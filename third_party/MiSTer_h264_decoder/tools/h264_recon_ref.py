#!/usr/bin/env python3
"""The Phase 4 reconstruction as a Python reference: the front end's canonical
syntax-element records (tools/h264_fe_ref.py / h264_trace_ref.py: N, S, M, E, B) in,
decoded pictures out -- everything h264/dec/recon_top.sv and its units will do, in the
spec's own terms, scored bit-exact against ffmpeg (docs/h264_recon.md S1).

The model consumes the SE stream exactly as the RTL does (it never sees the bitstream):
parameter sets and slice headers from the S records, macroblocks from M/E/B. Scope is
the core's: Main and High profiles (H264 Phase 5: the 8x8 transform 8.5.13, Intra_8x8 8.3.2,
scaling matrices 8.5.9 with the fall-back rules of 7.4.2), frame AND field pictures
(PAFF), 4:2:0, 8-bit, no MBAFF (refused upstream by the front end).

Written against the 06/2026 spec text: 8.2.1 picture order count (types 0/1/2), 8.2.4
picture numbers and reference list initialisation / modification (frames and fields),
8.2.5 reference marking (sliding window, every MMCO), 8.3 intra prediction, 8.4 inter
prediction (MV prediction 8.4.1.3, P_Skip 8.4.1.1, spatial and temporal direct 8.4.1.2
with the co-located derivation of Table 8-6/8-8, quarter-sample luma and eighth-sample
chroma interpolation 8.4.2.2, weighted prediction 8.4.2.3 / 8.4.3), 8.5 scaling and
transforms (zig-zag and field scans), 8.7 deblocking. Clause numbers sit beside the code.

Output order: pictures are collected per coded video sequence (an IDR or an MMCO 5
starts a new one) and written in PicOrderCnt order, cropped, as ffmpeg does; a field
pair is written as one frame. The RTL's gate is the DECODE-order pre- and post-deblock
picture dump (`--dump`), compared macroblock by macroblock.

    h264_recon_ref.py stream.264 --yuv out.yuv            # display order, cropped
    h264_recon_ref.py stream.264 --check                  # ...and compare with ffmpeg
    h264_recon_ref.py stream.264 --dump dir/              # decode-order dumps for benches
"""
import argparse
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import high_tables as HT  # noqa: E402

P, B, I = 0, 1, 2


class ReconError(Exception):
    pass


# ---------------------------------------------------------------- tables

# Table 8-13: scan index -> raster index (4 * row + col); frame zig-zag and field scan
ZIGZAG = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
FIELD_SCAN = [0, 4, 1, 8, 12, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]

# 8.5.9 normAdjust4x4 (8-314 / 8-315)
NORM_ADJUST = [[10, 16, 13], [11, 18, 14], [13, 20, 16], [14, 23, 18], [16, 25, 20], [18, 29, 23]]


def norm_adjust4(m, i, j):
    if i % 2 == 0 and j % 2 == 0:
        return NORM_ADJUST[m][0]
    if i % 2 == 1 and j % 2 == 1:
        return NORM_ADJUST[m][1]
    return NORM_ADJUST[m][2]


def norm_adjust8(m, i, j):
    """8-317, v from 8-318 (tools/high_tables.py, transcribed from the PDF)."""
    v = HT.NORM_ADJUST8[m]
    if i % 4 == 0 and j % 4 == 0:
        return v[0]
    if i % 2 == 1 and j % 2 == 1:
        return v[1]
    if i % 4 == 2 and j % 4 == 2:
        return v[2]
    if (i % 4 == 0 and j % 2 == 1) or (i % 2 == 1 and j % 4 == 0):
        return v[3]
    if (i % 4 == 0 and j % 4 == 2) or (i % 4 == 2 and j % 4 == 0):
        return v[4]
    return v[5]


def level_scale4_table(wlist):
    """LevelScale4x4(m, i, j) = weightScale4x4(i, j) * normAdjust4x4(m, i, j) (8-313) for
    m = 0..5; `wlist` is the scaling list in coded order, inverse-scanned with the
    zig-zag scan whatever the picture structure (8.5.6: 'for a scaling list the inverse
    zig-zag scan is used')."""
    w = [0] * 16
    for k, v in enumerate(wlist):
        w[ZIGZAG[k]] = v
    return [[[w[4 * i + j] * norm_adjust4(m, i, j) for j in range(4)] for i in range(4)] for m in range(6)]


def level_scale8_table(wlist):
    """LevelScale8x8(m, i, j) (8-316), m = 0..5, as [m][8 * i + j]."""
    w = [0] * 64
    for k, v in enumerate(wlist):
        w[HT.ZIGZAG8[k]] = v
    return [[w[8 * i + j] * norm_adjust8(m, i, j) for i in range(8) for j in range(8)] for m in range(6)]


LEVEL_SCALE = level_scale4_table([16] * 16)            # Flat_4x4_16

# Table 8-15: QPc from qPI
QPC_TABLE = list(range(30)) + [29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39]

# Table 8-16 / 8-17
ALPHA = [0] * 16 + [4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28, 32, 36, 40, 45, 50, 56, 63, 71, 80, 90,
                    101, 113, 127, 144, 162, 182, 203, 226, 255, 255]
BETA = [0] * 16 + [2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
                   16, 16, 17, 17, 18, 18]
TC0 = [
    [0] * 23 + [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 6, 6, 7, 8, 9, 10, 11, 13],
    [0] * 21 + [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 7, 8, 8, 10, 11, 12, 13, 15, 17],
    [0] * 17 + [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 23, 25],
]
assert len(ALPHA) == 52 and len(BETA) == 52 and all(len(t) == 52 for t in TC0)


def blk_xy(idx):
    """luma4x4BlkIdx -> (x, y) (6.4.3)."""
    return (idx >> 2 & 1) * 8 + (idx & 1) * 4, (idx >> 3) * 8 + (idx >> 1 & 1) * 4


def xy_blk(x, y):
    return 8 * (y >> 3) + 4 * (x >> 3) + 2 * ((y & 7) >> 2) + ((x & 7) >> 2)


BLK_XY = [blk_xy(i) for i in range(16)]


def clip1(v):
    return np.clip(v, 0, 255)


def clip3(lo, hi, v):
    return lo if v < lo else hi if v > hi else v


def median(a, b, c):
    return a + b + c - min(a, b, c) - max(a, b, c)


# ---------------------------------------------------------------- macroblock types

I_NXN, I_PCM_IDX = 0, 25
P_8X8, B_DIRECT_16X16, B_8X8 = 3, 0, 22
L0, L1, BI, DIRECT = 1, 2, 3, 0
B_PAIR_PRED = [(L0, L0), (L1, L1), (L0, L1), (L1, L0), (L0, BI), (L1, BI), (BI, L0), (BI, L1), (BI, BI)]
P_SUB = {0: (L0, "8x8"), 1: (L0, "8x4"), 2: (L0, "4x8"), 3: (L0, "4x4")}
B_SUB = {0: (DIRECT, "4x4"), 1: (L0, "8x8"), 2: (L1, "8x8"), 3: (BI, "8x8"), 4: (L0, "8x4"), 5: (L0, "4x8"),
         6: (L1, "8x4"), 7: (L1, "4x8"), 8: (BI, "8x4"), 9: (BI, "4x8"), 10: (L0, "4x4"), 11: (L1, "4x4"), 12: (BI, "4x4")}
# partition rectangles (x, y, w, h) in the macroblock
PART_RECT = {"16x16": [(0, 0, 16, 16)], "16x8": [(0, 0, 16, 8), (0, 8, 16, 8)], "8x16": [(0, 0, 8, 16), (8, 0, 8, 16)]}
SUB_RECT = {"8x8": [(0, 0, 8, 8)], "8x4": [(0, 0, 8, 4), (0, 4, 8, 4)], "4x8": [(0, 0, 4, 8), (4, 0, 4, 8)],
            "4x4": [(0, 0, 4, 4), (4, 0, 4, 4), (0, 4, 4, 4), (4, 4, 4, 4)]}


def rect_blks(x, y, w, h):
    return [xy_blk(x + i, y + j) for j in range(0, h, 4) for i in range(0, w, 4)]


# ---------------------------------------------------------------- the record cursor

class Cursor(object):
    """A name-driven walk over a record list: the syntax order is the check."""

    def __init__(self, items):
        self.items = items
        self.i = 0

    def peek(self):
        return self.items[self.i] if self.i < len(self.items) else (None, None)

    def take(self, name):
        n, v = self.peek()
        if n != name:
            raise ReconError("expected %s, found %s" % (name, n))
        self.i += 1
        return v

    def opt(self, name):
        n, v = self.peek()
        if n == name:
            self.i += 1
            return v
        return None

    def done(self):
        return self.i >= len(self.items)


# ---------------------------------------------------------------- parameter sets and headers

class Sps(object):
    pass


class Pps(object):
    pass


def parse_sps_records(items):
    c = Cursor(items)
    s = Sps()
    s.profile_idc = c.take("profile_idc")
    for k in range(3):
        c.take("constraint_set%d_flag" % k)
    s.level_idc = c.take("level_idc")
    s.id = c.take("seq_parameter_set_id")
    s.scaling_present = 0
    s.scaling_lists = []
    if c.opt("chroma_format_idc") is not None:
        c.take("bit_depth_luma_minus8")
        c.take("bit_depth_chroma_minus8")
        c.take("lossless_qpprime_y_zero_flag")
        s.scaling_present = c.take("seq_scaling_matrix_present_flag")
        if s.scaling_present:
            s.scaling_lists = scaling_list_records(c, 8, "seq")
    s.log2_max_frame_num = c.take("log2_max_frame_num_minus4") + 4
    s.poc_type = c.take("pic_order_cnt_type")
    s.log2_max_poc_lsb = 0
    s.delta_pic_order_always_zero = 0
    s.offset_for_non_ref_pic = 0
    s.offset_for_top_to_bottom_field = 0
    s.offset_for_ref_frame = []
    if s.poc_type == 0:
        s.log2_max_poc_lsb = c.take("log2_max_pic_order_cnt_lsb_minus4") + 4
    elif s.poc_type == 1:
        s.delta_pic_order_always_zero = c.take("delta_pic_order_always_zero_flag")
        s.offset_for_non_ref_pic = c.take("offset_for_non_ref_pic")
        s.offset_for_top_to_bottom_field = c.take("offset_for_top_to_bottom_field")
        n = c.take("num_ref_frames_in_pic_order_cnt_cycle")
        s.offset_for_ref_frame = [c.take("offset_for_ref_frame[i]") for _ in range(n)]
    s.num_ref_frames = c.take("num_ref_frames")
    s.gaps_allowed = c.take("gaps_in_frame_num_value_allowed_flag")
    s.width_mbs = c.take("pic_width_in_mbs_minus1") + 1
    s.height_map_units = c.take("pic_height_in_map_units_minus1") + 1
    s.frame_mbs_only = c.take("frame_mbs_only_flag")
    if not s.frame_mbs_only:
        c.take("mb_adaptive_frame_field_flag")
    s.direct_8x8_inference = c.take("direct_8x8_inference_flag")
    s.crop = (0, 0, 0, 0)
    if c.take("frame_cropping_flag"):
        s.crop = tuple(c.take("frame_crop_%s_offset" % k) for k in ("left", "right", "top", "bottom"))
    c.take("vui_parameters_present_flag")
    # the VUI (P5): its scalar fields by name (the HRD loop's [i] fields are not kept);
    # h264_fe_ref.parse_vui is the syntax, this only reads what the display needs
    s.vui = {}
    while not c.done():
        n, v = c.peek()
        c.i += 1
        if not n.endswith("[i]"):
            s.vui.setdefault(n, v)
    s.frame_height_mbs = (2 - s.frame_mbs_only) * s.height_map_units
    s.width = 16 * s.width_mbs
    s.height = 16 * s.frame_height_mbs
    return s


def parse_pps_records(items):
    c = Cursor(items)
    p = Pps()
    p.id = c.take("pic_parameter_set_id")
    p.sps_id = c.take("seq_parameter_set_id")
    c.take("entropy_coding_mode_flag")
    p.bottom_field_pic_order_in_frame_present = c.take("bottom_field_pic_order_in_frame_present_flag")
    c.take("num_slice_groups_minus1")
    p.num_ref_idx_default = [c.take("num_ref_idx_l0_default_active_minus1") + 1,
                             c.take("num_ref_idx_l1_default_active_minus1") + 1]
    p.weighted_pred = c.take("weighted_pred_flag")
    p.weighted_bipred_idc = c.take("weighted_bipred_idc")
    p.pic_init_qp = c.take("pic_init_qp_minus26") + 26
    c.take("pic_init_qs_minus26")
    p.chroma_qp_index_offset = c.take("chroma_qp_index_offset")
    p.deblocking_filter_control_present = c.take("deblocking_filter_control_present_flag")
    p.constrained_intra_pred = c.take("constrained_intra_pred_flag")
    p.redundant_pic_cnt_present = c.take("redundant_pic_cnt_present_flag")
    p.second_chroma_qp_index_offset = p.chroma_qp_index_offset
    p.transform_8x8_mode = 0
    p.scaling_present = 0
    p.scaling_lists = []
    t8 = c.opt("transform_8x8_mode_flag")
    if t8 is not None:
        p.transform_8x8_mode = t8
        p.scaling_present = c.take("pic_scaling_matrix_present_flag")
        if p.scaling_present:
            p.scaling_lists = scaling_list_records(c, 6 + 2 * p.transform_8x8_mode, "pic")
        p.second_chroma_qp_index_offset = c.take("second_chroma_qp_index_offset")
    return p


def scaling_list_records(c, n, kind):
    """The lists of a scaling_matrix from its records (7.3.2.1.1.1 replayed on the
    delta_scale values): None when not present, "default", or the list (coded order)."""
    out = []
    for i in range(n):
        if not c.take("%s_scaling_list_present_flag[i]" % kind):
            out.append(None)
            continue
        size = 16 if i < 6 else 64
        last, nxt, lst = 8, 8, []
        for j in range(size):
            if nxt != 0:
                nxt = (last + c.take("delta_scale") + 256) % 256
                if j == 0 and nxt == 0:
                    lst = "default"
                    break
            lst.append(last if nxt == 0 else nxt)
            last = lst[-1]
        out.append(lst)
    return out


class SliceHeader(object):
    pass


def parse_slice_records(items, nal_type, nal_ref_idc, sps_map, pps_map):
    c = Cursor(items)
    h = SliceHeader()
    h.nal_ref_idc = nal_ref_idc
    h.first_mb = c.take("first_mb_in_slice")
    h.slice_type = c.take("slice_type") % 5
    h.pps_id = c.take("pic_parameter_set_id")
    pps = pps_map[h.pps_id]
    sps = sps_map[pps.sps_id]
    h.pps, h.sps = pps, sps
    h.frame_num = c.take("frame_num")
    h.field_pic = 0
    h.bottom_field = 0
    if not sps.frame_mbs_only:
        h.field_pic = c.take("field_pic_flag")
        if h.field_pic:
            h.bottom_field = c.take("bottom_field_flag")
    h.idr = nal_type == 5
    h.idr_pic_id = c.take("idr_pic_id") if h.idr else None
    h.poc_lsb = 0
    h.delta_poc_bottom = 0
    h.delta_poc = [0, 0]
    if sps.poc_type == 0:
        h.poc_lsb = c.take("pic_order_cnt_lsb")
        if pps.bottom_field_pic_order_in_frame_present and not h.field_pic:
            h.delta_poc_bottom = c.take("delta_pic_order_cnt_bottom")
    if sps.poc_type == 1 and not sps.delta_pic_order_always_zero:
        h.delta_poc[0] = c.take("delta_pic_order_cnt[0]")
        if pps.bottom_field_pic_order_in_frame_present and not h.field_pic:
            h.delta_poc[1] = c.take("delta_pic_order_cnt[1]")
    if pps.redundant_pic_cnt_present:
        c.take("redundant_pic_cnt")
    h.direct_spatial = 1
    if h.slice_type == B:
        h.direct_spatial = c.take("direct_spatial_mv_pred_flag")
    h.num_ref_idx = list(pps.num_ref_idx_default)
    h.mods = [[], []]
    if h.slice_type in (P, B):
        if c.take("num_ref_idx_active_override_flag"):
            h.num_ref_idx[0] = c.take("num_ref_idx_l0_active_minus1") + 1
            if h.slice_type == B:
                h.num_ref_idx[1] = c.take("num_ref_idx_l1_active_minus1") + 1
        for lx in range(2 if h.slice_type == B else 1):
            if c.take("ref_pic_list_modification_flag_l%d" % lx):
                while True:
                    idc = c.take("modification_of_pic_nums_idc_l%d" % lx)
                    if idc == 3:
                        break
                    if idc in (0, 1):
                        h.mods[lx].append((idc, c.take("abs_diff_pic_num_minus1_l%d" % lx)))
                    else:
                        h.mods[lx].append((idc, c.take("long_term_pic_num_l%d" % lx)))
    # 7.4.3.2: the weight tables (defaults when a flag is 0: 2^denom, offset 0)
    h.luma_log2_wd = h.chroma_log2_wd = 0
    h.weights = None
    if (pps.weighted_pred and h.slice_type == P) or (pps.weighted_bipred_idc == 1 and h.slice_type == B):
        h.luma_log2_wd = c.take("luma_log2_weight_denom")
        h.chroma_log2_wd = c.take("chroma_log2_weight_denom")
        h.weights = [[], []]
        for lx in range(2 if h.slice_type == B else 1):
            for _i in range(h.num_ref_idx[lx]):
                lw, lo = 1 << h.luma_log2_wd, 0
                cw = [[1 << h.chroma_log2_wd, 0], [1 << h.chroma_log2_wd, 0]]
                if c.take("luma_weight_flag_l%d" % lx):
                    lw = c.take("luma_weight_l%d" % lx)
                    lo = c.take("luma_offset_l%d" % lx)
                if c.take("chroma_weight_flag_l%d" % lx):
                    for j in range(2):
                        cw[j][0] = c.take("chroma_weight_l%d" % lx)
                        cw[j][1] = c.take("chroma_offset_l%d" % lx)
                h.weights[lx].append((lw, lo, cw))
    h.no_output_of_prior_pics = 0
    h.long_term_reference = 0
    h.mmco = None
    if nal_ref_idc:
        if h.idr:
            h.no_output_of_prior_pics = c.take("no_output_of_prior_pics_flag")
            h.long_term_reference = c.take("long_term_reference_flag")
        elif c.take("adaptive_ref_pic_marking_mode_flag"):
            h.mmco = []
            while True:
                op = c.take("memory_management_control_operation")
                if op == 0:
                    break
                args = {}
                if op in (1, 3):
                    args["diff"] = c.take("difference_of_pic_nums_minus1")
                if op == 2:
                    args["ltpn"] = c.take("long_term_pic_num")
                if op in (3, 6):
                    args["ltfi"] = c.take("long_term_frame_idx")
                if op == 4:
                    args["max1"] = c.take("max_long_term_frame_idx_plus1")
                h.mmco.append((op, args))
    if h.slice_type != I:
        c.take("cabac_init_idc")
    h.qp = pps.pic_init_qp + c.take("slice_qp_delta")
    h.disable_deblocking = 0
    h.alpha_off = h.beta_off = 0
    if pps.deblocking_filter_control_present:
        h.disable_deblocking = c.take("disable_deblocking_filter_idc")
        if h.disable_deblocking != 1:
            h.alpha_off = c.take("slice_alpha_c0_offset_div2") * 2
            h.beta_off = c.take("slice_beta_offset_div2") * 2
    # H264 Phase 5: the front end's resolved scaling matrix (tools/h264_fe_ref.py
    # scaling_words), present in the RTL goldens' streams: kept, and compared with this
    # model's own resolution from the raw lists at the slice (SliceDecoder)
    h.scaling_words = None
    if not c.done() and c.peek()[0] == "scaling_matrix_flag":
        h.scaling_words = [("scaling_matrix_flag", c.take("scaling_matrix_flag"))]
        if h.scaling_words[0][1]:
            h.scaling_words += [("scaling_list_word", c.take("scaling_list_word")) for _ in range(56)]
    # P5c: a picture's first slice carries its display facts after the header (the
    # picture timing SEI's fields up to pic_struct, then the access unit's PTS; each only
    # when present) -- kept for the display side, P5d
    h.timing = {}
    for name in ("cpb_removal_delay", "dpb_output_delay", "pic_struct", "au_pts_lo", "au_pts_hi"):
        if not c.done() and c.peek()[0] == name:
            h.timing[name] = c.take(name)
    if not c.done():
        raise ReconError("slice header records left over: %r" % (c.peek(),))
    h.has_mmco5 = bool(h.mmco) and any(op == 5 for op, _ in h.mmco)
    return h


