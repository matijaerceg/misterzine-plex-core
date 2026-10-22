#!/usr/bin/env bash
# run_disp_anc.sh -- the audio anchor in the display scheduler (h264/disp_sched.sv, interface
# 0.5; docs/architecture.md "Audio (Phase 4)"): bench/h264/disp_anc_tb.sv, one simulation an
# arm. The rule from the design text: after the audio starts the STC, the first picture is
# scheduled against the running clock unless it is past FWD_MAX ahead or LATE_MAX behind (then
# it re-anchors); once a picture has anchored, the audio's anchor changes nothing.
#   X1 0.2 s ahead: waits, taken without anchoring   X2 1 s ahead: re-anchors
#   X3 3 s behind: re-anchors   X4 1 s behind: taken at once, not anchored
#   X5 a picture first: a later audio anchor moves nothing   X6 untagged: taken, clock kept
# (1.1) aud_lead, the queued audio ahead of the clock: X7 X3 with it -- taken, not anchored; X8 a late
#   picture contiguous on the timeline (disc's lateness leg) with it -- not anchored; X9 the same
#   without it (a stall) -- re-anchors; X10 with it, a jump past FWD_MAX -- re-anchors
# (The pause gates disp_ctl's tick / eval / pickup / skip: wiring, scored on the rig.)
#
# --red: mutations on a COPY, each caught by its own arm.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/danc
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="h264/disp_sched.sv"
TB="bench/h264/disp_anc_tb.sv"
ARMS="X1 X2 X3 X4 X5 X6 X7 X8 X9 X10"
run_arm() { timeout 300 vvp -n "$1" +arm="$2" > "$3" 2>&1; }

echo "== GREEN: disp_anc_tb =="
rm -f .sim/danc/sim   # iverilog leaves the old binary on a failed build: never run it
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/danc/sim $RTL $TB 2>&1 | grep -v "sorry"
for a in $ARMS; do ( run_arm .sim/danc/sim "$a" ".sim/danc/$a.log" ) & done
wait
for a in $ARMS; do
  if [ -f .sim/danc/sim ] && grep -q "^PASS: disp_anc_tb $a\$" ".sim/danc/$a.log"; then
    echo "  PASS $a: $(grep '^disp_anc_tb:' ".sim/danc/$a.log" | sed 's/^disp_anc_tb: [^ ]* //')"
  else echo "  FAIL $a"; grep -m3 "FAIL" ".sim/danc/$a.log"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mk_copy() { local d=$1; for f in $RTL $TB; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done; }
  mut() {   # name file old new arm check(regex)
    local name=$1 file=$2 old=$3 new=$4 arm=$5 chk=$6
    local d; d=$(mktemp -d)
    mk_copy "$d"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTL $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    run_arm "$d/sim" "$arm" "$d/log"
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- $arm cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($chk)\]" "$d/log"; then
      echo "  $name: caught by $arm $(grep -Em1 "FAIL \[($chk)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$chk] of $arm:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  S=h264/disp_sched.sv
  mut N1 $S "(next_valid ? disc : far)" "(next_valid ? disc : 1'b1)" X1 "anchor" &
  mut N2 $S "(next_valid ? disc : far)" "(next_valid ? disc : 1'b0)" X2 "anchor" &
  mut N3 $S "if (ext_anc && !anchored) begin stc <= ext_pts;" "if (ext_anc) begin stc <= ext_pts;" X5 "stc" &
  mut N4 $S "if (ext_anc && !anchored) begin stc <= ext_pts; anchored <= 1'b1; end" "if (ext_anc && !anchored) begin anchored <= 1'b1; end" X1 "anchor" &
  mut N5 $S "far = lat || (d_stc_pic < -FWD_MAX_TICKS);" "far = (d_stc_pic < -FWD_MAX_TICKS);" X3 "anchor" &
  # (1.1) the audio's lead ignored: a late picture anchors behind leading audio (the far leg, then disc's)
  mut N6 $S "lat  = (d_stc_pic > LATE_MAX_TICKS) && !lead_q;" "lat  = (d_stc_pic > LATE_MAX_TICKS);" X7 "anchor" &
  mut N6b $S "lat  = (d_stc_pic > LATE_MAX_TICKS) && !lead_q;" "lat  = (d_stc_pic > LATE_MAX_TICKS);" X8 "anchor" &
  # the lateness leg gone whatever the audio (a stall's late picture never re-anchors)
  mut N7 $S "lat  = (d_stc_pic > LATE_MAX_TICKS) && !lead_q;" "lat  = 1'b0;" X9 "anchor" &
  # the lead suppressing the timeline's legs too
  mut N8 $S "disc = tag_e && anchored && next_valid &&" "disc = tag_e && anchored && next_valid && !lead_q &&" X10 "anchor" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
