/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/moonlight/src/mister/mister.c -- the "mister" platform of moonlight-embedded: every
 * decode unit becomes one VIDEO_AU record and every Opus packet, decoded here, one AUDIO record
 * in the MiSTer H264 core's ring (hps/include/h264ring.h). Design: docs/moonlight.md.
 *
 * - LOW_LATENCY | GRAPHICS on every access unit, no PTS: the core presents each picture as
 *   soon as it is decoded and plays the audio as it arrives against its own queue target
 *   (the host's clock is not the core's).
 * - One writer: moonlight-common-c calls the video and the audio from different threads and
 *   the library is not thread-safe, so every library call holds `ring_mx`. A full ring is
 *   waited out with the try_ calls and a sleep OUTSIDE the mutex.
 * - Errors ask the host for an IDR: the core's error counters (front end, reconstruction)
 *   are read after every access unit. A session the core dropped (the OSD's Reset:
 *   -ENOTCONN) or stopped in ERROR is restarted, and the next access unit written is an IDR.
 * - A refusal (the stream uses something the core does not decode) ends the stream, by name:
 *   no IDR cures it, and the project's rule is to refuse loudly.
 * - The core unloaded (the user loaded another core, or the menu, from Main's OSD: the way out
 *   of a view-only stream) ends the stream: the status block's heartbeat (seq_head, +1 a frame)
 *   still for ALIVE_MS. An unloaded core's words stay as they were -- the session still looks
 *   open, the ring just stops draining -- so the heartbeat is the only sign. An OSD Reset keeps
 *   the heartbeat, so its session is restarted.
 * - Audio waits for the session's first access unit: a stream's mode (paced / low latency) is
 *   its first VIDEO_AU's, and audio ahead of it would start paced.
 * - CAVLC: the library's write call rewrites it into CABAC (h264ring_cavlc.h, fj#20,
 *   docs/cavlc.md): a host forced to CAVLC (amd_coder=cavlc, nvenc_h264_cavlc, qsv_coder) plays,
 *   up to the A9's ceiling (~4-5 Mbit/s at 480p60); a CABAC stream passes untouched. What the
 *   rewrite refuses (-EOPNOTSUPP) ends the stream like a core refusal; a unit it cannot parse
 *   (-EBADMSG) is dropped and an IDR awaited.
 */
#include "mister.h"

#include "h264ring.h"
#include "h264ring_cavlc.h"

#include <opus_multistream.h>

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define AU_FLAGS        (H264RING_F_LOW_LATENCY | H264RING_F_GRAPHICS)
#define VIDEO_WAIT_MS   500     /* a full ring: the decoder is this far behind -- give up the AU */
#define AUDIO_WAIT_MS   20      /* audio is dropped rather than held (the core conceals a gap) */
#define LAUNCH_MS       15000   /* loading the core and its first heartbeat */
#define SESSION_MS      2000
#define ALIVE_MS        1500    /* no heartbeat for this long: the core is not running */
#define IDR_RETRY_MS    1000    /* an IDR asked for and not seen: ask again after this */
#define IDR_GRACE_MS    250     /* after an IDR is written, errors still arriving belong to the
                                 * pictures before it (the core lags a few): not a new request */
#define RESTART_MS      1000    /* a session that would not start: try again after this */
#define W_EARLY         1       /* write_record: audio before the session's first access unit */

static h264ring *ring;
static pthread_mutex_t ring_mx = PTHREAD_MUTEX_INITIALIZER;

/* the session (under ring_mx) */
static bool session_ok;         /* a session is open and no error seen on it */
static bool video_started;      /* this session's first access unit (an IDR) is written */
static bool need_idr;           /* write nothing until an IDR arrives */
static uint32_t err_base;       /* the error counters' sum when last judged */
static uint64_t idr_asked_ms;   /* when LiRequestIdrFrame was last called (0: not waiting) */
static uint64_t idr_written_ms; /* when the last IDR was written */
static uint64_t restart_ms;     /* the last session start tried */
static volatile bool restarting;  /* a session start holds ring_mx (up to SESSION_MS): the
                                   * audio drops its packet instead of waiting behind it */
static uint32_t refused_base;   /* FE_REFUSED when last judged */
static uint32_t beat;           /* the last heartbeat (seq_head) seen */
static uint64_t beat_ms;        /* when it last moved (0: none seen yet) */
static volatile bool osd_open;

