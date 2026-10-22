// h264/recon_out.sv -- the reconstruction's output queue to the display (P5d,
// docs/display.md S6): what recon_top's output process emits (clk_dec), as records the
// display takes (clk_sys), and the display's releases back as the DPB's holds.
//
//   clk_dec  pinfo_*  every picture's display facts when it opens, by store: the "a"
//                     half (its first picture: size, cropping, aspect, the VUI timing --
//                     num_units_in_tick / time_scale, P5e divides them on clk_sys --
//                     pic_struct, PTS, IDR) or, for a pair's second field, the "b" half
//                     (its pic_struct and PTS). A table, 32 entries a half, written here,
//                     read by clk_sys.
//            emit_*   one store to show, in output order (C.4.5.3, the store is the unit:
//                     emitted whole, once per allocation). It goes on the record FIFO and
//                     its hold bit rises (oq_hold -> recon_dpb's disp_hold: the decoder
//                     cannot reuse the store until the display gives it back).
//            eos_done the end-of-stream flush is complete: an END record follows the last
//                     store (the display holds the last picture; P5e).
//   clk_sys  rec_*    the record at the head: its FIFO word, then its table row (the
//                     store's facts cannot change while it is queued: a store is written
//                     only when it opens, and it cannot open again while held). rec_take
//                     consumes it.
//            rel_*    a store the display is done with: through the release FIFO, its
//                     hold bit falls.
//
// Depths: a store is emitted at most once per allocation and held until released, so at
// most NSTORE (20) records are ever queued -- the 32-deep FIFOs cannot fill (a push
// while full is counted, rec_ovf, and would be a design error, never silent). A release
// of a store not held is counted too (rel_bad: a display bug).
//
// Resets: one per domain (fifo_dc's rules). The mount resets both with the decoder.

