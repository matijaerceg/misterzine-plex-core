// bench/h264/ring_rd_tb.sv -- the HPS interface's reader (h264/ring_rd.sv) and status block
// (h264/ring_stat.sv, cdc_snap_ix, ring_words_*) against tools/ring_model.py, on three real
// clocks, through ddr_mux2 beside a random master A, into bench/h264/ddr_model.sv (its
// [ddr] and [avalon] policing: a withdrawn or changed command fails the run).
//
//   +stem=S   S.steps.hex   the producer's script (the model's Producer): pokes into DDR3,
//                           the write index and nonce, waits on the published read index /
//                           ack / state, delays, an OSD reset, the reset release
//             S.expect.hex  what the reader must deliver, in order: bytes {byte, mark, PTS,
//                           au_end}, stream resets, EOS flushes; a PREFIX section may stop
//                           early (a session replaced mid-stream)
//             S.final.hex   status fields (word, lsb, width) and their values at the end
//             S.audio.hex   (0.5) the AUDIO payloads, in order: the words the audio fetch must
//                           return (the bench stands in for h264/aud_play.sv: it takes each
//                           descriptor, fetches the record through the engine, releases it after
//                           a random delay -- the held read index)
//             S.pics.hex    (0.15) what recon_out must present: each PICTURE's record (the store,
//                           its kind, size, crop, aspect, timing, pic_struct, PTS) and the END
//                           records -- h264/pic_in.sv and h264/recon_out.sv run here on clk_dec,
//                           reset per stream as in emu; the bench stands in for the display: it
//                           takes each record, checks it, and releases the store it took before
//                           (it holds one, as the display shows one); taking an END ends the stream
//   +arm=Rn   the scenario's name, printed with the verdict
//   +ready_pct=N  the decoder's ready (default 70)   +a_pct=N  master A's activity (default 30)
//   +aud_delay=N  (0.5) the audio consumer's release delay after a fetch, clk_sys cycles (default 3000)
//   +errs_any     (0.15) errors other than the final one are expected (R29: a session per error)
//   +ack_delay=N  (0.15) pic_in's pd_ack reaches the parser N clk_sys cycles late (default 0): R32
//                 stretches a hand-over so a session's clear lands inside it
//   +aud_wait=N   (0.5) ... and how long after its descriptor it starts fetching a record (default
//                 3000: aud_play fetches a record just before it plays, so a read index released
//                 early leaves the producer a window to overwrite it -- the hold's arm)
//
// Checks (each FAIL names its arm): [bytes] a delivered byte, mark, PTS or au_end differs;
// [events] a reset / EOS out of place; [missing] the run ended before everything expected
// arrived; [final] a status field differs; [seqlock] seq_head / seq_tail disagree or stand
// still; [audio] (0.5) a fetched AUDIO word differs from what the program wrote (the read
// index released too early lets the producer overwrite it), or a fetch misbehaves; [pause]
// (0.5) something delivered or the read index moved while paused; [words] a constant or
// snapshot word is wrong (the clk_dec words are a known
// function of the index; the probe / fetch fields known constants); [poll] the idle polls
// exceed the fast period's count, or no poll ran; [hang] a wait timed out; (0.15) [pics] a
// record recon_out presents differs from the model's picture (or arrives unexpected / is
// missing), [hold] pic_emitted did not step on the edge the emitted store's hold rose, [mux] a
// coded stream's recon_top outputs did not reach recon_out unchanged.
// Scoring is with !== (X never passes). PASS: ring_rd_tb is printed only when every check held.

`timescale 1ns/1ps
`default_nettype none

