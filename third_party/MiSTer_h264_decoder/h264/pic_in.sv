// h264/pic_in.sv -- pictures from the program (interface 0.15, docs/architecture.md "Pictures
// from the program"): a PICTURE record's descriptor, handed over by h264/ring_rd.sv's parser
// (clk_sys), becomes what the decoder's output process gives h264/recon_out.sv (clk_dec) -- the
// store's display facts and its emission -- so the display shows a picture the program wrote
// into a DPB store exactly as it shows a decoded one.
//
// THE HAND-OVER: four-phase levels. pd_req (ring_rd, clk_sys) rises with the descriptor stable
// behind it (quasi-static: h264.sdc); here it is synchronised (rq1, rq2) and the descriptor
// captured (d_*). A store the display still holds (recon_out's oq_hold) is refused: pd_busy rises,
// then pd_ack a cycle later (so the parser's two flops see pd_busy settled with pd_ack), nothing
// emitted. Otherwise, one per cycle, as bench/h264/disp_sched_tb.sv drives recon_out: the "a"
// half of pinfo (the size, the crop -- cuy4 0: the crop's rows are pairs of frame lines -- the
// aspect, the timing, pic_struct, the PTS); for a field pair the "b" half with no PTS and no
// pic_struct (else the store's earlier use would leave disp_ctl a stale second-field PTS); the
// emission (pic_emitted counted the cycle recon_out raises the store's hold, so word 84's
// snapshot never shows a store emitted and not yet held); after END_OF_STREAM, eos_done one
// cycle later (recon_out's END record). Then pd_ack; pd_req falls; pd_ack and pd_busy fall.
//
// THE MUX: in front of recon_out, recon_top's outputs pass through until this stream's first
// descriptor (sel), then this module's. Combinational on registered sources: a register here
// would delay recon_dpb's view of the holds by a cycle after an emission. A stream is one kind
// or the other (ring_rd's STREAM_KIND), and the per-stream reset (rst_n) clears sel; recon_top
// receives no bytes in a picture stream, so it stays silent while sel is up.
//
// Resets: rst_n the per-stream reset (fe_rst_dec_n: the parser's P_RST holds pd_req low through
// it, and an OSD reset resets both sides), cnt_rst_n the PLL lock (pic_emitted counts on across
// streams: the program's store rule numbers pictures from one status copy to the next).

