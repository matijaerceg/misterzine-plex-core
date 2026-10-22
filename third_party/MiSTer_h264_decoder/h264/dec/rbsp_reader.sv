// h264/dec/rbsp_reader.sv -- the bit reader of the header parsers (7.2, 9.1)
//
// Fetches RBSP bytes on demand from a held byte handshake and serves requests one
// bit per cycle: u(n), ue(v), se(v), the cabac_alignment_one_bit run and the
// more_rbsp_data() query. Bit-serial on purpose: a slice header is a few hundred
// bits and the longest one the format allows (a 32-reference pred_weight_table with
// every flag set, ~4 kbit) is still small beside the slice's macroblocks, and the
// serial machine has no barrel shifter and no lookahead to get wrong.
//
// Exactly one byte is ever held, and it is fetched only when a bit is needed (or a
// more_rbsp_data query peeks): after cabac_alignment_one_bit nothing is buffered, so
// the parent can hand the rest of the NAL unit to the CABAC engine byte for byte.
//
// more_rbsp_data() (7.2) needs the position of the rbsp_stop_one_bit. nal_parser
// strips the trailing zeros, so the NAL unit's last byte is the one holding the stop
// bit: more data remains iff the current byte is not the last one, or its unread
// bits hold a 1 above the lowest set bit. (Slice data is never asked -- cabac_zero_words
// may follow its stop bit -- only the PPS tail is, 7.3.2.2.)
//
// Requests (held valid/ready, one registered response each):
//   kind 0 BITS   n = 1..31 bits, MSB first                  -> rsp_val
//   kind 1 UE     Exp-Golomb ue(v), up to 31 leading zeros   -> rsp_val
//   kind 2 SE     se(v) (9.1.1 mapping of ue)                -> rsp_val (two's complement)
//   kind 3 ALIGN1 read cabac_alignment_one_bit until aligned; a 0 sets err_align
//   kind 4 MORE   more_rbsp_data()                            -> rsp_val[0]
//
// Errors (sticky until flush): err_ue (more than 31 leading zeros), err_align, err_eos
// (a bit needed past the last byte; read as 0 so the parser terminates).

