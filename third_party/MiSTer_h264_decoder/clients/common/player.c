/* player -- a stream from a URL into the core (player.h; docs/jellyfin.md S2 "Delivery", S3;
 * docs/player.md for a file's tracks and text subtitles). */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include "h264ring_cavlc.h"
#include "player.h"
#include "vdec.h"

#define QUEUE_PKTS    512                 /* the reader's video (and subtitle) queue: packets ... */
#define QUEUE_BYTES   (6u << 20)          /* ... and bytes (the ring itself holds 8 MB) */
#define AQUEUE_PKTS   1024                /* its audio queue: ~20 s of AAC, ~10 s of DTS ... */
#define AQUEUE_BYTES  (2u << 20)          /* ... at most */
#define AUD_LEAD      90000               /* audio written at most 1 s (90 kHz) ahead of the video: the
                                             core keeps 256 records (5.12 s) it has not played and stops
                                             reading the ring past them, the video behind them too
                                             (docs/jellyfin.md S12) */
#define AUD_RECORD    960                 /* audio frames gathered into one record: 20 ms (>= the library's 5 ms) */
#define STEP_PACKETS  64                  /* packets one step moves at most (the loop stays responsive) */
#define STEP_BUDGET_MS 10                 /* ... and the time it may spend: a write can take long (the
                                             CAVLC rewrite on the A9: ~16 ms an access unit of an 8 Mbit/s
                                             480p60 stream, more for an IDR), and the client's loop -- the pad,
                                             the overlay --
                                             runs between steps: 64 such writes held it ~a second, and a
                                             press shorter than that was never seen (the maintainer's
                                             round, 2026-10-02: Back + Start held for seconds to quit) */

#ifdef CLIENT_TEST
unsigned client_test_write_us;            /* the host test: each video write costs this long (the A9's rewrite) */
#endif
#define PTS_MASK      ((1ull << 33) - 1)  /* the ring's PTS field */

/* a bounded packet queue (the reader pushes, the loop pops; under the player's mx). Each packet
 * carries the demuxer's order, so the loop can keep it across the two queues. */
struct pq {
    AVPacket *q[AQUEUE_PKTS];
    uint64_t seq[AQUEUE_PKTS];
    unsigned head, tail, max;             /* pop at head, push at tail; max <= AQUEUE_PKTS */
    size_t bytes, max_bytes;
};

struct player {
    struct player_cfg cfg;
    char *url, *headers, *cafile;
    pthread_t thread;
    int thread_up;
    pthread_mutex_t mx;
    pthread_cond_t cv;
    /* the reader's side (under mx) */
    struct pq vq, aq;                     /* the video and subtitles; the audio (docs/jellyfin.md S12) */
    uint64_t seq;                         /* the demuxer's order: the next packet's */
    int opened, eof, failed, abort;
    char err[160];
    /* set by the reader before `opened`, read-only after */
    AVFormatContext *fmt;
    int (*io_open_default)(struct AVFormatContext *, AVIOContext **, const char *, int, AVDictionary **);
    int vs, as;                           /* stream indexes (-1: none) */
    AVBSFContext *bsf;                    /* avcC -> Annex B (MKV / MP4), or NULL (TS is Annex B) */
    AVCodecContext *adec;
    SwrContext *swr;
    AVChannelLayout swr_in;               /* what swr was built for: the last frame's layout, format, rate */
    int swr_fmt, swr_rate;
    struct player_info info;              /* set by the reader before `opened` (or `failed` after the open) */
    int have_info;
    AVCodecContext **sdec;                /* (text_subs) a decoder per text track, info.subs' order */
    struct subs **subs;                   /* ... and its cues */
    int *sub_of;                          /* stream index -> text track (-1 none); nb_streams long */
    /* the loop's side */
    enum player_state state;
    struct h264check_state chk;
    enum h264check verdict;
    int started;                          /* the first (IDR) access unit written */
    int64_t first_pts;                    /* 90 kHz, the first access unit's (-1: none yet) */
    int64_t vmax;                         /* 90 kHz, the newest video PTS handed on (-1: none yet): the
                                             audio waits while it is more than AUD_LEAD ahead of it */
    /* the video: `hold` is the newest access unit (written once the next exists, or at the end
     * with END_OF_STREAM); `out` is one the ring had no room for yet */
    AVPacket *hold, *out;
    unsigned out_flags;
    /* the audio: s16 stereo frames gathered, and a record the ring had no room for */
    int16_t *pcm;
    unsigned pcm_frames, pcm_cap;
    int64_t pcm_pts;
    int64_t apts_next;                    /* 90 kHz: where the next decoded frame starts (-1 unknown) --
                                             a frame without a time takes it (S12: a TS whose audio the
                                             probe missed times only each PES's first frame) */
    int16_t *aout;
    unsigned aout_bytes;
    int64_t aout_pts;
    struct player_counts n;
    int released;                         /* (hold) player_release() called */
    int rewrite_refused;                  /* (cavlc_ok) the library's rewrite refused the stream */
    int skip_to_idr;                      /* (cavlc_ok) a unit the rewrite could not parse: the next IDR */
    char trim_path[64];                   /* (hls_trim) the trimmed playlist written to /tmp */
    double trim_origin_s;                 /* (hls_trim) the item's time of the stream's start_time ... */
    int trimmed;                          /* ... known */
    /* (arm_video) the video decoded here (vdec.h): a packet its queue had no room for; the next
     * picture to send (written once another is decoded, or at the end with END_OF_STREAM); a store
     * acquired and copied for it, its record not yet in the ring; the decoder drained */
    struct vdec *vd;
    AVPacket *vpend;
    AVFrame *vnext;
    int vk, vcopied, vdone, vended;
    uint64_t late_ms, late_n, nonref_until;
    /* the open's timing (CLIENT_TIMING): open, stream info, seek, first packet, first IDR */
    uint64_t t0, t_open, t_info, t_seek, t_pkt, t_idr;
};

static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* ---- the reader thread ---- */

static int interrupted(void *opaque)
{
    struct player *p = opaque;
    return __atomic_load_n(&p->abort, __ATOMIC_RELAXED);
}

/* every request the demuxer opens -- the HLS playlists' and segments' too, which do not inherit
 * the first open's TLS options -- verifies the server against the client's CA bundle */
static int io_open_hook(struct AVFormatContext *s, AVIOContext **pb, const char *url, int flags,
                        AVDictionary **options)
{
    struct player *p = s->opaque;
    AVDictionary *o = NULL;
    if (options && *options) av_dict_copy(&o, *options, 0);
    if (p->cafile) av_dict_set(&o, "ca_file", p->cafile, 0);
    av_dict_set(&o, "tls_verify", "1", 0);
    if (p->headers) av_dict_set(&o, "headers", p->headers, 0);
    /* one connection for a file's range requests (a seek reads the Cues, then jumps): a TLS handshake
     * is ~0.4 s on the A9 */
    av_dict_set(&o, "multiple_requests", "1", 0);
    int rc = p->io_open_default(s, pb, url, flags, &o);
    av_dict_free(&o);
    return rc;
}

