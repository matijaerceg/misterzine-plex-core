// h264/dec/mv_pred.sv -- motion vector and reference index derivation of one inter
// macroblock (ITU-T H.264 8.4.1; non-MBAFF frame or field pictures)
//
//   8.4.1.1    P_Skip: refIdxL0 = 0, mvL0 = 0 when A or B is unavailable or either is
//              (refIdx 0, mv 0), else the 16x16 predictor
//   8.4.1.2.2  spatial direct: refIdxLX = MinPositive over A, B, C of the whole
//              macroblock, directZeroPredictionFlag, mvpLX of the 16x16 partition, then
//              per 4x4 block colZeroFlag from the co-located entry (NOTE 2: mvCol is NOT
//              scaled here, whatever the structures)
//   8.4.1.2.3  temporal direct: refIdxL0 = MapColToList0(refIdxCol) (a table the caller
//              builds per slice), mvCol[1] scaled by vertMvScale (8-193 / 8-194: "/" is
//              truncation toward zero), mvL0 = (DistScaleFactor * mvCol + 128) >> 8,
//              mvL1 = mvL0 - mvCol (8-199 / 8-200), or mvL0 = mvCol, mvL1 = 0 for a
//              long-term pic0 or DiffPicOrderCnt(pic1, pic0) == 0 (the caller folds both
//              into tdir_raw)
//   8.4.1.3    the luma predictor: the 16x8 / 8x16 directional rules (8-203..8-206),
//              else the median (8.4.1.3.1: B and C take A when both are unavailable and
//              A is; exactly one matching refIdx wins)
//   8.4.1.3.2  neighbouring partitions A (x-1, y), B (x, y-1), C (x+predPartWidth, y-1),
//              D (x-1, y-1) with C -> D when C is unavailable (8-214); an intra
//              neighbour or one with predFlagLX 0 is AVAILABLE with refIdx -1, mv 0
//   6.4.11.7   a partition of the current macroblock is available only once decoded
//              (step 7c); a B_Direct_8x8 sub-macroblock counts as decoded when its turn
//              in mbPartIdx order comes, although its values are derived up front
//
// Written from the spec and checked word-exact against tools/h264_recon_ref.py
// (SliceDecoder.p_skip / mb_pred / sub_mb_pred / mvp / nb_part / spatial_direct /
// temporal_direct, the model proven pixel-exact vs ffmpeg and the H.264.1 CABAC set) by
// bench/h264/run_mv_pred.sh over x264 clips, H.264.1 conformance streams and disc
// windows. docs/h264_recon.md S2.
//
// One macroblock per `start` (ignored while busy); every input is held until `done`.
// Outputs are read back through out_blk after done (a registered read: the words of
// block out_blk appear the cycle after). `err` pulses once per offending partition /
// block: a ref_idx of the descriptor naming no list entry (>= num_ref_lX), or a temporal
// co-located reference with no MapColToList0 entry; the derivation continues with index
// 0 so the pipeline never hangs (docs/h264_recon.md S2.5).
//
// Bit layouts of the flat vectors (a "motion word" is {refIdx[5:0] signed, mvx[15:0],
// mvy[15:0]} inside; the ports are laid out as the intake / line memories hold them):
//   nb_data[80*k +: 80]   k = 0..3 A: the left macroblock's right column, rows 0..3
//                                    (its 4x4 blocks 5, 7, 13, 15)
//                         k = 4..7 B: the above macroblock's bottom row, columns 0..3
//                                    (blocks 10, 11, 14, 15)
//                         k = 8    C: the above-right macroblock's block 10
//                         k = 9    D: the above-left macroblock's block 15
//     per entry: [15:0] L0 mvx  [31:16] L0 mvy  [37:32] L0 refIdx (signed)  [38] L0 pred
//                [55:40] L1 mvx [71:56] L1 mvy  [77:72] L1 refIdx           [78] L1 pred
//     nb_avail[k] the macroblock exists, is in this slice and is decoded (6.4.9);
//     nb_intra[k] it is intra coded. With avail 0, or intra 1, or pred 0, the other
//     fields are never read.
//   col_q (block col_ra)   b = 0..15 the co-located 4x4 block of block b of THIS
//                         macroblock (the caller applied Table 8-6 / 8-8: mbAddrCol,
//                         yM); with direct_8x8_inf the unit reads entry 5 * (b >> 2)
//     [15:0] mvCol x  [31:16] mvCol y (in the co-located picture's own units)
//     [36:32] refIdxCol  [44:37] the reference's identity code (bit 7 valid, bits 6:0
//     index map_col)  [45] intra (then nothing else is read)
//   map_col[6*c +: 6]     {valid, MapColToList0[4:0]} for identity code c = 0..127 (20 stores x 4: 80 used)
//   tdir_dsf[11*i +: 11]  DistScaleFactor (signed, -1024..1023, 8-198) of list-0 index i
//   tdir_raw[i]           list-0 index i is long-term, or DiffPicOrderCnt(pic1, pic0) = 0
//   sub_mb_type[4*b8 +: 4], refs[5*(4*lx + slot) +: 5] (slot = mbPartIdx or the
//   sub-macroblock index, absent -> 0), mvd[32*(16*lx + blk) +: 32] = {mvd y, mvd x} per
//   4x4 block (x in [15:0], y in [31:16], both signed), replicated over its partition
//   -- expand_mb() of h264_recon_ref.py; the unit reads the first block of each
//   partition. The readback ports are separate (out_mvx*, out_mvy*); the internal
//   motion word ({refIdx, mvx, mvy}, x above y) never leaves the module.
//
// Datapath. Partitions go in decoding order (mbPartIdx, then subMbPartIdx), seven cycles
// each: GATHER addresses A, then B, then C-or-D, one per cycle, each landing the cycle
// after, through ONE selection over the ten neighbour entries and the already-derived
// blocks of this macroblock (a RAM of one record per partition, `cur_m`)
// (availability decides the C -> D substitution before the mux; three parallel muxes
// cost ~1,300 LUTs more for two cycles a partition, docs/h264_recon.md S6); APPLY computes both lists' predictors at once (the
// directional rules, the median with three comparators per component), adds the mvd,
// writes the partition's blocks through a mask and marks them decoded. Spatial direct
// gathers once for the whole macroblock, takes a cycle for MinPositive and one for the
// two predictors, then writes one block per cycle with its colZeroFlag. Temporal direct
// is a five-stage pipeline over the sixteen blocks (the map read, the DistScaleFactor read added): entry / MapColToList0 / vertical
// scale / DistScaleFactor lookup, the two 11x16 signed products (registered; two DSP
// multipliers or ~150 ALMs each), the +128 >> 8 and the subtraction. Cycles, start to
// done inclusive (measured by the bench, exact per shape): P_Skip / 16x16 4, 16x8 /
// 8x16 6, P_8x8 / B_8x8 2 + 2 per sub-macroblock partition (10 .. 34), B_Skip /
// B_Direct_16x16 spatial 21 / temporal 20, B_8x8 with direct sub-macroblocks spatial
// 21 / temporal 20 + 1 per direct sub-macroblock + 2 per other partition (worst case
// 46: one direct and three 4x4 sub-macroblocks, spatial) -- against a budget of 2,000
// cycles per macroblock. (Before the shared gather mux: 2 cycles a partition, worst case
// 46; now 4, the same shapes +2 per partition. Temporal direct reads its two tables through
// ports: +2 pipeline stages and a pre-read, +3 cycles. The derived blocks in a RAM: +1
// cycle a partition; for clk_dec the geometry (S_PREP) and the predictor (S_MVP_Q)
// registered: +2 more. Worst case 114 (P_8x8 / B_8x8 with sixteen 4x4 partitions) -- the
// bench gated 120. P5b: the neighbour selectors (S_PREP2) and the predictor's decisions
// (S_MVP_Q0) registered too -- +2 a partition, worst case 146, the bench gates 152; ~10
// cycles a macroblock against a budget now ~1,100.)
//
// Quartus 17 caveats observed (CLAUDE.md): no `function automatic`, no N'(expr) casts;
// case blocks, part-selects and generate loops throughout. The per-4x4 arrays are
// register files read through a few structured muxes, never from many sites.

