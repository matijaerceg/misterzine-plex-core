// h264/disp_fit.sv -- the display fit's per-picture parameters (P6 step 3, docs/analog.md §5)
//
// For the shown store (its coded size, crop and SAR), the Analog Aspect mode and the raster
// (480i or not; 480 or 576 lines), computes where and how big the picture appears on the
// 720x480 / 720x576 raster and
// how the reader walks the source to get there -- exactly tools/disp_fit_ref.py's integers
// (the model is written from the design text; this module is scored against it by
// bench/h264/disp_fit_tb.sv):
//
//   Wc = 16 W - 2 (left + right)            Hc = 16 HF - (cuy4 ? 4 : 2)(top + bottom)
//   a crop leaving nothing (Wc or Hc <= 0): ignored, crop_bad -- the coded picture whole
//   A = Wc sar_w, B = Hc sar_h;  wide = 3 A >= 4 B          (at least as wide as 4:3)
//   Letterbox & wide / Crop & narrow: ow = 720, oh = round(640 B / A);
//   otherwise oh = 480, ow = round(540 A / B)         (round(n/d) = floor((2n + d) / 2d))
//   Fit (issue #11, docs/analog.md §5): the anamorphic 16:9 fit -- Letterbox computed for the 16:9 a
//   TV in its wide mode shows the raster at. Wider than 16:9 (9 A > 16 B): ow = 720, oh = round(rh P /
//   Q), P = 16 B, Q = 9 A -- A''s path below with a 16 x 9 display (lb stays 0: the raster is the
//   analog 4:3 one); else oh = 480, ow = round(405 A / B) (720 x 9/16; 16:9 itself fills the raster)
//   On the 576-line raster (`pal`, P6 step 6, docs/analog.md §10: 720 dots = 4:3 at 576
//   lines, a pixel 16:15): 576 for 480 and oh = round(768 B / A) (540 is the same on both)
//   Fill (mode 3, HDMI in Progressive with Analog Aspect Auto; docs/hdmi_raster.md §3a): the raster
//   filled, 720 x rh (before issue #11 that was Fit's rule too), but A' when the picture is wider than the HDMI display (A disp_h > B disp_w, disp_w and
//   disp_h nonzero): ow = 720, oh = round(rh B disp_w / (A disp_h)) -- B disp_w and A disp_h
//   (40 bits: two serial 12-step shift-add products, no DSP) shifted down together until
//   A disp_h fits 28 bits -- and the vertical alone snaps (oh within 3.5 % of Hc <= rh -> Hc);
//   `lb` published with the set (emu then gives HDMI the display's shape)
//   Native (`nat`, stage 2, docs/hdmi_raster.md §3b): the picture 1:1 on raster_geom's nat_w x
//   nat_h raster -- ow, oh = Wc, Hc, steps 1.0, no snap, centred: ox0 = (nat_w - Wc) >> 1, oy0 =
//   (nat_h - Hc) >> 1; the mode is ignored
//   ow, oh clamped to [2, 8191] (clamp: an absurd SAR under Crop); the native snap: under
//   Letterbox / Crop / Fit, within 3.5 % of Wc x Hc on both axes -> Wc x Hc (1:1)
//   ox0 = (720 - ow) >>> 1, oy0 = (480 - oh) >>> 1    (576 - oh; negative under Crop)
//   sx = (Wc << 16) / ow, sy = (Hc << 16) / oh        (Q.16, floor)
//   dh = pow2floor(sx) <= 8, >= 2 when 16 W > 1,024 (fitted only: the native line holds 2,048 samples
//   since hd_raster stage B); dv = pow2floor(sy) <= 8, <= 4 when
//   W > 80 (the fetch budget). At 480i too: the raster is 480 lines over two fields (a field
//   takes alternate rows); `il` does not change the fit (kept as an input: the set's change)
//   Anti-twitter (`at`, P6 step 4, docs/analog.md §9: the option, 480i, a frame store): the
//   reader fetches SLIDING luma boxes of 2 dv rows, so dv <= 4, and <= 2 when W > 40 (the 480i
//   line's fetch budget); `slide` publishes it with the set (a reader never sees half a set)
//   The Area pre-filter (`area`, docs/analog.md §11b; emu ties it high -- decided 2026-10-05: always
//   on; low is the Sharp control the benches compare with main): per axis on the decimated grid, a
//   code A 0..4 = weights (8 - A, A, 0) in eighths, from the residual step r = s >> d_l2 (Q.16):
//   r <= 1.0 -> 0, else A = min(4, (4 r - 3.5) >> 16). Vertically anti-twitter's 4 where it applies
//   (the stronger). The fetch budget (two boxes: 2 dv <= 8 and dv (6 W + 180) <= 1,300 clk_mem
//   cycles, two stored rows a 480p line) else 0; anti-twitter keeps its 4. Under Area the fitted
//   raster keeps every column (no dh >= 2 past 1,024: the slots hold 2,048). `hpf` / `vpf`
//   published with the set
//
// Sequencing: the inputs are compared with the last computed set every cycle; a difference
// starts a computation (~150 clk cycles: one restoring divider, 40 steps, used three times)
// and the results are PUBLISHED together at its end -- a reader never sees half a set. The
// inputs change at a pickup (line 500 progressive; at 480i half a field before the next),
// leaving ~20,000 cycles before the next field's first line is requested.
// A picture of a new size (a rotating phone's new SPS) is just a new input set.
//
// No `function`, no N'(expr) cast (Quartus 17: CLAUDE.md "Lessons").