`default_nettype none

module pic_in #(
    parameter int NST = 20
) (
    input  wire          clk,                 // clk_dec
    input  wire          rst_n,               // the per-stream reset
    input  wire          cnt_rst_n,           // the PLL lock: pic_emitted
    // ---- from ring_rd (clk_sys): the descriptor, quasi-static behind pd_req ----
    input  wire          pd_req,
    input  wire  [4:0]   pd_store,
    input  wire  [7:0]   pd_w,
    input  wire  [7:0]   pd_hf,
    input  wire  [1:0]   pd_struct,           // 0 frame, 1 pair top first, 2 pair bottom first
    input  wire  [3:0]   pd_ps,
    input  wire          pd_ps_v,
    input  wire  [39:0]  pd_aspect,
    input  wire  [2:0]   pd_colour,           // (0.16, docs/colour.md) the record's colour code: 0 auto (the size rule), 1..6
    input  wire          pd_timing_v,
    input  wire  [31:0]  pd_nuit,
    input  wire  [31:0]  pd_ts,
    input  wire  [39:0]  pd_crop,             // {left, right, top, bottom}
    input  wire  [32:0]  pd_pts,
    input  wire          pd_pts_v,
    input  wire          pd_eos,
    output logic         pd_ack,
    output logic         pd_busy,
    input  wire  [NST-1:0] oq_hold,           // recon_out: the stores the display holds
    output logic [31:0]  pic_emitted,         // word 84
    output logic         sel,                 // this stream's pictures are the program's
    // ---- recon_top's output process (passed through while !sel) ----
    input  wire          r_pinfo_we,
    input  wire  [4:0]   r_pinfo_store,
    input  wire          r_pinfo_second,
    input  wire  [7:0]   r_pinfo_w_mbs,
    input  wire  [7:0]   r_pinfo_hf_mbs,
    input  wire  [40:0]  r_pinfo_crop,
    input  wire  [39:0]  r_pinfo_aspect,
    input  wire  [2:0]   r_pinfo_colour,      // (0.16)
    input  wire          r_pinfo_col_unsup,
    input  wire  [25:0]  r_pinfo_col_tags,
    input  wire  [5:0]   r_pinfo_siting,      // (docs/chroma.md §4) the decoder's picture's chroma siting
    input  wire          r_pinfo_timing_v,
    input  wire  [31:0]  r_pinfo_nuit,
    input  wire  [31:0]  r_pinfo_ts,
    input  wire  [3:0]   r_pinfo_ps,
    input  wire          r_pinfo_ps_v,
    input  wire  [32:0]  r_pinfo_pts,
    input  wire          r_pinfo_pts_v,
    input  wire          r_pinfo_idr,
    input  wire          r_emit_valid,
    input  wire  [4:0]   r_emit_store,
    input  wire          r_emit_unpaired,
    input  wire          r_emit_first_bot,
    input  wire          r_emit_frame,
    input  wire          r_emit_dec_t,
    input  wire          r_emit_dec_b,
    input  wire          r_eos_done,
    // ---- to recon_out's write side ----
    output logic         pinfo_we,
    output logic [4:0]   pinfo_store,
    output logic         pinfo_second,
    output logic [7:0]   pinfo_w_mbs,
    output logic [7:0]   pinfo_hf_mbs,
    output logic [40:0]  pinfo_crop,
    output logic [39:0]  pinfo_aspect,
    output logic [2:0]   pinfo_colour,        // (0.16)
    output logic         pinfo_col_unsup,     // (0.16) a program's picture: 0
    output logic [25:0]  pinfo_col_tags,      // (0.16) a program's picture: no colour description (2, 2, 2, limited)
    output logic [5:0]   pinfo_siting,        // (chroma.md §4) a program's picture: 0 (interface 1.0 carries none)
    output logic         pinfo_timing_v,
    output logic [31:0]  pinfo_nuit,
    output logic [31:0]  pinfo_ts,
    output logic [3:0]   pinfo_ps,
    output logic         pinfo_ps_v,
    output logic [32:0]  pinfo_pts,
    output logic         pinfo_pts_v,
    output logic         pinfo_idr,
    output logic         emit_valid,
    output logic [4:0]   emit_store,
    output logic         emit_unpaired,
    output logic         emit_first_bot,
    output logic         emit_frame,
    output logic         emit_dec_t,
    output logic         emit_dec_b,
    output logic         eos_done
);

    // ---- the request, synchronised; the descriptor captured behind it ----
    logic rq1, rq2;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin rq1 <= 1'b0; rq2 <= 1'b0; end
        else        begin rq1 <= pd_req; rq2 <= rq1; end

    logic [4:0]  d_store;
    logic [7:0]  d_w, d_hf;
    logic [1:0]  d_struct;
    logic [3:0]  d_ps;
    logic        d_ps_v, d_timing_v, d_pts_v, d_eos;
    logic [39:0] d_aspect, d_crop;
    logic [2:0]  d_pcol, d_colour;            // (0.16) the record's code; the resolved one (registered a cycle after
                                              // the capture, valid at I_CHK's first write)
    // the size rule on the shown size (the crop in pairs of columns / of frame lines): >= 1,280 wide or > 576 high
    wire  [12:0] d_wshow = {1'b0, d_w, 4'd0}  - {2'd0, ({1'b0, d_crop[39:30]} + {1'b0, d_crop[29:20]}), 1'b0};
    wire  [12:0] d_hshow = {1'b0, d_hf, 4'd0} - {2'd0, ({1'b0, d_crop[19:10]} + {1'b0, d_crop[9:0]}), 1'b0};
    always_ff @(posedge clk)
        d_colour <= (d_pcol >= 3'd1 && d_pcol <= 3'd6) ? d_pcol :
                    ((d_wshow >= 13'd1280) || (d_hshow > 13'd576)) ? 3'd3 : 3'd1;
    logic [31:0] d_nuit, d_ts;
    logic [32:0] d_pts;
    wire         d_pair = (d_struct != 2'd0);

    typedef enum logic [2:0] { I_IDLE, I_CHK, I_A, I_B, I_E, I_EOS, I_ACK, I_WAIT } ist_t;
    ist_t st;
    // this module's drive of recon_out (o_*), registered
    logic        o_we, o_second, o_emit, o_eos;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= I_IDLE; sel <= 1'b0; pd_ack <= 1'b0; pd_busy <= 1'b0;
            o_we <= 1'b0; o_second <= 1'b0; o_emit <= 1'b0; o_eos <= 1'b0;
            d_store <= '0; d_w <= '0; d_hf <= '0; d_struct <= '0; d_ps <= '0; d_ps_v <= 1'b0; d_timing_v <= 1'b0;
            d_pts_v <= 1'b0; d_eos <= 1'b0; d_aspect <= '0; d_pcol <= '0; d_crop <= '0; d_nuit <= '0; d_ts <= '0; d_pts <= '0;
        end else begin
            o_we <= 1'b0; o_emit <= 1'b0; o_eos <= 1'b0;
            case (st)
                I_IDLE: if (rq2) begin
                    d_store <= pd_store; d_w <= pd_w; d_hf <= pd_hf; d_struct <= pd_struct; d_ps <= pd_ps;
                    d_ps_v <= pd_ps_v; d_aspect <= pd_aspect; d_pcol <= pd_colour; d_timing_v <= pd_timing_v; d_nuit <= pd_nuit;
                    d_ts <= pd_ts; d_crop <= pd_crop; d_pts <= pd_pts; d_pts_v <= pd_pts_v; d_eos <= pd_eos;
                    sel <= 1'b1;
                    st <= I_CHK;
                end
                I_CHK: if (d_store < NST[4:0] && oq_hold[d_store]) begin   // the store rule broken
                    pd_busy <= 1'b1; st <= I_ACK;
                end else begin
                    o_we <= 1'b1; o_second <= 1'b0;                              // the "a" half
                    if (d_pair) st <= I_B; else st <= I_E;
                end
                I_B: begin o_we <= 1'b1; o_second <= 1'b1; st <= I_E; end    // a pair's "b" half
                I_E: begin o_emit <= 1'b1; if (d_eos) st <= I_EOS; else st <= I_ACK; end
                I_EOS: begin o_eos <= 1'b1; st <= I_ACK; end                  // a cycle after the emission
                I_ACK: begin pd_ack <= 1'b1; st <= I_WAIT; end
                I_WAIT: if (!rq2) begin pd_ack <= 1'b0; pd_busy <= 1'b0; st <= I_IDLE; end
                default: st <= I_IDLE;
            endcase
        end
    end

    // counted on the edge recon_out raises the store's hold (o_emit is what it samples)
    always_ff @(posedge clk or negedge cnt_rst_n)
        if (!cnt_rst_n) pic_emitted <= '0;
        else if (o_emit) pic_emitted <= pic_emitted + 32'd1;

    // ---- the mux in front of recon_out ----
    always_comb begin
        if (sel) begin
            pinfo_we       = o_we;
            pinfo_store    = d_store;
            pinfo_second   = o_second;
            pinfo_w_mbs    = d_w;
            pinfo_hf_mbs   = d_hf;
            pinfo_crop     = {1'b0, d_crop};               // cuy4 0: the crop's rows are pairs of frame lines
            pinfo_aspect   = d_aspect;
            pinfo_colour   = d_colour;
            pinfo_col_unsup = 1'b0;
            pinfo_col_tags = {1'b0, 1'b0, 8'd2, 8'd2, 8'd2};
            pinfo_siting   = 6'd0;
            pinfo_timing_v = d_timing_v;
            pinfo_nuit     = d_nuit;
            pinfo_ts       = d_ts;
            pinfo_ps       = o_second ? 4'd0 : d_ps;
            pinfo_ps_v     = o_second ? 1'b0 : d_ps_v;
            pinfo_pts      = o_second ? 33'd0 : d_pts;
            pinfo_pts_v    = o_second ? 1'b0 : d_pts_v;
            pinfo_idr      = 1'b0;
            emit_valid     = o_emit;
            emit_store     = d_store;
            emit_unpaired  = 1'b0;
            emit_first_bot = (d_struct == 2'd2);
            emit_frame     = !d_pair;
            emit_dec_t     = 1'b1;
            emit_dec_b     = 1'b1;
            eos_done       = o_eos;
        end else begin
            pinfo_we       = r_pinfo_we;
            pinfo_store    = r_pinfo_store;
            pinfo_second   = r_pinfo_second;
            pinfo_w_mbs    = r_pinfo_w_mbs;
            pinfo_hf_mbs   = r_pinfo_hf_mbs;
            pinfo_crop     = r_pinfo_crop;
            pinfo_aspect   = r_pinfo_aspect;
            pinfo_colour   = r_pinfo_colour;
            pinfo_col_unsup = r_pinfo_col_unsup;
            pinfo_col_tags = r_pinfo_col_tags;
            pinfo_siting   = r_pinfo_siting;
            pinfo_timing_v = r_pinfo_timing_v;
            pinfo_nuit     = r_pinfo_nuit;
            pinfo_ts       = r_pinfo_ts;
            pinfo_ps       = r_pinfo_ps;
            pinfo_ps_v     = r_pinfo_ps_v;
            pinfo_pts      = r_pinfo_pts;
            pinfo_pts_v    = r_pinfo_pts_v;
            pinfo_idr      = r_pinfo_idr;
            emit_valid     = r_emit_valid;
            emit_store     = r_emit_store;
            emit_unpaired  = r_emit_unpaired;
            emit_first_bot = r_emit_first_bot;
            emit_frame     = r_emit_frame;
            emit_dec_t     = r_emit_dec_t;
            emit_dec_b     = r_emit_dec_b;
            eos_done       = r_eos_done;
        end
    end

endmodule

`default_nettype wire
