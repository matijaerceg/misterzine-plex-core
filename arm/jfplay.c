/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 Matija Erceg
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "h264ring.h"
#include "audio_boost.h"
#include "h264_idr.h"
#include "film_speed.h"
#include "seek_cache.h"
#include "seek_protocol.h"
#include "video_geometry.h"
#include "core_owner.h"
#include "direct_check.h"
#include "packet_pacing.h"
#include "lag_watch.h"

#define Q_PACKETS 8192
#define Q_BYTES (64u * 1024u * 1024u)
#define Q_AHEAD_TICKS (45LL * 90000LL)
#define AUDIO_LEAD 90000
#define VIDEO_LEAD 9000 /* a video AU may run at most 0.1 s past the audio written: audio leads in ring order */
#define AUDIO_RECORD_FRAMES 960
#define PCM_MAX_FRAMES 96000
#define CORE_HEARTBEAT_TIMEOUT_MS 100
#define PCM_DECODE_RESERVE 8192
#define PTS_MARGIN 90000
#define PTS_CONTIG_TOLERANCE 90
#define AUDIO_RESYNC_TOLERANCE 9000 /* 0.1 s: a decoded frame's timestamp this near the sample clock follows it */

enum seek_state { SEEK_IDLE, SEEK_IN_PROGRESS, SEEK_READY, SEEK_ERROR };

enum exit_code { EX_OK = 0, EX_ARGS = 2, EX_CORE = 3, EX_OPEN = 4,
                 EX_REFUSED = 5, EX_STREAM = 6,
                 /* --direct only: the stream needs a server transcode (the
                  * pre-check failed, or the core could not keep up) */
                 EX_NEEDS_TRANSCODE = 7 };
enum playback_state { STATE_OPENING, STATE_PLAYING, STATE_PAUSED,
                      STATE_ENDED, STATE_ERROR };

struct config {
    const char *url, *rbf, *headers, *cafile, *fifo, *status;
    const char *core_name;  /* --core-name: the app's own name for the core, or NULL */
    double base, start_in_file;
    int audio_index, hold, volume, audio_boost, surround_source, direct;
    int analog_aspect, analog_aspect_set;
    int anti_twitter, anti_twitter_set;
    struct video_geometry_config geometry;
    int geometry_set;
};

struct packet_node { AVPacket *pkt; uint64_t seq; struct packet_node *next; };
struct packet_queue { struct packet_node *head, *tail; unsigned count; size_t bytes; };
struct pcm_chunk {
    uint8_t *data;
    size_t frames, offset;
    int64_t pts90;
    struct pcm_chunk *next;
};
struct pcm_queue { struct pcm_chunk *head, *tail; size_t frames; };

struct reader {
    AVFormatContext *fmt;
    int vi, ai;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    struct packet_queue vq, aq;
    uint64_t seq;
    size_t bytes;
    int done, eof_wait, mutex_init, cond_init, queue_wait;
    atomic_int abort, err;
    atomic_int seek_interrupt;
    atomic_int_fast64_t playhead90;
    int seek_requested, seek_parked, seek_go, seek_rc;
    int seek_from_cache;
    int64_t seek_target_us;
};

struct player {
    struct config cfg;
    h264ring *ring;
    AVFormatContext *fmt;
    AVCodecContext *adec;
    AVBSFContext *bsf;
    SwrContext *swr;
    AVChannelLayout swr_in;
    enum AVSampleFormat swr_fmt;
    int swr_rate;
    struct reader rd;
    int fifo_fd, paused, opened, saw_idr, input_done, reader_joined;
    int core_owned;
    struct jfplay_core_owner core_owner;
    atomic_int stop, exit_code;
    enum playback_state state;
    int audio_channels_in, origin_ready;
    AVRational nominal_video_rate;
    struct film_speed film_speed;
    unsigned geometry_raster_w, geometry_raster_h, geometry_video_out, geometry_wide;
    int geometry_status_valid;
    int64_t origin90, newest_video90, newest_audio90, audio_next90;
    int audio_ring_full; /* the last audio write found the ring full */
    int have_stop_position, stop_reset_failed;
    int seek_state, seek_reset_done, seek_was_paused, seek_id;
    int seek_cache_hit;
    int64_t seek_target90, seek_current90;
    uint64_t seek_started_ms;
    double seek_position, seek_actual_position;
    char seek_error[256];
    int64_t buffered_video_start90, buffered_video_end90;
    int64_t buffered_audio_start90, buffered_audio_end90;
    int64_t nominal_video_duration90;
    int buffered_video_valid, buffered_video_broken;
    int buffered_audio_valid, buffered_audio_broken;
    double stop_position;
    unsigned long dbg_splits, dbg_pad, dbg_untimed;
    AVPacket *held_video;
    struct pcm_queue pcm;
    uint64_t last_status_ms;
    char error[256];
    struct direct_check dcheck;   /* --direct: the SPS / PPS pre-check */
    int direct_ok;                /* --direct: the pre-check passed */
    struct lag_watch lag;         /* --direct: the keep-up watchdog */
    unsigned lag_reanchor;        /* last DISP_REANCHOR the watchdog saw */
    int lag_reanchor_seen;
};

static volatile sig_atomic_t caught_signal;

static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void logmsg(const char *fmt, ...)
{
    struct timespec ts;
    struct tm tm;
    char stamp[32];
    va_list ap;
    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(stderr, "[%s.%03ld] jfplay: ", stamp, ts.tv_nsec / 1000000);
    va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
}

/* MiSTer keeps /tmp/CORENAME updated when the user changes cores.  The
 * devmem mapping stays valid across that change, but its target does not. */
static int read_core_name(char name[128])
{
    FILE *f = fopen("/tmp/CORENAME", "r");
    if (!f) return 0;
    int ok = fgets(name, 128, f) != NULL;
    fclose(f);
    return ok;
}

static int core_name_matches(const struct player *p)
{
    char name[128] = {0};
    return read_core_name(name) && jfplay_core_name_owned(name, p->cfg.core_name);
}

static int core_owner_ok(struct player *p)
{
    if (!p->core_owned || p->core_owner.lost) return 0;
    char name[128] = {0};
    int have_name = read_core_name(name);
    struct h264ring_status st;
    int have_status = have_name && jfplay_core_name_owned(name, p->cfg.core_name) &&
                      p->ring && !h264ring_status(p->ring, &st);
    int ok = jfplay_core_owner_check(&p->core_owner,
                                     have_name ? name : NULL,
                                     have_status,
                                     have_status ? H264RING_ST(&st, SEQ_HEAD) : 0,
                                     mono_ms(), CORE_HEARTBEAT_TIMEOUT_MS);
    if (!ok) {
        logmsg("H.264 core ownership or raster heartbeat lost; stopping without further core access");
        if (!atomic_load(&p->exit_code)) atomic_store(&p->exit_code, EX_CORE);
        atomic_store(&p->stop, 1);
        p->state = STATE_ERROR;
        snprintf(p->error, sizeof p->error, "H.264 core was replaced, unloaded, or stopped rastering");
    }
    return ok;
}

static void fail(struct player *p, int code, const char *fmt, ...)
{
    va_list ap;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&p->exit_code, &expected, code)) return;
    p->state = STATE_ERROR;
    va_start(ap, fmt); vsnprintf(p->error, sizeof p->error, fmt, ap); va_end(ap);
    for (char *s = p->error; *s; ++s) if (*s == '\n' || *s == '\r') *s = ' ';
    logmsg("%s", p->error);
}

static void signal_handler(int sig) { (void)sig; caught_signal = 1; }

static int parse_int(const char *s, int lo, int hi, int *out)
{
    char *end;
    long v;
    errno = 0; v = strtol(s, &end, 10);
    if (errno || !*s || *end || v < lo || v > hi) return -1;
    *out = (int)v; return 0;
}

static void usage(void)
{
    fprintf(stderr, "usage: jfplay [--rbf path] [--core-name NAME] [--base SECONDS] [--start-in-file SECONDS] [--audio INDEX] "
            "[--headers TEXT] [--cafile path] [--fifo path] [--status path] "
            "[--hold] [--direct] [--volume 0-100] [--audio-boost 100-300] [--surround-source] "
            "[--analog-aspect 0-4] [--anti-twitter 0-2] "
            "[--geometry LEFT,TOP,RIGHT,BOTTOM,WIDTH] URL\n");
}

static int parse_args(int argc, char **argv, struct config *c)
{
    memset(c, 0, sizeof *c);
    c->rbf = "_Other/H264"; c->fifo = "/tmp/jfplay.ctl";
    c->status = "/tmp/jfplay.status"; c->audio_index = -1; c->volume = 100; c->audio_boost = 100;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--hold")) c->hold = 1;
        else if (!strcmp(argv[i], "--surround-source")) c->surround_source = 1;
        else if (!strcmp(argv[i], "--direct")) c->direct = 1;
        else if (!strcmp(argv[i], "--rbf") && ++i < argc) c->rbf = argv[i];
        else if (!strcmp(argv[i], "--core-name") && ++i < argc) c->core_name = argv[i];
        else if (!strcmp(argv[i], "--headers") && ++i < argc) c->headers = argv[i];
        else if (!strcmp(argv[i], "--cafile") && ++i < argc) c->cafile = argv[i];
        else if (!strcmp(argv[i], "--fifo") && ++i < argc) c->fifo = argv[i];
        else if (!strcmp(argv[i], "--status") && ++i < argc) c->status = argv[i];
        else if (!strcmp(argv[i], "--audio") && ++i < argc) {
            if (parse_int(argv[i], 0, INT32_MAX, &c->audio_index)) return -1;
        } else if (!strcmp(argv[i], "--volume") && ++i < argc) {
            if (parse_int(argv[i], 0, 100, &c->volume)) return -1;
        } else if (!strcmp(argv[i], "--audio-boost") && ++i < argc) {
            if (parse_int(argv[i], 100, 300, &c->audio_boost)) return -1;
        } else if (!strcmp(argv[i], "--analog-aspect") && ++i < argc) {
            if (parse_int(argv[i], 0, 4, &c->analog_aspect)) return -1;
            c->analog_aspect_set = 1;
        } else if (!strcmp(argv[i], "--geometry") && ++i < argc) {
            struct video_geometry_config *g = &c->geometry;
            char extra;
            if (sscanf(argv[i], "%d,%d,%d,%d,%d%c", &g->left, &g->top, &g->right,
                       &g->bottom, &g->width, &extra) != 5) return -1;
            struct video_geometry_result check;
            if (video_geometry_compute(g, 4, 3, 480, 480, VIDEO_MODE_LETTERBOX, &check)) return -1;
            c->geometry_set = check.override_required;
        } else if (!strcmp(argv[i], "--anti-twitter") && ++i < argc) {
            if (parse_int(argv[i], 0, 2, &c->anti_twitter)) return -1;
            c->anti_twitter_set = 1;
        } else if ((!strcmp(argv[i], "--base") || !strcmp(argv[i], "--start-in-file")) && ++i < argc) {
            int start = !strcmp(argv[i - 1], "--start-in-file");
            char *end; double value; errno = 0; value = strtod(argv[i], &end);
            if (errno || !*argv[i] || *end || !isfinite(value) || value < 0) return -1;
            if (start) c->start_in_file = value; else c->base = value;
        } else if (argv[i][0] == '-' || c->url) return -1;
        else c->url = argv[i];
    }
    /* The app passes the headers (they carry the token) in the environment:
     * /proc/<pid>/cmdline is readable by every process, environ only by the
     * owner. --headers stays for runs by hand. */
    if (!c->headers) {
        const char *env = getenv("JFPLAY_HEADERS");
        if (env && *env) c->headers = env;
    }
    return c->url ? 0 : -1;
}

/* Socket read/connect timeout (tcp's "timeout", reaching tcp through http and
 * tls). Without one a connection that goes silent, such as after a Wi-Fi drop
 * the server gave up on, blocks the reader forever with the status still
 * "playing". A direct stream is a static file and answers at once; a transcode
 * can hold a segment request while the server starts encoding (over 30 s with
 * burned-in subtitles), so it gets longer. */
#define NET_TIMEOUT_DIRECT_US    "15000000"
#define NET_TIMEOUT_TRANSCODE_US "60000000"

