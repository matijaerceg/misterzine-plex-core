#!/usr/bin/env bash
# timing_paths.sh — wrapper for tools/timing_paths.tcl (top intra-clk_dec setup paths).
#
#   [USE_DOCKER=1] tools/timing_paths.sh [npaths]     (default 100)
#
# Needs a completed fit on disk (db/ + output_files/) — it does NOT refit; it opens the
# existing timing netlist. Output: output_files/clk_dec_paths.txt. See timing_paths.tcl.
#
# Environment (forwarded into Docker): TIMING_TEMP=-40|100 (the corner; check both),
# TIMING_BELOW=S (one path per endpoint under slack S: read with tools/timing_census.py),
# TIMING_CLK=N (another sys_pll output: 1 = clk_mem, 0 = clk_sys; `vid` = clk_vid, vid_pll; paths from any clock into it),
# TIMING_PAIRS="from to ..." (those paths in full detail to output_files/clk_dec_detail.txt:
# read with tools/timing_chain.py). docs/hw_budget_and_lessons.md S5, the P5b playbook.

set -u
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"

cd "$(dirname "$0")/.."
exec quartus_sta -t tools/timing_paths.tcl "${1:-100}"
