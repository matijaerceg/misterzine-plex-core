// bench/h264/wpred_tb.sv -- wpred against the spec transcription of 8.4.2.3 in
// tools/mc_golden.py (fixtures from --out-wp; the transcription cross-checked there
// against h264_recon_ref.py's SliceDecoder.weighted on a real weighted clip)
//
// +stem=<path>: <stem>.case.hex (3 words per case: {mode, bi, logwd, n}, {w0, w1},
// {o0, o1}), .a.hex / .b.hex (n bytes each per case), .exp.hex (n samples), .meta.hex.
// Per case the bench pulses start with the parameters and offers the a and b streams
// from two producers (+stall=N: each valid ~2/3 of the cycles, held until taken; 0:
// always valid) that keep offering POISON after their n samples, and collects the
// output with a random-ready consumer (+stall: ready ~2/3 of the cycles).
//
//   [out]      every sample equals the golden (`!==`), in order; a failure names the
//              case's class as <D|E|I>/<single|bi> [lw<n>] [oz] [clip]
//   [last]     out_last exactly on the n-th sample
//   [count]    n samples out, exactly n taken from a, exactly n from b when bi and NONE
//              when single (the poison after n must never be taken)
//   [busy]     busy high through the case and low two cycles after the last sample
//   [hang]     a sample within 300 cycles of the previous
//   [rate]     with +stall=0: a case of n samples takes at most n + LAT_MAX cycles
//
// PASS marker: "PASS: wpred_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module wpred_tb;

localparam MAXC = 1 << 13;          // cases
localparam MAXS = 1 << 20;          // samples
localparam LAT_MAX = 6;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT ---------------------------------------------------------------------------
reg               start = 1'b0, bi = 1'b0;
reg         [1:0] mode = 2'd0;
reg         [2:0] logwd = 3'd0;
reg  signed [8:0] w0 = 9'sd0, w1 = 9'sd0;
reg  signed [7:0] o0 = 8'sd0, o1 = 8'sd0;
reg         [8:0] n = 9'd0;
reg               a_valid = 1'b0, b_valid = 1'b0;
wire        [7:0] a, b;
wire              a_ready, b_ready, out_valid, out_last, busy;
wire        [7:0] out;
reg               out_ready = 1'b0;
wpred dut (
    .clk(clk), .rst_n(rst_n),
    .start(start), .bi(bi), .mode(mode), .logwd(logwd), .w0(w0), .w1(w1), .o0(o0), .o1(o1), .n(n),
    .a_valid(a_valid), .a(a), .a_ready(a_ready),
    .b_valid(b_valid), .b(b), .b_ready(b_ready),
    .out_valid(out_valid), .out(out), .out_last(out_last), .out_ready(out_ready),
    .busy(busy));

// ---- fixture ---------------------------------------------------------------------------
reg  [31:0] case_m [0:3*MAXC-1];
reg  [7:0]  a_m    [0:MAXS-1];
reg  [7:0]  b_m    [0:MAXS-1];
reg  [7:0]  exp_m  [0:MAXS-1];
reg  [31:0] meta   [0:15];
string  stem;
integer stall = 0, n_cases, n_samp, seed_v, k;

