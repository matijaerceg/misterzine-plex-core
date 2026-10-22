// h264/dec/recon_lists.sv -- reference picture list construction per P / B slice:
// initialisation (8.2.4.2.1-5, frames and fields) and modification (8.2.4.3)
// (docs/h264_recon.md S2.2). Executable specification: tools/h264_recon_ref.py
// Decoder.build_ref_lists / field_list.
//
// Serial, from the frame-store state recon_dpb exports. Every search SCANS one store
// (or one ordered position) per cycle -- the parallel argmax / match over 16 stores
// with 32-bit keys this unit first had cost 8,100 LUTs (docs/h264_recon.md S6); a scan
// costs 17 cycles a pick, a few hundred cycles a slice:
//   1. ORDER: a selection pass per phase picks, per 17-cycle scan, the best
//      not-yet-picked eligible store (first maximum in store order):
//        P frame:  short by FrameNumWrap descending, then long by LongTermFrameIdx
//        B frame:  L0 short POC <= cur descending, short POC > cur ascending, long;
//                  L1 short POC > cur ascending, short POC <= cur descending, long
//        fields:   the same orders over "frames with any field marked" (entry POC =
//                  the smallest POC among the fields so marked, 8.2.4.2.4), the
//                  current frame included when its first field is marked,
//      producing an ordered store list per class (short, long);
//   2. FIELDS (field pictures only, 8.2.4.2.5): alternate parity starting with the
//      current one, each pick the next store in the ordered list with a field of that
//      parity marked (and decoded); when one parity runs out the rest of the other
//      follow in order. Short-term fields first, then long-term;
//   3. the B-list swap (8.2.4.2.3/4: RefPicList1 identical to RefPicList0 and more than
//      one entry: swap its first two) -- compared over the WHOLE initial lists, before
//      the truncation to num_ref_idx_active, as the model (and ffmpeg) do;
//   4. MODIFY (8.2.4.3): per operation, picNumLX (or the long-term number) -> the
//      target (store, parity); insert at refIdxLX, shift, drop the later duplicate --
//      one element per cycle.
// Entries: {valid, store[4:0], struct[1:0] (0 frame, 1 top, 2 bottom)}; 33 per list
// (num_ref_idx_active <= 32, plus the one-longer working list of 8-37). An entry past
// the initial list is "no reference picture" (valid 0): a macroblock naming it is an
// error recon_top counts.

