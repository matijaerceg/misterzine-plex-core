/* vdec -- video the core does not decode, decoded on the ARM (docs/player.md "Other codecs";
 * docs/architecture.md "Pictures from the program", interface 0.15). libavcodec runs on a thread of
 * its own between the player's packet queue and its loop; the loop copies each picture into one of
 * the core's stores and sends its PICTURE record (the library is the loop's alone). The codecs and
 * the sizes are the ones measured to fit one A9 core with the store copy (docs/experiments.md):
 * MPEG-1/2, MPEG-4 Part 2, MS-MPEG4 (DivX 3), WMV7/8, Theora, MJPEG, H.263 -- at SD (720 x 576 at
 * most), 30 frames a second at most. */
#ifndef CLIENT_VDEC_H
#define CLIENT_VDEC_H

#include <stdint.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/pixdesc.h>

struct vdec;

/* 0: this stream is decoded here; else why not, as words, in `why` ("the video is HEVC (H.265)",
 * "MPEG-2 1280x720 is larger than SD", "MPEG-2 at 59.94 frames/s is too fast"). fps 0: unknown */
int  vdec_allowed(const AVCodecParameters *par, const char *label, double fps, char *why, size_t n);
int  vdec_open(struct vdec **vp, const AVStream *st);
/* a packet for the decoder: 0 taken (vdec owns it now), -EAGAIN its queue is full (keep it) */
int  vdec_put(struct vdec *v, AVPacket *pkt);
/* no more packets: the decoder is drained (idempotent) */
void vdec_end(struct vdec *v);
/* the next picture, in presentation order (the caller frees it), or NULL; *done once drained and
 * nothing is left */
AVFrame *vdec_get(struct vdec *v, int *done);
/* pictures decoded and waiting */
unsigned vdec_ready(struct vdec *v);
/* drained (after vdec_end) with nothing waiting: no picture will come */
int  vdec_drained(struct vdec *v);
/* falling behind: decode reference pictures only (AVDISCARD_NONREF) until switched off */
void vdec_skip_nonref(struct vdec *v, int on);
/* the store copy's source format for a frame's (H264RING_PIX_*), -1 one it does not take */
int  vdec_pix(int av_pix_fmt);
/* (0.16, docs/colour.md) a decoded picture's source format for h264ring_picture_copy -- full range when
 * the frame says so (yuv420p with color_range JPEG is full-range samples too) -- and its colour code: the
 * frame's colorspace (BT.709 / 601 / 2020) and range; untagged full range is JPEG's BT.601; untagged
 * limited 0 (auto: the core's size rule). -1: a format the core cannot show. */
struct AVFrame;
int  vdec_frame_pix(const struct AVFrame *f);
unsigned vdec_colour(const struct AVFrame *f);
void vdec_close(struct vdec *v);

#endif
