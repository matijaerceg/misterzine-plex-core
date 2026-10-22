// bench/h264/sync_gen_tb.sv -- MEASURES h264/sync_gen.sv's raster rather than restating it.
//
// Every number below is counted from the DUT's outputs over whole frames: dots between
// frame_ticks, active dots per frame, hsync width and period, vsync width and start
// line, coordinate monotonicity. The expected values are the CEA-861 480p figures
// written out independently of the module's parameters (858x525, 720x480, 62/6, sync
// at dot 736 and line 489), so a wrong parameter in the DUT cannot also be wrong here.
// +std=N (P6 steps 5 / 6, docs/analog.md §10): 1 = 60.00 Hz -- 450,000 dots a frame, 75
// lines of 858 dots (the frame lines % 7 == 0) and 450 of 857, every hsync rising edge
// within one dot of the uniform grid (450,000 / 525 dots a line); 2 = 50 Hz, CEA-861 576p
// (864x625, 720x576, hsync 64 from dot 732, vsync 5 lines from line 581); 3 reserved.
//
// Scoring uses !== throughout (an X passes != vacuously) and every failure is $fatal
// (a $finish on failure exits 0 and a runner reads it as PASS).
`timescale 1ns/1ps
module sync_gen_tb;

reg clk = 0, rst_n = 0;
always #18.5 clk = ~clk;           // ~27 MHz

wire [11:0] h_pos, v_pos;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field;
reg [1:0] std = 2'd0;
integer   iv;
initial if ($value$plusargs("std=%d", iv)) std = iv[1:0];
sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(1'b0), .std(std),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field), .nat(1'b0), .g_w(12'd0), .g_h(12'd0), .g_l(12'd0), .g_nt(12'd0), .g_last(12'd0), .lines(), .last_line());

integer fails = 0;
task check(input [767:0] what, input integer got, input integer want);
    if (got !== want) begin
        $display("FAIL %0s: got %0d want %0d", what, got, want); fails = fails + 1;
    end else $display("  ok  %0s = %0d", what, got);
endtask

// counters over one measured frame (from the 2nd frame_tick to the 3rd)
integer dots, active, hs_dots, vs_lines, hs_periods, hs_first_dot, vs_first_line;
integer hs_rise_dot, prev_hs, prev_vs, lines_in_frame, prev_h, prev_v;
integer mono_fail, field_fail, ticks;
integer frame_no;
// line lengths (from h_pos wraps) and the hsync edges' deviation from a uniform grid
integer line_len, n_long, n_short, n_other, long_bad, hs_idx, hs_t0, t_abs, dev, dev_max;
// the standard's figures, written out here (not from the module)
integer W_DOTS, W_ACT, W_HS, W_LINES, W_HS0, W_VS, W_VS0;
initial begin
    case (std)
        2'd3:    begin W_DOTS = 900 * 625; W_ACT = 720 * 576; W_HS = 64; W_LINES = 625; W_HS0 = 732; W_VS = 5; W_VS0 = 581; end
        2'd2:    begin W_DOTS = 864 * 625; W_ACT = 720 * 576; W_HS = 64; W_LINES = 625; W_HS0 = 732; W_VS = 5; W_VS0 = 581; end
        2'd1:    begin W_DOTS = 450000;    W_ACT = 720 * 480; W_HS = 62; W_LINES = 525; W_HS0 = 736; W_VS = 6; W_VS0 = 489; end
        default: begin W_DOTS = 858 * 525; W_ACT = 720 * 480; W_HS = 62; W_LINES = 525; W_HS0 = 736; W_VS = 6; W_VS0 = 489; end
    endcase
end

initial begin
    dots = 0; active = 0; hs_dots = 0; vs_lines = 0; hs_periods = 0;
    hs_first_dot = -1; vs_first_line = -1; hs_rise_dot = -1; prev_hs = 0; prev_vs = 0;
    lines_in_frame = 0; prev_h = -1; prev_v = -1; mono_fail = 0; field_fail = 0; ticks = 0;
    frame_no = 0;
    line_len = 0; n_long = 0; n_short = 0; n_other = 0; long_bad = 0; hs_idx = 0; hs_t0 = -1; t_abs = 0; dev_max = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    // count frame_ticks; measure the whole frame between the 2nd and the 3rd (the
    // first frame after reset is partial). The tick dot itself belongs to the frame
    // it starts, so it is counted below in the same cycle it is seen.
    forever begin
        @(posedge clk);
        // the line that ends at this dot (prev_v): its length -- before the tick below, so
        // the frame's last line (it ends on the check's own cycle) is counted
        if (ticks >= 2 && prev_h >= 0 && h_pos === 0) begin
            if (prev_h + 1 == ((std == 2'd2) ? 864 : 858)) begin
                n_long = n_long + 1;
                if (std == 2'd1 && (prev_v % 7) != 0) long_bad = long_bad + 1;
            end else if (std == 2'd1 && prev_h + 1 == 857) begin
                n_short = n_short + 1;
                if ((prev_v % 7) == 0) long_bad = long_bad + 1;
            end else n_other = n_other + 1;
        end
        if (frame_tick) begin
            ticks = ticks + 1;
            if (ticks == 3) begin
                check("dots per frame (858x525 / 450,000 / 864x625)", dots, W_DOTS);
                check("active dots per frame (720x480 / 720x576)", active, W_ACT);
                check("hsync width (dots)", hs_dots / hs_periods, W_HS);
                check("hsync periods per frame", hs_periods, W_LINES);
                check("hsync first dot (720 + front porch)", hs_first_dot, W_HS0);
                check("vsync width (lines)", vs_lines, W_VS);
                check("vsync first line", vs_first_line, W_VS0);
                check("h_pos/v_pos monotone", mono_fail, 0);
                if (std == 2'd1) begin
                    // 60.00 Hz: one line in seven long, the rest one dot short, the edges
                    // within a dot of the uniform grid
                    check("60.00: lines of 858 dots", n_long, 75);
                    check("60.00: lines of 857 dots", n_short, 450);
                    check("60.00: the long lines are the frame lines % 7 == 0", long_bad, 0);
                    check("60.00: every hsync edge within a dot of the uniform grid", dev_max < 525 ? 1 : 0, 1);
                end else begin
                    check("every line the same length", n_other + n_short, 0);
                end
                check("field stays 0", field_fail, 0);
                if (fails != 0) begin $display("FAIL: sync_gen_tb %0d check(s)", fails); $fatal(1); end
                $display("PASS: sync_gen_tb");
                $finish;
            end
        end
        if (ticks >= 2) begin
            dots = dots + 1;
            if (pixel_en === 1'b1) active = active + 1;
            if (h_sync === 1'b1) hs_dots = hs_dots + 1;
            if (h_sync === 1'b1 && prev_hs === 0) begin
                hs_periods = hs_periods + 1;
                if (hs_first_dot < 0) hs_first_dot = h_pos;
            end
            if (v_sync === 1'b1 && prev_vs === 0) vs_first_line = v_pos;
            if (v_sync === 1'b1 && h_pos == 0) vs_lines = vs_lines + 1;
            // coordinates: h steps by 1 or wraps to 0 (a line's end); v steps by 1 at the wrap
            if (prev_h >= 0) begin
                if (h_pos !== prev_h + 1 && h_pos !== 0) mono_fail = mono_fail + 1;
                if (h_pos === 0 && v_pos !== ((prev_v == W_LINES - 1) ? 0 : prev_v + 1)) mono_fail = mono_fail + 1;
                if (h_pos !== 0 && v_pos !== prev_v) mono_fail = mono_fail + 1;
            end
            // the hsync edges against the uniform grid: 1000 x (t - t0 - i x frame / lines),
            // in thousandths of a dot x 525 / 1000 (integer: edge i ideally at i x 450000 / 525)
            t_abs = t_abs + 1;
            if (h_sync === 1'b1 && prev_hs === 0) begin
                if (hs_t0 < 0) hs_t0 = t_abs;
                dev = (t_abs - hs_t0) * W_LINES - hs_idx * W_DOTS;       // dots x 525
                if (dev < 0) dev = -dev;
                if (dev > dev_max) dev_max = dev;
                hs_idx = hs_idx + 1;
            end
            if (field !== 1'b0) field_fail = field_fail + 1;
            prev_h = h_pos; prev_v = v_pos;
        end
        prev_hs = h_sync; prev_vs = v_sync;
    end
end

initial begin #(40*858*525*4); $display("FAIL: sync_gen_tb timeout"); $fatal(1); end
endmodule