static void net_options(const struct config *c, AVDictionary **d)
{
    av_dict_set(d, "timeout", c->direct ? NET_TIMEOUT_DIRECT_US : NET_TIMEOUT_TRANSCODE_US, 0);
    /* After a read error or a premature end, reconnect and resume at the same
     * offset (a response of known length), backing off for about two minutes
     * (FFmpeg's reconnect_delay_max / reconnect_delay_total_max) before failing. */
    av_dict_set(d, "reconnect", "1", 0);
    av_dict_set(d, "reconnect_on_network_error", "1", 0);
    if (c->headers) av_dict_set(d, "headers", c->headers, 0);
    if (c->cafile) {
        av_dict_set(d, "tls_verify", "1", 0);
        av_dict_set(d, "cafile", c->cafile, 0);
    }
}

static int io_open(AVFormatContext *s, AVIOContext **pb, const char *url,
                   int flags, AVDictionary **options)
{
    struct config *c = s->opaque;
    net_options(c, options);
    return avio_open2(pb, url, flags, &s->interrupt_callback, options);
}

static int interrupt_cb(void *opaque)
{
    struct player *p = opaque;
    if (p->core_owned && !core_name_matches(p)) {
        int expected = 0;
        atomic_compare_exchange_strong(&p->exit_code, &expected, EX_CORE);
        atomic_store(&p->stop, 1);
        return 1;
    }
    return atomic_load(&p->stop) || caught_signal ||
           atomic_load(&p->exit_code) || atomic_load(&p->rd.abort) ||
           atomic_load(&p->rd.seek_interrupt);
}

static void q_push(struct packet_queue *q, struct packet_node *n)
{
    n->next = NULL;
    if (q->tail) q->tail->next = n; else q->head = n;
    q->tail = n; q->count++; q->bytes += (size_t)n->pkt->size;
}

static AVPacket *q_pop(struct packet_queue *q)
{
    struct packet_node *n = q->head;
    AVPacket *pkt;
    if (!n) return NULL;
    q->head = n->next; if (!q->head) q->tail = NULL;
    q->count--; q->bytes -= (size_t)n->pkt->size;
    pkt = n->pkt; free(n); return pkt;
}

/* The demux reader is the only thread that owns AVFormatContext while active. */
static int reader_handle_seek(struct reader *r)
{
    int64_t target_us;
    int use_cache;
    int rc;
    pthread_mutex_lock(&r->mutex);
    if (!r->seek_requested || atomic_load(&r->abort)) {
        pthread_mutex_unlock(&r->mutex);
        return atomic_load(&r->abort) ? AVERROR_EXIT : 0;
    }
    r->seek_parked = 1;
    pthread_cond_broadcast(&r->changed);
    while (!r->seek_go && !atomic_load(&r->abort))
        pthread_cond_wait(&r->changed, &r->mutex);
    if (atomic_load(&r->abort)) {
        pthread_mutex_unlock(&r->mutex);
        return AVERROR_EXIT;
    }
    target_us = r->seek_target_us;
    use_cache = r->seek_from_cache;
    r->seek_go = 0;
    pthread_mutex_unlock(&r->mutex);

    if (use_cache) {
        /* Keep the demux cursor after the queued packets for a cache hit. */
        atomic_store(&r->seek_interrupt, 0);
        rc = 0;
    } else {
        /* This thread remains the sole owner of AVFormatContext. */
        atomic_store(&r->seek_interrupt, 0);
        rc = avformat_seek_file(r->fmt, -1, INT64_MIN, target_us,
                                target_us, AVSEEK_FLAG_BACKWARD);
        if (rc >= 0) avformat_flush(r->fmt);
    }

    pthread_mutex_lock(&r->mutex);
    r->seek_rc = rc;
    r->seek_requested = 0;
    r->seek_parked = 0;
    r->done = 0;
    r->eof_wait = 0;
    atomic_store(&r->err, 0);
    if (rc < 0) atomic_store(&r->err, rc);
    pthread_cond_broadcast(&r->changed);
    pthread_mutex_unlock(&r->mutex);
    return rc < 0 ? rc : use_cache ? 2 : 1;
}

static int packet_beyond_reader_horizon(struct reader *r, const AVPacket *pkt);

static void *reader_main(void *arg)
{
    struct reader *r = arg;
    for (;;) {
        AVPacket *pkt;
        struct packet_node *n;
        int rc;
        pthread_mutex_lock(&r->mutex);
        int seek_requested = r->seek_requested;
        pthread_mutex_unlock(&r->mutex);
        if (seek_requested) {
            rc = reader_handle_seek(r);
            if (rc == 1) continue;
            if (rc < 0) {
                if (rc != AVERROR_EXIT) atomic_store(&r->err, rc);
                break;
            }
        }
        pkt = av_packet_alloc();
        if (!pkt) { atomic_store(&r->err, AVERROR(ENOMEM)); break; }
        rc = av_read_frame(r->fmt, pkt);
        if (rc < 0) {
            av_packet_free(&pkt);
            if (rc == AVERROR_EXIT && atomic_load(&r->seek_interrupt)) {
                continue;
            }
            if (rc == AVERROR_EOF && !atomic_load(&r->abort)) {
                /* Keep the demux owner alive at EOF: a user may still seek
                 * while the core presents the queued tail of the stream. */
                pthread_mutex_lock(&r->mutex);
                r->done = 1;
                r->eof_wait = 1;
                pthread_cond_broadcast(&r->changed);
                while (!r->seek_requested && !atomic_load(&r->abort))
                    pthread_cond_wait(&r->changed, &r->mutex);
                pthread_mutex_unlock(&r->mutex);
                if (atomic_load(&r->abort)) break;
                continue;
            }
            if (!(atomic_load(&r->abort) && rc == AVERROR_EXIT))
                atomic_store(&r->err, rc);
            break;
        }
        if (atomic_load(&r->seek_interrupt)) { av_packet_free(&pkt); continue; }
        if (pkt->stream_index != r->vi && pkt->stream_index != r->ai) {
            av_packet_free(&pkt); continue;
        }
        if (pkt->flags & AV_PKT_FLAG_CORRUPT) {
            logmsg("discarded corrupt packet from stream %d", pkt->stream_index);
            av_packet_free(&pkt); continue;
        }
        n = calloc(1, sizeof *n);
        if (!n) { av_packet_free(&pkt); atomic_store(&r->err, AVERROR(ENOMEM)); break; }
        n->pkt = pkt;
        int discard_pending = 0, fatal = 0;
        for (;;) {
            pthread_mutex_lock(&r->mutex);
            while (!atomic_load(&r->abort) && !r->seek_requested &&
                   (r->vq.count + r->aq.count >= Q_PACKETS ||
                    r->bytes + (size_t)pkt->size > Q_BYTES ||
                    packet_beyond_reader_horizon(r, pkt))) {
                r->queue_wait = 1;
                pthread_cond_wait(&r->changed, &r->mutex);
            }
            r->queue_wait = 0;
            if (atomic_load(&r->abort)) {
                pthread_mutex_unlock(&r->mutex);
                av_packet_free(&pkt); free(n); fatal = 1; break;
            }
            if (r->seek_requested) {
                pthread_mutex_unlock(&r->mutex);
                rc = reader_handle_seek(r);
                if (rc == 2) {
                    /* The pending packet belongs after a successful retained
                     * queue hit. Recheck bounds after the main thread prunes. */
                    continue;
                }
                av_packet_free(&pkt); free(n); discard_pending = 1;
                if (rc < 0) {
                    if (rc != AVERROR_EXIT) atomic_store(&r->err, rc);
                    fatal = 1;
                }
                break;
            }
            n->seq = r->seq++;
            if (pkt->stream_index == r->vi) q_push(&r->vq, n); else q_push(&r->aq, n);
            r->bytes += (size_t)pkt->size;
            pthread_cond_broadcast(&r->changed);
            pthread_mutex_unlock(&r->mutex);
            break;
        }
        if (fatal) break;
        if (discard_pending) continue;
    }
    pthread_mutex_lock(&r->mutex); r->done = 1; pthread_cond_broadcast(&r->changed);
    pthread_mutex_unlock(&r->mutex);
    return NULL;
}

static int64_t packet_pts90(struct player *p, const AVPacket *pkt, int stream)
{
    int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    int64_t pts;
    if (ts == AV_NOPTS_VALUE || !p->origin_ready) return AV_NOPTS_VALUE;
    pts = av_rescale_q(ts, p->fmt->streams[stream]->time_base,
                       (AVRational){1, 90000}) - p->origin90;
    return pts < 0 ? AV_NOPTS_VALUE : pts;
}

/* Internal scheduling stays in the source domain for demux queues and cache
 * seeks. Only timestamps handed to the core are shortened to its 25 fps clock. */
static int64_t packet_clock_pts90(struct player *p, const AVPacket *pkt, int stream)
{
    int64_t pts = packet_pts90(p, pkt, stream);
    return pts == AV_NOPTS_VALUE ? pts : film_speed_pts90(p->film_speed, pts);
}

