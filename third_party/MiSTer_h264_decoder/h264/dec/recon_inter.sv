// h264/dec/recon_inter.sv -- the inter prediction samples of one macroblock (8.4.2):
// reference windows from the DPB in DDR3, mc_interp, wpred, into the macroblock's
// sample RAM (docs/h264_recon.md S2.3)
//
// The motion of the sixteen 4x4 blocks (mv_pred's result) is grouped by uniformity:
// the whole macroblock when all sixteen agree, else per 8x8 quadrant when its four
// agree, else per 4x4 block -- grouping changes the work, never the samples (every
// sample is interpolated from its own position with its block's vector). Per group and
// per plane (Y, Cb, Cr):
//   for each list the group predicts from:
//     FETCH  the reference window (luma (w+5)x(h+5) from (xInt-2, yInt-2), chroma
//            (w/2+1)x(h/2+1) from (xInt, yInt) -- since S4k only the rectangle the
//            position class reads: geometry below), every coordinate clamped into the
//            reference picture (8-228 / 8-229 / 8-230 / 8-231): per window row one
//            burst over the 64-bit words its clamped columns span (<= 4), then four
//            bytes a cycle into the window RAM, the clamped column picking its byte; up
//            to sixteen rows in flight (the memory client pipelines them);
//     MC     mc_interp over the window: list 0 of a bi-predicted group into pbuf0, the
//            last list streaming through
//   WEIGHT wpred (default, explicit, implicit: 8.4.2.3 / 8.4.3) into the sample RAM.
// FETCH and MC / WEIGHT are two machines over a double-buffered window: item n + 1 is
// fetched while item n is interpolated (the fetch / interpolation overlap), and (P5b) an
// item's interpolation starts while its own window is still arriving: the bank is claimed
// with its descriptor when its COPY starts, bank_rows counts the rows written, and
// mc_interp reads a row only once it is counted (its rows_avail). The first window of a
// macroblock was otherwise ~195 cycles of an idle interpolator (docs/throughput.md S5).
// Since 4c' the fetch itself is three sides (request / receive / copy, below): the requests
// run ahead into the next item instead of waiting for this one's copy. Since 4b the
// interpolation is two lanes (LN, below).
// A reference field is every other line of its frame store (a field picture's lines,
// 7.4.1.2.4); the chroma vector of a field picture referencing the opposite parity is
// offset by +-2 (Table 8-10). Implicit weights: dsf_calc per bi-predicted group.
//
// Addressing (docs/h264_recon.md S2.2): store s at word BASE + s << 18; luma plane rows
// of 2W words, Cb at 32*W*HF, Cr at 40*W*HF words (rows of W words); a picture row r of
// a field is store row 2r + parity.

