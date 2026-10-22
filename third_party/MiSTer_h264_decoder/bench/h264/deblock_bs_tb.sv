// bench/h264/deblock_bs_tb.sv -- deblock_bs against tools/h264_recon_ref.py's
// boundary_strength (fixtures from tools/deblock_golden.py)
//
// +stem=<path>: <stem>.in.hex (192-bit words: {cls, field, vertical, mb_edge, the q
// block, the p block}; a block = {intra, nz, pred0, pred1, refpic0, refpic1, mv0x, mv0y,
// mv1x, mv1y}), .exp.hex (4-bit bS), .meta.hex ([0] cases). +stall=N: with N > 0 about
// one cycle in N carries no pair (in_valid low) with garbage on the inputs. +only=<class>:
// score that class alone (the --red arm's proof that the class written for a defect is
// the one that sees it).
//
//   [bs]     every bS equals the model's (`!==`: an X is a mismatch); a failure names
//            the case's class
//   [lat]    out_valid is in_valid delayed by exactly LATENCY (1) cycle, never otherwise
//   [count]  the number of outputs equals the number of cases
//
// A mismatch is tallied per class (the first of every class printed in full) and the
// bench $fatals after the stream with "FAILCLS: <class>=<count> ..."; the PASS marker
// "PASS: deblock_bs_tb" is printed only when nothing failed.
`timescale 1ns/1ps
module deblock_bs_tb;

localparam MAXC = 1 << 17;
localparam LATENCY = 1;
localparam NCLS = 12;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

function string cls_name(input integer c);
    case (c)
        0: cls_name = "intra_mb"; 1: cls_name = "intra_in"; 2: cls_name = "flags"; 3: cls_name = "nz";
        4: cls_name = "nvec";     5: cls_name = "refset";   6: cls_name = "mv1h";  7: cls_name = "mv1v";
        8: cls_name = "mv2d";     9: cls_name = "mv2s";     10: cls_name = "rand"; 11: cls_name = "real";
        default: cls_name = "?";
    endcase
endfunction

// ---- DUT ---------------------------------------------------------------------------
reg         in_valid = 1'b0;
reg  [83:0] pb = 84'd0, qb = 84'd0;       // a block's fields as the fixture packs them
reg         mb_edge = 1'b0, vertical = 1'b0, field = 1'b0;
wire        out_valid;
wire [2:0]  bs;
deblock_bs dut (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid),
    .p_intra(pb[83]), .p_nz(pb[82]), .p_pred0(pb[81]), .p_pred1(pb[80]),
    .p_refpic0(pb[79:72]), .p_refpic1(pb[71:64]),
    .p_mv0x(pb[63:48]), .p_mv0y(pb[47:32]), .p_mv1x(pb[31:16]), .p_mv1y(pb[15:0]),
    .q_intra(qb[83]), .q_nz(qb[82]), .q_pred0(qb[81]), .q_pred1(qb[80]),
    .q_refpic0(qb[79:72]), .q_refpic1(qb[71:64]),
    .q_mv0x(qb[63:48]), .q_mv0y(qb[47:32]), .q_mv1x(qb[31:16]), .q_mv1y(qb[15:0]),
    .mb_edge(mb_edge), .vertical(vertical), .field(field),
    .out_valid(out_valid), .bs(bs));

// ---- fixture ---------------------------------------------------------------------------
reg  [191:0] in_m  [0:MAXC-1];
reg  [3:0]   exp_m [0:MAXC-1];
reg  [31:0]  meta  [0:3];
integer      sel   [0:MAXC-1];
string  stem, only;
integer stall = 0, n_cases, n_sel, k, only_idx;
integer seed_v = 11;

// ---- the driver and the scoreboard -------------------------------------------------------
integer di = 0, oi = 0;
integer n_out = 0, n_fail = 0;
integer hist [0:4];
integer fail_cls [0:NCLS-1];
reg  [LATENCY-1:0] vpipe = {LATENCY{1'b0}};
reg  [191:0] w;
reg  [3:0]   e;
integer c, idle;

initial begin
    for (k = 0; k < NCLS; k = k + 1) fail_cls[k] = 0;
    for (k = 0; k < 5; k = k + 1) hist[k] = 0;
    if (!$value$plusargs("stem=%s", stem)) stem = "bench/h264/fixtures/gen/deblock_bs";
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
        if (only_idx < 0 || in_m[k][178:171] == only_idx[7:0]) begin sel[n_sel] = k; n_sel = n_sel + 1; end
    if (n_sel == 0) `FAIL("count", {"no case of class ", only})
    if (only != "") $display("deblock_bs_tb: %0d cases, %0d selected of class %0s, stall %0d", n_cases, n_sel, only, stall);
    else $display("deblock_bs_tb: %0d cases, stall %0d", n_cases, stall);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    while (di < n_sel) begin
        @(posedge clk);
        idle = (stall > 0) && (($urandom(seed_v) % stall) == 0);
        if (idle) begin
            in_valid <= 1'b0;
            pb <= {$urandom(seed_v), $urandom(seed_v), $urandom(seed_v)};
            qb <= {$urandom(seed_v), $urandom(seed_v), $urandom(seed_v)};
            {mb_edge, vertical, field} <= $urandom(seed_v);
        end else begin
            w = in_m[sel[di]];
            in_valid <= 1'b1;
            pb <= w[83:0];
            qb <= w[167:84];
            mb_edge <= w[168]; vertical <= w[169]; field <= w[170];
            di = di + 1;
        end
    end
    @(posedge clk);
    in_valid <= 1'b0;
    repeat (LATENCY + 4) @(posedge clk);
    if (n_out !== n_sel) `FAIL("count", $sformatf("%0d outputs for %0d cases", n_out, n_sel))
    if (n_fail != 0) begin
        $write("FAILCLS:");
        for (k = 0; k < NCLS; k = k + 1) if (fail_cls[k] != 0) $write(" %0s=%0d", cls_name(k), fail_cls[k]);
        $display("");
        $display("FAIL [bs] %0d of %0d strengths differ from the model", n_fail, n_sel);
        $fatal(1);
    end
    $display("deblock_bs_tb: %0d pairs, bS 0/1/2/3/4: %0d/%0d/%0d/%0d/%0d, latency %0d, stall %0d",
             n_out, hist[0], hist[1], hist[2], hist[3], hist[4], LATENCY, stall);
    $display("PASS: deblock_bs_tb");
    $finish;
end

always @(posedge clk) if (rst_n) begin
    vpipe <= (LATENCY > 1) ? {vpipe[LATENCY-1:0], in_valid} : in_valid;
    if (out_valid !== vpipe[LATENCY-1])
        `FAIL("lat", $sformatf("out_valid %b, expected %b (in_valid delayed %0d)", out_valid, vpipe[LATENCY-1], LATENCY))
    if (out_valid) begin
        if (oi >= n_sel) `FAIL("count", "an output beyond the last case")
        w = in_m[sel[oi]];
        e = exp_m[sel[oi]];
        c = w[178:171];
        if (c >= NCLS) c = NCLS - 1;
        n_out = n_out + 1;
        if (bs <= 4) hist[bs] = hist[bs] + 1;
        if ({1'b0, bs} !== e) begin
            if (fail_cls[c] == 0)
                $display("FAIL [bs] case %0d (%0s): edge mb %b vert %b field %b p {i%b nz%b pred%b%b ref %0d/%0d mv (%0d,%0d) (%0d,%0d)} q {i%b nz%b pred%b%b ref %0d/%0d mv (%0d,%0d) (%0d,%0d)} -> got %0d, model %0d",
                         sel[oi], cls_name(c), w[168], w[169], w[170],
                         w[83], w[82], w[81], w[80], w[79:72], w[71:64], $signed(w[63:48]), $signed(w[47:32]), $signed(w[31:16]), $signed(w[15:0]),
                         w[167], w[166], w[165], w[164], w[163:156], w[155:148], $signed(w[147:132]), $signed(w[131:116]), $signed(w[115:100]), $signed(w[99:84]),
                         bs, e);
            fail_cls[c] = fail_cls[c] + 1;
            n_fail = n_fail + 1;
        end
        oi = oi + 1;
    end
end

endmodule
