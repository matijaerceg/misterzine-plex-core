// bench/h264/sfifo_tb.sv -- h264/sfifo.sv against a queue model: random pushes and
// pops (+stall biases), every popped word in order (`!==`), full/count honest, no
// word lost or invented, a pop every cycle possible when kept full.
//
//   [order]  every word out equals the model's, in order
//   [count]  count == the model's occupancy, full iff the RAM is full
//   [rate]   with pushes every cycle, the output stays valid every cycle after fill; and
//            (phase 5, from full, a push and a pop every cycle) every push after the first is
//            accepted: each pop frees the slot the next push needs, so a `full` that clears a
//            cycle late is caught here. It loses no word and costs the writer one cycle each
//            time the RAM tops out (then the RAM sits a word below the top): a margin of one
//            push, deterministic (both rates 100 %: no random draw decides it)
// PASS marker: "PASS: sfifo_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module sfifo_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

localparam AW = 4;
reg  [47:0] din = 48'd0;
reg         wr_en = 1'b0, rd_en = 1'b0;
wire        full, dout_valid;
wire [47:0] dout;
wire [AW+1:0] count;
sfifo #(.DW(48), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n), .din(din), .wr_en(wr_en), .full(full),
    .dout(dout), .dout_valid(dout_valid), .rd_en(rd_en), .count(count));

reg [47:0] q [$];
integer n_in = 0, n_out = 0, seed = 1;
integer wr_pct, rd_pct, phase;
integer valid_cycles = 0, kept_cycles = 0;
integer st_pushes = 0, st_accepted = 0;

initial begin
    #23 rst_n = 1'b1;
    for (phase = 0; phase < 7; phase = phase + 1) begin
        case (phase)
            0: begin wr_pct = 100; rd_pct = 100; end     // streaming
            1: begin wr_pct = 100; rd_pct = 30; end      // fills up
            2: begin wr_pct = 30;  rd_pct = 100; end     // drains
            3: begin wr_pct = 60;  rd_pct = 60; end
            4: begin wr_pct = 100; rd_pct = 0; end       // to full
            5: begin wr_pct = 100; rd_pct = 100; end     // streaming from full
            default: begin wr_pct = 0; rd_pct = 100; end // to empty
        endcase
        repeat (400) begin
            @(negedge clk);
            wr_en = ($urandom_range(0, 99) < wr_pct);
            din   = {$urandom, $urandom};
            rd_en = ($urandom_range(0, 99) < rd_pct);
        end
    end
    @(negedge clk); wr_en = 1'b0; rd_en = 1'b1;
    repeat (40) @(negedge clk);
    if (q.size() != 0 || dout_valid) `FAIL("count", $sformatf("%0d words left in the model, valid %0d", q.size(), dout_valid))
    if (n_out < 600) `FAIL("order", "too few words moved")
    if (kept_cycles < 300 || valid_cycles < kept_cycles - 2) `FAIL("rate", $sformatf("valid %0d of %0d kept-full cycles", valid_cycles, kept_cycles))
    if (st_pushes < 300 || st_accepted < st_pushes - 2) `FAIL("rate", $sformatf("streaming from full: %0d of %0d pushes accepted", st_accepted, st_pushes))
    $display("sfifo_tb: %0d words in, %0d out, %0d/%0d valid while fed, %0d/%0d pushes accepted streaming from full",
             n_in, n_out, valid_cycles, kept_cycles, st_accepted, st_pushes);
    $display("PASS: sfifo_tb");
    $finish;
end

// the model: push on accepted writes, pop on accepted reads, check
always @(posedge clk) if (rst_n) begin
    if (wr_en && !full) begin q.push_back(din); n_in = n_in + 1; end
    if (phase == 5 && wr_en) begin st_pushes = st_pushes + 1; if (!full) st_accepted = st_accepted + 1; end
    if (rd_en && dout_valid) begin
        if (q.size() == 0) `FAIL("order", "pop from an empty model")
        if (dout !== q[0]) `FAIL("order", $sformatf("word %0d: %h expected %h", n_out, dout, q[0]))
        q.pop_front(); n_out = n_out + 1;
    end
end
// count / full, checked a cycle later (registered)
integer model_n;
always @(negedge clk) if (rst_n) begin
    model_n = q.size();
    if (count !== model_n[AW+1:0]) `FAIL("count", $sformatf("count %0d model %0d", count, model_n))
    if (full && model_n < (1 << AW)) `FAIL("count", "full with room in the RAM")
    if (!full && model_n > (1 << AW) + 1) `FAIL("count", "not full while over capacity")
    if (phase == 1 && model_n > 3) begin kept_cycles = kept_cycles + 1; if (dout_valid) valid_cycles = valid_cycles + 1; end
end

endmodule
