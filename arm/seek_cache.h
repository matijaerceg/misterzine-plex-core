/* SPDX-License-Identifier: GPL-3.0-or-later
 * Conservative selector for a forward seek within the compressed reader queue.
 * Times are 90 kHz ticks. */
#ifndef JFPLAY_SEEK_CACHE_H
#define JFPLAY_SEEK_CACHE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define SEEK_CACHE_NOPTS INT64_MIN
#define SEEK_CACHE_MAX_OVERSHOOT90 90000 /* 1 second */
#define SEEK_CACHE_VIDEO_GAP90 22500    /* 250 ms */
#define SEEK_CACHE_AUDIO_GAP90 90       /* 1 ms */

enum seek_cache_kind {
    SEEK_CACHE_VIDEO = 1,
    SEEK_CACHE_AUDIO = 2
};

struct seek_cache_packet {
    uint64_t seq;
    enum seek_cache_kind kind;
    int64_t pts90;
    int64_t dts90;
    int64_t duration90;
    int idr_confirmed;
};

struct seek_cache_plan {
    uint64_t video_cut_seq;
    uint64_t audio_cut_seq;
    int64_t anchor_pts90;
    int64_t requested_target90;
    int64_t overshoot90;
    int64_t envelope_start90;
    int64_t envelope_end90;
};

struct seek_cache_interval {
    enum seek_cache_kind kind;
    int64_t start90;
    int64_t end90;
};

static inline int seek_cache_interval_cmp(const void *lhs, const void *rhs)
{
    const struct seek_cache_interval *a = lhs, *b = rhs;
    if (a->kind != b->kind) return (int)a->kind - (int)b->kind;
    if (a->start90 < b->start90) return -1;
    if (a->start90 > b->start90) return 1;
    return 0;
}

static inline int64_t seek_cache_gap_tolerance(enum seek_cache_kind kind)
{
    return kind == SEEK_CACHE_VIDEO ? SEEK_CACHE_VIDEO_GAP90 : SEEK_CACHE_AUDIO_GAP90;
}

/* Returns 1 for a conservative forward queue hit and 0 for a normal seek
 * miss. Input is globally seq-ordered. Decode timestamps must be monotonic
 * when present; presentation intervals are sorted separately so ordinary
 * H.264 B-frame PTS reordering is supported. Every stream's intervals must
 * continuously cover the hit envelope (video gap tolerance 250ms, audio 1ms).
 * The candidate is an explicitly confirmed IDR within one second of target,
 * either before or after it, and strictly after the current playhead.
 * Allocation failure, unknown timestamps/durations, gaps, and absent audio
 * yield a safe miss. Caller still validates decoded readiness after the hit. */
static inline int seek_cache_select(const struct seek_cache_packet *packets,
                                   size_t count, int64_t current90,
                                   int64_t target90,
                                   struct seek_cache_plan *plan)
{
    size_t anchor = count, audio_cut = count;
    struct seek_cache_interval *intervals;
    int64_t anchor_pts = SEEK_CACHE_NOPTS;
    int64_t anchor_distance = INT64_MAX;
    int64_t video_min = INT64_MAX, audio_min = INT64_MAX;
    int64_t video_end = INT64_MIN, audio_end = INT64_MIN;
    int64_t prev_video_dts = INT64_MIN, prev_audio_dts = INT64_MIN;
    int64_t prev_audio_pts = INT64_MIN;
    int have_video = 0, have_audio = 0;
    int video_post = 0, audio_post = 0;
    uint64_t prev_seq = 0;

    if (!packets || !plan || !count || target90 <= current90 || target90 < 0 ||
        count > SIZE_MAX / sizeof *intervals)
        return 0;
    intervals = malloc(count * sizeof *intervals);
    if (!intervals) return 0;

    for (size_t i = 0; i < count; ++i) {
        const struct seek_cache_packet *p = &packets[i];
        int64_t t = p->pts90 != SEEK_CACHE_NOPTS ? p->pts90 : p->dts90;
        int64_t end;
        if ((i && p->seq <= prev_seq) || t == SEEK_CACHE_NOPTS ||
            p->duration90 <= 0 || t > INT64_MAX - p->duration90 ||
            (p->kind != SEEK_CACHE_VIDEO && p->kind != SEEK_CACHE_AUDIO))
            goto miss;
        prev_seq = p->seq;
        end = t + p->duration90;
        intervals[i] = (struct seek_cache_interval){p->kind, t, end};
        if (p->kind == SEEK_CACHE_VIDEO) {
            /* The demuxer's sequence is decode order even when a container
             * omits DTS. PTS alone must not reject ordinary B-frame reorder. */
            if (p->dts90 != SEEK_CACHE_NOPTS) {
                if (prev_video_dts != INT64_MIN && p->dts90 < prev_video_dts) goto miss;
                prev_video_dts = p->dts90;
            }
            have_video = 1;
            if (p->idr_confirmed && t > current90) {
                int64_t distance;
                if (t >= target90) {
                    if (t - target90 > SEEK_CACHE_MAX_OVERSHOOT90) continue;
                    distance = t - target90;
                } else {
                    if (t < target90 - SEEK_CACHE_MAX_OVERSHOOT90) continue;
                    distance = target90 - t;
                }
                if (distance < anchor_distance ||
                    (distance == anchor_distance && t >= target90)) {
                    anchor = i;
                    anchor_pts = t;
                    anchor_distance = distance;
                }
            }
        } else {
            if (p->dts90 != SEEK_CACHE_NOPTS) {
                if (prev_audio_dts != INT64_MIN && p->dts90 < prev_audio_dts) goto miss;
                prev_audio_dts = p->dts90;
            } else if (prev_audio_pts != INT64_MIN && t < prev_audio_pts) {
                goto miss;
            }
            prev_audio_pts = t;
            have_audio = 1;
        }
    }
    if (!have_video || !have_audio || anchor == count)
        goto miss;

