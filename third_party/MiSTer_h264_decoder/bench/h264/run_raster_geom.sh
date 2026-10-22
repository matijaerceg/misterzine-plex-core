#!/usr/bin/env bash
# run_raster_geom.sh -- h264/raster_geom.sv (the native raster's geometry, docs/hdmi_raster.md §3b /
# §4, stage 2) against tools/raster_geom_ref.py, the design's arithmetic written from the text
# (bench/h264/raster_geom_tb.sv).
#
# (hd_raster stage B: the native raster in 81 MHz dots, 3F a frame, up to 2,048 x 2,048 -- hd_raster.md §4)
# GREEN: the model's selftest (§4's tables; 6,000 random pictures: every native frame exactly F
#   dots, L - Rw >= 20, the active lines ending by Ae); the RTL vs the model on 2,000 vectors (500
#   pictures x 59.94 / 60.00 / 50 Hz with Native asked, and 59.94 not asked; every branch reached:
#   display-shaped, picture-sized, fell back, a short last line, the 4,000-dot cap, 50 Hz).
# Arms: [mode] mode / disp, [size] rw / rh, [frame] l / nt / last and the frame's own arithmetic,
#   [seq] the computation's end, the outputs still while it runs, the hold with en low.
# Mutations (--red), each caught by its own arm:
#   G1  round(n/d) read as floor in the letterbox height             -> [size]
#   G2  the pillarbox width divided by sar_h dw (D1, not D2)          -> [size] (or [mode]: the wrong width changes the fit)
#   G3  the 4,000-dot line cap lost                                   -> [frame]
#   G4  the blank's 20 dots read as 10                                -> [mode]
#   G5  no picture-sized retry after the display-shaped raster        -> [mode]
#   G6  a short last line always (the 32-dot threshold at 0)          -> [frame]
#   G7  59.94's Ae read as 50 Hz's                                    -> [frame]
#   G8  `en` ignored (the hold between streams lost)                  -> [seq]
#   G9  the coded-width bound (128 macroblocks: hd_raster) lost       -> [mode]
#   G10 the raster's width bound (2,048: hd_raster) lost              -> [mode]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL=h264/raster_geom.sv; TB=bench/h264/raster_geom_tb.sv; VEC=.sim/raster_geom_vec.txt
echo "== the model =="
python3 tools/raster_geom_ref.py --selftest | sed 's/^/  /' || { echo "FAIL: model selftest"; exit 1; }
python3 tools/raster_geom_ref.py --vectors 500 $VEC | sed 's/^/  /'
echo "== GREEN =="
rm -f .sim/raster_geom_sim   # iverilog leaves the old binary on a failed build
if iverilog -g2012 -o .sim/raster_geom_sim $RTL $TB && vvp -n .sim/raster_geom_sim +vec=$VEC > .sim/raster_geom.log 2>&1 \
   && grep -q "^PASS: raster_geom_tb" .sim/raster_geom.log; then
  echo "  PASS $(grep '^raster_geom_tb:' .sim/raster_geom.log)"
else echo "  FAIL"; grep FAIL .sim/raster_geom.log | head -3; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  ROOT=$PWD
  mut() {   # name old new arm
    local d; d=$(mktemp -d)
    mkdir -p "$d/h264"; cp $RTL "$d/h264/"
    python3 - "$d/$RTL" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o "$d/sim" "$d/$RTL" "$ROOT/$TB" 2>"$d/build.log"); then
      echo "  $1: harness failure (anchor or build)"; fail=1
    else
      timeout 600 vvp -n "$d/sim" +vec="$ROOT/$VEC" > "$d/log" 2>&1
      if grep -q "^PASS:" "$d/log"; then echo "  $1: SURVIVED -- the bench cannot see this defect"; fail=1
      elif grep -Eq "FAIL \[($4)\]" "$d/log"; then echo "  $1: caught by $(grep -Em1 "FAIL \[($4)\]" "$d/log" | cut -c1-110)"
      else echo "  $1: failed but NOT in [$4]:"; grep -m2 FAIL "$d/log"; fail=1; fi
    fi
    rm -rf "$d"
  }
  mut G1 "dv_n <= {7'd0, a_acc, 1'b0} + {20'd0, r_d1};" "dv_n <= {7'd0, a_acc, 1'b0};" size
  mut G2 "dv_n <= {7'd0, b_acc, 1'b0} + {20'd0, r_d2}; dv_d <= {3'd0, r_d2, 1'b0};" "dv_n <= {7'd0, b_acc, 1'b0} + {20'd0, r_d2}; dv_d <= {3'd0, r_d1, 1'b0};" "size|mode"
  mut G3 "if (((dv_q > 48'd4000) ? 13'd4000 : {1'b0, dv_q[11:0]}) >= {1'b0, c_rw} + 13'd20) begin
                        c_l <= (dv_q > 48'd4000) ? 12'd4000 : dv_q[11:0];" "if (((dv_q > 48'd4000) ? 13'd4000 : {1'b0, dv_q[11:0]}) >= {1'b0, c_rw} + 13'd20) begin
                        c_l <= (dv_q > 48'd4095) ? 12'd4095 : dv_q[11:0];" frame
  mut G4 ">= {1'b0, c_rw} + 13'd20) begin" ">= {1'b0, c_rw} + 13'd10) begin" mode
  mut G5 "                    end else if (c_disp) begin
                        c_rw <= q_wc; c_rh <= q_hc; c_disp <= 1'b0; st <= S_FIT;" "                    end else if (1'b0) begin
                        c_rw <= q_wc; c_rh <= q_hc; c_disp <= 1'b0; st <= S_FIT;" mode
  mut G6 "if (dv_rem[11:0] >= 12'd32) begin" "if (1'b1) begin" frame
  mut G7 "wire [20:0] k_ae = (stdn == 2'd2) ? 21'd1529280 : 21'd1261260;" "wire [20:0] k_ae = 21'd1529280;" frame
  mut G8 "S_IDLE: if (en && (!have || in_set != last_set)) begin" "S_IDLE: if ((!have || in_set != last_set)) begin" seq
  mut G9 "q_w > 8'd128" "q_w > 8'd255" mode
  mut G10 "c_rw == 12'd0 || c_rw > 12'd2048 ||" "c_rw == 12'd0 ||" mode
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