/* the video's buffer: a decode unit's entries concatenated */
static uint8_t *au_buf;
static size_t au_cap;
static bool cavlc_refused;       /* the rewrite refused this stream: ended once, nothing more written */

/* the audio */
static OpusMSDecoder *opus;
static int16_t *pcm;
static int pcm_frames;          /* the largest packet, in frames */

/* counters, printed at the end */
static struct mister_counters n;

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

bool mister_detect(void) {
    return access("/dev/MiSTer_cmd", W_OK) == 0;
}

bool mister_osd_open(void) {
    return osd_open;
}

h264ring *mister_ring(void) {
    return ring;
}

/* ---- the session (callers hold ring_mx) ---- */

static uint32_t err_sum(const struct h264ring_status *st) {
    return (uint32_t)(H264RING_ST(st, FE_ERR) + H264RING_ST(st, RC_ERR));
}

/* the refusal codes (FE_REFUSED_CODE): h264/dec/h264_pkg.sv's REF_*, which the library does
 * not name yet */
static const char *refusal_name(unsigned code) {
    static const char *const names[] = {
        "none", "chroma format (not 4:2:0)", "bit depth (not 8)", "scaling lists",
        "MBAFF interlacing", "CAVLC (not CABAC)", "FMO (slice groups)", "8x8 transform",
        "redundant pictures", "SP / SI slices", "data partitioning", "SVC / MVC",
        "picture dimension (more than 128 macroblocks)",
    };
    return code < sizeof(names) / sizeof(names[0]) ? names[code] : "unknown";
}

/* the core is no longer running: end the stream (once) */
static void core_gone_locked(void) {
    if (n.core_gone)
        return;
    fprintf(stderr, "mister: the H264 core is no longer running (another core was loaded) -- "
            "ending the stream\n");
    session_ok = false;
    n.core_gone++;
    kill(getpid(), SIGTERM);   /* the main loop's signalfd: the stream ends cleanly */
}

static int session_start_locked(void) {
    restart_ms = now_ms();
    restarting = true;
    int rc = h264ring_start_session(ring, SESSION_MS);
    if (rc && n.sessions > 0 && h264ring_alive(ring, ALIVE_MS) != 0) {
        restarting = false;
        core_gone_locked();
        return rc;
    }
    restarting = false;
    if (rc) {
        fprintf(stderr, "mister: no session (%s)\n", strerror(-rc));
        session_ok = false;
        return rc;
    }
    struct h264ring_status st;
    if (h264ring_status(ring, &st) == 0) {
        err_base = err_sum(&st);
        refused_base = (uint32_t)H264RING_ST(&st, FE_REFUSED);
    }
    session_ok = true;
    video_started = false;
    need_idr = true;
    n.sessions++;
    return 0;
}

/* read the status: OSD_OPEN for the input, the error counters, the session's health */
static void poll_status_locked(void) {
    struct h264ring_status st;
    if (!ring || h264ring_status(ring, &st))
        return;
    uint32_t seq = (uint32_t)H264RING_ST(&st, SEQ_HEAD);
    if (seq != beat || !beat_ms) {
        beat = seq;
        beat_ms = now_ms();
    } else if (now_ms() - beat_ms >= ALIVE_MS) {
        core_gone_locked();
        return;
    }
    osd_open = (H264RING_ST(&st, LIVE) & H264RING_L_OSD_OPEN) != 0;
    if (H264RING_ST(&st, STATE) == H264RING_S_ERROR && session_ok) {
        fprintf(stderr, "mister: the core stopped the session: %s at %u\n",
                h264ring_error_name((unsigned)H264RING_ST(&st, ERR)), (unsigned)H264RING_ST(&st, ERR_POS));
        session_ok = false;
    }
    uint32_t refused = (uint32_t)H264RING_ST(&st, FE_REFUSED);
    if (refused != refused_base && session_ok) {
        fprintf(stderr, "mister: the core refused the stream: %s -- ending it\n",
                refusal_name((unsigned)H264RING_ST(&st, FE_REFUSED_CODE)));
        refused_base = refused;
        session_ok = false;
        n.refusals++;
        kill(getpid(), SIGTERM);   /* the main loop's signalfd: the stream ends cleanly */
        return;
    }
    uint32_t e = err_sum(&st);
    if (e != err_base && idr_written_ms && now_ms() - idr_written_ms < IDR_GRACE_MS) {
        n.errors_seen += e - err_base;
        err_base = e;               /* the pictures before the IDR: it already cures them */
    } else if (e != err_base) {
        /* the decoder met an error in an access unit already written: ask for an IDR, once
         * until one is written (or IDR_RETRY_MS passes) */
        n.errors_seen += e - err_base;
        err_base = e;
        if (!need_idr || (idr_asked_ms && now_ms() - idr_asked_ms > IDR_RETRY_MS)) {
            need_idr = true;
            idr_asked_ms = now_ms();
            n.idr_asked++;
            LiRequestIdrFrame();
        }
    }
}

