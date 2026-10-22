// h264/dec/dequant_itrans8.sv -- the 8x8 residual block of High profile: inverse 8x8 scan
// (8.5.7, Table 8-14), scaling (8.5.13.1, LevelScale8x8 = weightScale8x8 x normAdjust8x8,
// 8-316 / 8-317) and the 8x8 inverse transform (8.5.13.2). docs/high_profile.md S5.
//
// Bit-exact against tools/h264_recon_ref.py (dequant8x8 + itrans8x8 -- proven pixel-exact
// vs ffmpeg and the H.264.1 FRExt YUVs), scored by bench/h264/run_dequant_itrans.sh over
// tools/itrans_golden.py's L8 fixtures (every qp, both scans, flat and weighted lists,
// one coefficient at each of the 64 positions, the 8x8 blocks of an x264 High clip).
//
// One block per `start` (a pulse, taken while !busy): 64 levels in scan order in, 64
// residual samples r_ij in raster order (8 i + j) out. `qp` is QP'Y (8x8 blocks are luma
// in 4:2:0), `field_scan` the field scan of Table 8-14, `wflat` / `wlist` the scaling list
// (Flat_16, or list 6 Intra Y / 7 Inter Y of the active matrix: `w_ra` = {wlist,
// k[5:2]}, k the zig-zag index of the level's raster position -- hp_zzinv8, 8.5.7 --
// its word `w_q` the cycle after). All sampled with `start`.
//
// RAM-backed (a register-array 8x8 version would cost ~2,500 ALMs), and since Phase 5c part 2
// step 2 (docs/mb_pipeline.md S4j) a PIPELINE OVER BLOCKS of four stages, each with its own
// ping-pong buffer, so four blocks may be in flight at once:
//   intake  -- four stages a coefficient: the scan / weight read, c * weight,
//              * normAdjust8x8, then the shift of 8.5.13.1 (qp >= 36: << (qp/6 - 6); else
//              + 2^(5 - qp/6) and >> (6 - qp/6)) into work RAM A (half ia) at the raster
//              address; the half is handed to the row pass after the last level's stages
//   rows    -- A read in raster order, eight words collected, one 8-point butterfly
//              (8-358 .. 8-381, two register stages), the eight results written to RAM B
//              TRANSPOSED (B[8 j + i]) while the next row is read (dq8_pass, COL 0)
//   columns -- B read in order (column j of the row results is B[8 j .. 8 j + 7]), its own
//              butterfly (8-382 .. 8-405), r = (m + 32) >> 6 (8-406) written to the output
//              RAM O at its raster address (dq8_pass, COL 1)
//   output  -- O read in raster order, one sample a cycle (res_ready throttles)
// Each stage takes the next block once its input half is full and its output half free.
// `busy` is low when the intake may take a block: idle, its next half of A free, and fewer
// than four blocks in flight (the parent's descriptor FIFO holds four: recon_mb's collector).
// ~285 cycles a block serially (the unit before S4j); ~80 a block in a stream of blocks (the
// slowest stage, a pass: 64 reads and its pipeline's tail).
// The `start` contract is load-bearing: the intake accepts a start whenever it is idle, and it
// can be idle with `busy` high (A's next half still full, or four blocks in flight) -- a start
// then would write a half the row pass reads. The caller must start only while !busy
// (recon_mb's R_NEXT; arm V2 of run_recon_top.sh).
//
// Widths: 8.5.13 bounds d, e, f, g, h, k to 16 bits signed and m to 2^15 - 33 for a
// conforming stream; the RAMs hold 20 bits, the butterfly computes in 22, products are
// full width (16 x 8 -> 24, x 6 -> 30); a non-conforming stream wraps, never clamps. Every
// right shift is arithmetic. Quartus 17 (CLAUDE.md): ROMs are `case` modules
// (h264/dec/high_tables.sv), no `function automatic`, no N'() casts; the three RAMs are
// single-read-port arrays with a registered read (inferred block / MLAB RAM).