/* GET a playlist into memory through FFmpeg's own HTTP(S) (the client's CA bundle) */
static char *fetch(struct player *p, const char *url)
{
    AVIOContext *io = NULL;
    AVDictionary *o = NULL;
    if (p->cafile) av_dict_set(&o, "ca_file", p->cafile, 0);
    av_dict_set(&o, "tls_verify", "1", 0);
    if (p->headers) av_dict_set(&o, "headers", p->headers, 0);
    AVIOInterruptCB cb = { interrupted, p };
    int rc = avio_open2(&io, url, AVIO_FLAG_READ, &cb, &o);
    av_dict_free(&o);
    if (rc < 0) return NULL;
    size_t n = 0, cap = 1 << 16;
    char *b = malloc(cap);
    for (int k; b && (k = avio_read(io, (unsigned char *)b + n, (int)(cap - n - 1))) > 0;) {
        n += (size_t)k;
        if (cap - n < 4096) { char *nb = realloc(b, cap *= 2); if (!nb) { free(b); b = NULL; } else b = nb; }
    }
    avio_closep(&io);
    if (b) b[n] = 0;
    return b;
}

/* the transcode's playlist from the segment holding start_s: the server's playlist lists the whole
 * film (3 s segments, each URL carrying its start as runtimeTicks), and opening it fetches segment
 * 0 to probe -- the server starts transcoding the film's beginning, then a seek kills that and starts
 * again at the target (two encoder starts, ~2.8 + ~2 s on the rig, 2026-10-01). Written to /tmp; the
 * segments are the server's own URLs. Returns the path, or NULL (then the plain open and a seek). */
static const char *trim_hls(struct player *p)
{
    char *master = fetch(p, p->url);
    if (!master) return NULL;
    const char *q = strchr(p->url, '?');
    const char *slash = p->url;
    for (const char *x = p->url; *x && (!q || x < q); x++) if (*x == '/') slash = x;
    size_t baselen = (size_t)(slash - p->url) + 1;
    char *variant = NULL;
    for (char *line = strtok(master, "\r\n"); line; line = strtok(NULL, "\r\n"))
        if (line[0] && line[0] != '#') { variant = line; break; }
    char *url = variant ? malloc(baselen + strlen(variant) + 1) : NULL;
    char *main_pl = NULL;
    if (url) { memcpy(url, p->url, baselen); strcpy(url + baselen, variant); main_pl = fetch(p, url); }
    free(master);
    free(url);
    if (!main_pl) return NULL;
    /* the segment whose start is the last at or before start_s */
    char *start = NULL, *extinf = NULL, *prev_inf = NULL;
    double seg_s = 0;
    long seq = 0, k = 0;
    for (char *l = main_pl; *l;) {
        char *e = l + strcspn(l, "\r\n");
        if (!strncmp(l, "#EXTINF", 7)) extinf = l;
        else if (*l && *l != '#') {
            const char *rt = strstr(l, "runtimeTicks=");
            double t = rt ? (double)strtoll(rt + 13, NULL, 10) / 1e7 : -1;
            if (t < 0) { free(main_pl); return NULL; }
            if (t > p->cfg.start_s + 1e-3 && start) break;
            start = l; prev_inf = extinf; seg_s = t; seq = k++;
        }
        l = e + strspn(e, "\r\n");
    }
    if (!start || !prev_inf) { free(main_pl); return NULL; }
    snprintf(p->trim_path, sizeof p->trim_path, "/tmp/jellyfin_trim_XXXXXX.m3u8");
    int fd = mkstemps(p->trim_path, 5);       /* .m3u8: FFmpeg 8 detects HLS by its extension */
    FILE *f = fd >= 0 ? fdopen(fd, "w") : NULL;
    if (!f) { free(main_pl); p->trim_path[0] = 0; return NULL; }
    fprintf(f, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-PLAYLIST-TYPE:VOD\n"
               "#EXT-X-MEDIA-SEQUENCE:%ld\n", seq);
    for (char *l = prev_inf; *l;) {                  /* from the target's #EXTINF on, segments absolute */
        char *e = l + strcspn(l, "\r\n");
        if (!strncmp(l, "#EXTINF", 7)) fprintf(f, "%.*s\n", (int)(e - l), l);
        else if (*l && *l != '#') fprintf(f, "%.*s%.*s\n", (int)baselen, p->url, (int)(e - l), l);
        l = e + strspn(e, "\r\n");
    }
    fprintf(f, "#EXT-X-ENDLIST\n");
    fclose(f);
    free(main_pl);
    p->trim_origin_s = seg_s;                        /* the item's time at the first segment's start */
    return p->trim_path;
}

static void fail(struct player *p, const char *what, int rc)
{
    char e[96];
    av_strerror(rc, e, sizeof e);
    pthread_mutex_lock(&p->mx);
    snprintf(p->err, sizeof p->err, "%s: %s", what, e);
    p->failed = 1;
    pthread_cond_broadcast(&p->cv);
    pthread_mutex_unlock(&p->mx);
}

/* swr for this input (to 48 kHz s16 stereo), built again whenever a frame's input differs from the one
 * it was built for. 2026-10-06: the decoder's layout at open is NOT the frames' -- dca takes `downmix`
 * and reports stereo at open, but a DTS track without embedded downmix coefficients keeps decoding 5.1:
 * swr built for stereo read planes 0 and 1 (FL, FR) and dropped the center and the surrounds (a
 * Blu-ray rip's DTS 5.1: no dialogue). AC-3 / E-AC-3 do downmix, center included. */
static int swr_for(struct player *p, const AVChannelLayout *in, int fmt, int rate)
{
    if (p->swr && !av_channel_layout_compare(&p->swr_in, in) && p->swr_fmt == fmt && p->swr_rate == rate)
        return 0;
    swr_free(&p->swr);
    av_channel_layout_uninit(&p->swr_in);
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    int rc = swr_alloc_set_opts2(&p->swr, &stereo, AV_SAMPLE_FMT_S16, 48000, in, (enum AVSampleFormat)fmt, rate, 0, NULL);
    if (rc < 0) return rc;
    if ((rc = av_channel_layout_copy(&p->swr_in, in)) < 0) return rc;
    p->swr_fmt = fmt; p->swr_rate = rate;
    return swr_init(p->swr);
}

static int open_audio(struct player *p)
{
    AVStream *st = p->fmt->streams[p->as];
    const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;
    if (!(p->adec = avcodec_alloc_context3(dec))) return AVERROR(ENOMEM);
    int rc = avcodec_parameters_to_context(p->adec, st->codecpar);
    if (rc < 0) return rc;
    p->adec->pkt_timebase = st->time_base;
    /* AC-3 / E-AC-3 downmix in the decoder (docs/jellyfin.md S3); swr does the rest */
    av_opt_set(p->adec, "downmix", "stereo", AV_OPT_SEARCH_CHILDREN);
    /* no swr here: audio() builds it from each frame's own layout, format and rate. A stream whose
     * first packets came after the probe has none of them yet (sample rate 0: swr refused it, and the
     * whole stream played silent -- a 9.6 Mbit/s transcode, 2026-10-09); its decoder learns them from
     * the stream itself (ADTS, the AC-3 header) */
    return avcodec_open2(p->adec, dec, NULL);
}

