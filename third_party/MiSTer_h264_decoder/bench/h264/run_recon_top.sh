#!/usr/bin/env bash
# run_recon_top.sh -- the P4 reconstruction gate: h264/dec/recon_top.sv (the whole
# reconstruction, SE words in, pictures in the DPB out) through h264/dec/dpb_mem.sv on two
# real clocks against bench/h264/ddr_model.sv (bench/h264/recon_top_tb.sv), scored against
# tools/h264_recon_ref.py (pixel-exact vs ffmpeg and the H.264.1 YUVs) by
# tools/recon_top_golden.py. docs/h264_recon.md S5.
#
# Arms (bench/h264/recon_top_tb.sv): [pre] every macroblock's samples before deblocking,
# [post] every picture in the DDR model after deblocking, [count] pictures and
# macroblocks, [hang] a macroblock within 200,000 cycles of the previous one, [dropped] the
# status counter of stores C.4.4 drops (7 on c44n, 0 elsewhere; arm O13).
#
# GREEN:
#   x264 clips (ffmpeg + libx264; refs-free): intra; P with 2 refs; B spatial and temporal
#     direct (partitions=all); explicit weighted P over a fade; implicit weighted B; 3
#     slices a picture with deblocking offsets; P over a sub-pixel scroll with noise (mvq:
#     testsrc2 moves by whole pixels, so p4 never reaches the vertical half-sample filter);
#     16 reference frames at 64x48 (r16: Level 3.0's MaxDpbFrames for 12 macroblocks --
#     16 references + the current picture + the bench's held store need 18 of the 20).
#   H.264.1 conformance ($H264_REFS_DIR, SKIP without): field pictures, PAFF, weights with
#     list modification, long-term references and MMCOs -- the first pictures of each.
#   JM lencod streams ($H264_REFS_DIR, SKIP without the JM source): the control paths no x264
#     setting and no disc reaches -- field MMCOs (jfmmco), a long-term reference used in a
#     frame stream (jlt), low-delay B and the list-1 swap (jswap), list modification with
#     its duplicate removal (jmod). tools/jm_fixtures.py writes a fixture only when the
#     model is bit-exact vs ffmpeg on the stream AND the model's counters show the stream
#     reaches the case's own path; lencod is built on first use (tools/jm_build.sh --lencod).
#   (UMD's disc-window arm, Akira and Family Guy, is not carried: docs/harvest.md.
#   Long windows are the Verilator cosim's job, bench/h264/run_cosim.sh.)
#
# --red: mutations on a COPY of the RTL, each caught by its own arm on its own clip:
#   R1  mc_interp: the half-sample 6-tap's 20 as 16            (mvq)       -> [pre]
#   R2  deblock_bs: coded coefficients give bS 1, not 2         (sl)        -> [post]
#   (Measured 2026-09-24: on p4 both survive -- whole-pixel motion; and no bS-2 edge of
#   p4 / bsp / mvq filters differently from bS 1 or even bS 0: testsrc2's edges exceed
#   alpha. sl's deblocking offsets bring them in; even bS 2 -> 0 passes elsewhere.)
#   R3  recon_inter: explicit weights skipped (default pred)    (wp)        -> [pre]
#   R4  recon_inter: no opposite-parity chroma offset (T 8-10)  (fields)    -> [pre]
#   R5  recon_mb: the zig-zag scan in a field picture           (fields)    -> [pre]
#   R6  recon_inter: implicit weights' logWD 5 as 4             (wb)        -> [pre]
#   R7  recon_deblock: a vertical edge's p2 not written back     (i2)        -> [post]
#       (only the bS-4 strong filter changes p2: the intra clip)
#   R8  recon_deblock: a horizontal edge's rows written one sample rotated (p4) -> [post]
#   R9  h264_pkg: 16 DPB stores instead of 20                     (r16)       -> [pre] / [count]
#   T13 (perf/retime) recon_mb: the registered QP without mb_qp_delta (A_QP reads qp_new_q) (p4) -> [pre]
#   T14 (perf/retime) recon_inter: the setup's list-0 reference never latched (its reset value) (CAWP5_TOSHIBA_E)
#       -> [pre] (list 1's taken from list 0 survived every clip: both indices 0 there; recorded)
#   T15 (perf/retime) recon_mb: an uncoded Cb DC block's flags never cleared (p4)              -> [pre]
#       (Cb's clear from Cr's coded bit survived: a stale flag needs an uncoded AC block after it; recorded)
#       (picture 17 is the first with 16 references + itself live)
#   R10 recon_inter: the bi prefetch FIFO never advances         (bsp)       -> [pre]
#   R11 recon_inter: row buffers 8..15 aliased onto 0..7 (the lanes) (p4)       -> [pre]
#   R12 recon_mb: an all-zero residual block not marked zero        (p4)        -> [pre]
#   R13 recon_mb: the DDR arbiter grants a write inside a burst     (p4)        -> [pre] / [post] / [hang]
#   R14 recon_mb: the deblocker's writes lost while fb is still e_cur (i2)      -> [post]
#   R15 recon_mb: a DC value never marked nonzero (read as 0)       (i2)        -> [pre]
#   R16 recon_inter: the fetch fills a window bank still being interpolated (bspf: bsp against a
#       fast DDR -- with the two lanes the default latency never makes the fetch wait; since the
#       run-ahead the wait is the COPY's claim of a free bank) -> [pre] / [hang]
#       (since P5b's streaming start the overwrite also resets the bank's row count under the
#       running sweep, which then waits for rows that never come: a hang, not wrong pixels)
#   R17 recon_lists: the list-1 swap never taken                    (jswap)     -> [pre]
#   R18 recon_lists: a modification keeps the later duplicate      (jmod)      -> [pre]
#   R19 recon_dpb: a field MMCO 1 leaves the bottom field marked    (jfmmco)    -> [pre] / [post] / [count]
#   R20 recon_dpb: long_term_reference_flag ignored (the IDR short) (jlt)       -> [pre] / [count]
#
# High profile (Phase 5, docs/high_profile.md): x264 clips (refs-free) -- hi: intra,
#   Intra_8x8 in all nine modes, slices of 9 macroblocks (mid-row starts: an unavailable
#   p[-1,-1] with p[0,-1] and p[-1,0] available, the filter's 8-80 / 8-84 case); hpb: P / B
#   with the 8x8 transform (inter 8x8 residual, the deblocker's t8 edges); hci: constrained
#   intra, 3 slices, p8x8; hcq: custom matrices (every list distinct but Cb = Cr: x264 has
#   one chroma list per kind); hjvt: the JVT default matrices. Each fixture must reach its
#   paths: the model's coverage counters (tools/recon_top_golden.py prints them) are
#   required non-zero. FRExt ($H264_REFS_DIR): six CIF CABAC 4:2:0 streams, the first
#   pictures -- FRExt3_Panasonic_E (SPS + PPS matrices), HPCALQ_BRCM_B, HPCAQ2LQ_BRCM_B
#   (Cb != Cr lists, second_chroma_qp_index_offset), HCAFF1_HHI_B and HPCAFL_BRCM_C
#   (field pictures), HCAFR1_HHI_C.
#   H1  recon_deblock: luma edges 1 / 3 filtered with the 8x8 transform (hi)    -> [post]
#   H2  recon_deblock: the t8 flag read live, not latched at start   (hpb)      -> [post]
#   H3  recon_mb: an 8x8 block's samples into the 4x4 ids x/y swapped (hpb)     -> [pre]
#   H4  recon_mb: Intra_8x8 prev_intra8x8_pred_mode_flag indexed by 4x4 (hi)    -> [pre]
#   H5  recon_mb: no p[7,-1] substitution into p[8..15,-1]           (hi)       -> [pre]
#   H6  recon_mb: p[-1,-1] always available to the filter            (hi)       -> [pre]
#   H7  recon_mb: the above-right macroblock's samples 4..7 as 0..3  (hi)       -> [pre]
#   H8  recon_mb: the 8x8 lists Intra / Inter swapped               (hcq)      -> [pre]
#   H9  recon_mb: the 4x4 lists Intra / Inter swapped               (hcq)      -> [pre]
#   H10 recon_mb: Cr takes the Cb list                    (HPCAQ2LQ_BRCM_B)     -> [pre]
#   H11 recon_top: the slice's matrix always Flat_16                 (hcq)      -> [pre]
#   H12 recon_hdr: the 8x8 lists' words at the 4x4 lists' offsets    (hcq)      -> [pre]
#   H13 recon_mb: an 8x8 block's levels 16..63 read from its first slot (hpb)   -> [pre]
#   H14 recon_mb: Intra_8x8's four residual quarters x/y swapped     (hi)       -> [pre]
#   H15 recon_mb: an Intra_8x8 mode stored in one 4x4 slot, not four (hi)       -> [pre]
#   H16 recon_top: Cr's QP from chroma_qp_index_offset (HPCAQ2LQ_BRCM_B)        -> [pre]
#   H17 recon_mb: an 8x8 block of a field picture in the frame scan (HCAFF1_HHI_B) -> [pre]
#   H18 recon_mb: top7 (p[7,-1], Intra_8x8's substitution) loaded from p[6,-1] (hi) -> [pre]
#   H19 recon_mb: top3 (p[3,-1], Intra_4x4's substitution) loaded from p[2,-1] (i2) -> [pre]
#
# Phase 5b, throughput (docs/throughput.md):
#   T1  recon_deblock: the pre-pass writes bS at the undelayed index    (p4)        -> [post]
#   T2  recon_deblock: the p record read from the q copy of the RAM     (sl)        -> [post]
#   T3  recon_mb: the residual engine overlaps a DC block (its values read too early) (i2) -> [pre]
#   (T4, a coded 8x8 block started while 4x4 samples are still collected, is equivalent:
#   transform_size_8x8_flag is per macroblock, so the case never arises -- the guard it
#   tested was removed, the invariant documented in recon_mb_fsm.svh R_SETUP)
#   A1  recon_dpb: the no-free-store alarm never counts (a wait past STALL_LIMIT) (r16a, the
#       20,000-cycle bound) -> [alarm]
#   (Phase 4, the pause: UMD P6b3i's disp_frz, taken with interface 0.5's pause word)
#   F1  recon_dpb: the wait's alarm counts while the display is frozen (r16f) -> [frz]
#   F2  recon_dpb: the alarm never counts, frozen or not             (r16a) -> [alarm]
#   F3  recon_top: disp_frz not passed to recon_dpb                  (r16f) -> [frz]
#   T5  recon_inter: the streaming start ungated (rows_avail 31: reads ahead of the fetch) (p4) -> [pre]
#   (T9, the copy claiming a bank still in use, is R16 since the run-ahead moved the wait.)
#   T10 recon_mb: the streamed writeback's read side reads word 0 of every luma row twice
#       (exp/mb-pipeline: the read side and the command side walk the rows apart) (p4) -> [post]
#   T11 recon_mb: the streamed writeback steps a luma row by the chroma stride (p4) -> [post]
#   T12 recon_top: a picture done before its writes landed (dpb_mem wr_drained ignored)
#       (bsp against the slow DDR, bsps: the display holds a B picture at once) -> [hold]
#   exp/mb-pipeline (docs/mb_pipeline.md), the two front stages:
#   P2  the residual engine takes a macroblock with its collector busy (an 8x8 block's start
#       steers the result stream from a 4x4 one of the previous macroblock) (hpb) -> [pre]
#   P3  stage A loads a 2-wide picture's next macroblock before B's end walk (nar2) -> [pre]
#   P4  stage A's left neighbour without the right column's motion (bsp) -> [pre] / [post]
#   P5  the deblocker's pre-pass reads stage A's record bank (sl) -> [post]
#   P6  stage B adds residuals from bank 0 always (p4) -> [pre]
#   (equivalent, not an arm: the hand-off waiting for the engine to take A's request -- stage
#   B's tail after its last residual (SAVE, the side words, the deblock hand-off, >= 60
#   cycles) always outlasts the engine's (<= 3 cycles to R_IDLE); kept as a guard)
#   (equivalent, not arms: the copy's stage 0 carrying its item's first word -- the next
#   claim is a cycle after the pop, so c_wf holds; the sixteen-row request bound at 17 -- the
#   row buffers' full flags are the correctness, the bound is flow only)
#   Phase 5c part 2 step 2 (docs/mb_pipeline.md S4j), the 8x8 unit a pipeline over blocks:
#   V1  recon_mb: a 4x4 / DC block started while 8x8 samples still stream (r_l8 steers the
#       shared result port away from them) (hpb) -> [pre] / [hang]
#   V2  recon_mb: the next 8x8 block started without the unit's busy (its start lost) (hpb) -> [pre] / [hang]
#   W1  recon_inter: the narrowed window rectangle copied at window address 0 (S4k: a full-sample
#       item's sweep reads rows / columns 2.. the copy never wrote) (p4) -> [pre]
#   T6  recon_inter: a claimed bank's row count not reset (the last item's count) (bsp) -> [pre] / [hang]
#       (the stale count reads ahead, or wraps its 5 bits below the rows still owed: a hang)
#
# Interface 0.11, 720p (2 MiB stores, Level 3.1's MaxFS: docs/h264_recon.md S2.2): hd -- 1280x720,
#   3 pictures (I, P, B with temporal direct; High: the 8x8 transform), 3,600 macroblocks a
#   picture: neighbouring stores overlap at 1 MiB; big -- 1344x720 (3,780 macroblocks), one
#   picture, refused (+expect_refused: every slice counted in ref_size, nothing written or shown).
#   S1  recon_mb: the current picture's store at << 17 (1 MiB stores)   (hd)  -> [pre] / [post]
#   S2  recon_inter: a reference read at << 17                          (hd)  -> [pre]
#   S3  recon_mb: the co-located (direct) side words read at << 17      (hd)  -> [pre]
#   S4  recon_top: the bound back at 1,620 (0.10's)                     (hd)  -> [count] / [hang]
#   S5  recon_top: no bound (a 3,780-macroblock picture decoded into a 2 MiB store) (big) -> [refuse]
#   S6  recon_top: the refused slice still handed to recon_dpb (a store opened, the unwritten
#       store emitted to the display: the defect found 2026-10-02, the 1,620 bound had it) (big) -> [refuse]
#   S7  recon_top: (perf/retime) the slice handed to recon_dpb a cycle before the registered compare
#       settles (sr_d2: the previous slice's verdict -- reset's 0 for the first)          (big) -> [refuse]
#
# Interface 0.16, the colour (docs/colour.md): twenty clips of two IDR pictures, the VUI written by ffmpeg's
#   h264_metadata (every Table E-5 class, both ranges, the size rule at 1,280 wide / 576 and 592 high / a
#   crop across 1,280, both override directions); every picture's code (pinfo_colour), its unsupported flag
#   and its SPS's description scored against ffprobe's READING of the clip mapped by colour.md's table
#   (+colour / +unsup / +tags, the runner's oracle: independent of the RTL's parse). [colour]:
#   CL1  recon_hdr: matrix_coefficients not stored                 (c709)   CL2  recon_top: the range ignored (c709f)
#   CL3  recon_top: the width bound > 1,280 (not >=)               (chd)    CL4  recon_top: the coded width, not the cropped (ccrop)
#   CL5  recon_top: an unsupported matrix not flagged              (cgbr)   CL6  recon_top: the stream's override ignored (cscol)
#   CL7  recon_top: BT.2020 taken as 709                           (c2020)  CL8  recon_hdr: transfer stored as primaries (c2020's tags)
#   CL9  recon_top: the height bound >= 576 (not >)                (c576)   CL10 recon_hdr: the absent matrix inferred 6, not 2 (cnone's tags)
#   CL11 recon_top: matrix 3 (reserved) taken as unsupported       (cres)   CL12 recon_top: the height in half macroblocks (ctall)
#   (docs/chroma.md §4, the chroma siting; ffprobe's chroma_location the oracle, +siting on every colour clip)
#   CL13 recon_hdr: the top field's type not stored                (sit1)   CL14 recon_hdr: the bottom field's not stored (sit5)
#   CL15 recon_top: the siting not carried to pinfo                (sit2)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/rtop_gate
fail=0
red=0
for a in "$@"; do case $a in --red) red=1;; esac; done
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
GEN=bench/h264/fixtures/gen
W=.sim/rtop_gate
RTL="h264/dec/h264_pkg.sv h264/fifo_dc.sv h264/sfifo.sv h264/dec/dpb_mem.sv h264/dec/recon_hdr.sv h264/dec/recon_dpb.sv
     h264/dec/recon_lists.sv h264/dec/dsf_calc.sv h264/dec/recon_slice_tab.sv h264/dec/mb_intake.sv h264/dec/mv_pred.sv
     h264/dec/mc_interp.sv h264/dec/wpred.sv h264/dec/recon_inter.sv h264/dec/intra_pred.sv h264/dec/high_tables.sv h264/dec/dequant_itrans.sv h264/dec/dequant_itrans8.sv
     h264/dec/deblock_bs.sv h264/dec/deblock_filter.sv h264/dec/recon_deblock.sv h264/dec/recon_mb.sv h264/dec/recon_top.sv"
