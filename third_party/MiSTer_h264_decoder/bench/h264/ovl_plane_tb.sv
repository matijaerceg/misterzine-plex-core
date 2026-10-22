// bench/h264/ovl_plane_tb.sv -- the overlay plane (Phase 6b, interface 0.9): h264/ovl_plane.sv
// on the real raster (h264/sync_gen.sv), behind h264/ddr_mux2.sv beside a random master A (the
// display reader's place on ram2), into bench/h264/ddr_model.sv; h264/ovl_blend.sv on every dot.
// The expectations come from tools/ovl_ref.py (written from docs/architecture.md, not the RTL).
//
// The window: ddr_model holds 2 M words from the framebuffer's region (word FB_BYTE / 8); the
// control block's words 72-79 are translated into it at window word 0x100000 + 72 (the region
// and the block are 32 M words apart in DDR3). Each refresh begins (frame_tick) with the
// program's move for it: the descriptor written into words 72-79 (a backdoor store, between
// reads), `sess` and `at_en` set.
//
// Arms, each scored on every refresh:
//   [pix]    every active dot's premultiplied {r, g, b, a} at LAT 9 (5 before hd_raster) == the model's, the frame
//            line the field shows (480i: each pixel's two dots) -- with +late (the port starved)
//            each line is either the model's or wholly transparent (a late line), never a mix
//   [blend]  every dot: ovl_blend(V, P) == min(255, P + round(V (255 - a) / 255)), V a pattern
//            of the dot's position, the rounding done here in plain integers
//   [status] at the vertical blank: ovl_lines (the canvas lines fetched: each once a field) at
//            its first line; gen / state / err / torn / at / clip after the read (8 lines on);
//            ovl_late 0 (+late: > 0, and at least the lines seen dropped)
//   [live]   at least one dot with alpha scored, when the model has any (never vacuous)
// Plusargs: +arm=<name> (the fixture stem), +late, the model's +wait_pct / +lat_min / +lat_max,
// +a_pct=N (master A's activity, default 30).

`timescale 1ns/1ps
`default_nettype none

