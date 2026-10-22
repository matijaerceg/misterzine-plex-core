/* SPDX-License-Identifier: GPL-3.0-or-later */
/* cam -- the USB camera viewer: a UVC camera or capture device shown through the H264 core
 * (docs/uvc.md U6). Started from MiSTer's Scripts menu (Scripts/h264cam.sh), it loads the core and
 * waits for a device; each frame is decoded here (MJPEG) or repacked (YUY2), copied into one of the
 * core's picture stores and sent as a PICTURE record, LOW_LATENCY (interface 0.15).
 *   states: WAIT (a card: plug a camera in), LIVE (the picture; A pauses, B / the OSD's "Program
 *   menu" opens the mode list), MENU (the list over the picture), REFUSED (a card: why this device
 *   cannot be shown, until it is unplugged). Back + Start quits from any of them.
 * The mode: the best the device offers inside the ARM's budget (U2) -- MJPEG first, at most 720 x 576,
 * at most 30 frames a second, uncompressed only up to the 6 MB/s the USB host carries (U2b). The library is this
 * loop's alone; libusb's thread touches only uvc.c's assembler. */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>
#include "core.h"
#include "input.h"
#include "ui.h"
#include "uvc.h"

#define SD_W        720u
#define SD_H        576u
#define MAX_RATE    333333u                     /* 30 frames a second: the shortest interval taken */
#define SCAN_MS     1000u                       /* WAIT: a device looked for this often */
#define MAX_ROWS    32u
#define DEC_FAIL_MS 3000u                       /* no frame decoded for this long: the device is refused */

enum cam_state { C_WAIT, C_LIVE, C_MENU, C_REFUSED };

struct cand { const struct uvc_mode *m; uint32_t interval; };

struct cam {
    struct core core;
    struct ui *ui;
    struct cl_input in;
    enum cam_state state;
    struct uvc_dev *dev;
    char dev_name[96], menu_title[112];         /* "vvvv:pppp Product"; "Product (vvvv:pppp)" */
    struct cand cand[MAX_ROWS];
    unsigned n_cand, cur;                       /* the device's usable modes, best first; the one streaming */
    uint32_t interval;                          /* the committed one */
    char refused_name[96];                      /* REFUSED: the device, until it is gone */
    char why[160];
    int paused;
    uint64_t scan_ms, last_ok_ms;
    AVCodecContext *av;
    AVFrame *fr;
    AVPacket *pkt;
    uint8_t *planar;
    size_t planar_n;
    char rowtext[MAX_ROWS][64];
    const char *rows[MAX_ROWS];
    unsigned sel;
    struct { uint64_t shown, no_store, ring_full, dec_err, unplugs; } n;
};

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

static const char *fourcc_name(uint32_t f) { return f == UVC_MJPG ? "MJPEG" : f == UVC_YUY2 ? "YUY2" : "?"; }

/* the shortest interval no faster than 30 frames a second, or 0 (the mode only goes faster) */
static uint32_t slowest_ok(const struct uvc_mode *m)
{
    uint32_t best = 0;
    if (m->n_int) {
        for (unsigned i = 0; i < m->n_int; i++)
            if (m->intervals[i] >= MAX_RATE && (!best || m->intervals[i] < best)) best = m->intervals[i];
    } else if (m->int_max >= MAX_RATE) {
        best = uvc_pick_interval(m, m->int_min > MAX_RATE ? m->int_min : MAX_RATE);
        if (best < MAX_RATE) best = m->int_max;
    }
    return best;
}

/* the modes this viewer shows, best first: MJPEG before YUY2, then the larger, then the faster */
static void list_modes(struct cam *c)
{
    unsigned n;
    const struct uvc_mode *ms = uvc_modes(c->dev, &n);
    c->n_cand = 0;
    for (unsigned i = 0; i < n; i++) {
        const struct uvc_mode *m = &ms[i];
        if (m->fourcc != UVC_MJPG && m->fourcc != UVC_YUY2) continue;
        if (m->width > SD_W || m->height > SD_H || m->width < 16 || m->height < 16) continue;
        uint32_t iv = slowest_ok(m);
        if (!iv || !uvc_mode_fits(m, iv)) continue;
        if (c->n_cand < MAX_ROWS) c->cand[c->n_cand++] = (struct cand){ m, iv };
    }
    for (unsigned i = 1; i < c->n_cand; i++)        /* insertion sort: a few dozen at most */
        for (unsigned j = i; j > 0; j--) {
            const struct cand *a = &c->cand[j - 1], *b = &c->cand[j];
            unsigned aa = (unsigned)a->m->width * a->m->height, ba = (unsigned)b->m->width * b->m->height;
            int better = (b->m->fourcc == UVC_MJPG) != (a->m->fourcc == UVC_MJPG) ? b->m->fourcc == UVC_MJPG
                       : ba != aa ? ba > aa : b->interval < a->interval;
            if (!better) break;
            struct cand t = c->cand[j - 1]; c->cand[j - 1] = c->cand[j]; c->cand[j] = t;
        }
}

