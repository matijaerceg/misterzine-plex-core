#!/usr/bin/env bash
# fmax_check.sh — verify the clk_dec (decoder compute, 96.43 MHz) domain Fmax from a Quartus
# STA report. Inherited from MiSTer_DVD, where a clk_dec fit under the gate presented on
# hardware as a chroma fringe that came and went with the fitter seed.
#
# The domain must close at BOTH slow corners or the build is marginal. This script is the
# ONLY sanctioned way to read that number out of H264.sta.rpt.
#
#   PARSING RULE (learned the hard way, 2026-07-09): the Fmax Summary tables are sorted
#   by Fmax VALUE, so a clock's neighbors shift with every fit. Any `grep -A/-B` or
#   `tail`-based extraction reads a DIFFERENT clock's row sooner or later — the July 9
#   seed sweep did exactly that and logged junk (reported 99.89 MHz for a fit whose true
#   clk_dec was 81.13/77.38). Parse ROW-ANCHORED only: find the row that itself contains
#   the clk_dec divclk name, take its Restricted Fmax column.
#
# Usage:  tools/fmax_check.sh [path/to/H264.sta.rpt]     (default output_files/H264.sta.rpt)
#   FMAX_MIN=101.4  threshold in MHz (both slow corners must meet it)
#   FMAX_VID_MIN=86.0  clk_vid's (hd_raster, docs/hd_raster.md S2: the raster on 81 MHz, the same
#                   5 MHz rule) -- the second gated domain, also at both slow corners
# Exit codes: 0 = PASS, 1 = FAIL (below threshold), 2 = parse error / missing report.
#
# THRESHOLD: 101.4 MHz = the 96.43 MHz clock (sys_pll outclk_3, since H264 P5b, and again since
# the macroblock pipeline; 103.85 with a 108.8 gate on main 2026-09-30; 81 with an 86.0 gate
# before P5b) plus the
# 5 MHz margin MiSTer_DVD measured it needs (its healthy 81 MHz fits closed 86.9-96 MHz; the ones that misbehaved on hardware sat at
# 81-83). It is a netlist-health canary, not a cliff: a fit under it means the netlist has
# degraded -- measure with tools/timing_paths.sh (TIMING_TEMP=-40 for the cold corner,
# which usually binds) and fix the top cluster rather than only re-rolling seeds.

set -u

RPT="${1:-output_files/H264.sta.rpt}"
FMAX_MIN="${FMAX_MIN:-101.4}"
CLK_DEC='emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk'   # outclk_3 = clk_dec
CLK_MEM='emu|sys_pll|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk'   # outclk_1 = clk_mem (info only)
CLK_VID='emu|vid_pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk'   # vid_pll outclk_0 = clk_vid (gated)
FMAX_VID_MIN="${FMAX_VID_MIN:-86.0}"

if [[ ! -f "$RPT" ]]; then
    echo "fmax_check: ERROR: STA report not found: $RPT" >&2
    exit 2
fi

# Mismatched-pair trap: after a seed sweep the on-disk .sof and .sta.rpt can come from
# DIFFERENT fits (the July 9 sweep packed a seed-7 .sof while the rpt was seed 12's;
# the Aug 1 exhausted margin sweep left a seed-17 rpt NEWER than the shipped seed-11
# .sof — so the check is bidirectional: a healthy compile flow produces the pair
# within minutes of each other, any large gap in EITHER direction means they are
# from different fits).
SOF="$(dirname "$RPT")/H264.sof"
if [[ -f "$SOF" ]]; then
    rpt_t=$(stat -c %Y "$RPT" 2>/dev/null || echo 0)
    sof_t=$(stat -c %Y "$SOF" 2>/dev/null || echo 0)
    gap=$(( rpt_t - sof_t )); [[ $gap -lt 0 ]] && gap=$(( -gap ))
    if [[ $gap -gt 1800 ]]; then
        echo "fmax_check: WARNING: $RPT and $SOF timestamps differ by ${gap}s — the report may describe a different fit than the packed bitstream." >&2
    fi
fi

