#!/usr/bin/env bash
# run_scaffold.sh -- the P0 gate: raster + idle screen benches, GREEN then MUTATED, plus
# the emu.sv wiring check and the undriven-signal lint.
#
# GREEN: sync_gen_tb (measures the 480p raster), sync_gen_il_tb (the 480i raster: P6,
# docs/analog.md), each also at 60.00 Hz and 50 Hz (+std=1 / 2: P6 steps 5 / 6, §10 --
# 450,000 dots a frame with every hsync edge within a dot of a uniform grid; CEA-861
# 576p / 576i) and idle_bars_tb (scores the emitted
# pixels; built twice: STEP 4 as the core runs it, STEP 64 so a wrap happens in 14
# frames) must print their PASS marker. A runner looks for the marker POSITIVELY: a bench
# that dies early prints nothing, and a `$finish` on failure exits 0 (MiSTer_DVD lesson).
#
# --red: each mutation is applied to a COPY of the shipping source and must make the
# named arm FAIL. A mutation nobody catches means the bench cannot see that defect.
#   S1  hsync width 62 -> 61               -> sync_gen_tb hsync width
#   S2  vertical back porch 30 -> 29       -> sync_gen_tb dots per frame
#   480i (P6, sync_gen_il_tb):
#   S3  interlaced hsync one dot late      -> sync_gen_il_tb hsync first dot
#   S4  the half-line two dots early       -> sync_gen_il_tb vsync edge spacing (not 262.5 lines)
#   S5  equal field totals (262 + 262)     -> sync_gen_il_tb the two field totals
#   S6  FIELD1_VPOS read inverted          -> sync_gen_il_tb the short field is the v_pos-odd one
#   S7  ce_pix on the odd dots             -> sync_gen_il_tb ce_pix
#   S8  the restart into the bottom field  -> sync_gen_il_tb restart
#   S9  the restart ticks twice (a spurious refresh at a mode switch) -> sync_gen_il_tb the first field is whole
#   the standards (P6 steps 5 / 6):
#   S10 60.00: no short lines (the 59.94 raster)       -> sync_gen_tb +std=1 dots per frame
#   S11 60.00: the line count restarted every field     -> sync_gen_il_tb +std=1 dots a frame (76 long lines)
#   S12 50: hsync one dot late                          -> sync_gen_tb +std=2 hsync first dot
#   S13 50: the short field 311 lines                   -> sync_gen_il_tb +std=2 the two field totals
#   S14 50: the half-line at the 525-line raster's 858  -> sync_gen_il_tb +std=2 vsync edge spacing
#   B1  first bar boundary 103 -> 104      -> [bars]
#   B2  yellow and cyan swapped            -> [bars]
#   B3  the marker never advances          -> [mot]  (the frozen-picture case)
#   B4  the marker never wraps             -> [mot]  (STEP 64 run)
#   B5  de_out one clock early             -> [cov]
#   B6  vis ignored                        -> [vis]
#   B7  marker 33 rows tall                -> [band]
#   W1  idle_bars.vis enabled              -> check_emu_wiring (Jellyfin shipping must stay black)
#   W2  hsync one clock short of disp_reader's LAT 4 -> check_emu_wiring (sync and colour part company)
#   W3  sys_pll outclk_3 -> clk_vid        -> check_emu_wiring (fmax_check gates a dead domain)
#   W4  DDRAM2_WE port dropped             -> check_emu_wiring (port list != sys_top instance)
#   P2 (the decoder and the display path; UMD's W-arms where the seam came over):
#   W5  hps_io's ioctl_wait tied 1         -> check_emu_wiring (D3: nothing downloads; tie it low)
#   W6  h264_top.se_ready tied 1           -> check_emu_wiring (SEs dropped on a recon stall)
#   W7  ddr_mux2 reset per stream          -> check_emu_wiring (a burst cut by a new stream)
#   W8  ddr_mux2.a_abort tied 0            -> check_emu_wiring (the same, by the abort)
#   W9  the reconstruction on clk_sys      -> check_emu_wiring (recon_top is on clk_dec)
#   W10 the holds not from the output queue -> check_emu_wiring (recon_out drives disp_hold)
#   W11 the display reads through ram1     -> check_emu_wiring (disp_reader on DDRAM2)
#   W12 the display's field flag tied 0    -> check_emu_wiring (field chroma on the frame grid)
#   W13 VGA_DE from the picture's DE       -> check_emu_wiring (the raster's own delay)
#   W14 aspect_vui fed a constant idc      -> check_emu_wiring (Auto ignores the VUI)
#   W15 Auto ignores the VUI               -> check_emu_wiring
#   W16 the display's release tied off     -> check_emu_wiring (every store held: a stall)
#   W17 no emission reaches the queue      -> check_emu_wiring (recon_out takes emit_valid)
#   W18 the display's control on clk_dec   -> check_emu_wiring (the raster's clock)
#   W19 the reader's parity tied 0         -> check_emu_wiring (disp_ctl's decision)
#   W20 the reader's fetch side reset per stream -> check_emu_wiring (a held read withdrawn)
#   W21 the abort register reset per stream -> check_emu_wiring (the abort cleared mid-reset)
#   W22 the deinterlace mode tied to Weave -> check_emu_wiring (the menu's O[4:3])
#   W23 the single-field flag tied 0       -> check_emu_wiring (a lone field woven)
#   W24 h264_top's PTS input tied off      -> check_emu_wiring (Phase 3's PTS would tag nothing)
#   W25 a new stream resets nothing        -> check_emu_wiring (fe_rst_n = reset_n)
#   W26 END_OF_STREAM never flushes        -> check_emu_wiring (the last NAL unit held back)
#   W27 stream_live tied 0                 -> check_emu_wiring (the idle bars over a picture)
#   W28 the idle colour one register short -> check_emu_wiring (idle and picture part company)
#   W29 the reader's parser reset per stream -> check_emu_wiring (the next stream's records lost)
#   W30 the reader's engine reset per stream -> check_emu_wiring (a held ram1 command withdrawn)
#   W31 master B tied off                  -> check_emu_wiring (the ring never read)
#   W32 played latch cleared by stream     -> check_emu_wiring (Auto aspect/status retain stream history)
#   W33 a status snapshot reset per stream -> check_emu_wiring (a frame stalls mid-build)
#   W34 a status counter tied to 0         -> check_emu_wiring (reported 0 forever)
#   W35 the display's END tied high        -> check_emu_wiring (the last picture cut)
#   W36 the reader's region overridden     -> check_emu_wiring (the interface's address moved)
#   W37 low latency not reaching the display -> check_emu_wiring (LOW_LATENCY ignored)
#   (P6 -- numbered after the ring's W30..W37; they shared W30..W35 until 2026-09-28, and
#   the result files are keyed by name, so one set's verdicts overwrote the other's)
#   P6 (the 480i raster and Video Output, docs/analog.md):
#   W38 the raster's mode tied progressive -> check_emu_wiring (sync_gen.interlaced)
#   W39 Auto from the live ini wire        -> check_emu_wiring (video_out_eff: switches mid-stream)
#   W40 the idle screen given raw dots     -> check_emu_wiring (idle_bars.h_pos: squeezed at 480i)
#   W41 CE_PIXEL a clock early             -> check_emu_wiring (vga_ce_q: parts company with the dots)
#   W42 the composite sync from the raw hsync -> check_emu_wiring (csync_smpte.h_sync: CS_PIPE assumes VGA_HS's clock)
#   W43 the composite sync always on       -> check_emu_wiring (csync_smpte.en: a 9-line block at 31 kHz)
#   W44 the scheduler tied progressive     -> check_emu_wiring (disp_ctl.il: frames paced at 480i)
#   W45 the reader tied progressive        -> check_emu_wiring (disp_reader.il: the left half of each line)
#   W46 the fit's mode not latched         -> check_emu_wiring (disp_fit.mode: a menu change splits a picture)
#   W47 the exact aspect with bit 12 free  -> check_emu_wiring (VIDEO_ARX: sys_top reads bit 12 as a pixel size)
#   W48 the exact aspect over a fitted raster -> check_emu_wiring (ar_exact: a letterboxed raster stretched by HDMI)
#   W49 the reader's vertical pre-filter tied off -> check_emu_wiring (disp_reader.fit_vpf: anti-twitter's rows, flat positions)
#   W50 anti-twitter on field stores too   -> check_emu_wiring (fit_at: a field-coded pair filtered = Blend)
#   W51 the scheduler's grid tied to 59.94  -> check_emu_wiring (raster_std: 60.00 pictures paced on the 59.94 grid)
#   W52 the reader tied to 480 lines        -> check_emu_wiring (raster_pal: a 576-line raster shows 480)
#   W53 Auto latched under a live stream    -> check_emu_wiring (std_auto_l: the raster switched mid-stream)
#   W54 Anti-Twitter Auto ignores GRAPHICS  -> check_emu_wiring (at_sel: interface 0.4's content hint dropped)
#   W55 the settings request bypasses osd_req -> check_emu_wiring (osd_req: an unchecked word into Main)
#   W93-W95 (interface 0.13) a pad's rumble tied off, two pads' swapped, ring_rd's rumble left open
#           -> check_emu_wiring (hps_io.joystick_N_rumble, ring_rd.rumble)
#   W96-W98 (docs/analog.md §11) Auto's VGA verdict live, Native only when chosen by name, word 80's
#           video_out the menu's value -> check_emu_wiring (video_out_eff, nat_req_l, f_video_out)
#   W99, W101 (§11b) the Area pre-filter off (the Sharp control), the reader's horizontal pre-filter
#           tied off -> check_emu_wiring (disp_fit.area, disp_reader.fit_hpf)
#   W100, W102-W107 (interface 0.15) recon_out fed from recon_top past the mux, pic_in's holds tied
#           off (W106), its count reset per stream, word 84's snapshot in the wrong order, ring_rd's
#           ack tied off, pic_in's emission input tied off, word 85 tied off (W107) -> check_emu_wiring
#           (recon_out.pinfo_we, pic_in.oq_hold, pic_in.rst_n, pic_xing, ring_rd.pd_ack,
#           pic_in.r_emit_valid, ring_words_sys.f_disp_fhold)
#   W109, W110 (interface 0.17, F5) word 30's fit_valid tied 1; fit_clamp reported with no picture shown
#   W111 (issue #11) HDMI's Auto aspect 4:3 under Analog Aspect Fit (the anamorphic 16:9 fit) -> check_emu_wiring (ar_wide)
#   W112, W113 (issue #11) Fit on an SD HDMI mode not filled (16:9 there: a letterboxed window); 720x576 left out -> check_emu_wiring (fit_fill)
#   W114 (2026-10-19) progressive 4:3 back on Fill (480p at 4:3 too narrow on HDMI) -> check_emu_wiring (fit_mode_want)
#   W115, W116 (2026-10-19) emu's HDMI_HEIGHT / HDMI_WIDTH back on the VSET / HSET-clipped size (Native's
#           raster fed back through integer scaling) -> check_emu_wiring (sys_top.HDMI_HEIGHT / _WIDTH)
#   W117 (2026-10-19) a display-shaped Native raster given Display Shape's aspect (squeezed at 4:3)
#           -> check_emu_wiring (native_raster)
#       -> check_emu_wiring (st_fit_valid / st_fit_clamp)
#   W80-W90 (hd_raster, docs/hd_raster.md S3) CLK_VIDEO back on clk_sys, the dot two clocks in three, a
#           raster module on clk_sys, two bundle fields swapped, the bundle truncated, frame0 without its
#           mode tag, CE_PIXEL held for the whole dot, an output register off the dot, ring_stat on the
#           raw frame_tick, the status bundle's fields swapped, the reader's raster side not reset per
#           stream -> check_emu_wiring (each by its own name)
#   W75-W79 (stage 2) sync_gen without the native raster, the reader's frame tied to 480, the
#           latches back on line 500, raster_geom not holding between streams, word 80's mode
#           tied fitted -> check_emu_wiring (each by its own name)
#   L1  stream_live declared, not driven   -> lint_undriven
# the native raster (docs/hdmi_raster.md stage 2, sync_gen_nat_tb at 59.94 / 60.00 / 50 Hz):
#   N1  the geometry taken every line, not at the frame's first dot -> [dots] / [area]
#   N2  the odd line as long as the others (the remainder lost)    -> [dots]
#   N3  native HS across the end of the active area (into DE)    -> [hs]
#   N4  native VS from g_h + 1                                     -> [vs]
#   N5  native DE the fitted 720 wide                              -> [area]
#   N6  `lines` reports the fitted 480 in native                   -> [report]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1

