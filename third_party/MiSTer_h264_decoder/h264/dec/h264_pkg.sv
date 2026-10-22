// h264/dec/h264_pkg.sv -- the stored shape of a sequence / picture parameter set
// (h264/dec/sps_pps.sv writes them, slice_hdr.sv and P4 read them). Every field is
// sized for its spec range (7.4.2.1.1 / 7.4.2.2); the two picture dimensions are
// bounded by the fabric (128 macroblocks, mb_syntax's line memory) and a larger SPS
// is refused loudly before it is stored (docs/h264_frontend.md S5). A package (not an
// include) so the port lists can use SPS_W / PPS_W; H264.qsf lists it first.
package h264_pkg;
typedef struct packed {
    logic [7:0]  profile_idc;
    logic [7:0]  level_idc;
    logic [2:0]  constraint_set;                // {set0, set1, set2}
    logic [3:0]  log2_max_frame_num_minus4;     // 0..12
    logic [1:0]  poc_type;                      // 0..2
    logic [3:0]  log2_max_poc_lsb_minus4;       // 0..12
    logic        delta_pic_order_always_zero;
    logic [31:0] offset_for_non_ref_pic;        // POC type 1
    logic [31:0] offset_for_top_to_bottom_field;
    logic [7:0]  num_ref_frames_in_poc_cycle;   // 0..255 (the offsets themselves are not stored: S5)
    logic [4:0]  num_ref_frames;                // 0..16
    logic        gaps_in_frame_num_allowed;
    logic [6:0]  width_mbs_minus1;              // 0..127 (fabric)
    logic [6:0]  height_map_units_minus1;       // 0..127; frame height <= 128 MBs (fabric)
    logic        frame_mbs_only;
    logic        direct_8x8_inference;
    logic        frame_cropping;
    logic [9:0]  crop_left;                     // 0..1023 each (spec: below half the picture)
    logic [9:0]  crop_right;
    logic [9:0]  crop_top;
    logic [9:0]  crop_bottom;
    logic        vui_present;
    // VUI (E.1.1, P5). Absent fields hold their E.2.1 / E.2.2 inferences: the HRD delay
    // lengths 23 / 23 / 24, max_dec_frame_buffering "MaxDpbFrames" (br_present 0).
    // The front end reads the picture-timing lengths; the reconstruction and the display
    // the aspect, the timing and the DPB size.
    logic        pic_struct_present;
    logic        cpb_dpb_delays_present;        // nal_ or vcl_hrd_parameters_present_flag
    logic [4:0]  cpb_removal_delay_length_minus1;
    logic [4:0]  dpb_output_delay_length_minus1;
    logic [4:0]  time_offset_length;
    logic [7:0]  aspect_ratio_idc;              // 0 unspecified, 1..16 Table E-1, 255 Extended_SAR
    logic [15:0] sar_width;                     // Extended_SAR only
    logic [15:0] sar_height;
    logic        timing_present;
    logic [31:0] num_units_in_tick;             // > 0 when present (E.2.1)
    logic [31:0] time_scale;
    logic        bitstream_restriction;
    logic [4:0]  max_dec_frame_buffering;       // 0..16 (A.3.1)
    logic [4:0]  max_num_reorder_frames;        // 0..max_dec_frame_buffering (E.2.1); bitstream_restriction only
    // High profile (H264 Phase 5, docs/high_profile.md): the scaling matrix's presence and,
    // per list i = 0..7, {useDefaultScalingMatrixFlag, seq_scaling_list_present_flag[i]} at
    // [2i+1:2i]; the lists themselves are in sps_pps's list store
    logic        scaling_present;
    logic [15:0] sl_flags;
} sps_t;
// DPB frame stores (docs/h264_recon.md S2.2): MaxDpbFrames is 16 for a picture of 506
// macroblocks or fewer, + the current picture, + the display's two held stores; a store
// index is 5 bits, a reference code {valid, store, parity} 8 bits
localparam int NSTORE = 20;

localparam SPS_W = $bits(sps_t);

typedef struct packed {
    logic [4:0]  sps_id;
    logic        bottom_field_pic_order_present;
    logic [4:0]  num_ref_idx_l0_default_minus1; // 0..31
    logic [4:0]  num_ref_idx_l1_default_minus1;
    logic        weighted_pred;
    logic [1:0]  weighted_bipred_idc;
    logic [5:0]  pic_init_qp_minus26;           // -26..25, two's complement
    logic [5:0]  pic_init_qs_minus26;
    logic [4:0]  chroma_qp_index_offset;        // -12..12
    logic [4:0]  second_chroma_qp_index_offset; // = chroma_qp_index_offset when absent (7.4.2.2)
    logic        deblocking_filter_control_present;
    logic        constrained_intra_pred;
    logic        redundant_pic_cnt_present;
    // High profile: transform_8x8_mode_flag, pic_scaling_matrix_present_flag and the lists'
    // flags as in sps_t (lists 6, 7 only when transform_8x8_mode_flag)
    logic        transform_8x8_mode;
    logic        scaling_present;
    logic [15:0] sl_flags;
} pps_t;
localparam PPS_W = $bits(pps_t);

// refusal codes (a legal feature outside the core's scope) and error codes (a stream
// or state violation); the HUD shows the last of each with its count
// (REF_SCALING and REF_T8X8 are no longer raised: High profile is decoded since Phase 5;
//  the codes stay reserved so a log from an older build still reads the same)
localparam [3:0] REF_NONE = 4'd0, REF_CHROMA = 4'd1, REF_BITDEPTH = 4'd2, REF_SCALING = 4'd3,
                 REF_MBAFF = 4'd4, REF_CAVLC = 4'd5, REF_FMO = 4'd6, REF_T8X8 = 4'd7,
                 REF_REDUNDANT = 4'd8, REF_SPSI = 4'd9, REF_PARTITION = 4'd10, REF_SVC = 4'd11,
                 REF_SIZE = 4'd12;
localparam [3:0] ERR_NONE = 4'd0, ERR_RANGE = 4'd1, ERR_NO_PPS = 4'd2, ERR_NO_SPS = 4'd3,
                 ERR_READER = 4'd4, ERR_MOD_IDC = 4'd5, ERR_ENGINE = 4'd6, ERR_OVERRUN = 4'd7,
                 ERR_EMPTY_NAL = 4'd8, ERR_NAL_HDR = 4'd9;
endpackage
