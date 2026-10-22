// h264/ring_in.sv -- the HPS interface's input region (interface 0.6; docs/architecture.md
// "Input (interface 0.6)"): Main's input as hps_io hands it to the core -- six pads, every key
// as a PS/2 set-2 event, the mouse -- mirrored into the control block's words 48-71 for a
// program on the ARM to forward (the Moonlight client: Main grabs every input device, so the
// core is the only way a program sees them). clk_sys, reset by the PLL lock alone (an OSD
// Reset must not move the counts a program keeps).
//
// THE EVENTS. hps_io's ps2_key [10] and ps2_mouse [24] toggle once per event, and the events
// of one USB report arrive microseconds apart: the toggles are watched every cycle. Keys,
// mouse-button changes and the OSD's edges (OSD_STATUS, synchronised by the caller) share ONE
// queue so a program sees them in the order they happened: 32 entries of 16 bits in registers,
// event n at entry n % 32, ev_count the next event's number (free-running). A mouse packet
// moves the sums (dx, dy, the wheel: signed, wrapping -- nothing is lost between two reads)
// and queues an event only when the buttons changed.
//
// THE WRITE. in_req asks h264/ring_stat.sv for a write of the region: something changed (an
// event applied, a pad or stick moved, a frame passed -- the region's heartbeat) and MIN_GAP
// cycles have passed since the last write began (1 ms at 27 MHz). ring_stat answers with
// in_go (the write begins: in_head advances) and holds in_busy while it pushes the 24 words
// through ring_words_in (a mux on in_ix). During in_go / in_busy the queue, the sums and the
// button state are FROZEN: an event arriving then waits in a one-deep pending register of
// its source and is applied after, one a cycle (key, then mouse, then OSD). A second event
// from the same source while the first waits is counted in ev_lost (saturating), never
// dropped silently -- impossible at Main's pace (each event is its own multi-word bus
// transaction, far longer than the ~30-cycle write). The pad words are read live: each is
// its own word.
//
// THE ACTIONS (interface 0.8; docs/architecture.md "The OSD's actions (0.8)"). CONF_STR's
// R[17] / R[18] lines: choosing one, Main sets its status bit and clears it again (two SPI
// transactions, microseconds apart), then closes the OSD. A rising edge of act[n] queues the
// event {ACTION, n}; the pending register is a mask (one bit an action), applied lowest first
// after a key and a mouse event and BEFORE an OSD edge: the action was chosen while the OSD
// was still open, and the program must see it in that order. An edge of an action already
// pending is counted in ev_lost.
//
// Quartus 17: no functions, no N'() casts; the queue is a register array read by a
// constant-stride word index (a case, never a variable part-select of a wide vector).

