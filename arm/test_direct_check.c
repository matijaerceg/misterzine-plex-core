/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Host test for the --direct pre-check (direct_check.h, over the decoder
 * project's h264check.c) and the keep-up watchdog (lag_watch.h), on tiny
 * synthetic SPS / PPS NAL units built here bit by bit. */
#include <stdio.h>
#include <string.h>
#include "direct_check.h"
#include "lag_watch.h"

struct bw { uint8_t raw[64]; size_t bits; };

static void put(struct bw *w, unsigned v, unsigned n)
{
    while (n--) {
        if ((v >> n) & 1u) w->raw[w->bits >> 3] |= (uint8_t)(0x80u >> (w->bits & 7));
        w->bits++;
    }
}
static void ue(struct bw *w, unsigned v)
{
    unsigned x = v + 1, n = 0;
    while (x >> n) n++;
    put(w, 0, n - 1);
    put(w, x, n);
}
static void se(struct bw *w, int v) { ue(w, v > 0 ? (unsigned)(2 * v - 1) : (unsigned)(-2 * v)); }

/* append start code + header + RBSP (trailing bits, emulation prevention) */
static size_t nal(uint8_t *out, size_t at, uint8_t header, struct bw *w)
{
    put(w, 1, 1);
    while (w->bits & 7) put(w, 0, 1);
    out[at++] = 0; out[at++] = 0; out[at++] = 0; out[at++] = 1; out[at++] = header;
    unsigned zeros = 0;
    for (size_t i = 0; i < w->bits / 8; i++) {
        if (zeros >= 2 && w->raw[i] <= 3) { out[at++] = 3; zeros = 0; }
        out[at++] = w->raw[i];
        zeros = w->raw[i] ? 0 : zeros + 1;
    }
    return at;
}

struct sps { unsigned profile, chroma, depth, w_mbs, h_units, frame_mbs_only, mbaff; };
struct pps { unsigned entropy, slice_groups, redundant; };

static size_t build(uint8_t *out, struct sps s, struct pps p, int with_pps)
{
    struct bw w;
    memset(&w, 0, sizeof w);
    put(&w, s.profile, 8); put(&w, 0, 8); put(&w, 31, 8);   /* constraints, level 3.1 */
    ue(&w, 0);                                               /* sps id */
    if (s.profile == 100 || s.profile == 110 || s.profile == 122) {
        ue(&w, s.chroma); ue(&w, s.depth - 8); ue(&w, s.depth - 8);
        put(&w, 0, 1); put(&w, 0, 1);                        /* bypass, no scaling matrix */
    }
    ue(&w, 0); ue(&w, 2);                                    /* log2_max_frame_num-4, poc type 2 */
    ue(&w, 4); put(&w, 0, 1);                                /* refs, gaps */
    ue(&w, s.w_mbs - 1); ue(&w, s.h_units - 1);
    put(&w, s.frame_mbs_only, 1);
    if (!s.frame_mbs_only) put(&w, s.mbaff, 1);
    put(&w, 1, 1); put(&w, 0, 1); put(&w, 0, 1);             /* direct_8x8, no crop, no VUI */
    size_t n = nal(out, 0, 0x67, &w);
    if (!with_pps) return n;
    memset(&w, 0, sizeof w);
    ue(&w, 0); ue(&w, 0); put(&w, p.entropy, 1); put(&w, 0, 1);
    ue(&w, p.slice_groups - 1);
    if (p.slice_groups > 1) { ue(&w, 0); for (unsigned i = 0; i < p.slice_groups; i++) ue(&w, 0); }
    ue(&w, 0); ue(&w, 0); put(&w, 0, 1); put(&w, 0, 2);
    se(&w, 0); se(&w, 0); se(&w, 0);
    put(&w, 1, 1); put(&w, 0, 1); put(&w, p.redundant, 1);
    n = nal(out, n, 0x68, &w);
    out[n++] = 0; out[n++] = 0; out[n++] = 1; out[n++] = 0x65; out[n++] = 0x88; out[n++] = 0x84;  /* IDR stub */
    return n;
}

static int failures;

static void expect(const char *name, struct sps s, struct pps p, int with_pps, double fps, int want)
{
    uint8_t au[256];
    struct direct_check d;
    const char *why = "";
    memset(&d, 0, sizeof d);
    size_t n = build(au, s, p, with_pps);
    int got = direct_check_au(&d, au, n, fps, &why);
    if (got != want) {
        fprintf(stderr, "FAIL %s: got %d (%s), want %d\n", name, got, why, want);
        failures++;
    } else if (got < 0 && !*why) {
        fprintf(stderr, "FAIL %s: no reason\n", name);
        failures++;
    }
}

static void test_check(void)
{
    struct sps hd = {100, 1, 8, 80, 45, 1, 0}, sd = {77, 1, 8, 54, 30, 1, 0};
    struct pps cabac = {1, 1, 0};
    expect("High 720p30", hd, cabac, 1, 29.97, 1);
    expect("Main 480p60", sd, cabac, 1, 59.94, 1);
    expect("unknown frame rate", hd, cabac, 1, 0, 1);
    expect("absurd frame rate ignored", hd, cabac, 1, 90000, 1);
    struct sps paff = {100, 1, 8, 45, 15, 0, 0};
    expect("PAFF 720x480i", paff, cabac, 1, 29.97, 1);
    expect("SPS only: undecided", hd, cabac, 0, 25, 0);
    expect("CAVLC", hd, (struct pps){0, 1, 0}, 1, 25, -1);
    struct sps mbaff = paff; mbaff.mbaff = 1;
    expect("MBAFF", mbaff, cabac, 1, 29.97, -1);
    struct sps c422 = hd; c422.profile = 122; c422.chroma = 2;
    expect("4:2:2", c422, cabac, 1, 25, -1);
    struct sps d10 = hd; d10.profile = 110; d10.depth = 10;
    expect("10-bit", d10, cabac, 1, 25, -1);
    struct sps big = hd; big.h_units = 46;
    expect("1280x736", big, cabac, 1, 25, -1);
    struct sps wide = hd; wide.w_mbs = 120; wide.h_units = 30;
    expect("1920x480 (3600 macroblocks, too wide)", wide, cabac, 1, 25, -1);
    expect("720p60", hd, cabac, 1, 59.94, -1);
    struct sps base = sd; base.profile = 66;
    expect("Baseline", base, cabac, 1, 25, -1);
    struct sps ext = sd; ext.profile = 88;
    expect("Extended", ext, cabac, 1, 25, -1);
    expect("slice groups", sd, (struct pps){1, 2, 0}, 1, 25, -1);
    expect("redundant pictures", sd, (struct pps){1, 1, 1}, 1, 25, -1);

    /* extradata first, then an AU without parameter sets */
    uint8_t x[256];
    struct direct_check d;
    const char *why = "";
    memset(&d, 0, sizeof d);
    size_t n = build(x, hd, cabac, 1);
    if (direct_check_au(&d, x, n - 6, 25, &why) != 1) { fprintf(stderr, "FAIL extradata\n"); failures++; }
}

static void test_lag(void)
{
    struct lag_watch w;
    memset(&w, 0, sizeof w);
    uint64_t t = 0;
    unsigned late = 0;
    int lag = 0, fired = 0;
    /* in sync, then a drifting 60.000 stream: late pickups, lag ~1 ms/s */
    for (int i = 0; i < 40; i++, t += 250) {
        if (i > 20) { late++; lag = -(i - 20) / 4 - 200; }
        fired |= lag_watch_sample(&w, t, 1, late, (unsigned)lag & 0xFFFFu);
    }
    if (fired) { fprintf(stderr, "FAIL lag: drift triggered\n"); failures++; }
    /* a decoder at 0.85x: 150 ms more behind each second */
    memset(&w, 0, sizeof w);
    late = 0; lag = 0;
    uint64_t start = t, when = 0;
    for (int i = 0; i < 80 && !when; i++, t += 250) {
        late += 3; lag -= 37;
        if (lag_watch_sample(&w, t, 1, late, (unsigned)lag & 0xFFFFu)) when = t - start;
    }
    if (!when || when < LAG_GRACE_MS + 3 * LAG_WINDOW_MS || when > LAG_GRACE_MS + 6 * LAG_WINDOW_MS) {
        fprintf(stderr, "FAIL lag: falling behind fired after %llu ms\n", (unsigned long long)when);
        failures++;
    }
    /* pausing resets the grace */
    memset(&w, 0, sizeof w);
    late = 0; lag = -3000; fired = 0;
    for (int i = 0; i < 60; i++, t += 250) {
        late += 3;
        fired |= lag_watch_sample(&w, t, (i % 16) != 0, late, (unsigned)lag & 0xFFFFu);
    }
    if (fired) { fprintf(stderr, "FAIL lag: fired across pauses\n"); failures++; }
    /* the 16-bit late counter wraps */
    memset(&w, 0, sizeof w);
    late = 0xFFF0; lag = -2500; when = 0;
    for (int i = 0; i < 60 && !when; i++, t += 250) {
        late = (late + 2) & 0xFFFFu;
        if (lag_watch_sample(&w, t, 1, late, (unsigned)lag & 0xFFFFu)) when = 1;
    }
    if (!when) { fprintf(stderr, "FAIL lag: hard lag with wrapping counter\n"); failures++; }
    /* a no-value sample neither triggers nor moves the baseline or the clock */
    memset(&w, 0, sizeof w);
    late = 0; fired = 0;
    lag_watch_sample(&w, t, 1, late, 0);
    t += LAG_GRACE_MS;
    fired |= lag_watch_sample(&w, t, 1, late, (unsigned)-50 & 0xFFFFu);
    t += LAG_WINDOW_MS;
    {
        uint64_t next = w.next_ms;
        int base = w.behind0;
        unsigned l0 = w.late0;
        fired |= lag_watch_sample(&w, t, 1, late + 5, LAG_NONE);
        if (w.next_ms != next || w.behind0 != base || w.late0 != l0 || w.bad) {
            fprintf(stderr, "FAIL lag: sentinel moved the baseline\n"); failures++;
        }
    }
    for (int i = 0; i < 12; i++, t += LAG_WINDOW_MS) {
        late += 2;
        fired |= lag_watch_sample(&w, t, 1, late, (unsigned)-200 & 0xFFFFu);
    }
    if (fired) { fprintf(stderr, "FAIL lag: sentinel counted as growth\n"); failures++; }
    /* a stall: not running for a stretch, then a large lag, restarts the grace */
    memset(&w, 0, sizeof w);
    late = 0; fired = 0;
    for (int i = 0; i < 12; i++, t += 250) {
        late += 3;
        fired |= lag_watch_sample(&w, t, i >= 4 && i != 5, late, (unsigned)-2500 & 0xFFFFu);
    }
    if (fired) { fprintf(stderr, "FAIL lag: fired after a stall\n"); failures++; }
}

int main(void)
{
    test_check();
    test_lag();
    if (failures) return 1;
    puts("direct check: ok");
    return 0;
}
