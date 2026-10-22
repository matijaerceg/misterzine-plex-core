// h264/sfifo.sv -- single-clock FIFO with a held valid/ready output (first-word-fall-
// through), the memory in M10K: one synchronous read port, one write port (never an
// async read of the array, CLAUDE.md "LUT-RAM").
//
// Two parts: a plain RAM FIFO whose read returns the word ONE cycle after the request,
// and a two-entry skid in registers that presents the head (dout / dout_valid held
// until rd_en). A RAM read is issued only when the skid is guaranteed to have room
// for the word when it lands, so nothing is ever dropped and a pop can happen every
// cycle. `count` is every word held (RAM + in flight + skid); `full` is the RAM's.
//
// Used as the SE FIFO between the front end and the reconstruction (48-bit words) and
// inside the memory client. Depth 2**AW (+ 2 in the skid).

`default_nettype none

module sfifo #(
    parameter int DW = 48,
    parameter int AW = 9
) (
    input  wire           clk,
    input  wire           rst_n,
    input  wire  [DW-1:0] din,
    input  wire           wr_en,
    output logic          full,
    output logic [DW-1:0] dout,
    output logic          dout_valid,
    input  wire           rd_en,
    output logic [AW+1:0] count
);

    localparam [AW:0] DEPTH = 1 << AW;

    logic [DW-1:0] mem [0:(1<<AW)-1];
    logic [AW:0]   wptr, rptr, ram_n;
    logic [DW-1:0] ram_q;
    logic          ram_q_valid;           // ram_q landed this cycle (pushed into the skid at the next edge)
    logic [1:0]    sk_n;                  // skid occupancy 0..2
    logic [DW-1:0] sk1;                   // the word behind the head (dout is the head)

    wire pop   = dout_valid && rd_en;
    wire wr_ok = wr_en && !full;
    // room for the landing word and for this issue's word: skid after this cycle <= 1, i.e.
    // sk_n + ram_q_valid - pop <= 1. The reader's pop arrives late (its consumer's decision),
    // so both outcomes are precomputed from registers and pop only selects (clk_dec 103.85
    // retime: rd_en -> the add -> the compare -> ram_n's add -> full's compare was 8.8 ns)
    wire [2:0] sk_land = {1'b0, sk_n} + {2'b0, ram_q_valid};
    wire room_pop = (sk_land <= 3'd2);
    wire room_nop = (sk_land <= 3'd1);
    wire ram_nz   = (ram_n != '0);
    wire rd_ok = ram_nz && (pop ? room_pop : room_nop);
    // full next: ram_n + wr_ok - rd_ok == DEPTH, from ram_n's two top values (a write needs
    // !full, so ram_n == DEPTH only holds or drops)
    wire at_top  = (ram_n == DEPTH);
    wire at_top1 = (ram_n == DEPTH - 1'b1);

    always_ff @(posedge clk) begin
        if (wr_ok) mem[wptr[AW-1:0]] <= din;
        if (rd_ok) ram_q <= mem[rptr[AW-1:0]];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= '0; rptr <= '0; ram_n <= '0; full <= 1'b0; count <= '0;
            ram_q_valid <= 1'b0; sk_n <= 2'd0; dout <= '0; sk1 <= '0; dout_valid <= 1'b0;
        end else begin
            if (wr_ok) wptr <= wptr + 1'b1;
            if (rd_ok) rptr <= rptr + 1'b1;
            ram_n <= ram_n + {{AW{1'b0}}, wr_ok} - {{AW{1'b0}}, rd_ok};
            full  <= !rd_ok && (at_top || (at_top1 && wr_ok));
            count <= count + {{(AW+1){1'b0}}, wr_ok} - {{(AW+1){1'b0}}, pop};
            ram_q_valid <= rd_ok;
            // the skid
            case ({ram_q_valid, pop})
                2'b10: begin
                    if (sk_n == 2'd0) dout <= ram_q; else sk1 <= ram_q;
                    sk_n <= sk_n + 2'd1;
                end
                2'b01: begin
                    dout <= sk1;
                    sk_n <= sk_n - 2'd1;
                end
                2'b11: begin
                    if (sk_n == 2'd1) dout <= ram_q;
                    else begin dout <= sk1; sk1 <= ram_q; end
                end
                default: ;
            endcase
            dout_valid <= (sk_n + {1'b0, ram_q_valid} - {1'b0, pop}) != 2'd0;
        end
    end

endmodule

`default_nettype wire
