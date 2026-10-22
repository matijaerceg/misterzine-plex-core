// h264/dec/intra_pred.sv -- intra sample prediction (ITU-T H.264 8.3)
//
//   8.3.1.2   Intra_4x4: the nine modes (8.3.1.2.1 Vertical .. 8.3.1.2.9 Horizontal_Up)
//   8.3.2.2   Intra_8x8 (High profile, H264 Phase 5): the reference sample filter
//             (8.3.2.2.1) then the nine modes (8.3.2.2.2 .. 8.3.2.2.10)
//   8.3.3     Intra_16x16: Vertical, Horizontal, DC, Plane (8.3.3.1-4)
//   8.3.4     Intra chroma for 4:2:0: DC (8.3.4.1-3 per 4x4 chroma block), Horizontal,
//             Vertical, Plane (8.3.4.4)
//
// Bit-exact against tools/h264_recon_ref.py (intra4x4_pred, intra16x16_pred,
// intra_chroma_pred -- the model proven pixel-exact vs ffmpeg), scored by
// bench/h264/run_intra_pred.sh over random neighbours in every legal availability
// combination and the recorded calls of a real x264 intra clip. docs/h264_recon.md S2.4.
//
// Neighbour store (33 bytes of registers, written by the caller BEFORE start, read live
// while the block streams -- never write it while busy):
//   nb[0..15]  p[x, -1]  x = 0..15   (Intra_4x4 uses 0..7; the caller has already put
//                                     p[3,-1] into p[4..7,-1] when the above-right samples
//                                     are not available, 8.3.1.2; Intra_8x8 uses 0..15, the
//                                     caller having put p[7,-1] into p[8..15,-1], 8.3.2.2)
//   nb[16..31] p[-1, y]  y = 0..15   (Intra_4x4 uses 0..3, chroma and Intra_8x8 0..7)
//   nb[32]     p[-1, -1]
// avail_top / avail_left say whether the p[x,-1] / p[-1,y] runs exist; only the DC modes
// read them (8.3.1.2.3, 8.3.3.3, 8.3.4.1-3). Every other mode may only be selected when
// the samples it uses are available (the encoder's obligation, stated in each clause),
// so the unit reads them without looking at the flags. Intra_8x8 also needs avail_corner
// (p[-1,-1]) and all three for its filter (8-78 .. 8-88): the filter runs IN PLACE over
// the store at start -- p'[-1,-1] computed first and written last, each run keeping the
// unfiltered previous sample in a register (s_raw) -- one sample a cycle, 26 cycles.
//
// start (one pulse, ignored while busy) with kind / mode / avail_*:
//   kind 0  luma 4x4    mode = Intra4x4PredMode 0..8 (Table 8-2)        16 samples
//   kind 1  luma 16x16  mode = Intra16x16PredMode 0 V 1 H 2 DC 3 Plane  256 samples
//   kind 2  chroma 8x8  mode = intra_chroma_pred_mode 0 DC 1 H 2 V 3 Plane  64 samples
//   kind 3  luma 8x8    mode = Intra8x8PredMode 0..8 (Table 8-3)        64 samples
// The samples leave in raster order on pred_valid/pred/pred_last with pred_ready as the
// consumer's throttle: one per cycle when the consumer is ready. busy rises with start
// and drops when the last sample is taken.
//
// Datapath. Every sample is one of three shapes of the same 3-tap sum from the store:
//   COPY  t0                          AVG2  (t0 + t1 + 1) >> 1
//   AVG3  (t0 + 2 t1 + t2 + 2) >> 2   (the "(a + 3 b + 2) >> 2" corners are AVG3(a, b, b))
// The stream is a three-stage pipeline gated by one enable (the output register free or
// being taken): stage I registers the tap indices of position pos (the spec's case
// analysis on (x, y) -- zVR, zHD, zHU -- written as one pattern (m-2, m-1, m) /
// (m-1, m) / (m, m+1, m+2) / (m, m+1) / (m, m+1, m+1) / the corner (p[-1,0], p[-1,-1],
// p[0,-1]) / a copy, on one side T or L; a negative offset is p[-1,-1]) or the DC / Plane
// value, stage A fetches the taps (33:1 muxes over the register store), stage B adds.
// (Stage I was split out of A at the Phase 5 fit: with Intra_8x8's wider case analysis
// the two in one cycle missed clk_dec by ~1 ns.) Before the stream:
//   DC     the store summed four samples a cycle (the same tap muxes), the mean(s)
//          registered with the spec's rounding and availability rules: 2 + 2 cycles for
//          a 4x4, 8 + 2 for 16x16, 4 + 2 for chroma (its four quadrant means at once)
//   Plane  H and V (8-70 / 8-121) by nested accumulation instead of multiplies:
//          sum_k k d_k = sum_j (sum_{k>=j} d_k), the d_k walked from the last one down
//          (N cycles + 1), then a / b / c (a cycle; 5 H and 34 H are shift-adds), then
//          the first sample's a + b (x-7) + c (y-7) + 16 (a cycle); per sample the
//          accumulator moves by b along a row and by c to the next row, Clip1 at the
//          register. No multipliers anywhere.
// busy cycles per block (samples + 3 pipeline stages + the prep: DC N+2 cycles, Plane
// N+3, N = groups of four summed / plane taps; measured before stage I, each one cycle
// more since): 4x4 V/H/directional 19, 4x4 DC 23; 16x16 V/H 259, DC 269, Plane 270;
// chroma H/V 67, DC 73, Plane 74; Intra_8x8 the 27-cycle filter first. The next start is
// accepted the cycle after busy falls.
//
// Quartus 17 caveats observed (CLAUDE.md): no `function automatic`, no N'(expr) casts;
// case blocks and part-selects throughout.

