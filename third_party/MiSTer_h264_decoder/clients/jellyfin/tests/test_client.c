/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/jellyfin/tests/test_client.c -- the Jellyfin client (src/, built with -DCLIENT_TEST) against
 * a fake core on its own thread, while fake_server.py plays a scripted Jellyfin server to it.
 *
 *   test_client TESTDIR OUT TIMEOUT_S
 *
 * The client runs as jf_main("--dir", TESTDIR) on a thread (TESTDIR holds jellyfin.ini, the two
 * typefaces, state.json). The fake core is the protocol's core side as clients/moonlight/tests/
 * test_mister.c writes it (the nonce, the read index, the seqlocked status block), extended so
 * the client's behaviour can be judged:
 *   - it consumes whole records and reads their headers as it goes (type, flags, length, PTS);
 *   - ITS STC: from a session's first VIDEO_AU with PTS_VALID, that PTS plus the time since --
 *     at HALF real speed (45,000 ticks a real second), frozen while word 34's PAUSE is set (and
 *     nothing is consumed then, as the core stops reading the ring). Reported in word 7 with
 *     LIVE's STC_RUN / SESSION; LIVE ENDED (and STATE ENDED) once a VIDEO_AU with END_OF_STREAM
 *     was consumed and the STC has passed the session's latest PTS (B-frames: the last AU in
 *     decode order is not the latest picture). Half speed is the point: a position the client
 *     derives from what it WROTE runs far ahead of one derived from the STC (check_client.py (h));
 *   - the overlay mirrored: a consistent descriptor (gen_lo == gen_hi, words 72 / 79) with a new
 *     generation is taken -- OVL_GEN, OVL_STATE 1 (0 when ENABLE is clear, 2 refused) in word 46;
 *     a FLIP is a taken descriptor that is enabled with a base other than the last enabled one (a
 *     session start re-writes the same descriptor under a newer generation: not a flip);
 *   - word 34 (PAUSE, ATTEN) mirrored in word 45 and logged on change; the heartbeat every step;
 *   - pad 0 pressed on a cue (the scenario writes TESTDIR/pad_taps or TESTDIR/pad_hold): RIGHT
 *     tapped three times (pressed 60 ms, every 120 ms), or RIGHT held 1.2 s -- written into the
 *     input region (words 48-71) as the core writes it (docs/architecture.md "Input (interface
 *     0.6)"): in_head (48) first, the words, in_tail (71) last, so the library's seqlock read
 *     (in_tail first, in_head last) sees a whole copy; every change also logged. The pads are a
 *     snapshot (a press the program never polls during is lost, as on the rig), so each press and
 *     each release lasts its time AND until the client's loop has gone round twice since the edge
 *     (counted by this file's usleep, which the loop calls once an iteration): a client starved
 *     by a busy host still sees every edge; the stretches are logged (pad.txt, T7).
 * Written to OUT/ for check_client.py (every time is CLOCK_REALTIME, Python's time.time()):
 *   sNN.stream     session NN's consumed bytes (u32 start index, then the bytes), as Moonlight's
 *   sessions.txt   idx nonce t_start t_anchor anchor_pts bytes records t_first t_last first_type dropped
 *                  (t_first / t_last: the first / last record consumed; dropped: bytes the program
 *                  published that the session never consumed -- written while paused, then flushed)
 *   stc.txt        every 5 ms: t sess run paused ended stc
 *   ctl.txt        word 34 on change: t word
 *   ovl.txt        each descriptor taken: t gen enable base flip sess state
 *   pad.txt        each change of pad 0's RIGHT: t taps|hold pressed (a cue's first line is its start)
 * and prints its own PASS / FAIL lines, then "test_client: ALL GREEN". */
#include "h264ring.h"

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define RING     (1u << 20)
#define MAXSESS  64
#define MAXSAMP  (1u << 16)
#define MAXEV    4096
#define STEP_US  200
#define SAMPLE_US 5000

extern h264ring *client_test_ring;
int jf_main(int argc, char **argv);
void jf_test_stop(void);

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
    uint32_t seen, rw, seq, ack, w34;
    uint64_t anchor_pts, run_us, last_us, stc;
    int64_t max_pts;
    /* the overlay */
    uint32_t ovl_gen, ovl_base_last;
    int ovl_state, ovl_base_valid, ovl_refused;
    unsigned ovl_taken, ovl_flips;
} core;

static struct { double t; int sess, run, paused, ended; uint64_t stc; } samp[MAXSAMP];
static unsigned nsamp;
static uint64_t samp_last_us;
static struct { double t; uint32_t w; } ctl_ev[MAXEV];
static unsigned nctl;
static struct { double t; uint32_t gen, base; int en, flip, sess, state; } ovl_ev[MAXEV];
static unsigned novl;

