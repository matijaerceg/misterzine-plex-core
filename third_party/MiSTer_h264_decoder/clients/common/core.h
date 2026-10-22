/* core -- the H264 core as the client holds it: loaded, a session open for as long as the
 * client runs (the ready screen is a session with no video: docs/jellyfin.md J5, R3), the
 * status read once a loop, the heartbeat watched (an unloaded core's words stay as they were:
 * moonlight.md S2 "The way out"), an OSD Reset's dropped session re-opened. */
#ifndef CLIENT_CORE_H
#define CLIENT_CORE_H

#include <stdint.h>
#include "h264ring.h"

struct core {
    h264ring *r;
    struct h264ring_status st;        /* the last consistent copy */
    int have_st;
    uint32_t beat;                    /* the heartbeat (seq_head) last seen, and when */
    uint64_t beat_ms;
    uint32_t refused_base, err_base;  /* the counters at the stream's start */
    int gone;                         /* the core stopped beating: another core was loaded */
    unsigned sessions;
};

uint64_t now_ms(void);
/* load the core (rbf NULL: _Other/H264), attach, open a session */
int  core_open(struct core *c, const char *rbf);
/* ... with h264ring_open_devmem's flags ((0.15) H264RING_OPEN_PICTURES: the stores mapped, for
 * pictures decoded on the ARM) */
int  core_open2(struct core *c, const char *rbf, unsigned open_flags);
/* read the status; watch the heartbeat; re-open a dropped session. 0, or -ENODEV once the core
 * is gone (never comes back: the client ends) */
int  core_poll(struct core *c);
/* a new stream: drop what is queued, reset the decoder (h264ring_flush), re-base the counters */
int  core_new_stream(struct core *c);
/* since core_new_stream: the decoder refused the stream (and why), or met errors */
int  core_refused(const struct core *c, const char **why);
uint32_t core_errors(const struct core *c);
uint64_t core_stc(const struct core *c);
int  core_flag(const struct core *c, unsigned live_bit);   /* H264RING_L_* */
void core_close(struct core *c);

#endif
