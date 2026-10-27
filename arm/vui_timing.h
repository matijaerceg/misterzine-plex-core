/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_VUI_TIMING_H
#define JFPLAY_VUI_TIMING_H
/* The SPS VUI timing the core schedules by, made to agree with the container.
 *
 * The core's display scheduler takes a picture's duration from the SPS VUI
 * (num_units_in_tick / time_scale, H.264 E.2.1) and, with Refresh Rate on
 * Auto, the raster's rate from the same fields. Encoders do not always fill
 * them in: a 23.976 frames/s file was found carrying 1 / 180000 (a 90,000
 * frames/s "rate"), and with it the core picked up every other picture late
 * for the whole title, a steady judder the lag watchdog cannot see because
 * the timeline never falls behind. The container knows the rate (ffmpeg's
 * guess from the stream and its packets), so before an access unit with an
 * SPS reaches the core the VUI is rewritten to it when the two disagree by
 * more than half a percent, when the VUI has no timing, or when the SPS has
 * no VUI at all. Nothing else in the SPS changes; a rewrite keeps the
 * emulation prevention bytes right and may grow the NAL unit by a few bytes.
 *
 * vui_timing_fix_au returns 0 when the access unit is left alone (no SPS,
 * timing already right, rate unknown, or an SPS too odd to parse), or 1 with
 * *out set to a malloc'd rewritten copy of the access unit (*out_len bytes)
 * the caller frees. The rate is the output clock's (after any film-speed
 * change), num / den frames a second. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define VUI_TIMING_MAX_RBSP 1024u

struct vt_bits { const uint8_t *buf; size_t n, pos; int bad; };
struct vt_out { uint8_t buf[VUI_TIMING_MAX_RBSP + 16]; size_t bits; int full; };

static inline unsigned vt_u(struct vt_bits *b, unsigned n)
{
    unsigned v = 0;
    while (n--) {
        if (b->pos >= b->n * 8) { b->bad = 1; return 0; }
        v = v << 1 | ((b->buf[b->pos >> 3] >> (7 - (b->pos & 7))) & 1u);
        b->pos++;
    }
    return v;
}

static inline unsigned vt_ue(struct vt_bits *b)
{
    unsigned lz = 0, v = 0;
    while (!vt_u(b, 1) && !b->bad) if (++lz > 31) { b->bad = 1; return 0; }
    for (unsigned i = 0; i < lz && !b->bad; i++) v = v << 1 | vt_u(b, 1);
    return lz ? (1u << lz) - 1 + v : 0;
}

static inline void vt_put(struct vt_out *o, uint32_t v, unsigned n)
{
    while (n--) {
        if (o->bits >= sizeof o->buf * 8) { o->full = 1; return; }
        if ((v >> n) & 1u) o->buf[o->bits >> 3] |= (uint8_t)(0x80u >> (o->bits & 7));
        o->bits++;
    }
}

/* copy bits [from, to) of the input */
static inline void vt_copy(struct vt_out *o, const uint8_t *in, size_t from, size_t to)
{
    for (size_t i = from; i < to; i++) vt_put(o, (in[i >> 3] >> (7 - (i & 7))) & 1u, 1);
}

/* the VUI's timing fields: where they are, or where they would go */
struct vt_sps {
    size_t vui_flag;       /* bit position of vui_parameters_present_flag */
    int vui_present;
    size_t timing_flag;    /* bit position of timing_info_present_flag (VUI present) */
    int timing_present;
    uint32_t nuit, ts;     /* the fields as coded (timing present) */
    size_t after_timing;   /* bit position after fixed_frame_rate_flag, or == timing_flag + 1 */
    size_t stop;           /* bit position of the rbsp_stop_one_bit */
};

