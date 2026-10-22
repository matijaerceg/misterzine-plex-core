// h264/dec/recon_slice_tab.sv -- the per-slice tables the macroblock pipeline reads
// (docs/h264_recon.md S2): built once after recon_lists finishes, before the slice's
// first macroblock.
//
//   * code[lx][i]: the reference picture of list entry i as {valid, store[3:0],
//     struct[1:0]} (the identity the deblocking filter compares, 8.7.2.1 NOTE 1, and
//     the address of the samples); poc[lx][i]: its PicOrderCnt (a field's own, a
//     frame's Min(top, bottom), 8-1); lng[lx][i]: marked long-term;
//   * the co-located picture of direct prediction (Table 8-6, non-MBAFF): RefPicList1[0]
//     as it was coded -- a frame (side-info half F), a field of a frame coded as two
//     fields (its own half), or, for a frame decoded now, the field of a complementary
//     pair closer in POC -- and vertMvScale (Table 8-8: One_To_One, Frm_To_Fld,
//     Fld_To_Frm), and whether RefPicList1[0] is short-term (colZeroFlag, 8.4.1.2.2);
//   * temporal direct (8.4.1.2.3): per list-0 index, DistScaleFactor (dsf_calc) and the
//     "mvL0 = mvCol, mvL1 = 0" case (long-term or DiffPicOrderCnt(pic1, pic0) == 0);
//     MapColToList0 as a 64-entry table from the co-located reference's code to the
//     LOWEST list-0 index that references it under the vertMvScale rule.
// Only B slices need the direct tables; P slices finish after the codes.

