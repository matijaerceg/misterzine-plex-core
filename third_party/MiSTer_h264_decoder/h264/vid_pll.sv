// h264/vid_pll.sv -- the raster's clock, clk_vid (docs/hd_raster.md S2, Phase 5c part 3)
//
// Input:  50 MHz (FPGA_CLK2_50 via sys_top: the pin sys_pll runs from)
// Output: outclk_0  81 MHz  clk_vid -- CLK_VIDEO; the raster side (sync_gen, the reader's and the
//                                       overlay's read-outs, the output stage) on a dot enable:
//                                       one clock in three on the 27 MHz rasters (480i / 576i,
//                                       480p / 576p: the analog pins exactly as at 27 MHz), every
//                                       clock on the native one.
//
// Why a second PLL: 81 = 3 x 27 is not a divisor of sys_pll's 1,350 MHz VCO, and no VCO in range
// makes 81, 90 and ~96 together (1,620 is over the 1,600 limit; 1,215 costs clk_mem and clk_dec
// ~3 %). VCO 810 = 50 x 81 / 5, / 10. Integer-N from the same crystal as sys_pll: exactly three
// clk_vid cycles per 27 MHz dot, so the raster never drifts against disp_ctl's refresh grid on
// clk_sys -- but the PHASE is unrelated: every transfer goes through a crossing primitive
// (h264/raster_xing.sv) and sys/sys_top.sdc keeps this clock in the core PLL's timed group (an
// H264-FORK line), the crossings bounded by name in h264/h264.sdc.
//
// The instance MUST be named vid_pll: tools/fmax_check.sh gates clk_vid by the hierarchical name
// emu|vid_pll|altera_pll_i|general[0]..., and sys_top.sdc's group pattern names it.
// `ifdef QUARTUS as sys_pll; simulation passes refclk through (benches make their own clocks).
//
// outclk_1, 27 MHz, clk_vid_dv (dv27, 2026-10-29): with MiSTer.ini direct_video=1, sys_top clocks the
// HDMI transmitter from the core's clock (its hdmi_clk_sw), and on clk_vid that sent every 27 MHz
// dot three times: a 480i line of 5,148 pixels at 81 MHz, which HDMI-to-VGA DACs refuse (black on a
// Ugreen, scrambled on a GE; docs/hd_raster.md S11 had left it to confirm). The H264-FORK line in
// sys_top takes this clock for the transmitter instead, so the DAC sees the plain 27 MHz 480i / 480p
// (576i / 576p) raster: one dot per clock, 480i's pixel repetition as two clocks a pixel. The raster
// side stays on clk_vid; sys_top's dv_* registers (clk_vid) hold each dot for its three clocks, so
// the transmitter's 27 MHz register takes every dot exactly once at any fixed phase. The phase is
// shifted half a clk_vid period (6,173 ps) so no 27 MHz edge coincides with an 81 MHz one: the
// tightest clk_vid -> clk_vid_dv pair is then 6.2 ns, which TimeQuest times (same PLL, same group).

`timescale 1ns/10ps
module vid_pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0, // 81 MHz -- clk_vid
	output wire outclk_1, // 27 MHz -- clk_vid_dv: the HDMI transmitter's clock on direct_video (below)
	output wire locked
);

`ifdef QUARTUS

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(2),
		.output_clock_frequency0("81.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("27.000000 MHz"),
		.phase_shift1("6173 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   ({outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

`else
	assign outclk_0 = refclk;
	assign outclk_1 = refclk;
	assign locked   = 1'b1;
`endif

endmodule
