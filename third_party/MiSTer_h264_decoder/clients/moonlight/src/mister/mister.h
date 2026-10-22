/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/moonlight/src/mister/mister.h -- the "mister" platform of moonlight-embedded: the
 * video and audio go to the MiSTer H264 core through its HPS interface (hps/, libh264ring).
 * Design: docs/moonlight.md in the MiSTer H264 core's repository. */
#pragma once

#include <Limelight.h>
#include <stdbool.h>

extern DECODER_RENDERER_CALLBACKS decoder_callbacks_mister;
extern AUDIO_RENDERER_CALLBACKS audio_callbacks_mister;

/* the platform is usable here: a MiSTer (Main's command FIFO exists) */
bool mister_detect(void);
/* load the core if it is not running, attach to its ring and start a session (before the
 * stream: loading a core takes seconds). Returns 0 or a negative errno. */
int  mister_start(void);
/* end the session and detach; print the counters */
void mister_stop(void);
/* the picture to ask the host for when the user named none: the MiSTer screen's shape, from
 * the status block (after mister_start). Sunshine fits its desktop into the requested frame,
 * so matching the screen leaves at most one set of bars. 4:3 -- an interlaced raster (the
 * analog TV case) or Aspect Ratio 4:3 -- asks 640x480; otherwise (HDMI, Aspect Auto / 16:9)
 * 848x480, 16:9 in whole macroblocks (53x30, inside the core's 1,620). */
void mister_preferred_size(int *width, int *height);
/* Main's OSD is open (the status block's OSD_OPEN, as last read): forward no input */
bool mister_osd_open(void);
/* re-read the status block now (the input loop's 50 ms timer; skipped while a session start
 * holds the ring, so the input never waits up to 2 s behind it) */
void mister_poll_status(void);

/* mister_start's second half, for a ring the caller attached (the host test:
 * h264ring_attach over memory): take it and start a session */
struct h264ring;
int  mister_attach(struct h264ring *r);

/* the ring mister_start attached (NULL before it / after mister_stop) */
struct h264ring *mister_ring(void);

/* ---- input through the core (interface 0.6; mister_input.c) ----
 * Main grabs every input device while a core runs; the core mirrors Main's keys, mouse and
 * pads into its control block and this forwards them to the host. */
/* a 1 ms timer on the main loop (after mister_start); 0 or a negative errno */
int  mister_input_start(void);
/* release everything the host holds, remove the timer, print the counters */
void mister_input_stop(void);
/* one read of the input region, forwarded: LOOP_OK, or LOOP_RETURN when a quit combo completed
 * (the timer's handler, one tick = 1 ms of the chord's and the Guide tap's time; the host test
 * calls it directly) */
int  mister_input_poll(void);
struct mister_input_counters {
    unsigned long reads, reads_failed, events, keys, keys_unknown, stray_up, mouse_moves, buttons,
                  pads_announced, pad_sends, osd_opened, osd_dropped, releases, lost,
                  actions, guides,     /* (0.8) the OSD's actions read; Guide taps sent (an action or the chord) */
                  rumbles, rumble_refreshes, rumble_dropped;   /* (0.13) rumble values written; pads the
                                          keepalive stepped; rumble for a controller past the six */
};
/* (0.13) the connection's rumble callbacks (moonlight-common-c's callback thread): pad n's motors,
 * written to the core by the input timer; trigger rumble is dropped (no motor on Main's pads) */
void mister_rumble(unsigned short controller, unsigned short low_freq, unsigned short high_freq);
void mister_rumble_triggers(unsigned short controller, unsigned short left, unsigned short right);
void mister_input_get_counters(struct mister_input_counters *c);

/* what the backend did (printed by mister_stop; read by the host test) */
struct mister_counters {
    unsigned long au, au_bytes, au_dropped, idr_asked, sessions, errors_seen, refusals, core_gone;
    unsigned long au_rewritten;    /* written after the CAVLC -> CABAC rewrite (fj#20) */
    unsigned long aud, aud_dropped, aud_plc, aud_early;
};
void mister_get_counters(struct mister_counters *c);
