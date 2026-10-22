/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <stdint.h>
#include <stdio.h>
#include "audio_boost.h"

static int check(const char *name, int ok)
{
    if (!ok) fprintf(stderr, "FAIL: %s\n", name);
    return !ok;
}

int main(void)
{
    int failed = 0;
    int16_t quiet = audio_boost_sample(8000, 175);
    int16_t clipped = audio_boost_sample(30000, 300);
    int16_t negative = audio_boost_sample(-30000, 300);
    failed += check("100 percent preserves PCM", audio_boost_sample(12345, 100) == 12345);
    failed += check("175 percent raises a quiet sample", quiet > 8000);
    failed += check("300 percent is bounded below full scale", clipped > 30000 && clipped < 32767);
    failed += check("limiter is sign symmetric", negative == (int16_t)-clipped);
    int16_t minimum = audio_boost_sample(INT16_MIN, 300);
    failed += check("minimum S16 sample is compressed without wrapping",
                    minimum < 0 && minimum > INT16_MIN);
    if (!failed) puts("audio boost limiter OK");
    return failed ? 1 : 0;
}