TB="bench/h264/ddr_model.sv bench/h264/recon_top_tb.sv"
rm -f $W/sim $W/sim_alarm   # iverilog leaves the old binary on a failed build: never run it
# shellcheck disable=SC2086
iverilog -g2012 -I . -o $W/sim $RTL $TB 2>&1 | grep -v "sorry\|warning" && { echo "FAIL: build"; exit 1; }
[ -f $W/sim ] || { echo "FAIL: build"; exit 1; }
# the alarm's simulator: recon_dpb's wait bound at 20,000 cycles instead of 13 M, so a hold
# outlasts it (r16a; ported from MiSTer_UMD_Video P6b3i -- no hold had ever reached it)
# shellcheck disable=SC2086
iverilog -g2012 -I . -Precon_top_tb.STALL=20000 -o $W/sim_alarm $RTL $TB 2>&1 | grep -v "sorry\|warning" && { echo "FAIL: build (alarm)"; exit 1; }
[ -f $W/sim_alarm ] || { echo "FAIL: build (alarm)"; exit 1; }

STEMS=()
fx() {          # name fixture-command... -> the fixture, log in $W/<name>_fx.log
  local name=$1; shift
  "$@" --out "$GEN/rtop_$name" > "$W/${name}_fx.log" 2>&1
}
run() {         # sim name [stem [plusarg...]] -> the bench's verdict in $W/<name>.log
  local sim=$1 name=$2 stem=${3:-$2}
  shift $(( $# < 3 ? $# : 3 ))
  timeout 7200 vvp -n "$sim" "+stem=$GEN/rtop_$stem" "$@" > "$W/$name.log" 2>&1
}
verdict() {     # label name
  if grep -q "^PASS: recon_top_tb" "$W/$2.log"; then
    echo "  PASS $1: $(grep -m1 '^recon_top_tb:' "$W/$2.log" | sed 's/^recon_top_tb: //')"; STEMS+=("$2")
  else echo "  FAIL $1"; grep -m3 "FAIL" "$W/$2.log" | sed 's/^/    /'; fail=1; fi
}
x264() {        # name size frames params [filter] -> .264 + fixture
  local f="testsrc2=size=$2:rate=24"; [ -n "${5:-}" ] && f="$f,$5"
  ffmpeg -v error -f lavfi -i "$f" -frames:v "$3" -c:v libx264 -pix_fmt yuv420p -x264-params "$4" \
    -bsf:v h264_mp4toannexb -f h264 -y "$W/$1.264" && fx "$1" python3 tools/recon_top_golden.py "$W/$1.264"
}

echo "== GREEN: x264 clips (refs-free) =="
X264=(i2 p4 bsp btm wp wb sl mvq r16 nar3 nar2 nar1)
declare -A XL=([i2]="intra, 2 IDR" [p4]="P, 2 refs" [bsp]="B spatial direct, partitions=all"
               [btm]="B temporal direct" [wp]="explicit weighted P (fade)" [wb]="implicit weighted B (fade)"
               [sl]="3 slices/picture, deblock offsets" [mvq]="P, sub-pixel scroll + noise, qp 36" [r16]="16 reference frames (the DPB at its maximum)"
               [nar3]="B, 3 macroblocks wide (the narrowest picture A and B overlap on)"
               [nar2]="B, 2 macroblocks wide (exp/mb-pipeline: the above record is stage B's)" [nar1]="B, 1 macroblock wide")
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 i2 64x48 2 "cabac=1:8x8dct=0:keyint=1:crf=24" &
  x264 p4 64x48 4 "cabac=1:8x8dct=0:bframes=0:ref=2:keyint=4:crf=26:weightp=0" &
  x264 bsp 64x48 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=spatial:weightp=0:partitions=all" &
  x264 btm 64x48 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=temporal:weightp=0:partitions=all" &
  x264 wp 64x48 6 "cabac=1:8x8dct=0:bframes=0:ref=2:keyint=6:crf=26:weightp=2" "fade=t=out:st=0:d=0.25" &
  x264 wb 64x48 6 "cabac=1:8x8dct=0:bframes=2:ref=2:keyint=6:crf=26:weightb=1:weightp=2" "fade=t=out:st=0:d=0.25" &
  x264 sl 96x64 4 "cabac=1:8x8dct=0:bframes=1:ref=2:keyint=4:crf=24:slices=3:deblock=1,-2" &
  x264 mvq 64x48 5 "cabac=1:8x8dct=0:bframes=0:ref=2:keyint=5:qp=36:weightp=0:subme=7" "scroll=h=0.013:v=0.021,noise=alls=10:allf=t:all_seed=7" &
  x264 r16 64x48 30 "cabac=1:8x8dct=0:bframes=0:ref=16:keyint=60:min-keyint=60:scenecut=0:crf=26:weightp=0" "scroll=h=0.013:v=0.021" &
  x264 nar3 48x64 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=spatial:weightp=0:partitions=all" &
  x264 nar2 32x64 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=spatial:weightp=0:partitions=all" &
  x264 nar1 16x64 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=spatial:weightp=0:partitions=all" &
  wait
  for n in "${X264[@]}"; do run $W/sim $n & done
  # bsp against a fast DDR model (1-2 mclk latency, no waitrequest): the fetch outruns the
  # two interpolation lanes, so a window bank is reused as soon as it is free -- the arm
  # R16 needs (P5b 4b: at the default latency the lanes always free the bank first)
  run $W/sim bspf bsp +lat_min=1 +lat_max=2 +wait_pct=0 &
  # bsp against a SLOW DDR (20-60 mclk, 60 % waitrequest): writes queue in dpb_mem, so a B
  # picture (output at once) is released before its last rows land unless pipe_idle waits
  # for wr_drained -- T12's arm (since dpb_mem's write skid the default model drains too fast)
  run $W/sim bsps bsp +lat_min=20 +lat_max=60 +wait_pct=60 &
  wait
  for n in "${X264[@]}"; do verdict "${XL[$n]} ($n)" $n; done
  verdict "${XL[bsp]}, a fast DDR (bspf)" bspf
  verdict "${XL[bsp]}, a slow DDR (bsps)" bsps
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: 720p (interface 0.11: 2 MiB stores, the 3,600-macroblock bound) =="
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 hd 1280x720 3 "cabac=1:8x8dct=1:bframes=1:b-pyramid=0:ref=2:keyint=3:crf=30:weightp=0:direct=temporal" &
  x264 big 1344x720 1 "cabac=1:keyint=1:crf=36" &
  wait
  run $W/sim hd &
  run $W/sim big big +expect_refused &
  wait
  verdict "1280x720 I / P / B (temporal direct), 3,600 macroblocks a picture (hd)" hd
  verdict "1344x720 (3,780 macroblocks): refused, nothing written (big)" big
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: the colour (interface 0.16, docs/colour.md: the VUI's matrix and range, the size rule, the override) =="
# Two IDR pictures each, the VUI written by ffmpeg's h264_metadata (any Table E-5 value, the range, the
# crop); the expected code from ffprobe's READING of the clip -- its colour_space / color_range names and
# its cropped size -- mapped by the design's table (colour.md S2), independent of the RTL's parse.
xcol() {        # name size bsf-params [scol] -> .264, fixture, the expectation's plusargs in $W/<name>.cargs
  local bsf="h264_mp4toannexb"; [ -n "$3" ] && bsf="$bsf,h264_metadata=$3"
  ffmpeg -v error -f lavfi -i "testsrc2=size=$2:rate=24" -frames:v 2 -c:v libx264 -pix_fmt yuv420p \
    -x264-params "cabac=1:keyint=1:crf=30" -bsf:v "$bsf" -f h264 -y "$W/$1.264" &&
    fx "$1" python3 tools/recon_top_golden.py "$W/$1.264" &&
    python3 - "$W/$1.264" "${4:-0}" > "$W/$1.cargs" <<'ORACLE'
import json, subprocess, sys
path, scol = sys.argv[1], int(sys.argv[2])
s = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
    "stream=width,height,color_space,color_range,chroma_location,nb_read_frames", "-of", "json", path],
    capture_output=True, text=True, check=True).stdout)["streams"][0]
mat = {"bt709": 1, "smpte240m": 1, "fcc": 0, "bt470bg": 0, "smpte170m": 0, "bt2020nc": 2}
cs, n = s.get("color_space", "unknown"), int(s["nb_read_frames"])
hd = s["width"] >= 1280 or s["height"] > 576
unsup = cs not in mat and cs not in ("unknown", "reserved")
code = 1 + 2 * mat.get(cs, 1 if hd else 0) + (s.get("color_range") == "pc")
if scol:
    code, unsup = scol, False
# (docs/chroma.md §4) the chroma siting as ffprobe names it, E.2.1's types (absent: 0); the bsf writes
# both fields' types alike, so the expectation is {t, t}
loc = {"left": 0, "center": 1, "topleft": 2, "top": 3, "bottomleft": 4, "bottom": 5}.get(s.get("chroma_location", ""), 0)
print("+colour=%d +unsup=%d +scol=%d +siting=%02x" % (code, n if unsup else 0, scol, (loc << 3) | loc))
ORACLE
}
XCOL=(c709 c709f c601 c601f cfcc c240 c2020 c2020f cgbr cycgco c2020c c14 cres cnone chd ccrop ctall c576 cscol cscolf
      sit1 sit2 sit5)
