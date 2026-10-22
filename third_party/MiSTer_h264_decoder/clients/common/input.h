/* input -- a client's controls from the core's input region (interface 0.6 / 0.8: Main holds
 * every input device while a core runs; docs/jellyfin.md J1). Any pad, the keyboard, the OSD's
 * two actions. Nothing while Main's OSD is open (Main sends the core nothing then either).
 * Two mappings: playback (the default; the Jellyfin client's) and, with `nav` set, a list's
 * navigation (the file player's browser: docs/player.md P2). */
#ifndef CLIENT_INPUT_H
#define CLIENT_INPUT_H

#include "h264ring.h"

enum cl_action {
    ACT_NONE,
    ACT_PAUSE,          /* A, Start, Space, K, Enter */
    ACT_BACK,           /* left: -10 s (a held seek button repeats: REPEAT_FIRST_MS, then every REPEAT_MS) */
    ACT_FWD,            /* right: +30 s */
    ACT_BACK_BIG,       /* LB, down, Page Down: -5 min */
    ACT_FWD_BIG,        /* RB, up, Page Up: +5 min */
    ACT_STOP,           /* Back + Start held together, Esc, Q, the OSD's "Send Home to the program" */
    ACT_SUBS,           /* X, S: the next subtitle track (or off) */
    ACT_AUDIO,          /* Y, A key: the next audio track */
    ACT_INFO,           /* B, I, the OSD's "Program menu": show the now-playing panel */
    ACT_NEXT,           /* N: the next item (the file player: the next file in the folder) */
    ACT_PREV,           /* P: the previous one */
    /* nav (a list): ACT_STOP is Back + Start / Q / the OSD's "Send Home" (leave the list) */
    ACT_UP,             /* up (held: repeats), the arrow key */
    ACT_DOWN,           /* down */
    ACT_PAGE_UP,        /* LB, Page Up */
    ACT_PAGE_DOWN,      /* RB, Page Down */
    ACT_OK,             /* A, Start, right, Enter */
    ACT_CANCEL,         /* B, left, Esc, Backspace, the OSD's "Program menu" */
};

struct cl_input {
    int nav;            /* the client sets it: 1 a list's mapping, 0 playback's */
    uint32_t count;     /* the events read so far (the core's free-running count) */
    int started;
    uint32_t pads[6];   /* the buttons last seen, for the edges */
    uint64_t repeat_ms[6];  /* a held seek button repeats from then (0: none held) */
};

/* the actions since the last call, oldest first; returns how many (at most cap) */
unsigned input_poll(struct cl_input *in, h264ring *r, enum cl_action *out, unsigned cap);
const char *input_action_name(enum cl_action a);

#endif