    /* Require actual queue coverage through the target and the chosen IDR.
     * Sort presentation intervals because H.264 B-frames reorder PTS. */
    qsort(intervals, count, sizeof *intervals, seek_cache_interval_cmp);
    for (size_t i = 0; i < count; ++i) {
        struct seek_cache_interval *cur = &intervals[i];
        int64_t *lo = cur->kind == SEEK_CACHE_VIDEO ? &video_min : &audio_min;
        int64_t *hi = cur->kind == SEEK_CACHE_VIDEO ? &video_end : &audio_end;
        if (*lo == INT64_MAX) {
            *lo = cur->start90;
            *hi = cur->end90;
        } else {
            int64_t tolerance = seek_cache_gap_tolerance(cur->kind);
            if (cur->start90 > *hi &&
                (*hi > INT64_MAX - tolerance || cur->start90 > *hi + tolerance))
                goto miss;
            if (cur->end90 > *hi) *hi = cur->end90;
        }
    }
    if (video_min > target90 || audio_min > target90 ||
        video_end <= target90 || audio_end <= target90 ||
        video_end <= anchor_pts || audio_end <= anchor_pts)
        goto miss;

    /* Require actual queue packets after the IDR timestamp, including a later
     * video packet in decode sequence; an IDR packet's own duration is not a
     * substitute for queued future media. */
    for (size_t i = anchor + 1; i < count; ++i) {
        const struct seek_cache_packet *p = &packets[i];
        int64_t t = p->pts90 != SEEK_CACHE_NOPTS ? p->pts90 : p->dts90;
        if (p->kind == SEEK_CACHE_VIDEO && t >= anchor_pts) video_post = 1;
    }
    for (size_t i = 0; i < count; ++i) {
        const struct seek_cache_packet *p = &packets[i];
        int64_t t = p->pts90 != SEEK_CACHE_NOPTS ? p->pts90 : p->dts90;
        if (p->kind == SEEK_CACHE_AUDIO && t >= anchor_pts) audio_post = 1;
    }
    if (!video_post || !audio_post) goto miss;

    for (size_t i = 0; i < count; ++i) {
        const struct seek_cache_packet *p = &packets[i];
        int64_t t;
        if (p->kind != SEEK_CACHE_AUDIO) continue;
        t = p->pts90 != SEEK_CACHE_NOPTS ? p->pts90 : p->dts90;
        if (t <= anchor_pts && t + p->duration90 > anchor_pts) {
            audio_cut = i;
            break;
        }
        if (audio_cut == count && t >= anchor_pts) audio_cut = i;
    }
    if (audio_cut == count) goto miss;

    /* Validate the packets that remain after the stream-specific cuts. A
     * reordered pre-IDR picture may fill a PTS gap in the original queue, but
     * it is discarded with its earlier seq and cannot prove the retained
     * post-IDR range. Clip the selected overlapping audio packet to anchor. */
    size_t retained = 0;
    for (size_t i = 0; i < count; ++i) {
        const struct seek_cache_packet *p = &packets[i];
        uint64_t cut = p->kind == SEEK_CACHE_VIDEO ? packets[anchor].seq :
                                                     packets[audio_cut].seq;
        int64_t t = p->pts90 != SEEK_CACHE_NOPTS ? p->pts90 : p->dts90;
        int64_t end = t + p->duration90;
        if (p->seq < cut || end <= anchor_pts) continue;
        if (t < anchor_pts) t = anchor_pts;
        intervals[retained++] = (struct seek_cache_interval){p->kind, t, end};
    }
    qsort(intervals, retained, sizeof *intervals, seek_cache_interval_cmp);
    int64_t video_retained_end = anchor_pts, audio_retained_end = anchor_pts;
    for (size_t i = 0; i < retained; ++i) {
        struct seek_cache_interval *cur = &intervals[i];
        int64_t *cover = cur->kind == SEEK_CACHE_VIDEO ? &video_retained_end :
                                                        &audio_retained_end;
        int64_t tolerance = seek_cache_gap_tolerance(cur->kind);
        if (cur->start90 > *cover &&
            (*cover > INT64_MAX - tolerance || cur->start90 > *cover + tolerance))
            goto miss;
        if (cur->end90 > *cover) *cover = cur->end90;
    }
    if (video_retained_end <= anchor_pts || audio_retained_end <= anchor_pts ||
        video_retained_end <= target90 || audio_retained_end <= target90)
        goto miss;

    plan->video_cut_seq = packets[anchor].seq;
    plan->audio_cut_seq = packets[audio_cut].seq;
    plan->anchor_pts90 = anchor_pts;
    plan->requested_target90 = target90;
    plan->overshoot90 = anchor_pts - target90;
    plan->envelope_start90 = anchor_pts;
    plan->envelope_end90 = video_retained_end < audio_retained_end ?
                           video_retained_end : audio_retained_end;
    free(intervals);
    return 1;

miss:
    free(intervals);
    return 0;
}

#endif
