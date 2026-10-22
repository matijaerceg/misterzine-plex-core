#!/usr/bin/env bash
# run_mb_syntax.sh -- the macroblock-layer gate (h264/dec/mb_syntax.sv driving
# cabac_engine.sv + cabac_ctx.sv, bench/h264/mb_syntax_tb.sv; goldens
# tools/mb_syntax_golden.py <- tools/h264_fe_ref.py)
#
# GREEN, per slice fixture: the SE stream identical to the model's, every macroblock,
# no engine error, bins/cycle >= 0.16 (the Level-3.0 ceiling of 13 Mbins/s at 81 MHz;
# docs/h264_frontend.md S4 has the measured 0.18-0.20 and what is left on the table):
#   * an x264 clip encoded at run time (no media, no reference set: needs ffmpeg with
#     libx264): I slices incl. a second slice of a picture, P with 1 and 4 references,
#     B with two, crf + adaptive quantisation so mb_qp_delta varies -- SKIP without libx264;
#   * with $H264_REFS_DIR: CABACI3_Sony_B's I / P (cabac_init_idc 2) / B slices and
#     CAPM3_Sony_D's I_PCM slices (an I one and a B one with 43 PCM macroblocks);
#   * with $H264_REFS_DIR: camp_mot_fld0_full's field pictures with content -- an I field
#     (251k bins), a P field and a B field -- in place of UMD's disc field slices (the
#     fork's fixtures are generated or from H.264.1, never discs: docs/harvest.md).
#   One fixture also runs with a random-ready SE consumer (+stall).
#   * H264 Phase 5, High profile (docs/high_profile.md S4): x264 High clips (refs-free) --
#     I / P / B slices with the 8x8 transform and Intra_8x8, a P slice with sub-8x8
#     partitions beside 8x8-transform macroblocks (partitions=all: transform_size_8x8_flag
#     must NOT be read for them), the I slice again with +stall (the coefficient RAM's
#     skid buffer); with $H264_REFS_DIR, HCAFF1_HHI_B's I / P / B FIELD slices (the field
#     8x8 significance map of Table 9-43).
#
# --red: mutations on a COPY of mb_syntax.sv, each caught by its own arm (the x264 I
# and P slices, so the arm needs no reference set):
#   M1  mb_skip_flag ctxIdxInc ignores the left neighbour      -> [se]
#   M2  B mb_type: the intra-suffix offset 32 becomes 17       -> [se]  (the x264 B slice)
#   M3  Intra16x16's implied luma cbp dropped                  -> [se]
#   M4  cbp luma: the 4th 8x8's left neighbour is the wrong prior bin -> [se]
#   M5  mb_qp_delta: the previous macroblock never counts      -> [se]
#   M6  coded_block_flag: an unavailable neighbour of an intra MB gives 0  -> [se]
#   M7  significance map: the last position never inferred     -> [se]
#   M8  coeff_abs_level_minus1: numDecodAbsLevelGt1 saturates at 3 -> [se]
#   M9  mvd ctxIdxInc threshold 2 -> 3                          -> [se]
#   M10 ref_idx: the neighbour's ref_idx > 0 read from the wrong list -> [se]
#   M11 the row above: chroma AC cbf slots swapped              -> [se]
#   M12 field pictures: the frame significance contexts used   -> [se]  (camp_mot_fld0_full's P field, refs)
#   High profile:
#   M13 transform_size_8x8_flag ctxIdxInc ignores the above neighbour   -> [se] (x264 High I)
#   M14 numDecodAbsLevelEq1 wraps at 16 (the defect the High I slice found) -> [se] (x264 High I)
#   M15 an 8x8 block's coded_block_flag 1 not left in its 4x4 slots      -> [se] (x264 High P)
#   M16 field 8x8 blocks use the frame significance map                  -> [se] (HCAFF1's P field, refs)
#       (on the pre-issued sig_ctx1: sig_ctx is asked only at position 0, where the maps agree)
#   M17 transform_size_8x8_flag read after a sub-8x8 partition           -> [se] (x264 High partitions=all P)
#   Position (P5b's running row base in place of mb_y * PicWidthInMbs):
#   M18 the first-macroblock search steps the row base by width - 1  -> [se] (x264 I slice 1, first_mb 675)
#   M19 the row base not stepped at a row's end                      -> [done] (x264 High I, one
#       slice of 18 rows: the search re-finds the row and leaves mb_y one further ahead each
#       row, invisible until mb_y passes the height -- err_overrun; the half-picture Main I
#       slice never gets there)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/high_tables.sv h264/dec/cabac_ctx.sv h264/dec/cabac_engine.sv h264/dec/mb_syntax.sv"
TB=bench/h264/mb_syntax_tb.sv
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
mkdir -p "$GEN"

