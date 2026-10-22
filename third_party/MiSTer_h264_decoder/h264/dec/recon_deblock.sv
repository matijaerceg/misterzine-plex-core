// h264/dec/recon_deblock.sv -- the deblocking filter of one macroblock (8.7, non-MBAFF):
// its vertical edges left to right, then its horizontal edges top to bottom, luma then
// Cb then Cr, in place (docs/h264_recon.md S2.3 step 5)
//
// Three memories of 64-bit words (8 samples, byte 0 = the leftmost), reached through one
// read port (data two cycles after the address is registered) and one write port with
// byte enables:
//   region 0  the current macroblock: luma row y word w at 2y + w, Cb row y at 32 + y,
//             Cr row y at 40 + y
//   region 1  the macroblock to the left, already filtered (the left edge's p samples),
//             the same layout
//   region 2  the bottom rows of the macroblock above, already filtered (the top edge's
//             p samples): luma rows 12..15 at 2(y - 12) + w, Cb rows 6..7 at 8 + (y - 6),
//             Cr rows 6..7 at 10 + (y - 6) -- chroma filtering reads p1, p0 only
// The caller decides the three edge flags of 8.7 (filterLeftMbEdgeFlag,
// filterTopMbEdgeFlag, filterInternalEdgesFlag) and supplies the macroblocks' side info:
// per 4x4 block {nz, per list: pred, the reference picture's identity code, mv}, per
// macroblock intra, I_PCM, QPY and QPC per chroma plane (an I_PCM macroblock's qP is 0 /
// the QPC of QPY 0, 8.7.2 -- passed as pcm_qpc). FilterOffsetA / B are the current
// macroblock's slice's (the slice containing q0).
//
// SEGMENTS of eight lines (docs/h264_recon.md S6: the line-at-a-time engine this
// replaces spent ~25 cycles a filtered line, ~4,000 a macroblock of intra edges):
//   * luma: an edge is two segments (lines 0-7, 8-15), chroma one;
//   * BS, decided first (Nova's idea): a pre-pass over the 32 luma groups (4 lines sharing
//     a 4x4 block pair, per edge and direction) reads the p and q block records -- this
//     macroblock's from a 16-entry RAM recon_mb writes as its motion is known, the left /
//     above ones from l_blk / t_blk -- through deblock_bs (three cycles a group); a chroma
//     group takes the luma edge's bS at the same position (8.7.2). A segment whose groups
//     are all 0 is skipped;
//   * VERTICAL edges STREAM (Nova's pipelined filter, docs/h264_recon.md S6): a line's
//     words are read (one per row for edges 1 / 3, where p and q share the word; two for
//     edges 0 / 2, the p half held a cycle), the line enters deblock_filter as its last
//     word arrives (latency 3; bS 0 passes a line through unchanged), and the result is
//     written the cycle it lands with the byte enables of the samples the filter may
//     change (luma p2..q2, chroma p0 / q0) -- a two-word line's q word the cycle after;
//   * HORIZONTAL edges transpose through eight row registers: the rows p3..q3 (chroma
//     p1..q1) shift in as they are read, the eight positions leave through byte 0 of each
//     row, one a cycle, and the results shift back in at byte 7 as they land -- 8 +
//     latency byte shifts put every result at its own byte -- then the rows p2..q2
//     (chroma p0, q0) shift out to the write port whole (unchanged samples rewritten with
//     their own values, so every write is exact). No sample is ever selected by index.
// ~100 cycles of pre-pass, then per segment: vertical ~reads + 7, horizontal ~reads + 2 +
// 11 + writes (the 8 x 8 buffer engine this replaces: reads + 13 + writes, and ~1,700
// LUTs of byte selection). The segments are sequential: a later edge reads what an
// earlier one wrote, so a segment starts after the previous one's last write has landed.
// Gate: the chain bench against the model's decode-order
// post-deblock pictures (bench/h264/run_recon_top.sh).

