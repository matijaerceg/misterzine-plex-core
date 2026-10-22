#!/usr/bin/env bash
# run_dsf_calc.sh -- h264/dec/dsf_calc.sv (DistScaleFactor, 8-197 / 8-198) over every
# (tb, td) difference in -140..140 and two far out of range, against the formula of
# tools/h264_recon_ref.py (bench/h264/dsf_calc_tb.sv). docs/h264_recon.md S2.
#
# --red: mutations on a COPY, each must fail [dsf]:
#   S1  |td / 2| rounded up                      S2  tx not negated for td < 0
#   S3  the +32 rounding dropped                 S4  the upper clip at 1023 dropped
#   S5  tb not clipped to -128..127
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim bench/h264/fixtures/gen
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL=h264/dec/dsf_calc.sv
TB=bench/h264/dsf_calc_tb.sv
python3 - <<'PYEOF'
import sys
sys.path.insert(0, "tools")
import h264_recon_ref as R
out = []
for db in list(range(-140, 141)) + [100000, -100000]:
    for dd in list(range(-140, 141)) + [100000, -100000]:
        tb = R.clip3(-128, 127, db); td = R.clip3(-128, 127, dd)
        if td == 0:
            dsf, z = 0, 1
        else:
            tx = R.c_div(16384 + abs(R.c_div(td, 2)), td)
            dsf, z = R.clip3(-1024, 1023, (tb * tx + 32) >> 6), 0
        out.append("%08x %08x %03x %x" % (db & 0xFFFFFFFF, dd & 0xFFFFFFFF, dsf & 0x7FF, z))
open("bench/h264/fixtures/gen/dsf_cases.txt", "w").write("\n".join(out) + "\n")
PYEOF
echo "== GREEN =="
rm -f .sim/dsf_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/dsf_sim $RTL $TB 2>&1 | grep -v sorry
if vvp -n .sim/dsf_sim > .sim/dsf.log 2>&1 && grep -q "^PASS: dsf_calc_tb" .sim/dsf.log; then
  echo "  PASS $(grep '^dsf_calc_tb:' .sim/dsf.log)"
else echo "  FAIL dsf_calc_tb"; grep -m2 FAIL .sim/dsf.log; fail=1; fi
if [ $red = 1 ]; then
  echo "== MUTATIONS =="
  mut() {
    local d; d=$(mktemp -d); cp $RTL "$d/"
    python3 - "$d/dsf_calc.sv" "$2" "$3" <<'PYEOF'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, f"anchor not unique/found: {old!r}"
open(p, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/dsf_calc.sv" $TB 2>/dev/null; then echo "  $1: harness failure"; fail=1; rm -rf "$d"; return; fi
    vvp -n "$d/sim" > "$d/log" 2>&1
    if grep -q "^PASS" "$d/log"; then echo "  $1: SURVIVED"; fail=1
    elif grep -q "FAIL \[dsf\]" "$d/log"; then echo "  $1: caught by $(grep -m1 FAIL "$d/log" | cut -c1-90)"
    else echo "  $1: failed but not in [dsf]"; grep -m1 FAIL "$d/log"; fail=1; fi
    rm -rf "$d"
  }
  mut S1 "num <= 15'd16384 + {8'd0, td_abs[7:1]};" "num <= 15'd16384 + {8'd0, (td_abs + 8'd1) >> 1};"
  mut S2 "tx <= neg ? -\$signed({1'b0, quo}) : \$signed({1'b0, quo});" "tx <= \$signed({1'b0, quo});"
  mut S3 "wire  signed [24:0] sh = (prod + 25'sd32) >>> 6;" "wire  signed [24:0] sh = prod >>> 6;"
  mut S4 "else if (sh > 25'sd1023) dsf <= 11'sd1023;" "else if (1'b0) dsf <= 11'sd1023;"
  mut S5 "wire signed [7:0] tb_c = (diff_b > 32'sd127) ? 8'sd127 : (diff_b < -32'sd128) ? -8'sd128 : diff_b[7:0];" "wire signed [7:0] tb_c = diff_b[7:0];"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
