#!/usr/bin/env python3
"""The Phase 3 front end as a Python reference: Annex-B NAL units -> SPS / PPS / slice
header -> CABAC slice data -> the canonical syntax-element stream of
tools/h264_trace_ref.py. Everything the RTL (`nal_parser`, `sps_pps`, `slice_hdr`,
`cabac_engine`, `cabac_ctx`, `mb_syntax`) will do, in the spec's own terms, scored
against JM's trace of the same stream (docs/h264_frontend.md S2).

Scope is the core's: Main and High profiles (H264 Phase 5: the 8x8 transform, intra 8x8
and scaling matrices), CABAC, frame and field pictures, 4:2:0, 8-bit. CAVLC, MBAFF,
monochrome and the other chroma formats, slice groups, data partitioning, SP/SI, the
transform bypass are REFUSED with a `Refused` error naming the field, never decoded as
guesswork -- the same refusals the fabric will flag.

Written against the 06/2026 spec text: 7.3 syntax, 7.4 semantics (Tables 7-11, 7-13,
7-14, 7-17, 7-18), 6.4.11 neighbour derivations, 9.3.2 binarisations (Tables 9-34 to
9-38), 9.3.3.1 ctxIdx derivations (Tables 9-39 to 9-43, clauses 9.3.3.1.1.1-9,
9.3.3.1.2, 9.3.3.1.3). Where a decoder shortcut is common (mvd of a direct partition
is 0) the spec's condition is what is coded, with the clause named beside it.

    h264_fe_ref.py stream.264 [-o canonical.txt] [--stats]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from cabac_ref import BitReader, Cabac, CabacError, CTX_TERMINATE  # noqa: E402
import high_tables as HT  # noqa: E402

P, B, I = 0, 1, 2                      # slice_type % 5 (SP = 3, SI = 4 refused)


class Refused(Exception):
    """A feature outside the core's scope: refused loudly, never decoded as garbage."""


class FeError(Exception):
    pass


# ---------------------------------------------------------------- NAL units

def nal_units(data):
    """Annex B (B.1): split at start codes, strip emulation-prevention bytes (7.4.1).
    Yields (nal_ref_idc, nal_unit_type, rbsp)."""
    for _pos, ref_idc, ntype, rbsp in nal_units_pos(data):
        yield ref_idc, ntype, rbsp


def nal_units_pos(data):
    """nal_units(), with the byte offset of each NAL unit's header byte in `data` (its
    3-byte start code 00 00 01 is at offset - 3)."""
    n = len(data)
    i = data.find(b"\x00\x00\x01")
    while i >= 0 and i < n:
        s = i + 3
        j = data.find(b"\x00\x00\x01", s)
        if j < 0:
            e = n
            j = n
        else:
            e = j
            # a 4-byte start code's leading zero belongs to the start code, not the NAL
            while e > s and data[e - 1] == 0:
                e -= 1
        nal = data[s:e]
        if nal:
            hdr = nal[0]
            if hdr & 0x80:
                raise FeError("forbidden_zero_bit set at byte %d" % s)
            rbsp = bytearray()
            zeros = 0
            for b in nal[1:]:
                if zeros >= 2 and b == 3:
                    zeros = 0
                    continue
                rbsp.append(b)
                zeros = zeros + 1 if b == 0 else 0
            yield s, (hdr >> 5) & 3, hdr & 0x1F, bytes(rbsp)
        i = j


# ---------------------------------------------------------------- parameter sets

class Sps(object):
    pass


class Pps(object):
    pass


HIGH_PROFILES = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)

# scaling lists (7.3.2.1.1.1, 7.4.2.1.1 Table 7-2), kept in coded (zig-zag) order
FLAT4, FLAT8 = [16] * 16, [16] * 64
DEFAULT_LISTS = [HT.DEFAULT_4X4_INTRA] * 3 + [HT.DEFAULT_4X4_INTER] * 3 + [HT.DEFAULT_8X8_INTRA, HT.DEFAULT_8X8_INTER]


def scaling_list(br, n, f):
    """7.3.2.1.1.1: returns the list (coded order), or "default" when
    useDefaultScalingMatrixFlag is set (the first delta brings nextScale to 0)."""
    last, nxt = 8, 8
    out = []
    for j in range(n):
        if nxt != 0:
            d = f("delta_scale", br.se())
            if d < -128 or d > 127:
                raise FeError("delta_scale %d (7.4.2.1.1: -128..127)" % d)
            nxt = (last + d + 256) % 256
            if j == 0 and nxt == 0:
                # the remaining deltas are not coded (nextScale 0 stops the reads)
                return "default"
        out.append(last if nxt == 0 else nxt)
        last = out[-1]
    return out


def parse_scaling_lists(br, n, f, kind):
    """n lists, each: None (not present: fall-back), "default", or the coded list."""
    lists = []
    for i in range(n):
        if f("%s_scaling_list_present_flag[i]" % kind, br.read_bit()):
            lists.append(scaling_list(br, 16 if i < 6 else 64, f))
        else:
            lists.append(None)
    return lists


def resolve_scaling(sps, pps):
    """The scaling lists a slice uses (7.4.2.1.1 / 7.4.2.2, Table 7-2 fall-back rules A
    and B): (six 4x4 lists, two 8x8 lists), each in coded (zig-zag) order. Flat_16 when
    neither set carries a matrix. Returns also which list each came from, as the model's
    coverage evidence: 'flat', 'default', 'sps', 'pps', or 'fallback'."""
    def resolve(raw, fallback):
        out, src = [], []
        for i in range(8):
            r = raw[i] if i < len(raw) else None
            if r == "default":
                out.append(DEFAULT_LISTS[i]); src.append("default")
            elif r is not None:
                out.append(r); src.append("coded")
            else:
                v, sv = fallback(i, out, src)
                out.append(v); src.append(sv)
        return out, src

    def rule_a(i, out, src):
        if i in (0, 3, 6, 7):
            return DEFAULT_LISTS[i], "fallback-default"
        return out[i - 1], "fallback-previous"
    if sps.scaling_present:
        sl, ss = resolve(sps.scaling_lists, rule_a)
    else:
        sl, ss = [FLAT4] * 6 + [FLAT8] * 2, ["flat"] * 8
    if pps.scaling_present:
        if sps.scaling_present:
            def rule_b(i, out, src):
                if i in (0, 3, 6, 7):
                    return sl[i], "fallback-sps"
                return out[i - 1], "fallback-previous"
            pl, ps = resolve(pps.scaling_lists, rule_b)
        else:
            pl, ps = resolve(pps.scaling_lists, rule_a)
        return pl, ps
    return sl, ss


def scaling_words(sps, pps):
    """The resolved matrix as the RTL front end emits it after each slice header
    (docs/high_profile.md S3, tools/h264_fields.py): [("scaling_matrix_flag", 0)] when
    every list is Flat_16, else the flag 1 and 56 scaling_list_words -- lists 0..7 in coded
    order, four weights a word, the first in bits 7..0."""
    sl, _src = resolve_scaling(sps, pps)
    # flat by SOURCE (neither set carries a matrix), not by value: a coded list of 16s is
    # sent as a list -- the RTL decides from the two present flags alone
    if not sps.scaling_present and not pps.scaling_present:
        return [("scaling_matrix_flag", 0)]
    out = [("scaling_matrix_flag", 1)]
    for lst in sl:
        for k in range(0, len(lst), 4):
            out.append(("scaling_list_word", lst[k] | (lst[k + 1] << 8) | (lst[k + 2] << 16) | (lst[k + 3] << 24)))
    return out


