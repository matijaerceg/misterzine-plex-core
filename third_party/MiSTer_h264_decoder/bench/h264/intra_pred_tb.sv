// bench/h264/intra_pred_tb.sv -- intra_pred against tools/h264_recon_ref.py's intra
// predictors (fixtures from tools/intra_golden.py)
//
// +stem=<path>: <stem>.case.hex ({kind, mode, avail_top, avail_left} per case), .nb.hex
// (33 store bytes per case), .exp.hex (the samples, 16 / 256 / 64 per case), .meta.hex.
// Per case the bench writes the 33 neighbours through the write port, pulses start, and
// collects the stream with a random-ready consumer (+stall=N: ready ~2/3 of the cycles;
// 0: always ready).
//
//   [pred]   every sample equals the model's (`!==`), in raster order; a failure names
//            the case's class as k<kind>/m<mode> a<top><left>
//   [last]   pred_last exactly on the block's final sample
//   [count]  the block's sample count
//   [busy]   busy high through the block and low two cycles after the last sample
//   [hang]   a sample within 600 cycles of the previous
//   [rate]   with +stall=0: samples per cycle over the run >= 0.75 (4x4 blocks dominate
//            the set; the per-kind cycles are printed)
//
// PASS marker: "PASS: intra_pred_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module intra_pred_tb;

localparam MAXC = 1 << 15;          // cases
localparam MAXE = 1 << 21;          // expected samples

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT ---------------------------------------------------------------------------
reg        nb_we = 1'b0;
reg  [5:0] nb_idx = 6'd0;
reg  [7:0] nb_val = 8'd0;
reg        start = 1'b0;
reg  [1:0] kind = 2'd0;
reg  [3:0] mode = 4'd0;
reg        avail_top = 1'b0, avail_left = 1'b0, avail_corner = 1'b0;
wire       pred_valid, pred_last, busy;
wire [7:0] pred;
reg        pred_ready = 1'b0;
intra_pred dut (
    .clk(clk), .rst_n(rst_n),
    .nb_we(nb_we), .nb_idx(nb_idx), .nb_val(nb_val),
    .start(start), .kind(kind), .mode(mode), .avail_top(avail_top), .avail_left(avail_left), .avail_corner(avail_corner),
    .pred_valid(pred_valid), .pred(pred), .pred_last(pred_last), .pred_ready(pred_ready),
    .busy(busy));

// ---- fixture ---------------------------------------------------------------------------
reg  [31:0] case_m [0:MAXC-1];
reg  [7:0]  nb_m   [0:33*MAXC-1];
reg  [7:0]  exp_m  [0:MAXE-1];
reg  [31:0] meta   [0:15];
string  stem;
integer stall = 0, n_cases, n_exp, n_nb, seed_v, k;

