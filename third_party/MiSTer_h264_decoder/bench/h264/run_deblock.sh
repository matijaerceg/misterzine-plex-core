#!/usr/bin/env bash
# run_deblock.sh -- the deblocking leaf units' gate (h264/dec/deblock_filter.sv,
# h264/dec/deblock_bs.sv; bench/h264/deblock_filter_tb.sv, deblock_bs_tb.sv; goldens
# tools/deblock_golden.py <- tools/h264_recon_ref.py's filter_line / boundary_strength)
#
# GREEN (docs/h264_recon.md S2.4): every output of every case equals the model's:
#   * deblock_filter_tb: the directed classes at every threshold (alpha, beta, tc0, tcc,
#     p1, strong, c4, dclip, idxclip, pcm), random lines, and -- with ffmpeg's libx264 --
#     the lines the model filtered while decoding an x264 clip made at run time (B frames,
#     three references, adaptive quantisation, deblock offsets 2/-1; the recorded decode is
#     checked bit-exact vs ffmpeg inside the generator); SKIP of the clip arm without libx264;
#   * deblock_bs_tb: the directed classes (intra_mb, intra_in, flags -- all 252 reachable
#     flag combinations --, nz, nvec, refset, mv1h, mv1v, mv2d, mv2s), random pairs, and the
#     clip's recorded pairs (frame-coded: x264 has no PAFF, the field cases are directed);
#   * both again with input gaps (+stall=3: garbage on the inputs while in_valid is low),
#     and the latency arm on every run.
#
# --red: mutations on a COPY of the unit, each caught by the case class written for it,
# scored ALONE (+only=<class>) -- the classes are not ordered so that the designated one
# always fails first (an alpha case with a large |p0-q0| clips its delta at tC and would
# see a tC0 defect before the tc0 class does), so the verdict is "the named class alone
# catches it"; the full run's failing classes are listed for information:
#   deblock_filter.sv
#   F1  Table 8-16 alpha[30] 25 -> 26                                   -> [out] alpha
#   F2  Table 8-16 beta[30] 8 -> 9                                      -> [out] beta
#   F3  Table 8-17 tC0[bS 2][40] 5 -> 6                                 -> [out] tc0
#   F4  chroma tC = tC0 + 1 becomes tC0                                 -> [out] tcc
#   F5  the luma p1 / q1 term clipped at tC instead of tC0 (8-470)      -> [out] p1
#   F6  the strong-filter condition (alpha >> 2) + 2 becomes + 1        -> [out] strong
#   F7  the chroma bS 4 filter (8-481) reads q0 for q1                  -> [out] c4
#   F8  the delta clip's upper bound tC + 1 (8-468)                     -> [out] dclip
#   F9  the delta's arithmetic >> 3 becomes a logical shift             -> [out] dclip
#   F10 indexA no longer clipped at 51 (8-462)                          -> [out] idxclip
#   F11 in_valid ignored (a_valid always 1)                             -> [lat]
#   deblock_bs.sv
#   B1  the field picture's vertical limit 2 becomes 4 (NOTE 3)         -> [bs] mv1v
#   B2  a horizontal macroblock edge of a field picture with intra: 4 not 3 -> [bs] intra_mb
#   B3  the same picture twice: only the straight pairing tested        -> [bs] mv2s
#   B4  the number-of-vectors test dropped                              -> [bs] nvec
#   B5  the non-zero-coefficient test on q only                         -> [bs] nz
#   B6  the crossed picture pairing not recognised as the same set      -> [bs] refset
#   B7  the horizontal limit 4 becomes 8                                -> [bs] mv1h
#   B8  in_valid ignored (out_valid always 1)                           -> [lat]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/h264/fixtures/gen
RTL_F=h264/dec/deblock_filter.sv
RTL_B=h264/dec/deblock_bs.sv
TB_F=bench/h264/deblock_filter_tb.sv
TB_B=bench/h264/deblock_bs_tb.sv
STEM_F="$GEN/deblock_filter"
STEM_B="$GEN/deblock_bs"
mkdir -p "$GEN"

rm -f .sim/dbf_sim   # iverilog leaves the old binary on a failed build: never run it