# ---------------------------------------------------------------- pictures and the DPB

UNUSED, SHORT, LONG = 0, 1, 2
TOP, BOT = 0, 1


class MbInfo(object):
    """What later macroblocks, the co-located derivation and the deblocking filter ask of
    a decoded macroblock (the RTL's row-above / left / side-info stores)."""
    __slots__ = ("avail", "slice", "intra", "pcm", "i4", "qp", "qpc", "pcm_qpc", "modes", "mv", "ref", "refpic", "pred",
                 "nz", "disable_deblock", "alpha_off", "beta_off", "skip", "mb_type", "t8")

    def __init__(self):
        self.avail = 0
        self.slice = -1
        self.intra = 0
        self.pcm = 0
        self.i4 = 0                               # Intra_4x4 OR Intra_8x8 (8.3.1.1 / 8.3.2.1 read both)
        self.t8 = 0                               # transform_size_8x8_flag (8.7: internal edges, bS)
        self.qp = 0
        self.qpc = (0, 0)
        self.pcm_qpc = (0, 0)
        self.modes = [2] * 16                     # Intra4x4PredMode (DC when not Intra_4x4); an
                                                  # Intra_8x8 MB holds Intra8x8PredMode[b8] in all
                                                  # four of b8's slots (8.3.1.1 reads [idx >> 2])
        self.mv = [[(0, 0)] * 16, [(0, 0)] * 16]  # per 4x4 block, per list
        self.ref = [[-1] * 16, [-1] * 16]
        self.refpic = [[None] * 16, [None] * 16]  # (frame, structure) identity, None when unused
        self.pred = [[0] * 16, [0] * 16]
        self.nz = [0] * 16                        # a 4x4 luma block has non-zero levels (with
                                                  # the 8x8 transform: its 8x8 block has, 8.7.2.1)
        self.disable_deblock = 0
        self.alpha_off = 0
        self.beta_off = 0
        self.skip = 0
        self.mb_type = None


