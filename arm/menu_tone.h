/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_MENU_TONE_H
#define JFPLAY_MENU_TONE_H
#include "menu_click.h"

struct menu_tone { unsigned midi, level; double phase, gain, step; };

/* Phase survives pitch changes. A five-millisecond ramp softens press/release;
 * adjacent chunks have neither a retriggered envelope nor a silent boundary. */
static inline void menu_tone_render(struct menu_tone *tone, int16_t *pcm)
{
    const double tau = 6.283185307179586;
    double target = tone->midi ? (tone->level == 1 ? 700.0 : 1400.0) : 0;
    double ramp = (tone->level == 1 ? 700.0 : 1400.0) / 240;
    if (tone->midi)
        tone->step = tau * 440.0 * pow(2.0, ((int)tone->midi - 69) / 12.0) / 48000.0;
    for (unsigned i = 0; i < MENU_CLICK_FRAMES; ++i) {
        double delta = target - tone->gain;
        if (delta > ramp) delta = ramp;
        if (delta < -ramp) delta = -ramp;
        tone->gain += delta;
        pcm[2*i] = pcm[2*i+1] = (int16_t)lrint(tone->gain * sin(tone->phase));
        tone->phase += tone->step;
        if (tone->phase >= tau) tone->phase -= tau;
    }
}
#endif
