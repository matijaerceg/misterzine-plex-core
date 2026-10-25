/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_PACKET_PACING_H
#define JFPLAY_PACKET_PACING_H
#include <stdint.h>
#include <stddef.h>
struct packet_pacing {
    int has_audio, audio_queued, reader_done, reader_blocked;
    size_t pcm_frames;
    int64_t video_written, audio_written, video_pts, audio_pts;
};
/* Keep queued video close to audio even while the demuxer is fetching the
 * next audio packet. An empty audio queue is not evidence of a silent track.
 * Release a genuine timestamp gap, end of audio, or a full reader queue so
 * sparse tracks cannot deadlock the bounded demuxer. */
static inline int packet_video_ready(struct packet_pacing s, size_t record_frames,
                                     int64_t lead)
{
    if (!s.has_audio || s.video_written == INT64_MIN || s.video_pts == INT64_MIN)
        return 1;
    int64_t edge = s.audio_written == INT64_MIN ? s.video_written : s.audio_written;
    if (s.video_pts <= edge + lead) return 1;
    if (s.pcm_frames < record_frames) {
        if (s.audio_queued && s.audio_pts != INT64_MIN && s.audio_pts > s.video_pts)
            return 1;
        if (!s.audio_queued && (s.reader_done || s.reader_blocked)) return 1;
    }
    return 0;
}
#endif
