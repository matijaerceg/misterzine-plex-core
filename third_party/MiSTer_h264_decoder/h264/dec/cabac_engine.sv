// h264/dec/cabac_engine.sv -- the CABAC arithmetic decoding engine (ITU-T H.264 9.3.3.2)
//
// Bit-exact against tools/cabac_ref.py (the spec's DecodeDecision / DecodeBypass /
// DecodeTerminate with 9-bit codIRange and 9/10-bit codIOffset), scored by
// bench/h264/run_h264_cabac.sh over random request streams. docs/h264_frontend.md S3.
//
// Requests (held valid/ready; one response pulse per request, in order):
//   kind 0 DECISION  ctx = ctxIdx 0..459 (never 276)      -> rsp_bin      2 cycles
//   kind 1 BYPASS                                         -> rsp_bin      1 cycle
//   kind 2 TERMINATE (end_of_slice_flag, I_PCM bin)       -> rsp_bin      1 cycle
//   kind 3 INIT      ctx[7:6] = set (0..2 idc, 3 = I), ctx[5:0] = SliceQPY: the contexts
//                    (cabac_ctx, ~463 cycles) then the engine (9 bits)   -> rsp 0
//   kind 4 ALIGN     drop the bits to the next byte boundary (pcm_alignment_zero_bit)
//   kind 5 RAWBYTE   one aligned byte (pcm_sample_*)      -> rsp_byte     1 cycle
//   kind 6 REINIT    the engine only (after I_PCM samples, 9.3.1.2)      -> rsp 0
//   kind 7 FLUSH     discard buffered bits, clear end-of-stream: between NAL units
//
// Cadence. A DECISION is accepted in an idle cycle (the context read is issued then)
// and computed the next: context state, rangeTabLPS, subtract, compare, the bin, the
// new state written back -- all ending at REGISTERS that hold the range and offset
// BEFORE renormalisation. The renormalisation (one barrel shift by the leading-zero
// count, and the bit-buffer update) happens in the following idle cycle, which is
// also the cycle the next dependent decision is accepted in: two cycles per dependent
// bin, every output registered, and the M10K's clock-to-out plus the decision cone no
// longer share a cycle with the shifters (the first fit put the whole thing in one
// cycle and reached 63 MHz; docs/h264_frontend.md S3). A bypass or terminate arriving
// in that renormalisation cycle waits one cycle. The caller's ctxIdxInc logic sees
// rsp_bin combinationally in the response cycle.
//
// Bits come from a held byte handshake (in_byte/in_valid/in_ready) into a 32-bit buffer;
// in_last marks the NAL unit's last byte, after which requests proceed on whatever bits
// remain (a conformant slice never reads past its rbsp_stop_one_bit -- 9.3.3.2.4 -- so
// running out is a stream error: err_underrun, sticky, bits read as 0). Before the end
// of stream a request needs 9 buffered bits (the most any one of them consumes), a
// decision accepted while a renormalisation is still pending 16 (that one's up to 7,
// plus its own): the buffer refills a byte per cycle, so this never throttles.
//
// rangeTabLPS lives in the context RAM: each context stores its state's four rLPS values
// beside the state (cabac_ctx.sv), so the decision selects rLPS 4:1 by the range's bits
// 7:6 behind the RAM's clock-to-out, and the write-back carries the next state's row,
// looked up from the current state in parallel with the compare (P5b timing: the
// 256-entry ROM lookup, the subtract and the compare in series behind the RAM were the
// front end's longest path at ~100 MHz; docs/throughput.md). The 64 x 64 next-row and
// 64 x 12 transition tables are LUT ROMs from the .mem files tools/cabac_mem.py renders
// (never hand-typed).
//
// Errors (sticky until FLUSH): err_init (codIOffset 510/511 at initialisation, a
// bitstream violation), err_align (RAWBYTE while not byte-aligned), err_underrun.