/* the pad's presses, on a cue (core thread; started by main under core_mx) */
#define TAP_PRESS_US  60000u
#define TAP_EVERY_US  120000u
#define TAPS          3u
#define HOLD_US       1200000u
static struct {
    int kind;                 /* 0 none, 1 taps, 2 hold */
    unsigned phase;           /* taps: 0 press, 1 release, 2 press, ...; hold: 0 press */
    uint64_t t_edge;          /* the current phase's start */
    unsigned polls_edge;      /* the client's loop count then */
    uint32_t pad0, seq;
    uint64_t tap_us, hold_us; /* the longest tap phase, the hold (longer than nominal: the client's loop was late) */
} inj;
static struct { double t; int kind, pressed; } pad_ev[MAXEV];
static unsigned npad;

/* the client's loop: it calls usleep once an iteration -- counted on its thread (this definition
 * takes the executable's calls, the client's and the library's; FFmpeg and curl keep libc's) */
static pthread_t client_tid;
static volatile int client_tid_set;
static unsigned client_polls;
/* the loop's stalls: the time between one usleep's return and the next call, when over 250 ms
 * (work done on the loop's thread -- a server request made there freezes the picture and the
 * overlay: check (r)); the client thread's only */
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
    PUT(STATE, !core.sess ? H264RING_S_NO_SESSION : core.ended ? H264RING_S_ENDED : H264RING_S_PLAYING);
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
    PUT(CAP_NATIVE_H, 720);                       /* (0.12) the HD raster's: Video Output still not Native here */
    PUT(CAP_MB_RATE, 108000);
    /* (0.10) the raster as A' leaves it on a 1920x1080 display: shown 16:9 (word 47), letterboxed
     * inside (word 80). Its 576 lines against raster_std's 480 (0: 59.94) on purpose: word 80 is the
     * source of the canvas's height, and only a client that reads it draws 576 (T8) */
    PUT(AR_X, 1920u); PUT(AR_Y, 1080u);
    PUT(RASTER_W, 720u); PUT(RASTER_H, 576u); PUT(RASTER_LB, 1u);
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

