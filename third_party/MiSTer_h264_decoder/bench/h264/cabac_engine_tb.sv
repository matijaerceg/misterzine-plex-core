// bench/h264/cabac_engine_tb.sv -- cabac_engine (+ cabac_ctx) against tools/cabac_ref.py
//
// +stem=<path>: a tools/cabac_vectors.py set (.bytes/.req/.exp/.ctx/.meta.hex). The
// bytes are fed through the held handshake with in_last on the final one; +stall=N
// (N > 0) withholds in_valid at random with seed N. Requests are issued as soon as
// the previous response is visible (the caller's cadence in mb_syntax). +stem2=<path>:
// after the first set, a FLUSH request, then the second set from its own bytes.
//
//   [bin]    every response equals the model's (`!==`), in order
//   [ctx]    after every INIT, all 460 context states read back equal the model's
//   [err]    err_init / err_align / err_underrun never set (the sets never violate)
//   [hang]   a request answered within 2000 cycles (INIT takes ~470)
//   [rate]   with +stall=0: bins per cycle over the decision/bypass/terminate requests
//            >= 0.5 (two cycles per dependent decision, one per bypass/terminate)
//   [flush]  the second set decodes exactly after a FLUSH (a missing flush would feed
//            the first set's leftover bits into it)
//
// PASS marker: "PASS: cabac_engine_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module cabac_engine_tb;

localparam MAXB = 1 << 16;
localparam MAXR = 1 << 18;
localparam NCTX = 460;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT --------------------------------------------------------------------------------
reg  [7:0] in_byte = 8'd0;
reg        in_valid = 1'b0, in_last = 1'b0;
wire       in_ready;
reg        req_valid = 1'b0;
reg  [2:0] req_kind = 3'd0;
reg  [8:0] req_ctx = 9'd0;
wire       req_ready, rsp_valid, rsp_bin, busy, err_init, err_align, err_underrun;
wire [7:0] rsp_byte;
reg        dbg_rd_en = 1'b0;
reg  [8:0] dbg_addr = 9'd0;
wire [6:0] dbg_state;
wire [31:0] bin_count;
cabac_engine dut (
    .clk(clk), .rst_n(rst_n),
    .in_byte(in_byte), .in_valid(in_valid), .in_last(in_last), .in_ready(in_ready),
    .req_valid(req_valid), .req_ready(req_ready), .req_kind(req_kind), .req_ctx(req_ctx),
    .rsp_valid(rsp_valid), .rsp_bin(rsp_bin), .rsp_byte(rsp_byte),
    .busy(busy), .err_init(err_init), .err_align(err_align), .err_underrun(err_underrun),
    .dbg_rd_en(dbg_rd_en), .dbg_addr(dbg_addr), .dbg_state(dbg_state), .bin_count(bin_count));

// ---- fixture --------------------------------------------------------------------------
reg  [7:0]  bytes_m [0:MAXB-1];
reg  [15:0] req_m   [0:MAXR-1];
reg  [15:0] exp_m   [0:MAXR-1];
reg  [7:0]  ctx_m   [0:256*NCTX-1];
reg  [31:0] meta    [0:7];
string  stem, stem2;
integer stall = 0, seed;
integer n_bytes, n_req, n_init, n_bins;

// ---- byte feeder: held handshake, random stalls, in_last on the final byte ------------
integer bi = 0;
reg     feed_on = 1'b0;
reg     hold = 1'b0;
always @(posedge clk) begin
    if (feed_on && bi < n_bytes) begin
        if (!in_valid) begin
            if (stall == 0 || ($urandom % 4) != 0) begin
                in_byte  <= bytes_m[bi];
                in_last  <= (bi == n_bytes - 1);
                in_valid <= 1'b1;
            end
        end else if (in_ready) begin
            bi <= bi + 1;
            if (bi + 1 < n_bytes && (stall == 0 || ($urandom % 4) != 0)) begin
                in_byte <= bytes_m[bi + 1];
                in_last <= (bi + 1 == n_bytes - 1);
            end else in_valid <= 1'b0;
        end
    end else if (in_valid && in_ready) in_valid <= 1'b0;
end

// ---- request driver ------------------------------------------------------------------
integer ri, wait_cyc, bin_cycles, bins_seen, ci, init_seen, k, errs;
reg [6:0] want;

