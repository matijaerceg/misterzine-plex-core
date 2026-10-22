// bench/h264/disp_fit_tb.sv -- h264/disp_fit.sv against tools/disp_fit_ref.py (P6 step 3,
// docs/analog.md §5). The model is written from the design text, not from the RTL.
//
// Every vector (+vec=FILE, one case a line: the inputs, then the model's outputs): drive the
// inputs, wait for the computation to start and end, compare with `!==`:
//   [size]  ow, oh, ox0, oy0          the output rectangle
//   [step]  sx, sy                    the Q.16 steps
//   [dec]   dh, dv                    the decimation factors
//   [flag]  crop_bad, snap, clamp
//   [slide] anti-twitter's sliding rows published with the set (P6 step 4: the `at` column)
//   [crop]  wc, hc, lx, ty            the cropped size and origin
//   [lb]    A' (mode 3, Fill: wider than the HDMI display -> letterboxed inside the raster;
//           docs/hdmi_raster.md §3a) published with the set -- and never under Fit (mode 2, issue #11:
//           the anamorphic 16:9 fit letterboxes inside the analog raster, which stays 4:3)
//   [pf]    (docs/analog.md §11b) the Area pre-filter's codes hpf / vpf (the last three columns: area
//           in -- 1 the core's, 0 the Sharp control -- hpf, vpf out), the budget's fallback included
//   [seq]   a computation ends within 400 cycles; the outputs do not move while one runs
// $fatal on the first failure; the PASS marker is positive.
`timescale 1ns/1ps
module disp_fit_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 0, rst_n = 0;
always #18.5 clk = ~clk;

reg  [7:0]  w, hf;
reg  [40:0] crop;
reg  [15:0] sw, sh;
reg  [1:0]  mode;
reg         il, at, pal;
reg  [11:0] dw, dhh, nw, nh;
reg         nat;
reg  [1:0]  flt;
reg         geometry_en;
reg  [12:0] geometry_x, geometry_y, geometry_w, geometry_h;
reg         geometry_clip_en;
reg  [11:0] geometry_clip_x, geometry_clip_y, geometry_clip_w, geometry_clip_h;
wire        clip_en;
wire [11:0] clip_x, clip_y, clip_w, clip_h;
wire [2:0]  hpf, vpf;
wire [12:0] ow, oh;
wire [13:0] ox0, oy0;
wire [27:0] sx, sy;
wire [1:0]  dh_l2, dv_l2;
wire [11:0] wc, hc, lx, ty;
wire        crop_bad, snap, clamp, slide, lb, busy;
disp_fit dut (.clk(clk), .rst_n(rst_n), .w_mbs(w), .hf_mbs(hf), .crop(crop), .sar_w(sw), .sar_h(sh),
              .mode(mode), .disp_w(dw), .disp_h(dhh), .nat(nat), .nat_w(nw), .nat_h(nh), .il(il), .at(at), .pal(pal), .area(flt[0]),
              .geometry_en(geometry_en), .geometry_x(geometry_x), .geometry_y(geometry_y), .geometry_w(geometry_w), .geometry_h(geometry_h),
              .geometry_clip_en(geometry_clip_en), .geometry_clip_x(geometry_clip_x), .geometry_clip_y(geometry_clip_y),
              .geometry_clip_w(geometry_clip_w), .geometry_clip_h(geometry_clip_h),
              .ow(ow), .oh(oh), .ox0(ox0), .oy0(oy0), .sx(sx), .sy(sy),
              .clip_en(clip_en), .clip_x(clip_x), .clip_y(clip_y), .clip_w(clip_w), .clip_h(clip_h),
              .dh_l2(dh_l2), .dv_l2(dv_l2), .wc(wc), .hc(hc), .lx(lx), .ty(ty),
              .crop_bad(crop_bad), .snap(snap), .clamp(clamp), .slide(slide), .lb(lb), .hpf(hpf), .vpf(vpf), .busy(busy));

integer fd, r, n = 0, t;
reg [11:0] expected_clip_x = 12'd20;
// [seq]: the published outputs never move while a computation runs (the reader may sample
// them at any cycle)
reg [221:0] pub_q;
wire [221:0] pub = {ow, oh, ox0, oy0, clip_en, clip_x, clip_y, clip_w, clip_h,
                    sx, sy, dh_l2, dv_l2, wc, hc, lx, ty, crop_bad, snap, clamp, slide, lb, hpf, vpf};
always @(posedge clk) begin
    if (rst_n && pub_q !== {222{1'bx}} && busy === 1'b1 && pub !== pub_q) `FAIL("seq", $sformatf("the published fit changed while a computation ran (vector %0d): %h -> %h", n, pub_q, pub))
    if (rst_n && pub_q !== {222{1'bx}} && geometry_en && !nat && pub !== pub_q && !busy &&
        {ow, oh, $signed(ox0), $signed(oy0), clip_en, clip_x, clip_y, clip_w, clip_h} !==
        {13'd600, 13'd400, 14'sd14, 14'sd16, 1'b1, expected_clip_x, 12'd30, 12'd600, 12'd400})
        `FAIL("geometry-publish", "the clip and calibrated rectangle did not publish as one set")
    pub_q <= pub;
end

integer vw, vh, vcu, vl, vr, vt, vb, vsw, vsh, vmode, vil, vat, vpal, vdw, vdh, vnat, vnw, vnh;
integer eow, eoh, eox, eoy, esx, esy, edh, edv, efl, ewc, ehc, elx, ety, vflt, ehpf, evpf;
integer n_hpf = 0, n_varea = 0, n_vsm = 0, n_fall = 0;
integer n_bad = 0, n_snap = 0, n_clamp = 0, n_dec = 0, n_slide = 0, n_capped = 0, n_pal = 0;
integer n_fill = 0, n_lb = 0, n_lb_snap = 0, n_lb_pal = 0, n_nat = 0, n_nat_off = 0;
integer n_fit_lbx = 0, n_fit_pbx = 0, n_fit_full = 0, n_fit_snap = 0;   // (issue #11) Fit: letterboxed, pillarboxed, filled, snapped
string vec;
reg [144:0] prev;
initial begin
    if (!$value$plusargs("vec=%s", vec)) `FAIL("harness", "+vec= missing")
    fd = $fopen(vec, "r");
    if (fd == 0) `FAIL("harness", {"cannot open ", vec})
    w = 8'd45; hf = 8'd30; crop = '0; sw = 16'd1; sh = 16'd1; mode = 2'd0; il = 1'b0; at = 1'b0; pal = 1'b0;
    dw = 12'd0; dhh = 12'd0; nat = 1'b0; nw = 12'd720; nh = 12'd480; flt = 2'd0;
    geometry_en = 1'b0; geometry_x = '0; geometry_y = '0; geometry_w = '0; geometry_h = '0;
    geometry_clip_en = 1'b0; geometry_clip_x = '0; geometry_clip_y = '0; geometry_clip_w = '0; geometry_clip_h = '0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (400) @(posedge clk);
    forever begin
        r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    vw, vh, vcu, vl, vr, vt, vb, vsw, vsh, vmode, vil, vat, vpal, vdw, vdh, vnat, vnw, vnh,
                    eow, eoh, eox, eoy, esx, esy, edh, edv, efl, ewc, ehc, elx, ety, vflt, ehpf, evpf);
        if (r != 34) break;
        @(negedge clk);
        prev = {w, hf, crop, sw, sh, mode, il, at, pal, dw, dhh, nat, nw, nh, flt};
        w = vw; hf = vh; crop = {vcu[0], vl[9:0], vr[9:0], vt[9:0], vb[9:0]}; sw = vsw; sh = vsh;
        mode = vmode; il = vil; at = vat; pal = vpal; dw = vdw; dhh = vdh; nat = vnat; nw = vnw; nh = vnh; flt = vflt;
        // a changed input set starts a computation within two cycles; it ends within 400
        // (an unchanged set starts none: the published fit is already its own)
        if ({w, hf, crop, sw, sh, mode, il, at, pal, dw, dhh, nat, nw, nh, flt} !== prev) begin
            t = 0;
            while (busy !== 1'b1 && t < 3) begin @(posedge clk); #1; t = t + 1; end
            if (busy !== 1'b1) `FAIL("seq", $sformatf("vector %0d: no computation started", n))
        end
        t = 0;
        while (busy === 1'b1 && t < 400) begin @(posedge clk); #1; t = t + 1; end
        if (busy !== 1'b0) `FAIL("seq", $sformatf("vector %0d: still busy after 400 cycles", n))
        // A' first: lb decides the snap rule (its vertical-only snap), so an lb defect moves the flags and
        // is its own; then the flags: a snap / crop / clamp defect moves the size too, and is theirs
        if (lb !== efl[4])
            `FAIL("lb", $sformatf("vector %0d (%0dx%0d MBs sar %0d:%0d mode %0d display %0dx%0d): lb %b, want %b", n,
                  vw, vh, vsw, vsh, vmode, vdw, vdh, lb, efl[4]))
        if ({crop_bad, snap, clamp} !== {efl[0], efl[1], efl[2]})
            `FAIL("flag", $sformatf("vector %0d: bad %b snap %b clamp %b, want %b %b %b", n,
                  crop_bad, snap, clamp, efl[0], efl[1], efl[2]))
        if (slide !== efl[3])
            `FAIL("slide", $sformatf("vector %0d (at %0d): slide %b, want %b", n, vat, slide, efl[3]))
        if ({ow, oh, ox0, oy0} !== {eow[12:0], eoh[12:0], eox[13:0], eoy[13:0]})
            `FAIL("size", $sformatf("vector %0d (%0dx%0d MBs crop %0d,%0d,%0d,%0d/%0d sar %0d:%0d mode %0d il %0d pal %0d): %0dx%0d at (%0d, %0d), want %0dx%0d at (%0d, %0d)",
                  n, vw, vh, vl, vr, vt, vb, vcu, vsw, vsh, vmode, vil, vpal, ow, oh, $signed(ox0), $signed(oy0),
                  eow, eoh, $signed(eox[13:0]), $signed(eoy[13:0])))
        if ({wc, hc, lx, ty} !== {ewc[11:0], ehc[11:0], elx[11:0], ety[11:0]})
            `FAIL("crop", $sformatf("vector %0d: cropped %0dx%0d from (%0d, %0d), want %0dx%0d from (%0d, %0d)",
                  n, wc, hc, lx, ty, ewc, ehc, elx, ety))
        if ({sx, sy} !== {esx[27:0], esy[27:0]})
            `FAIL("step", $sformatf("vector %0d: sx %h sy %h, want %h %h", n, sx, sy, esx, esy))
        if ((32'd1 << dh_l2) !== edh || (32'd1 << dv_l2) !== edv)
            `FAIL("dec", $sformatf("vector %0d (%0dx%0d MBs il %0d at %0d): dh %0d dv %0d, want %0d %0d", n, vw, vh, vil, vat,
                  32'd1 << dh_l2, 32'd1 << dv_l2, edh, edv))
        if ({hpf, vpf} !== {ehpf[2:0], evpf[2:0]})
            `FAIL("pf", $sformatf("vector %0d (%0dx%0d MBs flt %0d il %0d at %0d, dh %0d dv %0d): hpf %0d vpf %0d, want %0d %0d", n,
                  vw, vh, vflt, vil, vat, edh, edv, hpf, vpf, ehpf, evpf))
        n = n + 1;
        if (ehpf != 0) n_hpf = n_hpf + 1;
        if (evpf >= 1 && evpf <= 3) n_varea = n_varea + 1;
        if (vflt == 1 && !vat && evpf == 0 && edv > 1 && esy[27:16] >= 2 * edv) n_fall = n_fall + 1;   // r >= 2 past the dv cap, or the budget
        if (efl[0]) n_bad = n_bad + 1;
        if (efl[1]) n_snap = n_snap + 1;
        if (efl[2]) n_clamp = n_clamp + 1;
        if (edh > 1 || edv > 1) n_dec = n_dec + 1;
        if (efl[3]) n_slide = n_slide + 1;
        if (vpal) n_pal = n_pal + 1;
        if (vmode == 3) n_fill = n_fill + 1;
        if (vmode == 2 && !vnat) begin
            if (efl[1]) n_fit_snap = n_fit_snap + 1;
            else if (eow == 720 && eoh == (vpal ? 576 : 480)) n_fit_full = n_fit_full + 1;
            else if (eow == 720) n_fit_lbx = n_fit_lbx + 1;
            else n_fit_pbx = n_fit_pbx + 1;
        end
        if (vnat) begin n_nat = n_nat + 1; if (eox != 0 || eoy != 0) n_nat_off = n_nat_off + 1; end
        if (efl[4]) n_lb = n_lb + 1;
        if (efl[4] && efl[1]) n_lb_snap = n_lb_snap + 1;
        if (efl[4] && vpal) n_lb_pal = n_lb_pal + 1;
        // anti-twitter's fetch cap bound (the step's integer part past the capped dv)
        if (efl[3] && ((vw > 40 && esy[27:16] >= 4) || esy[27:16] >= 8)) n_capped = n_capped + 1;
    end
    // (1.2) a calibrated rectangle controls placement and size while the source steps are
    // recomputed against that size. Native output retains the core's 1:1 geometry.
    @(negedge clk);
    w = 8'd45; hf = 8'd30; crop = '0; sw = 16'd1; sh = 16'd1; mode = 2'd0;
    il = 1'b0; at = 1'b0; pal = 1'b0; nat = 1'b0;
    geometry_en = 1'b1; geometry_x = 13'd14; geometry_y = 13'd16;
    geometry_w = 13'd600; geometry_h = 13'd400;
    geometry_clip_en = 1'b1; geometry_clip_x = 12'd20; geometry_clip_y = 12'd30;
    geometry_clip_w = 12'd600; geometry_clip_h = 12'd400;
    wait (busy === 1'b1);
    @(negedge clk); geometry_clip_x = 12'd22; // a later request arrives during the active calculation
    wait (busy === 1'b0); #1;
    if ({ow, oh, $signed(ox0), $signed(oy0), clip_en, clip_x, clip_y, clip_w, clip_h} !==
        {13'd600, 13'd400, 14'sd14, 14'sd16, 1'b1, 12'd20, 12'd30, 12'd600, 12'd400})
        `FAIL("geometry-publish", "the first fit did not keep its matching clip while a later request arrived")
    wait (busy === 1'b1);
    expected_clip_x = 12'd22;
    wait (busy === 1'b0); #1;
    if ({ow, oh, $signed(ox0), $signed(oy0)} !== {13'd600, 13'd400, 14'sd14, 14'sd16})
        `FAIL("geometry", $sformatf("calibrated rectangle %0dx%0d at (%0d,%0d)", ow, oh, $signed(ox0), $signed(oy0)))
    if ({sx, sy} !== {28'd78643, 28'd78643})
        `FAIL("geometry", $sformatf("source steps not recomputed for calibrated size: %0d %0d", sx, sy))
    if ({clip_en, clip_x, clip_y, clip_w, clip_h} !== {1'b1, 12'd22, 12'd30, 12'd600, 12'd400})
        `FAIL("geometry", "clip viewport was not published with the calibrated rectangle")
    // coverage: the vectors reach every flag and the decimation (a bench on a vector file
    // without them scores nothing)
    if (n < 2000 || n_bad < 10 || n_snap < 5 || n_clamp < 10 || n_dec < 100 || n_slide < 500 || n_capped < 5 || n_pal < 1000 ||
        n_fill < 1000 || n_lb < 200 || n_lb_snap < 5 || n_lb_pal < 50 || n_nat < 100 || n_nat_off < 50 ||
        n_hpf < 1000 || n_varea < 500 || n_fit_lbx < 200 || n_fit_pbx < 200 || n_fit_full < 20 || n_fit_snap < 5)
        `FAIL("harness", $sformatf("coverage: %0d vectors, %0d bad crops, %0d snaps, %0d clamps, %0d decimated, %0d anti-twitter (%0d capped), %0d on 576 lines, %0d Fill (%0d A', %0d snapped, %0d on 576); Fit %0d letterboxed, %0d pillarboxed, %0d filled, %0d snapped",
              n, n_bad, n_snap, n_clamp, n_dec, n_slide, n_capped, n_pal, n_fill, n_lb, n_lb_snap, n_lb_pal, n_fit_lbx, n_fit_pbx, n_fit_full, n_fit_snap))
    $display("disp_fit_tb: %0d vectors identical to the model (%0d bad crops, %0d snaps, %0d clamps, %0d decimated, %0d anti-twitter, %0d capped, %0d on 576 lines, %0d Fill: %0d A', %0d snapped; Fit: %0d letterboxed, %0d pillarboxed, %0d filled, %0d snapped; %0d native, %0d centred off the origin; pre-filters: %0d horizontal, %0d vertical, %0d vertical capped)",
             n, n_bad, n_snap, n_clamp, n_dec, n_slide, n_capped, n_pal, n_fill, n_lb, n_lb_snap, n_fit_lbx, n_fit_pbx, n_fit_full, n_fit_snap, n_nat, n_nat_off, n_hpf, n_varea, n_fall);
    $display("PASS: disp_fit_tb");
    $finish;
end
endmodule
