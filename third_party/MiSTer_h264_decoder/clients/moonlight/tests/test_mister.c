/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/moonlight/tests/test_mister.c -- the Moonlight client's mister backend
 * (src/mister/mister.c, unmodified) against a fake core on its own thread: the protocol's core
 * side as hps/tests/test_ring.c writes it (the nonce, the read index, the seqlocked status
 * block), consuming concurrently. The bytes each session consumed are written out and scored
 * by check_mister.py with tools/ring_model.py's consumer (an oracle that shares nothing with
 * the backend or the library). Control flow is checked here.
 *
 *   test_mister STREAM.h264 OUT_STEM CAVLC.h264 REFUSED.h264
 *                                      one PASS / FAIL line per check, "test_mister: ALL GREEN"
 *
 * Scenarios, in order, on one backend instance (as a real client lives):
 *   S1  the stream's access units as decode units, each split over 1-3 buffer entries, while
 *       an audio thread (started first) sends 5 ms Opus packets, every 40th lost (NULL);
 *   S2  a decoder error in the status block: one IDR request, P frames refused until an IDR;
 *   S3  the session dropped (an OSD Reset): a new session, starting at an IDR;
 *   S4  a refusal: the stream is ended (SIGTERM to the client's own loop);
 *   S5  OSD_OPEN read through the status block, and the size asked for by the screen's shape;
 *   S6  the core unloaded (the heartbeat still, its words left as they were): the stream is
 *       ended, not written into a ring nobody drains forever;
 *   S7  (fj#20) a CAVLC stream in session 2, after S3: every unit rewritten into CABAC before it is
 *       written (check_mister.py compares the bytes with hps' cavlc2cabac on the same file);
 *   S8  (fj#20) a stream the rewrite refuses (redundant pictures): ended like a refusal, once,
 *       nothing written; a new stream (setup) starts clean.
 * The fake core's barrier yields the CPU between a record's payload and its index, so two
 * writers without the backend's mutex interleave (the --red arm that removes it). */
#include <Limelight.h>
#include "h264ring.h"
#include "mister.h"

#include <opus_multistream.h>

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RING (1u << 20)
#define FRAMES 240                      /* 5 ms at 48 kHz: Sunshine's default packet */

static int fails;
#define CHECK(label, cond) do { int ok_ = (cond); printf("  %s %s\n", ok_ ? "PASS" : "FAIL", label); \
                                if (!ok_) fails++; } while (0)

/* ---- the stubs the backend calls into moonlight-common-c for ---- */
static volatile int idr_calls;
void LiRequestIdrFrame(void) { __sync_fetch_and_add(&idr_calls, 1); }

static volatile sig_atomic_t sigterms;
static void on_term(int s) { (void)s; sigterms++; }

/* ---- the fake core ---- */
static uint64_t ctrl[512];
static uint64_t *ringmem;
static pthread_mutex_t core_mx = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int booted, sess, stop, osd, dead, il, aspect;
    uint32_t seen, rw, seq, ack;
    uint32_t fe_err, fe_refused, refused_code;
} core;
struct sess { uint32_t start; uint8_t *b; size_t n, cap; };
static struct sess sessions[8];
static int nsess;

static uint32_t lo(unsigned w) { return (uint32_t)ctrl[w]; }

static void put(unsigned w, unsigned lsb, unsigned width, uint64_t v) {
    uint64_t m = width >= 64 ? ~0ull : ((1ull << width) - 1u);
    ctrl[w] = (ctrl[w] & ~(m << lsb)) | ((v & m) << lsb);
}
#define PUT(F, v) put(H264RING_##F##_W, H264RING_##F##_LSB, H264RING_##F##_WIDTH, (v))

static void core_status(void) {                    /* the seqlock: head first, tail last */
    core.seq++;
    put(3, 0, 32, core.seq);
    __sync_synchronize();
    ctrl[0] = H264RING_MAGIC;
    ctrl[1] = H264RING_VERSION | ((uint64_t)H264RING_CORE_WORDS << 16) | ((uint64_t)H264RING_PROG_WORD << 32) |
              ((uint64_t)H264RING_CORE2_WORD << 48);
    ctrl[2] = H264RING_RING_BYTE | ((uint64_t)RING << 32);
    put(3, 32, 32, H264RING_MAX_PAYLOAD);
    PUT(STATE, core.sess ? H264RING_S_PLAYING : H264RING_S_NO_SESSION);
    PUT(LIVE, (core.osd ? H264RING_L_OSD_OPEN : 0) | (core.sess ? H264RING_L_SESSION : 0));
    ctrl[5] = core.rw | ((uint64_t)core.ack << 32);
    PUT(FE_ERR, core.fe_err);
    PUT(FE_REFUSED, core.fe_refused);
    PUT(FE_REFUSED_CODE, core.refused_code);
    PUT(RASTER_IL, core.il);
    PUT(OSD_ASPECT, core.aspect);
    PUT(CAP_MAX_MBS, 3600);                         /* (0.11) word 81: the real core's constants */
    PUT(CAP_NATIVE_H, 480);
    PUT(CAP_MB_RATE, 108000);
    __sync_synchronize();
    put(31, 0, 32, core.seq);
}

static void core_step(void) {
    if (core.dead)                                   /* another core loaded: nothing answers */
        return;
    uint32_t wi = lo(H264RING_W_WRITE_INDEX), nonce = lo(H264RING_W_NONCE);
    if (!core.booted) {
        core.seen = nonce;
        core.booted = 1;
    } else if (nonce != core.seen) {                 /* a new session at the write index */
        core.seen = nonce;
        core.sess = 1;
        core.rw = wi & ~15u;
        core.ack = nonce;
        if (nsess < 8)
            sessions[nsess++].start = core.rw;
    } else if (core.sess && nsess > 0) {
        struct sess *s = &sessions[nsess - 1];
        while (core.rw != wi) {                      /* consume what the program wrote */
            if (s->n == s->cap) {
                s->cap = s->cap ? 2 * s->cap : (1u << 20);
                s->b = realloc(s->b, s->cap);
            }
            s->b[s->n++] = (uint8_t)(ringmem[(core.rw % RING) / 8] >> (8 * (core.rw % 8)));
            core.rw++;
        }
    }
    core_status();
}

static void *core_thread(void *u) {
    (void)u;
    while (!core.stop) {
        pthread_mutex_lock(&core_mx);
        core_step();
        pthread_mutex_unlock(&core_mx);
        usleep(100);
    }
    return NULL;
}

static void be_barrier(void *u) { (void)u; __sync_synchronize(); sched_yield(); }

/* ---- the audio thread: 5 ms Opus packets, every 40th lost; a reference decode of each ---- */
static volatile int audio_go = 1, audio_started, video_may_start;
static int16_t *ref_pcm;                            /* the reference decode, packet after packet */
static size_t ref_frames, ref_cap;
static size_t *pkt_at;                              /* packet i's first frame in ref_pcm */
static int npkt;

static void *audio_thread(void *u) {
    (void)u;
    int err;
    const unsigned char map[2] = { 0, 1 };
    OpusEncoder *enc = opus_encoder_create(48000, 2, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &err);
    OpusMSDecoder *ref = opus_multistream_decoder_create(48000, 2, 1, 1, map, &err);
    static OPUS_MULTISTREAM_CONFIGURATION cfg = { 48000, 2, 1, 1, FRAMES, { 0, 1 } };
    audio_callbacks_mister.init(AUDIO_CONFIGURATION_STEREO, &cfg, NULL, 0);
    int16_t in[FRAMES * 2], out[FRAMES * 2];
    unsigned char pkt[1500];
    double ph = 0;
    audio_started = 1;
    for (int i = 0; audio_go; i++) {
        for (int k = 0; k < FRAMES; k++) {           /* a sweep: every packet different */
            ph += 2 * M_PI * (200.0 + (i % 400)) / 48000.0;
            in[2 * k] = (int16_t)(8000 * sin(ph));
            in[2 * k + 1] = (int16_t)(6000 * sin(1.5 * ph));
        }
        int len = opus_encode(enc, in, FRAMES, pkt, sizeof pkt);
        bool lost = i % 40 == 39;
        int got = opus_multistream_decode(ref, lost ? NULL : pkt, lost ? 0 : len, out, FRAMES, 0);
        if (got > 0) {
            if (ref_frames + (size_t)got > ref_cap) {
                ref_cap = ref_cap ? 2 * ref_cap : 1u << 20;
                ref_pcm = realloc(ref_pcm, ref_cap * 4);
            }
            if ((npkt & 1023) == 0)
                pkt_at = realloc(pkt_at, (size_t)(npkt + 1024) * sizeof *pkt_at);
            pkt_at[npkt++] = ref_frames;
            memcpy(ref_pcm + 2 * ref_frames, out, (size_t)got * 4);
            ref_frames += (size_t)got;
        }
        audio_callbacks_mister.decodeAndPlaySample(lost ? NULL : (char *)pkt, lost ? 0 : len);
        if (i == 20)
            video_may_start = 1;                     /* 20 packets ahead of the first picture */
        usleep(500);
    }
    audio_callbacks_mister.cleanup();
    opus_encoder_destroy(enc);
    opus_multistream_decoder_destroy(ref);
    return NULL;
}

/* ---- decode units ---- */
static bool has_idr(const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i + 3 < n; i++)
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 && (p[i + 3] & 0x1F) == 5)
            return true;
    return false;
}

