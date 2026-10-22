#!/usr/bin/env bash
# run_ring_rd.sh -- the HPS interface's reader and status block (h264/ring_rd.sv,
# h264/ring_stat.sv, cdc_snap_ix, the generated ring_words_*) against tools/ring_model.py:
# bench/h264/ring_rd_tb.sv, one simulation per scenario (R1-R27, tools/ring_model.py
# --list), three real clocks, through ddr_mux2 beside a random master A into
# bench/h264/ddr_model.sv. docs/architecture.md "The HPS interface, v0.1".
#
# GREEN: tools/ring_layout.py --check (the generated files match the table); every
# scenario delivers exactly the model's stream (bytes, PTS marks, access-unit ends, stream
# resets, EOS flushes), stops on the model's error with its position and word, and leaves
# the model's status fields in DDR3 (read through the seqlock).
#   R1 bytes/marks/PTS, R2 the wraps (ring and u32) and PADs, R3 a whole ring then a
#   write index beyond it, R4 a misaligned write index, R5-R11 each header error (sync,
#   type / zero header, flags, length, seq / stale lap, CONTROL, crossing the end), R12 a
#   stale boot (nothing replays), R13 a session replaced mid-stream (must cut: the slow
#   poll), R14 the idle poll bound, R15 AUDIO queued (0.5: each descriptor in the stream's
#   order, each payload fetched through the engine and checked word for word by the bench's
#   stand-in audio path), R16 DISCONTINUITY / EOS /
#   NEED_DISCONT, R17 LOW_LATENCY, R18 the status words (0.3's raster report and 0.4's OSD
#   mirror land where the layout says), R21 GRAPHICS (0.4: taken from the stream's first
#   VIDEO_AU, the live bit, later disagreements counted), R22 the settings request (0.4: the
#   engine, h264/osd_req.sv and a stand-in Main -- applied, a repeated sequence number
#   ignored, an out-of-range value refused), R19 an OSD reset mid-stream (must
#   cut; the ack cleared), R20 a PAD short of the ring's end; 0.5: R23 an AUDIO record not
#   whole frames (HDR_LENGTH), R24 mostly audio against a slow consumer (the producer waits on
#   the held read index; one released early lets it overwrite an unfetched record), R25 the
#   pause word (nothing consumed while paused, a refused word, resume), R26 a DISCONTINUITY
#   after END_OF_STREAM waits for the queued audio; 0.13: R27 the rumble (program words 36-38:
#   nothing passed on before a session, a session's values applied, a change in one, the high halves
#   ignored, 0 after an OSD reset, the values back with the next session; words 82-83, the count);
#   0.15 (PICTURE records: h264/pic_in.sv and h264/recon_out.sv on clk_dec, a stand-in display taking
#   each record against the model's pics.hex): R28 a picture stream (frames and pairs, every field
#   through, audio beside it, END_OF_STREAM -> ENDED, word 84), R29 every error in a session of its own
#   (each PIC_* check, HDR_LENGTH 31 / 33, NEED_DISCONT, STREAM_KIND both ways, PIC_BUSY), R30 the kinds
#   switched legally (DISCONTINUITY in order and after END_OF_STREAM), R32 a session's clear while a
#   hand-over is in flight (pd_ack stretched: the picture taken is shown, nothing replays), R33
#   LOW_LATENCY / GRAPHICS from the stream's first PICTURE; 0.16 (the colour, docs/colour.md): R34 a coded
#   stream's colour from its first VIDEO_AU (a later disagreement counted, a new stream's own; word 80's colour
#   and word 86 where the layout says), R35 a PICTURE's code -- its own, else the size rule on the shown size at
#   the bounds (1,280 wide, 576 high, a crop across each) -- and every random picture's (R28-R33) resolved code,
#   R36 HDR_COLOUR (7 on a VIDEO_AU and a PICTURE, a colour on an AUDIO) and HDR_SYNC on bits 36 / 47.
#
# --red: mutations on a COPY of the RTL (tree kept, compiled from inside the copy: the RTL
# includes the generated h264/ring_iface.svh), each caught by its own arm (scenario +
# check); an unmutated control copy runs first and must pass.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/ring
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="h264/cdc.sv h264/fifo_dc.sv h264/ddr_mux2.sv h264/ring_rd.sv h264/osd_req.sv h264/ring_stat.sv h264/ring_words_sys.sv h264/ring_words_mem.sv h264/ring_words_dec.sv h264/ring_in.sv h264/ring_words_in.sv h264/pic_in.sv h264/recon_out.sv"
INC="h264/ring_iface.svh"
TB="bench/h264/ddr_model.sv bench/h264/ring_rd_tb.sv"
SCEN=$(python3 tools/ring_model.py --list)

