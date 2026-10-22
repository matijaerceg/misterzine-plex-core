// h264/aud_play.sv -- the audio path (roadmap Phase 4, interface 0.5; docs/architecture.md
// "Audio (Phase 4)"): AUDIO records' descriptors in, 48 kHz s16 stereo out, presented against
// the STC (paced) or against a queue target (LOW_LATENCY). clk_sys.
//
// THE RING IS THE BUFFER. h264/ring_rd.sv's parser pushes one descriptor per AUDIO record
// {index, length, PTS} and skips its payload; this module fetches the samples from the ring
// through ring_rd's engine when they are about to play, and tells ring_rd which record is the
// oldest it still needs (a_hold_*: the record being fetched, else the oldest queued) -- ring_rd
// publishes that as the read index, so the program cannot overwrite it. Once a record's words
// are in the sample FIFO (ring_rd's u_af, 256 words = 10.7 ms) the ring's copy is not needed.
//
// THE PIPE.
//   u_desc    the descriptors (sfifo, 256 + skid); at most AUD_MAX_RECORDS = 256 records are
//             queued (ad_room: q_rec < 256), so it never overflows.
//   fetch     pops a descriptor, pushes {PTS, length} to u_infl (the records whose words are in
//             flight, in order) and asks the engine for its words, eight at a time, only when
//             u_af has room for them: words asked (req_total) minus words taken (pop_total),
//             both counted HERE on clk_sys, reset by the PLL lock only (like u_af).
//   unpack    takes the words (u_af's PULL port) and extracts one stereo frame at a time into
//             the head sample (hs_*): a record starts on a fresh word, two frames a word, its
//             last word's upper half padding when its frame count is odd. Each frame gets its
//             time on the stream's timeline in eighth-ticks (1 frame = 15/8 ticks exactly): a
//             tagged record's first frame sets it, every frame after adds 15.
//   the gate  at the head sample (the FIFO's EXIT: MiSTer_DVD's lesson -- gating an elastic
//             buffer's entry does not set when its samples leave), below.
// AFTER ANY RESET (the stream's or the core's): `flushing` takes and drops every word still owed
// (pop_total catches up with req_total) before anything is fetched again, so a fetch in flight
// across a reset never plays in the next stream.
//
// THE TICK. 27 MHz / 48 kHz = 562.5: periods of 562 and 563 cycles alternate, exactly 48 kHz on
// the crystal the raster and the STC (clk_sys / 300) run from. Paused, the tick is withheld:
// nothing is consumed and the output is 0; resume continues from the same frame.
//
// THE GATE (G_ARM closed, G_PLAY open, G_DROP dropping late frames one a cycle, silent).
// Paced (ll low):
//   G_ARM   opens when the STC runs and the head is due (STC >= its time; a head with no time
//           -- untagged audio since the stream began -- when the STC runs); if it is already
//           more than SLIP late, G_DROP first. Waiting with a head while the STC does not run
//           asks for the AUDIO ANCHOR (aanc: disp_sched starts the STC at the head's time) at
//           once when the queue is full (the parser waits on it), else after AUD_WAIT.
//   G_PLAY  a tick plays the head. A tagged record's first frame is checked: more than SLIP
//           early -> G_ARM (silence until due, counted in n_gap); more than SLIP late ->
//           G_DROP (the late frames dropped, counted in n_late). No head at a tick: an
//           underrun -> G_ARM (the next head's time sets the phase again).
//   G_DROP  drops the head while it is late, then G_PLAY.
// Low latency (ll high):
//   G_ARM   opens when the queue holds LL_START frames.
//   G_PLAY  a tick plays the head. The queue's minimum -- the margin left before an underrun --
//           is kept between LL_MIN_LO and LL_MIN_HI: below, one frame is played twice; above,
//           one is dropped (counted). Decided every 2^LL_WIN_W frames played, on the minimum
//           over the last FOUR such windows: records arrive in steps, and a window shorter
//           than their spacing sees only part of the sawtooth, its minimum swinging from one
//           window to the next (aud_play_tb A6 / A7 slipped both ways on one window). At 1,024
//           frames: a decision every 21 ms on the last 85 ms, records up to ~60 ms, at most
//           ~1,000 ppm (ten times a crystal's error). Past LL_MAX (a burst) -> G_DROP down to
//           LL_START. An underrun -> G_ARM.
// The attenuation (aud_gain, Q1.15, 0 = exactly unity) is applied to the frame as it plays.
// THE LEAD (interface 1.1; docs/architecture.md "Queued audio: a late picture never runs the clock
// back over it"): aud_lead says the queued audio was written AHEAD of the clock -- it has waited for
// the STC (armed with a timed head not yet due, the clock running) or started it (the audio anchor)
// since it last ran dry (the queue empty) or arrived late (a late drop, G_DROP). While it
// is high disp_sched does not move the clock back to a late picture: the audio is right and the
// pictures are what is late (a transcode's audio 6 s ahead filled the queue, and each picture that
// still came re-anchored the clock back behind the waiting audio: a livelock, 2026-10-09). A stall
// clears it (the ring drains both streams, the audio runs dry or comes back late), so the stall's
// late picture re-anchors as before. Paced streams only; 0 in low latency.
//
// Quartus 17: no functions, no N'() casts; the FIFOs are sfifo (M10K, a synchronous read).

