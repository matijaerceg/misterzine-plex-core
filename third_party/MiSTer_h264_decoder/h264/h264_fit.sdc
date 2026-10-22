# h264/h264_fit.sdc -- the FITTER's own target for clk_dec (perf/retime, 2026-10-13; docs/throughput.md S8).
#
# Quartus' Auto Fit eases off once a clock's constraint is met: clk_dec's is its real 96.43 MHz, so fits
# landed anywhere from ~93 to ~104 MHz by seed against the 101.4 MHz gate (tools/fmax_check.sh), and every
# branch since 93 % ALM needed a seed sweep. 0.8 ns of extra setup uncertainty into clk_dec while quartus_fit
# runs makes the fitter aim at ~104.5 MHz; quartus_sta -- the gate's report -- does not read it (the branch
# below), so the gate still measures the real clock with the framework's derived uncertainty.
#
# Its own file, named in H264.qsf AFTER sys/sys.qip: sys_top.sdc creates the PLL clocks (derive_pll_clocks),
# and h264.sdc is read before it -- the uncertainty there matched no clock and was ignored (found on the
# first try: the fit identical to the bit).
if {[info exists ::quartus(nameofexecutable)] && $::quartus(nameofexecutable) eq "quartus_fit"} {
    set_clock_uncertainty -setup -add -to [get_clocks {emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] 0.8
}
