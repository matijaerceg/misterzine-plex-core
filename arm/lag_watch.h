/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_LAG_WATCH_H
#define JFPLAY_LAG_WATCH_H
/* The direct-stream watchdog: whether the core persistently fails to keep up
 * with an untranscoded stream, so the app should switch to a transcode.
 *
 * It samples two core status values once a window: DISP_LATE (pictures
 * picked up after they were due; a 16-bit counter) and LAG_MS (the last
 * pickup's want - STC in ms: negative when late). A window is bad when new
 * late pickups appeared and the picture is behind by at least LAG_BEHIND_MS
 * and falling further behind by at least LAG_GROWTH_MS a window, or is
 * behind by LAG_HARD_MS whatever the trend. LAG_BAD_WINDOWS consecutive bad
 * windows trigger. Late pickups alone do not: a 60.000 frames/s stream on
 * the 59.94 raster counts them steadily while its lag grows ~1 ms a second.
 * Sampling pauses (and the grace restarts) while paused, seeking or before
 * the first picture, and a LAG_MS of 0xFFFF (no pickup yet) is not a sample.
 * The thresholds are first estimates, to be tuned on hardware. */
#include <stdint.h>

#define LAG_WINDOW_MS   1000u
#define LAG_GRACE_MS    3000u  /* after start, seek or resume: the start's lag is won back */
#define LAG_BEHIND_MS   200
#define LAG_GROWTH_MS   20
#define LAG_HARD_MS     2000
#define LAG_BAD_WINDOWS 4u
#define LAG_NONE        0xFFFFu  /* the core's LAG_MS before its first pickup */

struct lag_watch {
    int active;
    uint64_t next_ms;
    unsigned late0, bad;
    int behind0;
};

/* One sample (raw_lag is the core's 16-bit LAG_MS word); returns 1 when a transcode is needed. */
static inline int lag_watch_sample(struct lag_watch *w, uint64_t now_ms, int running,
                                   unsigned late, unsigned raw_lag)
{
    if (!running) { w->active = 0; return 0; }
    if (raw_lag == LAG_NONE) return 0;  /* no pickup yet: not a sample */
    int behind = -(int)(int16_t)raw_lag;
    if (!w->active) {
        w->active = 1; w->bad = 0;
        w->next_ms = now_ms + LAG_GRACE_MS;
        w->late0 = late; w->behind0 = behind;
        return 0;
    }
    if (now_ms < w->next_ms) return 0;
    unsigned new_late = (late - w->late0) & 0xFFFFu;
    int worse = (behind >= LAG_BEHIND_MS && behind - w->behind0 >= LAG_GROWTH_MS) ||
                behind >= LAG_HARD_MS;
    w->bad = (new_late && worse) ? w->bad + 1 : 0;
    w->late0 = late; w->behind0 = behind;
    w->next_ms = now_ms + LAG_WINDOW_MS;
    return w->bad >= LAG_BAD_WINDOWS;
}
#endif
