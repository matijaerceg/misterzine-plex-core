// bench/h264/osd_req_tb.sv -- h264/osd_req.sv (interface 0.4, the settings request) against
// tools/osd_req_ref.py (the rule written from the design text): per vector, a menu state and a
// request handed over with a toggle -> err, whether status_set rose (once), status_in (when it
// did). Arms: [err] the result, [set] the pulse, [merge] status_in, [seq] the sequence
// number reported, [count] coverage. $fatal on failure; PASS marker.
`timescale 1ns/1ps
module osd_req_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 0, rst_n = 0; always #18.5 clk = ~clk;
reg [127:0] status; reg [31:0] word; reg tog = 0;
wire [127:0] status_in; wire status_set; wire [7:0] seq; wire [2:0] err; wire [15:0] n_applied;
osd_req dut (.clk(clk), .rst_n(rst_n), .status(status), .set_word(word), .set_tog(tog), .status_in(status_in),
             .status_set(status_set), .seq(seq), .err(err), .n_applied(n_applied));
integer fd, r, n = 0, sets, ne [0:3];
reg [127:0] vs, vout; reg [31:0] vw; integer ve, vset;
string vec;
task automatic check_match(input [31:0] req, input [2:0] expected_err,
                           input [1:0] expected_mode);
    integer pulses;
    begin
        @(negedge clk); status = '1; word = req; tog = ~tog; pulses = 0;
        repeat (8) begin @(posedge clk); #1; if (status_set === 1'b1) pulses++; end
        if (err !== expected_err) `FAIL("match", $sformatf("word %h: err %0d, want %0d", req, err, expected_err))
        if (pulses !== (expected_err == 0 ? 1 : 0)) `FAIL("match", $sformatf("word %h: set pulses %0d", req, pulses))
        if (expected_err == 0 && (status_in[28:27] !== expected_mode || status_in[23] !== status[23]))
            `FAIL("match", $sformatf("word %h: mode/legacy bit %0d/%0d, want %0d/%0d", req,
                                    status_in[28:27], status_in[23], expected_mode, status[23]))
    end
endtask
task automatic check_deflicker(input [1:0] value, input [7:0] seq_value);
    reg expected_disable;
    integer pulses;
    begin
        expected_disable = (value != 2'd2);
        @(negedge clk); status = '1;
        word = (32'd1 << 19) | ({30'd0, value} << 11) | ({24'd0, seq_value} << 24);
        tog = ~tog;
        pulses = 0;
        repeat (8) begin @(posedge clk); #1; if (status_set === 1'b1) pulses++; end
        if (err !== 0 || pulses !== 1 || status_in[16:15] !== value || status_in[29] !== expected_disable)
            `FAIL("deflicker", $sformatf("value %0d: err/set %0d/%0d legacy %0d bit29 %0d", value, err,
                                         pulses, status_in[16:15], status_in[29]))
    end
endtask
initial begin
    for (int i = 0; i < 4; i++) ne[i] = 0;
    if (!$value$plusargs("vec=%s", vec)) `FAIL("harness", "+vec= missing")
    fd = $fopen(vec, "r");
    status = '0; word = '0;
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
    r = $fscanf(fd, "%h %h %h %h %h\n", vs, vw, ve, vset, vout);
    while (r == 5) begin
        @(negedge clk); status = vs; word = vw; tog = ~tog;
        sets = 0;
        repeat (8) begin @(posedge clk); #1; if (status_set === 1'b1) sets = sets + 1; end
        if (err !== ve[2:0]) `FAIL("err", $sformatf("vector %0d (word %h): err %0d, want %0d", n, vw, err, ve))
        if (sets !== vset) `FAIL("set", $sformatf("vector %0d: status_set rose %0d times, want %0d", n, sets, vset))
        if (vset && vw[19] && status_in[29] !== vout[29])
            `FAIL("deflicker", $sformatf("vector %0d: bit 29 %0d, want %0d", n, status_in[29], vout[29]))
        if (vset && status_in !== vout) `FAIL("merge", $sformatf("vector %0d (word %h): status_in %h, want %h", n, vw, status_in, vout))
        if (seq !== vw[31:24]) `FAIL("seq", $sformatf("vector %0d: seq %h, want %h", n, seq, vw[31:24]))
        ne[ve] = ne[ve] + 1; n = n + 1;
        r = $fscanf(fd, "%h %h %h %h %h\n", vs, vw, ve, vset, vout);
    end
    // The app's legacy 3-value request remains accepted. The OSD now uses bit 29,
    // where low means On; its word-27 mirror is checked by the emu wiring gate.
    check_deflicker(2'd0, 8'd90);
    check_deflicker(2'd1, 8'd91);
    check_deflicker(2'd2, 8'd92);
    // Interface 1.3 enabled bit remains valid; retired v1.4 extension requests normalize to 50/60.
    check_match((32'd1 << 23) | (32'd2 << 13) | (32'd100 << 24), 0, 0);
    check_match((32'd1 << 23) | (32'd2 << 13) | (32'd1 << 3) | (32'd101 << 24), 0, 1);
    check_match((32'd1 << 23) | (32'd2 << 13) | (32'd1 << 3) | (32'd1 << 6) | (32'd102 << 24), 0, 1);
    check_match((32'd1 << 23) | (32'd2 << 13) | (32'd1 << 6) | (32'd103 << 24), 1, 0);
    check_match((32'd1 << 23) | (32'd1 << 13) | (32'd1 << 6) | (32'd104 << 24), 1, 0);
    if (n < 1000 || ne[0] < 100 || ne[1] < 20 || ne[2] < 20 || ne[3] < 20)
        `FAIL("count", $sformatf("coverage: %0d vectors, results %0d / %0d / %0d / %0d", n, ne[0], ne[1], ne[2], ne[3]))
    $display("osd_req_tb: %0d requests identical to the model (applied %0d, range %0d, reserved %0d, empty %0d)", n, ne[0], ne[1], ne[2], ne[3]);
    $display("PASS: osd_req_tb");
    $finish;
end
endmodule
