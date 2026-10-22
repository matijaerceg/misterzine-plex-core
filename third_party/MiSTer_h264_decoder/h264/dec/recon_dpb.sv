// h264/dec/recon_dpb.sv -- the decoded picture buffer's control: frame-store state,
// picture order count (8.2.1), reference marking (8.2.5), store allocation
// (docs/h264_recon.md S2.2). The list construction lives in recon_lists.sv, which
// reads the store state this module exports.
//
// Twenty frame stores (NSTORE, h264_pkg; registers: recon_lists and recon_slice_tab read every store).
// Every per-store computation here -- FrameNumWrap, the sliding window's victim, each
// MMCO's matches and updates -- SCANS the stores, one per cycle: each operation touches
// a store from that store's own pre-operation state only, so a scan is exact, and the
// parallel version (64 32-bit comparators, 32 adders) cost ~5,000 LUTs
// (docs/h264_recon.md S6). Per store and per field (parity 0 top, 1 bottom):
// the marking (unused / short / long), decoded, POC; per store: frame_num and its
// FrameNumWrap (8.2.4.1, recomputed per slice against the current frame_num), the
// LongTermFrameIdx, how it was coded (a frame, or fields and which came first),
// whether its picture is a reference picture. A store is FREE when neither field is
// marked "used for reference", it is not the current picture and the display does not
// hold it (disp_hold).
//
// Sequence per slice (slice_ready from recon_hdr):
//   * a new picture (first_mb 0, or none open): wait for the macroblock pipeline to be
//     idle (pipe_idle: the previous picture is complete in DDR3), MARK the previous
//     picture (8.2.5.1: IDR / sliding window / the MMCO list copied at its slices),
//     then open the new one: frame_num gap check, the store (a second field pairs with
//     its first field's store, 7.4.1.2.4; else the lowest free), the POC (8.2.1.1-3;
//     type 1 reads recon_hdr's prefix-sum table), then pic_start;
//   * every slice: FrameNumWrap for every store, then hand over to recon_lists
//     (lists_go / lists_done) and pulse slice_go.
// The MMCO list is copied out of recon_hdr at each slice (the next slice's header
// overwrites recon_hdr's RAM before this picture is marked).
//
// P5d, THE OUTPUT PROCESS (C.4.4 / C.4.5; docs/display.md S6; the model is
// tools/h264_recon_ref.py output_step): per store, waiting ("needed for output"), emitted
// (once per allocation) and pend_emit (output before its pair completed). After a
// picture's marking and BEFORE an MMCO 5's POC rewrite: C.4.4 (an IDR drops the waiting
// stores when no_output_of_prior_pics_flag is set -- as coded, never inferred -- else it,
// or an MMCO 5, bumps them all), then C.4.5 (a reference picture: bump while the DPB is
// full, then store; a non-reference one: bump while full and something waiting has a POC
// at or below its own, else output it directly). A bump SCANS the stores through the
// table port for the smallest POC among the waiting ones and EMITS it (emit_*: the store
// goes to the display's queue, recon_top forms the record). The STORE is the output
// unit: emitted whole, once, never before its pair completes (a directly output first
// field sets pend_emit and goes out with its second field, or unpaired when the next
// picture does not pair with it). The DPB size: max_dec_frame_buffering (Max(1, it)) when
// the VUI has it, else MaxDpbFrames from Table A-1 (level_idc 11 read as 1.1), capped at
// 16 -- computed serially when a picture opens. End of stream (eos, the front end's
// K_EOS_WORD): the last picture is closed and everything waiting is emitted (eos_done).
// EARLY OUTPUT (roadmap P3d, E.2.1): when the SPS limits reordering -- max_num_reorder_frames
// in its VUI, or POC type 2, whose output order IS its decoding order (8.2.1.3), read as 0 --
// after C.4.5 has placed the current picture, while more COMPLETE stores wait than that
// limit, the smallest POC is emitted (D_OUT_NRF: the same scan, the current store a
// candidate once complete). No picture follows more than max_num_reorder_frames others in
// output order, so this changes WHEN a store leaves, never the order; a stream breaking
// its own limit would output a POC below one already output: counted (nrf_late). A stock
// Sunshine stream (max_num_reorder_frames 0, max_dec_frame_buffering 2) was held two
// pictures by the bumping alone.
// DEADLOCK: a picture's output step runs before the NEXT picture opens its store, so
// references + waiting <= the DPB size (<= 16) when a store is chosen; with 20 stores at
// least one is free unless the DISPLAY holds some -- then D_OPEN waits (stall_cycles
// counts it) for a release, and a wait longer than STALL_LIMIT cycles counts
// err_no_store (a display that never releases is visible, never a silent hang).
//
// Errors (pulses, counted and shown by recon_top): a frame_num gap (8.2.5.2 is not
// implemented: the census never allows gaps; the picture decodes against what the
// lists hold), no free store (never on a conforming stream: 16 > MaxDpbFrames + 1),
// a sliding window with nothing short-term to drop, an MMCO naming no picture.

