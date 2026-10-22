#!/usr/bin/env bash
# run_disp_fit.sh -- h264/disp_fit.sv (the display fit's per-picture parameters, P6 step 3,
# docs/analog.md §5) against tools/disp_fit_ref.py, the design's arithmetic written from the
# text (bench/h264/disp_fit_tb.sv). The model's own rectangle is checked against ffmpeg's
# scale (force_original_aspect_ratio) first: an independent oracle for the geometry.
#
# GREEN: the model's selftest; the model vs ffmpeg (12 sizes x Letterbox / Crop / Fit); the RTL vs
#   the model on 8,000 vectors (400 cases x 4 modes x progressive / 480i / 480i with
#   anti-twitter / 576p / 576i with anti-twitter: every flag, the decimation, the
#   anti-twitter cap and the 576-line raster reached, the bench's coverage check); the
#   model's rectangle vs ffmpeg on the 480- and the 576-line raster.
# Arms: [flag] crop_bad / snap / clamp, [crop] the cropped size and origin, [size] the
#   rectangle, [step] sx / sy, [dec] the decimation, [slide] anti-twitter's sliding rows
#   published (P6 step 4), [pf] the Area pre-filter's codes (docs/analog.md §11b), [seq] the computation's start / end and the outputs still while
#   it runs, [lb] A' published (Fill: wider than the HDMI display, docs/hdmi_raster.md §3a).
# Mutations (--red), each caught by its own arm:
#   F1  round(n/d) read as floor (the + d dropped)                -> [size]
#   F2  the offset halved without its sign (a logical shift)      -> [size]
#   F3  sx divided by oh                                          -> [step]
#   F4  the fetch budget's cap (W > 80: dv <= 4) lost             -> [dec]
#   F5  the width cap (16 W > 1,024: dh >= 2) lost                -> [dec]
#   F23 (hd_raster) the width cap applied on the native raster too (a 2,048-sample line) -> [dec]
#   F6  the native snap never taken                               -> [flag]
#   F7  the crop's top offset in units of 2 for cuy4              -> [crop]
#   F8  a bad crop found only on the width                        -> [flag]
#   F9  busy never released                                       -> [seq]
#   F10 the clamp not flagged                                     -> [flag]
#   F11 anti-twitter's cap for W > 40 (dv <= 2) lost               -> [dec]
#   F12 the sliding rows never published                          -> [slide]
#   F13 anti-twitter's cap (dv <= 4) lost: dv 8 under it          -> [dec]
#   F14 576 lines: the wide picture's height by 640 (480's)        -> [size]
#   F15 576 lines: the rectangle centred on 480 lines              -> [size]
#   F16 A': the products not shifted down (the divisor's top bits lost) -> [size]
#   F17 A': "wider" taken at equal (>=): a picture of the display's shape letterboxed -> [lb]
#   F18 A': the vertical snap never taken                          -> [flag]
#   F19 A': the display's width in place of its height (the ratio)  -> [lb]
#   F20 A': lb never published                                      -> [lb]
#   F21 native: the picture centred on the 720 raster, not raster_geom's -> [size]
#   F22 native: the snap taken (a near-raster picture shown resampled)   -> [size]
#   (docs/analog.md §11b, the Area pre-filter; [pf] its codes)
#   F24 the 1,024-column floor kept under Area                      -> [dec]
#   F25 Area's A without its rounding half                         -> [pf]
#   F26 the vertical code from the undecimated step                -> [pf]
#   F27 the budget's fallback never taken                          -> [pf]
#   F28 anti-twitter's (4, 4, 0) not applied over Area's code      -> [pf]
#   F29 Area's A not clamped at 4 (a step past the caps)           -> [pf]
#   (equivalent, recorded: a pre-filter at r = 1.0 exactly -- A = floor(0.5) = 0 either way, only
#   Smooth could see it; the budget's row cap 2 dv <= 8 -- the cost alone excludes dv 8: 8 x 180 > 1,300)
#   F31 anti-twitter's two boxes dropped past the budget           -> [pf]
#   F32 the budget's cost threshold past a 480p line's two rows     -> [pf]
#   (issue #11, Fit: the anamorphic 16:9 fit)
#   F33 Fit's pillarbox by 540 (Letterbox's 4:3) for 405             -> [size]
#   F34 Fit's letterbox published as A' (lb)                          -> [lb]
#   F35 Fit's test against 4:3 for 16:9                               -> [size]
#   F36 Fit's snap never taken                                        -> [flag]
#   F37 Fit's quotient always the height (the pillarbox's width as oh) -> [size]
#   F38 Fit's "wider" not cleared between computations               -> [size]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL=h264/disp_fit.sv; TB=bench/h264/disp_fit_tb.sv; VEC=.sim/disp_fit_vec.txt
echo "== the model =="
python3 tools/disp_fit_ref.py --selftest | sed 's/^/  /' || { echo "FAIL: model selftest"; exit 1; }
if command -v ffprobe > /dev/null; then
  python3 tools/disp_fit_ref.py --check-ffmpeg > .sim/disp_fit_ffmpeg.log 2>&1 \
    && echo "  $(tail -n 1 .sim/disp_fit_ffmpeg.log)" || { echo "  FAIL: the model vs ffmpeg"; grep BAD .sim/disp_fit_ffmpeg.log; fail=1; }
