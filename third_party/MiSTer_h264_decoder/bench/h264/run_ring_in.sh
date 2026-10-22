#!/usr/bin/env bash
# run_ring_in.sh -- the HPS interface's input region (interface 0.6; docs/architecture.md "Input
# (interface 0.6)"): h264/ring_in.sv, h264/ring_stat.sv's second job, ring_rd.sv's 7-bit status
# index and the generated ring_words_in.sv, end to end into bench/h264/ddr_model.sv, read back by
# a stand-in program through the region's seqlock: bench/h264/ring_in_tb.sv, one simulation a
# scenario (~1 min each, run in parallel).
#
# GREEN: tools/ring_layout.py --check; I1 mixed input at Main's pace (every event in order, the
# sums and buttons, the OSD level, the pads, each within the write period; 0.8: the OSD's
# actions, one followed by the OSD's closing), I2 chords into the writes and across the frame
# pulses (the freeze, a frame kept pending; 0.8: an action and an OSD edge pending together, the
# two actions at once), I3 a flood faster than the freeze (the core's losses counted: ev_count +
# ev_lost = sent; 0.8: actions in it), I4 a reader slower than the queue (its losses counted
# exactly, every event it gets right), I5 idle (one write a frame).
#
# --red: mutations on a COPY of the RTL, compiled from inside the copy (the RTL includes the
# generated h264/ring_iface.svh), each caught by its own arm (scenario + check); an unmutated
# control copy runs first and must pass.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/ring_in
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="h264/cdc.sv h264/fifo_dc.sv h264/ddr_mux2.sv h264/ring_rd.sv h264/ring_stat.sv h264/ring_in.sv h264/ring_words_in.sv"
INC="h264/ring_iface.svh"
TB="bench/h264/ddr_model.sv bench/h264/ring_in_tb.sv"
SCEN="I1 I2 I3 I4 I5"

echo "== the layout =="
if python3 tools/ring_layout.py --check; then :; else fail=1; fi

run_scen() {   # sim scenario -> log
  timeout 900 vvp -n "$1" +arm="$2" > "$3" 2>&1
}

