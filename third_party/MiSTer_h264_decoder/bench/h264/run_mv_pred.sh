#!/usr/bin/env bash
# run_mv_pred.sh -- the motion vector derivation gate (h264/dec/mv_pred.sv,
# bench/h264/mv_pred_tb.sv; fixtures tools/mv_pred_golden.py <- tools/h264_recon_ref.py,
# the model proven pixel-exact vs ffmpeg and the H.264.1 CABAC set). docs/h264_recon.md S2.
#
# GREEN, per stream, plain and with +stall=3 (idle gaps, start driven while busy, random
# readback order): every inter macroblock's sixteen blocks (pred, ref, mv per list)
# identical to the model's, the err pulse as expected, done within 120 cycles:
#   * x264 clips encoded at run time (no media, no reference set: needs ffmpeg with
#     libx264 -- SKIP without): P with 4 references, every partition and 4 slices per
#     picture (slice tops: 8.4.1.3.1's substitution, neighbours in another slice); B with spatial
#     direct (bframes 2); B with temporal direct (bframes 3, pyramid: x264 falls back to
#     spatial on some B pictures, so both modes in one stream); the synthetic classes
#     (ERR_REF, ERR_MAP, TD_FRM2FLD / TD_FLD2FRM with negative odd mvCol[1], SP_EDGE on
#     the colZeroFlag boundary, TD_RAW) derived through the model's own methods;
#   * with $H264_REFS_DIR: CAPA1_TOSHIBA_B and camp_mot_picaff0_full (PAFF, temporal direct
#     with all three vertMvScale cases incl. Frm_To_Fld blocks with a negative odd
#     mvCol[1]; CAPA1 every B sub-macroblock type), camp_mot_fld0_full (temporal direct in
#     field pictures, One_To_One), Sharp_MP_PAFF_2r (spatial direct under all three
#     structures), CAFI1_SVA_C (spatial direct in field pictures);
#   (UMD's Akira / Family Guy disc windows are not carried -- docs/harvest.md; their
#   classes, spatial direct on frames and on fields, are required of x264 B spatial,
#   Sharp_MP_PAFF_2r and CAFI1_SVA_C above.)
#   Every fixture has a --require list: the coverage it exists for is asserted non-zero.
#
# --red: mutations on a COPY of mv_pred.sv, each required to be caught by its own case
# class of its own stream (the FAIL line of that class):
#   M1  the median becomes the average                              -> P16x16      (x264 P)
#   M2  the 16x8 partition-0 rule (8-203) dropped                    -> P16x8       (x264 P)
#   M3  C -> D substitution (8-214) dropped                          -> P8x8        (x264 P)
#   M4  the not-yet-decoded rule (6.4.11.7 step 7c) dropped          -> P8x8        (x264 P)
#   M5  P_Skip's zero condition without refIdxA == 0                 -> P_SKIP      (x264 P)
#   M6  spatial direct's MinPositive becomes a plain minimum         -> BDIR16S     (x264 B spatial)
#   M7  colZeroFlag's -1..1 range widened to -2..2                   -> SP_EDGE     (x264 B spatial)
#   M8  direct_8x8_inference's corner selection dropped              -> BDIR16T     (x264 B temporal)
#   M9  temporal direct's +128 rounding dropped                      -> BDIR16T     (x264 B temporal)
#   M10 Frm_To_Fld: floor instead of truncation toward zero (8-193)  -> TD_FRM2FLD  (x264 B temporal)
#   M10r  ...the same on a real stream                               -> BDIR16T / B8x8DT (camp_mot_picaff0, refs)
#   M11 an intra neighbour taken as unavailable                      -> P_SKIP      (x264 P)
#   M12 8.4.1.3.1's B, C <- A substitution dropped                   -> P16x16      (x264 P)
#   M13 mvL1 = mvCol - mvL0 (8-200 reversed)                         -> BDIR16T     (x264 B temporal)
#   M14 the err pulse for a ref_idx naming no entry dropped          -> [err] ERR_REF (x264 P)
#   M15 refIdxL0 = 0 (MapColToList0's result ignored)                 -> BDIR16T / B8x8DT (camp_mot_picaff0, refs)
#   M16 the long-term / equal-POC path (tdir_raw) ignored            -> TD_RAW      (x264 B temporal)
#   M17 start honoured while busy (it aborts the macroblock)         -> P16x16      (x264 P, +stall only)
#   M18 the 8x16 partition-1 rule (8-206) dropped                    -> P8x16       (x264 P)
#   M19 Fld_To_Frm: mvCol[1] not doubled (8-194)                     -> BDIR16T / B8x8DT (camp_mot_picaff0, refs)
#   M20 the block -> entry map not kept (each block reads its own)    -> P16x16      (x264 P)
#   M22 the partition's list use registered for S_APPLY stuck at list 0 (P6 timing) -> a B class
#   M23 (perf/retime) the entry mux's select: a C inside the macroblock never replaced by D -> a P 8x8 / 8x16 / 16x8 class
#   M21 spatial direct's reference not taken as S_SP_REF writes it (ref_in_q from ref_in
#       there too: S_SP_REF is the cycle before S_MVP_Q0 reads it) -> BDIR16S (x264 B spatial;
#       from MiSTer_UMD_Video's arm for the same registered ref_in_q, 2026-09-28)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL=h264/dec/mv_pred.sv
TB=bench/h264/mv_pred_tb.sv
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
mkdir -p "$GEN"
: > .sim/mvp_fx.log

