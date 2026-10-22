// bench/h264/recon_top_tb.sv -- the whole reconstruction (h264/dec/recon_top.sv) on a real
// syntax-element stream, two clocks (clk_dec 81 MHz, the DDR3 bridge's 90 MHz), against
// bench/h264/ddr_model.sv (64 MB: 20 stores of 2 MiB), scored against tools/recon_top_golden.py (the model's
// decode-order pictures, pixel-exact vs ffmpeg):
//
//   [pre]   every macroblock's pre-deblock samples (the sample bank the cycle recon_mb
//           starts deblocking it) equal the model's pre-deblock picture there: the first
//           mismatch is reported by (picture, macroblock, plane, x, y)
//   [post]  every picture's store in DDR3 (its field lines for a field) equals the model's
//           post-deblock picture, once every one of its writes has landed
//   [count] the pictures and macroblocks the stream holds, no error counted
//   [hang]  a macroblock completes within 200,000 cycles of the previous one (a wait on
//           the display's holds, counted in stall_cycles, excepted)
//   [out]   P5d, the output process: every store emitted (emit_*) is, in order, the
//           model's (tools/recon_top_golden.py .out.hex: the decode index of the store's
//           first picture, mapped through pic_start, its shape: frame / fields decoded /
//           unpaired, and WHEN: the pictures opened before it -- a DPB-size error moves
//           the timing, not the order), and the end-of-stream word flushes them (eos_done)
//   [hold]  no DDR3 write burst lands in a store the display holds (emitted, not released)
// +stall=N: random gaps in the SE input. The bench is the display: it holds each emitted
// store for a random 0..+hold=N cycles (default 5000), then releases it; the store being
// scored is held too, so the decoder cannot reuse it under the comparison.
// +expect_stall: the holds are long enough that the decoder must WAIT for a release at
// least once (stall_cycles > 0) -- and still decode everything exactly, with no error.
// +expect_alarm (the runner's second build, -Precon_top_tb.STALL=N small; ported from
// MiSTer_UMD_Video's P6b3i): a wait for the display outlasts recon_dpb's STALL_LIMIT, so the
// no-free-store alarm must count (code 6) -- and every picture is still exact (the decoder
// waits on after counting). [alarm]. Before this no bench hold outlasted the 13 M-cycle (now 14 M)
// bound: the alarm had never run in simulation.
// +frozen (the same build; Phase 4's pause, UMD P6b3i's disp_frz): the display frozen for the
// whole run -- some wait must outlast STALL (else the arm proves nothing) and still no error
// is counted: a pause's holds are no alarm. [frz].
// +expect_refused (interface 0.11, the picture bound): every picture is above Level 3.1's MaxFS
// (3,600 macroblocks) -- each slice refused (ref_size), no macroblock reconstructed, no DDR3
// write, no store emitted to the display, no error counted; the end of stream still taken.
// [refuse].
// +colour=N (0.16, docs/colour.md): every picture's colour code (pinfo_colour) must be N, and with
// +unsup=N the count of pictures flagged shown by the size rule for an unsupported matrix (pinfo_col_unsup)
// N, with +tags=HEX the SPS's colour description (pinfo_col_tags); +scol=N the stream's override;
// +siting=HEX (docs/chroma.md §4) the SPS's chroma siting {bottom, top} (pinfo_siting).
// The runner takes N from ffprobe's reading of the clip (an oracle independent of the RTL). [colour].
// PASS marker: "PASS: recon_top_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module recon_top_tb;
parameter int STALL = 13_000_000;          // recon_dpb's bound (the runner's second build: small)

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam [28:0] BASE = 29'h0600_0000;
localparam MAXS = 1 << 23;
localparam MAXP = 1 << 22;

reg clk = 1'b0, mclk = 1'b0;
always #6.173 clk = ~clk;
always #5.556 mclk = ~mclk;
reg rst_n = 1'b0, mrst_n = 1'b0;

