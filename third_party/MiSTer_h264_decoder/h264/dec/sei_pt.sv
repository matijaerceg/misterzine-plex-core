// h264/dec/sei_pt.sv -- the SEI NAL unit walker and the picture timing interpreter
// (7.3.2.3, D.1.3; roadmap P5c, docs/display.md)
//
// WALK (an SEI NAL unit's payload bytes, emulation prevention already removed by
// nal_parser): sei_message() is byte-aligned -- payloadType and payloadSize are runs of
// 0xFF plus a last byte, then payloadSize payload bytes. The NAL unit ends with the
// rbsp_trailing_bits byte 0x80 (nal_parser strips trailing zeros, so it is the unit's
// last byte), met where a message would start. The first PT_BYTES bytes of a
// pic_timing payload (type 1) are kept; every other type, and the rest of a pic_timing,
// is skipped. A malformed unit (a type or size cut by the unit's end, a payload running
// into its last byte, a last byte that is not 0x80 at a message boundary) ends the walk
// with err_walk; a pic_timing it cut leaves NOTHING pending (a new pic_timing always
// replaces the pending one when it starts). The walk never waits for bytes past in_last.
//
// WHY BUFFER: pic_timing's syntax depends on the SPS active for the access unit
// (CpbDpbDelaysPresentFlag, the delay lengths, pic_struct_present_flag), and that SPS is
// activated by the access unit's first slice, which FOLLOWS the SEI (D.2.3 NOTE 1). So
// the payload waits here and is interpreted when the parent has that slice's SPS
// (interp_start); its fields go out then -- after the slice header, before the
// macroblocks, as tools/h264_fe_ref.py records them.
//
// WHY 9 BYTES: only the fields up to pic_struct are read -- cpb_removal_delay and
// dpb_output_delay (at most 32 bits each) and pic_struct (4): 68 bits. The clock
// timestamps after pic_struct are not parsed: nothing downstream uses them, and the
// walker skips them by payloadSize (legal: the rest of a known payload, not a bound hit).
// (A first draft kept a 64-byte buffer and parsed every clock timestamp field.)
//
// INTERPRET: the needed length is checked UP FRONT -- a payload shorter than the delays
// + pic_struct the SPS makes present emits nothing (pt_short; the display infers
// pic_struct). With neither flag, no picture timing SEI may be present (D.2.3): dropped,
// pt_struct. Then bit-serial from the front of the buffer (a shift register), each field
// emitted in syntax order. pic_struct is emitted, then checked against Table D-1:
// reserved 9..15, or a field_pic_flag / bottom_field_flag mismatch, counts pt_struct
// (what to show is the display's business). Every counter is a pulse; the parent counts.