args_for() {   # per-scenario plusargs: R13 / R19 run with the decoder mostly stalled (the must-cut arms)
  case $1 in R13|R19) echo "+ready_pct=5";; R29|R36) echo "+errs_any";; R32) echo "+ack_delay=6000";; *) echo "";; esac
}

echo "== the layout =="
if python3 tools/ring_layout.py --check; then :; else fail=1; fi

echo "== fixtures (tools/ring_model.py) =="
for s in $SCEN; do
  python3 tools/ring_model.py --scenario "$s" --out ".sim/ring/$s" || { echo "  FAIL model $s"; fail=1; }
done

echo "== GREEN: ring_rd_tb =="
# shellcheck disable=SC2086
rm -f .sim/ring_sim   # iverilog leaves the old binary on a failed build: never run it
iverilog -g2012 -o .sim/ring_sim $RTL $TB 2>&1 | grep -v "sorry\|pop_front"
run_scen() {   # sim stem scenario -> log
  # shellcheck disable=SC2046
  timeout 900 vvp -n "$1" +stem="$2/$3" +arm="$3" $(args_for "$3") > "$4" 2>&1
}
for s in $SCEN; do
  if [ -f .sim/ring_sim ] && run_scen .sim/ring_sim .sim/ring "$s" ".sim/ring/$s.log" && grep -q "^PASS: ring_rd_tb $s" ".sim/ring/$s.log"; then
    echo "  PASS $s: $(grep '^ring_rd_tb:' ".sim/ring/$s.log" | sed 's/^ring_rd_tb: [^ ]* //')"
  else
    echo "  FAIL $s"; grep -m3 "FAIL" ".sim/ring/$s.log"; fail=1
  fi
done

echo "== GREEN: interface 1.2 geometry request/ACK transaction =="
rm -f .sim/ring_geom_sim   # iverilog can leave an old binary after a failed build
if iverilog -g2012 -s ring_geom_tb -o .sim/ring_geom_sim h264/cdc.sv h264/fifo_dc.sv h264/ring_rd.sv \
    h264/ring_words_sys.sv h264/ring_words_mem.sv h264/ring_words_dec.sv h264/ring_in.sv h264/ring_words_in.sv \
    h264/pic_in.sv h264/recon_out.sv bench/h264/ddr_model.sv bench/h264/ring_geom_tb.sv 2>.sim/ring_geom_build.log &&
    vvp -n .sim/ring_geom_sim >.sim/ring_geom.log 2>&1 && grep -q '^PASS: ring_geom_tb' .sim/ring_geom.log; then
  cat .sim/ring_geom.log
