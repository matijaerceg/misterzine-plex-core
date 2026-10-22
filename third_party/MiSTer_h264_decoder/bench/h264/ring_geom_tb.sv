// Directed 1.2 geometry protocol test: one real ring_rd Avalon master and the bench DDR model.
`timescale 1ns/1ps
`default_nettype none

module ring_geom_tb;
    localparam logic [28:0] CTRL = 29'h0628_0000;
    localparam logic [28:0] RING = 29'h0628_1000;
    localparam int POLL_FAST = 32, POLL_SLOW = 128;

    logic clk = 0, mclk = 0;
    always #18.5 clk = ~clk;
    always #5.55 mclk = ~mclk;
    logic lock_n = 0, core_n = 0;
    logic [28:0] b_address;
    logic [7:0] b_burstcount;
    logic b_read, b_write, b_waitrequest, b_readdatavalid;
    logic [63:0] b_writedata, b_readdata;
    logic [31:0] ack_nonce, n_polls;
    logic [127:0] geom_data;
    logic [7:0] geom_ack_seq;
    logic [1:0] geom_error;
    logic eng_session;
    logic [7:0] eng_err;

    ddr_model #(.BASE(CTRL), .AW(12)) ddr (
        .clk(mclk), .rst_n(lock_n), .address(b_address), .burstcount(b_burstcount),
        .read(b_read), .write(b_write), .writedata(b_writedata), .byteenable(8'hFF),
        .waitrequest(b_waitrequest), .readdata(b_readdata), .readdatavalid(b_readdatavalid), .unwritten_reads());

    ring_rd #(.CTRL_WORD(CTRL), .RING_WORD(RING), .RING_AW(9), .POLL_FAST(POLL_FAST), .POLL_SLOW(POLL_SLOW),
              .CLR_HOLD(8), .SETTLE(8), .END_WAIT(2000)) dut (
        .clk, .rst_n(core_n), .lrst_n(lock_n), .es_byte(), .es_mark(), .es_pts(), .es_au_end(), .es_valid(), .es_ready(1'b1),
        .stream_clr(), .eos(), .ll_mode(), .gfx_mode(), .vid_seen(), .disp_ended(1'b0),
        .ad_push(), .ad_pos(), .ad_len(), .ad_pts(), .ad_ptsv(), .ad_room(1'b1), .a_hold_v(1'b0), .a_hold_idx(32'd0),
        .aud_idle(1'b1), .hold_bytes(), .af_go(1'b0), .af_addr(32'd0), .af_n(4'd0), .af_busy(), .af_dout(), .af_valid(), .af_empty(), .af_rd(1'b0),
        .ctl_pause(), .ctl_err(), .ctl_atten(), .rumble(), .rum_changes(), .st_word(64'd0), .st_ix(7'd0), .st_wr(1'b0), .st_grp(1'b0), .st_free(),
        .sess(), .state(), .err(), .err_pos(), .err_word(), .eos_seen(), .n_au(), .n_audio(), .n_pad(), .n_streams(), .es_bytes(),
        .ll_mismatch(), .gfx_mismatch(), .colour_mode(), .colour_mismatch(), .pd_req(), .pd_store(), .pd_w(), .pd_hf(), .pd_struct(), .pd_ps(),
        .pd_ps_v(), .pd_aspect(), .pd_colour(), .pd_timing_v(), .pd_nuit(), .pd_ts(), .pd_crop(), .pd_pts(), .pd_pts_v(), .pd_eos(),
        .pd_ack(1'b0), .pd_busy(1'b0), .pic_mode(), .mclk, .mrst_n(lock_n), .b_address, .b_burstcount, .b_read, .b_write, .b_writedata,
        .b_waitrequest, .b_readdata, .b_readdatavalid, .read_index(), .ack_nonce, .n_polls, .n_bursts(), .eng_err, .eng_session,
        .eng_widx(), .set_word(), .set_tog(), .geom_data, .geom_ack_seq, .geom_error);

    task automatic wait_ack(input logic [7:0] seq);
        int spins;
        spins = 0;
        while (geom_ack_seq !== seq && spins < 20000) begin @(posedge clk); spins++; end
        repeat (8) @(posedge clk);
        if (geom_ack_seq !== seq) $fatal(1, "geometry ACK timeout: wanted %0d, got %0d", seq, geom_ack_seq);
    endtask

    initial begin
        logic [63:0] req, clip_a, clip_b, clip_bad;
        logic [31:0] nonce;
        int spins;
        ddr.poke(CTRL + 29'd32, 64'd0);
        ddr.poke(CTRL + 29'd33, 64'd0);
        ddr.poke(CTRL + 29'd39, 64'd0);
        ddr.poke(CTRL + 29'd88, 64'd0);
        repeat (8) @(posedge clk);
        lock_n = 1; core_n = 1;
        repeat (2000) @(posedge clk); // first observed nonce is ignored by design
        nonce = 32'h4754_0001;
        ddr.poke(CTRL + 29'd33, {32'd0, nonce});
        spins = 0;
        while (ack_nonce !== nonce && spins < 20000) begin @(posedge clk); spins++; end
        if (ack_nonce !== nonce || !eng_session) $fatal(1, "session did not open before geometry test");

        req = {8'd1, 4'd0, 13'h1FFC, 13'd20, 13'd600, 13'd400}; // x=-4
        clip_a = {16'd0, 12'd400, 12'd600, 12'd30, 12'd20};
        clip_b = {16'd0, 12'd400, 12'd600, 12'd30, 12'd30};
        ddr.poke(CTRL + 29'd88, clip_a);
        ddr.poke(CTRL + 29'd39, req); // sequence is committed last
        wait_ack(8'd1);
        if (geom_error !== 2'd0 || geom_data !== {clip_a, req})
            $fatal(1, "valid geometry transaction mismatch: error=%0d data=%h", geom_error, geom_data);

        ddr.poke(CTRL + 29'd88, clip_b); // partial write: no sequence transition
        repeat (8 * POLL_FAST) @(posedge mclk);
        if (geom_ack_seq !== 8'd1 || geom_data !== {clip_a, req})
            $fatal(1, "clip-only partial write became active");
        req[63:56] = 8'd2;
        ddr.poke(CTRL + 29'd39, req);
        wait_ack(8'd2);
        if (geom_error !== 2'd0 || geom_data !== {clip_b, req}) $fatal(1, "sequence commit did not publish clip B");

        clip_bad = {16'd0, 12'd400, 12'd40, 12'd30, 12'd700}; // right edge 740 exceeds 720
        req[63:56] = 8'd3;
        ddr.poke(CTRL + 29'd88, clip_bad);
        ddr.poke(CTRL + 29'd39, req);
        wait_ack(8'd3);
        if (geom_error !== 2'd1 || geom_data !== {clip_b, {8'd2, 4'd0, 13'h1FFC, 13'd20, 13'd600, 13'd400}})
            $fatal(1, "invalid transaction was not refused atomically: error=%0d", geom_error);

        nonce = 32'h4754_0002;
        ddr.poke(CTRL + 29'd33, {32'd0, nonce});
        spins = 0;
        while (ack_nonce !== nonce && spins < 20000) begin @(posedge clk); spins++; end
        repeat (12) @(posedge clk);
        if (ack_nonce !== nonce || geom_ack_seq !== 8'd3 || geom_error !== 2'd0 || geom_data !== 128'd0)
            $fatal(1, "new nonce did not clear and baseline the stale request");
        $display("PASS: ring_geom_tb valid / partial / invalid / nonce transitions");
        $finish;
    end
    initial begin #10ms; $fatal(1, "ring_geom_tb timeout"); end
endmodule

`default_nettype wire
