// h264/dec/mb_syntax.sv -- the macroblock layer of the H.264 Main-profile CABAC slice
// data (7.3.4, 7.3.5, 9.3.2, 9.3.3.1), driving cabac_engine and emitting a typed
// syntax-element stream.
//
// The executable specification is tools/h264_fe_ref.py (class SliceDecoder): every
// state below is one of its decision points, in its order, with the same ctxIdxInc
// derivations (clauses named there). The gate is bench/h264/run_mb_syntax.sh: real
// slices decoded by that model (tools/mb_syntax_golden.py) as the byte stream in and
// the exact SE stream out. docs/h264_frontend.md S4.
//
// Scope (the core's, docs/roadmap.md): Main and High (H264 Phase 5: transform_size_8x8_flag
// in both places of 7.3.5, Intra_8x8's four modes, the ctxBlockCat 5 residual -- no
// coded_block_flag in 4:2:0, Table 9-43's maps; docs/high_profile.md S4), frame and field
// pictures, no MBAFF, 4:2:0, num_ref_idx up to 32, PicWidthInMbs up to 128. Anything
// else is refused upstream (sps/pps/slice header).
//
// Neighbour state for the context derivations (6.4.11): the previous macroblock in
// decoding order is kept in registers (it is the left neighbour A whenever mb_x != 0,
// and prevMbAddr for mb_qp_delta); the row above is a 128-entry line memory (one
// synchronous read at each macroblock's start, one write at its end) holding what the
// B derivations need: the bottom row of 4x4 blocks (luma4x4BlkIdx 10, 11, 14, 15),
// chroma blocks 2 and 3 of each plane, the macroblock flags and the slice id (an
// entry is available iff its slice id is the current slice's). Per 4x4 block, per
// list: predFlag, ref_idx > 0, and |mvd| clipped to 33 per component -- all the
// ctxIdxInc rules ever ask (9.3.3.1.1.6/7: sums compared with 2 and 32) -- 6 bits
// each instead of a 16-bit motion vector difference.
//
// Engine cadence: one request outstanding; the next is issued the cycle after the
// response is consumed (about three cycles per dependent bin: 27 Mbins/s at 81 MHz
// against the 13 Mbins/s Level-3 ceiling). The SE output is a held valid/ready
// stream, one word per cycle at most: MB_START, the macroblock's SEs in syntax order,
// each residual block as BLK_START then its coefficients in scan order (zeros
// included), END_OF_SLICE. Kinds are tools/mb_syntax_golden.py's table.
//
// The residual block's levels (16, or 64 for an 8x8 block) are held in a 64 x 16 RAM
// written as each level is decoded (highest scan position first) and streamed out in scan
// order through a two-entry skid buffer (one coefficient a cycle), the significance map
// supplying the zeros; the level decode takes "the highest remaining significant
// position" of a mask that loses each position as it is decoded.
//
// exp/mb-pipeline (docs/mb_pipeline.md): emission is DECOUPLED -- the machine pushes jobs
// into a four-entry ordered queue (a word, or a block's coefficients) and an output process
// drains it; a block's levels are in one of TWO banks of the level RAM, so the next block
// decodes while this one streams (the stream's order is the queue's; done waits for it).
//
// Emission is generic (S_EMIT with a return state), as are the unary/TU prefix
// (S_TU_*), the Exp-Golomb suffix (S_EG_*) and the sign (S_SIGN) of the
// binarisations: an SE's states set the parameters and the return state.

