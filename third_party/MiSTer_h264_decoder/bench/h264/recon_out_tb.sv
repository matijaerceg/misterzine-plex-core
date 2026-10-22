// bench/h264/recon_out_tb.sv -- h264/recon_out.sv, the output queue between the
// reconstruction (clk_dec, 81 MHz) and the display (clk_sys, 27 MHz), on two real clocks.
// The bench plays both sides: a DPB that writes each store's display facts (pinfo, the
// "a" half and sometimes a second field's "b" half) and emits it as soon as one cycle
// later -- only stores the queue does not hold, as recon_dpb may -- with bursts of
// back-to-back emissions; and a display that takes each record, holds its store a random
// time and releases the stores in any order.
//
//   [rec]   every record, in emission order: store, shape, every table field (the b half
//           when the bench wrote it for that allocation); no record missing or extra
//   [hold]  a store the display has queued or holds is held (oq_hold) at every clk_dec
//           edge from the cycle after its emission until the display releases it, and
//           its hold falls within 16 clk_dec cycles of the release (liveness)
//   [end]   the END record arrives once, after every store record
//   [flags] rec_ovf / rel_bad stay 0 through the run; a release of a store not held at
//           the end sets rel_bad (the detector is alive)
// PASS marker: "PASS: recon_out_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module recon_out_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam int NST = 20, N = 600;
reg clk = 0, sclk = 0, rst_n = 0, srst_n = 0;
always #6.173 clk = ~clk;
always #18.518 sclk = ~sclk;

reg         pinfo_we = 0, pinfo_second = 0, pinfo_ps_v = 0, pinfo_pts_v = 0, pinfo_idr = 0;
reg  [4:0]  pinfo_store = 0;
reg  [7:0]  pinfo_w = 0, pinfo_hf = 0;
reg  [40:0] pinfo_crop = 0;
reg  [39:0] pinfo_aspect = 0;
reg         pinfo_timing_v = 0;
reg  [31:0] pinfo_nuit = 0, pinfo_ts = 0;
reg  [3:0]  pinfo_ps = 0;
reg  [32:0] pinfo_pts = 0;
reg         emit_valid = 0, emit_unpaired = 0, emit_first_bot = 0, emit_frame = 0, emit_dec_t = 0, emit_dec_b = 0;
reg  [4:0]  emit_store = 0;
reg         eos_done = 0;
wire [NST-1:0] oq_hold;
wire [31:0] n_emit, n_rel;
wire        rec_ovf, rel_bad;
wire        rec_valid, rec_end, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b;
wire [4:0]  rec_store;
wire [7:0]  rec_w, rec_hf;
wire [40:0] rec_crop;
wire [39:0] rec_aspect;
wire        rec_timing_v;
wire [31:0] rec_nuit, rec_ts;
wire [3:0]  rec_ps_a, rec_ps_b;
wire        rec_ps_a_v, rec_ps_b_v, rec_pts_v, rec_pts_b_v, rec_idr;
wire [32:0] rec_pts, rec_pts_b;
reg         rec_take = 0, rel_valid = 0;
reg  [4:0]  rel_store = 0;

recon_out #(.NST(NST)) dut (
    .clk(clk), .rst_n(rst_n),
    .pinfo_we(pinfo_we), .pinfo_store(pinfo_store), .pinfo_second(pinfo_second), .pinfo_w_mbs(pinfo_w),
    .pinfo_hf_mbs(pinfo_hf), .pinfo_crop(pinfo_crop), .pinfo_aspect(pinfo_aspect), .pinfo_colour(3'd1), .pinfo_col_unsup(1'b0), .pinfo_col_tags(26'd0), .pinfo_siting(6'd0), .pinfo_timing_v(pinfo_timing_v),
    .pinfo_nuit(pinfo_nuit), .pinfo_ts(pinfo_ts), .pinfo_ps(pinfo_ps),
    .pinfo_ps_v(pinfo_ps_v), .pinfo_pts(pinfo_pts), .pinfo_pts_v(pinfo_pts_v), .pinfo_idr(pinfo_idr),
    .emit_valid(emit_valid), .emit_store(emit_store), .emit_unpaired(emit_unpaired), .emit_first_bot(emit_first_bot),
    .emit_frame(emit_frame), .emit_dec_t(emit_dec_t), .emit_dec_b(emit_dec_b), .eos_done(eos_done),
    .oq_hold(oq_hold), .n_emit(n_emit), .n_rel(n_rel), .rec_ovf(rec_ovf), .rel_bad(rel_bad),
    .sclk(sclk), .srst_n(srst_n),
    .rec_valid(rec_valid), .rec_take(rec_take), .rec_end(rec_end), .rec_store(rec_store), .rec_frame(rec_frame),
    .rec_unpaired(rec_unpaired), .rec_first_bot(rec_first_bot), .rec_dec_t(rec_dec_t), .rec_dec_b(rec_dec_b),
    .rec_w_mbs(rec_w), .rec_hf_mbs(rec_hf), .rec_crop(rec_crop), .rec_aspect(rec_aspect),
    .rec_timing_v(rec_timing_v), .rec_nuit(rec_nuit), .rec_ts(rec_ts),
    .rec_ps_a(rec_ps_a), .rec_ps_a_v(rec_ps_a_v), .rec_ps_b(rec_ps_b), .rec_ps_b_v(rec_ps_b_v),
    .rec_pts(rec_pts), .rec_pts_v(rec_pts_v), .rec_pts_b(rec_pts_b), .rec_pts_b_v(rec_pts_b_v), .rec_idr(rec_idr),
    .rel_valid(rel_valid), .rel_store(rel_store));