reg         se_valid = 1'b0;
wire        se_ready;
reg  [7:0]  se_kind = 0, se_aux = 0;
reg  [31:0] se_val = 0;
reg  [19:0] score_hold = 20'd0, q_hold = 20'd0;
wire [19:0] disp_hold = score_hold | q_hold;
wire        pic_start, pic_done, idle;
wire [4:0]  cur_store, done_store;
wire [1:0]  cur_struct, done_struct;
wire [7:0]  width_mbs, frame_height_mbs;
wire [28:0] ddr_address;
wire [7:0]  ddr_burstcount, ddr_byteenable;
wire        ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
wire [63:0] ddr_writedata, ddr_readdata;
wire [31:0] pic_count, mb_count, err_count, ref_size;
wire [3:0]  err_code;
int         unwritten;

wire        pinfo_we, pinfo_second, emit_valid, emit_unpaired, emit_frame, emit_dec_t, emit_dec_b, eos_done;
reg  [2:0]  scol = 3'd0;                   // +scol=N (0.16): the stream's colour override
wire [2:0]  pinfo_colour;
wire        pinfo_col_unsup;
wire [25:0] pinfo_col_tags;
wire  [5:0] pinfo_siting;
integer     col_unsup = 0;
reg  [25:0] col_tags;
wire [4:0]  pinfo_store, emit_store;
wire [31:0] stall_cycles;
// [dropped]: the status counter of stores C.4.4 drops unshown (no_output_of_prior_pics_flag);
// +dropped=N from the runner (0 by default: a stream without the flag drops nothing)
wire [31:0] out_dropped;
integer want_dropped = 0;
reg         disp_frz = 1'b0;              // (Phase 4) +frozen: the display frozen, the pause
recon_top #(.DPB_BASE(BASE), .STALL_LIMIT(STALL)) dut (
    .clk(clk), .rst_n(rst_n), .clear(1'b0),
    .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
    .disp_hold(disp_hold), .disp_frz(disp_frz), .pic_start(pic_start), .cur_store(cur_store), .cur_struct(cur_struct),
    .pic_done(pic_done), .done_store(done_store), .done_struct(done_struct),
    .width_mbs(width_mbs), .frame_height_mbs(frame_height_mbs), .idle(idle),
    .stream_colour(scol),
    .mclk(mclk), .mrst_n(mrst_n),
    .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
    .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
    .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid),
    .pic_count(pic_count), .mb_count(mb_count), .err_count(err_count), .err_code(err_code), .ref_size(ref_size),
    .pinfo_we(pinfo_we), .pinfo_store(pinfo_store), .pinfo_second(pinfo_second), .pinfo_w_mbs(), .pinfo_hf_mbs(),
    .pinfo_colour(pinfo_colour), .pinfo_col_unsup(pinfo_col_unsup), .pinfo_col_tags(pinfo_col_tags), .pinfo_siting(pinfo_siting), .pinfo_crop(), .pinfo_timing_v(), .pinfo_nuit(), .pinfo_ts(), .pinfo_ps(), .pinfo_ps_v(), .pinfo_pts(),
    .pinfo_pts_v(), .pinfo_idr(),
    .emit_valid(emit_valid), .emit_store(emit_store), .emit_unpaired(emit_unpaired), .emit_first_bot(),
    .emit_frame(emit_frame), .emit_dec_t(emit_dec_t), .emit_dec_b(emit_dec_b), .emit_poc_t(), .emit_poc_b(),
    .eos_done(eos_done), .out_dropped(out_dropped), .out_direct(), .out_over(), .stall_cycles(stall_cycles), .dpb_fill());

ddr_model #(.BASE(BASE), .AW(23)) ddr (
    .clk(mclk), .rst_n(mrst_n), .address(ddr_address), .burstcount(ddr_burstcount), .read(ddr_read),
    .write(ddr_write), .writedata(ddr_writedata), .byteenable(ddr_byteenable), .waitrequest(ddr_waitrequest),
    .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));

