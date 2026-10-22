// bench/h264/vid_equiv_tb.sv -- the SD equivalence gate (docs/hd_raster.md S8 gate 1, stage A): the
// raster path -- sync_gen, disp_fit + disp_reader on a store, ovl_plane on a canvas, idle_bars, the
// output stage and csync_smpte -- built TWICE from one testbench:
//
//   -DMAIN_RTL  main's RTL (the fork point, compiled from a worktree): everything on clk_sys, 27 MHz,
//               every clock a dot; the output stage is emu.sv's inline code, copied below verbatim
//               but for the names of its sources (main has no vid_out.sv).
//   (default)   this branch's: the raster side on clk_vid, 81 MHz, every register on `ce`, one clock
//               in three; the output stage h264/vid_out.sv.
//
// Each writes ONE record per dot -- {VGA_R, G, B, HS, VS, DE, CE_PIXEL, F1, CS, CS_EN} -- from the
// second VS rise at the pins (480i: the third, a top field's; the reader's tags and the overlay's
// descriptor warmed up) for +refs=N frames, to +trace=FILE. Main samples every clock; the branch the clock after each
// dot's load (the one clock CE_PIXEL is high in). The runner (run_vid_equiv.sh) compares the files:
// identical = the 27 MHz rasters reach the pins exactly as before the domain move -- the analog-first
// proof. Inputs are quasi-static, set before the reset: no crossing is exercised here (emu's bundle
// is check_emu_wiring's).
//
// Plusargs: +trace=FILE +refs=N +store=FILE +w=N +hf=N +cuy4 +cl/+cr/+ct/+cb=N +sarw/+sarh=N +fmode=N
//   +il +at +pal +std=N (0 59.94, 1 60.00, 2 50) +ovl=STEM (an ovl_plane fixture: its refresh-0
//   descriptor and its memory) +vis=N (the idle screen's vis) +root=DIR (where bench/h264/fixtures
//   lives: the main build runs from its worktree).
// PASS marker: "PASS: vid_equiv_tb".

`timescale 1ns/1ps
`default_nettype none

module vid_equiv_tb;
    localparam logic [28:0] BASE      = 29'h0600_0000;
    localparam logic [28:0] FB_WORD   = 29'h0440_0000;   // FB_BYTE / 8
    localparam logic [28:0] CTRL_WORD = 29'h0628_0000;   // CTRL_BYTE / 8
    localparam logic [28:0] CB_WIN    = 29'h0010_0000;   // the control block inside the window

    logic clk = 0, mclk = 0, rst_n = 0;
