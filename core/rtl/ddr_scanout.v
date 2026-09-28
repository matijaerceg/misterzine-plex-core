//============================================================================
//  ddr_scanout - fetch a frame from DDR3 (written by an ARM process) and
//  serve it to the raster, one line ahead.
//
//  Memory layout (physical, byte addresses; the framework's DDRAM port is
//  addressed in 64-bit words, so everything below is >> 3 in hardware):
//
//    BASE + 0x00  header, written by the ARM:
//                   u32 magic   = 0x504C4558 "PLEX"
//                   u32 seq     frame sequence number, written LAST
//                   u32 buf     ring slot (0..4) holding frame `seq`
//                   u32 width   pixels (<= 720, multiple of 16)
//                   u32 height  frame rows (<= 480)
//                   u32 stride  bytes per row of the first plane (multiple of 8)
//                   u32 fmt     0 = xRGB8888 little endian (0x00RRGGBB)
//                               1 = planar YUV 4:2:0, BT.601 limited range
//                   u32 u_off   fmt 1: U plane offset from slot base, 64-bit words
//                   u32 v_off   fmt 1: V plane offset from slot base, 64-bit words
//                   u32 flags   unused
//    BASE + 0x28  overlay plane, written by the UI (a seqlock: taken only when
//                 both sequence words agree, else the last geometry stays):
//                   u32 seq_a
//                   u32 x | y << 16    frame pixels, x even
//                   u32 w | h << 16    w even; the plane is w*4 bytes per row
//                   u32 addr           byte offset of the pixels from BASE, multiple of 8
//                   u32 en             1 = blend the plane over the picture
//                   u32 seq_b
//                 Pixels are ARGB8888 little endian (0xAARRGGBB), straight
//                 alpha: out = video * (256 - a') / 256 + rgb * a' / 256 with
//                 a' = a + a[7]. Rows inside the rectangle are fetched after
//                 the picture's line, into a fourth line buffer.
//    BASE + 0x40  status, written by this module every vsync:
//                   u32 field_cnt   increments once per field / frame
//                   u32 seq_shown   header seq captured at that vsync
//    BASE + 0x48  input snapshot, written every LINE (and at vsync):
//                   u32 joy         joystick_1[15:0] << 16 | joystick_0[15:0]
//                   u32 key         key_cnt[7:0] << 11 | ps2_key[10:0]  (bit 9 pressed,
//                                   bit 8 extended, 7:0 scan code; key_cnt counts events)
//    BASE + 0x50  sprites, read every line, drawn over everything by the
//                 core itself so the UI moves them with one word store:
//                   u32 dot   x | y << 16 | en << 31   a 7-row disc, 9/8 wide
//                   u32 dot_rgb
//                   u32 bar   x | y << 16 | en << 31   a filled rectangle
//                   u32 bar_wh w | h << 16
//                   u32 bar_rgb
//                   u32 run   xmin | xmax << 10 | vx << 20 (signed 8) | load << 28
//                             The dot's x is owned by the core: at every
//                             vsync it takes dot.x when the load bit has
//                             toggled, else adds vx (pixels per field),
//                             clamped to xmin..xmax. So a held scrub runs
//                             field-locked whatever the ARM is doing.
//    BASE + 0x68  dot_x, written by the core every field: where the dot is
//                 (bits 9:0) and the brightness in use (bits 24:16)
//    BASE + 0x88  brightness, written by the UI, taken at every vsync:
//                   u32 0x444D0000 | level   level 0..256 of 256
//                 Every pixel leaves as value * level / 256, after the
//                 overlay and the sprites. Any other word (a wiped ring
//                 reads 0) means full brightness.
//    BASE + 0x100000 + buf * 0x160000   frame ring, 4 slots
//    BASE + 0x680000 .. 0x7E0000        overlay pixels (the UI places them)
//
//  Handshake: the ARM fills a slot the core is not showing, then writes the
//  header with the new buf and seq. This module latches the header at every
//  vsync, so a frame becomes visible at the next field boundary and never
//  tears. The ARM paces itself by polling field_cnt.
//
//  Line fetch: at the start of each line's active video the row for the NEXT
//  line is read into the other half of a two-line buffer (one, or for YUV
//  three planes), so a whole line time (63.5 us) is available. Out-of-range
//  rows and pixels beyond `width` come out black.
//
//  YUV path: nearest-neighbour chroma (each U/V sample covers 2x2 pixels),
//  then R = 1.164(Y-16) + 1.596(V-128)
//       G = 1.164(Y-16) - 0.392(U-128) - 0.813(V-128)
//       B = 1.164(Y-16) + 2.017(U-128)
//  in 8.8 fixed point, clamped. The converter is a free-running 3-stage
//  pipeline; the Y/U/V reads run ahead of hc (y_ahead) to cover it, so each
//  pixel still leaves at its own hc at both pixel clocks (tests/pixel_tb).
//
//  Line ends: in the 15 kHz modes the first 12 and last 8 pixels of every
//  line leave black, whatever the frame, overlay or sprites hold there.
//  720 samples at 13.5 MHz is 53.3 us, wider than analog NTSC's 52.7 us
//  active line, and a picture from pixel 0 starts 9.0 us after the sync
//  edge where analog video starts at 9.4. Whatever restores an RGB or
//  component signal's black level after sync (the set, a transcoder, a
//  receiver) can then sample picture, and each line's black level follows
//  its leftmost pixels: dark or tinted lines that move with the picture.
//  One patron's chain needed the first 10 pixels black. Overscan hides the
//  band. 480p keeps all 720 pixels, and DE is untouched either way, so the
//  HDMI scaler still sees a 720-pixel line.
//============================================================================