rm -f .sim/mvp_sim   # iverilog leaves the old binary on a failed build: never run it

iverilog -g2012 -o .sim/mvp_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/mvp_sim ] || { echo "  FAIL mv_pred_tb: build"; exit 1; }

fixture() {   # name require golden-args... -> the fixture $GEN/mvp_<name>; the print in .sim/mvp_fx_<name>.log
  local name=$1 req=$2; shift 2
  python3 tools/mv_pred_golden.py "$@" --require "$req" --out "$GEN/mvp_$name" > ".sim/mvp_fx_$name.log" 2>&1
}
show_cov() {  # name
  sed -n 's/^  \(classes\|coverage\)/      \1/p' ".sim/mvp_fx_$1.log"
}
run_one() {   # sim stem stall log -> 0 on PASS
  vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > "$4"
  grep -q "^PASS: mv_pred_tb" "$4"
}
report() {    # label name
  local stem="$GEN/mvp_$2" st log
  for st in 0 3; do
    log=".sim/mvp_$2_s$st.log"
    if run_one .sim/mvp_sim "$stem" $st "$log"; then
      echo "  PASS $1$([ $st != 0 ] && echo ' +stall'): $(grep '^mv_pred_tb: .*macroblocks' "$log" | sed 's/^mv_pred_tb: [^:]*: //')"
    else echo "  FAIL $1$([ $st != 0 ] && echo ' +stall')"; grep -m4 "FAIL\|mismatch" "$log" | sed 's/^/    /'; fail=1; fi
  done
  [ -f ".sim/mvp_$2_s0.log" ] && grep '^mv_pred_tb: cycles' ".sim/mvp_$2_s0.log" | sed 's/^mv_pred_tb: /      /'
}
fx_fail() {   # name label
  echo "  FAIL $2 fixtures"; tail -3 ".sim/mvp_fx_$1.log" | sed 's/^/    /'; fail=1
}
x264() {      # out frames params
  ffmpeg -v error -f lavfi -i "testsrc2=size=352x288:rate=24" -frames:v "$2" -c:v libx264 -profile:v main -pix_fmt yuv420p \
    -x264-params "$3" -bsf:v h264_mp4toannexb -f h264 -y "$1"
}

REQ_P="P_SKIP,P16x16,P16x8,P8x16,P8x8,ERR_REF,psub0,psub1,psub2,psub3,intra_nb,c_to_d"
REQ_BS="B16x16,B16x8,B8x16,B8x8,B8x8DS,BDIR16S,SP_EDGE,skip,direct8x8,bsub0,sp_col_zero,inference"
REQ_BT="B16x16,B16x8,B8x16,B8x8DT,BDIR16T,ERR_MAP,TD_FRM2FLD,TD_FLD2FRM,TD_RAW,direct8x8,td_one_to_one,td_intra_col"
REQ_SCALES="td_one_to_one,td_frm_to_fld,td_fld_to_frm,td_f2f_neg_odd"