def parse_sps(rbsp, rec, fabric_max_mbs=None):
    """With fabric_max_mbs, also refuse what the RTL's memories cannot hold (a picture
    wider or taller than that many macroblocks), at the same field the RTL does."""
    br = BitReader(rbsp)
    s = Sps()

    def f(name, v):
        rec.append("S %s %d" % (name, v))
        return v
    s.profile_idc = f("profile_idc", br.read_bits(8))
    for k in range(3):
        f("constraint_set%d_flag" % k, br.read_bit())
    br.read_bits(5)                                   # constraint_set3..5 + reserved_zero_2bits
    s.level_idc = f("level_idc", br.read_bits(8))
    s.id = f("seq_parameter_set_id", br.ue())
    s.chroma_format_idc = 1
    s.scaling_present = 0
    s.scaling_lists = []
    if s.profile_idc in HIGH_PROFILES:
        s.chroma_format_idc = f("chroma_format_idc", br.ue())
        if s.chroma_format_idc != 1:
            raise Refused("chroma_format_idc %d" % s.chroma_format_idc)
        if f("bit_depth_luma_minus8", br.ue()) or f("bit_depth_chroma_minus8", br.ue()):
            raise Refused("bit depth above 8")
        if f("lossless_qpprime_y_zero_flag", br.read_bit()):
            raise Refused("qpprime_y_zero_transform_bypass_flag")      # High 4:4:4 only
        s.scaling_present = f("seq_scaling_matrix_present_flag", br.read_bit())
        if s.scaling_present:
            s.scaling_lists = parse_scaling_lists(br, 8, f, "seq")     # 4:2:0: 8 lists
    s.log2_max_frame_num = f("log2_max_frame_num_minus4", br.ue()) + 4
    s.poc_type = f("pic_order_cnt_type", br.ue())
    if s.poc_type == 0:
        s.log2_max_poc_lsb = f("log2_max_pic_order_cnt_lsb_minus4", br.ue()) + 4
    elif s.poc_type == 1:
        s.delta_pic_order_always_zero_flag = f("delta_pic_order_always_zero_flag", br.read_bit())
        f("offset_for_non_ref_pic", br.se())
        f("offset_for_top_to_bottom_field", br.se())
        n = f("num_ref_frames_in_pic_order_cnt_cycle", br.ue())
        for _ in range(n):
            f("offset_for_ref_frame[i]", br.se())
    f("num_ref_frames", br.ue())
    f("gaps_in_frame_num_value_allowed_flag", br.read_bit())
    s.width_mbs = f("pic_width_in_mbs_minus1", br.ue()) + 1
    if fabric_max_mbs and s.width_mbs > fabric_max_mbs:
        raise Refused("pic_width_in_mbs %d beyond the fabric" % s.width_mbs)
    s.height_map_units = f("pic_height_in_map_units_minus1", br.ue()) + 1
    if fabric_max_mbs and s.height_map_units > fabric_max_mbs:
        raise Refused("pic_height_in_map_units %d beyond the fabric" % s.height_map_units)
    s.frame_mbs_only = f("frame_mbs_only_flag", br.read_bit())
    if fabric_max_mbs and (2 - s.frame_mbs_only) * s.height_map_units > fabric_max_mbs:
        raise Refused("FrameHeightInMbs %d beyond the fabric" % ((2 - s.frame_mbs_only) * s.height_map_units))
    s.mbaff = 0
    if not s.frame_mbs_only:
        s.mbaff = f("mb_adaptive_frame_field_flag", br.read_bit())
        if s.mbaff:
            raise Refused("mb_adaptive_frame_field_flag")
    s.direct_8x8_inference = f("direct_8x8_inference_flag", br.read_bit())
    if f("frame_cropping_flag", br.read_bit()):
        for k in ("left", "right", "top", "bottom"):
            f("frame_crop_%s_offset" % k, br.ue())
    s.vui = f("vui_parameters_present_flag", br.read_bit())
    parse_vui(br, s, f)
    s.frame_height_mbs = (2 - s.frame_mbs_only) * s.height_map_units
    return s


def parse_vui(br, s, f):
    """E.1.1 / E.1.2, every field recorded in syntax order (P5: the display reads the
    aspect, the timing, pic_struct_present_flag, the HRD delay lengths the picture timing
    SEI needs, and max_dec_frame_buffering). Defaults (E.2.1) for an SPS without them.
    Range errors are the RTL's (h264/dec/sps_pps.sv), on the values it stores or loops
    over -- an out-of-range value there would alias a legal one or run a loop away."""
    s.aspect_ratio_idc, s.sar_width, s.sar_height = 0, 0, 0
    s.timing_info_present, s.num_units_in_tick, s.time_scale = 0, 0, 0
    s.pic_struct_present = 0
    s.cpb_dpb_delays_present = 0
    s.cpb_removal_delay_length_minus1 = 23      # E.2.2 inferred values
    s.dpb_output_delay_length_minus1 = 23
    s.time_offset_length = 24
    s.bitstream_restriction = 0
    s.max_num_reorder_frames = None
    s.max_dec_frame_buffering = None            # None = infer MaxDpbFrames (E.2.1)
    if not s.vui:
        return
    if f("aspect_ratio_info_present_flag", br.read_bit()):
        s.aspect_ratio_idc = f("aspect_ratio_idc", br.read_bits(8))
        if s.aspect_ratio_idc == 255:           # Extended_SAR
            s.sar_width = f("sar_width", br.read_bits(16))
            s.sar_height = f("sar_height", br.read_bits(16))
    if f("overscan_info_present_flag", br.read_bit()):
        f("overscan_appropriate_flag", br.read_bit())
    if f("video_signal_type_present_flag", br.read_bit()):
        f("video_format", br.read_bits(3))
        f("video_full_range_flag", br.read_bit())
        if f("colour_description_present_flag", br.read_bit()):
            f("colour_primaries", br.read_bits(8))
            f("transfer_characteristics", br.read_bits(8))
            f("matrix_coefficients", br.read_bits(8))
    if f("chroma_loc_info_present_flag", br.read_bit()):
        f("chroma_sample_loc_type_top_field", br.ue())
        f("chroma_sample_loc_type_bottom_field", br.ue())
    s.timing_info_present = f("timing_info_present_flag", br.read_bit())
    if s.timing_info_present:
        s.num_units_in_tick = f("num_units_in_tick", br.read_bits(32))
        s.time_scale = f("time_scale", br.read_bits(32))
        if s.num_units_in_tick == 0 or s.time_scale == 0:
            raise FeError("num_units_in_tick / time_scale 0 (E.2.1: greater than 0)")
        f("fixed_frame_rate_flag", br.read_bit())
    lengths = None
    hrd_any = 0
    for kind in ("nal", "vcl"):
        if f("%s_hrd_parameters_present_flag" % kind, br.read_bit()):
            hrd_any = 1
            cnt = f("cpb_cnt_minus1", br.ue())
            if cnt > 31:
                raise FeError("cpb_cnt_minus1 %d (0..31)" % cnt)
            f("bit_rate_scale", br.read_bits(4))
            f("cpb_size_scale", br.read_bits(4))
            for _ in range(cnt + 1):
                f("bit_rate_value_minus1[i]", br.ue())
                f("cpb_size_value_minus1[i]", br.ue())
                f("cbr_flag[i]", br.read_bit())
            ln = (f("initial_cpb_removal_delay_length_minus1", br.read_bits(5)),
                  f("cpb_removal_delay_length_minus1", br.read_bits(5)),
                  f("dpb_output_delay_length_minus1", br.read_bits(5)),
                  f("time_offset_length", br.read_bits(5)))
            if lengths is not None and ln != lengths:
                raise FeError("NAL and VCL hrd_parameters() lengths differ (E.2.2: shall be equal)")
            lengths = ln
    if hrd_any:
        f("low_delay_hrd_flag", br.read_bit())
        s.cpb_dpb_delays_present = 1
        (_i, s.cpb_removal_delay_length_minus1, s.dpb_output_delay_length_minus1,
         s.time_offset_length) = lengths
    s.pic_struct_present = f("pic_struct_present_flag", br.read_bit())
    s.bitstream_restriction = f("bitstream_restriction_flag", br.read_bit())
    if s.bitstream_restriction:
        f("motion_vectors_over_pic_boundaries_flag", br.read_bit())
        f("max_bytes_per_pic_denom", br.ue())
        f("max_bits_per_mb_denom", br.ue())
        f("log2_max_mv_length_horizontal", br.ue())
        f("log2_max_mv_length_vertical", br.ue())
        s.max_num_reorder_frames = f("max_num_reorder_frames", br.ue())
        s.max_dec_frame_buffering = f("max_dec_frame_buffering", br.ue())
        if s.max_dec_frame_buffering > 16:
            raise FeError("max_dec_frame_buffering %d (A.3.1: at most 16)" % s.max_dec_frame_buffering)
        if s.max_num_reorder_frames > s.max_dec_frame_buffering:
            raise FeError("max_num_reorder_frames above max_dec_frame_buffering (E.2.1)")