declare -A XCL=([c709]="BT.709" [c709f]="BT.709 full range" [c601]="SMPTE 170M" [c601f]="BT.470BG full range"
  [cfcc]="FCC as 601" [c240]="SMPTE 240M as 709" [c2020]="BT.2020 (+ the tags word)" [c2020f]="BT.2020 full range"
  [cgbr]="GBR: unsupported, the size rule, counted" [cycgco]="YCgCo full range: unsupported" [c2020c]="BT.2020 constant luminance: unsupported"
  [c14]="matrix 14 (ICtCp): unsupported" [cres]="matrix 3, reserved: the size rule, not counted" [cnone]="untagged SD: 601"
  [chd]="untagged 1280x16: 709 (the width bound, exactly)" [ccrop]="untagged 1280x16 cropped to 1278: 601 (the shown size)"
  [ctall]="untagged 16x592: 709 (taller than 576)" [c576]="untagged 16x576: 601 (exactly 576)"
  [cscol]="BT.709 overridden to 601 limited (stream colour 1)" [cscolf]="untagged overridden to 2020 full (stream colour 6)"
  [sit1]="chroma siting 1, centre (chroma.md §4)" [sit2]="chroma siting 2, top left" [sit5]="chroma siting 5, bottom")
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  xcol c709 64x48 "matrix_coefficients=1" & xcol c709f 64x48 "matrix_coefficients=1:video_full_range_flag=1" &
  xcol c601 64x48 "matrix_coefficients=6" & xcol c601f 64x48 "matrix_coefficients=5:video_full_range_flag=1" &
  xcol cfcc 64x48 "matrix_coefficients=4" & xcol c240 64x48 "matrix_coefficients=7" &
  xcol c2020 64x48 "colour_primaries=9:transfer_characteristics=14:matrix_coefficients=9" &
  xcol c2020f 64x48 "matrix_coefficients=9:video_full_range_flag=1" &
  wait
  xcol cgbr 64x48 "matrix_coefficients=0" & xcol cycgco 64x48 "matrix_coefficients=8:video_full_range_flag=1" &
  xcol c2020c 64x48 "matrix_coefficients=10" & xcol c14 64x48 "matrix_coefficients=14" &
  xcol cres 64x48 "matrix_coefficients=3" & xcol cnone 64x48 "" &
  xcol chd 1280x16 "" & xcol ccrop 1280x16 "crop_right=2" & xcol ctall 16x592 "" & xcol c576 16x576 "" &
  xcol cscol 64x48 "matrix_coefficients=1" 1 & xcol cscolf 64x48 "" 6 &
  xcol sit1 64x48 "chroma_sample_loc_type=1" & xcol sit2 64x48 "chroma_sample_loc_type=2" &
  xcol sit5 64x48 "chroma_sample_loc_type=5" &
  wait
  # c2020's tags word: {present, full, primaries, transfer, matrix} as the bsf wrote them
  echo "+tags=$(printf '%07x' $(( (1 << 25) | (9 << 16) | (14 << 8) | 9 )))" >> $W/c2020.cargs
  # cnone's: no colour description -- E.2.1's inferences, 2 / 2 / 2, limited
  echo "+tags=$(printf '%07x' $(( (2 << 16) | (2 << 8) | 2 )))" >> $W/cnone.cargs
  for n in "${XCOL[@]}"; do
    # shellcheck disable=SC2046
    run $W/sim $n $n $(tr '\n' ' ' < $W/$n.cargs) &
  done
  wait
  for n in "${XCOL[@]}"; do verdict "${XCL[$n]} ($n: $(tr '\n' ' ' < $W/$n.cargs))" $n; done
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: the output process (P5d: C.4.4 / C.4.5, the display's holds) =="
# c44b: B pictures, two IDRs, x264's VUI DPB size (non-reference pictures output directly,
# C.4.5.2); c44n: its second IDR's no_output_of_prior_pics_flag set (the waiting stores
# dropped, not output -- JM agrees, ffmpeg ignores the flag); c44m: MMCO 5 on the last
# reference before the second IDR (the others bumped BEFORE the POC rewrite). Both
# rewrites drop the VUI: the DPB size from Table A-1.
# P3d (early output under max_num_reorder_frames; POC type 2 read as 0) makes the bumping
# path dormant where the stream limits its reordering -- c44m is P only, POC type 2: every
# picture leaves at once. Two fixtures keep it alive for the output-process arms: c44mb (B
# frames, so POC type 0, the MMCO 5 rewrite, no VUI: the bumping alone) and c44d (B
# frames, a VUI with max_num_reorder_frames = max_dec_frame_buffering = 3: the VUI's DPB
# size alone decides -- at 3 the DPB fills (2 references + the waiting ones) before the
# reorder limit binds; at 4 or more on this stream the limit fires exactly when the bump
# would, so a DPB size one too large is an EQUIVALENT mutant there: measured on the model,
# 2026-09-27). r16s: r16 with holds long enough
# that the decoder must wait for a release (+expect_stall): the stall path, no error.
# r16a: the same holds against a 20,000-cycle bound (-Precon_top_tb.STALL): the alarm must
# count code 6 and every picture is still exact ([alarm]). r16f (Phase 4's pause): the same
# holds with the display frozen -- a wait outlasts the bound and no error counts ([frz]).
C44=(c44b c44n c44m c44mb c44d)
declare -A OL=([c44b]="B pictures, direct output (C.4.5.2)" [c44n]="no_output_of_prior_pics_flag (C.4.4)"
               [c44m]="MMCO 5 bumps everything (C.4.4)" [c44mb]="MMCO 5 among B pictures, the bumping alone (C.4.4 / C.4.5)"
               [c44d]="the VUI's DPB size alone (max_num_reorder_frames = max_dec_frame_buffering = 3)")
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  c44() {       # name x264-params [synth kind]
    ffmpeg -v error -f lavfi -i testsrc2=size=64x64:rate=24 -frames:v 14 -c:v libx264 -pix_fmt yuv420p \
      -x264-params "cabac=1:8x8dct=0:keyint=7:min-keyint=7:scenecut=0:weightp=0:$2" -f h264 -y "$W/$1.264" || return
    if [ -n "${3:-}" ]; then python3 tools/h264_synth.py "$W/$1.264" "$3" "$W/$1s.264" > "$W/${1}_synth.log" 2>&1 \
                             && mv "$W/$1s.264" "$W/$1.264" || return; fi
    fx "$1" python3 tools/recon_top_golden.py "$W/$1.264"
  }
  c44 c44b "bframes=2:b-pyramid=0:ref=2" &
  c44 c44n "bframes=2:b-pyramid=0:ref=2" no_output &
  c44 c44m "bframes=0:ref=1" mmco5 &
  c44 c44mb "bframes=2:b-pyramid=0:ref=2" mmco5 &
  c44 c44d "bframes=2:b-pyramid=0:ref=2" dpb3 &
  wait
  # c44n drops 7: c44b, the same stream without the flag, emits all 14 pictures; c44n
  # emits 7 (the model's list, JM's behaviour) -- the other 7 are the waiting stores the
  # second IDR drops. Every other clip is scored at 0 ([dropped], the status counter).
  for n in "${C44[@]}"; do
    if [ $n = c44n ]; then run $W/sim $n $n +dropped=7 & else run $W/sim $n & fi
  done
  if [[ " ${STEMS[*]} " =~ " r16 " ]]; then
    run $W/sim r16s r16 +hold=600000 +expect_stall &
    run $W/sim_alarm r16a r16 +hold=600000 +expect_stall +expect_alarm &
    run $W/sim_alarm r16f r16 +hold=600000 +expect_stall +frozen &
  fi
  wait
  for n in "${C44[@]}"; do verdict "${OL[$n]} ($n)" $n; done
  if [[ " ${STEMS[*]} " =~ " r16 " ]]; then verdict "the display holds, the decoder waits (r16s)" r16s
    verdict "a wait past the bound (20,000 cycles): the no-free-store alarm, every picture exact (r16a)" r16a
    verdict "the display frozen (the pause): its holds are no alarm (r16f)" r16f
  else echo "  FAIL the display holds: r16 not GREEN in this run"; fail=1; fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: H.264.1 conformance (\$H264_REFS_DIR), the first pictures =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
CONF=(CAFI1_SVA_C cabac_mot_fld0_full CAPA1_TOSHIBA_B CAWP5_TOSHIBA_E CABREF3_Sand_D)
declare -A CL=([CAFI1_SVA_C]="fields, spatial direct" [cabac_mot_fld0_full]="fields, P and B"
               [CAPA1_TOSHIBA_B]="PAFF" [CAWP5_TOSHIBA_E]="explicit weights, list modification"
               [CABREF3_Sand_D]="fields (its long-term / MMCO pictures come later: jlt / jfmmco)")
CONF_OK=()
if [ -d "$AVC" ]; then
  for c in "${CONF[@]}"; do
    if [ -f "$AVC/$c.zip" ]; then
      (d=$(mktemp -d); unzip -o -q "$AVC/$c.zip" -d "$d"
       f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" | head -1)
       fx "$c" python3 tools/recon_top_golden.py "$f" --max-pics 4; rm -rf "$d") &
      CONF_OK+=("$c")
    else echo "  SKIP ${CL[$c]}: no $AVC/$c.zip"; fi
  done
  wait
  # fodd: the field stream cut after an odd picture -- its last first field has no
  # partner, and the end of stream emits it UNPAIRED (P5d)
  if [ -f "$AVC/cabac_mot_fld0_full.zip" ]; then
    d=$(mktemp -d); unzip -o -q "$AVC/cabac_mot_fld0_full.zip" -d "$d"
    f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" | head -1)
    fx fodd python3 tools/recon_top_golden.py "$f" --max-pics 5; rm -rf "$d"
    CONF_OK+=(fodd); CL[fodd]="fields, cut after a first field: unpaired at the end"
  fi
  for c in "${CONF_OK[@]}"; do run $W/sim "$c" & done; wait
  for c in "${CONF_OK[@]}"; do verdict "${CL[$c]} ($c)" "$c"; done
else
  echo "  SKIP: no $AVC (set H264_REFS_DIR)"
fi

echo "== GREEN: JM lencod control-path streams (\$H264_REFS_DIR) =="
JMCASES=(jfmmco jlt jswap jmod jdefer)
declare -A JL=([jfmmco]="field pictures with MMCOs" [jlt]="a long-term reference in a frame stream"
               [jswap]="low-delay B, the list-1 swap" [jmod]="list modification, duplicates removed"
               [jdefer]="B field pairs output directly, emitted with the second field")
LENCOD="$REFS/JM/build_enc/bin/lencod.exe"
if [ ! -x "$LENCOD" ] && [ -d "$REFS/JM/lencod/src" ]; then
  H264_REFS_DIR="$REFS" bash tools/jm_build.sh --lencod > $W/lencod_build.log 2>&1
fi
if [ -x "$LENCOD" ]; then
  # a stale fixture must not stand in for one this run could not write
  for c in "${JMCASES[@]}"; do (rm -f "$GEN/rtop_$c".*; fx "$c" python3 tools/jm_fixtures.py "$c" --lencod "$LENCOD") & done
  wait
  for c in "${JMCASES[@]}"; do
    if [ -f "$GEN/rtop_$c.meta.hex" ]; then run $W/sim "$c" &
    else echo "  FAIL ${JL[$c]} ($c): $(grep -m1 'FAIL\|Error\|rror' $W/${c}_fx.log | cut -c1-200)"; fail=1; fi
  done
  wait
  for c in "${JMCASES[@]}"; do [ -f "$GEN/rtop_$c.meta.hex" ] && verdict "${JL[$c]} ($c)" "$c"; done
else
  echo "  SKIP: no JM source / lencod under $REFS (set H264_REFS_DIR)"
fi

echo "== GREEN: High profile (Phase 5): x264 clips (refs-free) =="
need_cov() {    # name key... -> every key's counter non-zero in the fixture's coverage line
  local name=$1; shift
  local line; line=$(grep -m1 '^coverage:' "$W/${name}_fx.log")
  for k in "$@"; do
    if ! [[ " ${line#coverage: } " =~ \ $k=[1-9] ]]; then
      echo "  FAIL $name: the fixture never reaches $k ($line)"; fail=1; return 1
    fi
  done
}
HIGH=(hi hpb hci hcq hjvt)
declare -A HL=([hi]="intra, Intra_8x8 all modes, mid-row slices" [hpb]="P / B, the 8x8 transform"
               [hci]="constrained intra, 3 slices" [hcq]="custom scaling matrices" [hjvt]="JVT default matrices")
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  CQ="cqm4iy=$(python3 -c "print(','.join(str(6+(i*13)%50) for i in range(16)))")"
  CQ="$CQ:cqm4ic=$(python3 -c "print(','.join(str(9+(i*7)%40) for i in range(16)))")"
  CQ="$CQ:cqm4py=$(python3 -c "print(','.join(str(12+(i*5)%36) for i in range(16)))")"
  CQ="$CQ:cqm4pc=$(python3 -c "print(','.join(str(8+(i*11)%30) for i in range(16)))")"
  CQ="$CQ:cqm8i=$(python3 -c "print(','.join(str(4+(i*11)%60) for i in range(64)))")"
  CQ="$CQ:cqm8p=$(python3 -c "print(','.join(str(10+(i*9)%45) for i in range(64)))")"
  x264 hi 128x96 2 "cabac=1:8x8dct=1:keyint=1:crf=20:partitions=i8x8:slice-max-mbs=9" "noise=alls=6:allf=t:all_seed=3" &
  x264 hpb 96x64 6 "cabac=1:8x8dct=1:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=24:partitions=all:weightp=0" "scroll=h=0.013:v=0.021" &
  x264 hci 96x64 4 "cabac=1:8x8dct=1:bframes=0:ref=1:keyint=4:crf=22:constrained-intra=1:slices=3:partitions=i8x8,p8x8" \
    "noise=alls=12:allf=t:all_seed=5,scroll=h=0.02" &
  x264 hcq 96x64 4 "cabac=1:8x8dct=1:bframes=1:ref=2:keyint=4:crf=22:weightp=0:$CQ" "noise=alls=8:allf=t:all_seed=9,scroll=h=0.013:v=0.021" &
  x264 hjvt 96x64 3 "cabac=1:8x8dct=1:bframes=1:keyint=3:crf=22:cqm=jvt:weightp=0" "scroll=h=0.013:v=0.021" &
  wait
  HOK=()
  need_cov hi i8_block i8_subst i8_no_corner i8_mode_from_nb t8_edge_skipped \
    i8_mode0 i8_mode1 i8_mode2 i8_mode3 i8_mode4 i8_mode5 i8_mode6 i8_mode7 i8_mode8 && HOK+=(hi)
  need_cov hpb i8_block t8_inter_coded t8_edge_skipped && HOK+=(hpb)
  need_cov hci i8_block t8_inter_coded && HOK+=(hci)
  need_cov hcq scaling_nonflat i8_coded t8_inter_coded && HOK+=(hcq)
  need_cov hjvt scaling_nonflat && HOK+=(hjvt)
  for n in "${HOK[@]}"; do run $W/sim $n & done; wait
  for n in "${HOK[@]}"; do verdict "${HL[$n]} ($n)" $n; done
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: High profile: H.264.1 FRExt (\$H264_REFS_DIR), the first pictures =="
FRX="$REFS/H.264.1_bitstreams/FRExt"
declare -A FP=([FRExt3_Panasonic_E]=3 [HPCALQ_BRCM_B]=2 [HPCAQ2LQ_BRCM_B]=2 [HCAFF1_HHI_B]=4 [HPCAFL_BRCM_C]=4 [HCAFR1_HHI_C]=3)
declare -A FL=([FRExt3_Panasonic_E]="SPS + PPS matrices" [HPCALQ_BRCM_B]="matrices, every list absent"
               [HPCAQ2LQ_BRCM_B]="Cb != Cr lists, second_chroma_qp_index_offset" [HCAFF1_HHI_B]="field pictures"
               [HPCAFL_BRCM_C]="field pictures" [HCAFR1_HHI_C]="frames")
FRX_OK=()
if [ -d "$FRX" ]; then
  for c in "${!FP[@]}"; do
    if [ -f "$FRX/$c.zip" ]; then
      (d=$(mktemp -d); unzip -o -q "$FRX/$c.zip" -d "$d"
       f=$(find "$d" -type f \( -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" \) | head -1)
       fx "$c" python3 tools/recon_top_golden.py "$f" --max-pics "${FP[$c]}"; rm -rf "$d") &
      FRX_OK+=("$c")
    else echo "  SKIP ${FL[$c]}: no $FRX/$c.zip"; fi
  done
  wait
  FRX_RUN=()
  for c in "${FRX_OK[@]}"; do need_cov "$c" i8_block && FRX_RUN+=("$c"); done
  for c in "${FRX_RUN[@]}"; do run $W/sim "$c" & done; wait
  for c in "${FRX_RUN[@]}"; do verdict "${FL[$c]} ($c)" "$c"; done
else
  echo "  SKIP: no $FRX (set H264_REFS_DIR; the FRExt package, docs/references.md)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  FIELDS=cabac_mot_fld0_full
  RES=$(mktemp -d)
  mut() {   # name file old new clip arm [plusargs [iverilog flags]]
    local name=$1 file=$2 old=$3 new=$4 clip=$5 arm=$6 extra=${7:-} iflags=${8:-}
    if [ ! -f "$GEN/rtop_$clip.se.hex" ] || [[ ! " ${STEMS[*]} " =~ " $clip " ]]; then
      { echo "  $name: clip $clip not GREEN in this run -- cannot score"; echo MUTFAIL; } > "$RES/$name"; return
    fi
    # at most $RTOP_JOBS mutants at once (default 10): one simulation is ~0.9 GB since the 2 MiB
    # stores doubled the DDR model (interface 0.11), and a batch is ~20 -- a slot is a lock file
    # held for the subshell's life
    local slot fd
    while :; do
      for slot in $(seq 1 "${RTOP_JOBS:-10}"); do
        exec {fd}>"$RES/slot$slot"
        flock -n "$fd" && break 2
        exec {fd}>&-
      done
      sleep 1
    done
    local d; d=$(mktemp -d)
    mkdir -p "$d/h264/dec"
    for f in $RTL; do cp "$f" "$d/$f"; done
    cp h264/dec/*.svh "$d/h264/dec/" 2>/dev/null
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?          # the anchor edit's status (a later loop would mask it)
    local tbs=""; for f in $TB; do tbs="$tbs $PWD/$f"; done
    # compiled FROM the copy: iverilog resolves `include "h264/dec/..." against the working
    # directory BEFORE any -I, so compiled from the repo root a mutated .svh (recon_mb_fsm)
    # was silently replaced by the repo's own -- R12-R14 once "survived" for that reason
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! (cd "$d" && iverilog -g2012 -I . $iflags -o sim $RTL $tbs) 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    timeout 7200 vvp -n "$d/sim" "+stem=$GEN/rtop_$clip" $extra > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut R1 h264/dec/mc_interp.sv "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4) + (vp2s <<< 2);" \
         "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4);" mvq pre &
  mut R2 h264/dec/deblock_bs.sv "else if (p_nz || q_nz)    bs_c = 3'd2;" "else if (p_nz || q_nz)    bs_c = 3'd1;" sl post &
  mut R3 h264/dec/recon_inter.sv "wp_mode <= explicit ? 2'd1 : 2'd0;" "wp_mode <= 2'd0;" wp pre &
  mut R4 h264/dec/recon_inter.sv "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy + 16'sd2;" \
         "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy;" $FIELDS pre &
  mut R5 h264/dec/recon_mb.sv ".kind(dq_kind), .qp(dq_qp), .field_scan(field_pic)" ".kind(dq_kind), .qp(dq_qp), .field_scan(1'b0)" $FIELDS pre &
  mut R6 h264/dec/recon_inter.sv "wp_mode <= 2'd1; wp_logwd <= 3'd5;" "wp_mode <= 2'd1; wp_logwd <= 3'd4;" wb pre &
  mut R7 h264/dec/recon_deblock.sv "(is_c ? 8'h08 : 8'h0E) << poff" "(is_c ? 8'h08 : 8'h0C) << poff" i2 post &
  mut R9 h264/dec/h264_pkg.sv "localparam int NSTORE = 20;" "localparam int NSTORE = 16;" r16 "pre|count|hang" &
  # (perf/retime round 2) the registered QP: the delta lost in qp_new_q; the setup's latched list-1 reference
  # (mvq is fixed-QP: no mb_qp_delta -- T13 is equivalent there; p4 is CRF with x264's adaptive QP)
  mut T13 h264/dec/recon_mb.sv "always_ff @(posedge clk) begin qp_new_q <= qp_new;" "always_ff @(posedge clk) begin qp_new_q <= qp_pred;" p4 pre &
  mut T14 h264/dec/recon_inter.sv "ls_gref0 <= sd_gref0; ls_gref1 <= sd_gref1;" "ls_gref1 <= sd_gref1;" CAWP5_TOSHIBA_E pre &
  mut T15 h264/dec/recon_mb_fsm.svh "if (r_blk == 5'd17 && !g_coded[17]) dc_nz[19:16] <= '0;" "if (1'b0) dc_nz[19:16] <= '0;" p4 pre &
  mut R8 h264/dec/recon_deblock.sv "wr_data <= hr[1]; wr_be <= 8'hFF;" \
         "wr_data <= {hr[1][7:0], hr[1][63:8]}; wr_be <= 8'hFF;" p4 post &
  mut R10 h264/dec/recon_inter.sv "if (h_bi && wp_a_ready[ln]) pf_h <= pf_h + 1'b1;" "if (1'b0) pf_h <= pf_h + 1'b1;" bsp pre &
  mut R11 h264/dec/recon_inter.sv "if (rx_we) m[{rx_seq[3:0], rx_word[1:0]}] <= rd_data[8*gl +: 8];" "if (rx_we) m[{1'b0, rx_seq[2:0], rx_word[1:0]}] <= rd_data[8*gl +: 8];" p4 pre &
  mut R12 h264/dec/recon_mb_fsm.svh "if (!is_dc) begin res_rdy[{g_rbank, id}] <= 1'b1; res_zero[{g_rbank, id}] <= 1'b1; end" \
         "if (!is_dc) begin res_rdy[{g_rbank, id}] <= 1'b1; res_zero[{g_rbank, id}] <= 1'b0; end" p4 pre &
  mut R13 h264/dec/recon_mb_fsm.svh "wire         grant_e = !aq_valid && !f_cmd_valid && e_cmd_valid && (w_left == 4'd0);" \
         "wire         grant_e = !aq_valid && !f_cmd_valid && e_cmd_valid;" p4 "pre|post|ddr|hang" &
  mut R14 h264/dec/recon_mb_fsm.svh "bk_we[d_cur] = 1'b1; bk_waddr[d_cur] = db_wr_addr;" "bk_we[d_cur] = (d_cur != fb); bk_waddr[d_cur] = db_wr_addr;" i2 post &
  mut R15 h264/dec/recon_mb_fsm.svh "dc_nz[wa] <= (dq_res != 16'sd0);" "dc_nz[wa] <= 1'b0;" i2 pre &
  mut R16 h264/dec/recon_inter.sv "if (n_cpd != n_push && !bank_full[fb]) begin" "if (n_cpd != n_push) begin" bsp "pre|hang" "+lat_min=1 +lat_max=2 +wait_pct=0" &
  mut R17 h264/dec/recon_lists.sv "if (sw_same && lq0 == lq1 && n_init[1] > 6'd1) ls <= L_SWAP_W0;" "if (1'b0) ls <= L_SWAP_W0;" jswap pre &
  mut R18 h264/dec/recon_lists.sv "if (!ent_match) begin" "if (1'b1) begin" jmod pre &
  mut R19 h264/dec/recon_dpb.sv "if (z_ms_b) ref_b[z_dx] <= UNUSED;" "if (1'b0) ref_b[z_dx] <= UNUSED;" jfmmco "pre|post|count" &
  mut R20 h264/dec/recon_dpb.sv "cur_ltref <= sh_long_term_reference;" "cur_ltref <= 1'b0;" jlt "pre|count" &
  wait
  # interface 0.11: the 2 MiB stores and the bound (sequenced after the batch above: memory)
  mut S1 h264/dec/recon_mb.sv "wire  [28:0] cur_base = dpb_base + {6'd0, cur_store, 18'd0};" \
         "wire  [28:0] cur_base = dpb_base + {7'd0, cur_store, 17'd0};" hd "pre|post" &
  mut S2 h264/dec/recon_inter.sv "base_q <= dpb_base + {6'd0, gcode_q[6:2], 18'd0} + plane_off;" \
         "base_q <= dpb_base + {7'd0, gcode_q[6:2], 17'd0} + plane_off;" hd pre &
  mut S3 h264/dec/recon_mb_fsm.svh "wire  [28:0] col_base_w = dpb_base + {6'd0, col_store, 18'd0} + off_side;" \
         "wire  [28:0] col_base_w = dpb_base + {7'd0, col_store, 17'd0} + off_side;" hd pre &
  mut S4 h264/dec/recon_top.sv "sz_over <= (sz_prod > 21'd3600);" "sz_over <= (sz_prod > 21'd1620);" hd "count|hang|out" &
  mut S5 h264/dec/recon_top.sv "sz_over <= (sz_prod > 21'd3600);" "sz_over <= 1'b0;" big refuse +expect_refused &
  mut S6 h264/dec/recon_top.sv "wire         dpb_slice_ready = sr_d3 && !sz_over;" "wire         dpb_slice_ready = sr_d3;" big refuse +expect_refused &
  # (perf/retime) the size's register stages: the hand-off a cycle before the compare has settled
  mut S7 h264/dec/recon_top.sv "wire         dpb_slice_ready = sr_d3 && !sz_over;" "wire         dpb_slice_ready = sr_d2 && !sz_over;" big refuse +expect_refused &
  wait
  # P5d, the output process (sequenced: memory)
  mut O1 h264/dec/recon_dpb.sv "(!best_found || sq_poc < best_poc)" "(!best_found || sq_poc > best_poc)" c44b out &
  mut O2 h264/dec/recon_dpb.sv "5'd1 : s.max_dec_frame_buffering;" "5'd1 : s.max_dec_frame_buffering + 5'd1;" c44d out &
  mut O3 h264/dec/recon_dpb.sv "sz_acc <= sz_acc - {2'd0, sz_pic}; sz_cnt <= sz_cnt + 5'd1;" \
         "sz_acc <= '0; sz_cnt <= sz_cnt + 5'd1;" c44mb out &
  mut O4 h264/dec/recon_dpb.sv "if (cur_idr && cur_no_output) begin" "if (1'b0) begin" c44n out +dropped=7 &
  mut O13 h264/dec/recon_dpb.sv "if (drop_go) out_dropped <= out_dropped + {26'd0, drop_n};" "if (drop_go) out_dropped <= out_dropped;" c44n dropped +dropped=7 &
  mut O5 h264/dec/recon_dpb.sv "end else if (cur_idr || cur_mmco5) begin" "end else if (cur_idr) begin" c44mb out &
  mut O6 h264/dec/recon_dpb.sv "act_bump <= best_found && ((om != OM_NONREF) || (best_poc <= cur_poc));" \
         "act_bump <= best_found;" c44b out &
  mut O7 h264/dec/recon_dpb.sv "end else pend_emit[cur_store] <= 1'b1;" "end else pend_emit[cur_store] <= 1'b0;" jdefer out &
  mut O8 h264/dec/recon_dpb.sv "om <= OM_EOS; di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN;" \
         "eos_done <= 1'b1; eos_mode <= 1'b0; busy <= 1'b0; ds <= D_IDLE;" c44b out &
  wait
  mut O9 h264/dec/recon_dpb.sv "if (!pairing && !op_free && (|disp_hold)) begin" "if (1'b0) begin" r16 "count|hold|pre|post" \
         "+hold=600000 +expect_stall" &
  mut O10 h264/dec/recon_dpb.sv "|| disp_hold[i] || waiting[i] ||" "|| disp_hold[i] ||" c44mb "out|post|pre" &
  mut O11 h264/dec/recon_dpb.sv "emit_unpaired <= !frame_coded[best_store] && !(bs_dt && bs_db);" \
         "emit_unpaired <= 1'b0;" fodd out &
  mut O12 h264/dec/recon_top.sv $'.sh_no_output_of_prior_pics(sh_no_output),\n' \
          $'.sh_no_output_of_prior_pics(1\'b0),\n' c44n out +dropped=7 &
  wait
  # Phase 5, High profile (sequenced: memory)
  mut H1 h264/dec/recon_deblock.sv "(int_en && !(q_t8 && !is_c && e[0]))" "int_en" hi post &
  mut H2 h264/dec/recon_deblock.sv "(int_en && !(q_t8 && !is_c && e[0]))" "(int_en && !(q_t8_in && !is_c && e[0]))" hpb post &
  mut H3 h264/dec/recon_mb_fsm.svh "cid[4:2], res_n[5], res_n[2], res_n[4:3]}" "cid[4:2], res_n[2], res_n[5], res_n[4:3]}" hpb pre &
  mut H4 h264/dec/recon_mb_fsm.svh "wire       prev_ix = cur_t8 ? b_prev_flag[i4[3:2]] : b_prev_flag[i4];" \
         "wire       prev_ix = b_prev_flag[i4];" hi pre &
  mut H5 h264/dec/recon_mb_fsm.svh "if (!tr_av8 && top_av) begin" "if (1'b0) begin" hi pre &
  mut H6 h264/dec/recon_mb_fsm.svh "ip_av_corner <= corner_av;" "ip_av_corner <= 1'b1;" hi pre &
  mut H7 h264/dec/recon_mb_fsm.svh "h_src = 3'd1; h_val = upr_samp[cx[2:0]];" "h_src = 3'd1; h_val = upr_samp[{1'b0, cx[1:0]}];" hi pre &
  mut H8 h264/dec/recon_mb.sv ".wlist(!g_intra)" ".wlist(g_intra)" hcq pre &
  wait
  mut H9 h264/dec/recon_mb_fsm.svh "wl = g_intra ? 3'd0 : 3'd3;" "wl = g_intra ? 3'd3 : 3'd0;" hcq pre &
  mut H10 h264/dec/recon_mb_fsm.svh "wl = wl + (c ? 3'd2 : 3'd1);" "wl = wl + 3'd1;" HPCAQ2LQ_BRCM_B pre &
  mut H11 h264/dec/recon_top.sv ".sflat(sh_sflat)" ".sflat(1'b1)" hcq pre &
  mut H12 h264/dec/recon_hdr.sv "sl8_ram[sl_wi[4:0] - 5'd24] <= sl_wd;" "sl8_ram[sl_wi[4:0]] <= sl_wd;" hcq pre &
  mut H13 h264/dec/recon_mb_fsm.svh "{r_slot + {3'd0, r_pos[5:4]}, r_pos[3:0]}" "{r_slot, r_pos[3:0]}" hpb pre &
  mut H14 h264/dec/recon_mb_fsm.svh "r_x <= {i4[2], sb[0], 2'b00}; r_y <= {i4[3], sb[1], 2'b00};" \
         "r_x <= {i4[2], sb[1], 2'b00}; r_y <= {i4[3], sb[0], 2'b00};" hi pre &
  mut H15 h264/dec/recon_mb_fsm.svh "for (int k = 0; k < 16; k++) if (k[3:2] == i4[3:2]) modes[k] <= m;" "modes[i4] <= m;" hi pre &
  mut H17 h264/dec/recon_mb.sv ".start(dq_start && r_l8), .qp(dq_qp), .field_scan(field_pic)" \
         ".start(dq_start && r_l8), .qp(dq_qp), .field_scan(1'b0)" HCAFF1_HHI_B pre &
  mut T1 h264/dec/recon_deblock.sv "if (bs_valid) bs_arr[bs_idx_d] <= bs_out;" "if (bs_valid) bs_arr[bs_idx] <= bs_out;" p4 post &
  mut T3 h264/dec/recon_mb_fsm.svh "wire         r_serial = (r_kind == 3'd3 || r_kind == 3'd4);" "wire         r_serial = 1'b0;" i2 pre &
  mut T2 h264/dec/recon_deblock.sv "prec <= a1_mbe ? lt_rec : rec_p;" "prec <= a1_mbe ? lt_rec : rec_q;" sl post &
  wait
  # the substitution samples load a cycle after the gather (the SEED 5 fit's worst path)
  mut H18 h264/dec/recon_mb_fsm.svh "t7_ld <= gt2_v && (gt2_idx == 6'd7);" "t7_ld <= gt2_v && (gt2_idx == 6'd6);" hi pre &
  mut H19 h264/dec/recon_mb_fsm.svh "t3_ld <= gt2_v && (gt2_idx == 6'd3);" "t3_ld <= gt2_v && (gt2_idx == 6'd2);" i2 pre &
  mut H16 h264/dec/recon_top.sv ".cr_qp_off(pps.second_chroma_qp_index_offset)" ".cr_qp_off(pps.chroma_qp_index_offset)" HPCAQ2LQ_BRCM_B pre &
  mut A1 h264/dec/recon_dpb.sv "if (!disp_frz && stall_ctr >= STALL_LIMIT[23:0]) begin err_no_store <= 1'b1;" \
         "if (1'b0) begin err_no_store <= 1'b1;" r16 alarm "+hold=600000 +expect_stall +expect_alarm" "-Precon_top_tb.STALL=20000" &
  mut F1 h264/dec/recon_dpb.sv "stall_ctr <= disp_frz ? 24'd0 : stall_ctr + 24'd2;
                        if (!disp_frz && " "stall_ctr <= stall_ctr + 24'd2;
                        if (" r16 frz "+hold=600000 +expect_stall +frozen" "-Precon_top_tb.STALL=20000" &
  mut F2 h264/dec/recon_dpb.sv "if (!disp_frz && stall_ctr >= STALL_LIMIT[23:0])" "if (1'b0 && stall_ctr >= STALL_LIMIT[23:0])" \
         r16 alarm "+hold=600000 +expect_stall +expect_alarm" "-Precon_top_tb.STALL=20000" &
  mut F3 h264/dec/recon_top.sv ".disp_frz(disp_frz)," ".disp_frz(1'b0)," r16 frz "+hold=600000 +expect_stall +frozen" "-Precon_top_tb.STALL=20000" &
  mut T5 h264/dec/recon_inter.sv ".rows_avail(bank_rows[kb])" ".rows_avail(5'd31)" p4 pre &
  mut T10 h264/dec/recon_mb_fsm.svh "if (rd_row < 5'd16) e_bk_raddr <= {1'b0, rd_row[3:0], rd_w};" "if (rd_row < 5'd16) e_bk_raddr <= {1'b0, rd_row[3:0], 1'b0};" p4 post &
  mut T11 h264/dec/recon_mb_fsm.svh "else c_addr <= c_a + ((c_plane == 2'd0) ? st_y : st_c);" "else c_addr <= c_a + st_c;" p4 post &
  mut T12 h264/dec/recon_top.sv "!m_wd_valid && !mb_release && m_wr_drained;" "!m_wd_valid && !mb_release;" bsp hold "+lat_min=20 +lat_max=60 +wait_pct=60" &
  mut P2 h264/dec/recon_mb_fsm.svh "always_comb rq_take = (rs == R_IDLE) && rq_v && (cf_n == 3'd0) && !clear;" \
         "always_comb rq_take = (rs == R_IDLE) && rq_v && !clear;" hpb pre &
  mut P3 h264/dec/recon_mb_fsm.svh "end else if (mb_valid && !(width_mbs <= 8'd2 && ms != M_IDLE)) begin" "end else if (mb_valid) begin" nar2 pre &
  mut P4 h264/dec/recon_mb_fsm.svh "a_nb_left[54 +: 92] <= a_intra ? 92'd0 : a_rc[0];" "a_nb_left[54 +: 92] <= 92'd0;" bsp "pre|post" &
  mut P5 h264/dec/recon_mb_fsm.svh "assign rec_wbank = a_mbank; assign rec_rbank = b_mbank;" "assign rec_wbank = a_mbank; assign rec_rbank = a_mbank;" sl post &
  mut P6 h264/dec/recon_mb_fsm.svh "res_raddr <= {b_rbank, f_rid, add_row[1:0]};" "res_raddr <= {1'b0, f_rid, add_row[1:0]};" p4 pre &
  mut W1 h264/dec/recon_inter.sv "cp_base <= q_wst[n_cpd[0]];" "cp_base <= '0;" p4 pre &
  mut V1 h264/dec/recon_mb_fsm.svh "end else if (r_l8 && kind != 3'd5 && cf_n != 3'd0) begin" "end else if (1'b0) begin" hpb "pre|hang" &
  mut V2 h264/dec/recon_mb_fsm.svh "if (r_serial ? (cf_n == 3'd0) : r_l8 ? !dq8_busy : !dq_busy) begin" "if (r_serial ? (cf_n == 3'd0) : r_l8 ? 1'b1 : !dq_busy) begin" hpb "pre|hang" &
  mut T6 h264/dec/recon_inter.sv "bank_full[fb] <= 1'b1; bank_rows[fb] <= q_r0[n_cpd[0]];" "bank_full[fb] <= 1'b1;" bsp "pre|hang" &
  wait
  # (0.16, docs/colour.md) the colour, each on its own clip's [colour]
  cx() { tr '\n' ' ' < $W/$1.cargs; }
  mut CL1 h264/dec/recon_hdr.sv "F_matrix_coefficients:             c_stage[7:0] <= cv_q;" "F_matrix_coefficients:             ;" c709 colour "$(cx c709)" &
  mut CL2 h264/dec/recon_top.sv "+ {2'd0, sps_col[24]};" ";" c709f colour "$(cx c709f)" &
  mut CL3 h264/dec/recon_top.sv "cs_hd <= (cs_w >= 13'd1280)" "cs_hd <= (cs_w > 13'd1280)" chd colour "$(cx chd)" &
  mut CL4 h264/dec/recon_top.sv "cs_w  <= {1'b0, w_mbs, 4'd0}  - (sps.frame_cropping ? {1'b0, cs_lr, 1'b0} : 13'd0);" "cs_w  <= {1'b0, w_mbs, 4'd0};" ccrop colour "$(cx ccrop)" &
  mut CL5 h264/dec/recon_top.sv "default:          begin cs_bysize = 1'b1; cs_bad = 1'b1; end" "default:          begin cs_bysize = 1'b1; cs_bad = 1'b0; end" cgbr colour "$(cx cgbr)" &
  mut CL6 h264/dec/recon_top.sv "if (stream_colour >= 3'd1 && stream_colour <= 3'd6)" "if (1'b0)" cscol colour "$(cx cscol)" &
  mut CL7 h264/dec/recon_top.sv "8'd9:             cs_mat = 2'd2;" "8'd9:             cs_mat = 2'd1;" c2020 colour "$(cx c2020)" &
  mut CL8 h264/dec/recon_hdr.sv "F_transfer_characteristics:        c_stage[15:8] <= cv_q;" "F_transfer_characteristics:        c_stage[23:16] <= cv_q;" c2020 colour "$(cx c2020)" &
  mut CL9 h264/dec/recon_top.sv "|| (cs_h > 13'd576);" "|| (cs_h >= 13'd576);" c576 colour "$(cx c576)" &
  mut CL10 h264/dec/recon_hdr.sv "localparam logic [31:0] C_DEFAULT = {3'd0, 3'd0, 1'b0, 1'b0, 8'd2, 8'd2, 8'd2};" "localparam logic [31:0] C_DEFAULT = {3'd0, 3'd0, 1'b0, 1'b0, 8'd2, 8'd2, 8'd6};" cnone colour "$(cx cnone)" &
  mut CL11 h264/dec/recon_top.sv "8'd2, 8'd3:       cs_bysize = 1'b1;" "8'd2:             cs_bysize = 1'b1;" cres colour "$(cx cres)" &
  mut CL12 h264/dec/recon_top.sv "cs_h  <= {1'b0, hf_mbs, 4'd0}" "cs_h  <= {2'b0, hf_mbs, 3'd0}" ctall colour "$(cx ctall)" &
  wait
  # (docs/chroma.md §4) the chroma siting, each on its own clip's [colour]
  mut CL13 h264/dec/recon_hdr.sv "c_stage[28:26] <= cbig_q ? 3'd0 : cv_q[2:0];" "c_stage[28:26] <= 3'd0;" sit1 colour "$(cx sit1)" &
  mut CL14 h264/dec/recon_hdr.sv "c_stage[31:29] <= cbig_q ? 3'd0 : cv_q[2:0];" "c_stage[31:29] <= 3'd0;" sit5 colour "$(cx sit5)" &
  mut CL15 h264/dec/recon_top.sv "pinfo_siting <= sps_sit;" "pinfo_siting <= 6'd0;" sit2 colour "$(cx sit2)" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