module ring_rd_tb;
`include "h264/ring_iface.svh"

    localparam logic [28:0] CTRL = 29'h0628_0000;
    localparam int RING_AW = 9;                         // 512 words: wraps are frequent
    localparam logic [28:0] RINGW = CTRL + 29'd512;
    localparam int POLL_FAST = 200, POLL_SLOW = 3000;   // clk_mem cycles
    localparam int FRAME_T = 2500;                      // clk_sys cycles a "raster frame"

    // ---- clocks: clk_sys 27, clk_mem 90, clk_dec 81 MHz ----
    logic clk = 0, mclk = 0, dclk = 0;
    always #18.5 clk = ~clk;
    always #5.55 mclk = ~mclk;
    always #6.15 dclk = ~dclk;

    logic lock_n = 1'b0;          // the PLL lock: lrst_n, mrst_n, drst_n
    logic core_n = 1'b0;          // reset_n (the OSD reset pulses it)

    string stem, arm;
    int ready_pct = 70, a_pct = 30, aud_delay = 3000, aud_wait = 3000, ack_delay = 0;
    logic [63:0] steps [0:1<<20];
    logic [63:0] expect_q [0:1<<19];
    logic [63:0] final_q [0:255];
    logic [63:0] audio_q [0:1<<16];
    logic [63:0] pics_q [0:1<<14];
    int fails = 0;

    task automatic fail(input string label, input string msg);
        $display("FAIL [%s] %s: %s", label, arm, msg);
        fails++;
        if (fails > 8) $fatal(1);
    endtask

    // ---- the DUT ----
    logic [7:0]  es_byte;  logic es_mark, es_au_end, es_valid, es_ready;  logic [32:0] es_pts;
    logic        stream_clr, eos, ll_mode, gfx_mode, disp_ended;
    logic [15:0] gfx_mismatch;
    logic [63:0] st_word;  logic [6:0] st_ix;  logic st_wr, st_grp;  logic [6:0] st_free;
    // 0.5: the audio path's side (the bench's consumer below)
    logic        ad_push, ad_ptsv, ad_room, a_hold_v, aud_idle;
    logic [31:0] ad_pos, a_hold_idx, hold_bytes;  logic [22:0] ad_len;  logic [32:0] ad_pts;
    logic        af_go = 1'b0, af_busy, af_valid, af_empty, af_rd;
    logic [31:0] af_addr = '0;  logic [3:0] af_n = '0;  logic [63:0] af_dout;
    logic        ctl_pause, ctl_err;  logic [7:0] ctl_atten;
    logic [95:0] rumble;  logic [31:0] rum_changes;     // 0.13: words 36-38 as passed to Main
    logic        sess, eos_seen;
    logic [7:0]  state, err;  logic [31:0] err_pos;  logic [63:0] err_word;
    logic [31:0] n_au, n_audio, n_pad, n_streams, es_bytes, ll_mismatch;
    logic [28:0] b_address;  logic [7:0] b_burstcount;  logic b_read, b_write, b_waitrequest, b_readdatavalid;
    logic [63:0] b_writedata, b_readdata;
    logic [31:0] read_index, ack_nonce, n_polls, n_bursts, eng_widx;  logic [7:0] eng_err;  logic eng_session;
    logic [31:0] set_word;  logic set_tog;
    logic [127:0] geom_data; logic [7:0] geom_ack_seq; logic [1:0] geom_error;
    // 0.15: the PICTURE hand-over
    logic        pd_req, pd_ps_v, pd_timing_v, pd_pts_v, pd_eos, pd_ack, pd_busy, pd_ack_d, pic_mode;
    logic [4:0]  pd_store;  logic [7:0] pd_w, pd_hf;  logic [1:0] pd_struct;  logic [3:0] pd_ps;
    logic [39:0] pd_aspect, pd_crop;  logic [31:0] pd_nuit, pd_ts;  logic [32:0] pd_pts;
    logic [2:0]  pd_colour, colour_mode;  logic [15:0] colour_mismatch;   // (0.16, docs/colour.md)

    ring_rd #(.CTRL_WORD(CTRL), .RING_WORD(RINGW), .RING_AW(RING_AW), .POLL_FAST(POLL_FAST), .POLL_SLOW(POLL_SLOW),
              .CLR_HOLD(16), .SETTLE(32), .END_WAIT(20000)) dut (
        .clk, .rst_n(core_n), .lrst_n(lock_n),
        .es_byte, .es_mark, .es_pts, .es_au_end, .es_valid, .es_ready,
        .stream_clr, .eos, .ll_mode, .gfx_mode, .disp_ended,
        .ad_push, .ad_pos, .ad_len, .ad_pts, .ad_ptsv, .ad_room, .a_hold_v, .a_hold_idx, .aud_idle, .hold_bytes,
        .af_go, .af_addr, .af_n, .af_busy, .af_dout, .af_valid, .af_empty, .af_rd,
        .ctl_pause, .ctl_err, .ctl_atten, .rumble, .rum_changes,
        .st_word, .st_ix, .st_wr, .st_grp, .st_free,
        .sess, .state, .err, .err_pos, .err_word, .eos_seen,
        .n_au, .n_audio, .n_pad, .n_streams, .es_bytes, .ll_mismatch, .gfx_mismatch, .colour_mode, .colour_mismatch,
        .pd_req, .pd_store, .pd_w, .pd_hf, .pd_struct, .pd_ps, .pd_ps_v, .pd_aspect, .pd_colour, .pd_timing_v, .pd_nuit, .pd_ts,
        .pd_crop, .pd_pts, .pd_pts_v, .pd_eos, .pd_ack(pd_ack_d), .pd_busy, .pic_mode,
        .mclk, .mrst_n(lock_n),
        .b_address, .b_burstcount, .b_read, .b_write, .b_writedata, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .read_index, .ack_nonce, .n_polls, .n_bursts, .eng_err, .eng_session, .eng_widx, .set_word, .set_tog,
        .geom_data, .geom_ack_seq, .geom_error);

    // ---- 0.15: pic_in and recon_out on clk_dec, reset per stream as in emu (fe_rst_n = reset_n &
    // ~stream_clr, into clk_dec through cdc_reset); recon_top's side tied off (no decoder here) ----
    logic        fe_rst_n, fe_rst_dec_n, lock_dec_n;
    assign fe_rst_n = core_n & ~stream_clr;
    cdc_reset u_fed (.clk(dclk), .rst_n_in(fe_rst_n), .rst_n_out(fe_rst_dec_n));
    cdc_reset u_lkd (.clk(dclk), .rst_n_in(lock_n), .rst_n_out(lock_dec_n));
    logic        po_we, po_second, po_ps_v, po_pts_v, po_idr, po_timing_v, po_valid, po_unpaired, po_first_bot, po_frame,
                 po_dec_t, po_dec_b, po_eos_done;
    logic [31:0] po_nuit, po_ts, pic_emitted, n_emit, n_rel;
    logic [4:0]  po_store, po_estore;  logic [7:0] po_w, po_hf;  logic [40:0] po_crop;  logic [39:0] po_aspect;
    logic [2:0]  po_colour;  logic po_col_unsup;  logic [25:0] po_col_tags;   // (0.16)
    logic [5:0]  po_siting;                                                   // (docs/chroma.md §4)
    logic [3:0]  po_ps;  logic [32:0] po_pts;  logic [19:0] oq_hold;  logic rec_ovf, rel_bad;
    pic_in #(.NST(20)) u_pic (
        .clk(dclk), .rst_n(fe_rst_dec_n), .cnt_rst_n(lock_dec_n),
        .pd_req, .pd_store, .pd_w, .pd_hf, .pd_struct, .pd_ps, .pd_ps_v, .pd_aspect, .pd_colour, .pd_timing_v, .pd_nuit, .pd_ts,
        .pd_crop, .pd_pts, .pd_pts_v, .pd_eos, .pd_ack, .pd_busy, .oq_hold, .pic_emitted, .sel(),
        .r_pinfo_we(1'b0), .r_pinfo_store(5'd0), .r_pinfo_second(1'b0), .r_pinfo_w_mbs(8'hA5), .r_pinfo_hf_mbs(8'h5A),
        .r_pinfo_crop(41'd0), .r_pinfo_aspect(40'd0), .r_pinfo_colour(3'd0), .r_pinfo_col_unsup(1'b0), .r_pinfo_col_tags(26'd0), .r_pinfo_siting(6'd0), .r_pinfo_timing_v(1'b0), .r_pinfo_nuit(32'd0), .r_pinfo_ts(32'd0),
        .r_pinfo_ps(4'd0), .r_pinfo_ps_v(1'b0), .r_pinfo_pts(33'd0), .r_pinfo_pts_v(1'b0), .r_pinfo_idr(1'b0),
        .r_emit_valid(1'b0), .r_emit_store(5'd0), .r_emit_unpaired(1'b0), .r_emit_first_bot(1'b0), .r_emit_frame(1'b0),
        .r_emit_dec_t(1'b0), .r_emit_dec_b(1'b0), .r_eos_done(1'b0),
        .pinfo_we(po_we), .pinfo_store(po_store), .pinfo_second(po_second), .pinfo_w_mbs(po_w), .pinfo_hf_mbs(po_hf),
        .pinfo_crop(po_crop), .pinfo_aspect(po_aspect), .pinfo_colour(po_colour), .pinfo_col_unsup(po_col_unsup),
        .pinfo_col_tags(po_col_tags), .pinfo_siting(po_siting), .pinfo_timing_v(po_timing_v), .pinfo_nuit(po_nuit),
        .pinfo_ts(po_ts), .pinfo_ps(po_ps), .pinfo_ps_v(po_ps_v), .pinfo_pts(po_pts), .pinfo_pts_v(po_pts_v),
        .pinfo_idr(po_idr), .emit_valid(po_valid), .emit_store(po_estore), .emit_unpaired(po_unpaired),
        .emit_first_bot(po_first_bot), .emit_frame(po_frame), .emit_dec_t(po_dec_t), .emit_dec_b(po_dec_b),
        .eos_done(po_eos_done));
    logic        rec_valid, rec_more, rec_take = 1'b0, rec_end, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b;
    logic        rec_timing_v, rec_ps_a_v, rec_ps_b_v, rec_pts_v, rec_pts_b_v, rec_idr, rel_valid = 1'b0;
    logic [4:0]  rec_store, rel_store = '0;  logic [7:0] rec_w, rec_hf;  logic [40:0] rec_crop;  logic [39:0] rec_aspect;
    logic [2:0]  rec_colour;  logic rec_col_unsup;  logic [25:0] rec_col_tags;   // (0.16)
    logic [31:0] rec_nuit, rec_ts;  logic [3:0] rec_ps_a, rec_ps_b;  logic [32:0] rec_pts, rec_pts_b;
    recon_out #(.NST(20)) u_out (
        .clk(dclk), .rst_n(fe_rst_dec_n),
        .pinfo_we(po_we), .pinfo_store(po_store), .pinfo_second(po_second), .pinfo_w_mbs(po_w), .pinfo_hf_mbs(po_hf),
        .pinfo_crop(po_crop), .pinfo_aspect(po_aspect), .pinfo_colour(po_colour), .pinfo_col_unsup(po_col_unsup),
        .pinfo_col_tags(po_col_tags), .pinfo_siting(po_siting), .pinfo_timing_v(po_timing_v), .pinfo_nuit(po_nuit),
        .pinfo_ts(po_ts), .pinfo_ps(po_ps), .pinfo_ps_v(po_ps_v), .pinfo_pts(po_pts), .pinfo_pts_v(po_pts_v),
        .pinfo_idr(po_idr), .emit_valid(po_valid), .emit_store(po_estore), .emit_unpaired(po_unpaired),
        .emit_first_bot(po_first_bot), .emit_frame(po_frame), .emit_dec_t(po_dec_t), .emit_dec_b(po_dec_b),
        .eos_done(po_eos_done), .oq_hold, .n_emit, .n_rel, .rec_ovf, .rel_bad,
        .sclk(clk), .srst_n(fe_rst_n), .rec_valid, .rec_more, .rec_take, .rec_end, .rec_store, .rec_frame,
        .rec_unpaired, .rec_first_bot, .rec_dec_t, .rec_dec_b, .rec_w_mbs(rec_w), .rec_hf_mbs(rec_hf),
        .rec_crop, .rec_aspect, .rec_colour, .rec_col_unsup, .rec_col_tags, .rec_timing_v, .rec_nuit, .rec_ts, .rec_ps_a, .rec_ps_a_v, .rec_ps_b, .rec_ps_b_v,
        .rec_pts, .rec_pts_v, .rec_pts_b, .rec_pts_b_v, .rec_idr, .rel_valid, .rel_store);
    // word 84's snapshot, as emu's pic_xing
    logic [19:0] pic_held_s;  logic [31:0] pic_emitted_s;
    cdc_snap #(.W(52)) u_px (.src_clk(dclk), .src_rst_n(lock_dec_n), .src_data({oq_hold, pic_emitted}),
                             .dst_clk(clk), .dst_rst_n(lock_n), .dst_data({pic_held_s, pic_emitted_s}), .dst_tick());
    // +ack_delay: pd_ack reaches the parser late (a stretched hand-over); it falls at once
    int ack_cnt = 0;
    always @(posedge clk) begin
        if (!pd_ack) begin ack_cnt <= 0; pd_ack_d <= 1'b0; end
        else if (ack_cnt < ack_delay) ack_cnt <= ack_cnt + 1;
        else pd_ack_d <= 1'b1;
    end
    initial pd_ack_d = 1'b0;
    // [mux]: recon_top's side passes through pic_in until a picture stream's first PICTURE (its size
    // fields tied to constants here: recon_out sees them while sel is low)
    always @(posedge dclk)
        if (lock_dec_n && fe_rst_dec_n && !u_pic.sel && (po_w !== 8'hA5 || po_hf !== 8'h5A))
            fail("mux", $sformatf("a coded stream: recon_out given w %h hf %h, not recon_top's A5 / 5A", po_w, po_hf));
    // [hold]: pic_emitted steps on the edge recon_out raises the emitted store's hold
    logic [31:0] pe_q = '0;  logic [19:0] oh_q = '0;  logic ev_q = 1'b0;  logic [4:0] es_q = '0;
    always @(posedge dclk) begin
        if (lock_dec_n && fe_rst_dec_n) begin
            if (ev_q && (pic_emitted !== pe_q + 32'd1 || oq_hold[es_q] !== 1'b1 || oh_q[es_q] !== 1'b0))
                fail("hold", $sformatf("an emission of store %0d: pic_emitted %0d -> %0d, its hold %b -> %b", es_q, pe_q,
                     pic_emitted, oh_q[es_q], oq_hold[es_q]));
            if (!ev_q && pic_emitted !== pe_q) fail("hold", "pic_emitted stepped without an emission");
        end
        pe_q <= pic_emitted; oh_q <= oq_hold; ev_q <= po_valid; es_q <= po_estore;
    end
    // the stand-in display: each record checked against pics.hex, taken, and the store taken
    // before it released; the END taken ends the stream (disp_ended)
    int pq = 0, n_pics = 0;
    logic        have_prev = 1'b0;  logic [4:0] prev_store = '0;
    logic        pic_ended = 1'b0, taking = 1'b0;
    task automatic pic_got(input logic [63:0] item, input string what);
        if (pics_q[pq] !== item) fail("pics", $sformatf("picture item %0d (%s): got %h, want %h", pq, what, item, pics_q[pq]));
        pq++;
    endtask
    always @(posedge clk) begin
        rec_take <= 1'b0; rel_valid <= 1'b0; taking <= 1'b0;
        if (!fe_rst_n) begin have_prev <= 1'b0; pic_ended <= 1'b0; end
        else if (rec_valid && !rec_take && !taking) begin
            taking <= 1'b1; rec_take <= 1'b1;
            if (rec_end) begin pic_got(64'h16 << 56, "END"); pic_ended <= 1'b1; end
            else begin
                pic_got({8'h11, 26'd0, rec_pts_v, rec_ps_a_v, rec_ps_a, rec_timing_v, rec_hf, rec_w, rec_first_bot, rec_frame, rec_store}, "record");
                pic_got({8'h12, 12'd0, rec_colour, rec_crop}, "crop / colour");   // 0.16: [43:41] the resolved colour code
                if (rec_col_unsup !== 1'b0 || rec_col_tags !== {1'b0, 1'b0, 8'd2, 8'd2, 8'd2})
                    fail("pics", $sformatf("a program's picture: col_unsup %b, tags %h (want 0, no colour description)", rec_col_unsup, rec_col_tags));
                pic_got({8'h13, 16'd0, rec_aspect}, "aspect");
                pic_got({rec_ts, rec_nuit}, "timing");
                pic_got({8'h15, 23'd0, rec_pts}, "PTS");
                if (rec_unpaired !== 1'b0 || rec_dec_t !== 1'b1 || rec_dec_b !== 1'b1 || rec_idr !== 1'b0)
                    fail("pics", "unpaired / dec_t / dec_b / idr");
                if (!rec_frame && (rec_ps_b_v !== 1'b0 || rec_pts_b_v !== 1'b0 || rec_ps_b !== 4'd0 || rec_pts_b !== 33'd0))
                    fail("pics", $sformatf("a pair's second half carries pic_struct %b/%h or a PTS %b/%h", rec_ps_b_v, rec_ps_b, rec_pts_b_v, rec_pts_b));
                n_pics++;
                if (have_prev) begin rel_valid <= 1'b1; rel_store <= prev_store; end
                have_prev <= 1'b1; prev_store <= rec_store;
            end
        end
        if (rec_ovf === 1'b1 || rel_bad === 1'b1) fail("pics", "recon_out: an overflow or a bad release");
    end

    // ---- interface 0.4: the settings request, end to end -- osd_req, and a stand-in for Main
    // that adopts status_in when status_set rises (the menu starts at R18's constants); word
    // 27's mirror reads that menu, so R22 scores the request's effect against the model
    logic [127:0] menu, status_in;  logic status_set;  logic [7:0] set_seq;  logic [2:0] set_err;
    initial begin
        menu = '0;
        menu[2:1] = 2'd2; menu[4:3] = 2'd1; menu[6:5] = 2'd2; menu[7] = 1'b1; menu[9:8] = 2'd3;
        menu[12:11] = 2'd1; menu[16:15] = 2'd2;
    end
    always @(posedge clk) if (status_set) menu <= status_in;
    osd_req u_req (.clk, .rst_n(core_n), .status(menu), .set_word, .set_tog, .status_in, .status_set,
                   .seq(set_seq), .err(set_err), .n_applied());

    // ---- the status block ----
    logic frame = 1'b0;
    int fcnt = 0;
    always @(posedge clk) begin
        fcnt <= (fcnt == FRAME_T - 1) ? 0 : fcnt + 1;
        frame <= (fcnt == 0);
    end

    logic [31:0] seq, n_skips;
    logic [6:0]  sys_ix;                 // 0.10: 7 bits (words 80-87)
    logic [5:0]  mem_ix, dec_ix;
    logic [63:0] sys_word, mem_word, dec_word;
    localparam logic [31:0] K_FETCH = 32'hF00D_0001, K_PWR = 32'h0000_1234, K_PRD = 32'h0000_5678;
    // 0.6: the input region beside the frame's words (its own bench is run_ring_in.sh; here it
    // runs idle but for its heartbeat, with distinct pad words, so its groups interleave with
    // the frame's while the ring streams)
    logic in_req, in_go, in_busy;  logic [4:0] in_ix;  logic [63:0] in_word;
    localparam logic [191:0] K_JOY = {32'hB5B5_0005, 32'hB4B4_0004, 32'hB3B3_0003, 32'hB2B2_0002, 32'hB1B1_0001, 32'hB0B0_0000};
    localparam logic [95:0]  K_AL  = {16'hC5C5, 16'hC4C4, 16'hC3C3, 16'hC2C2, 16'hC1C1, 16'hC0C0};
    localparam logic [95:0]  K_AR  = {16'hD5D5, 16'hD4D4, 16'hD3D3, 16'hD2D2, 16'hD1D1, 16'hD0D0};
    ring_in #(.MIN_GAP(700)) u_in (
        .clk, .rst_n(lock_n), .frame(frame), .joy(K_JOY), .ana_l(K_AL), .ana_r(K_AR),
        .ps2_key(11'd0), .ps2_mouse(25'd0), .ps2_mouse_ext(16'd0), .osd(1'b0), .act(2'b00),
        .in_req, .in_go, .in_busy, .in_ix, .in_word, .n_events());
    ring_stat u_stat (
        .clk, .rst_n(lock_n), .frame(frame), .st_free, .seq, .n_skips,
        .sys_ix, .sys_word, .mclk, .mrst_n(lock_n), .mem_ix, .mem_word,
        .dclk, .drst_n(lock_n), .dec_ix, .dec_word,
        .in_req, .in_go, .in_busy, .in_ix, .in_word,
        .st_word, .st_ix, .st_wr, .st_grp);
    ring_words_sys u_ws (
        .ix(sys_ix), .f_seq_head(seq), .f_state(state), .f_err(err), .f_live({gfx_mode, sess, 1'b0, 1'b0, 1'b0, disp_ended, eos_seen, ll_mode}),
        .f_osd(8'h5A), .f_err_pos(err_pos), .f_err_word(err_word), .f_stc(33'h1_2345_6789), .f_lag_ms(16'hFFFE),
        .f_n_au(n_au), .f_n_audio(n_audio), .f_n_pad(n_pad), .f_n_streams(n_streams), .f_es_bytes(es_bytes),
        .f_ll_mismatch(ll_mismatch), .f_disp_dc(32'd11), .f_disp_pick(32'd12), .f_disp_skip(32'd13),
        .f_disp_late(16'd14), .f_disp_starve(16'd15), .f_disp_cadence(16'd16), .f_disp_reanchor(8'd17),
        .f_disp_flags(3'd5), .f_disp_lone(4'd9),   // 0.7: word 27 [30:27]
        // interface 0.4: word 27, the OSD mirror (distinct values) and the GRAPHICS mismatch count
        .f_osd_aspect(menu[2:1]), .f_osd_deint(menu[4:3]), .f_osd_video_out(menu[6:5]), .f_osd_hdmi_deint(menu[7]),
        .f_osd_analog_aspect(menu[9:8]), .f_osd_refresh(menu[12:11]), .f_osd_anti_twitter(menu[16:15]),
        .f_gfx_mismatch(gfx_mismatch), .f_set_seq(set_seq), .f_set_err(set_err),
        // interface 0.3: word 30's raster report (connected since 0.4: it floated in this bench)
        .f_raster_std(2'd2), .f_raster_il(1'b1), .f_raster_auto(1'b0), .f_anti_twitter(1'b1),
        // interface 0.2: word 30, the fit (distinct values: each field lands where the layout says)
        .f_disp_fetch_late(16'd18), .f_fit_crop_bad(1'b1), .f_fit_clamp(1'b0), .f_fit_snap(1'b1),
        .f_fit_ow(13'd719), .f_fit_oh(13'd401), .f_fit_valid(1'b1), .f_seq_tail(seq),   // 0.17: fit_valid [45]
        // interface 0.5: words 40-45 (the audio path's fields are the bench's constants; the
        // pause word's and the held bytes are ring_rd's own)
        .f_aud_state(2'd1), .f_aud_ll(1'b1), .f_aud_q_rec(9'd257), .f_aud_q_samples(32'hA0A0_0001),
        .f_aud_played(32'hA0A0_0002), .f_aud_records(32'hA0A0_0003), .f_aud_gap(32'hA0A0_0004),
        .f_aud_late(32'hA0A0_0005), .f_aud_underruns(16'hA006), .f_aud_slip_drop(16'hA007),
        .f_aud_slip_rep(16'hA008), .f_aud_anchor(16'hA009), .f_aud_offset(32'hA0A0_000A),
        .f_aud_hold_bytes(hold_bytes), .f_paused(ctl_pause), .f_ctl_err(ctl_err), .f_atten(ctl_atten),
        // 0.9: the overlay's status, distinct constants (each field where the layout puts it)
        .f_ovl_gen(32'hB0B0_0001), .f_ovl_state(2'd2), .f_ovl_at(1'b1), .f_ovl_clip(1'b0), .f_ovl_err(4'd6),
        .f_ovl_torn(8'hB2), .f_ovl_late(16'hB003), .f_ar_x(12'h123), .f_ar_y(12'h456), .f_ovl_lines(32'hB0B0_0004),
        // 0.10: word 80, the raster, distinct constants (pic_x0 negative: two's complement)
        .f_raster_w(12'hC81), .f_raster_h(12'h3C2), .f_raster_mode(2'd2), .f_raster_lb(1'b1),
        .f_video_out(2'd3),                                              // 0.14: word 80 [28:27]
        .f_colour(3'd5),                                                 // 0.16: word 80 [31:29]
        .f_pic_x0(13'h1F85), .f_pic_y0(13'h0A3),
        // 0.13: words 82-83, ring_rd's own (0 but in R27, which scores them)
        .f_rum_p0(rumble[15:0]), .f_rum_p1(rumble[31:16]), .f_rum_p2(rumble[47:32]), .f_rum_p3(rumble[63:48]),
        .f_rum_p4(rumble[79:64]), .f_rum_p5(rumble[95:80]), .f_rum_changes(rum_changes),
        .f_pic_held(pic_held_s), .f_pic_mode(pic_mode), .f_pic_emitted(pic_emitted_s),     // 0.15: word 84
        .f_disp_fhold(32'd0),                                                            // 0.15: word 85 (no display here)
        // 0.16: word 86, distinct constants but the stream's own (ring_rd's override and mismatch count)
        .f_vui_matrix(8'hD1), .f_vui_primaries(8'hD2), .f_vui_transfer(8'hD3), .f_vui_full_range(1'b1),
        .f_vui_colour_present(1'b0), .f_colour_override(colour_mode != 3'd0), .f_colour_unsup(16'hD004),
        .f_colour_mismatch(colour_mismatch),
        .w(sys_word));
    ring_words_mem u_wm (
        .ix(mem_ix), .f_read_index(read_index), .f_ack_nonce(ack_nonce), .f_n_polls(n_polls), .f_n_bursts(n_bursts),
        .f_eng_err(eng_err), .f_eng_session(eng_session), .f_eng_widx(eng_widx), .f_fetch_changes(K_FETCH),
        .f_probe_busy(16'd3), .f_probe_wr(K_PWR), .f_probe_rd(K_PRD), .f_probe_owed(16'd7), .f_probe_busy_max(16'd9),
        .w(mem_word));
    function automatic logic [63:0] dec_fn(input logic [5:0] ix);
        return {8'hDE, 3'd0, ix, 16'h0C0D, 27'd0, ix};
    endfunction
    assign dec_word = RI_DEC_WORDS[dec_ix] ? dec_fn(dec_ix) : 64'd0;

    // ---- ram1: master A (random traffic) + master B (the reader) -> ddr_model ----
    logic [28:0] a_address;  logic [7:0] a_burstcount;  logic a_read = 0, a_write = 0, a_waitrequest, a_readdatavalid;
    logic [63:0] a_writedata, a_readdata;
    logic [28:0] ddr_address;  logic [7:0] ddr_burstcount, ddr_byteenable;  logic ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
    logic [63:0] ddr_writedata, ddr_readdata;
    int unwritten;
    ddr_mux2 u_mux (
        .clk(mclk), .rst_n(lock_n),
        .a_address, .a_burstcount, .a_read, .a_write, .a_writedata, .a_byteenable(8'hFF), .a_abort(1'b0),
        .a_waitrequest, .a_readdata, .a_readdatavalid,
        .b_address, .b_burstcount, .b_read, .b_write, .b_writedata, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid);
    ddr_model #(.BASE(CTRL), .AW(11)) ddr (
        .clk(mclk), .rst_n(1'b1), .address(ddr_address), .burstcount(ddr_burstcount), .read(ddr_read), .write(ddr_write),
        .writedata(ddr_writedata), .byteenable(ddr_byteenable), .waitrequest(ddr_waitrequest),
        .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));

    // master A: a read or a write burst of 1-8 beats in its own region, one at a time
    int a_owed = 0, a_beats = 0;
    always @(posedge mclk) begin
        if (!lock_n) begin a_read <= 0; a_write <= 0; a_owed = 0; a_beats = 0; end
        else begin
            if (a_readdatavalid) a_owed = a_owed - 1;
            if (a_read && !a_waitrequest) begin
                a_read <= 0; a_owed = a_owed + a_burstcount;
            end else if (a_write && !a_waitrequest) begin
                a_beats = a_beats - 1;
                if (a_beats == 0) a_write <= 0; else a_writedata <= {$urandom, $urandom};
            end else if (!a_read && !a_write && a_owed == 0 && $urandom_range(0, 99) < a_pct) begin
                a_address <= CTRL + 29'd1024 + 29'($urandom_range(0, 1000));
                if ($urandom_range(0, 1)) begin a_burstcount <= 8'($urandom_range(1, 8)); a_read <= 1; end
                else begin
                    a_beats = $urandom_range(1, 8);
                    a_burstcount <= 8'(a_beats); a_write <= 1; a_writedata <= {$urandom, $urandom};
                end
            end
        end
    end

    // ---- the decoder's side: random ready; the delivered stream against the model ----
    int ep = 0;                    // the next expected item
    int pre_end = -1;              // inside a PREFIX section: where it ends
    bit pre_cut = 0;               // ... and it must stop early
    logic clr_q = 0, eos_q = 0;
    bit stream_complete = 0;       // R1 reached its expected sentinel before the geometry protocol
    bit geom_reset_expected = 0;   // the one reset caused by R1's fresh-nonce baseline
    bit geom_reset_seen = 0;
    int ended_at = -1;
    int n_items = 0;
    always @(posedge clk) es_ready <= ($urandom_range(0, 99) < ready_pct);

    // ---- 0.5: the audio path, stood in for: each descriptor is checked in the stream's order
    // (with the bytes), queued (at most AQ records: the parser must wait at a full queue),
    // fetched through the engine a burst at a time, every word checked against the payloads
    // the program wrote, then released after aud_delay cycles (the held read index). A read
    // index released early lets the producer overwrite a record before its fetch: [audio]. ----
    localparam int AQ = 6;
    logic [31:0] aq_pos [0:AQ-1];  logic [22:0] aq_len [0:AQ-1];
    longint      aq_t [0:AQ-1];                // the cycle its descriptor arrived
    longint      cyc = 0;
    int          aq_n = 0, aq_h = 0;           // queued records (fetching or waiting to release)
    int          af_rec = 0;                   // the queued record being fetched (index from aq_h)
    int          af_left = 0;                  // its words not yet asked for
    logic [31:0] af_next = '0;                 // ... the next one's ring index
    longint      af_owed = 0;                  // words asked for, not yet taken
    int          rel_t = -1;                   // the head's release countdown (-1: not fetched)
    int          aw = 0;                       // the next audio.hex word
    logic        af_pend = 1'b0;
    int          a_fetched = 0;                // words of the head record... fetched and checked
    assign ad_room  = (aq_n < AQ);
    assign aud_idle = (aq_n == 0);
    assign a_hold_v = (aq_n != 0);
    assign a_hold_idx = aq_pos[aq_h];
    assign af_rd    = !af_empty && !af_pend && af_owed > 0;
    always @(posedge clk) cyc <= cyc + 1;
    always @(posedge clk) begin
        // 0.5: a DISCONTINUITY after END_OF_STREAM waits for the queued audio to play out
        if (stream_clr && !clr_q && eos_q && aq_n != 0)
            fail("audio", $sformatf("the stream reset after END_OF_STREAM cut %0d queued AUDIO records", aq_n));
        if (!core_n || stream_clr) begin
            aq_n = 0; aq_h = 0; af_rec = 0; af_left = 0; rel_t = -1; af_go <= 1'b0;
        end else if (lock_n) begin
            af_go <= 1'b0;
            if (ad_push) begin
                if (aq_n >= AQ) fail("audio", "a descriptor pushed into a full queue (ad_room low)");
                got({8'h06, ad_len, ad_pts}, "audio");
                got({8'h07, 23'd0, ad_ptsv, ad_pos}, "audio");
                aq_pos[(aq_h + aq_n) % AQ] = ad_pos; aq_len[(aq_h + aq_n) % AQ] = ad_len; aq_t[(aq_h + aq_n) % AQ] = cyc;
                if (ad_len == 0 || ad_len[1:0] != 0) fail("audio", $sformatf("a descriptor of %0d bytes", ad_len));
                aq_n++;
            end
            // the fetch: the next queued record's words, eight at a time (af_go one cycle; the
            // engine's af_busy rises the cycle after it)
            if (af_left == 0 && af_rec < aq_n && cyc - aq_t[(aq_h + af_rec) % AQ] >= aud_wait) begin
                af_left = (aq_len[(aq_h + af_rec) % AQ] + 7) / 8;
                af_next = aq_pos[(aq_h + af_rec) % AQ] + 32'd16;
            end
            if (af_left > 0 && !af_busy && !af_go && af_owed + 8 <= 256) begin
                int n;
                n = (af_left > 8) ? 8 : af_left;
                af_go <= 1'b1; af_n <= 4'(n); af_addr <= af_next;
                af_next = af_next + 32'(8 * n);
                af_owed += n; af_left -= n;
                if (af_left == 0) af_rec++;
            end
            // the release: the head, aud_delay cycles after all its words were checked
            if (aq_n > 0 && af_rec > 0 && rel_t < 0 && a_fetched >= (aq_len[aq_h] + 7) / 8 && af_owed == 0)
                rel_t = aud_delay;
            if (rel_t > 0) rel_t--;
            else if (rel_t == 0) begin
                a_fetched -= (aq_len[aq_h] + 7) / 8;
                aq_h = (aq_h + 1) % AQ; aq_n--; af_rec--; rel_t = -1;
            end
        end
    end
    // the words back, against the payloads
    always @(posedge clk) begin
        if (af_rd) af_pend <= 1'b1;
        if (af_valid && af_pend) begin
            af_pend <= 1'b0; af_owed = af_owed - 1;
            if (af_dout !== audio_q[aw]) fail("audio", $sformatf("audio word %0d: %h, the program wrote %h", aw, af_dout, audio_q[aw]));
            aw++; a_fetched++;
        end
    end

    function automatic int find_prefix_end(input int from);
        int i;
        for (i = from; expect_q[i][63:56] != 8'h05; i++) ;
        return i;
    endfunction

    task automatic got(input logic [63:0] item, input string what);
        logic [63:0] e;
        e = expect_q[ep];
        if (e[63:56] == 8'h04) begin pre_cut = e[0]; ep++; pre_end = find_prefix_end(ep); e = expect_q[ep]; end
        if (e !== item && pre_end >= 0) begin              // a replaced session: the rest of the section is skipped
            ep = pre_end + 1; pre_end = -1; e = expect_q[ep];
            if (e[63:56] == 8'h04) begin pre_cut = e[0]; ep++; pre_end = find_prefix_end(ep); e = expect_q[ep]; end
        end
        if (e !== item) begin
            fail(item[63:56] == 8'h01 ? "bytes" : "events",
                 $sformatf("item %0d: got %s %h, want %h", n_items, what, item, e));
        end else begin
            ep++;
            if (pre_end >= 0 && ep == pre_end) begin
                if (pre_cut) fail("events", "the replaced session ran to its end: the switch was not prompt (the slow poll)");
                ep++; pre_end = -1;
            end
        end
        n_items++;
    endtask

    always @(posedge clk) begin
        clr_q <= stream_clr; eos_q <= eos;
        if (lock_n) begin
            if (stream_clr && !clr_q) begin
                if (!stream_complete) got(64'h02 << 56, "reset");
                else if (geom_reset_expected && !geom_reset_seen) geom_reset_seen = 1;
                else fail("events", "unexpected stream reset after the R1 completion sentinel");
            end
            if (eos && !eos_q) begin
                if (!stream_complete) got(64'h03 << 56, "eos");
                else fail("events", "unexpected EOS after the R1 completion sentinel");
            end
            if (es_valid && es_ready) begin
                if (!stream_complete) got({8'h01, 13'd0, es_pts, es_au_end, es_mark, es_byte}, "byte");
                else fail("events", "unexpected byte after the R1 completion sentinel");
            end
        end
        // the display takes the END a little after the flush (0.15: a picture stream's END is the
        // stand-in display's); a stream reset clears it
        if (stream_clr || !core_n) begin disp_ended <= 1'b0; ended_at <= -1; end
        else if (eos && !eos_q) ended_at <= 300;
        else if (ended_at > 0) ended_at <= ended_at - 1;
        else if (ended_at == 0 || pic_ended) disp_ended <= 1'b1;
    end
    initial disp_ended = 1'b0;

    // ---- [avalon] at master B itself: ddr_model polices the port, but a command B withdraws
    // while the mux holds it off never reaches the port (the reader must not do it either:
    // ddr_mux2 has no abort for B) ----
    logic        bp_valid = 1'b0, bp_rd, bp_wr;
    logic [28:0] bp_a;  logic [7:0] bp_bc;  logic [63:0] bp_wd;
    always @(posedge mclk) begin
        if (bp_valid && (b_read !== bp_rd || b_write !== bp_wr || b_address !== bp_a || b_burstcount !== bp_bc ||
                         (bp_wr && b_writedata !== bp_wd)))
            fail("avalon", $sformatf("master B %0s its %0s under waitrequest (address %h)",
                 (b_read || b_write) ? "changed" : "withdrew", bp_rd ? "read" : "write", bp_a));
        bp_valid <= lock_n && (b_read || b_write) && b_waitrequest;
        bp_rd <= b_read; bp_wr <= b_write; bp_a <= b_address; bp_bc <= b_burstcount; bp_wd <= b_writedata;
    end

    // ---- a session change is seen promptly: the engine acknowledges a new nonce within the
    // slow poll period (plus the clear), even when it is behind (R13 runs the decoder stalled) ----
    logic [31:0] want_nonce = 32'd0;
    int          nonce_age = -1;
    always @(posedge mclk) begin
        if (nonce_age >= 0) begin
            if (ack_nonce === want_nonce) nonce_age <= -1;
            else begin
                nonce_age <= nonce_age + 1;
                if (nonce_age == POLL_SLOW + 1000 + 4 * ack_delay)   // 0.15: a stretched hand-over defers the clear
                    fail("poll", $sformatf("a new nonce took over %0d clk_mem cycles to be acknowledged (slow poll %0d)",
                         nonce_age, POLL_SLOW));
            end
        end
    end

    // ---- an error the model did not predict fails at once (a later hang would hide it) ----
    logic [7:0] exp_err = 8'd0;
    bit         err_seen = 0;
    bit         errs_any = 0;              // (0.15) +errs_any: a scenario of many sessions, each ending in its
                                           // own error (R29) -- each waited for by its code (a wrong one hangs)
    always @(posedge clk)
        if (lock_n && err !== 8'd0 && err !== exp_err && !err_seen && !errs_any) begin
            err_seen <= 1;
            fail("final", $sformatf("unexpected error %0d at %h (word %h); the model's is %0d", err, err_pos, err_word, exp_err));
        end

    // ---- polls in idle windows ----
    int win_polls = 0, win_mem = 0;
    bit in_win = 0;
    always @(posedge mclk) begin
        if (in_win) begin
            win_mem++;
            if (b_read && !b_waitrequest && b_address == CTRL + 29'd32) win_polls++;
        end
    end

    // ---- the status block, read as a program reads it ----
    function automatic logic [63:0] cw(input int w);
        return ddr.peek(CTRL + 29'(w));
    endfunction

    function automatic logic [31:0] cw_lo(input int w);
        logic [63:0] v; v = ddr.peek(CTRL + 29'(w)); return v[31:0];
    endfunction
    function automatic logic [31:0] cw_hi(input int w);
        logic [63:0] v; v = ddr.peek(CTRL + 29'(w)); return v[63:32];
    endfunction

    int step_i;
    int t0;
    initial begin
        logic [63:0] op, v, fv;
        logic [7:0] code;
        int n, spins;
        if (!$value$plusargs("stem=%s", stem)) begin $display("FAIL [harness] +stem"); $fatal(1); end
        if (!$value$plusargs("arm=%s", arm)) arm = "?";
        void'($value$plusargs("ready_pct=%d", ready_pct));
        void'($value$plusargs("a_pct=%d", a_pct));
        void'($value$plusargs("aud_delay=%d", aud_delay));
        void'($value$plusargs("aud_wait=%d", aud_wait));
        void'($value$plusargs("ack_delay=%d", ack_delay));
        if ($test$plusargs("errs_any")) errs_any = 1;
        for (int i = 0; i < 256; i++) final_q[i] = 64'hX;
        $readmemh({stem, ".steps.hex"}, steps);
        $readmemh({stem, ".expect.hex"}, expect_q);
        $readmemh({stem, ".final.hex"}, final_q);
        $readmemh({stem, ".audio.hex"}, audio_q);
        $readmemh({stem, ".pics.hex"}, pics_q);
        for (int i = 0; final_q[i] !== 64'hX; i += 2)
            if (final_q[i][23:0] === 24'h040808) exp_err = final_q[i + 1][7:0];     // the "err" field (word 4 [8 +: 8])
        repeat (5) @(posedge clk);
        step_i = 0;
        forever begin
            op = steps[step_i]; step_i++;
            code = op[63:56]; n = op[55:32];
            case (code)
                8'd1: begin for (int i = 0; i < n; i++) ddr.poke(29'(op[31:0]) + 29'(i), steps[step_i + i]); step_i += n; end
                8'd2: ddr.poke(CTRL + 29'd32, {32'd0, op[31:0]});
                8'd3: begin
                        ddr.poke(CTRL + 29'd33, {32'd0, op[31:0]});
                        if (eng_session) begin want_nonce = op[31:0]; nonce_age = 0; end   // a running session replaced
                      end
                8'd4: begin spins = 0;
                        while ($signed(op[31:0] - cw_lo(5)) > 0) begin
                            @(posedge clk); spins++;
                            if (spins > 2000000) begin fail("hang", $sformatf("read index %h never reached %h", cw_lo(5), op[31:0])); $fatal(1); end
                        end
                      end
                8'd5: begin spins = 0;
                        while (cw_hi(5) !== op[31:0]) begin
                            @(posedge clk); spins++;
                            if (spins > 200000) begin fail("hang", $sformatf("ack %h never became %h (dut ack %h sess %b polls %0d seq %0d es %0d ps %0d skips %0d cw3 %h)", cw_hi(5), op[31:0], ack_nonce, eng_session, n_polls, seq, dut.es, dut.ps, n_skips, cw_lo(3))); $fatal(1); end
                        end
                      end
                8'd6: begin
                        if (op[31:0] >= 10 * POLL_SLOW / 3 && ep > 0) begin in_win = 1; win_polls = 0; win_mem = 0; end
                        repeat (op[31:0]) @(posedge clk);
                        if (in_win) begin
                            in_win = 0;
                            if (win_polls > win_mem / POLL_FAST + 2) fail("poll", $sformatf("%0d polls in %0d idle clk_mem cycles (fast period %0d)", win_polls, win_mem, POLL_FAST));
                            if (win_polls == 0) fail("poll", $sformatf("no poll in %0d clk_mem cycles", win_mem));
                        end
                      end
                8'd7: begin core_n = 1'b0; repeat (20) @(posedge clk); core_n = 1'b1; end
                8'd8: begin spins = 0;
                        while ((cw_lo(4) & 32'hFF) !== {24'd0, op[7:0]}) begin
                            @(posedge clk); spins++;
                            if (spins > 400000) begin fail("hang", $sformatf("state %0d never became %0d (err %0d)", (cw_lo(4) & 32'hFF), op[7:0], ((cw_lo(4) >> 8) & 32'hFF))); $fatal(1); end
                        end
                      end
                8'd9: break;
                8'd10: begin repeat (3) @(posedge clk); lock_n = 1'b1; core_n = 1'b1; end
                8'd11: begin                          // 0.5: STILL -- nothing delivered, the index unmoved
                        int items0;  logic [31:0] r0;
                        items0 = n_items; r0 = cw_lo(5);
                        repeat (op[31:0]) @(posedge clk);
                        if (n_items != items0) fail("pause", $sformatf("%0d items delivered while paused", n_items - items0));
                        if (cw_lo(5) !== r0) fail("pause", $sformatf("the read index moved %h -> %h while paused", r0, cw_lo(5)));
                      end
                8'd12: begin                          // 0.5: WAIT_FIELD
                        logic [63:0] fw, fv2;  int w, lsb, width;
                        fw = steps[step_i]; step_i++;
                        w = fw[55:48]; lsb = fw[47:40]; width = fw[39:32];
                        spins = 0;
                        do begin
                            @(posedge clk); spins++;
                            fv2 = cw(w) >> lsb;
                            if (width < 64) fv2 = fv2 & ((64'd1 << width) - 1);
                            if (spins > 400000) begin fail("hang", $sformatf("word %0d [%0d +: %0d] = %h never became %h", w, lsb, width, fv2, fw[31:0])); $fatal(1); end
                        end while (fv2 !== {32'd0, fw[31:0]});
                      end
                default: begin $display("FAIL [harness] step %0d op %h", step_i - 1, op); $fatal(1); end
            endcase
        end
        // everything expected delivered (0.15: and every picture presented)
        spins = 0;
        while (pics_q[pq][63:56] != 8'hFF) begin
            @(posedge clk); spins++;
            if (spins > 400000) begin fail("pics", $sformatf("stopped at picture item %0d (%h) after %0d pictures", pq, pics_q[pq], n_pics)); break; end
        end
        spins = 0;
        while (expect_q[ep][63:56] != 8'hFF && !(expect_q[ep][63:56] == 8'h05)) begin
            @(posedge clk); spins++;
            if (spins > 400000) begin fail("missing", $sformatf("stopped at expected item %0d (%h) after %0d items", ep, expect_q[ep], n_items)); break; end
        end
        repeat (3 * FRAME_T) @(posedge clk);
        // a consistent copy of the status block (seqlock), and a later one
        begin
            logic [63:0] img [0:87];
            logic [31:0] s1;
            spins = 0;
            do begin
                if (spins) repeat (40) @(posedge clk);       // a frame's write was in progress: retry later
                s1 = cw_lo(31);
                for (int w = 0; w < 48; w++) img[w] = cw(w);
                for (int w = 80; w < 88; w++) img[w] = cw(w);   // 0.10: the third region
                spins++;
            end while (cw_lo(3) !== s1 && spins < 100);
            if (img[3][31:0] !== img[31][31:0]) fail("seqlock", $sformatf("seq_head %h and seq_tail %h never agreed", img[3], img[31]));
            repeat (2 * FRAME_T) @(posedge clk);
            if (cw_lo(3) === s1) fail("seqlock", "the heartbeat stands still");
            // the constants and snapshot words
            if (img[0] !== RI_MAGIC) fail("words", $sformatf("magic %h", img[0]));
            if (img[1][15:0] !== RI_VERSION || img[2] !== {RI_RING_SIZE, RI_RING_BYTE}) fail("words", "version / geometry");
            for (int w = 0; w < 48; w++)
                if (RI_DEC_WORDS[w] && img[w] !== dec_fn(6'(w))) fail("words", $sformatf("clk_dec word %0d = %h", w, img[w]));
            // 0.5: the second region, each field where the layout puts it, and word 1's pointer to it
            if (img[1][63:48] !== 16'd40) fail("words", "word 1's core2_word (0.5)");
            if (img[40] !== {32'hA0A0_0001, 7'd0, 9'd257, 13'd0, 1'b1, 2'd1} || img[41] !== {32'hA0A0_0003, 32'hA0A0_0002} ||
                img[42] !== {32'hA0A0_0005, 32'hA0A0_0004} || img[43] !== {16'hA009, 16'hA008, 16'hA007, 16'hA006} ||
                img[44][31:0] !== 32'hA0A0_000A)
                fail("words", $sformatf("words 40-47 (0.5): %h %h %h %h %h", img[40], img[41], img[42], img[43], img[44]));
            // 0.9: words 46-47, the overlay's status
            if (img[46] !== {16'hB003, 8'hB2, 4'd6, 1'b0, 1'b1, 2'd2, 32'hB0B0_0001} ||
                img[47] !== {32'hB0B0_0004, 8'd0, 12'h456, 12'h123})
                fail("words", $sformatf("words 46-47 (0.9): %h %h", img[46], img[47]));
            // 0.10: word 80, the raster (written under the same seqlock); 0.11: word 81, the
            // capabilities (constants: 3,600 macroblocks, 720 lines native, 108,000 a second); 0.13: 82-83
            // the rumble (no scenario but R27 writes it: 0, nothing counted); 0.15: word 84's constant
            // (the rest by the scenario's final fields); 85 the bench's 0; 86 (0.16) its constants but the
            // stream's own bits (colour_override [26], colour_mismatch [63:48]: the final fields); 87 reserved 0
            if (img[80] !== {3'd0, 13'h0A3, 3'd0, 13'h1F85, 3'd5, 2'd3, 1'b1, 2'd2, 12'h3C2, 12'hC81})   // 0.14: video_out [28:27]; 0.16: colour [31:29]
                fail("words", $sformatf("word 80 (0.10): %h", img[80]));
            if ((img[86] & 64'h0000_FFFF_FBFF_FFFF) !== 64'h0000_D004_01D3_D2D1)
                fail("words", $sformatf("word 86 (0.16, the colour): %h", img[86]));
            if (img[81] !== {32'd108000, 4'd0, 12'd720, 16'd3600})   // 0.12: cap_native_h 720
                fail("words", $sformatf("word 81 (0.11, the capabilities): %h", img[81]));
            if (arm != "R27" && (img[82] !== 64'd0 || img[83] !== 64'd0))
                fail("words", $sformatf("words 82-83 (0.13, the rumble) = %h %h with nothing written", img[82], img[83]));
            if (img[84][31:21] !== {8'd20, 3'd0}) fail("words", $sformatf("word 84 (0.15): cap_pic_stores %h", img[84]));
            for (int w = 85; w < 88; w++)
                if (w != 86 && img[w] !== 64'd0) fail("words", $sformatf("word %0d (0.10, reserved) = %h", w, img[w]));
            // 0.6: the input region -- its own seqlock, its heartbeat, the pads where the layout puts them
            begin
                logic [63:0] iw [48:71];
                logic [31:0] t1;
                int sp;
                sp = 0;
                do begin
                    if (sp) repeat (40) @(posedge clk);
                    t1 = cw_lo(71);
                    for (int w = 48; w < 72; w++) iw[w] = cw(w);
                    sp++;
                end while (cw_lo(48) !== t1 && sp < 100);
                if (iw[48][31:0] !== iw[71][31:0] || iw[48][31:0] === 32'd0)
                    fail("words", $sformatf("the input region's in_head %h / in_tail %h (0.6)", iw[48], iw[71]));
                for (int n = 0; n < 6; n++)
                    if (iw[49 + n] !== {K_AR[16 * n +: 16], K_AL[16 * n +: 16], K_JOY[32 * n +: 32]})
                        fail("words", $sformatf("pad %0d's word %h (0.6)", n, iw[49 + n]));
                if (iw[48][63:32] !== 32'd0 || iw[64] !== 64'd0 || iw[55] !== 64'd0)
                    fail("words", "the idle input region's events / mouse words (0.6)");
                repeat (2 * FRAME_T) @(posedge clk);
                if (cw_lo(71) === t1) fail("seqlock", "the input region's heartbeat stands still (0.6)");
            end
            if (img[13][31:0] !== K_FETCH || img[28] !== {K_PRD, K_PWR} || img[29][31:0] !== {16'd9, 16'd7})
                fail("words", "clk_mem probe / fetch words");
            if (img[4][31:24] !== 8'h5A || img[27][15:0] !== 16'd16 || img[27][31:24] !== {1'b0, 4'd9, 3'd5})
                fail("words", "clk_sys words (0.7: word 27's disp_flags, disp_lone)");
            if (img[30] !== {3'd0, 13'd401, 2'd0, 1'b1, 13'd719, set_seq, 1'b1, 1'b0, 1'b1, 2'd2, 3'b101, 16'd18})   // 0.17: fit_valid [45]
                fail("words", "word 30 (the fit 0.2, the raster 0.3)");
            // 0.4: the OSD mirror, each option where the layout puts it
            if (arm != "R22" && img[27][44:32] !== {2'd2, 2'd1, 2'd3, 1'b1, 2'd2, 2'd1, 2'd2})
                fail("words", "word 27 (the OSD mirror, 0.4)");     // (R22 changes it: scored by the model)
            // the scenario's fields
            for (int i = 0; final_q[i] !== 64'hX; i += 2) begin
                int w, lsb, width;
                w = final_q[i][23:16]; lsb = final_q[i][15:8]; width = final_q[i][7:0];
                v = img[w] >> lsb;
                if (width < 64) v = v & ((64'd1 << width) - 1);
                fv = final_q[i + 1];
                if (v !== fv) fail("final", $sformatf("word %0d [%0d +: %0d] = %h, want %h", w, lsb, width, v, fv));
            end
        end
        // 1.2: direct RTL protocol exercise after the stream-model assertions. Word 88 may
        // change while word 39's sequence is unchanged; only the sequence commit publishes it.
        // A malformed clip is ACKed with an error and leaves the prior geometry intact. A new
        // nonce baselines the still-present request, so it cannot silently reapply.
        if (arm == "R1") begin
            logic [63:0] geom_req, clip_a, clip_b, clip_bad;
            logic [31:0] new_nonce;
            int gsp;
            if (expect_q[ep][63:56] !== 8'hFF || pre_end >= 0)
                fail("events", $sformatf("R1 stream did not reach its completion sentinel (ep %0d item %h)", ep, expect_q[ep]));
            else stream_complete = 1;
            geom_req = {8'd1, 4'd0, 13'h1FFC, 13'd20, 13'd600, 13'd400};
            clip_a = {16'd0, 12'd400, 12'd600, 12'd30, 12'd20};
            clip_b = {16'd0, 12'd400, 12'd600, 12'd30, 12'd30};
            ddr.poke(CTRL + 29'd88, clip_a);
            ddr.poke(CTRL + 29'd39, geom_req);
            gsp = 0;
            while (geom_ack_seq !== 8'd1 && gsp < 10000) begin @(posedge clk); gsp++; end
            repeat (8) @(posedge clk);
            if (geom_ack_seq !== 8'd1 || geom_error !== 2'd0 || geom_data !== {clip_a, geom_req})
                fail("geometry", $sformatf("valid seq1 ACK/data: ack %0d err %0d data %h", geom_ack_seq, geom_error, geom_data));
            ddr.poke(CTRL + 29'd88, clip_b);             // intentionally no word-39 commit
            repeat (8 * POLL_FAST) @(posedge mclk);
            if (geom_ack_seq !== 8'd1 || geom_data !== {clip_a, geom_req})
                fail("geometry", "clip-only partial update became active without a sequence commit");
            geom_req[63:56] = 8'd2;
            ddr.poke(CTRL + 29'd39, geom_req);
            gsp = 0;
            while (geom_ack_seq !== 8'd2 && gsp < 10000) begin @(posedge clk); gsp++; end
            repeat (8) @(posedge clk);
            if (geom_ack_seq !== 8'd2 || geom_error !== 2'd0 || geom_data !== {clip_b, geom_req})
                fail("geometry", $sformatf("valid seq2 ACK/data: ack %0d err %0d data %h", geom_ack_seq, geom_error, geom_data));
            clip_bad = {16'd0, 12'd400, 12'd40, 12'd30, 12'd700}; // clip right edge 740 > 720
            ddr.poke(CTRL + 29'd88, clip_bad);
            geom_req[63:56] = 8'd3;
            ddr.poke(CTRL + 29'd39, geom_req);
            gsp = 0;
            while (geom_ack_seq !== 8'd3 && gsp < 10000) begin @(posedge clk); gsp++; end
            repeat (8) @(posedge clk);
            if (geom_ack_seq !== 8'd3 || geom_error !== 2'd1 || geom_data !== {clip_b, {8'd2, 4'd0, 13'h1FFC, 13'd20, 13'd600, 13'd400}})
                fail("geometry", $sformatf("invalid seq3 was not refused atomically: ack %0d err %0d", geom_ack_seq, geom_error));
            new_nonce = cw_lo(33) ^ 32'h5453_5432;
            if (new_nonce == 0) new_nonce = 32'h5453_5432;
            geom_reset_expected = 1;
            ddr.poke(CTRL + 29'd33, {32'd0, new_nonce});
            gsp = 0;
            while (ack_nonce !== new_nonce && gsp < 10000) begin @(posedge clk); gsp++; end
            repeat (12) @(posedge clk);
            if (ack_nonce !== new_nonce || geom_ack_seq !== 8'd3 || geom_error !== 2'd0 || geom_data !== 128'd0)
                fail("geometry", "nonce transition did not clear and baseline the stale request");
            if (!geom_reset_seen)
                fail("geometry", "nonce transition did not produce its expected stream reset");
            geom_reset_expected = 0;
        end
        $display("ring_rd_tb: %s %0d items, %0d pictures, %0d polls, %0d bursts, %0d status frames, state %0d err %0d",
                 arm, n_items, n_pics, n_polls, n_bursts, seq, state, err);
        if (fails == 0) $display("PASS: ring_rd_tb %s", arm);
        else $fatal(1);
        $finish;
    end

    initial begin
        #400ms; $display("FAIL [hang] %s: the run never finished", arm); $fatal(1);
    end
endmodule

`default_nettype wire