/* a format's name as people say it */
static const char *codec_label(enum AVCodecID id)
{
    switch (id) {
    case AV_CODEC_ID_AAC: case AV_CODEC_ID_AAC_LATM: return "AAC";
    case AV_CODEC_ID_AC3: return "AC-3";
    case AV_CODEC_ID_EAC3: return "E-AC-3";
    case AV_CODEC_ID_DTS: return "DTS";
    case AV_CODEC_ID_TRUEHD: return "TrueHD";
    case AV_CODEC_ID_MP3: return "MP3";
    case AV_CODEC_ID_MP2: return "MP2";
    case AV_CODEC_ID_OPUS: return "Opus";
    case AV_CODEC_ID_VORBIS: return "Vorbis";
    case AV_CODEC_ID_FLAC: return "FLAC";
    case AV_CODEC_ID_H264: return "H.264";
    case AV_CODEC_ID_HEVC: return "HEVC (H.265)";
    case AV_CODEC_ID_AV1: return "AV1";
    case AV_CODEC_ID_VP9: return "VP9";
    case AV_CODEC_ID_VP8: return "VP8";
    case AV_CODEC_ID_MPEG2VIDEO: return "MPEG-2";
    case AV_CODEC_ID_MPEG4: return "MPEG-4 Part 2 (DivX / Xvid)";
    case AV_CODEC_ID_VC1: return "VC-1";
    case AV_CODEC_ID_SUBRIP: return "SRT";
    case AV_CODEC_ID_ASS: case AV_CODEC_ID_SSA: return "ASS";
    case AV_CODEC_ID_MOV_TEXT: return "mov_text";
    case AV_CODEC_ID_WEBVTT: return "WebVTT";
    default: return avcodec_get_name(id);
    }
}

static void track_name(const AVStream *st, char *b, size_t n)
{
    const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
    const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
    int has_lang = lang && strcmp(lang->value, "und");
    char ch[16] = "";
    if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        int c = st->codecpar->ch_layout.nb_channels;
        snprintf(ch, sizeof ch, "%s", c == 1 ? " mono" : c == 2 ? " stereo" : c == 6 ? " 5.1" : c == 8 ? " 7.1" : "");
        if (!ch[0] && c > 0) snprintf(ch, sizeof ch, " %dch", c);
    }
    snprintf(b, n, "%s%s%s%s%s%s", has_lang ? lang->value : "", has_lang ? "  " : "",
             title ? title->value : "", title ? "  " : "", codec_label(st->codecpar->codec_id), ch);
}

static int is_text_sub(const AVStream *st)
{
    const AVCodecDescriptor *d = avcodec_descriptor_get(st->codecpar->codec_id);
    return st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && d && (d->props & AV_CODEC_PROP_TEXT_SUB);
}

/* the stream's shape and tracks, from the probe (before the H.264 check: a refusal can name them) */
static void fill_info(struct player *p)
{
    struct player_info *in = &p->info;
    AVFormatContext *f = p->fmt;
    in->duration = f->duration > 0 ? (double)f->duration / AV_TIME_BASE : 0;
    in->audio_cur = -1;
    int v = av_find_best_stream(f, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (v >= 0) {
        AVStream *st = f->streams[v];
        snprintf(in->video, sizeof in->video, "%s", avcodec_get_name(st->codecpar->codec_id));
        in->width = st->codecpar->width;
        in->height = st->codecpar->height;
        AVRational r = st->avg_frame_rate.num && st->avg_frame_rate.den ? st->avg_frame_rate : st->r_frame_rate;
        in->fps = r.num && r.den ? av_q2d(r) : 0;
        AVRational sar = av_guess_sample_aspect_ratio(f, st, NULL);
        double sa = sar.num > 0 && sar.den > 0 ? av_q2d(sar) : 1.0;
        in->dar = in->width > 0 && in->height > 0 ? (double)in->width * sa / (double)in->height : 0;
    }
    in->raw = f->iformat && !strcmp(f->iformat->name, "h264");
    in->audio = calloc(f->nb_streams + 1, sizeof *in->audio);
    in->subs = calloc(f->nb_streams + 1, sizeof *in->subs);
    p->sdec = calloc(f->nb_streams + 1, sizeof *p->sdec);
    p->subs = calloc(f->nb_streams + 1, sizeof *p->subs);
    p->sub_of = malloc((f->nb_streams + 1) * sizeof *p->sub_of);
    if (!in->audio || !in->subs || !p->sdec || !p->subs || !p->sub_of) {
        free(p->sub_of);
        p->sub_of = NULL;
        return;
    }
    for (unsigned i = 0; i < f->nb_streams; i++) {
        AVStream *st = f->streams[i];
        p->sub_of[i] = -1;
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            struct player_track *t = &in->audio[in->n_audio++];
            t->index = (int)i;
            t->playable = avcodec_find_decoder(st->codecpar->codec_id) != NULL;
            track_name(st, t->name, sizeof t->name);
        } else if (p->cfg.text_subs && is_text_sub(st)) {
            const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
            AVCodecContext *c = dec ? avcodec_alloc_context3(dec) : NULL;
            if (c && avcodec_parameters_to_context(c, st->codecpar) >= 0) {
                c->pkt_timebase = st->time_base;
                if (avcodec_open2(c, dec, NULL) < 0) avcodec_free_context(&c);
            } else {
                avcodec_free_context(&c);
            }
            struct subs *cues = c ? subs_new() : NULL;
            if (!cues) { avcodec_free_context(&c); continue; }     /* no decoder: not offered */
            unsigned k = in->n_subs++;
            in->subs[k].index = (int)i;
            in->subs[k].playable = 1;
            in->subs[k].def = (st->disposition & (AV_DISPOSITION_DEFAULT | AV_DISPOSITION_FORCED)) != 0;
            track_name(st, in->subs[k].name, sizeof in->subs[k].name);
            p->sdec[k] = c;
            p->subs[k] = cues;
            p->sub_of[i] = (int)k;
        }
    }
    p->have_info = 1;
}

static int pq_full(const struct pq *q) { return q->tail - q->head == q->max || q->bytes > q->max_bytes; }

static AVPacket *pq_pop(struct pq *q)
{
    AVPacket *pkt = q->q[q->head++ % q->max];
    q->bytes -= (size_t)pkt->size;
    return pkt;
}

