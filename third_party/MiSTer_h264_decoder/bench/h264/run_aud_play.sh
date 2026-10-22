#!/usr/bin/env bash
# run_aud_play.sh -- the audio path (h264/aud_play.sv, interface 0.5; docs/architecture.md
# "Audio (Phase 4)") against the design text: bench/h264/aud_play_tb.sv, one simulation per
# arm. Every frame the bench queues carries a unique ID; the bench knows each frame's time
# from the records it wrote and checks, at every 48 kHz tick, which frame played against the
# STC it runs itself.
#
# GREEN: tools/gen_aud_gain.py --check (the attenuation table matches its generator); every
# arm passes:
#   A1 paced, every frame in order and on time (+-3 ticks, the start within a tick); A2 a gap
#   (silence counted, then on time); A3 an overlap (the late frames dropped and counted); A4
#   an underrun; A5 the audio anchor after AUD_WAIT; A5Q the anchor at once with 256 records
#   waiting; A6 / A7 low latency with the producer 2,500 ppm fast / slow (single frames
#   dropped / repeated, the queue bounded); A8 the pause (silent, nothing taken, sync kept);
#   A9 ATTEN 13 (every frame scaled, the gain computed in the bench from dB); A10 a stream
#   reset with a fetch in flight (nothing of the old stream after it); A11 the clock starting
#   100 ms after the audio's first frame (the late frames dropped before the gate opens);
#   (1.1) A12 the lead cleared by a late drop, A13 by an underrun; [lead] on every arm whose
#   story fixes it (A1 high, A5Q high from the anchor, A11 / A6 / A7 never).
#   Throughout: [hold] the
#   read index held behind every record not wholly fetched, [credit] the 256-word sample FIFO
#   never over-asked, [fetch] the requests walk the records in order, [rate] exactly 48 kHz.
#
# --red: mutations on a COPY of the RTL, compiled from inside the copy, each caught by its
# own arm (arm + check); an unmutated control copy runs first and must pass.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/aud
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="h264/sfifo.sv h264/aud_gain.sv h264/aud_play.sv"
TB="bench/h264/aud_play_tb.sv"
ARMS="A1 A2 A3 A4 A5 A5Q A6 A7 A8 A9 A10 A11 A12 A13"

echo "== the attenuation table =="
if python3 tools/gen_aud_gain.py --check; then :; else fail=1; fi

run_arm() {   # sim arm log
  timeout 900 vvp -n "$1" +arm="$2" > "$3" 2>&1
}

