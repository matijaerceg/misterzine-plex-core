// h264/dec/mb_intake.sv -- one macroblock's syntax elements, from the front end's SE
// stream, into the descriptor the reconstruction reads (docs/h264_recon.md S2.3)
//
// Input: the macroblock-layer words of h264/dec/mb_syntax.sv (tools/mb_syntax_golden.py's
// kinds 1..16), MB_START to END_OF_SLICE, one per cycle. Output, when END_OF_SLICE
// arrives: `mb_valid` with the descriptor held until `mb_release`:
//   * the scalars: address, skip, mb_type, the four sub_mb_types, cbp (Intra16x16's
//     implied cbp filled in), mb_qp_delta, intra_chroma_pred_mode, end_of_slice;
//   * the Intra4x4 prediction syntax per 4x4 block: prev flag and rem mode;
//   * refs[list][slot] and mvd[list][4x4 block] laid out as tools/h264_recon_ref.py's
//     expand_mb() does: a slot is a macroblock partition (16x16: 0; 16x8 / 8x16: 0, 1)
//     or a sub-macroblock (8x8: 0..3); an absent ref_idx is 0 (num_ref_idx_active 1),
//     every 4x4 block of a (sub-)partition carries its mvd (in a 32-word RAM read through
//     mvd_ra / mvd_q: the 1,024-bit register bus and its write muxes cost ~1,400 LUTs;
//     an mvd is written into its blocks one a cycle, the input held meanwhile -- at most
//     32 cycles a macroblock; a block whose list is unused keeps a stale value, never
//     read); pred[list] per 4x4 block;
//     the direct sub-macroblocks of B_8x8;
//   * the coefficient levels in a RAM (27 block slots x 16 in scan order: 0 = luma DC,
//     1..16 = luma 4x4 0..15, 17..18 = chroma DC Cb/Cr, 19..26 = chroma AC Cb 0..3 then
//     Cr 0..3) with a `coded` bit per slot (a block the stream did not send is zero),
//     `nz` per luma 4x4 block (a non-zero level; the deblocking bS), or I_PCM's 384
//     samples at addresses 0..383.
// The mapping from the stream order of ref_idx / mvd words to slots and blocks is the
// syntax of 7.3.5.1 / 7.3.5.2 (mb_pred / sub_mb_pred): list 0 over the slots, then
// list 1; the mvds per slot in sub-partition order, x then y.
//
// H264 Phase 5 (High profile, docs/high_profile.md S5): the T8 word (kind 20,
// transform_size_8x8_flag) -> mb_t8; an L8 block (BLK_START kind 5, 64 levels) fills the
// four luma 4x4 slots of its 8x8 (slot 1 + 4 b8 + pos / 16), each marked coded; the
// Intra_8x8 modes arrive as kinds 5 / 6 into entries 0..3 of the prev / rem arrays; `nz`
// is OR-ed over each 8x8 of an 8x8-transform macroblock as the descriptor moves out
// (8.7.2.1 judges bS 2 on the 8x8 block such a macroblock's 4x4 lies in).
//
// Gate: bench/h264/run_mb_intake.sh (the descriptor against expand_mb on real streams).

