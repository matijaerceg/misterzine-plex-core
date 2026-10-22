#!/usr/bin/env bash
# run_vid_equiv.sh -- the SD equivalence gate (docs/hd_raster.md S8 gate 1, stage A): the 27 MHz
# rasters at the pins, this branch's raster side (clk_vid, 81 MHz, every register on the dot enable)
# against main's (clk_sys, 27 MHz) -- bench/h264/vid_equiv_tb.sv built twice. Every dot's {RGB, HS,
# VS, DE, CE_PIXEL, F1, CS, CS_EN} must be identical: the analog-first proof that moving the raster
# to its own clock changed nothing a CRT or ascal sees.
#
# Main's side is compiled from a worktree of the fork point (MAIN_SHA, .sim/equiv_main: created on
# the first run), from INSIDE it (iverilog resolves `include "h264/..." against the working
# directory first). The fixtures are the reader's fit cases and the overlay's arms (generated here
# by their models).
#
# Scenarios (case = tools/disp_golden.py's fit case -- its il / pal columns set the raster -- and
# ovl = an ovl_plane fixture): 480p 59.94 (1280x720 fitted, 8888 clipped), 480i 59.94 (854x480
# letterboxed with anti-twitter, 1555), 480i (854x480 letterboxed, a narrow canvas), 576i
# (anti-twitter, 8888), 576p (854x480 letterboxed, 4444), 480p 60.00 (640x480 stretched, 1555),
# 480i 60.00 (1280x720 letterboxed, 4444) -- every raster, every standard, every overlay format,
# the idle bars in the letterboxes' margins (vis 1).
#
# --red: mutations of this branch's RTL, each caught by its own class of difference:
#   Q1 disp_reader: the column accumulator on the clock, not the dot  -> [rgb]
#   Q2 vid_out: the sync delays on the clock                           -> [rgb] (the trace starts at a VS
#      rise at the pins: sync parting company with the colour shows as the colour, shifted)
#   Q3 vid_out: CE_PIXEL without the 480i pixel-repetition phase       -> [ce]
#   Q4 csync_smpte: its counters on the clock                          -> [cs]
#   Q5 ovl_plane: the read-out on the clock                            -> [rgb]
#   Q6 idle_bars: stage 1 on the clock                                 -> [rgb]
#   Q7 disp_reader: the slot RAMs read on the clock (a found defect)   -> [rgb]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
MAIN_SHA=947565839dc352cb8e4ad473bf725878c75459e6   # main at the fork point (PR fj#29's merge)
WT=.sim/equiv_main
G=bench/h264/fixtures/gen
MODEL=bench/h264/ddr_model.sv
TB=bench/h264/vid_equiv_tb.sv
RTL_MAIN="h264/sync_gen.sv h264/disp_fit.sv h264/disp_reader.sv h264/ovl_plane.sv h264/ovl_blend.sv h264/sfifo.sv h264/idle_bars.sv h264/csync_smpte.sv"
RTL_BR="$RTL_MAIN h264/vid_out.sv"

python3 tools/disp_golden.py > /dev/null || { echo "FAIL: the reader's golden (fixtures)"; exit 1; }
SCEN=(
  "e480p|hd|p8888clip|0"
  "e480i|at_w|i1555at|0"
  "e480i_lb|w|inarrow|0"
  "e576i|pal_at|i8888pal|2"
  "e576p|pal_w|p4444|2"
  "e480p60|p640|p1555|1"
  "e480i60|hd_il|i4444odd|1"
)
for s in "${SCEN[@]}"; do IFS='|' read -r _ _ o _ <<< "$s"; python3 tools/ovl_ref.py "$o" > /dev/null || { echo "FAIL: the overlay model ($o)"; exit 1; }; done
# (docs/chroma.md §5) NEUTRAL chroma (Cb = Cr = 128): the branch reconstructs chroma bilinearly where main took
# the nearest sample -- by design, and run_disp_reader.sh's to prove -- but both reconstruct 128 as 128, so the
# pins stay bit-exact and this gate keeps proving what it is for: the clock-domain move (luma, sync, the overlay)
mkdir -p .sim
for s in "${SCEN[@]}"; do
  IFS='|' read -r _ c _ _ <<< "$s"
  python3 - "$G/disp_store_fit_$c.hex" ".sim/veq_store_$c.hex" "$(grep "^$c " $G/disp_fit_cases.txt | cut -d' ' -f2,3)" <<'PYEOF' || { echo "FAIL: the neutral store ($c)"; exit 1; }
import sys
src, dst, wh = sys.argv[1], sys.argv[2], sys.argv[3].split()
w, hf = int(wh[0]), int(wh[1])
words = open(src).read().split()
assert len(words) >= w * hf * 48, "the store is short"
ny = w * hf * 32                                   # luma's words; then Cb's and Cr's, w hf 8 each
open(dst, "w").write("\n".join(words[:ny] + ["8080808080808080"] * (w * hf * 16) + words[w * hf * 48:]) + "\n")
PYEOF
done

