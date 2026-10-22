// bench/h264/mc_interp_tb.sv -- mc_interp against tools/h264_recon_ref.py's mc_luma /
// mc_chroma (fixtures from tools/mc_golden.py --out-mc)
//
// +stem=<path>: <stem>.case.hex ({h, is_chroma, frac_x, frac_y, w} per case), .win.hex
// (the window bytes, (w+5)(h+5) luma / (w+1)(h+1) chroma per case), .exp.hex (w*h
// samples), .meta.hex. Per case the bench loads the window into a synchronous-read RAM
// model (one cycle of latency; every address OUTSIDE the window is X, so a read past the
// window that reaches an output is a mismatch), pulses start, and collects the stream
// with a random-ready consumer (+stall=N: ready ~2/3 of the cycles; 0: always ready).
// +rows=1 (P5b, the streaming window): the window starts all X and its rows are written
// one at a time after random delays, rows_avail counting each the edge it is written (the
// tightest the contract in mc_interp.sv allows) -- a read ahead of the count reads X and
// fails [pred]. Without +rows, rows_avail is 31 and the window is loaded before start.
// +off=1 (P5b 4b, the lanes' geometry): the case's window is planted inside a wider one --
// stride = its own + 3, starting at column 2, the padding X -- and the unit is given that
// win_stride and col_off = 2 (a lane sweeping a column slice of a larger window). Without
// +off: win_stride = the window's own, col_off 0.
// +ovl=1 (Phase 5c part 2, docs/mb_pipeline.md S4k: items overlap): each case starts as soon
// as the unit is `ready` (the previous case's reads all issued -- its samples still drain), its
// window already in the other of two banks (hd_raster: no gap cycle); the consumer scores every
// case's samples in order with its own case index. Two cases of different classes then
// share the pipeline: a parameter read from the wrong set fails [pred].
//
//   [pred]   every sample equals the model's (`!==`), in raster order; a failure names
//            the case's class as L<w>x<h> fx<fx>fy<fy> (luma) / C<w>x<h> ... (chroma)
//   [last]   pred_last exactly on the partition's final sample
//   [count]  the partition's sample count
//   [busy]   busy high through the partition and low two cycles after the last sample
//   [hang]   a sample within 600 cycles of the previous
//   [rate]   with +stall=0: every case finishes within its class's window-read count
//            plus the fixed pipeline latency (LAT_MAX cycles): G w*h, a/b/c h*(w+5),
//            d/h/n (h+5)*w, the rest (w+5)(h+5), chroma (w+xF!=0)(h+yF!=0) -- the read
//            port is the bound, and this pins the unit to it. The per-class table
//            (cycles and samples per cycle) is printed.
//
// PASS marker: "PASS: mc_interp_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module mc_interp_tb;

localparam MAXC = 1 << 14;          // cases
localparam MAXW = 1 << 21;          // window bytes
localparam MAXE = 1 << 21;          // expected samples
localparam LAT_MAX = 14;            // start .. last sample taken, beyond the reads

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT and the window RAM model ----------------------------------------------------
reg        start = 1'b0;
reg        is_chroma = 1'b0;
reg  [2:0] frac_x = 3'd0, frac_y = 3'd0;
reg  [4:0] w = 5'd0, h = 5'd0;
wire [8:0] win_addr;
reg  [7:0] win_data;
wire       pred_valid, pred_last, busy, dut_ready, dut_rd_done;
wire [7:0] pred;
reg        pred_ready = 1'b0;
reg  [4:0] rows_avail = 5'd31;
reg  [4:0] win_stride = 5'd0, col_off = 5'd0;
mc_interp dut (
    .clk(clk), .rst_n(rst_n),
    .start(start), .is_chroma(is_chroma), .frac_x(frac_x), .frac_y(frac_y), .w(w), .h(h),
    .win_addr(win_addr), .win_data(win_data), .rows_avail(rows_avail),
    .win_stride(win_stride), .col_off(col_off),
    .pred_valid(pred_valid), .pred(pred), .pred_last(pred_last), .pred_ready(pred_ready),
    .busy(busy), .ready(dut_ready), .rd_done(dut_rd_done));

