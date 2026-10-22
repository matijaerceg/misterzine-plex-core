/* uvc -- a USB Video Class device through libusb (uvc.h; docs/uvc.md). */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include "uvc.h"

/* ---- the assembler: payloads -> whole frames, three buffers (pure: no libusb) ---- */

#define PAD 64                      /* zeroed past a frame's end: a decoder may read ahead (FFmpeg's padding) */

struct uvc_asm {
    uint32_t fourcc;
    unsigned width, height;
    size_t cap;                     /* a frame's largest size */
    uint8_t *buf[3];
    size_t len[3];
    int fill, ready, held;          /* buffer indices; ready / held -1: none */
    int bad;                        /* the frame being filled is lost (dropped at its end) */
    int fid, fid_known;
    int after_eof, eof_fid;         /* a frame ended by EOF: its FID's later payloads are strays */
};

struct uvc_asm *uvc_asm_new(uint32_t fourcc, unsigned width, unsigned height, size_t max_frame)
{
    struct uvc_asm *a = calloc(1, sizeof *a);
    if (!a) return NULL;
    a->fourcc = fourcc;
    a->width = width;
    a->height = height;
    a->cap = max_frame ? max_frame : (size_t)width * height * 2u;
    for (int i = 0; i < 3; i++)
        if (!(a->buf[i] = malloc(a->cap + PAD))) { uvc_asm_free(a); return NULL; }
    a->ready = a->held = -1;
    return a;
}

void uvc_asm_free(struct uvc_asm *a)
{
    if (!a) return;
    for (int i = 0; i < 3; i++) free(a->buf[i]);
    free(a);
}

/* a whole frame's shape: MJPEG from SOI to EOI (some devices pad zeros after EOI), YUY2 exact */
static int shape_ok(const struct uvc_asm *a, const uint8_t *p, size_t n)
{
    if (a->fourcc == UVC_MJPG) {
        if (n < 4 || p[0] != 0xFF || p[1] != 0xD8) return 0;
        size_t lo = n > 256 ? n - 256 : 2;
        for (size_t i = n - 1; i > lo; i--)
            if (p[i - 1] == 0xFF && p[i] == 0xD9) return 1;
        return 0;
    }
    if (a->fourcc == UVC_YUY2) return n == (size_t)a->width * a->height * 2u;
    return n > 0;
}

/* the frame being filled is done: hand it over (whole) or drop it (counted), start an empty one */
static int finish(struct uvc_asm *a, struct uvc_stats *s)
{
    int f = a->fill, done = 0;
    size_t n = a->len[f];
    if (n == 0 && !a->bad) return 0;          /* nothing was in it */
    if (!a->bad && n && !shape_ok(a, a->buf[f], n)) { a->bad = 1; s->bad_shape++; }
    if (a->bad) {
        s->frames_bad++;
    } else {
        memset(a->buf[f] + n, 0, PAD);
        if (a->ready >= 0) s->frames_replaced++;   /* never taken: the newer one wins */
        int old = a->ready;
        a->ready = f;
        /* the next buffer to fill: the replaced one, else the one neither ready nor held */
        if (old >= 0) a->fill = old;
        else for (int i = 0; i < 3; i++) if (i != a->ready && i != a->held) { a->fill = i; break; }
        s->frames++;
        done = 1;
    }
    a->len[a->fill] = 0;
    a->bad = 0;
    return done;
}

