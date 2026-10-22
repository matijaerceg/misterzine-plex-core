// h264/osd_req.sv -- the program's settings request (interface 0.4, docs/architecture.md "The
// HPS interface", decided with the maintainer 2026-09-29): a program changes the core's OSD
// options from its own menus, through the framework's path for a core changing its options --
// hps_io's status_in / status_set, which Main adopts as if the user had chosen the value (the
// OSD shows it; the user can change it again: one copy of the settings, Main's).
//
// The request (program word 35, a u32 the engine hands over with set_tog, h264/ring_rd.sv):
//   [12:0]  the values in word 27's mirror order: Aspect [1:0], Deinterlace [3:2], Video
//           Output [5:4], HDMI Deinterlace [6], Analog Aspect [8:7], Refresh Rate [10:9],
//           Anti-Twitter [12:11]
//   [19:13] the mask, one bit an option in that order
//   [23:20] zero;  [31:24] the sequence number (the engine hands on only new, nonzero ones)
// Checked: a masked value past its option's last (Aspect / Deinterlace / Anti-Twitter have
// three values: 3 is out of range; Video Output four since 0.10 -- Native (HDMI)), a reserved bit, an empty mask -> refused
// (err 1 / 2 / 3), nothing sent. Else the masked fields replace the current status bits
// (CONF_STR's positions: status[2:1], [4:3], [6:5], [7], [9:8], [12:11], [16:15]), every other
// bit kept; Anti-Twitter also sets status[29] (the current De-flicker OSD bit: 0 On, 1 Off),
// with legacy Auto/Off mapping to Off and On mapping to On. status[0] (the OSD's Reset) and
// status[18:17] (0.8: the OSD's actions -- a request landing inside Main's pulse must not leave
// one set in Main's copy) are forced 0, and status_set
// rises for one clock.
// `seq` is the last sequence number consumed (applied or refused); err its result.
//
// clk_sys. No `function`, no N'(expr) cast (Quartus 17).
`default_nettype none
module osd_req (
    input  wire          clk,               // clk_sys (hps_io's)
    input  wire          rst_n,
    input  wire  [127:0] status,            // hps_io's current status (the menu's settings)
    input  wire  [31:0]  set_word,          // clk_mem, quasi-static (captured after the toggle crosses)
    input  wire          set_tog,           // clk_mem toggle: a new request
    output logic [127:0] status_in,         // to hps_io
    output logic         status_set,        // to hps_io: one clock, rising
    output logic [7:0]   seq,               // the last request consumed
    output logic [2:0]   err,               // its result: 0 applied, 1 range, 2 reserved, 3 empty
    output logic [15:0]  n_applied          // requests applied (a liveness count; saturating)
);
    logic [2:0]  tog_s;
    wire         fresh = tog_s[2] != tog_s[1];
    wire [12:0]  v = set_word[12:0];
    wire [6:0]   m = set_word[19:13];
    // v1.3 extended display request: bit23 selects profile/match/240p/film.
    // Retired v1.4 value bit6 is accepted only as a legacy 50/60 request marker.
    // Values [2:0],3,4,5; mask bits0..3 respectively. No legacy bits change.
    wire         display_req = set_word[23];
    wire         bad_reserved = display_req ?
                   (|set_word[22:20] || |v[12:7] || |m[6:4]) :
                   (set_word[23:20] != 4'd0);
    wire         bad_display_match = display_req && v[6] && !(m[1] && v[3]);
    // a masked value past its option's last value
    wire         bad_range = (m[0] && v[1:0]   == 2'd3) ||      // Aspect: Auto, 4:3, 16:9
                             (m[1] && v[3:2]   == 2'd3) ||      // Deinterlace: Weave, Bob, Blend
                             (m[6] && v[12:11] == 2'd3);        // Anti-Twitter: Auto, Off, On
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tog_s <= '0; status_in <= '0; status_set <= 1'b0; seq <= '0; err <= '0; n_applied <= '0;
        end else begin
            tog_s <= {tog_s[1:0], set_tog};
            status_set <= 1'b0;
            if (fresh) begin
                seq <= set_word[31:24];
                if (m == 7'd0)                       err <= 3'd3;
                else if (bad_reserved)               err <= 3'd2;
                else if (display_req ? ((m[0] && v[2:0] > 3'd4) || bad_display_match) : bad_range) err <= 3'd1;
                else begin
                    err <= 3'd0;
                    status_in <= status;
                    status_in[0] <= 1'b0;                              // never the OSD's Reset
                    status_in[18:17] <= 2'b00;                         // never an OSD action (0.8)
                    if (display_req) begin
                        if (m[0]) status_in[22:20] <= v[2:0];
                        if (m[1]) status_in[28:27] <= (v[6] || v[3]) ? 2'd1 : 2'd0;
                        if (m[2]) status_in[24] <= v[4];
                        if (m[3]) status_in[25] <= v[5];
                    end else begin
                    if (m[0]) status_in[2:1]   <= v[1:0];
                    if (m[1]) status_in[4:3]   <= v[3:2];
                    if (m[2]) status_in[6:5]   <= v[5:4];
                    if (m[3]) status_in[7]     <= v[6];
                    if (m[4]) status_in[9:8]   <= v[8:7];
                    if (m[5]) status_in[12:11] <= v[10:9];
                    if (m[6]) begin
                        status_in[16:15] <= v[12:11]; // retain the legacy OSD status bits
                        status_in[29] <= (v[12:11] != 2'd2); // legacy Auto/Off disables; On enables
                    end
                    end
                    status_set <= 1'b1;
                    if (n_applied != 16'hFFFF) n_applied <= n_applied + 16'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
