// h264/dec/recon_top.sv -- the H.264 reconstruction: the front end's syntax-element
// stream in, decoded pictures in the DPB in DDR3 out (docs/h264_recon.md)
//
//   se words -> sfifo -> router -> recon_hdr (NAL / header words: parameter sets, the
//                                    slice header) -> recon_dpb (POC, marking, stores)
//                                    -> recon_lists -> recon_slice_tab
//                              `-> mb_intake (macroblock words) -> recon_mb -> dpb_mem -> DDR3
//
// The router holds every NAL word until the macroblock pipeline is idle (the intake
// empty, recon_mb idle): a slice header overwrites recon_hdr's weight / modification /
// MMCO tables and a new slice changes every parameter recon_mb reads, so a slice's
// header is taken only after the previous slice's last macroblock is written. The first
// macroblock word of a slice ends its header (hdr_end); the router then waits for the
// slice to be READY -- recon_dpb (a new picture: the previous one marked, a store, the
// POC), recon_lists, recon_slice_tab -- before any macroblock word goes to the intake.
//
// A picture above Level 3.1's MaxFS (3,600 macroblocks: the DPB stores are 2 MiB each,
// docs/h264_recon.md S2.2) is refused: its macroblock words are discarded, `ref_size`
// counts it (word 20's rc_ref_size), nothing is written -- and (2026-10-02) recon_dpb never
// sees its slices, so no store is opened and nothing is emitted to the display (until then the
// picture was opened in a store before the size check and that unwritten store was shown).