args_of() {   # scenario -> plusargs
  local name case ovl std line
  IFS='|' read -r name case ovl std <<< "$1"
  line=$(grep "^$case " $G/disp_fit_cases.txt)
  set -- $line
  local a="+store=.sim/veq_store_$1.hex +w=$2 +hf=$3 +cl=$5 +cr=$6 +ct=$7 +cb=$8 +sarw=$9 +sarh=${10} +fmode=${11}"
  [ "$4" = 1 ] && a="$a +cuy4"
  [ "${12}" = 1 ] && a="$a +il"
  [ "${13}" = 1 ] && a="$a +at"
  [ "${14}" = 1 ] && a="$a +pal"
  echo "$a +ovl=$ovl +std=$std +vis=1 +refs=2"
}

# main's side, once per MAIN_SHA
if [ ! -d "$WT" ] || [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" != "$MAIN_SHA" ]; then
  rm -rf "$WT"; git worktree prune
  git worktree add --detach "$WT" "$MAIN_SHA" > /dev/null 2>&1 || { echo "FAIL: worktree of $MAIN_SHA"; exit 1; }
fi
rm -f .sim/veq_main_sim .sim/veq_br_sim   # iverilog leaves the old binary on a failed build: never run it
# shellcheck disable=SC2086
( cd "$WT" && iverilog -g2012 -DMAIN_RTL -o "$ROOT/.sim/veq_main_sim" $RTL_MAIN "$ROOT/$MODEL" "$ROOT/$TB" 2>&1 | grep -v "sorry\|warning" )
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/veq_br_sim $RTL_BR $MODEL $TB 2>&1 | grep -v "sorry\|warning"
[ -f .sim/veq_main_sim ] && [ -f .sim/veq_br_sim ] || { echo "FAIL: build"; exit 1; }

compare() {   # main-trace branch-trace -> "OK n" or "FAIL [class] ..."
  python3 - "$1" "$2" <<'PYEOF'
import sys
a, b = open(sys.argv[1]).read().split(), open(sys.argv[2]).read().split()
if not a:
    print("FAIL [count] main's trace is empty"); sys.exit()
names = ['hs', 'vs', 'de', 'ce', 'f1', 'cs', 'cs_en']
for i, (x, y) in enumerate(zip(a, b)):
    if x != y:
        fx, fy = int(x[6:], 16), int(y[6:], 16)
        if x[:6] != y[:6]: cls = 'rgb'
        elif (fx ^ fy) & 0x70: cls = 'sync'
        elif (fx ^ fy) & 0x08: cls = 'ce'
        elif (fx ^ fy) & 0x04: cls = 'f1'
        else: cls = 'cs'
        n = sum(1 for p, q in zip(a, b) if p != q)
        print("FAIL [%s] dot %d of %d: main %s, branch %s (%d dots differ)" % (cls, i, len(a), x, y, n)); sys.exit()
if len(a) != len(b):
    print("FAIL [count] main %d dots, branch %d" % (len(a), len(b))); sys.exit()
print("OK %d" % len(a))
PYEOF
}

run_scen() {   # scenario sim-branch tag -> result file .sim/veq_<name><tag>.res
  local s=$1 sim=$2 tag=${3:-} name; name=${s%%|*}
  local args; args=$(args_of "$s")
  if [ ! -s ".sim/veq_${name}_main.trc" ] || [ ! -f ".sim/veq_${name}_main.ok" ]; then
    # shellcheck disable=SC2086
    if ( cd "$WT" && timeout 3000 vvp -n "$ROOT/.sim/veq_main_sim" +root="$ROOT" +trace="$ROOT/.sim/veq_${name}_main.trc" $args ) \
         > ".sim/veq_${name}_main.log" 2>&1 && grep -q "^PASS: vid_equiv_tb" ".sim/veq_${name}_main.log"; then
      touch ".sim/veq_${name}_main.ok"
    else
      { echo "  FAIL $name: main's run"; grep FAIL ".sim/veq_${name}_main.log" | head -3; echo VEQFAIL; } > ".sim/veq_${name}${tag}.res"; return
    fi
  fi
  # shellcheck disable=SC2086
  if timeout 3000 vvp -n "$sim" +root="$ROOT" +trace="$ROOT/.sim/veq_${name}${tag}_br.trc" $args > ".sim/veq_${name}${tag}_br.log" 2>&1 \
       && grep -q "^PASS: vid_equiv_tb" ".sim/veq_${name}${tag}_br.log"; then
    local r; r=$(compare ".sim/veq_${name}_main.trc" ".sim/veq_${name}${tag}_br.trc")
    case "$r" in
      OK*) echo "  PASS $name: ${r#OK } dots identical" > ".sim/veq_${name}${tag}.res" ;;
      *)   { echo "  FAIL $name: $r"; echo VEQFAIL; } > ".sim/veq_${name}${tag}.res" ;;
    esac
  else
    { echo "  FAIL $name: the branch's run"; grep FAIL ".sim/veq_${name}${tag}_br.log" | head -3; echo VEQFAIL; } > ".sim/veq_${name}${tag}.res"
  fi
  rm -f ".sim/veq_${name}${tag}_br.trc"
}

