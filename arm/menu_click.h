/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_MENU_CLICK_H
#define JFPLAY_MENU_CLICK_H
#include <math.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define MENU_CLICK_FRAMES 1344
#define MENU_CLICK_NOTES 5
#define MENU_CLICK_MIDI_FIRST 48
#define MENU_CLICK_MIDI_LAST 96
#define MENU_CLICK_PITCHES (MENU_CLICK_NOTES + MENU_CLICK_MIDI_LAST - MENU_CLICK_MIDI_FIRST + 1)

struct menu_click_bank {
    /* Quiet and Loud; five random variants followed by MIDI 48 through 96. */
    int16_t pcm[2][MENU_CLICK_PITCHES][MENU_CLICK_FRAMES * 2];
};

static inline double menu_click_frequency(unsigned pitch)
{
    if (pitch < MENU_CLICK_NOTES)
        return 350.0 * pow(2.0, ((int)pitch - 2) * 0.5 / 12.0);
    return 440.0 * pow(2.0, ((int)pitch - MENU_CLICK_NOTES + MENU_CLICK_MIDI_FIRST - 69) / 12.0);
}

/* Twenty-eight milliseconds, with a soft attack and a tail that reaches zero.
 * Half-semitone steps cover one semitone either side of the centre pitch. */
static inline void menu_click_build(struct menu_click_bank *bank)
{
    for (unsigned note = 0; note < MENU_CLICK_PITCHES; ++note) {
        double frequency = menu_click_frequency(note);
        for (int i = 0; i < MENU_CLICK_FRAMES; ++i) {
            double envelope = (1.0 - exp(-i / 24.0)) * exp(-i / 384.0);
            if (i > 1200) envelope *= (1343 - i) / 143.0;
            int16_t sample = (int16_t)lrint(1600.0 * envelope *
                sin(2.0 * 3.141592653589793 * frequency * i / 48000.0));
            bank->pcm[1][note][2 * i] = bank->pcm[1][note][2 * i + 1] = sample;
            /* Round half the approved sample to the nearest integer, rather
             * than synthesizing again on each navigation event. */
            int16_t quiet = (int16_t)lrint(sample * 0.5);
            bank->pcm[0][note][2 * i] = bank->pcm[0][note][2 * i + 1] = quiet;
        }
    }
}

/* Small local PRNG; no repeat at a boundary between clicks. */
static inline unsigned menu_click_note(uint32_t *random, int previous)
{
    *random = *random * 1664525u + 1013904223u;
    unsigned note = (*random >> 16) % (previous < 0 ? 5u : 4u);
    if (previous >= 0 && note >= (unsigned)previous) ++note;
    return note;
}

/* kind: 0 short click, 1 sustained tone, 2 release. */
struct menu_click_command { unsigned level, midi, kind; };
struct menu_click_input {
    unsigned length;
    int invalid;
    char line[8];
    struct menu_click_command command;
};

/* Grammar: tap, tap LEVEL MIDI, ton LEVEL MIDI, or end.
 * Levels 1/2 select Quiet/Loud; ton requires a nonzero fixed pitch.
 * MIDI 0 keeps the random click, otherwise a generic MIDI 48..96 pitch.
 * No sequence or melody belongs to the worker protocol. */
static inline int menu_click_parse(struct menu_click_input *input)
{
    if (input->invalid || input->length < 3) return 0;
    if (input->length == 3 && !memcmp(input->line, "end", 3)) {
        input->command = (struct menu_click_command){0, 0, 2};
        return 1;
    }
    unsigned kind = !memcmp(input->line, "ton", 3);
    if (!kind && memcmp(input->line, "tap", 3)) return 0;
    struct menu_click_command command = {2, 0, kind};
    if (input->length != 3) {
        if ((input->length != 7 && input->length != 8) || input->line[3] != ' ' ||
            (input->line[4] != '1' && input->line[4] != '2') || input->line[5] != ' ') return 0;
        command.level = (unsigned)(input->line[4] - '0');
        if (input->length == 7) {
            if (input->line[6] != '0') return 0;
        } else {
            if (input->line[6] < '0' || input->line[6] > '9' ||
                input->line[7] < '0' || input->line[7] > '9') return 0;
            command.midi = (unsigned)((input->line[6] - '0') * 10 + input->line[7] - '0');
            if (command.midi < MENU_CLICK_MIDI_FIRST || command.midi > MENU_CLICK_MIDI_LAST) return 0;
        }
    }
    if (kind && !command.midi) return 0;
    input->command = command;
    return 1;
}

/* Coalesce a batch to one tap; malformed/long lines consume no extra memory. */
static inline int menu_click_input_feed(struct menu_click_input *input,
                                       const char *bytes, size_t count)
{
    int tap = 0;
    for (size_t i = 0; i < count; ++i) {
        char c = bytes[i];
        if (c == '\n') {
            tap |= menu_click_parse(input);
            input->length = 0;
            input->invalid = 0;
        } else if (input->length < sizeof input->line) {
            input->line[input->length++] = c;
        } else {
            input->invalid = 1;
        }
    }
    return tap;
}
#endif
