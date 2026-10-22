// h264/ring_stat.sv -- the HPS interface's status block, built once a raster frame (roadmap
// Phase 3; docs/architecture.md "The HPS interface, v0.1": the control block's words 0-31
// and, since 0.5, 40-47 and (0.10) 80-87 -- the telemetry). clk_sys, reset by the PLL lock alone (the
// heartbeat never restarts on an OSD reset).
//
// At each `frame` pulse, if h264/ring_rd.sv's status FIFO has room for a whole frame, the
// sequence advances and the 48 words are fetched in the write order (0.5: words 0-23, then
// 40-47, (0.10) then 80-87, then 24-31 -- seq_tail, word 31, stays the last one written, so the
// seqlock covers the second and third regions: tools/ring_layout.py WRITE_ORDER) and pushed
// with their index:
//   a clk_sys word   from ring_words_sys (a mux on sys_ix: combinational, one cycle);
//   a clk_mem word   through a cdc_snap_ix whose source muxes ring_words_mem;
//   a clk_dec word   the same through ring_words_dec.
// Which is which: RI_MEM_WORDS / RI_DEC_WORDS (tools/ring_layout.py). After every eighth
// word st_grp pulses: ring_rd's engine writes that group as one burst. Word 3 (seq_head)
// and word 31 (seq_tail) carry the same `seq`, so a reader that sees them equal read a
// frame that no write overlapped. A frame with no room WAITS for it (2026-10-05, fix/cleanup: the
// input job's 24 words still in the 64-word FIFO left 40 free, and the frame was skipped --
// run_ring_in.sh's I1 / I2 RED since 0.10's 48 words): ring_rd's engine drains a group in
// microseconds, a frame is 16.7 ms, so the frame runs a few microseconds late, whole; a waiting
// frame holds the input job off (in_go needs !frame_now). Only a frame pulse that arrives while
// one is still waiting is lost and counted (n_skips): the heartbeat then stands still a frame,
// which is how a reader sees it.
//
// 0.6: A SECOND JOB, the input region (words 48-71, h264/ring_in.sv; docs/architecture.md
// "Input (interface 0.6)"). When ring_in asks (in_req) and the FIFO has room for its 24 words,
// in_go pulses -- combinational, the cycle the job is granted, so ring_in's in_head has
// advanced by the first word's push (in_head and in_tail then carry the same count) and its
// state is frozen from that cycle -- and the 24 words are pushed
// in order, one a cycle (all clk_sys: in_busy high meanwhile), three groups of eight. A job
// runs whole, so the groups of the two jobs never interleave (ring_rd's engine takes a
// group's address from its first word). A frame has priority; a frame pulse that arrives
// while a job runs is kept pending, not lost. Room is checked per job: 48 (0.10; was 40) or 24
// free words.
//
// Quartus 17: no functions, no N'() casts.

