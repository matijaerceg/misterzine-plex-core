// bench/h264/dequant_itrans_tb.sv -- dequant_itrans and dequant_itrans8 against
// tools/h264_recon_ref.py (dequant4x4 + itrans4x4, luma_dc, chroma_dc; dequant8x8 +
// itrans8x8) through tools/itrans_golden.py fixtures.
//
// +stem=<path>: a fixture set (.meta.hex / .blk.hex / .coef.hex / .exp.hex / .w.hex; word
// orders in itrans_golden.py's header). Kinds 0..4 go to dequant_itrans, kind 5 (an 8x8
// block, High profile) to dequant_itrans8, as the reconstruction's residual engine routes
// them; both read their weights from the fixture's scaling matrix (.w.hex: the 4x4 lists at
// words 0..23, the 8x8 ones at 24..55) through a registered RAM model, a block's own
// {weighted, list} bits choosing flat or its list. Every block is started when `busy` is low, its levels
// fed in scan order through the coefficient handshake, its outputs taken through the
// residual handshake. +stall=N (N > 0): the producer withholds `start` and `coef_valid`
// at random and the consumer withholds `res_ready` at random, seeded with N (so the
// output buffer's back-pressure into the column pass and the overlap of one block's
// output stream with the next block's intake are both exercised); +stall=0 is the
// throughput measurement (a coefficient every cycle, a consumer always ready). N >= 100: as
// N > 0, but the consumer is ready one cycle in eight -- the backlog that fills every stage
// of dequant_itrans8's pipeline ([flight], docs/mb_pipeline.md S4j).
//
//   [res]    every output word equals the model's (`!==`), in order, block after block
//   [last]   res_last set on exactly the last word of each block (16, or 4 for CDC)
//   [x]      res_valid is never X
//   [hang]   an output within 2000 cycles of the previous one while words are owed
//   [count]  exactly n_out words came out, and nothing more once the last block is done
//   [flight] at most four 8x8 blocks started and not yet fully out (dequant_itrans8's contract
//            with recon_mb's four-entry collector FIFO, docs/mb_pipeline.md S4j)
//
// Reports "dequant_itrans_tb: <stem>: blocks N out N cycles N samples/cycle S
// cycles/block C" (cycles from the first `start` to the last accepted output).
// PASS marker: "PASS: dequant_itrans_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module dequant_itrans_tb;

localparam MAXB = 1 << 14;
localparam MAXW = 1 << 18;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT --------------------------------------------------------------------------------
reg         start = 1'b0;
reg  [2:0]  kind = 3'd0;
reg  [5:0]  qp = 6'd0;
reg         field_scan = 1'b0;
reg  signed [15:0] dc_in = 16'sd0;
reg         wflat = 1'b1;
reg  [2:0]  wlist = 3'd0;
reg         coef_valid = 1'b0;
reg  signed [15:0] coef = 16'sd0;
reg         res_ready = 1'b0;
// the scaling matrix (56 words) and its two read ports, registered like recon_hdr's RAMs
reg  [31:0] wmem [0:55];
wire [4:0]  w_ra4, w_ra8;
reg  [31:0] w_q4 = 32'd0, w_q8 = 32'd0;
always @(posedge clk) begin
    w_q4 <= wmem[w_ra4];
    w_q8 <= wmem[6'd24 + {1'b0, w_ra8}];
end
// the unit a block goes to: sel_in (the block being fed), sel_out (the block being received)
reg         sel_in = 1'b0;
wire        sel_out;
wire        coef_ready4, res_valid4, res_last4, busy4, coef_ready8, res_valid8, res_last8, busy8;
wire signed [15:0] res4, res8;
dequant_itrans dut (
    .clk(clk), .rst_n(rst_n),
    .start(start && !sel_in), .kind(kind), .qp(qp), .field_scan(field_scan), .dc_in(dc_in),
    .wflat(wflat), .wlist(wlist), .w_ra(w_ra4), .w_q(w_q4),
    .coef_valid(coef_valid && !sel_in), .coef(coef), .coef_ready(coef_ready4),
    .res_valid(res_valid4), .res(res4), .res_last(res_last4), .res_ready(res_ready && !sel_out),
    .busy(busy4));