class Frame(object):
    """A frame store: samples plus, per field, the marking and the POC (8.2.5: a frame's
    marking is deduced from its fields); the coded macroblock info per coded picture
    ('F' for a frame, 'T'/'B' for fields) for the co-located derivation."""
    _next_id = 0

    def __init__(self, sps):
        self.id = Frame._next_id
        Frame._next_id += 1
        self.sps = sps
        self.Y = np.zeros((sps.height, sps.width), dtype=np.int32)
        self.Cb = np.zeros((sps.height // 2, sps.width // 2), dtype=np.int32)
        self.Cr = np.zeros((sps.height // 2, sps.width // 2), dtype=np.int32)
        self.ref = [UNUSED, UNUSED]
        self.decoded = [0, 0]
        self.poc = [None, None]
        self.frame_num = 0
        self.frame_num_wrap = 0
        self.long_idx = None
        self.mbinfo = {}                          # 'F' | 'T' | 'B' -> list of MbInfo
        self.coded_as_frame = 0
        self.mmco5 = 0
        self.seq = 0                              # output sequence index
        self.is_ref = 0                           # nal_ref_idc != 0 of its (first) picture
        self.first_parity = None
        # the output process (P5d, C.4.4 / C.4.5; the STORE is the output unit):
        self.waiting = False                      # "needed for output", in the DPB
        self.emitted = False                      # emitted once in this allocation
        self.pend_emit = False                    # output, but its pair is not complete yet

    def any_ref(self):
        return self.ref[0] != UNUSED or self.ref[1] != UNUSED

    def both(self, kind):
        return self.ref[0] == kind and self.ref[1] == kind

    def frame_poc(self):
        """PicOrderCnt of a frame or complementary field pair (8-1)."""
        p = [v for v in self.poc if v is not None]
        return min(p)

    def entry_poc(self, kind):
        """PicOrderCnt of a reference entry in field decoding: the fields marked `kind`."""
        p = [self.poc[f] for f in (0, 1) if self.ref[f] == kind and self.poc[f] is not None]
        return min(p)


class RefPic(object):
    """A reference picture as a list entry: a frame ('F') or one field ('T'/'B')."""
    __slots__ = ("frame", "struct")

    def __init__(self, frame, struct):
        self.frame = frame
        self.struct = struct

    def ident(self):
        return (self.frame.id, self.struct)

    def poc(self):
        if self.struct == "F":
            return self.frame.frame_poc()
        return self.frame.poc[0 if self.struct == "T" else 1]

    def marking(self):
        if self.struct == "F":
            return self.frame.ref[0] if self.frame.ref[0] == self.frame.ref[1] else UNUSED
        return self.frame.ref[0 if self.struct == "T" else 1]

    def planes(self):
        f = self.frame
        if self.struct == "F":
            return f.Y, f.Cb, f.Cr
        p = 0 if self.struct == "T" else 1
        return f.Y[p::2], f.Cb[p::2], f.Cr[p::2]

    def same_frame(self, other):
        return self.frame is other.frame


# ---------------------------------------------------------------- residual

def dequant4x4(levels, scan, qp, dc=None, ls4=LEVEL_SCALE):
    """8.5.6 inverse scan + 8.5.12.1 scaling of one 4x4 block. `levels` are the 16 (or 15,
    AC only) coefficient levels in scan order; `dc` is the pre-scaled DC value from the
    DC path (Intra16x16 luma / chroma), in which case d00 = dc. `ls4` = LevelScale4x4 of
    the block's scaling list (level_scale4_table)."""
    c = [0] * 16
    if len(levels) == 15:
        for k, v in enumerate(levels):
            c[scan[k + 1]] = v
    else:
        for k, v in enumerate(levels):
            c[scan[k]] = v
    d = [0] * 16
    m, q6 = qp % 6, qp // 6
    ls = ls4[m]
    for i in range(4):
        for j in range(4):
            v = c[4 * i + j]
            if i == 0 and j == 0 and dc is not None:
                d[0] = dc
            elif v == 0:
                d[4 * i + j] = 0
            elif qp >= 24:
                d[4 * i + j] = (v * ls[i][j]) << (q6 - 4)
            else:
                d[4 * i + j] = (v * ls[i][j] + (1 << (3 - q6))) >> (4 - q6)
    return d


def itrans4x4(d):
    """8.5.12.2: the inverse 4x4 integer transform, rows then columns; returns r (16, raster)."""
    f = [0] * 16
    for i in range(4):
        d0, d1, d2, d3 = d[4 * i], d[4 * i + 1], d[4 * i + 2], d[4 * i + 3]
        e0 = d0 + d2
        e1 = d0 - d2
        e2 = (d1 >> 1) - d3
        e3 = d1 + (d3 >> 1)
        f[4 * i] = e0 + e3
        f[4 * i + 1] = e1 + e2
        f[4 * i + 2] = e1 - e2
        f[4 * i + 3] = e0 - e3
    r = [0] * 16
    for j in range(4):
        f0, f1, f2, f3 = f[j], f[4 + j], f[8 + j], f[12 + j]
        g0 = f0 + f2
        g1 = f0 - f2
        g2 = (f1 >> 1) - f3
        g3 = f1 + (f3 >> 1)
        r[j] = (g0 + g3 + 32) >> 6
        r[4 + j] = (g1 + g2 + 32) >> 6
        r[8 + j] = (g1 - g2 + 32) >> 6
        r[12 + j] = (g0 - g3 + 32) >> 6
    return r


def dequant8x8(levels, scan8, qp, ls8):
    """8.5.7 inverse 8x8 scan + 8.5.13.1 scaling: `levels` are 64 in scan order, `ls8` =
    LevelScale8x8 of the block's scaling list (level_scale8_table). Raster d."""
    c = [0] * 64
    for k, v in enumerate(levels):
        c[scan8[k]] = v
    m, q6 = qp % 6, qp // 6
    ls = ls8[m]
    d = [0] * 64
    for k in range(64):
        v = c[k]
        if v == 0:
            continue
        if qp >= 36:
            d[k] = (v * ls[k]) << (q6 - 6)                               # 8-356
        else:
            d[k] = (v * ls[k] + (1 << (5 - q6))) >> (6 - q6)             # 8-357
    return d


def _itrans8_1d(d):
    """One 8-point pass of 8.5.13.2 (8-358 .. 8-381)."""
    d0, d1, d2, d3, d4, d5, d6, d7 = d
    e0 = d0 + d4
    e1 = -d3 + d5 - d7 - (d7 >> 1)
    e2 = d0 - d4
    e3 = d1 + d7 - d3 - (d3 >> 1)
    e4 = (d2 >> 1) - d6
    e5 = -d1 + d7 + d5 + (d5 >> 1)
    e6 = d2 + (d6 >> 1)
    e7 = d3 + d5 + d1 + (d1 >> 1)
    f0 = e0 + e6
    f1 = e1 + (e7 >> 2)
    f2 = e2 + e4
    f3 = e3 + (e5 >> 2)
    f4 = e2 - e4
    f5 = (e3 >> 2) - e5
    f6 = e0 - e6
    f7 = e7 - (e1 >> 2)
    return [f0 + f7, f2 + f5, f4 + f3, f6 + f1, f6 - f1, f4 - f3, f2 - f5, f0 - f7]


def itrans8x8(d):
    """8.5.13.2: rows (horizontal) then columns; r = (m + 32) >> 6 (8-406). Raster."""
    g = []
    for i in range(8):
        g.extend(_itrans8_1d(d[8 * i:8 * i + 8]))
    r = [0] * 64
    for j in range(8):
        m = _itrans8_1d([g[8 * i + j] for i in range(8)])
        for i in range(8):
            r[8 * i + j] = (m[i] + 32) >> 6
    return r


def luma_dc(levels, scan, qp, ls4=LEVEL_SCALE):
    """8.5.10: Intra16x16 DC -- inverse scan, Hadamard, scaling; returns dcY as 16 raster (i, j)."""
    c = [0] * 16
    for k, v in enumerate(levels):
        c[scan[k]] = v
    # f = H c H with H = [[1,1,1,1],[1,1,-1,-1],[1,-1,-1,1],[1,-1,1,-1]]
    H = [[1, 1, 1, 1], [1, 1, -1, -1], [1, -1, -1, 1], [1, -1, 1, -1]]
    t = [[sum(H[i][k] * c[4 * k + j] for k in range(4)) for j in range(4)] for i in range(4)]
    f = [[sum(t[i][k] * H[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
    ls = ls4[qp % 6][0][0]
    out = [0] * 16
    for i in range(4):
        for j in range(4):
            if qp >= 36:
                out[4 * i + j] = (f[i][j] * ls) << (qp // 6 - 6)
            else:
                out[4 * i + j] = (f[i][j] * ls + (1 << (5 - qp // 6))) >> (6 - qp // 6)
    return out


def chroma_dc(levels, qp, ls4=LEVEL_SCALE):
    """8.5.11 (4:2:0): the 2x2 DC transform and scaling; returns [dc00, dc01, dc10, dc11]."""
    c0, c1, c2, c3 = levels
    f = [c0 + c1 + c2 + c3, c0 - c1 + c2 - c3, c0 + c1 - c2 - c3, c0 - c1 - c2 + c3]
    ls = ls4[qp % 6][0][0]
    return [((v * ls) << (qp // 6)) >> 5 for v in f]


# ---------------------------------------------------------------- intra prediction

def intra4x4_pred(p, mode, blk_idx):
    """8.3.1.2: p[x, y] samples with x = -1, y = -1..3 and x = 0..7, y = -1 given as
    top[0..7] (p[x,-1]), left[0..3] (p[-1,y]), tl (p[-1,-1]); None = not available.
    Returns 16 raster samples."""
    top, left, tl = p
    out = [0] * 16

    def T(x):
        return top[x]

    def Lf(y):
        return left[y]
    if mode == 0:
        for y in range(4):
            for x in range(4):
                out[4 * y + x] = T(x)
    elif mode == 1:
        for y in range(4):
            for x in range(4):
                out[4 * y + x] = Lf(y)
    elif mode == 2:
        ta = top is not None
        la = left is not None
        if ta and la:
            v = (sum(top[:4]) + sum(left) + 4) >> 3
        elif la:
            v = (sum(left) + 2) >> 2
        elif ta:
            v = (sum(top[:4]) + 2) >> 2
        else:
            v = 128
        out = [v] * 16
    elif mode == 3:
        for y in range(4):
            for x in range(4):
                if x == 3 and y == 3:
                    out[4 * y + x] = (T(6) + 3 * T(7) + 2) >> 2
                else:
                    out[4 * y + x] = (T(x + y) + 2 * T(x + y + 1) + T(x + y + 2) + 2) >> 2
    elif mode == 4:
        for y in range(4):
            for x in range(4):
                if x > y:
                    out[4 * y + x] = (Tm(top, tl, x - y - 2) + 2 * Tm(top, tl, x - y - 1) + T(x - y) + 2) >> 2
                elif x < y:
                    out[4 * y + x] = (Lm(left, tl, y - x - 2) + 2 * Lm(left, tl, y - x - 1) + Lf(y - x) + 2) >> 2
                else:
                    out[4 * y + x] = (T(0) + 2 * tl + Lf(0) + 2) >> 2
    elif mode == 5:
        for y in range(4):
            for x in range(4):
                z = 2 * x - y
                if z >= 0 and z % 2 == 0:
                    out[4 * y + x] = (Tm(top, tl, x - (y >> 1) - 1) + Tm(top, tl, x - (y >> 1)) + 1) >> 1
                elif z > 0:
                    out[4 * y + x] = (Tm(top, tl, x - (y >> 1) - 2) + 2 * Tm(top, tl, x - (y >> 1) - 1) + Tm(top, tl, x - (y >> 1)) + 2) >> 2
                elif z == -1:
                    out[4 * y + x] = (Lf(0) + 2 * tl + T(0) + 2) >> 2
                else:
                    out[4 * y + x] = (Lf(y - 1) + 2 * Lf(y - 2) + Lm(left, tl, y - 3) + 2) >> 2
    elif mode == 6:
        for y in range(4):
            for x in range(4):
                z = 2 * y - x
                if z >= 0 and z % 2 == 0:
                    out[4 * y + x] = (Lm(left, tl, y - (x >> 1) - 1) + Lm(left, tl, y - (x >> 1)) + 1) >> 1
                elif z > 0:
                    out[4 * y + x] = (Lm(left, tl, y - (x >> 1) - 2) + 2 * Lm(left, tl, y - (x >> 1) - 1) + Lm(left, tl, y - (x >> 1)) + 2) >> 2
                elif z == -1:
                    out[4 * y + x] = (Lf(0) + 2 * tl + T(0) + 2) >> 2
                else:
                    out[4 * y + x] = (T(x - 1) + 2 * T(x - 2) + Tm(top, tl, x - 3) + 2) >> 2
    elif mode == 7:
        for y in range(4):
            for x in range(4):
                if y % 2 == 0:
                    out[4 * y + x] = (T(x + (y >> 1)) + T(x + (y >> 1) + 1) + 1) >> 1
                else:
                    out[4 * y + x] = (T(x + (y >> 1)) + 2 * T(x + (y >> 1) + 1) + T(x + (y >> 1) + 2) + 2) >> 2
    elif mode == 8:
        for y in range(4):
            for x in range(4):
                z = x + 2 * y
                if z < 5 and z % 2 == 0:
                    out[4 * y + x] = (Lf(y + (x >> 1)) + Lf(y + (x >> 1) + 1) + 1) >> 1
                elif z < 5:
                    out[4 * y + x] = (Lf(y + (x >> 1)) + 2 * Lf(y + (x >> 1) + 1) + Lf(y + (x >> 1) + 2) + 2) >> 2
                elif z == 5:
                    out[4 * y + x] = (Lf(2) + 3 * Lf(3) + 2) >> 2
                else:
                    out[4 * y + x] = Lf(3)
    else:
        raise ReconError("Intra4x4PredMode %d" % mode)
    return out


def intra8x8_pred(top, left, tl, mode):
    """8.3.2.2: top = p[0..15, -1], left = p[-1, 0..7], tl = p[-1, -1], each sample None
    when "not available for Intra_8x8 prediction" (after the p[7, -1] substitution for
    p[8..15, -1]). The reference filter 8.3.2.2.1, then the mode (8.3.2.2.2 .. .10).
    Returns 64 raster samples."""
    ta = all(v is not None for v in top[:16])        # the filter needs all of x = 0..15
    la = all(v is not None for v in left)
    tla = tl is not None
    t = [0] * 16
    lf = [0] * 8
    ctl = 0
    if ta:                                           # 8-78 .. 8-81
        t[0] = (tl + 2 * top[0] + top[1] + 2) >> 2 if tla else (3 * top[0] + top[1] + 2) >> 2
        for x in range(1, 15):
            t[x] = (top[x - 1] + 2 * top[x] + top[x + 1] + 2) >> 2
        t[15] = (top[14] + 3 * top[15] + 2) >> 2
    if tla:                                          # 8-82 .. 8-84
        p0a, l0a = top[0] is not None, left[0] is not None
        if not p0a or not l0a:
            if p0a:
                ctl = (3 * tl + top[0] + 2) >> 2
            elif l0a:
                ctl = (3 * tl + left[0] + 2) >> 2
            else:
                ctl = tl
        else:
            ctl = (top[0] + 2 * tl + left[0] + 2) >> 2
    if la:                                           # 8-85 .. 8-88
        lf[0] = (tl + 2 * left[0] + left[1] + 2) >> 2 if tla else (3 * left[0] + left[1] + 2) >> 2
        for y in range(1, 7):
            lf[y] = (left[y - 1] + 2 * left[y] + left[y + 1] + 2) >> 2
        lf[7] = (left[6] + 3 * left[7] + 2) >> 2
    # the "shall be used only when" availabilities are the samples the mode reads; the
    # filter above ran only when ALL of p[0..15, -1] were available, which the 0..7
    # modes (x = 8..15 are substituted from p[7, -1] when missing) always satisfy
    t8a = all(v is not None for v in top[:8])

    def T(x):
        return t[x]

    def Lq(y):
        return ctl if y < 0 else lf[y]
    out = [0] * 64
    for y in range(8):
        for x in range(8):
            if mode == 0:
                v = T(x)
            elif mode == 1:
                v = lf[y]
            elif mode == 2:
                if t8a and la:
                    v = (sum(t[:8]) + sum(lf) + 8) >> 4
                elif la:
                    v = (sum(lf) + 4) >> 3
                elif t8a:
                    v = (sum(t[:8]) + 4) >> 3
                else:
                    v = 128
            elif mode == 3:
                if x == 7 and y == 7:
                    v = (T(14) + 3 * T(15) + 2) >> 2
                else:
                    v = (T(x + y) + 2 * T(x + y + 1) + T(x + y + 2) + 2) >> 2
            elif mode == 4:
                if x > y:
                    k = x - y
                    v = ((ctl if k - 2 < 0 else T(k - 2)) + 2 * T(k - 1) + T(k) + 2) >> 2
                elif x < y:
                    k = y - x
                    v = (Lq(k - 2) + 2 * Lq(k - 1) + Lq(k) + 2) >> 2
                else:
                    v = (T(0) + 2 * ctl + lf[0] + 2) >> 2
            elif mode == 5:
                z = 2 * x - y
                if z >= 0 and z % 2 == 0:
                    a = x - (y >> 1)
                    v = ((ctl if a - 1 < 0 else T(a - 1)) + T(a) + 1) >> 1
                elif z >= 0:
                    a = x - (y >> 1)
                    v = ((ctl if a - 2 < 0 else T(a - 2)) + 2 * (ctl if a - 1 < 0 else T(a - 1)) + T(a) + 2) >> 2
                elif z == -1:
                    v = (lf[0] + 2 * ctl + T(0) + 2) >> 2
                else:
                    k = y - 2 * x
                    v = (Lq(k - 1) + 2 * Lq(k - 2) + Lq(k - 3) + 2) >> 2
            elif mode == 6:
                z = 2 * y - x
                if z >= 0 and z % 2 == 0:
                    a = y - (x >> 1)
                    v = (Lq(a - 1) + Lq(a) + 1) >> 1
                elif z >= 0:
                    a = y - (x >> 1)
                    v = (Lq(a - 2) + 2 * Lq(a - 1) + Lq(a) + 2) >> 2
                elif z == -1:
                    v = (lf[0] + 2 * ctl + T(0) + 2) >> 2
                else:
                    k = x - 2 * y
                    v = ((ctl if k - 1 < 0 else T(k - 1)) + 2 * (ctl if k - 2 < 0 else T(k - 2)) +
                         (ctl if k - 3 < 0 else T(k - 3)) + 2) >> 2
            elif mode == 7:
                a = x + (y >> 1)
                if y % 2 == 0:
                    v = (T(a) + T(a + 1) + 1) >> 1
                else:
                    v = (T(a) + 2 * T(a + 1) + T(a + 2) + 2) >> 2
            else:
                z = x + 2 * y
                a = y + (x >> 1)
                if z <= 12 and z % 2 == 0:
                    v = (lf[a] + lf[a + 1] + 1) >> 1
                elif z < 13:
                    v = (lf[a] + 2 * lf[a + 1] + lf[a + 2] + 2) >> 2
                elif z == 13:
                    v = (lf[6] + 3 * lf[7] + 2) >> 2
                else:
                    v = lf[7]
            out[8 * y + x] = v
    return out


def Tm(top, tl, x):
    """p[x, -1] with x = -1 meaning p[-1, -1]."""
    return tl if x < 0 else top[x]


def Lm(left, tl, y):
    return tl if y < 0 else left[y]


def intra16x16_pred(mode, top, left, tl):
    """8.3.3: top[0..15], left[0..15], tl; None when not available. Returns a 16x16 array."""
    out = np.zeros((16, 16), dtype=np.int32)
    if mode == 0:
        out[:, :] = np.array(top)[None, :]
    elif mode == 1:
        out[:, :] = np.array(left)[:, None]
    elif mode == 2:
        if top is not None and left is not None:
            v = (sum(top) + sum(left) + 16) >> 5
        elif left is not None:
            v = (sum(left) + 8) >> 4
        elif top is not None:
            v = (sum(top) + 8) >> 4
        else:
            v = 128
        out[:, :] = v
    elif mode == 3:
        H = sum((x + 1) * (top[8 + x] - (top[6 - x] if 6 - x >= 0 else tl)) for x in range(8))
        V = sum((y + 1) * (left[8 + y] - (left[6 - y] if 6 - y >= 0 else tl)) for y in range(8))
        a = 16 * (left[15] + top[15])
        b = (5 * H + 32) >> 6
        c = (5 * V + 32) >> 6
        for y in range(16):
            for x in range(16):
                out[y, x] = clip3(0, 255, (a + b * (x - 7) + c * (y - 7) + 16) >> 5)
    return out


def intra_chroma_pred(mode, top, left, tl):
    """8.3.4 for 4:2:0: top[0..7], left[0..7], tl. Returns an 8x8 array."""
    out = np.zeros((8, 8), dtype=np.int32)
    if mode == 0:
        for yo in (0, 4):
            for xo in (0, 4):
                ta = top is not None
                la = left is not None
                st = sum(top[xo:xo + 4]) if ta else 0
                sl = sum(left[yo:yo + 4]) if la else 0
                if (xo == 0 and yo == 0) or (xo > 0 and yo > 0):
                    if ta and la:
                        v = (st + sl + 4) >> 3
                    elif la:
                        v = (sl + 2) >> 2
                    elif ta:
                        v = (st + 2) >> 2
                    else:
                        v = 128
                elif xo > 0:
                    if ta:
                        v = (st + 2) >> 2
                    elif la:
                        v = (sl + 2) >> 2
                    else:
                        v = 128
                else:
                    if la:
                        v = (sl + 2) >> 2
                    elif ta:
                        v = (st + 2) >> 2
                    else:
                        v = 128
                out[yo:yo + 4, xo:xo + 4] = v
    elif mode == 1:
        out[:, :] = np.array(left)[:, None]
    elif mode == 2:
        out[:, :] = np.array(top)[None, :]
    elif mode == 3:
        H = sum((x + 1) * (top[4 + x] - (top[2 - x] if 2 - x >= 0 else tl)) for x in range(4))
        V = sum((y + 1) * (left[4 + y] - (left[2 - y] if 2 - y >= 0 else tl)) for y in range(4))
        a = 16 * (left[7] + top[7])
        b = (34 * H + 32) >> 6
        c = (34 * V + 32) >> 6
        for y in range(8):
            for x in range(8):
                out[y, x] = clip3(0, 255, (a + b * (x - 3) + c * (y - 3) + 16) >> 5)
    return out


# ---------------------------------------------------------------- inter prediction: interpolation

def ref_window(plane, x0, y0, w, h):
    """plane[y0:y0+h, x0:x0+w] with the coordinates clamped into the picture (8.4.2.2.1:
    xInt = Clip3(0, PicWidth - 1, ...)); a numpy fancy-index gather."""
    H, W = plane.shape
    ys = np.clip(np.arange(y0, y0 + h), 0, H - 1)
    xs = np.clip(np.arange(x0, x0 + w), 0, W - 1)
    return plane[ys[:, None], xs[None, :]]


def tap6(a, b, c, d, e, f):
    return a - 5 * b + 20 * c + 20 * d - 5 * e + f


def mc_luma(plane, x, y, w, h, mvx, mvy):
    """8.4.2.2.1: the w x h luma prediction at integer position (x, y) + mv (quarter
    samples). Returns an int32 array (h, w)."""
    xi, yi = x + (mvx >> 2), y + (mvy >> 2)
    xf, yf = mvx & 3, mvy & 3
    # the window: rows yi-2 .. yi+h+2, cols xi-2 .. xi+w+2 (6-tap reach +1 row/col for m/s)
    win = ref_window(plane, xi - 2, yi - 2, w + 6, h + 6).astype(np.int64)
    G = win[2:2 + h, 2:2 + w]
    if xf == 0 and yf == 0:
        return G.astype(np.int32)
    # b1: horizontal half-sample intermediates at every row of the window (rows 0..h+5)
    b1 = tap6(win[:, 0:w + 1], win[:, 1:w + 2], win[:, 2:w + 3], win[:, 3:w + 4], win[:, 4:w + 5], win[:, 5:w + 6])
    # b1 has shape (h+6, w+1): column k is the half-sample between win col k+2 and k+3
    # h1: vertical half-sample intermediates at every column (cols 0..w+5), rows 0..h
    h1 = tap6(win[0:h + 1, :], win[1:h + 2, :], win[2:h + 3, :], win[3:h + 4, :], win[4:h + 5, :], win[5:h + 6, :])
    # h1 shape (h+1, w+6): row k is the half-sample between win row k+2 and k+3

    def bb(row_off, col_off):
        # b at output rows (+row_off) and half-column x + col_off
        return clip1((b1[2 + row_off:2 + row_off + h, col_off:col_off + w] + 16) >> 5)

    def hh(row_off, col_off):
        return clip1((h1[row_off:row_off + h, 2 + col_off:2 + col_off + w] + 16) >> 5)

    def jj():
        # j1 from the b1 intermediates vertically (equivalently h1 horizontally)
        j1 = tap6(b1[0:h, 0:w], b1[1:h + 1, 0:w], b1[2:h + 2, 0:w], b1[3:h + 3, 0:w], b1[4:h + 4, 0:w], b1[5:h + 5, 0:w])
        return clip1((j1 + 512) >> 10)

    def Gi(row_off, col_off):
        return win[2 + row_off:2 + row_off + h, 2 + col_off:2 + col_off + w]

    def avg(a, b):
        return (a + b + 1) >> 1
    if yf == 0:
        b = bb(0, 0)
        if xf == 1:
            r = avg(Gi(0, 0), b)
        elif xf == 2:
            r = b
        else:
            r = avg(Gi(0, 1), b)
    elif xf == 0:
        hv = hh(0, 0)
        if yf == 1:
            r = avg(Gi(0, 0), hv)
        elif yf == 2:
            r = hv
        else:
            r = avg(Gi(1, 0), hv)
    elif xf == 2 and yf == 2:
        r = jj()
    elif xf == 2:
        j = jj()
        b = bb(0, 0)
        s = bb(1, 0)
        r = avg(b, j) if yf == 1 else avg(j, s)
    elif yf == 2:
        j = jj()
        hv = hh(0, 0)
        m = hh(0, 1)
        r = avg(hv, j) if xf == 1 else avg(j, m)
    else:
        # diagonal quarter positions e, g, p, r
        b = bb(0, 0)
        s = bb(1, 0)
        hv = hh(0, 0)
        m = hh(0, 1)
        if xf == 1 and yf == 1:
            r = avg(b, hv)
        elif xf == 3 and yf == 1:
            r = avg(b, m)
        elif xf == 1 and yf == 3:
            r = avg(hv, s)
        else:
            r = avg(m, s)
    return r.astype(np.int32)


def mc_chroma(plane, x, y, w, h, mvx, mvy):
    """8.4.2.2.2 (4:2:0): eighth-sample bilinear; (x, y) in chroma samples, mv in eighths."""
    xi, yi = x + (mvx >> 3), y + (mvy >> 3)
    xf, yf = mvx & 7, mvy & 7
    win = ref_window(plane, xi, yi, w + 1, h + 1).astype(np.int64)
    A = win[0:h, 0:w]
    Bq = win[0:h, 1:w + 1]
    C = win[1:h + 1, 0:w]
    D = win[1:h + 1, 1:w + 1]
    r = ((8 - xf) * (8 - yf) * A + xf * (8 - yf) * Bq + (8 - xf) * yf * C + xf * yf * D + 32) >> 6
    return r.astype(np.int32)


# ---------------------------------------------------------------- the decoder

class Picture(object):
    """The picture being decoded: a frame or one field of a frame store."""

    def __init__(self, frame, struct, h):
        self.frame = frame
        self.struct = struct                     # 'F', 'T', 'B'
        self.field = struct != "F"
        self.bottom = struct == "B"
        self.sps = h.sps
        self.w = h.sps.width_mbs
        self.hgt = h.sps.frame_height_mbs // (2 if self.field else 1)
        self.n_mbs = self.w * self.hgt
        self.Y, self.Cb, self.Cr = RefPic(frame, struct).planes()
        self.mbs = [MbInfo() for _ in range(self.n_mbs)]
        frame.mbinfo[struct] = self.mbs
        self.slices = []                         # headers, in order
        self.slice_lists = []                    # the reference lists of each slice
        self.is_ref = h.nal_ref_idc != 0
        self.idr = h.idr
        self.mmco5 = h.has_mmco5
        self.frame_num = h.frame_num
        self.poc = None

    def as_ref(self):
        return RefPic(self.frame, self.struct)


# Table A-1 MaxDpbMbs by level_idc (level 1b coded as level_idc 11 + constraint_set3 is
# read as 1.1 -- the front end does not keep constraint_set3: a LARGER DPB, which adds
# output latency and never changes the order; docs/display.md)
MAX_DPB_MBS = {9: 396, 10: 396, 11: 900, 12: 2376, 13: 2376, 20: 2376, 21: 4752, 22: 8100, 30: 8100,
               31: 18000, 32: 20480, 40: 32768, 41: 32768, 42: 34816, 50: 110400, 51: 184320,
               52: 184320}


def dpb_size(sps):
    """The DPB size the bumping process fills to (C.4, E.2.1): max_dec_frame_buffering when
    the VUI carries it (Max(1, it): a zero there only fits an intra stream), else
    MaxDpbFrames = Min(MaxDpbMbs / (PicWidthInMbs * FrameHeightInMbs), 16) (A.3.1)."""
    vui = getattr(sps, "vui", {}) or {}
    if vui.get("bitstream_restriction_flag"):
        return max(1, min(16, vui.get("max_dec_frame_buffering", 16)))
    mbs = MAX_DPB_MBS.get(sps.level_idc, 8100)
    return max(1, min(16, mbs // (sps.width_mbs * sps.frame_height_mbs)))


def num_reorder(sps):
    """E.2.1: max_num_reorder_frames when the VUI carries it (bitstream_restriction_flag);
    0 for POC type 2, whose output order is its decoding order (8.2.1.3); else None: no
    early output, the bumping process alone (roadmap P3d; h264/dec/recon_dpb.sv EARLY OUTPUT)."""
    vui = getattr(sps, "vui", {}) or {}
    if vui.get("bitstream_restriction_flag"):
        return vui.get("max_num_reorder_frames", 16)
    if sps.poc_type == 2:
        return 0
    return None


class Decoder(object):
    def __init__(self, on_picture=None, verbose=False):
        self.sps_map = {}
        self.pps_map = {}
        self.dpb = []                            # Frame objects with any field marked, or pending output
        self.out = []                            # decoded frames in decode order (for output)
        self.pic = None
        self.prev_pic = None                     # previous picture in decoding order (field pairing)
        self.on_picture = on_picture
        self.verbose = verbose
        self.seq = 0
        # coverage of the control paths (tools/jm_fixtures.py asserts a fixture reaches its
        # own): b_swap (8.2.4.2.3/4), mmco_frame / mmco_field / mmco_op<n> (8.2.5.4), mod
        # (8.2.4.3 operations), mod_dup_removed (a later duplicate dropped), mod_dup_used
        # (a partition predicted from a list index the removal changed), lt_used (a
        # partition predicted from a long-term reference)
        self.cov = {}
        self.mod_diff = [set(), set()]
        # POC state (8.2.1)
        self.prev_poc_msb = 0
        self.prev_poc_lsb = 0
        self.prev_frame_num_offset = 0
        self.prev_frame_num = 0
        self.prev_ref_has_mmco5 = 0
        self.prev_ref_is_bottom = 0
        self.prev_ref_top_poc = 0
        self.prev_has_mmco5 = 0
        self.max_long_term_frame_idx = None
        self.prev_ref_frame_num = 0
        # record state
        self.nal_type = None
        self.nal_ref_idc = 0
        self.hdr_items = []
        self.hdr = None
        self.sd = None
        self.n_pictures = 0
        # the output process (P5d): stores emitted to the display, in order; each entry
        # (frame, the decode count when it was emitted, how: 'bump' / 'direct' / 'eos' / 'unpaired')
        self.emitted = []
        self.waitq = []                          # frames "needed for output" in the DPB
        self.out_cnt = {"dropped": 0, "direct": 0, "over": 0, "deferred": 0, "nrf_late": 0}
        self.last_out_poc = None                 # the last POC emitted since an IDR / MMCO 5
        # per picture, for tools/dpb_output_ref.py (the per-picture spec process): the
        # picture, its flags, the DPB size, and every store's reference marking after it
        self.pic_events = []

    # ---- records --------------------------------------------------------------------

    def feed(self, records):
        for r in records:
            k = r[0]
            if k == "N":
                self.end_nal()
                _n, t, ref = r.split(" ")
                self.nal_type, self.nal_ref_idc = int(t), int(ref)
                self.hdr_items = []
                self.hdr = None
            elif k == "S":
                _s, name, v = r.split(" ")
                self.hdr_items.append((name, int(v)))
            elif k == "M":
                if self.hdr is None:
                    self.start_slice()
                self.sd.mb_start(int(r.split(" ")[1]))
            elif k == "E":
                _e, name, v = r.split(" ")
                self.sd.se(name, int(v))
            elif k == "B":
                f = r.split(" ")
                self.sd.block(f[1], int(f[2]), [int(v) for v in f[4:4 + int(f[3])]])
        self.end_nal()
        self.finish_picture()

    def end_nal(self):
        if self.nal_type == 7 and self.hdr_items:
            s = parse_sps_records(self.hdr_items)
            self.sps_map[s.id] = s
        elif self.nal_type == 8 and self.hdr_items:
            p = parse_pps_records(self.hdr_items)
            self.pps_map[p.id] = p
        elif self.nal_type in (1, 5) and self.hdr is not None:
            self.sd.end()
        self.nal_type = None
        self.hdr_items = []
        self.hdr = None

    # ---- pictures -------------------------------------------------------------------

    def start_slice(self):
        h = parse_slice_records(self.hdr_items, self.nal_type, self.nal_ref_idc, self.sps_map, self.pps_map)
        self.hdr = h
        if h.first_mb == 0 or self.pic is None:
            self.finish_picture()
            self.start_picture(h)
        self.pic.slices.append(h)
        self.pic_is_ref = h.nal_ref_idc != 0
        self.build_ref_lists(h)
        # a snapshot as the slice sees it (the marking changes when the picture completes)
        self.pic.slice_lists.append([[None if e is None else (e.frame.id, e.struct, e.poc(), e.marking())
                                      for e in self.ref_lists[lx]] for lx in range(2)])
        self.sd = SliceDecoder(self, self.pic, h, len(self.pic.slices))

    def start_picture(self, h):
        sps = h.sps
        if h.idr:
            self.seq += 1
        # 8.2.5.2: gaps in frame_num are not modelled (the RTL counts them as errors)
        if not h.idr and h.frame_num != self.prev_ref_frame_num and h.frame_num != (self.prev_ref_frame_num + 1) % (1 << sps.log2_max_frame_num):
            pairing = (self.prev_pic is not None and self.prev_pic.field and h.field_pic
                       and h.frame_num == self.prev_pic.frame_num)
            if not pairing:
                raise ReconError("gap in frame_num (%d after %d)" % (h.frame_num, self.prev_ref_frame_num))
        # the frame store: the second field of a pair shares the first field's (7.4.1.2.4)
        frame = None
        struct = "F"
        if h.field_pic:
            struct = "B" if h.bottom_field else "T"
            pp = self.prev_pic
            if (pp is not None and pp.field and pp.struct != struct and pp.frame_num == h.frame_num
                    and not h.idr and not pp.mmco5 and pp.is_ref == (h.nal_ref_idc != 0)
                    and not pp.frame.decoded[0 if struct == "T" else 1]):
                frame = pp.frame
        # a store output before its pair completed (C.4.5.2, a first field): emitted now
        # unless this picture is its second field (then when that completes)
        for fr in [x for x in self.out[-2:] if x.pend_emit and x is not frame]:
            self.emit(fr, "unpaired")
        if frame is None:
            frame = Frame(sps)
            frame.seq = self.seq
            frame.is_ref = h.nal_ref_idc != 0
            frame.first_parity = struct
            self.out.append(frame)
        frame.frame_num = h.frame_num
        pic = Picture(frame, struct, h)
        if struct == "F":
            frame.coded_as_frame = 1
        self.pic = pic
        self.n_pictures += 1
        self.decode_poc(h, pic)
        if self.verbose:
            print("picture %d: %s frame_num %d poc %s %s%s" % (
                self.n_pictures, {"F": "frame", "T": "top", "B": "bottom"}[struct], h.frame_num, pic.poc,
                "IPB"[h.slice_type] if h.slice_type != I else "I", " IDR" if h.idr else ""), file=sys.stderr)

    def decode_poc(self, h, pic):
        """8.2.1: TopFieldOrderCnt / BottomFieldOrderCnt of the current picture."""
        sps = h.sps
        top = bot = None
        if sps.poc_type == 0:
            if h.idr:
                prev_msb, prev_lsb = 0, 0
            elif self.prev_ref_has_mmco5:
                prev_msb, prev_lsb = 0, (0 if self.prev_ref_is_bottom else self.prev_ref_top_poc)
            else:
                prev_msb, prev_lsb = self.prev_poc_msb, self.prev_poc_lsb
            max_lsb = 1 << sps.log2_max_poc_lsb
            if h.poc_lsb < prev_lsb and prev_lsb - h.poc_lsb >= max_lsb // 2:
                msb = prev_msb + max_lsb
            elif h.poc_lsb > prev_lsb and h.poc_lsb - prev_lsb > max_lsb // 2:
                msb = prev_msb - max_lsb
            else:
                msb = prev_msb
            if not h.bottom_field:
                top = msb + h.poc_lsb
            if not h.field_pic:
                bot = top + h.delta_poc_bottom
            elif h.bottom_field:
                bot = msb + h.poc_lsb
            pic.poc_msb = msb
        else:
            max_fn = 1 << sps.log2_max_frame_num
            if h.idr:
                fno = 0
            else:
                prev_off = 0 if self.prev_has_mmco5 else self.prev_frame_num_offset
                fno = prev_off + max_fn if self.prev_frame_num > h.frame_num else prev_off
            pic.frame_num_offset = fno
            if sps.poc_type == 1:
                n = len(sps.offset_for_ref_frame)
                abs_fn = fno + h.frame_num if n else 0
                if h.nal_ref_idc == 0 and abs_fn > 0:
                    abs_fn -= 1
                expected = 0
                if abs_fn > 0:
                    cyc = (abs_fn - 1) // n
                    in_cyc = (abs_fn - 1) % n
                    expected = cyc * sum(sps.offset_for_ref_frame)
                    for i in range(in_cyc + 1):
                        expected += sps.offset_for_ref_frame[i]
                if h.nal_ref_idc == 0:
                    expected += sps.offset_for_non_ref_pic
                if not h.field_pic:
                    top = expected + h.delta_poc[0]
                    bot = top + sps.offset_for_top_to_bottom_field + h.delta_poc[1]
                elif not h.bottom_field:
                    top = expected + h.delta_poc[0]
                else:
                    bot = expected + sps.offset_for_top_to_bottom_field + h.delta_poc[0]
            else:
                if h.idr:
                    t = 0
                elif h.nal_ref_idc == 0:
                    t = 2 * (fno + h.frame_num) - 1
                else:
                    t = 2 * (fno + h.frame_num)
                if not h.field_pic:
                    top = bot = t
                elif h.bottom_field:
                    bot = t
                else:
                    top = t
        f = pic.frame
        if top is not None:
            f.poc[TOP] = top
        if bot is not None:
            f.poc[BOT] = bot
        pic.poc = top if pic.struct == "T" else bot if pic.struct == "B" else min(top, bot)

    def finish_picture(self):
        pic = self.pic
        if pic is None:
            return
        self.pic = None
        h = pic.slices[0]
        sps = h.sps
        # 8.7: the deblocking filter over the whole picture, in macroblock order
        pre = None
        if self.on_picture is not None:
            pre = (pic.Y.copy(), pic.Cb.copy(), pic.Cr.copy())
        deblock_picture(pic, self.count)
        f = pic.frame
        if pic.struct == "F":
            f.decoded = [1, 1]
        else:
            f.decoded[0 if pic.struct == "T" else 1] = 1
        # 8.2.5: reference marking
        if pic.is_ref:
            self.mark(pic, h)
        # C.4.4 / C.4.5: the output process -- BEFORE an MMCO 5's POC rewrite below
        self.output_step(pic, h)
        # POC state for the next picture
        if pic.is_ref:
            self.prev_ref_has_mmco5 = pic.mmco5
            self.prev_ref_is_bottom = pic.struct == "B"
            if sps.poc_type == 0:
                self.prev_poc_msb = pic.poc_msb
                self.prev_poc_lsb = h.poc_lsb
                if pic.mmco5:
                    self.prev_ref_top_poc = f.poc[TOP] if f.poc[TOP] is not None else 0
        self.prev_has_mmco5 = pic.mmco5
        self.prev_frame_num_offset = getattr(pic, "frame_num_offset", 0)
        self.prev_frame_num = h.frame_num
        if pic.mmco5:
            # 8.2.1: the picture's POC becomes relative to itself; frame_num is 0 afterwards
            temp = pic.poc
            if f.poc[TOP] is not None:
                f.poc[TOP] -= temp
            if f.poc[BOT] is not None:
                f.poc[BOT] -= temp
            self.prev_frame_num = 0
            self.prev_frame_num_offset = 0
            self.prev_poc_msb = 0
            self.prev_poc_lsb = f.poc[TOP] if (pic.struct != "B" and f.poc[TOP] is not None) else 0
            self.prev_ref_top_poc = self.prev_poc_lsb
            self.seq += 1
            f.seq = self.seq
        if pic.is_ref:
            self.prev_ref_frame_num = 0 if pic.mmco5 else h.frame_num
        self.prev_pic = pic
        self.pic_events.append({
            "frame": f.id, "struct": pic.struct, "is_ref": pic.is_ref, "idr": h.idr,
            "no_output": h.no_output_of_prior_pics, "mmco5": pic.mmco5, "size": dpb_size(sps),
            "poc": [f.poc[0], f.poc[1]],                      # after an MMCO 5's rewrite
            "refs": {fr.id: [fr.ref[0] != UNUSED, fr.ref[1] != UNUSED] for fr in self.dpb + [f]}})
        if self.on_picture is not None:
            self.on_picture(pic, pre)
        # drop frames nobody references (they stay in `out` for the display order)
        self.dpb = [fr for fr in self.dpb if fr.any_ref()]

    # ---- the output process (C.4.4 / C.4.5, P5d) ---------------------------------------
    # The spec outputs PICTURES (a field pair's fields may leave apart when another
    # picture's POC falls between theirs); the display shows STORES, so a store is
    # emitted when the bumping first selects it, whole, once per allocation, and never
    # before its pair is complete (a directly output first field waits for its partner:
    # pend_emit). tools/dpb_output_ref.py is the per-picture spec process; it and this
    # agree on the ORDER of every fixture (their "pair split" count is 0).

    def store_poc(self, fr):
        return min(fr.poc[i] for i in (0, 1) if fr.decoded[i] and fr.poc[i] is not None)

    def complete(self, fr):
        return fr.coded_as_frame or (fr.decoded[0] and fr.decoded[1])

    def emit(self, fr, how):
        self.last_out_poc = self.store_poc(fr)
        fr.waiting = False
        if fr in self.waitq:
            self.waitq.remove(fr)
        fr.emitted = True
        if not self.complete(fr) and how == "direct":
            fr.pend_emit = True                  # its second field is next: emitted with it
            self.out_cnt["deferred"] += 1
            return
        fr.pend_emit = False
        self.emitted.append((fr, self.n_pictures, how))

    def bump(self, how="bump"):
        """C.4.5.3: the store with the smallest PicOrderCnt among those needed for output."""
        if not self.waitq:
            return False
        fr = min(self.waitq, key=self.store_poc)
        self.emit(fr, how)
        return True

    def fullness(self, cur):
        """Non-empty frame buffers: a reference or a store needed for output (the current
        picture's store is not in the DPB until it is stored)."""
        return len(set(id(x) for x in self.dpb if x is not cur and x.any_ref()) |
                   set(id(x) for x in self.waitq if x is not cur))

    def output_step(self, pic, h):
        f = pic.frame
        size = dpb_size(h.sps)
        if h.idr or pic.mmco5:
            self.last_out_poc = None             # POCs restart: nothing to compare with
        # C.4.4: an IDR empties the DPB -- without output (no_output_of_prior_pics_flag, as
        # CODED: its inference on a size change is not made, docs/spec_hardening.md) or by
        # bumping everything; an MMCO 5 bumps everything (the current store excluded)
        if h.idr and h.no_output_of_prior_pics:
            for fr in list(self.waitq):
                if fr is not f:
                    fr.waiting = False
                    self.waitq.remove(fr)
                    self.out_cnt["dropped"] += 1
        elif h.idr or pic.mmco5:
            while any(x is not f for x in self.waitq):
                fr = min((x for x in self.waitq if x is not f), key=self.store_poc)
                self.emit(fr, "flush")
        # C.4.5: store the current picture
        if f.emitted:
            pass                                  # emitted once in this allocation (a pair's second field)
        elif f.waiting:
            pass                                  # a second field whose first field is in the DPB: same buffer
        elif pic.is_ref:
            while self.fullness(f) >= size:
                if not self.bump():
                    self.out_cnt["over"] += 1     # full of references alone: a non-conforming stream
                    break
            f.waiting = True
            self.waitq.append(f)
        else:
            cur = pic.poc
            while True:
                if self.fullness(f) >= size:
                    if any(self.store_poc(x) <= cur for x in self.waitq if x is not f):
                        if not self.bump():
                            self.out_cnt["over"] += 1
                            break
                        continue
                    self.out_cnt["direct"] += 1
                    self.emit(f, "direct")        # output without storing
                else:
                    f.waiting = True
                    self.waitq.append(f)
                break
        # EARLY OUTPUT (E.2.1, roadmap P3d): no picture follows more than max_num_reorder_frames
        # others in output order, so while more than that many COMPLETE stores wait (the
        # current one once complete), the smallest POC leaves now. Changes when, not the order.
        nrf = num_reorder(h.sps)
        if nrf is not None:
            while True:
                cands = [x for x in self.waitq if x is not f or self.complete(f)]
                if len(cands) <= nrf:
                    break
                fr = min(cands, key=self.store_poc)
                if self.last_out_poc is not None and self.store_poc(fr) < self.last_out_poc:
                    self.out_cnt["nrf_late"] += 1     # the stream broke its own limit
                self.emit(fr, "reorder")
        if f.pend_emit and self.complete(f):
            f.pend_emit = False
            self.emitted.append((f, self.n_pictures, "direct"))

    def flush_output(self):
        """End of stream: everything still needed for output, in order; a pending store."""
        self.finish_picture()
        for fr in [x for x in self.out if x.pend_emit]:
            fr.pend_emit = False
            self.emitted.append((fr, self.n_pictures, "unpaired"))
        while self.bump("eos"):
            pass

    # ---- reference marking (8.2.5) ---------------------------------------------------

    def mark(self, pic, h):
        f = pic.frame
        sps = h.sps
        fields = [0, 1] if pic.struct == "F" else [0 if pic.struct == "T" else 1]
        if h.idr:
            for fr in self.dpb:
                fr.ref = [UNUSED, UNUSED]
            self.dpb = []
            if h.long_term_reference:
                for p in fields:
                    f.ref[p] = LONG
                f.long_idx = 0
                self.max_long_term_frame_idx = 0
            else:
                for p in fields:
                    f.ref[p] = SHORT
                self.max_long_term_frame_idx = None
        else:
            self.assign_pic_nums(h)
            marked_long = False
            if h.mmco is None:
                self.sliding_window(pic, h)
            else:
                marked_long = self.adaptive_marking(pic, h)
            if not marked_long:
                for p in fields:
                    f.ref[p] = SHORT
        if f not in self.dpb:
            self.dpb.append(f)

    def assign_pic_nums(self, h):
        """8.2.4.1: FrameNumWrap for every short-term reference frame."""
        max_fn = 1 << h.sps.log2_max_frame_num
        for fr in self.dpb:
            if fr.ref[0] == SHORT or fr.ref[1] == SHORT:
                fr.frame_num_wrap = fr.frame_num - max_fn if fr.frame_num > h.frame_num else fr.frame_num

    def sliding_window(self, pic, h):
        f = pic.frame
        if pic.field and f.first_parity != pic.struct and f.ref[0 if pic.struct == "B" else 1] == SHORT:
            return                                 # the second field of a short-term pair
        num_short = sum(1 for fr in self.dpb if fr is not f and (fr.ref[0] == SHORT or fr.ref[1] == SHORT))
        num_long = sum(1 for fr in self.dpb if fr is not f and (fr.ref[0] == LONG or fr.ref[1] == LONG)
                       and not (fr.ref[0] == SHORT or fr.ref[1] == SHORT))
        if num_short + num_long == max(h.sps.num_ref_frames, 1):
            if num_short == 0:
                raise ReconError("sliding window with no short-term reference to drop")
            victim = min((fr for fr in self.dpb if fr is not f and (fr.ref[0] == SHORT or fr.ref[1] == SHORT)),
                         key=lambda fr: fr.frame_num_wrap)
            victim.ref = [UNUSED, UNUSED]

    def pic_num(self, fr, parity, pic):
        """PicNum of a short-term reference frame / field (8.2.4.1)."""
        if not pic.field:
            return fr.frame_num_wrap
        same = (parity == 0) == (pic.struct == "T")
        return 2 * fr.frame_num_wrap + (1 if same else 0)

    def count(self, key, n=1):
        self.cov[key] = self.cov.get(key, 0) + n

    def long_term_pic_num(self, fr, parity, pic):
        if not pic.field:
            return fr.long_idx
        same = (parity == 0) == (pic.struct == "T")
        return 2 * fr.long_idx + (1 if same else 0)

    def find_short(self, pic_num, pic):
        for fr in self.dpb:
            if not pic.field:
                if fr.both(SHORT) and fr.frame_num_wrap == pic_num:
                    return fr, None
            else:
                for p in (0, 1):
                    if fr.ref[p] == SHORT and self.pic_num(fr, p, pic) == pic_num:
                        return fr, p
        raise ReconError("no short-term reference with PicNum %d" % pic_num)

    def find_long(self, ltpn, pic):
        for fr in self.dpb:
            if not pic.field:
                if fr.both(LONG) and fr.long_idx == ltpn:
                    return fr, None
            else:
                for p in (0, 1):
                    if fr.ref[p] == LONG and self.long_term_pic_num(fr, p, pic) == ltpn:
                        return fr, p
        raise ReconError("no long-term reference with LongTermPicNum %d" % ltpn)

    def adaptive_marking(self, pic, h):
        """8.2.5.4; returns True when the current picture was marked long-term (op 6)."""
        f = pic.frame
        cur_pic_num = 2 * h.frame_num + 1 if pic.field else h.frame_num
        marked_long = False
        self.count("mmco_field" if pic.field else "mmco_frame", len(h.mmco))
        for op, a in h.mmco:
            self.count("mmco_op%d" % op)
            if op == 1:
                fr, p = self.find_short(cur_pic_num - (a["diff"] + 1), pic)
                if p is None:
                    fr.ref = [UNUSED, UNUSED]
                else:
                    fr.ref[p] = UNUSED
            elif op == 2:
                fr, p = self.find_long(a["ltpn"], pic)
                if p is None:
                    fr.ref = [UNUSED, UNUSED]
                else:
                    fr.ref[p] = UNUSED
            elif op == 3:
                fr, p = self.find_short(cur_pic_num - (a["diff"] + 1), pic)
                self.free_long_idx(a["ltfi"], keep=fr)
                fr.long_idx = a["ltfi"]
                if p is None:
                    fr.ref = [LONG, LONG]
                else:
                    fr.ref[p] = LONG
            elif op == 4:
                self.max_long_term_frame_idx = a["max1"] - 1 if a["max1"] > 0 else None
                for fr in self.dpb:
                    if fr.long_idx is not None and (fr.ref[0] == LONG or fr.ref[1] == LONG):
                        if a["max1"] == 0 or fr.long_idx > a["max1"] - 1:
                            for p in (0, 1):
                                if fr.ref[p] == LONG:
                                    fr.ref[p] = UNUSED
            elif op == 5:
                for fr in self.dpb:
                    if fr is not f:
                        fr.ref = [UNUSED, UNUSED]
                self.max_long_term_frame_idx = None
            elif op == 6:
                self.free_long_idx(a["ltfi"], keep=f)
                f.long_idx = a["ltfi"]
                if pic.struct == "F":
                    f.ref = [LONG, LONG]
                else:
                    f.ref[0 if pic.struct == "T" else 1] = LONG
                marked_long = True
            else:
                raise ReconError("memory_management_control_operation %d" % op)
        return marked_long

    def free_long_idx(self, idx, keep):
        for fr in self.dpb:
            if fr is keep or fr.long_idx != idx:
                continue
            for p in (0, 1):
                if fr.ref[p] == LONG:
                    fr.ref[p] = UNUSED

    # ---- reference lists (8.2.4) ------------------------------------------------------

    def build_ref_lists(self, h):
        pic = self.pic
        self.ref_lists = [[], []]
        if h.slice_type == I:
            return
        self.assign_pic_nums(h)
        cur_frame = pic.frame
        if not pic.field:
            short = [fr for fr in self.dpb if fr.both(SHORT) and fr is not cur_frame]
            longt = [fr for fr in self.dpb if fr.both(LONG) and fr is not cur_frame]
            if h.slice_type == P:
                l0 = sorted(short, key=lambda fr: -fr.frame_num_wrap) + sorted(longt, key=lambda fr: fr.long_idx)
                lists = [[RefPic(fr, "F") for fr in l0], []]
            else:
                cur = pic.poc
                before = sorted([fr for fr in short if fr.frame_poc() <= cur], key=lambda fr: -fr.frame_poc())
                after = sorted([fr for fr in short if fr.frame_poc() > cur], key=lambda fr: fr.frame_poc())
                lt = sorted(longt, key=lambda fr: fr.long_idx)
                l0 = before + after + lt
                l1 = after + before + lt
                lists = [[RefPic(fr, "F") for fr in l0], [RefPic(fr, "F") for fr in l1]]
                if len(lists[1]) > 1 and [r.ident() for r in lists[0]] == [r.ident() for r in lists[1]]:
                    lists[1][0], lists[1][1] = lists[1][1], lists[1][0]
                    self.count("b_swap")
        else:
            # 8.2.4.2.2 / 8.2.4.2.4 / 8.2.4.2.5: frame lists, then fields by alternating parity
            short = [fr for fr in self.dpb if fr.ref[0] == SHORT or fr.ref[1] == SHORT]
            longt = [fr for fr in self.dpb if fr.ref[0] == LONG or fr.ref[1] == LONG]
            if cur_frame.ref[0] == SHORT or cur_frame.ref[1] == SHORT:
                if cur_frame not in short:
                    short.append(cur_frame)
            if cur_frame.ref[0] == LONG or cur_frame.ref[1] == LONG:
                if cur_frame not in longt:
                    longt.append(cur_frame)
            lt_frames = sorted(longt, key=lambda fr: fr.long_idx)
            if h.slice_type == P:
                st_frames = sorted(short, key=lambda fr: -fr.frame_num_wrap)
                lists = [self.field_list(st_frames, SHORT, pic) + self.field_list(lt_frames, LONG, pic), []]
            else:
                cur = pic.poc
                before = sorted([fr for fr in short if fr.entry_poc(SHORT) <= cur], key=lambda fr: -fr.entry_poc(SHORT))
                after = sorted([fr for fr in short if fr.entry_poc(SHORT) > cur], key=lambda fr: fr.entry_poc(SHORT))
                l0 = self.field_list(before + after, SHORT, pic) + self.field_list(lt_frames, LONG, pic)
                l1 = self.field_list(after + before, SHORT, pic) + self.field_list(lt_frames, LONG, pic)
                lists = [l0, l1]
                if len(lists[1]) > 1 and [r.ident() for r in lists[0]] == [r.ident() for r in lists[1]]:
                    lists[1][0], lists[1][1] = lists[1][1], lists[1][0]
                    self.count("b_swap")
        # 8.2.4.2: the list is num_ref_idx_active long; missing entries are "no reference picture"
        for lx in range(2 if h.slice_type == B else 1):
            lst = lists[lx][:h.num_ref_idx[lx]]
            while len(lst) < h.num_ref_idx[lx]:
                lst.append(None)
            lists[lx] = lst
        # 8.2.4.3: modification
        max_fn = 1 << h.sps.log2_max_frame_num
        max_pic_num = 2 * max_fn if pic.field else max_fn
        cur_pic_num = 2 * h.frame_num + 1 if pic.field else h.frame_num
        self.mod_diff = [set(), set()]
        for lx in range(2 if h.slice_type == B else 1):
            if not h.mods[lx]:
                continue
            n = h.num_ref_idx[lx]

            def modify(lst, remove, lx=lx, n=n):
                lst = lst + [None]
                ref_idx = 0
                pred = cur_pic_num
                for idc, val in h.mods[lx]:
                    if remove:
                        self.count("mod")
                    if idc in (0, 1):
                        if idc == 0:
                            nowrap = pred - (val + 1)
                            if nowrap < 0:
                                nowrap += max_pic_num
                        else:
                            nowrap = pred + (val + 1)
                            if nowrap >= max_pic_num:
                                nowrap -= max_pic_num
                        pred = nowrap
                        pn = nowrap - max_pic_num if nowrap > cur_pic_num else nowrap
                        fr, p = self.find_short(pn, pic)
                        entry = RefPic(fr, "F" if p is None else ("T" if p == 0 else "B"))

                        def keyf(e, pn=pn):
                            if e is None or e.marking() != SHORT:
                                return max_pic_num
                            return self.pic_num(e.frame, None if e.struct == "F" else (0 if e.struct == "T" else 1), pic)
                        target = pn
                    else:
                        fr, p = self.find_long(val, pic)
                        entry = RefPic(fr, "F" if p is None else ("T" if p == 0 else "B"))

                        def keyf(e, val=val):
                            if e is None or e.marking() != LONG:
                                return 2 * ((self.max_long_term_frame_idx or 0) + 1) + 1000000
                            return self.long_term_pic_num(e.frame, None if e.struct == "F" else (0 if e.struct == "T" else 1), pic)
                        target = val
                    for c in range(n, ref_idx, -1):
                        lst[c] = lst[c - 1]
                    lst[ref_idx] = entry
                    ref_idx += 1
                    nidx = ref_idx
                    for c in range(ref_idx, n + 1):
                        if not remove or keyf(lst[c]) != target:
                            lst[nidx] = lst[c]
                            nidx += 1
                        elif lst[c] is not None:
                            self.count("mod_dup_removed")
                return lst[:n]
            kept = modify(lists[lx], True)
            # coverage only: the same operations with the later duplicates kept -- the indices
            # where the two differ are where the removal is observable (mod_dup_used)
            shadow = modify(lists[lx], False)
            self.mod_diff[lx] = {i for i in range(n) if (kept[i] and kept[i].ident()) != (shadow[i] and shadow[i].ident())}
            lists[lx] = kept
        self.ref_lists = lists
        if self.verbose and h.first_mb == 0:
            for lx in range(2 if h.slice_type == B else 1):
                print("  list%d: %s" % (lx, " ".join("-" if r is None else "%d%s/%s" % (r.frame.id, r.struct, r.poc())
                                                     for r in lists[lx])), file=sys.stderr)

    def field_list(self, frames, kind, pic):
        """8.2.4.2.5: fields of the ordered frames, alternating parity from the current one."""
        same = 0 if pic.struct == "T" else 1
        q = [[fr for fr in frames if fr.ref[same] == kind and fr.decoded[same]],
             [fr for fr in frames if fr.ref[1 - same] == kind and fr.decoded[1 - same]]]
        out = []
        turn = 0
        while q[0] or q[1]:
            if q[turn]:
                fr = q[turn].pop(0)
                par = same if turn == 0 else 1 - same
                out.append(RefPic(fr, "T" if par == 0 else "B"))
            turn = 1 - turn
        return out

    # ---- output ---------------------------------------------------------------------

    def output_frames(self):
        """Display order: per sequence, by PicOrderCnt (fields as their frame)."""
        return sorted(self.out, key=lambda fr: (fr.seq, fr.frame_poc()))


# ---------------------------------------------------------------- the slice: macroblocks

class Mb(object):
    """The syntax elements of one macroblock, as the SE stream delivers them."""

    def __init__(self, addr):
        self.addr = addr
        self.skip = 0
        self.mb_type = None
        self.sub_types = []
        self.prev_flags = []
        self.rem_modes = []
        self.chroma_mode = 0
        self.ref_idx = [[], []]
        self.mvd = [[], []]
        self.cbp = 0
        self.qp_delta = 0
        self.blocks = []                          # (kind, idx, levels)
        self.pcm = None
        self.t8 = 0


def expand_mb(m, slice_type, num_ref_idx):
    """The macroblock's stream-order ref_idx_lX / mvd_lX lists expanded the way the
    fabric's intake stores them: refs[lx][part] for the 4 partition / sub-macroblock
    slots (absent -> 0), mvd[lx][blk] per 4x4 block, pred[lx][blk] (direct blocks 0),
    direct[b8] for B_8x8 direct sub-macroblocks; (None, ...) for intra and skip."""
    refs = [[0] * 4, [0] * 4]
    mvd = [[(0, 0)] * 16, [(0, 0)] * 16]
    pred = [[0] * 16, [0] * 16]
    direct = [0] * 4
    if m.skip:
        return refs, mvd, pred, [1, 1, 1, 1] if slice_type == B else direct
    base = {I: 0, P: 5, B: 23}[slice_type]
    if m.mb_type - base >= 0:
        return None
    if slice_type == B and m.mb_type == B_DIRECT_16X16:
        return refs, mvd, pred, [1, 1, 1, 1]
    if (slice_type == P and m.mb_type == P_8X8) or (slice_type == B and m.mb_type == B_8X8):
        tab = P_SUB if slice_type == P else B_SUB
        subs = [tab[t] for t in m.sub_types]
        for lx in range(2):
            ri = 0
            for b8, (p, _shape) in enumerate(subs):
                if p == DIRECT:
                    direct[b8] = 1
                    continue
                if p & (1 << lx):
                    if num_ref_idx[lx] > 1:
                        refs[lx][b8] = m.ref_idx[lx][ri]
                        ri += 1
                    for b in range(4):
                        pred[lx][4 * b8 + b] = 1
        for lx in range(2):
            k = 0
            for b8, (p, shape) in enumerate(subs):
                if p != DIRECT and p & (1 << lx):
                    bx, by = (b8 & 1) * 8, (b8 >> 1) * 8
                    for (sx, sy, w, h) in SUB_RECT[shape]:
                        d = (m.mvd[lx][k], m.mvd[lx][k + 1])
                        k += 2
                        for b in rect_blks(bx + sx, by + sy, w, h):
                            mvd[lx][b] = d
        return refs, mvd, pred, direct
    if slice_type == P:
        shape = ("16x16", "16x8", "8x16")[m.mb_type]
        preds = [L0] * len(PART_RECT[shape])
    elif m.mb_type <= 3:
        shape, preds = "16x16", [m.mb_type]
    else:
        k = m.mb_type - 4
        shape = "16x8" if k % 2 == 0 else "8x16"
        preds = list(B_PAIR_PRED[k // 2])
    rects = PART_RECT[shape]
    for lx in range(2):
        ri = 0
        for pi in range(len(rects)):
            if preds[pi] & (1 << lx):
                if num_ref_idx[lx] > 1:
                    refs[lx][pi] = m.ref_idx[lx][ri]
                    ri += 1
                for b in rect_blks(*rects[pi]):
                    pred[lx][b] = 1
    for lx in range(2):
        k = 0
        for pi, (x, y, w, h) in enumerate(rects):
            if preds[pi] & (1 << lx):
                d = (m.mvd[lx][k], m.mvd[lx][k + 1])
                k += 2
                for b in rect_blks(x, y, w, h):
                    mvd[lx][b] = d
    return refs, mvd, pred, direct


class SliceDecoder(object):
    def __init__(self, dec, pic, h, slice_id):
        self.dec = dec
        self.pic = pic
        self.h = h
        self.sps, self.pps = h.sps, h.pps
        self.slice_id = slice_id
        self.qp = h.qp                            # QPY,PRED
        self.cur = None
        self.lists = dec.ref_lists
        self.mod_diff = dec.mod_diff              # (coverage) indices the duplicate removal changed
        self.field = pic.field
        self.scan = FIELD_SCAN if pic.field else ZIGZAG
        self.scan8 = HT.FIELD_SCAN8 if pic.field else HT.ZIGZAG8
        self.w = pic.w
        self.mb_count = 0
        # the slice's scaling lists (7.4.2.1.1 / 7.4.2.2 fall-back rules): LevelScale per
        # list, [0..2] intra Y/Cb/Cr, [3..5] inter; 8x8 [0] intra Y, [1] inter Y
        import h264_fe_ref as FE
        sl, src = FE.resolve_scaling(self.sps, self.pps)
        if h.scaling_words is not None and h.scaling_words != FE.scaling_words(self.sps, self.pps):
            raise ReconError("the stream's resolved scaling matrix differs from the raw lists' resolution")
        self.ls4 = [level_scale4_table(sl[i]) for i in range(6)]
        self.ls8 = [level_scale8_table(sl[6 + i]) for i in range(2)]
        dec.count("scaling_nonflat", int(any(v != 16 for lst in sl for v in lst)))
        dec.count("scaling_fallback", sum(1 for x in src if x.startswith("fallback")))

    # ---- record intake

    def mb_start(self, addr):
        self.cur = Mb(addr)

    def se(self, name, v):
        m = self.cur
        if name == "mb_skip_flag":
            m.skip = v
        elif name == "mb_type":
            m.mb_type = v
        elif name == "sub_mb_type":
            m.sub_types.append(v)
        elif name in ("prev_intra4x4_pred_mode_flag", "prev_intra8x8_pred_mode_flag"):
            m.prev_flags.append(v)
            if v:
                m.rem_modes.append(None)
        elif name in ("rem_intra4x4_pred_mode", "rem_intra8x8_pred_mode"):
            m.rem_modes.append(v)
        elif name == "transform_size_8x8_flag":
            m.t8 = v
        elif name == "intra_chroma_pred_mode":
            m.chroma_mode = v
        elif name == "ref_idx_l0":
            m.ref_idx[0].append(v)
        elif name == "ref_idx_l1":
            m.ref_idx[1].append(v)
        elif name == "mvd_l0":
            m.mvd[0].append(v)
        elif name == "mvd_l1":
            m.mvd[1].append(v)
        elif name == "coded_block_pattern":
            m.cbp = v
        elif name == "mb_qp_delta":
            m.qp_delta = v
        elif name == "end_of_slice_flag":
            self.decode_mb(m)
            self.cur = None
        else:
            raise ReconError("unknown syntax element %s" % name)

    def block(self, kind, idx, levels):
        if kind == "PCM":
            self.cur.pcm = levels
        else:
            self.cur.blocks.append((kind, idx, levels))

    def end(self):
        pass

    # ---- neighbours (6.4.9, 6.4.11: same slice, already decoded)

    def mb_at(self, addr):
        if addr < 0 or addr >= self.pic.n_mbs:
            return None
        m = self.pic.mbs[addr]
        return m if m.avail and m.slice == self.slice_id else None

    def nb_mb(self, addr, xN, yN):
        """6.4.12 (non-MBAFF): the macroblock holding luma location (xN, yN) relative to
        mbAddr, and the location inside it; None when outside/unavailable."""
        w = self.w
        x_mb, y_mb = addr % w, addr // w
        if yN < 0:
            if xN < 0:
                a = addr - w - 1 if x_mb > 0 else -1
            elif xN <= 15:
                a = addr - w
            else:
                a = addr - w + 1 if x_mb < w - 1 else -1
            if a < 0 or y_mb == 0:
                return None, 0, 0
            return self.mb_at(a), xN & 15, yN & 15
        if yN <= 15:
            if xN < 0:
                if x_mb == 0:
                    return None, 0, 0
                return self.mb_at(addr - 1), xN & 15, yN
            if xN <= 15:
                return self.pic.mbs[addr], xN, yN
        return None, 0, 0

    # ---- the macroblock

    def decode_mb(self, m):
        pic = self.pic
        info = pic.mbs[m.addr]
        info.avail = 1
        info.slice = self.slice_id
        info.skip = m.skip
        info.disable_deblock = self.h.disable_deblocking
        info.alpha_off = self.h.alpha_off
        info.beta_off = self.h.beta_off
        st = self.h.slice_type
        mbx, mby = (m.addr % self.w) * 16, (m.addr // self.w) * 16
        self.mbx, self.mby, self.addr = mbx, mby, m.addr
        self.info = info
        # QPY (7.4.5): the delta is 0 when absent (skip, cbp 0 without Intra16x16)
        self.qp = (self.qp + m.qp_delta + 52) % 52
        info.qp = self.qp
        info.pcm_qpc = (QPC_TABLE[clip3(0, 51, self.pps.chroma_qp_index_offset)],
                        QPC_TABLE[clip3(0, 51, self.pps.second_chroma_qp_index_offset)])
        info.qpc = (QPC_TABLE[clip3(0, 51, self.qp + self.pps.chroma_qp_index_offset)],
                    QPC_TABLE[clip3(0, 51, self.qp + self.pps.second_chroma_qp_index_offset)])
        if m.skip:
            info.mb_type = "SKIP"
            if st == P:
                self.p_skip(info)
            else:
                self.b_direct(info, [0, 1, 2, 3])
            self.inter_predict(info)
            self.finish_inter(info, m)
            return
        base = {I: 0, P: 5, B: 23}[st]
        it = m.mb_type - base
        if it >= 0:
            info.intra = 1
            info.mb_type = "I"
            for lx in range(2):
                info.refpic[lx] = [None] * 16
                info.pred[lx] = [0] * 16
                info.ref[lx] = [-1] * 16
            if it == I_PCM_IDX:
                info.pcm = 1
                s = np.array(m.pcm, dtype=np.int32)
                pic.Y[mby:mby + 16, mbx:mbx + 16] = s[:256].reshape(16, 16)
                pic.Cb[mby // 2:mby // 2 + 8, mbx // 2:mbx // 2 + 8] = s[256:320].reshape(8, 8)
                pic.Cr[mby // 2:mby // 2 + 8, mbx // 2:mbx // 2 + 8] = s[320:384].reshape(8, 8)
                info.nz = [1] * 16
                return
            if it == I_NXN:
                info.i4 = 1
                if m.t8:
                    info.t8 = 1
                    self.intra8x8(m, info)
                else:
                    self.intra4x4(m, info)
            else:
                t = it - 1
                pred_mode = t % 4
                m.cbp = (15 if t >= 12 else 0) | (((t % 12) // 4) << 4)
                self.intra16x16(m, info, pred_mode)
            self.intra_chroma(m, info)
            self.residual_chroma(m, info)
            return
        # inter
        info.mb_type = "INTER"
        info.t8 = m.t8
        if st == B and m.mb_type == B_DIRECT_16X16:
            self.b_direct(info, [0, 1, 2, 3])
        elif (st == P and m.mb_type == P_8X8) or (st == B and m.mb_type == B_8X8):
            self.sub_mb_pred(m, info, st)
        else:
            self.mb_pred(m, info, st)
        self.inter_predict(info)
        self.finish_inter(info, m)

    def finish_inter(self, info, m):
        if not m.skip:
            self.residual_luma(m, info, i16=False)
            self.residual_chroma(m, info)

    # ---- intra

    def intra_avail(self, nb):
        """6.4.11 availability plus constrained_intra_pred (8.3.1.2 conditions)."""
        if nb is None:
            return False
        if self.pps.constrained_intra_pred and not nb.intra:
            return False
        return True

    def luma_sample(self, x, y):
        """A constructed (pre-deblock) luma sample at MB-relative (x, y) of an available MB, or None."""
        nb, xw, yw = self.nb_mb(self.addr, x, y)
        if nb is None or not self.intra_avail(nb):
            return None
        mbx, mby = (self.addr % self.w) * 16, (self.addr // self.w) * 16
        # locate the neighbour MB origin from the location
        if y < 0:
            oy = mby - 16
        elif y > 15:
            oy = mby + 16
        else:
            oy = mby
        if x < 0:
            ox = mbx - 16
        elif x > 15:
            ox = mbx + 16
        else:
            ox = mbx
        return int(self.pic.Y[oy + yw, ox + xw])

    def intra4x4(self, m, info):
        pic = self.pic
        mbx, mby = self.mbx, self.mby
        modes = info.modes
        blocks = {idx: lv for kind, idx, lv in m.blocks if kind == "L4"}
        for idx in range(16):
            x0, y0 = BLK_XY[idx]
            # 8.3.1.1: the predicted mode from A (left) and B (above)
            nba, _xa, ya = self.nb_mb(self.addr, x0 - 1, y0)
            nbb, xb, _yb = self.nb_mb(self.addr, x0, y0 - 1)
            dc_pred = (nba is None or nbb is None
                       or (self.pps.constrained_intra_pred and (not nba.intra or not nbb.intra)))
            if dc_pred:
                ma = mb_ = 2
            else:
                ma = nba.modes[xy_blk(x0 - 1 if x0 > 0 else 15, y0)] if nba.i4 else 2
                mb_ = nbb.modes[xy_blk(x0, y0 - 1 if y0 > 0 else 15)] if nbb.i4 else 2
                if nba is info and nba.i4:
                    ma = modes[xy_blk(x0 - 1, y0)]
                if nbb is info and nbb.i4:
                    mb_ = modes[xy_blk(x0, y0 - 1)]
            pred_mode = min(ma, mb_)
            if m.prev_flags[idx]:
                mode = pred_mode
            else:
                rem = m.rem_modes[idx]
                mode = rem if rem < pred_mode else rem + 1
            modes[idx] = mode
            # 8.3.1.2: the 13 neighbouring samples
            top = [self.luma_sample(x0 + k, y0 - 1) for k in range(8)]
            if idx in (3, 11) or top[4] is None:
                top[4:] = [None] * 4
            # blocks whose above-right is inside the MB but not yet decoded: 6.4.11.4 says
            # the neighbouring 4x4 block must be available (decoded); blocks 1, 4, 5 (above-
            # right inside the MB and later in order) -- handled by the "not yet decoded" rule
            if x0 + 4 <= 12 and y0 > 0:
                nb_idx = xy_blk(x0 + 4, y0 - 1)
                if nb_idx > idx:
                    top[4:] = [None] * 4
            if top[4] is None and top[3] is not None:
                top[4:] = [top[3]] * 4
            left = [self.luma_sample(x0 - 1, y0 + k) for k in range(4)]
            tl = self.luma_sample(x0 - 1, y0 - 1)
            if any(v is None for v in top[:4]):
                top = None
            if any(v is None for v in left):
                left = None
            pred = intra4x4_pred((top, left, tl), mode, idx)
            lv = blocks.get(idx)
            if lv is not None and any(lv):
                info.nz[idx] = 1
                r = itrans4x4(dequant4x4(lv, self.scan, self.qp, ls4=self.ls4[0]))
            else:
                r = [0] * 16
            out = np.clip(np.array(pred, dtype=np.int32) + np.array(r, dtype=np.int32), 0, 255).reshape(4, 4)
            pic.Y[mby + y0:mby + y0 + 4, mbx + x0:mbx + x0 + 4] = out

    def intra8x8(self, m, info):
        """8.3.2: per 8x8 block, the mode (8.3.2.1), the 25 neighbours (8.3.2.2), the
        prediction, then that block's residual (8.5.13) before the next block's samples."""
        pic = self.pic
        mbx, mby = self.mbx, self.mby
        modes = info.modes
        blocks = {idx: lv for kind, idx, lv in m.blocks if kind == "L8"}
        for b8 in range(4):
            x0, y0 = (b8 & 1) * 8, (b8 >> 1) * 8
            nba, xa, ya = self.nb_mb(self.addr, x0 - 1, y0)
            nbb, xb, yb = self.nb_mb(self.addr, x0, y0 - 1)
            dc_pred = (nba is None or nbb is None
                       or (self.pps.constrained_intra_pred and (not nba.intra or not nbb.intra)))
            if dc_pred:
                ma = mb_ = 2
            else:
                # 8.3.2.1 step 3: an Intra_8x8 neighbour's mode, or Intra4x4PredMode
                # [luma8x8BlkIdxN * 4 + n] with n = 1 for A, 2 for B (non-MBAFF); both
                # read from the 4x4 slots (an Intra_8x8 MB fills all four of a block's)
                b8a = 2 * (ya >> 3) + (xa >> 3)
                b8b = 2 * (yb >> 3) + (xb >> 3)
                ma = (modes if nba is info else nba.modes)[4 * b8a + 1] if nba.i4 else 2
                mb_ = (modes if nbb is info else nbb.modes)[4 * b8b + 2] if nbb.i4 else 2
            pred_mode = min(ma, mb_)
            if m.prev_flags[b8]:
                mode = pred_mode
            else:
                rem = m.rem_modes[b8]
                mode = rem if rem < pred_mode else rem + 1
            for k in range(4):
                modes[4 * b8 + k] = mode
            # coverage (tools/recon_top_golden.py prints it; bench/h264/run_recon_top.sh
            # requires each High fixture to reach its paths)
            self.dec.count("i8_block")
            self.dec.count("i8_mode%d" % mode)
            if not dc_pred and (ma != 2 or mb_ != 2):
                self.dec.count("i8_mode_from_nb")         # a neighbour's mode changed the prediction
            # 8.3.2.2: p[x, -1] x = 0..15, p[-1, y] y = 0..7, p[-1, -1]
            top = [self.luma_sample(x0 + k, y0 - 1) for k in range(16)]
            if any(v is None for v in top[8:]) and top[7] is not None:
                top[8:] = [top[7]] * 8
                self.dec.count("i8_subst")
            left = [self.luma_sample(x0 - 1, y0 + k) for k in range(8)]
            tl = self.luma_sample(x0 - 1, y0 - 1)
            if any(v is None for v in top[:8]):
                top = [None] * 16
            if any(v is None for v in left):
                left = [None] * 8
            if tl is None and top[0] is not None and left[0] is not None:
                self.dec.count("i8_no_corner")            # the filter's corner cases (8-80 / 8-84)
            pred = intra8x8_pred(top, left, tl, mode)
            lv = blocks.get(b8)
            if lv is not None and any(lv):
                for k in range(4):
                    info.nz[4 * b8 + k] = 1
                self.dec.count("i8_coded")
                r = itrans8x8(dequant8x8(lv, self.scan8, self.qp, self.ls8[0]))
            else:
                r = [0] * 64
            out = np.clip(np.array(pred, dtype=np.int32) + np.array(r, dtype=np.int32), 0, 255).reshape(8, 8)
            pic.Y[mby + y0:mby + y0 + 8, mbx + x0:mbx + x0 + 8] = out

    def intra16x16(self, m, info, pred_mode):
        pic = self.pic
        mbx, mby = self.mbx, self.mby
        top = [self.luma_sample(k, -1) for k in range(16)]
        left = [self.luma_sample(-1, k) for k in range(16)]
        tl = self.luma_sample(-1, -1)
        if any(v is None for v in top):
            top = None
        if any(v is None for v in left):
            left = None
        pred = intra16x16_pred(pred_mode, top, left, tl)
        pic.Y[mby:mby + 16, mbx:mbx + 16] = pred
        self.residual_luma(m, info, i16=True)

    def chroma_sample(self, plane, x, y):
        nb, xw, yw = self.nb_mb(self.addr, 2 * x if x >= 0 else -1, 2 * y if y >= 0 else -1)
        if nb is None or not self.intra_avail(nb):
            return None
        cx, cy = (self.addr % self.w) * 8, (self.addr // self.w) * 8
        ox = cx - 8 if x < 0 else cx
        oy = cy - 8 if y < 0 else cy
        return int(plane[oy + (y & 7), ox + (x & 7)])

    def intra_chroma(self, m, info):
        pic = self.pic
        cx, cy = self.mbx // 2, self.mby // 2
        for plane in (pic.Cb, pic.Cr):
            top = [self.chroma_sample(plane, k, -1) for k in range(8)]
            left = [self.chroma_sample(plane, -1, k) for k in range(8)]
            tl = self.chroma_sample(plane, -1, -1)
            if any(v is None for v in top):
                top = None
            if any(v is None for v in left):
                left = None
            plane[cy:cy + 8, cx:cx + 8] = intra_chroma_pred(m.chroma_mode, top, left, tl)

    # ---- residual

    def residual_luma(self, m, info, i16):
        pic = self.pic
        mbx, mby = self.mbx, self.mby
        ls4 = self.ls4[0 if info.intra else 3]    # iYCbCr 0 + (mbIsInterFlag ? 3 : 0)
        if m.t8:                                  # inter with the 8x8 transform (8.5.13)
            b8s = {idx: lv for kind, idx, lv in m.blocks if kind == "L8"}
            for b8, lv in b8s.items():
                if not any(lv):
                    continue
                for k in range(4):
                    info.nz[4 * b8 + k] = 1
                self.dec.count("t8_inter_coded")
                r = itrans8x8(dequant8x8(lv, self.scan8, self.qp, self.ls8[1]))
                x0, y0 = (b8 & 1) * 8, (b8 >> 1) * 8
                blk = pic.Y[mby + y0:mby + y0 + 8, mbx + x0:mbx + x0 + 8]
                pic.Y[mby + y0:mby + y0 + 8, mbx + x0:mbx + x0 + 8] = \
                    np.clip(blk + np.array(r, dtype=np.int32).reshape(8, 8), 0, 255)
            return
        dc = None
        if i16:
            ldc = [lv for kind, idx, lv in m.blocks if kind == "LDC"]
            levels = ldc[0] if ldc else [0] * 16
            dc = luma_dc(levels, self.scan, self.qp, ls4)
        blocks = {idx: lv for kind, idx, lv in m.blocks if kind == "L4"}
        for idx in range(16):
            lv = blocks.get(idx)
            x0, y0 = BLK_XY[idx]
            if i16:
                d = dc[4 * (y0 // 4) + (x0 // 4)]
                if (lv is None or not any(lv)) and d == 0:
                    continue
                r = itrans4x4(dequant4x4(lv if lv is not None else [0] * 15, self.scan, self.qp, dc=d, ls4=ls4))
                if lv is not None and any(lv):
                    info.nz[idx] = 1
                if d != 0:
                    info.nz[idx] = 1
            else:
                if lv is None or not any(lv):
                    continue
                info.nz[idx] = 1
                r = itrans4x4(dequant4x4(lv, self.scan, self.qp, ls4=ls4))
            blk = pic.Y[mby + y0:mby + y0 + 4, mbx + x0:mbx + x0 + 4]
            pic.Y[mby + y0:mby + y0 + 4, mbx + x0:mbx + x0 + 4] = np.clip(blk + np.array(r, dtype=np.int32).reshape(4, 4), 0, 255)

    def residual_chroma(self, m, info):
        pic = self.pic
        cx, cy = self.mbx // 2, self.mby // 2
        cdc = {idx: lv for kind, idx, lv in m.blocks if kind == "CDC"}
        cac = {idx: lv for kind, idx, lv in m.blocks if kind == "CAC"}
        for icc, plane in enumerate((pic.Cb, pic.Cr)):
            qpc = info.qpc[icc]
            ls4 = self.ls4[1 + icc + (0 if info.intra else 3)]
            dcl = cdc.get(icc, [0, 0, 0, 0])
            dc = chroma_dc(dcl, qpc, ls4)
            for b in range(4):
                lv = cac.get(4 * icc + b)
                d = dc[b]
                if (lv is None or not any(lv)) and d == 0:
                    continue
                r = itrans4x4(dequant4x4(lv if lv is not None else [0] * 15, self.scan, qpc, dc=d, ls4=ls4))
                x0, y0 = (b & 1) * 4, (b >> 1) * 4
                blk = plane[cy + y0:cy + y0 + 4, cx + x0:cx + x0 + 4]
                plane[cy + y0:cy + y0 + 4, cx + x0:cx + x0 + 4] = np.clip(blk + np.array(r, dtype=np.int32).reshape(4, 4), 0, 255)

    # ---- motion vectors

    def nb_part(self, x, y, lx):
        """8.4.1.3.2 / 6.4.11.7 step 7: the motion data of the partition holding MB-relative
        luma location (x, y): (available, mv, ref_idx). The current MB's blocks are
        available only once decoded (self.done)."""
        nb, xw, yw = self.nb_mb(self.addr, x, y)
        if nb is None:
            return False, (0, 0), -1
        blk = xy_blk(xw, yw)
        if nb is self.info:
            if not self.done[blk]:
                return False, (0, 0), -1
        if nb.intra or not nb.pred[lx][blk]:
            return True, (0, 0), -1
        return True, nb.mv[lx][blk], nb.ref[lx][blk]

    def mvp(self, x, y, w, h, pred_w, lx, ref_idx, shape=None, part=None):
        """8.4.1.3: the luma motion vector predictor for the partition at (x, y) w x h,
        with predPartWidth pred_w; directional rules for 16x8 / 8x16."""
        av_a, mv_a, r_a = self.nb_part(x - 1, y, lx)
        av_b, mv_b, r_b = self.nb_part(x, y - 1, lx)
        av_c, mv_c, r_c = self.nb_part(x + pred_w, y - 1, lx)
        if not av_c:
            av_c, mv_c, r_c = self.nb_part(x - 1, y - 1, lx)
        if shape == "16x8":
            if part == 0 and r_b == ref_idx:
                return mv_b
            if part == 1 and r_a == ref_idx:
                return mv_a
        elif shape == "8x16":
            if part == 0 and r_a == ref_idx:
                return mv_a
            if part == 1 and r_c == ref_idx:
                return mv_c
        # 8.4.1.3.1
        if not av_b and not av_c and av_a:
            mv_b, mv_c, r_b, r_c = mv_a, mv_a, r_a, r_a
        matches = [(r_a, mv_a), (r_b, mv_b), (r_c, mv_c)]
        eq = [mv for r, mv in matches if r == ref_idx]
        if len(eq) == 1:
            return eq[0]
        return (median(mv_a[0], mv_b[0], mv_c[0]), median(mv_a[1], mv_b[1], mv_c[1]))

    def set_part(self, info, blks, lx, mv, ref_idx, pred):
        rp = self.lists[lx][ref_idx] if pred and ref_idx >= 0 else None
        if pred and rp is None:
            raise ReconError("ref_idx_l%d %d names no reference picture (mb %d)" % (lx, ref_idx, self.addr))
        if pred and rp.marking() == LONG:
            self.dec.count("lt_used")
        if pred and ref_idx in self.mod_diff[lx]:
            self.dec.count("mod_dup_used")
        ident = rp.ident() if rp is not None else None
        for b in blks:
            info.mv[lx][b] = mv
            info.ref[lx][b] = ref_idx if pred else -1
            info.refpic[lx][b] = ident
            info.pred[lx][b] = 1 if pred else 0

    def begin_mvs(self, info):
        self.done = [0] * 16
        for lx in range(2):
            info.mv[lx] = [(0, 0)] * 16
            info.ref[lx] = [-1] * 16
            info.refpic[lx] = [None] * 16
            info.pred[lx] = [0] * 16

    def p_skip(self, info):
        """8.4.1.1"""
        self.begin_mvs(info)
        av_a, mv_a, r_a = self.nb_part(-1, 0, 0)
        av_b, mv_b, r_b = self.nb_part(0, -1, 0)
        if (not av_a or not av_b or (r_a == 0 and mv_a == (0, 0)) or (r_b == 0 and mv_b == (0, 0))):
            mv = (0, 0)
        else:
            mv = self.mvp(0, 0, 16, 16, 16, 0, 0)
        self.set_part(info, list(range(16)), 0, mv, 0, 1)
        self.done = [1] * 16

    def mb_pred(self, m, info, st):
        self.begin_mvs(info)
        if st == P:
            shape = ("16x16", "16x8", "8x16")[m.mb_type]
            preds = [L0] * len(PART_RECT[shape])
        else:
            if m.mb_type <= 3:
                shape, preds = "16x16", [m.mb_type]
            else:
                k = m.mb_type - 4
                shape = "16x8" if k % 2 == 0 else "8x16"
                preds = list(B_PAIR_PRED[k // 2])
        rects = PART_RECT[shape]
        # ref_idx per list per partition (absent -> 0), mvd per list per partition
        refs = [[0] * len(rects) for _ in range(2)]
        for lx in range(2):
            ri = 0
            for pi in range(len(rects)):
                if preds[pi] & (1 << lx):
                    if self.h.num_ref_idx[lx] > 1:
                        refs[lx][pi] = m.ref_idx[lx][ri]
                        ri += 1
        mvds = [[(0, 0)] * len(rects) for _ in range(2)]
        for lx in range(2):
            k = 0
            for pi in range(len(rects)):
                if preds[pi] & (1 << lx):
                    mvds[lx][pi] = (m.mvd[lx][k], m.mvd[lx][k + 1])
                    k += 2
        for pi, (x, y, w, h) in enumerate(rects):
            blks = rect_blks(x, y, w, h)
            for lx in range(2):
                if preds[pi] & (1 << lx):
                    p = self.mvp(x, y, w, h, w, lx, refs[lx][pi], shape, pi)
                    mv = (p[0] + mvds[lx][pi][0], p[1] + mvds[lx][pi][1])
                    self.set_part(info, blks, lx, mv, refs[lx][pi], 1)
            for b in blks:
                self.done[b] = 1

    def sub_mb_pred(self, m, info, st):
        self.begin_mvs(info)
        tab = P_SUB if st == P else B_SUB
        subs = [tab[t] for t in m.sub_types]
        refs = [[0] * 4 for _ in range(2)]
        for lx in range(2):
            ri = 0
            for b8, (pred, _shape) in enumerate(subs):
                if pred != DIRECT and pred & (1 << lx):
                    if self.h.num_ref_idx[lx] > 1:
                        refs[lx][b8] = m.ref_idx[lx][ri]
                        ri += 1
        mvds = [{} for _ in range(2)]
        for lx in range(2):
            k = 0
            for b8, (pred, shape) in enumerate(subs):
                if pred != DIRECT and pred & (1 << lx):
                    for si in range(len(SUB_RECT[shape])):
                        mvds[lx][(b8, si)] = (m.mvd[lx][k], m.mvd[lx][k + 1])
                        k += 2
        direct_b8 = [b8 for b8, (pred, _s) in enumerate(subs) if pred == DIRECT]
        if direct_b8:
            self.b_direct(info, direct_b8, partial=True)
        for b8, (pred, shape) in enumerate(subs):
            bx, by = (b8 & 1) * 8, (b8 >> 1) * 8
            if pred == DIRECT:
                for b in range(4):
                    self.done[4 * b8 + b] = 1
                continue
            for si, (sx, sy, w, h) in enumerate(SUB_RECT[shape]):
                x, y = bx + sx, by + sy
                blks = rect_blks(x, y, w, h)
                for lx in range(2):
                    if pred & (1 << lx):
                        p = self.mvp(x, y, w, h, w, lx, refs[lx][b8])
                        d = mvds[lx][(b8, si)]
                        self.set_part(info, blks, lx, (p[0] + d[0], p[1] + d[1]), refs[lx][b8], 1)
                for b in blks:
                    self.done[b] = 1

    # ---- direct (8.4.1.2)

    def colocated(self, blk):
        """8.4.1.2.1 for 4x4 block `blk` (luma4x4BlkIdx per direct_8x8_inference): returns
        (mvCol, refpic identity or None (intra), col_is_field, vert_scale, col_pic)."""
        pic = self.pic
        l1_0 = self.lists[1][0]
        if l1_0 is None:
            raise ReconError("direct prediction with an empty RefPicList1 (mb %d)" % self.addr)
        fr = l1_0.frame
        if self.sps.direct_8x8_inference:
            blk = 5 * (blk >> 2)
        x_col, y_col = BLK_XY[blk]
        w = self.w
        addr = self.addr
        if pic.field:
            if fr.coded_as_frame:
                # a field of a decoded frame: colPic is the frame (Frm_To_Fld)
                col = fr.mbinfo["F"]
                mb_col = 2 * w * (addr // w) + (addr % w) + w * (y_col // 8)
                y_m = (2 * y_col) % 16
                scale = "Frm_To_Fld"
                col_field = False
                col_struct = "F"
            else:
                col = fr.mbinfo[l1_0.struct]
                mb_col = addr
                y_m = y_col
                scale = "One_To_One"
                col_field = True
                col_struct = l1_0.struct
        else:
            if fr.coded_as_frame:
                col = fr.mbinfo["F"]
                mb_col = addr
                y_m = y_col
                scale = "One_To_One"
                col_field = False
                col_struct = "F"
            else:
                # a complementary field pair: the field closer in POC (Table 8-6)
                top_d = abs(fr.poc[TOP] - pic.poc)
                bot_d = abs(fr.poc[BOT] - pic.poc)
                col_struct = "T" if top_d < bot_d else "B"
                col = fr.mbinfo[col_struct]
                mb_col = w * (addr // (2 * w)) + (addr % w)
                y_m = 8 * ((addr // w) % 2) + 4 * (y_col // 8)
                scale = "Fld_To_Frm"
                col_field = True
        cm = col[mb_col]
        cblk = xy_blk(x_col, y_m)
        if cm.intra:
            return (0, 0), None, col_field, scale, col_struct, -1
        if cm.pred[0][cblk]:
            return cm.mv[0][cblk], cm.refpic[0][cblk], col_field, scale, col_struct, cm.ref[0][cblk]
        return cm.mv[1][cblk], cm.refpic[1][cblk], col_field, scale, col_struct, cm.ref[1][cblk]

    def b_direct(self, info, b8s, partial=False):
        if not partial:
            self.begin_mvs(info)
        if self.h.direct_spatial:
            self.spatial_direct(info, b8s)
        else:
            self.temporal_direct(info, b8s)

    def spatial_direct(self, info, b8s):
        """8.4.1.2.2"""
        refs = []
        mvs = []
        for lx in range(2):
            av_a, mv_a, r_a = self.nb_part(-1, 0, lx)
            av_b, mv_b, r_b = self.nb_part(0, -1, lx)
            av_c, mv_c, r_c = self.nb_part(16, -1, lx)
            if not av_c:
                av_c, mv_c, r_c = self.nb_part(-1, -1, lx)

            def minpos(a, b):
                return min(a, b) if a >= 0 and b >= 0 else max(a, b)
            r = minpos(r_a, minpos(r_b, r_c))
            refs.append(r)
        direct_zero = refs[0] < 0 and refs[1] < 0
        if direct_zero:
            refs = [0, 0]
        for lx in range(2):
            if direct_zero or refs[lx] < 0:
                mvs.append((0, 0))
            else:
                mvs.append(self.mvp(0, 0, 16, 16, 16, lx, refs[lx]))
        l1_0 = self.lists[1][0]
        l1_short = l1_0 is not None and l1_0.marking() == SHORT
        pred = [1 if refs[0] >= 0 else 0, 1 if refs[1] >= 0 else 0]
        for b8 in b8s:
            for b in range(4):
                blk = 4 * b8 + b
                mv_col, _rp, _cf, _sc, _cs, ref_col = self.colocated(blk)
                col_zero = l1_short and ref_col == 0 and -1 <= mv_col[0] <= 1 and -1 <= mv_col[1] <= 1
                for lx in range(2):
                    if not pred[lx]:
                        self.set_part(info, [blk], lx, (0, 0), -1, 0)
                        continue
                    mv = mvs[lx]
                    if direct_zero or (refs[lx] == 0 and col_zero):
                        mv = (0, 0)
                    self.set_part(info, [blk], lx, mv, refs[lx], 1)

    def map_col_to_list0(self, rp_ident, scale, col_struct):
        """8.4.1.2.3 MapColToList0: the lowest list-0 index referencing the co-located
        partition's reference picture (as a frame or as the field of the current parity)."""
        pic = self.pic
        fid, rstruct = rp_ident
        for i, e in enumerate(self.lists[0]):
            if e is None or e.frame.id != fid:
                continue
            if scale == "One_To_One":
                if e.struct == rstruct:
                    return i
            elif scale == "Frm_To_Fld":
                # field current, colPic a frame: the field of refPicCol with the current parity
                if e.struct == pic.struct:
                    return i
            else:
                # Fld_To_Frm: the frame containing the field refPicCol
                if e.struct == "F":
                    return i
        raise ReconError("temporal direct: RefPicList0 does not contain the co-located reference (mb %d)" % self.addr)

    def temporal_direct(self, info, b8s):
        """8.4.1.2.3"""
        pic = self.pic
        for b8 in b8s:
            for b in range(4):
                blk = 4 * b8 + b
                mv_col, rp, _cf, scale, col_struct, ref_col = self.colocated(blk)
                if rp is None:
                    ref0 = 0
                else:
                    ref0 = self.map_col_to_list0(rp, scale, col_struct)
                if scale == "Frm_To_Fld":
                    mv_col = (mv_col[0], c_div(mv_col[1], 2))
                elif scale == "Fld_To_Frm":
                    mv_col = (mv_col[0], mv_col[1] * 2)
                pic0 = self.lists[0][ref0]
                pic1 = self.lists[1][0]
                if pic0 is None:
                    raise ReconError("temporal direct: refIdxL0 %d names no picture" % ref0)
                if pic0.marking() == LONG or pic1.poc() - pic0.poc() == 0:
                    mv0, mv1 = mv_col, (0, 0)
                else:
                    tb = clip3(-128, 127, pic.poc - pic0.poc())
                    td = clip3(-128, 127, pic1.poc() - pic0.poc())
                    tx = c_div(16384 + abs(c_div(td, 2)), td)
                    dsf = clip3(-1024, 1023, (tb * tx + 32) >> 6)
                    mv0 = ((dsf * mv_col[0] + 128) >> 8, (dsf * mv_col[1] + 128) >> 8)
                    mv1 = (mv0[0] - mv_col[0], mv0[1] - mv_col[1])
                self.set_part(info, [blk], 0, mv0, ref0, 1)
                self.set_part(info, [blk], 1, mv1, 0, 1)

    # ---- inter prediction samples (8.4.2)

    def inter_predict(self, info):
        """Per 4x4 block group with identical motion: prediction, weighting, into the picture."""
        pic = self.pic
        mbx, mby = self.mbx, self.mby
        h = self.h
        pps = self.pps
        # group the 16 blocks by (mv0, ref0, mv1, ref1, pred flags) into rectangles: simplest
        # exact approach is per 4x4 block; group whole 8x8s / MB when uniform for speed
        keyf = [(info.pred[0][b], info.mv[0][b], info.ref[0][b], info.pred[1][b], info.mv[1][b], info.ref[1][b]) for b in range(16)]
        if len(set(keyf)) == 1:
            rects = [(0, 0, 16, 16)]
        else:
            rects = []
            for b8 in range(4):
                ks = [keyf[4 * b8 + b] for b in range(4)]
                bx, by = (b8 & 1) * 8, (b8 >> 1) * 8
                if len(set(ks)) == 1:
                    rects.append((bx, by, 8, 8))
                else:
                    for b in range(4):
                        rects.append((bx + (b & 1) * 4, by + (b >> 1) * 4, 4, 4))
        predY = np.zeros((16, 16), dtype=np.int32)
        predC = [np.zeros((8, 8), dtype=np.int32), np.zeros((8, 8), dtype=np.int32)]
        for (x, y, w, hh) in rects:
            blk = xy_blk(x, y)
            preds = []
            for lx in range(2):
                if not info.pred[lx][blk]:
                    preds.append(None)
                    continue
                ref_idx = info.ref[lx][blk]
                rp = self.lists[lx][ref_idx]
                mv = info.mv[lx][blk]
                Y, Cb, Cr = rp.planes()
                py = mc_luma(Y, mbx + x, mby + y, w, hh, mv[0], mv[1])
                # 8.4.1.4: the chroma vector; field pictures adjust for the reference parity
                cmv_y = mv[1]
                if pic.field:
                    if rp.struct == "T" and pic.struct == "B":
                        cmv_y += 2
                    elif rp.struct == "B" and pic.struct == "T":
                        cmv_y -= 2
                pcb = mc_chroma(Cb, (mbx + x) // 2, (mby + y) // 2, w // 2, hh // 2, mv[0], cmv_y)
                pcr = mc_chroma(Cr, (mbx + x) // 2, (mby + y) // 2, w // 2, hh // 2, mv[0], cmv_y)
                preds.append((py, pcb, pcr, ref_idx, rp))
            # 8.4.2.3 weighted sample prediction
            out = self.weighted(preds, info, blk)
            predY[y:y + hh, x:x + w] = out[0]
            predC[0][y // 2:(y + hh) // 2, x // 2:(x + w) // 2] = out[1]
            predC[1][y // 2:(y + hh) // 2, x // 2:(x + w) // 2] = out[2]
        pic.Y[mby:mby + 16, mbx:mbx + 16] = predY
        pic.Cb[mby // 2:mby // 2 + 8, mbx // 2:mbx // 2 + 8] = predC[0]
        pic.Cr[mby // 2:mby // 2 + 8, mbx // 2:mbx // 2 + 8] = predC[1]

    def weighted(self, preds, info, blk):
        h = self.h
        pps = self.pps
        pic = self.pic
        p0, p1 = preds
        both = p0 is not None and p1 is not None
        implicit = pps.weighted_bipred_idc == 2 and h.slice_type == B and both
        explicit = ((pps.weighted_bipred_idc == 1 and h.slice_type == B)
                    or (pps.weighted_pred and h.slice_type == P and p0 is not None))
        if not implicit and not explicit:
            if both:
                return [(p0[k].astype(np.int64) + p1[k] + 1) >> 1 for k in range(3)]
            p = p0 if p0 is not None else p1
            return [p[0], p[1], p[2]]
        if implicit:
            # 8.4.3: implicit weights from the POC distances
            pic0, pic1 = p0[4], p1[4]
            cur_poc = pic.poc
            tb = clip3(-128, 127, cur_poc - pic0.poc())
            td = clip3(-128, 127, pic1.poc() - pic0.poc())
            if td == 0 or pic0.marking() == LONG or pic1.marking() == LONG:
                w0 = w1 = 32
            else:
                tx = c_div(16384 + abs(c_div(td, 2)), td)
                dsf = clip3(-1024, 1023, (tb * tx + 32) >> 6)
                if (dsf >> 2) < -64 or (dsf >> 2) > 128:
                    w0 = w1 = 32
                else:
                    w0 = 64 - (dsf >> 2)
                    w1 = dsf >> 2
            out = []
            for k in range(3):
                a = p0[k].astype(np.int64)
                b = p1[k].astype(np.int64)
                out.append(clip1((a * w0 + b * w1 + 32) >> 6))
            return out
        # explicit
        out = []
        for k in range(3):
            if k == 0:
                logwd = h.luma_log2_wd
            else:
                logwd = h.chroma_log2_wd
            if both:
                r0, r1 = p0[3], p1[3]
                wt0, wt1 = h.weights[0][r0], h.weights[1][r1]
                if k == 0:
                    w0, o0, w1, o1 = wt0[0], wt0[1], wt1[0], wt1[1]
                else:
                    w0, o0 = wt0[2][k - 1]
                    w1, o1 = wt1[2][k - 1]
                a = p0[k].astype(np.int64)
                b = p1[k].astype(np.int64)
                out.append(clip1(((a * w0 + b * w1 + (1 << logwd)) >> (logwd + 1)) + ((o0 + o1 + 1) >> 1)))
            else:
                lx = 0 if p0 is not None else 1
                p = p0 if p0 is not None else p1
                wt = h.weights[lx][p[3]]
                if k == 0:
                    w, o = wt[0], wt[1]
                else:
                    w, o = wt[2][k - 1]
                a = p[k].astype(np.int64)
                if logwd >= 1:
                    out.append(clip1(((a * w + (1 << (logwd - 1))) >> logwd) + o))
                else:
                    out.append(clip1(a * w + o))
        return out


def c_div(a, b):
    """C-style integer division (truncation toward zero), as the spec's "/" on integers."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


# ---------------------------------------------------------------- deblocking (8.7)

def deblock_picture(pic, count=None):
    w = pic.w
    mbs = pic.mbs
    Y, Cb, Cr = pic.Y, pic.Cb, pic.Cr
    for addr in range(pic.n_mbs):
        q = mbs[addr]
        if not q.avail:
            continue
        mbx, mby = (addr % w) * 16, (addr // w) * 16
        ma = mbs[addr - 1] if addr % w else None
        mb_ = mbs[addr - w] if addr >= w else None
        if ma is not None and not ma.avail:
            ma = None
        if mb_ is not None and not mb_.avail:
            mb_ = None
        internal = q.disable_deblock != 1
        left = ma is not None and q.disable_deblock != 1 and not (q.disable_deblock == 2 and ma.slice != q.slice)
        top = mb_ is not None and q.disable_deblock != 1 and not (q.disable_deblock == 2 and mb_.slice != q.slice)
        if not internal and not left and not top:
            continue
        # luma vertical edges (with transform_size_8x8_flag only the edge at 8 inside)
        for e in range(4):
            if e == 0 and not left:
                continue
            if e > 0 and not internal:
                continue
            if e in (1, 3) and q.t8:
                # coverage: an edge the 4x4 transform would have filtered (bS > 0)
                if count is not None and any(boundary_strength(q, q, False, True, xy_blk(4 * e - 1, k), xy_blk(4 * e, k), pic.field)
                                             for k in range(16)):
                    count("t8_edge_skipped")
                continue
            p = ma if e == 0 else q
            for k in range(16):
                bs = boundary_strength(p, q, e == 0, True, xy_blk(15 if e == 0 else 4 * e - 1, k), xy_blk(4 * e, k), pic.field)
                if bs:
                    filter_line(Y, mby + k, mbx + 4 * e, True, bs, p, q, 0, q.alpha_off, q.beta_off)
        # luma horizontal edges
        for e in range(4):
            if e == 0 and not top:
                continue
            if e > 0 and not internal:
                continue
            if e in (1, 3) and q.t8:
                continue
            p = mb_ if e == 0 else q
            for k in range(16):
                bs = boundary_strength(p, q, e == 0, False, xy_blk(k, 15 if e == 0 else 4 * e - 1), xy_blk(k, 4 * e), pic.field)
                if bs:
                    filter_line(Y, mby + 4 * e, mbx + k, False, bs, p, q, 0, q.alpha_off, q.beta_off)
        # chroma: edges 0 and 4 (in chroma samples) with the luma bS of the corresponding line
        cx, cy = mbx // 2, mby // 2
        for icc, plane in enumerate((Cb, Cr)):
            for e in (0, 4):
                if e == 0 and not left:
                    continue
                if e > 0 and not internal:
                    continue
                p = ma if e == 0 else q
                for k in range(8):
                    bs = boundary_strength(p, q, e == 0, True, xy_blk(15 if e == 0 else 2 * e - 1, 2 * k), xy_blk(2 * e, 2 * k), pic.field)
                    if bs:
                        filter_line(plane, cy + k, cx + e, True, bs, p, q, icc + 1, q.alpha_off, q.beta_off)
            for e in (0, 4):
                if e == 0 and not top:
                    continue
                if e > 0 and not internal:
                    continue
                p = mb_ if e == 0 else q
                for k in range(8):
                    bs = boundary_strength(p, q, e == 0, False, xy_blk(2 * k, 15 if e == 0 else 2 * e - 1), xy_blk(2 * k, 2 * e), pic.field)
                    if bs:
                        filter_line(plane, cy + e, cx + k, False, bs, p, q, icc + 1, q.alpha_off, q.beta_off)


def boundary_strength(p, q, mb_edge, vertical, pblk, qblk, field):
    """8.7.2.1 (non-MBAFF)."""
    if mb_edge and (p.intra or q.intra):
        if not field or vertical:
            return 4
        return 3
    if p.intra or q.intra:
        return 3
    if p.nz[pblk] or q.nz[qblk]:
        return 2
    # motion: the set of reference pictures and the vectors per picture
    def motion(m, b):
        refs = []
        for lx in range(2):
            if m.pred[lx][b]:
                refs.append((m.refpic[lx][b], m.mv[lx][b]))
        return refs
    mp, mq = motion(p, pblk), motion(q, qblk)
    if len(mp) != len(mq):
        return 1
    if sorted(r for r, _ in mp) != sorted(r for r, _ in mq):
        return 1
    vlim = 2 if field else 4

    def far(a, b):
        return abs(a[0] - b[0]) >= 4 or abs(a[1] - b[1]) >= vlim
    if len(mp) == 1:
        return 1 if far(mp[0][1], mq[0][1]) else 0
    # two motion vectors
    (rp0, mvp0), (rp1, mvp1) = mp
    (rq0, mvq0), (rq1, mvq1) = mq
    if rp0 != rp1:
        # two different reference pictures: pair the vectors by picture
        if rq0 == rp0:
            return 1 if far(mvp0, mvq0) or far(mvp1, mvq1) else 0
        return 1 if far(mvp0, mvq1) or far(mvp1, mvq0) else 0
    # the same picture twice
    straight = far(mvp0, mvq0) or far(mvp1, mvq1)
    crossed = far(mvp0, mvq1) or far(mvp1, mvq0)
    return 1 if (straight and crossed) else 0


def filter_line(plane, y, x, vertical, bs, pm, qm, chroma, alpha_off, beta_off):
    """8.7.2: one set of samples across the edge at (x, y) (q0), p in the other direction."""
    if vertical:
        s = plane[y, x - 4:x + 4]
    else:
        s = plane[y - 4:y + 4, x]
    p3, p2, p1, p0, q0, q1, q2, q3 = [int(v) for v in s]
    if chroma:
        # 8.7.2: an I_PCM macroblock's chroma qP is the QPC of QPY = 0 -- WITH the chroma
        # offset (8.5.8), carried on the MbInfo as pcm_qpc
        qpp = pm.pcm_qpc[chroma - 1] if pm.pcm else pm.qpc[chroma - 1]
        qpq = qm.pcm_qpc[chroma - 1] if qm.pcm else qm.qpc[chroma - 1]
    else:
        qpp = 0 if pm.pcm else pm.qp
        qpq = 0 if qm.pcm else qm.qp
    qpav = (qpp + qpq + 1) >> 1
    idx_a = clip3(0, 51, qpav + alpha_off)
    idx_b = clip3(0, 51, qpav + beta_off)
    alpha, beta = ALPHA[idx_a], BETA[idx_b]
    if not (abs(p0 - q0) < alpha and abs(p1 - p0) < beta and abs(q1 - q0) < beta):
        return
    ap, aq = abs(p2 - p0), abs(q2 - q0)
    if bs < 4:
        tc0 = TC0[bs - 1][idx_a]
        if chroma:
            tc = tc0 + 1
        else:
            tc = tc0 + (1 if ap < beta else 0) + (1 if aq < beta else 0)
        delta = clip3(-tc, tc, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3)
        np0 = clip3(0, 255, p0 + delta)
        nq0 = clip3(0, 255, q0 - delta)
        np1, nq1 = p1, q1
        if not chroma and ap < beta:
            np1 = p1 + clip3(-tc0, tc0, (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1)
        if not chroma and aq < beta:
            nq1 = q1 + clip3(-tc0, tc0, (q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1)) >> 1)
        np2, nq2 = p2, q2
    else:
        if not chroma and ap < beta and abs(p0 - q0) < ((alpha >> 2) + 2):
            np0 = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
            np1 = (p2 + p1 + p0 + q0 + 2) >> 2
            np2 = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3
        else:
            np0 = (2 * p1 + p0 + q1 + 2) >> 2
            np1, np2 = p1, p2
        if not chroma and aq < beta and abs(p0 - q0) < ((alpha >> 2) + 2):
            nq0 = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3
            nq1 = (p0 + q0 + q1 + q2 + 2) >> 2
            nq2 = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3
        else:
            nq0 = (2 * q1 + q0 + p1 + 2) >> 2
            nq1, nq2 = q1, q2
    if vertical:
        plane[y, x - 3:x + 3] = [np2, np1, np0, nq0, nq1, nq2]
    else:
        plane[y - 3:y + 3, x] = [np2, np1, np0, nq0, nq1, nq2]


# ---------------------------------------------------------------- output and checking

def write_yuv(frames, path):
    with open(path, "wb") as f:
        for fr in frames:
            s = fr.sps
            l, r, t, b = s.crop
            # 4:2:0 frame cropping units: 2 horizontally, 2 * (2 - frame_mbs_only) vertically
            cu_y = 2 * (2 - s.frame_mbs_only)
            y0, y1 = t * cu_y, s.height - b * cu_y
            x0, x1 = l * 2, s.width - r * 2
            f.write(fr.Y[y0:y1, x0:x1].astype(np.uint8).tobytes())
            f.write(fr.Cb[y0 // 2:y1 // 2, x0 // 2:x1 // 2].astype(np.uint8).tobytes())
            f.write(fr.Cr[y0 // 2:y1 // 2, x0 // 2:x1 // 2].astype(np.uint8).tobytes())


def ffmpeg_yuv(stream, path):
    cmd = ["ffmpeg", "-v", "error", "-i", stream, "-fps_mode", "passthrough", "-f", "rawvideo",
           "-pix_fmt", "yuv420p", "-y", path]
    subprocess.check_call(cmd)


def compare_yuv(a, b, width, height):
    """First mismatch as (frame, plane, x, y, ours, theirs) or None; also the frame counts."""
    da = open(a, "rb").read()
    db = open(b, "rb").read()
    fs = width * height * 3 // 2
    na, nb = len(da) // fs, len(db) // fs
    n = min(na, nb)
    for i in range(n):
        fa = np.frombuffer(da[i * fs:(i + 1) * fs], dtype=np.uint8)
        fb = np.frombuffer(db[i * fs:(i + 1) * fs], dtype=np.uint8)
        if np.array_equal(fa, fb):
            continue
        d0 = d = int(np.nonzero(fa != fb)[0][0])
        if d < width * height:
            plane, x, y = "Y", d % width, d // width
        elif d < width * height * 5 // 4:
            d -= width * height
            plane, x, y = "Cb", d % (width // 2), d // (width // 2)
        else:
            d -= width * height * 5 // 4
            plane, x, y = "Cr", d % (width // 2), d // (width // 2)
        return (i, plane, x, y, int(fa[d0]), int(fb[d0])), na, nb
    return None, na, nb


def ref_code(ident):
    """The 8-bit reference-picture identity the fabric stores: store index (the model's
    frame id modulo 16 -- the bench maps ids to stores itself), structure 0 F / 1 T / 2 B,
    bit 7 = valid."""
    if ident is None:
        return 0
    fid, struct = ident
    return 0x80 | ((fid & 15) << 2) | {"F": 0, "T": 1, "B": 2}[struct]


class Dumper(object):
    """--dump: per picture in decode order, the pre- and post-deblock planes as raw
    4:2:0 (the field's own lines for a field picture), a .meta text file, and the
    per-macroblock side info the fabric keeps (one line per 4x4 block)."""

    def __init__(self, d):
        self.d = d
        self.n = 0
        self.dec = None                          # set by decode_file
        os.makedirs(d, exist_ok=True)

    def __call__(self, pic, pre):
        k = self.n
        self.n += 1
        h = pic.slices[0]
        with open(os.path.join(self.d, "pic_%04d.ctl.txt" % k), "w") as f:
            f.write("store %d struct %s poc_top %s poc_bot %s frame_num %d is_ref %d idr %d mmco5 %d\n" % (
                pic.frame.id, pic.struct, pic.frame.poc[0], pic.frame.poc[1], pic.frame_num, pic.is_ref, pic.idr, pic.mmco5))
            for si, (sh, lists) in enumerate(zip(pic.slices, pic.slice_lists)):
                f.write("slice %d type %s first_mb %d qp %d n_ref %d %d\n" % (si, "PBI"[sh.slice_type], sh.first_mb, sh.qp,
                                                                              sh.num_ref_idx[0], sh.num_ref_idx[1]))
                for lx in range(2):
                    f.write("  list%d" % lx)
                    for e in lists[lx]:
                        f.write(" -" if e is None else " %d%s/%d/%d" % e)
                    f.write("\n")
            # the DPB after this picture's marking: every frame with a field marked
            f.write("dpb")
            for fr in self.dec.dpb:
                f.write(" %d:%d%d/%s/%s/fn%d/lt%s" % (fr.id, fr.ref[0], fr.ref[1], fr.poc[0], fr.poc[1], fr.frame_num, fr.long_idx))
            f.write("\n")
        with open(os.path.join(self.d, "pic_%04d.pre.yuv" % k), "wb") as f:
            for p in pre:
                f.write(p.astype(np.uint8).tobytes())
        with open(os.path.join(self.d, "pic_%04d.post.yuv" % k), "wb") as f:
            for p in (pic.Y, pic.Cb, pic.Cr):
                f.write(np.ascontiguousarray(p).astype(np.uint8).tobytes())
        with open(os.path.join(self.d, "pic_%04d.meta" % k), "w") as f:
            f.write("struct %s\nframe_id %d\nframe_num %d\npoc %d\nwidth_mbs %d\nheight_mbs %d\nslices %d\n"
                    "is_ref %d\nidr %d\nslice_type %s\n" % (
                        pic.struct, pic.frame.id, pic.frame_num, pic.poc, pic.w, pic.hgt, len(pic.slices),
                        pic.is_ref, pic.idr, "".join("PBI"[s.slice_type] for s in pic.slices)))
        with open(os.path.join(self.d, "pic_%04d.mb.txt" % k), "w") as f:
            for a, m in enumerate(pic.mbs):
                f.write("M %d slice %d intra %d pcm %d qp %d type %s skip %d\n" % (
                    a, m.slice, m.intra, m.pcm, m.qp, m.mb_type, m.skip))
                for b in range(16):
                    f.write("  b%d" % b)
                    for lx in range(2):
                        f.write(" L%d %d %d %d %d %02x" % (lx, m.pred[lx][b], m.ref[lx][b], m.mv[lx][b][0], m.mv[lx][b][1],
                                                          ref_code(m.refpic[lx][b])))
                    f.write(" nz %d mode %d\n" % (m.nz[b], m.modes[b]))


def decode_file(stream, verbose=False, on_picture=None, records=None):
    import h264_fe_ref as FE
    if records is None:
        records = FE.decode_stream(open(stream, "rb").read())
    dec = Decoder(on_picture=on_picture, verbose=verbose)
    if on_picture is not None and hasattr(on_picture, "dec"):
        on_picture.dec = dec
    dec.feed(records)
    dec.flush_output()                           # end of stream (the RTL's K_EOS_WORD)
    return dec


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stream", help="an Annex-B file")
    ap.add_argument("--yuv", help="write the display-order frames (cropped)")
    ap.add_argument("--check", action="store_true", help="compare with ffmpeg's decode (needs ffmpeg)")
    ap.add_argument("--records", help="a canonical record file instead of decoding the stream")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--dump", help="decode-order picture and macroblock dumps into this directory (the RTL benches' golden)")
    a = ap.parse_args(argv)
    records = None
    if a.records:
        records = [ln.rstrip("\n") for ln in open(a.records) if ln.strip()]
    dec = decode_file(a.stream, verbose=a.verbose, records=records,
                      on_picture=Dumper(a.dump) if a.dump else None)
    frames = dec.output_frames()
    print("%d pictures, %d frames" % (dec.n_pictures, len(frames)), file=sys.stderr)
    yuv = a.yuv
    if a.check and not yuv:
        yuv = a.stream + ".recon.yuv"
    if yuv:
        write_yuv(frames, yuv)
    if a.check:
        ref = a.stream + ".ffmpeg.yuv"
        ffmpeg_yuv(a.stream, ref)
        s = frames[0].sps
        l, r, t, b = s.crop
        cu_y = 2 * (2 - s.frame_mbs_only)
        w, h = s.width - 2 * (l + r), s.height - cu_y * (t + b)
        mism, na, nb = compare_yuv(yuv, ref, w, h)
        if mism is None and na == nb:
            print("BIT-EXACT vs ffmpeg: %d frames of %dx%d" % (na, w, h))
            return 0
        if mism is None and na == nb + 1 and dec.prev_pic is not None and dec.prev_pic.field \
                and not all(dec.prev_pic.frame.decoded):
            # a clip cut after a first field: ffmpeg does not output the unpaired field
            print("BIT-EXACT vs ffmpeg: %d frames of %dx%d (+1 unpaired trailing field)" % (nb, w, h))
            return 0
        if mism is None:
            print("MISMATCH: frame count %d (model) vs %d (ffmpeg)" % (na, nb))
        else:
            print("MISMATCH at frame %d plane %s x %d y %d: model %d ffmpeg %d" % mism)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReconError as e:
        sys.exit("h264_recon_ref: %s" % e)
