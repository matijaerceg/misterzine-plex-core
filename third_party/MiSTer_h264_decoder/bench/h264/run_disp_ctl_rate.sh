#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sim=.sim/disp_ctl_rate_sim
mkdir -p .sim
rm -f "$sim"
iverilog -g2012 -s disp_ctl_rate_tb -o "$sim" h264/disp_sched.sv h264/disp_ctl.sv bench/h264/disp_ctl_rate_tb.sv
vvp "$sim"