/* why a device offers nothing this viewer can show (REFUSED's card) */
static void why_none(struct cam *c)
{
    unsigned n, mj = 0, yu = 0, h264 = 0;
    const struct uvc_mode *ms = uvc_modes(c->dev, &n);
    for (unsigned i = 0; i < n; i++) {
        mj += ms[i].fourcc == UVC_MJPG;
        yu += ms[i].fourcc == UVC_YUY2;
        h264 += ms[i].fourcc == UVC_H264;
    }
    if (!n) snprintf(c->why, sizeof c->why, "it describes no video formats");
    else if (!mj && !yu) snprintf(c->why, sizeof c->why, "its video is %s, not MJPEG or uncompressed", h264 ? "H.264 only" : "in a format the viewer does not read");
    else if (!mj) snprintf(c->why, sizeof c->why, "it sends only uncompressed video, which needs more USB bandwidth than the MiSTer's port carries at these sizes");
    else snprintf(c->why, sizeof c->why, "none of its modes fits: 720 x 576 at most, 30 frames a second at most");
}

static void close_decoder(struct cam *c)
{
    if (c->av) avcodec_free_context(&c->av);
}

static int open_decoder(struct cam *c)
{
    close_decoder(c);
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_MJPEG);
    if (!codec || !(c->av = avcodec_alloc_context3(codec))) return -1;
    c->av->thread_count = 1;
    return avcodec_open2(c->av, codec, NULL) < 0 ? -1 : 0;
}

/* stream mode k: 0, or -errno */
static int start_mode(struct cam *c, unsigned k)
{
    char info[256];
    uvc_stop(c->dev);
    const struct cand *cd = &c->cand[k];
    int rc = uvc_start(c->dev, cd->m, cd->interval, &c->interval, info, sizeof info);
    if (rc) {
        fprintf(stderr, "h264cam: %ux%u %s: %s\n", cd->m->width, cd->m->height, fourcc_name(cd->m->fourcc),
                strerror(-rc));
        return rc;
    }
    c->cur = k;
    c->last_ok_ms = now_ms();
    if (cd->m->fourcc == UVC_MJPG && open_decoder(c)) return -ENOMEM;
    fprintf(stderr, "h264cam: streaming %s\n", info);
    return 0;
}

static void show_card(struct cam *c)
{
    struct ui_card k = { "USB camera", "", "", "Back + Start: quit", "" };
    if (c->state == C_WAIT) {
        k.line = "Plug in a USB camera or video capture device";
    } else if (c->state == C_REFUSED) {
        static char line[300];
        snprintf(line, sizeof line, "%s cannot be shown: %s", c->refused_name, c->why);
        k.line = line;
        k.note = "Unplug it, or plug in another";
    }
    ui_card(c->ui, c->state == C_WAIT || c->state == C_REFUSED ? &k : NULL);
}

static void enter(struct cam *c, enum cam_state s)
{
    c->state = s;
    c->in.nav = s == C_MENU;
    ui_list(c->ui, NULL);
    show_card(c);
    ui_activity(c->ui);
    fprintf(stderr, "h264cam: state %s\n", s == C_WAIT ? "wait" : s == C_LIVE ? "live" : s == C_MENU ? "menu" : "refused");
}

static void drop_device(struct cam *c)
{
    if (!c->dev) return;
    uvc_close(c->dev);
    c->dev = NULL;
    close_decoder(c);
}

