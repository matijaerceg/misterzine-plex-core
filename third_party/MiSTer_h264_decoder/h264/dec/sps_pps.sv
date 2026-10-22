// h264/dec/sps_pps.sv -- sequence and picture parameter sets (7.3.2.1.1, 7.3.2.2)
//
// Parses an SPS or PPS NAL unit through rbsp_reader, field by field in the order of
// tools/h264_fe_ref.py's parse_sps / parse_pps (every field it records goes out on
// the SE stream as a K_HDR_WORD with its h264_fields.py id), and stores the fields
// the slice header and P4 need in two RAMs at the spec maxima: 32 SPS and 256 PPS
// (h264_pkg.sv has the layouts). Refusals are the model's, by name: chroma_format_idc
// != 1 (monochrome is legal High: docs/spec_hardening.md), bit depth > 8, the transform
// bypass, MBAFF, CAVLC, slice groups; plus the fabric's own: a picture wider or taller
// than 128 macroblocks (mb_syntax's line memory). A refused set is not stored AND its id
// is invalidated when the id is parsed (a re-sent set that is then refused must not leave
// the old record valid beside half-written scaling lists), so a slice naming it fails with
// ERR_NO_PPS / ERR_NO_SPS rather than decoding garbage.
//
// H264 Phase 5, High profile (docs/high_profile.md S3): the scaling_list()s of an SPS
// (eight) or a PPS (six, eight with transform_8x8_mode_flag) are stored as coded, at the
// spec maximum -- every one of 32 SPS and 256 PPS, 56 words of four weights each (lists 0..5
// at words 4i, 6 at 24, 7 at 40; 7.3.2.1.1.1), with the per-list {useDefault, present}
// flags in the record. delta_scale outside -128..127 (7.4.2.1.1.1) is ERR_RANGE. At a
// slice the parent asks (sl_start) for the RESOLVED matrix: the Table 7-2 fall-back rules
// A / B walked into a source per list {FLAT, DEFAULT, SPS list, PPS list}, then
// scaling_matrix_flag (0 when neither set carries a matrix, nothing follows) or 1 and 56
// scaling_list_words out on the same SE port (tools/h264_fe_ref.py scaling_words).
//
// Range errors: an id, count or offset outside its 7.4.2 range is ERR_RANGE (the
// stores are sized for the spec, so an out-of-range value could otherwise alias a
// legal one silently -- CLAUDE.md "never truncate silently"). The VUI (E.1.1) and its
// hrd_parameters() (E.1.2) are parsed whole, every field emitted (P5): the store keeps
// the picture-timing SEI's delay lengths and pic_struct_present_flag, the aspect, the
// timing and max_dec_frame_buffering. VUI range errors are on what is stored or looped
// over: cpb_cnt_minus1 > 31 (the loop), num_units_in_tick or time_scale 0 (a divisor),
// the NAL and VCL structures' four lengths differing (E.2.2 "shall be equal": one set is
// stored), max_dec_frame_buffering > 16 and max_num_reorder_frames above it. u(32)
// fields are read as two u(16) (rbsp_reader serves 31 bits at most) and emitted as one.
//
// Each field is one generic request/response/emit round (S_REQ / S_WAIT / S_EMIT
// with a return state), so a parse state reads the previous field's value from
// f_val, checks it, and issues the next.