`default_nettype none

module recon_dpb
    import h264_pkg::*;
#(
    parameter int STALL_LIMIT = 24'd13_000_000     // ~135 ms = ~4 frame periods at 30 at 96.43 MHz (14 M at 103.85, 2026-09-30..10-01; 11 M at 81)
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,             // a new title: every store free, POC state reset

    // the slice from recon_hdr (held)
    input  wire         slice_ready,
    input  wire  [SPS_W-1:0] sps,
    input  wire  [PPS_W-1:0] pps,
    input  wire  [13:0] sh_first_mb,
    input  wire  [1:0]  sh_slice_type,
    input  wire  [1:0]  sh_nal_ref_idc,
    input  wire         sh_idr,
    input  wire  [15:0] sh_frame_num,
    input  wire         sh_field_pic,
    input  wire         sh_bottom_field,
    input  wire  [15:0] sh_poc_lsb,
    input  wire  [31:0] sh_delta_poc_bottom,
    input  wire  [31:0] sh_delta_poc0,
    input  wire  [31:0] sh_delta_poc1,
    input  wire         sh_long_term_reference,
    input  wire         sh_adaptive_marking,
    input  wire         sh_mmco5,
    input  wire         sh_no_output_of_prior_pics,
    input  wire  [6:0]  sh_n_mmco,
    output logic [5:0]  mmco_addr,         // recon_hdr's MMCO table
    input  wire  [66:0] mmco_data,
    output logic [7:0]  poc1_addr,         // recon_hdr's prefix sums
    input  wire  [31:0] poc1_data,
    input  wire  [31:0] poc1_total,

    // the macroblock pipeline and the display
    input  wire         pipe_idle,         // no macroblock in flight, the last one written
    input  wire  [NSTORE-1:0] disp_hold,         // stores the display is reading (never freed)
    input  wire         disp_frz,          // (Phase 4, from UMD P6b3i) the display is frozen -- the
                                           // pause: its holds are legitimate, not the alarm's case

    // the picture and slice handshakes
    output logic        pic_start,         // one pulse per new picture (cur_* valid)
    output logic        pic_new,           // level: the slice being started opens a picture
    output logic [4:0]  cur_store,
    output logic [1:0]  cur_struct,        // 0 F, 1 T, 2 B
    output logic        cur_isref,
    output logic signed [31:0] cur_poc,    // PicOrderCnt(CurrPic)
    output logic        lists_go,          // recon_lists: build the lists now
    input  wire         lists_done,
    output logic        slice_go,          // one pulse per slice: everything is ready
    output logic        busy,

    // the store state, for recon_lists / the writeback / the display (packed per store)
    output logic [NSTORE*2-1:0]  st_ref_t,     // marking of the top field, 2 bits per store
    output logic [NSTORE*2-1:0]  st_ref_b,
    output logic [NSTORE-1:0] st_dec_t,
    output logic [NSTORE-1:0] st_dec_b,
    // the store table's wide fields live in RAM (below): one registered read port,
    // addressed by recon_lists while this unit waits for the lists, by recon_slice_tab
    // while this unit is idle; data the cycle after the address
    input  wire  [4:0]  tab_ra_lists,
    input  wire  [4:0]  tab_ra_slice,
    output logic signed [31:0] tab_q_poc_t,
    output logic signed [31:0] tab_q_poc_b,
    output logic signed [31:0] tab_q_fnw,      // FrameNumWrap
    output logic [NSTORE*5-1:0]  st_lt,        // LongTermFrameIdx
    output logic [NSTORE-1:0] st_frame,     // coded as a frame
    output logic [NSTORE-1:0] st_busy,

    // the output process (P5d): one pulse per store emitted to the display's queue
    input  wire         eos,               // end of stream (pulse): close, then emit everything
    output logic        eos_done,          // pulse: the end-of-stream flush is complete
    output logic        emit_valid,
    output logic [4:0]  emit_store,
    output logic        emit_unpaired,     // a single field (no partner came)
    output logic        emit_first_bot,    // its first-DECODED field was the bottom one
    output logic        emit_frame,        // coded as a frame
    output logic        emit_dec_t,        // which fields hold a picture
    output logic        emit_dec_b,
    output logic signed [31:0] emit_poc_t,
    output logic signed [31:0] emit_poc_b,
    output logic [31:0] out_dropped,       // stores dropped by no_output_of_prior_pics_flag
    output logic [31:0] out_direct,        // non-reference pictures output without storage
    output logic [31:0] out_over,          // the DPB full of references alone (non-conforming)
    output logic [31:0] nrf_late,          // an early output below the last POC output (a stream past its own max_num_reorder_frames)
    output logic [31:0] stall_cycles,      // cycles D_OPEN waited on the display's holds
    output logic [4:0]  dpb_fill,          // references + waiting (the HUD)

    // errors (pulses)
    output logic        err_gap,
    output logic        err_no_store,
    output logic        err_window,
    output logic        err_mmco
);

    localparam [1:0] UNUSED = 2'd0, SHORT = 2'd1, LONG = 2'd2;
    localparam [1:0] S_F = 2'd0, S_T = 2'd1, S_B = 2'd2;

    sps_t s;
    pps_t p;
    assign s = sps;
    assign p = pps;

    // ---- store state ---------------------------------------------------------------
    logic        pic_open;
    logic [15:0] sh_poc_lsb_r;             // the completed picture's pic_order_cnt_lsb
    logic [1:0]  ref_t [0:NSTORE-1], ref_b [0:NSTORE-1];
    logic        dec_t [0:NSTORE-1], dec_b [0:NSTORE-1];
    // POC per field, frame_num, FrameNumWrap per store: RAM, read one store at a time
    // (the scans read a store the cycle before they process it). 1,900 registers and
    // three 20:1 x 32-bit muxes in each reader as registers (docs/h264_recon.md S6.1).
    logic signed [31:0] poc_t_m [0:31];
    logic signed [31:0] poc_b_m [0:31];
    logic signed [31:0] fnw_m [0:31];
    logic [15:0] fn_m [0:31];
    logic        pt_we, pb_we, fw_we, fn_we;
    logic [4:0]  pt_wa, pb_wa, fw_wa, fn_wa;
    logic signed [31:0] pt_wd, pb_wd, fw_wd;
    logic [15:0] fn_wd;
    logic [4:0]  tab_ra;
    logic signed [31:0] q_fnw;
    logic [15:0] q_fn;
    always_ff @(posedge clk) begin
        if (pt_we) poc_t_m[pt_wa] <= pt_wd;
        if (pb_we) poc_b_m[pb_wa] <= pb_wd;
        if (fw_we) fnw_m[fw_wa] <= fw_wd;
        if (fn_we) fn_m[fn_wa] <= fn_wd;
        tab_q_poc_t <= poc_t_m[tab_ra];
        tab_q_poc_b <= poc_b_m[tab_ra];
        q_fnw <= fnw_m[tab_ra];
        q_fn <= fn_m[tab_ra];
    end
    assign tab_q_fnw = q_fnw;
    logic [4:0]  lt [0:NSTORE-1];
    logic        lt_v [0:NSTORE-1];
    logic        frame_coded [0:NSTORE-1];
    logic        first_bot [0:NSTORE-1];         // the first decoded field was the bottom one
    logic        isref [0:NSTORE-1];
    logic        mmco5_r [0:NSTORE-1];
    logic        alloc [0:NSTORE-1];             // allocated to a picture since the last free
    logic [NSTORE-1:0] waiting, emitted, pend_emit;  // the output process (P5d)

    always_comb begin
        for (int i = 0; i < NSTORE; i++) begin
            st_ref_t[2*i +: 2] = ref_t[i];
            st_ref_b[2*i +: 2] = ref_b[i];
            st_dec_t[i] = dec_t[i];
            st_dec_b[i] = dec_b[i];
            st_lt[5*i +: 5] = lt[i];
            st_frame[i] = frame_coded[i];
            st_busy[i] = (ref_t[i] != UNUSED) || (ref_b[i] != UNUSED) || disp_hold[i] || waiting[i] || pend_emit[i] ||
                         (pic_open && cur_store == i[4:0]);
        end
    end

    // ---- the current picture and the POC state --------------------------------------
    logic        cur_idr, cur_field, cur_bottom, cur_mmco5, cur_adaptive, cur_ltref;
    logic [15:0] cur_fn;
    logic signed [31:0] cur_poc_top, cur_poc_bot;
    logic signed [31:0] cur_poc_msb, cur_fno;
    logic [6:0]  cur_n_mmco;
    logic signed [31:0] prev_poc_msb, prev_poc_lsb, prev_fno, prev_ref_top_poc;
    logic [15:0] prev_fn, prev_ref_fn;
    logic        prev_ref_mmco5, prev_ref_bottom, prev_mmco5;
    logic        prev_was_field, prev_bottom, prev_isref, prev_mmco5_pic;
    logic [15:0] prev_fn_pic;
    logic [4:0]  prev_store;
    logic [4:0]  max_lt;                   // MaxLongTermFrameIdx (0..31); max_lt_v = "no long-term indices" when 0
    logic        max_lt_v;

    // the MMCO copy (this picture's)
    logic [66:0] mm_ram [0:63];
    logic [66:0] mm_q;
    logic [5:0]  mm_i;
    logic signed [32:0] p0_pm, p0_pl;      // D_POC0 .. D_POC0C: prevPicOrderCntMsb / Lsb, then the MSB
    logic signed [32:0] p0_up, p0_dn;      // D_POC0B: the two wrapped candidates, D_POC0B2 picks
    logic               p0_cu, p0_cd;

    // ---- helpers -----------------------------------------------------------------------
    wire signed [31:0] max_fn = 32'sd1 <<< (s.log2_max_frame_num_minus4 + 4);
    wire signed [31:0] max_lsb = 32'sd1 <<< (s.log2_max_poc_lsb_minus4 + 4);
    wire        new_pic = (sh_first_mb == 14'd0) || !pic_open;
    wire        cur_bot_now = sh_field_pic && sh_bottom_field;
    wire signed [31:0] cur_pic_num = cur_field ? (32'sd2 * $signed({16'd0, cur_fn}) + 32'sd1) : $signed({16'd0, cur_fn});

    // ---- the scanned store ------------------------------------------------------------
    // a scan reads store di and processes store dx = di - 1 (its data arrived): steps
    // 1..NSTORE process, NSTORE + 1 resolves (the scans that have a resolve step)
    localparam logic [4:0] SC_LAST = NSTORE, SC_RES = NSTORE + 1;
    logic [4:0]  di;
    wire  [4:0]  dx = di - 5'd1;
    // the store's marking read a cycle ahead, like the table RAM (store di now, processed as
    // dx = di - 1 next cycle): the 20:1 read in front of the write decode missed clk_dec
    logic [1:0]  y_rt, y_rb;
    logic [4:0]  y_lt;
    logic        y_ltv;
    always_ff @(posedge clk) begin
        if (di < NSTORE) begin y_rt <= ref_t[di]; y_rb <= ref_b[di]; y_lt <= lt[di]; y_ltv <= lt_v[di]; end
        else begin y_rt <= UNUSED; y_rb <= UNUSED; y_lt <= 5'd0; y_ltv <= 1'b0; end   // the resolve steps
    end
    wire signed [31:0] y_fnw = q_fnw;
    wire         y_notcur = (dx != cur_store);
    // PicNum / LongTermPicNum of its fields for the current picture (8.2.4.1): a frame's
    // are FrameNumWrap / LongTermFrameIdx; a field's 2x + 1 for the current parity, 2x
    // for the opposite one
    wire signed [31:0] y_ltn_t = cur_field ? $signed({26'd0, y_lt, !cur_bottom}) : $signed({27'd0, y_lt});
    wire signed [31:0] y_ltn_b = cur_field ? $signed({26'd0, y_lt,  cur_bottom}) : $signed({27'd0, y_lt});
    // the MMCO matches (picNumX = CurrPicNum - (difference_of_pic_nums_minus1 + 1) for
    // ops 1 and 3, long_term_pic_num for op 2): top (or the frame), bottom
    // (registered: mm_q is set in D_MMCO_RD and the scan acts from di = 1. A field's PicNum
    // 2 FrameNumWrap + p equals a target t exactly when FrameNumWrap == t >>> 1 and p == t[0]:
    // the compare runs on the table's output with no adder in front of it -- the RAM, the
    // doubling and the 32-bit compare in one cycle missed clk_dec)
    logic signed [31:0] m_short_target, m_long_target;
    always_ff @(posedge clk) begin
        m_short_target <= cur_pic_num - $signed(mm_q[63:32]) - 32'sd1;
        m_long_target  <= $signed(mm_q[63:32]);
    end
    wire signed [31:0] m_short_half = m_short_target >>> 1;
    wire         fnw_eq_half = (y_fnw == m_short_half);
    logic        y_ms_t, y_ms_b, y_ml_t, y_ml_b;
    always_comb begin
        if (cur_field) begin
            y_ms_t = y_notcur && (y_rt == SHORT) && fnw_eq_half && (m_short_target[0] == !cur_bottom);
            y_ms_b = y_notcur && (y_rb == SHORT) && fnw_eq_half && (m_short_target[0] ==  cur_bottom);
            y_ml_t = y_notcur && (y_rt == LONG) && y_ltv && (y_ltn_t == m_long_target);
            y_ml_b = y_notcur && (y_rb == LONG) && y_ltv && (y_ltn_b == m_long_target);
        end else begin
            y_ms_t = y_notcur && (y_rt == SHORT) && (y_rb == SHORT) && (y_fnw == m_short_target);
            y_ms_b = 1'b0;
            y_ml_t = y_notcur && (y_rt == LONG) && (y_rb == LONG) && y_ltv && ($signed({27'd0, y_lt}) == m_long_target);
            y_ml_b = 1'b0;
        end
    end
    // MMCO 3 / 6 free their LongTermFrameIdx elsewhere first: every OTHER store holding
    // that index loses its long-term fields (8.2.5.4.3 / 8.2.5.4.6)
    wire         y_lt_hit = y_ltv && (y_lt == mm_q[4:0]);
    wire         y_op3 = y_ms_t || y_ms_b;
    // FrameNumWrap of the scanned store against a frame_num
    logic [15:0] fnw_ref;                  // the frame_num the scan wraps against
    wire  [15:0] y_fn = q_fn;
    wire signed [31:0] y_fnw_new = ($signed({16'd0, y_fn}) > $signed({16'd0, fnw_ref})) ? $signed({16'd0, y_fn}) - max_fn
                                                                                        : $signed({16'd0, y_fn});
    // the sliding window's accumulators (the store with any short-term field and the
    // smallest FrameNumWrap; the short / long counts)
    logic [4:0]  win_victim;
    logic        win_found;
    logic signed [31:0] win_best;
    // the window scan's candidate stage (P5b timing: dx != cur_store and the table's
    // FrameNumWrap compared with win_best in one cycle in front of its enable, 9.6 ns at
    // 100 C): store dx's candidacy and FrameNumWrap registered, compared the next cycle
    logic        wz_v;
    logic [4:0]  wz_dx;
    logic signed [31:0] wz_fnw;
    logic [4:0]  num_short, num_long;
    logic        mm_any;                   // the scanned MMCO matched something
    // the lowest free store
    logic [4:0] free_store;
    logic       free_found;
    always_comb begin
        free_found = 1'b0; free_store = 4'd0;
        for (int i = NSTORE - 1; i >= 0; i--) if (!st_busy[i]) begin free_found = 1'b1; free_store = i[4:0]; end
    end
    wire [4:0] max_ref_frames = (s.num_ref_frames == 5'd0) ? 5'd1 : s.num_ref_frames;

    // ---- the FSM -----------------------------------------------------------------------
    typedef enum logic [5:0] {
        D_IDLE, D_WAIT_IDLE, D_MARK, D_MARK_IDR, D_MARK_WIN, D_MARK_WIN_SCAN, D_MMCO_RD, D_MMCO_EXEC, D_MARK_CUR,
        D_POST_MARK, D_OPEN, D_OPEN2, D_POC0, D_OUT_C44, D_OUT_FILL, D_OUT_FILL2, D_OUT_C45, D_OUT_SCAN, D_OUT_PRE, D_OUT_ACT, D_OUT_NRF0, D_OUT_NRF1, D_OUT_NRF, D_OUT_END, D_EOS, D_POC1_RD, D_POC1_RD2, D_POC1_DIV, D_POC1_MUL, D_POC1_CALC, D_POC2, D_POC2B, D_POC1_C2, D_POC1_C3, D_POC0B, D_POC0B2, D_POC0C, D_POC_BOT, D_POC_DONE,
        D_FNW, D_FNW_SCAN, D_COPY_MMCO, D_COPY_MMCO2, D_LISTS, D_LISTS_WAIT, D_POC1_RD3
    } dstate_t;
    dstate_t ds;
    // the MMCO scan's z stage (P5b timing): store dx's decisions registered, applied the
    // next cycle -- the FrameNumWrap table's clock-to-out, the 32-bit compare and the
    // marking enables of the matched store in one cycle were 9.9 ns at -40 C. Each store is
    // decided once and the next operation's scan starts after this one's resolve, so the
    // delay changes no result.
    logic        z_v, z_ms_t, z_ms_b, z_ml_t, z_ml_b, z_lt_hit, z_notcur, z_op4;
    logic [1:0]  z_rt, z_rb;
    logic [4:0]  z_dx;
    wire         z_op3 = z_ms_t || z_ms_b;
    always_ff @(posedge clk) begin
        z_v <= (ds == D_MMCO_EXEC) && (di != 5'd0) && (di <= SC_LAST);
        z_ms_t <= y_ms_t; z_ms_b <= y_ms_b; z_ml_t <= y_ml_t; z_ml_b <= y_ml_b;
        z_lt_hit <= y_lt_hit; z_notcur <= y_notcur; z_rt <= y_rt; z_rb <= y_rb; z_dx <= dx;
        z_op4 <= y_ltv && (mm_q[63:32] == 32'd0 || {27'd0, y_lt} > mm_q[63:32] - 32'd1);
    end
    // D_MARK wraps against the completed picture's frame_num, D_FNW against the slice's
    always_comb fnw_ref = (ds == D_MARK) ? cur_fn : sh_frame_num;
    // the table's read port: the lists while they run, the slice tables while this unit
    // is idle, the scan index otherwise
    always_comb tab_ra = (ds == D_LISTS_WAIT) ? tab_ra_lists : (ds == D_IDLE) ? tab_ra_slice : di;
    logic        op_pairing, op_gap, op_free;   // D_OPEN's decision, used by D_OPEN2
    logic [4:0]  op_st;
    logic        marked_long;              // MMCO 6 marked the current picture
    logic signed [31:0] tmp_a, tmp_b;
    logic [7:0]  abs_fn_i;                 // POC type 1 helpers
    logic signed [31:0] abs_fn, expected, cyc_cnt;
    logic        fn_wrap;                  // prev_fn > frame_num (8.2.1.2 / 8.2.1.3), registered at the opening
    logic [7:0]  in_cyc;
    logic signed [31:0] div_num, div_rem, poc1_prod;
    logic [5:0]  div_i;
    logic [2:0]  mm_op;
    logic [31:0] mm_a, mm_b;

    // ---- the output process (P5d) --------------------------------------------------------
    localparam [2:0] OM_FLUSH = 3'd0, OM_REF = 3'd1, OM_NONREF = 3'd2, OM_EOS = 3'd3, OM_NRF = 3'd4;
    logic [2:0]  om;                       // what the scan is for
    logic        eos_pend, eos_mode;
    logic        cur_no_output;
    logic [4:0]  cur_dpb_sz;               // the closing picture's DPB size
    logic [4:0]  cur_nrf;                  // its max_num_reorder_frames (E.2.1), when cur_nrf_on
    logic        cur_nrf_on;
    logic signed [31:0] last_out_poc;      // the last POC emitted since the last IDR / MMCO 5 (nrf_late)
    logic        last_out_v;
    // the dropped count (C.4.4) is added a cycle after it is counted: the count over the
    // stores (against cur_store) and the 32-bit add in one cycle missed 101.4 MHz (P6 fit)
    logic [5:0]  drop_n;
    logic        drop_go;
    // C.4.4's dropped-store count is a population count over waiting, excluding
    // the current store. Keep the reduction combinational so drop_n is still
    // captured in D_OUT_C44 and added on the following cycle, but balance the
    // adder depth instead of building a serial chain of NSTORE increments.
    localparam int DROP_LEVELS = (NSTORE > 1) ? $clog2(NSTORE) : 0;
    localparam int DROP_LEAVES = 1 << DROP_LEVELS;
    logic [NSTORE-1:0] drop_leaf;
    wire [5:0] drop_tree [0:DROP_LEVELS][0:DROP_LEAVES-1];
    always_comb begin
        drop_leaf = '0;
        for (int i = 0; i < NSTORE; i++)
            if (waiting[i] && i[4:0] != cur_store) drop_leaf[i] = 1'b1;
    end
    genvar drop_i, drop_level, drop_node;
    generate
        for (drop_i = 0; drop_i < DROP_LEAVES; drop_i++) begin : g_drop_leaf
            if (drop_i < NSTORE) begin : g_store
                assign drop_tree[0][drop_i] = {5'd0, drop_leaf[drop_i]};
            end else begin : g_pad
                assign drop_tree[0][drop_i] = 6'd0;
            end
        end
        for (drop_level = 0; drop_level < DROP_LEVELS; drop_level++) begin : g_drop_level
            for (drop_node = 0; drop_node < (DROP_LEAVES >> (drop_level + 1)); drop_node++) begin : g_node
                assign drop_tree[drop_level+1][drop_node] = drop_tree[drop_level][drop_node*2] + drop_tree[drop_level][drop_node*2+1];
            end
        end
    endgenerate
    wire [5:0] drop_count = drop_tree[DROP_LEVELS][0];
    logic        best_found;
    logic        act_bump, act_late;       // D_OUT_PRE's registered decisions for D_OUT_ACT
    logic [4:0]  best_store;
    logic signed [31:0] best_poc, best_pt, best_pb;
    logic [23:0] stall_ctr;
    // the current store is complete (a frame, or its other field decoded before)
    wire         cur_complete = (cur_struct == S_F) || ((cur_struct == S_T) ? dec_b[cur_store] : dec_t[cur_store]);
    // references + waiting over every store but the current one (C.4.5 "fullness"),
    // two register stages (P5b: the per-store conditions, then the count -- in one cycle with
    // cur_complete's 20:1 read in front it was 10.6 ns): D_OUT_FILL / D_OUT_FILL2 give it
    // two cycles after an emission
    logic [NSTORE-1:0] fill_c, nw_c;
    always_ff @(posedge clk) begin
        for (int i = 0; i < NSTORE; i++) begin
            fill_c[i] <= ((ref_t[i] != UNUSED) || (ref_b[i] != UNUSED) || waiting[i]) && !(pic_open && cur_store == i[4:0]);
            nw_c[i]   <= waiting[i] && (!(pic_open && cur_store == i[4:0]) || cur_complete);
        end
    end
    logic [4:0]  fill_q;
    always_ff @(posedge clk) begin
        logic [4:0] n;
        n = 5'd0;
        for (int i = 0; i < NSTORE; i++) if (fill_c[i]) n = n + 5'd1;
        fill_q <= n;
    end
    assign dpb_fill = fill_q;
    // stores waiting for output that may leave now: every waiting store but the current, and
    // the current once complete (EARLY OUTPUT, above); two stages like fill_q
    logic [4:0]  nw_q;
    always_ff @(posedge clk) begin
        logic [4:0] n;
        n = 5'd0;
        for (int i = 0; i < NSTORE; i++) if (nw_c[i]) n = n + 5'd1;
        nw_q <= n;
    end
    // the scanned store's candidacy and POC (the smaller of its decoded fields')
    // (the current store is not in the DPB yet; at the end of stream the last picture is
    // closed -- pic_open cleared in D_POST_MARK -- so it is a candidate like any other)
    // (EARLY OUTPUT: the current store too, once complete -- its closing field counted as
    // decoded, which D_POST_MARK records only after this process)
    wire         sc_cur  = pic_open && dx == cur_store;
    wire         sc_dt   = dec_t[dx] || (sc_cur && cur_struct != S_B);
    wire         sc_db   = dec_b[dx] || (sc_cur && cur_struct != S_T);
    wire         sc_cand = waiting[dx] && (!sc_cur || (om == OM_NRF && cur_complete));
    wire signed [31:0] sc_poc = (sc_dt && sc_db) ? ((tab_q_poc_t < tab_q_poc_b) ? tab_q_poc_t : tab_q_poc_b)
                              : sc_dt ? tab_q_poc_t : tab_q_poc_b;
    // the scan's first stage (D_OUT_SCAN): store dx's candidacy and POC, registered
    logic        sq_v;
    logic [4:0]  sq_dx;
    logic signed [31:0] sq_poc, sq_pt, sq_pb;
    always_ff @(posedge clk) begin
        sq_v <= (di != 5'd0) && (di != SC_RES) && sc_cand;
        sq_dx <= dx; sq_poc <= sc_poc; sq_pt <= tab_q_poc_t; sq_pb <= tab_q_poc_b;
    end
    // the DPB size engine: Min(MaxDpbMbs / PicSizeInMbs, 16) by repeated subtraction, or
    // max_dec_frame_buffering (Max(1, it)) -- started when a picture opens
    logic [17:0] sz_acc;
    logic [15:0] sz_pic;
    logic [4:0]  sz_cnt;
    logic        sz_run;
    logic [17:0] max_dpb_mbs;
    always_comb begin
        case (s.level_idc)
            8'd9, 8'd10:          max_dpb_mbs = 18'd396;
            8'd11:                max_dpb_mbs = 18'd900;     // (1b as 11 + constraint_set3: read as 1.1, larger)
            8'd12, 8'd13, 8'd20:  max_dpb_mbs = 18'd2376;
            8'd21:                max_dpb_mbs = 18'd4752;
            8'd22, 8'd30:         max_dpb_mbs = 18'd8100;
            8'd31:                max_dpb_mbs = 18'd18000;
            8'd32:                max_dpb_mbs = 18'd20480;
            8'd40, 8'd41:         max_dpb_mbs = 18'd32768;
            8'd42:                max_dpb_mbs = 18'd34816;
            8'd50:                max_dpb_mbs = 18'd110400;
            8'd51, 8'd52:         max_dpb_mbs = 18'd184320;
            default:              max_dpb_mbs = 18'd8100;
        endcase
    end
    wire [7:0] w_mbs_s  = {1'b0, s.width_mbs_minus1} + 8'd1;
    wire [7:0] hf_mbs_s = s.frame_mbs_only ? ({1'b0, s.height_map_units_minus1} + 8'd1)
                                           : ({s.height_map_units_minus1, 1'b0} + 8'd2);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NSTORE; i++) begin
                ref_t[i] <= UNUSED; ref_b[i] <= UNUSED; dec_t[i] <= 1'b0; dec_b[i] <= 1'b0;
                lt[i] <= '0; lt_v[i] <= 1'b0;
                frame_coded[i] <= 1'b0; first_bot[i] <= 1'b0; isref[i] <= 1'b0; mmco5_r[i] <= 1'b0; alloc[i] <= 1'b0;
            end
            di <= '0; mm_any <= 1'b0; win_found <= 1'b0; win_victim <= '0; win_best <= '0; wz_v <= 1'b0; wz_dx <= '0; wz_fnw <= '0; num_short <= '0; num_long <= '0;
            ds <= D_IDLE; pic_open <= 1'b0; cur_store <= '0; cur_struct <= S_F; cur_isref <= 1'b0; cur_poc <= '0;
            cur_idr <= 1'b0; cur_field <= 1'b0; cur_bottom <= 1'b0; cur_mmco5 <= 1'b0; cur_adaptive <= 1'b0;
            cur_ltref <= 1'b0; cur_fn <= '0; cur_poc_top <= '0; cur_poc_bot <= '0; cur_poc_msb <= '0; cur_fno <= '0;
            cur_n_mmco <= '0; prev_poc_msb <= '0; prev_poc_lsb <= '0; prev_fno <= '0; prev_ref_top_poc <= '0;
            prev_fn <= '0; prev_ref_fn <= '0; prev_ref_mmco5 <= 1'b0; prev_ref_bottom <= 1'b0; prev_mmco5 <= 1'b0;
            prev_was_field <= 1'b0; prev_bottom <= 1'b0; prev_isref <= 1'b0; prev_mmco5_pic <= 1'b0; prev_fn_pic <= '0;
            prev_store <= '0; max_lt <= '0; max_lt_v <= 1'b0; mm_i <= '0; mm_q <= '0; p0_pm <= '0; p0_pl <= '0; mmco_addr <= '0; poc1_addr <= '0;
            pic_start <= 1'b0; pic_new <= 1'b0; lists_go <= 1'b0; slice_go <= 1'b0; busy <= 1'b0;
            err_gap <= 1'b0; err_no_store <= 1'b0; err_window <= 1'b0; err_mmco <= 1'b0;
            marked_long <= 1'b0; tmp_a <= '0; tmp_b <= '0; abs_fn_i <= '0; abs_fn <= '0; expected <= '0; fn_wrap <= 1'b0;
            cyc_cnt <= '0; in_cyc <= '0; mm_op <= '0; mm_a <= '0; mm_b <= '0;
            div_num <= '0; div_rem <= '0; div_i <= '0; poc1_prod <= '0;
            pt_we <= 1'b0; pb_we <= 1'b0; fw_we <= 1'b0; fn_we <= 1'b0; pt_wa <= '0; pb_wa <= '0; fw_wa <= '0; fn_wa <= '0;
            pt_wd <= '0; pb_wd <= '0; fw_wd <= '0; fn_wd <= '0;
            waiting <= '0; emitted <= '0; pend_emit <= '0; om <= OM_FLUSH; eos_pend <= 1'b0; eos_mode <= 1'b0;
            cur_no_output <= 1'b0; cur_dpb_sz <= 5'd16; best_found <= 1'b0; act_bump <= 1'b0; act_late <= 1'b0; best_store <= '0; best_poc <= '0;
            best_pt <= '0; best_pb <= '0; stall_ctr <= '0; sz_acc <= '0; sz_pic <= '0; sz_cnt <= '0; sz_run <= 1'b0;
            emit_valid <= 1'b0; emit_store <= '0; emit_unpaired <= 1'b0; emit_first_bot <= 1'b0; emit_frame <= 1'b0;
            emit_dec_t <= 1'b0; emit_dec_b <= 1'b0; emit_poc_t <= '0; emit_poc_b <= '0; eos_done <= 1'b0;
            out_dropped <= '0; out_direct <= '0; out_over <= '0; stall_cycles <= '0; nrf_late <= '0;
            drop_n <= '0; drop_go <= 1'b0;
            cur_nrf <= '0; cur_nrf_on <= 1'b0; last_out_poc <= '0; last_out_v <= 1'b0;
        end else begin
            pic_start <= 1'b0; lists_go <= 1'b0; slice_go <= 1'b0;
            pt_we <= 1'b0; pb_we <= 1'b0; fw_we <= 1'b0; fn_we <= 1'b0;
            emit_valid <= 1'b0; eos_done <= 1'b0;
            if (eos) eos_pend <= 1'b1;
            drop_go <= 1'b0;
            if (drop_go) out_dropped <= out_dropped + {26'd0, drop_n};
            // the DPB size engine (P5d)
            if (sz_run) begin
                if (sz_cnt != 5'd16 && sz_acc >= {2'd0, sz_pic}) begin
                    sz_acc <= sz_acc - {2'd0, sz_pic}; sz_cnt <= sz_cnt + 5'd1;
                end else begin
                    sz_run <= 1'b0; cur_dpb_sz <= (sz_cnt == 5'd0) ? 5'd1 : sz_cnt;
                end
            end
            err_gap <= 1'b0; err_no_store <= 1'b0; err_window <= 1'b0; err_mmco <= 1'b0;
            if (clear) begin
                for (int i = 0; i < NSTORE; i++) begin
                    ref_t[i] <= UNUSED; ref_b[i] <= UNUSED; dec_t[i] <= 1'b0; dec_b[i] <= 1'b0; alloc[i] <= 1'b0;
                end
                pic_open <= 1'b0; ds <= D_IDLE; busy <= 1'b0;
                waiting <= '0; emitted <= '0; pend_emit <= '0; eos_pend <= 1'b0; eos_mode <= 1'b0;
                prev_ref_fn <= '0; prev_fn <= '0; prev_mmco5 <= 1'b0; prev_ref_mmco5 <= 1'b0; prev_was_field <= 1'b0;
            end else case (ds)
                D_IDLE: if (slice_ready) begin
                    busy <= 1'b1;
                    pic_new <= new_pic;
                    if (new_pic) ds <= D_WAIT_IDLE; else ds <= D_FNW;
                end else if (eos_pend) begin
                    // end of stream: close the open picture like a new one would, then flush
                    busy <= 1'b1; eos_pend <= 1'b0; eos_mode <= 1'b1;
                    ds <= D_WAIT_IDLE;
                end
                D_WAIT_IDLE: if (pipe_idle) begin
                    if (pic_open && cur_isref) ds <= D_MARK;
                    else if (pic_open) ds <= D_OUT_C44;
                    else ds <= D_POST_MARK;
                end
                // ---- 8.2.5: mark the picture that just completed ----------------------
                D_MARK: begin
                    // FrameNumWrap against the completed picture's frame_num: one store a cycle
                    if (di == 5'd0) begin marked_long <= 1'b0; end
                    else begin fw_we <= 1'b1; fw_wa <= dx; fw_wd <= y_fnw_new; end
                    di <= di + 1'b1;
                    if (di == SC_LAST) begin
                        di <= '0;
                        if (cur_idr) ds <= D_MARK_IDR;
                        else if (!cur_adaptive) ds <= D_MARK_WIN;
                        else begin mm_i <= '0; ds <= D_MMCO_RD; end
                    end
                end
                D_MARK_IDR: begin
                    for (int i = 0; i < NSTORE; i++) if (i[4:0] != cur_store) begin ref_t[i] <= UNUSED; ref_b[i] <= UNUSED; end
                    if (cur_ltref) begin
                        lt[cur_store] <= 5'd0; lt_v[cur_store] <= 1'b1; max_lt <= 5'd0; max_lt_v <= 1'b1;
                        if (cur_struct != S_B) ref_t[cur_store] <= LONG;
                        if (cur_struct != S_T) ref_b[cur_store] <= LONG;
                    end else begin
                        max_lt_v <= 1'b0;
                        if (cur_struct != S_B) ref_t[cur_store] <= SHORT;
                        if (cur_struct != S_T) ref_b[cur_store] <= SHORT;
                    end
                    ds <= D_OUT_C44;
                end
                D_MARK_WIN: begin
                    // the scan's registers cleared whether or not it runs (only the scan and
                    // its resolve read them): gating their ~80 enables on the pair test below
                    // (a 20:1 read of ref_t / ref_b by cur_store) was the 100 C binding path
                    // of the first 96.43 MHz fit (P5b)
                    win_found <= 1'b0; win_victim <= '0; win_best <= 32'sh7FFFFFFF; num_short <= '0; num_long <= '0;
                    wz_v <= 1'b0;
                    di <= '0;
                    // the second field of a short-term pair: no window (8.2.5.3)
                    if (cur_field && (first_bot[cur_store] != cur_bottom) && ((cur_bottom ? ref_t[cur_store] : ref_b[cur_store]) == SHORT))
                        ds <= D_MARK_CUR;
                    else
                        ds <= D_MARK_WIN_SCAN;
                end
                D_MARK_WIN_SCAN: if (di != SC_RES + 5'd1) begin
                    // first minimum in store order, as the parallel search had it; the
                    // candidate of step di is compared at step di + 1, so the resolve is a
                    // step later than the other scans' (the steps past SC_LAST read UNUSED)
                    wz_v <= (di != 5'd0) && y_notcur && (y_rt == SHORT || y_rb == SHORT);
                    wz_dx <= dx; wz_fnw <= y_fnw;
                    if (wz_v && (!win_found || wz_fnw < win_best)) begin win_found <= 1'b1; win_victim <= wz_dx; win_best <= wz_fnw; end
                    if (di != 5'd0 && y_notcur) begin
                        if (y_rt == SHORT || y_rb == SHORT) num_short <= num_short + 5'd1;
                        else if (y_rt == LONG || y_rb == LONG) num_long <= num_long + 5'd1;
                    end
                    di <= di + 1'b1;
                end else begin
                    di <= '0;
                    if ({1'b0, num_short} + {1'b0, num_long} >= {1'b0, max_ref_frames}) begin
                        if (!win_found) err_window <= 1'b1;
                        else begin ref_t[win_victim] <= UNUSED; ref_b[win_victim] <= UNUSED; end
                    end
                    ds <= D_MARK_CUR;
                end
                D_MMCO_RD: begin
                    if (mm_i >= cur_n_mmco[5:0] || cur_n_mmco == 7'd0) ds <= D_MARK_CUR;
                    else begin
                        mm_q <= mm_ram[mm_i];
                        di <= '0; mm_any <= 1'b0;
                        ds <= D_MMCO_EXEC;
                    end
                end
                D_MMCO_EXEC: if (di != SC_RES + 5'd1) begin
                    // one operation over NSTORE + 2 cycles; store z_dx's decisions (registered
                    // from dx's the cycle before: the z stage below) applied this cycle
                    di <= di + 1'b1;
                    if (z_v) case (mm_q[66:64])
                        3'd1: begin                    // short-term -> unused, by picNumX
                            if (z_ms_t || z_ms_b) mm_any <= 1'b1;
                            if (cur_field) begin
                                if (z_ms_t) ref_t[z_dx] <= UNUSED;
                                if (z_ms_b) ref_b[z_dx] <= UNUSED;
                            end else if (z_ms_t) begin ref_t[z_dx] <= UNUSED; ref_b[z_dx] <= UNUSED; end
                        end
                        3'd2: begin                    // long-term -> unused
                            if (z_ml_t || z_ml_b) mm_any <= 1'b1;
                            if (cur_field) begin
                                if (z_ml_t) ref_t[z_dx] <= UNUSED;
                                if (z_ml_b) ref_b[z_dx] <= UNUSED;
                            end else if (z_ml_t) begin ref_t[z_dx] <= UNUSED; ref_b[z_dx] <= UNUSED; end
                        end
                        3'd3: begin                    // short-term -> long-term with idx b
                            if (z_op3) mm_any <= 1'b1;
                            if (z_lt_hit && !z_op3) begin
                                if (z_rt == LONG) ref_t[z_dx] <= UNUSED;
                                if (z_rb == LONG) ref_b[z_dx] <= UNUSED;
                            end
                            if (z_op3) begin
                                lt[z_dx] <= mm_q[4:0]; lt_v[z_dx] <= 1'b1;
                                if (cur_field) begin
                                    if (z_ms_t) ref_t[z_dx] <= LONG;
                                    if (z_ms_b) ref_b[z_dx] <= LONG;
                                end else begin ref_t[z_dx] <= LONG; ref_b[z_dx] <= LONG; end
                            end
                        end
                        3'd4: begin                    // MaxLongTermFrameIdx = a - 1
                            if (z_op4) begin
                                if (z_rt == LONG) ref_t[z_dx] <= UNUSED;
                                if (z_rb == LONG) ref_b[z_dx] <= UNUSED;
                            end
                        end
                        3'd5: begin                    // everything unused
                            if (z_notcur) begin ref_t[z_dx] <= UNUSED; ref_b[z_dx] <= UNUSED; end
                        end
                        3'd6: begin                    // the current picture -> long-term idx b: others first
                            if (z_lt_hit && z_notcur) begin
                                if (z_rt == LONG) ref_t[z_dx] <= UNUSED;
                                if (z_rb == LONG) ref_b[z_dx] <= UNUSED;
                            end
                        end
                        default: ;
                    endcase
                end else begin
                    di <= '0;
                    mm_i <= mm_i + 1'b1;
                    ds <= D_MMCO_RD;
                    case (mm_q[66:64])
                        3'd1, 3'd2, 3'd3: if (!mm_any) err_mmco <= 1'b1;
                        3'd4: begin max_lt_v <= (mm_q[63:32] != 32'd0); max_lt <= mm_q[36:32] - 5'd1; end
                        3'd5: max_lt_v <= 1'b0;
                        3'd6: begin
                            lt[cur_store] <= mm_q[4:0]; lt_v[cur_store] <= 1'b1;
                            if (cur_struct != S_B) ref_t[cur_store] <= LONG;
                            if (cur_struct != S_T) ref_b[cur_store] <= LONG;
                            marked_long <= 1'b1;
                        end
                        default: ;
                    endcase
                end
                D_MARK_CUR: begin
                    if (!marked_long) begin
                        if (cur_struct != S_B) ref_t[cur_store] <= SHORT;
                        if (cur_struct != S_T) ref_b[cur_store] <= SHORT;
                    end
                    ds <= D_OUT_C44;
                end
                // ---- C.4.4 / C.4.5: the output process (P5d), after the marking and
                // before an MMCO 5's POC rewrite (D_POST_MARK) ------------------------------
                D_OUT_C44: begin
                    if (cur_idr || cur_mmco5) last_out_v <= 1'b0;   // POCs restart: nothing to compare with
                    if (cur_idr && cur_no_output) begin
                        // emptied without output (the current store is not in the DPB yet)
                        drop_n <= drop_count; drop_go <= 1'b1;
                        for (int i = 0; i < NSTORE; i++) if (i[4:0] != cur_store) waiting[i] <= 1'b0;
                        ds <= D_OUT_FILL;
                    end else if (cur_idr || cur_mmco5) begin
                        om <= OM_FLUSH; di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN;
                    end else ds <= D_OUT_FILL;
                end
                D_OUT_FILL: ds <= D_OUT_FILL2;            // fill_q: two register stages after any change
                D_OUT_FILL2: ds <= D_OUT_C45;
                D_OUT_C45: begin
                    if (emitted[cur_store] || waiting[cur_store]) ds <= D_OUT_NRF0;  // a second field: same buffer
                    else if (fill_q < cur_dpb_sz) begin
                        waiting[cur_store] <= 1'b1; ds <= D_OUT_NRF0;                  // stored
                    end else begin
                        om <= cur_isref ? OM_REF : OM_NONREF; di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN;
                    end
                end
                // the waiting store with the smallest POC (first in store order), one a cycle.
                // Two stages: store dx's candidacy and POC are registered (sq_*, below) and
                // compared with the running best the next cycle -- the RAM read, the
                // store's min(top, bottom) and the compare with best_poc in one cycle was
                // clk_dec's binding path (P5e fit: 84.48 MHz at -40C). The resolve step
                // (di == SC_RES) compares the last store; D_OUT_PRE registers the decision
                // (the 32-bit POC compare behind best_poc fanned out to ~100 loads in
                // D_OUT_ACT: 9.5 ns, P5b) and D_OUT_ACT acts on it.
                D_OUT_SCAN: begin
                    if (di >= 5'd2 && sq_v && (!best_found || sq_poc < best_poc)) begin
                        best_found <= 1'b1; best_store <= sq_dx; best_poc <= sq_poc;
                        best_pt <= sq_pt; best_pb <= sq_pb;
                    end
                    if (di != SC_RES) di <= di + 1'b1;
                    else begin di <= '0; ds <= D_OUT_PRE; end
                end
                D_OUT_PRE: begin
                    act_bump <= best_found && ((om != OM_NONREF) || (best_poc <= cur_poc));
                    act_late <= last_out_v && best_poc < last_out_poc;
                    ds <= D_OUT_ACT;
                end
                D_OUT_ACT: begin
                    // bump the best, or (a non-reference picture below every waiting POC)
                    // output the current picture directly
                    logic bump_it;
                    logic bs_cur, bs_dt, bs_db;
                    bump_it = act_bump;
                    bs_cur = pic_open && best_store == cur_store;        // only in OM_NRF, complete
                    bs_dt  = dec_t[best_store] || (bs_cur && cur_struct != S_B);
                    bs_db  = dec_b[best_store] || (bs_cur && cur_struct != S_T);
                    if (bump_it) begin
                        emit_valid <= 1'b1; emit_store <= best_store;
                        // a field store whose partner never came (the stream's end, or the
                        // next picture did not pair with it) goes out as a single field
                        emit_unpaired <= !frame_coded[best_store] && !(bs_dt && bs_db);
                        emit_first_bot <= first_bot[best_store]; emit_frame <= frame_coded[best_store];
                        emit_dec_t <= bs_dt; emit_dec_b <= bs_db;
                        emit_poc_t <= best_pt; emit_poc_b <= best_pb;
                        waiting[best_store] <= 1'b0; emitted[best_store] <= 1'b1;
                        last_out_poc <= best_poc; last_out_v <= 1'b1;
                        if (om == OM_NRF && act_late) nrf_late <= nrf_late + 32'd1;
                    end
                    case (om)
                        OM_FLUSH: begin
                            if (bump_it) begin di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN; end
                            else ds <= D_OUT_FILL;
                        end
                        OM_EOS: begin
                            if (bump_it) begin di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN; end
                            else begin
                                eos_done <= 1'b1; eos_mode <= 1'b0; busy <= 1'b0; ds <= D_IDLE;
                            end
                        end
                        OM_NRF: begin                                 // EARLY OUTPUT: count again
                            if (bump_it) ds <= D_OUT_NRF0; else ds <= D_OUT_END;
                        end
                        OM_REF: begin
                            if (bump_it) ds <= D_OUT_FILL;
                            else begin
                                out_over <= out_over + 32'd1;          // full of references alone
                                waiting[cur_store] <= 1'b1; ds <= D_OUT_NRF0;
                            end
                        end
                        default: begin                                // OM_NONREF
                            if (bump_it) ds <= D_OUT_FILL;
                            else begin
                                out_direct <= out_direct + 32'd1;
                                emitted[cur_store] <= 1'b1;
                                last_out_poc <= cur_poc; last_out_v <= 1'b1;
                                if (cur_complete) begin
                                    emit_valid <= 1'b1; emit_store <= cur_store; emit_unpaired <= 1'b0;
                                    emit_first_bot <= first_bot[cur_store]; emit_frame <= frame_coded[cur_store];
                                    emit_dec_t <= 1'b1; emit_dec_b <= 1'b1;
                                    emit_poc_t <= cur_poc_top; emit_poc_b <= cur_poc_bot;
                                end else pend_emit[cur_store] <= 1'b1;   // with its second field
                                ds <= D_OUT_NRF0;
                            end
                        end
                    endcase
                end
                // EARLY OUTPUT (E.2.1): nw_q is two register stages after any change
                D_OUT_NRF0: ds <= D_OUT_NRF1;
                D_OUT_NRF1: ds <= D_OUT_NRF;
                D_OUT_NRF: begin
                    if (cur_nrf_on && nw_q > cur_nrf) begin
                        om <= OM_NRF; di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN;
                    end else ds <= D_OUT_END;
                end
                D_OUT_END: begin
                    // a store output before its pair completed goes out with the second field
                    if (pend_emit[cur_store] && cur_complete && !emit_valid) begin
                        emit_valid <= 1'b1; emit_store <= cur_store; emit_unpaired <= 1'b0;
                        emit_first_bot <= first_bot[cur_store]; emit_frame <= frame_coded[cur_store];
                        emit_dec_t <= 1'b1; emit_dec_b <= 1'b1;
                        emit_poc_t <= cur_poc_top; emit_poc_b <= cur_poc_bot;
                        pend_emit[cur_store] <= 1'b0;
                    end
                    if (!emit_valid) ds <= D_POST_MARK;
                end
                // end of stream: a store still pending goes out unpaired, then every waiting
                // store in POC order (the last picture included: it is closed now)
                D_EOS: begin
                    if (pend_emit[prev_store]) begin
                        emit_valid <= 1'b1; emit_store <= prev_store; emit_unpaired <= 1'b1;
                        emit_first_bot <= first_bot[prev_store]; emit_frame <= 1'b0;
                        emit_dec_t <= dec_t[prev_store]; emit_dec_b <= dec_b[prev_store];
                        emit_poc_t <= cur_poc_top; emit_poc_b <= cur_poc_bot;
                        pend_emit[prev_store] <= 1'b0;
                    end
                    om <= OM_EOS; di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN;
                end
                D_POST_MARK: begin
                    // the POC / frame_num state the next picture derives from (8.2.1)
                    if (pic_open) begin
                        if (cur_isref) begin
                            prev_ref_mmco5 <= cur_mmco5;
                            prev_ref_bottom <= (cur_struct == S_B);
                            prev_poc_msb <= cur_mmco5 ? 32'sd0 : cur_poc_msb;
                            prev_poc_lsb <= cur_mmco5 ? ((cur_struct != S_B) ? cur_poc_top - cur_poc : 32'sd0) : $signed({16'd0, sh_poc_lsb_r});
                            prev_ref_top_poc <= (cur_struct != S_B) ? cur_poc_top - cur_poc : 32'sd0;
                            prev_ref_fn <= cur_mmco5 ? 16'd0 : cur_fn;
                        end
                        prev_mmco5 <= cur_mmco5;
                        prev_fno <= cur_mmco5 ? 32'sd0 : cur_fno;
                        prev_fn <= cur_mmco5 ? 16'd0 : cur_fn;
                        if (cur_mmco5) begin
                            // 8.2.1: the picture's POCs become relative to itself
                            if (cur_struct != S_B) begin pt_we <= 1'b1; pt_wa <= cur_store; pt_wd <= cur_poc_top - cur_poc; end
                            if (cur_struct != S_T) begin pb_we <= 1'b1; pb_wa <= cur_store; pb_wd <= cur_poc_bot - cur_poc; end
                        end
                        prev_was_field <= cur_field; prev_bottom <= cur_bottom; prev_isref <= cur_isref;
                        prev_mmco5_pic <= cur_mmco5; prev_fn_pic <= cur_fn; prev_store <= cur_store;
                        mmco5_r[cur_store] <= cur_mmco5;
                    end
                    pic_open <= 1'b0;
                    if (eos_mode) ds <= D_EOS; else ds <= D_OPEN;
                end
                // ---- open the new picture ---------------------------------------------
                // (two cycles, P5b: D_OPEN decides -- the pairing, the gap, the store -- and
                // registers them; D_OPEN2 writes through a decoder of the REGISTERED store. The
                // 20:1 reads, the pairing, the priority encoder and the 20-way write decode in
                // one cycle were 11.0 ns)
                D_OPEN: begin
                    logic pairing;
                    pairing = prev_was_field && sh_field_pic && (prev_bottom != sh_bottom_field) && (prev_fn_pic == sh_frame_num)
                              && !sh_idr && !prev_mmco5_pic && (prev_isref == (sh_nal_ref_idc != 2'd0))
                              && !(sh_bottom_field ? dec_b[prev_store] : dec_t[prev_store]) && alloc[prev_store];
                    op_pairing <= pairing;
                    op_gap <= !sh_idr && (sh_frame_num != prev_ref_fn) && (sh_frame_num != ((prev_ref_fn + 16'd1) & (max_fn[15:0] - 16'd1))) && !pairing;
                    op_st <= pairing ? prev_store : free_store;
                    op_free <= free_found;
                    ds <= D_OPEN2;
                end
                D_OPEN2: begin
                    logic pairing;
                    logic [4:0] st;
                    pairing = op_pairing;
                    st = op_st;
                    if (op_gap) err_gap <= 1'b1;
                    if (!pairing && !op_free && (|disp_hold)) begin
                        // every store is busy and the display holds some: wait for a release
                        // (bounded: a wait past STALL_LIMIT counts err_no_store, and waits on)
                        // -- deciding again in D_OPEN, where a released store is seen
                        // (two cycles a round now: both counters step by 2, cycles stay cycles).
                        // A frozen display holds its stores by design, so the bound restarts
                        // while it is frozen and runs from the release (UMD P6b3i: its pause
                        // counted ~8 errors a second; here the interface 0.5 pause word)
                        stall_cycles <= stall_cycles + 32'd2;
                        stall_ctr <= disp_frz ? 24'd0 : stall_ctr + 24'd2;
                        if (!disp_frz && stall_ctr >= STALL_LIMIT[23:0]) begin err_no_store <= 1'b1; stall_ctr <= '0; end
                        ds <= D_OPEN;
                    end else begin
                    stall_ctr <= '0;
                    if (!pairing && !op_free) err_no_store <= 1'b1;
                    // a store output directly before its pair completed: the pair did not come
                    if (pend_emit[prev_store] && !pairing) begin
                        emit_valid <= 1'b1; emit_store <= prev_store; emit_unpaired <= 1'b1;
                        emit_first_bot <= first_bot[prev_store]; emit_frame <= 1'b0;
                        emit_dec_t <= dec_t[prev_store]; emit_dec_b <= dec_b[prev_store];
                        emit_poc_t <= cur_poc_top; emit_poc_b <= cur_poc_bot;
                        pend_emit[prev_store] <= 1'b0;
                    end
                    if (!pairing) begin waiting[st] <= 1'b0; emitted[st] <= 1'b0; pend_emit[st] <= 1'b0; end
                    cur_no_output <= sh_no_output_of_prior_pics;
                    // the DPB size for this picture (its SPS): the engine above
                    // early output (E.2.1): the VUI's limit, else 0 for POC type 2 (8.2.1.3), else none
                    cur_nrf_on <= s.bitstream_restriction || (s.poc_type == 2'd2);
                    cur_nrf    <= s.bitstream_restriction ? s.max_num_reorder_frames : 5'd0;
                    if (s.bitstream_restriction) begin
                        cur_dpb_sz <= (s.max_dec_frame_buffering == 5'd0) ? 5'd1 : s.max_dec_frame_buffering;
                        sz_run <= 1'b0;
                    end else begin
                        sz_acc <= max_dpb_mbs; sz_pic <= w_mbs_s * hf_mbs_s; sz_cnt <= 5'd0; sz_run <= 1'b1;
                    end
                    cur_store <= st;
                    cur_struct <= sh_field_pic ? (sh_bottom_field ? S_B : S_T) : S_F;
                    cur_field <= sh_field_pic; cur_bottom <= cur_bot_now;
                    cur_isref <= (sh_nal_ref_idc != 2'd0); cur_idr <= sh_idr; cur_fn <= sh_frame_num;
                    // FrameNumOffset's wrap test for D_POC1_RD / D_POC2 (clk_dec 103.85 retime: the
                    // compare in front of their 27-way select and add was 9.0 ns); prev_fn changes
                    // only at a picture's close, frame_num is the slice header's
                    fn_wrap <= ($signed({16'd0, prev_fn}) > $signed({16'd0, sh_frame_num}));
                    cur_mmco5 <= sh_mmco5; cur_adaptive <= sh_adaptive_marking; cur_ltref <= sh_long_term_reference;
                    cur_n_mmco <= sh_n_mmco;
                    fn_we <= 1'b1; fn_wa <= st; fn_wd <= sh_frame_num; isref[st] <= (sh_nal_ref_idc != 2'd0); alloc[st] <= 1'b1;
                    if (!pairing) begin
                        dec_t[st] <= 1'b0; dec_b[st] <= 1'b0; ref_t[st] <= UNUSED; ref_b[st] <= UNUSED;
                        lt_v[st] <= 1'b0; frame_coded[st] <= !sh_field_pic; first_bot[st] <= cur_bot_now; mmco5_r[st] <= 1'b0;
                    end
                    pic_open <= 1'b1;
                    case (s.poc_type)
                        2'd0: ds <= D_POC0;
                        2'd1: begin poc1_addr <= 8'd0; ds <= D_POC1_RD; end
                        default: ds <= D_POC2;
                    endcase
                    end
                end
                // 8.2.1.1 over three cycles (the whole chain in one missed clk_dec): the previous
                // values, the MSB, the count
                D_POC0: begin
                    if (sh_idr) begin p0_pm <= 33'sd0; p0_pl <= 33'sd0; end
                    else if (prev_ref_mmco5) begin p0_pm <= 33'sd0; p0_pl <= prev_ref_bottom ? 33'sd0 : {prev_ref_top_poc[31], prev_ref_top_poc}; end
                    else begin p0_pm <= {prev_poc_msb[31], prev_poc_msb}; p0_pl <= {prev_poc_lsb[31], prev_poc_lsb}; end
                    ds <= D_POC0B;
                end
                // (8-3 over two cycles, P5b: the wrap tests and both candidates registered,
                // then selected -- the lsb compares, the differences against half and the
                // 33-bit adds in front of p0_pm were 10.2 ns)
                D_POC0B: begin
                    logic signed [32:0] lsb, half;
                    lsb = {17'd0, sh_poc_lsb};
                    half = {max_lsb[31], max_lsb} >>> 1;
                    p0_up <= p0_pm + {max_lsb[31], max_lsb};
                    p0_dn <= p0_pm - {max_lsb[31], max_lsb};
                    p0_cu <= (lsb < p0_pl) && ((p0_pl - lsb) >= half);
                    p0_cd <= (lsb > p0_pl) && ((lsb - p0_pl) > half);
                    ds <= D_POC0B2;
                end
                D_POC0B2: begin
                    if (p0_cu) p0_pm <= p0_up;
                    else if (p0_cd) p0_pm <= p0_dn;
                    ds <= D_POC0C;
                end
                D_POC0C: begin
                    cur_poc_msb <= p0_pm[31:0];
                    tmp_a <= p0_pm[31:0] + $signed({16'd0, sh_poc_lsb});             // top (or a bottom field's)
                    ds <= D_POC_BOT;
                end
                D_POC1_RD: begin
                    // FrameNumOffset and absFrameNum (8.2.1.2)
                    logic signed [31:0] fno;
                    if (sh_idr) fno = 32'sd0;
                    else if (prev_mmco5) fno = fn_wrap ? max_fn : 32'sd0;
                    else fno = fn_wrap ? prev_fno + max_fn : prev_fno;
                    cur_fno <= fno;
                    abs_fn <= (s.num_ref_frames_in_poc_cycle != 8'd0) ? fno + $signed({16'd0, sh_frame_num}) : 32'sd0;
                    ds <= D_POC1_RD2;
                end
                D_POC1_RD2: begin
                    logic signed [31:0] a;
                    a = abs_fn;
                    if (sh_nal_ref_idc == 2'd0 && a > 32'sd0) a = a - 32'sd1;
                    abs_fn <= a;
                    ds <= D_POC1_RD3;
                end
                D_POC1_RD3: begin
                    // (absFrameNum - 1) / num_ref_frames_in_pic_order_cnt_cycle and %: a
                    // restoring divider, one quotient bit per cycle (32 cycles, once per picture
                    // of a type-1 stream; a combinational 32/8 divider would not meet clk_dec).
                    // Its own state (clk_dec 103.85 retime: the non-reference decrement and this
                    // one, two compare-and-subtracts on 32 bits in one cycle, were 9.1 ns; one
                    // cycle a picture)
                    div_num <= (abs_fn > 32'sd0) ? abs_fn - 32'sd1 : 32'sd0;
                    div_rem <= '0;
                    div_i <= 6'd32;
                    ds <= D_POC1_DIV;
                end
                D_POC1_DIV: begin
                    logic [32:0] r;
                    r = {div_rem[31:0], div_num[31]};
                    if (div_i == 6'd0) begin
                        cyc_cnt <= div_num;             // the quotient shifted in
                        in_cyc <= div_rem[7:0];
                        poc1_addr <= div_rem[7:0];
                        ds <= D_POC1_MUL;
                    end else begin
                        if (r >= {25'd0, s.num_ref_frames_in_poc_cycle}) begin
                            div_rem <= r[31:0] - {24'd0, s.num_ref_frames_in_poc_cycle};
                            div_num <= {div_num[30:0], 1'b1};
                        end else begin
                            div_rem <= r[31:0];
                            div_num <= {div_num[30:0], 1'b0};
                        end
                        div_i <= div_i - 1'b1;
                    end
                end
                D_POC1_MUL: begin                       // registered product (a DSP)
                    poc1_prod <= cyc_cnt * poc1_total;
                    ds <= D_POC1_CALC;
                end
                // (over three cycles: the product's adds chained into tmp_b missed clk_dec)
                D_POC1_CALC: begin
                    // poc1_data = the prefix sum up to in_cyc (addressed two cycles ago)
                    logic signed [31:0] e;
                    if (abs_fn > 32'sd0) e = poc1_prod + poc1_data;
                    else e = 32'sd0;
                    if (sh_nal_ref_idc == 2'd0) e = e + s.offset_for_non_ref_pic;
                    expected <= e;
                    ds <= D_POC1_C2;
                end
                D_POC1_C2: begin
                    // a bottom field's own count: expected + offset_for_top_to_bottom + delta0
                    if (sh_field_pic && sh_bottom_field) tmp_a <= expected + s.offset_for_top_to_bottom_field + sh_delta_poc0;
                    else tmp_a <= expected + sh_delta_poc0;
                    ds <= D_POC1_C3;
                end
                D_POC1_C3: begin
                    // the bottom: a frame's from the top, a bottom field's own count in both
                    // (D_POC_DONE reads tmp_b)
                    if (!sh_field_pic) tmp_b <= tmp_a + s.offset_for_top_to_bottom_field + sh_delta_poc1;
                    else if (sh_bottom_field) tmp_b <= tmp_a;
                    ds <= D_POC_BOT;
                end
                D_POC2: begin                          // FrameNumOffset registered first (clk_dec)
                    logic signed [31:0] fno;
                    if (sh_idr) fno = 32'sd0;
                    else if (prev_mmco5) fno = fn_wrap ? max_fn : 32'sd0;
                    else fno = fn_wrap ? prev_fno + max_fn : prev_fno;
                    cur_fno <= fno;
                    ds <= D_POC2B;
                end
                D_POC2B: begin
                    logic signed [31:0] t;
                    if (sh_idr) t = 32'sd0;
                    else if (sh_nal_ref_idc == 2'd0) t = 32'sd2 * (cur_fno + $signed({16'd0, sh_frame_num})) - 32'sd1;
                    else t = 32'sd2 * (cur_fno + $signed({16'd0, sh_frame_num}));
                    tmp_a <= t; tmp_b <= t;
                    ds <= D_POC_BOT;
                end
                D_POC_BOT: begin
                    // type 0: the bottom field's count registered first (the add and the
                    // min in one cycle missed clk_dec)
                    if (s.poc_type == 2'd0) tmp_b <= sh_field_pic ? tmp_a : tmp_a + sh_delta_poc_bottom;
                    ds <= D_POC_DONE;
                end
                D_POC_DONE: begin
                    // tmp_a: TopFieldOrderCnt (or the bottom field's own); tmp_b: bottom
                    logic signed [31:0] top, bot;
                    top = tmp_a; bot = tmp_b;
                    if (cur_struct != S_B) begin cur_poc_top <= top; pt_we <= 1'b1; pt_wa <= cur_store; pt_wd <= top; end
                    if (cur_struct != S_T) begin cur_poc_bot <= bot; pb_we <= 1'b1; pb_wa <= cur_store; pb_wd <= bot; end
                    cur_poc <= (cur_struct == S_T) ? top : (cur_struct == S_B) ? bot : ((top < bot) ? top : bot);
                    sh_poc_lsb_r <= sh_poc_lsb;
                    pic_start <= 1'b1;
                    ds <= D_FNW;
                end
                // ---- every slice: FrameNumWrap, the MMCO copy, the lists --------------------
                D_FNW: begin
                    if (di != 5'd0) begin fw_we <= 1'b1; fw_wa <= dx; fw_wd <= y_fnw_new; end   // against sh_frame_num
                    di <= di + 1'b1;
                    if (di == SC_LAST) begin di <= '0; ds <= D_FNW_SCAN; end
                end
                D_FNW_SCAN: begin
                    mm_i <= '0; mmco_addr <= '0;
                    cur_n_mmco <= sh_n_mmco; cur_mmco5 <= sh_mmco5; cur_adaptive <= sh_adaptive_marking;
                    if (sh_adaptive_marking && sh_n_mmco != 7'd0) ds <= D_COPY_MMCO;
                    else ds <= D_LISTS;
                end
                D_COPY_MMCO: begin                     // mmco_data lands one cycle after the address
                    mmco_addr <= mmco_addr + 1'b1;
                    ds <= D_COPY_MMCO2;
                end
                D_COPY_MMCO2: begin
                    mm_ram[mm_i] <= mmco_data;
                    mm_i <= mm_i + 1'b1;
                    if (mm_i + 6'd1 >= sh_n_mmco[5:0]) ds <= D_LISTS;
                    else begin mmco_addr <= mmco_addr + 1'b1; ds <= D_COPY_MMCO2; end
                end
                D_LISTS: begin
                    if (sh_slice_type == 2'd2) begin slice_go <= 1'b1; busy <= 1'b0; ds <= D_IDLE; end
                    else begin lists_go <= 1'b1; ds <= D_LISTS_WAIT; end
                end
                D_LISTS_WAIT: if (lists_done) begin
                    slice_go <= 1'b1; busy <= 1'b0; ds <= D_IDLE;
                end
                default: ds <= D_IDLE;
            endcase
            // a field marks its store decoded when the picture closes (D_POST_MARK sees pic_open)
            if (ds == D_POST_MARK && pic_open) begin
                if (cur_struct != S_B) dec_t[cur_store] <= 1'b1;
                if (cur_struct != S_T) dec_b[cur_store] <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