/* a device found: its best mode that streams, or REFUSED */
static void try_device(struct cam *c)
{
    snprintf(c->dev_name, sizeof c->dev_name, "%s", uvc_name(c->dev));
    const char *sp = strchr(c->dev_name, ' ');          /* "vvvv:pppp Product": the product */
    const char *shown = sp && sp[1] ? sp + 1 : c->dev_name;
    snprintf(c->menu_title, sizeof c->menu_title, "%s (%.9s)", shown, c->dev_name);
    fprintf(stderr, "h264cam: device %s\n", c->dev_name);
    list_modes(c);
    int rc = -ENODEV;
    uvc_fixed_rate(c->dev);                              /* a constant frame rate where it has the control */
    for (unsigned k = 0; k < c->n_cand && rc; k++)
        rc = start_mode(c, k);
    if (rc) {
        if (!c->n_cand) why_none(c);
        else snprintf(c->why, sizeof c->why, "it did not start streaming in any of its modes");
        snprintf(c->refused_name, sizeof c->refused_name, "%s", shown);
        fprintf(stderr, "h264cam: refused %s: %s\n", c->dev_name, c->why);
        drop_device(c);
        enter(c, C_REFUSED);
        return;
    }
    char text[128];
    const struct cand *cd = &c->cand[c->cur];
    snprintf(text, sizeof text, "%u x %u, %.0f frames a second", cd->m->width, cd->m->height, 1e7 / c->interval);
    ui_message(c->ui, shown, text, 3000);
    c->paused = 0;
    enter(c, C_LIVE);
}

/* WAIT / REFUSED: look for a device now and then */
static void scan(struct cam *c)
{
    if (now_ms() - c->scan_ms < SCAN_MS) return;
    c->scan_ms = now_ms();
    struct uvc_dev *d = NULL;
    if (uvc_open(&d, -1, -1)) {                          /* none: a refused one has gone */
        if (c->state == C_REFUSED) { c->refused_name[0] = 0; enter(c, C_WAIT); }
        return;
    }
    if (c->state == C_REFUSED) {                          /* the refused one still there: keep the card */
        uvc_close(d);
        return;
    }
    c->dev = d;
    try_device(c);
}

/* the camera is gone (or failed): its stream ends, the card again */
static void unplugged(struct cam *c)
{
    fprintf(stderr, "h264cam: the device stopped (unplugged?)\n");
    c->n.unplugs++;
    drop_device(c);
    if (c->paused) h264ring_set_pause(c->core.r, 0);
    c->paused = 0;
    core_new_stream(&c->core);                            /* the last picture goes: black, then the card */
    ui_message(c->ui, "Camera unplugged", "Plug it in again to carry on", 4000);
    c->scan_ms = now_ms();
    enter(c, C_WAIT);
}

/* the store copy's format for a decoded frame, -1 one it does not take */
static int frame_fmt(const AVFrame *f)
{
    int full = f->color_range == AVCOL_RANGE_JPEG;
    switch (f->format) {
    case AV_PIX_FMT_YUVJ420P: return H264RING_PIX_YUVJ420P;
    case AV_PIX_FMT_YUVJ422P: return H264RING_PIX_YUVJ422P;
    case AV_PIX_FMT_YUV420P: return full ? H264RING_PIX_YUVJ420P : H264RING_PIX_YUV420P;
    case AV_PIX_FMT_YUV422P: return full ? H264RING_PIX_YUVJ422P : H264RING_PIX_YUV422P;
    default: return -1;
    }
}