task automatic load(input string s);
    begin
        $readmemh({s, ".meta.hex"}, meta);
        n_bytes = meta[0]; n_req = meta[1]; n_init = meta[2]; n_bins = meta[4];
        if (n_bytes > MAXB || n_req > MAXR || n_init > 256) `FAIL("harness", "fixture too large")
        $readmemh({s, ".bytes.hex"}, bytes_m, 0, n_bytes - 1);
        $readmemh({s, ".req.hex"}, req_m, 0, n_req - 1);
        $readmemh({s, ".exp.hex"}, exp_m, 0, n_req - 1);
        if (n_init) $readmemh({s, ".ctx.hex"}, ctx_m, 0, n_init * NCTX - 1);
        bi = 0;
    end
endtask

// one request: present it, wait for acceptance, then for its response
task automatic do_req(input [15:0] w, input [15:0] want_rsp, input integer idx, input bit score);
    integer t;
    begin
        req_kind = w[14:12]; req_ctx = w[8:0]; req_valid = 1'b1;
        #1;                                          // let req_ready settle for THIS kind before sampling it
        t = 0;
        while (!req_ready) begin @(posedge clk); #1; t = t + 1; if (t > 2000) `FAIL("hang", $sformatf("request %0d never accepted", idx)) end
        @(posedge clk); #1; req_valid = 1'b0;          // accepted on that edge
        t = 0;
        while (!rsp_valid) begin @(posedge clk); #1; t = t + 1; if (t > 2000) `FAIL("hang", $sformatf("request %0d never answered", idx)) end
        if (score) begin
            if (w[14:12] == 3'd5) begin
                if (rsp_byte !== want_rsp[7:0]) `FAIL("bin", $sformatf("request %0d (raw byte): got %02x want %02x", idx, rsp_byte, want_rsp[7:0]))
            end else if (w[14:12] <= 3'd2) begin
                if (rsp_bin !== want_rsp[0]) `FAIL("bin", $sformatf("request %0d kind %0d ctx %0d: got %0d want %0d", idx, w[14:12], w[8:0], rsp_bin, want_rsp[0]))
            end
        end
    end
endtask

task automatic check_ctx(input integer ev);
    begin
        for (ci = 0; ci < NCTX; ci = ci + 1) begin
            dbg_rd_en = 1'b1; dbg_addr = ci[8:0];
            @(posedge clk); #1; dbg_rd_en = 1'b0;
            @(posedge clk); #1;
            want = ctx_m[ev * NCTX + ci][6:0];
            if (dbg_state !== want) `FAIL("ctx", $sformatf("init %0d ctxIdx %0d: state %02x want %02x", ev, ci, dbg_state, want))
        end
    end
endtask

task automatic run_set(input string s, input bit score_rate);
    integer t0;
    begin
        load(s);
        feed_on = 1'b1;
        init_seen = 0; bin_cycles = 0; bins_seen = 0;
        for (ri = 0; ri < n_req; ri = ri + 1) begin
            t0 = $time;
            do_req(req_m[ri], exp_m[ri], ri, 1'b1);
            if (req_m[ri][14:12] <= 3'd2) begin
                bin_cycles = bin_cycles + ($time - t0) / 10;
                bins_seen = bins_seen + 1;
            end
            if (req_m[ri][14:12] == 3'd3) begin
                check_ctx(init_seen);
                init_seen = init_seen + 1;
            end
        end
        feed_on = 1'b0;
        if (err_init | err_align | err_underrun)
            `FAIL("err", $sformatf("err_init %0d err_align %0d err_underrun %0d", err_init, err_align, err_underrun))
        if (bins_seen !== n_bins) `FAIL("harness", "bin count")
        $display("cabac_engine_tb: %0s: %0d requests, %0d bins in %0d cycles = %0d.%02d bins/cycle, %0d inits",
                 s, n_req, bins_seen, bin_cycles, (100 * bins_seen / bin_cycles) / 100, (100 * bins_seen / bin_cycles) % 100, init_seen);
        if (score_rate && stall == 0 && (100 * bins_seen) < 50 * bin_cycles)
            `FAIL("rate", $sformatf("%0d bins in %0d cycles", bins_seen, bin_cycles))
        if (bin_count !== bins_seen[31:0]) `FAIL("bin", $sformatf("bin_count %0d, bins %0d", bin_count, bins_seen))
    end
endtask

task automatic reset_dut;
    begin
        feed_on = 1'b0; in_valid = 1'b0; in_last = 1'b0; req_valid = 1'b0;
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk); #1;
    end
endtask

task automatic send_one_byte(input [7:0] b, input bit last);
    begin
        @(negedge clk); in_byte = b; in_last = last; in_valid = 1'b1;
        do @(posedge clk); while (!in_ready);
        #1 in_valid = 1'b0; in_last = 1'b0;
    end
endtask

task automatic check_init_boundary(input [2:0] kind, input [7:0] second_byte, input [8:0] want_off);
    begin
        reset_dut();
        send_one_byte(8'hff, 1'b0);
        send_one_byte(second_byte, 1'b1);
        do_req({1'b0, kind, 3'd0, 9'd0}, 16'd0, -2, 1'b0);
        if (err_init !== 1'b1) `FAIL("init_boundary", $sformatf("kind %0d top9 %0d did not flag err_init", kind, want_off))
        if (dut.off !== {1'b0, want_off}) `FAIL("init_boundary", $sformatf("kind %0d initialized offset %0d want %0d", kind, dut.off, want_off))
        if (dut.bcnt !== 6'd7) `FAIL("init_boundary", $sformatf("kind %0d left %0d bits; expected 7", kind, dut.bcnt))
        $display("PASS: initialization boundary kind %0d top9 %0d", kind, want_off);
    end
endtask

initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    if (!$value$plusargs("stem2=%s", stem2)) stem2 = "";
    seed = stall;
    k = $urandom(seed);                     // seed once; the feeder draws unseeded
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;

    run_set(stem, 1'b1);

    if (stem2 != "") begin
        // FLUSH between "NAL units": the leftover bits of the first set must not reach
        // the second, and the second's expectations came from an independent model run
        in_valid = 1'b0;
        @(posedge clk); #1;
        do_req(16'h7000, 16'd0, -1, 1'b0);
        run_set(stem2, 1'b0);
        $display("cabac_engine_tb: [flush] second set decoded after FLUSH");
    end
    check_init_boundary(3'd6, 8'h00, 9'd510); // K_REINIT's threshold boundary
    check_init_boundary(3'd6, 8'h80, 9'd511);
    check_init_boundary(3'd3, 8'h00, 9'd510); // S_INIT_CTX's threshold boundary
    check_init_boundary(3'd3, 8'h80, 9'd511);
    $display("PASS: cabac_engine_tb");
    $finish;
end

endmodule
