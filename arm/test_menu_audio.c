/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Run the actual worker loop against a deterministic clock and fake core.
 * This exercises handoff and failure paths without /dev/mem or speakers. */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "menu_click.h"

typedef struct { int unused; } h264ring;
struct player { struct { const char *core_name; } cfg; struct { const char *app_name; } core_owner; h264ring *ring; int core_owned; atomic_int stop, exit_code; };
struct h264ring_status { uint32_t AUD_PLAYED, ERR; };
#define H264RING_ST(st, field) ((st)->field)
enum { EX_OK, EX_CORE, EX_OPEN };
static volatile sig_atomic_t caught_signal;
static h264ring ring;
static uint64_t clock_ms, eof_at, lose_at, reset_at, finish_at;
static uint32_t played;
static unsigned writes, ready_lines, closes, commands, opens;
static int16_t captured[256][MENU_CLICK_FRAMES * 2];
static unsigned pending_writes;
static uint64_t last_write_at;
static int stalled, wrong_core;
static unsigned frames[256], completed;
static int theme_test;
struct command { uint64_t at; const char *text; };
static struct command script[8];

static uint64_t mono_ms(void) { return clock_ms; }
static void signal_handler(int sig) { (void)sig; caught_signal = 1; }
static int core_name_matches(const struct player *p) { assert(p->cfg.core_name && !strcmp(p->cfg.core_name, "Example Core")); assert(p->core_owner.app_name == p->cfg.core_name); return !wrong_core; }
static int core_owner_ok(struct player *p) { return p->core_owned && clock_ms < lose_at; }
static int h264ring_open_devmem(h264ring **out, unsigned flags)
{ (void)flags; ++opens; *out = &ring; return 0; }
static int h264ring_alive(h264ring *r, unsigned timeout)
{ (void)r; (void)timeout; return 0; }
static int h264ring_start_session(h264ring *r, unsigned timeout)
{ (void)r; (void)timeout; return 0; }
static int h264ring_session_ok(h264ring *r)
{ (void)r; return clock_ms < reset_at; }
static int h264ring_status(h264ring *r, struct h264ring_status *st)
{
    (void)r;
    while (finish_at && clock_ms >= finish_at && !stalled) {
        played += frames[completed++];
        --pending_writes;
        finish_at = pending_writes ? finish_at + frames[completed] / 48 : 0;
    }
    st->AUD_PLAYED = played;
    st->ERR = 0;
    return 0;
}
static int h264ring_try_write_audio(h264ring *r, const void *bytes, uint32_t len, int64_t pts)
{
    (void)r;
    assert(clock_ms < lose_at && clock_ms < reset_at);
    assert((len == MENU_CLICK_FRAMES * 4 || len == 960) && pts == -1);
    if (!writes) {
        const int16_t *pcm = bytes;
        for (unsigned i = 0; i < MENU_CLICK_FRAMES * 2; ++i) assert(pcm[i] == 0);
    } else assert(ready_lines == 1);
    assert(writes < 256);
    memcpy(captured[writes], bytes, len);
    frames[writes] = len / 4;
    if (!finish_at) finish_at = clock_ms + (writes ? len / 192 : 1000);
    ++pending_writes;
    last_write_at = clock_ms;
    ++writes;
    return 0;
}
static void h264ring_close(h264ring *r) { (void)r; ++closes; }
static int fake_poll(struct pollfd *fds, nfds_t n, int timeout)
{ (void)fds; (void)n; clock_ms += (unsigned)timeout; return 0; }
static ssize_t fake_read(int fd, void *bytes, size_t size)
{
    if (fd == 3 && theme_test) {
        if (clock_ms < 1250) {
            int16_t *pcm = bytes;
            for (size_t i = 0; i < size / 2; ++i) pcm[i] = 1000;
            return (ssize_t)size;
        }
        errno = EAGAIN;
        return -1;
    }
    if (clock_ms >= eof_at) return 0;
    if (commands < 8 && script[commands].text && clock_ms >= script[commands].at) {
        size_t n = strlen(script[commands].text);
        assert(n <= size);
        memcpy(bytes, script[commands++].text, n);
        return (ssize_t)n;
    }
    errno = EAGAIN;
    return -1;
}
static int fake_fcntl(int fd, int op, ...)
{ (void)fd; (void)op; return 0; }
static int fake_puts(const char *text)
{ assert(!strcmp(text, "ready")); ++ready_lines; return 0; }
static int fake_fflush(FILE *file) { (void)file; return 0; }
#define poll fake_poll
#define read fake_read
#define fcntl fake_fcntl
#define puts fake_puts
#define fflush fake_fflush
#include "menu_audio.h"
#undef puts

