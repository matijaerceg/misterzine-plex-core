#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .sim
rm -f .sim/display_policy_tb
iverilog -g2012 -s display_policy_tb -o .sim/display_policy_tb \
    h264/display_policy.sv bench/h264/display_policy_tb.sv
vvp .sim/display_policy_tb | tee .sim/display_policy_tb.log
grep -Fq 'PASS: display_policy_tb' .sim/display_policy_tb.log
