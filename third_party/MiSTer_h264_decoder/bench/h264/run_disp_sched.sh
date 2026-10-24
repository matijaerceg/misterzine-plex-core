#!/usr/bin/env bash
# run_disp_sched.sh -- the display path from the output queue to the reader (roadmap P5e,
# docs/display.md S7): recon_out -> disp_ctl + disp_sched -> disp_reader over ddr_model,
# three real clocks and the real raster (bench/h264/disp_sched_tb.sv), Verilator --timing
# (a 300-refresh scenario is ~135 M clk_sys cycles: hours in Icarus, ~7 min here), scored
# refresh by refresh against tools/disp_sched_ref.py.
#
# GREEN, one per scenario (tools/disp_sched_ref.py --list):
#   film32 (C1 3:2 film)   prog24 (C2 23.976 progressive: 2.5 refreshes a frame)
#   prog24r (the same, time stamps rounded up: every other frame taken ~750 ticks after
#     its PTS -- not late)
#   tff / bff (C3 field pairs)   fldmix ((P7) frames, a 3-field frame, top-first then bottom-first
#     pairs: at 480i one pair run is held every pair for the raster's field)   fldlate ((P7) [5] on
#     pairs: a late pair is taken at once, off its field or not)   ps78 (C4 pic_struct 7 / 8)   unpaired (C5 single fields)
#   geom (C6 sizes, no VUI timing: the default and its flag)   late ([5] a late decoder)
#   back ([7a] a backward PTS jump)   back200 ([7d] 200 ms back: only the backward leg)   backfld ([7e] the same on single fields)   gap03 ([7b] 0.3 s waited out)   gap2s ([7c] re-anchors)
#   held ([8] LATE_MAX after a 4 s still)   heldlead ((1.1) the same with aud_lead high -- the queued
#   audio ahead of the clock: the late pictures shown at once, NO re-anchor)   starve400 ([8b] a 400 ms starvation is NOT a
#   re-anchor -- MiSTer_DVD's HW round B defect)
#   llsteady / llearly / llburst / llend (P3f, LOW_LATENCY: every head due -- llearly's arrive
#     3 refreshes ahead of their PTS; a head a newer picture
#     waits behind skipped at line 490; a burst at the stream's END still shows the last)
#   lone PTS (UMD fix/film-timing PR fj#25 + fix/lone-early PR fj#26, docs/display.md S10):
#   lone7 ([L1] 3:2 film, lone tags +7 / +8 / +1 tick, a +600-tick one believed between)
#   lonefld ([L2] the same on field pairs, +5)   lone2 ([L3] a real +7-tick gap: its first tag
#     disbelieved, the next believed -- waited out one tag later)   loneearly ([L4] rule B:
#     23.976, a lone tag a frame early)   loneearlyfld ([L5] rule B: pairs, 3 ticks early)
#   back1s ([7f] 1 s back: past the band, re-anchors at once)   lone7@2 (the band's edge at
#     50 Hz's half refresh, 900)
#   C7 (release after the last fetch) and C8 (the last picture held) are every scenario's
#   [hold] arm and END record.
#   the raster standards (P6 steps 5 / 6, docs/analog.md §10; NAME@STD, the .stim header
#   carries it): on 60.00 Hz p60 (60.000 tagged: one a refresh), p60ll (a Moonlight session),
#   p24 (24.000: exactly 2.5 refreshes), film32@1, llburst@1; on 50 Hz p25, p50, i25 (field
#   pairs), film32@2 (29.97 content), llsteady@2 (59.94 low latency: skips). [count] also
#   scores the first picture's rate class (Refresh Rate's Auto).
# --red: mutations on a COPY, each caught by its own arm:
#   D1  due at STC >= PTS (the half-refresh rounding lost)       film32   -> [refresh]
#   D2  lateness re-anchors (LATE_MAX -> half a refresh)         starve400 -> [count]
#   D27 (1.1) the audio's lead ignored                           heldlead -> [refresh]|[count]
#   D3  the backward-jump leg removed                            back200  -> [refresh]|[count]
#       (on `back`, 5 s back, the LATE_MAX leg re-anchors too: it cannot tell them apart)
#   D4  the forward-gap leg widened to 100 s                     gap2s    -> [refresh]|[count]
#   D5  pic_struct 5 / 6 last 2 ticks (Table E-6)                film32   -> [refresh]
#   D6  pic_struct 8 lasts 4 ticks                               ps78     -> [refresh]
#   D7  the VUI tick division starts from 0                      prog24   -> [refresh]
#   (480i, P6 -- every scenario also runs GREEN with +il, against the model's --il stem NAME.il:
#   since P7 a field pair starts on its first field's raster field, so pairs differ by raster)
#   (I1, the field line read as the frame line, retired: the events come from the refresh
#   grid's counter now, no (line, dot) pair to misread -- G1 / G2 guard the grid)
#   G1  the 60.00 Hz grid at 59.94's 450,450                     p60@1    -> [refresh]|[count]
#   G2  the 50 Hz pickup at the 525-line offset (500 x 858)       p25@2    -> [refresh]|[count]|[judder]|[hold]
#   G3  a 50 Hz refresh counted as 12,012 eighth-ticks (cadence)  film32@2 -> [count]
#   G4  half a 50 Hz refresh read as 750 ticks                   film32@2 -> [refresh]|[count]
#   G5  60.000 frames/s not classed 60.00 Hz (Auto)              p60@1    -> [count]
#   I2  a refresh's first line is line 0 only (a bottom field's missed) tff +il -> [judder]
#       (a field-coded pair changes parity every field; film32's changes land 2-3 fields
#       apart, where a top-only count still sees each one: equivalent there)
#   D8  a pair's parity sequence inverted                        tff      -> [refresh]
#   D9  the pickup releases the NEW store                        film32   -> [hold]|[queue]
#   D10 the reader's fetched-change counter dead                 film32   -> [judder]
#   D11 the END record never taken                               film32   -> [count]
#   D12 the cadence window one refresh short                     film32   -> [count]
#   D13 late judged across a re-anchor (the old timeline's STC)  backfld  -> [count]
#   D14 a single field not flagged single (P5f: woven, not bobbed) unpaired -> [refresh]
#       (only single fields take a picture at the refresh right after an anchor)
#   D15 low latency never skips                                  llburst  -> [refresh]|[count]
#   D16 rec_more counts the END (the last picture skipped)       llend    -> [refresh]|[count]
#   D17 low latency not due at every refresh (PTS pacing kept)   llearly  -> [refresh]|[count]
#       (llsteady cannot see it: pictures that arrive on time are due by their PTS anyway)
#   D18 no lone PTS rule (every tag believed: UMD's film gate's defect) lone7  -> [refresh]|[count]
#   D19 the tag after a disbelieved one disbelieved too            lone2    -> [refresh]|[count]
#   D20 the flag never cleared by a believed tag (84 believed)     lone7    -> [refresh]|[count]
#   D21 the band's lower edge at a frame (+1 tick believed)        lone7    -> [refresh]|[count]
#   D22 the band's upper edge removed (a 2 s gap disbelieved)      gap2s    -> [refresh]|[count]
#   D23 a disbelieved tag still shown at its own PTS               lone7    -> [refresh]
#   D24 the lone counter dead (the status block's disp_lone blind) lone7    -> [count]
#   D25 rule B's behind leg removed (an early lone tag believed)   loneearlyfld -> [refresh]|[count]
#   D26 the behind band unbounded (a 1 s backward jump disbelieved) back1s  -> [refresh]|[count]
#   (P7, the field order at 480i / 576i -- UMD's V6; docs/analog.md §5, history.md §35)
#   F1  no hold for the field (the rig's defect: later field first) tff.il +il +field_only -> [field]
#   F2  the parity compare inverted (every pair on the wrong field) tff.il +il +field_only -> [field]
#       (+field_only: [refresh], from the model that states the same rule, catches both a line
#       earlier; made non-fatal so the arm independent of the model shows it can fail alone)
#   F3  the field never alternates (fpar stuck at the top)       tff.il +il -> [refresh]|[field]|[count]
#   F4  a LATE pair held too (a backlog waits for its field)     fldlate.il +il -> [refresh]|[count]
#   F5  frames held for the field too                            film32.il +il -> [refresh]|[count]
#   F6  pairs held on the progressive raster                     tff      -> [refresh]|[count]
#   F7  a held pair's pickup counted late                        fldmix.il +il -> [count]
#   F8  the held store's cadence judged                          fldmix.il +il -> [count]
#   F9  the hold counter dead (word 85's disp_fhold blind)        tff.il +il -> [count]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/disp_sched
mkdir -p $W
fail=0
red=0; jobs=8
for a in "$@"; do case $a in --red) red=1;; esac; done
command -v verilator >/dev/null || { echo "run_disp_sched: SKIP -- no verilator"; exit 2; }
RTL="h264/fifo_dc.sv h264/recon_out.sv h264/disp_sched.sv h264/disp_ctl.sv h264/disp_reader.sv h264/sync_gen.sv"
# included, not compiled: a mutant copy must carry them (a mutant compiled from its copy
# resolves `include "h264/..." there first)
INC="h264/field_polarity.vh"
TB="bench/h264/ddr_model.sv bench/h264/disp_sched_tb.sv"
build() {   # src-root obj-dir -> 0 on success
  local src=$1 obj=$2 files=""
  for f in $RTL; do files="$files $src/$f"; done
  for f in $TB; do files="$files $ROOT/$f"; done
  # shellcheck disable=SC2086
  (cd "$src" && verilator -Ih264 --binary --timing -Wno-fatal -Wno-lint -Wno-style -j 8 --top-module disp_sched_tb \
      -I"$src" --Mdir "$obj" $files) > "$obj.log" 2>&1
}
SC=$(python3 tools/disp_sched_ref.py --list)
# DSCHED_ONLY="a b ...": the GREEN arms (both rasters) of those scenarios alone -- a re-run of a
# few after an interrupted run (2026-10-04: another session's `kill` by process name took 8);
# never with --red, and the verdict names the subset, so it is never read as the whole gate
only=""
if [ -n "${DSCHED_ONLY:-}" ]; then
  [ $red = 1 ] && { echo "run_disp_sched: DSCHED_ONLY re-runs GREEN arms; --red runs the whole set"; exit 2; }
  for s in $DSCHED_ONLY; do
    case " $(echo $SC) " in *" $s "*) ;; *) echo "run_disp_sched: no scenario '$s' (tools/disp_sched_ref.py --list)"; exit 2 ;; esac
  done
  SC=$DSCHED_ONLY; only=" (DSCHED_ONLY: $(echo $SC | wc -w) scenarios, not the whole gate)"
