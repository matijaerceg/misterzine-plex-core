// h264/disp_ctl.sv -- the display's control (roadmap P5e, docs/display.md S7): which store
// the raster shows at each refresh, and which field of it, paced by the scheduler
// (h264/disp_sched.sv). clk_sys, the raster's clock; tools/disp_sched_ref.py is the model.
//
//   the tick      90 kHz = clk_sys / 300, phased to the raster: counting starts at the
//                 first (h 0, v 0) after the mount reset (P = 0) -- `frame0`: since hd_raster
//                 the raster runs on clk_vid and emu crosses its frame start in, a few clk_sys
//                 cycles late (the grid is then that much later against the raster: its events
//                 are in the vertical blank, thousands of dots from any line), a tick every 300 cycles
//                 after it (P = 300 m) -- so a refresh, 450,450 cycles, is 1501.5 ticks
//                 and the model knows every tick.
//   the grid      (P6 steps 5 / 6, docs/analog.md §10) the refresh's events come from a
//                 refresh-phase counter restarted at the same point: refresh k's are at
//                 P = RF k + offset, RF = 450,450 (59.94), 450,000 (60.00), 540,000 (50 Hz)
//                 -- one frame progressive, one field interlaced (every raster's frame is a
//                 whole number of refreshes) -- the absolute times tools/disp_sched_ref.py
//                 states. At 59.94 these are the cycles the (line, dot) events of P5e / P6
//                 step 2 had (the 480i placement was chosen to land on this grid).
//   preparation   the queue's head record (h264/recon_out.sv, registered: stable until
//                 taken) becomes {tag, PTS, duration}: the duration is DeltaTfiDivisor
//                 (Table E-6: a frame 2, or its pic_struct's 0/3/4 -> 2, 5/6 -> 3, 7 -> 4,
//                 8 -> 6; a field 1, a pair 1 + 1) times the VUI tick, field_q3 =
//                 720000 * num_units_in_tick / time_scale eighth-ticks (C-1), by a 24-step
//                 serial division (~30 cycles against a 16.7 ms refresh). No VUI timing:
//                 12012 (59.94) and flag 1; a tick over 2^24 eighth-ticks (23 s) or a
//                 time_scale of 0: clamped / 12012 and flag 2; a pic_struct that does not
//                 fit the store (1/2 on a frame, 0/3-8 on a field, 9-15): the default and
//                 flag 4. A pair tagged only on its second field: PTS - one tick.
//   the refresh   offset 499 x 858: eval (the scheduler decides with that cycle's STC);
//                 500 x 858 (progressive 59.94: line 500 dot 0; 50 Hz 599 / 600 x 864): the
//                 pickup -- a due head is taken (rec_take), the store
//                 shown until then released (rel_*: its last line was fetched at line 478,
//                 line 0's comes at 523), the new store latched for the reader (sh_*).
//                 The END record is taken the same way; the last store stays, held.
//   the parity    a field store shows field first_bot ^ (refreshes since its pickup)[0];
//                 a single field its own (sh_single: the reader bobs it in every mode);
//                 a frame 0. (P5f's Bob keeps it; the future 480i raster needs the same.)
//   the field     (P7, UMD's V6 -- its PR fj#37, HW-confirmed on a CRT there; docs/analog.md §5) at
//                 480i / 576i the raster's field shows its own lines of a field store
//                 (disp_reader), so a field PAIR is picked up only for a refresh of its first
//                 field's parity: refresh 0 is the top field (frame0), the pickup in refresh k
//                 decides refresh k + 1 (field !fpar). A due pair on the other field waits one
//                 refresh (n_fhold), the store shown until then shown once more -- unless it is
//                 LATE (due at the previous refresh already: a starve's backlog catches up, and a
//                 head waits once at most). The scheduler is not told (its pickup is `pick`): an
//                 anchoring pair anchors a field later, in phase from then on. A hold's next
//                 pickup is not counted late, nor the held store's cadence judged (this tree's
//                 addition: a hold is not a missed opportunity). Frames and single fields are never
//                 held, nor anything on a progressive raster. A stream whose timeline sits a field
//                 off the raster's (after a pause of an odd field count -- UMD samples its freeze at
//                 top fields, this pause is not aligned -- a 3-field frame or a single field) holds
//                 every pair: in order, one field behind the audio (16.7 / 20 ms), n_fhold climbing;
//                 a frame or single field after such a pair cuts its second field (the cut is what
//                 keeps the lag bounded: a two-field minimum was tried and ratchets -- pairs never
//                 catch up, and at two refreshes behind every pair was taken late, off its field).
//                 MiSTer_DVD's corrector needed a feedback arm: its pickup did not know the
//                 raster's next field; this one does.
//   low latency   (roadmap P3f: low_lat, the stream's LOW_LATENCY) every prepared head is
//                 due at the pickup (disp_sched's `ll`); and at 490 x 858 (590 x 864), when a picture is
//                 on screen and another PICTURE already waits behind the head (rec_more:
//                 recon_out never counts the END), the head is taken and released unseen
//                 (n_skip) -- one a refresh at most, the next head prepared long before
//                 line 500 -- so a source a little faster than the raster never queues.
//   the rate      (Refresh Rate's Auto, docs/analog.md §10) each prepared head's VUI tick
//                 classified: field_q3 3,000 / 6,000 / 12,000 / 15,000 (120, 60, 30, 24
//                 frames/s) -> 1 (60.00 Hz); 3,600 / 7,200 / 14,400 (100, 50, 25) -> 2 (50
//                 Hz); anything else, or no VUI timing -> 0 (59.94). rate_v while prepared.
//   the pause     (Phase 4, interface 0.5: program word 34) the tick into the scheduler is
//                 withheld (the STC stands still) and so are the skip, the eval and the pickup:
//                 the shown store, its parity and the cadence count hold exactly, nothing is
//                 counted as starved or late, and resume continues the timeline.
//   the audio     (0.5) aanc / aanc_pts: h264/aud_play.sv's audio anchor, into the scheduler
//   instruments   dc: the decided (store, parity) changes -- disp_reader counts the ones
//                 it FETCHED, independently (the judder gate: equal); reanchors; late
//                 pickups; starved refreshes; cadence errors (a store held for a refresh
//                 count outside {floor, ceil} of its duration / one refresh, judged at the
//                 next contiguous pickup); flags; the last lag in ms.
//
// No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none