static void *reader(void *arg)
{
    struct player *p = arg;
    AVDictionary *opts = NULL;
    int rc;
    p->fmt = avformat_alloc_context();
    if (!p->fmt) { fail(p, "alloc", AVERROR(ENOMEM)); return NULL; }
    p->fmt->opaque = p;
    p->fmt->interrupt_callback.callback = interrupted;
    p->fmt->interrupt_callback.opaque = p;
    p->io_open_default = p->fmt->io_open;
    p->fmt->io_open = io_open_hook;
    av_dict_set(&opts, "rw_timeout", "15000000", 0);          /* 15 s without a byte: fail */
    av_dict_set(&opts, "reconnect", "1", 0);
    /* the probe: the server said what is coming; a short look is enough (the default reads up to
     * 5 MB / 5 s -- about a second of a transcode's start on the rig). An audio stream it misses (a
     * 9.6 Mbit/s transcode's can start past it) is still played: open_audio. 4 MB / 2 s was measured
     * on the rig (docs/jellyfin.md S12): it missed the same audio and cost ~0.2 s an open */
    p->fmt->probesize = 1 << 20;
    p->fmt->max_analyze_duration = 500000;
    const char *open_url = p->url;
    const AVInputFormat *ifmt = NULL;
    if (p->cfg.hls_trim) {
        const char *t = trim_hls(p);
        if (t) {
            open_url = t;
            p->trimmed = 1;
            ifmt = av_find_input_format("hls");
            av_dict_set(&opts, "protocol_whitelist", "file,http,https,tcp,tls,crypto", 0);
        } else {
            fprintf(stderr, "player: the playlist could not be trimmed: opening it whole\n");
        }
    }
    if ((rc = avformat_open_input(&p->fmt, open_url, ifmt, &opts)) < 0) {
        av_dict_free(&opts);
        fail(p, "open", rc);
        return NULL;
    }
    av_dict_free(&opts);
    p->t_open = mono_ms();
    if ((rc = avformat_find_stream_info(p->fmt, NULL)) < 0) { fail(p, "stream info", rc); return NULL; }
    p->t_info = mono_ms();
    fill_info(p);
    p->vs = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (p->vs >= 0 && p->cfg.arm_video && p->fmt->streams[p->vs]->codecpar->codec_id != AV_CODEC_ID_H264) {
        /* (0.15) decoded here, shown as pictures -- or refused by name */
        AVStream *vst = p->fmt->streams[p->vs];
        char why[160];
        /* a rate of 0 or above 120 is unknown (a VFR file, a time base as a rate: as video()'s check) */
        double fps = (p->info.fps <= 0 || p->info.fps > 120) ? 0 : p->info.fps;
        if (vdec_allowed(vst->codecpar, codec_label(vst->codecpar->codec_id), fps, why, sizeof why) ||
            vdec_open(&p->vd, vst) < 0) {
            pthread_mutex_lock(&p->mx);
            snprintf(p->err, sizeof p->err, "%s", p->vd || why[0] ? why : "the video's decoder did not open");
            p->failed = 1;
            pthread_cond_broadcast(&p->cv);
            pthread_mutex_unlock(&p->mx);
            return NULL;
        }
        p->info.sw = 1;
    }
    if (!p->info.sw && (p->vs < 0 || p->fmt->streams[p->vs]->codecpar->codec_id != AV_CODEC_ID_H264)) {
        pthread_mutex_lock(&p->mx);
        if (p->vs < 0) snprintf(p->err, sizeof p->err, "no video");
        else snprintf(p->err, sizeof p->err, "the video is %s, not H.264",
                      codec_label(p->fmt->streams[p->vs]->codecpar->codec_id));
        p->failed = 1;
        pthread_cond_broadcast(&p->cv);
        pthread_mutex_unlock(&p->mx);
        return NULL;
    }
    /* the track asked for, else the best one a decoder was built for (a film's default track
     * may be TrueHD: R2, not built) */
    const AVCodec *best_dec = NULL;
    p->as = p->cfg.audio_stream >= 0 && p->cfg.audio_stream < (int)p->fmt->nb_streams &&
            p->fmt->streams[p->cfg.audio_stream]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO
          ? p->cfg.audio_stream
          : av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, p->vs, &best_dec, 0);
    /* av_find_best_stream passes over an audio stream with no channels or sample rate: one whose
     * first packets came after the probe. The first such stream a decoder was built for is played
     * (its decoder reads them from the stream) */
    for (unsigned i = 0; p->as < 0 && i < p->fmt->nb_streams; i++) {
        AVCodecParameters *ap = p->fmt->streams[i]->codecpar;
        if (ap->codec_type == AVMEDIA_TYPE_AUDIO && avcodec_find_decoder(ap->codec_id)) {
            fprintf(stderr, "player: the audio's parameters were not in the probe: decoding them from the stream\n");
            p->as = (int)i;
        }
    }
    if (p->as >= 0 && (rc = open_audio(p)) < 0) {
        fprintf(stderr, "player: no audio (%s)\n", av_err2str(rc));
        p->as = -1;
    }
    p->info.audio_cur = p->as;
    for (unsigned i = 0; i < p->fmt->nb_streams; i++)
        if ((int)i != p->vs && (int)i != p->as && !(p->sub_of && p->sub_of[i] >= 0))
            p->fmt->streams[i]->discard = AVDISCARD_ALL;
    /* avcC (MKV / MP4) -> Annex B with the parameter sets before each IDR */
    AVCodecParameters *vp = p->fmt->streams[p->vs]->codecpar;
    if (!p->info.sw && vp->extradata_size > 0 && vp->extradata[0] == 1) {
        const AVBitStreamFilter *f = av_bsf_get_by_name("h264_mp4toannexb");
        if (!f || av_bsf_alloc(f, &p->bsf) < 0 || avcodec_parameters_copy(p->bsf->par_in, vp) < 0) {
            fail(p, "h264_mp4toannexb", AVERROR_BSF_NOT_FOUND);
            return NULL;
        }
        p->bsf->time_base_in = p->fmt->streams[p->vs]->time_base;
        if ((rc = av_bsf_init(p->bsf)) < 0) { fail(p, "h264_mp4toannexb", rc); return NULL; }
    }
    if (p->trimmed && p->fmt->start_time != AV_NOPTS_VALUE)
        p->trim_origin_s = (double)p->fmt->start_time / AV_TIME_BASE - p->trim_origin_s;   /* now: the offset */
    if (p->cfg.seek && p->cfg.start_s > 0 && !p->trimmed) {
        int64_t ts = (int64_t)(p->cfg.start_s * AV_TIME_BASE);
        if (p->fmt->start_time != AV_NOPTS_VALUE) ts += p->fmt->start_time;
        if ((rc = av_seek_frame(p->fmt, -1, ts, AVSEEK_FLAG_BACKWARD)) < 0)
            fprintf(stderr, "player: seek to %.1f s: %s\n", p->cfg.start_s, av_err2str(rc));
    }
    p->t_seek = mono_ms();
    pthread_mutex_lock(&p->mx);
    p->opened = 1;
    pthread_cond_broadcast(&p->cv);
    pthread_mutex_unlock(&p->mx);

    for (;;) {
        AVPacket *pkt = av_packet_alloc();
        if (!pkt) { fail(p, "alloc", AVERROR(ENOMEM)); break; }
        rc = av_read_frame(p->fmt, pkt);
        if (rc < 0) {
            av_packet_free(&pkt);
            if (rc == AVERROR_EOF || avio_feof(p->fmt->pb)) {
                pthread_mutex_lock(&p->mx);
                p->eof = 1;
                pthread_cond_broadcast(&p->cv);
                pthread_mutex_unlock(&p->mx);
            } else if (!interrupted(p)) {
                fail(p, "read", rc);
            }
            break;
        }
        if (pkt->stream_index != p->vs && pkt->stream_index != p->as &&
            !(p->sub_of && p->sub_of[pkt->stream_index] >= 0)) { av_packet_free(&pkt); continue; }
        struct pq *q = pkt->stream_index == p->as ? &p->aq : &p->vq;
        pthread_mutex_lock(&p->mx);
        while (!p->abort && pq_full(q))
            pthread_cond_wait(&p->cv, &p->mx);
        if (p->abort) { pthread_mutex_unlock(&p->mx); av_packet_free(&pkt); break; }
        q->seq[q->tail % q->max] = p->seq++;
        q->q[q->tail++ % q->max] = pkt;
        q->bytes += (size_t)pkt->size;
        pthread_mutex_unlock(&p->mx);
    }
    return NULL;
}

