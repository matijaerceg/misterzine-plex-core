// bench/h264/h264_top_tb.sv -- the whole front end (h264/dec/h264_top.sv: nal_parser,
// rbsp_reader, sps_pps, slice_hdr, cabac_engine, mb_syntax) on an Annex-B stream,
// against the record stream tools/h264_fe_ref.py decodes from it (tools/h264_top_golden.py)
//
// +stem=<path>: <stem>.es.hex (the Annex-B bytes), .se.hex (the expected 48-bit words
// {kind, aux, val}), .meta.hex (counts). +stall=N: random gaps on the ES input and a
// random-ready SE consumer (seeded by N). The bench feeds the bytes, pulses es_flush
// after the last one, and scores:
//   [se]      every SE word equals the model's, in order (`!==`); the count matches
//   [count]   nal / slice / picture / SPS / PPS counters equal the model's
//   [refuse]  refused_count and refused_code as the golden says (0 for a clean stream)
//   [err]     err_count equals meta[9] (0; 1 for a truncated stream)
//   [p5c]     the picture timing / PTS counters equal meta[12..17] (full fixtures)
//   [bins]    bin_total equals the model's bin count (clean streams)
//   [hang]    an SE word within 40000 cycles of the previous while busy
//   [idle]    the chain returns to idle (nothing left in flight) after the flush
// A truncated fixture (meta[11] = 1, tools/h264_top_golden.py --truncate) is scored on
// its first n_se words only -- whole NAL units before the cut -- and on the error count
// and the return to idle: the no-hang arm.
// PASS marker: "PASS: h264_top_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module h264_top_tb;