void mister_preferred_size(int *width, int *height) {
    struct h264ring_status st;
    int four3 = 0, known = 0;
    pthread_mutex_lock(&ring_mx);
    if (ring && h264ring_status(ring, &st) == 0) {
        known = 1;
        four3 = H264RING_ST(&st, RASTER_IL) || H264RING_ST(&st, OSD_ASPECT) == 1;
    }
    pthread_mutex_unlock(&ring_mx);
    *width = four3 ? 640 : 848;
    *height = 480;
    fprintf(stderr, "mister: the screen is %s%s: asking the host for %dx%d\n", four3 ? "4:3" : "16:9",
            known ? "" : " (the core not read)", *width, *height);
}

void mister_poll_status(void) {
    if (restarting)
        return;
    pthread_mutex_lock(&ring_mx);
    poll_status_locked();
    pthread_mutex_unlock(&ring_mx);
}

int mister_start(void) {
    int rc = h264ring_launch_core(NULL, LAUNCH_MS);
    if (rc) {
        fprintf(stderr, "mister: the H264 core did not start (%s)\n", strerror(-rc));
        return rc;
    }
    h264ring *r;
    rc = h264ring_open_devmem(&r, 0);
    if (rc) {
        fprintf(stderr, "mister: cannot attach to the core (%s)%s\n", strerror(-rc),
                rc == -EBUSY ? ": another program is feeding it" : "");
        return rc;
    }
    return mister_attach(r);
}

int mister_attach(h264ring *r) {
    pthread_mutex_lock(&ring_mx);
    ring = r;
    int rc = session_start_locked();
    pthread_mutex_unlock(&ring_mx);
    return rc;
}

void mister_get_counters(struct mister_counters *c) {
    *c = n;
}

void mister_stop(void) {
    pthread_mutex_lock(&ring_mx);
    if (ring)
        h264ring_close(ring);
    ring = NULL;
    session_ok = false;
    pthread_mutex_unlock(&ring_mx);
    fprintf(stderr, "mister: %lu access units (%lu bytes, %lu rewritten from CAVLC), %lu dropped; %lu decoder "
            "errors, %lu IDRs asked; %lu sessions; audio %lu records, %lu dropped, %lu before the video, "
            "%lu concealed\n", n.au, n.au_bytes, n.au_rewritten, n.au_dropped, n.errors_seen, n.idr_asked,
            n.sessions, n.aud, n.aud_dropped, n.aud_early, n.aud_plc);
}

/* one record, waiting out a full ring outside the mutex. Returns 0, W_EARLY, or a negative
 * errno (-ETIMEDOUT: the ring stayed full; -ENOTCONN / -EPROTO: the session is gone). */
static int write_record(bool audio, const void *p, uint32_t len, bool idr, unsigned wait_ms) {
    uint64_t t0 = now_ms();
    for (;;) {
        int rc;
        if (audio && restarting)
            return -ENOTCONN;
        pthread_mutex_lock(&ring_mx);
        if (!ring || !session_ok) {
            rc = -ENOTCONN;
        } else if (audio && !video_started) {
            rc = W_EARLY;           /* not yet: see the header */
        } else {
            rc = audio ? h264ring_try_write_audio(ring, p, len, -1)
                       : h264ring_try_write_au(ring, p, len, -1, AU_FLAGS);
            if (rc == 0 && idr) {       /* an IDR: the session's first, or a cure */
                video_started = true;
                idr_written_ms = now_ms();
            }
            if (rc == -ENOTCONN || rc == -EPROTO)
                session_ok = false;
        }
        pthread_mutex_unlock(&ring_mx);
        if (rc != -EAGAIN)
            return rc;
        if (now_ms() - t0 >= wait_ms)
            return -ETIMEDOUT;
        usleep(1000);
    }
}

