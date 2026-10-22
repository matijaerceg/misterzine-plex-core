/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/uvc/tests/test_cam.c -- the camera viewer (src/cam.c + ../common/, built with -DCLIENT_TEST)
 * against a fake core and a fake camera, driven by a script (docs/uvc.md U6).
 *
 *   test_cam FONTDIR SCRIPT TIMEOUT_S
 *
 * The fake core is cut down from the file player's (clients/player/tests/test_player.c: the nonce, the
 * read index, the seqlocked status block, records consumed whole, the overlay's descriptor taken, the pad
 * written into the input region) to what a picture stream needs: each PICTURE consumed with a probe of
 * its store, a stand-in display that shows each at once (no PTS) and releases the one before -- word 84
 * from it --, and word 34's PAUSE (nothing consumed while it is set). A copy, not a shared file: a third
 * user of the player's fake core is the moment to move it to clients/common/tests/ (U6).
 * The fake camera implements uvc.h's device calls over pre-encoded frames (an MJPEG camera, 4:2:2 full
 * range as the C270's; an uncompressed-only device): frame i's top-left 16 x 16 block has the brightness
 * 30 + 5 (i mod 32), the block right of it 235 (full range) -- so a picture's store says which frame it
 * was and whether full range became limited. Its 320x240 mode commits 25 frames a second when asked for
 * 30 (a device may), so the record's rate says whether the COMMITTED interval was sent.
 * The script, one command a line (each waits for the one before; every wait times out after 20 s):
 *   sleep S | press B[+B] | plug cam|rawonly | unplug | wait_pics N | wait_size W H | mark NAME | end
 * Then the checks (C1-C9, T1-T5), "test_cam: ALL GREEN" last. */
#include "h264ring.h"
#include "uvc.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>

#define RING      (1u << 20)
#define MAXSESS   64
#define MAXPIC    (1u << 16)
#define MAXEV     4096
#define STEP_US   200
#define PRESS_US  60000u
#define WAIT_S    20.0
#define NFRAMES   32

extern h264ring *client_test_ring;
int cam_main(int argc, char **argv);
void cam_test_stop(void);

static int fails;
#define CHECK(label, cond) do { int ok_ = (cond); printf("  %s %s\n", ok_ ? "PASS" : "FAIL", label); \
                                if (!ok_) fails++; } while (0)

