// h264/idle_bars.sv -- the idle screen: 75 % colour bars and a moving marker
//
// Shown whenever no stream is presenting (in the scaffold: always). Two jobs:
//
//   * prove the raster on every output: seven 75 % bars (EIA-189-A order, full-range
//     RGB 191 / 0) over the top 320 lines, so a screenshot or a scope shows the core's
//     geometry and colour path at a glance;
//   * prove the core is RUNNING, not a frozen last frame: a 32x32 white marker in the
//     black band below the bars advances 4 dots per frame and wraps. Two screenshots
//     a second apart must differ (docs/hil_harness.md: "is the PICTURE frozen or is
//     the MACHINE frozen?").
//
// Deliberately plain. UMD's idle screen is the PSP XMB wave; this core's identity is
// "a decoder waiting for a stream", and a test pattern says that honestly. A branded
// screen is a later, cosmetic decision (docs/experiments.md).
//
// Layout (h_pos / v_pos in sync_gen's convention, 0 = first active dot / line):
//   v   0..319  bars; bar k spans h in [103k, 103k + 103): 103 dots each, the last
//               102 (720 = 6*103 + 102)
//   v 320..479  black, except the marker: v in [400, 432), h in [mx, mx + 32)
//   mx: 0 after reset, +MK_STEP (4) at every frame_tick, back to 0 once it would pass 688
//               (720 - 32), so the marker never clips at the right edge
//
// vis = 0 blanks the colour (black) but keeps de_out: the display mux downstream
// decides what shows, this module only answers "what does idle look like here".
//
// Latency: LAT = 2 dots from {h_pos, v_pos, de_in} to {r, g, b, de_out}. emu delays
// the syncs to match. (hd_raster: clk is clk_vid and every register advances on `ce`, the dot.)

module idle_bars #(
    // Dots the marker moves per frame. 4 in the core; the bench also runs 64 so a wrap
    // happens within a dozen frames (a 4-dot wrap takes 173 frames, ~80 M sim cycles).
    parameter [11:0] MK_STEP = 12'd4
)(
    input  wire        clk,
    input  wire        ce,          // (hd_raster) the dot: every register advances on it
    input  wire        rst_n,
    input  wire [11:0] h_pos,
    input  wire [11:0] v_pos,
    input  wire        de_in,
    input  wire        frame_tick,
    input  wire        vis,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg         de_out
);

localparam [7:0]  LV       = 8'd191;   // 75 % of full range
localparam [11:0] BARS_END = 12'd320;  // first line of the band
localparam [11:0] MK_Y0    = 12'd400;
localparam [11:0] MK_Y1    = 12'd432;
localparam [11:0] MK_W     = 12'd32;
localparam [11:0] MK_LAST  = 12'd688;  // 720 - MK_W: the last x with the whole marker on screen

// ---- the marker's position, advanced once per frame --------------------------------
reg [11:0] mx, mx_e;    // the marker's left edge, and (hd_raster: a register, not an adder on the 81 MHz path) its right
wire [11:0] mx_n = (mx + MK_STEP > MK_LAST) ? 12'd0 : mx + MK_STEP;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)          begin mx <= 12'd0; mx_e <= MK_W; end
    else if (ce && frame_tick) begin mx <= mx_n; mx_e <= mx_n + MK_W; end
end

// ---- stage 1: classify the dot -------------------------------------------------------
reg [2:0] bar_q;       // 0..6
reg       in_bars_q, in_mark_q, de_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bar_q <= 3'd0; in_bars_q <= 1'b0; in_mark_q <= 1'b0; de_q <= 1'b0;
    end else if (ce) begin
        bar_q     <= (h_pos < 12'd103) ? 3'd0 :
                     (h_pos < 12'd206) ? 3'd1 :
                     (h_pos < 12'd309) ? 3'd2 :
                     (h_pos < 12'd412) ? 3'd3 :
                     (h_pos < 12'd515) ? 3'd4 :
                     (h_pos < 12'd618) ? 3'd5 : 3'd6;
        in_bars_q <= (v_pos < BARS_END);
        in_mark_q <= (v_pos >= MK_Y0) && (v_pos < MK_Y1) &&
                     (h_pos >= mx) && (h_pos < mx_e);
        de_q      <= de_in;
    end
end

// ---- stage 2: colour -------------------------------------------------------------------
// Bars as {R, G, B} on/off: white, yellow, cyan, green, magenta, red, blue.
reg [2:0] rgb_on;
always @(*) begin
    case (bar_q)
        3'd0:    rgb_on = 3'b111;
        3'd1:    rgb_on = 3'b110;
        3'd2:    rgb_on = 3'b011;
        3'd3:    rgb_on = 3'b010;
        3'd4:    rgb_on = 3'b101;
        3'd5:    rgb_on = 3'b100;
        default: rgb_on = 3'b001;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r <= 8'd0; g <= 8'd0; b <= 8'd0; de_out <= 1'b0;
    end else if (ce) begin
        de_out <= de_q;
        if (!vis || !de_q) begin
            r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end else if (in_bars_q) begin
            r <= rgb_on[2] ? LV : 8'd0;
            g <= rgb_on[1] ? LV : 8'd0;
            b <= rgb_on[0] ? LV : 8'd0;
        end else if (in_mark_q) begin
            r <= 8'd255; g <= 8'd255; b <= 8'd255;
        end else begin
            r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end
    end
end

endmodule
