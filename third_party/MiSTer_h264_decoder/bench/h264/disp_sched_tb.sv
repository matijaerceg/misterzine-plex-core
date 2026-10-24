// bench/h264/disp_sched_tb.sv -- the display path from the output queue to the reader
// (roadmap P5e, docs/display.md S7): h264/recon_out.sv (clk_dec -> clk_sys), h264/disp_ctl.sv
// + h264/disp_sched.sv (clk_sys, the raster's) and h264/disp_reader.sv (clk_mem, reading
// bench/h264/ddr_model.sv), on three real clocks and the real raster (h264/sync_gen.sv),
// scored refresh by refresh against tools/disp_sched_ref.py.
//
// The bench is the DPB: at line 10 of the refresh a record becomes available it writes
// the store's display facts (pinfo) and emits it (the stores are the model's: the lowest
// free one, which the bench checks is really free), and pulses eos_done for the END
// record. Arms:
//   [refresh] at line 510 of every refresh: {shown, store, parity, field, single} equal to the
//             model's (the pickup is at line 500)
//   [count]   pickups, decided changes, re-anchors, late pickups, starved refreshes,
//             cadence errors, flags, (P3f, LOW_LATENCY scenarios) skips and (P7) field holds
//             equal to the model's
//   [field]   (P7, +il) at each refresh's first line a shown field PAIR's decided parity is the
//             raster's field there (sync_gen's v_pos[0]: the field the reader shows of a field
//             store, the convention the rig's line markers confirmed) -- the external check: the
//             model states the same rule, this one reads the raster, not the model. Skipped only on
//             the refreshes the model marks as showing a pair taken LATE (UMD's V6 takes a backlog
//             at once, on whichever field: fldlate)
//   [judder]  the reader's own count of the (store, parity) changes it fetched equals the
//             decided changes (the independent half of the judder gate)
//   [hold]    every reader burst is from a store the display holds (emitted, not
//             released); the seam recon_out -> disp_ctl -> disp_reader in one simulation
//   [queue]   the harness: a store the model assigns is free when emitted
// PASS marker: "PASS: disp_sched_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module disp_sched_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam [28:0] BASE = 29'h0600_0000;
reg clk = 0, sclk = 0, mclk = 0, rst_n = 0, srst_n = 0, mrst_n = 0;
always #6.173  clk = ~clk;           // clk_dec 81 MHz
always #18.5185 sclk = ~sclk;        // clk_sys 27 MHz
always #5.5555 mclk = ~mclk;         // the DDR3 bridge 90 MHz

