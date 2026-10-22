// bench/h264/sync_gen_il_tb.sv -- MEASURES h264/sync_gen.sv's interlaced (480i) raster.
//
// The DUT starts progressive; after two progressive frames `interlaced` rises and the
// bench checks the restart, then measures four whole fields. The expected values are the
// 480i figures written out independently of the module (docs/analog.md, MiSTer_DVD's
// N64-model raster): 1716 dots a line (pixel repetition), 240 active lines a field of
// 1440 active dots, hsync 124 dots from dot 1472, the two fields 262 and 263 lines
// (900,900 dots a frame), vsync 3 lines long, its rising edges EXACTLY 262.5 lines
// (450,450 dots) apart every field -- the short field's at dot 0 of a line, the long
// field's at the half-line (dot 858) -- and the short (SMPTE field 1) field the v_pos-ODD
// one (FIELD1_VPOS). v_pos is the frame line: every active line of a field has the
// field's parity; `field` equals v_pos[0]; ce_pix marks every even dot; the field the switch
// starts is whole (one frame_tick, not two: the restart's own cycle does not tick).
//
// +std=N (P6 steps 5 / 6, docs/analog.md §10), each standard's figures written out here:
//   1 = 60.00 Hz: lines of 1,714 / 1,716 dots, fields of 450,858 / 449,142, 900,000 a
//       frame, the vsync edges within 2 dots of 450,000 apart;
//   2 = 50 Hz (CEA-861 576i): 1,728 dots a line, 288 x 1,440 active, hsync 128 from dot
//       1,464, fields of 312 / 313 lines (1,080,000 dots a frame), vsync 3 lines, its edges
//       exactly 540,000 apart, the long field's at the half-line (864).
//   3 is reserved and safely falls back to the 59.94-family timing.
// !== throughout; every failure is $fatal; the PASS marker is positive.
`timescale 1ns/1ps
module sync_gen_il_tb;

reg clk = 0, rst_n = 0, il = 0;
always #18.5 clk = ~clk;
reg [1:0] std = 2'd0;
integer   iv;
initial if ($value$plusargs("std=%d", iv)) std = iv[1:0];
// the standard's figures (not from the module)
integer W_F0, W_HS, W_HS0, W_ACT, W_LINES, W_FRAME, W_VSW, W_GAP, W_TOL, W_HALF, W_LONG;
initial begin
    case (std)
        2'd3:    begin W_F0 = 313 * 1800; W_HS = 128; W_HS0 = 1464; W_ACT = 1440 * 288; W_LINES = 625;
                       W_FRAME = 1125000; W_VSW = 3 * 1800; W_GAP = 562500; W_TOL = 0; W_HALF = 900; W_LONG = 313; end
        2'd2:    begin W_F0 = 313 * 1728; W_HS = 128; W_HS0 = 1464; W_ACT = 1440 * 288; W_LINES = 625;
                       W_FRAME = 1080000; W_VSW = 3 * 1728; W_GAP = 540000; W_TOL = 0; W_HALF = 864; W_LONG = 313; end
        2'd1:    begin W_F0 = 450858; W_HS = 124; W_HS0 = 1472; W_ACT = 1440 * 240; W_LINES = 525;
                       W_FRAME = 900000; W_VSW = -1; W_GAP = 450000; W_TOL = 2; W_HALF = 858; W_LONG = 263; end
        default: begin W_F0 = 263 * 1716; W_HS = 124; W_HS0 = 1472; W_ACT = 1440 * 240; W_LINES = 525;
                       W_FRAME = 900900; W_VSW = 3 * 1716; W_GAP = 450450; W_TOL = 0; W_HALF = 858; W_LONG = 263; end
    endcase
end

wire [11:0] h_pos, v_pos;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(il), .std(std),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field), .ce_pix(ce_pix), .nat(1'b0), .g_w(12'd0), .g_h(12'd0), .g_l(12'd0), .g_nt(12'd0), .g_last(12'd0), .lines(), .last_line());

// a second raster OUT OF RESET already interlaced (emu powering up with Video Output =
// Interlaced): its restart lands with the counters at 0, where a tick in the restart's own
// cycle would make the first field tick twice
wire [11:0] h2, v2;
wire pe2, hs2, vs2, hb2, vb2, ft2, fl2, ce2;
sync_gen dut2 (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(1'b1), .std(std),
    .h_pos(h2), .v_pos(v2), .pixel_en(pe2), .h_sync(hs2), .v_sync(vs2),
    .h_blank(hb2), .v_blank(vb2), .frame_tick(ft2), .field(fl2), .ce_pix(ce2));
integer t2 = 0, ft2_n = 0, ft2_first = -1, ft2_gap = -1;
always @(posedge clk) if (rst_n) begin
    t2 = t2 + 1;
    if (ft2 === 1'b1) begin
        if (ft2_n == 0) ft2_first = t2;
        else if (ft2_n == 1) ft2_gap = t2 - ft2_first;
        ft2_n = ft2_n + 1;
    end
end

integer fails = 0;
task check(input [511:0] what, input integer got, input integer want);
    if (got !== want) begin
        $display("FAIL %0s: got %0d want %0d", what, got, want); fails = fails + 1;
    end else $display("  ok  %0s = %0d", what, got);
endtask

// per-field measurements (fields 1..4 after the switch; field 0 is checked for the restart)
integer t, nfield, dots, act, hs_dots, hs_n, hs_first, lines, vs_dots, vs_rise_dot, vs_rise_t;
integer prev_hs, prev_vs, par_fail, fld_fail, ce_fail, lastpar;
integer f_lines [0:7], f_vsdot [0:7], f_par [0:7], f_act [0:7], f_dots [0:7], f_vsw [0:7];
integer f_vsgap [0:7];
integer tick_t, i;
integer hs_dots_w = 0, hs_first_w = -1, f_cur_par = 0;

initial begin
    t = 0; nfield = -1; prev_hs = 0; prev_vs = 0; par_fail = 0; fld_fail = 0; ce_fail = 0;
    vs_rise_t = -1; tick_t = -1;
    for (i = 0; i < 8; i = i + 1) begin f_vsgap[i] = -1; f_vsdot[i] = -1; end
    repeat (4) @(posedge clk);
    rst_n = 1;
    // two progressive frames, then the switch
    repeat (2 * 864 * 625 + 100) @(posedge clk);
    il = 1;
    forever begin
        @(posedge clk); #1;
        t = t + 1;
        if (frame_tick === 1'b1) begin
            if (nfield == -1) begin
                // the restart: the first tick after the switch is the top field's first dot
                check("restart: the first field after the switch starts at h 0", h_pos, 0);
                check("restart: the first field is the top one (v_pos even)", v_pos, 0);
            end else if (nfield >= 0 && nfield < 8) begin
                f_lines[nfield] = lines; f_act[nfield] = act; f_dots[nfield] = dots;
                f_vsdot[nfield] = vs_rise_dot; f_par[nfield] = lastpar; f_vsw[nfield] = vs_dots;
            end
            nfield = nfield + 1;
            dots = 0; act = 0; hs_dots = 0; hs_n = 0; hs_first = -1; lines = 0; vs_dots = 0; vs_rise_dot = -1;
            if (nfield == 6) begin
                // fields 1..4 (the first whole ones after the restart field 0)
                // the restart's field is whole: ONE tick, then 263 lines (a restart that
                // ticked twice would be a spurious refresh at every mode switch)
                check("the first field after the switch is whole (one tick, the long field)", f_dots[0], W_F0);
                check("reset-interlaced first field whole", ft2_gap, W_F0);
                check("hsync width (dots, 2 x the progressive)", hs_dots_w, W_HS);
                check("hsync first dot (2 x (720 + front porch))", hs_first_w, W_HS0);
                check("active dots a field (1440 x 240 / 288)", f_act[2], W_ACT);
                check("the two field totals, lines (262 + 263 / 312 + 313)", f_lines[2] + f_lines[3], W_LINES);
                check("the field totals alternate", f_lines[2] + f_lines[4] == 2 * f_lines[2] ? 1 : 0, 1);
                check("dots a frame", f_dots[2] + f_dots[3], W_FRAME);
                if (W_VSW >= 0) begin
                    check("vsync length (dots, 3 lines)", f_vsw[2], W_VSW);
                    check("vsync length, the other field", f_vsw[3], W_VSW);
                end else begin
                    // 60.00: three lines of 1,714 or 1,716 dots
                    check("vsync length within 3 lines of 1,714 .. 1,716 dots", (f_vsw[2] >= 3 * 1714 && f_vsw[2] <= 3 * 1716) ? 1 : 0, 1);
                    check("vsync length, the other field", (f_vsw[3] >= 3 * 1714 && f_vsw[3] <= 3 * 1716) ? 1 : 0, 1);
                    check("the fields 450,858 / 449,142 dots", (f_dots[2] == 450858 || f_dots[2] == 449142) &&
                          (f_dots[2] + f_dots[3] == 900000) ? 1 : 0, 1);
                end
                for (i = 3; i <= 5; i = i + 1)
                    check("vsync edge spacing (half a frame)",
                          ((f_vsgap[i] - W_GAP <= W_TOL) && (W_GAP - f_vsgap[i] <= W_TOL)) ? 1 : 0, 1);
                // the short field is SMPTE field 1: line-aligned vsync, and v_pos-ODD
                for (i = 2; i <= 3; i = i + 1)
                    if (f_lines[i] == W_LONG - 1) begin
                        check("the short field's vsync starts at dot 0", f_vsdot[i], 0);
                        check("the short field is the v_pos-odd one (FIELD1_VPOS)", f_par[i], 1);
                    end else begin
                        check("the long field's vsync starts at the half-line", f_vsdot[i], W_HALF);
                        check("the long field is 263 / 313 lines", f_lines[i], W_LONG);
                        check("the long field is the v_pos-even one", f_par[i], 0);
                    end
                check("active lines keep their field's parity", par_fail, 0);
                check("field == v_pos[0] on active dots", fld_fail, 0);
                check("ce_pix on every even dot, only there", ce_fail, 0);
                if (fails != 0) begin $display("FAIL: sync_gen_il_tb %0d check(s)", fails); $fatal(1); end
                $display("PASS: sync_gen_il_tb");
                $finish;
            end
        end
        if (nfield >= 0) begin
            dots = dots + 1;
            if (pixel_en === 1'b1) begin
                act = act + 1;
                lastpar = v_pos[0];
                if (dots > 1 && v_pos[0] !== f_cur_par) par_fail = par_fail + 1;
                if (field !== v_pos[0]) fld_fail = fld_fail + 1;
            end
            if (h_pos == 0) begin
                lines = lines + 1;
                if (dots == 1) f_cur_par = v_pos[0];
            end
            if (ce_pix !== ~h_pos[0]) ce_fail = ce_fail + 1;
            if (h_sync === 1'b1) hs_dots = hs_dots + 1;
            if (h_sync === 1'b1 && prev_hs === 0) begin
                hs_n = hs_n + 1;
                if (hs_first < 0) hs_first = h_pos;
                hs_first_w = hs_first;
            end
            if (h_sync === 1'b0 && prev_hs === 1) hs_dots_w = hs_dots / hs_n;
            if (v_sync === 1'b1) vs_dots = vs_dots + 1;
            if (v_sync === 1'b1 && prev_vs === 0) begin
                vs_rise_dot = h_pos;
                if (vs_rise_t >= 0 && nfield < 8) f_vsgap[nfield] = t - vs_rise_t;
                vs_rise_t = t;
            end
        end
        prev_hs = h_sync; prev_vs = v_sync;
    end
end
initial begin #(40 * 864 * 625 * 8); $display("FAIL: sync_gen_il_tb timeout"); $fatal(1); end
endmodule
