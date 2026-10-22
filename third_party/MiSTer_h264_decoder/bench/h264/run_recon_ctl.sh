#!/usr/bin/env bash
# run_recon_ctl.sh -- the reconstruction's control path: h264/dec/recon_hdr.sv (parameter
# store, slice-header capture), recon_dpb.sv (POC, marking, stores) and recon_lists.sv
# (reference lists) on real SE streams (bench/h264/recon_ctl_tb.sv), scored per slice
# against tools/h264_recon_ref.py --dump by tools/recon_ctl_check.py. docs/h264_recon.md S2.
#
# GREEN, per stream: every slice's picture (store, structure, POC, reference flag),
# every list entry (the picture, its POC, its marking), and the DPB after every
# picture's marking identical to the model (which is pixel-exact vs ffmpeg and the
# H.264.1 YUVs); no error pulse:
#   * x264 at run time (SKIP without libx264): I/P/B with 3 references, pyramid B
#     (non-reference B referenced), 4 slices per picture, a fade with weights and list
#     modification and an MMCO;
#   * with $H264_REFS_DIR: CABREF3_Sand_D (fields, long-term references, MMCOs),
#     CAPAMA3_Sand_F is MBAFF (refused upstream, not used), CAFI1_SVA_C (fields),
#     Sharp_MP_PAFF_2r (POC type 1, frame/field adaptive), CAMP_MOT_FRM/FLD... the
#     field and adaptive packages the P3 sweep measured (cabac_mot_fld0_full,
#     cabac_mot_picaff0_full), CAPA1_TOSHIBA_B (PAFF), MR1_BT_A... -- the list below;
#   (UMD's Akira / Family Guy disc windows are not carried: the fork's fixtures are generated
#   or from H.264.1, docs/harvest.md; their RED targets moved to conformance streams below.)
#
# --red: mutations on a COPY of the RTL, each caught by its own stream:
#   D1  recon_dpb: POC type 0 PicOrderCntMsb never wraps          -> CAPA1_TOSHIBA_B (5-bit lsb, wraps 9 times)
#   D2  recon_dpb: the sliding window drops the newest            -> x264 main
#   D3  recon_dpb: a second field never pairs with the first      -> cabac_mot_fld0_full
#   D5  recon_dpb: an IDR does not clear the DPB                  -> x264 main (two IDRs)
#   D6  recon_dpb: POC type 1 without the offset_for_ref_frame sum -> Sharp_MP_PAFF_2r
#   D7  recon_dpb: FrameNumOffset never steps at a frame_num wrap -> CAWP5_TOSHIBA_E (POC type 2,
#       4-bit frame_num, wraps 5 times; the register fn_wrap, clk_dec 103.85 retime. Sharp's
#       POC type 1 never wraps: it could not see this)
#   D8  recon_dpb: the POC type 1 divider fed absFrameNum, not absFrameNum - 1 -> Sharp_MP_PAFF_2r
#       (D_POC1_RD3, the state split at the clk_dec 103.85 retime)
#   L2  recon_lists: field lists do not alternate parity          -> cabac_mot_fld0_full
#   L3  recon_lists: P frame lists by POC, not FrameNumWrap       -> CAPA1_TOSHIBA_B
#   L4  recon_lists: the registered field parity never alternates -> cabac_mot_fld0_full (the
#       register f_par, clk_dec 103.85 retime)
# NOT COVERABLE with the streams available (measured 2026-09-24 by probing every
# fixture): an MMCO in a FIELD picture, long-term references, a B slice whose initial
# RefPicList1 equals RefPicList0 (the swap of 8.2.4.2.3), a list modification that
# removes a later duplicate (8-37's compaction). No H.264.1 CABAC stream and no disc
# uses them, and x264 emits none of them (it has no PAFF). The fix is fixtures encoded
# with the JM reference encoder (lencod, in $H264_REFS_DIR/JM), which can emit all four
# -- docs/h264_recon.md S5 "Open".
# Also not coverable (probed 2026-09-28 over every fixture above plus an x264 16-reference
# B stream): the sliding window's victim in the LAST store (19). P5b moved the window
# scan's resolve one step later (D_MARK_WIN_SCAN's candidate stage); a mutant resolving
# at the old step drops only store 19's candidacy, and no stream put the oldest short-term
# frame there. Kept correct by construction and by the scan's comment, not by an arm.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/h264_pkg.sv h264/dec/recon_hdr.sv h264/dec/recon_dpb.sv h264/dec/recon_lists.sv"
TB=bench/h264/recon_ctl_tb.sv
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
mkdir -p "$GEN"
: > .sim/rctl_fx.log

