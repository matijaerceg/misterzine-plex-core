#!/usr/bin/env bash
# run_cavlc.sh [--red] [--quick] -- the CAVLC -> CABAC rewriter of the client library
# (hps/lib/h264ring_cavlc.c, fj#20, docs/cavlc.md) on the host: every CAVLC stream it rewrites
# must decode to the same pictures, every one it refuses must be refused by name.
#
# Fixtures (generated into .sim/cavlc_test, never committed; regenerated when RECIPE changes):
#   x264 through ffmpeg  ultrafast (High CAVLC), Constrained Baseline, High CAVLC with the 8x8
#                        transform, B pictures (temporal direct, weighted P, 4 references), four
#                        slices, QP 4; MBAFF and 4:2:2 (refused); a CABAC stream (passed)
#   JM lencod            field pictures (+ P_8x8ref0), Intra_8x8 only, B pictures -- when
#                        $H264_REFS_DIR/JM/build_enc/bin/lencod.exe exists (tools/jm_build.sh)
#   tools/cavlc_synth.py the paths no encoder reaches: all-zero coded 8x8 blocks, a picture that
#                        needs cabac_zero_words, I_PCM; redundant pictures, data partitioning, an
#                        invalid code; ASO and truncation made from the x264 clips
#   H.264.1 conformance  every AVCv1 stream in $H264_REFS_DIR (skipped without it; --quick: a
#                        dozen): rewritten, refused (FMO, SP/SI, MBAFF) or passed (CABAC)
# Arms, each a separate verdict per fixture:
#   [tables]   tools/gen_cavlc_tables.py --check (the PDF; needs $H264_REFS_DIR) and
#              tools/gen_hps_tables.py --check (the C header is what the generator writes)
#   [pixels]   ffmpeg's frame MD5s of the original == of the rewrite (decoded with -xerror)
#   [refyuv]   the rewrite decoded == the conformance package's reference YUV
#   [model]    tools/cavlc_check.py: the project's CABAC model decodes the rewrite, its bin count
#              equals the rewriter's, the 7.4.2.10 bin limit holds per picture, the SPS / PPS rules
#   [engines]  the default engine and the spec's (-DCV_SPEC_ENGINE) write the same bytes
#   [verdict]  a refused / malformed stream gets that verdict, with its reason named
#   [pass]     a CABAC stream comes out byte for byte as it went in
#   [cover]    the synthetic streams reach their paths (the rewriter's own counters)
# --red: mutations of a COPY of the library (built from the copy), each caught by its own arm.
set -u
cd "$(dirname "$0")/../.."
W=.sim/cavlc_test
mkdir -p "$W/fix" "$W/out"
red=0; quick=0
for a in "$@"; do
  case $a in --red) red=1 ;; --quick) quick=1 ;; *) echo "usage: run_cavlc.sh [--red] [--quick]"; exit 2 ;; esac
done
REFS=${H264_REFS_DIR:-$HOME/h264-refs}
for t in gcc make ffmpeg python3 unzip cmp md5sum; do
  command -v "$t" >/dev/null || { echo "run_cavlc: $t is needed"; exit 2; }
