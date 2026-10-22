#!/usr/bin/env bash
# Focused same-cycle equivalence gate for recon_dpb's C.4.4 dropped-store count.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v iverilog >/dev/null && command -v vvp >/dev/null || { echo "FAIL: install Icarus Verilog"; exit 1; }
python3 bench/h264/check_dpb_drop_exhaustive.py
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
RTL="h264/dec/h264_pkg.sv h264/dec/recon_dpb.sv bench/h264/recon_dpb_drop_tb.sv"

iverilog -g2012 -I . -s recon_dpb_drop_tb -o "$tmp/drop" $RTL
vvp -n "$tmp/drop"

if [[ "${1:-}" == "--red" ]]; then
  python3 - "$tmp/recon_dpb_o13.sv" <<'PY'
from pathlib import Path
import sys
src = Path("h264/dec/recon_dpb.sv").read_text()
old = "if (drop_go) out_dropped <= out_dropped + {26'd0, drop_n};"
new = "if (drop_go) out_dropped <= out_dropped;"
if src.count(old) != 1:
    raise SystemExit("FAIL: O13 mutation anchor changed")
Path(sys.argv[1]).write_text(src.replace(old, new))
PY
  if iverilog -g2012 -I . -s recon_dpb_drop_tb -o "$tmp/drop_o13" h264/dec/h264_pkg.sv "$tmp/recon_dpb_o13.sv" bench/h264/recon_dpb_drop_tb.sv 2>"$tmp/o13-build.log"; then
    if vvp -n "$tmp/drop_o13" >"$tmp/o13.log" 2>&1; then
      echo "FAIL: O13 dropped-status accumulator mutation survived"
      exit 1
    fi
    grep -q "out_dropped got=.*want=" "$tmp/o13.log" || { cat "$tmp/o13.log"; echo "FAIL: O13 failed for an unexpected reason"; exit 1; }
    echo "PASS: O13 dropped-status accumulator mutation caught"
  else
    cat "$tmp/o13-build.log"
    echo "FAIL: O13 mutation did not compile"
    exit 1
  fi

  python3 - "$tmp/recon_dpb_mut.sv" <<'PY'
from pathlib import Path
import sys
src = Path("h264/dec/recon_dpb.sv").read_text()
old = "if (waiting[i] && i[4:0] != cur_store)"
new = "if (waiting[i] && 1'b1)"
if src.count(old) != 1:
    raise SystemExit("FAIL: O14 mutation anchor changed")
Path(sys.argv[1]).write_text(src.replace(old, new))
PY
  if iverilog -g2012 -I . -s recon_dpb_drop_tb -o "$tmp/drop_mut" h264/dec/h264_pkg.sv "$tmp/recon_dpb_mut.sv" bench/h264/recon_dpb_drop_tb.sv 2>"$tmp/mut-build.log"; then
    if vvp -n "$tmp/drop_mut" >"$tmp/mut.log" 2>&1; then
      echo "FAIL: O14 current-store exclusion mutation survived"
      exit 1
    fi
    grep -q "drop tree mask=.*current=.*got=.*want=" "$tmp/mut.log" || { cat "$tmp/mut.log"; echo "FAIL: O14 failed for an unexpected reason"; exit 1; }
    echo "PASS: O14 current-store exclusion mutation caught"
  else
    cat "$tmp/mut-build.log"
    echo "FAIL: O14 mutation did not compile"
    exit 1
  fi
fi