/* ---- the loop's side ---- */

static int64_t pts90(const struct player *p, const AVPacket *pkt, int stream)
{
    int64_t t = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    if (t == AV_NOPTS_VALUE) return -1;
    t = av_rescale_q(t, p->fmt->streams[stream]->time_base, (AVRational){1, 90000});
    return t < 0 ? -1 : t;
}

/* the next packet to write: the demuxer's order, except that audio waits while it is more than
 * AUD_LEAD ahead of the newest video handed on, and before the first picture (docs/jellyfin.md S12:
 * a transcode's audio 5 s ahead filled the core's 256 records and starved the picture). The video
 * goes on meanwhile. The audio goes anyway when nothing else can come: the video queue empty and
 * the reader done, or the audio queue full (the reader waits for room in it -- an audio-only stretch). */
static AVPacket *take(struct player *p, int *eof)
{
    AVPacket *pkt = NULL;
    pthread_mutex_lock(&p->mx);
    struct pq *a = &p->aq, *v = &p->vq;
    int have_a = a->head != a->tail, have_v = v->head != v->tail;
    if (have_a) {
        int64_t t = pts90(p, a->q[a->head % a->max], p->as);
        if (t < 0) t = p->apts_next;          /* untimed (a PES's later frames): where the audio has reached */
        int ok = p->started && (t < 0 || p->vmax < 0 || t <= p->vmax + AUD_LEAD);
        if (p->started && t >= 0 && p->vmax >= 0 && t - p->vmax > p->n.audio_lead_max)
            p->n.audio_lead_max = t - p->vmax;
        if (ok && (!have_v || a->seq[a->head % a->max] < v->seq[v->head % v->max])) {
            pkt = pq_pop(a);
        } else if (!ok && !have_v && (p->eof || pq_full(a))) {
            pkt = pq_pop(a);
            if (!p->eof) p->n.audio_forced++;
        } else if (!ok && have_v && p->started) {
            p->n.audio_held++;
        }
    }
    if (!pkt && have_v) {
        pkt = pq_pop(v);
        if (pkt->stream_index == p->vs) {
            int64_t t = pts90(p, pkt, p->vs);
            if (t > p->vmax) p->vmax = t;
        }
    }
    if (pkt) pthread_cond_broadcast(&p->cv);
    *eof = p->eof && a->head == a->tail && v->head == v->tail;
    pthread_mutex_unlock(&p->mx);
    return pkt;
}

/* write the access unit in `out`; 0 written (or nothing to write), -EAGAIN no room yet */
static int flush_out(struct player *p, h264ring *r)
{
    if (!p->out) return 0;
#ifdef CLIENT_TEST
    if (client_test_write_us) {           /* nanosleep: the test counts the loop's own usleep calls */
        struct timespec ts = { 0, (long)client_test_write_us * 1000L };
        nanosleep(&ts, NULL);
    }
#endif
    int64_t t = p->out->pts;              /* already 90 kHz (set by video()) */
    h264ring_set_colour(r, p->cfg.colour);   /* (0.16) the core takes it from the stream's first access unit */
    int rc = h264ring_try_write_au(r, p->out->data, (uint32_t)p->out->size,
                                   t >= 0 ? (t & (int64_t)PTS_MASK) : -1, p->out_flags);
    if (rc == -EAGAIN) { p->n.queue_full_waits++; return -EAGAIN; }
    if (rc == -EOPNOTSUPP) {                       /* (0.10) the CAVLC rewrite refused the stream */
        snprintf(p->err, sizeof p->err, "CAVLC H.264 the rewrite cannot carry: %s", h264ring_rewrite_why(r));
        p->rewrite_refused = 1;
    } else if (rc == -EBADMSG) {                   /* a CAVLC unit that does not parse: from the next IDR */
        fprintf(stderr, "player: the CAVLC rewrite skipped an access unit: %s\n", h264ring_rewrite_why(r));
        p->skip_to_idr = 1;
        p->n.rewrite_skipped++;
    } else if (rc) {
        fprintf(stderr, "player: write_au: %s\n", strerror(-rc));
    }
    av_packet_free(&p->out);
    if (!rc) p->n.video_aus++;
    return 0;
}

static int flush_audio(struct player *p, h264ring *r)
{
    if (!p->aout_bytes) return 0;
    int rc = h264ring_try_write_audio(r, p->aout, p->aout_bytes,
                                      p->aout_pts >= 0 ? (p->aout_pts & (int64_t)PTS_MASK) : -1);
    if (rc == -EAGAIN) { p->n.queue_full_waits++; return -EAGAIN; }
    if (rc) fprintf(stderr, "player: write_audio: %s\n", strerror(-rc));
    p->n.audio_records++;
    p->n.audio_bytes += p->aout_bytes;
    p->aout_bytes = 0;
    return 0;
}

/* gathered PCM -> the pending record (only when that is empty) */
static void seal_pcm(struct player *p)
{
    if (!p->pcm_frames || p->aout_bytes) return;
    memcpy(p->aout, p->pcm, p->pcm_frames * 4u);
    p->aout_bytes = p->pcm_frames * 4u;
    p->aout_pts = p->pcm_pts;
    p->pcm_frames = 0;
}