`default_nettype none

module recon_deblock (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    output logic        pre_done,          // the bS pre-pass is done: the block records, the
                                           // left / above records and nb_* may change now
    output logic        done,
    output logic        busy,

    input  wire         left_en,
    input  wire         top_en,
    input  wire         int_en,
    input  wire         q_t8_in,           // transform_size_8x8_flag (latched at start): luma edges 1, 3 not filtered
    input  wire         field_pic,
    input  wire signed [4:0] alpha_off,
    input  wire signed [4:0] beta_off,

    // the macroblocks: {pcm_qpc1, pcm_qpc0, qpc1, qpc0, qp, pcm, intra} (32 bits)
    input  wire  [31:0] q_mb_in,           // latched at start: the front moves on to the next
    input  wire  [31:0] l_mb_in,           // macroblock while this one is filtered (the MB
    input  wire  [31:0] t_mb_in,           // overlap, docs/h264_recon.md S6)
    // per 4x4 block: {mvy1, mvx1, code1[7:0], pred1, mvy0, mvx0, code0[7:0], pred0, nz} (83 bits)
    // the current macroblock's 16 block records, written into a RAM as they are known
    // (recon_mb's motion readback, one a cycle); read by the bS pre-pass
    input  wire         rec_we,
    input  wire  [3:0]  rec_wa,
    input  wire  [82:0] rec_wd,
    input  wire         rec_wbank,         // exp/mb-pipeline: the bank the records are written in
    input  wire         rec_rbank,         // ... and the one this macroblock's are in (latched at start)
    input  wire  [4*83-1:0]  l_blk,        // the left macroblock's right column, rows 0..3
    input  wire  [4*83-1:0]  t_blk,        // the above macroblock's bottom row, columns 0..3

    // the sample memories
    output logic [1:0]  rd_region,
    output logic [5:0]  rd_addr,
    input  wire  [63:0] rd_data,
    output logic        wr_en,
    output logic [1:0]  wr_region,
    output logic [5:0]  wr_addr,
    output logic [63:0] wr_data,
    output logic [7:0]  wr_be
);

    logic [31:0] q_mb, l_mb, t_mb;         // the headers, latched at start
    logic        q_t8;

    // ---- the walk ---------------------------------------------------------------------------
    logic [1:0]  plane;                    // 0 Y, 1 Cb, 2 Cr
    logic        vert;                     // vertical edges first
    logic [1:0]  e;                        // edge (luma 0..3, chroma 0..1)
    logic        seg;                      // luma segment (lines 0-7 / 8-15)
    wire         is_c = (plane != 2'd0);
    wire         mb_edge = (e == 2'd0);
    // 8.7: with transform_size_8x8_flag the luma edges 1 and 3 (x / y = 4, 12) are not
    // filtered (transform_size_8x8_flag 1 filters luma edges 0 and 2 only); the chroma
    // internal edge of 4:2:0 still is (it lies on luma edge 2)
    wire         edge_on = mb_edge ? (vert ? left_en : top_en) : (int_en && !(q_t8 && !is_c && e[0]));
    wire  [5:0]  cbase = (plane == 2'd1) ? 6'd32 : 6'd40;      // chroma rows in region 0 / 1
    wire  [5:0]  cbase2 = (plane == 2'd1) ? 6'd8 : 6'd10;      // chroma rows 6, 7 in region 2

    // ---- bS: a pre-pass over the 32 luma edge groups (Nova's idea: the strengths decided
    // before the filtering, docs/h264_recon.md S6) --------------------------------------------
    // group {dir, edge e, group g}: dir 0 vertical (x = 4e, rows 4g..4g+3), 1 horizontal
    // (y = 4e, columns 4g..4g+3). A chroma edge takes the luma edge at the same position
    // (2e) and a chroma line the group holding its luma sample (8.7.2).
    // One group a cycle (P5b, docs/throughput.md: three a group made the pre-pass ~99 cycles
    // and the front waits for it on every macroblock): the q and p records are read in the
    // same cycle from two copies of the record RAM (A: pp addresses both; B: a1_pp's records
    // land, the macroblock-edge neighbour selected, registered; C: deblock_bs; D: bs_arr)
    // exp/mb-pipeline: two banks of records -- the predict stage writes macroblock n + 1's
    // (rec_wbank) while this one's are still to be read by its pre-pass (the bank latched
    // at start from rec_rbank)
    logic [82:0] recm_q [0:31];
    logic [82:0] recm_p [0:31];
    logic [3:0]  rec_qa, rec_pa;
    logic [82:0] rec_q, rec_p;
    logic        rec_rb;                   // the bank the pre-pass reads (latched at start)
    always_ff @(posedge clk) begin
        if (rec_we) recm_q[{rec_wbank, rec_wa}] <= rec_wd;
        rec_q <= recm_q[{rec_rb, rec_qa}];
    end
    always_ff @(posedge clk) begin
        if (rec_we) recm_p[{rec_wbank, rec_wa}] <= rec_wd;
        rec_p <= recm_p[{rec_rb, rec_pa}];
    end
    logic [4:0]  pp;                       // the group being addressed (stage A)
    logic        pp_run;                   // stage A issues a group this cycle
    logic        a1_v;                     // stage B: a1_pp's records are on rec_q / rec_p
    logic [4:0]  a1_pp;
    logic [4:0]  bs_idx_d;                 // stage D: the group whose bS is on bs_out
    wire         pp_dir = pp[4];
    wire  [1:0]  pp_e = pp[3:2], pp_g = pp[1:0];
    wire         a1_dir = a1_pp[4];
    wire         a1_mbe = (a1_pp[3:2] == 2'd0);
    wire  [3:0]  pqx = pp_dir ? {pp_g, 2'b00} : {pp_e, 2'b00};
    wire  [3:0]  pqy = pp_dir ? {pp_e, 2'b00} : {pp_g, 2'b00};
    wire  [3:0]  ppx = pp_dir ? pqx : pqx - 4'd1;
    wire  [3:0]  ppy = pp_dir ? pqy - 4'd1 : pqy;
    wire  [3:0]  q_bi = {pqy[3], pqx[3], pqy[2], pqx[2]};      // luma4x4BlkIdx (6.4.3)
    wire  [3:0]  p_bi = {ppy[3], ppx[3], ppy[2], ppx[2]};
    logic [82:0] lt_rec;                   // (a case: an index times 83 became a shifter)
    always_comb begin
        case (a1_pp[1:0])
            2'd0: lt_rec = a1_dir ? t_blk[0 +: 83]   : l_blk[0 +: 83];
            2'd1: lt_rec = a1_dir ? t_blk[83 +: 83]  : l_blk[83 +: 83];
            2'd2: lt_rec = a1_dir ? t_blk[166 +: 83] : l_blk[166 +: 83];
            default: lt_rec = a1_dir ? t_blk[249 +: 83] : l_blk[249 +: 83];
        endcase
    end
    always_comb begin rec_qa = q_bi; rec_pa = p_bi; end
    logic [82:0] qrec, prec;
    logic        bs_in, bs_mbe, bs_vert, bs_pintra;
    logic [4:0]  bs_idx;
    logic [2:0]  bs_arr [0:31];
    wire  [2:0]  bs_out;
    wire         bs_valid;
    deblock_bs u_bs (
        .clk(clk), .rst_n(rst_n), .in_valid(bs_in),
        .p_intra(bs_pintra), .p_nz(prec[0]), .p_pred0(prec[1]), .p_pred1(prec[42]), .p_refpic0(prec[9:2]), .p_refpic1(prec[50:43]),
        .p_mv0x(prec[25:10]), .p_mv0y(prec[41:26]), .p_mv1x(prec[66:51]), .p_mv1y(prec[82:67]),
        .q_intra(q_mb[0]), .q_nz(qrec[0]), .q_pred0(qrec[1]), .q_pred1(qrec[42]), .q_refpic0(qrec[9:2]), .q_refpic1(qrec[50:43]),
        .q_mv0x(qrec[25:10]), .q_mv0y(qrec[41:26]), .q_mv1x(qrec[66:51]), .q_mv1y(qrec[82:67]),
        .mb_edge(bs_mbe), .vertical(bs_vert), .field(field_pic),
        .out_valid(bs_valid), .bs(bs_out));
    // the p macroblock of the edge being filtered
    wire         mb_edge_w = (e == 2'd0);
    wire  [31:0] pm = mb_edge_w ? (vert ? l_mb : t_mb) : q_mb;
    logic [2:0]  bsg [0:3];                // the segment's groups (luma 2, chroma 4)

    // ---- the filter -----------------------------------------------------------------------------
    // qP of each side (8.7.2): QPY, or the plane's QPC; an I_PCM macroblock's 0 / QPC of 0
    logic [5:0] qp_p_w, qp_q_w;
    always_comb begin
        case (plane)
            2'd0:    begin qp_p_w = pm[1] ? 6'd0 : pm[7:2];     qp_q_w = q_mb[1] ? 6'd0 : q_mb[7:2]; end
            2'd1:    begin qp_p_w = pm[1] ? pm[25:20] : pm[13:8]; qp_q_w = q_mb[1] ? q_mb[25:20] : q_mb[13:8]; end
            default: begin qp_p_w = pm[1] ? pm[31:26] : pm[19:14]; qp_q_w = q_mb[1] ? q_mb[31:26] : q_mb[19:14]; end
        endcase
    end
    logic [5:0]  qp_p_q, qp_q_q;           // the segment's qPs, registered at D_EDGE (the
                                           // edge -> macroblock -> plane selection in front
                                           // of the filter's indexA missed clk_dec)
    logic [3:0]  fleft;                    // filter results still to come
    logic [2:0]  fjo;                      // the line / position whose result lands next
    logic [3:0]  fj;                       // horizontal: the next position fed (8: done)
    logic        f_in;                     // a line is presented to the filter this cycle
    logic [2:0]  f_bs;
    wire         f_out;
    wire  [7:0]  o_p2, o_p1, o_p0, o_q0, o_q1, o_q2;
    logic [7:0]  fs [0:7];                 // the line presented (registered with f_in)
    deblock_filter u_f (
        .clk(clk), .rst_n(rst_n), .in_valid(f_in),
        .p3(fs[0]), .p2(fs[1]), .p1(fs[2]), .p0(fs[3]), .q0(fs[4]), .q1(fs[5]), .q2(fs[6]), .q3(fs[7]),
        .bs(f_bs), .chroma(is_c), .qp_p(qp_p_q), .qp_q(qp_q_q),
        .alpha_off(alpha_off), .beta_off(beta_off),
        .out_valid(f_out), .p2o(o_p2), .p1o(o_p1), .p0o(o_p0), .q0o(o_q0), .q1o(o_q1), .q2o(o_q2), .changed());

    // ---- where the words live ---------------------------------------------------------------------
    // vertical: row r of the segment; word A holds p3..p0 (bytes poff..poff+3), word B holds
    // q0..q3 (bytes qoff..qoff+3); edges 1 / 3 have A == B (one read, one write)
    wire         one_word = vert && e[0];
    wire  [2:0]  poff = e[0] ? 3'd0 : 3'd4;
    wire  [2:0]  qoff = e[0] ? 3'd4 : 3'd0;
    // access `acc` of the segment (reads) and `wacc` (writes): region, address, line, word B
    logic [4:0]  acc, wacc;
    wire  [1:0]  a_reg, wa_reg;
    wire  [5:0]  a_addr, wa_addr;
    wire  [2:0]  a_line, wa_line;
    wire         a_isb, wa_isb;
    deblock_addr u_ra (.vert(vert), .is_c(is_c), .e(e), .seg(seg), .one_word(one_word), .cbase(cbase), .cbase2(cbase2),
                       .acc(acc), .a_reg(a_reg), .a_addr(a_addr), .a_line(a_line), .a_isb(a_isb));
    deblock_addr u_wa (.vert(vert), .is_c(is_c), .e(e), .seg(seg), .one_word(one_word), .cbase(cbase), .cbase2(cbase2),
                       .acc(wacc), .a_reg(wa_reg), .a_addr(wa_addr), .a_line(wa_line), .a_isb(wa_isb));
    // accesses per segment
    wire  [4:0]  n_rd = vert ? (one_word ? 5'd8 : 5'd16) : (is_c ? 5'd4 : 5'd8);

    // ---- the FSM -------------------------------------------------------------------------------
    typedef enum logic [3:0] {D_IDLE, D_PRE, D_PRE_END, D_EDGE, D_VRUN, D_HRD, D_HFILT, D_HWR, D_NEXT, D_DONE} dstate_t;
    dstate_t st;
    always_ff @(posedge clk) if (start && st == D_IDLE) begin q_mb <= q_mb_in; l_mb <= l_mb_in; t_mb <= t_mb_in; q_t8 <= q_t8_in; rec_rb <= rec_rbank; end
    logic [4:0]  rq1, rq2;                 // the access whose address was presented / whose data returns
    logic        rq1_v, rq2_v;
    logic [3:0]  hl;                       // horizontal: rows loaded (+ chroma's two aligning shifts)
    logic [2:0]  hk;                       // horizontal: the write-back step

    // the returning access (vertical): its line and word
    wire  [2:0]  c_line = one_word ? rq2[2:0] : rq2[3:1];
    wire         c_isb  = !one_word && rq2[0];
    wire  [1:0]  c_grp  = is_c ? c_line[2:1] : {1'b0, c_line[2]};
    wire  [31:0] rd_p   = e[0] ? rd_data[31:0] : rd_data[63:32];    // bytes poff..poff+3: p3..p0
    wire  [31:0] rd_q   = e[0] ? rd_data[63:32] : rd_data[31:0];    // bytes qoff..qoff+3: q0..q3
    logic [31:0] pa;                       // a two-word line's p half, held for its q word
    // vertical results: the p side (with the q side when one word) now, a two-word line's q
    // word the cycle after (results of two-word lines are two cycles apart)
    logic        wb_pend;
    logic [23:0] wb_q;                     // {q2, q1, q0}
    wire  [63:0] wd_v = e[0] ? {8'h00, o_q2, o_q1, o_q0, o_p0, o_p1, o_p2, 8'h00}
                             : {o_p0, o_p1, o_p2, 8'h00, 8'h00, o_q2, o_q1, o_q0};
    wire  [7:0]  be_p = (is_c ? 8'h08 : 8'h0E) << poff;             // luma p2..p0, chroma p0
    wire  [7:0]  be_q = (is_c ? 8'h01 : 8'h07) << qoff;             // luma q0..q2, chroma q0
    wire  [3:0]  wb_acc = {fjo, 1'b0} - 4'd1;                       // the pending q word's access
    always_comb begin
        if (st == D_HWR) wacc = is_c ? {2'd0, hk} - 5'd1 : {2'd0, hk} + 5'd1;
        else if (wb_pend) wacc = {1'b0, wb_acc};
        else wacc = one_word ? {2'd0, fjo} : {1'b0, fjo, 1'b0};
    end
    // horizontal: the eight rows p3..q3 (chroma p1..q1 in rows 2..5), filled and written back
    // by row shifts, fed and refilled by byte shifts -- position x leaves at byte 0 when fed,
    // its result enters at byte 7 when it lands, and 8 + latency shifts later every result
    // is back at its own byte (no selection anywhere)
    logic [63:0] hr [0:7];
    wire         h_align = is_c && (hl >= n_rd[3:0]) && (hl != 4'd6);  // chroma: rows 4..7 -> 2..5
    wire         h_row_sh = (st == D_HRD && (rq2_v || h_align)) || (st == D_HWR);
    wire         h_byte_sh = (st == D_HFILT);
    always_ff @(posedge clk) begin
        if (h_row_sh) begin
            for (int i = 0; i < 7; i++) hr[i] <= hr[i + 1];
            hr[7] <= rd_data;
        end else if (h_byte_sh) begin
            hr[0] <= {8'h00, hr[0][63:8]};
            hr[1] <= {f_out ? o_p2 : 8'h00, hr[1][63:8]};
            hr[2] <= {f_out ? o_p1 : 8'h00, hr[2][63:8]};
            hr[3] <= {f_out ? o_p0 : 8'h00, hr[3][63:8]};
            hr[4] <= {f_out ? o_q0 : 8'h00, hr[4][63:8]};
            hr[5] <= {f_out ? o_q1 : 8'h00, hr[5][63:8]};
            hr[6] <= {f_out ? o_q2 : 8'h00, hr[6][63:8]};
            hr[7] <= {8'h00, hr[7][63:8]};
        end
    end
    wire  [1:0]  h_grp = is_c ? fj[2:1] : {1'b0, fj[2]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= D_IDLE; done <= 1'b0; pre_done <= 1'b0; busy <= 1'b0; plane <= '0; vert <= 1'b1; e <= '0; seg <= 1'b0;
            bs_in <= 1'b0; f_in <= 1'b0; f_bs <= '0; fj <= '0; fjo <= '0; fleft <= '0;
            pp <= '0; pp_run <= 1'b0; a1_v <= 1'b0; a1_pp <= '0; bs_idx_d <= '0;
            qrec <= '0; prec <= '0; bs_mbe <= 1'b0; bs_vert <= 1'b0; bs_pintra <= 1'b0; bs_idx <= '0;
            for (int j = 0; j < 32; j++) bs_arr[j] <= '0;
            for (int i = 0; i < 8; i++) fs[i] <= '0;
            rq1 <= '0; rq2 <= '0; rq1_v <= 1'b0; rq2_v <= 1'b0; acc <= '0; hl <= '0; hk <= '0;
            pa <= '0; wb_pend <= 1'b0; wb_q <= '0; qp_p_q <= '0; qp_q_q <= '0;
            rd_region <= '0; rd_addr <= '0; wr_en <= 1'b0; wr_region <= '0; wr_addr <= '0; wr_data <= '0; wr_be <= '0;
            for (int j = 0; j < 4; j++) bsg[j] <= '0;
        end else begin
            done <= 1'b0; pre_done <= 1'b0; bs_in <= 1'b0; f_in <= 1'b0; wr_en <= 1'b0;
            // the pre-pass pipeline (stages B, D; A and the pp walk in D_PRE below)
            a1_v <= pp_run; a1_pp <= pp;
            if (a1_v) begin
                qrec <= rec_q;
                prec <= a1_mbe ? lt_rec : rec_p;
                bs_pintra <= a1_mbe ? (a1_dir ? t_mb[0] : l_mb[0]) : q_mb[0];
                bs_mbe <= a1_mbe; bs_vert <= !a1_dir; bs_idx <= a1_pp; bs_in <= 1'b1;
            end
            bs_idx_d <= bs_idx;
            if (bs_valid) bs_arr[bs_idx_d] <= bs_out;
            // read data returning: the address was registered two edges ago
            rq2 <= rq1; rq2_v <= rq1_v; rq1_v <= 1'b0;
            if (rq2_v && vert) begin
                // a vertical line goes to the filter as its (last) word arrives
                if (one_word || c_isb) begin
                    f_in <= 1'b1; f_bs <= bsg[c_grp];
                    for (int b = 0; b < 4; b++) begin
                        fs[b] <= one_word ? rd_p[8*b +: 8] : pa[8*b +: 8];
                        fs[4 + b] <= rd_q[8*b +: 8];
                    end
                end else pa <= rd_p;
            end
            if (rq2_v && !vert) hl <= hl + 1'b1;
            // vertical results: written as they land
            if (st == D_VRUN) begin
                if (f_out) begin
                    wr_en <= 1'b1; wr_region <= wa_reg; wr_addr <= wa_addr; wr_data <= wd_v;
                    wr_be <= one_word ? (be_p | be_q) : be_p;
                    if (!one_word) begin wb_pend <= 1'b1; wb_q <= {o_q2, o_q1, o_q0}; end
                    fjo <= fjo + 1'b1; fleft <= fleft - 1'b1;
                end else if (wb_pend) begin
                    wr_en <= 1'b1; wr_region <= wa_reg; wr_addr <= wa_addr; wr_data <= {40'd0, wb_q}; wr_be <= be_q;
                    wb_pend <= 1'b0;
                end
            end
            case (st)
                D_IDLE: if (start) begin
                    busy <= 1'b1; plane <= 2'd0; vert <= 1'b1; e <= 2'd0; seg <= 1'b0;
                    pp <= '0; pp_run <= 1'b1;
                    st <= D_PRE;
                end
                // ---- the bS pre-pass: one group a cycle (stage A addresses group pp) ---------------
                D_PRE: begin
                    pp <= pp + 1'b1;
                    if (pp == 5'd31) begin pp_run <= 1'b0; st <= D_PRE_END; end
                end
                D_PRE_END: if (bs_valid && bs_idx_d == 5'd31) begin pre_done <= 1'b1; st <= D_EDGE; end   // the last group's result
                D_EDGE: begin
                    if (!edge_on) begin
                        seg <= 1'b1;                        // the whole edge is off
                        st <= D_NEXT;
                    end else begin
                        logic [2:0] b0, b1, b2, b3;
                        if (!is_c) begin
                            b0 = bs_arr[{!vert, e, seg, 1'b0}]; b1 = bs_arr[{!vert, e, seg, 1'b1}]; b2 = 3'd0; b3 = 3'd0;
                        end else begin
                            b0 = bs_arr[{!vert, e[0], 1'b0, 2'd0}]; b1 = bs_arr[{!vert, e[0], 1'b0, 2'd1}];
                            b2 = bs_arr[{!vert, e[0], 1'b0, 2'd2}]; b3 = bs_arr[{!vert, e[0], 1'b0, 2'd3}];
                        end
                        bsg[0] <= b0; bsg[1] <= b1; bsg[2] <= b2; bsg[3] <= b3;
                        qp_p_q <= qp_p_w; qp_q_q <= qp_q_w;
                        acc <= '0; fjo <= '0; fleft <= 4'd8; fj <= '0; hl <= '0; hk <= '0;
                        if ((b0 | b1 | b2 | b3) == 3'd0) st <= D_NEXT;           // nothing to filter
                        else if (vert) st <= D_VRUN;
                        else st <= D_HRD;
                    end
                end
                // ---- vertical: read, filter and write streamed ---------------------------------
                D_VRUN: begin
                    if (acc != n_rd) begin
                        rd_region <= a_reg; rd_addr <= a_addr;
                        rq1 <= acc; rq1_v <= 1'b1;
                        acc <= acc + 1'b1;
                    end
                    // the last write is registered this cycle at the latest: the next segment's
                    // first read is issued three cycles later
                    if (fleft == 4'd0 && !wb_pend) st <= D_NEXT;
                end
                // ---- horizontal: the rows in (row shifts; chroma two more to rows 2..5) ------------
                D_HRD: begin
                    if (acc != n_rd) begin
                        rd_region <= a_reg; rd_addr <= a_addr;
                        rq1 <= acc; rq1_v <= 1'b1;
                        acc <= acc + 1'b1;
                    end
                    if (h_align) hl <= hl + 1'b1;                             // an aligning shift
                    else if (hl >= n_rd[3:0]) st <= D_HFILT;
                end
                // ---- the eight positions through the filter, byte shifts until the last lands ----
                D_HFILT: begin
                    if (fj != 4'd8) begin
                        f_in <= 1'b1; f_bs <= bsg[h_grp];
                        for (int i = 0; i < 8; i++) fs[i] <= hr[i][7:0];
                        fj <= fj + 1'b1;
                    end
                    if (f_out) begin
                        fleft <= fleft - 1'b1;
                        if (fleft == 4'd1) st <= D_HWR;
                    end
                end
                // ---- the rows back: luma p2..q2, chroma p0 / q0 (after two shifts) --------------
                D_HWR: begin
                    if (!is_c || hk[1]) begin
                        wr_en <= 1'b1; wr_region <= wa_reg; wr_addr <= wa_addr; wr_data <= hr[1]; wr_be <= 8'hFF;
                    end
                    hk <= hk + 1'b1;
                    if (hk == (is_c ? 3'd3 : 3'd5)) st <= D_NEXT;
                end
                D_NEXT: begin
                    if (!is_c && !seg) begin
                        seg <= 1'b1; st <= D_EDGE;
                    end else if (e != (is_c ? 2'd1 : 2'd3)) begin
                        seg <= 1'b0; e <= e + 1'b1; st <= D_EDGE;
                    end else if (vert) begin
                        seg <= 1'b0; e <= 2'd0; vert <= 1'b0; st <= D_EDGE;
                    end else if (plane != 2'd2) begin
                        seg <= 1'b0; e <= 2'd0; vert <= 1'b1; plane <= plane + 1'b1; st <= D_EDGE;
                    end else st <= D_DONE;
                end
                D_DONE: begin done <= 1'b1; busy <= 1'b0; st <= D_IDLE; end
                default: st <= D_IDLE;
            endcase
        end
    end

endmodule

// the address of access `acc` of a segment (vertical: line acc (one word) or acc >> 1, word
// A for even acc, B for odd; horizontal: row acc of p3..q3, chroma row acc + 2 of p1..q1).
// Two instances: the reads and the writes of recon_deblock.
module deblock_addr (
    input  wire         vert,
    input  wire         is_c,
    input  wire  [1:0]  e,
    input  wire         seg,
    input  wire         one_word,
    input  wire  [5:0]  cbase,
    input  wire  [5:0]  cbase2,
    input  wire  [4:0]  acc,
    output logic [1:0]  a_reg,
    output logic [5:0]  a_addr,
    output logic [2:0]  a_line,
    output logic        a_isb
);
    wire mb_edge = (e == 2'd0);
    always_comb begin
        logic [3:0] r;
        logic signed [5:0] y;
        a_reg = 2'd0; a_addr = 6'd0; a_line = 3'd0; a_isb = 1'b0; r = 4'd0; y = 6'sd0;
        if (vert) begin
            a_line = one_word ? acc[2:0] : acc[3:1];
            a_isb  = !one_word && acc[0];
            r = is_c ? {1'b0, a_line} : {seg, a_line};
            if (!is_c) begin
                // A: e 0 -> the left macroblock's word 1; e 1, 2 -> word 0; e 3 -> word 1.
                // B: e 0 -> word 0; e 2 -> word 1.
                if (!a_isb) begin a_reg = (e == 2'd0) ? 2'd1 : 2'd0; a_addr = {1'b0, r, (e == 2'd0 || e == 2'd3)}; end
                else        begin a_reg = 2'd0;                      a_addr = {1'b0, r, e[1]}; end
            end else begin
                a_reg = (!a_isb && e == 2'd0) ? 2'd1 : 2'd0;
                a_addr = cbase + {3'd0, r[2:0]};
            end
        end else begin
            a_line = is_c ? acc[2:0] + 3'd2 : acc[2:0];                 // the row: p3 = 0 .. q3 = 7
            y = $signed({2'b00, e, 2'b00}) - 6'sd4 + $signed({3'b000, a_line});
            if (!is_c) begin
                if (mb_edge && a_line < 3'd4) begin a_reg = 2'd2; a_addr = {3'b000, a_line[1:0], seg}; end
                else                          begin a_reg = 2'd0; a_addr = {1'b0, y[3:0], seg}; end
            end else begin
                if (mb_edge && a_line < 3'd4) begin a_reg = 2'd2; a_addr = cbase2 + {5'd0, a_line[0]}; end
                else                          begin a_reg = 2'd0; a_addr = cbase + {3'd0, y[2:0]}; end
            end
        end
    end
endmodule


`default_nettype wire