static void reset(void)
{
    clock_ms = finish_at = played = 0;
    pending_writes = last_write_at = 0;
    eof_at = 2000;
    lose_at = reset_at = UINT64_MAX;
    writes = ready_lines = closes = commands = opens = 0;
    caught_signal = stalled = wrong_core = 0;
    completed = 0;
    theme_test = 0;
    unsetenv("MZ_MENU_PCM_FD");
    memset(script, 0, sizeof script);
    memset(captured, 0, sizeof captured);
}

int main(void)
{
    struct menu_tone tone = {.midi = 69, .level = 2};
    int16_t pcm[MENU_CLICK_FRAMES * 2];
    menu_tone_render(&tone, pcm);
    double phase = tone.phase;
    assert(tone.gain == 1400);
    menu_tone_render(&tone, pcm);
    assert(pcm[0] == (int16_t)lrint(1400 * sin(phase)));
    tone.midi = 72;
    phase = tone.phase;
    menu_tone_render(&tone, pcm);
    assert(pcm[0] == (int16_t)lrint(1400 * sin(phase)));
    tone.midi = 0;
    menu_tone_render(&tone, pcm);
    assert(tone.gain == 0 && pcm[MENU_CLICK_FRAMES*2-1] == 0);
    reset();
    script[0] = (struct command){100, "tap\ntap\n"};
    script[1] = (struct command){1040, "tap\ntap\ntap\n"};
    script[2] = (struct command){1045, "tap\n"};
    script[3] = (struct command){1160, "tap\n"};
    assert(menu_audio_main("Example Core") == EX_OK);
    assert(writes == 3 && ready_lines == 1 && closes == 1);
    reset();
    script[0] = (struct command){1040, "tap 1 69\n"};
    script[1] = (struct command){1160, "tap 2 69\n"};
    script[2] = (struct command){1280, "tap 0 69\ntap 1 97\n"};
    assert(menu_audio_main("Example Core") == EX_OK);
    assert(writes == 3 && ready_lines == 1 && closes == 1);
    static struct menu_click_bank expected;
    menu_click_build(&expected);
    unsigned pitch = MENU_CLICK_NOTES + 69 - MENU_CLICK_MIDI_FIRST;
    assert(!memcmp(captured[1], expected.pcm[0][pitch], sizeof captured[1]));
    assert(!memcmp(captured[2], expected.pcm[1][pitch], sizeof captured[2]));
    reset();
    eof_at = 5;
    assert(menu_audio_main("Example Core") == EX_OK);
    assert(clock_ms == 5 && writes == 1 && !ready_lines && closes == 1);
    reset();
    stalled = 1;
    assert(menu_audio_main("Example Core") == EX_CORE);
    assert(clock_ms == 1800 && !ready_lines && writes == 1);
    reset();
    lose_at = 1100;
    assert(menu_audio_main("Example Core") == EX_CORE);
    assert(!closes && writes == 1 && clock_ms <= 1140);
    reset();
    reset_at = 1100;
    assert(menu_audio_main("Example Core") == EX_CORE);
    assert(!closes && writes == 1 && clock_ms <= 1140);
    reset();
    wrong_core = 1;
    assert(menu_audio_main("Example Core") == EX_CORE);
    assert(!opens && !writes);
    reset();
    script[0] = (struct command){1040, "ton 2 69\n"};
    script[1] = (struct command){1120, "ton 1 72\n"};
    script[2] = (struct command){1200, "end\n"};
    assert(menu_audio_main("Example Core") == EX_OK);
    assert(writes > 5 && last_write_at < 1290 && pending_writes == 0);
    for (unsigned i = 672; i < MENU_CLICK_FRAMES * 2; ++i) assert(captured[writes-1][i] == 0);
    reset();
    script[0] = (struct command){1040, "ton 2 69\n"};
    assert(menu_audio_main("Example Core") == EX_OK);
    assert(writes > 20 && last_write_at < 1780 && pending_writes == 0);
    reset();
    script[0] = (struct command){1040, "ton 2 69\n"};
    lose_at = 1200;
    assert(menu_audio_main("Example Core") == EX_CORE);
    assert(!closes && last_write_at < lose_at);
    reset();
    theme_test = 1;
    setenv("MZ_MENU_PCM_FD", "3", 1);
    script[0] = (struct command){1100, "tap 2 69\n"};
    assert(menu_audio_main("Example Core") == EX_OK);
    assert(writes > 30 && last_write_at < 1300 && pending_writes == 0);
    int heard_theme = 0, heard_click = 0;
    for (unsigned w = 1; w < writes; ++w) {
        assert(frames[w] == 240);
        for (unsigned i = 0; i < 480; ++i) {
            heard_theme |= captured[w][i] == 1000;
            heard_click |= captured[w][i] != 1000;
        }
    }
    assert(heard_theme && heard_click);
    puts("menu audio lifecycle tests passed");
    return 0;
}
