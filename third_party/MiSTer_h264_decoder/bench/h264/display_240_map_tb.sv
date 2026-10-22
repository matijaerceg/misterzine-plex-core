`timescale 1ns/1ps

// Focused address-mapping checks for progressive 240p/288p. Physical raster rows are
// doubled into the logical 480/576 plane, while doubled dots map to one horizontal pixel.
module display_240_map_tb;
  reg clk = 0, ce = 0, rst_n = 0;
  reg [11:0] h_pos = 0, v_pos = 0, last_line = 261, rast_last = 261;
  reg prog240 = 1, il = 0, pal = 0;
  reg [11:0] lines = 480;
  always #5 clk = ~clk;

  disp_reader reader (
    .clk(clk), .ce(ce), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(1'b0),
    .il(il), .prog240(prog240), .pal(pal), .lines(lines), .last_line(last_line)
  );
  ovl_plane overlay (
    .clk(clk), .ce(ce), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(1'b0),
    .il(il), .prog240(prog240), .pal(pal), .rast_w(12'd720), .rast_h(lines),
    .rast_lines(lines), .rast_last(rast_last)
  );

  task check(input condition, input [255:0] message);
    begin
      if (!condition) $fatal(1, "FAIL: %0s", message);
    end
  endtask

  initial begin
    #1;
    v_pos = 0; h_pos = 0; #1;
    check(reader.nxt_line == 12'd2 && overlay.nxt_line == 12'd2, "first physical row maps to logical row 2 next");
    check(reader.x == 0 && overlay.x == 0, "dot 0 maps to pixel 0");
    h_pos = 1; #1;
    check(reader.px0 && reader.x == 0 && overlay.x == 0, "second dot repeats pixel 0");
    h_pos = 2; #1;
    check(!reader.px0 && reader.x == 1 && overlay.x == 1, "third dot advances to pixel 1");

    v_pos = 1; #1;
    check(reader.nxt_line == 12'd4 && overlay.nxt_line == 12'd4, "physical row 1 advances to logical row 4");
    check(reader.raster_y == 12'd2 && overlay.raster_y == 12'd2, "physical row 1 addresses logical y=2");
    v_pos = 238; #1;
    check(reader.nxt_line == 12'd478 && overlay.nxt_line == 12'd478, "last active physical row advances to logical row 478");
    v_pos = 239; #1;
    check(reader.nxt_line == 12'd480 && overlay.nxt_line == 12'd480, "first blank physical row reaches logical height");
    v_pos = 261; #1;
    check(reader.nxt_line == 0 && overlay.nxt_line == 0, "NTSC physical frame wraps without field parity");
    last_line = 311; rast_last = 311; pal = 1; lines = 576; v_pos = 311; #1;
    check(reader.nxt_line == 0 && overlay.nxt_line == 0, "PAL physical frame wraps without field parity");
    check(reader.raster_y == 12'd622 && overlay.raster_y == 12'd622, "PAL final physical row maps to logical y=622");

    // Existing progressive 480p behavior must remain one logical row per physical line.
    prog240 = 0; pal = 0; lines = 480; last_line = 524; rast_last = 524; v_pos = 0; #1;
    check(reader.nxt_line == 1 && overlay.nxt_line == 1, "480p mapping remains unchanged");
    $display("PASS: display_240_map_tb");
    $finish;
  end
endmodule