iverilog -g2012 -o .sim/dbf_sim $RTL_F $TB_F 2>&1 | grep -v sorry
[ -f .sim/dbf_sim ] || { echo "  FAIL deblock_filter_tb: build"; exit 1; }
rm -f .sim/dbs_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/dbs_sim $RTL_B $TB_B 2>&1 | grep -v sorry
[ -f .sim/dbs_sim ] || { echo "  FAIL deblock_bs_tb: build"; exit 1; }

echo "== FIXTURES =="
CLIP=""
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  CLIP=".sim/deblock_x264.264"
  rm -f "$CLIP"            # the generator makes it (a run-time clip, never stale)
else
  echo "  SKIP clip arm: ffmpeg with libx264 not found"
fi
# shellcheck disable=SC2086
if python3 tools/deblock_golden.py --out "$GEN" ${CLIP:+--clip "$CLIP"} > .sim/deblock_fx.log 2>&1; then
  sed 's/^/  /' .sim/deblock_fx.log
else
  echo "  FAIL fixtures"; tail -5 .sim/deblock_fx.log; fail=1
fi

run_one() {   # sim stem stall only -> 0 on PASS; log in .sim/deblock_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" ${4:+"+only=$4"} 2>&1 | grep -v 'readmem\|Not enough words' > .sim/deblock_last.log
  grep -q "^PASS: " .sim/deblock_last.log
}
report() {    # label sim stem stall
  if run_one "$2" "$3" "$4" ""; then
    echo "  PASS $1: $(grep -v '^PASS\|cases' .sim/deblock_last.log | grep '_tb:' | head -1 | sed 's/^[a-z_]*_tb: //')"
  else echo "  FAIL $1"; grep 'FAIL' .sim/deblock_last.log | head -3; fail=1; fi
}

