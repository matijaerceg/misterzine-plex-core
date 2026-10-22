#!/usr/bin/env bash
# run_recon_out.sh -- h264/recon_out.sv, the output queue between the reconstruction
# (clk_dec) and the display (clk_sys), roadmap P5d, docs/display.md S6: a random DPB and a
# random display on two real clocks (bench/h264/recon_out_tb.sv), three seeds.
#
# --red: mutations on a COPY, each caught by its own arm:
#   U1  an emission does not raise its store's hold             -> [hold]
#   U2  a release does not lower it                             -> [hold]
#   U3  a second field's b half never written                   -> [rec]
#   U4  the END record never queued                             -> [end]
#   U5  the bad-release detector dead                           -> [flags]
#   U6  frame / unpaired swapped in the record                  -> [rec]
#   U7  rec_take ignored (the head record presented forever)    -> [rec] / [end]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="h264/fifo_dc.sv h264/recon_out.sv"; TB=bench/h264/recon_out_tb.sv
echo "== GREEN =="
# shellcheck disable=SC2086
if iverilog -g2012 -o .sim/ro_sim $RTL $TB 2>.sim/ro_build.log; then
  for seed in 1 2 3; do
    if vvp -n .sim/ro_sim +seed=$seed > .sim/ro_$seed.log 2>&1 && grep -q "^PASS: recon_out_tb" .sim/ro_$seed.log; then
      echo "  PASS seed $seed: $(grep '^recon_out_tb:' .sim/ro_$seed.log | sed 's/^recon_out_tb: //')"
    else echo "  FAIL seed $seed"; grep FAIL .sim/ro_$seed.log | head -3; fail=1; fi
  done
else echo "  FAIL: build"; head -5 .sim/ro_build.log; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  mut() {   # name old new arm
    local d; d=$(mktemp -d)
    cp h264/fifo_dc.sv h264/recon_out.sv "$d/"
    python3 - "$d/recon_out.sv" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/fifo_dc.sv" "$d/recon_out.sv" $TB 2>"$d/build.log"; then
      echo "  $1: harness failure (anchor or build)"; fail=1
    else
      timeout 600 vvp -n "$d/sim" > "$d/log" 2>&1
      if grep -q "^PASS:" "$d/log"; then echo "  $1: SURVIVED -- the bench cannot see this defect"; fail=1
      elif grep -Eq "FAIL \[($4)\]" "$d/log"; then echo "  $1: caught by $(grep -Em1 "FAIL \[($4)\]" "$d/log" | cut -c1-100)"
      else echo "  $1: failed but NOT in [$4]:"; grep -m2 FAIL "$d/log"; fail=1; fi
    fi
    rm -rf "$d"
  }
  mut U1 "if (emit_valid && emit_store == i[4:0]) oq_hold[i] <= 1'b1;" "if (1'b0) oq_hold[i] <= 1'b1;" hold
  mut U2 "else if (lq_valid && lq_dout == i[4:0]) oq_hold[i] <= 1'b0;" "else if (1'b0) oq_hold[i] <= 1'b0;" hold
  mut U3 "if (pinfo_we && pinfo_second)" "if (1'b0)" rec
  mut U4 "rq_we  = emit_valid || eos_push;" "rq_we  = emit_valid;" end
  mut U5 "if (lq_dout >= NST[4:0] || !oq_hold[lq_dout]) rel_bad <= 1'b1;" "if (1'b0) rel_bad <= 1'b1;" flags
  mut U6 "{rec_store, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b} = p_word;" \
         "{rec_store, rec_unpaired, rec_frame, rec_first_bot, rec_dec_t, rec_dec_b} = p_word;" rec
  mut U7 "if (rec_valid && rec_take) rec_valid <= 1'b0;" "if (1'b0) rec_valid <= 1'b0;" "rec|end"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
