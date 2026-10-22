#!/usr/bin/env bash
# run_h264_top.sh -- the front-end chain gate (h264/dec/h264_top.sv: nal_parser,
# rbsp_reader, sps_pps, slice_hdr, cabac_engine + cabac_ctx, mb_syntax;
# bench/h264/h264_top_tb.sv; goldens tools/h264_top_golden.py <- tools/h264_fe_ref.py)
#
# GREEN, per Annex-B fixture: the SE stream (NAL words, every SPS / PPS / slice-header
# field, every macroblock SE and coefficient) identical to the model's, the counters
# and the bin total equal, no error, idle at the end (docs/h264_frontend.md S5):
#   * h264/dec/h264_fields.svh equals tools/h264_fields.py;
#   * x264 clips encoded at run time (no media, no reference set; SKIP without libx264):
#     Main 720x480 I/P/B with 2 slices per picture (+ a run with input gaps and a
#     slow SE consumer); a 320x240 fade with weighted P (luma AND chroma weights),
#     list modification and an MMCO; and the refusal arm -- CAVLC (code 5), MBAFF (4),
#     monochrome (1: legal High, refused -- docs/spec_hardening.md) and a 2080-pixel-wide
#     picture (12: the fabric's own limit), each refused
#     at the model's field with the records up to it identical; a lossless 64x64 noise
#     clip whose every macroblock x264 codes as I_PCM, with 00 00 01 sample triples so
#     the samples carry emulation-prevention bytes (258: the only refs-free way to put
#     EPBs in decoded data, asserted by the runner) -- since Phase 5 rewritten from High
#     4:4:4 Predictive to plain High by tools/h264_synth.py unlossless (the transform
#     bypass is refused; with every macroblock I_PCM nothing changes); and the no-hang arm --
#     the Main clip truncated inside a slice header and inside slice data (one error
#     counted, the chain back to idle, the whole NAL units before the cut identical);
#   * H264 Phase 5, High profile (docs/high_profile.md): x264 High 320x240 (the 8x8
#     transform, Intra_8x8, the High SPS fields and the PPS tail), the JVT default matrices
#     (a PPS with every list absent: fall-back rule A to Default_*), custom lists (the
#     "previous list" chains of lists 2, 4, 5); with $H264_REFS_DIR, FRExt3_Panasonic_E
#     (an SPS with all eight lists; PPS 0 re-sent with every mix: rule B to the SPS lists,
#     previous-list chains, useDefaultScalingMatrixFlag, no matrix) and HPCALQ_BRCM_B (an
#     SPS whose lists are all absent: rule A inside the SPS, then rule B).
#   * with $H264_REFS_DIR: CABACI3_Sony_B (4 slices per picture, cabac_init_idc 0/1/2),
#     CAWP5_TOSHIBA_E (weighted P, 901 list-modification ops), Sharp_MP_PAFF_2r (POC
#     type 1, field pictures), CAPM3_Sony_D (I_PCM), CAFI1_SVA_C (fields, spatial
#     direct) -- each cut to its first NAL units (--nals) to keep the run minutes long;
#     camp_mot_fld0_full (field pictures with content, weighted prediction), in place of
#     UMD's disc clips (the fork's fixtures are generated or from H.264.1: docs/harvest.md).
#
# --red: mutations on a COPY of the RTL, each caught by its own arm on an x264 fixture:
#   N1  nal_parser: emulation-prevention bytes kept                -> [se]  (the I_PCM fixture: a normal x264 clip's EPBs
#                                                                            all sit in its VUI / SEI, which are not decoded)
#   N2  nal_parser: a NAL unit's last byte never flagged           -> [hang] (the drain waits for an end that never comes)
#   R1  rbsp_reader: ue(v) suffix off by one                        -> [se]
#   R2  rbsp_reader: se(v) sign inverted                            -> [se]
#   R3  rbsp_reader: more_rbsp_data ignores the stop-bit rule       -> [se]
#   R4  rbsp_reader: the alignment run fetches a byte it will not consume -> [se]  (the engine loses the slice's first byte)
#   P1  sps_pps: weighted_pred_flag stored inverted                 -> [se]  (the fade fixture)
#   P2  sps_pps: the High-profile SPS branch skipped                -> [se]  (the 8x8 fixture)
#   S1  slice_hdr: idr_pic_id read for non-IDR slices too           -> [se]
#   S2  slice_hdr: slice_qp_delta ignored (SliceQPY = pic_init_qp)  -> [se]
#   S3  slice_hdr: I slices initialise the contexts with set 0      -> [se]
#   S4  slice_hdr: the chroma weight pair read once                 -> [se]  (the fade fixture)
#   S5  slice_hdr: the marking syntax skipped for non-IDR references -> [se]  (the fade fixture)
#   S7  slice_hdr: field_pic_flag never read                        -> [se]  (camp_mot_fld0_full, needs $H264_REFS_DIR)
#   (a "cabac_alignment_one_bit run skipped" mutation is an equivalent mutant: the bits it
#   would consume are the held byte's alignment ones, which no consumer needs -- dropped)
#   V1  sps_pps: a u(32)'s upper half dropped (time_scale)       -> [se]  (the maximal VUI)
#   V2  sps_pps: Extended_SAR's sar_height never read            -> [se]  (the x264 VUI clip)
#   V3  sps_pps: the CPB loop one short                          -> [se]  (the maximal VUI)
#   V4  sps_pps: max_dec_frame_buffering's bound dropped         -> [count] (err_mdfb: the SPS is stored)
#   V5  sps_pps: the NAL / VCL length comparison dropped         -> [count] (err_len: the SPS is stored)
#   V6  sps_pps: the VCL hrd_parameters() never parsed           -> [se]  (the maximal VUI)
#   P5c (the picture timing SEI, the PTS, end of stream):
#   E1  sei_pt: pic_struct read as 3 bits                       -> [se]  (ps_all)
#   E2  sei_pt: payloadSize's 0xFF runs not accumulated         -> [se]  (sei_edge: the 300-byte message)
#   E3  sei_pt: Table D-1's field check dropped for pic_struct 1 -> [p5c] (ps_all: 1 on a frame)
#   E4  sei_pt: the up-front length check dropped               -> [se]  (sei_short: fields from a 1-byte payload)
#   E5  sei_pt: cpb_removal_delay one bit short                 -> [se]  (ps_all)
#   A1  au_pts: a stamp AT the start code not taken (strict <)  -> [se]  (ptsedge)
#   A2  au_pts: the EARLIEST stamp kept, not the latest         -> [se]  (ptsedge)
#   A3  h264_top: openers ignored (access units start at slices) -> [se] (ptsedge)
#   A4  nal_parser: the start code's position one byte late      -> [se]  (ptsedge)
#   Z1  h264_top: no end-of-stream word                          -> [hang] (the bench waits for the last word)
#   T1  h264_top: the engine not FLUSHed before a picture's later slice
#   T3  h264_top: the engine not FLUSHed before a picture's first slice (the P5c path)   -> [se]             -> [se]
#   T2  h264_top: refusals counted as errors                        -> [refuse] (the CAVLC fixture)
#   M1  mb_syntax: the unbounded-unary cap removed                  -> [hang] (the truncated-slice fixture)
#   High profile:
#   H1  sps_pps: nextScale without the + delta (the lists wrong)    -> [se]  (the custom-lists fixture)
#   H2  sps_pps: the SPS's fall-back rule A to Flat, not Default     -> [se]  (HPCALQ_BRCM_B, refs)
#   H2b sps_pps: the PPS's fall-back rule A to Flat, not Default     -> [se]  (the JVT fixture)
#   H3  sps_pps: a "previous list" fall-back takes Flat              -> [se]  (FRExt3_Panasonic_E, refs)
#   H4  sps_pps: rule B never taken (A instead)                      -> [se]  (FRExt3_Panasonic_E, refs)
#   H5  sps_pps: useDefaultScalingMatrixFlag ignored                 -> [se]  (FRExt3_Panasonic_E, refs)
#   H6  h264_top: transform_8x8_mode_flag not passed to mb_syntax    -> [se]  (the x264 High fixture)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/h264_pkg.sv h264/dec/high_tables.sv h264/dec/nal_parser.sv h264/dec/rbsp_reader.sv h264/dec/sps_pps.sv h264/dec/slice_hdr.sv h264/dec/cabac_ctx.sv h264/dec/cabac_engine.sv h264/dec/mb_syntax.sv h264/dec/au_pts.sv h264/dec/sei_pt.sv h264/dec/h264_top.sv"
TB=bench/h264/h264_top_tb.sv
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
mkdir -p "$GEN"

