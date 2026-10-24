#!/usr/bin/env bash
# run_disp_reader.sh -- the display plumbing: h264/ddr_mux2.sv (two masters on one DDRAM
# port with the mount abort; in emu master A is the decoder's DPB and master B is tied off
# until Phase 3's ring reader (UMD's B is its compressed-video buffer) --
# bench/h264/ddr_mux2_tb.sv) and h264/disp_reader.sv (a DPB store on the 720x480 raster,
# frame and field pair, bench/h264/disp_reader_tb.sv). docs/display.md, docs/h264_recon.md
# S4. (UMD's se_cdc, the retired P4 clocking fallback, and its two arms are not carried.)
#
# GREEN: ddr_mux2_tb twice -- the model's default latency, and a long one that fills the
# 16-entry owner FIFO (+need_full) -- every beat to its owner in order, the model's rules
# held (no write during reads, no read inside an open write burst), B served while A is
# busy, both aborts clean; disp_reader_tb (the reader fed by h264/disp_fit.sv) on every
# deinterlace variant at the identity fit (P5f) and every fitted case (P6 step 3), each dot
# {de, R, G, B} against tools/disp_golden.py, LAT 5: [rgb] a frame (the BT.601 conversion
# of the store's samples, chroma interpolated at the identity -- docs/display.md "Chroma at the
# identity"); [field] the same
# store as a field pair, woven (ffmpeg separatefields); [pass] the frame in Bob and in Blend
# (untouched); [blend] the pair in Blend (ffmpeg's interlace lowpass; both edges' mirrors
# are its first and last lines); [bob] the pair in Bob keeping either field; [single] one
# field in Weave and in Blend (bobbed on its own field); [il] (P6) the 480i raster -- a
# frame, and a field pair with the menu on Blend -- shown as woven fields, chroma nearest (not the
# identity: disp_want_frame_il / field_il), every pixel two
# dots; [fit] the fitted pictures of bench/h264/fixtures/gen/disp_fit_cases.txt
# (480x272 up, 720x576 pillarboxed, 854x480 letterboxed and under Crop, 480x854 portrait,
# the 704x480 10:11 snap, 192x2048 decimated 2 x 4, 2048x192 decimated 2, 640x480
# stretched) against the render golden (the design's formulas), and (P6 step 4) six at
# 480i with anti-twitter (720x480 Fit: the (1, 2, 1), which the golden checks against
# ffmpeg's interlace lowpass within a code; 854x480 and 480x854 letterboxed; 192x2048 at
# dv 4 (8-row boxes); 2048x192 at the W > 40 cap; 352x240 scaled up), and (P6 step 6) five
# on the 50 Hz raster's 576 lines (854x480 letterboxed on 576p, 720x576 12:11 snapped at 576i,
# a cropped 1024x352 at 576i with anti-twitter, paired Area-only / Anti-Twitter 1280x534 fits), and (interface 0.11) four 1280x720 -- Fit at
# 480p (dh 2: 640 stored), letterboxed at 480i with and without anti-twitter, at 576i -- read
# from a 3,600-macroblock 2 MiB store, and (docs/analog.md §11b) thirteen under the Area pre-filter
# (+flt=1: 480p, 480i, with anti-twitter, 576i, paired 1280x534 PAL with / without anti-twitter, a 720x1280 portrait at odd W (the flush), 2048x448
# past the fetch budget, 192x2048, an upscale that stays the Sharp control's) -- which
# tools/disp_golden.py also checks independently of the arithmetic (impulses' centroids, a ramp,
# chroma's tap nearest the unshifted position); [colour] (0.16, docs/colour.md) the frame under each
# colour code 2-6 against tools/colour_ref.py's integers (derived from Kr / Kb, not the RTL's table),
# and the code changed mid-frame (+colswap) leaving that refresh in its old code; [late] every run: no line began before its
# rows were fetched (found the first budget rule too loose: wide_sm, 2026-10-04). The cases
# without +flt are the Sharp control: the fit before the Area pre-filter, bit-identical to main's.
# At most DISP_JOBS (default 6) simulations at once.
#
# --red: mutations on a COPY of the RTL, each caught by its own arm:
#   X1  mux: a write no longer waits for outstanding reads          -> [ddr]
#   X2  mux: an abort no longer swallows A's read beats              -> [abort]
#   X3  mux: an abort no longer completes the open write burst       -> [count] (the port hangs)
#   X4  mux: the completing beats written unmasked                   -> [abort]
#   X5  mux: the owner FIFO's full guard removed                     -> [data] or the model's credit rule [ddr]
#   X6  mux: B only when A is idle (no fairness)                     -> [count]
#   X7  mux: a request A withdraws under waitrequest is not held     -> [avalon] (the reload hang)
#   X8  mux: B's write burst no longer pins the grant (P6a)          -> [grant] / the model's [ddr]
#   X9  mux: B's write no longer waits for outstanding reads         -> [ddr]
#   X10 mux: a blocked B write gives the grant back (flip-flops)     -> [grant] / [count] (B starves)
#   X11 mux: B's write beats carry A's data                          -> [data] / [avalon] (the data
#       changes under waitrequest)
#   X12 mux: the grant handed to B while an orphan is re-presented   -> [ddr] (B's read inside A's
#       burst: the latent bug the live B found, 2026-09-27; the long-latency arm)
#   D1  disp: the Cr coefficient of R 409 -> 408 (code 1's)          -> [rgb]
#   the colour codes (0.16, docs/colour.md; [colour] on the code named):
#   C1  disp: code 3's (709 limited) Krv 459 -> 458                  -> [colour] c3
#   C2  disp: code 2's (601 full) Y offset 16, not 0                 -> [colour] c2
#   C3  disp: code 4's (709 full) Kbg 48 -> 47                       -> [colour] c4
#   C4  disp: code 5's (2020 limited) Kbb 548 -> 547                 -> [colour] c5
#   C5  disp: code 6's (2020 full) Krg 146 -> 145                    -> [colour] c6
#   C6  disp: code 2's Kc 298, not 256 (the full range's luma)       -> [colour] c2
#   C7  disp: the code ignored (always BT.601 limited)               -> [colour] c3
#   C8  disp: the code not latched per refresh (read live)           -> [colour] colswap
#   D3  disp: dot 0 read with the previous line's slots              -> [rgb]
#   K1  disp: the blend's rounding +1 -> +2 (luma)                   -> [blend]
#   K3  disp: bob keeps the other field                              -> [bob]
#   K4  disp: the bob's rebuilt line rounds down                     -> [bob]
#   K5  disp: no top mirror (row 0's a = row -1)                     -> [blend]
#   K6  disp: no bottom mirror (the last row's d = the row below)    -> [blend]
#   K8  disp: frames filtered too (the field gate dropped)           -> [pass]
#   K9  disp: a single field follows the menu (not always bobbed)    -> [single]
#   K10 disp: the mode never latched (always Weave)                  -> [blend]
#   480i (P6, docs/analog.md; [il]: the raster interlaced, two fields scored, every pixel on
#   both of its dots, against the Weave golden whatever the menu says):
#   I1  disp: the column advanced every dot at 480i (dots read as pixels) -> [il]
#   I2  disp: the deinterlacer left on at 480i (a pair in Blend)     -> [il]
#   the fit (P6 step 3, [fit] on the case named; [late] on the identity frame):
#   R1  disp: the horizontal blend's weight dropped                  -> [fit] p640
#   R2  disp: the vertical blend's weight dropped                    -> [fit] v
#   R3  disp: the box's rounding dropped (s = 1)                     -> [fit] wide
#   R4  disp: the accumulator ignored (the last row alone, dv 4)     -> [fit] tall
#   R5  disp: the crop's left origin ignored                         -> [fit] w
#   R7  disp: the rectangle's offset ignored in the position         -> [fit] v
#   (R8, the current line's slots unprotected, is EQUIVALENT under today's eviction: rows
#   only increase within a refresh and a victim is an invalid slot or the lowest row, so with
#   four slots and at most three in use it is always one above the line -- measured, it
#   survived; the protection stays as the guard for any other eviction policy)
#   R9  disp: fetch_late counts every line                           -> [late]
#   R10 disp: the crop's top origin ignored                          -> [fit] v
#   anti-twitter (P6 step 4, docs/analog.md §9):
#   (§11b: anti-twitter's sliding rows are now the vertical pre-filter's code 4 -- the same integers)
#   T1  disp: the luma box dv rows, not 2 dv (no sliding)            -> [fit] at_id
#   T2  disp: the half-row shift dropped (the pre-filter's S / 8)    -> [fit] at_w
#   T4  disp: the taps clamp to kmax (the box past the picture)      -> [fit] at_id
#   T5  disp: the sliding box's rounding dropped (s = 0)             -> [fit] at_id
#   T6  disp: the dv-4 shift of the sliding rows wrong               -> [fit] at_tall
#   the 576-line raster (P6 step 6):
#   P1  disp: the active lines stop at 480                           -> [fit] pal_n
#   P3  disp: the progressive active lines stop at 480 (not sync_gen's frame) -> [nat] nat_pal (stage 2)
#   P2  disp: the 576i field's last line at 480i's (261 / 262)       -> [fit] pal_n / [count]
#   the Area pre-filter (docs/analog.md §11b; its fit cases from tools/disp_golden.py, which also checks
#   them against impulses, a ramp and chroma's nearest tap independently of the arithmetic):
#   F1  disp: Area's horizontal A = 3 taken as 2                     -> [fit] hd_area
#   F2  disp: a row's last word never flushed                        -> [fit] port_area (odd W)
#   F3  disp: the first box's weight 8 (not 8 - A: the sum past 8)   -> [fit] hd_area
#   F5  disp: Area's rows one box (only anti-twitter's two)          -> [fit] port_area
#   F6  disp: the columns' centre offset dropped                     -> [fit] hd_area
#   F7  disp: the next word's lane not read (the word replicated)    -> [fit] hd_area
#   F8  disp: the columns clamped to kmax (the box past the crop)    -> [fit] p_area
#   the 2 MiB stores (interface 0.11, 1280x720: [fit] hd, a 3,600-macroblock store at store 17):
#   H1  disp: the store shift 17 (1 MiB stores)                      -> [fit] hd / [ddr] (outside the window)
#   H2  disp: Cr's plane offset in 17 bits (40 W HF = 144,000 wraps)  -> [fit] hd
#   (docs/chroma.md) siting-aware bilinear chroma on every output (the golden's chroma_line, checked against
#   ffmpeg's in_chroma_loc upsampling at all six sitings, a ramp at every fitted case, the worked positions):
#   N1  disp: the horizontal weight ignored (row 0's Cb)             -> [rgb]
#   N2  disp: the vertical blend's first weight 256 (not 256 - w)    -> [rgb]
#   N3  disp: a field store's chroma rows frame-wise (not 2 k + p)   -> [field]
#   N4  disp: Bob's rebuilt line from its own field (not the kept)   -> [bob]
#   N5  disp: the bottom field's siting taken as the top's           -> [field] field_s16
#   N6  disp: the bottom-sited types' vertical offset 0 (not 1)      -> [rgb] s5
#   N7  disp: the centred types' horizontal offset dropped           -> [rgb] s1
#   N8  disp: the chroma column's (dh - 1) dropped                   -> [fit] hd
#   N9  disp: the second chroma tap not clamped (the right edge)     -> [rgb]
#   N10 disp: a frame's chroma row position without (dv - 1)         -> [fit] tall
#   N11 disp: a chroma row's source rows not x dv                    -> [fit] tall
#   (2026-10-12, found by MiSTer_UMD_Video: a field store's chroma at Figure E-1's FIELD siting -- field p's
#   offset (voff + p) / 2 of its own line pair; the golden's field rule checked against ffmpeg's interlaced
#   upsampling, scale=interl=1, at all six sitings, and shown distinct from the old field-centred rule)
#   N12 disp: the field-centred rule (a field's offset the frame's voff)  -> [field]
#   N13 disp: the bottom field's extra half line dropped (voff / 2 both)  -> [field]
#   N14 disp: a field's offset not halved (voff + p)                      -> [field]
#   (the vertical weight zeroed below the crop is an EQUIVALENT mutant: there both taps are the first row)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
# at most DISP_JOBS simulations at once (each ~0.5 GB: fifty at once -- 2026-10-04, the Downscale
# Filter's cases -- exhausted the workstation's memory and took the IDE down)
MAXJ=${DISP_JOBS:-6}
throttle() { while [ "$(jobs -rp | wc -l)" -ge "$MAXJ" ]; do wait -n; done; }
red=0; [ "${1:-}" = "--red" ] && red=1
MODEL=bench/h264/ddr_model.sv
python3 tools/disp_golden.py > /dev/null || { echo "FAIL: golden"; exit 1; }

