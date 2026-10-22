#!/usr/bin/env bash
# run_f2sdram_term.sh -- sys/f2sdram_safe_terminator.sv (a UMD-FORK: the write burst
# tracked at the port) between a dpb_mem-shaped master and ddr_model, locked by the core
# reset hundreds of times at random instants, half of them inside a write burst
# (bench/h264/f2sdram_term_tb.sv; the reload hang, docs/hil_harness.md "Facts that bite").
# Verilator --timing: the stock terminator uses its localparams before declaring them,
# which Icarus refuses.
#
# GREEN: contiguous write bursts, and bursts whose `write` drops between beats (+gaps,
#   as dpb_mem's do) -- each 300 locks; nothing owed after any lock ([owed]), and
#   ddr_model's [ddr] / [avalon] rules on everything the terminator presents.
# --red: the CONTROL arm, then mutations on a copy of the fork, each caught by its arm:
#   K0  the stock terminator (bench/h264/f2sdram_term_stock.sv: MiSTer's, as UMD's scaffold
#       commit e33635c had it) -> [owed]|[avalon]
#   K1  the tracker counts the slave's beats (blind after the lock) -> [owed]
#   K2  the tracker counts a beat on every cycle (stock's error)    -> [owed]
#   K3  a held write beat's enables zeroed under waitrequest        -> [avalon]
#   K4  a held read not kept at the lock                            -> [avalon]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/f2sdram_term
mkdir -p $W
red=0
for a in "$@"; do case $a in --red) red=1;; esac; done
command -v verilator >/dev/null || { echo "run_f2sdram_term: SKIP -- no verilator"; exit 2; }
TB="bench/h264/f2sdram_term_tb.sv bench/h264/ddr_model.sv"
build() {   # terminator-source obj-dir -> 0 on success
  # shellcheck disable=SC2086
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-PROCASSWIRE -Wno-TIMESCALEMOD -j 4 \
      --top-module f2sdram_term_tb --Mdir "$2" -o term $TB "$1" > "$2.log" 2>&1
}
run() {     # obj-dir label plusargs... -> prints the verdict line, 0 on PASS
  local obj=$1 label=$2; shift 2
  "$obj/term" "$@" > "$obj.$label.out" 2>&1
  if grep -q "^PASS: f2sdram_term_tb" "$obj.$label.out"; then grep "^  PASS" "$obj.$label.out"; return 0; fi
  echo "  FAIL $label: $(grep -m1 'FAIL' "$obj.$label.out" || tail -2 "$obj.$label.out")"; return 1
}
fail=0
echo "== build =="
build sys/f2sdram_safe_terminator.sv "$ROOT/$W/fork" || { echo "FAIL: build"; tail -20 "$W/fork.log"; exit 1; }
echo "== GREEN =="
run "$W/fork" plain || fail=1
run "$W/fork" gaps +gaps || fail=1

if [ $red = 1 ] && [ $fail = 0 ]; then
  echo "== RED (each caught by its own arm) =="
  mut() {   # name source arm-regex -> caught on either traffic shape?
    local name=$1 src=$2 arm=$3 d="$ROOT/$W/$1" out
    if ! build "$src" "$d"; then echo "  $name: MUTFAIL -- did not build"; tail -5 "$d.log"; return 1; fi
    out=$( { "$d/term"; "$d/term" +gaps; } 2>&1 | grep -m1 -E 'FAIL \[' )
    if echo "$out" | grep -qE "FAIL \[($arm)\]"; then echo "  $name: caught by $out"; return 0; fi
    echo "  $name: MUTFAIL -- ${out:-SURVIVED}"; return 1
  }
  mutate() { # name old new -> a mutated copy's path (the anchor must be unique)
    python3 - "$1" "$2" "$3" "$ROOT/$W/$1.sv" <<'EOF'
import sys
name, old, new, out = sys.argv[1:]
s = open('sys/f2sdram_safe_terminator.sv').read()
assert s.count(old) == 1, f"{name}: anchor not unique/found: {old!r}"
open(out, 'w').write(s.replace(old, new))
EOF
    echo "$ROOT/$W/$1.sv"
  }
  cp bench/h264/f2sdram_term_stock.sv "$W/K0.sv"
  mut K0 "$W/K0.sv" "owed|avalon" || fail=1
  mut K1 "$(mutate K1 'wire port_wbeat = write_master && !waitrequest_master;' 'wire port_wbeat = write_slave && !waitrequest_master;')" "owed" || fail=1
  mut K2 "$(mutate K2 'wire [BURSTCOUNT_WIDTH-1:0] next_left = !port_wbeat ? wr_left :' 'wire [BURSTCOUNT_WIDTH-1:0] next_left = (!port_wbeat && !wr_open) ? wr_left :')" "owed" || fail=1
  mut K3 "$(mutate K3 'byteenable_master = be_keep ? byteenable_latch : {BYTEENABLE_WIDTH{1'"'"'b0}};' 'byteenable_master = {BYTEENABLE_WIDTH{1'"'"'b0}};')" "avalon" || fail=1
  mut K4 "$(mutate K4 '			read_terminating  <= 1;' '			read_terminating  <= 0;')" "avalon" || fail=1
fi
if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; exit 1; fi
