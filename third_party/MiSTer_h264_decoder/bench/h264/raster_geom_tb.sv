// bench/h264/raster_geom_tb.sv -- h264/raster_geom.sv against tools/raster_geom_ref.py (the native
// raster's geometry, docs/hdmi_raster.md §3b / §4). The model is written from the design text.
//
// Every vector (+vec=FILE: the inputs, then the model's outputs): drive, wait for the computation,
// compare with `!==`:
//   [mode]  mode (fitted / native / fell back) and disp (display-shaped)
//   [size]  rw, rh
//   [frame] l, nt, last -- and the frame they describe is exactly F dots, L - Rw >= 20, the active
//           lines end by Ae (checked here from the published values, independently of the model)
//   [seq]   a computation ends within 600 cycles; the outputs never move while one runs; with
//           `en` low nothing starts and nothing moves (the hold between streams)
// $fatal on the first failure; the PASS marker is positive.
`timescale 1ns/1ps
module raster_geom_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 0, rst_n = 0;
always #18.5 clk = ~clk;

reg         en, req;
reg  [11:0] wc, hc, dw, dhh;
reg  [15:0] sw, sh;
reg  [7:0]  wm;
reg  [1:0]  std;
wire [1:0]  mode;
wire [11:0] rw, rh, l, nt, last;
wire        disp, busy;
raster_geom dut (.clk(clk), .rst_n(rst_n), .en(en), .req(req), .wc(wc), .hc(hc), .sar_w(sw), .sar_h(sh),
                 .w_mbs(wm), .dw(dw), .dh(dhh), .std(std), .mode(mode), .rw(rw), .rh(rh), .disp(disp),
                 .l(l), .nt(nt), .last(last), .busy(busy));

reg [64:0] pub_q;
wire [64:0] pub = {mode, rw, rh, disp, l, nt, last};
always @(posedge clk) begin
    if (rst_n && pub_q !== {65{1'bx}} && busy === 1'b1 && pub !== pub_q)
        `FAIL("seq", "the published geometry changed while a computation ran")
    if (rst_n && en === 1'b0 && (busy === 1'b1 && pub_q !== {65{1'bx}} && dut.st == 0))
        `FAIL("seq", "a computation started with en low")
    pub_q <= pub;
end

integer fd, r, n = 0, t;
integer vwc, vhc, vsw, vsh, vwm, vdw, vdh, vstd, vreq, emode, erw, erh, edisp, el, ent, elast;
integer n_nat = 0, n_disp = 0, n_pic = 0, n_fell = 0, n_short = 0, n_cap = 0, n_pal = 0;
integer f_dots, f_ae;
string vec;
reg [64:0] held;
initial begin
    if (!$value$plusargs("vec=%s", vec)) `FAIL("harness", "+vec= missing")
    fd = $fopen(vec, "r");
    if (fd == 0) `FAIL("harness", {"cannot open ", vec})
    en = 1'b1; req = 1'b0; wc = 12'd720; hc = 12'd480; sw = 16'd1; sh = 16'd1; wm = 8'd45; dw = 12'd1920; dhh = 12'd1080; std = 2'd0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (700) @(posedge clk);
    begin : vector_loop
    forever begin
        r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    vwc, vhc, vsw, vsh, vwm, vdw, vdh, vstd, vreq, emode, erw, erh, edisp, el, ent, elast);
        if (r != 16) disable vector_loop;
        @(negedge clk);
        wc = vwc; hc = vhc; sw = vsw; sh = vsh; wm = vwm; dw = vdw; dhh = vdh; std = vstd; req = vreq;
        t = 0;
        while (busy !== 1'b1 && t < 3) begin @(posedge clk); #1; t = t + 1; end
        t = 0;
        while (busy === 1'b1 && t < 600) begin @(posedge clk); #1; t = t + 1; end
        if (busy !== 1'b0) `FAIL("seq", $sformatf("vector %0d: still busy after 600 cycles", n))
        if (mode !== emode[1:0] || disp !== edisp[0])
            `FAIL("mode", $sformatf("vector %0d (%0dx%0d sar %0d:%0d W %0d display %0dx%0d std %0d req %0d): mode %0d disp %b, want %0d %0d",
                  n, vwc, vhc, vsw, vsh, vwm, vdw, vdh, vstd, vreq, mode, disp, emode, edisp))
        if ({rw, rh} !== {erw[11:0], erh[11:0]})
            `FAIL("size", $sformatf("vector %0d (%0dx%0d sar %0d:%0d display %0dx%0d std %0d): %0dx%0d, want %0dx%0d",
                  n, vwc, vhc, vsw, vsh, vdw, vdh, vstd, rw, rh, erw, erh))
        if ({l, nt, last} !== {el[11:0], ent[11:0], elast[11:0]})
            `FAIL("frame", $sformatf("vector %0d: L %0d NT %0d last %0d, want %0d %0d %0d", n, l, nt, last, el, ent, elast))
        if (mode == 2'd1) begin
            // the frame, from the published values alone: exactly F dots, the blank wide enough,
            // the active lines ending by disp_ctl's skip
            f_dots = (nt - 1) * l + last;
            f_ae = (vstd == 2) ? 1529280 : 1261260;   // (hd_raster) 81 MHz dots: 3 Ae
            if (f_dots != ((vstd == 2) ? 1620000 : (vstd == 1) ? 1350000 : 1351350) || l < rw + 20 || rh * l > f_ae ||
                nt < rh + 6 || last > 4095)
                `FAIL("frame", $sformatf("vector %0d: %0dx%0d, L %0d NT %0d last %0d = %0d dots", n, rw, rh, l, nt, last, f_dots))
            n_nat = n_nat + 1;
            if (disp) n_disp = n_disp + 1; else n_pic = n_pic + 1;
            if (last < l) n_short = n_short + 1;
            if (l == 12'd4000) n_cap = n_cap + 1;
            if (vstd == 2) n_pal = n_pal + 1;
        end
        if (mode == 2'd2) n_fell = n_fell + 1;
        n = n + 1;
    end
    end // vector_loop: EOF exits the whole loop, not just its current iteration
    // the hold: with en low a new input set starts nothing and moves nothing (between streams)
    @(negedge clk);
    held = pub; en = 1'b0; wc = 12'd100; hc = 12'd100; req = 1'b1; dw = 12'd1920; dhh = 12'd1080; std = 2'd0; wm = 8'd7;
    repeat (800) @(posedge clk);
    #1 if (busy !== 1'b0 || pub !== held) `FAIL("seq", "en low: the geometry moved (it must hold between streams)")
    en = 1'b1;
    t = 0;
    while (busy !== 1'b1 && t < 3) begin @(posedge clk); #1; t = t + 1; end
    if (busy !== 1'b1) `FAIL("seq", "en back high: no computation started")
    if (n < 1000 || n_disp < 100 || n_pic < 50 || n_fell < 50 || n_short < 50 || n_cap < 5 || n_pal < 50)
        `FAIL("harness", $sformatf("coverage: %0d vectors, %0d native (%0d display-shaped, %0d picture-sized, %0d with a short last line, %0d at the 4,000 cap, %0d at 50 Hz), %0d fell back",
              n, n_nat, n_disp, n_pic, n_short, n_cap, n_pal, n_fell))
    $display("raster_geom_tb: %0d vectors identical to the model (%0d native: %0d display-shaped, %0d picture-sized, %0d short last lines, %0d capped, %0d at 50 Hz; %0d fell back)",
             n, n_nat, n_disp, n_pic, n_short, n_cap, n_pal, n_fell);
    $display("PASS: raster_geom_tb");
    $finish;
end
endmodule
