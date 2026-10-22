/* vdec -- video decoded on the ARM (vdec.h). */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE                        /* syscall(SYS_gettid) */
#endif
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "h264ring.h"
#include "vdec.h"

#define PKTS    16                         /* packets queued for the decoder */
#define FRAMES  4                          /* pictures decoded ahead of the loop */
#define SD_W    720                        /* the ARM's budget (docs/experiments.md "Writing a picture
                                              into the stores": the copy is ~5.3 ms of CPU at 720x480, */
#define SD_H    576                        /*  14 ms at 720p -- decided 2026-10-05: SD only) */
#define MAX_FPS 30.5                       /* 30 frames a second (29.97, 30), with rounding */
#define NICE    4                          /* the decode thread below the loop: the pad and the copy first */

struct vdec {
    AVCodecContext *dec;
    pthread_t thread;
    int up;
    pthread_mutex_t mx;
    pthread_cond_t cv;
    AVPacket *pq[PKTS];
    unsigned ph, pt;                       /* pop at ph, push at pt */
    AVFrame *fq[FRAMES];
    unsigned fh, ft;
    int end, drained, abort, nonref;
};

/* the codecs decoded here: the measured-comfortable set (docs/experiments.md) */
static int codec_ok(enum AVCodecID id)
{
    switch (id) {
    case AV_CODEC_ID_MPEG1VIDEO: case AV_CODEC_ID_MPEG2VIDEO: case AV_CODEC_ID_MPEG4:
    case AV_CODEC_ID_MSMPEG4V1: case AV_CODEC_ID_MSMPEG4V2: case AV_CODEC_ID_MSMPEG4V3:
    case AV_CODEC_ID_WMV1: case AV_CODEC_ID_WMV2: case AV_CODEC_ID_THEORA: case AV_CODEC_ID_MJPEG:
    case AV_CODEC_ID_H263: case AV_CODEC_ID_H263P:
        return 1;
    default:
        return 0;
    }
}

int vdec_allowed(const AVCodecParameters *par, const char *label, double fps, char *why, size_t n)
{
    if (!codec_ok(par->codec_id) || !avcodec_find_decoder(par->codec_id)) {
        snprintf(why, n, "the video is %s: the MiSTer cannot decode it", label);
        return -1;
    }
    if (par->width > SD_W || par->height > SD_H) {
        snprintf(why, n, "%s %dx%d is larger than SD (720x576): too much for the ARM", label, par->width, par->height);
        return -1;
    }
    if (fps > MAX_FPS) {
        snprintf(why, n, "%s at %.2f frames/s is too fast for the ARM (30 at most)", label, fps);
        return -1;
    }
    if (par->format != AV_PIX_FMT_NONE && vdec_pix(par->format) < 0) {
        snprintf(why, n, "%s in %s: only 8-bit 4:2:0 and 4:2:2 are shown", label,
                 av_get_pix_fmt_name((enum AVPixelFormat)par->format));
        return -1;
    }
    return 0;
}

int vdec_pix(int f)
{
    switch (f) {
    case AV_PIX_FMT_YUV420P:  return H264RING_PIX_YUV420P;
    case AV_PIX_FMT_YUVJ420P: return H264RING_PIX_YUVJ420P;
    case AV_PIX_FMT_YUV422P:  return H264RING_PIX_YUV422P;
    case AV_PIX_FMT_YUVJ422P: return H264RING_PIX_YUVJ422P;
    default:                  return -1;
    }
}

int vdec_frame_pix(const AVFrame *f)
{
    int fmt = vdec_pix(f->format);
    if (fmt == H264RING_PIX_YUV420P && f->color_range == AVCOL_RANGE_JPEG) return H264RING_PIX_YUVJ420P;
    if (fmt == H264RING_PIX_YUV422P && f->color_range == AVCOL_RANGE_JPEG) return H264RING_PIX_YUVJ422P;
    return fmt;
}

unsigned vdec_colour(const AVFrame *f)
{
    int fmt = vdec_frame_pix(f);
    unsigned full = fmt == H264RING_PIX_YUVJ420P || fmt == H264RING_PIX_YUVJ422P;
    switch (f->colorspace) {
    case AVCOL_SPC_BT709: case AVCOL_SPC_SMPTE240M:                      return H264RING_COLOUR_709 + full;
    case AVCOL_SPC_BT470BG: case AVCOL_SPC_SMPTE170M: case AVCOL_SPC_FCC: return H264RING_COLOUR_601 + full;
    case AVCOL_SPC_BT2020_NCL:                                            return H264RING_COLOUR_2020 + full;
    default: return full ? H264RING_COLOUR_601_FULL : H264RING_COLOUR_AUTO;   /* JFIF's BT.601; else by size */
    }
}

/* ---- the decode thread: packets in, pictures out, both queues bounded ---- */
static int push_frame(struct vdec *v, AVFrame *fr)
{
    pthread_mutex_lock(&v->mx);
    while (!v->abort && v->ft - v->fh == FRAMES)
        pthread_cond_wait(&v->cv, &v->mx);
    if (v->abort) { pthread_mutex_unlock(&v->mx); return -1; }
    v->fq[v->ft++ % FRAMES] = fr;
    pthread_mutex_unlock(&v->mx);
    return 0;
}