def parse_pps(rbsp, sps_map, rec):
    br = BitReader(rbsp)
    p = Pps()

    def f(name, v):
        rec.append("S %s %d" % (name, v))
        return v
    p.id = f("pic_parameter_set_id", br.ue())
    p.sps_id = f("seq_parameter_set_id", br.ue())
    p.cabac = f("entropy_coding_mode_flag", br.read_bit())
    if not p.cabac:
        raise Refused("entropy_coding_mode_flag 0 (CAVLC)")
    p.bottom_field_pic_order_in_frame_present = f("bottom_field_pic_order_in_frame_present_flag", br.read_bit())
    if f("num_slice_groups_minus1", br.ue()):
        raise Refused("num_slice_groups_minus1 > 0 (FMO)")
    p.num_ref_idx_l0_default = f("num_ref_idx_l0_default_active_minus1", br.ue()) + 1
    p.num_ref_idx_l1_default = f("num_ref_idx_l1_default_active_minus1", br.ue()) + 1
    p.weighted_pred = f("weighted_pred_flag", br.read_bit())
    p.weighted_bipred_idc = f("weighted_bipred_idc", br.read_bits(2))
    p.pic_init_qp = f("pic_init_qp_minus26", br.se()) + 26
    f("pic_init_qs_minus26", br.se())
    p.chroma_qp_index_offset = f("chroma_qp_index_offset", br.se())
    p.deblocking_filter_control_present = f("deblocking_filter_control_present_flag", br.read_bit())
    p.constrained_intra_pred = f("constrained_intra_pred_flag", br.read_bit())
    p.redundant_pic_cnt_present = f("redundant_pic_cnt_present_flag", br.read_bit())
    p.transform_8x8_mode = 0
    p.scaling_present = 0
    p.scaling_lists = []
    p.second_chroma_qp_index_offset = p.chroma_qp_index_offset      # 7.4.2.2: inferred
    if br.more_rbsp_data():
        p.transform_8x8_mode = f("transform_8x8_mode_flag", br.read_bit())
        p.scaling_present = f("pic_scaling_matrix_present_flag", br.read_bit())
        if p.scaling_present:
            # 6 + (chroma_format_idc != 3 ? 2 : 6) * transform_8x8_mode_flag; 4:4:4 is
            # refused at its SPS, so the 4:2:0 count holds for any PPS this decoder uses
            p.scaling_lists = parse_scaling_lists(br, 6 + 2 * p.transform_8x8_mode, f, "pic")
        p.second_chroma_qp_index_offset = f("second_chroma_qp_index_offset", br.se())
    return p


# ---------------------------------------------------------------- slice header

class SliceHeader(object):
    pass


def parse_slice_header(br, nal_type, nal_ref_idc, sps_map, pps_map, rec):
    h = SliceHeader()

    def f(name, v):
        rec.append("S %s %d" % (name, v))
        return v
    h.first_mb = f("first_mb_in_slice", br.ue())
    st = f("slice_type", br.ue())
    h.slice_type = st % 5
    if h.slice_type not in (P, B, I):
        raise Refused("slice_type %d (SP/SI)" % st)
    h.pps_id = f("pic_parameter_set_id", br.ue())
    if h.pps_id not in pps_map:
        raise FeError("slice refers to PPS %d before it was sent" % h.pps_id)
    pps = pps_map[h.pps_id]
    sps = sps_map[pps.sps_id]
    h.pps, h.sps = pps, sps
    h.frame_num = f("frame_num", br.read_bits(sps.log2_max_frame_num))
    h.field_pic = 0
    h.bottom_field = 0
    if not sps.frame_mbs_only:
        h.field_pic = f("field_pic_flag", br.read_bit())
        if h.field_pic:
            h.bottom_field = f("bottom_field_flag", br.read_bit())
    h.idr = nal_type == 5
    if h.idr:
        f("idr_pic_id", br.ue())
    if sps.poc_type == 0:
        f("pic_order_cnt_lsb", br.read_bits(sps.log2_max_poc_lsb))
        if pps.bottom_field_pic_order_in_frame_present and not h.field_pic:
            f("delta_pic_order_cnt_bottom", br.se())
    if sps.poc_type == 1 and not sps.delta_pic_order_always_zero_flag:
        f("delta_pic_order_cnt[0]", br.se())
        if pps.bottom_field_pic_order_in_frame_present and not h.field_pic:
            f("delta_pic_order_cnt[1]", br.se())
    if pps.redundant_pic_cnt_present:
        if f("redundant_pic_cnt", br.ue()):
            raise Refused("redundant_pic_cnt > 0")
    if h.slice_type == B:
        h.direct_spatial = f("direct_spatial_mv_pred_flag", br.read_bit())
    h.num_ref_idx = [pps.num_ref_idx_l0_default, pps.num_ref_idx_l1_default]
    if h.slice_type in (P, B):
        if f("num_ref_idx_active_override_flag", br.read_bit()):
            h.num_ref_idx[0] = f("num_ref_idx_l0_active_minus1", br.ue()) + 1
            if h.slice_type == B:
                h.num_ref_idx[1] = f("num_ref_idx_l1_active_minus1", br.ue()) + 1
        for lx in range(2 if h.slice_type == B else 1):
            if f("ref_pic_list_modification_flag_l%d" % lx, br.read_bit()):
                while True:
                    idc = f("modification_of_pic_nums_idc_l%d" % lx, br.ue())
                    if idc == 3:
                        break
                    if idc in (0, 1):
                        f("abs_diff_pic_num_minus1_l%d" % lx, br.ue())
                    elif idc == 2:
                        f("long_term_pic_num_l%d" % lx, br.ue())
                    else:
                        raise FeError("modification_of_pic_nums_idc %d" % idc)
    if (pps.weighted_pred and h.slice_type == P) or (pps.weighted_bipred_idc == 1 and h.slice_type == B):
        f("luma_log2_weight_denom", br.ue())
        f("chroma_log2_weight_denom", br.ue())
        for lx in range(2 if h.slice_type == B else 1):
            for _i in range(h.num_ref_idx[lx]):
                if f("luma_weight_flag_l%d" % lx, br.read_bit()):
                    f("luma_weight_l%d" % lx, br.se())
                    f("luma_offset_l%d" % lx, br.se())
                if f("chroma_weight_flag_l%d" % lx, br.read_bit()):
                    for _j in range(2):
                        f("chroma_weight_l%d" % lx, br.se())
                        f("chroma_offset_l%d" % lx, br.se())
    if nal_ref_idc:
        if h.idr:
            f("no_output_of_prior_pics_flag", br.read_bit())
            f("long_term_reference_flag", br.read_bit())
        elif f("adaptive_ref_pic_marking_mode_flag", br.read_bit()):
            while True:
                op = f("memory_management_control_operation", br.ue())
                if op == 0:
                    break
                if op in (1, 3):
                    f("difference_of_pic_nums_minus1", br.ue())
                if op == 2:
                    f("long_term_pic_num", br.ue())
                if op in (3, 6):
                    f("long_term_frame_idx", br.ue())
                if op == 4:
                    f("max_long_term_frame_idx_plus1", br.ue())
    h.cabac_init_idc = None
    if h.slice_type != I:
        h.cabac_init_idc = f("cabac_init_idc", br.ue())
        if h.cabac_init_idc > 2:
            raise FeError("cabac_init_idc %d" % h.cabac_init_idc)
    h.qp = pps.pic_init_qp + f("slice_qp_delta", br.se())
    h.disable_deblocking = 0
    if pps.deblocking_filter_control_present:
        h.disable_deblocking = f("disable_deblocking_filter_idc", br.ue())
        if h.disable_deblocking != 1:
            f("slice_alpha_c0_offset_div2", br.se())
            f("slice_beta_offset_div2", br.se())
    # cabac_alignment_one_bit
    while not br.byte_aligned():
        if br.read_bit() != 1:
            raise FeError("cabac_alignment_one_bit is 0")
    return h


