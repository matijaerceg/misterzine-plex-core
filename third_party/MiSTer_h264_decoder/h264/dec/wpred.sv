// h264/dec/wpred.sv -- weighted sample prediction (ITU-T H.264 8.4.2.3)
//
//   8.4.2.3.1  default   single list: out = a          bi: out = (a + b + 1) >> 1
//   8.4.2.3.2  weighted  single list: logWD >= 1  Clip1(((a * w0 + 2^(logWD-1)) >> logWD) + o0)
//                                     logWD == 0  Clip1(a * w0 + o0)
//                        bi:          Clip1(((a * w0 + b * w1 + 2^logWD) >> (logWD + 1))
//                                           + ((o0 + o1 + 1) >> 1))
//   8.4.3      implicit  the bi weighted formula with logWD = 5, o0 = o1 = 0 and the
//                        weights from the POC distances; the CALLER derives those (they
//                        need the reference lists) and presents mode 1 -- there is no
//                        third mode here. Its weights reach 128 (DistScaleFactor >> 2 is
//                        accepted up to 128, so w1 = 128, w0 = -64 is legal): the weight
//                        ports are 9-bit signed, -128..128. Offsets are -128..127 (7.4.3.2,
//                        8-bit samples: o = luma_offset_l0 << (BitDepth - 8) = the syntax
//                        value).
//
// Bit-exact against the formulas above as tools/mc_golden.py transcribes them from the
// spec text, cross-checked there against tools/h264_recon_ref.py's
// SliceDecoder.weighted on a real weighted x264 clip; scored by bench/h264/run_mc.sh.
// docs/h264_recon.md S2.4.
//
// start (one pulse, ignored while busy) latches bi / mode / logwd / w0 w1 o0 o1 / n and
// arms the intake: n samples (1..256) are taken from stream a (and, when bi, one from b
// for each -- a sample is taken only when both are offered), one per cycle when the
// consumer is ready, and leave on out_valid/out/out_last with out_ready as the throttle.
// busy rises with start and drops when the last sample is taken. a_ready / b_ready are
// combinational (they follow out_ready through the pipeline enable): the three stages
// -- the two products, the rounded and shifted sum plus the offset, the clip into the
// output register -- move together on one enable, so no sample is ever held in more than
// one place and the stream is one per cycle end to end. mode[1] is reserved (read as
// weighted). Two 10x9 signed multipliers (DSPs, or ~90 ALMs each), a barrel shift by
// 0..8, the rest is adds. Written without function helpers or N'() casts (Quartus 17,
// CLAUDE.md).

