// bench/h264/aud_play_tb.sv -- the audio path (h264/aud_play.sv, interface 0.5) against the
// design text (docs/architecture.md "Audio (Phase 4)"), not against its own RTL: every frame
// the bench queues carries a unique ID as its content (never 0: silence is told apart), and
// the bench knows each frame's time from the records it wrote (a tagged record's PTS, then
// 15/8 of a tick a frame). At every 48 kHz tick it reads the output, decodes which frame
// played, and checks it against the STC it runs itself (clk_sys / 300, anchored like a
// picture would, frozen by the pause like disp_sched's).
//
//   +arm=A1   paced: contiguous records (tagged and not), every frame played in order, on time
//   +arm=A2   paced: a gap (a record 100 ms after the audio before it): silence, then on time
//   +arm=A3   paced: an overlap (a record 50 ms early on the timeline): its late frames dropped
//   +arm=A4   paced: an underrun (the producer stops): counted, the next record on time
//   +arm=A5   paced: no picture -- the audio anchor after AUD_WAIT, at the head's PTS
//   +arm=A5Q  paced: no picture -- the anchor at once when 256 records wait
//   +arm=A6   low latency: the producer 2,500 ppm fast -- single frames dropped, the queue bounded
//   +arm=A7   low latency: the producer 2,500 ppm slow -- single frames repeated
//   +arm=A8   paced: the pause mid-play -- nothing consumed, the STC frozen, sync kept after
//   +arm=A9   paced: ATTEN 13 (-6.5 dB) -- every frame scaled (the gain computed here from dB)
//   +arm=A10  a stream reset while a fetch is in flight: nothing of the old stream plays after
//   +arm=A11  paced: the clock starts 100 ms after the audio's first frame (the picture came
//             later): the late frames dropped before the gate opens, then every frame on time
//   +arm=A12  (1.1) paced: A1's start (the audio waits 10 ms for the clock), then an overlap (a record
//             50 ms early on the timeline): its late frames dropped, and the lead with them
//   +arm=A13  (1.1) paced: a run that waited for the clock runs dry (an underrun), then untagged audio
//             on the timeline: played at once, the lead not back
// THE LEAD (1.1, aud_lead; docs/architecture.md "Queued audio: a late picture never runs the clock back
// over it") is scored on every frame played, from what the bench saw happen: high once the audio
// waited for the running clock (A1) or started it (A5Q), low after an underrun or a late drop until it
// waits again (A12, A13), never when it never waited (A11) or in low latency (A6, with a running clock
// and records ahead of it so the gate's own terms are exercised).
//
// Checks (each FAIL names its arm): [order] a frame out of order or repeated (a repeat is
// allowed only as a counted low-latency slip); [sync] a paced frame more than 3 ticks off
// the STC; [complete] a frame neither played nor dropped, or a count at the end differs from
// what the bench observed; [hold] a_hold_idx not the oldest record not wholly asked for;
// [credit] the sample FIFO asked past its 256 words; [fetch] a request outside the record
// being fetched, or out of order; [rate] the tick not exactly 48 kHz; [anchor] the anchor
// wrong, missing or sent while the STC runs; [pause] a frame played or taken while paused;
// [atten] a scaled frame differs; [flush] a frame of the old stream after the reset; [ll] the
// low-latency queue unbounded or the slip in the wrong direction; [lead] aud_lead not as THE LEAD above
// says; [hang] the run never ended.
// Scoring with !==; PASS: aud_play_tb is printed only when every check held.

`timescale 1ns/1ps
`default_nettype none

