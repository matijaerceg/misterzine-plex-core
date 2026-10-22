// bench/h264/disp_reader_tb.sv -- h264/disp_reader.sv, fed by h264/disp_fit.sv, on the real
// raster (h264/sync_gen.sv) and a store in bench/h264/ddr_model.sv holding a random picture:
// every active dot of the frame after the first compared with tools/disp_golden.py's
// expected raster ({de, R, G, B}: the BT.601 conversion of the kernel's or the fit's output,
// de 0 and black outside the picture's rectangle), including LAT 9 against the raster (5 before hd_raster).
// The raster side on clk_vid (81 MHz) and its dot enable, one clock in three (hd_raster S3):
// every comparison is made on a dot. Plusargs (run_disp_reader.sh sets them per arm):
//   +ce1           every clock a dot (the native raster's 81 MHz dot)
//   +arm=NAME      the arm a failure is reported under (default rgb)
//   +want=FILE     the expected raster (default the 720x480 frame's)
//   +store=FILE +w=N +hf=N   the store and its coded size in macroblocks (default the 720x480 one)
//   +cuy4 +cl=N +cr=N +ct=N +cb=N   its crop;  +sarw=N +sarh=N  its SAR (default 1:1)
//   +fmode=N       the fit's mode (0 Letterbox, 1 Crop, 2 Fit, 3 Fill; default 3 -- with no display, the
//                  raster filled: 720x480 is then the identity on both rasters. Fit was that before
//                  issue #11; it is now the anamorphic 16:9 fit)
//   +field         the store holds fields (pic_field)   +single  one field (pic_single)
//   +mode=N        deint_mode (0 Weave, 1 Bob, 2 Blend)  +parity=N  pic_parity
//   +colour=N      (0.16) pic_colour, the picture's colour code (default 1, BT.601 limited)
//   +colswap=N     ... changed to N on line 100 of the scored frame: the frame keeps its code
//   +il            the 480i raster (P6): two fields scored, every pixel on both of its dots
//   +at            anti-twitter (P6 step 4): disp_fit's `at`, the reader's sliding rows
//   +flt=N         (docs/analog.md §11b) the Downscale Filter: disp_fit's flt (0 Sharp, 1 Area, 2 Smooth)
//   +pal           the 50 Hz raster (P6 step 6): 720x576, the raster std 2, the fit and reader on 576 lines
//   +nat +nw=N +nh=N +nl=N +nnt=N +nlast=N   (hdmi_raster stage 2) the native raster: sync_gen's
//                  geometry (raster_geom's) and disp_fit's native mode -- the picture 1:1 on it
// Arms: [rgb] frame, Weave; [field] pair, Weave; [pass] frame in Bob / Blend (untouched);
//   [blend] pair, Blend; [bob] pair, Bob, either parity; [single] one field in Weave /
//   Blend (bobbed on its own parity); [il] 480i; [fit] a fitted picture (P6 step 3);
//   [count] a whole frame of 720 x 480 dots scored; [late] no line's rows fetched late;
//   [colour] (0.16) a frame under each colour code, and the code latched per refresh.
// PASS marker: "PASS: disp_reader_tb".
`timescale 1ns/1ps
module disp_reader_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
localparam [28:0] BASE = 29'h0600_0000;
reg clk = 0, mclk = 0;
always #6.173 clk = ~clk;        // clk_vid, 81 MHz (hd_raster): the dot is `ce`, one clock in three (27 MHz)
always #5.556 mclk = ~mclk;      // 90 MHz
reg  [1:0] cph = 2'd0;           // +ce1: every clock a dot (the native raster's 81 MHz dot, hd_raster stage B)
reg        ce1 = 1'b0;
reg        test_de = 1'b0;
always @(posedge clk) cph <= (cph == 2'd2) ? 2'd0 : cph + 2'd1;
wire       tick = ce1 | (cph == 2'd2);
wire       ce;               // sync_gen's dot: the tick, or every clock on the native raster (hd_raster stage B)
reg rst_n = 0;
wire [11:0] h_pos, v_pos; wire pixel_en, hs, vs, hb, vb, ft, fld;
reg il = 1'b0;   // +il: the 480i raster (P6)
reg at = 1'b0;   // +at: anti-twitter (P6 step 4)
reg [1:0] std = 2'd0;   // the raster standard (P6 steps 5 / 6): +pal sets 2 (50 Hz, 576 lines)
reg pal = 1'b0;
localparam RH_MAX = 720;        // (hd_raster) 1280x720 native
localparam RW_MAX = 2048;        // the native raster's widest (hd_raster stage B; 1,024 at stage 2)
reg        nat = 1'b0;           // +nat: the native raster
reg [11:0] nw = 12'd720, nh = 12'd480, nl = 12'd0, nnt = 12'd0, nlast = 12'd0;
integer    rwid;                 // the raster's width: 720, or the native raster's
wire [11:0] sg_lines, sg_last;   // sync_gen's current frame: the reader's wrap (hdmi_raster stage 2)
sync_gen sg (.clk(clk), .clk_en(tick), .dot(ce), .rst_n(rst_n), .interlaced(il), .std(std), .h_pos(h_pos), .v_pos(v_pos),
             .pixel_en(pixel_en), .h_sync(hs), .v_sync(vs), .h_blank(hb), .v_blank(vb), .frame_tick(ft), .field(fld), .nat(nat), .g_w(nw), .g_h(nh), .g_l(nl), .g_nt(nnt), .g_last(nlast), .lines(sg_lines), .last_line(sg_last));
wire [7:0] r, g, b; wire de_out;
wire [28:0] ddr_address; wire [7:0] ddr_burstcount; wire ddr_read, ddr_waitrequest, ddr_readdatavalid;
wire [63:0] ddr_readdata; int unwritten;
reg field = 1'b0, single = 1'b0, parity = 1'b0;
reg [1:0] mode = 2'd0;
reg [2:0] colour = 3'd1;          // +colour=N (0.16): the picture's colour code
reg [5:0] siting = 6'd0;          // +siting=N (docs/chroma.md): the chroma siting {bottom, top} (9 t: both type t)
reg [2:0] colswap = 3'd0;         // +colswap=N: the code changed to N in the middle of a scored frame
reg [7:0] w_mbs = 8'd45, hf_mbs = 8'd30;
reg [40:0] crop = '0;
reg [15:0] sarw = 16'd1, sarh = 16'd1;
reg clip_enable = 1'b0;
reg [11:0] clip_x = '0, clip_y = '0, clip_w = '0, clip_h = '0;
reg [1:0]  fmode = 2'd3;
reg [1:0]  flt = 2'd0;
wire [2:0] f_hpf, f_vpf;
wire [12:0] f_ow, f_oh; wire [13:0] f_ox0, f_oy0; wire [27:0] f_sx, f_sy; wire [1:0] f_dh, f_dv;
wire [11:0] f_wc, f_hc, f_lx, f_ty; wire f_busy, f_slide; wire [15:0] fetch_late;
wire f_clip_en; wire [11:0] f_clip_x, f_clip_y, f_clip_w, f_clip_h;
disp_fit fit (.clk(clk), .rst_n(rst_n), .w_mbs(w_mbs), .hf_mbs(hf_mbs), .crop(crop), .sar_w(sarw), .sar_h(sarh),
    .mode(fmode), .disp_w(12'd0), .disp_h(12'd0), .nat(nat), .nat_w(nw), .nat_h(nh), .il(il), .at(at), .pal(pal), .area(flt[0]),
    .geometry_en(1'b0), .geometry_x(13'd0), .geometry_y(13'd0), .geometry_w(13'd0), .geometry_h(13'd0),
    .geometry_clip_en(1'b0), .geometry_clip_x(12'd0), .geometry_clip_y(12'd0), .geometry_clip_w(12'd0), .geometry_clip_h(12'd0),
    .ow(f_ow), .oh(f_oh), .ox0(f_ox0), .oy0(f_oy0), .clip_en(f_clip_en), .clip_x(f_clip_x), .clip_y(f_clip_y), .clip_w(f_clip_w), .clip_h(f_clip_h), .sx(f_sx), .sy(f_sy),
    .dh_l2(f_dh), .dv_l2(f_dv), .wc(f_wc), .hc(f_hc), .lx(f_lx), .ty(f_ty), .crop_bad(), .snap(), .clamp(), .slide(f_slide), .lb(), .hpf(f_hpf), .vpf(f_vpf), .busy(f_busy));
disp_reader #(.DPB_BASE(BASE)) dut ( .lines(sg_lines), .last_line(sg_last),.clk(clk), .ce(ce), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(pixel_en | test_de), .il(il), .pal(pal),
    .pic_valid(1'b1), .pic_store(5'd17), .pic_field(field), .pic_w_mbs(w_mbs), .pic_hf_mbs(hf_mbs),
    .pic_parity(parity), .pic_single(single), .deint_mode(mode), .pic_colour(colour), .pic_siting(siting),
    .fit_ow(f_ow), .fit_oh(f_oh), .fit_ox0(f_ox0), .fit_oy0(f_oy0), .fit_sx(f_sx), .fit_sy(f_sy),
    .fit_dh_l2(f_dh), .fit_dv_l2(f_dv), .fit_lx(f_lx), .fit_ty(f_ty), .fit_wc(f_wc), .fit_hc(f_hc),
    .fit_hpf(f_hpf), .fit_vpf(f_vpf), .clip_enable(clip_enable), .clip_x(clip_x), .clip_y(clip_y), .clip_w(clip_w), .clip_h(clip_h),
    .fetch_late(fetch_late), .fetch_changes(), .r(r), .g(g), .b(b), .de_out(de_out),
    .mclk(mclk), .mrst_n(rst_n), .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read),
    .ddr_waitrequest(ddr_waitrequest), .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));
ddr_model #(.BASE(BASE + {5'd16, 18'd0}), .AW(22)) ddr (.clk(mclk), .rst_n(rst_n), .address(ddr_address), .burstcount(ddr_burstcount),
    .read(ddr_read), .write(1'b0), .writedata(64'd0), .byteenable(8'hFF), .waitrequest(ddr_waitrequest),
    .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));
reg [63:0] store [0:262143];               // (0.11) a 3,600-macroblock picture's samples: 172,800 words
reg [24:0] want [0:RW_MAX*RH_MAX-1];
integer n = 0, frames = 0, nwords, iv;
string arm, wfile, sfile, pfs;
reg [11:0] hq [0:8]; reg [11:0] vq [0:8]; reg dq [0:8];   // (hd_raster) LAT 9
initial begin
    if (!$value$plusargs("arm=%s", arm)) arm = "rgb";
    ce1    = $test$plusargs("ce1");
    if (!$value$plusargs("want=%s", wfile)) wfile = "bench/h264/fixtures/gen/disp_want_frame.hex";
    field  = $test$plusargs("field");
    il     = $test$plusargs("il");
    at     = $test$plusargs("at");
    pal    = $test$plusargs("pal");
    if (pal) std = 2'd2;
    single = $test$plusargs("single");
    if ($value$plusargs("mode=%d", iv)) mode = iv[1:0];
    if ($value$plusargs("parity=%d", iv)) parity = iv[0];
    if ($value$plusargs("colour=%d", iv)) colour = iv[2:0];
    if ($value$plusargs("siting=%d", iv)) siting = iv[5:0];   // (docs/chroma.md) {bottom, top} as 9 t for both
    if ($value$plusargs("colswap=%d", iv)) colswap = iv[2:0];
    if (!$value$plusargs("store=%s", sfile)) sfile = "bench/h264/fixtures/gen/disp_store.hex";
    if ($value$plusargs("w=%d", iv)) w_mbs = iv[7:0];
    if ($value$plusargs("hf=%d", iv)) hf_mbs = iv[7:0];
    crop[40] = $test$plusargs("cuy4");
    if ($value$plusargs("cl=%d", iv)) crop[39:30] = iv[9:0];
    if ($value$plusargs("cr=%d", iv)) crop[29:20] = iv[9:0];
    if ($value$plusargs("ct=%d", iv)) crop[19:10] = iv[9:0];
    if ($value$plusargs("cb=%d", iv)) crop[9:0]   = iv[9:0];
    if ($value$plusargs("sarw=%d", iv)) sarw = iv[15:0];
    if ($value$plusargs("sarh=%d", iv)) sarh = iv[15:0];
    if ($value$plusargs("fmode=%d", iv)) fmode = iv[1:0];
    if ($value$plusargs("flt=%d", iv)) flt = iv[1:0];
    nat = $test$plusargs("nat");
    if ($value$plusargs("nw=%d", iv)) nw = iv[11:0];
    if ($value$plusargs("nh=%d", iv)) nh = iv[11:0];
    if ($value$plusargs("nl=%d", iv)) nl = iv[11:0];
    if ($value$plusargs("nnt=%d", iv)) nnt = iv[11:0];
    if ($value$plusargs("nlast=%d", iv)) nlast = iv[11:0];
    rwid = nat ? int'(nw) : 720;
    $readmemh(sfile, store);
    $readmemh(wfile, want);
    nwords = w_mbs * hf_mbs * 48;                  // luma 32 W HF words, chroma 16 W HF
    // store 17: the fifth store bit; 2 MiB stores (store << 18). The model's 32 MB window starts at
    // store 16, so a reader that shifted by 17 (or wrapped a plane offset) reads outside it or zeros
    for (int i = 0; i < nwords; i++) ddr.poke(BASE + {5'd17, 18'd0} + i, store[i]);
    #100 rst_n = 1;
end
// the raster position LAT 9 dots ago (hd_raster: the read-out deepened for 81 MHz)
always @(posedge clk) if (ce) begin
    hq[0] <= h_pos; vq[0] <= v_pos; dq[0] <= pixel_en;
    for (int i = 1; i < 9; i++) begin hq[i] <= hq[i-1]; vq[i] <= vq[i-1]; dq[i] <= dq[i-1]; end
end
always @(posedge clk) if (rst_n && ce) begin
    if (ft) frames = frames + 1;
    // +colswap: the code changes on line 100 of the first scored frame -- latched per refresh, the
    // frame stays its old code's (the next refresh, not scored, takes the new one)
    if (colswap != 3'd0 && frames == 2 && v_pos == 12'd100 && h_pos == 12'd0) colour = colswap;
    // (at 480i frame_tick marks each FIELD: fields 2 and 3 are the two halves of a frame,
    // every pixel two dots)
    if ((frames == 2 || (il && frames == 3)) && dq[8]) begin
        integer idx;
        idx = vq[8] * rwid + (il ? hq[8] / 2 : hq[8]);
        if ({de_out, r, g, b} !== want[idx])
            `FAIL(arm, $sformatf("(%0d, %0d): de %b %h %h %h, want %h", hq[8], vq[8], de_out, r, g, b, want[idx]))
        n = n + 1;
    end
    if (frames == (il ? 4 : 3)) begin
        if (n !== (il ? 2 : 1) * rwid * (nat ? int'(nh) : (pal ? 576 : 480))) `FAIL("count", $sformatf("%0d dots scored", n))
        // every line's rows arrived before it began (the scored frames and the one before)
        if (fetch_late !== 16'd0) `FAIL("late", $sformatf("%0d lines began before their rows were fetched", fetch_late))
        // 1.2: the largest accepted signed start + width must be compared without 14-bit
        // signed overflow. Use a coordinate representable in both raster modes; interlace
        // halves h_pos before the rectangle comparison.
        force dut.r_ox0 = 14'sd100;
        force dut.r_ow = 13'd8190;
        force h_pos = il ? 12'd200 : 12'd100;
        #1;
        if (dut.in_x !== 1'b1) `FAIL("geometry-bound", $sformatf("valid large-width rectangle wrapped at its right edge (il %0d, h_pos %0d, x %0d, ox %0d, width %0d, end %0d)", il, h_pos, dut.x, $signed(dut.r_ox0), dut.r_ow, dut.rect_x_end))
        release dut.r_ox0;
        release dut.r_ow;
        // The reader captures viewport with fit controls on CE. Once active, its first
        // stage must admit an inside pixel and reject pixels just outside each edge.
        force dut.e_in = 1'b1;
        force dut.in_x = 1'b1;
        force h_pos = il ? 12'd100 : 12'd50;
        force v_pos = 12'd30;
        test_de = 1'b1;
        ce1 = 1'b1;
        clip_enable = 1'b1; clip_x = 12'd20; clip_y = 12'd30; clip_w = 12'd100; clip_h = 12'd60;
        repeat (3) @(posedge clk);
        #1;
        if (dut.s0_in !== 1'b1) `FAIL("geometry-clip", "an inside pixel was clipped after viewport capture")
        force h_pos = il ? 12'd38 : 12'd19;
        @(posedge clk); #1;
        if (dut.s0_in !== 1'b0) `FAIL("geometry-clip", "a pixel left of the clip viewport was admitted")
        release h_pos;
        force h_pos = il ? 12'd100 : 12'd50;
        force v_pos = 12'd29;
        @(posedge clk); #1;
        if (dut.s0_in !== 1'b0) `FAIL("geometry-clip", "a pixel above the clip viewport was admitted")
        release dut.e_in;
        release dut.in_x;
        release h_pos;
        release v_pos;
        pfs = "";
        if (f_hpf != 3'd0 || f_vpf != 3'd0) pfs = $sformatf(", pre-filters %0d / %0d (filter %0d)", f_hpf, f_vpf, flt);
        $display("disp_reader_tb: %0d dots identical (%0dx%0d, %0s, mode %0d, parity %0d%0s; fit %0dx%0d at (%0d, %0d), dh %0d dv %0d%0s%0s)",
                 n, w_mbs * 16, hf_mbs * 16, field ? "fields" : "frame", mode, parity, single ? ", single" : "",
                 f_ow, f_oh, $signed(f_ox0), $signed(f_oy0), 1 << f_dh, 1 << f_dv, f_slide ? ", anti-twitter" : "", pfs);
        $display("PASS: disp_reader_tb");
        $finish;
    end
end
endmodule