`default_nettype none

module recon_lists
    import h264_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         go,                // recon_dpb's lists_go
    output logic        done,              // one pulse

    // the slice
    input  wire  [1:0]  slice_type,        // 0 P, 1 B
    input  wire         field_pic,
    input  wire         bottom,
    input  wire  [4:0]  cur_store,
    input  wire signed [31:0] cur_poc,
    input  wire  [15:0] frame_num,
    input  wire  [3:0]  log2_max_frame_num,
    input  wire  [5:0]  num_ref_l0,
    input  wire  [5:0]  num_ref_l1,
    input  wire  [5:0]  n_mods_l0,
    input  wire  [5:0]  n_mods_l1,
    output logic [6:0]  mod_addr,          // recon_hdr's modification table
    input  wire  [33:0] mod_data,

    // the store state (recon_dpb)
    input  wire  [NSTORE*2-1:0]  st_ref_t,
    input  wire  [NSTORE*2-1:0]  st_ref_b,
    input  wire  [NSTORE-1:0] st_dec_t,
    input  wire  [NSTORE-1:0] st_dec_b,
    // the store table's wide fields (recon_dpb's RAM): the address this cycle, the
    // data the next
    output logic [4:0]  tab_ra,
    input  wire signed [31:0] tab_q_poc_t,
    input  wire signed [31:0] tab_q_poc_b,
    input  wire signed [31:0] tab_q_fnw,
    input  wire  [NSTORE*5-1:0]  st_lt,

    // the lists: a read port per list, registered (the entry the cycle after the index)
    input  wire  [5:0]  rd0_idx,
    output logic [7:0]  rd0_entry,
    input  wire  [5:0]  rd1_idx,
    output logic [7:0]  rd1_entry,
    output logic        err_mod            // a modification named no reference picture
);

    localparam [1:0] UNUSED = 2'd0, SHORT = 2'd1, LONG = 2'd2;

    // ---- unpacked views ----------------------------------------------------------------
    logic [1:0]  rt [0:NSTORE-1], rb [0:NSTORE-1];
    logic        dt [0:NSTORE-1], db [0:NSTORE-1];
    logic [4:0]  lt [0:NSTORE-1];
    always_comb begin
        for (int i = 0; i < NSTORE; i++) begin
            rt[i] = st_ref_t[2*i +: 2]; rb[i] = st_ref_b[2*i +: 2];
            dt[i] = st_dec_t[i]; db[i] = st_dec_b[i];
            lt[i] = st_lt[5*i +: 5];
        end
    end

    // ---- the scanned store (one per cycle) -------------------------------------------------
    // a scan reads store si and processes sx = si - 1 (its table data arrived): steps
    // 1..NSTORE process, NSTORE + 1 resolves
    localparam logic [4:0] SC_LAST = NSTORE, SC_RES = NSTORE + 1;
    localparam logic [4:0] SC_RES2 = NSTORE + 3;   // the selection scans: two stages deeper
    logic [4:0]  si;
    wire  [4:0]  sx = si - 5'd1;
    logic [1:0]  x_rt, x_rb;
    logic signed [31:0] x_pt, x_pb, x_fnw;
    logic [4:0]  x_lt;
    logic        x_short, x_long;
    logic signed [31:0] x_epoc;            // entry POC over the short-marked fields
    // store sx's marking and LongTermFrameIdx, read at si in the cycle the table read is
    // issued and used the next, when that store is sx, beside the table's data: si only
    // ever steps by one or restarts at 0 (where nothing is processed). P5b
    // timing: DPB marking -> 32:1 by sx -> the POC min's select -> j_epoc was 9.4 ns.
    logic [1:0]  q_rt, q_rb;
    logic [4:0]  q_lt;
    always_ff @(posedge clk) begin
        q_rt <= rt[si]; q_rb <= rb[si]; q_lt <= lt[si];
    end
    always_comb begin
        x_rt = q_rt; x_rb = q_rb; x_pt = tab_q_poc_t; x_pb = tab_q_poc_b; x_fnw = tab_q_fnw; x_lt = q_lt;
        if (!field_pic) begin
            // frame decoding: a reference entry is a frame / pair with BOTH fields marked
            x_short = (x_rt == SHORT) && (x_rb == SHORT) && (sx != cur_store);
            x_long  = (x_rt == LONG) && (x_rb == LONG) && (sx != cur_store);
            x_epoc  = (x_pt < x_pb) ? x_pt : x_pb;
        end else begin
            x_short = (x_rt == SHORT) || (x_rb == SHORT);
            x_long  = (x_rt == LONG) || (x_rb == LONG);
            if (x_rt == SHORT && x_rb == SHORT) x_epoc = (x_pt < x_pb) ? x_pt : x_pb;
            else if (x_rt == SHORT)             x_epoc = x_pt;
            else                                x_epoc = x_pb;
        end
    end

    // ---- the selection pass ------------------------------------------------------------
    // phase: 0 short FrameNumWrap desc, 1 short POC<=cur desc, 2 short POC>cur asc, 3 long asc
    logic [1:0]  phase;
    logic [NSTORE-1:0] picked;
    logic        sel_found;                // registered over the scan
    logic [4:0]  sel;
    logic signed [31:0] best;
    logic        x_better, x_ok;
    logic signed [31:0] x_key;
    // stage J: the store's values registered (the table read and the POC min)
    logic signed [31:0] j_epoc, j_fnw;
    logic [4:0]  j_lt, j_sx;
    logic        j_short, j_long, j_v;
    always_comb begin
        logic ok;
        case (phase)
            2'd0: begin ok = j_short; x_key = j_fnw; end                                    // max
            2'd1: begin ok = j_short && (j_epoc <= cur_poc); x_key = j_epoc; end            // max
            2'd2: begin ok = j_short && (j_epoc > cur_poc); x_key = -j_epoc; end            // min -> max of -x
            default: begin ok = j_long; x_key = -$signed({27'd0, j_lt}); end               // min
        endcase
        x_ok = ok && !picked[j_sx];
    end
    // the selection's second stage: the key and eligibility of store kx registered (the
    // table read -> min of the POCs -> the compare with best in one cycle missed clk_dec)
    logic signed [31:0] k_key;
    logic        k_ok, k_v;
    logic [4:0]  k_sx;
    assign x_better = k_v && k_ok && (!sel_found || k_key > best);

    // ordered store lists: the short part and the long part (<= 16 each)
    logic [4:0]  ord_s [0:NSTORE-1];
    logic [4:0]  n_s;
    logic [4:0]  ord_l [0:NSTORE-1];
    logic [4:0]  n_l;

    // the lists being built / modified
    // the lists, one RAM each (entries {valid, store[4:0], struct[1:0]}, 33 used): the
    // register file with its indexed writes, shifts and compactions cost ~1,400 LUTs and
    // 528 registers (docs/h264_recon.md S6.1). Every operation walks it one entry a read.
    // Entries past the initial list are zero-filled after the build (they were cleared);
    // the truncation to num_ref_idx_active is left to the readers, which never read past it.
    logic [7:0]  lm0 [0:63];
    logic [7:0]  lm1 [0:63];
    logic        lw_we, lw_l;
    logic [5:0]  lw_a;
    logic [7:0]  lw_d;
    logic [5:0]  lr_a0, lr_a1;
    logic [7:0]  lq0, lq1;
    always_ff @(posedge clk) begin
        if (lw_we && !lw_l) lm0[lw_a] <= lw_d;
        if (lw_we &&  lw_l) lm1[lw_a] <= lw_d;
        lq0 <= lm0[lr_a0];
        lq1 <= lm1[lr_a1];
    end
    assign rd0_entry = lq0;
    assign rd1_entry = lq1;
    logic [5:0]  n_init [0:1];              // entries of the initial list
    logic        cur_l;                     // the list being built
    wire  [7:0]  lq_cur = cur_l ? lq1 : lq0;

    // field interleave state (8.2.4.2.5): the parity being served (fq: 0 the current
    // picture's, 1 the opposite), the scan position fp in the ordered list, the next
    // position per parity, which parities ran out
    logic [4:0]  fi_ptr [0:1];
    logic        fi_long;                   // interleaving the long part
    logic        fq;
    logic [4:0]  fp;
    logic [1:0]  fdone;
    wire         same_par = bottom;         // the current picture's parity (0 top)
    wire  [4:0]  n_cls = fi_long ? n_l : n_s;
    logic        f_ph;                      // L_FIELD's phase
    logic [4:0]  f_stn;                     // the store at fp, registered (phase 0)
    always_ff @(posedge clk) f_stn <= fi_long ? ord_l[fp] : ord_s[fp];
    // the tested field's parity, registered in phase 0 beside f_stn (clk_dec 103.85 retime: the
    // slice's parity -> this select -> the 20:1 rb / rt read -> f_hit -> lw_d was 8.8 ns at
    // 100 C). Valid in phase 1: fq changes only at the end of phase 1 (or in the state that
    // starts a list, before phase 0), and same_par is the slice's parity
    logic        f_par;
    always_ff @(posedge clk) f_par <= fq ? !same_par : same_par;
    wire  [1:0]  f_m = f_par ? rb[f_stn] : rt[f_stn];
    wire         f_d = f_par ? db[f_stn] : dt[f_stn];
    wire         f_hit = (f_m == (fi_long ? LONG : SHORT)) && f_d;

    // ---- modification ----------------------------------------------------------------------
    logic signed [31:0] max_pic_num, cur_pic_num, pred_pn;
    logic [5:0]  mod_i, ref_idx, c_idx, n_idx;
    logic [7:0]  mod_entry;                 // the entry being inserted
    logic        mod_is_long;
    logic signed [31:0] mod_target;
    logic signed [31:0] mo_t;               // L_MOD_OP .. OP3's intermediate
    logic [1:0]  mo_idc;
    wire  [1:0]  m_idc = mod_data[33:32];
    wire signed [31:0] m_val = mod_data[31:0];
    wire  [5:0]  n_act = cur_l ? num_ref_l1 : num_ref_l0;
    wire  [5:0]  n_mods = cur_l ? n_mods_l1 : n_mods_l0;
    // the (store, parity) with PicNum / LongTermPicNum == mod_target: scanned, the LAST
    // match in (store, top, bottom) order kept (a conforming stream has one)
    logic        tgt_found;
    logic [7:0]  tgt_entry;
    logic        x_hit_f, x_hit_t, x_hit_b;
    always_comb begin
        logic signed [31:0] num_t, num_b;
        if (!mod_is_long) begin
            num_t = (x_fnw <<< 1) + ((same_par == 1'b0) ? 32'sd1 : 32'sd0);
            num_b = (x_fnw <<< 1) + ((same_par == 1'b1) ? 32'sd1 : 32'sd0);
        end else begin
            num_t = $signed({26'd0, x_lt, (same_par == 1'b0)});
            num_b = $signed({26'd0, x_lt, (same_par == 1'b1)});
        end
        x_hit_f = (!mod_is_long && x_short && x_fnw == mod_target) ||
                  (mod_is_long && x_long && $signed({27'd0, x_lt}) == mod_target);
        x_hit_t = (x_rt == (mod_is_long ? LONG : SHORT)) && (num_t == mod_target);
        x_hit_b = (x_rb == (mod_is_long ? LONG : SHORT)) && (num_b == mod_target);
    end
    // PicNumF / LongTermPicNumF of a list entry (8-37 / 8-38): its number if it is marked
    // as the class being inserted, else a value no target can equal
    logic        ent_match;
    logic [7:0]  ent;
    logic [7:0]  cent;                      // L_MOD_COMPACT: the entry read
    always_comb begin
        logic [4:0] stn;
        logic [1:0] m;
        logic signed [31:0] num;
        ent = cent;
        stn = ent[6:2];
        ent_match = 1'b0;
        if (ent[7]) begin
            if (ent[1:0] == 2'd0) begin
                m = (rt[stn] == rb[stn]) ? rt[stn] : UNUSED;
                num = mod_is_long ? $signed({27'd0, lt[stn]}) : tab_q_fnw;
            end else begin
                m = (ent[1:0] == 2'd2) ? rb[stn] : rt[stn];
                if (!mod_is_long) num = (tab_q_fnw <<< 1) + (((ent[1:0] == 2'd2) == same_par) ? 32'sd1 : 32'sd0);
                else num = $signed({26'd0, lt[stn], ((ent[1:0] == 2'd2) == same_par)});
            end
            ent_match = (m == (mod_is_long ? LONG : SHORT)) && (num == mod_target);
        end
    end

    // ---- the FSM ---------------------------------------------------------------------------
    typedef enum logic [4:0] {L_IDLE, L_SEL_S, L_SEL_L, L_BUILD, L_FIELD, L_ZFILL, L_SWAP, L_SWAP_W0, L_SWAP_W1, L_MOD_START,
                              L_MOD_RD, L_MOD_OP, L_MOD_OP2, L_MOD_OP3, L_MOD_FIND, L_MOD_SHIFT, L_MOD_PLACE, L_MOD_COMPACT, L_NEXT, L_NEXT_MOD, L_DONE} lstate_t;
    lstate_t ls;
    logic [1:0]  c_ph;                      // L_MOD_COMPACT / L_MOD_SHIFT / L_SWAP phase
    logic [5:0]  sw_k;                      // L_SWAP: the entry compared
    logic        sw_same;
    logic [7:0]  sw_e0, sw_e1;              // list 1's first two entries
    // the table's read port: the entry being compacted, else the scan index
    // L_MOD_COMPACT reads the entry's FrameNumWrap in phase 1, the cycle the entry itself lands
    // on lq_cur (cent registers it at that edge): addressing from cent there read the
    // PREVIOUS entry's store, so a later duplicate was dropped only when the entry before it
    // shared its store -- invisible until a stream whose removal changes an index in use
    // (tools/jm_fixtures.py jmod, 2026-09-25)
    always_comb tab_ra = (ls == L_MOD_COMPACT) ? ((c_ph == 2'd1) ? lq_cur[6:2] : cent[6:2]) : si;
    // the lists' read addresses: the operation's, or the external ports when idle
    always_comb begin
        lr_a0 = rd0_idx; lr_a1 = rd1_idx;
        case (ls)
            L_SWAP: begin lr_a0 = sw_k; lr_a1 = sw_k; end
            L_MOD_SHIFT: begin lr_a0 = c_idx - 6'd1; lr_a1 = c_idx - 6'd1; end
            L_MOD_COMPACT: begin lr_a0 = c_idx; lr_a1 = c_idx; end
            default: ;
        endcase
    end
    logic [5:0]  b_pos;                     // write position in the list being built
    logic [1:0]  b_seg;                     // B frame build: which of the 3 segments
    logic [5:0]  k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ls <= L_IDLE; done <= 1'b0; err_mod <= 1'b0; phase <= '0; picked <= '0; c_ph <= '0;
            lw_we <= 1'b0; lw_l <= 1'b0; lw_a <= '0; lw_d <= '0; cent <= '0; sw_k <= '0; sw_same <= 1'b0; sw_e0 <= '0; sw_e1 <= '0;
            n_s <= '0; n_l <= '0; cur_l <= 1'b0; b_pos <= '0; b_seg <= '0; k <= '0;
            fi_ptr[0] <= '0; fi_ptr[1] <= '0; fi_long <= 1'b0; fq <= 1'b0; fp <= '0; fdone <= '0;
            si <= '0; sel_found <= 1'b0; sel <= '0; best <= '0; tgt_found <= 1'b0; tgt_entry <= '0;
            n_init[0] <= '0; n_init[1] <= '0; mod_addr <= '0; mod_i <= '0; ref_idx <= '0;
            c_idx <= '0; n_idx <= '0; mod_entry <= '0; mod_is_long <= 1'b0; mod_target <= '0;
            max_pic_num <= '0; cur_pic_num <= '0; pred_pn <= '0;
            for (int e = 0; e < NSTORE; e++) begin ord_s[e] <= '0; ord_l[e] <= '0; end
            k_key <= '0; k_ok <= 1'b0; k_v <= 1'b0; k_sx <= '0;
            j_epoc <= '0; j_fnw <= '0; j_lt <= '0; j_short <= 1'b0; j_long <= 1'b0; j_sx <= '0; j_v <= 1'b0; mo_t <= '0; mo_idc <= '0; f_ph <= 1'b0;
        end else begin
            done <= 1'b0; err_mod <= 1'b0; lw_we <= 1'b0;
            // the selection scans' stages: J the store's values, K its key (compared with
            // best the cycle after)
            j_epoc <= x_epoc; j_fnw <= x_fnw; j_lt <= x_lt; j_short <= x_short; j_long <= x_long; j_sx <= sx;
            j_v <= (ls == L_SEL_S || ls == L_SEL_L) && (si != 5'd0) && (si <= SC_LAST);
            k_key <= x_key; k_ok <= x_ok; k_sx <= j_sx; k_v <= j_v;
            case (ls)
                L_IDLE: if (go) begin
                    cur_l <= 1'b0; picked <= '0; n_s <= '0; n_l <= '0;
                    max_pic_num <= field_pic ? (32'sd2 <<< log2_max_frame_num) : (32'sd1 <<< log2_max_frame_num);
                    cur_pic_num <= field_pic ? $signed({15'd0, frame_num, 1'b1}) : $signed({16'd0, frame_num});
                    // P: short by FrameNumWrap; B list 0: POC <= cur first
                    phase <= (slice_type == 2'd0) ? 2'd0 : 2'd1;
                    b_seg <= 2'd0; si <= '0; sel_found <= 1'b0;
                    ls <= L_SEL_S;
                end
                // ---- the ordered short-term store list ------------------------------
                L_SEL_S: if (si != SC_RES2) begin
                    if (x_better) begin sel_found <= 1'b1; sel <= k_sx; best <= k_key; end
                    si <= si + 1'b1;
                end else begin
                    si <= '0; sel_found <= 1'b0;
                    if (sel_found) begin
                        ord_s[n_s] <= sel; n_s <= n_s + 1'b1; picked[sel] <= 1'b1;
                    end else if (slice_type == 2'd1 && b_seg == 2'd0) begin
                        // B: the second short segment
                        phase <= cur_l ? 2'd1 : 2'd2;
                        b_seg <= 2'd1;
                    end else begin
                        picked <= '0; phase <= 2'd3; ls <= L_SEL_L;
                    end
                end
                L_SEL_L: if (si != SC_RES2) begin
                    if (x_better) begin sel_found <= 1'b1; sel <= k_sx; best <= k_key; end
                    si <= si + 1'b1;
                end else begin
                    si <= '0; sel_found <= 1'b0;
                    if (sel_found) begin
                        ord_l[n_l] <= sel; n_l <= n_l + 1'b1; picked[sel] <= 1'b1;
                    end else begin
                        b_pos <= '0; k <= '0;
                        fi_ptr[0] <= '0; fi_ptr[1] <= '0; fi_long <= 1'b0; fq <= 1'b0; fp <= '0; fdone <= '0;
                        if (field_pic) begin f_ph <= 1'b0; ls <= L_FIELD; end else ls <= L_BUILD;
                    end
                end
                // ---- frames: the list is the short part then the long part ----------------
                L_BUILD: begin
                    if (k < {1'b0, n_s}) begin
                        if (b_pos < 6'd33) begin lw_we <= 1'b1; lw_l <= cur_l; lw_a <= b_pos; lw_d <= {1'b1, ord_s[k[4:0]], 2'd0}; end
                        b_pos <= b_pos + 1'b1; k <= k + 1'b1;
                    end else if (k < {1'b0, n_s} + {1'b0, n_l}) begin
                        if (b_pos < 6'd33) begin lw_we <= 1'b1; lw_l <= cur_l; lw_a <= b_pos; lw_d <= {1'b1, ord_l[k[4:0] - n_s], 2'd0}; end
                        b_pos <= b_pos + 1'b1; k <= k + 1'b1;
                    end else begin
                        n_init[cur_l] <= b_pos;
                        ls <= L_ZFILL;
                    end
                end
                // ---- fields: alternate parity over the ordered frames (8.2.4.2.5) --------
                L_FIELD: if (!f_ph) begin
                    // two cycles a step: the store at fp registered, then its field tested
                    f_ph <= 1'b1;
                end else begin
                    f_ph <= 1'b0;
                    if (fp >= n_cls) begin
                        // parity fq ran out
                        if (!fdone[!fq]) begin
                            fdone[fq] <= 1'b1; fq <= !fq; fp <= fi_ptr[!fq];
                        end else if (!fi_long) begin
                            fi_long <= 1'b1; fi_ptr[0] <= '0; fi_ptr[1] <= '0; fq <= 1'b0; fp <= '0; fdone <= '0;
                        end else begin
                            n_init[cur_l] <= b_pos;
                            ls <= L_ZFILL;
                        end
                    end else if (f_hit) begin
                        if (b_pos < 6'd33) begin lw_we <= 1'b1; lw_l <= cur_l; lw_a <= b_pos; lw_d <= {1'b1, f_stn, (f_par ? 2'd2 : 2'd1)}; end
                        b_pos <= b_pos + 1'b1;
                        fi_ptr[fq] <= fp + 1'b1;
                        // alternate while the other parity may still have fields
                        if (!fdone[!fq]) begin fq <= !fq; fp <= fi_ptr[!fq]; end
                        else fp <= fp + 1'b1;
                    end else begin
                        fp <= fp + 1'b1;
                    end
                end
                // the entries past the initial list: zero ("no reference picture")
                L_ZFILL: begin
                    if (b_pos < 6'd33) begin
                        lw_we <= 1'b1; lw_l <= cur_l; lw_a <= b_pos; lw_d <= 8'd0;
                        b_pos <= b_pos + 1'b1;
                    end else ls <= L_NEXT;
                end
                L_NEXT: begin
                    if (slice_type == 2'd1 && !cur_l) begin
                        // build list 1: B order with the segments swapped
                        cur_l <= 1'b1; picked <= '0; n_s <= '0; n_l <= '0;
                        phase <= 2'd2; b_seg <= 2'd0; si <= '0; sel_found <= 1'b0;
                        ls <= L_SEL_S;
                    end else if (slice_type == 2'd1) begin
                        sw_k <= '0; sw_same <= (n_init[0] == n_init[1]); c_ph <= '0;
                        ls <= L_SWAP;
                    end else begin
                        cur_l <= 1'b0; ls <= L_MOD_START;
                    end
                end
                // RefPicList1 == RefPicList0 over the initial lists (8.2.4.2.3 / 4): compared
                // one entry a read (entries past n_init are zero in both), then list 1's
                // first two swapped when it has more than one
                L_SWAP: begin
                    if (c_ph == 2'd0) c_ph <= 2'd1;                 // entry sw_k addressed
                    else begin
                        if (lq0 != lq1) sw_same <= 1'b0;
                        if (sw_k == 6'd0) sw_e0 <= lq1;
                        if (sw_k == 6'd1) sw_e1 <= lq1;
                        c_ph <= 2'd0;
                        if (sw_k == 6'd32) begin
                            if (sw_same && lq0 == lq1 && n_init[1] > 6'd1) ls <= L_SWAP_W0;
                            else begin cur_l <= 1'b0; ls <= L_MOD_START; end
                        end else sw_k <= sw_k + 1'b1;
                    end
                end
                L_SWAP_W0: begin lw_we <= 1'b1; lw_l <= 1'b1; lw_a <= 6'd0; lw_d <= sw_e1; ls <= L_SWAP_W1; end
                L_SWAP_W1: begin lw_we <= 1'b1; lw_l <= 1'b1; lw_a <= 6'd1; lw_d <= sw_e0; cur_l <= 1'b0; ls <= L_MOD_START; end
                // ---- truncation and modification ------------------------------------------
                L_MOD_START: begin
                    mod_i <= '0; c_ph <= '0; ref_idx <= '0; pred_pn <= cur_pic_num;
                    mod_addr <= {cur_l, 6'd0};
                    if (n_mods == 6'd0) ls <= L_NEXT_MOD;
                    else ls <= L_MOD_RD;
                end
                L_MOD_RD: ls <= L_MOD_OP;          // mod_data lands
                // picNumLXNoWrap (8-34 / 8-35), picNumLX (8-36), over three cycles (the whole
                // chain in one missed clk_dec): the offset, the wrap, the picNum
                L_MOD_OP: begin
                    mo_idc <= m_idc;
                    if (m_idc == 2'd2) mo_t <= m_val;
                    else if (m_idc == 2'd0) mo_t <= pred_pn - (m_val + 32'sd1);
                    else mo_t <= pred_pn + (m_val + 32'sd1);
                    ls <= L_MOD_OP2;
                end
                L_MOD_OP2: begin
                    if (mo_idc == 2'd0 && mo_t < 0) mo_t <= mo_t + max_pic_num;
                    else if (mo_idc == 2'd1 && mo_t >= max_pic_num) mo_t <= mo_t - max_pic_num;
                    ls <= L_MOD_OP3;
                end
                L_MOD_OP3: begin
                    if (mo_idc == 2'd2) begin
                        mod_is_long <= 1'b1; mod_target <= mo_t;
                    end else begin
                        pred_pn <= mo_t;
                        mod_is_long <= 1'b0; mod_target <= (mo_t > cur_pic_num) ? mo_t - max_pic_num : mo_t;
                    end
                    si <= '0; tgt_found <= 1'b0; tgt_entry <= '0;
                    ls <= L_MOD_FIND;
                    c_idx <= n_act;                 // the shift runs from the end down
                end
                L_MOD_FIND: begin
                    // one store per cycle; a later match overrides (the parallel search's order)
                    if (si == 5'd0) ;
                    else if (!field_pic) begin
                        if (x_hit_f) begin tgt_found <= 1'b1; tgt_entry <= {1'b1, sx, 2'd0}; end
                    end else if (x_hit_b) begin tgt_found <= 1'b1; tgt_entry <= {1'b1, sx, 2'd2}; end
                    else if (x_hit_t)     begin tgt_found <= 1'b1; tgt_entry <= {1'b1, sx, 2'd1}; end
                    si <= si + 1'b1;
                    if (si == SC_LAST) begin si <= '0; ls <= L_MOD_SHIFT; end
                end
                L_MOD_SHIFT: begin
                    // the target was resolved by L_MOD_FIND
                    if (c_idx == 6'd0) begin
                        // unreachable: ref_idx >= 0 stops the loop first
                        ls <= L_MOD_PLACE;
                    end else if (c_idx > ref_idx) begin
                        // two cycles an entry: c_idx - 1 addressed, then written to c_idx
                        if (c_ph == 2'd0) c_ph <= 2'd1;
                        else begin
                            lw_we <= 1'b1; lw_l <= cur_l; lw_a <= c_idx; lw_d <= lq_cur;
                            c_idx <= c_idx - 1'b1; c_ph <= 2'd0;
                        end
                    end else begin
                        ls <= L_MOD_PLACE;
                    end
                    if (c_idx == n_act) begin
                        mod_entry <= tgt_entry;
                        if (!tgt_found) err_mod <= 1'b1;
                    end
                end
                L_MOD_PLACE: begin
                    lw_we <= 1'b1; lw_l <= cur_l; lw_a <= ref_idx; lw_d <= mod_entry;
                    ref_idx <= ref_idx + 1'b1;
                    c_idx <= ref_idx + 1'b1;
                    n_idx <= ref_idx + 1'b1;
                    ls <= L_MOD_COMPACT;
                end
                L_MOD_COMPACT: begin
                    // for cIdx = refIdxLX .. num_ref_idx_active: keep entries that are not the
                    // target. Three cycles an entry: the entry read (c_ph 0), its store's
                    // FrameNumWrap read (1), compared and the entry kept (2).
                    if (c_idx <= n_act) begin
                        if (c_ph == 2'd0) c_ph <= 2'd1;
                        else if (c_ph == 2'd1) begin cent <= lq_cur; c_ph <= 2'd2; end
                        else begin
                            if (!ent_match) begin
                                lw_we <= 1'b1; lw_l <= cur_l; lw_a <= n_idx; lw_d <= cent;
                                n_idx <= n_idx + 1'b1;
                            end
                            c_idx <= c_idx + 1'b1; c_ph <= 2'd0;
                        end
                    end else begin
                        c_ph <= 2'd0;
                        mod_i <= mod_i + 1'b1;
                        mod_addr <= {cur_l, mod_i + 6'd1};
                        if (mod_i + 6'd1 >= n_mods) ls <= L_NEXT_MOD;
                        else ls <= L_MOD_RD;
                    end
                end
                L_NEXT_MOD: begin
                    if (slice_type == 2'd1 && !cur_l) begin cur_l <= 1'b1; ls <= L_MOD_START; end
                    else ls <= L_DONE;
                end
                L_DONE: begin done <= 1'b1; ls <= L_IDLE; end
                default: ls <= L_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