static inline int vt_parse_sps(const uint8_t *rbsp, size_t n, struct vt_sps *s)
{
    struct vt_bits b = {rbsp, n, 0, 0};
    memset(s, 0, sizeof *s);
    unsigned profile = vt_u(&b, 8);
    vt_u(&b, 16);                                 /* constraints, level */
    vt_ue(&b);                                    /* sps id */
    switch (profile) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128:
    case 138: case 139: case 134: case 135: {
        unsigned chroma = vt_ue(&b);
        if (chroma == 3) vt_u(&b, 1);
        vt_ue(&b); vt_ue(&b); vt_u(&b, 1);        /* bit depths, transform bypass */
        if (vt_u(&b, 1))                          /* scaling matrix */
            for (unsigned i = 0; i < (chroma != 3 ? 8u : 12u) && !b.bad; i++)
                if (vt_u(&b, 1)) {
                    int last = 8, next = 8;
                    unsigned size = i < 6 ? 16 : 64;
                    for (unsigned j = 0; j < size && !b.bad; j++) {
                        if (next) {
                            unsigned k = vt_ue(&b);
                            int delta = (k & 1u) ? (int)((k + 1) / 2) : -(int)(k / 2);
                            next = (last + delta + 256) % 256;
                        }
                        last = next ? next : last;
                    }
                }
        break;
    }
    default: break;
    }
    vt_ue(&b);                                    /* log2_max_frame_num_minus4 */
    unsigned poc = vt_ue(&b);
    if (poc == 0) vt_ue(&b);
    else if (poc == 1) {
        vt_u(&b, 1); vt_ue(&b); vt_ue(&b);
        unsigned cycles = vt_ue(&b);
        for (unsigned i = 0; i < cycles && i < 256 && !b.bad; i++) vt_ue(&b);
    }
    vt_ue(&b); vt_u(&b, 1);                       /* max_num_ref_frames, gaps */
    vt_ue(&b); vt_ue(&b);                         /* width, height */
    if (!vt_u(&b, 1)) vt_u(&b, 1);                /* frame_mbs_only, mb_adaptive */
    vt_u(&b, 1);                                  /* direct_8x8_inference */
    if (vt_u(&b, 1)) { vt_ue(&b); vt_ue(&b); vt_ue(&b); vt_ue(&b); }   /* cropping */
    if (b.bad) return -1;
    s->vui_flag = b.pos;
    s->vui_present = (int)vt_u(&b, 1);
    s->timing_present = 0;
    s->nuit = s->ts = 0;
    if (s->vui_present) {
        if (vt_u(&b, 1)) { if (vt_u(&b, 8) == 255) vt_u(&b, 32); }      /* aspect ratio */
        if (vt_u(&b, 1)) vt_u(&b, 1);                                  /* overscan */
        if (vt_u(&b, 1)) { vt_u(&b, 4); if (vt_u(&b, 1)) vt_u(&b, 24); } /* video signal */
        if (vt_u(&b, 1)) { vt_ue(&b); vt_ue(&b); }                     /* chroma loc */
        if (b.bad) return -1;
        s->timing_flag = b.pos;
        s->timing_present = (int)vt_u(&b, 1);
        if (s->timing_present) {
            s->nuit = vt_u(&b, 32);
            s->ts = vt_u(&b, 32);
            vt_u(&b, 1);                                               /* fixed_frame_rate_flag */
        }
        if (b.bad) return -1;
        s->after_timing = b.pos;
    }
    /* the stop bit: the last 1 in the RBSP */
    size_t last = n * 8;
    while (last > 0) {
        size_t i = last - 1;
        if ((rbsp[i >> 3] >> (7 - (i & 7))) & 1u) break;
        last--;
    }
    if (last == 0) return -1;
    s->stop = last - 1;
    if (s->stop < b.pos) return -1;
    return 0;
}

/* whether a VUI rate (fields a second ts / nuit: a frame is two ticks) is the container's */
static inline int vt_rate_agrees(uint32_t nuit, uint32_t ts, unsigned num, unsigned den)
{
    if (!nuit || !ts) return 0;
    double vui = (double)ts / (2.0 * (double)nuit), want = (double)num / (double)den;
    double diff = vui > want ? vui - want : want - vui;
    return diff <= want * 0.005;
}

/* One SPS NAL unit (payload after the header byte, escaped). Returns the
 * rewritten payload length written to out (escaped, cap bytes available),
 * 0 when it should stay as it is, -1 when it cannot be parsed or fit. */