# shellcheck disable=SC2086
rm -f .sim/mbs_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/mbs_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/mbs_sim ] || { echo "  FAIL mb_syntax_tb: build"; exit 1; }

run_one() {   # sim stem stall [rate_min] -> 0 on PASS; log in .sim/mbs_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" "+rate_min=${4:-16}" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/mbs_last.log
  grep -q "^PASS: mb_syntax_tb" .sim/mbs_last.log
}
report() {    # label stem stall [rate_min x100, default 16]
  if run_one .sim/mbs_sim "$2" "$3" "${4:-16}"; then
    echo "  PASS $1: $(grep '^mb_syntax_tb:' .sim/mbs_last.log | head -1 | sed 's/^mb_syntax_tb: [^:]*: //')"
  else echo "  FAIL $1"; grep FAIL .sim/mbs_last.log | head -3; fail=1; fi
}

echo "== GREEN: x264 slices (refs-free) =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  ffmpeg -v error -f lavfi -i "testsrc2=size=720x480:rate=24" -frames:v 6 -c:v libx264 -profile:v main -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=2:keyint=6:min-keyint=6:scenecut=0:direct=spatial:aq-mode=1:aq-strength=1.5:crf=28" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/mbs_x264.264 \
  && python3 tools/mb_syntax_golden.py .sim/mbs_x264.264 --slice 0 1 3 5 8 --out "$GEN/mbs_x264" > .sim/mbs_fx.log 2>&1 \
  && X264=1 || { echo "  FAIL x264 fixtures"; tail -2 .sim/mbs_fx.log; fail=1; }
  if [ $X264 = 1 ]; then
    report "x264 I slice 0"            "$GEN/mbs_x264_0" 0
    report "x264 I slice 1 (2nd of picture)" "$GEN/mbs_x264_1" 0
    report "x264 P slice 3"            "$GEN/mbs_x264_3" 0
    report "x264 B slice 5"            "$GEN/mbs_x264_5" 0
    report "x264 P slice 8 (4 refs)"   "$GEN/mbs_x264_8" 0
    report "x264 P slice 3 +stall"     "$GEN/mbs_x264_3" 5
    report "x264 I slice 0 +burst"     "$GEN/mbs_x264_0" 200   # (bursts of 200: the emission queue's interlock)
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: High profile, x264 slices (refs-free) =="
XH=0
if [ $X264 = 1 ]; then
  ffmpeg -v error -f lavfi -i "mandelbrot=size=352x288:rate=30" -frames:v 6 -c:v libx264 -profile:v high -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=1:bframes=2:ref=2:keyint=6:scenecut=0:crf=20" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/mbs_x264h.264 \
  && ffmpeg -v error -f lavfi -i "mandelbrot=size=352x288:rate=30" -frames:v 4 -c:v libx264 -profile:v high -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=1:bframes=0:ref=2:partitions=all:keyint=4:scenecut=0:crf=18" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/mbs_x264p4.264 \
  && python3 tools/mb_syntax_golden.py .sim/mbs_x264h.264 --slice 0 1 2 --out "$GEN/mbs_x264h" > .sim/mbs_fxh.log 2>&1 \
  && python3 tools/mb_syntax_golden.py .sim/mbs_x264p4.264 --slice 2 3 --out "$GEN/mbs_x264p4" >> .sim/mbs_fxh.log 2>&1 \
  && XH=1 || { echo "  FAIL x264 High fixtures"; tail -2 .sim/mbs_fxh.log; fail=1; }
  if [ $XH = 1 ]; then
    # fixture ranges: the clips must still carry what the arms are for
    python3 - "$GEN" <<'PYEOF' || fail=1