echo "== GREEN: x264 clips (refs-free) =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  X=cabac=1:8x8dct=0:partitions=all:me=umh:subme=7:keyint=100:scenecut=0
  x264 .sim/mvp_p.264 8 "$X:bframes=0:ref=4:slices=4" \
  && x264 .sim/mvp_bs.264 12 "$X:bframes=2:b-adapt=0:b-pyramid=0:ref=3:direct=spatial" \
  && x264 .sim/mvp_bt.264 13 "$X:bframes=3:b-adapt=0:b-pyramid=normal:ref=3:direct=temporal" \
  && X264=1 || { echo "  FAIL x264 encode"; fail=1; }
  if [ $X264 = 1 ]; then
    fixture p  "$REQ_P"  --x264 .sim/mvp_p.264  & fixture bs "$REQ_BS" --x264 .sim/mvp_bs.264 &
    fixture bt "$REQ_BT" --x264 .sim/mvp_bt.264 & wait
    for n in p bs bt; do [ -f "$GEN/mvp_$n.meta.hex" ] && grep -q '^  coverage' ".sim/mvp_fx_$n.log" && ! grep -q 'missing' ".sim/mvp_fx_$n.log" || { fx_fail $n "x264 $n"; X264=0; }; done
  fi
  if [ $X264 = 1 ]; then
    report "x264 P (4 refs, every partition, 4 slices)" p;  show_cov p
    report "x264 B spatial direct"            bs; show_cov bs
    report "x264 B temporal direct (pyramid)" bt; show_cov bt
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance streams (\$H264_REFS_DIR) =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
CONF=0
if [ -f "$AVC/CAPA1_TOSHIBA_B.zip" ] && [ -f "$AVC/cabac_mot_picaff0_full.zip" ] && [ -f "$AVC/cabac_mot_fld0_full.zip" ] \
   && [ -f "$AVC/Sharp_MP_PAFF_2r.zip" ] && [ -f "$AVC/CAFI1_SVA_C.zip" ]; then
  CONF=1
  d=$(mktemp -d)
  for z in CAPA1_TOSHIBA_B cabac_mot_picaff0_full cabac_mot_fld0_full Sharp_MP_PAFF_2r CAFI1_SVA_C; do
    unzip -o -q "$AVC/$z.zip" -d "$d/$z"
  done
  s() { find "$d/$1" -type f \( -name '*.264' -o -name '*.26l' -o -name '*.jvt' \) | head -1; }
  fixture capa1  "field,$REQ_SCALES,$(echo bsub{0..12} | tr ' ' ',')" --x264 "$(s CAPA1_TOSHIBA_B)" &
  fixture picaff "field,$REQ_SCALES,B8x8DT,BDIR16T"                     --x264 "$(s cabac_mot_picaff0_full)" &
  fixture fld0   "field,td_one_to_one,B8x8DT,BDIR16T"                   --x264 "$(s cabac_mot_fld0_full)" &
  fixture sharp  "field,sp_one_to_one,sp_frm_to_fld,sp_fld_to_frm,B8x8DS,BDIR16S" --x264 "$(s Sharp_MP_PAFF_2r)" &
  fixture cafi1  "field,sp_one_to_one,sp_col_zero,BDIR16S"              --x264 "$(s CAFI1_SVA_C)" &
  wait
  rm -rf "$d"
  for n in capa1 picaff fld0 sharp cafi1; do
    [ -f "$GEN/mvp_$n.meta.hex" ] && grep -q '^  coverage' ".sim/mvp_fx_$n.log" && ! grep -q 'missing' ".sim/mvp_fx_$n.log" || { fx_fail $n "$n"; CONF=0; }
  done
  report "CAPA1_TOSHIBA_B (PAFF, temporal, 3 scales)"       capa1;  show_cov capa1
  report "camp_mot_picaff0_full (PAFF, temporal, 3 scales)" picaff; show_cov picaff
  report "camp_mot_fld0_full (fields, temporal)"            fld0;   show_cov fld0
  report "Sharp_MP_PAFF_2r (PAFF, spatial, 3 structures)"   sharp;  show_cov sharp
  report "CAFI1_SVA_C (fields, spatial)"                    cafi1;  show_cov cafi1
