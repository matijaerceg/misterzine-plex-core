// bench/h264/dsf_calc_tb.sv -- h264/dec/dsf_calc.sv over every (tb, td) difference in
// -140..140 (the clip on both sides) plus two far out of range, against the model's
// formula (tools/h264_recon_ref.py's temporal_direct / weighted, 8-197 / 8-198):
//   [dsf]   DistScaleFactor and td_zero equal (`!==`)
//   [time]  done within 20 cycles of start
// PASS marker: "PASS: dsf_calc_tb".
`timescale 1ns/1ps
module dsf_calc_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
reg clk = 1'b0; always #5 clk = ~clk;
reg rst_n = 1'b0, start = 1'b0;
reg signed [31:0] diff_b = 0, diff_d = 0;
wire done, td_zero;
wire signed [10:0] dsf;
dsf_calc dut (.clk(clk), .rst_n(rst_n), .start(start), .diff_b(diff_b), .diff_d(diff_d), .done(done), .dsf(dsf), .td_zero(td_zero));
integer fd, n = 0, cyc, rc;
reg [31:0] b, d; reg [10:0] want; reg wz;
initial begin
    fd = $fopen("bench/h264/fixtures/gen/dsf_cases.txt", "r");
    if (fd == 0) `FAIL("harness", "no cases")
    #23 rst_n = 1'b1;
    while (!$feof(fd)) begin
        rc = $fscanf(fd, "%h %h %h %h\n", b, d, want, wz);
        if (rc != 4) break;
        @(negedge clk); diff_b = b; diff_d = d; start = 1'b1;
        @(negedge clk); start = 1'b0;
        cyc = 0;
        while (!done) begin @(negedge clk); cyc = cyc + 1; if (cyc > 20) `FAIL("time", "no done") end
        if (dsf !== want || td_zero !== wz)
            `FAIL("dsf", $sformatf("diff_b %0d diff_d %0d: dsf %0d zero %0d, want %0d %0d", $signed(b), $signed(d), dsf, td_zero, $signed(want), wz))
        n = n + 1;
    end
    $display("dsf_calc_tb: %0d (tb, td) pairs", n);
    $display("PASS: dsf_calc_tb");
    $finish;
end
endmodule
