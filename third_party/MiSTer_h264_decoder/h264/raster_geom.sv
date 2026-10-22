// h264/raster_geom.sv -- the native raster's geometry (docs/hdmi_raster.md §3b / §4, stage 2)
//
// For the shown picture (disp_fit's cropped size, aspect_vui's SAR, the coded width), the HDMI
// display's shape and the refresh standard, decides the raster sync_gen scans when Video Output is
// Native (HDMI) -- exactly tools/raster_geom_ref.py's integers (the model is written from the
// design text; bench/h264/raster_geom_tb.sv scores this module against it):
//
//   A = Wc sar_w, B = Hc sar_h; with a display (dw, dh nonzero), coded width <= 2,048 (hd_raster: 128 MBs):
//     wider  (A dh > B dw):  Rw = Wc, Rh = round(A dh / (sar_h dw))     (letterboxed inside)
//     narrower (A dh < B dw): Rh = Hc, Rw = round(B dw / (sar_w dh))    (pillarboxed inside)
//     equal:                 Rw x Rh = Wc x Hc
//   -- the display-shaped raster (disp 1: HDMI is given dw : dh). If it does not fit, the
//   picture-sized Wc x Hc (disp 0); if neither, the fitted 720 raster (mode 2, fell back).
//   Fits: 1 <= Rw <= 2,048, 1 <= Rh <= 2,048, L = min(floor(Ae / Rh), 4,000), L - Rw >= 20
//   (hd_raster stage B, docs/hd_raster.md §4: the native raster counts 81 MHz dots, three a 27 MHz
//   dot -- Ae 1,261,260 / 1,529,280, three times disp_ctl's skip, so its events stay in the vertical
//   blank). The frame: N = floor(F / L), R = F mod L; R >= 32: NT = N + 1 lines, one R dots long;
//   else NT = N, one L + R. That odd line is the first blank line (line Rh: sync_gen). Exactly F
//   dots (1,351,350 / 1,350,000 / 1,620,000: three times the 27 MHz frame) a frame. Every picture
//   the decoder accepts fits, picture-sized at worst.
//   round(n / d) = floor((2n + d) / 2d).
//
// Sequencing (disp_fit's pattern): the inputs are compared with the last computed set every cycle
// while `en` (a picture is shown: between streams the geometry HOLDS, like the aspect -- a seek
// never flips the raster to 720 and back); a difference starts a computation (~260 cycles: four
// serial 12-step products, one restoring divider used up to four times) and the results are
// PUBLISHED together. sync_gen takes them only at a frame's first dot.
//
// No `function`, no N'(expr) cast, no DSP (the products are serial shift-add).

