#!/usr/bin/env bash
# tools/hdmi_pll_check.sh [FIT_RPT] -- the HDMI clock's PLL output counter is the one Main reprograms.
#
# Main sets every HDMI mode's pixel clock by rewriting pll_hdmi's PHYSICAL C counter 0 through
# pll_cfg (Main_MiSTer video.cpp setPLL: register 5, counter select 0) and its M / K (the VCO). A fit
# that puts pll_hdmi's outclk_0 on a different physical counter still closes timing and still shows
# 1080p (the compiled 148.5 MHz), but every other mode keeps the compiled /3 under the new VCO:
# 720x480 left at 135 MHz (black on the TV), 1280x720 at 148.5 MHz (720p at 120 Hz). Found 2026-10-11
# (docs/history.md S47): the SEED 2 fits of three branches sat on PLLOUTPUTCOUNTER_X0_Y7_N1; every working
# fit (and MiSTer_DVD's) on X0_Y5_N1, the location sys/sys.tcl now pins.
#
# Reads the fit report's PLL Usage Summary: pll_hdmi's PLL Location and its Output Clock Location,
# and the Ignored Assignments table for the two location pins (a pin the fitter could not honour; the
# stock UNFORCE_MERGE_PLL_OUTPUT_COUNTER line is ignored in every fit, ours and MiSTer_DVD's alike). Exit 0 = as pinned.
# Advisory on a dev build, fatal on --release (build_release.sh).
set -u
RPT=${1:-output_files/H264.fit.rpt}
WANT_PLL=FRACTIONALPLL_X0_Y1_N0
WANT_CNT=PLLOUTPUTCOUNTER_X0_Y5_N1

[ -f "$RPT" ] || { echo "hdmi_pll_check: FAIL: no fit report $RPT"; exit 2; }

# pll_hdmi's block in the PLL Usage Summary: from its name line to the next PLL's
read -r pll cnt < <(awk '
    /^; pll_hdmi:pll_hdmi\|.*\|fpll[ ;]/ { inb = 1; next }
    inb && /^; [a-zA-Z_]+:[a-zA-Z_]+\|.*(FRACTIONAL_PLL|\|fpll)[ ;]/ { exit }
    inb && /-- PLL Location/          { split($0, f, ";"); gsub(/ /, "", f[3]); pll = f[3] }
    inb && /-- Output Clock Location/ { split($0, f, ";"); gsub(/ /, "", f[3]); if (cnt == "") cnt = f[3] }
    END { print (pll == "" ? "-" : pll), (cnt == "" ? "-" : cnt) }
' "$RPT")

ignored=$(awk '/^; Ignored Assignments/ { inb = 1 } inb && /pll_hdmi/ && /FRACTIONALPLL_|PLLOUTPUTCOUNTER_|Location/ { print } inb && /^$/ { exit }' "$RPT")

rc=0
if [ "$pll" = "-" ] || [ "$cnt" = "-" ]; then
    echo "hdmi_pll_check: FAIL: pll_hdmi not found in $RPT's PLL Usage Summary"
    exit 2
fi
if [ "$pll" != "$WANT_PLL" ]; then
    echo "hdmi_pll_check: FAIL: pll_hdmi at $pll (want $WANT_PLL)"; rc=1
fi
if [ "$cnt" != "$WANT_CNT" ]; then
    echo "hdmi_pll_check: FAIL: pll_hdmi's output on $cnt (want $WANT_CNT, the counter Main reprograms):"
    echo "  every HDMI mode but 1080p will run at the wrong pixel clock (720x480 at 135 MHz: black)"; rc=1
fi
if [ -n "$ignored" ]; then
    echo "hdmi_pll_check: FAIL: the fitter ignored a pll_hdmi assignment:"; echo "$ignored"; rc=1
fi
[ "$rc" -eq 0 ] && echo "hdmi_pll_check: PASS: pll_hdmi at $pll, output on $cnt"
exit "$rc"
