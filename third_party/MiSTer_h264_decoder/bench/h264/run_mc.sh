#!/usr/bin/env bash
# run_mc.sh -- the motion-compensation gate: h264/dec/mc_interp.sv (bench/h264/mc_interp_tb.sv)
# and h264/dec/wpred.sv (bench/h264/wpred_tb.sv); fixtures from tools/mc_golden.py
# (mc_interp's golden <- tools/h264_recon_ref.py's mc_luma / mc_chroma; wpred's <- the
# generator's transcription of 8.4.2.3 / 8.4.3 from the spec text, cross-checked there
# against h264_recon_ref.py's SliceDecoder.weighted on a weighted x264 clip)
#
# GREEN (docs/h264_recon.md S2.4):
#   * mc_interp: every sample of every case equals the model's -- every partition size
#     (luma {4,8,16}^2, chroma halved), every fractional position (16 luma, 64 chroma),
#     random reference planes at random integer positions including off the picture
#     edges, the extreme fills, the j-rounding sentinels; with an always-ready consumer
#     (which also pins every case to its class's window-read count + the pipeline
#     latency) and with a random-ready one (+stall); and (P5b) with the window's rows
#     arriving one at a time after random delays (+rows=1: the streaming start, rows not
#     yet counted in rows_avail are X);
#   * wpred: every sample equals the transcription's -- default single / bi, explicit
#     single and bi at every logWD (both offsets zero first, then random offsets), the
#     implicit range (w up to 128), the extremes, and -- with ffmpeg's libx264 -- the
#     (inputs, output) triples recorded from a fade encoded with weightp=2 (explicit P
#     weights, luma and chroma) and weightb=1 (implicit bi); always-valid producers /
#     always-ready consumer, then random ones (+stall). SKIP of the clip arm without
#     libx264; when present, the clip MUST have produced explicit-single and implicit-bi
#     cases (a fixture-range check, not a hope).
#
# --red: mutations on a COPY of the RTL, each caught by its own arm and case class (cases
# are sorted (plane, fy, fx, size) / (source, bi, logWD, offsets), so the class named is
# the first one that can see it):
#   M1  luma horizontal tap 20 -> 19                              -> [pred] L4x4 fx1fy0 (a: avg(G, b))
#   M2  the centre's rounding (j1 + 512) >> 10 -> (j1 + 511)      -> [pred] a j position (f i j k q)
#   M3  b's Clip1((b1 + 16) >> 5) clip removed                     -> [pred] L4x4 fx1fy0
#   M4  position e's partners (b, h) -> (b, m)                     -> [pred] fx1fy1 (e)
#   M5  position n from G instead of M                             -> [pred] fx0fy3 (n)
#   M6  chroma's + 32 dropped                                      -> [pred] C fx1fy0 (the integer position cannot see it)
#   M7  chroma's xF / yF weights swapped                           -> [pred] C fx1fy0
#   M8  the window stride off by one (the win_stride input's register, P5b 4b)                          -> [pred] L4x4 fx0fy0
#   M9  the sweep ends one read early (pred_last one sample early) -> [last]
#   M10 the output register ignores pred_ready                     -> [pred|count|last] under +stall only
#                                                                     (must survive +stall=0: the stall arm is load-bearing)
#   M12 chroma's column offset ignored (the slice read from column 0)  -> [pred] C fx0fy0 under +off only
#   M13 the whole-sample luma class's offset ignored                    -> [pred] L fx0fy0 under +off only
#       (both must survive the plain run: there col_off is 0)
#   M11 the row gate removed (P5b streaming: a read ahead of rows_avail) -> [pred] under +rows=1 only
#                                                                     (must survive the plain run: the window is whole there)
#   M16 (perf/retime) S8's FIFO write a stage early (the operands not yet registered) -> [pred|last]
#   W1  wpred bi rounding 2^logWD -> 2^(logWD-1)                   -> [out] E/bi lw0 oz
#   W2  wpred single-list logWD == 0: rounds by 1                  -> [out] E/single lw0
#   W3  wpred offset rounding (o0 + o1 + 1) >> 1 -> (o0 + o1) >> 1 -> [out] E/bi lw0 (survives the "oz" class: the offsets are what sees it)
#   W4  wpred ignores out_ready                                    -> [out|count|last] under +stall only
#   W5  wpred takes b samples in a single-list case                -> [count] D/single
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL_MC=h264/dec/mc_interp.sv
RTL_WP=h264/dec/wpred.sv
TB_MC=bench/h264/mc_interp_tb.sv
TB_WP=bench/h264/wpred_tb.sv
STEM_MC="$GEN/mc_interp"
STEM_WP="$GEN/wpred"
mkdir -p "$GEN"

