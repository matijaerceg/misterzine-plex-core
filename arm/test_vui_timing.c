/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Host test for the SPS VUI timing rewrite (vui_timing.h): synthetic SPS
 * NAL units built bit by bit, rewritten, then parsed back. */
#include <stdio.h>
#include <string.h>
#include "vui_timing.h"

struct bw { uint8_t raw[256]; size_t bits; };

static void put(struct bw *w, uint32_t v, unsigned n)
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

/* start code + header + escaped RBSP; returns the length */
static size_t nal(uint8_t *out, uint8_t header, struct bw *w)
{
    size_t at = 0;
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

enum vui_kind { VUI_NONE, VUI_NO_TIMING, VUI_TIMING };

/* a Main or High profile 1280x720 SPS, with the VUI asked for (timing nuit / ts,
 * an aspect ratio and colour description before it, a bitstream restriction after) */
static size_t sps(uint8_t *out, unsigned profile, enum vui_kind kind, uint32_t nuit, uint32_t ts)
{
    struct bw w;
    memset(&w, 0, sizeof w);
    put(&w, profile, 8); put(&w, 0, 8); put(&w, 31, 8);
    ue(&w, 0);
    if (profile == 100) { ue(&w, 1); ue(&w, 0); ue(&w, 0); put(&w, 0, 1); put(&w, 0, 1); }
    ue(&w, 0); ue(&w, 0); ue(&w, 2);                 /* frame_num, poc type 0, poc lsb */
    ue(&w, 4); put(&w, 0, 1);
    ue(&w, 79); ue(&w, 44); put(&w, 1, 1); put(&w, 1, 1); put(&w, 0, 1);
    if (kind == VUI_NONE) { put(&w, 0, 1); return nal(out, 0x67, &w); }
    put(&w, 1, 1);
    put(&w, 1, 1); put(&w, 1, 8);                    /* aspect ratio idc 1 */
    put(&w, 0, 1);                                   /* overscan */
    put(&w, 1, 1); put(&w, 5, 3); put(&w, 0, 1); put(&w, 1, 1); put(&w, 1, 8); put(&w, 1, 8); put(&w, 1, 8);
    put(&w, 0, 1);                                   /* chroma loc */
    if (kind == VUI_TIMING) { put(&w, 1, 1); put(&w, nuit, 32); put(&w, ts, 32); put(&w, 0, 1); }
    else put(&w, 0, 1);
    put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1);     /* hrd x2, pic_struct */
    put(&w, 1, 1);                                   /* bitstream restriction */
    put(&w, 1, 1); ue(&w, 0); ue(&w, 0); ue(&w, 11); ue(&w, 11); ue(&w, 2); ue(&w, 4);
    return nal(out, 0x67, &w);
}

static size_t pps(uint8_t *out)
{
    struct bw w;
    memset(&w, 0, sizeof w);
    ue(&w, 0); ue(&w, 0); put(&w, 1, 1); put(&w, 0, 1); ue(&w, 0);
    ue(&w, 2); ue(&w, 0); put(&w, 1, 1); put(&w, 2, 2);
    ue(&w, 9); ue(&w, 0); ue(&w, 3);                 /* qp -5, qs 0, chroma offset -2 */
    put(&w, 1, 1); put(&w, 0, 1); put(&w, 0, 1);
    return nal(out, 0x68, &w);
}

static int failures;

static void check(const char *name, int cond)
{
    if (!cond) { fprintf(stderr, "FAIL %s\n", name); failures++; }
}

/* where the PPS start code begins in an AU, or NULL */
static const uint8_t *find_pps(const uint8_t *au, size_t len)
{
    for (size_t i = 0; i + 4 < len; i++)
        if (!au[i] && !au[i + 1] && !au[i + 2] && au[i + 3] == 1 && (au[i + 4] & 31u) == 8) return au + i;
    return NULL;
}

/* parse the (first) SPS of an AU back: its VUI timing, and the bits around it unchanged */
static int timing_of(const uint8_t *au, size_t len, uint32_t *nuit, uint32_t *ts, struct vt_sps *s)
{
    size_t at = 0, start, end;
    while (vt_next_nal(au, len, &at, &start, &end)) {
        if ((au[start] & 31u) != 7) continue;
        uint8_t rbsp[1024];
        size_t n = 0, zeros = 0;
        for (size_t i = start + 1; i < end; i++) {
            if (zeros >= 2 && au[i] == 3) { zeros = 0; continue; }
            zeros = au[i] == 0 ? zeros + 1 : 0;
            rbsp[n++] = au[i];
        }
        if (vt_parse_sps(rbsp, n, s)) return -1;
        *nuit = s->nuit; *ts = s->ts;
        return 0;
    }
    return -1;
}