int uvc_asm_payload(struct uvc_asm *a, const uint8_t *p, size_t len, int status, struct uvc_stats *s)
{
    int done = 0;
    s->packets++;
    /* a frame is open from its first payload to its EOF (between frames, a lost packet may have been
     * the next frame's start: the shape check finds that one -- no SOI, or the wrong length) */
    int open = a->len[a->fill] > 0 || (a->fid_known && !a->after_eof);
    if (status) {                            /* the data is lost */
        s->packet_errors++;
        if (open && !a->bad) { s->bad_packet++; a->bad = 1; }
        return 0;
    }
    if (len == 0) { s->packets_empty++; return 0; }
    unsigned hle = p[0];
    if (hle < 2 || hle > len) {               /* not a payload header: its data cannot be placed */
        s->bad_headers++;
        if (open && !a->bad) { s->bad_packet++; a->bad = 1; }
        return 0;
    }
    unsigned bfh = p[1];
    int fid = bfh & 1, eof = (bfh >> 1) & 1, err = (bfh >> 6) & 1;
    if (a->fid_known && fid != a->fid) {     /* a new frame: the last one ended without EOF */
        if (a->len[a->fill] || a->bad) {
            if (!a->bad) s->fid_no_eof++;
            done |= finish(a, s);
        }
        a->after_eof = 0;
    }
    a->fid = fid;
    a->fid_known = 1;
    size_t n = len - hle;
    if (a->after_eof && fid == a->eof_fid) { /* after EOF, before the toggle: no frame is open */
        if (n) s->stray_payloads++;
        return done;
    }
    if (err && !a->bad) { s->bad_err_bit++; a->bad = 1; }
    if (n) {
        s->bytes += n;
        if (!a->bad) {
            if (a->len[a->fill] + n > a->cap) { s->bad_overflow++; a->bad = 1; }
            else { memcpy(a->buf[a->fill] + a->len[a->fill], p + hle, n); a->len[a->fill] += n; }
        }
    }
    if (eof) {
        done |= finish(a, s);
        a->after_eof = 1;
        a->eof_fid = fid;
    }
    return done;
}

/* the newest complete frame: 0 (valid until the next take), or -EAGAIN */
static int asm_take(struct uvc_asm *a, const uint8_t **data, size_t *len)
{
    if (a->ready < 0) return -EAGAIN;
    a->held = a->ready;
    a->ready = -1;
    *data = a->buf[a->held];
    *len = a->len[a->held];
    return 0;
}

const uint8_t *uvc_asm_frame(struct uvc_asm *a, size_t *len)
{
    const uint8_t *d;
    return asm_take(a, &d, len) ? NULL : d;
}

int uvc_mode_fits(const struct uvc_mode *m, uint32_t interval)
{
    if (m->fourcc != UVC_YUY2) return 1;         /* compressed: a fraction of the limit */
    if (!interval) return 0;
    return (uint64_t)m->width * m->height * 2u * 10000000u / interval <= UVC_MAX_RAW_BPS;
}

uint32_t uvc_pick_interval(const struct uvc_mode *m, uint32_t want)
{
    if (!want) return m->def_interval;
    if (m->n_int) {
        uint32_t b = m->intervals[0];
        for (unsigned i = 1; i < m->n_int; i++) {
            uint32_t v = m->intervals[i];
            if ((v > want ? v - want : want - v) < (b > want ? b - want : want - b)) b = v;
        }
        return b;
    }
    if (want < m->int_min) return m->int_min;
    if (want > m->int_max) return m->int_max;
    if (m->int_step) want = m->int_min + (want - m->int_min) / m->int_step * m->int_step;
    return want;
}

/* ---- the device ---- */
#ifndef UVC_NO_LIBUSB
#include <libusb.h>

#define MAX_MODES   256
#define ISO_XFERS   8               /* transfers in flight */
#define ISO_PACKETS 32              /* microframes a transfer: 4 ms at high speed (uvcvideo's UVC_MAX_PACKETS) */
#define BULK_XFERS  4
#define BULK_MAX    (1u << 20)      /* a bulk transfer's size cap, whatever the device asks */

struct uvc_dev {
    libusb_context *ctx;
    libusb_device_handle *h;
    struct libusb_config_descriptor *cfg;
    char name[96];
    uint16_t bcd_uvc;
    int vc_if, cam_id;              /* the control interface; the camera terminal's ID (0: none) */
    uint32_t cam_controls;          /* its bmControls */
    struct uvc_mode modes[MAX_MODES];
    unsigned n_modes;
    /* streaming */
    int vs_if, alt, iso;
    uint8_t ep;
    struct libusb_transfer *xfer[ISO_XFERS > BULK_XFERS ? ISO_XFERS : BULK_XFERS];
    unsigned n_xfer, active;
    pthread_t thread;
    int thread_on, stopping, failed;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    struct uvc_asm *as;
    struct uvc_stats st;
    double thread_cpu;
    int force_alt;
};