module ovl_plane_tb;
    localparam logic [28:0] FB_WORD   = 29'h0440_0000;   // FB_BYTE / 8
    localparam logic [28:0] CTRL_WORD = 29'h0628_0000;   // CTRL_BYTE / 8
    localparam logic [28:0] CB_WIN    = 29'h0010_0000;   // the control block inside the window

    logic clk = 0, mclk = 0, rst_n = 0;
    always #6.173 clk = ~clk;                            // clk_vid 81 MHz (hd_raster): the dot is `ce`
    logic [1:0] cph = 2'd0;                              // one clock in three (27 MHz); +ce1 every clock
    logic       ce1 = 1'b0;
    always @(posedge clk) cph <= (cph == 2'd2) ? 2'd0 : cph + 2'd1;
    wire        tick = ce1 | (cph == 2'd2);
    wire        ce;                                      // sync_gen's dot (every clock native: hd_raster stage B)
    always #5.555  mclk = ~mclk;                          // 90 MHz

    string arm;
    bit    late_arm;
    int    a_pct = 30;

    // ---- the fixtures ----
    logic [31:0] stim [0:10 + 10 * 32 - 1];             // (0.10) the header: + the raster (nat, w, h, l, nt, last)
    logic [31:0] stat [0:5 * 32 - 1];
    localparam int MAXE = 14 * 480 * 720;                // the largest fixture (desc: 13 refreshes at 480p)
    logic [31:0] expv [0:MAXE - 1];                      // refreshes x lines x the raster's width
    int n_ref, il_i, pal_i, flags;
    int lines, rwid;
    logic        g_nat;                                  // (0.10) the native raster the fixture runs on
    logic [11:0] g_w, g_h, g_l, g_nt, g_last;

    // ---- the raster ----
    logic        il, pal;
    wire  [11:0] h_pos, v_pos;
    wire         pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
    wire  [11:0] sg_lines, sg_last;
    sync_gen u_sync (
        .clk(clk), .clk_en(tick), .dot(ce), .rst_n(rst_n), .interlaced(il), .std(pal ? 2'd2 : 2'd0),
        .h_pos, .v_pos, .pixel_en, .h_sync, .v_sync, .h_blank, .v_blank, .frame_tick, .field, .ce_pix,
        .nat(g_nat), .g_w(g_w), .g_h(g_h), .g_l(g_l), .g_nt(g_nt), .g_last(g_last), .lines(sg_lines), .last_line(sg_last));

    // ---- the plane ----
    logic        sess = 0, at_en = 0;
    wire  [7:0]  pr, pg, pb, pa;
    wire  [31:0] ovl_gen, ovl_lines;
    wire  [1:0]  ovl_state;
    wire         ovl_at, ovl_clip;
    wire  [3:0]  ovl_err;
    wire  [7:0]  ovl_torn;
    wire  [15:0] ovl_late;
    logic [28:0] b_address;  logic [7:0] b_burstcount;  logic b_read, b_waitrequest, b_readdatavalid;
    logic [63:0] b_readdata;
    ovl_plane dut (
        .clk(clk), .ce(ce), .rst_n(rst_n), .h_pos, .v_pos, .de_in(pixel_en), .il, .pal,
        .rast_w(g_nat ? g_w : 12'd720), .rast_h(g_nat ? g_h : (pal ? 12'd576 : 12'd480)), .rast_lines(sg_lines), .rast_last(sg_last), .sess, .at_en,
        .pr, .pg, .pb, .pa, .ovl_gen, .ovl_state, .ovl_at, .ovl_clip, .ovl_err, .ovl_torn, .ovl_late, .ovl_lines,
        .mclk(mclk), .mrst_n(rst_n), .ddr_address(b_address), .ddr_burstcount(b_burstcount), .ddr_read(b_read),
        .ddr_waitrequest(b_waitrequest), .ddr_readdata(b_readdata), .ddr_readdatavalid(b_readdatavalid));

    // ---- ram2: master A (random reads, the display reader's place) + the plane -> ddr_model ----
    logic [28:0] a_address = FB_WORD + CB_WIN + 29'd1024;  logic [7:0] a_burstcount = 8'd1;
    logic a_read = 0, a_waitrequest, a_readdatavalid;
    logic [63:0] a_readdata;
    logic [28:0] ddr_address;  logic [7:0] ddr_burstcount, ddr_byteenable;  logic ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
    logic [63:0] ddr_writedata, ddr_readdata;
    int unwritten;
    ddr_mux2 u_mux (
        .clk(mclk), .rst_n(rst_n),
        .a_address, .a_burstcount, .a_read, .a_write(1'b0), .a_writedata(64'd0), .a_byteenable(8'hFF), .a_abort(1'b0),
        .a_waitrequest, .a_readdata, .a_readdatavalid,
        .b_address, .b_burstcount, .b_read, .b_write(1'b0), .b_writedata(64'd0), .b_waitrequest, .b_readdata, .b_readdatavalid,
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid);
    // the control block, translated into the window
    wire  [28:0] m_address = (ddr_address >= CTRL_WORD) ? (FB_WORD + CB_WIN + (ddr_address - CTRL_WORD)) : ddr_address;
    ddr_model #(.BASE(FB_WORD), .AW(21)) ddr (
        .clk(mclk), .rst_n(rst_n), .address(m_address), .burstcount(ddr_burstcount), .read(ddr_read), .write(ddr_write),
        .writedata(ddr_writedata), .byteenable(ddr_byteenable), .waitrequest(ddr_waitrequest),
        .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));
    int a_owed = 0;
    always @(posedge mclk) begin
        if (!rst_n) begin a_read <= 0; a_owed = 0; end
        else begin
            if (a_readdatavalid) a_owed = a_owed - 1;
            if (a_read && !a_waitrequest) begin
                a_read <= 0; a_owed = a_owed + a_burstcount;
            end else if (!a_read && a_owed == 0 && $urandom_range(0, 99) < a_pct) begin
                a_address <= FB_WORD + CB_WIN + 29'd1024 + 29'($urandom_range(0, 1000));
                a_burstcount <= 8'($urandom_range(1, 8)); a_read <= 1;
            end
        end
    end
    // [avalon] at master B itself (ddr_model polices the port; a withdrawal B makes behind the mux
    // would be re-presented by nobody)
    logic bp_v = 0; logic [28:0] bp_a; logic [7:0] bp_bc;
    always @(posedge mclk) begin
        if (bp_v && (!b_read || b_address !== bp_a || b_burstcount !== bp_bc)) begin
            $display("FAIL [avalon] the plane %0s its request under waitrequest", b_read ? "changed" : "withdrew");
            $fatal(1);
        end
        bp_v <= b_read && b_waitrequest; bp_a <= b_address; bp_bc <= b_burstcount;
    end

    // ---- the composite: V a pattern of the dot's position ----
    logic [11:0] hd [1:9], vd [1:9];   // (hd_raster) LAT 9
    logic [9:1]  ded;
    int          rd [1:9];
    int          refresh = -1;
    always @(posedge clk) if (ce) begin
        hd[1] <= h_pos; vd[1] <= v_pos; ded[1] <= pixel_en; rd[1] <= ((frame_tick && (!g_nat || sg_lines == g_h)) ? refresh + 1 : refresh);
        for (int i = 2; i <= 9; i++) begin hd[i] <= hd[i - 1]; vd[i] <= vd[i - 1]; ded[i] <= ded[i - 1]; rd[i] <= rd[i - 1]; end
    end
    wire  [10:0] ox = il ? {1'b0, hd[9][10:1]} : hd[9][10:0];   // (hd_raster) 11 bits: up to 2,048
    wire  [11:0] oL = vd[9];
    wire  [7:0]  v_r = ox[7:0] ^ oL[7:0], v_g = ox[7:0] + {oL[6:0], 1'b0}, v_b = {ox[6:0], 1'b0} + ox[7:0] ^ oL[7:0];
    wire  [7:0]  o_r, o_g, o_b;
    ovl_blend u_blend (.clk(1'b0), .ce(1'b0), .v_r, .v_g, .v_b, .p_r(pr), .p_g(pg), .p_b(pb), .p_a(pa), .r(o_r), .g(o_g), .b(o_b));

    function automatic int want_c(input int p, input int v, input int a);
        int s;
        s = p + (2 * v * (255 - a) + 255) / 510;
        return s > 255 ? 255 : s;
    endfunction

    // ---- scoring ----
    int n_dots = 0, n_alpha = 0, n_blend = 0, n_lines_ok = 0, n_dropped = 0, exp_alpha = 0;
    bit line_exp, line_zero, line_any;
    int line_L = -1, line_r = -1;
    task automatic end_line;
        if (line_any) begin
            if (line_exp) n_lines_ok++;
            else if (late_arm && line_zero) n_dropped++;
            else begin
                $display("FAIL [pix] refresh %0d line %0d: neither the model's nor transparent", line_r, line_L); $fatal(1);
            end
        end
        line_any = 0; line_exp = 1; line_zero = 1;
    endtask
    always @(posedge clk) if (ce) begin
        if (rst_n && ded[9] && rd[9] >= 0 && rd[9] < n_ref) begin
            logic [31:0] e, got;
            int ix;
            if (oL != line_L || rd[9] != line_r) begin end_line(); line_L = oL; line_r = rd[9]; end
            ix = (rd[9] * lines + oL) * rwid + ox;
            e = expv[ix];
            got = {pr, pg, pb, pa};
            line_any = 1;
            if (got !== e) begin
                line_exp = 0;
                if (!late_arm) begin
                    $display("FAIL [pix] refresh %0d line %0d x %0d: got %h, the model %h", rd[9], oL, ox, got, e); $fatal(1);
                end
            end
            if (got !== 32'd0) line_zero = 0;
            n_dots++;
            if (e[7:0] != 0) exp_alpha++;
            if (got[7:0] != 0 && got === e) n_alpha++;
            // [blend]
            if (o_r !== 8'(want_c(pr, v_r, pa)) || o_g !== 8'(want_c(pg, v_g, pa)) || o_b !== 8'(want_c(pb, v_b, pa))) begin
                $display("FAIL [blend] V %h %h %h P %h %h %h %h: got %h %h %h, want %h %h %h", v_r, v_g, v_b, pr, pg, pb, pa,
                         o_r, o_g, o_b, 8'(want_c(pr, v_r, pa)), 8'(want_c(pg, v_g, pa)), 8'(want_c(pb, v_b, pa)));
                $fatal(1);
            end
            n_blend++;
        end
    end

    // ---- the program's moves, and the status at each vertical blank ----
    wire vb_first = il ? (v_pos[11:1] == (pal ? 11'd288 : 11'd240)) : (v_pos == 12'(lines));
    wire vb_stat  = il ? (v_pos[11:1] == (pal ? 11'd296 : 11'd248)) : (v_pos == 12'(lines + 8));
    int p0 = -1;                                          // refresh 0's first line parity
    int late_seen = 0;
    always @(posedge clk) if (ce) begin
        // (a native fixture: sync_gen scans one fitted frame after reset and takes the native geometry
        // at its end -- the refreshes count from the first frame on the fixture's raster)
        if (rst_n && frame_tick && (!g_nat || sg_lines == g_h)) begin
            refresh = refresh + 1;
            if (refresh == 0) p0 = v_pos[0];
            if (refresh < n_ref) begin
                for (int i = 0; i < 8; i++) ddr.poke(CTRL_WORD + 29'd72 + 29'(i) - CTRL_WORD + FB_WORD + CB_WIN, {32'd0, stim[10 + 10 * refresh + i]});
                sess <= stim[10 + 10 * refresh + 8][0];
                at_en <= stim[10 + 10 * refresh + 9][0];
            end
        end
        if (rst_n && refresh >= 0 && refresh < n_ref && h_pos == 12'd0) begin
            if (vb_first) begin
                // (+late: lines the starved engine could not take are never commanded -- at most the model's)
                if (late_arm ? (ovl_lines > stat[5 * refresh + 3 + p0]) : (ovl_lines !== stat[5 * refresh + 3 + p0])) begin
                    $display("FAIL [status] refresh %0d: ovl_lines %0d, the model %0d (each canvas line once a field)",
                             refresh, ovl_lines, stat[5 * refresh + 3 + p0]); $fatal(1);
                end
            end
            if (vb_stat) begin
                logic [31:0] sf;
                sf = stat[5 * refresh + 1];
                if (ovl_gen !== stat[5 * refresh] || ovl_state !== sf[1:0] || ovl_err !== sf[5:2] ||
                    ovl_at !== sf[6] || ovl_clip !== sf[7] || ovl_torn !== stat[5 * refresh + 2][7:0]) begin
                    $display("FAIL [status] refresh %0d: gen %h state %0d err %0d at %0d clip %0d torn %0d; the model gen %h state %0d err %0d at %0d clip %0d torn %0d",
                             refresh, ovl_gen, ovl_state, ovl_err, ovl_at, ovl_clip, ovl_torn,
                             stat[5 * refresh], sf[1:0], sf[5:2], sf[6], sf[7], stat[5 * refresh + 2]); $fatal(1);
                end
                if (!late_arm && ovl_late !== 16'd0) begin
                    $display("FAIL [status] refresh %0d: %0d lines late", refresh, ovl_late); $fatal(1);
                end
            end
        end
    end

    initial begin
        if (!$value$plusargs("arm=%s", arm)) begin $display("FAIL: no +arm"); $fatal(1); end
        late_arm = $test$plusargs("late");
        ce1 = $test$plusargs("ce1");
        if (!$value$plusargs("a_pct=%d", a_pct)) a_pct = 30;
        $readmemh({"bench/h264/fixtures/gen/ovl_", arm, ".stim.hex"}, stim);
        $readmemh({"bench/h264/fixtures/gen/ovl_", arm, ".stat.hex"}, stat);
        n_ref = stim[0]; il_i = stim[1]; pal_i = stim[2]; flags = stim[3];
        if (late_arm != flags[0]) begin $display("FAIL: +late and the fixture's flag disagree"); $fatal(1); end
        il = il_i[0]; pal = pal_i[0];
        g_nat = stim[4][0]; g_w = stim[5][11:0]; g_h = stim[6][11:0]; g_l = stim[7][11:0]; g_nt = stim[8][11:0]; g_last = stim[9][11:0];
        lines = g_nat ? int'(g_h) : (pal ? 576 : 480);
        rwid = g_nat ? int'(g_w) : 720;
        if (n_ref * lines * rwid > MAXE) begin $display("FAIL: the fixture is larger than MAXE"); $fatal(1); end
        $readmemh({"bench/h264/fixtures/gen/ovl_", arm, ".exp.hex"}, expv);
        $readmemh({"bench/h264/fixtures/gen/ovl_", arm, ".mem.hex"}, ddr.mem);
        // every word counts as written: a word the model never wrote stays X, so a pixel shown
        // from memory the program did not draw fails [pix] (!==) instead of reading as 0
        for (int i = 0; i < (1 << 21); i++) ddr.wrt[i] = 1'b1;
        line_any = 0; line_exp = 1; line_zero = 1;
        repeat (20) @(posedge clk);
        rst_n = 1;
        wait (refresh == n_ref);
        end_line();
        if (exp_alpha > 0 && n_alpha == 0) begin $display("FAIL [live] no overlay pixel seen"); $fatal(1); end
        if (late_arm) begin
            if (n_dropped == 0 || ovl_late == 0) begin
                $display("FAIL [status] +late: no line dropped (%0d) or none counted (%0d): the arm starved nothing", n_dropped, ovl_late);
                $fatal(1);
            end
            if (n_dropped > ovl_late) begin
                $display("FAIL [status] +late: %0d lines dropped, %0d counted", n_dropped, ovl_late); $fatal(1);
            end
        end
        $display("ovl_plane_tb %s: %0d dots (%0d with alpha, %0d model), %0d blends, %0d lines exact, %0d dropped, late %0d, lines fetched %0d, torn %0d",
                 arm, n_dots, n_alpha, exp_alpha, n_blend, n_lines_ok, n_dropped, ovl_late, ovl_lines, ovl_torn);
        $display("PASS: ovl_plane_tb %s", arm);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: timeout (refresh %0d of %0d)", refresh, n_ref); $fatal(1);
    end
endmodule

`default_nettype wire