static int64_t packet_raw_pts90(struct player *p, const AVPacket *pkt, int stream)
{
    int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    if (ts == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return av_rescale_q(ts, p->fmt->streams[stream]->time_base,
                        (AVRational){1, 90000});
}

static unsigned volume_atten(int volume)
{
    if (volume <= 0) return 255;
    if (volume >= 100) return 0;
    double half_db = -40.0 * log10((double)volume / 100.0);
    if (half_db > 254.0) half_db = 254.0;
    return (unsigned)lround(half_db);
}

static int annexb_idr(const uint8_t *d, size_t n)
{
    return h264_packet_idr(d, n, 0);
}

/* AVC length fields can resemble Annex-B start codes. Prefer the container's
 * explicit AVC framing and validate every length before declaring an IDR. */
static int packet_idr(const struct player *p, const AVPacket *pkt)
{
    const AVCodecParameters *par = p->fmt->streams[p->rd.vi]->codecpar;
    unsigned length_size = 0;
    if (par->extradata && par->extradata_size >= 5 && par->extradata[0] == 1)
        length_size = (par->extradata[4] & 3u) + 1u;
    return pkt->size > 0 && h264_packet_idr(pkt->data, (size_t)pkt->size, length_size);
}
static int cache_plan_locked(struct player *p, int64_t current90, int64_t target90,
                             struct seek_cache_plan *plan)
{
    struct reader *r = &p->rd;
    size_t count = r->vq.count + r->aq.count, i = 0;
    struct seek_cache_packet *a;
    struct packet_node *v = r->vq.head, *aud = r->aq.head;
    if (!count || count > Q_PACKETS || r->ai < 0) return 0;
    a = calloc(count, sizeof *a);
    if (!a) return 0;
    while (v || aud) {
        struct packet_node *node;
        int kind;
        if (!aud || (v && v->seq < aud->seq)) { node = v; v = v->next; kind = SEEK_CACHE_VIDEO; }
        else { node = aud; aud = aud->next; kind = SEEK_CACHE_AUDIO; }
        AVStream *s = p->fmt->streams[kind == SEEK_CACHE_VIDEO ? r->vi : r->ai];
        a[i].seq = node->seq;
        a[i].kind = (enum seek_cache_kind)kind;
        a[i].pts90 = node->pkt->pts == AV_NOPTS_VALUE ? SEEK_CACHE_NOPTS :
            av_rescale_q(node->pkt->pts, s->time_base, (AVRational){1, 90000});
        a[i].dts90 = node->pkt->dts == AV_NOPTS_VALUE ? SEEK_CACHE_NOPTS :
            av_rescale_q(node->pkt->dts, s->time_base, (AVRational){1, 90000});
        a[i].duration90 = node->pkt->duration > 0 ?
            av_rescale_q(node->pkt->duration, s->time_base, (AVRational){1, 90000}) : 0;
        a[i].idr_confirmed = kind == SEEK_CACHE_VIDEO && packet_idr(p, node->pkt);
        ++i;
    }
    int hit = seek_cache_select(a, count, current90, target90, plan);
    if (getenv("JFPLAY_DEBUG")) {
        size_t idrs = 0, unknown_duration = 0, missing_dts = 0;
        double nearest_ms = INFINITY;
        for (size_t j = 0; j < count; ++j) {
            if (a[j].duration90 <= 0) ++unknown_duration;
            if (a[j].kind == SEEK_CACHE_VIDEO && a[j].dts90 == SEEK_CACHE_NOPTS)
                ++missing_dts;
            if (a[j].idr_confirmed && a[j].pts90 != SEEK_CACHE_NOPTS) {
                double delta = ((double)a[j].pts90 - (double)target90) / 90.0;
                ++idrs;
                if (fabs(delta) < fabs(nearest_ms)) nearest_ms = delta;
            }
        }
        logmsg("seek cache probe: hit=%d packets=%zu idrs=%zu unknown_duration=%zu missing_video_dts=%zu nearest_idr_delta_ms=%.3f",
               hit, count, idrs, unknown_duration, missing_dts,
               isfinite(nearest_ms) ? nearest_ms : -1.0);
    }
    free(a);
    return hit;
}

static int packet_beyond_reader_horizon(struct reader *r, const AVPacket *pkt)
{
    int64_t playhead = atomic_load(&r->playhead90);
    if (playhead == INT64_MIN || pkt->stream_index < 0) return 0;
    AVStream *s = r->fmt->streams[pkt->stream_index];
    int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    if (ts == AV_NOPTS_VALUE) return 0;
    int64_t pts90 = av_rescale_q(ts, s->time_base, (AVRational){1, 90000});
    return pts90 > playhead + Q_AHEAD_TICKS;
}

static void q_prune_before(struct packet_queue *q, uint64_t seq, size_t *bytes)
{
    while (q->head && q->head->seq < seq) {
        struct packet_node *n = q->head;
        q->head = n->next;
        *bytes -= (size_t)n->pkt->size;
        q->bytes -= (size_t)n->pkt->size;
        --q->count;
        av_packet_free(&n->pkt);
        free(n);
    }
    if (!q->head) q->tail = NULL;
}

static void log_first_au(const AVPacket *pkt)
{
    char types[192];
    size_t used = 0;
    for (size_t i = 0; i + 3 < (size_t)pkt->size;) {
        size_t j = 0;
        if (pkt->data[i] == 0 && pkt->data[i+1] == 0 && pkt->data[i+2] == 1) j = i + 3;
        else if (i + 4 < (size_t)pkt->size && pkt->data[i] == 0 &&
                 pkt->data[i+1] == 0 && pkt->data[i+2] == 0 && pkt->data[i+3] == 1) j = i + 4;
        if (!j) { ++i; continue; }
        if (j < (size_t)pkt->size) {
            int n = snprintf(types + used, sizeof types - used, "%s%u",
                             used ? "," : "", pkt->data[j] & 0x1f);
            if (n < 0 || (size_t)n >= sizeof types - used) { used = sizeof types - 1; break; }
            used += (size_t)n;
        }
        i = j;
    }
    types[used] = 0;
    logmsg("first accepted AU: NAL types=%s size=%d pts=%lld dts=%lld flags=0x%x",
           types[0] ? types : "none", pkt->size, (long long)pkt->pts,
           (long long)pkt->dts, pkt->flags);
}

static void extend_buffer_interval(int64_t pts, int64_t duration, int64_t tolerance,
                                   int *valid, int *broken,
                                   int64_t *start, int64_t *end);
static int64_t video_duration90(struct player *p, const AVPacket *pkt);

static int write_au(struct player *p, AVPacket *pkt, unsigned flags)
{
    if (!core_owner_ok(p)) return AVERROR_EXIT;
    int64_t source_pts = packet_pts90(p, pkt, p->rd.vi);
    int64_t clock_pts = source_pts == AV_NOPTS_VALUE ? source_pts :
                        film_speed_pts90(p->film_speed, source_pts);
    int rc = h264ring_try_write_au(p->ring, pkt->data, (uint32_t)pkt->size,
                                   clock_pts == AV_NOPTS_VALUE ? -1 : clock_pts, flags);
    if (!rc && source_pts != AV_NOPTS_VALUE) {
        p->newest_video90 = clock_pts;
        extend_buffer_interval(source_pts, video_duration90(p, pkt), 22500,
                               &p->buffered_video_valid, &p->buffered_video_broken,
                               &p->buffered_video_start90, &p->buffered_video_end90);
    }
    if (!rc && p->seek_state == SEEK_IN_PROGRESS && p->seek_reset_done == 2 &&
        annexb_idr(pkt->data, (size_t)pkt->size)) {
        p->seek_state = SEEK_READY;
        p->state = p->paused ? STATE_PAUSED : STATE_PLAYING;
        int64_t raw = packet_raw_pts90(p, pkt, p->rd.vi);
        if (raw != AV_NOPTS_VALUE) {
            double stream = (double)raw / 90000.0;
            if (p->fmt->start_time != AV_NOPTS_VALUE)
                stream -= (double)p->fmt->start_time / AV_TIME_BASE;
            p->seek_actual_position = p->cfg.base + (stream > 0.0 ? stream : 0.0);
        }
    }
    return rc;
}

static int status_refusal(struct player *p)
{
    struct h264ring_status st;
    if (!h264ring_status(p->ring, &st)) return (int)H264RING_ST(&st, FE_REFUSED_CODE);
    return 0;
}

static int ring_result(struct player *p, int rc, const char *what)
{
    if (!rc || rc == -EAGAIN) return rc;
    int refusal = status_refusal(p);
    if (rc == -EPROTO || refusal) fail(p, EX_REFUSED, "core refused stream while writing %s", what);
    else fail(p, EX_STREAM, "core write %s failed: %s", what, strerror(-rc));
    return rc;
}

static void clear_pcm(struct player *p)
{
    while (p->pcm.head) {
        struct pcm_chunk *c = p->pcm.head;
        p->pcm.head = c->next;
        free(c->data); free(c);
    }
    p->pcm.tail = NULL; p->pcm.frames = 0;
}

static void extend_buffer_interval(int64_t pts, int64_t duration, int64_t tolerance,
                                   int *valid, int *broken,
                                   int64_t *start, int64_t *end)
{
    int64_t packet_end;
    if (pts == AV_NOPTS_VALUE || duration <= 0 || *broken) return;
    packet_end = pts > INT64_MAX - duration ? INT64_MAX : pts + duration;
    if (!*valid) {
        *valid = 1;
        *start = pts;
        *end = packet_end;
    } else if (pts > *end + tolerance) {
        *broken = 1;
    } else if (packet_end > *end) {
        *end = packet_end;
    }
}

static int64_t video_duration90(struct player *p, const AVPacket *pkt)
{
    AVStream *stream = p->fmt->streams[p->rd.vi];
    if (pkt->duration > 0)
        return av_rescale_q(pkt->duration, stream->time_base, (AVRational){1, 90000});
    return p->nominal_video_duration90;
}

static int append_pcm(struct player *p, const uint8_t *data, size_t frames,
                      int64_t pts, int64_t source_pts)
{
    struct pcm_chunk *c;
    int16_t *samples;
    if (!frames) return 0;
    if (frames > PCM_MAX_FRAMES - p->pcm.frames) return AVERROR(ENOBUFS);
    c = calloc(1, sizeof *c);
    if (!c) return AVERROR(ENOMEM);
    c->data = malloc(frames * 4u);
    if (!c->data) { free(c); return AVERROR(ENOMEM); }
    memcpy(c->data, data, frames * 4u); c->frames = frames; c->pts90 = pts;
    /* Boost only a multichannel source (or a known multichannel source that
     * the server has already downmixed), then limit peaks before core output. */
    if ((p->audio_channels_in > 2 || p->cfg.surround_source) && p->cfg.audio_boost > 100) {
        samples = (int16_t *)c->data;
        for (size_t i = 0; i < frames * 2u; ++i)
            samples[i] = audio_boost_sample(samples[i], p->cfg.audio_boost);
    }
    extend_buffer_interval(source_pts,
                           (int64_t)frames * 90000 /
                           film_speed_audio_rate(p->film_speed, 48000), 90,
                           &p->buffered_audio_valid, &p->buffered_audio_broken,
                           &p->buffered_audio_start90, &p->buffered_audio_end90);
    if (p->pcm.tail) p->pcm.tail->next = c; else p->pcm.head = c;
    p->pcm.tail = c; p->pcm.frames += frames;
    return 0;
}

static int pcm_has_room(const struct player *p)
{
    return p->pcm.frames <= PCM_MAX_FRAMES - PCM_DECODE_RESERVE;
}

static int64_t pcm_tail_pts90(const struct player *p)
{
    const struct pcm_chunk *c = p->pcm.tail;
    if (!c || c->pts90 == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
    return c->pts90 + (int64_t)c->frames * 90000 / 48000;
}

static int ensure_swr(struct player *p, const AVFrame *f)
{
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    int rc, output_rate = film_speed_audio_rate(p->film_speed, 48000);
    if (p->swr && !av_channel_layout_compare(&p->swr_in, &f->ch_layout) &&
        p->swr_fmt == f->format && p->swr_rate == f->sample_rate) return 0;
    swr_free(&p->swr); av_channel_layout_uninit(&p->swr_in);
    rc = swr_alloc_set_opts2(&p->swr, &stereo, AV_SAMPLE_FMT_S16, output_rate,
                             &f->ch_layout, (enum AVSampleFormat)f->format,
                             f->sample_rate, 0, NULL);
    if (rc < 0 || (rc = swr_init(p->swr)) < 0) return rc;
    if ((rc = av_channel_layout_copy(&p->swr_in, &f->ch_layout)) < 0) return rc;
    p->swr_fmt = f->format; p->swr_rate = f->sample_rate;
    if (!p->audio_channels_in) p->audio_channels_in = f->ch_layout.nb_channels;
    return 0;
}

static int receive_audio(struct player *p)
{
    int rc;
    for (;;) {
        AVFrame *f = av_frame_alloc();
        int out_cap, out_n;
        uint8_t *out = NULL;
        int64_t pts, source_pts;
        if (!f) return AVERROR(ENOMEM);
        rc = avcodec_receive_frame(p->adec, f);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) { av_frame_free(&f); return 0; }
        if (rc < 0) { av_frame_free(&f); return rc; }
        if ((rc = ensure_swr(p, f)) < 0) { av_frame_free(&f); return rc; }
        source_pts = f->best_effort_timestamp == AV_NOPTS_VALUE || !p->origin_ready ?
                     AV_NOPTS_VALUE :
                     av_rescale_q(f->best_effort_timestamp,
                                  p->fmt->streams[p->rd.ai]->time_base,
                                  (AVRational){1, 90000}) - p->origin90;
        if (source_pts < 0) source_pts = AV_NOPTS_VALUE;
        pts = source_pts == AV_NOPTS_VALUE ? p->audio_next90 :
              film_speed_pts90(p->film_speed, source_pts);
        /* Decoded audio is sample-continuous; the container's timestamps
         * are not always (Matroska laces several AAC frames under one
         * timestamp, and rounds to 1 ms). A frame near where the samples
         * put it keeps the sample clock, so the records stay contiguous:
         * a timestamp step would split a record, pad it with silence and
         * land the next one late at the core -- a click, many a second.
         * A real jump (a seek, a gap) still resyncs the clock. */
        if (pts != AV_NOPTS_VALUE && p->audio_next90 != AV_NOPTS_VALUE &&
            llabs(pts - p->audio_next90) <= AUDIO_RESYNC_TOLERANCE)
            pts = p->audio_next90;
        out_cap = (int)av_rescale_rnd(swr_get_delay(p->swr, f->sample_rate) + f->nb_samples,
                                      film_speed_audio_rate(p->film_speed, 48000),
                                      f->sample_rate, AV_ROUND_UP);
        if ((rc = av_samples_alloc(&out, NULL, 2, out_cap, AV_SAMPLE_FMT_S16, 0)) < 0) {
            av_frame_free(&f); return rc;
        }
        out_n = swr_convert(p->swr, &out, out_cap,
                            (const uint8_t * const *)f->extended_data, f->nb_samples);
        if (out_n < 0) rc = out_n;
        else rc = append_pcm(p, out, (size_t)out_n, pts, source_pts);
        av_freep(&out); av_frame_free(&f);
        if (rc < 0) return rc;
        p->audio_next90 = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
                          pts + (int64_t)out_n * 90000 / 48000;
    }
}

static int decode_audio(struct player *p, AVPacket *pkt)
{
    int rc;
    for (;;) {
        rc = avcodec_send_packet(p->adec, pkt);
        if (rc != AVERROR(EAGAIN)) break;
        rc = receive_audio(p);
        if (rc < 0) return rc;
    }
    if (rc < 0) return rc;
    return receive_audio(p);
}

static int drain_swr(struct player *p)
{
    for (;;) {
        uint8_t *out = NULL;
        int out_cap, out_n, rc;
        int64_t pts = p->audio_next90;
        if (!p->swr) return 0;
        int output_rate = film_speed_audio_rate(p->film_speed, 48000);
        out_cap = (int)av_rescale_rnd(swr_get_delay(p->swr, p->swr_rate),
                                      output_rate, p->swr_rate, AV_ROUND_UP);
        if (out_cap <= 0) return 0;
        rc = av_samples_alloc(&out, NULL, 2, out_cap, AV_SAMPLE_FMT_S16, 0);
        if (rc < 0) return rc;
        out_n = swr_convert(p->swr, &out, out_cap, NULL, 0);
        if (out_n < 0) rc = out_n;
        else rc = append_pcm(p, out, (size_t)out_n, pts, AV_NOPTS_VALUE);
        av_freep(&out);
        if (rc < 0) return rc;
        if (!out_n) return 0;
        p->audio_next90 = pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
                          pts + (int64_t)out_n * 90000 / 48000;
    }
}

static size_t pcm_record_frames(const struct player *p, int draining)
{
    const struct pcm_chunk *c = p->pcm.head;
    size_t total = 0;
    int64_t expected = AV_NOPTS_VALUE;
    while (c && total < AUDIO_RECORD_FRAMES) {
        int64_t start = c->pts90;
        size_t avail = c->frames - c->offset;
        if (start != AV_NOPTS_VALUE)
            start += (int64_t)c->offset * 90000 / 48000;
        if (total && start != AV_NOPTS_VALUE && expected != AV_NOPTS_VALUE &&
            llabs(start - expected) > PTS_CONTIG_TOLERANCE) { ((struct player *)p)->dbg_splits++; return total; }
        if (avail > AUDIO_RECORD_FRAMES - total) avail = AUDIO_RECORD_FRAMES - total;
        total += avail;
        expected = start == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
                   start + (int64_t)avail * 90000 / 48000;
        c = c->next;
    }
    if (total >= AUDIO_RECORD_FRAMES) return AUDIO_RECORD_FRAMES;
    return draining ? total : 0;
}

static void copy_pcm(const struct player *p, uint8_t *out, size_t frames)
{
    const struct pcm_chunk *c = p->pcm.head;
    size_t offset = c ? c->offset : 0;
    size_t copied = 0;
    while (copied < frames && c) {
        size_t take = c->frames - offset;
        if (take > frames - copied) take = frames - copied;
        memcpy(out + copied * 4u, c->data + offset * 4u, take * 4u);
        copied += take; c = c->next; offset = 0;
    }
}

static void consume_pcm(struct player *p, size_t frames)
{
    while (frames && p->pcm.head) {
        struct pcm_chunk *c = p->pcm.head;
        size_t take = c->frames - c->offset;
        if (take > frames) take = frames;
        c->offset += take; frames -= take; p->pcm.frames -= take;
        if (c->offset == c->frames) {
            p->pcm.head = c->next;
            if (!p->pcm.head) p->pcm.tail = NULL;
            free(c->data); free(c);
        }
    }
}

static int write_pcm(struct player *p, int draining)
{
    uint8_t record[AUDIO_RECORD_FRAMES * 4u];
    size_t take;
    int64_t pts;
    int rc;
    if (!seek_protocol_can_process(p->seek_state == SEEK_IN_PROGRESS,
                                  p->seek_reset_done)) return 0;
    take = pcm_record_frames(p, draining);
    if (!take) return 0;
    if (!core_owner_ok(p)) return AVERROR_EXIT;
    pts = p->pcm.head->pts90;
    if (pts != AV_NOPTS_VALUE)
        pts += (int64_t)p->pcm.head->offset * 90000 / 48000;
    if (!draining && p->newest_video90 != INT64_MIN &&
        pts != AV_NOPTS_VALUE && pts > p->newest_video90 + AUDIO_LEAD) return 0;
    copy_pcm(p, record, take);
    if (take < AUDIO_RECORD_FRAMES) {
        memset(record + take * 4u, 0, (AUDIO_RECORD_FRAMES - take) * 4u);
        p->dbg_pad += AUDIO_RECORD_FRAMES - take;
    }
    if (pts == AV_NOPTS_VALUE) p->dbg_untimed++;
    rc = ring_result(p, h264ring_try_write_audio(p->ring, record,
                     AUDIO_RECORD_FRAMES * 4u,
                     pts == AV_NOPTS_VALUE ? -1 : pts), "audio");
    if (rc) return rc;
    if (pts != AV_NOPTS_VALUE) p->newest_audio90 = pts + (int64_t)take * 90000 / 48000;
    consume_pcm(p, take);
    return 1;
}

static AVPacket *take_packet(struct player *p, int *kind)
{
    struct reader *r = &p->rd;
    AVPacket *pkt = NULL;
    if (!seek_protocol_can_process(p->seek_state == SEEK_IN_PROGRESS,
                                  p->seek_reset_done)) return NULL;
    pthread_mutex_lock(&r->mutex);
    struct packet_node *v = r->vq.head, *a = r->aq.head;
    int64_t apts = a ? packet_clock_pts90(p, a->pkt, p->rd.ai) : AV_NOPTS_VALUE;
    int64_t tail_pts = pcm_tail_pts90(p);
    int audio_ok = a && pcm_has_room(p) &&
                        ((p->newest_video90 != INT64_MIN &&
                         (tail_pts == AV_NOPTS_VALUE || tail_pts <= p->newest_video90 + AUDIO_LEAD) &&
                         (apts == AV_NOPTS_VALUE || apts <= p->newest_video90 + AUDIO_LEAD)) ||
                        (r->done && !v));
    int64_t vpts = v ? packet_clock_pts90(p, v->pkt, p->rd.vi) : AV_NOPTS_VALUE;
    struct packet_pacing pacing = {
        .has_audio = r->ai >= 0, .audio_queued = a != NULL,
        .reader_done = r->done, .reader_blocked = r->queue_wait,
        .pcm_frames = p->pcm.frames, .video_written = p->newest_video90,
        .audio_written = p->newest_audio90, .video_pts = vpts, .audio_pts = apts,
    };
    int video_ok = !v || packet_video_ready(pacing, AUDIO_RECORD_FRAMES, VIDEO_LEAD);
    /* Preserve packet order when both streams are ready; prioritize audio
     * when the video timestamp gate waits for it. */
    if (a && audio_ok && (!v || a->seq < v->seq || !video_ok)) { pkt = q_pop(&r->aq); *kind = 1; }
    else if (v && video_ok) { pkt = q_pop(&r->vq); *kind = 0; }
    if (pkt) { r->bytes -= (size_t)pkt->size; pthread_cond_broadcast(&r->changed); }
    p->input_done = r->done && !r->vq.head && !r->aq.head;
    pthread_mutex_unlock(&r->mutex);
    return pkt;
}

static void set_volume(struct player *p, int volume)
{
    if (!core_owner_ok(p)) return;
    p->cfg.volume = volume;
    int rc = h264ring_set_atten(p->ring, volume_atten(volume));
    if (rc) logmsg("volume command failed: %s", strerror(-rc));
}

static void set_playback_settings(struct player *p);
static int apply_geometry(struct player *p);

static void set_analog_aspect(struct player *p, int aspect)
{
    p->cfg.analog_aspect = aspect;
    p->cfg.analog_aspect_set = 1;
    set_playback_settings(p);
    if (p->opened) (void)apply_geometry(p);
}

static void set_anti_twitter(struct player *p, int value)
{
    p->cfg.anti_twitter = value;
    p->cfg.anti_twitter_set = 1;
    set_playback_settings(p);
}

static void set_playback_settings(struct player *p)
{
    unsigned values[H264RING_OPT_COUNT] = {0};
    unsigned mask = 0;
    if (p->cfg.analog_aspect_set) {
        /* 14:9 is represented by custom geometry. Keep the core's real enum
         * at Letterbox so older and newer cores both receive a valid value. */
        values[H264RING_OPT_ANALOG_ASPECT] = p->cfg.analog_aspect == VIDEO_MODE_CROP_14_9 ?
                VIDEO_MODE_LETTERBOX : (unsigned)p->cfg.analog_aspect;
        mask |= 1u << H264RING_OPT_ANALOG_ASPECT;
    }
    if (p->cfg.anti_twitter_set) {
        values[H264RING_OPT_ANTI_TWITTER] = (unsigned)p->cfg.anti_twitter;
        mask |= 1u << H264RING_OPT_ANTI_TWITTER;
    }
    if (mask && core_owner_ok(p)) {
        int rc = h264ring_request_settings(p->ring, mask, values);
        if (rc < 0) logmsg("playback settings request failed: %s", strerror(-rc));
    }
}

static int apply_geometry(struct player *p)
{
    if (!p->cfg.geometry_set && !p->geometry_status_valid &&
        p->cfg.analog_aspect != VIDEO_MODE_CROP_14_9) return 0;
    if (!core_owner_ok(p)) return -1;
    struct h264ring_status status;
    if (h264ring_status(p->ring, &status)) {
        fail(p, EX_CORE, "cannot read core status for video calibration"); return -1;
    }
    /* HPS 1.2 added custom geometry. 14:9 has no core enum, so on older
     * cores leave the valid Letterbox request in place (the safe Off mode). */
    if (p->cfg.analog_aspect == VIDEO_MODE_CROP_14_9 &&
        H264RING_ST(&status, VERSION) < 0x102) {
        p->geometry_status_valid = 0;
        return 0;
    }
    unsigned rw = H264RING_ST(&status, RASTER_W), rh = H264RING_ST(&status, RASTER_H);
    unsigned video_out = H264RING_ST(&status, VIDEO_OUT);
    unsigned wide = H264RING_ST(&status, VERSION) >= 0x103 ?
                    H264RING_ST(&status, DISPLAY_WIDE) : 0;
    /* Native HDMI does not use the fitted analog raster. Wait for the raster
     * fields to describe an ordinary SD mode; write_status will retry when
     * the first actual picture changes the core's selected mode. */
    if (video_out == 3 || rw != 720 || (rh != 480 && rh != 576)) {
        p->geometry_raster_w = rw; p->geometry_raster_h = rh;
        p->geometry_video_out = video_out; p->geometry_wide = wide;
        p->geometry_status_valid = 1;
        return 0;
    }
    AVStream *stream = p->fmt->streams[p->rd.vi];
    AVRational sar = av_guess_sample_aspect_ratio(p->fmt, stream, NULL);
    if (sar.num <= 0 || sar.den <= 0) sar = (AVRational){1, 1};
    int an, ad;
    av_reduce(&an, &ad, (int64_t)stream->codecpar->width * sar.num,
              (int64_t)stream->codecpar->height * sar.den, INT32_MAX);
    struct video_geometry_result result;
    if (an <= 0 || ad <= 0 || video_geometry_compute_display(&p->cfg.geometry, (unsigned)an,
            (unsigned)ad, (unsigned)stream->codecpar->height, rh,
            (enum video_analog_mode)p->cfg.analog_aspect, (int)wide, &result)) {
        fail(p, EX_ARGS, "video calibration cannot represent this picture shape"); return -1;
    }
    struct h264ring_geometry geometry = {
        .x = result.image.x, .y = result.image.y,
        .width = (unsigned)result.image.w, .height = (unsigned)result.image.h,
        .clip_x = (unsigned)result.clip.x, .clip_y = (unsigned)result.clip.y,
        .clip_width = (unsigned)result.clip.w, .clip_height = (unsigned)result.clip.h
    };
    if (!core_owner_ok(p)) return -1;
    int rc = h264ring_set_geometry(p->ring, &geometry, 1000);
    if (rc) {
        fail(p, EX_CORE, "video calibration request failed: %s", strerror(-rc)); return -1;
    }
    logmsg("video calibration applied: picture=%d,%d,%u,%u clip=%u,%u,%u,%u",
           geometry.x, geometry.y, geometry.width, geometry.height,
           geometry.clip_x, geometry.clip_y, geometry.clip_width, geometry.clip_height);
    p->geometry_raster_w = rw; p->geometry_raster_h = rh;
    p->geometry_video_out = video_out; p->geometry_wide = wide;
    p->geometry_status_valid = 1;
    return 0;
}

static void set_audio_boost(struct player *p, int percent)
{
    p->cfg.audio_boost = percent;
}

static int request_seek(struct player *p, char *args)
{
    if (!core_owner_ok(p)) return -1;
    char *end;
    long id;
    double target;
    int64_t target_us, current90 = INT64_MIN;
    int cache_hit = 0;
    struct h264ring_status core_status;
    struct seek_cache_plan cache_plan;
    errno = 0;
    id = strtol(args, &end, 10);
    if (errno || end == args || id <= 0 || id > INT32_MAX ||
        (*end != ' ' && *end != '\t')) return -1;
    while (*end == ' ' || *end == '\t') ++end;
    char *target_end;
    errno = 0;
    target = strtod(end, &target_end);
    if (errno || target_end == end || !isfinite(target) || target < 0.0) return -1;
    while (*target_end == ' ' || *target_end == '\t') ++target_end;
    if (*target_end) return -1;
    if (id <= p->seek_id || p->seek_state == SEEK_IN_PROGRESS) return -1;
    p->seek_id = (int)id;
    p->seek_position = target;
    p->seek_actual_position = 0.0;
    p->seek_started_ms = mono_ms();
    p->seek_error[0] = 0;
    if (!p->fmt || p->reader_joined) {
        strcpy(p->seek_error, "worker reader is unavailable");
        p->seek_state = SEEK_ERROR;
        return 0;
    }
    double stream_target = target - p->cfg.base;
    if (stream_target < 0.0) stream_target = 0.0;
    if (stream_target > (double)INT64_MAX / AV_TIME_BASE) return -1;
    target_us = (int64_t)(stream_target * AV_TIME_BASE);
    if (p->fmt->start_time != AV_NOPTS_VALUE &&
        (p->fmt->start_time > 0 && target_us > INT64_MAX - p->fmt->start_time)) return -1;
    if (p->fmt->start_time != AV_NOPTS_VALUE) target_us += p->fmt->start_time;
    p->seek_target90 = av_rescale_q(target_us, (AVRational){1, AV_TIME_BASE},
                                    (AVRational){1, 90000});
    if (p->origin_ready && !h264ring_status(p->ring, &core_status))
        current90 = film_speed_source_pts90(p->film_speed,
                      (int64_t)H264RING_ST(&core_status, STC)) + p->origin90;

    pthread_mutex_lock(&p->rd.mutex);
    if ((p->rd.done && !p->rd.eof_wait) || p->rd.seek_requested || atomic_load(&p->rd.abort)) {
        pthread_mutex_unlock(&p->rd.mutex);
        strcpy(p->seek_error, "demux reader cannot seek at end of stream");
        p->seek_state = SEEK_ERROR;
        return 0;
    }
    if (current90 != INT64_MIN)
        cache_hit = cache_plan_locked(p, current90, p->seek_target90, &cache_plan);
    p->seek_current90 = current90;
    p->seek_cache_hit = cache_hit;
    p->rd.seek_target_us = target_us;
    p->rd.seek_requested = 1;
    p->rd.seek_parked = 0;
    p->rd.seek_go = 0;
    p->rd.seek_rc = 0;
    p->rd.seek_from_cache = cache_hit;
    /* A potential queue hit must let the demuxer reach a packet boundary; a
     * miss interrupts a blocked network read so the ordinary seek can start. */
    atomic_store(&p->rd.seek_interrupt, !cache_hit);
    pthread_cond_broadcast(&p->rd.changed);
    pthread_mutex_unlock(&p->rd.mutex);

    p->seek_state = SEEK_IN_PROGRESS;
    p->seek_reset_done = 0;
    p->seek_was_paused = p->paused;
    p->state = STATE_OPENING;
    if (!core_owner_ok(p)) return -1;
    int rc = h264ring_set_pause(p->ring, 1);
    if (rc) {
        snprintf(p->seek_error, sizeof p->seek_error, "pause before seek failed: %s", strerror(-rc));
        p->seek_state = SEEK_ERROR;
        fail(p, EX_CORE, "%s", p->seek_error);
        return 0;
    }
    return 0;
}

static void command(struct player *p, char *line)
{
    while (*line == ' ' || *line == '\t') ++line;
    char *end = line + strlen(line); while (end > line && (end[-1] == ' ' || end[-1] == '\t')) *--end = 0;
    if (!strcmp(line, "pause")) p->paused = 1;
    else if (!strcmp(line, "resume")) p->paused = 0;
    else if (!strcmp(line, "toggle")) p->paused = !p->paused;
    else if (!strcmp(line, "stop") || !strcmp(line, "quit")) atomic_store(&p->stop, 1);
    else if (!strncmp(line, "volume ", 7)) {
        int n; if (!parse_int(line + 7, 0, 100, &n)) { set_volume(p, n); return; }
        logmsg("ignored malformed volume command"); return;
    } else if (!strncmp(line, "boost ", 6)) {
        int n; if (!parse_int(line + 6, 100, 300, &n)) { set_audio_boost(p, n); return; }
        logmsg("ignored malformed boost command"); return;
    } else if (!strncmp(line, "seek ", 5)) {
        if (request_seek(p, line + 5)) logmsg("ignored malformed or unavailable seek command");
        return;
    } else if (!strncmp(line, "aspect ", 7)) {
        int n; if (!parse_int(line + 7, 0, 4, &n)) { set_analog_aspect(p, n); return; }
        logmsg("ignored malformed aspect command"); return;
    } else if (!strncmp(line, "anti-twitter ", 13)) {
        int n; if (!parse_int(line + 13, 0, 2, &n)) { set_anti_twitter(p, n); return; }
        logmsg("ignored malformed anti-twitter command"); return;
    } else { logmsg("ignored unknown control command"); return; }
    if (!atomic_load(&p->stop) && core_owner_ok(p)) {
        int rc = h264ring_set_pause(p->ring, p->paused);
        if (rc) logmsg("pause command failed: %s", strerror(-rc));
        else p->state = p->paused ? STATE_PAUSED : STATE_PLAYING;
    }
}

static void poll_fifo(struct player *p)
{
    static char buf[2048]; static size_t used;
    for (;;) {
        ssize_t n = read(p->fifo_fd, buf + used, sizeof buf - used - 1);
        if (n > 0) used += (size_t)n;
        else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) logmsg("control FIFO read: %s", strerror(errno));
        else break;
    }
    buf[used] = 0;
    char *start = buf, *nl;
    while ((nl = memchr(start, '\n', used - (size_t)(start - buf)))) {
        *nl = 0; if (nl > start && nl[-1] == '\r') nl[-1] = 0;
        command(p, start); start = nl + 1;
    }
    size_t left = used - (size_t)(start - buf);
    memmove(buf, start, left); used = left;
    if (used == sizeof buf - 1) { used = 0; logmsg("discarded overlong control line"); }
}

