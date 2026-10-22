#!/usr/bin/env bash
# run_h264_cabac.sh -- the CABAC engine gate (h264/dec/cabac_engine.sv + cabac_ctx.sv,
# bench/h264/cabac_engine_tb.sv; goldens tools/cabac_vectors.py <- tools/cabac_ref.py)
#
# GREEN:
#   * the .mem tables equal tools/cabac_tables.py (tools/cabac_mem.py --check);
#   * six random vector sets (seeds 1-6, 2-6 KB of stream each, every request kind incl.
#     the I_PCM shape and the end-of-stream drain), bit-exact against the model, the
#     contexts read back after every init, bins/cycle >= 0.5 measured on the unstalled
#     runs; sets 5 and 6 with random input stalls;
#   * the FLUSH pair: set 1 then set 2 through one engine with a FLUSH between.
#   * K_REINIT and S_INIT_CTX both preserve the exact 9-bit initialization offset and flag
#     the 510/511 error boundary.
#
# --red: mutations on a COPY of the RTL, each caught by its own arm on the first set:
#   E1  qCodIRangeIdx from range bits 6:5             -> [bin]
#   E2  valMPS not flipped at pStateIdx 0 on an LPS   -> [bin]
#   E3  bypass compares with > instead of >=          -> [bin]
#   E4  terminate subtracts 1, not 2                  -> [bin]
#   E5  engine init reads 8 bits                       -> [bin]
#   E6  renormalisation one shift short for ranges 64..127 (the LPS path) -> [bin]
#   E7  ALIGN drops nothing                            -> [bin]  (raw bytes / re-init misplaced)
#   C1  context init clips at 127, not 126             -> [ctx]
#   C2  context init shifts the product by 3           -> [ctx]
#   C3  context init reads the wrong table set          -> [ctx]
#   E8  FLUSH keeps the buffered bits                   -> [bin] (the pair arm)
#   E9  the write-back stores the MPS successor's rLPS row on an LPS -> [bin]
#   E10 the decision compares rLPS > range - offset (the boundary: offset = range - rLPS is an LPS) -> [bin]
#   E11 K_REINIT misses top9 == 510 in err_init                         -> [init_boundary]
#   E12 S_INIT_CTX misses top9 == 510 in err_init                       -> [init_boundary]
#   C4  context init stores the row of pStateIdx ^ 1    -> [bin] (the row is not read back)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL="h264/dec/cabac_ctx.sv h264/dec/cabac_engine.sv"
TB=bench/h264/cabac_engine_tb.sv

echo "== GREEN: tables =="
python3 tools/cabac_mem.py --check | sed 's/^/  /' || fail=1

echo "== GREEN: vectors =="
mkdir -p "$GEN"
for s in 1 2 3 4 5 6; do
  python3 tools/cabac_vectors.py --seed $s --bytes $((1500 + 900 * s)) --out "$GEN/cabac_s$s" | sed 's/^/  /' || fail=1
done

# shellcheck disable=SC2086
iverilog -g2012 -o .sim/cabac_sim $RTL $TB || { echo "  FAIL cabac_engine_tb: build"; exit 1; }

run_one() {   # sim stem stall [stem2] -> 0 on PASS; log in .sim/cabac_last.log
  local args="+stem=$2 +stall=$3"
  [ -n "${4:-}" ] && args="$args +stem2=$4"
  # shellcheck disable=SC2086
  vvp -n "$1" $args 2>&1 | grep -v 'readmem\|Not enough words' > .sim/cabac_last.log
  grep -q "^PASS: cabac_engine_tb" .sim/cabac_last.log
}
report() {    # label sim stem stall [stem2]
  if run_one "$2" "$3" "$4" "${5:-}"; then
    echo "  PASS $1: $(grep '^cabac_engine_tb:' .sim/cabac_last.log | head -1 | sed 's/^cabac_engine_tb: //')"
  else echo "  FAIL $1"; grep FAIL .sim/cabac_last.log | head -3; fail=1; fi
}

