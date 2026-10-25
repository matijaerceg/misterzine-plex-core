// h264/emu.sv -- MiSTer H264 core, top level (roadmap P3: the HPS interface)
//
// What the core is for (docs/roadmap.md, docs/architecture.md): an H.264 decode and
// presentation accelerator for HPS-side programs. A Linux program on the DE10-Nano's ARM
// (a Moonlight client, a Plex / Jellyfin client, a file player) does the networking and
// demux and hands the core compressed video and audio with presentation times; the
// fabric decodes, keeps A/V sync against one clock, and scans out on HDMI and analog.
//
// What THIS build does: brings up the MiSTer framework (OSD, HDMI + analog rasters), draws
// the idle screen (h264/idle_bars.sv), and carries the decoder (h264/dec/, forked from
// MiSTer_UMD_Video at cc595c6: docs/harvest.md) and the display path (the output queue, the
// scheduler, the reader on ram2), fed through the HPS interface: a ring of records a
// program on the ARM writes into DDR3, read on ram1 by h264/ring_rd.sv, with the status
// block written back every frame (h264/ring_stat.sv). docs/architecture.md "The HPS
// interface, v0.1". Every later phase adds modules under h264/ and wires them here.
//
// Port list: MiSTer's stock emu ports plus the framework edits inherited from
// MiSTer_UMD_Video's sys/ (marked UMD-FORK there): the two analog composite-sync ports
// (VGA_CS / VGA_CS_EN) and a second DDR3 master on ram2 (DDRAM2_*). The list MUST
// match the `emu emu (...)` instance in sys/sys_top.v exactly;
// tools/check_emu_wiring.py pins the seam.

module emu (
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,
	output        VGA_DISABLE,

	output        CLK_SYS,
	output        CLK_MEM,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,

	// UMD-FORK (inherited): composite sync generated from the core's OWN raster, with
	// the equalizing pulses the framework's csync module cannot produce. sys_top delays
	// it by CS_PIPE and uses it whenever VGA_CS_EN is high. Tied off until the 480i /
	// CRT work harvests csync_smpte.sv (docs/roadmap.md).
	output        VGA_CS,
	output        VGA_CS_EN,

	// Canonical MiSTer direction is OUTPUT: b[0] is the core's virtual OSD button.
	output  [1:0] BUTTONS,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,   // 2 bits, matching sys_top's `wire [1:0] audio_mix`

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// UMD-FORK (inherited): a second DDR3 master on ram2 (sys/sys_top.v). In UMD it is
	// the display reader's own port -- docs/hw_budget_and_lessons.md S2: occupancy, not
	// bandwidth. Idle until the display path is harvested (docs/roadmap.md P2).
	output        DDRAM2_CLK,
	input         DDRAM2_BUSY,
	output  [7:0] DDRAM2_BURSTCNT,
	output [28:0] DDRAM2_ADDR,
	input  [63:0] DDRAM2_DOUT,
	input         DDRAM2_DOUT_READY,
	output        DDRAM2_RD,
	output [63:0] DDRAM2_DIN,
	output  [7:0] DDRAM2_BE,
	output        DDRAM2_WE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	output [6:0]  USER_OUT,
	input  [6:0]  USER_IN,

	input         OSD_STATUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,

	input         CLK_AUDIO,
	output        LOCKED
);

// =========================================================================
// Clocks and reset
// =========================================================================
// sys_pll: 27 MHz clk_sys, 90 MHz clk_mem (DDRAM_CLK), 25 MHz spare, 96.43 MHz clk_dec
// (decoder compute domain; 81 before P5b). The instance MUST be named sys_pll:
// tools/fmax_check.sh finds clk_dec in the timing report by the hierarchical name
// emu|sys_pll|altera_pll_i|general[3]...
// vid_pll (hd_raster, docs/hd_raster.md S2): 81 MHz clk_vid = 3 x 27, CLK_VIDEO -- the raster side
// (sync_gen, the reader's and the overlay's read-outs, the output stage) on a dot enable, one clock
// in three on the 27 MHz rasters. Same crystal, unrelated phase: everything crosses (below).
wire clk_sys, clk_mem, clk_spare, clk_dec, locked;
sys_pll sys_pll (
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_sys),
	.outclk_1 (clk_mem),
	.outclk_2 (clk_spare),
	.outclk_3 (clk_dec),
	.locked   (locked)
);
wire clk_vid, vid_locked;
vid_pll vid_pll (
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_vid),
	.locked   (vid_locked)
);

// OSD "Reset" (status[0]) joins the framework reset. user_rst_qn is a REGISTERED copy
// because reset_n is consumed as an async clear all over the core (MiSTer_DVD's
// reasoning, kept). Declared here, driven beside hps_io below.
wire user_rst_qn;
wire reset_n = locked & ~RESET & user_rst_qn;

assign CLK_SYS   = clk_sys;
assign CLK_MEM   = clk_mem;
assign CLK_VIDEO = clk_vid;      // 81 MHz (hd_raster): CE_PIXEL marks the dots, one clock in three at 27 MHz
assign LOCKED    = locked & vid_locked;

// =========================================================================
// Version and the OSD definition (CONF_STR)
// =========================================================================
`include "build_id.v"            // `BUILD_DATE "yymmdd", generated by sys/build_id.tcl