`default_nettype none

module ring_in #(
    parameter int MIN_GAP = 27000                // clk_sys cycles between two writes' starts: 1 ms at 27 MHz
) (
    input  wire          clk,                    // clk_sys
    input  wire          rst_n,                  // the PLL lock alone
    input  wire          frame,                  // one pulse a raster frame: the region's heartbeat
    // hps_io's input (clk_sys)
    input  wire  [191:0] joy,                    // joystick_0..5, pad n at [32n +: 32]
    input  wire   [95:0] ana_l,                  // joystick_l_analog_0..5, pad n at [16n +: 16]
    input  wire   [95:0] ana_r,                  // joystick_r_analog_0..5
    input  wire   [10:0] ps2_key,
    input  wire   [24:0] ps2_mouse,
    input  wire   [15:0] ps2_mouse_ext,
    input  wire          osd,                    // OSD_STATUS, synchronised into clk_sys
    input  wire    [1:0] act,                    // (0.8) the OSD's action bits, status[18:17] (clk_sys)
    // ring_stat's side
    output logic         in_req,
    input  wire          in_go,                  // one cycle: the region's write is granted (combinational in
                                                 // ring_stat: in_head advances before the first word is pushed)
    input  wire          in_busy,                // its words are being pushed
    input  wire    [4:0] in_ix,                  // the word being pushed (0 = word 48)
    output logic  [63:0] in_word,
    // for the bench
    output logic  [31:0] n_events
);

`include "h264/ring_iface.svh"

    localparam logic [16:0] GAP = MIN_GAP - 1;   // sized, not cast (Quartus 17)

    logic         primed;                        // the toggles' first sample is not an event
    logic         k_t, m_t, o_s;                 // the last toggle / OSD level seen
    logic   [1:0] a_s;                           // the action bits as last seen
    logic         kp_v, mp_v, op_v;              // pending: one per source
    logic   [1:0] ap_m;                          // pending actions: one bit each
    logic   [9:0] kp_d;
    logic  [24:0] mp_d;
    logic  [15:0] mpx_d;
    logic         op_d;
    logic  [15:0] q [0:31];                      // the queue
    logic  [31:0] ev_count, in_seq, dx_sum, dy_sum, wheel_sum;
    logic   [7:0] mbtn;
    logic         osd_open;
    logic  [15:0] ev_lost;
    logic         dirty;
    logic  [16:0] gap;                           // cycles since the last write began (saturating at GAP)
    logic [383:0] pads_q;                        // the pads as last seen: a change asks for a write

    wire         freeze = in_go || in_busy;
    wire         k_new  = primed && (ps2_key[10] != k_t);
    wire         m_new  = primed && (ps2_mouse[24] != m_t);
    wire         o_new  = primed && (osd != o_s);
    wire   [1:0] a_new  = primed ? (act & ~a_s) : 2'b00;
    wire         k_app  = !freeze && kp_v;
    wire         m_app  = !freeze && !kp_v && mp_v;
    wire         a_app  = !freeze && !kp_v && !mp_v && (ap_m != 2'b00);
    wire         a_num  = !ap_m[0];              // the lowest pending action
    wire   [1:0] a_done = a_app ? (a_num ? 2'b10 : 2'b01) : 2'b00;
    wire         o_app  = !freeze && !kp_v && !mp_v && (ap_m == 2'b00) && op_v;
    wire [383:0] pads   = {ana_r, ana_l, joy};
    // a mouse packet (PS/2): [4] / [5] the signs of the 9-bit dx / dy, [2:0] L R M; ext [7:0] the
    // wheel (sign-extended by hps_io), [12:8] buttons 4-8
    wire  [31:0] m_dx   = {{24{mp_d[4]}}, mp_d[15:8]};
    wire  [31:0] m_dy   = {{24{mp_d[5]}}, mp_d[23:16]};
    wire  [31:0] m_wh   = {{24{mpx_d[7]}}, mpx_d[7:0]};
    wire   [7:0] m_btn  = {mpx_d[12:8], mp_d[2:0]};
    wire         push   = k_app || (m_app && m_btn != mbtn) || a_app || o_app;
    // a second event from a source whose first still waits (only possible during a write)
    wire         k_lost = k_new && kp_v && !k_app;
    wire         m_lost = m_new && mp_v && !m_app;
    wire         o_lost = o_new && op_v && !o_app;
    wire   [1:0] a_lost = a_new & ap_m & ~a_done;
    wire  [16:0] lost_s = {1'b0, ev_lost} + {15'd0, k_lost} + {15'd0, m_lost} + {15'd0, o_lost} +
                          {15'd0, a_lost[0]} + {15'd0, a_lost[1]};
    logic [15:0] ev;
    always_comb begin
        if (k_app)      ev = {RV_KEY, 4'd0, kp_d};
        else if (m_app) ev = {RV_MOUSE_BTN, 6'd0, m_btn};
        else if (a_app) ev = {RV_ACTION, 13'd0, a_num};
        else            ev = {RV_OSD, 13'd0, op_d};
    end

    assign in_req   = dirty && (gap == GAP);
    assign n_events = ev_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            primed <= 1'b0; k_t <= 1'b0; m_t <= 1'b0; o_s <= 1'b0; a_s <= 2'b00; ap_m <= 2'b00;
            kp_v <= 1'b0; mp_v <= 1'b0; op_v <= 1'b0; kp_d <= '0; mp_d <= '0; mpx_d <= '0; op_d <= 1'b0;
            ev_count <= '0; in_seq <= '0; dx_sum <= '0; dy_sum <= '0; wheel_sum <= '0;
            mbtn <= '0; osd_open <= 1'b0; ev_lost <= '0; dirty <= 1'b1; gap <= GAP; pads_q <= '0;
            for (int i = 0; i < 32; i++) q[i] <= '0;
        end else begin
            primed <= 1'b1;
            k_t <= ps2_key[10]; m_t <= ps2_mouse[24]; o_s <= osd; a_s <= act;
            if (!primed) osd_open <= osd;            // the level at the start is a state, not an event
            pads_q <= pads;
            if (gap != GAP) gap <= gap + 17'd1;
            // arrivals: into the source's pending register (a second before the first was
            // applied is lost, counted)
            if (k_new) begin kp_d <= ps2_key[9:0]; kp_v <= 1'b1; end
            else if (k_app) kp_v <= 1'b0;
            if (m_new) begin mp_d <= ps2_mouse; mpx_d <= ps2_mouse_ext; mp_v <= 1'b1; end
            else if (m_app) mp_v <= 1'b0;
            if (o_new) begin op_d <= osd; op_v <= 1'b1; end
            else if (o_app) op_v <= 1'b0;
            ap_m <= (ap_m & ~a_done) | a_new;
            ev_lost <= lost_s[16] ? 16'hFFFF : lost_s[15:0];
            // application: one pending event a cycle, never during a write
            if (m_app) begin
                dx_sum <= dx_sum + m_dx; dy_sum <= dy_sum + m_dy; wheel_sum <= wheel_sum + m_wh;
                mbtn <= m_btn;
            end
            if (o_app) osd_open <= op_d;
            if (push) begin
                q[ev_count[4:0]] <= ev;
                ev_count <= ev_count + 32'd1;
            end
            // the write: asked when something changed and the gap has passed
            if (in_go) begin
                in_seq <= in_seq + 32'd1; dirty <= 1'b0; gap <= '0;
            end
            if (k_app || m_app || a_app || o_app || frame || pads != pads_q) dirty <= 1'b1;
        end
    end

    ring_words_in u_w (
        .ix(in_ix),
        .f_in_head(in_seq), .f_ev_count(ev_count),
        .f_pad0_joy(joy[31:0]),    .f_pad0_lstick(ana_l[15:0]),  .f_pad0_rstick(ana_r[15:0]),
        .f_pad1_joy(joy[63:32]),   .f_pad1_lstick(ana_l[31:16]), .f_pad1_rstick(ana_r[31:16]),
        .f_pad2_joy(joy[95:64]),   .f_pad2_lstick(ana_l[47:32]), .f_pad2_rstick(ana_r[47:32]),
        .f_pad3_joy(joy[127:96]),  .f_pad3_lstick(ana_l[63:48]), .f_pad3_rstick(ana_r[63:48]),
        .f_pad4_joy(joy[159:128]), .f_pad4_lstick(ana_l[79:64]), .f_pad4_rstick(ana_r[79:64]),
        .f_pad5_joy(joy[191:160]), .f_pad5_lstick(ana_l[95:80]), .f_pad5_rstick(ana_r[95:80]),
        .f_dx_sum(dx_sum), .f_dy_sum(dy_sum),
        .f_ev_q0(q[0]),   .f_ev_q1(q[1]),   .f_ev_q2(q[2]),   .f_ev_q3(q[3]),
        .f_ev_q4(q[4]),   .f_ev_q5(q[5]),   .f_ev_q6(q[6]),   .f_ev_q7(q[7]),
        .f_ev_q8(q[8]),   .f_ev_q9(q[9]),   .f_ev_q10(q[10]), .f_ev_q11(q[11]),
        .f_ev_q12(q[12]), .f_ev_q13(q[13]), .f_ev_q14(q[14]), .f_ev_q15(q[15]),
        .f_ev_q16(q[16]), .f_ev_q17(q[17]), .f_ev_q18(q[18]), .f_ev_q19(q[19]),
        .f_ev_q20(q[20]), .f_ev_q21(q[21]), .f_ev_q22(q[22]), .f_ev_q23(q[23]),
        .f_ev_q24(q[24]), .f_ev_q25(q[25]), .f_ev_q26(q[26]), .f_ev_q27(q[27]),
        .f_ev_q28(q[28]), .f_ev_q29(q[29]), .f_ev_q30(q[30]), .f_ev_q31(q[31]),
        .f_wheel_sum(wheel_sum), .f_mouse_btn(mbtn), .f_osd_open(osd_open), .f_ev_lost(ev_lost),
        .f_in_tail(in_seq),
        .w(in_word));

endmodule

`default_nettype wire
