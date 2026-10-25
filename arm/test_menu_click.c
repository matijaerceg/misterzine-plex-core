/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "menu_click.h"

int main(void)
{
    static struct menu_click_bank bank;
    menu_click_build(&bank);
    for (unsigned note = 0; note < MENU_CLICK_PITCHES; ++note) {
        const int16_t *pcm = bank.pcm[1][note];
        long energy = 0;
        assert(pcm[0] == 0 && pcm[(MENU_CLICK_FRAMES-1)*2] == 0);
        for (unsigned i = 0; i < MENU_CLICK_FRAMES; ++i) {
            int value = pcm[i * 2];
            int quiet = bank.pcm[0][note][i * 2];
            assert(value == pcm[i * 2 + 1]);
            assert(value >= -1600 && value <= 1600);
            assert(quiet == bank.pcm[0][note][i * 2 + 1]);
            assert(quiet == lrint(value * 0.5));
            assert(quiet >= -800 && quiet <= 800);
            energy += value < 0 ? -value : value;
        }
        assert(energy > 200000 && energy < 450000);
        if (note) assert(memcmp(pcm, bank.pcm[1][note - 1], MENU_CLICK_FRAMES * 4));
    }
    assert(fabs(menu_click_frequency(2) - 350) < 0.00001);
    assert(fabs(menu_click_frequency(MENU_CLICK_NOTES + 69 - MENU_CLICK_MIDI_FIRST) - 440) < 0.00001);
    assert(fabs(menu_click_frequency(MENU_CLICK_NOTES + 81 - MENU_CLICK_MIDI_FIRST) - 880) < 0.00001);
    for (unsigned octave = 0; octave < 2; ++octave) {
        unsigned pitch = MENU_CLICK_NOTES + 69 + octave * 12 - MENU_CLICK_MIDI_FIRST;
        unsigned crossings = 0;
        int last_sign = 0;
        for (unsigned i = 0; i < MENU_CLICK_FRAMES; ++i) {
            int value = bank.pcm[1][pitch][i * 2];
            if (!value) continue;
            int sign = value > 0 ? 1 : -1;
            if (last_sign && last_sign != sign) ++crossings;
            last_sign = sign;
        }
        /* Rounding the faded tail to silence may remove the final crossing. */
        assert(crossings >= (octave ? 48u : 23u) && crossings <= (octave ? 49u : 24u));
    }
    uint32_t random = 1234;
    int previous = -1;
    unsigned seen = 0;
    for (unsigned i = 0; i < 10000; ++i) {
        unsigned note = menu_click_note(&random, previous);
        assert(note < MENU_CLICK_NOTES && (int)note != previous);
        seen |= 1u << note;
        previous = (int)note;
    }
    assert(seen == 31);
    struct menu_click_input input = {0};
    assert(!menu_click_input_feed(&input, "ta", 2));
    assert(menu_click_input_feed(&input, "p\ntap\n", 6) == 1);
    assert(!menu_click_input_feed(&input, "bad\ntapx\n\n", 10));
    for (unsigned i = 0; i < 100000; ++i)
        assert(!menu_click_input_feed(&input, "x", 1));
    assert(!menu_click_input_feed(&input, "\n", 1));
    assert(menu_click_input_feed(&input, "tap\n", 4));
    assert(input.command.level == 2 && input.command.midi == 0);
    const char *valid[] = {"tap 1 0\n", "tap 2 0\n", "tap 1 48\n", "tap 2 96\n", "tap 1 69\n"};
    const unsigned levels[] = {1, 2, 1, 2, 1}, notes[] = {0, 0, 48, 96, 69};
    for (unsigned i = 0; i < sizeof valid / sizeof valid[0]; ++i) {
        assert(menu_click_input_feed(&input, valid[i], strlen(valid[i])));
        assert(input.command.level == levels[i] && input.command.midi == notes[i]);
    }
    const char *invalid[] = {"tap 0 69\n", "tap 3 69\n", "tap 1 47\n", "tap 2 97\n", "tap 1 00\n",
        "tap 1 -1\n", "tap 1 1\n", "tap 1 960\n", "tap 1 69x\n", "tap 1 69 \n", "tap 1\n",
        "tap 1 x9\n", "tap 1 6x\n", "tap\r\n", "tap  1 69\n", "tap 1\t69\n"};
    for (unsigned i = 0; i < sizeof invalid / sizeof invalid[0]; ++i)
        assert(!menu_click_input_feed(&input, invalid[i], strlen(invalid[i])));
    /* Fragmented commands and batches preserve the latest complete valid tap. */
    assert(!menu_click_input_feed(&input, "tap 1 6", 7));
    assert(menu_click_input_feed(&input, "9\ntap 2 72\nbad\n", 15));
    assert(input.command.level == 2 && input.command.midi == 72);
    assert(menu_click_input_feed(&input, "ton 1 69\n", 9));
    assert(input.command.kind == 1 && input.command.midi == 69);
    assert(menu_click_input_feed(&input, "end\n", 4));
    assert(input.command.kind == 2);
    assert(!menu_click_input_feed(&input, "ton\nton 1 0\nton 2 97\n", 21));
    puts("menu click waveform and input tests passed");
    return 0;
}