# ---------------------------------------------------------------- macroblock types

I_NXN, I_PCM_IDX = 0, 25              # I-slice mb_type values (Table 7-11)
P_8X8, B_DIRECT_16X16, B_8X8 = 3, 0, 22
L0, L1, BI, DIRECT = 1, 2, 3, 0       # prediction as a bit set (bit 0: list 0, bit 1: list 1)

# B mb_type 4..21 (Table 7-14): (part0 pred, part1 pred), 16x8 for even, 8x16 for odd
B_PAIR_PRED = [(L0, L0), (L1, L1), (L0, L1), (L1, L0), (L0, BI), (L1, BI), (BI, L0), (BI, L1), (BI, BI)]
# sub_mb_type (Tables 7-17, 7-18): (pred, number of sub-partitions, shape)
P_SUB = {0: (L0, 1, "8x8"), 1: (L0, 2, "8x4"), 2: (L0, 2, "4x8"), 3: (L0, 4, "4x4")}
B_SUB = {0: (DIRECT, 4, "4x4"), 1: (L0, 1, "8x8"), 2: (L1, 1, "8x8"), 3: (BI, 1, "8x8"),
         4: (L0, 2, "8x4"), 5: (L0, 2, "4x8"), 6: (L1, 2, "8x4"), 7: (L1, 2, "4x8"),
         8: (BI, 2, "8x4"), 9: (BI, 2, "4x8"), 10: (L0, 4, "4x4"), 11: (L1, 4, "4x4"), 12: (BI, 4, "4x4")}
# the 4x4 blocks (luma4x4BlkIdx) of each partition
PART_BLKS = {
    "16x16": [list(range(16))],
    "16x8": [[0, 1, 2, 3, 4, 5, 6, 7], [8, 9, 10, 11, 12, 13, 14, 15]],
    "8x16": [[0, 1, 2, 3, 8, 9, 10, 11], [4, 5, 6, 7, 12, 13, 14, 15]],
}
SUB_BLKS = {"8x8": [[0, 1, 2, 3]], "8x4": [[0, 1], [2, 3]], "4x8": [[0, 2], [1, 3]], "4x4": [[0], [1], [2], [3]]}


def blk_xy(idx):
    """luma4x4BlkIdx -> (x, y) in the macroblock (6.4.3)."""
    return (idx >> 2 & 1) * 8 + (idx & 1) * 4, (idx >> 3) * 8 + (idx >> 1 & 1) * 4


def xy_blk(x, y):
    return 8 * (y >> 3) + 4 * (x >> 3) + 2 * ((y & 7) >> 2) + ((x & 7) >> 2)


class Mb(object):
    """Everything later macroblocks' context derivations look at."""
    __slots__ = ("slice", "skip", "mb_type", "intra", "i16", "pcm", "direct16", "cbp",
                 "chroma_mode", "qp_delta", "ref", "mvd", "pred", "cbf_luma", "cbf_dc",
                 "cbf_cdc", "cbf_cac", "sub_direct", "t8")

    def __init__(self, slice_id):
        self.slice = slice_id
        self.skip = 0
        self.mb_type = None
        self.intra = 0
        self.i16 = 0
        self.pcm = 0
        self.direct16 = 0
        self.cbp = 0
        self.chroma_mode = 0
        self.qp_delta = 0
        self.ref = [[0] * 16, [0] * 16]           # per 4x4 block, per list
        self.mvd = [[(0, 0)] * 16, [(0, 0)] * 16]
        self.pred = [[0] * 16, [0] * 16]          # predFlagLX per 4x4 block (0 for direct: 9.3.3.1.1.6/7)
        self.cbf_luma = [0] * 16
        self.cbf_dc = 0
        self.cbf_cdc = [0, 0]
        self.cbf_cac = [[0] * 4, [0] * 4]
        self.sub_direct = [0] * 4
        self.t8 = 0                               # transform_size_8x8_flag


# ---------------------------------------------------------------- slice data