static void input_step(uint64_t now)
{
    if (!inj.kind) return;
    /* a phase ends after its time AND two of the client's loops since its edge */
    uint64_t len = inj.kind == 2 ? HOLD_US : inj.phase % 2 == 0 ? TAP_PRESS_US : TAP_EVERY_US - TAP_PRESS_US;
    unsigned polls = __atomic_load_n(&client_polls, __ATOMIC_RELAXED);
    if (now - inj.t_edge >= len && polls - inj.polls_edge >= 2) {
        uint64_t *m = inj.kind == 1 ? &inj.tap_us : &inj.hold_us;
        if (now - inj.t_edge > *m) *m = now - inj.t_edge;
        inj.phase++;
        inj.t_edge = now;
        inj.polls_edge = polls;
    }
    unsigned phases = inj.kind == 1 ? 2 * TAPS : 1;
    int done = inj.phase >= phases;
    int pressed = !done && inj.phase % 2 == 0;
    uint32_t pad0 = pressed ? H264RING_PAD_RIGHT : 0u;
    if (pad0 != inj.pad0) {
        inj.pad0 = pad0;
        input_write(pad0);
        if (npad < MAXEV) {
            pad_ev[npad].t = wall();
            pad_ev[npad].kind = inj.kind;
            pad_ev[npad++].pressed = pressed;
        }
    }
    if (done) inj.kind = 0;
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

/* whole records up to the write index, their headers read as they go */
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
        if (type < H264RING_T_PAD || type > H264RING_T_AUDIO || (w1 >> 48) != H264RING_SYNC ||
            n > RING - core.rw % RING) {
            core.bad_header = core.bad_seen = 1;     /* the scorer's consumer names the error */
            break;
        }
        if (n > avail) break;                        /* not all published: wait */
        sess_append(s, core.rw, n);
        core.rw += n;
        s->t_last = wall();
        if (!s->records++) {
            s->t_first = s->t_last;
            s->first_type = type;
        }
        if (type == H264RING_T_VIDEO_AU) {
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
    uint32_t wi = lo(H264RING_W_WRITE_INDEX), nonce = lo(H264RING_W_NONCE);
    uint32_t w34 = lo(H264RING_W_PAUSE);
    if (w34 != core.w34 && nctl < MAXEV) {
        ctl_ev[nctl].t = wall();
        ctl_ev[nctl++].w = w34;
    }
    core.w34 = w34;
    core.paused = core.sess && (w34 >> H264RING_CTL_PAUSE_BIT & 1u);
    if (!core.booted) {
        core.seen = nonce;
        core.booted = 1;
    } else if (nonce != core.seen) {                 /* a new session at the write index */
        if (core.sess && nsess > 0) sessions[nsess - 1].dropped = (wi & ~15u) - core.rw;
        core.seen = nonce;
        core.sess = 1;
        core.rw = wi & ~15u;
        core.ack = nonce;
        core.run = core.eos = core.ended = 0;
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
    /* the STC: half speed, frozen by the pause */
    if (core.run && !core.paused) {
        core.run_us += dt;
        core.stc = (core.anchor_pts + core.run_us * 45u / 1000u) & ((1ull << 33) - 1u);
    }
    if (core.eos && core.run && core.max_pts >= 0 && core.stc >= (uint64_t)core.max_pts) core.ended = 1;
    /* the overlay's descriptor: taken when consistent and new */
    uint32_t glo = lo(H264RING_W_OVL_GEN_LO), ghi = lo(H264RING_W_OVL_GEN_HI);
    if (glo == ghi && glo != core.ovl_gen) {
        uint32_t c = lo(H264RING_W_OVL_CTL), base = lo(H264RING_W_OVL_BASE), size = lo(H264RING_W_OVL_SIZE);
        uint32_t stride = lo(H264RING_W_OVL_STRIDE), band = lo(H264RING_W_OVL_BAND);
        uint32_t w = size & 0xFFFF, h = size >> 16, fmt = (c >> H264RING_OVL_CTL_FMT_LSB) & 3u;
        int en = c & 1u, flip = 0, state = H264RING_OVL_S_OFF;
        if (en) {
            uint32_t bpp = fmt == H264RING_OVL_FMT_8888 ? 4u : 2u;
            int ok = !(c & H264RING_OVL_CTL_RESERVED) && fmt != 3 && w >= 1 && w <= H264RING_OVL_MAX_W &&
                     h >= 1 && h <= H264RING_OVL_MAX_H && stride % 8 == 0 && stride >= w * bpp && base % 8 == 0 &&
                     (band & 0xFFFF) <= (band >> 16) && (band >> 16) < h && base >= H264RING_FB_BYTE &&
                     (uint64_t)base + (uint64_t)(h - 1) * stride + w * bpp <= (uint64_t)H264RING_FB_BYTE + H264RING_FB_SIZE;
            state = ok ? H264RING_OVL_S_ACCEPTED : H264RING_OVL_S_REFUSED;
            if (!ok) core.ovl_refused++;
            if (ok) {
                flip = core.ovl_base_valid && base != core.ovl_base_last;
                core.ovl_base_last = base;
                core.ovl_base_valid = 1;
            }
        }
        core.ovl_gen = glo;
        core.ovl_state = state;
        core.ovl_taken++;
        core.ovl_flips += (unsigned)flip;
        if (novl < MAXEV) {
            ovl_ev[novl].t = wall();
            ovl_ev[novl].gen = glo;
            ovl_ev[novl].base = base;
            ovl_ev[novl].en = en;
            ovl_ev[novl].flip = flip;
            ovl_ev[novl].sess = nsess;
            ovl_ev[novl++].state = state;
        }
    }
    /* a sample every 5 ms, and at once when the session or the clock's state changes (a report
     * just after a flush must not be scored against the previous session's clock) */
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

/* ---- the client ---- */
static const char *testdir;
static volatile int client_done;
static int client_rc = -1;

static void *client_thread(void *u)
{
    (void)u;
    char *argv[] = {"jellyfin", "--dir", (char *)testdir, NULL};
    client_tid = pthread_self();
    client_tid_set = 1;
    client_rc = jf_main(3, argv);
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

const char *jf_profile_json(int hd);

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: test_client TESTDIR OUT TIMEOUT_S\n");
        return 2;
    }
    testdir = argv[1];
    const char *out = argv[2];
    {   /* (0.12, b'') the profile a Native (HDMI) output on an HD-raster core asks with: check_client */
        FILE *pf = out_file(out, "profile_hd.json");
        fputs(jf_profile_json(1), pf);
        fclose(pf);
    }
    double timeout_s = atof(argv[3]);
    char stopf[4096];
    snprintf(stopf, sizeof stopf, "%s/stop", testdir);
    unlink(stopf);

    ringmem = calloc(RING / 8, 8);
    core_status();
    pthread_t ct, jt;
    pthread_create(&ct, NULL, core_thread, NULL);
    usleep(2000);

    struct h264ring_backend be;
    memset(&be, 0, sizeof be);
    be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING; be.barrier = be_barrier;
    int arc = h264ring_attach(&client_test_ring, &be);
    CHECK("T1 the library attaches to the fake core", arc == 0 && client_test_ring);
    if (arc) { printf("test_client: FAILURES\n"); return 1; }

    double t0 = wall();
    pthread_create(&jt, NULL, client_thread, NULL);
    int by_stop = 0, cued[2] = {0, 0};
    char cuef[2][4096];
    snprintf(cuef[0], sizeof cuef[0], "%s/pad_taps", testdir);
    snprintf(cuef[1], sizeof cuef[1], "%s/pad_hold", testdir);
    unlink(cuef[0]); unlink(cuef[1]);
    while (!client_done && wall() - t0 < timeout_s) {
        if (access(stopf, F_OK) == 0) { by_stop = 1; break; }
        for (int k = 0; k < 2; k++)
            if (!cued[k] && access(cuef[k], F_OK) == 0) {      /* the scenario's cue: press the pad */
                cued[k] = 1;
                pthread_mutex_lock(&core_mx);
                inj.kind = k + 1;
                inj.phase = 0;
                inj.t_edge = mono_us();
                inj.polls_edge = __atomic_load_n(&client_polls, __ATOMIC_RELAXED);
                pthread_mutex_unlock(&core_mx);
            }
        usleep(5000);
    }
    double t_stop = wall();
    jf_test_stop();
    while (!client_done && wall() - t_stop < 15.0) usleep(10000);
    int returned = client_done;
    if (returned) pthread_join(jt, NULL);
    double exit_s = wall() - t_stop;
    pthread_mutex_lock(&core_mx);
    core.stop = 1;
    pthread_mutex_unlock(&core_mx);
    pthread_join(ct, NULL);

    /* ---- the outputs ---- */
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
    f = out_file(out, "ctl.txt");
    for (unsigned i = 0; i < nctl; i++) fprintf(f, "%.6f %u\n", ctl_ev[i].t, ctl_ev[i].w);
    fclose(f);
    f = out_file(out, "pad.txt");
    for (unsigned i = 0; i < npad; i++)
        fprintf(f, "%.6f %s %d\n", pad_ev[i].t, pad_ev[i].kind == 1 ? "taps" : "hold", pad_ev[i].pressed);
    fclose(f);
    f = out_file(out, "loopgap.txt");
    for (unsigned i = 0; i < ngaps; i++) fprintf(f, "%.6f %.6f\n", gaps[i].from, gaps[i].to);
    fclose(f);
    f = out_file(out, "ovl.txt");
    for (unsigned i = 0; i < novl; i++)
        fprintf(f, "%.6f %u %d %u %d %d %d\n", ovl_ev[i].t, ovl_ev[i].gen, ovl_ev[i].en, ovl_ev[i].base,
                ovl_ev[i].flip, ovl_ev[i].sess - 1, ovl_ev[i].state);
    fclose(f);

    /* ---- what the fake core can judge itself ---- */
    printf("test_client: %d sessions, %u overlay descriptors taken (%u flips), word 34 changed %u times\n",
           nsess, core.ovl_taken, core.ovl_flips, nctl);
    CHECK("T2 the client opened a session on the fake core", nsess >= 1);
    CHECK("T3 the scenario ended the run (its stop file), not the timeout", by_stop);
    CHECK("T4 the client returned 0 within 10 s of being stopped", returned && client_rc == 0 && exit_s < 10.0);
    CHECK("T5 every record header the core read was well formed", !core.bad_seen);
    CHECK("T6 every overlay descriptor the client wrote was accepted", core.ovl_taken > 0 && core.ovl_refused == 0);
    printf("test_client: the pad: the longest tap press / release %.0f ms (60 nominal), the hold %.0f ms (1,200): "
           "longer = the client's loop was late\n", (double)inj.tap_us / 1000.0, (double)inj.hold_us / 1000.0);
    CHECK("T7 the pad was pressed on both cues (three taps, one hold: 8 changes of RIGHT)",
          cued[0] && cued[1] && npad == 8);
    {
        extern double client_test_par;
        extern unsigned client_test_lines;
        const double want = (1920.0 / 1080.0) * 576.0 / 720.0;          /* the raster's pixel aspect */
        printf("test_client: the overlay drawn for %u lines at a pixel aspect %.4f (%.4f wanted)\n",
               client_test_lines, client_test_par, want);
        CHECK("T8 the overlay drawn for the raster the core reports (word 80's lines, word 47's shape)",
              client_test_lines == 576u && client_test_par > want * 0.995 && client_test_par < want * 1.005);
    }
    printf("test_client: %s\n", fails ? "FAILURES" : "ALL GREEN");
    h264ring_close(client_test_ring);
    return fails ? 1 : 0;
}
