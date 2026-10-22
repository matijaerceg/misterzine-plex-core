// h264/dec/recon_hdr.sv -- the reconstruction's parameter store and slice-header
// capture, fed from the front end's SE stream (docs/h264_recon.md S2.1)
//
// The front end emits every SPS / PPS / slice-header field as a K_HDR_WORD (aux = the
// field id of tools/h264_fields.py, val = the value) in syntax order, and only the
// fields that are present. This module listens to those words (the router in
// recon_top hands it NAL and HDR words only), keeps its OWN parameter store -- 32 SPS
// and 256 PPS records (h264_pkg's sps_t / pps_t) in RAM, the spec maxima -- and
// assembles the slice header the reconstruction needs: the scalar fields as one
// record, the prediction-weight table, the reference-list modification operations
// and the memory-management operations in small RAMs read by recon_dpb / inter_pred.
//
// Why an own store: a FIFO sits between the front end and the reconstruction, so
// h264_top's live sp_* outputs may already describe the NEXT slice when this one's
// macroblocks are reconstructed. The stream is the whole contract (the model,
// tools/h264_recon_ref.py, parses the same records: parse_*_records).
//
// A parameter set is written to its store when its NAL unit ends (the next NAL word).
// A slice header is complete when the first macroblock word follows it: recon_top
// pulses `hdr_end`; the PPS and its SPS are then read from the stores (two
// synchronous reads) and `slice_ready` presents everything held until the next slice.
//
// 🚩 The POC type 1 offset_for_ref_frame tables (spec: 255 entries x 32 SPS = 27
// M10K) are the recorded deviation of docs/spec_hardening.md: the FULL-length prefix
// sums of the TWO most recently received type-1 SPSs are cached, keyed by id; a slice
// activating a type-1 SPS whose table was evicted raises err_poc1 (a REF code on the
// HUD), never a wrong POC.
//
// H264 Phase 5 (High profile, docs/high_profile.md S3): the slice's RESOLVED scaling
// matrix arrives after its header (scaling_matrix_flag, then 56 scaling_list_words when
// non-flat): the words go straight into two RAMs -- the 4x4 lists (24 words) and the 8x8
// lists (32 words), read by the dequant units through sl4_ra / sl8_ra -- and the flag into
// sh_sflat at activation. Writing the active RAMs directly is safe: recon_top holds every
// NAL word until the macroblock pipeline is idle, so no macroblock of the previous slice
// reads them while this slice's words arrive.
//
// Bounds (all visible): weights 2 x 32 entries (num_ref_idx <= 32, 7.4.3), list
// modifications 2 x 33 (at most num_ref_idx_active + 1 operations before idc 3,
// 7.4.3.1), MMCO operations 64 (the spec puts no bound on the count; a 65th sets
// err_mmco_ovf and is dropped -- a conforming stream references at most the 16
// pictures a DPB holds).

