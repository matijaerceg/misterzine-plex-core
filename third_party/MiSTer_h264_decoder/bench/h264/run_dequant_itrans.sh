#!/usr/bin/env bash
# run_dequant_itrans.sh -- the inverse scan / scaling / inverse transform gate
# (h264/dec/dequant_itrans.sv, bench/h264/dequant_itrans_tb.sv; goldens
# tools/itrans_golden.py <- tools/h264_recon_ref.py's dequant4x4 + itrans4x4, luma_dc,
# chroma_dc, which are proven pixel-exact against ffmpeg). docs/h264_recon.md S2.4.
#
# GREEN, per fixture class: every output word equal to the model's, res_last on the
# right word, nothing extra, no hang:
#   * it_rand_<KIND>_<frame|field>: every qp 0..51 x random blocks inside the spec ranges
#     (the golden asserts them), each of the five kinds, both scans;
#   * it_sparse_<frame|field>: one coefficient at every scan position, both signs, at the
#     largest magnitude the range admits (the scan ROM entry by entry, the widest values);
#   * it_zero: all-zero blocks, and AC blocks whose only content is dc_in;
#   * it_real: the fixture-range check -- every block an x264 clip's decode transforms
#     (encoded at run time with ffmpeg + libx264, crf + adaptive quantisation so the QP
#     varies per macroblock; the model's own residual path is wrapped to capture the
#     levels, the QP and the scan it used) -- SKIP without libx264;
#   * with $H264_REFS_DIR: it_real_field, the same from camp_mot_fld0_full's field pictures
#     (H.264.1; UMD cut a disc clip here);
#   * a spread of the classes again with +stall=5 (random start / coef_valid / res_ready).
#   H264 Phase 5 (High profile, docs/high_profile.md S5):
#   * it_w_<KIND>_<frame|field>: the random classes with WEIGHTED scaling lists (random
#     weights 1..255, a random list per block): the 8-337 rounding term real, the DC kinds
#     scaled by weightScale(0, 0);
#   * it_rand_L8_<frame|field>, it_sparse8_<frame|field>: 8x8 blocks through
#     dequant_itrans8 (every qp, flat and weighted, one coefficient at each position);
#   * it_real8: the 8x8 blocks an x264 High clip's decode transforms (SKIP without libx264).
#   Each PASS line reports samples/cycle and cycles/block.
#
# --red: mutations on a COPY of dequant_itrans.sv, each caught by its own fixture class
# (the class named first) while a class the defect must NOT touch still passes (the class
# in parentheses -- that is what makes the arm load-bearing):
#   M1  zig-zag entries 5 and 6 swapped                -> it_rand_L4_frame  (it_rand_L4_field passes)
#   M2  field-scan entries 1 and 2 swapped             -> it_rand_L4_field  (it_rand_L4_frame passes)
#   M3  normAdjust class (i odd, j odd) read as mixed  -> it_rand_L4_frame  (it_rand_LDC_frame: class 0 only)
#   M4  qp < 24 scaling shift wrong (>>3 for qp/6 = 0) -> it_rand_L4_frame  (it_rand_LDC_frame: no 4x4 scaling)
#   M5  butterfly (x1 >> 1) - x3 loses its >> 1        -> it_rand_L4_frame  (it_rand_LDC_frame: Hadamard path)
#   M6  the +32 of (h + 32) >> 6 dropped               -> it_rand_L4_frame  (it_rand_LDC_frame)
#   M7  luma DC qp >= 36 branch: << 1 becomes << 2     -> it_rand_LDC_frame (it_rand_L4_frame)
#   M8  luma DC qp < 12 rounding term dropped          -> it_rand_LDC_frame (it_rand_CDC)
#   M9  chroma DC >> 5 becomes >> 4                    -> it_rand_CDC       (it_rand_LDC_frame)
#   M10 dc_in ignored for kind 1 (LAC): d00 = 0        -> it_rand_LAC_frame (it_rand_CAC_frame)
#   M11 chroma DC outputs dc01 / dc10 swapped          -> it_rand_CDC       (it_rand_LDC_frame)
#   High profile:
#   M12 the weight's byte lanes 0 / 1 swapped                -> it_w_L4_frame    (it_rand_L4_frame: flat)
#   M13 the 8-337 rounding term dropped (qp / 6 = 0)          -> it_w_L4_frame    (it_rand_L4_frame: with flat
#       lists the term is vacuous -- LevelScale a multiple of 16 -- which is why the fork could omit it)
#   M14 the DC kinds' weightScale(0, 0) taken as 16           -> it_w_LDC_frame   (it_rand_LDC_frame)
#   M15 dequant_itrans8: normAdjust8x8 read at the wrong position -> it_rand_L8_frame (it_rand_L4_frame)
#   M16 dequant_itrans8: e3 loses its (d3 >> 1)             -> it_rand_L8_frame  (it_rand_L4_frame)
#   M17 dequant_itrans8: the field scan never used          -> it_rand_L8_field  (it_rand_L8_frame)
#   M18 dequant_itrans8: the row results written untransposed -> it_rand_L8_frame (it_rand_L4_frame)
#   M19 dequant_itrans8: the list (6 / 7) ignored            -> it_rand_L8_frame  (it_rand_L4_frame)
#   M20 dequant_itrans8: 8-357's rounding dropped (qp / 6 = 0) -> it_rand_L8_frame (it_rand_L4_frame)
#   M21 dequant_itrans8: 8-406's + 32 dropped                 -> it_rand_L8_frame (it_rand_L4_frame)
#   Phase 5c part 2 step 2 (docs/mb_pipeline.md S4j), dequant_itrans8 a pipeline over blocks:
#   M22 the four-blocks-in-flight cap dropped (recon_mb's collector holds four) -> [flight],
#       it_rand_L8_frame with a slow consumer, +stall=100 (it_rand_L4_frame)
#   M23 a pass restarted in its done cycle (the same block twice) -> it_rand_L8_frame (it_rand_L4_frame)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/high_tables.sv h264/dec/dequant_itrans.sv h264/dec/dequant_itrans8.sv"
TB=bench/h264/dequant_itrans_tb.sv
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
mkdir -p "$GEN"

