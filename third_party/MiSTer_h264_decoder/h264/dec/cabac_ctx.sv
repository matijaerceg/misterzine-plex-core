// h264/dec/cabac_ctx.sv -- the 460 CABAC context variables and their per-slice
// initialisation (ITU-T H.264 9.3.1.1)
//
// The M10Ks hold {rLPS row[31:0], valMPS, pStateIdx[5:0]} per ctxIdx 0..459 (Main profile
// incl. the field-coded significance ranges 277..398; docs/h264_frontend.md). The row is
// the state's four rangeTabLPS values (bits 8q+7..8q for qCodIRangeIdx q), stored beside
// it so the engine's decision reads rLPS with a 4:1 select behind the RAM instead of a
// 256-entry ROM lookup (P5b timing, docs/throughput.md): the engine writes the new
// state's row back with the state, and the initialisation writes it here. One synchronous read
// port and one write port: the engine reads a context in the cycle it accepts a decision
// request and writes the new state in the next, so a read never lands on the edge of a
// write to the same address (cabac_engine.sv's cadence) -- no forwarding is needed, and
// none is provided: a 1-bin/cycle engine would have to add it.
//
// Initialisation: on init_start, ctxIdx 0..459 are written from the (m, n) ROM
// (h264/dec/cabac_init.mem, rendered from tools/cabac_tables.py by tools/cabac_mem.py;
// set 0..2 = cabac_init_idc, 3 = I slices) as
//     preCtxState = Clip3(1, 126, ((m * Clip3(0, 51, SliceQPY)) >> 4) + n)
//     pStateIdx   = preCtxState <= 63 ? 63 - preCtxState : preCtxState - 64
//     valMPS      = preCtxState > 63
// one context per cycle in a four-stage pipeline (ROM fetch, product, add/clip, row
// lookup/write): ~465 cycles per slice against ~1,350 macroblocks of bins. The product is registered
// on its own because ROM-out -> multiply -> add -> clip -> RAM-in in one cycle was the
// binding path of the first fit (docs/h264_frontend.md S3).
// Entries the spec leaves "na" are (0, 0) in the ROM and initialise as that pair does
// (preCtxState 1: pStateIdx 62, valMPS 0), exactly what tools/cabac_ref.py does, so an
// unused context decodes identically in both (it never should be used; the model and
// the RTL agree if it is). (0, 0) is also a real entry -- set 1, ctxIdx 179 and 193 --
// so it could not have been a marker.
//
// The multiply is 8 x 6 bits signed; the arithmetic shift right by 4 floors, as the
// spec's >> on a negative product does (and as Python's does in the model).

