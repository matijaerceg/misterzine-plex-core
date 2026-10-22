#!/usr/bin/env bash
# run_cosim.sh -- the decoder cosim: the decoder as emu composes it (h264/dec/h264_top.sv ->
# h264/dec/recon_top.sv, bench/h264/cosim_top.sv) Verilated with the C++ harness
# bench/h264/cosim_main.cpp (its DDR model is ddr_model.sv's), fed a window of an Annex-B
# stream as ES bytes and scored against tools/cosim_golden.py: the model's decode-order
# pictures, the model itself checked against ffmpeg on the same window first.
# docs/h264_recon.md S5.
#
# Arms (cosim_main.cpp): [pre] every macroblock pre-deblock, [post] every picture in the
# DDR model, [count] pictures / macroblocks / no error or refusal on either half, [hang]
# a macroblock within 200,000 cycles, [ddr] the Avalon rules, [out] every store emitted in
# the model's output order and at its time (P5d), [hold] no write into a store the
# display holds (the harness is the display: random holds, then releases).
#
#   run_cosim.sh [--frames N (120)]     GREEN: two x264 720x480p59.94 windows made at run time
#                                        (refs-free, needs libx264) -- x264_film (sub-pixel
#                                        scroll + noise, B pyramid, weights, deblocking offsets)
#                                        and x264_sun (shaped like a stock Sunshine session:
#                                        P only, 1 reference, 1 slice, a one-frame VBV at 8
#                                        Mbit/s) -- and, with $H264_REFS_DIR, two field streams
#                                        (cabac_mot_fld0_full, CAPA1_TOSHIBA_B); and (P3h)
#                                        x264_sun_ring: x264_sun through the HPS interface
#                                        (+ring: hps/lib writes the records, ring_rd reads them
#                                        beside the DPB on ddr_mux2; every picture PTS-tagged;
#                                        its cycles a macroblock against x264_sun's are the
#                                        ring's cost on ram1); and (P5a) x264_sunh: x264_sun
#                                        as High with the 8x8 transform (what a stock host
#                                        sends): the refs-free High window -- the real
#                                        Sunshine captures are not in the repository (--sweep
#                                        --dir them: docs/high_profile.md S6); and (fj#20)
#                                        x264_uf_ring: x264 ultrafast's High CAVLC through the
#                                        interface -- the library's write call rewrites it into
#                                        CABAC, scored against the golden of cavlc2cabac's
#                                        rewrite (docs/cavlc.md)
#   run_cosim.sh --sweep [--jobs J (5)] [--frames N] [--dir DIR]... [--match GLOB]...
#                                        every H.264.1 CABAC package in $H264_REFS_DIR and
#                                        every Annex-B file (.264 .h264 .26l .jsv .jvt .avc) in
#                                        each --dir; a table in .sim/cosim/sweep.tsv
#   run_cosim.sh --red                   mutations on a COPY of the RTL (compiled from
#                                        inside the copy: iverilog / Verilator resolve
#                                        `include "h264/..." against the working directory),
#                                        each caught by its own arm on a 12-frame window of
#                                        x264_film ("film") or cabac_mot_fld0_full ("fld";
#                                        the RED arm needs $H264_REFS_DIR), or 4 frames of a
#                                        lossless noise clip x264 codes as I_PCM ("pcm": the
#                                        only refs-free way to put emulation-prevention
#                                        bytes in decoded data, asserted; film has none):
#     C1 mc_interp: the half-sample 6-tap's 20 as 16             (film) -> [pre]
#     C2 deblock_bs: coded coefficients give bS 1, not 2          (film) -> [post]
#     C3 recon_inter: no opposite-parity chroma offset (T 8-10)   (fld)  -> [pre]
#     C4 nal_parser: emulation prevention bytes kept              (pcm)  -> [pre] / [count] / [hang] / [out]
#        (on the pcm window the kept EPB breaks the first slice's parse: nothing is decoded and
#        the end-of-stream check fires first -- "[out] 0 stores emitted, the model emits 4")
#     C5 recon_mb: the DDR arbiter grants a write inside a burst  (film) -> [hang] / [pre] / [post] / [ddr]
#     (C6, dpb_mem: a write issued with read beats outstanding, RETIRED at P3h: the cosim
#      now has ddr_mux2 in front of the DPB, as emu does, and the mux itself holds a write
#      while read beats are outstanding -- the mutant is invisible at the port; run_dpb_mem.sh
#      M1 catches it against the raw DDR model)
#     C7 recon_dpb: the bump takes the LARGEST POC                (fld)  -> [out]
#     (C8, the VUI's DPB size one larger, RETIRED at P3d: every cosim window limits its
#      reordering in its VUI or is POC type 2, so the early output decides first and the
#      mutant is equivalent here; run_recon_top.sh O2 catches it on c44d)
#     C9 ring_rd: the PTS mark never raised                        (sunring) -> [count]
#     C10 ring_rd: END_OF_STREAM never flushes the decoder         (sunring) -> [hang] / [out] / [count]
#     C11 recon_dpb: max_num_reorder_frames ignored (P3d: the store held until the DPB fills) (sunring) -> [out]
#   (UMD ran these windows from Akira and Family Guy disc images; the fork's fixtures are
#   generated or from H.264.1: docs/harvest.md.)
#
# Verdicts per stream: PASS (with cycles a macroblock and frames/s at 81 MHz under the DDR
# model; "x real time" against the stream's pic_timing SEI, else 59.94 frames/s -- for the
# conformance packages that number means nothing), FAIL [arm], SKIP (no IDR, no pictures),
# REFUSED (the model refuses the stream: a scoping decision such as CAVLC, MBAFF or, until
# Phase 5, High profile -- the core must refuse it loudly too; not a decode failure),
# ORACLE (the model and ffmpeg disagree: the window is not scored). Exit 0 only when
# nothing FAILs and no ORACLE mismatch occurs. Needs verilator, ffmpeg, unzip.
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/cosim
mkdir -p $W
REFS=$(realpath -m "${H264_REFS_DIR:-$HOME/h264-refs}")
export H264_REFS_DIR="$REFS"   # absolute, for the tools that read it themselves (they run from other directories)
AVC="$REFS/H.264.1_bitstreams/AVCv1"
frames=120; sweep=0; red=0; jobs=5; matches=(); dirs=()
while [ $# -gt 0 ]; do
  case $1 in
    --frames) frames=$2; shift;;
    --sweep) sweep=1;;
    --red) red=1;;
    --jobs) jobs=$2; shift;;
    --match) matches+=("$2"); shift;;
    --dir) dirs+=("$2"); shift;;
  esac
  shift