// ---- the consumer, scoring in order ----------------------------------------------------
integer ci = 0, si = 0, eoff = 0, n_blk = 0, idle_cyc = 0, collecting = 0;
integer cyc_kind [0:3];
integer blk_kind [0:3];
integer t_start, t_all;
string  cls;
always @(posedge clk) begin
    if (rst_n) begin
        pred_ready <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
        if (collecting) begin
            if (pred_valid && pred_ready) begin
                idle_cyc <= 0;
                if (pred !== exp_m[eoff + si])
                    `FAIL("pred", $sformatf("case %0d (%0s) sample %0d: got %0d want %0d", ci, cls, si, pred, exp_m[eoff + si]))
                if (pred_last !== (si == n_blk - 1))
                    `FAIL("last", $sformatf("case %0d (%0s) sample %0d: pred_last %0d", ci, cls, si, pred_last))
                if (si >= n_blk)
                    `FAIL("count", $sformatf("case %0d (%0s): more than %0d samples", ci, cls, n_blk))
                si <= si + 1;
            end else begin
                idle_cyc <= idle_cyc + 1;
                if (idle_cyc > 600) `FAIL("hang", $sformatf("case %0d (%0s): no sample for 600 cycles after sample %0d", ci, cls, si))
            end
            // busy falls on the edge the last sample is taken (si counts it on the same
            // edge), so a low busy with the count short means it dropped early
            if (!busy && !pred_valid && si !== n_blk)
                `FAIL("busy", $sformatf("case %0d (%0s): busy dropped after %0d of %0d samples", ci, cls, si, n_blk))
        end
    end
end

integer i, kk, ii, wait_cyc;
initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    seed_v = stall + 7; k = $urandom(seed_v);
    $readmemh({stem, ".meta.hex"}, meta);
    n_cases = meta[0]; n_exp = meta[1]; n_nb = meta[2];
    if (n_cases > MAXC || n_exp > MAXE || n_nb != 33 * n_cases) `FAIL("harness", "fixture too large or inconsistent")
    if (n_cases == 0) `FAIL("harness", "no cases")
    $readmemh({stem, ".case.hex"}, case_m, 0, n_cases - 1);
    $readmemh({stem, ".nb.hex"}, nb_m, 0, n_nb - 1);
    $readmemh({stem, ".exp.hex"}, exp_m, 0, n_exp - 1);
    for (kk = 0; kk < 4; kk = kk + 1) begin cyc_kind[kk] = 0; blk_kind[kk] = 0; end

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    if (busy !== 1'b0) `FAIL("busy", "busy after reset")
    t_all = $time;

    for (ci = 0; ci < n_cases; ci = ci + 1) begin
        kind = case_m[ci][25:24]; mode = case_m[ci][19:16];
        avail_top = case_m[ci][8]; avail_left = case_m[ci][0]; avail_corner = case_m[ci][1];
        if (case_m[ci][31:26] !== 6'd0 || case_m[ci][23:20] !== 4'd0 || (kind !== 2'd3 && case_m[ci][1] !== 1'b0)) `FAIL("harness", "bad case word")
        n_blk = (kind == 2'd0) ? 16 : (kind == 2'd1) ? 256 : 64;
        cls = $sformatf("k%0d/m%0d a%0d%0d", kind, mode, avail_top, avail_left);
        // the store
        for (i = 0; i < 33; i = i + 1) begin
            nb_we = 1'b1; nb_idx = i; nb_val = nb_m[33 * ci + i];
            @(posedge clk); #1;
        end
        nb_we = 1'b0;
        // the block
        si = 0; idle_cyc = 0;
        t_start = $time;
        start = 1'b1; @(posedge clk); #1; start = 1'b0;
        if (busy !== 1'b1) `FAIL("busy", $sformatf("case %0d (%0s): busy not raised by start", ci, cls))
        // the consumer watches from the edge after start (busy rose on it; the first
        // sample is two pipeline stages away, so nothing can be missed)
        collecting = 1;
        wait_cyc = 0;
        while (busy) begin
            @(posedge clk); #1; wait_cyc = wait_cyc + 1;
            if (wait_cyc > 2000) `FAIL("hang", $sformatf("case %0d (%0s): busy for 2000 cycles", ci, cls))
        end
        // busy fell on the edge the last sample was taken; the consumer's block sees it now
        @(posedge clk); #1;
        collecting = 0;
        if (si !== n_blk) `FAIL("count", $sformatf("case %0d (%0s): %0d samples, want %0d", ci, cls, si, n_blk))
        if (pred_valid !== 1'b0) `FAIL("busy", $sformatf("case %0d (%0s): pred_valid after busy", ci, cls))
        cyc_kind[kind] = cyc_kind[kind] + (($time - t_start) / 10);
        blk_kind[kind] = blk_kind[kind] + 1;
        eoff = eoff + n_blk;
        @(posedge clk); #1;
        if (busy !== 1'b0 || pred_valid !== 1'b0) `FAIL("busy", $sformatf("case %0d (%0s): not idle two cycles after the block", ci, cls))
    end
    if (eoff !== n_exp) `FAIL("count", $sformatf("%0d samples scored, fixture holds %0d", eoff, n_exp))
    $display("intra_pred_tb: %0s: %0d cases, %0d samples in %0d cycles (incl. 33 store writes/case); per block: 4x4 %0d.%0d cycles (%0d), 16x16 %0d.%0d (%0d), chroma %0d.%0d (%0d), 8x8 %0d.%0d (%0d)",
             stem, n_cases, n_exp, ($time - t_all) / 10,
             (blk_kind[0] ? cyc_kind[0] / blk_kind[0] : 0), (blk_kind[0] ? (10 * cyc_kind[0] / blk_kind[0]) % 10 : 0), blk_kind[0],
             (blk_kind[1] ? cyc_kind[1] / blk_kind[1] : 0), (blk_kind[1] ? (10 * cyc_kind[1] / blk_kind[1]) % 10 : 0), blk_kind[1],
             (blk_kind[2] ? cyc_kind[2] / blk_kind[2] : 0), (blk_kind[2] ? (10 * cyc_kind[2] / blk_kind[2]) % 10 : 0), blk_kind[2],
             (blk_kind[3] ? cyc_kind[3] / blk_kind[3] : 0), (blk_kind[3] ? (10 * cyc_kind[3] / blk_kind[3]) % 10 : 0), blk_kind[3]);
    $display("intra_pred_tb: samples/cycle over the blocks: %0d.%02d",
             (100 * n_exp / (cyc_kind[0] + cyc_kind[1] + cyc_kind[2] + cyc_kind[3])) / 100, (100 * n_exp / (cyc_kind[0] + cyc_kind[1] + cyc_kind[2] + cyc_kind[3])) % 100);
    if (stall == 0 && (100 * n_exp) < 75 * (cyc_kind[0] + cyc_kind[1] + cyc_kind[2]))
        `FAIL("rate", $sformatf("%0d samples in %0d block cycles", n_exp, cyc_kind[0] + cyc_kind[1] + cyc_kind[2]))
    $display("PASS: intra_pred_tb");
    $finish;
end

endmodule
