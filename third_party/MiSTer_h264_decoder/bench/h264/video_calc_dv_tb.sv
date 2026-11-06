`timescale 1ns/1ps

// Exercise the real raster and framework measurement, then read the words that
// MiSTer Main copies into DV1's SPD packet. Expected porches come from the
// raster timings, in 27 MHz HDMI samples, not from video_calc's counters.
module video_calc_dv_tb;
    reg clk_vid = 0, clk_sys = 0, clk_100 = 0;
    always #6 clk_vid = ~clk_vid;
    always #18 clk_sys = ~clk_sys;
    always #5 clk_100 = ~clk_100;
    reg rst_n = 0;
    reg [1:0] phase = 0;
    always @(posedge clk_vid)
        phase <= !rst_n ? 0 : phase == 2 ? 0 : phase + 1'b1;
    wire tick = phase == 2;
    reg il = 0, p240 = 0;
    reg [1:0] std = 0;
    wire dot, hs, vs, de, f1, ce_pix;
    // Match vid_out's one-clock CE pulse alongside each held output dot.
    reg ce = 0;
    always @(posedge clk_vid) ce <= dot;
    sync_gen raster (
        .clk(clk_vid), .clk_en(tick), .dot(dot), .rst_n(rst_n),
        .interlaced(il), .prog240(p240), .std(std), .nat(1'b0),
        .g_w(12'd0), .g_h(12'd0), .g_l(12'd0),
        .g_nt(12'd0), .g_last(12'd0),
        .h_sync(hs), .v_sync(vs), .pixel_en(de), .field(f1),
        .ce_pix(ce_pix)
    );
    reg direct_video = 0;
    reg [4:0] par_num = 0;
    wire [15:0] dout;
    video_calc dut (
        .clk_100(clk_100), .clk_vid(clk_vid), .clk_sys(clk_sys),
        .ce_pix(ce & ce_pix), .de(de), .hs(hs), .vs(vs),
        .vs_hdmi(vs), .f1(f1), .new_vmode(1'b0),
        .video_rotated(1'b0), .direct_video(direct_video),
        .par_num(par_num), .dout(dout)
    );

    task automatic read_word(input integer address, output reg [15:0] value);
        @(negedge clk_sys);
        par_num = address;
        repeat (2) @(negedge clk_sys);
        value = dout;
    endtask

    task automatic expect_word(input integer address, input integer expected,
                               input string label);
        reg [15:0] value;
        read_word(address, value);
        if (value !== expected[15:0])
            $fatal(1, "[%s] word %0d got %0d expected %0d", label, address, value, expected);
    endtask

    integer mode, porch, repetition, height, frame_clocks;
    reg [15:0] ordinary [1:20];
    reg [15:0] value;
    initial begin
        if (!$value$plusargs("mode=%d", mode)) mode = 0;
        case (mode)
            0: begin porch=60;  repetition=1; height=480; frame_clocks=3*858*525; end
            1: begin porch=120; repetition=2; height=480; frame_clocks=3*1716*525; il=1; end
            2: begin porch=124; repetition=2; height=240; frame_clocks=3*1720*262; p240=1; end
            3: begin porch=68;  repetition=1; height=576; frame_clocks=3*864*625; std=2; end
            4: begin porch=136; repetition=2; height=576; frame_clocks=3*1728*625; std=2; il=1; end
            5: begin porch=139; repetition=2; height=288; frame_clocks=3*1731*312; std=2; p240=1; end
            default: $fatal(1, "invalid mode");
        endcase
        repeat (8) @(negedge clk_vid);
        rst_n = 1;
        // video_calc has no reset: let the counters acquire full frames.
        repeat (il ? 8 : 4) @(negedge vs);
        @(posedge vs);
        expect_word(2, 720, "width");
        expect_word(4, height, "height");
        expect_word(14, 720*3*repetition, "clock-count");
        expect_word(16, 3*repetition, "ordinary-repetition");
        expect_word(17, 3*porch, "ordinary-crop");
        expect_word(19, frame_clocks & 65535, "frame-count-low");
        expect_word(20, frame_clocks >> 16, "frame-count-high");
        for (integer i=1; i<=20; i=i+1) read_word(i, ordinary[i]);
        direct_video = 1;
        expect_word(16, repetition, "dv-repetition");
        expect_word(17, porch, "dv-crop");
        // Vertical offsets, dimensions and Y/C clock measurements retain their
        // original units. Changing the DV flag must affect only words 16/17.
        for (integer i=1; i<=20; i=i+1) begin
            if (i != 16 && i != 17) begin
                read_word(i, value);
                if ($isunknown(value) || value !== ordinary[i])
                    $fatal(1, "[unchanged] word %0d got %0d expected %0d", i, value, ordinary[i]);
            end
        end
        direct_video = 0;
        expect_word(16, 3*repetition, "ordinary-repetition");
        expect_word(17, 3*porch, "ordinary-crop");
        $display("PASS: video_calc_dv_tb mode=%0d porch=%0d repetition=%0d", mode, porch, repetition);
        $finish;
    end
    initial begin
        #500000000;
        $fatal(1, "[timeout] raster did not complete");
    end
endmodule
