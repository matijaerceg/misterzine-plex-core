// bench/h264/ring_in_tb.sv -- the HPS interface's input region (interface 0.6: h264/ring_in.sv,
// h264/ring_stat.sv's second job, ring_rd.sv's 7-bit status index, the generated
// ring_words_in.sv) end to end: a stand-in for Main drives hps_io's input ports the way
// hps_io drives them (a toggle per key event and per mouse packet, the pads' words, OSD_STATUS),
// the status path writes the region into bench/h264/ddr_model.sv through ddr_mux2 (beside a
// random master A), and a stand-in for the program reads it back as docs/architecture.md
// "Input (interface 0.6)" says a program must: in_tail, the words, in_head (spread over time,
// so a write can overlap the copy), the events from its own count, the sums' differences.
// The expected events are built by the stand-in for Main from the architecture's event format
// (not from the RTL): a key -> {0, pressed, extended, code}; a mouse packet whose buttons differ
// from the previous packet's -> {1, the buttons}; an OSD edge -> {2, open}; (0.8) an OSD action
// (Main sets status[17 + n], then clears it a bus transaction later) -> {3, n}, and two
// actions rising together -> action 0 first.
//
//   +arm=In   the scenario (below)
//   I1 mixed     keys, mouse packets (buttons, wheel), OSD edges, (0.8) actions -- one chosen
//                while the OSD is open followed by its closing, as Main does -- pad and stick
//                changes at Main's pace; a fast reader; then pad changes alone. Every check.
//   I2 collide   chords of 2-6 key events at the bus's fastest pace, one started just before
//                each frame pulse (the region's write then spans the frame: the frame must be
//                kept pending, not lost) and others timed into the writes (the freeze); (0.8)
//                into the writes too: an action then an OSD edge a few cycles apart (both
//                pending at once: the action first), and both actions rising together.
//   I3 flood     key events every 3 cycles for a while, then (0.8) keys and action pulses
//                interleaved: faster than the freeze can hold, so events are lost IN THE CORE --
//                counted: ev_count + ev_lost = events sent.
//   I4 slow      events faster than a queue a write period, the reader just after each write:
//                it must see exactly how many it lost, and every event it does get correct.
//   I5 idle      no input: the region is written once a frame (the heartbeat), no more; then
//                one lone action just after a frame (written by its own change, not the next frame).
//
// Checks (each FAIL names its arm): [events] an event read differs from the one sent, or out
// of order; [lost] a loss the reader counted that did not happen / did not count one that did
// (I4), or the core's ev_lost / conservation wrong (I3); [mouse] a sum, the buttons or the OSD
// level differs at the end; [pads] a pad word not in DDR3 within the write period; [latency]
// an event not in DDR3 within the write period; [rate] two writes of the region closer than
// the minimum gap, or more than one a frame while idle; [heartbeat] in_head still while idle;
// [frames] a raster frame's status write skipped or lost; [seqlock] no consistent copy, or
// in_head / in_tail disagree in one; [coverage] (I2) an action and an OSD edge never pending
// together, or the two actions never; [hang]. Scoring with !== (X never passes).
// PASS: ring_in_tb is printed only when every check held.

`timescale 1ns/1ps
`default_nettype none