echo "== GREEN: the field-id table =="
python3 tools/h264_fields.py --check | sed 's/^/  /' || fail=1

# shellcheck disable=SC2086
rm -f .sim/h264top_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/h264top_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/h264top_sim ] || { echo "  FAIL h264_top_tb: build"; exit 1; }

run_one() {   # sim stem stall -> 0 on PASS; log in .sim/h264top_last.log
  timeout 3600 vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/h264top_last.log
  grep -q "^PASS: h264_top_tb" .sim/h264top_last.log
}
report() {    # label stem stall
  if run_one .sim/h264top_sim "$2" "$3"; then
    echo "  PASS $1: $(grep '^h264_top_tb:' .sim/h264top_last.log | head -1 | sed 's/^h264_top_tb: [^:]*: //')"
  else echo "  FAIL $1"; grep FAIL .sim/h264top_last.log | head -3; fail=1; fi
}
x264() {      # out size frames extra-params [filter]
  local f="testsrc2=size=$2:rate=24"; [ -n "${5:-}" ] && f="$f,$5"
  ffmpeg -v error -f lavfi -i "$f" -frames:v "$3" -c:v libx264 -pix_fmt yuv420p -x264-params "$4" \
    -bsf:v h264_mp4toannexb -f h264 -y "$1"
}

