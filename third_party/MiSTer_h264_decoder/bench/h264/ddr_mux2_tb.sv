// bench/h264/ddr_mux2_tb.sv -- h264/ddr_mux2.sv: master A (random read / write bursts, gapped
// write beats) and master B (random read bursts, and since P6a random write bursts into
// its own region, read back) against bench/h264/ddr_model.sv, which $fatals on a write
// accepted while read beats are outstanding and on a read inside an open write burst.
//   [grant] no A command is accepted while B's write burst is open (B's burst pins it);
//           A's abort landing inside B's write burst leaves B's burst intact (read back);
//           B's write never waits more than 400 cycles (a blocked B write holds the grant
//           until the reads drain: it is not re-blocked by A for ever)
//   [data]  every read beat each master receives equals its scoreboard, in its own order
//   [count] both masters finished, every burst completed; while A streams commands back to
//           back, B still waits at most 40 cycles for the channel (fairness)
//   [abort] four aborts of master A (a mount reset): one with A's reads in flight (their
//           beats must never reach A), one inside a write burst (the burst is completed
//           with masked beats -- the model $fatals on a read inside an open burst -- and
//           the words it would have written read back unchanged), and two landing on the
//           very cycle the PORT holds off A's request -- a read, a write burst's first
//           beat -- while A withdraws it as a reset master does: the mux must keep
//           presenting it until accepted (the model's [avalon]: a request withdrawn under
//           waitrequest left the rig's HPS DDR3 port hung for good, docs/hil_harness.md)
// PASS marker: "PASS: ddr_mux2_tb".
`timescale 1ns/1ps
module ddr_mux2_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
localparam [28:0] BASE = 29'h0600_0000;
reg clk = 0; always #5.556 clk = ~clk;
reg rst_n = 0;

reg  [28:0] a_address = BASE; reg [7:0] a_burstcount = 1; reg a_read = 0, a_write = 0;
reg  [63:0] a_writedata = 0; reg [7:0] a_byteenable = 8'hFF; reg a_abort = 0;
wire        a_waitrequest, a_readdatavalid; wire [63:0] a_readdata;
reg  [28:0] b_address = BASE; reg [7:0] b_burstcount = 1; reg b_read = 0, b_write = 0;
reg  [63:0] b_writedata = 0;
wire        b_waitrequest, b_readdatavalid; wire [63:0] b_readdata;
wire [28:0] ddr_address; wire [7:0] ddr_burstcount, ddr_byteenable; wire ddr_read, ddr_write;
wire [63:0] ddr_writedata, ddr_readdata; wire ddr_waitrequest, ddr_readdatavalid;
int unwritten;

ddr_mux2 dut (.clk(clk), .rst_n(rst_n),
    .a_address(a_address), .a_burstcount(a_burstcount), .a_read(a_read), .a_write(a_write), .a_writedata(a_writedata),
    .a_byteenable(a_byteenable), .a_abort(a_abort), .a_waitrequest(a_waitrequest), .a_readdata(a_readdata), .a_readdatavalid(a_readdatavalid),
    .b_address(b_address), .b_burstcount(b_burstcount), .b_read(b_read), .b_write(b_write),
    .b_writedata(b_writedata), .b_waitrequest(b_waitrequest),
    .b_readdata(b_readdata), .b_readdatavalid(b_readdatavalid),
    .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
    .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
    .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));
ddr_model #(.BASE(BASE), .AW(12)) ddr (.clk(clk), .rst_n(rst_n), .address(ddr_address), .burstcount(ddr_burstcount),
    .read(ddr_read), .write(ddr_write), .writedata(ddr_writedata), .byteenable(ddr_byteenable),
    .waitrequest(ddr_waitrequest), .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));

// A owns words 0..1023, B reads words 2048..3071 (poked at start) and writes 3072..4095
integer b_wr_beats = 0, b_wwait = 0, b_wwait_max = 0, b_abort_in_burst = 0;
always @(posedge clk) if (rst_n) begin
    if (dut.b_wburst != 8'd0 && !dut.grant) `FAIL("grant", "the grant left B inside its write burst")
    if (dut.b_wburst != 8'd0 && (dut.a_rd_acc || dut.a_wr_acc)) `FAIL("grant", "an A command accepted inside B's write burst")
    if (b_write && b_waitrequest) b_wwait = b_wwait + 1; else b_wwait = 0;
    if (b_wwait > b_wwait_max) b_wwait_max = b_wwait;
    if (b_write && !b_waitrequest) b_wr_beats = b_wr_beats + 1;
    if (a_abort && dut.b_wburst != 8'd0) b_abort_in_burst = b_abort_in_burst + 1;
end
logic [63:0] sb [0:4095];
logic [63:0] qa [$], qb [$];
integer na = 0, nb = 0, b_during_a = 0, a_busy = 0, aborts = 0;
integer swallowed = 0, max_out = 0, in_abort = 0, need_full = 0;
integer a_fin = 0, b_fin = 0, b_wait = 0, b_wait_max = 0, streaming = 0, stream_b = 0;
always @(posedge clk) if (rst_n) begin
    // B's wait for the channel, scored while A streams reads (outside, B also waits one
    // read latency behind A's blocked writes: the no-write-during-reads rule, not fairness)
    if (b_read && b_waitrequest && streaming && !dut.own_full) b_wait = b_wait + 1;   // a full owner FIFO is back-pressure
    else if (!(b_read && b_waitrequest && streaming)) b_wait = 0;
    if (b_wait > b_wait_max) b_wait_max = b_wait;
    if (streaming && b_read && !b_waitrequest) stream_b = stream_b + 1;
end
initial if ($test$plusargs("need_full")) need_full = 1;
// coverage: beats swallowed by an abort (abort 1 is not vacuous); the owner FIFO's depth
always @(posedge clk) if (rst_n) begin
    if (ddr_readdatavalid && dut.reads_out && !dut.own[dut.o_rd] && dut.a_flush) swallowed = swallowed + 1;
    if (dut.o_cnt > max_out) max_out = dut.o_cnt;
end
always @(posedge clk) if (rst_n) begin
    if (a_readdatavalid) begin
        if (qa.size() == 0) begin
            if (in_abort) `FAIL("abort", "A: a beat after the abort") else `FAIL("data", "A: a beat nobody asked for")
        end
        if (a_readdata !== qa[0]) begin
            if (in_abort) `FAIL("abort", $sformatf("A beat %0d after an abort: %h, want %h", na, a_readdata, qa[0]))
            else `FAIL("data", $sformatf("A beat %0d: %h, want %h", na, a_readdata, qa[0]))
        end
        void'(qa.pop_front()); na = na + 1;
    end
    if (b_readdatavalid) begin
        if (qb.size() == 0) `FAIL("data", "B: a beat nobody asked for")
        if (b_readdata !== qb[0]) `FAIL("data", $sformatf("B beat %0d: %h, want %h", nb, b_readdata, qb[0]))
        void'(qb.pop_front()); nb = nb + 1;
        if (a_busy) b_during_a = b_during_a + 1;
    end
end

initial begin : a_master
    #50 rst_n = 1;
    for (int i = 0; i < 4096; i++) sb[i] = 64'd0;
    for (int i = 2048; i < 3072; i++) begin sb[i] = {$urandom, $urandom}; ddr.poke(BASE + i, sb[i]); end
    for (int i = 0; i < 1024; i++) ddr.poke(BASE + i, 64'd0);
    for (int i = 3072; i < 4096; i++) begin sb[i] = 64'd0; ddr.poke(BASE + i, 64'd0); end
    repeat (5) @(negedge clk);
    a_busy = 1;
    for (int k = 0; k < 900; k++) begin
        int a, n;
        a = $urandom_range(0, 1016); n = $urandom_range(1, 8);
        if (k == 100) begin
            // A streams 64 read commands back to back (never idle): B must still get turns
            streaming = 1;
            @(negedge clk);
            for (int r = 0; r < 64; r++) begin
                a = $urandom_range(0, 1016);
                a_address = BASE + a; a_burstcount = 4; a_read = 1;
                @(posedge clk); while (a_waitrequest) @(posedge clk);
                for (int j = 0; j < 4; j++) qa.push_back(sb[a + j]);
                #1;
            end
            @(negedge clk); a_read = 0; streaming = 0;
        end else if (k == 200) begin
            // abort 1: three reads in flight, then the reset
            for (int r = 0; r < 3; r++) begin
                @(negedge clk); a_address = BASE + a; a_burstcount = 8; a_read = 1;
                @(posedge clk); while (a_waitrequest) @(posedge clk);
                for (int j = 0; j < 8; j++) qa.push_back(sb[a + j]);
            end
            @(negedge clk); a_read = 0; a_abort = 1;
            @(posedge clk); @(negedge clk); qa.delete(); in_abort = 1;     // from here on A must hear nothing
            repeat (40) @(negedge clk); a_abort = 0; aborts = aborts + 1;
            repeat (200) @(negedge clk); in_abort = 0;
        end else if (k == 500) begin
            // abort 5: land A's abort inside one of B's write bursts (A idle): B's burst must
            // complete intact (B reads it back later) and A must come back clean
            @(negedge clk); a_read = 0; a_write = 0;
            while (dut.b_wburst == 8'd0) @(negedge clk);
            a_abort = 1; in_abort = 1;
            repeat (40) @(negedge clk); a_abort = 0; aborts = aborts + 1;
            repeat (200) @(negedge clk); in_abort = 0;
        end else if (k == 400) begin
            // abort 2: three beats of an 8-beat write burst, then the reset
            for (int j = 0; j < 3; j++) begin
                logic [63:0] d;
                d = {$urandom, $urandom};
                @(negedge clk); a_address = BASE + 100; a_burstcount = 8; a_write = 1; a_writedata = d;
                @(posedge clk); while (a_waitrequest) @(posedge clk);
                sb[100 + j] = d;
            end
            @(negedge clk); a_write = 0; a_abort = 1; a_writedata = 64'hDEAD_BEEF_DEAD_BEEF; in_abort = 1;
            repeat (40) @(negedge clk); a_abort = 0; aborts = aborts + 1;
            // the five masked beats changed nothing
            @(negedge clk); a_address = BASE + 100; a_burstcount = 8; a_read = 1;
            @(posedge clk); while (a_waitrequest) @(posedge clk);
            for (int j = 0; j < 8; j++) qa.push_back(sb[100 + j]);
            @(negedge clk); a_read = 0;
            repeat (200) @(negedge clk); in_abort = 0;
        end else if (k == 600 || k == 800) begin
            // aborts 3 / 4: present until the port holds the request off, then abort on that
            // cycle and withdraw it (a read at 600, a write burst's first beat at 800)
            // (sampled AT the edge, like the other arms: the model's waitrequest for the
            // next cycle is written by that same edge)
            begin : held_abort
                forever begin
                    @(negedge clk);
                    a_address = BASE + 200; a_burstcount = 8;
                    if (k == 600) a_read = 1; else begin a_write = 1; a_writedata = 64'hFEED_FACE_0000_0001; end
                    @(posedge clk);
                    if (a_waitrequest && dut.ddr_waitrequest && (dut.ddr_read || dut.ddr_write)) disable held_abort;
                    // accepted instead (or held by the mux alone): finish it cleanly and try again
                    while (a_waitrequest) @(posedge clk);
                    if (k == 600) begin
                        for (int j = 0; j < 8; j++) qa.push_back(sb[200 + j]);
                        @(negedge clk); a_read = 0;
                    end else begin
                        sb[200] = 64'hFEED_FACE_0000_0001;
                        for (int j = 1; j < 8; j++) begin
                            @(negedge clk); a_writedata = {$urandom, $urandom};
                            @(posedge clk); while (a_waitrequest) @(posedge clk);
                            sb[200 + j] = a_writedata;
                        end
                        @(negedge clk); a_write = 0;
                    end
                    repeat (60) @(negedge clk);
                end
            end
            // the held first write beat goes out as presented (A's data), the rest masked
            if (k == 800) sb[200] = 64'hFEED_FACE_0000_0001;
            @(negedge clk); a_read = 0; a_write = 0; a_abort = 1; qa.delete(); in_abort = 1;
            repeat (40) @(negedge clk); a_abort = 0; aborts = aborts + 1;
            repeat (200) @(negedge clk); in_abort = 0;
        end else if ($urandom_range(0, 1)) begin
            for (int j = 0; j < n; j++) begin
                logic [63:0] d;
                d = {$urandom, $urandom};
                @(negedge clk);
                while ($urandom_range(0, 3) == 0 && j != 0) begin a_write = 0; @(negedge clk); end   // gaps between beats
                a_address = BASE + a; a_burstcount = n; a_write = 1; a_writedata = d;
                @(posedge clk); while (a_waitrequest) @(posedge clk);
                sb[a + j] = d;
            end
            @(negedge clk); a_write = 0;
        end else begin
            @(negedge clk);
            a_address = BASE + a; a_burstcount = n; a_read = 1;
            @(posedge clk); while (a_waitrequest) @(posedge clk);
            for (int j = 0; j < n; j++) qa.push_back(sb[a + j]);
            @(negedge clk); a_read = 0;
        end
    end
    a_busy = 0; a_fin = 1;
end
initial begin : b_master
    #60;
    repeat (8) @(negedge clk);
    for (int k = 0; !a_fin; k++) begin      // B reads (and writes) for as long as A runs
        int a, n;
        n = $urandom_range(1, 8);
        if ($urandom_range(0, 2) == 0) begin
            // a write burst into B's region, beats back to back (as vbuf presents them)
            a = $urandom_range(3072, 4088);
            for (int j = 0; j < n; j++) begin
                logic [63:0] d;
                d = {$urandom, $urandom};
                @(negedge clk);
                b_address = BASE + a; b_burstcount = n; b_write = 1; b_writedata = d;
                @(posedge clk); while (b_waitrequest) @(posedge clk);
                sb[a + j] = d;
            end
            @(negedge clk); b_write = 0;
        end else begin
            a = $urandom_range(2048, 4088);
            @(negedge clk);
            b_address = BASE + a; b_burstcount = n; b_read = 1;
            @(posedge clk); while (b_waitrequest) @(posedge clk);
            for (int j = 0; j < n; j++) qb.push_back(sb[a + j]);
            @(negedge clk); b_read = 0;
        end
        repeat ($urandom_range(0, 6)) @(negedge clk);
    end
    b_fin = 1;
end
initial begin
    // done when both masters are (B's writes lengthen the long-latency arm to ~8 ms);
    // 12 ms without that is a hung port
    fork
        wait (a_fin && b_fin);
        #12_000_000;
    join_any
    repeat (400) @(posedge clk);             // the last read beats land
    if (!a_fin || !b_fin) `FAIL("count", $sformatf("a master never finished (A %0d, B %0d): the port hung", a_fin, b_fin))
    if (stream_b == 0) `FAIL("count", "B issued nothing while A streamed (the fairness arm is vacuous)")
    if (b_wait_max > 40) `FAIL("count", $sformatf("B waited %0d cycles for the channel", b_wait_max))
    if (qa.size() != 0 || qb.size() != 0) `FAIL("count", $sformatf("beats outstanding: A %0d B %0d", qa.size(), qb.size()))
    if (aborts != 5) `FAIL("abort", $sformatf("%0d aborts ran", aborts))
    if (b_abort_in_burst == 0) `FAIL("grant", "no abort landed inside a B write burst (the arm is vacuous)")
    if (b_wr_beats < 200) `FAIL("grant", $sformatf("B wrote only %0d beats", b_wr_beats))
    if (b_wwait_max > 400) `FAIL("grant", $sformatf("a B write waited %0d cycles", b_wwait_max))
    if (swallowed == 0) `FAIL("abort", "no beat was in flight at the first abort (the arm is vacuous)")
    if (need_full && max_out < 16) `FAIL("count", $sformatf("the owner FIFO never filled (%0d bursts at most)", max_out))
    if (b_during_a < 100) `FAIL("count", $sformatf("B served only %0d beats while A was busy", b_during_a))
    $display("ddr_mux2_tb: A %0d read beats, B %0d (%0d while A was busy) and %0d write beats (longest wait %0d), %0d swallowed by the aborts, %0d bursts in flight at most, B waited %0d cycles at most while A streamed (%0d commands)",
             na, nb, b_during_a, b_wr_beats, b_wwait_max, swallowed, max_out, b_wait_max, stream_b);
    $display("PASS: ddr_mux2_tb");
    $finish;
end
endmodule
