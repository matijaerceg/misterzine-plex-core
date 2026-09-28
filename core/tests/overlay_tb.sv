`timescale 1ns/1ps
// The overlay's edges land on the same pixels at both pixel clocks, and the
// brightness takes the picture, the overlay and the bar sprite down alike.
// In the 15 kHz modes the line ends leave black, the overlay's too.
module overlay_tb;
reg clk=0,reset=1;
always #5 clk=~clk;
reg [1:0] mode=2;
integer divider=0;
wire ce=(divider==0);
reg [10:0] hc=850;
reg [9:0] vc=0;
wire [7:0] r,g,b;
integer x,y,bank,word,level=256,er,eg,eb,d,checked=0,ox=100;
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
function integer out(input integer v);
 begin
  v=(v*level)>>8;
  out=(v>252)?255:v+d;
 end
endfunction
always @(posedge clk) if(!reset && ce && vc>0 && hc<720) begin
 x=hc;y=vc;
 d=((x%2)^(y%2))*2+(y%2);
 if(x>=400 && x<410) begin er=8'hE0;eg=8'hE0;eb=8'hE0; end       // bar sprite
 else if(x>=ox && x<ox+200) begin er=255;eg=0;eb=0; end          // opaque red overlay
 else begin er=8'h40;eg=8'h80;eb=8'hC0; end                      // the picture
 er=out(er);eg=out(eg);eb=out(eb);
 if(mode<2 && (x<12 || x>=712)) begin er=0;eg=0;eb=0; end       // line ends
 #1;
 if(r!==er || g!==eg || b!==eb)
  $fatal(1,"mode=%0d level=%0d pixel (%0d,%0d) got %0d,%0d,%0d expected %0d,%0d,%0d",mode,level,x,y,r,g,b,er,eg,eb);
 checked=checked+1;
end
task setup;
begin
 reset=1;hc=850;vc=0;divider=0;
 force dut.st=0;force dut.valid=1;force dut.h_yuv=0;force dut.h_width=720;force dut.h_height=480;
 force dut.o_en=1;force dut.o_x=ox;force dut.o_w=200;force dut.o_y=0;force dut.o_h=480;
 force dut.b_en=1;force dut.b_x=400;force dut.b_w=10;force dut.b_y=0;force dut.b_h=480;force dut.b_rgb=24'hE0E0E0;
 force dut.d_en=0;
 force dut.lvl=level;
 dut.rd_half=0;dut.wr_half=1;
 for(bank=0;bank<2;bank=bank+1)
  for(word=0;word<512;word=word+1) begin
   dut.lb0[bank*512+word]=64'h00_4080C0_00_4080C0;
   dut.lb3[bank*512+word]=64'hFF_FF0000_FF_FF0000;
  end
 repeat(5) @(negedge clk);reset=0;
 wait(vc==4);@(negedge clk);
end
endtask
initial begin
 level=256;mode=2;setup();mode=0;setup();
 level=64;mode=2;setup();mode=0;setup();
 level=256;ox=0;mode=2;setup();mode=0;setup();   // the overlay from pixel 0
 if(checked!=12960)$fatal(1,"coverage %0d",checked);
 $display("PASS overlay edges and sprite at both pixel clocks, full and quarter brightness, black 15 kHz line ends over the overlay");
 $finish;
end
initial begin #40000000;$fatal(1,"timeout");end
endmodule
