// bench/h264/dpb_mem_tb.sv -- h264/dec/dpb_mem.sv on two real clocks (81 / 90 MHz)
// against bench/h264/ddr_model.sv and a scoreboard: random bursts of writes (random
// byte enables, data arriving before / after the command) and reads, every read
// beat compared in order (`!==`) with what the scoreboard holds for that word; the
// model $fatals on a write issued during outstanding reads, on a read without
// credit, on an illegal burst.
//
//   [data]   every read beat equals the scoreboard's word (byte enables honoured)
//   [order]  beats arrive in command order (a read after a write of the same word
//            sees the write)
//   [count]  every issued read returned exactly its beats; the ddr model's rules held
//   [rate]   back-to-back single-row reads reach >= 1 beat per 4 clk cycles average
//            (pipelined reads: the client does not wait for each burst to finish)
// PASS marker: "PASS: dpb_mem_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module dpb_mem_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg clk = 1'b0, mclk = 1'b0;
always #6.173 clk = ~clk;      // 81 MHz
always #5.556 mclk = ~mclk;    // 90 MHz
reg rst_n = 1'b0, mrst_n = 1'b0;

reg         cmd_valid = 1'b0, cmd_write = 1'b0;
reg  [28:0] cmd_addr = 29'd0;
reg  [3:0]  cmd_len = 4'd1;
wire        cmd_ready, wd_ready, rd_valid;
reg         wd_valid = 1'b0;
reg  [63:0] wd_data = 64'd0;
reg  [7:0]  wd_be = 8'hFF;
wire [63:0] rd_data;
reg         rd_ready = 1'b0;
wire [31:0] stat_reads, stat_writes;
wire [28:0] ddr_address;
wire [7:0]  ddr_burstcount, ddr_byteenable;
wire        ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
wire [63:0] ddr_writedata, ddr_readdata;
int         unwritten;

dpb_mem dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_write(cmd_write), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
    .wd_valid(wd_valid), .wd_ready(wd_ready), .wd_data(wd_data), .wd_be(wd_be),
    .rd_valid(rd_valid), .rd_data(rd_data), .rd_ready(rd_ready),
    .stat_reads(stat_reads), .stat_writes(stat_writes), .wr_drained(),
    .mclk(mclk), .mrst_n(mrst_n),
    .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
    .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
    .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));

ddr_model #(.AW(12)) ddr (
    .clk(mclk), .rst_n(mrst_n), .address(ddr_address), .burstcount(ddr_burstcount), .read(ddr_read),
    .write(ddr_write), .writedata(ddr_writedata), .byteenable(ddr_byteenable), .waitrequest(ddr_waitrequest),
    .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));

// ---- the scoreboard: the words as the client wrote them, the expected read beats ----
localparam [28:0] BASE = 29'h0600_0000;
logic [63:0] sb [0:4095];
logic        sbw [0:4095];
initial for (int i = 0; i < 4096; i++) sbw[i] = 1'b0;
logic [63:0] exp_q [$];
logic [63:0] wd_d [0:7];
logic [7:0]  wd_bea [0:7];
integer n_rd_beats = 0, n_rd_cmds = 0, n_wr_cmds = 0, n_wr_beats_q = 0;
integer rate_start = 0, rate_beats = 0, rate_end = 0;

