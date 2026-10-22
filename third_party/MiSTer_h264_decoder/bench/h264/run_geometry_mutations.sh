#!/usr/bin/env bash
# Prove the geometry-specific benches reject three representative regressions.
set -eu
cd "$(dirname "$0")/../.."
command -v verilator >/dev/null || { echo "verilator is required" >&2; exit 1; }
mkdir -p .sim/geometry_mutations
M=.sim/geometry_mutations
rm -rf "$M" && mkdir -p "$M/src/h264"
cp h264/disp_fit.sv "$M/src/h264/disp_fit.sv"
cp h264/disp_reader.sv "$M/src/h264/disp_reader.sv"
cp h264/ring_rd.sv "$M/src/h264/ring_rd.sv"

python3 - "$M/src/h264" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
def change(name, old, new):
    f = p / name
    text = f.read_text()
    if old not in text:
        raise SystemExit(f"mutation anchor missing in {f}: {old!r}")
    f.write_text(text.replace(old, new, 1))

change("disp_fit.sv", "k_geom <= geometry_en && !nat;", "k_geom <= 1'b0;")
change("disp_reader.sv", "wire         in_clip_x = !r_clip_enable || (x >= r_clip_x && x < r_clip_x + r_clip_w);",
       "wire         in_clip_x = 1'b1;")
change("disp_reader.sv", "wire         in_clip_y = !r_clip_enable || (v_pos >= r_clip_y && v_pos < r_clip_y + r_clip_h);",
       "wire         in_clip_y = 1'b1;")
change("ring_rd.sv", "end else if (p_geom[25:13] == 13'd0 || p_geom[12:0] == 13'd0 ||\n                                 p_geom[39] || p_geom[26] || p_geom[13] || p_geom[0] ||\n                                 b_readdata[11:0] > 12'd720 || b_readdata[23:12] > 12'd576 ||\n                                 b_readdata[35:24] == 12'd0 || b_readdata[35:24] > 12'd720 ||\n                                 b_readdata[47:36] == 12'd0 || b_readdata[47:36] > 12'd576 ||\n                                 {1'b0, b_readdata[11:0]} + {1'b0, b_readdata[35:24]} > 13'd720 ||\n                                 {1'b0, b_readdata[23:12]} + {1'b0, b_readdata[47:36]} > 13'd576 ||\n                                 b_readdata[0] || b_readdata[12] || b_readdata[24] || b_readdata[36]) begin",
       "end else if (1'b0) begin // injected: accept malformed rectangles")
PY

python3 tools/disp_fit_ref.py --vectors 400 .sim/disp_fit_geom_vec.txt >/dev/null
expect_caught() {
  local name=$1 expected=$2; shift 2
  local log="$M/$name.log"
  if ! "$@" >"$log" 2>&1; then
    if grep -q "$expected" "$log"; then
      echo "PASS mutation caught: $name ($(grep -m1 "$expected" "$log"))"
      return
    fi
    cat "$log" >&2
    echo "ERROR: $name failed outside its expected test arm" >&2
    exit 1
  fi
  cat "$log" >&2
  echo "ERROR: mutation escaped: $name" >&2
  exit 1
}

verilator --binary --timing -Wno-fatal -j 2 --top-module disp_fit_tb \
  "$M/src/h264/disp_fit.sv" bench/h264/disp_fit_tb.sv --Mdir "$M/obj_fit" >"$M/build_fit.log" 2>&1
expect_caught ignore_geometry '^FAIL \[geometry-publish\]' "$M/obj_fit/Vdisp_fit_tb" +vec=.sim/disp_fit_geom_vec.txt

verilator --binary --timing -Wno-fatal -j 2 --top-module disp_reader_tb \
  h264/sync_gen.sv h264/disp_fit.sv "$M/src/h264/disp_reader.sv" \
  bench/h264/ddr_model.sv bench/h264/disp_reader_tb.sv --Mdir "$M/obj_reader" >"$M/build_reader.log" 2>&1
expect_caught ignore_clip '^FAIL \[geometry-clip\]' "$M/obj_reader/Vdisp_reader_tb" +arm=geometry

verilator --binary --timing -Wno-fatal -j 2 --top-module ring_geom_tb \
  h264/cdc.sv h264/fifo_dc.sv "$M/src/h264/ring_rd.sv" \
  h264/ring_words_sys.sv h264/ring_words_mem.sv h264/ring_words_dec.sv \
  h264/ring_in.sv h264/ring_words_in.sv h264/pic_in.sv h264/recon_out.sv \
  bench/h264/ddr_model.sv bench/h264/ring_geom_tb.sv --Mdir "$M/obj_ring" >"$M/build_ring.log" 2>&1
expect_caught accept_malformed 'invalid transaction was not refused atomically' "$M/obj_ring/Vring_geom_tb"
echo "PASS: all geometry mutations were caught"