/* LIVE / MENU: the newest frame, if any, into a store and the ring */
static void pump(struct cam *c)
{
    const uint8_t *data;
    size_t len;
    int rc = uvc_take(c->dev, &data, &len, 0);
    if (rc == -EIO) { unplugged(c); return; }
    if (rc) {
        if (now_ms() - c->last_ok_ms > DEC_FAIL_MS && c->n.dec_err) {
            snprintf(c->why, sizeof c->why, "its pictures could not be decoded");
            const char *sp = strchr(c->dev_name, ' ');
            snprintf(c->refused_name, sizeof c->refused_name, "%s", sp && sp[1] ? sp + 1 : c->dev_name);
            drop_device(c);
            core_new_stream(&c->core);
            enter(c, C_REFUSED);
        }
        return;
    }
    if (c->paused) return;                                  /* held: frames taken and let go */
    const struct uvc_mode *m = c->cand[c->cur].m;
    const uint8_t *planes[3];
    int strides[3], fmt;
    unsigned w = m->width, h = m->height;
    if (m->fourcc == UVC_MJPG) {
        c->pkt->data = (uint8_t *)data;                     /* the assembler pads past the end */
        c->pkt->size = (int)len;
        if (avcodec_send_packet(c->av, c->pkt) < 0 || avcodec_receive_frame(c->av, c->fr) < 0 ||
            (fmt = frame_fmt(c->fr)) < 0) {
            c->n.dec_err++;
            return;
        }
        w = (unsigned)c->fr->width;
        h = (unsigned)c->fr->height;
        for (int i = 0; i < 3; i++) { planes[i] = c->fr->data[i]; strides[i] = c->fr->linesize[i]; }
    } else {                                                /* YUY2 (Y0 U Y1 V) -> planar 4:2:2, limited */
        size_t need = (size_t)w * h * 2u;
        if (c->planar_n < need) { free(c->planar); c->planar = malloc(need); c->planar_n = c->planar ? need : 0; }
        if (!c->planar) return;
        uint8_t *y = c->planar, *u = y + (size_t)w * h, *v = u + (size_t)w * h / 2u;
        const uint8_t *s = data;
        planes[0] = y; planes[1] = u; planes[2] = v;
        for (size_t i = 0; i < (size_t)w * h / 2u; i++, s += 4) { *y++ = s[0]; *u++ = s[1]; *y++ = s[2]; *v++ = s[3]; }
        strides[0] = (int)w; strides[1] = strides[2] = (int)w / 2;
        fmt = H264RING_PIX_YUV422P;
    }
    c->last_ok_ms = now_ms();
    struct h264ring_picture pic;
    unsigned k;
    memset(&pic, 0, sizeof pic);
    pic.width = w;
    pic.height = h;
    pic.structure = H264RING_PIC_STRUCT_FRAME;
    pic.pic_struct = -1;
    pic.rate_num = 10000000u;                               /* the committed interval (100 ns units) */
    pic.rate_den = c->interval;
    /* (0.16, docs/colour.md D-C8) MJPEG is full range, JFIF's BT.601: sent as it is, the core converts it (no
     * conversion on the ARM); YUY2 limited: auto (BT.601 at these sizes) */
    pic.colour = (fmt == H264RING_PIX_YUVJ420P || fmt == H264RING_PIX_YUVJ422P) ? H264RING_COLOUR_601_FULL
                                                                                : H264RING_COLOUR_AUTO;
    rc = h264ring_picture_acquire(c->core.r, &k);
    if (rc == -EAGAIN) { c->n.no_store++; return; }         /* every store still shown: this frame dropped */
    if (rc) { fprintf(stderr, "h264cam: picture_acquire: %s\n", strerror(-rc)); return; }
    if (h264ring_picture_copy(h264ring_picture_store(c->core.r, k), &pic, planes, strides, (unsigned)fmt)) {
        fprintf(stderr, "h264cam: a %ux%u picture the core cannot show\n", w, h);
        return;
    }
    /* LOW_LATENCY, no PTS: the camera's clock is not ours (U4) */
    rc = h264ring_try_write_picture(c->core.r, k, &pic, -1, H264RING_F_LOW_LATENCY);
    if (rc == -EAGAIN) c->n.ring_full++;                    /* the store stays ours; a later frame takes another */
    else if (rc) fprintf(stderr, "h264cam: write_picture: %s\n", strerror(-rc));
    else c->n.shown++;
}

static void open_menu(struct cam *c)
{
    for (unsigned i = 0; i < c->n_cand; i++) {
        const struct cand *cd = &c->cand[i];
        snprintf(c->rowtext[i], sizeof c->rowtext[i], "%s%u x %u   %s   %.0f frames/s", i == c->cur ? "> " : "   ",
                 cd->m->width, cd->m->height, fourcc_name(cd->m->fourcc), 1e7 / cd->interval);
        c->rows[i] = c->rowtext[i];
    }
    c->sel = c->cur;
    enter(c, C_MENU);
}

static void show_menu(struct cam *c)
{
    struct ui_list l = { c->menu_title, "A: choose   B: back   Back + Start: quit", c->rows, c->n_cand, c->sel,
                         "No modes" };
    ui_list(c->ui, &l);
}

/* the menu's choice: the stream restarted at that mode (a new stream: its size may change) */
static void choose(struct cam *c, unsigned k)
{
    unsigned was = c->cur;
    if (k == was) { enter(c, C_LIVE); return; }
    core_new_stream(&c->core);
    if (c->paused) { h264ring_set_pause(c->core.r, 0); c->paused = 0; }
    int rc = start_mode(c, k);
    if (rc) {
        ui_message(c->ui, "That mode did not start", strerror(-rc), 4000);
        if (start_mode(c, was)) { unplugged(c); return; }
    } else {
        char text[128];
        snprintf(text, sizeof text, "%u x %u, %.0f frames a second", c->cand[k].m->width, c->cand[k].m->height,
                 1e7 / c->interval);
        ui_message(c->ui, "Mode", text, 2500);
    }
    enter(c, C_LIVE);
}