`ifdef MAIN_RTL
    always #18.519 clk = ~clk;                           // clk_sys, 27 MHz: every clock a dot
    wire        ce = 1'b1;
`else
    always #6.173 clk = ~clk;                            // clk_vid, 81 MHz
    logic [1:0] cph = 2'd0;
    always @(posedge clk) cph <= (cph == 2'd2) ? 2'd0 : cph + 2'd1;
    wire        tick = (cph == 2'd2);                    // the 27 MHz tick
    wire        ce;                                      // sync_gen's dot (the tick on these fitted rasters)
`endif
    always #5.556 mclk = ~mclk;                          // 90 MHz

    // ---- the settings ----
    logic        il = 0, at = 0, pal = 0;
    logic [1:0]  std = 2'd0;
    logic [7:0]  w_mbs = 8'd45, hf_mbs = 8'd30;
    logic [40:0] crop = '0;
    logic [15:0] sarw = 16'd1, sarh = 16'd1;
    logic [1:0]  fmode = 2'd3;   // Fill with no display: the raster filled (main's Fit before issue #11)
    logic        vis = 1'b1, sess = 1'b0, at_en = 1'b0;
    int          refs = 3, iv;
    string       tfile, sfile, ostem, root;

    // ---- the raster ----
    wire  [11:0] h_pos, v_pos, sg_lines, sg_last;
    wire         pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
    sync_gen sg (.clk(clk),
`ifdef MAIN_RTL
                 .clk_en(ce),
`else
                 .clk_en(tick), .dot(ce),
`endif
                 .rst_n(rst_n), .interlaced(il), .std(std), .h_pos, .v_pos, .pixel_en,
                 .h_sync, .v_sync, .h_blank, .v_blank, .frame_tick, .field, .ce_pix,
                 .nat(1'b0), .g_w(12'd0), .g_h(12'd0), .g_l(12'd0), .g_nt(12'd0), .g_last(12'd0),
                 .lines(sg_lines), .last_line(sg_last));

    // ---- the picture: disp_fit + disp_reader on a store in a model ----
    wire [12:0] f_ow, f_oh; wire [13:0] f_ox0, f_oy0; wire [27:0] f_sx, f_sy; wire [1:0] f_dh, f_dv;
    wire [11:0] f_wc, f_hc, f_lx, f_ty; wire f_slide; wire [15:0] fetch_late;
    wire [2:0]  f_hpf, f_vpf;                     // (docs/analog.md §11b) the branch's pre-filters: Sharp here
    disp_fit fit (.clk(clk), .rst_n(rst_n), .w_mbs(w_mbs), .hf_mbs(hf_mbs), .crop(crop), .sar_w(sarw), .sar_h(sarh),
        .mode(fmode), .disp_w(12'd0), .disp_h(12'd0), .nat(1'b0), .nat_w(12'd0), .nat_h(12'd0), .il(il), .at(at), .pal(pal),
        .geometry_en(1'b0), .geometry_x(13'd0), .geometry_y(13'd0), .geometry_w(13'd0), .geometry_h(13'd0),
        .geometry_clip_en(1'b0), .geometry_clip_x(12'd0), .geometry_clip_y(12'd0), .geometry_clip_w(12'd0), .geometry_clip_h(12'd0),
        .ow(f_ow), .oh(f_oh), .ox0(f_ox0), .oy0(f_oy0), .sx(f_sx), .sy(f_sy), .dh_l2(f_dh), .dv_l2(f_dv),
        .wc(f_wc), .hc(f_hc), .lx(f_lx), .ty(f_ty), .crop_bad(), .snap(), .clamp(), .slide(f_slide), .lb(),
`ifndef MAIN_RTL
        .area(1'b0), .hpf(f_hpf), .vpf(f_vpf),     // the Sharp control: bit-identical to main (§11b)
`endif
        .busy());
    wire  [7:0]  pic_r, pic_g, pic_b; wire pic_de;
    wire [28:0]  r_address; wire [7:0] r_burstcount; wire r_read, r_waitrequest, r_readdatavalid; wire [63:0] r_readdata;
    disp_reader #(.DPB_BASE(BASE)) rdr (
        .clk(clk),
`ifndef MAIN_RTL
        .ce(ce),
`endif
        .rst_n(rst_n), .h_pos, .v_pos, .de_in(pixel_en), .il, .pal, .lines(sg_lines), .last_line(sg_last),
        .pic_valid(1'b1), .pic_store(5'd17), .pic_field(1'b0), .pic_w_mbs(w_mbs), .pic_hf_mbs(hf_mbs),
        .pic_parity(1'b0), .pic_single(1'b0), .deint_mode(2'd0),
`ifndef MAIN_RTL
        .pic_colour(3'd1),     // (0.16) BT.601 limited: the 0.15 conversion, so the pins must match main's
        .pic_siting(6'd0),     // (docs/chroma.md) type 0
`endif
        .fit_ow(f_ow), .fit_oh(f_oh), .fit_ox0(f_ox0), .fit_oy0(f_oy0), .fit_sx(f_sx), .fit_sy(f_sy),
        .fit_dh_l2(f_dh), .fit_dv_l2(f_dv), .fit_lx(f_lx), .fit_ty(f_ty), .fit_wc(f_wc), .fit_hc(f_hc),
`ifdef MAIN_RTL
        .fit_slide(f_slide),
`else
        .fit_hpf(f_hpf), .fit_vpf(f_vpf), .clip_enable(1'b0), .clip_x(12'd0), .clip_y(12'd0), .clip_w(12'd0), .clip_h(12'd0),
`endif
        .r(pic_r), .g(pic_g), .b(pic_b), .de_out(pic_de), .fetch_late(fetch_late),
        .mclk(mclk), .mrst_n(rst_n), .ddr_address(r_address), .ddr_burstcount(r_burstcount), .ddr_read(r_read),
        .ddr_waitrequest(r_waitrequest), .ddr_readdata(r_readdata), .ddr_readdatavalid(r_readdatavalid),
        .fetch_changes());
    int unw_r;
    ddr_model #(.BASE(BASE + {5'd16, 18'd0}), .AW(22)) ddr_r (.clk(mclk), .rst_n(rst_n), .address(r_address),
        .burstcount(r_burstcount), .read(r_read), .write(1'b0), .writedata(64'd0), .byteenable(8'hFF),
        .waitrequest(r_waitrequest), .readdata(r_readdata), .readdatavalid(r_readdatavalid), .unwritten_reads(unw_r));
    reg [63:0] store [0:262143];

    // ---- the overlay: ovl_plane on a canvas (an ovl_plane_tb fixture's memory and descriptor) ----
    wire  [7:0]  ovl_pr, ovl_pg, ovl_pb, ovl_pa;
    wire  [31:0] ovl_gen, ovl_lines; wire [1:0] ovl_state; wire ovl_at, ovl_clip; wire [3:0] ovl_err;
    wire  [7:0]  ovl_torn; wire [15:0] ovl_late;
    wire  [28:0] o_address; wire [7:0] o_burstcount; wire o_read, o_waitrequest, o_readdatavalid; wire [63:0] o_readdata;
    ovl_plane ovl (
        .clk(clk),
`ifndef MAIN_RTL
        .ce(ce),
`endif
        .rst_n(rst_n), .h_pos, .v_pos, .de_in(pixel_en), .il, .pal, .rast_w(12'd720),
`ifndef MAIN_RTL
        .rast_h(pal ? 12'd576 : 12'd480),
`endif
        .rast_lines(sg_lines),
        .rast_last(sg_last), .sess, .at_en, .pr(ovl_pr), .pg(ovl_pg), .pb(ovl_pb), .pa(ovl_pa),
        .ovl_gen, .ovl_state, .ovl_at, .ovl_clip, .ovl_err, .ovl_torn, .ovl_late, .ovl_lines,
        .mclk(mclk), .mrst_n(rst_n), .ddr_address(o_address), .ddr_burstcount(o_burstcount), .ddr_read(o_read),
        .ddr_waitrequest(o_waitrequest), .ddr_readdata(o_readdata), .ddr_readdatavalid(o_readdatavalid));
    wire  [28:0] om_address = (o_address >= CTRL_WORD) ? (FB_WORD + CB_WIN + (o_address - CTRL_WORD)) : o_address;
    int unw_o;
    ddr_model #(.BASE(FB_WORD), .AW(21)) ddr_o (.clk(mclk), .rst_n(rst_n), .address(om_address),
        .burstcount(o_burstcount), .read(o_read), .write(1'b0), .writedata(64'd0), .byteenable(8'hFF),
        .waitrequest(o_waitrequest), .readdata(o_readdata), .readdatavalid(o_readdatavalid), .unwritten_reads(unw_o));
    logic [31:0] stim [0:10 + 10 * 32 - 1];

    // ---- the idle screen ----
    wire  [7:0]  idle_r, idle_g, idle_b;
    wire  [11:0] idle_x = il ? {1'b0, h_pos[11:1]} : h_pos;
    idle_bars ib (.clk(clk),
`ifndef MAIN_RTL
        .ce(ce),
`endif
        .rst_n(rst_n), .h_pos(idle_x), .v_pos, .de_in(pixel_en), .frame_tick, .vis, .r(idle_r), .g(idle_g),
        .b(idle_b), .de_out());

    // ---- the output stage ----
    wire  [7:0]  vga_r, vga_g, vga_b;
    wire         vga_hs, vga_vs, vga_de, vga_ce, vga_f1, cs, cs_en;
`ifdef MAIN_RTL
    // main's h264/emu.sv (9475658), the output stage verbatim but for its sources' names
    reg [15:0] idle_rg_q1, idle_rg_q2, idle_rg_q3;
    reg  [7:0] idle_b_q1, idle_b_q2, idle_b_q3;
    always @(posedge clk) begin
        idle_rg_q1 <= {idle_r, idle_g}; idle_b_q1 <= idle_b;
        idle_rg_q2 <= idle_rg_q1;       idle_b_q2 <= idle_b_q1;
        idle_rg_q3 <= idle_rg_q2;       idle_b_q3 <= idle_b_q2;
    end
    reg [5:0] hs_dly, vs_dly, de_dly, ce_dly, f1_dly;
    always @(posedge clk) begin
        hs_dly <= {hs_dly[4:0], h_sync};
        vs_dly <= {vs_dly[4:0], v_sync};
        de_dly <= {de_dly[4:0], pixel_en};
        ce_dly <= {ce_dly[4:0], ce_pix};
        f1_dly <= {f1_dly[4:0], field};
    end
    reg [7:0] sel_r_q, sel_g_q, sel_b_q;
    reg [7:0] ovl_r_q, ovl_g_q, ovl_b_q, ovl_a_q;
    always @(posedge clk) begin
        sel_r_q  <= pic_de ? pic_r : de_dly[4] ? idle_rg_q3[15:8] : 8'd0;
        sel_g_q  <= pic_de ? pic_g : de_dly[4] ? idle_rg_q3[7:0]  : 8'd0;
        sel_b_q  <= pic_de ? pic_b : de_dly[4] ? idle_b_q3        : 8'd0;
        ovl_r_q  <= ovl_pr;
        ovl_g_q  <= ovl_pg;
        ovl_b_q  <= ovl_pb;
        ovl_a_q  <= ovl_pa;
    end
    wire [7:0] ob_r, ob_g, ob_b;
    ovl_blend ovl_blend_inst (.v_r(sel_r_q), .v_g(sel_g_q), .v_b(sel_b_q), .p_r(ovl_r_q), .p_g(ovl_g_q),
                              .p_b(ovl_b_q), .p_a(ovl_a_q), .r(ob_r), .g(ob_g), .b(ob_b));
    reg [7:0] vga_r_q, vga_g_q, vga_b_q;
    reg       vga_hs_q, vga_vs_q, vga_de_q, vga_ce_q, vga_f1_q;
    always @(posedge clk) begin
        vga_r_q  <= ob_r;
        vga_g_q  <= ob_g;
        vga_b_q  <= ob_b;
        vga_hs_q <= hs_dly[5];
        vga_vs_q <= vs_dly[5];
        vga_de_q <= de_dly[5];
        vga_ce_q <= ce_dly[5];
        vga_f1_q <= f1_dly[5];
    end
    assign {vga_r, vga_g, vga_b, vga_hs, vga_vs, vga_de, vga_ce, vga_f1} =
           {vga_r_q, vga_g_q, vga_b_q, vga_hs_q, vga_vs_q, vga_de_q, vga_ce_q, vga_f1_q};
    csync_smpte csync_smpte_inst (.clk(clk), .rst_n(rst_n), .mode(1'b0), .en(il), .prog(1'b0), .pal(pal),
                                  .h_sync(hs_dly[5]), .v_pos(v_pos), .cs(cs), .cs_en(cs_en));
`else
    vid_out vo (.clk(clk), .ce(ce), .rst_n(rst_n), .h_sync, .v_sync, .pixel_en, .ce_pix, .field, .v_pos,
                .il, .pal, .pic_r, .pic_g, .pic_b, .pic_de, .idle_r, .idle_g, .idle_b, .ovl_pr, .ovl_pg, .ovl_pb,
                .ovl_pa, .vga_r, .vga_g, .vga_b, .vga_hs, .vga_vs, .vga_de, .vga_ce, .vga_f1, .cs, .cs_en);
`endif

    // ---- the trace: one record a dot, from a VS rise at the pins ----
    // (an event AT THE PINS, not sync_gen's frame start: a stage added uniformly to the whole output
    // path -- every signal one dot later -- moves the trace's start with it and compares equal; a
    // stage added to the colour alone, or the sync alone, does not)
    logic ce_d = 1'b0;                                   // the clock after a dot's load
    always @(posedge clk) ce_d <= ce;
    int fd, n_ticks = 0, n_rec = 0;
    bit rec = 0, vs_q = 0;
    always @(posedge clk) if (rst_n && ce_d) begin
        vs_q <= vga_vs;
        if (vga_vs && !vs_q) begin                       // a refresh's VS at the pins (480i: each field's)
            n_ticks = n_ticks + 1;
            if (n_ticks == (il ? 3 : 2)) rec = 1;
            if (n_ticks == (il ? 3 + 2 * refs : 2 + refs)) begin
                $fclose(fd);
                if (fetch_late !== 16'd0 || ovl_late !== 16'd0)
                    begin $display("FAIL [late] fetch_late %0d ovl_late %0d: a late line makes the trace timing-dependent", fetch_late, ovl_late); $fatal(1); end
                if (ovl_state !== 2'd1) begin $display("FAIL [ovl] the overlay is not on (state %0d err %0d): the gate would compare no overlay", ovl_state, ovl_err); $fatal(1); end
                $display("vid_equiv_tb: %0d dots traced (%0d frames from the second)", n_rec, refs);
                $display("PASS: vid_equiv_tb");
                $finish;
            end
        end
        if (rec)
            begin $fwrite(fd, "%02h%02h%02h%02h\n", vga_r, vga_g, vga_b,
                          {1'b0, vga_hs, vga_vs, vga_de, vga_ce, vga_f1, cs, cs_en}); n_rec = n_rec + 1; end
    end

    initial begin
        if (!$value$plusargs("trace=%s", tfile)) begin $display("FAIL: no +trace"); $fatal(1); end
        if (!$value$plusargs("root=%s", root)) root = ".";
        if ($value$plusargs("refs=%d", iv)) refs = iv;
        il = $test$plusargs("il"); at = $test$plusargs("at"); pal = $test$plusargs("pal");
        if ($value$plusargs("std=%d", iv)) std = iv[1:0];
        if ($value$plusargs("w=%d", iv)) w_mbs = iv[7:0];
        if ($value$plusargs("hf=%d", iv)) hf_mbs = iv[7:0];
        crop[40] = $test$plusargs("cuy4");
        if ($value$plusargs("cl=%d", iv)) crop[39:30] = iv[9:0];
        if ($value$plusargs("cr=%d", iv)) crop[29:20] = iv[9:0];
        if ($value$plusargs("ct=%d", iv)) crop[19:10] = iv[9:0];
        if ($value$plusargs("cb=%d", iv)) crop[9:0]   = iv[9:0];
        if ($value$plusargs("sarw=%d", iv)) sarw = iv[15:0];
        if ($value$plusargs("sarh=%d", iv)) sarh = iv[15:0];
        if ($value$plusargs("fmode=%d", iv)) fmode = iv[1:0];
        if ($value$plusargs("vis=%d", iv)) vis = iv[0];
        if (!$value$plusargs("store=%s", sfile)) begin $display("FAIL: no +store"); $fatal(1); end
        if (!$value$plusargs("ovl=%s", ostem)) begin $display("FAIL: no +ovl"); $fatal(1); end
        $readmemh({root, "/", sfile}, store);
        for (int i = 0; i < w_mbs * hf_mbs * 48; i++) ddr_r.poke(BASE + {5'd17, 18'd0} + i, store[i]);
        $readmemh({root, "/bench/h264/fixtures/gen/ovl_", ostem, ".stim.hex"}, stim);
        $readmemh({root, "/bench/h264/fixtures/gen/ovl_", ostem, ".mem.hex"}, ddr_o.mem);
        for (int i = 0; i < (1 << 21); i++) ddr_o.wrt[i] = 1'b1;
        for (int i = 0; i < 8; i++) ddr_o.poke(CTRL_WORD + 29'd72 + 29'(i) - CTRL_WORD + FB_WORD + CB_WIN, {32'd0, stim[10 + i]});
        sess = 1'b1; at_en = stim[19][0];
        fd = $fopen(tfile, "w");
        repeat (20) @(posedge clk);
        rst_n = 1;
    end
    initial begin
        #2_000_000_000;
        $display("FAIL: timeout (%0d frame starts)", n_ticks); $fatal(1);
    end
endmodule

`default_nettype wire
