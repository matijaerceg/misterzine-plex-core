#ifndef VIDEO_BITRATE_H
#define VIDEO_BITRATE_H
#include <stdint.h>
/* Encoded video bytes per media second, independent of download bursts and
 * wall-clock pauses. A seek starts a fresh sample; callers count accepted AUs. */
struct video_bitrate {
    uint64_t bytes, ticks, window_bytes, window_ticks, recent_bps;
};
static inline void video_bitrate_add(struct video_bitrate *s, uint32_t bytes, int64_t duration90)
{
    if (!bytes || duration90 <= 0 || duration90 > 90000) return;
    s->bytes += bytes; s->ticks += (uint64_t)duration90;
    s->window_bytes += bytes; s->window_ticks += (uint64_t)duration90;
    if (s->window_ticks >= 180000) {
        s->recent_bps = s->window_bytes * 720000 / s->window_ticks;
        s->window_bytes = s->window_ticks = 0;
    }
}
static inline uint64_t video_bitrate_average(const struct video_bitrate *s)
{
    return s->ticks >= 90000 ? s->bytes * 720000 / s->ticks : 0;
}
#endif