/* ---- video ---- */

static int mister_setup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) {
    if (!(videoFormat & VIDEO_FORMAT_MASK_H264)) {
        fprintf(stderr, "mister: the core decodes H.264 only\n");
        return -1;
    }
    if (!ring) {
        fprintf(stderr, "mister: not attached (mister_start)\n");
        return -1;
    }
    /* (interface 0.11) the core's limits, word 81: 3,600 macroblocks a picture (1280x720) and
     * 108,000 a second (720p30, 480p60: Level 3.1). Past the rate the core would show about every
     * other picture (low latency skips, counted): refused, as the size is (docs/moonlight.md) */
    struct h264ring_status st;
    struct h264ring_caps caps;
    pthread_mutex_lock(&ring_mx);
    int got = h264ring_status(ring, &st) == 0;
    pthread_mutex_unlock(&ring_mx);
    if (!got)
        memset(&st, 0, sizeof st);
    h264ring_caps(&st, &caps);
    long mbs = (long)((width + 15) / 16) * ((height + 15) / 16);
    if (mbs > (long)caps.max_mbs) {
        fprintf(stderr, "mister: %dx%d is %ld macroblocks a picture; the core decodes at most %u (1280x720)\n",
                width, height, mbs, caps.max_mbs);
        return -1;
    }
    if (mbs * redrawRate > (long)caps.mb_rate * 101 / 100) {
        fprintf(stderr, "mister: %dx%d at %d frames/s is %ld macroblocks a second; the core decodes at most "
                "%u (1280x720 at 30, 854x480 at 60): ask the host for fewer frames a second (-fps 30)\n",
                width, height, redrawRate, mbs * redrawRate, caps.mb_rate);
        return -1;
    }
    cavlc_refused = false;
    return 0;
}

static void mister_cleanup(void) {
    free(au_buf);
    au_buf = NULL;
    au_cap = 0;
    pthread_mutex_lock(&ring_mx);
    if (ring) {
        struct h264ring_cavlc_stats cs;
        h264ring_rewrite_stats(ring, &cs);
        if (cs.units_rewritten)
            fprintf(stderr, "mister: CAVLC: %llu access units rewritten into CABAC (%llu bins)\n",
                    (unsigned long long)cs.units_rewritten, (unsigned long long)cs.bins);
    }
    pthread_mutex_unlock(&ring_mx);
}