`default_nettype none

module mv_pred (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output logic         busy,
    output logic         done,
    output logic         err,

    // slice parameters (held)
    input  wire  [1:0]   slice_type,          // 0 P, 1 B
    input  wire          direct_spatial,
    input  wire          direct_8x8_inf,
    input  wire  [5:0]   num_ref_l0,
    input  wire  [5:0]   num_ref_l1,
    input  wire          list1_0_is_short,    // RefPicList1[0] marked "used for short-term reference"
    input  wire  [1:0]   vert_scale,          // 0 One_To_One, 1 Frm_To_Fld, 2 Fld_To_Frm (Table 8-8)
    // temporal direct's tables through read ports (data the cycle after the address; they
    // were a 768-bit and a 352-bit bus, docs/h264_recon.md S6.1): MapColToList0 by the
    // co-located reference's code, DistScaleFactor by list-0 index
    output logic [6:0]   map_ra,
    input  wire  [5:0]   map_q,            // {valid, index[4:0]}
    output logic [4:0]   dsf_ra,
    input  wire  [10:0]  dsf_q,
    input  wire  [31:0]  tdir_raw,

    // the macroblock descriptor (held)
    input  wire          skip,
    input  wire  [5:0]   mb_type,             // the raw stream value (P: 0..3, B: 0..22)
    input  wire  [15:0]  sub_mb_type,
    input  wire  [39:0]  refs,
    // the partition's mvds through a read port ({lx, blk}, data {y, x} the cycle after):
    // list 0 read during the first gather cycle, list 1 during the second
    output logic [4:0]   mvd_ra,
    input  wire  [31:0]  mvd_q,

    // the neighbours' motion at 4x4 granularity (held)
    input  wire  [799:0] nb_data,
    input  wire  [9:0]   nb_avail,
    input  wire  [9:0]   nb_intra,

    // the co-located blocks (held)
    // the co-located block of block col_ra (a read port, data the cycle after the address;
    // it was a 768-bit bus of all sixteen, docs/h264_recon.md S6.1)
    output logic [3:0]   col_ra,
    input  wire  [47:0]  col_q,

    // readback after done
    input  wire  [3:0]   out_blk,
    output logic         out_pred0,
    output logic [4:0]   out_ref0,
    output logic [15:0]  out_mvx0,
    output logic [15:0]  out_mvy0,
    output logic         out_pred1,
    output logic [4:0]   out_ref1,
    output logic [15:0]  out_mvx1,
    output logic [15:0]  out_mvy1
);

    localparam [1:0]  SH_16X16 = 2'd0, SH_16X8 = 2'd1, SH_8X16 = 2'd2, SH_SUB = 2'd3;
    localparam [37:0] MW_NONE  = {6'h3F, 32'd0};       // refIdx -1, mv (0, 0)
    localparam [5:0]  B_DIRECT_16X16 = 6'd0, B_8X8 = 6'd22;

    typedef enum logic [3:0] {S_IDLE, S_PREP, S_PREP2, S_GATHER, S_MVP_Q0, S_MVP_Q, S_APPLY, S_SP_REF, S_SP_MVP, S_SP_BLK, S_TD_PRE, S_TD, S_FIN} state_t;
    state_t state;

    // ---- the macroblock's derived blocks: {L1 word, L0 word} ------------------------------
    // One record per partition in a 16-word RAM, at the partition's first block (unique in
    // the macroblock: every block belongs to one partition); pfb[b] names block b's entry.
    // A partition is still written in one cycle; a direct block is its own entry. As
    // registers (16 x 76) it was 1,216 flip-flops and a 16:1 selection at each reader.
    logic [75:0] cur_m [0:15];
    logic [3:0]  pfb [0:15];
    logic        cw_we;
    logic [3:0]  cw_a, cr_a;
    logic [75:0] cw_d, cur_q;
    always_ff @(posedge clk) begin
        if (cw_we) cur_m[cw_a] <= cw_d;
        cur_q <= cur_m[cr_a];
    end
    logic [15:0] dec_done;                             // 6.4.11.7 step 7c


    // ---- the macroblock's shape and the partition walk --------------------------------
    logic        is_b, pskip;
    logic [1:0]  shape;                 // SH_*
    logic [1:0]  pp0, pp1;              // mb-level partition 0 / 1 list use (bit 0 L0, bit 1 L1)
    logic        pi;                    // mbPartIdx of a 16x8 / 8x16 walk
    logic [1:0]  b8, si;                // sub-macroblock and sub-partition of an 8x8 walk
    logic [3:0]  direct_mask;           // B_Direct_8x8 sub-macroblocks (all four for B_Skip / B_Direct_16x16)
    logic        sp_mode;               // the GATHER / MVP is the spatial direct one (16x16 at (0, 0))
    logic        all_direct;
    logic [4:0]  td_cnt;                // temporal pipeline step
    logic [3:0]  sp_blk;                // spatial per-block step

    // the descriptor decoded (combinational from the held inputs; latched at start)
    logic [1:0]  d_shape, d_pp0, d_pp1;
    logic [3:0]  d_direct;
    always_comb begin
        d_shape = SH_16X16; d_pp0 = 2'b01; d_pp1 = 2'b01; d_direct = 4'd0;
        if (slice_type[0]) begin
            if (skip || mb_type == B_DIRECT_16X16) d_direct = 4'hF;
            else if (mb_type == B_8X8) begin
                d_shape = SH_SUB;
                for (int q = 0; q < 4; q++) d_direct[q] = (sub_mb_type[4*q +: 4] == 4'd0);
            end else if (mb_type <= 6'd3) begin
                d_pp0 = mb_type[1:0];
            end else begin
                d_shape = mb_type[0] ? SH_8X16 : SH_16X8;      // mb_type - 4 even -> 16x8
                case ((mb_type - 6'd4) >> 1)                    // B_PAIR_PRED (Table 7-14)
                    6'd0: begin d_pp0 = 2'b01; d_pp1 = 2'b01; end
                    6'd1: begin d_pp0 = 2'b10; d_pp1 = 2'b10; end
                    6'd2: begin d_pp0 = 2'b01; d_pp1 = 2'b10; end
                    6'd3: begin d_pp0 = 2'b10; d_pp1 = 2'b01; end
                    6'd4: begin d_pp0 = 2'b01; d_pp1 = 2'b11; end
                    6'd5: begin d_pp0 = 2'b10; d_pp1 = 2'b11; end
                    6'd6: begin d_pp0 = 2'b11; d_pp1 = 2'b01; end
                    6'd7: begin d_pp0 = 2'b11; d_pp1 = 2'b10; end
                    default: begin d_pp0 = 2'b11; d_pp1 = 2'b11; end
                endcase
            end
        end else if (!skip) begin
            case (mb_type[1:0])
                2'd1: d_shape = SH_16X8;
                2'd2: d_shape = SH_8X16;
                2'd3: d_shape = SH_SUB;
                default: d_shape = SH_16X16;
            endcase
            if (mb_type[2]) d_shape = SH_SUB;                  // P_8x8ref0 (never coded by CABAC)
        end
    end

    // the current sub-macroblock's type: shape (0 8x8, 1 8x4, 2 4x8, 3 4x4), list use, direct
    logic [3:0]  st;
    logic [1:0]  sshape, spred;
    logic        s_direct;
    always_comb begin
        st = sub_mb_type[4*b8 +: 4];
        sshape = 2'd0; spred = 2'b01; s_direct = 1'b0;
        if (!is_b) begin
            sshape = st[1:0];                                  // Table 7-17
        end else begin
            case (st)                                          // Table 7-18
                4'd0:  s_direct = 1'b1;
                4'd1, 4'd2, 4'd3: begin sshape = 2'd0; spred = st[1:0]; end
                4'd4:  begin sshape = 2'd1; spred = 2'b01; end
                4'd5:  begin sshape = 2'd2; spred = 2'b01; end
                4'd6:  begin sshape = 2'd1; spred = 2'b10; end
                4'd7:  begin sshape = 2'd2; spred = 2'b10; end
                4'd8:  begin sshape = 2'd1; spred = 2'b11; end
                4'd9:  begin sshape = 2'd2; spred = 2'b11; end
                4'd10: begin sshape = 2'd3; spred = 2'b01; end
                4'd11: begin sshape = 2'd3; spred = 2'b10; end
                default: begin sshape = 2'd3; spred = 2'b11; end
            endcase
        end
    end

    // the current partition: rectangle, list use, ref slot, last-ness
    logic [4:0]  cx, cy, cw, ch;
    logic [1:0]  cpred;
    logic [1:0]  cslot;
    logic        part_last, sub_last;
    logic        dir_en;                                       // the 16x8 / 8x16 rules apply
    always_comb begin
        cx = 5'd0; cy = 5'd0; cw = 5'd16; ch = 5'd16; cpred = 2'b01; cslot = 2'd0;
        part_last = 1'b1; sub_last = 1'b1; dir_en = 1'b0;
        if (sp_mode || pskip) begin
            cx = 5'd0; cy = 5'd0; cw = 5'd16; ch = 5'd16; cpred = is_b ? 2'b11 : 2'b01;
        end else if (shape == SH_SUB) begin
            cslot = b8;
            cpred = spred;
            cx = {b8[0], 3'b000}; cy = {b8[1], 3'b000};
            case (sshape)
                2'd0: begin cw = 5'd8; ch = 5'd8; sub_last = 1'b1; end
                2'd1: begin cw = 5'd8; ch = 5'd4; cy = cy + {si[0], 2'b00}; sub_last = si[0]; end
                2'd2: begin cw = 5'd4; ch = 5'd8; cx = cx + {si[0], 2'b00}; sub_last = si[0]; end
                default: begin cw = 5'd4; ch = 5'd4; cx = cx + {si[0], 2'b00}; cy = cy + {si[1], 2'b00}; sub_last = (si == 2'd3); end
            endcase
            part_last = (b8 == 2'd3) && (s_direct || sub_last);
        end else begin
            cslot = {1'b0, pi};
            cpred = pi ? pp1 : pp0;
            dir_en = (shape != SH_16X16);
            case (shape)
                SH_16X8: begin cw = 5'd16; ch = 5'd8; cy = {pi, 3'b000}; end
                SH_8X16: begin cw = 5'd8; ch = 5'd16; cx = {pi, 3'b000}; end
                default: begin cw = 5'd16; ch = 5'd16; end
            endcase
            part_last = (shape == SH_16X16) || pi;
        end
    end

    // the partition's 4x4 blocks (6.4.3: block b sits at x = {b[2], b[0]} * 4, y = {b[3], b[1]} * 4)
    logic [15:0] part_mask;
    always_comb begin
        for (int b = 0; b < 16; b++) begin
            part_mask[b] = ({b[2], b[0], 2'b00} >= cx) && ({b[2], b[0], 2'b00} < cx + cw) &&
                           ({b[3], b[1], 2'b00} >= cy) && ({b[3], b[1], 2'b00} < cy + ch);
        end
    end
    wire [3:0] blk0 = {cy[3], cx[3], cy[2], cx[2]};           // the partition's first block

    // the descriptor's refIdx / mvd of this partition, per list
    logic [4:0]  ref5 [0:1];
    logic [31:0] mvd_p [0:1];                                  // {y, x}
    logic [31:0] mvd_c [0:1];                                  // captured from the port
    logic        ref_bad [0:1];
    logic [4:0]  ref_eff [0:1];
    always_comb begin
        for (int l = 0; l < 2; l++) begin
            ref5[l]    = pskip ? 5'd0 : refs[5*(4*l + cslot) +: 5];
            mvd_p[l]   = pskip ? 32'd0 : mvd_c[l];
            ref_bad[l] = cpred[l] && ({1'b0, ref5[l]} >= ((l == 1) ? num_ref_l1 : num_ref_l0));
            ref_eff[l] = ref_bad[l] ? 5'd0 : ref5[l];
        end
    end

    // ---- neighbouring partitions (6.4.11.7 / 6.4.12, non-MBAFF) ---------------------------
    // Lookups 0 A (x-1, y), 1 B (x, y-1), 2 C (x+w, y-1), 3 D (x-1, y-1): a selector
    // 0..15 = a block of this macroblock (available once decoded), 16..19 = A row,
    // 20..23 = B column, 24 = C, 25 = D; (x > 15, y >= 0) is never available.
    // the partition's geometry registered (S_PREP, one cycle before each gather: the walk
    // registers -> geometry -> neighbour selection -> the entry select was one cycle)
    logic [4:0] cx_q, cy_q, cw_q;
    always_ff @(posedge clk) begin cx_q <= cx; cy_q <= cy; cw_q <= cw; end
    wire signed [5:0] scx = {1'b0, cx_q};
    wire signed [5:0] scy = {1'b0, cy_q};
    wire signed [5:0] scw = {1'b0, cw_q};
    logic signed [5:0] lkx [0:3];
    logic signed [5:0] lky [0:3];
    assign lkx[0] = scx - 6'sd1;  assign lky[0] = scy;
    assign lkx[1] = scx;          assign lky[1] = scy - 6'sd1;
    assign lkx[2] = scx + scw;    assign lky[2] = scy - 6'sd1;
    assign lkx[3] = scx - 6'sd1;  assign lky[3] = scy - 6'sd1;
    // 8.4.1.3.2: an intra neighbour is AVAILABLE (with refIdx -1, mv 0 from the normalised entry), unlike an
    // absent one -- the difference steers P_Skip's zero rule, 8.4.1.3.1's substitution
    // and the C -> D replacement
    wire [9:0]  nb_av = nb_avail;
    // the geometry's selectors registered in S_PREP2 (P5b: cw_q -> the neighbour coordinates
    // -> the selector -> C or D -> the 10:1 entry mux -> nb_sel_q was 10.6 ns). Availability
    // is captured with the selector; dec_done is stable from S_PREP2 through a normal gather.
    logic [4:0] lksel_c [0:3];
    logic [1:0] lkk_c [0:3];               // 0 never, 1 nb_av[lki], 2 dec_done[lki]
    logic [3:0] lki_c [0:3];
    logic [4:0] lksel [0:3];
    logic [1:0] lkk [0:3];
    logic       lkav_q [0:3];
    logic       lkav  [0:3];
    genvar g;
    generate for (g = 0; g < 4; g++) begin : LK
        always_comb begin
            lksel_c[g] = 5'd0; lkk_c[g] = 2'd0; lki_c[g] = 4'd0;
            if (lky[g] < 0) begin
                if (lkx[g] < 0)        begin lksel_c[g] = 5'd25; lkk_c[g] = 2'd1; lki_c[g] = 4'd9; end
                else if (lkx[g] < 16)  begin lksel_c[g] = {3'b101, lkx[g][3:2]}; lkk_c[g] = 2'd1; lki_c[g] = {2'b01, lkx[g][3:2]}; end
                else                   begin lksel_c[g] = 5'd24; lkk_c[g] = 2'd1; lki_c[g] = 4'd8; end
            end else if (lkx[g] < 0)   begin lksel_c[g] = {3'b100, lky[g][3:2]}; lkk_c[g] = 2'd1; lki_c[g] = {2'b00, lky[g][3:2]}; end
            else if (lkx[g] < 16)      begin lksel_c[g] = {1'b0, lky[g][3], lkx[g][3], lky[g][2], lkx[g][2]};
                                             lkk_c[g] = 2'd2; lki_c[g] = {lky[g][3], lkx[g][3], lky[g][2], lkx[g][2]}; end
        end
        always_ff @(posedge clk) if (state == S_PREP2) begin
            lksel[g] <= lksel_c[g]; lkk[g] <= lkk_c[g];
            // External availability is fixed for the whole macroblock. Capture it with the
            // selector. dec_done changes only in S_APPLY, before PREP2, or on the direct-SUB
            // fast path in GATHER (which skips these neighbour reads), so the internal flag
            // is also stable until its gather consumes it. This keeps both C/D and the entry
            // address out of the late availability path without adding a cycle.
            lkav_q[g] <= (lkk_c[g] == 2'd1) ? nb_av[lki_c[g]] : (lkk_c[g] == 2'd2) ? dec_done[lki_c[g]] : 1'b0;
        end
        always_comb lkav[g] = lkav_q[g];
    end endgenerate
    // 8.4.1.3.2 step 3: C -> D when C is not available
    wire [4:0] selC = lkav[2] ? lksel[2] : lksel[3];
    wire       avC  = lkav[2] ? 1'b1 : lkav[3];
    wire [4:0] selA = lksel[0], selB = lksel[1];
    wire       avA  = lkav[0], avB = lkav[1];

    // the one gather: A, B, C-or-D addressed in turn (gi 0..2), each landing the cycle after
    // (gi 1..3) -- a block of this macroblock from the RAM, a neighbour entry (nbn_sel)
    logic [1:0]  gi;
    assign mvd_ra = {gi[0], blk0};         // gi 0: list 0, gi 1: list 1 (the partition's first block)
    wire  [4:0]  selX = (gi == 2'd0) ? selA : (gi == 2'd1) ? selB : selC;
    // (perf/retime, 2026-10-13) the neighbour entry mux's select without dec_done: dec_done decides C only when
    // C is inside this macroblock (lkk 2), and then either C is available -- selX is internal (bit 4 clear),
    // read from cur_q, nb_sel_q unused -- or D replaces it, which this select already takes. dec_done ->
    // the C -> D substitution -> the 10:1 entry mux -> nb_sel_q was a census cluster
    wire  [4:0]  selC_nb = (lkk[2] == 2'd2) ? lksel[3] : selC;
    wire  [4:0]  selXn = (gi == 2'd0) ? selA : (gi == 2'd1) ? selB : selC_nb;
    wire         avX  = (gi == 2'd0) ? avA  : (gi == 2'd1) ? avB  : avC;
    logic [4:0]  gs_sel;                   // the entry addressed last cycle
    logic        gs_av;
    // the neighbour entry addressed last cycle, selected raw, then normalised (8.4.1.3.2: an
    // intra neighbour or predFlagLX 0 gives refIdx -1 and mv 0 and stays available; the raw
    // fields are not looked at then) -- normalising all ten before the selection cost ~300 LUTs
    // (selected in the issue cycle and registered with gs_sel, like the RAM's read)
    logic [79:0] nb_sel, nb_sel_q;
    logic        nb_sel_intra, nb_sel_intra_q;
    logic [75:0] nbn_sel;
    always_comb begin
        nb_sel = nb_data[0 +: 80]; nb_sel_intra = nb_intra[0];
        for (int k = 1; k < 10; k++)
            if (selXn[3:0] == k[3:0]) begin nb_sel = nb_data[80*k +: 80]; nb_sel_intra = nb_intra[k]; end
        for (int l = 0; l < 2; l++) begin
            if (nb_sel_intra_q || !nb_sel_q[40*l + 38])
                nbn_sel[38*l +: 38] = MW_NONE;
            else
                nbn_sel[38*l +: 38] = {nb_sel_q[40*l + 32 +: 6], nb_sel_q[40*l +: 16], nb_sel_q[40*l + 16 +: 16]};
        end
    end
    logic [75:0] mwX;
    always_comb begin
        if (!gs_av)          mwX = {MW_NONE, MW_NONE};
        else if (!gs_sel[4]) mwX = cur_q;
        else                 mwX = nbn_sel;
    end

    // the gathered neighbours (GATHER registers them; APPLY / SP_REF / SP_MVP read them)
    logic [75:0] gA, gB, gC;
    logic        gAvA, gAvB, gAvC;

    // ---- spatial direct's macroblock-level state ----------------------------------------
    logic signed [5:0] sp_ref [0:1];
    logic        sp_dz;
    logic [31:0] sp_mv [0:1];                                  // {x, y}

    // ---- 8.4.1.3: the predictor of each list --------------------------------------------
    logic signed [5:0] ref_in [0:1];
    logic [31:0] mvp [0:1];                                    // {x, y}
    logic [31:0] mvp_q [0:1];                                  // registered (S_MVP_Q): the median
                                                               // and the + mvd in one cycle missed clk_dec
    logic signed [5:0] mp_abc [0:1];                           // spatial direct's MinPositive per list
    // the partition's constants registered a cycle ahead (P5b: the walk registers -> cslot ->
    // refIdx -> the compares -> the median -> mvp_q was 11.3 ns): the reference each list
    // predicts for, and which 16x8 / 8x16 directional rule applies. Both hold through the
    // gather; spatial direct's reference is written with sp_ref in S_SP_REF, the cycle
    // before S_MVP_Q reads it.
    logic signed [5:0] ref_in_q [0:1];
    logic        c_dirB, c_dirA, c_dirC;
    generate for (g = 0; g < 2; g++) begin : LST
        wire signed [5:0]  rA  = gA[38*g + 32 +: 6];
        wire signed [5:0]  rB  = gB[38*g + 32 +: 6];
        wire signed [5:0]  rC  = gC[38*g + 32 +: 6];
        wire signed [15:0] axx = gA[38*g + 16 +: 16], axy = gA[38*g +: 16];
        wire signed [15:0] bxx = gB[38*g + 16 +: 16], bxy = gB[38*g +: 16];
        wire signed [15:0] cxx = gC[38*g + 16 +: 16], cxy = gC[38*g +: 16];
        wire eqA0 = (rA == ref_in_q[g]);
        wire eqB0 = (rB == ref_in_q[g]);
        wire eqC0 = (rC == ref_in_q[g]);
        // 8-203 .. 8-206
        wire dirB = c_dirB && eqB0;
        wire dirA = c_dirA && eqA0;
        wire dirC = c_dirC && eqC0;
        // 8.4.1.3.1 step 1
        wire subst = !gAvB && !gAvC && gAvA;
        wire signed [5:0]  rB2 = subst ? rA : rB;
        wire signed [5:0]  rC2 = subst ? rA : rC;
        wire signed [15:0] bx2 = subst ? axx : bxx, by2 = subst ? axy : bxy;
        wire signed [15:0] cx2 = subst ? axx : cxx, cy2 = subst ? axy : cxy;
        wire eqB = (rB2 == ref_in_q[g]);
        wire eqC = (rC2 == ref_in_q[g]);
        wire one = (eqA0 ^ eqB ^ eqC) && !(eqA0 && eqB && eqC);
        // 8-212 / 8-213: Median(a, b, c) = the middle one, from three compares in parallel
        // (a between b and c: a; else b or c by (a > b) == (b > c)) -- the max / min of a, b
        // then a compare with c was two compare levels in series (clk_dec)
        wire abx = (axx > bx2), acx = (axx > cx2), bcx = (bx2 > cx2);
        wire aby = (axy > by2), acy = (axy > cy2), bcy = (by2 > cy2);
        // the decisions registered (S_MVP_Q0, P5b: the substitution, the compares, the median
        // and the rule muxes in one cycle were 10.3 ns); S_MVP_Q only selects among the
        // gathered vectors, which hold
        logic q_abx, q_acx, q_bcx, q_aby, q_acy, q_bcy, q_eqA0, q_eqB, q_dirA, q_dirB, q_dirC, q_one;
        always_ff @(posedge clk) begin
            q_abx <= abx; q_acx <= acx; q_bcx <= bcx; q_aby <= aby; q_acy <= acy; q_bcy <= bcy;
            q_eqA0 <= eqA0; q_eqB <= eqB; q_dirA <= dirA; q_dirB <= dirB; q_dirC <= dirC; q_one <= one;
        end
        wire signed [15:0] medx = (q_abx != q_acx) ? axx : (q_abx == q_bcx) ? bx2 : cx2;
        wire signed [15:0] medy = (q_aby != q_acy) ? axy : (q_aby == q_bcy) ? by2 : cy2;
        // 8.4.1.2.2 MinPositive over A, B, C (8-184 / 8-185, 8-187: the raw refs after the C -> D substitution)
        wire signed [5:0] mpbc  = (!rB[5] && !rC[5])   ? ((rB < rC)   ? rB : rC)   : ((rB > rC)   ? rB : rC);
        wire signed [5:0] mpabc = (!rA[5] && !mpbc[5]) ? ((rA < mpbc) ? rA : mpbc) : ((rA > mpbc) ? rA : mpbc);
        assign mp_abc[g] = mpabc;
        always_comb begin
            if (q_dirB)      mvp[g] = {bxx, bxy};
            else if (q_dirA) mvp[g] = {axx, axy};
            else if (q_dirC) mvp[g] = {cxx, cxy};
            else if (q_one)  mvp[g] = q_eqA0 ? {axx, axy} : q_eqB ? {bx2, by2} : {cx2, cy2};
            else             mvp[g] = {medx, medy};
        end
    end endgenerate
    always_comb begin
        for (int l = 0; l < 2; l++)
            ref_in[l] = sp_mode ? {1'b0, sp_ref[l][4:0]} : {1'b0, ref_eff[l]};
    end
    always_ff @(posedge clk) begin
        for (int l = 0; l < 2; l++) begin
            if (state == S_SP_REF)
                ref_in_q[l] <= (mp_abc[0][5] && mp_abc[1][5]) ? 6'sd0 : {1'b0, mp_abc[l][4:0]};
            else
                ref_in_q[l] <= ref_in[l];
        end
        c_dirB <= dir_en && (shape == SH_16X8) && !pi;
        c_dirA <= dir_en && (((shape == SH_16X8) && pi) || ((shape == SH_8X16) && !pi));
        c_dirC <= dir_en && (shape == SH_8X16) && pi;
    end

    // 8.4.1.1: the P_Skip zero conditions on the list-0 data of A and B
    wire signed [5:0] rA0 = gA[37:32], rB0 = gB[37:32];
    wire skip_zero = !gAvA || !gAvB || (rA0 == 6'sd0 && gA[31:0] == 32'd0) || (rB0 == 6'sd0 && gB[31:0] == 32'd0);


    // ---- the co-located entry of a block (spatial per block, temporal stage 0) ------------
    logic [3:0]  col_blk;
    wire  [3:0]  col_idx = direct_8x8_inf ? {col_blk[3:2], col_blk[3:2]} : col_blk;   // 5 * (blk >> 2)
    assign col_ra = col_idx;               // the block read next (col_blk runs one ahead)
    wire  [47:0] ce      = col_q;
    wire  [15:0] ce_mvx  = ce[15:0];
    wire  [15:0] ce_mvy  = ce[31:16];
    wire  [4:0]  ce_ref  = ce[36:32];
    wire  [7:0]  ce_code = ce[44:37];
    wire         ce_intra = ce[45];
    // spatial: colZeroFlag (mvCol in its own units, -1..1 both components)
    wire ce_x_small = (ce_mvx[15:1] == 15'd0) || (ce_mvx == 16'hFFFF);
    wire ce_y_small = (ce_mvy[15:1] == 15'd0) || (ce_mvy == 16'hFFFF);
    wire col_zero = list1_0_is_short && !ce_intra && (ce_ref == 5'd0) && ce_x_small && ce_y_small;
    // temporal: MapColToList0 and the vertical scale
    assign map_ra = ce_code[6:0];          // stage a: the map read with the entry
    logic        ta_v, ta_wr, ta_intra, ta_cval;
    logic [3:0]  ta_blk;
    logic signed [15:0] ta_mvx, ta_mvy;
    wire         mc_ok   = ta_intra || (map_q[5] && ta_cval);      // stage b: the map arrived
    wire  [4:0]  td_ref0 = (ta_intra || !mc_ok) ? 5'd0 : map_q[4:0];
    assign dsf_ra = td_ref0;               // stage b: the DistScaleFactor read
    logic        tb_v, tb_wr, tb_raw, tb_err;
    logic [3:0]  tb_blk;
    logic [4:0]  tb_ref0;
    logic signed [15:0] tb_mvx, tb_mvy;
    wire signed [15:0] ce_mvy_s = ce_mvy;
    wire signed [15:0] ce_mvy_neg = {15'd0, ce_mvy[15]};       // +1 before the shift when negative
    logic signed [15:0] td_mvy_s;
    always_comb begin
        case (vert_scale)
            2'd1:    td_mvy_s = (ce_mvy_s + ce_mvy_neg) >>> 1;                      // 8-193, truncation toward zero
            2'd2:    td_mvy_s = {ce_mvy[14:0], 1'b0};                              // 8-194
            default: td_mvy_s = ce_mvy;
        endcase
    end

    // the temporal pipeline registers
    logic        t1_v, t1_wr, t1_raw, t1_err;
    logic [3:0]  t1_blk;
    logic [4:0]  t1_ref0;
    logic signed [15:0] t1_mvx, t1_mvy;
    logic signed [10:0] t1_dsf;
    logic        t2_v, t2_wr, t2_raw, t2_err;
    logic [3:0]  t2_blk;
    logic [4:0]  t2_ref0;
    logic signed [15:0] t2_mvx, t2_mvy;
    logic signed [26:0] t2_px, t2_py;
    wire  signed [26:0] t2_sx = t2_px + 27'sd128;
    wire  signed [26:0] t2_sy = t2_py + 27'sd128;
    wire  signed [15:0] td_mv0x = t2_raw ? t2_mvx : t2_sx[23:8];               // 8-199 (>> 8 is arithmetic)
    wire  signed [15:0] td_mv0y = t2_raw ? t2_mvy : t2_sy[23:8];
    wire  signed [15:0] td_mv1x = t2_raw ? 16'sd0 : td_mv0x - t2_mvx;           // 8-200
    wire  signed [15:0] td_mv1y = t2_raw ? 16'sd0 : td_mv0y - t2_mvy;

    // the partition's list use, blocks and references, registered for S_APPLY (P6 timing:
    // sub_mb_type -> the 8x8's sub-shape and pred flags -> the write data's list select ->
    // the motion RAM was 9.7 ns at 100 C). The partition's geometry is set several states
    // before its S_APPLY (S_PREP, S_PREP2, the gather, S_MVP_Q0, S_MVP_Q), so a copy one
    // cycle behind holds the current partition's values there. No cycle is added.
    logic [1:0]  cpred_q;
    logic [15:0] part_mask_q;
    logic [4:0]  ref_eff_q [0:1];
    always_ff @(posedge clk) begin
        cpred_q <= cpred; part_mask_q <= part_mask;
        ref_eff_q[0] <= ref_eff[0]; ref_eff_q[1] <= ref_eff[1];
    end

    // ---- the block write (one description for APPLY, SP_BLK and the temporal stage 2) ----
    logic [15:0] wr_mask;
    logic [3:0]  wr_ent;                   // the RAM entry: the partition's first block
    logic [37:0] wr_w0, wr_w1;
    logic        wr_done;
    logic [31:0] mv_sum [0:1];
    always_comb begin
        wr_mask = 16'd0; wr_ent = blk0; wr_w0 = MW_NONE; wr_w1 = MW_NONE; wr_done = 1'b0;
        for (int l = 0; l < 2; l++) begin
            mv_sum[l] = {mvp_q[l][31:16] + mvd_p[l][15:0], mvp_q[l][15:0] + mvd_p[l][31:16]};   // x, y
        end
        case (state)
            S_APPLY: begin
                wr_mask = part_mask_q; wr_done = 1'b1;
                if (pskip) wr_w0 = {6'd0, (skip_zero ? 32'd0 : mvp_q[0])};
                else begin
                    if (cpred_q[0]) wr_w0 = {1'b0, ref_eff_q[0], mv_sum[0]};
                    if (cpred_q[1]) wr_w1 = {1'b0, ref_eff_q[1], mv_sum[1]};
                end
            end
            S_SP_BLK: begin
                wr_mask = direct_mask[sp_blk[3:2]] ? (16'd1 << sp_blk) : 16'd0; wr_ent = sp_blk;
                if (!sp_ref[0][5]) wr_w0 = {sp_ref[0], ((sp_dz || (sp_ref[0] == 6'sd0 && col_zero)) ? 32'd0 : sp_mv[0])};
                if (!sp_ref[1][5]) wr_w1 = {sp_ref[1], ((sp_dz || (sp_ref[1] == 6'sd0 && col_zero)) ? 32'd0 : sp_mv[1])};
            end
            S_TD: begin
                wr_mask = (t2_v && t2_wr) ? (16'd1 << t2_blk) : 16'd0; wr_ent = t2_blk;
                wr_w0 = {1'b0, t2_ref0, td_mv0x, td_mv0y};
                wr_w1 = {6'd0, td_mv1x, td_mv1y};
            end
            default: ;
        endcase
    end
    // the RAM's ports: the write above; the read by the gather, else the readback
    assign cw_we = (wr_mask != 16'd0);
    assign cw_a  = wr_ent;
    assign cw_d  = {wr_w1, wr_w0};
    assign cr_a  = (state == S_GATHER) ? pfb[selX[3:0]] : pfb[out_blk];

    // ---- the sequencer ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0; err <= 1'b0;
            is_b <= 1'b0; pskip <= 1'b0; shape <= SH_16X16; pp0 <= 2'b01; pp1 <= 2'b01;
            pi <= 1'b0; b8 <= 2'd0; si <= 2'd0; direct_mask <= 4'd0; sp_mode <= 1'b0; all_direct <= 1'b0;
            td_cnt <= 5'd0; sp_blk <= 4'd0; col_blk <= 4'd0; gi <= 2'd0; mvd_c[0] <= '0; mvd_c[1] <= '0;
            dec_done <= 16'd0;
            gA <= {MW_NONE, MW_NONE}; gB <= {MW_NONE, MW_NONE}; gC <= {MW_NONE, MW_NONE};
            gAvA <= 1'b0; gAvB <= 1'b0; gAvC <= 1'b0;
            sp_ref[0] <= 6'sd0; sp_ref[1] <= 6'sd0; sp_dz <= 1'b0; sp_mv[0] <= 32'd0; sp_mv[1] <= 32'd0;
            mvp_q[0] <= 32'd0; mvp_q[1] <= 32'd0;
            ta_v <= 1'b0; ta_wr <= 1'b0; ta_intra <= 1'b0; ta_cval <= 1'b0; ta_blk <= 4'd0; ta_mvx <= 16'sd0; ta_mvy <= 16'sd0;
            tb_v <= 1'b0; tb_wr <= 1'b0; tb_raw <= 1'b0; tb_err <= 1'b0; tb_blk <= 4'd0; tb_ref0 <= 5'd0; tb_mvx <= 16'sd0; tb_mvy <= 16'sd0;
            t1_v <= 1'b0; t1_wr <= 1'b0; t1_raw <= 1'b0; t1_err <= 1'b0; t1_blk <= 4'd0; t1_ref0 <= 5'd0;
            t1_mvx <= 16'sd0; t1_mvy <= 16'sd0; t1_dsf <= 11'sd0;
            t2_v <= 1'b0; t2_wr <= 1'b0; t2_raw <= 1'b0; t2_err <= 1'b0; t2_blk <= 4'd0; t2_ref0 <= 5'd0;
            t2_mvx <= 16'sd0; t2_mvy <= 16'sd0; t2_px <= 27'sd0; t2_py <= 27'sd0;
            for (int b = 0; b < 16; b++) pfb[b] <= b[3:0];
            gs_sel <= 5'd0; gs_av <= 1'b0; nb_sel_q <= '0; nb_sel_intra_q <= 1'b0;
        end else begin
            done <= 1'b0;
            err  <= 1'b0;

            // the block write
            for (int b = 0; b < 16; b++)
                if (wr_mask[b]) pfb[b] <= wr_ent;
            gs_sel <= selX; gs_av <= avX; nb_sel_q <= nb_sel; nb_sel_intra_q <= nb_sel_intra;
            if (wr_done) dec_done <= dec_done | wr_mask;

            // the temporal pipeline (advances only in S_TD; stage 0 reads col_blk = td_cnt)
            if (state == S_TD) begin
                ta_v <= !td_cnt[4]; ta_blk <= td_cnt[3:0]; ta_wr <= direct_mask[td_cnt[3:2]];
                ta_mvx <= ce_intra ? 16'sd0 : $signed(ce_mvx);
                ta_mvy <= ce_intra ? 16'sd0 : td_mvy_s;
                ta_intra <= ce_intra; ta_cval <= ce_code[7];
                tb_v <= ta_v; tb_blk <= ta_blk; tb_wr <= ta_wr; tb_mvx <= ta_mvx; tb_mvy <= ta_mvy;
                tb_ref0 <= td_ref0; tb_raw <= tdir_raw[td_ref0]; tb_err <= !mc_ok;
                t1_v <= tb_v; t1_blk <= tb_blk; t1_wr <= tb_wr;
                t1_mvx <= tb_mvx; t1_mvy <= tb_mvy;
                t1_ref0 <= tb_ref0; t1_raw <= tb_raw; t1_dsf <= dsf_q; t1_err <= tb_err;
                t2_v <= t1_v; t2_blk <= t1_blk; t2_wr <= t1_wr; t2_raw <= t1_raw; t2_ref0 <= t1_ref0;
                t2_err <= t1_err; t2_mvx <= t1_mvx; t2_mvy <= t1_mvy;
                t2_px <= t1_dsf * t1_mvx;
                t2_py <= t1_dsf * t1_mvy;
                if (t2_v && t2_wr && t2_err) err <= 1'b1;
            end else begin
                ta_v <= 1'b0; tb_v <= 1'b0; t1_v <= 1'b0; t2_v <= 1'b0;
            end

            case (state)
                S_IDLE: if (start) begin
                    busy <= 1'b1;
                    dec_done <= 16'd0;
                    is_b <= slice_type[0];
                    pskip <= !slice_type[0] && skip;
                    shape <= d_shape; pp0 <= d_pp0; pp1 <= d_pp1;
                    direct_mask <= d_direct;
                    all_direct <= (d_direct == 4'hF) && (d_shape != SH_SUB);
                    pi <= 1'b0; b8 <= 2'd0; si <= 2'd0;
                    sp_mode <= 1'b0; td_cnt <= 5'd0; sp_blk <= 4'd0; col_blk <= 4'd0;
                    if (d_direct != 4'd0) begin
                        if (direct_spatial) begin sp_mode <= 1'b1; state <= S_PREP; end
                        else state <= S_TD_PRE;
                    end else state <= S_PREP;
                end

                S_PREP: state <= S_PREP2;
                S_PREP2: state <= S_GATHER;
                S_GATHER: begin
                    if (!sp_mode && shape == SH_SUB && s_direct) begin
                        // a B_Direct_8x8 sub-macroblock: derived up front, decoded now (6.4.11.7)
                        dec_done <= dec_done | (16'hF << {b8, 2'b00});
                        if (b8 == 2'd3) state <= S_FIN;
                        else begin b8 <= b8 + 2'd1; state <= S_PREP; end
                    end else begin
                        // gi 0..2 address A, B, C-or-D; each lands (mwX, gs_av) the cycle after
                        case (gi)
                            2'd0: gi <= 2'd1;
                            2'd1: begin gA <= mwX; gAvA <= gs_av; gi <= 2'd2; mvd_c[0] <= mvd_q; end
                            2'd2: begin gB <= mwX; gAvB <= gs_av; gi <= 2'd3; mvd_c[1] <= mvd_q; end
                            default: begin
                                gC <= mwX; gAvC <= gs_av; gi <= 2'd0;
                                if (sp_mode) state <= S_SP_REF; else state <= S_MVP_Q0;
                            end
                        endcase
                    end
                end

                S_APPLY: begin
                    if ((cpred[0] && ref_bad[0]) || (cpred[1] && ref_bad[1])) err <= 1'b1;
                    if (part_last) state <= S_FIN;
                    else begin
                        state <= S_PREP;
                        if (shape == SH_SUB) begin
                            if (sub_last) begin b8 <= b8 + 2'd1; si <= 2'd0; end
                            else si <= si + 2'd1;
                        end else pi <= 1'b1;
                    end
                end

                S_SP_REF: begin
                    // 8-184 .. 8-190
                    if (mp_abc[0][5] && mp_abc[1][5]) begin
                        sp_ref[0] <= 6'sd0; sp_ref[1] <= 6'sd0; sp_dz <= 1'b1;
                    end else begin
                        sp_ref[0] <= mp_abc[0]; sp_ref[1] <= mp_abc[1]; sp_dz <= 1'b0;
                    end
                    col_blk <= 4'd0;                 // block 0's co-located entry read during S_SP_MVP
                    state <= S_MVP_Q0;
                end

                S_MVP_Q0: state <= S_MVP_Q;       // the decisions registered (P5b)
                S_MVP_Q: begin
                    mvp_q[0] <= mvp[0]; mvp_q[1] <= mvp[1];
                    if (sp_mode) state <= S_SP_MVP; else state <= S_APPLY;
                end
                S_SP_MVP: begin
                    sp_mv[0] <= mvp_q[0]; sp_mv[1] <= mvp_q[1];
                    sp_mode <= 1'b0;
                    col_blk <= 4'd1; sp_blk <= 4'd0;     // col_blk one block ahead of sp_blk
                    state <= S_SP_BLK;
                end

                S_SP_BLK: begin
                    sp_blk <= sp_blk + 4'd1;
                    col_blk <= col_blk + 4'd1;
                    if (sp_blk == 4'd15) begin if (all_direct) state <= S_FIN; else state <= S_PREP; end
                end

                S_TD_PRE: begin                      // block 0's co-located entry read
                    col_blk <= 4'd1;
                    state <= S_TD;
                end

                S_TD: begin                          // col_blk one block ahead of td_cnt
                    td_cnt <= td_cnt + 5'd1;
                    col_blk <= col_blk + 4'd1;
                    if (td_cnt == 5'd19) begin if (all_direct) state <= S_FIN; else state <= S_PREP; end
                end

                S_FIN: begin
                    done <= 1'b1; busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- the readback port: the RAM read of out_blk's entry (idle only) -------------------
    wire [75:0] rd = cur_q;
    always_comb begin
        out_pred0 = !rd[37];   out_ref0 = rd[37] ? 5'd0 : rd[36:32];   out_mvx0 = rd[31:16]; out_mvy0 = rd[15:0];
        out_pred1 = !rd[75];   out_ref1 = rd[75] ? 5'd0 : rd[74:70];   out_mvx1 = rd[69:54]; out_mvy1 = rd[53:38];
    end

endmodule

`default_nettype wire