// ---- the fixture ---------------------------------------------------------------------
reg  [47:0] se_m [0:MAXS-1];
reg  [31:0] pic_m [0:4*4096-1];
reg  [63:0] pre_m [0:MAXP-1];
reg  [63:0] post_m [0:MAXP-1];
reg  [31:0] meta [0:4];
reg  [31:0] out_m [0:4095];
string stem;
integer n_se, n_pics, n_words, n_mbs, si = 0, stall = 0;

// ---- the SE feeder (words are taken at the rising edge) --------------------------------
reg accepted = 1'b0;
always @(posedge clk) accepted <= se_valid && se_ready;
always @(negedge clk) if (rst_n) begin
    if (accepted) si = si + 1;
    if (si < n_se && (stall == 0 || $urandom_range(0, stall) == 0)) begin
        se_valid = 1'b1; se_kind = se_m[si][47:40]; se_aux = se_m[si][39:32]; se_val = se_m[si][31:0];
    end else se_valid = 1'b0;
end

// ---- geometry of picture p -----------------------------------------------------------------
function automatic integer pic_w(input integer p); return pic_m[4*p + 1]; endfunction
function automatic integer pic_h(input integer p); return pic_m[4*p + 2]; endfunction
function automatic integer pic_st(input integer p); return pic_m[4*p]; endfunction
function automatic integer pic_off(input integer p); return pic_m[4*p + 3]; endfunction

// ---- [pre]: every macroblock as it reaches the deblocking filter --------------------------------
integer cur_pic = -1;                      // the picture being decoded (decode order)
always @(posedge clk) if (rst_n && pic_start) cur_pic = cur_pic + 1;
integer n_pre = 0;
always @(posedge clk) if (rst_n && dut.u_mb.dbg_pre_db) begin : pre_check
    integer w, h, off, mx, my, x, y, pl, word, lw, want_w;
    reg [63:0] got, want;
    w = pic_w(cur_pic); h = pic_h(cur_pic); off = pic_off(cur_pic);
    mx = dut.u_mb.mbx; my = dut.u_mb.mby;
    for (integer k = 0; k < 48; k = k + 1) begin
        got = (dut.u_mb.dbg_bank == 3'd4) ? dut.u_mb.bank4[k] : (dut.u_mb.dbg_bank == 3'd3) ? dut.u_mb.bank3[k] : (dut.u_mb.dbg_bank == 2'd2) ? dut.u_mb.bank2[k] : (dut.u_mb.dbg_bank == 2'd1) ? dut.u_mb.bank1[k] : dut.u_mb.bank0[k];
        if (k < 32) begin              // luma row k >> 1, word k & 1
            y = my * 16 + (k >> 1); lw = 2 * w;
            want = pre_m[off + y * lw + 2 * mx + (k & 1)];
            pl = 0;
        end else if (k < 40) begin
            y = my * 8 + (k - 32); lw = w;
            want = pre_m[off + 16 * h * 2 * w + y * lw + mx];
            pl = 1;
        end else begin
            y = my * 8 + (k - 40); lw = w;
            want = pre_m[off + 16 * h * 2 * w + 8 * h * w + y * lw + mx];
            pl = 2;
        end
        if (got !== want) begin
            integer bi;
            bi = 0;
            while (bi < 8 && got[8*bi +: 8] === want[8*bi +: 8]) bi = bi + 1;
            `FAIL("pre", $sformatf("picture %0d mb (%0d, %0d) plane %0d x %0d y %0d: %0d, model %0d (word %0d: %h vs %h)",
                  cur_pic, mx, my, pl, (pl == 0 ? mx * 16 + (k & 1) * 8 : mx * 8) + bi, y, got[8*bi +: 8], want[8*bi +: 8], k, got, want))
        end
    end
    n_pre = n_pre + 1;
end

// ---- [post]: a completed picture's store, once its writes landed ----------------------------------
integer wr_issued = 0;                     // write bursts accepted by the memory client
always @(posedge clk) if (rst_n && dut.m_cmd_valid && dut.c_cmd_ready && dut.m_cmd_write) wr_issued = wr_issued + 1;
integer n_post = 0;
task automatic check_store(input integer p, input [4:0] store, input [1:0] st);
    integer w, h, off, y, x, srow, lw;
    reg [28:0] a;
    reg [63:0] got, want;
    w = pic_w(p); h = pic_h(p); off = pic_off(p);
    for (integer pl = 0; pl < 3; pl = pl + 1) begin
        integer rows, words, poff, goff;
        rows = (pl == 0) ? 16 * h : 8 * h;
        words = (pl == 0) ? 2 * w : w;
        poff = (pl == 0) ? 0 : (pl == 1) ? 32 * w * dut.frame_height_mbs : 40 * w * dut.frame_height_mbs;
        goff = (pl == 0) ? 0 : (pl == 1) ? 16 * h * 2 * w : 16 * h * 2 * w + 8 * h * w;
        for (y = 0; y < rows; y = y + 1) begin
            srow = (st == 2'd0) ? y : 2 * y + (st == 2'd2 ? 1 : 0);
            for (x = 0; x < words; x = x + 1) begin
                a = BASE + {store, 18'd0} + poff + srow * words + x;
                got = ddr.peek(a);
                want = post_m[off + goff + y * words + x];
                if (got !== want) begin
                    integer bi;
                    bi = 0;
                    while (bi < 8 && got[8*bi +: 8] === want[8*bi +: 8]) bi = bi + 1;
                    `FAIL("post", $sformatf("picture %0d plane %0d x %0d y %0d (mb %0d, %0d): %0d, model %0d",
                          p, pl, 8 * x + bi, y, (8 * x + bi) / ((pl == 0) ? 16 : 8), y / ((pl == 0) ? 16 : 8), got[8*bi +: 8], want[8*bi +: 8]))
                end
            end
        end
    end
    n_post = n_post + 1;
