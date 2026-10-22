// bench/h264/cosim_top.sv -- the Verilator cosim's top (bench/h264/cosim_main.cpp): the
// decoder as emu composes it -- the front end (h264/dec/h264_top.sv) straight into the
// reconstruction (h264/dec/recon_top.sv) on clk_dec, the DPB client on the memory clock
// -- with the probes the C++ harness scores through brought out as ports (hierarchical
// reads: the harness never reaches into the model by name).
//
//   ES bytes (the harness) -> h264_top -> SE words -> recon_top -> Avalon-MM (the
//   harness's DDR model)
//
// RING MODE (ring_mode = 1, roadmap P3h): the ES comes through the HPS interface instead --
// the harness's copy of hps/lib (the same C the rig runs) writes records into the DDR
// model's control block and ring, h264/ring_rd.sv reads them on ddr_mux2's master B beside
// the DPB (master A), and its stream reset resets the decoder as emu's fe_rst_n does. The
// status block (ring_stat, a "frame" every FRAME_T cycles) is how the library sees the
// read index and its session's ack. The ring reader's parser runs on clk here (emu: clk_sys
// through vidfeed_cdc) -- the crossing is benched by run_ring_rd.sh; this is the decoder fed
// through the ring, bit-exact, and ram1's occupancy shared with the ring's reads and polls.
//
// Probes: the [pre] arm's macroblock (the 48 words of the sample bank the cycle recon_mb
// starts deblocking it, as recon_top_tb.sv reads them), the [post] arm's write
// accounting, the [hang] arm's macroblock-done pulse and the counters of both halves.
// docs/h264_recon.md S5.
`default_nettype none
module cosim_top (
    input  wire         clk,
    input  wire         mclk,
    input  wire         rst_n,
    input  wire         mrst_n,
    input  wire         ring_mode,        // P3h: the ES from the ring (static)
    output wire   [7:0] ring_state,
    output wire   [7:0] ring_err,
    output wire  [31:0] ring_polls,
    output wire  [31:0] fe_pts_tag,       // pictures tagged with a PTS (au_pts)
    output wire  [31:0] fe_pts_drop,
    // the elementary stream
    input  wire   [7:0] es_byte,
    input  wire         es_valid,
    output wire         es_ready,
    input  wire         es_flush,
    // the display's hold on DPB stores (the harness holds a picture's store until scored)
    input  wire  [19:0] disp_hold,
    // DDR3 (Avalon-MM, mclk)
    output wire  [28:0] ddr_address,
    output wire   [7:0] ddr_burstcount,
    output wire         ddr_read,
    output wire         ddr_write,
    output wire  [63:0] ddr_writedata,
    output wire   [7:0] ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,
    // reconstruction status
    output wire         pic_start,
    output wire         pic_done,
    output wire   [4:0] cur_store,
    output wire   [1:0] cur_struct,
    output wire   [4:0] done_store,
    output wire   [1:0] done_struct,
    output wire   [7:0] width_mbs,
    output wire   [7:0] frame_height_mbs,
    output wire         idle,
    output wire  [31:0] pic_count,
    output wire  [31:0] mb_count,
    output wire  [31:0] err_count,
    output wire   [3:0] err_code,
    output wire  [31:0] mb_err_count,
    output wire  [31:0] ref_size,
    // P5d, the output process: the stores emitted to the display, the end of stream
    output wire         pinfo_second,     // the picture opening is its store's second field
    output wire         emit_valid,
    output wire   [4:0] emit_store,
    output wire         emit_frame,
    output wire         emit_unpaired,
    output wire         eos_done,
    output wire  [31:0] stall_cycles,
    // front-end status
    output wire         fe_busy,
    output wire  [31:0] fe_pic_count,
    output wire  [31:0] fe_refused_count,
    output wire   [3:0] fe_refused_code,
    output wire  [31:0] fe_err_count,
    output wire   [3:0] fe_err_code,
    output wire  [31:0] se_words,
    // probes
    output wire         pre_db,           // a macroblock's samples are complete, pre-deblock
    output wire   [6:0] pre_mbx,
    output wire   [6:0] pre_mby,
    output wire [3071:0] pre_words,       // its 48 words: luma rows 0..15 x 2, Cb 8, Cr 8
    output wire         mb_done,
    output wire   [7:0] mb_state,
    output wire   [7:0] inter_state,      // recon_inter.st: the fetch side   (the profile, +prof)
    output wire   [7:0] interp_state,     // recon_inter.k: the interpolation side
    output wire   [7:0] engine_state,     // recon_mb.es: the back engine (deblock, writeback)
    output wire   [7:0] res_state,        // recon_mb.rs: the residual engine
    output wire   [7:0] a_state,          // recon_mb.as: stage A (exp/mb-pipeline; mb_state is stage B)
    output wire   [7:0] fe_state,         // mb_syntax.state: the CABAC front end (the profile)
    output wire   [7:0] dq8_state,        // dequant_itrans8.state: the 8x8 residual unit (the profile)
    output wire   [7:0] kitem,            // recon_inter's interpolation item (the profile): {owned, chroma,
                                          // size 0..2, fraction class 0..2, bi, list} -- see cosim_prof.py
    output wire         kitem_take,       // ... an item taken this cycle (its key on kitem)
    output wire   [7:0] mc0_state,        // lane 0's mc_interp: 0 no reads left, 1 a read issued, 2 starved
                                          // of window rows (rows_avail), 3 held by its output credit
    output wire   [1:0] mb_slice_type,    // recon_mb's slice type (0 P, 1 B, 2 I): the profile's picture types
    output wire         fe_bin,           // cabac_engine.rsp_valid: a bin (or byte) decoded this cycle
    output wire         wr_cmd,           // a DPB write burst accepted by the memory client (clk)
    output wire  [31:0] wr_landed         // write bursts completed at the port (dpb_mem)
);
    // ---- the per-stream reset (ring mode: the reader's stream_clr), as emu makes it -------
    wire        stream_clr;
    wire        fe_rst_n = rst_n & ~(ring_mode & stream_clr);
    wire        dec_rst_n, dec_mrst_n;
    cdc_reset u_rst_dec (.clk(clk),  .rst_n_in(fe_rst_n), .rst_n_out(dec_rst_n));
    cdc_reset u_rst_mem (.clk(mclk), .rst_n_in(fe_rst_n & mrst_n), .rst_n_out(dec_mrst_n));
    logic [1:0] abort_q;
    always_ff @(posedge mclk or negedge mrst_n)
        if (!mrst_n) abort_q <= 2'b11;
        else         abort_q <= {abort_q[0], ~dec_mrst_n};

    // ---- the HPS interface's reader (ring mode) -------------------------------------------
    localparam int FRAME_T = 40000;                  // a status "frame": ~0.5 ms at 81 MHz
    wire  [7:0] rr_byte;
    wire        rr_mark, rr_au_end, rr_valid, rr_ready, rr_eos, rr_ll, rr_sess, rr_eos_seen;
    wire [32:0] rr_pts;
    wire [63:0] st_word, rr_err_word;
    wire  [6:0] st_ix;                               // 0.6: 7 bits (the input region's words 48-71)
    wire        st_wr, st_grp;
    wire  [6:0] st_free;                             // 0.6: was st_room
    wire [31:0] rr_err_pos, rr_n_au, rr_n_audio, rr_n_pad, rr_n_streams, rr_es_bytes, rr_ll_mismatch;
    wire [31:0] rr_read_index, rr_ack_nonce, rr_n_polls, rr_n_bursts, rr_eng_widx;
    wire  [7:0] rr_eng_err;
    wire        rr_eng_session;
    wire [28:0] rb_address;
    wire  [7:0] rb_burstcount;
    wire        rb_read, rb_write, rb_waitrequest, rb_readdatavalid;
    wire [63:0] rb_writedata, rb_readdata;
    wire        ring_mrst_n = mrst_n & ring_mode;
    ring_rd u_ring (
        .clk(clk), .rst_n(rst_n), .lrst_n(rst_n),
        .es_byte(rr_byte), .es_mark(rr_mark), .es_pts(rr_pts), .es_au_end(rr_au_end), .es_valid(rr_valid),
        .es_ready(rr_ready), .stream_clr(stream_clr), .eos(rr_eos), .ll_mode(rr_ll), .disp_ended(1'b1),
        // 0.5: no audio path here (the streams carry none): room, no hold, idle, no fetch
        .ad_push(), .ad_pos(), .ad_len(), .ad_pts(), .ad_ptsv(), .ad_room(1'b1), .a_hold_v(1'b0),
        .a_hold_idx(32'd0), .aud_idle(1'b1), .hold_bytes(), .af_go(1'b0), .af_addr(32'd0), .af_n(4'd0),
        .af_busy(), .af_dout(), .af_valid(), .af_empty(), .af_rd(1'b0), .ctl_pause(), .ctl_err(), .ctl_atten(), .rumble(), .rum_changes(),
        .st_word(st_word), .st_ix(st_ix), .st_wr(st_wr), .st_grp(st_grp), .st_free(st_free),
        .sess(rr_sess), .state(ring_state), .err(ring_err), .err_pos(rr_err_pos), .err_word(rr_err_word),
        .eos_seen(rr_eos_seen), .n_au(rr_n_au), .n_audio(rr_n_audio), .n_pad(rr_n_pad), .n_streams(rr_n_streams),
        .es_bytes(rr_es_bytes), .ll_mismatch(rr_ll_mismatch),
        // 0.15: no PICTURE records here (coded streams only): the hand-over tied off
        .pd_req(), .pd_store(), .pd_w(), .pd_hf(), .pd_struct(), .pd_ps(), .pd_ps_v(), .pd_aspect(), .pd_timing_v(),
        .pd_nuit(), .pd_ts(), .pd_crop(), .pd_pts(), .pd_pts_v(), .pd_eos(), .pd_ack(1'b0), .pd_busy(1'b0), .pic_mode(),
        .mclk(mclk), .mrst_n(ring_mrst_n),
        .b_address(rb_address), .b_burstcount(rb_burstcount), .b_read(rb_read), .b_write(rb_write),
        .b_writedata(rb_writedata), .b_waitrequest(rb_waitrequest), .b_readdata(rb_readdata),
        .b_readdatavalid(rb_readdatavalid),
        .read_index(rr_read_index), .ack_nonce(rr_ack_nonce), .n_polls(rr_n_polls), .n_bursts(rr_n_bursts),
        .eng_err(rr_eng_err), .eng_session(rr_eng_session), .eng_widx(rr_eng_widx));
    assign ring_polls = rr_n_polls;
    // the status block, a frame every FRAME_T cycles
    logic [31:0] fcnt;
    logic        frame;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin fcnt <= '0; frame <= 1'b0; end
        else begin frame <= (fcnt == FRAME_T - 1); fcnt <= (fcnt == FRAME_T - 1) ? 32'd0 : fcnt + 32'd1; end
    wire [31:0] st_seq;
    wire  [6:0] sys_ix;                  // 0.10: 7 bits (words 80-87)
    wire  [5:0] mem_ix, dec_ix;
    wire [63:0] sys_word, mem_word;
    ring_stat u_stat (
        .clk(clk), .rst_n(rst_n), .frame(frame & ring_mode), .st_free(st_free), .seq(st_seq), .n_skips(),
        .sys_ix(sys_ix), .sys_word(sys_word), .mclk(mclk), .mrst_n(mrst_n), .mem_ix(mem_ix), .mem_word(mem_word),
        .dclk(clk), .drst_n(rst_n), .dec_ix(dec_ix), .dec_word(64'd0),
        // 0.6: no input here (the decoder's cosim): the input job never asked
        .in_req(1'b0), .in_go(), .in_busy(), .in_ix(), .in_word(64'd0),
        .st_word(st_word), .st_ix(st_ix), .st_wr(st_wr), .st_grp(st_grp));
    ring_words_sys u_ws (
        .ix(sys_ix), .f_seq_head(st_seq), .f_state(ring_state), .f_err(ring_err),
        .f_live({1'b0, rr_sess, 4'd0, rr_eos_seen, rr_ll}), .f_osd(8'd0), .f_err_pos(rr_err_pos),
        .f_err_word(rr_err_word), .f_stc(33'd0), .f_lag_ms(16'd0), .f_n_au(rr_n_au), .f_n_audio(rr_n_audio),
        .f_n_pad(rr_n_pad), .f_n_streams(rr_n_streams), .f_es_bytes(rr_es_bytes), .f_ll_mismatch(rr_ll_mismatch),
        .f_disp_dc(32'd0), .f_disp_pick(32'd0), .f_disp_skip(32'd0), .f_disp_late(16'd0), .f_disp_starve(16'd0),
        .f_disp_cadence(16'd0), .f_disp_reanchor(8'd0), .f_disp_flags(3'd0), .f_disp_lone(4'd0),
        .f_disp_fetch_late(16'd0), .f_fit_crop_bad(1'b0), .f_fit_clamp(1'b0), .f_fit_snap(1'b0), .f_fit_ow(13'd0), .f_fit_oh(13'd0), .f_fit_valid(1'b0),
        .f_seq_tail(st_seq),
        .f_aud_state(2'd0), .f_aud_ll(1'b0), .f_aud_q_rec(9'd0), .f_aud_q_samples(32'd0), .f_aud_played(32'd0),
        .f_aud_records(32'd0), .f_aud_gap(32'd0), .f_aud_late(32'd0), .f_aud_underruns(16'd0), .f_aud_slip_drop(16'd0),
        .f_aud_slip_rep(16'd0), .f_aud_anchor(16'd0), .f_aud_offset(32'd0), .f_aud_hold_bytes(32'd0),
        .f_paused(1'b0), .f_ctl_err(1'b0), .f_atten(8'd0),
        .f_ovl_gen(32'd0), .f_ovl_state(2'd0), .f_ovl_at(1'b0), .f_ovl_clip(1'b0), .f_ovl_err(4'd0),   // 0.9: no overlay here
        .f_ovl_torn(8'd0), .f_ovl_late(16'd0), .f_ar_x(12'd0), .f_ar_y(12'd0), .f_ovl_lines(32'd0),
        .f_raster_w(12'd0), .f_raster_h(12'd0), .f_raster_mode(2'd0), .f_raster_lb(1'b0), .f_video_out(2'd0), .f_pic_x0(13'd0), .f_pic_y0(13'd0),   // 0.10
        .f_rum_p0(16'd0), .f_rum_p1(16'd0), .f_rum_p2(16'd0), .f_rum_p3(16'd0), .f_rum_p4(16'd0), .f_rum_p5(16'd0), .f_rum_changes(32'd0),   // 0.13
        .f_pic_held(20'd0), .f_pic_mode(1'b0), .f_pic_emitted(32'd0), .f_disp_fhold(32'd0),   // 0.15
        .f_colour(3'd0), .f_vui_matrix(8'd0), .f_vui_primaries(8'd0), .f_vui_transfer(8'd0), .f_vui_full_range(1'b0),
        .f_vui_colour_present(1'b0), .f_colour_override(1'b0), .f_colour_unsup(16'd0), .f_colour_mismatch(16'd0),   // 0.16
        .w(sys_word));
    ring_words_mem u_wm (
        .ix(mem_ix), .f_read_index(rr_read_index), .f_ack_nonce(rr_ack_nonce), .f_n_polls(rr_n_polls),
        .f_n_bursts(rr_n_bursts), .f_eng_err(rr_eng_err), .f_eng_session(rr_eng_session), .f_eng_widx(rr_eng_widx),
        .f_fetch_changes(32'd0), .f_probe_busy(16'd0), .f_probe_wr(32'd0), .f_probe_rd(32'd0), .f_probe_owed(16'd0),
        .f_probe_busy_max(16'd0), .w(mem_word));
    // the ES into the front end: the harness's bytes, or the reader's; END_OF_STREAM -> one flush pulse
    logic eos_q;
    always_ff @(posedge clk or negedge rst_n) if (!rst_n) eos_q <= 1'b0; else eos_q <= rr_eos;
    wire [7:0]  fe_byte  = ring_mode ? rr_byte  : es_byte;
    wire        fe_valid = ring_mode ? rr_valid : es_valid;
    wire        fe_ready;
    wire        fe_flush = ring_mode ? (rr_eos && !eos_q) : es_flush;
    // ready only once the front end is out of its (synchronised) reset: nal_parser's
    // in_ready reads 1 in reset, and a byte taken then is lost -- a stream opening with a
    // 3-byte start code lost its SPS that way (Phase 5). emu cannot: its CDC FIFO in front
    // of h264_top shares fe_rst_dec_n, so it holds nothing valid while the parser is reset
    assign rr_ready = ring_mode && fe_ready && dec_rst_n;
    assign es_ready = !ring_mode && fe_ready && dec_rst_n;

    // ---- ram1: master A the DPB, master B the ring reader -------------------------------------
    wire [28:0] a_address;
    wire  [7:0] a_burstcount, a_byteenable;
    wire        a_read, a_write, a_waitrequest, a_readdatavalid;
    wire [63:0] a_writedata, a_readdata;
    ddr_mux2 u_mux (
        .clk(mclk), .rst_n(mrst_n),
        .a_address(a_address), .a_burstcount(a_burstcount), .a_read(a_read), .a_write(a_write),
        .a_writedata(a_writedata), .a_byteenable(a_byteenable), .a_abort(abort_q[1]),
        .a_waitrequest(a_waitrequest), .a_readdata(a_readdata), .a_readdatavalid(a_readdatavalid),
        .b_address(rb_address), .b_burstcount(rb_burstcount), .b_read(rb_read), .b_write(rb_write),
        .b_writedata(rb_writedata), .b_waitrequest(rb_waitrequest), .b_readdata(rb_readdata),
        .b_readdatavalid(rb_readdatavalid),
        .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
        .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
        .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));

    wire        se_valid, se_ready;
    wire  [7:0] se_kind, se_aux;
    wire [31:0] se_val;
    wire [31:0] fe_nal, fe_slice, fe_sps, fe_pps;
    wire [39:0] fe_bins;

    h264_top u_fe (
        .clk(clk), .rst_n(dec_rst_n), .clear(1'b0),
        .es_byte(fe_byte), .es_valid(fe_valid), .es_ready(fe_ready), .es_flush(fe_flush),
        .es_mark(ring_mode & rr_mark), .es_pts(ring_mode ? rr_pts : 33'd0),   // ring mode: the records' PTS
        .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
        .sp_pps(), .sp_sps(), .sp_slice_type(), .sp_field(), .sp_bottom(), .sp_idr(),
        .sp_frame_num(), .sp_poc_lsb(),
        .busy(fe_busy), .nal_count(fe_nal), .slice_count(fe_slice), .pic_count(fe_pic_count),
        .sps_count(fe_sps), .pps_count(fe_pps), .refused_count(fe_refused_count),
        .refused_code(fe_refused_code), .err_count(fe_err_count), .err_code(fe_err_code),
        .bin_total(fe_bins), .pts_tag_count(fe_pts_tag), .pts_drop_count(fe_pts_drop));

    recon_top #(.DPB_BASE(29'h0640_0000)) dut (
        .clk(clk), .rst_n(dec_rst_n), .clear(1'b0),
        .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
        .disp_hold(disp_hold), .disp_frz(1'b0), .pic_start(pic_start), .cur_store(cur_store), .cur_struct(cur_struct),
        .pic_done(pic_done), .done_store(done_store), .done_struct(done_struct),
        .width_mbs(width_mbs), .frame_height_mbs(frame_height_mbs), .idle(idle), .stream_colour(3'd0),
        .pinfo_second(pinfo_second), .emit_valid(emit_valid), .emit_store(emit_store), .emit_frame(emit_frame),
        .emit_unpaired(emit_unpaired), .eos_done(eos_done), .stall_cycles(stall_cycles),
        .mclk(mclk), .mrst_n(dec_mrst_n),
        .ddr_address(a_address), .ddr_burstcount(a_burstcount), .ddr_read(a_read), .ddr_write(a_write),
        .ddr_writedata(a_writedata), .ddr_byteenable(a_byteenable), .ddr_waitrequest(a_waitrequest),
        .ddr_readdata(a_readdata), .ddr_readdatavalid(a_readdatavalid),
        .pic_count(pic_count), .mb_count(mb_count), .err_count(err_count), .err_code(err_code), .ref_size(ref_size));

    // SE words the reconstruction accepted
    logic [31:0] se_n;
    always_ff @(posedge clk or negedge dec_rst_n)
        if (!dec_rst_n) se_n <= '0;
        else if (se_valid && se_ready) se_n <= se_n + 1'b1;
    assign se_words = se_n;

    assign mb_err_count = dut.u_mb.err_count;
    assign pre_db  = dut.u_mb.dbg_pre_db;
    assign pre_mbx = dut.u_mb.mbx;
    assign pre_mby = dut.u_mb.mby;
    genvar k;
    generate for (k = 0; k < 48; k++) begin : PW
        assign pre_words[64*k +: 64] = (dut.u_mb.dbg_bank == 3'd4) ? dut.u_mb.bank4[k] : (dut.u_mb.dbg_bank == 3'd3) ? dut.u_mb.bank3[k] : (dut.u_mb.dbg_bank == 2'd2) ? dut.u_mb.bank2[k] :
                                       (dut.u_mb.dbg_bank == 2'd1) ? dut.u_mb.bank1[k] : dut.u_mb.bank0[k];
    end endgenerate
    assign mb_done   = dut.u_mb.mb_done;
    assign mb_state  = 8'(dut.u_mb.ms);
    assign inter_state  = 8'(dut.u_mb.u_inter.st);
    assign interp_state = 8'(dut.u_mb.u_inter.k);
    assign engine_state = 8'(dut.u_mb.es);
    assign res_state    = 8'(dut.u_mb.rs);
    assign a_state      = 8'(dut.u_mb.as);
    assign fe_state     = 8'(u_fe.mbs.state);
    assign mb_slice_type = dut.u_mb.slice_type;
    assign dq8_state    = 8'(dut.u_mb.u_dq8.state);
    // the item the interpolation side owns, or takes this cycle (recon_inter: k, the bank kb's
    // descriptor). Groups are square (16x16, an 8x8 quadrant, a 4x4 block): the width alone
    wire        ki_c  = dut.u_mb.u_inter.kd_c;
    wire  [4:0] ki_bw = dut.u_mb.u_inter.kd_bw;
    wire  [1:0] ki_sz = ki_c ? ((ki_bw == 5'd8) ? 2'd2 : (ki_bw == 5'd4) ? 2'd1 : 2'd0)
                             : ((ki_bw == 5'd16) ? 2'd2 : (ki_bw == 5'd8) ? 2'd1 : 2'd0);
    wire  [1:0] ki_fr = {1'b0, dut.u_mb.u_inter.kd_fx != 3'd0} + {1'b0, dut.u_mb.u_inter.kd_fy != 3'd0};
    wire        ki_own = (8'(dut.u_mb.u_inter.k) != 8'd0);
    assign kitem_take = !ki_own && dut.u_mb.u_inter.bank_full[dut.u_mb.u_inter.kb];
    wire        mc0_act = dut.u_mb.u_inter.LN[0].u_mc.active;
    wire        mc0_iss = dut.u_mb.u_inter.LN[0].u_mc.issue;
    wire        mc0_row = dut.u_mb.u_inter.LN[0].u_mc.r < dut.u_mb.u_inter.LN[0].u_mc.rows_avail;
    // +4: the item the interpolation side owns has not issued its first read yet (its setup,
    // or its first rows awaited), as opposed to the reads and the drain after them
    reg         mc0_first;
    always_ff @(posedge clk) begin
        if (kitem_take) mc0_first <= 1'b1;
        else if (mc0_iss) mc0_first <= 1'b0;
    end
    assign mc0_state = (ki_own && mc0_first ? 8'd4 : 8'd0) + (!mc0_act ? 8'd0 : mc0_iss ? 8'd1 : !mc0_row ? 8'd2 : 8'd3);
    assign kitem = {ki_own || kitem_take, ki_c, ki_sz, ki_fr, dut.u_mb.u_inter.kd_bi, dut.u_mb.u_inter.kd_lx};
    assign fe_bin       = u_fe.eng.rsp_valid;
    assign wr_cmd    = dut.m_cmd_valid && dut.c_cmd_ready && dut.m_cmd_write;
    assign wr_landed = dut.u_mem.stat_writes;
endmodule
`default_nettype wire