else echo "  SKIP: the model vs ffmpeg (no ffprobe)"; fi
python3 tools/disp_fit_ref.py --vectors 400 $VEC | sed 's/^/  /'
echo "== GREEN =="
rm -f .sim/disp_fit_sim   # iverilog leaves the old binary on a failed build
if iverilog -g2012 -o .sim/disp_fit_sim $RTL $TB && vvp -n .sim/disp_fit_sim +vec=$VEC > .sim/disp_fit.log 2>&1 \
   && grep -q "^PASS: disp_fit_tb" .sim/disp_fit.log; then
  echo "  PASS $(grep '^disp_fit_tb:' .sim/disp_fit.log)"
else echo "  FAIL"; grep FAIL .sim/disp_fit.log | head -3; fail=1; fi

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
      elif grep -Eq "FAIL \[($4)\]" "$d/log"; then echo "  $1: caught by $(grep -Em1 "FAIL \[($4)\]" "$d/log" | cut -c1-110)"
      else echo "  $1: failed but NOT in [$4]:"; grep -m2 FAIL "$d/log"; fail=1; fi
    fi
    rm -rf "$d"
  }
  mut F1 "dv_n <= {1'b0, (k_pal ? b768 : b640), 1'b0} + {12'd0, r_a};" "dv_n <= {1'b0, (k_pal ? b768 : b640), 1'b0};" size
  mut F2 "ox0 <= {ox_d[13], ox_d[13:1]};" "ox0 <= {1'b0, ox_d[13:1]};" size
  mut F3 "dv_n <= {12'd0, r_wc, 16'd0}; dv_d <= {16'd0, r_ow};" "dv_n <= {12'd0, r_wc, 16'd0}; dv_d <= {16'd0, r_oh};" step
  mut F4 "else if (k_at || k_w > 8'd80)" "else if (k_at || k_w > 8'd127)" dec
  mut F5 "((r_sx[27:16] >= 12'd2) || (k_w > 8'd64 && !k_nat && !k_area))" "(r_sx[27:16] >= 12'd2)" dec
  mut F23 "(k_w > 8'd64 && !k_nat && !k_area)" "(k_w > 8'd64 && !k_area)" dec
  # (docs/analog.md §11b) the Downscale Filter
  mut F24 "(k_w > 8'd64 && !k_nat && !k_area)" "(k_w > 8'd64 && !k_nat)" dec
  mut F25 "wire [29:0] ah_t = {rh_q, 2'b00} - 30'd229376;" "wire [29:0] ah_t = {rh_q, 2'b00} - 30'd262144;" pf
  mut F26 "wire [29:0] av_t = {rv_q, 2'b00} - 30'd229376;" "wire [29:0] av_t = {r_sy, 2'b00} - 30'd229376;" pf
  mut F27 "vpf <= (r_vpf != 3'd0 && !fit2 && !k_at) ? 3'd0 : r_vpf;" "vpf <= r_vpf;" pf
  mut F28 "r_vpf <= k_at ? 3'd4 : vc_w;" "r_vpf <= vc_w;" pf
  mut F29 "wire [2:0]  ah   = (ah_t[29:16] >= 14'd4) ? 3'd4 : {1'b0, ah_t[17:16]};" "wire [2:0]  ah   = ah_t[18:16];" pf
  mut F31 "vpf <= (r_vpf != 3'd0 && !fit2 && !k_at) ? 3'd0 : r_vpf;" "vpf <= (r_vpf != 3'd0 && !fit2) ? 3'd0 : r_vpf;" pf
  mut F32 "wire        fit2 = (dvn <= 4'd4) && (c2 <= 16'd1300);" "wire        fit2 = (dvn <= 4'd4) && (c2 <= 16'd1900);" pf
  mut F6 "if (!k_nat && k_mode != 2'd3 && (dw1000 <= wc35) && (dh1000 <= hc35)) begin" "if (1'b0) begin" flag
  mut F7 "r_ty <= k_cuy4 ? {k_t, 2'b00} : {1'b0, k_t, 1'b0};" "r_ty <= {1'b0, k_t, 1'b0};" crop
  mut F8 "if (t_wc[13] || t_wc == 14'd0 || t_hc[13] || t_hc == 14'd0) begin" "if (t_wc[13] || t_wc == 14'd0) begin" flag
  mut F9 "                    busy <= 1'b0;
                    st <= S_IDLE;" "                    busy <= 1'b1;
                    st <= S_IDLE;" seq
  mut F10 "r_clamp <= (dv_q > 40'd8191);" "r_clamp <= 1'b0;" flag
  mut F11 "if (k_at && k_w > 8'd40)" "if (k_at && k_w > 8'd127)" dec
  mut F12 "slide <= k_at;" "slide <= 1'b0;" slide
  mut F13 "else if (k_at || k_w > 8'd80)" "else if (k_w > 8'd80)" dec
  mut F14 "dv_n <= {1'b0, (k_pal ? b768 : b640), 1'b0}" "dv_n <= {1'b0, (k_pal ? b640 : b640), 1'b0}" size
  mut F15 "wire [13:0] oy_d = (k_nat ? {2'd0, k_nh} : {1'b0, rh}) - {1'b0, r_oh};" "wire [13:0] oy_d = (k_nat ? {2'd0, k_nh} : 14'd480) - {1'b0, r_oh};" size
  mut F16 "if (pm_q[39:28] != 12'd0) begin" "if (1'b0) begin" size
  mut F17 "if (pm_q > pm_p) begin" "if (pm_q >= pm_p) begin" lb
  mut F18 "end else if (r_lb && (dh1000 <= hc35) && ({1'b0, r_hc} <= rh)) begin" "end else if (1'b0) begin" flag
  mut F19 "pm_mw <= k_dw; pm_mh <= k_dh; pm_cnt <= 4'd12;" "pm_mw <= k_dw; pm_mh <= k_dw; pm_cnt <= 4'd12;" lb
  mut F20 "slide <= k_at; lb <= r_lb;" "slide <= k_at; lb <= 1'b0;" lb
  mut F21 "wire [13:0] ox_d = (k_nat ? {2'd0, k_nw} : 14'd720) - {1'b0, r_ow};" "wire [13:0] ox_d = 14'd720 - {1'b0, r_ow};" size
  mut F22 "if (!k_nat && k_mode != 2'd3 && (dw1000 <= wc35) && (dh1000 <= hc35)) begin" "if ((k_nat || k_mode != 2'd3) && (dw1000 <= wc35) && (dh1000 <= hc35)) begin" "flag|size"
  # (issue #11) Fit
  mut F33 "dv_n <= {1'b0, a405, 1'b0} + {12'd0, r_b};" "dv_n <= {1'b0, a540, 1'b0} + {12'd0, r_b};" size
  mut F34 "r_lb <= (k_mode == 2'd3);" "r_lb <= 1'b1;" lb
  mut F35 "pm_mw <= 12'd16; pm_mh <= 12'd9;" "pm_mw <= 12'd4; pm_mh <= 12'd3;" size
  mut F36 "if (!k_nat && k_mode != 2'd3 && (dw1000 <= wc35) && (dh1000 <= hc35)) begin" "if (!k_nat && !k_mode[1] && (dw1000 <= wc35) && (dh1000 <= hc35)) begin" flag
  mut F37 "if (k_mode == 2'd3 || (k_mode == 2'd2 && r_w16)) begin" "if (k_mode == 2'd3 || k_mode == 2'd2) begin" size
  mut F38 "r_lb <= 1'b0; r_w16 <= 1'b0;
                    st <= S_CROP;" "r_lb <= 1'b0;
                    st <= S_CROP;" size
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