static int mister_submit(PDECODE_UNIT du) {
    bool idr = du->frameType == FRAME_TYPE_IDR;

    pthread_mutex_lock(&ring_mx);
    if (ring && !session_ok && !n.core_gone && now_ms() - restart_ms >= RESTART_MS)
        session_start_locked();
    bool wait_idr = need_idr;
    bool ok = session_ok;
    if (idr) {
        need_idr = false;
        idr_asked_ms = 0;
    }
    pthread_mutex_unlock(&ring_mx);

    if (!ok || (wait_idr && !idr)) {
        /* not written: no session, or an IDR is awaited (moonlight-common-c asks for one and
         * drops what follows until it). The status is still read: the heartbeat is how an
         * unloaded core is noticed. */
        pthread_mutex_lock(&ring_mx);
        poll_status_locked();
        pthread_mutex_unlock(&ring_mx);
        n.au_dropped++;
        return DR_NEED_IDR;
    }

    if ((size_t)du->fullLength > au_cap) {
        size_t cap = (size_t)du->fullLength * 2;
        uint8_t *b = realloc(au_buf, cap);
        if (!b) {
            n.au_dropped++;
            return DR_NEED_IDR;
        }
        au_buf = b;
        au_cap = cap;
    }
    size_t len = 0;
    for (PLENTRY e = du->bufferList; e != NULL; e = e->next) {
        memcpy(au_buf + len, e->data, (size_t)e->length);
        len += (size_t)e->length;
    }

    if (cavlc_refused) {
        n.au_dropped++;
        return DR_OK;               /* the stream is ending (SIGTERM sent): nothing more */
    }

    int rc = write_record(false, au_buf, (uint32_t)len, idr, VIDEO_WAIT_MS);
    if (rc == -EOPNOTSUPP) {        /* the library's CAVLC rewrite refused the stream (fj#20) */
        pthread_mutex_lock(&ring_mx);
        fprintf(stderr, "mister: the stream cannot be given to the core (%s) -- ending it\n",
                h264ring_rewrite_why(ring));
        pthread_mutex_unlock(&ring_mx);
        cavlc_refused = true;
        n.refusals++;
        n.au_dropped++;
        kill(getpid(), SIGTERM);    /* as a core refusal: no IDR cures it */
        return DR_OK;
    }
    if (rc == -EBADMSG) {           /* a CAVLC unit the rewrite cannot parse: skip to an IDR */
        pthread_mutex_lock(&ring_mx);
        fprintf(stderr, "mister: access unit %lu not rewritten (%s)\n", n.au, h264ring_rewrite_why(ring));
        need_idr = true;
        pthread_mutex_unlock(&ring_mx);
        n.au_dropped++;
        return DR_NEED_IDR;
    }
    if (rc) {
        pthread_mutex_lock(&ring_mx);
        if (rc != -ENOTCONN && !n.core_gone)
            fprintf(stderr, "mister: access unit %lu not written (%s)\n", n.au, strerror(-rc));
        need_idr = true;
        poll_status_locked();      /* a ring that stopped draining: is the core still there? */
        pthread_mutex_unlock(&ring_mx);
        n.au_dropped++;
        return DR_NEED_IDR;
    }
    n.au++;
    n.au_bytes += len;

    pthread_mutex_lock(&ring_mx);
    {
        struct h264ring_cavlc_stats cs;
        h264ring_rewrite_stats(ring, &cs);
        n.au_rewritten = (unsigned long)cs.units_rewritten;
    }
    poll_status_locked();
    pthread_mutex_unlock(&ring_mx);
    return DR_OK;
}

DECODER_RENDERER_CALLBACKS decoder_callbacks_mister = {
    .setup = mister_setup,
    .cleanup = mister_cleanup,
    .submitDecodeUnit = mister_submit,
    .capabilities = 0,     /* the decoder thread, not the receive thread; no RFI (moonlight.md) */
};

/* ---- audio: Opus decoded here, 48 kHz s16 stereo to the core (D2) ---- */

static int mister_audio_init(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION cfg, void *context, int arFlags) {
    if (cfg->sampleRate != H264RING_AUD_RATE || cfg->channelCount != 2) {
        fprintf(stderr, "mister: audio %d Hz x %d channels; the core plays 48 kHz stereo\n",
                cfg->sampleRate, cfg->channelCount);
        return -1;
    }
    int err;
    opus = opus_multistream_decoder_create(cfg->sampleRate, cfg->channelCount, cfg->streams,
                                           cfg->coupledStreams, cfg->mapping, &err);
    if (!opus) {
        fprintf(stderr, "mister: opus decoder: %d\n", err);
        return -1;
    }
    pcm_frames = cfg->samplesPerFrame;
    pcm = malloc(sizeof(int16_t) * 2 * (size_t)pcm_frames);
    return pcm ? 0 : -1;
}

static void mister_audio_cleanup(void) {
    if (opus)
        opus_multistream_decoder_destroy(opus);
    opus = NULL;
    free(pcm);
    pcm = NULL;
}

static void mister_audio_sample(char *data, int length) {
    /* data NULL: a lost packet -- libopus conceals it, so the core's queue keeps its length */
    int frames = opus_multistream_decode(opus, (const unsigned char *)data, length, pcm, pcm_frames, 0);
    if (frames <= 0) {
        n.aud_dropped++;
        return;
    }
    if (!data)
        n.aud_plc++;
    int rc = write_record(true, pcm, (uint32_t)frames * 4u, false, AUDIO_WAIT_MS);
    if (rc == 0)
        n.aud++;
    else if (rc == W_EARLY)
        n.aud_early++;
    else
        n.aud_dropped++;
}

AUDIO_RENDERER_CALLBACKS audio_callbacks_mister = {
    .init = mister_audio_init,
    .cleanup = mister_audio_cleanup,
    .decodeAndPlaySample = mister_audio_sample,
    .capabilities = CAPABILITY_DIRECT_SUBMIT,   /* decoding a 5 ms packet is quick; no queue */
};