module ddr_scanout #(
	parameter [28:0] BASE_WORDS = 29'h04400200,   // 0x22001000 >> 3 (MiSTer_fb memory)
	parameter  [7:0] BURST      = 8'd36
)(
	input             clk,          // must be the clock driving DDRAM_CLK
	input             reset,

	// framework DDR3 port
	input             DDRAM_BUSY,
	output reg  [7:0] DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output reg [63:0] DDRAM_DIN,
	output reg  [7:0] DDRAM_BE,
	output reg        DDRAM_WE,

	// raster timing from crt480i
	input             ce_pix,
	input      [10:0] hc,           // 0 = first active pixel of the line
	input       [9:0] vc,           // frame row of the current line
	input       [9:0] next_row,     // frame row the next line will show
	input             active,       // ~(hblank | vblank)
	input             vs,

	// framework input state, published to the ARM every vsync (main grabs
	// every evdev node, so this is how a menu on the ARM sees the pad)
	input      [15:0] joy0,
	input      [15:0] joy1,
	input      [10:0] ps2_key,
	input       [3:0] scan_status,  // bit 3: CRT profile lock; bit 2: manual OSD override; bits 1:0: actual mode
	output reg  [1:0] app_mode = 0,
	output reg        app_fresh = 0,
	output reg [31:0] tap_sequence = 0,
	input [15:0] tap_peak,

	output reg        valid,        // header magic matched at the last vsync
	output reg  [7:0] r, g, b,
	output     [31:0] dbg_field_cnt
);

localparam [31:0] MAGIC   = 32'h504C4558;
localparam [28:0] BUF0_W  = BASE_WORDS + 29'h20000;   // +1 MB
localparam [28:0] STAT_W  = BASE_WORDS + 29'd8;       // +0x40
localparam [28:0] SPR_W   = BASE_WORDS + 29'd10;      // +0x50

// ---------------- header / status ----------------
reg [31:0] h_seq, h_width, h_height, h_stride, h_uoff, h_voff;
reg  [2:0] h_buf;
reg        h_yuv;
reg  [9:0] o_x = 0, o_y = 0, o_w = 0, o_h = 0;   // overlay rectangle
reg [28:0] o_addr = 0;                           // its pixels, in words from 0
reg        o_en = 0;
reg  [9:0] d_x = 0, d_y = 0;                     // dot sprite
reg        d_en = 0;
reg  [9:0] r_x = 0, r_xmin = 0, r_xmax = 10'd719; // requested x, run limits
reg signed [7:0] r_vx = 0;                       // pixels per field while running
reg        r_load = 0, load_q = 0;
reg [23:0] d_rgb = 24'hFFFFFF;
reg  [9:0] b_x = 0, b_y = 0, b_w = 0, b_h = 0;   // bar sprite
reg        b_en = 0;
reg [23:0] b_rgb = 24'hE0E0E0;
reg  [8:0] lvl = 9'd256;                         // brightness, of 256
reg [63:0] sw0, sw1, sw2;
reg  [2:0] scnt;
reg [31:0] field_cnt = 0;
assign dbg_field_cnt = field_cnt;
reg  [7:0] key_cnt = 0;      // one per ps2_key event, so the ARM can catch quick taps
reg        key_tog_q = 0;

