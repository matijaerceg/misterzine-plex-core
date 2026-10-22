// h264/dec/recon_mb_fsm.svh -- the state machine of h264/dec/recon_mb.sv (included there;
// every signal is declared in recon_mb.sv). One macroblock per pass: see that header.

    // ---- exp/mb-pipeline: TWO front stages (docs/mb_pipeline.md) ------------------------
    // stage A (as): the descriptor, the neighbours' records, QP, the co-located side info,
    // mv_pred, recon_inter's prediction into bank a_fb; then the HAND-OFF to stage B (ms):
    // intra prediction, the residual adds, the saves, the side words, the deblock hand-off
    // and the end walk. A predicts macroblock k + 1 while B reconstructs k; the back
    // engine deblocks k - 1 and writes k - 2 back.
    typedef enum logic [4:0] {
        A_IDLE, A_DIV, A_LOAD0, A_LOAD1, A_LOAD2, A_LOAD3, A_QP,
        A_COL_CMD, A_COL_DATA, A_MV_GO, A_MV_WAIT, A_MV_READ, A_INTER_GO, A_INTER_WAIT, A_HAND
    } astate_t;
    astate_t     as;
    logic [8:0]  a_cnt;
    logic        a_idle;                   // stage A has no macroblock
    logic        a_cmd_valid;              // A's co-located reads
    logic [28:0] a_cmd_addr;
    logic [3:0]  a_cmd_len;
    logic        a_rd_ready;
    logic [5:0]  a_qp, a_qpc0, a_qpc1, a_pcm_qpc0, a_pcm_qpc1;
    logic [91:0] a_rc [0:3];               // the right column's motion (blocks 5, 7, 13, 15), for the next left
    logic        a_rbank;                  // the residual RAM bank of A's macroblock
    // the residual engine's queue of one: A's macroblock's context, taken when it is idle
    logic        rq_v;
    logic [5:0]  rq_qp, rq_qpc0, rq_qpc1;
    logic        rq_intra, rq_i4, rq_t8, rq_rbank;
    logic [26:0] rq_coded;
    logic [1:0]  rq_cbank;
    // stage B's copies of the descriptor (A released it at the hand-off)
    logic [13:0] b_addr;
    logic [4:0]  b_itype;
    logic [15:0] b_prev_flag;
    logic [47:0] b_rem_mode;
    logic [1:0]  b_chroma_mode;
    logic [15:0] b_nz;
    logic [1:0]  b_cbank;
    logic        b_rbank;
    logic        pcm_lock;                 // B's I_PCM owns the coefficient port

    // ---- stage B's own memory requests (registered) -------------------------------------
    logic        f_bk_we;
    logic [5:0]  f_bk_waddr, f_bk_raddr;
    logic        f_bk_rbank;               // (always 0: the front reads its own bank)
    logic [63:0] f_bk_wdata;
    logic [7:0]  f_bk_wbe;
    logic        f_cmd_valid, f_cmd_write; // B's side-word writes
    logic [28:0] f_cmd_addr;
    logic [3:0]  f_cmd_len;
    logic        f_wd_valid;               // the side words' write data
    logic [63:0] f_wd_data;
    logic [7:0]  f_wd_be;
    logic        db_rd_is0, db_rd_is1;     // the region of the deblocker's read in flight


    // ---- the residual engine's state (its always_ff is at the end of this file) --------
    // It walks a macroblock's residual as soon as stage A has its QPs (the request rq_*,
    // taken when the engine is idle): the luma DC (Intra_16x16), the 16 luma blocks, per
    // chroma plane the DC then the four AC blocks, through dequant_itrans into a residual
    // RAM (block id 0..15 luma, 16..23 chroma AC; a row of four 16-bit samples a word; TWO
    // banks, exp/mb-pipeline: the engine fills macroblock k + 1's while stage B adds k's),
    // res_rdy / res_zero per block and bank. Stage B only waits for a block and adds it.
    // P5b (docs/throughput.md S3): the feed side (rs) and the collector are separate -- the
    // next 4x4 block is started as soon as dequant_itrans drops busy (its intake overlapping
    // the previous block's output stream, the unit's own contract), the collector writing each
    // block's samples from a descriptor FIFO (cf_*) in order. The feed waits for the collector
    // to empty only after a DC block (its outputs are the next blocks' R_DC values).
    // Phase 5c part 2 step 2 (docs/mb_pipeline.md S4j): dequant_itrans8 is a pipeline over
    // blocks too, so the next 8x8 block starts once it drops busy (up to four in flight, the
    // FIFO's depth). r_l8 steers the shared result stream and dequant_itrans cannot be held
    // (res_ready 1): a 4x4 or DC block after 8x8 ones waits in R_SETUP for the collector to
    // empty. (Nothing 4x4 precedes a coded 8x8 block in its macroblock: transform_size_8x8_flag
    // is per macroblock, and the collector is empty when the engine takes one -- rq_take.)
    typedef enum logic [2:0] {R_IDLE, R_SETUP, R_DC, R_FEED, R_NEXT} rstate_t;
    rstate_t     rs;
    logic        rq_take;                  // the engine takes the request (assigned with the engine)
    logic [4:0]  r_blk;                    // 0 luma DC, 1..16 luma, 17 Cb DC, 18..21 Cb AC, 22 Cr DC, 23..26 Cr AC, 27 done
    logic        r_i16;
    logic        r_dcc_c;                  // the chroma plane of a chroma DC block
    logic        r_dcnz;                   // this block's DC is nonzero (dc_q is its value in R_DC)
    logic [4:0]  r_id;                     // the residual RAM block of the block being fed
    logic [63:0] res_rdy, res_zero;        // {bank, block id}
    logic [8:0]  r_coef_addr, f_coef_addr;
    logic [4:0]  f_rid;                    // the front's block being added
    logic [63:0] res_m [0:255];
    logic        res_we;
    logic [7:0]  res_wa, res_raddr;
    logic [63:0] res_wd, res_q, r_row;
    always_ff @(posedge clk) begin
        if (res_we) res_m[res_wa] <= res_wd;
        res_q <= res_m[res_raddr];
    end
    // the engine's macroblock (g_intra is declared in recon_mb.sv: dequant_itrans8's list)
    logic [5:0]  g_qp, g_qpc0, g_qpc1;
    logic        g_i4, g_t8, g_rbank;
    logic [26:0] g_coded;
    logic [1:0]  g_cbank;
    // the coefficient port: the engine's, or B's I_PCM samples (pcm_lock waits out the
    // engine's read in flight, and the engine issues none while it is held)
    always_comb begin
        coef_addr = (ms == M_PCM) ? f_coef_addr : r_coef_addr;
        coef_bank = (ms == M_PCM) ? b_cbank : g_cbank;
    end
    assign rec_wbank = a_mbank; assign rec_rbank = b_mbank;
    // ---- the back engine's state (its always_ff is at the end of this file) ------------
    // E_DB: recon_deblock on macroblock n (bank e_cur, its left neighbour in e_left, the
    // above rows in LM_DBK); then the writeback items of the old E_ states: the above
    // macroblock's pending rows, the left macroblock, this one at the right edge
    // exp/mb-pipeline: the writeback STREAMS (E_SEG .. E_ROW): a read side prefetches the
    // item's words into a 4-deep FIFO one a cycle, a command side issues a row's burst as
    // soon as its words wait there, stepping the address by the plane's row stride (the
    // product pipeline only at a plane's first row). It was one word every ~6.5 cycles
    // (E_DATA 310 of the back engine's ~680 busy, docs/throughput.md)
    // exp/mb-pipeline, step 3: TWO engines. The DEBLOCK engine (ds) runs recon_deblock on
    // macroblock n (bank d_cur, its left neighbour d_left, the above rows in LM_DBK) and
    // hands n to the WRITEBACK engine (es) once that is idle. The writeback engine first does
    // all its LM_DBK work -- phase L (w_lphase): item 0's rows into i0buf, the items'
    // pending rows kept (E_LK1 / E_LK2) -- and then writes back from i0buf and the banks
    // while the deblocker filters n + 1 (stage B starts it only after phase L: LM_DBK has
    // one read and one write port, and the two engines never share them).
    typedef enum logic [1:0] {DS_IDLE, DS_DB, DS_HAND} dsstate_t;
    dsstate_t    ds;
    logic        d_go;                     // stage B's start pulse (with db_start)
    logic [6:0]  d_mbx, d_mby;
    logic [2:0]  d_cur, d_left;
    wire         d_busy = (ds != DS_IDLE) || d_go;
    logic        w_go;                     // the deblock engine's hand-off
    logic        w_lphase;                 // the writeback engine's LM_DBK phase
    logic [63:0] i0buf [0:7];              // item 0: luma rows 13..15 (two words each), Cb 7, Cr 7
    typedef enum logic [3:0] {E_IDLE, E_L0, E_LK1, E_LK2, E_PLAN, E_SEG, E_SROW, E_ADDR, E_ADDR2, E_ROW, E_TAIL} estate_t;
    estate_t     es;
    logic [6:0]  e_mbx, e_mby;
    logic [2:0]  e_cur, e_left;
    logic [4:0]  e_cnt;
    logic        e_cmd_valid;
    logic [28:0] e_cmd_addr;
    logic [3:0]  e_cmd_len;
    logic        e_wd_valid;               // the FIFO's head (combinational)
    logic [63:0] e_wd_data;
    logic [5:0]  e_bk_raddr;
    logic        e_rbank;                  // 0 e_cur, 1 e_left
    logic [10:0] e_dbk_raddr;
    logic        e_dbk_we;
    logic [10:0] e_dbk_waddr;
    logic [63:0] e_dbk_wdata;
    wire         e_busy = d_busy || (es != E_IDLE) || w_go;
    // stage B may start the deblocker: the previous macroblock handed on, the writeback
    // engine's LM_DBK phase over (and B's side words sent)
    wire         db_go_ok = !f_wd_valid && !d_busy && !w_go && !w_lphase;

    // ---- the DDR3 port: stage A's reads (recon_inter's, the co-located side words), stage
    // B's side-word writes, the engine's writeback. A write burst is granted whole: once a
    // write command is taken, only its owner's data words go until w_left reaches 0
    // (dpb_mem pairs write data with write commands in order). A's reads first (latency),
    // then B, then the engine.
    logic        w_owner;                  // 0 stage B, 1 engine
    logic [3:0]  w_left;                   // data words still owed to the accepted write
    wire         aq_valid = (as == A_INTER_WAIT) ? int_cmd_valid : a_cmd_valid;
    wire         grant_a = aq_valid;
    wire         grant_b = !aq_valid && f_cmd_valid && (w_left == 4'd0);
    wire         grant_e = !aq_valid && !f_cmd_valid && e_cmd_valid && (w_left == 4'd0);
    assign       f_cmd_rdy = cmd_ready && grant_a;   // (declared in recon_mb.sv: recon_inter's port)
    wire         b_cmd_rdy = cmd_ready && grant_b;
    wire         e_cmd_rdy = cmd_ready && grant_e;
    wire         f_wd_rdy = wd_ready && (w_left != 4'd0) && !w_owner;
    wire         e_wd_rdy = wd_ready && (w_left != 4'd0) && w_owner;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin w_owner <= 1'b0; w_left <= '0; end
        else begin
            if (cmd_valid && cmd_ready && cmd_write) begin w_owner <= grant_e; w_left <= cmd_len; end
            else if (wd_valid && wd_ready) w_left <= w_left - 4'd1;
        end
    end

    // bank ports: stage B on fb (its own requests), stage A's recon_inter on a_fb while it
    // predicts, the deblocker on d_cur / d_left, the writeback engine on e_left (and e_cur at
    // the right edge). docs/mb_pipeline.md: A k, B k - 1, D k - 2 (left k - 3), W k - 4 / k - 3
    always_comb begin
        for (int b = 0; b < 5; b++) begin
            bk_we[b] = 1'b0; bk_waddr[b] = f_bk_waddr; bk_wdata[b] = f_bk_wdata; bk_wbe[b] = f_bk_wbe;
            bk_raddr[b] = f_bk_raddr;
        end
        bk_we[fb] = f_bk_we; bk_waddr[fb] = f_bk_waddr; bk_wdata[fb] = f_bk_wdata; bk_wbe[fb] = f_bk_wbe;
        bk_raddr[fb] = f_bk_raddr;
        if (as == A_INTER_WAIT) begin
            // recon_inter's lanes write a row segment a time (P5b 4b): word, bytes, data
            bk_we[a_fb] = int_out_we; bk_waddr[a_fb] = int_out_word; bk_wdata[a_fb] = int_out_wdata;
            bk_wbe[a_fb] = int_out_be;
        end
        // the writeback engine's reads (items 1 / 2 and the KEEPs: e_left = n - 1, and e_cur = n
        // only at the right edge, when the deblocker's n + 1 opens a row and has no left edge)
        if (es != E_IDLE) begin
            bk_raddr[e_cur] = e_bk_raddr; bk_raddr[e_left] = e_bk_raddr;
        end
        // the deblocker on d_cur / d_left (its left bank only for the left edge's accesses)
        if (ds == DS_DB) begin
            if (db_wr_en && db_wr_region == 2'd0) begin
                bk_we[d_cur] = 1'b1; bk_waddr[d_cur] = db_wr_addr; bk_wdata[d_cur] = db_wr_data; bk_wbe[d_cur] = db_wr_be;
            end
            if (db_wr_en && db_wr_region == 2'd1) begin
                bk_we[d_left] = 1'b1; bk_waddr[d_left] = db_wr_addr; bk_wdata[d_left] = db_wr_data; bk_wbe[d_left] = db_wr_be;
            end
            bk_raddr[d_cur] = db_rd_addr;
            if (db_rd_region == 2'd1) bk_raddr[d_left] = db_rd_addr;
        end
        // LM_DBK: the deblocker's while it filters, else the writeback engine's (phase L)
        dbk_raddr = e_dbk_raddr; dbk_we = e_dbk_we; dbk_waddr = e_dbk_waddr; dbk_wdata = e_dbk_wdata; dbk_wbe = 8'hFF;
        if (ds == DS_DB) begin
            dbk_raddr = {d_mbx, db_rd_addr[3:0]};
            dbk_we = db_wr_en && db_wr_region == 2'd2;
            dbk_waddr = {d_mbx, db_wr_addr[3:0]}; dbk_wdata = db_wr_data; dbk_wbe = db_wr_be;
        end
        // the deblocker's read data: by the region of the read the RAMs served
        db_rd_data = db_rd_is0 ? bk_q[d_cur] : db_rd_is1 ? bk_q[d_left] : dbk_q;
        // DDR3: the arbiter above
        if (grant_a) begin
            cmd_valid = 1'b1; cmd_write = 1'b0;
            cmd_addr = (as == A_INTER_WAIT) ? int_cmd_addr : a_cmd_addr;
            cmd_len = (as == A_INTER_WAIT) ? int_cmd_len : a_cmd_len;
        end else if (grant_b) begin
            cmd_valid = 1'b1; cmd_write = 1'b1; cmd_addr = f_cmd_addr; cmd_len = f_cmd_len;
        end else begin
            cmd_valid = grant_e; cmd_write = 1'b1; cmd_addr = e_cmd_addr; cmd_len = e_cmd_len;
        end
        rd_ready = (as == A_INTER_WAIT) ? int_rd_ready : a_rd_ready;
        if (w_owner) begin wd_valid = e_wd_valid && (w_left != 4'd0); wd_data = e_wd_data; wd_be = 8'hFF; end
        else         begin wd_valid = f_wd_valid && (w_left != 4'd0); wd_data = f_wd_data; wd_be = f_wd_be; end
    end
    assign dbg_pre_db = (ms == M_DB_GO) && db_go_ok;
    assign dbg_bank = fb;

    // the bank words read back (a read issued two edges ago): the front's, the engine's
    wire  [63:0] bq_cur = bk_q[fb];
    wire  [63:0] bq_e = e_rbank ? bk_q[e_left] : bk_q[e_cur];

    // ---- Intra_4x4 mode derivation (8.3.1.1) -------------------------------------------------
    // neighbour A (left) and B (above) of block i4
    logic [3:0] mode_a, mode_b;
    // the neighbour macroblock's mode of block row / column by4 / bx4 (a case: an index
    // times 97 into the 437-bit word synthesised as a ~200-LUT shifter per use)
    logic [3:0] nbl_mode, nba_mode;
    always_comb begin
        case (by4[3:2])
            2'd0: nbl_mode = nb_left[49 +: 4];
            2'd1: nbl_mode = nb_left[146 +: 4];
            2'd2: nbl_mode = nb_left[243 +: 4];
            default: nbl_mode = nb_left[340 +: 4];
        endcase
        case (bx4[3:2])
            2'd0: nba_mode = nb_above[49 +: 4];
            2'd1: nba_mode = nb_above[146 +: 4];
            2'd2: nba_mode = nb_above[243 +: 4];
            default: nba_mode = nb_above[340 +: 4];
        endcase
    end
    logic       dc_pred;
    always_comb begin
        logic [3:0] ax, ay, bxx, byy;
        logic       av_a, av_b, inter_a, inter_b;
        ax = bx4 - 4'd1; ay = by4;
        bxx = bx4; byy = by4 - 4'd1;
        if (bx4 != 4'd0) begin
            av_a = 1'b1; inter_a = 1'b0;
            mode_a = modes[{ay[3], ax[3], ay[2], ax[2]}];
        end else begin
            av_a = av_left; inter_a = !nb_left[16];
            mode_a = (nb_left[16] && nb_left[17]) ? nbl_mode : 4'd2;
        end
        if (by4 != 4'd0) begin
            av_b = 1'b1; inter_b = 1'b0;
            mode_b = modes[{byy[3], bxx[3], byy[2], bxx[2]}];
        end else begin
            av_b = av_above; inter_b = !nb_above[16];
            mode_b = (nb_above[16] && nb_above[17]) ? nba_mode : 4'd2;
        end
        dc_pred = !av_a || !av_b || (constrained_intra && (inter_a || inter_b));
    end
    wire [3:0] pred_i4 = dc_pred ? 4'd2 : ((mode_a < mode_b) ? mode_a : mode_b);
    logic [2:0] rem_i4;
    always_comb begin
        rem_i4 = 3'd0;
        for (int k = 0; k < 16; k++) if (i4 == k[3:0]) rem_i4 = b_rem_mode[3*k +: 3];
    end
    // Intra_8x8 (High, 8.3.2.1): the same derivation with i4 = 4 * luma8x8BlkIdx -- mode_a /
    // mode_b then read the 4x4 slots 4 b8A + 1 / 4 b8B + 2 of 8-72 (an Intra_8x8 macroblock
    // stores its mode in all four slots of each 8x8 block, so an Intra_4x4 neighbour's rule
    // Intra8x8PredMode[n >> 2] of 8.3.1.1 reads the same slots); prev / rem come from
    // mb_intake's sequential index, luma8x8BlkIdx
    logic [2:0] rem_i8;
    always_comb begin
        case (i4[3:2])
            2'd0: rem_i8 = b_rem_mode[2:0];
            2'd1: rem_i8 = b_rem_mode[5:3];
            2'd2: rem_i8 = b_rem_mode[8:6];
            default: rem_i8 = b_rem_mode[11:9];
        endcase
    end
    wire [2:0] rem_ix = cur_t8 ? rem_i8 : rem_i4;
    wire       prev_ix = cur_t8 ? b_prev_flag[i4[3:2]] : b_prev_flag[i4];
    logic [3:0] i4_pred_q;                 // M_I4_BLK's registered predIntra4x4PredMode
    logic [2:0] i4_rem_q;                  // ... and the block's rem / prev syntax (P5b timing:
    logic       i4_prev_q;                 // i4 -> the 16:1 rem select -> 8-13 -> modes was 9.8 ns)

    // ---- the Intra_4x4 neighbour gather: sample s (0..7 top, 8..11 left, 12 corner) ----------
    // source: 0 = the bank (word, byte), 1 = a register value, 2 = unavailable, 3 = the row
    // above (LM_SAMP word {mbx, g_word[1:0]}, byte), 4 = the left column (its RAM, g_word[4:0])
    logic [2:0]  g_src;
    logic [5:0]  g_word;
    logic [2:0]  g_byte;
    logic [7:0]  g_val;
    logic [5:0]  g_idx;                    // intra_pred's neighbour index
    always_comb begin
        logic [3:0] cx, cy;
        logic       in_mb_up, in_mb_left;
        g_src = 3'd2; g_word = '0; g_byte = '0; g_val = '0; g_idx = '0;
        if (step < 6'd8) begin                               // top: p[k, -1], k = step
            g_idx = {3'd0, step[2:0]};
            cx = bx4 + {1'b0, step[2:0]};
            if (by4 != 4'd0) begin
                cy = by4 - 4'd1;
                if (step < 6'd4) begin
                    g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];
                end else if (bx4 != 4'd12 && {cy[3], cx[3], cy[2], cx[2]} < i4) begin
                    g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];   // decoded earlier in this MB
                end
            end else begin
                if (step < 6'd4 || bx4 != 4'd12) begin
                    if (ia_above) begin g_src = 3'd3; g_word = {5'd0, cx[3]}; g_byte = cx[2:0]; end
                end else begin
                    if (ia_aright) begin g_src = 3'd1; g_val = upr_samp[step[1:0]]; end
                end
            end
        end else if (step < 6'd12) begin                     // left: p[-1, k]
            g_idx = 6'd16 + {4'd0, step[1:0]};
            cy = by4 + {2'd0, step[1:0]};
            if (bx4 != 4'd0) begin
                cx = bx4 - 4'd1;
                g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];
            end else if (ia_left) begin
                g_src = 3'd4; g_word = {2'd0, cy};
            end
        end else begin                                       // the corner p[-1, -1]
            g_idx = 6'd32;
            cx = bx4 - 4'd1; cy = by4 - 4'd1;
            if (bx4 != 4'd0 && by4 != 4'd0) begin
                g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];
            end else if (bx4 == 4'd0 && by4 != 4'd0) begin
                if (ia_left) begin g_src = 3'd4; g_word = {2'd0, cy}; end
            end else if (bx4 != 4'd0 && by4 == 4'd0) begin
                if (ia_above) begin g_src = 3'd3; g_word = {5'd0, cx[3]}; g_byte = cx[2:0]; end
            end else begin
                if (ia_aleft) begin g_src = 3'd1; g_val = corner[0]; end
            end
        end
    end
    // ---- the Intra_8x8 neighbour gather (8.3.2.2): step 0..15 p[x, -1] (store 0..15),
    // 16..23 p[-1, y] (16..23), 24 the corner (32); the 8x8 block at (bx4, by4) = i4 = 4 b8.
    // Top-right p[8..15, -1]: block 0 the above macroblock's, 1 the above-right's (upr_samp),
    // 2 block 1's bottom row (reconstructed before block 2's gather), 3 never available
    logic [2:0]  h_src;
    logic [5:0]  h_word;
    logic [2:0]  h_byte;
    logic [7:0]  h_val;
    logic [5:0]  h_idx;
    always_comb begin
        logic [4:0] cx;
        logic [3:0] cy, lx;
        h_src = 3'd2; h_word = '0; h_byte = '0; h_val = '0; h_idx = '0;
        cx = '0; cy = '0; lx = '0;
        if (step < 6'd16) begin                              // top: p[k, -1], k = step
            h_idx = step;
            cx = {1'b0, bx4} + {1'b0, step[3:0]};
            if (by4 != 4'd0) begin
                cy = by4 - 4'd1;
                if (step < 6'd8 || bx4 == 4'd0) begin
                    h_src = 3'd0; h_word = {1'b0, cy, cx[3]}; h_byte = cx[2:0];
                end
            end else if (!cx[4]) begin
                if (ia_above) begin h_src = 3'd3; h_word = {5'd0, cx[3]}; h_byte = cx[2:0]; end
            end else if (ia_aright) begin
                h_src = 3'd1; h_val = upr_samp[cx[2:0]];
            end
        end else if (step < 6'd24) begin                     // left: p[-1, k]
            h_idx = 6'd16 + {3'd0, step[2:0]};
            cy = by4 + {1'b0, step[2:0]};
            if (bx4 != 4'd0) begin
                lx = bx4 - 4'd1;
                h_src = 3'd0; h_word = {1'b0, cy, lx[3]}; h_byte = lx[2:0];
            end else if (ia_left) begin
                h_src = 3'd4; h_word = {2'd0, cy};
            end
        end else begin                                       // the corner p[-1, -1]
            h_idx = 6'd32;
            lx = bx4 - 4'd1; cy = by4 - 4'd1;
            if (bx4 != 4'd0 && by4 != 4'd0) begin
                h_src = 3'd0; h_word = {1'b0, cy, lx[3]}; h_byte = lx[2:0];
            end else if (bx4 == 4'd0 && by4 != 4'd0) begin
                if (ia_left) begin h_src = 3'd4; h_word = {2'd0, cy}; end
            end else if (bx4 != 4'd0 && by4 == 4'd0) begin
                if (ia_above) begin h_src = 3'd3; h_word = {5'd0, lx[3]}; h_byte = lx[2:0]; end
            end else begin
                if (ia_aleft) begin h_src = 3'd1; h_val = corner[0]; end
            end
        end
    end
    // the neighbour issued this cycle by M_I4_NB (the gather above), M_I16_NB (step 0..15
    // the row above, 16..31 the left column, 32 the corner) or M_CI_NB (0..7, 8..15, 16):
    // one a cycle through the gather pipeline; an unavailable row / column goes as 0
    logic [2:0]  n_src;
    logic [5:0]  n_word, n_idx;
    logic [2:0]  n_byte;
    logic [7:0]  n_val;
    always_comb begin
        n_src = g_src; n_word = g_word; n_byte = g_byte; n_val = g_val; n_idx = g_idx;
        if (ms == M_I4_NB && cur_t8) begin
            n_src = h_src; n_word = h_word; n_byte = h_byte; n_val = h_val; n_idx = h_idx;
        end
        if (ms == M_I16_NB) begin
            n_idx = step; n_byte = step[2:0]; n_val = 8'd0;
            if (step < 6'd16)      begin n_src = ia_above ? 3'd3 : 3'd1; n_word = {5'd0, step[3]}; end
            else if (step < 6'd32) begin n_src = ia_left ? 3'd4 : 3'd1;  n_word = {2'd0, step[3:0]}; end
            else                   begin n_src = 3'd1; n_val = corner[0]; n_idx = 6'd32; end
        end else if (ms == M_CI_NB) begin
            n_byte = step[2:0]; n_val = 8'd0;
            if (step < 6'd8)       begin n_src = ia_above ? 3'd3 : 3'd1; n_word = {4'd0, 1'b1, cplane[0]}; n_idx = step; end
            else if (step < 6'd16) begin n_src = ia_left ? 3'd4 : 3'd1;  n_word = {1'b0, 1'b1, cplane[0], step[2:0]}; n_idx = 6'd16 + {3'd0, step[2:0]}; end
            else                   begin n_src = 3'd1; n_val = corner[1 + cplane[0]]; n_idx = 6'd32; end
        end
    end
    // availability of the top 4, the top-right 4, the left 4 of block i4
    wire top_av  = (by4 != 4'd0) ? 1'b1 : ia_above;
    wire left_av = (bx4 != 4'd0) ? 1'b1 : ia_left;
    logic tr_av;
    always_comb begin
        logic [3:0] cx, cy;
        cx = bx4 + 4'd4; cy = by4 - 4'd1;
        if (by4 != 4'd0) tr_av = (bx4 != 4'd12) && ({cy[3], cx[3], cy[2], cx[2]} < i4);
        else tr_av = (bx4 != 4'd12) ? ia_above : ia_aright;
    end
    logic [7:0] top3;                      // p[3, -1] for the substitution (8.3.1.2)
    // Intra_8x8: p[8..15, -1] available (the top-right substitution of 8.3.2.2 with p[7, -1]
    // otherwise), and p[-1, -1] (the reference filter needs its availability, 8.3.2.2.1)
    wire tr_av8 = (by4 != 4'd0) ? (bx4 == 4'd0) : ((bx4 == 4'd0) ? ia_above : ia_aright);
    wire corner_av = (bx4 != 4'd0 && by4 != 4'd0) ? 1'b1 : (bx4 == 4'd0 && by4 != 4'd0) ? ia_left :
                     (bx4 != 4'd0) ? ia_above : ia_aleft;
    logic [7:0] top7;                      // p[7, -1] for the Intra_8x8 substitution
    // top3 / top7 load from ip_nb_val a cycle after it (timing: gt2_nb is the five-bank read
    // mux and a byte select; through top7's own next-state select it was the cold corner's
    // worst path, 108.18 MHz). Read only in M_I4_NBW, entered two cycles after gt2 empties.
    logic       t3_ld, t7_ld;

    // gather pipeline: a bank read's tag travels two stages
    // (every neighbour travels it, register-sourced ones too, so exactly one lands per cycle)
    logic       gt1_v, gt2_v;
    logic [5:0] gt1_idx, gt2_idx;
    logic [2:0] gt1_byte, gt2_byte;
    logic [1:0] gt1_src, gt2_src;          // 0 a bank byte, 1 gtN_val, 2 an LM_SAMP byte, 3 the left RAM
    logic [7:0] gt1_val, gt2_val;
    logic [7:0] gt2_nb;                    // the neighbour landing at gt2
    always_comb begin
        case (gt2_src)
            2'd0:    gt2_nb = bq_cur[8*gt2_byte +: 8];
            2'd1:    gt2_nb = gt2_val;
            2'd2:    gt2_nb = smp_q[8*gt2_byte +: 8];
            default: gt2_nb = ls_q;
        endcase
    end
    // the left column's RAM: written by M_SAVE (cnt 6..37: byte 7 of the right-column words)
    always_comb begin
        ls_we = (ms == M_SAVE) && (cnt >= 9'd6) && (cnt < 9'd38);
        ls_wa = cnt[4:0] - 5'd6;
        ls_wd = bq_cur[63:56];
    end

    // ---- the residual walk -----------------------------------------------------------------------
    logic [2:0]  r_kind;
    logic [4:0]  r_slot;
    logic [6:0]  r_n;                      // coefficients to stream (64: an 8x8 block)
    logic [6:0]  r_pos;                    // next coefficient
    logic        r_rq1, r_rq2;             // a coefficient read in flight (address -> data two edges)
    // the coefficient queue in front of dequant_itrans: reads issue one a cycle while
    // queued + in flight < 4, so the transform takes a coefficient every cycle (it waited
    // out each read before: ~4 cycles a coefficient, docs/h264_recon.md S6)
    logic signed [15:0] cq [0:3];
    logic [1:0]  cq_h, cq_t;
    logic [2:0]  cq_n;
    logic        r_zpush;                  // an uncoded block's zero joins the queue this cycle
    wire         cq_push = r_rq2 || r_zpush;
    wire         cq_out_free = !dq_coef_valid || dq_coef_ready;
    wire         cq_pop = cq_out_free && (cq_n != 3'd0);
    wire  [2:0]  cq_used = cq_n + {2'd0, r_rq1} + {2'd0, r_rq2} + {2'd0, r_zpush};
    logic [1:0]  r_plane;                  // 0 Y, 1 Cb, 2 Cr (where the block lands)
    logic [3:0]  r_x, r_y;                 // the block's top-left sample in its plane
    logic [4:0]  r_ret;                    // where to go after the block (encoded)
    logic        r_coded;
    logic [2:0]  add_row;
    logic        add_pend;                 // (unused since the pipelined add)
    logic [63:0] rq_d, bq_d;               // the residual row and the bank word, a cycle after the RAMs
    always_ff @(posedge clk) begin rq_d <= res_q; bq_d <= bq_cur; end
    logic        a_v;                      // the residual add's summed row, written next cycle
    logic [5:0]  a_w;
    logic [63:0] a_nw;
    logic [7:0]  a_be;

    // chroma walk: c (0 Cb, 1 Cr), b (0..3)
    logic        cw_c;
    logic [2:0]  cw_b;                     // 4 = the DC stage

    // mv_pred's read-back one cycle late: the reference codes come from recon_slice_tab's
    // RAMs, addressed with the block's refIdx (M_MV_READ: block cnt - 1 on mv_pred's outputs,
    // its codes and these registers at cnt; written at cnt, block cnt - 2)
    assign code_ra0 = mvp_ref0;
    assign code_ra1 = mvp_ref1;
    logic        d_pred0, d_pred1;
    logic [4:0]  d_ref0, d_ref1;
    logic [15:0] d_mvx0, d_mvy0, d_mvx1, d_mvy1;
    always_ff @(posedge clk) begin
        d_pred0 <= mvp_pred0; d_ref0 <= mvp_ref0; d_mvx0 <= mvp_mvx0; d_mvy0 <= mvp_mvy0;
        d_pred1 <= mvp_pred1; d_ref1 <= mvp_ref1; d_mvx1 <= mvp_mvx1; d_mvy1 <= mvp_mvy1;
    end
    wire  [7:0]  d_code0 = d_pred0 ? code_q0 : 8'd0;
    wire  [7:0]  d_code1 = d_pred1 ? code_q1 : 8'd0;
    // the deblocker's block records (see recon_mb.sv, recon_deblock's rec_* port)
    always_comb begin
        rec_we = (as == A_MV_READ) && (a_cnt >= 9'd2);
        rec_wa = a_cnt[3:0] - 4'd2;
        rec_wd = {d_mvy1, d_mvx1, d_code1, d_pred1, d_mvy0, d_mvx0, d_code0, d_pred0, mb_nz[rec_wa]};
    end

    // ---- the co-located fetch -----------------------------------------------------------------------
    logic [63:0] colbuf [0:31];
    logic        col_we;
    logic [4:0]  col_wa;
    logic [63:0] col_wd;
    logic [5:0]  col_i;                    // words received
    logic [2:0]  col_bursts;               // bursts issued
    logic        col_two;                  // two co-located macroblocks (Frm_To_Fld)
    wire  [28:0] col_base_w = dpb_base + {6'd0, col_store, 18'd0} + off_side;   // 2 MiB stores
    // the co-located macroblock address(es) (Table 8-8, non-MBAFF)
    logic [20:0] col_mb0, col_mb1;
    logic [20:0] col_prod_q;               // row0 * W, registered (P5b: vert_scale -> the DSP
                                           // product -> two adds -> col_mb0_q was 9.7 ns at -40 C;
                                           // a stage more stays inside the >= 8 cycles below)
    always_ff @(posedge clk) begin
        logic [7:0] row0;
        case (vert_scale)
            2'd1: row0 = {a_mby, 1'b0};                      // Frm_To_Fld: frame rows 2y, 2y + 1
            2'd2: row0 = {2'b0, a_mby[6:1]};                 // Fld_To_Frm: field row y / 2
            default: row0 = {1'b0, a_mby};
        endcase
        col_prod_q <= {13'd0, row0} * {13'd0, width_mbs};
    end
    always_comb begin
        col_mb0 = col_prod_q + {14'd0, a_mbx};
        col_mb1 = col_mb0 + {13'd0, width_mbs};
        if (col_half == 2'd2) begin col_mb0 = col_mb0 + half_mbs; col_mb1 = col_mb1 + half_mbs; end
    end

    // the co-located entry of block col_ra (8.4.1.2.1): (xCol, yCol) = the block's corner,
    // yM per Table 8-8, read from the co-located buffer (a RAM: 2,048 registers and sixteen
    // 32:1 x 64-bit muxes as registers, docs/h264_recon.md S6.1)
    logic [4:0]  col_addr;
    logic [63:0] col_w;
    always_comb begin
        logic [3:0] xc, yc, ym;
        logic [4:0] src;
        xc = {col_ra[2], col_ra[0], 2'b00}; yc = {col_ra[3], col_ra[1], 2'b00};
        case (vert_scale)
            2'd1: begin ym = {yc[2:0], 1'b0}; src = {yc[3], 4'd0}; end                   // (2 yCol) % 16
            2'd2: begin ym = {a_mby[0], yc[3], 2'b00}; src = 5'd0; end                     // 8 (y % 2) + 4 (yCol / 8)
            default: begin ym = yc; src = 5'd0; end
        endcase
        col_addr = src + {1'b0, ym[3], xc[3], ym[2], xc[2]};
    end
    always_ff @(posedge clk) begin
        if (col_we) colbuf[col_wa] <= col_wd;
        col_w <= colbuf[col_addr];
    end
    // side word: [15:0] mvy [31:16] mvx [39:32] code [44:40] refIdx [45] pred [46] intra
    assign col_q = {2'b00, col_w[46], col_w[39:32], col_w[44:40], col_w[15:0], col_w[31:16]};

    // ---- the writeback plan ----------------------------------------------------------------------
    // items: 0 = the above MB's pending rows (from LM_DBK), 1 = the left MB (prev bank),
    // 2 = this MB at the right edge (current bank); each row: luma 2 words, chroma 1
    logic [1:0]  wb_item;
    logic [4:0]  wb_row;                   // luma rows then Cb then Cr (0..15 / 16..23 / 24..31)
    logic [4:0]  rd_row;
    logic        rd_w, rd_act;
    wire         e_last_row = (e_mby == pic_h_mbs[6:0] - 7'd1);   // the engine's macroblock
    // an item's row walk (wb_row: the command side's row; rd_row: the read side's): rows
    // 0..15 luma, 16..23 Cb, 24..31 Cr; item 0 = luma 13..15, Cb 7, Cr 7; items 1 / 2 =
    // luma 0..12, Cb / Cr 0..6 (all of them on the last macroblock row)
    wire  [4:0]  wb_lr_end = (wb_item == 2'd0 || e_last_row) ? 5'd15 : 5'd12;
    wire  [4:0]  wb_cr_end = (wb_item == 2'd0 || e_last_row) ? 5'd7 : 5'd6;
    logic [4:0]  c_next;                   // the row after wb_row
    logic        c_last;                   // wb_row is the item's last
    logic [4:0]  r_next;                   // the row after rd_row
    logic        r_lastrow;
    always_comb begin
        c_last = 1'b0; c_next = wb_row + 5'd1;
        if (wb_row < 5'd16) begin if (wb_row >= wb_lr_end) c_next = (wb_item == 2'd0) ? 5'd23 : 5'd16; end
        else if (wb_row < 5'd24) begin if (wb_row >= 5'd16 + wb_cr_end) c_next = (wb_item == 2'd0) ? 5'd31 : 5'd24; end
        else if (wb_row >= 5'd24 + wb_cr_end) c_last = 1'b1;
        r_lastrow = 1'b0; r_next = rd_row + 5'd1;
        if (rd_row < 5'd16) begin if (rd_row >= wb_lr_end) r_next = (wb_item == 2'd0) ? 5'd23 : 5'd16; end
        else if (rd_row < 5'd24) begin if (rd_row >= 5'd16 + wb_cr_end) r_next = (wb_item == 2'd0) ? 5'd31 : 5'd24; end
        else if (rd_row >= 5'd24 + wb_cr_end) r_lastrow = 1'b1;
    end
    wire  [1:0]  c_plane = (wb_row < 5'd16) ? 2'd0 : wb_row[3] ? 2'd2 : 2'd1;
    wire  [1:0]  c_next_plane = (c_next < 5'd16) ? 2'd0 : c_next[3] ? 2'd2 : 2'd1;
    // the read side: rd_act while the item has words to read; a read lands two edges later
    // (rd_v1 -> rd_v2) and is pushed with its source (rd_s*: 0 e_cur, 1 e_left, 2 LM_DBK)
    logic        rd_v1, rd_v2;
    logic [1:0]  rd_s1, rd_s2;
    logic [2:0]  rd_i1, rd_i2;             // item 0's i0buf index, beside the read
    logic [63:0] ef [0:3];                 // the data FIFO
    logic [1:0]  ef_h, ef_t;
    logic [2:0]  ef_n;
    wire  [2:0]  ef_used = ef_n + {2'd0, rd_v1} + {2'd0, rd_v2};
    wire  [63:0] rd_land = (rd_s2 == 2'd2) ? i0buf[rd_i2] : (rd_s2 == 2'd1) ? bk_q[e_left] : bk_q[e_cur];
    logic        ef_ne;                    // the FIFO holds a word: registered beside ef_n (its compare into the
                                           // arbiter and dpb_mem's write FIFO was fit 2's worst path, -0.05 ns)
    always_comb begin e_wd_valid = ef_ne; e_wd_data = ef[ef_h]; end
    wire  [3:0]  c_len = (c_plane == 2'd0) ? 4'd2 : 4'd1;
    // the plane's row stride in words: a frame row of luma 2W, chroma W; a field's rows twice that
    logic [28:0] st_y, st_c;
    always_ff @(posedge clk) begin
        st_y <= field_pic ? {19'd0, width_mbs, 2'b0} : {20'd0, width_mbs, 1'b0};
        st_c <= field_pic ? {20'd0, width_mbs, 1'b0} : {21'd0, width_mbs};
    end
    // the DDR address of a row of macroblock column x0 at picture row pr (plane p)
    logic [6:0]  wb_x;
    logic [10:0] wb_prow;                  // the picture row within its plane
    logic [1:0]  wb_plane;
    wire  [11:0] wb_srow = field_pic ? {wb_prow, bottom} : {1'b0, wb_prow};
    logic [11:0] wb_srow_q;
    // two register steps (M_WB_ADDR, M_WB_ADDR2): the row product, then the sums (the product
    // and the adds in the command cycle missed clk_dec)
    // (the plane bases are per-picture constants, registered: cur_base + the plane offset +
    // the product + the column in one cycle was 10.3 ns -- P5b)
    logic [28:0] wb_prod_q, wb_addr_q;
    logic [28:0] pbase_y, pbase_cb, pbase_cr;
    always_ff @(posedge clk) begin
        pbase_y <= cur_base; pbase_cb <= cur_base + off_cb; pbase_cr <= cur_base + off_cr;
        // (the field row select registered first: sh_field_pic -> the mux -> the DSP product
        // was the fit's worst path, -0.26 ns at the 108.8 gate; exp/mb-pipeline)
        wb_srow_q <= wb_srow;
        wb_prod_q <= (wb_plane == 2'd0) ? {17'd0, wb_srow_q} * {21'd0, width_mbs, 1'b0} : {17'd0, wb_srow_q} * {21'd0, width_mbs};
        wb_addr_q <= ((wb_plane == 2'd0) ? pbase_y : (wb_plane == 2'd1) ? pbase_cb : pbase_cr) + wb_prod_q
                   + ((wb_plane == 2'd0) ? {21'd0, wb_x, 1'b0} : {22'd0, wb_x});
    end

    // ---- the motion RAM's port ---------------------------------------------------------------
    // writes: mv_pred's read-back, a cycle late with the codes (block cnt - 2, above)
    always_comb begin
        mot_we = (as == A_MV_READ) && (a_cnt >= 9'd2);
        mot_wa = a_cnt[3:0] - 4'd2;
        mot_wd = {d_mvy1, d_mvx1, d_code1, d_ref1, d_pred1, d_mvy0, d_mvx0, d_code0, d_ref0, d_pred0};
    end
    // the record read (an intra macroblock's motion is all zeros)
    wire  [91:0] mot_qm = cur_intra ? 92'd0 : mot_q;
    // the end walk, after the deblocker (the last reader of nb_above = LM_INFO[mbx] and of
    // nb_left): nl_k 0..3 read the bottom row (blocks 10, 11, 14, 15) into LM_INFO[mbx]
    // (landing at 1..4, the header at 0), 4..7 the right column (5, 7, 13, 15) into nb_left
    // (landing at 5..8)
    logic        nl_run;
    logic [3:0]  nl_k;
    // reads: recon_inter while it runs; the side words (the block the next data cycle
    // sends); the end walk
    wire        sd_adv = (ms == M_SAVE_SIDE_DATA) && (!f_wd_valid || f_wd_rdy);
    always_comb begin
        a_mot_ra = int_mot_ra;              // stage A's bank: recon_inter
        if (ms == M_SAVE_SIDE_CMD || ms == M_SAVE_SIDE_DATA) mot_ra = sd_adv ? cnt[3:0] + 4'd1 : cnt[3:0];
        else if (!nl_k[2]) mot_ra = (nl_k[1:0] == 2'd0) ? 4'd10 : (nl_k[1:0] == 2'd1) ? 4'd11 : (nl_k[1:0] == 2'd2) ? 4'd14 : 4'd15;
        else mot_ra = (nl_k[1:0] == 2'd0) ? 4'd5 : (nl_k[1:0] == 2'd1) ? 4'd7 : (nl_k[1:0] == 2'd2) ? 4'd13 : 4'd15;
    end
    // LM_INFO's writes (the end walk): the header, the bottom blocks as they are read
    always_comb begin
        logic [3:0] bb;
        inf_we = nl_run && (nl_k == 4'd0); inf_waddr = mbx;
        inf_wdata = {pcm_qpc1, pcm_qpc0, qpc1, qpc0, qp, cur_pcm, cur_i4, cur_intra, slice_id};
        ib_we = nl_run && (nl_k >= 4'd1) && (nl_k <= 4'd4);
        ib_j = nl_k[1:0] - 2'd1; ib_wa = mbx;
        bb = (ib_j == 2'd0) ? 4'd10 : (ib_j == 2'd1) ? 4'd11 : (ib_j == 2'd2) ? 4'd14 : 4'd15;
        ib_wd = {mot_qm, b_nz[bb], modes[bb]};
    end
    // the side word of the block read: the list-0 vector when predFlagL0, else list 1's (8.4.1.2.1)
    logic [63:0] side_w;
    always_comb begin
        if (cur_intra) side_w = {17'd0, 1'b1, 46'd0};
        else if (mot_q[0]) side_w = {17'd0, 1'b0, 1'b1, mot_q[5:1], mot_q[13:6], mot_q[29:14], mot_q[45:30]};
        else side_w = {17'd0, 1'b0, 1'b1, mot_q[51:47], mot_q[59:52], mot_q[75:60], mot_q[91:76]};
    end
    wire  [28:0] side_addr_w = cur_base + off_side
                           + {4'd0, ((cur_struct == 2'd2) ? half_mbs : 21'd0) + {7'd0, b_addr}, 4'd0};
    // registered (their inputs hold for the whole macroblock; the product and adds in the
    // command cycle missed clk_dec): the co-located side words' and this macroblock's
    // (stages: the product (col_prod_q), then col_mb0_q, the second row's +W, the sums --
    // four; >= 8 cycles pass between the macroblock's position change and M_COL_CMD)
    logic [28:0] col_base, col_a0, col_a1, side_addr;
    logic [20:0] col_mb0_q, col_mb1_q;
    always_ff @(posedge clk) begin
        col_base <= col_base_w;
        col_mb0_q <= col_mb0; col_mb1_q <= col_mb0_q + {13'd0, width_mbs};   // (col_mb1 = col_mb0 + W)
        col_a0 <= col_base + {4'd0, col_mb0_q, 4'd0};
        col_a1 <= col_base + {4'd0, col_mb1_q, 4'd0};
        side_addr <= side_addr_w;
    end

    // ---- divisions of the macroblock address by the width -----------------------------------
    logic [13:0] div_rem;
    logic [6:0]  div_q;
    logic [13:0] last_addr;
    logic        last_valid;
    logic        rel_pending;              // a released descriptor not yet dropped by the intake

    // the hand-off: stage B idle, and the residual engine has taken A's request (its flags
    // for A's residual bank are cleared then -- stage B must not read the bank's previous
    // macroblock's)
    wire         hand = (as == A_HAND) && (ms == M_IDLE) && (a_pcm || !rq_v) && !clear;

    // =====================================================================================
    // stage A: the descriptor to the prediction
    // =====================================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            as <= A_IDLE; a_cnt <= '0; a_idle <= 1'b1; a_fb <= 3'd0; a_mbank <= 1'b0; a_rbank <= 1'b0;
            a_mbx <= '0; a_mby <= '0; a_slice_id <= '0; qp_pred <= '0;
            a_qp <= '0; a_qpc0 <= '0; a_qpc1 <= '0; a_pcm_qpc0 <= '0; a_pcm_qpc1 <= '0;
            a_intra <= 1'b0; a_i4 <= 1'b0; a_pcm <= 1'b0; a_t8 <= 1'b0;
            a_nb_left <= '0; a_nb_aright <= '0; a_nb_aleft <= '0; a_prev_above <= '0;
            a_av_above <= 1'b0; a_av_aright <= 1'b0; a_av_aleft <= 1'b0; a_av_left <= 1'b0;
            for (int i = 0; i < 4; i++) a_rc[i] <= '0;
            key0 <= '0; keyq <= '0; all16 <= 1'b0; all8 <= '0;
            col_we <= 1'b0; col_wa <= '0; col_wd <= '0; col_i <= '0; col_bursts <= '0; col_two <= 1'b0;
            mb_release <= 1'b0; err_count <= '0; err_code <= '0;
            mvp_start <= 1'b0; mvp_blk <= '0; int_start <= 1'b0; inf_raddr <= '0;
            a_cmd_valid <= 1'b0; a_cmd_addr <= '0; a_cmd_len <= 4'd1; a_rd_ready <= 1'b0;
            rq_v <= 1'b0; rq_qp <= '0; rq_qpc0 <= '0; rq_qpc1 <= '0; rq_intra <= 1'b0; rq_i4 <= 1'b0; rq_t8 <= 1'b0;
            rq_rbank <= 1'b0; rq_coded <= '0; rq_cbank <= '0;
            div_rem <= '0; div_q <= '0; last_addr <= '0; last_valid <= 1'b0; rel_pending <= 1'b0;
        end else begin
            col_we <= 1'b0; mb_release <= 1'b0; mvp_start <= 1'b0; int_start <= 1'b0;
            if (a_cmd_valid && f_cmd_rdy && as != A_INTER_WAIT) a_cmd_valid <= 1'b0;
            if (mvp_err || int_err) begin err_count <= err_count + 1'b1; err_code <= mvp_err ? 4'd1 : 4'd2; end
            if (rq_take) rq_v <= 1'b0;
            // the right column's motion (the next macroblock's left neighbour), as it is written
            if (mot_we) begin
                case (mot_wa)
                    4'd5: a_rc[0] <= mot_wd;
                    4'd7: a_rc[1] <= mot_wd;
                    4'd13: a_rc[2] <= mot_wd;
                    4'd15: a_rc[3] <= mot_wd;
                    default: ;
                endcase
            end
            if (clear) begin
                as <= A_IDLE; a_idle <= 1'b1; last_valid <= 1'b0; rq_v <= 1'b0; a_cmd_valid <= 1'b0; a_rd_ready <= 1'b0;
            end else case (as)
                A_IDLE: begin
                    a_idle <= !mb_valid || rel_pending;
                    if (rel_pending) begin
                        // the released descriptor stays valid for one more cycle (mb_intake)
                        if (!mb_valid) rel_pending <= 1'b0;
                    end else if (slice_go) begin
                        qp_pred <= slice_qp;
                        a_slice_id <= a_slice_id + 1'b1;
                    end else if (mb_valid && !(width_mbs <= 8'd2 && ms != M_IDLE)) begin
                        // (a picture two macroblocks wide or less: the next one's above or
                        // above-right IS stage B's, whose LM_INFO entry its end walk has not
                        // written yet -- wait for B)
                        a_idle <= 1'b0;
                        if (last_valid && mb_addr == last_addr + 14'd1) begin
                            if ({1'b0, a_mbx} == width_mbs - 8'd1) begin a_mbx <= '0; a_mby <= a_mby + 1'b1; end
                            else a_mbx <= a_mbx + 1'b1;
                            as <= A_LOAD0;
                        end else begin
                            div_rem <= mb_addr; div_q <= '0;
                            as <= A_DIV;
                        end
                        last_addr <= mb_addr; last_valid <= 1'b1;
                    end
                end
                A_DIV: begin                                     // mb_addr / PicWidthInMbs
                    if (div_rem >= {6'd0, width_mbs}) begin div_rem <= div_rem - {6'd0, width_mbs}; div_q <= div_q + 1'b1; end
                    else begin a_mbx <= div_rem[6:0]; a_mby <= div_q; as <= A_LOAD0; end
                end
                // ---- the neighbours' records ---------------------------------------------------
                // LM_INFO: the above-right macroblock first, then the above one, whose word the
                // RAM's output then holds to the hand-off (nothing else reads LM_INFO; stage B
                // copies it; this macroblock's own write waits for B's end walk)
                A_LOAD0: begin inf_raddr <= a_mbx + 7'd1; as <= A_LOAD1; end
                A_LOAD1: begin inf_raddr <= a_mbx; as <= A_LOAD2; end
                A_LOAD2: begin a_nb_aright <= {inf_q[49 +: 97], inf_q[16], inf_q[15:0]}; as <= A_LOAD3; end
                A_LOAD3: begin
                    a_av_above <= (a_mby != 7'd0) && (inf_q[15:0] == a_slice_id);
                    a_av_aright <= (a_mby != 7'd0) && ({1'b0, a_mbx} != width_mbs - 8'd1) && (a_nb_aright[15:0] == a_slice_id);
                    a_av_aleft <= (a_mby != 7'd0) && (a_mbx != 7'd0) && (a_prev_above[15:0] == a_slice_id);
                    a_av_left <= (a_mbx != 7'd0) && (a_nb_left[15:0] == a_slice_id);
                    a_nb_aleft <= a_prev_above; a_prev_above <= {inf_q[49 + 97*3 +: 97], inf_q[16], inf_q[15:0]};
                    as <= A_QP;
                end
                // ---- QP, the residual engine's request, the branch ----------------------------
                A_QP: if (mb_pcm || !rq_v) begin
                    a_qp <= qp_new_q; qp_pred <= qp_new_q;
                    a_qpc0 <= qpc_n0_q; a_qpc1 <= qpc_n1_q;
                    a_pcm_qpc0 <= qpc_p0; a_pcm_qpc1 <= qpc_p1;
                    a_intra <= mb_is_intra && !mb_skip; a_pcm <= mb_pcm;
                    a_i4 <= mb_is_intra && !mb_skip && mb_itype == 5'd0;
                    a_t8 <= mb_t8;                    // (mb_intake: 0 unless coded, I_NxN or inter)
                    if (!mb_pcm) begin                // the residual engine walks this macroblock
                        rq_v <= 1'b1; rq_qp <= qp_new_q; rq_qpc0 <= qpc_n0_q; rq_qpc1 <= qpc_n1_q;
                        rq_intra <= mb_is_intra && !mb_skip; rq_i4 <= mb_is_intra && !mb_skip && mb_itype == 5'd0;
                        rq_t8 <= mb_t8; rq_coded <= mb_coded; rq_cbank <= mb_cbank; rq_rbank <= a_rbank;
                    end
                    a_cnt <= '0;
                    if (mb_pcm || (mb_is_intra && !mb_skip)) as <= A_HAND;          // (intra: all in stage B)
                    else if (slice_type == 2'd1 && mb_direct8 != 4'd0) begin col_i <= '0; col_bursts <= '0; as <= A_COL_CMD; end
                    else as <= A_MV_GO;
                end
                // ---- inter: the co-located side info, mv_pred, recon_inter -------------------------
                A_COL_CMD: begin
                    // bursts of 8 words: macroblock 0 (two bursts), then macroblock 1 for Frm_To_Fld
                    if (!a_cmd_valid) begin
                        a_cmd_valid <= 1'b1; a_cmd_len <= 4'd8;
                        a_cmd_addr <= (col_bursts[1] ? col_a1 : col_a0) + {25'd0, col_bursts[0], 3'd0};
                        col_bursts <= col_bursts + 1'b1;
                        if (col_bursts == ((vert_scale == 2'd1) ? 3'd3 : 3'd1)) begin a_rd_ready <= 1'b1; as <= A_COL_DATA; end
                    end
                end
                A_COL_DATA: begin
                    if (rd_valid && a_rd_ready) begin
                        col_we <= 1'b1; col_wa <= col_i[4:0]; col_wd <= rd_data;
                        col_i <= col_i + 1'b1;
                        if (col_i == ((vert_scale == 2'd1) ? 6'd31 : 6'd15)) begin a_rd_ready <= 1'b0; as <= A_MV_GO; end
                    end
                end
                A_MV_GO: begin mvp_start <= 1'b1; as <= A_MV_WAIT; end
                A_MV_WAIT: if (mvp_done) begin mvp_blk <= 4'd0; a_cnt <= '0; as <= A_MV_READ; end
                A_MV_READ: begin
                    // out_blk is a registered read: block a_cnt - 1's words are on the outputs now
                    if (a_cnt != 9'd0 && a_cnt <= 9'd16) begin
                        logic [3:0] b;
                        b = a_cnt[3:0] - 4'd1;
                        // (the motion RAM is written from the same words a cycle later: mot_we)
                        // recon_inter's uniformity tests, one block at a time (a 16-way compare
                        // of 76-bit keys cost ~840 LUTs): every block alike, each 8x8 alike
                        if (b == 4'd0) begin key0 <= rd_key; all16 <= 1'b1; end
                        else if (rd_key != key0) all16 <= 1'b0;
                        if (b[1:0] == 2'd0) begin keyq <= rd_key; all8[b[3:2]] <= 1'b1; end
                        else if (rd_key != keyq) all8[b[3:2]] <= 1'b0;
                    end
                    if (a_cnt == 9'd17) as <= A_INTER_GO;    // block 15 written a cycle late
                    else begin mvp_blk <= a_cnt[3:0] + 4'd1; end
                    a_cnt <= a_cnt + 1'b1;
                end
                A_INTER_GO: begin int_start <= 1'b1; as <= A_INTER_WAIT; end
                A_INTER_WAIT: if (int_done) as <= A_HAND;
                // ---- the hand-off to stage B -------------------------------------------------
                A_HAND: if (hand) begin
                    // the next macroblock's left neighbour, as mv_pred reads it: the header
                    // (slice id, intra) and the right column's motion (an intra one's is zero)
                    a_nb_left[48:0] <= {a_pcm_qpc1, a_pcm_qpc0, a_qpc1, a_qpc0, a_qp, a_pcm, a_i4, a_intra, a_slice_id};
                    a_nb_left[54 +: 92] <= a_intra ? 92'd0 : a_rc[0];
                    a_nb_left[151 +: 92] <= a_intra ? 92'd0 : a_rc[1];
                    a_nb_left[248 +: 92] <= a_intra ? 92'd0 : a_rc[2];
                    a_nb_left[345 +: 92] <= a_intra ? 92'd0 : a_rc[3];
                    a_fb <= (a_fb == 3'd4) ? 3'd0 : a_fb + 3'd1; a_mbank <= !a_mbank; a_rbank <= !a_rbank;
                    mb_release <= 1'b1; rel_pending <= 1'b1;
                    a_idle <= 1'b1;
                    as <= A_IDLE;
                end
                default: as <= A_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // stage B: the hand-off to the macroblock's final samples in its bank
    // =====================================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms <= M_IDLE; fb <= 3'd0; fb_prev <= 3'd4; mbx <= '0; mby <= '0; slice_id <= '0; qp <= '0;
            qpc0 <= '0; qpc1 <= '0; pcm_qpc0 <= '0; pcm_qpc1 <= '0; cur_intra <= 1'b0; cur_i4 <= 1'b0; cur_pcm <= 1'b0;
            nb_left <= '0; nb_above <= '0; b_ar_intra <= 1'b0; b_al_intra <= 1'b0; b_mbank <= 1'b0;
            b_addr <= '0; b_itype <= '0; b_prev_flag <= '0; b_rem_mode <= '0; b_chroma_mode <= '0; b_nz <= '0;
            b_cbank <= '0; b_rbank <= 1'b0; pcm_lock <= 1'b0;
            av_above <= 1'b0; av_aright <= 1'b0; av_aleft <= 1'b0; av_left <= 1'b0;
            for (int i = 0; i < 8; i++) upr_samp[i] <= '0;
            cur_t8 <= 1'b0; ip_av_corner <= 1'b0; top7 <= '0; t3_ld <= 1'b0; t7_ld <= 1'b0;
            for (int i = 0; i < 3; i++) begin corner[i] <= '0; next_corner[i] <= '0; end
            for (int b = 0; b < 16; b++) begin
                modes[b] <= 4'd2;
            end
            nl_run <= 1'b0; nl_k <= '0;
            mb_done <= 1'b0; mb_done_addr <= '0; mb_count <= '0;
            ip_nb_we <= 1'b0; ip_nb_idx <= '0; ip_nb_val <= '0;
            ip_start <= 1'b0; ip_kind <= '0; ip_mode <= '0; ip_av_top <= 1'b0; ip_av_left <= 1'b0;
            f_rid <= '0; res_raddr <= '0;
            db_start <= 1'b0; db_left_en <= 1'b0; db_top_en <= 1'b0; db_int_en <= 1'b0;
            f_bk_we <= 1'b0; f_bk_waddr <= '0; f_bk_raddr <= '0; f_bk_rbank <= 1'b0;
            f_bk_wdata <= '0; f_bk_wbe <= '0; f_cmd_valid <= 1'b0; f_cmd_write <= 1'b1; f_cmd_addr <= '0; f_cmd_len <= 4'd1;
            db_rd_is0 <= 1'b0; db_rd_is1 <= 1'b0;
            f_wd_valid <= 1'b0; f_wd_data <= '0; f_wd_be <= 8'hFF; d_go <= 1'b0;
            smp_we <= 1'b0; smp_waddr <= '0; smp_raddr <= '0; smp_wdata <= '0; f_coef_addr <= '0;
            cnt <= '0; step <= '0; rblk <= '0; rphase <= '0; i4 <= '0; i4_mode <= '0; rd_pend <= '0;
            cplane <= '0; after_pred <= 1'b0; top3 <= '0;
            gt1_v <= 1'b0; gt2_v <= 1'b0; gt1_idx <= '0; gt2_idx <= '0; gt1_byte <= '0; gt2_byte <= '0;
            gt1_src <= 2'd0; gt2_src <= 2'd0; gt1_val <= '0; gt2_val <= '0; ls_raddr <= '0;
            r_plane <= '0; r_x <= '0; r_y <= '0; r_ret <= '0; add_row <= '0; add_pend <= 1'b0; a_v <= 1'b0; a_w <= '0; a_nw <= '0; a_be <= '0;
            cw_c <= 1'b0; cw_b <= '0;
        end else begin
            // pulses
            mb_done <= 1'b0; ip_nb_we <= 1'b0;
            ip_start <= 1'b0; db_start <= 1'b0; f_bk_we <= 1'b0; d_go <= 1'b0;
            smp_we <= 1'b0; a_v <= 1'b0;
            // the residual add's registered row (M_RES_ADD_RD)
            if (a_v) begin f_bk_we <= 1'b1; f_bk_waddr <= a_w; f_bk_wdata <= a_nw; f_bk_wbe <= a_be; end
            db_rd_is0 <= (db_rd_region == 2'd0); db_rd_is1 <= (db_rd_region == 2'd1);
            if (f_cmd_valid && b_cmd_rdy) f_cmd_valid <= 1'b0;
            if (f_wd_valid && f_wd_rdy) f_wd_valid <= 1'b0;
            // the end walk (the writeback states leave the motion port to it): the right
            // column's motion lands in nb_left at nl_k 5..8
            if (nl_run) begin
                case (nl_k)
                    4'd5: nb_left[54 +: 92] <= mot_qm;
                    4'd6: nb_left[151 +: 92] <= mot_qm;
                    4'd7: nb_left[248 +: 92] <= mot_qm;
                    4'd8: nb_left[345 +: 92] <= mot_qm;
                    default: ;
                endcase
                if (nl_k == 4'd8) nl_run <= 1'b0;
                nl_k <= nl_k + 1'b1;
            end
            // the gather pipeline (intra neighbours from the bank)
            gt2_v <= gt1_v; gt2_idx <= gt1_idx; gt2_byte <= gt1_byte; gt2_src <= gt1_src; gt2_val <= gt1_val;
            gt1_v <= 1'b0;
            t3_ld <= gt2_v && (gt2_idx == 6'd3); t7_ld <= gt2_v && (gt2_idx == 6'd7);
            if (t3_ld) top3 <= ip_nb_val;
            if (t7_ld) top7 <= ip_nb_val;
            if (gt2_v) begin
                ip_nb_we <= 1'b1; ip_nb_idx <= gt2_idx;
                ip_nb_val <= gt2_nb;
            end
            // a neighbour issued (the three states' selection above): the read addressed now,
            // its data two edges later at gt2
            if ((ms == M_I4_NB && step <= (cur_t8 ? 6'd24 : 6'd12)) || (ms == M_I16_NB && step <= 6'd32) || (ms == M_CI_NB && step <= 6'd16)) begin
                gt1_idx <= n_idx; gt1_byte <= n_byte; gt1_val <= n_val;
                case (n_src)
                    3'd0: begin f_bk_raddr <= n_word; f_bk_rbank <= 1'b0; gt1_v <= 1'b1; gt1_src <= 2'd0; end
                    3'd1: begin gt1_v <= 1'b1; gt1_src <= 2'd1; end
                    3'd3: begin smp_raddr <= {mbx, n_word[1:0]}; gt1_v <= 1'b1; gt1_src <= 2'd2; end
                    3'd4: begin ls_raddr <= n_word[4:0]; gt1_v <= 1'b1; gt1_src <= 2'd3; end
                    default: ;                                        // unavailable: nothing
                endcase
            end

            if (clear) begin
                ms <= M_IDLE; pcm_lock <= 1'b0;
            end else case (ms)
                // ---------------------------------------------------------------------------
                M_IDLE: if (hand) begin
                    // stage A's macroblock: its context and the descriptor's fields B reads
                    mbx <= a_mbx; mby <= a_mby; slice_id <= a_slice_id; fb <= a_fb;
                    qp <= a_qp; qpc0 <= a_qpc0; qpc1 <= a_qpc1; pcm_qpc0 <= a_pcm_qpc0; pcm_qpc1 <= a_pcm_qpc1;
                    cur_intra <= a_intra; cur_i4 <= a_i4; cur_pcm <= a_pcm; cur_t8 <= a_t8;
                    nb_above <= inf_q; b_ar_intra <= a_nb_aright[16]; b_al_intra <= a_nb_aleft[16];
                    av_above <= a_av_above; av_aright <= a_av_aright; av_aleft <= a_av_aleft; av_left <= a_av_left;
                    b_addr <= mb_addr; b_itype <= mb_itype; b_prev_flag <= mb_prev_flag; b_rem_mode <= mb_rem_mode;
                    b_chroma_mode <= mb_chroma_mode; b_nz <= mb_nz; b_cbank <= mb_cbank; b_rbank <= a_rbank;
                    b_mbank <= a_mbank;
                    ms <= M_LOAD0;
                end
                // ---- the unfiltered row above (LM_SAMP, B's own: B writes it at M_SAVE) --------
                M_LOAD0: begin smp_raddr <= {mbx, 2'd0}; ms <= M_LOAD1; end
                M_LOAD1: begin smp_raddr <= {mbx, 2'd1}; ms <= M_LOAD2; end
                M_LOAD2: begin
                    for (int i = 0; i < 3; i++) corner[i] <= next_corner[i];   // the previous row-above's last samples
                    smp_raddr <= {mbx, 2'd2}; ms <= M_LOAD3;
                end
                M_LOAD3: begin
                    next_corner[0] <= smp_q[63:56];              // (the row above is read in place)
                    smp_raddr <= {mbx, 2'd3}; ms <= M_LOAD4;
                end
                M_LOAD4: begin
                    next_corner[1] <= smp_q[63:56];
                    smp_raddr <= {mbx + 7'd1, 2'd0}; ms <= M_LOAD5;
                end
                M_LOAD5: begin
                    next_corner[2] <= smp_q[63:56];
                    ms <= M_LOAD6;
                end
                M_LOAD6: begin
                    for (int i = 0; i < 8; i++) upr_samp[i] <= smp_q[8*i +: 8];
                    ms <= M_QP;
                end
                // ---- the branch ------------------------------------------------------------------
                M_QP: begin
                    for (int b = 0; b < 16; b++) modes[b] <= 4'd2;
                    cnt <= '0; step <= '0; i4 <= '0; rblk <= '0;
                    if (cur_pcm) begin pcm_lock <= 1'b1; ms <= M_PCM_LOCK; end
                    else if (cur_intra) begin
                        if (cur_i4) begin step <= '0; ms <= M_I4_BLK; end else ms <= M_I16_NB;
                    end
                    else ms <= M_RES_LUMA;            // (the prediction is in the bank: stage A's)
                end
                // ---- I_PCM: the coefficient port once the engine's read in flight has landed ----
                M_PCM_LOCK: if (!r_rq1) ms <= M_PCM;
                // ---- I_PCM: 384 samples, word = sample >> 3, byte = sample & 7 ---------------------
                M_PCM: begin
                    // the address of sample cnt now; its byte arrives two edges later
                    if (cnt < 9'd384) f_coef_addr <= cnt;
                    if (cnt >= 9'd2) begin
                        logic [8:0] sidx;
                        sidx = cnt - 9'd2;
                        f_bk_we <= 1'b1; f_bk_waddr <= sidx[8:3];
                        f_bk_wdata <= {8{coef_data[7:0]}}; f_bk_wbe <= 8'd1 << sidx[2:0];
                    end
                    if (cnt == 9'd385) begin cnt <= '0; pcm_lock <= 1'b0; ms <= M_SAVE; end
                    else cnt <= cnt + 1'b1;
                end
                // ---- Intra_4x4 ------------------------------------------------------------------------
                M_I4_BLK: begin
                    // two cycles: the predicted mode registered (the neighbour selection and
                    // the min in one cycle with the write missed clk_dec), then 8-13's rule
                    if (step == 6'd0) begin
                        i4_pred_q <= pred_i4; i4_rem_q <= rem_ix; i4_prev_q <= prev_ix; step <= 6'd1;
                    end else begin
                        logic [3:0] m;
                        m = i4_prev_q ? i4_pred_q : (({1'b0, i4_rem_q} < i4_pred_q) ? {1'b0, i4_rem_q} : {1'b0, i4_rem_q} + 4'd1);
                        i4_mode <= m;
                        if (cur_t8) begin
                            for (int k = 0; k < 16; k++) if (k[3:2] == i4[3:2]) modes[k] <= m;
                        end else modes[i4] <= m;
                        step <= '0; ms <= M_I4_NB;
                    end
                end
                M_I4_NB: begin
                    // one neighbour per cycle: bank reads through the gather pipeline, the rest now
                    if (step <= (cur_t8 ? 6'd24 : 6'd12)) step <= step + 1'b1;      // (issued above)
                    else if (!gt1_v && !gt2_v) begin
                        step <= '0; ms <= M_I4_NBW;
                    end
                end
                M_I4_NBW: begin
                    // the top-right substitution: p[4..7, -1] = p[3, -1] when unavailable
                    // (Intra_8x8: p[8..15, -1] = p[7, -1])
                    if (cur_t8) begin
                        if (!tr_av8 && top_av) begin
                            if (step < 6'd8) begin
                                ip_nb_we <= 1'b1; ip_nb_idx <= 6'd8 + step; ip_nb_val <= top7; step <= step + 1'b1;
                            end else begin step <= '0; ms <= M_I4_GO; end
                        end else ms <= M_I4_GO;
                    end else if (!tr_av && top_av) begin
                        if (step < 6'd4) begin
                            ip_nb_we <= 1'b1; ip_nb_idx <= 6'd4 + step; ip_nb_val <= top3; step <= step + 1'b1;
                        end else begin step <= '0; ms <= M_I4_GO; end
                    end else ms <= M_I4_GO;
                end
                M_I4_GO: begin
                    ip_start <= 1'b1; ip_kind <= cur_t8 ? 2'd3 : 2'd0; ip_mode <= i4_mode; ip_av_top <= top_av; ip_av_left <= left_av;
                    ip_av_corner <= corner_av;
                    cnt <= '0; ms <= M_I4_PRED;
                end
                M_I4_PRED: begin
                    if (ip_valid) begin
                        logic [3:0] px, py;
                        px = cur_t8 ? bx4 + {1'd0, cnt[2:0]} : bx4 + {2'd0, cnt[1:0]};
                        py = cur_t8 ? by4 + {1'd0, cnt[5:3]} : by4 + {2'd0, cnt[3:2]};
                        f_bk_we <= 1'b1; f_bk_waddr <= {1'b0, py, px[3]};
                        f_bk_wdata <= {8{ip_pred}}; f_bk_wbe <= 8'd1 << px[2:0];
                        cnt <= cnt + 1'b1;
                        if (ip_last) begin
                            // this block's residual (the engine's), then the next block (r_ret 1)
                            // (Intra_8x8: its four 4x4 residual ids in turn, r_ret 2)
                            r_plane <= 2'd0; r_x <= bx4; r_y <= by4; r_ret <= cur_t8 ? 5'd2 : 5'd1; f_rid <= {1'b0, i4};
                            ms <= M_RES_NEXT;
                        end
                    end
                end
                // ---- Intra_16x16 ---------------------------------------------------------------------
                M_I16_NB: begin
                    // 33 neighbours through the gather pipeline: top 0..15, left 16..31, corner 32
                    if (step <= 6'd32) step <= step + 1'b1;
                    else if (!gt1_v && !gt2_v) begin step <= '0; ms <= M_I16_GO; end
                end
                M_I16_GO: begin
                    logic [4:0] t;
                    t = b_itype - 5'd1;
                    ip_start <= 1'b1; ip_kind <= 2'd1; ip_mode <= {2'b00, t[1:0]};   // Intra16x16PredMode = t % 4
                    ip_av_top <= ia_above; ip_av_left <= ia_left; ip_av_corner <= 1'b0;
                    cnt <= '0; ms <= M_I16_PRED;
                end
                M_I16_PRED: begin
                    if (ip_valid) begin
                        f_bk_we <= 1'b1; f_bk_waddr <= {1'b0, cnt[7:4], cnt[3]};
                        f_bk_wdata <= {8{ip_pred}}; f_bk_wbe <= 8'd1 << cnt[2:0];
                        cnt <= cnt + 1'b1;
                        if (ip_last) begin
                            // the luma blocks (the engine did the DC transform first)
                            rblk <= '0; ms <= M_RES_LUMA;
                        end
                    end
                end
                // ---- intra chroma ---------------------------------------------------------------------
                M_CI_NB: begin
                    // 17 neighbours through the gather pipeline: top 0..7, left 16..23, corner 32
                    if (step <= 6'd16) step <= step + 1'b1;
                    else if (!gt1_v && !gt2_v) begin step <= '0; ms <= M_CI_GO; end
                end
                M_CI_GO: begin
                    ip_start <= 1'b1; ip_kind <= 2'd2; ip_mode <= {2'b00, b_chroma_mode};
                    ip_av_top <= ia_above; ip_av_left <= ia_left; ip_av_corner <= 1'b0;
                    cnt <= '0; ms <= M_CI_PRED;
                end
                M_CI_PRED: begin
                    if (ip_valid) begin
                        f_bk_we <= 1'b1;
                        f_bk_waddr <= (cplane[0] ? 6'd40 : 6'd32) + {3'd0, cnt[5:3]};
                        f_bk_wdata <= {8{ip_pred}}; f_bk_wbe <= 8'd1 << cnt[2:0];
                        cnt <= cnt + 1'b1;
                        if (ip_last) begin
                            if (!cplane[0]) begin cplane <= 2'd1; step <= '0; ms <= M_CI_NB; end
                            else begin cw_c <= 1'b0; cw_b <= 3'd0; ms <= M_RES_CHROMA; end
                        end
                    end
                end
                // ---- the luma residual walk (inter, and Intra_16x16's AC) ----------------------------
                M_RES_LUMA: begin
                    if (rblk == 5'd16) begin
                        cw_c <= 1'b0; cw_b <= 3'd0;
                        if (cur_intra) begin cplane <= 2'd0; step <= '0; ms <= M_CI_NB; end   // chroma prediction first
                        else ms <= M_RES_CHROMA;
                    end else begin
                        logic [3:0] b;
                        b = rblk[3:0];
                        r_plane <= 2'd0; r_x <= {b[2], b[0], 2'b00}; r_y <= {b[3], b[1], 2'b00};
                        f_rid <= {1'b0, b}; r_ret <= 5'd3;
                        ms <= M_RES_NEXT;
                    end
                end
                // ---- the chroma residual adds: Cb AC 0..3, then Cr (the engine did each DC first) --------
                M_RES_CHROMA: begin
                    r_plane <= cw_c ? 2'd2 : 2'd1; r_x <= {1'b0, cw_b[0], 2'b00}; r_y <= {1'b0, cw_b[1], 2'b00};
                    f_rid <= 5'd16 + {2'd0, cw_c, cw_b[1:0]}; r_ret <= 5'd5;
                    ms <= M_RES_NEXT;
                end
                // ---- wait for the engine's block (f_rid): add it, or nothing for an all-zero one -------
                M_RES_NEXT: if (res_rdy[{b_rbank, f_rid}]) begin
                    if (res_zero[{b_rbank, f_rid}]) ms <= M_RES_RET;
                    else begin add_row <= '0; add_pend <= 1'b0; ms <= M_RES_ADD_RD; end
                end
                // ---- add the residual to the prediction in the bank, row by row ---------------------------
                M_RES_ADD_RD: begin
                    // pipelined over the four rows: add_row 0..3 addresses row add_row, 3..6 has
                    // row add_row - 3's words (landed at 2..5, registered in rq_d / bq_d: the
                    // RAMs' clock-to-out straight into the add and clip was ~10.5 ns, P5b): the
                    // sum registered (a_*), written the cycle after
                    logic [5:0] w;
                    logic [3:0] yy;
                    logic [2:0] ar;
                    yy = r_y + {1'b0, add_row};
                    w = (r_plane == 2'd0) ? {1'b0, yy, r_x[3]} : ((r_plane == 2'd1) ? 6'd32 : 6'd40) + {3'd0, yy[2:0]};
                    if (add_row < 3'd4) begin f_bk_raddr <= w; f_bk_rbank <= 1'b0; res_raddr <= {b_rbank, f_rid, add_row[1:0]}; end
                    if (add_row >= 3'd3) begin
                        logic [63:0] nw;
                        logic [7:0]  be;
                        logic [5:0]  wl;
                        logic [3:0]  yl;
                        ar = add_row - 3'd3;
                        yl = r_y + {1'b0, ar};
                        wl = (r_plane == 2'd0) ? {1'b0, yl, r_x[3]} : ((r_plane == 2'd1) ? 6'd32 : 6'd40) + {3'd0, yl[2:0]};
                        nw = bq_d; be = '0;
                        for (int j = 0; j < 4; j++) begin
                            logic [2:0] by;
                            logic signed [17:0] v;
                            // a 4x4 block's x within its 8-sample word is 0 or 4: {r_x[2], j}
                            // is a 2:1 byte select (r_x[2:0] + j was an 8:1 one in front of the
                            // add and clip: P5b)
                            by = {r_x[2], j[1:0]};
                            v = $signed({10'd0, bq_d[8*by +: 8]}) + $signed(rq_d[16*j +: 16]);
                            nw[8*by +: 8] = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
                            be[by] = 1'b1;
                        end
                        a_v <= 1'b1; a_w <= wl; a_nw <= nw; a_be <= be;
                    end
                    if (add_row == 3'd6) ms <= M_RES_RET;
                    add_row <= add_row + 1'b1;
                end
                M_RES_RET: begin
                    case (r_ret)
                        5'd1: begin                                  // Intra_4x4: the next block
                            if (i4 == 4'd15) begin cplane <= 2'd0; step <= '0; ms <= M_CI_NB; end
                            else begin i4 <= i4 + 1'b1; step <= '0; ms <= M_I4_BLK; end
                        end
                        5'd2: begin                                  // Intra_8x8: the next 4x4 of the block, then the next block
                            if (f_rid[1:0] != 2'd3) begin
                                logic [1:0] sb;
                                sb = f_rid[1:0] + 2'd1;
                                f_rid <= f_rid + 5'd1;
                                r_x <= {i4[2], sb[0], 2'b00}; r_y <= {i4[3], sb[1], 2'b00};
                                ms <= M_RES_NEXT;
                            end else if (i4 == 4'd12) begin cplane <= 2'd0; step <= '0; ms <= M_CI_NB; end
                            else begin i4 <= i4 + 4'd4; step <= '0; ms <= M_I4_BLK; end
                        end
                        5'd3: begin rblk <= rblk + 1'b1; ms <= M_RES_LUMA; end
                        default: begin                               // a chroma AC block done
                            if (cw_b == 3'd3) begin
                                if (!cw_c) begin cw_c <= 1'b1; cw_b <= 3'd0; ms <= M_RES_CHROMA; end
                                else begin cnt <= '0; ms <= M_SAVE; end
                            end else begin cw_b <= cw_b + 1'b1; ms <= M_RES_CHROMA; end
                        end
                    endcase
                end
                // ---- save the unfiltered lines, the info, the side words ----------------------------------
                M_SAVE: begin
                    // LM_SAMP[mbx] <- words 30, 31, 39, 47; the left RAM <- byte 7 of the right words
                    // (cnt: 0..3 the bottom row words, 4..35 the right column bytes; reads land 2 later)
                    if (cnt < 9'd36) begin
                        f_bk_rbank <= 1'b0;
                        case (cnt)
                            9'd0: f_bk_raddr <= 6'd30; 9'd1: f_bk_raddr <= 6'd31;
                            9'd2: f_bk_raddr <= 6'd39; 9'd3: f_bk_raddr <= 6'd47;
                            default: begin
                                logic [5:0] k;
                                k = cnt[5:0] - 6'd4;
                                f_bk_raddr <= (k < 6'd16) ? {1'b0, k[3:0], 1'b1} : (k < 6'd24) ? 6'd32 + {3'd0, k[2:0]} : 6'd40 + {3'd0, k[2:0]};
                            end
                        endcase
                    end
                    if (cnt >= 9'd2 && cnt < 9'd6) begin
                        smp_we <= 1'b1; smp_waddr <= {mbx, cnt[1:0] - 2'd2}; smp_wdata <= bq_cur;
                    end
                    if (cnt == 9'd38) begin
                        cnt <= '0; ms <= M_SAVE_SIDE_CMD;
                    end else cnt <= cnt + 1'b1;
                end
                M_SAVE_SIDE_CMD: begin
                    // two write bursts of 8 side words
                    if (!f_cmd_valid) begin
                        f_cmd_valid <= 1'b1; f_cmd_write <= 1'b1; f_cmd_len <= 4'd8;
                        f_cmd_addr <= side_addr + {25'd0, cnt[3], 3'd0};
                        ms <= M_SAVE_SIDE_DATA;
                    end
                end
                M_SAVE_SIDE_DATA: begin
                    if (!f_wd_valid || f_wd_rdy) begin
                        f_wd_valid <= 1'b1; f_wd_data <= side_w; f_wd_be <= 8'hFF;
                        cnt <= cnt + 1'b1;
                        if (cnt[2:0] == 3'd7) begin
                            if (cnt[3]) ms <= M_DB_GO; else ms <= M_SAVE_SIDE_CMD;
                        end
                    end
                end
                // ---- deblocking --------------------------------------------------------------------------
                M_DB_GO: begin
                    // the engine takes this macroblock once it is idle (the previous one is
                    // deblocked and written back, so bank fb(n + 1) = fb(n - 2) is free)
                    if (db_go_ok) begin
                        db_left_en <= (mbx != 7'd0) && (disable_deblock != 2'd1) && !(disable_deblock == 2'd2 && !av_left);
                        db_top_en <= (mby != 7'd0) && (disable_deblock != 2'd1) && !(disable_deblock == 2'd2 && !av_above);
                        db_int_en <= (disable_deblock != 2'd1);
                        db_start <= 1'b1; d_go <= 1'b1;
                        ms <= M_DB_WAIT;
                    end
                end
                // the deblocker's bS pre-pass reads this macroblock's block records and the
                // left / above ones (nb_left, LM_INFO[mbx] = nb_above): once it is done the end
                // walk may rewrite them, and the next macroblock may start
                M_DB_WAIT: if (db_pre_done) begin
                    nl_run <= 1'b1; nl_k <= '0;
                    ms <= M_DONE;
                end
                // ---- done ------------------------------------------------------------------------------
                M_DONE: begin
                    if (!f_cmd_valid && !f_wd_valid && !nl_run) begin
                        // the header and {nz, mode} of the right column (its motion is walked in)
                        nb_left[48:0] <= {pcm_qpc1, pcm_qpc0, qpc1, qpc0, qp, cur_pcm, cur_i4, cur_intra, slice_id};
                        nb_left[49 +: 5] <= {b_nz[5], modes[5]};
                        nb_left[146 +: 5] <= {b_nz[7], modes[7]};
                        nb_left[243 +: 5] <= {b_nz[13], modes[13]};
                        nb_left[340 +: 5] <= {b_nz[15], modes[15]};
                        fb_prev <= fb;                    // (fb: the next macroblock's, from stage A)
                        mb_done <= 1'b1; mb_done_addr <= b_addr; mb_count <= mb_count + 1'b1;
                        ms <= M_IDLE;
                    end
                end
                default: ms <= M_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // the back engine: the deblock and the writeback of a finished macroblock, while the
    // front builds the next one (the MB overlap, docs/h264_recon.md S6). Its registers are
    // its own; the slice and picture parameters it reads (the edge flags, the offsets,
    // cur_base, the plane geometry) hold because every NAL boundary waits for idle, which
    // includes this engine. The writeback is the former front states M_WB_*.
    // =====================================================================================
    assign idle = a_idle && (as == A_IDLE) && (ms == M_IDLE) && !e_busy && (rs == R_IDLE) && !rq_v && !nl_run;
    wire         rd_room = (ef_used < 3'd4);
    logic [28:0] c_addr;                   // the next row's address (stride steps)
    logic        c_fresh;                  // ... or the product pipeline's (a plane's first row)
    wire  [28:0] c_a = c_fresh ? wb_addr_q : c_addr;
    // the deblock engine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds <= DS_IDLE; d_mbx <= '0; d_mby <= '0; d_cur <= '0; d_left <= '0; w_go <= 1'b0;
        end else begin
            w_go <= 1'b0;
            if (clear) ds <= DS_IDLE;
            else case (ds)
                DS_IDLE: if (d_go) begin
                    d_mbx <= mbx; d_mby <= mby; d_cur <= fb; d_left <= fb_prev;
                    ds <= DS_DB;
                end
                DS_DB: if (db_done) ds <= DS_HAND;
                DS_HAND: if (es == E_IDLE) begin w_go <= 1'b1; ds <= DS_IDLE; end
                default: ds <= DS_IDLE;
            endcase
        end
    end
    // the writeback engine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            es <= E_IDLE; e_mbx <= '0; e_mby <= '0; e_cur <= '0; e_left <= '0; e_cnt <= '0; w_lphase <= 1'b0;
            rd_i1 <= '0; rd_i2 <= '0;
            for (int i = 0; i < 8; i++) i0buf[i] <= '0;
            e_cmd_valid <= 1'b0; e_cmd_addr <= '0; e_cmd_len <= 4'd1;
            e_bk_raddr <= '0; e_rbank <= 1'b0; e_dbk_raddr <= '0; e_dbk_we <= 1'b0; e_dbk_waddr <= '0; e_dbk_wdata <= '0;
            wb_item <= '0; wb_row <= '0; wb_x <= '0; wb_prow <= '0; wb_plane <= '0;
            rd_row <= '0; rd_w <= 1'b0; rd_act <= 1'b0; rd_v1 <= 1'b0; rd_v2 <= 1'b0; rd_s1 <= '0; rd_s2 <= '0;
            ef_h <= '0; ef_t <= '0; ef_n <= '0; ef_ne <= 1'b0; c_addr <= '0; c_fresh <= 1'b0;
        end else begin
            logic ef_push, ef_pop;
            e_dbk_we <= 1'b0;
            if (e_cmd_valid && e_cmd_rdy) e_cmd_valid <= 1'b0;
            // ---- the read side: one word a cycle into the FIFO while it has room ----------
            rd_v2 <= rd_v1; rd_s2 <= rd_s1; rd_i2 <= rd_i1; rd_v1 <= 1'b0;
            ef_push = rd_v2;
            ef_pop = e_wd_valid && e_wd_rdy;
            if (ef_push) begin ef[ef_t] <= rd_land; ef_t <= ef_t + 2'd1; end
            if (ef_pop) ef_h <= ef_h + 2'd1;
            ef_n <= ef_n + {2'd0, ef_push} - {2'd0, ef_pop};
            ef_ne <= (ef_n + {2'd0, ef_push} - {2'd0, ef_pop}) != 3'd0;
            if (rd_act && rd_room) begin
                if (wb_item == 2'd0) begin
                    // i0buf (phase L read it from LM_DBK): luma rows 13..15 at 2(r - 13) + w, Cb 7 at 6, Cr 7 at 7
                    if (rd_row < 5'd16) rd_i1 <= {rd_row[1:0] - 2'd1, rd_w};
                    else rd_i1 <= (rd_row < 5'd24) ? 3'd6 : 3'd7;
                    rd_s1 <= 2'd2;
                end else begin
                    if (rd_row < 5'd16) e_bk_raddr <= {1'b0, rd_row[3:0], rd_w};
                    else e_bk_raddr <= ((rd_row < 5'd24) ? 6'd32 : 6'd40) + {3'd0, rd_row[2:0]};
                    rd_s1 <= (wb_item == 2'd1) ? 2'd1 : 2'd0;
                end
                rd_v1 <= 1'b1;
                if (rd_row < 5'd16 && !rd_w) rd_w <= 1'b1;
                else begin
                    rd_w <= 1'b0;
                    if (r_lastrow) rd_act <= 1'b0; else rd_row <= r_next;
                end
            end
            if (clear) begin
                es <= E_IDLE; w_lphase <= 1'b0; rd_act <= 1'b0; rd_v1 <= 1'b0; rd_v2 <= 1'b0; ef_h <= '0; ef_t <= '0; ef_n <= '0; ef_ne <= 1'b0;
            end else case (es)
                E_IDLE: if (w_go) begin
                    e_mbx <= d_mbx; e_mby <= d_mby; e_cur <= d_cur; e_left <= d_left;
                    w_lphase <= 1'b1; e_cnt <= '0;
                    es <= E_L0;
                end
                // ---- phase L: every LM_DBK access of this macroblock's writeback ------------
                E_L0: begin
                    // item 0: the above macroblock's rows 13..15, Cb 7, Cr 7 (final now) into i0buf
                    // (LM_DBK words 2..7, 9, 11; a read's word two edges later)
                    if (e_mby == 7'd0) begin e_cnt <= '0; es <= E_LK1; end
                    else begin
                        if (e_cnt < 5'd8) e_dbk_raddr <= {e_mbx, (e_cnt < 5'd6) ? {1'b0, e_cnt[2:0]} + 4'd2 : (e_cnt[0] ? 4'd11 : 4'd9)};
                        if (e_cnt >= 5'd2) i0buf[e_cnt[2:0] - 3'd2] <= dbk_q;
                        if (e_cnt == 5'd9) begin e_cnt <= '0; es <= E_LK1; end
                        else e_cnt <= e_cnt + 1'b1;
                    end
                end
                E_LK1, E_LK2: begin
                    // KEEP: LM_DBK[x] <- rows 12..15 (8 words) and chroma rows 6..7 (4 words) of
                    // the left macroblock (E_LK1, bank e_left) / this one at the right edge (E_LK2)
                    if ((es == E_LK1) ? (e_mbx == 7'd0) : ({1'b0, e_mbx} != width_mbs - 8'd1)) begin
                        e_cnt <= '0;
                        if (es == E_LK1) es <= E_LK2;
                        else begin
                            w_lphase <= 1'b0;
                            wb_item <= (e_mby != 7'd0) ? 2'd0 : (e_mbx != 7'd0) ? 2'd1 : 2'd2;
                            es <= E_PLAN;
                        end
                    end else begin
                        if (e_cnt < 5'd12) begin
                            e_rbank <= (es == E_LK1);
                            e_bk_raddr <= (e_cnt < 5'd8) ? 6'd24 + {3'd0, e_cnt[2:0]} : (e_cnt < 5'd10) ? 6'd38 + {5'd0, e_cnt[0]} : 6'd46 + {5'd0, e_cnt[0]};
                        end
                        if (e_cnt >= 5'd2 && e_cnt < 5'd14) begin
                            logic [3:0] k;
                            k = e_cnt[3:0] - 4'd2;
                            e_dbk_we <= 1'b1; e_dbk_waddr <= {((es == E_LK1) ? e_mbx - 7'd1 : e_mbx), k}; e_dbk_wdata <= bq_e;
                        end
                        if (e_cnt == 5'd14) begin
                            e_cnt <= '0;
                            if (es == E_LK1) es <= E_LK2;
                            else begin
                                w_lphase <= 1'b0;
                                wb_item <= (e_mby != 7'd0) ? 2'd0 : (e_mbx != 7'd0) ? 2'd1 : 2'd2;
                                es <= E_PLAN;
                            end
                        end else e_cnt <= e_cnt + 1'b1;
                    end
                end
                // ---- phase D: the DDR writes, from i0buf and the banks ------------------------
                E_PLAN: begin
                    // skip items that do not apply
                    if (wb_item == 2'd0 && e_mby == 7'd0) wb_item <= 2'd1;
                    else if (wb_item == 2'd1 && e_mbx == 7'd0) wb_item <= 2'd2;
                    else if (wb_item == 2'd2 && {1'b0, e_mbx} != width_mbs - 8'd1) wb_item <= 2'd3;
                    else if (wb_item == 2'd3) es <= E_IDLE;
                    else begin
                        // item 0: luma rows 13..15 + Cb row 7 + Cr row 7 of the above MB (from LM_DBK)
                        // items 1 / 2: rows 0..12 (0..15 on the last row), chroma 0..6 (0..7)
                        wb_row <= (wb_item == 2'd0) ? 5'd13 : 5'd0;
                        rd_row <= (wb_item == 2'd0) ? 5'd13 : 5'd0; rd_w <= 1'b0; rd_act <= 1'b1;
                        es <= E_SEG;
                    end
                end
                E_SEG: begin
                    // a plane's first row into the address pipeline (the product, then the sums)
                    wb_x <= (wb_item == 2'd1) ? e_mbx - 7'd1 : e_mbx;
                    if (wb_row < 5'd16) begin
                        wb_plane <= 2'd0;
                        wb_prow <= {((wb_item == 2'd0) ? e_mby - 7'd1 : e_mby), 4'b0} + {7'd0, wb_row[3:0]};
                    end else begin
                        wb_plane <= wb_row[3] ? 2'd2 : 2'd1;
                        wb_prow <= {1'b0, ((wb_item == 2'd0) ? e_mby - 7'd1 : e_mby), 3'b0} + {8'd0, wb_row[2:0]};
                    end
                    es <= E_SROW;
                end
                E_SROW: es <= E_ADDR;                // the row registered (wb_srow_q)
                E_ADDR: es <= E_ADDR2;               // the product registered (wb_prod_q)
                E_ADDR2: begin c_fresh <= 1'b1; es <= E_ROW; end   // the sum registered (wb_addr_q)
                E_ROW: begin
                    // a row's burst once the previous one's words are all sent and this one's
                    // wait in the FIFO: the words then follow without a gap
                    if (!e_cmd_valid && w_left == 4'd0 && ef_n >= {1'b0, c_len[1:0]}) begin
                        e_cmd_valid <= 1'b1; e_cmd_addr <= c_a; e_cmd_len <= c_len;
                        c_fresh <= 1'b0;
                        if (c_last) es <= E_TAIL;
                        else begin
                            wb_row <= c_next;
                            if (c_next_plane != c_plane) es <= E_SEG;
                            else c_addr <= c_a + ((c_plane == 2'd0) ? st_y : st_c);
                        end
                    end
                end
                E_TAIL: begin
                    // the item's last words sent (its pending rows were kept in phase L)
                    if (!e_cmd_valid && w_left == 4'd0 && ef_n == 3'd0) begin
                        wb_item <= wb_item + 1'b1; es <= E_PLAN;
                    end
                end
                default: es <= E_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // the residual engine (see its declarations at the top): the former M_RES_LUMA /
    // CHROMA / NEXT / FEED walk, into the residual RAM instead of res_buf
    // =====================================================================================
    // the DC values (8.5.10 dcY at 0..15 in the Intra16x16 AC order's source order, 8.5.11
    // dcC at 16 + 4c + i) in a RAM read one at a time; dc_nz marks each entry nonzero, so an
    // uncoded DC block clears the flags instead of the values, and a zero entry reads as 0.
    // The read is addressed by r_blk (whose DC is needed) and lands the edge after, so a
    // block that is transformed waits one cycle in R_DC for it
    logic [15:0] dcm [0:31];
    logic [23:0] dc_nz;
    logic [4:0]  dc_ra, dc_wa;
    logic        dc_we;
    logic signed [15:0] dc_q, dc_wd;
    always_comb begin
        logic [3:0] b;
        b = r_blk[3:0] - 4'd1;
        if (r_blk <= 5'd16) dc_ra = {1'b0, b[3], b[1], b[2], b[0]};
        else if (r_blk >= 5'd22) dc_ra = {3'b101, r_blk[1:0] - 2'd3};
        else dc_ra = {3'b100, r_blk[1:0] - 2'd2};
    end
    always_ff @(posedge clk) begin
        if (dc_we) dcm[dc_wa] <= dc_wd;
        dc_q <= dcm[dc_ra];
    end

    // the collector's descriptor FIFO: one entry per block started, popped at its last sample
    logic [2:0]  cf_kind [0:3];
    logic [4:0]  cf_id [0:3];
    logic        cf_c [0:3];
    logic        cf_l8 [0:3];
    logic        cf_rb [0:3];              // the residual RAM bank (the block's macroblock's)
    logic [1:0]  cf_h, cf_t;
    logic [2:0]  cf_n;
    wire  [2:0]  ck = cf_kind[cf_h];
    wire         ck_dc = (ck == 3'd3 || ck == 3'd4);
    wire  [4:0]  cid = cf_id[cf_h];
    wire         cl8 = cf_l8[cf_h];
    // every coefficient of the block being fed has reached the unit
    wire         r_fed = (r_pos == r_n) && (cq_n == 3'd0) && !r_rq1 && !r_rq2 && !r_zpush && !dq_coef_valid;
    wire         r_serial = (r_kind == 3'd3 || r_kind == 3'd4);
    // a macroblock is taken once the collector is empty: its first block may be an 8x8 one,
    // whose start steers the shared result stream (r_l8) away from a 4x4 block of the
    // previous macroblock still being collected (exp/mb-pipeline: the engine no longer waits
    // for stage B to take every block before the next macroblock)
    // (clear: recon_top's port, tied 0 in emu -- the stream reset is rst_n. A clear in the
    // middle of a block would leave the dequant units and the collector holding it, and
    // this take would wait on cf_n for ever: a clear must come with a reset of those, which
    // nothing needs today; docs/mb_pipeline.md "Known limitations")
    always_comb rq_take = (rs == R_IDLE) && rq_v && (cf_n == 3'd0) && !clear;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dc_nz <= '0; dc_we <= 1'b0; dc_wa <= '0; dc_wd <= '0;
            rs <= R_IDLE; r_blk <= '0; r_i16 <= 1'b0; r_dcc_c <= 1'b0; r_dcnz <= 1'b0; r_id <= '0; res_rdy <= '0; res_zero <= '0;
            r_coef_addr <= '0; res_we <= 1'b0; res_wa <= '0; res_wd <= '0; r_row <= '0;
            r_kind <= '0; r_slot <= '0; r_n <= '0; r_pos <= '0; r_l8 <= 1'b0; r_rq1 <= 1'b0; r_rq2 <= 1'b0; r_zpush <= 1'b0; r_coded <= 1'b0;
            cq_h <= '0; cq_t <= '0; cq_n <= '0; for (int i = 0; i < 4; i++) cq[i] <= '0;
            dq_start <= 1'b0; dq_kind <= '0; dq_qp <= '0; dq_wlist <= '0; dq_dc <= '0; dq_coef_valid <= 1'b0; dq_coef <= '0; res_n <= '0;
            cf_h <= '0; cf_t <= '0; cf_n <= '0;
            for (int i = 0; i < 4; i++) begin cf_kind[i] <= '0; cf_id[i] <= '0; cf_c[i] <= 1'b0; cf_l8[i] <= 1'b0; cf_rb[i] <= 1'b0; end
            g_intra <= 1'b0; g_i4 <= 1'b0; g_t8 <= 1'b0; g_qp <= '0; g_qpc0 <= '0; g_qpc1 <= '0; g_coded <= '0; g_cbank <= '0; g_rbank <= 1'b0;
        end else begin
            logic cf_push, cf_pop;
            cf_push = 1'b0; cf_pop = 1'b0;
            dq_start <= 1'b0; res_we <= 1'b0; dc_we <= 1'b0;
            // coefficient reads (address -> data two edges later) through the 4-entry queue
            r_rq2 <= r_rq1; r_rq1 <= 1'b0; r_zpush <= 1'b0;
            if (cq_push) begin cq[cq_t] <= r_rq2 ? $signed(coef_data) : 16'sd0; cq_t <= cq_t + 1'b1; end
            if (cq_pop) begin dq_coef <= cq[cq_h]; dq_coef_valid <= 1'b1; cq_h <= cq_h + 1'b1; end
            else if (cq_out_free) dq_coef_valid <= 1'b0;
            cq_n <= cq_n + {2'd0, cq_push} - {2'd0, cq_pop};

            // ---- the collector: the head block's samples, in order ----------------------------
            if (dq_res_valid && cf_n != 3'd0) begin
                if (ck_dc) begin
                    logic [4:0] wa;
                    wa = (ck == 3'd3) ? {1'b0, res_n[3:0]} : {2'b10, cf_c[cf_h], res_n[1:0]};
                    dc_we <= 1'b1; dc_wa <= wa; dc_wd <= dq_res;
                    dc_nz[wa] <= (dq_res != 16'sd0);
                end
                else begin
                    // raster order: four samples a row word (an 8x8 block's sample n =
                    // 8 y + x lands in 4x4 id cid + {y / 4, x / 4}, row y % 4)
                    if (res_n[1:0] == 2'd3) begin
                        res_we <= 1'b1;
                        res_wa <= cl8 ? {cf_rb[cf_h], cid[4:2], res_n[5], res_n[2], res_n[4:3]} : {cf_rb[cf_h], cid, res_n[3:2]};
                        res_wd <= {dq_res, r_row[47:0]};
                    end else r_row[16*res_n[1:0] +: 16] <= dq_res;
                end
                res_n <= res_n + 1'b1;
                if (dq_res_last) begin
                    if (cl8) begin
                        for (int k = 0; k < 4; k++) res_rdy[{cf_rb[cf_h], cid + k[4:0]}] <= 1'b1;
                    end else if (!ck_dc) res_rdy[{cf_rb[cf_h], cid}] <= 1'b1;
                    res_n <= '0;
                    cf_pop = 1'b1;
                end
            end

            if (clear) rs <= R_IDLE;
            else case (rs)
                R_IDLE: if (rq_take) begin
                    // stage A's macroblock (rq_take): its context, its bank's flags cleared
                    g_intra <= rq_intra; g_i4 <= rq_i4; g_t8 <= rq_t8; g_qp <= rq_qp; g_qpc0 <= rq_qpc0; g_qpc1 <= rq_qpc1;
                    g_coded <= rq_coded; g_cbank <= rq_cbank; g_rbank <= rq_rbank;
                    if (rq_rbank) begin res_rdy[63:32] <= '0; res_zero[63:32] <= '0; end
                    else begin res_rdy[31:0] <= '0; res_zero[31:0] <= '0; end
                    r_i16 <= rq_intra && !rq_i4;
                    r_blk <= (rq_intra && !rq_i4) ? 5'd0 : 5'd1;
                    rs <= R_SETUP;
                end
                R_SETUP: begin
                    logic [2:0]  kind;
                    logic [4:0]  slot, id;
                    logic [6:0]  n;
                    logic [2:0]  wl;
                    logic [5:0]  q;
                    logic        dcnz;
                    logic        coded, is_dc, c;
                    logic [3:0]  b;
                    logic [1:0]  bb;
                    kind = 3'd0; slot = 5'd0; n = 7'd16; id = 5'd0; q = g_qp; dcnz = 1'b0; c = 1'b0; b = '0; bb = '0;
                    // the 4x4 scaling list (Table 7-2): Intra Y / Cb / Cr 0..2, Inter 3..5
                    wl = g_intra ? 3'd0 : 3'd3;
                    if (r_blk == 5'd0) begin kind = 3'd3; slot = 5'd0; end
                    else if (r_blk <= 5'd16) begin
                        b = r_blk[3:0] - 4'd1; slot = 5'd1 + {1'b0, b}; id = {1'b0, b};
                        if (r_i16) begin kind = 3'd1; n = 7'd15; dcnz = dc_nz[dc_ra]; end
                        // an 8x8 block (b = 4 luma8x8BlkIdx): its 64 levels in slots b + 1 .. b + 4
                        // (mb_intake), its samples into the residual ids b .. b + 3
                        else if (g_t8) begin kind = 3'd5; n = 7'd64; end
                    end else begin
                        c = (r_blk >= 5'd22);
                        q = c ? g_qpc1 : g_qpc0;
                        wl = wl + (c ? 3'd2 : 3'd1);
                        if (r_blk == 5'd17 || r_blk == 5'd22) begin kind = 3'd4; slot = 5'd17 + {4'd0, c}; n = 7'd4; end
                        else begin
                            bb = c ? r_blk[1:0] - 2'd3 : r_blk[1:0] - 2'd2;   // 23..26 -> 0..3, 18..21 -> 0..3
                            kind = 3'd2; slot = 5'd19 + {2'd0, c, bb}; n = 7'd15; id = 5'd16 + {2'd0, c, bb};
                            dcnz = dc_nz[dc_ra];
                        end
                    end
                    coded = g_coded[slot];
                    is_dc = (kind == 3'd3 || kind == 3'd4);
                    // an uncoded DC block clears its flags (perf/retime, 2026-10-13: written from r_blk and its
                    // coded bit alone -- the skip branch below is taken for a DC block exactly when it is not
                    // coded, so the dc_nz lookup that decides it for AC blocks left these clears' cone; r_blk ->
                    // dc_ra -> dc_nz[dc_ra] -> the branch -> dc_nz was a census cluster). Slots: 0 luma, 17 / 18
                    if (r_blk == 5'd0  && !g_coded[0])  dc_nz[15:0]  <= '0;
                    if (r_blk == 5'd17 && !g_coded[17]) dc_nz[19:16] <= '0;
                    if (r_blk == 5'd22 && !g_coded[18]) dc_nz[23:20] <= '0;
                    if (r_blk == 5'd27) rs <= R_IDLE;
                    else if (!coded && (is_dc || !dcnz)) begin
                        // no levels and no DC: nothing to transform
                        if (kind == 3'd5) begin
                            for (int k = 0; k < 4; k++) begin res_rdy[{g_rbank, id + k[4:0]}] <= 1'b1; res_zero[{g_rbank, id + k[4:0]}] <= 1'b1; end
                            r_blk <= r_blk + 5'd4;
                        end else begin
                            if (!is_dc) begin res_rdy[{g_rbank, id}] <= 1'b1; res_zero[{g_rbank, id}] <= 1'b1; end
                            r_blk <= r_blk + 5'd1;
                        end
                    end else if (r_l8 && kind != 3'd5 && cf_n != 3'd0) begin
                        // a 4x4 / DC block after 8x8 ones: their samples still stream on the
                        // 8x8 unit's result port (r_l8 steers it) -- wait for the last
                    end else begin
                        r_kind <= kind; r_slot <= slot; r_n <= n; r_coded <= coded; r_id <= id; r_dcc_c <= c;
                        dq_kind <= kind; dq_qp <= q; r_dcnz <= dcnz; dq_wlist <= wl; r_l8 <= (kind == 3'd5);
                        r_pos <= '0;
                        rs <= R_DC;
                    end
                end
                R_DC: begin
                    // dc_q holds this block's DC now (r_blk has been stable an edge); the
                    // block's descriptor joins the collector's FIFO with its start
                    dq_start <= 1'b1; dq_dc <= r_dcnz ? dc_q : 16'sd0;
                    cf_kind[cf_t] <= r_kind; cf_id[cf_t] <= r_id; cf_c[cf_t] <= r_dcc_c; cf_l8[cf_t] <= r_l8; cf_rb[cf_t] <= g_rbank;
                    cf_push = 1'b1;
                    rs <= R_FEED;
                end
                R_FEED: begin
                    // stream r_n coefficients (zeros when the block was not sent)
                    if (r_pos < r_n && cq_used < 3'd4 && !pcm_lock) begin
                        if (r_coded) begin r_coef_addr <= {r_slot + {3'd0, r_pos[5:4]}, r_pos[3:0]}; r_rq1 <= 1'b1; end
                        else r_zpush <= 1'b1;
                        r_pos <= r_pos + 1'b1;
                    end
                    if (r_fed) rs <= R_NEXT;
                end
                R_NEXT: begin
                    // the next block: once its unit takes a new one (busy low: the 4x4 unit, or
                    // the 8x8 one after an 8x8 block), or -- after a DC block -- once every
                    // result is collected
                    if (r_serial ? (cf_n == 3'd0) : r_l8 ? !dq8_busy : !dq_busy) begin
                        r_blk <= r_blk + (r_l8 ? 5'd4 : 5'd1);
                        rs <= R_SETUP;
                    end
                end
                default: rs <= R_IDLE;
            endcase
            if (cf_push) cf_t <= cf_t + 2'd1;
            if (cf_pop) cf_h <= cf_h + 2'd1;
            cf_n <= cf_n + {2'd0, cf_push} - {2'd0, cf_pop};
        end
    end