`default_nettype none

module wpred (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               start,
    input  wire               bi,
    input  wire         [1:0] mode,        // 0 default, 1 weighted (explicit or implicit)
    input  wire         [2:0] logwd,       // luma_log2_weight_denom / chroma_..., 0..7
    input  wire signed  [8:0] w0,          // -128..128 (128 only from 8.4.3)
    input  wire signed  [8:0] w1,
    input  wire signed  [7:0] o0,
    input  wire signed  [7:0] o1,
    input  wire         [8:0] n,           // samples, 1..256

    input  wire               a_valid,     // list 0 (or the single list) prediction
    input  wire         [7:0] a,
    output logic              a_ready,
    input  wire               b_valid,     // list 1 prediction, read only when bi
    input  wire         [7:0] b,
    output logic              b_ready,

    output logic              out_valid,
    output logic        [7:0] out,
    output logic              out_last,
    input  wire               out_ready,

    output logic              busy
);

    // ---- the parameters, latched at start ----------------------------------------------
    logic               bi_r, wgt;          // wgt: mode != 0
    logic        [2:0]  lw;
    logic signed [8:0]  w0_r, w1_r;
    logic signed [7:0]  o0_r, o1_r;
    logic        [8:0]  n_r, cnt;           // cnt: samples taken so far
    logic               taking;             // samples still to take

    // ---- the pipeline enable and the intake --------------------------------------------
    wire adv  = !out_valid || out_ready;
    wire take = adv && taking && a_valid && (!bi_r || b_valid);
    wire last = (cnt == n_r - 9'd1);
    assign a_ready = take;
    assign b_ready = take && bi_r;

    // ---- S1: the products ----------------------------------------------------------------
    logic               s1_v, s1_last;
    logic        [7:0]  s1_a, s1_b;
    logic signed [17:0] p0, p1;             // 0..255 x -128..128: |p| <= 32640
    wire  signed [9:0]  a_s = {2'b00, a};
    wire  signed [9:0]  b_s = {2'b00, b};

    // ---- S2: the rounded, shifted sum plus the offset ----------------------------------
    logic               s2_v, s2_last;
    logic signed [19:0] s2_val;
    wire  signed [19:0] p0x   = {{2{p0[17]}}, p0};
    wire  signed [19:0] p1x   = {{2{p1[17]}}, p1};
    wire  signed [19:0] rnd_b = 20'sd1 <<< lw;                                    // 2^logWD
    wire  signed [19:0] rnd_s = (lw == 3'd0) ? 20'sd0 : (20'sd1 <<< (lw - 3'd1)); // 2^(logWD-1); none at logWD 0
    // (P5b: S2 split -- S2a the rounded sums registered, S2b the shift, the offset and the
    // mode select; the products into the three-term add, the variable shift and the select
    // in one cycle were 9.9 ns. The pipeline still moves as a whole on adv)
    wire  signed [19:0] sum_b = p0x + p1x + rnd_b;
    wire  signed [19:0] sum_s = p0x + rnd_s;
    logic               s2a_v, s2a_last;
    logic        [7:0]  s2a_a, s2a_b;
    logic signed [19:0] s2a_sb, s2a_ss;
    wire  signed [19:0] sh_b  = s2a_sb >>> (lw + 4'd1);
    wire  signed [19:0] sh_s  = s2a_ss >>> lw;
    wire  signed [9:0]  o0x   = {{2{o0_r[7]}}, o0_r};
    wire  signed [9:0]  o1x   = {{2{o1_r[7]}}, o1_r};
    wire  signed [9:0]  off_b = (o0x + o1x + 10'sd1) >>> 1;                       // (o0 + o1 + 1) >> 1
    wire  signed [9:0]  avg_d = ({2'b00, s2a_a} + {2'b00, s2a_b} + 10'sd1) >>> 1; // (a + b + 1) >> 1
    wire  signed [19:0] avg_dx = {{10{avg_d[9]}}, avg_d};
    wire  signed [19:0] o0xx   = {{10{o0x[9]}}, o0x};
    wire  signed [19:0] off_bx = {{10{off_b[9]}}, off_b};
    logic signed [19:0] v;
    always_comb begin
        case ({wgt, bi_r})
            2'b00:   v = {12'd0, s2a_a};
            2'b01:   v = avg_dx;
            2'b10:   v = sh_s + o0xx;
            default: v = sh_b + off_bx;
        endcase
    end

    // ---- S3: Clip1 into the output register ---------------------------------------------
    wire [7:0] v_clip = s2_val[19] ? 8'd0 : (|s2_val[18:8]) ? 8'd255 : s2_val[7:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bi_r <= 1'b0; wgt <= 1'b0; lw <= 3'd0;
            w0_r <= 9'sd0; w1_r <= 9'sd0; o0_r <= 8'sd0; o1_r <= 8'sd0;
            n_r <= 9'd0; cnt <= 9'd0; taking <= 1'b0; busy <= 1'b0;
            s1_v <= 1'b0; s1_last <= 1'b0; s1_a <= 8'd0; s1_b <= 8'd0; p0 <= 18'sd0; p1 <= 18'sd0;
            s2_v <= 1'b0; s2_last <= 1'b0; s2_val <= 20'sd0;
            s2a_v <= 1'b0; s2a_last <= 1'b0; s2a_a <= 8'd0; s2a_b <= 8'd0; s2a_sb <= 20'sd0; s2a_ss <= 20'sd0;
            out_valid <= 1'b0; out <= 8'd0; out_last <= 1'b0;
        end else begin
            if (start && !busy) begin
                bi_r <= bi; wgt <= |mode; lw <= logwd;
                w0_r <= w0; w1_r <= w1; o0_r <= o0; o1_r <= o1;
                n_r <= n; cnt <= 9'd0; taking <= 1'b1; busy <= 1'b1;
            end else begin
                if (take) begin
                    cnt <= cnt + 9'd1;
                    if (last) taking <= 1'b0;
                end
                if (out_valid && out_ready && out_last) busy <= 1'b0;
            end
            if (adv) begin
                s1_v <= take; s1_last <= take && last; s1_a <= a; s1_b <= b;
                p0 <= a_s * w0_r;
                p1 <= b_s * w1_r;
                s2a_v <= s1_v; s2a_last <= s1_last; s2a_a <= s1_a; s2a_b <= s1_b; s2a_sb <= sum_b; s2a_ss <= sum_s;
                s2_v <= s2a_v; s2_last <= s2a_last; s2_val <= v;
                out_valid <= s2_v; out_last <= s2_last; out <= v_clip;
            end
        end
    end

endmodule

`default_nettype wire