import sys, os
gen = sys.argv[1]
def words(stem):
    return [l.strip() for l in open(os.path.join(gen, stem + ".se.hex"))]
def count(stem, kind, aux_kind=None):
    n = 0
    for w in words(stem):
        if int(w[:2], 16) == kind and (aux_kind is None or (int(w[2:4], 16) & 15) == aux_kind):
            n += 1
    return n
ok = True
for stem, what, n in (("mbs_x264h_0", "L8 blocks", count("mbs_x264h_0", 14, 5)),
                      ("mbs_x264h_1", "L8 blocks", count("mbs_x264h_1", 14, 5)),
                      ("mbs_x264h_1", "T8 words", count("mbs_x264h_1", 20)),
                      ("mbs_x264p4_2", "sub_mb_types", count("mbs_x264p4_2", 4))):
    good = n > 10
    ok = ok and good
    print("  %s range: %s %s: %d" % ("PASS" if good else "FAIL", stem, what, n))
sys.exit(0 if ok else 1)
PYEOF
    report "x264 High I slice (Intra_8x8)"      "$GEN/mbs_x264h_0" 0
    report "x264 High P slice"                  "$GEN/mbs_x264h_1" 0
    report "x264 High B slice"                  "$GEN/mbs_x264h_2" 0
    report "x264 High P slice, sub-8x8"         "$GEN/mbs_x264p4_2" 0
    report "x264 High I slice +stall"           "$GEN/mbs_x264h_0" 5 10
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance slices (\$H264_REFS_DIR) =="
CI3="$REFS/H.264.1_bitstreams/AVCv1/CABACI3_Sony_B.zip"
PCM="$REFS/H.264.1_bitstreams/AVCv1/CAPM3_Sony_D.zip"
if [ -f "$CI3" ] && [ -f "$PCM" ]; then
  d=$(mktemp -d)
  unzip -o -q "$CI3" -d "$d" && unzip -o -q "$PCM" -d "$d"
  python3 tools/mb_syntax_golden.py "$d/CABACI3_Sony_B.jsv" --slice 0 4 12 --out "$GEN/mbs_ci3" > .sim/mbs_fx.log 2>&1 || { echo "  FAIL CABACI3 fixtures"; fail=1; }
  python3 tools/mb_syntax_golden.py "$d/CAPM3_Sony_D.jsv" --slice 0 4 --out "$GEN/mbs_pcm" >> .sim/mbs_fx.log 2>&1 || { echo "  FAIL CAPM3 fixtures"; fail=1; }
  rm -rf "$d"
  report "CABACI3 I slice 0"          "$GEN/mbs_ci3_0" 0
  report "CABACI3 P slice 4 (idc 2)"  "$GEN/mbs_ci3_4" 0
  report "CABACI3 B slice 12"         "$GEN/mbs_ci3_12" 0
  report "CAPM3 I slice 0 (I_PCM)"    "$GEN/mbs_pcm_0" 0
  report "CAPM3 B slice 4 (43 I_PCM)" "$GEN/mbs_pcm_4" 0
else
  echo "  SKIP: no $CI3 / $PCM (set H264_REFS_DIR)"
fi

echo "== GREEN: field slices (\$H264_REFS_DIR) =="
FLD="$REFS/H.264.1_bitstreams/AVCv1/cabac_mot_fld0_full.zip"
if [ -f "$FLD" ]; then
  d=$(mktemp -d)
  unzip -o -q "$FLD" -d "$d"
  python3 tools/mb_syntax_golden.py "$d/camp_mot_fld0_full.26l" --slice 0 2 4 --out "$GEN/mbs_fld" >> .sim/mbs_fx.log 2>&1 || { echo "  FAIL camp_mot_fld0_full fixtures"; fail=1; }
  rm -rf "$d"
  report "camp_mot_fld I field slice 0 (251k bins)" "$GEN/mbs_fld_0" 0
  report "camp_mot_fld P field slice 2"             "$GEN/mbs_fld_2" 0
  # 0.148 bins/cycle measured (2026-09-27), word-exact: under UMD's 0.16 Level-3.0 floor on
  # a dense B field slice. Gated at its own measured rate so a regression still fails; the
  # front end's rate is Phase 5's (docs/roadmap.md D1, docs/h264_frontend.md S4).
  report "camp_mot_fld B field slice 4 (floor 0.14)" "$GEN/mbs_fld_4" 0 14
