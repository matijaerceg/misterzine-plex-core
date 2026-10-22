// h264/vid_out.sv -- the output stage: the picture or the idle screen, the overlay composited over
// it, the syncs delayed to match, into the VGA registers; and the analog composite sync.
// (hd_raster, docs/hd_raster.md S3: factored out of emu.sv unchanged, onto clk_vid and the dot
// enable, so the SD equivalence bench -- bench/h264/vid_equiv_tb.sv -- runs exactly what emu runs.)
//
// The display reader is LAT 9 from (h_pos, v_pos, de_in) (hd_raster: 5 at 27 MHz; deepened for
// 81 MHz); idle_bars is LAT 2, so its colour is delayed seven more dots. The decoded picture where it
// covers the raster (pic_de), else the idle screen (black while a stream is live: a picture smaller
// than the raster is framed) -- selected into a register (sel_*_q), beside the overlay plane's
// pixel (LAT 9 too, ovl_*_q); then the overlay's composite (h264/ovl_blend.sv: its products
// registered, LAT_BLEND) into the output registers. Sync / DE are delayed eleven, then the output
// register: the output stage is the picture's LAT + 1 + LAT_BLEND = 11, the pins 12 dots after
// sync_gen (Phase 6b: 6 / 7 at 27 MHz). Every register advances on `ce` -- LAT is counted in DOTS
// (tools/check_emu_wiring.py reads it so) -- except vga_ce: CE_PIXEL is high for ONE clock, the
// first of the dot's output (the clock after its load), so sys_top samples each dot once on the
// 81 MHz clock: every clock on the native raster, one in three on the 27 MHz rasters, and at 480i
// one dot in two of those (pixel repetition, ce_pix).
//
// The analog composite sync (h264/csync_smpte.sv, SMPTE 170M: equalizing pulses and 2H
// serrations) from the raster itself, in place of the framework's (no equalizing pulses: the
// fields' first broad pulses ~18 / ~50 us), on the 15 kHz raster only (cs_en follows en; 480p
// keeps the framework's). Its hsync input is the one VGA_HS's register takes, so the one-dot
// output lands in VGA_HS's dot, as sys_top's CS_PIPE expects.

