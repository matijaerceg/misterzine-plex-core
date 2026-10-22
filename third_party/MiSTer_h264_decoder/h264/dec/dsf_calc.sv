// h264/dec/dsf_calc.sv -- DistScaleFactor (8-197, 8-198) from two picture-order-count
// differences, for temporal direct (8.4.1.2.3) and implicit weights (8.4.3):
//
//   tb = Clip3(-128, 127, DiffPicOrderCnt(currPicOrField, pic0))     (8-201)
//   td = Clip3(-128, 127, DiffPicOrderCnt(pic1, pic0))               (8-202)
//   tx = (16384 + Abs(td / 2)) / td                                  (8-197, "/" truncates toward zero)
//   DistScaleFactor = Clip3(-1024, 1023, (tb * tx + 32) >> 6)        (8-198)
//
// td == 0 is the callers' "use mvCol / weights 32" case: `td_zero` says so and dsf is 0.
// Serial: a restoring divider, one quotient bit per cycle (the dividend is at most
// 16384 + 64 < 2^15), then one registered product -- 18 cycles from start to done.
// Used once per list-0 entry per slice (temporal direct) and once per bi-predicted
// partition of an implicit-weights slice. Gate: bench/h264/run_dsf_calc.sh (every
// (tb, td) pair in -128..127 against the model's formula).

`default_nettype none

module dsf_calc (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire signed [31:0] diff_b,      // DiffPicOrderCnt(currPicOrField, pic0)
    input  wire signed [31:0] diff_d,      // DiffPicOrderCnt(pic1, pic0)
    output logic        done,              // one pulse; dsf / td_zero valid until the next start
    output logic signed [10:0] dsf,
    output logic        td_zero
);

    logic signed [7:0]  tb, td;
    logic [14:0] num;                      // the dividend, shifted out MSB first
    logic [14:0] quo;
    logic [7:0]  rem;
    logic [7:0]  den;                      // |td|, 1..128
    logic        neg;                      // td < 0
    logic [4:0]  cnt;
    logic        busy, mul;

    wire signed [7:0] tb_c = (diff_b > 32'sd127) ? 8'sd127 : (diff_b < -32'sd128) ? -8'sd128 : diff_b[7:0];
    wire signed [7:0] td_c = (diff_d > 32'sd127) ? 8'sd127 : (diff_d < -32'sd128) ? -8'sd128 : diff_d[7:0];
    wire [7:0] td_abs = td_c[7] ? (8'd0 - td_c) : td_c;      // 1..128 (8 bits unsigned: 128 fits)

    // one restoring step
    wire [8:0] r_sh = {rem, num[14]};
    wire       ge = (r_sh >= {1'b0, den});

    // the product and the clip
    logic signed [15:0] tx;
    wire  signed [24:0] prod = tb * tx;                      // |tb| <= 128, |tx| <= 16384
    wire  signed [24:0] sh = (prod + 25'sd32) >>> 6;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb <= '0; td <= '0; num <= '0; quo <= '0; rem <= '0; den <= 8'd1; neg <= 1'b0; cnt <= '0;
            busy <= 1'b0; mul <= 1'b0; done <= 1'b0; dsf <= '0; td_zero <= 1'b0; tx <= '0;
        end else begin
            done <= 1'b0;
            if (start) begin
                tb <= tb_c; td <= td_c;
                td_zero <= (td_c == 8'sd0);
                den <= (td_c == 8'sd0) ? 8'd1 : td_abs;
                num <= 15'd16384 + {8'd0, td_abs[7:1]};
                neg <= td_c[7];
                rem <= '0; quo <= '0; cnt <= 5'd15;
                busy <= 1'b1; mul <= 1'b0;
            end else if (busy) begin
                if (cnt != 5'd0) begin
                    rem <= ge ? (r_sh[7:0] - den) : r_sh[7:0];
                    quo <= {quo[13:0], ge};
                    num <= {num[13:0], 1'b0};
                    cnt <= cnt - 1'b1;
                end else if (!mul) begin
                    tx <= neg ? -$signed({1'b0, quo}) : $signed({1'b0, quo});
                    mul <= 1'b1;
                end else begin
                    if (td_zero) dsf <= '0;
                    else if (sh > 25'sd1023) dsf <= 11'sd1023;
                    else if (sh < -25'sd1024) dsf <= -11'sd1024;
                    else dsf <= sh[10:0];
                    busy <= 1'b0; mul <= 1'b0; done <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