static double playback_position(struct player *p, const struct h264ring_status *st, int have)
{
    if (p->have_stop_position) return p->stop_position;
    if (p->seek_state == SEEK_IN_PROGRESS) return p->seek_position;
    if (p->seek_state == SEEK_READY && have &&
        !(H264RING_ST(st, LIVE) & H264RING_L_STC_RUN))
        return p->seek_actual_position;
    double position = p->cfg.base;
    if (have && p->origin_ready) {
        double stream = (film_speed_original_seconds(p->film_speed,
                         (double)H264RING_ST(st, STC) / 90000.0) +
                         (double)p->origin90 / 90000.0);
        if (p->fmt && p->fmt->start_time != AV_NOPTS_VALUE)
            stream -= (double)p->fmt->start_time / AV_TIME_BASE;
        if (stream > 0.0) position += stream;
    } else {
        position += p->cfg.start_in_file;
    }
    return position;
}

static double item_position_from_pts90(const struct player *p, int64_t pts90)
{
    double stream = (double)(pts90 + p->origin90) / 90000.0;
    if (p->fmt && p->fmt->start_time != AV_NOPTS_VALUE)
        stream -= (double)p->fmt->start_time / AV_TIME_BASE;
    if (stream < 0.0) stream = 0.0;
    return p->cfg.base + stream;
}