dequant_itrans8 dut8 (
    .clk(clk), .rst_n(rst_n),
    .start(start && sel_in), .qp(qp), .field_scan(field_scan),
    .wflat(wflat), .wlist(wlist[0]), .w_ra(w_ra8), .w_q(w_q8),
    .coef_valid(coef_valid && sel_in), .coef(coef), .coef_ready(coef_ready8),
    .res_valid(res_valid8), .res(res8), .res_last(res_last8), .res_ready(res_ready && sel_out),
    .busy(busy8));
wire        coef_ready = sel_in ? coef_ready8 : coef_ready4;
wire        res_valid  = sel_out ? res_valid8 : res_valid4;
wire        res_last   = sel_out ? res_last8 : res_last4;
wire signed [15:0] res = sel_out ? res8 : res4;
wire        busy = busy4 || busy8;

// ---- fixture --------------------------------------------------------------------------
reg  [31:0] blk_m  [0:MAXB-1];
reg  [15:0] coef_m [0:MAXW-1];
reg  [15:0] exp_m  [0:MAXW-1];
reg  [31:0] meta   [0:7];
string  stem;
integer stall = 0, seed, k;
integer n_blocks, n_coef, n_out;

function integer ncoef_of(input [2:0] kk);
    ncoef_of = (kk == 3'd5) ? 64 : (kk == 3'd4) ? 4 : ((kk == 3'd1 || kk == 3'd2) ? 15 : 16);
endfunction
function integer nout_of(input [2:0] kk);
    nout_of = (kk == 3'd5) ? 64 : (kk == 3'd4) ? 4 : 16;
endfunction

