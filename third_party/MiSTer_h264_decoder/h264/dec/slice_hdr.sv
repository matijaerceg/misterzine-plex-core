// h264/dec/slice_hdr.sv -- the slice header (7.3.3) incl. ref_pic_list_modification
// (7.3.3.1), pred_weight_table (7.3.3.2) and dec_ref_pic_marking (7.3.3.3), for
// frame and field pictures
//
// Field by field in the order of tools/h264_fe_ref.py's parse_slice_header, every
// recorded field out on the SE stream (K_HDR_WORD + its h264_fields.py id, so P4 gets
// the list modifications, the weights and the marking operations in syntax order
// without a second store here), the active PPS and SPS looked up in sps_pps when
// pic_parameter_set_id is known. Ends with the cabac_alignment_one_bit run, after
// which rbsp_reader holds nothing and the parent hands the rest of the NAL unit to
// the CABAC engine. The parameters mb_syntax and the engine need are held on sp_*
// from `done` until the next `start`; the whole active PPS / SPS words are exposed
// for P4 (chroma_qp_index_offset, direct_8x8_inference, constrained_intra_pred...).
//
// Refused (the model's names): SP / SI slices, redundant_pic_cnt > 0. Errors: a PPS
// or SPS never received (or refused), a field outside its 7.4.3 range (slice_type,
// num_ref_idx > 32, cabac_init_idc > 2, SliceQPY outside 0..51, a modification idc
// of 3+ inside the loop, an MMCO above 6, weights and offsets beyond -128..127, ...)
// and any reader error; the parent then drains the NAL unit and counts it.
//
// A loop the stream could run forever (the modification and MMCO loops on a
// truncated NAL unit) ends because the reader flags err_eos on the first bit past
// the last byte and S_WAIT aborts on it.