static int receive(struct vdec *v)
{
    for (;;) {
        AVFrame *fr = av_frame_alloc();
        if (!fr) return -1;
        int rc = avcodec_receive_frame(v->dec, fr);
        if (rc < 0) { av_frame_free(&fr); return rc == AVERROR_EOF ? 1 : 0; }
        if (push_frame(v, fr)) { av_frame_free(&fr); return -1; }
    }
}

static void *run(void *arg)
{
    struct vdec *v = arg;
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), NICE);   /* this thread only (Linux) */
    for (;;) {
        AVPacket *pkt = NULL;
        int end;
        pthread_mutex_lock(&v->mx);
        while (!v->abort && v->ph == v->pt && !v->end)
            pthread_cond_wait(&v->cv, &v->mx);
        if (v->abort) { pthread_mutex_unlock(&v->mx); break; }
        if (v->ph != v->pt) { pkt = v->pq[v->ph++ % PKTS]; pthread_cond_broadcast(&v->cv); }
        end = v->end && !pkt;
        v->dec->skip_frame = v->nonref ? AVDISCARD_NONREF : AVDISCARD_DEFAULT;
        pthread_mutex_unlock(&v->mx);
        if (pkt) {
            int rc = avcodec_send_packet(v->dec, pkt);
            av_packet_free(&pkt);
            if (rc < 0 && rc != AVERROR(EAGAIN)) continue;     /* a damaged packet: the decoder resyncs */
            if (receive(v) < 0) break;
        } else if (end) {
            avcodec_send_packet(v->dec, NULL);                   /* drain the reordered pictures */
            receive(v);
            pthread_mutex_lock(&v->mx);
            v->drained = 1;
            pthread_cond_broadcast(&v->cv);
            pthread_mutex_unlock(&v->mx);
            break;
        }
    }
    return NULL;
}

int vdec_open(struct vdec **vp, const AVStream *st)
{
    const AVCodec *c = avcodec_find_decoder(st->codecpar->codec_id);
    struct vdec *v;
    *vp = NULL;
    if (!c || !(v = calloc(1, sizeof *v))) return AVERROR(ENOMEM);
    if (!(v->dec = avcodec_alloc_context3(c)) || avcodec_parameters_to_context(v->dec, st->codecpar) < 0) {
        avcodec_free_context(&v->dec);
        free(v);
        return AVERROR(ENOMEM);
    }
    v->dec->pkt_timebase = st->time_base;
    v->dec->thread_count = 1;              /* one core: Main holds the other (threads add only overhead) */
    v->dec->apply_cropping = 1;
    if (avcodec_open2(v->dec, c, NULL) < 0) {
        avcodec_free_context(&v->dec);
        free(v);
        return AVERROR_DECODER_NOT_FOUND;
    }
    pthread_mutex_init(&v->mx, NULL);
    pthread_cond_init(&v->cv, NULL);
    if (pthread_create(&v->thread, NULL, run, v)) { vdec_close(v); return AVERROR(ENOMEM); }
    v->up = 1;
    *vp = v;
    return 0;
}

int vdec_put(struct vdec *v, AVPacket *pkt)
{
    pthread_mutex_lock(&v->mx);
    if (v->pt - v->ph == PKTS) { pthread_mutex_unlock(&v->mx); return -EAGAIN; }
    v->pq[v->pt++ % PKTS] = pkt;
    pthread_cond_broadcast(&v->cv);
    pthread_mutex_unlock(&v->mx);
    return 0;
}

void vdec_end(struct vdec *v)
{
    pthread_mutex_lock(&v->mx);
    v->end = 1;
    pthread_cond_broadcast(&v->cv);
    pthread_mutex_unlock(&v->mx);
}

AVFrame *vdec_get(struct vdec *v, int *done)
{
    AVFrame *fr = NULL;
    pthread_mutex_lock(&v->mx);
    if (v->fh != v->ft) { fr = v->fq[v->fh++ % FRAMES]; pthread_cond_broadcast(&v->cv); }
    *done = v->drained && v->fh == v->ft;
    pthread_mutex_unlock(&v->mx);
    return fr;
}

unsigned vdec_ready(struct vdec *v)
{
    pthread_mutex_lock(&v->mx);
    unsigned n = v->ft - v->fh;
    pthread_mutex_unlock(&v->mx);
    return n;
}

int vdec_drained(struct vdec *v)
{
    pthread_mutex_lock(&v->mx);
    int d = v->drained && v->fh == v->ft;
    pthread_mutex_unlock(&v->mx);
    return d;
}

void vdec_skip_nonref(struct vdec *v, int on)
{
    pthread_mutex_lock(&v->mx);
    v->nonref = on;
    pthread_mutex_unlock(&v->mx);
}

void vdec_close(struct vdec *v)
{
    if (!v) return;
    pthread_mutex_lock(&v->mx);
    v->abort = 1;
    pthread_cond_broadcast(&v->cv);
    pthread_mutex_unlock(&v->mx);
    if (v->up) pthread_join(v->thread, NULL);
    while (v->ph != v->pt) av_packet_free(&v->pq[v->ph++ % PKTS]);
    while (v->fh != v->ft) av_frame_free(&v->fq[v->fh++ % FRAMES]);
    avcodec_free_context(&v->dec);
    pthread_mutex_destroy(&v->mx);
    pthread_cond_destroy(&v->cv);
    free(v);
}