reg [7:0] win_mem [0:511];
// +ovl: two banks, case ci's window in bank ci & 1, loaded BEFORE its start (hd_raster, 2026-10-04:
// the one-bank bench waited a cycle after `ready` for the previous case's last read to land, and
// that cycle hid the parameter-set hazard once S7 took its parameters registered -- M15). A read
// issued after a start is the new item's: the bank switches at the start the unit takes.
reg [7:0] win_ob [0:1023];
reg       rbank = 1'b0, nbank = 1'b0;

// ---- fixture ---------------------------------------------------------------------------
reg  [31:0] case_m [0:MAXC-1];
reg  [7:0]  win_m  [0:MAXW-1];
reg  [7:0]  exp_m  [0:MAXE-1];
reg  [31:0] meta   [0:15];
string  stem;
integer stall = 0, rows_mode = 0, off_mode = 0, ovl_mode = 0, n_cases, n_win, n_exp, seed_v, k;
// (the window's read port: +ovl's two banks, above)
always @(posedge clk) begin
    win_data <= ovl_mode ? win_ob[{rbank, win_addr}] : win_mem[win_addr];
    if (ovl_mode && start && dut_ready) rbank <= nbank;
end
// +ovl: the consumer's own case (the producer may be a case or two ahead)
integer oc = 0, osi = 0, oeoff = 0, o_n = 0;
reg [31:0] ocw = 32'd0;                  // the consumer's case word
always @* begin
    ocw = (oc < n_cases) ? case_m[oc] : 32'd0;
    o_n = ocw[4:0] * ocw[28:24];