localparam MAXB = 1 << 22;                 // 4 MB of ES
localparam MAXS = 1 << 23;                 // 8 M words (200 packs of a field-coded disc is ~3.5 M)

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT ---------------------------------------------------------------------------
reg  [7:0]  es_byte = 8'd0;
reg         es_valid = 1'b0, es_flush = 1'b0;
wire        es_ready;
wire        se_valid;
reg         se_ready = 1'b0;
wire [7:0]  se_kind, se_aux;
wire [31:0] se_val;
wire        busy;
wire [31:0] nal_count, slice_count, pic_count, sps_count, pps_count, refused_count, err_count;
wire [3:0]  refused_code, err_code;
wire [39:0] bin_total;
wire [31:0] pt_seen, pt_missing, pt_bad, sei_err, pts_tag, pts_drop;
wire [3:0]  last_ps;
reg         es_mark = 1'b0;
reg  [32:0] es_pts = 33'd0;
wire [h264_pkg::PPS_W-1:0] sp_pps;
wire [h264_pkg::SPS_W-1:0] sp_sps;
wire [1:0]  sp_slice_type;
wire        sp_field, sp_bottom, sp_idr;
wire [15:0] sp_frame_num, sp_poc_lsb;
h264_top dut (
    .clk(clk), .rst_n(rst_n), .clear(1'b0),
    .es_byte(es_byte), .es_valid(es_valid), .es_ready(es_ready), .es_flush(es_flush),
    .es_mark(es_mark), .es_pts(es_pts),
    .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
    .sp_pps(sp_pps), .sp_sps(sp_sps), .sp_slice_type(sp_slice_type), .sp_field(sp_field), .sp_bottom(sp_bottom),
    .sp_idr(sp_idr), .sp_frame_num(sp_frame_num), .sp_poc_lsb(sp_poc_lsb),
    .busy(busy), .nal_count(nal_count), .slice_count(slice_count), .pic_count(pic_count),
    .sps_count(sps_count), .pps_count(pps_count), .refused_count(refused_count), .refused_code(refused_code),
    .err_count(err_count), .err_code(err_code), .bin_total(bin_total),
    .pt_seen_count(pt_seen), .pt_missing_count(pt_missing), .pt_bad_count(pt_bad), .sei_err_count(sei_err),
    .pts_tag_count(pts_tag), .pts_drop_count(pts_drop), .last_pic_struct(last_ps));

// ---- fixture ---------------------------------------------------------------------------
reg  [41:0] es_m [0:MAXB-1];              // {pts[32:0], mark, byte} (P5c: the PES sideband)
reg  [47:0] se_m [0:MAXS-1];
reg  [31:0] meta [0:31];
string  stem;
integer stall = 0, n_bytes, n_se, k, seed_v, partial = 0;

// ---- byte feeder with random gaps ------------------------------------------------------
integer bi = 0;
reg     feed_on = 1'b0, fed = 1'b0;
always @(posedge clk) begin
    if (feed_on && bi < n_bytes) begin
        if (!es_valid) begin
            if (stall == 0 || ($urandom % 4) != 0) begin {es_pts, es_mark, es_byte} <= es_m[bi]; es_valid <= 1'b1; end
        end else if (es_ready) begin
            bi <= bi + 1;
            if (bi + 1 < n_bytes && (stall == 0 || ($urandom % 4) != 0)) {es_pts, es_mark, es_byte} <= es_m[bi + 1];
            else es_valid <= 1'b0;
            if (bi + 1 == n_bytes) fed <= 1'b1;
        end
    end else if (es_valid && es_ready) es_valid <= 1'b0;
end

// ---- SE consumer with random readiness, scoring in order ------------------------------------
integer si = 0, idle_cyc = 0, t_start, nal_seen = 0, mb_seen = 0;
reg [47:0] want;
always @(posedge clk) begin
    if (rst_n) begin
        se_ready <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
        if (se_valid && se_ready) begin
            idle_cyc <= 0;
            want = se_m[si];
            if (partial && si >= n_se) ;                     // past the model's failure: not scored
            else if ({se_kind, se_aux, se_val} !== want)
                `FAIL("se", $sformatf("word %0d: got kind %0d aux %0d val %0d, want kind %0d aux %0d val %0d (NAL unit %0d, %0d macroblocks)",
                                      si, se_kind, se_aux, $signed(se_val), want[47:40], want[39:32], $signed(want[31:0]), nal_seen, mb_seen))
            if (se_kind == 8'd17) nal_seen <= nal_seen + 1;
            if (se_kind == 8'd1) mb_seen <= mb_seen + 1;
            si <= si + 1;
        end else if (busy) begin
            idle_cyc <= idle_cyc + 1;
            if (idle_cyc > 40000) `FAIL("hang", $sformatf("no SE word for 40000 cycles after word %0d (NAL unit %0d, %0d macroblocks)", si, nal_seen, mb_seen))
        end
    end
end

initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    seed_v = stall + 7; k = $urandom(seed_v);
    $readmemh({stem, ".meta.hex"}, meta);
    n_bytes = meta[0]; n_se = meta[1]; partial = (meta[11] === 32'd1);   // an older 11-word meta reads X here
    if (n_bytes > MAXB || n_se > MAXS) `FAIL("harness", "fixture too large")
    $readmemh({stem, ".es.hex"}, es_m, 0, n_bytes - 1);
    if (n_se > 0) $readmemh({stem, ".se.hex"}, se_m, 0, n_se - 1);

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    t_start = $time;
    feed_on = 1'b1;
    k = 0;
    while (!fed) begin @(posedge clk); #1; k = k + 1; if (k > 40000000) `FAIL("hang", "the stream was never consumed") end
    @(posedge clk); #1;
    es_flush = 1'b1; @(posedge clk); #1; es_flush = 1'b0;
    k = 0;
    while (busy || (si < n_se && !partial)) begin @(posedge clk); #1; k = k + 1; if (k > 40000000) `FAIL("hang", $sformatf("never idle: %0d of %0d words", si, n_se)) end
    repeat (8) @(posedge clk); #1;
    if (busy) `FAIL("idle", "busy after the flush")
    if (partial ? (si < n_se) : (si !== n_se)) `FAIL("se", $sformatf("%0d SE words emitted, %0d expected", si, n_se))
    if (nal_count !== meta[2] || slice_count !== meta[3] || pic_count !== meta[4] || sps_count !== meta[5] || pps_count !== meta[6])
        `FAIL("count", $sformatf("nal %0d/%0d slices %0d/%0d pics %0d/%0d sps %0d/%0d pps %0d/%0d (got/want)",
                                 nal_count, meta[2], slice_count, meta[3], pic_count, meta[4], sps_count, meta[5], pps_count, meta[6]))
    if (refused_count !== meta[7] || (meta[7] != 0 && refused_code !== meta[8][3:0]))
        `FAIL("refuse", $sformatf("refused %0d code %0d, want %0d code %0d", refused_count, refused_code, meta[7], meta[8]))
    if (err_count !== meta[9]) `FAIL("err", $sformatf("err_count %0d (code %0d), want %0d", err_count, err_code, meta[9]))
    if (meta[7] == 0 && !partial && bin_total !== {8'd0, meta[10]}) `FAIL("bins", $sformatf("bin_total %0d, model %0d", bin_total, meta[10]))
    // P5c: the picture timing and PTS counters (not scored on a refused / partial fixture)
    if (meta[12] !== 32'hFFFFFFFF && {pt_seen, pt_missing, pt_bad, sei_err, pts_tag, pts_drop} !==
                                      {meta[12], meta[13], meta[14], meta[15], meta[16], meta[17]})
        `FAIL("p5c", $sformatf("pic_timing %0d/%0d missing %0d/%0d bad %0d/%0d malformed SEI %0d/%0d PTS tagged %0d/%0d dropped %0d/%0d (got/want)",
                               pt_seen, meta[12], pt_missing, meta[13], pt_bad, meta[14], sei_err, meta[15], pts_tag, meta[16], pts_drop, meta[17]))
    $display("h264_top_tb: %0s: %0d NAL units, %0d slices, %0d macroblocks, %0d SE words, %0d bins in %0d cycles = %0d.%02d bins/cycle, refused %0d (code %0d), errors %0d",
             stem, nal_count, slice_count, mb_seen, si, bin_total, ($time - t_start) / 10,
             (100 * bin_total / (($time - t_start) / 10)) / 100, (100 * bin_total / (($time - t_start) / 10)) % 100,
             refused_count, refused_code, err_count);
    $display("PASS: h264_top_tb");
    $finish;
end

endmodule