static int lu_err(int e)
{
    switch (e) {
    case LIBUSB_ERROR_ACCESS: return -EACCES;
    case LIBUSB_ERROR_NO_DEVICE: case LIBUSB_ERROR_NOT_FOUND: return -ENODEV;
    case LIBUSB_ERROR_BUSY: return -EBUSY;
    case LIBUSB_ERROR_TIMEOUT: return -ETIMEDOUT;
    case LIBUSB_ERROR_PIPE: return -EPIPE;
    case LIBUSB_ERROR_NO_MEM: return -ENOMEM;
    case LIBUSB_ERROR_NOT_SUPPORTED: return -EOPNOTSUPP;
    default: return -EIO;
    }
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

/* the class-specific descriptors of a VS interface (alt 0's extra bytes) */
static void parse_vs(struct uvc_dev *d, int ifnum, const uint8_t *x, int n)
{
    uint32_t fourcc = 0;
    uint8_t fmt_idx = 0;
    for (int i = 0; i + 3 <= n && x[i] >= 3 && i + x[i] <= n; i += x[i]) {
        const uint8_t *p = x + i;
        unsigned len = p[0], sub = p[2];
        if (p[1] != 0x24) continue;              /* CS_INTERFACE */
        if ((sub == 0x04 || sub == 0x10) && len >= 21) {   /* FORMAT_UNCOMPRESSED / FORMAT_FRAME_BASED */
            fmt_idx = p[3];
            fourcc = le32(p + 5);                /* the GUID's first four bytes are the FourCC */
        } else if (sub == 0x06 && len >= 11) {   /* FORMAT_MJPEG */
            fmt_idx = p[3];
            fourcc = UVC_MJPG;
        } else if ((sub == 0x05 || sub == 0x07 || sub == 0x11) && len >= 26 && fourcc && d->n_modes < MAX_MODES) {
            struct uvc_mode *m = &d->modes[d->n_modes];
            memset(m, 0, sizeof *m);
            m->fourcc = fourcc;
            m->vs_if = (uint8_t)ifnum;
            m->fmt_idx = fmt_idx;
            m->frame_idx = p[3];
            m->width = le16(p + 5);
            m->height = le16(p + 7);
            unsigned k;                          /* bFrameIntervalType's offset differs for frame-based */
            if (sub == 0x11) { m->max_frame = 0; m->def_interval = le32(p + 17); k = 21; }
            else { m->max_frame = le32(p + 17); m->def_interval = le32(p + 21); k = 25; }
            unsigned type = p[k];
            if (type == 0 && len >= k + 13) {
                m->int_min = le32(p + k + 1);
                m->int_max = le32(p + k + 5);
                m->int_step = le32(p + k + 9);
            } else {
                for (unsigned j = 0; j < type && j < UVC_MAX_INTERVALS && k + 1 + 4 * (j + 1) <= len; j++)
                    m->intervals[m->n_int++] = le32(p + k + 1 + 4 * j);
            }
            d->n_modes++;
        }
    }
}

int uvc_open(struct uvc_dev **dp, int vid, int pid)
{
    struct uvc_dev *d = calloc(1, sizeof *d);
    libusb_device **list = NULL;
    int rc = -ENODEV;
    if (!d) return -ENOMEM;
    pthread_mutex_init(&d->mu, NULL);
    pthread_cond_init(&d->cv, NULL);
    if (libusb_init(&d->ctx)) { free(d); return -EIO; }
    ssize_t n = libusb_get_device_list(d->ctx, &list);
    for (ssize_t i = 0; i < n && !d->h; i++) {
        struct libusb_device_descriptor dd;
        struct libusb_config_descriptor *cfg;
        if (libusb_get_device_descriptor(list[i], &dd)) continue;
        if (vid >= 0 && (dd.idVendor != vid || dd.idProduct != pid)) continue;
        if (libusb_get_active_config_descriptor(list[i], &cfg)) continue;
        int video = 0;
        for (int j = 0; j < cfg->bNumInterfaces; j++) {
            const struct libusb_interface_descriptor *a = &cfg->interface[j].altsetting[0];
            if (a->bInterfaceClass == 14 && a->bInterfaceSubClass == 2) video = 1;
        }
        if (!video) { libusb_free_config_descriptor(cfg); continue; }
        int e = libusb_open(list[i], &d->h);
        if (e) { rc = lu_err(e); libusb_free_config_descriptor(cfg); d->h = NULL; continue; }
        d->cfg = cfg;
        char prod[64] = "";
        if (dd.iProduct) libusb_get_string_descriptor_ascii(d->h, dd.iProduct, (unsigned char *)prod, sizeof prod);
        snprintf(d->name, sizeof d->name, "%04x:%04x %s", dd.idVendor, dd.idProduct,
                 prod[0] ? prod : "USB camera");      /* (the C270 names no product) */
    }
    libusb_free_device_list(list, 1);
    if (!d->h) { libusb_exit(d->ctx); free(d); return rc; }
    for (int j = 0; j < d->cfg->bNumInterfaces; j++) {
        const struct libusb_interface_descriptor *a = &d->cfg->interface[j].altsetting[0];
        if (a->bInterfaceClass != 14) continue;
        if (a->bInterfaceSubClass == 1) {        /* VC: the header's bcdUVC sets the probe's length */
            d->vc_if = a->bInterfaceNumber;
            for (int i = 0; i + 5 <= a->extra_length; i += a->extra[i] ? a->extra[i] : a->extra_length) {
                const uint8_t *x = a->extra + i;
                if (x[1] != 0x24) continue;
                if (x[2] == 0x01) d->bcd_uvc = le16(x + 3);
                /* INPUT_TERMINAL of type ITT_CAMERA: its controls (bControlSize at 14, bmControls at 15) */
                if (x[2] == 0x02 && x[0] >= 15 && le16(x + 4) == 0x0201 && i + x[0] <= a->extra_length) {
                    d->cam_id = x[3];
                    for (unsigned b = 0; b < x[14] && b < 4 && 15u + b < x[0]; b++)
                        d->cam_controls |= (uint32_t)x[15 + b] << (8 * b);
                }
            }
        } else if (a->bInterfaceSubClass == 2) {
            parse_vs(d, a->bInterfaceNumber, a->extra, a->extra_length);
        }
    }
    libusb_set_auto_detach_kernel_driver(d->h, 1);
    *dp = d;
    return 0;
}

const struct uvc_mode *uvc_modes(const struct uvc_dev *d, unsigned *n) { *n = d->n_modes; return d->modes; }
const char *uvc_name(const struct uvc_dev *d) { return d->name; }
void uvc_force_alt(struct uvc_dev *d, int alt) { d->force_alt = alt; }

const struct uvc_mode *uvc_pick(const struct uvc_dev *d, uint32_t fourcc, unsigned width, unsigned height)
{
    const struct uvc_mode *best = NULL, *any = NULL;
    for (unsigned i = 0; i < d->n_modes; i++) {
        const struct uvc_mode *m = &d->modes[i];
        if (m->fourcc != fourcc) continue;
        if (m->width == width && m->height == height) return m;
        if (!any || (unsigned)m->width * m->height < (unsigned)any->width * any->height) any = m;
        if (m->width <= width && m->height <= height &&
            (!best || (unsigned)m->width * m->height > (unsigned)best->width * best->height)) best = m;
    }
    return best ? best : any;
}

static int ctrl(struct uvc_dev *d, int set, unsigned sel, uint8_t *buf, unsigned len)
{
    int r = libusb_control_transfer(d->h, set ? 0x21 : 0xA1, set ? 0x01 /* SET_CUR */ : 0x81 /* GET_CUR */,
                                    (uint16_t)(sel << 8), (uint16_t)d->vs_if, buf, (uint16_t)len, 1000);
    return r < 0 ? lu_err(r) : r;
}

int uvc_fixed_rate(struct uvc_dev *d)
{
    uint8_t v = 0;                               /* CT_AE_PRIORITY_CONTROL 0: the frame rate stays constant */
    if (!d->cam_id || !(d->cam_controls & (1u << 2))) return -EOPNOTSUPP;
    int r = libusb_control_transfer(d->h, 0x21, 0x01, 0x03 << 8, (uint16_t)(d->cam_id << 8 | d->vc_if), &v, 1, 1000);
    return r < 0 ? lu_err(r) : 0;
}

/* libusb's event thread: it touches only the assembler and the counters, under the mutex -- never the
 * core's interface (h264ring is not thread-safe: the app's loop is its only caller) */
static void LIBUSB_CALL on_xfer(struct libusb_transfer *t)
{
    struct uvc_dev *d = t->user_data;
    int done = 0, resubmit = 1;
    pthread_mutex_lock(&d->mu);
    d->st.transfers++;
    if (t->status == LIBUSB_TRANSFER_CANCELLED || t->status == LIBUSB_TRANSFER_NO_DEVICE || d->stopping) {
        resubmit = 0;
        if (t->status == LIBUSB_TRANSFER_NO_DEVICE) d->failed = 1;
    } else if (d->iso) {
        for (int i = 0; i < t->num_iso_packets; i++) {
            const struct libusb_iso_packet_descriptor *pk = &t->iso_packet_desc[i];
            int bad = t->status != LIBUSB_TRANSFER_COMPLETED || pk->status != LIBUSB_TRANSFER_COMPLETED;
            done |= uvc_asm_payload(d->as, libusb_get_iso_packet_buffer_simple(t, (unsigned)i),
                                    pk->actual_length, bad, &d->st);
        }
    } else {
        done = uvc_asm_payload(d->as, t->buffer, (size_t)t->actual_length,
                               t->status != LIBUSB_TRANSFER_COMPLETED, &d->st);
    }
    if (resubmit && libusb_submit_transfer(t)) { d->st.resubmit_errors++; resubmit = 0; }
    if (!resubmit && --d->active == 0 && !d->stopping) d->failed = 1;   /* nothing in flight: no more frames */
    if (done || d->failed) pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
}

static void *event_thread(void *arg)
{
    struct uvc_dev *d = arg;
    struct timeval tv = { 0, 100000 };
    for (;;) {
        pthread_mutex_lock(&d->mu);
        int go = d->active > 0;
        pthread_mutex_unlock(&d->mu);
        if (!go) break;
        libusb_handle_events_timeout_completed(d->ctx, &tv, NULL);
    }
    struct rusage ru;
    if (getrusage(RUSAGE_THREAD, &ru) == 0)
        d->thread_cpu = ru.ru_utime.tv_sec + ru.ru_stime.tv_sec + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6;
    return NULL;
}

int uvc_start(struct uvc_dev *d, const struct uvc_mode *m, uint32_t interval, uint32_t *committed, char *info,
              size_t n)
{
    uint8_t pr[48];
    unsigned plen = d->bcd_uvc >= 0x0150 ? 48 : d->bcd_uvc >= 0x0110 ? 34 : 26;
    int rc, e;
    if (m->fourcc != UVC_MJPG && m->fourcc != UVC_YUY2) return -EOPNOTSUPP;
    d->vs_if = m->vs_if;
    if ((e = libusb_claim_interface(d->h, d->vs_if))) return lu_err(e);
    libusb_set_interface_alt_setting(d->h, d->vs_if, 0);
    memset(pr, 0, sizeof pr);
    pr[0] = 1;                                   /* bmHint: dwFrameInterval fixed */
    pr[2] = m->fmt_idx;
    pr[3] = m->frame_idx;
    pr[4] = (uint8_t)interval; pr[5] = (uint8_t)(interval >> 8);
    pr[6] = (uint8_t)(interval >> 16); pr[7] = (uint8_t)(interval >> 24);
    if ((rc = ctrl(d, 1, 1, pr, plen)) < 0) return rc;          /* SET_CUR PROBE */
    if ((rc = ctrl(d, 0, 1, pr, plen)) < 26) return rc < 0 ? rc : -EPROTO;   /* GET_CUR PROBE */
    if (pr[2] != m->fmt_idx || pr[3] != m->frame_idx) return -EPROTO;
    if ((rc = ctrl(d, 1, 2, pr, plen)) < 0) return rc;          /* SET_CUR COMMIT */
    uint32_t got_int = le32(pr + 4), max_frame = le32(pr + 18), payload = le32(pr + 22);
    if (committed) *committed = got_int ? got_int : interval;
    if (!max_frame || (m->max_frame && max_frame > m->max_frame)) max_frame = m->max_frame;
    if (!max_frame) max_frame = (uint32_t)m->width * m->height * 2u;

    const struct libusb_interface *itf = NULL;
    for (int j = 0; j < d->cfg->bNumInterfaces; j++)
        if (d->cfg->interface[j].altsetting[0].bInterfaceNumber == d->vs_if) itf = &d->cfg->interface[j];
    if (!itf) return -ENODEV;
    d->iso = itf->num_altsetting > 1;
    unsigned psize = 0, xsize;
    if (d->iso) {                                /* the smallest alternate setting that carries the payload */
        int best = -1, big = -1;
        unsigned bsz = 0, gsz = 0;
        for (int a = 1; a < itf->num_altsetting; a++) {
            const struct libusb_interface_descriptor *al = &itf->altsetting[a];
            for (int k = 0; k < al->bNumEndpoints; k++) {
                const struct libusb_endpoint_descriptor *ep = &al->endpoint[k];
                if ((ep->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_ISOCHRONOUS || !(ep->bEndpointAddress & 0x80)) continue;
                unsigned sz = (ep->wMaxPacketSize & 0x7FFu) * (1u + ((ep->wMaxPacketSize >> 11) & 3u));
                if (payload && sz >= payload && (best < 0 || sz < bsz)) { best = a; bsz = sz; d->ep = ep->bEndpointAddress; }
                if (sz > gsz) { big = a; gsz = sz; }
            }
        }
        if (best < 0) {                          /* more than any setting carries, or 0 (unknown): the largest */
            best = big; bsz = gsz;
            for (int k = 0; best >= 0 && k < itf->altsetting[best].bNumEndpoints; k++)
                if (itf->altsetting[best].endpoint[k].bEndpointAddress & 0x80) d->ep = itf->altsetting[best].endpoint[k].bEndpointAddress;
        }
        if (d->force_alt > 0 && d->force_alt < itf->num_altsetting) {   /* measuring: this one */
            const struct libusb_interface_descriptor *al = &itf->altsetting[d->force_alt];
            for (int k = 0; k < al->bNumEndpoints; k++)
                if (al->endpoint[k].bEndpointAddress & 0x80) {
                    best = d->force_alt;
                    d->ep = al->endpoint[k].bEndpointAddress;
                    bsz = (al->endpoint[k].wMaxPacketSize & 0x7FFu) * (1u + ((al->endpoint[k].wMaxPacketSize >> 11) & 3u));
                }
        }
        if (best < 0) return -ENODEV;
        d->alt = best;
        psize = bsz;
        if ((e = libusb_set_interface_alt_setting(d->h, d->vs_if, d->alt))) return lu_err(e);
        xsize = psize * ISO_PACKETS;
    } else {
        const struct libusb_interface_descriptor *al = &itf->altsetting[0];
        for (int k = 0; k < al->bNumEndpoints; k++)
            if ((al->endpoint[k].bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_BULK && (al->endpoint[k].bEndpointAddress & 0x80))
                d->ep = al->endpoint[k].bEndpointAddress;
        if (!d->ep) return -ENODEV;
        d->alt = 0;
        xsize = payload ? payload : max_frame;
        if (xsize > BULK_MAX) xsize = BULK_MAX;
    }
    uvc_asm_free(d->as);                         /* a restart (another mode): a fresh stream's state */
    d->stopping = d->failed = 0;
    d->active = 0;
    if (!(d->as = uvc_asm_new(m->fourcc, m->width, m->height, max_frame))) return -ENOMEM;
    for (unsigned i = 0; i < (d->iso ? ISO_XFERS : BULK_XFERS); i++) {   /* n_xfer counts what exists */
        uint8_t *buf = malloc(xsize);
        struct libusb_transfer *t = libusb_alloc_transfer(d->iso ? ISO_PACKETS : 0);
        if (!buf || !t) { free(buf); if (t) libusb_free_transfer(t); return -ENOMEM; }
        if (d->iso) {
            libusb_fill_iso_transfer(t, d->h, d->ep, buf, (int)xsize, ISO_PACKETS, on_xfer, d, 0);
            libusb_set_iso_packet_lengths(t, psize);
        } else {
            libusb_fill_bulk_transfer(t, d->h, d->ep, buf, (int)xsize, on_xfer, d, 0);
        }
        t->flags = LIBUSB_TRANSFER_FREE_BUFFER;
        d->xfer[d->n_xfer++] = t;
    }
    pthread_mutex_lock(&d->mu);
    for (unsigned i = 0; i < d->n_xfer; i++) {
        if ((e = libusb_submit_transfer(d->xfer[i]))) { rc = lu_err(e); break; }
        d->active++;
    }
    pthread_mutex_unlock(&d->mu);
    if (!d->active) return rc < 0 ? rc : -EIO;
    if (pthread_create(&d->thread, NULL, event_thread, d) == 0) d->thread_on = 1;
    if (info) {
        char how[32];
        if (d->iso) snprintf(how, sizeof how, "iso alt %d, %u B a microframe", d->alt, psize);
        else snprintf(how, sizeof how, "bulk, %u B transfers", xsize);
        snprintf(info, n, "%s %ux%u, interval %u (%.2f frames/s), %s, payload %u B, frame <= %u B, UVC %x.%02x",
                 m->fourcc == UVC_MJPG ? "MJPEG" : "YUY2", m->width, m->height, got_int,
                 got_int ? 1e7 / got_int : 0.0, how, payload, max_frame, d->bcd_uvc >> 8, d->bcd_uvc & 0xFF);
    }
    return 0;
}

int uvc_take(struct uvc_dev *d, const uint8_t **data, size_t *len, unsigned timeout_ms)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&d->mu);
    int rc;
    while ((rc = asm_take(d->as, data, len)) == -EAGAIN && !d->failed)
        if (pthread_cond_timedwait(&d->cv, &d->mu, &ts)) break;
    if (rc == 0) d->st.frames_taken++;
    else if (d->failed) rc = -EIO;
    pthread_mutex_unlock(&d->mu);
    return rc;
}

void uvc_get_stats(struct uvc_dev *d, struct uvc_stats *s)
{
    pthread_mutex_lock(&d->mu);
    *s = d->st;
    pthread_mutex_unlock(&d->mu);
}

double uvc_thread_cpu(const struct uvc_dev *d) { return d->thread_cpu; }

void uvc_stop(struct uvc_dev *d)
{
    if (!d->n_xfer) return;
    pthread_mutex_lock(&d->mu);
    d->stopping = 1;
    pthread_mutex_unlock(&d->mu);
    for (unsigned i = 0; i < d->n_xfer; i++) libusb_cancel_transfer(d->xfer[i]);
    if (d->thread_on) pthread_join(d->thread, NULL);
    d->thread_on = 0;
    struct timeval tv = { 0, 100000 };
    for (int i = 0; i < 20 && d->active; i++)   /* no event thread (it never started): reap here */
        libusb_handle_events_timeout_completed(d->ctx, &tv, NULL);
    for (unsigned i = 0; i < d->n_xfer; i++) libusb_free_transfer(d->xfer[i]);
    d->n_xfer = 0;
    libusb_set_interface_alt_setting(d->h, d->vs_if, 0);
    libusb_release_interface(d->h, d->vs_if);
}

void uvc_close(struct uvc_dev *d)
{
    if (!d) return;
    uvc_stop(d);
    uvc_asm_free(d->as);
    if (d->cfg) libusb_free_config_descriptor(d->cfg);
    if (d->h) libusb_close(d->h);
    libusb_exit(d->ctx);
    free(d);
}
#endif