rm -f .sim/mc_sim   # iverilog leaves the old binary on a failed build: never run it

iverilog -g2012 -o .sim/mc_sim $RTL_MC $TB_MC 2>&1 | grep -v sorry
[ -f .sim/mc_sim ] || { echo "  FAIL mc_interp_tb: build"; exit 1; }
rm -f .sim/wp_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/wp_sim $RTL_WP $TB_WP 2>&1 | grep -v sorry
[ -f .sim/wp_sim ] || { echo "  FAIL wpred_tb: build"; exit 1; }

echo "== FIXTURES =="
CLIP=""
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  # a fade (weightp=2 emits explicit luma AND chroma weights on it) with B pictures under
  # weightb=1 (x264's B weighting is the IMPLICIT mode, weighted_bipred_idc 2)
  if ffmpeg -v error -f lavfi -i "testsrc2=size=320x240:rate=24,fade=t=out:st=0:d=0.3" -frames:v 8 -c:v libx264 -pix_fmt yuv420p \
       -x264-params "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:weightp=2:weightb=1:keyint=8:min-keyint=8:scenecut=0:crf=26" \
       -bsf:v h264_mp4toannexb -f h264 -y .sim/mc_x264.264; then
    CLIP=".sim/mc_x264.264"
  else echo "  FAIL: x264 clip"; fail=1; fi
else
  echo "  SKIP clip arm: ffmpeg with libx264 not found"
fi
# shellcheck disable=SC2086
if python3 tools/mc_golden.py --out-mc "$STEM_MC" --out-wp "$STEM_WP" --seeds 6 ${CLIP:+--clip "$CLIP"} > .sim/mc_fx.log 2>&1; then
  sed 's/^/  /' .sim/mc_fx.log
  if [ -n "$CLIP" ]; then
    # the clip must exercise what its arm claims
    grep -q "^  E/single lw[1-7] clip" .sim/mc_fx.log || { echo "  FAIL: the clip recorded no explicit single-list weighting"; fail=1; }
    grep -q "^  I/bi lw5 oz clip" .sim/mc_fx.log || { echo "  FAIL: the clip recorded no implicit bi-prediction"; fail=1; }
    grep -q "every one reproduced by the spec transcription" .sim/mc_fx.log || { echo "  FAIL: the transcription was not cross-checked"; fail=1; }
  fi
else
  echo "  FAIL fixtures"; tail -5 .sim/mc_fx.log; fail=1
fi

run_one() {   # sim stem stall [rows [off [ovl]]] -> 0 on PASS; log in .sim/mc_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" "+rows=${4:-0}" "+off=${5:-0}" "+ovl=${6:-0}" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/mc_last.log
  grep -q "^PASS: " .sim/mc_last.log
}
report() {    # label sim stem stall tbname [rows [off [ovl]]]
  if run_one "$2" "$3" "$4" "${6:-0}" "${7:-0}" "${8:-0}"; then
    echo "  PASS $1: $(grep "^$5:" .sim/mc_last.log | head -1 | sed "s/^$5: [^:]*: //")"
    if [ "$5" = mc_interp_tb ] && [ "$4" = 0 ]; then grep "^mc_interp_tb:   \|by position class" .sim/mc_last.log | sed 's/^mc_interp_tb: /       /'; fi
  else echo "  FAIL $1"; grep FAIL .sim/mc_last.log | head -3; fail=1; fi
}