# shellcheck disable=SC2086
rm -f .sim/rctl_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/rctl_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/rctl_sim ] || { echo "  FAIL recon_ctl_tb: build"; exit 1; }

STEMS=()           # name|stem|dumpdir, for the RED arm
fixture() {        # name stream-file [extra golden args...] -> 0 when the fixture exists
  local name=$1 src=$2; shift 2
  local stem="$GEN/rctl_$name" dump=".sim/rctl_${name}_dump"
  rm -rf "$dump"
  python3 tools/h264_top_golden.py "$src" "$@" --out "$stem" >> .sim/rctl_fx.log 2>&1 \
    && grep -E '^(11|12|01)' "$stem.se.hex" > "$stem.ctl.hex" \
    && python3 tools/h264_recon_ref.py "$src" --dump "$dump" >> .sim/rctl_fx.log 2>&1
}
score() {          # sim name -> 0 on PASS; log in .sim/rctl_<name>.log
  local sim=$1 name=$2
  local stem="$GEN/rctl_$name" dump=".sim/rctl_${name}_dump" log=".sim/rctl_${name}.log"
  timeout 1800 vvp -n "$sim" "+stem=$stem" "+n_ctl=$(grep -c . "$stem.ctl.hex")" > "$log" 2>&1
  grep -q "^PASS: recon_ctl_tb" "$log" || { grep -m2 "FAIL\|ERR" "$log"; return 1; }
  if grep -q "^ERR " "$log"; then grep -m1 "^ERR " "$log"; return 1; fi
  python3 tools/recon_ctl_check.py "$dump" "$log"
}
report() {         # label name
  local out
  if out=$(score .sim/rctl_sim "$2"); then echo "  PASS $1: ${out#recon_ctl_check: }"; STEMS+=("$2")
  else echo "  FAIL $1"; echo "$out" | sed 's/^/    /' | head -4; fail=1; fi
}
x264() {           # out size frames extra-params [filter]
  local f="testsrc2=size=$2:rate=24"; [ -n "${5:-}" ] && f="$f,$5"
  ffmpeg -v error -f lavfi -i "$f" -frames:v "$3" -c:v libx264 -pix_fmt yuv420p -x264-params "$4" \
    -bsf:v h264_mp4toannexb -f h264 -y "$1"
}

echo "== GREEN: x264 streams (refs-free) =="
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 .sim/rctl_main.264 320x240 24 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:keyint=12:min-keyint=12:scenecut=0:crf=28" \
  && x264 .sim/rctl_pyr.264 320x240 24 "cabac=1:8x8dct=0:bframes=3:b-pyramid=normal:ref=4:keyint=24:scenecut=0:crf=28:slices=4" \
  && x264 .sim/rctl_fade.264 320x240 12 "cabac=1:8x8dct=0:bframes=2:ref=2:weightp=2:keyint=12:min-keyint=12:scenecut=0:crf=26" "fade=t=out:st=0:d=0.5" \
  || { echo "  FAIL x264 encode"; fail=1; }
  fixture main .sim/rctl_main.264 && report "x264 I/P/B, 3 refs, two IDRs" main || { echo "  FAIL main fixture"; fail=1; }
  fixture pyr .sim/rctl_pyr.264 && report "x264 pyramid B, 4 refs, 4 slices/picture" pyr || { echo "  FAIL pyr fixture"; fail=1; }
  fixture fade .sim/rctl_fade.264 && report "x264 fade: weights, list modification, MMCO" fade || { echo "  FAIL fade fixture"; fail=1; }
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance streams (\$H264_REFS_DIR) =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
conf() {           # label zip name-in-zip-glob
  if [ -f "$AVC/$2.zip" ]; then
    local d; d=$(mktemp -d)
    unzip -o -q "$AVC/$2.zip" -d "$d"
    local f; f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" | head -1)
    if [ -n "$f" ] && fixture "$2" "$f"; then report "$1" "$2"; else echo "  FAIL $1: fixture"; tail -2 .sim/rctl_fx.log; fail=1; fi
    rm -rf "$d"
  else echo "  SKIP $1: no $AVC/$2.zip"; fi
}
if [ -d "$AVC" ]; then
  conf "CABREF3_Sand_D (fields, long-term, MMCOs)" CABREF3_Sand_D
  conf "CAFI1_SVA_C (fields)" CAFI1_SVA_C
  conf "Sharp_MP_PAFF_2r (POC type 1, PAFF)" Sharp_MP_PAFF_2r
  conf "CAPA1_TOSHIBA_B (PAFF)" CAPA1_TOSHIBA_B
  conf "cabac_mot_fld0_full (fields)" cabac_mot_fld0_full
  conf "cabac_mot_picaff0_full (picture AFF)" cabac_mot_picaff0_full
  conf "CAWP5_TOSHIBA_E (list modification)" CAWP5_TOSHIBA_E
  conf "CABACI3_Sony_B (4 slices/picture)" CABACI3_Sony_B
  conf "MR1_BT_A... CANL4_SVA_B (B, spatial direct)" CANL4_SVA_B