for s in 1 2 3 4; do report "cabac_s$s" .sim/cabac_sim "$GEN/cabac_s$s" 0; done
for s in 5 6; do report "cabac_s$s +stall" .sim/cabac_sim "$GEN/cabac_s$s" $s; done
report "flush pair s1+s2" .sim/cabac_sim "$GEN/cabac_s1" 0 "$GEN/cabac_s2"

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new arm-pattern [stem2]
    local name=$1 file=$2 old=$3 new=$4 pat=$5 stem2=${6:-}
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/cabac_ctx.sv" "$d/cabac_engine.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local args="+stem=$GEN/cabac_s1 +stall=0"
    [ -n "$stem2" ] && args="$args +stem2=$stem2"
    # shellcheck disable=SC2086
    vvp -n "$d/sim" $args 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: cabac_engine_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL $pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 "FAIL $pat" "$d/log" | cut -c1-78)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  E=h264/dec/cabac_engine.sv; C=h264/dec/cabac_ctx.sv
  mut E1 $E "case (rng[7:6])" "case (rng[6:5])" '\[bin\]' &
  mut E2 $E "(p_state == 6'd0) ? ~val_mps : val_mps" "val_mps" '\[bin\]' &
  mut E3 $E "byp_bin  = (off_byp >= {1'b0, rng});" "byp_bin  = (off_byp > {1'b0, rng});" '\[bin\]' &
  mut E4 $E "rng_term = rng - 9'd2;" "rng_term = rng - 9'd1;" '\[bin\]' &
  mut E5 $E "K_REINIT:    take = 4'd9;" "K_REINIT:    take = 4'd8;" '\[bin\]' &
  mut E6 $E "9'b001??????: sh_dec = 4'd2;" "9'b001??????: sh_dec = 4'd1;" '\[bin\]' &
  wait
  mut E7 $E "K_ALIGN:     take = {1'b0, bcnt[2:0]};" "K_ALIGN:     take = 4'd0;" '\[bin\]' &
  mut C1 $C "(pre0 > 15'sd126) ? 7'd126" "(pre0 > 15'sd127) ? 7'd127" '\[ctx\]' &
  mut C2 $C "(prod_q >>> 4) + n_q" "(prod_q >>> 3) + n_q" '\[ctx\]' &
  mut C3 $C "{2'b00, set_q} * 11'd460" "{2'b00, set_q} * 11'd459" '\[ctx\]' &
  mut E8 $E "bbuf <= 32'd0; bcnt <= 6'd0; eos <= 1'b0; renorm_pending <= 1'b0;\n                err_init" "eos <= 1'b0; renorm_pending <= 1'b0;\n                err_init" '\[bin\]' "$GEN/cabac_s2" &
  wait
  mut E9 $E "is_lps ? rnext[63:32] : rnext[31:0]" "rnext[31:0]" '\[bin\]' &
  mut E10 $E "(\$signed({3'b000, r_lps}) >= t_ro)" "(\$signed({3'b000, r_lps}) > t_ro)" '\[bin\]' &
  mut E11 $E "K_REINIT: begin\n                            rng <= 9'd510; off <= {1'b0, top9};\n                            if (top9 >= 9'd510) err_init <= 1'b1;" \
         "K_REINIT: begin\n                            rng <= 9'd510; off <= {1'b0, top9};\n                            if (top9 >= 9'd511) err_init <= 1'b1;" '\[init_boundary\]' &
  mut E12 $E "S_INIT_CTX: if (!ctx_init_busy && !ctx_init_start && enough) begin\n                    rng <= 9'd510; off <= {1'b0, top9};\n                    if (top9 >= 9'd510) err_init <= 1'b1;" \
         "S_INIT_CTX: if (!ctx_init_busy && !ctx_init_start && enough) begin\n                    rng <= 9'd510; off <= {1'b0, top9};\n                    if (top9 >= 9'd511) err_init <= 1'b1;" '\[init_boundary\]' &
  mut C4 $C "row_rom[s3_st[5:0]]" "row_rom[s3_st[5:0] ^ 6'd1]" '\[bin\]' &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