task automatic do_write(input [28:0] a, input [3:0] len, input bit data_first);
    for (int i = 0; i < len; i++) begin
        wd_d[i] = {$urandom, $urandom};
        wd_bea[i] = ($urandom_range(0, 3) == 0) ? $urandom : 8'hFF;
        if (wd_bea[i] == 8'd0) wd_bea[i] = 8'h01;
    end
    if (data_first) push_data(len);
    @(negedge clk);
    cmd_valid = 1'b1; cmd_write = 1'b1; cmd_addr = a; cmd_len = len;
    @(posedge clk); while (!cmd_ready) @(posedge clk);
    @(negedge clk); cmd_valid = 1'b0;
    if (!data_first) push_data(len);
    for (int i = 0; i < len; i++) begin
        logic [63:0] cur;
        int wi;
        wi = int'(a + i - BASE);
        cur = sbw[wi] ? sb[wi] : 64'd0;
        for (int b = 0; b < 8; b++) if (wd_bea[i][b]) cur[8*b +: 8] = wd_d[i][8*b +: 8];
        sb[wi] = cur; sbw[wi] = 1'b1;
    end
    n_wr_cmds = n_wr_cmds + 1;
endtask

task automatic push_data(input [3:0] len);
    for (int i = 0; i < len; i++) begin
        @(negedge clk);
        while ($urandom_range(0, 3) == 0) @(negedge clk);   // gaps in the data stream
        wd_valid = 1'b1; wd_data = wd_d[i]; wd_be = wd_bea[i];
        @(posedge clk); while (!wd_ready) @(posedge clk);
        @(negedge clk); wd_valid = 1'b0;
    end
endtask

task automatic do_read(input [28:0] a, input [3:0] len);
    @(negedge clk);
    cmd_valid = 1'b1; cmd_write = 1'b0; cmd_addr = a; cmd_len = len;
    @(posedge clk); while (!cmd_ready) @(posedge clk);
    @(negedge clk); cmd_valid = 1'b0;
    for (int i = 0; i < len; i++) exp_q.push_back(sbw[int'(a + i - BASE)] ? sb[int'(a + i - BASE)] : 64'd0);
    n_rd_cmds = n_rd_cmds + 1;
endtask

// the read consumer: random ready, checks in order
always @(posedge clk) if (rst_n) begin
    if (rd_valid && rd_ready) begin
        if (exp_q.size() == 0) `FAIL("count", "a read beat nobody asked for")
        if (rd_data !== exp_q[0]) `FAIL("data", $sformatf("beat %0d: %h expected %h", n_rd_beats, rd_data, exp_q[0]))
        exp_q.pop_front();
        n_rd_beats = n_rd_beats + 1;
        if (rate_start != 0) rate_beats = rate_beats + 1;
    end
end
integer rd_pct = 100;
always @(negedge clk) rd_ready = ($urandom_range(0, 99) < rd_pct);

integer cyc = 0;
always @(posedge clk) cyc = cyc + 1;

initial begin
    #40 rst_n = 1'b1; mrst_n = 1'b1;
    repeat (10) @(negedge clk);
    // 1. writes then reads of the same words (ordering through the client)
    $display("dpb_mem_tb: phase 1");
    for (int k = 0; k < 40; k++) begin
        logic [28:0] a; logic [3:0] len;
        a = 29'h0600_0000 + $urandom_range(0, 200) * 8; len = $urandom_range(1, 8);
        do_write(a, len, $urandom_range(0, 1));
        do_read(a, len);
    end
    $display("dpb_mem_tb: phase 2 (%0d beats so far)", n_rd_beats);
    // 2. mixed traffic with a slow consumer
    rd_pct = 40;
    for (int k = 0; k < 200; k++) begin
        logic [28:0] a; logic [3:0] len;
        a = 29'h0600_0000 + $urandom_range(0, 300) * 8; len = $urandom_range(1, 8);
        if ($urandom_range(0, 2) == 0) do_write(a, len, $urandom_range(0, 1)); else do_read(a, len);
    end
    rd_pct = 100;
    while (exp_q.size() != 0) @(negedge clk);
    $display("dpb_mem_tb: phase 2b (%0d beats so far)", n_rd_beats);
    // 2b. the consumer stalls while 40 x 8 beats are requested: only the credit keeps
    //     the read FIFO from overflowing (the M2 arm)
    rd_pct = 0;
    // 20 commands: 8 fit the 64-beat credit, 12 wait in the 16-deep command FIFO, so the
    // issue loop itself never blocks while the consumer is off
    for (int k = 0; k < 20; k++) do_read(29'h0600_0000 + $urandom_range(0, 300) * 8, 4'd8);
    repeat (50) @(negedge clk);
    rd_pct = 100;
    while (exp_q.size() != 0) @(negedge clk);
    $display("dpb_mem_tb: phase 3 (%0d beats so far)", n_rd_beats);
    // 3. the rate arm: 64 back-to-back 3-beat reads (a reference window's rows)
    repeat (20) @(negedge clk);
    rate_start = cyc;
    for (int k = 0; k < 64; k++) do_read(29'h0600_0000 + k * 8, 4'd3);
    while (exp_q.size() != 0) @(negedge clk);
    rate_end = cyc;
    repeat (20) @(negedge clk);
    if (n_rd_beats == 0 || exp_q.size() != 0) `FAIL("count", "reads unfinished")
    if ((rate_end - rate_start) > 64 * 3 * 4) `FAIL("rate", $sformatf("192 beats took %0d clk cycles", rate_end - rate_start))
    $display("dpb_mem_tb: %0d writes, %0d reads, %0d beats (%0d of unwritten words, as zeros); 192 pipelined beats in %0d clk cycles (%0d ddr bursts)",
             n_wr_cmds, n_rd_cmds, n_rd_beats, unwritten, rate_end - rate_start, stat_reads);
    $display("PASS: dpb_mem_tb");
    $finish;
end

initial begin
    #40_000_000;
    `FAIL("hang", "timeout")
end

endmodule