# shellcheck disable=SC2086
rm -f .sim/dqit_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/dqit_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/dqit_sim ] || { echo "  FAIL dequant_itrans_tb: build"; exit 1; }

run_one() {   # sim stem stall -> 0 on PASS; log in .sim/dqit_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/dqit_last.log
  grep -q "^PASS: dequant_itrans_tb" .sim/dqit_last.log
}
report() {    # label stem stall
  if run_one .sim/dqit_sim "$2" "$3"; then
    echo "  PASS $1: $(grep '^dequant_itrans_tb:' .sim/dqit_last.log | head -1 | sed 's/^dequant_itrans_tb: [^:]*: //')"
  else echo "  FAIL $1"; grep FAIL .sim/dqit_last.log | head -3; fail=1; fi
}

echo "== FIXTURES =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  ffmpeg -v error -f lavfi -i "testsrc2=size=720x480:rate=24" -frames:v 6 -c:v libx264 -profile:v main -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=2:keyint=6:min-keyint=6:scenecut=0:direct=spatial:aq-mode=1:aq-strength=1.5:crf=22" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/dqit_x264.264 \
  && ffmpeg -v error -f lavfi -i "mandelbrot=size=352x288:rate=30" -frames:v 6 -c:v libx264 -profile:v high -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=1:bframes=2:ref=2:keyint=6:scenecut=0:crf=20" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/dqit_x264h.264 && X264=1 || { echo "  FAIL x264 clips"; fail=1; }
else
  echo "  SKIP it_real: ffmpeg with libx264 not found"
fi
FLD_ZIP="$REFS/H.264.1_bitstreams/AVCv1/cabac_mot_fld0_full.zip"
FLD=0
GOLD_ARGS=(--out "$GEN")
[ $X264 = 1 ] && GOLD_ARGS+=(--stream .sim/dqit_x264.264 --high-stream .sim/dqit_x264h.264)
if [ -f "$FLD_ZIP" ]; then
  unzip -o -q "$FLD_ZIP" camp_mot_fld0_full.26l -d .sim/ && GOLD_ARGS+=(--field-stream .sim/camp_mot_fld0_full.26l) && FLD=1
else echo "  SKIP it_real_field: no $FLD_ZIP (set H264_REFS_DIR)"; fi
if python3 tools/itrans_golden.py "${GOLD_ARGS[@]}" > .sim/dqit_fx.log 2>&1; then
  sed 's/^/  /' .sim/dqit_fx.log
else
  echo "  FAIL fixtures"; tail -3 .sim/dqit_fx.log; fail=1
fi

echo "== GREEN: random blocks, every qp, every kind, both scans =="
for k in L4 LAC CAC LDC; do
  report "it_rand_${k}_frame" "$GEN/it_rand_${k}_frame" 0
  report "it_rand_${k}_field" "$GEN/it_rand_${k}_field" 0