static void act(struct cam *c, enum cl_action a)
{
    fprintf(stderr, "h264cam: input: %s\n", input_action_name(a));
    if (a == ACT_STOP) { stop = 1; return; }
    if (c->state == C_LIVE) {
        if (a == ACT_PAUSE) {
            c->paused = !c->paused;
            /* the core holds the shown picture. On a resume this loop's pump() may write a picture before
             * any status shows the core running again: safe -- h264ring_picture_acquire reads a fresh
             * status itself, and a record written early simply waits in the ring */
            h264ring_set_pause(c->core.r, c->paused);
            ui_message(c->ui, c->paused ? "Paused" : "Live", c->paused ? "A: carry on" : "", c->paused ? 3600000u : 1000u);
        } else if (a == ACT_INFO) {
            open_menu(c);
        }
    } else if (c->state == C_MENU) {
        unsigned page = ui_list_rows(c->ui) ? ui_list_rows(c->ui) : 1u;
        switch (a) {
        case ACT_UP: if (c->sel) c->sel--; break;
        case ACT_DOWN: if (c->sel + 1 < c->n_cand) c->sel++; break;
        case ACT_PAGE_UP: c->sel = c->sel > page ? c->sel - page : 0; break;
        case ACT_PAGE_DOWN: c->sel = c->sel + page < c->n_cand ? c->sel + page : (c->n_cand ? c->n_cand - 1 : 0); break;
        case ACT_OK: choose(c, c->sel); break;
        case ACT_CANCEL: enter(c, C_LIVE); break;
        default: break;
        }
    }
}

static void raster(const struct cam *c, unsigned *w, unsigned *h, double *aspect)
{
    *w = 720u; *h = 480u; *aspect = 4.0 / 3.0;
    if (!c->core.have_st) return;
    struct h264ring_raster rs;
    h264ring_raster(&c->core.st, &rs);
    if (rs.w) *w = rs.w;
    *h = rs.h ? rs.h : H264RING_ST(&c->core.st, RASTER_STD) == 2 ? 576u : 480u;
    *aspect = rs.aspect;
}

static int run(struct cam *c, const char *dir)
{
    if (core_open2(&c->core, getenv("H264CAM_RBF"), H264RING_OPEN_PICTURES)) return 1;
    if (ui_open(&c->ui, c->core.r, dir)) { core_close(&c->core); return 1; }
    ui_saver_times(c->ui, 5u * 60000u, 30u * 60000u);     /* the player's (P5): only while no camera shows */
    c->fr = av_frame_alloc();
    c->pkt = av_packet_alloc();
    enter(c, C_WAIT);
    while (!stop) {
        if (core_poll(&c->core)) break;                    /* another core was loaded */
        enum cl_action acts[16];
        unsigned na = input_poll(&c->in, c->core.r, acts, 16);
        for (unsigned i = 0; i < na && !stop; i++) {
            if (ui_wake(c->ui)) continue;                  /* the press only wakes the screensaver */
            act(c, acts[i]);
        }
        if (c->state == C_WAIT || c->state == C_REFUSED) scan(c);
        else pump(c);
        if (c->state == C_MENU) show_menu(c);
        ui_busy(c->ui, c->state == C_LIVE || c->state == C_MENU);
        unsigned w, h;
        double aspect;
        raster(c, &w, &h, &aspect);
        ui_draw(c->ui, w, h, aspect);
        usleep(2000);
    }
    fprintf(stderr, "h264cam: shown %llu, no store %llu, ring full %llu, undecodable %llu, unplugged %llu\n",
            (unsigned long long)c->n.shown, (unsigned long long)c->n.no_store, (unsigned long long)c->n.ring_full,
            (unsigned long long)c->n.dec_err, (unsigned long long)c->n.unplugs);
    if (c->paused && !c->core.gone) h264ring_set_pause(c->core.r, 0);
    drop_device(c);
    av_frame_free(&c->fr);
    av_packet_free(&c->pkt);
    free(c->planar);
    ui_close(c->ui);
    core_close(&c->core);
    return 0;
}

#ifdef CLIENT_TEST
void cam_test_stop(void) { stop = 1; }
#endif

/* h264cam [--dir DIR]: the viewer (DIR holds the typefaces; default: the binary's folder) */
int cam_main(int argc, char **argv)
{
    static char dir[4096];
    static struct cam c;
    av_log_set_level(AV_LOG_FATAL);                         /* Logitech's APP fields: an error line a frame */
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    stop = 0;
    memset(&c, 0, sizeof c);
    ssize_t n = readlink("/proc/self/exe", dir, sizeof dir - 1);
    dir[n > 0 ? n : 0] = 0;
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0; else snprintf(dir, sizeof dir, ".");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dir") && i + 1 < argc) snprintf(dir, sizeof dir, "%s", argv[++i]);
        else { fprintf(stderr, "usage: h264cam [--dir DIR]   (measuring: h264cam --stage ..., --help)\n"); return 2; }
    }
    return run(&c, dir);
}
