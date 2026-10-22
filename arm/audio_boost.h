/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef MISTERZINE_AUDIO_BOOST_H
#define MISTERZINE_AUDIO_BOOST_H

#include <stdint.h>

/* Apply the configured surround gain with a soft ceiling before S16 output. */
static inline int16_t audio_boost_sample(int16_t sample, int percent)
{
    const double knee = 26213.0;
    const double span = 32767.0 - knee;
    double x = (double)sample * (double)percent / 100.0;
    double mag = x < 0.0 ? -x : x;
    if (percent <= 100) return sample;
    if (mag > knee) {
        double over = mag - knee;
        mag = knee + span * (over / (span + over));
    }
    if (mag > 32767.0) mag = 32767.0;
    return (int16_t)(x < 0.0 ? -mag : mag);
}

#endif