`default_nettype none

module raster_geom (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,                // a picture is shown (stream_live): compute; else hold
    input  wire         req,               // Video Output Native (HDMI), progressive, a scaler
    input  wire  [11:0] wc,                // the cropped picture (disp_fit)
    input  wire  [11:0] hc,
    input  wire  [15:0] sar_w,             // resolved (aspect_vui: 1:1 when unspecified)
    input  wire  [15:0] sar_h,
    input  wire  [7:0]  w_mbs,             // the CODED width
    input  wire  [11:0] dw,                // the HDMI display's shape (0: none)
    input  wire  [11:0] dh,
    input  wire  [1:0]  std,               // 0 59.94, 1 60.00, 2 50 Hz (3 reserved)
    output logic [1:0]  mode,              // 0 fitted, 1 native, 2 native asked but fell back
    output logic [11:0] rw,                // the raster's active size (fitted: 720 x 480 / 576)
    output logic [11:0] rh,
    output logic        disp,              // native at the display's shape (HDMI gets dw : dh)
    output logic [11:0] l,                 // native: dots a line
    output logic [11:0] nt,                // ... lines a frame
    output logic [11:0] last,              // ... the odd line's dots (sync_gen: the first blank line, Rh)
    output logic        busy
);

    // (hd_raster stage B) in 81 MHz dots, three a 27 MHz dot: the frame 3F, the active lines by 3 Ae
    wire [20:0] k_f  = (std == 2'd2) ? 21'd1620000 : (std == 2'd1) ? 21'd1350000 : 21'd1351350;
    wire [20:0] k_ae = (std == 2'd2) ? 21'd1529280 : 21'd1261260;

    wire [100:0] in_set = {req, wc, hc, sar_w, sar_h, w_mbs, dw, dh, std};
    logic [100:0] last_set;
    logic         have;

    logic        q_req;
    logic [11:0] q_wc, q_hc, q_dw, q_dh;
    logic [15:0] q_sw, q_sh;
    logic [7:0]  q_w;
    logic [20:0] q_f, q_ae;
    logic        q_pal;

    // the serial products: A = wc sar_w, B = hc sar_h, D1 = sar_h dw, D2 = sar_w dh (12-bit
    // multipliers wc / hc / dw / dh), then P = A dh, Q = B dw
    logic [39:0] a_acc, b_acc, d1_acc, d2_acc, a_md, b_md, d1_md, d2_md;
    logic [11:0] a_mr, b_mr, d1_mr, d2_mr;
    logic [3:0]  m_cnt;
    logic [27:0] r_a, r_b, r_d1, r_d2;

    // the divider: restoring, 48 steps (dividend 48 bits, divisor 32)
    logic [47:0] dv_n, dv_q;
    logic [31:0] dv_d;
    logic [32:0] dv_rem;
    logic [5:0]  dv_cnt;
    wire  [32:0] dv_trial = {dv_rem[31:0], dv_n[47]};
    wire         dv_ge = dv_trial >= {1'b0, dv_d};

    logic [11:0] c_rw, c_rh, c_l;
    logic        c_disp;
    logic [1:0]  r_mode;
    logic [11:0] r_nt, r_last;

    typedef enum logic [3:0] {
        S_IDLE, S_CHK, S_M1, S_M2SET, S_M2, S_CMP, S_DIV, S_RDIM, S_FIT, S_LQ, S_NQ, S_PUB
    } st_t;
    st_t st, st_ret;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; st_ret <= S_IDLE; busy <= 1'b0; last_set <= '0; have <= 1'b0;
            q_req <= 1'b0; q_wc <= '0; q_hc <= '0; q_dw <= '0; q_dh <= '0; q_sw <= '0; q_sh <= '0; q_w <= '0;
            q_f <= '0; q_ae <= '0; q_pal <= 1'b0;
            a_acc <= '0; b_acc <= '0; d1_acc <= '0; d2_acc <= '0; a_md <= '0; b_md <= '0; d1_md <= '0; d2_md <= '0;
            a_mr <= '0; b_mr <= '0; d1_mr <= '0; d2_mr <= '0; m_cnt <= '0;
            r_a <= '0; r_b <= '0; r_d1 <= '0; r_d2 <= '0;
            dv_n <= '0; dv_q <= '0; dv_d <= '0; dv_rem <= '0; dv_cnt <= '0;
            c_rw <= '0; c_rh <= '0; c_l <= '0; c_disp <= 1'b0; r_mode <= 2'd0; r_nt <= '0; r_last <= '0;
            mode <= 2'd0; rw <= 12'd720; rh <= 12'd480; disp <= 1'b0; l <= '0; nt <= '0; last <= '0;
        end else begin
            case (st)
                S_IDLE: if (en && (!have || in_set != last_set)) begin
                    last_set <= in_set; have <= 1'b1; busy <= 1'b1;
                    q_req <= req; q_wc <= wc; q_hc <= hc; q_dw <= dw; q_dh <= dh; q_w <= w_mbs;
                    q_sw <= (sar_w == 16'd0 || sar_h == 16'd0) ? 16'd1 : sar_w;
                    q_sh <= (sar_w == 16'd0 || sar_h == 16'd0) ? 16'd1 : sar_h;
                    q_f <= k_f; q_ae <= k_ae; q_pal <= (std == 2'd2);
                    st <= S_CHK;
                end
                S_CHK: begin
                    if (!q_req) begin
                        r_mode <= 2'd0; st <= S_PUB;
                    end else if (q_dw == 12'd0 || q_dh == 12'd0 || q_w > 8'd128 || q_wc == 12'd0 || q_hc == 12'd0) begin
                        r_mode <= 2'd2; st <= S_PUB;
                    end else begin
                        a_acc <= '0; b_acc <= '0; d1_acc <= '0; d2_acc <= '0;
                        a_md <= {24'd0, q_sw}; b_md <= {24'd0, q_sh}; d1_md <= {24'd0, q_sh}; d2_md <= {24'd0, q_sw};
                        a_mr <= q_wc; b_mr <= q_hc; d1_mr <= q_dw; d2_mr <= q_dh;
                        m_cnt <= 4'd12; st <= S_M1;
                    end
                end
                S_M1: begin                                       // A, B, D1, D2
                    if (a_mr[0])  a_acc  <= a_acc  + a_md;
                    if (b_mr[0])  b_acc  <= b_acc  + b_md;
                    if (d1_mr[0]) d1_acc <= d1_acc + d1_md;
                    if (d2_mr[0]) d2_acc <= d2_acc + d2_md;
                    a_md <= {a_md[38:0], 1'b0}; b_md <= {b_md[38:0], 1'b0}; d1_md <= {d1_md[38:0], 1'b0}; d2_md <= {d2_md[38:0], 1'b0};
                    a_mr <= {1'b0, a_mr[11:1]}; b_mr <= {1'b0, b_mr[11:1]}; d1_mr <= {1'b0, d1_mr[11:1]}; d2_mr <= {1'b0, d2_mr[11:1]};
                    m_cnt <= m_cnt - 4'd1;
                    if (m_cnt == 4'd1) st <= S_M2SET;
                end
                S_M2SET: begin                                    // P = A dh (in a_acc), Q = B dw (in b_acc)
                    r_a <= a_acc[27:0]; r_b <= b_acc[27:0]; r_d1 <= d1_acc[27:0]; r_d2 <= d2_acc[27:0];
                    a_md <= {12'd0, a_acc[27:0]}; b_md <= {12'd0, b_acc[27:0]};
                    a_acc <= '0; b_acc <= '0;
                    a_mr <= q_dh; b_mr <= q_dw;
                    m_cnt <= 4'd12; st <= S_M2;
                end
                S_M2: begin
                    if (a_mr[0]) a_acc <= a_acc + a_md;
                    if (b_mr[0]) b_acc <= b_acc + b_md;
                    a_md <= {a_md[38:0], 1'b0}; b_md <= {b_md[38:0], 1'b0};
                    a_mr <= {1'b0, a_mr[11:1]}; b_mr <= {1'b0, b_mr[11:1]};
                    m_cnt <= m_cnt - 4'd1;
                    if (m_cnt == 4'd1) st <= S_CMP;
                end
                S_CMP: begin                                      // the display-shaped candidate
                    c_disp <= 1'b1;
                    if (a_acc > b_acc) begin                      // wider: Rh = round(P / D1)
                        c_rw <= q_wc;
                        dv_n <= {7'd0, a_acc, 1'b0} + {20'd0, r_d1}; dv_d <= {3'd0, r_d1, 1'b0};
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd48; st <= S_DIV; st_ret <= S_RDIM;
                    end else if (a_acc < b_acc) begin             // narrower: Rw = round(Q / D2)
                        c_rh <= q_hc;
                        dv_n <= {7'd0, b_acc, 1'b0} + {20'd0, r_d2}; dv_d <= {3'd0, r_d2, 1'b0};
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd48; st <= S_DIV; st_ret <= S_RDIM;
                    end else begin
                        c_rw <= q_wc; c_rh <= q_hc; st <= S_FIT;
                    end
                end
                S_DIV: begin
                    dv_rem <= dv_ge ? (dv_trial - {1'b0, dv_d}) : dv_trial;
                    dv_q <= {dv_q[46:0], dv_ge};
                    dv_n <= {dv_n[46:0], 1'b0};
                    dv_cnt <= dv_cnt - 6'd1;
                    if (dv_cnt == 6'd1) st <= st_ret;
                end
                S_RDIM: begin                                     // the quotient, saturated at 4,095 (then it cannot fit)
                    if (a_acc > b_acc) c_rh <= (dv_q > 48'd4095) ? 12'd4095 : dv_q[11:0];
                    else               c_rw <= (dv_q > 48'd4095) ? 12'd4095 : dv_q[11:0];
                    st <= S_FIT;
                end
                S_FIT: begin                                      // the size bounds; then L = floor(Ae / Rh)
                    if (c_rw == 12'd0 || c_rw > 12'd2048 || c_rh == 12'd0 || c_rh > 12'd2048) begin
                        if (c_disp) begin c_rw <= q_wc; c_rh <= q_hc; c_disp <= 1'b0; end   // picture-sized next
                        else begin r_mode <= 2'd2; st <= S_PUB; end
                    end else begin
                        dv_n <= {27'd0, q_ae}; dv_d <= {20'd0, c_rh};
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd48; st <= S_DIV; st_ret <= S_LQ;
                    end
                end
                S_LQ: begin
                    // L, capped at 4,000; it fits iff L - Rw >= 20
                    if (((dv_q > 48'd4000) ? 13'd4000 : {1'b0, dv_q[11:0]}) >= {1'b0, c_rw} + 13'd20) begin
                        c_l <= (dv_q > 48'd4000) ? 12'd4000 : dv_q[11:0];
                        dv_n <= {27'd0, q_f}; dv_d <= {20'd0, ((dv_q > 48'd4000) ? 12'd4000 : dv_q[11:0])};
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd48; st <= S_DIV; st_ret <= S_NQ;
                    end else if (c_disp) begin
                        c_rw <= q_wc; c_rh <= q_hc; c_disp <= 1'b0; st <= S_FIT;
                    end else begin
                        r_mode <= 2'd2; st <= S_PUB;
                    end
                end
                S_NQ: begin                                       // N = floor(F / L), R = F mod L
                    if (dv_rem[11:0] >= 12'd32) begin
                        r_nt <= dv_q[11:0] + 12'd1; r_last <= dv_rem[11:0];
                    end else begin
                        r_nt <= dv_q[11:0]; r_last <= c_l + dv_rem[11:0];
                    end
                    r_mode <= 2'd1; st <= S_PUB;
                end
                S_PUB: begin
                    mode <= r_mode;
                    if (r_mode == 2'd1) begin
                        rw <= c_rw; rh <= c_rh; disp <= c_disp; l <= c_l; nt <= r_nt; last <= r_last;
                    end else begin
                        rw <= 12'd720; rh <= q_pal ? 12'd576 : 12'd480; disp <= 1'b0; l <= '0; nt <= '0; last <= '0;
                    end
                    busy <= 1'b0; st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
