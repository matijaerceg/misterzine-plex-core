#!/usr/bin/env bash
# run_ovl_plane.sh -- the overlay plane (Phase 6b, interface 0.9; docs/architecture.md "The overlay
# plane"): h264/ovl_plane.sv on the real raster behind h264/ddr_mux2.sv beside a random master A
# into bench/h264/ddr_model.sv, h264/ovl_blend.sv on every dot (bench/h264/ovl_plane_tb.sv),
# against tools/ovl_ref.py (written from the architecture's text: the descriptor's checks, the
# formats, the premultiply and the (1, 2, 1), round(x / 255) in plain integers).
#
# GREEN, every active dot of every refresh ([pix] the overlay's premultiplied RGBA at LAT 5,
# [blend] the composite over a position pattern, [status] words 46-47's fields at each vertical
# blank -- ovl_lines exact: each canvas line fetched once a field -- [live] never vacuous):
#   p1555      720x480 at 480p, a page flip between two pages
#   p4444      640x400 centred, a padded stride, a band (100..299)
#   p8888clip  720x576 on the 480-line raster: centred, clipped, ovl_clip
#   i1555at    480i with the anti-twitter, the whole canvas (both fields' edge lines)
#   i4444odd   480i unfiltered, 333x211 (odd width, height and offset)
#   i8888pal   576i with the anti-twitter, a band (200..263): its edges filtered against zero
#   inarrow    480i with the anti-twitter, 4444 canvases 1 and 3 pixels wide (both fields each):
#              an op's accumulator words read a clock or two after the op before wrote them
#   desc       13 descriptors: accepted, CTL x2, SIZE, STRIDE, ALIGN, BAND, RANGE (8 bytes past
#              the region), the region's exact end accepted, torn (the previous kept), ENABLE
#              clear, no session (accepted, not shown), accepted again
#   late       the port 97 % busy: lines late -- each line the model's or wholly transparent,
#              the dropped ones counted, the lines after them exact (the chain restarts)
#
# --red: mutations on a COPY of the RTL, each caught by its own arm (scenario and label):
#   O1  the 1555 colour widened with zeros (not replicated)          -> p1555 [pix]
#   O2  the 4444 alpha widened with zeros                            -> p4444 [pix]
#   O3  8888's red and blue swapped                                  -> p8888clip [pix]
#   O4  div255's +128 -> +127 (the premultiply)                      -> p8888clip [pix]
#   O5  the filter's centre tap weight 2 -> 1                        -> i1555at [pix]
#   O6  the filter's rounding +2 -> +1                               -> i1555at [pix]
#   O7  every filtered line a prologue (c - 1 fetched again)         -> i1555at [status] (the pixels
#       are right: only the fetch count -- once a field -- sees it)
#   O8  the chain survives the vertical blank (neither a blank line nor a refresh's first line
#       resets it)                                                   -> i1555at [pix]
#       (either reset ALONE removed is EQUIVALENT: every refresh begins after blank lines, and a
#       blank line clears the chain -- measured, it survived; both stay as each other's guard)
#   O9  the band's last line excluded                                -> p4444 [pix]
#   O10 the horizontal centring not halved                           -> p4444 [pix]
#   O11 the vertical centring not halved                             -> p4444 [pix]
#   O12 the vertical offset's shift logical (a taller canvas)        -> p8888clip [pix]
#   O13 RANGE refuses a page ending exactly at the region's end      -> desc [status]
#   O14 STRIDE refuses a stride of exactly width x bytes             -> desc [status]
#   O15 a torn descriptor taken (gen_lo / gen_hi ignored)            -> desc [status]
#   O16 shown without a session                                      -> desc [pix]
#   O17 ENABLE ignored                                               -> desc [pix]
#   O18 dot 0 read with the previous line's slot / state             -> p1555 [pix]
#   O19 a late line not counted                                      -> late [status]
#   O20 a late line shown anyway (half-written)                      -> late [pix]
#   O21 the beat FIFO's room check dropped (overflow)                -> p1555 [pix] / the model's [ddr]
#   O22 a request re-issued under waitrequest                        -> p1555 [avalon]
#   O23 the composite's 255 - a -> 256 - a                           -> p4444 [blend]
#   O24 the composite's rounding +128 -> +127                        -> p8888clip [blend] (4444's
#       alphas, multiples of 17, never give a product where +127 and +128 part: x = 128 mod 255)
#   O25 the third 16 bpp pixel of a beat taken from the second        -> p4444 [pix]
#   O26 8888's two pixels of a beat swapped                          -> p8888clip [pix]
#   O27 the line read from the slot being written                    -> p1555 [pix]
#   O28 16 bpp words a line rounded down                             -> i4444odd [pix]
#   O29 the filter regardless of the option                          -> i4444odd [pix]
#   O30 the active lines stop at 480                                 -> i8888pal [pix]
#   O31 the descriptor read 8 words off                              -> p1555 [status]
#   O32 no premultiply (straight colour)                             -> p8888clip [pix]
#   O33 no bubble between ops (the accumulator read before written)  -> inarrow [pix] (720-wide
#       canvases cannot see it: an op's first word is written long before the next op reads it)
#   O34 a canvas line's address from c's low 10 bits (unsigned)      -> inarrow [pix] -- the bug
#       inarrow found (2026-09-30): on the line above a centred, filtered canvas c = -1, and c + 1's
#       address (canvas line 0) came out as line 1024's; no 720-wide or uncentred arm reaches it
#   (0.10, docs/hdmi_raster.md stage 2: n8888wide -- a 1,024-wide 8888 canvas on a native 852x480
#   raster, clipped 86 columns each side, then a 640x300 4444 one centred; n1555tall -- a 400x1000
#   canvas on a native 480x854 raster at 50 Hz, clipped 73 lines top and bottom)
#   O35 the canvas centred on 720, not the raster's width            -> n8888wide [pix]
#   O36 the left offset halved unsigned (a wider canvas lost)        -> n8888wide [pix]
#   O37 the frame wrap at 624, not the frame's own last line         -> n1555tall [pix] / [status]
#   O38 8888 words a line one bit short (0.12: 10 bits; 2,048 pixels = 1,024 words -> 0)
#                                                                    -> n8888w2k [pix] (a 2,048-wide
#       8888 canvas on the 2048x448 native raster: no narrower canvas sets that bit)
# ~1 min GREEN (the arms in parallel), ~6 with --red.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
MODEL=bench/h264/ddr_model.sv
TB=bench/h264/ovl_plane_tb.sv
OTHERS="h264/ovl_blend.sv h264/sfifo.sv h264/ddr_mux2.sv h264/sync_gen.sv $MODEL"
ARMS=(p1555 p4444 p8888clip i1555at i4444odd i8888pal inarrow desc late n8888wide n1555tall n8888hd n4444w2k n8888w2k)
args_of() { if [ "$1" = late ]; then echo "+arm=late +late +wait_pct=97"; else echo "+arm=$1"; fi; }