`default_nettype none

module mb_syntax (
    input  wire        clk,
    input  wire        rst_n,

    // slice parameters, held from `start` to `done`
    input  wire  [1:0] sp_slice_type,     // 0 P, 1 B, 2 I
    input  wire  [5:0] sp_num_ref_l0,     // num_ref_idx_l0_active (1..32)
    input  wire  [5:0] sp_num_ref_l1,
    input  wire        sp_field,          // field_pic_flag
    input  wire  [7:0] sp_width_mbs,      // PicWidthInMbs
    input  wire  [7:0] sp_height_mbs,     // PicHeightInMbs of this picture (a field's own)
    input  wire [13:0] sp_first_mb,
    input  wire  [15:0] sp_slice_id,       // unique per slice; the row-above memory keys on it
    input  wire        sp_t8_mode,        // the PPS's transform_8x8_mode_flag (High)
    input  wire        sp_d8inf,          // the SPS's direct_8x8_inference_flag
    input  wire        start,             // the engine is initialised for the slice already
    output logic       done,
    output logic       err_overrun,       // the slice ran past the picture (sticky until start)
    output logic       err_bins,          // a binarisation ran past its spec maximum (a unary of
                                          // 63 bins, an Exp-Golomb prefix of 16): the slice is
                                          // abandoned -- a corrupt or truncated stream decoded
                                          // as zeros would otherwise loop forever (sticky until start)

    // cabac_engine
    output logic       eng_req_valid,
    input  wire        eng_req_ready,
    output logic [2:0] eng_req_kind,
    output logic [8:0] eng_req_ctx,
    input  wire        eng_rsp_valid,
    input  wire        eng_rsp_bin,
    input  wire  [7:0] eng_rsp_byte,

    // the syntax-element stream
    output logic       se_valid,
    input  wire        se_ready,
    output logic [7:0] se_kind,
    output logic [7:0] se_aux,
    output logic [15:0] se_val
);

    // ---- SE kinds (tools/mb_syntax_golden.py) ----------------------------------------
    localparam [7:0] SE_MB_START = 8'd1, SE_SKIP = 8'd2, SE_MB_TYPE = 8'd3, SE_SUB_MB_TYPE = 8'd4,
                     SE_PREV_INTRA = 8'd5, SE_REM_INTRA = 8'd6, SE_CHROMA_PRED = 8'd7,
                     SE_REF_L0 = 8'd8, SE_REF_L1 = 8'd9, SE_MVD_L0 = 8'd10, SE_MVD_L1 = 8'd11,
                     SE_CBP = 8'd12, SE_QP_DELTA = 8'd13, SE_BLK_START = 8'd14, SE_COEF = 8'd15,
                     SE_END_OF_SLICE = 8'd16, SE_T8 = 8'd20;
    localparam [2:0] K_DECISION = 3'd0, K_BYPASS = 3'd1, K_TERMINATE = 3'd2,
                     K_ALIGN = 3'd4, K_RAWBYTE = 3'd5, K_REINIT = 3'd6;
    localparam [1:0] ST_P = 2'd0, ST_B = 2'd1, ST_I = 2'd2;
    localparam [3:0] BK_LDC = 4'd0, BK_L4 = 4'd1, BK_CDC = 4'd2, BK_CAC = 4'd3, BK_PCM = 4'd4, BK_L8 = 4'd5;

    // ---- states ----------------------------------------------------------------------
    // states (plain constants: Icarus will not take a ternary of enum literals as an enum)
    typedef logic [6:0] state_t;
    localparam state_t S_IDLE = 7'd0;
    localparam state_t S_MB_BEGIN = 7'd1;
    localparam state_t S_MB_LOAD = 7'd2;
    localparam state_t S_MB_START_EMIT = 7'd3;
    localparam state_t S_SKIP = 7'd4;
    localparam state_t S_SKIP_EMIT = 7'd5;
    localparam state_t S_MBT_P0 = 7'd6;
    localparam state_t S_MBT_P1 = 7'd7;
    localparam state_t S_MBT_P2 = 7'd8;
    localparam state_t S_MBT_P3 = 7'd9;
    localparam state_t S_MBT_B0 = 7'd10;
    localparam state_t S_MBT_B1 = 7'd11;
    localparam state_t S_MBT_B2A = 7'd12;
    localparam state_t S_MBT_B2B = 7'd13;
    localparam state_t S_MBT_B3 = 7'd14;
    localparam state_t S_MBT_B6 = 7'd15;
    localparam state_t S_MBT_I0 = 7'd16;
    localparam state_t S_MBT_I1 = 7'd17;
    localparam state_t S_MBT_I2 = 7'd18;
    localparam state_t S_MBT_I3 = 7'd19;
    localparam state_t S_MBT_I4 = 7'd20;
    localparam state_t S_MBT_I5 = 7'd21;
    localparam state_t S_MBT_I6 = 7'd22;
    localparam state_t S_MBT_DONE = 7'd23;
    localparam state_t S_MBT_EMIT = 7'd24;
    localparam state_t S_I4_FLAG = 7'd25;
    localparam state_t S_I4_REM = 7'd26;
    localparam state_t S_I4_EMIT_REM = 7'd27;
    localparam state_t S_CHROMA_TU = 7'd28;
    localparam state_t S_CHROMA_EMIT = 7'd29;
    localparam state_t S_SUB_B0 = 7'd30;
    localparam state_t S_SUB_B1 = 7'd31;
    localparam state_t S_SUB_B2 = 7'd32;
    localparam state_t S_SUB_B3 = 7'd33;
    localparam state_t S_SUB_B4 = 7'd34;
    localparam state_t S_SUB_B5 = 7'd35;
    localparam state_t S_SUB_P0 = 7'd36;
    localparam state_t S_SUB_P1 = 7'd37;
    localparam state_t S_SUB_P2 = 7'd38;
    localparam state_t S_SUB_DONE = 7'd39;
    localparam state_t S_REF_NEXT = 7'd40;
    localparam state_t S_REF_TU = 7'd41;
    localparam state_t S_REF_EMIT = 7'd42;
    localparam state_t S_MVD_NEXT = 7'd43;
    localparam state_t S_MVD_TU = 7'd44;
    localparam state_t S_MVD_EG = 7'd45;
    localparam state_t S_MVD_SIGN = 7'd46;
    localparam state_t S_MVD_EMIT = 7'd47;
    localparam state_t S_CBP_LUMA = 7'd48;
    localparam state_t S_CBP_C0 = 7'd49;
    localparam state_t S_CBP_C1 = 7'd50;
    localparam state_t S_CBP_EMIT = 7'd51;
    localparam state_t S_QPD_TU = 7'd52;
    localparam state_t S_QPD_EMIT = 7'd53;
    localparam state_t S_RB_NEXT = 7'd54;
    localparam state_t S_RB_CBF = 7'd55;
    localparam state_t S_RB_SIG = 7'd56;
    localparam state_t S_RB_LAST = 7'd57;
    localparam state_t S_RB_LEVEL_FIND = 7'd58;
    localparam state_t S_RB_LEVEL_TU = 7'd59;
    localparam state_t S_RB_LEVEL_EG = 7'd60;
    localparam state_t S_RB_LEVEL_SIGN = 7'd61;
    localparam state_t S_RB_EMIT_START = 7'd62;
    localparam state_t S_RB_EMIT_COEF = 7'd63;
    localparam state_t S_PCM_ALIGN = 7'd64;
    localparam state_t S_PCM_START = 7'd65;
    localparam state_t S_PCM_BYTE = 7'd66;
    localparam state_t S_PCM_EMIT = 7'd67;
    localparam state_t S_PCM_REINIT = 7'd68;
    localparam state_t S_EOS = 7'd69;
    localparam state_t S_EOS_EMIT = 7'd70;
    localparam state_t S_MB_END = 7'd71;
    localparam state_t S_DONE = 7'd72;
    localparam state_t S_EMIT = 7'd73;
    localparam state_t S_TU = 7'd74;
    localparam state_t S_EG_PREFIX = 7'd75;
    localparam state_t S_EG_SUFFIX = 7'd76;
    localparam state_t S_SIGN = 7'd77;
    localparam state_t S_MB_POS = 7'd78;
    localparam state_t S_MVD_CTX = 7'd79;  // the mvd context increment registered before S_MVD_TU   // one cycle before S_MB_BEGIN: its position test settles
    localparam state_t S_T8 = 7'd80;       // transform_size_8x8_flag (9.3.3.1.1.10)
    localparam state_t S_MVD_CTX2 = 7'd81; // P5b: the mvd neighbours registered (S_MVD_CTX), then summed
    state_t state, ret_state, ret2_state;

    // ---- slice parameters (latched) ----------------------------------------------------
    logic [1:0]  slice_type;
    logic [5:0]  num_ref [0:1];
    logic        field;
    logic [7:0]  width_mbs, height_mbs;
    logic        pos_eq_q, pos_ge_q;       // S_MB_BEGIN's position test, registered
    logic [7:0]  pos_x_q;
    logic [15:0] slice_id;
    logic        t8_mode, d8inf;           // transform_8x8_mode_flag, direct_8x8_inference_flag
    logic [13:0] mb_addr;
    logic [7:0]  mb_x, mb_y;
    logic [13:0] row_base;                 // mb_y * PicWidthInMbs, kept beside every change of
                                           // mb_y (P5b timing: the product in front of the
                                           // position test was a DSP multiply, 9.7 ns); 14
                                           // bits wrap exactly as the product's did
    logic        prev_valid;             // a previous macroblock of this slice exists

    // ---- the engine request / response --------------------------------------------------
    logic        rq_wait, rq_sent;
    logic        bin;                    // the last response bin
    assign eng_req_valid = rq_wait && !rq_sent;
    wire rsp = rq_wait && eng_rsp_valid;

    // ---- SE emission: the job queue (the machine pushes, the output process pops) --------
    logic em_wait;                         // the output head is valid
    assign se_valid = em_wait;
    logic        jq_typ [0:3];             // 0 a word, 1 a block's coefficients
    logic [7:0]  jq_kind [0:3];
    logic [7:0]  jq_aux [0:3];
    logic [15:0] jq_val [0:3];
    logic        jq_bank [0:3];
    logic [6:0]  jq_n [0:3];
    logic [2:0]  jq_t, jq_h;               // tail (the machine's), head (the output's)
    wire  [2:0]  jq_cnt = jq_t - jq_h;
    wire         jq_room = !jq_cnt[2];
    logic [7:0]  pw_kind, pw_aux;          // the word S_EMIT pushes
    logic [15:0] pw_val;
    logic        wbk;                      // the level RAM bank the machine decodes into
    logic [1:0]  bk_tok, bk_done;          // per bank: toggled at the push / when streamed
    wire  [1:0]  bk_busy = bk_tok ^ bk_done;
    logic [63:0] sigb [0:1];               // the significance map of each bank's block
    logic        eo_busy;                  // the output process holds a job

    // ---- the current / previous macroblock records ---------------------------------------
    logic        c_skip, c_intra, c_i16, c_pcm, c_direct16, c_chroma_nz, c_cbf_dc, c_qpd_nz, c_is8x8;
    logic        c_t8;                   // transform_size_8x8_flag
    logic        c_nosub;                // noSubMbPartSizeLessThan8x8Flag (7.3.5)
    state_t      t8_ret;                 // where S_T8 goes on (the modes, or mb_qp_delta)
    logic [5:0]  c_mb_type;
    logic [5:0]  c_cbp;
    logic [1:0]  c_cbf_cdc;
    logic [7:0]  c_cbf_cac;              // Cb 0-3, Cr 4-7
    logic [15:0] c_cbf_luma;
    logic [15:0] c_pred0, c_pred1, c_ref0gt, c_ref1gt;
    logic [5:0]  c_mvd0x [0:15];
    logic [5:0]  c_mvd0y [0:15];
    logic [5:0]  c_mvd1x [0:15];
    logic [5:0]  c_mvd1y [0:15];
    logic [1:0]  c_sub_pred [0:3];       // per 8x8: bit 0 list 0, bit 1 list 1 (0 = direct)
    logic [1:0]  c_sub_shape [0:3];      // 0 8x8, 1 8x4, 2 4x8, 3 4x4
    logic [1:0]  c_shape;                // 0 16x16, 1 16x8, 2 8x16
    logic [1:0]  c_part_pred [0:1];

    logic        p_skip, p_intra, p_i16, p_pcm, p_direct16, p_chroma_nz, p_cbf_dc, p_qpd_nz, p_t8;
    logic [5:0]  p_cbp;
    logic [1:0]  p_cbf_cdc;
    logic [7:0]  p_cbf_cac;
    logic [15:0] p_cbf_luma;
    logic [15:0] p_pred0, p_pred1, p_ref0gt, p_ref1gt;
    logic [5:0]  p_mvd0x [0:15];
    logic [5:0]  p_mvd0y [0:15];
    logic [5:0]  p_mvd1x [0:15];
    logic [5:0]  p_mvd1y [0:15];

    // ---- the row above: 128 x 152-bit line memory --------------------------------------
    // entry: slice_id[15:0] skip intra i16 pcm direct16 cbp[5:0] chroma_nz cbf_dc cbf_cdc[1:0]
    //        cbf_cac{Cb2,Cb3,Cr2,Cr3} cbf_luma{10,11,14,15} then 4 blocks (10,11,14,15) x
    //        {pred0 pred1 ref0gt ref1gt mvd0x mvd0y mvd1x mvd1y}, then t8 (bit 0)
    localparam int AW = 16 + 5 + 6 + 1 + 1 + 2 + 4 + 4 + 4 * 28 + 1;   // 152
    logic [AW-1:0] above_mem [0:127];
    logic [AW-1:0] above_q, above_wd;
    logic        a_avail, a_skip, a_intra, a_i16, a_pcm, a_direct16, a_chroma_nz, a_cbf_dc, a_t8;
    logic [5:0]  a_cbp;
    logic [1:0]  a_cbf_cdc;
    logic [3:0]  a_cbf_cac, a_cbf_luma, a_pred0, a_pred1, a_ref0gt, a_ref1gt;
    logic [5:0]  a_mvd0x [0:3];
    logic [5:0]  a_mvd0y [0:3];
    logic [5:0]  a_mvd1x [0:3];
    logic [5:0]  a_mvd1y [0:3];
    logic        above_we;
    logic [6:0]  above_wa;               // latched with above_we: mb_x has moved on by then
    // which entries hold this picture's rows: cleared when a slice starts at MB 0 (a new
    // picture or field), so neither the previous picture's rows nor never-written memory
    // can ever look available (a slice id match on garbage would)
    logic [127:0] above_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) above_valid <= 128'd0;
        else if (start && sp_first_mb == 14'd0) above_valid <= 128'd0;
        else if (above_we) above_valid[above_wa] <= 1'b1;
    end
    always_ff @(posedge clk) begin
        pos_eq_q <= ({6'd0, mb_x} + row_base == mb_addr);
        pos_ge_q <= (mb_addr - row_base >= {6'd0, width_mbs});
        pos_x_q  <= mb_addr[7:0] - row_base[7:0];
    end
    always_ff @(posedge clk) begin
        if (above_we) above_mem[above_wa] <= above_wd;
        if (state == S_MB_BEGIN) above_q <= above_mem[mb_x[6:0]];
    end
    always_comb begin
        above_wd = {slice_id, c_skip, c_intra, c_i16, c_pcm, c_direct16, c_cbp, c_chroma_nz, c_cbf_dc, c_cbf_cdc,
                    c_cbf_cac[7], c_cbf_cac[6], c_cbf_cac[3], c_cbf_cac[2],       // -> a_cbf_cac[0] = Cb2 .. [3] = Cr3
                    c_cbf_luma[15], c_cbf_luma[14], c_cbf_luma[11], c_cbf_luma[10],   // -> a_cbf_luma[0] = block 10 (slot order)
                    c_pred0[10], c_pred1[10], c_ref0gt[10], c_ref1gt[10], c_mvd0x[10], c_mvd0y[10], c_mvd1x[10], c_mvd1y[10],
                    c_pred0[11], c_pred1[11], c_ref0gt[11], c_ref1gt[11], c_mvd0x[11], c_mvd0y[11], c_mvd1x[11], c_mvd1y[11],
                    c_pred0[14], c_pred1[14], c_ref0gt[14], c_ref1gt[14], c_mvd0x[14], c_mvd0y[14], c_mvd1x[14], c_mvd1y[14],
                    c_pred0[15], c_pred1[15], c_ref0gt[15], c_ref1gt[15], c_mvd0x[15], c_mvd0y[15], c_mvd1x[15], c_mvd1y[15],
                    c_t8};
    end

    // ---- macroblock-level neighbour views ------------------------------------------------
    wire left_avail = prev_valid && (mb_x != 8'd0);
    // (the previous macroblock is in this slice by construction; it is the left one iff
    //  this is not the first of a row)

    // ---- binarisation sub-machine parameters --------------------------------------------
    logic [8:0]  tu_base;                // ctxIdxOffset (+ block category offset)
    logic [3:0]  tu_inc0, tu_inc1, tu_cap;
    logic [4:0]  tu_cmax;                // 0: unbounded (U)
    logic [5:0]  tu_bin;                 // binIdx: mb_qp_delta's U binarisation runs to 52 bins
                                         // (-26..25, Table 9-3) -- a 5-bit counter wrapped and the
                                         // context fell back to bin 0's (found by a crf-encoded clip)
    logic [15:0] tu_val;                 // the unary count / the value under construction
    logic [3:0]  eg_k;
    logic        val_neg;

    // ---- SE-level scratch ------------------------------------------------------------------
    logic [3:0]  i4_idx;                 // intra 4x4 block, rem bins
    logic [2:0]  rem_val;
    logic [1:0]  rem_bit;
    logic [3:0]  mbt_bits;               // the bins of the B mb_type tree
    logic        mbt_ac;
    logic [1:0]  mbt_chroma, mbt_pred;
    logic [8:0]  mbt_off;                // the I-tree offset (3, 17 or 32)
    logic [5:0]  mbt_add;                // 0 / 5 / 23
    logic [1:0]  sub_idx;                // sub_mb_type being decoded
    logic [3:0]  sub_t;
    logic [1:0]  sub_bits;
    logic        lx;                     // list of the current ref/mvd loop
    logic [1:0]  unit;                   // partition / 8x8 index
    logic [1:0]  sub;                    // sub-partition index
    logic        comp;                   // mvd component
    logic [3:0]  cbp_b8;
    logic [5:0]  cbp_acc;
    logic [4:0]  rb_phase_i;             // residual block cursor: index within a phase
    logic [2:0]  rb_phase;               // 0 LDC, 1 luma, 2 chroma DC, 3 chroma AC, 4 done
    logic [3:0]  rb_kind;
    logic [3:0]  rb_idx;
    logic [2:0]  rb_cat;
    logic [6:0]  rb_n;                   // coefficients of the block (4, 15, 16 or 64)
    logic [6:0]  rb_i;                   // scan position under decode / emission
    logic [63:0] rb_sig;                 // the significance map
    logic [63:0] rb_rem;                 // significant positions whose level is still to decode
    logic [6:0]  rb_num;                 // numCoeff after the last flag
    logic [3:0]  rb_eq1, rb_gt1;
    logic [8:0]  pcm_i;
    // the levels: a 64 x 16 RAM (write: the level decoded at rb_i; read: the emission
    // stream's position em_rp -- a register -- its word the cycle after)
    logic signed [15:0] coef_m [0:127];  // exp/mb-pipeline: two banks {bank, position}
    logic        cm_we;
    logic        cm_wb;                  // the bank of the write
    logic [5:0]  cm_wa;
    logic signed [15:0] cm_wd, cm_q;
    logic [6:0]  em_rp;                  // the next position the emission stream reads
    logic        eo_bank;                // ... in this bank
    logic [6:0]  eo_n;                   // ... of this many
    always_ff @(posedge clk) begin
        if (cm_we) coef_m[{cm_wb, cm_wa}] <= cm_wd;
        cm_q <= coef_m[{eo_bank, em_rp[5:0]}];
    end
    // the emission stream: position em_rp read (em_rv: its word lands THIS cycle, with its
    // significance em_sv and last flag em_lv), into a two-entry buffer: the head is the SE
    // output register itself (se_val, em_wait = valid, eb_l0 = it is the last), eb_v1 the
    // skid entry. A read is issued while the occupancy after this cycle's pop stays below
    // two, which sustains one coefficient a cycle with the RAM's one-cycle read.
    logic        em_rv, em_sv, em_lv;
    logic [15:0] eb_v1;
    logic        eb_l0, eb_l1;
    logic [1:0]  eb_n;                   // entries held (head + skid)
    logic        em_run;                 // the output process streams a block

    // ---- combinational helpers ----------------------------------------------------------------

    // luma 4x4 neighbour of block b: (in prev MB?, in above MB?, neighbour index; for the
    // above MB the index is the slot 0..3 of blocks 10, 11, 14, 15)
    logic [3:0] nbA_idx, nbB_idx;
    logic       nbA_prev, nbB_above;
    logic [3:0] mv_query;                // the partition's first block, set by the ref/mvd loops
    // Two copies of the tables: the ref/mvd loops ask for their partition's first block
    // (mv_query), the coded_block_flag contexts for the residual block (rb_idx). One table
    // behind a state-selected index (`state == S_RB_CBF ? rb_idx : mv_query`, fanout 110)
    // was the clk_dec 103.85 binding path into eng_req_ctx (9.3 ns): the playbook's "separate
    // muxes per state class" (docs/hw_budget_and_lessons.md S5). One driver per copy (the
    // first draft assigned one index from two always blocks and the cbf one silently won --
    // the mvd y contexts lost the x/y of the partition before).
    logic [3:0] rbA_idx, rbB_idx;        // the coded_block_flag side's copy (rb_idx)
    logic       rbA_prev, rbB_above;
    always_comb begin
        case (mv_query)
            4'd0:  begin nbA_prev = 1; nbA_idx = 4'd5;  end
            4'd1:  begin nbA_prev = 0; nbA_idx = 4'd0;  end
            4'd2:  begin nbA_prev = 1; nbA_idx = 4'd7;  end
            4'd3:  begin nbA_prev = 0; nbA_idx = 4'd2;  end
            4'd4:  begin nbA_prev = 0; nbA_idx = 4'd1;  end
            4'd5:  begin nbA_prev = 0; nbA_idx = 4'd4;  end
            4'd6:  begin nbA_prev = 0; nbA_idx = 4'd3;  end
            4'd7:  begin nbA_prev = 0; nbA_idx = 4'd6;  end
            4'd8:  begin nbA_prev = 1; nbA_idx = 4'd13; end
            4'd9:  begin nbA_prev = 0; nbA_idx = 4'd8;  end
            4'd10: begin nbA_prev = 1; nbA_idx = 4'd15; end
            4'd11: begin nbA_prev = 0; nbA_idx = 4'd10; end
            4'd12: begin nbA_prev = 0; nbA_idx = 4'd9;  end
            4'd13: begin nbA_prev = 0; nbA_idx = 4'd12; end
            4'd14: begin nbA_prev = 0; nbA_idx = 4'd11; end
            default: begin nbA_prev = 0; nbA_idx = 4'd14; end
        endcase
        case (mv_query)
            4'd0:  begin nbB_above = 1; nbB_idx = 4'd0;  end   // block 10
            4'd1:  begin nbB_above = 1; nbB_idx = 4'd1;  end   // block 11
            4'd2:  begin nbB_above = 0; nbB_idx = 4'd0;  end
            4'd3:  begin nbB_above = 0; nbB_idx = 4'd1;  end
            4'd4:  begin nbB_above = 1; nbB_idx = 4'd2;  end   // block 14
            4'd5:  begin nbB_above = 1; nbB_idx = 4'd3;  end   // block 15
            4'd6:  begin nbB_above = 0; nbB_idx = 4'd4;  end
            4'd7:  begin nbB_above = 0; nbB_idx = 4'd5;  end
            4'd8:  begin nbB_above = 0; nbB_idx = 4'd2;  end
            4'd9:  begin nbB_above = 0; nbB_idx = 4'd3;  end
            4'd10: begin nbB_above = 0; nbB_idx = 4'd8;  end
            4'd11: begin nbB_above = 0; nbB_idx = 4'd9;  end
            4'd12: begin nbB_above = 0; nbB_idx = 4'd6;  end
            4'd13: begin nbB_above = 0; nbB_idx = 4'd7;  end
            4'd14: begin nbB_above = 0; nbB_idx = 4'd12; end
            default: begin nbB_above = 0; nbB_idx = 4'd13; end
        endcase
    end
    always_comb begin
        case (rb_idx)
            4'd0:  begin rbA_prev = 1; rbA_idx = 4'd5;  end
            4'd1:  begin rbA_prev = 0; rbA_idx = 4'd0;  end
            4'd2:  begin rbA_prev = 1; rbA_idx = 4'd7;  end
            4'd3:  begin rbA_prev = 0; rbA_idx = 4'd2;  end
            4'd4:  begin rbA_prev = 0; rbA_idx = 4'd1;  end
            4'd5:  begin rbA_prev = 0; rbA_idx = 4'd4;  end
            4'd6:  begin rbA_prev = 0; rbA_idx = 4'd3;  end
            4'd7:  begin rbA_prev = 0; rbA_idx = 4'd6;  end
            4'd8:  begin rbA_prev = 1; rbA_idx = 4'd13; end
            4'd9:  begin rbA_prev = 0; rbA_idx = 4'd8;  end
            4'd10: begin rbA_prev = 1; rbA_idx = 4'd15; end
            4'd11: begin rbA_prev = 0; rbA_idx = 4'd10; end
            4'd12: begin rbA_prev = 0; rbA_idx = 4'd9;  end
            4'd13: begin rbA_prev = 0; rbA_idx = 4'd12; end
            4'd14: begin rbA_prev = 0; rbA_idx = 4'd11; end
            default: begin rbA_prev = 0; rbA_idx = 4'd14; end
        endcase
        case (rb_idx)
            4'd0:  begin rbB_above = 1; rbB_idx = 4'd0;  end   // block 10
            4'd1:  begin rbB_above = 1; rbB_idx = 4'd1;  end   // block 11
            4'd2:  begin rbB_above = 0; rbB_idx = 4'd0;  end
            4'd3:  begin rbB_above = 0; rbB_idx = 4'd1;  end
            4'd4:  begin rbB_above = 1; rbB_idx = 4'd2;  end   // block 14
            4'd5:  begin rbB_above = 1; rbB_idx = 4'd3;  end   // block 15
            4'd6:  begin rbB_above = 0; rbB_idx = 4'd4;  end
            4'd7:  begin rbB_above = 0; rbB_idx = 4'd5;  end
            4'd8:  begin rbB_above = 0; rbB_idx = 4'd2;  end
            4'd9:  begin rbB_above = 0; rbB_idx = 4'd3;  end
            4'd10: begin rbB_above = 0; rbB_idx = 4'd8;  end
            4'd11: begin rbB_above = 0; rbB_idx = 4'd9;  end
            4'd12: begin rbB_above = 0; rbB_idx = 4'd6;  end
            4'd13: begin rbB_above = 0; rbB_idx = 4'd7;  end
            4'd14: begin rbB_above = 0; rbB_idx = 4'd12; end
            default: begin rbB_above = 0; rbB_idx = 4'd13; end
        endcase
    end

    // ref_idx / mvd neighbour data (9.3.3.1.1.6 / 7) for block mv_query, list lx, component comp
    logic nA_ok, nB_ok;                  // available, inter, not skip, not direct, predFlagLX
    logic nA_refgt, nB_refgt;
    logic [5:0] nA_mvd, nB_mvd;
    always_comb begin
        // A
        if (nbA_prev) begin
            nA_ok = left_avail && !p_skip && !p_intra && !p_direct16 && (lx ? p_pred1[nbA_idx] : p_pred0[nbA_idx]);
            nA_refgt = lx ? p_ref1gt[nbA_idx] : p_ref0gt[nbA_idx];
            nA_mvd = lx ? (comp ? p_mvd1y[nbA_idx] : p_mvd1x[nbA_idx]) : (comp ? p_mvd0y[nbA_idx] : p_mvd0x[nbA_idx]);
        end else begin
            nA_ok = (lx ? c_pred1[nbA_idx] : c_pred0[nbA_idx]);
            nA_refgt = lx ? c_ref1gt[nbA_idx] : c_ref0gt[nbA_idx];
            nA_mvd = lx ? (comp ? c_mvd1y[nbA_idx] : c_mvd1x[nbA_idx]) : (comp ? c_mvd0y[nbA_idx] : c_mvd0x[nbA_idx]);
        end
        // B
        if (nbB_above) begin
            nB_ok = a_avail && !a_skip && !a_intra && !a_direct16 && (lx ? a_pred1[nbB_idx[1:0]] : a_pred0[nbB_idx[1:0]]);
            nB_refgt = lx ? a_ref1gt[nbB_idx[1:0]] : a_ref0gt[nbB_idx[1:0]];
            nB_mvd = lx ? (comp ? a_mvd1y[nbB_idx[1:0]] : a_mvd1x[nbB_idx[1:0]]) : (comp ? a_mvd0y[nbB_idx[1:0]] : a_mvd0x[nbB_idx[1:0]]);
        end else begin
            nB_ok = (lx ? c_pred1[nbB_idx] : c_pred0[nbB_idx]);
            nB_refgt = lx ? c_ref1gt[nbB_idx] : c_ref0gt[nbB_idx];
            nB_mvd = lx ? (comp ? c_mvd1y[nbB_idx] : c_mvd1x[nbB_idx]) : (comp ? c_mvd0y[nbB_idx] : c_mvd0x[nbB_idx]);
        end
    end
    wire [3:0] ref_inc = (nA_ok && nA_refgt ? 4'd1 : 4'd0) + (nB_ok && nB_refgt ? 4'd2 : 4'd0);
    // the mvd neighbours registered before the sum (P5b: the state-selected neighbour query,
    // its 16:1 reads, the sum and the thresholds in one cycle were 11.0 ns): S_MVD_CTX
    // registers them, S_MVD_CTX2 the increment
    logic       mA_ok, mB_ok;
    logic [5:0] mA_mvd, mB_mvd;
    always_ff @(posedge clk) begin mA_ok <= nA_ok; mB_ok <= nB_ok; mA_mvd <= nA_mvd; mB_mvd <= nB_mvd; end
    wire [6:0] mvd_sum = (mA_ok ? {1'b0, mA_mvd} : 7'd0) + (mB_ok ? {1'b0, mB_mvd} : 7'd0);
    wire [3:0] mvd_inc = (mvd_sum > 7'd32) ? 4'd2 : (mvd_sum > 7'd2) ? 4'd1 : 4'd0;
    logic [3:0] mvd_inc_q;
    always_ff @(posedge clk) mvd_inc_q <= mvd_inc;

    // the partition / sub-partition tables (7.4.5, Tables 7-13, 7-14, 7-17, 7-18)
    logic [1:0]  unit_pred;
    logic [1:0]  unit_nsub;              // sub-partitions - 1 (0..3)
    logic [3:0]  sub_first;              // first 4x4 block of (unit, sub)
    logic [15:0] sub_mask;
    logic [3:0]  unit_first;
    logic [1:0]  n_units;                // units - 1
    always_comb begin
        if (c_is8x8) begin
            n_units = 2'd3;
            unit_pred = c_sub_pred[unit];
            unit_first = {unit, 2'b00};
            case (c_sub_shape[unit])
                2'd0: begin unit_nsub = 2'd0; sub_first = {unit, 2'b00}; sub_mask = 16'h000F << {unit, 2'b00}; end
                2'd1: begin unit_nsub = 2'd1; sub_first = {unit, sub[0], 1'b0}; sub_mask = (sub[0] ? 16'h000C : 16'h0003) << {unit, 2'b00}; end
                2'd2: begin unit_nsub = 2'd1; sub_first = {unit, 1'b0, sub[0]}; sub_mask = (sub[0] ? 16'h000A : 16'h0005) << {unit, 2'b00}; end
                default: begin unit_nsub = 2'd3; sub_first = {unit, sub}; sub_mask = 16'h0001 << {unit, sub}; end
            endcase
        end else begin
            unit_nsub = 2'd0;
            unit_pred = c_part_pred[unit[0]];
            case (c_shape)
                2'd0: begin n_units = 2'd0; unit_first = 4'd0; sub_first = 4'd0; sub_mask = 16'hFFFF; end
                2'd1: begin n_units = 2'd1; unit_first = unit[0] ? 4'd8 : 4'd0; sub_first = unit_first; sub_mask = unit[0] ? 16'hFF00 : 16'h00FF; end
                default: begin n_units = 2'd1; unit_first = unit[0] ? 4'd4 : 4'd0; sub_first = unit_first; sub_mask = unit[0] ? 16'hF0F0 : 16'h0F0F; end
            endcase
        end
    end

    // the B mb_type 4..21 pairs (Table 7-14): k = mb_type - 4, pair index k >> 1
    logic [1:0] pair_p0, pair_p1;
    wire [4:0] pair_k = c_mb_type[4:0] - 5'd4;
    always_comb begin
        case (pair_k[4:1])
            4'd0: begin pair_p0 = 2'd1; pair_p1 = 2'd1; end
            4'd1: begin pair_p0 = 2'd2; pair_p1 = 2'd2; end
            4'd2: begin pair_p0 = 2'd1; pair_p1 = 2'd2; end
            4'd3: begin pair_p0 = 2'd2; pair_p1 = 2'd1; end
            4'd4: begin pair_p0 = 2'd1; pair_p1 = 2'd3; end
            4'd5: begin pair_p0 = 2'd2; pair_p1 = 2'd3; end
            4'd6: begin pair_p0 = 2'd3; pair_p1 = 2'd1; end
            4'd7: begin pair_p0 = 2'd3; pair_p1 = 2'd2; end
            default: begin pair_p0 = 2'd3; pair_p1 = 2'd3; end
        endcase
    end
    // sub_mb_type -> (pred, shape) (Tables 7-17, 7-18)
    logic [1:0] subt_pred, subt_shape;
    always_comb begin
        if (slice_type == ST_P) begin
            subt_pred = 2'd1;
            subt_shape = sub_t[1:0];
        end else begin
            case (sub_t)
                4'd0:  begin subt_pred = 2'd0; subt_shape = 2'd3; end
                4'd1:  begin subt_pred = 2'd1; subt_shape = 2'd0; end
                4'd2:  begin subt_pred = 2'd2; subt_shape = 2'd0; end
                4'd3:  begin subt_pred = 2'd3; subt_shape = 2'd0; end
                4'd4:  begin subt_pred = 2'd1; subt_shape = 2'd1; end
                4'd5:  begin subt_pred = 2'd1; subt_shape = 2'd2; end
                4'd6:  begin subt_pred = 2'd2; subt_shape = 2'd1; end
                4'd7:  begin subt_pred = 2'd2; subt_shape = 2'd2; end
                4'd8:  begin subt_pred = 2'd3; subt_shape = 2'd1; end
                4'd9:  begin subt_pred = 2'd3; subt_shape = 2'd2; end
                4'd10: begin subt_pred = 2'd1; subt_shape = 2'd3; end
                4'd11: begin subt_pred = 2'd2; subt_shape = 2'd3; end
                default: begin subt_pred = 2'd3; subt_shape = 2'd3; end
            endcase
        end
    end

    // coded_block_pattern luma ctxIdxInc (9.3.3.1.1.4), 8x8 block cbp_b8, prior bins in cbp_acc
    logic [1:0] cbp_inc;
    logic cbpA_zero, cbpB_zero;
    always_comb begin
        // A
        case (cbp_b8[1:0])
            2'd0: cbpA_zero = left_avail && !p_pcm && (p_skip || !p_cbp[1]);
            2'd1: cbpA_zero = !cbp_acc[0];
            2'd2: cbpA_zero = left_avail && !p_pcm && (p_skip || !p_cbp[3]);
            default: cbpA_zero = !cbp_acc[2];
        endcase
        // (an unavailable or I_PCM neighbour: condTerm 0)
        case (cbp_b8[1:0])
            2'd0: cbpB_zero = a_avail && !a_pcm && (a_skip || !a_cbp[2]);
            2'd1: cbpB_zero = a_avail && !a_pcm && (a_skip || !a_cbp[3]);
            2'd2: cbpB_zero = !cbp_acc[0];
            default: cbpB_zero = !cbp_acc[1];
        endcase
        cbp_inc = {cbpB_zero, cbpA_zero};
    end
    // chroma cbp condTerms, bin 0 (!= 0) and bin 1 (== 2)
    wire cbpcA0 = left_avail && (p_pcm || (!p_skip && p_cbp[5:4] != 2'd0));
    wire cbpcB0 = a_avail && (a_pcm || (!a_skip && a_cbp[5:4] != 2'd0));
    wire cbpcA1 = left_avail && (p_pcm || (!p_skip && p_cbp[5:4] == 2'd2));
    wire cbpcB1 = a_avail && (a_pcm || (!a_skip && a_cbp[5:4] == 2'd2));

    // coded_block_flag condTerms (9.3.3.1.1.9) for the current residual block
    logic cbfA, cbfB;
    logic cbfA_tb_ok, cbfB_tb_ok, cbfA_tb, cbfB_tb;
    logic [1:0] cac_nbA_idx, cac_nbB_idx;
    logic cac_nbA_prev, cac_nbB_above;
    always_comb begin
        // chroma 4x4 neighbours (6.4.11.5, 4:2:0): blocks 0,2 look left into the previous MB (1,3);
        // blocks 0,1 look up into the row above (2,3)
        cac_nbA_prev = !rb_idx[0];
        cac_nbA_idx = rb_idx[1:0] ^ 2'b01;
        cac_nbB_above = !rb_idx[1];
        cac_nbB_idx = rb_idx[1:0] ^ 2'b10;
        cbfA_tb_ok = 1'b0; cbfA_tb = 1'b0; cbfB_tb_ok = 1'b0; cbfB_tb = 1'b0;
        case (rb_kind)
            BK_LDC: begin
                cbfA_tb_ok = left_avail && p_i16;  cbfA_tb = p_cbf_dc;
                cbfB_tb_ok = a_avail && a_i16;     cbfB_tb = a_cbf_dc;
            end
            BK_L4: begin
                if (rbA_prev) begin
                    cbfA_tb_ok = left_avail && !p_skip && !p_pcm && p_cbp[rbA_idx[3:2]];
                    cbfA_tb = p_cbf_luma[rbA_idx];
                end else begin
                    cbfA_tb_ok = c_cbp[rbA_idx[3:2]];
                    cbfA_tb = c_cbf_luma[rbA_idx];
                end
                if (rbB_above) begin
                    cbfB_tb_ok = a_avail && !a_skip && !a_pcm && a_cbp[{1'b1, rbB_idx[1]}];   // blocks 10,11 -> 8x8 #2, 14,15 -> #3
                    cbfB_tb = a_cbf_luma[rbB_idx[1:0]];
                end else begin
                    cbfB_tb_ok = c_cbp[rbB_idx[3:2]];
                    cbfB_tb = c_cbf_luma[rbB_idx];
                end
            end
            BK_CDC: begin
                cbfA_tb_ok = left_avail && !p_skip && !p_pcm && (p_cbp[5:4] != 2'd0);  cbfA_tb = p_cbf_cdc[rb_idx[0]];
                cbfB_tb_ok = a_avail && !a_skip && !a_pcm && (a_cbp[5:4] != 2'd0);     cbfB_tb = a_cbf_cdc[rb_idx[0]];
            end
            default: begin   // BK_CAC: rb_idx = icc * 4 + blk
                if (cac_nbA_prev) begin
                    cbfA_tb_ok = left_avail && !p_skip && !p_pcm && (p_cbp[5:4] == 2'd2);
                    cbfA_tb = p_cbf_cac[{rb_idx[2], cac_nbA_idx}];
                end else begin
                    cbfA_tb_ok = 1'b1;
                    cbfA_tb = c_cbf_cac[{rb_idx[2], cac_nbA_idx}];
                end
                if (cac_nbB_above) begin
                    cbfB_tb_ok = a_avail && !a_skip && !a_pcm && (a_cbp[5:4] == 2'd2);
                    cbfB_tb = a_cbf_cac[{rb_idx[2], cac_nbB_idx[0]}];     // slots Cb2 Cb3 Cr2 Cr3
                end else begin
                    cbfB_tb_ok = 1'b1;
                    cbfB_tb = c_cbf_cac[{rb_idx[2], cac_nbB_idx}];
                end
            end
        endcase
        // the neighbour MB for A is the previous one unless the block is internal
        if ((rb_kind == BK_L4 && !rbA_prev) || (rb_kind == BK_CAC && !cac_nbA_prev))
            cbfA = cbfA_tb_ok ? cbfA_tb : 1'b0;
        else if (!left_avail)
            cbfA = c_intra;
        else if (p_pcm)
            cbfA = 1'b1;
        else
            cbfA = cbfA_tb_ok ? cbfA_tb : 1'b0;
        if ((rb_kind == BK_L4 && !rbB_above) || (rb_kind == BK_CAC && !cac_nbB_above))
            cbfB = cbfB_tb_ok ? cbfB_tb : 1'b0;
        else if (!a_avail)
            cbfB = c_intra;
        else if (a_pcm)
            cbfB = 1'b1;
        else
            cbfB = cbfB_tb_ok ? cbfB_tb : 1'b0;
    end
    wire [1:0] cbf_inc = {cbfB, cbfA};
    // block category offsets (Table 9-40)
    logic [5:0] cat_off_cbf, cat_off_sig, cat_off_abs;
    always_comb begin
        case (rb_cat)
            3'd0: begin cat_off_cbf = 6'd0;  cat_off_sig = 6'd0;  cat_off_abs = 6'd0;  end
            3'd1: begin cat_off_cbf = 6'd4;  cat_off_sig = 6'd15; cat_off_abs = 6'd10; end
            3'd2: begin cat_off_cbf = 6'd8;  cat_off_sig = 6'd29; cat_off_abs = 6'd20; end
            3'd3: begin cat_off_cbf = 6'd12; cat_off_sig = 6'd44; cat_off_abs = 6'd30; end
            default: begin cat_off_cbf = 6'd16; cat_off_sig = 6'd47; cat_off_abs = 6'd39; end
        endcase
    end
    // ctxBlockCat 5 (an 8x8 luma block): Table 9-43's maps from levelListIdx, the offsets of
    // Table 9-34 (sig 402 / 436 field, last 417 / 451 field)
    wire [6:0] rb_i1 = rb_i + 7'd1;
    logic [3:0] c8_sfr, c8_sfl, c8_last, c8_sfr1, c8_sfl1;
    logic [3:0] c8_last1_unused;
    hp_ctx8 u_c8  (.i(rb_i[5:0]),  .sig_fr(c8_sfr),  .sig_fl(c8_sfl),  .last(c8_last));
    hp_ctx8 u_c81 (.i(rb_i1[5:0]), .sig_fr(c8_sfr1), .sig_fl(c8_sfl1), .last(c8_last1_unused));
    wire       cat5 = (rb_cat == 3'd5);
    wire [3:0] sig_inc = (rb_cat == 3'd3) ? ((rb_i > 7'd2) ? 4'd2 : rb_i[3:0]) : rb_i[3:0];
    wire [8:0] sig_ctx  = cat5 ? (field ? 9'd436 + {5'd0, c8_sfl} : 9'd402 + {5'd0, c8_sfr})
                               : (field ? 9'd277 : 9'd105) + {3'd0, cat_off_sig} + {5'd0, sig_inc};
    wire [8:0] last_ctx = cat5 ? (field ? 9'd451 : 9'd417) + {5'd0, c8_last}
                               : (field ? 9'd338 : 9'd166) + {3'd0, cat_off_sig} + {5'd0, sig_inc};
    // the same for scan position rb_i + 1: issued in the cycle the current flag's bin
    // is consumed, saving a cycle per bin on the residual's hot loop
    wire [3:0] sig_inc1 = (rb_cat == 3'd3) ? ((rb_i1 > 7'd2) ? 4'd2 : rb_i1[3:0]) : rb_i1[3:0];
    wire [8:0] sig_ctx1 = cat5 ? (field ? 9'd436 + {5'd0, c8_sfl1} : 9'd402 + {5'd0, c8_sfr1})
                               : (field ? 9'd277 : 9'd105) + {3'd0, cat_off_sig} + {5'd0, sig_inc1};
    wire       more_sig = (rb_i1 < rb_n - 7'd1);            // a flag is coded at rb_i + 1

    // the residual block cursor: what the next block is, from rb_phase / rb_phase_i
    logic [3:0] nx_kind, nx_idx;
    logic [2:0] nx_cat;
    logic [6:0] nx_n;
    logic       nx_valid;
    logic [2:0] nx_phase;
    logic [4:0] nx_phase_i;
    always_comb begin
        nx_valid = 1'b0; nx_kind = BK_L4; nx_idx = 4'd0; nx_cat = 3'd2; nx_n = 7'd16;
        nx_phase = rb_phase; nx_phase_i = rb_phase_i;
        case (rb_phase)
            3'd0: begin
                if (c_i16) begin nx_valid = 1'b1; nx_kind = BK_LDC; nx_idx = 4'd0; nx_cat = 3'd0; nx_n = 7'd16; end
                nx_phase = 3'd1; nx_phase_i = 5'd0;
            end
            3'd1: begin
                if (c_t8) begin
                    // the 8x8 transform: one 64-coefficient block per coded 8x8 (7.3.5.3.1)
                    if (c_cbp[rb_phase_i[1:0]]) begin
                        nx_valid = 1'b1; nx_kind = BK_L8; nx_idx = {2'b00, rb_phase_i[1:0]}; nx_cat = 3'd5; nx_n = 7'd64;
                    end
                    if (rb_phase_i < 5'd3) nx_phase_i = rb_phase_i + 5'd1;
                    else begin nx_phase = 3'd2; nx_phase_i = 5'd0; end
                end else begin
                    if (rb_phase_i < 5'd16 && c_cbp[rb_phase_i[3:2]]) begin
                        nx_valid = 1'b1; nx_kind = BK_L4; nx_idx = rb_phase_i[3:0];
                        nx_cat = c_i16 ? 3'd1 : 3'd2; nx_n = c_i16 ? 7'd15 : 7'd16;
                    end
                    if (rb_phase_i < 5'd15) nx_phase_i = rb_phase_i + 5'd1;
                    else begin nx_phase = 3'd2; nx_phase_i = 5'd0; end
                end
            end
            3'd2: begin
                if (c_cbp[5:4] != 2'd0) begin nx_valid = 1'b1; nx_kind = BK_CDC; nx_idx = rb_phase_i[3:0]; nx_cat = 3'd3; nx_n = 7'd4; end
                if (rb_phase_i == 5'd0) nx_phase_i = 5'd1;
                else begin nx_phase = 3'd3; nx_phase_i = 5'd0; end
            end
            3'd3: begin
                if (c_cbp[5:4] == 2'd2) begin nx_valid = 1'b1; nx_kind = BK_CAC; nx_idx = rb_phase_i[3:0]; nx_cat = 3'd4; nx_n = 7'd15; end
                if (rb_phase_i < 5'd7) nx_phase_i = rb_phase_i + 5'd1;
                else begin nx_phase = 3'd4; nx_phase_i = 5'd0; end
            end
            default: begin nx_valid = 1'b0; nx_phase = 3'd4; end
        endcase
    end

    // the level-search: the highest position of rb_rem (significant, level not decoded yet),
    // as eight groups of eight: the highest non-empty group, then the highest bit in it
    logic [5:0] lv_pos;
    logic       lv_found;
    always_comb begin
        logic [7:0] grp_any, gbits;
        logic [2:0] g;
        for (int k = 0; k < 8; k++) grp_any[k] = (rb_rem[8*k +: 8] != 8'd0);
        g = 3'd0;
        for (int k = 0; k < 8; k++) if (grp_any[k]) g = k[2:0];
        case (g)
            3'd0: gbits = rb_rem[7:0];   3'd1: gbits = rb_rem[15:8];  3'd2: gbits = rb_rem[23:16]; 3'd3: gbits = rb_rem[31:24];
            3'd4: gbits = rb_rem[39:32]; 3'd5: gbits = rb_rem[47:40]; 3'd6: gbits = rb_rem[55:48]; default: gbits = rb_rem[63:56];
        endcase
        lv_pos = {g, 3'd0};
        for (int k = 0; k < 8; k++) if (gbits[k]) lv_pos = {g, k[2:0]};
        lv_found = (grp_any != 8'd0);
    end

    // the emission stream's landing word and pop (S_RB_EMIT_COEF)
    wire [15:0] em_land = em_sv ? cm_q : 16'd0;
    wire        eb_pop  = em_wait && se_ready && em_run;
    wire [2:0]  eb_after = {1'b0, eb_n} + {2'b00, em_rv} - {2'b00, eb_pop};
    // the TU sub-machine's context for the current bin
    wire [3:0] tu_binm1 = (tu_bin == 6'd0) ? 4'd0 : ((tu_bin - 6'd1) > {2'b00, tu_cap} ? tu_cap : tu_bin[3:0] - 4'd1);
    wire [8:0] tu_ctx = tu_base + ((tu_bin == 6'd0) ? {5'd0, tu_inc0} : ({5'd0, tu_inc1} + {5'd0, tu_binm1}));
    // the next bin's context (binIdx + 1), issued as the current bin is consumed
    wire [3:0] tu_binm1n = (tu_bin > {2'b00, tu_cap}) ? tu_cap : tu_bin[3:0];
    wire [8:0] tu_ctx_next = tu_base + {5'd0, tu_inc1} + {5'd0, tu_binm1n};

    // ---- the machine ---------------------------------------------------------------------------
    // request helpers: `issue` presents a request and waits; the consuming branch runs on rsp
    task automatic issue(input [2:0] kind, input [8:0] ctx);
        begin
            eng_req_kind <= kind; eng_req_ctx <= ctx; rq_wait <= 1'b1; rq_sent <= 1'b0;
        end
    endtask
    task automatic emit(input [7:0] kind, input [7:0] aux, input [15:0] val, input state_t next);
        begin
            pw_kind <= kind; pw_aux <= aux; pw_val <= val; ret_state <= next; state <= S_EMIT;
        end
    endtask
    task automatic start_tu(input [8:0] base, input [3:0] inc0, input [3:0] inc1, input [3:0] cap, input [4:0] cmax, input state_t next);
        begin
            tu_base <= base; tu_inc0 <= inc0; tu_inc1 <= inc1; tu_cap <= cap; tu_cmax <= cmax;
            tu_bin <= 6'd0; tu_val <= 16'd0; ret_state <= next; state <= S_TU;
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; ret_state <= S_IDLE; ret2_state <= S_IDLE;
            done <= 1'b0; err_overrun <= 1'b0; err_bins <= 1'b0;
            rq_wait <= 1'b0; rq_sent <= 1'b0; bin <= 1'b0;
            eng_req_kind <= 3'd0; eng_req_ctx <= 9'd0;
            pw_kind <= 8'd0; pw_aux <= 8'd0; pw_val <= 16'd0; jq_t <= 3'd0; wbk <= 1'b0; bk_tok <= 2'b00; cm_wb <= 1'b0;
            for (int j = 0; j < 4; j++) begin jq_typ[j] <= 1'b0; jq_kind[j] <= 8'd0; jq_aux[j] <= 8'd0; jq_val[j] <= 16'd0; jq_bank[j] <= 1'b0; jq_n[j] <= 7'd0; end
            sigb[0] <= 64'd0; sigb[1] <= 64'd0;
            slice_type <= 2'd0; num_ref[0] <= 6'd1; num_ref[1] <= 6'd1; field <= 1'b0;
            width_mbs <= 8'd1; height_mbs <= 8'd1; slice_id <= 16'd0;
            mb_addr <= 14'd0; mb_x <= 8'd0; mb_y <= 8'd0; row_base <= 14'd0; prev_valid <= 1'b0;
            above_we <= 1'b0; above_wa <= 7'd0;
            a_avail <= 1'b0; a_skip <= 1'b0; a_intra <= 1'b0; a_i16 <= 1'b0; a_pcm <= 1'b0; a_direct16 <= 1'b0;
            a_chroma_nz <= 1'b0; a_cbf_dc <= 1'b0; a_cbp <= 6'd0; a_cbf_cdc <= 2'd0; a_cbf_cac <= 4'd0; a_cbf_luma <= 4'd0;
            a_pred0 <= 4'd0; a_pred1 <= 4'd0; a_ref0gt <= 4'd0; a_ref1gt <= 4'd0;
            for (int k = 0; k < 4; k++) begin a_mvd0x[k] <= 6'd0; a_mvd0y[k] <= 6'd0; a_mvd1x[k] <= 6'd0; a_mvd1y[k] <= 6'd0; end
            c_skip <= 1'b0; c_intra <= 1'b0; c_i16 <= 1'b0; c_pcm <= 1'b0; c_direct16 <= 1'b0; c_chroma_nz <= 1'b0;
            c_cbf_dc <= 1'b0; c_qpd_nz <= 1'b0; c_is8x8 <= 1'b0; c_mb_type <= 6'd0; c_cbp <= 6'd0; c_cbf_cdc <= 2'd0;
            c_cbf_cac <= 8'd0; c_cbf_luma <= 16'd0; c_pred0 <= 16'd0; c_pred1 <= 16'd0; c_ref0gt <= 16'd0; c_ref1gt <= 16'd0;
            for (int k = 0; k < 16; k++) begin c_mvd0x[k] <= 6'd0; c_mvd0y[k] <= 6'd0; c_mvd1x[k] <= 6'd0; c_mvd1y[k] <= 6'd0; end
            for (int k = 0; k < 4; k++) begin c_sub_pred[k] <= 2'd0; c_sub_shape[k] <= 2'd0; end
            c_shape <= 2'd0; c_part_pred[0] <= 2'd0; c_part_pred[1] <= 2'd0;
            c_t8 <= 1'b0; c_nosub <= 1'b1; t8_ret <= S_IDLE; p_t8 <= 1'b0; a_t8 <= 1'b0; t8_mode <= 1'b0; d8inf <= 1'b0;
            rb_rem <= 64'd0; cm_we <= 1'b0; cm_wa <= 6'd0; cm_wd <= 16'sd0;

            p_skip <= 1'b0; p_intra <= 1'b0; p_i16 <= 1'b0; p_pcm <= 1'b0; p_direct16 <= 1'b0; p_chroma_nz <= 1'b0;
            p_cbf_dc <= 1'b0; p_qpd_nz <= 1'b0; p_cbp <= 6'd0; p_cbf_cdc <= 2'd0; p_cbf_cac <= 8'd0; p_cbf_luma <= 16'd0;
            p_pred0 <= 16'd0; p_pred1 <= 16'd0; p_ref0gt <= 16'd0; p_ref1gt <= 16'd0;
            for (int k = 0; k < 16; k++) begin p_mvd0x[k] <= 6'd0; p_mvd0y[k] <= 6'd0; p_mvd1x[k] <= 6'd0; p_mvd1y[k] <= 6'd0; end
            tu_base <= 9'd0; tu_inc0 <= 4'd0; tu_inc1 <= 4'd0; tu_cap <= 4'd0; tu_cmax <= 5'd0; tu_bin <= 6'd0; tu_val <= 16'd0;
            eg_k <= 4'd0; val_neg <= 1'b0;
            i4_idx <= 4'd0; rem_val <= 3'd0; rem_bit <= 2'd0; mbt_bits <= 4'd0; mbt_ac <= 1'b0; mbt_chroma <= 2'd0; mbt_pred <= 2'd0;
            mbt_off <= 9'd3; mbt_add <= 6'd0; sub_idx <= 2'd0; sub_t <= 4'd0; sub_bits <= 2'd0;
            lx <= 1'b0; unit <= 2'd0; sub <= 2'd0; comp <= 1'b0; cbp_b8 <= 4'd0; cbp_acc <= 6'd0; mv_query <= 4'd0;
            rb_phase <= 3'd0; rb_phase_i <= 5'd0; rb_kind <= 4'd0; rb_idx <= 4'd0; rb_cat <= 3'd0; rb_n <= 7'd0; rb_i <= 7'd0;
            rb_sig <= 64'd0; rb_num <= 7'd0; rb_eq1 <= 4'd0; rb_gt1 <= 4'd0; pcm_i <= 9'd0;
        end else begin
            above_we <= 1'b0;
            cm_we <= 1'b0;
            if (eng_req_valid && eng_req_ready) rq_sent <= 1'b1;
            if (rsp) begin rq_wait <= 1'b0; rq_sent <= 1'b0; bin <= eng_rsp_bin; end

            case (state)
            // ---------------------------------------------------------------- slice
            S_IDLE: if (start) begin
                t8_mode <= sp_t8_mode; d8inf <= sp_d8inf;
                slice_type <= sp_slice_type; num_ref[0] <= sp_num_ref_l0; num_ref[1] <= sp_num_ref_l1;
                field <= sp_field; width_mbs <= sp_width_mbs; height_mbs <= sp_height_mbs; slice_id <= sp_slice_id;
                mb_addr <= sp_first_mb; prev_valid <= 1'b0; done <= 1'b0; err_overrun <= 1'b0; err_bins <= 1'b0;
                // mb_x / mb_y of the first macroblock: a division, done serially below
                mb_x <= 8'd0; mb_y <= 8'd0; row_base <= 14'd0;
                state <= S_MB_POS;
            end
            S_MB_POS: state <= S_MB_BEGIN;
            S_MB_BEGIN: begin
                // (mb_x, mb_y) were advanced at S_MB_END; for the first macroblock they
                // come from first_mb by repeated subtraction (at most 128 rows). The test is
                // registered (pos_*: the product, the add and the compare in front of the
                // record's ~600 enables missed clk_dec in the full core), so every change of
                // mb_x / mb_y passes through S_MB_POS
                if (!pos_eq_q) begin
                    if (pos_ge_q) begin mb_y <= mb_y + 8'd1; row_base <= row_base + {6'd0, width_mbs}; end
                    else mb_x <= pos_x_q;
                    state <= S_MB_POS;
                end else if (mb_y >= height_mbs) begin
                    err_overrun <= 1'b1; state <= S_DONE;
                end else begin
                    // a fresh record
                    c_skip <= 1'b0; c_intra <= 1'b0; c_i16 <= 1'b0; c_pcm <= 1'b0; c_direct16 <= 1'b0; c_chroma_nz <= 1'b0;
                    c_cbf_dc <= 1'b0; c_qpd_nz <= 1'b0; c_is8x8 <= 1'b0; c_mb_type <= 6'd0; c_cbp <= 6'd0; c_cbf_cdc <= 2'd0;
                    c_cbf_cac <= 8'd0; c_cbf_luma <= 16'd0; c_pred0 <= 16'd0; c_pred1 <= 16'd0; c_ref0gt <= 16'd0; c_ref1gt <= 16'd0;
                    for (int k = 0; k < 16; k++) begin c_mvd0x[k] <= 6'd0; c_mvd0y[k] <= 6'd0; c_mvd1x[k] <= 6'd0; c_mvd1y[k] <= 6'd0; end
                    for (int k = 0; k < 4; k++) begin c_sub_pred[k] <= 2'd0; c_sub_shape[k] <= 2'd0; end
                    c_t8 <= 1'b0; c_nosub <= 1'b1;
                    state <= S_MB_LOAD;              // above_q is read this cycle
                end
            end
            S_MB_LOAD: begin
                a_avail <= (mb_y != 8'd0) && above_valid[mb_x[6:0]] && (above_q[AW-1 -: 16] == slice_id);
                {a_skip, a_intra, a_i16, a_pcm, a_direct16} <= above_q[AW-17 -: 5];
                a_cbp <= above_q[AW-22 -: 6];
                a_chroma_nz <= above_q[AW-28];
                a_cbf_dc <= above_q[AW-29];
                a_cbf_cdc <= above_q[AW-30 -: 2];
                a_cbf_cac <= above_q[AW-32 -: 4];
                a_cbf_luma <= above_q[AW-36 -: 4];
                for (int k = 0; k < 4; k++) begin
                    a_pred0[k]  <= above_q[112 - 28 * k];
                    a_pred1[k]  <= above_q[111 - 28 * k];
                    a_ref0gt[k] <= above_q[110 - 28 * k];
                    a_ref1gt[k] <= above_q[109 - 28 * k];
                    a_mvd0x[k]  <= above_q[108 - 28 * k -: 6];
                    a_mvd0y[k]  <= above_q[102 - 28 * k -: 6];
                    a_mvd1x[k]  <= above_q[96 - 28 * k -: 6];
                    a_mvd1y[k]  <= above_q[90 - 28 * k -: 6];
                end
                a_t8 <= above_q[0];
                emit(SE_MB_START, 8'd0, {2'b00, mb_addr}, (slice_type == ST_I) ? S_MBT_I0 : S_SKIP);
                mbt_off <= 9'd3; mbt_add <= 6'd0;
            end
            // ---------------------------------------------------------------- mb_skip_flag
            S_SKIP: begin
                if (!rq_wait) issue(K_DECISION, (slice_type == ST_P ? 9'd11 : 9'd24)
                                    + (left_avail && !p_skip ? 9'd1 : 9'd0) + (a_avail && !a_skip ? 9'd1 : 9'd0));
                else if (rsp) begin
                    c_skip <= eng_rsp_bin;
                    emit(SE_SKIP, 8'd0, {15'd0, eng_rsp_bin}, eng_rsp_bin ? S_EOS : (slice_type == ST_P ? S_MBT_P0 : S_MBT_B0));
                end
            end
            // ---------------------------------------------------------------- mb_type
            S_MBT_P0: begin
                if (!rq_wait) issue(K_DECISION, 9'd14);
                else if (rsp) begin
                    if (eng_rsp_bin) begin mbt_off <= 9'd17; mbt_add <= 6'd5; state <= S_MBT_I0; end
                    else state <= S_MBT_P1;
                end
            end
            S_MBT_P1: begin
                if (!rq_wait) issue(K_DECISION, 9'd15);
                else if (rsp) state <= eng_rsp_bin ? S_MBT_P3 : S_MBT_P2;
            end
            S_MBT_P2: begin          // 0 0 x
                if (!rq_wait) issue(K_DECISION, 9'd16);
                else if (rsp) begin c_mb_type <= eng_rsp_bin ? 6'd3 : 6'd0; state <= S_MBT_DONE; end
            end
            S_MBT_P3: begin          // 0 1 x
                if (!rq_wait) issue(K_DECISION, 9'd17);
                else if (rsp) begin c_mb_type <= eng_rsp_bin ? 6'd1 : 6'd2; state <= S_MBT_DONE; end
            end
            S_MBT_B0: begin
                if (!rq_wait) issue(K_DECISION, 9'd27 + (left_avail && !p_skip && !p_direct16 ? 9'd1 : 9'd0)
                                                     + (a_avail && !a_skip && !a_direct16 ? 9'd1 : 9'd0));
                else if (rsp) begin
                    if (!eng_rsp_bin) begin c_mb_type <= 6'd0; state <= S_MBT_DONE; end
                    else state <= S_MBT_B1;
                end
            end
            S_MBT_B1: begin
                if (!rq_wait) issue(K_DECISION, 9'd30);
                else if (rsp) begin mbt_bits <= 4'd0; state <= eng_rsp_bin ? S_MBT_B2B : S_MBT_B2A; end
            end
            S_MBT_B2A: begin         // 1 0 x -> 1 + x
                if (!rq_wait) issue(K_DECISION, 9'd32);
                else if (rsp) begin c_mb_type <= {5'd0, eng_rsp_bin} + 6'd1; state <= S_MBT_DONE; end
            end
            S_MBT_B2B: begin         // 1 1 b2 (ctx 31) then b3 b4 b5 (ctx 32)
                if (!rq_wait) issue(K_DECISION, 9'd31);
                else if (rsp) begin mbt_bits <= {eng_rsp_bin, 3'b000}; rem_bit <= 2'd0; state <= S_MBT_B3; end
            end
            S_MBT_B3: begin
                if (!rq_wait) issue(K_DECISION, 9'd32);
                else if (rsp) begin
                    if (rem_bit == 2'd0) begin mbt_bits[2] <= eng_rsp_bin; rem_bit <= 2'd1; end
                    else if (rem_bit == 2'd1) begin mbt_bits[1] <= eng_rsp_bin; rem_bit <= 2'd2; end
                    else begin
                        // bits complete
                        case ({mbt_bits[3:1], eng_rsp_bin})
                            4'd13: begin mbt_off <= 9'd32; mbt_add <= 6'd23; state <= S_MBT_I0; end
                            4'd14: begin c_mb_type <= 6'd11; state <= S_MBT_DONE; end
                            4'd15: begin c_mb_type <= 6'd22; state <= S_MBT_DONE; end
                            default: begin
                                if (!mbt_bits[3]) begin c_mb_type <= {3'd0, mbt_bits[2:1], eng_rsp_bin} + 6'd3; state <= S_MBT_DONE; end
                                else begin mbt_bits[0] <= eng_rsp_bin; state <= S_MBT_B6; end
                            end
                        endcase
                    end
                end
            end
            S_MBT_B6: begin          // one more bin: (bits << 1 | b) - 4
                if (!rq_wait) issue(K_DECISION, 9'd32);
                else if (rsp) begin c_mb_type <= {1'b0, mbt_bits, eng_rsp_bin} - 6'd4; state <= S_MBT_DONE; end
            end
            // the I binarisation at mbt_off (3: an I slice; 17 / 32: the P / B intra suffix)
            S_MBT_I0: begin
                if (!rq_wait) issue(K_DECISION, mbt_off + ((mbt_off == 9'd3)
                                    ? ((left_avail && !(p_intra && !p_i16 && !p_pcm) ? 9'd1 : 9'd0)
                                       + (a_avail && !(a_intra && !a_i16 && !a_pcm) ? 9'd1 : 9'd0)) : 9'd0));
                else if (rsp) begin
                    if (!eng_rsp_bin) begin c_mb_type <= mbt_add; state <= S_MBT_DONE; end      // I_NxN
                    else state <= S_MBT_I1;
                end
            end
            S_MBT_I1: begin
                if (!rq_wait) issue(K_TERMINATE, 9'd0);
                else if (rsp) begin
                    if (eng_rsp_bin) begin c_mb_type <= mbt_add + 6'd25; state <= S_MBT_DONE; end  // I_PCM
                    else state <= S_MBT_I2;
                end
            end
            S_MBT_I2: begin          // luma AC
                if (!rq_wait) issue(K_DECISION, mbt_off + ((mbt_off == 9'd3) ? 9'd3 : 9'd1));
                else if (rsp) begin mbt_ac <= eng_rsp_bin; state <= S_MBT_I3; end
            end
            S_MBT_I3: begin          // chroma present
                if (!rq_wait) issue(K_DECISION, mbt_off + ((mbt_off == 9'd3) ? 9'd4 : 9'd2));
                else if (rsp) begin mbt_chroma <= {1'b0, eng_rsp_bin}; state <= eng_rsp_bin ? S_MBT_I4 : S_MBT_I5; end
            end
            S_MBT_I4: begin          // chroma 2 vs 1
                if (!rq_wait) issue(K_DECISION, mbt_off + ((mbt_off == 9'd3) ? 9'd5 : 9'd2));
                else if (rsp) begin mbt_chroma <= eng_rsp_bin ? 2'd2 : 2'd1; state <= S_MBT_I5; end
            end
            S_MBT_I5: begin          // pred bit 1
                if (!rq_wait) issue(K_DECISION, mbt_off + ((mbt_off == 9'd3) ? 9'd6 : 9'd3));
                else if (rsp) begin mbt_pred[1] <= eng_rsp_bin; state <= S_MBT_I6; end
            end
            S_MBT_I6: begin          // pred bit 0
                if (!rq_wait) issue(K_DECISION, mbt_off + ((mbt_off == 9'd3) ? 9'd7 : 9'd3));
                else if (rsp) begin
                    c_mb_type <= mbt_add + 6'd1 + {4'd0, mbt_pred[1], eng_rsp_bin} + {3'd0, mbt_chroma, 2'b00} + (mbt_ac ? 6'd12 : 6'd0);
                    state <= S_MBT_DONE;
                end
            end
            S_MBT_DONE: begin
                // interpret the (spec) mb_type
                if (c_mb_type >= mbt_add && mbt_add != 6'd0 || slice_type == ST_I) begin
                    // intra (for an I slice mbt_add == 0 and every type is intra)
                end
                emit(SE_MB_TYPE, 8'd0, {10'd0, c_mb_type}, S_MBT_EMIT);
            end
            S_MBT_EMIT: begin
                // after the emission: branch on the type
                if (slice_type == ST_I || c_mb_type >= (slice_type == ST_P ? 6'd5 : 6'd23)) begin
                    c_intra <= 1'b1;
                    if (c_mb_type - mbt_add == 6'd25) begin c_pcm <= 1'b1; state <= S_PCM_ALIGN; end
                    else if (c_mb_type == mbt_add) begin
                        // I_NxN: transform_size_8x8_flag first when the PPS allows it (7.3.5)
                        i4_idx <= 4'd0; t8_ret <= S_I4_FLAG;
                        state <= t8_mode ? S_T8 : S_I4_FLAG;
                    end
                    else begin
                        c_i16 <= 1'b1;
                        // CodedBlockPattern from the type (Table 7-11): t = type - base - 1
                        c_cbp <= {mbt_chroma, (mbt_ac ? 4'hF : 4'h0)};
                        state <= S_CHROMA_TU;
                    end
                end else if (slice_type == ST_B && c_mb_type == 6'd0) begin
                    c_direct16 <= 1'b1;
                    state <= S_CBP_LUMA; cbp_b8 <= 4'd0; cbp_acc <= 6'd0;
                end else if ((slice_type == ST_P && c_mb_type == 6'd3) || (slice_type == ST_B && c_mb_type == 6'd22)) begin
                    c_is8x8 <= 1'b1; sub_idx <= 2'd0;
                    state <= (slice_type == ST_P) ? S_SUB_P0 : S_SUB_B0;
                end else begin
                    // a 16x16 / 16x8 / 8x16 partitioning
                    if (slice_type == ST_P) begin
                        c_shape <= c_mb_type[1:0];                  // 0 16x16, 1 16x8, 2 8x16
                        c_part_pred[0] <= 2'd1; c_part_pred[1] <= 2'd1;
                    end else if (c_mb_type <= 6'd3) begin
                        c_shape <= 2'd0; c_part_pred[0] <= c_mb_type[1:0]; c_part_pred[1] <= c_mb_type[1:0];
                    end else begin
                        c_shape <= pair_k[0] ? 2'd2 : 2'd1; c_part_pred[0] <= pair_p0; c_part_pred[1] <= pair_p1;
                    end
                    lx <= 1'b0; unit <= 2'd0; sub <= 2'd0; state <= S_REF_NEXT;
                    ret2_state <= S_REF_NEXT;
                end
            end
            // ---------------------------------------------------------------- intra 4x4 modes
            S_I4_FLAG: begin
                if (!rq_wait) issue(K_DECISION, 9'd68);
                else if (rsp) begin
                    // Intra_4x4: 16 blocks; Intra_8x8: 4 (the same bins, ctxIdx 68 / 69)
                    if (eng_rsp_bin) emit(SE_PREV_INTRA, 8'd0, 16'd1, (i4_idx == (c_t8 ? 4'd3 : 4'd15)) ? S_CHROMA_TU : S_I4_FLAG);
                    else emit(SE_PREV_INTRA, 8'd0, 16'd0, S_I4_REM);
                    if (eng_rsp_bin) i4_idx <= i4_idx + 4'd1;
                    rem_bit <= 2'd0; rem_val <= 3'd0;
                end
            end
            S_I4_REM: begin          // 3 bins, LSB first, ctx 69
                if (!rq_wait) issue(K_DECISION, 9'd69);
                else if (rsp) begin
                    rem_val[rem_bit] <= eng_rsp_bin;
                    if (rem_bit == 2'd2) begin
                        i4_idx <= i4_idx + 4'd1;
                        emit(SE_REM_INTRA, 8'd0, {13'd0, eng_rsp_bin, rem_val[1:0]}, (i4_idx == (c_t8 ? 4'd3 : 4'd15)) ? S_CHROMA_TU : S_I4_FLAG);
                    end else rem_bit <= rem_bit + 2'd1;
                end
            end
            // ---------------------------------------------------------------- intra_chroma_pred_mode
            S_CHROMA_TU: begin
                start_tu(9'd64, (left_avail && p_intra && !p_pcm && p_chroma_nz ? 4'd1 : 4'd0)
                                 + (a_avail && a_intra && !a_pcm && a_chroma_nz ? 4'd1 : 4'd0), 4'd3, 4'd0, 5'd3, S_CHROMA_EMIT);
            end
            S_CHROMA_EMIT: begin
                c_chroma_nz <= (tu_val != 16'd0);
                emit(SE_CHROMA_PRED, 8'd0, tu_val, c_i16 ? S_QPD_TU : S_CBP_LUMA);
                cbp_b8 <= 4'd0; cbp_acc <= 6'd0;
            end
            // ---------------------------------------------------------------- sub_mb_type
            S_SUB_P0: begin
                if (!rq_wait) issue(K_DECISION, 9'd21);
                else if (rsp) begin if (eng_rsp_bin) begin sub_t <= 4'd0; state <= S_SUB_DONE; end else state <= S_SUB_P1; end
            end
            S_SUB_P1: begin
                if (!rq_wait) issue(K_DECISION, 9'd22);
                else if (rsp) begin if (!eng_rsp_bin) begin sub_t <= 4'd1; state <= S_SUB_DONE; end else state <= S_SUB_P2; end
            end
            S_SUB_P2: begin
                if (!rq_wait) issue(K_DECISION, 9'd23);
                else if (rsp) begin sub_t <= eng_rsp_bin ? 4'd2 : 4'd3; state <= S_SUB_DONE; end
            end
            S_SUB_B0: begin
                if (!rq_wait) issue(K_DECISION, 9'd36);
                else if (rsp) begin if (!eng_rsp_bin) begin sub_t <= 4'd0; state <= S_SUB_DONE; end else state <= S_SUB_B1; end
            end
            S_SUB_B1: begin
                if (!rq_wait) issue(K_DECISION, 9'd37);
                else if (rsp) begin sub_bits <= 2'd0; state <= eng_rsp_bin ? S_SUB_B2 : S_SUB_B5; end
            end
            S_SUB_B5: begin          // 1 0 x -> 1 + x (ctx 39)
                if (!rq_wait) issue(K_DECISION, 9'd39);
                else if (rsp) begin sub_t <= {3'd0, eng_rsp_bin} + 4'd1; state <= S_SUB_DONE; end
            end
            S_SUB_B2: begin          // ctx 38
                if (!rq_wait) issue(K_DECISION, 9'd38);
                else if (rsp) begin sub_bits <= 2'd0; state <= eng_rsp_bin ? S_SUB_B3 : S_SUB_B4; end
            end
            S_SUB_B3: begin          // 1 1 1 x: x=1 -> 11 + b ; x=0 -> 7 + 2b + b
                if (!rq_wait) issue(K_DECISION, 9'd39);
                else if (rsp) begin
                    if (sub_bits == 2'd0) begin
                        if (eng_rsp_bin) begin sub_bits <= 2'd3; end       // 11 + next
                        else sub_bits <= 2'd1;                              // 7 + 2*next + next
                    end else if (sub_bits == 2'd3) begin sub_t <= 4'd11 + {3'd0, eng_rsp_bin}; state <= S_SUB_DONE; end
                    else if (sub_bits == 2'd1) begin sub_t <= 4'd7 + {2'd0, eng_rsp_bin, 1'b0}; sub_bits <= 2'd2; end
                    else begin sub_t <= sub_t + {3'd0, eng_rsp_bin}; state <= S_SUB_DONE; end
                end
            end
            S_SUB_B4: begin          // 1 1 0 b b -> 3 + 2b + b
                if (!rq_wait) issue(K_DECISION, 9'd39);
                else if (rsp) begin
                    if (sub_bits == 2'd0) begin sub_t <= 4'd3 + {2'd0, eng_rsp_bin, 1'b0}; sub_bits <= 2'd1; end
                    else begin sub_t <= sub_t + {3'd0, eng_rsp_bin}; state <= S_SUB_DONE; end
                end
            end
            S_SUB_DONE: begin
                c_sub_pred[sub_idx] <= subt_pred; c_sub_shape[sub_idx] <= subt_shape;
                // 7.3.5: a sub-macroblock partitioned below 8x8, or B_Direct_8x8 without
                // direct_8x8_inference_flag, rules the 8x8 transform out
                if (subt_pred == 2'd0) begin if (!d8inf) c_nosub <= 1'b0; end
                else if (subt_shape != 2'd0) c_nosub <= 1'b0;
                // predFlagLX of the 8x8's four blocks
                if (subt_pred[0]) c_pred0[{sub_idx, 2'b00} +: 4] <= 4'hF;
                if (subt_pred[1]) c_pred1[{sub_idx, 2'b00} +: 4] <= 4'hF;
                emit(SE_SUB_MB_TYPE, 8'd0, {12'd0, sub_t}, (sub_idx == 2'd3) ? S_REF_NEXT : (slice_type == ST_P ? S_SUB_P0 : S_SUB_B0));
                sub_idx <= sub_idx + 2'd1;
                lx <= 1'b0; unit <= 2'd0; sub <= 2'd0;
            end
            // ---------------------------------------------------------------- ref_idx loops
            S_REF_NEXT: begin
                // set the partition predFlags for the non-8x8 case on the first visit
                if (!c_is8x8 && lx == 1'b0 && unit == 2'd0 && c_pred0 == 16'd0 && c_pred1 == 16'd0 && c_part_pred[0] != 2'd0) begin
                    // (16x16: unit 0 covers everything; 16x8/8x16: units 0 and 1)
                    if (c_shape == 2'd0) begin
                        if (c_part_pred[0][0]) c_pred0 <= 16'hFFFF;
                        if (c_part_pred[0][1]) c_pred1 <= 16'hFFFF;
                    end else if (c_shape == 2'd1) begin
                        c_pred0 <= {{8{c_part_pred[1][0]}}, {8{c_part_pred[0][0]}}};
                        c_pred1 <= {{8{c_part_pred[1][1]}}, {8{c_part_pred[0][1]}}};
                    end else begin
                        c_pred0 <= {{4{c_part_pred[1][0]}}, {4{c_part_pred[0][0]}}, {4{c_part_pred[1][0]}}, {4{c_part_pred[0][0]}}};
                        c_pred1 <= {{4{c_part_pred[1][1]}}, {4{c_part_pred[0][1]}}, {4{c_part_pred[1][1]}}, {4{c_part_pred[0][1]}}};
                    end
                end else if (unit_pred[lx] && num_ref[lx] > 6'd1) begin
                    mv_query <= unit_first;
                    state <= S_REF_TU;
                end else if (unit != n_units) unit <= unit + 2'd1;
                else if (!lx) begin lx <= 1'b1; unit <= 2'd0; end
                else begin lx <= 1'b0; unit <= 2'd0; sub <= 2'd0; comp <= 1'b0; state <= S_MVD_NEXT; end
            end
            S_REF_TU: start_tu(9'd54, ref_inc, 4'd4, 4'd1, 5'd0, S_REF_EMIT);
            S_REF_EMIT: begin
                // ref_idx > 0 into the unit's blocks
                if (tu_val != 16'd0) begin
                    if (lx) c_ref1gt <= c_ref1gt | (c_is8x8 ? (16'h000F << {unit, 2'b00}) : (c_shape == 2'd0 ? 16'hFFFF : c_shape == 2'd1 ? (unit[0] ? 16'hFF00 : 16'h00FF) : (unit[0] ? 16'hF0F0 : 16'h0F0F)));
                    else    c_ref0gt <= c_ref0gt | (c_is8x8 ? (16'h000F << {unit, 2'b00}) : (c_shape == 2'd0 ? 16'hFFFF : c_shape == 2'd1 ? (unit[0] ? 16'hFF00 : 16'h00FF) : (unit[0] ? 16'hF0F0 : 16'h0F0F)));
                end
                emit(lx ? SE_REF_L1 : SE_REF_L0, 8'd0, tu_val, S_REF_NEXT);
                if (unit != n_units) unit <= unit + 2'd1;
                else if (!lx) begin lx <= 1'b1; unit <= 2'd0; end
                else begin lx <= 1'b0; unit <= 2'd0; sub <= 2'd0; comp <= 1'b0; ret_state <= S_MVD_NEXT; end
            end
            // ---------------------------------------------------------------- mvd loops
            S_MVD_NEXT: begin
                if (unit_pred[lx]) begin
                    mv_query <= sub_first;
                    state <= S_MVD_CTX;
                end else if (unit != n_units) begin unit <= unit + 2'd1; sub <= 2'd0; end
                else if (!lx) begin lx <= 1'b1; unit <= 2'd0; sub <= 2'd0; end
                else begin state <= S_CBP_LUMA; cbp_b8 <= 4'd0; cbp_acc <= 6'd0; end
            end
            S_MVD_CTX: state <= S_MVD_CTX2;        // (the neighbours registered; mvd_inc_q: the
            S_MVD_CTX2: state <= S_MVD_TU;         //  sum a cycle later -- in front of the bin
                                                   //  engine's request it missed clk_dec)
            S_MVD_TU: start_tu(comp ? 9'd47 : 9'd40, mvd_inc_q, 4'd3, 4'd3, 5'd9, S_MVD_EG);
            S_MVD_EG: begin
                if (tu_val == 16'd9) begin eg_k <= 4'd3; ret_state <= S_MVD_SIGN; state <= S_EG_PREFIX; end
                else state <= S_MVD_SIGN;
            end
            S_MVD_SIGN: begin
                if (tu_val != 16'd0) begin ret_state <= S_MVD_EMIT; state <= S_SIGN; end
                else begin val_neg <= 1'b0; state <= S_MVD_EMIT; end
            end
            S_MVD_EMIT: begin
                // store |mvd| clipped to 33 into the sub-partition's blocks
                for (int k = 0; k < 16; k++) begin
                    if (sub_mask[k]) begin
                        if (!lx && !comp) c_mvd0x[k] <= (tu_val > 16'd33) ? 6'd33 : tu_val[5:0];
                        if (!lx &&  comp) c_mvd0y[k] <= (tu_val > 16'd33) ? 6'd33 : tu_val[5:0];
                        if ( lx && !comp) c_mvd1x[k] <= (tu_val > 16'd33) ? 6'd33 : tu_val[5:0];
                        if ( lx &&  comp) c_mvd1y[k] <= (tu_val > 16'd33) ? 6'd33 : tu_val[5:0];
                    end
                end
                emit(lx ? SE_MVD_L1 : SE_MVD_L0, 8'd0, val_neg ? (16'd0 - tu_val) : tu_val, S_MVD_NEXT);
                if (!comp) comp <= 1'b1;
                else begin
                    comp <= 1'b0;
                    if (sub != unit_nsub) sub <= sub + 2'd1;
                    else if (unit != n_units) begin unit <= unit + 2'd1; sub <= 2'd0; end
                    else if (!lx) begin lx <= 1'b1; unit <= 2'd0; sub <= 2'd0; end
                    else begin ret_state <= S_CBP_LUMA; cbp_b8 <= 4'd0; cbp_acc <= 6'd0; end
                end
            end
            // ---------------------------------------------------------------- coded_block_pattern
            S_CBP_LUMA: begin
                if (!rq_wait) issue(K_DECISION, 9'd73 + {7'd0, cbp_inc});
                else if (rsp) begin
                    cbp_acc[cbp_b8[1:0]] <= eng_rsp_bin;
                    if (cbp_b8 == 4'd3) state <= S_CBP_C0;
                    else cbp_b8 <= cbp_b8 + 4'd1;
                end
            end
            S_CBP_C0: begin
                if (!rq_wait) issue(K_DECISION, 9'd77 + (cbpcA0 ? 9'd1 : 9'd0) + (cbpcB0 ? 9'd2 : 9'd0));
                else if (rsp) begin
                    if (eng_rsp_bin) begin cbp_acc[4] <= 1'b1; state <= S_CBP_C1; end
                    else state <= S_CBP_EMIT;
                end
            end
            S_CBP_C1: begin
                if (!rq_wait) issue(K_DECISION, 9'd81 + (cbpcA1 ? 9'd1 : 9'd0) + (cbpcB1 ? 9'd2 : 9'd0));
                else if (rsp) begin cbp_acc[5] <= eng_rsp_bin; cbp_acc[4] <= ~eng_rsp_bin; state <= S_CBP_EMIT; end
            end
            S_CBP_EMIT: begin
                c_cbp <= cbp_acc;
                t8_ret <= S_QPD_TU;
                // 7.3.5: the second place of transform_size_8x8_flag (inter macroblocks with luma)
                emit(SE_CBP, 8'd0, {10'd0, cbp_acc},
                     (cbp_acc[3:0] != 4'd0 && t8_mode && !c_intra && c_nosub && (!c_direct16 || d8inf)) ? S_T8 :
                     (cbp_acc != 6'd0) ? S_QPD_TU : S_EOS);
            end
            // ---------------------------------------------------------------- transform_size_8x8_flag
            S_T8: begin
                if (!rq_wait) issue(K_DECISION, 9'd399 + (left_avail && p_t8 ? 9'd1 : 9'd0) + (a_avail && a_t8 ? 9'd1 : 9'd0));
                else if (rsp) begin
                    c_t8 <= eng_rsp_bin;
                    emit(SE_T8, 8'd0, {15'd0, eng_rsp_bin}, t8_ret);
                end
            end
            // ---------------------------------------------------------------- mb_qp_delta
            S_QPD_TU: start_tu(9'd60, (prev_valid && !p_skip && !p_pcm && (p_i16 || p_cbp != 6'd0) && p_qpd_nz) ? 4'd1 : 4'd0,
                               4'd2, 4'd1, 5'd0, S_QPD_EMIT);
            S_QPD_EMIT: begin
                c_qpd_nz <= (tu_val != 16'd0);
                // Table 9-3: k -> (-1)^(k+1) * Ceil(k / 2)
                emit(SE_QP_DELTA, 8'd0, tu_val[0] ? {1'b0, tu_val[15:1]} + 16'd1 : (16'd0 - {1'b0, tu_val[15:1]}), S_RB_NEXT);
                rb_phase <= 3'd0; rb_phase_i <= 5'd0;
            end
            // ---------------------------------------------------------------- residual
            S_RB_NEXT: if (!(nx_valid && bk_busy[wbk])) begin   // (the bank's last block still streams)
                rb_phase <= nx_phase; rb_phase_i <= nx_phase_i;
                if (nx_valid) begin
                    rb_kind <= nx_kind; rb_idx <= nx_idx; rb_cat <= nx_cat; rb_n <= nx_n;
                    rb_sig <= 64'd0; rb_rem <= 64'd0; rb_i <= 7'd0; rb_eq1 <= 4'd0; rb_gt1 <= 4'd0; rb_num <= nx_n;
                    if (nx_cat == 3'd5) begin
                        // no coded_block_flag in 4:2:0 (7.3.5.3.3), inferred 1: the four 4x4 slots
                        // carry it for the neighbours' contexts (9.3.3.1.1.9)
                        c_cbf_luma[{nx_idx[1:0], 2'b00} +: 4] <= 4'hF;
                        state <= S_RB_SIG;
                    end else state <= S_RB_CBF;
                end else if (rb_phase == 3'd4) state <= S_EOS;
            end
            S_RB_CBF: begin
                if (!rq_wait) issue(K_DECISION, 9'd85 + {3'd0, cat_off_cbf} + {7'd0, cbf_inc});
                else if (rsp) begin
                    // record the flag
                    case (rb_kind)
                        BK_LDC: c_cbf_dc <= eng_rsp_bin;
                        BK_L4:  c_cbf_luma[rb_idx] <= eng_rsp_bin;
                        BK_CDC: c_cbf_cdc[rb_idx[0]] <= eng_rsp_bin;
                        default: c_cbf_cac[rb_idx[2:0]] <= eng_rsp_bin;
                    endcase
                    if (eng_rsp_bin) begin rb_i <= 7'd0; state <= S_RB_SIG; end
                    else begin rb_i <= 7'd0; state <= S_RB_EMIT_START; end
                end
            end
            S_RB_SIG: begin
                if (rb_i >= rb_n - 7'd1) begin
                    // the last position: significant by inference
                    rb_sig[rb_n[5:0] - 6'd1] <= 1'b1; rb_rem[rb_n[5:0] - 6'd1] <= 1'b1;
                    rb_num <= rb_n; rb_i <= rb_n - 7'd1; state <= S_RB_LEVEL_FIND;
                end else if (!rq_wait) issue(K_DECISION, sig_ctx);
                else if (rsp) begin
                    if (eng_rsp_bin) begin rb_sig[rb_i[5:0]] <= 1'b1; rb_rem[rb_i[5:0]] <= 1'b1; state <= S_RB_LAST; issue(K_DECISION, last_ctx); end
                    else begin rb_i <= rb_i1; if (more_sig) issue(K_DECISION, sig_ctx1); end
                end
            end
            S_RB_LAST: begin
                if (!rq_wait) issue(K_DECISION, last_ctx);
                else if (rsp) begin
                    if (eng_rsp_bin) begin rb_num <= rb_i + 7'd1; state <= S_RB_LEVEL_FIND; end   // rb_i stays: the highest
                    else begin rb_i <= rb_i1; state <= S_RB_SIG; if (more_sig) issue(K_DECISION, sig_ctx1); end
                end
            end
            S_RB_LEVEL_FIND: begin
                // the highest significant position whose level is still to decode
                if (lv_found) begin
                    rb_i <= {1'b0, lv_pos};
                    state <= S_RB_LEVEL_TU;
                end else begin rb_i <= 7'd0; state <= S_RB_EMIT_START; end
            end
            S_RB_LEVEL_TU: start_tu(cat5 ? 9'd426 : 9'd227 + {3'd0, cat_off_abs},
                                    (rb_gt1 != 4'd0) ? 4'd0 : ((rb_eq1 >= 4'd3) ? 4'd4 : rb_eq1 + 4'd1),
                                    4'd5 + (((4'd4 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) < rb_gt1) ? (4'd4 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) : rb_gt1),
                                    4'd0, 5'd14, S_RB_LEVEL_EG);
            S_RB_LEVEL_EG: begin
                if (tu_val == 16'd14) begin eg_k <= 4'd0; ret_state <= S_RB_LEVEL_SIGN; state <= S_EG_PREFIX; end
                else state <= S_RB_LEVEL_SIGN;
            end
            S_RB_LEVEL_SIGN: begin
                if (!rq_wait) issue(K_BYPASS, 9'd0);
                else if (rsp) begin
                    cm_we <= 1'b1; cm_wb <= wbk; cm_wa <= rb_i[5:0];
                    cm_wd <= eng_rsp_bin ? -($signed({1'b0, tu_val[14:0]}) + 16'sd1) : ($signed({1'b0, tu_val[14:0]}) + 16'sd1);
                    rb_rem[rb_i[5:0]] <= 1'b0;
                    // both counts saturate: an 8x8 block has up to 64 levels, and 9-23 / 9-24 only
                    // ever compare them with 4 (a wrapping 4-bit eq1 broke an x264 I slice)
                    if (tu_val == 16'd0) rb_eq1 <= (rb_eq1 == 4'd15) ? rb_eq1 : rb_eq1 + 4'd1;
                    else rb_gt1 <= (rb_gt1 == 4'd15) ? rb_gt1 : rb_gt1 + 4'd1;
                    state <= S_RB_LEVEL_FIND;
                end
            end
            S_RB_EMIT_START: begin
                rb_i <= 7'd0;
                emit(SE_BLK_START, {rb_idx, rb_kind}, {9'd0, rb_n}, S_RB_EMIT_COEF);
            end
            S_RB_EMIT_COEF: if (jq_room) begin
                // the block's coefficients as a job on this bank; the next block decodes into
                // the other (S_RB_NEXT waits for it to be streamed)
                jq_typ[jq_t[1:0]] <= 1'b1; jq_bank[jq_t[1:0]] <= wbk; jq_n[jq_t[1:0]] <= rb_n;
                jq_t <= jq_t + 3'd1;
                sigb[wbk] <= rb_sig; bk_tok[wbk] <= !bk_tok[wbk]; wbk <= !wbk;
                state <= S_RB_NEXT;
            end
            // ---------------------------------------------------------------- I_PCM
            S_PCM_ALIGN: begin
                if (!rq_wait) issue(K_ALIGN, 9'd0);
                else if (rsp) begin pcm_i <= 9'd0; emit(SE_BLK_START, {4'd0, BK_PCM}, 16'd384, S_PCM_BYTE); end
            end
            S_PCM_BYTE: begin
                if (!rq_wait) issue(K_RAWBYTE, 9'd0);
                else if (rsp) begin
                    emit(SE_COEF, 8'd0, {8'd0, eng_rsp_byte}, (pcm_i == 9'd383) ? S_PCM_REINIT : S_PCM_BYTE);
                    pcm_i <= pcm_i + 9'd1;
                end
            end
            S_PCM_REINIT: begin
                if (!rq_wait) issue(K_REINIT, 9'd0);
                else if (rsp) state <= S_EOS;
            end
            // ---------------------------------------------------------------- end_of_slice_flag
            S_EOS: begin
                if (!rq_wait) issue(K_TERMINATE, 9'd0);
                else if (rsp) emit(SE_END_OF_SLICE, 8'd0, {15'd0, eng_rsp_bin}, eng_rsp_bin ? S_DONE : S_MB_END);
            end
            S_MB_END: begin
                // the record becomes the previous one and the row-above entry
                above_we <= 1'b1; above_wa <= mb_x[6:0];
                p_skip <= c_skip; p_intra <= c_intra; p_i16 <= c_i16; p_pcm <= c_pcm; p_direct16 <= c_direct16; p_t8 <= c_t8;
                p_chroma_nz <= c_chroma_nz; p_cbf_dc <= c_cbf_dc; p_qpd_nz <= c_qpd_nz; p_cbp <= c_cbp;
                p_cbf_cdc <= c_cbf_cdc; p_cbf_cac <= c_cbf_cac; p_cbf_luma <= c_cbf_luma;
                p_pred0 <= c_pred0; p_pred1 <= c_pred1; p_ref0gt <= c_ref0gt; p_ref1gt <= c_ref1gt;
                for (int k = 0; k < 16; k++) begin p_mvd0x[k] <= c_mvd0x[k]; p_mvd0y[k] <= c_mvd0y[k]; p_mvd1x[k] <= c_mvd1x[k]; p_mvd1y[k] <= c_mvd1y[k]; end
                prev_valid <= 1'b1;
                mb_addr <= mb_addr + 14'd1;
                if (mb_x == width_mbs - 8'd1) begin mb_x <= 8'd0; mb_y <= mb_y + 8'd1; row_base <= row_base + {6'd0, width_mbs}; end
                else mb_x <= mb_x + 8'd1;
                state <= S_MB_POS;
            end
            S_DONE: if (jq_cnt == 3'd0 && !eo_busy) begin   // (every SE out: done is a level the parser acts on)
                // the last record still goes to the row above (the next slice may use it)
                above_we <= 1'b1; above_wa <= mb_x[6:0];
                done <= 1'b1;
                state <= S_IDLE;
            end
            // ---------------------------------------------------------------- generic sub-machines
            S_EMIT: if (jq_room) begin
                jq_typ[jq_t[1:0]] <= 1'b0; jq_kind[jq_t[1:0]] <= pw_kind; jq_aux[jq_t[1:0]] <= pw_aux; jq_val[jq_t[1:0]] <= pw_val;
                jq_t <= jq_t + 3'd1;
                state <= ret_state;
            end
            S_TU: begin
                if (!rq_wait) issue(K_DECISION, tu_ctx);
                else if (rsp) begin
                    if (eng_rsp_bin) begin
                        tu_val <= tu_val + 16'd1;
                        if (tu_cmax != 5'd0 && tu_bin + 6'd1 >= {1'b0, tu_cmax}) state <= ret_state;   // cMax reached
                        // an unbounded unary (ref_idx <= 32 bins, mb_qp_delta <= 53) past 63 bins is
                        // not a stream: abandon the slice rather than loop on it
                        else if (tu_bin == 6'd63) begin err_bins <= 1'b1; state <= S_DONE; end
                        else begin tu_bin <= tu_bin + 6'd1; issue(K_DECISION, tu_ctx_next); end
                    end else state <= ret_state;
                end
            end
            S_EG_PREFIX: begin
                if (!rq_wait) issue(K_BYPASS, 9'd0);
                else if (rsp) begin
                    // the prefix of a legal UEGk value never reaches k = 15 (|mvd| < 2^14, |level| < 2^16)
                    if (eng_rsp_bin && eg_k == 4'd15) begin err_bins <= 1'b1; state <= S_DONE; end
                    else if (eng_rsp_bin) begin tu_val <= tu_val + (16'd1 << eg_k); eg_k <= eg_k + 4'd1; issue(K_BYPASS, 9'd0); end
                    else begin
                        state <= (eg_k == 4'd0) ? ret_state : S_EG_SUFFIX;
                        if (eg_k != 4'd0) issue(K_BYPASS, 9'd0);
                    end
                end
            end
            S_EG_SUFFIX: begin
                if (!rq_wait) issue(K_BYPASS, 9'd0);
                else if (rsp) begin
                    tu_val <= tu_val + ({15'd0, eng_rsp_bin} << (eg_k - 4'd1));
                    if (eg_k == 4'd1) state <= ret_state;
                    else begin eg_k <= eg_k - 4'd1; issue(K_BYPASS, 9'd0); end
                end
            end
            S_SIGN: begin
                if (!rq_wait) issue(K_BYPASS, 9'd0);
                else if (rsp) begin val_neg <= eng_rsp_bin; state <= ret_state; end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // the output process: the queue's jobs in order -- a word held until taken, or a block's
    // coefficients from its bank at one a cycle (a read of position em_rp while the two-entry
    // buffer has room, its word landing the next cycle; the head is se_val / em_wait)
    // =====================================================================================
    wire [1:0] jh = jq_h[1:0];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            em_wait <= 1'b0; se_kind <= 8'd0; se_aux <= 8'd0; se_val <= 16'd0; jq_h <= 3'd0; eo_busy <= 1'b0;
            em_rp <= 7'd0; em_rv <= 1'b0; em_sv <= 1'b0; em_lv <= 1'b0; eb_v1 <= 16'd0;
            eb_l0 <= 1'b0; eb_l1 <= 1'b0; eb_n <= 2'd0; em_run <= 1'b0; eo_bank <= 1'b0; eo_n <= 7'd0; bk_done <= 2'b00;
        end else begin
            em_rv <= 1'b0;
            if (em_run) begin
                if (em_rp < eo_n && eb_after < 3'd2) begin
                    em_rv <= 1'b1; em_sv <= sigb[eo_bank][em_rp[5:0]]; em_lv <= (em_rp == eo_n - 7'd1);
                    em_rp <= em_rp + 7'd1;
                end
            end
            if (!eo_busy) begin
                if (jq_cnt != 3'd0) begin
                    eo_busy <= 1'b1;
                    if (!jq_typ[jh]) begin se_kind <= jq_kind[jh]; se_aux <= jq_aux[jh]; se_val <= jq_val[jh]; em_wait <= 1'b1; end
                    else begin
                        se_kind <= SE_COEF; se_aux <= 8'd0; eo_bank <= jq_bank[jh]; eo_n <= jq_n[jh];
                        em_rp <= 7'd0; eb_n <= 2'd0; em_run <= 1'b1;
                    end
                end
            end else if (!em_run) begin
                if (se_ready) begin em_wait <= 1'b0; eo_busy <= 1'b0; jq_h <= jq_h + 3'd1; end
            end else begin
                if (eb_pop && eb_l0) begin
                    em_wait <= 1'b0; em_run <= 1'b0; eb_n <= 2'd0; eo_busy <= 1'b0; jq_h <= jq_h + 3'd1;
                    bk_done[eo_bank] <= !bk_done[eo_bank];
                end else begin
                    case ({em_rv, eb_pop})
                        2'b10: begin                                   // a word lands
                            if (eb_n == 2'd0) begin se_val <= em_land; eb_l0 <= em_lv; em_wait <= 1'b1; end
                            else begin eb_v1 <= em_land; eb_l1 <= em_lv; end
                            eb_n <= eb_n + 2'd1;
                        end
                        2'b01: begin                                   // the head is taken
                            if (eb_n == 2'd2) begin se_val <= eb_v1; eb_l0 <= eb_l1; end
                            else em_wait <= 1'b0;
                            eb_n <= eb_n - 2'd1;
                        end
                        2'b11: begin                                   // both
                            if (eb_n == 2'd2) begin se_val <= eb_v1; eb_l0 <= eb_l1; eb_v1 <= em_land; eb_l1 <= em_lv; end
                            else begin se_val <= em_land; eb_l0 <= em_lv; end
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