static int64_t queued_contiguous_end(struct player *p, struct packet_queue *q,
                                     int stream, int64_t end90, int64_t tolerance)
{
    for (struct packet_node *n = q->head; n; n = n->next) {
        int64_t pts = packet_pts90(p, n->pkt, stream);
        int64_t duration = n->pkt->duration > 0 ?
            av_rescale_q(n->pkt->duration, p->fmt->streams[stream]->time_base,
                         (AVRational){1, 90000}) : 0;
        if (pts == AV_NOPTS_VALUE || duration <= 0 || pts > end90 + tolerance) break;
        if (pts <= end90 + tolerance && pts + duration > end90)
            end90 = pts + duration;
    }
    return end90;
}

static void write_status(struct player *p, int force)
{
    uint64_t now = mono_ms();
    struct h264ring_status st;
    unsigned late = 0, errors = 0, refused = 0, aud_samples = 0;
    int have = p->ring && core_owner_ok(p) && !h264ring_status(p->ring, &st);
    if (!force && now - p->last_status_ms < 250) return;
    p->last_status_ms = now;
    if (have) {
        late = (unsigned)H264RING_ST(&st, DISP_LATE);
        errors = (unsigned)H264RING_ST(&st, RC_ERR);
        refused = (unsigned)H264RING_ST(&st, FE_REFUSED_CODE);
        aud_samples = (unsigned)H264RING_ST(&st, AUD_Q_SAMPLES);
        if (p->opened && (p->cfg.geometry_set || p->geometry_status_valid ||
                          p->cfg.analog_aspect == VIDEO_MODE_CROP_14_9)) {
            unsigned rw = H264RING_ST(&st, RASTER_W);
            unsigned rh = H264RING_ST(&st, RASTER_H);
            unsigned vo = H264RING_ST(&st, VIDEO_OUT);
            unsigned wide = H264RING_ST(&st, VERSION) >= 0x103 ?
                            H264RING_ST(&st, DISPLAY_WIDE) : 0;
            if (!p->geometry_status_valid || p->geometry_raster_w != rw ||
                p->geometry_raster_h != rh || p->geometry_video_out != vo ||
                p->geometry_wide != wide)
                (void)apply_geometry(p);
        }
    }
    if (refused && !atomic_load(&p->exit_code))
        fail(p, EX_REFUSED, "core refused stream: %u %s", refused, h264ring_refusal_name(refused));
    if (have && p->cfg.direct && !atomic_load(&p->exit_code)) {
        /* A source stall that starved the ring leaves the display clock
         * re-anchored, and the pictures then arrive late with a large lag
         * though the core decodes fine. DISP_REANCHOR is already in the
         * status word, so a window that saw it move does not count and
         * restarts the grace, as a pause or seek does. */
        unsigned reanch = (unsigned)H264RING_ST(&st, DISP_REANCHOR);
        int reanchored = p->lag_reanchor_seen && reanch != p->lag_reanchor;
        p->lag_reanchor = reanch; p->lag_reanchor_seen = 1;
        int running = p->direct_ok && p->origin_ready && !p->paused &&
                      p->state == STATE_PLAYING && p->seek_state != SEEK_IN_PROGRESS &&
                      !reanchored;
        unsigned raw_lag = (unsigned)H264RING_ST(&st, LAG_MS) & 0xFFFFu;
        if (lag_watch_sample(&p->lag, now, running, late, raw_lag))
            fail(p, EX_NEEDS_TRANSCODE,
                 "direct stream needs a transcode: the core cannot keep up (%d ms behind)",
                 -(int)(int16_t)raw_lag);
    }
    char tmp[1024], clean[256], seek_clean[256], state[16], seek_state[16];
    snprintf(tmp, sizeof tmp, "%s.tmp.%ld", p->cfg.status, (long)getpid());
    snprintf(clean, sizeof clean, "%s", p->error);
    for (char *s = clean; *s; ++s) if (*s == '\r' || *s == '\n' || *s == '=') *s = ' ';
    snprintf(seek_clean, sizeof seek_clean, "%s", p->seek_error);
    for (char *s = seek_clean; *s; ++s) if (*s == '\r' || *s == '\n' || *s == '=') *s = ' ';
    strcpy(seek_state, p->seek_state == SEEK_IN_PROGRESS ? "seeking" :
           p->seek_state == SEEK_READY ? "ready" :
           p->seek_state == SEEK_ERROR ? "error" : "idle");
    if (p->state == STATE_ERROR) strcpy(state, "error");
    else if (p->state == STATE_ENDED) strcpy(state, "ended");
    else if (p->state == STATE_PAUSED) strcpy(state, "paused");
    else if (p->state == STATE_PLAYING) strcpy(state, "playing");
    else strcpy(state, "opening");
    /* position = base + stream time. The STC counts from the PTS origin (the
     * first IDR minus the preroll margin), so adding the origin back gives the
     * raw stream time of what is showing; the container's start time is taken
     * off so a stream whose timestamps begin at an offset (an HLS transcode
     * started mid-film, where base already carries the offset) counts from 0,
     * while an in-file seek in a plain file reports film time directly. */
    double position = playback_position(p, &st, have);
    if (have && p->origin_ready)
        atomic_store(&p->rd.playhead90,
                     film_speed_source_pts90(p->film_speed,
                         (int64_t)H264RING_ST(&st, STC)) + p->origin90);
    int buffered_valid = p->origin_ready && p->buffered_video_valid &&
                         (!p->adec || p->buffered_audio_valid);
    int64_t buffered_start90 = p->buffered_video_start90;
    int64_t buffered_end90 = p->buffered_video_end90;
    int64_t queued_video_end90 = buffered_end90;
    int64_t queued_audio_end90 = p->buffered_audio_end90;
    if (buffered_valid) {
        pthread_mutex_lock(&p->rd.mutex);
        queued_video_end90 = queued_contiguous_end(p, &p->rd.vq, p->rd.vi,
                                                    buffered_end90, 22500);
        if (p->adec)
            queued_audio_end90 = queued_contiguous_end(p, &p->rd.aq, p->rd.ai,
                                                        p->buffered_audio_end90, 90);
        pthread_mutex_unlock(&p->rd.mutex);
    }
    if (queued_video_end90 > buffered_end90) buffered_end90 = queued_video_end90;
    double buffered_start = 0.0, buffered_end = 0.0;
    if (p->adec && p->buffered_audio_valid) {
        if (p->buffered_audio_start90 > buffered_start90)
            buffered_start90 = p->buffered_audio_start90;
        if (queued_audio_end90 < buffered_end90)
            buffered_end90 = queued_audio_end90;
    }
    if (buffered_valid && buffered_end90 >= buffered_start90) {
        buffered_start = item_position_from_pts90(p, buffered_start90);
        buffered_end = item_position_from_pts90(p, buffered_end90);
        if (buffered_start < position) buffered_start = position;
        if (buffered_end < buffered_start) buffered_valid = 0;
    } else buffered_valid = 0;
    double duration = p->fmt && p->fmt->duration != AV_NOPTS_VALUE ?
                      p->cfg.base + (double)p->fmt->duration / AV_TIME_BASE : 0.0;
    AVStream *vs = p->fmt && p->rd.vi >= 0 ? p->fmt->streams[p->rd.vi] : NULL;
    AVRational fr = p->nominal_video_rate;
    const char *ac = p->adec && p->adec->codec ? p->adec->codec->name : "";
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "state=%s\n", state);
    fprintf(f, "position=%.3f\n", position);
    fprintf(f, "duration=%.3f\n", duration);
    fprintf(f, "width=%d\n", vs ? vs->codecpar->width : 0);
    fprintf(f, "height=%d\n", vs ? vs->codecpar->height : 0);
    fprintf(f, "fps=%.3f\n", fr.den ? av_q2d(fr) : 0.0);
    fprintf(f, "film_speed=%d\n", p->film_speed.enabled && p->film_speed.scale_num < p->film_speed.scale_den);
    fprintf(f, "ntsc_slowdown=%d\n", p->film_speed.enabled && p->film_speed.scale_num > p->film_speed.scale_den);
    fprintf(f, "audio_output_rate=%d\n", film_speed_audio_rate(p->film_speed, 48000));
    fprintf(f, "video_bitrate=%lld\n", (long long)(vs ? vs->codecpar->bit_rate : 0));
    fprintf(f, "audio_codec=%s\n", ac);
    fprintf(f, "audio_channels_in=%d\n", p->audio_channels_in);
    fprintf(f, "audio_boost=%d\n", p->cfg.audio_boost);
    fprintf(f, "seek_supported=1\n");
    fprintf(f, "seek_id=%d\n", p->seek_id);
    fprintf(f, "seek_state=%s\n", seek_state);
    fprintf(f, "seek_position=%.3f\n", p->seek_position);
    fprintf(f, "seek_actual_position=%.3f\n", p->seek_actual_position);
    fprintf(f, "seek_cache_hit=%d\n", p->seek_cache_hit);
    fprintf(f, "seek_error=%s\n", seek_clean);
    fprintf(f, "late=%u\n", late);
    fprintf(f, "errors=%u\n", errors);
    fprintf(f, "refused=%u %s\n", refused, refused ? h264ring_refusal_name(refused) : "none");
    fprintf(f, "buffered_ms=%llu\n", (unsigned long long)(((uint64_t)aud_samples + p->pcm.frames) * 1000u / 48000u));
    fprintf(f, "buffered_valid=%d\n", buffered_valid);
    fprintf(f, "buffered_start=%.3f\n", buffered_valid ? buffered_start : 0.0);
    fprintf(f, "buffered_end=%.3f\n", buffered_valid ? buffered_end : 0.0);
    fprintf(f, "error=%s\n", clean);
    if (fclose(f) || rename(tmp, p->cfg.status)) unlink(tmp);
}