echo "== GREEN: aud_play_tb =="
rm -f .sim/aud/sim   # iverilog leaves the old binary on a failed build: never run it
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/aud/sim $RTL $TB 2>&1 | grep -v "sorry"
for a in $ARMS; do ( run_arm .sim/aud/sim "$a" ".sim/aud/$a.log" ) & done
wait
for a in $ARMS; do
  if [ -f .sim/aud/sim ] && grep -q "^PASS: aud_play_tb $a\$" ".sim/aud/$a.log"; then
    echo "  PASS $a: $(grep '^aud_play_tb:' ".sim/aud/$a.log" | sed 's/^aud_play_tb: [^ ]* //')"
  else
    echo "  FAIL $a"; grep -m3 "FAIL" ".sim/aud/$a.log"; fail=1
  fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mk_copy() {
    local d=$1
    for f in $RTL $TB; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
  }
  CTL=$(mktemp -d); mk_copy "$CTL"
  # shellcheck disable=SC2086
  if (cd "$CTL" && iverilog -g2012 -o sim $RTL $TB 2>build.log) && run_arm "$CTL/sim" A1 "$CTL/log" && grep -q "^PASS:" "$CTL/log"; then
    echo "  control: the unmutated copy passes A1"
  else echo "  CONTROL FAIL: the unmutated copy does not pass"; fail=1; fi
  rm -rf "$CTL"
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
  P=h264/aud_play.sv
  mut M1 $P "if (!hs_tv || due) begin" "if (1'b1) begin" A1 "sync" &
  mut M2 $P "if (tcnt == (tphase ? 10'd562 : 10'd561))" "if (tcnt == 10'd562)" A1 "rate" &
  mut M3 $P "take = 1'b1; drop1 <= 1'b0; ev_sdrop <= 1'b1;" "take = 1'b1; drop1 <= 1'b0;" A6 "ll" &
  mut M4 $P "take = 1'b1; ev_late <= 1'b1;" "take = 1'b1;" A3 "complete" &
  mut M5 $P "if (pause) out_s <= '0;
            else if (play)" "if (play)" A8 "pause" &
  mut M6 $P "f_words <= {d_len[22:3]} + {19'd0, (d_len[2:0] != 3'd0)};" "f_words <= {d_len[22:3]};" A1 "fetch|order|complete|hang|hold" &
  wait
  mut M7 $P "assign a_hold_v   = f_run || (d_count != 10'd0);" "assign a_hold_v   = f_run;" A1 "hold" &
  mut M8 $P "if (flushing && owed == 16'd0 && !rd_pend) flushing <= 1'b0;" "if (flushing) flushing <= 1'b0;" A10 "flush|order|sync" &
  mut M9 $P "(anc_tmr == AWAIT || q_rec == MAXREC)" "(anc_tmr == AWAIT)" A5Q "anchor" &
  mut M10 $P "mul_l <= \$signed(out_s[15:0]) * \$signed({1'b0, gain});" "mul_l <= \$signed(out_s[15:0]) * \$signed({1'b0, 16'd32768});" A9 "atten" &
  mut M11 $P "end else if (!ll && hs_tag && far_early) begin" "end else if (1'b0) begin" A2 "sync|complete" &
  mut M12 $P "silent = 1'b1; ev_under <= 1'b1; gs <= G_ARM; gap_arm <= 1'b0;" "silent = 1'b1; gs <= G_ARM; gap_arm <= 1'b0;" A4 "complete" &
  wait
  mut M13 $P "if (ptick && q_samples >= LL_T) begin" "if (ptick) begin" A7 "ll" &
  mut M14 $P "(({1'b0, owed} + {13'd0, f_n}) <= SFW)" "(({1'b0, owed} + {13'd0, f_n}) <= SFW + 17'd64)" A1 "credit" &
  mut M15 $P "if (nwin == 2'd3) begin" "if (1'b1) begin" A7 "ll" &
  mut M16 $P "else if (ad_push && !f_run && d_count == 10'd0) h_pos <= ad_pos;" "" A1 "hold" &
  mut M17 $P "if (u_first && u_ptsv) begin hs_t <= {u_pts, 3'b000};" "if (u_first && u_ptsv && 1'b0) begin hs_t <= {u_pts, 3'b000};" A2 "sync|complete|hang" &
  mut M18 $P "if (hs_tv && far_late) gs <= G_DROP;" "if (1'b0) gs <= G_DROP;" A11 "sync|complete" &
  # (1.1) THE LEAD: each term that sets or clears it, caught by its own arm
  mut L1 $P "(gs == G_PLAY && ptick && hs_v && hs_tag && far_late) ||           // late: to G_DROP" "1'b0 ||" A12 "lead" &
  mut L2 $P "if (q_rec == 9'd0 ||                                                  // ran dry" "if (1'b0 ||" A13 "lead" &
  mut L3 $P "else if ((gs == G_ARM && hs_v && !pause && stc_run && hs_tv && !due) ||  // waiting for the clock" "else if (1'b0 ||" A1 "lead" &
  mut L4 $P "                     aanc)                                                          // the audio anchor (sent last cycle)" "                     1'b0)" A5Q "lead" &
  mut L5 $P "aud_lead <= lead && !ll && q_rec != 9'd0;" "aud_lead <= lead && q_rec != 9'd0;" A6 "lead" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
