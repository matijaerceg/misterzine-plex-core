/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/player/tests/test_player.c -- the file player (src/ + ../common/, built with
 * -DCLIENT_TEST) against a fake core on its own thread, driven by a scripted pad.
 *
 *   test_player TESTDIR ROOT OUT TIMEOUT_S
 *
 * The player runs as player_main("--dir", TESTDIR, "--root", ROOT) on a thread (TESTDIR holds the
 * two typefaces; ROOT the fixtures' folder). The fake core is the Jellyfin client's
 * (clients/jellyfin/tests/test_client.c: the nonce, the read index, the seqlocked status block,
 * records consumed whole, its STC at HALF real speed from a session's first PTS, frozen by word
 * 34's PAUSE, LIVE ENDED once END_OF_STREAM is consumed and the clock has passed the latest PTS,
 * the overlay's descriptor taken), plus what a file player needs:
 *   - the settings request (program word 35, docs/architecture.md "The settings request"): a new
 *     sequence number is consumed -- the options its mask selects copied into word 27's mirror,
 *     SET_SEQ / SET_ERR 0 in words 30 / 27 -- and a Refresh Rate of 50 Hz switches the raster to
 *     576 lines (RASTER_STD 2), as the core's does; every request logged;
 *   - the pad: TESTDIR/script, one command a line, run in order (each logged with its time):
 *       sleep S            wait S seconds
 *       press B[+B...]     pad 0: the buttons down (60 ms and two of the player's loops), then up
 *                          (the same): A B X Y LB RB UP DOWN LEFT RIGHT START BACK
 *       wait_played N      until N sessions have consumed at least one record
 *       wait_stc S         until the current session's clock is S seconds past its anchor
 *       wait_ended         until the current session's stream ended (LIVE ENDED), or one ended since
 *                          the wait began (a folder's end opens a new session the moment the last
 *                          file's ENDED is read: a 2 ms poll can miss so short an ENDED)
 *       end                the script is done: the player must now end by itself
 *     Every wait has a timeout (20 s) that is logged and moves on, so a mutant still finishes.
 * Written to OUT/ for check_player.py (times are CLOCK_REALTIME):
 *   sNN.stream     session NN's consumed bytes (u32 start index, then the bytes)
 *   sessions.txt   idx nonce t_start t_anchor anchor_pts bytes records t_first t_last first_type dropped
 *   stc.txt        every 5 ms: t sess run paused ended stc
 *   settings.txt   each request consumed: t seq mask refresh
 *   script.txt     each command: t_start t_end timed_out command
 *   final.txt      the mirror's Refresh Rate at the end
 *   pics.bin       (0.15) every PICTURE consumed: {u32 session, u32 flags (0.16: [18:16] the colour code), u64 PTS,
 *                  u64 desc[4], u32 bytes}
 *                  and the store's image as the core read it then (Y, Cb, Cr: 384 w_mbs hf_mbs bytes)
 * (0.15) Pictures from the program: the backend carries the stores (40 MiB); the state reads READY
 * until a session's first video record; a PICTURE is consumed with its store's image and queued on a
 * stand-in display that shows each when the clock reaches its PTS (at once without one) and releases
 * the store it showed before -- word 84 (pic_held, pic_emitted, cap_pic_stores) from it, and a
 * PICTURE naming a store the display holds counted (the store rule broken: T10).
 * and prints its own PASS / FAIL lines, then "test_player: ALL GREEN". */
#include "h264ring.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define RING      (1u << 20)
#define MAXSESS   64
#define MAXSAMP   (1u << 16)
#define MAXEV     4096
#define STEP_US   200
#define SAMPLE_US 5000
#define PRESS_US  60000u
#define WAIT_S    20.0
#define RASTER_NATIVE_W 852u

extern h264ring *client_test_ring;
extern void *client_test_fb;            /* the player's overlay pages (ui.c, CLIENT_TEST) */
int player_main(int argc, char **argv);
void player_test_stop(void);

static int fails;
#define CHECK(label, cond) do { int ok_ = (cond); printf("  %s %s\n", ok_ ? "PASS" : "FAIL", label); \
                                if (!ok_) fails++; } while (0)

static double wall(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static uint64_t mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

/* ---- the fake core ---- */
static uint64_t ctrl[512];
static uint64_t *ringmem;
static pthread_mutex_t core_mx = PTHREAD_MUTEX_INITIALIZER;

/* (0.15) the stores, and the stand-in display's queue (emitted, not yet shown) and shown store */
static uint64_t *stores;
static struct { int store, ptsv; uint64_t pts; } dq[64];
static unsigned dq_h, dq_t;
static int shown = -1;
static uint32_t pic_emitted, pic_busy, pics_consumed;
static FILE *pics_f;

struct sess {
    uint32_t start, nonce;
    double t_start, t_anchor;
    uint64_t anchor_pts;
    unsigned records, first_type;
    double t_first, t_last;
    uint32_t dropped;
    uint8_t *b;
    size_t n, cap;
};
static struct sess sessions[MAXSESS];
static int nsess;

static struct {
    int booted, sess, stop, run, paused, eos, ended, bad_header, bad_seen;
    unsigned n_ended;                 /* sessions whose stream ended (wait_ended's latch) */
    int vrec, pic_mode;                 /* (0.15) a video record this session; its first was a PICTURE */
    uint32_t seen, rw, seq, ack, w34;
    uint64_t anchor_pts, run_us, last_us, stc;
    int64_t max_pts;
    uint32_t ovl_gen;
    int ovl_state, ovl_refused;
    unsigned ovl_taken;
    /* the OSD mirror and the settings request */
    unsigned osd[H264RING_OPT_COUNT];
    unsigned set_seq;
} core;

static struct { double t; int sess, run, paused, ended; uint64_t stc; } samp[MAXSAMP];
static unsigned nsamp;
static uint64_t samp_last_us;
static struct { double t; unsigned seq, mask, refresh; } set_ev[MAXEV];
static unsigned nset;
static struct { double t; uint32_t gen; int en, corner, corner_r; unsigned w, raster_w, h, stride;
                uint32_t base; } ovl_ev[MAXEV];
static unsigned novl;

/* the pad: one press at a time (set by main under core_mx, run by the core thread) */
static struct {
    int active;
    unsigned phase;            /* 0 down, 1 up */
    uint32_t buttons, pad0, seq;
    uint64_t t_edge;
    unsigned polls_edge;
} inj;

/* the player's loop calls usleep once an iteration: counted on its thread */
static pthread_t client_tid;
static volatile int client_tid_set;
static unsigned client_polls;
/* the loop's stalls: the time between one usleep's return and the next call, when over 250 ms
 * (the Jellyfin test's instrument): with every video write made slow (client_test_write_us: the
 * A9's CAVLC rewrite), a step that writes until a packet count rather than a time budget holds the
 * loop -- the pad unread -- for most of a second (check (w)) */
#define GAP_S 0.25
static struct { double from, to; } gaps[MAXEV];
static unsigned ngaps;
static double last_sleep_end;
static double wall(void);
int usleep(useconds_t us)
{
    int mine = client_tid_set && pthread_equal(pthread_self(), client_tid);
    if (mine) {
        __atomic_add_fetch(&client_polls, 1, __ATOMIC_RELAXED);
        double t = wall();
        if (last_sleep_end > 0 && t - last_sleep_end > GAP_S && ngaps < MAXEV) {
            gaps[ngaps].from = last_sleep_end;
            gaps[ngaps++].to = t;
        }
    }
    struct timespec ts = { (time_t)(us / 1000000u), (long)(us % 1000000u) * 1000L };
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
    if (mine) last_sleep_end = wall();
    return 0;
}

static uint32_t lo(unsigned w) { return (uint32_t)ctrl[w]; }

static void put(unsigned w, unsigned lsb, unsigned width, uint64_t v)
{
    uint64_t m = width >= 64 ? ~0ull : ((1ull << width) - 1u);
    ctrl[w] = (ctrl[w] & ~(m << lsb)) | ((v & m) << lsb);
}
#define PUT(F, v) put(H264RING_##F##_W, H264RING_##F##_LSB, H264RING_##F##_WIDTH, (v))

static void core_status(void)                       /* the seqlock: head first, tail last */
{
    core.seq++;
    put(3, 0, 32, core.seq);
    __sync_synchronize();
    ctrl[0] = H264RING_MAGIC;
    ctrl[1] = H264RING_VERSION | ((uint64_t)H264RING_CORE_WORDS << 16) | ((uint64_t)H264RING_PROG_WORD << 32) |
              ((uint64_t)H264RING_CORE2_WORD << 48);
    ctrl[2] = H264RING_RING_BYTE | ((uint64_t)RING << 32);
    put(3, 32, 32, H264RING_MAX_PAYLOAD);
    PUT(STATE, !core.sess ? H264RING_S_NO_SESSION : core.ended ? H264RING_S_ENDED :
               core.vrec ? H264RING_S_PLAYING : H264RING_S_READY);
    {   /* (0.15) word 84 from the stand-in display */
        uint32_t held = shown >= 0 ? 1u << shown : 0u;
        for (unsigned i = dq_h; i != dq_t; i++) held |= 1u << dq[i % 64].store;
        PUT(PIC_HELD, held);
        PUT(PIC_MODE, core.pic_mode);
        PUT(CAP_PIC_STORES, H264RING_DPB_STORES);
        PUT(PIC_EMITTED, pic_emitted);
    }
    PUT(LIVE, (core.sess ? H264RING_L_SESSION : 0) | (core.run ? H264RING_L_STC_RUN : 0) |
              (core.eos ? H264RING_L_EOS : 0) | (core.ended ? H264RING_L_ENDED : 0) |
              (core.run ? H264RING_L_PLAYED : 0));
    ctrl[5] = core.rw | ((uint64_t)core.ack << 32);
    PUT(STC, core.stc);
    PUT(PAUSED, core.paused);
    PUT(ATTEN, (core.w34 >> H264RING_CTL_ATTEN_LSB) & 0xFFu);
    PUT(OVL_GEN, core.ovl_gen);
    PUT(OVL_STATE, core.ovl_state);
    PUT(CAP_MAX_MBS, 3600);                       /* (0.11) word 81: the real core's constants */
    PUT(CAP_NATIVE_H, 480);
    PUT(CAP_MB_RATE, 108000);
    PUT(OSD_ASPECT, core.osd[H264RING_OPT_ASPECT]);
    PUT(OSD_DEINT, core.osd[H264RING_OPT_DEINTERLACE]);
    PUT(OSD_VIDEO_OUT, core.osd[H264RING_OPT_VIDEO_OUTPUT]);
    PUT(OSD_HDMI_DEINT, core.osd[H264RING_OPT_HDMI_DEINTERLACE]);
    PUT(OSD_ANALOG_ASPECT, core.osd[H264RING_OPT_ANALOG_ASPECT]);
    PUT(OSD_REFRESH, core.osd[H264RING_OPT_REFRESH_RATE]);
    PUT(OSD_ANTI_TWITTER, core.osd[H264RING_OPT_ANTI_TWITTER]);
    PUT(SET_SEQ, core.set_seq);
    PUT(SET_ERR, 0);
    PUT(RASTER_STD, core.osd[H264RING_OPT_REFRESH_RATE] == 3 ? 2u : 0u);
    /* (0.10) word 80 / 47: at 59.94 / 60 Hz the raster a 16:9 film's Video Output "Native (HDMI)"
     * gives (852 x 480, shown 16:9), at 50 Hz the fitted 720 x 576 -- so the canvas is drawn for
     * two widths, neither the one a client might assume (T7, (z1)'s right edge) */
    int pal = core.osd[H264RING_OPT_REFRESH_RATE] == 3;
    PUT(RASTER_W, pal ? 720u : RASTER_NATIVE_W);
    PUT(RASTER_H, pal ? 576u : 480u);
    PUT(RASTER_MODE, pal ? H264RING_RASTER_FITTED : H264RING_RASTER_NATIVE);
    PUT(AR_X, 16u); PUT(AR_Y, 9u);
    __sync_synchronize();
    put(31, 0, 32, core.seq);
}

/* the input region as the core writes it: in_head first, the words, in_tail last */
static void input_write(uint32_t pad0)
{
    inj.seq++;
    put(H264RING_IN_HEAD_W, H264RING_IN_HEAD_LSB, H264RING_IN_HEAD_WIDTH, inj.seq);
    __sync_synchronize();
    put(H264RING_PAD0_JOY_W, H264RING_PAD0_JOY_LSB, H264RING_PAD0_JOY_WIDTH, pad0);
    __sync_synchronize();
    put(H264RING_IN_TAIL_W, H264RING_IN_TAIL_LSB, H264RING_IN_TAIL_WIDTH, inj.seq);
}

/* a press: down for PRESS_US and two of the player's loops, then up as long */
static void input_step(uint64_t now)
{
    if (!inj.active) return;
    unsigned polls = __atomic_load_n(&client_polls, __ATOMIC_RELAXED);
    if (now - inj.t_edge >= PRESS_US && polls - inj.polls_edge >= 2) {
        inj.phase++;
        inj.t_edge = now;
        inj.polls_edge = polls;
    }
    uint32_t pad0 = inj.phase == 0 ? inj.buttons : 0u;
    if (pad0 != inj.pad0) { inj.pad0 = pad0; input_write(pad0); }
    if (inj.phase >= 2) inj.active = 0;
}

/* the settings request: a new sequence number consumed, the mirror updated (docs/architecture.md) */
static void settings_step(void)
{
    static const unsigned width[H264RING_OPT_COUNT] = {2, 2, 2, 1, 2, 2, 2};
    uint32_t w = lo(H264RING_W_SETTINGS);
    unsigned seq = w >> H264RING_REQ_SEQ_LSB, mask = (w >> H264RING_REQ_MASK_LSB) & ((1u << H264RING_OPT_COUNT) - 1u);
    if (!seq || seq == core.set_seq) return;
    unsigned lsb = 0;
    for (unsigned i = 0; i < H264RING_OPT_COUNT; i++) {
        if (mask >> i & 1u) core.osd[i] = (w >> lsb) & ((1u << width[i]) - 1u);
        lsb += width[i];
    }
    core.set_seq = seq;
    if (nset < MAXEV) {
        set_ev[nset].t = wall();
        set_ev[nset].seq = seq;
        set_ev[nset].mask = mask;
        set_ev[nset++].refresh = core.osd[H264RING_OPT_REFRESH_RATE];
    }
}

static void sess_append(struct sess *s, uint32_t from, uint32_t n)
{
    if (s->n + n > s->cap) {
        while (s->n + n > s->cap) s->cap = s->cap ? 2 * s->cap : (1u << 22);
        s->b = realloc(s->b, s->cap);
    }
    for (uint32_t i = 0; i < n; i++, from++)
        s->b[s->n++] = (uint8_t)(ringmem[(from % RING) / 8] >> (8 * (from % 8)));
}

static void consume(uint32_t wi)
{
    struct sess *s = &sessions[nsess - 1];
    while (core.rw != wi && !core.bad_header) {
        uint32_t avail = wi - core.rw;
        if (avail < 16) break;
        uint64_t w0 = ringmem[(core.rw % RING) / 8], w1 = ringmem[((core.rw + 8) % RING) / 8];
        unsigned type = (unsigned)(w0 & 0xFF), flags = (unsigned)((w0 >> 8) & 0xFF);
        uint32_t len = (uint32_t)(w0 >> 32);
        uint32_t n = 16u + ((len + 15u) & ~15u);
        if (type < H264RING_T_PAD || type > H264RING_T_PICTURE || type == H264RING_T_CONTROL ||
            (type == H264RING_T_PICTURE && len != H264RING_PIC_PAYLOAD) || (w1 >> 48) != H264RING_SYNC ||
            n > RING - core.rw % RING) {
            core.bad_header = core.bad_seen = 1;
            break;
        }
        if (n > avail) break;
        sess_append(s, core.rw, n);
        core.rw += n;
        s->t_last = wall();
        if (!s->records++) {
            s->t_first = s->t_last;
            s->first_type = type;
        }
        if (type == H264RING_T_PICTURE) {           /* (0.15) the store's image now, then the display's queue */
            uint64_t d[4];
            for (unsigned k = 0; k < 4; k++) d[k] = ringmem[((core.rw - n + 16u + 8u * k) % RING) / 8];
            unsigned st = (unsigned)(d[0] & 31u), w = (unsigned)(d[0] >> 8) & 0xFFu, hf = (unsigned)(d[0] >> 16) & 0xFFu;
            uint32_t bytes = 384u * w * hf;
            uint32_t held = shown >= 0 ? 1u << shown : 0u;
            for (unsigned i = dq_h; i != dq_t; i++) held |= 1u << dq[i % 64].store;
            if (st >= H264RING_DPB_STORES || (held >> st & 1u)) pic_busy++;
            if (!core.vrec) core.pic_mode = 1;
            if (pics_f && st < H264RING_DPB_STORES) {
                uint32_t sn = (uint32_t)(nsess - 1), fl = flags | (uint32_t)((w1 >> 33) & 7u) << 16;   /* (0.16) */
                uint64_t pts = w1 & ((1ull << 33) - 1u);
                fwrite(&sn, 4, 1, pics_f); fwrite(&fl, 4, 1, pics_f); fwrite(&pts, 8, 1, pics_f);
                fwrite(d, 8, 4, pics_f); fwrite(&bytes, 4, 1, pics_f);
                fwrite((const uint8_t *)stores + (size_t)st * H264RING_DPB_STORE, 1, bytes, pics_f);
            }
            if (dq_t - dq_h < 64) {
                dq[dq_t % 64].store = (int)st;
                dq[dq_t % 64].ptsv = (flags & H264RING_F_PTS_VALID) != 0;
                dq[dq_t % 64].pts = w1 & ((1ull << 33) - 1u);
                dq_t++;
            }
            pic_emitted++;
            pics_consumed++;
        }
        if (type == H264RING_T_VIDEO_AU || type == H264RING_T_PICTURE) {
            core.vrec = 1;
            if (flags & H264RING_F_PTS_VALID) {
                int64_t pts = (int64_t)(w1 & ((1ull << 33) - 1u));
                if (!core.run) {
                    core.run = 1;
                    core.anchor_pts = (uint64_t)pts;
                    core.run_us = 0;
                    core.stc = core.anchor_pts;
                    s->t_anchor = wall();
                    s->anchor_pts = core.anchor_pts;
                }
                if (pts > core.max_pts) core.max_pts = pts;
            }
            if (flags & H264RING_F_END_OF_STREAM) core.eos = 1;
        }
    }
}

static void core_step(void)
{
    uint64_t now = mono_us();
    uint64_t dt = core.last_us ? now - core.last_us : 0;
    core.last_us = now;
    input_step(now);
    settings_step();
    uint32_t wi = lo(H264RING_W_WRITE_INDEX), nonce = lo(H264RING_W_NONCE);
    uint32_t w34 = lo(H264RING_W_PAUSE);
    core.w34 = w34;
    core.paused = core.sess && (w34 >> H264RING_CTL_PAUSE_BIT & 1u);
    if (!core.booted) {
        core.seen = nonce;
        core.booted = 1;
    } else if (nonce != core.seen) {
        if (core.sess && nsess > 0) sessions[nsess - 1].dropped = (wi & ~15u) - core.rw;
        core.seen = nonce;
        core.sess = 1;
        core.rw = wi & ~15u;
        core.ack = nonce;
        core.run = core.eos = core.ended = 0;
        core.vrec = core.pic_mode = 0;               /* (0.15) a new stream: READY, the display reset */
        dq_h = dq_t = 0;
        shown = -1;
        core.stc = 0;
        core.max_pts = -1;
        core.bad_header = 0;
        if (nsess < MAXSESS) {
            struct sess *s = &sessions[nsess++];
            s->start = core.rw;
            s->nonce = nonce;
            s->t_start = wall();
        }
    } else if (core.sess && nsess > 0 && !core.paused) {
        consume(wi);
    }
    if (core.run && !core.paused) {
        core.run_us += dt;
        core.stc = (core.anchor_pts + core.run_us * 45u / 1000u) & ((1ull << 33) - 1u);
    }
    /* (0.15) the stand-in display: the head shown when its time comes, the store before it released */
    while (dq_h != dq_t && !core.paused &&
           (!dq[dq_h % 64].ptsv || (core.run && core.stc >= dq[dq_h % 64].pts))) {
        shown = dq[dq_h % 64].store;
        dq_h++;
    }
    if (core.eos && core.run && core.max_pts >= 0 && core.stc >= (uint64_t)core.max_pts && !core.ended) {
        core.ended = 1;
        core.n_ended++;
    }
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
        }
        core.ovl_gen = glo;
        core.ovl_state = state;
        core.ovl_taken++;
        /* the page's corner pixel (2, 2): outside every list, card and panel, so its alpha is the
         * screensaver's veil -- 0, 11 dimmed, 15 black (P5); read from the page the descriptor names */
        int corner = -1, corner_r = -1;
        if ((c & 1u) && state == H264RING_OVL_S_ACCEPTED && client_test_fb && fmt == H264RING_OVL_FMT_4444 &&
            base >= H264RING_FB_BYTE + 0x1000u && (band & 0xFFFF) <= 2 && (band >> 16) >= 2) {
            const uint16_t *pg = (const uint16_t *)((const uint8_t *)client_test_fb + (base - H264RING_FB_BYTE - 0x1000u));
            corner = pg[2 * (stride / 2) + 2] >> 12;
            corner_r = w >= 3 ? pg[2 * (stride / 2) + (w - 3)] >> 12 : -1;   /* the canvas's right edge */
        } else if (!(c & 1u)) {
            corner = 0;                                  /* hidden: nothing over the picture */
        }
        if (novl < MAXEV) {
            ovl_ev[novl].t = wall();
            ovl_ev[novl].gen = glo;
            ovl_ev[novl].en = (int)(c & 1u);
            ovl_ev[novl].corner_r = corner_r;
            ovl_ev[novl].w = (c & 1u) ? w : 0;
            ovl_ev[novl].raster_w = core.osd[H264RING_OPT_REFRESH_RATE] == 3 ? 720u : RASTER_NATIVE_W;
            ovl_ev[novl].h = (c & 1u) ? h : 0;
            ovl_ev[novl].stride = stride;
            ovl_ev[novl].base = base;
            ovl_ev[novl++].corner = corner;
        }
    }
    static int last_sess = -1, last_run = -1, last_paused = -1;
    int changed = nsess != last_sess || core.run != last_run || core.paused != last_paused;
    if ((now - samp_last_us >= SAMPLE_US || changed) && nsamp < MAXSAMP) {
        samp_last_us = now;
        last_sess = nsess; last_run = core.run; last_paused = core.paused;
        samp[nsamp].t = wall();
        samp[nsamp].sess = nsess;
        samp[nsamp].run = core.run;
        samp[nsamp].paused = core.paused;
        samp[nsamp].ended = core.ended;
        samp[nsamp++].stc = core.stc;
    }
    core_status();
}

static void *core_thread(void *u)
{
    (void)u;
    while (!core.stop) {
        pthread_mutex_lock(&core_mx);
        core_step();
        pthread_mutex_unlock(&core_mx);
        usleep(STEP_US);
    }
    return NULL;
}

static void be_barrier(void *u) { (void)u; __sync_synchronize(); sched_yield(); }

/* ---- the player ---- */
static const char *testdir, *root;
static volatile int client_done;
static int client_rc = -1;

static void *client_thread(void *u)
{
    (void)u;
    char *argv[] = {"h264player", "--dir", (char *)testdir, "--root", (char *)root, NULL};
    client_tid = pthread_self();
    client_tid_set = 1;
    client_rc = player_main(5, argv);
    client_done = 1;
    return NULL;
}

static FILE *out_file(const char *out, const char *name)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", out, name);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(2); }
    return f;
}

static uint32_t button(const char *b)
{
    static const struct { const char *n; uint32_t m; } t[] = {
        {"A", H264RING_PAD_A}, {"B", H264RING_PAD_B}, {"X", H264RING_PAD_X}, {"Y", H264RING_PAD_Y},
        {"LB", H264RING_PAD_LB}, {"RB", H264RING_PAD_RB}, {"UP", H264RING_PAD_UP}, {"DOWN", H264RING_PAD_DOWN},
        {"LEFT", H264RING_PAD_LEFT}, {"RIGHT", H264RING_PAD_RIGHT}, {"START", H264RING_PAD_START},
        {"BACK", H264RING_PAD_BACK},
    };
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) if (!strcmp(b, t[i].n)) return t[i].m;
    fprintf(stderr, "test_player: what button is %s?\n", b);
    exit(2);
}