static int choose_audio(AVFormatContext *fmt, int requested)
{
    if (requested >= 0) {
        if (requested >= (int)fmt->nb_streams || fmt->streams[requested]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) return -1;
        return requested;
    }
    int n = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (n >= 0) return n;
    for (unsigned i = 0; i < fmt->nb_streams; ++i)
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
            avcodec_find_decoder(fmt->streams[i]->codecpar->codec_id)) return (int)i;
    return -1;
}

static int open_media(struct player *p)
{
    AVDictionary *opts = NULL;
    int rc;
    p->fmt = avformat_alloc_context();
    if (!p->fmt) return AVERROR(ENOMEM);
    p->fmt->opaque = &p->cfg; p->fmt->io_open = io_open;
    p->fmt->interrupt_callback = (AVIOInterruptCB){interrupt_cb, p};
    av_dict_set(&opts, "probesize", "16777216", 0);
    av_dict_set(&opts, "analyzeduration", "5000000", 0);
    net_options(&p->cfg, &opts);
    rc = avformat_open_input(&p->fmt, p->cfg.url, NULL, &opts);
    av_dict_free(&opts);
    if (rc < 0) return rc;
    if ((rc = avformat_find_stream_info(p->fmt, NULL)) < 0) return rc;
    if (p->cfg.start_in_file > 0) {
        int64_t target = (int64_t)(p->cfg.start_in_file * AV_TIME_BASE);
        /* The UI offset is relative to the movie, whereas demuxer seeks use
         * container timestamps. HLS transport streams may start above zero. */
        if (p->fmt->start_time != AV_NOPTS_VALUE)
            target += p->fmt->start_time;
        rc = avformat_seek_file(p->fmt, -1, INT64_MIN, target, target, AVSEEK_FLAG_BACKWARD);
        if (rc < 0) return rc;
    }
    p->rd.vi = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (p->rd.vi < 0 || p->fmt->streams[p->rd.vi]->codecpar->codec_id != AV_CODEC_ID_H264) return AVERROR_DECODER_NOT_FOUND;
    AVRational nominal_rate = av_guess_frame_rate(p->fmt, p->fmt->streams[p->rd.vi], NULL);
    p->nominal_video_rate = nominal_rate;
    if (nominal_rate.num > 0 && nominal_rate.den > 0)
        p->nominal_video_duration90 = av_rescale_q(1, av_inv_q(nominal_rate), (AVRational){1, 90000});
    struct h264ring_status core_status;
    if (!h264ring_status(p->ring, &core_status) &&
        H264RING_ST(&core_status, VERSION) >= 0x103) {
        unsigned profile = H264RING_ST(&core_status, DISPLAY_PROFILE);
        int match_refresh = (int)H264RING_ST(&core_status, DISPLAY_MATCH_REFRESH);
        if (H264RING_ST(&core_status, VERSION) >= 0x104)
            match_refresh = (int)H264RING_ST(&core_status, DISPLAY_REFRESH_MATCH_MODE);
        int requested = (int)H264RING_ST(&core_status, DISPLAY_FILM_SPEED);
        p->film_speed = playback_speed_select(requested, profile, match_refresh,
                                              nominal_rate.num, nominal_rate.den);
    }
    logmsg("playback clock %s (source %.6g fps, audio output %d Hz)",
           !p->film_speed.enabled ? "unchanged" :
           p->film_speed.scale_num > p->film_speed.scale_den ? "NTSC 0.1% slowdown" :
           "PAL film speed-up",
           nominal_rate.den ? av_q2d(nominal_rate) : 0.0,
           film_speed_audio_rate(p->film_speed, 48000));
    p->rd.ai = choose_audio(p->fmt, p->cfg.audio_index);
    AVCodecParameters *vp = p->fmt->streams[p->rd.vi]->codecpar;
    char bsf_chain[128];
    if (p->film_speed.enabled) {
        AVRational tick_rate = av_mul_q(nominal_rate,
            (AVRational){2 * p->film_speed.scale_den, p->film_speed.scale_num});
        snprintf(bsf_chain, sizeof bsf_chain,
                 "h264_mp4toannexb,h264_metadata=tick_rate=%d/%d", tick_rate.num, tick_rate.den);
    } else {
        snprintf(bsf_chain, sizeof bsf_chain, "h264_mp4toannexb");
    }
    if ((rc = av_bsf_list_parse_str(bsf_chain, &p->bsf)) < 0 ||
        (rc = avcodec_parameters_copy(p->bsf->par_in, vp)) < 0)
        return rc < 0 ? rc : AVERROR_BSF_NOT_FOUND;
    p->bsf->time_base_in = p->fmt->streams[p->rd.vi]->time_base;
    if ((rc = av_bsf_init(p->bsf)) < 0) return rc;
    if (p->rd.ai >= 0) {
        AVCodecParameters *ap = p->fmt->streams[p->rd.ai]->codecpar;
        const AVCodec *codec = avcodec_find_decoder(ap->codec_id);
        if (!codec) return AVERROR_DECODER_NOT_FOUND;
        p->adec = avcodec_alloc_context3(codec);
        if (!p->adec || (rc = avcodec_parameters_to_context(p->adec, ap)) < 0 ||
            (rc = avcodec_open2(p->adec, codec, NULL)) < 0) return rc < 0 ? rc : AVERROR(ENOMEM);
    }
    p->rd.fmt = p->fmt;
    return 0;
}

static int start_reader(struct player *p)
{
    int rc = pthread_mutex_init(&p->rd.mutex, NULL);
    if (rc) return rc;
    p->rd.mutex_init = 1;
    rc = pthread_cond_init(&p->rd.changed, NULL);
    if (rc) return rc;
    p->rd.cond_init = 1;
    return pthread_create(&p->rd.thread, NULL, reader_main, &p->rd);
}

static void stop_reader(struct player *p)
{
    if (p->reader_joined) return;
    pthread_mutex_lock(&p->rd.mutex); atomic_store(&p->rd.abort, 1); pthread_cond_broadcast(&p->rd.changed);
    pthread_mutex_unlock(&p->rd.mutex); pthread_join(p->rd.thread, NULL);
    p->reader_joined = 1;
}

/* Called only by the main thread. The reader parks before this resets any
 * state that could contain packets from the old timeline. */