IB64="-P idle_bars_tb.STEP=64 -P idle_bars_tb.N_FRAMES=14 -P idle_bars_tb.NEED_WRAP=1"

run_bench() {   # name  marker  iverilog-args...
  local name=$1 marker=$2; shift 2
  rm -f ".sim/${name}_sim"   # iverilog leaves the old binary on a failed build: never run it
  iverilog -g2012 -o ".sim/${name}_sim" "$@" || { echo "  FAIL $name: build"; fail=1; return; }
  # shellcheck disable=SC2086
  if vvp ".sim/${name}_sim" ${VVPARGS:-} 2>&1 | grep -v '^VCD\|sorry' | tee ".sim/${name}.log" | grep -q "^PASS: $marker"; then
    echo "  PASS $name"
  else
    echo "  FAIL $name"; grep "FAIL" ".sim/${name}.log" | head -12; fail=1
  fi
}

echo "== GREEN =="
run_bench sync_gen sync_gen_tb h264/sync_gen.sv bench/h264/sync_gen_tb.sv &
run_bench sync_gen_il sync_gen_il_tb h264/sync_gen.sv bench/h264/sync_gen_il_tb.sv &
VVPARGS=+std=1 run_bench sync_gen60 sync_gen_tb h264/sync_gen.sv bench/h264/sync_gen_tb.sv &
VVPARGS=+std=1 run_bench sync_gen_il60 sync_gen_il_tb h264/sync_gen.sv bench/h264/sync_gen_il_tb.sv &
VVPARGS=+std=2 run_bench sync_gen50 sync_gen_tb h264/sync_gen.sv bench/h264/sync_gen_tb.sv &
VVPARGS=+std=2 run_bench sync_gen_il50 sync_gen_il_tb h264/sync_gen.sv bench/h264/sync_gen_il_tb.sv &
run_bench idle_bars idle_bars_tb h264/sync_gen.sv h264/idle_bars.sv bench/h264/idle_bars_tb.sv &
for s in 0 1 2; do python3 tools/raster_geom_ref.py --sync-geo $s .sim/sync_nat_geo$s.txt > /dev/null; done
VVPARGS="+std=0 +geo=.sim/sync_nat_geo0.txt" run_bench sync_gen_nat sync_gen_nat_tb h264/sync_gen.sv bench/h264/sync_gen_nat_tb.sv &
VVPARGS="+std=1 +geo=.sim/sync_nat_geo1.txt" run_bench sync_gen_nat60 sync_gen_nat_tb h264/sync_gen.sv bench/h264/sync_gen_nat_tb.sv &
VVPARGS="+std=2 +geo=.sim/sync_nat_geo2.txt" run_bench sync_gen_nat50 sync_gen_nat_tb h264/sync_gen.sv bench/h264/sync_gen_nat_tb.sv &
# shellcheck disable=SC2086
run_bench idle_bars64 idle_bars_tb $IB64 h264/sync_gen.sv h264/idle_bars.sv bench/h264/idle_bars_tb.sv &
wait
# run_bench in the background cannot set $fail in this shell: re-read the logs
for n in sync_gen:sync_gen_tb sync_gen_il:sync_gen_il_tb sync_gen60:sync_gen_tb sync_gen_il60:sync_gen_il_tb \
         sync_gen50:sync_gen_tb sync_gen_il50:sync_gen_il_tb idle_bars:idle_bars_tb idle_bars64:idle_bars_tb \
         sync_gen_nat:sync_gen_nat_tb sync_gen_nat60:sync_gen_nat_tb sync_gen_nat50:sync_gen_nat_tb; do
  grep -q "^PASS: ${n#*:}" ".sim/${n%%:*}.log" 2>/dev/null || fail=1
