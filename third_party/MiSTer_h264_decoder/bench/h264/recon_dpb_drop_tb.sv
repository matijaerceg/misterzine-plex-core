`timescale 1ns/1ps
module recon_dpb_drop_tb;
    import h264_pkg::*;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg [NSTORE-1:0] mask;
    reg [4:0] current;
    integer expected;
    wire [31:0] out_dropped;
    integer i, j, trial;
    reg [31:0] rng = 32'h92a7_61d3;

    recon_dpb #(.STALL_LIMIT(100)) dut (
        .clk(clk), .rst_n(rst_n), .clear(1'b0), .out_dropped(out_dropped)
    );

    task automatic check_mask(input [NSTORE-1:0] m, input [4:0] cur);
        begin
            mask = m;
            current = cur;
            expected = 0;
            for (integer k = 0; k < NSTORE; k = k + 1)
                if (m[k] && k[4:0] != cur) expected = expected + 1;
            force dut.waiting = mask;
            force dut.cur_store = current;
            #1;
            if (dut.drop_count !== expected[5:0])
                $fatal(1, "drop tree mask=%h current=%0d got=%0d want=%0d", m, cur, dut.drop_count, expected);

            // Exercise the actual D_OUT_C44 capture and its existing one-cycle
            // status update, not just the combinational reduction output.
            force dut.cur_idr = 1'b1;
            force dut.cur_mmco5 = 1'b0;
            force dut.cur_no_output = 1'b1;
            force dut.ds = 6'd13; // D_OUT_C44 in dstate_t
            @(posedge clk); #1;
            if (dut.drop_n !== expected[5:0] || dut.drop_go !== 1'b1)
                $fatal(1, "D_OUT_C44 mask=%h current=%0d drop_n=%0d drop_go=%b want=%0d/1", m, cur, dut.drop_n, dut.drop_go, expected);
            @(negedge clk); #1;
            release dut.ds;
            release dut.cur_no_output;
            release dut.cur_mmco5;
            release dut.cur_idr;
            release dut.cur_store;
            release dut.waiting;
        end
    endtask

    initial begin
        mask = '0; current = '0;
        repeat (2) @(posedge clk);
        #1 rst_n = 1'b1;
        // Every current-store exclusion, empty/full, each singleton, and
        // varied dense/sparse masks exercise the real parameterized RTL.
        for (i = 0; i < NSTORE; i = i + 1) begin
            check_mask('0, i[4:0]);
            check_mask({NSTORE{1'b1}}, i[4:0]);
            check_mask({{(NSTORE-1){1'b0}},1'b1} << i, i[4:0]);
        end
        for (trial = 0; trial < 4096; trial = trial + 1) begin
            rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
            mask = rng[NSTORE-1:0];
            check_mask(mask, rng[26:22] % NSTORE);
        end

        // Isolated public-counter check: a no-output IDR drops every waiting
        // store except the current one. This verifies the existing next-cycle
        // status update separately from the exhaustive combinational/tree arm.
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1 rst_n = 1'b1;
        @(negedge clk);
        force dut.waiting = {NSTORE{1'b1}};
        force dut.cur_store = 5'd3;
        force dut.cur_idr = 1'b1;
        force dut.cur_mmco5 = 1'b0;
        force dut.cur_no_output = 1'b1;
        force dut.ds = 6'd13;
        @(posedge clk); #1;
        if (dut.drop_n !== 6'd19 || dut.drop_go !== 1'b1)
            $fatal(1, "counter setup drop_n=%0d drop_go=%b want=19/1", dut.drop_n, dut.drop_go);
        @(negedge clk); #1;
        release dut.ds;
        release dut.cur_no_output;
        release dut.cur_mmco5;
        release dut.cur_idr;
        release dut.cur_store;
        release dut.waiting;
        @(posedge clk); #1;
        if (out_dropped !== 32'd19)
            $fatal(1, "out_dropped got=%0d want=19", out_dropped);
        $display("PASS: recon_dpb_drop_tb (%0d directed/random RTL cases)", 3*NSTORE + 4096);
        $finish;
    end
endmodule