echo "== GREEN: mc_interp =="
if [ -f "$STEM_MC.meta.hex" ]; then
  report "every size and position, always-ready consumer" .sim/mc_sim "$STEM_MC" 0 mc_interp_tb
  report "every size and position, +stall"                .sim/mc_sim "$STEM_MC" 3 mc_interp_tb
  report "every size and position, rows streamed in, +stall" .sim/mc_sim "$STEM_MC" 3 mc_interp_tb 1
  report "every size and position, a column slice of a wider window (+off), always ready" .sim/mc_sim "$STEM_MC" 0 mc_interp_tb 0 1
  report "every size and position, +off, rows streamed in, +stall" .sim/mc_sim "$STEM_MC" 3 mc_interp_tb 1 1
  report "every size and position, items overlapped (+ovl), always ready" .sim/mc_sim "$STEM_MC" 0 mc_interp_tb 0 0 1
  report "every size and position, items overlapped (+ovl), +stall" .sim/mc_sim "$STEM_MC" 3 mc_interp_tb 0 0 1
fi
echo "== GREEN: wpred =="
if [ -f "$STEM_WP.meta.hex" ]; then
  report "every class, always-valid / always-ready" .sim/wp_sim "$STEM_WP" 0 wpred_tb
  report "every class, +stall"                      .sim/wp_sim "$STEM_WP" 3 wpred_tb
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm and case class) =="
  RES=$(mktemp -d)
  mut() {   # name unit old new expect-arm-regex expect-class-regex stall   (unit mc | wp)
    local name=$1 unit=$2 old=$3 new=$4 arm=$5 cls=$6 stall=$7
    local d rtl tb stem pass
    d=$(mktemp -d)
    if [ "$unit" = mc ]; then rtl=mc_interp.sv; tb=$TB_MC; stem=$STEM_MC; pass="PASS: mc_interp_tb"
    else rtl=wpred.sv; tb=$TB_WP; stem=$STEM_WP; pass="PASS: wpred_tb"; fi
    cp "h264/dec/$rtl" "$d/"
    python3 - "$d/$rtl" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/$rtl" "$tb" 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local rows=0 off=0 ovl=0
    if [ "$stall" = ovl ]; then stall=3; ovl=1
      # the overlap arm must be the one that sees it: the serial run has to survive
      vvp -n "$d/sim" "+stem=$stem" +stall=3 2>&1 | grep -v 'readmem\|Not enough' > "$d/log0"
      if ! grep -q "^$pass" "$d/log0"; then
        { echo "  $name: caught WITHOUT +ovl -- the overlap arm is not what sees it"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
      fi
    elif [ "$stall" = off ]; then stall=0; off=1
      vvp -n "$d/sim" "+stem=$stem" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log0"
      if ! grep -q "^$pass" "$d/log0"; then
        { echo "  $name: caught WITHOUT +off -- the offset arm is not what sees it"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
      fi
    elif [ "$stall" = rows ]; then stall=0; rows=1
      # the row-release arm must be the one that sees it: the whole-window run has to survive
      vvp -n "$d/sim" "+stem=$stem" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log0"
      if ! grep -q "^$pass" "$d/log0"; then
        { echo "  $name: caught WITHOUT +rows -- the row-release arm is not what sees it"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
      fi
    elif [ "$stall" != 0 ]; then
      # the stall arm must be the one that sees it: the always-ready run has to survive
      vvp -n "$d/sim" "+stem=$stem" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log0"
      if ! grep -q "^$pass" "$d/log0"; then
        { echo "  $name: caught WITHOUT stall -- the stall arm is not what sees it"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
      fi
    fi
    vvp -n "$d/sim" "+stem=$stem" "+stall=$stall" "+rows=$rows" "+off=$off" "+ovl=$ovl" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^$pass" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\] case [0-9]+ \(($cls)\)" "$d/log"; then
      echo "  $name: caught by $(grep -m1 -E "FAIL \[($arm)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT by [$arm] in class /$cls/:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  ANY='[^)]*'
  mut M1  mc "bsum <= bp0s - (bp1s <<< 2) - bp1s + (bp2s <<< 4) + (bp2s <<< 2);" "bsum <= bp0s - (bp1s <<< 2) - bp1s + (bp2s <<< 4) + (bp2s <<< 1) + bp2s;" pred "L4x4 fx1fy0" 0 &
  mut M2  mc "wire signed [20:0] jt = (jsum + 21'sd512) >>> 10;" "wire signed [20:0] jt = (jsum + 21'sd511) >>> 10;" pred "L[0-9x]* (fx2fy1|fx1fy2|fx2fy2|fx3fy2|fx2fy3)" 0 &
  mut M3  mc "wire  [7:0]  b_clip = bt[15] ? 8'd0 : (|bt[14:8])  ? 8'd255 : bt[7:0];" "wire  [7:0]  b_clip = bt[7:0];" pred "L4x4 fx1fy0" 0 &
  mut M4  mc "4'b01_01: begin opa = b7;  opb = h7;  end" "4'b01_01: begin opa = b7;  opb = m7;  end" pred "L[0-9x]* fx1fy1" 0 &
  mut M5  mc "4'b11_00: begin opa = m7i; opb = h7;  end" "4'b11_00: begin opa = g7;  opb = h7;  end" pred "L[0-9x]* fx0fy3" 0 &
  wait
  mut M6  mc "cv <= wy0_4 * cha + wy1_4 * chc + 16'd32;" "cv <= wy0_4 * cha + wy1_4 * chc + 16'd0;" pred "C[0-9x]* fx1fy0" 0 &
  mut M7  mc "wx0_s[!ps] <= 4'd8 - {1'b0, frac_x}; wx1_s[!ps] <= {1'b0, frac_x};" "wx0_s[!ps] <= 4'd8 - {1'b0, frac_y}; wx1_s[!ps] <= {1'b0, frac_y};" pred "C[0-9x]* fx1fy0" 0 &
  mut M8  mc "stride <= win_stride;" "stride <= win_stride + 5'd1;" pred "L4x4 fx0fy0" 0 &
  mut M9  mc "wire last_now = (c == c1) && (r == r1);" "wire last_now = (c == c1 - 5'd1) && (r == r1);" last "$ANY" 0 &
  mut M10 mc "wire        load = (fcnt != 5'd0) && (!pred_valid || pred_ready);" "wire        load = (fcnt != 5'd0);" "pred|count|last" "$ANY" 3 &
  mut M11 mc "&& (r < rows_avail);" ";" pred "$ANY" rows &
  mut M12 mc "c <= 5'd0; r <= 5'd0; row_base <= {4'd0, col_off};\n                end else if (!in_xnz && !in_ynz)" "c <= 5'd0; r <= 5'd0; row_base <= 9'd0;\n                end else if (!in_xnz && !in_ynz)" pred "C[0-9x]* fx0fy0" off &
  # S4k, items overlapped: a use site reading the set of the reads ISSUING (ps), not its stage's
  # tag -- equal while items run serially, wrong once the next item starts under the drain
  mut M14 mc "fx_7 <= fx_s[t6_s]; fy_7 <= fy_s[t6_s];" "fx_7 <= fx_s[ps]; fy_7 <= fy_s[ps];" pred "$ANY" ovl &
  mut M15 mc "always_comb begin ready = !active && !set_used[!ps]; rd_done = !active; end" "always_comb begin ready = !active; rd_done = !active; end" pred "$ANY" ovl &
  mut M13 mc "row_base <= {3'd0, win_stride, 1'b0} + {4'd0, col_off};\n                end else if (!in_ynz)" "row_base <= {3'd0, win_stride, 1'b0};\n                end else if (!in_ynz)" pred "L[0-9x]* fx0fy0" off &
  # (perf/retime) S8: the FIFO written a stage early (the previous sample's registered operands)
  mut M16 mc "assign fpush = t8_ov;" "assign fpush = t7_ov;" "pred|last" "$ANY" 0 &
  wait
  mut W1  wp "wire  signed [19:0] rnd_b = 20'sd1 <<< lw;" "wire  signed [19:0] rnd_b = (20'sd1 <<< lw) >>> 1;" out "E/bi lw0 oz" 0 &
  mut W2  wp "wire  signed [19:0] rnd_s = (lw == 3'd0) ? 20'sd0 : (20'sd1 <<< (lw - 3'd1));" "wire  signed [19:0] rnd_s = (lw == 3'd0) ? 20'sd1 : (20'sd1 <<< (lw - 3'd1));" out "E/single lw0" 0 &
  mut W3  wp "wire  signed [9:0]  off_b = (o0x + o1x + 10'sd1) >>> 1;" "wire  signed [9:0]  off_b = (o0x + o1x) >>> 1;" out "E/bi lw0" 0 &
  mut W4  wp "wire adv  = !out_valid || out_ready;" "wire adv  = 1'b1;" "out|count|last" "$ANY" 3 &
  mut W5  wp "assign b_ready = take && bi_r;" "assign b_ready = take;" count "D/single" 0 &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