`default_nettype none

module recon_out #(
    parameter int NST = 20
) (
    // ---- clk_dec: the reconstruction's side ----
    input  wire          clk,
    input  wire          rst_n,
    input  wire          pinfo_we,
    input  wire  [4:0]   pinfo_store,
    input  wire          pinfo_second,
    input  wire  [7:0]   pinfo_w_mbs,
    input  wire  [7:0]   pinfo_hf_mbs,
    input  wire  [40:0]  pinfo_crop,          // {cuy4, left, right, top, bottom} (recon_top)
    input  wire  [39:0]  pinfo_aspect,       // {aspect_ratio_idc, sar_width, sar_height}
    input  wire  [2:0]   pinfo_colour,      // (0.16, docs/colour.md) the picture's colour code, by store like the aspect
    input  wire          pinfo_col_unsup,   // (0.16) ... shown by the size rule: its matrix not supported
    input  wire  [25:0]  pinfo_col_tags,    // (0.16) its SPS's colour description (word 86)
    input  wire  [5:0]   pinfo_siting,      // (docs/chroma.md §4) its chroma siting {bottom, top}, by store like the colour
    input  wire          pinfo_timing_v,     // the SPS's VUI timing_info_present_flag
    input  wire  [31:0]  pinfo_nuit,         //   num_units_in_tick
    input  wire  [31:0]  pinfo_ts,           //   time_scale
    input  wire  [3:0]   pinfo_ps,
    input  wire          pinfo_ps_v,
    input  wire  [32:0]  pinfo_pts,
    input  wire          pinfo_pts_v,
    input  wire          pinfo_idr,
    input  wire          emit_valid,
    input  wire  [4:0]   emit_store,
    input  wire          emit_unpaired,
    input  wire          emit_first_bot,
    input  wire          emit_frame,
    input  wire          emit_dec_t,
    input  wire          emit_dec_b,
    input  wire          eos_done,
    output logic [NST-1:0] oq_hold,          // -> recon_top disp_hold
    output logic [31:0]  n_emit,             // stores emitted (the HUD)
    output logic [31:0]  n_rel,              // stores released
    output logic         rec_ovf,            // sticky: a record was pushed into a full FIFO
    output logic         rel_bad,            // sticky: a release of a store not held

    // ---- clk_sys: the display's side ----
    input  wire          sclk,
    input  wire          srst_n,
    output logic         rec_valid,
    output logic         rec_more,           // P3f: another PICTURE (not the END) waits behind the head
    input  wire          rec_take,
    output logic         rec_end,            // the END record (end of stream): no store
    output logic [4:0]   rec_store,
    output logic         rec_frame,          // coded as a frame
    output logic         rec_unpaired,       // a single field (dec_t / dec_b say which)
    output logic         rec_first_bot,      // a pair's first-decoded field is the bottom one
    output logic         rec_dec_t,
    output logic         rec_dec_b,
    output logic [7:0]   rec_w_mbs,
    output logic [7:0]   rec_hf_mbs,
    output logic [40:0]  rec_crop,
    output logic [39:0]  rec_aspect,
    output logic [2:0]   rec_colour,        // (0.16)
    output logic         rec_col_unsup,
    output logic [25:0]  rec_col_tags,
    output logic [5:0]   rec_siting,        // (chroma.md §4)
    output logic         rec_timing_v,
    output logic [31:0]  rec_nuit,
    output logic [31:0]  rec_ts,
    output logic [3:0]   rec_ps_a,           // pic_struct: the first picture's ...
    output logic         rec_ps_a_v,
    output logic [3:0]   rec_ps_b,           //   ... and a pair's second field's
    output logic         rec_ps_b_v,
    output logic [32:0]  rec_pts,            // the first picture's PTS (a pair's second field's
    output logic         rec_pts_v,          //   is in rec_pts_b)
    output logic [32:0]  rec_pts_b,
    output logic         rec_pts_b_v,
    output logic         rec_idr,
    input  wire          rel_valid,
    input  wire  [4:0]   rel_store
);

    // ---- the store table: a (238 bits; 0.16: + the colour code, flag and tags; chroma.md §4: + the siting) and b (39 bits), by store
    // (no byte enables: 238 bits pack in six 40-bit M10K columns, as 232 did)
    localparam int AW_A = 238, AW_B = 39;
    logic [AW_A-1:0] tab_a [0:31];
    logic [AW_B-1:0] tab_b [0:31];
    always_ff @(posedge clk) begin
        if (pinfo_we && !pinfo_second)
            tab_a[pinfo_store] <= {pinfo_w_mbs, pinfo_hf_mbs, pinfo_crop, pinfo_aspect, pinfo_colour, pinfo_col_unsup, pinfo_col_tags, pinfo_siting, pinfo_timing_v, pinfo_nuit,
                                   pinfo_ts, pinfo_ps, pinfo_ps_v, pinfo_pts, pinfo_pts_v, pinfo_idr};
        if (pinfo_we && pinfo_second)
            tab_b[pinfo_store] <= {pinfo_ps, pinfo_ps_v, pinfo_pts, pinfo_pts_v};
    end

    // ---- the record FIFO: {end, store, frame, unpaired, first_bot, dec_t, dec_b} -----
    // The END record is pushed 8 clk_dec cycles after eos_done, and a flag (end_q) set AT
    // eos_done crosses to clk_sys beside it: the flag then arrives before the END can be
    // seen in the FIFO (its pointer crosses through two flops too), so rec_more -- "another
    // PICTURE waits behind the head" -- never counts the END (P3f: low latency skips a head
    // only for a newer picture; the stream's last one must be shown). After eos_done the
    // DPB is idle until the next stream's reset: nothing else is pushed meanwhile.
    logic [10:0] rq_din, rq_dout;
    logic        rq_we, rq_full, rq_empty, rq_rd, rq_valid;
    logic [7:0]  eos_dly;
    logic        end_q;
    wire         eos_push = eos_dly[7];
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin eos_dly <= '0; end_q <= 1'b0; end
        else begin eos_dly <= {eos_dly[6:0], eos_done}; if (eos_done) end_q <= 1'b1; end
    always_comb begin
        rq_we  = emit_valid || eos_push;
        rq_din = eos_push && !emit_valid ? {1'b1, 10'd0}
                                         : {1'b0, emit_store, emit_frame, emit_unpaired, emit_first_bot, emit_dec_t, emit_dec_b};
    end
    fifo_dc #(.DW(11), .AW(5)) u_rec (
        .wr_clk(clk), .wr_rst_n(rst_n), .din(rq_din), .wr_en(rq_we), .full(rq_full), .wr_free(),
        .rd_clk(sclk), .rd_rst_n(srst_n), .dout(rq_dout), .rd_en(rq_rd), .empty(rq_empty), .valid(rq_valid));

    // ---- the release FIFO: a store, clk_sys -> clk_dec -------------------------------
    logic [4:0] lq_dout;
    logic       lq_empty, lq_rd, lq_valid;
    fifo_dc #(.DW(5), .AW(5)) u_rel (
        .wr_clk(sclk), .wr_rst_n(srst_n), .din(rel_store), .wr_en(rel_valid), .full(), .wr_free(),
        .rd_clk(clk), .rd_rst_n(rst_n), .dout(lq_dout), .rd_en(lq_rd), .empty(lq_empty), .valid(lq_valid));
    assign lq_rd = !lq_empty;

    // ---- clk_dec: the holds ----------------------------------------------------------
    // (eos_done and an emission never coincide: recon_dpb raises eos_done in the cycle
    // after its last scan found nothing -- both pushes would still be one FIFO word, so
    // the END record would be lost; counted as an overflow if it ever happened)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oq_hold <= '0; n_emit <= '0; n_rel <= '0; rec_ovf <= 1'b0; rel_bad <= 1'b0;
        end else begin
            if (rq_we && (rq_full || (emit_valid && eos_push))) rec_ovf <= 1'b1;
            if (lq_valid) begin
                if (lq_dout >= NST[4:0] || !oq_hold[lq_dout]) rel_bad <= 1'b1;
                n_rel <= n_rel + 32'd1;
            end
            for (int i = 0; i < NST; i++) begin
                if (emit_valid && emit_store == i[4:0]) oq_hold[i] <= 1'b1;
                else if (lq_valid && lq_dout == i[4:0]) oq_hold[i] <= 1'b0;
            end
            if (emit_valid) n_emit <= n_emit + 32'd1;
        end
    end

    // ---- clk_sys: the head record, its FIFO word then its table row ------------------
    // p0: pop (rq_rd) -> p1: the word (rq_valid) captured -> p2: the table read at the
    // captured store (fifo_dc's dout is not held after the pop) -> p3: rec_valid
    logic       p_busy;                     // a word popped and not yet presented
    logic       p_tab;                      // the table read is in flight (p1 -> p2)
    logic [9:0] p_word;
    logic       p_end;
    logic [AW_A-1:0] ra;
    logic [AW_B-1:0] rb;
    assign rq_rd = !rq_empty && !p_busy && !rec_valid;
    logic end_s1, end_s2;                   // end_q into clk_sys (ahead of the END's FIFO word)
    always_ff @(posedge sclk or negedge srst_n)
        if (!srst_n) begin end_s1 <= 1'b0; end_s2 <= 1'b0; end
        else begin end_s1 <= end_q; end_s2 <= end_s1; end
    assign rec_more = rec_valid && !rq_empty && !end_s2;
    always_ff @(posedge sclk) begin
        if (p_tab) begin
            ra <= tab_a[p_word[9:5]];
            rb <= tab_b[p_word[9:5]];
        end
    end
    always_ff @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            p_busy <= 1'b0; p_tab <= 1'b0; p_word <= '0; p_end <= 1'b0; rec_valid <= 1'b0;
        end else begin
            if (rq_rd) p_busy <= 1'b1;
            p_tab <= 1'b0;
            if (rq_valid) begin p_word <= rq_dout[9:0]; p_end <= rq_dout[10]; p_tab <= 1'b1; end
            if (p_tab) begin rec_valid <= 1'b1; p_busy <= 1'b0; end
            if (rec_valid && rec_take) rec_valid <= 1'b0;
        end
    end
    always_comb begin
        rec_end       = p_end;
        {rec_store, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b} = p_word;
        {rec_w_mbs, rec_hf_mbs, rec_crop, rec_aspect, rec_colour, rec_col_unsup, rec_col_tags, rec_siting, rec_timing_v, rec_nuit, rec_ts, rec_ps_a, rec_ps_a_v, rec_pts,
         rec_pts_v, rec_idr} = ra;
        {rec_ps_b, rec_ps_b_v, rec_pts_b, rec_pts_b_v} = rb;
    end

endmodule

`default_nettype wire