static int service_seek(struct player *p)
{
    if (!core_owner_ok(p)) return -1;
    int parked, requested, seek_rc, done, cache_pending;
    if (p->seek_state != SEEK_IN_PROGRESS) return 0;
    pthread_mutex_lock(&p->rd.mutex);
    parked = p->rd.seek_parked;
    requested = p->rd.seek_requested;
    seek_rc = p->rd.seek_rc;
    done = p->rd.done;
    cache_pending = p->rd.seek_from_cache;
    pthread_mutex_unlock(&p->rd.mutex);

    /* A queue candidate normally reaches a packet boundary immediately. If
     * the source is stalled in network I/O, interrupt it and take the normal
     * demux seek path instead of leaving the UI pending indefinitely. */
    if (cache_pending && !parked &&
        mono_ms() - p->seek_started_ms > 2500) {
        pthread_mutex_lock(&p->rd.mutex);
        p->rd.seek_from_cache = 0;
        p->seek_cache_hit = 0;
        atomic_store(&p->rd.seek_interrupt, 1);
        pthread_mutex_unlock(&p->rd.mutex);
        logmsg("buffered seek candidate timed out; falling back to demux seek");
    }

    if (p->seek_reset_done == 0 &&
        seek_protocol_next(0, parked, requested, seek_rc) == 1) {
        if (!core_owner_ok(p)) return -1;
        int rc = h264ring_flush(p->ring, 1000);
        if (rc) {
            snprintf(p->seek_error, sizeof p->seek_error, "core seek reset failed: %s", strerror(-rc));
            p->seek_state = SEEK_ERROR;
            fail(p, EX_CORE, "%s", p->seek_error);
            pthread_mutex_lock(&p->rd.mutex);
            atomic_store(&p->rd.abort, 1);
            pthread_cond_broadcast(&p->rd.changed);
            pthread_mutex_unlock(&p->rd.mutex);
            return 0;
        }
        pthread_mutex_lock(&p->rd.mutex);
        int cache_ok = 0;
        struct seek_cache_plan cache_plan;
        /* STC has reset with the ring flush, so use the pre-seek position
         * captured by the request-time cache probe. Revalidate queue contents
         * after the reader parks before pruning anything. */
        if (p->rd.seek_from_cache)
            cache_ok = cache_plan_locked(p, p->seek_current90,
                                         p->seek_target90, &cache_plan);
        if (cache_ok) {
            q_prune_before(&p->rd.vq, cache_plan.video_cut_seq, &p->rd.bytes);
            q_prune_before(&p->rd.aq, cache_plan.audio_cut_seq, &p->rd.bytes);
            p->rd.seek_from_cache = 1;
            logmsg("forward compressed-buffer seek hit; IDR overshoot %.3f s",
                   (double)cache_plan.overshoot90 / 90000.0);
            p->seek_cache_hit = 1;
        } else {
            AVPacket *pkt;
            while ((pkt = q_pop(&p->rd.vq))) av_packet_free(&pkt);
            while ((pkt = q_pop(&p->rd.aq))) av_packet_free(&pkt);
            p->rd.bytes = 0;
            p->rd.seq = 0;
            p->rd.seek_from_cache = 0;
            atomic_store(&p->rd.seek_interrupt, 0);
            p->seek_cache_hit = 0;
        }
        pthread_mutex_unlock(&p->rd.mutex);

        av_packet_free(&p->held_video);
        clear_pcm(p);
        if (p->adec) avcodec_flush_buffers(p->adec);
        av_bsf_flush(p->bsf);
        swr_free(&p->swr);
        av_channel_layout_uninit(&p->swr_in);
        p->swr_rate = 0;
        p->audio_channels_in = 0;
        p->saw_idr = 0;
        p->origin_ready = 0;
        p->origin90 = 0;
        p->newest_video90 = INT64_MIN;
        p->newest_audio90 = INT64_MIN;
        p->buffered_video_valid = p->buffered_video_broken = 0;
        p->buffered_audio_valid = p->buffered_audio_broken = 0;
        p->audio_next90 = AV_NOPTS_VALUE;
        p->audio_ring_full = 0;
        p->input_done = 0;

        /* Flush creates a new hardware session; restore session-scoped controls
         * and geometry before letting the decoder accept the new IDR. */
        set_volume(p, p->cfg.volume);
        set_playback_settings(p);
        if (apply_geometry(p)) {
            snprintf(p->seek_error, sizeof p->seek_error,
                     "cannot restore display geometry after seek");
            p->seek_state = SEEK_ERROR;
            fail(p, EX_CORE, "%s", p->seek_error);
            pthread_mutex_lock(&p->rd.mutex);
            atomic_store(&p->rd.abort, 1);
            pthread_cond_broadcast(&p->rd.changed);
            pthread_mutex_unlock(&p->rd.mutex);
            return 0;
        }
        if (!core_owner_ok(p)) return -1;
        rc = h264ring_set_pause(p->ring, p->paused);
        if (rc) {
            snprintf(p->seek_error, sizeof p->seek_error, "cannot restore pause after seek reset: %s", strerror(-rc));
            p->seek_state = SEEK_ERROR;
            fail(p, EX_CORE, "%s", p->seek_error);
            pthread_mutex_lock(&p->rd.mutex);
            atomic_store(&p->rd.abort, 1);
            pthread_cond_broadcast(&p->rd.changed);
            pthread_mutex_unlock(&p->rd.mutex);
            return 0;
        }
        pthread_mutex_lock(&p->rd.mutex);
        p->rd.seek_go = 1;
        p->seek_reset_done = 1;
        /* Rebase the reader horizon while the flushed core has no STC yet. */
        atomic_store(&p->rd.playhead90, p->seek_target90);
        pthread_cond_broadcast(&p->rd.changed);
        pthread_mutex_unlock(&p->rd.mutex);
        return 1;
    }
    if (p->seek_reset_done == 1 &&
        seek_protocol_next(1, parked, requested, seek_rc) != 1) {
        if (seek_protocol_next(1, parked, requested, seek_rc) < 0) {
            char err[128];
            av_strerror(seek_rc, err, sizeof err);
            snprintf(p->seek_error, sizeof p->seek_error, "demux seek failed: %s", err);
            p->seek_state = SEEK_ERROR;
            fail(p, EX_STREAM, "%s", p->seek_error);
            return 0;
        }
        p->seek_reset_done = 2;
        return 0;
    }
    if (p->seek_reset_done == 2 && done) {
        pthread_mutex_lock(&p->rd.mutex);
        int empty = !p->rd.vq.head && !p->rd.aq.head;
        pthread_mutex_unlock(&p->rd.mutex);
        if (empty && !p->saw_idr) {
            strcpy(p->seek_error, "no keyframe followed the requested position");
            p->seek_state = SEEK_ERROR;
            fail(p, EX_STREAM, "%s", p->seek_error);
            return 0;
        }
    }
    return p->seek_reset_done < 2;
}

/* --direct: feed Annex-B SPS / PPS to the pre-check. Returns 1 when the
 * stream passed, 0 while undecided, -1 after failing with EX_NEEDS_TRANSCODE.
 * final: no more parameter sets will come before the first picture. */
static int direct_precheck(struct player *p, const uint8_t *data, size_t len, int final)
{
    const char *why = "no SPS / PPS before the first picture";
    AVRational fr = p->nominal_video_rate;
    double fps = fr.num > 0 && fr.den > 0 ? av_q2d(fr) : 0.0;
    int rc = data && len ? direct_check_au(&p->dcheck, data, len, fps, &why) : 0;
    if (rc > 0) {
        p->direct_ok = 1;
        logmsg("direct stream pre-check passed (profile %u, %ux%u macroblocks, %.3f fps)",
               p->dcheck.chk.profile_idc, p->dcheck.chk.width_mbs,
               p->dcheck.chk.height_map_units * (p->dcheck.chk.frame_mbs_only ? 1u : 2u), fps);
        return 1;
    }
    if (rc < 0 || final) {
        fail(p, EX_NEEDS_TRANSCODE, "direct stream needs a transcode: %s", why);
        return -1;
    }
    return 0;
}

static int receive_video(struct player *p)
{
    int rc;
    for (;;) {
        AVPacket *out = av_packet_alloc();
        if (!out) return AVERROR(ENOMEM);
        rc = av_bsf_receive_packet(p->bsf, out);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) { av_packet_free(&out); return 0; }
        if (rc < 0) { av_packet_free(&out); return rc; }
        if (!p->saw_idr && !annexb_idr(out->data, (size_t)out->size)) {
            av_packet_free(&out); continue;
        }
        if (!p->saw_idr && p->cfg.direct && !p->direct_ok &&
            direct_precheck(p, out->data, (size_t)out->size, 1) < 0) {
            /* nothing of the stream reaches the core */
            av_packet_free(&out); return 0;
        }
        if (!p->saw_idr) {
            int64_t raw = packet_raw_pts90(p, out, p->rd.vi);
            if (raw != AV_NOPTS_VALUE) {
                p->origin90 = raw - PTS_MARGIN;
                p->origin_ready = 1;
                if (getenv("JFPLAY_DEBUG")) {
                    double source = (double)raw / 90000.0;
                    if (p->fmt->start_time != AV_NOPTS_VALUE)
                        source -= (double)p->fmt->start_time / AV_TIME_BASE;
                    logmsg("first video source_seconds=%.3f requested_seek=%.3f", source, p->cfg.start_in_file);
                }
            }
            p->saw_idr = 1;
            log_first_au(out);
        }
        while (p->held_video && !atomic_load(&p->exit_code) &&
               !atomic_load(&p->stop) &&
               (p->seek_state != SEEK_IN_PROGRESS || p->seek_reset_done == 2)) {
            rc = ring_result(p, write_au(p, p->held_video, 0), "video");
            if (!rc) { av_packet_free(&p->held_video); break; }
            if (rc != -EAGAIN) break;
            while (write_pcm(p, 0) > 0) ;
            poll_fifo(p); write_status(p, 0); usleep(1500);
        }
        if (!seek_protocol_can_process(p->seek_state == SEEK_IN_PROGRESS,
                                       p->seek_reset_done)) {
            av_packet_free(&out);
            return 0;
        }
        if (atomic_load(&p->exit_code) || atomic_load(&p->stop)) {
            av_packet_free(&out); return 0;
        }
        p->held_video = out;
    }
}

static int handle_video(struct player *p, AVPacket *in)
{
    int rc;
    for (;;) {
        rc = av_bsf_send_packet(p->bsf, in);
        if (rc != AVERROR(EAGAIN)) break;
        rc = receive_video(p);
        if (rc < 0) { av_packet_free(&in); return rc; }
    }
    av_packet_free(&in);
    if (rc < 0) return rc;
    return receive_video(p);
}

static int submit_eos(struct player *p, uint64_t deadline_ms, int best_effort)
{
    int rc = 0;
    if (!p->held_video) return 0;
    do {
        rc = write_au(p, p->held_video, H264RING_F_END_OF_STREAM);
        if (!best_effort) rc = ring_result(p, rc, "end of stream");
        else if (rc && rc != -EAGAIN) {
            logmsg("best-effort end of stream failed: %s", strerror(-rc));
            break;
        }
        if (rc == -EAGAIN) {
            poll_fifo(p); write_status(p, 0); usleep(1500);
            if (caught_signal) atomic_store(&p->stop, 1);
            if (atomic_load(&p->stop) || p->seek_state == SEEK_IN_PROGRESS)
                return AVERROR(EINTR);
        }
    } while (rc == -EAGAIN && !atomic_load(&p->exit_code) &&
             (!deadline_ms || mono_ms() < deadline_ms));
    if (!rc) av_packet_free(&p->held_video);
    return rc;
}