else
  echo "  SKIP: no $AVC (set H264_REFS_DIR)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own stream) =="
  RES=$(mktemp -d)
  mut() {   # name file old new stream-name
    local name=$1 file=$2 old=$3 new=$4 target=$5
    if [ ! -f "$GEN/rctl_$target.meta.hex" ]; then echo "  $name: SKIP (no $target fixture)" > "$RES/$name"; return; fi
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?          # the anchor edit's status (a later loop would mask it)
    local files=""; for f in $RTL; do files="$files $d/$(basename "$f")"; done
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! iverilog -g2012 -o "$d/sim" $files $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local stem="$GEN/rctl_$target" dump=".sim/rctl_${target}_dump"
    timeout 1800 vvp -n "$d/sim" "+stem=$stem" "+n_ctl=$(grep -c . "$stem.ctl.hex")" > "$d/log" 2>&1
    if grep -q "^PASS: recon_ctl_tb" "$d/log" && ! grep -q "^ERR " "$d/log" && python3 tools/recon_ctl_check.py "$dump" "$d/log" > "$d/chk" 2>&1; then
      { echo "  $name: SURVIVED on $target -- the gate cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    else
      echo "  $name: caught on $target: $( (grep -m1 "FAIL\|^ERR" "$d/log"; cat "$d/chk" 2>/dev/null) | grep -m1 . | cut -c1-110)" > "$RES/$name"
    fi
    rm -rf "$d"
  }
  D=h264/dec/recon_dpb.sv; L=h264/dec/recon_lists.sv
  mut D1 $D "if (p0_cu) p0_pm <= p0_up;" \
         "if (1'b0) p0_pm <= p0_up;" CAPA1_TOSHIBA_B &
  mut D2 $D "if (wz_v && (!win_found || wz_fnw < win_best)) begin win_found <= 1'b1;" \
            "if (wz_v && (!win_found || wz_fnw > win_best)) begin win_found <= 1'b1;" main &
  mut D3 $D "pairing = prev_was_field && sh_field_pic && (prev_bottom != sh_bottom_field) && (prev_fn_pic == sh_frame_num)" \
            "pairing = 1'b0 && prev_was_field && sh_field_pic && (prev_bottom != sh_bottom_field) && (prev_fn_pic == sh_frame_num)" cabac_mot_fld0_full &
  mut D5 $D "for (int i = 0; i < NSTORE; i++) if (i[4:0] != cur_store) begin ref_t[i] <= UNUSED; ref_b[i] <= UNUSED; end\n                    if (cur_ltref) begin" \
            "if (cur_ltref) begin" main &
  mut D6 $D "if (abs_fn > 32'sd0) e = poc1_prod + poc1_data;" "if (abs_fn > 32'sd0) e = poc1_prod;" Sharp_MP_PAFF_2r &
  mut D8 $D "div_num <= (abs_fn > 32'sd0) ? abs_fn - 32'sd1 : 32'sd0;" "div_num <= (abs_fn > 32'sd0) ? abs_fn : 32'sd0;" Sharp_MP_PAFF_2r &
  mut D7 $D 'fn_wrap <= ($signed({16'"'"'d0, prev_fn}) > $signed({16'"'"'d0, sh_frame_num}));' 'fn_wrap <= 1'"'"'b0;' CAWP5_TOSHIBA_E &
  wait
  mut L2 $L "if (!fdone[!fq]) begin fq <= !fq; fp <= fi_ptr[!fq]; end\n                        else fp <= fp + 1'b1;" \
            "fp <= fp + 1'b1;" cabac_mot_fld0_full &
  mut L3 $L "phase <= (slice_type == 2'd0) ? 2'd0 : 2'd1;" "phase <= 2'd1;" CAPA1_TOSHIBA_B &
  mut L4 $L "always_ff @(posedge clk) f_par <= fq ? !same_par : same_par;" "always_ff @(posedge clk) f_par <= same_par;" cabac_mot_fld0_full &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
