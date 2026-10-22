// bench/h264/mb_syntax_tb.sv -- mb_syntax + cabac_engine + cabac_ctx against the SE
// stream tools/h264_fe_ref.py decodes from a real slice (tools/mb_syntax_golden.py)
//
// +stem=<path>: <stem>.bytes.hex (the slice data), .se.hex (the expected SE words
// {kind, aux, val}), .meta.hex (the slice parameters). The bench plays the slice
// header's part: it FLUSHes the engine, feeds the bytes with in_last on the final one,
// issues INIT(set, QP), then `start`s mb_syntax and collects its SE stream with a
// random-ready consumer (+stall=N; N >= 100: BURSTS -- ready N cycles, not ready N cycles, as a
// back-pressured SE FIFO does, so the output falls a whole block behind the decode: the
// emission queue's level-bank interlock, feature/mb-pipeline).
//
//   [se]     every SE word equals the model's, in order (`!==`), and the count matches
//   [done]   mb_syntax reports done after the last END_OF_SLICE 1, no overrun
//   [err]    the engine's err_init / err_align / err_underrun stay clear
//   [hang]   an SE within 20000 cycles of the previous (I_PCM's 384 bytes take ~800)
//   [rate]   with +stall=0: engine bins (+ I_PCM sample bytes) per cycle over the slice
//            >= 0.16 -- the Level-3.0 ceiling of 13 Mbins/s at 81 MHz (H264: +rate_min=N sets
//            the floor x100 for one fixture; the runner says which and why)
//
// PASS marker: "PASS: mb_syntax_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module mb_syntax_tb;

localparam MAXB = 1 << 18;
localparam MAXS = 1 << 20;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT ---------------------------------------------------------------------------
reg  [7:0] in_byte = 8'd0;
reg        in_valid = 1'b0, in_last = 1'b0;
wire       in_ready;
// the bench and mb_syntax share the engine's request port: the bench owns it until start
reg        tb_req_valid = 1'b0;
reg  [2:0] tb_req_kind = 3'd0;
reg  [8:0] tb_req_ctx = 9'd0;
wire       mbs_req_valid;
wire [2:0] mbs_req_kind;
wire [8:0] mbs_req_ctx;
reg        mbs_owns = 1'b0;
wire       req_valid = mbs_owns ? mbs_req_valid : tb_req_valid;
wire [2:0] req_kind  = mbs_owns ? mbs_req_kind  : tb_req_kind;
wire [8:0] req_ctx   = mbs_owns ? mbs_req_ctx   : tb_req_ctx;
wire       req_ready, rsp_valid, rsp_bin, eng_busy, err_init, err_align, err_underrun;
wire [7:0] rsp_byte;
wire [6:0] dbg_state;
wire [31:0] bin_count;
cabac_engine eng (
    .clk(clk), .rst_n(rst_n),
    .in_byte(in_byte), .in_valid(in_valid), .in_last(in_last), .in_ready(in_ready),
    .req_valid(req_valid), .req_ready(req_ready), .req_kind(req_kind), .req_ctx(req_ctx),
    .rsp_valid(rsp_valid), .rsp_bin(rsp_bin), .rsp_byte(rsp_byte),
    .busy(eng_busy), .err_init(err_init), .err_align(err_align), .err_underrun(err_underrun),
    .dbg_rd_en(1'b0), .dbg_addr(9'd0), .dbg_state(dbg_state), .bin_count(bin_count));

reg  [1:0]  sp_slice_type = 2'd0;
reg  [5:0]  sp_num_ref_l0 = 6'd1, sp_num_ref_l1 = 6'd1;
reg         sp_field = 1'b0;
reg  [7:0]  sp_width = 8'd1, sp_height = 8'd1;
reg  [13:0] sp_first_mb = 14'd0;
reg  [15:0] sp_slice_id = 16'd1;
reg         sp_t8_mode = 1'b0, sp_d8inf = 1'b0;   // High: meta[14], meta[15]
reg         start = 1'b0;
wire        done, err_overrun, err_bins;
wire        se_valid;
reg         se_ready = 1'b0;
wire [7:0]  se_kind, se_aux;
wire [15:0] se_val;
mb_syntax dut (
    .clk(clk), .rst_n(rst_n),
    .sp_slice_type(sp_slice_type), .sp_num_ref_l0(sp_num_ref_l0), .sp_num_ref_l1(sp_num_ref_l1),
    .sp_field(sp_field), .sp_width_mbs(sp_width), .sp_height_mbs(sp_height), .sp_first_mb(sp_first_mb),
    .sp_slice_id(sp_slice_id), .sp_t8_mode(sp_t8_mode), .sp_d8inf(sp_d8inf),
    .start(start), .done(done), .err_overrun(err_overrun), .err_bins(err_bins),
    .eng_req_valid(mbs_req_valid), .eng_req_ready(req_ready && mbs_owns), .eng_req_kind(mbs_req_kind),
    .eng_req_ctx(mbs_req_ctx), .eng_rsp_valid(rsp_valid && mbs_owns), .eng_rsp_bin(rsp_bin), .eng_rsp_byte(rsp_byte),
    .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val));

// ---- fixture ---------------------------------------------------------------------------
reg  [7:0]  bytes_m [0:MAXB-1];
reg  [31:0] se_m    [0:MAXS-1];
reg  [31:0] meta    [0:15];
string  stem;
integer stall = 0, rate_min = 16, n_bytes, n_se, k, seed_v;   // rate_min: bins/cycle x100 (H264: +rate_min, per fixture)