`default_nettype none

module recon_inter (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    output logic        busy,
    output logic        done,
    output logic        err,               // a list entry with no picture was named

    // the macroblock and the picture
    input  wire  [6:0]  mb_x,
    input  wire  [6:0]  mb_y,              // in the current picture's macroblock rows
    input  wire  [7:0]  width_mbs,
    input  wire  [7:0]  frame_height_mbs,  // FrameHeightInMbs
    input  wire         field_pic,
    input  wire         bottom,            // the current field's parity
    input  wire  [28:0] dpb_base,          // word address of store 0
    input  wire  [20:0] plane_mbs,         // W * FrameHeightInMbs (<= 3600)

    // the motion of the 16 blocks: recon_mb's motion RAM, one block per read (registered:
    // the record of mot_ra's block the cycle after). Record: {mvy1, mvx1, code1, ref1, pred1,
    // mvy0, mvx0, code0, ref0, pred0}, the codes {valid, store, parity} of the list entries
    // (0 for a list the block does not use) -- LM_INFO's block layout above {nz, mode}
    output logic [3:0]  mot_ra,
    input  wire  [91:0] mot_q,
    // uniformity, computed by the caller as the blocks arrive: all sixteen alike, each 8x8
    input  wire         all16,
    input  wire  [3:0]  all8,

    // slice: the references and the weights
    input  wire  [1:0]  slice_type,        // 0 P, 1 B
    input  wire         weighted_pred,
    input  wire  [1:0]  weighted_bipred_idc,
    input  wire  [2:0]  luma_log2_wd,
    input  wire  [2:0]  chroma_log2_wd,
    output logic [4:0]  poc_ra0,           // recon_slice_tab's POC RAMs: the group's references,
    output logic [4:0]  poc_ra1,           // the item being set up (S4k: the next to start); read in KS_WT_RD2
    input  wire  [31:0] poc_q0,
    input  wire  [31:0] poc_q1,
    input  wire  [31:0] lng0,
    input  wire  [31:0] lng1,
    input  wire signed [31:0] cur_poc,
    output logic [5:0]  wt_addr,           // recon_hdr's weight table
    input  wire  [50:0] wt_data,           // {cr_o, cr_w, cb_o, cb_w, luma_o, luma_w}: weights 9 bits

    // DDR3 reads (dpb_mem, owned while busy)
    output logic        cmd_valid,
    input  wire         cmd_ready,
    output logic [28:0] cmd_addr,
    output logic [3:0]  cmd_len,
    input  wire         rd_valid,
    input  wire  [63:0] rd_data,
    output logic        rd_ready,

    // the macroblock's sample RAM, a 64-bit word at a time (P5b 4b): word {y, x[3]} for luma
    // (0..31), 32 + y for Cb, 40 + y for Cr; out_be the bytes written (a lane's row segment)
    output logic        out_we,
    output logic [5:0]  out_word,
    output logic [7:0]  out_be,
    output logic [63:0] out_wdata
);

    // ---- the FSM -----------------------------------------------------------------------------
    // Two machines over a double-buffered window RAM (the fetch / interpolation overlap,
    // docs/h264_recon.md S6): the FETCH side (st) walks the (group, plane, list) items --
    // geometry, the reference rows, the copy into window bank fb -- marks the bank full with
    // the item's descriptor and goes straight on to the next item, waiting only for a full
    // bank; the INTERPOLATION side (k) takes the banks in order: list 0 of a bi-predicted
    // group into pbuf0, else the weights and the interpolation streaming through wpred into
    // the sample RAM, then frees the bank. The interpolation side stays serial, so pbuf0
    // (written by list 0, read by list 1 of the same group) has one user at a time.
    typedef enum logic [4:0] {
        I_IDLE, I_GROUP, I_PLANE, I_LIST, I_LIST2, I_LIST3, I_LIST4, I_REQ, I_NEXT_PLANE, I_NEXT_GROUP, I_DRAIN, I_DONE
    } istate_t;
    istate_t st;
    typedef enum logic [3:0] {
        K_IDLE, K_RD0, K_RD1, K_RDW, K_FR0, K_FR1
    } kstate_t;
    kstate_t k;
    // S4k step B: the next item's weights are read by a SETUP machine (ks) as soon as its bank
    // is claimed -- while the item before it still reads -- so it starts the cycle the lanes
    // are free. Its target is the bank that starts next: kb while k is idle, the other bank
    // while kb's item reads; sdone: the target's setup is done (s_kind its route, wp_* its
    // weights, held until its start pushes them into the writers)
    typedef enum logic [2:0] {
        KS_IDLE, KS_WT_RD, KS_WT_RD1, KS_WT_RD2, KS_IMPL, KS_IMPL2, KS_IMPL_WAIT, KS_FIN
    } ksstate_t;
    ksstate_t ks;
    logic        sdone, s_kind;
    logic [1:0]  bank_full;                // a window bank is claimed by an item (from its fetch's start)
    logic [4:0]  bank_rows [0:1];          // ... and how many of its window rows are written
    logic        fb, kb;                   // the bank the fetch fills / the interpolation sweeps
    // the item descriptor, per bank
    logic [1:0]  d_plane [0:1];
    logic [2:0]  d_fx [0:1];
    logic [2:0]  d_fy [0:1];
    logic [4:0]  d_bw [0:1];
    logic [4:0]  d_bh [0:1];
    logic [4:0]  d_gx [0:1];
    logic [4:0]  d_gy [0:1];
    logic [4:0]  d_gref0 [0:1];
    logic [4:0]  d_gref1 [0:1];
    logic        d_bi [0:1];
    logic        d_lx [0:1];
    logic        d_gp0 [0:1];
    wire  [1:0]  kd_plane = d_plane[kb];
    wire         kd_c = (kd_plane != 2'd0);
    wire  [2:0]  kd_fx = d_fx[kb];
    wire  [2:0]  kd_fy = d_fy[kb];
    wire  [4:0]  kd_bw = d_bw[kb];
    wire  [4:0]  kd_bh = d_bh[kb];
    wire  [4:0]  kd_gx = d_gx[kb];
    wire  [4:0]  kd_gy = d_gy[kb];
    wire  [4:0]  kd_gref0 = d_gref0[kb];
    wire  [4:0]  kd_gref1 = d_gref1[kb];
    wire         kd_bi = d_bi[kb];
    wire         kd_lx = d_lx[kb];
    wire         kd_gp0 = d_gp0[kb];
    // the setup machine's target and its descriptor
    wire         tgt = (k == K_IDLE) ? kb : !kb;
    wire  [1:0]  sd_plane = d_plane[tgt];
    wire         sd_c = (sd_plane != 2'd0);
    wire  [4:0]  sd_gref0 = d_gref0[tgt];
    wire  [4:0]  sd_gref1 = d_gref1[tgt];
    wire         sd_bi = d_bi[tgt];
    wire         sd_lx = d_lx[tgt];
    wire         sd_gp0 = d_gp0[tgt];
    // (perf/retime, 2026-10-13) the target's fields latched as its setup leaves KS_IDLE, used by the later
    // KS states and the POC reads: kb -> tgt -> d_*[tgt] -> the weights was a census cluster on every seed.
    // Equivalent: the target is one bank for the whole sequence (k starts only once sdone is set; k's
    // return to idle flips kb, so tgt still names the same bank) and a claimed bank's descriptor holds
    logic [4:0]  ls_gref0, ls_gref1;
    logic        ls_bi, ls_gp0, ls_c;

    // fetch bookkeeping
    logic [4:0]  req_row;                  // next row to request
    logic [2:0]  rx_word;                  // word within the row
    // SIXTEEN row buffers: sixteen reference rows in flight (the fetch is DDR3-latency
    // bound: two in flight left it waiting on each round trip; four -> eight -> sixteen
    // took The Office Disc 01's window from 2,237 to 1,974 to 1,907 cycles a macroblock,
    // docs/h264_recon.md S6). Sixteen rows of <= 4 words fill dpb_mem's 64-beat read
    // buffer exactly; a luma window has at most 21 rows.
    // (the row buffers are eight byte-lane LUT-RAMs, below the copy: 1,024 registers and a
    // word / byte selection per copied byte as a register file)
    logic [15:0] rb_full;                  // a row buffer holds a complete row
    logic [4:0]  cp_row;                   // row being copied
    logic [4:0]  cp_col;
    logic [8:0]  cp_base;                  // window RAM address of row cp_row

    logic [8:0]  w_first_q;                // the (per-window constant) first word
    logic [8:0]  w_last_q;                 // ... and last (P5b: row_len_q a state later)
    logic [3:0]  row_len_q;
    logic [11:0] xs_q;                     // unclamped window start column (as 16-bit signed)
    logic signed [15:0] xi_q;
    logic [11:0] pw_q;
    logic [4:0]  ww_q, wh_q, ws_q, r0_q;
    logic [8:0]  wst_q;
    // ---- the fetch in three sides (P5b 4c': the requests run ahead into the next item) ----
    // REQUEST (st): walks the items, computes each window's geometry, issues its row
    // commands and pushes the item into a two-entry queue as its requests start, then goes
    // straight on to the next item -- bounded by the queue and by the sixteen row buffers
    // (rows requested but not yet copied < 16), NOT by the copy of the item before. Before
    // this, every item waited for the previous window to arrive and be copied, so each paid
    // a full DDR round trip: 245 of I_FETCH's 404 cycles a macroblock (docs/throughput.md).
    // RECEIVE: the beats of the queue's items in order into the row buffers (a ring, indexed
    // by the global row count). COPY: claims a free window bank for the queue's oldest item
    // (the descriptor and bank_rows: the interpolation side may start) and copies its rows,
    // then pops it. Each side latches the geometry it needs at its item's start, so the
    // queue adds no mux on the copy's retimed address path. The row buffers' correctness is
    // their full flags (a beat waits for its buffer, the copy for its row); the sixteen-row
    // bound only keeps the requests from running further ahead than the ring (and dpb_mem's
    // read credit bounds the beats in flight regardless): a bound of 17 is not a defect.
    logic [1:0]  n_push, n_rxd, n_cpd;     // items pushed / fully received / fully copied (mod 4)
    logic [4:0]  rq_seq, cp_seq;           // rows requested / copied, all items (mod 32)
    logic [4:0]  rx_seq;                   // rows received, all items
    // the queue (two entries, index = the count's low bit)
    logic [4:0]  q_wh [0:1], q_ww [0:1], q_ws [0:1], q_r0 [0:1];
    logic [8:0]  q_wst [0:1];
    logic [3:0]  q_len [0:1];
    logic signed [15:0] q_xi [0:1];
    logic [11:0] q_pw [0:1];
    logic [8:0]  q_wf [0:1];
    logic [1:0]  q_plane [0:1];
    logic [2:0]  q_fx [0:1], q_fy [0:1];
    logic [4:0]  q_bw [0:1], q_bh [0:1], q_gx [0:1], q_gy [0:1], q_gref0 [0:1], q_gref1 [0:1];
    logic        q_bi [0:1], q_lx [0:1], q_gp0 [0:1];
    // receive: the item being received (valid while n_rxd != n_push)
    wire         x_act = (n_rxd != n_push);
    wire  [4:0]  x_wh  = q_wh[n_rxd[0]];
    wire  [3:0]  x_len = q_len[n_rxd[0]];
    logic [4:0]  x_row;                    // row within the item
    // copy: the item being copied, its geometry latched at its claim
    logic        c_act;
    logic [4:0]  c_wh, c_ww, c_ws;
    logic signed [15:0] c_xi;
    logic [11:0] c_pw;
    logic [8:0]  c_wf;
    assign rd_ready = x_act && !rb_full[rx_seq[3:0]];


    // ---- the group being predicted --------------------------------------------------------
    logic [3:0]  g_blk;                    // its first 4x4 block (luma4x4BlkIdx)
    logic [4:0]  g_x, g_y, g_w, g_h;       // luma rectangle in the macroblock
    logic [1:0]  g_q;                      // quadrant being walked
    logic [2:0]  g_sub;                    // block inside the quadrant (4 = quadrant done)
    logic [1:0]  plane;                    // 0 Y, 1 Cb, 2 Cr
    logic        lx;                       // the list being fetched
    logic        g_bi;
    // block (x, y) of luma4x4BlkIdx b (6.4.3): x = {b[2], b[0]} * 4, y = {b[3], b[1]} * 4

    // the group's first block: its record is read the cycle g_blk is set (I_GROUP addresses
    // the RAM with the value it registers) and holds while the group is predicted
    logic [3:0]  g_blk_n;
    always_comb begin
        if (all16) g_blk_n = 4'd0;
        else if (all8[g_q]) g_blk_n = {g_q, 2'b00};
        else g_blk_n = {g_q, g_sub[1:0]};
    end
    assign mot_ra = (st == I_GROUP) ? g_blk_n : g_blk;
    // the group's motion for list lx
    wire        gp0 = mot_q[0], gp1 = mot_q[46];
    wire [4:0]  gref0 = mot_q[5:1], gref1 = mot_q[51:47];
    // the vectors and codes from a copy of the record a cycle behind the RAM (P5b: the RAM's
    // clock-to-out into the window geometry of I_LIST was ~10 ns); the record holds for the
    // whole group and I_LIST comes two states after I_GROUP addresses it
    logic [91:0] mot_qq;
    always_ff @(posedge clk) mot_qq <= mot_q;
    wire signed [15:0] gmvx = lx ? mot_qq[75:60] : mot_qq[29:14];
    wire signed [15:0] gmvy = lx ? mot_qq[91:76] : mot_qq[45:30];
    wire [7:0]  gcode = lx ? mot_qq[59:52] : mot_qq[13:6];   // {valid, store[4:0], parity[1:0]}

    assign poc_ra0 = ls_gref0;             // the item being set up (read from KS_WT_RD2 on,
    assign poc_ra1 = ls_gref1;             // >= 2 cycles after its setup starts; its bank claimed)

    // ---- window geometry ------------------------------------------------------------------
    wire        is_c = (plane != 2'd0);
    // the chroma vector's vertical component (Table 8-10)
    logic signed [15:0] cmvy;
    always_comb begin
        cmvy = gmvy;
        if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy + 16'sd2;     // ref top, current bottom
        if (field_pic && gcode[1:0] == 2'd2 && !bottom) cmvy = gmvy - 16'sd2;     // ref bottom, current top
    end
    // integer sample position and fraction
    // Phase 5c part 2 (docs/mb_pipeline.md S4k): the window keeps its layout (luma (w+5)
    // columns from (xInt-2, yInt-2), chroma (w+1) from (xInt, yInt): mc_interp's addressing),
    // but only the rectangle mc_interp's sweep reads for the item's position class is FETCHED
    // and COPIED -- luma columns 2..w+1 unless the x fraction is nonzero (then 0..w+4), rows
    // 2..h+1 unless the y fraction is (then 0..h+4); chroma columns 0..w-1 (+1 for a nonzero x
    // fraction), rows 0..h-1 (+1). A full-sample 16x16 item was 21 x 21 bytes for 16 x 16 used.
    // xi / yi / ww / wh are that rectangle; ws the window's stride, wst the rectangle's first
    // window address, r0 its first row (the rows above it count as present: never read)
    logic signed [15:0] xi, yi;
    logic [2:0]  fx, fy;
    logic [4:0]  ww, wh;                   // the rectangle fetched and copied
    logic [4:0]  ws;                       // the window's stride (its full width)
    logic [8:0]  wst;                      // the rectangle's first window address
    logic [4:0]  r0;                       // ... its first window row
    logic [4:0]  bw, bh;                   // prediction block size in this plane
    logic [11:0] pw, ph;                   // reference plane size
    always_comb begin
        logic xnz, ynz;
        if (!is_c) begin
            xnz = (gmvx[1:0] != 2'd0); ynz = (gmvy[1:0] != 2'd0);
            xi = $signed({2'b0, mb_x, 4'b0}) + $signed({11'b0, g_x}) + (gmvx >>> 2) - (xnz ? 16'sd2 : 16'sd0);
            yi = $signed({2'b0, mb_y, 4'b0}) + $signed({11'b0, g_y}) + (gmvy >>> 2) - (ynz ? 16'sd2 : 16'sd0);
            fx = {1'b0, gmvx[1:0]}; fy = {1'b0, gmvy[1:0]};
            bw = g_w; bh = g_h;
            ws = g_w + 5'd5;
            ww = xnz ? g_w + 5'd5 : g_w; wh = ynz ? g_h + 5'd5 : g_h;
            r0 = ynz ? 5'd0 : 5'd2;
            wst = (ynz ? 9'd0 : {3'd0, ws, 1'b0}) + (xnz ? 9'd0 : 9'd2);
            pw = {width_mbs, 4'b0};
            ph = (gcode[1:0] == 2'd0) ? {frame_height_mbs, 4'b0} : {1'b0, frame_height_mbs, 3'b0};
        end else begin
            xnz = (gmvx[2:0] != 3'd0); ynz = (cmvy[2:0] != 3'd0);
            xi = $signed({3'b0, mb_x, 3'b0}) + $signed({12'b0, g_x[4:1]}) + (gmvx >>> 3);
            yi = $signed({3'b0, mb_y, 3'b0}) + $signed({12'b0, g_y[4:1]}) + (cmvy >>> 3);
            fx = gmvx[2:0]; fy = cmvy[2:0];
            bw = {1'b0, g_w[4:1]}; bh = {1'b0, g_h[4:1]};
            ws = {1'b0, g_w[4:1]} + 5'd1;
            ww = {1'b0, g_w[4:1]} + {4'd0, xnz}; wh = {1'b0, g_h[4:1]} + {4'd0, ynz};
            r0 = 5'd0; wst = 9'd0;
            pw = {1'b0, width_mbs, 3'b0};
            ph = (gcode[1:0] == 2'd0) ? {1'b0, frame_height_mbs, 3'b0} : {2'b0, frame_height_mbs, 2'b0};
        end
    end
    // the clamped column span of the window, in 64-bit words
    // (from the registered xi_q / ww_q / pw_q: computed in I_LIST2)
    wire signed [15:0] x_last = xi_q + $signed({11'b0, ww_q}) - 16'sd1;
    wire [11:0] xs_c = (xi_q < 0) ? 12'd0 : (xi_q >= $signed({4'b0, pw_q})) ? pw_q - 12'd1 : xi_q[11:0];
    wire [11:0] xe_c = (x_last < 0) ? 12'd0 : (x_last >= $signed({4'b0, pw_q})) ? pw_q - 12'd1 : x_last[11:0];
    wire [8:0]  w_first = xs_c[11:3];
    wire [8:0]  w_lastw = xe_c[11:3];

    // the store rows of the window: row r is picture row clamp(yi + r) (T: 2r, B: 2r + 1 in
    // the frame store), word address base + srow * stride. Built over I_LIST .. I_LIST4 from
    // registered geometry (the motion RAM's output -> clamp -> multiply -> adds was one
    // 17.8 ns cycle); each request then steps by the row stride while the clamped row still
    // advances (addr_cur, y_cur)
    logic signed [15:0] yi_q, y_cur;
    logic [11:0] ph_q;
    logic [7:0]  gcode_q;
    logic [28:0] base_q, addr_cur;
    logic [12:0] srow0_q;
    logic [8:0]  stride_q;
    logic [9:0]  rstep_q;
    wire  [11:0] y0_c = (yi_q < 0) ? 12'd0 : (yi_q >= $signed({4'b0, ph_q})) ? ph_q - 12'd1 : yi_q[11:0];
    wire  [28:0] plane_off = (plane == 2'd0) ? 29'd0 :
                             (plane == 2'd1) ? {3'd0, plane_mbs, 5'd0} : ({3'd0, plane_mbs, 5'd0} + {5'd0, plane_mbs, 3'd0});
    wire  [8:0]  stride = is_c ? {1'b0, width_mbs} : {width_mbs, 1'b0};
    wire         y_adv = (y_cur >= 0) && (y_cur < $signed({4'b0, ph_q}) - 16'sd1);

    // ---- the window RAM, mc_interp and wpred: two lanes (P5b 4b) -------------------------------
    // A partition 8 or more samples wide in its plane (luma 16 / 8, chroma 8) is interpolated
    // by TWO lanes, each an mc_interp over half its columns -- lane 1 from column bw/2 of the
    // SAME window (the whole window's stride, col_off) -- each with its own copy of the window
    // RAM (the copy writes both), its own list-0 buffer and prefetch and its own wpred: two
    // samples a cycle. A narrower one (luma 4, chroma 4 / 2) runs on lane 0 alone: splitting
    // it would buy ~12 cycles and make 2-sample segments. Each lane gathers its row segment
    // (4 or 8 samples: always inside one 64-bit word of the sample RAM) and hands it over as
    // one byte-enabled word write; the two share the RAM's port through a one-deep pending
    // register each -- segments are >= 4 cycles apart per lane, so <= 2 writes per 4 cycles.
    // The window RAM: four byte-wide lanes (address mod 4) -- the copy writes four consecutive
    // window bytes a cycle (docs/h264_recon.md S6), mc_interp reads one a cycle with a
    // one-cycle latency; each holds two windows (the fetch writes bank fb, the lanes read kb).
    logic [3:0]  wb_we;                    // per byte lane
    logic [7:0]  wb_addr [0:3];            // {bank, word}
    logic [7:0]  wb_data [0:3];
    wire         k_split  = (kd_bw >= 5'd8);
    wire  [4:0]  k_lw     = k_split ? {1'b0, kd_bw[4:1]} : kd_bw;     // a lane's width
    wire  [4:0]  k_stride = kd_c ? kd_bw + 5'd1 : kd_bw + 5'd5;       // the whole window's
    // (perf/retime, 2026-10-13) each bank's lane sample count (lane width x height), registered from
    // the bank's own descriptor -- the push took the product behind the kb select in one cycle. A
    // descriptor is filled (d_*[fb]) long before its item starts, so the register's cycle never shows
    logic [8:0]  bank_n [0:1];
    always_ff @(posedge clk)
        for (int b = 0; b < 2; b++)
            bank_n[b] <= {4'd0, (d_bw[b] >= 5'd8) ? {1'b0, d_bw[b][4:1]} : d_bw[b]} * {4'd0, d_bh[b]};
    logic        mc_start;
    logic        mc_kind;                  // the item mc_start starts: 0 list 0 of a bi-predicted group
                                           // (into pbuf), 1 the last list (through wpred)
    logic        pbb;                      // the pbuf bank of the bi-predicted group being started
    logic [1:0]  mc_valid, mc_last, mc_ready, mc_busy, mc_rdy, mc_rdn;
    logic [7:0]  mc_pred [0:1];
    // S4k: the reader (the K FSM) moves to the next item once the lanes' reads are issued; each
    // lane's WRITER takes the item's samples out of mc_interp -- into pbuf, or through wpred
    // into the row segments -- from a two-entry queue of descriptors pushed as the lanes start
    logic [1:0]  wr_cnt0;                  // (lane 0's queue count, for the K FSM and I_DRAIN)
    logic [1:0]  wr_cnt1;
    wire         lanes_ok = mc_rdy[0] && wr_cnt0 != 2'd2 && (!k_split || (mc_rdy[1] && wr_cnt1 != 2'd2));
    wire         lanes_rd = mc_rdn[0] && (!k_split || mc_rdn[1]);
    // weighting: the weights are computed per item by the K FSM and travel in the descriptor
    logic [1:0]  wp_busy, wp_a_valid, wp_a_ready, wp_b_valid, wp_b_ready, wp_valid, wp_last;
    logic [7:0]  wp_out [0:1];
    logic [1:0]  wp_mode;
    logic [2:0]  wp_logwd;
    logic signed [8:0] wp_w0, wp_w1;
    // the addressed entry's weight and offset for the item's plane (17 bits a plane: a case,
    // not an index times 17 -- CLAUDE.md, the barrel shifter)
    logic signed [8:0] wt_w;
    logic signed [7:0] wt_o;
    always_comb begin
        case (sd_plane)
            2'd1:    begin wt_w = wt_data[25:17]; wt_o = wt_data[33:26]; end
            2'd2:    begin wt_w = wt_data[42:34]; wt_o = wt_data[50:43]; end
            default: begin wt_w = wt_data[8:0];   wt_o = wt_data[16:9];  end
        endcase
    end
    logic signed [7:0] wp_o0, wp_o1;
    // a lane's completed row segment (combinational, the cycle its last sample leaves wpred)
    logic [1:0]  seg_ev;
    logic [5:0]  seg_word [0:1];
    logic [7:0]  seg_be [0:1];
    logic [63:0] seg_data [0:1];
    genvar ln;
    generate for (ln = 0; ln < 2; ln++) begin : LN
        // the lane's copy of the window
        logic [7:0] w0 [0:255];
        logic [7:0] w1 [0:255];
        logic [7:0] w2 [0:255];
        logic [7:0] w3 [0:255];
        logic [8:0] raddr;
        logic [7:0] wq [0:3];
        logic [1:0] wq_sel;
        always_ff @(posedge clk) begin
            if (wb_we[0]) w0[wb_addr[0]] <= wb_data[0];
            if (wb_we[1]) w1[wb_addr[1]] <= wb_data[1];
            if (wb_we[2]) w2[wb_addr[2]] <= wb_data[2];
            if (wb_we[3]) w3[wb_addr[3]] <= wb_data[3];
            wq[0] <= w0[{kb, raddr[8:2]}];
            wq[1] <= w1[{kb, raddr[8:2]}];
            wq[2] <= w2[{kb, raddr[8:2]}];
            wq[3] <= w3[{kb, raddr[8:2]}];
            wq_sel <= raddr[1:0];
        end
        mc_interp u_mc (
            .clk(clk), .rst_n(rst_n), .start(mc_start && (ln == 0 || k_split)), .is_chroma(kd_c),
            .frac_x(kd_fx), .frac_y(kd_fy), .w(k_lw), .h(kd_bh),
            .win_addr(raddr), .win_data(wq[wq_sel]), .rows_avail(bank_rows[kb]),
            .win_stride(k_stride), .col_off(ln == 0 ? 5'd0 : k_lw),
            .pred_valid(mc_valid[ln]), .pred(mc_pred[ln]), .pred_last(mc_last[ln]), .pred_ready(mc_ready[ln]),
            .busy(mc_busy[ln]), .ready(mc_rdy[ln]), .rd_done(mc_rdn[ln]));
        // ---- the writer: its items in the order the lane started them --------------------------
        // The descriptor: the route (0 list 0 of a bi-predicted group into pbuf, 1 the last
        // list through wpred), the pbuf bank, wpred's parameters and sample count, the
        // segment geometry. Pushed the cycle mc_start reaches the lane (kd_* and the weights
        // hold then); the head pops at its last sample into pbuf, or its last result out of wpred
        logic        q_kind [0:1], q_bi2 [0:1], q_pb [0:1], q_c [0:1];
        logic [1:0]  q_mode [0:1], q_pl [0:1];
        logic [2:0]  q_lwd [0:1];
        logic signed [8:0] q_w0 [0:1], q_w1 [0:1];
        logic signed [7:0] q_o0 [0:1], q_o1 [0:1];
        logic [8:0]  q_n [0:1];
        logic [4:0]  q_gx2 [0:1], q_gy2 [0:1], q_off [0:1], q_klw [0:1];
        logic        hd, tl;                   // the queue's head / tail
        logic [1:0]  wcnt;
        logic        wrun;                     // the head (a wpred item) has started its wpred
        wire         hv    = (wcnt != 2'd0);
        wire         h_wp  = hv && q_kind[hd];
        wire         h_bi  = q_bi2[hd];
        wire         h_pb  = q_pb[hd];
        wire  [8:0]  h_n   = q_n[hd];
        wire  [4:0]  h_klw = q_klw[hd];
        wire         push  = mc_start && (ln == 0 || k_split);
        wire         wp_go = h_wp && !wrun && !wp_busy[ln];
        // list 0 of a bi-predicted group (the head, route 0); the LAST list's interpolation
        // streams straight into wpred (the weighting folded into it, no second pass over a
        // buffer), list 0's buffered samples joining through a prefetch: pbuf read in order
        // (pb_ridx registered, pb_q the edge after), up to four samples held or in flight
        // ahead of wpred's take. TWO pbuf banks (S4k): a group's list 1 reads one while the
        // next group's list 0 may write the other
        logic [7:0] pbuf [0:511];
        logic [7:0] pb_widx, pb_ridx, pb_q;
        wire        pb_we = hv && !q_kind[hd] && mc_valid[ln];          // mc_ready is 1 there
        always_ff @(posedge clk) begin
            if (pb_we) pbuf[{h_pb, pb_widx}] <= mc_pred[ln];
            pb_q <= pbuf[{h_pb, pb_ridx}];
        end
        logic [7:0] pf [0:3];
        logic [1:0] pf_h, pf_t;
        logic [2:0] pf_n;
        logic       pf_i1, pf_i2;
        logic [8:0] pf_rd;
        wpred u_wp (
            .clk(clk), .rst_n(rst_n), .start(wp_go), .bi(h_bi), .mode(q_mode[hd]),
            .logwd(q_lwd[hd]), .w0(q_w0[hd]), .w1(q_w1[hd]), .o0(q_o0[hd]), .o1(q_o1[hd]), .n(h_n),
            .a_valid(wp_a_valid[ln]), .a(h_bi ? pf[pf_h] : mc_pred[ln]), .a_ready(wp_a_ready[ln]),
            .b_valid(wp_b_valid[ln]), .b(mc_pred[ln]), .b_ready(wp_b_ready[ln]),
            .out_valid(wp_valid[ln]), .out(wp_out[ln]), .out_last(wp_last[ln]), .out_ready(1'b1), .busy(wp_busy[ln]));
        wire         wt_st = h_wp && wrun;
        assign wp_a_valid[ln] = wt_st && (h_bi ? (pf_n != 3'd0) : mc_valid[ln]);
        assign wp_b_valid[ln] = wt_st && h_bi && mc_valid[ln];
        assign mc_ready[ln]   = !hv ? 1'b0 : !q_kind[hd] ? 1'b1 : !wrun ? 1'b0 : (h_bi ? wp_b_ready[ln] : wp_a_ready[ln]);
        wire         pop   = (hv && !q_kind[hd] && mc_valid[ln] && mc_last[ln]) || (wt_st && wp_valid[ln] && wp_last[ln]);
        // the results, raster over the lane's columns, gathered a row segment at a time
        logic [4:0]  wo_x, wo_y;
        logic [63:0] sd;
        logic [7:0]  sbe;
        logic [4:0]  ox, oy;
        always_comb begin
            ox = q_gx2[hd] + q_off[hd] + wo_x;
            oy = q_gy2[hd] + wo_y;
            case (q_pl[hd])
                2'd0:    seg_word[ln] = {1'b0, oy[3:0], ox[3]};
                2'd1:    seg_word[ln] = 6'd32 + {3'd0, oy[2:0]};
                default: seg_word[ln] = 6'd40 + {3'd0, oy[2:0]};
            endcase
            seg_be[ln]   = sbe;
            seg_data[ln] = sd;
            case (ox[2:0])
                3'd0: begin seg_be[ln][0] = 1'b1; seg_data[ln][7:0]   = wp_out[ln]; end
                3'd1: begin seg_be[ln][1] = 1'b1; seg_data[ln][15:8]  = wp_out[ln]; end
                3'd2: begin seg_be[ln][2] = 1'b1; seg_data[ln][23:16] = wp_out[ln]; end
                3'd3: begin seg_be[ln][3] = 1'b1; seg_data[ln][31:24] = wp_out[ln]; end
                3'd4: begin seg_be[ln][4] = 1'b1; seg_data[ln][39:32] = wp_out[ln]; end
                3'd5: begin seg_be[ln][5] = 1'b1; seg_data[ln][47:40] = wp_out[ln]; end
                3'd6: begin seg_be[ln][6] = 1'b1; seg_data[ln][55:48] = wp_out[ln]; end
                default: begin seg_be[ln][7] = 1'b1; seg_data[ln][63:56] = wp_out[ln]; end
            endcase
            seg_ev[ln] = wp_valid[ln] && (wo_x == h_klw - 5'd1);
        end
        if (ln == 0) begin : C0 assign wr_cnt0 = wcnt; end
        else begin : C1 assign wr_cnt1 = wcnt; end
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                pb_widx <= '0; pb_ridx <= '0; pf_h <= '0; pf_t <= '0; pf_n <= '0; pf_i1 <= 1'b0; pf_i2 <= 1'b0;
                pf_rd <= '0; wo_x <= '0; wo_y <= '0; sd <= '0; sbe <= '0;
                hd <= 1'b0; tl <= 1'b0; wcnt <= '0; wrun <= 1'b0;
                for (int e = 0; e < 2; e++) begin
                    q_kind[e] <= 1'b0; q_bi2[e] <= 1'b0; q_pb[e] <= 1'b0; q_c[e] <= 1'b0; q_mode[e] <= '0; q_pl[e] <= '0;
                    q_lwd[e] <= '0; q_w0[e] <= '0; q_w1[e] <= '0; q_o0[e] <= '0; q_o1[e] <= '0; q_n[e] <= '0;
                    q_gx2[e] <= '0; q_gy2[e] <= '0; q_off[e] <= '0; q_klw[e] <= '0;
                end
            end else begin
                if (push) begin
                    // this lane's sample count: 4..256 (a product of powers of two)
                    q_kind[tl] <= mc_kind; q_bi2[tl] <= kd_bi; q_pb[tl] <= pbb; q_c[tl] <= kd_c;
                    q_mode[tl] <= wp_mode; q_lwd[tl] <= wp_logwd; q_w0[tl] <= wp_w0; q_w1[tl] <= wp_w1;
                    q_o0[tl] <= wp_o0; q_o1[tl] <= wp_o1;
                    q_n[tl] <= bank_n[kb];
                    q_pl[tl] <= kd_plane;
                    q_gx2[tl] <= kd_c ? {1'b0, kd_gx[4:1]} : kd_gx; q_gy2[tl] <= kd_c ? {1'b0, kd_gy[4:1]} : kd_gy;
                    q_off[tl] <= (ln == 0) ? 5'd0 : k_lw; q_klw[tl] <= k_lw;
                    tl <= !tl;
                end
                wcnt <= wcnt + {1'b0, push} - {1'b0, pop};
                if (pop) begin hd <= !hd; wrun <= 1'b0; end
                if (pb_we) pb_widx <= (mc_last[ln]) ? 8'd0 : pb_widx + 1'b1;
                if (wp_go) begin
                    // the head's wpred starts: its prefetch and its segments from the start
                    wrun <= 1'b1;
                    pf_h <= '0; pf_t <= '0; pf_n <= '0; pf_i1 <= 1'b0; pf_i2 <= 1'b0; pf_rd <= '0;
                    wo_x <= '0; wo_y <= '0; sbe <= '0;
                end
                if (wt_st) begin
                    // bi: list 0's samples prefetched from pbuf (address, then data an edge
                    // later, then into the FIFO), taken with list 1's by wpred
                    logic issue;
                    issue = h_bi && (pf_rd < h_n) && ({1'b0, pf_n} + {3'd0, pf_i1} + {3'd0, pf_i2} < 4'd4);
                    if (issue) begin pb_ridx <= pf_rd[7:0]; pf_rd <= pf_rd + 1'b1; end
                    pf_i1 <= issue; pf_i2 <= pf_i1;
                    if (pf_i2) begin pf[pf_t] <= pb_q; pf_t <= pf_t + 1'b1; end
                    pf_n <= pf_n + {2'd0, pf_i2} - {2'd0, h_bi && wp_a_ready[ln]};
                    if (h_bi && wp_a_ready[ln]) pf_h <= pf_h + 1'b1;
                end
                if (wp_valid[ln]) begin
                    if (seg_ev[ln]) begin sbe <= '0; wo_x <= '0; wo_y <= wo_y + 1'b1; end
                    else begin sd <= seg_data[ln]; sbe <= seg_be[ln]; wo_x <= wo_x + 1'b1; end
                end
            end
        end
    end endgenerate
    // the segments into the sample RAM's one port: lane 0 first, lane 1 at most a cycle later
    logic [1:0]  pend_v;
    logic [5:0]  pend_word [0:1];
    logic [7:0]  pend_be [0:1];
    logic [63:0] pend_data [0:1];

    // implicit weights (8.4.3): DistScaleFactor from the two references' POCs
    logic        ds_start, ds_done, ds_zero;
    logic signed [10:0] ds_dsf;
    logic signed [31:0] ds_b, ds_d;
    dsf_calc u_ds (.clk(clk), .rst_n(rst_n), .start(ds_start), .diff_b(ds_b), .diff_d(ds_d),
                   .done(ds_done), .dsf(ds_dsf), .td_zero(ds_zero));
    logic signed [8:0] imp_w0, imp_w1;


    // the copy, two stages: (1) window columns cp_col .. cp_col + 3 of the row being copied,
    // clamped to the picture (8.4.2.2's Clip3), with where they land (a = cp_base + cp_col,
    // bank (a + k) mod 4); (2) their bytes from the row buffer into the window banks. The
    // row buffer stage 2 reads is refilled no earlier than the edge that ends stage 2.
    logic [11:0] cp_xc [0:3];
    logic [8:0]  cp_a;
    logic [4:0]  cp_n;                     // bytes this cycle (1..4)
    always_comb begin
        for (int k = 0; k < 4; k++) begin
            logic signed [15:0] xu;
            xu = c_xi + $signed({11'b0, cp_col}) + k;
            cp_xc[k] = (xu < 0) ? 12'd0 : (xu >= $signed({4'b0, c_pw})) ? c_pw - 12'd1 : xu[11:0];
        end
        cp_a = cp_base + {4'd0, cp_col};
        cp_n = (c_ww - cp_col > 5'd4) ? 5'd4 : c_ww - cp_col;
    end
    // stage 0 (P5b): the step's columns registered before the lane addresses are formed
    // (cp_col -> clamp -> lane match -> the lane RAMs' address registers was 11.6 ns)
    logic        x0_v;
    logic [4:0]  x0_row;
    logic        x0_fb;
    logic [11:0] x0_xc [0:3];
    logic [8:0]  x0_a;
    logic [4:0]  x0_n;
    logic        x0_clr;                   // x0_row's last step: its buffer is freed a stage late
    logic        c1_v;
    logic        c1_clr;                   // stage 1 holds a row's last step
    logic        w2_clr;                   // ... stage 2 (the lane writes this cycle): the row is in
    logic        w2_fb;
    logic [3:0]  c1_rb;
    logic        c1_fb;                    // the bank stage 1 copied for
    logic [11:0] c1_xc [0:3];
    logic [8:0]  c1_a;
    logic [4:0]  c1_n;
    logic [7:0]  cp_byte [0:3];
    // the row buffers as byte lanes: lane L holds byte L of every word (64 words: 16 rows x 4).
    // The four columns a copy step takes sit in four different lanes (consecutive samples,
    // or one sample repeated where clamped -- the same lane and address), so each lane is
    // read once, addressed in stage 1 and landing for stage 2 (a received word writes all
    // eight lanes; its buffer is refilled no earlier than the edge after that read)
    logic [5:0]  ln_addr [0:7];
    logic [7:0]  lane_q [0:7];
    always_comb begin
        for (int l = 0; l < 8; l++) begin
            ln_addr[l] = {x0_row[3:0], 2'd0};
            for (int k = 0; k < 4; k++) begin
                logic [8:0] xw;
                xw = x0_xc[k][11:3] - c_wf;    // (the item's: stage 0 holds its last step
                                               // while the copy pops it -- the next claim is a
                                               // cycle later, so c_wf has not moved yet)
                if (x0_xc[k][2:0] == l[2:0]) ln_addr[l] = {x0_row[3:0], xw[1:0]};
            end
        end
    end
    wire         rx_we = rd_valid && rd_ready;
    genvar gl;
    generate for (gl = 0; gl < 8; gl++) begin : RL
        logic [7:0] m [0:63];
        always_ff @(posedge clk) begin
            if (rx_we) m[{rx_seq[3:0], rx_word[1:0]}] <= rd_data[8*gl +: 8];
            lane_q[gl] <= m[ln_addr[gl]];
        end
    end endgenerate
    always_comb for (int k = 0; k < 4; k++) cp_byte[k] = lane_q[c1_xc[k][2:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= I_IDLE; busy <= 1'b0; done <= 1'b0; err <= 1'b0;
            g_blk <= '0; g_x <= '0; g_y <= '0; g_w <= '0; g_h <= '0; g_q <= '0; g_sub <= '0;
            plane <= '0; lx <= 1'b0; g_bi <= 1'b0;
            k <= K_IDLE; ks <= KS_IDLE; sdone <= 1'b0; ls_gref0 <= '0; ls_gref1 <= '0; ls_bi <= 1'b0; ls_gp0 <= 1'b0; ls_c <= 1'b0; s_kind <= 1'b0; bank_full <= '0; fb <= 1'b0; kb <= 1'b0; c1_fb <= 1'b0;
            bank_rows[0] <= '0; bank_rows[1] <= '0; c1_clr <= 1'b0; w2_clr <= 1'b0; w2_fb <= 1'b0;
            for (int b = 0; b < 2; b++) begin
                d_plane[b] <= '0; d_fx[b] <= '0; d_fy[b] <= '0; d_bw[b] <= '0; d_bh[b] <= '0; d_gx[b] <= '0; d_gy[b] <= '0;
                d_gref0[b] <= '0; d_gref1[b] <= '0; d_bi[b] <= 1'b0; d_lx[b] <= 1'b0; d_gp0[b] <= 1'b0;
            end
            cmd_valid <= 1'b0; cmd_addr <= '0; cmd_len <= 4'd1; cp_base <= '0;
            out_we <= 1'b0; out_word <= '0; out_be <= '0; out_wdata <= '0;
            pend_v <= '0; mc_kind <= 1'b0; pbb <= 1'b0;
            for (int b = 0; b < 2; b++) begin pend_word[b] <= '0; pend_be[b] <= '0; pend_data[b] <= '0; end
            wb_we <= '0; for (int b = 0; b < 4; b++) begin wb_addr[b] <= '0; wb_data[b] <= '0; end
            mc_start <= 1'b0;
            wp_mode <= '0; wp_logwd <= '0; wp_w0 <= '0; wp_w1 <= '0; wp_o0 <= '0; wp_o1 <= '0;
            wt_addr <= '0;
            ds_start <= 1'b0; ds_b <= '0; ds_d <= '0; imp_w0 <= 9'sd32; imp_w1 <= 9'sd32;
            req_row <= '0; rx_word <= '0; rb_full <= '0; cp_row <= '0; cp_col <= '0;
            n_push <= '0; n_rxd <= '0; n_cpd <= '0; rq_seq <= '0; cp_seq <= '0; rx_seq <= '0; x_row <= '0;
            c_act <= 1'b0; c_wh <= '0; c_ww <= '0; c_ws <= '0; c_xi <= '0; c_pw <= '0; c_wf <= '0;
            for (int b = 0; b < 2; b++) begin
                q_wh[b] <= '0; q_ww[b] <= '0; q_ws[b] <= '0; q_r0[b] <= '0; q_wst[b] <= '0; q_len[b] <= 4'd1; q_xi[b] <= '0; q_pw[b] <= '0; q_wf[b] <= '0;
                q_plane[b] <= '0; q_fx[b] <= '0; q_fy[b] <= '0; q_bw[b] <= '0; q_bh[b] <= '0; q_gx[b] <= '0; q_gy[b] <= '0;
                q_gref0[b] <= '0; q_gref1[b] <= '0; q_bi[b] <= 1'b0; q_lx[b] <= 1'b0; q_gp0[b] <= 1'b0;
            end
            w_first_q <= '0; w_last_q <= '0; row_len_q <= 4'd1; xs_q <= '0; xi_q <= '0; pw_q <= '0; ww_q <= '0; wh_q <= '0; ws_q <= '0; r0_q <= '0; wst_q <= '0;
            yi_q <= '0; y_cur <= '0; ph_q <= '0; gcode_q <= '0; base_q <= '0; addr_cur <= '0; srow0_q <= '0;
            stride_q <= '0; rstep_q <= '0; c1_v <= 1'b0; c1_rb <= 4'd0; c1_a <= '0; c1_n <= '0;
            for (int k = 0; k < 4; k++) c1_xc[k] <= '0;
            x0_v <= 1'b0; x0_row <= '0; x0_fb <= 1'b0; x0_a <= '0; x0_n <= '0; x0_clr <= 1'b0;
            for (int k = 0; k < 4; k++) x0_xc[k] <= '0;
        end else begin
            done <= 1'b0; err <= 1'b0; mc_start <= 1'b0; ds_start <= 1'b0;
            out_we <= 1'b0; wb_we <= '0; c1_v <= 1'b0; x0_v <= 1'b0; x0_clr <= 1'b0;
            // the copy's stage 1: the lane RAMs are read at x0's addresses (above); the step
            // moves on to stage 2 with them, and a row's last step frees its buffer now
            if (x0_v) begin
                c1_v <= 1'b1; c1_rb <= x0_row[3:0]; c1_fb <= x0_fb; c1_a <= x0_a; c1_n <= x0_n; c1_clr <= x0_clr;
                for (int k = 0; k < 4; k++) c1_xc[k] <= x0_xc[k];
                if (x0_clr) rb_full[x0_row[3:0]] <= 1'b0;
            end
            // the rows written: counted on the edge a row's last lane writes land (wb_we, set
            // by stage 2 below, writes the edge after), in the bank the copy carried
            w2_clr <= c1_v && c1_clr; w2_fb <= c1_fb;
            if (w2_clr) bank_rows[w2_fb] <= bank_rows[w2_fb] + 5'd1;
            // the copy's stage 2
            if (c1_v) begin
                for (int b = 0; b < 4; b++) begin
                    logic [1:0] kb;
                    logic [8:0] ab;
                    kb = b[1:0] - c1_a[1:0];
                    ab = c1_a + {7'd0, kb};
                    wb_we[b] <= ({3'd0, kb} < c1_n);
                    wb_addr[b] <= {c1_fb, ab[8:2]};
                    wb_data[b] <= cp_byte[kb];
                end
            end
            if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;
            case (st)
                I_IDLE: if (start) begin
                    busy <= 1'b1;
                    g_q <= 2'd0; g_sub <= 3'd0;
                    st <= I_GROUP;
                end
                // ---- the next group: whole MB, a quadrant, or a 4x4 block ------------------
                I_GROUP: begin
                    g_blk <= g_blk_n;
                    if (all16) begin
                        g_x <= 5'd0; g_y <= 5'd0; g_w <= 5'd16; g_h <= 5'd16;
                        g_q <= 2'd3; g_sub <= 3'd4;          // the last group
                    end else if (all8[g_q]) begin
                        g_x <= {1'b0, g_q[0], 3'b0}; g_y <= {1'b0, g_q[1], 3'b0};
                        g_w <= 5'd8; g_h <= 5'd8; g_sub <= 3'd4;
                    end else begin
                        g_x <= {1'b0, g_q[0], g_sub[0], 2'b00}; g_y <= {1'b0, g_q[1], g_sub[1], 2'b00};
                        g_w <= 5'd4; g_h <= 5'd4; g_sub <= g_sub + 3'd1;
                    end
                    plane <= 2'd0;
                    st <= I_PLANE;
                end
                I_PLANE: begin
                    g_bi <= gp0 && gp1;
                    lx <= gp0 ? 1'b0 : 1'b1;
                    st <= I_LIST;
                end
                // ---- request one list's window ----------------------------------------------
                I_LIST: if (n_push - n_cpd != 2'd2) begin     // a queue entry is free
                    if (!gcode[7]) err <= 1'b1;
                    xi_q <= xi; pw_q <= pw;
                    ww_q <= ww; wh_q <= wh; ws_q <= ws; r0_q <= r0; wst_q <= wst;
                    yi_q <= yi; ph_q <= ph; gcode_q <= gcode;
                    req_row <= '0;
                    st <= I_LIST2;
                end
                I_LIST2: begin
                    w_first_q <= w_first; w_last_q <= w_lastw;
                    base_q <= dpb_base + {6'd0, gcode_q[6:2], 18'd0} + plane_off;   // 2 MiB stores
                    srow0_q <= (gcode_q[1:0] == 2'd0) ? {1'b0, y0_c} : {y0_c, gcode_q[1]};
                    stride_q <= stride;
                    rstep_q <= (gcode_q[1:0] == 2'd0) ? {1'b0, stride} : {stride, 1'b0};
                    st <= I_LIST3;
                end
                I_LIST3: begin
                    base_q <= base_q + {20'd0, w_first_q};
                    row_len_q <= w_last_q[3:0] - w_first_q[3:0] + 4'd1;     // 1..4 words (the clamp,
                                                                              // then this, was 10.1 ns)
                    st <= I_LIST4;
                end
                I_LIST4: begin
                    addr_cur <= base_q + srow0_q * stride_q;
                    y_cur <= yi_q;
                    // the item into the queue (the geometry holds from I_LIST to here)
                    q_wh[n_push[0]] <= wh_q; q_ww[n_push[0]] <= ww_q; q_len[n_push[0]] <= row_len_q;
                    q_ws[n_push[0]] <= ws_q; q_r0[n_push[0]] <= r0_q; q_wst[n_push[0]] <= wst_q;
                    q_xi[n_push[0]] <= xi_q; q_pw[n_push[0]] <= pw_q; q_wf[n_push[0]] <= w_first_q;
                    q_plane[n_push[0]] <= plane; q_fx[n_push[0]] <= fx; q_fy[n_push[0]] <= fy;
                    q_bw[n_push[0]] <= bw; q_bh[n_push[0]] <= bh; q_gx[n_push[0]] <= g_x; q_gy[n_push[0]] <= g_y;
                    q_gref0[n_push[0]] <= gref0; q_gref1[n_push[0]] <= gref1;
                    q_bi[n_push[0]] <= g_bi; q_lx[n_push[0]] <= lx; q_gp0[n_push[0]] <= gp0;
                    n_push <= n_push + 2'd1;
                    st <= I_REQ;
                end
                I_REQ: begin
                    // one row per accepted command, at most sixteen rows requested and not
                    // yet copied (the row buffers), across items (the handshake's accept is
                    // outside the case: the last row's command may still wait as the
                    // request side moves on to the next item)
                    if ((!cmd_valid || cmd_ready) && req_row < wh_q && (rq_seq - cp_seq) < 5'd16) begin
                        cmd_valid <= 1'b1; cmd_addr <= addr_cur; cmd_len <= row_len_q;
                        req_row <= req_row + 1'b1; rq_seq <= rq_seq + 5'd1;
                        addr_cur <= addr_cur + (y_adv ? {19'd0, rstep_q} : 29'd0);
                        y_cur <= y_cur + 16'sd1;
                        // the item's last row requested: the next item (list 1 of a
                        // bi-predicted group, else the next plane) -- its data still arriving
                        if (req_row == wh_q - 5'd1) begin
                            if (g_bi && !lx) begin lx <= 1'b1; st <= I_LIST; end
                            else st <= I_NEXT_PLANE;
                        end
                    end
                end
                I_NEXT_PLANE: begin
                    if (plane == 2'd2) st <= I_NEXT_GROUP;
                    else begin plane <= plane + 1'b1; st <= I_PLANE; end
                end
                I_NEXT_GROUP: begin
                    if (all16 || (g_q == 2'd3 && g_sub == 3'd4)) st <= I_DRAIN;
                    else if (g_sub == 3'd4) begin g_q <= g_q + 1'b1; g_sub <= 3'd0; st <= I_GROUP; end
                    else st <= I_GROUP;
                end
                // every item fetched: done once the interpolation side has emptied both banks
                I_DRAIN: if (n_cpd == n_push && !c_act && !cmd_valid && bank_full == 2'b00 && k == K_IDLE && pend_v == 2'b00 &&
                             wr_cnt0 == 2'd0 && wr_cnt1 == 2'd0 && !seg_ev[0] && !seg_ev[1])
                    st <= I_DONE;
                I_DONE: begin busy <= 1'b0; done <= 1'b1; st <= I_IDLE; end
                default: st <= I_IDLE;
            endcase

            // ---- receive: the queue's items' beats, in order, into the row-buffer ring ------------
            if (rd_valid && rd_ready) begin
                if (rx_word == x_len[2:0] - 3'd1) begin
                    rb_full[rx_seq[3:0]] <= 1'b1; rx_word <= '0; rx_seq <= rx_seq + 5'd1;
                    if (x_row == x_wh - 5'd1) begin x_row <= '0; n_rxd <= n_rxd + 2'd1; end
                    else x_row <= x_row + 5'd1;
                end else rx_word <= rx_word + 1'b1;
            end
            // ---- copy: the queue's oldest item into a free window bank --------------------------
            if (!c_act) begin
                if (n_cpd != n_push && !bank_full[fb]) begin
                    // claimed and described now: the interpolation side may start on it while
                    // its rows arrive (streaming start); its geometry latched for the copy
                    c_act <= 1'b1;
                    c_wh <= q_wh[n_cpd[0]]; c_ww <= q_ww[n_cpd[0]]; c_ws <= q_ws[n_cpd[0]]; c_xi <= q_xi[n_cpd[0]];
                    c_pw <= q_pw[n_cpd[0]]; c_wf <= q_wf[n_cpd[0]];
                    // (the rectangle's first address and row: S4k -- the rows above it are
                    // never read, so they count as present)
                    cp_row <= '0; cp_col <= '0; cp_base <= q_wst[n_cpd[0]];
                    bank_full[fb] <= 1'b1; bank_rows[fb] <= q_r0[n_cpd[0]];
                    d_plane[fb] <= q_plane[n_cpd[0]]; d_fx[fb] <= q_fx[n_cpd[0]]; d_fy[fb] <= q_fy[n_cpd[0]];
                    d_bw[fb] <= q_bw[n_cpd[0]]; d_bh[fb] <= q_bh[n_cpd[0]]; d_gx[fb] <= q_gx[n_cpd[0]];
                    d_gy[fb] <= q_gy[n_cpd[0]]; d_gref0[fb] <= q_gref0[n_cpd[0]]; d_gref1[fb] <= q_gref1[n_cpd[0]];
                    d_bi[fb] <= q_bi[n_cpd[0]]; d_lx[fb] <= q_lx[n_cpd[0]]; d_gp0[fb] <= q_gp0[n_cpd[0]];
                end
            end else if (cp_row == c_wh) begin
                // the item copied (its last row's lane writes still in the copy stages: they
                // carry their bank, and bank_rows counts them when they land): popped, the
                // next bank
                c_act <= 1'b0; fb <= !fb; n_cpd <= n_cpd + 2'd1;
            end else if (rb_full[cp_seq[3:0]]) begin
                // four bytes a cycle from the full row buffer of the ring's copy position
                x0_v <= 1'b1; x0_row <= cp_seq; x0_fb <= fb; x0_a <= cp_a; x0_n <= cp_n;
                for (int k = 0; k < 4; k++) x0_xc[k] <= cp_xc[k];
                if (cp_n != 5'd4 || cp_col + 5'd4 == c_ww) begin
                    cp_col <= '0; cp_row <= cp_row + 1'b1; cp_base <= cp_base + {4'd0, c_ws}; cp_seq <= cp_seq + 5'd1;
                    x0_clr <= 1'b1;
                end else cp_col <= cp_col + 5'd4;
            end

            // ---- the interpolation side: the full banks in order --------------------------------
            case (k)
                // the next item once its setup is done, the lanes it needs can start it (no
                // reads left, a parameter set free: mc_interp's ready) and their writers have
                // room (S4k); its route and weights go to the writers with the start
                K_IDLE: if (bank_full[kb] && sdone && lanes_ok) begin
                    mc_start <= 1'b1; mc_kind <= s_kind; sdone <= 1'b0;
                    k <= K_RD0;
                end
                // the lanes take the start (and push their writers' descriptors), then their
                // reads run; once every read is issued (two cycles more: the last read's window
                // RAM access) the bank is free for the fetch and the next item may start while
                // this one's samples drain through mc_interp and the writers
                K_RD0: begin
                    // (the lanes push now, with this pbb: a group's list 1 done, the next group's
                    // list 0 takes the other bank)
                    if (mc_kind && kd_bi) pbb <= !pbb;
                    k <= K_RD1;
                end
                K_RD1: k <= K_RDW;
                K_RDW: if (lanes_rd) k <= K_FR0;
                K_FR0: k <= K_FR1;
                K_FR1: begin bank_full[kb] <= 1'b0; kb <= !kb; k <= K_IDLE; end
                default: k <= K_IDLE;
            endcase

            // ---- the setup machine: the next item's route and weights -------------------------
            case (ks)
                KS_IDLE: if (!sdone && bank_full[tgt]) begin
                    ls_gref0 <= sd_gref0; ls_gref1 <= sd_gref1; ls_bi <= sd_bi; ls_gp0 <= sd_gp0; ls_c <= sd_c;
                    if (sd_bi && !sd_lx) begin s_kind <= 1'b0; sdone <= 1'b1; end   // list 0 of a bi-predicted group: into pbuf
                    else ks <= KS_WT_RD;                                              // the last list: the weights, then wpred
                end
                KS_WT_RD: begin
                    // the explicit weight entries: list 0 first (the single list's otherwise)
                    wt_addr <= {1'b0, ls_gref0};
                    ks <= KS_WT_RD1;
                end
                KS_WT_RD1: ks <= KS_WT_RD2;     // the table registers the address, then the data
                KS_WT_RD2: begin
                    logic explicit, implicit;
                    explicit = (slice_type == 2'd0 && weighted_pred) || (slice_type == 2'd1 && weighted_bipred_idc == 2'd1);
                    implicit = (slice_type == 2'd1 && weighted_bipred_idc == 2'd2 && ls_bi);
                    if (implicit) begin
                        ds_b <= cur_poc - $signed(poc_q0);
                        ds_d <= $signed(poc_q1) - $signed(poc_q0);
                        ds_start <= 1'b1;
                        ks <= KS_IMPL_WAIT;
                    end else begin
                        wp_mode <= explicit ? 2'd1 : 2'd0;
                        ks <= KS_FIN;
                        if (explicit) begin
                            // wt_data: {cr_o, cr_w, cb_o, cb_w, luma_o, luma_w} of the entry addressed
                            // last cycle (list 0 when the group uses it, else list 1: re-read below)
                            if (ls_gp0) begin
                                wp_w0 <= wt_w;
                                wp_o0 <= wt_o;
                                if (ls_bi) begin wt_addr <= {1'b1, ls_gref1}; ks <= KS_IMPL; end
                            end else begin
                                wt_addr <= {1'b1, ls_gref1};
                                ks <= KS_IMPL;              // read list 1's entry as the single list
                            end
                            wp_logwd <= ls_c ? chroma_log2_wd : luma_log2_wd;
                        end
                    end
                end
                KS_IMPL: ks <= KS_IMPL2;        // (explicit list-1 entry: address -> RAM -> data)
                KS_IMPL2: ks <= KS_IMPL_WAIT;
                KS_IMPL_WAIT: begin
                    logic explicit;
                    explicit = (slice_type == 2'd0 && weighted_pred) || (slice_type == 2'd1 && weighted_bipred_idc == 2'd1);
                    if (explicit) begin
                        if (ls_gp0) begin
                            wp_w1 <= wt_w;
                            wp_o1 <= wt_o;
                        end else begin
                            wp_w0 <= wt_w;
                            wp_o0 <= wt_o;
                        end
                        ks <= KS_FIN;
                    end else if (ds_done) begin
                        // 8.4.3: 32/32 when td is 0, either picture is long-term, or DSF >> 2
                        // is outside -64..128
                        wp_mode <= 2'd1; wp_logwd <= 3'd5; wp_o0 <= '0; wp_o1 <= '0;
                        if (ds_zero || lng0[ls_gref0] || lng1[ls_gref1] ||
                            (ds_dsf >>> 2) < -11'sd64 || (ds_dsf >>> 2) > 11'sd128) begin
                            wp_w0 <= 9'sd32; wp_w1 <= 9'sd32;
                        end else begin
                            wp_w0 <= 9'sd64 - (ds_dsf >>> 2);
                            wp_w1 <= ds_dsf >>> 2;
                        end
                        ks <= KS_FIN;
                    end
                end
                KS_FIN: begin s_kind <= 1'b1; sdone <= 1'b1; ks <= KS_IDLE; end
                default: ks <= KS_IDLE;
            endcase

            // ---- the lanes' row segments into the sample RAM (out_we was cleared above) ----
            if (pend_v[0]) begin
                out_we <= 1'b1; out_word <= pend_word[0]; out_be <= pend_be[0]; out_wdata <= pend_data[0];
                pend_v[0] <= 1'b0;
            end else if (pend_v[1]) begin
                out_we <= 1'b1; out_word <= pend_word[1]; out_be <= pend_be[1]; out_wdata <= pend_data[1];
                pend_v[1] <= 1'b0;
            end
            for (int b = 0; b < 2; b++)
                if (seg_ev[b]) begin
                    pend_v[b] <= 1'b1; pend_word[b] <= seg_word[b]; pend_be[b] <= seg_be[b]; pend_data[b] <= seg_data[b];
                end
            // synthesis translate_off
            // lane 1's segment onto its pending one not granted this cycle (lane 0 held the port)
            // would be lost: a lane's segments are >= 4 cycles apart, so this never happens
            if (seg_ev[1] && pend_v[1] && pend_v[0]) begin
                $display("FAIL [hang] recon_inter: a row segment overran its pending write");
                $fatal(1);
            end
            // synthesis translate_on
        end
    end

endmodule

`default_nettype wire
