/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/h264stat/h264stat.c -- print the H264 core's status block (the telemetry: roadmap D4).
 * A reader only: it maps the region without the lock and never starts a session, so it can
 * run beside a feeder.
 *
 *   h264stat [--json] [--watch SECONDS] [--wait-live SECONDS] [--input]
 *     --json        one JSON object a line (tools/mister.py reads these)
 *     --input       (0.6) the input region instead: Main's pads, mouse and events as the core
 *                   mirrors them; with --watch, each new event on a line of its own as it
 *                   arrives (a key's PS/2 set-2 code, a mouse-button change, the OSD's edges),
 *                   and each pad change and mouse movement (not in JSON)
 *     --watch S     print every S seconds (fractions allowed) until interrupted
 *     --wait-live S exit 0 once the heartbeat advances (the core is running), 1 after S s
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "h264ring.h"

static const struct h264ring_field in_fields[] = H264RING_IN_FIELDS;

static void dump_input(const struct h264ring_input *in, int json)
{
    for (unsigned i = 0; i < H264RING_IN_NFIELDS; i++) {
        const struct h264ring_field *f = &in_fields[i];
        uint64_t v = h264ring_get(in->w, f->word - H264RING_IN_WORD, f->lsb, f->width);
        if (json) printf("%s\"%s\":%llu", i ? "," : "{", f->name, (unsigned long long)v);
        else printf("%-14s %llu (0x%llx)\n", f->name, (unsigned long long)v, (unsigned long long)v);
    }
    if (json) printf("}\n");
}

static void print_event(uint32_t n, uint16_t e, int json)
{
    unsigned t = H264RING_EV_TYPE(e);
    if (json) {
        printf("{\"event\":%u,\"type\":%u,\"raw\":%u}\n", n, t, e);
        return;
    }
    if (t == H264RING_EV_KEY)
        printf("event %u: key %s%02X %s\n", n, H264RING_EV_EXT(e) ? "E0 " : "", H264RING_EV_CODE(e),
               H264RING_EV_PRESSED(e) ? "down" : "up");
    else if (t == H264RING_EV_MOUSE_BTN) printf("event %u: mouse buttons 0x%02X\n", n, H264RING_EV_CODE(e));
    else if (t == H264RING_EV_OSD) printf("event %u: OSD %s\n", n, H264RING_EV_OPEN(e) ? "opened" : "closed");
    else printf("event %u: OSD action %u\n", n, H264RING_EV_CODE(e));   /* H264RING_EV_ACTION (0.8) */
}

static int input_mode(h264ring *r, int json, double watch)
{
    struct h264ring_input in;
    uint16_t ev[H264RING_IN_Q_LEN];
    uint32_t count, lost = 0, lost_seen = 0;
    int rc;
    if ((rc = h264ring_input(r, &in))) {
        fprintf(stderr, "h264stat: no consistent copy of the input region: %s\n", strerror(-rc));
        return 1;
    }
    dump_input(&in, json);
    if (watch <= 0)
        return 0;
    count = (uint32_t)H264RING_IN(&in, EV_COUNT);
    uint64_t pads[6];
    uint32_t dx = (uint32_t)H264RING_IN(&in, DX_SUM), dy = (uint32_t)H264RING_IN(&in, DY_SUM),
             wh = (uint32_t)H264RING_IN(&in, WHEEL_SUM);
    for (int p = 0; p < 6; p++)
        pads[p] = in.w[H264RING_PAD0_JOY_W - H264RING_IN_WORD + p];
    for (;;) {
        unsigned n;
        usleep((useconds_t)(watch * 1e6));
        if (h264ring_input(r, &in))
            continue;
        while ((n = h264ring_input_events(&in, &count, ev, H264RING_IN_Q_LEN, &lost)) != 0)
            for (unsigned i = 0; i < n; i++)
                print_event(count - n + i, ev[i], json);
        /* the pads and the mouse's movement: what changed since the last print (not in JSON) */
        for (int p = 0; p < 6 && !json; p++) {
            uint64_t w = in.w[H264RING_PAD0_JOY_W - H264RING_IN_WORD + p];
            if (w != pads[p]) {
                printf("pad %d: buttons 0x%04x  left (%d, %d)  right (%d, %d)\n", p, (unsigned)(w & 0xFFFFFFFFu),
                       (int8_t)(w >> 32), (int8_t)(w >> 40), (int8_t)(w >> 48), (int8_t)(w >> 56));
                pads[p] = w;
            }
        }
        if (!json && ((uint32_t)H264RING_IN(&in, DX_SUM) != dx || (uint32_t)H264RING_IN(&in, DY_SUM) != dy ||
                      (uint32_t)H264RING_IN(&in, WHEEL_SUM) != wh)) {
            printf("mouse: dx %+d dy %+d wheel %+d\n", (int32_t)((uint32_t)H264RING_IN(&in, DX_SUM) - dx),
                   (int32_t)((uint32_t)H264RING_IN(&in, DY_SUM) - dy), (int32_t)((uint32_t)H264RING_IN(&in, WHEEL_SUM) - wh));
            dx = (uint32_t)H264RING_IN(&in, DX_SUM); dy = (uint32_t)H264RING_IN(&in, DY_SUM);
            wh = (uint32_t)H264RING_IN(&in, WHEEL_SUM);
        }
        if (lost != lost_seen) {
            printf("%u events lost (read too late)\n", lost - lost_seen);
            lost_seen = lost;
        }
        fflush(stdout);
    }
}

int main(int argc, char **argv)
{
    int json = 0, rc, input = 0;
    double watch = 0, wait_live = -1;
    h264ring *r;
    struct h264ring_status st;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--watch") && i + 1 < argc) watch = atof(argv[++i]);
        else if (!strcmp(argv[i], "--wait-live") && i + 1 < argc) wait_live = atof(argv[++i]);
        else if (!strcmp(argv[i], "--input")) input = 1;
        else { fprintf(stderr, "usage: h264stat [--json] [--watch S] [--wait-live S] [--input]\n"); return 2; }
    }
    rc = h264ring_open_devmem(&r, H264RING_OPEN_NOLOCK);
    /* --wait-live: a core just loaded may not have written its magic yet -- retry to the timeout */
    for (double waited = 0; rc == -ENODEV && wait_live > 0 && waited < wait_live; waited += 0.1) {
        usleep(100000);
        rc = h264ring_open_devmem(&r, H264RING_OPEN_NOLOCK);
    }
    if (rc) {
        fprintf(stderr, "h264stat: %s\n", rc == -ENODEV ? "no H264 core status block (is the core loaded?)"
                                                         : strerror(-rc));
        return 1;
    }
    if (wait_live >= 0) {
        rc = h264ring_alive(r, (unsigned)(wait_live * 1000));
        h264ring_close(r);
        return rc ? 1 : 0;
    }
    if (input) {
        rc = input_mode(r, json, watch);
        h264ring_close(r);
        return rc;
    }
    do {
        if ((rc = h264ring_status(r, &st))) {
            fprintf(stderr, "h264stat: no consistent copy: %s\n", strerror(-rc));
            h264ring_close(r);
            return 1;
        }
        h264ring_dump(stdout, &st, json);
        fflush(stdout);
        if (watch > 0) usleep((useconds_t)(watch * 1e6));
    } while (watch > 0);
    h264ring_close(r);
    return 0;
}