endtask

integer     want_colour = -1, want_unsup = -1, n_colour = 0, iv_c;
reg  [25:0] want_tags; reg have_tags = 1'b0;
reg   [5:0] want_siting, siting_seen; reg have_siting = 1'b0;
always @(posedge clk) if (pinfo_we && !pinfo_second && want_colour >= 0) begin
    if (pinfo_colour !== want_colour[2:0])
        `FAIL("colour", $sformatf("picture %0d: colour code %0d, want %0d", n_colour, pinfo_colour, want_colour))
    if (pinfo_col_unsup) col_unsup = col_unsup + 1;
    col_tags = pinfo_col_tags;
    siting_seen = pinfo_siting;
    n_colour = n_colour + 1;
end
reg     expect_refused = 1'b0;             // +expect_refused (0.11): every picture above the bound
// the picture being held for scoring: set when it opens, released when scored
reg [4:0] open_store;
integer store_of [0:4095];                 // each picture's store (pic_done k is picture k: pictures
                                           // complete in decoding order, the last one on the end of stream)
integer first_pic_of [0:31];               // the picture that opened the store's current use (the [out] identity)
integer opened = 0;                        // this block's own count (cur_pic steps in another block: a race)
reg [11:0] opened_q = 12'd0;               // the pictures opened BEFORE this cycle (nonblocking: race-free)
always @(posedge clk) if (rst_n && pic_start) opened_q <= opened_q + 12'd1;
reg trace = 1'b0;                          // +trace: every open / emission / completion
always @(posedge clk) if (rst_n && trace) begin
    if (pic_start) $display("trace %0t open picture %0d store %0d second %b", $time, opened, cur_store, pinfo_second);
    if (emit_valid) $display("trace %0t emit store %0d (picture %0d) unpaired %b", $time, emit_store, first_pic_of[emit_store], emit_unpaired);
    if (pic_done) $display("trace %0t done store %0d struct %0d", $time, done_store, done_struct);
end
always @(posedge clk) if (rst_n && pic_start) begin
    score_hold = score_hold | (20'd1 << cur_store);
    store_of[opened] = cur_store;
    if (!pinfo_second) first_pic_of[cur_store] = opened;
    opened = opened + 1;
end

// ---- [out] / the display: emissions in the model's order, held, then released ----------------
integer n_emit = 0, n_out = 0, hold_max = 5000, eos_seen = 0;
reg     expect_stall = 1'b0;
integer rel_at [0:31];
always @(posedge clk) if (rst_n) begin
    if (emit_valid) begin : emit_check
        reg [31:0] got;
        got = {opened_q, emit_frame, emit_dec_b, emit_dec_t, emit_unpaired, first_pic_of[emit_store][15:0]};
        if (expect_refused) `FAIL("refuse", $sformatf("store %0d emitted for a refused picture: an unwritten store sent to the display", emit_store))
        if (n_emit >= n_out) `FAIL("out", $sformatf("store %0d emitted beyond the model's %0d", emit_store, n_out))
        if (got !== out_m[n_emit])
            `FAIL("out", $sformatf("emission %0d: picture %0d frame %b dec %b%b unpaired %b after %0d opened, want picture %0d frame %b dec %b%b unpaired %b after %0d",
                                   n_emit, got[15:0], got[19], got[18], got[17], got[16], got[31:20],
                                   out_m[n_emit][15:0], out_m[n_emit][19], out_m[n_emit][18], out_m[n_emit][17], out_m[n_emit][16], out_m[n_emit][31:20]))
        if (q_hold[emit_store]) `FAIL("out", $sformatf("store %0d emitted while the display still holds it", emit_store))
        q_hold[emit_store] = 1'b1;
        rel_at[emit_store] = $time / 12.346 + $urandom_range(0, hold_max);
        n_emit = n_emit + 1;
    end
    for (integer i = 0; i < 20; i = i + 1)
        if (q_hold[i] && ($time / 12.346) >= rel_at[i]) q_hold[i] = 1'b0;
    if (eos_done) eos_seen = eos_seen + 1;
end
// [hold]: a write burst into a store the display holds (sampled at the command, on mclk)
always @(posedge mclk) if (mrst_n && ddr_write && !ddr_waitrequest) begin : hold_check
    reg [28:0] rel;
    rel = ddr_address - BASE;
    if (rel[28:23] == 6'd0 && q_hold[rel[22:18]])
        `FAIL("hold", $sformatf("a write to store %0d while the display holds it (word %h)", rel[22:18], ddr_address))
