// h264/dec/deblock_bs.sv -- the boundary filtering strength bS (ITU-T H.264 8.7.2.1)
//
// For one pair of 4x4 luma blocks across one edge (p holds p0, q holds q0), non-MBAFF,
// one registered stage: the inputs of one cycle give bs with out_valid the next.
// Bit-exact against tools/h264_recon_ref.py's boundary_strength (docs/h264_recon.md
// S2.4), scored by bench/h264/run_deblock.sh.
//
// The rules of 8.7.2.1 as they read without MBAFF (mixedModeEdgeFlag is always 0;
// SP / SI slices never come, the front end refuses the profile):
//   4  a macroblock edge with either macroblock intra, in a frame picture ("both in
//      frame macroblocks"), or in a field picture on a VERTICAL edge (the second bullet:
//      "field_pic_flag is equal to 1, verticalEdgeFlag is equal to 1"). A horizontal
//      macroblock edge of a field picture with intra falls through to
//   3  either macroblock intra (any other edge)
//   2  the 4x4 block holding p0 OR the one holding q0 has non-zero transform
//      coefficient levels (nz: a caller's per-block flag; for Intra16x16 / chroma this
//      is the caller's business as 8.7.2.1 defines it)
//   1  a different number of motion vectors, or different reference PICTURES (NOTE 1:
//      which pictures are referenced, regardless of list or index -- the caller's
//      refpic codes name pictures, equal codes mean the same picture, so the test is
//      on the multiset {refpic0?, refpic1?} of each side); or the vectors of the same
//      picture differ by >= 4 in a component in quarter luma FRAME samples: 4
//      horizontally, and vertically 4 in a frame picture but 2 in a field picture (NOTE
//      3; the model's vlim and JM's mvlimit). With two vectors each: two different
//      pictures -> pair by picture (like with like, whichever list holds it); the same
//      picture twice -> bS 1 only when BOTH the straight pairing (L0-L0, L1-L1) and the
//      crossed one (L0-L1, L1-L0) have a far component (the last bullet of the clause).
//   0  otherwise (including both sides with no vector at all, a case a conformant
//      caller never presents: an inter block has at least one)
//
// The 16-bit vectors are compared through a 17-bit difference; "near" is tested on the
// difference's top bits (a difference d is in -3..3 iff d[16:2] is all zeros, or all
// ones with d[1:0] != 0), no absolute value, no `function automatic` (Quartus 17).

