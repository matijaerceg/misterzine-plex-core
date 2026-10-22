// bench/h264/sync_gen_nat_tb.sv -- MEASURES h264/sync_gen.sv's native raster (docs/hdmi_raster.md
// §4, stage 2) from its outputs, frame by frame.
//
// +geo=FILE: one segment a line, "nat w h l nt last" (hex) -- tools/raster_geom_ref.py's geometries
// for pictures at this run's +std (fitted segments, nat 0, between them). Each segment is presented
// at a RANDOM dot in the middle of a frame and held for three frames. Every whole frame is scored
// against the segment presented at its first dot:
//   [dots]   the frame is exactly 3F CLOCKS of clk_vid (1,351,350 / 1,350,000 / 1,620,000: three times
//            the standard's 27 MHz frame, written here) whether fitted (F dots on the tick) or native
//            (3F dots, one a clock: hd_raster stage B) -- across every switch, both ways
//   [area]   the DE footprint: g_h lines of g_w dots, each run from h_pos 0 (fitted: 720 x 480 / 576)
//   [blank]  DE low at least 20 dots between two lines (ascal needs 17)
//   [hs]     one HS rising edge a line, never during DE
//   [vs]     VS on exactly the 3 lines [g_h + 2, g_h + 5) (native)
//   [report] lines / last_line equal the frame's active lines and last line index
//   [switch] the geometry presented mid-frame never changes the frame being scanned (a frame scored
//            against the segment at its first dot covers this: a mid-frame take breaks [dots]/[area])
// $fatal on the first failure; the PASS marker is positive.
`timescale 1ns/1ps
module sync_gen_nat_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 0, rst_n = 0;
always #6.173 clk = ~clk;      // clk_vid 81 MHz (hd_raster): the 27 MHz tick one clock in three
reg  [1:0] cph = 2'd0;
always @(posedge clk) cph <= (cph == 2'd2) ? 2'd0 : cph + 2'd1;
wire       tick = (cph == 2'd2);
wire       dot;                // sync_gen's: the tick, or every clock on the native raster

reg  [1:0]  std = 2'd0;
reg         nat = 1'b0;
reg  [11:0] g_w = 0, g_h = 0, g_l = 0, g_nt = 0, g_last = 0;
wire [11:0] h_pos, v_pos, lines, last_line;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
integer iv;
initial if ($value$plusargs("std=%d", iv)) std = iv[1:0];
sync_gen dut (.clk(clk), .clk_en(tick), .dot(dot), .rst_n(rst_n), .interlaced(1'b0), .std(std),
    .nat(nat), .g_w(g_w), .g_h(g_h), .g_l(g_l), .g_nt(g_nt), .g_last(g_last), .lines(lines), .last_line(last_line),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field), .ce_pix(ce_pix));

// the segment presented at each frame's first dot (sync_gen takes it the cycle the counters wrap)
reg        f_nat;
reg [11:0] f_w, f_h, f_nt;
integer F_WANT;
integer dots, de_lines, de_run, de_bad, gap, gap_min, hs_rises, hs_in_de, vs_lines, vs_first, vs_bad, rep_bad;
integer prev_de, prev_hs, prev_vs, in_line_de, frames, scored, n_nat;
integer cur_line;
initial F_WANT = 0;

always @(posedge clk) if (rst_n) begin
    if (dot && frame_tick) begin
        // score the frame that just ended (whole frames only: after the first tick)
        if (frames >= 1) begin
            // (the outputs are registered a DOT behind the counters, and a dot is 3 clocks fitted, 1
            // native: a frame followed by the other kind measures 2 clocks short / long at the
            // outputs -- the counters themselves keep 3F; the 2 clocks fall in the vertical blank)
            if (dots !== F_WANT + 2 * (f_nat - nat))
                `FAIL("dots", $sformatf("frame %0d (nat %0d %0dx%0d, next nat %0d): %0d clocks, want %0d", frames, f_nat, f_w, f_h, nat, dots, F_WANT + 2 * (f_nat - nat)))
            if (de_lines !== f_h || de_bad !== 0) `FAIL("area", $sformatf("frame %0d (nat %0d %0dx%0d): %0d DE lines, %0d lines not %0d dots from h_pos 0", frames, f_nat, f_w, f_h, de_lines, de_bad, f_w))
            if (gap_min < 20) `FAIL("blank", $sformatf("frame %0d (nat %0d %0dx%0d): DE low only %0d dots between lines", frames, f_nat, f_w, f_h, gap_min))
            if (hs_in_de !== 0 || (f_nat && hs_rises !== f_nt)) `FAIL("hs", $sformatf("frame %0d (nat %0d %0dx%0d): %0d HS rises (want %0d), %0d during DE", frames, f_nat, f_w, f_h, hs_rises, f_nt, hs_in_de))
            if (f_nat && (vs_lines !== 3 || vs_first !== f_h + 2 || vs_bad !== 0)) `FAIL("vs", $sformatf("frame %0d (%0dx%0d): VS %0d lines from line %0d", frames, f_w, f_h, vs_lines, vs_first))
            if (rep_bad !== 0) `FAIL("report", $sformatf("frame %0d (nat %0d %0dx%0d): lines / last_line disagreed %0d times", frames, f_nat, f_w, f_h, rep_bad))
            scored = scored + 1;
            if (f_nat) n_nat = n_nat + 1;
        end
        frames = frames + 1;
        // the segment this new frame must run: the one this bench presented before its first dot
        // (segments change only mid-frame, so the inputs now are the ones at the wrap)
        f_nat = nat; f_w = nat ? g_w : 12'd720; f_h = nat ? g_h : ((std == 2) ? 12'd576 : 12'd480);
        f_nt = g_nt;
        dots = 0; de_lines = 0; de_bad = 0; gap = 0; gap_min = 100000; hs_rises = 0; hs_in_de = 0;
        vs_lines = 0; vs_first = -1; vs_bad = 0; rep_bad = 0; de_run = 0; cur_line = 0;
    end
    dots = dots + 1;                          // CLOCKS (the frame's time)
  if (dot) begin                              // everything else a dot at a time
    // DE: one run a line, from h_pos 0, f_w long; the gap between runs
    if (pixel_en) begin
        if (!prev_de) begin
            if (h_pos !== 12'd0) de_bad = de_bad + 1;
            if (gap > 0 && gap < gap_min) gap_min = gap;
            de_run = 0;
        end
        de_run = de_run + 1;
        gap = 0;
    end else begin
        if (prev_de) begin
            de_lines = de_lines + 1;
            if (de_run !== f_w) de_bad = de_bad + 1;
        end
        gap = gap + 1;
    end
    if (h_sync && !prev_hs) hs_rises = hs_rises + 1;
    if (h_sync && pixel_en) hs_in_de = hs_in_de + 1;
    // VS: counted in lines (at h_pos 0)
    if (h_pos == 12'd0) begin
        if (v_sync) begin vs_lines = vs_lines + 1; if (vs_first < 0) vs_first = v_pos; end
        if (lines !== f_h || last_line !== (f_nat ? f_nt - 12'd1 : ((std == 2) ? 12'd624 : 12'd524))) rep_bad = rep_bad + 1;
    end
    if (v_sync && !prev_vs && vs_first >= 0 && v_pos != vs_first) vs_bad = vs_bad + 1;
    prev_de = pixel_en; prev_hs = h_sync; prev_vs = v_sync;
  end
end

integer fd, r, seg, wait_dots, k;
integer vn, vw, vh, vl, vnt, vlast;
string geo;
initial begin
    frames = 0; scored = 0; n_nat = 0; prev_de = 0; prev_hs = 0; prev_vs = 0; dots = 0;
    de_lines = 0; de_bad = 0; gap = 0; gap_min = 100000; hs_rises = 0; hs_in_de = 0; vs_lines = 0; vs_first = -1; vs_bad = 0; rep_bad = 0;
    F_WANT = (std == 2) ? 1620000 : (std == 1) ? 1350000 : 1351350;
    if (!$value$plusargs("geo=%s", geo)) `FAIL("harness", "+geo= missing")
    fd = $fopen(geo, "r");
    if (fd == 0) `FAIL("harness", {"cannot open ", geo})
    repeat (4) @(posedge clk);
    rst_n = 1;
    seg = 0;
    forever begin
        r = $fscanf(fd, "%h %h %h %h %h %h\n", vn, vw, vh, vl, vnt, vlast);
        if (r != 6) break;
        // present it at a random dot in the middle of the frame being scanned
        @(posedge frame_tick);
        wait_dots = 150000 + ($urandom % 900000);    // clocks
        repeat (wait_dots) @(posedge clk);
        @(negedge clk);
        nat = vn[0]; g_w = vw; g_h = vh; g_l = vl; g_nt = vnt; g_last = vlast;
        for (k = 0; k < 3; k = k + 1) @(posedge frame_tick);
        seg = seg + 1;
    end
    @(posedge frame_tick); @(posedge frame_tick);
    if (scored < 3 * seg || n_nat < seg || seg < 8)
        `FAIL("harness", $sformatf("coverage: %0d segments, %0d frames scored, %0d native", seg, scored, n_nat))
    $display("sync_gen_nat_tb: std %0d, %0d segments, %0d frames scored (%0d native): every frame %0d clocks, its DE, blank, HS, VS and report as presented at its first dot",
             std, seg, scored, n_nat, F_WANT);
    $display("PASS: sync_gen_nat_tb");
    $finish;
end
endmodule