static inline int vt_rewrite_sps(const uint8_t *in, size_t len, unsigned num, unsigned den,
                                 uint8_t *out, size_t cap, uint32_t *old_nuit, uint32_t *old_ts)
{
    uint8_t rbsp[VUI_TIMING_MAX_RBSP];
    size_t n = 0, zeros = 0;
    if (len > VUI_TIMING_MAX_RBSP) return -1;
    for (size_t i = 0; i < len; i++) {
        if (zeros >= 2 && in[i] == 3) { zeros = 0; continue; }
        zeros = in[i] == 0 ? zeros + 1 : 0;
        rbsp[n++] = in[i];
    }
    struct vt_sps s;
    if (vt_parse_sps(rbsp, n, &s)) return -1;
    *old_nuit = s.nuit; *old_ts = s.ts;
    if (s.vui_present && s.timing_present && vt_rate_agrees(s.nuit, s.ts, num, den)) return 0;
    struct vt_out o;
    memset(&o, 0, sizeof o);
    uint32_t nuit = den, ts = 2u * num;
    if (s.vui_present) {
        vt_copy(&o, rbsp, 0, s.timing_flag);
        vt_put(&o, 1, 1); vt_put(&o, nuit, 32); vt_put(&o, ts, 32); vt_put(&o, 0, 1);
        vt_copy(&o, rbsp, s.after_timing, s.stop);
    } else {
        vt_copy(&o, rbsp, 0, s.vui_flag);
        vt_put(&o, 1, 1);                         /* vui_parameters_present_flag */
        vt_put(&o, 0, 4);                         /* no aspect, overscan, video signal, chroma loc */
        vt_put(&o, 1, 1); vt_put(&o, nuit, 32); vt_put(&o, ts, 32); vt_put(&o, 0, 1);
        vt_put(&o, 0, 4);                         /* no nal_hrd, vcl_hrd, pic_struct, bitstream_restriction */
    }
    vt_put(&o, 1, 1);                             /* rbsp_stop_one_bit */
    while (o.bits & 7) vt_put(&o, 0, 1);
    if (o.full) return -1;
    size_t m = 0;
    zeros = 0;
    for (size_t i = 0; i < o.bits / 8; i++) {
        if (zeros >= 2 && o.buf[i] <= 3) { if (m >= cap) return -1; out[m++] = 3; zeros = 0; }
        if (m >= cap) return -1;
        out[m++] = o.buf[i];
        zeros = o.buf[i] == 0 ? zeros + 1 : 0;
    }
    return (int)m;
}

/* the next NAL unit in an Annex-B buffer from *at: its payload [start, end), or 0 at the end */
static inline int vt_next_nal(const uint8_t *au, size_t len, size_t *at, size_t *start, size_t *end)
{
    size_t i = *at;
    while (i + 2 < len && !(au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1)) i++;
    if (i + 2 >= len) return 0;
    *start = i + 3;
    size_t e = *start;
    while (e + 2 < len && !(au[e] == 0 && au[e + 1] == 0 && (au[e + 2] == 1 || au[e + 2] == 0))) e++;
    if (e + 2 >= len) e = len;
    *end = e;
    *at = e;
    return 1;
}

static inline int vui_timing_fix_au(const uint8_t *au, size_t len, unsigned num, unsigned den,
                                    uint8_t **out, size_t *out_len, uint32_t *old_nuit, uint32_t *old_ts)
{
    if (!num || !den) return 0;
    double fps = (double)num / (double)den;
    if (fps < 10.0 || fps > 120.0) return 0;
    size_t at = 0, start, end;
    uint8_t *buf = NULL;
    size_t m = 0, copied = 0;
    while (vt_next_nal(au, len, &at, &start, &end)) {
        if (end <= start || (au[start] & 31u) != 7) continue;
        uint8_t sps[VUI_TIMING_MAX_RBSP + 32];
        uint32_t nuit = 0, ts = 0;
        int n = vt_rewrite_sps(au + start + 1, end - start - 1, num, den, sps, sizeof sps, &nuit, &ts);
        if (n <= 0) continue;
        if (!buf) {
            buf = malloc(len + 64);
            if (!buf) return 0;
        } else {
            uint8_t *grown = realloc(buf, m + (len - copied) + 64);
            if (!grown) { free(buf); return 0; }
            buf = grown;
        }
        memcpy(buf + m, au + copied, start + 1 - copied); m += start + 1 - copied;
        memcpy(buf + m, sps, (size_t)n); m += (size_t)n;
        copied = end;
        *old_nuit = nuit; *old_ts = ts;
    }
    if (!buf) return 0;
    memcpy(buf + m, au + copied, len - copied); m += len - copied;
    *out = buf; *out_len = m;
    return 1;
}
#endif