fi
# DSCHED_MUTS="F1 F2 ...": those mutations alone, the GREEN arms skipped (2026-10-06: the whole --red
# outgrew a 2 h session limit at 39 scenarios); with --red only, and the verdict names the subset
if [ -n "${DSCHED_MUTS:-}" ]; then
  [ $red = 1 ] || { echo "run_disp_sched: DSCHED_MUTS needs --red"; exit 2; }
  only=" (DSCHED_MUTS: $DSCHED_MUTS -- not the whole gate)"
fi
for s in $SC; do
  python3 tools/disp_sched_ref.py --scenario "$s" --out "$W/$s" > "$W/$s.ref.log" 2>&1 || { echo "FAIL: model $s"; cat "$W/$s.ref.log"; exit 1; }
  python3 tools/disp_sched_ref.py --il --scenario "$s" --out "$W/$s.il" > "$W/$s.il.ref.log" 2>&1 || { echo "FAIL: model $s --il"; cat "$W/$s.il.ref.log"; exit 1; }
done
echo "== build =="
build "$ROOT" "$ROOT/$W/obj" || { echo "FAIL: build"; tail -20 "$W/obj.log"; exit 1; }
echo "  built $W/obj/Vdisp_sched_tb"
if [ -z "${DSCHED_MUTS:-}" ]; then
echo "== GREEN: $(echo $SC | wc -w) scenarios =="
for s in $SC; do
  (timeout 3600 "$W/obj/Vdisp_sched_tb" +stem="$W/$s" > "$W/$s.log" 2>&1) &
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
done
wait
for s in $SC; do
  if grep -q "^PASS: disp_sched_tb" "$W/$s.log"; then
    echo "  PASS $s: $(grep -m1 '^disp_sched_tb:' "$W/$s.log" | sed 's/^disp_sched_tb: //')"
  else echo "  FAIL $s"; grep -m3 "FAIL\|Error" "$W/$s.log" | sed 's/^/    /'; fail=1; fi