// ---- the producers and the consumer --------------------------------------------------
integer ci = 0, si = 0, ai = 0, bi_i = 0, soff = 0, n_case = 0, idle_cyc = 0, active = 0;
string  cls;
// a sample stays on the port until taken; past n the port carries poison
assign a = (ai < n_case) ? a_m[soff + ai] : (8'hA5 ^ ai[7:0]);
assign b = (bi_i < n_case) ? b_m[soff + bi_i] : (8'h5A ^ bi_i[7:0]);
always @(posedge clk) begin
    if (rst_n) begin
        if (active) begin
            if (a_valid && a_ready) begin
                ai <= ai + 1;
                if (ai >= n_case) `FAIL("count", $sformatf("case %0d (%0s): a sample taken beyond the %0d", ci, cls, n_case))
            end
            if (b_valid && b_ready) begin
                bi_i <= bi_i + 1;
                if (!bi) `FAIL("count", $sformatf("case %0d (%0s): a b sample taken in a single-list case", ci, cls))
                if (bi_i >= n_case) `FAIL("count", $sformatf("case %0d (%0s): b sample taken beyond the %0d", ci, cls, n_case))
            end
            if (!a_valid || a_ready) a_valid <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
            if (!b_valid || b_ready) b_valid <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
            out_ready <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
            if (out_valid && out_ready) begin
                idle_cyc <= 0;
                if (out !== exp_m[soff + si])
                    `FAIL("out", $sformatf("case %0d (%0s) sample %0d: got %0d want %0d", ci, cls, si, out, exp_m[soff + si]))
                if (out_last !== (si == n_case - 1))
                    `FAIL("last", $sformatf("case %0d (%0s) sample %0d: out_last %0d", ci, cls, si, out_last))
                if (si >= n_case)
                    `FAIL("count", $sformatf("case %0d (%0s): more than %0d samples", ci, cls, n_case))
                si <= si + 1;
            end else begin
                idle_cyc <= idle_cyc + 1;
                if (idle_cyc > 300) `FAIL("hang", $sformatf("case %0d (%0s): no sample for 300 cycles after sample %0d", ci, cls, si))
            end
            if (!busy && !out_valid && si !== n_case)
                `FAIL("busy", $sformatf("case %0d (%0s): busy dropped after %0d of %0d samples", ci, cls, si, n_case))
        end else begin
            a_valid <= 1'b0; b_valid <= 1'b0; out_ready <= 1'b0;
        end
    end
end

integer wait_cyc, t_start, t_all, cyc, tot_cyc = 0, n_clip = 0;
reg [31:0] w_cs, w_w, w_o;
reg [7:0]  w_mode, w_bi, w_lw, w_src, w_clip;
integer    n_clip_seen = 0;
initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    seed_v = stall + 13; k = $urandom(seed_v);
    $readmemh({stem, ".meta.hex"}, meta);
    n_cases = meta[0]; n_samp = meta[1]; n_clip = meta[3];
    if (n_cases > MAXC || n_samp > MAXS) `FAIL("harness", "fixture too large")
    if (n_cases == 0) `FAIL("harness", "no cases")
    $readmemh({stem, ".case.hex"}, case_m, 0, 3 * n_cases - 1);
    $readmemh({stem, ".a.hex"}, a_m, 0, n_samp - 1);
    $readmemh({stem, ".b.hex"}, b_m, 0, n_samp - 1);
    $readmemh({stem, ".exp.hex"}, exp_m, 0, n_samp - 1);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    if (busy !== 1'b0) `FAIL("busy", "busy after reset")
    t_all = $time;

    for (ci = 0; ci < n_cases; ci = ci + 1) begin
        w_cs = case_m[3 * ci]; w_w = case_m[3 * ci + 1]; w_o = case_m[3 * ci + 2];
        w_mode = w_cs[31:28]; w_bi = w_cs[27:24]; w_lw = w_cs[23:20]; w_src = w_cs[19:16]; w_clip = w_cs[15:12];
        if (w_src > 2 || w_clip > 1 || w_mode > 1 || w_bi > 1 || w_lw > 7 || w_cs[11:0] == 0 || w_cs[11:0] > 256)
            `FAIL("harness", $sformatf("case %0d: bad case word %08x", ci, w_cs))
        mode = w_mode[1:0]; bi = w_bi[0]; logwd = w_lw[2:0]; n = w_cs[8:0];
        w0 = w_w[24:16]; w1 = w_w[8:0]; o0 = w_o[23:16]; o1 = w_o[7:0];
        if (w_w[31:25] != {7{w_w[24]}} || w_w[15:9] != {7{w_w[8]}} || w_o[31:24] != {8{w_o[23]}} || w_o[15:8] != {8{w_o[7]}})
            `FAIL("harness", $sformatf("case %0d: a weight or offset outside its port width", ci))
        if (w_clip[0]) n_clip_seen = n_clip_seen + 1;
        n_case = n;
        if (w_src == 0) cls = "D/"; else if (w_src == 1) cls = "E/"; else cls = "I/";
        if (bi) cls = {cls, "bi"}; else cls = {cls, "single"};
        if (w_src != 0) cls = {cls, $sformatf(" lw%0d", logwd)};
        if (w_src != 0 && bi && o0 == 0 && o1 == 0) cls = {cls, " oz"};
        if (w_clip[0]) cls = {cls, " clip"};
        si = 0; ai = 0; bi_i = 0; idle_cyc = 0;
        t_start = $time;
        start = 1'b1; @(posedge clk); #1; start = 1'b0;
        if (busy !== 1'b1) `FAIL("busy", $sformatf("case %0d (%0s): busy not raised by start", ci, cls))
        active = 1;
        wait_cyc = 0;
        while (busy) begin
            @(posedge clk); #1; wait_cyc = wait_cyc + 1;
            if (wait_cyc > 4000) `FAIL("hang", $sformatf("case %0d (%0s): busy for 4000 cycles", ci, cls))
        end
        @(posedge clk); #1;
        active = 0;
        if (si !== n_case) `FAIL("count", $sformatf("case %0d (%0s): %0d samples, want %0d", ci, cls, si, n_case))
        if (ai !== n_case) `FAIL("count", $sformatf("case %0d (%0s): %0d a samples taken, want %0d", ci, cls, ai, n_case))
        if (bi_i !== (bi ? n_case : 0)) `FAIL("count", $sformatf("case %0d (%0s): %0d b samples taken", ci, cls, bi_i))
        if (out_valid !== 1'b0) `FAIL("busy", $sformatf("case %0d (%0s): out_valid after busy", ci, cls))
        cyc = ($time - t_start) / 10 - 1;
        tot_cyc = tot_cyc + cyc;
        if (stall == 0 && cyc > n_case + LAT_MAX)
            `FAIL("rate", $sformatf("case %0d (%0s): %0d cycles for %0d samples", ci, cls, cyc, n_case))
        soff = soff + n_case;
        @(posedge clk); #1;
        if (busy !== 1'b0 || out_valid !== 1'b0) `FAIL("busy", $sformatf("case %0d (%0s): not idle two cycles after the case", ci, cls))
    end
    if (soff !== n_samp) `FAIL("count", $sformatf("%0d samples scored, fixture holds %0d", soff, n_samp))
    if (n_clip_seen !== n_clip) `FAIL("harness", $sformatf("%0d clip cases seen, meta says %0d", n_clip_seen, n_clip))
    $display("wpred_tb: %0s: %0d cases (%0d from the clip), %0d samples in %0d case cycles: %0d.%02d samples/cycle (stall %0d)",
             stem, n_cases, n_clip, n_samp, tot_cyc, n_samp / tot_cyc, (100 * n_samp / tot_cyc) % 100, stall);
    $display("PASS: wpred_tb");
    $finish;
end

endmodule
