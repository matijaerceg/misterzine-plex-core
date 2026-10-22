// h264/dec/nal_parser.sv -- Annex B byte stream -> NAL unit payloads (RBSP bytes)
//
// Finds the start codes (B.1: 00 00 01, any number of leading zeros), removes the
// emulation-prevention bytes (7.4.1: a 03 after two zeros is dropped) and drops the
// trailing_zero_8bits before the next start code, exactly as tools/h264_fe_ref.py's
// nal_units() does. Bytes before the first start code are discarded.
//
// Out: a held byte handshake. out_first marks a NAL unit's first byte (its header:
// forbidden_zero_bit, nal_ref_idc, nal_unit_type -- the parent reads it from the
// stream), out_last its final RBSP byte. A NAL unit's last byte is only known when the
// next start code arrives, so it is held back until then: the parser keeps at most
// one undecided byte plus the count of zeros seen after it (a saturating 0..3: two
// zeros can precede an EPB or a start code; three or more only a start code), and
// emits them once the byte after the zeros says what they were. in_flush (a level,
// served when the output is free) closes the stream: the held byte goes out as last.
//
// POSITIONS (P5c, the PTS association: h264/dec/au_pts.sv): in_pos counts the input
// bytes taken since reset (modulo 2^PW), and out_sc_pos, valid with out_first, is the
// position of that NAL unit's 3-byte start code (the first 00 of 00 00 01 -- a leading
// zero_byte is not counted), where ISO 13818-1 says the access unit it opens commences.
// tools/h264_fe_ref.py nal_units_pos() counts the same way.
//
// in_ready never depends on in_byte: a non-zero byte is always taken in one cycle
// (the previously held byte leaves through the output register the same cycle, and
// the queued zeros drain in the cycles after, in order, before the new byte can go).

`default_nettype none

module nal_parser #(
    parameter int PW = 24
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    output logic       in_ready,
    input  wire        in_flush,           // end of stream: release the held byte as last

    output logic [7:0] out_byte,
    output logic       out_valid,
    input  wire        out_ready,
    output logic       out_first,
    output logic       out_last,

    output logic [PW-1:0] in_pos,          // the position of the next input byte
    output logic [PW-1:0] out_sc_pos,      // with out_first: the NAL unit's start code
    output logic       flushed             // pulse: a flush has been served (the held byte is out)
);

    logic [7:0] held_b;
    logic       held_v, held_first;
    logic [1:0] zeros;                     // zeros seen since the held byte (saturating at 3)
    logic [1:0] zq;                        // zeros decided as data, still to be emitted
    logic       started;                   // a start code has been seen
    logic       first_pend;                // the next data byte is a NAL header
    logic       flush_pend;
    logic [PW-1:0] sc_pos;                 // the last start code seen (for the next header)
    logic [PW-1:0] held_sc;                // the held byte's, when it is a header

    wire out_free = !out_valid || out_ready;
    wire is_zero  = (in_byte == 8'h00);
    wire is_sc    = (zeros >= 2'd2) && (in_byte == 8'h01);
    wire is_epb   = (zeros >= 2'd2) && (in_byte == 8'h03);

    assign in_ready = out_free && (zq == 2'd0) && !flush_pend;
    wire take = in_valid && in_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            held_b <= 8'd0; held_v <= 1'b0; held_first <= 1'b0;
            zeros <= 2'd0; zq <= 2'd0; started <= 1'b0; first_pend <= 1'b0; flush_pend <= 1'b0;
            out_byte <= 8'd0; out_valid <= 1'b0; out_first <= 1'b0; out_last <= 1'b0;
            in_pos <= '0; sc_pos <= '0; held_sc <= '0; out_sc_pos <= '0; flushed <= 1'b0;
        end else begin
            if (take) in_pos <= in_pos + 1'b1;
            flushed <= 1'b0;
            if (in_flush) flush_pend <= 1'b1;
            if (out_ready) out_valid <= 1'b0;

            if (out_free && flush_pend) begin
                // end of stream: the held byte is the last one; pending zeros were trailing
                if (zq != 2'd0) begin
                    out_valid <= 1'b1; out_byte <= 8'd0; out_first <= 1'b0; out_last <= 1'b0;
                    zq <= zq - 2'd1;
                end else begin
                    if (held_v) begin
                        out_valid <= 1'b1; out_byte <= held_b; out_first <= held_first; out_sc_pos <= held_sc; out_last <= 1'b1;
                    end
                    held_v <= 1'b0; zeros <= 2'd0; flush_pend <= 1'b0; started <= 1'b0;
                    flushed <= 1'b1;
                end
            end else if (out_free && zq != 2'd0) begin
                out_valid <= 1'b1; out_byte <= 8'd0; out_first <= 1'b0; out_last <= 1'b0;
                zq <= zq - 2'd1;
            end else if (take) begin
                if (is_zero) begin
                    if (zeros != 2'd3) zeros <= zeros + 2'd1;
                end else if (is_sc) begin
                    if (held_v) begin
                        out_valid <= 1'b1; out_byte <= held_b; out_first <= held_first; out_sc_pos <= held_sc; out_last <= 1'b1;
                    end
                    held_v <= 1'b0; zeros <= 2'd0; started <= 1'b1; first_pend <= 1'b1;
                    sc_pos <= in_pos - 2'd2;       // the 01 is at in_pos: 00 00 01 starts 2 before
                end else if (!started) begin
                    zeros <= 2'd0;
                end else begin
                    if (held_v) begin
                        out_valid <= 1'b1; out_byte <= held_b; out_first <= held_first; out_sc_pos <= held_sc; out_last <= 1'b0;
                    end
                    // the zeros were data; an EPB keeps its last zero as the new held byte
                    // (it may be the NAL unit's final byte: a 03 is appended after a
                    // trailing 00, 7.4.1) and the 03 itself is dropped
                    zq <= is_epb ? zeros - 2'd1 : zeros;
                    held_b <= is_epb ? 8'h00 : in_byte;
                    held_v <= 1'b1;
                    held_first <= first_pend;
                    if (first_pend) held_sc <= sc_pos;
                    first_pend <= 1'b0;
                    zeros <= 2'd0;
                end
            end
        end
    end

endmodule

`default_nettype wire
