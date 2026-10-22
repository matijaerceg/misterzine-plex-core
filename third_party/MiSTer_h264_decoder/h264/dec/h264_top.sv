// h264/dec/h264_top.sv -- the H.264 bitstream front end: Annex-B video ES in, one
// typed syntax-element stream out (docs/h264_frontend.md S5)
//
//   es bytes -> nal_parser -> [NAL header: this module]
//                          -> rbsp_reader -> sps_pps   (types 7, 8)
//                                         -> slice_hdr (types 1, 5) -> cabac_engine <- mb_syntax
//                          -> drained (every other type; the rest of a refused or
//                             failed NAL unit; the bytes past a slice's end)
//
// Per NAL unit: the header byte is read here (K_NAL_WORD out: type, nal_ref_idc), the
// payload is routed by type. A parameter set is parsed and stored. A slice: the
// header is parsed (its fields out as K_HDR_WORDs), sps_pps emits the slice's resolved
// scaling matrix (High profile, docs/high_profile.md S3: one word when flat, 57
// otherwise), then the engine is FLUSHed (its
// read-ahead of the previous NAL unit must not leak in), the remaining bytes are
// routed to it, INIT(set, QP) issued, and mb_syntax started; when it reports done the
// rest of the NAL unit (rbsp_slice_trailing_bits, cabac_zero_words, whatever the
// engine did not fetch) is drained. The SE stream is the concatenation, in order, of
// the NAL word, the header fields and mb_syntax's words (16-bit values sign-extended
// to 32), which is exactly tools/h264_fe_ref.py's record list -- the bench's oracle.
//
// Refusals (a legal feature outside the core's scope) and errors (a stream or state
// violation) are counted separately with the last code of each (h264_pkg.sv); both
// end the NAL unit and the decoder carries on with the next one -- never a hang,
// never garbage decoded as pixels. Data-partitioning and SVC/MVC NAL types are
// refused here by type; AUD, end-of-sequence, filler are skipped.
//
// P5c, the display's per-picture facts (docs/display.md):
//   * SEI (type 6) goes to sei_pt, which walks its messages and keeps a picture timing
//     payload; at the picture's first slice (first_mb_in_slice 0) it is interpreted with
//     that slice's SPS and its fields (cpb_removal_delay, dpb_output_delay, pic_struct)
//     follow the slice header's words.
//   * The PTS: each input byte arrives with {es_mark, es_pts}; a marked byte (the first
//     payload byte of a PES that carried a PTS) pushes a stamp at its position into
//     au_pts. An access unit starts (7.4.1.2.3) at an AUD / SEI / SPS / PPS / 14..18 NAL
//     after a VCL NAL, else at the picture's first slice; au_pts gives it the latest
//     stamp at or before its start code (ISO 13818-1 2.4.3.7). The tag follows the SEI
//     words as au_pts_lo / au_pts_hi. The source-neutral handoff: this module sees ES
//     bytes, marks and PTSs, never a pack or a CLPI.
//   * End of stream: after es_flush has drained through nal_parser and the last NAL
//     unit is done, one K_EOS_WORD -- in band, so it cannot overtake the words before.
//
// The rbsp_reader fetches only on demand, so when the slice header ends (byte
// aligned) nothing of the slice data is buffered anywhere but the nal_parser's
// output register; the engine takes it from there. nal_ended remembers that the
// unit's last byte went to *some* consumer, so a drain after a partial parse cannot
// wait for a byte that was already taken.

