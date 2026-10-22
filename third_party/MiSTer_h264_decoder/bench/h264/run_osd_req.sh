#!/usr/bin/env bash
# run_osd_req.sh -- h264/osd_req.sv (interface 0.4: a program's settings request -> hps_io's
# status_in / status_set) against tools/osd_req_ref.py, the rule written from
# docs/architecture.md (bench/h264/osd_req_tb.sv). The end-to-end path (the engine's poll, the
# hand-over, a stand-in Main) is run_ring_rd.sh's R22.
#
# GREEN: 2,000 random requests over random menu states -- every result code reached (the
#   bench's coverage check): [err] the result, [set] status_set once exactly when applied,
#   [merge] status_in (each masked option at its CONF_STR bits, every other bit kept, the
#   OSD's Reset and (0.8) its two action bits forced 0), [seq] the sequence number reported.
# --red: mutations on a COPY, each caught by its own arm:
#   O1 Aspect's range unchecked (3 accepted)            -> [err]
#   O2 the reserved bits not checked                    -> [err]
#   O3 an empty mask accepted                           -> [err]
#   O4 the OSD's Reset passed through                   -> [merge]
#   O5 HDMI Deinterlace merged at the wrong bit         -> [merge]
#   O6 status_set never cleared (held high)            -> [set]
#   O7 Anti-Twitter merged into Refresh Rate's bits     -> [merge]
#   O8 (0.8) an OSD action bit passed through           -> [merge]
#   O9 De-flicker request does not update new bit 29    -> [deflicker]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL=h264/osd_req.sv; TB=bench/h264/osd_req_tb.sv; VEC=.sim/osd_req_vec.txt
python3 tools/osd_req_ref.py 2000 $VEC | sed 's/^/  /'
echo "== GREEN =="
rm -f .sim/osd_req_sim   # iverilog leaves the old binary on a failed build: never run it
if iverilog -g2012 -o .sim/osd_req_sim $RTL $TB && vvp -n .sim/osd_req_sim +vec=$VEC > .sim/osd_req.log 2>&1 \
   && grep -q "^PASS: osd_req_tb" .sim/osd_req.log; then
  echo "  PASS $(grep '^osd_req_tb:' .sim/osd_req.log)"
else echo "  FAIL"; grep FAIL .sim/osd_req.log | head -3; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  ROOT=$PWD
  mut() {   # name old new arm
    local d; d=$(mktemp -d)
    mkdir -p "$d/h264"; cp $RTL "$d/h264/"
    python3 - "$d/$RTL" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o "$d/sim" "$d/$RTL" "$ROOT/$TB" 2>"$d/build.log"); then
      echo "  $1: harness failure (anchor or build)"; fail=1
    else
      timeout 600 vvp -n "$d/sim" +vec="$ROOT/$VEC" > "$d/log" 2>&1
      if grep -q "^PASS:" "$d/log"; then echo "  $1: SURVIVED -- the bench cannot see this defect"; fail=1
      elif grep -Eq "FAIL \[($4)\]" "$d/log"; then echo "  $1: caught by $(grep -Em1 "FAIL \[($4)\]" "$d/log" | cut -c1-100)"
      else echo "  $1: failed but NOT in [$4]:"; grep -m2 FAIL "$d/log"; fail=1; fi
    fi
    rm -rf "$d"
  }
  mut O1 "wire         bad_range = (m[0] && v[1:0]   == 2'd3) ||" "wire         bad_range = (1'b0) ||" err
  mut O2 "else if (bad_reserved)               err <= 3'd2;" "else if (1'b0)    err <= 3'd2;" err
  mut O3 "if (m == 7'd0)                       err <= 3'd3;" "if (1'b0)                       err <= 3'd3;" "err|set"
  mut O4 "status_in[0] <= 1'b0;" "status_in[0] <= status[0];" merge
  mut O5 "if (m[3]) status_in[7]     <= v[6];" "if (m[3]) status_in[10]    <= v[6];" merge
  mut O6 "            status_set <= 1'b0;
            if (fresh) begin" "            if (fresh) begin" "set"
  mut O7 "status_in[16:15] <= v[12:11];" "status_in[12:11] <= v[12:11];" merge
  mut O8 "status_in[18:17] <= 2'b00;" "status_in[18:17] <= {1'b0, status[17]};" merge
  mut O9 "status_in[29] <= (v[12:11] != 2'd2);" "status_in[29] <= status[29];" deflicker
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
