/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>

#include "seek_cache.h"

#define T(s, k, p, d, n, idr) { (s), (k), (p), (d), (n), (idr) }

static void test_next_confirmed_idr_and_audio_overlap(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 90000, SEEK_CACHE_NOPTS, 90000, 0),
        T(2, SEEK_CACHE_AUDIO, 90000, SEEK_CACHE_NOPTS, 90000, 0),
        T(3, SEEK_CACHE_VIDEO, 180000, SEEK_CACHE_NOPTS, 90000, 1),
        T(4, SEEK_CACHE_AUDIO, 180000, SEEK_CACHE_NOPTS, 90000, 0),
        T(5, SEEK_CACHE_VIDEO, 270000, SEEK_CACHE_NOPTS, 90000, 0),
        T(6, SEEK_CACHE_AUDIO, 270000, SEEK_CACHE_NOPTS, 90000, 0),
    };
    struct seek_cache_plan p;
    assert(seek_cache_select(q, sizeof q / sizeof q[0], 90000, 175000, &p));
    assert(p.video_cut_seq == 3);
    assert(p.audio_cut_seq == 4);
    assert(p.anchor_pts90 == 180000 && p.overshoot90 == 5000);
    assert(p.requested_target90 == 175000);
    assert(p.envelope_start90 == 180000 && p.envelope_end90 == 360000);
}

static void test_key_flag_without_confirmed_idr_misses(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 90000, SEEK_CACHE_NOPTS, 3000, 0),
        T(2, SEEK_CACHE_AUDIO, 90000, SEEK_CACHE_NOPTS, 1920, 0),
        T(3, SEEK_CACHE_VIDEO, 180000, SEEK_CACHE_NOPTS, 3000, 0),
        T(4, SEEK_CACHE_AUDIO, 180000, SEEK_CACHE_NOPTS, 1920, 0),
    };
    struct seek_cache_plan p;
    assert(!seek_cache_select(q, 4, 90000, 175000, &p));
}

static void test_audio_must_cover_target_and_anchor(void)
{
    const struct seek_cache_packet no_target[] = {
        T(1, SEEK_CACHE_VIDEO, 90000, SEEK_CACHE_NOPTS, 3000, 0),
        T(2, SEEK_CACHE_AUDIO, 176000, SEEK_CACHE_NOPTS, 1920, 0),
        T(3, SEEK_CACHE_VIDEO, 180000, SEEK_CACHE_NOPTS, 3000, 1),
        T(4, SEEK_CACHE_AUDIO, 180000, SEEK_CACHE_NOPTS, 1920, 0),
    };
    const struct seek_cache_packet no_anchor[] = {
        T(1, SEEK_CACHE_VIDEO, 90000, SEEK_CACHE_NOPTS, 3000, 0),
        T(2, SEEK_CACHE_AUDIO, 90000, SEEK_CACHE_NOPTS, 1920, 0),
        T(3, SEEK_CACHE_VIDEO, 180000, SEEK_CACHE_NOPTS, 3000, 1),
        T(4, SEEK_CACHE_AUDIO, 176000, SEEK_CACHE_NOPTS, 1920, 0),
    };
    struct seek_cache_plan p;
    assert(!seek_cache_select(no_target, 4, 90000, 175000, &p));
    assert(!seek_cache_select(no_anchor, 4, 90000, 175000, &p));
}

static void test_backward_unknown_time_and_bad_order_miss(void)
{
    struct seek_cache_plan p;
    const struct seek_cache_packet backward[] = {
        T(1, SEEK_CACHE_VIDEO, 90000, SEEK_CACHE_NOPTS, 3000, 1),
        T(2, SEEK_CACHE_AUDIO, 90000, SEEK_CACHE_NOPTS, 1920, 0),
    };
    const struct seek_cache_packet unknown[] = {
        T(1, SEEK_CACHE_VIDEO, SEEK_CACHE_NOPTS, SEEK_CACHE_NOPTS, 3000, 1),
        T(2, SEEK_CACHE_AUDIO, 90000, SEEK_CACHE_NOPTS, 1920, 0),
    };
    const struct seek_cache_packet unordered[] = {
        T(1, SEEK_CACHE_VIDEO, 90000, SEEK_CACHE_NOPTS, 3000, 0),
        T(2, SEEK_CACHE_AUDIO, 90000, SEEK_CACHE_NOPTS, 1920, 0),
        T(3, SEEK_CACHE_VIDEO, 180000, SEEK_CACHE_NOPTS, 3000, 1),
        T(4, SEEK_CACHE_AUDIO, 89000, SEEK_CACHE_NOPTS, 1920, 0),
    };
    assert(!seek_cache_select(backward, 2, 100000, 90000, &p));
    assert(!seek_cache_select(unknown, 2, 80000, 100000, &p));
    assert(!seek_cache_select(unordered, 4, 80000, 170000, &p));
}