// ---- the scoreboard: per emission, what the record must say --------------------------
reg  [4:0]   exp_store [0:N-1];
reg  [4:0]   exp_shape [0:N-1];          // {frame, unpaired, first_bot, dec_t, dec_b}
reg  [201:0] exp_a [0:N-1];
reg  [38:0]  exp_b [0:N-1];
reg          exp_bv [0:N-1];             // the b half was written for this allocation
reg  [201:0] cur_a [0:31];               // the bench's own copy of the table, per store
reg  [38:0]  cur_b [0:31];
reg          cur_bv [0:31];

// the display's view of a store: 0 free, 1 emitted (queued or shown), cleared when released
reg  [NST-1:0] q_disp = '0;              // set at emission (clk), cleared at release (sclk)
integer rel_time [0:31];                 // the release's time (ns), for liveness

// ---- the DPB side (clk) -----------------------------------------------------------------
integer n_em = 0;
task automatic pinfo(input [4:0] s, input second);
    reg [201:0] a;
    reg [38:0]  b;
    begin
        @(negedge clk);
        pinfo_we = 1; pinfo_store = s; pinfo_second = second;
        pinfo_w = $urandom; pinfo_hf = $urandom; pinfo_crop = {$urandom, $urandom, $urandom};
        pinfo_aspect = {$urandom, $urandom}; pinfo_timing_v = $urandom; pinfo_nuit = $urandom; pinfo_ts = $urandom;
        pinfo_ps = $urandom; pinfo_ps_v = $urandom;
        pinfo_pts = {$urandom, $urandom}; pinfo_pts_v = $urandom; pinfo_idr = $urandom;
        if (!second) cur_a[s] = {pinfo_w, pinfo_hf, pinfo_crop, pinfo_aspect, pinfo_timing_v, pinfo_nuit, pinfo_ts,
                                 pinfo_ps, pinfo_ps_v, pinfo_pts, pinfo_pts_v, pinfo_idr};
        else begin cur_b[s] = {pinfo_ps, pinfo_ps_v, pinfo_pts, pinfo_pts_v}; cur_bv[s] = 1; end
        @(negedge clk);
        pinfo_we = 0;
    end
endtask

integer seed = 1, seed_in = 1;
initial begin : dpb
    integer s, tries, gap;
    reg [4:0] sh;
    void'($value$plusargs("seed=%d", seed));
    seed_in = seed;
    s = $urandom(seed);                  // seeds this process's generator (+seed=N)
    #100 rst_n = 1; srst_n = 1;
    repeat (10) @(negedge clk);
    while (n_em < N) begin
        // a store neither the queue nor the display holds (recon_dpb's st_busy)
        tries = 0;
        s = $urandom_range(0, NST - 1);
        while ((oq_hold[s] || q_disp[s]) && tries < 200) begin
            @(negedge clk); s = $urandom_range(0, NST - 1); tries = tries + 1;
        end
        if (!(oq_hold[s] || q_disp[s])) begin
            cur_bv[s] = 0;
            pinfo(s[4:0], 0);
            if ($urandom_range(0, 1)) pinfo(s[4:0], 1);
            // the emission: the next cycle (the tightest the DPB can be), or later
            gap = ($urandom_range(0, 3) == 0) ? 0 : $urandom_range(0, 40);
            repeat (gap) @(negedge clk);
            sh = $urandom;
            emit_valid = 1; emit_store = s; {emit_frame, emit_unpaired, emit_first_bot, emit_dec_t, emit_dec_b} = sh;
            exp_store[n_em] = s; exp_shape[n_em] = sh; exp_a[n_em] = cur_a[s]; exp_b[n_em] = cur_b[s];
            exp_bv[n_em] = cur_bv[s];
            q_disp[s] = 1'b1;
            n_em = n_em + 1;
            @(negedge clk);
            emit_valid = 0;
        end
    end
    repeat (20) @(negedge clk);
    eos_done = 1; @(negedge clk); eos_done = 0;