// ---------------- line buffers ----------------
// plane 0: RGB (360 words) or Y (90 words), 2 halves x 512
// plane 1/2: U / V, 45 words each, 2 halves x 64
// plane 3: the overlay row, up to 360 words, 2 halves x 512
reg [63:0] lb0 [0:1023];
reg [63:0] lb1 [0:127];
reg [63:0] lb2 [0:127];
reg [63:0] lb3 [0:1023];
reg        lb_we;
reg  [1:0] lb_plane;
reg  [8:0] lb_waddr;
reg [63:0] lb_wdata;
reg [63:0] q0, q1, q2, q3;
reg        rd_half = 0, wr_half = 1;
// Fetch YUV pixels eight clocks ahead of presentation. Keep the byte index
// with its RAM word, and prefetch row zero from the incoming bank during the
// final blanking pixels. Otherwise stale blanking chroma appears green at x=0.
wire [10:0] y_ahead = hc + ((scan_status[1:0] == 2'd2) ? 11'd4 : 11'd2);
wire y_wrap = (y_ahead >= 11'd858);
wire [10:0] y_x = y_wrap ? y_ahead - 11'd858 : y_ahead;
wire y_half = (y_wrap || hc == 0) ? wr_half : rd_half;
reg [3:0] y_x_q;

// The RGB picture and overlay reads feed the stage register ahead of the
// blend (below), which takes them a clock before the output register takes
// the pixel. At 15 kHz a pixel lasts four clocks, which covers the read and
// the stage, so they read the pixel on show; in 480p it lasts two, so they
// read a pixel ahead, into the incoming bank at the line's end like the YUV
// reads.
wire [10:0] la_ahead = hc + ((scan_status[1:0] == 2'd2) ? 11'd1 : 11'd0);
wire la_wrap = (la_ahead >= 11'd858);
wire [10:0] la_x = la_wrap ? la_ahead - 11'd858 : la_ahead;
wire la_half = (la_wrap || hc == 0) ? wr_half : rd_half;
wire  [9:0] la_row = la_wrap ? next_row : vc;

// where the pixel on show, and the one being read, sit in the overlay rectangle
wire [10:0] ox     = hc - {1'b0, o_x};
wire [10:0] ox_la  = la_x - {1'b0, o_x};
wire        osd_at = o_en && (la_x >= {1'b0, o_x}) && (la_x < ({1'b0, o_x} + {1'b0, o_w})) &&
                     (la_row >= o_y) && (la_row < (o_y + o_h));
// Registered like the line buffer reads: hc moves only on ce_pix, at most
// every other clock, so a clock later it still names the same pixel. Keeps
// these compares out of the blend and brightness multiplies' clock.
reg         in_osd = 0;

always @(posedge clk) begin
	if (lb_we && lb_plane == 2'd0) lb0[{wr_half, lb_waddr}]      <= lb_wdata;
	if (lb_we && lb_plane == 2'd1) lb1[{wr_half, lb_waddr[5:0]}] <= lb_wdata;
	if (lb_we && lb_plane == 2'd2) lb2[{wr_half, lb_waddr[5:0]}] <= lb_wdata;
	if (lb_we && lb_plane == 2'd3) lb3[{wr_half, lb_waddr}]      <= lb_wdata;
	q0 <= lb0[{h_yuv ? y_half : la_half, h_yuv ? {2'b00, y_x[9:3]} : la_x[9:1]}];
	q1 <= lb1[{y_half, y_x[9:4]}];
	q2 <= lb2[{y_half, y_x[9:4]}];
	y_x_q <= y_x[3:0];
	q3 <= lb3[{la_half, ox_la[9:1]}];
	in_osd <= osd_at;
end

wire signed [11:0] d_nx = $signed({2'b00, d_x}) + {{4{r_vx[7]}}, r_vx};

// ---------------- events from the raster ----------------
reg old_vs = 0;
wire vs_rise = vs & ~old_vs;
wire line_start = ce_pix && (hc == 11'd0);

// ---------------- sequencer ----------------
localparam S_IDLE = 4'd0, S_HDR_WAIT = 4'd1, S_STAT = 4'd2,
           S_LINE_SETUP = 4'd3, S_LINE_MUL = 4'd4, S_LINE_RD = 4'd5, S_LINE_WAIT = 4'd6,
           S_STAT2 = 4'd7, S_SPR = 4'd8, S_SPR_WAIT = 4'd9, S_JOY = 4'd10, S_DX = 4'd11,
           S_DIAG = 4'd12;
reg  [3:0] st = S_IDLE;
reg [15:0] fetch_clocks = 0, max_fetch_clocks = 0, missed_lines = 0;
reg timing_fetch = 0;
reg [1:0] measured_mode = 0;
// Diagnostics at +0x80: max fetch clocks (u16), missed active lines (u16).
always @(posedge clk) begin
	if (reset || measured_mode != scan_status[1:0]) begin
		measured_mode <= scan_status[1:0];
		max_fetch_clocks <= 0;
		missed_lines <= 0;
		timing_fetch <= 0;
	end else begin
		if (timing_fetch) fetch_clocks <= fetch_clocks + 16'd1;
		if (line_start) begin
			if (active && timing_fetch && missed_lines != 16'hffff)
				missed_lines <= missed_lines + 16'd1;
			timing_fetch <= (next_row < 10'd480);
			fetch_clocks <= 0;
		end
		if (st == S_JOY && !DDRAM_BUSY && timing_fetch) begin
			if (fetch_clocks > max_fetch_clocks) max_fetch_clocks <= fetch_clocks;
			timing_fetch <= 0;
		end
	end
end

reg        hdr_pend = 0, line_pend = 0;
reg  [9:0] pend_row;
reg  [4:0] hcnt;
reg [63:0] hw0, hw1, hw2, hw3, hw4, hw5, hw6, hw7;
// +0x70: seq_a, 0x56500000|mode, seq_b, reserved. Heartbeat every 250 ms.
reg [63:0] hw14, hw15;
reg [63:0] hw17;             // +0x88: the brightness word
reg [31:0] mode_seq = 0;
reg [7:0] mode_age = 8'd120;
reg  [8:0] words_left;
reg  [5:0] burst_left;
reg [28:0] rd_addr;
reg  [8:0] wr_ptr;
reg  [1:0] seg;              // plane being fetched (3 = the overlay row)
reg [19:0] row_off;          // row * stride_words
reg [28:0] slot_base;        // BUF0_W + buf * 0x2C000 words
reg [28:0] plane_off;
reg  [8:0] line_words;

wire [8:0] stride_words = h_stride[11:3];
wire [7:0] burst_now = (words_left > {1'b0, BURST}) ? BURST : words_left[7:0];

// per-segment operands
wire [9:0] seg_row = (seg == 2'd3) ? (pend_row - o_y) : (seg == 2'd0) ? pend_row : {1'b0, pend_row[9:1]};
wire [8:0] seg_sw  = (seg == 2'd3) ? o_w[9:1] : (seg == 2'd0) ? stride_words : {1'b0, stride_words[8:1]};

// does the overlay cover the line being fetched
wire osd_line = o_en && (pend_row >= o_y) && (pend_row < (o_y + o_h)) && (o_w != 10'd0);

always @(posedge clk) begin
	old_vs <= vs;
	lb_we  <= 1'b0;

	key_tog_q <= ps2_key[10];
	if (ps2_key[10] != key_tog_q) key_cnt <= key_cnt + 8'd1;

	if (vs_rise) begin
		hdr_pend  <= 1'b1;
		field_cnt <= field_cnt + 32'd1;
		// the dot: a new place when asked, else one step of the run
		if (r_load != load_q) begin
			load_q <= r_load;
			d_x    <= r_x;
		end
		else if (r_vx != 8'sd0) begin
			d_x <= (d_nx < $signed({2'b00, r_xmin})) ? r_xmin :
			       (d_nx > $signed({2'b00, r_xmax})) ? r_xmax : d_nx[9:0];
		end
	end

	if (line_start) begin
		rd_half   <= wr_half;
		wr_half   <= ~wr_half;
		line_pend <= 1'b1;
		pend_row  <= next_row;
	end

	if (reset) begin
		st <= S_IDLE;
		DDRAM_RD <= 0;
		DDRAM_WE <= 0;
		valid <= 0;
		app_fresh <= 0;
		mode_age <= 8'd120;
		lvl <= 9'd256;
		hdr_pend <= 0;
		line_pend <= 0;
	end
	else begin
		// ---- data return path, independent of BUSY ----
		if (DDRAM_DOUT_READY) begin
			if (st == S_HDR_WAIT) begin
				case (hcnt)
					4'd0: hw0 <= DDRAM_DOUT;
					4'd1: hw1 <= DDRAM_DOUT;
					4'd2: hw2 <= DDRAM_DOUT;
					4'd3: hw3 <= DDRAM_DOUT;
					4'd4: hw4 <= DDRAM_DOUT;
					4'd5: hw5 <= DDRAM_DOUT;
					4'd6: hw6 <= DDRAM_DOUT;
					4'd7: hw7 <= DDRAM_DOUT;
					5'd14: hw14 <= DDRAM_DOUT;
					5'd15: hw15 <= DDRAM_DOUT;
					5'd17: hw17 <= DDRAM_DOUT;
					default: ;
				endcase
				hcnt <= hcnt + 5'd1;
			end
			else if (st == S_SPR_WAIT) begin
				case (scnt)
					2'd0: sw0 <= DDRAM_DOUT;
					2'd1: sw1 <= DDRAM_DOUT;
					2'd2: sw2 <= DDRAM_DOUT;
					3'd5: tap_sequence <= DDRAM_DOUT[63:32];
					default: ;
				endcase
				scnt <= scnt + 3'd1;
			end
			else begin
				lb_we    <= 1'b1;
				lb_plane <= seg;
				lb_waddr <= wr_ptr;
				lb_wdata <= DDRAM_DOUT;
				wr_ptr   <= wr_ptr + 9'd1;
				burst_left <= burst_left - 6'd1;
			end
		end

		// ---- command path, Avalon style: hold RD/WE until not busy ----
		if (~DDRAM_BUSY) begin
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;

			case (st)
			S_IDLE: begin
				if (hdr_pend) begin
					hdr_pend       <= 1'b0;
					DDRAM_ADDR     <= BASE_WORDS;
					DDRAM_BURSTCNT <= 8'd18;   // through the brightness word
					DDRAM_RD       <= 1'b1;
					hcnt           <= 4'd0;
					st             <= S_HDR_WAIT;
				end
				else if (line_pend) begin
					line_pend <= 1'b0;
					seg       <= 2'd0;
					st        <= S_LINE_SETUP;
				end
			end

			S_HDR_WAIT: if (hcnt == 5'd18) begin
				// taken in the blanking at the top of the field, so a change
				// never splits a picture
				lvl <= (hw17[31:16] == 16'h444D && hw17[8:0] <= 9'd256) ? hw17[8:0] : 9'd256;
				if (hw14[31:0] == hw15[31:0] && !hw14[0] &&
				    hw14[63:34] == 30'h15940000 && hw14[33:32] < 2'd3 &&
				    hw14[31:0] != mode_seq) begin
					mode_seq <= hw14[31:0];
					mode_age <= 0;
					app_mode <= hw14[33:32];
					app_fresh <= 1;
				end else if (mode_age < 8'd120) mode_age <= mode_age + 8'd1;
				else app_fresh <= 0;
				valid    <= (hw0[31:0] == MAGIC);
				h_seq    <= hw0[63:32];
				h_buf    <= hw1[2:0];
				h_width  <= hw1[63:32];
				h_height <= hw2[31:0];
				h_stride <= hw2[63:32];
				h_yuv    <= (hw3[31:0] == 32'd1);
				h_uoff   <= hw3[63:32];
				h_voff   <= hw4[31:0];
				if (hw5[31:0] == hw7[63:32]) begin   // the overlay words agree
					o_x    <= hw5[41:32];
					o_y    <= hw5[57:48];
					o_w    <= hw6[9:0];
					o_h    <= hw6[25:16];
					o_addr <= hw6[63:35];
					o_en   <= hw7[0];
				end
				st       <= S_STAT;
			end

			S_STAT: begin
				DDRAM_ADDR     <= STAT_W;
				DDRAM_BURSTCNT <= 8'd1;
				DDRAM_BE       <= 8'hFF;
				DDRAM_DIN      <= {h_seq, field_cnt};
				DDRAM_WE       <= 1'b1;
				st             <= S_STAT2;
			end

			S_STAT2: begin            // second single-word write, once the first was accepted
				DDRAM_ADDR     <= STAT_W + 29'd1;
				DDRAM_BURSTCNT <= 8'd1;
				DDRAM_BE       <= 8'hFF;
				DDRAM_DIN      <= {13'd0, key_cnt, ps2_key, joy1, joy0};
				DDRAM_WE       <= 1'b1;
				st             <= S_DIAG;
			end
			S_DIAG: begin
				DDRAM_ADDR <= BASE_WORDS + 29'd16;
				DDRAM_BURSTCNT <= 8'd1;
				DDRAM_BE <= 8'hFF;
				DDRAM_DIN <= {tap_peak, tap_sequence[15:0], missed_lines, max_fetch_clocks};
				DDRAM_WE <= 1'b1;
				st <= S_DX;
			end

			S_DX: begin                  // where the dot is, for the ARM
				DDRAM_ADDR     <= BASE_WORDS + 29'd13;
				DDRAM_BURSTCNT <= 8'd1;
				DDRAM_BE       <= 8'hFF;
				DDRAM_DIN      <= {28'h5650000, scan_status, 7'd0, lvl, 6'd0, d_x};
				DDRAM_WE       <= 1'b1;
				st             <= S_IDLE;
			end

			S_LINE_SETUP: begin
				if (seg == 2'd3) begin
					row_off    <= seg_row * seg_sw;
					slot_base  <= BASE_WORDS + o_addr;
					plane_off  <= 29'd0;
					line_words <= {1'b0, o_w[9:1]};
					st         <= S_LINE_MUL;
				end
				else if (valid && ({22'd0, pend_row} < h_height)) begin
					row_off    <= seg_row * seg_sw;
					slot_base  <= BUF0_W + ({26'd0, h_buf} << 17) + ({26'd0, h_buf} << 15) + ({26'd0, h_buf} << 14);
					plane_off  <= (seg == 2'd0) ? 29'd0 : (seg == 2'd1) ? h_uoff[28:0] : h_voff[28:0];
					// words per row: RGB width/2, Y width/8, U/V width/16
					line_words <= (seg != 2'd0) ? {3'd0, h_width[9:4]} :
					              h_yuv         ? {2'd0, h_width[9:3]} :
					              (h_width > 32'd720) ? 9'd360 : h_width[9:1];
					st         <= S_LINE_MUL;
				end
				else if (osd_line) seg <= 2'd3;   // no picture row: only the overlay
				else st <= S_SPR;
			end

			S_SPR: begin                 // the sprite words, every line
				DDRAM_ADDR     <= SPR_W;
				DDRAM_BURSTCNT <= 8'd6;
				DDRAM_RD       <= 1'b1;
				scnt           <= 2'd0;
				st             <= S_SPR_WAIT;
			end

			S_SPR_WAIT: if (scnt == 3'd6) begin
				r_x   <= sw0[9:0];
				d_y   <= sw0[25:16];
				d_en  <= sw0[31];
				d_rgb <= sw0[55:32];
				b_x   <= sw1[9:0];
				b_y   <= sw1[25:16];
				b_en  <= sw1[31];
				b_w   <= sw1[41:32];
				b_h   <= sw1[57:48];
				b_rgb <= sw2[23:0];
				r_xmin <= sw2[41:32];
				r_xmax <= sw2[51:42];
				r_vx   <= sw2[59:52];
				r_load <= sw2[60];
				st    <= S_JOY;
			end

			S_JOY: begin                 // the pad, every line: a press is seen within 64 us
				DDRAM_ADDR     <= STAT_W + 29'd1;
				DDRAM_BURSTCNT <= 8'd1;
				DDRAM_BE       <= 8'hFF;
				DDRAM_DIN      <= {13'd0, key_cnt, ps2_key, joy1, joy0};
				DDRAM_WE       <= 1'b1;
				st             <= S_IDLE;
			end

			S_LINE_MUL: begin
				rd_addr    <= slot_base + plane_off + {9'd0, row_off};
				words_left <= line_words;
				wr_ptr     <= 9'd0;
				st         <= S_LINE_RD;
			end

			S_LINE_RD: begin
				if (words_left != 9'd0) begin
					DDRAM_ADDR     <= rd_addr;
					DDRAM_BURSTCNT <= burst_now;
					DDRAM_RD       <= 1'b1;
					burst_left     <= burst_now[5:0];
					rd_addr        <= rd_addr + {21'd0, burst_now};
					words_left     <= words_left - {1'b0, burst_now};
					st             <= S_LINE_WAIT;
				end
				else if (h_yuv && seg != 2'd2 && seg != 2'd3) begin
					seg <= seg + 2'd1;
					st  <= S_LINE_SETUP;
				end
				else if (seg != 2'd3 && osd_line) begin
					seg <= 2'd3;
					st  <= S_LINE_SETUP;
				end
				else st <= S_SPR;
			end

			S_LINE_WAIT: if (burst_left == 6'd0) st <= S_LINE_RD;

			default: st <= S_IDLE;
			endcase
		end
	end
end

// ---------------- pixel output ----------------
wire        row_ok = valid && ({22'd0, vc} < h_height);
wire        col_ok = ({21'd0, hc} < h_width);
wire [31:0] px     = hc[0] ? q0[63:32] : q0[31:0];

// YUV -> RGB, free-running 3-stage pipeline (8.8 fixed point, BT.601 limited)
wire  [7:0] ybyte = q0[{y_x_q[2:0], 3'b000} +: 8];
wire  [7:0] ubyte = q1[{y_x_q[3:1], 3'b000} +: 8];
wire  [7:0] vbyte = q2[{y_x_q[3:1], 3'b000} +: 8];

reg signed  [9:0] y16, u128, v128;
reg signed [19:0] yy, rv, gu, gv, bu;
reg signed [20:0] rs, gs, bs;
reg         [7:0] cr, cg, cb;
reg [23:0] rgb_delay0, rgb_delay1;   // the stage register is the third delay

function [7:0] clamp8(input signed [20:0] v);
	clamp8 = v[20] ? 8'd0 : (v[19:8] > 12'd255) ? 8'd255 : v[15:8];
endfunction

always @(posedge clk) begin
	y16  <= $signed({2'b00, ybyte}) - 10'sd16;
	u128 <= $signed({2'b00, ubyte}) - 10'sd128;
	v128 <= $signed({2'b00, vbyte}) - 10'sd128;

	yy <= y16  * 11'sd298;
	rv <= v128 * 11'sd409;
	gu <= u128 * 11'sd100;
	gv <= v128 * 11'sd208;
	bu <= u128 * 11'sd516;

	rs <= yy + rv + 21'sd128;
	gs <= yy - gu - gv + 21'sd128;
	bs <= yy + bu + 21'sd128;

	cr <= clamp8(rs);
	cg <= clamp8(gs);
	cb <= clamp8(bs);
	rgb_delay0 <= {cr, cg, cb};
	rgb_delay1 <= rgb_delay0;
end

// ---------------- ordered dither to 6 bits ----------------
// The analog board's DAC is a 6-bit R-2R ladder and the framework keeps only
// the top 6 bits of each channel. A 2x2 Bayer threshold (0,2 / 3,1) on the
// dropped two bits turns 8-bit gradients into a fine static texture instead of
// 64-level banding. Static on purpose: temporal dither flickers on a CRT.
wire [1:0] dth = {hc[0] ^ vc[0], vc[0]};   // (x,y): 00->0 10->2 01->3 11->1

function [7:0] dither8(input [7:0] v, input [1:0] d);
	dither8 = (v > 8'd252) ? 8'd255 : (v + {6'd0, d});
endfunction

wire        pic = row_ok && col_ok;
wire [7:0] sr = ~pic ? 8'd0 : h_yuv ? rgb_delay1[23:16] : px[23:16];
wire [7:0] sg = ~pic ? 8'd0 : h_yuv ? rgb_delay1[15:8] : px[15:8];
wire [7:0] sb = ~pic ? 8'd0 : h_yuv ? rgb_delay1[7:0] : px[7:0];

// ---------------- overlay blend ----------------
// straight alpha; a' = a + a[7] so 255 is fully the overlay
wire [31:0] opx = ox[0] ? q3[63:32] : q3[31:0];
wire  [7:0] oa  = in_osd ? opx[31:24] : 8'd0;
wire  [8:0] a9  = {1'b0, oa} + {8'd0, oa[7]};
wire  [8:0] ia9 = 9'd256 - a9;

// Stage register: the blend's operands, taken every clock, so the one before
// the output register's names the pixel on show (see la_ahead). It keeps the
// line buffer reads and the alpha sums out of the clock of the blend and
// brightness multiplies, which had only 0.12 ns to spare without it.
reg [7:0] s_r = 0, s_g = 0, s_b = 0, s_or = 0, s_og = 0, s_ob = 0;
reg [8:0] s_a = 0, s_ia = 9'd256;
always @(posedge clk) begin
	{s_r, s_g, s_b}    <= {sr, sg, sb};
	{s_or, s_og, s_ob} <= opx[23:0];
	{s_a, s_ia}        <= {a9, ia9};
end

function [7:0] mix(input [7:0] v, input [7:0] o, input [8:0] a, input [8:0] ia);
	reg [17:0] sum;
	begin
		sum = v * ia + o * a;
		mix = sum[15:8];
	end
endfunction

wire [7:0] mr = mix(s_r, s_or, s_a, s_ia);
wire [7:0] mg = mix(s_g, s_og, s_a, s_ia);
wire [7:0] mb = mix(s_b, s_ob, s_a, s_ia);

// ---------------- sprites ----------------
// the bar: a rectangle. The dot: a disc of radius 7 rows, widened 9/8 so
// it is round on the tube; half-widths per row from the centre.
wire        in_bar = b_en && (hc >= {1'b0, b_x}) && (hc < ({1'b0, b_x} + {1'b0, b_w})) &&
                     (vc >= b_y) && (vc < (b_y + b_h));
wire signed [11:0] ddy = $signed({2'b00, vc}) - $signed({2'b00, d_y});
wire signed [11:0] ddx = $signed({1'b0, hc}) - $signed({2'b00, d_x});
wire        [3:0] ady = ddy[11] ? (-ddy[3:0]) : ddy[3:0];
reg         [3:0] dhw;
always @(*) begin
	case (ady)
		4'd0: dhw = 4'd8;
		4'd1: dhw = 4'd8;
		4'd2: dhw = 4'd8;
		4'd3: dhw = 4'd7;
		4'd4: dhw = 4'd6;
		4'd5: dhw = 4'd6;
		4'd6: dhw = 4'd4;
		4'd7: dhw = 4'd2;
		default: dhw = 4'd0;
	endcase
end
wire in_dot = d_en && (ddy > -12'sd8) && (ddy < 12'sd8) &&
              (ddx > -$signed({8'd0, dhw})) && (ddx < $signed({8'd0, dhw}));

wire [7:0] fr = in_dot ? d_rgb[23:16] : in_bar ? b_rgb[23:16] : mr;
wire [7:0] fg = in_dot ? d_rgb[15:8]  : in_bar ? b_rgb[15:8]  : mg;
wire [7:0] fb = in_dot ? d_rgb[7:0]   : in_bar ? b_rgb[7:0]   : mb;

// ---------------- brightness ----------------
// last, so the picture, the overlay and the sprites dim together; ahead of
// the dither, which smooths the smaller range. 256 passes a value through.
function [7:0] scale8(input [7:0] v, input [8:0] l);
	reg [16:0] p;
	begin
		p = v * l;
		scale8 = p[15:8];
	end
endfunction

wire [7:0] lr = scale8(fr, lvl);
wire [7:0] lg = scale8(fg, lvl);
wire [7:0] lb = scale8(fb, lvl);

// ---------------- line ends ----------------
// Black guard bands at both ends of the line in the 15 kHz modes (see the
// header). Registered like in_osd: hc and active move only on ce_pix, so a
// clock later this still names the pixel the output register takes, and the
// compares stay out of the multiplies' path.
localparam [10:0] EDGE_L = 11'd12;
localparam [10:0] EDGE_R = 11'd8;
reg lit = 0;
always @(posedge clk)
	lit <= active && !(scan_status[1:0] < 2'd2 && (hc < EDGE_L || hc >= 11'd720 - EDGE_R));

always @(posedge clk) begin
	if (ce_pix) begin
		if (lit) {r, g, b} <= {dither8(lr, dth), dither8(lg, dth), dither8(lb, dth)};
		else     {r, g, b} <= 24'h000000;
	end
end

endmodule
