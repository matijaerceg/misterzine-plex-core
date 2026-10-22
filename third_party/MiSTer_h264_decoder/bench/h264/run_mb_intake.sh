#!/usr/bin/env bash
# run_mb_intake.sh -- the macroblock intake gate (h264/dec/mb_intake.sv,
# bench/h264/mb_intake_tb.sv; goldens tools/intake_golden.py <- tools/h264_recon_ref.py's
# intake and expand_mb). docs/h264_recon.md S2.3.
#
# GREEN, per stream: every macroblock's descriptor (type, sub-types, cbp incl.
# Intra16x16's implied one, the Intra4x4 syntax, refs per slot, mvd and pred flags per
# 4x4 block, the direct sub-macroblocks, coded slots, nz) and every level read back
# identical, with and without input gaps:
#   * x264 at run time (SKIP without libx264): P with every partition size incl. 4x4
#     sub-partitions and 4 references; B with B_8x8 and direct sub-macroblocks, 3
#     references; a lossless noise clip (I_PCM; x264 marks it High 4:4:4 Predictive with the
#     transform bypass, which the core refuses: tools/h264_synth.py unlossless rewrites it
#     to plain High -- every macroblock is I_PCM, so the bypass never applied); an intra
#     clip (Intra4x4 / 16x16);
#     High (Phase 5): P/B with the 8x8 transform (transform_size_8x8_flag in both of its
#     places, 8x8 blocks as four slots, nz per 8x8) and an Intra_8x8 clip;
#   * with $H264_REFS_DIR: CAPM3_Sony_D (I_PCM in P / B), CAWP5_TOSHIBA_E (many refs),
#     cabac_mot_fld0_full (field pictures with content: UMD's Family Guy window's role).
#
# --red: mutations on a COPY of the RTL, each caught by its own stream:
#   I1  Intra16x16's implied chroma cbp halved (class 1 -> 0, 2 -> 1) -> intra (the clip has
#       no Plane-mode Intra16x16, so an off-by-one on the type would only move Plane types)
#   I2  the ref cursor never advances (every ref to slot 0)        -> x264 P
#   I3  8x4 sub-partitions' mvd masks swapped                       -> x264 P
#   I4  B mb_type 12 (L0 / Bi) lists swapped                        -> x264 B
#   I5  B_8x8 direct sub-macroblocks not flagged                    -> x264 B
#   I6  I_PCM samples written at block-slot addresses               -> pcm
#   I7  nz set for zero levels too                                  -> x264 P
#   I8  prev_intra4x4_pred_mode_flag 1 does not advance the block   -> intra
#   I9  the coefficient read from the working bank, not the output  -> intra (the next MB's levels)
#   I10 the working descriptor moved out over one still being read  -> x264 P
#   I11 nz not OR-ed per 8x8 with the 8x8 transform                 -> x264 High P/B
#   I12 an 8x8 block's 64 levels all into its first slot            -> x264 High P/B
#   I13 transform_size_8x8_flag kept from the previous macroblock   -> x264 High intra
#   I14 (perf/retime) the slot-use table a cycle late (from the registered layout) -> x264 B
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/mb_intake.sv"
TB=bench/h264/mb_intake_tb.sv
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
mkdir -p "$GEN"
: > .sim/intake_fx.log

rm -f .sim/intake_sim   # iverilog leaves the old binary on a failed build: never run it

iverilog -g2012 -o .sim/intake_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/intake_sim ] || { echo "  FAIL mb_intake_tb: build"; exit 1; }

