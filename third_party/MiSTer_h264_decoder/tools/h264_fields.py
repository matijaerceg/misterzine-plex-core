#!/usr/bin/env python3
"""The header-field ids of the front end's syntax-element stream (docs/h264_frontend.md
S5): every SPS / PPS / slice-header field tools/h264_fe_ref.py records as `S <name> <v>`
gets one 8-bit id, shared by the golden (tools/h264_top_golden.py) and the RTL
(h264/dec/h264_fields.svh, rendered from this table -- never hand-typed).

The `_l0` / `_l1` pairs are adjacent (l1 = l0 + 1) so the RTL indexes them with the
list number. `--check` compares the .svh in the tree with what this table renders.

    h264_fields.py --render > h264/dec/h264_fields.svh
    h264_fields.py --check
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SVH = os.path.join(HERE, "..", "h264", "dec", "h264_fields.svh")

# the SE word kinds of the top-level stream: 1..16 are mb_syntax's (tools/mb_syntax_golden.py)
K_NAL = 17          # aux = nal_unit_type, val = nal_ref_idc
K_HDR = 18          # aux = field id (below), val = the field's value (32-bit two's complement)
K_EOS = 19          # end of stream (P5c): after the last NAL unit's words, once per flush;
                    # aux = 0, val = 0. In-band, so it cannot overtake the words before it.

FIELDS = [
    # SPS
    "profile_idc", "constraint_set0_flag", "constraint_set1_flag", "constraint_set2_flag", "level_idc",
    "seq_parameter_set_id", "chroma_format_idc", "bit_depth_luma_minus8", "bit_depth_chroma_minus8",
    "lossless_qpprime_y_zero_flag", "seq_scaling_matrix_present_flag", "log2_max_frame_num_minus4",
    "pic_order_cnt_type", "log2_max_pic_order_cnt_lsb_minus4", "delta_pic_order_always_zero_flag",
    "offset_for_non_ref_pic", "offset_for_top_to_bottom_field", "num_ref_frames_in_pic_order_cnt_cycle",
    "offset_for_ref_frame[i]", "num_ref_frames", "gaps_in_frame_num_value_allowed_flag",
    "pic_width_in_mbs_minus1", "pic_height_in_map_units_minus1", "frame_mbs_only_flag",
    "mb_adaptive_frame_field_flag", "direct_8x8_inference_flag", "frame_cropping_flag",
    "frame_crop_left_offset", "frame_crop_right_offset", "frame_crop_top_offset", "frame_crop_bottom_offset",
    "vui_parameters_present_flag",
    # PPS
    "pic_parameter_set_id", "entropy_coding_mode_flag", "bottom_field_pic_order_in_frame_present_flag",
    "num_slice_groups_minus1", "num_ref_idx_l0_default_active_minus1", "num_ref_idx_l1_default_active_minus1",
    "weighted_pred_flag", "weighted_bipred_idc", "pic_init_qp_minus26", "pic_init_qs_minus26",
    "chroma_qp_index_offset", "deblocking_filter_control_present_flag", "constrained_intra_pred_flag",
    "redundant_pic_cnt_present_flag", "transform_8x8_mode_flag", "pic_scaling_matrix_present_flag",
    "second_chroma_qp_index_offset",
    # slice header
    "first_mb_in_slice", "slice_type", "frame_num", "field_pic_flag", "bottom_field_flag", "idr_pic_id",
    "pic_order_cnt_lsb", "delta_pic_order_cnt_bottom", "delta_pic_order_cnt[0]", "delta_pic_order_cnt[1]",
    "redundant_pic_cnt", "direct_spatial_mv_pred_flag", "num_ref_idx_active_override_flag",
    "num_ref_idx_l0_active_minus1", "num_ref_idx_l1_active_minus1",
    "ref_pic_list_modification_flag_l0", "ref_pic_list_modification_flag_l1",
    "modification_of_pic_nums_idc_l0", "modification_of_pic_nums_idc_l1",
    "abs_diff_pic_num_minus1_l0", "abs_diff_pic_num_minus1_l1", "long_term_pic_num_l0", "long_term_pic_num_l1",
    "luma_log2_weight_denom", "chroma_log2_weight_denom",
    "luma_weight_flag_l0", "luma_weight_flag_l1", "luma_weight_l0", "luma_weight_l1",
    "luma_offset_l0", "luma_offset_l1", "chroma_weight_flag_l0", "chroma_weight_flag_l1",
    "chroma_weight_l0", "chroma_weight_l1", "chroma_offset_l0", "chroma_offset_l1",
    "no_output_of_prior_pics_flag", "long_term_reference_flag", "adaptive_ref_pic_marking_mode_flag",
    "memory_management_control_operation", "difference_of_pic_nums_minus1", "long_term_pic_num",
    "long_term_frame_idx", "max_long_term_frame_idx_plus1", "cabac_init_idc", "slice_qp_delta",
    "disable_deblocking_filter_idc", "slice_alpha_c0_offset_div2", "slice_beta_offset_div2",
    # SPS VUI (E.1.1) and its hrd_parameters() (E.1.2), P5 -- appended so the earlier ids stay
    "aspect_ratio_info_present_flag", "aspect_ratio_idc", "sar_width", "sar_height",
    "overscan_info_present_flag", "overscan_appropriate_flag", "video_signal_type_present_flag",
    "video_format", "video_full_range_flag", "colour_description_present_flag", "colour_primaries",
    "transfer_characteristics", "matrix_coefficients", "chroma_loc_info_present_flag",
    "chroma_sample_loc_type_top_field", "chroma_sample_loc_type_bottom_field", "timing_info_present_flag",
    "num_units_in_tick", "time_scale", "fixed_frame_rate_flag", "nal_hrd_parameters_present_flag",
    "cpb_cnt_minus1", "bit_rate_scale", "cpb_size_scale", "bit_rate_value_minus1[i]",
    "cpb_size_value_minus1[i]", "cbr_flag[i]", "initial_cpb_removal_delay_length_minus1",
    "cpb_removal_delay_length_minus1", "dpb_output_delay_length_minus1", "time_offset_length",
    "vcl_hrd_parameters_present_flag", "low_delay_hrd_flag", "pic_struct_present_flag",
    "bitstream_restriction_flag", "motion_vectors_over_pic_boundaries_flag", "max_bytes_per_pic_denom",
    "max_bits_per_mb_denom", "log2_max_mv_length_horizontal", "log2_max_mv_length_vertical",
    "max_num_reorder_frames", "max_dec_frame_buffering",
    # per picture, after its first slice header (P5c): the picture timing SEI (D.1.3) up to
    # pic_struct -- the clock timestamps after it are not read (nothing uses them; the
    # walker skips them by payloadSize) -- then the access unit's PTS, which is not H.264
    # syntax but the stream source's tag (ISO 13818-1 2.4.3.7)
    "cpb_removal_delay", "dpb_output_delay", "pic_struct", "au_pts_lo", "au_pts_hi",
    # H264 Phase 5 (High profile, docs/high_profile.md): the scaling_list() syntax of an SPS
    # / PPS as coded, then, per slice after its header (and before the picture-timing words),
    # the RESOLVED matrix the front end emits: scaling_matrix_flag (0 = every list Flat_16,
    # nothing follows) or 1 and 56 scaling_list_words (lists 0..7, coded order, four
    # weights a word, the first in bits 7..0) -- not H.264 syntax, the resolution of Table 7-2
    "seq_scaling_list_present_flag[i]", "pic_scaling_list_present_flag[i]", "delta_scale",
    "scaling_matrix_flag", "scaling_list_word",
]
FIELD_ID = {name: i + 1 for i, name in enumerate(FIELDS)}
assert len(FIELDS) < 256
for _n in FIELDS:
    if _n.endswith("_l0"):
        assert FIELD_ID[_n[:-1] + "1"] == FIELD_ID[_n] + 1, _n


def sv_name(name):
    return "F_" + name.replace("[", "_").replace("]", "")


def render():
    out = ["// h264/dec/h264_fields.svh -- header-field ids of the front end's SE stream.",
           "// RENDERED by tools/h264_fields.py --render; do not edit (the runner checks it).",
           "localparam [7:0] K_NAL_WORD = 8'd%d;" % K_NAL,
           "localparam [7:0] K_HDR_WORD = 8'd%d;" % K_HDR,
           "localparam [7:0] K_EOS_WORD = 8'd%d;" % K_EOS]
    for name in FIELDS:
        out.append("localparam [7:0] %s = 8'd%d;" % (sv_name(name), FIELD_ID[name]))
    return "\n".join(out) + "\n"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--render"]:
        sys.stdout.write(render())
        return 0
    if argv == ["--check"]:
        have = open(SVH).read() if os.path.exists(SVH) else ""
        if have != render():
            print("h264_fields.svh differs from tools/h264_fields.py (re-render it)")
            return 1
        print("h264_fields.svh matches tools/h264_fields.py (%d fields)" % len(FIELDS))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
