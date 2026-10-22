#!/usr/bin/env bash
# lint_undriven.sh -- fail on any signal that is DECLARED, CONSUMED and NEVER DRIVEN.
#
# WHY (2026-09-07). Two defects of exactly this shape shipped in one feature and
# survived two hardware rounds:
#
#   (MiSTer_DVD) emu.sv  dec_pts_in / dec_pts_in_valid were wired into mpeg2video
#                       and the CDC that drives them was never instantiated, so the
#                       decoder never received a video PTS at all.
#   resample_addrgen.v  frame_late was left `output reg` with its always block
#                       deleted by the Stage-1 governor surgery, so the entire
#                       lateness -> frame_drop_ctl ledger was dead.
#
# Neither is an implicit net -- both wires were properly declared -- so
# `default_nettype none` and the Quartus 10236 gate stay silent: those catch a
# missing DECLARATION, these were missing DRIVERS. Neither is visible in
# simulation either, because the module benches drive the input directly and there
# is no emu-level bench. Quartus ties the net low and everything downstream keeps
# compiling, fitting and running.
#
# ★ The file list comes from H264.qsf, not from a glob: what is linted is exactly what
# is built. The flip side (memory: qsf-file-list-gates-everything): a new h264/*.sv that
# is not yet named in H264.qsf is invisible here too.
#
# Validated against the real defect: run over the commit before the pts_cdc fix it
# reports dec_pts_in and dec_pts_in_valid by name.
set -u
cd "$(dirname "$0")/.."

# Stock MiSTer framework, inside the `if(PS2DIV)` block that this core disables.
# Present since the upstream import; not ours, and not reachable.
ALLOW='kbd_data_host|mouse_data_host'

# emu.sv `includes build_id.v, which sys/build_id.tcl generates inside a Quartus
# compile. Lint may run before any compile has happened, so provide a stand-in.
INCDIR=$(mktemp -d)
trap 'rm -rf "$INCDIR"' EXIT
[ -f build_id.v ] && cp build_id.v "$INCDIR/" || echo '`define BUILD_DATE "000000"' > "$INCDIR/build_id.v"

FILES=$(sed -n 's/^[[:space:]]*set_global_assignment[[:space:]]\+-name[[:space:]]\+\(VERILOG_FILE\|SYSTEMVERILOG_FILE\)[[:space:]]\+//p' H264.qsf \
        | grep -vE '\.vhd$')
[ -n "$FILES" ] || { echo "lint_undriven: no source files found in H264.qsf"; exit 2; }

OUT=$(verilator --lint-only -Wno-fatal --top-module emu -Wwarn-UNDRIVEN \
        +incdir+h264 +incdir+sys +incdir+"$INCDIR" \
        $FILES 2>&1 | grep "Signal is not driven" | grep -vE "'($ALLOW)'")

if [ -n "$OUT" ]; then
  echo "lint_undriven: FAIL -- a declared, consumed signal has no driver."
  echo "  Quartus ties it low; every bench that drives it directly still passes."
  echo "$OUT" | sed 's/^/  /'
  exit 1
fi
echo "lint_undriven: PASS (no undriven signals outside the stock hps_io allowlist)"
