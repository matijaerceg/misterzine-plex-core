// bench/h264/aspect_vui_tb.sv -- h264/aspect_vui.sv against tools/aspect_vui_golden.py (Table E-1
// read from the spec PDF; the 4:3 / 16:9 rounding checked there against the table's own
// examples). Every case: drive, one clock, compare {known, wide} with `!==`.
//   [table] every aspect_ratio_idc 0..255 at 720x480 (Extended_SAR 40:33 behind idc 255)
//   [round] the spec's informative examples at their coded sizes
//   [ext]   Extended_SAR: zero terms, extremes, 400 random pairs and sizes
//   [valid] nothing shown -> unknown
//   [sar]   (P6) every case: the resolved SAR out, 1:1 when not known
// `wide` is scored only where known = 1 (the caller ignores it otherwise).
// PASS marker: "PASS: aspect_vui_tb".
`timescale 1ns/1ps
module aspect_vui_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 0;
always #5 clk = ~clk;
reg valid; reg [7:0] idc, w, h; reg [15:0] ew, eh;
wire known, wide;
wire [15:0] sar_w_o, sar_h_o;
aspect_vui dut (.clk(clk), .valid(valid), .aspect_idc(idc), .ext_sar_w(ew), .ext_sar_h(eh),
                .w_mbs(w), .hf_mbs(h), .known(known), .wide(wide),
                .sar_w_o(sar_w_o), .sar_h_o(sar_h_o));
reg [95:0] cases [0:1023];
integer i, n = 0, nk = 0;
integer per [0:3];
string arms [0:3];
initial begin
    arms[0] = "table"; arms[1] = "round"; arms[2] = "ext"; arms[3] = "valid";
    for (i = 0; i < 4; i++) per[i] = 0;
    for (i = 0; i < 1024; i++) cases[i] = {96{1'b1}};
    $readmemh("bench/h264/fixtures/gen/aspect_vui.hex", cases);
    for (i = 0; i < 1024 && cases[i] !== {96{1'b1}}; i++) begin
        {valid, idc, ew, eh, w, h} = cases[i][58:2];
        @(posedge clk); #1;
        if (known !== cases[i][1])
            `FAIL(arms[cases[i][60:59]], $sformatf("case %0d idc %0d %0d:%0d %0dx%0d MBs: known %b want %b",
                  i, idc, ew, eh, w, h, known, cases[i][1]))
        if (cases[i][1] && wide !== cases[i][0])
            `FAIL(arms[cases[i][60:59]], $sformatf("case %0d idc %0d %0d:%0d %0dx%0d MBs: wide %b want %b",
                  i, idc, ew, eh, w, h, wide, cases[i][0]))
        // P6: the resolved SAR (1:1 when not known) -- the fit's and the exact aspect's input
        if ({sar_w_o, sar_h_o} !== cases[i][95:64])
            `FAIL("sar", $sformatf("case %0d idc %0d %0d:%0d: sar %0d:%0d want %0d:%0d",
                  i, idc, ew, eh, sar_w_o, sar_h_o, cases[i][95:80], cases[i][79:64]))
        n = n + 1; per[cases[i][60:59]] = per[cases[i][60:59]] + 1;
        if (cases[i][1]) nk = nk + 1;
    end
    if (n < 700 || per[1] < 20 || per[3] < 3) `FAIL("count", $sformatf("%0d cases (%0d examples)", n, per[1]))
    $display("aspect_vui_tb: %0d cases identical (%0d with a known SAR; table %0d, examples %0d, ext %0d, valid %0d)",
             n, nk, per[0], per[1], per[2], per[3]);
    $display("PASS: aspect_vui_tb");
    $finish;
end
endmodule
