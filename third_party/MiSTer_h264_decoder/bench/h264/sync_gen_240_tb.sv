`timescale 1ns/1ps
module sync_gen_240_tb;
  reg clk=0, rst_n=0;
  always #5 clk=~clk;
  reg [1:0] std;
  reg interlaced=0, prog240=1;
  wire dot;
  wire [11:0] h_pos,v_pos,lines,last_line;
  wire pixel_en,h_sync,v_sync,h_blank,v_blank,frame_tick,field,ce_pix,mode_il,mode_240p;
  sync_gen dut(.clk(clk),.clk_en(1'b1),.dot(dot),.rst_n(rst_n),.interlaced(interlaced),.prog240(prog240),.std(std),
    .nat(1'b0),.g_w(12'd0),.g_h(12'd0),.g_l(12'd0),.g_nt(12'd0),.g_last(12'd0),
    .lines(lines),.last_line(last_line),.h_pos(h_pos),.v_pos(v_pos),.pixel_en(pixel_en),.h_sync(h_sync),.v_sync(v_sync),
    .h_blank(h_blank),.v_blank(v_blank),.frame_tick(frame_tick),.field(field),.ce_pix(ce_pix),.mode_il(mode_il),.mode_std(),.mode_240p(mode_240p));

  integer s, dots, active_lines, line_dots, expected_dots, expected_lines, expected_active, expected_line_dots;
  integer prev_h, prev_v, seen_tick;
  initial begin
    for (s=0; s<3; s=s+1) begin
      std=s; rst_n=0; repeat(4) @(posedge clk); #1 rst_n=1;
      wait(mode_240p===1'b1); wait(frame_tick===1'b1);
      dots=1; active_lines=1; line_dots=1; prev_h=0; prev_v=0; seen_tick=1;
      if (s==0) begin expected_line_dots=1720; expected_lines=262; expected_active=240; end
      else if (s==1) begin expected_line_dots=1720; expected_lines=262; expected_active=240; end
      else begin expected_line_dots=1731; expected_lines=312; expected_active=288; end
      expected_dots=expected_line_dots*expected_lines;
      begin : frame_measure
        forever begin
          @(posedge clk); #1;
          if (frame_tick && seen_tick) begin
            disable frame_measure;
          end
          dots=dots+1;
          if (field !== 1'b0 || mode_il !== 1'b0) $fatal(1,"240p leaked interlace at std %0d",s);
          if (pixel_en !== ((h_pos<1440) && (v_pos<expected_active))) $fatal(1,"bad active window at %0d,%0d",h_pos,v_pos);
          if (h_sync !== ((h_pos >= ((s==2)?1464:1472)) && (h_pos < ((s==2)?1592:1596)))) $fatal(1,"bad horizontal sync at dot %0d",h_pos);
          if (h_pos==0 && v_sync !== ((v_pos>=((s==2)?292:244)) && (v_pos<((s==2)?295:247)))) $fatal(1,"bad full-line vertical sync at line %0d",v_pos);
          if (h_pos==0) begin
            if (prev_h>=0) begin
              if (line_dots != expected_line_dots) $fatal(1,"std %0d variable line length %0d expected %0d",s,line_dots,expected_line_dots);
            end
            line_dots=0;
            if (pixel_en) active_lines=active_lines+1;
          end
          line_dots=line_dots+1;
          if (h_pos<1440 && ce_pix !== ~h_pos[0]) $fatal(1,"bad pixel repeat phase");
          if (h_pos>=1440 && pixel_en) $fatal(1,"active area exceeded 1440 dots");
          prev_h=h_pos; prev_v=v_pos;
        end
      end
      if (dots != expected_dots) $fatal(1,"std %0d frame dots %0d expected %0d",s,dots,expected_dots);
      if (active_lines != expected_active) $fatal(1,"std %0d active lines %0d expected %0d",s,active_lines,expected_active);
      if (last_line != expected_lines-1) $fatal(1,"std %0d physical last line %0d",s,last_line);
      $display("PASS 240p std=%0d dots=%0d line-dots=%0d active=%0d",s,dots,expected_line_dots,active_lines);
    end
    // Leave 240p playback for the selected PAL progressive menu raster, then
    // switch that PAL menu to interlace. Each new mode must restart cleanly and
    // settle onto its own exact cadence without a phantom tick.
    prog240=0; interlaced=0; std=2;
    wait(mode_240p===1'b0); wait(frame_tick===1'b1);
    dots=1;
    begin : pal_progressive_frame
      forever begin @(posedge clk); #1; if (frame_tick) disable pal_progressive_frame; dots=dots+1; end
    end
    if (dots != 540000 || lines != 576 || last_line != 624 || mode_il !== 1'b0)
      $fatal(1,"240p->PAL progressive transition: dots=%0d lines=%0d last=%0d il=%b",dots,lines,last_line,mode_il);
    interlaced=1;
    wait(mode_il===1'b1); wait(frame_tick===1'b1);
    dots=1;
    begin : pal_interlace_field
      forever begin @(posedge clk); #1; if (frame_tick) disable pal_interlace_field; dots=dots+1; end
    end
    if (dots != 540864 || field !== 1'b1)
      $fatal(1,"PAL menu interlace transition: first field dots=%0d field=%b",dots,field);
    $display("PASS transitions 240p -> PAL 576p -> PAL 576i");
    $finish;
  end
endmodule
