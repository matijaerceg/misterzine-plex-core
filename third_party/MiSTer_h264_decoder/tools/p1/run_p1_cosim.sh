#!/usr/bin/env bash
# run_p1_cosim.sh -- Phase 1: UMD's decoder (the one this core forks) on Annex-B streams,
# cycles a macroblock and where they go (docs/p1_measurements.md).
#
#   tools/p1/run_p1_cosim.sh [--umd DIR] [--commit REV] [--frames N] [--work DIR] CLIP.264...
#
# Snapshots UMD at REV (`git archive`, default 75e3f37: the fork point) into WORK (default
# .sim/p1), so NOTHING is written into the UMD tree -- coordinate with the UMD sessions
# anyway: the build is 8 compilers and each run is ~3 min per 60 frames (CLAUDE.md,
# memory: never a fit and several heavy sims at once). Copies tools/p1/es_golden.py in,
# builds the Verilator cosim with bench/umd/run_cosim.sh's exact flags, then per clip:
# the golden (UMD's model, checked bit-exact against ffmpeg), the cosim with +prof (every
# macroblock and picture scored against the model), and UMD's cosim_prof.py breakdown.
# One line per clip in WORK/results.tsv. Clips run one at a time.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
UMD=$ROOT/../MiSTer_UMD_Video; REV=75e3f37; FRAMES=60; WORK=$ROOT/.sim/p1; clips=()
while [ $# -gt 0 ]; do
  case $1 in
    --umd) UMD=$2; shift;; --commit) REV=$2; shift;; --frames) FRAMES=$2; shift;; --work) WORK=$2; shift;;
    *) clips+=("$(cd "$(dirname "$1")" && pwd)/$(basename "$1")");;
  esac; shift
done
[ ${#clips[@]} -gt 0 ] || { sed -n '2,16p' "$0"; exit 2; }
S=$WORK/umd; W=$S/.sim/cosim/p1
if [ ! -d "$S" ]; then
  mkdir -p "$S" && git -C "$UMD" archive "$REV" | tar -x -C "$S" || { echo "FAIL: snapshot"; exit 1; }
  echo "$REV" > "$S/.umd_commit"
fi
cp "$HERE/es_golden.py" "$S/tools/"
mkdir -p "$W"
cd "$S"
eval "$(sed -n '/^FE=/,/^RTL=/p' bench/umd/run_cosim.sh)"
if [ ! -x .sim/cosim/obj/cosim ]; then
  echo "== build (UMD $(cat .umd_commit)) =="
  # shellcheck disable=SC2086
  verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-lint -Wno-style -Wno-LATCH -Wno-MULTIDRIVEN -I. --top-module cosim_top \
    -Mdir "$S/.sim/cosim/obj" -o cosim -MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2' \
    $RTL "$S/bench/umd/cosim_top.sv" "$S/bench/umd/cosim_main.cpp" > .sim/cosim/obj.build.log 2>&1 \
    && [ -x .sim/cosim/obj/cosim ] || { echo "FAIL: build (.sim/cosim/obj.build.log)"; exit 1; }
fi
for c in "${clips[@]}"; do
  n=$(basename "${c%.*}")_$FRAMES
  if ! python3 -u tools/es_golden.py --es "$c" --out "$W/$n" --frames "$FRAMES" > "$W/$n.golden.log" 2>&1; then
    echo -e "$n\tGOLDEN\t$(tail -n 1 "$W/$n.golden.log")" | tee -a "$WORK/results.tsv"; continue
  fi
  .sim/cosim/obj/cosim "$W/$n" +label="$n" +prof > "$W/$n.prof.log" 2>&1
  v=$(grep -m1 -o "[0-9]* clk_dec cycles a macroblock, [0-9.]* frames/s at [0-9.]* MHz, [0-9.]*x real time" "$W/$n.prof.log")
  grep -q "^PASS: cosim" "$W/$n.prof.log" && r=PASS || r=FAIL
  echo -e "$n\t$r\t${v:-$(grep -m1 FAIL "$W/$n.prof.log")}" | tee -a "$WORK/results.tsv"
  python3 tools/cosim_prof.py "$W/$n.prof.log" --min 40 > "$W/$n.prof.txt" 2>&1
done