echo "== GREEN: ring_in_tb =="
# iverilog leaves the old binary on a failed build: never run it -- nor score the logs it wrote
rm -f .sim/ring_in/sim .sim/ring_in/*.log
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/ring_in/sim $RTL $TB 2>&1 | grep -v "sorry\|pop_front"
for s in $SCEN; do
  if [ -f .sim/ring_in/sim ]; then run_scen .sim/ring_in/sim "$s" ".sim/ring_in/$s.log" & fi
done
wait
for s in $SCEN; do
  if [ -f ".sim/ring_in/$s.log" ] && grep -q "^PASS: ring_in_tb $s" ".sim/ring_in/$s.log"; then
    echo "  PASS $s: $(grep '^ring_in_tb:' ".sim/ring_in/$s.log" | sed 's/^ring_in_tb: [^ ]* //')"
  else
    echo "  FAIL $s"; grep -m3 "FAIL" ".sim/ring_in/$s.log" 2>/dev/null; fail=1
  fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mk_copy() {
    local d=$1
    for f in $RTL $INC $TB; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
  }
  CTL=$(mktemp -d); mk_copy "$CTL"
  # shellcheck disable=SC2086
  if (cd "$CTL" && iverilog -g2012 -o sim $RTL $TB 2>build.log) && run_scen "$CTL/sim" I1 "$CTL/log" && grep -q "^PASS:" "$CTL/log"; then
    echo "  control: the unmutated copy passes I1"
  else echo "  CONTROL FAIL: the unmutated copy does not pass"; fail=1; fi
  rm -rf "$CTL"
  mut() {   # name file old new scenario arm(regex)
    local name=$1 file=$2 old=$3 new=$4 scen=$5 arm=$6
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
    run_scen "$d/sim" "$scen" "$d/log"
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- $scen cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $scen $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm] of $scen:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  N=h264/ring_in.sv; S=h264/ring_stat.sv; R=h264/ring_rd.sv
  # ring_in: the queue, its order and its losses
  mut N1 $N "q[ev_count[4:0]] <= ev;" "q[ev_count[4:0] + 5'd1] <= ev;" I1 "events" &
  mut N2 $N "wire         freeze = in_go || in_busy;" "wire         freeze = 1'b0;" I4 "events" &
  mut N3 $N "ev_lost <= lost_s[16] ? 16'hFFFF : lost_s[15:0];" "ev_lost <= ev_lost;" I3 "lost" &
  mut N4 $N "wire         push   = k_app || (m_app && m_btn != mbtn) || a_app || o_app;" "wire         push   = k_app || a_app || o_app;" I1 "events|latency" &
  mut N5 $N "else            ev = {RV_OSD, 13'd0, op_d};" "else            ev = {RV_OSD, 13'd0, 1'b1};" I1 "events" &
  wait
  # ring_in: the mouse
  mut N6 $N "wire  [31:0] m_dx   = {{24{mp_d[4]}}, mp_d[15:8]};" "wire  [31:0] m_dx   = {{23{mp_d[4]}}, mp_d[15:8]};" I1 "mouse" &
  mut N7 $N "wire   [7:0] m_btn  = {mpx_d[12:8], mp_d[2:0]};" "wire   [7:0] m_btn  = {mpx_d[11:8], mp_d[3:0]};" I1 "mouse|events" &
  # ring_in: when the region is written
  mut N8 $N "assign in_req   = dirty && (gap == GAP);" "assign in_req   = dirty;" I1 "rate" &
  mut N9 $N "if (k_app || m_app || a_app || o_app || frame || pads != pads_q) dirty <= 1'b1;" "if (k_app || m_app || a_app || o_app || pads != pads_q) dirty <= 1'b1;" I5 "heartbeat" &
  mut N10 $N "if (k_app || m_app || a_app || o_app || frame || pads != pads_q) dirty <= 1'b1;" "if (k_app || m_app || a_app || o_app || frame) dirty <= 1'b1;" I1 "pads" &
  wait
  # the seqlock: in_head advanced a cycle late (the first write's first word carries the old count)
  mut N11 $N "                in_seq <= in_seq + 32'd1; dirty <= 1'b0; gap <= '0;" "                dirty <= 1'b0; gap <= '0;
            end
            if (in_busy && in_ix == 5'd0) begin
                in_seq <= in_seq + 32'd1;" I1 "seqlock" &
  # (0.8) the OSD's actions: the number, the edge, the order, the losses, the write
  mut A1 $N "wire         a_num  = !ap_m[0];" "wire         a_num  = 1'b0;" I1 "events" &
  mut A2 $N "wire   [1:0] a_new  = primed ? (act & ~a_s) : 2'b00;" "wire   [1:0] a_new  = primed ? act : 2'b00;" I1 "events|lost|latency" &
  mut A3 $N "wire         o_app  = !freeze && !kp_v && !mp_v && (ap_m == 2'b00) && op_v;" "wire         o_app  = !freeze && !kp_v && !mp_v && op_v;" I2 "events|latency" &
  mut A4 $N "wire   [1:0] a_lost = a_new & ap_m & ~a_done;" "wire   [1:0] a_lost = 2'b00;" I3 "lost" &
  mut A5 $N "wire   [1:0] a_done = a_app ? (a_num ? 2'b10 : 2'b01) : 2'b00;" "wire   [1:0] a_done = a_app ? 2'b11 : 2'b00;" I2 "events|latency" &
  wait
  mut A6 $N "if (k_app || m_app || a_app || o_app || frame || pads != pads_q) dirty <= 1'b1;" "if (k_app || m_app || o_app || frame || pads != pads_q) dirty <= 1'b1;" I5 "latency" &
  # ring_stat's second job
  mut S1 $S "if (frame && bs != B_IDLE) frame_p <= 1'b1;" "" I2 "frames" &
  # (2026-10-05, fix/cleanup) a frame with no room skipped again instead of waiting for it
  mut S9 $S "frame_p <= 1'b1;                         // wait for the room (the engine drains it)" "frame_p <= 1'b0;" I2 "frames" &
  mut S2 $S "st_word <= in_word; st_ix <= IN_W0 + {2'd0, j}; st_wr <= 1'b1;" "st_word <= in_word; st_ix <= IN_W0 + {2'd0, j} + 7'd8; st_wr <= 1'b1;" I1 "seqlock|events|pads|mouse|latency" &
  mut S3 $S "st_grp <= (j[2:0] == 3'd7);" "st_grp <= (j[2:0] == 3'd7) && (j != 5'd23);" I1 "seqlock|events|pads|mouse|frames|latency|hang" &
  # ring_rd: the 7-bit index (words 64-71 would land on 0-7)
  mut D1 $R "b_address <= CTRL_WORD + {22'd0, sf_dout[70:64]}; b_burstcount <= 8'd8;" "b_address <= CTRL_WORD + {23'd0, sf_dout[69:64]}; b_burstcount <= 8'd8;" I1 "seqlock|frames" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