static void test_dts_fallback(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, SEEK_CACHE_NOPTS, 90000, 90000, 0),
        T(2, SEEK_CACHE_AUDIO, SEEK_CACHE_NOPTS, 90000, 90000, 0),
        T(3, SEEK_CACHE_VIDEO, SEEK_CACHE_NOPTS, 180000, 90000, 1),
        T(4, SEEK_CACHE_AUDIO, SEEK_CACHE_NOPTS, 180000, 90000, 0),
        T(5, SEEK_CACHE_VIDEO, SEEK_CACHE_NOPTS, 270000, 90000, 0),
        T(6, SEEK_CACHE_AUDIO, SEEK_CACHE_NOPTS, 270000, 90000, 0),
    };
    struct seek_cache_plan p;
    assert(seek_cache_select(q, 6, 90000, 170000, &p));
    assert(p.video_cut_seq == 3 && p.audio_cut_seq == 4);
    assert(p.anchor_pts90 == 180000 && p.overshoot90 == 10000);
    assert(p.envelope_start90 == 180000 && p.envelope_end90 == 360000);
}

static void test_overshoot_gaps_unknown_duration_and_missing_audio(void)
{
    struct seek_cache_plan p;
    const struct seek_cache_packet far_idr[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 91001, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 91001, 0),
        T(3, SEEK_CACHE_VIDEO, 91001, SEEK_CACHE_NOPTS, 10000, 1),
        T(4, SEEK_CACHE_AUDIO, 91001, SEEK_CACHE_NOPTS, 10000, 0),
        T(5, SEEK_CACHE_VIDEO, 101001, SEEK_CACHE_NOPTS, 10000, 0),
        T(6, SEEK_CACHE_AUDIO, 101001, SEEK_CACHE_NOPTS, 10000, 0),
    };
    const struct seek_cache_packet video_gap[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(3, SEEK_CACHE_VIDEO, 200000, SEEK_CACHE_NOPTS, 100000, 1),
        T(4, SEEK_CACHE_AUDIO, 100000, SEEK_CACHE_NOPTS, 100000, 0),
        T(5, SEEK_CACHE_VIDEO, 300000, SEEK_CACHE_NOPTS, 100000, 0),
        T(6, SEEK_CACHE_AUDIO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
    };
    const struct seek_cache_packet unknown_duration[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, SEEK_CACHE_NOPTS, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(3, SEEK_CACHE_VIDEO, 100000, SEEK_CACHE_NOPTS, 100000, 1),
        T(4, SEEK_CACHE_AUDIO, 100000, SEEK_CACHE_NOPTS, 100000, 0),
        T(5, SEEK_CACHE_VIDEO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
        T(6, SEEK_CACHE_AUDIO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
    };
    const struct seek_cache_packet no_audio[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(2, SEEK_CACHE_VIDEO, 100000, SEEK_CACHE_NOPTS, 100000, 1),
        T(3, SEEK_CACHE_VIDEO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
    };
    assert(!seek_cache_select(far_idr, 6, 0, 1000, &p));
    assert(!seek_cache_select(video_gap, 6, 0, 150000, &p));
    assert(!seek_cache_select(unknown_duration, 6, 0, 50000, &p));
    assert(!seek_cache_select(no_audio, 3, 0, 50000, &p));
}

static void test_negative_pts_and_timestamp_overflow(void)
{
    struct seek_cache_plan p;
    const struct seek_cache_packet negative[] = {
        T(1, SEEK_CACHE_VIDEO, -100000, -100000, 200000, 0),
        T(2, SEEK_CACHE_AUDIO, -100000, -100000, 200000, 0),
        T(3, SEEK_CACHE_VIDEO, 100000, 100000, 10000, 1),
        T(4, SEEK_CACHE_AUDIO, 100000, 100000, 10000, 0),
        T(5, SEEK_CACHE_VIDEO, 110000, 110000, 10000, 0),
        T(6, SEEK_CACHE_AUDIO, 110000, 110000, 10000, 0),
    };
    const struct seek_cache_packet overflow[] = {
        T(1, SEEK_CACHE_VIDEO, INT64_MAX - 100, INT64_MAX - 100, 200, 1),
        T(2, SEEK_CACHE_AUDIO, 0, 0, 10000, 0),
    };
    assert(seek_cache_select(negative, 6, 0, 50000, &p));
    assert(p.anchor_pts90 == 100000 && p.envelope_start90 == 100000);
    assert(!seek_cache_select(overflow, 2, 0, 1, &p));
}

static void test_pre_idr_b_frame_cannot_fill_retained_gap(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 0, 0, 100000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, 0, 100000, 0),
        T(3, SEEK_CACHE_VIDEO, 200000, 100000, 100000, 0), /* pre-IDR B-frame */
        T(4, SEEK_CACHE_AUDIO, 100000, 100000, 100000, 0),
        T(5, SEEK_CACHE_VIDEO, 100000, 200000, 100000, 1),
        T(6, SEEK_CACHE_AUDIO, 200000, 200000, 100000, 0),
        T(7, SEEK_CACHE_VIDEO, 300000, 300000, 100000, 0),
        T(8, SEEK_CACHE_AUDIO, 300000, 300000, 100000, 0),
    };
    struct seek_cache_plan p;
    /* The discarded pre-IDR packet makes the original PTS envelope look
     * continuous, but retained packets have a 100k-tick video gap. */
    assert(!seek_cache_select(q, 8, 0, 100000, &p));
}

static void test_reordered_b_frame_pts_with_monotonic_dts_hits(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 0, 0, 10000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, 0, 10000, 0),
        T(3, SEEK_CACHE_VIDEO, 30000, 10000, 10000, 0), /* B-frame PTS reorder */
        T(4, SEEK_CACHE_AUDIO, 10000, 10000, 10000, 0),
        T(5, SEEK_CACHE_VIDEO, 10000, 20000, 10000, 0),
        T(6, SEEK_CACHE_AUDIO, 20000, 20000, 10000, 0),
        T(7, SEEK_CACHE_VIDEO, 20000, 30000, 10000, 1),
        T(8, SEEK_CACHE_AUDIO, 30000, 30000, 10000, 0),
        T(9, SEEK_CACHE_VIDEO, 40000, 40000, 10000, 0),
        T(10, SEEK_CACHE_AUDIO, 40000, 40000, 10000, 0),
    };
    struct seek_cache_plan p;
    assert(seek_cache_select(q, 10, 0, 15000, &p));
    assert(p.video_cut_seq == 7 && p.audio_cut_seq == 6);
    assert(p.anchor_pts90 == 20000 && p.overshoot90 == 5000);
}