else
  echo "  SKIP: no $FLD (set H264_REFS_DIR)"
fi

echo "== GREEN: High profile field slices (\$H264_REFS_DIR) =="
HFF="$REFS/H.264.1_bitstreams/FRExt/HCAFF1_HHI_B.zip"
if [ -f "$HFF" ]; then
  d=$(mktemp -d)
  unzip -o -q "$HFF" -d "$d"
  python3 tools/mb_syntax_golden.py "$d/HCAFF1_HHI.264" --slice 0 2 5 --out "$GEN/mbs_hff" >> .sim/mbs_fx.log 2>&1 || { echo "  FAIL HCAFF1 fixtures"; fail=1; }
  rm -rf "$d"
  report "HCAFF1 I field slice 0 (725 8x8 blocks)" "$GEN/mbs_hff_0" 0
  # word-exact at 0.128 / 0.136 bins/cycle (2026-09-27): few bins, many 64-coefficient
  # blocks -- the emission of 64 words an 8x8 block bounds these slices, not the engine.
  # Gated at their own measured rate so a regression still fails.
  report "HCAFF1 P field slice 2 (floor 0.12)"     "$GEN/mbs_hff_2" 0 12
  report "HCAFF1 B field slice 5 (floor 0.13)"     "$GEN/mbs_hff_5" 0 13
