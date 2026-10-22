/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/include/h264ring.h -- the client library of the MiSTer H264 core's HPS interface.
 *
 * A program on the MiSTer's ARM feeds the core H.264 access units and PCM audio through a
 * ring of records in DDR3 and reads the core's status block; the layout (h264ring_layout.h)
 * is generated from tools/ring_layout.py, the design is docs/architecture.md "The HPS
 * interface, v0.1" (and "Audio (Phase 4)") and the user-facing description the manual's
 * integrating/ pages. Interface version 1.0, FROZEN: within 1.x nothing moves or changes its meaning,
 * a minor version only adds, and h264ring_attach accepts a core of the same major and a minor at least
 * this header's (a program built for 1.0 runs on a 1.x core). This library keeps common playback attachable to 1.1;
 * newer calls check their own minimum version. The history below 1.0 (0.6: the input region; 0.7:
 * word 27's disp_lone; 0.8: the OSD's actions, event type 3; 0.9: the overlay plane; 0.10-0.12:
 * the raster, the capabilities, the HD raster; 0.13: the pads' rumble; 0.14: Video Output resolved;
 * 0.15: pictures from the program -- the PICTURE record, word 84; 0.16: the colour -- header word 1's
 * code, h264ring_set_colour(), struct h264ring_picture's colour, words 80 / 86; 0.17: word 30's fit_valid --
 * the fit's fields 0 while no picture is shown; 1.0: the 0.17 layout, frozen; 1.1: queued audio clock guarantee;
 * 1.2: calibrated playback geometry (word 39, clip viewport word 88)).
 *
 * The protocol is written once, over a backend: /dev/mem on the MiSTer
 * (h264ring_open_devmem), or a caller's memory (h264ring_attach: the host tests, the
 * Verilator cosim). Typical use:
 *
 *     h264ring *r;
 *     if (h264ring_launch_core(NULL, 5000) || h264ring_open_devmem(&r, 0) ||
 *         h264ring_start_session(r, 2000)) { ... }
 *     for each access unit:  h264ring_write_au(r, au, len, pts, flags, 1000);
 *     ...                    (the last one with H264RING_F_END_OF_STREAM)
 *     h264ring_close(r);
 *
 * Every call returns 0 or a negative errno (-EAGAIN: the ring is full, retry; -ETIMEDOUT;
 * -EPROTO: the core refused the stream -- read the status block's error; -ENODEV: no live
 * core; -EPROTONOSUPPORT: a core of another major version, or an older minor than this header's).

 *
 * Not thread-safe: the ring has one writer, and a handle's session state is unlocked.
 * Serialize every call on a handle (a program writing video and audio from two threads holds
 * one mutex around each call, and waits out a full ring with the try_ calls outside it).
 * (0.6) h264ring_input and h264ring_input_events only read the control block (no session
 * state): an input thread may call them beside the writer without the mutex. (0.13) So may
 * h264ring_rumble and h264ring_rumble_keepalive (they touch only the rumble's words and state),
 * from ONE thread, once the first session has started and until h264ring_close.
 */
#ifndef H264RING_H
#define H264RING_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include "h264ring_layout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define H264RING_LIB_VERSION H264RING_VERSION   /* the library's version is the interface's */
#define H264RING_MIN_VERSION 0x101u             /* ordinary 1.1 API remains attachable; 1.2 calls gate themselves */

/* (1.0) a core of interface version `core` serves a program built against version `lib` (each major
 * << 8 | minor, word 1's low 16 bits): the same major, and the core's minor at least the program's. A
 * minor only adds (fields in bits that read 0), so a newer core serves an older program; an older core
 * may lack a field the program reads. h264ring_attach applies it with H264RING_VERSION; below 1.0 the
 * version was checked exactly. */
static inline int h264ring_version_ok(uint32_t core, uint32_t lib)
{
    return ((core >> 8) & 0xFFu) == ((lib >> 8) & 0xFFu) && (core & 0xFFu) >= (lib & 0xFFu);
}

/* where the words live and how to wait: a backend */
struct h264ring_backend {
    volatile uint64_t *ctrl;          /* the control block (H264RING_OVL_WORD + 8 words at least: 0.9) */
    volatile uint64_t *ring;          /* the ring (ring_size bytes) */
    uint32_t ring_size;               /* must equal the control block's (checked) */
    void (*barrier)(void *user);      /* order the payload's stores before the index's (NULL: a full barrier) */
    void (*sleep_us)(void *user, unsigned us);   /* wait (NULL: usleep); the cosim advances simulated time */
    uint64_t (*now_us)(void *user);   /* a monotonic clock for timeouts (NULL: CLOCK_MONOTONIC) */
    void *user;
    volatile uint64_t *stores;        /* (0.15) the DPB's stores, H264RING_DPB_STORES x H264RING_DPB_STORE
                                         bytes (NULL: no pictures from this handle). Last: a backend
                                         initialised by position keeps working */
};

typedef struct h264ring h264ring;

/* the core's status block, a consistent copy (the seqlock: seq_tail, the words, seq_head):
 * words 0-87 by their number -- the core's 0-31, (0.5) 40-47 and (0.10) 80-87; the others
 * (32-39 the program's, 48-79 the input region and the overlay's descriptor) read 0 here */
#define H264RING_STATUS_WORDS (H264RING_CORE3_WORD + H264RING_CORE3_WORDS)
struct h264ring_status {
    uint64_t w[H264RING_STATUS_WORDS];
};

/* ---- attaching ---- */
int  h264ring_attach(h264ring **r, const struct h264ring_backend *be);   /* checks magic, version (1.0: same major, minor >=), geometry */
int  h264ring_open_devmem(h264ring **r, unsigned flags);                 /* map /dev/mem, check, take the lock */
#define H264RING_OPEN_NOLOCK 1u        /* a reader (h264stat): no session, no lock */
#define H264RING_OPEN_PICTURES 2u      /* (0.15) also map the DPB's stores (40 MiB): pictures from the program */
void h264ring_close(h264ring *r);

/* ---- the core ---- */
/* load the core if /tmp/CORENAME is not H264 (an MGL through /dev/MiSTer_cmd), then wait up to
 * timeout_ms for its status block to be alive. rbf: the MGL's <rbf>, NULL for "_Other/H264". */
int  h264ring_launch_core(const char *rbf, unsigned timeout_ms);
/* the same for an app's own build of the core, whose CONF_STR names it core_name (what
 * /tmp/CORENAME reads once it is loaded; MiSTer writes the core's name there, not the rbf
 * file's): loaded when CORENAME is H264 or core_name. NULL core_name: H264 only. */
int  h264ring_launch_core_as(const char *rbf, const char *core_name, unsigned timeout_ms);
/* the heartbeat advances (the core is loaded and running now, not a previous load's words) */
int  h264ring_alive(h264ring *r, unsigned timeout_ms);

/* ---- the session ---- */
/* a new nonce, acknowledged by the core; the session starts at the core's read index. Stops
 * a session the core was running (another program's, or this one's after an OSD Reset). */
int  h264ring_start_session(h264ring *r, unsigned timeout_ms);
/* SEEK / SWITCH NOW: drop every record written and not yet read by the core, and reset the
 * stream (the decoder, the pictures waiting, the display: black until the next picture).
 * Then write from an IDR access unit with its SPS / PPS; no DISCONTINUITY flag is needed.
 * (A DISCONTINUITY flag alone takes effect in order: only after everything queued ahead of
 * it has been decoded and shown -- seconds, with a full ring.) Costs one acknowledgement
 * from the core: ~20-40 ms. */
int  h264ring_flush(h264ring *r, unsigned timeout_ms);
/* the core still runs this program's session (an OSD Reset drops it: start a new one) */
int  h264ring_session_ok(h264ring *r);

/* ---- records ---- */
/* one complete access unit (Annex-B), with its PTS (90 kHz) when pts >= 0. flags: any of
 * H264RING_F_DISCONTINUITY, _END_OF_STREAM, _LOW_LATENCY, _GRAPHICS (0.4: the stream is
 * rendered graphics -- a game stream, a desktop; the core's Anti-Twitter Auto follows it; set
 * it on every access unit of such a stream) (PTS_VALID is set from pts). After
 * an END_OF_STREAM the next access unit gets DISCONTINUITY automatically. (0.10) A CAVLC
 * access unit is rewritten into CABAC before it is queued; -EOPNOTSUPP / -EBADMSG when it
 * cannot be (h264ring_cavlc.h "In the write call"). */
int  h264ring_try_write_au(h264ring *r, const void *au, uint32_t len, int64_t pts, unsigned flags);
int  h264ring_write_au(h264ring *r, const void *au, uint32_t len, int64_t pts, unsigned flags,
                       unsigned timeout_ms);
/* (0.5) PCM: whole frames of 48 kHz, 16-bit signed little-endian, stereo interleaved (len a
 * multiple of 4, not 0: -EINVAL otherwise), pts (90 kHz) its first frame's time or -1 (the
 * frames follow the previous record's). Decode, resample to 48 kHz and downmix to stereo
 * first. Write audio and video in the order you have them; the core holds at most
 * H264RING_AUD_MAX_RECORDS records not yet played (then the ring waits), so send records of
 * 5 ms or more. The core plays paced against the video's clock, or, when the stream's
 * access units carry LOW_LATENCY, as the audio arrives (docs: the manual's integrating/). */
int  h264ring_try_write_audio(h264ring *r, const void *pcm, uint32_t len, int64_t pts);
int  h264ring_write_audio(h264ring *r, const void *pcm, uint32_t len, int64_t pts, unsigned timeout_ms);
/* any record type ((0.15) a PICTURE's payload is its 32-byte descriptor: h264ring_try_write_picture
 * builds it) */
int  h264ring_try_write(h264ring *r, unsigned type, unsigned flags, int64_t pts,
                        const void *payload, uint32_t len);
/* (0.16, docs/architecture.md "The colour") the colour code every later VIDEO_AU carries: 0 auto (the
 * stream's own VUI tags, else BT.601 for SD and BT.709 for >= 1,280 wide or > 576 high), or
 * H264RING_COLOUR_* to override the stream's tags. The core takes it from a stream's FIRST access unit:
 * set it before a stream starts (a session start, a flush, a DISCONTINUITY). 0, or -EINVAL (code > 6). */
int  h264ring_set_colour(h264ring *r, unsigned code);

/* ---- (0.15) pictures from the program (docs/architecture.md "Pictures from the program"; the
 * manual's integrating/pictures.md) ----
 * A program that decodes video itself (a codec the core does not decode) writes each picture into
 * one of the core's picture stores and sends a PICTURE record: the core shows it as it shows a
 * decoded picture -- fitted to its raster, deinterlaced, anti-twittered, paced against the STC
 * with the audio. A stream (from a session start, a flush or a DISCONTINUITY) is pictures or
 * access units, never both; the stores are the program's only in a picture stream, so the library
 * refuses picture calls (-EBUSY) until a flush or a session start has followed the last access
 * unit. Open with H264RING_OPEN_PICTURES. Per picture, on the writer's thread:
 *     h264ring_picture_acquire(r, &k)           a free store (-EAGAIN: none yet, try next step)
 *     h264ring_picture_copy(h264ring_picture_store(r, k), &pic, planes, strides, fmt)
 *     h264ring_try_write_picture(r, k, &pic, pts, flags)
 * The copy goes through the strongly-ordered mapping: ~97 MB/s on the MiSTer, a 720x480 picture
 * ~5.3 ms of CPU (docs/experiments.md); a full-range 4:2:2 640x480 one ~8 ms, its conversion included
 * (NEON: docs/uvc.md U2a). */
struct h264ring_picture {
    unsigned width, height;            /* the picture shown, pixels: the coded size is rounded up to
                                          macroblocks (a pair: to 32 lines), the rest cropped */
    unsigned structure;                /* H264RING_PIC_STRUCT_FRAME, or a woven field pair:
                                          H264RING_PIC_STRUCT_PAIR_TOP (top field first) / _PAIR_BOT */
    int      pic_struct;               /* frames: -1 none (two fields), 0 / 3 / 4 (two), 5 / 6 (three:
                                          MPEG-2's repeat_first_field, top / bottom first), 7 (four:
                                          doubling), 8 (six: tripling); pairs: -1 */
    unsigned sar_w, sar_h;             /* the sample aspect ratio; 0:0 unspecified (square pixels) */
    unsigned rate_num, rate_den;       /* frames a second, num / den (30000 / 1001); 0 / 0 unknown */
    unsigned colour;                   /* (0.16) the colour code (H264RING_COLOUR_*: the matrix and range); 0 auto
                                          (BT.601 limited for SD, BT.709 for >= 1,280 wide or > 576 high). A
                                          full-range code (_601_FULL, _709_FULL, _2020_FULL) keeps a full-range
                                          source's samples as they are in h264ring_picture_copy (the core converts
                                          them: no conversion on the ARM); docs/architecture.md "The colour" */
};
struct h264ring_pic_layout {
    unsigned w_mbs, hf_mbs;            /* the coded size: macroblocks wide, frame macroblocks tall */
    uint32_t y_stride, c_stride;       /* bytes a row: 16 w_mbs, 8 w_mbs */
    uint32_t cb_off, cr_off;           /* the chroma planes in the store: 256 and 320 w_mbs hf_mbs */
    uint32_t bytes;                    /* the three planes' extent: 384 w_mbs hf_mbs */
    unsigned crop_r, crop_b;           /* the crop, in pairs of columns / frame lines (left, top 0) */
};
/* the store a picture of this size takes: 0, or -EINVAL for anything the core would refuse (a
 * side of 0 or past 2,048 pixels, more than H264RING_CAP_MAX_MBS macroblocks, a bad structure or
 * pic_struct) */
int  h264ring_picture_layout(const struct h264ring_picture *p, struct h264ring_pic_layout *l);
/* store k's mapping (NULL: no stores mapped, or k past H264RING_DPB_STORES) */
volatile uint64_t *h264ring_picture_store(h264ring *r, unsigned k);
/* a store the display no longer needs (the store rule, from a fresh status copy): 0 and *k, or
 * -EAGAIN (none free yet: a status frame later), -EBUSY (a coded stream since the last flush),
 * -ENOTCONN, -ENODEV (no stores mapped) */
int  h264ring_picture_acquire(h264ring *r, unsigned *k);
/* the copy into a store: planes[0..2] Y, Cb, Cr with their strides (bytes), in one of the source
 * formats below; full range converted to limited -- unless (0.16) p->colour is a full-range code, then
 * kept as it is (a limited source with a full-range code: -EINVAL) --, 4:2:2 averaged to 4:2:0 (within
 * each field for a pair), the edges replicated to the coded size; aligned 64-bit stores only. Touches
 * only the store: any thread may call it. 0, or -EINVAL. */
#define H264RING_PIX_YUV420P  0        /* 8-bit 4:2:0, limited range (most decoders) */
#define H264RING_PIX_YUVJ420P 1        /* ... full range (MJPEG) */
#define H264RING_PIX_YUV422P  2        /* 8-bit 4:2:2, limited range */
#define H264RING_PIX_YUVJ422P 3        /* ... full range (MJPEG) */
int  h264ring_picture_copy(volatile uint64_t *store, const struct h264ring_picture *p,
                           const uint8_t *const planes[3], const int strides[3], unsigned fmt);
/* the PICTURE record for store k (written by h264ring_picture_copy before): pts (90 kHz) or -1,
 * flags as an access unit's (H264RING_F_DISCONTINUITY, _END_OF_STREAM, _LOW_LATENCY, _GRAPHICS;
 * after an END_OF_STREAM the next one gets DISCONTINUITY automatically). -EAGAIN: the ring is full
 * (the store stays this program's: write it later); -EINVAL; -EBUSY; -ENOTCONN; -EPROTO */
int  h264ring_try_write_picture(h264ring *r, unsigned k, const struct h264ring_picture *p, int64_t pts,
                                unsigned flags);
int  h264ring_write_picture(h264ring *r, unsigned k, const struct h264ring_picture *p, int64_t pts,
                            unsigned flags, unsigned timeout_ms);
/* bytes that can be written now (a record needs 16 + its payload rounded up to 16, and a PAD
 * at the ring's end may come first) */
uint32_t h264ring_free(h264ring *r);

/* ---- access units ---- */
/* split an Annex-B buffer into access units (start codes included); returns how many there
 * are, filling at most `cap` entries of `out` (call with out = NULL to count) */
struct h264ring_au { uint32_t off, len; };
size_t h264ring_split_annexb(const uint8_t *buf, size_t n, struct h264ring_au *out, size_t cap);

/* ---- the core's OSD settings (interface 0.4) ----
 * Change any of the menu's options from your own interface. Main adopts the values as if the
 * user had chosen them: the OSD shows them, the user can change them again (the last change
 * wins). Takes effect within a poll (a few ms) during a session; the result is in the status
 * block (set_seq: this request's sequence number, set_err: 0 applied, 1 a value out of range,
 * 2 a reserved bit, 3 nothing selected) and the mirror (osd_*). Changing Video Output or
 * Refresh Rate switches the display's signal (the TV resyncs), as the menu does. */
enum h264ring_opt {                    /* the options, in the mirror's order */
    H264RING_OPT_ASPECT,               /* 0 Auto, 1 4:3, 2 16:9 */
    H264RING_OPT_DEINTERLACE,          /* 0 Weave, 1 Bob, 2 Blend */
    H264RING_OPT_VIDEO_OUTPUT,         /* 0 Auto, 1 Interlaced, 2 Progressive, 3 Native (HDMI) (0.10) */
    H264RING_OPT_HDMI_DEINTERLACE,     /* 0 Weave, 1 Bob */
    H264RING_OPT_ANALOG_ASPECT,        /* 0 Auto, 1 Fit, 2 Letterbox, 3 Crop */
    H264RING_OPT_REFRESH_RATE,         /* 0 Auto, 1 59.94 Hz, 2 60 Hz, 3 50 Hz */
    H264RING_OPT_ANTI_TWITTER,         /* 0 Auto (your stream's GRAPHICS), 1 Off, 2 On */
    H264RING_OPT_COUNT
};
/* one request: values[i] for each option i whose bit is set in `mask` (1u << H264RING_OPT_*).
 * -EINVAL: an empty mask, or a value past its option's last; -ENOTCONN: no session. Returns
 * the request's sequence number (1-255) on success. */
int  h264ring_request_settings(h264ring *r, unsigned mask, const unsigned values[H264RING_OPT_COUNT]);
/* v1.3 display policy on the OSD-owned settings path. mask bits 0..3 select profile
 * (0=480i60,1=480p60,2=576i50,3=576p50,4=Native HDMI), refresh matching
 * (0=Off, 1=50/60; legacy 2 is normalized to 1), 240p playback, and film speed-up.
 * Returns a request sequence or a negative errno; -ENOTSUP when unsupported. */
int h264ring_request_display(h264ring *r, unsigned mask, unsigned profile,
                            unsigned match, unsigned lowres, unsigned film);
/* stop asserting settings: clears the request word (0: no request). The core applies the
 * word's request again at each new session's start -- clear it when you no longer want your
 * settings re-applied over the user's (a later session, another program). Returns 0. */
int  h264ring_clear_settings(h264ring *r);

/* ---- calibrated playback geometry (interface 1.2) ----
 * The picture rectangle may extend past the raster for Crop. The clip viewport is the
 * calibrated screen area inside which output is visible. Coordinates are raster pixels /
 * frame lines and must be even; x/y are signed 13-bit values, dimensions are 1..8191. The
 * viewport is nonnegative and inside 720x576. All-zero clears the override. A 1.1 core can
 * still be attached for ordinary playback; this call returns -ENOTSUP on it. On success the
 * core has acknowledged the matching request sequence before this returns. */
struct h264ring_geometry {
    int x, y;
    unsigned width, height;
    unsigned clip_x, clip_y, clip_width, clip_height;
};
int  h264ring_set_geometry(h264ring *r, const struct h264ring_geometry *g, unsigned timeout_ms);

/* ---- the pause and the volume (interface 0.5: program word 34) ----
 * Out of band: they act within a poll (a few ms), not after the seconds queued in the ring.
 * PAUSE freezes the presentation clock, holds the picture, silences the audio and stops the
 * core consuming the ring; clearing it continues where it stopped. ATTEN is an attenuation
 * in 0.5 dB steps (0 full volume, 255 mute), applied to the audio as it plays. Both apply
 * during a session; the library writes them at every session's start (so a program that
 * crashed paused cannot leave the next one paused). Returns 0, or -EINVAL. */
int  h264ring_set_pause(h264ring *r, int paused);
int  h264ring_set_atten(h264ring *r, unsigned half_db);

/* ---- the pads' rumble (interface 0.13: program words 36-38, status words 82-83) ----
 * Main plays it on the user's pad: pad n is Main's player n + 1 (the input region's pad n). Two
 * motors, 0 off .. 255 full: `large` the low-frequency (strong) one, `small` the high-frequency
 * (weak) one -- a game-stream host's lowFreqMotor >> 8 and highFreqMotor >> 8. The core passes
 * the values on only while a session is open (0 otherwise); the library writes this program's
 * values at its first session (0 unless set before it) and zeroes them at h264ring_close.
 * Main plays a value for at most 32.767 s and re-uploads it only when it changes: to hold one
 * longer call h264ring_rumble_keepalive at least once a second, which writes a pad held at one
 * nonzero value for H264RING_RUMBLE_KEEPALIVE_MS one step away from it and back (1/255 of a
 * motor: imperceptible). If the program dies, Main stops the pad within 32.767 s.
 * Call both from one thread (an input thread may, beside the writer, without its mutex: above).
 * h264ring_rumble returns 0 or -EINVAL; h264ring_rumble_keepalive the pads it refreshed. */
#define H264RING_RUMBLE_KEEPALIVE_MS 10000u
int  h264ring_rumble(h264ring *r, unsigned pad, unsigned large, unsigned small);
int  h264ring_rumble_keepalive(h264ring *r);

/* ---- the overlay plane (interface 0.9: program words 72-79, status words 46-47) ----
 * Draw your own screens -- a menu, a host list, subtitles, a progress bar -- into a page of the
 * Linux framebuffer and the core composites it over the video (or the idle screen, or black)
 * on its own raster: HDMI and the analog outputs alike, anti-twittered at 480i / 576i unless
 * the user's Anti-Twitter is Off. One canvas pixel is one raster pixel: the raster is 720
 * pixels by 480 lines (576 at 50 Hz, the status block's raster_std); the canvas, at most 720 x
 * 576, is centred on it. Pixels are 16-bit 1555 (A R G B, the top bit opaque) or 4444, or
 * 32-bit 8888 (bytes B, G, R, A); straight (not premultiplied) alpha; a zeroed page is
 * transparent. Draw only the lines you need and say so in the band: the core reads those
 * lines alone, and its reads cost the decoder time (a full 8888 canvas ~1 % at 854x480p60,
 * which fits). Shown only during a session; every session starts with this
 * handle's overlay (or none). */
struct h264ring_overlay {
    uint32_t base;                     /* the page's physical byte address (a multiple of 8, inside
                                          [H264RING_FB_BYTE, + H264RING_FB_SIZE): h264ring_fb_map) */
    uint16_t width, height;            /* 1..OVL_MAX_W (2,048), 1..OVL_MAX_H (2,048) (0.12; 0.10: 1,024 x 2,047; 0.9: 720, 576) */
    uint16_t stride;                   /* bytes from one line to the next: a multiple of 8, >= width x bytes a pixel */
    uint8_t  format;                   /* H264RING_OVL_FMT_1555, _4444 or _8888 */
    uint16_t band_first, band_last;    /* the lines drawn on (only these are read): 0, height - 1 for all */
};
/* the core's checks, here: 0 or the H264RING_OVL_E_* code it would refuse the descriptor with */
int  h264ring_overlay_check(const struct h264ring_overlay *o);
/* show it (a page flip is a show with another base): the descriptor written under a new
 * generation, taken by the core at its next refresh, never mid-picture. Returns the generation
 * (> 0), or -EINVAL (h264ring_overlay_check failed). */
int  h264ring_overlay_show(h264ring *r, const struct h264ring_overlay *o);
/* hide it (the descriptor with ENABLE clear). Returns the generation (> 0). */
int  h264ring_overlay_hide(h264ring *r);
/* wait until the core has read generation `gen` OR A LATER ONE (the status block's ovl_gen): from
 * then on it never reads the previous page again, so a double-buffered program may draw into it.
 * (Later: every session start -- h264ring_start_session, h264ring_flush -- re-writes this
 * program's descriptor with a new generation, so the one a flip returned may be superseded before
 * the core reports it.) 0, or -EPROTO (the core refused the descriptor: ovl_state 2, the reason
 * in ovl_err), -ETIMEDOUT */
int  h264ring_overlay_wait(h264ring *r, int gen, unsigned timeout_ms);
/* the Linux framebuffer (/dev/fb0), mapped whole: pages are the caller's to lay out inside it
 * (phys + an offset, a multiple of 8). The core reads its pages, whatever mode the fbdev
 * driver reports. The kernel's console (fbcon, a login prompt on tty1) draws its blinking
 * cursor into this memory -- 16 lines of a text cell, measured on the MiSTer -- so the map
 * also stops the blink and hides the cursor on tty1; the unmap puts both back. -ENODEV: no
 * framebuffer, or not inside the region the core reads. */
struct h264ring_fb {
    void    *virt;                     /* the mapping */
    uint32_t phys;                     /* its physical byte address */
    uint32_t len;                      /* bytes */
    int      fd;
    int      blink;                    /* fbcon's cursor_blink before the map (-1: none) */
};
int  h264ring_fb_map(struct h264ring_fb *fb);
void h264ring_fb_unmap(struct h264ring_fb *fb);

/* ---- status ---- */
int  h264ring_status(h264ring *r, struct h264ring_status *st);
#define H264RING_ST(st, F) H264RING_GET((st)->w, F)
const char *h264ring_state_name(unsigned state);
const char *h264ring_error_name(unsigned err);
/* why the decoder refused a stream: FE_REFUSED_CODE (word 18) as words ("CAVLC (not CABAC)", ...);
 * a refusal no IDR cures -- end the stream, or ask the source for another encoding */
const char *h264ring_refusal_name(unsigned code);
/* every status field, as one JSON object (json != 0) or name / value lines */
void h264ring_dump(FILE *f, const struct h264ring_status *st, int json);
/* (0.10) the raster a program draws its overlay for, and where the picture is on it
 * (docs/architecture.md "The raster (0.10)"; the manual's integrating/overlay.md): the active
 * size (word 80), the shape HDMI shows it at (word 47: ar_x : ar_y for the WHOLE raster; 4:3
 * on the analog pins), the shown picture's rectangle on it (words 80 and 30; x0 / y0 negative
 * under Crop) and whether it is letterboxed inside (A': a picture wider than the HDMI
 * display, the raster shown at the display's shape -- its bars are the raster's, and a
 * program may draw in them). */
struct h264ring_raster {
    unsigned w, h;                     /* active pixels x frame lines (a field is half the lines) */
    unsigned mode;                     /* H264RING_RASTER_* */
    int interlaced;                    /* 480i / 576i: the analog raster, shown 4:3 */
    unsigned ar_x, ar_y;               /* the raster is shown ar_x : ar_y wide on HDMI */
    double aspect;                     /* ar_x / ar_y (4:3 when interlaced or not yet known) */
    int lb;                            /* A': letterboxed inside the raster */
    int pic_x0, pic_y0;                /* the picture's rectangle on the raster */
    unsigned pic_w, pic_h;
};
#define H264RING_RASTER_FITTED 0       /* 720 x 480 / 576 */
#define H264RING_RASTER_NATIVE 1       /* (stage 2: docs/hdmi_raster.md) the picture's own size */
#define H264RING_RASTER_NATIVE_FB 2    /* native, but this picture fell back to the fitted raster */
void h264ring_raster(const struct h264ring_status *st, struct h264ring_raster *rs);
/* (0.11) what the core can play (word 81; docs/architecture.md "The capabilities (0.11)"; the
 * manual's integrating/status.md): the largest picture in macroblocks (a larger one is refused,
 * counted in RC_REF_SIZE), the macroblock rate the core is designed for (above it the decoding
 * falls behind; real time below it also depends on the bitrate), and the tallest 16:9 picture
 * Video Output's Native (HDMI) shows at its own size (a taller one is fitted to the 720-wide
 * raster -- a program choosing a transcode's size gains nothing above it). A word 81 of 0 (no
 * status frame yet) reads as 0.10's limits. */
struct h264ring_caps {
    unsigned max_mbs;                  /* 3,600: 1280x720 (Level 3.1's MaxFS) */
    unsigned mb_rate;                  /* 108,000 a second: 1280x720 at 30, 854x480 at 60 (MaxMBPS) */
    unsigned native_h;                 /* 480 */
};
void h264ring_caps(const struct h264ring_status *st, struct h264ring_caps *c);
/* (0.14) Video Output as the core resolved it (word 80's video_out; docs/architecture.md "Video
 * Output resolved (0.14)"): its Auto is Interlaced (an analog TV in MiSTer.ini), Progressive (a
 * 31 kHz VGA monitor on the core's own raster) or Native (HDMI) -- so a program asking "is the
 * picture shown at its own pixels?" reads this, never the menu's value (word 27's mirror). A core
 * before 0.14 reads 0 there: the menu's value, its Auto then Interlaced or Progressive by word
 * 30's raster_il (Auto never chose Native before 0.14). */
#define H264RING_VOUT_INTERLACED  1
#define H264RING_VOUT_PROGRESSIVE 2
#define H264RING_VOUT_NATIVE      3
unsigned h264ring_video_out(const struct h264ring_status *st);

/* ---- input (0.6): Main's pads, keys and mouse, mirrored by the core ----
 * While a core runs Main holds every input device (EVIOCGRAB): a program reading /dev/input
 * receives nothing. The core copies what Main sends it into words 48-71 (docs/architecture.md
 * "Input (interface 0.6)"; the manual's integrating/launch.md "Input"): the six pads as a snapshot, the
 * mouse's movement as sums, and keys, mouse-button changes, the OSD's opening / closing and
 * (0.8) the OSD's actions as ONE ordered event queue of H264RING_IN_Q_LEN entries. Rewritten on
 * change (at most every 1 ms) and once a frame. Reading it needs no session.
 *
 * (0.8) The OSD's actions: the core's menu has H264RING_IN_ACTIONS entries a program acts on --
 * 0 "Send Home to the program" (a game-stream client: the host's Guide / Home button), 1
 * "Program menu" (the program's own menu, if it has one). Choosing one queues an ACTION event
 * and then Main closes the OSD, so the event arrives BEFORE the OSD's closing: take it while
 * the OSD is open, act on it after the close. */
struct h264ring_input {
    uint64_t w[H264RING_IN_WORDS];    /* w[i] is control word H264RING_IN_WORD + i */
};
#define H264RING_IN(in, F) h264ring_get((in)->w, H264RING_##F##_W - H264RING_IN_WORD, \
                                        H264RING_##F##_LSB, H264RING_##F##_WIDTH)
/* a consistent copy (the region's own seqlock: in_tail, the words, in_head). 0, or -EAGAIN */
int  h264ring_input(h264ring *r, struct h264ring_input *in);
/* The events after *count, oldest first, at most cap of them into ev[]; returns how many and
 * advances *count past them (call again while it returns cap). Start *count at the copy's
 * EV_COUNT (events before the program began are not its). If the queue no longer holds the
 * oldest ones (the program read more than H264RING_IN_Q_LEN events late), *lost is increased
 * by how many were overwritten and *count moves past them: the program must then treat every
 * key and button as unknown (release them all). lost may be NULL. */
unsigned h264ring_input_events(const struct h264ring_input *in, uint32_t *count, uint16_t *ev,
                               unsigned cap, uint32_t *lost);
/* an event (16 bits): the type, and its fields */
#define H264RING_EV_TYPE(e)     ((unsigned)(e) >> H264RING_EV_TYPE_LSB)      /* H264RING_EV_KEY / _MOUSE_BTN / _OSD / _ACTION */
#define H264RING_EV_CODE(e)     ((unsigned)(e) & 0xFFu)     /* KEY: the PS/2 set-2 code; MOUSE_BTN: the buttons; ACTION: its number */
#define H264RING_EV_EXT(e)      (((unsigned)(e) >> H264RING_EV_KEY_EXT) & 1u)       /* KEY: the E0 prefix */
#define H264RING_EV_PRESSED(e)  (((unsigned)(e) >> H264RING_EV_KEY_PRESSED) & 1u)   /* KEY: pressed (1) or released */
#define H264RING_EV_OPEN(e)     ((unsigned)(e) & 1u)        /* OSD: opened (1) or closed */
/* a pad's buttons (the core's J line, bits [15:0] of PADn_JOY) */
enum {
    H264RING_PAD_RIGHT = 1u << 0, H264RING_PAD_LEFT = 1u << 1, H264RING_PAD_DOWN = 1u << 2, H264RING_PAD_UP = 1u << 3,
    H264RING_PAD_A = 1u << 4, H264RING_PAD_B = 1u << 5, H264RING_PAD_X = 1u << 6, H264RING_PAD_Y = 1u << 7,
    H264RING_PAD_LB = 1u << 8, H264RING_PAD_RB = 1u << 9, H264RING_PAD_BACK = 1u << 10, H264RING_PAD_START = 1u << 11,
    H264RING_PAD_LS = 1u << 12, H264RING_PAD_RS = 1u << 13, H264RING_PAD_LT = 1u << 14, H264RING_PAD_RT = 1u << 15
};

#ifdef __cplusplus
}
#endif
#endif
