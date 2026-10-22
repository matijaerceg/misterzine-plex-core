/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_DIRECT_CHECK_H
#define JFPLAY_DIRECT_CHECK_H
/* The direct-stream pre-check: from the SPS / PPS of an untranscoded stream,
 * whether the core certainly decodes it in real time. The decoder project's
 * client check (clients/common/h264check.c) supplies the parse and the
 * profile / chroma / bit depth / MBAFF / size / macroblock-rate / CAVLC
 * verdict; this adds what jfplay needs on top of it:
 *   - only Main (77) and High (100) profiles: no Baseline / Extended stream
 *     (their ASO, slice groups, redundant pictures and data partitioning);
 *     jfplay does not enable the library's CAVLC rewrite, so CAVLC (and with
 *     it Constrained Baseline) is refused as well;
 *   - at most 80 macroblocks (1280 pixels) wide;
 *   - no slice groups and no redundant pictures in the PPS.
 * Transcodes from the server are made within the profile and are not checked. */
#include <stddef.h>
#include <stdint.h>
#include "h264check.h"

#define DIRECT_MAX_WIDTH_MBS 80u   /* 1280 pixels */

struct direct_check {
    struct h264check_state chk;
    int have_pps;
    unsigned slice_groups, redundant;
};

struct dc_bits { uint8_t buf[64]; size_t n, pos; int bad; };

static inline unsigned dc_u1(struct dc_bits *b)
{
    if (b->pos >= b->n * 8) { b->bad = 1; return 0; }
    unsigned v = (b->buf[b->pos >> 3] >> (7 - (b->pos & 7))) & 1u;
    b->pos++;
    return v;
}

static inline unsigned dc_ue(struct dc_bits *b)
{
    unsigned lz = 0, v = 0;
    while (!dc_u1(b) && !b->bad) if (++lz > 31) { b->bad = 1; return 0; }
    for (unsigned i = 0; i < lz; i++) v = v << 1 | dc_u1(b);
    return lz ? (1u << lz) - 1 + v : 0;
}

/* the PPS fields h264check does not read (H.264 7.3.2.2) */
static inline void direct_check_pps(struct direct_check *d, const uint8_t *p, size_t len)
{
    struct dc_bits b = {{0}, 0, 0, 0};
    unsigned zeros = 0;
    for (size_t i = 0; i < len && b.n < sizeof b.buf; i++) {
        if (zeros >= 2 && p[i] == 3) { zeros = 0; continue; }
        zeros = p[i] == 0 ? zeros + 1 : 0;
        b.buf[b.n++] = p[i];
    }
    dc_ue(&b); dc_ue(&b);                   /* pic_parameter_set_id, seq_parameter_set_id */
    dc_u1(&b); dc_u1(&b);                   /* entropy_coding_mode_flag, bottom_field_pic_order... */
    d->slice_groups = dc_ue(&b) + 1;
    if (d->slice_groups > 1) { d->have_pps = !b.bad; return; }   /* refused: the rest is moot */
    dc_ue(&b); dc_ue(&b);                   /* num_ref_idx_l0/l1_default_active_minus1 */
    dc_u1(&b); dc_u1(&b); dc_u1(&b);        /* weighted_pred_flag, weighted_bipred_idc (2 bits) */
    dc_ue(&b); dc_ue(&b); dc_ue(&b);        /* pic_init_qp/qs_minus26, chroma_qp_index_offset (se) */
    dc_u1(&b); dc_u1(&b);                   /* deblocking_filter_control, constrained_intra_pred */
    d->redundant = dc_u1(&b);
    d->have_pps = !b.bad;
}

/* Feed one Annex-B access unit (or Annex-B extradata). fps is the
 * container's frame rate (0: unknown, no rate check). Returns 1 when the
 * stream is certainly playable, 0 while no SPS and PPS have been seen, and
 * -1 with *why set when a transcode is needed. */
static inline int direct_check_au(struct direct_check *d, const uint8_t *au, size_t len,
                                  double fps, const char **why)
{
    d->chk.fps = (fps > 0 && fps <= 120) ? fps : 0;
    enum h264check v = h264check_au(&d->chk, au, len);
    for (size_t i = 0; !d->have_pps && i + 3 < len; i++) {
        if (au[i] || au[i + 1] || au[i + 2] != 1 || (au[i + 3] & 31u) != 8) continue;
        size_t end = i + 4;
        while (end + 2 < len && !(au[end] == 0 && au[end + 1] == 0 && au[end + 2] <= 1)) end++;
        if (end + 2 >= len) end = len;
        direct_check_pps(d, au + i + 4, end - i - 4);
    }
    if (v == H264C_UNKNOWN || !d->have_pps) return 0;
    if (v != H264C_OK) { *why = h264check_name(v); return -1; }
    if (d->chk.profile_idc != 77 && d->chk.profile_idc != 100) { *why = "profile (not Main or High)"; return -1; }
    if (d->chk.width_mbs > DIRECT_MAX_WIDTH_MBS) { *why = "picture width (wider than 1280)"; return -1; }
    if (d->slice_groups > 1) { *why = "slice groups"; return -1; }
    if (d->redundant) { *why = "redundant pictures"; return -1; }
    return 1;
}
#endif
