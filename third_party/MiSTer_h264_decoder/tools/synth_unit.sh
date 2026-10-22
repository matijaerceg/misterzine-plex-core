#!/usr/bin/env bash
# synth_unit.sh -- Quartus Analysis & Synthesis only, on ONE module as the top, for
# area work: minutes instead of a full fit. Prints the per-entity table (LUTs,
# registers, block memory bits) and every RAM that was or was not inferred.
#
#   USE_DOCKER=1 tools/synth_unit.sh recon_top            # default file list: H264.qsf's
#   USE_DOCKER=1 tools/synth_unit.sh mv_pred h264/dec/h264_pkg.sv h264/dec/mv_pred.sv
#
# The project lives in .sim/synth_<top>/ (gitignored scratch); the device is the core's.
# Top-level ports become pins, so a wide unit reports a pin-count error AFTER synthesis:
# ignored here -- the numbers are what matter (virtual pins would change nothing
# inside the entity). Not a gate: the full build (build_release.sh) is.
set -u
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"
cd "$(dirname "$0")/.."
ROOT=$(pwd)
top=${1:?usage: synth_unit.sh TOP [files...]}; shift
D=.sim/synth_$top
rm -rf "$D"; mkdir -p "$D"
{
  echo "set_global_assignment -name FAMILY \"Cyclone V\""
  echo "set_global_assignment -name DEVICE 5CSEBA6U23I7"
  echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
  echo "set_global_assignment -name SEARCH_PATH $ROOT"
  echo "set_global_assignment -name VERILOG_MACRO \"QUARTUS=1\""
  if [ $# -gt 0 ]; then
    for f in "$@"; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $ROOT/$f"; done
  else
    grep -E "^set_global_assignment -name (SYSTEMVERILOG|VERILOG)_FILE h264/" H264.qsf | grep -v "emu.sv\|sys_pll" \
      | sed "s# h264/# $ROOT/h264/#"
  fi
} > "$D/$top.qsf"
echo "PROJECT_REVISION = \"$top\"" > "$D/$top.qpf"
( cd "$D" && quartus_map "$top" > map.log 2>&1 ); rc=$?
R="$D/output_files/$top.map.rpt"; [ -f "$R" ] || R="$D/$top.map.rpt"
if [ ! -f "$R" ]; then echo "synth_unit: no map report (exit $rc)"; grep -m5 "Error" "$D/map.log"; exit 1; fi
grep -m3 "Error" "$D/map.log"
awk '/Analysis & Synthesis Resource Utilization by Entity/{f=1} f&&/^; +\|/{print} f&&/^$/{if(n++>1)exit}' "$R" \
  | awk -F';' '{gsub(/ +$/,"",$2); printf "%-24s %-22s %-10s %s\n", $3, $4, $5, $2}' | sed 's/  \+/ /g' | head -60
echo "-- RAMs:"
grep -oE "Inferred altsyncram megafunction from the following design logic: \"[^\"]*\"|RAM logic \"[^\"]*\" is uninferred[^F]*" "$D/map.log" | sed 's/Inferred altsyncram megafunction from the following design logic:/  inferred/' | head -60
