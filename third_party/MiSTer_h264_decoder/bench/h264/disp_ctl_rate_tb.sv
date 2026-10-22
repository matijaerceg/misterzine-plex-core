`timescale 1ns/1ps
module disp_ctl_rate_tb;
  reg clk=0, rst_n=0;
  reg [31:0] nuit=1, ts=48;
  always #5 clk=~clk;
  wire rate_v;
  wire [1:0] rate_cls;

  disp_ctl dut (
    .clk(clk), .rst_n(rst_n), .frame0(1'b0), .il(1'b1), .prog240(1'b0), .std(2'd0),
    .rec_valid(1'b1), .rec_more(1'b0), .low_lat(1'b0), .pause(1'b0), .aanc(1'b0),
    .aanc_pts(33'd0), .aud_lead(1'b0), .rec_end(1'b0), .rec_store(5'd0),
    .rec_frame(1'b1), .rec_unpaired(1'b0), .rec_first_bot(1'b0), .rec_dec_t(1'b1), .rec_dec_b(1'b1),
    .rec_w_mbs(8'd45), .rec_hf_mbs(8'd30), .rec_crop(41'd0), .rec_aspect(40'd0),
    .rec_colour(3'd1), .rec_col_unsup(1'b0), .rec_col_tags(26'd0), .rec_siting(6'd0),
    .rec_timing_v(1'b1), .rec_nuit(nuit), .rec_ts(ts), .rec_ps_a(4'd0), .rec_ps_a_v(1'b0),
    .rec_ps_b(4'd0), .rec_ps_b_v(1'b0), .rec_pts(33'd0), .rec_pts_v(1'b0),
    .rec_pts_b(33'd0), .rec_pts_b_v(1'b0), .rate_v(rate_v), .rate_cls(rate_cls)
  );

  task run_case(input [31:0] n, input [31:0] t, input [1:0] want);
    integer cycles;
    begin
      @(negedge clk); rst_n=0; nuit=n; ts=t;
      repeat (4) @(negedge clk);
      rst_n=1;
      cycles = 0;
      while (rate_v !== 1'b1 && cycles < 64) begin
        @(negedge clk);
        cycles = cycles + 1;
      end
      if (rate_v !== 1'b1)
        $fatal(1, "timeout preparing VUI %0d/%0d after %0d cycles", n, t, cycles);
      #1;
      if (rate_cls !== want)
        $fatal(1, "rate class for VUI %0d/%0d was %0d, wanted %0d (fq=%0d)", n, t, rate_cls, want, dut.fq);
      $display("PASS: VUI %0d/%0d -> fq %0d, rate class %0d", n, t, dut.fq, rate_cls);
    end
  endtask

  initial begin
    run_case(32'd1, 32'd48, 2'd1);         // 24 fps -> 60.00 class
    run_case(32'd1001, 32'd48000, 2'd0);   // 23.976 fps -> default 59.94 class
    run_case(32'd1, 32'd50, 2'd2);         // 25 fps -> 50 Hz class
    $display("PASS: disp_ctl_rate_tb");
    $finish;
  end
endmodule