class SliceDecoder(object):
    def __init__(self, h, rbsp, pos, pic, slice_id, rec):
        self.h = h
        self.sps, self.pps = h.sps, h.pps
        self.br = BitReader(rbsp, pos)
        self.cab = Cabac(self.br)
        self.pic = pic                    # list of Mb or None, one per mbAddr
        self.slice_id = slice_id
        self.rec = rec
        self.w = self.sps.width_mbs
        self.hgt = self.sps.frame_height_mbs // (2 if h.field_pic else 1)
        self.field = h.field_pic
        self.prev = None                  # previous MB in decoding order (mb_qp_delta ctx)
        self.cur = None
        self.addr = 0

    # ---- neighbours (6.4.9 / 6.4.11.1, non-MBAFF)

    def mb_a(self):
        if self.addr % self.w == 0:
            return None
        m = self.pic[self.addr - 1]
        return m if m is not None and m.slice == self.slice_id else None

    def mb_b(self):
        if self.addr < self.w:
            return None
        m = self.pic[self.addr - self.w]
        return m if m is not None and m.slice == self.slice_id else None

    def blk_nb(self, idx, left):
        """6.4.11.4: (macroblock, luma4x4BlkIdx) to the left of / above 4x4 block idx;
        (None, None) when not available."""
        x, y = blk_xy(idx)
        if left:
            x -= 1
        else:
            y -= 1
        if x < 0:
            m = self.mb_a()
            x += 16
        elif y < 0:
            m = self.mb_b()
            y += 16
        else:
            m = self.cur
        return (m, xy_blk(x, y)) if m is not None else (None, None)

    def blk8_nb(self, idx, left):
        """6.4.11.2: neighbouring 8x8 block."""
        x, y = (idx & 1) * 8, (idx >> 1) * 8
        if left:
            x -= 1
        else:
            y -= 1
        if x < 0:
            m = self.mb_a()
            x += 16
        elif y < 0:
            m = self.mb_b()
            y += 16
        else:
            m = self.cur
        return (m, 2 * (y >> 3) + (x >> 3)) if m is not None else (None, None)

    def cblk_nb(self, idx, left):
        """6.4.11.5 for 4:2:0: neighbouring 4x4 chroma block."""
        x, y = (idx & 1) * 4, (idx >> 1) * 4
        if left:
            x -= 1
        else:
            y -= 1
        if x < 0:
            m = self.mb_a()
            x += 8
        elif y < 0:
            m = self.mb_b()
            y += 8
        else:
            m = self.cur
        return (m, 2 * (y >> 2) + (x >> 2)) if m is not None else (None, None)

    # ---- the slice (7.3.4)

    def run(self):
        h = self.h
        self.cab.init_contexts(h.qp, "I" if h.slice_type == I else h.cabac_init_idc)
        self.cab.init_engine()
        self.addr = h.first_mb
        n_mbs = self.w * self.hgt
        while True:
            if self.addr >= n_mbs:
                raise FeError("slice runs past the picture (mb %d of %d)" % (self.addr, n_mbs))
            self.cur = Mb(self.slice_id)
            self.pic[self.addr] = self.cur
            self.rec.append("M %d" % self.addr)
            skip = 0
            if h.slice_type != I:
                skip = self.cab.decode(11 + self.inc_skip() if h.slice_type == P else 24 + self.inc_skip())
                self.se("mb_skip_flag", skip)
            if skip:
                self.cur.skip = 1
                self.cur.mb_type = None
            else:
                self.macroblock_layer()
            eos = self.cab.terminate()
            self.se("end_of_slice_flag", eos)
            self.prev = self.cur
            self.addr += 1
            if eos:
                break
        return self.addr

    def se(self, name, v):
        self.rec.append("E %s %d" % (name, v))

    # ---- 9.3.3.1.1.1
    def inc_skip(self):
        inc = 0
        for m in (self.mb_a(), self.mb_b()):
            if m is not None and not m.skip:
                inc += 1
        return inc

    # ---- 7.3.5
    def macroblock_layer(self):
        h, cur = self.h, self.cur
        st = h.slice_type
        mb_type = self.decode_mb_type()
        cur.mb_type = mb_type
        self.se("mb_type", mb_type)
        base = {I: 0, P: 5, B: 23}[st]
        it = mb_type - base                          # the I-slice mb_type of an intra MB, else < 0
        if it >= 0:
            cur.intra = 1
            if it == I_PCM_IDX:
                cur.pcm = 1
                self.pcm_samples()
                return
            if it == I_NXN:
                if self.pps.transform_8x8_mode:
                    cur.t8 = self.decode_t8()
                    self.se("transform_size_8x8_flag", cur.t8)
                n = 4 if cur.t8 else 16                  # Intra_8x8 / Intra_4x4 (7.3.5.1)
                sz = "8x8" if cur.t8 else "4x4"
                for _blk in range(n):
                    if self.cab.decode(68):
                        self.se("prev_intra%s_pred_mode_flag" % sz, 1)
                    else:
                        self.se("prev_intra%s_pred_mode_flag" % sz, 0)
                        self.se("rem_intra%s_pred_mode" % sz, self.cab.decode_fixed(69, 3))
            else:
                cur.i16 = 1
                t = it - 1
                cur.cbp = (15 if t >= 12 else 0) | (((t % 12) // 4) << 4)
            cur.chroma_mode = self.decode_chroma_pred_mode()
            self.se("intra_chroma_pred_mode", cur.chroma_mode)
        elif st == B and mb_type == B_DIRECT_16X16:
            cur.direct16 = 1
        no_sub_lt8 = 1                                   # noSubMbPartSizeLessThan8x8Flag
        if (st == P and mb_type == P_8X8) or (st == B and mb_type == B_8X8):
            no_sub_lt8 = self.sub_mb_pred(st)
        elif not cur.intra and not cur.direct16:
            self.mb_pred(st, mb_type)
        if not cur.i16:
            cur.cbp = self.decode_cbp()
            self.se("coded_block_pattern", cur.cbp)
            # 7.3.5: the second place transform_size_8x8_flag can be (inter macroblocks)
            if (cur.cbp & 15) and self.pps.transform_8x8_mode and not cur.intra and no_sub_lt8 \
                    and (not cur.direct16 or self.sps.direct_8x8_inference):
                cur.t8 = self.decode_t8()
                self.se("transform_size_8x8_flag", cur.t8)
        if cur.cbp or cur.i16:
            cur.qp_delta = self.decode_qp_delta()
            self.se("mb_qp_delta", cur.qp_delta)
            self.residual()

    # ---- mb_type (9.3.2.5, Tables 9-36/9-37, ctxIdx per Table 9-39 + 9.3.3.1.2)

    def decode_mb_type(self):
        st = self.h.slice_type
        cab = self.cab
        if st == I:
            return self.decode_mb_type_i(3, self.inc_mb_type_i())
        if st == P:
            if cab.decode(14) == 0:
                b1 = cab.decode(15)
                if b1 == 0:
                    return 3 if cab.decode(16) else 0           # 0 0 1 = P_8x8, 0 0 0 = P_L0_16x16
                return 1 if cab.decode(17) else 2               # 0 1 1 = 16x8, 0 1 0 = 8x16
            return 5 + self.decode_mb_type_i(17, 0)             # prefix 1: intra, suffix offset 17
        # B
        inc = self.inc_mb_type_b()
        if cab.decode(27 + inc) == 0:
            return 0                                            # B_Direct_16x16
        if cab.decode(27 + 3) == 0:
            return 1 + cab.decode(27 + 5)                       # 1 0 x: b2 uses inc 5 when b1 == 0
        bits = cab.decode(27 + 4) << 3                          # b2 uses inc 4 when b1 != 0
        bits |= cab.decode(27 + 5) << 2
        bits |= cab.decode(27 + 5) << 1
        bits |= cab.decode(27 + 5)
        if bits < 8:
            return bits + 3                                     # 1 1 0 b3 b4 b5
        if bits == 13:
            return 23 + self.decode_mb_type_i(32, 0)            # 1 1 1 1 0 1: intra prefix, suffix offset 32
        if bits == 14:
            return 11                                           # 1 1 1 1 1 0
        if bits == 15:
            return 22                                           # 1 1 1 1 1 1: B_8x8
        bits = (bits << 1) | cab.decode(27 + 5)                 # 1 1 1 0 b3 b4 b5 b6 / 1 1 1 1 0 0 b6
        return bits - 4

    def decode_mb_type_i(self, off, inc0):
        """The I-slice binarisation (Table 9-36) at ctxIdxOffset off (3, 17 or 32):
        bin 0 at off + inc0; bin 1 the terminate bin (I_PCM); then luma AC, chroma
        (TU cMax 2), and the two prediction-mode bins, with the ctxIdxInc of Table 9-39
        (offset 3: 3, 4, 5/6, 6/7, 7; offsets 17/32: 1, 2, 2/3, 3, 3)."""
        cab = self.cab
        if cab.decode(off + inc0) == 0:
            return I_NXN
        if cab.terminate():
            return I_PCM_IDX
        if off == 3:
            c = (3, 4, 5, 6, 7)          # b2, b3, b4 (b3 != 0), b5 (b3 != 0) / b4 (b3 == 0), b5 (b3 == 0)
        else:
            c = (1, 2, 2, 3, 3)
        ac = cab.decode(off + c[0])
        chroma = 0
        if cab.decode(off + c[1]):
            chroma = 2 if cab.decode(off + c[2]) else 1
            p = (cab.decode(off + c[3]) << 1) | cab.decode(off + c[4])
        else:
            p = (cab.decode(off + c[3]) << 1) | cab.decode(off + c[4])
        return 1 + p + 4 * chroma + 12 * ac

    def inc_mb_type_i(self):
        """9.3.3.1.1.3, ctxIdxOffset 3: a neighbour that is I_NxN gives 0."""
        inc = 0
        for m in (self.mb_a(), self.mb_b()):
            if m is not None and not (m.intra and m.mb_type is not None and self.i_type(m) == I_NXN):
                inc += 1
        return inc

    def inc_mb_type_b(self):
        """9.3.3.1.1.3, ctxIdxOffset 27: B_Skip / B_Direct_16x16 neighbours give 0."""
        inc = 0
        for m in (self.mb_a(), self.mb_b()):
            if m is not None and not m.skip and not m.direct16:
                inc += 1
        return inc

    def i_type(self, m):
        return m.mb_type - {I: 0, P: 5, B: 23}[self.h.slice_type]

    # ---- transform_size_8x8_flag (9.3.3.1.1.10; ctxIdx 399 + A + B)
    def decode_t8(self):
        inc = 0
        for m in (self.mb_a(), self.mb_b()):
            if m is not None and m.t8:
                inc += 1
        return self.cab.decode(399 + inc)

    # ---- intra_chroma_pred_mode (9.3.3.1.1.8; TU cMax 3, bins 1-2 at inc 3)
    def decode_chroma_pred_mode(self):
        inc = 0
        for m in (self.mb_a(), self.mb_b()):
            if m is not None and m.intra and not m.pcm and m.chroma_mode != 0:
                inc += 1
        return self.cab.decode_unary(lambda b: 64 + (inc if b == 0 else 3), 3)

    # ---- mb_pred / sub_mb_pred (7.3.5.1 / 7.3.5.2)

    def mb_pred(self, st, mb_type):
        cur = self.cur
        if st == P:
            shape = ("16x16", "16x8", "8x16")[mb_type]
            preds = [L0] * len(PART_BLKS[shape])
        else:
            if mb_type <= 3:
                shape, preds = "16x16", [mb_type]          # 1 L0, 2 L1, 3 Bi
            else:
                k = mb_type - 4
                shape = "16x8" if k % 2 == 0 else "8x16"
                preds = list(B_PAIR_PRED[k // 2])
        parts = PART_BLKS[shape]
        for p, blks in zip(preds, parts):
            for lx in range(2):
                if p & (1 << lx):
                    for b in blks:
                        cur.pred[lx][b] = 1
        for lx in range(2):
            for pi, blks in enumerate(parts):
                if preds[pi] & (1 << lx):
                    r = 0
                    if self.h.num_ref_idx[lx] > 1:
                        r = self.decode_ref_idx(lx, blks[0])
                        self.se("ref_idx_l%d" % lx, r)
                    for b in blks:
                        cur.ref[lx][b] = r
        for lx in range(2):
            for pi, blks in enumerate(parts):
                if preds[pi] & (1 << lx):
                    self.decode_mvd_pair(lx, blks)

    def sub_mb_pred(self, st):
        cur = self.cur
        tab = P_SUB if st == P else B_SUB
        subs = []
        no_sub_lt8 = 1
        for b8 in range(4):
            t = self.decode_sub_mb_type(st)
            self.se("sub_mb_type", t)
            subs.append(tab[t])
            pred, n_sub, shape = tab[t]
            if pred == DIRECT:
                cur.sub_direct[b8] = 1
                if not self.sps.direct_8x8_inference:
                    no_sub_lt8 = 0
            elif n_sub > 1:
                no_sub_lt8 = 0
            for lx in range(2):
                if pred & (1 << lx):
                    for b in range(4):
                        cur.pred[lx][4 * b8 + b] = 1
        for lx in range(2):
            for b8, (pred, _n, shape) in enumerate(subs):
                if pred != DIRECT and pred & (1 << lx):
                    r = 0
                    if self.h.num_ref_idx[lx] > 1:
                        r = self.decode_ref_idx(lx, 4 * b8)
                        self.se("ref_idx_l%d" % lx, r)
                    for b in range(4):
                        cur.ref[lx][4 * b8 + b] = r
        for lx in range(2):
            for b8, (pred, _n, shape) in enumerate(subs):
                if pred != DIRECT and pred & (1 << lx):
                    for sub in SUB_BLKS[shape]:
                        self.decode_mvd_pair(lx, [4 * b8 + b for b in sub])
        return no_sub_lt8

    def decode_sub_mb_type(self, st):
        cab = self.cab
        if st == P:
            if cab.decode(21):
                return 0
            if cab.decode(22) == 0:
                return 1
            return 2 if cab.decode(23) else 3
        if cab.decode(36) == 0:
            return 0
        if cab.decode(37) == 0:
            return 1 + cab.decode(39)                          # b2 at inc 3 when b1 == 0
        if cab.decode(38):                                     # b2 at inc 2 when b1 != 0
            if cab.decode(39):
                return 11 + cab.decode(39)
            return 7 + (cab.decode(39) << 1) + cab.decode(39)
        return 3 + (cab.decode(39) << 1) + cab.decode(39)

    # ---- ref_idx (9.3.3.1.1.6; U binarisation, bins: inc, 4, 5, 5...)
    def decode_ref_idx(self, lx, blk):
        inc = 0
        for left, w in ((True, 1), (False, 2)):
            m, nb = self.blk_nb(blk, left)
            if m is None or m.skip or m.intra or m.direct16:
                continue
            if m.sub_direct[nb >> 2] or not m.pred[lx][nb]:      # predModeEqualFlag 0
                continue
            if m.ref[lx][nb] > 0:                                # refIdxZeroFlag 0
                inc += w
        return self.cab.decode_unary(lambda b: 54 + (inc if b == 0 else 4 if b == 1 else 5))

    # ---- mvd (9.3.3.1.1.7; UEG3, uCoff 9, signed; bins: inc, 3, 4, 5, 6, 6...)
    def decode_mvd_pair(self, lx, blks):
        cur = self.cur
        first = blks[0]
        out = []
        for comp in range(2):
            s = 0
            for left in (True, False):
                m, nb = self.blk_nb(first, left)
                if m is None or m.skip or m.intra or m.direct16:
                    continue
                if m.sub_direct[nb >> 2] or not m.pred[lx][nb]:
                    continue
                s += abs(m.mvd[lx][nb][comp])
            inc = 2 if s > 32 else 1 if s > 2 else 0
            off = 40 if comp == 0 else 47
            v = self.cab.decode_ueg(lambda b, inc=inc, off=off: off + (inc if b == 0 else min(b + 2, 6)), 9, 3, True)
            self.se("mvd_l%d" % lx, v)
            out.append(v)
            # the x component is stored before y is derived: the neighbour lookup for y
            # reads the same partition's x only through other blocks, never this one
        for b in blks:
            cur.mvd[lx][b] = (out[0], out[1])

    # ---- coded_block_pattern (9.3.3.1.1.4; prefix FL 4 bins at 73, suffix TU cMax 2 at 77)
    def decode_cbp(self):
        cur = self.cur
        luma = 0
        for b8 in range(4):
            inc = 0
            for left, w in ((True, 1), (False, 2)):
                m, nb = self.blk8_nb(b8, left)
                if m is None or m.pcm:
                    continue
                if m is cur:
                    if (luma >> nb) & 1:
                        continue
                elif not m.skip and (m.cbp >> nb) & 1:
                    continue
                inc += w
            luma |= self.cab.decode(73 + inc) << b8
        chroma = 0
        a, b = self.mb_a(), self.mb_b()

        def term(m, bin_idx):
            if m is None:
                return 0
            if m.pcm:
                return 1
            if m.skip:
                return 0
            c = m.cbp >> 4
            return 1 if (c != 0 if bin_idx == 0 else c == 2) else 0
        if self.cab.decode(77 + term(a, 0) + 2 * term(b, 0)):
            chroma = 2 if self.cab.decode(77 + 4 + term(a, 1) + 2 * term(b, 1)) else 1
        return luma | (chroma << 4)

    # ---- mb_qp_delta (9.3.3.1.1.5; U of the Table 9-3 mapping, bins: inc, 2, 3, 3...)
    def decode_qp_delta(self):
        p = self.prev
        inc = 0
        if p is not None and p.slice == self.slice_id and not p.skip and not p.pcm \
                and (p.i16 or p.cbp) and p.qp_delta != 0:
            inc = 1
        k = self.cab.decode_unary(lambda b: 60 + (inc if b == 0 else 2 if b == 1 else 3))
        return (k + 1) >> 1 if k & 1 else -(k >> 1)

    # ---- residual (7.3.5.3, 7.3.5.3.1; 4:2:0)
    def residual(self):
        cur = self.cur
        if cur.i16:
            cur.cbf_dc, c = self.residual_block(0, 16, self.inc_cbf_dc())
            self.block("LDC", 0, c)
        for b8 in range(4):
            if cur.t8:
                if (cur.cbp >> b8) & 1:
                    # ctxBlockCat 5: no coded_block_flag in 4:2:0 (7.3.5.3.3), inferred 1
                    # (7.4.5.3.3); a later 4x4 block's cbf context sees the 8x8 block
                    # (9.3.3.1.1.9: transBlockN is the 8x8 block when the neighbour MB
                    # has transform_size_8x8_flag 1) -- its flag, 1, in each 4x4 slot
                    _cbf, c = self.residual_block(5, 64, None)
                    for b in range(4):
                        cur.cbf_luma[4 * b8 + b] = 1
                    self.block("L8", b8, c)
                continue
            for b in range(4):
                idx = 4 * b8 + b
                if (cur.cbp >> b8) & 1:
                    cat, n = (1, 15) if cur.i16 else (2, 16)
                    cur.cbf_luma[idx], c = self.residual_block(cat, n, self.inc_cbf_luma(idx))
                    self.block("L4", idx, c)
        chroma = cur.cbp >> 4
        if chroma:
            for icc in range(2):
                cur.cbf_cdc[icc], c = self.residual_block(3, 4, self.inc_cbf_cdc(icc))
                self.block("CDC", icc, c)
        if chroma == 2:
            for icc in range(2):
                for b in range(4):
                    cur.cbf_cac[icc][b], c = self.residual_block(4, 15, self.inc_cbf_cac(icc, b))
                    self.block("CAC", 4 * icc + b, c)

    def block(self, kind, idx, c):
        self.rec.append("B %s %d %d %s" % (kind, idx, len(c), " ".join(str(v) for v in c)))

    # 9.3.3.1.1.9 condTermFlag, given the neighbour's transBlock cbf (or None when n/a)
    def cbf_term(self, m, tb):
        if m is None:
            return 1 if self.cur.intra else 0
        if m.pcm:
            return 1
        if tb is None:
            return 0
        return tb

    def inc_cbf_dc(self):
        inc = 0
        for left, w in ((True, 1), (False, 2)):
            m = self.mb_a() if left else self.mb_b()
            inc += w * self.cbf_term(m, m.cbf_dc if m is not None and m.i16 else None)
        return inc

    def inc_cbf_luma(self, idx):
        inc = 0
        for left, w in ((True, 1), (False, 2)):
            m, nb = self.blk_nb(idx, left)
            tb = None
            if m is not None and not m.skip and not m.pcm and (m.cbp >> (nb >> 2)) & 1:
                tb = m.cbf_luma[nb]
            inc += w * self.cbf_term(m, tb)
        return inc

    def inc_cbf_cdc(self, icc):
        inc = 0
        for left, w in ((True, 1), (False, 2)):
            m = self.mb_a() if left else self.mb_b()
            tb = None
            if m is not None and not m.skip and not m.pcm and (m.cbp >> 4):
                tb = m.cbf_cdc[icc]
            inc += w * self.cbf_term(m, tb)
        return inc

    def inc_cbf_cac(self, icc, idx):
        inc = 0
        for left, w in ((True, 1), (False, 2)):
            m, nb = self.cblk_nb(idx, left)
            tb = None
            if m is not None and not m.skip and not m.pcm and (m.cbp >> 4) == 2:
                tb = m.cbf_cac[icc][nb]
            inc += w * self.cbf_term(m, tb)
        return inc

    # 7.3.5.3.3 residual_block_cabac + 9.3.3.1.3
    CAT_OFF_CBF = (0, 4, 8, 12, 16)
    CAT_OFF_SIG = (0, 15, 29, 44, 47)
    CAT_OFF_ABS = (0, 10, 20, 30, 39)

    def residual_block(self, cat, n, inc_cbf):
        cab = self.cab
        coeffs = [0] * n
        if cat != 5:
            cbf = cab.decode(85 + self.CAT_OFF_CBF[cat] + inc_cbf)
            if not cbf:
                return 0, coeffs
        if cat == 5:                                         # Table 9-34 / 9-43
            sig_off, last_off = (436, 451) if self.field else (402, 417)
            sig_map = HT.SIG8_FIELD if self.field else HT.SIG8_FRAME
        else:
            sig_off = (277 if self.field else 105) + self.CAT_OFF_SIG[cat]
            last_off = (338 if self.field else 166) + self.CAT_OFF_SIG[cat]
        sig = []
        num = n
        i = 0
        while i < num - 1:
            if cat == 5:
                inc_s, inc_l = sig_map[i], HT.LAST8[i]
            else:
                inc_s = inc_l = min(i, 2) if cat == 3 else i  # NumC8x8 = 1 for 4:2:0
            if cab.decode(sig_off + inc_s):
                sig.append(i)
                if cab.decode(last_off + inc_l):
                    num = i + 1
            i += 1
        if num == n:
            sig.append(n - 1)                                # the last position, significant by inference
        abs_off = 426 if cat == 5 else 227 + self.CAT_OFF_ABS[cat]
        eq1 = gt1 = 0
        for pos in reversed(sig):
            inc0 = 0 if gt1 else min(4, 1 + eq1)
            incn = 5 + min(4 - (1 if cat == 3 else 0), gt1)
            a = cab.decode_ueg(lambda b, inc0=inc0, incn=incn: abs_off + (inc0 if b == 0 else incn), 14, 0, False)
            if cab.bypass():
                coeffs[pos] = -(a + 1)
            else:
                coeffs[pos] = a + 1
            if a == 0:
                eq1 += 1
            else:
                gt1 += 1
        return 1, coeffs

    # ---- I_PCM (7.3.5, 9.3.1.2)
    def pcm_samples(self):
        br = self.br
        br.byte_align()                                     # pcm_alignment_zero_bit
        samples = [br.read_bits(8) for _ in range(256 + 2 * 64)]
        self.rec.append("B PCM 0 %d %s" % (len(samples), " ".join(str(v) for v in samples)))
        self.cab.init_engine()


# ---------------------------------------------------------------- the stream

# ---------------------------------------------------------------- SEI pic_timing, PTS (P5c)

PT_BYTES = 9    # the pic_timing payload bytes kept: pic_struct ends by bit 32 + 32 + 4 = 68


def sei_pic_timing(rbsp):
    """sei_rbsp() (7.3.2.3.1, D.1), as h264/dec/sei_pt.sv walks it. Returns (touched,
    pt, malformed): touched = a pic_timing message started in this unit (it REPLACES the
    pending one, even if it is then cut); pt = (its first PT_BYTES payload bytes, its
    payloadSize) when it completed, else None; malformed = the walk ended on a type or
    size cut by the unit's end, a payload running into the unit's last byte, or a last
    byte at a message boundary that is not 0x80 (rbsp_trailing_bits). Byte level:
    payloadType / payloadSize are 0xFF runs plus a last byte."""
    i, n = 0, len(rbsp)
    touched, pt = False, None
    while True:
        if i >= n:
            return touched, pt, True                # (an empty unit: no trailing byte)
        if i == n - 1:
            return touched, pt, rbsp[i] != 0x80     # at a message boundary: the trailing byte
        ptype = 0
        while rbsp[i] == 0xFF and i < n - 1:
            ptype += 255
            i += 1
        if i == n - 1:
            return touched, pt, True                # a type cut by the end
        ptype += rbsp[i]
        i += 1
        psize = 0
        while i < n - 1 and rbsp[i] == 0xFF:
            psize += 255
            i += 1
        if i == n - 1:
            if ptype == 1:
                touched, pt = True, None
            return touched, pt, True                # a size cut by the end
        psize += rbsp[i]
        i += 1
        if ptype == 1:
            touched, pt = True, None
        if i + psize > n - 1:
            return touched, pt, True                # the payload runs into the last byte
        if ptype == 1:
            pt = (bytes(rbsp[i:i + min(psize, PT_BYTES)]), psize)
        i += psize


def interpret_pic_timing(pt, sps, field_pic, bottom, rec, cnt):
    """D.1.3 up to pic_struct, with the SPS the picture's first slice activates (D.2.3
    NOTE 1: the SEI precedes that slice). The clock timestamps after pic_struct are not
    read: nothing downstream uses them. Checked UP FRONT: a payload shorter than the
    delays + pic_struct the SPS makes present records nothing (`pt_short`; the display
    infers pic_struct). With neither CpbDpbDelaysPresentFlag nor pic_struct_present_flag
    no picture timing SEI may be present (D.2.3): dropped, `pt_struct`. pic_struct is
    recorded, then checked against Table D-1 (reserved 9..15; field_pic_flag /
    bottom_field_flag): a mismatch counts `pt_struct` (the reconstruction's display
    side decides what to show)."""
    data, psize = pt
    cpb = sps.cpb_dpb_delays_present
    psp = sps.pic_struct_present
    if not cpb and not psp:
        cnt["pt_struct"] += 1
        return
    need = ((sps.cpb_removal_delay_length_minus1 + sps.dpb_output_delay_length_minus1 + 2) if cpb else 0) + \
           (4 if psp else 0)
    if need > 8 * min(psize, PT_BYTES):
        cnt["pt_short"] += 1
        return
    br = BitReader(bytes(data) + b"\x00")
    if cpb:
        rec.append("S cpb_removal_delay %d" % br.read_bits(sps.cpb_removal_delay_length_minus1 + 1))
        rec.append("S dpb_output_delay %d" % br.read_bits(sps.dpb_output_delay_length_minus1 + 1))
    if psp:
        ps = br.read_bits(4)
        rec.append("S pic_struct %d" % ps)
        ok = ((ps == 0 and not field_pic) or (ps == 1 and field_pic and not bottom) or
              (ps == 2 and field_pic and bottom) or (3 <= ps <= 8 and not field_pic))
        if not ok:
            cnt["pt_struct"] += 1


AU_OPENERS = (6, 7, 8, 9, 14, 15, 16, 17, 18)   # 7.4.1.2.3: after a VCL NAL, the next AU


def decode_stream(data, stats=None, slices=None, fabric_max_mbs=None, marks=None, rec=None,
                  resolved_scaling=False):
    """Annex-B bytes -> canonical records (h264_trace_ref.py's format). With `slices` a
    list, one dict per slice is appended: the slice-data bytes from the CABAC start
    (byte aligned, emulation prevention removed), the header fields the macroblock
    layer needs, and the slice's own records -- the fixture for mb_syntax_tb.

    P5c. A picture timing SEI (the last complete one since its access unit opened) is
    interpreted at the picture's first slice (first_mb_in_slice 0) with that slice's SPS
    and its fields recorded after the slice header's. `marks` = [(offset in data, PTS)],
    one per PES that carried a PTS, at its first payload byte: the PTS belongs to the
    first access unit that COMMENCES at or after it (ISO/IEC 13818-1 2.4.3.7). An access
    unit commences at its first NAL unit's 3-byte start code; its first NAL (7.4.1.2.3)
    is a NAL of AU_OPENERS after the last VCL NAL, else the picture's first slice. Every
    mark at or before that start is taken; the LATEST is the tag (au_pts_lo = bits
    31..0, au_pts_hi = bit 32, after the SEI fields); earlier ones are counted as
    `pts_drops` (a PES with no access unit starting in it). h264/dec/au_pts.sv.
    Counters in `stats`: pt_seen, pt_missing, pt_short, pt_struct, pts_tagged, pts_drops,
    sei_malformed -- h264/dec/h264_top.sv's, the HUD's.
    With `rec` given, records are appended to it (so they survive an exception).
    With `resolved_scaling`, each slice header is followed by the resolved scaling matrix
    as the RTL emits it (scaling_words(), before the picture-timing records) -- the
    goldens of h264_top and recon_top; the canonical stream (JM's) does not have them."""
    rec = [] if rec is None else rec
    sps_map, pps_map = {}, {}
    pic = None
    slice_id = 0
    bins = 0
    marks = sorted(marks or [])
    mi = 0
    au_pos = None               # the pending access unit's start (its first start code)
    vcl_last = True             # the previous NAL was VCL: an opener starts an access unit
    pt = None                   # the pending picture timing payload
    cnt = {"pt_seen": 0, "pt_missing": 0, "pt_short": 0, "pt_struct": 0, "pts_tagged": 0, "pts_drops": 0,
           "sei_malformed": 0}
    for pos, ref_idc, ntype, rbsp in nal_units_pos(data):
        rec.append("N %d %d" % (ntype, ref_idc))
        if ntype in AU_OPENERS and vcl_last:
            au_pos = pos - 3
            vcl_last = False
            pt = None                               # a new access unit: nothing carries over
        if ntype == 6:
            touched, got, bad = sei_pic_timing(rbsp)
            if touched:
                pt = got
            if bad:
                cnt["sei_malformed"] += 1
        if ntype == 7:
            s = parse_sps(rbsp, rec, fabric_max_mbs)
            sps_map[s.id] = s
        elif ntype == 8:
            p = parse_pps(rbsp, sps_map, rec)
            pps_map[p.id] = p
        elif ntype in (1, 5):
            br = BitReader(rbsp)
            h = parse_slice_header(br, ntype, ref_idc, sps_map, pps_map, rec)
            if resolved_scaling:
                for name, v in scaling_words(h.sps, h.pps):
                    rec.append("S %s %d" % (name, v))
            if h.first_mb == 0:
                if vcl_last or au_pos is None:
                    au_pos = pos - 3                # no opener since the last VCL NAL
                    pt = None
                if pt is not None:
                    cnt["pt_seen"] += 1
                    interpret_pic_timing(pt, h.sps, h.field_pic, h.bottom_field, rec, cnt)
                elif h.sps.pic_struct_present or h.sps.cpb_dpb_delays_present:
                    cnt["pt_missing"] += 1          # D.2.3: one per access unit
                pt = None
                tag, n_taken = None, 0
                while mi < len(marks) and marks[mi][0] <= au_pos:
                    tag = marks[mi][1]
                    mi += 1
                    n_taken += 1
                if tag is not None:
                    rec.append("S au_pts_lo %d" % (tag & 0xFFFFFFFF))
                    rec.append("S au_pts_hi %d" % ((tag >> 32) & 1))
                    cnt["pts_tagged"] += 1
                    cnt["pts_drops"] += n_taken - 1
            vcl_last = True
            n_mbs = h.sps.width_mbs * (h.sps.frame_height_mbs // (2 if h.field_pic else 1))
            if h.first_mb == 0 or pic is None or len(pic) != n_mbs:
                pic = [None] * n_mbs
            slice_id += 1
            rec_start = len(rec)
            sd = SliceDecoder(h, rbsp, br.pos, pic, slice_id, rec)
            last_addr = sd.run()
            bins += sd.cab.bins
            if slices is not None:
                slices.append({
                    "data": rbsp[br.pos // 8:], "slice_type": h.slice_type, "first_mb": h.first_mb,
                    "num_ref_idx": list(h.num_ref_idx), "field_pic": h.field_pic,
                    "width_mbs": h.sps.width_mbs, "height_mbs": sd.hgt, "qp": h.qp,
                    "cabac_init_idc": h.cabac_init_idc, "slice_id": slice_id, "n_mbs": last_addr - h.first_mb,
                    "records": rec[rec_start:], "bins": sd.cab.bins,
                    "t8_mode": h.pps.transform_8x8_mode, "d8inf": h.sps.direct_8x8_inference})
        elif ntype in (2, 3, 4):
            raise Refused("nal_unit_type %d (data partitioning)" % ntype)
        elif ntype in (14, 20):
            raise Refused("nal_unit_type %d (SVC/MVC)" % ntype)
    if stats is not None:
        stats["bins"] = bins
        stats.update(cnt)
    return rec


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stream")
    ap.add_argument("-o", "--out")
    ap.add_argument("--stats", action="store_true")
    a = ap.parse_args(argv)
    stats = {}
    rec = decode_stream(open(a.stream, "rb").read(), stats)
    if a.out:
        with open(a.out, "w") as f:
            f.write("\n".join(rec) + "\n")
    else:
        sys.stdout.write("\n".join(rec) + "\n")
    if a.stats:
        print("%d records, %d bins" % (len(rec), stats["bins"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Refused, FeError, CabacError) as e:
        sys.exit("h264_fe_ref: %s: %s" % (type(e).__name__, e))