end

// ---- [hold]: every edge, a store the display has is held (after its emission's cycle) --
reg [NST-1:0] q_prev = '0;
always @(posedge clk) if (rst_n) begin
    for (int i = 0; i < NST; i++) begin
        if (q_prev[i] && q_disp[i] && !oq_hold[i])
            `FAIL("hold", $sformatf("store %0d is queued or shown but not held (oq_hold)", i))
        if (!q_disp[i] && oq_hold[i] && rel_time[i] > 0 && ($realtime - rel_time[i]) > 16 * 12.346)
            `FAIL("hold", $sformatf("store %0d released %0.0f ns ago and still held", i, $realtime - rel_time[i]))
    end
    q_prev <= q_disp;
end

// ---- the display side (sclk) --------------------------------------------------------------
integer n_rec = 0, n_end = 0;
integer held_until [0:31];
reg [NST-1:0] shown = '0;
reg          bad_rel = 1'b0;             // the end: release a store nobody holds
initial for (int i = 0; i < 32; i++) begin held_until[i] = 0; rel_time[i] = 0; end
always @(posedge sclk) if (srst_n) begin : display
    rec_take <= 1'b0;
    rel_valid <= 1'b0;
    if (rec_valid && !rec_take) begin
        rec_take <= 1'b1;
        if (rec_end) begin
            if (n_rec != N) `FAIL("end", $sformatf("the END record after %0d of %0d store records", n_rec, N))
            n_end = n_end + 1;
        end else begin
            if (n_end) `FAIL("end", "a store record after the END record")
            if (n_rec >= N) `FAIL("rec", "a record beyond the emissions")
            if (rec_store !== exp_store[n_rec] ||
                {rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b} !== exp_shape[n_rec])
                `FAIL("rec", $sformatf("record %0d: store %0d shape %b, want store %0d shape %b", n_rec, rec_store,
                                       {rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b},
                                       exp_store[n_rec], exp_shape[n_rec]))
            if ({rec_w, rec_hf, rec_crop, rec_aspect, rec_timing_v, rec_nuit, rec_ts, rec_ps_a, rec_ps_a_v, rec_pts,
                 rec_pts_v, rec_idr} !== exp_a[n_rec])
                `FAIL("rec", $sformatf("record %0d (store %0d): the a half differs", n_rec, rec_store))
            if (exp_bv[n_rec] && {rec_ps_b, rec_ps_b_v, rec_pts_b, rec_pts_b_v} !== exp_b[n_rec])
                `FAIL("rec", $sformatf("record %0d (store %0d): the b half differs", n_rec, rec_store))
            shown[rec_store] = 1'b1;
            held_until[rec_store] = $urandom_range(0, 60);
            n_rec = n_rec + 1;
        end
    end else if (bad_rel) begin
        rel_valid <= 1'b1; rel_store <= 5'd3; bad_rel = 1'b0;
    end else begin : rel_pick
        // one release a cycle, any held store whose time has come (in any order)
        integer k;
        k = -1;
        for (int i = 0; i < NST; i++) if (shown[i] && k < 0) begin
            if (held_until[i] == 0) k = i; else held_until[i] = held_until[i] - 1;
        end
        if (k >= 0) begin
            rel_valid <= 1'b1; rel_store <= k[4:0];
            shown[k] = 1'b0; q_disp[k] = 1'b0; rel_time[k] = $realtime;
        end
    end
end

initial begin
    wait (n_end == 1);
    repeat (200) @(posedge sclk);
    if (n_rec !== N) `FAIL("rec", $sformatf("%0d records of %0d", n_rec, N))
    if (n_emit !== N) `FAIL("rec", $sformatf("n_emit %0d, want %0d", n_emit, N))
    if (n_rel !== N) `FAIL("hold", $sformatf("n_rel %0d, want %0d", n_rel, N))
    if (oq_hold !== '0) `FAIL("hold", $sformatf("stores still held at the end: %b", oq_hold))
    if (rec_ovf !== 1'b0 || rel_bad !== 1'b0) `FAIL("flags", $sformatf("rec_ovf %b rel_bad %b", rec_ovf, rel_bad))
    // the detector is alive: a release of a store nobody holds
    bad_rel = 1'b1;
    repeat (40) @(posedge sclk);
    if (rel_bad !== 1'b1) `FAIL("flags", "a release of a store not held left rel_bad clear")
    $display("recon_out_tb: seed %0d: %0d stores through the queue in order with their table rows, held from emission to release; END last (first store %0d)",
             seed_in, N, exp_store[0]);
    $display("PASS: recon_out_tb");
    $finish;
end

initial begin
    #50_000_000;
    `FAIL("end", $sformatf("timeout: %0d emitted, %0d records, %0d END", n_em, n_rec, n_end))
end

endmodule
`default_nettype wire