done
fail=0
note() { echo "  $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# ---- build: the library's tool, and the same source with the spec's engine ----
echo "== build =="
rm -f hps/build/host/cavlc2cabac "$W/c2c_spec"
make -C hps >/dev/null 2>"$W/build.log" || { cat "$W/build.log"; echo "run_cavlc: hps/ build failed"; exit 2; }
CFL=(-O2 -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -Werror)
build_c2c() {   # out srcroot [defs...] -- cavlc2cabac from the tree at srcroot
  local out=$1 root=$2; shift 2
  gcc "${CFL[@]}" "$@" -I"$root/include" -I"$root/lib" -o "$out" "$root/cavlc2cabac/cavlc2cabac.c" \
      "$root/lib/h264ring_cavlc.c" "$root/lib/h264ring_au.c"
}
build_c2c "$W/c2c_spec" hps -DCV_SPEC_ENGINE || { echo "run_cavlc: the spec-engine build failed"; exit 2; }
FAST=hps/build/host/cavlc2cabac
SPEC=$W/c2c_spec
note "cavlc2cabac and the spec-engine variant built"

echo "== [tables] =="
if python3 tools/gen_hps_tables.py --check | grep -q matches; then note "PASS [tables] hps/lib/h264ring_cavlc_tab.h"
else bad "[tables] hps/lib/h264ring_cavlc_tab.h differs from tools/gen_hps_tables.py"; fi
if python3 tools/cavlc_synth.py --c-header hps/tests/cavlc_fixtures.h --check | grep -q matches; then
  note "PASS [tables] hps/tests/cavlc_fixtures.h (test_ring's streams)"
else bad "[tables] hps/tests/cavlc_fixtures.h differs from tools/cavlc_synth.py --c-header"; fi
if [ -f "$REFS/T-REC-H.264-202606.pdf" ]; then
  if out=$(python3 tools/gen_cavlc_tables.py --check 2>&1) && echo "$out" | grep -q "matches the PDF" &&
     echo "$out" | grep -q "every value agrees"; then note "PASS [tables] tools/cavlc_tables.py == the PDF == ffmpeg"
  else bad "[tables] $out"; fi
else note "SKIP [tables] the PDF (no \$H264_REFS_DIR)"; fi

# ---- fixtures ----
RECIPE=4
stamp="$RECIPE $(ffmpeg -version | head -1)"
if [ ! -f "$W/fix/recipe" ] || [ "$(cat "$W/fix/recipe")" != "$stamp" ]; then
  echo "== fixtures (generated) =="
  rm -rf "$W/fix"; mkdir -p "$W/fix"
  src="testsrc2=size=352x288:rate=30,noise=alls=8:allf=t+u"
  x264() {   # name extra-ffmpeg-args...
    local n=$1; shift
    ffmpeg -nostdin -v error -y -f lavfi -i "$src" -frames:v 30 "$@" -an -f h264 "$W/fix/$n.264" ||
      { echo "run_cavlc: x264 fixture $n failed"; exit 2; }
  }
  x264 x_uf     -c:v libx264 -preset ultrafast -profile:v high -b:v 2M -pix_fmt yuv420p
  x264 x_base   -c:v libx264 -preset medium -profile:v baseline -b:v 1M -pix_fmt yuv420p
  x264 x_hi8    -c:v libx264 -preset medium -profile:v high -x264-params cabac=0:8x8dct=1 -b:v 1500k -pix_fmt yuv420p
  x264 x_hib    -c:v libx264 -preset slow -profile:v high -x264-params cabac=0:bframes=3:ref=4:weightp=2:direct=temporal -b:v 1500k -pix_fmt yuv420p
  x264 x_slices -c:v libx264 -preset medium -profile:v main -x264-params cabac=0:slices=4 -b:v 1M -pix_fmt yuv420p
  x264 x_qp     -c:v libx264 -preset fast -profile:v high -x264-params cabac=0:qp=4 -pix_fmt yuv420p
  x264 x_mbaff  -c:v libx264 -preset medium -profile:v high -x264-params cabac=0:interlaced=1:tff=1 -b:v 1M -pix_fmt yuv420p
  x264 x_422    -c:v libx264 -preset medium -profile:v high422 -x264-params cabac=0 -b:v 1M -pix_fmt yuv422p
  x264 x_cabac  -c:v libx264 -preset medium -profile:v high -b:v 1M -pix_fmt yuv420p
  for c in $(python3 tools/cavlc_synth.py --list | awk '{print $1}'); do
    case $c in
      aso) python3 tools/cavlc_synth.py aso "$W/fix/x_slices.264" "$W/fix/s_aso.264" ;;
      cut) python3 tools/cavlc_synth.py cut "$W/fix/x_uf.264" "$W/fix/s_cut.264" ;;
      *) python3 tools/cavlc_synth.py "$c" "$W/fix/s_$c.264" ;;
    esac || { echo "run_cavlc: cavlc_synth $c failed"; exit 2; }
  done
  if [ -x "$REFS/JM/build_enc/bin/lencod.exe" ]; then
    for c in field i8 b; do
      H264_REFS_DIR=$REFS python3 tools/cavlc_synth.py jm "$c" "$W/fix/j_$c.264" || { echo "run_cavlc: JM $c failed"; exit 2; }
    done
  fi
  echo "$stamp" > "$W/fix/recipe"
