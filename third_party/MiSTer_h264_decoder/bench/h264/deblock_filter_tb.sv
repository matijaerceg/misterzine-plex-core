// bench/h264/deblock_filter_tb.sv -- deblock_filter against tools/h264_recon_ref.py's
// filter_line (fixtures from tools/deblock_golden.py)
//
// +stem=<path>: <stem>.in.hex (128-bit words: {cls, beta_off, alpha_off, qp_q, qp_p,
// chroma, bs, p3..q3}), .exp.hex (64-bit: {changed, p2o..q2o}), .meta.hex ([0] cases).
// +stall=N: with N > 0 about one cycle in N carries no line (in_valid low) and the inputs
// are driven with garbage in it, so a unit that samples without looking at in_valid is
// seen. +only=<class>: score that class alone (the --red arm's proof that the class
// written for a defect is the one that sees it).
//
//   [out]    every output line equals the model's (`!==`: an X is a mismatch), p2o..q2o
//            and changed (filterSamplesFlag); a failure names the case's class
//   [lat]    out_valid is in_valid delayed by exactly LATENCY cycles, never otherwise
//   [count]  the number of output lines equals the number of cases
//
// A mismatch is tallied per class (the first of every class printed in full) and the
// bench $fatals after the stream with "FAILCLS: <class>=<count> ..."; the PASS marker
// "PASS: deblock_filter_tb" is printed only when nothing failed.
`timescale 1ns/1ps
module deblock_filter_tb;

localparam MAXC = 1 << 17;
localparam LATENCY = 3;
localparam NCLS = 12;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

function string cls_name(input integer c);
    case (c)
        0: cls_name = "alpha";   1: cls_name = "beta";    2: cls_name = "tc0";     3: cls_name = "tcc";
        4: cls_name = "p1";      5: cls_name = "strong";  6: cls_name = "c4";      7: cls_name = "dclip";
        8: cls_name = "idxclip"; 9: cls_name = "pcm";     10: cls_name = "rand";   11: cls_name = "real";
        default: cls_name = "?";
    endcase
endfunction

// ---- DUT ---------------------------------------------------------------------------
reg         in_valid = 1'b0;
reg  [7:0]  p3 = 8'd0, p2 = 8'd0, p1 = 8'd0, p0 = 8'd0, q0 = 8'd0, q1 = 8'd0, q2 = 8'd0, q3 = 8'd0;
reg  [2:0]  bs = 3'd0;
reg         chroma = 1'b0;
reg  [5:0]  qp_p = 6'd0, qp_q = 6'd0;
reg  signed [4:0] alpha_off = 5'sd0, beta_off = 5'sd0;
wire        out_valid, changed;
wire [7:0]  p2o, p1o, p0o, q0o, q1o, q2o;
deblock_filter dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .p3(p3), .p2(p2), .p1(p1), .p0(p0), .q0(q0), .q1(q1), .q2(q2), .q3(q3),
    .bs(bs), .chroma(chroma), .qp_p(qp_p), .qp_q(qp_q), .alpha_off(alpha_off), .beta_off(beta_off),
    .out_valid(out_valid), .p2o(p2o), .p1o(p1o), .p0o(p0o), .q0o(q0o), .q1o(q1o), .q2o(q2o),
    .changed(changed));

// ---- fixture ---------------------------------------------------------------------------
reg  [127:0] in_m  [0:MAXC-1];
reg  [63:0]  exp_m [0:MAXC-1];
reg  [31:0]  meta  [0:3];
integer      sel   [0:MAXC-1];      // the case indices to play (all, or one class)
string  stem, only;
integer stall = 0, n_cases, n_sel, k, only_idx;
integer seed_v = 7;

// ---- the driver and the scoreboard -------------------------------------------------------
integer di = 0;                     // next selected case to drive
integer oi = 0;                     // next selected case to score
integer n_out = 0, n_fail = 0, n_on = 0;
integer fail_cls [0:NCLS-1];
reg  [LATENCY-1:0] vpipe = {LATENCY{1'b0}};
reg  [127:0] w;
reg  [63:0]  e;
reg  [47:0]  got;
integer c, idle;

initial begin
    for (k = 0; k < NCLS; k = k + 1) fail_cls[k] = 0;
    if (!$value$plusargs("stem=%s", stem)) stem = "bench/h264/fixtures/gen/deblock_filter";
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    if (!$value$plusargs("only=%s", only)) only = "";
    $readmemh({stem, ".meta.hex"}, meta);
    $readmemh({stem, ".in.hex"}, in_m);
    $readmemh({stem, ".exp.hex"}, exp_m);
    n_cases = meta[0];
    if (n_cases <= 0 || n_cases > MAXC) `FAIL("count", $sformatf("bad case count %0d", n_cases))
    only_idx = -1;
    for (k = 0; k < NCLS; k = k + 1) if (only == cls_name(k)) only_idx = k;
    if (only != "" && only_idx < 0) `FAIL("count", {"unknown class ", only})
    n_sel = 0;
    for (k = 0; k < n_cases; k = k + 1)
        if (only_idx < 0 || in_m[k][97:90] == only_idx[7:0]) begin sel[n_sel] = k; n_sel = n_sel + 1; end
    if (n_sel == 0) `FAIL("count", {"no case of class ", only})
    if (only != "") $display("deblock_filter_tb: %0d cases, %0d selected of class %0s, stall %0d", n_cases, n_sel, only, stall);
    else $display("deblock_filter_tb: %0d cases, stall %0d", n_cases, stall);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    // drive: one selected case per cycle, an idle cycle about every `stall`
    while (di < n_sel) begin
        @(posedge clk);
        idle = (stall > 0) && (($urandom(seed_v) % stall) == 0);
        if (idle) begin
            in_valid <= 1'b0;
            {p3, p2, p1, p0, q0, q1, q2, q3} <= {$urandom(seed_v), $urandom(seed_v)};
            bs <= $urandom(seed_v); chroma <= $urandom(seed_v);
            qp_p <= $urandom(seed_v); qp_q <= $urandom(seed_v);
            alpha_off <= $urandom(seed_v); beta_off <= $urandom(seed_v);
        end else begin
            w = in_m[sel[di]];
            in_valid <= 1'b1;
            {p3, p2, p1, p0, q0, q1, q2, q3} <= w[63:0];
            bs <= w[66:64]; chroma <= w[67];
            qp_p <= w[73:68]; qp_q <= w[79:74];
            alpha_off <= w[84:80]; beta_off <= w[89:85];
            di = di + 1;
        end
    end
    @(posedge clk);
    in_valid <= 1'b0;
    repeat (LATENCY + 4) @(posedge clk);
    if (n_out !== n_sel) `FAIL("count", $sformatf("%0d output lines for %0d cases", n_out, n_sel))
    if (n_fail != 0) begin
        $write("FAILCLS:");
        for (k = 0; k < NCLS; k = k + 1) if (fail_cls[k] != 0) $write(" %0s=%0d", cls_name(k), fail_cls[k]);
        $display("");
        $display("FAIL [out] %0d of %0d lines differ from the model", n_fail, n_sel);
        $fatal(1);
    end
    $display("deblock_filter_tb: %0d lines, %0d with filterSamplesFlag, latency %0d, stall %0d", n_out, n_on, LATENCY, stall);
    $display("PASS: deblock_filter_tb");
    $finish;
end

// the latency arm and the scoreboard, at the clock edge the outputs are registered on
always @(posedge clk) if (rst_n) begin
    vpipe <= {vpipe[LATENCY-2:0], in_valid};
    if (out_valid !== vpipe[LATENCY-1])
        `FAIL("lat", $sformatf("out_valid %b, expected %b (in_valid delayed %0d)", out_valid, vpipe[LATENCY-1], LATENCY))
    if (out_valid) begin
        if (oi >= n_sel) `FAIL("count", "an output line beyond the last case")
        w = in_m[sel[oi]];
        e = exp_m[sel[oi]];
        got = {p2o, p1o, p0o, q0o, q1o, q2o};
        c = w[97:90];
        if (c >= NCLS) c = NCLS - 1;
        n_out = n_out + 1;
        if (e[48]) n_on = n_on + 1;
        if (got !== e[47:0] || changed !== e[48]) begin
            if (fail_cls[c] == 0)
                $display("FAIL [out] case %0d (%0s): bs %0d chroma %0d qp %0d/%0d off %0d/%0d in %h -> got %h ch %b, model %h ch %b",
                         sel[oi], cls_name(c), w[66:64], w[67], w[73:68], w[79:74], $signed(w[84:80]), $signed(w[89:85]),
                         w[63:0], got, changed, e[47:0], e[48]);
            fail_cls[c] = fail_cls[c] + 1;
            n_fail = n_fail + 1;
        end
        oi = oi + 1;
    end
end

endmodule