`default_nettype none

module rbsp_reader (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,              // drop the held byte, clear the errors (a new NAL unit)

    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    input  wire        in_last,
    output logic       in_ready,

    input  wire        req_valid,
    output logic       req_ready,
    input  wire  [2:0] req_kind,
    input  wire  [4:0] req_n,
    output logic       rsp_valid,
    output logic [31:0] rsp_val,

    output logic       aligned,            // no partially read byte is held
    output logic       err_ue,
    output logic       err_align,
    output logic       err_eos
);

    localparam [2:0] K_BITS = 3'd0, K_UE = 3'd1, K_SE = 3'd2, K_ALIGN1 = 3'd3, K_MORE = 3'd4;

    typedef enum logic [2:0] {S_IDLE, S_BITS, S_UE_LZ, S_UE_SUF, S_ALIGN, S_MORE} state_t;
    state_t state;

    logic [7:0]  cur;
    logic        cur_v, cur_last;
    logic [2:0]  pos;                      // bits of cur already consumed
    logic        ended;                    // the last byte has been consumed entirely
    logic [4:0]  cnt;                      // bits still to read (BITS / UE suffix)
    logic [4:0]  lz;                       // leading zeros of the ue(v)
    logic [31:0] acc;
    logic        is_se;

    assign aligned = !cur_v || (pos == 3'd0);
    wire   bit_now = cur[3'd7 - pos];
    wire   consuming = (state == S_BITS) || (state == S_UE_LZ) || (state == S_UE_SUF) ||
                       ((state == S_ALIGN) && !aligned);
    wire   need_byte = (consuming && !cur_v) || ((state == S_MORE) && !cur_v);
    assign in_ready  = need_byte && !ended;
    // a bit is available this cycle: from the held byte, or as a zero past the end
    wire   bit_avail = cur_v || ended;
    wire   bit_val   = cur_v ? bit_now : 1'b0;

    assign req_ready = (state == S_IDLE);

    // the unread bits of the last byte, for more_rbsp_data
    wire [7:0] rem      = cur & (8'hFF >> pos);
    wire [7:0] rem_m1   = rem - 8'd1;
    wire       more_now = !cur_last || ((rem & rem_m1) != 8'd0);

    // the ue(v) value once the suffix's last bit (this cycle's) is in: (1 << lz) - 1 + suffix
    wire [31:0] ue_acc = ((32'd1 << lz) - 32'd1) + {acc[30:0], bit_val};
    // se(v): k odd -> (k + 1) / 2, even -> -(k / 2)   (9.1.1)
    wire [31:0] se_of_k = ue_acc[0] ? ({1'b0, ue_acc[31:1]} + 32'd1) : (32'd0 - {1'b0, ue_acc[31:1]});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; cur <= 8'd0; cur_v <= 1'b0; cur_last <= 1'b0; pos <= 3'd0; ended <= 1'b0;
            cnt <= 5'd0; lz <= 5'd0; acc <= 32'd0; is_se <= 1'b0;
            rsp_valid <= 1'b0; rsp_val <= 32'd0;
            err_ue <= 1'b0; err_align <= 1'b0; err_eos <= 1'b0;
        end else begin
            rsp_valid <= 1'b0;
            if (flush) begin
                cur_v <= 1'b0; pos <= 3'd0; ended <= 1'b0; state <= S_IDLE;
                err_ue <= 1'b0; err_align <= 1'b0; err_eos <= 1'b0;
            end else begin
                // fetch
                if (in_valid && in_ready) begin
                    cur <= in_byte; cur_v <= 1'b1; cur_last <= in_last; pos <= 3'd0;
                end
                // consume one bit
                if (consuming && bit_avail) begin
                    if (cur_v) begin
                        pos <= pos + 3'd1;
                        if (pos == 3'd7) begin
                            cur_v <= 1'b0;
                            if (cur_last) ended <= 1'b1;
                        end
                    end else err_eos <= 1'b1;
                end

                case (state)
                    S_IDLE: if (req_valid) begin
                        acc <= 32'd0; lz <= 5'd0; is_se <= 1'b0;
                        case (req_kind)
                            K_BITS:   begin cnt <= req_n; state <= S_BITS; end
                            K_UE:     state <= S_UE_LZ;
                            K_SE:     begin is_se <= 1'b1; state <= S_UE_LZ; end
                            K_ALIGN1: state <= S_ALIGN;
                            default:  state <= S_MORE;
                        endcase
                    end
                    S_BITS: if (bit_avail) begin
                        acc <= {acc[30:0], bit_val};
                        cnt <= cnt - 5'd1;
                        if (cnt == 5'd1) begin
                            rsp_val <= {acc[30:0], bit_val}; rsp_valid <= 1'b1; state <= S_IDLE;
                        end
                    end
                    S_UE_LZ: if (bit_avail) begin
                        if (bit_val) begin
                            if (lz == 5'd0) begin
                                rsp_val <= 32'd0; rsp_valid <= 1'b1; state <= S_IDLE;
                            end else begin
                                cnt <= lz; state <= S_UE_SUF;
                            end
                        end else if (lz == 5'd31) begin
                            err_ue <= 1'b1;
                            rsp_val <= 32'd0; rsp_valid <= 1'b1; state <= S_IDLE;
                        end else lz <= lz + 5'd1;
                    end
                    S_UE_SUF: if (bit_avail) begin
                        acc <= {acc[30:0], bit_val};
                        cnt <= cnt - 5'd1;
                        if (cnt == 5'd1) begin
                            rsp_val <= is_se ? se_of_k : ue_acc; rsp_valid <= 1'b1; state <= S_IDLE;
                        end
                    end
                    S_ALIGN: begin
                        if (aligned) begin
                            rsp_val <= 32'd0; rsp_valid <= 1'b1; state <= S_IDLE;
                        end else if (bit_avail && !bit_val) err_align <= 1'b1;
                    end
                    S_MORE: begin
                        if (cur_v) begin
                            rsp_val <= {31'd0, more_now}; rsp_valid <= 1'b1; state <= S_IDLE;
                        end else if (ended) begin
                            rsp_val <= 32'd0; rsp_valid <= 1'b1; state <= S_IDLE;
                        end
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