static int drain_natural_eof(struct player *p)
{
    int rc;
    int seek_id = p->seek_id;
    if (caught_signal) atomic_store(&p->stop, 1);
    if (atomic_load(&p->stop)) return AVERROR_EXIT;
    if (p->bsf) {
        rc = handle_video(p, NULL);
        if (rc < 0) return rc;
    }
    while (p->pcm.frames && !atomic_load(&p->exit_code) &&
           !atomic_load(&p->stop)) {
        if (caught_signal) atomic_store(&p->stop, 1);
        if (atomic_load(&p->stop)) return AVERROR_EXIT;
        if (p->seek_state == SEEK_IN_PROGRESS) return AVERROR(EINTR);
        rc = write_pcm(p, 1);
        if (rc == -EAGAIN || rc == 0) {
            poll_fifo(p); write_status(p, 0); usleep(1500);
        } else if (rc < 0) return rc;
    }
    if (atomic_load(&p->stop)) return AVERROR_EXIT;
    if (p->seek_state == SEEK_IN_PROGRESS) return AVERROR(EINTR);
    if (p->adec) {
        rc = decode_audio(p, NULL);
        if (rc < 0 && rc != AVERROR_EOF) return rc;
        if (caught_signal) atomic_store(&p->stop, 1);
        if (atomic_load(&p->stop)) return AVERROR_EXIT;
        if (p->seek_state == SEEK_IN_PROGRESS) return AVERROR(EINTR);
        if ((rc = drain_swr(p)) < 0) return rc;
    }
    while (p->pcm.frames && !atomic_load(&p->exit_code) &&
           !atomic_load(&p->stop)) {
        if (caught_signal) atomic_store(&p->stop, 1);
        if (atomic_load(&p->stop)) return AVERROR_EXIT;
        if (p->seek_state == SEEK_IN_PROGRESS) return AVERROR(EINTR);
        rc = write_pcm(p, 1);
        if (rc == -EAGAIN || rc == 0) { poll_fifo(p); write_status(p, 0); usleep(1500); }
        else if (rc < 0) return rc;
    }
    if (atomic_load(&p->stop)) return AVERROR_EXIT;
    rc = submit_eos(p, 0, 0);
    if (rc < 0) return rc;

    /* EOS only tells the core no more packets are coming. The display keeps
     * playing buffered video/audio until it reports ENDED. Keep FIFO/status
     * servicing active, including the parked demux reader's EOF seek path. */
    for (;;) {
        struct h264ring_status st;
        if (caught_signal) atomic_store(&p->stop, 1);
        if (atomic_load(&p->stop)) return AVERROR_EXIT;
        poll_fifo(p);
        write_status(p, 0);
        /* Return to main immediately: only its packet loop can feed the IDR
         * needed to finish an in-progress seek after the reset phase. */
        if (p->seek_id != seek_id || p->seek_state == SEEK_IN_PROGRESS)
            return AVERROR(EINTR);
        if (atomic_load(&p->exit_code)) return AVERROR_EXIT;
        if (h264ring_status(p->ring, &st)) return -EIO;
        if (H264RING_ST(&st, STATE) == H264RING_S_ENDED &&
            H264RING_ST(&st, AUD_STATE) == 0 &&
            H264RING_ST(&st, AUD_Q_SAMPLES) == 0) return 0;
        if (H264RING_ST(&st, STATE) == H264RING_S_ERROR) return -EIO;
        usleep(1500);
    }
}

static void discard_packets(struct player *p)
{
    AVPacket *pkt;
    while ((pkt = q_pop(&p->rd.vq))) av_packet_free(&pkt);
    while ((pkt = q_pop(&p->rd.aq))) av_packet_free(&pkt);
    p->rd.bytes = 0;
}

static void stop_quickly(struct player *p)
{
    if (!core_owner_ok(p)) {
        p->have_stop_position = 1;
        clear_pcm(p);
        av_packet_free(&p->held_video);
        p->input_done = 1;
        return;
    }
    if (p->have_stop_position) return;
    struct h264ring_status st;
    int have = p->ring && core_owner_ok(p) && !h264ring_status(p->ring, &st);
    p->stop_position = playback_position(p, &st, have);
    p->have_stop_position = 1;
    p->paused = 0;
    if (p->ring) {
        /* EOS waits behind buffered media. Silence first, then discard the
         * hardware queues so audio cannot outlive this worker. */
        if (!core_owner_ok(p)) return;
        int rc = h264ring_set_pause(p->ring, 1);
        if (rc) logmsg("pause for stop failed: %s", strerror(-rc));
        if (!core_owner_ok(p)) return;
        rc = h264ring_flush(p->ring, 1000);
        if (rc) {
            p->stop_reset_failed = 1;
            fail(p, EX_CORE, "core stop reset failed: %s", strerror(-rc));
        }
    }
    /* The demux thread may still own its packet queues. Cleanup discards
     * those after joining it; PCM and held_video belong to this thread. */
    clear_pcm(p);
    av_packet_free(&p->held_video);
    p->input_done = 1;
    if (!p->stop_reset_failed) p->state = STATE_ENDED;
}

static void cleanup(struct player *p, int reader_started)
{
    if (reader_started) stop_reader(p);
    discard_packets(p);
    av_packet_free(&p->held_video); clear_pcm(p);
    swr_free(&p->swr); av_channel_layout_uninit(&p->swr_in);
    avcodec_free_context(&p->adec); av_bsf_free(&p->bsf); avformat_close_input(&p->fmt);
    if (p->fifo_fd >= 0) close(p->fifo_fd);
    if (p->ring) {
        if (core_owner_ok(p)) {
            if (!p->stop_reset_failed) (void)h264ring_set_pause(p->ring, 0);
            if (core_owner_ok(p)) (void)h264ring_clear_settings(p->ring);
        }
        h264ring_close(p->ring);
    }
    if (p->rd.cond_init) pthread_cond_destroy(&p->rd.changed);
    if (p->rd.mutex_init) pthread_mutex_destroy(&p->rd.mutex);
}

int main(int argc, char **argv)
{
    struct player p;
    struct stat fifo_st;
    int rc, reader_started = 0, reader_err = 0, result = 0;
    memset(&p, 0, sizeof p); p.fifo_fd = -1; p.newest_video90 = INT64_MIN; p.newest_audio90 = INT64_MIN; p.audio_next90 = AV_NOPTS_VALUE;
    atomic_init(&p.stop, 0); atomic_init(&p.exit_code, 0);
    atomic_init(&p.rd.abort, 0); atomic_init(&p.rd.err, 0);
    atomic_init(&p.rd.seek_interrupt, 0);
    atomic_init(&p.rd.playhead90, INT64_MIN);
    p.state = STATE_OPENING;
    av_log_set_level(AV_LOG_WARNING);
    if (parse_args(argc, argv, &p.cfg)) { usage(); return EX_ARGS; }
    if (getenv("JFPLAY_LOG_URLS") && !strcmp(getenv("JFPLAY_LOG_URLS"), "1")) logmsg("opening %s", p.cfg.url);
    else logmsg("opening media URL (hidden)");
    signal(SIGINT, signal_handler); signal(SIGTERM, signal_handler);
    write_status(&p, 1);
    p.core_owner.app_name = p.cfg.core_name;
    if ((rc = h264ring_launch_core_as(p.cfg.rbf, p.cfg.core_name, 5000)) ||
        (rc = h264ring_open_devmem(&p.ring, 0))) {
        fail(&p, EX_CORE, "H.264 core unavailable: %s", strerror(-rc)); goto done;
    }
    p.core_owned = 1;
    if (!core_owner_ok(&p)) goto done;
    p.paused = p.cfg.hold;
    if (!core_owner_ok(&p)) goto done;
    rc = h264ring_set_pause(p.ring, p.paused);
    if (!rc && core_owner_ok(&p)) rc = h264ring_start_session(p.ring, 2000);
    else if (!rc) rc = -ECANCELED;
    if (rc) {
        fail(&p, EX_CORE, "cannot start core session: %s", strerror(-rc)); goto done;
    }
    set_volume(&p, p.cfg.volume);
    set_playback_settings(&p);
    if (mkfifo(p.cfg.fifo, 0600)) {
        if (errno != EEXIST || lstat(p.cfg.fifo, &fifo_st) || !S_ISFIFO(fifo_st.st_mode)) {
            fail(&p, EX_OPEN, "control path is not a FIFO: %s", p.cfg.fifo); goto done;
        }
    }
    p.fifo_fd = open(p.cfg.fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (p.fifo_fd < 0) {
        fail(&p, EX_OPEN, "cannot open control FIFO: %s", strerror(errno)); goto done;
    }
    rc = open_media(&p);
    if (rc < 0) {
        char e[128];
        if (caught_signal) {
            atomic_store(&p.stop, 1); stop_quickly(&p); goto done;
        }
        av_strerror(rc, e, sizeof e);
        fail(&p, EX_OPEN, "stream open failed: %s", e); goto done;
    }
    if (p.cfg.direct) {
        /* The container's parameter sets, before anything is shown (a
         * transport stream has none here; its first IDR is checked). */
        const AVCodecParameters *op = p.bsf->par_out;
        const uint8_t *x = op->extradata;
        if (x && op->extradata_size >= 4 && !x[0] && !x[1] && (x[2] == 1 || (!x[2] && x[3] == 1)) &&
            direct_precheck(&p, x, (size_t)op->extradata_size, 0) < 0)
            goto done;
    }
    if (apply_geometry(&p)) goto done;
    p.opened = 1; p.state = p.paused ? STATE_PAUSED : STATE_PLAYING; write_status(&p, 1);
    rc = start_reader(&p);
    if (rc) { fail(&p, EX_STREAM, "cannot start demux reader: %s", strerror(rc)); goto done; }
    reader_started = 1;
    int dbg_on = getenv("JFPLAY_DEBUG") != NULL; unsigned long dbg_records = 0;
    struct timespec dbg_last = {0, 0};
    while (!atomic_load(&p.exit_code) && !atomic_load(&p.stop)) {
        int kind = -1, progressed = 0;
        if (caught_signal) atomic_store(&p.stop, 1);
        if (!core_owner_ok(&p)) break;
        poll_fifo(&p); write_status(&p, 0);
        if (service_seek(&p)) { usleep(1500); continue; }
        /* Write every audio record that is ready before the next video AU: the
         * core's descriptor FIFO holds 256 entries, so audio that trails its
         * video by more than a few seconds in ring order is parsed too late. */
        while ((rc = write_pcm(&p, p.input_done)) > 0) { progressed = 1; ++dbg_records; }
        p.audio_ring_full = rc == -EAGAIN;
        if (dbg_on) {
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - dbg_last.tv_sec >= 2) {
                struct h264ring_status st;
                                dbg_last = now;
                if (!h264ring_status(p.ring, &st))
                    logmsg("dbg stc=%lld nv=%lld na=%lld pcm=%zu rec=%lu played=%lu late=%lu under=%lu gap=%lu qrec=%lu astate=%lu reanch=%lu free=%lu splits=%lu pad=%lu untimed=%lu",
                           (long long)H264RING_ST(&st, STC), (long long)p.newest_video90, (long long)p.newest_audio90,
                           p.pcm.frames, dbg_records, (unsigned long)H264RING_ST(&st, AUD_PLAYED),
                           (unsigned long)H264RING_ST(&st, AUD_LATE), (unsigned long)H264RING_ST(&st, AUD_UNDERRUNS),
                           (unsigned long)H264RING_ST(&st, AUD_GAP), (unsigned long)H264RING_ST(&st, AUD_Q_REC),
                           (unsigned long)H264RING_ST(&st, AUD_STATE), (unsigned long)H264RING_ST(&st, DISP_REANCHOR),
                           (unsigned long)h264ring_free(p.ring), p.dbg_splits, p.dbg_pad, p.dbg_untimed);
            }
        }
        if (rc < 0 && rc != -EAGAIN) break;
        AVPacket *pkt = take_packet(&p, &kind);
        if (pkt) {
            progressed = 1;
            if (!kind) rc = handle_video(&p, pkt);
            else { rc = p.adec ? decode_audio(&p, pkt) : 0; av_packet_free(&pkt); }
            if (rc < 0) { char e[128]; av_strerror(rc, e, sizeof e); fail(&p, EX_STREAM, "media processing failed: %s", e); }
        }
        if (p.input_done) {
            rc = drain_natural_eof(&p);
            if (rc == AVERROR(EINTR)) continue;
            if (atomic_load(&p.stop)) break;
            if (rc < 0) {
                char e[128]; av_strerror(rc, e, sizeof e);
                fail(&p, EX_STREAM, "end-of-input drain failed: %s", e);
                break;
            }
            p.state = STATE_ENDED;
            break;
        }
        if (!progressed) usleep(1500);
    }
    if (atomic_load(&p.stop)) stop_quickly(&p);
    if (reader_started) {
        stop_reader(&p);
        reader_err = atomic_load(&p.rd.err);
    }
    if (!atomic_load(&p.exit_code)) {
        if (atomic_load(&p.stop)) stop_quickly(&p);
        else if (reader_err) {
            char e[128]; av_strerror(reader_err, e, sizeof e);
            fail(&p, EX_STREAM, "demux failed: %s", e);
        }
    }
done:
    /* END deliberately holds the decoder's last picture. Release it on every
     * worker exit so playback-only refresh/240p/native modes return to menus.
     * Keep an existing stream error visible after resetting the display. */
    if (p.opened && !p.have_stop_position) {
        int terminal_state = p.state;
        stop_quickly(&p);
        if (atomic_load(&p.exit_code) && !p.stop_reset_failed)
            p.state = terminal_state;
    }
    result = atomic_load(&p.exit_code);
    write_status(&p, 1);
    cleanup(&p, reader_started);
    return result;
}