fi

# conformance: unpacked once into .sim/cavlc_test/conf/NAME
CONF=()
if [ -d "$REFS/H.264.1_bitstreams/AVCv1" ]; then
  QUICK="BA1_Sony_D CI1_FT_B CVPCMNL1_SVA_C CVFI1_Sony_D Sharp_MP_PAFF_1r2 CVSE3_Sony_H MR6_BT_B CVFC1_Sony_C FM1_BT_B sp1_bt_a CVMA1_TOSHIBA_B CABA1_SVA_B"
  for z in "$REFS"/H.264.1_bitstreams/AVCv1/*.zip; do
    n=$(basename "$z" .zip)
    if [ $quick = 1 ] && ! echo " $QUICK " | grep -qi " $n "; then continue; fi
    [ -d "$W/conf/$n" ] || { mkdir -p "$W/conf/$n"; unzip -q -o "$z" -d "$W/conf/$n"; }
    CONF+=("$n")
  done
fi
confbs() { find "$W/conf/$1" -iregex '.*\.\(264\|26l\|jsv\|avc\|h264\|jvt\|bit\|bits\)$' | head -1; }

# expectations: exact | pass | refused:REGEX | error:REGEX
expect() {
  case $1 in
    x_mbaff|CVMA1_Sony_D|CVMA1_TOSHIBA_B|CVMANL1_TOSHIBA_B|CVMANL2_TOSHIBA_B|CVMAQP2_Sony_G|CVMAQP3_Sony_D|CVMAPAQP3_Sony_E|CVCANLMA2_Sony_C|cavlc_mot_mbaff0_full_B)
      echo "refused:MBAFF" ;;
    x_422) echo "refused:chroma_format_idc" ;;
    FM1_BT_B|FM1_FT_E|FM2_SVA_C) echo "refused:FMO" ;;
    SP1_BT_A|sp2_bt_b) echo "refused:SP / SI" ;;
    s_z8_intra_qpd) echo "refused:not expressible" ;;
    s_redundant) echo "refused:redundant" ;;
    s_dp) echo "refused:data partitioning" ;;
    s_aso) echo "refused:ASO" ;;
    s_badcode) echo "error:no such code" ;;
    s_cut) echo "error:cut short" ;;
    x_cabac) echo "pass" ;;
    *) echo "exact" ;;
  esac
}

fmd5() {   # [strict] file -> "frames md5" of ffmpeg's per-frame MD5s, empty on a decode error
  local strict=() f
  if [ "$1" = strict ]; then strict=(-err_detect explode -xerror); shift; fi
  f=$1
  local o
  o=$(ffmpeg -nostdin -v error "${strict[@]}" -i "$f" -f framemd5 - 2>/dev/null) || return 0
  o=$(echo "$o" | grep -v '^#' | awk -F, '{print $NF}')
  [ -n "$o" ] && echo "$(echo "$o" | wc -l) $(echo "$o" | md5sum | cut -c1-32)"
}

# check ARM NAME IN EXPECT FAST SPEC -> prints one verdict line, returns 0 / 1
check() {
  local arm=$1 name=$2 in=$3 exp=$4 fast=$5 spec=$6 o msg rc
  o="$W/out/$name.$$.$RANDOM.264"
  msg=$("$fast" "$in" "$o" 2>&1); rc=$?
  case $arm in
    pixels)
      [ $rc = 0 ] || { echo "FAIL [pixels] $name: rc $rc: ${msg##*: }"; rm -f "$o"; return 1; }
      local a b; a=$(fmd5 "$in"); b=$(fmd5 strict "$o")
      if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "PASS [pixels] $name: ${a%% *} frames"
      else echo "FAIL [pixels] $name: original '$a' rewrite '$b'"; rm -f "$o"; return 1; fi ;;
    refyuv)
      [ $rc = 0 ] || { echo "FAIL [refyuv] $name: rc $rc"; rm -f "$o"; return 1; }
      local y ok=0
      ffmpeg -nostdin -v error -i "$o" -fps_mode passthrough -f rawvideo -pix_fmt yuv420p "$o.yuv" 2>/dev/null
      while IFS= read -r y; do cmp -s "$y" "$o.yuv" && ok=1; done < <(find "$W/conf/$name" -iname '*.yuv')
      rm -f "$o.yuv"
      if [ $ok = 1 ]; then echo "PASS [refyuv] $name"; else echo "FAIL [refyuv] $name: no reference YUV matches"; rm -f "$o"; return 1; fi ;;
    model)
      [ $rc = 0 ] || { echo "FAIL [model] $name: rc $rc"; rm -f "$o"; return 1; }
      local bins r
      bins=$(echo "$msg" | sed -n 's/.* \([0-9]*\) bins,.*/\1/p')
      if r=$(timeout 1800 python3 tools/cavlc_check.py "$in" "$o" --bins "$bins" 2>&1); then echo "PASS [model] $name: ${r#cavlc_check: OK }"
      else echo "FAIL [model] $name: $(echo "$r" | head -2 | tr '\n' ' ')"; rm -f "$o"; return 1; fi ;;
    engines)
      [ $rc = 0 ] || { echo "FAIL [engines] $name: rc $rc"; rm -f "$o"; return 1; }
      "$spec" -q "$in" "$o.spec" >/dev/null 2>&1
      if cmp -s "$o" "$o.spec"; then echo "PASS [engines] $name"
      else echo "FAIL [engines] $name: the two engines' bytes differ"; rm -f "$o" "$o.spec"; return 1; fi
      rm -f "$o.spec" ;;
    verdict)
      local want=${exp%%:*} why=${exp#*:} code
      code=$([ "$want" = refused ] && echo 2 || echo 3)
      if [ $rc = "$code" ] && echo "$msg" | grep -q "$why"; then echo "PASS [verdict] $name: ${msg#*: unit }"
      else echo "FAIL [verdict] $name: wanted $want ($why), got rc $rc: $msg"; rm -f "$o"; return 1; fi ;;
    pass)
      if [ $rc = 0 ] && echo "$msg" | grep -q "(0 rewritten)" && cmp -s "$in" "$o"; then echo "PASS [pass] $name: byte for byte"
      else echo "FAIL [pass] $name: rc $rc, $(echo "$msg" | cut -c1-120)"; rm -f "$o"; return 1; fi ;;
    cover)
      local field
      case $name in s_z8_*) field="all-zero 8x8 blocks" ;; s_zw) field="cabac_zero_words" ;; s_pcm) field="I_PCM" ;; j_field) field="P_8x8ref0" ;; esac
      local v; v=$(echo "$msg" | sed -n "s/.* \([0-9]*\) $field.*/\1/p")
      if [ $rc = 0 ] && [ -n "$v" ] && [ "$v" -gt 0 ]; then echo "PASS [cover] $name: $v $field"
      else echo "FAIL [cover] $name: $field '$v'"; rm -f "$o"; return 1; fi ;;
  esac
  rm -f "$o"
  return 0
}

