/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_TIMING_WATCH_H
#define JFPLAY_TIMING_WATCH_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* A bounded timestamp check for progressive direct video. Sort PTS rather
 * than DTS: B pictures arrive out of display order. Ignore eight pictures at
 * either edge, where a reorder group may cross a window boundary. Compare
 * with the rate used for the core's VUI repair, allowing 1.5 ms rounding or
 * 5%, whichever is larger. Packet duration is deliberately not evidence:
 * demuxers can fill it with the same misleading nominal rate.
 *
 * A mostly wrong window is decisive; mixed timing needs two bad windows.
 * Sparse outliers, absent timestamps and large discontinuities do not vote
 * for a transcode. This is a compatibility check, not a universal VFR label.
 */
#define TIMING_WATCH_COUNT 64
struct timing_watch {
    int64_t pts[TIMING_WATCH_COUNT];
    unsigned count, bad_windows;
};
static inline int tw_compare(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return (x > y) - (x < y);
}
static inline void timing_watch_reset(struct timing_watch *w)
{
    memset(w, 0, sizeof *w);
}
static inline int timing_watch_sample(struct timing_watch *w, int64_t pts90,
                                      unsigned rate_num, unsigned rate_den)
{
    if (pts90 == INT64_MIN || !rate_num || !rate_den) {
        timing_watch_reset(w);
        return 0;
    }
    double duration = 90000.0 * rate_den / rate_num;
    if (duration < 750 || duration > 9000) return 0;
    w->pts[w->count++] = pts90;
    if (w->count < TIMING_WATCH_COUNT) return 0;
    w->count = 0;
    qsort(w->pts, TIMING_WATCH_COUNT, sizeof w->pts[0], tw_compare);
    double span = (double)w->pts[63] - (double)w->pts[0];
    if (span < 45000 || span > 9000.0 * TIMING_WATCH_COUNT) {
        w->bad_windows = 0;
        return 0;
    }
    double tolerance = duration * .05;
    if (tolerance < 135) tolerance = 135;
    unsigned bad = 0;
    for (unsigned i = 8; i < TIMING_WATCH_COUNT - 9; ++i) {
        double delta = (double)w->pts[i + 1] - (double)w->pts[i];
        if (delta <= 0 || delta > 9000) {
            w->bad_windows = 0;
            return 0;
        }
        if (delta < duration - tolerance || delta > duration + tolerance) bad++;
    }
    w->bad_windows = bad >= 12 ? w->bad_windows + 1 : 0;
    return bad >= 36 || w->bad_windows >= 2;
}
#endif