else
  echo "  SKIP: the conformance packages are not in $AVC (set H264_REFS_DIR)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own class) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixtures"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name old new fixture stall class-regex
    local name=$1 old=$2 new=$3 stem="$GEN/mvp_$4" st=$5 want=$6
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/mv_pred.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/mv_pred.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 600 vvp -n "$d/sim" "+stem=$stem" "+stall=$st" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: mv_pred_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "$want" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "$want" "$d/log" | cut -c1-90) [$4]" > "$RES/$name"
    else
      { echo "  $name: failed but NOT by /$want/:"; grep -m3 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  cls() { echo "^FAIL \[mv\] class ($1):"; }
  mut M1 "        wire signed [15:0] medx = (q_abx != q_acx) ? axx : (q_abx == q_bcx) ? bx2 : cx2;\n        wire signed [15:0] medy = (q_aby != q_acy) ? axy : (q_aby == q_bcy) ? by2 : cy2;" \
         "        wire signed [15:0] medx = (axx + bx2 + cx2) / 3;\n        wire signed [15:0] medy = (axy + by2 + cy2) / 3;" p 0 "$(cls P16x16)" &
  mut M2 "wire dirB = c_dirB && eqB0;" "wire dirB = 1'b0;" p 0 "$(cls P16x8)" &
  mut M3 "wire [4:0] selC = lkav[2] ? lksel[2] : lksel[3];\n    wire       avC  = lkav[2] ? 1'b1 : lkav[3];" \
         "wire [4:0] selC = lksel[2];\n    wire       avC  = lkav[2];" p 0 "$(cls P8x8)" &
  mut M4 "? dec_done[lki_c[g]] : 1'b0;" "? 1'b1 : 1'b0;" p 0 "$(cls P8x8)" &
  mut M5 "(rA0 == 6'sd0 && gA[31:0] == 32'd0)" "(gA[31:0] == 32'd0)" p 0 "$(cls P_SKIP)" &
  mut M6 "wire signed [5:0] mpabc = (!rA[5] && !mpbc[5]) ? ((rA < mpbc) ? rA : mpbc) : ((rA > mpbc) ? rA : mpbc);" \
         "wire signed [5:0] mpabc = (rA < mpbc) ? rA : mpbc;" bs 0 "$(cls BDIR16S)" &
  wait
  mut M7 "wire ce_x_small = (ce_mvx[15:1] == 15'd0) || (ce_mvx == 16'hFFFF);\n    wire ce_y_small = (ce_mvy[15:1] == 15'd0) || (ce_mvy == 16'hFFFF);" \
         "wire ce_x_small = (\$signed(ce_mvx) >= -2) && (\$signed(ce_mvx) <= 2);\n    wire ce_y_small = (\$signed(ce_mvy) >= -2) && (\$signed(ce_mvy) <= 2);" bs 0 "$(cls SP_EDGE)" &
  mut M8 "wire  [3:0]  col_idx = direct_8x8_inf ? {col_blk[3:2], col_blk[3:2]} : col_blk;" "wire  [3:0]  col_idx = col_blk;" bt 0 "$(cls BDIR16T)" &
  mut M9 "wire  signed [26:0] t2_sx = t2_px + 27'sd128;\n    wire  signed [26:0] t2_sy = t2_py + 27'sd128;" \
         "wire  signed [26:0] t2_sx = t2_px;\n    wire  signed [26:0] t2_sy = t2_py;" bt 0 "$(cls BDIR16T)" &
  mut M10 "2'd1:    td_mvy_s = (ce_mvy_s + ce_mvy_neg) >>> 1;" "2'd1:    td_mvy_s = ce_mvy_s >>> 1;" bt 0 "$(cls TD_FRM2FLD)" &
  mut M11 "wire [9:0]  nb_av = nb_avail;" "wire [9:0]  nb_av = nb_avail & ~nb_intra;" p 0 "$(cls P_SKIP)" &
  mut M12 "wire subst = !gAvB && !gAvC && gAvA;" "wire subst = 1'b0;" p 0 "$(cls P16x16)" &
  wait
  mut M13 "wire  signed [15:0] td_mv1x = t2_raw ? 16'sd0 : td_mv0x - t2_mvx;" "wire  signed [15:0] td_mv1x = t2_raw ? 16'sd0 : t2_mvx - td_mv0x;" bt 0 "$(cls BDIR16T)" &
  mut M14 "if ((cpred[0] && ref_bad[0]) || (cpred[1] && ref_bad[1])) err <= 1'b1;" "if (1'b0) err <= 1'b1;" p 0 "^FAIL \[err\] class ERR_REF:" &
  mut M16 "tb_raw <= tdir_raw[td_ref0];" "tb_raw <= 1'b0;" bt 0 "$(cls TD_RAW)" &
  mut M17 "                S_GATHER: begin" "                S_GATHER: if (start) state <= S_FIN; else begin" p 3 "$(cls P16x16)" &
  mut M18 "wire dirC = c_dirC && eqC0;" "wire dirC = 1'b0;" p 0 "$(cls P8x16)" &
  mut M20 "if (wr_mask[b]) pfb[b] <= wr_ent;" "if (wr_mask[b]) pfb[b] <= b[3:0];" p 0 "$(cls P16x16)" &
  mut M22 "cpred_q <= cpred; part_mask_q <= part_mask;" "cpred_q <= 2'b01; part_mask_q <= part_mask;" bs 0 "$(cls 'B16x16|B16x8|B8x16|B8x8')" &
  mut M21 "ref_in_q[l] <= (mp_abc[0][5] && mp_abc[1][5]) ? 6'sd0 : {1'b0, mp_abc[l][4:0]};" "ref_in_q[l] <= ref_in[l];" bs 0 "$(cls BDIR16S)" &
  # (perf/retime) the entry mux's select without dec_done: C inside the macroblock never replaced by D there
  mut M23 "wire  [4:0]  selC_nb = (lkk[2] == 2'd2) ? lksel[3] : selC;" "wire  [4:0]  selC_nb = (lkk[2] == 2'd2) ? lksel[2] : selC;" p 0 "$(cls 'P8x8|P8x16|P16x8')" &
  # M24 removes the retimed external-neighbour availability capture; C/D selection must notice it.
  mut M24 "? nb_av[lki_c[g]] : (lkk_c[g] == 2'd2)" "? 1'b0 : (lkk_c[g] == 2'd2)" p 0 "$(cls 'P8x8|P8x16|P16x8')" &
  # M25 removes the internal availability capture; PREP2 -> gather stability is the key proof.
  mut M25 "? dec_done[lki_c[g]] : 1'b0;" "? 1'b0 : 1'b0;" p 0 "$(cls 'P8x8|P8x16|P16x8')" &
  if [ $CONF = 1 ]; then
    mut M10r "2'd1:    td_mvy_s = (ce_mvy_s + ce_mvy_neg) >>> 1;" "2'd1:    td_mvy_s = ce_mvy_s >>> 1;" picaff 0 "$(cls 'BDIR16T|B8x8DT')" &
    mut M15 "wire  [4:0]  td_ref0 = (ta_intra || !mc_ok) ? 5'd0 : map_q[4:0];" "wire  [4:0]  td_ref0 = (ta_intra || !mc_ok) ? 5'd0 : 5'd0;" picaff 0 "$(cls 'BDIR16T|B8x8DT')" &
    mut M19 "2'd2:    td_mvy_s = {ce_mvy[14:0], 1'b0};" "2'd2:    td_mvy_s = ce_mvy;" picaff 0 "$(cls 'BDIR16T|B8x8DT')" &
  else
    for m in M10r M15 M19; do echo "  $m: SKIP (the conformance fixtures need \$H264_REFS_DIR)" > "$RES/$m"; done
  fi
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