`default_nettype none

module intra_pred (
    input  wire        clk,
    input  wire        rst_n,

    // the neighbour store's write port
    input  wire        nb_we,
    input  wire  [5:0] nb_idx,
    input  wire  [7:0] nb_val,

    // the block request
    input  wire        start,
    input  wire  [1:0] kind,
    input  wire  [3:0] mode,
    input  wire        avail_top,
    input  wire        avail_left,
    input  wire        avail_corner,      // p[-1,-1] (Intra_8x8's filter only)

    // the prediction samples, raster order
    output logic       pred_valid,
    output logic [7:0] pred,
    output logic       pred_last,
    input  wire        pred_ready,

    output logic       busy
);

    localparam [1:0] K_L4 = 2'd0, K_L16 = 2'd1, K_CH = 2'd2, K_L8 = 2'd3;
    // the operation decoded from (kind, mode) at start
    localparam [2:0] OP_V = 3'd0, OP_H = 3'd1, OP_DC = 3'd2, OP_PLANE = 3'd3, OP_DIR = 3'd4;
    // the sum shapes
    localparam [1:0] F_COPY = 2'd0, F_AVG2 = 2'd1, F_AVG3 = 2'd2;
    // the tap patterns of the 4x4 case analysis
    localparam [2:0] P_M12 = 3'd0,      // (m-2, m-1, m)   AVG3
                     P_M01 = 3'd1,      // (m-1, m)        AVG2
                     P_P12 = 3'd2,      // (m, m+1, m+2)   AVG3
                     P_P01 = 3'd3,      // (m, m+1)        AVG2
                     P_P11 = 3'd4,      // (m, m+1, m+1)   AVG3: the (a + 3b + 2) >> 2 corners
                     P_CNR = 3'd5,      // (p[-1,0], p[-1,-1], p[0,-1]) AVG3
                     P_CPY = 3'd6;      // (m)             COPY
    localparam [5:0] I_CORNER = 6'd32;

    // ---- the neighbour store ----------------------------------------------------------
    // 33 bytes of registers, read through four 33:1 tap muxes (t0..t3 below): pinned to
    // logic so Quartus never tries a RAM with four asynchronous read ports (CLAUDE.md:
    // async-read arrays at many sites explode into LUT-RAM)
    (* ramstyle = "logic" *) logic [7:0] nb [0:32];
    logic       fw_we;                  // the Intra_8x8 filter's in-place write
    logic [5:0] fw_idx;
    logic [7:0] fw_val;
    always_ff @(posedge clk) begin
        if (nb_we && nb_idx <= 6'd32) nb[nb_idx] <= nb_val;
        else if (fw_we) nb[fw_idx] <= fw_val;
    end

    // ---- the request, latched at start ---------------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_SUM, S_DC, S_PLB0, S_PLB, S_PLA, S_STREAM, S_FILT} state_t;
    state_t     state;
    logic [1:0] k_kind;
    logic [3:0] k_mode;
    logic       av_t, av_l, av_c;
    logic [2:0] op;
    logic [3:0] pc;                     // the prep counter
    logic [7:0] pos;                    // the stream position
    logic       gen_done;

    // decode of the request on the input pins (registered into op at start)
    logic [2:0] op_in;
    always_comb begin
        case (kind)
            K_L4, K_L8: case (mode)
                         4'd0:    op_in = OP_V;
                         4'd1:    op_in = OP_H;
                         4'd2:    op_in = OP_DC;
                         default: op_in = OP_DIR;
                     endcase
            K_L16:   case (mode[1:0])
                         2'd0:    op_in = OP_V;
                         2'd1:    op_in = OP_H;
                         2'd2:    op_in = OP_DC;
                         default: op_in = OP_PLANE;
                     endcase
            default: case (mode[1:0])
                         2'd0:    op_in = OP_DC;
                         2'd1:    op_in = OP_H;
                         2'd2:    op_in = OP_V;
                         default: op_in = OP_PLANE;
                     endcase
        endcase
    end

    // per-kind geometry. The position's x / y (and the case analysis' sx, sy, zVR, zHD,
    // zHU below) are REGISTERS holding position pos's values: computed from pos + 1 on the
    // edge stage I advances, and zero at a start (position 0 is (0, 0) in every kind). P5b
    // timing: pos -> x, y -> z -> m -> index -> s_i* was one cycle (9.9 ns). The last
    // position's advance wraps pos + 1 to a zero geometry in every kind as well (16, 256,
    // 64 all truncate to 0 in their fields), so the start's reset only matters after an
    // aborted block.
    logic [3:0] x, y;                   // the position in the block (registers)
    logic       x_end;                  // last column (register)
    logic [3:0] gx, gy;                 // pos + 1's
    logic       gx_end;
    logic [7:0] g_pos;
    logic [7:0] n_last;                 // last position
    logic [3:0] n_grp;                  // DC: groups of four to sum; Plane: N (8 or 4)
    logic [5:0] i_top_end, i_left_end;  // p[2N-1,-1] and p[-1,2N-1] for the plane's a
    always_comb begin
        g_pos = pos + 8'd1;
        case (k_kind)
            K_L4: begin
                gx = {2'b00, g_pos[1:0]}; gy = {2'b00, g_pos[3:2]}; gx_end = (g_pos[1:0] == 2'd3);
                n_last = 8'd15; n_grp = 4'd2; i_top_end = 6'd3; i_left_end = 6'd19;
            end
            K_L16: begin
                gx = g_pos[3:0]; gy = g_pos[7:4]; gx_end = (g_pos[3:0] == 4'd15);
                n_last = 8'd255; n_grp = 4'd8; i_top_end = 6'd15; i_left_end = 6'd31;
            end
            K_L8: begin
                gx = {1'b0, g_pos[2:0]}; gy = {1'b0, g_pos[5:3]}; gx_end = (g_pos[2:0] == 3'd7);
                n_last = 8'd63; n_grp = 4'd4; i_top_end = 6'd7; i_left_end = 6'd23;
            end
            default: begin
                gx = {1'b0, g_pos[2:0]}; gy = {1'b0, g_pos[5:3]}; gx_end = (g_pos[2:0] == 3'd7);
                n_last = 8'd63; n_grp = 4'd4; i_top_end = 6'd7; i_left_end = 6'd23;
            end
        endcase
    end

    // ---- the 4x4 / 8x8 case analysis (8.3.1.2.4 .. 8.3.1.2.9; 8.3.2.2.5 .. 8.3.2.2.10) ->
    // side, m, pattern. The two sizes are the same equations with N = 4 or 8: the corner
    // of Diagonal_Down_Left at (N-1, N-1), zHU's corner at 2N - 3, its copy beyond; the
    // "below -1" branches of Vertical_Right / Horizontal_Down read (y-2x-1 .. y-2x-3) /
    // (x-2y-1 .. x-2y-3), which in a 4x4 block only occur for x = 0 / y = 0
    logic signed [5:0] sx, sy, m, mm1, mm2, mp1, mp2;   // sx, sy registers (above)
    logic signed [5:0] z_vr, z_hd, z_hu;                // registers
    logic              side;            // 0 = the row above (T), 1 = the column left (L)
    logic [2:0]        pat;
    wire               big = (k_kind == K_L8);
    wire  [2:0]        nm1 = big ? 3'd7 : 3'd3;           // N - 1
    logic signed [5:0] g_sx, g_sy;                      // pos + 1's
    always_comb begin
        g_sx = big ? {3'b000, gx[2:0]} : {4'b0000, gx[1:0]};
        g_sy = big ? {3'b000, gy[2:0]} : {4'b0000, gy[1:0]};
    end
    always_comb begin
        side = 1'b0; m = 6'sd0; pat = P_CPY;
        case (k_mode)
            4'd3: begin                                     // Diagonal_Down_Left
                side = 1'b0;
                if (sx == {3'b000, nm1} && sy == {3'b000, nm1}) begin m = big ? 6'sd14 : 6'sd6; pat = P_P11; end
                else begin m = sx + sy; pat = P_P12; end
            end
            4'd4: begin                                     // Diagonal_Down_Right
                if (sx > sy)      begin side = 1'b0; m = sx - sy; pat = P_M12; end
                else if (sx < sy) begin side = 1'b1; m = sy - sx; pat = P_M12; end
                else              begin pat = P_CNR; end
            end
            4'd5: begin                                     // Vertical_Right
                if (z_vr >= 6'sd0) begin
                    side = 1'b0; m = sx - (sy >>> 1);
                    pat = y[0] ? P_M12 : P_M01;             // zVR odd / even
                end
                else if (z_vr == -6'sd1) pat = P_CNR;
                else begin side = 1'b1; m = sy - (sx <<< 1) - 6'sd1; pat = P_M12; end   // (p[-1,y-2x-1], .., p[-1,y-2x-3])
            end
            4'd6: begin                                     // Horizontal_Down
                if (z_hd >= 6'sd0) begin
                    side = 1'b1; m = sy - (sx >>> 1);
                    pat = x[0] ? P_M12 : P_M01;             // zHD odd / even
                end
                else if (z_hd == -6'sd1) pat = P_CNR;
                else begin side = 1'b0; m = sx - (sy <<< 1) - 6'sd1; pat = P_M12; end   // (p[x-2y-1,-1], .., p[x-2y-3,-1])
            end
            4'd7: begin                                     // Vertical_Left
                side = 1'b0; m = sx + (sy >>> 1);
                pat = y[0] ? P_P12 : P_P01;
            end
            4'd8: begin                                     // Horizontal_Up
                side = 1'b1;
                if (z_hu < (big ? 6'sd13 : 6'sd5))       begin m = sy + (sx >>> 1); pat = x[0] ? P_P12 : P_P01; end
                else if (z_hu == (big ? 6'sd13 : 6'sd5)) begin m = big ? 6'sd6 : 6'sd2; pat = P_P11; end
                else                                     begin m = big ? 6'sd7 : 6'sd3; pat = P_CPY; end
            end
            default: pat = P_CPY;
        endcase
        mm1 = m - 6'sd1;
        mm2 = m - 6'sd2;
        mp1 = m + 6'sd1;
        mp2 = m + 6'sd2;
    end

    // an offset on the chosen side -> store index; a negative offset is p[-1,-1]
    logic [5:0] i_mm2, i_mm1, i_m, i_mp1, i_mp2;
    always_comb begin
        i_mm2 = mm2[5] ? I_CORNER : {1'b0, side, mm2[3:0]};
        i_mm1 = mm1[5] ? I_CORNER : {1'b0, side, mm1[3:0]};
        i_m   = m[5]   ? I_CORNER : {1'b0, side, m[3:0]};
        i_mp1 = mp1[5] ? I_CORNER : {1'b0, side, mp1[3:0]};
        i_mp2 = mp2[5] ? I_CORNER : {1'b0, side, mp2[3:0]};
    end

    // ---- the Intra_8x8 reference filter (8.3.2.2.1), in place: fp 0 the corner into
    // f_cnr (held), fp 1..16 p'[x,-1] x = fp - 1, fp 17..24 p'[-1,y] y = fp - 17, fp 25 the
    // corner written. Every filtered sample is AVG3 of three taps, the edge rules folding
    // into repeated taps ((3a + b + 2) >> 2 = AVG3(a, a, b)); s_raw keeps the unfiltered
    // sample the previous position overwrote.
    logic [4:0] fp;
    logic [7:0] s_raw, f_cnr, f_cnr_raw;
    logic       f_active;               // this position is filtered (its run is available)
    logic [5:0] f_idx;                  // the position's store index
    logic [7:0] fa, fb, fc;             // the three taps
    always_comb begin
        f_idx = I_CORNER; f_active = 1'b0; fa = nb[0]; fb = nb[0]; fc = nb[0];
        if (fp == 5'd0) begin                               // p'[-1,-1] (8-82 .. 8-84)
            f_idx = I_CORNER; f_active = av_c;
            if (av_t && av_l) begin fa = nb[0];  fb = nb[32]; fc = nb[16]; end
            else if (av_t)    begin fa = nb[32]; fb = nb[32]; fc = nb[0];  end
            else if (av_l)    begin fa = nb[32]; fb = nb[32]; fc = nb[16]; end
            else              begin fa = nb[32]; fb = nb[32]; fc = nb[32]; end
        end else if (fp <= 5'd16) begin                     // p'[x,-1] (8-78 .. 8-81)
            logic [3:0] xx;
            xx = fp[3:0] - 4'd1;                            // (fp 16: xx 15)
            if (fp == 5'd16) xx = 4'd15;
            f_idx = {2'b00, xx}; f_active = av_t;
            fb = nb[{2'b00, xx}];
            fa = (xx == 4'd0) ? (av_c ? nb[32] : nb[0]) : s_raw;
            fc = (xx == 4'd15) ? nb[15] : nb[{2'b00, xx + 4'd1}];
        end else if (fp <= 5'd24) begin                     // p'[-1,y] (8-85 .. 8-88)
            logic [2:0] yy;
            yy = fp[2:0] - 3'd1;                            // fp 17..24 -> 0..7
            f_idx = {3'b010, yy}; f_active = av_l;
            fb = nb[{3'b010, yy}];
            fa = (yy == 3'd0) ? (av_c ? f_cnr_raw : nb[16]) : s_raw;
            fc = (yy == 3'd7) ? nb[23] : nb[{3'b010, yy + 3'd1}];
        end
    end
    wire [9:0] f_sum = {2'b00, fa} + {1'b0, fb, 1'b0} + {2'b00, fc} + 10'd2;

    // ---- the tap indices of this cycle --------------------------------------------------
    logic [5:0] i0, i1, i2, i3;         // the prep states' taps (functions of pc)
    logic [5:0] si0, si1, si2;          // the stream's taps of position pos (stage I registers them)
    logic [1:0] f_sel;
    logic [5:0] grp_base;               // DC: the first of this cycle's four samples
    logic [3:0] pl_x;                   // Plane: x' walked from N-1 down to 0 = N-1-pc
    always_comb begin
        // the group's first index: 4x4 groups are p[0..3,-1], p[-1,0..3]; 16x16 the eight
        // runs of four in store order; chroma p[0..3], p[4..7], p[-1,0..3], p[-1,4..7]
        case (k_kind)
            K_L4:    grp_base = pc[0] ? 6'd16 : 6'd0;
            K_L16:   grp_base = {1'b0, pc[2:0], 2'b00};
            default: grp_base = {1'b0, pc[1], 1'b0, pc[0], 2'b00};   // chroma and Intra_8x8
        endcase
        pl_x = n_grp - 4'd1 - pc;
        i0 = 6'd0; i1 = 6'd0; i2 = 6'd0; i3 = 6'd0; f_sel = F_COPY;
        si0 = 6'd0; si1 = 6'd0; si2 = 6'd0;
        // the stream's, computed whatever the state (no state select in front of stage I)
        case (op)
            OP_V:   begin si0 = {2'b00, x}; f_sel = F_COPY; end
            OP_H:   begin si0 = {2'b01, y}; f_sel = F_COPY; end
            OP_DIR: begin
                case (pat)
                    P_M12:   begin si0 = i_mm2;  si1 = i_mm1;    si2 = i_m;   f_sel = F_AVG3; end
                    P_M01:   begin si0 = i_mm1;  si1 = i_m;                   f_sel = F_AVG2; end
                    P_P12:   begin si0 = i_m;    si1 = i_mp1;    si2 = i_mp2; f_sel = F_AVG3; end
                    P_P01:   begin si0 = i_m;    si1 = i_mp1;                 f_sel = F_AVG2; end
                    P_P11:   begin si0 = i_m;    si1 = i_mp1;    si2 = i_mp1; f_sel = F_AVG3; end
                    P_CNR:   begin si0 = 6'd16;  si1 = I_CORNER; si2 = 6'd0;  f_sel = F_AVG3; end
                    default: begin si0 = i_m;                                 f_sel = F_COPY; end
                endcase
            end
            default: f_sel = F_COPY;        // DC / Plane: the value is registered already
        endcase
        case (state)
            S_SUM: begin
                if (op == OP_DC) begin
                    i0 = grp_base; i1 = grp_base + 6'd1; i2 = grp_base + 6'd2; i3 = grp_base + 6'd3;
                end else begin
                    // d_x' = p[N+x',-1] - p[N-2-x',-1]; N-2-x' = pc-1 (p[-1,-1] when x' = N-1)
                    i0 = {2'b00, n_grp + pl_x};
                    i1 = (pc == 4'd0) ? I_CORNER : {2'b00, pc - 4'd1};
                    i2 = {2'b01, n_grp + pl_x};
                    i3 = (pc == 4'd0) ? I_CORNER : {2'b01, pc - 4'd1};
                end
            end
            S_PLB0: begin i0 = i_top_end; i1 = i_left_end; end
            default: ;
        endcase
    end

    // Two sets of tap muxes: the prep states (DC sums, the plane's H / V and corners) select
    // with this cycle's indices (i0..i3: short functions of pc); the stream selects ONLY with
    // stage I's registered indices (s_i*). One shared set behind a state-selected index kept
    // the case analysis (pos -> x, y -> pattern -> m -> index) in front of the 33:1 mux as a
    // static path, even though the stream never used it: 80.2 MHz at -40 C (P5b fit
    // 2026-09-28). The extra three 33:1 x 8 muxes cost ~250 ALMs.
    logic [5:0] s_i0, s_i1, s_i2;
    wire [7:0] t0 = nb[i0];
    wire [7:0] t1 = nb[i1];
    wire [7:0] t2 = nb[i2];
    wire [7:0] t3 = nb[i3];
    wire [7:0] ts0 = nb[s_i0];
    wire [7:0] ts1 = nb[s_i1];
    wire [7:0] ts2 = nb[s_i2];

    // ---- DC: four samples a cycle into per-side and per-group sums ---------------------------
    logic [9:0]  gs_r;                  // the group sum, registered
    logic        gs_valid, gs_top;
    logic [1:0]  gs_slot;
    logic [11:0] acc_t, acc_l;          // 16 samples each at most
    logic [9:0]  gs [0:3];              // 4x4: T, L; chroma: T lo, T hi, L lo, L hi
    // the sums and differences take the samples one cycle after their fetch (tq*: the index,
    // the 33:1 selection and the adds in one cycle missed clk_dec); S_SUM runs to n_grp + 1
    logic [7:0]  tq0, tq1, tq2, tq3;
    logic        tq_v, tq_top;
    logic [1:0]  tq_slot;
    always_ff @(posedge clk) begin tq0 <= t0; tq1 <= t1; tq2 <= t2; tq3 <= t3; end
    wire  [9:0]  gsum = {2'b00, tq0} + {2'b00, tq1} + {2'b00, tq2} + {2'b00, tq3};

    // the means (8.3.1.2.3, 8.3.3.3, 8.3.4.1-3), from the registered sums
    logic [7:0]  dc_l4, dc_l16, dc_l8;
    logic [7:0]  dc_q0, dc_q1, dc_q2, dc_q3;
    wire  [10:0] s4_both  = {1'b0, gs[0]} + {1'b0, gs[1]} + 11'd4;
    wire  [12:0] s16_both = {1'b0, acc_t} + {1'b0, acc_l} + 13'd16;
    wire  [11:0] s16_t    = acc_t + 12'd8;
    wire  [11:0] s16_l    = acc_l + 12'd8;
    wire  [11:0] s8_both  = {1'b0, acc_t[10:0]} + {1'b0, acc_l[10:0]} + 12'd8;
    wire  [10:0] s8_t     = acc_t[10:0] + 11'd4;
    wire  [10:0] s8_l     = acc_l[10:0] + 11'd4;
    wire  [9:0]  s4_t     = gs[0] + 10'd2;
    wire  [9:0]  s4_l     = gs[1] + 10'd2;
    always_comb begin
        // Intra_4x4 DC: p[0..3,-1] in gs[0], p[-1,0..3] in gs[1]
        if (av_t && av_l)   dc_l4 = s4_both[10:3];
        else if (av_l)      dc_l4 = s4_l[9:2];
        else if (av_t)      dc_l4 = s4_t[9:2];
        else                dc_l4 = 8'd128;
        // Intra_16x16 DC
        if (av_t && av_l)   dc_l16 = s16_both[12:5];
        else if (av_l)      dc_l16 = s16_l[11:4];
        else if (av_t)      dc_l16 = s16_t[11:4];
        else                dc_l16 = 8'd128;
        // Intra_8x8 DC (8-91 .. 8-94): the filtered p'[0..7,-1] and p'[-1,0..7]
        if (av_t && av_l)   dc_l8 = s8_both[11:4];
        else if (av_l)      dc_l8 = s8_l[10:3];
        else if (av_t)      dc_l8 = s8_t[10:3];
        else                dc_l8 = 8'd128;
    end
    // chroma DC per 4x4 chroma block (xO, yO): the (0,0) and (4,4) blocks use both runs,
    // (4,0) prefers the run above, (0,4) prefers the run left (8.3.4.1-3)
    wire [10:0] cq0_both = {1'b0, gs[0]} + {1'b0, gs[2]} + 11'd4;
    wire [10:0] cq3_both = {1'b0, gs[1]} + {1'b0, gs[3]} + 11'd4;
    wire [9:0]  cq_t0 = (gs[0] + 10'd2) >> 2, cq_t1 = (gs[1] + 10'd2) >> 2;
    wire [9:0]  cq_l0 = (gs[2] + 10'd2) >> 2, cq_l1 = (gs[3] + 10'd2) >> 2;
    always_comb begin
        if (av_t && av_l)   dc_q0 = cq0_both[10:3];
        else if (av_l)      dc_q0 = cq_l0[7:0];
        else if (av_t)      dc_q0 = cq_t0[7:0];
        else                dc_q0 = 8'd128;
        if (av_t)           dc_q1 = cq_t1[7:0];          // xO > 0, yO == 0
        else if (av_l)      dc_q1 = cq_l0[7:0];
        else                dc_q1 = 8'd128;
        if (av_l)           dc_q2 = cq_l1[7:0];          // xO == 0, yO > 0
        else if (av_t)      dc_q2 = cq_t0[7:0];
        else                dc_q2 = 8'd128;
        if (av_t && av_l)   dc_q3 = cq3_both[10:3];
        else if (av_l)      dc_q3 = cq_l1[7:0];
        else if (av_t)      dc_q3 = cq_t1[7:0];
        else                dc_q3 = 8'd128;
    end
    logic [7:0]  dcq [0:3];             // the registered mean(s); [0] for 4x4 and 16x16
    wire  [1:0]  quad = {y[2], x[2]};   // the chroma 4x4 block of position (x, y)

    // ---- Plane: H, V by nested accumulation; a, b, c; the walking accumulator -------------
    logic signed [8:0]  d_t, d_l;       // p[N+x',-1] - p[N-2-x',-1] and the left one
    logic               d_valid;
    logic signed [11:0] s_t, s_l;       // the running suffix sums
    logic signed [14:0] h_acc, v_acc;   // H, V: |.| <= 36 * 255
    logic signed [17:0] hx, vx;         // sign-extended for the shift-adds
    logic signed [17:0] h5, v5;         // 5 H + 32, 34 H + 32 (16x16 / chroma)
    logic signed [17:0] h5_sh, v5_sh;   // ... >> 6 (arithmetic: a part-select would be unsigned)
    logic signed [12:0] b_r, c_r;       // |b| <= 1355
    logic [12:0]        a_r;            // 16 (p[-1,2N-1] + p[2N-1,-1]) <= 8160
    logic signed [17:0] pl_acc, pl_row; // a + b (x - N+1) + c (y - N+1) + 16 for this position / this row's start
    logic signed [17:0] bc, bc_k;       // b + c and its (N-1) multiple: 7 (b+c) or 3 (b+c)
    logic signed [17:0] pl_first;
    logic signed [17:0] pl_sh;
    logic [7:0]         pl_clip;
    always_comb begin
        hx = {{3{h_acc[14]}}, h_acc};
        vx = {{3{v_acc[14]}}, v_acc};
        if (k_kind == K_L16) begin
            h5 = (hx <<< 2) + hx + 18'sd32;                       // b = (5 H + 32) >> 6   (8-72)
            v5 = (vx <<< 2) + vx + 18'sd32;
        end else begin
            h5 = (hx <<< 5) + (hx <<< 1) + 18'sd32;               // b = (34 H + 32) >> 6  (8-124), 4:2:0
            v5 = (vx <<< 5) + (vx <<< 1) + 18'sd32;
        end
        h5_sh = h5 >>> 6;
        v5_sh = v5 >>> 6;
        bc = {{5{b_r[12]}}, b_r} + {{5{c_r[12]}}, c_r};
        if (k_kind == K_L16) bc_k = (bc <<< 3) - bc;             // 7 (b + c)
        else                 bc_k = (bc <<< 1) + bc;             // 3 (b + c)
        pl_first = {5'b00000, a_r} + 18'sd16 - bc_k;
        // Clip1 of the accumulator >> 5
        pl_sh = pl_acc >>> 5;
        if (pl_sh[17])                      pl_clip = 8'd0;
        else if (pl_sh[16:8] != 9'd0)       pl_clip = 8'd255;
        else                                pl_clip = pl_sh[7:0];
    end

    // ---- the stream pipeline: stage I (indices, the DC / Plane value), A (taps), B (sum) ---
    logic [1:0] s_f;
    logic [7:0] s_val;                  // DC / Plane: the sample value itself
    logic       s_dv, s_valid, s_last;
    logic [7:0] a_t0, a_t1, a_t2;
    logic [1:0] a_f;
    logic       a_valid, a_last;
    wire        adv = !pred_valid || pred_ready;
    wire  [8:0] sum2 = {1'b0, a_t0} + {1'b0, a_t1} + 9'd1;
    wire  [9:0] sum3 = {2'b00, a_t0} + {1'b0, a_t1, 1'b0} + {2'b00, a_t2} + 10'd2;
    logic [7:0] b_val;
    always_comb begin
        case (a_f)
            F_AVG2:  b_val = sum2[8:1];
            F_AVG3:  b_val = sum3[9:2];
            default: b_val = a_t0;
        endcase
    end
    // stage I's value for the registered-value modes
    logic [7:0] i_val;
    always_comb begin
        if (op == OP_DC) i_val = (k_kind == K_CH) ? dcq[quad] : dcq[0];   // (Intra_8x8: one mean)
        else             i_val = pl_clip;
    end

    integer gi;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0;
            k_kind <= 2'd0; k_mode <= 4'd0; av_t <= 1'b0; av_l <= 1'b0; av_c <= 1'b0; op <= OP_V;
            fp <= 5'd0; s_raw <= 8'd0; f_cnr <= 8'd0; f_cnr_raw <= 8'd0; fw_we <= 1'b0; fw_idx <= 6'd0; fw_val <= 8'd0;
            pc <= 4'd0; pos <= 8'd0; gen_done <= 1'b0;
            x <= 4'd0; y <= 4'd0; x_end <= 1'b0; sx <= 6'sd0; sy <= 6'sd0; z_vr <= 6'sd0; z_hd <= 6'sd0; z_hu <= 6'sd0;
            gs_r <= 10'd0; gs_valid <= 1'b0; gs_top <= 1'b0; gs_slot <= 2'd0;
            acc_t <= 12'd0; acc_l <= 12'd0;
            for (gi = 0; gi < 4; gi = gi + 1) begin gs[gi] <= 10'd0; dcq[gi] <= 8'd0; end
            d_t <= 9'sd0; d_l <= 9'sd0; d_valid <= 1'b0; tq_v <= 1'b0; tq_top <= 1'b0; tq_slot <= 2'd0;
            s_t <= 12'sd0; s_l <= 12'sd0; h_acc <= 15'sd0; v_acc <= 15'sd0;
            b_r <= 13'sd0; c_r <= 13'sd0; a_r <= 13'd0;
            pl_acc <= 18'sd0; pl_row <= 18'sd0;
            a_t0 <= 8'd0; a_t1 <= 8'd0; a_t2 <= 8'd0; a_f <= F_COPY; a_valid <= 1'b0; a_last <= 1'b0;
            s_i0 <= 6'd0; s_i1 <= 6'd0; s_i2 <= 6'd0; s_f <= F_COPY; s_val <= 8'd0; s_dv <= 1'b0; s_valid <= 1'b0; s_last <= 1'b0;
            pred_valid <= 1'b0; pred <= 8'd0; pred_last <= 1'b0;
        end else begin
            fw_we <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    k_kind <= kind; k_mode <= mode; av_t <= avail_top; av_l <= avail_left; av_c <= avail_corner; op <= op_in;
                    fp <= 5'd0;
                    busy <= 1'b1;
                    pc <= 4'd0; pos <= 8'd0; gen_done <= 1'b0;
                    x <= 4'd0; y <= 4'd0; x_end <= 1'b0; sx <= 6'sd0; sy <= 6'sd0; z_vr <= 6'sd0; z_hd <= 6'sd0; z_hu <= 6'sd0;
                    gs_valid <= 1'b0; d_valid <= 1'b0; tq_v <= 1'b0;
                    acc_t <= 12'd0; acc_l <= 12'd0;
                    s_t <= 12'sd0; s_l <= 12'sd0; h_acc <= 15'sd0; v_acc <= 15'sd0;
                    a_valid <= 1'b0; s_valid <= 1'b0; pred_valid <= 1'b0;
                    if (kind == K_L8)                            state <= S_FILT;
                    else if (op_in == OP_DC || op_in == OP_PLANE) state <= S_SUM;
                    else                                          state <= S_STREAM;
                end

                S_FILT: begin
                    // one position a cycle; the write lands the edge after, before the next
                    // position reads (its left tap comes from s_raw, never from the store)
                    if (fp == 5'd0) begin
                        f_cnr_raw <= nb[32];
                        f_cnr <= f_active ? f_sum[9:2] : nb[32];
                    end else if (fp <= 5'd24) begin
                        s_raw <= fb;
                        if (f_active) begin fw_we <= 1'b1; fw_idx <= f_idx; fw_val <= f_sum[9:2]; end
                    end else if (fp == 5'd25) begin
                        fw_we <= 1'b1; fw_idx <= I_CORNER; fw_val <= f_cnr;
                    end
                    // leave with the corner's write (fp 25): it lands at the end of the next
                    // cycle, before any tap is fetched -- the stream's first fetch is stage A,
                    // a cycle after stage I, and the DC sums never read the corner. (Before
                    // stage I, fp 26 was needed: the first fetch was the next cycle.)
                    if (fp == 5'd25) begin
                        if (op == OP_DC) state <= S_SUM;
                        else             state <= S_STREAM;
                    end
                    fp <= fp + 5'd1;
                end

                S_SUM: begin
                    // fetch (this cycle) then accumulate (the next): pc walks 0..n_grp, the
                    // cycle pc == n_grp only retires the last fetch
                    tq_v <= (pc < n_grp); tq_top <= !grp_base[4]; tq_slot <= pc[1:0];
                    gs_valid <= tq_v;
                    gs_r <= gsum; gs_top <= tq_top; gs_slot <= tq_slot;
                    if (gs_valid) begin
                        if (gs_top) acc_t <= acc_t + {2'b00, gs_r};
                        else        acc_l <= acc_l + {2'b00, gs_r};
                        gs[gs_slot] <= gs_r;        // 4x4: T, L; chroma: T lo, T hi, L lo, L hi
                    end
                    d_valid <= tq_v;
                    d_t <= {1'b0, tq0} - {1'b0, tq1};
                    d_l <= {1'b0, tq2} - {1'b0, tq3};
                    if (d_valid) begin
                        s_t <= s_t + {{3{d_t[8]}}, d_t};
                        s_l <= s_l + {{3{d_l[8]}}, d_l};
                        h_acc <= h_acc + {{3{s_t[11]}}, s_t} + {{6{d_t[8]}}, d_t};
                        v_acc <= v_acc + {{3{s_l[11]}}, s_l} + {{6{d_l[8]}}, d_l};
                    end
                    pc <= pc + 4'd1;
                    if (pc == n_grp + 4'd1) begin
                        if (op == OP_DC) state <= S_DC;
                        else             state <= S_PLB0;
                    end
                end

                S_DC: begin
                    dcq[0] <= (k_kind == K_L4) ? dc_l4 : (k_kind == K_L16) ? dc_l16 : (k_kind == K_L8) ? dc_l8 : dc_q0;
                    dcq[1] <= dc_q1; dcq[2] <= dc_q2; dcq[3] <= dc_q3;
                    state <= S_STREAM;
                end

                S_PLB0: state <= S_PLB;             // the two corner samples fetched
                S_PLB: begin
                    a_r <= {{1'b0, tq0} + {1'b0, tq1}, 4'b0000};                // a = 16 (p[-1,2N-1] + p[2N-1,-1])
                    b_r <= h5_sh[12:0];                                        // (5 H + 32) >> 6, arithmetic
                    c_r <= v5_sh[12:0];
                    state <= S_PLA;
                end

                S_PLA: begin
                    pl_acc <= pl_first;
                    pl_row <= pl_first;
                    state <= S_STREAM;
                end

                S_STREAM: if (adv) begin
                    // stage B
                    pred_valid <= a_valid;
                    pred <= b_val;
                    pred_last <= a_last;
                    // stage A: the taps of stage I's indices
                    a_t0 <= s_dv ? s_val : ts0; a_t1 <= ts1; a_t2 <= ts2; a_f <= s_f;
                    a_valid <= s_valid; a_last <= s_last;
                    // stage I
                    if (!gen_done) begin
                        s_i0 <= si0; s_i1 <= si1; s_i2 <= si2; s_f <= f_sel;
                        s_val <= i_val; s_dv <= (op == OP_DC || op == OP_PLANE);
                        s_valid <= 1'b1; s_last <= (pos == n_last);
                        pos <= g_pos;
                        x <= gx; y <= gy; x_end <= gx_end; sx <= g_sx; sy <= g_sy;
                        z_vr <= (g_sx <<< 1) - g_sy;    // zVR = 2x - y
                        z_hd <= (g_sy <<< 1) - g_sx;    // zHD = 2y - x
                        z_hu <= g_sx + (g_sy <<< 1);    // zHU = x + 2y
                        if (pos == n_last) gen_done <= 1'b1;
                        if (x_end) begin pl_acc <= pl_row + {{5{c_r[12]}}, c_r}; pl_row <= pl_row + {{5{c_r[12]}}, c_r}; end
                        else       pl_acc <= pl_acc + {{5{b_r[12]}}, b_r};
                    end else s_valid <= 1'b0;
                    // the last sample taken: done
                    if (pred_valid && pred_ready && pred_last) begin
                        busy <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