// VERSION, shown in the OSD About line and recorded in the build manifest. A core that
// ships carries plex-<app version> of the MisterZine Plex release it first ships in;
// a later app-only release keeps it. Test builds can carry anything.
//   * <= 18 characters of letters, digits and . _ + - (build_release.sh checks):
//     stock Main truncates the About line at 30 chars and splits CONF_STR on , and ;.
//   * This string is INSIDE CONF_STR = inside the netlist, so changing it re-rolls the
//     fit. Set it before the build that will ship, not after.
`define CORE_VERSION "plex-dev-dither1"

// The OSD definition. Every option, button and file extension here MUST be documented
// in the manual: tools/docs_check.py parses this block (by its terminator, never a
// grep) and fails the check otherwise. Any change here re-rolls the fitter seed.
//
// No "S0" or "F" slot: this core's input is an HPS program, not a file the OSD picks
// (docs/architecture.md). D3 decided (2026-09-27): no developer file-load path either;
// the reference feeder (hps/h264play) is how a stream reaches the rig.
//
// The pad (interface 0.6, docs/architecture.md "Input (interface 0.6)"): the J line names the
// five controls used by the programs: OK, Back, optional page shortcuts and Pause/Play. "JN": the left stick
// is not turned into d-pad bits. "jn": Main's automatic map by name. The compact J-line
// button bits are translated below to the original input-region positions used by the app.
// Never "J1" (the keyboard would become player 1's pad) or "X" (no OSD).
//
// The actions (interface 0.8, docs/architecture.md "The OSD's actions (0.8)", decided with the
// maintainer 2026-09-30, docs/moonlight.md M11): two R lines a program acts on, generic names
// (the core serves any program). Main pulses the bit (set, cleared) and closes the OSD; h264/
// ring_in.sv queues the edge as an ACTION event. Both entries exist now so the OSD's layout
// never changes when a program starts using the second (the Moonlight client: its menu, later).
//
// Legacy status positions remain allocated for the HPS settings API: [2:1] shape, [4:3]
// deinterlace, [7] HDMI deinterlace, [9:8] legacy Analog Aspect (hidden), [16:15] Anti-Twitter mirror,
// [17:18] program actions, [19] free (reserved). The display policy adds [22:20] profile,
// [23] legacy match refresh (ignored), [24] playback 240p, [25] film speed,
// [26] free (reserved), and [28:27] refresh-match mode. CONF_STR stays at v1 so existing
// HPS values remain intact; the new profile defaults to 480i60.
// [30] Gradient Dither defaults to On; bit 30 disables final RGB rounding dither.
// The first entry is the core's name: the OSD title, MiSTer.ini's per-core section and
// /tmp/CORENAME (what the app and jfplay --core-name test for), whatever the rbf is called.
localparam CONF_STR = {
	"MisterZine Plex Core;;",
	"-;",
	"O[22:20],Output Mode,480i60,480p60,576i50,576p50,Native HDMI;",
	"O[27],Refresh Rate Match,Off,50/60;",
	"D2O[24],240p Playback,Off,On;",
	"D1O[25],Play 24fps at 25fps,Off,On;",
	"O[2],Display Shape,4:3,16:9;",
	"H0O[4:3],Deinterlace,Weave,Bob,Blend;",
	"h0O[7],HDMI Deinterlace,Weave,Bob;",
	"O[29],De-flicker,On,Off;",
	"O[30],Gradient Dither,On,Off;",
	"-;",
	"-;",
	"R[0],Reset;",
	"JN,OK,Back,Page Back,Page Forward,Pause/Play;",
	"jn,A,B,L,R,Start;",
	"v,1;",
	"V,",`CORE_VERSION," ",`BUILD_DATE,";"
};

// =========================================================================
// HPS IO: the OSD. No sd blocks, no file mount, no download (D3: the ioctl path that was
// Phase 2's stand-in input is gone; ioctl_wait is an input of hps_io, tied low).
// =========================================================================
wire  [1:0] buttons;
wire [127:0] status;
// interface 0.13: the program's rumble back to Main (ring_rd, clk_sys; declared before hps_io uses it)
wire [95:0] rumble;                  // (0.13) program words 36-38 as passed to Main (0 outside a session)
wire [31:0] rum_changes;
// interface 0.6: Main's input as hps_io hands it over (clk_sys)
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3, joystick_4, joystick_5;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1, joystick_l_analog_2,
            joystick_l_analog_3, joystick_l_analog_4, joystick_l_analog_5;
wire [15:0] joystick_r_analog_0, joystick_r_analog_1, joystick_r_analog_2,
            joystick_r_analog_3, joystick_r_analog_4, joystick_r_analog_5;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire [15:0] ps2_mouse_ext;
wire        forced_scandoubler, direct_video;
wire        ini_vga_scaler, ini_csync, ini_ypbpr, ini_sog, cfg_seen, cfg_wr;
// Video Output (P6, docs/analog.md; MiSTer_DVD's design): the ONE resolved output mode --
// the 480i raster (pixel repetition, fields, the half-line) for HDMI and the analog pins
// alike, the 480p raster, or (hdmi_raster stage 2) the native raster. Assigned below the
// display (it holds while a stream plays).
wire  [1:0] video_out_eff;            // 1 Interlaced, 2 Progressive, 3 Native (HDMI): Auto resolved
wire        interlaced_eff;
wire        prog240_eff;
wire        raster_il_eff = interlaced_eff && !prog240_eff;
// interface 0.4: the program's settings request (ring_rd's engine -> h264/osd_req.sv -> hps_io's
// status_in / status_set: Main adopts it as if the user had chosen it)
wire [127:0] req_status_in;
wire         req_status_set;
wire  [1:0] raster_std;             // the raster standard: 0 59.94 Hz, 1 60.00 Hz, 2 50 Hz (625 lines)
wire        raster_pal;             // raster_std == 2: 576 active lines (Refresh Rate, below)

// OSD R0 Reset -> core reset (see reset_n above)
reg user_rst_q = 1'b0;
always @(posedge clk_sys) user_rst_q <= status[0];
assign user_rst_qn = ~user_rst_q;

hps_io #(.CONF_STR(CONF_STR)) hps_io_inst (
	.clk_sys        (clk_sys),
	.HPS_BUS        (HPS_BUS),
	.EXT_BUS        (),

	.ioctl_download (),
	.ioctl_wr       (),
	.ioctl_addr     (),
	.ioctl_dout     (),
	.ioctl_index    (),
	.ioctl_wait     (1'b0),

	.buttons        (buttons),
	.status         (status),
	.status_in      (req_status_in),        // 0.4: a program's settings request (h264/osd_req.sv)
	.status_set     (req_status_set),

	.forced_scandoubler (forced_scandoubler),
	.gamma_bus      (),
	.direct_video   (direct_video),
	.ini_vga_scaler (ini_vga_scaler),
	.ini_csync      (ini_csync),
	.ini_ypbpr      (ini_ypbpr),
	.ini_sog        (ini_sog),
	.cfg_seen       (cfg_seen),
	.cfg_wr         (cfg_wr),
	// the menu mask: bit 0 = the 480i raster is on (CONF_STR's H0 / h0 swap the in-core
	// Deinterlace line for ascal's HDMI Bob / Weave: the menu never offers what the
	// raster cannot do, docs/display.md S1)
	.status_menumask ({13'd0, 1'b0, !film_speed_allowed, interlaced_eff}),

	// interface 0.6: the input, mirrored into the control block by h264/ring_in.sv
	.joystick_0     (joystick_0), .joystick_1 (joystick_1), .joystick_2 (joystick_2),
	.joystick_3     (joystick_3), .joystick_4 (joystick_4), .joystick_5 (joystick_5),
	.joystick_l_analog_0 (joystick_l_analog_0), .joystick_l_analog_1 (joystick_l_analog_1),
	.joystick_l_analog_2 (joystick_l_analog_2), .joystick_l_analog_3 (joystick_l_analog_3),
	.joystick_l_analog_4 (joystick_l_analog_4), .joystick_l_analog_5 (joystick_l_analog_5),
	.joystick_r_analog_0 (joystick_r_analog_0), .joystick_r_analog_1 (joystick_r_analog_1),
	.joystick_r_analog_2 (joystick_r_analog_2), .joystick_r_analog_3 (joystick_r_analog_3),
	.joystick_r_analog_4 (joystick_r_analog_4), .joystick_r_analog_5 (joystick_r_analog_5),
	// (interface 0.13) the program's rumble (words 36-38, during a session): Main plays it on the
	// player's pad (docs/architecture.md "Rumble (interface 0.13)")
	.joystick_0_rumble (rumble[15:0]),  .joystick_1_rumble (rumble[31:16]), .joystick_2_rumble (rumble[47:32]),
	.joystick_3_rumble (rumble[63:48]), .joystick_4_rumble (rumble[79:64]), .joystick_5_rumble (rumble[95:80]),
	.ps2_key        (ps2_key),
	.ps2_mouse      (ps2_mouse),
	.ps2_mouse_ext  (ps2_mouse_ext),

	// No virtual disk: the sd request side is tied idle.
	.sd_lba         ('{32'd0}),
	.sd_blk_cnt     ('{6'd0}),
	.sd_rd          (1'b0),
	.sd_wr          (1'b0),
	.sd_buff_din    ('{8'd0})
);

// No startup OSD pop (UMD pops the file picker when nothing is mounted): an HPS
// program launches this core and feeds it, so there is nothing for the user to pick.
assign BUTTONS = 2'b00;

// =========================================================================
// The PLL-lock resets (every DDR3 master, the status block: never RESET -- a master reset
// while a request is held under waitrequest withdraws it, UMD's reload hang) and the
// per-stream reset.
// =========================================================================
wire mem_lock_n, lock_sys_n, lock_dec_n;
cdc_reset mem_lock_cdc (
	.clk       (clk_mem),
	.rst_n_in  (locked),
	.rst_n_out (mem_lock_n)
);
cdc_reset sys_lock_cdc (
	.clk       (clk_sys),
	.rst_n_in  (locked),
	.rst_n_out (lock_sys_n)
);
// (hd_raster) the raster side's resets on clk_vid: the PLL locks; the framework / OSD reset; the
// per-stream reset (the reader's raster side) -- each released through two clk_vid flops
wire vid_lock_n, vid_rst_n, vid_fe_rst_n;
cdc_reset vid_lock_cdc (
	.clk       (clk_vid),
	.rst_n_in  (locked & vid_locked),
	.rst_n_out (vid_lock_n)
);
cdc_reset vid_rst_cdc (
	.clk       (clk_vid),
	.rst_n_in  (reset_n & vid_locked),
	.rst_n_out (vid_rst_n)
);
cdc_reset dec_lock_cdc (
	.clk       (clk_dec),
	.rst_n_in  (locked),
	.rst_n_out (lock_dec_n)
);

// =========================================================================
// The HPS interface's reader (h264/ring_rd.sv; docs/architecture.md "The HPS interface,
// v0.1", decided 2026-09-27): the ring at byte 0x3180_0000 (8 MB) and the control block at
// 0x3140_0000, both on ram1 through ddr_mux2's master B. Its clk_mem engine polls the
// program's write index and nonce, fetches the records and writes the status block; its
// clk_sys parser checks every record and hands the decoder {byte, PTS mark, AU end}. It
// owns the per-stream reset: fe_rst_n = reset_n & ~stream_clr (a session start and every
// DISCONTINUITY reset the decoder, the DPB's master (the abort) and the display). The
// parser runs on reset_n alone: the records behind a DISCONTINUITY are the next stream.
// END_OF_STREAM is vidfeed_cdc's flush level (the decoder drains, the last picture stays).
// =========================================================================
wire [28:0] rb_address;
wire  [7:0] rb_burstcount;
wire        rb_read, rb_write, rb_waitrequest, rb_readdatavalid;
wire [63:0] rb_writedata, rb_readdata;
wire  [7:0] rr_byte;
wire        rr_mark, rr_au_end, rr_valid, rr_ready, stream_clr, rr_eos, rr_ll, rr_gfx;
wire [15:0] rr_gfx_mismatch;        // interface 0.4: VIDEO_AUs whose GRAPHICS differs from the stream's first
wire  [2:0] rr_colour;              // (0.16, docs/colour.md) the stream's first VIDEO_AU's colour (0 auto)
wire [15:0] rr_colour_mismatch;     // (0.16) VIDEO_AUs whose colour differs from it (word 86)
wire [31:0] rr_set_word;            // interface 0.4: the program's settings request (clk_mem) and its toggle
wire        rr_set_tog;
wire [127:0] rr_geom_data;          // interface 1.2: {clip viewport word 88, picture rectangle word 39}
wire [7:0] rr_geom_ack_seq;
wire [1:0] rr_geom_error;
wire        v_clip_en;
wire [11:0] v_clip_x, v_clip_y, v_clip_w, v_clip_h;
wire [32:0] rr_pts;
wire        disp_ended;                   // disp_ctl: the display took the stream's END
wire [63:0] st_word;
wire  [6:0] st_ix;                  // 0.5: words 0-31 and 40-47; 0.6: and 48-71 (the input region)
wire        st_wr, st_grp;
wire  [6:0] st_free;                // 0.6: the status FIFO's free words (ring_stat checks each job's room)
// interface 0.5 (Phase 4): the audio path's side of the reader
wire        ad_push, ad_ptsv, ad_room, a_hold_v, aud_idle, rr_vid_seen;
wire [31:0] ad_pos, a_hold_idx, aud_hold_bytes;
wire [22:0] ad_len;
wire [32:0] ad_pts;
wire        af_go, af_busy, af_valid, af_empty, af_rd;
wire [31:0] af_addr;
wire  [3:0] af_n;
wire [63:0] af_dout;
wire        ctl_pause, ctl_err;          // word 34 as applied (the pause during a session)
wire  [7:0] ctl_atten;
wire        rr_sess, rr_eos_seen;
wire  [7:0] rr_state, rr_err;
wire [31:0] rr_err_pos;
wire [63:0] rr_err_word;
wire [31:0] rr_n_au, rr_n_audio, rr_n_pad, rr_n_streams, rr_es_bytes, rr_ll_mismatch;
wire [31:0] rr_read_index, rr_ack_nonce, rr_n_polls, rr_n_bursts, rr_eng_widx;
wire  [7:0] rr_eng_err;
wire        rr_eng_session;
// interface 0.15: a PICTURE's descriptor, ring_rd (clk_sys) -> pic_in (clk_dec), below
wire        pd_req, pd_ps_v, pd_timing_v, pd_pts_v, pd_eos, pd_ack, pd_busy, rr_pic_mode;
wire  [4:0] pd_store;
wire  [7:0] pd_w, pd_hf;
wire  [1:0] pd_struct;
wire  [3:0] pd_ps;
wire [39:0] pd_aspect, pd_crop;
wire  [2:0] pd_colour;              // (0.16) a PICTURE's colour (0 auto)
wire [31:0] pd_nuit, pd_ts;
wire [32:0] pd_pts;
ring_rd ring_rd_inst (
	.clk            (clk_sys),
	.rst_n          (reset_n),
	.lrst_n         (lock_sys_n),
	.es_byte        (rr_byte),
	.es_mark        (rr_mark),
	.es_pts         (rr_pts),
	.es_au_end      (rr_au_end),
	.es_valid       (rr_valid),
	.es_ready       (rr_ready),
	.stream_clr     (stream_clr),
	.eos            (rr_eos),
	.ll_mode        (rr_ll),
	.gfx_mode       (rr_gfx),               // 0.4: the stream declared rendered graphics (Anti-Twitter Auto)
	.vid_seen       (rr_vid_seen),          // 0.5: the stream has had a VIDEO_AU
	.disp_ended     (disp_ended),
	.ad_push        (ad_push),              // 0.5: AUDIO descriptors to aud_play, the held index back
	.ad_pos         (ad_pos),
	.ad_len         (ad_len),
	.ad_pts         (ad_pts),
	.ad_ptsv        (ad_ptsv),
	.ad_room        (ad_room),
	.a_hold_v       (a_hold_v),
	.a_hold_idx     (a_hold_idx),
	.aud_idle       (aud_idle),
	.hold_bytes     (aud_hold_bytes),
	.af_go          (af_go),                // 0.5: the audio's fetch through the engine
	.af_addr        (af_addr),
	.af_n           (af_n),
	.af_busy        (af_busy),
	.af_dout        (af_dout),
	.af_valid       (af_valid),
	.af_empty       (af_empty),
	.af_rd          (af_rd),
	.ctl_pause      (ctl_pause),            // 0.5: program word 34
	.ctl_err        (ctl_err),
	.ctl_atten      (ctl_atten),
	.rumble         (rumble),               // 0.13: program words 36-38, into hps_io
	.rum_changes    (rum_changes),
	.st_word        (st_word),
	.st_ix          (st_ix),
	.st_wr          (st_wr),
	.st_grp         (st_grp),
	.st_free        (st_free),
	.sess           (rr_sess),
	.state          (rr_state),
	.err            (rr_err),
	.err_pos        (rr_err_pos),
	.err_word       (rr_err_word),
	.eos_seen       (rr_eos_seen),
	.n_au           (rr_n_au),
	.n_audio        (rr_n_audio),
	.n_pad          (rr_n_pad),
	.n_streams      (rr_n_streams),
	.es_bytes       (rr_es_bytes),
	.ll_mismatch    (rr_ll_mismatch),
	.gfx_mismatch   (rr_gfx_mismatch),
	.colour_mode    (rr_colour),            // (0.16, docs/colour.md)
	.colour_mismatch(rr_colour_mismatch),
	.pd_req         (pd_req),               // 0.15: a PICTURE's descriptor to pic_in
	.pd_store       (pd_store),
	.pd_w           (pd_w),
	.pd_hf          (pd_hf),
	.pd_struct      (pd_struct),
	.pd_ps          (pd_ps),
	.pd_ps_v        (pd_ps_v),
	.pd_aspect      (pd_aspect),
	.pd_colour      (pd_colour),            // (0.16)
	.pd_timing_v    (pd_timing_v),
	.pd_nuit        (pd_nuit),
	.pd_ts          (pd_ts),
	.pd_crop        (pd_crop),
	.pd_pts         (pd_pts),
	.pd_pts_v       (pd_pts_v),
	.pd_eos         (pd_eos),
	.pd_ack         (pd_ack),
	.pd_busy        (pd_busy),
	.pic_mode       (rr_pic_mode),
	.mclk           (clk_mem),
	.mrst_n         (mem_lock_n),
	.b_address      (rb_address),
	.b_burstcount   (rb_burstcount),
	.b_read         (rb_read),
	.b_write        (rb_write),
	.b_writedata    (rb_writedata),
	.b_waitrequest  (rb_waitrequest),
	.b_readdata     (rb_readdata),
	.b_readdatavalid(rb_readdatavalid),
	.read_index     (rr_read_index),
	.ack_nonce      (rr_ack_nonce),
	.n_polls        (rr_n_polls),
	.n_bursts       (rr_n_bursts),
	.eng_err        (rr_eng_err),
	.eng_session    (rr_eng_session),
	.set_word       (rr_set_word),           // 0.4: the settings request (clk_mem, with its toggle)
	.set_tog        (rr_set_tog),
	.geom_data      (rr_geom_data),
	.geom_ack_seq   (rr_geom_ack_seq),
	.geom_error     (rr_geom_error),
	.eng_widx       (rr_eng_widx)
);

// ---- interface 0.4: the program's settings request (h264/osd_req.sv) ----
// ring_rd's engine hands each new request (program word 35) over with a toggle; osd_req
// checks it, merges it into the menu's current settings and raises hps_io's status_set --
// Main adopts the new settings as if the user had chosen them (docs/architecture.md).
wire  [7:0] req_seq;
wire  [2:0] req_err;
osd_req osd_req_inst (
	.clk        (clk_sys),
	.rst_n      (reset_n),
	.status     (status),
	.set_word   (rr_set_word),
	.set_tog    (rr_set_tog),
	.status_in  (req_status_in),
	.status_set (req_status_set),
	.seq        (req_seq),
	.err        (req_err),
	.n_applied  ()
);

wire fe_rst_n = reset_n & ~stream_clr;
// (hd_raster) into clk_vid for the reader's raster side (vid_fe_rst_n declared with the vid resets)
cdc_reset vid_fe_cdc (
	.clk       (clk_vid),
	.rst_n_in  (fe_rst_n & vid_locked),
	.rst_n_out (vid_fe_rst_n)
);
wire fe_rst_dec_n;
cdc_reset fe_rst_cdc (
	.clk       (clk_dec),
	.rst_n_in  (fe_rst_n),
	.rst_n_out (fe_rst_dec_n)
);

// The bytes into clk_dec. es_au_end is carried by the reader but not yet by this crossing
// (roadmap P3e brings the sideband and the decoder's early close).
wire [41:0] es_data;                      // {pts[32:0], mark, byte}
wire        es_valid, es_ready, es_flush, fe_flushed;
vidfeed_cdc #(.DW(42)) vidfeed_cdc_inst (
	.wr_clk     (clk_sys),
	.wr_rst_n   (fe_rst_n),
	.wr_data    ({rr_pts, rr_mark, rr_byte}),
	.wr_valid   (rr_valid),
	.wr_ready   (rr_ready),
	.wr_flush   (rr_eos),                 // END_OF_STREAM consumed: every byte was handed over before it
	.rd_clk     (clk_dec),
	.rd_rst_n   (fe_rst_dec_n),
	.rd_data    (es_data),
	.rd_valid   (es_valid),
	.rd_ready   (es_ready),
	.rd_flush   (es_flush),
	.rd_flushed (fe_flushed)
);

// =========================================================================
// The H.264 front end (h264/dec/h264_top.sv) on clk_dec. docs/h264_frontend.md S6 (the
// UMD design, harvested at cc595c6). h264_top's own `clear` is tied off: fe_rst_n resets
// the whole front end, the CDC FIFO's two sides included. Its syntax elements go to the
// reconstruction, whose FIFO back-pressures it. Its counters are the status block's
// clk_dec words (ring_words_dec, below).
// =========================================================================
wire        se_valid, se_ready;
wire [31:0] fe_nal, fe_slice, fe_pic, fe_refused, fe_err, fe_pt_missing, fe_sei_err, fe_pts_tag, fe_pts_drop;
wire  [3:0] fe_refused_code, fe_err_code, fe_pic_struct;
wire [39:0] fe_bins;
wire  [7:0] se_kind, se_aux;
wire [31:0] se_val;
h264_top h264_top_inst (
	.clk           (clk_dec),
	.rst_n         (fe_rst_dec_n),
	.clear         (1'b0),
	.es_byte       (es_data[7:0]),
	.es_valid      (es_valid),
	.es_ready      (es_ready),
	.es_flush      (es_flush),
	.es_mark       (es_data[8]),
	.es_pts        (es_data[41:9]),
	.se_valid      (se_valid),
	.se_ready      (se_ready),            // the reconstruction's SE FIFO
	.se_kind       (se_kind),
	.se_aux        (se_aux),
	.se_val        (se_val),
	.sp_pps        (),
	.sp_sps        (),
	.sp_slice_type (),
	.sp_field      (),
	.sp_bottom     (),
	.sp_idr        (),
	.sp_frame_num  (),
	.sp_poc_lsb    (),
	.busy          (),
	.nal_count     (fe_nal),
	.slice_count   (fe_slice),
	.pic_count     (fe_pic),
	.sps_count     (),
	.pps_count     (),
	.refused_count (fe_refused),
	.refused_code  (fe_refused_code),
	.err_count     (fe_err),
	.err_code      (fe_err_code),
	.bin_total     (fe_bins),
	.pt_seen_count    (),
	.pt_missing_count (fe_pt_missing),
	.pt_bad_count     (),
	.sei_err_count    (fe_sei_err),
	.pts_tag_count    (fe_pts_tag),
	.pts_drop_count   (fe_pts_drop),
	.last_pic_struct  (fe_pic_struct)
);

// =========================================================================
// Raster (clk_vid since hd_raster: docs/hd_raster.md S3)
// =========================================================================
// The raster side -- sync_gen, the reader's and the overlay's read-outs, idle_bars, vid_out -- runs
// on clk_vid and advances on ce_dot: one clock in three (tick27, the 27 MHz dot) on the fitted
// rasters, so every 27 MHz raster reaches the pins exactly as it did on clk_sys; EVERY clock on the
// native raster (stage B, docs/hd_raster.md §4: 3F dots a frame) once its frame has begun on a tick --
// sync_gen makes ce_dot (its `dot`) from the tick and the raster it is scanning. Everything it reads from clk_sys arrives as ONE
// bundle (v_*, a continuous cdc_snap below, where its sources are declared); its counters go back
// through another; its frame events through two pulses (frame_sys, frame0_sys).
reg  [1:0] ce_ph;
always @(posedge clk_vid or negedge vid_lock_n)
	if (!vid_lock_n) ce_ph <= 2'd0;
	else             ce_ph <= (ce_ph == 2'd2) ? 2'd0 : ce_ph + 2'd1;
wire        tick27 = (ce_ph == 2'd2);
wire        ce_dot;                       // sync_gen's dot: tick27, or every clock native
wire        v_il, v_prog240, v_pal;                  // the bundle (clk_vid): the raster's mode
wire  [1:0] v_std;
wire        v_nat;                        // ... raster_geom's geometry
wire [11:0] v_rw, v_rh, v_l, v_nt, v_last;
wire        v_sh_valid, v_sh_field, v_sh_parity, v_sh_single;   // ... the shown picture (disp_ctl)
wire  [4:0] v_sh_store;
wire  [7:0] v_sh_w, v_sh_hf;
wire  [1:0] v_deint;                      // ... the Deinterlace menu
wire  [2:0] v_colour;                     // ... (0.16) the shown picture's colour code
wire  [5:0] v_siting;                     // ... (docs/chroma.md §4) and its chroma siting
wire [12:0] v_fit_ow, v_fit_oh;           // ... the fit (disp_fit)
wire [13:0] v_fit_ox0, v_fit_oy0;
wire [27:0] v_fit_sx, v_fit_sy;
wire  [1:0] v_fit_dh_l2, v_fit_dv_l2;
wire [11:0] v_fit_lx, v_fit_ty, v_fit_wc, v_fit_hc;
wire  [2:0] v_fit_hpf, v_fit_vpf;        // ... (§11b) the pre-filters
wire        v_sess, v_at_en, v_idle_vis;  // ... the overlay's session and anti-twitter, the idle screen
wire [11:0] h_pos, v_pos;
wire        pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
wire        sg_mode_il;                   // the mode sync_gen ran its frame in (frame0's tag)
wire        sg_mode_240p;
wire  [1:0] sg_mode_std;
// the native raster (docs/hdmi_raster.md stage 2: h264/raster_geom.sv, below) and the frame sync_gen
// is scanning (the reader's and the overlay's wrap)
wire  [1:0] geom_mode;                    // 0 fitted, 1 native, 2 native asked but fell back
wire [11:0] geom_rw, geom_rh, geom_l, geom_nt, geom_last;
wire        geom_disp;                    // native at the HDMI display's shape
wire        geom_nat = (geom_mode == 2'd1);
wire [11:0] rast_lines, rast_last;
sync_gen sync_gen_inst (
	.clk        (clk_vid),
	.clk_en     (tick27),             // (hd_raster) the 27 MHz tick
	.dot        (ce_dot),             // ... and the raster's dot it makes of it (every clock native)
	.rst_n      (vid_rst_n),
	.interlaced (v_il),
	.prog240    (v_prog240),
	.std        (v_std),              // P6 steps 5 / 6: 59.94 / 60.00 / 50 Hz (Refresh Rate, below)
	.nat        (v_nat),              // stage 2: the native raster, taken at a frame's first dot
	.g_w        (v_rw),
	.g_h        (v_rh),
	.g_l        (v_l),
	.g_nt       (v_nt),
	.g_last     (v_last),
	.lines      (rast_lines),
	.last_line  (rast_last),
	.h_pos      (h_pos),
	.v_pos      (v_pos),
	.pixel_en   (pixel_en),
	.h_sync     (h_sync),
	.v_sync     (v_sync),
	.h_blank    (h_blank),
	.v_blank    (v_blank),
	.frame_tick (frame_tick),
	.field      (field),
	.ce_pix     (ce_pix),
	.mode_il    (sg_mode_il),
	.mode_std   (sg_mode_std),
	.mode_240p  (sg_mode_240p)
);

// The raster's frame events into clk_sys: every refresh (ring_stat's and ring_in's frame), and the
// top field's (a frame's) first dot -- disp_ctl phases its tick and refresh grid there. The second
// carries the mode the raster ran that frame in (quasi-static: it changes only at a restart, a frame
// before the next frame0), and disp_ctl takes it only when that is ITS mode: after a mode change a
// frame start of the old raster, crossing late, must not align the grid (docs/hd_raster.md S3).
wire frame_sys, f0_sys;
cdc_pulse frame_xing (
	.src_clk   (clk_vid),
	.src_rst_n (vid_lock_n),
	.src_pulse (ce_dot & frame_tick),
	.dst_clk   (clk_sys),
	.dst_rst_n (lock_sys_n),
	.dst_pulse (frame_sys)
);
cdc_pulse f0_xing (
	.src_clk   (clk_vid),
	.src_rst_n (vid_lock_n),
	.src_pulse (ce_dot & frame_tick & (v_pos == 12'd0)),
	.dst_clk   (clk_sys),
	.dst_rst_n (lock_sys_n),
	.dst_pulse (f0_sys)
);
reg  [3:0] f0_tag_s1 = 4'd0, f0_tag_s2 = 4'd0;
always @(posedge clk_sys) begin f0_tag_s1 <= {sg_mode_240p, sg_mode_il, sg_mode_std}; f0_tag_s2 <= f0_tag_s1; end
wire       frame0_sys = f0_sys && (f0_tag_s2 == {prog240_eff, raster_il_eff, raster_std});

// =========================================================================
// The reconstruction (h264/dec/recon_top.sv), its DPB client on clk_mem, the output
// queue (h264/recon_out.sv: the stores in OUTPUT order, C.4.5.3), the display's control
// (h264/disp_ctl.sv + disp_sched.sv) and reader (h264/disp_reader.sv). UMD's design,
// harvested at cc595c6: docs/h264_recon.md S4, docs/display.md S6-S8.
//
// Crossings: recon_out. A store the output process emits is held (disp_hold) from that
// clk_dec cycle until the display's release comes back through recon_out's release FIFO,
// so no picture is written while it is queued or shown.
//
// Resets: the reconstruction takes fe_rst_dec_n on clk_dec and the same reset released
// into clk_mem (fe_rst_mem_n) for its DPB client. A new stream can land inside a DDR3
// write burst, so the port mux (h264/ddr_mux2.sv) is never reset with the decoder: it
// ABORTS the decoder's master, holds a request the port had not yet accepted until it is
// (an Avalon request is never withdrawn under waitrequest), completes an open burst with
// masked beats and swallows the outstanding read beats.
//
// mem_lock_n: every master that drives a DDR3 port directly (the mux, its abort
// register, the display reader's fetch side) resets with the PLL lock alone, never
// RESET: a master reset while a request is held under waitrequest withdraws it, and the
// HPS f2sdram port then stops returning read beats (UMD's reload hang,
// docs/hil_harness.md). Pinned by tools/check_emu_wiring.py.
//
// ram1 carries the decoder's DPB (ddr_mux2 master A) and the HPS interface's ring and
// control block (master B: h264/ring_rd.sv, above; docs/architecture.md "Memory ports").
// The display reads through its own port, ram2 (DDRAM2_*; docs/hw_budget_and_lessons.md
// S2: occupancy, not bandwidth). DPB: 20 stores of 2 MiB at word 0x0640_0000 (byte
// 0x3200_0000, above the ring; h264_pkg NSTORE; docs/architecture.md).
// =========================================================================
wire fe_rst_mem_n;
cdc_reset fe_rst_mem_cdc (
	.clk       (clk_mem),
	.rst_n_in  (fe_rst_n),
	.rst_n_out (fe_rst_mem_n)
);
// the abort, synchronous to clk_mem (fe_rst_mem_n asserts asynchronously)
reg [1:0] dpb_abort_q;
always @(posedge clk_mem or negedge mem_lock_n) begin
	if (!mem_lock_n) dpb_abort_q <= 2'b11;
	else            dpb_abort_q <= {dpb_abort_q[0], ~fe_rst_mem_n};
end

wire [28:0] dpb_address;
wire  [7:0] dpb_burstcount, dpb_byteenable;
wire        dpb_read, dpb_write, dpb_waitrequest, dpb_readdatavalid;
wire [63:0] dpb_writedata, dpb_readdata;
wire [19:0] disp_hold;                    // one bit per DPB store (h264_pkg NSTORE)
// the output process: per picture its display facts (pinfo_*), per store shown an
// emission (emit_*), the end-of-stream flush (eos_done)
wire        pi_we, pi_second, pi_ps_v, pi_pts_v, pi_idr, pi_timing_v;
wire [31:0] pi_nuit, pi_ts;
wire  [4:0] pi_store;
wire  [7:0] pi_w, pi_hf;
wire [40:0] pi_crop;
wire [39:0] pi_aspect;
wire  [2:0] pi_colour;              // (0.16) recon_top: the picture's colour code, its flag and tags
wire        pi_col_unsup;
wire [25:0] pi_col_tags;
wire  [5:0] pi_siting;              // (docs/chroma.md §4) recon_top: the picture's chroma siting
wire  [3:0] pi_ps;
wire [32:0] pi_pts;
wire        em_valid, em_unpaired, em_first_bot, em_frame, em_dec_t, em_dec_b, rc_eos_done;
wire  [4:0] em_store;
wire [31:0] rc_out_dropped, rc_out_direct, rc_out_over, rc_stall, rc_pic, rc_mb, rc_err, rc_ref_size, rc_nrf_late;
wire  [4:0] rc_dpb_fill;
wire  [3:0] rc_err_code;
// (Phase 4, interface 0.5) the pause freezes the display, which then holds its stores by
// design: the freeze (ring_rd's ctl_pause, clk_sys) reaches recon_dpb through two clk_dec
// flops, so its wait on those holds is not counted as err_no_store (UMD P6b3i: its pause
// counted ~8 a second; docs/harvest.md "Fixes exchanged")
reg  [1:0] frz_dec_s;
// (0.16, docs/colour.md) the stream's colour override into clk_dec: quasi-static -- ring_rd latches it at the
// stream's first VIDEO_AU, after the per-stream reset emptied the decoder, long before a picture opens
reg  [2:0] col_dec_s0, col_dec_s1;
always @(posedge clk_dec) begin col_dec_s0 <= rr_colour; col_dec_s1 <= col_dec_s0; end
always @(posedge clk_dec) frz_dec_s <= {frz_dec_s[0], ctl_pause};
recon_top #(.DPB_BASE(29'h0640_0000)) recon_top_inst (
	.clk              (clk_dec),
	.rst_n            (fe_rst_dec_n),
	.clear            (1'b0),
	.se_valid         (se_valid),
	.se_ready         (se_ready),
	.se_kind          (se_kind),
	.se_aux           (se_aux),
	.se_val           (se_val),
	.disp_hold        (disp_hold),
	.disp_frz         (frz_dec_s[1]),       // 0.5: the pause (two clk_dec flops)
	.pic_start        (),
	.cur_store        (),
	.cur_struct       (),
	.pic_done         (),
	.done_store       (),
	.done_struct      (),
	.width_mbs        (),
	.frame_height_mbs (),
	.aspect_idc       (),
	.sar_w            (),
	.sar_h            (),
	.idle             (),
	.stream_colour    (col_dec_s1),         // (0.16) the stream's override (ring_rd, two clk_dec flops: quasi-static)
	.pinfo_we         (pi_we),
	.pinfo_store      (pi_store),
	.pinfo_second     (pi_second),
	.pinfo_w_mbs      (pi_w),
	.pinfo_hf_mbs     (pi_hf),
	.pinfo_crop       (pi_crop),
	.pinfo_aspect     (pi_aspect),
	.pinfo_colour     (pi_colour),          // (0.16, docs/colour.md)
	.pinfo_col_unsup  (pi_col_unsup),
	.pinfo_col_tags   (pi_col_tags),
	.pinfo_siting     (pi_siting),          // (chroma.md §4)
	.pinfo_timing_v   (pi_timing_v),
	.pinfo_nuit       (pi_nuit),
	.pinfo_ts         (pi_ts),
	.pinfo_ps         (pi_ps),
	.pinfo_ps_v       (pi_ps_v),
	.pinfo_pts        (pi_pts),
	.pinfo_pts_v      (pi_pts_v),
	.pinfo_idr        (pi_idr),
	.emit_valid       (em_valid),
	.emit_store       (em_store),
	.emit_unpaired    (em_unpaired),
	.emit_first_bot   (em_first_bot),
	.emit_frame       (em_frame),
	.emit_dec_t       (em_dec_t),
	.emit_dec_b       (em_dec_b),
	.emit_poc_t       (),
	.emit_poc_b       (),
	.eos_done         (rc_eos_done),
	.out_dropped      (rc_out_dropped),
	.out_direct       (rc_out_direct),
	.out_over         (rc_out_over),
	.nrf_late         (rc_nrf_late),
	.stall_cycles     (rc_stall),
	.dpb_fill         (rc_dpb_fill),
	.mclk             (clk_mem),
	.mrst_n           (fe_rst_mem_n),
	.ddr_address      (dpb_address),
	.ddr_burstcount   (dpb_burstcount),
	.ddr_read         (dpb_read),
	.ddr_write        (dpb_write),
	.ddr_writedata    (dpb_writedata),
	.ddr_byteenable   (dpb_byteenable),
	.ddr_waitrequest  (dpb_waitrequest),
	.ddr_readdata     (dpb_readdata),
	.ddr_readdatavalid(dpb_readdatavalid),
	.pic_count        (rc_pic),
	.mb_count         (rc_mb),
	.err_count        (rc_err),
	.err_code         (rc_err_code),
	.ref_size         (rc_ref_size)
);

// Interface 0.15 (docs/architecture.md "Pictures from the program"): a picture the program wrote
// into a store, handed over by ring_rd's parser, given to recon_out as the decoder's output
// process gives its own; pic_in's mux passes recon_top through until a picture stream's first
// PICTURE. {holds, pic_emitted} cross to clk_sys as one snapshot for word 84 (the store rule).
wire        po_we, po_second, po_ps_v, po_pts_v, po_idr, po_timing_v;
wire [31:0] po_nuit, po_ts;
wire  [4:0] po_store;
wire  [7:0] po_w, po_hf;
wire [40:0] po_crop;
wire [39:0] po_aspect;
wire  [2:0] po_colour;              // (0.16) pic_in's mux
wire        po_col_unsup;
wire [25:0] po_col_tags;
wire  [5:0] po_siting;              // (chroma.md §4) pic_in's mux (a program's picture: 0)
wire  [3:0] po_ps;
wire [32:0] po_pts;
wire        po_valid, po_unpaired, po_first_bot, po_frame, po_dec_t, po_dec_b, po_eos_done;
wire  [4:0] po_estore;
wire [31:0] pic_emitted;
pic_in #(.NST(20)) pic_in_inst (
	.clk              (clk_dec),
	.rst_n            (fe_rst_dec_n),
	.cnt_rst_n        (lock_dec_n),
	.pd_req           (pd_req),
	.pd_store         (pd_store),
	.pd_w             (pd_w),
	.pd_hf            (pd_hf),
	.pd_struct        (pd_struct),
	.pd_ps            (pd_ps),
	.pd_ps_v          (pd_ps_v),
	.pd_aspect        (pd_aspect),
	.pd_colour        (pd_colour),          // (0.16)
	.pd_timing_v      (pd_timing_v),
	.pd_nuit          (pd_nuit),
	.pd_ts            (pd_ts),
	.pd_crop          (pd_crop),
	.pd_pts           (pd_pts),
	.pd_pts_v         (pd_pts_v),
	.pd_eos           (pd_eos),
	.pd_ack           (pd_ack),
	.pd_busy          (pd_busy),
	.oq_hold          (disp_hold),
	.pic_emitted      (pic_emitted),
	.sel              (),
	.r_pinfo_we       (pi_we),
	.r_pinfo_store    (pi_store),
	.r_pinfo_second   (pi_second),
	.r_pinfo_w_mbs    (pi_w),
	.r_pinfo_hf_mbs   (pi_hf),
	.r_pinfo_crop     (pi_crop),
	.r_pinfo_aspect   (pi_aspect),
	.r_pinfo_colour   (pi_colour),          // (0.16)
	.r_pinfo_col_unsup(pi_col_unsup),
	.r_pinfo_col_tags (pi_col_tags),
	.r_pinfo_siting   (pi_siting),          // (chroma.md §4)
	.r_pinfo_timing_v (pi_timing_v),
	.r_pinfo_nuit     (pi_nuit),
	.r_pinfo_ts       (pi_ts),
	.r_pinfo_ps       (pi_ps),
	.r_pinfo_ps_v     (pi_ps_v),
	.r_pinfo_pts      (pi_pts),
	.r_pinfo_pts_v    (pi_pts_v),
	.r_pinfo_idr      (pi_idr),
	.r_emit_valid     (em_valid),
	.r_emit_store     (em_store),
	.r_emit_unpaired  (em_unpaired),
	.r_emit_first_bot (em_first_bot),
	.r_emit_frame     (em_frame),
	.r_emit_dec_t     (em_dec_t),
	.r_emit_dec_b     (em_dec_b),
	.r_eos_done       (rc_eos_done),
	.pinfo_we         (po_we),
	.pinfo_store      (po_store),
	.pinfo_second     (po_second),
	.pinfo_w_mbs      (po_w),
	.pinfo_hf_mbs     (po_hf),
	.pinfo_crop       (po_crop),
	.pinfo_aspect     (po_aspect),
	.pinfo_colour     (po_colour),          // (0.16)
	.pinfo_col_unsup  (po_col_unsup),
	.pinfo_col_tags   (po_col_tags),
	.pinfo_siting     (po_siting),          // (chroma.md §4)
	.pinfo_timing_v   (po_timing_v),
	.pinfo_nuit       (po_nuit),
	.pinfo_ts         (po_ts),
	.pinfo_ps         (po_ps),
	.pinfo_ps_v       (po_ps_v),
	.pinfo_pts        (po_pts),
	.pinfo_pts_v      (po_pts_v),
	.pinfo_idr        (po_idr),
	.emit_valid       (po_valid),
	.emit_store       (po_estore),
	.emit_unpaired    (po_unpaired),
	.emit_first_bot   (po_first_bot),
	.emit_frame       (po_frame),
	.emit_dec_t       (po_dec_t),
	.emit_dec_b       (po_dec_b),
	.eos_done         (po_eos_done)
);
wire [19:0] pic_held;
wire [31:0] pic_emitted_s;
cdc_snap #(.W(52)) pic_xing (
	.src_clk   (clk_dec),
	.src_rst_n (lock_dec_n),
	.src_data  ({disp_hold, pic_emitted}),
	.dst_clk   (clk_sys),
	.dst_rst_n (lock_sys_n),
	.dst_data  ({pic_held, pic_emitted_s}),
	.dst_tick  ()
);

// The output queue: the emitted stores as records on clk_sys, the display's releases back
// as the decoder's holds.
wire        rq_valid, rq_end, rq_frame, rq_unpaired, rq_first_bot, rq_dec_t, rq_dec_b, rq_timing_v;
wire        rq_ps_a_v, rq_ps_b_v, rq_pts_v, rq_pts_b_v;
wire  [4:0] rq_store;
wire  [7:0] rq_w, rq_hf;
wire [39:0] rq_aspect;
wire  [2:0] rq_colour;              // (0.16) recon_out: the store's colour code, flag and tags
wire        rq_col_unsup;
wire [25:0] rq_col_tags;
wire  [5:0] rq_siting;              // (docs/chroma.md §4) recon_out: the store's chroma siting
wire [40:0] rq_crop;          // P6: the store's crop, to the fit (docs/analog.md §5)
wire [31:0] rq_nuit, rq_ts;
wire  [3:0] rq_ps_a, rq_ps_b;
wire [32:0] rq_pts, rq_pts_b;
wire        rq_take, rl_valid, rq_more;
wire  [4:0] rl_store;
wire [31:0] out_emit, out_rel;
wire        out_ovf, out_rel_bad;
recon_out #(.NST(20)) recon_out_inst (
	.clk            (clk_dec),
	.rst_n          (fe_rst_dec_n),
	.pinfo_we       (po_we),
	.pinfo_store    (po_store),
	.pinfo_second   (po_second),
	.pinfo_w_mbs    (po_w),
	.pinfo_hf_mbs   (po_hf),
	.pinfo_crop     (po_crop),
	.pinfo_aspect   (po_aspect),
	.pinfo_colour   (po_colour),            // (0.16)
	.pinfo_col_unsup(po_col_unsup),
	.pinfo_col_tags (po_col_tags),
	.pinfo_siting   (po_siting),            // (chroma.md §4)
	.pinfo_timing_v (po_timing_v),
	.pinfo_nuit     (po_nuit),
	.pinfo_ts       (po_ts),
	.pinfo_ps       (po_ps),
	.pinfo_ps_v     (po_ps_v),
	.pinfo_pts      (po_pts),
	.pinfo_pts_v    (po_pts_v),
	.pinfo_idr      (po_idr),
	.emit_valid     (po_valid),
	.emit_store     (po_estore),
	.emit_unpaired  (po_unpaired),
	.emit_first_bot (po_first_bot),
	.emit_frame     (po_frame),
	.emit_dec_t     (po_dec_t),
	.emit_dec_b     (po_dec_b),
	.eos_done       (po_eos_done),
	.oq_hold        (disp_hold),
	.n_emit         (out_emit),
	.n_rel          (out_rel),
	.rec_ovf        (out_ovf),
	.rel_bad        (out_rel_bad),
	.sclk           (clk_sys),
	.srst_n         (fe_rst_n),
	.rec_valid      (rq_valid),
	.rec_more       (rq_more),
	.rec_take       (rq_take),
	.rec_end        (rq_end),
	.rec_store      (rq_store),
	.rec_frame      (rq_frame),
	.rec_unpaired   (rq_unpaired),
	.rec_first_bot  (rq_first_bot),
	.rec_dec_t      (rq_dec_t),
	.rec_dec_b      (rq_dec_b),
	.rec_w_mbs      (rq_w),
	.rec_hf_mbs     (rq_hf),
	.rec_crop       (rq_crop),
	.rec_aspect     (rq_aspect),
	.rec_colour     (rq_colour),            // (0.16)
	.rec_col_unsup  (rq_col_unsup),
	.rec_col_tags   (rq_col_tags),
	.rec_siting     (rq_siting),            // (chroma.md §4)
	.rec_timing_v   (rq_timing_v),
	.rec_nuit       (rq_nuit),
	.rec_ts         (rq_ts),
	.rec_ps_a       (rq_ps_a),
	.rec_ps_a_v     (rq_ps_a_v),
	.rec_ps_b       (rq_ps_b),
	.rec_ps_b_v     (rq_ps_b_v),
	.rec_pts        (rq_pts),
	.rec_pts_v      (rq_pts_v),
	.rec_pts_b      (rq_pts_b),
	.rec_pts_b_v    (rq_pts_b_v),
	.rec_idr        (),
	.rel_valid      (rl_valid),
	.rel_store      (rl_store)
);

// The display's control (docs/display.md S7): every record is shown when its PTS is due
// against a 90 kHz STC phased to this raster, for its Table E-6 duration (a record with
// no PTS -- a VIDEO_AU record without PTS_VALID -- is shown at its VUI rate from the
// previous one); at line 500 a due record is taken and the store shown until then
// released; the END record leaves the last store up, held. sh_field / sh_parity /
// sh_single: the store holds fields, the field to show, one field alone (bobbed).
wire        sh_valid, sh_field, sh_parity, sh_single;
wire  [4:0] sh_store;
wire  [7:0] sh_w, sh_hf;
wire [39:0] sh_aspect;
wire  [2:0] sh_colour;              // (0.16) disp_ctl: the shown picture's colour code (word 80) and tags (word 86)
wire [25:0] sh_col_tags;
wire  [5:0] sh_siting;              // (chroma.md §4) disp_ctl: the shown picture's chroma siting
wire [15:0] disp_col_unsup;         // (0.16) pictures taken whose matrix is not supported (word 86)
wire [40:0] sh_crop;
wire [15:0] fit_sar_w, fit_sar_h;   // P6: the resolved SAR (1:1 unspecified; aspect_vui below), to the fit
wire        rate_v;                 // P6 steps 5 / 6: disp_ctl's prepared head, and its VUI rate's class (Refresh Rate's Auto)
wire  [1:0] rate_cls;
wire [31:0] disp_dc, disp_pick, disp_skip;
wire  [7:0] disp_reanchor;
wire [31:0] disp_fhold;               // (0.15) disp_ctl: field pairs held a refresh for the raster's field (word 85)
wire  [3:0] disp_lone;                // 0.7: lone PTS disbelieved (UMD's rules A and B, disp_sched)
wire [15:0] disp_late, disp_starve, disp_cadence;
wire  [2:0] disp_flags;
wire signed [15:0] disp_lag_ms;
wire [32:0] disp_stc;
wire        disp_stc_run;
wire        aud_anc;                  // 0.5: aud_play's audio anchor
wire        aud_lead;                 // 1.1: aud_play: the queued audio ahead of the clock (disp_sched: no lateness anchor)
wire [32:0] aud_anc_pts;
// 0.5: aud_play's status (words 40-44; the audio path itself is below, by the audio outputs)
wire  [1:0] aud_st_state;
wire  [8:0] aud_q_rec;
wire [31:0] aud_q_samples, aud_n_played, aud_n_records, aud_n_gap, aud_n_late, aud_offset;
wire [15:0] aud_n_underruns, aud_n_slip_drop, aud_n_slip_rep, aud_n_anchor;
disp_ctl disp_ctl_inst (
	.clk            (clk_sys),
	.rst_n          (fe_rst_n),
	.frame0         (frame0_sys),             // (hd_raster) the raster's frame start, crossed from clk_vid
	.il             (raster_il_eff),          // P6: a refresh is a field only on an interlaced raster
	.prog240        (prog240_eff),
	.std            (raster_std),             // P6 steps 5 / 6: the refresh grid (59.94 / 60.00 / 50 Hz)
	.rec_valid      (rq_valid),
	.rec_more       (rq_more),                // P3f: another picture waits behind the head
	.low_lat        (rr_ll),                  // the stream's LOW_LATENCY (the HPS interface's reader)
	.pause          (ctl_pause),              // 0.5: word 34's PAUSE -- the STC and the display stand still
	.aanc           (aud_anc),                // 0.5: the audio starts the STC (no picture has)
	.aanc_pts       (aud_anc_pts),
	.aud_lead       (aud_lead),               // 1.1: the queued audio ahead of the clock: no lateness anchor
	.rec_take       (rq_take),
	.rec_end        (rq_end),
	.rec_store      (rq_store),
	.rec_frame      (rq_frame),
	.rec_unpaired   (rq_unpaired),
	.rec_first_bot  (rq_first_bot),
	.rec_dec_t      (rq_dec_t),
	.rec_dec_b      (rq_dec_b),
	.rec_w_mbs      (rq_w),
	.rec_hf_mbs     (rq_hf),
	.rec_crop       (rq_crop),
	.rec_aspect     (rq_aspect),
	.rec_colour     (rq_colour),            // (0.16)
	.rec_col_unsup  (rq_col_unsup),
	.rec_col_tags   (rq_col_tags),
	.rec_siting     (rq_siting),            // (chroma.md §4)
	.rec_timing_v   (rq_timing_v),
	.rec_nuit       (rq_nuit),
	.rec_ts         (rq_ts),
	.rec_ps_a       (rq_ps_a),
	.rec_ps_a_v     (rq_ps_a_v),
	.rec_ps_b       (rq_ps_b),
	.rec_ps_b_v     (rq_ps_b_v),
	.rec_pts        (rq_pts),
	.rec_pts_v      (rq_pts_v),
	.rec_pts_b      (rq_pts_b),
	.rec_pts_b_v    (rq_pts_b_v),
	.rel_valid      (rl_valid),
	.rel_store      (rl_store),
	.sh_valid       (sh_valid),
	.sh_field       (sh_field),
	.sh_store       (sh_store),
	.sh_w           (sh_w),
	.sh_hf          (sh_hf),
	.sh_parity      (sh_parity),
	.sh_single      (sh_single),
	.sh_crop        (sh_crop),
	.sh_aspect      (sh_aspect),
	.sh_colour      (sh_colour),            // (0.16)
	.sh_col_tags    (sh_col_tags),
	.sh_siting      (sh_siting),            // (chroma.md §4)
	.n_col_unsup    (disp_col_unsup),
	.n_dc           (disp_dc),
	.n_pick         (disp_pick),
	.n_skip         (disp_skip),
	.n_reanchor     (disp_reanchor),
	.n_lone         (disp_lone),
	.n_late         (disp_late),
	.n_starve       (disp_starve),
	.n_cadence      (disp_cadence),
	.n_fhold        (disp_fhold),
	.flags          (disp_flags),
	.lag_ms         (disp_lag_ms),
	.stc            (disp_stc),
	.stc_run        (disp_stc_run),
	.pick_ph        (disp_pick_ph),
	.ended          (disp_ended),
	.rate_v         (rate_v),
	.rate_cls       (rate_cls)
);

// ---- the fit (P6 step 3): where and how big the shown picture is -----------------------------
// Display Shape supplies the shared 4:3 / 16:9 canvas, and every fitted raster matches it: 4:3 is
// Letterbox, 16:9 the anamorphic 16:9 fit, interlaced and progressive alike. HDMI is told the same
// shape (VIDEO_ARX / ARY below), so the picture keeps its proportions on either output. Fill (mode
// 3, A') is not selected: it letterboxed for the HDMI display's shape while HDMI was told 4:3, so
// 480p at 4:3 showed a scope film about 1.5x too narrow (found on the DE10 2026-10-19). The player
// publishes its calibrated geometry separately. Fit state is latched once per refresh, in its
// blank before the next one's rows are commanded (progressive line 500, the field's line
// 250 at 480i), so a menu change never splits a picture; disp_fit then republishes within
// ~150 clocks.
// A' (docs/hdmi_raster.md §3a) stays in disp_fit for its benches: under Fill a picture wider than
// the HDMI display (HDMI_WIDTH x HDMI_HEIGHT, latched below) is letterboxed INSIDE the raster and
// HDMI is given the display's shape. The native raster (raster_geom) still uses the latched shape.
wire  [1:0] fit_mode_want = status[2] ? 2'd2 : 2'd0; // the anamorphic 16:9 fit, or 4:3 Letterbox
wire        raster_fitted = ~geom_nat;   // every non-native profile uses the shared fitted canvas
reg   [1:0] fit_mode_l = 2'd0;
reg  [11:0] fit_dw_l = 12'd0, fit_dh_l = 12'd0;   // A': the HDMI display's shape, latched with the mode
reg         nat_req_l = 1'b0;                     // stage 2: Video Output Native (HDMI), latched with the mode
wire        disp_pick_ph;                         // disp_ctl: the pickup's phase of every refresh
// De-flicker (formerly Anti-Twitter; the vertical 1:2:1 softening in disp_fit):
// Global vertical De-flicker applies the (1, 2, 1) blend to frame stores on interlaced output.
// Field stores already carry interlaced content and are never filtered across fields. The
// setting is latched at pickup; progressive and Native HDMI output leave it inactive.
wire        at_sel = ~status[29];              // global On/Off; filter is gated to interlaced below
reg         at_opt_l = 1'b0;
// Latched at the pickup's phase (disp_ctl's refresh grid: line 500 / 600 of the fitted rasters, a
// field's 250 / 300 -- the same dots), raster-independent: a native raster is shorter or taller
always @(posedge clk_sys)
	if (disp_pick_ph) begin
		fit_mode_l <= fit_mode_want;
		at_opt_l   <= at_sel;
		fit_dw_l   <= HDMI_WIDTH;              // a display-mode change (Main's) is a new input set at the pickup
		fit_dh_l   <= HDMI_HEIGHT;
		nat_req_l  <= (video_out_eff == 2'd3) & sh_valid; // Native only while a picture is shown; menus use the fitted 480/576 raster
	end
wire        fit_at = at_opt_l & raster_il_eff & ~sh_field;
wire [12:0] fit_ow, fit_oh;
wire [13:0] fit_ox0, fit_oy0;
wire        fit_clip_en;
wire [11:0] fit_clip_x, fit_clip_y, fit_clip_w, fit_clip_h;
wire [27:0] fit_sx, fit_sy;
wire  [1:0] fit_dh_l2, fit_dv_l2;
wire [11:0] fit_wc, fit_hc, fit_lx, fit_ty;
wire        fit_crop_bad, fit_snap, fit_clamp, fit_slide, fit_lb;
wire  [2:0] fit_hpf, fit_vpf;
disp_fit disp_fit_inst (
	.clk      (clk_sys),
	.rst_n    (reset_n),
	.w_mbs    (sh_w),
	.hf_mbs   (sh_hf),
	.crop     (sh_crop),
	.sar_w    (fit_sar_w),
	.sar_h    (fit_sar_h),
	.mode     (fit_mode_l),
	.disp_w   (fit_dw_l),
	.disp_h   (fit_dh_l),
	.nat      (geom_nat),                  // stage 2: the picture 1:1 on raster_geom's raster
	.nat_w    (geom_rw),
	.nat_h    (geom_rh),
	.il       (interlaced_eff),
	.at       (fit_at),
	.pal      (raster_pal),
	.area     (1'b1),                      // the Area pre-filter, always (docs/analog.md §11b, decided 2026-10-05)
	.geometry_en (rr_geom_data[63:56] != 8'd0 && !geom_nat),
	.geometry_x  (rr_geom_data[51:39]),
	.geometry_y  (rr_geom_data[38:26]),
	.geometry_w  (rr_geom_data[25:13]),
	.geometry_h  (rr_geom_data[12:0]),
	.geometry_clip_en (rr_geom_data[63:56] != 8'd0 && !geom_nat),
	.geometry_clip_x  (rr_geom_data[75:64]),
	.geometry_clip_y  (rr_geom_data[87:76]),
	.geometry_clip_w  (rr_geom_data[99:88]),
	.geometry_clip_h  (rr_geom_data[111:100]),
	.ow       (fit_ow),
	.oh       (fit_oh),
	.ox0      (fit_ox0),
	.oy0      (fit_oy0),
	.clip_en  (fit_clip_en),
	.clip_x   (fit_clip_x),
	.clip_y   (fit_clip_y),
	.clip_w   (fit_clip_w),
	.clip_h   (fit_clip_h),
	.sx       (fit_sx),
	.sy       (fit_sy),
	.dh_l2    (fit_dh_l2),
	.dv_l2    (fit_dv_l2),
	.wc       (fit_wc),
	.hc       (fit_hc),
	.lx       (fit_lx),
	.ty       (fit_ty),
	.crop_bad (fit_crop_bad),
	.snap     (fit_snap),
	.clamp    (fit_clamp),
	.slide    (fit_slide),
	.lb       (fit_lb),
	.hpf      (fit_hpf),
	.vpf      (fit_vpf),
	.busy     ()
);

// ---- the native raster (docs/hdmi_raster.md §3b / §4, stage 2) ---------------------------------
// From the shown picture (disp_fit's cropped size, aspect_vui's SAR, its coded width), the HDMI
// display's shape and the refresh standard: display-shaped where it fits, else picture-sized, else
// the fitted 720 raster (mode 2, word 80). Computes while a picture is shown, or when Native is
// off (to go back to fitted); between streams it HOLDS -- a seek never flips the raster to 720 and
// back. Its inputs change at the pickup (sh_*, the latched display and Native): the geometry is
// ready long before sync_gen takes it at the next frame's first dot.
raster_geom raster_geom_inst (
	.clk    (clk_sys),
	.rst_n  (reset_n),
	.en     (sh_valid | ~nat_req_l),        // a picture shown (stream_live), or Native off
	.req    (nat_req_l),
	.wc     (fit_wc),
	.hc     (fit_hc),
	.sar_w  (fit_sar_w),
	.sar_h  (fit_sar_h),
	.w_mbs  (sh_w),
	.dw     (fit_dw_l),
	.dh     (fit_dh_l),
	.std    (raster_std),
	.mode   (geom_mode),
	.rw     (geom_rw),
	.rh     (geom_rh),
	.disp   (geom_disp),
	.l      (geom_l),
	.nt     (geom_nt),
	.last   (geom_last),
	.busy   ()
);

wire  [7:0] pic_r, pic_g, pic_b;
wire        pic_de;
wire [31:0] disp_fetch_changes;           // clk_mem (mem_lock_n: never reset per stream)
wire [28:0] dr_address;                   // the reader's ram2 master (ram2_mux's A)
wire  [7:0] dr_burstcount;
wire        dr_read, dr_waitrequest, dr_readdatavalid;
wire [63:0] dr_readdata;
wire [15:0] disp_fetch_late;              // clk_sys: lines whose rows came late (to the status word, step 3e)
wire [15:0] disp_fetch_late_v;            // clk_vid: the reader's count (crossed below)
disp_reader #(.DPB_BASE(29'h0640_0000)) disp_reader_inst (
	.clk               (clk_vid),            // (hd_raster) the raster side on clk_vid, a dot per ce_dot
	.ce                (ce_dot),
	.rst_n             (vid_fe_rst_n),
	.h_pos             (h_pos),
	.v_pos             (v_pos),
	.de_in             (pixel_en),
	.il                (v_il),               // P6: pixels of two dots, the fields shown as they are
	.prog240           (v_prog240),
	.pal               (v_pal),              // P6 step 6: the 625-line raster's line counts
	.lines             (rast_lines),         // stage 2: the frame being scanned (native or fitted)
	.last_line         (rast_last),
	.pic_valid         (v_sh_valid),         // the bundle: disp_ctl's shown picture, disp_fit's fit
	.pic_store         (v_sh_store),
	.pic_field         (v_sh_field),
	.pic_w_mbs         (v_sh_w),
	.pic_hf_mbs        (v_sh_hf),
	.pic_parity        (v_sh_parity),
	.pic_single        (v_sh_single),
	.deint_mode        (v_deint),            // Deinterlace: Weave / Bob / Blend (latched per frame)
	.pic_colour        (v_colour),           // (0.16, docs/colour.md) the shown picture's colour code, latched per refresh
	.gradient_dither   (~status[30]),
	.pic_siting        (v_siting),           // (docs/chroma.md) its chroma siting, latched with it
	.fit_ow            (v_fit_ow),
	.fit_oh            (v_fit_oh),
	.fit_ox0           (v_fit_ox0),
	.fit_oy0           (v_fit_oy0),
	.fit_sx            (v_fit_sx),
	.fit_sy            (v_fit_sy),
	.fit_dh_l2         (v_fit_dh_l2),
	.fit_dv_l2         (v_fit_dv_l2),
	.fit_lx            (v_fit_lx),
	.fit_ty            (v_fit_ty),
	.fit_wc            (v_fit_wc),
	.fit_hc            (v_fit_hc),
	.fit_hpf           (v_fit_hpf),          // (§11b) the pre-filters, published with the fit
	.fit_vpf           (v_fit_vpf),          // (anti-twitter's sliding rows among them: 4)
	.clip_enable       (v_clip_en),
	.clip_x            (v_clip_x),
	.clip_y            (v_clip_y),
	.clip_w            (v_clip_w),
	.clip_h            (v_clip_h),
	.fetch_late        (disp_fetch_late_v),
	.r                 (pic_r),
	.g                 (pic_g),
	.b                 (pic_b),
	.de_out            (pic_de),
	.mclk              (clk_mem),
	.mrst_n            (mem_lock_n),
	.ddr_address       (dr_address),         // ram2 through ram2_mux (master A), below
	.ddr_burstcount    (dr_burstcount),
	.ddr_read          (dr_read),
	.ddr_waitrequest   (dr_waitrequest),
	.ddr_readdata      (dr_readdata),
	.ddr_readdatavalid (dr_readdatavalid),
	.fetch_changes     (disp_fetch_changes)
);

ddr_mux2 ddr_mux2_inst (
	.clk               (clk_mem),
	.rst_n             (mem_lock_n),
	.a_address         (dpb_address),
	.a_burstcount      (dpb_burstcount),
	.a_read            (dpb_read),
	.a_write           (dpb_write),
	.a_writedata       (dpb_writedata),
	.a_byteenable      (dpb_byteenable),
	.a_abort           (dpb_abort_q[1]),
	.a_waitrequest     (dpb_waitrequest),
	.a_readdata        (dpb_readdata),
	.a_readdatavalid   (dpb_readdatavalid),
	.b_address         (rb_address),      // master B: the HPS interface's reader (h264/ring_rd.sv)
	.b_burstcount      (rb_burstcount),
	.b_read            (rb_read),
	.b_write           (rb_write),
	.b_writedata       (rb_writedata),
	.b_waitrequest     (rb_waitrequest),
	.b_readdata        (rb_readdata),
	.b_readdatavalid   (rb_readdatavalid),
	.ddr_address       (DDRAM_ADDR),
	.ddr_burstcount    (DDRAM_BURSTCNT),
	.ddr_read          (DDRAM_RD),
	.ddr_write         (DDRAM_WE),
	.ddr_writedata     (DDRAM_DIN),
	.ddr_byteenable    (DDRAM_BE),
	.ddr_waitrequest   (DDRAM_BUSY),
	.ddr_readdata      (DDRAM_DOUT),
	.ddr_readdatavalid (DDRAM_DOUT_READY)
);

// ram1's traffic, watched (h264/ddr_probe.sv, UMD's): the ring's reads share the port with
// the DPB's, and occupancy is the scarce resource (docs/hw_budget_and_lessons.md S2).
wire [31:0] probe_wr, probe_rd;
wire [15:0] probe_owed, probe_busy, probe_busy_max;
ddr_probe ram1_probe (
	.clk           (clk_mem),
	.rst_n         (mem_lock_n),
	.read          (DDRAM_RD),
	.write         (DDRAM_WE),
	.burstcount    (DDRAM_BURSTCNT),
	.waitrequest   (DDRAM_BUSY),
	.readdatavalid (DDRAM_DOUT_READY),
	.wr_beats      (probe_wr),
	.rd_beats      (probe_rd),
	.owed          (probe_owed),
	.busy          (probe_busy),
	.busy_max      (probe_busy_max)
);

// =========================================================================
// The overlay plane (Phase 6b, interface 0.9; docs/architecture.md "The overlay plane"): the
// program's page of the Linux framebuffer, described in control words 72-79, composited over
// the picture on this raster (HDMI and the analog pins alike). h264/ovl_plane.sv reads the
// descriptor once a refresh and the page a line at a time on ram2, as master B of a second
// ddr_mux2 beside the display reader (A: B takes the channel after each A command -- the
// shape measured on the rig, architecture.md measurement 2). Shown only during a session
// (rr_sess: DDR3 survives a core load, and a previous program's descriptor with it);
// anti-twittered at 480i unless Anti-Twitter is Off (the overlay is graphics: Auto filters).
// Both sides reset with the PLL lock alone: its master never withdraws a held read, and a
// program's counts survive an OSD Reset.
// =========================================================================
wire [28:0] ov_address;
wire  [7:0] ov_burstcount;
wire        ov_read, ov_waitrequest, ov_readdatavalid;
wire [63:0] ov_readdata;
wire  [7:0] ovl_pr, ovl_pg, ovl_pb, ovl_pa;
wire [31:0] ovl_gen, ovl_lines;
wire  [1:0] ovl_state;
wire        ovl_at, ovl_clip;
wire  [3:0] ovl_err;
wire  [7:0] ovl_torn;
wire [15:0] ovl_late;
wire [31:0] ovl_gen_v, ovl_lines_v;       // clk_vid (hd_raster): crossed into clk_sys below
wire  [1:0] ovl_state_v;
wire        ovl_at_v, ovl_clip_v;
wire  [3:0] ovl_err_v;
wire  [7:0] ovl_torn_v;
wire [15:0] ovl_late_v;
ovl_plane ovl_plane_inst (
	.clk               (clk_vid),          // (hd_raster) the raster side on clk_vid, a dot per ce_dot
	.ce                (ce_dot),
	.rst_n             (vid_lock_n),
	.h_pos             (h_pos),
	.v_pos             (v_pos),
	.de_in             (pixel_en),
	.il                (v_il),
	.prog240           (v_prog240),
	.pal               (v_pal),
	.rast_w            (v_rw),             // (0.10) the raster the canvas is centred on (720 fitted, native's)
	.rast_h            (v_rh),             // (hd_raster) ... its lines: the next frame's (raster_geom's)
	.rast_lines        (rast_lines),       // ... the frame sync_gen scans
	.rast_last         (rast_last),
	.sess              (v_sess),
	.at_en             (v_at_en),          // Anti-Twitter Auto or On
	.pr                (ovl_pr),
	.pg                (ovl_pg),
	.pb                (ovl_pb),
	.pa                (ovl_pa),
	.ovl_gen           (ovl_gen_v),
	.ovl_state         (ovl_state_v),
	.ovl_at            (ovl_at_v),
	.ovl_clip          (ovl_clip_v),
	.ovl_err           (ovl_err_v),
	.ovl_torn          (ovl_torn_v),
	.ovl_late          (ovl_late_v),
	.ovl_lines         (ovl_lines_v),
	.mclk              (clk_mem),
	.mrst_n            (mem_lock_n),
	.ddr_address       (ov_address),
	.ddr_burstcount    (ov_burstcount),
	.ddr_read          (ov_read),
	.ddr_waitrequest   (ov_waitrequest),
	.ddr_readdata      (ov_readdata),
	.ddr_readdatavalid (ov_readdatavalid)
);

ddr_mux2 ram2_mux (
	.clk               (clk_mem),
	.rst_n             (mem_lock_n),
	.a_address         (dr_address),      // master A: the display reader
	.a_burstcount      (dr_burstcount),
	.a_read            (dr_read),
	.a_write           (1'b0),
	.a_writedata       (64'd0),
	.a_byteenable      (8'hFF),
	.a_abort           (1'b0),            // the reader never withdraws (mem_lock_n alone)
	.a_waitrequest     (dr_waitrequest),
	.a_readdata        (dr_readdata),
	.a_readdatavalid   (dr_readdatavalid),
	.b_address         (ov_address),      // master B: the overlay plane
	.b_burstcount      (ov_burstcount),
	.b_read            (ov_read),
	.b_write           (1'b0),
	.b_writedata       (64'd0),
	.b_waitrequest     (ov_waitrequest),
	.b_readdata        (ov_readdata),
	.b_readdatavalid   (ov_readdatavalid),
	.ddr_address       (DDRAM2_ADDR),
	.ddr_burstcount    (DDRAM2_BURSTCNT),
	.ddr_read          (DDRAM2_RD),
	.ddr_write         (),                // ram2 is read-only (DDRAM2_WE tied 0)
	.ddr_writedata     (),
	.ddr_byteenable    (),
	.ddr_waitrequest   (DDRAM2_BUSY),
	.ddr_readdata      (DDRAM2_DOUT),
	.ddr_readdatavalid (DDRAM2_DOUT_READY)
);

// =========================================================================
// Stream state
// -------------------------------------------------------------------------
// stream_live: "a picture is on screen" -- the level that selects the idle screen vs the
// decoded picture, and the content aspect. The display holds its last store after the
// END record, so the level stays up until the next stream resets it (fe_rst_n): a
// producer going quiet never flips VIDEO_ARX under live content (UMD's media_seen note).
// played: a picture has been shown since the core's reset. Between two streams (a session
// start, a DISCONTINUITY) the screen is then BLACK, not the bars, and the Auto aspect holds
// the last picture's (decided 2026-09-27): the bars mean "nothing has played yet".
// =========================================================================
wire stream_live = sh_valid;
reg  played = 1'b0;
always @(posedge clk_sys or negedge reset_n)
	if (!reset_n)        played <= 1'b0;
	else if (stream_live) played <= 1'b1;

// =========================================================================
// The idle screen (h264/idle_bars.sv, LAT 2) and the output stage
// =========================================================================
wire       idle_vis = ~stream_live & ~played;

// Output Mode uses the selected explicit profile. Keep the framework's old Auto-detection
// latches above for board setup compatibility, but they no longer choose the core raster.
wire       analog_want_raw = ((ini_csync | ini_ypbpr | ini_sog) & ~ini_vga_scaler & ~forced_scandoubler)
                           | direct_video;
wire       vga31_want_raw  = forced_scandoubler & ~ini_vga_scaler;
reg        analog_want_l, vga31_want_l;
always @(posedge clk_sys or negedge reset_n) begin
	if (!reset_n)                       begin analog_want_l <= 1'b0; vga31_want_l <= 1'b0; end
	else if (cfg_seen && !stream_live)  begin analog_want_l <= analog_want_raw; vga31_want_l <= vga31_want_raw; end
end
// Retain the stream's rate classification while idle. Match Video Refresh applies it only
// during playback, so the user's selected output profile returns when no picture is shown.
reg  [1:0] std_auto_l;
always @(posedge clk_sys or negedge reset_n) begin
	if (!reset_n)                      std_auto_l <= 2'd0;
	else if (rate_v && !stream_live)   std_auto_l <= rate_cls;
end
wire       match_playback = stream_live | rate_v; // the prepared head precedes its first shown picture
wire [2:0] output_profile = status[22:20];  // 0 480i60, 1 480p60, 2 576i50, 3 576p50, 4 Native HDMI
// Read only the active option bit: a former saved 48/50/60 value (binary 10) becomes Off.
wire [1:0] match_refresh = status[27] ? 2'd1 : 2'd0;
wire       film_speed_allowed = (output_profile == 3'd2 || output_profile == 3'd3) && match_refresh == 0;
wire [2:0] effective_profile;
assign prog240_eff = status[24] && interlaced_eff && match_playback && !geom_nat;
display_policy display_policy_inst (
	.profile          (output_profile),
	.match_refresh    (match_refresh),
	.playing          (match_playback),
	.source_std       (std_auto_l),
	.video_out        (video_out_eff),
	.interlaced       (interlaced_eff),
	.raster_std       (raster_std),
	.effective_profile(effective_profile)
);
// Matching temporarily follows the prepared source. Native retains exact 60 Hz; fitted modes use 59.94.
assign raster_pal     = raster_std[1];
// ---- (hd_raster) the crossings of the raster side (docs/hd_raster.md S3) ---------------------
// clk_sys -> clk_vid: everything the raster side reads, as ONE bundle through a continuous cdc_snap
// (a fresh untorn copy every ~4 cycles of each clock). Its sources change at the pickup (disp_ctl's
// sh_*, then disp_fit's and raster_geom's republishing inside the pickup's 21,450-dot lead), with a
// menu change, or at a mode change; the raster uses a picture from the next frame on, the geometry
// at a frame's first dot, the deinterlace mode / the overlay's settings at a refresh's first line --
// all long after the copy has settled.
localparam int XW_DN = 1 + 1 + 1 + 2 + 1 + 5*12 + 1 + 5 + 1 + 8 + 8 + 1 + 1 + 2 + 3 +
                       13 + 13 + 14 + 14 + 28 + 28 + 2 + 2 + 12 + 12 + 12 + 12 + 3 + 3 + 1 + 1 + 1 + 6 + 1 + 4*12;
wire [XW_DN-1:0] xdn_src = {raster_il_eff, prog240_eff, raster_pal, raster_std,
                            geom_nat, geom_rw, geom_rh, geom_l, geom_nt, geom_last,
                            sh_valid, sh_store, sh_field, sh_w, sh_hf, sh_parity, sh_single, status[4:3], sh_colour,
                            fit_ow, fit_oh, fit_ox0, fit_oy0, fit_sx, fit_sy, fit_dh_l2, fit_dv_l2,
                            fit_lx, fit_ty, fit_wc, fit_hc, fit_hpf, fit_vpf,
                            rr_sess, at_sel, idle_vis, sh_siting,
                            fit_clip_en, fit_clip_x, fit_clip_y, fit_clip_w, fit_clip_h};
wire [XW_DN-1:0] xdn_dst;
assign {v_il, v_prog240, v_pal, v_std,
        v_nat, v_rw, v_rh, v_l, v_nt, v_last,
        v_sh_valid, v_sh_store, v_sh_field, v_sh_w, v_sh_hf, v_sh_parity, v_sh_single, v_deint, v_colour,
        v_fit_ow, v_fit_oh, v_fit_ox0, v_fit_oy0, v_fit_sx, v_fit_sy, v_fit_dh_l2, v_fit_dv_l2,
        v_fit_lx, v_fit_ty, v_fit_wc, v_fit_hc, v_fit_hpf, v_fit_vpf,
        v_sess, v_at_en, v_idle_vis, v_siting,
        v_clip_en, v_clip_x, v_clip_y, v_clip_w, v_clip_h} = xdn_dst;
cdc_snap #(.W(XW_DN)) raster_dn_xing (
	.src_clk   (clk_sys),
	.src_rst_n (lock_sys_n),
	.src_data  (xdn_src),
	.dst_clk   (clk_vid),
	.dst_rst_n (vid_lock_n),
	.dst_data  (xdn_dst),
	.dst_tick  ()
);
// clk_vid -> clk_sys: the raster side's counters and the overlay's state, for the status block
// (words 30, 46, 47), the same way (a counter is never read mid-carry).
localparam int XW_UP = 16 + 32 + 2 + 1 + 1 + 4 + 8 + 16 + 32;
wire [XW_UP-1:0] xup_src = {disp_fetch_late_v, ovl_gen_v, ovl_state_v, ovl_at_v, ovl_clip_v, ovl_err_v, ovl_torn_v,
                            ovl_late_v, ovl_lines_v};
wire [XW_UP-1:0] xup_dst;
assign {disp_fetch_late, ovl_gen, ovl_state, ovl_at, ovl_clip, ovl_err, ovl_torn, ovl_late, ovl_lines} = xup_dst;
cdc_snap #(.W(XW_UP)) raster_up_xing (
	.src_clk   (clk_vid),
	.src_rst_n (vid_lock_n),
	.src_data  (xup_src),
	.dst_clk   (clk_sys),
	.dst_rst_n (lock_sys_n),
	.dst_data  (xup_dst),
	.dst_tick  ()
);

wire [7:0] idle_r, idle_g, idle_b;
// the pixel column: in 480i a pixel is two dots (pixel repetition), h_pos counts dots
wire [11:0] idle_x = (v_il || v_prog240) ? {1'b0, h_pos[11:1]} : h_pos;
idle_bars idle_bars_inst (
	.clk        (clk_vid),
	.ce         (ce_dot),
	.rst_n      (vid_rst_n),
	.h_pos      (idle_x),
	.v_pos      (v_pos),
	.de_in      (pixel_en),
	.frame_tick (frame_tick),
	.vis        (1'b0),            // quiet startup; test-pattern logic is optimized away
	.r          (idle_r),
	.g          (idle_g),
	.b          (idle_b),
	.de_out     ()                    // = vid_out's de_dly[4] three dots early: DE is the raster's
);

// The output stage (h264/vid_out.sv): the picture (LAT 5) or the idle screen (LAT 2), the overlay
// (LAT 5) composited over it, sync / DE / CE_PIXEL / VGA_F1 delayed to match -- LAT 6 dots -- and the
// SMPTE composite sync on the 15 kHz raster.
wire cs_smpte, cs_smpte_en;
wire [7:0] vga_r_q, vga_g_q, vga_b_q;
wire       vga_hs_q, vga_vs_q, vga_de_q, vga_ce_q, vga_f1_q;
vid_out vid_out_inst (
	.clk      (clk_vid),
	.ce       (ce_dot),
	.rst_n    (vid_rst_n),
	.h_sync   (h_sync),
	.v_sync   (v_sync),
	.pixel_en (pixel_en),
	.ce_pix   (ce_pix),
	.field    (field),
	.v_pos    (v_pos),
	.il       (v_il),
	.prog240  (v_prog240),
	.pal      (v_pal),
	.pic_r    (pic_r),
	.pic_g    (pic_g),
	.pic_b    (pic_b),
	.pic_de   (pic_de),
	.idle_r   (idle_r),
	.idle_g   (idle_g),
	.idle_b   (idle_b),
	.ovl_pr   (ovl_pr),
	.ovl_pg   (ovl_pg),
	.ovl_pb   (ovl_pb),
	.ovl_pa   (ovl_pa),
	.vga_r    (vga_r_q),
	.vga_g    (vga_g_q),
	.vga_b    (vga_b_q),
	.vga_hs   (vga_hs_q),
	.vga_vs   (vga_vs_q),
	.vga_de   (vga_de_q),
	.vga_ce   (vga_ce_q),
	.vga_f1   (vga_f1_q),
	.cs       (cs_smpte),
	.cs_en    (cs_smpte_en)
);
assign VGA_R  = vga_r_q;
assign VGA_G  = vga_g_q;
assign VGA_B  = vga_b_q;
assign VGA_HS = vga_hs_q;
assign VGA_VS = vga_vs_q;
assign VGA_DE = vga_de_q;
assign CE_PIXEL = vga_ce_q;       // one clk_vid clock a dot: every third at 480p; every sixth at 480i (pixel repetition)
assign VGA_F1 = vga_f1_q;        // 480i: v_pos[0], 0 on the top field (what ascal's Weave needs, DVD #41); 0 in 480p
assign VGA_SL = 2'd0;
assign VGA_SCALER  = 1'b0;
assign VGA_DISABLE = 1'b0;
assign VGA_CS    = cs_smpte;
assign VGA_CS_EN = cs_smpte_en;
assign HDMI_FREEZE    = 1'b0;
assign HDMI_BLACKOUT  = 1'b0;
assign HDMI_BOB_DEINT = raster_il_eff & status[7];   // 480i on HDMI: ascal's Bob (else Weave)

// =========================================================================
// Aspect ratio presented to the scaler
// -------------------------------------------------------------------------
// O[2:1]: Auto / 4:3 / 16:9. With a picture shown, Auto is the shown picture's VUI aspect
// (h264/aspect_vui.sv): sar_w * W : sar_h * H rounded to the nearer of 4:3 and 16:9. An
// unspecified SAR (no VUI, idc 0, reserved) is read as SQUARE pixels, W : H rounded the
// same way (a stock Sunshine stream at 720x480 is 3:2 -> 4:3). UMD read it as 16:9, every
// UMD title being anamorphic; a game or media-server stream is not. The exact aspect to
// the scaler is Phase 6 (docs/roadmap.md). At idle Auto follows the DISPLAY: a widescreen
// HDMI mode gets a full-width pattern instead of a pillarboxed 4:3 window. W*2 >= H*3 <=>
// W/H >= 1.5, by shift-add; HDMI_WIDTH == 0 (no scaler) takes the 4:3 path. Registered;
// the inputs change only with the shown picture's SPS, so VIDEO_ARX/ARY stay stable --
// every change re-inits the scaler.
// =========================================================================
reg disp_wide_q = 1'b0;
always @(posedge clk_sys)
	disp_wide_q <= ({1'b0, HDMI_WIDTH, 1'b0} >=                        // W*2
	                {1'b0, HDMI_HEIGHT, 1'b0} + {2'b00, HDMI_HEIGHT})  // H*3
	               && (HDMI_WIDTH != 12'd0);
wire  [7:0] sh_ar_idc = sh_aspect[39:32];
wire [15:0] sh_sar_w  = sh_aspect[31:16], sh_sar_h = sh_aspect[15:0];
wire vui_sar_known, vui_wide;
aspect_vui aspect_vui_inst (
	.clk        (clk_sys),
	.valid      (sh_valid),
	.aspect_idc (sh_ar_idc),
	.ext_sar_w  (sh_sar_w),
	.ext_sar_h  (sh_sar_h),
	.w_mbs      (sh_w),
	.hf_mbs     (sh_hf),
	.known      (vui_sar_known),
	.wide       (vui_wide),
	.sar_w_o    (fit_sar_w),
	.sar_h_o    (fit_sar_h)
);
// square pixels: 9 * W > 14 * H in macroblocks (aspect_vui's rule with sar 1:1)
reg sq_wide_q = 1'b0;
always @(posedge clk_sys)
	sq_wide_q <= ({4'd0, sh_w, 3'd0} + {7'd0, sh_w}) > ({3'd0, sh_hf, 4'd0} - {6'd0, sh_hf, 1'b0});
wire idle_wide  = ~stream_live & disp_wide_q;
wire live_wide  = vui_sar_known ? vui_wide : sq_wide_q;
reg  last_wide_q = 1'b0;                  // the last picture's, held between streams
always @(posedge clk_sys) if (stream_live) last_wide_q <= live_wide;
wire auto_wide  = stream_live ? live_wide : (played ? last_wide_q : idle_wide);
// P6 (docs/analog.md §5, decided 2026-09-29): in Progressive the raster is FILLED with the
// picture (the fit's Fit mode) and Auto gives the scaler the picture's exact display aspect,
// sar_w Wc : sar_h Hc (the cropped size), shifted down together until both fit 12 BITS: in
// sys_top a VIDEO_ARX / ARY with bit 12 set is not a ratio but an explicit output size in
// pixels (`arxy`: wcalc <= arx) -- a 13-bit ratio would size the HDMI picture literally. A
// shift keeps the ratio to 1 part in 2,048 (no gcd needed); portrait arrives as 9 : 16.
// When the raster carries a 4:3 fit (480i, or Analog Aspect set explicitly) Auto is 4:3 -- 16:9 under
// Fit, the anamorphic 16:9 fit (issue #11: fit_169 below).
// Idle, the display's own (auto_wide). Registered: the inputs change only with the shown picture.
reg  [27:0] ex_x, ex_y;
reg  [11:0] ar_x, ar_y;
wire [27:0] ex_or = ex_x | ex_y;
// A' (fit_lb): the raster is shown at the display's shape, HDMI_WIDTH : HDMI_HEIGHT as latched
// for the fit (12 bits each already), not the picture's (docs/hdmi_raster.md §3a).
// F8 (docs/hdmi_raster.md §7): ar_x / ar_y follow the fit ONLY while a picture is shown. Between
// streams (a stop, a seek's or a track change's restart: the per-stream reset clears sh_w / sh_hf)
// the fit is computed from a 0x0 picture, which gave 0 : 0 -- HDMI's "fill" (sys_top's FREESCALE
// path), word 47 reading 0, and an aspect change Main may answer by re-programming the HDMI mode.
// Held, the last picture's aspect stays until the next picture (the 2026-09-27 rule: between
// streams the Auto aspect holds the last picture's). ar_exact is 0 until a picture has played.
always @(posedge clk_sys) begin
	ex_x <= {16'd0, fit_wc} * {12'd0, fit_sar_w};
	ex_y <= {16'd0, fit_hc} * {12'd0, fit_sar_h};
	if      (!stream_live) begin ar_x <= ar_x; ar_y <= ar_y; end
	else if (fit_lb || (geom_nat && geom_disp)) begin ar_x <= fit_dw_l; ar_y <= fit_dh_l; end   // A', native display-shaped
	else if (ex_or[27]) begin ar_x <= ex_x[27:16]; ar_y <= ex_y[27:16]; end
	else if (ex_or[26]) begin ar_x <= ex_x[26:15]; ar_y <= ex_y[26:15]; end
	else if (ex_or[25]) begin ar_x <= ex_x[25:14]; ar_y <= ex_y[25:14]; end
	else if (ex_or[24]) begin ar_x <= ex_x[24:13]; ar_y <= ex_y[24:13]; end
	else if (ex_or[23]) begin ar_x <= ex_x[23:12]; ar_y <= ex_y[23:12]; end
	else if (ex_or[22]) begin ar_x <= ex_x[22:11]; ar_y <= ex_y[22:11]; end
	else if (ex_or[21]) begin ar_x <= ex_x[21:10]; ar_y <= ex_y[21:10]; end
	else if (ex_or[20]) begin ar_x <= ex_x[20:9];  ar_y <= ex_y[20:9];  end
	else if (ex_or[19]) begin ar_x <= ex_x[19:8];  ar_y <= ex_y[19:8];  end
	else if (ex_or[18]) begin ar_x <= ex_x[18:7];  ar_y <= ex_y[18:7];  end
	else if (ex_or[17]) begin ar_x <= ex_x[17:6];  ar_y <= ex_y[17:6];  end
	else if (ex_or[16]) begin ar_x <= ex_x[16:5];  ar_y <= ex_y[16:5];  end
	else if (ex_or[15]) begin ar_x <= ex_x[15:4];  ar_y <= ex_y[15:4];  end
	else if (ex_or[14]) begin ar_x <= ex_x[14:3];  ar_y <= ex_y[14:3];  end
	else if (ex_or[13]) begin ar_x <= ex_x[13:2];  ar_y <= ex_y[13:2];  end
	else if (ex_or[12]) begin ar_x <= ex_x[12:1];  ar_y <= ex_y[12:1];  end
	else                begin ar_x <= ex_x[11:0];  ar_y <= ex_y[11:0];  end
end
// Native (HDMI): HDMI is given the raster's own shape -- the display's (fit_dw_l : fit_dh_l, known from
// the HDMI mode) when it is display-shaped, the picture's when it fell back to picture-sized -- never
// Display Shape's. Display-shaped once took Display Shape's 4:3 / 16:9, so at 4:3 a raster laid out for
// a 16:9 display was squeezed into 4:3 (found on the DE10 2026-10-19). Display Shape still shapes the
// fitted raster Native uses between pictures (the menus).
wire native_raster = geom_nat;
wire ar_wide    = status[2];
// (issue #11, decided 2026-10-11 with the maintainer) Analog Aspect Fit is the anamorphic 16:9 fit: the
// raster is meant to be shown at 16:9, as a TV in its wide mode shows it, so HDMI's Auto is 16:9 there --
// except on Main's SD modes, 720x480 and 720x576, which it sends as CEA's 16:9 VIC 3 / 18 (the AVI frame's
// 16:9 bit set): the TV stretches that frame to 16:9 itself, so the raster FILLS it (the mode's own shape,
// HDMI_WIDTH : HDMI_HEIGHT -- ascal treats the frame as square pixels). Found on .201 2026-10-11 with the
// maintainer: 16:9 there gave a 720x405 window, letterboxed on the TV (docs/analog.md §5a).
wire fit_169    = raster_fitted && (status[9:8] == 2'd1);
reg  hdmi_sd16  = 1'b0;                        // Main's 720x480 / 720x576 HDMI modes (16:9 VIC 3 / 18)
always @(posedge clk_sys)
	hdmi_sd16 <= (HDMI_WIDTH == 12'd720) && (HDMI_HEIGHT == 12'd480 || HDMI_HEIGHT == 12'd576);
reg  [11:0] hdmi_w_q = 12'd720, hdmi_h_q = 12'd480;
always @(posedge clk_sys) begin hdmi_w_q <= HDMI_WIDTH; hdmi_h_q <= HDMI_HEIGHT; end
assign VIDEO_ARX = native_raster ? {1'b0, ar_x} : ar_wide ? 13'd16 : 13'd4;
assign VIDEO_ARY = native_raster ? {1'b0, ar_y} : ar_wide ? 13'd9  : 13'd3;

// =========================================================================
// The status block (docs/architecture.md "The HPS interface, v0.1": the control block's
// words 0-31, rewritten every raster frame; the telemetry). h264/ring_stat.sv builds it on
// clk_sys from three muxes generated by tools/ring_layout.py: this domain's words
// (ring_words_sys) directly, clk_mem's and clk_dec's through its two cdc_snap_ix; the
// reader's engine writes it. Reset by the PLL lock alone: the heartbeat never restarts.
// =========================================================================
reg [1:0] osd_q = 2'b00;                  // OSD_STATUS into clk_sys
always @(posedge clk_sys) osd_q <= {osd_q[0], OSD_STATUS};
wire [31:0] st_seq, st_skips;
wire  [6:0] st_sys_ix;                    // interface 0.10: 7 bits (words 80-87)
wire  [5:0] st_mem_ix, st_dec_ix;
wire [63:0] st_sys_word, st_mem_word, st_dec_word;
// interface 0.6: the input region (docs/architecture.md "Input (interface 0.6)"): hps_io's pads,
// keys and mouse, mirrored into words 48-71 for a program to forward (Main grabs every input
// device while a core runs). Written by ring_stat as its second job; reset by the PLL lock alone
// (an OSD Reset must not move the counts a program keeps).
wire        in_req, in_go, in_busy;
wire  [4:0] in_ix;
wire [63:0] in_word;
function [31:0] input_region_joy(input [31:0] joy);
	begin
		// Compact JN slots: OK, Back, Page Back, Page Forward, Pause/Play. Preserve the
		// ring/app layout: d-pad [3:0], B [5], A [4], LB [8], RB [9], Start [11].
		input_region_joy = {20'b0, joy[8], 1'b0, joy[7:6], 2'b0, joy[4], joy[5], joy[3:0]};
	end
endfunction
ring_in ring_in_inst (
	.clk           (clk_sys),
	.rst_n         (lock_sys_n),
	.frame         (frame_sys),
	.joy           ({input_region_joy(joystick_5), input_region_joy(joystick_4),
	                 input_region_joy(joystick_3), input_region_joy(joystick_2),
	                 input_region_joy(joystick_1), input_region_joy(joystick_0)}),
	.ana_l         ({joystick_l_analog_5, joystick_l_analog_4, joystick_l_analog_3,
	                 joystick_l_analog_2, joystick_l_analog_1, joystick_l_analog_0}),
	.ana_r         ({joystick_r_analog_5, joystick_r_analog_4, joystick_r_analog_3,
	                 joystick_r_analog_2, joystick_r_analog_1, joystick_r_analog_0}),
	.ps2_key       (ps2_key),
	.ps2_mouse     (ps2_mouse),
	.ps2_mouse_ext (ps2_mouse_ext),
	.osd           (osd_q[1]),
	.act           (status[18:17]),         // (0.8) the OSD's actions: Main pulses the bit, the edge is the event
	.in_req        (in_req),
	.in_go         (in_go),
	.in_busy       (in_busy),
	.in_ix         (in_ix),
	.in_word       (in_word),
	.n_events      ()
);
ring_stat ring_stat_inst (
	.clk      (clk_sys),
	.rst_n    (lock_sys_n),
	.frame    (frame_sys),
	.st_free  (st_free),
	.seq      (st_seq),
	.n_skips  (st_skips),
	.sys_ix   (st_sys_ix),
	.sys_word (st_sys_word),
	.mclk     (clk_mem),
	.mrst_n   (mem_lock_n),
	.mem_ix   (st_mem_ix),
	.mem_word (st_mem_word),
	.dclk     (clk_dec),
	.drst_n   (lock_dec_n),
	.dec_ix   (st_dec_ix),
	.dec_word (st_dec_word),
	.in_req   (in_req),                 // 0.6: the input region (ring_in, below)
	.in_go    (in_go),
	.in_busy  (in_busy),
	.in_ix    (in_ix),
	.in_word  (in_word),
	.st_word  (st_word),
	.st_ix    (st_ix),
	.st_wr    (st_wr),
	.st_grp   (st_grp)
);
// (0.17, the Jellyfin client's F5) the fit's status describes the SHOWN picture: with none shown (a session's ready
// screen, after a flush) disp_fit works on a 0 x 0 picture and its flags read as faults -- so they, the rectangle
// and its place on the raster read 0 until disp_ctl has a picture up (sh_valid), and fit_valid says which
wire        st_fit_valid    = sh_valid;
wire        st_fit_crop_bad = sh_valid & fit_crop_bad;
wire        st_fit_clamp    = sh_valid & fit_clamp;
wire        st_fit_snap     = sh_valid & fit_snap;
wire [12:0] st_fit_ow       = sh_valid ? fit_ow : 13'd0;
wire [12:0] st_fit_oh       = sh_valid ? fit_oh : 13'd0;
wire [12:0] st_pic_x0       = sh_valid ? fit_ox0[12:0] : 13'd0;   // two's complement (>= -3,736: ow <= 8,191)
wire [12:0] st_pic_y0       = sh_valid ? fit_oy0[12:0] : 13'd0;
ring_words_sys ring_words_sys_inst (
	.ix               (st_sys_ix),
	.f_seq_head       (st_seq),
	.f_state          (rr_state),
	.f_err            (rr_err),
	.f_live           ({rr_gfx, rr_sess, osd_q[1], played, disp_stc_run, disp_ended, rr_eos_seen, rr_ll}),
	.f_osd            ({4'd0, status[4:1]}),
	.f_err_pos        (rr_err_pos),
	.f_err_word       (rr_err_word),
	.f_stc            (disp_stc),
	.f_lag_ms         (disp_lag_ms),
	.f_n_au           (rr_n_au),
	.f_n_audio        (rr_n_audio),
	.f_n_pad          (rr_n_pad),
	.f_n_streams      (rr_n_streams),
	.f_es_bytes       (rr_es_bytes),
	.f_ll_mismatch    (rr_ll_mismatch),
	.f_disp_dc        (disp_dc),
	.f_disp_pick      (disp_pick),
	.f_disp_skip      (disp_skip),
	.f_disp_late      (disp_late),
	.f_disp_starve    (disp_starve),
	.f_disp_cadence   (disp_cadence),
	.f_disp_reanchor  (disp_reanchor),
	.f_disp_flags     (disp_flags),
	.f_disp_lone      (disp_lone),
	.f_disp_fetch_late(disp_fetch_late),   // P6 step 3 (interface 0.2): the fit's telemetry, word 30
	.f_fit_crop_bad   (st_fit_crop_bad),
	.f_fit_clamp      (st_fit_clamp),
	.f_fit_snap       (st_fit_snap),
	.f_osd_aspect     (status[2:1]),       // (interface 0.4) the OSD mirror, word 27: every option as the menu holds it
	.f_osd_deint      (status[4:3]),
	.f_osd_video_out  (status[6:5]),
	.f_osd_hdmi_deint (status[7]),
	.f_osd_analog_aspect (status[9:8]),
	.f_osd_refresh    (status[12:11]),
	.f_osd_anti_twitter (status[29] ? 2'd1 : 2'd2), // legacy mirror: Off=1, On=2
	.f_display_profile (output_profile),
	.f_display_match_refresh (match_refresh != 0),
	.f_display_refresh_match_mode (match_refresh),
	.f_display_240p (status[24]),
	.f_display_240p_active (prog240_eff),
	.f_display_film_speed (status[25] && film_speed_allowed),
	.f_display_wide (status[2]),
	.f_display_effective_profile ({1'b0, effective_profile}),
	.f_display_raster_std (raster_std),
	.f_display_interlaced (raster_il_eff),
	.f_display_deflicker (!status[29] && raster_il_eff),
	.f_gfx_mismatch   (rr_gfx_mismatch),
	.f_set_err        (req_err),           // 0.4: the settings request's result and sequence number
	.f_set_seq        (req_seq),
	.f_raster_std     (raster_std),        // (interface 0.3) the raster report, word 30
	.f_raster_il      (raster_il_eff),
	.f_raster_auto    (status[12:11] == 2'd0),
	.f_anti_twitter   (fit_slide),
	.f_fit_ow         (st_fit_ow),
	.f_fit_oh         (st_fit_oh),
	.f_fit_valid      (st_fit_valid),       // (0.17) a picture is shown: word 30's fit and word 80's place describe it
	.f_seq_tail       (st_seq),
	.f_geometry_ack_seq (rr_geom_ack_seq),
	.f_geometry_error (rr_geom_error),
	.f_aud_state      (aud_st_state),      // (interface 0.5) words 40-45: the audio path, the pause word
	.f_aud_ll         (aud_ll),
	.f_aud_q_rec      (aud_q_rec),
	.f_aud_q_samples  (aud_q_samples),
	.f_aud_played     (aud_n_played),
	.f_aud_records    (aud_n_records),
	.f_aud_gap        (aud_n_gap),
	.f_aud_late       (aud_n_late),
	.f_aud_underruns  (aud_n_underruns),
	.f_aud_slip_drop  (aud_n_slip_drop),
	.f_aud_slip_rep   (aud_n_slip_rep),
	.f_aud_anchor     (aud_n_anchor),
	.f_aud_offset     (aud_offset),
	.f_aud_hold_bytes (aud_hold_bytes),
	.f_paused         (ctl_pause),
	.f_ctl_err        (ctl_err),
	.f_atten          (ctl_atten),
	.f_ovl_gen        (ovl_gen),           // (interface 0.9) words 46-47: the overlay plane
	.f_ovl_state      (ovl_state),
	.f_ovl_at         (ovl_at),
	.f_ovl_clip       (ovl_clip),
	.f_ovl_err        (ovl_err),
	.f_ovl_torn       (ovl_torn),
	.f_ovl_late       (ovl_late),
	.f_ar_x           (VIDEO_ARX[11:0]),   // the aspect HDMI's scaler is given (bit 12 is clear: a ratio)
	.f_ar_y           (VIDEO_ARY[11:0]),
	.f_ovl_lines      (ovl_lines),
	.f_raster_w       (geom_rw),           // (interface 0.10) word 80: the raster (raster_geom: 720 x 480 / 576 fitted)
	.f_raster_h       (geom_rh),
	.f_raster_mode    (geom_mode),
	.f_raster_lb      (fit_lb | (geom_nat & geom_disp)),   // shown at the display's shape (A', or native display-shaped)
	.f_video_out      (video_out_eff),      // (0.14) Video Output as resolved (Auto: Interlaced, Progressive or Native)
	.f_colour         (sh_colour),          // (0.16) word 80: the shown picture's colour code
	.f_pic_x0         (st_pic_x0),          // (0.17) 0 while no picture is shown
	.f_pic_y0         (st_pic_y0),
	.f_rum_p0         (rumble[15:0]),      // (interface 0.13) words 82-83: the rumble passed to Main
	.f_rum_p1         (rumble[31:16]),
	.f_rum_p2         (rumble[47:32]),
	.f_rum_p3         (rumble[63:48]),
	.f_rum_p4         (rumble[79:64]),
	.f_rum_p5         (rumble[95:80]),
	.f_rum_changes    (rum_changes),
	.f_pic_held       (pic_held),          // (interface 0.15) word 84: the stores' state (the store rule)
	.f_pic_mode       (rr_pic_mode),
	.f_pic_emitted    (pic_emitted_s),
	.f_disp_fhold     (disp_fhold),        // (0.15) word 85: field pairs held for the raster's field (disp_ctl)
	.f_vui_matrix     (sh_col_tags[7:0]),   // (0.16) word 86: the shown picture's colour description (docs/colour.md)
	.f_vui_primaries  (sh_col_tags[23:16]),
	.f_vui_transfer   (sh_col_tags[15:8]),
	.f_vui_full_range (sh_col_tags[24]),
	.f_vui_colour_present (sh_col_tags[25]),
	.f_colour_override (rr_colour != 3'd0),
	.f_colour_unsup   (disp_col_unsup),
	.f_colour_mismatch (rr_colour_mismatch),
	.w                (st_sys_word)
);
ring_words_mem ring_words_mem_inst (
	.ix               (st_mem_ix),
	.f_read_index     (rr_read_index),
	.f_ack_nonce      (rr_ack_nonce),
	.f_n_polls        (rr_n_polls),
	.f_n_bursts       (rr_n_bursts),
	.f_eng_err        (rr_eng_err),
	.f_eng_session    (rr_eng_session),
	.f_eng_widx       (rr_eng_widx),
	.f_fetch_changes  (disp_fetch_changes),
	.f_probe_busy     (probe_busy),
	.f_probe_wr       (probe_wr),
	.f_probe_rd       (probe_rd),
	.f_probe_owed     (probe_owed),
	.f_probe_busy_max (probe_busy_max),
	.w                (st_mem_word)
);
ring_words_dec ring_words_dec_inst (
	.ix               (st_dec_ix),
	.f_fe_nal         (fe_nal),
	.f_fe_slice       (fe_slice),
	.f_fe_pic         (fe_pic),
	.f_fe_refused     (fe_refused),
	.f_fe_err         (fe_err),
	.f_fe_bins        (fe_bins[39:8]),
	.f_fe_pts_tag     (fe_pts_tag),
	.f_fe_pts_drop    (fe_pts_drop),
	.f_fe_refused_code(fe_refused_code),
	.f_fe_err_code    (fe_err_code),
	.f_rc_err_code    (rc_err_code),
	.f_fe_pic_struct  (fe_pic_struct),
	.f_rc_dpb_fill    (rc_dpb_fill),
	.f_out_ovf        (out_ovf),
	.f_out_rel_bad    (out_rel_bad),
	.f_fe_sei_err     (fe_sei_err),
	.f_rc_pic         (rc_pic),
	.f_rc_mb          (rc_mb),
	.f_rc_err         (rc_err),
	.f_rc_ref_size    (rc_ref_size),
	.f_rc_out_dropped (rc_out_dropped),
	.f_rc_out_direct  (rc_out_direct),
	.f_rc_out_over    (rc_out_over),
	.f_rc_stall       (rc_stall),
	.f_rc_nrf_late    (rc_nrf_late),
	.f_out_emit       (out_emit),
	.f_out_rel        (out_rel),
	.f_fe_pt_missing  (fe_pt_missing),
	.w                (st_dec_word)
);

// =========================================================================
// Decoder compute domain placeholder (see h264/dec_stub.sv for why this exists)
// =========================================================================
wire dec_alive;
dec_stub dec_stub_inst (
	.clk_dec   (clk_dec),
	.clk_sys   (clk_sys),
	.rst_n     (reset_n),
	.dec_alive (dec_alive)
);

// =========================================================================
// Audio (Phase 4, interface 0.5; docs/architecture.md "Audio (Phase 4)"): the program decodes
// (D2) and writes 48 kHz s16 stereo PCM as AUDIO records into the ring; the ring IS the
// buffer. h264/aud_play.sv takes each record's descriptor from the reader's parser, fetches
// its samples through the reader's engine when they are about to play (holding the read
// index behind them), and presents them against the display's STC (paced) or a queue target
// (the stream's LOW_LATENCY), on a 48 kHz tick from clk_sys -- the crystal the raster and the
// STC run from. The framework's ALSA mixer stays compiled out (MISTER_DISABLE_ALSA):
// sys/audio_out.sv samples AUDIO_L / R at its own 48 kHz through two flops, as for any core.
// =========================================================================
wire signed [15:0] aud_l, aud_r;
wire        aud_ll = rr_ll && rr_vid_seen;   // before the stream's first VIDEO_AU: paced
aud_play aud_play_inst (
	.clk         (clk_sys),
	.rst_n       (reset_n),
	.srst_n      (fe_rst_n),
	.lrst_n      (lock_sys_n),
	.ad_push     (ad_push),
	.ad_pos      (ad_pos),
	.ad_len      (ad_len),
	.ad_pts      (ad_pts),
	.ad_ptsv     (ad_ptsv),
	.ad_room     (ad_room),
	.a_hold_v    (a_hold_v),
	.a_hold_idx  (a_hold_idx),
	.aud_idle    (aud_idle),
	.af_go       (af_go),
	.af_addr     (af_addr),
	.af_n        (af_n),
	.af_busy     (af_busy),
	.af_dout     (af_dout),
	.af_valid    (af_valid),
	.af_empty    (af_empty),
	.af_rd       (af_rd),
	.stc         (disp_stc),
	.stc_run     (disp_stc_run),
	.aanc        (aud_anc),
	.aanc_pts    (aud_anc_pts),
	.aud_lead    (aud_lead),
	.ll          (aud_ll),
	.pause       (ctl_pause),
	.atten       (ctl_atten),
	.audio_l     (aud_l),
	.audio_r     (aud_r),
	.st_state    (aud_st_state),
	.q_rec       (aud_q_rec),
	.q_samples   (aud_q_samples),
	.n_played    (aud_n_played),
	.n_records   (aud_n_records),
	.n_gap       (aud_n_gap),
	.n_late      (aud_n_late),
	.n_underruns (aud_n_underruns),
	.n_slip_drop (aud_n_slip_drop),
	.n_slip_rep  (aud_n_slip_rep),
	.n_anchor    (aud_n_anchor),
	.offset      (aud_offset)
);
assign AUDIO_L   = aud_l;
assign AUDIO_R   = aud_r;
assign AUDIO_S   = 1'b1;                 // signed
assign AUDIO_MIX = 2'd0;                 // stereo as given (the program downmixes)

// =========================================================================
// DDR3: ram1 = the DPB and the HPS interface (behind h264/ddr_mux2.sv: A the DPB, B the ring reader),
// ram2 = the display reader (read-only). Both on clk_mem (docs/architecture.md "Memory
// ports").
// =========================================================================
assign DDRAM_CLK  = clk_mem;
assign DDRAM2_CLK = clk_mem;
assign DDRAM2_WE  = 1'b0;
assign DDRAM2_DIN = 64'd0;
assign DDRAM2_BE  = 8'hFF;

// =========================================================================
// Unused framework interfaces
// =========================================================================
assign SD_SCK  = 1'b0;
assign SD_MOSI = 1'b0;
assign SD_CS   = 1'b1;
assign UART_RTS = 1'b1;
assign UART_TXD = 1'b1;
assign UART_DTR = 1'b1;
assign USER_OUT = 7'h7F;
// ADC_BUS: left undriven (high-Z), as the Template does when the ADC is unused.

// =========================================================================
// LEDs
// =========================================================================
assign LED_POWER = 2'b00;                       // framework controls it
assign LED_DISK  = 2'b00;                       // {enable, value}: nothing to show yet
assign LED_USER  = dec_alive;                   // ~4.8 Hz: the clk_dec domain is alive

endmodule