static void run(const char *name, unsigned profile, enum vui_kind kind, uint32_t nuit, uint32_t ts,
                unsigned num, unsigned den, int want_change, uint32_t want_nuit, uint32_t want_ts)
{
    uint8_t au[1024], *out = NULL;
    size_t n = sps(au, profile, kind, nuit, ts), out_len = 0;
    n += pps(au + n);
    /* an IDR slice stub with bytes that look like an escape */
    const uint8_t idr[] = {0, 0, 1, 0x65, 0x88, 0x84, 0, 0, 3, 1, 0x40};
    memcpy(au + n, idr, sizeof idr); n += sizeof idr;
    uint32_t old_nuit = 0, old_ts = 0;
    int rc = vui_timing_fix_au(au, n, num, den, &out, &out_len, &old_nuit, &old_ts);
    char what[128];
    snprintf(what, sizeof what, "%s: change", name);
    check(what, rc == want_change);
    if (rc != 1) { free(out); return; }
    snprintf(what, sizeof what, "%s: old timing reported", name);
    check(what, old_nuit == nuit && old_ts == ts);
    uint32_t got_nuit = 0, got_ts = 0;
    struct vt_sps s;
    snprintf(what, sizeof what, "%s: rewritten SPS parses", name);
    check(what, timing_of(out, out_len, &got_nuit, &got_ts, &s) == 0);
    snprintf(what, sizeof what, "%s: new timing", name);
    check(what, got_nuit == want_nuit && got_ts == want_ts && s.vui_present && s.timing_present);
    /* the PPS and the slice survive byte for byte */
    snprintf(what, sizeof what, "%s: PPS and slice unchanged", name);
    const uint8_t *pps_in = find_pps(au, n), *pps_out = find_pps(out, out_len);
    check(what, pps_in && pps_out && (size_t)(au + n - pps_in) == (size_t)(out + out_len - pps_out) &&
          !memcmp(pps_in, pps_out, (size_t)(au + n - pps_in)));
    /* idempotent: the rewritten AU is left alone */
    uint8_t *again = NULL;
    size_t again_len = 0;
    snprintf(what, sizeof what, "%s: second pass unchanged", name);
    check(what, vui_timing_fix_au(out, out_len, num, den, &again, &again_len, &old_nuit, &old_ts) == 0);
    free(again);
    free(out);
}

int main(void)
{
    /* 23.976 content wrongly tagged 1 / 180000 (the file that showed the judder) */
    run("junk VUI timing", 77, VUI_TIMING, 1, 180000, 24000, 1001, 1, 1001, 48000);
    /* the same with a High profile SPS */
    run("junk VUI timing, High", 100, VUI_TIMING, 1, 180000, 24000, 1001, 1, 1001, 48000);
    /* right already: 1001 / 48000 for 23.976, 1 / 50 for 25, 1001 / 60000 for 29.97 */
    run("right 23.976", 77, VUI_TIMING, 1001, 48000, 24000, 1001, 0, 0, 0);
    run("right 25", 77, VUI_TIMING, 1, 50, 25, 1, 0, 0, 0);
    run("right 29.97", 77, VUI_TIMING, 1001, 60000, 30000, 1001, 0, 0, 0);
    /* 24 against 23.976 is within the half percent */
    run("24 for 23.976", 77, VUI_TIMING, 1, 48, 24000, 1001, 0, 0, 0);
    /* a zero time_scale, and timing twice off */
    run("zero time_scale", 77, VUI_TIMING, 1, 0, 25, 1, 1, 1, 50);
    run("50 for 25", 77, VUI_TIMING, 1, 100, 25, 1, 1, 1, 50);
    /* a VUI without timing, and no VUI at all */
    run("VUI without timing", 77, VUI_NO_TIMING, 0, 0, 25, 1, 1, 1, 50);
    run("no VUI", 100, VUI_NONE, 0, 0, 30000, 1001, 1, 1001, 60000);
    /* an unknown or absurd container rate leaves the stream alone */
    run("rate unknown", 77, VUI_TIMING, 1, 180000, 0, 0, 0, 0, 0);
    run("rate absurd", 77, VUI_TIMING, 1, 180000, 1000, 1, 0, 0, 0);

    /* an AU without an SPS is never copied */
    uint8_t au[64];
    size_t n = pps(au);
    uint8_t *out = NULL; size_t out_len = 0; uint32_t a = 0, b = 0;
    check("no SPS", vui_timing_fix_au(au, n, 25, 1, &out, &out_len, &a, &b) == 0 && !out);
    /* a truncated SPS is left alone */
    n = sps(au, 77, VUI_TIMING, 1, 180000);
    check("truncated SPS", n > 12 && vui_timing_fix_au(au, 12, 25, 1, &out, &out_len, &a, &b) == 0 && !out);

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    puts("vui timing: ok");
    return 0;
}
