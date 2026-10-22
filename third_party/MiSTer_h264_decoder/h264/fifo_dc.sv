// h264/fifo_dc.sv -- dual-clock FIFO (the one h264/vidfeed_cdc.sv needs)
//
// Written here rather than harvested: MiSTer_DVD's fifo_dc is a wrapper around the
// MPEG-2 decoder's xilinx_fifo_dc (rtl/mpeg2/wrappers.v), a tree docs/harvest.md
// classes X. Same port subset, same semantics, so vidfeed_cdc's proven read adapter
// carries over unchanged:
//
//   PULL read port: assert rd_en with empty low; dout and valid arrive the NEXT
//   rd_clk cycle (one registered read of the memory -- an M10K/MLAB sync read, never
//   an async read, CLAUDE.md "LUT-RAM").
//   Writing when full or reading when empty does nothing and destroys nothing.
//
// Cummings' gray-code pointers (SNUG 2002 "Simulation and Synthesis Techniques for
// Asynchronous FIFO Design"): each side keeps a binary pointer and its gray form, the
// other side's gray pointer crosses through two flops; full and empty are REGISTERED
// from the next-pointer compare, so they are pessimistic by one cycle each way and
// never wrong. Depth 2**AW; AW+1-bit pointers tell full from empty.
//
// Resets: one per domain, both active-low, asserted asynchronously; the parent must
// release each one synchronously to its clock (h264/cdc.sv cdc_reset for the clk_dec
// side). Either side may leave reset first: a side still in reset holds its pointer at
// zero, which the other side reads as empty / not full, so no byte is lost or invented.

`default_nettype none

module fifo_dc #(
    parameter int DW = 9,      // data width
    parameter int AW = 5       // depth 2**AW
) (
    // write side
    input  wire          wr_clk,
    input  wire          wr_rst_n,
    input  wire [DW-1:0] din,
    input  wire          wr_en,
    output logic         full,
    output logic [AW:0]  wr_free,       // slots free as the write side sees them (pessimistic:
                                        // the read pointer arrives two wr_clk cycles late)

    // read side
    input  wire          rd_clk,
    input  wire          rd_rst_n,
    output logic [DW-1:0] dout,
    input  wire          rd_en,
    output logic         empty,
    output logic         valid          // dout holds the word popped in the previous cycle
);

    logic [DW-1:0] mem [0:(1<<AW)-1];

    // every pointer is declared here: each side's always block reads the other's
    logic [AW:0] wbin, wgray;            // write: binary pointer and its gray form
    logic [AW:0] wq1_rgray, wq2_rgray;   // the read pointer, synchronised into wr_clk
    logic [AW:0] rbin, rgray;            // read: binary pointer and its gray form
    logic [AW:0] rq1_wgray, rq2_wgray;   // the write pointer, synchronised into rd_clk

    // ---- write side ----------------------------------------------------------------
    wire  [AW:0] wbin_nx  = wbin + {{AW{1'b0}}, (wr_en && !full)};
    wire  [AW:0] wgray_nx = (wbin_nx >> 1) ^ wbin_nx;
    // full: the next write pointer equals the read pointer with its two MSBs inverted
    wire         full_nx  = (wgray_nx == {~wq2_rgray[AW:AW-1], wq2_rgray[AW-2:0]});

    // the synchronised read pointer back in binary (gray -> binary prefix XOR), for wr_free
    logic [AW:0] wq2_rbin;
    always_comb begin
        wq2_rbin[AW] = wq2_rgray[AW];
        for (int i = AW - 1; i >= 0; i--) wq2_rbin[i] = wq2_rbin[i + 1] ^ wq2_rgray[i];
    end
    wire  [AW:0] occ_nx = wbin_nx - wq2_rbin;
    localparam [AW:0] DEPTH = 1 << AW;   // no N'(expr) casts: Quartus 17 (CLAUDE.md)

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin <= '0; wgray <= '0; full <= 1'b0; wr_free <= DEPTH;
            wq1_rgray <= '0; wq2_rgray <= '0;
        end else begin
            wbin <= wbin_nx; wgray <= wgray_nx; full <= full_nx;
            wr_free <= DEPTH - occ_nx;
            wq1_rgray <= rgray; wq2_rgray <= wq1_rgray;
        end
    end
    always_ff @(posedge wr_clk)
        if (wr_en && !full) mem[wbin[AW-1:0]] <= din;

    // ---- read side -------------------------------------------------------------------
    wire  [AW:0] rbin_nx  = rbin + {{AW{1'b0}}, (rd_en && !empty)};
    wire  [AW:0] rgray_nx = (rbin_nx >> 1) ^ rbin_nx;
    wire         empty_nx = (rgray_nx == rq2_wgray);

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin <= '0; rgray <= '0; empty <= 1'b1; valid <= 1'b0;
            rq1_wgray <= '0; rq2_wgray <= '0;
        end else begin
            rbin <= rbin_nx; rgray <= rgray_nx; empty <= empty_nx;
            rq1_wgray <= wgray; rq2_wgray <= rq1_wgray;
            valid <= rd_en && !empty;
        end
    end
    always_ff @(posedge rd_clk)
        if (rd_en && !empty) dout <= mem[rbin[AW-1:0]];

endmodule

`default_nettype wire
