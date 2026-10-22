#!/usr/bin/env bash
# run_intra_pred.sh -- the intra prediction gate (h264/dec/intra_pred.sv,
# bench/h264/intra_pred_tb.sv; goldens tools/intra_golden.py <- tools/h264_recon_ref.py)
#
# GREEN: every sample of every case equals the model's (docs/h264_recon.md S2.4):
#   * random neighbours for every kind / mode / legal availability combination, the
#     extreme fills, and -- with ffmpeg's libx264 -- the recorded calls of an all-intra
#     x264 HIGH clip made at run time (the 8x8 transform on: Intra_4x4, Intra_8x8,
#     Intra_16x16 and chroma calls; three slices per picture, so the row above, the column
#     left and the corner go unavailable mid-picture); SKIP of the clip arm without libx264;
#   * H264 Phase 5: kind 3, Intra_8x8 -- the reference filter in place, the nine modes,
#     the corner's availability as a third bit (docs/high_profile.md S5);
#   * the same set with a random-ready consumer (+stall).
#
# --red: mutations on a COPY of intra_pred.sv, each caught by its own case class (the
# cases are in (kind, mode) order, so the class named is the first one that can see it):
#   M1  4x4 mode 3: the (3,3) corner special case removed (T8 read)      -> [pred] k0/m3
#   M2  4x4 mode 5: the zVR == -1 branch taken as the zVR < -1 one        -> [pred] k0/m5
#   M3  4x4 mode 8: the zHU == 5 rule replaced by the zHU > 5 copy        -> [pred] k0/m8
#   M4  4x4 DC, left only: (sum + 2) >> 2 becomes (sum + 1) >> 2          -> [pred] k0/m2
#   M5  16x16 Plane: b = (5H + 32) >> 6 becomes (5H + 16) >> 6            -> [pred] k1/m3
#   M6  chroma Plane: 34 H becomes 5 H                                    -> [pred] k2/m3
#   M7  chroma DC (xO > 0, yO == 0): prefers the column left              -> [pred] k2/m0
#   M8  the corner sample misused in modes 4/6: centre tap p[0,-1]        -> [pred] k0/m4
#   M9  16x16 DC, row above only: (sum + 8) >> 4 becomes (sum + 16) >> 5  -> [pred] k1/m2
#   M10 4x4 mode 6: the zHD parity read from y instead of x               -> [pred] k0/m6
#   M11 4x4 mode 7: the even / odd rows swapped                            -> [pred] k0/m7
#   M12 pred_last one sample early                                         -> [last]
#   M13 the pipeline ignores pred_ready (adv = 1)                          -> [pred] under +stall only
#                                                                            (survives +stall=0: the stall arm is load-bearing)
#   Intra_8x8 (kind 3):
#   M14 the filter's p'[15,-1] reads past the run (8-81's (p14 + 3 p15))  -> [pred] k3/m3
#   M15 p'[0,-1] ignores the corner (8-78 taken as 8-79)                   -> [pred] k3/m0
#   M17 8x8 DC, both runs: (sum + 8) >> 4 taken as the top run's (+ 4) >> 3 -> [pred] k3/m2
#   M18 Vertical_Right below -1: the 4x4 offset y - 1 (right only at x 0)   -> [pred] k3/m5
#   M19 Horizontal_Up's (p'6 + 3 p'7) corner at zHU 5 instead of 13        -> [pred] k3/m8
#   M21 the registered zHD one position ahead off by one (the geometry registers)    -> [pred] k0/m6
#   Equivalent mutants, dropped rather than kept as false arms: the corner filter's "row
#   above only" rule (8-82: every mode that reads p'[-1,-1] -- 4, 5, 6 -- needs the column
#   too); and the filter reading its left tap from the store instead of s_raw (the in-place
#   write is registered, so it lands after the next position has read the store: the store
#   still holds the unfiltered sample -- s_raw is kept so the unit does not rest on that);
#   and (M20, retired at the P5 retime) leaving the filter a cycle before the corner's write
#   lands: with stage I the first tap fetch is a cycle later, so the RTL now does exactly
#   that
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/intra_pred.sv"
TB=bench/h264/intra_pred_tb.sv
STEM="$GEN/intra"
mkdir -p "$GEN"

# shellcheck disable=SC2086
rm -f .sim/ip_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/ip_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/ip_sim ] || { echo "  FAIL intra_pred_tb: build"; exit 1; }

echo "== FIXTURES =="
CLIP=""
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  if ffmpeg -v error -f lavfi -i "testsrc2=size=352x288:rate=24" -frames:v 2 -c:v libx264 -profile:v high -pix_fmt yuv420p \
       -x264-params "cabac=1:8x8dct=1:keyint=1:min-keyint=1:scenecut=0:slices=3:aq-mode=1:crf=22" \
       -bsf:v h264_mp4toannexb -f h264 -y .sim/ip_x264.264; then
    CLIP=".sim/ip_x264.264"
  else echo "  FAIL: x264 clip"; fail=1; fi
else
  echo "  SKIP clip arm: ffmpeg with libx264 not found"
fi
# shellcheck disable=SC2086
if python3 tools/intra_golden.py --out "$STEM" --seeds 24 ${CLIP:+--clip "$CLIP"} > .sim/ip_fx.log 2>&1; then
  sed 's/^/  /' .sim/ip_fx.log
else
  echo "  FAIL fixtures"; tail -5 .sim/ip_fx.log; fail=1
fi

