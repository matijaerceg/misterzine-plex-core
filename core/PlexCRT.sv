//============================================================================
//  PlexCRT - MisterZine Plex Core video and audio core
//
//  Native NTSC 480i and HDMI 480p, with a profile-based CRT safety lock.
//
//  Critically, for Y/C to work this core must:
//    * drive VGA_R/G/B natively on CLK_VIDEO/CE_PIXEL   (yc_out taps here)
//    * hold VGA_SCALER = 0   (asserting it routes the analog pins to ascal)
//    * hold VGA_DISABLE = 0
//    * NOT define MISTER_FB  (that would route through ascal too)
//    * NOT be built with MISTER_DISABLE_YC or MISTER_DUAL_SDRAM
//
//  GPL-3.0-or-later. See LICENSING.md; upstream files retain their notices.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign DDRAM_CLK = clk_sys;   // ddr_scanout drives the rest of the DDRAM port

assign VGA_SL        = 0;
assign VGA_SCALER    = 0;   // MUST stay 0 - see header
assign VGA_DISABLE   = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;

assign AUDIO_S   = 1;
wire [15:0] tap_sample;
wire [15:0] tap_peak;
wire [31:0] tap_sequence;
ui_tap ui_tap(.clk(clk_sys), .reset(reset), .sequence_in(tap_sequence), .sample(tap_sample), .peak(tap_peak));
assign AUDIO_L   = tap_sample;
assign AUDIO_R   = tap_sample;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Scale the complete 720x480 frame, including when native output is interlaced.
// Only HDMI aspect/size metadata changes; VGA timing and DE remain untouched.
// Legacy status[7] (square-pixel diagnostics) is deliberately ignored.
video_scale_int hdmi_scale
(
	.CLK_VIDEO(CLK_VIDEO),
	.HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
	.SCALE({2'b00, status[8]}),
	.hsize(12'd720), .vsize(12'd480),
	.arx_i(12'd4), .ary_i(12'd3),
	.arx_o(VIDEO_ARX), .ary_o(VIDEO_ARY)
);

`include "build_id.v"
localparam CONF_STR = {
	"MisterZine Plex Core;;",
	"-;",
	"D0-,HDMI aspect: 4:3;",
	"O[8],HDMI scaling,Normal,Integer height;",
	"O[6],Force 480i,Off,On;",
	"P1,HDMI setup help;",
	"P1-,Resolution: MiSTer INI;",
	"P1-;",
	"P1-,Full height: Normal scaling;",
	"P1-,  vscale_mode=0;",
	"P1-,  vscale_border=0;",
	"P1-;",
	"P1-,Smoother text:;",
	"P1-,  Video Processing filters;",
	"P1-,  Interpolation (Sharp);",
	"P1-;",
	"P1-,Force 480i:;",
	"P1-,  Off: app chooses;",
	"P1-,  On: interlaced output;",
	"P1-,  Not HDMI resolution;",
	"-;",
	// button order fixes joystick_0 bits 4..11 for the ARM menu (plexmenu.py)
	"J1,OK,Back,L,R;",
	"jn,A,B,L,R;",
	"R[0],Reset;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),
	.new_vmode(new_vmode),
	.video_rotated(1'b0),

	.buttons(buttons),
	.status(status),
	// Dim the fixed aspect information without making it selectable.
	.status_menumask(16'h0001),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);
wire [31:0] joystick_0, joystick_1;
wire [10:0] ps2_key;

// Tell the framework the video timing changed, so it re-measures and recomputes
// the Y/C subcarrier phase for the new raster.
reg new_vmode = 1'b0;
reg [1:0] scan_q = 2'd0;
always @(posedge clk_sys) begin
	scan_q <= scan_mode;
	if (scan_mode != scan_q) new_vmode <= ~new_vmode;
end

///////////////////////   CLOCKS   ///////////////////////////////
// 54 MHz -> CE_PIXEL 1-in-4 -> exactly 13.5 MHz, the BT.601 / NTSC rate.
// Kept deliberately high because yc_out synthesises the colour subcarrier at
// full CLK_VIDEO with no clock enable - a low pixel clock starves it.
wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

// status[9] is set by the app, in MiSTer's saved settings for this core, while
// 480p is the confirmed choice. MiSTer main loads it with the core, so the
// raster starts in 480p instead of switching from 480i once the app is up: a
// RetroTINK 4K in Direct Video locked onto the 480i raster and kept its pixel
// repetition after the switch, showing half the picture. It is also the mode
// to hold when the app's lease lapses.
wire [1:0] boot_mode = status[9] ? 2'd2 : 2'd0;
wire [1:0] app_mode;
wire app_fresh;
wire [1:0] requested_mode = status[6] ? 2'd0 :
                         app_fresh ? app_mode : boot_mode;
wire crt_locked;
wire [1:0] wanted_mode;
wire config_ready;
crt_profile_guard crt_profile_guard(
 .clk(clk_sys), .io_enable(HPS_BUS[34]), .io_strobe(HPS_BUS[33]),
 .io_din(HPS_BUS[31:16]), .requested_mode(requested_mode),
 .boot_progressive(status[9]),
 .locked(crt_locked), .safe_mode(wanted_mode), .ready(config_ready)
);
// No sync and no DE while the core is in reset or main has not configured it
// yet; the raster then starts in the mode the guard allows.
wire raster_off = reset | ~config_ready;
reg [1:0] scan_mode = 2'd0;
reg scan_vs = 0;
always @(posedge clk_sys) begin
	scan_vs <= vs;
	if (raster_off) scan_mode <= wanted_mode;
	else if (vs && !scan_vs) scan_mode <= wanted_mode;
end
wire       vs_at_hs  = 1'b1;   // default: textbook placement
wire       band_grey = 1'b1;
wire       force_card = 1'b0;
wire       ce_pix;
wire       hs, vs, hblank, vblank, f1;
wire [7:0] vr, vg, vb;
wire [10:0] hc;
wire  [9:0] vc, next_row;

crt480i crt480i
(
	.clk       (clk_sys),
	.reset     (raster_off),
	.mode      (scan_mode),
	.vs_at_hs  (vs_at_hs),
	.band_grey (band_grey),

	.ce_pix    (ce_pix),
	.hs        (hs),
	.vs        (vs),
	.hblank    (hblank),
	.vblank    (vblank),
	.field     (f1),
	.hc_o      (hc),
	.vc_o      (vc),
	.next_row  (next_row),

	.r         (vr),
	.g         (vg),
	.b         (vb)
);

// Frames from DDR3, written by the ARM. Stay black until the app is alive
// and its frame header is valid. Legacy diagnostic settings are ignored.
wire        ddr_valid;
wire  [7:0] dr, dg, db;
wire [31:0] ddr_field_cnt;

// Buffers live in the Linux framebuffer's memory (MiSTer_fb, physical
// 0x22001000, 8 MB) because /dev/fb0 gives the ARM a write-combined mapping,
// where /dev/mem is strongly ordered and several times slower to stream into.
// Nothing else touches that memory while a non-framebuffer core is running.
ddr_scanout #(.BASE_WORDS(29'h04400200)) ddr_scanout
(
	.clk              (clk_sys),
	.reset            (reset),

	.DDRAM_BUSY       (DDRAM_BUSY),
	.DDRAM_BURSTCNT   (DDRAM_BURSTCNT),
	.DDRAM_ADDR       (DDRAM_ADDR),
	.DDRAM_DOUT       (DDRAM_DOUT),
	.DDRAM_DOUT_READY (DDRAM_DOUT_READY),
	.DDRAM_RD         (DDRAM_RD),
	.DDRAM_DIN        (DDRAM_DIN),
	.DDRAM_BE         (DDRAM_BE),
	.DDRAM_WE         (DDRAM_WE),

	.ce_pix           (ce_pix),
	.hc               (hc),
	.vc               (vc),
	.next_row         (next_row),
	.active           (~(hblank | vblank | raster_off)),
	.vs               (vs),
	.joy0             (joystick_0[15:0]),
	.joy1             (joystick_1[15:0]),
	.ps2_key          (ps2_key),
	.scan_status      ({crt_locked, status[6], scan_mode}),
	.app_mode         (app_mode),
	.app_fresh        (app_fresh),
	.tap_sequence     (tap_sequence),
	.tap_peak         (tap_peak),

	.valid            (ddr_valid),
	.r                (dr),
	.g                (dg),
	.b                (db),
	.dbg_field_cnt    (ddr_field_cnt)
);

wire use_ddr = ddr_valid & app_fresh & ~force_card;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;

assign VGA_DE = ~(hblank | vblank | raster_off);
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_F1 = f1;           // the interlace field flag - template hardwires this to 0
assign VGA_R  = force_card ? vr : use_ddr ? dr : 8'd0;
assign VGA_G  = force_card ? vg : use_ddr ? dg : 8'd0;
assign VGA_B  = force_card ? vb : use_ddr ? db : 8'd0;

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