`default_nettype none

module disp_fit (
    input  wire         clk,
    input  wire         rst_n,
    // the shown store (disp_ctl's sh_*, aspect_vui's resolved SAR) and the mode
    input  wire  [7:0]  w_mbs,
    input  wire  [7:0]  hf_mbs,
    input  wire  [40:0] crop,              // {cuy4, left, right, top, bottom} (recon_top)
    input  wire  [15:0] sar_w,             // resolved: 1:1 when unspecified (aspect_vui)
    input  wire  [15:0] sar_h,
    input  wire  [1:0]  mode,              // 0 Letterbox, 1 Crop, 2 Fit (anamorphic 16:9), 3 Fill (720 x rh, or A' when wider than the display)
    input  wire  [11:0] disp_w,            // A': the HDMI display's shape (HDMI_WIDTH x HDMI_HEIGHT; 0 = none)
    input  wire  [11:0] disp_h,
    input  wire         nat,               // stage 2: the native raster (raster_geom), nat_w x nat_h
    input  wire  [11:0] nat_w,
    input  wire  [11:0] nat_h,
    input  wire         il,                // the 480i raster
    input  wire         at,                // anti-twitter applies to this picture (emu: the option, 480i, a frame store)
    input  wire         pal,               // the 576-line raster (P6 step 6)
    input  wire         area,              // the Area pre-filter (docs/analog.md §11b): emu 1; 0 the benches' Sharp control
    // (1.2) a host-computed output rectangle; the normal fit still supplies source steps.
    input  wire         geometry_en,
    input  wire  [12:0] geometry_x,        // signed two's-complement
    input  wire  [12:0] geometry_y,
    input  wire  [12:0] geometry_w,
    input  wire  [12:0] geometry_h,
    input  wire         geometry_clip_en,
    input  wire  [11:0] geometry_clip_x,
    input  wire  [11:0] geometry_clip_y,
    input  wire  [11:0] geometry_clip_w,
    input  wire  [11:0] geometry_clip_h,
    // the published fit (stable between computations)
    output logic [12:0] ow,                // the output rectangle, raster pixels / frame lines
    output logic [12:0] oh,
    output logic [13:0] ox0,               // its top-left (two's complement: negative under Crop)
    output logic [13:0] oy0,
    output logic        clip_en,
    output logic [11:0] clip_x,
    output logic [11:0] clip_y,
    output logic [11:0] clip_w,
    output logic [11:0] clip_h,
    output logic [27:0] sx,                // source samples per output pixel, Q.16
    output logic [27:0] sy,                // source rows per output frame line, Q.16
    output logic [1:0]  dh_l2,             // log2 of the decimation factors (0..3)
    output logic [1:0]  dv_l2,
    output logic [11:0] wc,                // the cropped size
    output logic [11:0] hc,
    output logic [11:0] lx,                // the crop's origin, samples / rows
    output logic [11:0] ty,
    output logic        crop_bad,          // the crop left nothing: ignored
    output logic        snap,              // shown 1:1 (the native snap)
    output logic        clamp,             // ow / oh clamped at 8,191
    output logic        slide,             // anti-twitter: the luma rows are sliding boxes of 2 dv rows (docs/analog.md §9)
    output logic        lb,                // A': letterboxed inside the raster, which is shown at the display's shape
    output logic [2:0]  hpf,               // (§11b) the pre-filters: A 0..4 = (8 - A, A, 0)
    output logic [2:0]  vpf,
    output logic        busy               // a computation is running (the outputs are the last set)
);

    // ---- the input set, compared every cycle ----------------------------------------------
    wire [245:0] in_set = {w_mbs, hf_mbs, crop, sar_w, sar_h, mode, il, at, pal, disp_w, disp_h, nat, nat_w, nat_h, area,
                           geometry_en, geometry_x, geometry_y, geometry_w, geometry_h,
                           geometry_clip_en, geometry_clip_x, geometry_clip_y, geometry_clip_w, geometry_clip_h};
    logic [245:0] last_set;
    logic        have;                     // a set has been computed since reset

    // ---- working registers ------------------------------------------------------------------
    logic [7:0]  k_w, k_hf;
    logic        k_cuy4, k_il, k_at, k_pal;
    logic [9:0]  k_l, k_r, k_t, k_b;
    logic [15:0] k_sw, k_sh;
    logic [1:0]  k_mode;
    logic [13:0] t_wc, t_hc;               // signed: may be <= 0 before the bad check
    logic [11:0] r_wc, r_hc, r_lx, r_ty;
    logic        r_bad, r_wide, r_clamp, r_snap;
    logic [27:0] r_a, r_b;                 // Wc sar_w, Hc sar_h
    logic [12:0] r_ow, r_oh;
    logic [12:0] r_geom_x, r_geom_y;
    logic        k_geom;
    logic [12:0] k_geom_x, k_geom_y, k_geom_w, k_geom_h;
    logic        k_clip_en;
    logic [11:0] k_clip_x, k_clip_y, k_clip_w, k_clip_h;
    logic [27:0] r_sx;
    logic [11:0] k_dw, k_dh, k_nw, k_nh;
    logic        k_nat;
    logic        r_lb;
    logic        r_w16;                    // (issue #11) Fit: wider than 16:9 -- the quotient is oh
    logic        k_area;                   // (§11b) the Area pre-filter
    logic [27:0] r_sy;
    logic [1:0]  r_dhl2, r_dvl2;
    logic [2:0]  r_hpf, r_vpf;
    // A': the serial products B disp_w (pm_p) and A disp_h (pm_q), 12 shift-add steps
    logic [39:0] pm_p, pm_q, pm_b, pm_a;
    logic [11:0] pm_mw, pm_mh;
    logic [3:0]  pm_cnt;

    // ---- the divider: restoring, 40 steps -----------------------------------------------------
    logic [39:0] dv_n;                     // dividend, shifted out MSB first
    logic [28:0] dv_d;                     // divisor
    logic [29:0] dv_rem;
    logic [39:0] dv_q;
    logic [5:0]  dv_cnt;
    wire  [29:0] dv_trial = {dv_rem[28:0], dv_n[39]};
    wire         dv_ge = dv_trial >= {1'b0, dv_d};

    typedef enum logic [3:0] {
        S_IDLE, S_CROP, S_BAD, S_MUL, S_SEL, S_DIV, S_Q1, S_SNAP, S_Q2, S_Q3, S_PUB,
        S_PM, S_PWIDE, S_PSH, S_PF, S_PF2
    } st_t;
    st_t st, st_ret;

    // products and constants (shift-add where the factor is a constant)
    wire [29:0] a3 = {r_a, 1'b0} + {2'd0, r_a};                 // 3 A
    wire [29:0] b4 = {r_b, 2'b00};                              // 4 B
    wire [37:0] b640 = {1'b0, r_b, 9'd0} + {3'd0, r_b, 7'd0};   // 640 B = 512 B + 128 B
    wire [37:0] b768 = {1'b0, r_b, 9'd0} + {2'd0, r_b, 8'd0};   // 768 B = 512 B + 256 B (576 lines)
    wire [12:0] rh   = k_pal ? 13'd576 : 13'd480;               // the raster's lines
    wire [37:0] a540 = {1'b0, r_a, 9'd0} + {6'd0, r_a, 4'd0} + {7'd0, r_a, 3'd0} + {8'd0, r_a, 2'd0}; // 540 A
    wire [37:0] a405 = {2'd0, r_a, 8'd0} + {3'd0, r_a, 7'd0} + {6'd0, r_a, 4'd0} + {8'd0, r_a, 2'd0} + {10'd0, r_a}; // 405 A (Fit)
    // A': rh x (B disp_w), shifted below 2^28: 480 P = 512 P - 32 P, 576 P = 512 P + 64 P (38 bits)
    wire [37:0] p_rh = k_pal ? ({1'b0, pm_p[27:0], 9'd0} + {4'd0, pm_p[27:0], 6'd0})
                             : ({1'b0, pm_p[27:0], 9'd0} - {5'd0, pm_p[27:0], 5'd0});
    // the snap's test: 1000 |ow - Wc| <= 35 Wc (alike for oh)
    wire [13:0] dw  = ({1'b0, r_ow} >= {2'd0, r_wc}) ? ({1'b0, r_ow} - {2'd0, r_wc}) : ({2'd0, r_wc} - {1'b0, r_ow});
    wire [13:0] dhh = ({1'b0, r_oh} >= {2'd0, r_hc}) ? ({1'b0, r_oh} - {2'd0, r_hc}) : ({2'd0, r_hc} - {1'b0, r_oh});
    wire [23:0] dw1000 = {dw, 10'd0} - {6'd0, dw, 4'd0} - {7'd0, dw, 3'd0};     // 1024 - 16 - 8
    wire [23:0] dh1000 = {dhh, 10'd0} - {6'd0, dhh, 4'd0} - {7'd0, dhh, 3'd0};
    wire [23:0] wc35 = {7'd0, r_wc, 5'd0} + {11'd0, r_wc, 1'b0} + {12'd0, r_wc};  // 32 + 2 + 1
    wire [23:0] hc35 = {7'd0, r_hc, 5'd0} + {11'd0, r_hc, 1'b0} + {12'd0, r_hc};
    // the vertical decimation's step, as published (sy is the divider's quotient in S_PUB)
    wire [28:0] vstep_pub = {1'b0, dv_q[27:0]};
    // (§11b) the residual steps (Q.16) after the decimation, and each axis's pre-filter code
    logic [27:0] rh_q, rv_q;
    always_comb begin
        case (r_dhl2)
            2'd0: rh_q = r_sx;
            2'd1: rh_q = {1'b0, r_sx[27:1]};
            2'd2: rh_q = {2'b0, r_sx[27:2]};
            default: rh_q = {3'b0, r_sx[27:3]};
        endcase
        case (r_dvl2)
            2'd0: rv_q = r_sy;
            2'd1: rv_q = {1'b0, r_sy[27:1]};
            2'd2: rv_q = {2'b0, r_sy[27:2]};
            default: rv_q = {3'b0, r_sy[27:3]};
        endcase
    end
    // Area's A = min(4, (4 r - 4 + 1/2) >> 16) where r > 1.0 (then 4 r - 3.5 > 0.5)
    wire [29:0] ah_t = {rh_q, 2'b00} - 30'd229376;
    wire [29:0] av_t = {rv_q, 2'b00} - 30'd229376;
    wire [2:0]  ah   = (ah_t[29:16] >= 14'd4) ? 3'd4 : {1'b0, ah_t[17:16]};
    wire [2:0]  av   = (av_t[29:16] >= 14'd4) ? 3'd4 : {1'b0, av_t[17:16]};
    wire        rh_gt1 = (rh_q > 28'h001_0000), rv_gt1 = (rv_q > 28'h001_0000);
    wire [2:0]  hc_w = (!rh_gt1 || !k_area) ? 3'd0 : ah;
    wire [2:0]  vc_w = (!rv_gt1 || !k_area) ? 3'd0 : av;
    // the fetch budget: a stored row of two boxes costs ~ dv (6 W + 180) clk_mem cycles (luma 2 dv rows of
    // 2W words, chroma 2 dv rows of W, ~45 a row's latency); a 480p line (2,860) fetches up to two:
    // 2 dv <= 8 and the cost <= 1,300
    wire [3:0]  dvn  = 4'd1 << r_dvl2;
    wire [11:0] dvw  = {4'd0, k_w} << r_dvl2;                      // dv W (<= 2,040)
    wire [15:0] c2   = {1'b0, dvw, 3'd0} - {3'd0, dvw, 1'b0} +                          // 6 dvW
                       {5'd0, dvn, 7'd0} + {7'd0, dvn, 5'd0} + {8'd0, dvn, 4'd0} + {10'd0, dvn, 2'd0};   // + 180 dv
    wire        fit2 = (dvn <= 4'd4) && (c2 <= 16'd1300);
    // the rectangle's offsets: (720 - ow) and (480 - oh), halved with the sign kept
    wire [13:0] ox_d = (k_nat ? {2'd0, k_nw} : 14'd720) - {1'b0, r_ow};
    wire [13:0] oy_d = (k_nat ? {2'd0, k_nh} : {1'b0, rh}) - {1'b0, r_oh};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_set <= '0; have <= 1'b0; st <= S_IDLE; st_ret <= S_IDLE; busy <= 1'b0;
            k_w <= '0; k_hf <= '0; k_cuy4 <= 1'b0; k_il <= 1'b0; k_at <= 1'b0; k_pal <= 1'b0; k_l <= '0; k_r <= '0; k_t <= '0; k_b <= '0;
            k_geom <= 1'b0; k_geom_x <= '0; k_geom_y <= '0; k_geom_w <= '0; k_geom_h <= '0; r_geom_x <= '0; r_geom_y <= '0;
            k_clip_en <= 1'b0; k_clip_x <= '0; k_clip_y <= '0; k_clip_w <= '0; k_clip_h <= '0;
            k_sw <= '0; k_sh <= '0; k_mode <= '0; k_dw <= '0; k_dh <= '0; r_lb <= 1'b0; lb <= 1'b0; r_w16 <= 1'b0;
            k_nat <= 1'b0; k_nw <= '0; k_nh <= '0;
            pm_p <= '0; pm_q <= '0; pm_b <= '0; pm_a <= '0; pm_mw <= '0; pm_mh <= '0; pm_cnt <= '0;
            t_wc <= '0; t_hc <= '0; r_wc <= '0; r_hc <= '0; r_lx <= '0; r_ty <= '0;
            r_bad <= 1'b0; r_wide <= 1'b0; r_clamp <= 1'b0; r_snap <= 1'b0; r_a <= '0; r_b <= '0;
            r_ow <= '0; r_oh <= '0; r_sx <= '0;
            dv_n <= '0; dv_d <= '0; dv_rem <= '0; dv_q <= '0; dv_cnt <= '0;
            ow <= 13'd720; oh <= 13'd480; ox0 <= '0; oy0 <= '0; sx <= 28'h001_0000; sy <= 28'h001_0000;
            clip_en <= 1'b0; clip_x <= '0; clip_y <= '0; clip_w <= '0; clip_h <= '0;
            dh_l2 <= '0; dv_l2 <= '0; wc <= 12'd720; hc <= 12'd480; lx <= '0; ty <= '0;
            crop_bad <= 1'b0; snap <= 1'b0; clamp <= 1'b0; slide <= 1'b0;
            k_area <= 1'b0; r_sy <= '0; r_dhl2 <= '0; r_dvl2 <= '0; r_hpf <= '0; r_vpf <= '0; hpf <= '0; vpf <= '0;
        end else begin
            case (st)
                S_IDLE: if (!have || in_set != last_set) begin
                    last_set <= in_set; have <= 1'b1; busy <= 1'b1;
                    k_w <= w_mbs; k_hf <= hf_mbs;
                    {k_cuy4, k_l, k_r, k_t, k_b} <= crop;
                    k_sw <= (sar_w == 16'd0 || sar_h == 16'd0) ? 16'd1 : sar_w;
                    k_sh <= (sar_w == 16'd0 || sar_h == 16'd0) ? 16'd1 : sar_h;
                    k_mode <= mode; k_il <= il; k_at <= at; k_pal <= pal; k_dw <= disp_w; k_dh <= disp_h;
                    k_nat <= nat; k_nw <= nat_w; k_nh <= nat_h; k_area <= area;
                    k_geom <= geometry_en && !nat; k_geom_x <= geometry_x; k_geom_y <= geometry_y;
                    k_geom_w <= geometry_w; k_geom_h <= geometry_h;
                    k_clip_en <= geometry_clip_en && !nat;
                    k_clip_x <= geometry_clip_x; k_clip_y <= geometry_clip_y;
                    k_clip_w <= geometry_clip_w; k_clip_h <= geometry_clip_h;
                    r_lb <= 1'b0; r_w16 <= 1'b0;
                    st <= S_CROP;
                end
                S_CROP: begin
                    // 16 W - 2 (l + r); 16 HF - uy (t + b), as 14-bit two's complement
                    t_wc <= {2'd0, k_w, 4'd0} - {2'd0, ({1'b0, k_l} + {1'b0, k_r}), 1'b0};
                    t_hc <= {2'd0, k_hf, 4'd0} - (k_cuy4 ? {1'b0, ({1'b0, k_t} + {1'b0, k_b}), 2'b00}
                                                        : {2'd0, ({1'b0, k_t} + {1'b0, k_b}), 1'b0});
                    st <= S_BAD;
                end
                S_BAD: begin
                    // <= 0 is the sign bit or zero
                    if (t_wc[13] || t_wc == 14'd0 || t_hc[13] || t_hc == 14'd0) begin
                        r_bad <= 1'b1; r_wc <= {k_w, 4'd0}; r_hc <= {k_hf, 4'd0}; r_lx <= '0; r_ty <= '0;
                    end else begin
                        r_bad <= 1'b0; r_wc <= t_wc[11:0]; r_hc <= t_hc[11:0];
                        r_lx <= {1'b0, k_l, 1'b0};
                        r_ty <= k_cuy4 ? {k_t, 2'b00} : {1'b0, k_t, 1'b0};
                    end
                    st <= S_MUL;
                end
                S_MUL: begin
                    r_a <= {16'd0, r_wc} * {12'd0, k_sw};
                    r_b <= {16'd0, r_hc} * {12'd0, k_sh};
                    st <= S_SEL;
                end
                S_SEL: begin
                    r_wide <= (a3 >= b4);
                    if (k_nat) begin                             // native: 1:1 (at least 2, the model's clamp: between
                        r_ow <= (r_wc < 12'd2) ? 13'd2 : {1'b0, r_wc};    // streams the picture is 0x0)
                        r_oh <= (r_hc < 12'd2) ? 13'd2 : {1'b0, r_hc}; r_clamp <= 1'b0;
                        st <= S_SNAP;
                    end else if (k_mode == 2'd3 && k_dw != 12'd0 && k_dh != 12'd0) begin   // Fill: is it wider than the display?
                        pm_p <= '0; pm_q <= '0; pm_b <= {12'd0, r_b}; pm_a <= {12'd0, r_a};
                        pm_mw <= k_dw; pm_mh <= k_dh; pm_cnt <= 4'd12;
                        st <= S_PM;
                    end else if (k_mode == 2'd2) begin           // Fit: is it wider than 16:9? (A''s products, 16 x 9)
                        pm_p <= '0; pm_q <= '0; pm_b <= {12'd0, r_b}; pm_a <= {12'd0, r_a};
                        pm_mw <= 12'd16; pm_mh <= 12'd9; pm_cnt <= 4'd12;
                        st <= S_PM;
                    end else if (k_mode == 2'd3) begin           // Fill without a display: the raster filled
                        r_ow <= 13'd720; r_oh <= rh; r_clamp <= 1'b0;
                        st <= S_SNAP;
                    end else begin
                        // round(n / d) = floor((2n + d) / 2d)
                        if ((k_mode == 2'd0) == (a3 >= b4)) begin    // oh = round(640 B / A) (768 at 576 lines)
                            dv_n <= {1'b0, (k_pal ? b768 : b640), 1'b0} + {12'd0, r_a};
                            dv_d <= {r_a, 1'b0};
                        end else begin                               // ow = round(540 A / B)
                            dv_n <= {1'b0, a540, 1'b0} + {12'd0, r_b};
                            dv_d <= {r_b, 1'b0};
                        end
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd40;
                        st <= S_DIV; st_ret <= S_Q1;
                    end
                end
                S_DIV: begin
                    // one restoring step a cycle
                    dv_rem <= dv_ge ? (dv_trial - {1'b0, dv_d}) : dv_trial;
                    dv_q <= {dv_q[38:0], dv_ge};
                    dv_n <= {dv_n[38:0], 1'b0};
                    dv_cnt <= dv_cnt - 6'd1;
                    if (dv_cnt == 6'd1) st <= st_ret;
                end
                S_PM: begin
                    // one step of each product: the multiplier's low bit, the multiplicand doubled
                    if (pm_mw[0]) pm_p <= pm_p + pm_b;
                    if (pm_mh[0]) pm_q <= pm_q + pm_a;
                    pm_b <= {pm_b[38:0], 1'b0}; pm_a <= {pm_a[38:0], 1'b0};
                    pm_mw <= {1'b0, pm_mw[11:1]}; pm_mh <= {1'b0, pm_mh[11:1]};
                    pm_cnt <= pm_cnt - 4'd1;
                    if (pm_cnt == 4'd1) st <= S_PWIDE;
                end
                S_PWIDE: begin
                    if (pm_q > pm_p) begin                       // A disp_h > B disp_w: A' (Fit: wider than 16:9)
                        r_lb <= (k_mode == 2'd3);
                        r_w16 <= 1'b1;
                        st <= S_PSH;
                    end else if (k_mode == 2'd2) begin           // Fit, not wider: ow = round(405 A / B)
                        dv_n <= {1'b0, a405, 1'b0} + {12'd0, r_b};
                        dv_d <= {r_b, 1'b0};
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd40;
                        st <= S_DIV; st_ret <= S_Q1;
                    end else begin                               // Fill, not wider: the raster filled
                        r_ow <= 13'd720; r_oh <= rh; r_clamp <= 1'b0;
                        st <= S_SNAP;
                    end
                end
                S_PSH: begin
                    // both down together until A disp_h fits 28 bits; then oh = round(rh P / Q)
                    if (pm_q[39:28] != 12'd0) begin
                        pm_p <= {1'b0, pm_p[39:1]}; pm_q <= {1'b0, pm_q[39:1]};
                    end else begin
                        dv_n <= {1'b0, p_rh, 1'b0} + {12'd0, pm_q[27:0]};
                        dv_d <= {pm_q[27:0], 1'b0};
                        dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd40;
                        st <= S_DIV; st_ret <= S_Q1;
                    end
                end
                S_Q1: begin
                    // the quotient: ow or oh, clamped to [2, 8191]; the other side is the raster's
                    if (k_mode == 2'd3 || (k_mode == 2'd2 && r_w16)) begin   // A' / Fit wider than 16:9: the letterbox's height
                        r_ow <= 13'd720;
                        r_oh <= (dv_q > 40'd8191) ? 13'd8191 : (dv_q < 40'd2) ? 13'd2 : dv_q[12:0];
                    end else if (k_mode == 2'd2) begin          // Fit, 16:9 or narrower: the pillarbox's width
                        r_oh <= rh;
                        r_ow <= (dv_q > 40'd8191) ? 13'd8191 : (dv_q < 40'd2) ? 13'd2 : dv_q[12:0];
                    end else if ((k_mode == 2'd0) == r_wide) begin
                        r_ow <= 13'd720;
                        r_oh <= (dv_q > 40'd8191) ? 13'd8191 : (dv_q < 40'd2) ? 13'd2 : dv_q[12:0];
                    end else begin
                        r_oh <= rh;
                        r_ow <= (dv_q > 40'd8191) ? 13'd8191 : (dv_q < 40'd2) ? 13'd2 : dv_q[12:0];
                    end
                    r_clamp <= (dv_q > 40'd8191);
                    st <= S_SNAP;
                end
                S_SNAP: begin
                    r_snap <= 1'b0;
                    if (!k_nat && k_mode != 2'd3 && (dw1000 <= wc35) && (dh1000 <= hc35)) begin
                        r_ow <= {1'b0, r_wc}; r_oh <= {1'b0, r_hc}; r_snap <= 1'b1;
                    end else if (r_lb && (dh1000 <= hc35) && ({1'b0, r_hc} <= rh)) begin
                        r_oh <= {1'b0, r_hc}; r_snap <= 1'b1;      // A': the vertical alone, 1:1
                    end
                    if (k_geom) begin
                        r_ow <= k_geom_w; r_oh <= k_geom_h;
                        r_geom_x <= k_geom_x; r_geom_y <= k_geom_y;
                        r_snap <= 1'b0;
                    end
                    st <= S_Q2;
                end
                S_Q2: begin
                    // sx = (Wc << 16) / ow, with the ow the snap settled
                    dv_n <= {12'd0, r_wc, 16'd0}; dv_d <= {16'd0, r_ow};
                    dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd40;
                    st <= S_DIV; st_ret <= S_Q3;
                end
                S_Q3: begin
                    // sx is in; sy = (Hc << 16) / oh
                    r_sx <= dv_q[27:0];
                    dv_n <= {12'd0, r_hc, 16'd0}; dv_d <= {16'd0, r_oh};
                    dv_rem <= '0; dv_q <= '0; dv_cnt <= 6'd40;
                    st <= S_DIV; st_ret <= S_PF;
                end
                S_PF: begin
                    // sy is in; the decimation: pow2floor of the step's integer part, capped (the
                    // dh >= 2 floor past 1,024 columns under Sharp only, §11b)
                    r_sy <= dv_q[27:0];
                    r_dhl2 <= (r_sx[27:16] >= 12'd8) ? 2'd3 : (r_sx[27:16] >= 12'd4) ? 2'd2 :
                              ((r_sx[27:16] >= 12'd2) || (k_w > 8'd64 && !k_nat && !k_area)) ? 2'd1 : 2'd0;   // (native: a 2,048-sample line, hd_raster)
                    if (k_at && k_w > 8'd40)
                        r_dvl2 <= (vstep_pub[28:16] >= 13'd2) ? 2'd1 : 2'd0;
                    else if (k_at || k_w > 8'd80)
                        r_dvl2 <= (vstep_pub[28:16] >= 13'd4) ? 2'd2 : (vstep_pub[28:16] >= 13'd2) ? 2'd1 : 2'd0;
                    else
                        r_dvl2 <= (vstep_pub[28:16] >= 13'd8) ? 2'd3 : (vstep_pub[28:16] >= 13'd4) ? 2'd2 :
                                  (vstep_pub[28:16] >= 13'd2) ? 2'd1 : 2'd0;
                    st <= S_PF2;
                end
                S_PF2: begin
                    // the pre-filters from the residual steps; vertically anti-twitter's (4, 4, 0)
                    r_hpf <= hc_w;
                    r_vpf <= k_at ? 3'd4 : vc_w;
                    st <= S_PUB;
                end
                S_PUB: begin
                    // publish the whole set in one cycle
                    ow <= r_ow; oh <= r_oh;
                    ox0 <= k_geom ? {{1{r_geom_x[12]}}, r_geom_x} : {ox_d[13], ox_d[13:1]};
                    oy0 <= k_geom ? {{1{r_geom_y[12]}}, r_geom_y} : {oy_d[13], oy_d[13:1]};
                    clip_en <= k_clip_en; clip_x <= k_clip_x; clip_y <= k_clip_y;
                    clip_w <= k_clip_w; clip_h <= k_clip_h;
                    sx <= r_sx; sy <= r_sy;
                    dh_l2 <= r_dhl2; dv_l2 <= r_dvl2;
                    hpf <= r_hpf;
                    // the fetch budget: two boxes -> one past it; anti-twitter keeps its two (its own dv
                    // caps, on the 480i line's double time)
                    vpf <= (r_vpf != 3'd0 && !fit2 && !k_at) ? 3'd0 : r_vpf;
                    wc <= r_wc; hc <= r_hc; lx <= r_lx; ty <= r_ty;
                    crop_bad <= r_bad; snap <= r_snap; clamp <= r_clamp; slide <= k_at; lb <= r_lb;
                    busy <= 1'b0;
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