`default_nettype none

module h264_top
    import h264_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,              // a new title: counters and parameter sets

    // the video elementary stream (Annex B)
    input  wire  [7:0] es_byte,
    input  wire        es_valid,
    output logic       es_ready,
    input  wire        es_flush,           // end of stream: release the last NAL unit
    input  wire        es_mark,            // with es_byte: the first payload byte of a PES with a PTS
    input  wire [32:0] es_pts,             //   and that PTS (meaningful with es_mark)

    // the syntax-element stream
    output logic       se_valid,
    input  wire        se_ready,
    output logic [7:0] se_kind,
    output logic [7:0] se_aux,
    output logic [31:0] se_val,

    // the slice's parameters, for P4 (held from the slice header to the next one)
    output logic [PPS_W-1:0] sp_pps,
    output logic [SPS_W-1:0] sp_sps,
    output logic [1:0] sp_slice_type,
    output logic       sp_field,
    output logic       sp_bottom,
    output logic       sp_idr,
    output logic [15:0] sp_frame_num,
    output logic [15:0] sp_poc_lsb,

    // telemetry (the HUD)
    output logic       busy,
    output logic [31:0] nal_count,
    output logic [31:0] slice_count,       // slices decoded to their end
    output logic [31:0] pic_count,         // slices with first_mb_in_slice 0
    output logic [31:0] sps_count,
    output logic [31:0] pps_count,
    output logic [31:0] refused_count,
    output logic [3:0] refused_code,       // the last one
    output logic [31:0] err_count,
    output logic [3:0] err_code,
    output logic [39:0] bin_total,         // CABAC bins decoded since clear
    // P5c: the picture timing and PTS telemetry
    output logic [31:0] pt_seen_count,     // pictures with a picture timing SEI
    output logic [31:0] pt_missing_count,  // pictures without one where D.2.3 requires it
    output logic [31:0] pt_bad_count,      // short payloads + Table D-1 / forbidden (pt_struct)
    output logic [31:0] sei_err_count,     // malformed SEI NAL units
    output logic [31:0] pts_tag_count,     // pictures tagged with a PTS
    output logic [31:0] pts_drop_count,    // stamps no access unit started after (au_pts)
    output logic [3:0]  last_pic_struct
);

`include "h264/dec/h264_fields.svh"

    localparam [2:0] K_INIT = 3'd3, K_FLUSH = 3'd7;

    typedef enum logic [4:0] {T_IDLE, T_NAL_EMIT, T_DISPATCH, T_PS, T_SH, T_SL, T_FLUSH, T_FLUSH_WAIT,
                              T_INIT, T_INIT_WAIT, T_MBS_START, T_MBS, T_DRAIN,
                              T_SEI, T_PT_AU, T_PT_WAIT, T_PT_SEI, T_PT_LO, T_PT_HI, T_PT_END, T_EOS} state_t;
    state_t     state;
    logic [4:0] nal_type;
    logic [1:0] nal_ref_idc;
    logic       nal_ended;                 // this unit's last byte has been consumed by someone
    logic       sh_active;                 // the reader belongs to slice_hdr (else sps_pps)
    logic       route_rd, route_eng, route_sei;
    // P5c: access units, the PTS, end of stream
    logic       vcl_last;                  // the last NAL unit was VCL (an opener starts an AU)
    logic       prev_vcl;                  // vcl_last before this NAL unit's header (a slice
                                           // with it set opens its own access unit)
    logic [23:0] nal_sc;                   // this NAL unit's start code position
    logic       au_go;                     // pulse: an access unit starts at au_at
    logic [23:0] au_at;
    logic       eos_pend;

    // ---- nal_parser ----------------------------------------------------------------
    logic [7:0] nb_byte;
    logic       nb_valid, nb_ready, nb_first, nb_last;
    logic [23:0] np_in_pos, np_sc_pos;
    logic       np_flushed;
    nal_parser #(.PW(24)) np (
        .clk(clk), .rst_n(rst_n),
        .in_byte(es_byte), .in_valid(es_valid), .in_ready(es_ready), .in_flush(es_flush),
        .out_byte(nb_byte), .out_valid(nb_valid), .out_ready(nb_ready), .out_first(nb_first), .out_last(nb_last),
        .in_pos(np_in_pos), .out_sc_pos(np_sc_pos), .flushed(np_flushed));

    // ---- the PTS stamps (P5c) --------------------------------------------------------------
    logic        tag_valid, au_busy;
    logic [32:0] tag_pts;
    au_pts #(.DEPTH(4), .PW(24)) apts (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .push(es_valid && es_ready && es_mark), .push_pts(es_pts), .push_pos(np_in_pos),
        .au_start(au_go), .au_pos(au_at), .busy(au_busy),
        .tag_valid(tag_valid), .tag_pts(tag_pts), .drops(pts_drop_count));

    // ---- rbsp_reader, shared by the two header parsers ----------------------------------
    logic        rd_flush, rd_in_valid, rd_in_ready;
    logic        rd_req_valid, rd_req_ready, rd_rsp_valid;
    logic [2:0]  rd_req_kind;
    logic [4:0]  rd_req_n;
    logic [31:0] rd_rsp_val;
    logic        rd_aligned, rd_err_ue, rd_err_align, rd_err_eos;
    wire         rd_err = rd_err_ue | rd_err_align | rd_err_eos;
    rbsp_reader rd (
        .clk(clk), .rst_n(rst_n), .flush(rd_flush),
        .in_byte(nb_byte), .in_valid(rd_in_valid), .in_last(nb_last), .in_ready(rd_in_ready),
        .req_valid(rd_req_valid), .req_ready(rd_req_ready), .req_kind(rd_req_kind), .req_n(rd_req_n),
        .rsp_valid(rd_rsp_valid), .rsp_val(rd_rsp_val),
        .aligned(rd_aligned), .err_ue(rd_err_ue), .err_align(rd_err_align), .err_eos(rd_err_eos));

    // ---- sps_pps ------------------------------------------------------------------
    logic        ps_start, ps_done, ps_refused, ps_err;
    logic [3:0]  ps_code;
    logic        ps_rd_req_valid, ps_se_valid;
    logic [2:0]  ps_rd_req_kind;
    logic [4:0]  ps_rd_req_n;
    logic [7:0]  ps_se_aux;
    logic [31:0] ps_se_val;
    logic [7:0]  pps_rd_id;
    logic [4:0]  sps_rd_id;
    logic [PPS_W-1:0] pps_q;
    logic [SPS_W-1:0] sps_q;
    logic        pps_q_valid, sps_q_valid;
    logic        ps_sl_start, ps_sl_done;
    sps_pps ps (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .start(ps_start), .is_pps(nal_type == 5'd8), .done(ps_done), .refused(ps_refused), .err(ps_err), .code(ps_code),
        .rd_req_valid(ps_rd_req_valid), .rd_req_ready(rd_req_ready && !sh_active), .rd_req_kind(ps_rd_req_kind), .rd_req_n(ps_rd_req_n),
        .rd_rsp_valid(rd_rsp_valid && !sh_active), .rd_rsp_val(rd_rsp_val), .rd_err(rd_err),
        .se_valid(ps_se_valid), .se_ready(se_ready && (state == T_PS || state == T_SL)), .se_aux(ps_se_aux), .se_val(ps_se_val),
        .pps_rd_id(pps_rd_id), .pps_q(pps_q), .pps_q_valid(pps_q_valid),
        .sps_rd_id(sps_rd_id), .sps_q(sps_q), .sps_q_valid(sps_q_valid),
        .sps_count(sps_count), .pps_count(pps_count),
        .sl_start(ps_sl_start), .sl_pps_id(pps_rd_id), .sl_pps(sp_pps), .sl_sps(sp_sps), .sl_done(ps_sl_done));

    // ---- slice_hdr ----------------------------------------------------------------
    logic        sh_start, sh_done, sh_refused, sh_err;
    logic [3:0]  sh_code;
    logic        sh_rd_req_valid, sh_se_valid;
    logic [2:0]  sh_rd_req_kind;
    logic [4:0]  sh_rd_req_n;
    logic [7:0]  sh_se_aux;
    logic [31:0] sh_se_val;
    logic [5:0]  sp_num_ref_l0, sp_num_ref_l1;
    logic [7:0]  sp_width_mbs, sp_height_mbs;
    logic [13:0] sp_first_mb;
    logic [5:0]  sp_qp;
    logic [1:0]  sp_init_set;
    logic        sp_direct_spatial;
    logic [1:0]  sp_disable_deblock;
    logic [3:0]  sp_alpha_div2, sp_beta_div2;
    slice_hdr sh (
        .clk(clk), .rst_n(rst_n),
        .start(sh_start), .nal_type(nal_type), .nal_ref_idc(nal_ref_idc),
        .done(sh_done), .refused(sh_refused), .err(sh_err), .code(sh_code),
        .rd_req_valid(sh_rd_req_valid), .rd_req_ready(rd_req_ready && sh_active), .rd_req_kind(sh_rd_req_kind), .rd_req_n(sh_rd_req_n),
        .rd_rsp_valid(rd_rsp_valid && sh_active), .rd_rsp_val(rd_rsp_val), .rd_err(rd_err),
        .se_valid(sh_se_valid), .se_ready(se_ready && state == T_SH), .se_aux(sh_se_aux), .se_val(sh_se_val),
        .pps_rd_id(pps_rd_id), .pps_q(pps_q), .pps_q_valid(pps_q_valid),
        .sps_rd_id(sps_rd_id), .sps_q(sps_q), .sps_q_valid(sps_q_valid),
        .sp_slice_type(sp_slice_type), .sp_num_ref_l0(sp_num_ref_l0), .sp_num_ref_l1(sp_num_ref_l1),
        .sp_field(sp_field), .sp_bottom(sp_bottom), .sp_width_mbs(sp_width_mbs), .sp_height_mbs(sp_height_mbs),
        .sp_first_mb(sp_first_mb), .sp_qp(sp_qp), .sp_init_set(sp_init_set), .sp_idr(sp_idr),
        .sp_frame_num(sp_frame_num), .sp_poc_lsb(sp_poc_lsb), .sp_direct_spatial(sp_direct_spatial),
        .sp_disable_deblock(sp_disable_deblock), .sp_alpha_div2(sp_alpha_div2), .sp_beta_div2(sp_beta_div2),
        .sp_pps(sp_pps), .sp_sps(sp_sps));

    // ---- sei_pt: the SEI walker + picture timing interpreter (P5c) --------------------------
    logic        sei_start, sei_done, sei_pending, sei_drop, pt_go, pt_done, sei_se_valid;
    logic        sei_err_walk, sei_pt_short, sei_pt_struct;
    logic [7:0]  sei_se_aux;
    logic [31:0] sei_se_val;
    logic        sei_in_ready;
    sps_t        sp_s;
    assign sp_s = sp_sps;
    pps_t        sp_p;
    assign sp_p = sp_pps;
    sei_pt #(.PT_BYTES(9)) sei (
        .clk(clk), .rst_n(rst_n),
        .start(sei_start), .in_byte(nb_byte), .in_valid(route_sei && nb_valid && !nb_first), .in_last(nb_last),
        .in_ready(sei_in_ready), .done(sei_done),
        .pending(sei_pending), .drop(sei_drop),
        .interp_start(pt_go), .cpb_dpb_present(sp_s.cpb_dpb_delays_present),
        .cpb_len_m1(sp_s.cpb_removal_delay_length_minus1), .dpb_len_m1(sp_s.dpb_output_delay_length_minus1),
        .pic_struct_present(sp_s.pic_struct_present), .field_pic(sp_field), .bottom_field(sp_bottom),
        .interp_done(pt_done),
        .se_valid(sei_se_valid), .se_ready(se_ready && state == T_PT_SEI), .se_aux(sei_se_aux), .se_val(sei_se_val),
        .err_walk(sei_err_walk), .pt_short(sei_pt_short), .pt_struct(sei_pt_struct), .last_pic_struct(last_pic_struct));

    // ---- cabac_engine + mb_syntax ------------------------------------------------------
    logic        eng_in_valid, eng_in_ready;
    logic        eng_req_valid, eng_req_ready, eng_rsp_valid, eng_rsp_bin, eng_busy;
    logic [2:0]  eng_req_kind;
    logic [8:0]  eng_req_ctx;
    logic [7:0]  eng_rsp_byte;
    logic        eng_err_init, eng_err_align, eng_err_underrun;
    logic [6:0]  eng_dbg_state;
    logic [31:0] eng_bin_count;
    logic        top_req_valid, mbs_req_valid, mbs_owns;
    logic [2:0]  top_req_kind, mbs_req_kind;
    logic [8:0]  mbs_req_ctx;
    assign eng_req_valid = mbs_owns ? mbs_req_valid : top_req_valid;
    assign eng_req_kind  = mbs_owns ? mbs_req_kind  : top_req_kind;
    assign eng_req_ctx   = mbs_owns ? mbs_req_ctx   : {1'b0, sp_init_set, sp_qp};
    cabac_engine eng (
        .clk(clk), .rst_n(rst_n),
        .in_byte(nb_byte), .in_valid(eng_in_valid), .in_last(nb_last), .in_ready(eng_in_ready),
        .req_valid(eng_req_valid), .req_ready(eng_req_ready), .req_kind(eng_req_kind), .req_ctx(eng_req_ctx),
        .rsp_valid(eng_rsp_valid), .rsp_bin(eng_rsp_bin), .rsp_byte(eng_rsp_byte),
        .busy(eng_busy), .err_init(eng_err_init), .err_align(eng_err_align), .err_underrun(eng_err_underrun),
        .dbg_rd_en(1'b0), .dbg_addr(9'd0), .dbg_state(eng_dbg_state), .bin_count(eng_bin_count));
    wire eng_err = eng_err_init | eng_err_align | eng_err_underrun;

    logic        mbs_start, mbs_done, mbs_err_overrun, mbs_err_bins, mbs_se_valid;
    logic [7:0]  mbs_se_kind, mbs_se_aux;
    logic [15:0] mbs_se_val;
    logic [15:0] slice_id;
    mb_syntax mbs (
        .clk(clk), .rst_n(rst_n),
        .sp_slice_type(sp_slice_type), .sp_num_ref_l0(sp_num_ref_l0), .sp_num_ref_l1(sp_num_ref_l1),
        .sp_field(sp_field), .sp_width_mbs(sp_width_mbs), .sp_height_mbs(sp_height_mbs), .sp_first_mb(sp_first_mb),
        .sp_slice_id(slice_id), .sp_t8_mode(sp_p.transform_8x8_mode), .sp_d8inf(sp_s.direct_8x8_inference),
        .start(mbs_start), .done(mbs_done), .err_overrun(mbs_err_overrun), .err_bins(mbs_err_bins),
        .eng_req_valid(mbs_req_valid), .eng_req_ready(eng_req_ready && mbs_owns), .eng_req_kind(mbs_req_kind),
        .eng_req_ctx(mbs_req_ctx), .eng_rsp_valid(eng_rsp_valid && mbs_owns), .eng_rsp_bin(eng_rsp_bin), .eng_rsp_byte(eng_rsp_byte),
        .se_valid(mbs_se_valid), .se_ready(se_ready && state == T_MBS), .se_kind(mbs_se_kind), .se_aux(mbs_se_aux), .se_val(mbs_se_val));

    // ---- the NAL unit machine (declared first: the instances below use its state) ----------

    // byte routing (nb_first is never routed: the header byte is read in T_IDLE)
    assign rd_in_valid  = route_rd  && nb_valid && !nb_first;
    assign eng_in_valid = route_eng && nb_valid && !nb_first;
    always_comb begin
        nb_ready = 1'b0;
        case (state)
            T_IDLE:  nb_ready = 1'b1;                       // the header byte, or stray bytes
            T_DRAIN: nb_ready = !nb_first && !nal_ended;
            default: begin
                if (route_rd)       nb_ready = rd_in_ready && !nb_first;
                else if (route_eng) nb_ready = eng_in_ready && !nb_first;
                else if (route_sei) nb_ready = sei_in_ready && !nb_first;
            end
        endcase
    end
    wire nb_take = nb_valid && nb_ready;

    // the SE stream: one source at a time
    always_comb begin
        se_valid = 1'b0; se_kind = 8'd0; se_aux = 8'd0; se_val = 32'd0;
        case (state)
            T_NAL_EMIT: begin se_valid = 1'b1; se_kind = K_NAL_WORD; se_aux = {3'd0, nal_type}; se_val = {30'd0, nal_ref_idc}; end
            T_PS, T_SL: begin se_valid = ps_se_valid; se_kind = K_HDR_WORD; se_aux = ps_se_aux; se_val = ps_se_val; end
            T_SH:  begin se_valid = sh_se_valid; se_kind = K_HDR_WORD; se_aux = sh_se_aux; se_val = sh_se_val; end
            T_MBS: begin se_valid = mbs_se_valid; se_kind = mbs_se_kind; se_aux = mbs_se_aux; se_val = {{16{mbs_se_val[15]}}, mbs_se_val}; end
            T_PT_SEI: begin se_valid = sei_se_valid; se_kind = K_HDR_WORD; se_aux = sei_se_aux; se_val = sei_se_val; end
            T_PT_LO:  begin se_valid = 1'b1; se_kind = K_HDR_WORD; se_aux = F_au_pts_lo; se_val = tag_pts[31:0]; end
            T_PT_HI:  begin se_valid = 1'b1; se_kind = K_HDR_WORD; se_aux = F_au_pts_hi; se_val = {31'd0, tag_pts[32]}; end
            T_EOS:    begin se_valid = 1'b1; se_kind = K_EOS_WORD; se_aux = 8'd0; se_val = 32'd0; end
            default: ;
        endcase
    end
    // the reader request port: whichever parser is active
    assign rd_req_valid = sh_active ? sh_rd_req_valid : ps_rd_req_valid;
    assign rd_req_kind  = sh_active ? sh_rd_req_kind  : ps_rd_req_kind;
    assign rd_req_n     = sh_active ? sh_rd_req_n     : ps_rd_req_n;

    assign busy = (state != T_IDLE) || nb_valid || eos_pend;

    wire is_slice   = (nal_type == 5'd1) || (nal_type == 5'd5);
    wire is_ps      = (nal_type == 5'd7) || (nal_type == 5'd8);
    wire is_refused = (nal_type == 5'd2) || (nal_type == 5'd3) || (nal_type == 5'd4) ||
                      (nal_type == 5'd14) || (nal_type == 5'd20);
    // 7.4.1.2.3: these NAL types, after a VCL NAL unit, start the next access unit
    wire [4:0] hdr_type = nb_byte[4:0];
    wire hdr_opener = (hdr_type == 5'd6) || (hdr_type == 5'd7) || (hdr_type == 5'd8) || (hdr_type == 5'd9) ||
                      ((hdr_type >= 5'd14) && (hdr_type <= 5'd18));
    wire hdr_vcl    = (hdr_type == 5'd1) || (hdr_type == 5'd5);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= T_IDLE; nal_type <= 5'd0; nal_ref_idc <= 2'd0; nal_ended <= 1'b0; sh_active <= 1'b0;
            route_rd <= 1'b0; route_eng <= 1'b0; route_sei <= 1'b0; rd_flush <= 1'b0;
            vcl_last <= 1'b1; prev_vcl <= 1'b1; nal_sc <= '0; au_go <= 1'b0; au_at <= '0; eos_pend <= 1'b0;
            sei_start <= 1'b0; sei_drop <= 1'b0; pt_go <= 1'b0;
            pt_seen_count <= '0; pt_missing_count <= '0; pt_bad_count <= '0; sei_err_count <= '0; pts_tag_count <= '0;
            ps_start <= 1'b0; sh_start <= 1'b0; mbs_start <= 1'b0; mbs_owns <= 1'b0; ps_sl_start <= 1'b0;
            top_req_valid <= 1'b0; top_req_kind <= 3'd0; slice_id <= 16'd1;
            nal_count <= 32'd0; slice_count <= 32'd0; pic_count <= 32'd0;
            refused_count <= 32'd0; refused_code <= 4'd0; err_count <= 32'd0; err_code <= 4'd0; bin_total <= 40'd0;
        end else begin
            ps_start <= 1'b0; sh_start <= 1'b0; mbs_start <= 1'b0; rd_flush <= 1'b0; ps_sl_start <= 1'b0;
            sei_start <= 1'b0; sei_drop <= 1'b0; pt_go <= 1'b0; au_go <= 1'b0;
            if (nb_take && nb_last) nal_ended <= 1'b1;
            if (np_flushed) eos_pend <= 1'b1;
            if (sei_err_walk) sei_err_count <= sei_err_count + 32'd1;
            if (sei_pt_short || sei_pt_struct) pt_bad_count <= pt_bad_count + 32'd1;
            if (clear) begin
                nal_count <= 32'd0; slice_count <= 32'd0; pic_count <= 32'd0;
                refused_count <= 32'd0; refused_code <= 4'd0; err_count <= 32'd0; err_code <= 4'd0; bin_total <= 40'd0;
                pt_seen_count <= '0; pt_missing_count <= '0; pt_bad_count <= '0; sei_err_count <= '0; pts_tag_count <= '0;
            end

            case (state)
            T_IDLE: if (eos_pend && !nb_valid && !np_flushed) state <= T_EOS;
            else if (nb_take && nb_first) begin
                nal_type <= nb_byte[4:0]; nal_ref_idc <= nb_byte[6:5];
                nal_ended <= nb_last;
                nal_count <= nal_count + 32'd1;
                nal_sc <= np_sc_pos;
                prev_vcl <= vcl_last;
                // an opener after a VCL NAL unit starts the next access unit, here; its
                // pending picture timing (none can be left from the last one) is dropped
                if (hdr_opener && vcl_last) begin
                    au_go <= 1'b1; au_at <= np_sc_pos; sei_drop <= 1'b1; vcl_last <= 1'b0;
                end
                if (hdr_vcl) vcl_last <= 1'b1;
                if (nb_byte[7]) begin err_count <= err_count + 32'd1; err_code <= ERR_NAL_HDR; end   // forbidden_zero_bit
                state <= T_NAL_EMIT;
            end
            T_NAL_EMIT: if (se_ready) state <= T_DISPATCH;
            T_EOS: if (se_ready) begin eos_pend <= 1'b0; state <= T_IDLE; end
            T_DISPATCH: begin
                if (nal_ended) begin
                    // nothing after the header byte: a parameter set or slice cannot be empty
                    if (is_slice || is_ps) begin err_count <= err_count + 32'd1; err_code <= ERR_EMPTY_NAL; end
                    if (is_refused) begin refused_count <= refused_count + 32'd1; refused_code <= (nal_type >= 5'd14) ? REF_SVC : REF_PARTITION; end
                    state <= T_IDLE;
                end else if (is_ps) begin
                    rd_flush <= 1'b1; route_rd <= 1'b1; sh_active <= 1'b0; ps_start <= 1'b1; state <= T_PS;
                end else if (is_slice) begin
                    rd_flush <= 1'b1; route_rd <= 1'b1; sh_active <= 1'b1; sh_start <= 1'b1; state <= T_SH;
                end else if (nal_type == 5'd6) begin
                    route_sei <= 1'b1; sei_start <= 1'b1; state <= T_SEI;
                end else begin
                    if (is_refused) begin refused_count <= refused_count + 32'd1; refused_code <= (nal_type >= 5'd14) ? REF_SVC : REF_PARTITION; end
                    state <= T_DRAIN;
                end
            end
            T_SEI: if (sei_done) begin route_sei <= 1'b0; state <= T_DRAIN; end
            T_PS: if (ps_done) begin
                if (ps_refused) begin refused_count <= refused_count + 32'd1; refused_code <= ps_code; end
                if (ps_err)     begin err_count <= err_count + 32'd1; err_code <= ps_code; end
                route_rd <= 1'b0; rd_flush <= 1'b1; state <= T_DRAIN;
            end
            T_SH: if (sh_done) begin
                route_rd <= 1'b0;
                if (sh_refused || sh_err) begin
                    if (sh_refused) begin refused_count <= refused_count + 32'd1; refused_code <= sh_code; end
                    else            begin err_count <= err_count + 32'd1; err_code <= sh_code; end
                    rd_flush <= 1'b1; state <= T_DRAIN;
                end else begin
                    ps_sl_start <= 1'b1; state <= T_SL;         // the slice's scaling matrix (High)
                end
            end
            T_SL: if (ps_sl_done) begin
                if (sp_first_mb == 14'd0) begin
                    state <= T_PT_AU;                           // a picture's first slice: its display facts
                end else begin
                    top_req_valid <= 1'b1; top_req_kind <= K_FLUSH; state <= T_FLUSH;
                end
            end
            // ---- P5c: the picture's first slice -- the access unit, its SEI, its PTS
            T_PT_AU: begin
                // no opener since the last VCL NAL: this slice starts the access unit
                // (vcl_last was set by its own header byte, so look at the NAL before it)
                if (prev_vcl) begin au_go <= 1'b1; au_at <= nal_sc; sei_drop <= 1'b1; end
                state <= T_PT_WAIT;
            end
            T_PT_WAIT: if (!au_go && !au_busy) begin
                if (sei_pending) begin
                    pt_seen_count <= pt_seen_count + 32'd1; pt_go <= 1'b1; state <= T_PT_SEI;
                end else begin
                    if (sp_s.pic_struct_present || sp_s.cpb_dpb_delays_present) pt_missing_count <= pt_missing_count + 32'd1;
                    if (tag_valid) state <= T_PT_LO; else state <= T_PT_END;
                end
            end
            T_PT_SEI: if (pt_done) begin if (tag_valid) state <= T_PT_LO; else state <= T_PT_END; end
            T_PT_LO: if (se_ready) state <= T_PT_HI;
            T_PT_HI: if (se_ready) begin pts_tag_count <= pts_tag_count + 32'd1; state <= T_PT_END; end
            T_PT_END: begin top_req_valid <= 1'b1; top_req_kind <= K_FLUSH; state <= T_FLUSH; end
            T_FLUSH: if (eng_req_ready) begin top_req_valid <= 1'b0; state <= T_FLUSH_WAIT; end
            T_FLUSH_WAIT: if (eng_rsp_valid) begin
                if (nal_ended) begin
                    // the header consumed the unit's last byte: no slice data. INIT would
                    // wait for 9 bits the engine can never get (it never sees in_last)
                    err_count <= err_count + 32'd1; err_code <= ERR_EMPTY_NAL;
                    state <= T_DRAIN;
                end else begin
                    route_eng <= 1'b1;
                    top_req_valid <= 1'b1; top_req_kind <= K_INIT; state <= T_INIT;
                end
            end
            T_INIT: if (eng_req_ready) begin top_req_valid <= 1'b0; state <= T_INIT_WAIT; end
            T_INIT_WAIT: if (eng_rsp_valid) begin
                mbs_owns <= 1'b1; mbs_start <= 1'b1; state <= T_MBS_START;
            end
            T_MBS_START: state <= T_MBS;                    // mb_syntax's done (a level) drops on start
            T_MBS: if (mbs_done) begin
                mbs_owns <= 1'b0; route_eng <= 1'b0;
                if (mbs_err_overrun)   begin err_count <= err_count + 32'd1; err_code <= ERR_OVERRUN; end
                else if (mbs_err_bins) begin err_count <= err_count + 32'd1; err_code <= ERR_RANGE; end
                else if (eng_err)      begin err_count <= err_count + 32'd1; err_code <= ERR_ENGINE; end
                else begin
                    slice_count <= slice_count + 32'd1;
                    if (sp_first_mb == 14'd0) pic_count <= pic_count + 32'd1;
                end
                bin_total <= bin_total + {8'd0, eng_bin_count};
                slice_id <= slice_id + 16'd1;
                state <= T_DRAIN;
            end
            T_DRAIN: if (nal_ended) state <= T_IDLE;
            default: state <= T_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