static void audio(struct player *p, AVPacket *pkt)
{
    /* nothing before the first picture: the session opens with its IDR (and audio older than
     * it would only be dropped by the core's clock) -- by each FRAME's time, below: a packet
     * without one (a PES's later frames) is placed by the frames before it */
    if (!p->started) return;
    if (avcodec_send_packet(p->adec, pkt) < 0) return;
    AVFrame *fr = av_frame_alloc();
    while (fr && avcodec_receive_frame(p->adec, fr) == 0) {
        int64_t ft = fr->best_effort_timestamp;
        int64_t fpts = ft == AV_NOPTS_VALUE ? p->apts_next
                     : av_rescale_q(ft, p->fmt->streams[p->as]->time_base, (AVRational){1, 90000});
        p->apts_next = fpts >= 0 && fr->sample_rate > 0
                     ? fpts + av_rescale(fr->nb_samples, 90000, fr->sample_rate) : -1;
        if (fpts >= 0 && p->first_pts >= 0 && fpts < p->first_pts) { av_frame_unref(fr); continue; }
        if (swr_for(p, &fr->ch_layout, fr->format, fr->sample_rate) < 0) { av_frame_unref(fr); continue; }
        int out_max = swr_get_out_samples(p->swr, fr->nb_samples);
        if (out_max > 0 && p->pcm_frames + (unsigned)out_max > p->pcm_cap) {
            unsigned cap = p->pcm_frames + (unsigned)out_max + AUD_RECORD;
            int16_t *n = realloc(p->pcm, cap * 4u), *o = realloc(p->aout, cap * 4u);
            if (!n || !o) { free(n); free(o); p->pcm = p->aout = NULL; break; }
            p->pcm = n; p->aout = o; p->pcm_cap = cap;
        }
        uint8_t *dst = (uint8_t *)(p->pcm + p->pcm_frames * 2u);
        if (!p->pcm_frames) p->pcm_pts = fpts;
        int got = swr_convert(p->swr, &dst, out_max, (const uint8_t **)fr->extended_data, fr->nb_samples);
        if (got > 0) p->pcm_frames += (unsigned)got;
        av_frame_unref(fr);
    }
    av_frame_free(&fr);
}

/* a text subtitle packet -> its track's cues, in the item's seconds (player_position's origin:
 * the file's start_time) */
static void subtitle(struct player *p, AVPacket *pkt, unsigned k)
{
    AVSubtitle sub;
    int got = 0;
    int64_t t = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    if (t == AV_NOPTS_VALUE || avcodec_decode_subtitle2(p->sdec[k], &sub, &got, pkt) < 0 || !got) return;
    AVRational tb = p->fmt->streams[pkt->stream_index]->time_base;
    double origin = p->fmt->start_time != AV_NOPTS_VALUE ? (double)p->fmt->start_time / AV_TIME_BASE : 0;
    double a = (double)t * av_q2d(tb) - origin + sub.start_display_time / 1000.0, b;
    if (pkt->duration > 0) b = (double)(t + pkt->duration) * av_q2d(tb) - origin;
    else if (sub.end_display_time && sub.end_display_time != UINT32_MAX)
        b = (double)t * av_q2d(tb) - origin + sub.end_display_time / 1000.0;
    else b = a;                                       /* subs_add gives it a few seconds */
    for (unsigned i = 0; i < sub.num_rects; i++) {
        const AVSubtitleRect *r = sub.rects[i];
        if (r->type == SUBTITLE_ASS && r->ass) subs_add(p->subs[k], a, b, r->ass, 1);
        else if (r->type == SUBTITLE_TEXT && r->text) subs_add(p->subs[k], a, b, r->text, 0);
    }
    avsubtitle_free(&sub);
}

/* ---- (arm_video) pictures decoded here: each into a store of the core, then its PICTURE record ---- */