for a in "${ARMS[@]}"; do python3 tools/ovl_ref.py "$a" > /dev/null || { echo "FAIL: the model ($a)"; exit 1; }; done

echo "== GREEN =="
rm -f .sim/ovl_plane_sim   # iverilog leaves the old binary on a failed build: never run it
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/ovl_plane_sim h264/ovl_plane.sv $OTHERS $TB 2>&1 | grep -v "sorry\|warning"
[ -f .sim/ovl_plane_sim ] || { echo "FAIL: build"; exit 1; }
arm() {
  local a=$1
  # shellcheck disable=SC2046
  if timeout 1500 vvp -n .sim/ovl_plane_sim $(args_of "$a") > .sim/ovl_$a.log 2>&1 && grep -q "^PASS: ovl_plane_tb $a" .sim/ovl_$a.log; then
    echo "  PASS $a: $(grep "^ovl_plane_tb $a:" .sim/ovl_$a.log | sed "s/^ovl_plane_tb $a: //")" > .sim/ovl_$a.res
  else { echo "  FAIL $a"; grep FAIL .sim/ovl_$a.log | head -3; echo OVLFAIL; } > .sim/ovl_$a.res; fi
}
for a in "${ARMS[@]}"; do arm "$a" & done
wait
for a in "${ARMS[@]}"; do grep -v '^OVLFAIL$' .sim/ovl_$a.res; grep -q '^OVLFAIL$' .sim/ovl_$a.res && fail=1; done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new scenario label(s regex)
    local name=$1 file=$2 old=$3 new=$4 sc=$5 lab=$6
    local d; d=$(mktemp -d)
    cp "$file" "$d/"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
