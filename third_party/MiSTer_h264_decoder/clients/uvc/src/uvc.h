/* uvc -- a USB Video Class camera or capture dongle read through libusb (usbfs), for a kernel with no
 * V4L2 / uvcvideo (the MiSTer's: docs/uvc.md U1). One streaming interface, MJPEG or uncompressed
 * YUY2, isochronous or bulk; the payloads assembled into whole frames on libusb's event thread and
 * handed to one consumer through three buffers (the newest complete frame wins: a camera, not a
 * file -- a frame the consumer did not take in time is replaced, and counted).
 * Every way a frame can be lost or damaged is counted (struct uvc_stats): a frames-received count
 * alone cannot see a torn picture. */
#ifndef CLIENT_UVC_H
#define CLIENT_UVC_H

#include <stddef.h>
#include <stdint.h>

#define UVC_FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)
#define UVC_MJPG UVC_FOURCC('M', 'J', 'P', 'G')
#define UVC_YUY2 UVC_FOURCC('Y', 'U', 'Y', '2')
#define UVC_H264 UVC_FOURCC('H', '2', '6', '4')   /* frame-based H.264: listed, not streamed (U5) */

#define UVC_MAX_INTERVALS 16

/* one frame size of one format, as the device describes it */
struct uvc_mode {
    uint32_t fourcc;                     /* UVC_MJPG, UVC_YUY2, UVC_H264, or another uncompressed GUID's first 4 bytes */
    uint8_t  vs_if;                      /* the streaming interface it belongs to */
    uint8_t  fmt_idx, frame_idx;         /* bFormatIndex, bFrameIndex */
    uint16_t width, height;
    uint32_t max_frame;                  /* dwMaxVideoFrameBufferSize (0: not given -- frame-based) */
    uint32_t def_interval;               /* dwDefaultFrameInterval, 100 ns units */
    unsigned n_int;                      /* discrete intervals, or 0 (continuous: min / max / step below) */
    uint32_t intervals[UVC_MAX_INTERVALS];
    uint32_t int_min, int_max, int_step;
};

struct uvc_stats {
    uint64_t transfers;                  /* transfers completed */
    uint64_t packets, packets_empty;     /* iso packets (bulk: transfers) seen / carrying no payload data */
    uint64_t packet_errors;              /* iso packet status or transfer status not COMPLETED */
    uint64_t bytes;                      /* payload bytes (headers excluded) */
    uint64_t bad_headers;                /* a payload header whose length is impossible */
    uint64_t frames;                     /* complete frames handed to the consumer's buffer */
    uint64_t frames_taken;               /* ... and taken by it */
    uint64_t frames_replaced;            /* complete, never taken: a newer one arrived first */
    uint64_t frames_bad;                 /* dropped whole, by the first reason below */
    uint64_t bad_err_bit;                /*   the device's own error bit (BFH ERR) */
    uint64_t bad_packet;                 /*   a packet error inside the frame */
    uint64_t bad_overflow;               /*   longer than dwMaxVideoFrameBufferSize */
    uint64_t bad_shape;                  /*   MJPEG without SOI ... EOI, or YUY2 not width x height x 2 */
    uint64_t fid_no_eof;                 /* a frame ended by the FID toggling, not by EOF (accepted if whole) */
    uint64_t stray_payloads;             /* data after a frame's EOF, before the FID toggled (dropped) */
    uint64_t resubmit_errors;            /* a transfer that could not be resubmitted (the stream stalls) */
};

struct uvc_dev;

/* the first device with a video streaming interface (vid < 0), or vid:pid. 0, or -ENODEV, -EACCES
 * (no write access to /dev/bus/usb: run as root), -EIO */
int  uvc_open(struct uvc_dev **dp, int vid, int pid);
/* the modes it offers (owned by the device) */
const struct uvc_mode *uvc_modes(const struct uvc_dev *d, unsigned *n);
/* the device's name, "vvvv:pppp Product" */
const char *uvc_name(const struct uvc_dev *d);
/* the mode that best matches: fourcc first, then the exact size, else the largest no larger than
 * width x height (any size if none is); NULL if the fourcc is not offered */
const struct uvc_mode *uvc_pick(const struct uvc_dev *d, uint32_t fourcc, unsigned width, unsigned height);
/* the interval it offers nearest to want (100 ns units; 0: the default) */
uint32_t uvc_pick_interval(const struct uvc_mode *m, uint32_t want);
/* whether a mode can stream through the MiSTer's USB host (docs/uvc.md U2b, measured on .201: DWC2
 * carried 6.0 MB/s of isochronous video clean, lost a packet at 6.1 and most frames at 9; light MJPEG
 * streamed clean on every alternate setting, three 1,020-byte packets a microframe included -- the
 * limit is the data, not the setting). Uncompressed: its rate (width x height x 2 x frames a second) at
 * most UVC_MAX_RAW_BPS. MJPEG: 1 (a few hundred kB/s to 2-3 MB/s; its descriptors declare the
 * uncompressed rate, Logitech's do, so they cannot be used). */
#define UVC_MAX_RAW_BPS 6000000u
int  uvc_mode_fits(const struct uvc_mode *m, uint32_t interval);
/* measuring only: stream on alternate setting alt whatever the payload committed (0: chosen as usual) */
void uvc_force_alt(struct uvc_dev *d, int alt);
/* keep the frame rate constant: auto-exposure may not lengthen the exposure past the frame interval
 * (the camera terminal's AE priority control off; a webcam in a dim room otherwise drops to ~12 frames/s,
 * docs/uvc.md U2). 0, -EOPNOTSUPP (no such control), -errno */
int  uvc_fixed_rate(struct uvc_dev *d);
/* negotiate (PROBE / COMMIT), select the alternate setting the committed payload size needs (the
 * smallest that carries it -- USB reserves a setting's whole bandwidth on the bus, so a larger one only
 * takes room from other devices; every setting streams (U2b) -- the largest if it commits none), start the transfers and
 * the event thread. 0, or -errno. *committed gets the interval the device committed (it may differ
 * from the one asked), info a line describing what was negotiated (either may be NULL). */
int  uvc_start(struct uvc_dev *d, const struct uvc_mode *m, uint32_t interval, uint32_t *committed, char *info,
               size_t n);
/* the newest complete frame not yet taken: 0 and *data / *len (valid until the next uvc_take or
 * uvc_stop), or -EAGAIN after timeout_ms with none, -EIO once the stream has failed */
int  uvc_take(struct uvc_dev *d, const uint8_t **data, size_t *len, unsigned timeout_ms);
void uvc_get_stats(struct uvc_dev *d, struct uvc_stats *s);
/* CPU seconds the event thread used (valid after uvc_stop) */
double uvc_thread_cpu(const struct uvc_dev *d);
void uvc_stop(struct uvc_dev *d);
void uvc_close(struct uvc_dev *d);

/* (pure, for the host test) one payload into the assembler; exposed so a recorded payload stream
 * can be replayed without a device */
struct uvc_asm;
struct uvc_asm *uvc_asm_new(uint32_t fourcc, unsigned width, unsigned height, size_t max_frame);
/* returns 1 when a frame completed (uvc_asm_frame gives it), else 0; status != 0: a packet error */
int  uvc_asm_payload(struct uvc_asm *a, const uint8_t *p, size_t len, int status, struct uvc_stats *s);
const uint8_t *uvc_asm_frame(struct uvc_asm *a, size_t *len);
void uvc_asm_free(struct uvc_asm *a);

#endif
