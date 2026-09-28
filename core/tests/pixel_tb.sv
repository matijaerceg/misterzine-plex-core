`timescale 1ns/1ps
module pixel_tb;
reg clk=0,reset=1;
always #5 clk=~clk;
reg [1:0] mode=2;
integer divider=0;
wire ce=(divider==0);
reg [10:0] hc=850;
reg [9:0] vc=0;
wire [7:0] r,g,b;
integer x,y,bank,word,byteidx,value,expected,checked=0;
ddr_scanout dut(.clk(clk),.reset(reset),.DDRAM_BUSY(1'b0),.DDRAM_DOUT(64'd0),.DDRAM_DOUT_READY(1'b0),
 .ce_pix(ce),.hc(hc),.vc(vc),.next_row(vc+10'd1),.active(hc<720),.vs(1'b0),
 .joy0(16'd0),.joy1(16'd0),.ps2_key(11'd0),.scan_status({2'b0,mode}),.r(r),.g(g),.b(b));
always @(posedge clk) if(!reset) begin
 divider <= (divider==((mode==2)?1:3)) ? 0 : divider+1;
 if(ce) begin
  if(hc==857) begin hc<=0;vc<=vc+1;end
  else hc<=hc+1;
 end
end
always @(posedge clk) if(!reset && ce && vc>0 && hc<720) begin
 x=hc;y=vc;
 value=16+((x*13+(y%2)*37)%220);
 expected=((value-16)*298+128)>>8;
 if(expected>255)expected=255;
 if(expected<=252)expected=expected+(((x%2)^(y%2))*2+(y%2));else expected=255;
 if(mode<2 && (x<12 || x>=712)) expected=0;   // the 15 kHz line ends leave black
 #1;
 if(r!==expected || g!==expected || b!==expected)
  $fatal(1,"mode=%d pixel (%d,%d) got %d,%d,%d expected %d",mode,x,y,r,g,b,expected);
 checked=checked+1;
end
task setup;
begin
 reset=1;hc=850;vc=0;divider=0;
 force dut.st=0;force dut.valid=1;force dut.h_yuv=1;force dut.h_width=720;force dut.h_height=480;
 dut.rd_half=0;dut.wr_half=1;
 for(bank=0;bank<2;bank=bank+1) begin
  for(word=0;word<512;word=word+1) begin
   dut.lb0[bank*512+word]=0;
   dut.lb3[bank*512+word]=0;
   for(byteidx=0;byteidx<8;byteidx=byteidx+1)
    dut.lb0[bank*512+word][byteidx*8+:8]=16+(((word*8+byteidx)*13+bank*37)%220);
  end
  for(word=0;word<64;word=word+1) begin
   dut.lb1[bank*64+word]=(word<45)?64'h8080808080808080:0;
   dut.lb2[bank*64+word]=(word<45)?64'h8080808080808080:0;
  end
 end
 repeat(5) @(negedge clk);reset=0;
 wait(vc==4);@(negedge clk);
end
endtask
initial begin
 setup();mode=0;setup();mode=1;setup();
 if(checked!=6480)$fatal(1,"coverage %d",checked);
 $display("PASS all 720 YUV columns, word boundaries and alternating row banks at both pixel clocks; 12/8 black line ends in 480i and 240p only");
 $finish;
end
endmodule