`default_nettype none

module mb_intake (
    input  wire         clk,
    input  wire         rst_n,

    input  wire  [1:0]  slice_type,        // 0 P, 1 B, 2 I (held for the slice)
    input  wire  [5:0]  num_ref_l0,
    input  wire  [5:0]  num_ref_l1,

    // macroblock words (kinds 1..16), one per cycle when in_ready
    input  wire         in_valid,
    output logic        in_ready,
    input  wire  [7:0]  in_kind,
    input  wire  [7:0]  in_aux,
    input  wire  [15:0] in_val,

    // the descriptor
    output logic        mb_valid,
    input  wire         mb_release,        // the consumer is done with the descriptor and the RAM
    output logic [13:0] mb_addr,
    output logic        mb_skip,
    output logic [5:0]  mb_type,
    output logic [15:0] mb_sub_types,      // 4 x 4 bits, sub-macroblock 0 in [3:0]
    output logic        mb_is_intra,       // mb_type is an intra type of this slice
    output logic [4:0]  mb_itype,          // the I-slice mb_type of an intra MB (0 I_NxN, 1..24 I_16x16, 25 I_PCM)
    output logic [5:0]  mb_cbp,
    output logic signed [7:0] mb_qp_delta,
    output logic [1:0]  mb_chroma_mode,
    output logic        mb_end_of_slice,
    output logic [15:0] mb_prev_flag,      // prev_intra4x4_pred_mode_flag per luma4x4BlkIdx
    output logic [47:0] mb_rem_mode,       // rem_intra4x4_pred_mode, 3 bits per block
    output logic [39:0] mb_refs,           // {l1 slots 3..0, l0 slots 3..0}, 5 bits each
    input  wire  [4:0]  mvd_ra,            // {lx, blk}: the mvd RAM, data the cycle after
    output logic [31:0] mvd_q,             // {x[15:0], y[15:0]}
    output logic [31:0] mb_pred,           // [lx][blk] at 16*lx + blk
    output logic [3:0]  mb_direct8,        // B_8x8: sub-macroblock b8 is B_Direct_8x8
    output logic [26:0] mb_coded,          // coefficient slots the stream sent
    output logic [15:0] mb_nz,             // luma 4x4 blocks with a non-zero level (OR-ed per 8x8 with mb_t8)
    output logic        mb_pcm,
    output logic        mb_t8,             // transform_size_8x8_flag

    // the coefficient RAM (synchronous read, data one cycle after the address)
    output logic [1:0]  mb_cbank,          // exp/mb-pipeline: the descriptor's coefficient bank
    input  wire  [1:0]  coef_bank,         // ... and the bank the reader reads
    input  wire  [8:0]  coef_addr,         // {slot[4:0], pos[3:0]} or a PCM sample index 0..383
    output logic signed [15:0] coef_data,

    output logic        err_order          // a word the macroblock syntax does not allow here
);

    // ---- the working descriptor (w_*) and the output stage (the mb_* ports) ----------
    // DOUBLE-BUFFERED (docs/h264_recon.md S6): the words of macroblock n + 1 are taken while
    // the reconstruction reads macroblock n. END_OF_SLICE completes the working set (w_done);
    // it moves to the output stage as soon as that is free, and the RAMs' banks swap (the
    // intake writes bank wb, the reconstruction reads bank rb = !wb).
    logic [13:0] w_addr;
    logic  w_skip;
    logic [5:0] w_type;
    logic [15:0] w_sub_types;
    logic  w_is_intra;
    logic [4:0] w_itype;
    logic [5:0] w_cbp;
    logic signed [7:0] w_qp_delta;
    logic [1:0] w_chroma_mode;
    logic  w_end_of_slice;
    logic [15:0] w_prev_flag;
    logic [47:0] w_rem_mode;
    logic [39:0] w_refs;
    logic [31:0] w_pred;
    logic [3:0] w_direct8;
    logic [26:0] w_coded;
    logic [15:0] w_nz;
    logic  w_pcm;
    logic  w_t8;
    logic        w_done;
    logic        wb;
    wire         rb = !wb;

    localparam [7:0] SE_MB_START = 8'd1, SE_SKIP = 8'd2, SE_MB_TYPE = 8'd3, SE_SUB_MB_TYPE = 8'd4,
                     SE_PREV_INTRA = 8'd5, SE_REM_INTRA = 8'd6, SE_CHROMA_PRED = 8'd7,
                     SE_REF_L0 = 8'd8, SE_REF_L1 = 8'd9, SE_MVD_L0 = 8'd10, SE_MVD_L1 = 8'd11,
                     SE_CBP = 8'd12, SE_QP_DELTA = 8'd13, SE_BLK_START = 8'd14, SE_COEF = 8'd15,
                     SE_END_OF_SLICE = 8'd16, SE_T8 = 8'd20;
    localparam [3:0] BK_LDC = 4'd0, BK_L4 = 4'd1, BK_CDC = 4'd2, BK_CAC = 4'd3, BK_PCM = 4'd4, BK_L8 = 4'd5;
    localparam [1:0] ST_P = 2'd0, ST_B = 2'd1, ST_I = 2'd2;
    localparam [1:0] SH_16X16 = 2'd0, SH_16X8 = 2'd1, SH_8X16 = 2'd2, SH_8X8 = 2'd3;
    localparam [1:0] SS_8X8 = 2'd0, SS_8X4 = 2'd1, SS_4X8 = 2'd2, SS_4X4 = 2'd3;

    // ---- the coefficient RAM ------------------------------------------------------------
    // exp/mb-pipeline: FOUR banks of 512 -- the working set, the output stage (the predict
    // stage), and the macroblock the reconstruct stage and the residual engine still read
    // after the predict stage released it; cwb rotates, the output's bank is mb_cbank and
    // the reader names its bank (coef_bank)
    logic signed [15:0] cram [0:2047];
    logic        cram_we;
    logic [1:0]  cram_wb, cwb;
    logic [8:0]  cram_waddr;
    logic signed [15:0] cram_wdata;
    always_ff @(posedge clk) begin
        if (cram_we) cram[{cram_wb, cram_waddr}] <= cram_wdata;
        coef_data <= cram[{coef_bank, coef_addr}];
    end

    // ---- the macroblock's shape, from w_type / sub_mb_type -------------------------------
    // per slot (0..3): the lists it predicts from ({l1, l0}), its sub-partition shape
    // the partition layout, decoded from the types (shape_c ...) and REGISTERED (shape ...):
    // the type decode, the slot searches and the mvd mask in one cycle missed clk_dec. A type
    // word holds the intake for one cycle (ty_hold) so no word uses a stale layout.
    logic [1:0]  shape, shape_c;           // SH_*
    logic [1:0]  slot_lists [0:3];
    logic [1:0]  slot_lists_c [0:3];
    logic [1:0]  slot_sub [0:3];           // SS_* (8x8 macroblocks only)
    logic [1:0]  slot_sub_c [0:3];
    logic [2:0]  n_slots, n_slots_c;
    logic        ty_hold;
    always_ff @(posedge clk) begin
        shape <= shape_c; n_slots <= n_slots_c;
        for (int b = 0; b < 4; b++) begin slot_lists[b] <= slot_lists_c[b]; slot_sub[b] <= slot_sub_c[b]; end
    end

    // B w_type 1..21 -> (shape, part0 lists, part1 lists), Table 7-14
    logic [1:0] b_shape;
    logic [1:0] b_p0, b_p1;
    always_comb begin
        b_shape = SH_16X16; b_p0 = 2'b01; b_p1 = 2'b01;
        case (w_type)
            6'd1:  begin b_shape = SH_16X16; b_p0 = 2'b01; end
            6'd2:  begin b_shape = SH_16X16; b_p0 = 2'b10; end
            6'd3:  begin b_shape = SH_16X16; b_p0 = 2'b11; end
            6'd4:  begin b_shape = SH_16X8;  b_p0 = 2'b01; b_p1 = 2'b01; end
            6'd5:  begin b_shape = SH_8X16;  b_p0 = 2'b01; b_p1 = 2'b01; end
            6'd6:  begin b_shape = SH_16X8;  b_p0 = 2'b10; b_p1 = 2'b10; end
            6'd7:  begin b_shape = SH_8X16;  b_p0 = 2'b10; b_p1 = 2'b10; end
            6'd8:  begin b_shape = SH_16X8;  b_p0 = 2'b01; b_p1 = 2'b10; end
            6'd9:  begin b_shape = SH_8X16;  b_p0 = 2'b01; b_p1 = 2'b10; end
            6'd10: begin b_shape = SH_16X8;  b_p0 = 2'b10; b_p1 = 2'b01; end
            6'd11: begin b_shape = SH_8X16;  b_p0 = 2'b10; b_p1 = 2'b01; end
            6'd12: begin b_shape = SH_16X8;  b_p0 = 2'b01; b_p1 = 2'b11; end
            6'd13: begin b_shape = SH_8X16;  b_p0 = 2'b01; b_p1 = 2'b11; end
            6'd14: begin b_shape = SH_16X8;  b_p0 = 2'b10; b_p1 = 2'b11; end
            6'd15: begin b_shape = SH_8X16;  b_p0 = 2'b10; b_p1 = 2'b11; end
            6'd16: begin b_shape = SH_16X8;  b_p0 = 2'b11; b_p1 = 2'b01; end
            6'd17: begin b_shape = SH_8X16;  b_p0 = 2'b11; b_p1 = 2'b01; end
            6'd18: begin b_shape = SH_16X8;  b_p0 = 2'b11; b_p1 = 2'b10; end
            6'd19: begin b_shape = SH_8X16;  b_p0 = 2'b11; b_p1 = 2'b10; end
            6'd20: begin b_shape = SH_16X8;  b_p0 = 2'b11; b_p1 = 2'b11; end
            6'd21: begin b_shape = SH_8X16;  b_p0 = 2'b11; b_p1 = 2'b11; end
            default: ;
        endcase
    end
    // sub_mb_type -> (lists, shape), Tables 7-17 (P) and 7-18 (B); B 0 is direct (lists 0)
    logic [1:0] sub_l [0:3];
    logic [1:0] sub_s [0:3];
    always_comb begin
        for (int b = 0; b < 4; b++) begin
            logic [3:0] t;
            t = w_sub_types[4*b +: 4];
            if (slice_type == ST_P) begin
                sub_l[b] = 2'b01;
                sub_s[b] = t[1:0];                          // 0 8x8, 1 8x4, 2 4x8, 3 4x4
            end else begin
                case (t)
                    4'd0:  begin sub_l[b] = 2'b00; sub_s[b] = SS_4X4; end   // direct
                    4'd1:  begin sub_l[b] = 2'b01; sub_s[b] = SS_8X8; end
                    4'd2:  begin sub_l[b] = 2'b10; sub_s[b] = SS_8X8; end
                    4'd3:  begin sub_l[b] = 2'b11; sub_s[b] = SS_8X8; end
                    4'd4:  begin sub_l[b] = 2'b01; sub_s[b] = SS_8X4; end
                    4'd5:  begin sub_l[b] = 2'b01; sub_s[b] = SS_4X8; end
                    4'd6:  begin sub_l[b] = 2'b10; sub_s[b] = SS_8X4; end
                    4'd7:  begin sub_l[b] = 2'b10; sub_s[b] = SS_4X8; end
                    4'd8:  begin sub_l[b] = 2'b11; sub_s[b] = SS_8X4; end
                    4'd9:  begin sub_l[b] = 2'b11; sub_s[b] = SS_4X8; end
                    4'd10: begin sub_l[b] = 2'b01; sub_s[b] = SS_4X4; end
                    4'd11: begin sub_l[b] = 2'b10; sub_s[b] = SS_4X4; end
                    default: begin sub_l[b] = 2'b11; sub_s[b] = SS_4X4; end
                endcase
            end
        end
    end
    wire is_8x8 = (slice_type == ST_P && w_type == 6'd3) || (slice_type == ST_B && w_type == 6'd22);
    always_comb begin
        for (int b = 0; b < 4; b++) begin slot_lists_c[b] = 2'b00; slot_sub_c[b] = SS_8X8; end
        shape_c = SH_16X16; n_slots_c = 3'd1;
        if (is_8x8) begin
            shape_c = SH_8X8; n_slots_c = 3'd4;
            for (int b = 0; b < 4; b++) begin slot_lists_c[b] = sub_l[b]; slot_sub_c[b] = sub_s[b]; end
        end else if (slice_type == ST_P) begin
            shape_c = (w_type == 6'd1) ? SH_16X8 : (w_type == 6'd2) ? SH_8X16 : SH_16X16;
            n_slots_c = (w_type == 6'd0) ? 3'd1 : 3'd2;
            slot_lists_c[0] = 2'b01; slot_lists_c[1] = 2'b01;
        end else begin
            shape_c = b_shape;
            n_slots_c = (b_shape == SH_16X16) ? 3'd1 : 3'd2;
            slot_lists_c[0] = b_p0; slot_lists_c[1] = (b_shape == SH_16X16) ? 2'b00 : b_p1;
        end
    end

    // ---- slot searches (combinational; per list) ------------------------------------------
    // uses[lx][slot]: the slot predicts from list lx. (perf/retime, 2026-10-13) registered from the layout's
    // next values on the same edge as n_slots / slot_lists, so it equals the old (b < n_slots) && slot_lists[b][lx]
    // on every cycle -- the compare and the AND came off the ref_idx / mvd words' slot searches (n_slots ->
    // uses -> ref_sel -> w_refs' write select was a census cluster)
    logic [3:0] uses [0:1];
    always_ff @(posedge clk)
        for (int lx = 0; lx < 2; lx++)
            for (int b = 0; b < 4; b++)
                uses[lx][b] <= (b[2:0] < n_slots_c) && slot_lists_c[b][lx];
    // the first slot >= from[lx] using lx (4 = none), for the ref cursor and the mvd cursor
    logic [2:0] ref_next [0:1], ref_sel [0:1];
    logic [2:0] mv_slot [0:1], mv_after [0:1];
    logic [1:0] mv_sub [0:1];
    logic       mv_started [0:1];
    always_comb begin
        for (int lx = 0; lx < 2; lx++) begin
            ref_sel[lx] = 3'd4;
            for (int b = 3; b >= 0; b--) if (uses[lx][b] && b[2:0] >= ref_next[lx]) ref_sel[lx] = b[2:0];
            mv_after[lx] = 3'd4;
            for (int b = 3; b >= 0; b--)
                if (uses[lx][b] && (mv_started[lx] ? (b[2:0] > mv_slot[lx]) : 1'b1)) mv_after[lx] = b[2:0];
        end
    end
    // the (sub-)partition of the incoming mvd word: its list's cursor (or the first slot)
    logic       w_lx;
    logic [1:0] w_slot, w_sub;
    logic [2:0] w_nsubs;
    logic [15:0] w_mask;
    always_comb begin
        w_lx = (in_kind == SE_MVD_L1);
        w_slot = mv_started[w_lx] ? mv_slot[w_lx][1:0] : mv_after[w_lx][1:0];
        w_sub = mv_started[w_lx] ? mv_sub[w_lx] : 2'd0;
        if (shape != SH_8X8) w_nsubs = 3'd1;
        else case (slot_sub[w_slot])
            SS_8X8: w_nsubs = 3'd1;
            SS_8X4, SS_4X8: w_nsubs = 3'd2;
            default: w_nsubs = 3'd4;
        endcase
        case (shape)
            SH_16X16: w_mask = 16'hFFFF;
            SH_16X8:  w_mask = (w_slot == 2'd0) ? 16'h00FF : 16'hFF00;
            SH_8X16:  w_mask = (w_slot == 2'd0) ? 16'h0F0F : 16'hF0F0;
            default: begin
                logic [3:0] m4;
                case (slot_sub[w_slot])
                    SS_8X8: m4 = 4'b1111;
                    SS_8X4: m4 = (w_sub == 2'd0) ? 4'b0011 : 4'b1100;
                    SS_4X8: m4 = (w_sub == 2'd0) ? 4'b0101 : 4'b1010;
                    default: m4 = 4'b0001 << w_sub;
                endcase
                w_mask = {12'd0, m4} << (4 * w_slot);
            end
        endcase
    end
    // the next slot of the incoming word's list after w_slot (for the cursor advance)
    logic [2:0] w_next_slot;
    always_comb begin
        w_next_slot = 3'd4;
        for (int b = 3; b >= 0; b--) if (uses[w_lx][b] && b[1:0] > w_slot) w_next_slot = b[2:0];
    end

    // ---- the intake FSM -----------------------------------------------------------------
    logic        mvd_comp;                 // 0: x next, 1: y next
    logic signed [15:0] mvd_x;
    // the y word's write mask and cursor advance, computed on the x word and registered
    // (P5b timing: fifo word -> list cursor -> slot shape -> mask -> pend_mask was one
    // cycle). Valid because x and y of one mvd are consecutive words of the same list and
    // the x word itself leaves the cursor where y reads it: w_slot is mv_after on a first
    // x (the cursor then starts there) and mv_slot otherwise, w_sub 0 / mv_sub alike.
    logic [15:0] q_mask;
    logic [1:0]  q_slot, q_sub1;
    logic        q_more;                   // another sub-partition of this slot follows
    logic [2:0]  q_next_slot;
    logic [3:0]  i4_blk;
    logic [4:0]  blk_slot;                 // the coefficient slot being filled
    logic [8:0]  blk_pos;                  // position within the block (or PCM sample)
    logic        blk_pcm;
    logic        blk_l8;                   // an 8x8 block: 64 levels over four slots
    logic [5:0]  base;
    always_comb base = (slice_type == ST_P) ? 6'd5 : (slice_type == ST_B) ? 6'd23 : 6'd0;
    wire  [5:0]  it_w = in_val[5:0] - base;
    wire  [4:0]  i16_t = it_w[4:0] - 5'd1;

    // the mvd RAM and its expanding writer
    logic [31:0] mvd_ram [0:63];           // two banks of 32 ({bank, lx, blk})
    logic [15:0] pend_mask;                // blocks still to write with pend_data
    logic [31:0] pend_data;
    logic        pend_lx;
    logic [3:0]  pend_blk;
    always_comb begin
        pend_blk = 4'd0;
        for (int b = 15; b >= 0; b--) if (pend_mask[b]) pend_blk = b[3:0];
    end
    always_ff @(posedge clk) begin
        if (pend_mask != 16'd0) mvd_ram[{wb, pend_lx, pend_blk}] <= pend_data;
        mvd_q <= mvd_ram[{rb, mvd_ra}];
    end
    assign in_ready = !w_done && (pend_mask == 16'd0) && !ty_hold;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mb_valid <= 1'b0; err_order <= 1'b0;
            w_addr <= '0; w_skip <= 1'b0; w_type <= '0; w_sub_types <= '0; w_is_intra <= 1'b0; w_itype <= '0;
            w_cbp <= '0; w_qp_delta <= '0; w_chroma_mode <= '0; w_end_of_slice <= 1'b0; w_prev_flag <= '0;
            w_rem_mode <= '0; w_refs <= '0; w_pred <= '0; w_direct8 <= '0; w_coded <= '0;
            pend_mask <= '0; pend_data <= '0; pend_lx <= 1'b0;
            w_nz <= '0; w_pcm <= 1'b0; w_t8 <= 1'b0; mb_t8 <= 1'b0; blk_l8 <= 1'b0;
            ref_next[0] <= '0; ref_next[1] <= '0; mv_slot[0] <= '0; mv_slot[1] <= '0; mv_sub[0] <= '0; mv_sub[1] <= '0;
            mv_started[0] <= 1'b0; mv_started[1] <= 1'b0; mvd_comp <= 1'b0; mvd_x <= '0; i4_blk <= '0;
            q_mask <= '0; q_slot <= '0; q_sub1 <= '0; q_more <= 1'b0; q_next_slot <= '0;
            blk_slot <= '0; blk_pos <= '0; blk_pcm <= 1'b0;
            cram_we <= 1'b0; cram_waddr <= '0; cram_wdata <= '0; ty_hold <= 1'b0; cram_wb <= '0; cwb <= '0; mb_cbank <= '0;
            w_done <= 1'b0; wb <= 1'b0;
            mb_addr <= '0; mb_skip <= 1'b0; mb_type <= '0; mb_sub_types <= '0; mb_is_intra <= 1'b0; mb_itype <= '0;
            mb_cbp <= '0; mb_qp_delta <= '0; mb_chroma_mode <= '0; mb_end_of_slice <= 1'b0; mb_prev_flag <= '0;
            mb_rem_mode <= '0; mb_refs <= '0; mb_pred <= '0; mb_direct8 <= '0; mb_coded <= '0; mb_nz <= '0; mb_pcm <= 1'b0;
        end else begin
            cram_we <= 1'b0;
            // a word that changes the layout's inputs: the next word waits for the register
            ty_hold <= in_valid && in_ready && (in_kind == SE_MB_START || in_kind == SE_MB_TYPE || in_kind == SE_SUB_MB_TYPE);
            err_order <= 1'b0;
            if (mb_release) mb_valid <= 1'b0;
            // the working descriptor to the output stage, the RAM banks swapped
            if (w_done && !mb_valid) begin
                mb_valid <= 1'b1; w_done <= 1'b0; wb <= !wb; mb_cbank <= cwb; cwb <= cwb + 2'd1;
                mb_addr <= w_addr; mb_skip <= w_skip; mb_type <= w_type; mb_sub_types <= w_sub_types;
                mb_is_intra <= w_is_intra; mb_itype <= w_itype; mb_cbp <= w_cbp; mb_qp_delta <= w_qp_delta;
                mb_chroma_mode <= w_chroma_mode; mb_end_of_slice <= w_end_of_slice; mb_prev_flag <= w_prev_flag;
                mb_rem_mode <= w_rem_mode; mb_refs <= w_refs; mb_pred <= w_pred; mb_direct8 <= w_direct8;
                mb_coded <= w_coded; mb_pcm <= w_pcm; mb_t8 <= w_t8;
                // 8.7.2.1: in an 8x8-transform macroblock bS 2 looks at the 8x8 block
                mb_nz <= w_t8 ? {{4{|w_nz[15:12]}}, {4{|w_nz[11:8]}}, {4{|w_nz[7:4]}}, {4{|w_nz[3:0]}}} : w_nz;
            end
            if (pend_mask != 16'd0) pend_mask <= pend_mask & ~(16'd1 << pend_blk);
            if (in_valid && in_ready) begin
                case (in_kind)
                    SE_MB_START: begin
                        w_addr <= in_val[13:0];
                        w_skip <= 1'b0; w_type <= '0; w_sub_types <= '0; w_is_intra <= 1'b0; w_itype <= '0;
                        w_cbp <= '0; w_qp_delta <= '0; w_chroma_mode <= '0; w_end_of_slice <= 1'b0;
                        w_prev_flag <= '0; w_rem_mode <= '0; w_refs <= '0; w_pred <= '0;
                        w_direct8 <= '0; w_coded <= '0; w_nz <= '0; w_pcm <= 1'b0; w_t8 <= 1'b0;
                        ref_next[0] <= '0; ref_next[1] <= '0; mv_started[0] <= 1'b0; mv_started[1] <= 1'b0;
                        mvd_comp <= 1'b0; i4_blk <= '0;
                    end
                    SE_SKIP: begin
                        w_skip <= in_val[0];
                        if (in_val[0] && slice_type == ST_B) w_direct8 <= 4'b1111;      // B_Skip is direct
                    end
                    SE_MB_TYPE: begin
                        w_type <= in_val[5:0];
                        w_is_intra <= (in_val[5:0] >= base);
                        w_itype <= it_w[4:0];
                        // Intra16x16's implied coded_block_pattern (Table 7-11): luma 15 for types
                        // 13..24, chroma ((type - 1) % 12) / 4
                        if (in_val[5:0] >= base && it_w[4:0] != 5'd0 && it_w[4:0] != 5'd25)
                            w_cbp <= {(i16_t >= 5'd12) ? ((i16_t - 5'd12) >> 2) : (i16_t >> 2),
                                       (i16_t >= 5'd12) ? 4'b1111 : 4'b0000};
                        if (slice_type == ST_B && in_val[5:0] == 6'd0) w_direct8 <= 4'b1111;   // B_Direct_16x16
                    end
                    SE_SUB_MB_TYPE: begin
                        w_sub_types <= {in_val[3:0], w_sub_types[15:4]};
                        w_direct8 <= {(slice_type == ST_B && in_val[3:0] == 4'd0), w_direct8[3:1]};
                    end
                    SE_PREV_INTRA: begin
                        w_prev_flag[i4_blk] <= in_val[0];
                        if (in_val[0]) i4_blk <= i4_blk + 1'b1;          // no rem follows
                    end
                    SE_REM_INTRA: begin
                        w_rem_mode[3*i4_blk +: 3] <= in_val[2:0];
                        i4_blk <= i4_blk + 1'b1;
                    end
                    SE_CHROMA_PRED: w_chroma_mode <= in_val[1:0];
                    SE_T8: w_t8 <= in_val[0];
                    SE_REF_L0, SE_REF_L1: begin
                        logic lx;
                        lx = (in_kind == SE_REF_L1);
                        if (ref_sel[lx][2]) err_order <= 1'b1;
                        else begin
                            w_refs[5*(4*lx + ref_sel[lx][1:0]) +: 5] <= in_val[4:0];
                            ref_next[lx] <= ref_sel[lx] + 3'd1;
                        end
                    end
                    SE_MVD_L0, SE_MVD_L1: begin
                        if (!mv_started[w_lx]) begin
                            if (mv_after[w_lx][2]) err_order <= 1'b1;
                            mv_started[w_lx] <= 1'b1; mv_slot[w_lx] <= mv_after[w_lx]; mv_sub[w_lx] <= 2'd0;
                        end
                        if (!mvd_comp) begin
                            mvd_x <= $signed(in_val);
                            mvd_comp <= 1'b1;
                            q_mask <= w_mask; q_slot <= w_slot; q_sub1 <= w_sub + 2'd1;
                            q_more <= ({1'b0, w_sub} + 3'd1 < w_nsubs); q_next_slot <= w_next_slot;
                        end else begin
                            pend_mask <= q_mask; pend_data <= {mvd_x, in_val}; pend_lx <= w_lx;
                            mvd_comp <= 1'b0;
                            // advance: the next sub-partition, else the next slot of this list
                            if (q_more) begin
                                mv_slot[w_lx] <= {1'b0, q_slot}; mv_sub[w_lx] <= q_sub1;
                            end else begin
                                mv_slot[w_lx] <= q_next_slot; mv_sub[w_lx] <= 2'd0;
                            end
                        end
                    end
                    SE_CBP: w_cbp <= in_val[5:0];
                    SE_QP_DELTA: w_qp_delta <= in_val[7:0];
                    SE_BLK_START: begin
                        blk_pos <= '0;
                        blk_pcm <= (in_aux[3:0] == BK_PCM);
                        blk_l8 <= (in_aux[3:0] == BK_L8);
                        case (in_aux[3:0])
                            BK_LDC: begin blk_slot <= 5'd0; w_coded[0] <= 1'b1; end
                            BK_L4:  begin blk_slot <= 5'd1 + {1'b0, in_aux[7:4]}; w_coded[5'd1 + {1'b0, in_aux[7:4]}] <= 1'b1; end
                            BK_CDC: begin blk_slot <= 5'd17 + {4'd0, in_aux[4]}; w_coded[5'd17 + {4'd0, in_aux[4]}] <= 1'b1; end
                            BK_CAC: begin blk_slot <= 5'd19 + {2'd0, in_aux[6:4]}; w_coded[5'd19 + {2'd0, in_aux[6:4]}] <= 1'b1; end
                            BK_PCM: begin blk_slot <= 5'd0; w_pcm <= 1'b1; end
                            BK_L8:  begin
                                // luma 4x4 slots 1 + 4 b8 .. 4 + 4 b8, 16 levels each in scan order
                                blk_slot <= 5'd1 + {1'b0, in_aux[5:4], 2'b00};
                                w_coded[5'd1 + {1'b0, in_aux[5:4], 2'b00} +: 4] <= 4'hF;
                            end
                            default: err_order <= 1'b1;
                        endcase
                        // an Intra16x16 luma AC block has 15 levels (scan positions 1..15),
                        // stored at positions 0..14 of its slot as the stream sends them
                    end
                    SE_COEF: begin
                        cram_we <= 1'b1; cram_wb <= cwb;
                        cram_waddr <= blk_pcm ? blk_pos : {blk_slot + (blk_l8 ? {3'd0, blk_pos[5:4]} : 5'd0), blk_pos[3:0]};
                        cram_wdata <= $signed(in_val);
                        blk_pos <= blk_pos + 1'b1;
                        if (!blk_pcm && blk_slot >= 5'd1 && blk_slot <= 5'd16 && in_val != 16'd0)
                            w_nz[blk_slot - 5'd1 + (blk_l8 ? {3'd0, blk_pos[5:4]} : 5'd0)] <= 1'b1;
                    end
                    SE_END_OF_SLICE: begin
                        w_end_of_slice <= in_val[0];
                        w_done <= 1'b1;
                        // the pred flags per 4x4 block from the slots' lists (0 for direct / skip / intra)
                        for (int b = 0; b < 16; b++) begin
                            logic [1:0] sl;
                            logic [1:0] ls;
                            case (shape)
                                SH_16X16: sl = 2'd0;
                                SH_16X8:  sl = (b >= 8) ? 2'd1 : 2'd0;
                                SH_8X16:  sl = b[2] ? 2'd1 : 2'd0;
                                default:  sl = b[3:2];
                            endcase
                            ls = slot_lists[sl];
                            if (w_is_intra || w_skip || (slice_type == ST_B && w_type == 6'd0)) ls = 2'b00;
                            w_pred[b] <= ls[0];
                            w_pred[16 + b] <= ls[1];
                        end
                    end
                    default: err_order <= 1'b1;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