done
report "it_rand_CDC" "$GEN/it_rand_CDC" 0
echo "== GREEN: sparse and zero blocks =="
report "it_sparse_frame" "$GEN/it_sparse_frame" 0
report "it_sparse_field" "$GEN/it_sparse_field" 0
report "it_zero" "$GEN/it_zero" 0
echo "== GREEN: real blocks (the fixture-range check) =="
[ $X264 = 1 ] && report "it_real (x264 720x480)" "$GEN/it_real" 0
[ $FLD = 1 ] && report "it_real_field (camp_mot_fld0_full fields)" "$GEN/it_real_field" 0
echo "== GREEN: High profile -- weighted lists, 8x8 blocks =="
for k in L4 LAC CAC LDC; do
  report "it_w_${k}_frame" "$GEN/it_w_${k}_frame" 0
  report "it_w_${k}_field" "$GEN/it_w_${k}_field" 0
done
report "it_w_CDC" "$GEN/it_w_CDC" 0
report "it_rand_L8_frame" "$GEN/it_rand_L8_frame" 0
report "it_rand_L8_field" "$GEN/it_rand_L8_field" 0
report "it_sparse8_frame" "$GEN/it_sparse8_frame" 0
report "it_sparse8_field" "$GEN/it_sparse8_field" 0
[ $X264 = 1 ] && report "it_real8 (x264 High 352x288)" "$GEN/it_real8" 0
echo "== GREEN: +stall (random start / coef_valid / res_ready) =="
report "it_w_L4_field +stall" "$GEN/it_w_L4_field" 5
report "it_rand_L8_frame +stall" "$GEN/it_rand_L8_frame" 5
report "it_rand_L8_frame, a slow consumer" "$GEN/it_rand_L8_frame" 100
report "it_rand_L4_frame +stall" "$GEN/it_rand_L4_frame" 5
report "it_rand_LAC_field +stall" "$GEN/it_rand_LAC_field" 5
report "it_rand_LDC_frame +stall" "$GEN/it_rand_LDC_frame" 5
report "it_rand_CDC +stall" "$GEN/it_rand_CDC" 5
report "it_zero +stall" "$GEN/it_zero" 5
[ $X264 = 1 ] && report "it_real +stall" "$GEN/it_real" 5

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own fixture class) =="
  RES=$(mktemp -d)
  mut() {   # name old new catch_stem pass_stem [file] [stall] [class]
    local name=$1 old=$2 new=$3 catch=$4 pass=$5 file=${6:-dequant_itrans.sv} st=${7:-0} cls=${8:-res}
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/high_tables.sv" "$d/dequant_itrans.sv" "$d/dequant_itrans8.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    vvp -n "$d/sim" "+stem=$GEN/$catch" +stall=$st 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: dequant_itrans_tb" "$d/log"; then
      { echo "  $name: SURVIVED $catch -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif ! grep -q "^FAIL \[$cls\]" "$d/log"; then
      { echo "  $name: $catch failed but NOT in [$cls]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    else
      vvp -n "$d/sim" "+stem=$GEN/$pass" +stall=$st 2>&1 | grep -v 'readmem\|Not enough' > "$d/log2"
      if grep -q "^PASS: dequant_itrans_tb" "$d/log2"; then
        echo "  $name: caught by $catch $(grep -m1 "^FAIL \[$cls\]" "$d/log" | cut -c6-70)... ($pass still passes)" > "$RES/$name"
      else
        { echo "  $name: caught by $catch but $pass ALSO fails -- the arm is not specific"; echo MUTFAIL; } > "$RES/$name"
      fi
    fi
    rm -rf "$d"
  }
  L4F=it_rand_L4_frame; L4D=it_rand_L4_field; LDC=it_rand_LDC_frame; CDC=it_rand_CDC
  mut M1  "5'h05: scan_r = 4'd2;  5'h06: scan_r = 4'd3;" "5'h05: scan_r = 4'd3;  5'h06: scan_r = 4'd2;" $L4F $L4D &
  mut M2  "5'h11: scan_r = 4'd4;  5'h12: scan_r = 4'd1;" "5'h11: scan_r = 4'd1;  5'h12: scan_r = 4'd4;" $L4D $L4F &
  mut M3  "2'b11:   in_cls = 2'd1;" "2'b11:   in_cls = 2'd2;" $L4F $LDC &
  mut M4  "4'd0: dq_sh = (dq_ext + 33'sd8) >>> 4;" "4'd0: dq_sh = (dq_ext + 33'sd8) >>> 3;" $L4F $LDC &
  mut M5  "e2 = x1h - x3;" "e2 = x1 - x3;" $L4F $LDC &
  mut M6  "o_val = ({{16{m_val[19]}}, m_val} + 32) >>> 6;" "o_val = ({{16{m_val[19]}}, m_val}) >>> 6;" $L4F $LDC &
  wait
  mut M7  "4'd7: o_val = o_ext <<< 1;" "4'd7: o_val = o_ext <<< 2;" $LDC $L4F &
  mut M8  "4'd0: o_val = (o_ext + 32) >>> 6;" "4'd0: o_val = o_ext >>> 6;" $LDC $CDC &
  mut M9  "4'd0: o_val = o_ext >>> 5;" "4'd0: o_val = o_ext >>> 4;" $CDC $LDC &
  mut M10 "if (wsel) A1[0] <= {{4{dc_in[15]}}, dc_in}; else A0[0] <= {{4{dc_in[15]}}, dc_in};" "if (wsel) A1[0] <= (kind == K_CAC) ? {{4{dc_in[15]}}, dc_in} : 20'sd0; else A0[0] <= (kind == K_CAC) ? {{4{dc_in[15]}}, dc_in} : 20'sd0;" it_rand_LAC_frame it_rand_CAC_frame &
  # (exp/mb-pipeline, equivalent -- not an arm: one work buffer instead of two ("tsel <= wsel;"
  # without the swap). The unit's contract lets a parent start the next block in the cycle
  # busy drops, but this bench and recon_mb's residual engine both register start, and the
  # next block's first coefficient lands ~7 cycles after the hand-off, when the column pass
  # has read every position the early scan indices overwrite; the two buffers keep the
  # contract rather than depend on that latency. docs/mb_pipeline.md)
  mut M11 "O[1] <= a12[19:0]; O[2] <= m03[19:0];" "O[1] <= m03[19:0]; O[2] <= a12[19:0];" $CDC $LDC &
  wait
  L8F=it_rand_L8_frame; L8D=it_rand_L8_field
  mut M12 "2'd0: w1 = w_q[7:0];   2'd1: w1 = w_q[15:8];" "2'd0: w1 = w_q[15:8];   2'd1: w1 = w_q[7:0];" it_w_L4_frame $L4F &
  mut M13 "4'd0: dq_sh = (dq_ext + 33'sd8) >>> 4;" "4'd0: dq_sh = dq_ext >>> 4;" it_w_L4_frame $L4F &
  mut M14 "if (w00_pend) b_w00 <= b_flat ? 8'd16 : w_q[7:0];" "if (w00_pend) b_w00 <= 8'd16;" it_w_LDC_frame $LDC &
  mut M15 "hp_norm8 u_na (.m(b_m), .r(p1_r), .v(na_w));" "hp_norm8 u_na (.m(b_m), .r(p1_r ^ 6'd9), .v(na_w));" $L8F $L4F dequant_itrans8.sv &
  mut M16 "e3 = x[1] + x[7] - x[3] - (x[3] >>> 1);" "e3 = x[1] + x[7] - x[3];" $L8F $L4F dequant_itrans8.sv &
  wait
  mut M17 "hp_scan8  u_scan (.field(b_field)," "hp_scan8  u_scan (.field(1'b0)," $L8D $L8F dequant_itrans8.sv &
  mut M18 "we <= 1'b1; wa <= {y_k, y_idx};" "we <= 1'b1; wa <= COL ? {y_k, y_idx} : {y_idx, y_k};" $L8F $L4F dequant_itrans8.sv &
  mut M19 "always_comb w_ra = {b_list, in_kz[5:2]};" "always_comb w_ra = {1'b0, in_kz[5:2]};" $L8F $L4F dequant_itrans8.sv &
  mut M20 "4'd0: p3_sh = (p3_ext + 34'sd32) >>> 6;" "4'd0: p3_sh = p3_ext >>> 6;" $L8F $L4F dequant_itrans8.sv &
  mut M21 "wire signed [21:0] m_r = y[0] + 22'sd32;" "wire signed [21:0] m_r = y[0];" $L8F $L4F dequant_itrans8.sv &
  mut M22 "busy = (state != S_IDLE) || a_full[ia] || (inflight >= 3'd4);" "busy = (state != S_IDLE) || a_full[ia];" $L8F $L4F dequant_itrans8.sv 100 flight &
  mut M23 "r_go = !r_busy && !r_done && a_full[ra] && !b_full[rb];" "r_go = !r_busy && a_full[ra] && !b_full[rb];" $L8F $L4F dequant_itrans8.sv &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