/* one access unit as moonlight-common-c hands it over: split over 1-3 entries */
static int submit(const uint8_t *p, uint32_t n, int type, unsigned salt) {
    LENTRY e[3];
    int parts = 1 + (int)(salt % 3);
    uint32_t cut1 = parts > 1 ? n / 3 + salt % 7 : n, cut2 = parts > 2 ? 2 * n / 3 : n;
    if (cut1 > n) cut1 = n;
    if (cut2 < cut1) cut2 = cut1;
    memset(e, 0, sizeof e);
    e[0].data = (char *)p;              e[0].length = (int)cut1;
    e[1].data = (char *)p + cut1;       e[1].length = (int)(cut2 - cut1);
    e[2].data = (char *)p + cut2;       e[2].length = (int)(n - cut2);
    e[0].next = parts > 1 ? &e[1] : NULL;
    e[1].next = parts > 2 ? &e[2] : NULL;
    if (parts == 2) e[1].length = (int)(n - cut1);
    DECODE_UNIT du;
    memset(&du, 0, sizeof du);
    du.frameType = type;
    du.fullLength = (int)n;
    du.bufferList = &e[0];
    return decoder_callbacks_mister.submitDecodeUnit(&du);
}

static void write_sess(const char *stem, int k) {
    char path[4096];
    snprintf(path, sizeof path, "%s.s%d.stream", stem, k + 1);
    FILE *f = fopen(path, "wb");
    fwrite(&sessions[k].start, 4, 1, f);
    fwrite(sessions[k].b, 1, sessions[k].n, f);
    fclose(f);
}