`default_nettype none

module slice_hdr
    import h264_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,              // pulse: the header follows on the reader
    input  wire  [4:0] nal_type,           // 1 or 5
    input  wire  [1:0] nal_ref_idc,
    output logic       done,               // pulse; refused / err / code valid with it
    output logic       refused,
    output logic       err,
    output logic [3:0] code,

    // rbsp_reader
    output logic       rd_req_valid,
    input  wire        rd_req_ready,
    output logic [2:0] rd_req_kind,
    output logic [4:0] rd_req_n,
    input  wire        rd_rsp_valid,
    input  wire [31:0] rd_rsp_val,
    input  wire        rd_err,

    // header fields, in syntax order
    output logic       se_valid,
    input  wire        se_ready,
    output logic [7:0] se_aux,
    output logic [31:0] se_val,

    // sps_pps lookups
    output logic [7:0] pps_rd_id,
    input  wire [PPS_W-1:0] pps_q,
    input  wire        pps_q_valid,
    output logic [4:0] sps_rd_id,
    input  wire [SPS_W-1:0] sps_q,
    input  wire        sps_q_valid,

    // the slice's parameters (valid from a successful done to the next start)
    output logic [1:0] sp_slice_type,      // 0 P, 1 B, 2 I
    output logic [5:0] sp_num_ref_l0,      // 1..32
    output logic [5:0] sp_num_ref_l1,
    output logic       sp_field,
    output logic       sp_bottom,
    output logic [7:0] sp_width_mbs,
    output logic [7:0] sp_height_mbs,      // of this picture (a field's own)
    output logic [13:0] sp_first_mb,
    output logic [5:0] sp_qp,              // SliceQPY
    output logic [1:0] sp_init_set,        // cabac_init_idc, 3 for I
    output logic       sp_idr,
    output logic [15:0] sp_frame_num,
    output logic [15:0] sp_poc_lsb,
    output logic       sp_direct_spatial,
    output logic [1:0] sp_disable_deblock,
    output logic [3:0] sp_alpha_div2,      // two's complement, -6..6
    output logic [3:0] sp_beta_div2,
    output logic [PPS_W-1:0] sp_pps,       // the active sets, whole
    output logic [SPS_W-1:0] sp_sps
);

`include "h264/dec/h264_fields.svh"

    localparam [2:0] K_BITS = 3'd0, K_UE = 3'd1, K_SE = 3'd2, K_ALIGN1 = 3'd3, K_MORE = 3'd4;
    localparam [1:0] ST_P = 2'd0, ST_B = 2'd1, ST_I = 2'd2;

    typedef logic [6:0] state_t;
    localparam state_t S_IDLE = 7'd0, S_REQ = 7'd1, S_WAIT = 7'd2, S_EMIT = 7'd3, S_FINISH = 7'd4,
        S_FIRST_MB = 7'd10, S_STYPE = 7'd11, S_PPSID = 7'd12, S_PPS_LOOK = 7'd13, S_PPS_LOOK2 = 7'd14,
        S_PPS_GOT = 7'd15, S_SPS_LOOK2 = 7'd16, S_SPS_GOT = 7'd17, S_FIELDPIC = 7'd18, S_BOTTOM = 7'd19,
        S_BOTTOM_CHK = 7'd20, S_IDR = 7'd21, S_IDR_CHK = 7'd22, S_POC = 7'd23, S_POC0_BOT = 7'd24,
        S_POC0_BOT_CHK = 7'd25, S_POC1_1 = 7'd26, S_POC1_CHK = 7'd27, S_REDUNDANT = 7'd28,
        S_REDUNDANT_CHK = 7'd29, S_DIRECT = 7'd30, S_DIRECT_CHK = 7'd31, S_OVERRIDE = 7'd32, S_OVR_BR = 7'd33,
        S_OVR_L1 = 7'd34, S_OVR_L1_CHK = 7'd35, S_MOD_START = 7'd36, S_MOD_FLAG = 7'd37, S_MOD_FLAG_BR = 7'd38,
        S_MOD_IDC = 7'd39, S_MOD_IDC_BR = 7'd40, S_MOD_NEXT = 7'd41, S_WP = 7'd42, S_WP_CD = 7'd43,
        S_WP_START = 7'd44, S_WP_LOOP = 7'd45, S_WP_LWF = 7'd46, S_WP_LW = 7'd47, S_WP_LO = 7'd48,
        S_WP_CWF = 7'd49, S_WP_CWF_BR = 7'd50, S_WP_CW = 7'd51, S_WP_CO = 7'd52, S_WP_C_NEXT = 7'd53,
        S_WP_RI_NEXT = 7'd54, S_WP_NEXTLX = 7'd55, S_MARK = 7'd56, S_MARK_LT = 7'd57, S_MARK_LT_CHK = 7'd58,
        S_MARK_ADAPT_BR = 7'd59, S_MMCO = 7'd60, S_MMCO_BR = 7'd61, S_MMCO3_LT = 7'd62, S_CABAC_INIT = 7'd63,
        S_CABAC_INIT_CHK = 7'd64, S_QPD = 7'd65, S_QPD_CHK = 7'd66, S_DEBLOCK = 7'd67, S_DEBLOCK_BR = 7'd68,
        S_BETA = 7'd69, S_BETA_CHK = 7'd70, S_ALIGN = 7'd71, S_ALIGN_DONE = 7'd72, S_RET = 7'd73;
    state_t state, f_ret;

    logic [2:0]  f_kind;
    logic [4:0]  f_n;
    logic [7:0]  f_id;
    logic [31:0] f_val;
    assign rd_req_valid = (state == S_REQ);
    assign rd_req_kind  = f_kind;
    assign rd_req_n     = f_n;
    assign se_valid     = (state == S_EMIT);
    assign se_aux       = f_id;
    assign se_val       = f_val;
    wire signed [31:0] f_sval = f_val;
    // f_val's range predicates, registered a cycle behind it (P5b: the 32-bit compares in
    // front of the next-state logic were 10.5-10.8 ns). Every check runs at least a cycle
    // after its f_val landed: through S_EMIT (a field with an id), or S_RET (one without)
    logic p_z, p_one, p_u5, p_u7, p_u8, p_u10, p_u14, p_u16, p_s8;
    always_ff @(posedge clk) begin
        p_z   <= (f_val == 32'd0);
        p_one <= (f_val == 32'd1);
        p_u5  <= (f_val[31:5] == 27'd0);
        p_u7  <= (f_val[31:7] == 25'd0);
        p_u8  <= (f_val[31:8] == 24'd0);
        p_u10 <= (f_val[31:10] == 22'd0);
        p_u14 <= (f_val[31:14] == 18'd0);
        p_u16 <= (f_val[31:16] == 16'd0);
        p_s8  <= (f_val[31:7] == 25'd0) || (f_val[31:7] == {25{1'b1}});
    end


`define FIELD(kind, n, id, ret) begin f_kind <= kind; f_n <= n; f_id <= id; f_ret <= ret; state <= S_REQ; end
`define REFUSE(c) begin refused <= 1'b1; code <= c; state <= S_FINISH; end
`define ERROR(c)  begin err <= 1'b1; code <= c; state <= S_FINISH; end

    pps_t p;
    sps_t s;
    assign sp_pps = p;
    assign sp_sps = s;
    pps_t pps_qs;                          // the lookup results, as their structs
    sps_t sps_qs;
    assign pps_qs = pps_q;
    assign sps_qs = sps_q;
    wire [4:0] fn_bits  = {1'b0, sps_qs.log2_max_frame_num_minus4} + 5'd4;   // frame_num is u(v)
    wire [4:0] poc_bits = {1'b0, s.log2_max_poc_lsb_minus4} + 5'd4;
    logic       idr;
    logic       lx;                        // the list being parsed
    logic [5:0] ri;                        // pred_weight_table reference index
    logic       ci;                        // chroma component
    wire [7:0] lx8 = {7'd0, lx};           // the _l1 field id is the _l0 one + 1 (h264_fields.py)
    // SliceQPY = 26 + pic_init_qp_minus26 + slice_qp_delta (7.4.3), checked 0..51
    // registered a cycle behind f_val like the range predicates above (clk_dec 103.85 retime:
    // the add and both compares in front of S_QPD_CHK's next-state logic were 9.0 ns); p is
    // the slice's PPS, loaded at S_PPS_LOOK long before
    wire signed [31:0] qp_sum = 32'sd26 + {{26{p.pic_init_qp_minus26[5]}}, p.pic_init_qp_minus26} + f_sval;
    logic       p_qp_ok;
    logic [5:0] p_qp;
    always_ff @(posedge clk) begin
        p_qp_ok <= !(qp_sum < 32'sd0 || qp_sum > 32'sd51);
        p_qp    <= qp_sum[5:0];
    end
    wire weighted = (p.weighted_pred && sp_slice_type == ST_P) || (p.weighted_bipred_idc == 2'd1 && sp_slice_type == ST_B);
    wire [7:0] frame_height_mbs = s.frame_mbs_only ? {1'b0, s.height_map_units_minus1} + 8'd1
                                                   : {s.height_map_units_minus1, 1'b0} + 8'd2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; f_ret <= S_IDLE; f_kind <= 3'd0; f_n <= 5'd0; f_id <= 8'd0; f_val <= 32'd0;
            done <= 1'b0; refused <= 1'b0; err <= 1'b0; code <= 4'd0;
            p <= '0; s <= '0; idr <= 1'b0; lx <= 1'b0; ri <= 6'd0; ci <= 1'b0;
            pps_rd_id <= 8'd0; sps_rd_id <= 5'd0;
            sp_slice_type <= ST_I; sp_num_ref_l0 <= 6'd1; sp_num_ref_l1 <= 6'd1; sp_field <= 1'b0; sp_bottom <= 1'b0;
            sp_width_mbs <= 8'd1; sp_height_mbs <= 8'd1; sp_first_mb <= 14'd0; sp_qp <= 6'd0; sp_init_set <= 2'd3;
            sp_idr <= 1'b0; sp_frame_num <= 16'd0; sp_poc_lsb <= 16'd0; sp_direct_spatial <= 1'b0;
            sp_disable_deblock <= 2'd0; sp_alpha_div2 <= 4'd0; sp_beta_div2 <= 4'd0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: if (start) begin
                refused <= 1'b0; err <= 1'b0; code <= 4'd0;
                idr <= (nal_type == 5'd5); sp_idr <= (nal_type == 5'd5);
                sp_field <= 1'b0; sp_bottom <= 1'b0; sp_poc_lsb <= 16'd0; sp_direct_spatial <= 1'b0;
                sp_disable_deblock <= 2'd0; sp_alpha_div2 <= 4'd0; sp_beta_div2 <= 4'd0;
                state <= S_FIRST_MB;
            end
            S_REQ:  if (rd_req_ready) state <= S_WAIT;
            S_WAIT: if (rd_err) `ERROR(ERR_READER)
                    else if (rd_rsp_valid) begin
                        f_val <= rd_rsp_val;
                        state <= (f_id != 8'd0) ? S_EMIT : S_RET;   // (S_RET: the predicates)
                    end
            S_EMIT: if (se_ready) state <= f_ret;
            S_RET: state <= f_ret;
            S_FINISH: begin done <= 1'b1; state <= S_IDLE; end

            S_FIRST_MB: `FIELD(K_UE, 5'd0, F_first_mb_in_slice, S_STYPE)
            S_STYPE: if (!p_u14) `ERROR(ERR_RANGE) else begin sp_first_mb <= f_val[13:0]; `FIELD(K_UE, 5'd0, F_slice_type, S_PPSID) end
            S_PPSID: begin
                if (!(p_u5 && f_val[4:0] <= 5'd9)) `ERROR(ERR_RANGE)
                else if (f_val[3:0] == 4'd3 || f_val[3:0] == 4'd4 || f_val[3:0] == 4'd8 || f_val[3:0] == 4'd9) `REFUSE(REF_SPSI)
                else begin
                    // slice_type % 5: 0 P, 1 B, 2 I (the model's P, B, I = 0, 1, 2)
                    sp_slice_type <= (f_val[3:0] == 4'd0 || f_val[3:0] == 4'd5) ? ST_P :
                                     (f_val[3:0] == 4'd1 || f_val[3:0] == 4'd6) ? ST_B : ST_I;
                    `FIELD(K_UE, 5'd0, F_pic_parameter_set_id, S_PPS_LOOK)
                end
            end
            S_PPS_LOOK: if (!p_u8) `ERROR(ERR_RANGE) else begin pps_rd_id <= f_val[7:0]; state <= S_PPS_LOOK2; end
            S_PPS_LOOK2: state <= S_PPS_GOT;                       // the RAM read lands this edge
            S_PPS_GOT: begin
                if (!pps_q_valid) `ERROR(ERR_NO_PPS)
                else begin p <= pps_q; sps_rd_id <= pps_qs.sps_id; state <= S_SPS_LOOK2; end
            end
            S_SPS_LOOK2: state <= S_SPS_GOT;
            S_SPS_GOT: begin
                if (!sps_q_valid) `ERROR(ERR_NO_SPS)
                else begin
                    s <= sps_q;
                    sp_num_ref_l0 <= {1'b0, p.num_ref_idx_l0_default_minus1} + 6'd1;
                    sp_num_ref_l1 <= {1'b0, p.num_ref_idx_l1_default_minus1} + 6'd1;
                    `FIELD(K_BITS, fn_bits, F_frame_num, S_FIELDPIC)
                end
            end
            S_FIELDPIC: begin
                sp_frame_num <= f_val[15:0];
                if (!s.frame_mbs_only) `FIELD(K_BITS, 5'd1, F_field_pic_flag, S_BOTTOM)
                else state <= S_IDR;
            end
            S_BOTTOM: begin
                sp_field <= f_val[0];
                if (f_val[0]) `FIELD(K_BITS, 5'd1, F_bottom_field_flag, S_BOTTOM_CHK)
                else state <= S_IDR;
            end
            S_BOTTOM_CHK: begin sp_bottom <= f_val[0]; state <= S_IDR; end
            S_IDR: if (idr) `FIELD(K_UE, 5'd0, F_idr_pic_id, S_IDR_CHK) else state <= S_POC;
            S_IDR_CHK: if (!p_u16) `ERROR(ERR_RANGE) else state <= S_POC;
            S_POC: begin
                if (s.poc_type == 2'd0) `FIELD(K_BITS, poc_bits, F_pic_order_cnt_lsb, S_POC0_BOT)
                else if (s.poc_type == 2'd1 && !s.delta_pic_order_always_zero) `FIELD(K_SE, 5'd0, F_delta_pic_order_cnt_0, S_POC1_1)
                else state <= S_REDUNDANT;
            end
            S_POC0_BOT: begin
                sp_poc_lsb <= f_val[15:0];
                if (p.bottom_field_pic_order_present && !sp_field) `FIELD(K_SE, 5'd0, F_delta_pic_order_cnt_bottom, S_POC0_BOT_CHK)
                else state <= S_REDUNDANT;
            end
            S_POC0_BOT_CHK: state <= S_REDUNDANT;
            S_POC1_1: begin
                if (p.bottom_field_pic_order_present && !sp_field) `FIELD(K_SE, 5'd0, F_delta_pic_order_cnt_1, S_POC1_CHK)
                else state <= S_REDUNDANT;
            end
            S_POC1_CHK: state <= S_REDUNDANT;
            S_REDUNDANT: if (p.redundant_pic_cnt_present) `FIELD(K_UE, 5'd0, F_redundant_pic_cnt, S_REDUNDANT_CHK) else state <= S_DIRECT;
            S_REDUNDANT_CHK: if (!p_z) `REFUSE(REF_REDUNDANT) else state <= S_DIRECT;
            S_DIRECT: if (sp_slice_type == ST_B) `FIELD(K_BITS, 5'd1, F_direct_spatial_mv_pred_flag, S_DIRECT_CHK) else state <= S_OVERRIDE;
            S_DIRECT_CHK: begin sp_direct_spatial <= f_val[0]; state <= S_OVERRIDE; end
            S_OVERRIDE: if (sp_slice_type != ST_I) `FIELD(K_BITS, 5'd1, F_num_ref_idx_active_override_flag, S_OVR_BR) else state <= S_MARK;
            S_OVR_BR: if (f_val[0]) `FIELD(K_UE, 5'd0, F_num_ref_idx_l0_active_minus1, S_OVR_L1) else state <= S_MOD_START;
            S_OVR_L1: begin
                if (!p_u5) `ERROR(ERR_RANGE)
                else begin
                    sp_num_ref_l0 <= f_val[5:0] + 6'd1;
                    if (sp_slice_type == ST_B) `FIELD(K_UE, 5'd0, F_num_ref_idx_l1_active_minus1, S_OVR_L1_CHK)
                    else state <= S_MOD_START;
                end
            end
            S_OVR_L1_CHK: if (!p_u5) `ERROR(ERR_RANGE) else begin sp_num_ref_l1 <= f_val[5:0] + 6'd1; state <= S_MOD_START; end
            // ---- ref_pic_list_modification (7.3.3.1)
            S_MOD_START: begin lx <= 1'b0; state <= S_MOD_FLAG; end
            S_MOD_FLAG: `FIELD(K_BITS, 5'd1, F_ref_pic_list_modification_flag_l0 + lx8, S_MOD_FLAG_BR)
            S_MOD_FLAG_BR: state <= f_val[0] ? S_MOD_IDC : S_MOD_NEXT;
            S_MOD_IDC: `FIELD(K_UE, 5'd0, F_modification_of_pic_nums_idc_l0 + lx8, S_MOD_IDC_BR)
            S_MOD_IDC_BR: begin
                case (f_val)
                    32'd0, 32'd1: `FIELD(K_UE, 5'd0, F_abs_diff_pic_num_minus1_l0 + lx8, S_MOD_IDC)
                    32'd2:        `FIELD(K_UE, 5'd0, F_long_term_pic_num_l0 + lx8, S_MOD_IDC)
                    32'd3:        state <= S_MOD_NEXT;
                    default:      `ERROR(ERR_MOD_IDC)
                endcase
            end
            S_MOD_NEXT: begin
                if (!lx && sp_slice_type == ST_B) begin lx <= 1'b1; state <= S_MOD_FLAG; end
                else state <= S_WP;
            end
            // ---- pred_weight_table (7.3.3.2)
            S_WP: if (weighted) `FIELD(K_UE, 5'd0, F_luma_log2_weight_denom, S_WP_CD) else state <= S_MARK;
            S_WP_CD: if (!(p_u5 && f_val[4:0] <= 5'd7)) `ERROR(ERR_RANGE) else `FIELD(K_UE, 5'd0, F_chroma_log2_weight_denom, S_WP_START)
            S_WP_START: if (!(p_u5 && f_val[4:0] <= 5'd7)) `ERROR(ERR_RANGE) else begin lx <= 1'b0; ri <= 6'd0; state <= S_WP_LOOP; end
            S_WP_LOOP: if (ri < (lx ? sp_num_ref_l1 : sp_num_ref_l0)) `FIELD(K_BITS, 5'd1, F_luma_weight_flag_l0 + lx8, S_WP_LWF)
                       else state <= S_WP_NEXTLX;
            S_WP_LWF: if (f_val[0]) `FIELD(K_SE, 5'd0, F_luma_weight_l0 + lx8, S_WP_LW) else state <= S_WP_CWF;
            S_WP_LW: if (!p_s8) `ERROR(ERR_RANGE) else `FIELD(K_SE, 5'd0, F_luma_offset_l0 + lx8, S_WP_LO)
            S_WP_LO: if (!p_s8) `ERROR(ERR_RANGE) else state <= S_WP_CWF;
            S_WP_CWF: `FIELD(K_BITS, 5'd1, F_chroma_weight_flag_l0 + lx8, S_WP_CWF_BR)
            S_WP_CWF_BR: if (f_val[0]) begin ci <= 1'b0; state <= S_WP_CW; end else state <= S_WP_RI_NEXT;
            S_WP_CW: `FIELD(K_SE, 5'd0, F_chroma_weight_l0 + lx8, S_WP_CO)
            S_WP_CO: if (!p_s8) `ERROR(ERR_RANGE) else `FIELD(K_SE, 5'd0, F_chroma_offset_l0 + lx8, S_WP_C_NEXT)
            S_WP_C_NEXT: begin
                if (!p_s8) `ERROR(ERR_RANGE)
                else if (!ci) begin ci <= 1'b1; state <= S_WP_CW; end
                else state <= S_WP_RI_NEXT;
            end
            S_WP_RI_NEXT: begin ri <= ri + 6'd1; state <= S_WP_LOOP; end
            S_WP_NEXTLX: begin
                if (!lx && sp_slice_type == ST_B) begin lx <= 1'b1; ri <= 6'd0; state <= S_WP_LOOP; end
                else state <= S_MARK;
            end
            // ---- dec_ref_pic_marking (7.3.3.3)
            S_MARK: begin
                if (nal_ref_idc == 2'd0) state <= S_CABAC_INIT;
                else if (idr) `FIELD(K_BITS, 5'd1, F_no_output_of_prior_pics_flag, S_MARK_LT)
                else `FIELD(K_BITS, 5'd1, F_adaptive_ref_pic_marking_mode_flag, S_MARK_ADAPT_BR)
            end
            S_MARK_LT: `FIELD(K_BITS, 5'd1, F_long_term_reference_flag, S_MARK_LT_CHK)
            S_MARK_LT_CHK: state <= S_CABAC_INIT;
            S_MARK_ADAPT_BR: state <= f_val[0] ? S_MMCO : S_CABAC_INIT;
            S_MMCO: `FIELD(K_UE, 5'd0, F_memory_management_control_operation, S_MMCO_BR)
            S_MMCO_BR: begin
                case (f_val)
                    32'd0: state <= S_CABAC_INIT;
                    32'd1: `FIELD(K_UE, 5'd0, F_difference_of_pic_nums_minus1, S_MMCO)
                    32'd2: `FIELD(K_UE, 5'd0, F_long_term_pic_num, S_MMCO)
                    32'd3: `FIELD(K_UE, 5'd0, F_difference_of_pic_nums_minus1, S_MMCO3_LT)
                    32'd4: `FIELD(K_UE, 5'd0, F_max_long_term_frame_idx_plus1, S_MMCO)
                    32'd5: state <= S_MMCO;
                    32'd6: `FIELD(K_UE, 5'd0, F_long_term_frame_idx, S_MMCO)
                    default: `ERROR(ERR_RANGE)
                endcase
            end
            S_MMCO3_LT: `FIELD(K_UE, 5'd0, F_long_term_frame_idx, S_MMCO)
            // ---- the tail
            S_CABAC_INIT: if (sp_slice_type != ST_I) `FIELD(K_UE, 5'd0, F_cabac_init_idc, S_CABAC_INIT_CHK)
                          else begin sp_init_set <= 2'd3; state <= S_QPD; end
            S_CABAC_INIT_CHK: if (!(p_u5 && f_val[4:0] <= 5'd2)) `ERROR(ERR_RANGE) else begin sp_init_set <= f_val[1:0]; state <= S_QPD; end
            S_QPD: `FIELD(K_SE, 5'd0, F_slice_qp_delta, S_QPD_CHK)
            S_QPD_CHK: if (!p_qp_ok) `ERROR(ERR_RANGE) else begin sp_qp <= p_qp; state <= S_DEBLOCK; end
            S_DEBLOCK: if (p.deblocking_filter_control_present) `FIELD(K_UE, 5'd0, F_disable_deblocking_filter_idc, S_DEBLOCK_BR) else state <= S_ALIGN;
            S_DEBLOCK_BR: begin
                if (!(p_u5 && f_val[4:0] <= 5'd2)) `ERROR(ERR_RANGE)
                else begin
                    sp_disable_deblock <= f_val[1:0];
                    if (!p_one) `FIELD(K_SE, 5'd0, F_slice_alpha_c0_offset_div2, S_BETA)
                    else state <= S_ALIGN;
                end
            end
            S_BETA: if (!(p_s8 && $signed(f_val[7:0]) >= -8'sd6 && $signed(f_val[7:0]) <= 8'sd6)) `ERROR(ERR_RANGE) else begin sp_alpha_div2 <= f_val[3:0]; `FIELD(K_SE, 5'd0, F_slice_beta_offset_div2, S_BETA_CHK) end
            S_BETA_CHK: if (!(p_s8 && $signed(f_val[7:0]) >= -8'sd6 && $signed(f_val[7:0]) <= 8'sd6)) `ERROR(ERR_RANGE) else begin sp_beta_div2 <= f_val[3:0]; state <= S_ALIGN; end
            S_ALIGN: `FIELD(K_ALIGN1, 5'd0, 8'd0, S_ALIGN_DONE)
            S_ALIGN_DONE: begin
                sp_width_mbs  <= {1'b0, s.width_mbs_minus1} + 8'd1;
                sp_height_mbs <= sp_field ? (frame_height_mbs >> 1) : frame_height_mbs;
                if (rd_err) `ERROR(ERR_READER) else state <= S_FINISH;
            end
            default: state <= S_IDLE;
            endcase
        end
    end

`undef FIELD
`undef REFUSE
`undef ERROR

endmodule

`default_nettype wire