// ---- the raster --------------------------------------------------------------------------
wire [11:0] h_pos, v_pos;
reg         raster_rst_n = 0;
// +il (P6): the 480i raster -- a refresh is a field; the bench's lines 0 / 10 / 510 become
// each field's lines 0 / 5 / 255
reg il = 1'b0;
initial il = $test$plusargs("il");
wire [11:0] rline = il ? {1'b0, v_pos[11:1]} : v_pos;
// (P6 steps 5 / 6: the .stim header's raster standard; at 50 Hz the pickup is at 600 / a
// field's 300, so the check moves to 610 / 305)
wire [11:0] L_CHECK = il ? ((std == 2'd2) ? 12'd305 : 12'd255) : ((std == 2'd2) ? 12'd610 : 12'd510);
wire [11:0] L_EMIT  = il ? 12'd5   : 12'd10;
reg [1:0] std = 2'd0;   // the raster standard (P6 steps 5 / 6): the .stim header's
wire [11:0] sg_lines, sg_last;   // sync_gen's current frame: the reader's wrap (hdmi_raster stage 2)
sync_gen u_sync (.clk(sclk), .clk_en(1'b1), .rst_n(raster_rst_n), .interlaced(il), .std(std), .h_pos(h_pos), .v_pos(v_pos),
                 .pixel_en(), .h_sync(), .v_sync(), .h_blank(), .v_blank(), .frame_tick(), .field(), .nat(1'b0), .g_w(12'd0), .g_h(12'd0), .g_l(12'd0), .g_nt(12'd0), .g_last(12'd0), .lines(sg_lines), .last_line(sg_last));

// ---- the queue --------------------------------------------------------------------------
reg         pinfo_we = 0, pinfo_second = 0, pinfo_ps_v = 0, pinfo_pts_v = 0, pinfo_timing_v = 0;
reg  [4:0]  pinfo_store = 0;
reg  [7:0]  pinfo_w = 0, pinfo_hf = 0;
reg  [3:0]  pinfo_ps = 0;
reg  [32:0] pinfo_pts = 0;
reg  [31:0] pinfo_nuit = 0, pinfo_ts = 0;
reg         emit_valid = 0, emit_unpaired = 0, emit_first_bot = 0, emit_frame = 0, emit_dec_t = 0, emit_dec_b = 0;
reg  [4:0]  emit_store = 0;
reg         eos_done = 0;
wire [19:0] oq_hold;
wire        rec_valid, rec_end, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b, rec_timing_v;
wire        rec_ps_a_v, rec_ps_b_v, rec_pts_v, rec_pts_b_v, rec_take, rel_valid, rec_ovf, rel_bad, rec_more;
wire [4:0]  rec_store, rel_store;
wire [7:0]  rec_w, rec_hf;
wire [39:0] rec_aspect;
wire [40:0] rec_crop;
wire [31:0] rec_nuit, rec_ts;
wire [3:0]  rec_ps_a, rec_ps_b;
wire [32:0] rec_pts, rec_pts_b;
recon_out #(.NST(20)) u_out (
    .clk(clk), .rst_n(rst_n),
    .pinfo_we(pinfo_we), .pinfo_store(pinfo_store), .pinfo_second(pinfo_second), .pinfo_w_mbs(pinfo_w),
    .pinfo_hf_mbs(pinfo_hf), .pinfo_crop(41'd0), .pinfo_aspect(40'd0), .pinfo_colour(3'd1), .pinfo_col_unsup(1'b0), .pinfo_col_tags(26'd0), .pinfo_siting(6'd0), .pinfo_timing_v(pinfo_timing_v),
    .pinfo_nuit(pinfo_nuit), .pinfo_ts(pinfo_ts), .pinfo_ps(pinfo_ps), .pinfo_ps_v(pinfo_ps_v), .pinfo_pts(pinfo_pts),
    .pinfo_pts_v(pinfo_pts_v), .pinfo_idr(1'b0),
    .emit_valid(emit_valid), .emit_store(emit_store), .emit_unpaired(emit_unpaired), .emit_first_bot(emit_first_bot),
    .emit_frame(emit_frame), .emit_dec_t(emit_dec_t), .emit_dec_b(emit_dec_b), .eos_done(eos_done),
    .oq_hold(oq_hold), .n_emit(), .n_rel(), .rec_ovf(rec_ovf), .rel_bad(rel_bad),
    .sclk(sclk), .srst_n(srst_n),
    .rec_valid(rec_valid), .rec_more(rec_more), .rec_take(rec_take), .rec_end(rec_end), .rec_store(rec_store), .rec_frame(rec_frame),
    .rec_unpaired(rec_unpaired), .rec_first_bot(rec_first_bot), .rec_dec_t(rec_dec_t), .rec_dec_b(rec_dec_b),
    .rec_w_mbs(rec_w), .rec_hf_mbs(rec_hf), .rec_crop(rec_crop), .rec_aspect(rec_aspect), .rec_timing_v(rec_timing_v),
    .rec_nuit(rec_nuit), .rec_ts(rec_ts), .rec_ps_a(rec_ps_a), .rec_ps_a_v(rec_ps_a_v), .rec_ps_b(rec_ps_b),
    .rec_ps_b_v(rec_ps_b_v), .rec_pts(rec_pts), .rec_pts_v(rec_pts_v), .rec_pts_b(rec_pts_b), .rec_pts_b_v(rec_pts_b_v),
    .rec_idr(), .rel_valid(rel_valid), .rel_store(rel_store));

// ---- the display control ------------------------------------------------------------------
wire        sh_valid, sh_field, sh_parity, sh_single, ended;
wire [4:0]  sh_store;
wire [7:0]  sh_w, sh_hf;
wire [31:0] n_dc, n_pick, n_skip;
reg         ll = 1'b0;                  // the scenario's LOW_LATENCY (the .stim header)
reg         lead = 1'b0;                // (1.1) the scenario's aud_lead: the queued audio ahead of the clock (the .stim header)
wire [7:0]  n_reanchor;
wire [3:0]  n_lone;                     // UMD's lone-PTS rules (display.md S10)
wire [15:0] n_late, n_starve, n_cadence;
wire [31:0] n_fhold;                    // (P7) pairs held for the raster's field
wire [2:0]  flags;
wire        rate_v;
wire [1:0]  rate_cls;
disp_ctl u_ctl (
    .clk(sclk), .rst_n(srst_n), .frame0(h_pos == 12'd0 && v_pos == 12'd0), .il(il), .std(std),
    .rec_valid(rec_valid), .rec_more(rec_more), .low_lat(ll), .pause(1'b0), .aanc(1'b0), .aanc_pts(33'd0), .aud_lead(lead), .rec_take(rec_take), .rec_end(rec_end), .rec_store(rec_store), .rec_frame(rec_frame),
    .rec_unpaired(rec_unpaired), .rec_first_bot(rec_first_bot), .rec_dec_t(rec_dec_t), .rec_dec_b(rec_dec_b),
    .rec_w_mbs(rec_w), .rec_hf_mbs(rec_hf), .rec_crop(rec_crop), .rec_aspect(rec_aspect), .rec_colour(3'd1), .rec_col_unsup(1'b0), .rec_col_tags(26'd0), .rec_siting(6'd0), .rec_timing_v(rec_timing_v), .rec_nuit(rec_nuit),
    .rec_ts(rec_ts), .rec_ps_a(rec_ps_a), .rec_ps_a_v(rec_ps_a_v), .rec_ps_b(rec_ps_b), .rec_ps_b_v(rec_ps_b_v),
    .rec_pts(rec_pts), .rec_pts_v(rec_pts_v), .rec_pts_b(rec_pts_b), .rec_pts_b_v(rec_pts_b_v),
    .rel_valid(rel_valid), .rel_store(rel_store),
    .sh_valid(sh_valid), .sh_field(sh_field), .sh_store(sh_store), .sh_w(sh_w), .sh_hf(sh_hf), .sh_parity(sh_parity),
    .sh_single(sh_single), .sh_crop(), .sh_aspect(), .n_dc(n_dc), .n_pick(n_pick), .n_skip(n_skip), .n_reanchor(n_reanchor), .n_lone(n_lone), .n_late(n_late), .n_starve(n_starve),
    .n_cadence(n_cadence), .n_fhold(n_fhold), .flags(flags), .lag_ms(), .stc(), .stc_run(), .ended(ended),
    .rate_v(rate_v), .rate_cls(rate_cls));

// ---- the reader over the DDR model ------------------------------------------------------
wire [28:0] d_addr;
wire [7:0]  d_burst;
wire        d_read, d_wait, d_rdv;
wire [63:0] d_rdata;
wire [31:0] fetch_changes;
disp_reader #(.DPB_BASE(BASE)) u_rd (.gradient_dither(1'b0), .lines(sg_lines), .last_line(sg_last),
    .clk(sclk), .ce(1'b1), .rst_n(srst_n), .h_pos(h_pos), .v_pos(v_pos), .il(il), .pal(std == 2'd2), .de_in(1'b1),
    .pic_valid(sh_valid), .pic_store(sh_store), .pic_field(sh_field), .pic_w_mbs(sh_w), .pic_hf_mbs(sh_hf),
    .pic_parity(sh_parity), .pic_single(sh_single), .deint_mode(2'd2), .pic_colour(3'd1), .pic_siting(6'd0),
    // the identity fit (P6 step 3): 720x480 filled 1:1 -- the scheduler's scenarios are about
    // WHICH picture, not where (bench/h264/disp_reader_tb.sv scores the fit)
    .fit_ow(13'd720), .fit_oh(13'd480), .fit_ox0(14'd0), .fit_oy0(14'd0), .fit_sx(28'h001_0000), .fit_sy(28'h001_0000),
    .fit_dh_l2(2'd0), .fit_dv_l2(2'd0), .fit_lx(12'd0), .fit_ty(12'd0), .fit_wc(12'd720), .fit_hc(12'd480),
    .fit_hpf(3'd0), .fit_vpf(3'd0), .clip_enable(1'b0), .clip_x(12'd0), .clip_y(12'd0), .clip_w(12'd0), .clip_h(12'd0),
    .fetch_late(), .r(), .g(), .b(), .de_out(),
    .mclk(mclk), .mrst_n(mrst_n), .ddr_address(d_addr), .ddr_burstcount(d_burst), .ddr_read(d_read),
    .ddr_waitrequest(d_wait), .ddr_readdata(d_rdata), .ddr_readdatavalid(d_rdv), .fetch_changes(fetch_changes));
ddr_model #(.BASE(BASE), .AW(23)) u_mem (
    .clk(mclk), .rst_n(mrst_n), .address(d_addr), .burstcount(d_burst), .read(d_read), .write(1'b0),
    .writedata(64'd0), .byteenable(8'd0), .waitrequest(d_wait), .readdata(d_rdata), .readdatavalid(d_rdv),
    .unwritten_reads());

// ---- the stimulus and the expected refreshes --------------------------------------------
localparam int MAXR = 1024, MAXK = 4096;
string stem;
integer n_rec, n_ref;
integer r_end [0:MAXR-1], r_av [0:MAXR-1], r_st [0:MAXR-1], r_fr [0:MAXR-1], r_up [0:MAXR-1], r_fb [0:MAXR-1];
integer r_dt [0:MAXR-1], r_db [0:MAXR-1], r_psa [0:MAXR-1], r_psav [0:MAXR-1], r_psb [0:MAXR-1], r_psbv [0:MAXR-1];
longint r_pts [0:MAXR-1], r_ptsb [0:MAXR-1], r_nuit [0:MAXR-1], r_ts [0:MAXR-1];
integer r_ptsv [0:MAXR-1], r_ptsbv [0:MAXR-1], r_tv [0:MAXR-1], r_w [0:MAXR-1], r_hf [0:MAXR-1];
integer e_v [0:MAXK-1], e_s [0:MAXK-1], e_p [0:MAXK-1], e_f [0:MAXK-1], e_g [0:MAXK-1], e_l [0:MAXK-1];
integer c_dc, c_pick, c_re, c_late, c_starve, c_cad, c_flags, c_skip, c_rate, c_lone, c_fhold, i_ll, i_std, i_il, i_lead;

task automatic load;
    integer fd, i, rc;
    string tagc;
    begin
        fd = $fopen({stem, ".stim"}, "r");
        if (fd == 0) `FAIL("harness", {"no ", stem, ".stim"})
        rc = $fscanf(fd, "%d %d %d %d %d %d\n", n_rec, n_ref, i_ll, i_std, i_il, i_lead);
        if (rc != 6) `FAIL("harness", "bad .stim header (n_rec n_ref ll std il lead)")
        // (P7) the expected refreshes differ by raster: the model's --il stem with +il, only
        if ((i_il != 0) !== il) `FAIL("harness", $sformatf("the .stim is for il %0d, the bench runs il %b", i_il, il))
        ll = (i_ll != 0);
        lead = (i_lead != 0);
        std = i_std[1:0];
        for (i = 0; i < n_rec; i++) begin
            rc = $fscanf(fd, "%s", tagc);
            if (tagc == "E") begin
                r_end[i] = 1; rc = $fscanf(fd, "%d\n", r_av[i]);
            end else begin
                r_end[i] = 0;
                rc = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                             r_av[i], r_st[i], r_fr[i], r_up[i], r_fb[i], r_dt[i], r_db[i], r_psa[i], r_psav[i],
                             r_psb[i], r_psbv[i], r_pts[i], r_ptsv[i], r_ptsb[i], r_ptsbv[i], r_tv[i], r_nuit[i],
                             r_ts[i], r_w[i], r_hf[i]);
                if (rc != 20) `FAIL("harness", $sformatf("bad record %0d", i))
            end
        end
        $fclose(fd);
        fd = $fopen({stem, ".exp"}, "r");
        for (i = 0; i < n_ref; i++) begin
            rc = $fscanf(fd, "%d %d %d %d %d %d\n", e_v[i], e_s[i], e_p[i], e_f[i], e_g[i], e_l[i]);
            if (rc != 6) `FAIL("harness", $sformatf("bad .exp line %0d", i))
        end
        $fclose(fd);
        fd = $fopen({stem, ".cnt"}, "r");
        rc = $fscanf(fd, "cadence=%d dc=%d fhold=%d flags=%d late=%d lone=%d pickups=%d rate=%d reanchors=%d skip=%d starve=%d",
                     c_cad, c_dc, c_fhold, c_flags, c_late, c_lone, c_pick, c_rate, c_re, c_skip, c_starve);
        if (rc != 11) `FAIL("harness", "bad .cnt")
        $fclose(fd);
    end
endtask

// ---- the refresh count, the display's holds (the bench's view) ----------------------------
integer k = -1;                         // the refresh (frame since the alignment)
reg     aligned_seen = 0;
reg [19:0] held = 20'd0;                // emitted, not released
always @(posedge sclk) if (srst_n) begin
    // the count starts where disp_ctl aligns: the first dot of a frame (at 480i the TOP
    // field's, v_pos 0 -- a bottom field starting first is not counted), then every refresh
    if (h_pos == 12'd0 && rline == 12'd0 && (aligned_seen || v_pos == 12'd0)) begin aligned_seen <= 1'b1; k <= k + 1; end
    if (rel_valid) held[rel_store] = 1'b0;
end

// ---- Refresh Rate's Auto: the first prepared picture's rate class (scored in [count]) --------
integer rate_seen = -1;
always @(posedge sclk) if (srst_n && rate_v && rate_seen < 0) rate_seen = rate_cls;

// ---- [refresh] ------------------------------------------------------------------------------
integer n_checked = 0;
// +field_only (the runner's F1 / F2): [refresh] not fatal, so [field] -- the arm independent of the
// model, which states the same rule -- shows it can go RED by itself
reg field_only = 1'b0;
initial field_only = $test$plusargs("field_only");
always @(posedge sclk) if (srst_n && aligned_seen && h_pos == 12'd0 && rline == L_CHECK && k < n_ref) begin
    if (!field_only &&
        {sh_valid, sh_store, sh_parity, sh_field, sh_single} !== {e_v[k][0], e_s[k][4:0], e_p[k][0], e_f[k][0], e_g[k][0]})
        `FAIL("refresh", $sformatf("refresh %0d: shown %b store %0d parity %b field %b single %b, want %0d %0d %0d %0d %0d", k,
                                    sh_valid, sh_store, sh_parity, sh_field, sh_single, e_v[k], e_s[k], e_p[k], e_f[k], e_g[k]))
    n_checked = n_checked + 1;
end

// ---- [field]: a shown pair's field is the raster's (P7) ----------------------------------------
integer n_fchecked = 0;
integer n_flate = 0;
// (k here is still the previous refresh's: the store it decided is the one this field shows)
always @(posedge sclk) if (srst_n && il && aligned_seen && h_pos == 12'd0 && rline == 12'd0 && k >= 0 && k < n_ref) begin
    if (sh_valid && sh_field && !sh_single && e_l[k] != 0) n_flate = n_flate + 1;
    else if (sh_valid && sh_field && !sh_single) begin
        if (sh_parity !== v_pos[0])
            `FAIL("field", $sformatf("refresh %0d: a field pair's field %b decided, the raster's field is %b (v_pos %0d): played out of order",
                                     k, sh_parity, v_pos[0], v_pos))
        n_fchecked = n_fchecked + 1;
    end
end

// ---- [hold]: every reader burst from a held store -------------------------------------------
always @(posedge mclk) if (mrst_n && d_read && !d_wait) begin : hold_check
    reg [28:0] rel;
    rel = d_addr - BASE;
    if (!held[rel[22:18]])
        `FAIL("hold", $sformatf("refresh %0d: the reader reads store %0d, which the display does not hold", k, rel[22:18]))
end

// ---- the DPB: emissions at line 10 of each refresh ------------------------------------------
integer ri = 0;
initial begin : dpb
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "+stem= missing")
    load();
    // the raster first: disp_ctl aligns its tick at the first (0, 0) it sees
    #100 raster_rst_n = 1;
    #500 rst_n = 1; srst_n = 1; mrst_n = 1;
    forever begin
        @(posedge sclk);
        if (aligned_seen && h_pos == 12'd0 && rline == L_EMIT) begin
            while (ri < n_rec && r_av[ri] <= k) begin
                @(negedge clk);
                if (r_end[ri]) begin
                    eos_done = 1; @(negedge clk); eos_done = 0;
                end else begin
                    if (held[r_st[ri]] || oq_hold[r_st[ri]])
                        `FAIL("queue", $sformatf("record %0d: store %0d is not free at refresh %0d", ri, r_st[ri], k))
                    pinfo_we = 1; pinfo_second = 0; pinfo_store = r_st[ri]; pinfo_w = r_w[ri]; pinfo_hf = r_hf[ri];
                    pinfo_timing_v = r_tv[ri]; pinfo_nuit = r_nuit[ri]; pinfo_ts = r_ts[ri];
                    pinfo_ps = r_psa[ri]; pinfo_ps_v = r_psav[ri]; pinfo_pts = r_pts[ri]; pinfo_pts_v = r_ptsv[ri];
                    @(negedge clk);
                    if (!r_fr[ri] && !r_up[ri]) begin
                        pinfo_second = 1; pinfo_ps = r_psb[ri]; pinfo_ps_v = r_psbv[ri]; pinfo_pts = r_ptsb[ri];
                        pinfo_pts_v = r_ptsbv[ri];
                        @(negedge clk);
                    end
                    pinfo_we = 0;
                    emit_valid = 1; emit_store = r_st[ri]; emit_frame = r_fr[ri]; emit_unpaired = r_up[ri];
                    emit_first_bot = r_fb[ri]; emit_dec_t = r_dt[ri]; emit_dec_b = r_db[ri];
                    held[r_st[ri]] = 1'b1;
                    @(negedge clk);
                    emit_valid = 0;
                end
                ri = ri + 1;
            end
        end
    end
end

initial begin
    #1;
    wait (k == n_ref && h_pos == 12'd10);
    if (n_checked !== n_ref) `FAIL("refresh", $sformatf("%0d refreshes checked of %0d", n_checked, n_ref))
    if (n_pick !== c_pick || n_dc !== c_dc || n_reanchor !== c_re[7:0] || n_late !== c_late[15:0] ||
        n_starve !== c_starve[15:0] || n_cadence !== c_cad[15:0] || flags !== c_flags[2:0] || n_skip !== c_skip ||
        rate_seen !== c_rate || n_lone !== (c_lone > 15 ? 4'hF : c_lone[3:0]) || n_fhold !== c_fhold)
        `FAIL("count", $sformatf("pickups %0d dc %0d reanchors %0d late %0d starve %0d cadence %0d flags %0d skip %0d rate %0d lone %0d fhold %0d; want %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                                  n_pick, n_dc, n_reanchor, n_late, n_starve, n_cadence, flags, n_skip, rate_seen, n_lone, n_fhold,
                                  c_pick, c_dc, c_re, c_late, c_starve, c_cad, c_flags, c_skip, c_rate, c_lone, c_fhold))
    // the decided changes up to refresh n_ref - 1 were fetched at refresh n_ref - 1's line 0
    if (fetch_changes !== n_dc)
        `FAIL("judder", $sformatf("the reader fetched %0d (store, parity) changes, the display decided %0d", fetch_changes, n_dc))
    if (rec_ovf !== 1'b0 || rel_bad !== 1'b0) `FAIL("hold", $sformatf("queue faults: rec_ovf %b rel_bad %b", rec_ovf, rel_bad))
    $display("disp_sched_tb: [std %0d%0s] %0d refreshes identical to the model (rate class %0d); %0d pickups, %0d skipped, %0d re-anchors, %0d late, %0d starved, %0d cadence errors, flags %0d, %0d field holds (%0d pair refreshes on the raster's field, %0d of late pairs not scored); the reader fetched every one of %0d decided changes",
             std, il ? " il" : "", n_ref, rate_seen, n_pick, n_skip, n_reanchor, n_late, n_starve, n_cadence, flags, n_fhold, n_fchecked, n_flate, n_dc);
    $display("PASS: disp_sched_tb");
    $finish;
end

endmodule
`default_nettype wire