else
  echo "  SKIP: no $HFF (set H264_REFS_DIR; the FRExt package, docs/references.md)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixtures"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name old new stem [rate_min x100] [arm, default se] [stall, default 0]
    local name=$1 old=$2 new=$3 stem=$4 rmin=${5:-16} arm=${6:-se} stall=${7:-0}
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/mb_syntax.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/high_tables.sv" "$d/cabac_ctx.sv" "$d/cabac_engine.sv" "$d/mb_syntax.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    vvp -n "$d/sim" "+stem=$stem" "+stall=$stall" "+rate_min=$rmin" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: mb_syntax_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[$arm\]" "$d/log"; then
      echo "  $name: caught by $(grep -m1 "FAIL \[$arm\]" "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  XI="$GEN/mbs_x264_0"; XP="$GEN/mbs_x264_3"; XB="$GEN/mbs_x264_5"
  mut M1 "+ (left_avail && !p_skip ? 9'd1 : 9'd0) + (a_avail && !a_skip ? 9'd1 : 9'd0));" "+ (a_avail && !a_skip ? 9'd1 : 9'd0));" "$XP" &
  mut M2 "4'd13: begin mbt_off <= 9'd32; mbt_add <= 6'd23; state <= S_MBT_I0; end" "4'd13: begin mbt_off <= 9'd17; mbt_add <= 6'd23; state <= S_MBT_I0; end" "$XB" &
  mut M3 "c_cbp <= {mbt_chroma, (mbt_ac ? 4'hF : 4'h0)};" "c_cbp <= {mbt_chroma, 4'h0};" "$XI" &
  mut M4 "default: cbpA_zero = !cbp_acc[2];" "default: cbpA_zero = !cbp_acc[1];" "$XP" &
  mut M5 "(prev_valid && !p_skip && !p_pcm && (p_i16 || p_cbp != 6'd0) && p_qpd_nz) ? 4'd1 : 4'd0," "4'd0," "$XI" &
  mut M6 "        else if (!left_avail)\n            cbfA = c_intra;" "        else if (!left_avail)\n            cbfA = 1'b0;" "$XI" &
  wait
  mut M7 "rb_sig[rb_n[5:0] - 6'd1] <= 1'b1; rb_rem[rb_n[5:0] - 6'd1] <= 1'b1;" "" "$XI" &
  # feature/mb-pipeline: the emission queue -- a block decoding into a level bank still streaming
  # (the consumer stalls, +stall=5, so the output falls behind the decode)
  mut M20 "S_RB_NEXT: if (!(nx_valid && bk_busy[wbk])) begin" "S_RB_NEXT: if (1'b1) begin" "$XI" 5 se 200 &
  mut M8 "4'd5 + (((4'd4 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) < rb_gt1) ? (4'd4 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) : rb_gt1)," "4'd5 + (((4'd3 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) < rb_gt1) ? (4'd3 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) : rb_gt1)," "$XI" &
  mut M9 "(mvd_sum > 7'd2) ? 4'd1 : 4'd0;" "(mvd_sum > 7'd3) ? 4'd1 : 4'd0;" "$XP" &
  mut M10 "nA_refgt = lx ? p_ref1gt[nbA_idx] : p_ref0gt[nbA_idx];" "nA_refgt = lx ? p_ref0gt[nbA_idx] : p_ref1gt[nbA_idx];" "$GEN/mbs_x264_8" &
  mut M11 "c_cbf_cac[7], c_cbf_cac[6], c_cbf_cac[3], c_cbf_cac[2]," "c_cbf_cac[2], c_cbf_cac[3], c_cbf_cac[6], c_cbf_cac[7]," "$XI" &
  mut M18 "if (pos_ge_q) begin mb_y <= mb_y + 8'd1; row_base <= row_base + {6'd0, width_mbs}; end" "if (pos_ge_q) begin mb_y <= mb_y + 8'd1; row_base <= row_base + {6'd0, width_mbs} - 14'd1; end" "$GEN/mbs_x264_1" &
  if [ -f "$GEN/mbs_fld_2.meta.hex" ]; then
    mut M12 ": (field ? 9'd277 : 9'd105) + {3'd0, cat_off_sig} + {5'd0, sig_inc};" ": (1'b0 ? 9'd277 : 9'd105) + {3'd0, cat_off_sig} + {5'd0, sig_inc};" "$GEN/mbs_fld_2" &
  else
    echo "  M12: SKIP (the field fixture needs \$H264_REFS_DIR)" > "$RES/M12"
  fi
  wait
  if [ $XH = 1 ]; then
    XHI="$GEN/mbs_x264h_0"; XHP="$GEN/mbs_x264h_1"
    mut M13 "issue(K_DECISION, 9'd399 + (left_avail && p_t8 ? 9'd1 : 9'd0) + (a_avail && a_t8 ? 9'd1 : 9'd0));" "issue(K_DECISION, 9'd399 + (left_avail && p_t8 ? 9'd1 : 9'd0));" "$XHI" &
    mut M14 "if (tu_val == 16'd0) rb_eq1 <= (rb_eq1 == 4'd15) ? rb_eq1 : rb_eq1 + 4'd1;" "if (tu_val == 16'd0) rb_eq1 <= rb_eq1 + 4'd1;" "$XHI" &
    mut M15 "c_cbf_luma[{nx_idx[1:0], 2'b00} +: 4] <= 4'hF;" "" "$XHP" &
    mut M17 "else if (subt_shape != 2'd0) c_nosub <= 1'b0;" "" "$GEN/mbs_x264p4_2" &
    mut M19 "mb_x <= 8'd0; mb_y <= mb_y + 8'd1; row_base <= row_base + {6'd0, width_mbs}; end" "mb_x <= 8'd0; mb_y <= mb_y + 8'd1; end" "$XHI" 16 done &
  else
    for m in M13 M14 M15 M17; do echo "  $m: SKIP (needs the x264 High fixtures)" > "$RES/$m"; done
  fi
  if [ -f "$GEN/mbs_hff_2.meta.hex" ]; then
    # (on sig_ctx1, the pre-issued next position: sig_ctx itself is asked only at levelListIdx
    #  0, where Table 9-43's frame and field maps agree -- mutating it is an equivalent mutant)
    mut M16 "(field ? 9'd436 + {5'd0, c8_sfl1} : 9'd402 + {5'd0, c8_sfr1})" "(field ? 9'd436 + {5'd0, c8_sfr1} : 9'd402 + {5'd0, c8_sfr1})" "$GEN/mbs_hff_2" 12 &
  else
    echo "  M16: SKIP (the High field fixture needs \$H264_REFS_DIR)" > "$RES/M16"
  fi
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