done
command -v verilator >/dev/null || { echo "run_cosim: SKIP -- no verilator"; exit 2; }

FE="h264/dec/nal_parser.sv h264/dec/rbsp_reader.sv h264/dec/sps_pps.sv h264/dec/slice_hdr.sv
    h264/dec/cabac_ctx.sv h264/dec/cabac_engine.sv h264/dec/mb_syntax.sv h264/dec/au_pts.sv h264/dec/sei_pt.sv h264/dec/h264_top.sv"
RC="h264/fifo_dc.sv h264/sfifo.sv h264/dec/dpb_mem.sv h264/dec/recon_hdr.sv h264/dec/recon_dpb.sv
    h264/dec/recon_lists.sv h264/dec/dsf_calc.sv h264/dec/recon_slice_tab.sv h264/dec/mb_intake.sv
    h264/dec/mv_pred.sv h264/dec/mc_interp.sv h264/dec/wpred.sv h264/dec/recon_inter.sv
    h264/dec/intra_pred.sv h264/dec/high_tables.sv h264/dec/dequant_itrans.sv h264/dec/dequant_itrans8.sv h264/dec/deblock_bs.sv h264/dec/deblock_filter.sv
    h264/dec/recon_deblock.sv h264/dec/recon_mb.sv h264/dec/recon_top.sv"
# P3h, ring mode: the HPS interface's reader, the status block, the port mux (and hps/lib in the harness)
RING="h264/cdc.sv h264/ddr_mux2.sv h264/ring_rd.sv h264/ring_stat.sv h264/ring_words_sys.sv h264/ring_words_mem.sv"
RTL="h264/dec/h264_pkg.sv $FE $RC $RING"