echo "== GREEN =="
if [ -f "$STEM_F.meta.hex" ] && [ -f "$STEM_B.meta.hex" ]; then
  report "deblock_filter, one line per cycle" .sim/dbf_sim "$STEM_F" 0
  report "deblock_filter, +stall"             .sim/dbf_sim "$STEM_F" 3
  report "deblock_bs, one pair per cycle"     .sim/dbs_sim "$STEM_B" 0
  report "deblock_bs, +stall"                 .sim/dbs_sim "$STEM_B" 3
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own case class, scored alone) =="
  RES=$(mktemp -d)
  mut() {   # name unit(f|b) old new arm class   (class "" = the arm alone, on the full set)
    local name=$1 unit=$2 old=$3 new=$4 arm=$5 cls=$6
    local rtl tb stem
    if [ "$unit" = f ]; then rtl=$RTL_F; tb=$TB_F; stem=$STEM_F; else rtl=$RTL_B; tb=$TB_B; stem=$STEM_B; fi
    local d; d=$(mktemp -d)
    cp "$rtl" "$d/unit.sv"
    python3 - "$d/unit.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/unit.sv" "$tb" 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # the full set: for the record, which classes see it
    vvp -n "$d/sim" "+stem=$stem" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    local seen; seen=$(grep -m1 '^FAILCLS:' "$d/log" | sed 's/^FAILCLS: *//')
    if [ -n "$cls" ]; then
      # the named class alone must catch it
      vvp -n "$d/sim" "+stem=$stem" +stall=0 "+only=$cls" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log1"
      if grep -q "^PASS: " "$d/log1"; then
        { echo "  $name: SURVIVED class $cls alone (full run: ${seen:-nothing})"; echo MUTFAIL; } > "$RES/$name"
      elif grep -q "FAIL \[$arm\]" "$d/log1" && grep -q "^FAILCLS: .*\b$cls=" "$d/log1"; then
        echo "  $name: caught by [$arm] $cls alone ($(grep -m1 '^FAILCLS:' "$d/log1" | sed "s/^FAILCLS: *//") of $(grep -m1 'selected of class' "$d/log1" | sed 's/.*cases, \([0-9]*\) selected.*/\1/')); full run: $seen" > "$RES/$name"
      else
        { echo "  $name: failed but NOT by [$arm] in class $cls:"; grep -m2 FAIL "$d/log1"; echo MUTFAIL; } > "$RES/$name"
      fi
    else
      if grep -q "^PASS: " "$d/log"; then
        { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
      elif grep -q "FAIL \[$arm\]" "$d/log"; then
        echo "  $name: caught by $(grep -m1 "FAIL \[$arm\]" "$d/log" | cut -c1-90)" > "$RES/$name"
      else
        { echo "  $name: failed but NOT by [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
      fi
    fi
    rm -rf "$d"
  }
  mut F1  f "6'd30: alpha = 8'd25;" "6'd30: alpha = 8'd26;" out alpha &
  mut F2  f "6'd30: beta = 5'd8;" "6'd30: beta = 5'd9;" out beta &
  mut F3  f "{3'd2, 6'd40}: tc0 = 5'd5;" "{3'd2, 6'd40}: tc0 = 5'd6;" out tc0 &
  mut F4  f "wire [4:0] b_tc     = a_chroma ? tc0 + 5'd1 :" "wire [4:0] b_tc     = a_chroma ? tc0 + 5'd0 :" out tcc &
  mut F5  f "assign t1p_clip = (b_t1p > tc0_s) ? tc0_s : (b_t1p < -tc0_s) ? -tc0_s : b_t1p;" "assign t1p_clip = (b_t1p > tc_s) ? tc_s : (b_t1p < -tc_s) ? -tc_s : b_t1p;" out p1 &
  mut F6  f "wire [7:0] a_quarter = {2'b00, alpha[7:2]} + 8'd2;" "wire [7:0] a_quarter = {2'b00, alpha[7:2]} + 8'd1;" out strong &
  wait
  mut F7  f "wire [10:0] w_q0 = ({2'd0, a_q1, 1'b0} + {3'd0, a_q0} + {3'd0, a_p1} + 11'd2) >> 2;" "wire [10:0] w_q0 = ({2'd0, a_q0, 1'b0} + {3'd0, a_q0} + {3'd0, a_p1} + 11'd2) >> 2;" out c4 &
  mut F8  f "assign d_clip   = (b_d > tc_s) ? tc_s : (b_d < -tc_s) ? -tc_s : b_d;" "assign d_clip   = (b_d > tc_s) ? tc_s + 12'sd1 : (b_d < -tc_s) ? -tc_s : b_d;" out dclip &
  mut F9  f "wire signed [11:0] d_sh   = d_raw >>> 3;" "wire signed [11:0] d_sh   = d_raw >> 3;" out dclip &
  mut F10 f "wire [5:0]        idx_a  = sum_a[7] ? 6'd0 : (sum_a > 8'sd51) ? 6'd51 : sum_a[5:0];" "wire [5:0]        idx_a  = sum_a[7] ? 6'd0 : sum_a[5:0];" out idxclip &
  mut F11 f "a_valid <= in_valid;" "a_valid <= 1'b1;" lat "" &
  wait
  mut B1  b "    wire neary_00 = field ? near2_y00 : near4_y00;\n    wire neary_11 = field ? near2_y11 : near4_y11;\n    wire neary_01 = field ? near2_y01 : near4_y01;\n    wire neary_10 = field ? near2_y10 : near4_y10;" "    wire neary_00 = near4_y00;\n    wire neary_11 = near4_y11;\n    wire neary_01 = near4_y01;\n    wire neary_10 = near4_y10;" bs mv1v &
  mut B2  b "wire bs4    = mb_edge && intra && (!field || vertical);" "wire bs4    = mb_edge && intra;" bs intra_mb &
  mut B3  b "mv_far = (far00 || far11) && (far01 || far10);" "mv_far = (far00 || far11);" bs mv2s &
  mut B4  b "wire bs1    = n_diff || !same_set || mv_far;" "wire bs1    = !same_set || mv_far;" bs nvec &
  mut B5  b "else if (p_nz || q_nz)    bs_c = 3'd2;" "else if (q_nz)            bs_c = 3'd2;" bs nz &
  mut B6  b "same_set = straight_pics || crossed_pics;" "same_set = straight_pics;" bs refset &
  mut B7  b "wire near4_x00 = (dx00[16:2] == 15'd0) || ((&dx00[16:2]) && (dx00[1:0] != 2'b00));" "wire near4_x00 = (dx00[16:3] == 14'd0) || ((&dx00[16:3]) && (dx00[2:0] != 3'b000));" bs mv1h &
  mut B8  b "out_valid <= in_valid;" "out_valid <= 1'b1;" lat "" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