`default_nettype none

module cabac_ctx (
    input  wire        clk,
    input  wire        rst_n,

    // per-slice initialisation
    input  wire        init_start,      // one-cycle pulse; ignored while busy
    input  wire  [1:0] init_set,        // 0..2 cabac_init_idc, 3 I slices
    input  wire  [5:0] init_qp,         // SliceQPY, already 0..51
    output logic       init_busy,

    // the engine's ports (and the bench's readback, muxed by the engine)
    input  wire        rd_en,
    input  wire  [8:0] rd_addr,
    output logic [6:0] rd_state,        // {valMPS, pStateIdx}, valid the cycle after rd_en
    output logic [31:0] rd_rlps,        // pStateIdx's rangeTabLPS row, with rd_state
    input  wire        wr_en,
    input  wire  [8:0] wr_addr,
    input  wire  [6:0] wr_state,
    input  wire  [31:0] wr_rlps         // the new pStateIdx's row
);

    localparam int NUM_CTX = 460;

    // ---- the (m, n) ROM: 4 sets x 460, synchronous read (M10K) --------------------
    logic [15:0] init_rom [0:4*NUM_CTX-1];
    initial $readmemh("h264/dec/cabac_init.mem", init_rom);

    // ---- pStateIdx -> its rangeTabLPS row (LUT ROM, tools/cabac_mem.py) -------------
    logic [31:0] row_rom [0:63];
    initial $readmemh("h264/dec/cabac_rlpsrow.mem", row_rom);

    // ---- the contexts (M10K, simple dual port) ------------------------------------
    logic [38:0] ctx [0:NUM_CTX-1];

    // ---- init sequencer: stage 0 issues the ROM address, stage 1 the product,
    //      stage 2 adds n, clips and writes
    logic        seq_run;
    logic [8:0]  seq_idx;               // stage 0: the ctxIdx whose (m, n) is being fetched
    logic        s1_valid, s2_valid, s3_valid;
    logic [8:0]  s1_idx, s2_idx, s3_idx;
    logic [6:0]  s3_st;
    logic [15:0] rom_q;
    logic [1:0]  set_q;
    logic [5:0]  qp_q;
    logic [10:0] rom_addr;
    logic signed [14:0] prod_q;
    logic signed [7:0]  n_q;

    assign init_busy = seq_run || s1_valid || s2_valid || s3_valid;

    // stage 1: the product (declared before the sequencer that registers it)
    wire signed [7:0]  m_s  = rom_q[15:8];
    wire signed [7:0]  n_s  = rom_q[7:0];
    wire signed [14:0] prod = m_s * $signed({1'b0, qp_q});          // 8 x 7 (qp zero-extended to signed)
    assign rom_addr  = {2'b00, set_q} * 11'd460 + {2'b00, seq_idx};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_run  <= 1'b0;
            seq_idx  <= 9'd0;
            s1_valid <= 1'b0;
            s1_idx   <= 9'd0;
            s2_valid <= 1'b0;
            s2_idx   <= 9'd0;
            set_q    <= 2'd0;
            qp_q     <= 6'd0;
            rom_q    <= 16'd0;
            prod_q   <= 15'sd0;
            n_q      <= 8'sd0;
        end else begin
            if (init_start && !init_busy) begin
                seq_run <= 1'b1;
                seq_idx <= 9'd0;
                set_q   <= init_set;
                qp_q    <= init_qp;
            end
            // stage 0 -> 1 (ROM fetch) -> 2 (product)
            s1_valid <= seq_run;
            s1_idx   <= seq_idx;
            rom_q    <= init_rom[rom_addr];
            s2_valid <= s1_valid;
            s2_idx   <= s1_idx;
            prod_q   <= prod;
            n_q      <= n_s;
            if (seq_run) begin
                if (seq_idx == 9'd459) seq_run <= 1'b0;
                seq_idx <= seq_idx + 9'd1;
            end
        end
    end

    // stage 2: preCtxState from the registered product and n; stage 3 registers the state
    // and looks its row up (the lookup behind the clip was a new long path)
    wire signed [14:0] pre0 = (prod_q >>> 4) + n_q;
    wire        [6:0]  pre  = (pre0 < 15'sd1) ? 7'd1 : (pre0 > 15'sd126) ? 7'd126 : pre0[6:0];
    wire        [6:0]  d_lo = 7'd63 - pre;
    wire        [6:0]  d_hi = pre - 7'd64;
    wire        [6:0]  init_state = (pre <= 7'd63) ? {1'b0, d_lo[5:0]} : {1'b1, d_hi[5:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_idx   <= 9'd0;
            s3_st    <= 7'd0;
        end else begin
            s3_valid <= s2_valid;
            s3_idx   <= s2_idx;
            s3_st    <= init_state;
        end
    end

    // ---- the RAM ---------------------------------------------------------------------
    wire        ram_we   = s3_valid ? 1'b1     : wr_en;
    wire [8:0]  ram_wa   = s3_valid ? s3_idx   : wr_addr;
    wire [38:0] ram_wd   = s3_valid ? {row_rom[s3_st[5:0]], s3_st} : {wr_rlps, wr_state};

    always_ff @(posedge clk) begin
        if (ram_we) ctx[ram_wa] <= ram_wd;
        if (rd_en)  {rd_rlps, rd_state} <= ctx[rd_addr];
    end

endmodule

`default_nettype wire
