/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_CORE_OWNER_H
#define JFPLAY_CORE_OWNER_H

#include <stdint.h>
#include <string.h>

/* Match MiSTer's first CORENAME line, including its optional CRLF ending.
 * MiSTer writes the core's own name there (the first entry of its CONF_STR,
 * not the rbf file name): "H264" for an upstream build of the core, or the
 * name an app's build gives itself, which the app passes as --core-name
 * (app_name). Given an app name, only that name is owned: an upstream core
 * may be another app's, drawing its own overlay. NULL or empty accepts
 * only H264. */
static inline int jfplay_core_name_owned(const char *name, const char *app_name)
{
    size_t n;
    if (!name) return 0;
    n = strcspn(name, "\r\n");
    if (app_name && *app_name)
        return n == strlen(app_name) && !memcmp(name, app_name, n);
    return n == 4 && !memcmp(name, "H264", 4);
}

struct jfplay_core_owner {
    const char *app_name;   /* the app's own name for the core, or NULL */
    int lost, sampled, have_beat;
    uint32_t beat;
    uint64_t sampled_at_ms, beat_at_ms;
};

/* Once ownership is lost, never reclaim the mapping during this process.
 * A frame counter is required to keep writes enabled; advancing while paused
 * is expected because this counter follows raster frames, not decoded media. */
static inline int jfplay_core_owner_check(struct jfplay_core_owner *owner,
        const char *name, int beat_valid, uint32_t beat,
        uint64_t now_ms, uint64_t max_stale_ms)
{
    if (!owner || owner->lost) return 0;
    if (!jfplay_core_name_owned(name, owner->app_name)) {
        owner->lost = 1;
        return 0;
    }
    if (!owner->sampled) {
        owner->sampled = 1;
        owner->sampled_at_ms = now_ms;
    }
    if (beat_valid) {
        if (!owner->have_beat || owner->beat != beat) {
            owner->beat = beat;
            owner->beat_at_ms = now_ms;
            owner->have_beat = 1;
        }
    }
    uint64_t last_alive = owner->have_beat ? owner->beat_at_ms : owner->sampled_at_ms;
    if (now_ms - last_alive > max_stale_ms) {
        owner->lost = 1;
        return 0;
    }
    return 1;
}

#endif
