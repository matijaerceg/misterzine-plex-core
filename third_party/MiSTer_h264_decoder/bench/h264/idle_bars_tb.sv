// bench/h264/idle_bars_tb.sv -- scores h264/idle_bars.sv on the pixels it emits.
//
// The DUT runs behind the real raster (h264/sync_gen.sv at its default 480p timing).
// Coordinates are NOT taken from h_pos / v_pos: the bench counts de_out itself (x = dot
// within a de run, y = run index mod 480), so a DUT that misaligns its colour with its
// DE is caught rather than scored against its own mistake.
//
// Arms (each named in its FAIL line; bench/h264/run_scaffold.sh --red proves each can fail):
//   [cov]  every de run is 720 dots, every frame 480 runs, and de_out is de_in delayed by
//          exactly LAT = 2 clocks
//   [bars] lines 0..319: every dot is its bar's 75 % colour, bars 103 dots wide (the last
//          102) in EIA-189-A order -- the table below is written from that order, not
//          from the DUT
//   [band] lines 320..479: black, except one 32x32 white square on lines 400..431 whose
//          left edge is the same on all 32 lines
//   [mot]  the square advances exactly STEP dots per frame and wraps to 0 when the next
//          step would put its right edge past 720. The runner builds the bench twice:
//          STEP = 4 (the core's value, 6 frames) and STEP = 64 (14 frames, which must
//          contain a wrap; a 4-dot wrap takes 173 frames, too slow for iverilog)
//   [vis]  with vis = 0 a whole frame is black and still 720x480 of DE
//
// Scoring uses !== throughout (an X passes != vacuously) and every failure is $fatal (a
// $finish on failure exits 0 and a runner reads it as PASS).
`timescale 1ns/1ps
module idle_bars_tb;

parameter  integer STEP       = 4;       // the DUT's MK_STEP (iverilog -P idle_bars_tb.STEP=...)
parameter  integer N_FRAMES   = 6;       // frames scored before the vis = 0 frame
parameter  integer NEED_WRAP  = 0;       // 1: the run must contain a wrap
localparam integer LAT        = 2;
localparam integer FULL_SCORE = 3;       // frames scored dot by dot (the rest: the marker only)

reg clk = 0, rst_n = 0, vis = 1;
always #18.5 clk = ~clk;                // ~27 MHz

wire [11:0] h_pos, v_pos;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field;
sync_gen sg (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(1'b0), .std(2'd0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field), .nat(1'b0), .g_w(12'd0), .g_h(12'd0), .g_l(12'd0), .g_nt(12'd0), .g_last(12'd0), .lines(), .last_line());

wire [7:0] r, g, b;
wire       de_out;
idle_bars #(.MK_STEP(STEP)) dut (
    .clk(clk), .ce(1'b1), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(pixel_en),
    .frame_tick(frame_tick), .vis(vis), .r(r), .g(g), .b(b), .de_out(de_out));

// ---- expected bars: EIA-189-A 75 % order, 103 dots each, the last takes the remainder --
function automatic [23:0] bar_rgb(input integer x);
    integer k;
    begin
        k = x / 103; if (k > 6) k = 6;
        case (k)
            0: bar_rgb = {8'd191, 8'd191, 8'd191};   // white
            1: bar_rgb = {8'd191, 8'd191, 8'd0  };   // yellow
            2: bar_rgb = {8'd0,   8'd191, 8'd191};   // cyan
            3: bar_rgb = {8'd0,   8'd191, 8'd0  };   // green
            4: bar_rgb = {8'd191, 8'd0,   8'd191};   // magenta
            5: bar_rgb = {8'd191, 8'd0,   8'd0  };   // red
            default: bar_rgb = {8'd0, 8'd0, 8'd191}; // blue
        endcase
    end
endfunction

integer f_cov = 0, f_bars = 0, f_band = 0, f_mot = 0, f_vis = 0;
integer x = 0, y = 0, frame = 0, runs = 0;
reg     de_prev = 0;
reg [LAT-1:0] de_dly = 0;
integer mk_x0, mk_rows, prev_x0, wraps, vis_frame;
reg [23:0] px;

// one line's marker bookkeeping
integer row_first, row_last, row_white;

task automatic fail(input [63:0] arm, input [511:0] msg, inout integer cnt);
    begin
        if (cnt < 5) $display("FAIL [%0s] frame %0d x %0d y %0d: %0s", arm, frame, x, y, msg);
        cnt = cnt + 1;
    end
endtask

initial begin
    mk_x0 = -1; mk_rows = 0; prev_x0 = -1; wraps = 0; vis_frame = N_FRAMES;
    row_first = -1; row_last = -1; row_white = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
end

always @(posedge clk) if (rst_n) begin
    // [cov] de_out is de_in delayed by exactly LAT clocks
    if (de_out !== de_dly[LAT-1]) fail("cov", "de_out is not de_in delayed by LAT", f_cov);
    de_dly <= {de_dly[LAT-2:0], pixel_en};

    px = {r, g, b};
    if (de_out === 1'b1) begin
        // ---- the dot at (x, y) ----
        if (frame == vis_frame) begin
            if (px !== 24'd0) fail("vis", "not black with vis = 0", f_vis);
        end else if (y < 320) begin
            if (frame < FULL_SCORE && px !== bar_rgb(x)) fail("bars", "wrong bar colour", f_bars);
        end else begin
            if (px === 24'hFFFFFF) begin
                if (y < 400 || y >= 432) fail("band", "white outside the marker rows", f_band);
                if (row_first < 0) row_first = x;
                if (row_last >= 0 && row_last != x - 1) fail("band", "marker row not contiguous", f_band);
                row_last = x; row_white = row_white + 1;
            end else if (px !== 24'd0) begin
                fail("band", "band dot neither black nor white", f_band);
            end
        end
        x = x + 1;
    end
    // end of a de run: close the line
    if (de_prev === 1'b1 && de_out !== 1'b1) begin
        if (x !== 720) fail("cov", "de run is not 720 dots", f_cov);
        if (y >= 400 && y < 432 && frame != vis_frame) begin
            if (row_white !== 32) fail("band", "marker row is not 32 dots", f_band);
            if (mk_x0 < 0) mk_x0 = row_first;
            else if (row_first !== mk_x0) fail("band", "marker rows do not share a left edge", f_band);
            mk_rows = mk_rows + 1;
        end
        row_first = -1; row_last = -1; row_white = 0;
        x = 0; y = y + 1; runs = runs + 1;
        if (y == 480) begin
            // ---- end of a frame ----
            if (frame != vis_frame) begin
                if (mk_rows !== 32) fail("band", "marker is not 32 rows", f_band);
                if (prev_x0 >= 0) begin
                    if (prev_x0 + STEP + 32 > 720) begin
                        if (mk_x0 !== 0) fail("mot", "marker did not wrap to 0", f_mot);
                        wraps = wraps + 1;
                    end else if (mk_x0 !== prev_x0 + STEP) begin
                        fail("mot", "marker did not advance STEP dots", f_mot);
                    end
                end
                prev_x0 = mk_x0;
            end
            mk_x0 = -1; mk_rows = 0;
            y = 0; frame = frame + 1;
            if (frame == N_FRAMES) vis = 0;           // in vertical blanking: the next frame is black
            if (frame == N_FRAMES + 1) begin
                if (NEED_WRAP && wraps < 1) fail("mot", "no wrap seen in the run", f_mot);
                if (f_cov + f_bars + f_band + f_mot + f_vis != 0) begin
                    $display("FAIL: idle_bars_tb cov=%0d bars=%0d band=%0d mot=%0d vis=%0d",
                             f_cov, f_bars, f_band, f_mot, f_vis);
                    $fatal(1);
                end
                $display("  ok  STEP %0d: %0d frames, %0d wrap(s), bars scored on %0d frames, a black vis=0 frame",
                         STEP, N_FRAMES, wraps, FULL_SCORE);
                $display("PASS: idle_bars_tb");
                $finish;
            end
        end
    end
    de_prev = de_out;
end

initial begin #(37.0 * 858 * 525 * (N_FRAMES + 4)); $display("FAIL: idle_bars_tb timeout"); $fatal(1); end
endmodule