run_one() {   # sim stem stall -> 0 on PASS
  timeout 1800 vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem' > .sim/intake_last.log
  grep -q "^PASS: mb_intake_tb" .sim/intake_last.log
}
report() {    # label name
  local stem="$GEN/intake_$2"
  for st in 0 3; do
    if run_one .sim/intake_sim "$stem" $st; then
      echo "  PASS $1 (stall $st): $(grep '^mb_intake_tb:' .sim/intake_last.log | sed 's/^mb_intake_tb: //')"
    else echo "  FAIL $1 (stall $st)"; grep -m2 FAIL .sim/intake_last.log; fail=1; fi
  done
}
fixture() {   # name stream [max_mbs]
  python3 tools/intake_golden.py "$2" --out "$GEN/intake_$1" ${3:+--max-mbs $3} >> .sim/intake_fx.log 2>&1
}
x264() {      # out size frames extra-params
  ffmpeg -v error -f lavfi -i "testsrc2=size=$2:rate=24" -frames:v "$3" -c:v libx264 -pix_fmt yuv420p \
    -x264-params "$4" -bsf:v h264_mp4toannexb -f h264 -y "$1"
}

echo "== GREEN: x264 streams (refs-free) =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 .sim/intake_p.264 320x240 6 "cabac=1:8x8dct=0:bframes=0:ref=4:partitions=all:me=umh:subme=7:keyint=6:crf=24" \
  && x264 .sim/intake_b.264 320x240 8 "cabac=1:8x8dct=0:bframes=3:b-pyramid=0:ref=3:partitions=all:direct=spatial:subme=7:keyint=8:crf=24" \
  && x264 .sim/intake_i.264 320x240 2 "cabac=1:8x8dct=0:keyint=1:crf=18" \
  && x264 .sim/intake_h.264 320x240 6 "cabac=1:8x8dct=1:bframes=2:b-pyramid=0:ref=2:partitions=all:direct=spatial:keyint=6:crf=24" \
  && x264 .sim/intake_hi.264 320x240 2 "cabac=1:8x8dct=1:keyint=1:crf=20" \
  && ffmpeg -v error -f lavfi -i "nullsrc=size=64x64:rate=24,geq=lum='random(1)*255':cb='random(1)*255':cr='random(1)*255'" \
       -frames:v 1 -c:v libx264 -profile:v main -pix_fmt yuv420p -x264-params "cabac=1:8x8dct=0:qp=0" -bsf:v h264_mp4toannexb -f h264 -y .sim/intake_pcm_ll.264 \
  && python3 tools/h264_synth.py .sim/intake_pcm_ll.264 unlossless .sim/intake_pcm.264 >> .sim/intake_fx.log 2>&1 \
  && fixture p .sim/intake_p.264 && fixture b .sim/intake_b.264 && fixture i .sim/intake_i.264 && fixture pcm .sim/intake_pcm.264 \
  && fixture h .sim/intake_h.264 && fixture hi .sim/intake_hi.264 \
  && X264=1 || { echo "  FAIL x264 fixtures"; tail -3 .sim/intake_fx.log; fail=1; }
  if [ $X264 = 1 ]; then
    report "x264 P, every partition, 4 refs" p
    report "x264 B, B_8x8 + direct, 3 refs" b
    report "x264 intra (4x4 / 16x16)" i
    report "x264 lossless noise (I_PCM)" pcm
    report "x264 High P/B, the 8x8 transform" h
    report "x264 High intra (Intra_8x8 / 4x4 / 16x16)" hi
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance streams (\$H264_REFS_DIR) =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
conf() {      # label zip max_mbs
  if [ -f "$AVC/$2.zip" ]; then
    local d; d=$(mktemp -d)
    unzip -o -q "$AVC/$2.zip" -d "$d"
    local f; f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" | head -1)
    if [ -n "$f" ] && fixture "$2" "$f" "$3"; then report "$1" "$2"; else echo "  FAIL $1: fixture"; fail=1; fi
    rm -rf "$d"
  else echo "  SKIP $1: no $AVC/$2.zip"; fi
}
if [ -d "$AVC" ]; then
  conf "CAPM3_Sony_D (I_PCM in P / B), 4000 MBs" CAPM3_Sony_D 4000
  conf "CAWP5_TOSHIBA_E (many refs), 4000 MBs" CAWP5_TOSHIBA_E 4000
  conf "cabac_mot_fld0_full (fields), 6000 MBs" cabac_mot_fld0_full 6000