end
`define OCLS $sformatf("%0s%0dx%0d fx%0dfy%0d", ocw[16] ? "C" : "L", ocw[4:0], ocw[28:24], ocw[14:12], ocw[10:8])
// the row release (+rows): rows of the current case written one by one
integer rl_woff = 0, rl_stride = 0, rl_nrows = 0, rl_row = 0, rl_wait = 0;
integer rl_rs = 0, rl_off = 0;           // the RAM's row stride and column offset (+off)
reg     rl_go = 1'b0;
always @(posedge clk) begin
    if (rl_go && rl_row < rl_nrows) begin
        if (rl_wait == 0) begin
            for (int x = 0; x < rl_stride; x++) win_mem[rl_row * rl_rs + rl_off + x] <= win_m[rl_woff + rl_row * rl_stride + x];
            rows_avail <= rl_row + 1;
            rl_row <= rl_row + 1;
            rl_wait <= $urandom % 24;
        end else rl_wait <= rl_wait - 1;
    end
end

// ---- the consumer, scoring in order ----------------------------------------------------
integer ci = 0, si = 0, eoff = 0, woff = 0, n_blk = 0, idle_cyc = 0, collecting = 0;
string  cls;
always @(posedge clk) begin
    if (rst_n) begin
        pred_ready <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
        if (ovl_mode && collecting) begin
            if (pred_valid && pred_ready) begin
                idle_cyc <= 0;
                if (oc >= n_cases) `FAIL("count", "a sample after the last case")
                if (pred !== exp_m[oeoff + osi])
                    `FAIL("pred", $sformatf("case %0d (%0s) sample %0d: got %0d want %0d", oc, `OCLS, osi, pred, exp_m[oeoff + osi]))
                if (pred_last !== (osi == o_n - 1))
                    `FAIL("last", $sformatf("case %0d (%0s) sample %0d: pred_last %0d", oc, `OCLS, osi, pred_last))
                if (osi == o_n - 1) begin oc <= oc + 1; oeoff <= oeoff + o_n; osi <= 0; end
                else osi <= osi + 1;
            end else begin
                idle_cyc <= idle_cyc + 1;
                if (idle_cyc > 600 && oc < n_cases) `FAIL("hang", $sformatf("case %0d (%0s): no sample for 600 cycles after sample %0d", oc, `OCLS, osi))
            end
        end else if (collecting) begin
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
            if (!busy && !pred_valid && si !== n_blk)
                `FAIL("busy", $sformatf("case %0d (%0s): busy dropped after %0d of %0d samples", ci, cls, si, n_blk))
        end
    end
end

// ---- the per-class table: plane x size x position class -------------------------------
// size index: (w, h) in {4, 8, 16}^2 (chroma halved) -> 3 * hi + wi; position class 0 G /
// integer, 1 xF only, 2 yF only, 3 both
integer cyc_t [0:71];
integer smp_t [0:71];
integer cnt_t [0:71];
integer ti, wi, hi, pcls, n_reads, worst_lat = 0;
integer i, wait_cyc, t_start, t_all, win_n, cyc;
initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    if (!$value$plusargs("rows=%d", rows_mode)) rows_mode = 0;
    if (!$value$plusargs("off=%d", off_mode)) off_mode = 0;
    if (!$value$plusargs("ovl=%d", ovl_mode)) ovl_mode = 0;
    seed_v = stall + 11; k = $urandom(seed_v);
    $readmemh({stem, ".meta.hex"}, meta);
    n_cases = meta[0]; n_win = meta[1]; n_exp = meta[2];
    if (n_cases > MAXC || n_win > MAXW || n_exp > MAXE) `FAIL("harness", "fixture too large")
    if (n_cases == 0) `FAIL("harness", "no cases")
    $readmemh({stem, ".case.hex"}, case_m, 0, n_cases - 1);
    $readmemh({stem, ".win.hex"}, win_m, 0, n_win - 1);
    $readmemh({stem, ".exp.hex"}, exp_m, 0, n_exp - 1);
    for (i = 0; i < 72; i = i + 1) begin cyc_t[i] = 0; smp_t[i] = 0; cnt_t[i] = 0; end

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    if (busy !== 1'b0) `FAIL("busy", "busy after reset")
    t_all = $time;

    if (ovl_mode) begin
        // ---- +ovl: every case started as soon as the unit is ready -------------------------
        collecting = 1;
        for (ci = 0; ci < n_cases; ci = ci + 1) begin
            wait_cyc = 0;
            while (dut_ready !== 1'b1) begin
                @(posedge clk); #1; wait_cyc = wait_cyc + 1;
                if (wait_cyc > 3000) `FAIL("hang", $sformatf("case %0d: the unit not ready for 3000 cycles", ci))
            end
            h = case_m[ci][28:24]; is_chroma = case_m[ci][16]; frac_x = case_m[ci][14:12]; frac_y = case_m[ci][10:8]; w = case_m[ci][4:0];
            win_n = is_chroma ? (w + 1) * (h + 1) : (w + 5) * (h + 5);
            rl_stride = is_chroma ? w + 1 : w + 5; rl_nrows = is_chroma ? h + 1 : h + 5;
            win_stride = rl_stride; col_off = 0; rows_avail = 5'd31;
            nbank = ci[0];
            for (i = 0; i < 512; i = i + 1) win_ob[{nbank, i[8:0]}] = 8'hxx;
            for (i = 0; i < rl_nrows; i = i + 1)
                for (k = 0; k < rl_stride; k = k + 1) win_ob[{nbank, 9'(i * rl_stride + k)}] = win_m[woff + i * rl_stride + k];
            woff = woff + win_n;
            start = 1'b1; @(posedge clk); #1; start = 1'b0;
        end
        wait_cyc = 0;
        while (oc < n_cases || busy) begin
            @(posedge clk); #1; wait_cyc = wait_cyc + 1;
            if (wait_cyc > 3000) `FAIL("hang", $sformatf("the last cases: %0d of %0d out after 3000 cycles", oc, n_cases))
        end
        collecting = 0;
        if (oeoff !== n_exp) `FAIL("count", $sformatf("%0d samples scored, fixture holds %0d", oeoff, n_exp))
        if (woff !== n_win) `FAIL("count", $sformatf("%0d window bytes used, fixture holds %0d", woff, n_win))
        $display("mc_interp_tb: %0s: %0d cases, %0d samples in %0d cycles, items overlapped (stall %0d)",
                 stem, n_cases, n_exp, ($time - t_all) / 10, stall);
        $display("PASS: mc_interp_tb");
        $finish;
    end

    for (ci = 0; ci < n_cases; ci = ci + 1) begin
        h = case_m[ci][28:24]; is_chroma = case_m[ci][16]; frac_x = case_m[ci][14:12]; frac_y = case_m[ci][10:8]; w = case_m[ci][4:0];
        if (case_m[ci][31:29] != 3'd0 || case_m[ci][23:17] != 7'd0 || case_m[ci][15] || case_m[ci][11] || case_m[ci][7:5] != 3'd0)
            `FAIL("harness", $sformatf("case %0d: bad case word %08x", ci, case_m[ci]))
        if (!is_chroma && (frac_x > 3 || frac_y > 3)) `FAIL("harness", $sformatf("case %0d: luma fraction > 3", ci))
        n_blk = w * h;
        win_n = is_chroma ? (w + 1) * (h + 1) : (w + 5) * (h + 5);
        cls = $sformatf("%0s%0dx%0d fx%0dfy%0d", is_chroma ? "C" : "L", w, h, frac_x, frac_y);
        // the window RAM: X everywhere the window is not
        for (i = 0; i < 512; i = i + 1) win_mem[i] = 8'hxx;
        rl_stride = is_chroma ? w + 1 : w + 5; rl_nrows = is_chroma ? h + 1 : h + 5;
        rl_rs  = off_mode ? rl_stride + 3 : rl_stride;
        rl_off = off_mode ? 2 : 0;
        win_stride = rl_rs; col_off = rl_off;
        if (rows_mode == 0) begin
            for (i = 0; i < rl_nrows; i = i + 1)
                for (k = 0; k < rl_stride; k = k + 1) win_mem[i * rl_rs + rl_off + k] = win_m[woff + i * rl_stride + k];
            rows_avail = 5'd31;
        end else begin
            rows_avail = 5'd0;
            rl_woff = woff;
            rl_row = 0; rl_wait = $urandom % 24; rl_go = 1'b1;
        end
        // the class bookkeeping
        wi = (w == (is_chroma ? 2 : 4)) ? 0 : (w == (is_chroma ? 4 : 8)) ? 1 : (w == (is_chroma ? 8 : 16)) ? 2 : -1;
        hi = (h == (is_chroma ? 2 : 4)) ? 0 : (h == (is_chroma ? 4 : 8)) ? 1 : (h == (is_chroma ? 8 : 16)) ? 2 : -1;
        if (wi < 0 || hi < 0) `FAIL("harness", $sformatf("case %0d: size %0dx%0d is not a partition", ci, w, h))
        pcls = {frac_y != 0, frac_x != 0};
        ti = (is_chroma ? 36 : 0) + 4 * (3 * hi + wi) + pcls;
        case (pcls)
            0: n_reads = is_chroma ? w * h : w * h;
            1: n_reads = is_chroma ? (w + 1) * h : h * (w + 5);
            2: n_reads = is_chroma ? w * (h + 1) : (h + 5) * w;
            default: n_reads = is_chroma ? (w + 1) * (h + 1) : (w + 5) * (h + 5);
        endcase
        // the partition
        si = 0; idle_cyc = 0;
        t_start = $time;
        start = 1'b1; @(posedge clk); #1; start = 1'b0;
        if (busy !== 1'b1) `FAIL("busy", $sformatf("case %0d (%0s): busy not raised by start", ci, cls))
        collecting = 1;
        wait_cyc = 0;
        while (busy) begin
            @(posedge clk); #1; wait_cyc = wait_cyc + 1;
            if (wait_cyc > 3000) `FAIL("hang", $sformatf("case %0d (%0s): busy for 3000 cycles", ci, cls))
        end
        // busy fell on the edge the last sample was taken; the consumer's block sees it now
        @(posedge clk); #1;
        collecting = 0;
        if (si !== n_blk) `FAIL("count", $sformatf("case %0d (%0s): %0d samples, want %0d", ci, cls, si, n_blk))
        if (pred_valid !== 1'b0) `FAIL("busy", $sformatf("case %0d (%0s): pred_valid after busy", ci, cls))
        cyc = ($time - t_start) / 10 - 1;            // the edge after busy fell is not the unit's
        cyc_t[ti] = cyc_t[ti] + cyc; smp_t[ti] = smp_t[ti] + n_blk; cnt_t[ti] = cnt_t[ti] + 1;
        rl_go = 1'b0;
        if (stall == 0 && rows_mode == 0) begin
            if (cyc - n_reads > worst_lat) worst_lat = cyc - n_reads;
            if (cyc > n_reads + LAT_MAX)
                `FAIL("rate", $sformatf("case %0d (%0s): %0d cycles for %0d reads (+%0d allowed)", ci, cls, cyc, n_reads, LAT_MAX))
        end
        eoff = eoff + n_blk; woff = woff + win_n;
        @(posedge clk); #1;
        if (busy !== 1'b0 || pred_valid !== 1'b0) `FAIL("busy", $sformatf("case %0d (%0s): not idle two cycles after the partition", ci, cls))
    end
    if (eoff !== n_exp) `FAIL("count", $sformatf("%0d samples scored, fixture holds %0d", eoff, n_exp))
    if (woff !== n_win) `FAIL("count", $sformatf("%0d window bytes used, fixture holds %0d", woff, n_win))
    $display("mc_interp_tb: %0s: %0d cases, %0d samples in %0d cycles; worst latency beyond the reads %0d (stall %0d)",
             stem, n_cases, n_exp, ($time - t_all) / 10, worst_lat, stall);
    $display("mc_interp_tb: cycles per partition (samples/cycle) by position class: G | xF | yF | both");
    for (i = 0; i < 18; i = i + 1) begin
        if (cnt_t[4 * i] + cnt_t[4 * i + 1] + cnt_t[4 * i + 2] + cnt_t[4 * i + 3] != 0)
            $display("mc_interp_tb:   %0s%0dx%0d: %0d (0.%02d) | %0d (0.%02d) | %0d (0.%02d) | %0d (0.%02d)",
                     (i >= 9) ? "C" : "L",
                     ((i >= 9) ? 2 : 4) << ((i % 9) % 3), ((i >= 9) ? 2 : 4) << ((i % 9) / 3),
                     cnt_t[4 * i]     ? cyc_t[4 * i]     / cnt_t[4 * i]     : 0, cnt_t[4 * i]     ? (100 * smp_t[4 * i]     / cyc_t[4 * i])     % 100 : 0,
                     cnt_t[4 * i + 1] ? cyc_t[4 * i + 1] / cnt_t[4 * i + 1] : 0, cnt_t[4 * i + 1] ? (100 * smp_t[4 * i + 1] / cyc_t[4 * i + 1]) % 100 : 0,
                     cnt_t[4 * i + 2] ? cyc_t[4 * i + 2] / cnt_t[4 * i + 2] : 0, cnt_t[4 * i + 2] ? (100 * smp_t[4 * i + 2] / cyc_t[4 * i + 2]) % 100 : 0,
                     cnt_t[4 * i + 3] ? cyc_t[4 * i + 3] / cnt_t[4 * i + 3] : 0, cnt_t[4 * i + 3] ? (100 * smp_t[4 * i + 3] / cyc_t[4 * i + 3]) % 100 : 0);
    end
    $display("PASS: mc_interp_tb");
    $finish;
end

endmodule
