// h264/vidfeed_cdc.sv -- elementary-stream byte CDC: ps_demux (clk_sys 27 MHz) ->
// the H.264 front end (clk_dec 96.43 MHz)
//
// Harvested from MiSTer_DVD's dvd/vidfeed_cdc.sv (docs/harvest.md, class S). The
// surgery: an own h264/fifo_dc.sv (the DVD's wrapped the MPEG-2 tree's Xilinx FIFO);
// one reset per clock domain instead of one shared (the DVD passed a clk_sys reset
// straight into the clk_dec registers); and the END-OF-TITLE FLUSH below, which the
// MPEG-2 decoder did not need and an Annex-B parser does. The read adapter is the
// DVD's, unchanged, for the reason its header gave:
//
// CORRECTNESS (this is the whole point of the module): the read adapter keeps AT MOST
// ONE outstanding pop and NEVER overwrites an unconsumed head byte. A naive "pop
// whenever the head looks free" adapter drops a byte if rd_ready deasserts while a pop
// is already in flight -- the arriving byte clobbers the still-unconsumed head. That
// dropped a byte from the MPEG bitstream and garbled EVERY clip. The 3-state pull
// below is trivially correct: it only issues a pop from IDLE, then waits for that
// exact byte, holds it until consumed, and only then returns to IDLE to pop again.
// The ceiling is one byte per three rd_clk cycles = 32 MB/s at 96.43 MHz against the
// Level 3.0 maximum of 1.25 MB/s, so the per-byte latency is never a throughput limit.
//
// THE FLUSH. nal_parser holds a NAL unit's last byte back until the next start code
// says it was the last; the title's final NAL unit has no next start code, so the
// front end needs es_flush once the stream is over. wr_flush is umd_reader's
// title_done (a clk_sys level: every item streamed and the reader's cache drained).
// That says nothing about the bytes still inside ps_stream_fifo and ps_demux, which
// keep arriving for a while, so the flush is issued only once the level has crossed AND
// the FIFO and the head have then been empty for FLUSH_IDLE consecutive rd_clk cycles:
// the upstream holds at most a few dozen bytes after title_done and moves at one byte
// per clk_sys cycle, so 4096 rd_clk cycles (~50 us) of silence is a whole order of
// magnitude beyond anything a live drain can pause for. The window is counted from
// the level's arrival, never before it: a FIFO that was quiet for ages while the
// reader waited on the card, then received the title's last bytes in the same breath
// as title_done, would otherwise be flushed with those bytes still upstream (the chain
// bench's first run found exactly that: a flush 4 cycles after the level). One pulse
// per title: the level must drop (a new mount resets everything) before another can
// fire. rd_flushed is the level "the pulse went out" for the HUD.
//
// The 9th data bit is ps_demux's vid_mark (the PTS mark rides with its byte), carried
// for P5's PTS association; the front end ignores it today.

`default_nettype none

module vidfeed_cdc #(
    parameter int FLUSH_IDLE = 4096,
    // the byte's width with its sideband: 9 = {mark, byte}; 42 = {pts[32:0], mark, byte}
    // in emu since P5c (the PES PTS rides with the marked byte into clk_dec, in order --
    // a separate PTS crossing would have to be matched to marks it is not 1:1 with)
    parameter int DW = 9
) (
    // write side -- ps_demux / clk_sys
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire  [DW-1:0] wr_data,   // {[vid_pts,] vid_mark, vid_byte}
    input  wire        wr_valid,     // ps_demux vid_valid
    output wire        wr_ready,     // -> ps_demux vid_ready (= FIFO not full)
    input  wire        wr_flush,     // level: the title is over (umd_reader title_done)

    // read side -- the front end / clk_dec
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    output wire  [DW-1:0] rd_data,   // -> {[pts,] mark, h264_top es_byte}
    output wire        rd_valid,     // -> h264_top es_valid (held until rd_ready)
    input  wire        rd_ready,     // <- h264_top es_ready
    output logic       rd_flush,     // one-cycle pulse -> h264_top es_flush
    output logic       rd_flushed    // level: the flush pulse has been issued
);
    wire        full, empty, fifo_valid;
    wire [DW-1:0] fifo_dout;

    assign wr_ready = ~full;

    // ---- read-side pull adapter (3 states; one byte at a time) ----
    localparam [1:0] S_IDLE = 2'd0,   // head empty: pop one byte if FIFO non-empty
                     S_WAIT = 2'd1,   // pop issued: wait for its data (fifo_valid)
                     S_FULL = 2'd2;   // head holds a byte: present until consumed
    logic [1:0] st;
    logic [DW-1:0] head;

    wire take  = (st == S_FULL) & rd_ready;       // the front end consumes the head byte
    wire rd_en = (st == S_IDLE) & ~empty;         // exactly one pop, only from IDLE

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            st   <= S_IDLE;
            head <= '0;
        end else begin
            case (st)
            S_IDLE: if (~empty)      st <= S_WAIT;            // rd_en high this cycle
            S_WAIT: if (fifo_valid) begin head <= fifo_dout; st <= S_FULL; end
            S_FULL: if (take)        st <= S_IDLE;
            default:                 st <= S_IDLE;
            endcase
        end
    end

    // The DVD adapter's rd_valid was "byte taken this cycle" (a consume pulse); the
    // front end wants a held valid it answers with ready, so the head is presented as
    // valid for as long as it holds a byte. take is the same event in both forms.
    assign rd_data  = head;
    assign rd_valid = (st == S_FULL);

    // 32-deep is ample for a CDC + the per-byte handshake (upstream ps_stream_fifo
    // and the reader's 16 KB cache provide the real buffering); keeping it small
    // relieves routing congestion in the dense HPS-bridge region.
    fifo_dc #(.DW(DW), .AW(5)) u_fifo (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .din      (wr_data),
        .wr_en    (wr_valid & ~full),
        .full     (full),
        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .dout     (fifo_dout),
        .rd_en    (rd_en),
        .empty    (empty),
        .valid    (fifo_valid)
    );

    // ---- the end-of-title flush (header) ----
    logic        fl_q1, fl_q2;                    // wr_flush, synchronised into rd_clk
    logic [12:0] idle_cnt;                        // rd_clk cycles of nothing to feed, since the level
    wire         quiet = empty && (st == S_IDLE);
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            fl_q1 <= 1'b0; fl_q2 <= 1'b0; idle_cnt <= 13'd0; rd_flush <= 1'b0; rd_flushed <= 1'b0;
        end else begin
            fl_q1 <= wr_flush; fl_q2 <= fl_q1;
            if (!quiet || !fl_q2)                  idle_cnt <= 13'd0;
            else if (idle_cnt != FLUSH_IDLE[12:0]) idle_cnt <= idle_cnt + 13'd1;
            rd_flush <= fl_q2 && quiet && (idle_cnt == FLUSH_IDLE[12:0]) && !rd_flushed;
            if (rd_flush) rd_flushed <= 1'b1;
            if (!fl_q2)   rd_flushed <= 1'b0;
        end
    end

endmodule

`default_nettype wire