static double wall(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ---- the fake core (cut down from test_player.c) ---- */
static uint64_t ctrl[512];
static uint64_t *ringmem, *stores;
static pthread_mutex_t mx = PTHREAD_MUTEX_INITIALIZER;
static int shown = -1;
static struct { int store; } dq[64];
static unsigned dq_h, dq_t;
static uint32_t pic_emitted, pic_busy;

static struct pic {                     /* every PICTURE consumed */
    double t;
    int sess;
    unsigned flags, w_mbs, hf_mbs, width, height;
    double fps;
    int y_id, y_fixed;                  /* the store's luma at the id block's and the fixed block's centres */
    unsigned colour;                    /* (0.16) the record's colour code (header word 1 [35:33]) */
} pics[MAXPIC];
static unsigned npic;

static struct {
    int booted, sess, stop, paused, bad_header, bad_seen, vrec;
    uint32_t seen, rw, seq, ack, w34, nsess;
    uint32_t ovl_gen;
    int ovl_state;
    unsigned ovl_taken, ovl_refused, ovl_shown;
    uint32_t wi_at_pause, pending_at_resume, resumes;  /* bytes written after the pause was seen */
} core;

static struct { int active; unsigned phase; uint32_t buttons, pad0, seq; double t_edge; } inj;

static uint32_t lo(unsigned w) { return (uint32_t)ctrl[w]; }
static void put(unsigned w, unsigned lsb, unsigned width, uint64_t v)
{
    uint64_t m = width >= 64 ? ~0ull : ((1ull << width) - 1u);
    ctrl[w] = (ctrl[w] & ~(m << lsb)) | ((v & m) << lsb);
}
#define PUT(F, v) put(H264RING_##F##_W, H264RING_##F##_LSB, H264RING_##F##_WIDTH, (v))

static void core_status(void)
{
    core.seq++;
    put(3, 0, 32, core.seq);
    __sync_synchronize();
    ctrl[0] = H264RING_MAGIC;
    ctrl[1] = H264RING_VERSION | ((uint64_t)H264RING_CORE_WORDS << 16) | ((uint64_t)H264RING_PROG_WORD << 32) |
              ((uint64_t)H264RING_CORE2_WORD << 48);
    ctrl[2] = H264RING_RING_BYTE | ((uint64_t)RING << 32);
    put(3, 32, 32, H264RING_MAX_PAYLOAD);
    PUT(STATE, !core.sess ? H264RING_S_NO_SESSION : core.vrec ? H264RING_S_PLAYING : H264RING_S_READY);
    uint32_t held = shown >= 0 ? 1u << shown : 0u;
    for (unsigned i = dq_h; i != dq_t; i++) held |= 1u << dq[i % 64].store;
    PUT(PIC_HELD, held);
    PUT(PIC_MODE, core.vrec);
    PUT(CAP_PIC_STORES, H264RING_DPB_STORES);
    PUT(PIC_EMITTED, pic_emitted);
    PUT(LIVE, core.sess ? H264RING_L_SESSION : 0);
    ctrl[5] = core.rw | ((uint64_t)core.ack << 32);
    PUT(PAUSED, core.paused);
    PUT(OVL_GEN, core.ovl_gen);
    PUT(OVL_STATE, core.ovl_state);
    PUT(CAP_MAX_MBS, 3600);
    PUT(CAP_NATIVE_H, 720);
    PUT(CAP_MB_RATE, 108000);
    PUT(RASTER_W, 720u);
    PUT(RASTER_H, 480u);
    PUT(RASTER_MODE, H264RING_RASTER_FITTED);
    PUT(AR_X, 4u); PUT(AR_Y, 3u);
    __sync_synchronize();
    put(31, 0, 32, core.seq);
}

static void input_write(uint32_t pad0)
{
    inj.seq++;
    put(H264RING_IN_HEAD_W, H264RING_IN_HEAD_LSB, H264RING_IN_HEAD_WIDTH, inj.seq);
    __sync_synchronize();
    put(H264RING_PAD0_JOY_W, H264RING_PAD0_JOY_LSB, H264RING_PAD0_JOY_WIDTH, pad0);
    __sync_synchronize();
    put(H264RING_IN_TAIL_W, H264RING_IN_TAIL_LSB, H264RING_IN_TAIL_WIDTH, inj.seq);
}

static void input_step(double now)
{
    if (!inj.active) return;
    if (now - inj.t_edge >= PRESS_US / 1e6) { inj.phase++; inj.t_edge = now; }
    uint32_t pad0 = inj.phase == 0 ? inj.buttons : 0u;
    if (pad0 != inj.pad0) { inj.pad0 = pad0; input_write(pad0); }
    if (inj.phase >= 2) inj.active = 0;
}

static void consume(uint32_t wi)
{
    while (core.rw != wi && !core.bad_header) {
        uint32_t avail = wi - core.rw;
        if (avail < 16) break;
        uint64_t w0 = ringmem[(core.rw % RING) / 8], w1 = ringmem[((core.rw + 8) % RING) / 8];
        unsigned type = (unsigned)(w0 & 0xFF), flags = (unsigned)((w0 >> 8) & 0xFF);
        uint32_t len = (uint32_t)(w0 >> 32), n = 16u + ((len + 15u) & ~15u);
        if (type < H264RING_T_PAD || type > H264RING_T_PICTURE || type == H264RING_T_CONTROL ||
            (type == H264RING_T_PICTURE && len != H264RING_PIC_PAYLOAD) || (w1 >> 48) != H264RING_SYNC ||
            n > RING - core.rw % RING) {
            core.bad_header = core.bad_seen = 1;
            break;
        }
        if (n > avail) break;
        if (type == H264RING_T_PICTURE) {
            uint64_t d[4];
            for (unsigned k = 0; k < 4; k++) d[k] = ringmem[((core.rw + 16u + 8u * k) % RING) / 8];
            unsigned st = (unsigned)(d[0] & 31u);
            uint32_t held = shown >= 0 ? 1u << shown : 0u;
            for (unsigned i = dq_h; i != dq_t; i++) held |= 1u << dq[i % 64].store;
            if (st >= H264RING_DPB_STORES || (held >> st & 1u)) pic_busy++;
            if (npic < MAXPIC && st < H264RING_DPB_STORES) {
                struct pic *p = &pics[npic++];
                p->t = wall();
                p->sess = (int)core.nsess;
                p->flags = flags;
                p->w_mbs = (unsigned)(d[0] >> 8) & 0xFFu;
                p->hf_mbs = (unsigned)(d[0] >> 16) & 0xFFu;
                p->width = 16u * p->w_mbs - 2u * (unsigned)((d[3] >> 10) & 0x3FFu);   /* crop_r, crop_b */
                p->height = 16u * p->hf_mbs - 2u * (unsigned)((d[3] >> 30) & 0x3FFu);
                uint32_t nuit = (uint32_t)d[2], ts = (uint32_t)(d[2] >> 32);
                p->fps = nuit ? ts / (2.0 * nuit) : 0;
                const uint8_t *y = (const uint8_t *)stores + (size_t)st * H264RING_DPB_STORE;
                unsigned stride = 16u * p->w_mbs;
                p->y_id = y[8u * stride + 8u];
                p->y_fixed = y[8u * stride + 24u];
                p->colour = (unsigned)(ringmem[((core.rw + 8u) % RING) / 8] >> 33) & 7u;
            }
            if (dq_t - dq_h < 64) dq[dq_t++ % 64].store = (int)st;
            pic_emitted++;
            core.vrec = 1;
        }
        core.rw += n;
    }
}

static void core_step(void)
{
    double now = wall();
    input_step(now);
    uint32_t wi = lo(H264RING_W_WRITE_INDEX), nonce = lo(H264RING_W_NONCE), w34 = lo(H264RING_W_PAUSE);
    int paused = core.sess && (w34 >> H264RING_CTL_PAUSE_BIT & 1u);
    if (!core.paused && paused) core.wi_at_pause = wi;
    if (core.paused && !paused) {        /* a resume: what was written while paused waits in the ring */
        core.pending_at_resume += wi - core.wi_at_pause;
        core.resumes++;
    }
    core.paused = paused;
    if (!core.booted) {
        core.seen = nonce;
        core.booted = 1;
    } else if (nonce != core.seen) {     /* a session (or a flush): the stream reset, READY */
        core.seen = nonce;
        core.sess = 1;
        core.nsess++;
        core.rw = wi & ~15u;
        core.ack = nonce;
        core.vrec = 0;
        core.bad_header = 0;
        dq_h = dq_t = 0;
        shown = -1;
    } else if (core.sess && !core.paused) {
        consume(wi);
    }
    while (dq_h != dq_t && !core.paused) shown = dq[dq_h++ % 64].store;   /* no PTS: shown at once */
    uint32_t glo = lo(H264RING_W_OVL_GEN_LO), ghi = lo(H264RING_W_OVL_GEN_HI);
    if (glo == ghi && glo != core.ovl_gen) {
        uint32_t c = lo(H264RING_W_OVL_CTL), base = lo(H264RING_W_OVL_BASE), size = lo(H264RING_W_OVL_SIZE);
        uint32_t stride = lo(H264RING_W_OVL_STRIDE), band = lo(H264RING_W_OVL_BAND);
        uint32_t w = size & 0xFFFF, h = size >> 16, fmt = (c >> H264RING_OVL_CTL_FMT_LSB) & 3u;
        int state = H264RING_OVL_S_OFF;
        if (c & 1u) {
            uint32_t bpp = fmt == H264RING_OVL_FMT_8888 ? 4u : 2u;
            int ok = !(c & H264RING_OVL_CTL_RESERVED) && fmt != 3 && w >= 1 && w <= H264RING_OVL_MAX_W &&
                     h >= 1 && h <= H264RING_OVL_MAX_H && stride % 8 == 0 && stride >= w * bpp && base % 8 == 0 &&
                     (band & 0xFFFF) <= (band >> 16) && (band >> 16) < h && base >= H264RING_FB_BYTE &&
                     (uint64_t)base + (uint64_t)(h - 1) * stride + w * bpp <= (uint64_t)H264RING_FB_BYTE + H264RING_FB_SIZE;
            state = ok ? H264RING_OVL_S_ACCEPTED : H264RING_OVL_S_REFUSED;
            if (!ok) core.ovl_refused++;
            else core.ovl_shown++;
        }
        core.ovl_gen = glo;
        core.ovl_state = state;
        core.ovl_taken++;
    }
    core_status();
}

static void *core_thread(void *u)
{
    (void)u;
    while (!core.stop) {
        pthread_mutex_lock(&mx);
        core_step();
        pthread_mutex_unlock(&mx);
        usleep(STEP_US);
    }
    return NULL;
}

static void be_barrier(void *u) { (void)u; __sync_synchronize(); sched_yield(); }

/* ---- the fake camera: uvc.h's device calls ---- */
static pthread_mutex_t cam_mx = PTHREAD_MUTEX_INITIALIZER;
static int plugged;                     /* 0 none, 1 cam, 2 rawonly, 3 flaky (its 640x480 will not start) */
static unsigned plug_gen;               /* each plug a new device: an open handle of an older one is dead */
static unsigned opens, starts, tries;   /* uvc_open; uvc_start; uvc_fixed_rate (once a device tried) */

struct frameset { unsigned w, h, n; uint8_t *data[NFRAMES]; size_t len[NFRAMES]; };
static struct frameset fs_640, fs_320, raw_320;

struct uvc_dev {
    unsigned gen, profile;
    struct uvc_mode modes[8];
    unsigned n_modes;
    const struct uvc_mode *m;
    const struct frameset *fs;
    uint32_t interval;
    double next;
    unsigned frame;
    int streaming;
};

static void add_mode(struct uvc_dev *d, uint32_t fourcc, unsigned w, unsigned h, uint32_t iv0, uint32_t iv1)
{
    struct uvc_mode *m = &d->modes[d->n_modes];
    memset(m, 0, sizeof *m);
    m->fourcc = fourcc;
    m->vs_if = 1;
    m->fmt_idx = fourcc == UVC_MJPG ? 2 : 1;
    m->frame_idx = (uint8_t)(d->n_modes + 1);
    m->width = (uint16_t)w;
    m->height = (uint16_t)h;
    m->max_frame = w * h * 2u;
    m->def_interval = iv0;
    m->intervals[m->n_int++] = iv0;
    if (iv1) m->intervals[m->n_int++] = iv1;
    d->n_modes++;
}

int uvc_open(struct uvc_dev **dp, int vid, int pid)
{
    (void)vid; (void)pid;
    pthread_mutex_lock(&cam_mx);
    int p = plugged;
    unsigned g = plug_gen;
    if (p) opens++;
    pthread_mutex_unlock(&cam_mx);
    if (!p) return -ENODEV;
    struct uvc_dev *d = calloc(1, sizeof *d);
    d->gen = g;
    d->profile = (unsigned)p;
    if (p == 1) {                       /* a webcam: MJPEG and YUY2, one HD mode past SD */
        add_mode(d, UVC_MJPG, 1280, 720, 333333, 0);
        add_mode(d, UVC_MJPG, 640, 480, 333333, 666666);
        add_mode(d, UVC_YUY2, 640, 480, 333333, 0);      /* 18.4 MB/s: past U2b's 6 */
        add_mode(d, UVC_MJPG, 320, 240, 333333, 0);
        add_mode(d, UVC_YUY2, 320, 240, 333333, 0);      /* 4.6 MB/s: fits */
    } else if (p == 2) {                /* uncompressed only, none slow enough */
        add_mode(d, UVC_YUY2, 640, 480, 333333, 0);
        add_mode(d, UVC_YUY2, 1280, 720, 1000000, 0);
    } else {                            /* flaky: its best mode fails to start, the next works */
        add_mode(d, UVC_MJPG, 640, 480, 333333, 0);
        add_mode(d, UVC_MJPG, 320, 240, 333333, 0);
    }
    *dp = d;
    return 0;
}

const struct uvc_mode *uvc_modes(const struct uvc_dev *d, unsigned *n) { *n = d->n_modes; return d->modes; }
const char *uvc_name(const struct uvc_dev *d)
{
    return d->profile == 1 ? "1234:0001 Test Camera" : d->profile == 2 ? "1234:0002 Raw Box" : "1234:0003 Flaky Cam";
}
int uvc_fixed_rate(struct uvc_dev *d)
{
    (void)d;
    pthread_mutex_lock(&cam_mx);
    tries++;
    pthread_mutex_unlock(&cam_mx);
    return 0;
}
void uvc_force_alt(struct uvc_dev *d, int alt) { (void)d; (void)alt; }
const struct uvc_mode *uvc_pick(const struct uvc_dev *d, uint32_t f, unsigned w, unsigned h) { (void)f; (void)w; (void)h; return d->modes; }
double uvc_thread_cpu(const struct uvc_dev *d) { (void)d; return 0; }
void uvc_get_stats(struct uvc_dev *d, struct uvc_stats *s) { (void)d; memset(s, 0, sizeof *s); }

int uvc_start(struct uvc_dev *d, const struct uvc_mode *m, uint32_t interval, uint32_t *committed, char *info, size_t n)
{
    const struct frameset *fs = m->fourcc == UVC_MJPG ? (m->width == 640 ? &fs_640 : m->width == 320 ? &fs_320 : NULL)
                                                      : (m->width == 320 ? &raw_320 : NULL);
    pthread_mutex_lock(&cam_mx);
    starts++;                           /* counted first: an attempt at a mode the viewer must not offer counts */
    pthread_mutex_unlock(&cam_mx);
    if (!fs) return -EOPNOTSUPP;        /* a mode the test made no frames for: never started by a GREEN run */
    if (d->profile == 3 && m->width == 640) return -EIO;   /* the flaky camera's best mode */
    d->m = m;
    d->fs = fs;
    d->interval = m->width == 320 && m->fourcc == UVC_MJPG ? 400000u : interval;   /* commits 25 for 30 */
    if (committed) *committed = d->interval;
    if (info) snprintf(info, n, "fake %ux%u", m->width, m->height);
    d->next = wall();
    d->streaming = 1;
    return 0;
}

int uvc_take(struct uvc_dev *d, const uint8_t **data, size_t *len, unsigned timeout_ms)
{
    (void)timeout_ms;
    pthread_mutex_lock(&cam_mx);
    int gone = !plugged || plug_gen != d->gen;
    pthread_mutex_unlock(&cam_mx);
    if (gone) return -EIO;
    if (!d->streaming || wall() < d->next) return -EAGAIN;
    d->next += d->interval / 1e7;
    if (wall() > d->next + 0.2) d->next = wall();          /* the loop was away: no catch-up burst */
    unsigned k = d->frame++ % d->fs->n;
    *data = d->fs->data[k];
    *len = d->fs->len[k];
    return 0;
}

void uvc_stop(struct uvc_dev *d) { d->streaming = 0; }
void uvc_close(struct uvc_dev *d) { free(d); }

/* frame i: the id block's brightness (full range for MJPEG, limited for YUY2) */
static int id_luma(unsigned i) { return 30 + 5 * (int)(i % NFRAMES); }

static void make_mjpeg(struct frameset *fs, unsigned w, unsigned h)
{
    const AVCodec *enc = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
    AVCodecContext *c = avcodec_alloc_context3(enc);
    c->width = (int)w; c->height = (int)h;
    c->pix_fmt = AV_PIX_FMT_YUVJ422P;
    c->time_base = (AVRational){ 1, 30 };
    c->flags |= AV_CODEC_FLAG_QSCALE;
    c->global_quality = FF_QP2LAMBDA * 2;
    if (avcodec_open2(c, enc, NULL) < 0) { fprintf(stderr, "test_cam: no MJPEG encoder\n"); exit(2); }
    AVFrame *f = av_frame_alloc();
    f->format = c->pix_fmt; f->width = (int)w; f->height = (int)h;
    av_frame_get_buffer(f, 32);
    AVPacket *pkt = av_packet_alloc();
    fs->w = w; fs->h = h; fs->n = NFRAMES;
    for (unsigned i = 0; i < NFRAMES; i++) {
        av_frame_make_writable(f);
        for (unsigned y = 0; y < h; y++)
            for (unsigned x = 0; x < w; x++)
                f->data[0][y * f->linesize[0] + x] = y < 16 && x < 16 ? (uint8_t)id_luma(i) : y < 16 && x < 32 ? 235 : 90;
        for (int p = 1; p < 3; p++)
            for (unsigned y = 0; y < h; y++) memset(f->data[p] + y * f->linesize[p], 128, w / 2);
        f->pts = i;
        if (avcodec_send_frame(c, f) < 0 || avcodec_receive_packet(c, pkt) < 0) { fprintf(stderr, "test_cam: encode\n"); exit(2); }
        fs->data[i] = calloc(1, (size_t)pkt->size + 64);   /* zero padding past the end, as uvc.c's */
        memcpy(fs->data[i], pkt->data, (size_t)pkt->size);
        fs->len[i] = (size_t)pkt->size;
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    av_frame_free(&f);
    avcodec_free_context(&c);
}

static void make_yuy2(struct frameset *fs, unsigned w, unsigned h)
{
    fs->w = w; fs->h = h; fs->n = NFRAMES;
    for (unsigned i = 0; i < NFRAMES; i++) {
        uint8_t *b = calloc(1, (size_t)w * h * 2u + 64);
        for (unsigned y = 0; y < h; y++)
            for (unsigned x = 0; x < w; x++) {
                uint8_t *s = b + ((size_t)y * w + x) * 2u;
                s[0] = y < 16 && x < 16 ? (uint8_t)id_luma(i) : y < 16 && x < 32 ? 235 : 90;
                s[1] = 128;
            }
        fs->data[i] = b;
        fs->len[i] = (size_t)w * h * 2u;
    }
}

/* ---- the viewer on its thread ---- */
static const char *fontdir;
static volatile int client_done;
static int client_rc = -1;

static void *client_thread(void *u)
{
    (void)u;
    char *argv[] = { "h264cam", "--dir", (char *)fontdir, NULL };
    client_rc = cam_main(3, argv);
    client_done = 1;
    return NULL;
}

static uint32_t button(const char *b)
{
    static const struct { const char *n; uint32_t m; } t[] = {
        {"A", H264RING_PAD_A}, {"B", H264RING_PAD_B}, {"UP", H264RING_PAD_UP}, {"DOWN", H264RING_PAD_DOWN},
        {"START", H264RING_PAD_START}, {"BACK", H264RING_PAD_BACK},
    };
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) if (!strcmp(b, t[i].n)) return t[i].m;
    fprintf(stderr, "test_cam: what button is %s?\n", b);
    exit(2);
}

#define MAXMARK 32
static struct { char name[64]; unsigned npic, nsess, opens, starts, tries, ovl_shown; double t; } marks[MAXMARK + 1];
static unsigned nmarks;

/* a mark's index; one the script never reached (a wait cut it short) is the empty sentinel: the checks
 * reading it fail, the rest still report */
static int mark(const char *name)
{
    for (unsigned i = 0; i < nmarks; i++) if (!strcmp(marks[i].name, name)) return (int)i;
    printf("test_cam: the script never reached mark %s\n", name);
    return MAXMARK;
}

/* the frame a picture was: the id brightness nearest its probe (limited range: 16 + 219 v / 255) */
static int pic_frame(const struct pic *p, int full)
{
    int best = -1, bd = 1 << 30;
    for (unsigned i = 0; i < NFRAMES; i++) {
        int v = id_luma(i), want = full ? 16 + (219 * v + 127) / 255 : v;
        int dd = abs(p->y_id - want);
        if (dd < bd) { bd = dd; best = (int)i; }
    }
    return bd <= 3 ? best : -1;
}

int main(int argc, char **argv)
{
    if (argc != 4) { fprintf(stderr, "usage: test_cam FONTDIR SCRIPT TIMEOUT_S\n"); return 2; }
    fontdir = argv[1];
    double timeout_s = atof(argv[3]);
    make_mjpeg(&fs_640, 640, 480);
    make_mjpeg(&fs_320, 320, 240);
    make_yuy2(&raw_320, 320, 240);
    ringmem = calloc(RING / 8, 8);
    stores = calloc((size_t)H264RING_DPB_STORES * H264RING_DPB_STORE / 8u, 8);
    core_status();
    pthread_t ct, pt;
    pthread_create(&ct, NULL, core_thread, NULL);
    usleep(2000);
    struct h264ring_backend be;
    memset(&be, 0, sizeof be);
    be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING; be.barrier = be_barrier; be.stores = stores;
    int arc = h264ring_attach(&client_test_ring, &be);
    CHECK("T1 the library attaches to the fake core", arc == 0 && client_test_ring);
    if (arc) { printf("test_cam: FAILURES\n"); return 1; }

    FILE *sf = fopen(argv[2], "r");
    if (!sf) { perror(argv[2]); return 2; }
    double t0 = wall();
    pthread_create(&pt, NULL, client_thread, NULL);
    char line[256];
    int ended = 0, timeouts = 0;
    while (!ended && !client_done && wall() - t0 < timeout_s && fgets(line, sizeof line, sf)) {
        line[strcspn(line, "\r\n#")] = 0;
        char cmd[32] = "", a1[64] = "", a2[64] = "";
        if (sscanf(line, "%31s %63s %63s", cmd, a1, a2) < 1) continue;
        double ts = wall();
        int timed_out = 0;
        if (!strcmp(cmd, "sleep")) {
            usleep((useconds_t)(atof(a1) * 1e6));
        } else if (!strcmp(cmd, "press")) {
            uint32_t m = 0;
            for (char *tok = strtok(a1, "+"); tok; tok = strtok(NULL, "+")) m |= button(tok);
            pthread_mutex_lock(&mx);
            inj.active = 1; inj.phase = 0; inj.buttons = m; inj.t_edge = wall();
            pthread_mutex_unlock(&mx);
            for (;;) {
                pthread_mutex_lock(&mx);
                int busy = inj.active;
                pthread_mutex_unlock(&mx);
                if (!busy || client_done) break;
                if (wall() - ts > WAIT_S) { timed_out = 1; break; }
                usleep(2000);
            }
            usleep(150000);                              /* the viewer's loop acts on it */
        } else if (!strcmp(cmd, "plug") || !strcmp(cmd, "unplug")) {
            pthread_mutex_lock(&cam_mx);
            plugged = !strcmp(cmd, "unplug") ? 0 : !strcmp(a1, "cam") ? 1 : !strcmp(a1, "flaky") ? 3 : 2;
            plug_gen++;
            pthread_mutex_unlock(&cam_mx);
        } else if (!strcmp(cmd, "wait_pics") || !strcmp(cmd, "wait_size")) {
            unsigned want = (unsigned)atoi(a1), wh = (unsigned)atoi(a2);
            unsigned base = npic;
            for (;;) {
                pthread_mutex_lock(&mx);
                int ok = !strcmp(cmd, "wait_pics") ? npic >= base + want
                       : npic > 0 && pics[npic - 1].width == want && pics[npic - 1].height == wh;
                pthread_mutex_unlock(&mx);
                if (ok) break;
                if (wall() - ts > WAIT_S || client_done) { timed_out = 1; break; }
                usleep(2000);
            }
        } else if (!strcmp(cmd, "mark")) {
            pthread_mutex_lock(&mx);
            pthread_mutex_lock(&cam_mx);
            if (nmarks < MAXMARK) {
                snprintf(marks[nmarks].name, sizeof marks[nmarks].name, "%s", a1);
                marks[nmarks].npic = npic;
                marks[nmarks].nsess = core.nsess;
                marks[nmarks].opens = opens;
                marks[nmarks].starts = starts;
                marks[nmarks].tries = tries;
                marks[nmarks].ovl_shown = core.ovl_shown;
                marks[nmarks++].t = wall();
            }
            pthread_mutex_unlock(&cam_mx);
            pthread_mutex_unlock(&mx);
        } else if (!strcmp(cmd, "end")) {
            ended = 1;
        } else {
            fprintf(stderr, "test_cam: what is \"%s\"?\n", line);
            return 2;
        }
        timeouts += timed_out;
        printf("test_cam: %7.3f %s%s\n", ts - t0, line, timed_out ? "  (TIMED OUT)" : "");
        fflush(stdout);
    }
    /* the viewer may end inside the last press (the quit): what is left must be only "end" */
    while (!ended && fgets(line, sizeof line, sf)) {
        line[strcspn(line, "\r\n#")] = 0;
        char cmd[32] = "";
        if (sscanf(line, "%31s", cmd) < 1) continue;
        if (!strcmp(cmd, "end")) ended = 1;
        else break;
    }
    fclose(sf);
    double t_end = wall();
    while (!client_done && wall() - t_end < 10.0) usleep(10000);
    int by_itself = client_done;
    if (!client_done) cam_test_stop();
    while (!client_done && wall() - t_end < 20.0) usleep(10000);
    if (client_done) pthread_join(pt, NULL);
    pthread_mutex_lock(&mx);
    core.stop = 1;
    pthread_mutex_unlock(&mx);
    pthread_join(ct, NULL);

    printf("test_cam: %u pictures in %u sessions; store rule broken %u; overlay descriptors %u (refused %u)\n",
           npic, core.nsess, pic_busy, core.ovl_taken, core.ovl_refused);
    CHECK("T2 the script ran to its end, no wait timed out", ended && !timeouts);
    CHECK("T3 the viewer ended by itself (Back + Start) within 10 s, returning 0", by_itself && client_rc == 0);
    CHECK("T4 every record header well formed", !core.bad_seen);
    CHECK("T5 every overlay descriptor accepted (the cards, the menu, the messages drawn)",
          core.ovl_shown > 0 && core.ovl_refused == 0);

    int m_start = mark("start"), m_raw = mark("raw"), m_rawgone = mark("rawgone"), m_live = mark("live"),
        m_menu = mark("menu"), m_small = mark("small"), m_pause = mark("pause"), m_resume = mark("resume"),
        m_unplug = mark("unplug"), m_replug = mark("replug"), m_quit = mark("quit"), m_flaky = mark("flaky"),
        m_flakyend = mark("flakyend");
    (void)m_start;
    /* C1: no device: a session, a card, no picture */
    CHECK("C1 with no camera: a session, the card drawn (an overlay shown), no picture",
          marks[m_raw].nsess >= 1 && marks[m_raw].npic == 0 && marks[m_raw].ovl_shown > 0);
    /* C6: the uncompressed-only device: refused -- no picture, never started, opened once, not retried */
    CHECK("C6a an uncompressed-only device past 6 MB/s: no picture, no stream started",
          marks[m_rawgone].npic == marks[m_raw].npic && marks[m_rawgone].starts == marks[m_raw].starts);
    printf("test_cam: the uncompressed-only device: tried %u times, %u streams started, opened %u times\n",
           marks[m_rawgone].tries - marks[m_raw].tries, marks[m_rawgone].starts - marks[m_raw].starts,
           marks[m_rawgone].opens - marks[m_raw].opens);
    CHECK("C6b the refused device is tried once, not again while it stays plugged in",
          marks[m_rawgone].tries - marks[m_raw].tries == 1);
    /* C2: the camera: the best SD mode, LOW_LATENCY, no PTS, the committed rate */
    {
        unsigned ok = 0, n = 0, ll = 0, nopts = 0;
        for (unsigned i = marks[m_live].npic; i < marks[m_menu].npic; i++) {
            n++;
            ok += pics[i].width == 640 && pics[i].height == 480 && pics[i].fps > 29.99 && pics[i].fps < 30.01;
            ll += (pics[i].flags & H264RING_F_LOW_LATENCY) != 0;
            nopts += !(pics[i].flags & H264RING_F_PTS_VALID);
        }
        printf("test_cam: live %u pictures, %u at 640x480 30/s, %u LOW_LATENCY, %u without a PTS\n", n, ok, ll, nopts);
        CHECK("C2 the camera's best SD mode (640x480 MJPEG, not the 1280x720 or YUY2) at its rate, LOW_LATENCY, no PTS",
              n >= 20 && ok == n && ll == n && nopts == n);
    }
    /* C3: the pictures are the camera's frames, in order; (0.16, docs/colour.md D-C8) full range sent as it
     * is, tagged BT.601 full (colour 2): the core converts it, not the ARM */
    {
        unsigned n = 0, known = 0, fixed_ok = 0, back = 0, col_ok = 0;
        int last = -1;
        for (unsigned i = marks[m_live].npic; i < marks[m_menu].npic; i++) {
            n++;
            int f = pic_frame(&pics[i], 0);
            known += f >= 0;
            fixed_ok += abs(pics[i].y_fixed - 235) <= 3;
            col_ok += pics[i].colour == H264RING_COLOUR_601_FULL;
            if (f >= 0 && last >= 0 && f == last) back++;     /* the same frame twice: a store shown again */
            if (f >= 0) last = f;
        }
        printf("test_cam: content: %u of %u pictures a known frame, %u with the fixed block full range, %u tagged 601 full, %u repeats\n",
               known, n, fixed_ok, col_ok, back);
        CHECK("C3 each picture one of the camera's frames, full range sent as it is and tagged BT.601 full (0.16), never the same twice in a row",
              n > 0 && known == n && fixed_ok == n && col_ok == n && back == 0);
    }
    /* C4: the menu: 320x240 chosen, its committed 25 frames a second sent, a new stream */
    {
        unsigned n = 0, ok = 0;
        for (unsigned i = marks[m_small].npic; i < marks[m_pause].npic; i++) {
            n++;
            ok += pics[i].width == 320 && pics[i].height == 240 && pics[i].fps > 24.99 && pics[i].fps < 25.01;
        }
        printf("test_cam: after the menu %u pictures, %u at 320x240 25/s\n", n, ok);
        CHECK("C4 the menu's choice streamed: 320x240 at the 25 frames a second the device committed, in a new stream",
              n >= 10 && ok == n && marks[m_small].nsess > marks[m_menu].nsess);
    }
    /* C9: pause: nothing written while the core is paused (the frames taken and let go) */
    printf("test_cam: pause: %u pictures consumed while paused, %u bytes written while paused, resumes %u\n",
           marks[m_resume].npic - marks[m_pause].npic, core.pending_at_resume, core.resumes);
    CHECK("C9 paused: the core paused (word 34) and nothing written until it resumed",
          core.resumes >= 1 && core.pending_at_resume == 0 && marks[m_resume].npic == marks[m_pause].npic);
    /* C5: unplugged mid-stream: a new stream (the last picture gone), nothing in it until the replug */
    {
        unsigned after = 0;
        for (unsigned i = marks[m_unplug].npic; i < npic; i++) after += pics[i].sess > (int)marks[m_unplug].nsess;
        CHECK("C5 an unplug flushes the stream (a new one, no picture in it) and the camera plays again when plugged back",
              marks[m_replug].nsess > marks[m_unplug].nsess && marks[m_replug].npic == marks[m_unplug].npic &&
              after >= 10 && marks[m_quit].npic > marks[m_replug].npic);
    }
    /* C10: a device whose best mode fails to start: the next mode instead */
    {
        unsigned n = 0, ok = 0;
        for (unsigned i = marks[m_flaky].npic; i < marks[m_flakyend].npic; i++) {
            n++;
            ok += pics[i].width == 320 && pics[i].height == 240;
        }
        printf("test_cam: the flaky camera: %u pictures, %u at 320x240, %u starts tried\n", n, ok,
               marks[m_flakyend].starts - marks[m_quit].starts);
        CHECK("C10 a camera whose best mode fails to start shows its next mode (320x240), not a refusal",
              n >= 10 && ok == n && marks[m_flakyend].starts - marks[m_quit].starts >= 2);
    }
    /* C8: the store rule across every boundary (mode change, unplug, replug) */
    CHECK("C8 the store rule: no picture into a store the display held", npic > 50 && pic_busy == 0);
    printf("test_cam: %s\n", fails ? "FAILURES" : "ALL GREEN");
    h264ring_close(client_test_ring);
    return fails ? 1 : 0;
}