`default_nettype none

// (hd_raster) no M10K shift registers: a delay chain on the dot inferred as altshift_taps put a RAM's
// slow clock-to-out on an 81 MHz path (the first stage-A fit)
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module vid_out (
    input  wire        clk,                // clk_vid
    input  wire        ce,                 // the dot
    input  wire        rst_n,              // csync's
    // the raster (sync_gen, registered: the dot's)
    input  wire        h_sync,
    input  wire        v_sync,
    input  wire        pixel_en,
    input  wire        ce_pix,             // 480i: the pixel-repetition phase
    input  wire        field,
    input  wire [11:0] v_pos,
    input  wire        il,                 // the 15 kHz raster (csync on)
    input  wire        prog240,            // progressive 15 kHz 240p/288p raster
    input  wire        pal,

    // the sources: the picture (LAT 9), the idle screen (LAT 2), the overlay (LAT 9, premultiplied)
    input  wire  [7:0] pic_r,
    input  wire  [7:0] pic_g,
    input  wire  [7:0] pic_b,
    input  wire        pic_de,
    input  wire  [7:0] idle_r,
    input  wire  [7:0] idle_g,
    input  wire  [7:0] idle_b,
    input  wire  [7:0] ovl_pr,
    input  wire  [7:0] ovl_pg,
    input  wire  [7:0] ovl_pb,
    input  wire  [7:0] ovl_pa,
    // the outputs (LAT 12 from sync_gen)
    output reg   [7:0] vga_r,
    output reg   [7:0] vga_g,
    output reg   [7:0] vga_b,
    output reg         vga_hs,
    output reg         vga_vs,
    output reg         vga_de,
    output reg         vga_ce,             // CE_PIXEL
    output reg         vga_f1,
    output wire        cs,
    output wire        cs_en
);

// (hd_raster) the latencies, in dots: the picture's and the overlay's read-outs (disp_reader /
// ovl_plane "LAT 9"), the idle screen's (idle_bars, 2), the composite's register (ovl_blend PIPE 1)
localparam int LAT_PIC   = 9;
localparam int LAT_BLEND = 1;
reg [15:0] idle_rg_q1, idle_rg_q2, idle_rg_q3, idle_rg_q4, idle_rg_q5, idle_rg_q6, idle_rg_q7;
reg  [7:0] idle_b_q1, idle_b_q2, idle_b_q3, idle_b_q4, idle_b_q5, idle_b_q6, idle_b_q7;
always @(posedge clk) if (ce) begin
	idle_rg_q1 <= {idle_r, idle_g}; idle_b_q1 <= idle_b;
	idle_rg_q2 <= idle_rg_q1;       idle_b_q2 <= idle_b_q1;
	idle_rg_q3 <= idle_rg_q2;       idle_b_q3 <= idle_b_q2;
	idle_rg_q4 <= idle_rg_q3;       idle_b_q4 <= idle_b_q3;
	idle_rg_q5 <= idle_rg_q4;       idle_b_q5 <= idle_b_q4;
	idle_rg_q6 <= idle_rg_q5;       idle_b_q6 <= idle_b_q5;
	idle_rg_q7 <= idle_rg_q6;       idle_b_q7 <= idle_b_q6;
end
reg [10:0] hs_dly, vs_dly, de_dly, ce_dly, f1_dly;
always @(posedge clk) if (ce) begin
	hs_dly <= {hs_dly[9:0], h_sync};
	vs_dly <= {vs_dly[9:0], v_sync};
	de_dly <= {de_dly[9:0], pixel_en};    // the raster's active area, LAT 12 like hs / vs
	ce_dly <= {ce_dly[9:0], ce_pix};      // 480i: the pixel-repetition phase, with the dots
	f1_dly <= {f1_dly[9:0], field};       // 480i: the field (VGA_F1), with its lines
end

reg [7:0] sel_r_q, sel_g_q, sel_b_q;      // the video: the picture, the idle screen or black
reg [7:0] ovl_r_q, ovl_g_q, ovl_b_q, ovl_a_q;
always @(posedge clk) if (ce) begin
	sel_r_q  <= pic_de ? pic_r : de_dly[8] ? idle_rg_q7[15:8] : 8'd0;
	sel_g_q  <= pic_de ? pic_g : de_dly[8] ? idle_rg_q7[7:0]  : 8'd0;
	sel_b_q  <= pic_de ? pic_b : de_dly[8] ? idle_b_q7        : 8'd0;
	ovl_r_q  <= ovl_pr;
	ovl_g_q  <= ovl_pg;
	ovl_b_q  <= ovl_pb;
	ovl_a_q  <= ovl_pa;
end
wire [7:0] ob_r, ob_g, ob_b;
ovl_blend #(.PIPE(LAT_BLEND)) ovl_blend_inst (
	.clk (clk),
	.ce  (ce),
	.v_r (sel_r_q),
	.v_g (sel_g_q),
	.v_b (sel_b_q),
	.p_r (ovl_r_q),
	.p_g (ovl_g_q),
	.p_b (ovl_b_q),
	.p_a (ovl_a_q),
	.r   (ob_r),
	.g   (ob_g),
	.b   (ob_b)
);

always @(posedge clk) begin
	if (ce) begin
		vga_r  <= ob_r;
		vga_g  <= ob_g;
		vga_b  <= ob_b;
		vga_hs <= hs_dly[10];
		vga_vs <= vs_dly[10];
		vga_de <= de_dly[10];
		vga_f1 <= f1_dly[10];
	end
	vga_ce <= ce & ce_dly[10];            // one clock a dot, with the dot's first output clock
end

wire prog240_i = (prog240 === 1'b1);
csync_smpte csync_smpte_inst (
	.clk    (clk),
	.ce     (ce),
	.rst_n  (rst_n),
	.mode   (1'b0),                   // the SMPTE block (DVD's 2H-only variant not offered)
	.en     (il | prog240_i),
	.prog   (prog240_i),
	.pal    (pal),                    // P6 step 6: BT.470's 5 / 5 / 5 block on the 576i raster
	.h_sync (hs_dly[10]),
	.v_pos  (v_pos),                  // {field line, parity}: chooses the block's line only
	.cs     (cs),
	.cs_en  (cs_en)
);

endmodule

`default_nettype wire