# Row-anchored extraction: walk the report, track which Fmax Summary table we are in
# (table title rows look like '; Slow 1100mV 100C Model Fmax Summary ;'), and when a row
# inside a slow-corner table contains the target clock name, take column 2 = Restricted
# Fmax. Emits "corner value" pairs. Plain substring match (index) — the clock name is
# full of regex metacharacters ([3], |, .) that would otherwise match other divclk rows.
extract() { # $1 = exact clock-name substring
    awk -v pat="$1" '
        /^; Slow 1100mV 100C Model Fmax Summary/ { corner = "100C"; next }
        /^; Slow 1100mV -40C Model Fmax Summary/ { corner = "-40C"; next }
        /^; (Fast|Multicorner|Setup|Hold)/       { corner = "" }
        corner != "" && index($0, pat) > 0 && / MHz / {
            n = split($0, f, ";")
            gsub(/^ +| +$/, "", f[3])       # f[2]=Fmax, f[3]=Restricted Fmax
            sub(/ MHz$/, "", f[3])
            print corner, f[3]
        }' "$RPT"
}

declare -A dec mem vid
while read -r corner val; do dec[$corner]="$val"; done < <(extract "$CLK_DEC")
while read -r corner val; do mem[$corner]="$val"; done < <(extract "$CLK_MEM")
while read -r corner val; do vid[$corner]="$val"; done < <(extract "$CLK_VID")

if [[ -z "${dec[100C]:-}" || -z "${dec[-40C]:-}" ]]; then
    echo "fmax_check: ERROR: clk_dec row not found in both slow-corner Fmax tables of $RPT" >&2
    exit 2
fi

if [[ -z "${vid[100C]:-}" || -z "${vid[-40C]:-}" ]]; then
    echo "fmax_check: ERROR: clk_vid row (emu|vid_pll) not found in both slow-corner Fmax tables of $RPT" >&2
    exit 2
fi

echo "clk_dec Restricted Fmax: ${dec[100C]} MHz @100C, ${dec[-40C]} MHz @-40C (target ${FMAX_MIN})"
echo "clk_vid Restricted Fmax: ${vid[100C]} MHz @100C, ${vid[-40C]} MHz @-40C (target ${FMAX_VID_MIN})"
[[ -n "${mem[100C]:-}" ]] && \
    echo "clk_mem (info, no gate):  ${mem[100C]} MHz @100C, ${mem[-40C]:-?} MHz @-40C (infra domain, never closes; validated empirically)"

# Advisory (no gate): any core-PLL clock with negative setup slack at a slow corner. The
# crossings into clk_sys are bounded in the core SDC (h264/*.sdc, once one exists); one that is not shows up here as
# the 90 / 27 MHz 3.7 ns edge window -- P5e's three clk_mem -> clk_sys cdc_snaps sat at
# -0.28 ns for three fits because this script read clk_dec alone (found 2026-09-27).
SUMMARY="${RPT%.rpt}.summary"
if [[ -f "$SUMMARY" ]]; then
    awk '/^Type  : Slow 1100mV .* Model Setup .emu\|(sys|vid)_pll/ { t = $0; next }
         t != "" && /^Slack : / { if ($3 + 0 < 0) print "fmax_check: WARNING: negative setup slack " $3 " ns: " substr(t, 9); t = "" }' \
        "$SUMMARY" >&2
fi

ok=0
if awk -v a="${dec[100C]}" -v b="${dec[-40C]}" -v m="$FMAX_MIN" 'BEGIN{ exit !(a >= m && b >= m) }'; then
    echo "fmax_check: PASS — clk_dec closes ${FMAX_MIN} MHz at both slow corners"
else
    echo "fmax_check: FAIL — clk_dec below ${FMAX_MIN} MHz (marginal build; re-sweep seeds or retime)"; ok=1
fi
if awk -v a="${vid[100C]}" -v b="${vid[-40C]}" -v m="$FMAX_VID_MIN" 'BEGIN{ exit !(a >= m && b >= m) }'; then
    echo "fmax_check: PASS — clk_vid closes ${FMAX_VID_MIN} MHz at both slow corners"
else
    echo "fmax_check: FAIL — clk_vid below ${FMAX_VID_MIN} MHz (the raster side: retime it, docs/hd_raster.md S3)"; ok=1
fi
exit $ok