`default_nettype none

module dequant_itrans8 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire  [5:0]  qp,
    input  wire         field_scan,
    input  wire         wflat,
    input  wire         wlist,             // 0: list 6 (Intra Y), 1: list 7 (Inter Y)
    output logic [4:0]  w_ra,              // weight word {wlist, k[5:2]} of the 8x8 lists (32 words)
    input  wire  [31:0] w_q,

    input  wire         coef_valid,
    input  wire signed [15:0] coef,
    output logic        coef_ready,

    output logic        res_valid,
    output logic signed [15:0] res,
    output logic        res_last,
    input  wire         res_ready,

    output logic        busy
);

    // the intake's state (the profile names it: S_IN / S_DRAIN while a block comes in;
    // S_ROW / S_COL / S_OUT are unused since S4j -- the passes and the output are stages)
    typedef enum logic [2:0] {S_IDLE, S_IN, S_DRAIN, S_ROW, S_COL, S_OUT} state_t;
    state_t state;

    // ---- the block's parameters (the intake's alone) -----------------------------------
    logic [3:0]  b_q6;
    logic [2:0]  b_m;
    logic        b_field, b_flat, b_list;
    logic [6:0]  cnt;                   // coefficients accepted / the drain counter

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

    // ---- the three RAMs, two halves each (128 x 20, one read port each, a registered read:
    // the word lands the cycle after its address) -------------------------------------------
    logic signed [19:0] ram_a [0:127];
    logic signed [19:0] ram_b [0:127];
    logic signed [19:0] ram_o [0:127];
    logic        a_we, b_we, o_we;
    logic [6:0]  a_wa, b_wa, o_wa;
    logic signed [19:0] a_wd, b_wd, o_wd, a_q, b_q, o_q;
    logic        ia, ra, rb, cb, co, oo;    // the halves: intake writes A[ia], rows read A[ra] and
                                            // write B[rb], columns read B[cb] and write O[co],
                                            // the output reads O[oo]
    logic [1:0]  a_full, b_full, o_full;    // a half holds a block for the next stage
    logic [5:0]  r_ra, c_ra;                // the passes' read addresses
    logic [6:0]  o_pos;                     // the output stream's next O address
    always_ff @(posedge clk) begin
        if (a_we) ram_a[a_wa] <= a_wd;
        a_q <= ram_a[{ra, r_ra}];
    end
    always_ff @(posedge clk) begin
        if (b_we) ram_b[b_wa] <= b_wd;
        b_q <= ram_b[{cb, c_ra}];
    end
    always_ff @(posedge clk) begin
        if (o_we) ram_o[o_wa] <= o_wd;
        o_q <= ram_o[{oo, o_pos[5:0]}];
    end

    // ---- intake ----------------------------------------------------------------------------
    wire        in_acc = coef_valid && coef_ready;
    logic [5:0] in_r, in_kz;
    hp_scan8  u_scan (.field(b_field), .k(cnt[5:0]), .r(in_r));
    hp_zzinv8 u_zz   (.r(in_r), .k(in_kz));
    always_comb w_ra = {b_list, in_kz[5:2]};
    // stage 1: the level, its raster position, its weight byte; normAdjust8x8 looked up
    logic               p1_v;
    logic signed [15:0] p1_c;
    logic [5:0]         p1_r;
    logic [1:0]         p1_kb;
    logic [5:0]         na_w;
    hp_norm8 u_na (.m(b_m), .r(p1_r), .v(na_w));
    logic [7:0] w1;
    always_comb begin
        case (p1_kb)
            2'd0: w1 = w_q[7:0];   2'd1: w1 = w_q[15:8];
            2'd2: w1 = w_q[23:16]; default: w1 = w_q[31:24];
        endcase
        if (b_flat) w1 = 8'd16;
    end
    // stage 2: c * weight
    logic               p2_v;
    logic signed [23:0] p2_cw;
    logic [5:0]         p2_r, p2_na;
    // stage 3: * normAdjust8x8, registered; stage 4: the shift (8-356 / 8-357) into A. (The
    // product and the shift in one cycle after hp_norm8 -- which Quartus puts in an M10K,
    // its output late in the cycle -- missed clk_dec by ~1 ns: P5 fit 2026-09-28)
    logic signed [29:0] p3_prod, p3_q;
    logic               p3_v;
    logic [5:0]         p3_r;
    logic               p3_h;               // the half the level goes to
    logic               p1_h, p2_h;
    logic signed [33:0] p3_ext, p3_sh;
    always_comb begin
        p3_prod = p2_cw * $signed({1'b0, p2_na});
        p3_ext  = {{4{p3_q[29]}}, p3_q};
        case (b_q6)
            4'd0: p3_sh = (p3_ext + 34'sd32) >>> 6;
            4'd1: p3_sh = (p3_ext + 34'sd16) >>> 5;
            4'd2: p3_sh = (p3_ext + 34'sd8)  >>> 4;
            4'd3: p3_sh = (p3_ext + 34'sd4)  >>> 3;
            4'd4: p3_sh = (p3_ext + 34'sd2)  >>> 2;
            4'd5: p3_sh = (p3_ext + 34'sd1)  >>> 1;
            4'd6: p3_sh = p3_ext;
            4'd7: p3_sh = p3_ext <<< 1;
            default: p3_sh = p3_ext <<< 2;
        endcase
    end

    // ---- the two passes ----------------------------------------------------------------------
    logic        r_go, r_busy, r_done, r_we, c_go, c_busy, c_done, c_we;
    logic [5:0]  r_wa, c_wa;
    logic signed [19:0] r_wd, c_wd;
    dq8_pass #(.COL(1'b0)) u_rows (.clk(clk), .rst_n(rst_n), .go(r_go), .busy(r_busy), .done(r_done),
        .rd_addr(r_ra), .rd_q(a_q), .we(r_we), .wa(r_wa), .wd(r_wd));
    dq8_pass #(.COL(1'b1)) u_cols (.clk(clk), .rst_n(rst_n), .go(c_go), .busy(c_busy), .done(c_done),
        .rd_addr(c_ra), .rd_q(b_q), .we(c_we), .wa(c_wa), .wd(c_wd));
    // a pass starts when its input half holds a block and its output half is free (a pulse:
    // the pass is busy from the cycle after; not in its `done` cycle, whose hand-off moves
    // the halves at that cycle's edge)
    always_comb begin
        r_go = !r_busy && !r_done && a_full[ra] && !b_full[rb];
        c_go = !c_busy && !c_done && b_full[cb] && !o_full[co];
        b_we = r_we; b_wa = {rb, r_wa}; b_wd = r_wd;
        o_we = c_we; o_wa = {co, c_wa}; o_wd = c_wd;
    end

    // ---- the blocks in flight (started, last sample not yet taken) ----------------------------
    logic [2:0]  inflight;
    always_comb busy = (state != S_IDLE) || a_full[ia] || (inflight >= 3'd4);

    // ---- the output stream: O[oo] at o_pos, the head in res / res_valid, one skid entry -------
    logic        o_rv, o_lv;            // an O word lands this cycle, and it is the last
    logic        sk_v, sk_l;
    logic signed [15:0] sk_d;
    logic        o_run;                 // the output streams O[oo]
    wire         o_pop = res_valid && res_ready;
    wire [1:0]   o_after = {1'b0, res_valid} + {1'b0, sk_v} + {1'b0, o_rv} - {1'b0, o_pop};
    wire signed [15:0] o_land = o_q[15:0];
    wire         o_end = o_pop && res_last;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; coef_ready <= 1'b0;
            b_q6 <= '0; b_m <= '0; b_field <= 1'b0; b_flat <= 1'b1; b_list <= 1'b0; cnt <= '0;
            p1_v <= 1'b0; p1_c <= '0; p1_r <= '0; p1_kb <= '0; p1_h <= 1'b0;
            p2_v <= 1'b0; p2_cw <= '0; p2_r <= '0; p2_na <= '0; p2_h <= 1'b0;
            p3_v <= 1'b0; p3_q <= '0; p3_r <= '0; p3_h <= 1'b0;
            a_we <= 1'b0; a_wa <= '0; a_wd <= '0;
            ia <= 1'b0; ra <= 1'b0; rb <= 1'b0; cb <= 1'b0; co <= 1'b0; oo <= 1'b0;
            a_full <= '0; b_full <= '0; o_full <= '0; inflight <= '0;
            o_pos <= '0; o_run <= 1'b0; o_rv <= 1'b0; o_lv <= 1'b0; sk_v <= 1'b0; sk_l <= 1'b0; sk_d <= '0;
            res_valid <= 1'b0; res <= '0; res_last <= 1'b0;
        end else begin
            a_we <= 1'b0;
            // ---- intake pipeline
            p1_v <= in_acc;
            if (in_acc) begin p1_c <= coef; p1_r <= in_r; p1_kb <= in_kz[1:0]; p1_h <= ia; end
            p2_v <= p1_v;
            if (p1_v) begin p2_cw <= p1_c * $signed({1'b0, w1}); p2_r <= p1_r; p2_na <= na_w; p2_h <= p1_h; end
            p3_v <= p2_v;
            if (p2_v) begin p3_q <= p3_prod; p3_r <= p2_r; p3_h <= p2_h; end
            if (p3_v) begin a_we <= 1'b1; a_wa <= {p3_h, p3_r}; a_wd <= p3_sh[19:0]; end

            // ---- the stages' hand-offs (a half is set full by its writer, freed by its reader;
            // the two never name the same half in one cycle: a writer only takes a free half)
            if (r_done) begin a_full[ra] <= 1'b0; ra <= !ra; b_full[rb] <= 1'b1; rb <= !rb; end
            if (c_done) begin b_full[cb] <= 1'b0; cb <= !cb; o_full[co] <= 1'b1; co <= !co; end

            // ---- the output stream
            o_rv <= 1'b0;
            if (!o_run && o_full[oo] && !o_end) begin o_run <= 1'b1; o_pos <= '0; end
            if (o_run) begin
                if (o_pos < 7'd64 && o_after < 2'd2) begin
                    o_rv <= 1'b1; o_lv <= (o_pos == 7'd63); o_pos <= o_pos + 7'd1;
                end
            end
            case ({o_rv, o_pop})
                2'b10: begin
                    if (!res_valid) begin res_valid <= 1'b1; res <= o_land; res_last <= o_lv; end
                    else begin sk_v <= 1'b1; sk_d <= o_land; sk_l <= o_lv; end
                end
                2'b01: begin
                    if (sk_v) begin res <= sk_d; res_last <= sk_l; sk_v <= 1'b0; end
                    else res_valid <= 1'b0;
                end
                2'b11: begin
                    if (sk_v) begin res <= sk_d; res_last <= sk_l; sk_d <= o_land; sk_l <= o_lv; end
                    else begin res <= o_land; res_last <= o_lv; end
                end
                default: ;
            endcase
            if (o_end) begin
                // the block's last sample taken: its half of O is free, the next half streams
                res_valid <= 1'b0; sk_v <= 1'b0; o_run <= 1'b0; o_full[oo] <= 1'b0; oo <= !oo;
            end

            inflight <= inflight + {2'd0, state == S_IDLE && start} - {2'd0, o_end};

            case (state)
                S_IDLE: if (start) begin
                    b_q6 <= q6_w; b_m <= m_w[2:0]; b_field <= field_scan; b_flat <= wflat; b_list <= wlist;
                    cnt <= '0; coef_ready <= 1'b1;
                    state <= S_IN;
                end
                S_IN: if (in_acc) begin
                    cnt <= cnt + 7'd1;
                    if (cnt == 7'd63) begin coef_ready <= 1'b0; cnt <= 7'd64; state <= S_DRAIN; end
                end
                S_DRAIN: begin
                    // the last level's four stages: then A[ia] is the row pass's
                    cnt <= cnt + 7'd1;
                    if (cnt == 7'd68) begin a_full[ia] <= 1'b1; ia <= !ia; state <= S_IDLE; end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// One pass of the 8x8 inverse transform (8.5.13.2) over a 64-word block: read in order (word
// k lands the cycle after rd_addr holds k), eight words collected, the 8-point butterfly
// (two register stages), the eight results shifted out one a cycle and written at {k, idx}:
// the row pass (COL 0) writes y transposed into B (B[8 j + i]), the column pass (COL 1)
// r = (m + 32) >> 6 (8-406) into O at the raster address (O[8 i + j]). `go` (a pulse, while
// !busy) starts it; `done` pulses once the last result is written.
module dq8_pass #(parameter bit COL = 1'b0) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         go,
    output logic        busy,
    output logic        done,
    output logic [5:0]  rd_addr,
    input  wire  signed [19:0] rd_q,
    output logic        we,
    output logic [5:0]  wa,
    output logic signed [19:0] wd
);
    logic [6:0]  cnt;
    logic signed [19:0] col [0:7];      // the eight words of the row / column being collected
    logic signed [21:0] x [0:7];
    always_comb for (int k = 0; k < 8; k++) x[k] = {{2{col[k][19]}}, col[k]};
    logic signed [21:0] e0, e1, e2, e3, e4, e5, e6, e7;
    always_comb begin
        e0 = x[0] + x[4];
        e1 = -x[3] + x[5] - x[7] - (x[7] >>> 1);
        e2 = x[0] - x[4];
        e3 = x[1] + x[7] - x[3] - (x[3] >>> 1);
        e4 = (x[2] >>> 1) - x[6];
        e5 = -x[1] + x[7] + x[5] + (x[5] >>> 1);
        e6 = x[2] + (x[6] >>> 1);
        e7 = x[3] + x[5] + x[1] + (x[1] >>> 1);
    end
    logic signed [21:0] f [0:7];        // stage 1 (registered)
    logic               bf1_v, bf2_v;
    logic [2:0]         bf1_idx, bf2_idx;
    // the transformed eight, shifted out one a cycle: y[0] is the next to write
    logic signed [21:0] y [0:7];
    logic [3:0]         y_n;            // results left to write
    logic [2:0]         y_idx;          // the row (row pass) / column (column pass) they belong to
    logic [2:0]         y_k;            // the position within the eight of y[0]
    logic        rd_v;
    logic [2:0]  rd_j, rd_i;
    wire signed [21:0] m_r = y[0] + 22'sd32;          // 8-406: r = (m + 32) >> 6
    always_comb rd_addr = cnt[5:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; cnt <= '0; we <= 1'b0; wa <= '0; wd <= '0;
            for (int k = 0; k < 8; k++) begin col[k] <= '0; f[k] <= '0; y[k] <= '0; end
            bf1_v <= 1'b0; bf2_v <= 1'b0; bf1_idx <= '0; bf2_idx <= '0; y_n <= '0; y_idx <= '0; y_k <= '0;
            rd_v <= 1'b0; rd_j <= '0; rd_i <= '0;
        end else begin
            we <= 1'b0; done <= 1'b0;
            rd_v <= 1'b0;
            if (rd_v) col[rd_j] <= rd_q;
            bf1_v <= rd_v && (rd_j == 3'd7);
            bf1_idx <= rd_i;
            if (bf1_v) begin
                f[0] <= e0 + e6;          f[1] <= e1 + (e7 >>> 2);
                f[2] <= e2 + e4;          f[3] <= e3 + (e5 >>> 2);
                f[4] <= e2 - e4;          f[5] <= (e3 >>> 2) - e5;
                f[6] <= e0 - e6;          f[7] <= e7 - (e1 >>> 2);
            end
            bf2_v <= bf1_v; bf2_idx <= bf1_idx;
            // write y[0] (the previous eight's last may go in the cycle the next eight load):
            // the row pass transposed (B[8 k + i]), the column pass at the raster address
            // (O[8 k + j]): {y_k, y_idx} both
            if (y_n != 4'd0) begin
                we <= 1'b1; wa <= {y_k, y_idx};
                wd <= COL ? {{4{m_r[21]}}, m_r[21:6]} : y[0][19:0];
                for (int k = 0; k < 7; k++) y[k] <= y[k + 1];
                y_n <= y_n - 4'd1; y_k <= y_k + 3'd1;
            end
            if (bf2_v) begin
                y[0] <= f[0] + f[7]; y[1] <= f[2] + f[5]; y[2] <= f[4] + f[3]; y[3] <= f[6] + f[1];
                y[4] <= f[6] - f[1]; y[5] <= f[4] - f[3]; y[6] <= f[2] - f[5]; y[7] <= f[0] - f[7];
                y_n <= 4'd8; y_idx <= bf2_idx; y_k <= 3'd0;
            end
            if (go) begin busy <= 1'b1; cnt <= '0; end
            else if (busy) begin
                // read word cnt (0..63); the pass ends when its last eight are written
                if (cnt < 7'd64) begin
                    rd_v <= 1'b1; rd_j <= cnt[2:0]; rd_i <= cnt[5:3];
                    cnt <= cnt + 7'd1;
                end else if (!rd_v && !bf1_v && !bf2_v && y_n == 4'd0 && !we) begin
                    busy <= 1'b0; done <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