echo "== GREEN: the 27 MHz rasters, branch (clk_vid + ce) == main (clk_sys) =="
rm -f .sim/veq_*_main.ok   # main's traces are re-made every run (the worktree may have been re-created)
for s in "${SCEN[@]}"; do run_scen "$s" .sim/veq_br_sim & done
wait
for s in "${SCEN[@]}"; do
  f=".sim/veq_${s%%|*}.res"; grep -v '^VEQFAIL$' "$f"; grep -q '^VEQFAIL$' "$f" && fail=1
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each caught by its own class) =="
  RES=$(mktemp -d)
  vmut() {   # name file old new class scenario
    local name=$1 file=$2 old=$3 new=$4 cls=$5 scen=$6
    local d; d=$(mktemp -d)
    mkdir -p "$d/h264"; cp h264/*.sv h264/*.svh h264/*.vh "$d/h264/" 2>/dev/null
    python3 - "$d" "$file" "$old" "$new" <<'PYEOF' || { echo "  $name: anchor missed (harness failure)"; echo MUTFAIL; } > "$RES/$name"
import sys, os
d, f, old, new = sys.argv[1:5]
old = old.replace('\\n', '\n').replace('\\t', '\t'); new = new.replace('\\n', '\n').replace('\\t', '\t')
s = open(f).read()
assert s.count(old) == 1, f"mutation anchor not unique/found in {f}: {old!r}"
open(os.path.join(d, f), 'w').write(s.replace(old, new))
PYEOF
    [ -f "$RES/$name" ] && { rm -rf "$d"; return; }
    # shellcheck disable=SC2086
    if ! ( cd "$d" && iverilog -g2012 -o "$d/sim" $RTL_BR "$ROOT/$MODEL" "$ROOT/$TB" 2> "$d/build.log" ); then
      { echo "  $name: DID NOT COMPILE (harness failure)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local sc; for x in "${SCEN[@]}"; do [ "${x%%|*}" = "$scen" ] && sc=$x; done
    run_scen "$sc" "$d/sim" "_$name"
    local r; r=$(cat ".sim/veq_${scen}_$name.res")
    if ! grep -q VEQFAIL <<< "$r"; then { echo "  $name: SURVIVED -- the gate cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[$cls\]" <<< "$r"; then echo "  $name: caught by $(grep -o "FAIL \[$cls\].*" <<< "$r" | cut -c1-80)" > "$RES/$name"
    else { echo "  $name: failed but NOT as [$cls]:"; grep -v VEQFAIL <<< "$r"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d" ".sim/veq_${scen}_$name.res"
  }
  vmut Q1 h264/disp_reader.sv "always_ff @(posedge clk) if (ce) begin\n        if (h_pos == 12'd0) xacc" "always_ff @(posedge clk) begin\n        if (h_pos == 12'd0) xacc" rgb e480p &
  vmut Q2 h264/vid_out.sv "always @(posedge clk) if (ce) begin\n\ths_dly" "always @(posedge clk) begin\n\ths_dly" rgb e480p &
  vmut Q3 h264/vid_out.sv "vga_ce <= ce & ce_dly[10];" "vga_ce <= ce;" ce e480i &
  vmut Q4 h264/csync_smpte.sv "        hs_q     <= 1'b0;\n    end else if (ce) begin" "        hs_q     <= 1'b0;\n    end else begin" cs e480i &
  wait
  vmut Q5 h264/ovl_plane.sv "always_ff @(posedge clk) if (ce) begin\n        s0_x <=" "always_ff @(posedge clk) begin\n        s0_x <=" rgb e576p &
  vmut Q6 h264/idle_bars.sv "        bar_q <= 3'd0; in_bars_q <= 1'b0; in_mark_q <= 1'b0; de_q <= 1'b0;\n    end else if (ce) begin" "        bar_q <= 3'd0; in_bars_q <= 1'b0; in_mark_q <= 1'b0; de_q <= 1'b0;\n    end else begin" rgb e576p &
  vmut Q7 h264/disp_reader.sv "always_ff @(posedge clk) if (ce) begin\n        q_ya" "always_ff @(posedge clk) begin\n        q_ya" rgb e576i &
  wait
  for f in "$RES"/*; do grep -v '^MUTFAIL$' "$f"; grep -q '^MUTFAIL$' "$f" && fail=1; done
  rm -rf "$RES"
fi
rm -f .sim/veq_*_main.trc

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
