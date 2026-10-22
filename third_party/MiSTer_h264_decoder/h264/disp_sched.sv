// h264/disp_sched.sv -- the display scheduler's timeline (roadmap P5e, docs/display.md S7):
// a free-running 90 kHz STC, anchored to the pictures' PTS, and at every refresh the
// decision whether the picture at the head of the output queue is due.
//
// HARVESTED from MiSTer_DVD dvd/disp_sched.sv (docs/harvest.md), with surgery. KEPT, with
// the reasons its notes give: the STC runs from the same crystal as the raster (rate is
// locked by construction; this module owns PHASE); a picture is due when STC >= want -
// half a refresh (the opportunity grid); a TAGGED picture more than one frame behind the
// timeline, more than FWD_MAX ahead or more than LATE_MAX late re-anchors; LATENESS IS NOT
// A DISCONTINUITY (a late picture is shown at once -- the DVD's HW round B defect was
// re-anchoring on it). DROPPED, each with its reason:
//   prov_* (a provisional parse-front anchor): only audio priming needed it -- P6
//   skip_* / defer_q3 (the governor's drops): no frame dropping until P6
//   pause / frame step: no transport until P6
//   cc_credit: no captions
//   disp_anchored / anchor_disc / anchor_delta: audio's qualifiers -- P6 brings them back
//   catchup_late (drop to discharge lateness at the maximum display rate): on the 480p
//     59.94 raster every census content class has >= 2 refreshes a store (24p 2.5, 3:2
//     2 / 3, 29.97 pairs 2), so an overdue queue drains at one store a refresh and the
//     display is never at its maximum rate. The exception, a stream of single 59.94
//     fields (1 tick each), is not in the census: a starve there recovers only at
//     LATE_MAX (docs/display.md S7, reference/compatibility.md).
//   frame_rate_code / MPEG-2 flags: the duration arrives in Q3 (dur_q3) from disp_ctl,
//     Table E-6's DeltaTfiDivisor times the VUI tick.
//   the DVD's "bookkeeping reads the live picbuf outputs" rule: recon_out's rec_* are
//     REGISTERED and cannot move until the take, so the pickup reads what was evaluated.
// LOW LATENCY (roadmap P3f; the HPS interface's LOW_LATENCY flag, a game stream): `ll`
// makes a head due at every refresh whatever its PTS -- the picture is shown as soon as it
// is decoded -- while the STC still anchors and runs (the audio's clock, Phase 4); `late`
// means nothing without pacing and is suppressed at its register. (disp_ctl skips a head a
// newer picture waits behind: a 60.00 source on the 59.94 raster never queues.)
// THE AUDIO ANCHOR (Phase 4, interface 0.5; docs/architecture.md "Audio (Phase 4)"): when the
// stream has audio and no picture has started the clock, h264/aud_play.sv may start it
// (ext_anc: the STC set to ext_pts, anchored, no timeline yet) -- else queued audio, holding
// the ring's read index, could wedge a program that cannot write the video behind it. The first
// picture after it is SCHEDULED against the running clock, not anchored on it, unless it is
// more than FWD_MAX ahead of the STC or LATE_MAX behind it (the bounds a later picture has).
// THE AUDIO'S LEAD (interface 1.1; docs/architecture.md "Queued audio: a late picture never runs the
// clock back over it"): while `aud_lead` is high (h264/aud_play.sv: the queued audio was written ahead of
// the clock and has neither run dry nor arrived late since), a picture's LATENESS does not anchor -- the
// LATE_MAX leg drops out of `disc` and of `far`; the picture is shown at once, late, as any late picture.
// The timeline's legs (a picture behind the timeline, a jump past FWD_MAX, FWD_MAX ahead of an
// audio-started clock) keep anchoring. Moving the clock back behind waiting audio is what fed the
// 2026-10-09 livelock: the audio, early again, held the parser (256 records) or the read index (a full
// ring), so every picture that still came was late and moved it back again. Sampled at eval.
// THE PAUSE (0.5): disp_ctl withholds `tick` (the STC stands still) and the eval / pickup.
// A LONE PTS (UMD fix/film-timing PR fj#25 + fix/lone-early PR fj#26, ported 2026-09-30; UMD
// docs/display.md S10, this tree's docs/display.md S10): a tagged head more than half a refresh
// and at most FWD_MAX ahead of the timeline OR behind it (rule B), not past LATE_MAX, is
// disbelieved -- taken as untagged, on the timeline -- unless the previous tag taken was
// disbelieved too (`susp`: the next tag is always believed, so a real jump under FWD_MAX is
// followed one tag later). UMD's discs carry one-off PES PTS 1-8 ticks off the timeline, the next
// tag back on it; believing one held a picture ~3x and then re-anchored the STC back. Here a
// container that jitters the same way (a TS remux with one late PES) is the case. The decision
// needs d_pic_next, so it is one more stage (ev[1]); `want` is corrected there, before the due
// compare. It never fires before a picture has set the timeline (next_valid: the audio anchor's
// state) and never in place of a jump the other legs re-anchor on.
// CHANGED: clk_sys (27 MHz) instead of clk_dec, so nothing here costs the decoder's
// timing; the decision is EVALUATED at one fixed cycle (eval: raster line 499, dot 0) with
// the STC of that cycle, and TAKEN at pickup (line 500) -- the exact contract
// tools/disp_sched_ref.py models. The STC counts ticks while anchored; an anchor at a
// pickup overrides that cycle's tick.
//
// No `function`, no N'(expr) cast: Quartus 17 miscompiles both silently.