end
// pic_done k is picture k (pictures complete in decoding order): queued with the writes
// issued by then, and scored IN ORDER by one process (a fork per picture would read the
// queue index after the next picture's pic_done moved it)
integer n_done = 0, n_scored = 0;
reg [4:0]  dq_store  [0:4095];
reg [1:0]  dq_struct [0:4095];
integer    dq_target [0:4095];
always @(posedge clk) if (rst_n && pic_done) begin
    if (n_done >= opened || store_of[n_done] !== {27'd0, done_store})
        `FAIL("count", $sformatf("pic_done %0d in store %0d: that picture opened in store %0d", n_done, done_store, store_of[n_done]))
    dq_store[n_done] = done_store; dq_struct[n_done] = done_struct;
    dq_target[n_done] = wr_issued;         // every write burst issued so far is this picture's or earlier
    n_done = n_done + 1;
end
initial begin : post_loop
    reg [4:0] s;
    forever begin
        @(posedge clk);
        while (n_scored < n_done) begin
            s = dq_store[n_scored];
            while (dut.u_mem.stat_writes < dq_target[n_scored]) @(posedge clk);
            if (!expect_refused) check_store(n_scored, s, dq_struct[n_scored]);   // (refused: nothing to score)
            else n_post = n_post + 1;
            // release unless the new picture reuses the store (a second field)
            if (!(dut.cur_store == s)) score_hold = score_hold & ~(20'd1 << s);
            n_scored = n_scored + 1;
        end
    end
end

// ---- [hang] ---------------------------------------------------------------------------------
integer since = 0;
integer wait_max = 0;                      // the longest wait recon_dpb's counter reached
integer wait_run = 0, run_max = 0, last_chg = 0, run_start = 0;   // the longest unbroken wait, by stall_cycles (+frozen: the counter rests)
reg     expect_alarm = 1'b0;
reg [31:0] stall_q = 32'd0;
always @(posedge clk) if (rst_n) begin
    // a cycle the DPB waits on the display's holds is not a hang (stall_cycles counts it)
    // -- while the display holds something it will release; a wait on the bench's own
    // scoring hold alone can never end (NSTORE too small: R9)
    // (a refused stream reconstructs nothing: the words it discards are its progress)
    since = (dut.u_mb.mb_done || (stall_cycles != stall_q && q_hold != 20'd0) || (expect_refused && accepted)) ? 0 : since + 1;
    // a wait: stall_cycles stepping (by 2, every other cycle) without a gap of more than 3
    wait_run = wait_run + 1;
    if (stall_cycles != stall_q) begin
        if (wait_run - last_chg > 3) run_start = wait_run;
        last_chg = wait_run;
        if (wait_run - run_start > run_max) run_max = wait_run - run_start;
    end
    stall_q = stall_cycles;
    if (dut.u_dpb.stall_ctr > wait_max) wait_max = dut.u_dpb.stall_ctr;
    if (since > 200000) `FAIL("hang", $sformatf("no macroblock for 200000 cycles (after %0d, picture %0d, state %0d)", mb_count, cur_pic, dut.u_mb.ms))
end

initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "+stem= missing")
    void'($value$plusargs("stall=%d", stall));
    void'($value$plusargs("hold=%d", hold_max));
    void'($value$plusargs("dropped=%d", want_dropped));
    expect_stall = $test$plusargs("expect_stall");
    expect_alarm = $test$plusargs("expect_alarm");
    expect_refused = $test$plusargs("expect_refused");
    if ($value$plusargs("scol=%d", iv_c)) scol = iv_c[2:0];
    void'($value$plusargs("colour=%d", want_colour));
    void'($value$plusargs("unsup=%d", want_unsup));
    have_tags = $value$plusargs("tags=%h", want_tags);
    have_siting = $value$plusargs("siting=%h", want_siting);
    disp_frz     = $test$plusargs("frozen");
    trace = $test$plusargs("trace");
    $readmemh({stem, ".meta.hex"}, meta);
    n_se = meta[0]; n_pics = meta[1]; n_words = meta[2]; n_mbs = meta[3]; n_out = meta[4];
    for (integer i = 0; i < 32; i = i + 1) begin first_pic_of[i] = -1; rel_at[i] = 0; end
    $readmemh({stem, ".out.hex"}, out_m, 0, (n_out > 0 ? n_out : 1) - 1);
    $readmemh({stem, ".se.hex"}, se_m, 0, n_se - 1);
    $readmemh({stem, ".pic.hex"}, pic_m, 0, 4 * n_pics - 1);
    $readmemh({stem, ".pre.hex"}, pre_m, 0, n_words - 1);
    $readmemh({stem, ".post.hex"}, post_m, 0, n_words - 1);
    #40 rst_n = 1'b1; mrst_n = 1'b1;
    // wait for every word to be taken (the last is the end-of-stream word) and its flush:
    // the last picture is closed by it (pic_done) and scored like every other
    wait (si == n_se);
    begin : drain
        integer t;
        t = 0;
        while ((eos_seen == 0 || (!expect_refused && n_post < n_pics) || !idle) && t < 4000000) begin @(posedge clk); t = t + 1; end
        if (eos_seen !== 1) `FAIL("out", $sformatf("end of stream: %0d eos_done pulses, want 1", eos_seen))
    end
    repeat (20) @(posedge clk);
    if (expect_refused) begin
        if (ref_size < n_pics || mb_count !== 32'd0 || wr_issued !== 0 || n_emit !== 0 || err_count !== 32'd0 || dut.u_mb.err_count !== 32'd0)
            `FAIL("refuse", $sformatf("%0d pictures of %0d macroblocks: ref_size %0d, %0d macroblocks reconstructed, %0d write bursts, %0d stores emitted, errors %0d / %0d -- want every slice refused, nothing decoded, written or shown",
                                      n_pics, n_mbs / n_pics, ref_size, mb_count, wr_issued, n_emit, err_count, dut.u_mb.err_count))
        $display("recon_top_tb: refused: %0d slices of %0d pictures (%0d macroblocks each, above 3,600): nothing reconstructed, written or emitted",
                 ref_size, n_pics, n_mbs / n_pics);
        $display("PASS: recon_top_tb");
        $finish;
    end
    if (n_emit !== n_out) `FAIL("out", $sformatf("%0d stores emitted, the model emits %0d", n_emit, n_out))
    if (out_dropped !== want_dropped) `FAIL("dropped", $sformatf("the dropped-store counter reads %0d, want %0d", out_dropped, want_dropped))
    if (expect_stall && stall_cycles == 32'd0) `FAIL("out", "the holds never made the decoder wait (+expect_stall)")
    if (cur_pic + 1 !== n_pics) `FAIL("count", $sformatf("%0d pictures, the stream has %0d", cur_pic + 1, n_pics))
    if (mb_count !== n_mbs) `FAIL("count", $sformatf("%0d macroblocks, the stream has %0d", mb_count, n_mbs))
    if (disp_frz && run_max <= STALL)
        `FAIL("frz", $sformatf("the longest wait was %0d cycles, not past the bound %0d: the frozen arm proves nothing", run_max, STALL))
    if (disp_frz && (err_count !== 32'd0 || dut.u_mb.err_count !== 32'd0))
        `FAIL("frz", $sformatf("frozen, errors: top %0d (code %0d), mb %0d -- a pause's holds counted as the alarm", err_count, err_code, dut.u_mb.err_count))
    if (disp_frz) $display("recon_top_tb: frozen: the longest wait %0d cycles against the bound %0d, no alarm", run_max, STALL);
    if (expect_alarm) begin
        if (err_count == 32'd0 || err_code !== 4'd6 || dut.u_mb.err_count !== 32'd0)
            `FAIL("alarm", $sformatf("a wait of %0d cycles against the bound %0d: errors top %0d (code %0d), mb %0d; want the no-free-store alarm (6)",
                                     wait_max, STALL, err_count, err_code, dut.u_mb.err_count))
    end else if (err_count !== 32'd0 || dut.u_mb.err_count !== 32'd0) `FAIL("count", $sformatf("errors: top %0d (code %0d), mb %0d", err_count, err_code, dut.u_mb.err_count))
    if (n_post !== n_pics) `FAIL("count", $sformatf("%0d pictures scored of %0d", n_post, n_pics))
    if (want_colour >= 0) begin
        if (n_colour == 0) `FAIL("colour", "no picture's colour code was seen")
        if (want_unsup >= 0 && col_unsup !== want_unsup)
            `FAIL("colour", $sformatf("col_unsup %0d, want %0d", col_unsup, want_unsup))
        if (have_tags && col_tags !== want_tags)
            `FAIL("colour", $sformatf("col_tags %h, want %h", col_tags, want_tags))
        if (have_siting && siting_seen !== want_siting)
            `FAIL("colour", $sformatf("siting %h, want %h", siting_seen, want_siting))
        $display("recon_top_tb: colour: %0d pictures coded %0d, col_unsup %0d, tags %h", n_colour, want_colour, col_unsup, col_tags);
    end
    $display("recon_top_tb: %0d pictures, %0d macroblocks, every pre-deblock macroblock and every picture identical; %0d stores emitted in the model's order; %0d clk_dec cycles (%0d per macroblock; %0d waiting on the display)",
             n_pics, mb_count, n_emit, $time / 12.346, ($time / 12.346) / (mb_count ? mb_count : 1), stall_cycles);
    $display("PASS: recon_top_tb");
    $finish;
end

endmodule
