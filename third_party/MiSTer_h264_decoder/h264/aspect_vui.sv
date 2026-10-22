// h264/aspect_vui.sv -- the shown picture's display aspect from its SPS VUI (roadmap P5b,
// docs/display.md)
//
// Table E-1 maps aspect_ratio_idc to the sample aspect ratio sar_w : sar_h (255 =
// Extended_SAR: the SPS's own pair). The display aspect is sar_w * W : sar_h * H, and
// the scaler is given the NEARER of 4:3 and 16:9: 16:9 iff
//     9 * sar_w * W  >  14 * sar_h * H          (14/9 = 1.556, midway 1.333 .. 1.778)
// with W and H in macroblocks (the 16s cancel). SAR 40:33 at 720x480 is 1.82 -> 16:9;
// 10:11 is 1.36 -> 4:3; square pixels at 720x480 (1.5) -> 4:3.
//
// `known` is 0 when the SAR is unspecified: idc 0 (or no VUI), a reserved idc (17..254:
// E.2.1 says decoders read those as unspecified) or an Extended_SAR with a 0 term. The
// caller keeps its fallback then (emu: 16:9, every UMD title measured is anamorphic).
// Cropping is not applied (no disc crops; the display window is the coded picture).
//
// One register stage (clk_sys, relaxed timing: the inputs change only with the latched
// picture's SPS). Bench: bench/h264/run_aspect_vui.sh, every idc x sizes against
// tools/aspect_vui_golden.py (ffmpeg's own SAR table, libavcodec/h264_ps.c).

`default_nettype none

module aspect_vui (
    input  wire         clk,
    input  wire         valid,             // a picture is shown (else known = 0)
    input  wire  [7:0]  aspect_idc,
    input  wire  [15:0] ext_sar_w,         // Extended_SAR (idc 255) only
    input  wire  [15:0] ext_sar_h,
    input  wire  [7:0]  w_mbs,             // PicWidthInMbs
    input  wire  [7:0]  hf_mbs,            // FrameHeightInMbs
    output logic        known,             // the SAR is specified
    output logic        wide,              // 16:9 (else 4:3); meaningful with known
    // P6 (docs/analog.md §5): the resolved SAR for the fit and the exact aspect -- 1 : 1
    // when unspecified (a game or media-server stream is square-pixelled; see emu)
    output logic [15:0] sar_w_o,
    output logic [15:0] sar_h_o
);

    logic [15:0] sw, sh;
    always_comb begin
        case (aspect_idc)
            8'd1:  begin sw = 16'd1;   sh = 16'd1;  end
            8'd2:  begin sw = 16'd12;  sh = 16'd11; end
            8'd3:  begin sw = 16'd10;  sh = 16'd11; end
            8'd4:  begin sw = 16'd16;  sh = 16'd11; end
            8'd5:  begin sw = 16'd40;  sh = 16'd33; end
            8'd6:  begin sw = 16'd24;  sh = 16'd11; end
            8'd7:  begin sw = 16'd20;  sh = 16'd11; end
            8'd8:  begin sw = 16'd32;  sh = 16'd11; end
            8'd9:  begin sw = 16'd80;  sh = 16'd33; end
            8'd10: begin sw = 16'd18;  sh = 16'd11; end
            8'd11: begin sw = 16'd15;  sh = 16'd11; end
            8'd12: begin sw = 16'd64;  sh = 16'd33; end
            8'd13: begin sw = 16'd160; sh = 16'd99; end
            8'd14: begin sw = 16'd4;   sh = 16'd3;  end
            8'd15: begin sw = 16'd3;   sh = 16'd2;  end
            8'd16: begin sw = 16'd2;   sh = 16'd1;  end
            8'd255: begin sw = ext_sar_w; sh = ext_sar_h; end
            default: begin sw = 16'd0; sh = 16'd0; end   // 0 unspecified, 17..254 reserved
        endcase
    end

    // 9 * 16 bits * 8 bits < 2^28; 14 * 16 bits * 8 bits < 2^28
    wire [27:0] lhs = 28'd9  * {12'd0, sw} * {20'd0, w_mbs};
    wire [27:0] rhs = 28'd14 * {12'd0, sh} * {20'd0, hf_mbs};

    always_ff @(posedge clk) begin
        known <= valid && (sw != 16'd0) && (sh != 16'd0);
        wide  <= lhs > rhs;
        sar_w_o <= (valid && sw != 16'd0 && sh != 16'd0) ? sw : 16'd1;
        sar_h_o <= (valid && sw != 16'd0 && sh != 16'd0) ? sh : 16'd1;
    end

endmodule

`default_nettype wire