`default_nettype none

module ring_stat (
    input  wire         clk,               // clk_sys
    input  wire         rst_n,             // the PLL lock alone
    input  wire         frame,             // one pulse a raster frame
    input  wire   [6:0] st_free,           // 0.6: the status FIFO's free words (was st_room: >= 40)
    output logic [31:0] seq,
    output logic [31:0] n_skips,
    // the clk_sys words
    output logic  [6:0] sys_ix,            // 0.10: 7 bits (words 80-87)
    input  wire  [63:0] sys_word,
    // the clk_mem words
    input  wire         mclk,
    input  wire         mrst_n,
    output logic  [5:0] mem_ix,
    input  wire  [63:0] mem_word,
    // the clk_dec words
    input  wire         dclk,
    input  wire         drst_n,
    output logic  [5:0] dec_ix,
    input  wire  [63:0] dec_word,
    // 0.6: the input region's job (h264/ring_in.sv)
    input  wire         in_req,
    output logic        in_go,
    output logic        in_busy,
    output logic  [4:0] in_ix,
    input  wire  [63:0] in_word,
    // into ring_rd's status FIFO
    output logic [63:0] st_word,
    output logic  [6:0] st_ix,             // 0.6: 7 bits (word 71)
    output logic        st_wr,
    output logic        st_grp
);

`include "h264/ring_iface.svh"

    typedef enum logic [1:0] { B_IDLE, B_FETCH, B_WAIT, B_IN } bst_t;
    bst_t        bs;
    logic [5:0]  s;                        // the step, 0 .. RI_NSTAT-1
    logic [6:0]  k;                        // its word: steps 0-23 words 0-23, 24-31 words 40-47, 32-39 (0.10) words 80-87, 40-47 words 24-31
    logic        m_go, d_go, m_busy, d_busy, m_done, d_done;
    logic [63:0] m_data, d_data;
    logic        frame_p;                  // 0.6: a frame arrived while a job ran
    logic [4:0]  j;                        // 0.6: the input job's step (word 48 + j)
    wire         frame_now = frame || frame_p;
    localparam logic [6:0] IN_W0 = RI_IN_WORD[6:0];
    assign in_go = (bs == B_IDLE) && !frame_now && in_req && (st_free >= 7'd24);

    localparam logic [5:0] S_A = RI_STAT_A, S_B = RI_STAT_B, S_C = RI_STAT_C, S_LAST = RI_NSTAT - 1;   // sized, not cast (Quartus 17)
    always_comb begin
        if (s < S_A)      k = {1'b0, s};
        else if (s < S_B) k = {1'b0, s} + 7'd16;           // 24..31 -> 40..47
        else if (s < S_C) k = {1'b0, s} + 7'd48;           // 32..39 -> 80..87 (0.10)
        else              k = {1'b0, s} - 7'd16;           // 40..47 -> 24..31
    end
    // the clk_mem / clk_dec words are all below 64 (ring_layout.py checks it): the masks are 64 bits
    wire is_mem = !k[6] && RI_MEM_WORDS[k[5:0]];
    wire is_dec = !k[6] && RI_DEC_WORDS[k[5:0]];
    wire last   = (s == S_LAST);
    assign sys_ix = k;
    assign in_ix  = j;
    assign in_busy = (bs == B_IN);

    cdc_snap_ix #(.W(64), .IW(6)) u_mem (
        .src_clk(mclk), .src_rst_n(mrst_n), .src_ix(mem_ix), .src_data(mem_word),
        .dst_clk(clk), .dst_rst_n(rst_n), .dst_ix(k[5:0]), .dst_go(m_go),
        .dst_busy(m_busy), .dst_data(m_data), .dst_done(m_done));
    cdc_snap_ix #(.W(64), .IW(6)) u_dec (
        .src_clk(dclk), .src_rst_n(drst_n), .src_ix(dec_ix), .src_data(dec_word),
        .dst_clk(clk), .dst_rst_n(rst_n), .dst_ix(k[5:0]), .dst_go(d_go),
        .dst_busy(d_busy), .dst_data(d_data), .dst_done(d_done));

    assign m_go = (bs == B_FETCH) && is_mem;
    assign d_go = (bs == B_FETCH) && is_dec && !is_mem;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bs <= B_IDLE; s <= '0; seq <= '0; n_skips <= '0; frame_p <= 1'b0; j <= '0;
            st_word <= '0; st_ix <= '0; st_wr <= 1'b0; st_grp <= 1'b0;
        end else begin
            st_wr <= 1'b0; st_grp <= 1'b0;
            if (frame && bs != B_IDLE) frame_p <= 1'b1;
            case (bs)
                B_IDLE: if (frame_now) begin
                    if (st_free >= 7'd48) begin frame_p <= 1'b0; seq <= seq + 32'd1; s <= '0; bs <= B_FETCH; end
                    else begin
                        frame_p <= 1'b1;                         // wait for the room (the engine drains it)
                        if (frame && frame_p) n_skips <= n_skips + 32'd1;   // a frame lost: one already waited
                    end
                end else if (in_go) begin
                    j <= '0; bs <= B_IN;
                end
                B_IN: begin                                      // 0.6: the input region, a word a cycle
                    st_word <= in_word; st_ix <= IN_W0 + {2'd0, j}; st_wr <= 1'b1; st_grp <= (j[2:0] == 3'd7);
                    j <= j + 5'd1;
                    if (j == 5'd23) bs <= B_IDLE;
                end
                B_FETCH: begin
                    if (is_mem || is_dec) bs <= B_WAIT;          // the snapshot was asked (m_go / d_go)
                    else begin                                   // a clk_sys word: now
                        st_word <= sys_word; st_ix <= k; st_wr <= 1'b1; st_grp <= (s[2:0] == 3'd7);
                        s <= s + 6'd1;
                        if (last) bs <= B_IDLE;
                    end
                end
                B_WAIT: if (m_done || d_done) begin
                    st_word <= m_done ? m_data : d_data; st_ix <= k; st_wr <= 1'b1; st_grp <= (s[2:0] == 3'd7);
                    s <= s + 6'd1;
                    if (last) bs <= B_IDLE; else bs <= B_FETCH;
                end
                default: bs <= B_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