`default_nettype none

module recon_hdr
    import h264_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,             // a new title: forget every parameter set

    // the routed SE words (NAL and HDR kinds only), one per cycle
    input  wire         se_valid,
    input  wire  [7:0]  se_kind,
    input  wire  [7:0]  se_aux,
    input  wire  [31:0] se_val,
    input  wire         hdr_end,           // the slice header is complete (first MB word seen)

    // the slice, held from slice_ready to the next one
    output logic        slice_ready,       // one pulse per slice header, two cycles after hdr_end
    output logic [SPS_W-1:0] sps,
    // (0.16, docs/colour.md) the slice's SPS's colour description (E.1.1; E.2.1's inferences when
    // absent): {colour_description_present_flag, video_full_range_flag, colour_primaries,
    // transfer_characteristics, matrix_coefficients} -- held with sps. Kept in its own table, not in
    // sps_t: sps_t is also the front end's sps_mem, which never reads them.
    output logic [25:0] sps_colour,
    // (docs/chroma.md §4) the slice's SPS's chroma siting: {chroma_sample_loc_type_bottom_field,
    // _top_field}, each 0..5 (E.2.1: absent 0; a value past 5, a malformed VUI, taken as 0) -- held with sps
    output logic [5:0]  sps_siting,
    output logic [PPS_W-1:0] pps,
    output logic [13:0] sh_first_mb,
    output logic [1:0]  sh_slice_type,     // 0 P, 1 B, 2 I
    output logic [1:0]  sh_nal_ref_idc,
    output logic        sh_idr,
    output logic [15:0] sh_frame_num,
    output logic        sh_field_pic,
    output logic        sh_bottom_field,
    output logic [15:0] sh_poc_lsb,
    output logic [31:0] sh_delta_poc_bottom,
    output logic [31:0] sh_delta_poc0,
    output logic [31:0] sh_delta_poc1,
    output logic        sh_direct_spatial,
    output logic [5:0]  sh_num_ref_l0,
    output logic [5:0]  sh_num_ref_l1,
    output logic [2:0]  sh_luma_log2_wd,
    output logic [2:0]  sh_chroma_log2_wd,
    output logic        sh_has_weights,    // explicit weights were sent (the table is valid)
    output logic        sh_no_output_of_prior_pics,
    // P5c / P5d: the picture's display facts, after its FIRST slice's header (absent on the
    // later slices): the picture timing SEI's pic_struct, the access unit's PTS
    output logic [3:0]  sh_pic_struct,
    output logic        sh_pic_struct_v,
    output logic [32:0] sh_pts,
    output logic        sh_pts_v,
    output logic        sh_long_term_reference,
    output logic        sh_adaptive_marking,
    output logic        sh_mmco5,          // the marking includes an MMCO 5
    output logic [5:0]  sh_qp,             // SliceQPY
    output logic [1:0]  sh_disable_deblock,
    output logic signed [4:0] sh_alpha_off, // FilterOffsetA (already << 1)
    output logic signed [4:0] sh_beta_off,
    output logic [5:0]  sh_n_mods_l0,
    output logic [5:0]  sh_n_mods_l1,
    output logic [6:0]  sh_n_mmco,
    output logic        sh_sflat,          // the slice's scaling matrix is Flat_16 (no weights read)

    // the tables (synchronous reads, data one cycle after the address)
    input  wire  [5:0]  wt_addr,           // {list, ref_idx[4:0]}
    output logic [50:0] wt_data,           // {cr_o, cr_w, cb_o, cb_w, luma_o, luma_w}: offsets 8 bits,
                                           // weights 9 (the default 2^denom is 128 at denom 7, 7.4.3.2)
    input  wire  [6:0]  mod_addr,          // {list, op[5:0]}
    output logic [33:0] mod_data,          // {idc[1:0], value[31:0]}
    input  wire  [5:0]  mmco_addr,
    output logic [66:0] mmco_data,         // {op[2:0], arg_a[31:0], arg_b[31:0]}: a = diff / ltpn / max+1, b = ltfi
    input  wire  [7:0]  poc1_addr,         // offset_for_ref_frame prefix sum up to and incl. i
    output logic [31:0] poc1_data,
    output logic [31:0] poc1_total,        // ExpectedDeltaPerPicOrderCntCycle of the active SPS
    input  wire  [4:0]  sl4_ra,            // the 4x4 lists' word {list, k / 4} (lists 0..5)
    output logic [31:0] sl4_q,
    input  wire  [4:0]  sl8_ra,            // the 8x8 lists' word {list - 6, k / 4}
    output logic [31:0] sl8_q,

    // refusals / errors (pulses, counted by recon_top)
    output logic        err_no_pps,        // the slice names a PPS never stored
    output logic        err_no_sps,
    output logic        err_poc1,          // type-1 SPS whose offset table was evicted
    output logic        err_mmco_ovf
);

`include "h264/dec/h264_fields.svh"

    // activation pipeline: hdr_end -> read pps -> read sps -> present
    logic [1:0]  act;
    logic [PPS_W-1:0] pps_q;
    logic [SPS_W-1:0] sps_q;
    pps_t  pps_qt;
    sps_t  sps_qt;
    assign pps_qt = pps_q;
    assign sps_qt = sps_q;

    // ---- the parameter stores ----------------------------------------------------------
    logic [SPS_W-1:0] sps_ram [0:31];
    logic [31:0] col_ram [0:31];             // (0.16) beside it, by the same id; (chroma.md §4) [31:26] the siting
    logic [31:0] col_q;
    logic [31:0] c_stage;                    // the SPS being received: its colour description and chroma siting
    localparam logic [31:0] C_DEFAULT = {3'd0, 3'd0, 1'b0, 1'b0, 8'd2, 8'd2, 8'd2};   // E.2.1: absent -> 2 (unspecified), limited; siting 0
    logic [PPS_W-1:0] pps_ram [0:255];
    logic [31:0] sps_valid;
    logic [255:0] pps_valid;
    sps_t  s_stage;                          // the SPS being received
    pps_t  p_stage;
    logic  [4:0] s_id;                       // its id (the store index)
    logic  [7:0] p_id;
    logic  [4:0] nal_type;
    logic  in_sps, in_pps;                   // the current NAL is an SPS / PPS
    logic  [7:0] poc1_i;                     // offset_for_ref_frame index being received
    logic  [31:0] poc1_sum;

    // POC type 1 cache: two slots of 255 prefix sums
    logic [31:0] poc1_ram0 [0:255];
    logic [31:0] poc1_ram1 [0:255];
    logic [4:0]  poc1_slot_id [0:1];
    logic [1:0]  poc1_slot_valid;
    logic        poc1_slot_lru;              // the slot to evict next
    logic        poc1_wr_slot;               // the slot the current SPS writes
    logic [31:0] poc1_total_r [0:1];
    logic        poc1_act_slot;              // the active SPS's slot
    logic        poc1_act_valid;

    // ---- the slice header being received -------------------------------------------------
    logic [7:0]  h_pps_id;
    logic [13:0] h_first_mb;
    logic [1:0]  h_slice_type, h_nal_ref_idc;
    logic        h_idr, h_field_pic, h_bottom_field, h_direct_spatial;
    logic [15:0] h_frame_num, h_poc_lsb;
    logic [31:0] h_delta_poc_bottom, h_delta_poc0, h_delta_poc1;
    logic        h_override;
    logic [5:0]  h_num_ref [0:1];
    logic [2:0]  h_luma_log2_wd, h_chroma_log2_wd;
    logic        h_has_weights, h_no_output, h_long_term_ref, h_adaptive, h_mmco5;
    logic [3:0]  h_ps;
    logic        h_ps_v, h_pts_v;
    logic [32:0] h_pts;
    logic [5:0]  h_qp;
    logic [1:0]  h_disable_deblock;
    logic signed [4:0] h_alpha_off, h_beta_off;
    logic [5:0]  h_n_mods [0:1];
    logic [6:0]  h_n_mmco;
    logic        h_mmco_ovf;
    logic signed [31:0] h_pic_init_qp;       // from the PPS at activation (SliceQPY needs it)
    logic signed [31:0] h_slice_qp_delta;

    // weights: the entry being assembled
    logic        w_list;
    logic [4:0]  w_i;
    logic [1:0]  w_c;                        // chroma value index 0..3
    logic signed [8:0] w_lw, w_cbw, w_crw;   // (9 bits: a default of 2^7 = 128 is not a signed byte)
    logic signed [7:0] w_lo, w_cbo, w_cro;
    logic        w_pending;                  // an entry is assembled and unwritten
    // the active scaling matrix (the words of the current slice)
    logic [31:0] sl4_ram [0:31];             // 24 used
    logic [31:0] sl8_ram [0:31];
    logic        sl_we;
    logic [5:0]  sl_wi;                      // the next word's index 0..55
    logic [31:0] sl_wd;
    logic        h_sflat;
    always_ff @(posedge clk) begin
        if (sl_we && sl_wi < 6'd24) sl4_ram[sl_wi[4:0]] <= sl_wd;
        sl4_q <= sl4_ram[sl4_ra];
    end
    always_ff @(posedge clk) begin
        if (sl_we && sl_wi >= 6'd24) sl8_ram[sl_wi[4:0] - 5'd24] <= sl_wd;
        sl8_q <= sl8_ram[sl8_ra];
    end
    logic [50:0] wt_ram [0:63];
    logic        wt_we;
    logic [5:0]  wt_waddr;
    logic [50:0] wt_wdata;

    // modifications and MMCOs
    logic [33:0] mod_ram [0:65];
    logic        mod_we;
    logic [6:0]  mod_waddr;
    logic [33:0] mod_wdata;
    logic        m_list;
    logic [1:0]  m_idc;
    logic        m_pending;                  // an op waits for its value
    logic [66:0] mmco_ram [0:63];
    logic        mmco_we;
    logic [5:0]  mmco_waddr;
    logic [66:0] mmco_wdata;               // captured with the enable: the next op overwrites mm_*
    logic [2:0]  mm_op;
    logic [31:0] mm_a, mm_b;
    logic        mm_pending;

    wire is_hdr = se_valid && (se_kind == K_HDR_WORD);
    // slice_type % 5 -> 0 P, 1 B, 2 I (SP/SI are refused upstream)
    wire [7:0] st_raw = se_val[7:0];
    wire [7:0] st_m5  = (st_raw >= 8'd5) ? st_raw - 8'd5 : st_raw;
    wire [1:0] st_mod5 = (st_m5 == 8'd0) ? 2'd0 : (st_m5 == 8'd1) ? 2'd1 : 2'd2;
    // SliceQPY = 26 + pic_init_qp_minus26 + slice_qp_delta (checked 0..51 upstream)
    wire signed [31:0] qp_sum = 32'sd26 + {{26{pps_qt.pic_init_qp_minus26[5]}}, pps_qt.pic_init_qp_minus26} + h_slice_qp_delta;
    wire is_nal = se_valid && (se_kind == K_NAL_WORD);
    // (0.16) the colour description is handled a clock behind the word decode -- off is_nal's and the header
    // case's load (the first fits' near-gate path: sfifo dout -> is_nal, fanout 50 -> the slice header's
    // enables; the description's reset and table write had added ~26 loads). A NAL word at cycle k: the table
    // written and the description reset on k + 1's edge, from the description as it stands then (a colour
    // field just before the NAL word, captured on k's edge, is in it); a colour field captured a clock late.
    logic        cn_q, cn_sps_q, ch_q;
    logic [4:0]  cs_id_q;
    logic [7:0]  ca_q, cv_q;
    logic        cbig_q;                     // (chroma.md §4) the value past 5 (the whole word: cv_q is its low byte)
    always_ff @(posedge clk) begin
        cn_q <= is_nal; cn_sps_q <= is_nal && in_sps; cs_id_q <= s_id;
        ch_q <= is_hdr && in_sps; ca_q <= se_aux; cv_q <= se_val[7:0]; cbig_q <= (se_val > 32'd5);
    end
    wire signed [31:0] sval = se_val;

    // ---- RAM ports (one synchronous read each) -------------------------------------------
    always_ff @(posedge clk) begin
        if (wt_we)   wt_ram[wt_waddr] <= wt_wdata;
        wt_data <= wt_ram[wt_addr];
        if (mod_we)  mod_ram[mod_waddr] <= mod_wdata;
        mod_data <= mod_ram[mod_addr];
        if (mmco_we) mmco_ram[mmco_waddr] <= mmco_wdata;
        mmco_data <= mmco_ram[mmco_addr];
        poc1_data <= poc1_act_slot ? poc1_ram1[poc1_addr] : poc1_ram0[poc1_addr];
        if (is_hdr && in_sps && se_aux == F_offset_for_ref_frame_i) begin
            if (poc1_wr_slot) poc1_ram1[poc1_i] <= poc1_sum + se_val;
            else              poc1_ram0[poc1_i] <= poc1_sum + se_val;
        end
        // the parameter stores: written at the end of the NAL unit
        if (is_nal && in_sps) sps_ram[s_id] <= s_stage;
        if (cn_sps_q) col_ram[cs_id_q] <= c_stage;          // (0.16) a clock after the SPS's end
        if (is_nal && in_pps) pps_ram[p_id] <= p_stage;
        if (act == 2'd1) pps_q <= pps_ram[h_pps_id];
        if (act == 2'd2) begin sps_q <= sps_ram[pps_qt.sps_id]; col_q <= col_ram[pps_qt.sps_id]; end
    end

    // ---- the capture ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sps_valid <= '0; pps_valid <= '0; in_sps <= 1'b0; in_pps <= 1'b0; nal_type <= '0;
            s_stage <= '0; p_stage <= '0; s_id <= '0; p_id <= '0; poc1_i <= '0; poc1_sum <= '0; c_stage <= C_DEFAULT;
            poc1_slot_id[0] <= '0; poc1_slot_id[1] <= '0; poc1_slot_valid <= '0; poc1_slot_lru <= 1'b0;
            poc1_wr_slot <= 1'b0; poc1_total_r[0] <= '0; poc1_total_r[1] <= '0;
            poc1_act_slot <= 1'b0; poc1_act_valid <= 1'b0; poc1_total <= '0;
            h_pps_id <= '0; h_first_mb <= '0; h_slice_type <= '0; h_nal_ref_idc <= '0; h_idr <= 1'b0;
            h_field_pic <= 1'b0; h_bottom_field <= 1'b0; h_direct_spatial <= 1'b1; h_frame_num <= '0;
            h_poc_lsb <= '0; h_delta_poc_bottom <= '0; h_delta_poc0 <= '0; h_delta_poc1 <= '0;
            h_override <= 1'b0; h_num_ref[0] <= 6'd1; h_num_ref[1] <= 6'd1;
            h_luma_log2_wd <= '0; h_chroma_log2_wd <= '0; h_has_weights <= 1'b0; h_no_output <= 1'b0;
            h_ps <= '0; h_ps_v <= 1'b0; h_pts <= '0; h_pts_v <= 1'b0;
            sh_pic_struct <= '0; sh_pic_struct_v <= 1'b0; sh_pts <= '0; sh_pts_v <= 1'b0;
            h_long_term_ref <= 1'b0; h_adaptive <= 1'b0; h_mmco5 <= 1'b0; h_qp <= '0;
            h_disable_deblock <= '0; h_alpha_off <= '0; h_beta_off <= '0;
            h_n_mods[0] <= '0; h_n_mods[1] <= '0; h_n_mmco <= '0; h_mmco_ovf <= 1'b0;
            h_pic_init_qp <= '0; h_slice_qp_delta <= '0;
            w_list <= 1'b0; w_i <= '0; w_c <= '0; w_lw <= '0; w_lo <= '0; w_cbw <= '0; w_cbo <= '0;
            w_crw <= '0; w_cro <= '0; w_pending <= 1'b0; wt_we <= 1'b0; wt_waddr <= '0; wt_wdata <= '0;
            mod_we <= 1'b0; mod_waddr <= '0; mod_wdata <= '0; m_list <= 1'b0; m_idc <= '0; m_pending <= 1'b0;
            mmco_we <= 1'b0; mmco_waddr <= '0; mmco_wdata <= '0; mm_op <= '0; mm_a <= '0; mm_b <= '0; mm_pending <= 1'b0;
            act <= '0; slice_ready <= 1'b0; sps <= '0; pps <= '0; sps_colour <= C_DEFAULT[25:0]; sps_siting <= 6'd0;
            sh_first_mb <= '0; sh_slice_type <= '0; sh_nal_ref_idc <= '0; sh_idr <= 1'b0; sh_frame_num <= '0;
            sh_field_pic <= 1'b0; sh_bottom_field <= 1'b0; sh_poc_lsb <= '0; sh_delta_poc_bottom <= '0;
            sh_delta_poc0 <= '0; sh_delta_poc1 <= '0; sh_direct_spatial <= 1'b0; sh_num_ref_l0 <= '0;
            sh_num_ref_l1 <= '0; sh_luma_log2_wd <= '0; sh_chroma_log2_wd <= '0; sh_has_weights <= 1'b0;
            sh_no_output_of_prior_pics <= 1'b0; sh_long_term_reference <= 1'b0; sh_adaptive_marking <= 1'b0;
            sh_mmco5 <= 1'b0; sh_qp <= '0; sh_disable_deblock <= '0; sh_alpha_off <= '0; sh_beta_off <= '0;
            sh_n_mods_l0 <= '0; sh_n_mods_l1 <= '0; sh_n_mmco <= '0; sh_sflat <= 1'b1;
            sl_we <= 1'b0; sl_wi <= '0; sl_wd <= '0; h_sflat <= 1'b1;
            err_no_pps <= 1'b0; err_no_sps <= 1'b0; err_poc1 <= 1'b0; err_mmco_ovf <= 1'b0;
        end else begin
            wt_we <= 1'b0; mod_we <= 1'b0; mmco_we <= 1'b0; slice_ready <= 1'b0;
            err_no_pps <= 1'b0; err_no_sps <= 1'b0; err_poc1 <= 1'b0; err_mmco_ovf <= 1'b0;
            if (sl_we) sl_wi <= sl_wi + 6'd1;
            sl_we <= 1'b0;
            if (clear) begin
                sps_valid <= '0; pps_valid <= '0; poc1_slot_valid <= '0;
            end

            // ---- NAL words: close the previous parameter set, open the next ------------
            if (is_nal) begin
                if (in_sps) begin
                    sps_valid[s_id] <= 1'b1;
                    if (s_stage.poc_type == 2'd1) begin
                        poc1_slot_id[poc1_wr_slot] <= s_id;
                        poc1_slot_valid[poc1_wr_slot] <= 1'b1;
                        poc1_total_r[poc1_wr_slot] <= poc1_sum;
                        poc1_slot_lru <= !poc1_wr_slot;
                    end
                end
                if (in_pps) pps_valid[p_id] <= 1'b1;
                nal_type <= se_aux[4:0];
                in_sps <= (se_aux[4:0] == 5'd7);
                in_pps <= (se_aux[4:0] == 5'd8);
                s_stage <= '0;
                p_stage <= '0;
                poc1_i <= '0; poc1_sum <= '0;
                if (se_aux[4:0] == 5'd1 || se_aux[4:0] == 5'd5) begin
                    // defaults for a slice header (7.4.3): what an absent field infers
                    h_nal_ref_idc <= se_val[1:0];
                    h_idr <= (se_aux[4:0] == 5'd5);
                    h_field_pic <= 1'b0; h_bottom_field <= 1'b0; h_direct_spatial <= 1'b1;
                    h_poc_lsb <= '0; h_delta_poc_bottom <= '0; h_delta_poc0 <= '0; h_delta_poc1 <= '0;
                    h_override <= 1'b0; h_has_weights <= 1'b0; h_no_output <= 1'b0; h_long_term_ref <= 1'b0;
                    h_ps_v <= 1'b0; h_pts_v <= 1'b0;
                    h_adaptive <= 1'b0; h_mmco5 <= 1'b0; h_disable_deblock <= '0; h_alpha_off <= '0; h_beta_off <= '0;
                    h_n_mods[0] <= '0; h_n_mods[1] <= '0; h_n_mmco <= '0; h_mmco_ovf <= 1'b0;
                    w_pending <= 1'b0; m_pending <= 1'b0; mm_pending <= 1'b0; w_list <= 1'b0; w_i <= '0;
                    h_slice_qp_delta <= '0;
                    h_sflat <= 1'b1;                   // (a stream without the word: Main's flat)
                end
            end

            // ---- HDR words ----------------------------------------------------------
            // (0.16) the colour description, a clock behind (above): reset a clock after each NAL word, its
            // fields from the registered word
            if (cn_q) c_stage <= C_DEFAULT;
            else if (ch_q) case (ca_q)
                F_video_full_range_flag:           c_stage[24] <= cv_q[0];
                F_colour_description_present_flag: c_stage[25] <= cv_q[0];
                F_colour_primaries:                c_stage[23:16] <= cv_q;
                F_transfer_characteristics:        c_stage[15:8] <= cv_q;
                F_matrix_coefficients:             c_stage[7:0] <= cv_q;
                F_chroma_sample_loc_type_top_field:    c_stage[28:26] <= cbig_q ? 3'd0 : cv_q[2:0];
                F_chroma_sample_loc_type_bottom_field: c_stage[31:29] <= cbig_q ? 3'd0 : cv_q[2:0];
                default: ;
            endcase
            if (is_hdr && in_sps) begin
                case (se_aux)
                    F_profile_idc:                            s_stage.profile_idc <= se_val[7:0];
                    F_level_idc:                              s_stage.level_idc <= se_val[7:0];
                    F_seq_parameter_set_id:                   s_id <= se_val[4:0];
                    F_log2_max_frame_num_minus4:              s_stage.log2_max_frame_num_minus4 <= se_val[3:0];
                    F_pic_order_cnt_type:                     s_stage.poc_type <= se_val[1:0];
                    F_log2_max_pic_order_cnt_lsb_minus4:      s_stage.log2_max_poc_lsb_minus4 <= se_val[3:0];
                    F_delta_pic_order_always_zero_flag:       s_stage.delta_pic_order_always_zero <= se_val[0];
                    F_offset_for_non_ref_pic:                 s_stage.offset_for_non_ref_pic <= se_val;
                    F_offset_for_top_to_bottom_field:         s_stage.offset_for_top_to_bottom_field <= se_val;
                    F_num_ref_frames_in_pic_order_cnt_cycle: begin
                        s_stage.num_ref_frames_in_poc_cycle <= se_val[7:0];
                        // choose the cache slot now: the same id's slot, else the LRU one
                        if (poc1_slot_valid[0] && poc1_slot_id[0] == s_id)      poc1_wr_slot <= 1'b0;
                        else if (poc1_slot_valid[1] && poc1_slot_id[1] == s_id) poc1_wr_slot <= 1'b1;
                        else poc1_wr_slot <= poc1_slot_lru;
                    end
                    F_offset_for_ref_frame_i: begin
                        poc1_i <= poc1_i + 1'b1;
                        poc1_sum <= poc1_sum + se_val;
                    end
                    F_num_ref_frames:                         s_stage.num_ref_frames <= se_val[4:0];
                    F_gaps_in_frame_num_value_allowed_flag:   s_stage.gaps_in_frame_num_allowed <= se_val[0];
                    F_pic_width_in_mbs_minus1:                s_stage.width_mbs_minus1 <= se_val[6:0];
                    F_pic_height_in_map_units_minus1:         s_stage.height_map_units_minus1 <= se_val[6:0];
                    F_frame_mbs_only_flag:                    s_stage.frame_mbs_only <= se_val[0];
                    F_direct_8x8_inference_flag:              s_stage.direct_8x8_inference <= se_val[0];
                    F_frame_cropping_flag:                    s_stage.frame_cropping <= se_val[0];
                    F_frame_crop_left_offset:                 s_stage.crop_left <= se_val[9:0];
                    F_frame_crop_right_offset:                s_stage.crop_right <= se_val[9:0];
                    F_frame_crop_top_offset:                  s_stage.crop_top <= se_val[9:0];
                    F_frame_crop_bottom_offset:               s_stage.crop_bottom <= se_val[9:0];
                    F_vui_parameters_present_flag:            s_stage.vui_present <= se_val[0];
                    // the VUI fields the display reads (P5; the SEI's lengths are the front end's)
                    F_aspect_ratio_idc:                       s_stage.aspect_ratio_idc <= se_val[7:0];
                    F_sar_width:                              s_stage.sar_width <= se_val[15:0];
                    F_sar_height:                             s_stage.sar_height <= se_val[15:0];
                    F_timing_info_present_flag:               s_stage.timing_present <= se_val[0];
                    F_num_units_in_tick:                      s_stage.num_units_in_tick <= se_val;
                    F_time_scale:                             s_stage.time_scale <= se_val;
                    F_pic_struct_present_flag:                s_stage.pic_struct_present <= se_val[0];
                    F_bitstream_restriction_flag:             s_stage.bitstream_restriction <= se_val[0];
                    F_max_dec_frame_buffering:                s_stage.max_dec_frame_buffering <= se_val[4:0];
                    F_max_num_reorder_frames:                 s_stage.max_num_reorder_frames <= se_val[4:0];   // <= 16: the front end range-checks it
                    default: ;
                endcase
            end
            if (is_hdr && in_pps) begin
                case (se_aux)
                    F_pic_parameter_set_id:                       p_id <= se_val[7:0];
                    F_seq_parameter_set_id:                       p_stage.sps_id <= se_val[4:0];
                    F_bottom_field_pic_order_in_frame_present_flag: p_stage.bottom_field_pic_order_present <= se_val[0];
                    F_num_ref_idx_l0_default_active_minus1:       p_stage.num_ref_idx_l0_default_minus1 <= se_val[4:0];
                    F_num_ref_idx_l1_default_active_minus1:       p_stage.num_ref_idx_l1_default_minus1 <= se_val[4:0];
                    F_weighted_pred_flag:                         p_stage.weighted_pred <= se_val[0];
                    F_weighted_bipred_idc:                        p_stage.weighted_bipred_idc <= se_val[1:0];
                    F_pic_init_qp_minus26:                        p_stage.pic_init_qp_minus26 <= se_val[5:0];
                    F_pic_init_qs_minus26:                        p_stage.pic_init_qs_minus26 <= se_val[5:0];
                    F_chroma_qp_index_offset: begin
                        p_stage.chroma_qp_index_offset <= se_val[4:0];
                        p_stage.second_chroma_qp_index_offset <= se_val[4:0];   // 7.4.2.2: equal when absent
                    end
                    F_second_chroma_qp_index_offset:              p_stage.second_chroma_qp_index_offset <= se_val[4:0];
                    F_deblocking_filter_control_present_flag:     p_stage.deblocking_filter_control_present <= se_val[0];
                    F_constrained_intra_pred_flag:                p_stage.constrained_intra_pred <= se_val[0];
                    F_redundant_pic_cnt_present_flag:             p_stage.redundant_pic_cnt_present <= se_val[0];
                    default: ;
                endcase
            end
            if (is_hdr && !in_sps && !in_pps) begin
                case (se_aux)
                    F_first_mb_in_slice:            h_first_mb <= se_val[13:0];
                    F_slice_type:                   h_slice_type <= st_mod5;
                    F_pic_parameter_set_id:         h_pps_id <= se_val[7:0];
                    F_frame_num:                    h_frame_num <= se_val[15:0];
                    F_field_pic_flag:               h_field_pic <= se_val[0];
                    F_bottom_field_flag:            h_bottom_field <= se_val[0];
                    F_pic_order_cnt_lsb:            h_poc_lsb <= se_val[15:0];
                    F_delta_pic_order_cnt_bottom:   h_delta_poc_bottom <= se_val;
                    F_delta_pic_order_cnt_0:        h_delta_poc0 <= se_val;
                    F_delta_pic_order_cnt_1:        h_delta_poc1 <= se_val;
                    F_direct_spatial_mv_pred_flag:  h_direct_spatial <= se_val[0];
                    F_num_ref_idx_active_override_flag: h_override <= se_val[0];
                    F_num_ref_idx_l0_active_minus1: h_num_ref[0] <= se_val[5:0] + 6'd1;
                    F_num_ref_idx_l1_active_minus1: h_num_ref[1] <= se_val[5:0] + 6'd1;
                    // list modification: an op then its value
                    F_modification_of_pic_nums_idc_l0, F_modification_of_pic_nums_idc_l1: begin
                        m_list <= (se_aux == F_modification_of_pic_nums_idc_l1);   // the _l1 id is the _l0 id + 1
                        m_idc <= se_val[1:0];
                        m_pending <= (se_val[1:0] != 2'd3);
                    end
                    F_abs_diff_pic_num_minus1_l0, F_abs_diff_pic_num_minus1_l1,
                    F_long_term_pic_num_l0, F_long_term_pic_num_l1: begin
                        if (m_pending) begin
                            mod_we <= 1'b1;
                            mod_waddr <= {m_list, h_n_mods[m_list]};
                            mod_wdata <= {m_idc, se_val};
                            if (h_n_mods[m_list] != 6'd33) h_n_mods[m_list] <= h_n_mods[m_list] + 1'b1;
                            m_pending <= 1'b0;
                        end
                    end
                    // weights (7.4.3.2): defaults on the flag, values overwrite, the entry
                    // is written when its chroma part ends
                    F_luma_log2_weight_denom:   begin h_luma_log2_wd <= se_val[2:0]; h_has_weights <= 1'b1; end
                    F_chroma_log2_weight_denom: h_chroma_log2_wd <= se_val[2:0];
                    F_luma_weight_flag_l0, F_luma_weight_flag_l1: begin
                        if ((se_aux == F_luma_weight_flag_l1) != w_list) begin w_list <= (se_aux == F_luma_weight_flag_l1); w_i <= '0; end
                        w_lw <= 9'sd1 <<< h_luma_log2_wd; w_lo <= '0;
                        w_cbw <= 9'sd1 <<< h_chroma_log2_wd; w_cbo <= '0;
                        w_crw <= 9'sd1 <<< h_chroma_log2_wd; w_cro <= '0;
                        w_c <= '0;
                    end
                    F_luma_weight_l0, F_luma_weight_l1:   w_lw <= se_val[8:0];     // -128..127, sign-extended
                    F_luma_offset_l0, F_luma_offset_l1:   w_lo <= se_val[7:0];
                    F_chroma_weight_flag_l0, F_chroma_weight_flag_l1: begin
                        if (!se_val[0]) begin
                            wt_we <= 1'b1; wt_waddr <= {w_list, w_i};
                            wt_wdata <= {w_cro, w_crw, w_cbo, w_cbw, w_lo, w_lw};
                            w_i <= w_i + 1'b1;
                        end
                    end
                    F_chroma_weight_l0, F_chroma_weight_l1: begin
                        if (w_c == 2'd0) w_cbw <= se_val[8:0]; else w_crw <= se_val[8:0];
                    end
                    F_chroma_offset_l0, F_chroma_offset_l1: begin
                        if (w_c == 2'd0) begin
                            w_cbo <= se_val[7:0]; w_c <= 2'd1;
                        end else begin
                            wt_we <= 1'b1; wt_waddr <= {w_list, w_i};
                            wt_wdata <= {se_val[7:0], w_crw, w_cbo, w_cbw, w_lo, w_lw};
                            w_i <= w_i + 1'b1; w_c <= '0;
                        end
                    end
                    // marking
                    F_no_output_of_prior_pics_flag:        h_no_output <= se_val[0];
                    F_long_term_reference_flag:            h_long_term_ref <= se_val[0];
                    F_adaptive_ref_pic_marking_mode_flag:  h_adaptive <= se_val[0];
                    F_memory_management_control_operation: begin
                        // write the previous op (its args arrived), start the next
                        if (mm_pending) begin
                            if (h_n_mmco[6]) begin
                                err_mmco_ovf <= 1'b1; h_mmco_ovf <= 1'b1;
                            end else begin
                                mmco_we <= 1'b1; mmco_waddr <= h_n_mmco[5:0]; mmco_wdata <= {mm_op, mm_a, mm_b};
                                h_n_mmco <= h_n_mmco + 1'b1;
                            end
                        end
                        mm_op <= se_val[2:0]; mm_a <= '0; mm_b <= '0;
                        mm_pending <= (se_val[2:0] != 3'd0);
                        if (se_val[2:0] == 3'd5) h_mmco5 <= 1'b1;
                    end
                    F_difference_of_pic_nums_minus1:       mm_a <= se_val;
                    F_long_term_pic_num:                   mm_a <= se_val;
                    F_max_long_term_frame_idx_plus1:       mm_a <= se_val;
                    F_long_term_frame_idx:                 mm_b <= se_val;
                    F_slice_qp_delta:                      h_slice_qp_delta <= se_val;
                    // High: the resolved scaling matrix, after the header
                    F_scaling_matrix_flag:                 begin h_sflat <= !se_val[0]; sl_wi <= 6'd0; end
                    F_scaling_list_word:                   begin sl_we <= 1'b1; sl_wd <= se_val; end
                    F_disable_deblocking_filter_idc:       h_disable_deblock <= se_val[1:0];
                    F_slice_alpha_c0_offset_div2:          h_alpha_off <= {se_val[3:0], 1'b0};
                    F_slice_beta_offset_div2:              h_beta_off <= {se_val[3:0], 1'b0};
                    // P5c: after the picture's first slice header
                    F_pic_struct:                          begin h_ps <= se_val[3:0]; h_ps_v <= 1'b1; end
                    F_au_pts_lo:                           begin h_pts[31:0] <= se_val; h_pts_v <= 1'b1; end
                    F_au_pts_hi:                           h_pts[32] <= se_val[0];
                    default: ;
                endcase
            end

            // ---- activation --------------------------------------------------------------
            if (hdr_end) begin
                act <= 2'd1;
            end else if (act == 2'd1) begin
                act <= 2'd2;                          // pps_q lands
            end else if (act == 2'd2) begin
                act <= 2'd3;                          // sps_q lands
            end else if (act == 2'd3) begin
                act <= 2'd0;
                slice_ready <= 1'b1;
                if (!pps_valid[h_pps_id]) err_no_pps <= 1'b1;
                if (!sps_valid[pps_qt.sps_id]) err_no_sps <= 1'b1;
                pps <= pps_q;
                sps <= sps_q;
                sps_colour <= col_q[25:0];
                sps_siting <= col_q[31:26];
                sh_first_mb <= h_first_mb;
                sh_slice_type <= h_slice_type;
                sh_nal_ref_idc <= h_nal_ref_idc;
                sh_idr <= h_idr;
                sh_frame_num <= h_frame_num;
                sh_field_pic <= h_field_pic;
                sh_bottom_field <= h_bottom_field;
                sh_poc_lsb <= h_poc_lsb;
                sh_delta_poc_bottom <= h_delta_poc_bottom;
                sh_delta_poc0 <= h_delta_poc0;
                sh_delta_poc1 <= h_delta_poc1;
                sh_direct_spatial <= h_direct_spatial;
                sh_num_ref_l0 <= h_override ? h_num_ref[0] : {1'b0, pps_qt.num_ref_idx_l0_default_minus1} + 6'd1;
                sh_num_ref_l1 <= h_override ? h_num_ref[1] : {1'b0, pps_qt.num_ref_idx_l1_default_minus1} + 6'd1;
                sh_luma_log2_wd <= h_luma_log2_wd;
                sh_chroma_log2_wd <= h_chroma_log2_wd;
                sh_has_weights <= h_has_weights;
                sh_no_output_of_prior_pics <= h_no_output;
                sh_pic_struct <= h_ps; sh_pic_struct_v <= h_ps_v;
                sh_pts <= h_pts; sh_pts_v <= h_pts_v;
                sh_long_term_reference <= h_long_term_ref;
                sh_adaptive_marking <= h_adaptive;
                sh_mmco5 <= h_mmco5;
                // SliceQPY = 26 + pic_init_qp_minus26 + slice_qp_delta (0..51 checked upstream)
                sh_qp <= qp_sum[5:0];
                sh_disable_deblock <= h_disable_deblock;
                sh_alpha_off <= h_alpha_off;
                sh_beta_off <= h_beta_off;
                sh_n_mods_l0 <= h_n_mods[0];
                sh_n_mods_l1 <= h_n_mods[1];
                sh_n_mmco <= h_n_mmco;
                sh_sflat <= h_sflat;
                // the POC type 1 table of the active SPS
                poc1_act_valid <= 1'b0;
                if (sps_qt.poc_type == 2'd1 && sps_qt.num_ref_frames_in_poc_cycle != 8'd0) begin
                    if (poc1_slot_valid[0] && poc1_slot_id[0] == pps_qt.sps_id) begin
                        poc1_act_slot <= 1'b0; poc1_act_valid <= 1'b1; poc1_total <= poc1_total_r[0];
                    end else if (poc1_slot_valid[1] && poc1_slot_id[1] == pps_qt.sps_id) begin
                        poc1_act_slot <= 1'b1; poc1_act_valid <= 1'b1; poc1_total <= poc1_total_r[1];
                    end else begin
                        err_poc1 <= 1'b1;
                    end
                end
                // the last MMCO (op 0 ends the list: its record is the pending one)
            end
            // an MMCO list ends with op 0: the op before it is written on the op-0 word
            // (handled above: mm_pending cleared, the previous op written)
        end
    end

endmodule

`default_nettype wire