static void test_reordered_b_frame_pts_without_dts_hits(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 10000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 10000, 0),
        T(3, SEEK_CACHE_VIDEO, 30000, SEEK_CACHE_NOPTS, 10000, 0),
        T(4, SEEK_CACHE_AUDIO, 10000, SEEK_CACHE_NOPTS, 10000, 0),
        T(5, SEEK_CACHE_VIDEO, 10000, SEEK_CACHE_NOPTS, 10000, 0),
        T(6, SEEK_CACHE_AUDIO, 20000, SEEK_CACHE_NOPTS, 10000, 0),
        T(7, SEEK_CACHE_VIDEO, 20000, SEEK_CACHE_NOPTS, 10000, 1),
        T(8, SEEK_CACHE_AUDIO, 30000, SEEK_CACHE_NOPTS, 10000, 0),
        T(9, SEEK_CACHE_VIDEO, 40000, SEEK_CACHE_NOPTS, 10000, 0),
        T(10, SEEK_CACHE_AUDIO, 40000, SEEK_CACHE_NOPTS, 10000, 0),
    };
    struct seek_cache_plan p;
    assert(seek_cache_select(q, 10, 0, 15000, &p));
    assert(p.video_cut_seq == 7 && p.audio_cut_seq == 6);
    assert(p.anchor_pts90 == 20000 && p.overshoot90 == 5000);
}

