#!/usr/bin/env bash
# run_aspect_vui.sh -- h264/aspect_vui.sv (the shown picture's VUI aspect -> 4:3 / 16:9,
# roadmap P5b, docs/display.md) against tools/aspect_vui_golden.py: Table E-1 read from
# the spec PDF ($H264_REFS_DIR; without it the golden says it fell back to a transcription),
# the rounding checked against the table's own examples.
#
# GREEN: every idc 0..255, the spec's examples, Extended_SAR edge and random cases, and
# the not-shown case -- {known, wide} identical (bench/h264/aspect_vui_tb.sv).
# --red: mutations on a COPY, each caught by its own arm:
#   A1  idc 5 reads 40:32 (a table entry)                      -> [table]
#   A2  the threshold 14/9 -> 13/9                             -> [round]
#   A3  Extended_SAR's height ignored (sh = sw)                -> [ext]
#   A4  a 0 term in Extended_SAR not unspecified               -> [ext]
#   A5  `valid` ignored                                        -> [valid]
#   A6  the resolved SAR out unguarded (0:0 / garbage when not known; P6) -> [sar]
#   (A1 is also seen by [sar]: the resolved SAR is the table's entry)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
export H264_REFS_DIR=${H264_REFS_DIR:-$HOME/h264-refs}
python3 tools/aspect_vui_golden.py | sed 's/^/  /' || { echo "FAIL: golden"; exit 1; }
RTL=h264/aspect_vui.sv; TB=bench/h264/aspect_vui_tb.sv
echo "== GREEN =="
rm -f .sim/aspect_sim   # iverilog leaves the old binary on a failed build
if iverilog -g2012 -o .sim/aspect_sim $RTL $TB && vvp -n .sim/aspect_sim > .sim/aspect.log 2>&1 && grep -q "^PASS: aspect_vui_tb" .sim/aspect.log; then
  echo "  PASS $(grep '^aspect_vui_tb:' .sim/aspect.log)"
else echo "  FAIL"; grep FAIL .sim/aspect.log | head -3; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  mut() {   # name old new arm
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/aspect_vui.sv" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/aspect_vui.sv" $TB 2>"$d/build.log"; then
      echo "  $1: harness failure (anchor or build)"; fail=1
    else
      vvp -n "$d/sim" > "$d/log" 2>&1
      if grep -q "^PASS:" "$d/log"; then echo "  $1: SURVIVED -- the bench cannot see this defect"; fail=1
      elif grep -Eq "FAIL \[($4)\]" "$d/log"; then echo "  $1: caught by $(grep -Em1 "FAIL \[($4)\]" "$d/log" | cut -c1-100)"
      else echo "  $1: failed but NOT in [$4]:"; grep -m2 FAIL "$d/log"; fail=1; fi
    fi
    rm -rf "$d"
  }
  mut A1 "8'd5:  begin sw = 16'd40;  sh = 16'd33; end" "8'd5:  begin sw = 16'd40;  sh = 16'd32; end" "table|sar"
  mut A2 "wire [27:0] rhs = 28'd14 *" "wire [27:0] rhs = 28'd13 *" round
  mut A3 "8'd255: begin sw = ext_sar_w; sh = ext_sar_h; end" "8'd255: begin sw = ext_sar_w; sh = ext_sar_w; end" ext
  mut A4 "known <= valid && (sw != 16'd0) && (sh != 16'd0);" "known <= valid && (sw != 16'd0 || sh != 16'd0);" ext
  mut A5 "known <= valid && (sw != 16'd0)" "known <= 1'b1 && (sw != 16'd0)" valid
  mut A6 "sar_w_o <= (valid && sw != 16'd0 && sh != 16'd0) ? sw : 16'd1;" "sar_w_o <= sw;" sar
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