module aud_play_tb;

    // shrunk from the core's to keep the arms short: the anchor's wait (1 s), the drift window
    // (1,024 frames; 256 here: four of them span 21 ms, two 10 ms records; up to 3,900 ppm),
    // the margin's band (2.5-20 ms; here 8.3-11.7 ms around the ~10 ms a 20 ms start leaves
    // with 10 ms records)
    localparam int AUD_WAIT = 20000;
    localparam int LL_WIN_W = 8;
    localparam int LL_MIN_LO = 400, LL_MIN_HI = 560;

    logic clk = 0;
    always #18.5 clk = ~clk;                   // clk_sys, 27 MHz
    logic rst_n = 0, srst_n = 0, lrst_n = 0;

    string arm;
    int arm_n;
    int fails = 0;
    task automatic fail(input string label, input string msg);
        $display("FAIL [%s] %s: %s", label, arm, msg);
        fails++;
        if (fails > 8) $fatal(1);
    endtask

    // ---- the DUT ----
    logic        ad_push = 0, ad_ptsv = 0, ad_room;
    logic [31:0] ad_pos = 0;  logic [22:0] ad_len = 0;  logic [32:0] ad_pts = 0;
    logic        a_hold_v, aud_idle;  logic [31:0] a_hold_idx;
    logic        af_go, af_busy, af_valid, af_empty, af_rd;
    logic [31:0] af_addr;  logic [3:0] af_n;  logic [63:0] af_dout;
    logic [32:0] stc = 0;  logic stc_run = 0;
    logic        aanc;  logic [32:0] aanc_pts;  logic aud_lead;
    logic        ll = 0, pause = 0;  logic [7:0] atten = 0;
    logic signed [15:0] audio_l, audio_r;
    logic [1:0]  st_state;  logic [8:0] q_rec;  logic [31:0] q_samples;
    logic [31:0] n_played, n_records, n_gap, n_late, offset;
    logic [15:0] n_underruns, n_slip_drop, n_slip_rep, n_anchor;

    aud_play #(.AUD_WAIT(AUD_WAIT), .LL_WIN_W(LL_WIN_W), .LL_MIN_LO(LL_MIN_LO), .LL_MIN_HI(LL_MIN_HI)) dut (
        .clk, .rst_n, .srst_n, .lrst_n,
        .ad_push, .ad_pos, .ad_len, .ad_pts, .ad_ptsv, .ad_room, .a_hold_v, .a_hold_idx, .aud_idle,
        .af_go, .af_addr, .af_n, .af_busy, .af_dout, .af_valid, .af_empty, .af_rd,
        .stc, .stc_run, .aanc, .aanc_pts, .aud_lead, .ll, .pause, .atten,
        .audio_l, .audio_r,
        .st_state, .q_rec, .q_samples, .n_played, .n_records, .n_gap, .n_late,
        .n_underruns, .n_slip_drop, .n_slip_rep, .n_anchor, .offset);

    // ---- the records the bench queued: the ring (free-running byte index -> word), each
    // frame's ID, and its time on the timeline (eighth-ticks; -1: no timeline yet) ----
    localparam longint WBASE = 64'h0000_0000_FFFF_F000 >> 3;   // the ring's first word here
    logic [63:0] ring [0:(1<<18)-1];           // words from WBASE (2 MB: every arm fits)
    int          rec_n = 0;                    // records queued
    longint      rec_pos [0:8191];
    int          rec_frames [0:8191];
    int          rec_first [0:8191];           // the ID of its first frame
    longint      rec_words_asked [0:8191];     // words of it asked for (the [fetch] / [hold] checks)
    int          nid = 1;                      // the next frame ID (0 is silence)
    longint      ftime [0:(1<<17)-1];          // ID -> time (eighth-ticks); -1: not on a timeline
    longint      tl = -1;                      // the timeline's next frame (the producer's view)
    longint      wpos = 64'h0000_0000_FFFF_F000;   // the next record's index (crosses 2^32: the u32 wrap)
    int          stream_first_id = 1;          // A10: the new stream's first ID

    function automatic logic [31:0] content(input int id);
        return (arm == "A9") ? {~id[15:0], id[15:0] ^ 16'h5A5A} : id;   // A9: signed values of both signs
    endfunction

    task automatic queue_record(input int frames, input bit tg, input longint pts);
        longint p;
        int k;
        p = wpos;
        if (tg) tl = pts * 8;
        for (k = 0; k < frames; k++) begin
            logic [31:0] c;  longint wi;  logic [63:0] w;
            c = content(nid + k);
            wi = ((p + 16 + 4 * k) >> 3) - WBASE;
            w = (k % 2 == 0) ? 64'd0 : ring[wi];
            if (k % 2 == 0) w[31:0] = c; else w[63:32] = c;
            ring[wi] = w;
            if (tl >= 0) begin ftime[nid + k] = tl; tl = tl + 15; end
            else ftime[nid + k] = -1;
        end
        rec_pos[rec_n] = p; rec_frames[rec_n] = frames; rec_first[rec_n] = nid; rec_words_asked[rec_n] = 0;
        while (!ad_room) @(posedge clk);
        ad_push <= 1; ad_pos <= p[31:0]; ad_len <= 23'(4 * frames); ad_ptsv <= tg; ad_pts <= tg ? pts[32:0] : 33'd0;
        @(posedge clk);
        ad_push <= 0;
        rec_n++; nid += frames;
        wpos = p + 16 + ((4 * frames + 15) / 16) * 16 + 16 * $urandom_range(0, 3);   // video records between
    endtask

    // ---- the engine: requests served after a random latency into the sample FIFO (its read
    // port PULL: dout / valid the cycle after rd; `empty` two cycles pessimistic like fifo_dc) ----
    logic [63:0] sfq [0:1023];                 // a circular buffer (iverilog's queues trip assertions here)
    int          sfq_h = 0, sfq_n = 0;
    int          lat = 0, pend_n = 0;  longint pend_a;
    logic        busy_q = 0;
    int          fetch_rec = 0;                // the record the requests must be walking
    longint      fetch_next = -1;              // the index the next request must start at
    int          empty_hold = 0;
    assign af_busy  = busy_q;
    assign af_empty = (sfq_n == 0) || (empty_hold != 0);
    always @(posedge clk) begin
        af_valid <= 1'b0;
        if (empty_hold) empty_hold <= empty_hold - 1;
        if (af_rd) begin
            if (sfq_n == 0) fail("credit", "read from an empty sample FIFO");
            else begin af_dout <= sfq[sfq_h]; af_valid <= 1'b1; sfq_h = (sfq_h + 1) % 1024; sfq_n--; end
        end
        if (af_go && !busy_q && lrst_n) begin
            // [fetch]: inside the record being fetched, in order
            if (fetch_next < 0 || af_addr !== fetch_next[31:0]) begin
                // a new record starts: it must be the next one queued, at its payload
                if (fetch_rec >= rec_n || af_addr !== (rec_pos[fetch_rec][31:0] + 32'd16) || rec_words_asked[fetch_rec] != 0)
                    fail("fetch", $sformatf("request at %h: not record %0d's payload (%h)", af_addr, fetch_rec,
                         rec_pos[fetch_rec] + 16));
            end
            if (af_n == 0 || af_n > 8 || af_addr[2:0] != 0) fail("fetch", $sformatf("request of %0d words at %h", af_n, af_addr));
            rec_words_asked[fetch_rec] += af_n;
            if (rec_words_asked[fetch_rec] > (rec_frames[fetch_rec] + 1) / 2)
                fail("fetch", $sformatf("record %0d: %0d words asked, it has %0d", fetch_rec, rec_words_asked[fetch_rec],
                     (rec_frames[fetch_rec] + 1) / 2));
            if (rec_words_asked[fetch_rec] == (rec_frames[fetch_rec] + 1) / 2) begin fetch_rec++; fetch_next = -1; end
            else fetch_next = {32'd0, af_addr} + 8 * af_n;
            busy_q <= 1'b1; pend_a = {32'd0, af_addr}; pend_n = af_n; lat = $urandom_range(3, 60);
        end else if (busy_q) begin
            if (lat > 0) lat--;
            else if (pend_n > 0) begin
                longint wi;
                wi = ((wpos & ~64'hFFFF_FFFF) | pend_a);           // the free-running index behind the u32 address
                if (wi > wpos) wi -= 64'h1_0000_0000;
                sfq[(sfq_h + sfq_n) % 1024] = ring[(wi >> 3) - WBASE]; sfq_n++;
                if (sfq_n > 256) fail("credit", $sformatf("%0d words in the 256-word sample FIFO", sfq_n));
                empty_hold <= 2;
                pend_a += 8; pend_n--;
            end else if ($urandom_range(0, 3) == 0) busy_q <= 1'b0;   // the ack, two flops later
        end
    end

    // ---- [hold]: whenever a record is queued and not wholly asked for, the hold is up and at
    // or before the oldest such record -- and not before the one before it (an index held too
    // far back is safe, but a stuck one is a defect too). At the negedge: the bench's own
    // bookkeeping (rec_n, fetch_rec) moves at the posedge ----
    always @(negedge clk) if (srst_n && !dut.flushing) begin
        int r;  longint lo;
        r = fetch_rec;
        if (r < rec_n) begin
            lo = (r > 0) ? rec_pos[r - 1] : rec_pos[r];
            if (!a_hold_v || ($signed(rec_pos[r][31:0] - a_hold_idx) < 0) || ($signed(a_hold_idx - lo[31:0]) < 0))
                fail("hold", $sformatf("hold %b %h, the oldest record not wholly asked for is %0d at %h", a_hold_v, a_hold_idx, r, rec_pos[r][31:0]));
        end
    end

    // ---- the STC: clk_sys / 300 while it runs and not paused; anchored by the bench (a
    // picture) or by the audio anchor ----
    int sdiv = 0;
    int anc_seen = 0;  logic [32:0] anc_got;
    always @(posedge clk) begin
        if (stc_run && !pause) begin
            if (sdiv == 299) begin sdiv <= 0; stc <= stc + 1; end else sdiv <= sdiv + 1;
        end
        if (aanc) begin
            if (stc_run) fail("anchor", "the anchor sent while the STC runs");
            anc_seen++; anc_got = aanc_pts;
            stc <= aanc_pts; stc_run <= 1'b1; sdiv <= 0;
        end
    end
    task automatic anchor_stc(input longint at);
        stc <= at[32:0]; stc_run <= 1'b1; sdiv <= 0;
    endtask

    // ---- the monitor: each tick, which frame played ----
    int     played = 0, silence = 0, dropped = 0, reps = 0, last_id = 0, first_played = 0;
    longint off_max = 0;
    int     gap_ticks = 0;
    logic [15:0] slip_d, slip_r;
    bit     in_pause_check = 0;
    int     q_max = 0;
    int     lead_hi = 0, lead_lo = 0, lead_hi_from = 0;   // [lead]: frames played with aud_lead high / low,
    int     lead_mark = 1 << 30;                           // and high from frame lead_mark on
    always @(posedge clk) begin
        if (dut.tick && srst_n) begin
            logic [32:0] s;  int id;  logic ld;
            s = stc;
            ld = aud_lead;                         // [lead] as the frame was taken (the last take empties the queue)
            repeat (3) @(posedge clk);             // out_s, the multiply, audio_l / audio_r
            if (arm == "A9") begin
                if ({audio_r, audio_l} !== 32'd0) begin
                    // the k-th frame played must be frame k scaled (no drops in A9)
                    int k;  logic [31:0] c;  real g;  logic signed [15:0] el, er;
                    k = last_id + 1; c = content(k);
                    g = $floor(32768.0 * (10.0 ** (-13.0 / 40.0)) + 0.5);
                    el = $rtoi($floor($itor($signed(c[15:0])) * g / 32768.0));
                    er = $rtoi($floor($itor($signed(c[31:16])) * g / 32768.0));
                    if (audio_l !== el || audio_r !== er)
                        fail("atten", $sformatf("frame %0d: %0d / %0d, want %0d / %0d", k, audio_l, audio_r, el, er));
                    last_id = k; played++;
                    if (ld) lead_hi++; else lead_lo++;
                end else silence++;
            end else begin
                id = {audio_r, audio_l};
                if (id == 0) silence++;
                else begin
                    if (in_pause_check) fail("pause", $sformatf("frame %0d played while paused", id));
                    if (first_played == 0) first_played = id;
                    if (id == last_id && ll) reps++;
                    else if (id <= last_id) fail("order", $sformatf("frame %0d after %0d", id, last_id));
                    else dropped += id - last_id - 1 - ((last_id == 0) ? (stream_first_id - 1) : 0);
                    last_id = id; played++;
                    if (ld) lead_hi++; else lead_lo++;
                    if (ld && id >= lead_mark) lead_hi_from++;
                    if (!ll && ftime[id] >= 0) begin
                        longint e;
                        e = {s, 3'b000};
                        e = e - ftime[id];
                        if (e > off_max || -e > off_max) off_max = (e < 0) ? -e : e;
                        if (e > 24 || e < -24) fail("sync", $sformatf("frame %0d at STC %0d: %0d eighth-ticks off", id, s, e));
                    end
                end
            end
        end
        if (ll && q_samples > q_max) q_max = q_samples;
    end

    // ---- [rate]: the tick is exactly 48 kHz of 27 MHz (two ticks each 1,125 cycles), counted
    // in windows from the first tick ----
    int tcount = 0, tcyc = 0;
    bit tstart = 0;
    always @(posedge clk) if (lrst_n && (tstart || dut.tick)) begin
        tstart = 1;
        tcyc++;
        if (dut.tick) tcount++;
        if (tcyc == 1125 * 64) begin
            if (tcount != 128) fail("rate", $sformatf("%0d ticks in %0d cycles, want 128", tcount, tcyc));
            tcyc = 0; tcount = 0;
        end
    end

    task automatic wait_played(input int id, input int limit);
        int n;
        n = 0;
        while (last_id < id) begin
            @(posedge clk); n++;
            if (n > limit) begin fail("hang", $sformatf("frame %0d never played (last %0d, state %0d q %0d)", id, last_id, st_state, q_rec)); $fatal(1); end
        end
    endtask
    task automatic wait_idle(input int limit);
        int n;
        n = 0;
        while (!aud_idle) begin
            @(posedge clk); n++;
            if (n > limit) begin fail("hang", $sformatf("never idle (last %0d, state %0d q %0d)", last_id, st_state, q_rec)); $fatal(1); end
        end
        repeat (1200) @(posedge clk);
    endtask

    // =========================================================== the arms
    initial begin
        longint t0;
        int total;
        if (!$value$plusargs("arm=%s", arm)) arm = "A1";
        repeat (5) @(posedge clk);
        lrst_n = 1; rst_n = 1; srst_n = 1;
        repeat (20) @(posedge clk);
        t0 = 90000 + $urandom_range(0, 9000);
        // (a case on the string itself trips an iverilog code-generation assertion)
        arm_n = (arm == "A1" || arm == "A9") ? 0 : (arm == "A2" || arm == "A3") ? 1 : (arm == "A4") ? 2 :
                (arm == "A5" || arm == "A5Q") ? 3 : (arm == "A6" || arm == "A7") ? 4 : (arm == "A8") ? 5 :
                (arm == "A10") ? 6 : (arm == "A11") ? 7 : (arm == "A12") ? 8 : (arm == "A13") ? 9 : -1;
        case (arm_n)
            0: begin   // A1, A9
                if (arm == "A9") atten = 8'd13;
                for (int r = 0; r < 40; r++)
                    queue_record($urandom_range(1, 700), r == 0 || r % 3 != 1, t0 + (nid - 1) * 15 / 8);
                repeat (500) @(posedge clk);
                anchor_stc(t0 - 900);               // the first picture, 10 ms before the audio
                wait_played(nid - 1, 40_000_000);
                wait_idle(100000);
                total = nid - 1;
                if (played != total) fail("complete", $sformatf("%0d of %0d frames played", played, total));
                if (n_underruns != 16'd1) fail("complete", $sformatf("n_underruns %0d, want 1 (the audio's end)", n_underruns));
            end
            1: begin   // A2, A3
                for (int r = 0; r < 8; r++) queue_record($urandom_range(200, 600), 1, t0 + (nid - 1) * 15 / 8);
                // the next record's PTS: 100 ms after (A2: a gap) or 50 ms before (A3: an overlap) continuity
                queue_record(3000, 1, t0 + (nid - 1) * 15 / 8 + ((arm == "A2") ? 9000 : -4500));
                for (int r = 0; r < 4; r++) queue_record($urandom_range(200, 600), 0, 0);
                repeat (500) @(posedge clk);
                anchor_stc(t0);
                wait_played(nid - 1, 60_000_000);
                wait_idle(100000);
                total = nid - 1;
                if (arm == "A2") begin
                    if (n_gap < 32'd4700 || n_gap > 32'd4900) fail("complete", $sformatf("n_gap %0d, want ~4,800 ticks of silence", n_gap));
                    if (played != total || n_late != 0) fail("complete", $sformatf("%0d of %0d played, %0d dropped", played, total, n_late));
                end else begin
                    // 2,400 frames of overlap, plus the STC's advance while they drop (a frame every
                    // two cycles: ~16 ticks, ~9 frames)
                    if (n_late < 32'd2395 || n_late > 32'd2420) fail("complete", $sformatf("n_late %0d, want ~2,410 frames", n_late));
                    if (dropped != n_late || played + dropped != total)
                        fail("complete", $sformatf("played %0d + dropped %0d (counted %0d) of %0d", played, dropped, n_late, total));
                end
            end
            2: begin   // A4
                for (int r = 0; r < 6; r++) queue_record($urandom_range(200, 400), 1, t0 + (nid - 1) * 15 / 8);
                anchor_stc(t0);
                wait_idle(40_000_000);             // it ran dry: an underrun
                repeat (20000) @(posedge clk);
                // the next audio, tagged 22 ms ahead of the clock, then continuing untagged
                for (int r = 0; r < 4; r++) queue_record($urandom_range(200, 400), r == 0, stc + 2000);
                wait_played(nid - 1, 40_000_000);
                wait_idle(100000);
                // the first run's end and the second's (the end of the audio is an underrun too)
                if (n_underruns != 16'd2) fail("complete", $sformatf("n_underruns %0d, want 2", n_underruns));
                if (played != nid - 1) fail("complete", $sformatf("%0d of %0d played", played, nid - 1));
            end
            3: begin   // A5, A5Q
                if (arm == "A5")
                    for (int r = 0; r < 20; r++) queue_record($urandom_range(100, 300), 1, t0 + (nid - 1) * 15 / 8);
                else
                    for (int r = 0; r < 256; r++) queue_record(1, r == 0, t0);
                if (arm == "A5Q") begin
                    repeat (200) @(posedge clk);
                    if (anc_seen != 1) fail("anchor", "256 records waiting and no anchor at once");
                end
                wait_played(nid - 1, 60_000_000);
                wait_idle(100000);
                if (anc_seen != 1 || anc_got !== t0[32:0] || n_anchor != 16'd1)
                    fail("anchor", $sformatf("%0d anchors at %0d (counted %0d), want 1 at %0d", anc_seen, anc_got, n_anchor, t0));
                if (played != nid - 1) fail("complete", $sformatf("%0d of %0d played", played, nid - 1));
            end
            4: begin   // A6, A7
                // records of 10 ms (480 frames) every 480 x 562.5 x (1 -/+ 2,500 ppm) cycles
                real per;
                ll = 1;
                anchor_stc(0);                     // (1.1) a running clock, the records ahead of it: [lead]
                per = 480.0 * 562.5 * ((arm == "A6") ? (1.0 - 0.0025) : (1.0 + 0.0025));
                for (int r = 0; r < 200; r++) begin
                    queue_record(480, 1, 90000 + r * 900);
                    repeat ($rtoi(per) - 1) @(posedge clk);
                end
                // the direction is scored while the producer runs: once it stops, the queue
                // drains and its margin falls through the band before the last underrun
                slip_d = n_slip_drop; slip_r = n_slip_rep;
                wait_idle(40_000_000);
                total = nid - 1;
                // 2 s at 2,500 ppm is ~240 frames of drift; the first ~80 only move the margin
                // across its band
                if (arm == "A6" && (slip_d < 16'd100 || slip_r != 0))
                    fail("ll", $sformatf("fast producer: %0d drops, %0d repeats (want ~160 drops)", slip_d, slip_r));
                if (arm == "A7" && (slip_r < 16'd100 || slip_d != 0))
                    fail("ll", $sformatf("slow producer: %0d repeats, %0d drops (want ~160 repeats)", slip_r, slip_d));
                if (q_max > LL_MIN_HI + 480 + 256) fail("ll", $sformatf("the queue reached %0d frames", q_max));
                if (n_underruns != 16'd1) fail("ll", $sformatf("n_underruns %0d, want 1 (the audio's end)", n_underruns));
                if (played != total - n_slip_drop + reps || reps != n_slip_rep || dropped != n_slip_drop)
                    fail("complete", $sformatf("played %0d (%0d repeats), dropped %0d, counted %0d / %0d of %0d",
                         played, reps, dropped, n_slip_drop, n_slip_rep, total));
            end
            5: begin   // A8
                int frozen_id, taken;
                for (int r = 0; r < 20; r++) queue_record($urandom_range(200, 600), 1, t0 + (nid - 1) * 15 / 8);
                anchor_stc(t0);
                wait_played(nid / 3, 40_000_000);
                pause = 1;
                repeat (6) @(posedge clk);
                in_pause_check = 1; frozen_id = last_id; taken = q_samples;
                repeat (300000) @(posedge clk);
                if (q_samples != taken) fail("pause", $sformatf("%0d frames taken while paused", taken - q_samples));
                in_pause_check = 0; pause = 0;
                wait_played(nid - 1, 60_000_000);
                wait_idle(100000);
                if (played != nid - 1) fail("complete", $sformatf("%0d of %0d played", played, nid - 1));
            end
            6: begin   // A10
                for (int r = 0; r < 30; r++) queue_record($urandom_range(300, 700), 1, t0 + (nid - 1) * 15 / 8);
                anchor_stc(t0);
                wait_played(200, 40_000_000);
                @(posedge af_go);                    // a fetch in flight
                @(negedge clk); srst_n = 0; stc_run = 0;
                fetch_rec = rec_n; fetch_next = -1;  // the new stream's records start here
                repeat (4) @(posedge clk); srst_n = 1;
                stream_first_id = nid; last_id = 0; first_played = 0; played = 0; tl = -1;
                t0 = 400000;
                for (int r = 0; r < 6; r++) queue_record($urandom_range(300, 700), 1, t0 + (nid - stream_first_id) * 15 / 8);
                anchor_stc(t0);
                wait_played(nid - 1, 40_000_000);
                wait_idle(100000);
                if (first_played != stream_first_id)
                    fail("flush", $sformatf("the first frame after the reset was %0d, the new stream's first is %0d", first_played, stream_first_id));
                if (played != nid - stream_first_id) fail("complete", $sformatf("%0d of %0d played after the reset", played, nid - stream_first_id));
            end
            7: begin   // A11
                for (int r = 0; r < 20; r++) queue_record($urandom_range(200, 600), 1, t0 + (nid - 1) * 15 / 8);
                repeat (500) @(posedge clk);
                anchor_stc(t0 + 9000);              // the first picture, 100 ms after the audio's start
                wait_played(nid - 1, 40_000_000);
                wait_idle(100000);
                total = nid - 1;
                // 4,800 frames before the clock, plus its advance while ~9,700 cycles of dropping
                // run (~32 ticks, ~17 frames)
                if (n_late < 32'd4795 || n_late > 32'd4840) fail("complete", $sformatf("n_late %0d, want ~4,820 frames", n_late));
                if (dropped != n_late || played + dropped != total)
                    fail("complete", $sformatf("played %0d + dropped %0d (counted %0d) of %0d", played, dropped, n_late, total));
            end
            8: begin   // A12
                for (int r = 0; r < 8; r++) queue_record($urandom_range(200, 600), 1, t0 + (nid - 1) * 15 / 8);
                lead_mark = nid;                    // the overlap's first frame
                queue_record(3000, 1, t0 + (nid - 1) * 15 / 8 - 4500);
                for (int r = 0; r < 4; r++) queue_record($urandom_range(200, 600), 0, 0);
                repeat (500) @(posedge clk);
                anchor_stc(t0 - 900);               // the audio waits 10 ms for the clock: the lead
                wait_played(nid - 1, 60_000_000);
                wait_idle(100000);
                if (lead_hi == 0) fail("lead", "never high although the audio waited for the clock");
                if (lead_hi_from != 0) fail("lead", $sformatf("%0d frames after the late drop played with it high", lead_hi_from));
                if (played + dropped != nid - 1) fail("complete", $sformatf("played %0d + dropped %0d of %0d", played, dropped, nid - 1));
            end
            9: begin   // A13
                for (int r = 0; r < 6; r++) queue_record($urandom_range(200, 400), 1, t0 + (nid - 1) * 15 / 8);
                anchor_stc(t0 - 900);               // waits for the clock: the lead
                wait_idle(40_000_000);              // ran dry: an underrun
                if (aud_lead !== 1'b0) fail("lead", "high with the queue empty");
                if (lead_hi == 0) fail("lead", "never high although the audio waited for the clock");
                repeat (20000) @(posedge clk);
                lead_mark = nid;
                // on the old timeline, untagged: ~70 ticks past it now, inside SLIP -- played at once, neither
                // waited for nor dropped (their [sync] not scored: the bench's timeline is not the gate's here)
                tl = -1;
                for (int r = 0; r < 4; r++) queue_record($urandom_range(200, 400), 0, 0);
                wait_played(nid - 1, 40_000_000);
                wait_idle(100000);
                if (lead_hi_from != 0) fail("lead", $sformatf("%0d frames after the underrun played with it high", lead_hi_from));
                if (played != nid - 1) fail("complete", $sformatf("%0d of %0d played", played, nid - 1));
            end
            default: begin $display("FAIL [harness] unknown arm %s", arm); $fatal(1); end
        endcase
        // [lead] where the arm's whole story says it
        if ((arm == "A1" || arm == "A5Q") && lead_lo != 0)
            fail("lead", $sformatf("%0d frames played with it low (of %0d) although the audio waited or anchored", lead_lo, played));
        if ((arm == "A11" || arm == "A6" || arm == "A7") && lead_hi != 0)
            fail("lead", $sformatf("%0d frames played with it high (of %0d): the audio never waited%s", lead_hi, played, ll ? " (low latency)" : ""));
        if (arm != "A6" && arm != "A7" && arm != "A3" && arm != "A11" && arm != "A12" && dropped != 0) fail("complete", $sformatf("%0d frames skipped", dropped));
        if (arm != "A10" && n_played != played) fail("complete", $sformatf("n_played %0d, the bench saw %0d", n_played, played));
        $display("aud_play_tb: %s %0d frames played, %0d silent ticks, %0d dropped, gap %0d late %0d under %0d slips %0d/%0d anchor %0d, worst sync %0d/8 tick",
                 arm, played, silence, dropped, n_gap, n_late, n_underruns, n_slip_drop, n_slip_rep, n_anchor, off_max);
        if (fails == 0) $display("PASS: aud_play_tb %s", arm);
        else $fatal(1);
        $finish;
    end

    initial begin
        #4s; $display("FAIL [hang] %s: the run never finished", arm); $fatal(1);
    end
endmodule

`default_nettype wire