echo "== GREEN: x264 streams (refs-free) =="
X264=0
: > .sim/h264top_fx.log            # every golden below APPENDS (the runner greps their summary lines)
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 .sim/h264top_main.264 720x480 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=2:keyint=6:min-keyint=6:scenecut=0:direct=spatial:aq-mode=1:aq-strength=1.5:crf=28" \
  && x264 .sim/h264top_fade.264 320x240 6 "cabac=1:8x8dct=0:bframes=2:ref=2:weightp=2:keyint=6:min-keyint=6:scenecut=0:crf=26" "fade=t=out:st=0:d=0.3" \
  && x264 .sim/h264top_cavlc.264 320x240 2 "cabac=0" \
  && x264 .sim/h264top_mbaff.264 320x240 2 "cabac=1:8x8dct=0:interlaced=1" \
  && x264 .sim/h264top_8x8.264 320x240 4 "cabac=1:8x8dct=1:bframes=1" \
  && x264 .sim/h264top_jvt.264 320x240 3 "cabac=1:8x8dct=1:cqm=jvt:bframes=1" \
  && x264 .sim/h264top_cqm.264 320x240 3 "cabac=1:8x8dct=1:bframes=1:cqm4iy=$(python3 -c "print(','.join(str(6+(i*13)%50) for i in range(16)))"):cqm4py=$(python3 -c "print(','.join(str(12+(i*5)%36) for i in range(16)))"):cqm8i=$(python3 -c "print(','.join(str(4+(i*11)%60) for i in range(64)))"):cqm8p=$(python3 -c "print(','.join(str(10+(i*9)%45) for i in range(64)))")" \
  && ffmpeg -v error -f lavfi -i "testsrc2=size=64x64:rate=24" -frames:v 2 -c:v libx264 -profile:v high -pix_fmt gray \
       -x264-params "cabac=1" -bsf:v h264_mp4toannexb -f h264 -y .sim/h264top_gray.264 \
  && python3 tools/h264_top_golden.py .sim/h264top_jvt.264 --out "$GEN/h264top_jvt" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_cqm.264 --out "$GEN/h264top_cqm" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_gray.264 --out "$GEN/h264top_gray" >> .sim/h264top_fx.log 2>&1 \
  && x264 .sim/h264top_wide.264 2080x64 1 "cabac=1:8x8dct=0" \
  && ffmpeg -v error -f lavfi -i "nullsrc=size=64x64:rate=24,geq=lum='if(lt(mod(X,16),2),0,if(eq(mod(X,16),2),1,random(1)*255))':cb='random(1)*255':cr='random(1)*255'" \
       -frames:v 1 -c:v libx264 -profile:v main -pix_fmt yuv420p -x264-params "cabac=1:8x8dct=0:qp=0" -bsf:v h264_mp4toannexb -f h264 -y .sim/h264top_pcm_ll.264 \
  && python3 tools/h264_synth.py .sim/h264top_pcm_ll.264 unlossless .sim/h264top_pcm.264 >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_pcm.264 --out "$GEN/h264top_pcm" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_main.264 --out "$GEN/h264top_main" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_fade.264 --out "$GEN/h264top_fade" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_cavlc.264 --out "$GEN/h264top_cavlc" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_mbaff.264 --out "$GEN/h264top_mbaff" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_8x8.264 --out "$GEN/h264top_8x8" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_wide.264 --fabric --out "$GEN/h264top_wide" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_main.264 --truncate "$(python3 -c "
import sys; sys.path.insert(0, 'tools'); import h264_top_golden as G
d = open('.sim/h264top_main.264', 'rb').read(); sc = G.start_codes(d)
print(sc[3] + 8)")" --out "$GEN/h264top_trunc_hdr" >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_main.264 --truncate 9000 --out "$GEN/h264top_trunc_data" >> .sim/h264top_fx.log 2>&1 \
  && x264 .sim/h264top_vui.264 64x64 3 "cabac=1:8x8dct=0:nal-hrd=vbr:vbv-maxrate=2000:vbv-bufsize=2000:pic-struct=1" "setsar=7/5" \
  && python3 tools/h264_top_golden.py .sim/h264top_vui.264 --out "$GEN/h264top_vui" >> .sim/h264top_fx.log 2>&1 \
  && x264 .sim/h264top_vbase.264 64x64 3 "cabac=1:8x8dct=0:bframes=0" \
  && python3 tools/h264_synth.py .sim/h264top_vbase.264 max .sim/h264top_vmax.264 >> .sim/h264top_fx.log 2>&1 \
  && python3 tools/h264_top_golden.py .sim/h264top_vmax.264 --out "$GEN/h264top_vmax" >> .sim/h264top_fx.log 2>&1 \
  && for k in err_cpb err_mdfb err_nrf err_tick err_len; do
       python3 tools/h264_synth.py .sim/h264top_vbase.264 $k .sim/h264top_v$k.264 >> .sim/h264top_fx.log 2>&1 \
       && python3 tools/h264_top_golden.py .sim/h264top_v$k.264 --nals 1 --expect-error --out "$GEN/h264top_v$k" >> .sim/h264top_fx.log 2>&1 || exit 1
     done \
  && X264=1 || { echo "  FAIL x264 fixtures"; tail -3 .sim/h264top_fx.log; fail=1; }
  if [ $X264 = 1 ]; then
    # the fade must exercise what its arm claims (a fixture range check, not a hope)
    python3 tools/h264_fe_ref.py .sim/h264top_fade.264 -o .sim/h264top_fade.rec
    for f in "luma_weight_l0" "chroma_weight_l0" "modification_of_pic_nums_idc_l0" "memory_management_control_operation 1"; do
      grep -q "^S $f" .sim/h264top_fade.rec || { echo "  FAIL fade fixture lacks $f"; fail=1; }
    done
    report "x264 Main 720x480, 2 slices/picture, I/P/B"  "$GEN/h264top_main" 0
    report "x264 Main +stall (input gaps, slow consumer)" "$GEN/h264top_main" 3
    report "x264 fade: weights, list modification, MMCO"  "$GEN/h264top_fade" 0
    report "x264 CAVLC -> refused 5"                       "$GEN/h264top_cavlc" 0
    report "x264 MBAFF -> refused 4"                       "$GEN/h264top_mbaff" 0
    report "x264 High 320x240: the 8x8 transform, Intra_8x8"  "$GEN/h264top_8x8" 0
    # the High fixtures must carry what their arms claim
    python3 tools/h264_fe_ref.py .sim/h264top_8x8.264 -o .sim/h264top_8x8.rec
    grep -q "^B L8 " .sim/h264top_8x8.rec && grep -q "^E prev_intra8x8_pred_mode_flag" .sim/h264top_8x8.rec \
      || { echo "  FAIL the High fixture has no 8x8 block / Intra_8x8"; fail=1; }
    python3 tools/h264_fe_ref.py .sim/h264top_cqm.264 -o .sim/h264top_cqm.rec
    grep -q "^S pic_scaling_list_present_flag\[i\] 0" .sim/h264top_cqm.rec && grep -q "^S delta_scale" .sim/h264top_cqm.rec \
      || { echo "  FAIL the custom-lists fixture has no absent (fall-back) list or no coded one"; fail=1; }
    report "x264 High, JVT default matrices (rule A)"      "$GEN/h264top_jvt" 0
    report "x264 High, custom lists (previous-list chains)" "$GEN/h264top_cqm" 0
    report "x264 High 4:0:0 (monochrome) -> refused 1"     "$GEN/h264top_gray" 0
    report "x264 2080 wide -> refused 12 (fabric)"         "$GEN/h264top_wide" 0
    python3 tools/h264_fe_ref.py .sim/h264top_pcm.264 -o .sim/h264top_pcm.rec
    grep -q "^B PCM" .sim/h264top_pcm.rec || { echo "  FAIL the noise clip has no I_PCM macroblock"; fail=1; }
    grep -q "h264top_pcm: .* [1-9][0-9]* EPBs" .sim/h264top_fx.log || { echo "  FAIL the noise clip carries no emulation-prevention bytes (the N1 arm needs them)"; fail=1; }
    report "x264 lossless noise: 16 I_PCM macroblocks, 258 EPBs" "$GEN/h264top_pcm" 0
    grep -q "h264top_trunc_hdr: .*errors 1, .*(partial)" .sim/h264top_fx.log || { echo "  FAIL the header truncation did not land inside a slice header"; fail=1; }
    grep -q "h264top_trunc_data: .*errors 1, .*(partial)" .sim/h264top_fx.log || { echo "  FAIL the data truncation did not land inside slice data"; fail=1; }
    report "x264 Main truncated in a slice header -> 1 error, idle" "$GEN/h264top_trunc_hdr" 0
    report "x264 Main truncated in slice data -> 1 error, idle"     "$GEN/h264top_trunc_data" 0
    # P5b: the VUI (E.1.1 / E.1.2). The fixtures must carry what their arms claim.
    python3 tools/h264_fe_ref.py .sim/h264top_vui.264 -o .sim/h264top_vui.rec
    for f in "aspect_ratio_idc 255" "sar_height 5" "nal_hrd_parameters_present_flag 1" "pic_struct_present_flag 1"; do
      grep -q "^S $f" .sim/h264top_vui.rec || { echo "  FAIL the x264 VUI clip lacks $f"; fail=1; }
    done
    python3 tools/h264_fe_ref.py .sim/h264top_vmax.264 -o .sim/h264top_vmax.rec
    [ "$(grep -c '^S cpb_cnt_minus1 31' .sim/h264top_vmax.rec)" = 2 ] && grep -q "^S time_scale 4294967295" .sim/h264top_vmax.rec \
      || { echo "  FAIL the maximal VUI fixture is not maximal"; fail=1; }
    report "x264 VUI: Extended_SAR 7:5, NAL HRD, pic_struct"        "$GEN/h264top_vui" 0
    report "synthetic VUI at the spec maxima (2 x 32 CPBs, u(32) 2^32-1)" "$GEN/h264top_vmax" 0
    for k in err_cpb err_mdfb err_nrf err_tick err_len; do
      grep -q "h264top_v$k: .*errors 1, .*(partial)" .sim/h264top_fx.log || { echo "  FAIL the $k fixture is not a range error"; fail=1; }
      report "synthetic VUI $k -> 1 error (ERR_RANGE), idle" "$GEN/h264top_v$k" 0
    done
    # P5c: the picture timing SEI (D.1.3) and the PTS association, on an x264 stream with
    # pic_struct and a NAL HRD, rewritten by tools/h264_synth.py (docs/display.md)
    x264 .sim/h264top_ptbase.264 64x64 12 "cabac=1:8x8dct=0:nal-hrd=vbr:vbv-maxrate=2000:vbv-bufsize=2000:pic-struct=1:bframes=2" \
      && python3 tools/h264_top_golden.py .sim/h264top_ptbase.264 --synth-marks --out "$GEN/h264top_ptsedge" >> .sim/h264top_fx.log 2>&1 \
      || { echo "  FAIL P5c base fixture"; fail=1; }
    grep -q "h264top_ptsedge: .*PTS tagged 12, dropped [1-9]" .sim/h264top_fx.log || { echo "  FAIL the PTS edges fixture tags every picture and supersedes some stamps"; fail=1; }
    report "P5c PTS: marks at -1/0/+1/+2 around every start code (bit 32 set on some)" "$GEN/h264top_ptsedge" 0
    report "P5c PTS edges +stall" "$GEN/h264top_ptsedge" 3
    for k in ps_all sei_edge sei_short sei_malformed sei_missing sps_after_sei; do
      python3 tools/h264_synth.py .sim/h264top_ptbase.264 $k .sim/h264top_pt_$k.264 >> .sim/h264top_fx.log 2>&1 \
        && python3 tools/h264_top_golden.py .sim/h264top_pt_$k.264 --out "$GEN/h264top_pt_$k" >> .sim/h264top_fx.log 2>&1 \
        || { echo "  FAIL P5c fixture $k"; fail=1; continue; }
      report "P5c SEI $k" "$GEN/h264top_pt_$k" 0
    done
    # each fixture carries what its arm claims (the model's counters, read from the golden's log)
    for want in "h264top_pt_ps_all: .*pic_timing 12, missing 0, bad 4" "h264top_pt_sei_short: .*bad 1," \
                "h264top_pt_sei_malformed: .*missing 1, bad 0, malformed SEI 1" "h264top_pt_sei_missing: .*missing 1," \
                "h264top_pt_sei_edge: .*pic_timing 12, missing 0, bad 0, malformed SEI 0"; do
      grep -q "$want" .sim/h264top_fx.log || { echo "  FAIL fixture range: no '$want'"; fail=1; }
    done
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance streams (\$H264_REFS_DIR) =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
conf() {      # label zip stream nals
  if [ -f "$AVC/$2" ]; then
    local d; d=$(mktemp -d)
    unzip -o -q "$AVC/$2" -d "$d" "$3" 2>/dev/null || unzip -o -q "$AVC/$2" -d "$d"
    local f; f=$(find "$d" -name "$3" | head -1)
    local stem="$GEN/h264top_$(basename "$2" .zip)"
    if [ -n "$f" ] && python3 tools/h264_top_golden.py "$f" --nals "$4" --out "$stem" >> .sim/h264top_fx.log 2>&1; then
      report "$1" "$stem" 0
    else echo "  FAIL $1: fixture"; tail -2 .sim/h264top_fx.log; fail=1; fi
    rm -rf "$d"
  else echo "  SKIP $1: no $AVC/$2"; fi
}
if [ -d "$AVC" ]; then
  conf "CABACI3_Sony_B (4 slices/picture, idc 0/1/2), 30 NAL units" CABACI3_Sony_B.zip CABACI3_Sony_B.jsv 30
  conf "CAWP5_TOSHIBA_E (weighted P, l0 modification), 12 NAL units" CAWP5_TOSHIBA_E.zip CAWP5_TOSHIBA_E.264 12
  conf "Sharp_MP_PAFF_2r (POC type 1, fields), 14 NAL units"        Sharp_MP_PAFF_2r.zip Sharp_MP_PAFF_2.jvt 14
  conf "CAPM3_Sony_D (I_PCM), 8 NAL units"                            CAPM3_Sony_D.zip CAPM3_Sony_D.jsv 8
  conf "CAFI1_SVA_C (fields, spatial direct), 14 NAL units"           CAFI1_SVA_C.zip CAFI1_SVA_C.264 14
  conf "camp_mot_fld0_full (fields with content, weighted), 12 NAL units" cabac_mot_fld0_full.zip camp_mot_fld0_full.26l 12
else
  echo "  SKIP: no $AVC (set H264_REFS_DIR)"
fi
echo "== GREEN: High-profile conformance streams (\$H264_REFS_DIR) =="
FRX="$REFS/H.264.1_bitstreams/FRExt"
if [ -d "$FRX" ]; then
  AVC="$FRX"
  conf "FRExt3_Panasonic_E (SPS lists; PPS re-sent: rule B, chains, useDefault), whole" FRExt3_Panasonic_E.zip FRExt3_Panasonic.avc 400
  conf "HPCALQ_BRCM_B (SPS / PPS matrices, every list absent), 8 NAL units" HPCALQ_BRCM_B.zip HPCALQ_BRCM_B.264 8
  AVC="$REFS/H.264.1_bitstreams/AVCv1"
else
  echo "  SKIP: no $FRX (set H264_REFS_DIR; the FRExt package, docs/references.md)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixtures"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name file old new stem arm
    local name=$1 file=$2 old=$3 new=$4 stem=$5 arm=$6
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
    local pyrc=$?          # the anchor edit's status (a later loop would mask it)
    local files=""; for f in $RTL; do files="$files $d/$(basename "$f")"; done
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! iverilog -g2012 -o "$d/sim" $files $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 1800 vvp -n "$d/sim" "+stem=$stem" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: h264_top_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[$arm\]" "$d/log"; then
      echo "  $name: caught by $(grep -m1 "FAIL \[$arm\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  XM="$GEN/h264top_main"; XF="$GEN/h264top_fade"
  mut N1 nal_parser.sv "wire is_epb   = (zeros >= 2'd2) && (in_byte == 8'h03);" "wire is_epb   = 1'b0;" "$GEN/h264top_pcm" se &
  mut N2 nal_parser.sv "out_valid <= 1'b1; out_byte <= held_b; out_first <= held_first; out_sc_pos <= held_sc; out_last <= 1'b1;\n                    end\n                    held_v <= 1'b0; zeros <= 2'd0; started <= 1'b1; first_pend <= 1'b1;" \
                       "out_valid <= 1'b1; out_byte <= held_b; out_first <= held_first; out_sc_pos <= held_sc; out_last <= 1'b0;\n                    end\n                    held_v <= 1'b0; zeros <= 2'd0; started <= 1'b1; first_pend <= 1'b1;" "$XM" hang &
  mut R1 rbsp_reader.sv "wire [31:0] ue_acc = ((32'd1 << lz) - 32'd1) + {acc[30:0], bit_val};" "wire [31:0] ue_acc = (32'd1 << lz) + {acc[30:0], bit_val};" "$XM" se &
  mut R2 rbsp_reader.sv "wire [31:0] se_of_k = ue_acc[0] ? ({1'b0, ue_acc[31:1]} + 32'd1) : (32'd0 - {1'b0, ue_acc[31:1]});" \
                        "wire [31:0] se_of_k = ue_acc[0] ? (32'd0 - ({1'b0, ue_acc[31:1]} + 32'd1)) : {1'b0, ue_acc[31:1]};" "$XM" se &
  mut R3 rbsp_reader.sv "wire       more_now = !cur_last || ((rem & rem_m1) != 8'd0);" "wire       more_now = !cur_last || (rem != 8'd0);" "$XM" se &
  mut R4 rbsp_reader.sv "((state == S_ALIGN) && !aligned);" "(state == S_ALIGN);" "$XM" se &
  mut P1 sps_pps.sv "S_PPS_WBI: begin p.weighted_pred <= f_val[0];" "S_PPS_WBI: begin p.weighted_pred <= !f_val[0];" "$XF" se &
  mut V1 sps_pps.sv "V_TS_CMB: begin f_val <= {v_hi, f_val[15:0]};" "V_TS_CMB: begin f_val <= {16'd0, f_val[15:0]};" "$GEN/h264top_vmax" se &
  mut V2 sps_pps.sv "V_SARH: begin s.sar_width <= f_val[15:0]; \`FIELD(K_BITS, 5'd16, F_sar_height, V_SAR_DONE) end" "V_SARH: begin s.sar_width <= f_val[15:0]; state <= V_SAR_DONE; end" "$GEN/h264top_vui" se &
  mut V3 sps_pps.sv "if (v_cpb_i == v_cpb_cnt)" "if (v_cpb_i + 5'd1 == v_cpb_cnt)" "$GEN/h264top_vmax" se &
  mut V4 sps_pps.sv "if (!(p_u5 && f_val[4:0] <= 5'd16) || v_nrf > f_val)" "if (v_nrf > f_val)" "$GEN/h264top_verr_mdfb" count &
  mut V5 sps_pps.sv "if (v_hrd_seen && ({v_init_len" "if (1'b0 && ({v_init_len" "$GEN/h264top_verr_len" count &
  mut V6 sps_pps.sv "                    state <= v_hrd_k ? V_HRD_END : V_VCLHRD;
                end" "                    state <= V_HRD_END;
                end" "$GEN/h264top_vmax" se &
  PE="$GEN/h264top_ptsedge"
  mut E1 sei_pt.sv "I_PS: if (pic_struct_present) \`RD(6'd4, F_pic_struct, I_PS_CHK)" "I_PS: if (pic_struct_present) \`RD(6'd3, F_pic_struct, I_PS_CHK)" "$GEN/h264top_pt_ps_all" se &
  mut E2 sei_pt.sv "                        psize <= psize + 32'd255;" "                        psize <= psize;" "$GEN/h264top_pt_sei_edge" se &
  mut E3 sei_pt.sv "4'd1:                               if (!field_pic || bottom_field) pt_struct <= 1'b1;" "4'd1:                               if (bottom_field) pt_struct <= 1'b1;" "$GEN/h264top_pt_ps_all" p5c &
  mut E4 sei_pt.sv "end else if ({29'd0, need} > have) begin" "end else if (1'b0) begin" "$GEN/h264top_pt_sei_short" se &
  mut E5 sei_pt.sv "I_CPB: if (cpb_dpb_present) \`RD({1'b0, cpb_len_m1} + 6'd1," "I_CPB: if (cpb_dpb_present) \`RD({1'b0, cpb_len_m1}," "$GEN/h264top_pt_ps_all" se &
  mut A1 au_pts.sv "wire          pop   = busy && (cnt != '0) && !gap[PW-1];" "wire          pop   = busy && (cnt != '0) && !gap[PW-1] && (gap != '0);" "$PE" se &
  mut A2 au_pts.sv "cand_v <= 1'b1; cand_pts <= e_pts[0];" "if (!cand_v) cand_pts <= e_pts[0]; cand_v <= 1'b1;" "$PE" se &
  mut A3 h264_top.sv "if (hdr_opener && vcl_last) begin" "if (1'b0) begin" "$PE" se &
  mut A4 nal_parser.sv "sc_pos <= in_pos - 2'd2;" "sc_pos <= in_pos - 2'd1;" "$PE" se &
  mut Z1 h264_top.sv "if (np_flushed) eos_pend <= 1'b1;" "if (1'b0) eos_pend <= 1'b1;" "$XM" hang &
  mut P2 sps_pps.sv "if (high_profile) \`FIELD(K_UE, 5'd0, F_chroma_format_idc, S_SPS_BDL)" "if (1'b0) \`FIELD(K_UE, 5'd0, F_chroma_format_idc, S_SPS_BDL)" "$GEN/h264top_8x8" se &
  mut S1 slice_hdr.sv "S_IDR: if (idr) \`FIELD(K_UE, 5'd0, F_idr_pic_id, S_IDR_CHK)" "S_IDR: if (1'b1) \`FIELD(K_UE, 5'd0, F_idr_pic_id, S_IDR_CHK)" "$XM" se &
  wait
  mut S2 slice_hdr.sv "wire signed [31:0] qp_sum = 32'sd26 + {{26{p.pic_init_qp_minus26[5]}}, p.pic_init_qp_minus26} + f_sval;" \
                      "wire signed [31:0] qp_sum = 32'sd26 + {{26{p.pic_init_qp_minus26[5]}}, p.pic_init_qp_minus26};" "$XM" se &
  mut S3 slice_hdr.sv "else begin sp_init_set <= 2'd3; state <= S_QPD; end" "else begin sp_init_set <= 2'd0; state <= S_QPD; end" "$XM" se &
  mut S4 slice_hdr.sv "else if (!ci) begin ci <= 1'b1; state <= S_WP_CW; end" "else if (1'b0) begin ci <= 1'b1; state <= S_WP_CW; end" "$XF" se &
  mut S5 slice_hdr.sv "else \`FIELD(K_BITS, 5'd1, F_adaptive_ref_pic_marking_mode_flag, S_MARK_ADAPT_BR)" "else state <= S_CABAC_INIT;" "$XF" se &
  mut M1 mb_syntax.sv "else if (tu_bin == 6'd63) begin err_bins <= 1'b1; state <= S_DONE; end" "else if (1'b0) begin err_bins <= 1'b1; state <= S_DONE; end" "$GEN/h264top_trunc_data" hang &
  if [ -f "$GEN/h264top_cabac_mot_fld0_full.meta.hex" ]; then
    mut S7 slice_hdr.sv "if (!s.frame_mbs_only) \`FIELD(K_BITS, 5'd1, F_field_pic_flag, S_BOTTOM)" "if (1'b0) \`FIELD(K_BITS, 5'd1, F_field_pic_flag, S_BOTTOM)" "$GEN/h264top_cabac_mot_fld0_full" se &
  else
    echo "  S7: SKIP (the field fixture needs \$H264_REFS_DIR)" > "$RES/S7"
  fi
  mut T1 h264_top.sv "end else begin\n                    top_req_valid <= 1'b1; top_req_kind <= K_FLUSH; state <= T_FLUSH;" "end else begin\n                    route_eng <= 1'b1; top_req_valid <= 1'b1; top_req_kind <= K_INIT; state <= T_INIT;" "$XM" se &
  mut T3 h264_top.sv "T_PT_END: begin top_req_valid <= 1'b1; top_req_kind <= K_FLUSH; state <= T_FLUSH; end" "T_PT_END: begin route_eng <= 1'b1; top_req_valid <= 1'b1; top_req_kind <= K_INIT; state <= T_INIT; end" "$XM" se &
  mut T2 h264_top.sv "if (ps_refused) begin refused_count <= refused_count + 32'd1; refused_code <= ps_code; end" "if (ps_refused) begin err_count <= err_count + 32'd1; err_code <= ps_code; end" "$GEN/h264top_cavlc" refuse &
  wait
  mut H1 sps_pps.sv "nx = sl_last + f_val[7:0];" "nx = sl_last;" "$GEN/h264top_cqm" se &
  mut H2b sps_pps.sv "else if (rs_first)         rs_fin = rs_s_on ? rs_ss : {SRC_DEF, rs_i[2:0]};" "else if (rs_first)         rs_fin = rs_s_on ? rs_ss : {SRC_FLAT, rs_i[2:0]};" "$GEN/h264top_jvt" se &
  mut H6 h264_top.sv ".sp_t8_mode(sp_p.transform_8x8_mode)" ".sp_t8_mode(1'b0)" "$GEN/h264top_8x8" se &
  if [ -f "$GEN/h264top_HPCALQ_BRCM_B.meta.hex" ]; then
    mut H2 sps_pps.sv "else if (rs_first)         rs_ss = {SRC_DEF, rs_i[2:0]};" "else if (rs_first)         rs_ss = {SRC_FLAT, rs_i[2:0]};" "$GEN/h264top_HPCALQ_BRCM_B" se &
  else
    echo "  H2: SKIP (HPCALQ_BRCM_B needs \$H264_REFS_DIR)" > "$RES/H2"
  fi
  if [ -f "$GEN/h264top_FRExt3_Panasonic_E.meta.hex" ]; then
    mut H3 sps_pps.sv "else                       rs_fin = rs_src_prev;" "else                       rs_fin = {SRC_FLAT, rs_i[2:0]};" "$GEN/h264top_FRExt3_Panasonic_E" se &
    mut H4 sps_pps.sv "else if (rs_first)         rs_fin = rs_s_on ? rs_ss : {SRC_DEF, rs_i[2:0]};" "else if (rs_first)         rs_fin = {SRC_DEF, rs_i[2:0]};" "$GEN/h264top_FRExt3_Panasonic_E" se &
    mut H5 sps_pps.sv "                    sl_fl[{sl_i[2:0], 1'b1}] <= 1'b1;" "" "$GEN/h264top_FRExt3_Panasonic_E" se &
  else
    for m in H3 H4 H5; do echo "  $m: SKIP (FRExt3_Panasonic_E needs \$H264_REFS_DIR)" > "$RES/$m"; done
  fi
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
