`timescale 1ns/1ps
module disp_ctl_240_tb;
  reg clk=0, rst_n=0, frame0=0, prog240=1, pause=0;
  reg [1:0] std=1; // exact-60 inputs alias the fixed-line 59.94-class lowres grid
  reg aanc=0;
  reg [32:0] aanc_pts=33'd100;
  always #5 clk=~clk;
  wire [32:0] stc;
  wire stc_run, pick_ph;

  disp_ctl dut (
    .clk(clk), .rst_n(rst_n), .frame0(frame0), .il(1'b0), .prog240(prog240), .std(std),
    .rec_valid(1'b0), .rec_more(1'b0), .low_lat(1'b0), .pause(pause), .aanc(aanc),
    .aanc_pts(aanc_pts), .aud_lead(1'b0), .rec_end(1'b0), .rec_store(5'd0),
    .rec_frame(1'b1), .rec_unpaired(1'b0), .rec_first_bot(1'b0), .rec_dec_t(1'b0),
    .rec_dec_b(1'b0), .rec_w_mbs(8'd0), .rec_hf_mbs(8'd0), .rec_crop(41'd0),
    .rec_aspect(40'd0), .rec_colour(3'd1), .rec_col_unsup(1'b0), .rec_col_tags(26'd0),
    .rec_siting(6'd0), .rec_timing_v(1'b0), .rec_nuit(32'd0), .rec_ts(32'd0),
    .rec_ps_a(4'd0), .rec_ps_a_v(1'b0), .rec_ps_b(4'd0), .rec_ps_b_v(1'b0),
    .rec_pts(33'd0), .rec_pts_v(1'b0), .rec_pts_b(33'd0), .rec_pts_b_v(1'b0),
    .stc(stc), .stc_run(stc_run), .pick_ph(pick_ph)
  );

  integer i;
  initial begin
    repeat (4) @(posedge clk); #1 rst_n=1;
    repeat (3) @(negedge clk);
    @(negedge clk); frame0=1;
    @(negedge clk); frame0=0;
    wait(dut.aligned===1'b1);
    @(negedge clk); aanc=1;
    @(negedge clk); aanc=0;
    wait(stc_run===1'b1);
    if (stc !== 33'd100) $fatal(1,"anchor failed: STC=%0d",stc);
    pause=1;
    if (dut.rf_m1 !== 20'd450639 || dut.p_pick !== 20'd428280)
      $fatal(1,"NTSC 240p grid mismatch: period=%0d pickup=%0d",dut.rf_m1,dut.p_pick);
    force dut.rp = 20'd428280;
    #1;
    if (pick_ph !== 1'b1) $fatal(1,"NTSC 240p pickup phase not aligned to fixed-line grid");
    release dut.rp;
    dut.rp = 20'd450639;
    @(posedge clk); #1;
    if (dut.rp !== 20'd0) $fatal(1,"NTSC 240p refresh phase did not wrap at RF: %0d",dut.rp);
    @(posedge clk); #1;
    if (dut.rp !== 20'd1) $fatal(1,"NTSC 240p refresh phase did not continue after wrap");
    for (i=0; i<32; i=i+1) begin
      @(posedge clk); #1;
      if (stc !== 33'd100) $fatal(1,"pause advanced STC at 240p dot %0d",i);
    end

    // The menu selects PAL 288p after playback ends. The old 59.94 Hz
    // phase is discarded until its matching frame0, then the fixed-line PAL
    // grid's pickup point must arrive at line 299 (517569 cycles).
    std=2;
    wait(dut.aligned===1'b0);
    if (pick_ph !== 1'b0) $fatal(1,"stale pickup phase survived the mode change");
    repeat (3) @(negedge clk);
    @(negedge clk); frame0=1;
    @(negedge clk); frame0=0;
    wait(dut.aligned===1'b1);
    if (dut.rf_m1 !== 20'd540071 || dut.p_pick !== 20'd517569)
      $fatal(1,"PAL 288p grid mismatch: period=%0d pickup=%0d",dut.rf_m1,dut.p_pick);
    force dut.rp = 20'd517569;
    #1;
    if (pick_ph !== 1'b1) $fatal(1,"PAL 288p pickup phase not aligned to fixed-line grid");
    release dut.rp;
    dut.rp = 20'd540071;
    @(posedge clk); #1;
    if (dut.rp !== 20'd0) $fatal(1,"PAL 288p refresh phase did not wrap at RF");
    @(posedge clk); #1;
    if (dut.rp !== 20'd1) $fatal(1,"PAL 288p refresh phase did not continue after wrap");
    for (i=0; i<32; i=i+1) begin
      @(posedge clk); #1;
      if (stc !== 33'd100) $fatal(1,"pause advanced STC after PAL mode change at dot %0d",i);
    end
    $display("PASS paused STC with continuing 240p grid; mode change restarts PAL grid");
    $finish;
  end
endmodule