`default_nettype none

module sps_pps
    import h264_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,              // forget every parameter set (a new title)

    input  wire        start,              // pulse: a NAL unit's payload follows on the reader
    input  wire        is_pps,             // 0: SPS (type 7), 1: PPS (type 8)
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
    input  wire        rd_err,             // any reader error, sticky

    // header fields, in syntax order
    output logic       se_valid,
    input  wire        se_ready,
    output logic [7:0] se_aux,
    output logic [31:0] se_val,

    // lookups (synchronous: the word and its valid bit follow the id by one cycle)
    input  wire  [7:0] pps_rd_id,
    output logic [PPS_W-1:0] pps_q,
    output logic       pps_q_valid,
    input  wire  [4:0] sps_rd_id,
    output logic [SPS_W-1:0] sps_q,
    output logic       sps_q_valid,

    output logic [31:0] sps_count,          // stored (accepted) sets since clear
    output logic [31:0] pps_count,

    // the resolved scaling matrix of a slice (High profile): its sets, whole, and the PPS id
    input  wire        sl_start,           // pulse, while idle
    input  wire  [7:0] sl_pps_id,
    input  wire [PPS_W-1:0] sl_pps,
    input  wire [SPS_W-1:0] sl_sps,
    output logic       sl_done             // pulse: every word emitted
);

`include "h264/dec/h264_fields.svh"

    localparam [2:0] K_BITS = 3'd0, K_UE = 3'd1, K_SE = 3'd2, K_ALIGN1 = 3'd3, K_MORE = 3'd4;

    typedef logic [7:0] state_t;
    localparam state_t S_IDLE = 8'd0, S_REQ = 8'd1, S_WAIT = 8'd2, S_EMIT = 8'd3,
        // SPS: a state issues the field it is named after, after checking the previous one
        S_SPS_PROFILE = 8'd10, S_SPS_CS0 = 8'd11, S_SPS_CS1 = 8'd12, S_SPS_CS2 = 8'd13, S_SPS_RES = 8'd14,
        S_SPS_LEVEL = 8'd15, S_SPS_ID = 8'd16, S_SPS_ID_CHK = 8'd17, S_SPS_BDL = 8'd18, S_SPS_BDC = 8'd19,
        S_SPS_LOSSLESS = 8'd20, S_SPS_SCALING = 8'd21, S_SPS_SCALING_CHK = 8'd22, S_SPS_LOG2FN = 8'd23,
        S_SPS_POCTYPE = 8'd24, S_SPS_POC_BR = 8'd25, S_SPS_POCLSB_CHK = 8'd26, S_SPS_OFF_NR = 8'd27,
        S_SPS_OFF_T2B = 8'd28, S_SPS_NCYC = 8'd29, S_SPS_CYC_CHK = 8'd30, S_SPS_CYC_LOOP = 8'd31,
        S_SPS_CYC_NEXT = 8'd32, S_SPS_NUMREF = 8'd33, S_SPS_GAPS = 8'd34, S_SPS_WIDTH = 8'd35,
        S_SPS_HEIGHT = 8'd36, S_SPS_FMO = 8'd37, S_SPS_FMO_CHK = 8'd38, S_SPS_MBAFF_CHK = 8'd39,
        S_SPS_D8 = 8'd40, S_SPS_CROP = 8'd41, S_SPS_CROP_BR = 8'd42, S_SPS_CROP_R = 8'd43,
        S_SPS_CROP_T = 8'd44, S_SPS_CROP_B = 8'd45, S_SPS_CROP_DONE = 8'd46, S_SPS_VUI = 8'd47,
        S_SPS_VUI_CHK = 8'd48, S_SPS_STORE = 8'd49,
        // PPS
        S_PPS_ID = 8'd60, S_PPS_SPSID = 8'd61, S_PPS_ENTROPY = 8'd62, S_PPS_BFPO = 8'd63, S_PPS_NSG = 8'd64,
        S_PPS_NREF0 = 8'd65, S_PPS_NREF1 = 8'd66, S_PPS_WP = 8'd67, S_PPS_WBI = 8'd68, S_PPS_QP = 8'd69,
        S_PPS_QS = 8'd70, S_PPS_CQO = 8'd71, S_PPS_DFC = 8'd72, S_PPS_CIP = 8'd73, S_PPS_RPC = 8'd74,
        S_PPS_MORE = 8'd75, S_PPS_MORE_BR = 8'd76, S_PPS_T8_CHK = 8'd77, S_PPS_PSM_CHK = 8'd78,
        S_PPS_SCQO = 8'd79, S_PPS_STORE = 8'd80, S_PPS_SCQO_REQ = 8'd81,
        S_FINISH = 8'd90,
        // scaling_list() (7.3.2.1.1.1), for either set
        S_SL_LOOP = 8'd150, S_SL_PRESENT = 8'd151, S_SL_J = 8'd152, S_SL_DELTA = 8'd153, S_SL_PUT = 8'd154,
        // the slice's resolved matrix
        S_RS_SRC = 8'd160, S_RS_LIST = 8'd161, S_RS_RD = 8'd162, S_RS_EMIT_W = 8'd163, S_RS_NEXT = 8'd164,
        S_RS_DONE = 8'd165,
        // SPS VUI (E.1.1) and hrd_parameters() (E.1.2)
        V_AR_BR = 8'd100, V_AR_IDC = 8'd101, V_SARH = 8'd102, V_SAR_DONE = 8'd103, V_OVS = 8'd104,
        V_OVS_BR = 8'd105, V_VST = 8'd106, V_VST_BR = 8'd107, V_VFR = 8'd108, V_CDP = 8'd109,
        V_CDP_BR = 8'd110, V_TC = 8'd111, V_MC = 8'd112, V_CLOC = 8'd113, V_CLOC_BR = 8'd114,
        V_CLOC_B = 8'd115, V_TIM = 8'd116, V_TIM_BR = 8'd117, V_NUIT_LO = 8'd118, V_NUIT_CMB = 8'd119,
        V_TS_HI = 8'd120, V_TS_LO = 8'd121, V_TS_CMB = 8'd122, V_FFR = 8'd123, V_NALHRD = 8'd124,
        V_HRD_BR = 8'd125, V_VCLHRD = 8'd126, V_BRS = 8'd127, V_CSS = 8'd128, V_CPB_LOOP = 8'd129,
        V_CPB_SZ = 8'd130, V_CPB_CBR = 8'd131, V_CPB_NEXT = 8'd132, V_CRD = 8'd133, V_DOD = 8'd134,
        V_TOL = 8'd135, V_HRD_CMP = 8'd136, V_HRD_END = 8'd137, V_PSP = 8'd138, V_BR = 8'd139,
        V_BR_BR = 8'd140, V_MBPD = 8'd141, V_MBMD = 8'd142, V_MVH = 8'd143, V_MVV = 8'd144,
        V_NRF = 8'd145, V_MDFB = 8'd146, V_BR_CHK = 8'd147, S_RET = 8'd166;
    state_t state, f_ret;

    // the generic field round
    logic [2:0]  f_kind;
    logic [4:0]  f_n;
    logic [7:0]  f_id;                     // 0: consumed silently (reserved bits)
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

    // ---- the stores ------------------------------------------------------------------
    logic [SPS_W-1:0] sps_mem [0:31];
    logic [PPS_W-1:0] pps_mem [0:255];
    logic [31:0]  sps_valid;
    logic [255:0] pps_valid;
    logic         sps_inval, pps_inval;    // the id just parsed: forget its old set
    // the scaling lists (High): 32 x 56 and 256 x 56 words, word id * 56 + list offset + j/4
    logic [31:0]  sps_sl_mem [0:1791];
    logic [31:0]  pps_sl_mem [0:14335];
    logic         sl_we;
    logic [13:0]  sl_waddr, rs_raddr;
    logic [31:0]  sl_wdata, sps_sl_q, pps_sl_q;
    // scaling_list() state
    logic         sl_is_pps;                  // the lists being parsed are a PPS's
    logic [3:0]   sl_i, sl_n;              // list, lists coded (8 SPS; 6 / 8 PPS)
    logic [6:0]   sl_j;                    // entry (0..64)
    logic [7:0]   sl_last, sl_next;
    logic [31:0]  sl_acc;                  // four entries, the first in bits 7..0
    logic [7:0]   sl_val;
    logic [15:0]  sl_fl;                   // the flags being built
    // list i's first word in a set's 56
    logic [5:0]   loffw;
    always_comb loffw = (sl_i < 4'd6) ? {sl_i[3:0], 2'b00} : (sl_i == 4'd6) ? 6'd24 : 6'd40;
    // the resolver: a source per list {kind 0 FLAT 1 DEFAULT 2 SPS 3 PPS, list}
    pps_t         rs_p;
    sps_t         rs_s;
    logic [7:0]   rs_pid;
    logic [4:0]   rs_src [0:7];
    logic [4:0]   rs_ss_prev, rs_src_prev; // the SPS chain's and the final chain's list i - 1
    logic [3:0]   rs_i;
    logic [4:0]   rs_wj;
    logic [4:0]   rs_cur;                  // the source being read
    logic [5:0]   def_a;
    logic [31:0]  def_q, def_q_r;
    hp_sl_default u_def (.a(def_a), .q(def_q));
    pps_t         sl_pps_w;
    sps_t         sl_sps_w;
    assign sl_pps_w = sl_pps;
    assign sl_sps_w = sl_sps;
    sps_t s;                               // the set being parsed
    pps_t p;
    logic [4:0] sps_id;
    logic [7:0] pps_id;
    // the list store's word of the set being parsed (id * 56)
    wire  [13:0]  sl_base = sl_is_pps ? ({pps_id, 6'd0} - {3'd0, pps_id, 3'd0}) : {3'd0, ({sps_id, 6'd0} - {3'd0, sps_id, 3'd0})};
    logic       sps_we, pps_we;
    logic [7:0] cyc_i;
    // VUI scratch
    logic [15:0] v_hi;                     // a u(32)'s upper half
    logic [31:0] v_nrf;                    // max_num_reorder_frames, until its bound is known
    logic        v_hrd_k;                  // 0: the NAL hrd_parameters(), 1: the VCL one
    logic        v_hrd_seen;               // one was parsed (its lengths are in s)
    logic [4:0]  v_cpb_cnt, v_cpb_i;
    logic [4:0]  v_init_len, v_crd, v_dod; // this structure's lengths, until compared
    logic [4:0]  v_init_prev;              // the first structure's initial_cpb_removal_delay length

    always_ff @(posedge clk) begin
        if (sps_we) sps_mem[sps_id] <= s;
        if (pps_we) pps_mem[pps_id] <= p;
        sps_q <= sps_mem[sps_rd_id];
        pps_q <= pps_mem[pps_rd_id];
    end
    always_ff @(posedge clk) begin
        if (sl_we && !sl_is_pps) sps_sl_mem[sl_waddr[10:0]] <= sl_wdata;
        sps_sl_q <= sps_sl_mem[rs_raddr[10:0]];
    end
    always_ff @(posedge clk) begin
        if (sl_we && sl_is_pps) pps_sl_mem[sl_waddr] <= sl_wdata;
        pps_sl_q <= pps_sl_mem[rs_raddr];
    end
    always_ff @(posedge clk) def_q_r <= def_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sps_valid <= 32'd0; pps_valid <= 256'd0; sps_q_valid <= 1'b0; pps_q_valid <= 1'b0;
            sps_count <= 32'd0; pps_count <= 32'd0;
        end else if (clear) begin
            sps_valid <= 32'd0; pps_valid <= 256'd0; sps_q_valid <= 1'b0; pps_q_valid <= 1'b0;
            sps_count <= 32'd0; pps_count <= 32'd0;
        end else begin
            if (sps_inval) sps_valid[sps_id] <= 1'b0;
            if (pps_inval) pps_valid[pps_id] <= 1'b0;
            if (sps_we) begin sps_valid[sps_id] <= 1'b1; sps_count <= sps_count + 32'd1; end
            if (pps_we) begin pps_valid[pps_id] <= 1'b1; pps_count <= pps_count + 32'd1; end
            sps_q_valid <= sps_valid[sps_rd_id];
            pps_q_valid <= pps_valid[pps_rd_id];
        end
    end

    // Table A-1 / 7.4.2.1.1: the profiles whose SPS carries chroma_format_idc and friends
    wire high_profile = (s.profile_idc == 8'd100) || (s.profile_idc == 8'd110) || (s.profile_idc == 8'd122) ||
                        (s.profile_idc == 8'd244) || (s.profile_idc == 8'd44)  || (s.profile_idc == 8'd83)  ||
                        (s.profile_idc == 8'd86)  || (s.profile_idc == 8'd118) || (s.profile_idc == 8'd128) ||
                        (s.profile_idc == 8'd138) || (s.profile_idc == 8'd139) || (s.profile_idc == 8'd134) ||
                        (s.profile_idc == 8'd135);

    // Table 7-2 for list rs_i: the SPS's own resolution (rule A inside it), then the PPS's
    // (rule B when the SPS carries a matrix, else A); a "previous list" fall-back takes the
    // chain's list i - 1 source (which names the list whose words to read)
    localparam [1:0] SRC_FLAT = 2'd0, SRC_DEF = 2'd1, SRC_SPS = 2'd2, SRC_PPS = 2'd3;
    logic [4:0] rs_ss, rs_fin;
    wire        rs_first = (rs_i == 4'd0) || (rs_i == 4'd3) || (rs_i == 4'd6) || (rs_i == 4'd7);
    wire [15:0] rs_sfl = rs_s.sl_flags;
    wire [15:0] rs_pfl = rs_p.sl_flags;
    wire        rs_s_on = rs_s.scaling_present;
    wire        rs_p_on = rs_p.scaling_present;
    always_comb begin
        logic s_pr, s_df, p_pr, p_df;
        s_pr = rs_sfl[{rs_i[2:0], 1'b0}]; s_df = rs_sfl[{rs_i[2:0], 1'b1}];
        p_pr = rs_pfl[{rs_i[2:0], 1'b0}]; p_df = rs_pfl[{rs_i[2:0], 1'b1}];
        if (!rs_s_on)              rs_ss = {SRC_FLAT, rs_i[2:0]};
        else if (s_pr)             rs_ss = {s_df ? SRC_DEF : SRC_SPS, rs_i[2:0]};
        else if (rs_first)         rs_ss = {SRC_DEF, rs_i[2:0]};
        else                       rs_ss = rs_ss_prev;
        if (!rs_p_on)              rs_fin = rs_ss;
        else if (p_pr)             rs_fin = {p_df ? SRC_DEF : SRC_PPS, rs_i[2:0]};
        else if (rs_first)         rs_fin = rs_s_on ? rs_ss : {SRC_DEF, rs_i[2:0]};
        else                       rs_fin = rs_src_prev;
    end
    // the word the resolver reads: list rs_cur's word rs_wj
    wire [5:0] cur_off = (rs_cur[2:0] < 3'd6) ? {1'b0, rs_cur[2:0], 2'b00} : (rs_cur[2:0] == 3'd6) ? 6'd24 : 6'd40;
    always_comb begin
        // the default lists' ROM: 4x4 intra 0..3, inter 4..7, 8x8 intra 8..23, inter 24..39
        case (rs_cur[2:0])
            3'd0, 3'd1, 3'd2: def_a = {4'd0, rs_wj[1:0]};
            3'd3, 3'd4, 3'd5: def_a = 6'd4 + {4'd0, rs_wj[1:0]};
            3'd6:             def_a = 6'd8 + {2'd0, rs_wj[3:0]};
            default:          def_a = 6'd24 + {2'd0, rs_wj[3:0]};
        endcase
    end
    wire [4:0] rs_nw = (rs_i < 4'd6) ? 5'd4 : 5'd16;          // words in list rs_i

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; f_ret <= S_IDLE; f_kind <= 3'd0; f_n <= 5'd0; f_id <= 8'd0; f_val <= 32'd0;
            sps_inval <= 1'b0; pps_inval <= 1'b0; sl_we <= 1'b0; sl_waddr <= '0; sl_wdata <= '0; rs_raddr <= '0;
            sl_is_pps <= 1'b0; sl_i <= '0; sl_n <= '0; sl_j <= '0; sl_last <= '0; sl_next <= '0; sl_acc <= '0;
            sl_val <= '0; sl_fl <= '0; rs_p <= '0; rs_s <= '0; rs_pid <= '0; rs_ss_prev <= '0; rs_src_prev <= '0;
            rs_i <= '0; rs_wj <= '0; rs_cur <= '0; sl_done <= 1'b0;
            for (int k = 0; k < 8; k++) rs_src[k] <= '0;
            done <= 1'b0; refused <= 1'b0; err <= 1'b0; code <= 4'd0;
            s <= '0; p <= '0; sps_id <= 5'd0; pps_id <= 8'd0; sps_we <= 1'b0; pps_we <= 1'b0; cyc_i <= 8'd0;
            v_hi <= '0; v_nrf <= '0; v_hrd_k <= 1'b0; v_hrd_seen <= 1'b0; v_cpb_cnt <= '0; v_cpb_i <= '0;
            v_init_len <= '0; v_crd <= '0; v_dod <= '0; v_init_prev <= '0;
        end else begin
            done <= 1'b0; sps_we <= 1'b0; pps_we <= 1'b0; sps_inval <= 1'b0; pps_inval <= 1'b0; sl_we <= 1'b0;
            sl_done <= 1'b0;
            case (state)
            S_IDLE: if (sl_start) begin
                // the slice's resolved scaling matrix (docs/high_profile.md S3)
                rs_p <= sl_pps; rs_s <= sl_sps; rs_pid <= sl_pps_id;
                rs_i <= 4'd0;
                f_id <= F_scaling_matrix_flag;
                if (!sl_pps_w.scaling_present && !sl_sps_w.scaling_present) begin
                    f_val <= 32'd0; f_ret <= S_RS_DONE; state <= S_EMIT;
                end else state <= S_RS_SRC;
            end else if (start) begin
                refused <= 1'b0; err <= 1'b0; code <= 4'd0;
                s <= '0; p <= '0;
                // E.2.2: the delay lengths inferred when no hrd_parameters() is present
                s.cpb_removal_delay_length_minus1 <= 5'd23; s.dpb_output_delay_length_minus1 <= 5'd23;
                s.time_offset_length <= 5'd24;
                v_hrd_seen <= 1'b0;
                state <= is_pps ? S_PPS_ID : S_SPS_PROFILE;
            end
            // ---- the generic field round
            S_REQ:  if (rd_req_ready) state <= S_WAIT;
            S_WAIT: if (rd_err) `ERROR(ERR_READER)
                    else if (rd_rsp_valid) begin
                        f_val <= rd_rsp_val;
                        state <= (f_id != 8'd0) ? S_EMIT : S_RET;   // (S_RET: the predicates)
                    end
            S_EMIT: if (se_ready) state <= f_ret;
            S_RET: state <= f_ret;
            S_FINISH: begin done <= 1'b1; state <= S_IDLE; end

            // ---- SPS (7.3.2.1.1)
            S_SPS_PROFILE: `FIELD(K_BITS, 5'd8, F_profile_idc, S_SPS_CS0)
            S_SPS_CS0: begin s.profile_idc <= f_val[7:0]; `FIELD(K_BITS, 5'd1, F_constraint_set0_flag, S_SPS_CS1) end
            S_SPS_CS1: begin s.constraint_set[2] <= f_val[0]; `FIELD(K_BITS, 5'd1, F_constraint_set1_flag, S_SPS_CS2) end
            S_SPS_CS2: begin s.constraint_set[1] <= f_val[0]; `FIELD(K_BITS, 5'd1, F_constraint_set2_flag, S_SPS_RES) end
            S_SPS_RES: begin s.constraint_set[0] <= f_val[0]; `FIELD(K_BITS, 5'd5, 8'd0, S_SPS_LEVEL) end   // set3..5 + reserved_zero_2bits
            S_SPS_LEVEL: `FIELD(K_BITS, 5'd8, F_level_idc, S_SPS_ID)
            S_SPS_ID: begin s.level_idc <= f_val[7:0]; `FIELD(K_UE, 5'd0, F_seq_parameter_set_id, S_SPS_ID_CHK) end
            S_SPS_ID_CHK: begin
                if (!p_u5) `ERROR(ERR_RANGE)
                else begin
                    sps_id <= f_val[4:0]; sps_inval <= 1'b1;
                    if (high_profile) `FIELD(K_UE, 5'd0, F_chroma_format_idc, S_SPS_BDL)
                    else state <= S_SPS_LOG2FN;
                end
            end
            S_SPS_BDL: if (!p_one) `REFUSE(REF_CHROMA) else `FIELD(K_UE, 5'd0, F_bit_depth_luma_minus8, S_SPS_BDC)
            S_SPS_BDC: if (!p_z) `REFUSE(REF_BITDEPTH) else `FIELD(K_UE, 5'd0, F_bit_depth_chroma_minus8, S_SPS_LOSSLESS)
            S_SPS_LOSSLESS: if (!p_z) `REFUSE(REF_BITDEPTH) else `FIELD(K_BITS, 5'd1, F_lossless_qpprime_y_zero_flag, S_SPS_SCALING)
            // qpprime_y_zero_transform_bypass_flag: High 4:4:4 Predictive only
            S_SPS_SCALING: if (f_val[0]) `REFUSE(REF_BITDEPTH) else `FIELD(K_BITS, 5'd1, F_seq_scaling_matrix_present_flag, S_SPS_SCALING_CHK)
            S_SPS_SCALING_CHK: begin
                s.scaling_present <= f_val[0];
                if (f_val[0]) begin sl_is_pps <= 1'b0; sl_i <= 4'd0; sl_n <= 4'd8; sl_fl <= '0; state <= S_SL_LOOP; end
                else state <= S_SPS_LOG2FN;
            end
            // ---- scaling_list() x sl_n (7.3.2.1.1.1): into the list store as four-entry words
            S_SL_LOOP: begin
                if (sl_i == sl_n) begin
                    if (sl_is_pps) begin p.sl_flags <= sl_fl; state <= S_PPS_SCQO_REQ; end
                    else        begin s.sl_flags <= sl_fl; state <= S_SPS_LOG2FN; end
                end else `FIELD(K_BITS, 5'd1, sl_is_pps ? F_pic_scaling_list_present_flag_i : F_seq_scaling_list_present_flag_i, S_SL_PRESENT)
            end
            S_SL_PRESENT: begin
                sl_fl[{sl_i[2:0], 1'b0}] <= f_val[0];
                if (f_val[0]) begin sl_last <= 8'd8; sl_next <= 8'd8; sl_j <= 7'd0; state <= S_SL_J; end
                else begin sl_i <= sl_i + 4'd1; state <= S_SL_LOOP; end
            end
            S_SL_J: begin
                if (sl_j == ((sl_i < 4'd6) ? 7'd16 : 7'd64)) begin sl_i <= sl_i + 4'd1; state <= S_SL_LOOP; end
                else if (sl_next != 8'd0) `FIELD(K_SE, 5'd0, F_delta_scale, S_SL_DELTA)
                else begin sl_val <= sl_last; state <= S_SL_PUT; end   // nextScale 0: the rest repeat
            end
            S_SL_DELTA: begin
                logic [7:0] nx;
                nx = sl_last + f_val[7:0];                          // (lastScale + delta + 256) % 256
                if (!p_s8) `ERROR(ERR_RANGE)
                else if (sl_j == 7'd0 && nx == 8'd0) begin
                    // useDefaultScalingMatrixFlag: no more deltas; the list is a default one
                    sl_fl[{sl_i[2:0], 1'b1}] <= 1'b1;
                    sl_i <= sl_i + 4'd1; state <= S_SL_LOOP;
                end else begin
                    sl_next <= nx; sl_val <= (nx == 8'd0) ? sl_last : nx; state <= S_SL_PUT;
                end
            end
            S_SL_PUT: begin
                sl_acc <= {sl_val, sl_acc[31:8]};
                sl_last <= sl_val;
                if (sl_j[1:0] == 2'd3) begin
                    sl_we <= 1'b1; sl_wdata <= {sl_val, sl_acc[31:8]};
                    sl_waddr <= sl_base + {8'd0, loffw} + {9'd0, sl_j[6:2]};
                end
                sl_j <= sl_j + 7'd1;
                state <= S_SL_J;
            end
            S_SPS_LOG2FN: `FIELD(K_UE, 5'd0, F_log2_max_frame_num_minus4, S_SPS_POCTYPE)
            S_SPS_POCTYPE: begin
                if (!(p_u5 && f_val[4:0] <= 5'd12)) `ERROR(ERR_RANGE)
                else begin s.log2_max_frame_num_minus4 <= f_val[3:0]; `FIELD(K_UE, 5'd0, F_pic_order_cnt_type, S_SPS_POC_BR) end
            end
            S_SPS_POC_BR: begin
                s.poc_type <= f_val[1:0];
                case (f_val)
                    32'd0: `FIELD(K_UE, 5'd0, F_log2_max_pic_order_cnt_lsb_minus4, S_SPS_POCLSB_CHK)
                    32'd1: `FIELD(K_BITS, 5'd1, F_delta_pic_order_always_zero_flag, S_SPS_OFF_NR)
                    32'd2: state <= S_SPS_NUMREF;
                    default: `ERROR(ERR_RANGE)
                endcase
            end
            S_SPS_POCLSB_CHK: if (!(p_u5 && f_val[4:0] <= 5'd12)) `ERROR(ERR_RANGE) else begin s.log2_max_poc_lsb_minus4 <= f_val[3:0]; state <= S_SPS_NUMREF; end
            S_SPS_OFF_NR: begin s.delta_pic_order_always_zero <= f_val[0]; `FIELD(K_SE, 5'd0, F_offset_for_non_ref_pic, S_SPS_OFF_T2B) end
            S_SPS_OFF_T2B: begin s.offset_for_non_ref_pic <= f_val; `FIELD(K_SE, 5'd0, F_offset_for_top_to_bottom_field, S_SPS_NCYC) end
            S_SPS_NCYC: begin s.offset_for_top_to_bottom_field <= f_val; `FIELD(K_UE, 5'd0, F_num_ref_frames_in_pic_order_cnt_cycle, S_SPS_CYC_CHK) end
            S_SPS_CYC_CHK: if (!p_u8) `ERROR(ERR_RANGE) else begin s.num_ref_frames_in_poc_cycle <= f_val[7:0]; cyc_i <= 8'd0; state <= S_SPS_CYC_LOOP; end
            S_SPS_CYC_LOOP: if (cyc_i < s.num_ref_frames_in_poc_cycle) `FIELD(K_SE, 5'd0, F_offset_for_ref_frame_i, S_SPS_CYC_NEXT)
                            else state <= S_SPS_NUMREF;
            // 🚩 The offsets are NOT stored here (docs/spec_hardening.md "Known deviations",
            // decided 2026-09-23): the spec store is 32 SPS x 255 x 32 bits = 27 M10K; P4's POC
            // module captures them from the SE stream for the two most recent type-1 SPSs and
            // refuses loudly if a slice activates an evicted one.
            S_SPS_CYC_NEXT: begin cyc_i <= cyc_i + 8'd1; state <= S_SPS_CYC_LOOP; end
            S_SPS_NUMREF: `FIELD(K_UE, 5'd0, F_num_ref_frames, S_SPS_GAPS)
            S_SPS_GAPS: if (!(p_u5 && f_val[4:0] <= 5'd16)) `ERROR(ERR_RANGE) else begin s.num_ref_frames <= f_val[4:0]; `FIELD(K_BITS, 5'd1, F_gaps_in_frame_num_value_allowed_flag, S_SPS_WIDTH) end
            S_SPS_WIDTH: begin s.gaps_in_frame_num_allowed <= f_val[0]; `FIELD(K_UE, 5'd0, F_pic_width_in_mbs_minus1, S_SPS_HEIGHT) end
            S_SPS_HEIGHT: if (!p_u7) `REFUSE(REF_SIZE) else begin s.width_mbs_minus1 <= f_val[6:0]; `FIELD(K_UE, 5'd0, F_pic_height_in_map_units_minus1, S_SPS_FMO) end
            S_SPS_FMO: if (!p_u7) `REFUSE(REF_SIZE) else begin s.height_map_units_minus1 <= f_val[6:0]; `FIELD(K_BITS, 5'd1, F_frame_mbs_only_flag, S_SPS_FMO_CHK) end
            S_SPS_FMO_CHK: begin
                s.frame_mbs_only <= f_val[0];
                if (!f_val[0] && s.height_map_units_minus1 > 7'd63) `REFUSE(REF_SIZE)   // FrameHeightInMbs = 2 * map units > 128
                else if (!f_val[0]) `FIELD(K_BITS, 5'd1, F_mb_adaptive_frame_field_flag, S_SPS_MBAFF_CHK)
                else state <= S_SPS_D8;
            end
            S_SPS_MBAFF_CHK: if (f_val[0]) `REFUSE(REF_MBAFF) else state <= S_SPS_D8;
            S_SPS_D8: `FIELD(K_BITS, 5'd1, F_direct_8x8_inference_flag, S_SPS_CROP)
            S_SPS_CROP: begin s.direct_8x8_inference <= f_val[0]; `FIELD(K_BITS, 5'd1, F_frame_cropping_flag, S_SPS_CROP_BR) end
            S_SPS_CROP_BR: begin
                s.frame_cropping <= f_val[0];
                if (f_val[0]) `FIELD(K_UE, 5'd0, F_frame_crop_left_offset, S_SPS_CROP_R)
                else state <= S_SPS_VUI;
            end
            S_SPS_CROP_R: if (!p_u10) `ERROR(ERR_RANGE) else begin s.crop_left <= f_val[9:0]; `FIELD(K_UE, 5'd0, F_frame_crop_right_offset, S_SPS_CROP_T) end
            S_SPS_CROP_T: if (!p_u10) `ERROR(ERR_RANGE) else begin s.crop_right <= f_val[9:0]; `FIELD(K_UE, 5'd0, F_frame_crop_top_offset, S_SPS_CROP_B) end
            S_SPS_CROP_B: if (!p_u10) `ERROR(ERR_RANGE) else begin s.crop_top <= f_val[9:0]; `FIELD(K_UE, 5'd0, F_frame_crop_bottom_offset, S_SPS_CROP_DONE) end
            S_SPS_CROP_DONE: if (!p_u10) `ERROR(ERR_RANGE) else begin s.crop_bottom <= f_val[9:0]; state <= S_SPS_VUI; end
            S_SPS_VUI: `FIELD(K_BITS, 5'd1, F_vui_parameters_present_flag, S_SPS_VUI_CHK)
            S_SPS_VUI_CHK: begin
                s.vui_present <= f_val[0];
                if (f_val[0]) `FIELD(K_BITS, 5'd1, F_aspect_ratio_info_present_flag, V_AR_BR)
                else state <= S_SPS_STORE;
            end
            // ---- VUI (E.1.1)
            V_AR_BR: if (f_val[0]) `FIELD(K_BITS, 5'd8, F_aspect_ratio_idc, V_AR_IDC) else state <= V_OVS;
            V_AR_IDC: begin
                s.aspect_ratio_idc <= f_val[7:0];
                if (f_val[7:0] == 8'd255) `FIELD(K_BITS, 5'd16, F_sar_width, V_SARH)   // Extended_SAR
                else state <= V_OVS;
            end
            V_SARH: begin s.sar_width <= f_val[15:0]; `FIELD(K_BITS, 5'd16, F_sar_height, V_SAR_DONE) end
            V_SAR_DONE: begin s.sar_height <= f_val[15:0]; state <= V_OVS; end
            V_OVS: `FIELD(K_BITS, 5'd1, F_overscan_info_present_flag, V_OVS_BR)
            V_OVS_BR: if (f_val[0]) `FIELD(K_BITS, 5'd1, F_overscan_appropriate_flag, V_VST) else state <= V_VST;
            V_VST: `FIELD(K_BITS, 5'd1, F_video_signal_type_present_flag, V_VST_BR)
            V_VST_BR: if (f_val[0]) `FIELD(K_BITS, 5'd3, F_video_format, V_VFR) else state <= V_CLOC;
            V_VFR: `FIELD(K_BITS, 5'd1, F_video_full_range_flag, V_CDP)
            V_CDP: `FIELD(K_BITS, 5'd1, F_colour_description_present_flag, V_CDP_BR)
            V_CDP_BR: if (f_val[0]) `FIELD(K_BITS, 5'd8, F_colour_primaries, V_TC) else state <= V_CLOC;
            V_TC: `FIELD(K_BITS, 5'd8, F_transfer_characteristics, V_MC)
            V_MC: `FIELD(K_BITS, 5'd8, F_matrix_coefficients, V_CLOC)
            V_CLOC: `FIELD(K_BITS, 5'd1, F_chroma_loc_info_present_flag, V_CLOC_BR)
            V_CLOC_BR: if (f_val[0]) `FIELD(K_UE, 5'd0, F_chroma_sample_loc_type_top_field, V_CLOC_B) else state <= V_TIM;
            V_CLOC_B: `FIELD(K_UE, 5'd0, F_chroma_sample_loc_type_bottom_field, V_TIM)
            V_TIM: `FIELD(K_BITS, 5'd1, F_timing_info_present_flag, V_TIM_BR)
            V_TIM_BR: begin
                s.timing_present <= f_val[0];
                if (f_val[0]) `FIELD(K_BITS, 5'd16, 8'd0, V_NUIT_LO)   // num_units_in_tick, upper half (silent)
                else state <= V_NALHRD;
            end
            V_NUIT_LO: begin v_hi <= f_val[15:0]; `FIELD(K_BITS, 5'd16, 8'd0, V_NUIT_CMB) end
            V_NUIT_CMB: begin f_val <= {v_hi, f_val[15:0]}; f_id <= F_num_units_in_tick; f_ret <= V_TS_HI; state <= S_EMIT; end
            V_TS_HI: begin s.num_units_in_tick <= f_val; `FIELD(K_BITS, 5'd16, 8'd0, V_TS_LO) end
            V_TS_LO: begin v_hi <= f_val[15:0]; `FIELD(K_BITS, 5'd16, 8'd0, V_TS_CMB) end
            V_TS_CMB: begin f_val <= {v_hi, f_val[15:0]}; f_id <= F_time_scale; f_ret <= V_FFR; state <= S_EMIT; end
            V_FFR: begin
                if (s.num_units_in_tick == 32'd0 || p_z) `ERROR(ERR_RANGE)    // E.2.1: both > 0
                else begin s.time_scale <= f_val; `FIELD(K_BITS, 5'd1, F_fixed_frame_rate_flag, V_NALHRD) end
            end
            V_NALHRD: begin v_hrd_k <= 1'b0; `FIELD(K_BITS, 5'd1, F_nal_hrd_parameters_present_flag, V_HRD_BR) end
            V_VCLHRD: begin v_hrd_k <= 1'b1; `FIELD(K_BITS, 5'd1, F_vcl_hrd_parameters_present_flag, V_HRD_BR) end
            V_HRD_BR: begin
                if (f_val[0]) `FIELD(K_UE, 5'd0, F_cpb_cnt_minus1, V_BRS)
                else state <= v_hrd_k ? V_HRD_END : V_VCLHRD;
            end
            // ---- hrd_parameters() (E.1.2)
            V_BRS: begin
                if (!p_u5) `ERROR(ERR_RANGE)
                else begin v_cpb_cnt <= f_val[4:0]; v_cpb_i <= 5'd0; `FIELD(K_BITS, 5'd4, F_bit_rate_scale, V_CSS) end
            end
            V_CSS: `FIELD(K_BITS, 5'd4, F_cpb_size_scale, V_CPB_LOOP)
            V_CPB_LOOP: `FIELD(K_UE, 5'd0, F_bit_rate_value_minus1_i, V_CPB_SZ)
            V_CPB_SZ: `FIELD(K_UE, 5'd0, F_cpb_size_value_minus1_i, V_CPB_CBR)
            V_CPB_CBR: `FIELD(K_BITS, 5'd1, F_cbr_flag_i, V_CPB_NEXT)
            V_CPB_NEXT: begin
                if (v_cpb_i == v_cpb_cnt) `FIELD(K_BITS, 5'd5, F_initial_cpb_removal_delay_length_minus1, V_CRD)
                else begin v_cpb_i <= v_cpb_i + 5'd1; state <= V_CPB_LOOP; end
            end
            V_CRD: begin v_init_len <= f_val[4:0]; `FIELD(K_BITS, 5'd5, F_cpb_removal_delay_length_minus1, V_DOD) end
            V_DOD: begin v_crd <= f_val[4:0]; `FIELD(K_BITS, 5'd5, F_dpb_output_delay_length_minus1, V_TOL) end
            V_TOL: begin v_dod <= f_val[4:0]; `FIELD(K_BITS, 5'd5, F_time_offset_length, V_HRD_CMP) end
            V_HRD_CMP: begin
                // E.2.2: in both structures the four lengths shall be equal (one set is stored)
                if (v_hrd_seen && ({v_init_len, v_crd, v_dod, f_val[4:0]} !=
                                   {v_init_prev, s.cpb_removal_delay_length_minus1,
                                    s.dpb_output_delay_length_minus1, s.time_offset_length})) `ERROR(ERR_RANGE)
                else begin
                    v_hrd_seen <= 1'b1; v_init_prev <= v_init_len;
                    s.cpb_removal_delay_length_minus1 <= v_crd; s.dpb_output_delay_length_minus1 <= v_dod;
                    s.time_offset_length <= f_val[4:0];
                    state <= v_hrd_k ? V_HRD_END : V_VCLHRD;
                end
            end
            V_HRD_END: begin
                s.cpb_dpb_delays_present <= v_hrd_seen;
                if (v_hrd_seen) `FIELD(K_BITS, 5'd1, F_low_delay_hrd_flag, V_PSP)
                else state <= V_PSP;
            end
            V_PSP: `FIELD(K_BITS, 5'd1, F_pic_struct_present_flag, V_BR)
            V_BR: begin s.pic_struct_present <= f_val[0]; `FIELD(K_BITS, 5'd1, F_bitstream_restriction_flag, V_BR_BR) end
            V_BR_BR: begin
                s.bitstream_restriction <= f_val[0];
                if (f_val[0]) `FIELD(K_BITS, 5'd1, F_motion_vectors_over_pic_boundaries_flag, V_MBPD)
                else state <= S_SPS_STORE;
            end
            V_MBPD: `FIELD(K_UE, 5'd0, F_max_bytes_per_pic_denom, V_MBMD)
            V_MBMD: `FIELD(K_UE, 5'd0, F_max_bits_per_mb_denom, V_MVH)
            V_MVH: `FIELD(K_UE, 5'd0, F_log2_max_mv_length_horizontal, V_MVV)
            V_MVV: `FIELD(K_UE, 5'd0, F_log2_max_mv_length_vertical, V_NRF)
            V_NRF: `FIELD(K_UE, 5'd0, F_max_num_reorder_frames, V_MDFB)
            V_MDFB: begin v_nrf <= f_val; `FIELD(K_UE, 5'd0, F_max_dec_frame_buffering, V_BR_CHK) end
            V_BR_CHK: begin
                if (!(p_u5 && f_val[4:0] <= 5'd16) || v_nrf > f_val) `ERROR(ERR_RANGE)     // A.3.1; E.2.1
                else begin s.max_dec_frame_buffering <= f_val[4:0]; s.max_num_reorder_frames <= v_nrf[4:0]; state <= S_SPS_STORE; end
            end
            S_SPS_STORE: begin sps_we <= 1'b1; state <= S_FINISH; end

            // ---- PPS (7.3.2.2)
            S_PPS_ID: `FIELD(K_UE, 5'd0, F_pic_parameter_set_id, S_PPS_SPSID)
            S_PPS_SPSID: if (!p_u8) `ERROR(ERR_RANGE) else begin pps_id <= f_val[7:0]; pps_inval <= 1'b1; `FIELD(K_UE, 5'd0, F_seq_parameter_set_id, S_PPS_ENTROPY) end
            S_PPS_ENTROPY: if (!p_u5) `ERROR(ERR_RANGE) else begin p.sps_id <= f_val[4:0]; `FIELD(K_BITS, 5'd1, F_entropy_coding_mode_flag, S_PPS_BFPO) end
            S_PPS_BFPO: if (!f_val[0]) `REFUSE(REF_CAVLC) else `FIELD(K_BITS, 5'd1, F_bottom_field_pic_order_in_frame_present_flag, S_PPS_NSG)
            S_PPS_NSG: begin p.bottom_field_pic_order_present <= f_val[0]; `FIELD(K_UE, 5'd0, F_num_slice_groups_minus1, S_PPS_NREF0) end
            S_PPS_NREF0: if (!p_z) `REFUSE(REF_FMO) else `FIELD(K_UE, 5'd0, F_num_ref_idx_l0_default_active_minus1, S_PPS_NREF1)
            S_PPS_NREF1: if (!p_u5) `ERROR(ERR_RANGE) else begin p.num_ref_idx_l0_default_minus1 <= f_val[4:0]; `FIELD(K_UE, 5'd0, F_num_ref_idx_l1_default_active_minus1, S_PPS_WP) end
            S_PPS_WP: if (!p_u5) `ERROR(ERR_RANGE) else begin p.num_ref_idx_l1_default_minus1 <= f_val[4:0]; `FIELD(K_BITS, 5'd1, F_weighted_pred_flag, S_PPS_WBI) end
            S_PPS_WBI: begin p.weighted_pred <= f_val[0]; `FIELD(K_BITS, 5'd2, F_weighted_bipred_idc, S_PPS_QP) end
            S_PPS_QP: begin p.weighted_bipred_idc <= f_val[1:0]; `FIELD(K_SE, 5'd0, F_pic_init_qp_minus26, S_PPS_QS) end
            S_PPS_QS: if (!(p_s8 && $signed(f_val[7:0]) >= -8'sd26 && $signed(f_val[7:0]) <= 8'sd25)) `ERROR(ERR_RANGE) else begin p.pic_init_qp_minus26 <= f_val[5:0]; `FIELD(K_SE, 5'd0, F_pic_init_qs_minus26, S_PPS_CQO) end
            S_PPS_CQO: if (!(p_s8 && $signed(f_val[7:0]) >= -8'sd26 && $signed(f_val[7:0]) <= 8'sd25)) `ERROR(ERR_RANGE) else begin p.pic_init_qs_minus26 <= f_val[5:0]; `FIELD(K_SE, 5'd0, F_chroma_qp_index_offset, S_PPS_DFC) end
            S_PPS_DFC: if (!(p_s8 && $signed(f_val[7:0]) >= -8'sd12 && $signed(f_val[7:0]) <= 8'sd12)) `ERROR(ERR_RANGE)
                       else begin p.chroma_qp_index_offset <= f_val[4:0]; p.second_chroma_qp_index_offset <= f_val[4:0]; `FIELD(K_BITS, 5'd1, F_deblocking_filter_control_present_flag, S_PPS_CIP) end
            S_PPS_CIP: begin p.deblocking_filter_control_present <= f_val[0]; `FIELD(K_BITS, 5'd1, F_constrained_intra_pred_flag, S_PPS_RPC) end
            S_PPS_RPC: begin p.constrained_intra_pred <= f_val[0]; `FIELD(K_BITS, 5'd1, F_redundant_pic_cnt_present_flag, S_PPS_MORE) end
            S_PPS_MORE: begin p.redundant_pic_cnt_present <= f_val[0]; `FIELD(K_MORE, 5'd0, 8'd0, S_PPS_MORE_BR) end
            S_PPS_MORE_BR: if (f_val[0]) `FIELD(K_BITS, 5'd1, F_transform_8x8_mode_flag, S_PPS_T8_CHK) else state <= S_PPS_STORE;
            S_PPS_T8_CHK: begin p.transform_8x8_mode <= f_val[0]; `FIELD(K_BITS, 5'd1, F_pic_scaling_matrix_present_flag, S_PPS_PSM_CHK) end
            S_PPS_PSM_CHK: begin
                // 6 + (chroma_format_idc != 3 ? 2 : 6) * transform_8x8_mode_flag lists; 4:4:4
                // is refused at its SPS, so 6 or 8 for every PPS this decoder can use
                p.scaling_present <= f_val[0];
                if (f_val[0]) begin sl_is_pps <= 1'b1; sl_i <= 4'd0; sl_n <= p.transform_8x8_mode ? 4'd8 : 4'd6; sl_fl <= '0; state <= S_SL_LOOP; end
                else state <= S_PPS_SCQO_REQ;
            end
            S_PPS_SCQO_REQ: `FIELD(K_SE, 5'd0, F_second_chroma_qp_index_offset, S_PPS_SCQO)
            S_PPS_SCQO: if (!(p_s8 && $signed(f_val[7:0]) >= -8'sd12 && $signed(f_val[7:0]) <= 8'sd12)) `ERROR(ERR_RANGE) else begin p.second_chroma_qp_index_offset <= f_val[4:0]; state <= S_PPS_STORE; end
            S_PPS_STORE: begin pps_we <= 1'b1; state <= S_FINISH; end

            // ---- the slice's resolved matrix: the sources, then 56 words
            S_RS_SRC: begin
                rs_src[rs_i[2:0]] <= rs_fin;
                rs_ss_prev <= rs_ss; rs_src_prev <= rs_fin;
                if (rs_i == 4'd7) begin
                    rs_i <= 4'd0; rs_wj <= 5'd0;
                    f_id <= F_scaling_matrix_flag; f_val <= 32'd1; f_ret <= S_RS_LIST; state <= S_EMIT;
                end else rs_i <= rs_i + 4'd1;
            end
            S_RS_LIST: begin
                if (rs_i == 4'd8) state <= S_RS_DONE;
                else begin
                    rs_cur <= rs_src[rs_i[2:0]];
                    state <= S_RS_RD;
                end
            end
            S_RS_RD: begin
                // the store word (a read registered here, its data the edge after)
                rs_raddr <= ((rs_cur[4:3] == SRC_PPS) ? ({rs_pid, 6'd0} - {3'd0, rs_pid, 3'd0})
                                                      : {3'd0, ({rs_p.sps_id, 6'd0} - {3'd0, rs_p.sps_id, 3'd0})})
                            + {8'd0, cur_off} + {9'd0, rs_wj};
                state <= S_RS_EMIT_W;
            end
            S_RS_EMIT_W: state <= S_RS_NEXT;                   // the store / ROM word lands
            S_RS_NEXT: begin
                case (rs_cur[4:3])
                    SRC_FLAT: f_val <= 32'h10101010;
                    SRC_DEF:  f_val <= def_q_r;
                    SRC_SPS:  f_val <= sps_sl_q;
                    default:  f_val <= pps_sl_q;
                endcase
                f_id <= F_scaling_list_word;
                if (rs_wj == rs_nw - 5'd1) begin rs_wj <= 5'd0; rs_i <= rs_i + 4'd1; f_ret <= S_RS_LIST; end
                else begin rs_wj <= rs_wj + 5'd1; f_ret <= S_RS_RD; end
                state <= S_EMIT;
            end
            S_RS_DONE: begin sl_done <= 1'b1; state <= S_IDLE; end

            default: state <= S_IDLE;
            endcase
        end
    end

`undef FIELD
`undef REFUSE
`undef ERROR

endmodule

`default_nettype wire