// ---- byte feeder -------------------------------------------------------------------------
integer bi = 0;
reg     feed_on = 1'b0;
always @(posedge clk) begin
    if (feed_on && bi < n_bytes) begin
        if (!in_valid) begin
            in_byte <= bytes_m[bi]; in_last <= (bi == n_bytes - 1); in_valid <= 1'b1;
        end else if (in_ready) begin
            bi <= bi + 1;
            if (bi + 1 < n_bytes) begin in_byte <= bytes_m[bi + 1]; in_last <= (bi + 1 == n_bytes - 1); end
            else in_valid <= 1'b0;
        end
    end else if (in_valid && in_ready) in_valid <= 1'b0;
end

// ---- SE consumer with random readiness, scoring in order ------------------------------------
integer si = 0, idle_cyc = 0, t_start, mb_seen = 0, pcm_bytes = 0, burst_cyc = 0;
reg [31:0] want;
always @(posedge clk) begin
    if (rst_n) begin
        burst_cyc <= burst_cyc + 1;
        se_ready <= (stall == 0) ? 1'b1 : (stall >= 100) ? (((burst_cyc / stall) % 2) == 0) : (($urandom % 3) != 0);
        if (se_valid && se_ready) begin
            idle_cyc <= 0;
            want = se_m[si];
            if ({se_kind, se_aux, se_val} !== want)
                `FAIL("se", $sformatf("SE %0d: got kind %0d aux %02x val %0d, want kind %0d aux %02x val %0d (after %0d macroblocks)",
                                      si, se_kind, se_aux, $signed(se_val), want[31:24], want[23:16], $signed(want[15:0]), mb_seen))
            if (se_kind == 8'd1) mb_seen <= mb_seen + 1;
            if (se_kind == 8'd14 && se_aux[3:0] == 4'd4) pcm_bytes <= pcm_bytes + 384;   // I_PCM samples are not bins
            si <= si + 1;
        end else if (mbs_owns && !done) begin
            idle_cyc <= idle_cyc + 1;
            if (idle_cyc > 20000) `FAIL("hang", $sformatf("no SE for 20000 cycles after SE %0d (%0d macroblocks)", si, mb_seen))
        end
    end
end

task automatic tb_req(input [2:0] kind, input [8:0] ctx);
    integer t;
    begin
        tb_req_kind = kind; tb_req_ctx = ctx; tb_req_valid = 1'b1; #1;
        t = 0;
        while (!req_ready) begin @(posedge clk); #1; t = t + 1; if (t > 5000) `FAIL("hang", "bench request never accepted") end
        @(posedge clk); #1; tb_req_valid = 1'b0;
        t = 0;
        while (!rsp_valid) begin @(posedge clk); #1; t = t + 1; if (t > 5000) `FAIL("hang", "bench request never answered") end
    end
endtask

initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    if (!$value$plusargs("rate_min=%d", rate_min)) rate_min = 16;
    seed_v = stall + 11; k = $urandom(seed_v);
    $readmemh({stem, ".meta.hex"}, meta);
    n_bytes = meta[0]; n_se = meta[1];
    if (n_bytes > MAXB || n_se > MAXS) `FAIL("harness", "fixture too large")
    $readmemh({stem, ".bytes.hex"}, bytes_m, 0, n_bytes - 1);
    $readmemh({stem, ".se.hex"}, se_m, 0, n_se - 1);
    sp_slice_type = meta[2][1:0]; sp_first_mb = meta[3][13:0];
    sp_num_ref_l0 = meta[4][5:0]; sp_num_ref_l1 = meta[5][5:0]; sp_field = meta[6][0];
    sp_width = meta[7][7:0]; sp_height = meta[8][7:0]; sp_slice_id = meta[11][15:0];
    sp_t8_mode = meta[14][0]; sp_d8inf = meta[15][0];

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    // the slice header's job: a fresh engine on this NAL's bytes, contexts and engine initialised
    tb_req(3'd7, 9'd0);                                  // FLUSH
    feed_on = 1'b1;
    tb_req(3'd3, {meta[10][1:0], meta[9][5:0]});         // INIT(set, QP)
    mbs_owns = 1'b1;
    t_start = $time;
    start = 1'b1; @(posedge clk); #1; start = 1'b0;
    k = 0;
    while (!done) begin @(posedge clk); #1; k = k + 1; if (k > 4000000) `FAIL("hang", "slice never done") end
    repeat (4) @(posedge clk); #1;
    if (err_overrun) `FAIL("done", "err_overrun")
    if (err_bins) `FAIL("done", "err_bins")
    if (si !== n_se) `FAIL("se", $sformatf("%0d SE words emitted, %0d expected", si, n_se))
    if (err_init | err_align | err_underrun) `FAIL("err", $sformatf("err_init %0d err_align %0d err_underrun %0d", err_init, err_align, err_underrun))
    $display("mb_syntax_tb: %0s: %0d macroblocks, %0d SE words, %0d bins in %0d cycles = %0d.%02d bins/cycle",
             stem, mb_seen, si, bin_count, ($time - t_start) / 10,
             (100 * bin_count / (($time - t_start) / 10)) / 100, (100 * bin_count / (($time - t_start) / 10)) % 100);
    if (stall == 0 && (100 * (bin_count + pcm_bytes)) < rate_min * (($time - t_start) / 10))
        `FAIL("rate", $sformatf("%0d bins + %0d PCM bytes in %0d cycles", bin_count, pcm_bytes, ($time - t_start) / 10))
    $display("PASS: mb_syntax_tb");
    $finish;
end

endmodule
