/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 Matija Erceg
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "film_speed.h"

int main(void)
{
    struct film_speed s;
    s = film_speed_select(1, 50, 24000, 1001);
    assert(s.enabled);
    assert(film_speed_pts90(s, 90000) == 86314);
    assert(film_speed_audio_rate(s, 48000) == 46034);
    assert(film_speed_seek_seconds(s, 100.0) > 104.27 &&
           film_speed_seek_seconds(s, 100.0) < 104.28);
    assert(film_speed_original_seconds(s, 96.0) > 100.09 &&
           film_speed_original_seconds(s, 96.0) < 100.11);

    s = film_speed_select(1, 50, 24, 1);
    assert(s.enabled && film_speed_pts90(s, 90000) == 86400);
    assert(film_speed_audio_rate(s, 48000) == 46080);
    assert(film_speed_seek_seconds(s, 96.0) == 100.0);
    s = film_speed_select(1, 50, 24000, 1000);
    assert(s.enabled && film_speed_pts90(s, 90000) == 86400);
    assert(film_speed_source_pts90(s, 86400) == 90000);

    assert(!film_speed_select(1, 60, 24, 1).enabled);
    assert(!film_speed_select(1, 50, 25, 1).enabled);
    assert(!film_speed_select(1, 50, 23976, 1000).enabled);
    assert(!film_speed_select(0, 50, 24, 1).enabled);
    s = film_speed_select(0, 50, 24, 1);
    assert(film_speed_pts90(s, 90000) == 90000);
    assert(film_speed_audio_rate(s, 48000) == 48000);
    const int exact[] = {24, 30, 60};
    for (unsigned i = 0; i < sizeof exact / sizeof exact[0]; ++i) {
        s = playback_speed_select(0, 0, 0, exact[i], 1);
        assert(s.enabled && s.scale_num == 1001 && s.scale_den == 1000);
        assert(film_speed_pts90(s, 90000) == 90090);
        assert(film_speed_source_pts90(s, 90090) == 90000);
        assert(film_speed_audio_rate(s, 48000) == 48048);
        assert(!playback_speed_select(0, 0, 0, exact[i] * 1000, 1001).enabled);
        assert(!playback_speed_select(0, 4, 1, exact[i], 1).enabled);
        assert(!playback_speed_select(0, 2, 0, exact[i], 1).enabled);
        assert(playback_speed_select(0, 2, 1, exact[i], 1).scale_num == 1001);
    }
    /* 24 -> 25 is reserved for fixed-50-Hz PAL output (profiles 2/3).
     * Matching mode keeps the source rate and uses the fitted clock policy. */
    for (unsigned profile = 2; profile <= 3; ++profile) {
        s = playback_speed_select(1, profile, 0, 24, 1);
        assert(s.enabled && s.scale_num == 24 && s.scale_den == 25);
        s = playback_speed_select(1, profile, 1, 24, 1);
        assert(s.enabled && s.scale_num == 1001 && s.scale_den == 1000);
    }
    s = playback_speed_select(1, 1, 0, 24, 1);
    assert(s.scale_num != 24 || s.scale_den != 25);
    s = playback_speed_select(1, 0, 1, 24, 1);
    assert(s.scale_num != 24 || s.scale_den != 25);
    /* Refresh matching slows exact 24/30/60 on fitted output only.
     * Fractional 23.976 and the reserved legacy mode value stay unchanged. */
    const int matched_ntsc[] = {24, 30, 60};
    for (unsigned i = 0; i < sizeof matched_ntsc / sizeof matched_ntsc[0]; ++i) {
        s = playback_speed_select(0, 1, 1, matched_ntsc[i], 1);
        assert(s.enabled && s.scale_num == 1001 && s.scale_den == 1000);
    }
    assert(!playback_speed_select(0, 1, 1, 24000, 1001).enabled);
    assert(!playback_speed_select(0, 4, 1, 24, 1).enabled);
    s = playback_speed_select(0, 2, 1, 24000, 1001);
    assert(!s.enabled);
    s = playback_speed_select(0, 1, 2, 24000, 1001);
    assert(!s.enabled);
    s = playback_speed_select(0, 1, 2, 24, 1);
    assert(s.enabled && s.scale_num == 1001 && s.scale_den == 1000);
    assert(!playback_speed_select(0, 0, 1, 25, 1).enabled);
    assert(!playback_speed_select(0, 1, 0, 0, 0).enabled);
    s = playback_speed_select(0, 1, 0, 24000, 1000);
    assert(s.scale_num == 1001);
    assert(film_speed_pts90(s, INT64_MAX) == INT64_MAX);
    assert(film_speed_pts90(s, INT64_MIN) == INT64_MIN);
    puts("film speed helpers OK");
    return 0;
}
