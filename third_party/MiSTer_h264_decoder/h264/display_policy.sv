// h264/display_policy.sv -- resolve the OSD output profile and playback refresh override.
// The source rate is latched by emu while idle; Match Video Refresh uses it only for a
// prepared or shown picture, so the selected menu profile returns after playback.

`default_nettype none

module display_policy (
    input  wire [2:0] profile,       // 0 480i60, 1 480p60, 2 576i50, 3 576p50, 4 Native HDMI
    input  wire [1:0] match_refresh, // 0 Off, 1 50/60; legacy value 2 is treated as 1
    input  wire       playing,       // rate_v (pre-first-picture) or a shown picture
    input  wire [1:0] source_std,    // 0 59.94, 1 60.00, 2 50 Hz
    output wire [1:0] video_out,     // 1 interlaced, 2 progressive, 3 Native HDMI
    output wire       interlaced,
    output wire [1:0] raster_std,
    output wire [2:0] effective_profile
);

    wire [2:0] safe_profile = (profile <= 3'd4) ? profile : 3'd0;
    wire       native = (safe_profile == 3'd4);
    wire       interlaced_profile = (safe_profile == 3'd0) || (safe_profile == 3'd2);
    wire       pal_profile = (safe_profile == 3'd2) || (safe_profile == 3'd3);
    wire       source_valid = source_std != 2'd3;
    wire [1:0] safe_source_std = source_valid ? source_std : 2'd0;
    // Fitted output uses a steady-line 59.94/50 raster. Exact-60 sources remain
    // available through Native HDMI; fitted profiles map them to the 59.94 family.
    wire [1:0] fitted_source_std = (safe_source_std == 2'd2) ? 2'd2 : 2'd0;

    assign video_out = native ? 2'd3 : interlaced_profile ? 2'd1 : 2'd2;
    assign interlaced = video_out == 2'd1;
    wire [1:0] safe_match_refresh = (match_refresh == 2'd2) ? 2'd1 : match_refresh;
    assign raster_std = native ? ((playing && (safe_match_refresh != 0 || safe_source_std != 2'd2)) ? safe_source_std : 2'd0) :
                        (safe_match_refresh && playing) ? fitted_source_std :
                        (pal_profile && !native) ? 2'd2 :
                        2'd0;
    assign effective_profile = native ? 3'd4 :
                               interlaced_profile ? (raster_std[1] ? 3'd2 : 3'd0) :
                                                    (raster_std[1] ? 3'd3 : 3'd1);

endmodule

`default_nettype wire
