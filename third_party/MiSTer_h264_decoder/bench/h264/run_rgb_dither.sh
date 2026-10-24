#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .sim
iverilog -g2012 -Ih264 -s rgb_dither_tb -o .sim/rgb_dither h264/disp_reader.sv bench/h264/rgb_dither_tb.sv
vvp .sim/rgb_dither