`default_nettype none

module deblock_bs (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    // the block holding p0
    input  wire        p_intra,
    input  wire        p_nz,
    input  wire        p_pred0, p_pred1,
    input  wire  [7:0] p_refpic0, p_refpic1,
    input  wire signed [15:0] p_mv0x, p_mv0y, p_mv1x, p_mv1y,
    // the block holding q0
    input  wire        q_intra,
    input  wire        q_nz,
    input  wire        q_pred0, q_pred1,
    input  wire  [7:0] q_refpic0, q_refpic1,
    input  wire signed [15:0] q_mv0x, q_mv0y, q_mv1x, q_mv1y,

    input  wire        mb_edge,      // the edge is a macroblock edge
    input  wire        vertical,     // verticalEdgeFlag
    input  wire        field,        // field_pic_flag

    output logic       out_valid,
    output logic [2:0] bs
);

    // ---- the four pairings' differences (17-bit signed) ------------------------------------
    wire signed [16:0] dx00 = {p_mv0x[15], p_mv0x} - {q_mv0x[15], q_mv0x};
    wire signed [16:0] dy00 = {p_mv0y[15], p_mv0y} - {q_mv0y[15], q_mv0y};
    wire signed [16:0] dx11 = {p_mv1x[15], p_mv1x} - {q_mv1x[15], q_mv1x};
    wire signed [16:0] dy11 = {p_mv1y[15], p_mv1y} - {q_mv1y[15], q_mv1y};
    wire signed [16:0] dx01 = {p_mv0x[15], p_mv0x} - {q_mv1x[15], q_mv1x};
    wire signed [16:0] dy01 = {p_mv0y[15], p_mv0y} - {q_mv1y[15], q_mv1y};
    wire signed [16:0] dx10 = {p_mv1x[15], p_mv1x} - {q_mv0x[15], q_mv0x};
    wire signed [16:0] dy10 = {p_mv1y[15], p_mv1y} - {q_mv0y[15], q_mv0y};

    // |d| < 4: d in -3..3
    wire near4_x00 = (dx00[16:2] == 15'd0) || ((&dx00[16:2]) && (dx00[1:0] != 2'b00));
    wire near4_y00 = (dy00[16:2] == 15'd0) || ((&dy00[16:2]) && (dy00[1:0] != 2'b00));
    wire near4_x11 = (dx11[16:2] == 15'd0) || ((&dx11[16:2]) && (dx11[1:0] != 2'b00));
    wire near4_y11 = (dy11[16:2] == 15'd0) || ((&dy11[16:2]) && (dy11[1:0] != 2'b00));
    wire near4_x01 = (dx01[16:2] == 15'd0) || ((&dx01[16:2]) && (dx01[1:0] != 2'b00));
    wire near4_y01 = (dy01[16:2] == 15'd0) || ((&dy01[16:2]) && (dy01[1:0] != 2'b00));
    wire near4_x10 = (dx10[16:2] == 15'd0) || ((&dx10[16:2]) && (dx10[1:0] != 2'b00));
    wire near4_y10 = (dy10[16:2] == 15'd0) || ((&dy10[16:2]) && (dy10[1:0] != 2'b00));
    // |d| < 2: d in -1..1 (the vertical limit of a field picture)
    wire near2_y00 = (dy00[16:1] == 16'd0) || ((&dy00[16:1]) && dy00[0]);
    wire near2_y11 = (dy11[16:1] == 16'd0) || ((&dy11[16:1]) && dy11[0]);
    wire near2_y01 = (dy01[16:1] == 16'd0) || ((&dy01[16:1]) && dy01[0]);
    wire near2_y10 = (dy10[16:1] == 16'd0) || ((&dy10[16:1]) && dy10[0]);
    wire neary_00 = field ? near2_y00 : near4_y00;
    wire neary_11 = field ? near2_y11 : near4_y11;
    wire neary_01 = field ? near2_y01 : near4_y01;
    wire neary_10 = field ? near2_y10 : near4_y10;
    // a pairing is far when either component is
    wire far00 = !(near4_x00 && neary_00);
    wire far11 = !(near4_x11 && neary_11);
    wire far01 = !(near4_x01 && neary_01);
    wire far10 = !(near4_x10 && neary_10);

    // ---- the vector counts and the picture sets -----------------------------------------------
    wire [1:0] p_n = {1'b0, p_pred0} + {1'b0, p_pred1};
    wire [1:0] q_n = {1'b0, q_pred0} + {1'b0, q_pred1};
    wire       n_diff = (p_n != q_n);
    // the one vector of a single-vector block: list 0 if it predicts from it, else list 1
    wire [7:0] p_ref_a = p_pred0 ? p_refpic0 : p_refpic1;
    wire [7:0] q_ref_a = q_pred0 ? q_refpic0 : q_refpic1;
    wire       far_a   = p_pred0 ? (q_pred0 ? far00 : far01) : (q_pred0 ? far10 : far11);
    // the same multiset of pictures (only meaningful when the counts agree)
    wire straight_pics = (p_refpic0 == q_refpic0) && (p_refpic1 == q_refpic1);
    wire crossed_pics  = (p_refpic0 == q_refpic1) && (p_refpic1 == q_refpic0);
    logic same_set, mv_far;
    always_comb begin
        case (p_n)
            2'd0: begin same_set = 1'b1; mv_far = 1'b0; end
            2'd1: begin same_set = (p_ref_a == q_ref_a); mv_far = far_a; end
            default: begin
                same_set = straight_pics || crossed_pics;
                if (p_refpic0 != p_refpic1)
                    // two different pictures: pair like with like
                    mv_far = (p_refpic0 == q_refpic0) ? (far00 || far11) : (far01 || far10);
                else
                    // the same picture twice: both pairings must be far
                    mv_far = (far00 || far11) && (far01 || far10);
            end
        endcase
    end

    // ---- the strength --------------------------------------------------------------------------
    wire intra  = p_intra || q_intra;
    wire bs4    = mb_edge && intra && (!field || vertical);
    wire bs1    = n_diff || !same_set || mv_far;
    logic [2:0] bs_c;
    always_comb begin
        if (bs4)                  bs_c = 3'd4;
        else if (intra)           bs_c = 3'd3;
        else if (p_nz || q_nz)    bs_c = 3'd2;
        else if (bs1)             bs_c = 3'd1;
        else                      bs_c = 3'd0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            bs <= 3'd0;
        end else begin
            out_valid <= in_valid;
            bs <= bs_c;
        end
    end

endmodule

`default_nettype wire