`default_nettype none

module recon_top
    import h264_pkg::*;
#(
    parameter logic [28:0] DPB_BASE = 29'h0600_0000,    // byte 0x3000_0000: the core's DDR3 window
    parameter int STALL_LIMIT = 24'd13_000_000          // recon_dpb's bound on a wait for the display (a bench sets it small)
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,

    // the syntax-element stream (h264_top)
    input  wire         se_valid,
    output logic        se_ready,
    input  wire  [7:0]  se_kind,
    input  wire  [7:0]  se_aux,
    input  wire  [31:0] se_val,

    // the display: stores it is reading (never reused while held)
    input  wire  [NSTORE-1:0] disp_hold,
    input  wire         disp_frz,          // (Phase 4) the display is frozen (the pause): its holds are no alarm

    // pictures
    output logic        pic_start,         // a picture opened (cur_store / cur_struct valid)
    output logic [4:0]  cur_store,
    output logic [1:0]  cur_struct,
    output logic        pic_done,          // the previous picture is complete (all its writes issued)
    output logic [4:0]  done_store,
    output logic [1:0]  done_struct,
    output logic [7:0]  width_mbs,
    output logic [7:0]  frame_height_mbs,
    output logic [7:0]  aspect_idc,        // the picture's SPS VUI aspect_ratio_idc (0: absent / unspecified)
    output logic [15:0] sar_w,             //   and its Extended_SAR (idc 255) sar_width : sar_height
    output logic [15:0] sar_h,             //   (h264/aspect_vui.sv maps them, Table E-1)
    output logic        idle,
    // (0.16, docs/colour.md) the stream's colour override (ring_rd: its first VIDEO_AU's; 0 auto), quasi-static
    // -- latched after the per-stream reset emptied the decoder, so every picture opened after it is that stream's
    input  wire  [2:0]  stream_colour,

    // P5d, the output process (docs/display.md S6): per picture, its display facts when
    // it opens (pinfo_*: the store, whether it is the store's second field, the size, the
    // crop, the timing, pic_struct and PTS); per store emitted to the display's queue
    // (emit_*). h264/recon_out.sv turns these into records, holds and releases.
    output logic        pinfo_we,
    output logic [4:0]  pinfo_store,
    output logic        pinfo_second,
    output logic [7:0]  pinfo_w_mbs,
    output logic [7:0]  pinfo_hf_mbs,
    output logic [40:0] pinfo_crop,         // {cuy4, left, right, top, bottom}: frame_crop_*_offset (0 without
                                            // cropping) and the vertical crop unit (P6: cuy4 = !frame_mbs_only_flag --
                                            // CropUnitY 4, else 2; CropUnitX is 2 at 4:2:0)
    output logic [39:0] pinfo_aspect,       // {aspect_ratio_idc, sar_width, sar_height} of its SPS's VUI
    output logic [2:0]  pinfo_colour,       // (0.16, docs/colour.md) its colour code 1..6: the stream's override, else
                                            // the VUI's matrix and range, else the size rule
    output logic        pinfo_col_unsup,    // (0.16) ... by the size rule because its matrix is not supported
    output logic [25:0] pinfo_col_tags,     // (0.16) its SPS's colour description (recon_hdr's sps_colour; word 86)
    output logic [5:0]  pinfo_siting,       // (docs/chroma.md §4) its SPS's chroma siting {bottom, top}, each 0..5
    output logic        pinfo_timing_v,
    output logic [31:0] pinfo_nuit,
    output logic [31:0] pinfo_ts,
    output logic [3:0]  pinfo_ps,
    output logic        pinfo_ps_v,
    output logic [32:0] pinfo_pts,
    output logic        pinfo_pts_v,
    output logic        pinfo_idr,
    output logic        emit_valid,
    output logic [4:0]  emit_store,
    output logic        emit_unpaired,
    output logic        emit_first_bot,
    output logic        emit_frame,
    output logic        emit_dec_t,
    output logic        emit_dec_b,
    output logic signed [31:0] emit_poc_t,
    output logic signed [31:0] emit_poc_b,
    output logic        eos_done,           // the end-of-stream flush is complete
    output logic [31:0] out_dropped,
    output logic [31:0] out_direct,
    output logic [31:0] out_over,
    output logic [31:0] nrf_late,          // P3d: an early output below the last POC output (recon_dpb)
    output logic [31:0] stall_cycles,
    output logic [4:0]  dpb_fill,

    // DDR3 (the priority master of ddr_arb in emu)
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,

    // telemetry
    output logic [31:0] pic_count,
    output logic [31:0] mb_count,
    output logic [31:0] err_count,
    output logic [3:0]  err_code,
    output logic [31:0] ref_size
);

`include "h264/dec/h264_fields.svh"

    // ---- the SE FIFO -------------------------------------------------------------------------
    wire         sf_full, sf_valid;
    wire  [47:0] sf_dout;
    logic        sf_rd;
    wire  [10:0] sf_count;
    assign se_ready = !sf_full;
    sfifo #(.DW(48), .AW(9)) u_sf (
        .clk(clk), .rst_n(rst_n), .din({se_kind, se_aux, se_val}), .wr_en(se_valid && !sf_full), .full(sf_full),
        .dout(sf_dout), .dout_valid(sf_valid), .rd_en(sf_rd), .count(sf_count));
    wire [7:0]  w_kind = sf_dout[47:40];
    wire [7:0]  w_aux  = sf_dout[39:32];
    wire [31:0] w_val  = sf_dout[31:0];

    // ---- recon_hdr ------------------------------------------------------------------------------
    logic        h_valid, hdr_end;
    // (perf/retime, 2026-10-13) the header words reach recon_hdr a register later: the FIFO's output ->
    // the router -> recon_hdr's field decode was a census cluster on every seed. hdr_end is delayed the
    // same cycle (the last header word -> hdr_end gap unchanged); a word registered as `clear` arrives is
    // dropped (before: processed, then cleared -- the same parameter sets either way)
    logic        hq_valid, hq_end;
    logic [7:0]  hq_kind, hq_aux;
    logic [31:0] hq_val;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin hq_valid <= 1'b0; hq_end <= 1'b0; hq_kind <= '0; hq_aux <= '0; hq_val <= '0; end
        else begin
            hq_valid <= h_valid && !clear; hq_end <= hdr_end && !clear;
            hq_kind <= w_kind; hq_aux <= w_aux; hq_val <= w_val;
        end
    wire         slice_ready;
    wire [SPS_W-1:0] sps_w;
    wire [25:0] sps_col;                   // (0.16) the slice's SPS's colour description (recon_hdr)
    wire [5:0]  sps_sit;                   // (chroma.md §4) its chroma siting
    wire [PPS_W-1:0] pps_w;
    sps_t sps;
    pps_t pps;
    assign sps = sps_w;
    assign pps = pps_w;
    wire [13:0] sh_first_mb;
    wire [1:0]  sh_slice_type, sh_nal_ref_idc, sh_disable_deblock;
    wire        sh_idr, sh_field_pic, sh_bottom_field, sh_direct_spatial, sh_has_weights;
    wire        sh_no_output, sh_long_term_reference, sh_adaptive_marking, sh_mmco5;
    wire [3:0]  sh_ps;
    wire        sh_ps_v, sh_pts_v;
    wire [32:0] sh_pts;
    wire [15:0] sh_frame_num, sh_poc_lsb;
    wire [31:0] sh_delta_poc_bottom, sh_delta_poc0, sh_delta_poc1;
    wire [5:0]  sh_num_ref_l0, sh_num_ref_l1, sh_qp, sh_n_mods_l0, sh_n_mods_l1;
    wire [2:0]  sh_luma_log2_wd, sh_chroma_log2_wd;
    wire signed [4:0] sh_alpha_off, sh_beta_off;
    wire [6:0]  sh_n_mmco;
    wire [5:0]  wt_addr;
    wire [50:0] wt_data;
    wire [6:0]  mod_addr;
    wire [33:0] mod_data;
    wire [5:0]  mmco_addr;
    wire [66:0] mmco_data;
    wire [7:0]  poc1_addr;
    wire [31:0] poc1_data, poc1_total;
    wire        e_no_pps, e_no_sps, e_poc1, e_mmco_ovf;
    wire        sh_sflat;                  // High: the slice's scaling matrix (flat, or recon_hdr's RAMs)
    wire [4:0]  sl4_ra, sl8_ra;
    wire [31:0] sl4_q, sl8_q;
    recon_hdr u_hdr (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .se_valid(hq_valid && !clear), .se_kind(hq_kind), .se_aux(hq_aux), .se_val(hq_val), .hdr_end(hq_end),
        .slice_ready(slice_ready), .sps(sps_w), .sps_colour(sps_col), .sps_siting(sps_sit), .pps(pps_w), .sh_first_mb(sh_first_mb), .sh_slice_type(sh_slice_type),
        .sh_nal_ref_idc(sh_nal_ref_idc), .sh_idr(sh_idr), .sh_frame_num(sh_frame_num), .sh_field_pic(sh_field_pic),
        .sh_bottom_field(sh_bottom_field), .sh_poc_lsb(sh_poc_lsb), .sh_delta_poc_bottom(sh_delta_poc_bottom),
        .sh_delta_poc0(sh_delta_poc0), .sh_delta_poc1(sh_delta_poc1), .sh_direct_spatial(sh_direct_spatial),
        .sh_num_ref_l0(sh_num_ref_l0), .sh_num_ref_l1(sh_num_ref_l1), .sh_luma_log2_wd(sh_luma_log2_wd),
        .sh_chroma_log2_wd(sh_chroma_log2_wd), .sh_has_weights(sh_has_weights),
        .sh_no_output_of_prior_pics(sh_no_output), .sh_long_term_reference(sh_long_term_reference),
        .sh_pic_struct(sh_ps), .sh_pic_struct_v(sh_ps_v), .sh_pts(sh_pts), .sh_pts_v(sh_pts_v),
        .sh_adaptive_marking(sh_adaptive_marking), .sh_mmco5(sh_mmco5), .sh_qp(sh_qp),
        .sh_disable_deblock(sh_disable_deblock), .sh_alpha_off(sh_alpha_off), .sh_beta_off(sh_beta_off),
        .sh_n_mods_l0(sh_n_mods_l0), .sh_n_mods_l1(sh_n_mods_l1), .sh_n_mmco(sh_n_mmco),
        .sh_sflat(sh_sflat), .sl4_ra(sl4_ra), .sl4_q(sl4_q), .sl8_ra(sl8_ra), .sl8_q(sl8_q),
        .wt_addr(wt_addr), .wt_data(wt_data), .mod_addr(mod_addr), .mod_data(mod_data),
        .mmco_addr(mmco_addr), .mmco_data(mmco_data), .poc1_addr(poc1_addr), .poc1_data(poc1_data), .poc1_total(poc1_total),
        .err_no_pps(e_no_pps), .err_no_sps(e_no_sps), .err_poc1(e_poc1), .err_mmco_ovf(e_mmco_ovf));

    // ---- recon_dpb / recon_lists ---------------------------------------------------------------------
    // the picture bound, decided BEFORE recon_dpb opens a picture: recon_hdr registers the
    // active SPS on the edge that pulses slice_ready (held until the next slice); the size is
    // registered in three steps -- the sides (sz_w / sz_h), their product, the compare -- so
    // recon_dpb takes the slice three cycles after slice_ready (sr_d3), or never (a refused slice:
    // R_SLICE_WAIT discards it). (perf/retime, 2026-10-13: the product and the compare in one
    // cycle with the hand-off were clk_dec's largest census cluster; two cycles a slice are free)
    logic        sr_d1, sr_d2, sr_d3;
    logic [7:0]  sz_w, sz_h;
    logic [20:0] sz_prod;
    logic        sz_over;                       // Level 3.1's MaxFS (Table A-1): sz_prod > 3,600
    wire         dpb_slice_ready = sr_d3 && !sz_over;
    wire        pipe_idle;
    wire        d_pic_start, d_pic_new, lists_go, lists_done, slice_go, dpb_busy;
    wire [4:0]  d_store;
    wire [1:0]  d_struct;
    wire        d_isref;
    wire signed [31:0] cur_poc;
    wire [NSTORE*2-1:0]  st_ref_t, st_ref_b;
    wire [NSTORE-1:0] st_dec_t, st_dec_b, st_frame, st_busy;
    wire [4:0]  tab_ra_lists, tab_ra_slice;
    wire signed [31:0] tab_q_poc_t, tab_q_poc_b, tab_q_fnw;
    wire [NSTORE*5-1:0]  st_lt;
    wire        e_gap, e_no_store, e_window, e_mmco, e_mod;
    logic       dpb_eos;
    recon_dpb #(.STALL_LIMIT(STALL_LIMIT)) u_dpb (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .slice_ready(dpb_slice_ready), .sps(sps_w), .pps(pps_w), .sh_first_mb(sh_first_mb), .sh_slice_type(sh_slice_type),
        .sh_nal_ref_idc(sh_nal_ref_idc), .sh_idr(sh_idr), .sh_frame_num(sh_frame_num), .sh_field_pic(sh_field_pic),
        .sh_bottom_field(sh_bottom_field), .sh_poc_lsb(sh_poc_lsb), .sh_delta_poc_bottom(sh_delta_poc_bottom),
        .sh_delta_poc0(sh_delta_poc0), .sh_delta_poc1(sh_delta_poc1), .sh_long_term_reference(sh_long_term_reference),
        .sh_adaptive_marking(sh_adaptive_marking), .sh_mmco5(sh_mmco5), .sh_n_mmco(sh_n_mmco),
        .sh_no_output_of_prior_pics(sh_no_output),
        .mmco_addr(mmco_addr), .mmco_data(mmco_data), .poc1_addr(poc1_addr), .poc1_data(poc1_data), .poc1_total(poc1_total),
        .pipe_idle(pipe_idle), .disp_hold(disp_hold), .disp_frz(disp_frz),
        .pic_start(d_pic_start), .pic_new(d_pic_new), .cur_store(d_store), .cur_struct(d_struct), .cur_isref(d_isref),
        .cur_poc(cur_poc), .lists_go(lists_go), .lists_done(lists_done), .slice_go(slice_go), .busy(dpb_busy),
        .st_ref_t(st_ref_t), .st_ref_b(st_ref_b), .st_dec_t(st_dec_t), .st_dec_b(st_dec_b), .st_lt(st_lt), .st_frame(st_frame), .st_busy(st_busy),
        .tab_ra_lists(tab_ra_lists), .tab_ra_slice(tab_ra_slice), .tab_q_poc_t(tab_q_poc_t), .tab_q_poc_b(tab_q_poc_b), .tab_q_fnw(tab_q_fnw),
        .eos(dpb_eos), .eos_done(eos_done), .emit_valid(emit_valid), .emit_store(emit_store),
        .emit_unpaired(emit_unpaired), .emit_first_bot(emit_first_bot), .emit_frame(emit_frame),
        .emit_dec_t(emit_dec_t), .emit_dec_b(emit_dec_b), .emit_poc_t(emit_poc_t), .emit_poc_b(emit_poc_b),
        .out_dropped(out_dropped), .out_direct(out_direct), .out_over(out_over), .nrf_late(nrf_late), .stall_cycles(stall_cycles),
        .dpb_fill(dpb_fill),
        .err_gap(e_gap), .err_no_store(e_no_store), .err_window(e_window), .err_mmco(e_mmco));

    wire [5:0]  l0_idx, l1_idx;
    wire [7:0]  l0_entry, l1_entry;
    recon_lists u_lists (
        .clk(clk), .rst_n(rst_n), .go(lists_go), .done(lists_done),
        .slice_type(sh_slice_type), .field_pic(sh_field_pic), .bottom(sh_bottom_field), .cur_store(d_store),
        .cur_poc(cur_poc), .frame_num(sh_frame_num), .log2_max_frame_num(sps.log2_max_frame_num_minus4 + 4'd4),
        .num_ref_l0(sh_num_ref_l0), .num_ref_l1(sh_num_ref_l1), .n_mods_l0(sh_n_mods_l0), .n_mods_l1(sh_n_mods_l1),
        .mod_addr(mod_addr), .mod_data(mod_data),
        .st_ref_t(st_ref_t), .st_ref_b(st_ref_b), .st_dec_t(st_dec_t), .st_dec_b(st_dec_b), .st_lt(st_lt),
        .tab_ra(tab_ra_lists), .tab_q_poc_t(tab_q_poc_t), .tab_q_poc_b(tab_q_poc_b), .tab_q_fnw(tab_q_fnw),
        .rd0_idx(l0_idx), .rd0_entry(l0_entry), .rd1_idx(l1_idx), .rd1_entry(l1_entry), .err_mod(e_mod));

    // ---- recon_slice_tab ---------------------------------------------------------------------------------
    logic        tab_go;
    wire         tab_done, tab_busy;
    wire [4:0]  code_ra0, code_ra1;
    wire [7:0]  code_q0, code_q1;
    wire [4:0]  poc_ra0, poc_ra1;
    wire [31:0] poc_q0, poc_q1;
    wire [31:0] lng0, lng1, tdir_raw;
    wire [4:0]  col_store;
    wire [1:0]  col_half, vert_scale;
    wire        col_is_field, l1_0_short;
    wire [4:0]  dsf_ra;
    wire signed [10:0] dsf_q;
    wire [6:0]  map_ra;
    wire [5:0]  map_q;
    recon_slice_tab u_tab (
        .clk(clk), .rst_n(rst_n), .go(tab_go), .done(tab_done), .busy(tab_busy),
        .slice_type(sh_slice_type), .field_pic(sh_field_pic), .cur_struct(d_struct), .cur_poc(cur_poc),
        .num_ref_l0(sh_num_ref_l0), .num_ref_l1(sh_num_ref_l1),
        .l0_idx(l0_idx), .l0_entry(l0_entry), .l1_idx(l1_idx), .l1_entry(l1_entry),
        .st_ref_t(st_ref_t), .st_ref_b(st_ref_b), .tab_ra(tab_ra_slice), .tab_q_poc_t(tab_q_poc_t), .tab_q_poc_b(tab_q_poc_b), .st_frame(st_frame),
        .code_ra0(code_ra0), .code_ra1(code_ra1), .code_q0(code_q0), .code_q1(code_q1),
        .poc_ra0(poc_ra0), .poc_ra1(poc_ra1), .poc_q0(poc_q0), .poc_q1(poc_q1), .lng(lng0), .lng1(lng1), .col_store(col_store), .col_half(col_half),
        .col_is_field(col_is_field), .vert_scale(vert_scale), .l1_0_short(l1_0_short),
        .dsf_ra(dsf_ra), .dsf_q(dsf_q), .tdir_raw(tdir_raw), .map_ra(map_ra), .map_q(map_q));

    // ---- geometry per slice ----------------------------------------------------------------------------------
    wire [7:0]  w_mbs = {1'b0, sps.width_mbs_minus1} + 8'd1;
    wire [7:0]  hf_mbs = sps.frame_mbs_only ? ({1'b0, sps.height_map_units_minus1} + 8'd1)
                                            : ({sps.height_map_units_minus1, 1'b0} + 8'd2);
    logic [20:0] plane_mbs;

    // ---- (0.16, docs/colour.md) the picture's colour code ------------------------------------------------------
    // Registered every cycle from the held slice state (sps, sps_col: stable from slice_ready) and the stream's
    // quasi-static override: two clocks behind slice_ready, long before recon_dpb opens the picture (d_pic_start).
    // The size rule on the CROPPED size (CropUnitX 2, CropUnitY 2 or 4: 4:2:0): >= 1,280 wide or > 576 high is HD.
    logic [12:0] cs_w, cs_h;
    logic        cs_hd;
    logic [2:0]  cs_code;
    logic        cs_unsup;
    wire  [7:0]  cs_m    = sps_col[25] ? sps_col[7:0] : 8'd2;   // colour_description_present_flag 0: unspecified
    wire  [10:0] cs_lr   = {1'b0, sps.crop_left} + {1'b0, sps.crop_right};
    wire  [10:0] cs_tb   = {1'b0, sps.crop_top} + {1'b0, sps.crop_bottom};
    logic [1:0]  cs_mat;                   // 0 BT.601, 1 BT.709, 2 BT.2020 (ncl)
    logic        cs_bysize, cs_bad;
    always_comb begin
        cs_mat = 2'd0; cs_bysize = 1'b0; cs_bad = 1'b0;
        case (cs_m)                        // Table E-5
            8'd1, 8'd7:       cs_mat = 2'd1;            // BT.709; SMPTE 240M as 709 (spec_hardening.md)
            8'd4, 8'd5, 8'd6: cs_mat = 2'd0;            // FCC as 601; BT.470BG; SMPTE 170M
            8'd9:             cs_mat = 2'd2;            // BT.2020 non-constant luminance
            8'd2, 8'd3:       cs_bysize = 1'b1;         // unspecified; reserved
            default:          begin cs_bysize = 1'b1; cs_bad = 1'b1; end   // GBR, YCgCo, 2020 cl, 11+: counted
        endcase
        if (cs_bysize) cs_mat = cs_hd ? 2'd1 : 2'd0;
    end
    always_ff @(posedge clk) begin
        cs_w  <= {1'b0, w_mbs, 4'd0}  - (sps.frame_cropping ? {1'b0, cs_lr, 1'b0} : 13'd0);
        cs_h  <= {1'b0, hf_mbs, 4'd0} - (!sps.frame_cropping ? 13'd0 : sps.frame_mbs_only ? {1'b0, cs_tb, 1'b0} : {cs_tb, 2'b00});
        cs_hd <= (cs_w >= 13'd1280) || (cs_h > 13'd576);
        if (stream_colour >= 3'd1 && stream_colour <= 3'd6) begin cs_code <= stream_colour; cs_unsup <= 1'b0; end
        else begin cs_code <= 3'd1 + {cs_mat, 1'b0} + {2'd0, sps_col[24]}; cs_unsup <= cs_bad; end
    end

    // ---- mb_intake --------------------------------------------------------------------------------------------
    logic        in_valid;
    wire         in_ready;
    wire         mb_valid, mb_release, mb_skip, mb_is_intra, mb_eos, mb_pcm, mb_t8, e_order;
    wire [13:0]  mb_addr;
    wire [5:0]   mb_type, mb_cbp;
    wire [15:0]  mb_sub_types, mb_prev_flag, mb_nz;
    wire [4:0]   mb_itype;
    wire signed [7:0] mb_qp_delta;
    wire [1:0]   mb_chroma_mode;
    wire [47:0]  mb_rem_mode;
    wire [39:0]  mb_refs;
    wire [4:0]   mvd_ra;
    wire [31:0]  mvd_q;
    wire [31:0]  mb_pred;
    wire [3:0]   mb_direct8;
    wire [26:0]  mb_coded;
    wire [8:0]   coef_addr;
    wire [1:0]   mb_cbank, coef_bank;     // exp/mb-pipeline: the intake's coefficient banks
    wire signed [15:0] coef_data;
    mb_intake u_in (
        .clk(clk), .rst_n(rst_n), .slice_type(sh_slice_type), .num_ref_l0(sh_num_ref_l0), .num_ref_l1(sh_num_ref_l1),
        .in_valid(in_valid), .in_ready(in_ready), .in_kind(w_kind), .in_aux(w_aux), .in_val(w_val[15:0]),
        .mb_valid(mb_valid), .mb_release(mb_release), .mb_addr(mb_addr), .mb_skip(mb_skip), .mb_type(mb_type),
        .mb_sub_types(mb_sub_types), .mb_is_intra(mb_is_intra), .mb_itype(mb_itype), .mb_cbp(mb_cbp),
        .mb_qp_delta(mb_qp_delta), .mb_chroma_mode(mb_chroma_mode), .mb_end_of_slice(mb_eos),
        .mb_prev_flag(mb_prev_flag), .mb_rem_mode(mb_rem_mode), .mb_refs(mb_refs), .mvd_ra(mvd_ra), .mvd_q(mvd_q), .mb_pred(mb_pred),
        .mb_direct8(mb_direct8), .mb_coded(mb_coded), .mb_nz(mb_nz), .mb_pcm(mb_pcm), .mb_t8(mb_t8),
        .mb_cbank(mb_cbank), .coef_bank(coef_bank), .coef_addr(coef_addr), .coef_data(coef_data), .err_order(e_order));

    // ---- recon_mb --------------------------------------------------------------------------------------------------
    logic        mb_slice_go;
    wire         m_cmd_valid, m_cmd_write, m_wd_valid, m_rd_ready, m_idle, m_mb_done;
    wire [28:0]  m_cmd_addr;
    wire [3:0]   m_cmd_len;
    wire [63:0]  m_wd_data;
    wire [7:0]   m_wd_be;
    wire         c_cmd_ready, c_wd_ready, c_rd_valid;
    wire [63:0]  c_rd_data;
    wire [13:0]  m_done_addr;
    wire [31:0]  m_err;
    wire [3:0]   m_err_code;
    recon_mb u_mb (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .slice_go(mb_slice_go), .slice_type(sh_slice_type), .slice_qp(sh_qp), .disable_deblock(sh_disable_deblock),
        .sflat(sh_sflat), .sl4_ra(sl4_ra), .sl4_q(sl4_q), .sl8_ra(sl8_ra), .sl8_q(sl8_q),
        .alpha_off(sh_alpha_off), .beta_off(sh_beta_off), .direct_spatial(sh_direct_spatial),
        .num_ref_l0(sh_num_ref_l0), .num_ref_l1(sh_num_ref_l1), .luma_log2_wd(sh_luma_log2_wd),
        .chroma_log2_wd(sh_chroma_log2_wd), .weighted_pred(pps.weighted_pred), .weighted_bipred_idc(pps.weighted_bipred_idc),
        .constrained_intra(pps.constrained_intra_pred), .cb_qp_off(pps.chroma_qp_index_offset),
        .cr_qp_off(pps.second_chroma_qp_index_offset), .width_mbs(width_mbs), .frame_height_mbs(frame_height_mbs),   // registered (R_SLICE_WAIT), before mb_slice_go
        .direct_8x8_inf(sps.direct_8x8_inference), .field_pic(sh_field_pic), .bottom(sh_bottom_field),
        .cur_store(d_store), .cur_poc(cur_poc), .dpb_base(DPB_BASE), .plane_mbs(plane_mbs),
        .code_ra0(code_ra0), .code_ra1(code_ra1), .code_q0(code_q0), .code_q1(code_q1),
        .poc_ra0(poc_ra0), .poc_ra1(poc_ra1), .poc_q0(poc_q0), .poc_q1(poc_q1), .lng0(lng0), .lng1(lng1), .col_store(col_store), .col_half(col_half),
        .vert_scale(vert_scale), .l1_0_short(l1_0_short), .dsf_ra(dsf_ra), .dsf_q(dsf_q), .tdir_raw(tdir_raw), .map_ra(map_ra), .map_q(map_q),
        .wt_addr(wt_addr), .wt_data(wt_data),
        .mb_valid(mb_valid), .mb_release(mb_release), .mb_addr(mb_addr), .mb_skip(mb_skip), .mb_type(mb_type),
        .mb_sub_types(mb_sub_types), .mb_is_intra(mb_is_intra), .mb_itype(mb_itype), .mb_cbp(mb_cbp),
        .mb_qp_delta(mb_qp_delta), .mb_chroma_mode(mb_chroma_mode), .mb_prev_flag(mb_prev_flag),
        .mb_rem_mode(mb_rem_mode), .mb_refs(mb_refs), .mvd_ra(mvd_ra), .mvd_q(mvd_q), .mb_direct8(mb_direct8),
        .mb_coded(mb_coded), .mb_nz(mb_nz), .mb_pcm(mb_pcm), .mb_t8(mb_t8), .mb_cbank(mb_cbank), .coef_bank(coef_bank), .coef_addr(coef_addr), .coef_data(coef_data),
        .cmd_valid(m_cmd_valid), .cmd_ready(c_cmd_ready), .cmd_write(m_cmd_write), .cmd_addr(m_cmd_addr), .cmd_len(m_cmd_len),
        .wd_valid(m_wd_valid), .wd_ready(c_wd_ready), .wd_data(m_wd_data), .wd_be(m_wd_be),
        .rd_valid(c_rd_valid), .rd_data(c_rd_data), .rd_ready(m_rd_ready),
        .idle(m_idle), .mb_done(m_mb_done), .mb_done_addr(m_done_addr), .mb_count(mb_count),
        .err_count(m_err), .err_code(m_err_code), .dbg_pre_db(), .dbg_bank());
    wire         m_wr_drained;           // every write burst accepted by the port (dpb_mem): a NAL
                                         // boundary waits for it too, not only a picture's release
                                         // (a few cycles a slice; the release is what needs it)
    assign pipe_idle = m_idle && !mb_valid && !m_cmd_valid && !m_wd_valid && !mb_release && m_wr_drained;

    // ---- dpb_mem ------------------------------------------------------------------------------------------------------
    wire [31:0] stat_reads, stat_writes;
    dpb_mem u_mem (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(m_cmd_valid), .cmd_ready(c_cmd_ready), .cmd_write(m_cmd_write), .cmd_addr(m_cmd_addr), .cmd_len(m_cmd_len),
        .wd_valid(m_wd_valid), .wd_ready(c_wd_ready), .wd_data(m_wd_data), .wd_be(m_wd_be),
        .rd_valid(c_rd_valid), .rd_data(c_rd_data), .rd_ready(m_rd_ready),
        .stat_reads(stat_reads), .stat_writes(stat_writes), .wr_drained(m_wr_drained),
        .mclk(mclk), .mrst_n(mrst_n),
        .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
        .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
        .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));

    // =====================================================================================
    // the router
    // =====================================================================================
    typedef enum logic [2:0] {R_RUN, R_NAL_WAIT, R_SLICE_WAIT, R_SIZE, R_TAB_WAIT, R_DISCARD} rstate_t;
    rstate_t rs;
    logic    in_slice_hdr;                 // header words of a slice seen, its first MB not yet
    logic    refuse_pic;
    logic    had_pic;
    // recon_mb counts its own errors (1 a reference index naming no list entry / a
    // temporal co-located reference outside list 0 -- mv_pred; 2 a list entry with no
    // picture -- recon_inter): a change of its count is one more error here (11 / 12)
    logic [31:0] m_err_q;
    // the pipeline idle for three registered cycles: a NAL word waits for it (the idle AND
    // straight into the header unit's enables missed clk_dec; once idle with the NAL word
    // held, nothing re-enters the pipeline)
    logic [1:0]  idle_run;
    wire         idle3 = (idle_run == 2'd3);
    wire         e_mb = (m_err != m_err_q);

    always_comb begin
        sf_rd = 1'b0; h_valid = 1'b0; in_valid = 1'b0;
        case (rs)
            R_RUN: if (sf_valid) begin
                if (w_kind == K_NAL_WORD) begin
                    // held until the pipeline is idle (R_NAL_WAIT), then taken below
                end else if (w_kind == K_HDR_WORD) begin
                    h_valid = 1'b1; sf_rd = 1'b1;
                end else if (w_kind == K_EOS_WORD) begin
                    // end of stream: never a macroblock word -- recon_dpb closes the last
                    // picture and emits everything waiting (P5d)
                    sf_rd = 1'b1;
                end else if (w_kind == 8'd1 && in_slice_hdr) begin
                    // the first macroblock of a slice: its header is complete (hdr_end)
                end else begin
                    in_valid = 1'b1; sf_rd = in_ready;
                end
            end
            R_NAL_WAIT: if (sf_valid && idle3 && !dpb_busy) begin h_valid = 1'b1; sf_rd = 1'b1; end
            R_DISCARD: if (sf_valid && !(w_kind == K_NAL_WORD)) sf_rd = 1'b1;   // (an EOS too: below)
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs <= R_RUN; in_slice_hdr <= 1'b0; hdr_end <= 1'b0; tab_go <= 1'b0; mb_slice_go <= 1'b0;
            refuse_pic <= 1'b0; plane_mbs <= '0; sr_d1 <= 1'b0; sr_d2 <= 1'b0; sr_d3 <= 1'b0; sz_w <= '0; sz_h <= '0; sz_over <= 1'b0; sz_prod <= '0; pic_count <= '0; err_count <= '0; err_code <= '0; ref_size <= '0;
            pic_start <= 1'b0; cur_store <= '0; cur_struct <= '0; pic_done <= 1'b0; done_store <= '0; done_struct <= '0;
            width_mbs <= '0; frame_height_mbs <= '0; aspect_idc <= '0; sar_w <= '0; sar_h <= '0; had_pic <= 1'b0; idle <= 1'b1; m_err_q <= '0; idle_run <= '0;
            dpb_eos <= 1'b0; pinfo_we <= 1'b0; pinfo_store <= '0; pinfo_second <= 1'b0; pinfo_w_mbs <= '0; pinfo_hf_mbs <= '0; pinfo_aspect <= '0;
            pinfo_crop <= '0; pinfo_timing_v <= 1'b0; pinfo_nuit <= '0; pinfo_ts <= '0; pinfo_ps <= '0; pinfo_ps_v <= 1'b0;
            pinfo_pts <= '0; pinfo_pts_v <= 1'b0; pinfo_idr <= 1'b0;
            pinfo_colour <= 3'd1; pinfo_col_unsup <= 1'b0; pinfo_col_tags <= {1'b0, 1'b0, 8'd2, 8'd2, 8'd2}; pinfo_siting <= 6'd0;
        end else begin
            // P5d: an end-of-stream word consumed -> recon_dpb closes and flushes
            dpb_eos <= sf_rd && sf_valid && (w_kind == K_EOS_WORD);
            sr_d1 <= slice_ready; sr_d2 <= sr_d1; sr_d3 <= sr_d2;
            sz_w <= w_mbs; sz_h <= hf_mbs;
            sz_prod <= {13'd0, sz_w} * {13'd0, sz_h};
            sz_over <= (sz_prod > 21'd3600);
            pinfo_we <= 1'b0;
            m_err_q <= m_err;
            idle_run <= !pipe_idle ? 2'd0 : (idle_run == 2'd3) ? 2'd3 : idle_run + 2'd1;
            hdr_end <= 1'b0; tab_go <= 1'b0; mb_slice_go <= 1'b0; pic_start <= 1'b0; pic_done <= 1'b0;
            idle <= pipe_idle && (rs == R_RUN) && !sf_valid;
            // errors from every unit (pulses), the last code kept
            if (e_no_pps || e_no_sps || e_poc1 || e_mmco_ovf || e_gap || e_no_store || e_window || e_mmco || e_mod || e_order || e_mb) begin
                err_count <= err_count + 1'b1;
                err_code <= e_no_pps ? 4'd1 : e_no_sps ? 4'd2 : e_poc1 ? 4'd3 : e_mmco_ovf ? 4'd4 : e_gap ? 4'd5 :
                            e_no_store ? 4'd6 : e_window ? 4'd7 : e_mmco ? 4'd8 : e_mod ? 4'd9 : e_order ? 4'd10 :
                            (m_err_code == 4'd1) ? 4'd11 : 4'd12;
            end
            if (d_pic_start) begin
                // the previous picture is complete: every one of its writes was issued before
                // recon_dpb could open this one (pipe_idle)
                if (had_pic) begin pic_done <= 1'b1; done_store <= cur_store; done_struct <= cur_struct; end
                had_pic <= 1'b1;
                pic_start <= 1'b1; cur_store <= d_store; cur_struct <= d_struct; pic_count <= pic_count + 1'b1;
                // P5d: the picture's display facts, by store (its second field: the "b" half)
                pinfo_we <= 1'b1; pinfo_store <= d_store;
                pinfo_second <= had_pic && (d_struct != 2'd0) && (cur_struct != 2'd0) && (d_store == cur_store) &&
                                (d_struct != cur_struct);
                pinfo_w_mbs <= w_mbs; pinfo_hf_mbs <= hf_mbs;
                pinfo_aspect <= {sps.aspect_ratio_idc, sps.sar_width, sps.sar_height};
                pinfo_colour <= cs_code; pinfo_col_unsup <= cs_unsup; pinfo_col_tags <= sps_col; pinfo_siting <= sps_sit;
                pinfo_crop <= sps.frame_cropping ? {!sps.frame_mbs_only, sps.crop_left, sps.crop_right, sps.crop_top, sps.crop_bottom} : 41'd0;
                pinfo_timing_v <= sps.timing_present; pinfo_nuit <= sps.num_units_in_tick; pinfo_ts <= sps.time_scale;
                pinfo_ps <= sh_ps; pinfo_ps_v <= sh_ps_v; pinfo_pts <= sh_pts; pinfo_pts_v <= sh_pts_v;
                pinfo_idr <= sh_idr;
            end
            // P5d: the end of stream closed the last picture: it is complete too
            if (eos_done && had_pic) begin
                pic_done <= 1'b1; done_store <= cur_store; done_struct <= cur_struct; had_pic <= 1'b0;
            end
            if (clear) begin
                rs <= R_RUN; in_slice_hdr <= 1'b0; had_pic <= 1'b0;
            end else case (rs)
                R_RUN: if (sf_valid) begin
                    if (w_kind == K_NAL_WORD) rs <= R_NAL_WAIT;
                    else if (w_kind == K_HDR_WORD) begin
                        // (taken combinationally)
                    end else if (w_kind == 8'd1 && in_slice_hdr) begin
                        in_slice_hdr <= 1'b0;
                        hdr_end <= 1'b1;
                        rs <= R_SLICE_WAIT;
                    end
                end
                R_NAL_WAIT: if (sf_valid && idle3 && !dpb_busy) begin
                    in_slice_hdr <= (w_aux[4:0] == 5'd1 || w_aux[4:0] == 5'd5);
                    rs <= R_RUN;
                end
                R_SLICE_WAIT: if (sr_d3 && sz_over) begin
                    // above Level 3.1's MaxFS: never handed to recon_dpb (no store, no output)
                    ref_size <= ref_size + 1'b1;
                    rs <= R_DISCARD;
                end else if (slice_go) begin
                    plane_mbs <= sz_prod;
                    width_mbs <= w_mbs; frame_height_mbs <= hf_mbs;
                    aspect_idc <= sps.aspect_ratio_idc; sar_w <= sps.sar_width; sar_h <= sps.sar_height;
                    rs <= R_SIZE;
                end
                R_SIZE: begin                       // (the geometry registered first)
                    if (sh_slice_type == 2'd2) begin
                        mb_slice_go <= 1'b1; rs <= R_RUN;
                    end else begin
                        tab_go <= 1'b1; rs <= R_TAB_WAIT;
                    end
                end
                R_TAB_WAIT: if (tab_done) begin mb_slice_go <= 1'b1; rs <= R_RUN; end
                R_DISCARD: if (sf_valid && w_kind == K_NAL_WORD) rs <= R_NAL_WAIT;
                           else if (sf_valid && w_kind == K_EOS_WORD) rs <= R_RUN;
                default: rs <= R_RUN;
            endcase
        end
    end

endmodule

`default_nettype wire