module disp_ctl (
    input  wire         clk,               // clk_sys
    input  wire         rst_n,             // the per-mount reset (fe_rst_n)
    input  wire         frame0,            // (hd_raster) the raster's frame start -- the top field's first dot,
                                           // (h 0, v 0) -- crossed from clk_vid in the raster's mode (emu)
    input  wire         il,                // P6: the 480i raster (a refresh is a field)
    input  wire         prog240,           // fixed progressive 240p/288p timing frame
    input  wire  [1:0]  std,               // the raster standard (0 59.94, 1 60.00, 2 50 Hz)
    // the queue's head (h264/recon_out.sv)
    input  wire         rec_valid,
    input  wire         rec_more,          // recon_out: another picture waits behind the head
    input  wire         low_lat,           // the stream's LOW_LATENCY (a level, stable per stream)
    input  wire         pause,             // (0.5) word 34's PAUSE: the STC and the display stand still
    input  wire         aanc,              // (0.5) the audio anchor (aud_play)
    input  wire  [32:0] aanc_pts,
    input  wire         aud_lead,          // (1.1) the queued audio is ahead of the clock (aud_play): no lateness anchor
    output logic        rec_take,
    input  wire         rec_end,
    input  wire  [4:0]  rec_store,
    input  wire         rec_frame,
    input  wire         rec_unpaired,
    input  wire         rec_first_bot,
    input  wire         rec_dec_t,
    input  wire         rec_dec_b,
    input  wire  [7:0]  rec_w_mbs,
    input  wire  [7:0]  rec_hf_mbs,
    input  wire  [40:0] rec_crop,          // P6: the store's crop (recon_top's pinfo_crop), carried to the fit
    input  wire  [39:0] rec_aspect,
    input  wire  [2:0]  rec_colour,        // (0.16, docs/colour.md) the picture's colour code
    input  wire         rec_col_unsup,     // (0.16) ... shown by the size rule, its matrix not supported
    input  wire  [25:0] rec_col_tags,      // (0.16) ... its SPS's colour description
    input  wire  [5:0]  rec_siting,        // (docs/chroma.md §4) ... its chroma siting {bottom, top}
    input  wire         rec_timing_v,
    input  wire  [31:0] rec_nuit,
    input  wire  [31:0] rec_ts,
    input  wire  [3:0]  rec_ps_a,
    input  wire         rec_ps_a_v,
    input  wire  [3:0]  rec_ps_b,
    input  wire         rec_ps_b_v,
    input  wire  [32:0] rec_pts,
    input  wire         rec_pts_v,
    input  wire  [32:0] rec_pts_b,
    input  wire         rec_pts_b_v,
    output logic        rel_valid,
    output logic [4:0]  rel_store,
    // the shown store, for disp_reader (latched at line 500)
    output logic        sh_valid,
    output logic        sh_field,
    output logic [4:0]  sh_store,
    output logic [7:0]  sh_w,
    output logic [7:0]  sh_hf,
    output logic        sh_parity,
    output logic        sh_single,         // the shown store is ONE field (unpaired)
    output logic [40:0] sh_crop,           // P6: the shown store's crop
    output logic [39:0] sh_aspect,
    output logic [2:0]  sh_colour,         // (0.16) the shown picture's colour code (1 before any picture)
    output logic [25:0] sh_col_tags,       // (0.16) ... its colour description (word 86)
    output logic [5:0]  sh_siting,         // (chroma.md §4) ... its chroma siting (0 before any picture)
    output logic [15:0] n_col_unsup,       // (0.16) pictures taken whose matrix is not supported (word 86; reset per stream, saturating)
    // instruments
    output logic [31:0] n_dc,
    output logic [31:0] n_pick,
    output logic [31:0] n_skip,            // heads skipped in low latency
    output logic [7:0]  n_reanchor,
    output logic [3:0]  n_lone,            // lone PTS disbelieved (saturating; disp_sched, docs/display.md S10)
    output logic [15:0] n_late,
    output logic [15:0] n_starve,
    output logic [15:0] n_cadence,
    output logic [31:0] n_fhold,           // (P7) field pairs held a refresh for the raster's field (word 85)
    output logic [2:0]  flags,
    output logic signed [15:0] lag_ms,
    output logic [32:0] stc,
    output logic        pick_ph,           // (hdmi_raster stage 2) the pickup's phase of every refresh (pause or not): emu's latches
    output logic        stc_run,           // P6: the STC is anchored and counting (the audio gate's clock)
    output logic        rate_v,            // the head is prepared: rate_cls is its rate's class
    output logic [1:0]  rate_cls,          // 0 59.94 (or no VUI timing), 1 60.00, 2 50 Hz (Refresh Rate's Auto)
    output logic        ended
);

    // ---- the tick, phased to the raster, and the refresh grid ----------------------------------
    // P6: a refresh is a FIELD at 480i; the fields are 263 and 262 lines (the short field
    // starts 858 cycles off the grid), so the events are NOT placed by (line, dot): they come
    // from a refresh-phase counter, restarted with the tick at the top field's (a frame's)
    // first dot, at the grid's absolute times -- skip 490 x 858, eval 499 x 858, pickup 500 x
    // 858 after each grid point (50 Hz: 590 / 599 / 600 x 864), all in vertical blanking and
    // before the next refresh's first line is commanded. A change of raster (il or std)
    // restarts it: the tick and the grid re-align at the top field's first dot.
    logic       aligned, il_q, p240_q;
    wire        prog240_i = (prog240 === 1'b1);
    logic [1:0] std_q;
    logic [8:0] tdiv;
    logic [19:0] rp;                                            // the refresh phase, 0 .. RF - 1
    logic        fpar;                                          // (P7) the raster's field of this refresh: 0 top
    wire        pal = (std == 2'd2);
    wire [19:0] rf_m1   = prog240_i ? (pal ? 20'd540071 : 20'd450639) :
                         pal ? 20'd539999 : (std == 2'd1) ? 20'd449999 : 20'd450449;
    // Keep the three decisions inside the 240p/288p vertical blank: a short lead
    // is sufficient because the prepared head is already queued before evaluation.
    wire [19:0] p_eval  = prog240_i ? (pal ? 20'd515838 : 20'd426560) :
                         pal ? 20'd517536 : 20'd428142;
    wire [19:0] p_pick  = prog240_i ? (pal ? 20'd517569 : 20'd428280) :
                         pal ? 20'd518400 : 20'd429000;
    wire [19:0] p_skip  = prog240_i ? (pal ? 20'd501990 : 20'd416240) :
                         pal ? 20'd509760 : 20'd420420;
    wire        tick = aligned && (tdiv == 9'd0);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aligned <= 1'b0; tdiv <= '0; il_q <= 1'b0; p240_q <= 1'b0; std_q <= 2'd0; rp <= '0; fpar <= 1'b0;
        end else begin
            il_q <= il; p240_q <= prog240_i; std_q <= std;
            if (il != il_q || prog240_i != p240_q || std != std_q) aligned <= 1'b0;
            else if (!aligned) begin
                if (frame0) begin aligned <= 1'b1; tdiv <= 9'd1; rp <= 20'd1; fpar <= 1'b0; end
            end else begin
                tdiv <= (tdiv == 9'd299) ? 9'd0 : tdiv + 9'd1;
                rp <= (rp == rf_m1) ? 20'd0 : rp + 20'd1;
                if (rp == rf_m1) fpar <= !fpar;
            end
        end
    end
    wire ev_pulse = aligned && (rp == p_eval) && !pause;
    wire pk_pulse = aligned && (rp == p_pick) && !pause;
    wire sk_pulse = aligned && (rp == p_skip) && !pause;
    // the pickup's phase, raster-independent (a native raster may be shorter or taller than line
    // 500): emu latches the menu's fit mode, the display's shape and Native here, so disp_fit and
    // raster_geom recompute inside the pickup's 21,450-dot lead before the next refresh
    assign pick_ph = aligned && (rp == p_pick);

    // ---- preparation: the head's tick (field_q3), its duration, its PTS -----------------------
    // states: 0 idle (nothing, END, or prepared), 1 the range check, 2 the 24 division
    // steps, 26 the quotient, 27 the duration and PTS -- then prep until the take
    logic [4:0]  pst;
    logic [51:0] num;
    logic [32:0] rem;
    logic [23:0] quo;
    logic [4:0]  dstep;
    logic [23:0] fq;                       // field_q3 of the head
    logic [2:0]  hflag;
    logic        prep;                     // the head is prepared
    logic [26:0] dur_q3;
    logic [32:0] pts_eff;
    logic        tag;
    logic [2:0]  nt;
    logic        ps_err;
    // Table E-6 (a head that is not END)
    always_comb begin
        ps_err = 1'b0;
        if (rec_frame) begin
            nt = 3'd2;
            if (rec_ps_a_v) begin
                case (rec_ps_a)
                    4'd0, 4'd3, 4'd4: nt = 3'd2;
                    4'd5, 4'd6:       nt = 3'd3;
                    4'd7:             nt = 3'd4;
                    4'd8:             nt = 3'd6;
                    default:          begin nt = 3'd2; ps_err = 1'b1; end
                endcase
            end
        end else begin
            nt = rec_unpaired ? 3'd1 : 3'd2;
            if (rec_ps_a_v && !(rec_ps_a == 4'd1 || rec_ps_a == 4'd2)) ps_err = 1'b1;
            if (!rec_unpaired && rec_ps_b_v && !(rec_ps_b == 4'd1 || rec_ps_b == 4'd2)) ps_err = 1'b1;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pst <= '0; num <= '0; rem <= '0; quo <= '0; dstep <= '0; fq <= 24'd12012; hflag <= '0; prep <= 1'b0;
            dur_q3 <= '0; pts_eff <= '0; tag <= 1'b0; rate_cls <= 2'd0;
        end else begin
            case (pst)
                5'd0: if (rec_valid && !rec_end && !prep && !rec_take) begin
                    num <= rec_nuit * 20'd720000;
                    pst <= 5'd1;
                end
                5'd1: begin
                    // the quotient must fit 24 bits: num < ts << 24
                    if (!rec_timing_v) begin fq <= 24'd12012; hflag <= 3'd1; pst <= 5'd27; end
                    else if (rec_ts == 32'd0 || num >= {rec_ts, 24'd0}) begin
                        fq <= (rec_ts == 32'd0) ? 24'd12012 : 24'hFFFFFF; hflag <= 3'd2; pst <= 5'd27;
                    end else begin
                        rem <= {5'd0, num[51:24]}; quo <= '0; dstep <= 5'd23; hflag <= 3'd0; pst <= 5'd2;
                    end
                end
                5'd2: begin : divide
                    logic [32:0] t;
                    t = {rem[31:0], num[dstep]};
                    if (t >= {1'b0, rec_ts}) begin rem <= t - {1'b0, rec_ts}; quo[dstep] <= 1'b1; end
                    else rem <= t;
                    if (dstep == 5'd0) pst <= 5'd26; else dstep <= dstep - 5'd1;
                end
                5'd26: begin
                    if (quo == 24'd0) begin fq <= 24'd12012; hflag <= 3'd2; end
                    else fq <= quo;
                    pst <= 5'd27;
                end
                5'd27: begin
                    // the duration (nt x fq: shifts and adds), the effective PTS
                    case (nt)
                        3'd1:    dur_q3 <= {3'd0, fq};
                        3'd3:    dur_q3 <= {2'd0, fq, 1'b0} + {3'd0, fq};
                        3'd4:    dur_q3 <= {1'd0, fq, 2'b0};
                        3'd6:    dur_q3 <= {1'd0, fq, 2'b0} + {2'd0, fq, 1'b0};
                        default: dur_q3 <= {2'd0, fq, 1'b0};
                    endcase
                    if (rec_pts_v) begin tag <= 1'b1; pts_eff <= rec_pts; end
                    else if (rec_pts_b_v && !rec_frame && !rec_unpaired) begin
                        tag <= 1'b1; pts_eff <= rec_pts_b - {12'd0, fq[23:3]};
                    end else begin tag <= 1'b0; pts_eff <= '0; end
                    hflag <= hflag | (ps_err ? 3'd4 : 3'd0);
                    // the rate's class (hflag 0: fq is the VUI's own)
                    rate_cls <= (hflag != 3'd0) ? 2'd0 :
                                (fq == 24'd3000 || fq == 24'd6000 || fq == 24'd12000 || fq == 24'd15000) ? 2'd1 :
                                (fq == 24'd3600 || fq == 24'd7200 || fq == 24'd14400) ? 2'd2 : 2'd0;
                    // fq is the per-field half of a frame duration (nt=2 for a frame).
                    // Thus 24 and 23.976 fps frames are 2*15,000 and 2*15,015 Q3 ticks.
                    prep <= 1'b1;
                    pst <= 5'd0;
                end
                default: pst <= 5'd0;
            endcase
            if (rec_take) prep <= 1'b0;
        end
    end

    // ---- the scheduler -----------------------------------------------------------------------
    logic ev_head, ev_end;                 // what the eval saw at the head
    logic due, anchor_now, late, contig, next_due, anchored, next_valid, lone;
    logic signed [33:0] disp_lag;
    logic pick;                            // the pickup takes the head
    disp_sched u_sched (
        .clk(clk), .rst_n(rst_n), .tick(tick && !pause), .eval(ev_pulse), .pickup(pick), .ll(low_lat),
        .ext_anc(aanc), .ext_pts(aanc_pts), .aud_lead(aud_lead),
        .half(pal ? 11'd900 : 11'd750), // half refresh, rounded ticks (1,800 / 1,500)
        .head_valid(rec_valid && !rec_end && prep && !ended), .head_tag(tag), .head_pts(pts_eff),
        .head_dur_q3(dur_q3), .head_frame_t({1'b0, fq[23:2]}),
        .due(due), .anchor_now(anchor_now), .late(late), .contig(contig), .next_due(next_due), .lone(lone),
        .stc(stc), .anchored(anchored), .next_valid(next_valid), .disp_lag(disp_lag));
    // (P7, UMD's V6) at 480i / 576i a field pair due for the other raster field waits a refresh
    // (the pickup decides refresh k + 1: field !fpar) -- unless it is LATE (due at the previous
    // refresh already: a backlog, or the refresh after a hold), so a queue still catches up and
    // a head waits once at most
    wire fhold = il && !late && !rec_frame && !rec_unpaired && (rec_first_bot == fpar);
    assign pick = pk_pulse && ev_head && due && !fhold;
    assign stc_run = anchored;
    assign rate_v = prep && rec_valid && !rec_end;

    // ---- the refresh: take, release, latch, count ---------------------------------------------
    logic [15:0] idx;                      // refreshes since the shown store's pickup
    logic        cur_pair, cur_first_bot, cur_single_bot;
    logic [27:0] c_lo, c_hi;               // idx x R and (idx + 2) x R: the cadence window
    // the last pickup's lag (want - STC) in ms: ticks x 728 / 65536 (1 / 90.02)
    logic signed [45:0] lag_p;
    always_ff @(posedge clk) begin
        lag_p  <= disp_lag * 46'sd728;
        lag_ms <= lag_p[31:16];
    end
    logic [26:0] cur_dur;
    logic        starved, have_cur;
    logic        held_f;                   // (P7) the last pickup refresh was a field hold
    // one refresh in eighth-ticks: 1,501.5 / 1,500 / 1,800 ticks
    wire [27:0] R_Q3 = pal ? 28'd14400 : (std == 2'd1) ? 28'd12000 : 28'd12012;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rec_take <= 1'b0; rel_valid <= 1'b0; rel_store <= '0;
            sh_valid <= 1'b0; sh_field <= 1'b0; sh_store <= '0; sh_w <= '0; sh_hf <= '0; sh_parity <= 1'b0; sh_single <= 1'b0;
            sh_aspect <= '0; sh_colour <= 3'd1; sh_col_tags <= {1'b0, 1'b0, 8'd2, 8'd2, 8'd2}; sh_siting <= 6'd0; n_col_unsup <= '0; sh_crop <= '0; ev_head <= 1'b0; ev_end <= 1'b0; ended <= 1'b0;
            idx <= '0; cur_pair <= 1'b0; cur_first_bot <= 1'b0; cur_single_bot <= 1'b0; c_lo <= '0; c_hi <= '0;
            cur_dur <= '0; starved <= 1'b0; have_cur <= 1'b0; held_f <= 1'b0; n_fhold <= '0;
            n_dc <= '0; n_pick <= '0; n_skip <= '0; n_reanchor <= '0; n_late <= '0; n_starve <= '0; n_cadence <= '0; n_lone <= '0;
            flags <= '0;
        end else begin
            rec_take <= 1'b0; rel_valid <= 1'b0;
            // low latency: a head a newer picture waits behind is dropped unseen (line 490)
            if (sk_pulse && low_lat && have_cur && rec_valid && !rec_end && prep && !ended && rec_more) begin
                rec_take <= 1'b1; rel_valid <= 1'b1; rel_store <= rec_store;
                n_skip <= n_skip + 32'd1;
            end
            if (ev_pulse) begin
                ev_head <= rec_valid && !rec_end && prep && !ended;
                ev_end  <= rec_valid && rec_end && !ended;
            end
            if (pk_pulse) begin
                held_f <= ev_head && due && fhold;
                if (ev_head && due && fhold) n_fhold <= n_fhold + 32'd1;
                if (ev_end) begin
                    rec_take <= 1'b1; ended <= 1'b1;
                end
                if (pick) begin
                    rec_take <= 1'b1;
                    n_pick <= n_pick + 32'd1;
                    n_dc   <= n_dc + 32'd1;
                    // the previous store's cadence, judged at a contiguous pickup
                    if (have_cur && !anchor_now && !starved && contig && !held_f &&
                        !(({1'b0, cur_dur} > c_lo) && ({1'b0, cur_dur} < c_hi)))
                        n_cadence <= n_cadence + 16'd1;
                    if (late && !held_f) n_late <= n_late + 16'd1;
                    if (anchor_now && n_reanchor != 8'hFF) n_reanchor <= n_reanchor + 8'd1;
                    if (lone && n_lone != 4'hF) n_lone <= n_lone + 4'd1;
                    flags <= flags | hflag;
                    if (have_cur) begin rel_valid <= 1'b1; rel_store <= sh_store; end
                    have_cur <= 1'b1;
                    sh_valid <= 1'b1; sh_field <= !rec_frame; sh_store <= rec_store; sh_w <= rec_w_mbs;
                    sh_hf <= rec_hf_mbs; sh_aspect <= rec_aspect; sh_colour <= rec_colour; sh_col_tags <= rec_col_tags; sh_siting <= rec_siting; sh_crop <= rec_crop;
                    if (rec_col_unsup && n_col_unsup != 16'hFFFF) n_col_unsup <= n_col_unsup + 16'd1;
                    cur_pair <= !rec_frame && !rec_unpaired; cur_first_bot <= rec_first_bot;
                    cur_single_bot <= rec_dec_b && !rec_dec_t;
                    sh_parity <= rec_frame ? 1'b0 : rec_unpaired ? (rec_dec_b && !rec_dec_t) : rec_first_bot;
                    sh_single <= !rec_frame && rec_unpaired;
                    cur_dur <= dur_q3;
                    idx <= '0; c_lo <= '0; c_hi <= R_Q3 + R_Q3;
                    starved <= 1'b0;
                end else begin
                    if (have_cur) begin
                        idx <= idx + 16'd1;
                        c_lo <= c_lo + R_Q3; c_hi <= c_hi + R_Q3;
                        if (cur_pair) begin
                            n_dc <= n_dc + 32'd1;
                            sh_parity <= cur_first_bot ^ !idx[0];     // (idx + 1)[0]
                        end
                    end
                    // starved: no head at the eval while the timeline was due (the END
                    // record's refresh is the title's end, not a starve)
                    if (!ev_head && !ev_end && !ended && next_due) begin
                        starved <= 1'b1; n_starve <= n_starve + 16'd1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