run_arm() {  # label sim-files tb marker plusargs
  local label=$1 files=$2 tb=$3 marker=$4 args=$5
  # shellcheck disable=SC2086
  rm -f .sim/${label}_sim   # iverilog leaves the old binary on a failed build: never run it
  iverilog -g2012 -Ih264 -o .sim/${label}_sim $files $tb 2>&1 | grep -v "sorry\|warning"
  # shellcheck disable=SC2086
  if [ -f .sim/${label}_sim ] && timeout 1200 vvp -n .sim/${label}_sim $args > .sim/${label}.log 2>&1 && grep -q "^PASS: $marker" .sim/${label}.log; then
    echo "  PASS $label: $(grep "^$marker:" .sim/${label}.log | sed "s/^$marker: //")"
  else echo "  FAIL $label"; grep FAIL .sim/${label}.log | head -3; fail=1; fi
}
echo "== GREEN: ddr_mux2 =="
run_arm mux2 "h264/ddr_mux2.sv $MODEL" bench/h264/ddr_mux2_tb.sv ddr_mux2_tb ""
run_arm mux2_long "h264/ddr_mux2.sv $MODEL" bench/h264/ddr_mux2_tb.sv ddr_mux2_tb "+need_full +lat_min=60 +lat_max=90 +wait_pct=5"
echo "== GREEN: disp_reader =="
G=bench/h264/fixtures/gen
DF="h264/sync_gen.sv h264/disp_fit.sv h264/disp_reader.sv $MODEL"
DT=bench/h264/disp_reader_tb.sv
# shellcheck disable=SC2086
rm -f .sim/disp_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -Ih264 -o .sim/disp_sim $DF $DT 2>&1 | grep -v "sorry\|warning"
disp_arm() {  # label plusargs -- one compile, the arms in parallel
  local label=$1 args=$2
  # shellcheck disable=SC2086
  if timeout 1200 vvp -n .sim/disp_sim $args > .sim/${label}.log 2>&1 && grep -q "^PASS: disp_reader_tb" .sim/${label}.log; then
    echo "  PASS $label: $(grep "^disp_reader_tb:" .sim/${label}.log | sed "s/^disp_reader_tb: //")" > .sim/${label}.res
  else { echo "  FAIL $label"; grep FAIL .sim/${label}.log | head -3; echo DISPFAIL; } > .sim/${label}.res; fi
}
# shellcheck disable=SC2034
DISP_ARMS=(
  "disp|+arm=rgb"
  "disp_field|+arm=field +field +want=$G/disp_want_field.hex"
  "disp_pass_bob|+arm=pass +mode=1"
  "disp_pass_blend|+arm=pass +mode=2 +parity=1"
  "disp_blend|+arm=blend +field +mode=2 +want=$G/disp_want_blend.hex"
  "disp_bob0|+arm=bob +field +mode=1 +parity=0 +want=$G/disp_want_bob0.hex"
  "disp_bob1|+arm=bob +field +mode=1 +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_single_w|+arm=single +field +single +mode=0 +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_single_l|+arm=single +field +single +mode=2 +parity=0 +want=$G/disp_want_bob0.hex"
  "disp_il|+arm=il +il +want=$G/disp_want_frame_il.hex"
  "disp_il_field|+arm=il +il +field +mode=2 +want=$G/disp_want_field_il.hex"
  "disp_colswap|+arm=colour +colswap=3"
)
for c in 2 3 4 5 6; do DISP_ARMS+=("disp_c$c|+arm=colour +colour=$c +want=$G/disp_want_frame_c$c.hex"); done
# (docs/chroma.md) the frame at every other chroma siting (both fields' types t: 9 t), and a field pair whose
# fields differ (top 0, bottom 2: 16)
for t in 1 2 3 4 5; do DISP_ARMS+=("disp_s$t|+arm=rgb +siting=$((9 * t)) +want=$G/disp_want_frame_s$t.hex"); done
DISP_ARMS+=("disp_field_s16|+arm=field +field +siting=16 +want=$G/disp_want_field_s16.hex")
# the fitted cases (P6 step 3): their plusargs from the golden's case table
fit_args() {   # name -> the plusargs of that case
  local line; line=$(grep "^$1 " $G/disp_fit_cases.txt)
  set -- $line
  local a="+arm=fit +store=$G/disp_store_fit_$1.hex +want=$G/disp_want_fit_$1.hex +w=$2 +hf=$3 +cl=$5 +cr=$6 +ct=$7 +cb=$8 +sarw=$9 +sarh=${10} +fmode=${11}"
  [ "$4" = 1 ] && a="$a +cuy4"
  [ "${12}" = 1 ] && a="$a +il"
  [ "${13}" = 1 ] && a="$a +at"
  [ "${14}" = 1 ] && a="$a +pal"
  echo "$a +flt=${15} +siting=${16}"
}
for c in $(cut -d' ' -f1 $G/disp_fit_cases.txt); do DISP_ARMS+=("disp_fit_$c|$(fit_args "$c")"); done
# (hdmi_raster stage 2) the native cases: raster_geom's raster, the picture 1:1 on it
nat_args() {   # name -> the plusargs of that case
  local line; line=$(grep "^$1 " $G/disp_nat_cases.txt)
  set -- $line
  local a="+arm=nat +store=$G/disp_store_nat_$1.hex +want=$G/disp_want_nat_$1.hex +w=$2 +hf=$3 +cl=$5 +cr=$6 +ct=$7 +cb=$8 +sarw=$9 +sarh=${10} +fmode=2"
  [ "$4" = 1 ] && a="$a +cuy4"
  [ "${11}" = 2 ] && a="$a +pal"
  echo "$a +nat +nw=${12} +nh=${13} +nl=${14} +nnt=${15} +nlast=${16} +siting=${17}"
}
for c in $(cut -d' ' -f1 $G/disp_nat_cases.txt); do DISP_ARMS+=("disp_$c|$(nat_args "$c")"); done
for a in "${DISP_ARMS[@]}"; do disp_arm "${a%%|*}" "${a#*|}" & throttle; done
wait
for a in "${DISP_ARMS[@]}"; do
  l=${a%%|*}; grep -v '^DISPFAIL$' .sim/$l.res; grep -q '^DISPFAIL$' .sim/$l.res && fail=1
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new tb arm(s regex) other-files plusargs
    local name=$1 file=$2 old=$3 new=$4 tb=$5 arm=$6 others=$7 args=${8:-}
    local d; d=$(mktemp -d)
    cp "$file" "$d/"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # shellcheck disable=SC2086
    if [ $? != 0 ] || ! iverilog -g2012 -Ih264 -o "$d/sim" "$d/$(basename "$file")" $others "$tb" 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    timeout 1200 vvp -n "$d/sim" $args > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  M=h264/ddr_mux2.sv; MT=bench/h264/ddr_mux2_tb.sv; D=h264/disp_reader.sv; DT=bench/h264/disp_reader_tb.sv
  BL="+arm=blend +field +mode=2 +want=$G/disp_want_blend.hex"
  mut X1 $M "wire a_wr_blocked = a_write && (a_wburst == 8'd0) && reads_out;" "wire a_wr_blocked = 1'b0;" $MT "ddr" "$MODEL" & throttle
  mut X2 $M "reads_out && !own[o_rd] && !a_flush;" "reads_out && !own[o_rd];" $MT "abort" "$MODEL" & throttle
  mut X3 $M "ddr_write = (a_wburst != 8'd0);" "ddr_write = 1'b0;" $MT "count" "$MODEL" & throttle
  mut X4 $M "ddr_writedata = a_writedata; ddr_byteenable = 8'h00;" "ddr_writedata = a_writedata; ddr_byteenable = 8'hFF;" $MT "abort" "$MODEL" & throttle
  mut X5 $M "wire         own_full  = o_cnt[4];" "wire         own_full  = 1'b0;" $MT "data|ddr" "$MODEL" "+need_full +lat_min=60 +lat_max=90 +wait_pct=5" & throttle
  mut X6 $M "if (b_req && !orphan && ((a_rd_acc) ||" "if (b_req && !orphan && ((1'b0) ||" $MT "count" "$MODEL" & throttle
  mut X7 $M "wire         orphan  = h_valid && !grant && (a_flush || !a_same);" "wire         orphan  = 1'b0;" $MT "avalon" "$MODEL" & throttle
  wait
  mut X8 $M "if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0)) grant <= 1'b0;" "if (b_rd_acc || b_wr_acc || !b_req) grant <= 1'b0;" $MT "grant|ddr" "$MODEL" & throttle
  mut X9 $M "wire b_wr_blocked = b_write && (b_wburst == 8'd0) && reads_out;" "wire b_wr_blocked = 1'b0;" $MT "ddr" "$MODEL" & throttle
  mut X10 $M "if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0)) grant <= 1'b0;" "if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0) || b_wr_blocked) grant <= 1'b0;" $MT "grant|count" "$MODEL" & throttle
  mut X11 $M "ddr_writedata = b_writedata; ddr_byteenable = 8'hFF;" "ddr_writedata = a_writedata; ddr_byteenable = 8'hFF;" $MT "data|avalon" "$MODEL" & throttle
  mut X12 $M "if (b_req && !orphan && ((a_rd_acc)" "if (b_req && ((a_rd_acc)" $MT "ddr" "$MODEL" "+need_full +lat_min=60 +lat_max=90 +wait_pct=5" & throttle
  O="h264/sync_gen.sv h264/disp_fit.sv $MODEL"
  mut D1 $D "cf_rv <= 10'd409;" "cf_rv <= 10'd408;" $DT "rgb" "$O" & throttle
  mut D3 $D "wire  [1:0]  e_sa = dot0 ? nx_sa : cur_sa, e_sb = dot0 ? nx_sb : cur_sb," "wire  [1:0]  e_sa = dot0 ? nx_sa : cur_sa, e_sb = cur_sb," $DT "rgb" "$O" & throttle
  mut K1 $D "{1'd0, s4_hb, 1'b0} + {2'd0, s4_hd} + 10'd1;" "{1'd0, s4_hb, 1'b0} + {2'd0, s4_hd} + 10'd2;" $DT "blend" "$O" "$BL" & throttle
  mut K3 $D "(e_par == pic_parity)" "(e_par != pic_parity)" $DT "bob" "$O" "+arm=bob +field +mode=1 +parity=0 +want=$G/disp_want_bob0.hex" & throttle
  mut K4 $D "wire  [8:0]  ym = {1'd0, s4_ya} + {1'd0, s4_hd} + 9'd1;" "wire  [8:0]  ym = {1'd0, s4_ya} + {1'd0, s4_hd};" $DT "bob" "$O" "+arm=bob +field +mode=1 +parity=1 +want=$G/disp_want_bob1.hex" & throttle
  mut K5 $D "ln_ra <= (ln_k0 == kmin_y) ? ((ln_k0 == kmax_y) ? ln_k0 : ln_k0 + 12'd1) : ln_k0 - 12'd1;" "ln_ra <= ln_k0 - 12'd1;" $DT "blend" "$O" "$BL" & throttle
  mut K6 $D "ln_rd <= (ln_k0 == kmax_y) ? ((ln_k0 == kmin_y) ? ln_k0 : ln_k0 - 12'd1) : ln_k0 + 12'd1;" "ln_rd <= ln_k0 + 12'd1;" $DT "blend" "$O" "$BL" & throttle
  mut K8 $D "wire         kern_ok_now = ident && pic_field;" "wire         kern_ok_now = ident;" $DT "pass" "$O" "+arm=pass +mode=2 +parity=1" & throttle
  mut K9 $D "wire         bob  = pic_field && (pic_single || k_mode == 2'd1);" "wire         bob  = pic_field && (k_mode == 2'd1);" $DT "single" "$O" "+arm=single +field +single +mode=0 +parity=1 +want=$G/disp_want_bob1.hex" & throttle
  mut K10 $D "if (ln_first) begin tag_v <= '0; ctag_v <= '0; k_mode <= deint_mode; k_col <= pic_colour; k_sit <= pic_siting; end" "if (ln_first) begin tag_v <= '0; ctag_v <= '0; k_mode <= 2'd0; k_col <= pic_colour; k_sit <= pic_siting; end" $DT "blend" "$O" "$BL" & throttle
  wait
  mut I1 $D "else if (!il || (h_pos[0] && h_pos != 12'd1)) xacc <=" "else if (1'b1) xacc <=" $DT "il" "$O" "+arm=il +il +want=$G/disp_want_frame_il.hex" & throttle
  mut I2 $D "wire         ident = !il && (r_sx" "wire         ident = (r_sx" $DT "il" "$O" "+arm=il +il +field +mode=2 +want=$G/disp_want_field_il.hex" & throttle
  mut R1 $D "s3_db * \$signed({1'b0, s3_w})" "s3_db * \$signed(9'sd0)" $DT "fit" "$O" "$(fit_args p640)" & throttle
  mut R2 $D "{1'b0, s4_hd} * {1'b0, s4_wy}" "{1'b0, s4_hb} * {1'b0, s4_wy}" $DT "fit" "$O" "$(fit_args v)" & throttle
  mut R3 $D "3'd1: out_l[i] = (hq[i] + 21'd64)   >> 7;" "3'd1: out_l[i] = hq[i] >> 7;" $DT "fit" "$O" "$(fit_args wide)" & throttle
  mut R4 $D "sum_l[i] = (p_first ? 17'd0 : acc_q[17*i +: 17]) + {2'd0, wst[i]};" "sum_l[i] = {2'd0, wst[i]};" $DT "fit" "$O" "$(fit_args tall)" & throttle
  mut R5 $D "pos0_c <= \$signed({17'd0, r_lx, 16'd0})" "pos0_c <= \$signed(45'sd0)" $DT "fit" "$O" "$(fit_args w)" & throttle
  mut H1 $D "store_base = DPB_BASE + {6'd0, m_store, 18'd0};" "store_base = DPB_BASE + {7'd0, m_store, 17'd0};" $DT "fit|ddr" "$O" "$(fit_args hd)" & throttle
  mut H2 $D "store_base + {3'd0, pm_r, 5'd0} + {5'd0, pm_r, 3'd0} + lc_r;" "store_base + {12'd0, 17'({3'd0, pm_r, 5'd0} + {5'd0, pm_r, 3'd0})} + lc_r;" $DT "fit" "$O" "$(fit_args hd)" & throttle
  wait
  mut R7 $D "pos0_p <= pos0_a + (pos0_b <<< 14);" "pos0_p <= 45'sd0;" $DT "fit" "$O" "$(fit_args v)" & throttle
  mut R9 $D "wire         cmd_pending = (cmd_done_s2 != cmd_tog);" "wire         cmd_pending = 1'b1;" $DT "late" "$O" & throttle
  mut R10 $D "ln_pt <= \$signed({16'd0, r_ty, 16'd0}) + ln_prod" "ln_pt <= ln_prod" $DT "fit" "$O" "$(fit_args v)" & throttle
  mut T1 $D "wire  [4:0]  rows_m1 = ((plane == 2'd0 && m_vpf != 3'd0) ? {dv_n, 1'b0} : {1'b0, dv_n}) - 5'd1;" "wire  [4:0]  rows_m1 = {1'b0, dv_n} - 5'd1;" $DT "fit" "$O" "$(fit_args at_id)" & throttle
  mut T2 $D "c_vo   <= ({40'd0, (4'd1 << r_dv) - 4'd1} << 15) + ({40'd0, sh_v} << (5'd13 + {3'd0, r_dv}));" "c_vo   <= ({40'd0, (4'd1 << r_dv) - 4'd1} << 15);" $DT "fit" "$O" "$(fit_args at_w)" & throttle
  wait
  mut T4 $D "kmax_y <= tyh_d - {10'd0, nx_v};" "kmax_y <= tyh_d;" $DT "fit" "$O" "$(fit_args at_id)" & throttle
  mut T5 $D "3'd0: out_l[i] = (hq[i] + 21'd32)   >> 6;" "3'd0: out_l[i] = hq[i] >> 6;" $DT "fit" "$O" "$(fit_args at_id)" & throttle
  mut T6 $D "+ ({40'd0, sh_v} << (5'd13 + {3'd0, r_dv}));" "+ ({40'd0, sh_v} << (5'd13 + {4'd0, r_dv[0]}));" $DT "fit" "$O" "$(fit_args at_tall)" & throttle
  mut P1 $D "ln_act <= pic_valid && (nxt_line < (il ? (pal ? 12'd576 : 12'd480) : lines));" "ln_act <= pic_valid && (nxt_line < (il ? 12'd480 : lines));" $DT "fit" "$O" "$(fit_args pal_n)" & throttle
  # (hdmi_raster stage 2) the progressive raster's active lines from sync_gen's frame, not 480
  mut P3 $D "ln_act <= pic_valid && (nxt_line < (il ? (pal ? 12'd576 : 12'd480) : lines));" "ln_act <= pic_valid && (nxt_line < (il ? (pal ? 12'd576 : 12'd480) : 12'd480));" $DT "nat" "$O" "$(nat_args nat_pal)" & throttle
  mut P2 $D "(fl == (pal ? 11'd311 : 11'd261))" "(fl == 11'd261)" $DT "fit|count" "$O" "$(fit_args pal_n)" & throttle
  wait
  # (docs/analog.md §11b) the Downscale Filter, each on the case that must see it
  mut F1 $D "3'd3:    had[i] = {{3{hdf[i][17]}}, hdf[i]} + {{2{hdf[i][17]}}, hdf[i], 1'b0};" "3'd3:    had[i] = {{2{hdf[i][17]}}, hdf[i], 1'b0};" $DT "fit" "$O" "$(fit_args hd_area)" & throttle
  mut F2 $D "                    hf_v <= hn_end;" "                    hf_v <= 1'b0;" $DT "fit" "$O" "$(fit_args port_area)" & throttle
  mut F3 $D "!f_box          ? 4'd8 - {1'b0, m_vpf} : {1'b0, m_vpf};" "!f_box          ? 4'd8 : {1'b0, m_vpf};" $DT "fit" "$O" "$(fit_args hd_area)" & throttle
  mut F5 $D "wire  [4:0]  rows_m1 = ((plane == 2'd0 && m_vpf != 3'd0) ? {dv_n, 1'b0} : {1'b0, dv_n}) - 5'd1;" "wire  [4:0]  rows_m1 = ((plane == 2'd0 && m_vpf == 3'd4) ? {dv_n, 1'b0} : {1'b0, dv_n}) - 5'd1;" $DT "fit" "$O" "$(fit_args port_area)" & throttle
  mut F6 $D " - 45'sd32768 - \$signed({20'd0, c_ho});" " - 45'sd32768;" $DT "fit" "$O" "$(fit_args hd_area)" & throttle
  mut F7 $D "        hx[8] = hf_v ? hp[7] : hn[0];" "        hx[8] = hp[7];" $DT "fit" "$O" "$(fit_args hd_area)" & throttle
  mut F8 $D "kmax_x <= ((r_lx + r_wc - 12'd1) >> r_dh) - {10'd0, nx_h};" "kmax_x <= ((r_lx + r_wc - 12'd1) >> r_dh);" $DT "fit" "$O" "$(fit_args p_area)" & throttle
  wait
  ca() { echo "+arm=colour +colour=$1 +want=$G/disp_want_frame_c$1.hex"; }
  mut C1 $D "cf_rv <= 10'd459;" "cf_rv <= 10'd458;" $DT "colour" "$O" "$(ca 3)" & throttle
  mut C2 $D "3'd2:    begin cf_yoff <= 5'd0;" "3'd2:    begin cf_yoff <= 5'd16;" $DT "colour" "$O" "$(ca 2)" & throttle
  mut C3 $D "cf_bg <= 10'd48;  cf_rg <= 10'd120;" "cf_bg <= 10'd47;  cf_rg <= 10'd120;" $DT "colour" "$O" "$(ca 4)" & throttle
  mut C4 $D "cf_bb <= 10'd548;" "cf_bb <= 10'd547;" $DT "colour" "$O" "$(ca 5)" & throttle
  mut C5 $D "cf_rg <= 10'd146;" "cf_rg <= 10'd145;" $DT "colour" "$O" "$(ca 6)" & throttle
  mut C6 $D "cf_c <= 10'd256; cf_rv <= 10'd359;" "cf_c <= 10'd298; cf_rv <= 10'd359;" $DT "colour" "$O" "$(ca 2)" & throttle
  wait
  mut C7 $D "        case (k_col)" "        case (3'd1)" $DT "colour" "$O" "$(ca 3)" & throttle
  mut C8 $D "        case (k_col)" "        case (pic_colour)" $DT "colour" "$O" "+arm=colour +colswap=3" & throttle
  wait
  # (docs/display.md "Chroma at the identity") chroma interpolated at the identity fit
  wait
  # (docs/chroma.md) the chroma resampler, each on the arm that must see it
  mut N1 $D "s3_du0 * \$signed({1'b0, s3_cwx})" "s3_du0 * \$signed(9'sd0)" $DT "rgb" "$O" & throttle
  mut N2 $D "wire  [8:0]  iwc  = 9'd256 - {1'b0, s4_cwy};" "wire  [8:0]  iwc  = 9'd256;" $DT "rgb" "$O" & throttle
  mut N3 $D "c_r0 <= cfield ? {c_k0[10:0], c_cp} : c_k0;" "c_r0 <= c_k0;" $DT "field" "$O" "+arm=field +field +want=$G/disp_want_field.hex" & throttle
  mut N4 $D "wire         c_cpn  = c_bob ? pic_parity : c_pn;" "wire         c_cpn  = c_pn;" $DT "bob" "$O" "+arm=bob +field +mode=1 +parity=0 +want=$G/disp_want_bob0.hex" & throttle
  mut N5 $D "(cfield && c_cpn) ? k_sit[5:3] : k_sit[2:0]" "k_sit[2:0]" $DT "field" "$O" "+arm=field +field +siting=16 +want=$G/disp_want_field_s16.hex" & throttle
  mut N6 $D "(c_typ <= 3'd3) ? 17'h00000 : 17'h10000" "(c_typ <= 3'd3) ? 17'h00000 : 17'h00000" $DT "rgb" "$O" "+arm=rgb +siting=45 +want=$G/disp_want_frame_s5.hex" & throttle
  wait
  mut N7 $D "pos0c1 <= pos0c0 - 45'sd32768;" "pos0c1 <= pos0c0;" $DT "rgb" "$O" "+arm=rgb +siting=9 +want=$G/disp_want_frame_s1.hex" & throttle
  mut N8 $D " - \$signed({25'd0, (4'd1 << r_dh) - 4'd1, 16'd0});" ";" $DT "fit" "$O" "$(fit_args hd)" & throttle
  mut N9 $D "(s0_ck + 29'sd1 > \$signed({17'd0, ckmax_x})) ? ckmax_x[9:0] : s0_ck[9:0] + 10'd1;" "s0_ck[9:0] + 10'd1;" $DT "rgb" "$O" & throttle
  mut N10 $D ": (ln_pos - \$signed({24'd0, (4'd1 << r_dv) - 4'd1, 16'd0}));" ": ln_pos;" $DT "fit" "$O" "$(fit_args tall)" & throttle
  mut N11 $D "wire  [14:0] c_src0 = {3'd0, f_crow} << m_dv;" "wire  [14:0] c_src0 = {3'd0, f_crow};" $DT "fit" "$O" "$(fit_args tall)" & throttle
  wait
  # (2026-10-12) a field store's chroma at Figure E-1's field siting
  FA="+arm=field +field +want=$G/disp_want_field.hex"
  mut N12 $D "((c_a >>> 1) - \$signed({27'd0, c_vf}))" "((c_a >>> 1) - \$signed({27'd0, c_voff}))" $DT "field" "$O" "$FA" & throttle
  mut N13 $D "wire  [17:0] c_vfs = {1'b0, c_voff} + {1'b0, c_cp, 16'd0};" "wire  [17:0] c_vfs = {1'b0, c_voff};" $DT "field" "$O" "$FA" & throttle
  mut N14 $D "wire  [16:0] c_vf  = c_vfs[17:1];" "wire  [16:0] c_vf  = c_vfs[16:0];" $DT "field" "$O" "$FA" & throttle
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
