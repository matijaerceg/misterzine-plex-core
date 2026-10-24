`timescale 1ns/1ps
module rgb_dither_tb;
  reg clk=0, rst_n=0, ce=0, en=0, interlaced=0;
  reg [11:0] hp=0,vp=0;
  wire [7:0] r,g,b;
  reg [7:0] expected[0:8];
  integer i,j,k,total,seen[0:255],count=0;
  reg [7:0] held;
  `include "rgb_dither.svh"
  always #5 clk=~clk;
  disp_reader dut(.clk(clk),.rst_n(rst_n),.ce(ce),.gradient_dither(en),
    .h_pos(hp),.v_pos(vp),.il(interlaced),.prog240(1'b0),.r(r),.g(g),.b(b));
  task tick;
    begin @(posedge clk); #1; @(negedge clk); end
  endtask
  initial begin
    for(i=0;i<256;i=i+1) seen[i]=0;
    for(i=0;i<16;i=i+1) for(j=0;j<16;j=j+1)
      seen[rgb_dither_rank(i[3:0],j[3:0])]=seen[rgb_dither_rank(i[3:0],j[3:0])]+1;
    for(i=0;i<256;i=i+1) if(seen[i]!=1) $fatal(1,"rank permutation");
    for(k=0;k<256;k=k+1) begin
      total=0;
      for(i=0;i<16;i=i+1) for(j=0;j<16;j=j+1)
        total=total+((k+rgb_dither_rank(i[3:0],j[3:0]))>>8);
      if(total!=k) $fatal(1,"mean preservation");
    end
    tick(); rst_n=1;
    // Fixed neutral Q8 value 10.25. Exercise the real reader's rounding and clipping.
    force dut.p_c=20'sd2624;
    force dut.p_ecr=20'sd0; force dut.p_dcb=20'sd0;
    force dut.p_dg=20'sd0; force dut.p_eg=20'sd0; force dut.s6_in=1'b1;
    ce=1; repeat(16) tick();
    if(r!=10 || g!=10 || b!=10) $fatal(1,"off equivalence");
    en=1; repeat(5) tick();
    // Sync and frame latch have settled. Threshold tracks a pixel through eight delays.
    for(i=0;i<512;i=i+1) begin
      hp=i%16; vp=(i/16)%16;
      for(j=8;j>0;j=j-1) expected[j]=expected[j-1];
      expected[0]=(2624+rgb_dither_rank(hp[3:0],vp[3:0]))>>8;
      ce=1; tick();
      if(i>=9 && (r!=expected[8] || g!=r || b!=r)) $fatal(1,"pixel alignment or neutral gray at %0d",i);
      held=r; ce=0; tick(); tick();
      if(r!=held) $fatal(1,"CE hold");
    end
    // Interlaced two-dot pixels must retain the same threshold on both dots.
    interlaced=1;
    for(i=0;i<512;i=i+1) begin
      hp=i%32; vp=(i/32)%16;
      for(j=8;j>0;j=j-1) expected[j]=expected[j-1];
      expected[0]=(2624+rgb_dither_rank(hp[4:1],vp[3:0]))>>8;
      ce=1; tick();
      if(i>=9 && (r!=expected[8] || g!=r || b!=r)) $fatal(1,"two-dot alignment");
    end
    hp=4;vp=4;en=0;repeat(6) tick();
    if(dut.gd_frame!=1) $fatal(1,"setting changed mid-frame");
    hp=0;vp=0;repeat(12) tick();
    if(dut.gd_frame!=0 || r!=10 || g!=10 || b!=10) $fatal(1,"switch Off at frame origin");
    force dut.p_c=-20'sd1000; ce=1; repeat(3) tick();
    if(r!=0 || g!=0 || b!=0) $fatal(1,"black clipping");
    force dut.p_c=20'sd100000; repeat(3) tick();
    if(r!=255 || g!=255 || b!=255) $fatal(1,"white clipping");
    force dut.s6_in=1'b0; repeat(3) tick();
    if(r!=0 || g!=0 || b!=0) $fatal(1,"blanking");
    $display("rgb_dither: PASS permutation, means, Off, alignment, CE hold, neutral gray, two-dot mapping, frame latch, clipping, blanking");
    $finish;
  end
endmodule