`default_nettype none

module aud_play #(
    parameter int SLIP_TICKS = 900,          // 10 ms: a tagged record this far off plays re-timed
    parameter int AUD_WAIT   = 27000000,     // 1 s of clk_sys: the audio anchor's wait
    parameter int LL_START   = 960,          // 20 ms of frames: low latency starts
    parameter int LL_MIN_LO  = 120,          // 2.5 ms: a smaller margin repeats a frame
    parameter int LL_MIN_HI  = 960,          // 20 ms: a larger margin drops one
    parameter int LL_MAX     = 12000,        // 250 ms: a burst, dropped down to LL_START
    parameter int LL_WIN_W   = 10,           // 2^10 = 1,024 frames a drift window
    parameter int SF_WORDS   = 256           // ring_rd's u_af depth
) (
    input  wire         clk,                 // clk_sys
    input  wire         rst_n,               // reset_n: the counters
    input  wire         srst_n,              // the per-stream reset (fe_rst_n): the queue, the gate
    input  wire         lrst_n,              // the PLL lock: the words asked / taken, the tick
    // the descriptors (ring_rd's parser)
    input  wire         ad_push,
    input  wire  [31:0] ad_pos,
    input  wire  [22:0] ad_len,
    input  wire  [32:0] ad_pts,
    input  wire         ad_ptsv,
    output logic        ad_room,
    output logic        a_hold_v,
    output logic [31:0] a_hold_idx,
    output logic        aud_idle,
    // the fetch (ring_rd's engine)
    output logic        af_go,
    output logic [31:0] af_addr,
    output logic  [3:0] af_n,
    input  wire         af_busy,
    input  wire  [63:0] af_dout,
    input  wire         af_valid,
    input  wire         af_empty,
    output logic        af_rd,
    // the clock
    input  wire  [32:0] stc,
    input  wire         stc_run,
    output logic        aanc,                // one cycle: start the STC at aanc_pts (sent only while !stc_run)
    output logic [32:0] aanc_pts,
    output logic        aud_lead,            // (1.1) the queued audio is ahead of the clock (THE LEAD, above)
    input  wire         ll,                  // the stream's LOW_LATENCY (its first VIDEO_AU; 0 before one)
    input  wire         pause,
    input  wire   [7:0] atten,
    // out
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    // the status (words 40-44)
    output logic  [1:0] st_state,            // 0 idle, 1 armed, 2 playing
    output logic  [8:0] q_rec,
    output logic [31:0] q_samples,
    output logic [31:0] n_played,
    output logic [31:0] n_records,
    output logic [31:0] n_gap,
    output logic [31:0] n_late,
    output logic [15:0] n_underruns,
    output logic [15:0] n_slip_drop,
    output logic [15:0] n_slip_rep,
    output logic [15:0] n_anchor,
    output logic [31:0] offset
);

    localparam logic [8:0]  MAXREC   = 9'd256;
    localparam logic [35:0] SLIP_Q3  = SLIP_TICKS * 8;
    localparam logic [31:0] LL_T     = LL_START;
    localparam logic [31:0] LL_HI    = LL_MIN_HI;
    localparam logic [31:0] LL_LO    = LL_MIN_LO;
    localparam logic [31:0] LL_M     = LL_MAX;
    localparam logic [24:0] AWAIT    = AUD_WAIT;
    localparam logic [16:0] SFW      = SF_WORDS;

    // ---------------------------------------------------------------- the 48 kHz tick
    logic [9:0] tcnt;
    logic       tphase, tick;
    always_ff @(posedge clk or negedge lrst_n)
        if (!lrst_n) begin tcnt <= '0; tphase <= 1'b0; tick <= 1'b0; end
        else begin
            tick <= 1'b0;
            if (tcnt == (tphase ? 10'd562 : 10'd561)) begin tcnt <= '0; tphase <= ~tphase; tick <= 1'b1; end
            else tcnt <= tcnt + 10'd1;
        end
    wire ptick = tick && !pause;

    // ---------------------------------------------------------------- words asked / taken
    logic [15:0] req_total, pop_total;
    always_ff @(posedge clk or negedge lrst_n)
        if (!lrst_n) begin req_total <= '0; pop_total <= '0; end
        else begin
            if (af_go) req_total <= req_total + {12'd0, af_n};
            if (af_rd) pop_total <= pop_total + 16'd1;
        end
    wire [15:0] owed = req_total - pop_total;

    // ---------------------------------------------------------------- the descriptors
    logic [88:0] d_dout;
    logic        d_valid, d_rd;
    logic [9:0]  d_count;
    sfifo #(.DW(89), .AW(8)) u_desc (
        .clk, .rst_n(srst_n), .din({ad_ptsv, ad_pts, ad_len, ad_pos}), .wr_en(ad_push), .full(),
        .dout(d_dout), .dout_valid(d_valid), .rd_en(d_rd), .count(d_count));
    wire [31:0] d_pos  = d_dout[31:0];
    wire [22:0] d_len  = d_dout[54:32];
    wire [32:0] d_pts  = d_dout[87:55];
    wire        d_ptsv = d_dout[88];

    // the records in flight: {PTS_VALID, PTS, length}
    logic [56:0] i_dout;
    logic        i_valid, i_rd, i_wr;
    logic [5:0]  i_count;
    sfifo #(.DW(57), .AW(4)) u_infl (
        .clk, .rst_n(srst_n), .din({d_ptsv, d_pts, d_len}), .wr_en(i_wr), .full(),
        .dout(i_dout), .dout_valid(i_valid), .rd_en(i_rd), .count(i_count));

    // ---------------------------------------------------------------- the fetch
    logic        flushing;                 // taking back the words owed after a reset
    logic        f_run;                    // a record is being fetched
    logic [31:0] f_pos, f_addr;
    logic [19:0] f_words;                  // words left to ask for (<= 2^22 / 8)
    wire  [3:0]  f_n = (f_words >= 20'd8) ? 4'd8 : f_words[3:0];
    assign d_rd = !f_run && !flushing && d_valid && (i_count < 6'd14);
    assign i_wr = d_rd;
    assign af_go   = f_run && !flushing && !af_busy && (({1'b0, owed} + {13'd0, f_n}) <= SFW);
    assign af_addr = f_addr;
    assign af_n    = f_n;
    // THE HOLD: the record being fetched, else the oldest queued. A pushed descriptor takes a
    // few cycles to reach u_desc's head (its RAM, then its skid), while `count` has it at once;
    // in that window the hold is h_pos -- the first record pushed into an empty queue, or the
    // last one taken for fetching (older than anything queued): conservative, never late. (A
    // hold that fell for those cycles let the parser's position, past a small record, become
    // the read index: found by aud_play_tb's [hold].)
    logic [31:0] h_pos;
    assign a_hold_v   = f_run || (d_count != 10'd0);
    assign a_hold_idx = f_run ? f_pos : d_valid ? d_pos : h_pos;
    always_ff @(posedge clk or negedge srst_n)
        if (!srst_n) h_pos <= '0;
        else if (d_rd) h_pos <= d_pos;
        else if (ad_push && !f_run && d_count == 10'd0) h_pos <= ad_pos;
    always_ff @(posedge clk or negedge srst_n)
        if (!srst_n) begin f_run <= 1'b0; f_pos <= '0; f_addr <= '0; f_words <= '0; end
        else if (d_rd) begin
            f_run <= 1'b1; f_pos <= d_pos; f_addr <= d_pos + 32'd16;
            f_words <= {d_len[22:3]} + {19'd0, (d_len[2:0] != 3'd0)};
        end else if (af_go) begin
            f_addr <= f_addr + {25'd0, af_n, 3'b000};
            f_words <= f_words - {16'd0, af_n};
            if (f_words == {16'd0, af_n}) f_run <= 1'b0;
        end

    // ---------------------------------------------------------------- the unpack
    logic        u_v, u_first, u_ptsv;
    logic [20:0] u_left;                   // frames left in the record (<= 2^20)
    logic [32:0] u_pts;
    logic        w_have, w_half, rd_pend;
    logic [63:0] w_data;
    logic        hs_v, hs_first, hs_tag, hs_last, hs_tv;
    logic [31:0] hs_s;                     // {R, L}
    logic [35:0] hs_t, tl;                 // the head's time, the next frame's (eighth-ticks)
    logic        tl_v;
    assign af_rd = !af_empty && !rd_pend && (flushing || (u_v && !w_have));
    assign i_rd  = !flushing && !u_v && i_valid;

    // ---------------------------------------------------------------- the gate
    typedef enum logic [1:0] { G_ARM, G_PLAY, G_DROP } gst_t;
    gst_t        gs;
    logic        gap_arm;                  // armed by an early record (its silence is counted)
    logic        drop1, rep1;              // low latency: a slip pending
    logic [LL_WIN_W-1:0] lw;               // frames played in the drift window
    logic [15:0] qmin, qh0, qh1, qh2;      // this window's minimum (saturated at 16 bits), the last three
    logic [1:0]  nwin;                     // windows completed since playing began (saturating at 3)
    wire  [15:0] q16 = (q_samples > 32'd65535) ? 16'hFFFF : q_samples[15:0];
    logic [15:0] m01, m23, m4;
    always_comb begin
        m01 = (qmin < qh0) ? qmin : qh0;
        m23 = (qh1 < qh2) ? qh1 : qh2;
        m4  = (m01 < m23) ? m01 : m23;
    end
    logic [24:0] anc_tmr;
    logic        anc_sent;
    logic        lead;                     // THE LEAD's state (aud_lead: gated by ll and the queue)
    logic [31:0] out_s;
    // events for the counters (reset_n): registered pulses
    logic ev_play, ev_rec, ev_gap, ev_late, ev_under, ev_sdrop, ev_srep, ev_anc, ev_off;
    logic [31:0] off_v;

    wire signed [35:0] late = $signed({stc, 3'b000} - hs_t);      // > 0: the head is late
    wire               due  = !late[35];                           // late >= 0
    wire               far_late  = (late > $signed(SLIP_Q3));
    wire               far_early = (late < -$signed(SLIP_Q3));

    always_ff @(posedge clk or negedge srst_n) begin : g_proc
        logic take;                        // the head is consumed this cycle (played or dropped)
        logic play;                        // ... and played at this tick
        logic silent;                      // a tick with nothing played
        if (!srst_n) begin
            flushing <= 1'b1;
            u_v <= 1'b0; u_first <= 1'b0; u_ptsv <= 1'b0; u_left <= '0; u_pts <= '0;
            w_have <= 1'b0; w_half <= 1'b0; rd_pend <= 1'b0; w_data <= '0;
            hs_v <= 1'b0; hs_first <= 1'b0; hs_tag <= 1'b0; hs_last <= 1'b0; hs_tv <= 1'b0; hs_s <= '0; hs_t <= '0;
            tl <= '0; tl_v <= 1'b0;
            gs <= G_ARM; gap_arm <= 1'b0; drop1 <= 1'b0; rep1 <= 1'b0; lw <= '0; qmin <= '1;
            qh0 <= '1; qh1 <= '1; qh2 <= '1; nwin <= '0;
            anc_tmr <= '0; anc_sent <= 1'b0; aanc <= 1'b0; aanc_pts <= '0; out_s <= '0; lead <= 1'b0; aud_lead <= 1'b0;
            q_rec <= '0; q_samples <= '0;
            ev_play <= 1'b0; ev_rec <= 1'b0; ev_gap <= 1'b0; ev_late <= 1'b0; ev_under <= 1'b0; ev_sdrop <= 1'b0; ev_srep <= 1'b0; ev_anc <= 1'b0;
            ev_off <= 1'b0; off_v <= '0;
        end else begin
            take = 1'b0; play = 1'b0; silent = 1'b0;
            ev_gap <= 1'b0; ev_late <= 1'b0; ev_under <= 1'b0; ev_sdrop <= 1'b0; ev_srep <= 1'b0; ev_anc <= 1'b0;
            ev_off <= 1'b0; aanc <= 1'b0;

            // ---- the words ----
            if (af_rd) rd_pend <= 1'b1;
            if (af_valid && rd_pend) begin
                rd_pend <= 1'b0;
                if (!flushing) begin w_data <= af_dout; w_have <= 1'b1; w_half <= 1'b0; end
            end
            if (flushing && owed == 16'd0 && !rd_pend) flushing <= 1'b0;

            // ---- the next record ----
            if (i_rd) begin
                u_v <= 1'b1; u_first <= 1'b1; u_ptsv <= i_dout[56]; u_pts <= i_dout[55:23];
                u_left <= i_dout[22:2];
            end

            // ---- the gate (reads the head as it stood at the cycle's start) ----
            case (gs)
                G_ARM: begin
                    if (ptick) silent = 1'b1;
                    if (hs_v && !pause) begin
                        if (ll) begin
                            if (ptick && q_samples >= LL_T) begin gs <= G_PLAY; take = 1'b1; play = 1'b1; silent = 1'b0; end
                        end else if (stc_run) begin
                            if (!hs_tv || due) begin
                                if (hs_tv && far_late) gs <= G_DROP;
                                else if (ptick) begin
                                    gs <= G_PLAY; take = 1'b1; play = 1'b1; silent = 1'b0; gap_arm <= 1'b0;
                                    if (hs_tag) begin ev_off <= 1'b1; off_v <= late[34:3]; end
                                end
                            end else if (ptick && gap_arm) ev_gap <= 1'b1;
                        end else if (!anc_sent && (anc_tmr == AWAIT || q_rec == MAXREC)) begin
                            aanc <= 1'b1; aanc_pts <= hs_tv ? hs_t[35:3] : 33'd0; anc_sent <= 1'b1; ev_anc <= 1'b1;
                        end
                    end
                end
                G_PLAY: begin
                    if (ptick) begin
                        if (!hs_v) begin
                            silent = 1'b1; ev_under <= 1'b1; gs <= G_ARM; gap_arm <= 1'b0;
                        end else if (!ll && hs_tag && far_early) begin
                            silent = 1'b1; ev_gap <= 1'b1; gs <= G_ARM; gap_arm <= 1'b1;
                        end else if (!ll && hs_tag && far_late) begin
                            silent = 1'b1; gs <= G_DROP;
                        end else if (ll && q_samples > LL_M) begin
                            silent = 1'b1; gs <= G_DROP;
                        end else begin
                            play = 1'b1;
                            if (!ll && hs_tag) begin ev_off <= 1'b1; off_v <= late[34:3]; end
                            if (ll && rep1) begin rep1 <= 1'b0; ev_srep <= 1'b1; end    // played twice
                            else take = 1'b1;
                        end
                    end else if (ll && drop1 && hs_v && !pause) begin
                        take = 1'b1; drop1 <= 1'b0; ev_sdrop <= 1'b1;             // one frame skipped
                    end
                end
                default: begin                                      // G_DROP
                    if (ptick) silent = 1'b1;
                    if (!pause) begin
                        if (hs_v) begin
                            if (ll ? (q_samples > LL_T) : (hs_tv && !late[35] && late != 36'sd0)) begin
                                take = 1'b1; ev_late <= 1'b1;
                            end else gs <= G_PLAY;
                        end else if (q_rec == 9'd0) gs <= G_ARM;
                    end
                end
            endcase

            // ---- THE LEAD: set by waiting ahead of the clock or starting it; cleared by running dry
            // or arriving late (the gate's state as it stood at the cycle's start, as the gate reads it).
            // Low latency is excluded at aud_lead alone (the stream's mode is fixed until its reset). Ran
            // dry = the queue empty (an underrun with records still queued is only a fetch behind)
            if (q_rec == 9'd0 ||                                                  // ran dry
                (gs == G_PLAY && ptick && hs_v && hs_tag && far_late) ||           // late: to G_DROP
                (gs == G_ARM && hs_v && !pause && stc_run && hs_tv && due && far_late))
                lead <= 1'b0;
            else if ((gs == G_ARM && hs_v && !pause && stc_run && hs_tv && !due) ||  // waiting for the clock
                     aanc)                                                          // the audio anchor (sent last cycle)
                lead <= 1'b1;
            aud_lead <= lead && !ll && q_rec != 9'd0;

            // ---- the anchor's wait (paced, armed with a head, the STC stopped) ----
            if (stc_run) anc_sent <= 1'b0;
            if (gs == G_ARM && hs_v && !ll && !stc_run && !pause) begin
                if (anc_tmr != AWAIT) anc_tmr <= anc_tmr + 25'd1;
            end else anc_tmr <= '0;

            // ---- low latency: the drift windows ----
            if (play && ll) begin
                lw <= lw + 1'b1;
                if (&lw) begin                                     // the window's last frame
                    if (nwin == 2'd3) begin                        // four windows seen: decide
                        if ({16'd0, m4} > LL_HI) drop1 <= 1'b1;
                        else if ({16'd0, m4} < LL_LO) rep1 <= 1'b1;
                    end else nwin <= nwin + 2'd1;
                    qh2 <= qh1; qh1 <= qh0; qh0 <= qmin;
                    qmin <= '1;
                end else if (q16 < qmin) qmin <= q16;
            end
            if (gs != G_PLAY) begin lw <= '0; qmin <= '1; qh0 <= '1; qh1 <= '1; qh2 <= '1; nwin <= '0; end

            // ---- the output frame (silent while paused: aud_play_tb A8 found it held) ----
            if (pause) out_s <= '0;
            else if (play) out_s <= hs_s;
            else if (silent) out_s <= '0;

            // ---- the head: consumed, then refilled from the word (a cycle later) ----
            if (take) hs_v <= 1'b0;
            else if (!hs_v && u_v && w_have && !flushing) begin
                hs_v <= 1'b1;
                hs_s <= w_half ? w_data[63:32] : w_data[31:0];
                hs_first <= u_first;
                hs_tag <= u_first && u_ptsv;
                hs_last <= (u_left == 21'd1);
                if (u_first && u_ptsv) begin hs_t <= {u_pts, 3'b000}; tl <= {u_pts, 3'b000} + 36'd15; hs_tv <= 1'b1; tl_v <= 1'b1; end
                else begin hs_t <= tl; tl <= tl + 36'd15; hs_tv <= tl_v; end
                u_first <= 1'b0;
                u_left <= u_left - 21'd1;
                if (w_half || u_left == 21'd1) begin w_have <= 1'b0; w_half <= 1'b0; end
                else w_half <= 1'b1;
                if (u_left == 21'd1) u_v <= 1'b0;
            end

            ev_play <= play;
            ev_rec  <= take && hs_last;

            // ---- the queue ----
            q_samples <= q_samples + (ad_push ? {11'd0, ad_len[22:2]} : 32'd0) - (take ? 32'd1 : 32'd0);
            q_rec <= q_rec + (ad_push ? 9'd1 : 9'd0) - ((take && hs_last) ? 9'd1 : 9'd0);
        end
    end

    assign ad_room  = (q_rec < MAXREC);
    assign aud_idle = (q_rec == 9'd0);
    assign st_state = (gs != G_ARM) ? 2'd2 : (q_rec != 9'd0) ? 2'd1 : 2'd0;

    // ---------------------------------------------------------------- the counters (reset_n)
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            n_played <= '0; n_records <= '0; n_gap <= '0; n_late <= '0; n_underruns <= '0;
            n_slip_drop <= '0; n_slip_rep <= '0; n_anchor <= '0; offset <= '0;
        end else begin
            if (ev_play)  n_played <= n_played + 32'd1;
            if (ev_rec)   n_records <= n_records + 32'd1;
            if (ev_gap)   n_gap <= n_gap + 32'd1;
            if (ev_late)  n_late <= n_late + 32'd1;
            if (ev_under && !(&n_underruns)) n_underruns <= n_underruns + 16'd1;
            if (ev_sdrop && !(&n_slip_drop)) n_slip_drop <= n_slip_drop + 16'd1;
            if (ev_srep && !(&n_slip_rep))   n_slip_rep <= n_slip_rep + 16'd1;
            if (ev_anc && !(&n_anchor))      n_anchor <= n_anchor + 16'd1;
            if (ev_off) offset <= off_v;
        end

    // ---------------------------------------------------------------- the attenuation
    logic [15:0] gain;
    aud_gain u_gain (.clk, .atten, .gain);
    logic signed [32:0] mul_l, mul_r;
    always_ff @(posedge clk) begin
        mul_l <= $signed(out_s[15:0]) * $signed({1'b0, gain});
        mul_r <= $signed(out_s[31:16]) * $signed({1'b0, gain});
        audio_l <= mul_l[30:15];
        audio_r <= mul_r[30:15];
    end

endmodule

`default_nettype wire