else
  echo "  SKIP: no $AVC (set H264_REFS_DIR)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own stream) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixtures"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name old new stream
    local name=$1 old=$2 new=$3 target=$4
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/mb_intake.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/mb_intake.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 1800 vvp -n "$d/sim" "+stem=$GEN/intake_$target" +stall=0 2>&1 | grep -v readmem > "$d/log"
    if grep -q "^PASS: mb_intake_tb" "$d/log"; then
      { echo "  $name: SURVIVED on $target -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[\(dsc\|coef\)\]" "$d/log"; then
      echo "  $name: caught on $target by $(grep -m1 FAIL "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed on $target but not in [dsc]/[coef]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut I1 "w_cbp <= {(i16_t >= 5'd12) ? ((i16_t - 5'd12) >> 2) : (i16_t >> 2)," "w_cbp <= {(i16_t >= 5'd12) ? ((i16_t - 5'd12) >> 3) : (i16_t >> 3)," i &
  mut I2 "ref_next[lx] <= ref_sel[lx] + 3'd1;" "ref_next[lx] <= ref_sel[lx];" p &
  mut I3 "SS_8X4: m4 = (w_sub == 2'd0) ? 4'b0011 : 4'b1100;" "SS_8X4: m4 = (w_sub == 2'd0) ? 4'b1100 : 4'b0011;" p &
  mut I4 "6'd12: begin b_shape = SH_16X8;  b_p0 = 2'b01; b_p1 = 2'b11; end" "6'd12: begin b_shape = SH_16X8;  b_p0 = 2'b11; b_p1 = 2'b01; end" b &
  wait
  mut I5 "w_direct8 <= {(slice_type == ST_B && in_val[3:0] == 4'd0), w_direct8[3:1]};" "w_direct8 <= {1'b0, w_direct8[3:1]};" b &
  mut I6 "cram_waddr <= blk_pcm ? blk_pos : {blk_slot +" "cram_waddr <= {blk_slot +" pcm &
  mut I7 "if (!blk_pcm && blk_slot >= 5'd1 && blk_slot <= 5'd16 && in_val != 16'd0)" "if (!blk_pcm && blk_slot >= 5'd1 && blk_slot <= 5'd16)" p &
  mut I8 "if (in_val[0]) i4_blk <= i4_blk + 1'b1;          // no rem follows" "if (1'b0) i4_blk <= i4_blk + 1'b1;" i &
  mut I9 "coef_data <= cram[{coef_bank, coef_addr}];" "coef_data <= cram[{cwb, coef_addr}];" i &
  mut I10 "if (w_done && !mb_valid) begin" "if (w_done) begin" p &
  wait
  mut I11 "mb_nz <= w_t8 ? {{4{|w_nz[15:12]}}, {4{|w_nz[11:8]}}, {4{|w_nz[7:4]}}, {4{|w_nz[3:0]}}} : w_nz;" "mb_nz <= w_nz;" h &
  mut I12 "{blk_slot + (blk_l8 ? {3'd0, blk_pos[5:4]} : 5'd0), blk_pos[3:0]}" "{blk_slot, blk_pos[3:0]}" h &
  mut I13 "w_coded <= '0; w_nz <= '0; w_pcm <= 1'b0; w_t8 <= 1'b0;" "w_coded <= '0; w_nz <= '0; w_pcm <= 1'b0;" hi &
  # (perf/retime) uses registered from the layout's next values: built from the registered layout it lags a cycle
  mut I14 "uses[lx][b] <= (b[2:0] < n_slots_c) && slot_lists_c[b][lx];" "uses[lx][b] <= (b[2:0] < n_slots) && slot_lists[b][lx];" b &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