/* the picture's shape as the interface takes it (docs/architecture.md "Pictures from the program") */
static void sw_shape(struct player *p, const AVFrame *f, struct h264ring_picture *pic)
{
    AVStream *st = p->fmt->streams[p->vs];
    AVRational sar = av_guess_sample_aspect_ratio(p->fmt, st, (AVFrame *)f);
    AVRational r = st->avg_frame_rate.num && st->avg_frame_rate.den ? st->avg_frame_rate : st->r_frame_rate;
    double fps = r.num > 0 && r.den > 0 ? av_q2d(r) : 0;
    int tff = (f->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != 0;
    memset(pic, 0, sizeof *pic);
    pic->width = (unsigned)f->width;
    pic->height = (unsigned)f->height;
    pic->pic_struct = -1;
    if (f->flags & AV_FRAME_FLAG_INTERLACED)           /* a woven pair: each field its own refresh at 480i */
        pic->structure = tff ? H264RING_PIC_STRUCT_PAIR_TOP : H264RING_PIC_STRUCT_PAIR_BOT;
    else if (f->repeat_pict == 1)                      /* MPEG-2's repeat_first_field: three fields */
        pic->pic_struct = tff ? 5 : 6;
    else if (f->repeat_pict == 2)                      /* frame doubling / tripling (progressive sequences) */
        pic->pic_struct = 7;
    else if (f->repeat_pict == 4)
        pic->pic_struct = 8;
    if (sar.num > 0 && sar.den > 0) { pic->sar_w = (unsigned)sar.num; pic->sar_h = (unsigned)sar.den; }
    if (fps >= 1 && fps <= 120) { pic->rate_num = (unsigned)r.num; pic->rate_den = (unsigned)r.den; }
    pic->colour = vdec_colour(f);                      /* (0.16) a full-range code keeps full-range samples */
}

static int64_t frame_pts90(const struct player *p, const AVFrame *f)
{
    int64_t t = f->best_effort_timestamp;
    if (t == AV_NOPTS_VALUE) return -1;
    t = av_rescale_q(t, p->fmt->streams[p->vs]->time_base, (AVRational){1, 90000});
    return t < 0 ? -1 : t;
}

/* at most one picture a step (its copy ~5 ms of the step's 10): the next one decoded, written once
 * another is waiting behind it or the decoder is drained (the last carries END_OF_STREAM). Late
 * pictures (the clock past them) are dropped before the copy; dropping keeps on -> reference pictures
 * only for a while. Returns -1 when the stream cannot be shown (p->err says why). */
static int sw_pictures(struct player *p, h264ring *r)
{
    int done = 0;
    if (!p->vnext) {
        p->vnext = vdec_get(p->vd, &done);
        if (!p->vnext) { if (done) p->vdone = 1; return 0; }
        p->vcopied = 0;
        if (!p->started) {                             /* the stream's first picture: the session opens on it */
            p->started = 1;
            p->first_pts = frame_pts90(p, p->vnext);
            p->t_idr = mono_ms();
        }
    }
    if (p->cfg.hold && !p->released) return 0;         /* copied only after the release's flush */
    int last = 0;
    if (!vdec_ready(p->vd)) {                          /* nothing behind it: the last one, once drained */
        if (!p->vended || !vdec_drained(p->vd)) return 0;
        last = 1;
    }
    int64_t t = frame_pts90(p, p->vnext);
    struct h264ring_status st;
    if (!p->vcopied && !last && t >= 0 && h264ring_status(r, &st) == 0 &&
        (H264RING_ST(&st, LIVE) & H264RING_L_STC_RUN)) {
        int64_t late = (int64_t)((H264RING_ST(&st, STC) - (uint64_t)t) & PTS_MASK);
        if (late > 9000 && late < (int64_t)(PTS_MASK / 2)) {   /* 100 ms past its time: never shown */
            uint64_t now = mono_ms();
            p->n.pics_late++;
            if (now - p->late_ms > 1000) { p->late_ms = now; p->late_n = 0; }
            if (++p->late_n >= 5 && !p->nonref_until) {        /* behind for good: reference pictures only */
                vdec_skip_nonref(p->vd, 1);
                p->n.pics_nonref++;
            }
            if (p->late_n >= 5) p->nonref_until = now + 2000;
            av_frame_free(&p->vnext);
            return 0;
        }
    }
    if (p->nonref_until && mono_ms() > p->nonref_until) { vdec_skip_nonref(p->vd, 0); p->nonref_until = 0; }
    struct h264ring_picture pic;
    sw_shape(p, p->vnext, &pic);
    if (!p->vcopied) {
        unsigned k;
        int fmt = vdec_frame_pix(p->vnext);           /* (0.16) full range by the frame's range too */
        if (fmt < 0) {
            snprintf(p->err, sizeof p->err, "the video's pictures are %s: only 8-bit 4:2:0 and 4:2:2 are shown",
                     av_get_pix_fmt_name((enum AVPixelFormat)p->vnext->format));
            return -1;
        }
        int rc = h264ring_picture_acquire(r, &k);
        if (rc == -EAGAIN) return 0;                   /* every store still shown: the next step */
        if (rc) { fprintf(stderr, "player: picture_acquire: %s\n", strerror(-rc)); return 0; }
        const uint8_t *planes[3] = { p->vnext->data[0], p->vnext->data[1], p->vnext->data[2] };
        int strides[3] = { p->vnext->linesize[0], p->vnext->linesize[1], p->vnext->linesize[2] };
        if (h264ring_picture_copy(h264ring_picture_store(r, k), &pic, planes, strides, (unsigned)fmt)) {
            snprintf(p->err, sizeof p->err, "a %dx%d picture the core cannot show", p->vnext->width, p->vnext->height);
            return -1;
        }
        p->vk = (int)k;
        p->vcopied = 1;
    }
    int rc = h264ring_try_write_picture(r, (unsigned)p->vk, &pic, t >= 0 ? (t & (int64_t)PTS_MASK) : -1,
                                        last ? H264RING_F_END_OF_STREAM : 0u);
    if (rc == -EAGAIN) { p->n.queue_full_waits++; return 0; }   /* the store stays ours: write it next step */
    if (rc) fprintf(stderr, "player: write_picture: %s\n", strerror(-rc));
    else p->n.pictures++;
    av_frame_free(&p->vnext);
    if (last) p->vdone = 1;
    return 0;
}

/* one video packet (Annex B after the filter) -> `hold`, the previous hold -> `out` */
static int video(struct player *p, AVPacket *pkt)
{
    /* a raw stream's timestamps are the demuxer's guess at 25 frames/s: none instead, the core
     * paces it by its VUI */
    int64_t t = p->info.raw ? -1 : pts90(p, pkt, p->vs);
    if (!p->started) {
        if (p->verdict == H264C_UNKNOWN) {
            /* the rate check's frame rate: a raw stream's is the demuxer's guess, and a VFR file or a
             * remux can carry an absurd one (a time base as a rate) -- unknown then, no rate check */
            p->chk.fps = (p->info.raw || p->info.fps <= 0 || p->info.fps > 120) ? 0 : p->info.fps;
            p->verdict = h264check_au(&p->chk, pkt->data, (size_t)pkt->size);
            if (p->verdict == H264C_CAVLC && p->cfg.cavlc_ok) {    /* the write call rewrites it */
                p->verdict = H264C_OK;
                p->info.cavlc = 1;
            }
        }
        if (p->verdict != H264C_UNKNOWN && p->verdict != H264C_OK)
            return -1;
        if (!(pkt->flags & AV_PKT_FLAG_KEY) || p->verdict != H264C_OK) {
            p->n.dropped_before_idr++;
            av_packet_free(&pkt);
            return 0;
        }
        p->started = 1;
        p->first_pts = t;
        p->t_idr = mono_ms();
        if (getenv("CLIENT_TIMING"))
            fprintf(stderr, "player: timing (ms from the open): connected %llu, stream info %llu, seek %llu, "
                    "first packet %llu, first IDR %llu\n",
                    (unsigned long long)(p->t_open - p->t0), (unsigned long long)(p->t_info - p->t0),
                    (unsigned long long)(p->t_seek - p->t0), (unsigned long long)(p->t_pkt - p->t0),
                    (unsigned long long)(p->t_idr - p->t0));
    }
    if (p->skip_to_idr) {                  /* after a unit the rewrite could not parse */
        if (!(pkt->flags & AV_PKT_FLAG_KEY)) { av_packet_free(&pkt); return 0; }
        p->skip_to_idr = 0;
    }
    pkt->pts = t;                          /* 90 kHz from here on */
    if (p->hold) { p->out = p->hold; p->out_flags = 0; }
    p->hold = pkt;
    return 0;
}

enum player_state player_step(struct player *p, h264ring *r)
{
    if (p->state != PL_OPENING && p->state != PL_RUNNING && p->state != PL_READY) return p->state;
    if (p->state == PL_READY) {
        if (!p->released) return p->state;          /* held: the old picture stays up */
        p->state = PL_RUNNING;
    }
    if (p->state == PL_OPENING) {
        pthread_mutex_lock(&p->mx);
        int opened = p->opened, failed = p->failed;
        pthread_mutex_unlock(&p->mx);
        if (failed) return p->state = PL_FAILED;
        if (!opened) return p->state;
        p->state = PL_RUNNING;
    }
    uint64_t t_step = mono_ms();
    if (p->vd && sw_pictures(p, r) < 0) return p->state = PL_UNDECODABLE;   /* (arm_video) a picture */
    for (unsigned k = 0; k < STEP_PACKETS; k++) {
        if (k && mono_ms() - t_step >= STEP_BUDGET_MS) return p->state;   /* the loop's turn */
        if (p->rewrite_refused) return p->state = PL_UNDECODABLE;
        if (p->cfg.hold && !p->released && p->started) return p->state = PL_READY;
        if (flush_out(p, r) == -EAGAIN || flush_audio(p, r) == -EAGAIN) return p->state;
        if (p->pcm_frames >= AUD_RECORD) { seal_pcm(p); continue; }
        if (p->vpend) {                                /* (arm_video) the decoder's queue was full */
            if (vdec_put(p->vd, p->vpend) == -EAGAIN) return p->state;
            p->vpend = NULL;
        }
        int eof;
        AVPacket *pkt = take(p, &eof);
        if (pkt && !p->t_pkt) p->t_pkt = mono_ms();
        if (!pkt) {
            pthread_mutex_lock(&p->mx);
            int failed = p->failed;
            pthread_mutex_unlock(&p->mx);
            if (failed) return p->state = PL_FAILED;
            if (!eof) return p->state;
            /* the end: the last PCM, then the last access unit with END_OF_STREAM */
            seal_pcm(p);
            if (flush_audio(p, r) == -EAGAIN) return p->state;
            if (p->vd) {                               /* (arm_video) drain the decoder; the last picture ends it */
                if (!p->vended) { vdec_end(p->vd); p->vended = 1; }
                if (sw_pictures(p, r) < 0) return p->state = PL_UNDECODABLE;
                if (!p->vdone || p->vnext) return p->state;
            }
            if (p->hold) { p->out = p->hold; p->hold = NULL; p->out_flags = H264RING_F_END_OF_STREAM; }
            if (flush_out(p, r) == -EAGAIN) return p->state;
            return p->state = p->started ? PL_DRAINED : PL_FAILED;
        }
        if (pkt->stream_index == p->as && p->adec) {
            audio(p, pkt);
            av_packet_free(&pkt);
            continue;
        }
        if (pkt->stream_index != p->vs) {          /* a text subtitle track's (text_subs) */
            if (p->sub_of && p->sub_of[pkt->stream_index] >= 0)
                subtitle(p, pkt, (unsigned)p->sub_of[pkt->stream_index]);
            av_packet_free(&pkt);
            continue;
        }
        if (p->vd) {                                   /* (arm_video) to the decoder's thread */
            if (vdec_put(p->vd, pkt) == -EAGAIN) { p->vpend = pkt; return p->state; }
            continue;
        }
        if (p->bsf) {
            if (av_bsf_send_packet(p->bsf, pkt) < 0) { av_packet_free(&pkt); continue; }
            av_packet_free(&pkt);
            AVPacket *o = av_packet_alloc();
            while (o && av_bsf_receive_packet(p->bsf, o) == 0) {
                o->stream_index = p->vs;
                if (video(p, o) < 0) { av_packet_free(&o); return p->state = PL_UNDECODABLE; }
                o = av_packet_alloc();
            }
            av_packet_free(&o);
        } else if (video(p, pkt) < 0) {
            av_packet_free(&pkt);
            return p->state = PL_UNDECODABLE;
        }
    }
    return p->state;
}

int player_open(struct player **pp, const struct player_cfg *cfg)
{
    struct player *p = calloc(1, sizeof *p);
    if (!p) return -ENOMEM;
    p->cfg = *cfg;
    p->chk.max_mbs = cfg->max_mbs;
    p->chk.mb_rate = cfg->mb_rate;
    p->url = strdup(cfg->url);
    p->headers = cfg->headers ? strdup(cfg->headers) : NULL;
    p->cafile = cfg->cafile ? strdup(cfg->cafile) : NULL;
    p->vs = p->as = -1;
    p->first_pts = p->vmax = p->apts_next = -1;
    p->vq.max = QUEUE_PKTS; p->vq.max_bytes = QUEUE_BYTES;
    p->aq.max = AQUEUE_PKTS; p->aq.max_bytes = AQUEUE_BYTES;
    p->t0 = mono_ms();
    p->state = PL_OPENING;
    pthread_mutex_init(&p->mx, NULL);
    pthread_cond_init(&p->cv, NULL);
    if (!p->url || pthread_create(&p->thread, NULL, reader, p)) { player_close(p); return -ENOMEM; }
    p->thread_up = 1;
    *pp = p;
    return 0;
}

double player_position(const struct player *p, uint64_t stc, int stc_running)
{
    if (p->first_pts < 0 || !stc_running) return p->cfg.start_s;
    if (p->trimmed) {                      /* a trimmed transcode: its timestamps are the item's time + an offset */
        double t = (double)(stc & PTS_MASK) / 90000.0 - p->trim_origin_s;
        return t < 0 ? 0 : t;
    }
    if (p->cfg.seek) {                     /* direct play: the file's timestamps are the item's time */
        double origin = p->fmt && p->fmt->start_time != AV_NOPTS_VALUE ? (double)p->fmt->start_time / AV_TIME_BASE : 0;
        return (double)(stc & PTS_MASK) / 90000.0 - origin;
    }
    uint64_t d = (stc - (uint64_t)p->first_pts) & PTS_MASK;
    if (d > PTS_MASK / 2) d = 0;           /* the clock before the first picture */
    return p->cfg.start_s + (double)d / 90000.0;
}

void player_release(struct player *p) { p->released = 1; }

const struct player_info *player_info(const struct player *p)
{
    struct player *q = (struct player *)p;            /* the lock only: the reader's writes before `opened` / `failed` */
    pthread_mutex_lock(&q->mx);
    int ok = (p->opened || p->failed) && p->have_info;
    pthread_mutex_unlock(&q->mx);
    return ok ? &p->info : NULL;
}

struct subs *player_subs(const struct player *p, unsigned k)
{
    return player_info(p) && k < p->info.n_subs ? p->subs[k] : NULL;
}
enum h264check player_check(const struct player *p) { return p->verdict; }
const char *player_error(const struct player *p) { return p->err; }
void player_counts(const struct player *p, struct player_counts *c) { *c = p->n; }

void player_close(struct player *p)
{
    if (!p) return;
    pthread_mutex_lock(&p->mx);
    __atomic_store_n(&p->abort, 1, __ATOMIC_RELAXED);
    pthread_cond_broadcast(&p->cv);
    pthread_mutex_unlock(&p->mx);
    if (p->thread_up) pthread_join(p->thread, NULL);
    if (p->n.audio_lead_max > AUD_LEAD || p->n.audio_forced)
        fprintf(stderr, "player: the stream's audio ran up to %.1f s ahead of its video: held back (%llu waits), "
                "%llu packets let through early\n", (double)p->n.audio_lead_max / 90000.0,
                (unsigned long long)p->n.audio_held, (unsigned long long)p->n.audio_forced);
    while (p->vq.head != p->vq.tail) { AVPacket *k = pq_pop(&p->vq); av_packet_free(&k); }
    while (p->aq.head != p->aq.tail) { AVPacket *k = pq_pop(&p->aq); av_packet_free(&k); }
    av_packet_free(&p->hold);
    av_packet_free(&p->out);
    vdec_close(p->vd);                     /* (arm_video) joins its thread */
    av_packet_free(&p->vpend);
    av_frame_free(&p->vnext);
    av_bsf_free(&p->bsf);
    avcodec_free_context(&p->adec);
    swr_free(&p->swr);
    av_channel_layout_uninit(&p->swr_in);
    for (unsigned k = 0; k < p->info.n_subs; k++) {
        if (p->sdec) avcodec_free_context(&p->sdec[k]);
        if (p->subs) subs_free(p->subs[k]);
    }
    free(p->sdec); free(p->subs); free(p->sub_of);
    free(p->info.audio); free(p->info.subs);
    avformat_close_input(&p->fmt);
    if (p->trim_path[0]) unlink(p->trim_path);
    pthread_mutex_destroy(&p->mx);
    pthread_cond_destroy(&p->cv);
    free(p->pcm); free(p->aout);
    free(p->url); free(p->headers); free(p->cafile);
    free(p);
}