build() {       # SRC_DIR OBJ_DIR -> OBJ_DIR/cosim, compiled from inside SRC_DIR
  local src=$1 obj=$2
  # shellcheck disable=SC2086
  (cd "$src" && verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
     -Wno-fatal -Wno-lint -Wno-style -Wno-LATCH -Wno-MULTIDRIVEN -I. --top-module cosim_top \
     -CFLAGS "-I$ROOT/hps/include -I$ROOT/hps/lib" \
     -Mdir "$obj" -o cosim -MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2' \
     $RTL "$ROOT/bench/h264/cosim_top.sv" "$ROOT/bench/h264/cosim_main.cpp" \
     "$ROOT/hps/lib/h264ring.c" "$ROOT/hps/lib/h264ring_au.c" \
     "$ROOT/hps/lib/h264ring_cavlc.c") > "$obj.build.log" 2>&1 \
     && [ -x "$obj/cosim" ]
}

golden() {      # STREAM STEM [frames] -> exit status of cosim_golden.py, its line in STEM.golden.log
  python3 tools/cosim_golden.py --es "$1" --out "$2" --frames "${3:-$frames}" > "$2.golden.log" 2>&1
}

# the x264 windows (720x480 at 59.94, 300 frames made once; a window takes --frames of them)
X264_SRC="testsrc2=size=720x480:rate=60000/1001,scroll=h=0.0013:v=0.0021,noise=alls=8:allf=t:all_seed=7"
x264_clip() {   # name x264-params [profile (main)] -> $W/<name>.264
  [ -s "$W/$1.264" ] && return 0
  ffmpeg -v error -f lavfi -i "$X264_SRC" -frames:v 300 -c:v libx264 -profile:v "${3:-main}" -pix_fmt yuv420p \
    -x264-params "$2" -bsf:v h264_mp4toannexb -f h264 -y "$W/$1.264.tmp" && mv "$W/$1.264.tmp" "$W/$1.264"
}
make_x264() {   # -> 0 when the three x264 windows exist
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264 || return 1
  x264_clip x264_film "cabac=1:8x8dct=0:bframes=2:b-pyramid=normal:ref=3:weightp=2:keyint=120:min-keyint=120:scenecut=0:crf=24:deblock=1,-2:subme=7" \
  && x264_clip x264_sun "cabac=1:8x8dct=0:bframes=0:ref=1:slices=1:keyint=infinite:scenecut=0:weightp=0:bitrate=8000:vbv-maxrate=8000:vbv-bufsize=134:nal-hrd=cbr:sliced-threads=0" \
  && x264_clip x264_sunh "cabac=1:8x8dct=1:bframes=0:ref=1:slices=1:keyint=infinite:scenecut=0:weightp=0:bitrate=8000:vbv-maxrate=8000:vbv-bufsize=134:nal-hrd=cbr:sliced-threads=0" high
}
make_cavlc() {  # (fj#20) -> $W/x264_uf.264: 40 frames of x264 ultrafast (High CAVLC), and its CABAC rewrite;
                # without x264's SEI (the golden's window drops an SEI before the IDR: the
                # ring is fed this clip whole, so the window must be the whole clip)
  [ -s "$W/x264_uf.264" ] && [ -s "$W/x264_uf.cabac.264" ] && return 0
  make -C "$ROOT/hps" >/dev/null || return 1
  ffmpeg -v error -f lavfi -i "$X264_SRC" -frames:v 40 -c:v libx264 -profile:v high -preset ultrafast -pix_fmt yuv420p \
    -x264-params "keyint=infinite:scenecut=0:bitrate=3000:vbv-maxrate=3000:vbv-bufsize=100" \
    -bsf:v h264_mp4toannexb,filter_units=remove_types=6 -f h264 -y "$W/x264_uf.264.tmp" \
  && "$ROOT/hps/build/host/cavlc2cabac" -q "$W/x264_uf.264.tmp" "$W/x264_uf.cabac.264" \
  && mv "$W/x264_uf.264.tmp" "$W/x264_uf.264"
}
make_pcm() {    # -> $W/x264_pcm.264: 64x64 noise, lossless, every macroblock I_PCM (run_h264_top's clip)
  [ -s "$W/x264_pcm.264" ] && return 0
  ffmpeg -v error -f lavfi -i "nullsrc=size=64x64:rate=24,geq=lum='if(lt(mod(X,16),2),0,if(eq(mod(X,16),2),1,random(1)*255))':cb='random(1)*255':cr='random(1)*255'" \
    -frames:v 4 -c:v libx264 -profile:v main -pix_fmt yuv420p -x264-params "cabac=1:8x8dct=0:qp=0" \
    -bsf:v h264_mp4toannexb -f h264 -y "$W/x264_pcm.264.tmp" \
  && python3 tools/h264_synth.py "$W/x264_pcm.264.tmp" unlossless "$W/x264_pcm.264.tmp2" > /dev/null \
  && mv "$W/x264_pcm.264.tmp2" "$W/x264_pcm.264" && rm -f "$W/x264_pcm.264.tmp"   # (High 4:4:4 Predictive -> High: run_h264_top.sh)
}
conf_stream() { # PACKAGE DIR -> the path of the package's stream, unpacked into DIR
  unzip -o -q "$AVC/$1.zip" -d "$2" 2>/dev/null || return 1
  find "$2" -type f \( -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" -o -iname "*.h264" \) | head -1
}

echo "== build =="
if ! build "$ROOT" "$ROOT/$W/obj"; then echo "FAIL: build ($W/obj.build.log)"; tail -5 "$W/obj.build.log"; exit 1; fi
echo "  built $W/obj/cosim"

fail=0

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  make_x264 || { echo "  FAIL: the RED arm needs ffmpeg with libx264"; exit 1; }
  [ -f "$AVC/cabac_mot_fld0_full.zip" ] || { echo "  FAIL: the RED arm needs \$H264_REFS_DIR (cabac_mot_fld0_full)"; exit 1; }
  golden $W/x264_film.264 $W/red_film 12 || { echo "FAIL: golden (x264_film)"; cat $W/red_film.golden.log; exit 1; }
  tdir=$(mktemp -d); fs=$(conf_stream cabac_mot_fld0_full "$tdir")
  golden "$fs" $W/red_fld 12 || { echo "FAIL: golden (cabac_mot_fld0_full)"; cat $W/red_fld.golden.log; rm -rf "$tdir"; exit 1; }
  rm -rf "$tdir"
  make_pcm && golden $W/x264_pcm.264 $W/red_pcm 4 || { echo "FAIL: golden (x264_pcm)"; cat $W/red_pcm.golden.log; exit 1; }
  golden $W/x264_sun.264 $W/red_sun 12 || { echo "FAIL: golden (x264_sun)"; cat $W/red_sun.golden.log; exit 1; }
  python3 -c "import sys; d=open(sys.argv[1],'rb').read(); sys.exit(0 if d.count(b'\x00\x00\x03') >= 16 else 1)" $W/red_pcm.es \
    || { echo "FAIL: the pcm window carries no emulation-prevention bytes (C4 would be vacuous)"; exit 1; }
  for g in film fld pcm sun; do
    $W/obj/cosim $W/red_$g +label=red_$g $([ $g = sun ] && echo +ring) > $W/red_$g.log 2>&1
    grep -q "^PASS: cosim" $W/red_$g.log || { echo "FAIL: the unmutated control on red_$g"; grep -m2 FAIL $W/red_$g.log; exit 1; }
  done
  echo "  control: the four windows PASS unmutated (sun through the ring)"
  RES=$(mktemp -d)
  mut() {   # name file old new window arm
    local name=$1 file=$2 old=$3 new=$4 win=$5 arm=$6
    local d; d=$(mktemp -d)
    for f in $RTL; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
    cp h264/dec/*.svh "$d/h264/dec/"
    cp h264/*.svh "$d/h264/"                    # ring_rd includes h264/ring_iface.svh (P3h)
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # the builds one at a time (eight compilers each); the simulations in parallel
    if [ $? != 0 ] || ! flock "$ROOT/$W/build.lock" bash -c "$(declare -f build); ROOT='$ROOT' RTL='$RTL' build '$d' '$d/obj'"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local stem=$W/red_$win extra=""
    [ "$win" = sunring ] && { stem=$W/red_sun; extra=+ring; }
    timeout 3600 "$d/obj/cosim" $stem +label=$name $extra > "$d/log" 2>&1
    if grep -q "^PASS: cosim" "$d/log"; then
      { echo "  $name: SURVIVED -- the cosim cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 "FAIL\|rror" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut C1 h264/dec/mc_interp.sv "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4) + (vp2s <<< 2);" \
         "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4);" film pre &
  mut C2 h264/dec/deblock_bs.sv "else if (p_nz || q_nz)    bs_c = 3'd2;" "else if (p_nz || q_nz)    bs_c = 3'd1;" film post &
  mut C3 h264/dec/recon_inter.sv "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy + 16'sd2;" \
         "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy;" fld pre &
  mut C4 h264/dec/nal_parser.sv "wire is_epb   = (zeros >= 2'd2) && (in_byte == 8'h03);" "wire is_epb   = 1'b0;" pcm "pre|count|hang|out" &
  mut C5 h264/dec/recon_mb_fsm.svh "wire         grant_e = !aq_valid && !f_cmd_valid && e_cmd_valid && (w_left == 4'd0);" \
         "wire         grant_e = !aq_valid && !f_cmd_valid && e_cmd_valid;" film "hang|pre|post|ddr" &
  mut C7 h264/dec/recon_dpb.sv "(!best_found || sq_poc < best_poc)" "(!best_found || sq_poc > best_poc)" fld out &
  wait
  mut C9 h264/ring_rd.sv "assign es_mark   = first_byte && h_flags[RF_PTS_VALID];" "assign es_mark   = 1'b0;" sunring count &
  mut C10 h264/ring_rd.sv "if (h_vrec && h_flags[RF_END_OF_STREAM]) begin eos <= h_video; eos_seen <= 1'b1; end" "" sunring "hang|out|count" &
  mut C11 h264/dec/recon_dpb.sv "cur_nrf_on <= s.bitstream_restriction || (s.poc_type == 2'd2);" "cur_nrf_on <= 1'b0;" sunring out &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
  if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; fi
  exit $fail
fi

# one stream: STREAM-or-PACKAGE.zip LABEL -> a verdict line on stdout (the golden and logs
# under $W/sweep)
one() {         # STREAM LABEL [+ring] [ES]: ES (fj#20) -- the golden from STREAM, the ring fed ES
  local img=$1 label=$2 tmp="" stem=$W/sweep/$2 es=${4:-}
  mkdir -p $W/sweep
  if [[ ${img,,} == *.zip ]]; then
    tmp=$(mktemp -d "$ROOT/$W/unz.XXXXXX")
    local f; f=$(unzip -o -q "$img" -d "$tmp" 2>/dev/null; find "$tmp" -type f \( -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" -o -iname "*.h264" \) | head -1)
    if [ -z "$f" ]; then
      echo -e "$label\tSKIP\tno stream inside the package"; rm -rf "$tmp"; return
    fi
    img=$f
  fi
  golden "$img" "$stem"
  local rc=$?
  [ -n "$tmp" ] && rm -rf "$tmp"
  case $rc in
    0) ;;
    3) echo -e "$label\tSKIP\t$(tail -1 $stem.golden.log)"; rm -f $stem.es $stem.pre $stem.post; return;;
    4) echo -e "$label\tREFUSED\t$(grep -m1 REFUSED $stem.golden.log)"; rm -f $stem.es $stem.pre $stem.post; return;;
    5) echo -e "$label\tORACLE\t$(grep -m1 MISMATCH $stem.golden.log)"; return;;
    *) echo -e "$label\tFAIL\t[golden] $(tail -1 $stem.golden.log)"; return;;
  esac
  if [ -n "$es" ]; then          # the window must be the whole stream for ES to be its source
    if ! cmp -s "$stem.es" "$img"; then echo -e "$label\tFAIL\t[window] the golden's window is not the whole stream"; return; fi
    cp "$es" "$stem.es"
  fi
  $W/obj/cosim $stem +label="$label" ${3:-} > $stem.log 2>&1
  if grep -q "^PASS: cosim" $stem.log; then
    local l; l=$(grep -m1 "identical" $stem.log)
    echo -e "$label\tPASS\t$(grep -o '[0-9]* pictures ([0-9]* fields), [0-9]* frames' <<< "$l"); $(grep -o '[0-9]* clk_dec cycles a macroblock, [0-9.]* frames/s at [0-9.]* MHz, [0-9.]*x real time' <<< "$l")"
    rm -f $stem.es $stem.pre $stem.post          # large; kept on failure
  else
    echo -e "$label\tFAIL\t$(grep -m1 "FAIL" $stem.log | cut -c1-160)"
  fi
}

if [ $sweep = 1 ]; then
  echo "== SWEEP: every H.264.1 CABAC package in \$H264_REFS_DIR and every stream in ${dirs[*]:-(no --dir)}, $frames frames, $jobs at a time =="
  shopt -s nullglob nocaseglob nocasematch
  imgs=()
  cands=("$AVC"/CA*.zip "$AVC"/cama*.zip "$AVC"/camp*.zip "$AVC"/cabac*.zip "$AVC"/Sharp_MP*.zip)
  for d in "${dirs[@]}"; do cands+=("$d"/*.264 "$d"/*.h264 "$d"/*.26l "$d"/*.jsv "$d"/*.jvt "$d"/*.avc); done
  for f in "${cands[@]}"; do
    b=$(basename "$f")
    for m in "${matches[@]:-*}"; do
      [[ ${b%.*} == $m ]] && { imgs+=("$f"); break; }
    done
  done
  shopt -u nullglob nocaseglob nocasematch
  mapfile -t imgs < <(printf '%s\n' "${imgs[@]}" | sort -u)
  [ ${#imgs[@]} = 0 ] && { echo "  SKIP: no stream (set H264_REFS_DIR, or pass --dir)"; exit 2; }
  : > $W/sweep.tsv
  for img in "${imgs[@]}"; do
    base=$(basename "$img"); base=${base%.*}; base=${base//[^A-Za-z0-9._-]/_}
    one "$img" "$base" >> $W/sweep.tsv &
    while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
  done
  wait
  sort -o $W/sweep.tsv $W/sweep.tsv
  column -t -s $'\t' $W/sweep.tsv | sed 's/^/  /'
  for v in PASS FAIL SKIP REFUSED ORACLE; do printf "  %s %d" $v "$(cut -f2 $W/sweep.tsv | grep -cx $v)"; done; echo
  # real time is reported, not gated: the DDR model is not the rig's DDR3 (UMD's rig ran
  # 4-7 % slower than it), so a window under ~1.07x here is at risk there
  slow=$(grep -P "\tPASS\t" $W/sweep.tsv | awk -F'\t' '{ if (match($3, /([0-9.]+)x real time/, m) && m[1] + 0 < 1.07) print "    " $1 " " m[1] "x" }')
  [ -n "$slow" ] && { echo "  under 1.07x real time (at risk on the rig):"; echo "$slow"; }
  grep -qP "\t(FAIL|ORACLE)\t" $W/sweep.tsv && fail=1
else
  echo "== GREEN: x264 720x480p59.94 (refs-free) and field streams (\$H264_REFS_DIR), $frames frames each =="
  : > $W/green.tsv
  if make_x264; then
    one $W/x264_film.264 x264_film >> $W/green.tsv &
    one $W/x264_sun.264 x264_sun >> $W/green.tsv &
    one $W/x264_sun.264 x264_sun_ring +ring >> $W/green.tsv &
    # (fj#20) CAVLC through the interface: the ring fed x264 ultrafast's CAVLC, the library's write
    # call rewrites it, the decoder must match the golden made from cavlc2cabac's rewrite
    if make_cavlc; then one $W/x264_uf.cabac.264 x264_uf_ring +ring $W/x264_uf.264 >> $W/green.tsv &
    else echo -e "x264_uf_ring\tFAIL\tthe CAVLC clip or its rewrite (hps/ host build)" >> $W/green.tsv; fi
    one $W/x264_sunh.264 x264_sunh >> $W/green.tsv &
  else
    echo -e "x264\tFAIL\tno ffmpeg with libx264 (the GREEN arm's refs-free windows)" >> $W/green.tsv
  fi
  for c in cabac_mot_fld0_full CAPA1_TOSHIBA_B; do
    if [ -f "$AVC/$c.zip" ]; then one "$AVC/$c.zip" "$c" >> $W/green.tsv &
    else echo "  SKIP $c: no $AVC/$c.zip (set H264_REFS_DIR)"; fi
  done
  wait
  column -t -s $'\t' $W/green.tsv | sed 's/^/  /'
  grep -qvP "\tPASS\t" $W/green.tsv && fail=1
fi
if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; fi
exit $fail
