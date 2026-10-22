#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .sim
rm -f .sim/display_240_map_tb
iverilog -g2012 -I. -s display_240_map_tb -o .sim/display_240_map_tb \
    h264/disp_reader.sv h264/ovl_plane.sv h264/sfifo.sv bench/h264/display_240_map_tb.sv
vvp -n .sim/display_240_map_tb | tee .sim/display_240_map_tb.log
grep -Fq 'PASS: display_240_map_tb' .sim/display_240_map_tb.log
