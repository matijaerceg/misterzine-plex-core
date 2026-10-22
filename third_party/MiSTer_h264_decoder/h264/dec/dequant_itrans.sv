// h264/dec/dequant_itrans.sv -- inverse scan, scaling and inverse transform of one
// residual block (ITU-T H.264 8.5.6 inverse scanning, Table 8-13; 8.5.10 Intra16x16 luma
// DC; 8.5.11 chroma DC (4:2:0); 8.5.12.1 scaling; 8.5.12.2 the 4x4 inverse transform).
// H264 Phase 5 (High profile, docs/high_profile.md S5): LevelScale4x4 = weightScale4x4 x
// normAdjust4x4 (8-313) with the slice's scaling list `wlist` read through a weight port
// (wflat: every weight 16, the Main-profile numbers exactly).
//
// Bit-exact against tools/h264_recon_ref.py (dequant4x4 + itrans4x4, luma_dc,
// chroma_dc -- proven pixel-exact vs ffmpeg and the H.264.1 reference YUVs), scored by
// bench/h264/run_dequant_itrans.sh over fixtures from tools/itrans_golden.py: every
// QP x both scans x every kind, sparse and zero blocks, and real x264 blocks.
// docs/h264_recon.md S2.4.
//
// One block per `start` (a pulse, taken while !busy):
//   kind 0 L4   16 coefficients in scan order -> 16 residual samples r_ij, raster 4i+j
//   kind 1 LAC  15 AC coefficients of an Intra16x16 luma block (scan positions 1..15),
//               d00 = dc_in (the dcY value 8.5.10 produced)         -> 16 samples
//   kind 2 CAC  15 chroma AC coefficients, d00 = dc_in (the dcC of 8.5.11) -> 16 samples
//   kind 3 LDC  16 Intra16x16 DC levels in scan order -> the 16 scaled dcY_ij, raster 4i+j
//   kind 4 CDC  4 chroma DC levels c0..c3 -> the 4 scaled dcC in order dc00 dc01 dc10 dc11
//   kinds 5..7  not defined; decoded as kind 0 (the parent never issues them)
// `qp` is QP'Y (kinds 0, 1, 3) or QP'C (kinds 2, 4), 0..51. `field_scan` selects the
// field scan of Table 8-13 (field pictures) over the zig-zag. `kind`, `qp`, `field_scan`,
// `dc_in`, `wflat` and `wlist` are sampled with `start`. The weights: `w_ra` addresses word
// {wlist, k / 4} of the active matrix (tools/h264_fe_ref.py scaling_words: four weights a
// word, coded -- zig-zag -- order, the first in bits 7..0; k the zig-zag index of the
// coefficient's raster position, hp_zzinv4: a scaling list is always inverse-scanned with
// the zig-zag, 8.5.6), its word `w_q` the cycle after.
//
// Datapath (serial: one coefficient in per cycle, one sample out per cycle):
//   intake  -- each coefficient is placed by the scan ROM at its raster position and, for
//              kinds 0..2, scaled on the way in over two stages: its weight read and
//              c * weightScale (stage 1), then * normAdjust4x4 and the shift of 8.5.12.1
//              with the rounding term of eq. 8-337 (qp < 24). (The fork omitted that term:
//              with flat lists LevelScale is a multiple of 16 and the term can never carry
//              into the surviving bits; a weight other than 16 breaks that, H264 Phase 5.)
//              Kinds 3, 4 store the raw levels (the DC transforms come before their
//              scaling: 8.5.10, 8.5.11), which scale by LevelScale4x4(qp%6, 0, 0) = the
//              list's weightScale(0, 0) x normAdjust -- that weight is read at `start`.
//   rows    -- 4 cycles, one 4-point butterfly per cycle, in place (8.5.12.2 e/f for
//              kinds 0..2; the Hadamard for kind 3 -- exact integer sums, so rows before
//              columns gives the same f as the spec's H c H).
//   columns -- 4 cycles into the output buffer (g/h, or the second Hadamard pass); kind 4
//              is the one 2x2 Hadamard cycle (eq. 8-328) straight into the output buffer.
//   output  -- one sample per cycle from the output buffer: r = (h + 32) >> 6 (kinds
//              0..2), the DC scaling of 8.5.10 (kind 3, both branches, with its rounding
//              term -- that one is real below qp 12) or of 8.5.11.2 (kind 4).
// exp/mb-pipeline (docs/mb_pipeline.md): TWO work buffers. The intake fills one while the
// transform (rows, columns, with its own copy of the block's parameters) works on the
// other; `busy` drops when the intake hands its block to the transform, so the next
// block's 16 coefficients arrive under this block's 9 transform cycles (~20 cycles a
// 16-coefficient block, was 28).
// The output buffer is separate from the work buffers, so the next block's intake and
// transform overlap this block's output stream: `busy` drops when the INTAKE hands its
// block to the transform (S_HOLD), and the parent may `start` the next block then -- so up
// to three blocks are in flight (intake, transform, output stream; a parent's descriptor
// FIFO must hold three). The transform's column pass waits if the output stream has not
// drained the buffer yet. Steady state with a ready consumer and a coefficient every cycle:
// ~21 cycles per 16-coefficient block (1 start + 16 intake + 3 drain + the hand-off; the 4
// rows + 4 columns run under the next intake), 22 measured with a registered start
// (run_dequant_itrans.sh); 8 per chroma DC block. (Was 28: one work buffer.)
//
// Widths. The spec bounds a conforming stream's d_ij, f_ij, h_ij (8.5.12), dcY (8.5.10)
// and dcC (8.5.11.2) to 16 bits signed at 8-bit depth (-2^15 .. 2^15-1); the butterfly
// intermediates e_ij and g_ij may legally reach 17 bits. Both buffers are 20 bits wide:
// the transform path has 3 bits of headroom above the widest legal intermediate, and the
// Intra16x16 DC Hadamard is exact for ANY 16-bit levels (16 sums: 16 + 4 = 20 bits). The
// butterfly itself computes in 22 bits. Scaling products are formed at full width (16 x
// 8 -> 24 then x 5 -> 29 bits on the way in, 20 x 14 -> 34 bits on the way out; separate
// multipliers per stage, because the stages run in the same cycle when blocks overlap) and the
// shifted result is truncated to the buffer / output width: a non-conforming stream that
// overflows wraps, it is never clamped (the spec says the bitstream shall not do it; the
// parent counts errors elsewhere). Every right shift is arithmetic (the spec's >> on
// signed values).
//
// Quartus 17 (CLAUDE.md): tables are `case` ROMs, no `function automatic` helpers, no
// N'() casts; the butterfly operands are sign-extended explicitly before any shift so no
// context-width rule is relied on. The two 16-entry buffers are register arrays: the work
// buffer is read by three fixed 4:1 patterns (a row, a column, the first four entries),
// the output buffer by one 16:1 mux -- 640 flops, no LUT-RAM explosion possible.

