// bench/h264/mv_pred_tb.sv -- mv_pred against tools/h264_recon_ref.py's motion derivation
// (fixtures from tools/mv_pred_golden.py: every inter macroblock of a stream)
//
// +stem=<path>: <stem>.case.hex (164 words per macroblock), .slice.hex (100 words per
// slice record), .meta.hex. Per case the bench drives the slice record's parameters and
// tables, the descriptor, the neighbour entries and the co-located entries, pulses
// start, waits for done, then reads the sixteen blocks back through out_blk.
// +stall=N (N > 0): 0..N idle cycles before each start (done and busy must stay low),
// start driven at random while busy (it must be ignored: one done, the same result), the
// sixteen blocks read back in a random order with 0..N cycles between reads.
//
//   [mv]     every block's (pred, ref, mv) per list equals the model's (`!==`); the
//            bench keeps going and tallies the failing cases per class, then reports
//            "FAIL [mv] class <name>: n cases (first case k, mb a)" for each and $fatals
//   [err]    the err pulse seen (any, during the macroblock) equals the expectation
//   [busy]   busy is high the cycle after start and low the cycle after done
//   [hang]   done within 200 cycles of start
//   [idle]   (+stall) done and busy stay low between macroblocks
//   [cycles] per class: start to done inclusive, printed (min / max / mean) and gated (136:
//            one gather through the block RAM, temporal direct's two table-read stages,
//            the registered geometry and predictor, docs/h264_recon.md S6): <= 152 for every
//            class (the worst case 146: P_8x8 / B_8x8 with sixteen 4x4 partitions --
//            114 until P5b's S_PREP2 and S_MVP_Q0 added a cycle each, docs/throughput.md)
//
// PASS marker: "PASS: mv_pred_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module mv_pred_tb;

localparam MAXC = 1 << 14;              // cases
localparam MAXS = 1 << 11;              // slice records
localparam WC = 164, WS = 100;
localparam NCLS = 19;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT ---------------------------------------------------------------------------
reg          start = 1'b0;
wire         busy, done, err;
reg  [1:0]   slice_type = 2'd0;
reg          direct_spatial = 1'b0, direct_8x8_inf = 1'b0, list1_0_is_short = 1'b0;
reg  [5:0]   num_ref_l0 = 6'd1, num_ref_l1 = 6'd1;
reg  [1:0]   vert_scale = 2'd0;
reg  [351:0] tdir_dsf = 352'd0;
reg  [31:0]  tdir_raw = 32'd0;
reg  [383:0] map_col = 384'd0;
// the tables' read ports: one cycle from address to data, as recon_slice_tab's RAMs (the
// fixture's map has 64 codes -- stores below 16 -- so a higher code reads as invalid)
wire [6:0]  map_ra;
wire [4:0]  dsf_ra;
reg  [5:0]  map_q = 6'd0;
reg  [10:0] dsf_q = 11'd0;
always @(posedge clk) begin
    map_q <= map_ra[6] ? 6'd0 : map_col[6*map_ra[5:0] +: 6];
    dsf_q <= tdir_dsf[11*dsf_ra +: 11];
end
reg          skip = 1'b0;
reg  [5:0]   mb_type = 6'd0;
reg  [15:0]  sub_mb_type = 16'd0;
reg  [39:0]  refs = 40'd0;
reg  [1023:0] mvd = 1024'd0;
// the mvd read port: one cycle from address to data, as mb_intake's RAM
wire [4:0]  mvd_ra;
reg  [31:0] mvd_q = 32'd0;
always @(posedge clk) mvd_q <= mvd[32*mvd_ra +: 32];
reg  [799:0] nb_data = 800'd0;
reg  [9:0]   nb_avail = 10'd0, nb_intra = 10'd0;
reg  [767:0] col_data = 768'd0;
// the co-located read port: one cycle from address to data, as recon_mb's RAM
wire [3:0]  col_ra;
reg  [47:0] col_q = 48'd0;
always @(posedge clk) col_q <= col_data[48*col_ra +: 48];
reg  [3:0]   out_blk = 4'd0;
wire         out_pred0, out_pred1;
wire [4:0]   out_ref0, out_ref1;
wire [15:0]  out_mvx0, out_mvy0, out_mvx1, out_mvy1;