static void test_nearest_prior_idr_hits(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(3, SEEK_CACHE_VIDEO, 100000, SEEK_CACHE_NOPTS, 100000, 1),
        T(4, SEEK_CACHE_AUDIO, 100000, SEEK_CACHE_NOPTS, 100000, 0),
        T(5, SEEK_CACHE_VIDEO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
        T(6, SEEK_CACHE_AUDIO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
    };
    struct seek_cache_plan p;
    assert(seek_cache_select(q, 6, 50000, 175000, &p));
    assert(p.video_cut_seq == 3 && p.audio_cut_seq == 4);
    assert(p.anchor_pts90 == 100000 && p.overshoot90 == -75000);
    /* A buffered jump must advance the actual picture, not merely the target. */
    assert(!seek_cache_select(q, 6, 100000, 175000, &p));
    /* A prior IDR alone cannot justify a target beyond retained coverage. */
    struct seek_cache_packet short_queue[] = {
        T(1, SEEK_CACHE_VIDEO, 100000, SEEK_CACHE_NOPTS, 10000, 1),
        T(2, SEEK_CACHE_AUDIO, 100000, SEEK_CACHE_NOPTS, 10000, 0),
        T(3, SEEK_CACHE_VIDEO, 110000, SEEK_CACHE_NOPTS, 10000, 0),
        T(4, SEEK_CACHE_AUDIO, 110000, SEEK_CACHE_NOPTS, 10000, 0),
    };
    assert(!seek_cache_select(short_queue, 4, 50000, 150000, &p));
}

static void test_closer_after_idr_wins(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(3, SEEK_CACHE_VIDEO, 100000, SEEK_CACHE_NOPTS, 100000, 1),
        T(4, SEEK_CACHE_AUDIO, 100000, SEEK_CACHE_NOPTS, 100000, 0),
        T(5, SEEK_CACHE_VIDEO, 200000, SEEK_CACHE_NOPTS, 100000, 1),
        T(6, SEEK_CACHE_AUDIO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
        T(7, SEEK_CACHE_VIDEO, 300000, SEEK_CACHE_NOPTS, 100000, 0),
        T(8, SEEK_CACHE_AUDIO, 300000, SEEK_CACHE_NOPTS, 100000, 0),
    };
    struct seek_cache_plan p;
    assert(seek_cache_select(q, 8, 50000, 180000, &p));
    assert(p.video_cut_seq == 5 && p.audio_cut_seq == 6);
    assert(p.anchor_pts90 == 200000 && p.overshoot90 == 20000);
}

static void test_prior_idr_outside_window_misses(void)
{
    const struct seek_cache_packet q[] = {
        T(1, SEEK_CACHE_VIDEO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(2, SEEK_CACHE_AUDIO, 0, SEEK_CACHE_NOPTS, 100000, 0),
        T(3, SEEK_CACHE_VIDEO, 100000, SEEK_CACHE_NOPTS, 100000, 1),
        T(4, SEEK_CACHE_AUDIO, 100000, SEEK_CACHE_NOPTS, 100000, 0),
        T(5, SEEK_CACHE_VIDEO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
        T(6, SEEK_CACHE_AUDIO, 200000, SEEK_CACHE_NOPTS, 100000, 0),
    };
    struct seek_cache_plan p;
    assert(!seek_cache_select(q, 6, 50000, 200001, &p));
}

int main(void)
{
    test_next_confirmed_idr_and_audio_overlap();
    test_key_flag_without_confirmed_idr_misses();
    test_audio_must_cover_target_and_anchor();
    test_backward_unknown_time_and_bad_order_miss();
    test_dts_fallback();
    test_overshoot_gaps_unknown_duration_and_missing_audio();
    test_reordered_b_frame_pts_with_monotonic_dts_hits();
    test_reordered_b_frame_pts_without_dts_hits();
    test_negative_pts_and_timestamp_overflow();
    test_pre_idr_b_frame_cannot_fill_retained_gap();
    test_nearest_prior_idr_hits();
    test_closer_after_idr_wins();
    test_prior_idr_outside_window_misses();
    puts("seek_cache tests passed");
    return 0;
}