`default_nettype none

module dequant_itrans (
    input  wire         clk,
    input  wire         rst_n,

    // one block
    input  wire         start,
    input  wire  [2:0]  kind,
    input  wire  [5:0]  qp,
    input  wire         field_scan,
    input  wire signed [15:0] dc_in,
    input  wire         wflat,             // the slice's matrix is Flat_16 (no weight reads used)
    input  wire  [2:0]  wlist,             // the 4x4 scaling list: Intra Y Cb Cr 0..2, Inter 3..5
    output logic [4:0]  w_ra,              // weight word {wlist, k[3:2]} (lists 0..5: words 0..23)
    input  wire  [31:0] w_q,               //   and its data, the cycle after

    // the coefficients in scan order
    input  wire         coef_valid,
    input  wire signed [15:0] coef,
    output logic        coef_ready,

    // the residual samples (or scaled DC values) in raster order
    output logic        res_valid,
    output logic signed [15:0] res,
    output logic        res_last,
    input  wire         res_ready,

    output logic        busy
);

    // kind 0 (L4) is the default of every kind test below, so it needs no name
    localparam [2:0] K_LAC = 3'd1, K_CAC = 3'd2, K_LDC = 3'd3, K_CDC = 3'd4;

    // the intake (state) and the transform (tst) are separate machines (two work buffers)
    typedef enum logic [3:0] {S_IDLE, S_IN, S_DRAIN, S_DRAIN2, S_DRAIN3, S_HOLD} state_t;
    state_t state;
    typedef enum logic [2:0] {T_IDLE, T_ROW, T_ROWW, T_COL, T_CDC} tstate_t;
    tstate_t tst;
    logic        wsel, tsel;            // the buffer the intake fills / the transform works on
    logic [2:0]  t_kind;                // the transform's block: its kind, qp / 6, qp % 6, w00
    logic [3:0]  t_q6;
    logic [2:0]  t_m;
    logic [7:0]  t_w00;

    // ---- the block's parameters ----------------------------------------------------
    logic [2:0]  b_kind;
    logic [3:0]  b_q6;                  // qp / 6, 0..8
    logic [2:0]  b_m;                   // qp % 6
    logic        b_field;
    logic [4:0]  b_ncoef;               // 16, 15 or 4
    logic [4:0]  cnt;                   // coefficients accepted so far
    logic        b_flat;
    logic [2:0]  b_list;
    logic [7:0]  b_w00;                 // weightScale(0, 0) of the block's list (the DC kinds)
    logic        w00_pend;              // the w00 read lands this cycle (the first of S_IN)

    wire is_ac  = (b_kind == K_LAC) || (b_kind == K_CAC);
    wire is_dc  = (b_kind == K_LDC) || (b_kind == K_CDC);

    // qp -> (qp / 6, qp % 6) at start: a comparator chain, no divider
    logic [3:0] q6_w;
    logic [5:0] six_q6;
    always_comb begin
        if      (qp >= 6'd48) q6_w = 4'd8;
        else if (qp >= 6'd42) q6_w = 4'd7;
        else if (qp >= 6'd36) q6_w = 4'd6;
        else if (qp >= 6'd30) q6_w = 4'd5;
        else if (qp >= 6'd24) q6_w = 4'd4;
        else if (qp >= 6'd18) q6_w = 4'd3;
        else if (qp >= 6'd12) q6_w = 4'd2;
        else if (qp >= 6'd6)  q6_w = 4'd1;
        else                  q6_w = 4'd0;
        six_q6 = {1'b0, q6_w, 1'b0} + {q6_w, 2'b00};
    end
    wire [5:0] m_w = qp - six_q6;

    // ---- the work buffers (d / f, or the DC levels / their first Hadamard pass) --------
    logic signed [19:0] A0 [0:15];
    logic signed [19:0] A1 [0:15];
    // ---- the output buffer (h, or the transformed DC values before scaling) ------------
    logic signed [19:0] O [0:15];

    // ---- intake: scan position -> raster (Table 8-13) and its LevelScale class ---------
    // k is the scan index of the coefficient being accepted: cnt for a 16-coefficient
    // block, cnt + 1 for an AC block (scan positions 1..15)
    wire [4:0] k_full = cnt + (is_ac ? 5'd1 : 5'd0);
    wire [3:0] k_idx  = k_full[3:0];
    logic [3:0] scan_r;
    always_comb begin
        case ({b_field, k_idx})
            // zig-zag (frame macroblocks): raster 4i+j
            5'h00: scan_r = 4'd0;  5'h01: scan_r = 4'd1;  5'h02: scan_r = 4'd4;  5'h03: scan_r = 4'd8;
            5'h04: scan_r = 4'd5;  5'h05: scan_r = 4'd2;  5'h06: scan_r = 4'd3;  5'h07: scan_r = 4'd6;
            5'h08: scan_r = 4'd9;  5'h09: scan_r = 4'd12; 5'h0A: scan_r = 4'd13; 5'h0B: scan_r = 4'd10;
            5'h0C: scan_r = 4'd7;  5'h0D: scan_r = 4'd11; 5'h0E: scan_r = 4'd14; 5'h0F: scan_r = 4'd15;
            // field scan (field pictures)
            5'h10: scan_r = 4'd0;  5'h11: scan_r = 4'd4;  5'h12: scan_r = 4'd1;  5'h13: scan_r = 4'd8;
            5'h14: scan_r = 4'd12; 5'h15: scan_r = 4'd5;  5'h16: scan_r = 4'd9;  5'h17: scan_r = 4'd13;
            5'h18: scan_r = 4'd2;  5'h19: scan_r = 4'd6;  5'h1A: scan_r = 4'd10; 5'h1B: scan_r = 4'd14;
            5'h1C: scan_r = 4'd3;  5'h1D: scan_r = 4'd7;  5'h1E: scan_r = 4'd11; 5'h1F: scan_r = 4'd15;
            default: scan_r = 4'd0;
        endcase
    end
    // chroma DC levels go to positions 0..3 as given (c0..c3 of eq. 8-328)
    wire [3:0] in_r = (b_kind == K_CDC) ? cnt[3:0] : scan_r;
    // 8.5.9: normAdjust4x4 class of (i, j): 0 both even, 1 both odd, 2 mixed;
    // raster r = 4i + j, so i odd is r[2] and j odd is r[0]
    logic [1:0] in_cls;
    always_comb begin
        case ({in_r[2], in_r[0]})
            2'b00:   in_cls = 2'd0;
            2'b11:   in_cls = 2'd1;
            default: in_cls = 2'd2;
        endcase
    end

    // the weight word of the coefficient being accepted (its zig-zag index), or at start
    // weightScale(0, 0) of the block's list (word 0, byte 0)
    logic [3:0] in_kz;
    hp_zzinv4 u_zz (.r(in_r), .k(in_kz));
    always_comb w_ra = (state == S_IDLE) ? {wlist[2:0], 2'b00} : {b_list, in_kz[3:2]};

    // stage 1: the accepted coefficient with its raster position, class and weight byte
    logic               p1_valid;
    logic signed [15:0] p1_coef;
    logic [3:0]         p1_r;
    logic [1:0]         p1_cls;
    logic [1:0]         p1_kb;          // the weight's byte in w_q
    logic [7:0]         w1;             // the coefficient's weightScale4x4(i, j)
    always_comb begin
        case (p1_kb)
            2'd0: w1 = w_q[7:0];   2'd1: w1 = w_q[15:8];
            2'd2: w1 = w_q[23:16]; default: w1 = w_q[31:24];
        endcase
        if (b_flat) w1 = 8'd16;
    end
    // stage 2: c * weightScale registered, with the position and class
    logic               p2_valid;
    logic signed [23:0] p2_cw;
    logic signed [15:0] p2_coef;
    logic [3:0]         p2_r;
    logic [1:0]         p2_cls;
    logic [4:0]         p2_na;          // normAdjust4x4 of the stage-2 coefficient, registered

    // normAdjust4x4(m, i, j) (8-314 / 8-315: 10 16 13 / 11 18 14 / 13 20 16 / 14 23 18 /
    // 16 25 20 / 18 29 23), looked up for the coefficient in stage 1 and registered with it
    // (the lookup in the multiply's cycle missed clk_dec: P5 fit 2026-09-28, -0.29 ns) and,
    // class 0, for the DC scaling of the block being handed to the output (x weightScale(0, 0))
    logic [4:0] na_in, na_dc;
    always_comb begin
        case ({b_m, p1_cls})
            5'b000_00: na_in = 5'd10; 5'b000_01: na_in = 5'd16; 5'b000_10: na_in = 5'd13;
            5'b001_00: na_in = 5'd11; 5'b001_01: na_in = 5'd18; 5'b001_10: na_in = 5'd14;
            5'b010_00: na_in = 5'd13; 5'b010_01: na_in = 5'd20; 5'b010_10: na_in = 5'd16;
            5'b011_00: na_in = 5'd14; 5'b011_01: na_in = 5'd23; 5'b011_10: na_in = 5'd18;
            5'b100_00: na_in = 5'd16; 5'b100_01: na_in = 5'd25; 5'b100_10: na_in = 5'd20;
            5'b101_00: na_in = 5'd18; 5'b101_01: na_in = 5'd29; 5'b101_10: na_in = 5'd23;
            default:   na_in = 5'd10;
        endcase
        case (t_m)
            3'd0: na_dc = 5'd10;
            3'd1: na_dc = 5'd11;
            3'd2: na_dc = 5'd13;
            3'd3: na_dc = 5'd14;
            3'd4: na_dc = 5'd16;
            3'd5: na_dc = 5'd18;
            default: na_dc = 5'd10;
        endcase
    end
    // LevelScale4x4(qp % 6, 0, 0) of the DC kinds: weightScale(0, 0) x normAdjust (<= 255 x 18)
    wire [12:0] ls_dc_u = t_w00 * na_dc;
    wire signed [13:0] ls_dc = {1'b0, ls_dc_u};

    // stage 3: 8.5.12.1 -- d = (c * LevelScale) << (qp/6 - 4) for qp >= 24, else
    // (c * LevelScale + 2^(3 - qp/6)) >> (4 - qp/6) (eq. 8-337)
    // (P5b: the product is registered -- stage 3 -- before the shift and the write into A;
    // the multiply, the rounding add and A's 16:1 write decode in one cycle were 10.9 ns)
    logic signed [28:0] dq_prod, p3_prod;
    logic               p3_valid;
    logic signed [15:0] p3_coef;
    logic [3:0]         p3_r;
    logic signed [32:0] dq_ext, dq_sh;
    always_comb begin
        dq_prod = p2_cw * $signed({1'b0, p2_na});
        dq_ext  = {{4{p3_prod[28]}}, p3_prod};
        case (b_q6)
            4'd0: dq_sh = (dq_ext + 33'sd8) >>> 4;
            4'd1: dq_sh = (dq_ext + 33'sd4) >>> 3;
            4'd2: dq_sh = (dq_ext + 33'sd2) >>> 2;
            4'd3: dq_sh = (dq_ext + 33'sd1) >>> 1;
            4'd4: dq_sh = dq_ext;
            4'd5: dq_sh = dq_ext <<< 1;
            4'd6: dq_sh = dq_ext <<< 2;
            4'd7: dq_sh = dq_ext <<< 3;
            default: dq_sh = dq_ext <<< 4;
        endcase
    end
    wire signed [19:0] a_din = is_dc ? {{4{p3_coef[15]}}, p3_coef} : dq_sh[19:0];

    // ---- the 4-point butterfly (8.5.12.2 eq. 8-339..8-346 / the Hadamard rows of 8.5.10)
    // mode 0: e0 = x0 + x2, e1 = x0 - x2, e2 = (x1 >> 1) - x3, e3 = x1 + (x3 >> 1)
    //         y = [e0 + e3, e1 + e2, e1 - e2, e0 - e3]
    // mode 1: e0 = x0 + x1, e1 = x0 - x1, e2 = x2 - x3, e3 = x2 + x3
    //         y = [e0 + e3, e0 - e3, e1 - e2, e1 + e2]  (H = [1 1 1 1; 1 1 -1 -1; 1 -1 -1 1; 1 -1 1 -1])
    // the four output sums are the same set; only their order differs, resolved at the
    // write (kind 4's 2x2 transform, eq. 8-328, is mode 1 with the order [s03 a12 m03 m12])
    logic [1:0] ri, ci;
    logic signed [19:0] bx0, bx1, bx2, bx3;
    logic signed [19:0] At [0:15];       // the transform's buffer
    always_comb for (int i = 0; i < 16; i++) At[i] = tsel ? A1[i] : A0[i];
    always_comb begin
        case (tst)
            T_COL: begin
                bx0 = At[{2'd0, ci}]; bx1 = At[{2'd1, ci}]; bx2 = At[{2'd2, ci}]; bx3 = At[{2'd3, ci}];
            end
            T_CDC: begin
                bx0 = At[0]; bx1 = At[1]; bx2 = At[2]; bx3 = At[3];
            end
            default: begin
                bx0 = At[{ri, 2'd0}]; bx1 = At[{ri, 2'd1}]; bx2 = At[{ri, 2'd2}]; bx3 = At[{ri, 2'd3}];
            end
        endcase
    end
    wire had = (t_kind == K_LDC) || (t_kind == K_CDC);   // the Hadamard butterfly for kinds 3 and 4
    // sign-extended to the butterfly width first, then the halves (arithmetic shifts)
    wire signed [21:0] x0  = {{2{bx0[19]}}, bx0};
    wire signed [21:0] x1  = {{2{bx1[19]}}, bx1};
    wire signed [21:0] x2  = {{2{bx2[19]}}, bx2};
    wire signed [21:0] x3  = {{2{bx3[19]}}, bx3};
    wire signed [21:0] x1h = x1 >>> 1;
    wire signed [21:0] x3h = x3 >>> 1;
    logic signed [21:0] e0, e1, e2, e3, s03, m03, a12, m12;
    always_comb begin
        if (had) begin
            e0 = x0 + x1;
            e1 = x0 - x1;
            e2 = x2 - x3;
            e3 = x2 + x3;
        end else begin
            e0 = x0 + x2;
            e1 = x0 - x2;
            e2 = x1h - x3;
            e3 = x1 + x3h;
        end
    end
    // two stages (the selection, the two adder levels and the write in one cycle missed
    // clk_dec): the issue registers e0..e3 (bq*) and where the result goes, the second
    // stage forms the outputs and writes them -- rows back to back into A, one bubble
    // (S_ROWW) before the columns read A, the columns / the 2x2 into O
    logic               bf_v, bf_had;
    logic [1:0]         bf_dst, bf_idx;      // dst 0 row of A, 1 column of O, 2 the 2x2 into O
    logic signed [21:0] bq0, bq1, bq2, bq3;
    always_comb begin
        s03 = bq0 + bq3;
        m03 = bq0 - bq3;
        a12 = bq1 + bq2;
        m12 = bq1 - bq2;
    end
    // mode 0: y = [s03 a12 m12 m03]; mode 1: y = [s03 m03 m12 a12]
    wire signed [21:0] y0 = s03;
    wire signed [21:0] y1 = bf_had ? m03 : a12;
    wire signed [21:0] y2 = m12;
    wire signed [21:0] y3 = bf_had ? a12 : m03;

    // ---- the output stream --------------------------------------------------------
    logic        o_active;               // the output buffer holds a block not yet fetched
    logic [4:0]  o_cnt, o_n;
    logic [2:0]  o_kind;
    logic [3:0]  o_q6;
    logic signed [13:0] o_ls;
    // the pipeline: fetch (p_*) then compute into res; it moves as a whole when the
    // output is free or being taken, so a stalled consumer holds every stage
    logic               p_valid, p_last;
    logic signed [19:0] p_val;
    logic [2:0]         p_kind;
    logic [3:0]         p_q6;
    logic signed [13:0] p_ls;
    wire adv = !res_valid || res_ready;

    // stage m (P5b): the DC kinds' product registered before the rounding shift (the multiply,
    // the shift and the kind select in one cycle were 10.0 ns); the whole pipeline -- fetch,
    // m, res -- still moves together on adv
    logic               m_valid, m_last;
    logic signed [19:0] m_val;
    logic [2:0]         m_kind;
    logic [3:0]         m_q6;
    logic signed [33:0] m_prod;
    logic signed [35:0] o_ext, o_val;
    always_comb begin
        o_ext  = {{2{m_prod[33]}}, m_prod};
        case (m_kind)
            K_LDC:   // 8.5.10 eq. 8-326/8-327: qp >= 36 shifts left by qp/6 - 6, below it
                     // rounds by 2^(5 - qp/6) and shifts right by 6 - qp/6
                case (m_q6)
                    4'd0: o_val = (o_ext + 32) >>> 6;
                    4'd1: o_val = (o_ext + 16) >>> 5;
                    4'd2: o_val = (o_ext + 8) >>> 4;
                    4'd3: o_val = (o_ext + 4) >>> 3;
                    4'd4: o_val = (o_ext + 2) >>> 2;
                    4'd5: o_val = (o_ext + 1) >>> 1;
                    4'd6: o_val = o_ext;
                    4'd7: o_val = o_ext <<< 1;
                    default: o_val = o_ext <<< 2;
                endcase
            K_CDC:   // 8.5.11.2 eq. 8-330: ((f * LevelScale) << (qp/6)) >> 5
                case (m_q6)
                    4'd0: o_val = o_ext >>> 5;
                    4'd1: o_val = o_ext >>> 4;
                    4'd2: o_val = o_ext >>> 3;
                    4'd3: o_val = o_ext >>> 2;
                    4'd4: o_val = o_ext >>> 1;
                    4'd5: o_val = o_ext;
                    4'd6: o_val = o_ext <<< 1;
                    4'd7: o_val = o_ext <<< 2;
                    default: o_val = o_ext <<< 3;
                endcase
            default: // 8.5.12.2 eq. 8-347: r_ij = (h_ij + 32) >> 6
                o_val = ({{16{m_val[19]}}, m_val} + 32) >>> 6;
        endcase
    end

    // ---- control -----------------------------------------------------------------
    wire   in_acc     = coef_valid && coef_ready;
    wire   o_free     = !o_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; tst <= T_IDLE; wsel <= 1'b0; tsel <= 1'b0;
            t_kind <= 3'd0; t_q6 <= 4'd0; t_m <= 3'd0; t_w00 <= 8'd16;
            coef_ready <= 1'b0; busy <= 1'b0;
            b_kind <= 3'd0; b_q6 <= 4'd0; b_m <= 3'd0; b_field <= 1'b0; b_ncoef <= 5'd16;
            b_flat <= 1'b1; b_list <= 3'd0; b_w00 <= 8'd16; w00_pend <= 1'b0;
            p1_kb <= 2'd0; p2_valid <= 1'b0; p2_cw <= '0; p2_coef <= '0; p2_r <= '0; p2_cls <= '0; p2_na <= '0;
            p3_valid <= 1'b0; p3_prod <= '0; p3_coef <= '0; p3_r <= '0;
            cnt <= 5'd0; ri <= 2'd0; ci <= 2'd0;
            p1_valid <= 1'b0; p1_coef <= 16'sd0; p1_r <= 4'd0; p1_cls <= 2'd0;
            o_active <= 1'b0; o_cnt <= 5'd0; o_n <= 5'd16; o_kind <= 3'd0; o_q6 <= 4'd0; o_ls <= 14'sd0;
            p_valid <= 1'b0; p_last <= 1'b0; p_val <= 20'sd0; p_kind <= 3'd0; p_q6 <= 4'd0; p_ls <= 14'sd0;
            m_valid <= 1'b0; m_last <= 1'b0; m_val <= 20'sd0; m_kind <= 3'd0; m_q6 <= 4'd0; m_prod <= '0;
            res_valid <= 1'b0; res <= 16'sd0; res_last <= 1'b0;
            bf_v <= 1'b0; bf_had <= 1'b0; bf_dst <= 2'd0; bf_idx <= 2'd0; bq0 <= '0; bq1 <= '0; bq2 <= '0; bq3 <= '0;
        end else begin
            // ---- intake stage 1 (the weight read) -> 2 (c * weight) -> 3 (the buffer write)
            p1_valid <= in_acc;
            if (in_acc) begin
                p1_coef <= coef;
                p1_r    <= in_r;
                p1_cls  <= in_cls;
                p1_kb   <= in_kz[1:0];
            end
            p2_valid <= p1_valid;
            if (p1_valid) begin
                p2_cw   <= p1_coef * $signed({1'b0, w1});
                p2_coef <= p1_coef;
                p2_r    <= p1_r;
                p2_cls  <= p1_cls;
                p2_na   <= na_in;
            end
            p3_valid <= p2_valid;
            if (p2_valid) begin p3_prod <= dq_prod; p3_coef <= p2_coef; p3_r <= p2_r; end
            if (p3_valid) begin if (wsel) A1[p3_r] <= a_din; else A0[p3_r] <= a_din; end
            // weightScale(0, 0): its read was addressed in the start cycle
            w00_pend <= 1'b0;
            if (w00_pend) b_w00 <= b_flat ? 8'd16 : w_q[7:0];

            // ---- the butterfly's second stage
            bf_v <= 1'b0;
            if (bf_v) begin
                case (bf_dst)
                    2'd0: begin
                        if (tsel) begin
                            A1[{bf_idx, 2'd0}] <= y0[19:0]; A1[{bf_idx, 2'd1}] <= y1[19:0];
                            A1[{bf_idx, 2'd2}] <= y2[19:0]; A1[{bf_idx, 2'd3}] <= y3[19:0];
                        end else begin
                            A0[{bf_idx, 2'd0}] <= y0[19:0]; A0[{bf_idx, 2'd1}] <= y1[19:0];
                            A0[{bf_idx, 2'd2}] <= y2[19:0]; A0[{bf_idx, 2'd3}] <= y3[19:0];
                        end
                    end
                    2'd1: begin
                        O[{2'd0, bf_idx}] <= y0[19:0]; O[{2'd1, bf_idx}] <= y1[19:0];
                        O[{2'd2, bf_idx}] <= y2[19:0]; O[{2'd3, bf_idx}] <= y3[19:0];
                        if (bf_idx == 2'd3) begin o_active <= 1'b1; o_cnt <= 5'd0; end
                    end
                    default: begin
                        O[0] <= s03[19:0]; O[1] <= a12[19:0]; O[2] <= m03[19:0]; O[3] <= m12[19:0];
                        o_active <= 1'b1; o_cnt <= 5'd0;
                    end
                endcase
            end

            // ---- the intake
            case (state)
                S_IDLE: if (start) begin
                    b_kind  <= kind;
                    b_flat  <= wflat;
                    b_list  <= wlist;
                    w00_pend <= 1'b1;
                    b_q6    <= q6_w;
                    b_m     <= m_w[2:0];
                    b_field <= field_scan;
                    b_ncoef <= (kind == K_CDC) ? 5'd4 : ((kind == K_LAC || kind == K_CAC) ? 5'd15 : 5'd16);
                    cnt     <= 5'd0;
                    // an AC block's d00 is the DC value the DC path produced (8.5.10 / 8.5.11)
                    if (kind == K_LAC || kind == K_CAC) begin
                        if (wsel) A1[0] <= {{4{dc_in[15]}}, dc_in}; else A0[0] <= {{4{dc_in[15]}}, dc_in};
                    end
                    coef_ready <= 1'b1;
                    busy    <= 1'b1;
                    state   <= S_IN;
                end
                S_IN: if (in_acc) begin
                    cnt <= cnt + 5'd1;
                    if (cnt == b_ncoef - 5'd1) begin
                        coef_ready <= 1'b0;
                        state <= S_DRAIN;
                    end
                end
                S_DRAIN: state <= S_DRAIN2;          // the last coefficient's weight stage
                S_DRAIN2: state <= S_DRAIN3;         // ... its product
                S_DRAIN3: state <= S_HOLD;           // the last coefficient lands in the buffer this cycle
                S_HOLD: if (tst == T_IDLE) begin     // the block to the transform, the buffers swap
                    if (b_kind == K_CDC) tst <= T_CDC; else tst <= T_ROW;
                    tsel <= wsel; wsel <= !wsel;
                    t_kind <= b_kind; t_q6 <= b_q6; t_m <= b_m; t_w00 <= b_w00;
                    ri <= 2'd0; ci <= 2'd0;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end
                default: begin
                    busy <= 1'b0; coef_ready <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
            // ---- the transform
            case (tst)
                T_ROW: begin                         // row ri issued (written in place next cycle)
                    bf_v <= 1'b1; bf_dst <= 2'd0; bf_idx <= ri; bf_had <= had;
                    bq0 <= e0; bq1 <= e1; bq2 <= e2; bq3 <= e3;
                    ri <= ri + 2'd1;
                    if (ri == 2'd3) tst <= T_ROWW;
                end
                T_ROWW: tst <= T_COL;                // row 3 lands
                T_COL: if (ci != 2'd0 || o_free) begin   // column ci issued (into O next cycle)
                    bf_v <= 1'b1; bf_dst <= 2'd1; bf_idx <= ci; bf_had <= had;
                    bq0 <= e0; bq1 <= e1; bq2 <= e2; bq3 <= e3;
                    ci <= ci + 2'd1;
                    if (ci == 2'd0) begin
                        o_kind <= t_kind; o_q6 <= t_q6; o_ls <= ls_dc; o_n <= 5'd16;
                    end
                    if (ci == 2'd3) tst <= T_IDLE;
                end
                T_CDC: if (o_free) begin             // eq. 8-328: f = [c0+c1+c2+c3, c0-c1+c2-c3, c0+c1-c2-c3, c0-c1-c2+c3]
                    bf_v <= 1'b1; bf_dst <= 2'd2; bf_idx <= 2'd0; bf_had <= had;
                    bq0 <= e0; bq1 <= e1; bq2 <= e2; bq3 <= e3;
                    o_kind <= t_kind; o_q6 <= t_q6; o_ls <= ls_dc; o_n <= 5'd4;
                    tst <= T_IDLE;
                end
                default: ;
            endcase

            // ---- the output pipeline
            if (adv) begin
                res_valid <= m_valid;
                res_last  <= m_last;
                res       <= o_val[15:0];
                m_valid   <= p_valid; m_last <= p_last; m_val <= p_val; m_kind <= p_kind; m_q6 <= p_q6;
                m_prod    <= p_val * p_ls;
                p_valid   <= o_active;
                if (o_active) begin
                    p_val  <= O[o_cnt[3:0]];
                    p_last <= (o_cnt == o_n - 5'd1);
                    p_kind <= o_kind; p_q6 <= o_q6; p_ls <= o_ls;
                    o_cnt  <= o_cnt + 5'd1;
                    if (o_cnt == o_n - 5'd1) o_active <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