run_one() {   # sim stem stall -> 0 on PASS; log in .sim/ip_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/ip_last.log
  grep -q "^PASS: intra_pred_tb" .sim/ip_last.log
}
report() {    # label stall
  if run_one .sim/ip_sim "$STEM" "$2"; then
    echo "  PASS $1: $(grep '^intra_pred_tb:' .sim/ip_last.log | head -1 | sed 's/^intra_pred_tb: [^:]*: //')"
    [ "$2" = 0 ] && echo "       $(grep '^intra_pred_tb: samples' .sim/ip_last.log | sed 's/^intra_pred_tb: //')"
  else echo "  FAIL $1"; grep FAIL .sim/ip_last.log | head -3; fail=1; fi
}

echo "== GREEN =="
if [ -f "$STEM.meta.hex" ]; then
  report "every class, always-ready consumer" 0
  report "every class, +stall" 3
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own case class / arm) =="
  RES=$(mktemp -d)
  mut() {   # name old new expect-arm expect-class stall   (expect-class "" = any)
    local name=$1 old=$2 new=$3 arm=$4 cls=$5 stall=$6
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/intra_pred.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/intra_pred.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    if [ "$stall" != 0 ]; then
      # the stall arm must be the one that sees it: the always-ready run has to survive
      vvp -n "$d/sim" "+stem=$STEM" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log0"
      if ! grep -q "^PASS: intra_pred_tb" "$d/log0"; then
        { echo "  $name: caught WITHOUT stall -- the stall arm is not what sees it"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
      fi
    fi
    vvp -n "$d/sim" "+stem=$STEM" "+stall=$stall" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: intra_pred_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[$arm\]" "$d/log" && { [ -z "$cls" ] || grep -q "FAIL \[$arm\] case [0-9]* ($cls " "$d/log"; }; then
      echo "  $name: caught by $(grep -m1 "FAIL \[$arm\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT by [$arm] ${cls:+in class $cls}:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut M1  "begin m = big ? 6'sd14 : 6'sd6; pat = P_P11; end" "begin m = big ? 6'sd14 : 6'sd6; pat = P_P12; end" pred "k0/m3" 0 &
  mut M2  "else if (z_vr == -6'sd1) pat = P_CNR;" "else if (1'b0) pat = P_CNR;" pred "k0/m5" 0 &
  mut M3  "begin m = big ? 6'sd6 : 6'sd2; pat = P_P11; end" "begin m = big ? 6'sd7 : 6'sd3; pat = P_CPY; end" pred "k0/m8" 0 &
  mut M4  "wire  [9:0]  s4_l     = gs[1] + 10'd2;" "wire  [9:0]  s4_l     = gs[1] + 10'd1;" pred "k0/m2" 0 &
  mut M5  "h5 = (hx <<< 2) + hx + 18'sd32;" "h5 = (hx <<< 2) + hx + 18'sd16;" pred "k1/m3" 0 &
  mut M6  "h5 = (hx <<< 5) + (hx <<< 1) + 18'sd32;" "h5 = (hx <<< 2) + hx + 18'sd32;" pred "k2/m3" 0 &
  mut M7  "if (av_t)           dc_q1 = cq_t1[7:0];          // xO > 0, yO == 0\n        else if (av_l)      dc_q1 = cq_l0[7:0];" "if (av_l)           dc_q1 = cq_l0[7:0];\n        else if (av_t)      dc_q1 = cq_t1[7:0];" pred "k2/m0" 0 &
  wait
  mut M8  "P_CNR:   begin si0 = 6'd16;  si1 = I_CORNER; si2 = 6'd0;  f_sel = F_AVG3; end" "P_CNR:   begin si0 = 6'd16;  si1 = 6'd0; si2 = I_CORNER;  f_sel = F_AVG3; end" pred "k0/m4" 0 &
  mut M9  "else if (av_t)      dc_l16 = s16_t[11:4];" "else if (av_t)      dc_l16 = s16_both[12:5];" pred "k1/m2" 0 &
  mut M10 "pat = x[0] ? P_M12 : P_M01;             // zHD odd / even" "pat = y[0] ? P_M12 : P_M01;             // zHD odd / even" pred "k0/m6" 0 &
  mut M11 "pat = y[0] ? P_P12 : P_P01;" "pat = y[0] ? P_P01 : P_P12;" pred "k0/m7" 0 &
  mut M12 "s_valid <= 1'b1; s_last <= (pos == n_last);" "s_valid <= 1'b1; s_last <= (pos == n_last - 8'd1);" last "" 0 &
  mut M13 "wire        adv = !pred_valid || pred_ready;" "wire        adv = 1'b1;" pred "" 3 &
  wait
  mut M14 "fc = (xx == 4'd15) ? nb[15] : nb[{2'b00, xx + 4'd1}];" "fc = nb[{2'b00, xx + 4'd1}];" pred "k3/m3" 0 &
  mut M15 "fa = (xx == 4'd0) ? (av_c ? nb[32] : nb[0]) : s_raw;" "fa = (xx == 4'd0) ? nb[0] : s_raw;" pred "k3/m0" 0 &
  mut M17 "if (av_t && av_l)   dc_l8 = s8_both[11:4];" "if (av_t && av_l)   dc_l8 = s8_t[10:3];" pred "k3/m2" 0 &
  mut M18 "else begin side = 1'b1; m = sy - (sx <<< 1) - 6'sd1; pat = P_M12; end" "else begin side = 1'b1; m = sy - 6'sd1; pat = P_M12; end" pred "k3/m5" 0 &
  mut M19 "else if (z_hu == (big ? 6'sd13 : 6'sd5)) begin" "else if (z_hu == 6'sd5) begin" pred "k3/m8" 0 &
  mut M21 "z_hd <= (g_sy <<< 1) - g_sx;" "z_hd <= (g_sy <<< 1) - g_sx + 6'sd1;" pred "k0/m6" 0 &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