mv_pred dut (
    .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done), .err(err),
    .slice_type(slice_type), .direct_spatial(direct_spatial), .direct_8x8_inf(direct_8x8_inf),
    .num_ref_l0(num_ref_l0), .num_ref_l1(num_ref_l1), .list1_0_is_short(list1_0_is_short),
    .vert_scale(vert_scale), .map_ra(map_ra), .map_q(map_q), .dsf_ra(dsf_ra), .dsf_q(dsf_q), .tdir_raw(tdir_raw),
    .skip(skip), .mb_type(mb_type), .sub_mb_type(sub_mb_type), .refs(refs), .mvd_ra(mvd_ra), .mvd_q(mvd_q),
    .nb_data(nb_data), .nb_avail(nb_avail), .nb_intra(nb_intra), .col_ra(col_ra), .col_q(col_q),
    .out_blk(out_blk),
    .out_pred0(out_pred0), .out_ref0(out_ref0), .out_mvx0(out_mvx0), .out_mvy0(out_mvy0),
    .out_pred1(out_pred1), .out_ref1(out_ref1), .out_mvx1(out_mvx1), .out_mvy1(out_mvy1));

// ---- fixture ---------------------------------------------------------------------------
reg  [31:0] case_m  [0:WC*MAXC-1];
reg  [31:0] slice_m [0:WS*MAXS-1];
reg  [31:0] meta    [0:31];
string  stem;
integer n_cases, n_slices;

// class names (tools/mv_pred_golden.py CLASSES order)
string cls_name [0:NCLS-1];
initial begin
    cls_name[0] = "P_SKIP";  cls_name[1] = "P16x16"; cls_name[2] = "P16x8";   cls_name[3] = "P8x16";
    cls_name[4] = "P8x8";    cls_name[5] = "B16x16"; cls_name[6] = "B16x8";   cls_name[7] = "B8x16";
    cls_name[8] = "B8x8";    cls_name[9] = "B8x8DS"; cls_name[10] = "B8x8DT"; cls_name[11] = "BDIR16S";
    cls_name[12] = "BDIR16T"; cls_name[13] = "ERR_REF"; cls_name[14] = "ERR_MAP"; cls_name[15] = "TD_FRM2FLD";
    cls_name[16] = "TD_FLD2FRM"; cls_name[17] = "SP_EDGE"; cls_name[18] = "TD_RAW";
end

// ---- tallies -----------------------------------------------------------------------
integer fail_mv  [0:NCLS-1];
integer fail_err [0:NCLS-1];
integer first_mv [0:NCLS-1];
integer first_err [0:NCLS-1];
integer first_mv_addr [0:NCLS-1];
integer cyc_n [0:NCLS-1];
integer cyc_sum [0:NCLS-1];
integer cyc_min [0:NCLS-1];
integer cyc_max [0:NCLS-1];
integer shown = 0;

// ---- the run -----------------------------------------------------------------------
integer ci, base, sb, si, cls, k, l, b, cyc, err_seen, t, i;
reg [31:0] w0, w1, wa, wb, wc, s0, want_mv, want_pr;
reg        exp_err, bad_mv, bad_err;
reg [15:0] got_x, got_y;
reg [4:0]  got_r;
reg        got_p;
integer any_fail = 0;
integer stall = 0, seed = 1, gap, perm_j, perm_t;
integer perm [0:15];

initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    $readmemh({stem, ".meta.hex"}, meta);
    n_cases = meta[0]; n_slices = meta[1];
    if (meta[2] !== WC || meta[3] !== WS) `FAIL("harness", "fixture word layout mismatch")
    if (n_cases > MAXC || n_slices > MAXS) `FAIL("harness", "fixture too large")
    if (n_cases == 0) `FAIL("harness", "no cases")
    $readmemh({stem, ".case.hex"}, case_m, 0, WC * n_cases - 1);
    $readmemh({stem, ".slice.hex"}, slice_m, 0, WS * n_slices - 1);
    for (k = 0; k < NCLS; k = k + 1) begin
        fail_mv[k] = 0; fail_err[k] = 0; first_mv[k] = -1; first_err[k] = -1; first_mv_addr[k] = -1;
        cyc_n[k] = 0; cyc_sum[k] = 0; cyc_min[k] = 1 << 30; cyc_max[k] = 0;
    end

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;

    for (ci = 0; ci < n_cases; ci = ci + 1) begin
        base = ci * WC;
        w0 = case_m[base]; w1 = case_m[base + 1];
        si = w0[15:0]; cls = w0[31:24]; exp_err = w0[23];
        if (si >= n_slices) `FAIL("harness", $sformatf("case %0d names slice record %0d of %0d", ci, si, n_slices))
        if (cls >= NCLS) `FAIL("harness", $sformatf("case %0d has class %0d", ci, cls))
        sb = si * WS; s0 = slice_m[sb];
        slice_type = s0[1:0]; direct_spatial = s0[2]; direct_8x8_inf = s0[3];
        num_ref_l0 = s0[12:7]; num_ref_l1 = s0[18:13]; list1_0_is_short = s0[19]; vert_scale = s0[22:21];
        for (k = 0; k < 64; k = k + 1) map_col[6*k +: 6] = slice_m[sb + 2 + k][5:0];
        for (k = 0; k < 32; k = k + 1) begin
            tdir_dsf[11*k +: 11] = slice_m[sb + 66 + k][10:0];
            tdir_raw[k] = slice_m[sb + 66 + k][11];
        end
        skip = w0[16]; mb_type = w0[22:17]; sub_mb_type = w1[15:0];
        refs = {case_m[base + 3][19:0], case_m[base + 2][19:0]};
        for (l = 0; l < 2; l = l + 1)
            for (b = 0; b < 16; b = b + 1)
                mvd[32*(16*l + b) +: 32] = case_m[base + 4 + 16*l + b];
        for (k = 0; k < 10; k = k + 1) begin
            wa = case_m[base + 36 + 3*k]; wb = case_m[base + 37 + 3*k]; wc = case_m[base + 38 + 3*k];
            nb_data[80*k +: 80] = {1'b0, wc[9], wc[15:10], wb[31:16], wb[15:0], 1'b0, wc[2], wc[8:3], wa[31:16], wa[15:0]};
            nb_avail[k] = wc[0]; nb_intra[k] = wc[1];
        end
        for (b = 0; b < 16; b = b + 1) begin
            wa = case_m[base + 66 + 2*b]; wb = case_m[base + 67 + 2*b];
            col_data[48*b +: 48] = {2'b00, wb[13], wb[12:5], wb[4:0], wa[31:16], wa[15:0]};
        end

        // +stall: idle cycles first; nothing may move
        if (stall > 0) begin
            gap = $unsigned($random(seed)) % (stall + 1);
            for (i = 0; i < gap; i = i + 1) begin
                @(posedge clk); #1;
                if (done !== 1'b0 || busy !== 1'b0 || err !== 1'b0)
                    `FAIL("idle", $sformatf("case %0d: done/busy/err moved while idle", ci))
            end
        end
        // start; count cycles from the start cycle to the done cycle inclusive
        start = 1'b1;
        cyc = 1; err_seen = 0;
        @(posedge clk); #1;
        start = 1'b0;
        if (busy !== 1'b1) `FAIL("busy", $sformatf("case %0d: busy low the cycle after start", ci))
        t = 0;
        while (done !== 1'b1) begin
            if (err) err_seen = 1;
            if (busy !== 1'b1) `FAIL("busy", $sformatf("case %0d: busy dropped before done", ci))
            start = (stall > 0) ? $random(seed) : 1'b0;         // ignored while busy
            @(posedge clk); #1;
            start = 1'b0;
            cyc = cyc + 1; t = t + 1;
            if (t > 200) `FAIL("hang", $sformatf("case %0d (%0s): no done within 200 cycles", ci, cls_name[cls]))
        end
        if (err) err_seen = 1;
        if (busy !== 1'b0) `FAIL("busy", $sformatf("case %0d: busy high with done", ci))
        @(posedge clk); #1;
        if (busy !== 1'b0 || done !== 1'b0) `FAIL("busy", $sformatf("case %0d: busy or done high the cycle after done", ci))
        cyc_n[cls] = cyc_n[cls] + 1; cyc_sum[cls] = cyc_sum[cls] + cyc;
        if (cyc < cyc_min[cls]) cyc_min[cls] = cyc;
        if (cyc > cyc_max[cls]) cyc_max[cls] = cyc;

        // read back and score
        bad_mv = 1'b0; bad_err = (err_seen !== exp_err);
        for (i = 0; i < 16; i = i + 1) perm[i] = i;
        if (stall > 0)
            for (i = 15; i > 0; i = i - 1) begin
                perm_j = $unsigned($random(seed)) % (i + 1);
                perm_t = perm[i]; perm[i] = perm[perm_j]; perm[perm_j] = perm_t;
            end
        for (i = 0; i < 16; i = i + 1) begin
            b = perm[i];
            if (stall > 0) begin
                gap = $unsigned($random(seed)) % (stall + 1);
                repeat (gap) begin out_blk = $random(seed); @(posedge clk); #1; end
            end
            out_blk = b[3:0];
            @(posedge clk); #1;
            for (l = 0; l < 2; l = l + 1) begin
                want_mv = case_m[base + 98 + 4*b + 2*l]; want_pr = case_m[base + 99 + 4*b + 2*l];
                if (l == 0) begin got_p = out_pred0; got_r = out_ref0; got_x = out_mvx0; got_y = out_mvy0; end
                else        begin got_p = out_pred1; got_r = out_ref1; got_x = out_mvx1; got_y = out_mvy1; end
                if ({got_p, got_r} !== want_pr[5:0] || {got_y, got_x} !== want_mv) begin
                    if (!bad_mv && shown < 12) begin
                        $display("  mismatch case %0d (%0s mb %0d) blk %0d L%0d: got pred %0d ref %0d mv (%0d, %0d), want pred %0d ref %0d mv (%0d, %0d)",
                                 ci, cls_name[cls], w1[31:16], b, l, got_p, got_r, $signed(got_x), $signed(got_y),
                                 want_pr[5], want_pr[4:0], $signed(want_mv[15:0]), $signed(want_mv[31:16]));
                        shown = shown + 1;
                    end
                    bad_mv = 1'b1;
                end
            end
        end
        if (bad_mv) begin
            fail_mv[cls] = fail_mv[cls] + 1;
            if (first_mv[cls] < 0) begin first_mv[cls] = ci; first_mv_addr[cls] = w1[31:16]; end
            any_fail = 1;
        end
        if (bad_err) begin
            fail_err[cls] = fail_err[cls] + 1;
            if (first_err[cls] < 0) first_err[cls] = ci;
            any_fail = 1;
        end
    end

    // cycles per class
    for (k = 0; k < NCLS; k = k + 1)
        if (cyc_n[k] > 0)
            $display("mv_pred_tb: cycles %-10s n=%0d min=%0d max=%0d mean=%0d.%0d", cls_name[k], cyc_n[k], cyc_min[k], cyc_max[k],
                     cyc_sum[k] / cyc_n[k], (10 * cyc_sum[k] / cyc_n[k]) % 10);
    if (any_fail) begin
        for (k = 0; k < NCLS; k = k + 1) begin
            if (fail_mv[k] > 0) $display("FAIL [mv] class %0s: %0d of %0d cases (first case %0d, mb %0d)", cls_name[k], fail_mv[k], cyc_n[k], first_mv[k], first_mv_addr[k]);
            if (fail_err[k] > 0) $display("FAIL [err] class %0s: %0d of %0d cases (first case %0d)", cls_name[k], fail_err[k], cyc_n[k], first_err[k]);
        end
        $fatal(1);
    end
    for (k = 0; k < NCLS; k = k + 1)
        if (cyc_n[k] > 0 && cyc_max[k] > 152) `FAIL("cycles", $sformatf("class %0s took %0d cycles", cls_name[k], cyc_max[k]))
    $display("mv_pred_tb: %0s: %0d macroblocks, %0d slice records, all blocks exact%0s", stem, n_cases, n_slices,
             stall > 0 ? " (+stall)" : "");
    $display("PASS: mv_pred_tb");
    $finish;
end

endmodule