# one defect may need two edits: anchors joined by @@AND@@, each replaced by its partner
for o, n in zip(old.split("@@AND@@"), new.split("@@AND@@")):
    assert s.count(o) == 1, f"mutation anchor not unique/found: {o!r}"
    s = s.replace(o, n)
open(path, "w").write(s)
PYEOF
    local ok=$?
    # the plane or the blend replaced by its mutant; the rest as shipped. ovl_plane.sv includes
    # h264/ring_iface.svh, which no mutation touches (the repo's copy is the one compiled).
    local files="h264/ovl_plane.sv $OTHERS"
    files=${files/$file/$d/$(basename "$file")}
    # shellcheck disable=SC2086
    if [ $ok != 0 ] || ! iverilog -g2012 -o "$d/sim" $files $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2046
    timeout 1500 vvp -n "$d/sim" $(args_of "$sc") > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED ($sc) -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($lab)\]" "$d/log"; then
      echo "  $name: caught by $sc $(grep -Em1 "FAIL \[($lab)\]" "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed ($sc) but NOT in [$lab]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  P=h264/ovl_plane.sv; B=h264/ovl_blend.sv
  mut O1 $P "u_r = {p1_raw[14:10], p1_raw[14:12]};" "u_r = {p1_raw[14:10], 3'd0};" p1555 pix &
  mut O2 $P "u_a = {p1_raw[15:12], p1_raw[15:12]};" "u_a = {p1_raw[15:12], 4'd0};" p4444 pix &
  mut O3 $P "u_a = p1_raw[31:24]; u_r = p1_raw[23:16]; u_g = p1_raw[15:8]; u_b = p1_raw[7:0];" "u_a = p1_raw[31:24]; u_r = p1_raw[7:0]; u_g = p1_raw[15:8]; u_b = p1_raw[23:16];" p8888clip pix &
  mut O4 $P "wire  [16:0] t_r = {1'b0, m3_r} + 17'd128," "wire  [16:0] t_r = {1'b0, m3_r} + 17'd127," p8888clip pix &
  mut O5 $P "d2_r = a_r + {1'b0, p4_r, 1'b0}," "d2_r = a_r + {2'd0, p4_r}," i1555at pix &
  mut O6 $P "s_r = a_r + {2'd0, p4_r} + 10'd2," "s_r = a_r + {2'd0, p4_r} + 10'd1," i1555at pix &
  mut O7 $P "wire         cmd_pro_next = r_at && !chain;" "wire         cmd_pro_next = r_at;" i1555at status &
  mut O8 $P "                            ovl_at <= il && at_en;
                            chain <= 1'b0;@@AND@@if (!ln_act) chain <= 1'b0;" "                            ovl_at <= il && at_en;@@AND@@if (!ln_act) ;" i1555at pix &
  wait
  mut O9 $P "wire         v_0 = (ln_c  >= \$signed({1'd0, r_bf})) && (ln_c  <= \$signed({1'd0, r_bl}));" "wire         v_0 = (ln_c  >= \$signed({1'd0, r_bf})) && (ln_c  < \$signed({1'd0, r_bl}));" p4444 pix &
  mut O10 $P "r_ox <= ox_n >>> 1;" "r_ox <= ox_n;" p4444 pix &
  mut O11 $P "r_oy <= oy_n >>> 1;" "r_oy <= oy_n;" p4444 pix &
  mut O12 $P "r_oy <= oy_n >>> 1;" "r_oy <= {1'b0, oy_n[12:1]};" p8888clip pix &
  mut O13 $P "(q_end > ({1'b0, RI_FB_BYTE} + {1'b0, RI_FB_SIZE}))" "(q_end >= ({1'b0, RI_FB_BYTE} + {1'b0, RI_FB_SIZE}))" desc status &
  mut O14 $P "({2'd0, q_s} < q_wb)" "({2'd0, q_s} <= q_wb)" desc status &
  mut O15 $P "f_torn <= (dq[0] != dq[7]);" "f_torn <= 1'b0;" desc status &
  mut O16 $P "r_on <= nd_on && sess;" "r_on <= nd_on;" desc pix &
  wait
  mut O17 $P "if (!q_ctl[0]) begin" "if (1'b0) begin" desc "pix|status" &
  mut O18 $P "wire         e_ok = dot0 ? line_ok_d0 : cur_ok;" "wire         e_ok = cur_ok;" p1555 pix &
  mut O19 $P "if (nx_want && !line_ok_d0 && ovl_late != 16'hFFFF) ovl_late <= ovl_late + 16'd1;" "if (1'b0) ovl_late <= ovl_late + 16'd1;" late status &
  mut O20 $P "cur_ok <= line_ok_d0; cur_slot <= nx_slot;" "cur_ok <= nx_want; cur_slot <= nx_slot;" late pix &
  mut O21 $P "<= 9'd64;" "<= 9'd200;" p1555 "pix|ddr" &
  mut O22 $P "            if (!ddr_read || !ddr_waitrequest) begin
                ddr_read <= 1'b0;" "            if (1'b1) begin
                ddr_read <= 1'b0;" p1555 "avalon|ddr" &
  mut O23 $B "wire  [7:0]  ia  = 8'd255 - p_a;" "wire  [7:0]  ia  = 8'd0 - p_a;" p4444 blend &
  mut O24 $B "t_r = {1'b0, m_r} + 17'd128," "t_r = {1'b0, m_r} + 17'd127," p8888clip blend &
  wait
  mut O25 $P "2'd2: k_raw = {16'd0, k_beat[47:32]};" "2'd2: k_raw = {16'd0, k_beat[31:16]};" p4444 pix &
  mut O26 $P "1'b0: k_raw = k_beat[31:0];" "1'b0: k_raw = k_beat[63:32];" p8888clip pix &
  mut O27 $P "cmd_slot <= !cmd_slot; nx_slot <= !cmd_slot;" "cmd_slot <= !cmd_slot; nx_slot <= cmd_slot;" p1555 pix &
  mut O28 $P "wd_16 = {1'b0, nd_w} + 13'd3;" "wd_16 = {1'b0, nd_w} + 13'd2;" i4444odd pix &
  mut O29 $P "r_at <= il && at_en;" "r_at <= il;" i4444odd pix &
  mut O30 $P "wire  [11:0] lines = il ? (pal ? 12'd576 : 12'd480) : rast_lines;" "wire  [11:0] lines = il ? 12'd480 : rast_lines;" i8888pal "pix|status" &
  mut O31 $P "ddr_address <= RI_OVL_DESC_WORD;" "ddr_address <= RI_OVL_DESC_WORD + 29'd8;" p1555 status &
  mut O32 $P "m3_r <= c2_r * c2_a;" "m3_r <= {c2_r, 8'd0};" p8888clip pix &
  wait
  mut O34 $P "ln_prod <= ln_c * \$signed({1'b0, r_s});" "ln_prod <= {20'd0, ln_c[9:0]} * {13'd0, r_s};" inarrow pix &
  mut O33 $P "else begin k_op <= k_op + 2'd1; k_gap <= 3'd4; end" "else begin k_op <= k_op + 2'd1; k_gap <= 3'd0; end" inarrow pix &
  wait
  # (0.10) the native raster: the canvas on the raster's own width, clipped, its frame's wrap
  mut O35 $P "wire  [11:0] rw    = il ? 12'd720 : rast_w;" "wire  [11:0] rw    = 12'd720;" n8888wide pix &
  mut O36 $P "r_ox <= ox_n >>> 1;" "r_ox <= {1'b0, ox_n[12:1]};" n8888wide pix &
  mut O37 $P "((v_pos == rast_last) ? 12'd0 : v_pos + 12'd1);" "((v_pos == (pal ? 12'd624 : 12'd524)) ? 12'd0 : v_pos + 12'd1);" n1555tall "pix|status" &
  mut O38 $P "r_words <= (nd_fmt == RO_FMT_8888) ? wd_32[11:1] : wd_16[12:2];" "r_words <= (nd_fmt == RO_FMT_8888) ? {1'b0, wd_32[10:1]} : wd_16[12:2];" n8888w2k pix &
  wait
  for f in "$RES"/*; do grep -v '^MUTFAIL$' "$f"; grep -q '^MUTFAIL$' "$f" && fail=1; done
  rm -rf "$RES"
fi

if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; exit 1; fi
