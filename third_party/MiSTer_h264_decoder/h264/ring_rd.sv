// h264/ring_rd.sv -- the HPS interface's reader (roadmap Phase 3; docs/architecture.md "The
// HPS interface, v0.1"): the ring of records a program on the ARM writes into DDR3 ->
// the decoder's input {byte, PTS mark, access-unit end} + the stream's events, and the
// status block's writes back. The layout is tools/ring_layout.py's (h264/ring_iface.svh);
// the model the bench scores against is tools/ring_model.py, written from the
// architecture text. Template: UMD's umd/vbuf.sv (an engine on ram1's master B, a clk_sys
// side, a clear handshake that never withdraws a command).
//
// TWO DOMAINS.
//   clk_mem  the ENGINE, reset by the PLL lock only (mrst_n): ddr_mux2's master B has no
//            abort, and a master reset while a request is held under waitrequest
//            withdraws it (UMD's reload hang). One command at a time, never withdrawn:
//              * status: a burst of eight words of the status block (ring_stat pushes
//                them into u_sf and toggles grp_tog after each eighth word; 0.6: the input
//                region's groups too -- a group's address is its first word's, 7 bits);
//              * poll: words 32-39 of the control block (write index, nonce, pause, settings,
//                rumble, 1.2 geometry request: one burst) -- when
//                caught up with the last write index seen, every POLL_FAST cycles; always
//                at least every POLL_SLOW (a new nonce is seen mid-stream). A read holds
//                ram1's grant through its latency: docs/hw_budget_and_lessons.md S2;
//              * read: up to eight ring words below the observed write index, never across
//                the ring's end, when the data FIFO has room for them.
//            The write index is checked on arrival (a multiple of 16; not more than a
//            ring ahead of what was fetched; never backwards): a failure stops the
//            fetching (eng_err) until the next session.
//            THE SESSION. The first nonce read after the lock is recorded and IGNORED
//            (DDR3 survives a core load: an earlier program's nonce and ring must not
//            replay). A later change starts a session at the write index read in the SAME
//            poll (rounded down to 16): indices are never zeroed, so no pair of ARM stores
//            can be seen half done. An OSD reset (rst_n, synchronised) drops the session.
//   clk_sys  the PARSER, reset by rst_n (the core's reset_n, NOT the per-stream reset: the
//            words behind a DISCONTINUITY are the next stream's). It walks the records:
//            the header's checks in the order the interface lists them (type, CONTROL,
//            flags, length, the ring's end, seq; word 1's sync; the stream's state), the
//            first failure kept with its position and word; a VIDEO_AU's payload out as
//            bytes (the first marked with the PTS when PTS_VALID, the last with au_end);
//            PAD skipped a word a cycle; AUDIO (0.5) queued as a descriptor {index, length,
//            PTS} for h264/aud_play.sv -- the parser waits at its header while the
//            descriptor FIFO is full -- and its payload skipped (the audio path fetches it
//            from the ring when it is about to play). DISCONTINUITY: stream_clr (fe_rst_n =
//            reset_n & ~stream_clr) for CLR_HOLD cycles, then SETTLE quiet cycles (the
//            clk_dec / clk_mem releases are two flops behind), then the payload -- after
//            an END_OF_STREAM it first waits for the display to take the END (disp_ended)
//            and (0.5) for the queued audio to play out (aud_idle), at most END_WAIT cycles.
//            END_OF_STREAM: `eos` (vidfeed_cdc's wr_flush) after the payload, until the
//            next stream reset.
// THE RING IS THE AUDIO'S BUFFER (0.5, docs/architecture.md "Audio (Phase 4)"). The published
// read index (word 5) is the RELEASED index: the start of the oldest AUDIO record not yet
// played (aud_play's a_hold_*), else the start of the record the parser is at. It is built
// on clk_sys (rel_s), crossed by a cdc_snap, and taken by the engine only inside the
// session's [start, fetched] and never backwards -- a snapshot taken before a session's clear
// can never move it. The engine checks the write index against it (WIDX_RANGE). The audio
// fetch: aud_play asks for up to eight words at a ring index (af_go; a toggle with stable
// fields, answered after the words are pushed); the engine serves it between its other
// commands (after the status writes and the polls, before the ring reads) into u_af, a
// fifo_dc reset by the PLL lock only (aud_play counts what it is owed across any reset).
// THE PAUSE WORD (0.5, program word 34): read with every poll; a word with a reserved bit set
// is refused whole (ctl_err). PAUSE applies during a session: the engine stops fetching the
// ring (polls, status writes and the audio's fetch go on); its level, ATTEN and ctl_err
// cross to clk_sys (cdc_snap) for the display, the STC and the audio path.
// THE RUMBLE (0.13, program words 36-38; docs/architecture.md "Rumble (interface 0.13)"): their
// low halves read with every poll, taken whole when the poll ends, passed on only while a session
// is open (0 otherwise: no session, nothing rumbles), crossed to clk_sys (cdc_snap) for hps_io's
// joystick_N_rumble; rum_changes counts the changes that reached clk_sys. Every value is valid
// (two u16 a u32, no reserved bits): nothing to refuse.
// PICTURE (0.15, docs/architecture.md "Pictures from the program"): a picture the program wrote
// into a DPB store itself. Its 32 bytes are taken through the word register into pdw0-3 (the
// reserved bits checked as each word lands), checked (the descriptor's fields, the store, the
// size -- w x hf by an 8-step shift-add, no DSP -- the crop), then handed to h264/pic_in.sv
// (clk_dec) by a four-phase level handshake: pd_req up with the descriptor stable behind it,
// pic_in's pd_ack up (pd_busy set a cycle before it: the store was still held, PIC_BUSY),
// pd_req down, pd_ack down. A session clear waits for a hand-over in flight (P_PWAIT /
// P_PDONE), so a flush never drops a picture pic_in has taken. A stream's first video record
// decides its kind (pic_mode): a VIDEO_AU in a picture stream, or a PICTURE in a coded one, is
// STREAM_KIND. A PICTURE's END_OF_STREAM sets eos_seen but not `eos` (vidfeed_cdc's flush: the
// decoder has nothing to flush, and its eos_done would race pic_in's).
// THE CLEAR (a session starts or drops; also once after the lock): the engine, between
// commands, holds its side of the data FIFO in reset and raises clr_req (start and
// new_sess stable before it); the parser holds its side in reset, resets its record state
// (and the stream, for a new session) and raises clr_ack; the engine sets its indices,
// releases its side and drops clr_req; the parser releases its side and drops clr_ack.
// Both sides of the FIFO are in reset together while nothing moves (h264/fifo_dc.sv).
// The status FIFO is not cleared: both its sides reset with the PLL lock only (lrst_n,
// mrst_n), so the heartbeat never restarts on an OSD reset.
//
// Quartus 17: no functions, no N'() casts, power-of-two FIFO depths (M10K).