done

echo "== WIRING =="
if python3 tools/check_emu_wiring.py; then :; else fail=1; fi

echo "== LINT =="
if command -v verilator >/dev/null 2>&1; then
  if tools/lint_undriven.sh; then :; else fail=1; fi
else
  echo "  FAIL verilator not installed: the lint is a gate, not optional"; fail=1
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name  file  old  new  bench-args(with FILE placeholder)  marker  pattern  [plusargs]
    local name=$1 file=$2 old=$3 new=$4 srcs=$5 marker=$6 pat=$7 args=${8:-}
    local d; d=$(mktemp -d)
    python3 - "$d" "$file" "$old" "$new" <<'PYEOF'
import sys, os
d, f, old, new = sys.argv[1:5]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')   # runner passes \n for newlines
s = open(f).read()
assert s.count(old) == 1, f"mutation anchor not unique/found in {f}: {old!r}"
open(os.path.join(d, os.path.basename(f)), 'w').write(s.replace(old, new))
PYEOF
    [ -f "$d/$(basename "$file")" ] || { { echo "  $name: anchor missed (harness failure)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; }
    local msrc=${srcs//FILE/$d/$(basename "$file")}
    # shellcheck disable=SC2086
    if ! iverilog -g2012 -o "$d/sim" $msrc 2>"$d/build.log"; then
      { echo "  $name: DID NOT COMPILE (harness failure)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    vvp "$d/sim" $args 2>&1 | grep -v '^VCD\|sorry' > "$d/log"
    if grep -q "^PASS: $marker" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "$pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 "$pat" "$d/log" | cut -c1-70)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep FAIL "$d/log" | head -3; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  S="FILE bench/h264/sync_gen_tb.sv"
  SI="FILE bench/h264/sync_gen_il_tb.sv"
  B="h264/sync_gen.sv FILE bench/h264/idle_bars_tb.sv"
  SN="FILE bench/h264/sync_gen_nat_tb.sv"
  G0="+std=0 +geo=.sim/sync_nat_geo0.txt"; G2="+std=2 +geo=.sim/sync_nat_geo2.txt"
  mut S1 h264/sync_gen.sv "localparam H_SE_N    = 798," "localparam H_SE_N    = 797," "$S" sync_gen_tb "FAIL hsync width" &
  mut S2 h264/sync_gen.sv "localparam V_TOT_N   = 525," "localparam V_TOT_N   = 524," "$S" sync_gen_tb "FAIL dots per frame" &
  mut S3 h264/sync_gen.sv "hs_now = il_q  ? ((h_cnt >= {hs_s[10:0], 1'b0})" "hs_now = il_q  ? ((h_cnt >= {hs_s[10:0], 1'b1})" "$SI" sync_gen_il_tb "FAIL hsync first dot" &
  mut S4 h264/sync_gen.sv "vs_ref  = field1 ? 12'd0 : (pal ? H_TOT_P : H_TOT_N);" "vs_ref  = field1 ? 12'd0 : (pal ? H_TOT_P : H_TOT_N - 2);" "$SI" sync_gen_il_tb "FAIL vsync edge spacing" &
  mut S5 h264/sync_gen.sv "(v_cnt == (field1 ? iv_short - 12'd1 : iv_short))" "(v_cnt == (iv_short - 12'd1))" "$SI" sync_gen_il_tb "FAIL the two field totals" &
  mut S6 h264/sync_gen.sv "wire        field1 = ((~odd_field) == \`FIELD1_VPOS);" "wire        field1 = ((~odd_field) != \`FIELD1_VPOS);" "$SI" sync_gen_il_tb "FAIL the short field is the v_pos-odd one" &
  mut S7 h264/sync_gen.sv "ce_pix     <= il_q ? ~h_cnt[0] : 1'b1;" "ce_pix     <= il_q ? h_cnt[0] : 1'b1;" "$SI" sync_gen_il_tb "FAIL ce_pix" &
  mut S9 h264/sync_gen.sv "(v_cnt == 12'd0) && !mode_chg;" "(v_cnt == 12'd0);" "$SI" sync_gen_il_tb "FAIL reset-interlaced first field whole" &
  mut S8 h264/sync_gen.sv "odd_field <= 1'b1;\n            m7 <= 3'd0;\n            nat_q <= nat_in;" "odd_field <= 1'b0;\n            m7 <= 3'd0;\n            nat_q <= nat_in;" "$SI" sync_gen_il_tb "FAIL restart: the first field is the top one" &
  wait
  mut S10 h264/sync_gen.sv "(s60 && m7 != 3'd0) ? (H_TOT_N - 1)" "(1'b0) ? (H_TOT_N - 1)" "$S" sync_gen_tb "FAIL dots per frame" +std=1 &
  mut S11 h264/sync_gen.sv "m7 <= (v_last && (!il_q || !odd_field)) ? 3'd0" "m7 <= (v_last) ? 3'd0" "$SI" sync_gen_il_tb "FAIL dots a frame" +std=1 &
  mut S12 h264/sync_gen.sv "localparam H_SS_N    = 736,  H_SS_P    = 732;" "localparam H_SS_N    = 736,  H_SS_P    = 733;" "$S" sync_gen_tb "FAIL hsync first dot" +std=2 &
  mut S13 h264/sync_gen.sv "localparam IV_SHORT_N = 262, IV_SHORT_P = 312;" "localparam IV_SHORT_N = 262, IV_SHORT_P = 311;" "$SI" sync_gen_il_tb "FAIL the two field totals" +std=2 &
  mut N1 h264/sync_gen.sv "                if (v_last && !il_q) begin\n                    nat_q <= nat_in;" "                if (!il_q) begin\n                    nat_q <= nat_in;" "$SN" sync_gen_nat_tb "FAIL \[\(dots\|area\)\]" "$G0" &
  mut N2 h264/sync_gen.sv "wire [11:0] h_tot = nat_q ? ((v_cnt == gh_q) ? glast_q : gl_q) :" "wire [11:0] h_tot = nat_q ? gl_q :" "$SN" sync_gen_nat_tb "FAIL \[dots\]" "$G0" &
  mut N3 h264/sync_gen.sv "            : nat_q ? ((h_cnt >= h_tot - 12'd14) && (h_cnt < h_tot - 12'd6))" "            : nat_q ? ((h_cnt >= gw_q - 12'd4) && (h_cnt < gw_q + 12'd4))" "$SN" sync_gen_nat_tb "FAIL \[hs\]" "$G0" &
  mut N4 h264/sync_gen.sv "wire vs_now = nat_q ? ((v_cnt >= gh_q + 12'd2)" "wire vs_now = nat_q ? ((v_cnt >= gh_q + 12'd1)" "$SN" sync_gen_nat_tb "FAIL \[vs\]" "$G2" &
  mut N5 h264/sync_gen.sv "nat_q ? (h_cnt < gw_q) : (h_cnt < H_ACTIVE);" "nat_q ? (h_cnt < H_ACTIVE) : (h_cnt < H_ACTIVE);" "$SN" sync_gen_nat_tb "FAIL \[area\]" "$G0" &
  mut N6 h264/sync_gen.sv "lines      <= nat_q ? gh_q : pal ? 12'd576 : 12'd480;" "lines      <= pal ? 12'd576 : 12'd480;" "$SN" sync_gen_nat_tb "FAIL \[report\]" "$G0" &
  wait
  mut S14 h264/sync_gen.sv "vs_ref  = field1 ? 12'd0 : (pal ? H_TOT_P : H_TOT_N);" "vs_ref  = field1 ? 12'd0 : (pal ? H_TOT_N : H_TOT_N);" "$SI" sync_gen_il_tb "FAIL vsync edge spacing" +std=2 &
  wait
  mut B1 h264/idle_bars.sv "bar_q     <= (h_pos < 12'd103) ? 3'd0 :" "bar_q     <= (h_pos < 12'd104) ? 3'd0 :" "$B" idle_bars_tb "FAIL \[bars\]" &
  mut B2 h264/idle_bars.sv "3'd1:    rgb_on = 3'b110;\n        3'd2:    rgb_on = 3'b011;" "3'd1:    rgb_on = 3'b011;\n        3'd2:    rgb_on = 3'b110;" "$B" idle_bars_tb "FAIL \[bars\]" &
  mut B3 h264/idle_bars.sv "else if (ce && frame_tick) begin mx <= mx_n;" "else if (1'b0) begin mx <= mx_n;" "$B" idle_bars_tb "FAIL \[mot\]" &
  mut B4 h264/idle_bars.sv "(mx + MK_STEP > MK_LAST) ? 12'd0" "(1'b0) ? 12'd0" "$IB64 $B" idle_bars_tb "FAIL \[mot\]" &
  mut B5 h264/idle_bars.sv "de_out <= de_q;" "de_out <= de_in;" "$B" idle_bars_tb "FAIL \[cov\]" &
  mut B6 h264/idle_bars.sv "if (!vis || !de_q) begin" "if (!de_q) begin" "$B" idle_bars_tb "FAIL \[vis\]" &
  mut B7 h264/idle_bars.sv "localparam [11:0] MK_Y1    = 12'd432;" "localparam [11:0] MK_Y1    = 12'd433;" "$B" idle_bars_tb "FAIL \[band\]" &
  wait
  # W / L: the wiring checker and the lint on a mutated emu.sv (no bench: emu has none)
  wmut() {   # name  old  new  tool  [label: the check_emu_wiring failure that must name it]
    # WFILE=h264/vid_out.sv: mutate the output stage instead (hd_raster: factored out of emu.sv)
    local name=$1 old=$2 new=$3 tool=$4 want=${5:-} wf=${WFILE:-h264/emu.sv}
    local d; d=$(mktemp -d)
    cp h264/emu.sv h264/vid_out.sv sys/sys_top.v "$d/"
    if ! python3 - "$d" "$old" "$new" "$wf" <<'PYEOF'
import sys, os
d, old, new, wf = sys.argv[1:5]
old = old.replace('\\n', '\n').replace('\\t', '\t')   # runner passes \n / \t
new = new.replace('\\n', '\n').replace('\\t', '\t')
s = open(wf).read()
assert s.count(old) == 1, f"mutation anchor not unique/found in {wf}: {old!r}"
open(os.path.join(d, os.path.basename(wf)), 'w').write(s.replace(old, new))
PYEOF
    then { echo "  $name: anchor missed (harness failure)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    local ok=0
    if [ "$tool" = wiring ]; then
      VID_OUT_SV="$d/vid_out.sv" python3 tools/check_emu_wiring.py "$d/emu.sv" "$d/sys_top.v" > "$d/wlog" 2>&1 && ok=1
      if [ $ok = 0 ] && [ -n "$want" ] && ! grep -qF -- "- $want:" "$d/wlog"; then
        { echo "  $name: failed but NOT by its own check ($want):"; grep -m2 -- '^  - ' "$d/wlog"; echo MUTFAIL; } > "$RES/$name"
        rm -rf "$d"; return
      fi
    else
      # the lint reads the file list from the qsf: run it on a copy of the tree
      local t; t=$(mktemp -d)
      cp -r H264.qsf h264 sys tools "$t/" && cp "$d/emu.sv" "$t/h264/emu.sv"
      "$t/tools/lint_undriven.sh" >/dev/null 2>&1 && ok=1
      rm -rf "$t"
    fi
    if [ $ok = 1 ]; then { echo "  $name: SURVIVED -- $tool accepts it"; echo MUTFAIL; } > "$RES/$name"
    else echo "  $name: caught by $tool${want:+ ($want)}" > "$RES/$name"; fi
    rm -rf "$d"
  }
  wmut W1 ".vis        (1'b0)" ".vis        (1'b1)" wiring idle_bars.vis
  WFILE=h264/vid_out.sv wmut W2 "vga_hs <= hs_dly[10];" "vga_hs <= hs_dly[9];" wiring vga_hs
  wmut W3 ".outclk_2 (clk_spare),\n\t.outclk_3 (clk_dec)," ".outclk_2 (clk_dec),\n\t.outclk_3 (clk_spare)," wiring sys_pll
  wmut W4 "	output        DDRAM2_WE,
" "" wiring ports
  wmut W5 ".ioctl_wait     (1'b0)," ".ioctl_wait     (1'b1)," wiring hps_io.ioctl_wait
  wmut W6 ".se_ready      (se_ready)," ".se_ready      (1'b1)," wiring h264_top.se_ready
  wmut W7 "\t.rst_n             (mem_lock_n),\n\t.a_address         (dpb_address)," "\t.rst_n             (fe_rst_mem_n),\n\t.a_address         (dpb_address)," wiring ddr_mux2.rst_n
  wmut W8 ".a_abort           (dpb_abort_q[1])," ".a_abort           (1'b0)," wiring ddr_mux2.a_abort
  wmut W9 "recon_top_inst (\n\t.clk              (clk_dec)," "recon_top_inst (\n\t.clk              (clk_sys)," wiring recon_top
  wmut W10 ".oq_hold        (disp_hold)," ".oq_hold        ()," wiring recon_out.oq_hold
  wmut W11 ".ddr_read          (dr_read)," ".ddr_read          (DDRAM_RD)," wiring disp_reader.ddr_read
  wmut W12 ".pic_field         (v_sh_field)," ".pic_field         (1'b0)," wiring disp_reader.pic_field
  WFILE=h264/vid_out.sv wmut W13 "vga_de <= de_dly[10];" "vga_de <= pic_de;" wiring vga_de_q
  wmut W14 ".aspect_idc (sh_ar_idc)," ".aspect_idc (8'd5)," wiring aspect_vui.aspect_idc
  wmut W15 "wire auto_wide  = stream_live ? live_wide : (played ? last_wide_q : idle_wide);" "wire auto_wide  = stream_live | idle_wide;" wiring auto_wide
  wmut W16 "\t.rel_valid      (rl_valid),\n\t.rel_store      (rl_store)\n);" "\t.rel_valid      (1'b0),\n\t.rel_store      (rl_store)\n);" wiring recon_out.rel_valid
  wmut W17 ".emit_valid     (po_valid)," ".emit_valid     (1'b0)," wiring recon_out.emit_valid
  wmut W18 "disp_ctl disp_ctl_inst (\n\t.clk            (clk_sys)," "disp_ctl disp_ctl_inst (\n\t.clk            (clk_dec)," wiring disp_ctl
  wmut W19 ".pic_parity        (v_sh_parity)," ".pic_parity        (1'b0)," wiring disp_reader.pic_parity
  wmut W20 "\t.mrst_n            (mem_lock_n),\n\t.ddr_address       (dr_address)," "\t.mrst_n            (fe_rst_mem_n),\n\t.ddr_address       (dr_address)," wiring disp_reader.mrst_n
  wmut W21 "always @(posedge clk_mem or negedge mem_lock_n) begin\n\tif (!mem_lock_n) dpb_abort_q <= 2'b11;" "always @(posedge clk_mem or negedge fe_rst_mem_n) begin\n\tif (!fe_rst_mem_n) dpb_abort_q <= 2'b11;" wiring ddr_mux2.a_abort
  wmut W22 ".deint_mode        (v_deint)," ".deint_mode        (2'd0)," wiring disp_reader.deint_mode
  wmut W23 ".pic_single        (v_sh_single)," ".pic_single        (1'b0)," wiring disp_reader.pic_single
  wmut W24 ".es_pts        (es_data[41:9])," ".es_pts        (33'd0)," wiring h264_top.es_pts
  wmut W25 "wire fe_rst_n = reset_n & ~stream_clr;" "wire fe_rst_n = reset_n;" wiring fe_rst_n
  wmut W26 ".wr_flush   (rr_eos)," ".wr_flush   (1'b0)," wiring vidfeed_cdc.wr_flush
  wmut W27 "wire stream_live = sh_valid;" "wire stream_live = 1'b0;" wiring stream_live
  WFILE=h264/vid_out.sv wmut W28 "de_dly[8] ? idle_rg_q7[15:8]" "de_dly[8] ? idle_rg_q6[15:8]" wiring sel_r_q
  wmut W29 "\t.rst_n          (reset_n),\n\t.lrst_n" "\t.rst_n          (fe_rst_n),\n\t.lrst_n" wiring ring_rd.rst_n
  wmut W30 "\t.mrst_n         (mem_lock_n),\n\t.b_address" "\t.mrst_n         (fe_rst_mem_n),\n\t.b_address" wiring ring_rd.mrst_n
  wmut W31 ".b_read            (rb_read)," ".b_read            (1'b0)," wiring ddr_mux2.b_read
  wmut W32 "else if (stream_live) played <= 1'b1;" "else if (stream_live) played <= 1'b0;" wiring played
  wmut W33 ".drst_n   (lock_dec_n)," ".drst_n   (fe_rst_dec_n)," wiring ring_stat.drst_n
  wmut W34 ".f_rc_err         (rc_err)," ".f_rc_err         (32'd0)," wiring ring_words_dec.f_rc_err
  wmut W35 ".disp_ended     (disp_ended)," ".disp_ended     (1'b1)," wiring ring_rd.disp_ended
  wmut W36 "ring_rd ring_rd_inst (" "ring_rd #(.RING_AW(19)) ring_rd_inst (" wiring ring_rd
  wmut W37 ".low_lat        (rr_ll)," ".low_lat        (1'b0)," wiring disp_ctl.low_lat
  wmut W38 "\t.interlaced (v_il)," "\t.interlaced (1'b0)," wiring sync_gen.interlaced
  wmut W39 "                        analog_want_l            ? 2'd1 :" "                        analog_want_raw          ? 2'd1 :" wiring video_out_eff
  wmut W40 "\t.h_pos      (idle_x)," "\t.h_pos      (h_pos)," wiring idle_bars.h_pos
  WFILE=h264/vid_out.sv wmut W41 "vga_ce <= ce & ce_dly[10];" "vga_ce <= ce & ce_dly[9];" wiring vga_ce
  WFILE=h264/vid_out.sv wmut W42 "\t.h_sync (hs_dly[10])," "\t.h_sync (h_sync)," wiring csync_smpte.h_sync
  WFILE=h264/vid_out.sv wmut W43 "\t.en     (il)," "\t.en     (1'b1)," wiring csync_smpte.en
  wmut W44 ".il             (interlaced_eff)," ".il             (1'b0)," wiring disp_ctl.il
  wmut W45 ".il                (v_il),               // P6: pixels" ".il                (1'b0),               // P6: pixels" wiring disp_reader.il
  wmut W46 "	.mode     (fit_mode_l)," "	.mode     (fit_mode_want)," wiring disp_fit.mode
  wmut W47 "assign VIDEO_ARX = ar_exact ? {1'b0, ar_x}" "assign VIDEO_ARX = ar_exact ? {ar_x[11], ar_x}" wiring VIDEO_ARX
  wmut W48 "&& !raster_fitted && (stream_live || played);" "&& !interlaced_eff && (stream_live || played);" wiring ar_exact
  wmut W49 ".fit_vpf           (v_fit_vpf)," ".fit_vpf           (3'd0)," wiring disp_reader.fit_vpf
  wmut W50 "wire        fit_at = at_opt_l & interlaced_eff & ~sh_field;" "wire        fit_at = at_opt_l & interlaced_eff;" wiring fit_at
  wmut W51 ".std            (raster_std)," ".std            (2'd0)," wiring raster_std
  wmut W52 ".pal               (v_pal),              // P6 step 6" ".pal               (1'b0),              // P6 step 6" wiring raster_pal
  wmut W53 "else if (rate_v && !stream_live)   std_auto_l" "else if (rate_v)   std_auto_l" wiring std_auto_l
  wmut W54 "wire        at_sel = (at_opt == 2'd0) ? rr_gfx : (at_opt == 2'd2);" "wire        at_sel = (at_opt == 2'd2);" wiring at_sel
  wmut W55 "	.status_in      (req_status_in)," "	.status_in      ({96'd0, rr_set_word})," wiring osd_req
  # Phase 4 (interface 0.5): the pause's freeze into recon_dpb (UMD P6b3i's disp_frz)
  wmut W56 "	.disp_frz         (frz_dec_s[1])," "	.disp_frz         (1'b0)," wiring recon_top.disp_frz
  # interface 0.6: the input region -- Main's keys tied off, the reset an OSD Reset reaches, the pads
  # left unconnected at hps_io
  wmut W57 "	.ps2_key       (ps2_key)," "	.ps2_key       (11'd0)," wiring ring_in.ps2_key
  wmut W58 "	.rst_n         (lock_sys_n),
	.frame         (frame_sys)," "	.rst_n         (reset_n),
	.frame         (frame_sys)," wiring ring_in.rst_n
  wmut W59 "	.joystick_0     (joystick_0)," "	.joystick_0     ()," wiring hps_io.joystick_0
  # Phase 6b (interface 0.9): the overlay plane -- its session gate, its lock-only resets, its place
  # on ram2, the composite after the selection, the anti-twitter choice, the raster
  wmut W60 "	.sess              (v_sess)," "	.sess              (1'b1)," wiring ovl_plane.sess
  wmut W61 "	.rst_n             (vid_lock_n),
	.h_pos             (h_pos)," "	.rst_n             (vid_rst_n),
	.h_pos             (h_pos)," wiring ovl_plane.rst_n
  wmut W62 "\t.mrst_n            (mem_lock_n),\n\t.ddr_address       (ov_address)," "\t.mrst_n            (fe_rst_mem_n),\n\t.ddr_address       (ov_address)," wiring ovl_plane.mrst_n
  wmut W63 ".b_read            (ov_read)," ".b_read            (1'b0)," wiring ovl_plane.ddr_read
  WFILE=h264/vid_out.sv wmut W64 "	.p_r (ovl_r_q)," "	.p_r (ovl_pr)," wiring ovl_blend
  WFILE=h264/vid_out.sv wmut W65 "		vga_r  <= ob_r;" "		vga_r  <= sel_r_q;" wiring vga_r_q
  wmut W66 "	.at_en             (v_at_en)," "	.at_en             (1'b0)," wiring ovl_plane.at_en
  wmut W67 "ddr_mux2 ram2_mux (\n\t.clk               (clk_mem),\n\t.rst_n             (mem_lock_n)," "ddr_mux2 ram2_mux (\n\t.clk               (clk_mem),\n\t.rst_n             (fe_rst_mem_n)," wiring "ram2 ddr_mux2"
  wmut W68 "\t.il                (v_il),\n\t.pal               (v_pal),\n\t.rast_w" "\t.il                (1'b0),\n\t.pal               (v_pal),\n\t.rast_w" wiring ovl_plane.il
  # A' and word 80 (docs/hdmi_raster.md, interface 0.10); F8: word 47 pinned to what HDMI is given
  wmut W69 "	.disp_w   (fit_dw_l)," "	.disp_w   (HDMI_WIDTH)," wiring disp_fit.disp_w
  wmut W70 "		fit_dh_l   <= HDMI_HEIGHT;" "		fit_dh_l   <= HDMI_WIDTH;" wiring fit_dh_l
  wmut W71 "	else if (fit_lb || (geom_nat && geom_disp)) begin ar_x <= fit_dw_l; ar_y <= fit_dh_l; end" "	else if (fit_lb) begin ar_x <= fit_dw_l; ar_y <= fit_dh_l; end" wiring ar_x
  # stage 2 (docs/hdmi_raster.md): the native raster's wiring
  wmut W75 "	.nat        (v_nat)," "	.nat        (1'b0)," wiring sync_gen.nat
  wmut W76 "	.lines             (rast_lines),         // stage 2" "	.lines             (12'd480),         // stage 2" wiring disp_reader.lines
  wmut W77 "	if (disp_pick_ph) begin" "	if (h_pos == 12'd0 && v_pos == 12'd500) begin" wiring nat_req_l
  wmut W78 "	.en     (sh_valid | ~nat_req_l)," "	.en     (1'b1)," wiring raster_geom.en
  wmut W79 "	.f_raster_mode    (geom_mode)," "	.f_raster_mode    (2'd0)," wiring ring_words_sys.f_raster_mode
  wmut W72 "	.f_ar_x           (VIDEO_ARX[11:0])," "	.f_ar_x           (12'd0)," wiring ring_words_sys.f_ar_x
  wmut W73 "wire [12:0] st_pic_y0       = sh_valid ? fit_oy0[12:0] : 13'd0;" "wire [12:0] st_pic_y0       = sh_valid ? fit_ox0[12:0] : 13'd0;" wiring st_pic_y0   # (0.17: through st_pic_y0)
  wmut W74 "	if      (!stream_live) begin ar_x <= ar_x; ar_y <= ar_y; end" "	if      (1'b0) begin ar_x <= ar_x; ar_y <= ar_y; end" wiring ar_hold
  # hd_raster (docs/hd_raster.md S3): the raster side on clk_vid and the dot, its crossings
  wmut W80 "assign CLK_VIDEO = clk_vid;" "assign CLK_VIDEO = clk_sys;" wiring CLK_VIDEO
  wmut W81 "wire        tick27 = (ce_ph == 2'd2);" "wire        tick27 = (ce_ph != 2'd2);" wiring ce_dot
  wmut W91 "\t.dot        (ce_dot)," "\t.dot        ()," wiring ce_dot
  wmut W92 "\t.rast_h            (v_rh)," "\t.rast_h            (rast_lines)," wiring ovl_plane.rast_h
  wmut W82 "\t.clk               (clk_vid),            // (hd_raster)" "\t.clk               (clk_sys),            // (hd_raster)" wiring "raster clock"
  # (two fields of one width swapped are each caught by their own consumer's arm: sync_gen.g_w, ...)
  wmut W83 "                            sh_valid, sh_store, sh_field," "                            sh_store, sh_valid, sh_field," wiring "bundle XW_DN"
  wmut W84 "localparam int XW_DN = 1 + 1 + 2 + 1 + 5*12" "localparam int XW_DN = 1 + 1 + 2 + 1 + 4*12" wiring "bundle XW_DN"
  wmut W85 "wire       frame0_sys = f0_sys && (f0_tag_s2 == {interlaced_eff, raster_std});" "wire       frame0_sys = f0_sys;" wiring frame0_sys
  WFILE=h264/vid_out.sv wmut W86 "vga_ce <= ce & ce_dly[10];" "vga_ce <= ce_dly[10];" wiring vga_ce
  WFILE=h264/vid_out.sv wmut W87 "always @(posedge clk) if (ce) begin\n\tidle_rg_q1" "always @(posedge clk) begin\n\tidle_rg_q1" wiring vid_out.ce
  wmut W88 "\t.frame    (frame_sys)," "\t.frame    (frame_tick)," wiring ring_stat
  wmut W89 "                            ovl_late_v, ovl_lines_v};" "                            ovl_lines_v, ovl_late_v};" wiring "bundle XW_UP"
  wmut W90 "\t.rst_n             (vid_fe_rst_n)," "\t.rst_n             (vid_rst_n)," wiring disp_reader.rst_n
  # interface 0.13: the rumble into hps_io (pad n to joystick_n_rumble exactly)
  wmut W93 ".joystick_0_rumble (rumble[15:0])," ".joystick_0_rumble (16'd0)," wiring hps_io.joystick_0_rumble
  wmut W94 ".joystick_4_rumble (rumble[79:64]), .joystick_5_rumble (rumble[95:80])," ".joystick_4_rumble (rumble[95:80]), .joystick_5_rumble (rumble[79:64])," wiring hps_io.joystick_4_rumble
  wmut W95 "\t.rumble         (rumble)," "\t.rumble         ()," wiring ring_rd.rumble
  # (2026-10-04, docs/analog.md §11) Auto's Native: the VGA verdict latched, Native's latch, the report
  wmut W96 "                        vga31_want_l             ? 2'd2 : 2'd3;" "                        vga31_want_raw           ? 2'd2 : 2'd3;" wiring video_out_eff
  wmut W97 "		nat_req_l  <= (video_out_eff == 2'd3);" "		nat_req_l  <= (status[6:5] == 2'd3);" wiring nat_req_l
  wmut W98 "	.f_video_out      (video_out_eff)," "	.f_video_out      (video_out_mode)," wiring ring_words_sys.f_video_out
  # (docs/analog.md §11b) the Area pre-filter: tied to the Sharp control, the reader's horizontal code tied off
  wmut W99 "	.area     (1'b1)," "	.area     (1'b0)," wiring disp_fit.area
  # interface 0.15: pic_in between recon_top and recon_out; word 84 as one snapshot
  wmut W100 "\t.pinfo_we       (po_we)," "\t.pinfo_we       (pi_we)," wiring recon_out.pinfo_we
  wmut W106 "\t.oq_hold          (disp_hold)," "\t.oq_hold          (20'd0)," wiring pic_in.oq_hold
  wmut W102 "\t.cnt_rst_n        (lock_dec_n)," "\t.cnt_rst_n        (fe_rst_dec_n)," wiring pic_in.rst_n
  wmut W103 "\t.src_data  ({disp_hold, pic_emitted})," "\t.src_data  ({pic_emitted, disp_hold})," wiring pic_xing
  wmut W104 "\t.pd_ack         (pd_ack)," "\t.pd_ack         (1'b0)," wiring ring_rd.pd_ack
  wmut W105 "\t.r_emit_valid     (em_valid)," "\t.r_emit_valid     (1'b0)," wiring pic_in.r_emit_valid
  wmut W107 "\t.f_disp_fhold     (disp_fhold)," "\t.f_disp_fhold     (32'd0)," wiring ring_words_sys.f_disp_fhold
  # (0.17, F5) the fit's status before any picture: fit_valid tied 1, a fit flag ungated
  wmut W109 "wire        st_fit_valid    = sh_valid;" "wire        st_fit_valid    = 1'b1;" wiring st_fit_valid
  wmut W110 "wire        st_fit_clamp    = sh_valid & fit_clamp;" "wire        st_fit_clamp    = fit_clamp;" wiring st_fit_clamp
  wmut W111 "(fit_169 || (auto_wide && !raster_fitted))" "(auto_wide && !raster_fitted)" wiring ar_wide
  wmut W112 "wire fit_fill   = fit_169 && hdmi_sd16 && (status[2:1] == 2'd0);" "wire fit_fill   = 1'b0;" wiring fit_fill
  wmut W113 "(HDMI_HEIGHT == 12'd480 || HDMI_HEIGHT == 12'd576)" "(HDMI_HEIGHT == 12'd480)" wiring fit_fill
  wmut W114 "fit_mode_want = status[2] ? 2'd2 : 2'd0;" "fit_mode_want = interlaced_eff ? (status[2] ? 2'd2 : 2'd0) : status[2] ? 2'd2 : 2'd3;" wiring fit_mode_want
  WFILE=sys/sys_top.v wmut W115 "	.HDMI_HEIGHT(direct_video ? 12'd0 : hdmi_mode_h)," "	.HDMI_HEIGHT(direct_video ? 12'd0 : hdmi_height)," wiring sys_top.HDMI_HEIGHT
  WFILE=sys/sys_top.v wmut W116 "	hdmi_mode_w <= WIDTH << HDMI_PR;" "	hdmi_mode_w <= (HSET && (HSET < WIDTH))  ? HSET << HDMI_PR : WIDTH << HDMI_PR;" wiring sys_top.HDMI_WIDTH
  wmut W117 "wire native_raster = geom_nat;" "wire native_raster = geom_nat && !geom_disp;" wiring native_raster
  wmut W101 "	.fit_hpf           (v_fit_hpf)," "	.fit_hpf           (3'd0)," wiring disp_reader.fit_hpf
  wmut L1 "wire stream_live = sh_valid;" "wire stream_live;" lint
  for f in "$RES"/*; do grep -v '^MUTFAIL$' "$f"; grep -q '^MUTFAIL$' "$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