else
  echo "  FAIL geometry protocol"; grep -m3 -E 'FAIL|FATAL|ERROR' .sim/ring_geom.log .sim/ring_geom_build.log 2>/dev/null; fail=1
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  FIX=$(cd .sim/ring && pwd)
  mk_copy() {
    local d=$1
    for f in $RTL $INC $TB; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
  }
  # the control: the unmutated copy, built the same way, must pass the scenarios the arms use
  CTL=$(mktemp -d); mk_copy "$CTL"
  # shellcheck disable=SC2086
  if (cd "$CTL" && iverilog -g2012 -o sim $RTL $TB 2>build.log) && run_scen "$CTL/sim" "$FIX" R1 "$CTL/log" && grep -q "^PASS:" "$CTL/log"; then
    echo "  control: the unmutated copy passes R1"
  else echo "  CONTROL FAIL: the unmutated copy does not pass"; fail=1; fi
  rm -rf "$CTL"
  mut() {   # name file old new scenario arm(regex)
    local name=$1 file=$2 old=$3 new=$4 scen=$5 arm=$6
    local d; d=$(mktemp -d)
    mk_copy "$d"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTL $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    run_scen "$d/sim" "$FIX" "$scen" "$d/log"
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- $scen cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $scen $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm] of $scen:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  R=h264/ring_rd.sv; S=h264/ring_stat.sv; Q=h264/osd_req.sv
  # the engine (clk_mem)
  mut E1 $R "seen_nonce <= p_nonce; booted <= 1'b1;" "booted <= 1'b1;" R12 "events|bytes|final" &
  mut E2 $R "(caught && ptimer >= POLL_FAST_W)" "(caught)" R14 "poll" &
  mut E3 $R "wire         poll_due = (ptimer >= POLL_SLOW_W) ||" "wire         poll_due = 1'b0 ||" R13 "poll" &
  mut E4 $R "end else if (d_rw > RING_BYTES || d_ww > RING_BYTES) begin" "end else if (1'b0) begin" R3 "final" &
  mut E5 $R "if (p_wi[3:0] != 4'd0) begin" "if (1'b0) begin" R4 "final" &
  mut E6 $R "wire  [3:0]  rn     = (to_end < {{(RING_AW-3){1'b0}}, rn_a}) ? to_end[3:0] : rn_a;" "wire  [3:0]  rn     = rn_a;" R2 "final|bytes|events" &
  wait
  mut E7 $R "E_PCMD: if (!b_waitrequest) begin b_read <= 1'b0; es <= E_PDATA; end" "E_PCMD: begin b_read <= 1'b0; es <= E_PDATA; end" R1 "avalon" &
  mut E8 $R "b_address <= CTRL_WORD + {22'd0, sf_dout[70:64]}; b_burstcount <= 8'd8;" "b_address <= CTRL_WORD; b_burstcount <= 8'd8;" R12 "words|seqlock|final" &
  mut E9 $R "if (!rst_m2) rst_seen <= 1'b1;" "" R19 "hang" &
  mut E10 $R "rw <= start; ww <= start; pub <= start; eng_err <= '0;" "ww <= start; pub <= start; eng_err <= '0;" R13 "bytes|events|hang|final" &
  # the parser (clk_sys)
  mut P1 $R "assign es_mark   = first_byte && h_flags[RF_PTS_VALID];" "assign es_mark   = first_byte;" R1 "bytes" &
  mut P2 $R "assign es_au_end = (bleft == 32'd1);" "assign es_au_end = (bleft == 32'd2);" R1 "bytes" &
  wait
  mut P3 $R "else if (t_seq != seq)                                     h0_err = RE_HDR_SEQ;" "" R9 "final|bytes" &
  mut P4 $R "wire         w1_bad  = (word[63:48] != RI_SYNC) || (word[47:36] != 12'd0);" "wire         w1_bad  = (word[47:36] != 12'd0);" R5 "final|bytes" &
  mut P5 $R "else if (t_pad ? (t_endp != {1'b0, RING_BYTES}) : (t_endp > {1'b0, RING_BYTES})) h0_err = RE_HDR_WRAP;" "else if (!t_pad && (t_endp > {1'b0, RING_BYTES})) h0_err = RE_HDR_WRAP;" R20 "final|bytes|events" &
  mut P6 $R "else if (t_pad ? (t_endp != {1'b0, RING_BYTES}) : (t_endp > {1'b0, RING_BYTES})) h0_err = RE_HDR_WRAP;" "else if (t_pad && (t_endp != {1'b0, RING_BYTES})) h0_err = RE_HDR_WRAP;" R11 "final|bytes|events" &
  mut P7 $R "                        else ps <= P_RST;" "                        else ps <= P_AUSTART;" R16 "events|bytes" &
  mut P8 $R "if (h_vrec && h_flags[RF_END_OF_STREAM]) begin eos <= h_video; eos_seen <= 1'b1; end" "" R16 "events" &
  wait
  mut P9 $R "end else if (h_vrec && eos_seen && !h_flags[RF_DISCONTINUITY]) begin" "end else if (1'b0) begin" R16 "final|bytes" &
  mut P10 $R "else if (t_type == RT_CONTROL)                             h0_err = RE_CONTROL_UNSUPPORTED;" "" R10 "final|bytes|events" &
  mut P11 $R "else if ((t_flags & ~t_allow) != 8'd0)                     h0_err = RE_HDR_FLAGS;" "" R7 "final|bytes" &
  mut P12 $R "else if (t_len > RI_MAX_PAYLOAD || (t_video && t_len == 32'd0) ||" "else if (1'b0 ||" R8 "final" &
  mut P13 $R "if (!(t_video || t_pad || t_audio || t_pic || t_type == RT_CONTROL)) h0_err = RE_HDR_TYPE;" "if (1'b0) h0_err = RE_HDR_TYPE;" R6 "final|bytes|events" &
  mut P14 $R "                        n_pad <= n_pad + 32'd1;" "                        n_pad <= n_pad + 32'd2;" R2 "final" &
  wait
  mut P15 $R "if (first_au) begin                // the stream's first video record: a VIDEO_AU" "if (1'b1) begin" R17 "final" &
  # interface 0.4: GRAPHICS
  mut G1 $R "ll_mode <= h_flags[RF_LOW_LATENCY]; gfx_mode <= h_flags[RF_GRAPHICS]; first_au <= 1'b0;" "ll_mode <= h_flags[RF_LOW_LATENCY]; first_au <= 1'b0;" R21 "final" &
  mut G2 $R "wire  [7:0]  t_allow = (t_video || t_pic) ? 8'h1F" "wire  [7:0]  t_allow = (t_video || t_pic) ? 8'h0F" R21 "final|bytes" &
  mut G3 $R "if (gfx_mode != h_flags[RF_GRAPHICS] && gfx_mismatch != 16'hFFFF)" "if (1'b0 && gfx_mismatch != 16'hFFFF)" R21 "final" &
  # interface 0.4: the settings request (R22: the engine, osd_req and a stand-in Main)
  mut Q1 $R "if (p_set[31:24] != 8'd0 && p_set[31:24] != set_last) begin" "if (p_set[31:24] != 8'd0) begin" R22 "final" &
  mut Q2 $R "b_burstcount <= RI_POLL_WORDS; b_read <= 1'b1;" "b_burstcount <= 8'd4; b_read <= 1'b1;" R1 "hang|final|bytes|events|missing" &
  mut Q3 $Q "(m[6] && v[12:11] == 2'd3);" "1'b0;" R22 "final" &
  mut Q4 $Q "if (m[5]) status_in[12:11] <= v[10:9];" "if (m[5]) status_in[12:11] <= v[8:7];" R22 "final" &
  mut Q5 $Q "                    status_set <= 1'b1;" "                    status_set <= 1'b0;" R22 "final" &
  mut P16 $R "have <= 1'b0; lane <= '0; wleft <= wleft - 30'd1;" "have <= 1'b0; lane <= '0;" R1 "final|bytes|events" &
  mut P17 $R "rpos <= rpos + {h_words, 3'b000} + 32'd16;" "rpos <= rpos + {h_words, 3'b000};" R2 "final|bytes|events" &
  # the status block
  mut S1 $S "st_word <= sys_word; st_ix <= k; st_wr <= 1'b1;" "st_word <= sys_word; st_ix <= k ^ 7'd1; st_wr <= 1'b1;" R12 "words|seqlock|final" &
  mut S2 $S "wire is_dec = !k[6] && RI_DEC_WORDS[k[5:0]];" "wire is_dec = 1'b0;" R12 "words" &
  mut S3 $S "if (st_free >= 7'd48) begin frame_p <= 1'b0; seq <= seq + 32'd1; s <= '0; bs <= B_FETCH; end" "if (st_free >= 7'd48) begin frame_p <= 1'b0; s <= '0; bs <= B_FETCH; end" R12 "seqlock" &
  # interface 0.5: the second region in the write order (before seq_tail)
  mut S5 $S "else if (s < S_B) k = {1'b0, s} + 7'd16;" "else if (s < S_B) k = {1'b0, s} + 7'd8;" R12 "words|seqlock" &
  # interface 0.10: the third region (words 80-87) in the write order, word 80's fields
  mut S6 $S "else if (s < S_C) k = {1'b0, s} + 7'd48;" "else if (s < S_C) k = {1'b0, s} + 7'd40;" R12 "words|seqlock" &
  wait
  # interface 0.5: the audio (the ring is its buffer), the pause word
  mut A1 $R "rel_s <= a_hold_v ? a_hold_idx : rpos;" "rel_s <= rpos;" R24 "audio" &
  mut A2 $R "(t_audio && (t_len == 32'd0 || t_len[1:0] != 2'd0)) ||" "1'b0 ||" R23 "final|events|audio" &
  mut A3 $R "assign ad_pos  = rpos;" "assign ad_pos  = rpos + 32'd16;" R15 "events|bytes|audio" &
  mut A4 $R "!caught && !pause_m && rf_free >= 7'd8) begin" "!caught && rf_free >= 7'd8) begin" R25 "pause" &
  mut A5 $R "if ((p_ctl & RI_CTL_RESERVED) != 32'd0) ctl_err_m <= 1'b1;" "if (1'b0) ctl_err_m <= 1'b1;" R25 "hang|final|pause" &
  mut A6 $R "b_address <= RING_WORD + {{(29-RING_AW){1'b0}}, af_addr_q[RING_AW+2:3]};" "b_address <= RING_WORD + {{(29-RING_AW){1'b0}}, af_addr_q[RING_AW+2:3]} + 29'd1;" R15 "audio" &
  wait
  mut A7 $R "rw <= start; ww <= start; pub <= start;" "rw <= start; ww <= start;" R13 "hang|final|bytes|events" &
  mut A8 $R "if ((disp_ended && aud_idle) || end_cnt == END_WAIT_W) ps <= P_RST;" "if (disp_ended || end_cnt == END_WAIT_W) ps <= P_RST;" R26 "audio" &
  mut A9 $R "P_ADESC: if (ad_room) begin" "P_ADESC: if (1'b1) begin" R24 "audio|bytes|events" &
  # interface 0.2: word 30's fields where the layout puts them (the generated mux)
  mut S4 h264/ring_words_sys.sv "w[17:17] = f_fit_clamp; w[18:18] = f_fit_snap;" "w[17:17] = f_fit_snap; w[18:18] = f_fit_clamp;" R12 "words" &
  mut S7 h264/ring_words_sys.sv "w[11:0] = f_raster_w; w[23:12] = f_raster_h;" "w[11:0] = f_raster_h; w[23:12] = f_raster_w;" R12 "words" &
  # interface 0.11: word 81's constants (the largest picture still 0.10's 1,620)
  mut S8 h264/ring_words_sys.sv "7'd81: begin w[15:0] = 16'hE10;" "7'd81: begin w[15:0] = 16'h654;" R12 "words" &
  wait
  # interface 0.13: the rumble (R27)
  mut U1 $R "wire  [95:0] rum_out_m = sess_m ? rum_m : 96'd0;" "wire  [95:0] rum_out_m = rum_m;" R27 "hang|final" &
  mut U2 $R "3'd4: p_rum[31:0]  <= b_readdata[31:0];" "3'd4: p_rum[31:0]  <= b_readdata[63:32];" R27 "hang|final" &
  mut U3 $R "if (rumble != rum_q) rum_changes <= rum_changes + 32'd1;" "if (rumble != rum_q) rum_changes <= rum_changes + 32'd2;" R27 "final" &
  mut U4 $R "3'd5: p_rum[63:32] <= b_readdata[31:0];" "3'd5: p_rum[95:64] <= b_readdata[31:0];" R27 "hang|final" &
  mut U5 $R "rum_m <= p_rum;                                       // 0.13" "                                                      // 0.13" R27 "hang" &
  mut U6 h264/ring_words_sys.sv "7'd83: begin w[15:0] = f_rum_p4; w[31:16] = f_rum_p5;" "7'd83: begin w[15:0] = f_rum_p5; w[31:16] = f_rum_p4;" R27 "hang|final" &
  wait
  # interface 0.15: PICTURE records (h264/pic_in.sv; R28-R33)
  I=h264/pic_in.sv
  mut X1 $R "if (!first_au && pic_mode) begin           // 0.15: a VIDEO_AU in a picture stream" "if (1'b0) begin" R29 "hang|final|bytes" &
  mut X2 $R "if (!first_au && !pic_mode) begin          // a PICTURE in a coded stream" "if (1'b0) begin" R29 "hang|final|pics" &
  mut X3 $R "if ((word & rsv_m) != 64'd0) rsv_bad <= 1'b1;" "" R29 "hang|pics" &
  mut X4 $R "(q_psv && (q_pair || !ps_ok))" "(q_psv && q_pair)" R29 "hang|pics" &
  mut X5 $R "(q_idc >= 8'd17 && q_idc <= 8'd254)" "1'b0" R29 "hang|pics" &
  mut X6 $R "(q_tv && (q_nuit == 32'd0 || q_ts == 32'd0))" "1'b0" R29 "hang|pics" &
  wait
  mut X7 $R "wire         s_bad   = (q_store >= RI_DPB_STORES[4:0]);" "wire         s_bad   = 1'b0;" R29 "hang|pics|hold" &
  mut X8 $R "(q_pair && q_hf[0]) || (area > RI_CAP_MAX_MBS);" "(q_pair && q_hf[0]);" R29 "hang|pics" &
  mut X9 $R "(q_pair && q_hf[0]) || (area > RI_CAP_MAX_MBS);" "(area > RI_CAP_MAX_MBS);" R29 "hang|pics" &
  mut X10 $R "msh <= {msh[14:0], 1'b0}; hsh <= {1'b0, hsh[7:1]};" "hsh <= {1'b0, hsh[7:1]};" R29 "hang|pics" &
  mut X11 $R "wire         c_bad   = (q_lr >= {q_w, 3'b000}) || (q_tb >= {q_hf, 3'b000});" "wire         c_bad   = (q_lr >= {q_w, 3'b000});" R29 "hang|pics" &
  mut X12 $R "assign pd_crop     = {pdw3[9:0], pdw3[19:10], pdw3[29:20], pdw3[39:30]};" "assign pd_crop     = pdw3[39:0];" R28 "pics" &
  wait
  mut X13 $R "if (req_s2 && !cack && !pd_hold) begin" "if (req_s2 && !cack) begin" R32 "pics|hang|missing|final" &
  mut X14 $R "begin eos <= h_video; eos_seen <= 1'b1; end" "begin eos <= 1'b1; eos_seen <= 1'b1; end" R28 "events" &
  mut X15 $R "gfx_mode <= h_flags[RF_GRAPHICS]; ll_mode <= h_flags[RF_LOW_LATENCY]; first_au <= 1'b0;" "first_au <= 1'b0;" R33 "final" &
  mut X16 $R "                            pic_mode <= 1'b1;" "" R29 "hang|final" &
  mut X17 $R "(t_pic && t_len != {24'd0, RI_PIC_PAYLOAD}))" "1'b0)" R29 "hang|pics" &
  mut X18 $R "P_PWAIT: if (pa_s2) begin pd_req <= 1'b0; pd_bq <= pb_s2; ps <= P_PDONE; end" "P_PWAIT: if (pa_s2) begin pd_req <= 1'b0; pd_bq <= 1'b0; ps <= P_PDONE; end" R29 "hang|final" &
  wait
  mut X19 $I "I_CHK: if (d_store < NST[4:0] && oq_hold[d_store]) begin" "I_CHK: if (1'b0) begin" R29 "hang|pics|final" &
  mut X20 $I "if (d_pair) st <= I_B; else st <= I_E;" "st <= I_E;" R28 "pics" &
  mut X21 $I "else if (o_emit) pic_emitted <= pic_emitted + 32'd1;" "else if (st == I_E) pic_emitted <= pic_emitted + 32'd1;" R28 "hold" &
  mut X22 $I "        if (sel) begin" "        if (1'b0) begin" R28 "pics|missing|hang|hold" &   # [hold]: emitted, never reaching recon_out
  mut X23 $I "        if (sel) begin" "        if (1'b1) begin" R1 "mux" &
  mut X24 $I "            pinfo_pts      = o_second ? 33'd0 : d_pts;" "            pinfo_pts      = d_pts;" R28 "pics" &
  mut X25 h264/ring_words_sys.sv "w[20:20] = f_pic_mode;" "w[20:20] = 1'b0;" R28 "final" &
  wait
  # 0.16, the colour (docs/colour.md): R34 a coded stream's, R35 a PICTURE's, R36 the errors
  mut C1 $R "end else if (w1_col == 3'd7 || (w1_col != 3'd0 && !h_vrec)) begin" "end else if (1'b0) begin" R36 "final|bytes|events|hang" &
  mut C2 $R "colour_mode <= h_col; colour_mismatch <= '0;   // (0.16) the stream's colour" "colour_mismatch <= '0;" R34 "final" &
  mut C3 $R "if (colour_mode != h_col && colour_mismatch != 16'hFFFF) colour_mismatch <= colour_mismatch + 16'd1;" "" R34 "final" &
  mut C4 $R "wire         w1_bad  = (word[63:48] != RI_SYNC) || (word[47:36] != 12'd0);" "wire         w1_bad  = (word[63:48] != RI_SYNC) || (word[47:33] != 15'd0);" R34 "final|bytes" &
  mut C5 $I "((d_wshow >= 13'd1280) || (d_hshow > 13'd576))" "((d_wshow > 13'd1280) || (d_hshow > 13'd576))" R35 "pics" &
  mut C6 $I "wire  [12:0] d_wshow = {1'b0, d_w, 4'd0}  - {2'd0, ({1'b0, d_crop[39:30]} + {1'b0, d_crop[29:20]}), 1'b0};" "wire  [12:0] d_wshow = {1'b0, d_w, 4'd0};" R35 "pics" &
  wait
  mut C7 $I "d_colour <= (d_pcol >= 3'd1 && d_pcol <= 3'd6) ? d_pcol :" "d_colour <= (1'b0) ? d_pcol :" R35 "pics" &
  mut C8 h264/recon_out.sv "pinfo_aspect, pinfo_colour, pinfo_col_unsup," "pinfo_aspect, 3'd1, pinfo_col_unsup," R35 "pics" &
  mut C9 $I "|| (d_hshow > 13'd576))" "|| (d_hshow >= 13'd576))" R35 "pics" &
  mut C10 h264/ring_words_sys.sv "w[31:29] = f_colour;" "w[31:29] = 3'd0;" R34 "final" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