`default_nettype none

module ring_rd #(
    parameter logic [28:0] CTRL_WORD = 29'h0628_0000,   // the control block (word address)
    parameter logic [28:0] RING_WORD = 29'h0630_0000,   // the ring (word address)
    parameter int RING_AW   = 20,                       // log2(ring words): 8 MB
    parameter int POLL_FAST = 2880,                     // clk_mem cycles: 32 us at 90 MHz
    parameter int POLL_SLOW = 90000,                    // 1 ms
    parameter int CLR_HOLD  = 16,                       // clk_sys cycles of stream_clr
    parameter int SETTLE    = 32,                       // clk_sys cycles after it
    parameter int END_WAIT  = 81000000                  // clk_sys cycles: 3 s at 27 MHz
) (
    // ---- clk_sys ----
    input  wire          clk,
    input  wire          rst_n,            // reset_n: the core's reset (OSD Reset drops the session)
    input  wire          lrst_n,           // the PLL lock alone, into clk_sys: the status FIFO
    output logic   [7:0] es_byte,
    output logic         es_mark,
    output logic  [32:0] es_pts,
    output logic         es_au_end,
    output logic         es_valid,
    input  wire          es_ready,
    output logic         stream_clr,       // the per-stream reset (fe_rst_n = reset_n & ~stream_clr)
    output logic         eos,              // END_OF_STREAM consumed: vidfeed_cdc's wr_flush
    output logic         ll_mode,          // the stream's first VIDEO_AU asked for LOW_LATENCY
    output logic         gfx_mode,         // (0.4) the stream's first VIDEO_AU declared GRAPHICS
    output logic         vid_seen,         // (0.5) the stream has had a VIDEO_AU (ll_mode is its own, not the last stream's)
    input  wire          disp_ended,       // disp_ctl: the display took the stream's END
    // 0.5: the audio path (h264/aud_play.sv, clk_sys): descriptors out, the held index in
    output logic         ad_push,          // one cycle: an AUDIO record queued
    output logic  [31:0] ad_pos,           // its index (the record's start)
    output logic  [22:0] ad_len,           // its payload length in bytes (a multiple of 4, <= MAX_PAYLOAD)
    output logic  [32:0] ad_pts,
    output logic         ad_ptsv,
    input  wire          ad_room,          // the descriptor FIFO can take one
    input  wire          a_hold_v,         // an AUDIO record is queued, not yet played
    input  wire   [31:0] a_hold_idx,       // ... the oldest one's index
    input  wire          aud_idle,         // nothing queued or playing (a DISCONTINUITY after EOS waits for it)
    output logic  [31:0] hold_bytes,       // ring bytes the audio holds behind the parser (status)
    // 0.5: the audio's fetch (clk_sys side): up to eight words at a ring byte index
    input  wire          af_go,            // one cycle, ignored while af_busy
    input  wire   [31:0] af_addr,          // a ring index, 8-aligned
    input  wire    [3:0] af_n,             // 1..8 words, never across the ring's end
    output logic         af_busy,
    output logic  [63:0] af_dout,          // u_af's read side (PULL: dout / valid the cycle after rd)
    output logic         af_valid,
    output logic         af_empty,
    input  wire          af_rd,
    // 0.5: word 34 as applied (clk_sys)
    output logic         ctl_pause,        // PAUSE, during a session
    output logic         ctl_err,          // the last word read was refused
    output logic   [7:0] ctl_atten,
    // 0.13: the pads' rumble (program words 36-38) as passed to Main (clk_sys)
    output logic  [95:0] rumble,           // pad n at [16n +: 16], {large, small}; 0 outside a session
    output logic  [31:0] rum_changes,      // the value above changed (any pad), since the PLL lock (wrapping)
    // the status block's words, from ring_stat (clk_sys, lrst_n)
    input  wire   [63:0] st_word,
    input  wire    [6:0] st_ix,            // 0.6: 7 bits (the input region's words 48-71)
    input  wire          st_wr,
    input  wire          st_grp,           // pulse: the eighth word of a group was pushed
    output logic   [6:0] st_free,          // 0.6: the status FIFO's free words (ring_stat checks a job's room)
    // the parser's status fields (clk_sys)
    output logic         sess,             // a session is open
    output logic   [7:0] state,
    output logic   [7:0] err,
    output logic  [31:0] err_pos,
    output logic  [63:0] err_word,
    output logic         eos_seen,         // live EOS
    output logic  [31:0] n_au,
    output logic  [31:0] n_audio,
    output logic  [31:0] n_pad,
    output logic  [31:0] n_streams,
    output logic  [31:0] es_bytes,
    output logic  [31:0] ll_mismatch,
    output logic  [15:0] gfx_mismatch,     // (0.4) VIDEO_AUs whose GRAPHICS differs from the first (saturating)
    output logic  [2:0]  colour_mode,      // (0.16, docs/colour.md) the stream's first VIDEO_AU's colour (0 auto; a picture stream 0)
    output logic  [15:0] colour_mismatch,  // (0.16) VIDEO_AUs whose colour differs from the stream's first (per stream, saturating)
    // 0.15: a PICTURE's descriptor to h264/pic_in.sv (clk_dec): pd_req and the fields quasi-static
    // behind it (h264.sdc), pd_ack / pd_busy back
    output logic         pd_req,
    output logic   [4:0] pd_store,
    output logic   [7:0] pd_w,
    output logic   [7:0] pd_hf,
    output logic   [1:0] pd_struct,        // 0 frame, 1 pair top first, 2 pair bottom first
    output logic   [3:0] pd_ps,
    output logic         pd_ps_v,
    output logic  [39:0] pd_aspect,        // {aspect_ratio_idc, sar_w, sar_h}
    output logic  [2:0]  pd_colour,        // (0.16) the PICTURE's colour (header word 1 [35:33]; 0 auto)
    output logic         pd_timing_v,
    output logic  [31:0] pd_nuit,
    output logic  [31:0] pd_ts,
    output logic  [39:0] pd_crop,          // {left, right, top, bottom}, pairs of samples / frame lines
    output logic  [32:0] pd_pts,
    output logic         pd_pts_v,
    output logic         pd_eos,           // the record carries END_OF_STREAM: eos_done after the emission
    input  wire          pd_ack,
    input  wire          pd_busy,
    output logic         pic_mode,         // the stream's first video record was a PICTURE (word 84)

    // ---- clk_mem: ddr_mux2 master B ----
    input  wire          mclk,
    input  wire          mrst_n,           // the PLL lock only
    output logic  [28:0] b_address,
    output logic   [7:0] b_burstcount,
    output logic         b_read,
    output logic         b_write,
    output logic  [63:0] b_writedata,
    input  wire          b_waitrequest,
    input  wire   [63:0] b_readdata,
    input  wire          b_readdatavalid,
    // the engine's status fields (clk_mem)
    output logic  [31:0] read_index,
    output logic  [31:0] ack_nonce,
    output logic  [31:0] n_polls,
    output logic  [31:0] n_bursts,
    output logic   [7:0] eng_err,
    output logic         eng_session,
    output logic  [31:0] eng_widx,
    // interface 0.4: the settings request (program word 35), handed to clk_sys: a new
    // sequence number during a session sets set_word and toggles set_tog (set_word is stable
    // for a poll period before the next toggle: quasi-static, h264.sdc)
    output logic  [31:0] set_word,
    output logic         set_tog,
    // (1.2) calibrated geometry, a stable {clip word 88, request word 39} bundle on clk_sys.
    output wire  [127:0] geom_data,
    output wire   [7:0]  geom_ack_seq,
    output wire   [1:0]  geom_error
);

`include "h264/ring_iface.svh"

    localparam logic [31:0] RING_BYTES = 32'd1 << (RING_AW + 3);
    localparam logic [RING_AW:0] RING_WORDS = 1 << RING_AW;
    localparam logic [16:0] POLL_FAST_W = POLL_FAST[16:0];     // sized, not cast (Quartus 17)
    localparam logic [16:0] POLL_SLOW_W = POLL_SLOW[16:0];
    localparam logic [7:0]  CLR_HOLD_W  = CLR_HOLD[7:0];
    localparam logic [7:0]  SETTLE_W    = SETTLE[7:0];
    localparam logic [26:0] END_WAIT_W  = END_WAIT[26:0];

    // ---- the crossings (declared first: both sides read them) ----
    logic        clr_req;                  // clk_mem -> clk_sys
    logic        new_sess;                 // clk_mem, stable while clr_req
    logic [31:0] start;                    // clk_mem, stable while clr_req
    logic        clr_ack;                  // clk_sys -> clk_mem
    logic        eng_errf;                 // clk_mem: eng_err != 0 (a level)
    logic [31:0] eng_bad_wi;               // clk_mem: the write index that failed, stable while eng_errf
    logic        grp_tog;                  // clk_sys -> clk_mem: one toggle per status group
    logic        m_frst_n, s_frst_n;       // the data FIFO's sides

    // =================================================================== clk_sys: parser
    logic        req_s1, req_s2, ef_s1, ef_s2;
    always_ff @(posedge clk) begin
        req_s1 <= clr_req; req_s2 <= req_s1;
        ef_s1 <= eng_errf; ef_s2 <= ef_s1;
    end

    // the data FIFO's read side
    logic        rf_empty, rf_valid, rf_rd;
    logic [63:0] rf_dout;

    typedef enum logic [4:0] {
        P_WAIT, P_IDLE, P_RST, P_SETTLE, P_H0, P_H1, P_AUSTART, P_PAY, P_SKIP, P_WEND, P_ERR, P_ADESC,
        P_PSTART, P_PDESC, P_PCHK, P_PWAIT, P_PDONE      // 0.15: a PICTURE
    } pst_t;
    pst_t        ps;
    logic        cack;                     // the clear acknowledged, waiting for clr_req to drop
    logic        have, pulled;             // a word in `word`; a pop in flight
    logic [63:0] word;
    logic [2:0]  lane;                     // the next byte within `word`
    logic [31:0] rpos;                     // the record's start index
    logic [15:0] seq;
    logic [63:0] h0;                       // the header's word 0
    logic [32:0] pts;
    logic [31:0] bleft;                    // payload bytes still to deliver
    logic [29:0] wleft;                    // payload words still to take (padding included)
    logic        first_byte, first_au, pay_after;
    logic [7:0]  hold_cnt;
    logic [26:0] end_cnt;
    logic        au_seen;                  // a VIDEO_AU since the stream began (READY / PLAYING)
    logic [7:0]  perr;
    logic [31:0] perr_pos;
    logic [63:0] perr_word;
    logic        e_cap;                    // the engine's error was the first
    logic [7:0]  q_eng_err;
    logic [31:0] q_eng_wi;
    // 0.15: the PICTURE's descriptor, its checks, the hand-over
    logic [63:0] pdw0, pdw1, pdw2, pdw3;
    logic [1:0]  dk;                       // the next descriptor word
    logic        rsv_bad;                  // a reserved bit was set in a word taken so far
    logic [15:0] area, msh;                // w x hf, by shift-add: the running sum, w shifted
    logic [7:0]  hsh;                      // hf, shifted the other way
    logic        pa_s1, pa_s2, pb_s1, pb_s2;   // pd_ack / pd_busy into clk_sys
    logic        pd_bq;                    // pd_busy as it stood with pd_ack (pic_in drops both together)
    always_ff @(posedge clk) begin pa_s1 <= pd_ack; pa_s2 <= pa_s1; pb_s1 <= pd_busy; pb_s2 <= pb_s1; end

    // header word 0's fields and its checks (combinational, from the word as it lands)
    wire  [7:0]  t_type  = word[7:0];
    wire  [7:0]  t_flags = word[15:8];
    wire  [15:0] t_seq   = word[31:16];
    wire  [31:0] t_len   = word[63:32];
    wire         t_video = (t_type == RT_VIDEO_AU);
    wire         t_pad   = (t_type == RT_PAD);
    wire         t_audio = (t_type == RT_AUDIO);
    wire         t_pic   = (t_type == RT_PICTURE);     // 0.15
    // the flags a type may carry (ring_layout.py FLAGS): VIDEO_AU (0.15: and PICTURE) PTS_VALID /
    // DISCONTINUITY / END_OF_STREAM / LOW_LATENCY / GRAPHICS (0.4); AUDIO PTS_VALID
    wire  [7:0]  t_allow = (t_video || t_pic) ? 8'h1F : (t_audio ? 8'h01 : 8'h00);
    wire  [32:0] t_n     = 33'd16 + {1'b0, t_len[31:4], 4'd0} + {28'd0, (t_len[3:0] != 4'd0), 4'd0};   // 16 + pad16(len)
    wire  [32:0] t_off   = {1'b0, rpos & (RING_BYTES - 32'd1)};
    wire  [32:0] t_endp  = t_off + t_n;
    logic [7:0]  h0_err;
    always_comb begin
        h0_err = RE_NONE;
        if (!(t_video || t_pad || t_audio || t_pic || t_type == RT_CONTROL)) h0_err = RE_HDR_TYPE;
        else if (t_type == RT_CONTROL)                             h0_err = RE_CONTROL_UNSUPPORTED;
        else if ((t_flags & ~t_allow) != 8'd0)                     h0_err = RE_HDR_FLAGS;
        else if (t_len > RI_MAX_PAYLOAD || (t_video && t_len == 32'd0) ||
                 (t_audio && (t_len == 32'd0 || t_len[1:0] != 2'd0)) ||    // 0.5: whole frames
                 (t_pic && t_len != {24'd0, RI_PIC_PAYLOAD}))              h0_err = RE_HDR_LENGTH;   // 0.15: exactly 32
        else if (t_pad ? (t_endp != {1'b0, RING_BYTES}) : (t_endp > {1'b0, RING_BYTES})) h0_err = RE_HDR_WRAP;
        else if (t_seq != seq)                                     h0_err = RE_HDR_SEQ;
    end
    wire         w1_bad  = (word[63:48] != RI_SYNC) || (word[47:36] != 12'd0);   // (0.16: [35:33] the colour)
    wire  [2:0]  w1_col  = word[35:33];
    logic [2:0]  h_col;                    // (0.16) the record's colour, from header word 1
    wire         h_video = (h0[7:0] == RT_VIDEO_AU);
    wire         h_pic   = (h0[7:0] == RT_PICTURE);         // 0.15
    wire         h_vrec  = h_video || h_pic;                // a video record of either kind
    wire  [7:0]  h_flags = h0[15:8];
    wire  [31:0] h_len   = h0[63:32];
    wire  [29:0] h_words = {h_len[31:4], 1'b0} + {28'd0, (h_len[3:0] != 4'd0), 1'b0};         // pad16(len) / 8

    wire want_word = (ps == P_H0 || ps == P_H1 || ps == P_PAY || ps == P_SKIP || ps == P_PDESC);

    // 0.15: the PICTURE's descriptor (docs/architecture.md "Pictures from the program") and its
    // checks, in the interface's order (the fields, the store, the size, the crop)
    wire  [4:0]  q_store = pdw0[4:0];
    wire  [7:0]  q_w     = pdw0[15:8];
    wire  [7:0]  q_hf    = pdw0[23:16];
    wire  [1:0]  q_st    = pdw0[25:24];
    wire  [3:0]  q_ps    = pdw0[35:32];
    wire         q_psv   = pdw0[36];
    wire  [7:0]  q_idc   = pdw0[47:40];
    wire  [15:0] q_sarw  = pdw1[15:0];
    wire  [15:0] q_sarh  = pdw1[31:16];
    wire         q_tv    = pdw1[32];
    wire  [31:0] q_nuit  = pdw2[31:0];
    wire  [31:0] q_ts    = pdw2[63:32];
    wire  [10:0] q_lr    = {1'b0, pdw3[9:0]} + {1'b0, pdw3[19:10]};
    wire  [10:0] q_tb    = {1'b0, pdw3[29:20]} + {1'b0, pdw3[39:30]};
    wire         q_pair  = (q_st != 2'd0);
    wire         ps_ok   = (q_ps == 4'd0) || (q_ps >= 4'd3 && q_ps <= 4'd8);
    wire         f_bad   = rsv_bad || q_st == 2'd3 || (q_psv && (q_pair || !ps_ok)) ||
                           (q_idc >= 8'd17 && q_idc <= 8'd254) || (q_idc == 8'd255 && (q_sarw == 16'd0 || q_sarh == 16'd0)) ||
                           (q_tv && (q_nuit == 32'd0 || q_ts == 32'd0));
    wire         s_bad   = (q_store >= RI_DPB_STORES[4:0]);
    wire         z_bad   = (q_w == 8'd0) || (q_hf == 8'd0) || (q_w > RI_PIC_MAX_SIDE) || (q_hf > RI_PIC_MAX_SIDE) ||
                           (q_pair && q_hf[0]) || (area > RI_CAP_MAX_MBS);
    wire         c_bad   = (q_lr >= {q_w, 3'b000}) || (q_tb >= {q_hf, 3'b000});
    wire  [7:0]  pic_err = f_bad ? RE_PIC_FIELD : s_bad ? RE_PIC_STORE : z_bad ? RE_PIC_SIZE :
                           c_bad ? RE_PIC_CROP : RE_NONE;
    wire  [63:0] rsv_m   = (dk == 2'd0) ? RI_PIC_RSV0 : (dk == 2'd1) ? RI_PIC_RSV1 : (dk == 2'd3) ? RI_PIC_RSV3 : 64'd0;
    wire         pd_hold = (ps == P_PWAIT) || (ps == P_PDONE);   // a hand-over in flight: the clear waits
    assign pd_store    = q_store;
    assign pd_w        = q_w;
    assign pd_hf       = q_hf;
    assign pd_struct   = q_st;
    assign pd_ps       = q_ps;
    assign pd_ps_v     = q_psv;
    assign pd_aspect   = {q_idc, q_sarw, q_sarh};
    assign pd_colour   = h_col;            // held: the next header is read only after the hand-over
    assign pd_timing_v = q_tv;
    assign pd_nuit     = q_nuit;
    assign pd_ts       = q_ts;
    assign pd_crop     = {pdw3[9:0], pdw3[19:10], pdw3[29:20], pdw3[39:30]};   // recon_out's order: left first
    assign pd_pts      = h_flags[RF_PTS_VALID] ? pts : 33'd0;
    assign pd_pts_v    = h_flags[RF_PTS_VALID];
    assign pd_eos      = h_flags[RF_END_OF_STREAM];
    assign rf_rd   = want_word && !rf_empty && !have && !pulled;
    // the word is used up: a header word, a skipped word, or a payload word's last byte
    wire  give     = es_valid && es_ready;
    wire  pay_last = (bleft == 32'd1) || (lane == 3'd7);

    assign es_valid  = (ps == P_PAY) && have && (bleft != 32'd0);
    assign es_byte   = word[{lane, 3'b000} +: 8];
    assign es_mark   = first_byte && h_flags[RF_PTS_VALID];
    assign es_pts    = es_mark ? pts : 33'd0;
    assign es_au_end = (bleft == 32'd1);

    // 0.5: an AUDIO record's descriptor, pushed from P_ADESC when the FIFO has room (the walk
    // is paused while a clear is open)
    assign ad_push = (ps == P_ADESC) && ad_room && !cack && !req_s2;
    assign ad_pos  = rpos;
    assign ad_len  = h_len[22:0];          // <= MAX_PAYLOAD (4 MiB = 2^22), checked at P_H0
    assign ad_pts  = pts;
    assign ad_ptsv = h_flags[RF_PTS_VALID];

    // 0.5: the released index -- the oldest unplayed AUDIO record, else the parser's record
    logic [31:0] rel_s;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin rel_s <= '0; hold_bytes <= '0; end
        else begin
            rel_s <= a_hold_v ? a_hold_idx : rpos;
            hold_bytes <= rpos - rel_s;
        end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ps <= P_WAIT; cack <= 1'b0; clr_ack <= 1'b0; s_frst_n <= 1'b0; sess <= 1'b0;
            have <= 1'b0; pulled <= 1'b0; word <= '0; lane <= '0; rpos <= '0; seq <= '0;
            h0 <= '0; pts <= '0; bleft <= '0; wleft <= '0; first_byte <= 1'b0; first_au <= 1'b1;
            pay_after <= 1'b0; hold_cnt <= '0; end_cnt <= '0; au_seen <= 1'b0;
            stream_clr <= 1'b0; eos <= 1'b0; eos_seen <= 1'b0; ll_mode <= 1'b0; gfx_mode <= 1'b0;
            perr <= '0; perr_pos <= '0; perr_word <= '0; e_cap <= 1'b0; q_eng_err <= '0; q_eng_wi <= '0;
            pdw0 <= '0; pdw1 <= '0; pdw2 <= '0; pdw3 <= '0; dk <= '0; rsv_bad <= 1'b0; area <= '0; msh <= '0; hsh <= '0;
            pd_req <= 1'b0; pd_bq <= 1'b0; pic_mode <= 1'b0;
            n_au <= '0; n_audio <= '0; n_pad <= '0; n_streams <= '0; es_bytes <= '0; ll_mismatch <= '0; gfx_mismatch <= '0; colour_mode <= '0; colour_mismatch <= '0; h_col <= '0;
        end else begin
            // ---- the engine's error (quasi-static behind its flag) ----
            if (ef_s2 && !e_cap && q_eng_err == 8'd0) begin
                q_eng_err <= eng_err; q_eng_wi <= eng_bad_wi; e_cap <= (perr == 8'd0);
            end
            if (!ef_s2) begin q_eng_err <= '0; e_cap <= 1'b0; end

            // ---- the word register ----
            pulled <= rf_rd;
            if (rf_valid && pulled) begin word <= rf_dout; have <= 1'b1; end

            // ---- the clear (answers the engine; 0.15: after a PICTURE's hand-over in flight) ----
            if (req_s2 && !cack && !pd_hold) begin
                s_frst_n <= 1'b0; have <= 1'b0; pulled <= 1'b0; lane <= '0;
                sess <= new_sess; rpos <= start; seq <= '0; perr <= '0; perr_pos <= '0; perr_word <= '0;
                first_byte <= 1'b0; pay_after <= 1'b0;
                if (new_sess) ps <= P_RST; else ps <= P_IDLE;
                hold_cnt <= '0;
                clr_ack <= 1'b1; cack <= 1'b1;
            end else if (cack && !req_s2) begin
                s_frst_n <= 1'b1; clr_ack <= 1'b0; cack <= 1'b0;
            end

            // ---- the record walk (paused while the clear is open; 0.15: but a hand-over finishes) ----
            if (!cack && (!req_s2 || pd_hold)) case (ps)
                P_WAIT, P_IDLE, P_ERR: ;
                P_RST: begin                                   // the stream reset
                    if (hold_cnt == 8'd0) begin                // a new stream: its state from scratch
                        n_streams <= n_streams + 32'd1;
                        eos <= 1'b0; eos_seen <= 1'b0; au_seen <= 1'b0; first_au <= 1'b1; pic_mode <= 1'b0;
                    end
                    stream_clr <= 1'b1;
                    hold_cnt <= hold_cnt + 8'd1;
                    if (hold_cnt == CLR_HOLD_W) begin stream_clr <= 1'b0; hold_cnt <= '0; ps <= P_SETTLE; end
                end
                P_SETTLE: begin
                    hold_cnt <= hold_cnt + 8'd1;
                    if (hold_cnt == SETTLE_W) begin
                        hold_cnt <= '0; pay_after <= 1'b0;
                        if (pay_after && h_pic) ps <= P_PSTART; else if (pay_after) ps <= P_AUSTART; else ps <= P_H0;
                    end
                end
                P_H0: if (have) begin
                    have <= 1'b0; h0 <= word;
                    if (h0_err != RE_NONE) begin
                        if (!e_cap) begin perr <= h0_err; perr_pos <= rpos; perr_word <= word; end
                        ps <= P_ERR;
                    end else ps <= P_H1;
                end
                P_H1: if (have) begin
                    have <= 1'b0; pts <= word[32:0]; h_col <= w1_col;
                    wleft <= h_words; bleft <= h_len;
                    if (w1_bad) begin
                        if (!e_cap) begin perr <= RE_HDR_SYNC; perr_pos <= rpos; perr_word <= h0; end
                        ps <= P_ERR;
                    end else if (w1_col == 3'd7 || (w1_col != 3'd0 && !h_vrec)) begin   // (0.16)
                        if (!e_cap) begin perr <= RE_HDR_COLOUR; perr_pos <= rpos; perr_word <= h0; end
                        ps <= P_ERR;
                    end else if (h_vrec && eos_seen && !h_flags[RF_DISCONTINUITY]) begin
                        if (!e_cap) begin perr <= RE_NEED_DISCONT; perr_pos <= rpos; perr_word <= h0; end
                        ps <= P_ERR;
                    end else if (h_vrec && h_flags[RF_DISCONTINUITY]) begin
                        pay_after <= 1'b1; end_cnt <= '0; hold_cnt <= '0;
                        if (eos_seen && !disp_ended) ps <= P_WEND;   // the flush stays up until the reset
                        else ps <= P_RST;
                    end else if (h_video) begin
                        ps <= P_AUSTART;
                    end else if (h_pic) begin                  // 0.15
                        ps <= P_PSTART;
                    end else if (h0[7:0] == RT_PAD) begin
                        n_pad <= n_pad + 32'd1;
                        ps <= P_SKIP;
                    end else ps <= P_ADESC;                    // AUDIO (0.5): queue it
                end
                P_ADESC: if (ad_room) begin                    // the descriptor is pushed this cycle
                    n_audio <= n_audio + 32'd1;
                    ps <= P_SKIP;                              // then its payload is skipped
                end
                P_WEND: begin                                  // DISCONTINUITY after EOS: the last picture first
                    end_cnt <= end_cnt + 27'd1;                // (0.5: and the queued audio)
                    if ((disp_ended && aud_idle) || end_cnt == END_WAIT_W) ps <= P_RST;
                end
                P_AUSTART: begin
                    if (!first_au && pic_mode) begin           // 0.15: a VIDEO_AU in a picture stream
                        if (!e_cap) begin perr <= RE_STREAM_KIND; perr_pos <= rpos; perr_word <= h0; end
                        ps <= P_ERR;
                    end else begin
                        if (first_au) begin                // the stream's first video record: a VIDEO_AU
                            ll_mode <= h_flags[RF_LOW_LATENCY]; gfx_mode <= h_flags[RF_GRAPHICS]; first_au <= 1'b0;
                            colour_mode <= h_col; colour_mismatch <= '0;   // (0.16) the stream's colour
                        end else begin
                            if (ll_mode != h_flags[RF_LOW_LATENCY]) ll_mismatch <= ll_mismatch + 32'd1;
                            if (gfx_mode != h_flags[RF_GRAPHICS] && gfx_mismatch != 16'hFFFF) gfx_mismatch <= gfx_mismatch + 16'd1;
                            if (colour_mode != h_col && colour_mismatch != 16'hFFFF) colour_mismatch <= colour_mismatch + 16'd1;
                        end
                        n_au <= n_au + 32'd1; au_seen <= 1'b1;
                        first_byte <= 1'b1; lane <= '0;
                        ps <= P_PAY;
                    end
                end
                // 0.15: a PICTURE -- the stream's kind, the descriptor, the checks, the hand-over
                P_PSTART: begin
                    if (!first_au && !pic_mode) begin          // a PICTURE in a coded stream
                        if (!e_cap) begin perr <= RE_STREAM_KIND; perr_pos <= rpos; perr_word <= h0; end
                        ps <= P_ERR;
                    end else begin
                        if (first_au) begin                // ... a PICTURE: a picture stream
                            gfx_mode <= h_flags[RF_GRAPHICS]; ll_mode <= h_flags[RF_LOW_LATENCY]; first_au <= 1'b0;
                            pic_mode <= 1'b1;
                            colour_mode <= '0; colour_mismatch <= '0;      // (0.16) a picture stream: per picture
                        end else begin
                            if (h_flags[RF_LOW_LATENCY] != ll_mode) ll_mismatch <= ll_mismatch + 32'd1;
                            if (h_flags[RF_GRAPHICS] != gfx_mode && gfx_mismatch != 16'hFFFF) gfx_mismatch <= gfx_mismatch + 16'd1;
                        end
                        au_seen <= 1'b1;
                        dk <= '0; rsv_bad <= 1'b0;
                        ps <= P_PDESC;
                    end
                end
                P_PDESC: if (have) begin                       // four words; the reserved bits as each lands
                    have <= 1'b0; wleft <= wleft - 30'd1; dk <= dk + 2'd1;
                    if ((word & rsv_m) != 64'd0) rsv_bad <= 1'b1;
                    case (dk)
                        2'd0: pdw0 <= word;
                        2'd1: pdw1 <= word;
                        2'd2: pdw2 <= word;
                        default: begin pdw3 <= word; area <= '0; msh <= {8'd0, pdw0[15:8]}; hsh <= pdw0[23:16];
                                       hold_cnt <= '0; ps <= P_PCHK; end
                    endcase
                end
                P_PCHK: begin                                  // w x hf, eight steps; then the checks
                    if (hold_cnt != 8'd8) begin
                        if (hsh[0]) area <= area + msh;
                        msh <= {msh[14:0], 1'b0}; hsh <= {1'b0, hsh[7:1]};
                        hold_cnt <= hold_cnt + 8'd1;
                    end else begin
                        hold_cnt <= '0;
                        if (pic_err != RE_NONE) begin
                            if (!e_cap) begin perr <= pic_err; perr_pos <= rpos; perr_word <= h0; end
                            ps <= P_ERR;
                        end else begin
                            pd_req <= 1'b1; ps <= P_PWAIT;
                        end
                    end
                end
                P_PWAIT: if (pa_s2) begin pd_req <= 1'b0; pd_bq <= pb_s2; ps <= P_PDONE; end   // pd_busy set a cycle before pd_ack
                P_PDONE: if (!pa_s2) begin
                    if (pd_bq) begin
                        if (!e_cap) begin perr <= RE_PIC_BUSY; perr_pos <= rpos; perr_word <= h0; end
                        ps <= P_ERR;
                    end else ps <= P_SKIP;                     // wleft is 0: the record's end
                end
                P_PAY: begin
                    if (give) begin
                        first_byte <= 1'b0;
                        bleft <= bleft - 32'd1;
                        es_bytes <= es_bytes + 32'd1;
                        lane <= lane + 3'd1;
                        if (pay_last) begin
                            have <= 1'b0; lane <= '0; wleft <= wleft - 30'd1;
                        end
                        if (bleft == 32'd1) ps <= P_SKIP;              // the padding (if any) next
                    end
                end
                P_SKIP: begin
                    if (wleft == 30'd0) begin                          // the record's end
                        if (h_vrec && h_flags[RF_END_OF_STREAM]) begin eos <= h_video; eos_seen <= 1'b1; end
                        rpos <= rpos + {h_words, 3'b000} + 32'd16;
                        seq <= seq + 16'd1;
                        ps <= P_H0;
                    end else if (have) begin
                        have <= 1'b0; wleft <= wleft - 30'd1;
                    end
                end
                default: ps <= P_ERR;
            endcase
        end
    end

    assign vid_seen = au_seen;
    assign state = !sess ? RS_NO_SESSION :
                   (perr != 8'd0 || e_cap) ? RS_ERROR :
                   (eos_seen && disp_ended) ? RS_ENDED :
                   !au_seen ? RS_READY : RS_PLAYING;
    assign err      = e_cap ? q_eng_err : perr;
    assign err_pos  = e_cap ? q_eng_wi : perr_pos;
    assign err_word = e_cap ? 64'd0 : perr_word;

    // ---- the status FIFO's write side, and its group toggle ----
    logic         sf_full;
    logic [6:0]   sf_free;
    assign st_free = sf_free;              // 0.6: ring_stat checks a frame's 40 or the input region's 24
    always_ff @(posedge clk or negedge lrst_n)
        if (!lrst_n) grp_tog <= 1'b0;
        else if (st_grp) grp_tog <= ~grp_tog;

    // =================================================================== clk_mem: engine
    logic        req_m1, ack_m1, ack_m2, rst_m1, rst_m2, gt_m1, gt_m2, gt_m3;
    always_ff @(posedge mclk) begin
        ack_m1 <= clr_ack; ack_m2 <= ack_m1;
        gt_m1 <= grp_tog; gt_m2 <= gt_m1; gt_m3 <= gt_m2;
    end
    // the OSD reset, synchronised (asserts asynchronously: rst_m2 low = the core is in reset)
    always_ff @(posedge mclk or negedge rst_n)
        if (!rst_n) begin rst_m1 <= 1'b0; rst_m2 <= 1'b0; end
        else        begin rst_m1 <= 1'b1; rst_m2 <= rst_m1; end

    logic        rf_full, rf_wr;
    logic [6:0]  rf_free;
    logic        sf_empty, sf_valid, sf_rd;
    logic [70:0] sf_dout;
    logic        af_wr;

    fifo_dc #(.DW(64), .AW(6)) u_rf (
        .wr_clk(mclk), .wr_rst_n(m_frst_n), .din(b_readdata), .wr_en(rf_wr), .full(rf_full), .wr_free(rf_free),
        .rd_clk(clk), .rd_rst_n(s_frst_n), .dout(rf_dout), .rd_en(rf_rd), .empty(rf_empty), .valid(rf_valid));
    // 0.5: the audio's words. Reset by the PLL lock only: aud_play asks only for what it has
    // room for (its own count), and takes back every word it is owed after any reset.
    fifo_dc #(.DW(64), .AW(8)) u_af (
        .wr_clk(mclk), .wr_rst_n(mrst_n), .din(b_readdata), .wr_en(af_wr), .full(), .wr_free(),
        .rd_clk(clk), .rd_rst_n(lrst_n), .dout(af_dout), .rd_en(af_rd), .empty(af_empty), .valid(af_valid));
    fifo_dc #(.DW(71), .AW(6)) u_sf (
        .wr_clk(clk), .wr_rst_n(lrst_n), .din({st_ix, st_word}), .wr_en(st_wr), .full(sf_full), .wr_free(sf_free),
        .rd_clk(mclk), .rd_rst_n(mrst_n), .dout(sf_dout), .rd_en(sf_rd), .empty(sf_empty), .valid(sf_valid));

    typedef enum logic [3:0] {
        E_CLR, E_CLR_DROP, E_IDLE, E_PCMD, E_PDATA, E_PEVAL, E_RCMD, E_RDATA, E_SFETCH, E_SLAND, E_SBEAT,
        E_ACMD, E_ADATA, E_GCMD, E_GDATA
    } est_t;
    est_t        es;
    logic [31:0] ww, rw;                   // the observed write index; bytes fetched (0.5: read_index is `pub`)
    logic [31:0] seen_nonce, p_wi, p_nonce;
    logic        booted;
    logic [2:0]  pbeat;                    // the poll's beat: 0 write index, 1 nonce, 2 pause, 3 settings,
                                           // 4-6 rumble, 7 geometry request (1.2)
    logic [31:0] p_set;
    logic [31:0] p_ctl;                    // 0.5: word 34 as read
    logic [15:0] ctl_m;                    // ... as accepted ([0] PAUSE, [15:8] ATTEN)
    logic [95:0] p_rum;                    // 0.13: words 36-38's low halves as read (pad n at [16n +: 16])
    logic [95:0] rum_m;                    // ... taken at the poll's end
    logic [63:0] p_geom;
    logic [7:0]  geom_last_m, geom_ack_m;
    logic [1:0]  geom_err_m;
    logic [127:0] geom_data_m;
    logic [137:0] geom_bundle_s;
    logic        ctl_err_m;
    logic [31:0] pub;                      // 0.5: the published (released) index
    logic        af_ack;                   // 0.5: the audio fetch's answer (a toggle)
    logic [7:0]  set_last;                 // the last request's sequence number handed on this session
    logic        sess_m;                   // the engine runs a session
    logic        rst_seen;                 // an OSD reset was seen: drop the session (latched until served)
    logic [3:0]  n, k;
    logic [16:0] ptimer;
    logic [3:0]  grp_pend;

    wire  [31:0] avail  = ww - rw;
    wire         caught = (avail == 32'd0);
    wire  [RING_AW:0] to_end = RING_WORDS - {1'b0, rw[RING_AW+2:3]};
    wire  [3:0]  rn_a   = (avail[31:3] >= 29'd8) ? 4'd8 : {1'b0, avail[5:3]};
    wire  [3:0]  rn     = (to_end < {{(RING_AW-3){1'b0}}, rn_a}) ? to_end[3:0] : rn_a;
    wire         poll_due = (ptimer >= POLL_SLOW_W) || (caught && ptimer >= POLL_FAST_W);
    wire  [31:0] d_rw   = p_wi - pub;       // 0.5: against the published (released) index
    wire  [31:0] d_ww   = p_wi - ww;
    wire         pause_m = sess_m && ctl_m[0];
    wire  [95:0] rum_out_m = sess_m ? rum_m : 96'd0;    // 0.13: no session, no rumble

    // ---- 0.5: the audio fetch's request (clk_sys -> clk_mem: a toggle, the fields stable
    // while it is outstanding) ----
    logic        af_req, afr_m1, afr_m2, afa_s1, afa_s2;
    logic [31:0] af_addr_q;  logic [3:0] af_n_q;
    assign af_busy = (af_req != afa_s2);
    always_ff @(posedge clk or negedge lrst_n)
        if (!lrst_n) begin af_req <= 1'b0; af_addr_q <= '0; af_n_q <= '0; afa_s1 <= 1'b0; afa_s2 <= 1'b0; end
        else begin
            afa_s1 <= af_ack; afa_s2 <= afa_s1;
            if (af_go && !af_busy) begin af_addr_q <= af_addr; af_n_q <= af_n; af_req <= ~af_req; end
        end
    always_ff @(posedge mclk) begin afr_m1 <= af_req; afr_m2 <= afr_m1; end
    wire         af_pend = (afr_m2 != af_ack);

    // ---- 0.5: the released index into clk_mem, word 34 into clk_sys ----
    logic [31:0] rel_m;  logic rel_tick;
    cdc_snap #(.W(32)) u_rel (
        .src_clk(clk), .src_rst_n(lrst_n), .src_data(rel_s),
        .dst_clk(mclk), .dst_rst_n(mrst_n), .dst_data(rel_m), .dst_tick(rel_tick));
    cdc_snap #(.W(10)) u_ctl (
        .src_clk(mclk), .src_rst_n(mrst_n), .src_data({pause_m, ctl_err_m, ctl_m[15:8]}),
        .dst_clk(clk), .dst_rst_n(lrst_n), .dst_data({ctl_pause, ctl_err, ctl_atten}), .dst_tick());
    // 0.13: the rumble into clk_sys, and its changes counted where they reach hps_io
    cdc_snap #(.W(96)) u_rum (
        .src_clk(mclk), .src_rst_n(mrst_n), .src_data(rum_out_m),
        .dst_clk(clk), .dst_rst_n(lrst_n), .dst_data(rumble), .dst_tick());
    cdc_snap #(.W(138)) u_geometry (
        .src_clk(mclk), .src_rst_n(mrst_n), .src_data({geom_err_m, geom_ack_m, geom_data_m}),
        .dst_clk(clk), .dst_rst_n(lrst_n), .dst_data(geom_bundle_s), .dst_tick());
    assign geom_data = geom_bundle_s[127:0];
    assign geom_ack_seq = geom_bundle_s[135:128];
    assign geom_error = geom_bundle_s[137:136];
    logic [95:0] rum_q;
    always_ff @(posedge clk or negedge lrst_n)
        if (!lrst_n) begin rum_q <= '0; rum_changes <= '0; end
        else begin
            rum_q <= rumble;
            if (rumble != rum_q) rum_changes <= rum_changes + 32'd1;
        end
    wire  [31:0] rel_d  = rel_m - start;     // inside the session's [start, fetched], never backwards
    wire         rel_ok = (rel_d <= (rw - start)) && (rel_d >= (pub - start));

    assign sf_rd = (es == E_SFETCH) && !sf_empty;
    assign rf_wr = (es == E_RDATA) && b_readdatavalid;
    assign af_wr = (es == E_ADATA) && b_readdatavalid;
    assign read_index = pub;
    assign eng_session = sess_m;
    assign eng_errf = (eng_err != 8'd0);

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            es <= E_CLR; ww <= '0; rw <= '0; seen_nonce <= '0; p_wi <= '0; p_nonce <= '0;
            booted <= 1'b0; pbeat <= 3'd0; p_rum <= '0; rum_m <= '0; p_set <= '0; set_last <= '0; set_word <= '0; set_tog <= 1'b0; n <= '0; k <= '0; rst_seen <= 1'b0; ptimer <= POLL_SLOW_W;
            p_geom <= '0; geom_last_m <= '0; geom_ack_m <= '0; geom_err_m <= '0; geom_data_m <= '0;
            p_ctl <= '0; ctl_m <= '0; ctl_err_m <= 1'b0; pub <= '0; af_ack <= 1'b0;
            grp_pend <= '0; sess_m <= 1'b0; new_sess <= 1'b0; start <= '0; clr_req <= 1'b0; m_frst_n <= 1'b0;
            eng_err <= '0; eng_bad_wi <= '0; eng_widx <= '0; ack_nonce <= '0; n_polls <= '0; n_bursts <= '0;
            b_address <= CTRL_WORD; b_burstcount <= 8'd1; b_read <= 1'b0; b_write <= 1'b0; b_writedata <= '0;
        end else begin
            if (ptimer != 17'h1FFFF) ptimer <= ptimer + 17'd1;
            if (gt_m3 != gt_m2) grp_pend <= grp_pend + 4'd1;
            if (!rst_m2) rst_seen <= 1'b1;
            if (rel_tick && es != E_CLR && es != E_CLR_DROP && rel_ok) pub <= rel_m;
            case (es)
                E_CLR: begin                                   // nothing outstanding: clear
                    m_frst_n <= 1'b0; clr_req <= 1'b1;
                    if (ack_m2) begin
                        rw <= start; ww <= start; pub <= start; eng_err <= '0; sess_m <= new_sess; set_last <= '0;
                        ack_nonce <= new_sess ? seen_nonce : 32'd0;
                        m_frst_n <= 1'b1; clr_req <= 1'b0;
                        es <= E_CLR_DROP;
                    end
                end
                E_CLR_DROP: if (!ack_m2) es <= E_IDLE;
                E_IDLE: begin
                    if (rst_seen) begin                        // an OSD reset: drop the session (the parser
                        rst_seen <= 1'b0;                      // was reset; it answers once released)
                        new_sess <= 1'b0; start <= '0; es <= E_CLR;
                    end else if (grp_pend != 4'd0 && !(gt_m3 != gt_m2)) begin
                        grp_pend <= grp_pend - 4'd1; k <= '0; es <= E_SFETCH;
                    end else if (poll_due) begin
                        // the program's words 32-39 (1.2 adds geometry word 39)
                        b_address <= CTRL_WORD + {21'd0, RI_W_WRITE_INDEX}; b_burstcount <= RI_POLL_WORDS; b_read <= 1'b1;
                        ptimer <= '0; pbeat <= 3'd0; n_polls <= n_polls + 32'd1;
                        es <= E_PCMD;
                    end else if (af_pend) begin                // 0.5: the audio's fetch (it has room)
                        b_address <= RING_WORD + {{(29-RING_AW){1'b0}}, af_addr_q[RING_AW+2:3]};
                        b_burstcount <= {4'd0, af_n_q}; b_read <= 1'b1;
                        n <= af_n_q; k <= '0;
                        es <= E_ACMD;
                    end else if (sess_m && eng_err == 8'd0 && !caught && !pause_m && rf_free >= 7'd8) begin
                        b_address <= RING_WORD + {{(29-RING_AW){1'b0}}, rw[RING_AW+2:3]};
                        b_burstcount <= {4'd0, rn}; b_read <= 1'b1;
                        n <= rn; k <= '0; n_bursts <= n_bursts + 32'd1;
                        es <= E_RCMD;
                    end
                end
                E_PCMD: if (!b_waitrequest) begin b_read <= 1'b0; es <= E_PDATA; end
                E_PDATA: if (b_readdatavalid) begin
                    pbeat <= pbeat + 3'd1;
                    case (pbeat)
                        3'd0: p_wi <= b_readdata[31:0];
                        3'd1: p_nonce <= b_readdata[31:0];
                        3'd2: p_ctl <= b_readdata[31:0];          // 0.5: the pause and attenuation
                        3'd3: p_set <= b_readdata[31:0];          // 0.4: the settings request
                        3'd4: p_rum[31:0]  <= b_readdata[31:0];   // 0.13: pads 0-1 (the high half ignored)
                        3'd5: p_rum[63:32] <= b_readdata[31:0];   // pads 2-3
                        3'd6: p_rum[95:64] <= b_readdata[31:0];   // pads 4-5
                        default: begin p_geom <= b_readdata; es <= E_PEVAL; end
                    endcase
                end
                E_PEVAL: begin
                    eng_widx <= p_wi;
                    rum_m <= p_rum;                                       // 0.13: whole, at the poll's end
                    es <= E_IDLE;
                    // 0.5: word 34, range-checked: a reserved bit refuses the word whole
                    if ((p_ctl & RI_CTL_RESERVED) != 32'd0) ctl_err_m <= 1'b1;
                    else begin ctl_m <= p_ctl[15:0]; ctl_err_m <= 1'b0; end
                    if (!booted) begin
                        seen_nonce <= p_nonce; booted <= 1'b1;           // an earlier load's: ignored
                    end else if (p_nonce != seen_nonce) begin
                        seen_nonce <= p_nonce; new_sess <= 1'b1; start <= {p_wi[31:4], 4'd0};
                        geom_data_m <= 128'd0;
                        geom_ack_m <= p_geom[63:56]; geom_last_m <= p_geom[63:56]; geom_err_m <= 2'd0;
                        es <= E_CLR;
                    end else if (sess_m && eng_err == 8'd0) begin
                        // the settings request: a new, nonzero sequence number during the session
                        if (p_set[31:24] != 8'd0 && p_set[31:24] != set_last) begin
                            set_last <= p_set[31:24]; set_word <= p_set; set_tog <= ~set_tog;
                        end
                        if (p_wi[3:0] != 4'd0) begin
                            eng_err <= RE_WIDX_ALIGN; eng_bad_wi <= p_wi;
                        end else if (d_rw > RING_BYTES || d_ww > RING_BYTES) begin
                            eng_err <= RE_WIDX_RANGE; eng_bad_wi <= p_wi;
                        end else ww <= p_wi;
                        if (p_geom[63:56] != 8'd0 && p_geom[63:56] != geom_last_m) begin
                            geom_last_m <= p_geom[63:56];
                            b_address <= CTRL_WORD + {21'd0, RI_W_GEOMETRY_CLIP}; b_burstcount <= 8'd1; b_read <= 1'b1;
                            es <= E_GCMD;
                        end
                    end
                end
                E_GCMD: if (!b_waitrequest) begin b_read <= 1'b0; es <= E_GDATA; end
                E_GDATA: if (b_readdatavalid) begin
                    if ((p_geom[55:52] != 4'd0) || (b_readdata[63:48] != 16'd0)) begin
                        geom_ack_m <= p_geom[63:56]; geom_err_m <= 2'd2;
                    end else if (p_geom[51:39] == 13'd0 && p_geom[38:26] == 13'd0 &&
                                 p_geom[25:13] == 13'd0 && p_geom[12:0] == 13'd0 && b_readdata[47:0] == 48'd0) begin
                        geom_data_m <= 128'd0; geom_ack_m <= p_geom[63:56]; geom_err_m <= 2'd0;
                    end else if (p_geom[25:13] == 13'd0 || p_geom[12:0] == 13'd0 ||
                                 p_geom[39] || p_geom[26] || p_geom[13] || p_geom[0] ||
                                 b_readdata[11:0] > 12'd720 || b_readdata[23:12] > 12'd576 ||
                                 b_readdata[35:24] == 12'd0 || b_readdata[35:24] > 12'd720 ||
                                 b_readdata[47:36] == 12'd0 || b_readdata[47:36] > 12'd576 ||
                                 {1'b0, b_readdata[11:0]} + {1'b0, b_readdata[35:24]} > 13'd720 ||
                                 {1'b0, b_readdata[23:12]} + {1'b0, b_readdata[47:36]} > 13'd576 ||
                                 b_readdata[0] || b_readdata[12] || b_readdata[24] || b_readdata[36]) begin
                        geom_ack_m <= p_geom[63:56]; geom_err_m <= 2'd1;
                    end else begin
                        geom_data_m <= {b_readdata, p_geom}; geom_ack_m <= p_geom[63:56]; geom_err_m <= 2'd0;
                    end
                    es <= E_IDLE;
                end
                E_RCMD: if (!b_waitrequest) begin b_read <= 1'b0; es <= E_RDATA; end
                E_RDATA: if (b_readdatavalid) begin
                    k <= k + 4'd1;
                    if (k + 4'd1 == n) begin
                        rw <= rw + {25'd0, n, 3'b000};
                        es <= E_IDLE;
                    end
                end
                E_ACMD: if (!b_waitrequest) begin b_read <= 1'b0; es <= E_ADATA; end
                E_ADATA: if (b_readdatavalid) begin      // into u_af (af_wr)
                    k <= k + 4'd1;
                    if (k + 4'd1 == n) begin af_ack <= ~af_ack; es <= E_IDLE; end
                end
                // the status: eight words, the first one's index giving the address
                E_SFETCH: if (!sf_empty) es <= E_SLAND;
                E_SLAND: if (sf_valid) begin
                    if (k == 4'd0) begin
                        b_address <= CTRL_WORD + {22'd0, sf_dout[70:64]}; b_burstcount <= 8'd8;
                    end
                    b_writedata <= sf_dout[63:0]; b_write <= 1'b1; es <= E_SBEAT;
                end
                E_SBEAT: if (!b_waitrequest) begin
                    b_write <= 1'b0;
                    k <= k + 4'd1;
                    if (k + 4'd1 == 4'd8) es <= E_IDLE; else es <= E_SFETCH;
                end
                default: es <= E_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
