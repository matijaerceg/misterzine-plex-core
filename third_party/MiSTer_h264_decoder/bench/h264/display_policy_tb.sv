`timescale 1ns/1ps
`default_nettype none

module display_policy_tb;
    logic [2:0] profile;
    logic [1:0] match_refresh;
    logic playing;
    logic [1:0] source_std;
    wire [1:0] video_out, raster_std;
    wire interlaced;
    wire [2:0] effective_profile;

    display_policy dut (.*);

    task automatic check_mode(input [1:0] out, input il, input [1:0] std, input [2:0] eff, input [255:0] why);
        #1;
        if ({video_out, interlaced, raster_std, effective_profile} !== {out, il, std, eff})
            $fatal(1, "%0s: got out=%0d il=%0d std=%0d effective=%0d", why, video_out, interlaced, raster_std, effective_profile);
    endtask

    initial begin
        // Fitted profiles use steady-line 59.94/50 timings. Exact 60 stays available in Native.
        profile = 0; match_refresh = 0; playing = 0; source_std = 0;
        check_mode(1, 1, 0, 0, "480i 59.94 idle");
        source_std = 1; check_mode(1, 1, 0, 0, "480i exact 60 source maps to steady 59.94");

        // Match Off restores 480i when a 50 Hz picture plays; Match On selects 576i before
        // its first picture (playing represents disp_ctl's prepared-head rate_v).
        source_std = 2; playing = 1;
        check_mode(1, 1, 0, 0, "match off ignores 50 Hz for selected 480i profile");
        match_refresh = 1; check_mode(1, 1, 2, 2, "match on selects 576i at prepared head");
        playing = 0; check_mode(1, 1, 0, 0, "idle restores 480i after 50 Hz playback");

        // Progressive and Native profiles preserve their scan mode while switching family.
        profile = 1; playing = 1; check_mode(2, 0, 2, 3, "480p profile matches 50 Hz as 576p");
        profile = 2; source_std = 1; check_mode(1, 1, 0, 0, "576i profile maps exact 60 source to 480i");
        profile = 4; check_mode(3, 0, 1, 4, "Native HDMI matches exact 60");
        match_refresh = 0; check_mode(3, 0, 1, 4, "Native HDMI follows exact-60 playback automatically");
        source_std = 2; check_mode(3, 0, 0, 4, "Native HDMI requires match for 50 Hz");

        // 24/25 fps source mapping arrives as its selected 50 Hz class; idle restores the menu.
        source_std = 2; match_refresh = 1; check_mode(3, 0, 2, 4, "Native HDMI matches 25 fps film speed");
        playing = 0; check_mode(3, 0, 0, 4, "Native HDMI restores 59.94 menu default");
        source_std = 1; check_mode(3, 0, 0, 4, "Native HDMI idle clamps exact-60 source");
        profile = 7; check_mode(1, 1, 0, 0, "invalid profile safely falls back to 480i");

        profile = 0; playing = 1; match_refresh = 2; source_std = 2;
        check_mode(1, 1, 2, 2, "legacy match setting safely resolves to 50/60");
        source_std = 1; check_mode(1, 1, 0, 0, "legacy match setting retains 59.94 family");
        $display("PASS: display_policy_tb");
        $finish;
    end
endmodule

`default_nettype wire