/* a wait's condition, under core_mx */
static int played_sessions(void)
{
    int n = 0;
    for (int k = 0; k < nsess; k++) n += sessions[k].records > 0;
    return n;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: test_player TESTDIR ROOT OUT TIMEOUT_S\n");
        return 2;
    }
    testdir = argv[1];
    root = argv[2];
    const char *out = argv[3];
    double timeout_s = atof(argv[4]);

    ringmem = calloc(RING / 8, 8);
    stores = calloc((size_t)H264RING_DPB_STORES * H264RING_DPB_STORE / 8u, 8);   /* (0.15) */
    {
        char pp[4096];
        snprintf(pp, sizeof pp, "%s/pics.bin", argv[3]);
        pics_f = fopen(pp, "wb");
    }
    core_status();
    pthread_t ct, pt;
    pthread_create(&ct, NULL, core_thread, NULL);
    usleep(2000);

    struct h264ring_backend be;
    memset(&be, 0, sizeof be);
    be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING; be.barrier = be_barrier;
    be.stores = stores;                                                         /* (0.15) */
    int arc = h264ring_attach(&client_test_ring, &be);
    CHECK("T1 the library attaches to the fake core", arc == 0 && client_test_ring);
    if (arc) { printf("test_player: FAILURES\n"); return 1; }

    char path[4096];
    snprintf(path, sizeof path, "%s/script", testdir);
    FILE *sf = fopen(path, "r");
    if (!sf) { perror(path); return 2; }
    FILE *slog = out_file(out, "script.txt");

    double t0 = wall();
    {   /* every video write costs 15 ms: the A9's CAVLC rewrite of a dense stream (~16 ms a unit at
         * 8 Mbit/s, 480p60) -- a 64-unit step would hold the loop ~1 s */
        extern unsigned client_test_write_us;
        client_test_write_us = 15000u;
    }
    pthread_create(&pt, NULL, client_thread, NULL);
    char line[256];
    int ended_script = 0, timeouts = 0;
    while (!ended_script && !client_done && wall() - t0 < timeout_s && fgets(line, sizeof line, sf)) {
        line[strcspn(line, "\r\n#")] = 0;
        char cmd[32] = "", arg[64] = "";
        if (sscanf(line, "%31s %63s", cmd, arg) < 1) continue;
        double ts = wall();
        int timed_out = 0;
        if (!strcmp(cmd, "sleep")) {
            usleep((useconds_t)(atof(arg) * 1e6));
        } else if (!strcmp(cmd, "press")) {
            uint32_t m = 0;
            for (char *tok = strtok(arg, "+"); tok; tok = strtok(NULL, "+")) m |= button(tok);
            pthread_mutex_lock(&core_mx);
            inj.active = 1; inj.phase = 0; inj.buttons = m;
            inj.t_edge = mono_us();
            inj.polls_edge = __atomic_load_n(&client_polls, __ATOMIC_RELAXED);
            pthread_mutex_unlock(&core_mx);
            for (;;) {
                pthread_mutex_lock(&core_mx);
                int busy = inj.active;
                pthread_mutex_unlock(&core_mx);
                if (!busy || client_done) break;          /* (the quit press: the player ends inside it) */
                if (wall() - ts > WAIT_S) { timed_out = 1; break; }
                usleep(2000);
            }
        } else if (!strcmp(cmd, "wait_played") || !strcmp(cmd, "wait_stc") || !strcmp(cmd, "wait_ended")) {
            double v = atof(arg);
            pthread_mutex_lock(&core_mx);
            unsigned ended0 = core.n_ended;
            pthread_mutex_unlock(&core_mx);
            for (;;) {
                pthread_mutex_lock(&core_mx);
                int ok = !strcmp(cmd, "wait_played") ? played_sessions() >= (int)v
                       : !strcmp(cmd, "wait_ended") ? core.ended || core.n_ended != ended0
                       : core.run && (double)((core.stc - core.anchor_pts) & ((1ull << 33) - 1u)) >= v * 90000.0;
                pthread_mutex_unlock(&core_mx);
                if (ok) break;
                if (wall() - ts > WAIT_S || client_done) { timed_out = 1; break; }
                usleep(2000);
            }
        } else if (!strcmp(cmd, "end")) {
            ended_script = 1;
        } else {
            fprintf(stderr, "test_player: what is \"%s\"?\n", line);
            return 2;
        }
        timeouts += timed_out;
        fprintf(slog, "%.6f %.6f %d %s\n", ts, wall(), timed_out, line);
        fflush(slog);
        if (timed_out) printf("test_player: \"%s\" timed out\n", line);
    }
    /* the player may end inside the last press (the quit): what is left must be only "end" */
    while (!ended_script && fgets(line, sizeof line, sf)) {
        line[strcspn(line, "\r\n#")] = 0;
        char cmd[32] = "";
        if (sscanf(line, "%31s", cmd) < 1) continue;
        if (!strcmp(cmd, "end")) ended_script = 1;
        else break;
    }
    fclose(sf);
    fclose(slog);
    /* the script is done: the player ends by itself (Back + Start in the list) */
    double t_end = wall();
    while (!client_done && wall() - t_end < 10.0) usleep(10000);
    int by_itself = client_done;
    if (!client_done) player_test_stop();
    while (!client_done && wall() - t_end < 25.0) usleep(10000);
    int returned = client_done;
    if (returned) pthread_join(pt, NULL);
    pthread_mutex_lock(&core_mx);
    core.stop = 1;
    pthread_mutex_unlock(&core_mx);
    pthread_join(ct, NULL);
    if (pics_f) fclose(pics_f);

    FILE *f = out_file(out, "sessions.txt");
    for (int k = 0; k < nsess; k++) {
        struct sess *s = &sessions[k];
        fprintf(f, "%d %u %.6f %.6f %llu %zu %u %.6f %.6f %u %u\n", k, s->nonce, s->t_start, s->t_anchor,
                (unsigned long long)s->anchor_pts, s->n, s->records, s->t_first, s->t_last, s->first_type, s->dropped);
        char name[64];
        snprintf(name, sizeof name, "s%02d.stream", k);
        FILE *g = out_file(out, name);
        fwrite(&s->start, 4, 1, g);
        if (s->n) fwrite(s->b, 1, s->n, g);
        fclose(g);
    }
    fclose(f);
    f = out_file(out, "stc.txt");
    for (unsigned i = 0; i < nsamp; i++)
        fprintf(f, "%.6f %d %d %d %d %llu\n", samp[i].t, samp[i].sess - 1, samp[i].run, samp[i].paused,
                samp[i].ended, (unsigned long long)samp[i].stc);
    fclose(f);
    f = out_file(out, "settings.txt");
    for (unsigned i = 0; i < nset; i++)
        fprintf(f, "%.6f %u %u %u\n", set_ev[i].t, set_ev[i].seq, set_ev[i].mask, set_ev[i].refresh);
    fclose(f);
    f = out_file(out, "ovl.txt");
    for (unsigned i = 0; i < novl; i++)
        fprintf(f, "%.6f %u %d %d %d %u %u\n", ovl_ev[i].t, ovl_ev[i].gen, ovl_ev[i].en, ovl_ev[i].corner,
                ovl_ev[i].corner_r, ovl_ev[i].w, ovl_ev[i].raster_w);
    fclose(f);
    f = out_file(out, "loopgap.txt");
    for (unsigned i = 0; i < ngaps; i++) fprintf(f, "%.6f %.6f\n", gaps[i].from, gaps[i].to);
    fclose(f);
    f = out_file(out, "final.txt");
    fprintf(f, "%u\n", core.osd[H264RING_OPT_REFRESH_RATE]);
    fclose(f);

    printf("test_player: %d sessions (%d played), %u settings requests, %u overlay descriptors taken\n",
           nsess, played_sessions(), nset, core.ovl_taken);
    CHECK("T2 the player opened a session on the fake core", nsess >= 1);
    CHECK("T3 the script ran to its end, no wait timed out", ended_script && !timeouts);
    CHECK("T4 the player ended by itself (Back + Start in the list) within 10 s, returning 0",
          by_itself && returned && client_rc == 0);
    CHECK("T5 every record header the core read was well formed", !core.bad_seen);
    CHECK("T6 every overlay descriptor the player wrote was accepted", core.ovl_taken > 0 && core.ovl_refused == 0);
    printf("test_player: %u pictures consumed, %u named a store the display held\n", pics_consumed, pic_busy);
    CHECK("T10 (0.15) the store rule: pictures sent, none into a store the display held (queued or shown)",
          pics_consumed > 20 && pic_busy == 0);
    {   /* (0.10) the canvas spans the raster the core reports: 852 native and 720 fitted both drawn,
         * and no width other than those two */
        unsigned at852 = 0, at720 = 0, other = 0;
        for (unsigned i = 0; i < novl; i++) {
            if (!ovl_ev[i].w) continue;
            if (ovl_ev[i].w == RASTER_NATIVE_W && ovl_ev[i].raster_w == RASTER_NATIVE_W) at852++;
            else if (ovl_ev[i].w == 720u && ovl_ev[i].raster_w == 720u) at720++;
            else if (ovl_ev[i].w != RASTER_NATIVE_W && ovl_ev[i].w != 720u) other++;
        }
        printf("test_player: canvases 852 wide on the native raster %u, 720 on the fitted %u, other widths %u\n",
               at852, at720, other);
        CHECK("T7 the overlay drawn for the raster's width (852 native, 720 fitted: word 80)",
              at852 > 0 && at720 > 0 && other == 0);
    }
    {   /* (0.12) /dev/fb0 is Main's HDMI mode's size, not the 8 MB region (CLIENT_TEST_FB_LEN models it:
         * run_test.sh's arms). T8: every canvas has the raster's lines, or as many as two pages of its
         * width fit (a row of the width rounded to 8 bytes) -- never fewer; the raster named by the
         * canvas's width (852 is the native 852 x 480, 720 the fitted 720 x 576: T7), since a canvas
         * taken just after a switch was drawn for the raster before it. T9: every canvas lies inside
         * the framebuffer (from its start, the page the device skips). */
        const char *e = getenv("CLIENT_TEST_FB_LEN");
        uint64_t len = e ? strtoull(e, NULL, 0) : H264RING_FB_SIZE - 0x1000u;
        uint64_t start = H264RING_FB_BYTE + 0x1000u;
        unsigned short_n = 0, outside = 0, drawn = 0, clamped = 0;
        for (unsigned i = 0; i < novl; i++) {
            if (!ovl_ev[i].w) continue;
            uint64_t row = ((uint64_t)ovl_ev[i].w * 2u + 7u) & ~7ull;
            uint64_t fit = len / (2u * row);
            unsigned rh = ovl_ev[i].w == RASTER_NATIVE_W ? 480u : 576u;
            uint64_t want = rh < fit ? rh : fit;
            drawn++;
            if (want < rh) clamped++;
            if (ovl_ev[i].h != want) {
                if (short_n++ < 3) printf("test_player: canvas %u x %u on a %u-line raster, %u wanted (framebuffer %llu)\n",
                                          ovl_ev[i].w, ovl_ev[i].h, rh, (unsigned)want,
                                          (unsigned long long)len);
            }
            if (ovl_ev[i].base < start ||
                (uint64_t)ovl_ev[i].base + (uint64_t)(ovl_ev[i].h - 1u) * ovl_ev[i].stride + ovl_ev[i].w * 2u > start + len)
                if (outside++ < 3) printf("test_player: canvas at +0x%llx, %u lines of %u bytes: past the framebuffer's %llu\n",
                                          (unsigned long long)(ovl_ev[i].base - start), ovl_ev[i].h, ovl_ev[i].stride,
                                          (unsigned long long)len);
        }
        printf("test_player: framebuffer %llu bytes: %u canvases (%u of them shorter than their raster: two pages "
               "fit no more)\n", (unsigned long long)len, drawn, clamped);
        CHECK("T8 every canvas the raster's lines, or all two pages of it fit (Main's HDMI mode's framebuffer)",
              drawn > 0 && short_n == 0);
        CHECK("T9 every canvas inside the framebuffer Main gives (/dev/fb0's smem_len)", drawn > 0 && outside == 0);
    }
    printf("test_player: %s\n", fails ? "FAILURES" : "ALL GREEN");
    h264ring_close(client_test_ring);
    return fails ? 1 : 0;
}