`default_nettype none

module disp_sched #(
    parameter signed [33:0] FWD_MAX_TICKS  = 34'sd45000,   // wait out gaps shorter than this (0.5 s)
    parameter signed [33:0] LATE_MAX_TICKS = 34'sd243000   // re-anchor past this much lateness (2.7 s)
) (
    input  wire         clk,               // clk_sys
    input  wire         rst_n,             // the per-mount reset
    input  wire         tick,              // 90 kHz: one clk pulse
    input  wire         eval,              // one clk: evaluate the head (raster line 499)
    input  wire         pickup,            // one clk: the head was taken (line 500)
    input  wire         ll,                // LOW LATENCY: every head is due (a level; stable per stream)
    input  wire         ext_anc,           // (0.5) one clk: the audio starts the STC (ignored once anchored)
    input  wire  [32:0] ext_pts,
    input  wire  [10:0] half,              // half a refresh, in ticks: 750 (59.94 / 60.00 Hz), 900 (50 Hz) -- P6 §10
    input  wire         aud_lead,          // (1.1) the queued audio is ahead of the clock: no lateness anchor
    // the head of the queue (stable from eval to pickup)
    input  wire         head_valid,        // a picture record, prepared
    input  wire         head_tag,          // it carries a PTS (pts_eff valid)
    input  wire  [32:0] head_pts,          // its effective PTS
    input  wire  [26:0] head_dur_q3,       // its duration, eighth-ticks
    input  wire  [22:0] head_frame_t,      // one frame (2 VUI ticks), in ticks
    output logic        due,               // after eval: take the head at the pickup
    output logic        anchor_now,        // after eval: the take anchors the STC
    output logic        late,              // after eval: the head was already due at the PREVIOUS
                                           //   refresh (a missed opportunity: starved or backlogged)
    output logic        contig,            // after eval: the head continues the timeline (|d| < half)
    output logic        next_due,          // after eval: the timeline is due (no head = starved)
    output logic        lone,              // after eval: the head's PTS is disbelieved (a lone PTS)
    output logic [32:0] stc,
    output logic        anchored,
    output logic        next_valid,
    output logic signed [33:0] disp_lag    // want - STC, latched at each pickup
);

    wire signed [33:0] HALF_SCAN = $signed({23'd0, half});   // (quasi-static: the raster's standard)
    logic [35:0] next_q3;                  // the next picture's PTS, Q3
    wire  [32:0] next_pts = next_q3[35:3];

    // ---- evaluation: the STC of the eval cycle, then four registered stages ---------------
    logic [3:0]  ev;                       // the stages in flight
    logic [32:0] s_e;
    // late = "already due one refresh earlier": the previous eval's STC, valid when the
    // STC ran then and no pickup has re-anchored it since. (A draft judged STC - want >
    // half a refresh at the pickup: 23.976 frames last 2.5 refreshes, every other one is
    // taken ~750 ticks after its PTS -- the best a 59.94 raster can do -- and X-Men 2
    // read LT 21 a minute on the rig with the decoder ahead of the display.)
    logic [32:0] s_prev;
    logic        prev_run, prev_ok, re_anch;
    logic signed [33:0] d_prev_want;
    logic [32:0] want;
    logic signed [33:0] d_pic_next, d_stc_pic, d_stc_want, d_stc_next;
    logic        hv_q, tag_q, lead_q;
    logic        tag_e;                    // tag_q, unless disbelieved (ev[1])
    logic        susp;                     // the previous tag taken was disbelieved
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev <= '0; s_e <= '0; want <= '0; d_pic_next <= '0; d_stc_pic <= '0; d_stc_want <= '0; d_stc_next <= '0;
            s_prev <= '0; prev_run <= 1'b0; prev_ok <= 1'b0; re_anch <= 1'b0; d_prev_want <= '0;
            hv_q <= 1'b0; tag_q <= 1'b0; lead_q <= 1'b0; tag_e <= 1'b0; lone <= 1'b0;
            due <= 1'b0; anchor_now <= 1'b0; late <= 1'b0; contig <= 1'b0; next_due <= 1'b0;
        end else begin
            ev <= {ev[2:0], eval};
            if (eval) begin
                s_e <= stc; hv_q <= head_valid; tag_q <= head_tag; lead_q <= aud_lead;
                s_prev <= s_e; prev_ok <= prev_run && !re_anch;
                prev_run <= anchored; re_anch <= 1'b0;
            end
            if (pickup && anchor_now) re_anch <= 1'b1;
            if (ev[0]) begin
                want       <= tag_q ? head_pts : (next_valid ? next_pts : s_e);
                d_pic_next <= $signed({1'b0, head_pts}) - $signed({1'b0, next_pts});
                d_stc_pic  <= $signed({1'b0, s_e}) - $signed({1'b0, head_pts});
                d_stc_next <= $signed({1'b0, s_e}) - $signed({1'b0, next_pts});
            end
            if (ev[1]) begin : lone_pts
                logic ln;
                ln = tag_q && anchored && next_valid && !susp &&
                     ((d_pic_next > HALF_SCAN) || (d_pic_next < -HALF_SCAN)) &&
                     !(d_pic_next > FWD_MAX_TICKS) && !(d_pic_next < -FWD_MAX_TICKS) &&
                     !(d_stc_pic > LATE_MAX_TICKS);
                lone  <= ln;
                tag_e <= tag_q && !ln;
                if (ln) want <= next_pts;          // on the timeline (next_valid: ln needs it)
            end
            if (ev[2]) begin
                d_stc_want  <= $signed({1'b0, s_e}) - $signed({1'b0, want});
                d_prev_want <= $signed({1'b0, s_prev}) - $signed({1'b0, want});
            end
            if (ev[3]) begin : decide
                logic disc, an;
                logic far, lat;
                lat  = (d_stc_pic > LATE_MAX_TICKS) && !lead_q;        // (1.1) not while the audio leads
                disc = tag_e && anchored && next_valid &&
                       ((d_pic_next < -$signed({11'd0, head_frame_t})) || (d_pic_next > FWD_MAX_TICKS) || lat);
                // (0.5) anchored with no timeline: only the audio anchor leaves that state (a
                // picture's anchor sets next_valid); the picture is scheduled unless far off
                far = lat || (d_stc_pic < -FWD_MAX_TICKS);
                an = hv_q && (!anchored || (tag_e && (next_valid ? disc : far)));
                anchor_now <= an;
                due        <= hv_q && (an || ll || (d_stc_want >= -HALF_SCAN));
                late       <= !an && !ll && prev_ok && (d_prev_want >= -HALF_SCAN);
                contig     <= !tag_e || ((d_pic_next < HALF_SCAN) && (d_pic_next > -HALF_SCAN));
                next_due   <= anchored && next_valid && (d_stc_next >= -HALF_SCAN);
            end
        end
    end

    // ---- the clock and the timeline --------------------------------------------------------
    wire [32:0] anchor_val = tag_e ? head_pts : 33'd0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stc <= '0; anchored <= 1'b0; next_q3 <= '0; next_valid <= 1'b0; disp_lag <= '0; susp <= 1'b0;
        end else begin
            if (tick && anchored) stc <= stc + 33'd1;
            if (ext_anc && !anchored) begin stc <= ext_pts; anchored <= 1'b1; end   // (a pickup's anchor wins)
            if (pickup) begin
                disp_lag <= $signed({1'b0, want}) - $signed({1'b0, s_e});
                if (anchor_now) begin
                    stc      <= anchor_val;
                    anchored <= 1'b1;
                    next_q3  <= {anchor_val, 3'd0} + {9'd0, head_dur_q3};
                end else begin
                    next_q3  <= {want, 3'd0} + {9'd0, head_dur_q3};
                end
                next_valid <= 1'b1;
                if (lone) susp <= 1'b1;
                else if (tag_e) susp <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