`default_nettype none

module sei_pt #(
    parameter int PT_BYTES = 9
) (
    input  wire        clk,
    input  wire        rst_n,

    // the walk: an SEI NAL unit's payload (after its header byte)
    input  wire        start,              // pulse: the payload follows
    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    input  wire        in_last,
    output logic       in_ready,
    output logic       done,               // pulse: the walk ended (the parent drains the rest)

    // the buffered pic_timing (valid until consumed by an interpretation or dropped)
    output logic       pending,
    input  wire        drop,               // forget it (a new access unit opened)

    // interpretation with the access unit's first slice's SPS
    input  wire        interp_start,       // pulse (with pending)
    input  wire        cpb_dpb_present,
    input  wire  [4:0] cpb_len_m1,
    input  wire  [4:0] dpb_len_m1,
    input  wire        pic_struct_present,
    input  wire        field_pic,
    input  wire        bottom_field,
    output logic       interp_done,        // pulse

    // header words (K_HDR_WORD: aux = field id, val)
    output logic       se_valid,
    input  wire        se_ready,
    output logic [7:0] se_aux,
    output logic [31:0] se_val,

    // pulses, counted by the parent
    output logic       err_walk,           // a malformed SEI NAL unit
    output logic       pt_short,           // a pic_timing shorter than its syntax
    output logic       pt_struct,          // pic_struct against Table D-1, or a forbidden SEI
    output logic [3:0] last_pic_struct     // the last pic_struct parsed (the HUD)
);

`include "h264/dec/h264_fields.svh"

    localparam int BW = 8 * PT_BYTES;

    // ---- the walk ----------------------------------------------------------------------
    typedef enum logic [1:0] {W_IDLE, W_TYPE, W_SIZE, W_PAY} wstate_t;
    wstate_t ws;
    logic [15:0] ptype;                    // saturating (only type 1 matters)
    logic [31:0] psize, pleft;
    logic [3:0]  wr_n;                     // pic_timing bytes kept (0..PT_BYTES)
    logic        at_boundary;              // W_TYPE with no byte of this message read yet
    logic [BW-1:0] pbuf;                   // the kept bytes, first byte in the top bits
    logic [31:0] pt_size;                  // the pending payload's payloadSize

    assign in_ready = (ws != W_IDLE);
    wire take = in_valid && in_ready;

    // ---- the interpreter ---------------------------------------------------------------
    typedef enum logic [2:0] {I_IDLE, I_CPB, I_DPB, I_PS, I_PS_CHK, I_BIT, I_EMIT} istate_t;
    istate_t is, i_ret;
    logic [BW-1:0] ibuf;                   // the payload being read, next bit at the top
    logic [5:0]  i_left;
    logic [31:0] i_acc;
    logic [7:0]  i_id;

    assign se_valid = (is == I_EMIT);
    assign se_aux   = i_id;
    assign se_val   = i_acc;

    // the bits the SPS makes present, and the bits the payload has (both <= 72 here:
    // min(payloadSize, PT_BYTES) bytes kept)
    wire [6:0]  need  = (cpb_dpb_present ? ({2'd0, cpb_len_m1} + {2'd0, dpb_len_m1} + 7'd2) : 7'd0) +
                        (pic_struct_present ? 7'd4 : 7'd0);
    // (registered off pt_size, which settles long before interp_start -- the compare, the
    // subtract and the 72-bit shift in the start cycle were 10.6 ns: P5b)
    logic [35:0] have;
    logic [3:0]  pt_shb;                   // bytes to shift a short payload left by
    always_ff @(posedge clk) begin
        have   <= (pt_size > PT_BYTES) ? PT_BYTES * 8 : {pt_size, 3'b000};
        pt_shb <= PT_BYTES - ((pt_size > PT_BYTES) ? PT_BYTES : pt_size[3:0]);
    end

`define RD(n, id, ret) begin i_left <= n; i_acc <= 32'd0; i_id <= id; i_ret <= ret; is <= I_BIT; end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ws <= W_IDLE; ptype <= '0; psize <= '0; pleft <= '0; wr_n <= '0; at_boundary <= 1'b0;
            pbuf <= '0; pt_size <= '0; pending <= 1'b0; done <= 1'b0;
            is <= I_IDLE; i_ret <= I_IDLE; ibuf <= '0; i_left <= '0; i_acc <= '0; i_id <= '0;
            interp_done <= 1'b0; err_walk <= 1'b0; pt_short <= 1'b0; pt_struct <= 1'b0; last_pic_struct <= '0;
        end else begin
            done <= 1'b0; interp_done <= 1'b0;
            err_walk <= 1'b0; pt_short <= 1'b0; pt_struct <= 1'b0;
            if (drop) pending <= 1'b0;

            // ---- walk
            case (ws)
                W_IDLE: if (start) begin ws <= W_TYPE; ptype <= '0; at_boundary <= 1'b1; end
                W_TYPE: if (take) begin
                    at_boundary <= 1'b0;
                    if (in_last) begin
                        // at a message boundary the unit's last byte is rbsp_trailing_bits;
                        // anywhere else a type cut by the end
                        if (!at_boundary || in_byte != 8'h80) err_walk <= 1'b1;
                        ws <= W_IDLE; done <= 1'b1;
                    end else if (in_byte == 8'hFF) begin
                        ptype <= (ptype > 16'hFE00) ? 16'hFFFF : ptype + 16'd255;
                    end else begin
                        ptype <= (ptype > 16'hFF00) ? 16'hFFFF : ptype + {8'd0, in_byte};
                        psize <= '0; ws <= W_SIZE;
                    end
                end
                W_SIZE: if (take) begin
                    if (in_last) begin
                        err_walk <= 1'b1; ws <= W_IDLE; done <= 1'b1;      // a size cut by the end
                        if (ptype == 16'd1) pending <= 1'b0;
                    end else if (in_byte == 8'hFF) begin
                        psize <= psize + 32'd255;
                    end else begin
                        pleft <= psize + {24'd0, in_byte};
                        wr_n <= '0;
                        if (ptype == 16'd1) begin
                            pending <= 1'b0;                               // a new pic_timing replaces the old
                            pt_size <= psize + {24'd0, in_byte};
                        end
                        if (psize + {24'd0, in_byte} == 32'd0) begin
                            if (ptype == 16'd1) pending <= 1'b1;           // empty: interpretation says short
                            ptype <= '0; at_boundary <= 1'b1; ws <= W_TYPE;
                        end else ws <= W_PAY;
                    end
                end
                W_PAY: if (take) begin
                    if (ptype == 16'd1 && wr_n < PT_BYTES[3:0]) begin
                        pbuf <= {pbuf[BW-9:0], in_byte};
                        wr_n <= wr_n + 4'd1;
                    end
                    pleft <= pleft - 32'd1;
                    if (in_last) begin
                        // the payload ran into the unit's last byte (the trailing byte follows a payload)
                        err_walk <= 1'b1; ws <= W_IDLE; done <= 1'b1;
                    end else if (pleft == 32'd1) begin
                        if (ptype == 16'd1) pending <= 1'b1;
                        ptype <= '0; at_boundary <= 1'b1; ws <= W_TYPE;
                    end
                end
                default: ws <= W_IDLE;
            endcase

            // ---- interpret
            case (is)
                I_IDLE: if (interp_start) begin
                    pending <= 1'b0;
                    // the kept bytes, left-aligned (a payload shorter than PT_BYTES shifted in fewer)
                    ibuf <= pbuf << {pt_shb, 3'b000};
                    if (!cpb_dpb_present && !pic_struct_present) begin
                        pt_struct <= 1'b1; interp_done <= 1'b1;            // D.2.3: none may be present
                    end else if ({29'd0, need} > have) begin
                        pt_short <= 1'b1; interp_done <= 1'b1;
                    end else is <= I_CPB;
                end
                I_CPB: if (cpb_dpb_present) `RD({1'b0, cpb_len_m1} + 6'd1, F_cpb_removal_delay, I_DPB)
                       else is <= I_PS;
                I_DPB: `RD({1'b0, dpb_len_m1} + 6'd1, F_dpb_output_delay, I_PS)
                I_PS: if (pic_struct_present) `RD(6'd4, F_pic_struct, I_PS_CHK)
                      else begin interp_done <= 1'b1; is <= I_IDLE; end
                I_PS_CHK: begin
                    last_pic_struct <= i_acc[3:0];
                    // Table D-1: the field_pic_flag / bottom_field_flag restriction, reserved values
                    case (i_acc[3:0])
                        4'd0:                               if (field_pic) pt_struct <= 1'b1;
                        4'd1:                               if (!field_pic || bottom_field) pt_struct <= 1'b1;
                        4'd2:                               if (!field_pic || !bottom_field) pt_struct <= 1'b1;
                        4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8: if (field_pic) pt_struct <= 1'b1;
                        default:                            pt_struct <= 1'b1;
                    endcase
                    interp_done <= 1'b1; is <= I_IDLE;
                end
                // one bit a cycle off the top of the buffer
                I_BIT: begin
                    i_acc <= {i_acc[30:0], ibuf[BW-1]};
                    ibuf <= {ibuf[BW-2:0], 1'b0};
                    if (i_left == 6'd1) is <= I_EMIT;
                    else i_left <= i_left - 6'd1;
                end
                I_EMIT: if (se_ready) is <= i_ret;
                default: is <= I_IDLE;
            endcase
        end
    end
`undef RD

endmodule

`default_nettype wire