`default_nettype none

module recon_slice_tab
    import h264_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         go,
    output logic        done,
    output logic        busy,

    input  wire  [1:0]  slice_type,
    input  wire         field_pic,
    input  wire  [1:0]  cur_struct,        // 0 F, 1 T, 2 B
    input  wire signed [31:0] cur_poc,
    input  wire  [5:0]  num_ref_l0,
    input  wire  [5:0]  num_ref_l1,

    // recon_lists' read ports (owned while busy)
    output logic [5:0]  l0_idx,
    input  wire  [7:0]  l0_entry,
    output logic [5:0]  l1_idx,
    input  wire  [7:0]  l1_entry,
    // the store state
    input  wire  [NSTORE*2-1:0]  st_ref_t,
    input  wire  [NSTORE*2-1:0]  st_ref_b,
    // the store table's POCs (recon_dpb's RAM): the address this cycle, the data the next
    output logic [4:0]  tab_ra,
    input  wire signed [31:0] tab_q_poc_t,
    input  wire signed [31:0] tab_q_poc_b,
    input  wire  [NSTORE-1:0] st_frame,

    // the tables
    // code[lx][i] in two 32-word RAMs (one per list) behind registered read ports -- 512
    // registers and a 32:1 selection per reader as a register table. The ports are
    // recon_mb's (its motion read-back) while this unit is idle; list 0's is the
    // MapColToList0 walk's while it runs
    input  wire  [4:0]  code_ra0,
    input  wire  [4:0]  code_ra1,
    output logic [7:0]  code_q0,
    output logic [7:0]  code_q1,
    // PicOrderCnt per list entry: two 32-word RAMs (one per list), read through a
    // registered port -- 2,048 registers and four 32:1 muxes as a register table. The
    // port is recon_inter's while this unit is idle (it runs only between slices).
    input  wire  [4:0]  poc_ra0,
    input  wire  [4:0]  poc_ra1,
    output logic [31:0] poc_q0,
    output logic [31:0] poc_q1,
    output logic [31:0] lng,                     // list-0 long-term flags
    output logic [31:0] lng1,
    output logic [4:0]  col_store,
    output logic [1:0]  col_half,                // 0 F, 1 T, 2 B
    output logic        col_is_field,
    output logic [1:0]  vert_scale,              // 0 One_To_One, 1 Frm_To_Fld, 2 Fld_To_Frm
    output logic        l1_0_short,
    // temporal direct's tables, in RAM, read by mv_pred (data the cycle after the address):
    // DistScaleFactor per list-0 index; MapColToList0 {valid, index[4:0]} by the
    // co-located reference's code[6:0] (a Fld_To_Frm frame entry is stored once, at its
    // parity-0 code, and the read folds the parity -- the map was 768 registers)
    input  wire  [4:0]  dsf_ra,
    output logic signed [10:0] dsf_q,
    output logic [31:0] tdir_raw,
    input  wire  [6:0]  map_ra,
    output logic [5:0]  map_q
);

    localparam [1:0] UNUSED = 2'd0, SHORT = 2'd1, LONG = 2'd2;

    typedef enum logic [3:0] {T_IDLE, T_CODES, T_COL_RD, T_COL0, T_COL, T_MCLR, T_MAP, T_DSF_GO, T_DSF_RD, T_DSF_WAIT, T_DONE} tstate_t;
    tstate_t ts;
    logic [5:0] i;

    logic signed [10:0] dsf_m [0:31];
    logic [5:0]  map_m [0:127];
    logic        dsf_we, map_we;
    logic [4:0]  dsf_wa;
    logic [6:0]  map_wa;
    logic signed [10:0] dsf_wd;
    logic [5:0]  map_wd;
    logic [6:0]  mclr;                     // the clear walk's address
    wire  [6:0]  map_ra_f = (vert_scale == 2'd2) ? {map_ra[6:2], 2'd0} : map_ra;
    always_ff @(posedge clk) begin
        if (dsf_we) dsf_m[dsf_wa] <= dsf_wd;
        if (map_we) map_m[map_wa] <= map_wd;
        dsf_q <= dsf_m[dsf_ra];
        map_q <= map_m[map_ra_f];
    end

    logic [31:0] poc_m0 [0:31];
    logic [31:0] poc_m1 [0:31];
    logic        poc_we;
    logic [4:0]  poc_wa;
    logic [31:0] poc_wd0, poc_wd1;
    wire  [4:0]  poc_a0 = (ts == T_IDLE) ? poc_ra0 : i[4:0];     // T_DSF: list-0 entry i
    wire  [4:0]  poc_a1 = (ts == T_IDLE) ? poc_ra1 : 5'd0;       //        and RefPicList1[0]
    always_ff @(posedge clk) begin
        if (poc_we) begin poc_m0[poc_wa] <= poc_wd0; poc_m1[poc_wa] <= poc_wd1; end
        poc_q0 <= poc_m0[poc_a0];
        poc_q1 <= poc_m1[poc_a1];
    end
    logic       lx;

    // the entries being copied this cycle, their POC (8-1) and long-term marking --
    // combinational part-selects (no `function automatic`: Quartus 17, CLAUDE.md)
    // T_CODES takes four cycles an entry: the lists' entries i addressed (cs 0, recon_lists'
    // registered read ports), e0's store addressed (cs 1), its POCs captured and e1's
    // addressed (cs 2), e1's arrive and the entry is written (cs 3)
    logic [2:0] cs;                        // (P5b: 5 phases -- list 1's POCs registered, cs 3, before
                                           //  the compare and the write, cs 4: the RAM straight into
                                           //  the 32-bit compare was ~10 ns)
    logic signed [31:0] t0q, b0q, t1q, b1q;
    logic [7:0] e0, e1;
    logic [7:0] e0_q, e1_q;                // registered at cs 1 (cs 2 and 3 use them: the
                                           // list read, the count test, a 20:1 marking select
                                           // and the write decode in one cycle missed clk_dec)
    logic signed [31:0] p0_w, p1_w;
    logic       lg0_w, lg1_w;
    always_comb begin
        logic signed [31:0] t0, b0, t1, b1;
        logic [1:0] rt0, rb0, rt1, rb1;
        e0 = (i < {1'b0, num_ref_l0}) ? l0_entry : 8'd0;
        e1 = (i < {1'b0, num_ref_l1} && slice_type == 2'd1) ? l1_entry : 8'd0;
        t0 = t0q; b0 = b0q;
        t1 = t1q; b1 = b1q;
        p0_w = (e0_q[1:0] == 2'd1) ? t0 : (e0_q[1:0] == 2'd2) ? b0 : ((t0 < b0) ? t0 : b0);
        p1_w = (e1_q[1:0] == 2'd1) ? t1 : (e1_q[1:0] == 2'd2) ? b1 : ((t1 < b1) ? t1 : b1);
        rt0 = st_ref_t[2*e0_q[6:2] +: 2]; rb0 = st_ref_b[2*e0_q[6:2] +: 2];
        rt1 = st_ref_t[2*e1_q[6:2] +: 2]; rb1 = st_ref_b[2*e1_q[6:2] +: 2];
        lg0_w = e0_q[7] && ((e0_q[1:0] == 2'd1) ? (rt0 == LONG) : (e0_q[1:0] == 2'd2) ? (rb0 == LONG) : (rt0 == LONG && rb0 == LONG));
        lg1_w = e1_q[7] && ((e1_q[1:0] == 2'd1) ? (rt1 == LONG) : (e1_q[1:0] == 2'd2) ? (rb1 == LONG) : (rt1 == LONG && rb1 == LONG));
    end


    logic [7:0]  code10;                   // code[1][0], the co-located picture's (kept)
    logic signed [31:0] col_dt, col_db;    // T_COL0: |POC - current| of its fields
    always_comb tab_ra = (ts == T_CODES) ? ((cs == 3'd1) ? e0[6:2] : e1_q[6:2]) : code10[6:2];

    // dsf for list-0 entry i: tb = cur - poc0, td = poc1 - poc0 (pic1 = RefPicList1[0])
    logic        dsf_start, dsf_done, dsf_zero;
    logic signed [10:0] dsf_out;
    logic signed [31:0] dsf_b, dsf_d;
    dsf_calc u_dsf (.clk(clk), .rst_n(rst_n), .start(dsf_start), .diff_b(dsf_b), .diff_d(dsf_d),
                    .done(dsf_done), .dsf(dsf_out), .td_zero(dsf_zero));

    logic [7:0]  code_m0 [0:31];
    logic [7:0]  code_m1 [0:31];
    logic        code_we;
    logic [4:0]  code_wa;
    logic [7:0]  code_wd0, code_wd1;
    logic        mp_ph;                    // T_MAP: 0 the entry addressed, 1 its code landed
    wire  [5:0]  mp_k = {1'b0, num_ref_l0} - 6'd1 - i;             // walked from the end
    wire  [4:0]  cr0 = (ts == T_MAP) ? mp_k[4:0] : code_ra0;
    always_ff @(posedge clk) begin
        if (code_we) begin code_m0[code_wa] <= code_wd0; code_m1[code_wa] <= code_wd1; end
        code_q0 <= code_m0[cr0];
        code_q1 <= code_m1[code_ra1];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ts <= T_IDLE; done <= 1'b0; busy <= 1'b0; i <= '0; lx <= 1'b0; l0_idx <= '0; l1_idx <= '0;
            lng <= '0; lng1 <= '0; col_store <= '0; col_half <= '0; col_is_field <= 1'b0; vert_scale <= '0;
            l1_0_short <= 1'b0; tdir_raw <= '0; dsf_start <= 1'b0; dsf_b <= '0; dsf_d <= '0;
            cs <= '0; t0q <= '0; b0q <= '0; t1q <= '0; b1q <= '0; e0_q <= '0; e1_q <= '0;
            code_we <= 1'b0; code_wa <= '0; code_wd0 <= '0; code_wd1 <= '0; code10 <= '0; mp_ph <= 1'b0;
            poc_we <= 1'b0; poc_wa <= '0; poc_wd0 <= '0; poc_wd1 <= '0;
            dsf_we <= 1'b0; map_we <= 1'b0; dsf_wa <= '0; map_wa <= '0; dsf_wd <= '0; map_wd <= '0; mclr <= '0;
        end else begin
            done <= 1'b0; dsf_start <= 1'b0; poc_we <= 1'b0; dsf_we <= 1'b0; map_we <= 1'b0; code_we <= 1'b0;
            case (ts)
                T_IDLE: if (go) begin
                    busy <= 1'b1; i <= '0; lx <= 1'b0; l0_idx <= '0; l1_idx <= '0;
                    lng <= '0; lng1 <= '0; tdir_raw <= '0;
                    cs <= '0;
                    ts <= T_CODES;
                end
                // the lists' entries are registers (combinational read); their stores' POCs
                // come from recon_dpb's table, one store a read
                T_CODES: if (cs == 3'd0) begin
                    cs <= 3'd1;
                end else if (cs == 3'd1) begin
                    e0_q <= e0; e1_q <= e1;
                    cs <= 3'd2;
                end else if (cs == 3'd2) begin
                    t0q <= tab_q_poc_t; b0q <= tab_q_poc_b;
                    cs <= 3'd3;
                end else if (cs == 3'd3) begin
                    t1q <= tab_q_poc_t; b1q <= tab_q_poc_b;
                    cs <= 3'd4;
                end else begin
                    cs <= 3'd0;
                    code_we <= 1'b1; code_wa <= i[4:0]; code_wd0 <= e0_q; code_wd1 <= e1_q;
                    if (i == 6'd0) code10 <= e1_q;
                    poc_we <= 1'b1; poc_wa <= i[4:0]; poc_wd0 <= p0_w; poc_wd1 <= p1_w;
                    lng[i[4:0]] <= lg0_w;
                    lng1[i[4:0]] <= lg1_w;
                    if (i == 6'd31) begin
                        if (slice_type == 2'd1) ts <= T_COL_RD; else ts <= T_DONE;
                        l0_idx <= '0; l1_idx <= '0;
                    end else begin
                        i <= i + 1'b1; l0_idx <= i + 1'b1; l1_idx <= i + 1'b1;
                    end
                end
                // the co-located picture (Table 8-6) and vertMvScale (Table 8-8)
                T_COL_RD: ts <= T_COL0;          // its store's POCs addressed
                // (P5b: the two distances registered, then compared in T_COL -- the RAM, two
                // 32-bit absolute differences and the compare in one cycle were 8.9 ns + the
                // RAM's clock-to-out)
                T_COL0: begin
                    logic signed [31:0] t, b;
                    t = tab_q_poc_t; b = tab_q_poc_b;
                    col_dt <= (t - cur_poc < 0) ? cur_poc - t : t - cur_poc;
                    col_db <= (b - cur_poc < 0) ? cur_poc - b : b - cur_poc;
                    ts <= T_COL;
                end
                T_COL: begin
                    logic [7:0] c;
                    logic signed [31:0] t, b, dt, db;
                    c = code10;
                    col_store <= c[6:2];
                    l1_0_short <= c[7] && !lng1[0];
                    if (field_pic) begin
                        if (st_frame[c[6:2]]) begin
                            col_half <= 2'd0; col_is_field <= 1'b0; vert_scale <= 2'd1;      // Frm_To_Fld
                        end else begin
                            col_half <= c[1:0]; col_is_field <= 1'b1; vert_scale <= 2'd0;    // One_To_One
                        end
                    end else begin
                        if (st_frame[c[6:2]]) begin
                            col_half <= 2'd0; col_is_field <= 1'b0; vert_scale <= 2'd0;      // One_To_One
                        end else begin
                            col_half <= (col_dt < col_db) ? 2'd1 : 2'd2;
                            col_is_field <= 1'b1; vert_scale <= 2'd2;                         // Fld_To_Frm
                        end
                    end
                    i <= '0; mclr <= '0; mp_ph <= 1'b0;
                    ts <= T_MCLR;
                end
                // the map cleared, one entry a cycle (a RAM, 128 cycles a B slice)
                T_MCLR: begin
                    map_we <= 1'b1; map_wa <= mclr; map_wd <= 6'd0;
                    mclr <= mclr + 1'b1;
                    if (mclr == 7'd127) ts <= T_MAP;
                end
                // MapColToList0: walk list 0 from the END so the lowest index wins
                T_MAP: if (!mp_ph) mp_ph <= 1'b1; else begin
                    logic [5:0] k;
                    logic [7:0] e;
                    k = mp_k;
                    e = code_q0;
                    mp_ph <= 1'b0;
                    if (e[7]) begin
                        case (vert_scale)
                            2'd1: begin   // Frm_To_Fld: the field of refPicCol with the current parity
                                if (e[1:0] == cur_struct) begin map_we <= 1'b1; map_wa <= {e[6:2], 2'd0}; map_wd <= {1'b1, k[4:0]}; end
                            end
                            2'd2: begin   // Fld_To_Frm: the frame containing the field refPicCol
                                if (e[1:0] == 2'd0) begin            // stored once: the read folds the parity
                                    map_we <= 1'b1; map_wa <= {e[6:2], 2'd0}; map_wd <= {1'b1, k[4:0]};
                                end
                            end
                            default: begin map_we <= 1'b1; map_wa <= e[6:0]; map_wd <= {1'b1, k[4:0]}; end
                        endcase
                    end
                    if (i + 6'd1 >= {1'b0, num_ref_l0}) begin i <= '0; ts <= T_DSF_GO; end
                    else i <= i + 1'b1;
                end
                // DistScaleFactor per list-0 entry
                T_DSF_GO: begin
                    if (i >= {1'b0, num_ref_l0}) ts <= T_DONE;
                    else ts <= T_DSF_RD;         // poc_m0[i], poc_m1[0] addressed this cycle
                end
                T_DSF_RD: begin
                    dsf_b <= cur_poc - $signed(poc_q0);
                    dsf_d <= $signed(poc_q1) - $signed(poc_q0);
                    dsf_start <= 1'b1;
                    ts <= T_DSF_WAIT;
                end
                T_DSF_WAIT: if (dsf_done) begin
                    dsf_we <= 1'b1; dsf_wa <= i[4:0]; dsf_wd <= dsf_out;
                    tdir_raw[i[4:0]] <= lng[i[4:0]] || dsf_zero;
                    i <= i + 1'b1;
                    ts <= T_DSF_GO;
                end
                T_DONE: begin done <= 1'b1; busy <= 1'b0; ts <= T_IDLE; end
                default: ts <= T_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
