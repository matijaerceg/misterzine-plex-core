// h264/dec/deblock_filter.sv -- the deblocking edge filter kernel (ITU-T H.264 8.7.2)
//
// One set of eight samples across one edge in, the six the filter may change out:
// the filtering of 8.7.2.2 (the thresholds alpha / beta from qPav and the slice's
// FilterOffsetA / FilterOffsetB, filterSamplesFlag), 8.7.2.3 (bS < 4: tC0 from Table
// 8-17, tC, the delta and the luma p1 / q1 update) and 8.7.2.4 (bS == 4: the strong
// and the weak luma filters, the chroma filter). Non-MBAFF, 8-bit samples, 4:2:0
// (chromaStyleFilteringFlag == chromaEdgeFlag). Bit-exact against the model's
// filter_line (tools/h264_recon_ref.py, itself pixel-exact vs ffmpeg and the H.264.1
// reference YUVs), scored by bench/h264/run_deblock.sh. docs/h264_recon.md S2.4.
//
// The caller (the deblocking sequencer) resolves everything that is not per-line:
//   qp_p / qp_q   QPY of the macroblocks holding p0 / q0, or 0 for an I_PCM macroblock;
//                 for a chroma edge the QPc of each macroblock for that plane (8.7.2.2)
//   alpha_off / beta_off  FilterOffsetA / FilterOffsetB = slice_alpha_c0_offset_div2 << 1
//                 and slice_beta_offset_div2 << 1: even, -12..12
//   bs            1..4 (a bS 0 line is not sent; if it is, nothing changes)
//   chroma        chromaEdgeFlag
// and paces the unit: one line per cycle with in_valid, no ready handshake. The
// outputs land three cycles later with out_valid (a fixed latency); `changed` is
// filterSamplesFlag (8-460), so the caller can skip the write-back of an untouched line.
//
// The pipeline. A: qPav = (qPp + qPq + 1) >> 1 (8-461), indexA / indexB = Clip3(0, 51,
// qPav + offset) (8-462, 8-463), the five absolute differences. B: the alpha / beta /
// tC0 ROMs (Tables 8-16 and 8-17 as case blocks, transcribed from the ALPHA / BETA / TC0
// lists of tools/h264_recon_ref.py, which were transcribed from the spec PDF and
// proven by the pixel match), the comparisons, tC (8-472), and every sum that does not
// depend on the tables: the raw delta (8-468) and the raw p1 / q1 terms (8-470, 8-471),
// the strong-filter averages (8-478..8-488). C: the clips, the adds, the output mux.
// Every intermediate that can be negative is a signed logic of explicit width and is
// shifted with >>> (the spec's arithmetic ">>"); no `function automatic`, no N'() casts
// (Quartus 17, CLAUDE.md).
//
// Value ranges: the raw delta ((q0 - p0) << 2 + (p1 - q1) + 4) is -1275..1279 (12-bit
// signed), >> 3 is -160..159; tC is at most 25 + 2; p0 + delta is -27..282 and is
// Clip1'd; the p1 / q1 update needs no clip (the spec has none: the result lies
// between p1 and (p2 + avg) / 2, both in range); the strong-filter sums are at most
// 8 * 255 + 4 (11 bits unsigned).

