#!/usr/bin/env bash
# Run only the Ring Interface 1.2 geometry request/ACK transaction bench.
# This stays independent of run_ring_rd.sh's legacy ring_rd_tb Icarus build.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p .sim
rm -f .sim/ring_geom_sim .sim/ring_geom.log .sim/ring_geom_build.log

RTL=(
  h264/cdc.sv h264/fifo_dc.sv h264/ring_rd.sv
  h264/ring_words_sys.sv h264/ring_words_mem.sv h264/ring_words_dec.sv
  h264/ring_in.sv h264/ring_words_in.sv h264/pic_in.sv h264/recon_out.sv
  bench/h264/ddr_model.sv bench/h264/ring_geom_tb.sv
)

if ! iverilog -g2012 -s ring_geom_tb -o .sim/ring_geom_sim "${RTL[@]}" 2>.sim/ring_geom_build.log; then
  cat .sim/ring_geom_build.log >&2
  exit 1
fi
if ! vvp -n .sim/ring_geom_sim >.sim/ring_geom.log 2>&1; then
  cat .sim/ring_geom.log >&2
  exit 1
fi
cat .sim/ring_geom.log
grep -q '^PASS: ring_geom_tb' .sim/ring_geom.log