done
# P6 (docs/analog.md): every scenario again on the interlaced raster (+il) -- a refresh is a
# field, its events placed on the model's grid (450,450 / 450,000 / 540,000 cycles); the
# reader counts its fetches at each field's first line. P7: the model's --il stem (a field
# pair starts on its first field's raster field: the pairs' refreshes differ by raster)
echo "== GREEN: the same $(echo $SC | wc -w) scenarios on the 480i raster =="
for s in $SC; do
  (timeout 3600 "$W/obj/Vdisp_sched_tb" +stem="$W/$s.il" +il > "$W/$s.il.log" 2>&1) &
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
done
wait
for s in $SC; do
  if grep -q "^PASS: disp_sched_tb" "$W/$s.il.log"; then
    echo "  PASS $s (480i): $(grep -m1 '^disp_sched_tb:' "$W/$s.il.log" | sed 's/^disp_sched_tb: //')"
  else echo "  FAIL $s (480i)"; grep -m3 "FAIL\|Error" "$W/$s.il.log" | sed 's/^/    /'; fail=1; fi
done
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new scenario arm [plusargs]
    local name=$1 file=$2 old=$3 new=$4 sc=$5 arm=$6 extra=${7:-} d
    if [ -n "${DSCHED_MUTS:-}" ]; then case " $DSCHED_MUTS " in *" $name "*) ;; *) return ;; esac; fi
    d=$(mktemp -d)
    for f in $RTL $INC; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! flock "$ROOT/$W/build.lock" bash -c "$(declare -f build); ROOT='$ROOT' RTL='$RTL' TB='$TB' build '$d' '$d/obj'"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    timeout 3600 "$d/obj/Vdisp_sched_tb" +stem="$ROOT/$W/$sc" $extra > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 "FAIL\|rror" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut D1 h264/disp_sched.sv "(an || ll || (d_stc_want >= -HALF_SCAN))" "(an || ll || (d_stc_want >= 34'sd0))" film32 refresh &
  mut D2 h264/disp_sched.sv "lat  = (d_stc_pic > LATE_MAX_TICKS) && !lead_q;" "lat  = (d_stc_pic > HALF_SCAN) && !lead_q;" starve400 count &
  # (1.1) the audio's lead ignored: heldlead's late pictures re-anchor behind the leading audio
  mut D27 h264/disp_sched.sv "lat  = (d_stc_pic > LATE_MAX_TICKS) && !lead_q;" "lat  = (d_stc_pic > LATE_MAX_TICKS);" heldlead "refresh|count" &
  mut D3 h264/disp_sched.sv "((d_pic_next < -\$signed({11'd0, head_frame_t})) ||" "((1'b0) ||" back200 "refresh|count" &
  mut D4 h264/disp_sched.sv "(d_pic_next > FWD_MAX_TICKS) ||" "(d_pic_next > 34'sd9000000) ||" gap2s "refresh|count" &
  mut D5 h264/disp_ctl.sv "4'd5, 4'd6:       nt = 3'd3;" "4'd5, 4'd6:       nt = 3'd2;" film32 refresh &
  mut D6 h264/disp_ctl.sv "4'd8:             nt = 3'd6;" "4'd8:             nt = 3'd4;" ps78 refresh &
  wait
  mut D7 h264/disp_ctl.sv "rem <= {5'd0, num[51:24]};" "rem <= '0;" prog24 refresh &
  mut D8 h264/disp_ctl.sv "sh_parity <= cur_first_bot ^ !idx[0];" "sh_parity <= cur_first_bot ^ idx[0];" tff refresh &
  mut D9 h264/disp_ctl.sv "if (have_cur) begin rel_valid <= 1'b1; rel_store <= sh_store; end" \
         "if (have_cur) begin rel_valid <= 1'b1; rel_store <= rec_store; end" film32 "hold|queue" &
  mut D10 h264/disp_reader.sv "fetch_changes <= fetch_changes + 32'd1;" "fetch_changes <= fetch_changes + 32'd0;" film32 judder &
  mut D11 h264/disp_ctl.sv "ev_end  <= rec_valid && rec_end && !ended;" "ev_end  <= 1'b0;" film32 count &
  mut D12 h264/disp_ctl.sv "c_hi <= R_Q3 + R_Q3;" "c_hi <= R_Q3;" film32 count &
  mut D13 h264/disp_sched.sv "prev_ok <= prev_run && !re_anch;" "prev_ok <= prev_run;" backfld count &
  mut D14 h264/disp_ctl.sv "sh_single <= !rec_frame && rec_unpaired;" "sh_single <= 1'b0;" unpaired refresh &
  wait
  mut D15 h264/disp_ctl.sv "if (sk_pulse && low_lat && have_cur" "if (1'b0 && sk_pulse && low_lat && have_cur" llburst "refresh|count" &
  mut D16 h264/recon_out.sv "assign rec_more = rec_valid && !rq_empty && !end_s2;" "assign rec_more = rec_valid && !rq_empty;" llend "refresh|count" &
  mut D17 h264/disp_sched.sv "(an || ll || (d_stc_want >= -HALF_SCAN))" "(an || (d_stc_want >= -HALF_SCAN))" llearly "refresh|count" &
  mut G1 h264/disp_ctl.sv "(std == 2'd1) ? 20'd449999 : 20'd450449;" "(std == 2'd1) ? 20'd450449 : 20'd450449;" "p60@1" "refresh|count" &
  mut G2 h264/disp_ctl.sv "wire [19:0] p_pick  = pal ? 20'd518400 : 20'd429000;" "wire [19:0] p_pick  = pal ? 20'd429000 : 20'd429000;" "p25@2" "refresh|count|judder|hold" &
  mut I2 h264/disp_reader.sv "ln_first <= (nxt_line == 12'd0) || (il && nxt_line == 12'd1);" "ln_first <= (nxt_line == 12'd0);" tff.il judder +il &
  wait
  mut G3 h264/disp_ctl.sv "wire [27:0] R_Q3 = pal ? 28'd14400" "wire [27:0] R_Q3 = pal ? 28'd12012" "film32@2" "count" &
  mut G4 h264/disp_ctl.sv ".half(pal ? 11'd900 : 11'd750)," ".half(11'd750)," "film32@2" "refresh|count" &
  mut G5 h264/disp_ctl.sv "(fq == 24'd3000 || fq == 24'd6000 ||" "(fq == 24'd3000 ||" "p60@1" "count" &
  wait
  # UMD's lone-PTS rules A and B (PR fj#25 + fj#26; UMD's D30-D38)
  mut D18 h264/disp_sched.sv "ln = tag_q && anchored" "ln = 1'b0 && anchored" lone7 "refresh|count" &
  mut D19 h264/disp_sched.sv "if (lone) susp <= 1'b1;" "if (1'b0) susp <= 1'b1;" lone2 "refresh|count" &
  mut D20 h264/disp_sched.sv "else if (tag_e) susp <= 1'b0;" "else if (1'b0) susp <= 1'b0;" lone7 "refresh|count" &
  wait
  mut D21 h264/disp_sched.sv "((d_pic_next > HALF_SCAN) ||" "((d_pic_next > \$signed({11'd0, head_frame_t})) ||" lone7 "refresh|count" &
  mut D22 h264/disp_sched.sv "!(d_pic_next > FWD_MAX_TICKS) && !(d_pic_next < -FWD_MAX_TICKS)" "1'b1 && !(d_pic_next < -FWD_MAX_TICKS)" gap2s "refresh|count" &
  mut D23 h264/disp_sched.sv "if (ln) want <= next_pts;" "if (1'b0) want <= next_pts;" lone7 refresh &
  wait
  mut D24 h264/disp_ctl.sv "if (lone && n_lone != 4'hF) n_lone <= n_lone + 4'd1;" "if (1'b0) n_lone <= n_lone + 4'd1;" lone7 count &
  mut D25 h264/disp_sched.sv "|| (d_pic_next < -HALF_SCAN)) &&" "|| 1'b0) &&" loneearlyfld "refresh|count" &
  mut D26 h264/disp_sched.sv "!(d_pic_next > FWD_MAX_TICKS) && !(d_pic_next < -FWD_MAX_TICKS)" "!(d_pic_next > FWD_MAX_TICKS) && 1'b1" back1s "refresh|count" &
  wait
  # P7: the field order at 480i / 576i (UMD's V6)
  mut F1 h264/disp_ctl.sv "wire fhold = il && !late && !rec_frame" "wire fhold = 1'b0 && !late && !rec_frame" tff.il field "+il +field_only" &
  mut F2 h264/disp_ctl.sv "(rec_first_bot == fpar);" "(rec_first_bot != fpar);" tff.il field "+il +field_only" &
  mut F3 h264/disp_ctl.sv "if (rp == rf_m1) fpar <= !fpar;" "if (1'b0) fpar <= !fpar;" tff.il "refresh|field|count" +il &
  wait
  mut F4 h264/disp_ctl.sv "wire fhold = il && !late && !rec_frame" "wire fhold = il && !rec_frame" fldlate.il "refresh|count" +il &
  mut F5 h264/disp_ctl.sv "!late && !rec_frame && !rec_unpaired &&" "!late && !rec_unpaired &&" film32.il "refresh|count" +il &
  mut F6 h264/disp_ctl.sv "wire fhold = il && !late" "wire fhold = 1'b1 && !late" tff "refresh|count" &
  wait
  mut F7 h264/disp_ctl.sv "if (late && !held_f) n_late" "if (late) n_late" fldmix.il count +il &
  mut F8 h264/disp_ctl.sv "contig && !held_f &&" "contig &&" fldmix.il count +il &
  mut F9 h264/disp_ctl.sv "if (ev_head && due && fhold) n_fhold <= n_fhold + 32'd1;" "if (ev_head && due && fhold) n_fhold <= n_fhold + 32'd0;" tff.il count +il &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN$only ==" || echo "== FAILURES$only =="
exit $fail