module ring_in_tb;
`include "h264/ring_iface.svh"

    localparam logic [28:0] CTRL = 29'h0628_0000;
    localparam logic [28:0] RINGW = CTRL + 29'd512;
    localparam int MIN_GAP = 2000;                      // clk_sys cycles between the region's writes (27,000 in the core)
    localparam int FRAME_T = 9000;                      // a "raster frame": 4.5 write periods (16.7 ms / 1 ms ~ 17 in the core)
    localparam int SLACK   = 600;                       // the status path's own delay (a frame job ahead, the engine, ram1)

    // ---- clocks: clk_sys 27, clk_mem 90, clk_dec 81 MHz ----
    logic clk = 0, mclk = 0, dclk = 0;
    always #18.5 clk = ~clk;
    always #5.55 mclk = ~mclk;
    always #6.15 dclk = ~dclk;
    logic lock_n = 1'b0;

    string arm;
    int fails = 0;
    task automatic fail(input string label, input string msg);
        $display("FAIL [%s] %s: %s", label, arm, msg);
        fails++;
        if (fails > 8) $fatal(1);
    endtask

    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    task automatic gap_bus();                            // one event is a bus transaction: >= ~2 us
        repeat ($urandom_range(54, 120)) @(posedge clk);
    endtask

    // ---- the stand-in for Main (hps_io's outputs) ----
    logic [191:0] joy = '0;  logic [95:0] ana_l = '0, ana_r = '0;
    logic [10:0]  ps2_key = '0;  logic [24:0] ps2_mouse = '0;  logic [15:0] ps2_mouse_ext = '0;
    logic         osd = 1'b0;
    logic [1:0]   act = 2'b00;                          // (0.8) status[18:17]
    logic [15:0]  truth [0:65535];                      // the events, in the order sent
    longint       t_sent [0:65535];
    int           n_sent = 0;
    logic [31:0]  dx_t = 0, dy_t = 0, wh_t = 0;         // the sums the region must end with
    logic [7:0]   btn_t = 0;
    longint       pad_t [0:5];                          // when each pad last changed
    longint       mouse_t = -1;                         // when the mouse last moved
    initial for (int n = 0; n < 6; n++) pad_t[n] = -1;

    task automatic key(input logic [7:0] code, input logic pressed, input logic ext);
        @(posedge clk);
        ps2_key <= {~ps2_key[10], pressed, ext, code};
        truth[n_sent] = {RV_KEY, 4'd0, pressed, ext, code}; t_sent[n_sent] = cyc; n_sent++;
    endtask
    task automatic mouse(input int dx, input int dy, input int wheel, input logic [7:0] b);
        logic [8:0] x9, y9;  logic [7:0] w8;
        x9 = 9'(dx); y9 = 9'(dy); w8 = 8'(wheel);
        @(posedge clk);
        // byte 0 {Yovf, Xovf, Ysign, Xsign, 1, M, R, L}; ext {3'b0, buttons 4-8, the wheel}
        ps2_mouse <= {~ps2_mouse[24], y9[7:0], x9[7:0], 2'b00, y9[8], x9[8], 1'b1, b[2:0]};
        ps2_mouse_ext <= {3'd0, b[7:3], w8};
        dx_t = dx_t + 32'(dx); dy_t = dy_t + 32'(dy); wh_t = wh_t + 32'(wheel); mouse_t = cyc + 1;
        if (b != btn_t) begin
            truth[n_sent] = {RV_MOUSE_BTN, 6'd0, b}; t_sent[n_sent] = cyc; n_sent++;
            btn_t = b;
        end
    endtask
    task automatic osd_set(input logic open);
        @(posedge clk);
        osd <= open;
        truth[n_sent] = {RV_OSD, 13'd0, open}; t_sent[n_sent] = cyc; n_sent++;
    endtask
    // (0.8) an OSD action: Main sets the bit, then clears it (two SPI transactions)
    task automatic action(input int n);
        @(posedge clk);
        act[n] <= 1'b1;
        truth[n_sent] = {RV_ACTION, 13'd0, 1'(n)}; t_sent[n_sent] = cyc; n_sent++;
        gap_bus();
        act[n] <= 1'b0;
    endtask
    task automatic action_pulse(input logic [1:0] m, input int hold);   // no gap: I2 / I3
        @(posedge clk);
        act <= m;
        if (m[0]) begin truth[n_sent] = {RV_ACTION, 14'd0}; t_sent[n_sent] = cyc; n_sent++; end
        if (m[1]) begin truth[n_sent] = {RV_ACTION, 14'd1}; t_sent[n_sent] = cyc; n_sent++; end
        repeat (hold) @(posedge clk);
        act <= 2'b00;
    endtask
    task automatic pad(input int n);
        @(posedge clk);
        joy[32 * n +: 32] <= {$urandom} & 32'h0000_FFFF;
        ana_l[16 * n +: 16] <= 16'($urandom);
        ana_r[16 * n +: 16] <= 16'($urandom);
        pad_t[n] = cyc + 1;
    endtask

    // ---- the DUT: ring_in -> ring_stat -> ring_rd's engine -> ram1 ----
    logic frame = 1'b0;
    int   fcnt = 1, n_frames = 0;
    always @(posedge clk) if (lock_n) begin
        fcnt <= (fcnt == FRAME_T - 1) ? 0 : fcnt + 1;
        frame <= (fcnt == 0);
        if (fcnt == 0) n_frames <= n_frames + 1;
    end

    logic        in_req, in_go, in_busy;  logic [4:0] in_ix;  logic [63:0] in_word;  logic [31:0] n_events;
    ring_in #(.MIN_GAP(MIN_GAP)) u_in (
        .clk, .rst_n(lock_n), .frame, .joy, .ana_l, .ana_r, .ps2_key, .ps2_mouse, .ps2_mouse_ext, .osd, .act,
        .in_req, .in_go, .in_busy, .in_ix, .in_word, .n_events);

    logic [31:0] seq, n_skips;
    logic [6:0]  sys_ix;                 // 0.10: 7 bits
    logic [5:0]  mem_ix, dec_ix;
    logic [63:0] st_word;  logic [6:0] st_ix, st_free;  logic st_wr, st_grp;
    ring_stat u_stat (
        .clk, .rst_n(lock_n), .frame, .st_free, .seq, .n_skips,
        .sys_ix, .sys_word({57'd0, sys_ix}), .mclk, .mrst_n(lock_n), .mem_ix, .mem_word({58'd0, mem_ix}),
        .dclk, .drst_n(lock_n), .dec_ix, .dec_word({58'd0, dec_ix}),
        .in_req, .in_go, .in_busy, .in_ix, .in_word,
        .st_word, .st_ix, .st_wr, .st_grp);

    logic [28:0] b_address;  logic [7:0] b_burstcount;  logic b_read, b_write, b_waitrequest, b_readdatavalid;
    logic [63:0] b_writedata, b_readdata;
    ring_rd #(.CTRL_WORD(CTRL), .RING_WORD(RINGW), .RING_AW(9), .POLL_FAST(200), .POLL_SLOW(3000),
              .CLR_HOLD(16), .SETTLE(32), .END_WAIT(20000)) u_rd (
        .clk, .rst_n(lock_n), .lrst_n(lock_n),
        .es_byte(), .es_mark(), .es_pts(), .es_au_end(), .es_valid(), .es_ready(1'b1),
        .stream_clr(), .eos(), .ll_mode(), .gfx_mode(), .vid_seen(), .disp_ended(1'b0),
        .ad_push(), .ad_pos(), .ad_len(), .ad_pts(), .ad_ptsv(), .ad_room(1'b1), .a_hold_v(1'b0), .a_hold_idx(32'd0),
        .aud_idle(1'b1), .hold_bytes(),
        .af_go(1'b0), .af_addr(32'd0), .af_n(4'd0), .af_busy(), .af_dout(), .af_valid(), .af_empty(), .af_rd(1'b0),
        .ctl_pause(), .ctl_err(), .ctl_atten(), .rumble(), .rum_changes(),
        .st_word, .st_ix, .st_wr, .st_grp, .st_free,
        .sess(), .state(), .err(), .err_pos(), .err_word(), .eos_seen(),
        .n_au(), .n_audio(), .n_pad(), .n_streams(), .es_bytes(), .ll_mismatch(), .gfx_mismatch(),
        // 0.15: no PICTURE records here: the hand-over tied off
        .pd_req(), .pd_store(), .pd_w(), .pd_hf(), .pd_struct(), .pd_ps(), .pd_ps_v(), .pd_aspect(), .pd_timing_v(),
        .pd_nuit(), .pd_ts(), .pd_crop(), .pd_pts(), .pd_pts_v(), .pd_eos(), .pd_ack(1'b0), .pd_busy(1'b0), .pic_mode(),
        .mclk, .mrst_n(lock_n),
        .b_address, .b_burstcount, .b_read, .b_write, .b_writedata, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .read_index(), .ack_nonce(), .n_polls(), .n_bursts(), .eng_err(), .eng_session(), .eng_widx(),
        .set_word(), .set_tog());

    logic [28:0] a_address;  logic [7:0] a_burstcount;  logic a_read = 0, a_write = 0, a_waitrequest, a_readdatavalid;
    logic [63:0] a_writedata, a_readdata;
    logic [28:0] ddr_address;  logic [7:0] ddr_burstcount, ddr_byteenable;  logic ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
    logic [63:0] ddr_writedata, ddr_readdata;
    int unwritten;
    ddr_mux2 u_mux (
        .clk(mclk), .rst_n(lock_n),
        .a_address, .a_burstcount, .a_read, .a_write, .a_writedata, .a_byteenable(8'hFF), .a_abort(1'b0),
        .a_waitrequest, .a_readdata, .a_readdatavalid,
        .b_address, .b_burstcount, .b_read, .b_write, .b_writedata, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid);
    ddr_model #(.BASE(CTRL), .AW(11)) ddr (
        .clk(mclk), .rst_n(1'b1), .address(ddr_address), .burstcount(ddr_burstcount), .read(ddr_read), .write(ddr_write),
        .writedata(ddr_writedata), .byteenable(ddr_byteenable), .waitrequest(ddr_waitrequest),
        .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));
    // master A: random bursts in its own region (ram1 is shared)
    int a_owed = 0, a_beats = 0;
    always @(posedge mclk) begin
        if (!lock_n) begin a_read <= 0; a_write <= 0; a_owed = 0; a_beats = 0; end
        else begin
            if (a_readdatavalid) a_owed = a_owed - 1;
            if (a_read && !a_waitrequest) begin a_read <= 0; a_owed = a_owed + a_burstcount; end
            else if (a_write && !a_waitrequest) begin
                a_beats = a_beats - 1;
                if (a_beats == 0) a_write <= 0; else a_writedata <= {$urandom, $urandom};
            end else if (!a_read && !a_write && a_owed == 0 && $urandom_range(0, 99) < 30) begin
                a_address <= CTRL + 29'd1024 + 29'($urandom_range(0, 1000));
                if ($urandom_range(0, 1)) begin a_burstcount <= 8'($urandom_range(1, 8)); a_read <= 1; end
                else begin a_beats = $urandom_range(1, 8); a_burstcount <= 8'(a_beats); a_write <= 1; a_writedata <= {$urandom, $urandom}; end
            end
        end
    end

    function automatic logic [63:0] cw(input int w);
        return ddr.peek(CTRL + 29'(w));
    endfunction

    // ---- watchers on DDR3 (every clk_sys cycle) ----
    logic [31:0] seen_head = 0, seen_evc = 0;
    longint      t_head = -1;
    int          n_writes = 0, win_writes = 0;
    bit          idle_win = 0;
    logic [63:0] w48, w64;
    always @(posedge clk) if (lock_n) begin
        w48 = cw(48); w64 = cw(64);
        if (w48[31:0] !== seen_head && w48 !== 64'hX) begin
            // [rate]: the region's writes, where they land
            if (t_head >= 0 && cyc - t_head < MIN_GAP - SLACK)
                fail("rate", $sformatf("in_head %0d -> %0d after %0d cycles (minimum gap %0d)", seen_head, w48[31:0], cyc - t_head, MIN_GAP));
            t_head = cyc; seen_head = w48[31:0]; n_writes++;
            if (idle_win) win_writes++;
        end
        // [latency]: every event in DDR3 within the gap (+ the path's delay) of being sent
        if (w48[63:32] !== 32'hX && w48[63:32] != seen_evc) begin
            if (arm != "I3")
                for (int i = seen_evc; i < w48[63:32] && i < n_sent; i++)
                    if (cyc - t_sent[i] > MIN_GAP + SLACK)
                        fail("latency", $sformatf("event %0d reached DDR3 %0d cycles after it was sent", i, cyc - t_sent[i]));
            seen_evc = w48[63:32];
        end
        for (int i = seen_evc; i < n_sent && arm != "I3"; i++)
            if (cyc - t_sent[i] > MIN_GAP + SLACK + 5) begin
                fail("latency", $sformatf("event %0d not in DDR3 %0d cycles after it was sent", i, cyc - t_sent[i]));
                seen_evc = i + 1;
            end
        // [mouse]: the sums in DDR3 within the gap of the last packet (checked at every quiet
        // spell, not only at the end: a sum's high bits are wrong only some of the time)
        if (mouse_t >= 0 && cyc - mouse_t == MIN_GAP + SLACK && (cw(55) !== {dy_t, dx_t} || w64[31:0] !== wh_t))
            fail("mouse", $sformatf("sums %h / wheel %h in DDR3, %0d cycles after the last packet; sent %h %h / %h",
                 cw(55), cw(64), MIN_GAP + SLACK, dy_t, dx_t, wh_t));
        // [pads]: a pad's new word in DDR3 within the gap
        for (int n = 0; n < 6; n++)
            if (pad_t[n] >= 0 && cyc - pad_t[n] == MIN_GAP + SLACK &&
                cw(49 + n) !== {ana_r[16 * n +: 16], ana_l[16 * n +: 16], joy[32 * n +: 32]})
                fail("pads", $sformatf("pad %0d: %h in DDR3, %0d cycles after it became %h", n, cw(49 + n), MIN_GAP + SLACK,
                     {ana_r[16 * n +: 16], ana_l[16 * n +: 16], joy[32 * n +: 32]}));
    end

    // ---- coverage (I2): the cases the order rule exists for, reached (a peek, never a score) ----
    int n_act_osd = 0, n_act_both = 0;
    always @(posedge clk) if (lock_n) begin
        if (u_in.ap_m != 2'b00 && u_in.op_v) n_act_osd++;
        if (u_in.ap_m == 2'b11) n_act_both++;
    end

    // ---- the stand-in for the program: a copy through the seqlock, spread over time ----
    logic [63:0] img [48:71];
    task automatic copy_region(output bit ok);
        logic [31:0] tail, head;
        int tries;
        ok = 0;
        for (tries = 0; tries < 200 && !ok; tries++) begin
            tail = cw(71);
            repeat ($urandom_range(0, 3)) @(posedge mclk);
            for (int w = 48; w < 72; w++) begin
                img[w] = cw(w);
                if ($urandom_range(0, 3) == 0) @(posedge mclk);
            end
            head = cw(48);
            ok = (head === tail);
            if (ok && (img[48][31:0] !== tail || img[71][31:0] !== tail))
                fail("seqlock", $sformatf("a copy with in_head %h in_tail %h: its words say %h / %h", head, tail, img[48][31:0], img[71][31:0]));
            if (!ok) repeat ($urandom_range(5, 40)) @(posedge clk);
        end
        if (!ok) fail("seqlock", "no consistent copy of the input region in 200 tries");
    endtask

    int          r_count = 0;                         // the reader's event count
    longint      r_lost = 0, r_got = 0;
    int          r_reads = 0;
    task automatic read_events();
        bit ok;  logic [31:0] evc;  logic [15:0] e;
        copy_region(ok);
        if (!ok) return;
        r_reads++;
        evc = img[48][63:32];
        if (evc - r_count > RI_IN_Q_LEN) begin              // the oldest were overwritten: counted
            r_lost += evc - r_count - RI_IN_Q_LEN;
            r_count = evc - RI_IN_Q_LEN;
        end
        for (int i = r_count; i < evc; i++) begin
            e = img[RI_IN_Q_WORD + (i % RI_IN_Q_LEN) / 4] >> (16 * (i % 4));
            if (arm != "I3" && e !== truth[i])
                fail("events", $sformatf("event %0d: read %h, sent %h", i, e, truth[i]));
            r_got++;
        end
        r_count = evc;
    endtask

    int poll_lo = 200, poll_hi = 900;
    bit reading = 1;
    bit after_write = 0;                               // I4: read just after each write lands
    initial begin
        logic [63:0] h, t;
        wait (lock_n);
        while (reading) begin
            if (after_write) begin
                h = cw(48);
                do begin @(posedge clk); t = cw(48); end while (t[31:0] === h[31:0] && reading);
                repeat ($urandom_range(40, 300)) @(posedge clk);
            end else
                repeat ($urandom_range(poll_lo, poll_hi)) @(posedge clk);
            read_events();
        end
    end

    // ---- the scenarios ----
    task automatic mixed(input int n);
        for (int i = 0; i < n; i++) begin
            case ($urandom_range(0, 9))
                0, 1, 2, 3: key(8'($urandom_range(1, 255)), 1'($urandom), 1'($urandom));
                4, 5:       mouse($urandom_range(0, 510) - 255, $urandom_range(0, 510) - 255, $urandom_range(0, 126) - 63,
                                  ($urandom_range(0, 3) == 0) ? 8'($urandom) : btn_t);
                6:          osd_set(!osd);
                7:          pad($urandom_range(0, 5));
                8:          if (osd) begin                   // chosen in the OSD, which Main then closes
                                action($urandom_range(0, 1));
                                repeat ($urandom_range(54, 400)) @(posedge clk);
                                osd_set(1'b0);
                            end else action($urandom_range(0, 1));
                default:    ;
            endcase
            repeat ($urandom_range(54, 1500)) @(posedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("arm=%s", arm)) arm = "I1";
        repeat (10) @(posedge clk);
        lock_n = 1'b1;
        repeat (3 * FRAME_T) @(posedge clk);
        if (arm == "I1") begin
                      mixed(900);
                      // pad changes alone (nothing else to make the region dirty but a frame): a
                      // pad change must itself ask for a write
                      for (int k = 0; k < 12; k++) begin
                          pad($urandom_range(0, 5));
                          repeat (MIN_GAP + SLACK + 400) @(posedge clk);
                      end
                  end
        else if (arm == "I2") for (int f = 0; f < 60; f++) begin
                      // a chord started 3 cycles before a frame pulse, then one into the write it causes
                      wait (fcnt == FRAME_T - 4);
                      for (int k = 0; k < $urandom_range(2, 6); k++) begin
                          key(8'($urandom_range(1, 255)), 1'($urandom), 1'($urandom));
                          repeat (54) @(posedge clk);
                      end
                      repeat ($urandom_range(MIN_GAP - 40, MIN_GAP + 40)) @(posedge clk);
                      for (int k = 0; k < $urandom_range(2, 6); k++) begin
                          key(8'($urandom_range(1, 255)), 1'($urandom), 1'($urandom));
                          repeat ($urandom_range(5, 30)) @(posedge clk);
                      end
                      // (0.8) an action and an OSD edge pending together (the action first), then
                      // both actions rising together (action 0 first): each started a few cycles
                      // into a write of the region (the write's start peeked to time the stimulus)
                      repeat ($urandom_range(100, 400)) @(posedge clk);
                      do @(posedge clk); while (!u_in.in_go);
                      repeat ($urandom_range(0, 6)) @(posedge clk);
                      action_pulse(2'($urandom_range(1, 2)), 3);
                      osd_set(!osd);
                      do @(posedge clk); while (!u_in.in_go);
                      repeat ($urandom_range(0, 6)) @(posedge clk);
                      action_pulse(2'b11, 3);
                  end
        else if (arm == "I3") begin
                      mixed(40);
                      for (int k = 0; k < 400; k++) begin
                          key(8'($urandom_range(1, 255)), 1'($urandom), 1'($urandom));
                          repeat (2) @(posedge clk);
                      end
                      mixed(40);
                      for (int k = 0; k < 1500; k++) begin     // (0.8) actions in the flood (over several writes)
                          key(8'($urandom_range(1, 255)), 1'($urandom), 1'($urandom));
                          action_pulse(2'($urandom_range(1, 3)), 1);
                      end
                      mixed(40);
                  end
        else if (arm == "I4") begin
                      poll_lo = 6 * MIN_GAP; poll_hi = 7 * MIN_GAP;
                      // events faster than a queue a write period (but slower than the freeze: the
                      // core loses none), the reader reading just after each write: every copy it
                      // takes is more than a queue behind, so it trusts the oldest slots -- the ones
                      // an event applied during a write's push would overwrite (the freeze's arm)
                      after_write = 1;
                      for (int b = 0; b < 4; b++) begin
                          for (int k = 0; k < $urandom_range(500, 900); k++) begin
                              key(8'($urandom_range(1, 255)), 1'($urandom), 1'($urandom));
                              repeat ($urandom_range(30, 70)) @(posedge clk);
                          end
                          repeat ($urandom_range(3 * MIN_GAP, 9 * MIN_GAP)) @(posedge clk);
                      end
                  end
        else if (arm == "I5") begin
                      mixed(20);
                      repeat (2 * FRAME_T) @(posedge clk);
                      wait (fcnt == 100);
                      idle_win = 1; win_writes = 0;
                      repeat (20 * FRAME_T) @(posedge clk);
                      idle_win = 0;
                      if (win_writes < 19) fail("heartbeat", $sformatf("%0d writes of the idle region in 20 frames", win_writes));
                      if (win_writes > 21) fail("rate", $sformatf("%0d writes of the idle region in 20 frames", win_writes));
                      // a lone action after the frame's own region write (it waits behind the frame's
                      // status job, ~150 cycles) and ~8,000 cycles before the next frame: it reaches
                      // DDR3 by its own write (an action is a change), within the latency bound
                      wait (fcnt == 1000);
                      action(0);
                  end
        else begin $display("FAIL [harness] arm %s", arm); $fatal(1); end
        // quiet, then the last read and the end state
        repeat (MIN_GAP + FRAME_T) @(posedge clk);
        reading = 0;
        repeat (poll_hi + 10) @(posedge clk);
        read_events();
        if (img[48][63:32] + img[64][63:48] !== 32'(n_sent) && arm == "I3")
            fail("lost", $sformatf("ev_count %0d + ev_lost %0d, %0d events sent", img[48][63:32], img[64][63:48], n_sent));
        if (arm == "I3" && img[64][63:48] === 16'd0) fail("lost", "the flood lost nothing in the core (ev_lost 0)");
        if (arm != "I3" && (img[48][63:32] !== 32'(n_sent) || img[64][63:48] !== 16'd0))
            fail("lost", $sformatf("ev_count %0d ev_lost %0d, %0d events sent", img[48][63:32], img[64][63:48], n_sent));
        // every event the reader did not get was counted lost, and no other
        if (arm != "I3" && r_got + r_lost != n_sent)
            fail("lost", $sformatf("the reader got %0d and counted %0d lost of %0d sent", r_got, r_lost, n_sent));
        if (arm == "I4") begin
            if (r_lost == 0) fail("lost", "the slow reader never fell more than a queue behind (the arm tests nothing)");
        end else if (arm != "I3" && r_lost != 0) fail("lost", $sformatf("the reader counted %0d events lost", r_lost));
        if (img[55] !== {dy_t, dx_t} || img[64][31:0] !== wh_t || img[64][39:32] !== btn_t || img[64][40] !== osd)
            fail("mouse", $sformatf("sums dx %h dy %h wheel %h buttons %h osd %b; sent %h %h %h %h %b",
                 img[55][31:0], img[55][63:32], img[64][31:0], img[64][39:32], img[64][40], dx_t, dy_t, wh_t, btn_t, osd));
        for (int n = 0; n < 6; n++)
            if (img[49 + n] !== {ana_r[16 * n +: 16], ana_l[16 * n +: 16], joy[32 * n +: 32]}) fail("pads", $sformatf("pad %0d at the end", n));
        if (img[65] !== 64'd0 || img[70] !== 64'd0) fail("events", "the reserved words 65-70 are not zero");
        if (arm == "I2" && (n_act_osd == 0 || n_act_both == 0))
            fail("coverage", $sformatf("an action pending beside an OSD edge %0d cycles, both actions %0d", n_act_osd, n_act_both));
        // [frames]: every raster frame's status job ran (a frame during an input job kept pending)
        if (n_skips !== 32'd0 || seq !== 32'(n_frames))
            fail("frames", $sformatf("%0d status frames for %0d raster frames (%0d skipped)", seq, n_frames, n_skips));
        if (cw(3) === 64'hX || cw(3) != {58'd0, 6'd3}) fail("frames", "the frame's words not in DDR3");
        $display("ring_in_tb: %s %0d events sent, %0d reads, %0d region writes, %0d lost by the reader, ev_lost %0d, %0d frames",
                 arm, n_sent, r_reads, n_writes, r_lost, img[64][63:48], seq);
        if (fails == 0) $display("PASS: ring_in_tb %s", arm);
        else $fatal(1);
        $finish;
    end

    initial begin
        #800ms; $display("FAIL [hang] %s: the run never finished", arm); $fatal(1);
    end
endmodule

`default_nettype wire
