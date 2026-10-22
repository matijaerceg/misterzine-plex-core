/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 Matija Erceg
 *
 * Clock conversion helpers for PAL film speed-up and fractional NTSC
 * slowdown. All public positions remain in source-film seconds.
 */
#ifndef JFPLAY_FILM_SPEED_H
#define JFPLAY_FILM_SPEED_H

#include <stdint.h>

struct film_speed {
    int enabled;
    int scale_num; /* source clock -> output clock */
    int scale_den;
};

/* Only the two common film rates qualify. A 25 fps source must pass through
 * unchanged, which prevents the frequent double-speed-up failure. */
static inline struct film_speed film_speed_select(int enabled, int mains_hz,
                                                  int fps_num, int fps_den)
{
    struct film_speed s = {0, 1, 1};
    if (enabled && mains_hz == 50 && fps_num > 0 && fps_den > 0 &&
        ((fps_num == 24000 && fps_den == 1001) ||
         ((int64_t)fps_num == (int64_t)24 * fps_den))) {
        s.enabled = 1;
        int fractional = fps_num == 24000 && fps_den == 1001;
        s.scale_num = fractional ? 960 : 24;
        s.scale_den = fractional ? 1001 : 25;
    }
    return s;
}

/* Exact 24/30/60 fps material uses the fractional NTSC clock when output uses
 * the NTSC family: on fitted 480-line profiles, or when refresh matching
 * selects NTSC rates. PAL film speed-up is only available on fixed-50-Hz PAL
 * profiles. Output policy is sampled when opening the stream. */
static inline struct film_speed playback_speed_select(int film_requested,
                                                       unsigned profile,
                                                       int match_refresh,
                                                       int fps_num, int fps_den)
{
    int pal_profile = profile == 2 || profile == 3;
    /* 24 -> 25 is only a fixed-50-Hz option on the two PAL profiles. */
    struct film_speed s = film_speed_select(film_requested && pal_profile &&
                                            match_refresh == 0,
                                            50, fps_num, fps_den);
    if (s.enabled || fps_num <= 0 || fps_den <= 0) return s;
    if (profile == 4) return s;
    if ((!pal_profile || match_refresh) &&
        ((int64_t)fps_num == 24LL * fps_den ||
         (int64_t)fps_num == 30LL * fps_den ||
         (int64_t)fps_num == 60LL * fps_den)) {
        s.enabled = 1;
        s.scale_num = 1001;
        s.scale_den = 1000;
    }
    return s;
}

/* Source timeline PTS -> output timeline PTS, relative to the same origin.
 * The selected ratio converts only the playback clock; status retains the
 * original source timestamp. */
static inline int64_t film_speed_pts90(struct film_speed s, int64_t source90)
{
    int64_t q, r, whole, part;
    if (!s.enabled) return source90;
    q = source90 / s.scale_den;
    r = source90 % s.scale_den;
    if (q > INT64_MAX / s.scale_num) return INT64_MAX;
    if (q < INT64_MIN / s.scale_num) return INT64_MIN;
    whole = q * s.scale_num;
    part = (r * s.scale_num + (r >= 0 ? s.scale_den / 2 : -s.scale_den / 2)) /
           s.scale_den;
    if (part > 0 && whole > INT64_MAX - part) return INT64_MAX;
    if (part < 0 && whole < INT64_MIN - part) return INT64_MIN;
    return whole + part;
}

/* Output elapsed seconds -> source elapsed seconds. User seek positions
 * already use source-film time and must NOT pass through this conversion. */
static inline double film_speed_seek_seconds(struct film_speed s,
                                             double output_seconds)
{
    return s.enabled ? output_seconds * s.scale_den / s.scale_num :
                       output_seconds;
}

/* Output PCM sample rate for SwrContext when its samples are consumed at
 * 48 kHz. This changes audio duration by the video clock ratio (rounded to
 * 1 Hz); pitch follows playback speed without another processing dependency. */
static inline int film_speed_audio_rate(struct film_speed s, int device_rate)
{
    if (!s.enabled || device_rate <= 0) return device_rate;
    return (device_rate * s.scale_num + s.scale_den / 2) / s.scale_den;
}

static inline int64_t film_speed_source_pts90(struct film_speed s,
                                               int64_t output90)
{
    int64_t q, r, whole, part;
    if (!s.enabled) return output90;
    q = output90 / s.scale_num;
    r = output90 % s.scale_num;
    if (q > INT64_MAX / s.scale_den) return INT64_MAX;
    if (q < INT64_MIN / s.scale_den) return INT64_MIN;
    whole = q * s.scale_den;
    part = (r * s.scale_den + (r >= 0 ? s.scale_num / 2 : -s.scale_num / 2)) /
           s.scale_num;
    if (part > 0 && whole > INT64_MAX - part) return INT64_MAX;
    if (part < 0 && whole < INT64_MIN - part) return INT64_MIN;
    return whole + part;
}

/* Convert output/playback time back to the original film timeline for the
 * player status/progress position. */
static inline double film_speed_original_seconds(struct film_speed s,
                                                 double output_seconds)
{
    return film_speed_seek_seconds(s, output_seconds);
}

#endif