`default_nettype none

module deblock_filter (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire  [7:0] p3, p2, p1, p0, q0, q1, q2, q3,
    input  wire  [2:0] bs,
    input  wire        chroma,
    input  wire  [5:0] qp_p,
    input  wire  [5:0] qp_q,
    input  wire signed [4:0] alpha_off,
    input  wire signed [4:0] beta_off,

    output logic       out_valid,
    output logic [7:0] p2o, p1o, p0o, q0o, q1o, q2o,
    output logic       changed
);

    // ---- stage A: qPav, indexA / indexB, the absolute differences -----------------------
    wire [6:0]        qpav   = ({1'b0, qp_p} + {1'b0, qp_q} + 7'd1) >> 1;      // 0..51
    wire signed [7:0] sum_a  = {1'b0, qpav} + {{3{alpha_off[4]}}, alpha_off};  // -12..63
    wire signed [7:0] sum_b  = {1'b0, qpav} + {{3{beta_off[4]}}, beta_off};
    wire [5:0]        idx_a  = sum_a[7] ? 6'd0 : (sum_a > 8'sd51) ? 6'd51 : sum_a[5:0];
    wire [5:0]        idx_b  = sum_b[7] ? 6'd0 : (sum_b > 8'sd51) ? 6'd51 : sum_b[5:0];
    // |a - b| of two 8-bit samples: the larger minus the smaller
    wire [7:0]        d_pq   = (p0 > q0) ? p0 - q0 : q0 - p0;
    wire [7:0]        d_p1   = (p1 > p0) ? p1 - p0 : p0 - p1;
    wire [7:0]        d_q1   = (q1 > q0) ? q1 - q0 : q0 - q1;
    wire [7:0]        d_ap   = (p2 > p0) ? p2 - p0 : p0 - p2;                 // ap (8-466)
    wire [7:0]        d_aq   = (q2 > q0) ? q2 - q0 : q0 - q2;                 // aq (8-467)

    logic        a_valid, a_chroma;
    logic [2:0]  a_bs;
    logic [7:0]  a_p3, a_p2, a_p1, a_p0, a_q0, a_q1, a_q2, a_q3;
    logic [5:0]  a_idx_a, a_idx_b;
    logic [7:0]  a_dpq, a_dp1, a_dq1, a_ap, a_aq;

    // ---- stage B: the tables, the decisions, the table-free sums ---------------------------
    // Table 8-16 (alpha and beta by indexA / indexB) and Table 8-17 (tC0 by bS and
    // indexA), as ROMs: entries 0..15 are 0, index 51 repeats the last value.
    logic [7:0] alpha;
    logic [4:0] beta;
    logic [4:0] tc0;
    always_comb begin
        case (a_idx_a)
            6'd16: alpha = 8'd4;   6'd17: alpha = 8'd4;   6'd18: alpha = 8'd5;   6'd19: alpha = 8'd6;
            6'd20: alpha = 8'd7;   6'd21: alpha = 8'd8;   6'd22: alpha = 8'd9;   6'd23: alpha = 8'd10;
            6'd24: alpha = 8'd12;  6'd25: alpha = 8'd13;  6'd26: alpha = 8'd15;  6'd27: alpha = 8'd17;
            6'd28: alpha = 8'd20;  6'd29: alpha = 8'd22;  6'd30: alpha = 8'd25;  6'd31: alpha = 8'd28;
            6'd32: alpha = 8'd32;  6'd33: alpha = 8'd36;  6'd34: alpha = 8'd40;  6'd35: alpha = 8'd45;
            6'd36: alpha = 8'd50;  6'd37: alpha = 8'd56;  6'd38: alpha = 8'd63;  6'd39: alpha = 8'd71;
            6'd40: alpha = 8'd80;  6'd41: alpha = 8'd90;  6'd42: alpha = 8'd101; 6'd43: alpha = 8'd113;
            6'd44: alpha = 8'd127; 6'd45: alpha = 8'd144; 6'd46: alpha = 8'd162; 6'd47: alpha = 8'd182;
            6'd48: alpha = 8'd203; 6'd49: alpha = 8'd226; 6'd50: alpha = 8'd255; 6'd51: alpha = 8'd255;
            default: alpha = 8'd0;
        endcase
        case (a_idx_b)
            6'd16: beta = 5'd2;   6'd17: beta = 5'd2;   6'd18: beta = 5'd2;   6'd19: beta = 5'd3;
            6'd20: beta = 5'd3;   6'd21: beta = 5'd3;   6'd22: beta = 5'd3;   6'd23: beta = 5'd4;
            6'd24: beta = 5'd4;   6'd25: beta = 5'd4;   6'd26: beta = 5'd6;   6'd27: beta = 5'd6;
            6'd28: beta = 5'd7;   6'd29: beta = 5'd7;   6'd30: beta = 5'd8;   6'd31: beta = 5'd8;
            6'd32: beta = 5'd9;   6'd33: beta = 5'd9;   6'd34: beta = 5'd10;  6'd35: beta = 5'd10;
            6'd36: beta = 5'd11;  6'd37: beta = 5'd11;  6'd38: beta = 5'd12;  6'd39: beta = 5'd12;
            6'd40: beta = 5'd13;  6'd41: beta = 5'd13;  6'd42: beta = 5'd14;  6'd43: beta = 5'd14;
            6'd44: beta = 5'd15;  6'd45: beta = 5'd15;  6'd46: beta = 5'd16;  6'd47: beta = 5'd16;
            6'd48: beta = 5'd17;  6'd49: beta = 5'd17;  6'd50: beta = 5'd18;  6'd51: beta = 5'd18;
            default: beta = 5'd0;
        endcase
        case ({a_bs, a_idx_a})
            // bS 1
            {3'd1, 6'd23}: tc0 = 5'd1;  {3'd1, 6'd24}: tc0 = 5'd1;  {3'd1, 6'd25}: tc0 = 5'd1;  {3'd1, 6'd26}: tc0 = 5'd1;
            {3'd1, 6'd27}: tc0 = 5'd1;  {3'd1, 6'd28}: tc0 = 5'd1;  {3'd1, 6'd29}: tc0 = 5'd1;  {3'd1, 6'd30}: tc0 = 5'd1;
            {3'd1, 6'd31}: tc0 = 5'd1;  {3'd1, 6'd32}: tc0 = 5'd1;  {3'd1, 6'd33}: tc0 = 5'd2;  {3'd1, 6'd34}: tc0 = 5'd2;
            {3'd1, 6'd35}: tc0 = 5'd2;  {3'd1, 6'd36}: tc0 = 5'd2;  {3'd1, 6'd37}: tc0 = 5'd3;  {3'd1, 6'd38}: tc0 = 5'd3;
            {3'd1, 6'd39}: tc0 = 5'd3;  {3'd1, 6'd40}: tc0 = 5'd4;  {3'd1, 6'd41}: tc0 = 5'd4;  {3'd1, 6'd42}: tc0 = 5'd4;
            {3'd1, 6'd43}: tc0 = 5'd5;  {3'd1, 6'd44}: tc0 = 5'd6;  {3'd1, 6'd45}: tc0 = 5'd6;  {3'd1, 6'd46}: tc0 = 5'd7;
            {3'd1, 6'd47}: tc0 = 5'd8;  {3'd1, 6'd48}: tc0 = 5'd9;  {3'd1, 6'd49}: tc0 = 5'd10; {3'd1, 6'd50}: tc0 = 5'd11;
            {3'd1, 6'd51}: tc0 = 5'd13;
            // bS 2
            {3'd2, 6'd21}: tc0 = 5'd1;  {3'd2, 6'd22}: tc0 = 5'd1;  {3'd2, 6'd23}: tc0 = 5'd1;  {3'd2, 6'd24}: tc0 = 5'd1;
            {3'd2, 6'd25}: tc0 = 5'd1;  {3'd2, 6'd26}: tc0 = 5'd1;  {3'd2, 6'd27}: tc0 = 5'd1;  {3'd2, 6'd28}: tc0 = 5'd1;
            {3'd2, 6'd29}: tc0 = 5'd1;  {3'd2, 6'd30}: tc0 = 5'd1;  {3'd2, 6'd31}: tc0 = 5'd2;  {3'd2, 6'd32}: tc0 = 5'd2;
            {3'd2, 6'd33}: tc0 = 5'd2;  {3'd2, 6'd34}: tc0 = 5'd2;  {3'd2, 6'd35}: tc0 = 5'd3;  {3'd2, 6'd36}: tc0 = 5'd3;
            {3'd2, 6'd37}: tc0 = 5'd3;  {3'd2, 6'd38}: tc0 = 5'd4;  {3'd2, 6'd39}: tc0 = 5'd4;  {3'd2, 6'd40}: tc0 = 5'd5;
            {3'd2, 6'd41}: tc0 = 5'd5;  {3'd2, 6'd42}: tc0 = 5'd6;  {3'd2, 6'd43}: tc0 = 5'd7;  {3'd2, 6'd44}: tc0 = 5'd8;
            {3'd2, 6'd45}: tc0 = 5'd8;  {3'd2, 6'd46}: tc0 = 5'd10; {3'd2, 6'd47}: tc0 = 5'd11; {3'd2, 6'd48}: tc0 = 5'd12;
            {3'd2, 6'd49}: tc0 = 5'd13; {3'd2, 6'd50}: tc0 = 5'd15; {3'd2, 6'd51}: tc0 = 5'd17;
            // bS 3
            {3'd3, 6'd17}: tc0 = 5'd1;  {3'd3, 6'd18}: tc0 = 5'd1;  {3'd3, 6'd19}: tc0 = 5'd1;  {3'd3, 6'd20}: tc0 = 5'd1;
            {3'd3, 6'd21}: tc0 = 5'd1;  {3'd3, 6'd22}: tc0 = 5'd1;  {3'd3, 6'd23}: tc0 = 5'd1;  {3'd3, 6'd24}: tc0 = 5'd1;
            {3'd3, 6'd25}: tc0 = 5'd1;  {3'd3, 6'd26}: tc0 = 5'd1;  {3'd3, 6'd27}: tc0 = 5'd2;  {3'd3, 6'd28}: tc0 = 5'd2;
            {3'd3, 6'd29}: tc0 = 5'd2;  {3'd3, 6'd30}: tc0 = 5'd2;  {3'd3, 6'd31}: tc0 = 5'd3;  {3'd3, 6'd32}: tc0 = 5'd3;
            {3'd3, 6'd33}: tc0 = 5'd3;  {3'd3, 6'd34}: tc0 = 5'd4;  {3'd3, 6'd35}: tc0 = 5'd4;  {3'd3, 6'd36}: tc0 = 5'd4;
            {3'd3, 6'd37}: tc0 = 5'd5;  {3'd3, 6'd38}: tc0 = 5'd6;  {3'd3, 6'd39}: tc0 = 5'd6;  {3'd3, 6'd40}: tc0 = 5'd7;
            {3'd3, 6'd41}: tc0 = 5'd8;  {3'd3, 6'd42}: tc0 = 5'd9;  {3'd3, 6'd43}: tc0 = 5'd10; {3'd3, 6'd44}: tc0 = 5'd11;
            {3'd3, 6'd45}: tc0 = 5'd13; {3'd3, 6'd46}: tc0 = 5'd14; {3'd3, 6'd47}: tc0 = 5'd16; {3'd3, 6'd48}: tc0 = 5'd18;
            {3'd3, 6'd49}: tc0 = 5'd20; {3'd3, 6'd50}: tc0 = 5'd23; {3'd3, 6'd51}: tc0 = 5'd25;
            default: tc0 = 5'd0;
        endcase
    end

    // filterSamplesFlag (8-460) and the side conditions (8-466 .. 8-467, 8-473 .. 8-475)
    wire       b_flag   = (a_bs != 3'd0) && (a_dpq < alpha) && (a_dp1 < {3'b000, beta}) && (a_dq1 < {3'b000, beta});
    wire       b_ap_lt  = (a_ap < {3'b000, beta});
    wire       b_aq_lt  = (a_aq < {3'b000, beta});
    wire [7:0] a_quarter = {2'b00, alpha[7:2]} + 8'd2;                    // (alpha >> 2) + 2
    wire       b_close  = (a_dpq < a_quarter);                            // bS 4 luma strong condition
    // tC (8-472): luma tC0 + (ap < beta) + (aq < beta); chroma tC0 + 1
    wire [4:0] b_tc     = a_chroma ? tc0 + 5'd1 : tc0 + {4'd0, b_ap_lt} + {4'd0, b_aq_lt};

    // the samples as signed 12-bit values
    logic signed [11:0] sp2, sp1, sp0, sq0, sq1, sq2;
    assign sp2 = {4'b0000, a_p2}; assign sp1 = {4'b0000, a_p1}; assign sp0 = {4'b0000, a_p0};
    assign sq0 = {4'b0000, a_q0}; assign sq1 = {4'b0000, a_q1}; assign sq2 = {4'b0000, a_q2};
    // the raw delta (8-468) before the clip: (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3
    wire signed [11:0] d_raw  = ((sq0 - sp0) <<< 2) + (sp1 - sq1) + 12'sd4;
    wire signed [11:0] d_sh   = d_raw >>> 3;
    // the raw p1 / q1 terms (8-470, 8-471): (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1
    wire signed [11:0] avg_pq = (sp0 + sq0 + 12'sd1) >>> 1;
    wire signed [11:0] t1p    = (sp2 + avg_pq - (sp1 <<< 1)) >>> 1;
    wire signed [11:0] t1q    = (sq2 + avg_pq - (sq1 <<< 1)) >>> 1;
    // bS 4 (8.7.2.4): the strong luma filter (8-478..8-480 / 8-484..8-486) ...
    wire [10:0] s_p0 = ({3'd0, a_p2} + {2'd0, a_p1, 1'b0} + {2'd0, a_p0, 1'b0} + {2'd0, a_q0, 1'b0} + {3'd0, a_q1} + 11'd4) >> 3;
    wire [10:0] s_p1 = ({3'd0, a_p2} + {3'd0, a_p1} + {3'd0, a_p0} + {3'd0, a_q0} + 11'd2) >> 2;
    wire [10:0] s_p2 = ({2'd0, a_p3, 1'b0} + {3'd0, a_p2} + {2'd0, a_p2, 1'b0} + {3'd0, a_p1} + {3'd0, a_p0} + {3'd0, a_q0} + 11'd4) >> 3;
    wire [10:0] s_q0 = ({3'd0, a_p1} + {2'd0, a_p0, 1'b0} + {2'd0, a_q0, 1'b0} + {2'd0, a_q1, 1'b0} + {3'd0, a_q2} + 11'd4) >> 3;
    wire [10:0] s_q1 = ({3'd0, a_p0} + {3'd0, a_q0} + {3'd0, a_q1} + {3'd0, a_q2} + 11'd2) >> 2;
    wire [10:0] s_q2 = ({2'd0, a_q3, 1'b0} + {3'd0, a_q2} + {2'd0, a_q2, 1'b0} + {3'd0, a_q1} + {3'd0, a_q0} + {3'd0, a_p0} + 11'd4) >> 3;
    // ... and the weak one, also the chroma bS 4 filter (8-481 / 8-487): (2 p1 + p0 + q1 + 2) >> 2
    wire [10:0] w_p0 = ({2'd0, a_p1, 1'b0} + {3'd0, a_p0} + {3'd0, a_q1} + 11'd2) >> 2;
    wire [10:0] w_q0 = ({2'd0, a_q1, 1'b0} + {3'd0, a_q0} + {3'd0, a_p1} + 11'd2) >> 2;

    logic        b_valid, b_chroma, b_bs4, b_on, b_apl, b_aql, b_strong_ok;
    logic [7:0]  b_p2, b_p1, b_p0, b_q0, b_q1, b_q2;
    logic [4:0]  b_tc_r, b_tc0_r;
    logic signed [11:0] b_d, b_t1p, b_t1q;
    logic [7:0]  b_sp0, b_sp1, b_sp2, b_sq0, b_sq1, b_sq2, b_wp0, b_wq0;

    // ---- stage C: the clips, the adds, the output mux ---------------------------------------
    logic signed [11:0] tc_s, tc0_s, d_clip, t1p_clip, t1q_clip, np0_raw, nq0_raw;
    assign tc_s  = {7'd0, b_tc_r};
    assign tc0_s = {7'd0, b_tc0_r};
    assign d_clip   = (b_d > tc_s) ? tc_s : (b_d < -tc_s) ? -tc_s : b_d;                  // Clip3(-tC, tC, delta) (8-468)
    assign t1p_clip = (b_t1p > tc0_s) ? tc0_s : (b_t1p < -tc0_s) ? -tc0_s : b_t1p;       // Clip3(-tC0, tC0, ...) (8-470)
    assign t1q_clip = (b_t1q > tc0_s) ? tc0_s : (b_t1q < -tc0_s) ? -tc0_s : b_t1q;       // (8-471)
    assign np0_raw  = {4'b0000, b_p0} + d_clip;                                            // p0 + delta, then Clip1 (8-469)
    assign nq0_raw  = {4'b0000, b_q0} - d_clip;
    wire [7:0] np0_w = np0_raw[11] ? 8'd0 : (np0_raw > 12'sd255) ? 8'd255 : np0_raw[7:0];
    wire [7:0] nq0_w = nq0_raw[11] ? 8'd0 : (nq0_raw > 12'sd255) ? 8'd255 : nq0_raw[7:0];
    wire signed [11:0] np1_raw = {4'b0000, b_p1} + t1p_clip;                               // in range by construction
    wire signed [11:0] nq1_raw = {4'b0000, b_q1} + t1q_clip;
    wire       luma_p1 = !b_chroma && b_apl;                                               // p1 changes only for luma with ap < beta
    wire       luma_q1 = !b_chroma && b_aql;
    wire       strong_p = !b_chroma && b_apl && b_strong_ok;                               // 8-477
    wire       strong_q = !b_chroma && b_aql && b_strong_ok;                               // 8-483

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_valid <= 1'b0; a_chroma <= 1'b0; a_bs <= 3'd0;
            a_p3 <= 8'd0; a_p2 <= 8'd0; a_p1 <= 8'd0; a_p0 <= 8'd0; a_q0 <= 8'd0; a_q1 <= 8'd0; a_q2 <= 8'd0; a_q3 <= 8'd0;
            a_idx_a <= 6'd0; a_idx_b <= 6'd0;
            a_dpq <= 8'd0; a_dp1 <= 8'd0; a_dq1 <= 8'd0; a_ap <= 8'd0; a_aq <= 8'd0;
            b_valid <= 1'b0; b_chroma <= 1'b0; b_bs4 <= 1'b0; b_on <= 1'b0; b_apl <= 1'b0; b_aql <= 1'b0; b_strong_ok <= 1'b0;
            b_p2 <= 8'd0; b_p1 <= 8'd0; b_p0 <= 8'd0; b_q0 <= 8'd0; b_q1 <= 8'd0; b_q2 <= 8'd0;
            b_tc_r <= 5'd0; b_tc0_r <= 5'd0; b_d <= 12'sd0; b_t1p <= 12'sd0; b_t1q <= 12'sd0;
            b_sp0 <= 8'd0; b_sp1 <= 8'd0; b_sp2 <= 8'd0; b_sq0 <= 8'd0; b_sq1 <= 8'd0; b_sq2 <= 8'd0; b_wp0 <= 8'd0; b_wq0 <= 8'd0;
            out_valid <= 1'b0; changed <= 1'b0;
            p2o <= 8'd0; p1o <= 8'd0; p0o <= 8'd0; q0o <= 8'd0; q1o <= 8'd0; q2o <= 8'd0;
        end else begin
            // A
            a_valid <= in_valid;
            a_chroma <= chroma; a_bs <= bs;
            a_p3 <= p3; a_p2 <= p2; a_p1 <= p1; a_p0 <= p0; a_q0 <= q0; a_q1 <= q1; a_q2 <= q2; a_q3 <= q3;
            a_idx_a <= idx_a; a_idx_b <= idx_b;
            a_dpq <= d_pq; a_dp1 <= d_p1; a_dq1 <= d_q1; a_ap <= d_ap; a_aq <= d_aq;
            // B
            b_valid <= a_valid;
            b_chroma <= a_chroma; b_bs4 <= (a_bs == 3'd4);
            b_on <= b_flag; b_apl <= b_ap_lt; b_aql <= b_aq_lt; b_strong_ok <= b_close;
            b_p2 <= a_p2; b_p1 <= a_p1; b_p0 <= a_p0; b_q0 <= a_q0; b_q1 <= a_q1; b_q2 <= a_q2;
            b_tc_r <= b_tc; b_tc0_r <= tc0;
            b_d <= d_sh; b_t1p <= t1p; b_t1q <= t1q;
            b_sp0 <= s_p0[7:0]; b_sp1 <= s_p1[7:0]; b_sp2 <= s_p2[7:0];
            b_sq0 <= s_q0[7:0]; b_sq1 <= s_q1[7:0]; b_sq2 <= s_q2[7:0];
            b_wp0 <= w_p0[7:0]; b_wq0 <= w_q0[7:0];
            // C
            out_valid <= b_valid;
            changed <= b_on;
            if (!b_on) begin
                p2o <= b_p2; p1o <= b_p1; p0o <= b_p0; q0o <= b_q0; q1o <= b_q1; q2o <= b_q2;
            end else if (b_bs4) begin
                p0o <= strong_p ? b_sp0 : b_wp0;
                p1o <= strong_p ? b_sp1 : b_p1;
                p2o <= strong_p ? b_sp2 : b_p2;
                q0o <= strong_q ? b_sq0 : b_wq0;
                q1o <= strong_q ? b_sq1 : b_q1;
                q2o <= strong_q ? b_sq2 : b_q2;
            end else begin
                p0o <= np0_w;
                q0o <= nq0_w;
                p1o <= luma_p1 ? np1_raw[7:0] : b_p1;
                q1o <= luma_q1 ? nq1_raw[7:0] : b_q1;
                p2o <= b_p2;
                q2o <= b_q2;
            end
        end
    end

endmodule

`default_nettype wire