# every fixture: NAME FILE
FIX=()
for f in "$W"/fix/*.264; do FIX+=("$(basename "$f" .264) $f"); done
for n in "${CONF[@]}"; do b=$(confbs "$n"); [ -n "$b" ] && FIX+=("$n $b"); done

echo "== GREEN: ${#FIX[@]} fixtures =="
# the arms each fixture gets
arms_for() {   # name expectation in -> arm list
  local n=$1 e=$2 in=$3
  case $e in
    refused:*|error:*) echo verdict; return ;;
    pass) echo pass; return ;;
  esac
  local a="pixels engines"
  case $n in s_*|j_*|x_base|x_hi8|x_slices|BA1_Sony_D|CVPCMNL1_SVA_C|CVFI1_Sony_D|Sharp_MP_PAFF_1r2|CVSE3_Sony_H|MR6_BT_B|CI1_FT_B) a="$a model" ;; esac
  case $n in s_z8_*|s_zw|s_pcm|j_field) a="$a cover" ;; esac
  case $in in "$W"/conf/*) find "$W/conf/$n" -iname '*.yuv' | grep -q . && a="$a refyuv" ;; esac
  echo "$a"
}
LOG=$W/green.log; : > "$LOG"
# conformance CABAC streams pass: decided by a first run (no expectation table for 51 streams)
run_one() {
  local n=$1 in=$2 e
  e=$(expect "$n")
  if [ "$e" = exact ] && [ "${in#"$W"/conf/}" != "$in" ]; then
    "$FAST" "$in" /dev/null 2>/dev/null | grep -q "(0 rewritten)" && e=pass
  fi
  local arm
  for arm in $(arms_for "$n" "$e" "$in"); do check "$arm" "$n" "$in" "$e" "$FAST" "$SPEC"; done
}
export -f run_one check fmd5 expect arms_for
export W FAST SPEC
printf '%s\n' "${FIX[@]}" | xargs -P "$(nproc)" -L1 bash -c 'run_one "$0" "$1"' >> "$LOG"
sort -k2,2 -k3 "$LOG" | sed 's/^/  /'
np=$(grep -c "^PASS" "$LOG"); nf=$(grep -c "^FAIL" "$LOG")
note "$np verdicts PASS, $nf FAIL"
[ "$nf" = 0 ] && [ "$np" -gt 0 ] || fail=1
for arm in pixels model engines verdict pass cover; do
  grep -q "^PASS \[$arm\]" "$LOG" || bad "[$arm] no fixture reached this arm"
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mk_copy() { mkdir -p "$1"; cp -r hps/include hps/lib hps/cavlc2cabac "$1/"; }
  CTL=$(mktemp -d); mk_copy "$CTL"
  if (cd "$CTL" && build_c2c c2c . && build_c2c c2c_spec . -DCV_SPEC_ENGINE) &&
     check pixels x_uf "$W/fix/x_uf.264" exact "$CTL/c2c" "$CTL/c2c_spec" >/dev/null &&
     check engines x_uf "$W/fix/x_uf.264" exact "$CTL/c2c" "$CTL/c2c_spec" >/dev/null; then
    note "control: the unmutated copy passes"
  else bad "CONTROL: the unmutated copy does not pass"; fi
  rm -rf "$CTL"
  mut() {   # name old new fixture arm
    local name=$1 old=$2 new=$3 fx=$4 arm=$5 d
    d=$(mktemp -d); mk_copy "$d"
    if ! python3 - "$d/lib/h264ring_cavlc.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "mutation anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)" > "$RES/$name"; echo MUTFAIL >> "$RES/$name"; rm -rf "$d"; return; fi
    if ! (cd "$d" && build_c2c c2c . 2>build.log && build_c2c c2c_spec . -DCV_SPEC_ENGINE 2>>build.log); then
      { echo "  $name: harness failure (build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    local f; f=$(ls "$W"/fix/"$fx".264 2>/dev/null || confbs "$fx")
    [ -n "$f" ] || { echo "  $name: SKIP (no fixture $fx)" > "$RES/$name"; rm -rf "$d"; return; }
    local out; out=$(check "$arm" "$fx" "$f" "$(expect "$fx")" "$d/c2c" "$d/c2c_spec")
    if [ "${out%% *}" = FAIL ]; then echo "  $name: caught by $(echo "$out" | cut -c6-140)" > "$RES/$name"
    else { echo "  $name: SURVIVED -- [$arm] on $fx cannot see it"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  export -f build_c2c mk_copy
  # the CABAC side (9.3.3.1 derivations, binarisations, the engine)
  mut M1  "cab_bin(c, (s->st == ST_P ? 11 : 24) + (s->A && !s->A->skip) + (s->B && !s->B->skip), 0);" \
          "cab_bin(c, (s->st == ST_P ? 11 : 24) + (s->A && !s->A->skip), 0);" x_uf pixels &
  mut M2  "inc = sum > 32 ? 2 : sum > 2 ? 1 : 0;" "inc = sum > 2 ? 1 : 0;" x_hib pixels &
  mut M3  "bits = (mt + 4) >> 1;" "bits = (mt + 5) >> 1;" x_hib pixels &
  mut M4  "            cab_bin(c, 399 + inc_t8(s), cur->t8);" "            cab_bin(c, 399, cur->t8);" x_hi8 pixels &
  mut M5  "            cur->cbf_luma |= (uint16_t)(0xFu << (4 * b8));" "" x_hi8 pixels &
  mut M6  "                b->p[b->n - 1]++;               /* never 0xFF: those are held back */" "" x_uf pixels &
  mut M7  "        unsigned inc0 = gt1 ? 0 : (1 + eq1 < 4 ? 1 + eq1 : 4);" "        unsigned inc0 = gt1 ? 0 : (eq1 < 4 ? eq1 : 4);" x_base pixels &
  mut M8  "    bw_put(c->w, ((c->low >> 7) & 3) | 1, 2);" "    bw_put(c->w, ((c->low >> 7) & 3), 2);" x_uf engines &
  mut M9  "    unsigned sig_off = (s->field ? 277 : 105) + CAT_OFF_SIG[cat];" "    unsigned sig_off = 105 + CAT_OFF_SIG[cat];" j_field pixels &
  mut M10 "    cab_start(s->c);                             /* 9.3.1.2 after the samples */" "" s_pcm pixels &
  # the CAVLC side (9.2) and the macroblock layer
  mut M11 "        return (a + b + 1) >> 1;" "        return (a + b) >> 1;" x_base pixels &
  mut M12 "        if ((lv[i] < 0 ? -lv[i] : lv[i]) > (3 << (sl - 1)) && sl < 6)" "        if ((lv[i] < 0 ? -lv[i] : lv[i]) > (3 << (sl - 1)) && sl < 5)" x_qp pixels &
  mut M13 "                    res->l8[b8][4 * k->pos[j] + b] = k->lev[j];" "                    res->l8[b8][4 * b + k->pos[j]] = k->lev[j];" x_hi8 pixels &
  mut M14 "    s->B = s->addr >= s->w && b->addr == s->addr - s->w && b->slice == s->slice ? b : NULL;" "    s->B = s->addr >= s->w && b->addr == s->addr - s->w ? b : NULL;" x_slices pixels &
  mut M15 "    memset(s->cur->tc, 16, sizeof s->cur->tc);" "" s_pcm pixels &
  mut M16 "                unsigned r = 0;                  /* P_8x8ref0: not coded in CAVLC, 0 (7.4.5) */" "                unsigned r = 1;" j_field pixels &
  # the 8x8 rule (docs/cavlc.md S3)
  mut M17 "            if (!cur->intra && zero == coded)" "            if (0)" s_z8_inter_qpd pixels &
  mut M18 "                cbp &= ~zero;                    /* the block not coded: same levels, same QP */" "" s_z8_mixed pixels &
  mut M19 "            cv->stats.t8_zero_blocks++;" "" s_z8_inter cover &
  # 9.3.4.6, the bin count, the headers
  mut M20 "            k = (need - cv->pic_bytes + 2) / 3;" "            k = 0;" s_zw model &
  mut M21 "e_q++; E_OUT(c); e_bins++; } while (0)" "e_q++; E_OUT(c); } while (0)" x_base model &
  mut M22 "                    prof = 77;" "" x_base model &
  # refusals and errors
  mut M23 "    } else if (h.first_mb < cv->pic_next_mb) {" "    } else if (0) {" s_aso verdict &
  mut M24 "    if (q.redundant_pic_cnt_present)
        q.refuse" "    if (0)
        q.refuse" s_redundant verdict &
  mut M25 "        } else if (t >= 2 && t <= 4) {" "        } else if (0) {" s_dp verdict &
  mut M26 "    if (s->mbaff && !h->field_pic) {" "    if (0) {" x_mbaff verdict &
  mut M27 "        if (b.err)                               /* whatever the parse tripped on first */" "        if (0)" s_cut verdict &
  mut M28 "                    s->refuse = 1;" "" s_z8_intra_qpd verdict &
  mut M29 "            s.refuse = \"chroma_format_idc other than 4:2:0\";" "" x_422 verdict &
  # the pass-through
  mut M30 "!cv->pps[pid].valid || cv->pps[pid].cabac) {" "!cv->pps[pid].valid) {" x_cabac pass &
  wait
  for f in $(ls "$RES" | sort -V); do head -1 "$RES/$f"; done
  if grep -lq MUTFAIL "$RES"/* 2>/dev/null; then fail=1; fi
  rm -rf "$RES"
fi

if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; exit 1; fi
