# timing_paths.tcl — dump the top intra-clk_dec setup paths (the Fmax-limiter cluster).
#
# The clk_dec Fmax limiter MOVES as
# features grow — framestore_request (MiSTer_DVD PR #58) → disp_vscale (its PR #92) → ??? . Before
# retiming anything, MEASURE which cluster is on top NOW. This script is the
# one-command version of the report_timing step MiSTer_DVD PR #92 ran by hand.
#
# Run via the wrapper (handles Docker):   [USE_DOCKER=1] tools/timing_paths.sh [npaths]
# or directly:                            quartus_sta -t tools/timing_paths.tcl [npaths]
#
# Output: output_files/clk_dec_paths.txt — a summary table of the top N intra-clk_dec
# setup paths (slow 1100mV corner: TIMING_TEMP, default 100C) + the 3 worst paths
# in full detail. Read the From/To Node columns to spot the dominant cluster.

set rev H264
set npaths 100
if { [info exists quartus(args)] && [llength $quartus(args)] > 0 } {
    set npaths [lindex $quartus(args) 0]
}

# Same clock string as tools/fmax_check.sh CLK_DEC (outclk_3 = clk_dec).
set clk_dec {emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
set out output_files/clk_dec_paths.txt
# TIMING_CLK=N (optional, 2026-09-29): another sys_pll output instead -- 0 clk_sys, 1 clk_mem
# -- its paths FROM ANY CLOCK into it (a crossing's capture shows up too), to
# output_files/clk_gN_paths.txt. (The variable keeps its name: everything below reads it.)
set from_any 0
if { [info exists ::env(TIMING_CLK)] && $::env(TIMING_CLK) ne "" && $::env(TIMING_CLK) ne "3" } {
    set clk_dec "emu|sys_pll|altera_pll_i|general\[$::env(TIMING_CLK)\].gpll~PLL_OUTPUT_COUNTER|divclk"
    set out output_files/clk_g$::env(TIMING_CLK)_paths.txt
    set from_any 1
    # (hd_raster) TIMING_CLK=vid: clk_vid, vid_pll's one output (the raster side, 81 MHz)
    if { $::env(TIMING_CLK) eq "vid" } {
        set clk_dec "emu|vid_pll|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
        set out output_files/clk_vid_paths.txt
    }
}

project_open $rev -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist
if { $from_any } { set clkopt [list -to_clock [get_clocks $clk_dec]] } else {
    set clkopt [list -from_clock [get_clocks $clk_dec] -to_clock [get_clocks $clk_dec]] }

# Pin the analysis to a slow corner: TIMING_TEMP (default 100). The COLD corner (-40)
# usually binds on this device: TIMING_TEMP=-40 tools/timing_paths.sh, or the report
# retimes the wrong path. (CLAUDE.md documented the knob before it existed: the tcl
# hardcoded 100 until 2026-09-27; docker_reexec.sh forwards it.)
set temp 100
if { [info exists ::env(TIMING_TEMP)] && $::env(TIMING_TEMP) ne "" } { set temp $::env(TIMING_TEMP) }
if { [catch { set_operating_conditions -model slow -temperature $temp -voltage 1100 } msg] } {
    post_message -type warning "timing_paths: could not pin slow/${temp}C corner ($msg); using default"
} else {
    post_message -type info "timing_paths: slow 1100mV ${temp}C corner"
    update_timing_netlist
}

# TIMING_BELOW=S (optional): one path per ENDPOINT (the worst) with slack below S ns,
# instead of the top N paths -- a few clusters fill the top N; this counts what a clock
# target actually needs retimed (slack below period - 1000 / gate_MHz: 10.370 - 9.862 =
# 0.508 for the 101.4 gate at the 96.43 MHz constraint; 9.630 - 9.191 = 0.439 for 108.8
# at 103.85)
if { [info exists ::env(TIMING_BELOW)] && $::env(TIMING_BELOW) ne "" } {
    report_timing -setup \
        {*}$clkopt \
        -npaths $npaths -nworst 1 -less_than_slack $::env(TIMING_BELOW) -detail summary -file $out
} else {
report_timing -setup \
    {*}$clkopt \
    -npaths $npaths -detail summary -file $out
}

report_timing -setup \
    {*}$clkopt \
    -npaths 3 -detail full_path -append -file $out

# TIMING_PAIRS="from1 to1 from2 to2 ..." (optional): the worst path between each pair of
# register globs in full detail, to output_files/clk_dec_detail.txt -- the census names
# the endpoints, this shows the cells between them (tools/timing_chain.py condenses it).
# Globs match register names, e.g. "*u_dpb|cur_poc[13]" "*u_dpb|waiting[5]".
if { [info exists ::env(TIMING_PAIRS)] && $::env(TIMING_PAIRS) ne "" } {
    set dout output_files/clk_dec_detail.txt
    file delete -force $dout
    foreach {f t} $::env(TIMING_PAIRS) {
        report_timing -setup -from [get_registers $f] -to [get_registers $t] \
            -npaths 1 -detail full_path -append -file $dout
    }
    post_message -type info "timing_paths: wrote the TIMING_PAIRS paths to $dout"
}

post_message -type info "timing_paths: wrote top $npaths intra-clk_dec setup paths to $out"
project_close