// ---- producer: start when busy is low, then the levels in scan order ----------------
reg     run = 1'b0;
integer pb = 0;            // the block being fed
integer pc = 0;            // coefficients accepted of this block
integer pbase = 0;         // index of this block's first level in coef_m
reg     in_block = 1'b0;
integer n_start = 0;
integer n_start8 = 0, n_done8 = 0;  // 8x8 blocks started / fully out ([flight])
wire [31:0] pw = blk_m[pb];
always @(posedge clk) begin
    if (run) begin
        start <= 1'b0;
        if (!in_block) begin
            if (pb < n_blocks && !busy && !start && (stall == 0 || ($urandom % 3) != 0)) begin
                start      <= 1'b1;
                kind       <= pw[31:29];
                sel_in     <= (pw[31:29] == 3'd5);
                field_scan <= pw[28];
                qp         <= pw[27:22];
                wflat      <= !pw[21];
                // the list: 0..5 for the 4x4 unit, 6 / 7 -> the 8x8 unit's 0 / 1
                wlist      <= (pw[31:29] == 3'd5) ? {2'b00, pw[18]} : pw[20:18];
                dc_in      <= pw[15:0];
                in_block   <= 1'b1;
                pc         <= 0;
                n_start    <= n_start + 1;
                if (pw[31:29] == 3'd5) n_start8 <= n_start8 + 1;
            end
        end else if (coef_valid && coef_ready) begin
            pc <= pc + 1;
            if (pc + 1 == ncoef_of(pw[31:29])) begin
                coef_valid <= 1'b0;
                in_block   <= 1'b0;
                pbase      <= pbase + ncoef_of(pw[31:29]);
                pb         <= pb + 1;
            end else if (stall == 0 || ($urandom % 3) != 0) begin
                coef <= coef_m[pbase + pc + 1];
            end else coef_valid <= 1'b0;
        end else if (!coef_valid) begin
            if (stall == 0 || ($urandom % 3) != 0) begin
                coef       <= coef_m[pbase + pc];
                coef_valid <= 1'b1;
            end
        end
    end
end

// ---- consumer: random ready, every word scored ---------------------------------------
integer ob = 0;            // the block being received
integer oc = 0;            // words received of this block
integer oi = 0;            // words received in all
integer idle = 0;
integer t_first = -1, t_last = -1, cyc = 0;
wire [31:0] ow = blk_m[ob];
assign sel_out = (ow[31:29] == 3'd5);
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (run) begin
        res_ready <= (stall == 0) ? 1'b1 : (stall >= 100) ? (($urandom % 8) == 0) : (($urandom % 4) != 0);
        if (start && t_first < 0) t_first = cyc;
        if (res_valid !== 1'b0 && res_valid !== 1'b1) `FAIL("x", "res_valid is X")
        if (n_start8 - n_done8 > 4) `FAIL("flight", $sformatf("%0d 8x8 blocks in flight", n_start8 - n_done8))
        if (res_valid && res_ready) begin
            if (oi >= n_out) `FAIL("count", $sformatf("output %0d beyond the fixture's %0d", oi, n_out))
            if (res !== $signed(exp_m[oi]))
                `FAIL("res", $sformatf("block %0d kind %0d qp %0d field %0d word %0d: got %0d expected %0d",
                                       ob, ow[31:29], ow[27:22], ow[28], oc, res, $signed(exp_m[oi])))
            if (res_last !== (oc + 1 == nout_of(ow[31:29])))
                `FAIL("last", $sformatf("block %0d kind %0d word %0d: res_last %0d", ob, ow[31:29], oc, res_last))
            oi <= oi + 1;
            t_last = cyc;
            if (oc + 1 == nout_of(ow[31:29])) begin
                if (ow[31:29] == 3'd5) n_done8 <= n_done8 + 1;
                oc <= 0;
                ob <= ob + 1;
            end else oc <= oc + 1;
            idle <= 0;
        end else begin
            idle <= idle + 1;
            if (idle > 2000 && oi < n_out)
                `FAIL("hang", $sformatf("no output for 2000 cycles at word %0d of %0d (block %0d, busy %0d)", oi, n_out, ob, busy))
        end
    end
end

// ---- main -----------------------------------------------------------------------------
integer i;
initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    seed = stall;
    k = $urandom(seed);
    for (i = 0; i < 8; i = i + 1) meta[i] = 32'd0;
    $readmemh({stem, ".meta.hex"}, meta);
    n_blocks = meta[0]; n_coef = meta[1]; n_out = meta[2];
    if (n_blocks <= 0 || n_blocks > MAXB) `FAIL("harness", $sformatf("n_blocks %0d", n_blocks))
    if (n_coef <= 0 || n_coef > MAXW || n_out <= 0 || n_out > MAXW) `FAIL("harness", "fixture too large")
    $readmemh({stem, ".blk.hex"}, blk_m, 0, n_blocks - 1);
    $readmemh({stem, ".coef.hex"}, coef_m, 0, n_coef - 1);
    $readmemh({stem, ".exp.hex"}, exp_m, 0, n_out - 1);
    for (i = 0; i < 56; i = i + 1) wmem[i] = 32'h10101010;
    $readmemh({stem, ".w.hex"}, wmem, 0, 55);
    // the counts must agree with the kinds (a short or torn fixture is a harness failure)
    begin : chk
        integer sc, so;
        sc = 0; so = 0;
        for (i = 0; i < n_blocks; i = i + 1) begin
            if (blk_m[i][31:29] > 3'd5) `FAIL("harness", $sformatf("block %0d kind %0d", i, blk_m[i][31:29]))
            sc = sc + ncoef_of(blk_m[i][31:29]);
            so = so + nout_of(blk_m[i][31:29]);
        end
        if (sc != n_coef || so != n_out) `FAIL("harness", $sformatf("meta counts %0d/%0d vs kinds %0d/%0d", n_coef, n_out, sc, so))
        for (i = 0; i < n_out; i = i + 1)
            if (exp_m[i] !== exp_m[i]) `FAIL("harness", "expected word X")
    end

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    run = 1'b1;
    while (oi < n_out) @(posedge clk);
    // nothing more may come out, and the DUT must go idle
    repeat (60) @(posedge clk);
    if (oi != n_out) `FAIL("count", $sformatf("got %0d words, expected %0d", oi, n_out))
    if (ob != n_blocks) `FAIL("count", $sformatf("received %0d blocks of %0d", ob, n_blocks))
    if (n_start != n_blocks) `FAIL("count", $sformatf("started %0d blocks of %0d", n_start, n_blocks))
    if (busy !== 1'b0 || res_valid !== 1'b0) `FAIL("count", "not idle after the last block")
    $display("dequant_itrans_tb: %0s: blocks %0d out %0d cycles %0d samples/cycle %.3f cycles/block %.1f",
             stem, n_blocks, n_out, t_last - t_first + 1,
             $itor(n_out) / $itor(t_last - t_first + 1),
             $itor(t_last - t_first + 1) / $itor(n_blocks));
    $display("PASS: dequant_itrans_tb");
    $finish;
end

endmodule