static void settle(void) {                          /* the fake core has read everything */
    for (int i = 0; i < 2000; i++) {
        pthread_mutex_lock(&core_mx);
        int done = core.rw == (lo(H264RING_W_WRITE_INDEX) & ~0u);
        pthread_mutex_unlock(&core_mx);
        if (done) return;
        usleep(1000);
    }
}

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END);
    long fn = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)fn);
    *n = b && fread(b, 1, (size_t)fn, f) == (size_t)fn ? (size_t)fn : 0;
    fclose(f);
    return b;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: test_mister STREAM.h264 OUT_STEM CAVLC.h264 REFUSED.h264\n");
        return 2;
    }
    const char *stem = argv[2];
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END);
    long fn = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc((size_t)fn);
    if (fread(buf, 1, (size_t)fn, f) != (size_t)fn) return 2;
    fclose(f);
    size_t nau = h264ring_split_annexb(buf, (size_t)fn, NULL, 0);
    struct h264ring_au *au = calloc(nau, sizeof *au);
    h264ring_split_annexb(buf, (size_t)fn, au, nau);
    if (nau < 60) { fprintf(stderr, "test_mister: %zu access units: too few\n", nau); return 2; }

    signal(SIGTERM, on_term);
    ringmem = calloc(RING / 8, 8);
    pthread_t ct, at;
    core_status();
    pthread_create(&ct, NULL, core_thread, NULL);
    usleep(2000);

    struct h264ring_backend be;
    memset(&be, 0, sizeof be);
    be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING; be.barrier = be_barrier;
    h264ring *r = NULL;
    CHECK("attach to the fake core", h264ring_attach(&r, &be) == 0);
    if (!r) { printf("test_mister: FAILURES\n"); return 1; }
    CHECK("mister_attach starts a session", mister_attach(r) == 0 && nsess == 1);
    CHECK("setup accepts 720x480 H.264",
          decoder_callbacks_mister.setup(VIDEO_FORMAT_H264, 720, 480, 60, NULL, 0) == 0);
    CHECK("setup refuses HEVC", decoder_callbacks_mister.setup(VIDEO_FORMAT_H265, 720, 480, 60, NULL, 0) != 0);
    CHECK("setup accepts 1280x720 at 30 frames/s (0.11: 3,600 macroblocks, 108,000 a second)",
          decoder_callbacks_mister.setup(VIDEO_FORMAT_H264, 1280, 720, 30, NULL, 0) == 0);
    CHECK("setup refuses a picture over the core's 3,600 macroblocks (1920x1080 at 10: under the rate)",
          decoder_callbacks_mister.setup(VIDEO_FORMAT_H264, 1920, 1080, 10, NULL, 0) != 0);
    CHECK("setup refuses 1280x720 at 60 frames/s (over the core's 108,000 macroblocks a second)",
          decoder_callbacks_mister.setup(VIDEO_FORMAT_H264, 1280, 720, 60, NULL, 0) != 0);

    /* ---- S1: the stream, the audio concurrent ---- */
    pthread_create(&at, NULL, audio_thread, NULL);
    while (!video_may_start) usleep(200);
    size_t s1 = nau - 14;                            /* the last 14 are S2-S4's */
    char path[4096];
    snprintf(path, sizeof path, "%s.s1.dus", stem);
    FILE *dus = fopen(path, "w");
    int s1_ok = 1;
    for (size_t i = 0; i < s1; i++) {
        const uint8_t *p = buf + au[i].off;
        int rc = submit(p, au[i].len, has_idr(p, au[i].len) ? FRAME_TYPE_IDR : FRAME_TYPE_PFRAME, (unsigned)i);
        if (rc != DR_OK) s1_ok = 0;
        fprintf(dus, "%u %u\n", au[i].off, au[i].len);
        usleep(2000);                                /* the audio interleaves (~4 packets an AU) */
    }
    fclose(dus);
    audio_go = 0;
    pthread_join(at, NULL);
    settle();
    struct mister_counters c1;
    mister_get_counters(&c1);
    CHECK("S1: every decode unit accepted (DR_OK)", s1_ok && c1.au == s1 && c1.au_dropped == 0);
    CHECK("S1: the audio arriving before the first picture held back, the rest written",
          c1.aud_early > 0 && c1.aud_dropped == 0 && c1.aud + c1.aud_early == (unsigned long)npkt);
    CHECK("S1: lost packets concealed", c1.aud_plc > 0);
    CHECK("S1: no IDR asked, one session", idr_calls == 0 && c1.sessions == 1);
    /* the reference PCM of the packets written: those after the early ones */
    snprintf(path, sizeof path, "%s.s1.pcm", stem);
    f = fopen(path, "wb");
    size_t from = c1.aud_early < (unsigned long)npkt ? pkt_at[c1.aud_early] : ref_frames;
    fwrite(ref_pcm + 2 * from, 4, ref_frames - from, f);
    fclose(f);
    pthread_mutex_lock(&core_mx);
    write_sess(stem, 0);
    pthread_mutex_unlock(&core_mx);

    /* ---- S2: a decoder error: one IDR request; P frames refused until an IDR ---- */
    size_t k = s1;
    usleep(300000);                                  /* past IDR_GRACE_MS after S1's IDRs */
    pthread_mutex_lock(&core_mx); core.fe_err += 1; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    int rc_a = submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 1); k++;   /* written, then the error seen */
    pthread_mutex_lock(&core_mx); core.fe_err += 3; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    int rc_b = submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 2); k++;
    int rc_c = submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 3); k++;
    CHECK("S2: an error in the status block -> one IDR request (not one per error)",
          rc_a == DR_OK && idr_calls == 1);
    CHECK("S2: P frames while the IDR is awaited are not written (DR_NEED_IDR)",
          rc_b == DR_NEED_IDR && rc_c == DR_NEED_IDR);
    int rc_d = submit(buf + au[0].off, au[0].len, FRAME_TYPE_IDR, 4);
    /* errors of the pictures before the IDR, arriving just after it (the core lags a few) */
    pthread_mutex_lock(&core_mx); core.fe_err += 2; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    int rc_d2 = submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 5); k++;
    CHECK("S2: the IDR is written and the stream resumes",
          rc_d == DR_OK && rc_d2 == DR_OK && submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 5) == DR_OK &&
          idr_calls == 1);
    k++;

    /* ---- S3: the session dropped (an OSD Reset) ---- */
    pthread_mutex_lock(&core_mx); core.sess = 0; core.ack = 0; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    int rc_e = submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 6); k++;
    usleep(1100000);                                 /* past RESTART_MS: the restart is not luck */
    int rc_f = submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 7); k++;
    int nsess_after = nsess;
    int rc_g = submit(buf + au[0].off, au[0].len, FRAME_TYPE_IDR, 8);
    struct mister_counters c3;
    mister_get_counters(&c3);
    CHECK("S3: the write to a dropped session is refused (DR_NEED_IDR)", rc_e == DR_NEED_IDR);
    CHECK("S3: a new session, and a P frame is not its first record",
          nsess_after == 2 && c3.sessions == 2 && rc_f == DR_NEED_IDR);
    CHECK("S3: the IDR starts the new session", rc_g == DR_OK);
    settle();
    pthread_mutex_lock(&core_mx);
    write_sess(stem, 1);
    pthread_mutex_unlock(&core_mx);
    snprintf(path, sizeof path, "%s.s2.first", stem);
    f = fopen(path, "wb");
    fwrite(buf + au[0].off, 1, au[0].len, f);
    fclose(f);

    /* ---- S7 (fj#20): a CAVLC stream, rewritten into CABAC before it is written ---- */
    {
        size_t cn;
        uint8_t *cb = slurp(argv[3], &cn);
        size_t cnau = cb ? h264ring_split_annexb(cb, cn, NULL, 0) : 0;
        struct h264ring_au *cau = calloc(cnau ? cnau : 1, sizeof *cau);
        h264ring_split_annexb(cb, cn, cau, cnau);
        struct mister_counters c7a, c7b;
        mister_get_counters(&c7a);
        int s7_ok = cnau > 10;
        for (size_t i = 0; i < cnau; i++) {
            const uint8_t *p = cb + cau[i].off;
            if (submit(p, cau[i].len, has_idr(p, cau[i].len) ? FRAME_TYPE_IDR : FRAME_TYPE_PFRAME, 40 + (unsigned)i) != DR_OK)
                s7_ok = 0;
        }
        settle();
        mister_get_counters(&c7b);
        CHECK("S7: every CAVLC unit accepted and rewritten (DR_OK, counted)",
              s7_ok && c7b.au - c7a.au == cnau && c7b.au_rewritten - c7a.au_rewritten == cnau);
        pthread_mutex_lock(&core_mx);
        write_sess(stem, 1);                         /* session 2 again: S3's IDR, then S7 */
        pthread_mutex_unlock(&core_mx);
        free(cau);
        free(cb);
        /* back to the first stream as a host would switch: a new stream (setup), its IDR with its
         * parameter sets first (S7's PPS 0 was CAVLC; the first stream's P frames refer to its own) */
        decoder_callbacks_mister.setup(VIDEO_FORMAT_H264, 720, 480, 60, NULL, 0);
        submit(buf + au[0].off, au[0].len, FRAME_TYPE_IDR, 39);
    }

    /* ---- S4: a refusal ends the stream ---- */
    pthread_mutex_lock(&core_mx); core.fe_refused += 1; core.refused_code = 5; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    int idr_before = idr_calls;
    submit(buf + au[k].off, au[k].len, FRAME_TYPE_PFRAME, 9); k++;
    usleep(1000);
    struct mister_counters c4;
    mister_get_counters(&c4);
    CHECK("S4: a refusal ends the stream (SIGTERM), once, and asks for no IDR",
          sigterms == 1 && c4.refusals == 1 && idr_calls == idr_before);

    /* ---- S8 (fj#20): a stream the rewrite refuses ends like a refusal ---- */
    {
        size_t rn;
        uint8_t *rb = slurp(argv[4], &rn);
        usleep(1100000);                             /* past RESTART_MS: a session to write to */
        struct mister_counters c8a, c8b;
        mister_get_counters(&c8a);
        int terms8 = sigterms, idr8 = idr_calls, rc8 = rb ? submit(rb, (uint32_t)rn, FRAME_TYPE_IDR, 30) : -99;
        usleep(1000);
        int rc8b = rb ? submit(rb, (uint32_t)rn, FRAME_TYPE_IDR, 31) : -99;
        mister_get_counters(&c8b);
        CHECK("S8: a stream the CAVLC rewrite refuses ends (SIGTERM) once, nothing written, no IDR asked",
              rc8 == DR_OK && rc8b == DR_OK && sigterms == terms8 + 1 && c8b.refusals == c8a.refusals + 1 &&
              c8b.au == c8a.au && idr_calls == idr8);
        CHECK("S8: a new stream (setup) is written again",
              decoder_callbacks_mister.setup(VIDEO_FORMAT_H264, 720, 480, 60, NULL, 0) == 0);
        free(rb);
    }

    /* ---- S5: OSD_OPEN ---- */
    pthread_mutex_lock(&core_mx); core.osd = 1; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    mister_poll_status();
    int open1 = mister_osd_open();
    pthread_mutex_lock(&core_mx); core.osd = 0; pthread_mutex_unlock(&core_mx);
    usleep(5000);
    mister_poll_status();
    CHECK("S5: OSD_OPEN read from the status block, and its clearing", open1 && !mister_osd_open());
    {
        int w1, h1, w2, h2, w3, h3;
        pthread_mutex_lock(&core_mx); core.il = 1; core.aspect = 0; pthread_mutex_unlock(&core_mx);
        usleep(5000);
        mister_preferred_size(&w1, &h1);
        pthread_mutex_lock(&core_mx); core.il = 0; core.aspect = 1; pthread_mutex_unlock(&core_mx);
        usleep(5000);
        mister_preferred_size(&w2, &h2);
        pthread_mutex_lock(&core_mx); core.il = 0; core.aspect = 2; pthread_mutex_unlock(&core_mx);
        usleep(5000);
        mister_preferred_size(&w3, &h3);
        CHECK("S5: the size asked for follows the screen (480i 640x480, 4:3 640x480, 16:9 848x480)",
              w1 == 640 && h1 == 480 && w2 == 640 && h2 == 480 && w3 == 848 && h3 == 480);
    }

    /* ---- S6: the core unloaded: the stream ends ---- */
    /* as on the rig: a new session first (S4's refusal ended the last), then the core stops --
     * its words left as they were (the session still looks open), the ring no longer drained */
    usleep(1100000);                                 /* past RESTART_MS */
    submit(buf + au[0].off, au[0].len, FRAME_TYPE_IDR, 10);
    pthread_mutex_lock(&core_mx); core.dead = 1; pthread_mutex_unlock(&core_mx);
    int s6_sub = 0, s6_terms = sigterms;
    for (size_t j = 1; sigterms == s6_terms && s6_sub < 400; j = (j + 1) % s1, s6_sub++) {
        submit(buf + au[j].off, au[j].len, FRAME_TYPE_PFRAME, 12 + (unsigned)j);
        usleep(16000);                               /* a 60 frames/s host: 400 = 6.4 s */
    }
    struct mister_counters c6;
    mister_get_counters(&c6);
    CHECK("S6: the core unloaded ends the stream (SIGTERM), not a restart forever",
          sigterms == s6_terms + 1 && c6.core_gone == 1 && s6_sub < 400);

    decoder_callbacks_mister.cleanup();
    core.stop = 1;
    pthread_join(ct, NULL);
    mister_stop();

    snprintf(path, sizeof path, "%s.counters", stem);
    f = fopen(path, "w");
    fprintf(f, "au %lu\naud %lu\naud_early %lu\naud_plc %lu\n", c1.au, c1.aud, c1.aud_early, c1.aud_plc);
    fclose(f);
    printf("test_mister: %s\n", fails ? "FAILURES" : "ALL GREEN");
    return fails ? 1 : 0;
}
