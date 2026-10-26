/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_MENU_AUDIO_H
#define JFPLAY_MENU_AUDIO_H
#include <poll.h>
#include <stdlib.h>
#include "menu_click.h"
#include "menu_tone.h"

/* This mode is deliberately independent of media, FIFO and status-file setup.
 * The existing ring lock serializes it with playback. Its caller closes stdin
 * and waits for exit before starting a movie. No retries or deferred taps. */
static int menu_audio_main(const char *core_name)
{
    struct player p = {0};
    p.cfg.core_name = core_name;
    p.core_owner.app_name = core_name;
    struct menu_click_input input = {0};
    static struct menu_click_bank clicks;
    int16_t silence[MENU_CLICK_FRAMES * 2] = {0};
    int ready = 0, busy = 1, previous = -1, result = EX_CORE;
    uint32_t played = 0, random = (uint32_t)mono_ms() ^ (uint32_t)getpid();
    uint64_t deadline;
    struct menu_tone tone = {0};
    int16_t tone_pcm[MENU_CLICK_FRAMES * 2];
    uint64_t tone_until = 0, progress_deadline = 0;
    uint32_t submitted = 0, last_played = 0;
    /* An inherited pipe carries decoded theme PCM separately from commands. */
    const char *pcm_env = getenv("MZ_MENU_PCM_FD");
    int pcm_fd = pcm_env ? atoi(pcm_env) : -1;
    if (pcm_fd >= 3) {
        int f = fcntl(pcm_fd, F_GETFL);
        if (f < 0 || fcntl(pcm_fd, F_SETFL, f | O_NONBLOCK) < 0) return EX_OPEN;
    } else pcm_fd = -1;
    int16_t theme_pcm[240 * 2], mixed_pcm[240 * 2];
    size_t theme_bytes = 0;
    const int16_t *theme_click = NULL;
    unsigned click_frame = 0;
    atomic_init(&p.stop, 0);
    atomic_init(&p.exit_code, 0);
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);
    int flags = fcntl(STDIN_FILENO, F_GETFL);
    if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) < 0)
        return EX_OPEN;
    menu_click_build(&clicks);
    /* Never launch a core from the background menu helper. */
    if (!core_name_matches(&p) || h264ring_open_devmem(&p.ring, 0)) return EX_CORE;
    p.core_owned = 1;
    if (!core_owner_ok(&p) || h264ring_alive(p.ring, 100) ||
        caught_signal || !core_owner_ok(&p)) goto done;
    if (h264ring_start_session(p.ring, 300) || caught_signal || !core_owner_ok(&p))
        goto done;
    struct h264ring_status status;
    if (h264ring_status(p.ring, &status)) goto done;
    played = (uint32_t)H264RING_ST(&status, AUD_PLAYED);
    if (!core_owner_ok(&p) || h264ring_try_write_audio(p.ring, silence, sizeof silence, -1))
        goto done;
    deadline = mono_ms() + 1800;
    submitted = played + MENU_CLICK_FRAMES;
    last_played = played;
    while (!caught_signal) {
        struct pollfd fd = { .fd = STDIN_FILENO, .events = POLLIN };
        int polled = poll(&fd, 1, (pcm_fd >= 0 || tone.midi || tone.gain > 0) ? 2 : (busy ? 5 : 40));
        if (polled < 0 && errno != EINTR) goto done;
        if (caught_signal) break;
        int tap = 0, drained = 0;
        /* Bound each drain even if a broken caller writes continuously. */
        for (unsigned batch = 0; batch < 16; ++batch) {
            char bytes[256];
            ssize_t n = read(STDIN_FILENO, bytes, sizeof bytes);
            if (n == 0) { result = EX_OK; goto done; }
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) { drained = 1; break; }
                if (errno == EINTR) continue;
                goto done;
            }
            tap |= menu_click_input_feed(&input, bytes, (size_t)n);
        }
        /* Drop anything received before ready, during an outstanding click,
         * or during a command flood. Never save it for a later iteration. */
        int control = tap && drained && ready;
        tap = control && !busy && input.command.kind == 0;
        if (!core_owner_ok(&p) || !h264ring_session_ok(p.ring) ||
            h264ring_status(p.ring, &status) || H264RING_ST(&status, ERR)) goto done;
        if (busy && (uint32_t)((uint32_t)H264RING_ST(&status, AUD_PLAYED) - played)
                    >= MENU_CLICK_FRAMES) {
            busy = 0;
            if (!ready) {
                ready = 1;
                if (puts("ready") == EOF || fflush(stdout)) goto done;
            }
        }
        if (busy && mono_ms() >= deadline) goto done;
        uint32_t current = (uint32_t)H264RING_ST(&status, AUD_PLAYED);
        uint32_t queued = submitted - current;
        if (current != last_played) {
            last_played = current;
            progress_deadline = mono_ms() + 200;
        }
        if (ready && queued && mono_ms() >= progress_deadline) goto done;
        if (control && input.command.kind) {
            tone.midi = input.command.kind == 1 ? input.command.midi : 0;
            if (input.command.kind == 1) tone.level = input.command.level;
            tone_until = mono_ms() + 650; /* lost release / stalled UI watchdog */
        }
        if (mono_ms() >= tone_until) tone.midi = 0;
        /* Refill a bounded 30 ms cushion in one pass. One 5 ms record
         * per scheduler wake starves on the DE10 under menu load. */
        int handled_theme = 0;
        for (unsigned fill = 0; fill < 6; ++fill) {
            if (pcm_fd >= 0 && theme_bytes < sizeof theme_pcm) {
                ssize_t n = read(pcm_fd, (char *)theme_pcm + theme_bytes, sizeof theme_pcm - theme_bytes);
                if (n > 0) theme_bytes += (size_t)n;
                else if (n == 0) pcm_fd = -1;
                else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) goto done;
            }
            if (ready && (theme_bytes || theme_click)) {
                if (tap && !theme_click) {
                    unsigned note = input.command.midi ?
                        MENU_CLICK_NOTES + input.command.midi - MENU_CLICK_MIDI_FIRST :
                        menu_click_note(&random, previous);
                    theme_click = clicks.pcm[input.command.level - 1][note];
                    click_frame = 0;
                    if (!input.command.midi) previous = (int)note;
                }
                if (queued < 1440 && (theme_bytes || theme_click)) {
                    for (unsigned i = 0; i < 480; ++i) {
                        int value = i * 2 < theme_bytes ? theme_pcm[i] : 0;
                        if (theme_click && click_frame + i / 2 < MENU_CLICK_FRAMES)
                            value += theme_click[click_frame * 2 + i];
                        mixed_pcm[i] = value > 32767 ? 32767 : value < -32768 ? -32768 : value;
                    }
                    if (!core_owner_ok(&p)) goto done;
                    int rc = h264ring_try_write_audio(p.ring, mixed_pcm, sizeof mixed_pcm, -1);
                    if (rc && rc != -EAGAIN) goto done;
                    if (!rc) {
                        theme_bytes = 0;
                        submitted += 240;
                        if (!queued) progress_deadline = mono_ms() + 200;
                        queued += 240;
                        if (theme_click) {
                            click_frame += 240;
                            if (click_frame >= MENU_CLICK_FRAMES) theme_click = NULL;
                        }
                    }
                }
                handled_theme = 1;
                if (queued >= 1440) break;
            } else break;
        }
        if (handled_theme) continue;
        if (tone.midi || tone.gain > 0) {
            tap = 0;
            /* AUD_PLAYED may advance by whole records. Keep multiple records
             * ahead instead of waiting for the current one to finish. */
            for (unsigned fill = 0; fill < 3 && queued < MENU_CLICK_FRAMES * 3 &&
                    (tone.midi || tone.gain > 0); ++fill) {
                struct menu_tone next = tone;
                menu_tone_render(&next, tone_pcm);
                if (!core_owner_ok(&p)) goto done;
                int rc = h264ring_try_write_audio(p.ring, tone_pcm, sizeof tone_pcm, -1);
                if (rc && rc != -EAGAIN) goto done;
                if (!rc) {
                    tone = next;
                    submitted += MENU_CLICK_FRAMES;
                    if (!queued) progress_deadline = mono_ms() + 200;
                    queued += MENU_CLICK_FRAMES;
                }
                if (rc == -EAGAIN) break;
            }
        }
        if (tap && !queued) {
            unsigned note = input.command.midi ?
                MENU_CLICK_NOTES + input.command.midi - MENU_CLICK_MIDI_FIRST :
                menu_click_note(&random, previous);
            played = (uint32_t)H264RING_ST(&status, AUD_PLAYED);
            if (!core_owner_ok(&p)) goto done;
            const int16_t *pcm = clicks.pcm[input.command.level - 1][note];
            int rc = h264ring_try_write_audio(p.ring, pcm, MENU_CLICK_FRAMES * 4, -1);
            if (rc == -EAGAIN) continue;
            if (rc) goto done;
            submitted = played + MENU_CLICK_FRAMES;
            progress_deadline = mono_ms() + 200;
            if (!input.command.midi) previous = (int)note;
            busy = 1;
            deadline = mono_ms() + 200;
        }
    }
    result = EX_OK;
done:
    /* close() clears rumble words after a session. After ownership/reset loss,
     * leave cleanup to process exit, which unmaps and releases flock without
     * any writes to a replacement core. */
    if (core_owner_ok(&p) && h264ring_session_ok(p.ring)) h264ring_close(p.ring);
    return result;
}
#endif