`default_nettype none

module cabac_engine (
    input  wire        clk,
    input  wire        rst_n,

    // byte stream of the slice's RBSP (emulation-prevention bytes already removed)
    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    input  wire        in_last,
    output logic       in_ready,

    // requests
    input  wire        req_valid,
    output logic       req_ready,
    input  wire  [2:0] req_kind,
    input  wire  [8:0] req_ctx,

    // responses
    output logic       rsp_valid,
    output logic       rsp_bin,
    output logic [7:0] rsp_byte,

    output logic       busy,
    output logic       err_init,
    output logic       err_align,
    output logic       err_underrun,

    // context readback for the bench (only while idle)
    input  wire        dbg_rd_en,
    input  wire  [8:0] dbg_addr,
    output logic [6:0] dbg_state,

    // measured, for the HUD later: bins decoded since FLUSH
    output logic [31:0] bin_count
);

    localparam [2:0] K_DECISION = 3'd0, K_BYPASS = 3'd1, K_TERMINATE = 3'd2, K_INIT = 3'd3,
                     K_ALIGN = 3'd4, K_RAWBYTE = 3'd5, K_REINIT = 3'd6, K_FLUSH = 3'd7;

    // ---- tables ------------------------------------------------------------------------
    logic [63:0] rnext_rom [0:63];      // {row(transIdxLPS[p]), row(transIdxMPS[p])}
    logic [11:0] trans_rom [0:63];
    initial begin
        $readmemh("h264/dec/cabac_rlpsnext.mem", rnext_rom);
        $readmemh("h264/dec/cabac_trans.mem", trans_rom);
    end

    // ---- engine registers ----------------------------------------------------------
    logic [8:0]  rng;                   // codIRange, renormalised
    logic [9:0]  off;                   // codIOffset (10 bits: the bypass shift needs one more)
    logic [8:0]  rng_pre;               // a decision's range/offset before renormalisation
    logic [9:0]  off_pre;
    logic        renorm_pending;
    typedef enum logic [1:0] {S_IDLE, S_DEC, S_INIT_CTX} state_t;
    state_t state;
    logic [8:0]  ctx_q;                 // the decision's ctxIdx (write-back address)

    // ---- the bit buffer --------------------------------------------------------------
    logic [31:0] bbuf;                  // valid bits left-aligned, MSB first
    logic [5:0]  bcnt;                  // 0..32
    logic        eos;                   // in_last seen: no more bytes will come
    logic [3:0]  take;                  // bits consumed this cycle (0..9)
    logic        flush_now;

    assign in_ready = (bcnt <= 6'd24) && !eos;
    wire        refill   = in_valid && in_ready;
    // the new byte lands right after the valid bits (a position known early, from bcnt
    // alone); the whole buffer then shifts by what this cycle consumed -- one barrel
    // shift on the late path, not two
    wire [4:0]  put_pos  = 5'd24 - bcnt[4:0];             // bcnt <= 24 whenever refill
    wire [31:0] buf_full = refill ? (bbuf | ({24'd0, in_byte} << put_pos)) : bbuf;
    wire [31:0] buf_next = buf_full << take;
    wire [5:0]  cnt_full = refill ? bcnt + 6'd8 : bcnt;
    wire        underrun = (take > cnt_full);
    wire [5:0]  cnt_next = underrun ? 6'd0 : cnt_full - {2'b00, take};
    wire [8:0]  top9     = bbuf[31:23];
    wire [8:0]  taken    = top9 >> (4'd9 - take);          // the consumed bits, right-aligned
    // Both initialization paths consume exactly nine bits: K_REINIT is accepted only
    // with no pending renormalisation and enough input, while S_INIT_CTX is non-idle
    // and reaches its guarded consume only when enough input is available. In either
    // case take is 9, so the initialized offset is exactly top9. Keep these branches
    // off the variable shifter used by ordinary requests.
    wire        enough   = (bcnt >= 6'd9) || eos;
    wire        enough2  = (bcnt >= 6'd16) || eos;         // a decision behind a pending renormalisation

    // ---- the contexts --------------------------------------------------------------
    logic        ctx_init_start, ctx_init_busy;
    logic        ctx_rd_en, ctx_wr_en;
    logic [8:0]  ctx_rd_addr;
    logic [6:0]  ctx_rd_state, ctx_wr_state;
    logic [31:0] ctx_rd_rlps, ctx_wr_rlps;
    // The write-back is combinational from S_DEC so it commits on S_DEC's own edge, one
    // edge BEFORE the next request's read (issued in the following idle cycle):
    // registering it would land it on that read's edge and a back-to-back decision on
    // the same ctxIdx would read the stale state (found by the bench: request 151 of
    // set 1, ctxIdx 184 twice).
    cabac_ctx contexts (
        .clk(clk), .rst_n(rst_n),
        .init_start(ctx_init_start), .init_set(ctx_q[7:6]), .init_qp(ctx_q[5:0]), .init_busy(ctx_init_busy),
        .rd_en(ctx_rd_en), .rd_addr(ctx_rd_addr), .rd_state(ctx_rd_state), .rd_rlps(ctx_rd_rlps),
        .wr_en(ctx_wr_en), .wr_addr(ctx_q), .wr_state(ctx_wr_state), .wr_rlps(ctx_wr_rlps));
    assign dbg_state = ctx_rd_state;

    wire idle   = (state == S_IDLE);
    wire accept = req_valid && req_ready;
    // a bypass/terminate/init/raw-byte needs the renormalised range and offset; a
    // decision only needs them by its compute cycle, which comes after the pending
    // renormalisation completes this cycle
    // FLUSH abandons the slice: it is taken even while a renormalisation waits for bits
    // that will never come (the parent stopped feeding this NAL unit after the slice's
    // end), else the next slice could never start
    assign req_ready = idle && !ctx_init_busy &&
                       ((req_kind == K_DECISION) ? (renorm_pending ? enough2 : enough) :
                        (req_kind == K_FLUSH)    ? 1'b1 :
                                                   (!renorm_pending && (enough || req_kind == K_ALIGN)));
    assign busy = !idle || ctx_init_busy || renorm_pending;

    // the read port: the accepted decision's context, else the bench's readback
    assign ctx_rd_en   = (accept && req_kind == K_DECISION) || (idle && dbg_rd_en);
    assign ctx_rd_addr = (accept && req_kind == K_DECISION) ? req_ctx : dbg_addr;

    // ---- DecodeDecision (9.3.3.2.1), combinational in S_DEC, up to the renormalisation
    wire [5:0]  p_state = ctx_rd_state[5:0];
    wire        val_mps = ctx_rd_state[6];
    // qCodIRangeIdx = (codIRange >> 6) & 3 selects the stored row's byte (a case, not a
    // variable part-select: CLAUDE.md)
    logic [7:0] r_lps;
    always_comb begin
        case (rng[7:6])
            2'd0:    r_lps = ctx_rd_rlps[7:0];
            2'd1:    r_lps = ctx_rd_rlps[15:8];
            2'd2:    r_lps = ctx_rd_rlps[23:16];
            default: r_lps = ctx_rd_rlps[31:24];
        endcase
    end
    // codIOffset >= codIRange - rLPS  <=>  rLPS >= codIRange - codIOffset: the difference
    // comes from registers alone (in parallel with the RAM), leaving one compare behind
    // the select. 11 bits signed: exact for any offset, including a stream error's
    // offset >= range (the model's arithmetic, bit for bit).
    wire signed [10:0] t_ro = $signed({2'b00, rng}) - $signed({1'b0, off});
    wire        is_lps  = ($signed({3'b000, r_lps}) >= t_ro);
    wire [8:0]  rng_mps = rng - {1'b0, r_lps};
    wire        dec_bin = is_lps ? ~val_mps : val_mps;
    wire [9:0]  off_dec = is_lps ? {2'b00, r_lps} - t_ro[9:0] : off;   // off - (rng - rLPS)
    wire [8:0]  rng_dec = is_lps ? {1'b0, r_lps} : rng_mps;
    wire [11:0] tr      = trans_rom[p_state];
    wire [63:0] rnext   = rnext_rom[p_state];
    wire [6:0]  st_next = is_lps ? {(p_state == 6'd0) ? ~val_mps : val_mps, tr[11:6]} : {val_mps, tr[5:0]};
    assign ctx_wr_en    = (state == S_DEC);
    assign ctx_wr_state = st_next;
    assign ctx_wr_rlps  = is_lps ? rnext[63:32] : rnext[31:0];

    // RenormD (9.3.3.2.2) as one shift in the cycle after: leading zeros of the 9-bit
    // range held in rng_pre. Written as a casez block, not a function: Quartus 17
    // miscompiles some `function automatic` helpers (CLAUDE.md).
    logic [3:0] sh_dec, sh_term;
    always_comb begin
        casez (rng_pre)
            9'b1????????: sh_dec = 4'd0;
            9'b01???????: sh_dec = 4'd1;
            9'b001??????: sh_dec = 4'd2;
            9'b0001?????: sh_dec = 4'd3;
            9'b00001????: sh_dec = 4'd4;
            9'b000001???: sh_dec = 4'd5;
            9'b0000001??: sh_dec = 4'd6;
            9'b00000001?: sh_dec = 4'd7;
            default:      sh_dec = 4'd8;
        endcase
    end
    wire        can_renorm = (bcnt >= {2'b00, sh_dec}) || eos;
    wire        renorm_now = idle && renorm_pending && can_renorm;

    // ---- DecodeBypass (9.3.3.2.3) and DecodeTerminate (9.3.3.2.4), in the accept cycle
    wire [9:0]  off_byp  = {off[8:0], top9[8]};
    wire        byp_bin  = (off_byp >= {1'b0, rng});
    wire [9:0]  off_byp2 = byp_bin ? off_byp - {1'b0, rng} : off_byp;
    wire [8:0]  rng_term = rng - 9'd2;
    wire        term_bin = (off >= {1'b0, rng_term});
    always_comb sh_term = rng_term[8] ? 4'd0 : 4'd1;   // codIRange >= 256 before, so 254..508 after

    // ---- what this cycle consumes ------------------------------------------------------
    always_comb begin
        take = 4'd0;
        if (renorm_now) take = sh_dec;
        else if (accept) begin
            case (req_kind)
                K_BYPASS:    take = 4'd1;
                K_TERMINATE: take = term_bin ? 4'd0 : sh_term;
                K_ALIGN:     take = {1'b0, bcnt[2:0]};
                K_RAWBYTE:   take = 4'd8;
                K_REINIT:    take = 4'd9;
                default:     take = 4'd0;
            endcase
        end else if (state == S_INIT_CTX && !ctx_init_busy && !ctx_init_start && enough) take = 4'd9;
    end
    assign flush_now = accept && (req_kind == K_FLUSH);

    // ---- registers -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bbuf <= 32'd0; bcnt <= 6'd0; eos <= 1'b0;
            rng <= 9'd510; off <= 10'd0; rng_pre <= 9'd0; off_pre <= 10'd0; renorm_pending <= 1'b0;
            state <= S_IDLE; ctx_q <= 9'd0;
            rsp_valid <= 1'b0; rsp_bin <= 1'b0; rsp_byte <= 8'd0;
            err_init <= 1'b0; err_align <= 1'b0; err_underrun <= 1'b0;
            ctx_init_start <= 1'b0;
            bin_count <= 32'd0;
        end else begin
            rsp_valid <= 1'b0;
            ctx_init_start <= 1'b0;

            // the bit buffer
            if (flush_now) begin
                bbuf <= 32'd0; bcnt <= 6'd0; eos <= 1'b0; renorm_pending <= 1'b0;
                err_init <= 1'b0; err_align <= 1'b0; err_underrun <= 1'b0;
                bin_count <= 32'd0;
            end else begin
                bbuf <= buf_next;
                bcnt <= cnt_next;
                if (refill && in_last) eos <= 1'b1;
                if (underrun) err_underrun <= 1'b1;
            end

            // the pending renormalisation of the last decision
            if (renorm_now && !flush_now) begin
                rng <= rng_pre << sh_dec;
                off <= (off_pre << sh_dec) | {1'b0, taken};
                renorm_pending <= 1'b0;
            end

            case (state)
                S_IDLE: if (accept) begin
                    ctx_q <= req_ctx;
                    case (req_kind)
                        K_DECISION: state <= S_DEC;
                        K_BYPASS: begin
                            off <= off_byp2;
                            rsp_valid <= 1'b1; rsp_bin <= byp_bin;
                            bin_count <= bin_count + 32'd1;
                        end
                        K_TERMINATE: begin
                            rng <= term_bin ? rng_term : (rng_term << sh_term);
                            if (!term_bin) off <= (off << sh_term) | {1'b0, taken};
                            rsp_valid <= 1'b1; rsp_bin <= term_bin;
                            bin_count <= bin_count + 32'd1;
                        end
                        K_INIT: begin
                            ctx_init_start <= 1'b1;
                            state <= S_INIT_CTX;
                        end
                        K_ALIGN: begin
                            rsp_valid <= 1'b1; rsp_bin <= 1'b0;
                        end
                        K_RAWBYTE: begin
                            if (bcnt[2:0] != 3'd0) err_align <= 1'b1;
                            rsp_valid <= 1'b1; rsp_bin <= 1'b0; rsp_byte <= bbuf[31:24];
                        end
                        K_REINIT: begin
                            rng <= 9'd510; off <= {1'b0, top9};
                            if (top9 >= 9'd510) err_init <= 1'b1;
                            rsp_valid <= 1'b1; rsp_bin <= 1'b0;
                        end
                        default: begin                       // K_FLUSH
                            rsp_valid <= 1'b1; rsp_bin <= 1'b0;
                        end
                    endcase
                end
                S_DEC: begin
                    rng_pre <= rng_dec;
                    off_pre <= off_dec;
                    renorm_pending <= 1'b1;
                    rsp_valid <= 1'b1; rsp_bin <= dec_bin;
                    bin_count <= bin_count + 32'd1;
                    state <= S_IDLE;
                end
                S_INIT_CTX: if (!ctx_init_busy && !ctx_init_start && enough) begin
                    rng <= 9'd510; off <= {1'b0, top9};
                    if (top9 >= 9'd510) err_init <= 1'b1;
                    rsp_valid <= 1'b1; rsp_bin <= 1'b0;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
