// h264/ovl_plane.sv -- the overlay plane (Phase 6b, interface 0.9): a page of the Linux
// framebuffer, described by the program in control words 72-79, fetched a line at a time on
// ram2 and handed to the output stage as premultiplied RGBA on the core's own raster
// (docs/architecture.md "The overlay plane (Phase 6b, interface 0.9)" -- the normative text;
// the bench's model, tools/ovl_ref.py, is written from it, not from this file).
//
// THE MAPPING is the identity, centred (decided 2026-09-30): canvas pixel (x, y) is raster pixel
// (x + ox, y + oy), ox = (720 - width) >> 1, oy = (lines - height) >>> 1, lines 480 or 576.
//
// clk_vid (the raster, a dot per `ce`; clk_sys until hd_raster, docs/hd_raster.md S3):
//   * the DESCRIPTOR: at the vertical blank's first line (progressive v_pos == lines; 480i the
//     field line lines / 2) a request toggle; clk_mem reads words 72-79 in one burst and answers
//     with the eight low halves stable; they are copied, and checked over a few cycles in the
//     order of the architecture's table (a torn copy -- gen_lo != gen_hi -- is counted and
//     ignored; ENABLE clear turns the overlay off; a failed check refuses it). The result is the
//     NEXT descriptor; each refresh's first line takes it (with the session level and the
//     anti-twitter choice), so nothing changes mid-picture.
//   * the LINE CONTROL, disp_reader's shape: at the first dot of every line the NEXT raster
//     line's canvas lines are worked out and commanded (a toggle, the fields stable until the
//     done toggle comes back): canvas line c = L - oy of frame line L; filtered (480i with the
//     option), c - 1 (only when the chain is broken), c and c + 1; else c. Each is valid inside
//     the band (the band lies inside the canvas); its address base + k x stride. Every active
//     line is commanded while the overlay is on -- an all-invalid command writes a transparent
//     line without a DDR3 read -- so the accumulator's chain (below) is never broken by the
//     band. A line whose command is not done when it begins is shown transparent and counted
//     (ovl_late); the engine is then busy, so the next line is not commanded (also counted),
//     and the one after starts a new chain.
//   * the READ-OUT: stage 0 the slot address from the raster column (every other dot at 480i),
//     (hd_raster: deepened for 81 MHz) stage 0 the canvas column, stage 1 the RAM word, stage 2
//     its output register, stages 3-7 delays -- LAT 9 dots from (h_pos, v_pos, de_in) to
//     (pr, pg, pb, pa), the picture's (disp_reader) -- 0 outside the canvas, off, or late.
//
// clk_mem (the engine), one command at a time, the descriptor read between commands:
//   * the FETCH walks the command's ops; a valid op's words go out as bursts of up to 8 (a
//     burst only when the beat FIFO has room for it beside every beat in flight), never
//     withdrawn under waitrequest (reset by the PLL lock alone, like every ram master);
//   * the CONSUMER walks the same ops, a pixel a clock: a valid op's pixels from its beats (4
//     a beat at 16 bpp, 2 at 8888; the last beat's surplus dropped), an invalid op's zeros;
//     a 4-clock bubble between ops (the accumulator's read-after-write distance);
//   * the PIPELINE: s1 the raw pixel, s2 unpacked to 8-bit colour and alpha, s3 the products
//     C x a, s4 P = div255 (exact: (x + 128 + ((x + 128) >> 8)) >> 8) with the accumulator's
//     word, s5 the op -- LOAD acc = P; ADD2 acc += 2 P; FINAL out = (acc + P + 2) >> 2, acc = P;
//     PLAIN out = P -- written at the edge after: the accumulator (10-bit sums, 2,048 x 40) and
//     the line slot (2 x 2,048 premultiplied RGBA 8888, a dual-clock M10K the read-out reads;
//     interface 0.12, hd_raster: a canvas up to 2,048 wide -- 1,024 until then).
//   A filtered field line's ADD2 (c) and FINAL (c + 1) leave P[c + 1] in the accumulator: the
//   next field line's c - 1. Each canvas line is fetched ONCE a field.
//
// No `function`, no N'(expr) cast, no variable part-select with a non-power-of-two stride
// (Quartus 17): the pixel within a beat is chosen by a case.

`default_nettype none

// (hd_raster) no M10K shift registers: a delay chain on the dot inferred as altshift_taps put a RAM's
// slow clock-to-out on an 81 MHz path (the first stage-A fit)
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module ovl_plane (
    // the raster (clk_vid since hd_raster: docs/hd_raster.md S3) and its dot enable
    input  wire         clk,
    input  wire         ce,                 // the dot: one clock in three on the 27 MHz rasters, every clock native
    input  wire         rst_n,              // the PLL lock alone (a program's counts survive an OSD Reset)
    input  wire  [11:0] h_pos,
    input  wire  [11:0] v_pos,
    input  wire         de_in,
    input  wire         il,                 // the 480i / 576i raster (a pixel is two dots; v_pos the frame line)
    input  wire         prog240,            // progressive 240p/288p: logical rows are sampled at 2x
    input  wire         pal,                // the 625-line raster (576 active)
    input  wire  [11:0] rast_w,             // (interface 0.10) progressive: the raster's width (720 fitted, native's)
    input  wire  [11:0] rast_h,             // ... and its lines (480 / 576 fitted, native's): raster_geom's, the
                                            // raster the NEXT frame scans -- the canvas is centred on it
    input  wire  [11:0] rast_lines,         // ... the frame sync_gen scans: its active lines
    input  wire  [11:0] rast_last,          // ... and its last line's index
    input  wire         sess,               // a session is open (ring_rd): shown only then
    input  wire         at_en,              // Anti-Twitter Auto or On (the overlay is graphics)
    // the pixel, premultiplied, LAT 9 (hd_raster; 5 before)
    output logic [7:0]  pr,
    output logic [7:0]  pg,
    output logic [7:0]  pb,
    output logic [7:0]  pa,
    // the status (words 46-47)
    output logic [31:0] ovl_gen,
    output logic [1:0]  ovl_state,
    output logic        ovl_at,
    output logic        ovl_clip,
    output logic [3:0]  ovl_err,
    output logic [7:0]  ovl_torn,
    output logic [15:0] ovl_late,
    output logic [31:0] ovl_lines,

    // DDR3 reads (clk_mem): ddr_mux2's master B on ram2
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid
);

`include "h264/ring_iface.svh"

    wire prog240_i = (prog240 === 1'b1);     // older named-port benches may omit this optional mode

    localparam logic [1:0] K_LOAD = 2'd0, K_ADD2 = 2'd1, K_FINAL = 2'd2, K_PLAIN = 2'd3;

    // the line slots: 2 x 2,048 premultiplied RGBA ({r, g, b, a}); written on clk_mem, read on clk_vid
    logic [31:0] slot_ram [0:4095];

    // =========================================================================================
    // clk_vid: the descriptor
    // =========================================================================================
    // the raster the canvas is centred on: 720 x 480 / 576 interlaced; progressive the frame
    // sync_gen is scanning (fitted, or native: up to 1,024 x 2,047 -- docs/hdmi_raster.md stage 2)
    wire  [11:0] lines = il ? (pal ? 12'd576 : 12'd480) : rast_lines;
    // (hd_raster) the frame about to begin: the descriptor is taken on the old frame's last line, when
    // sync_gen's `lines` is still the old frame's -- centred on that, the first frame after a native
    // size change showed the canvas off by half the change (found by n8888hd: 480 -> 720 lines)
    wire  [11:0] lines_n = il ? (pal ? 12'd576 : 12'd480) : rast_h;
    wire  [11:0] rw    = il ? 12'd720 : rast_w;
    wire [11:0]  raster_y = prog240_i ? {v_pos[10:0], 1'b0} : v_pos;
    wire         vb_first = il ? (v_pos[11:1] == lines[11:1]) : (raster_y == lines);

    logic        d_req;                     // the request toggle (to clk_mem)
    logic        d_ack;                     // clk_mem
    logic [31:0] d_w [0:7];                 // clk_mem: the eight low halves, stable from d_ack's flip
    logic        da_s1, da_s2, da_s3;
    logic [31:0] dq [0:7];                  // the copy
    logic [2:0]  vs;                        // the checks' sequencer
    logic [26:0] q_prod;                    // (height - 1) x stride (2,046 x 65,535 < 2^27)
    logic        f_torn, f_ctl, f_size, f_stride, f_align, f_band, f_range;   // the checks, a step before the verdict
    // the next descriptor (what the checks accepted); taken at each refresh's first line
    logic        nd_on;
    logic [1:0]  nd_fmt;
    logic [31:0] nd_base;
    logic [11:0] nd_w, nd_h;                // (0.12) up to 2,048 x 2,048
    logic [15:0] nd_s;
    logic [11:0] nd_bf, nd_bl;

    wire  [31:0] q_ctl = dq[1], q_base = dq[2], q_size = dq[3], q_str = dq[4], q_band = dq[5];
    wire  [1:0]  q_fmt = q_ctl[2:1];
    wire  [15:0] q_w = q_size[15:0], q_h = q_size[31:16], q_s = q_str[15:0];
    wire  [15:0] q_bf = q_band[15:0], q_bl = q_band[31:16];
    wire  [17:0] q_wb = (q_fmt == RO_FMT_8888) ? {q_w, 2'b00} : {1'b0, q_w, 1'b0};   // width x bytes a pixel
    wire         e_ctl    = ((q_ctl & RI_OVL_CTL_RESERVED) != 32'd0) || (dq[6] != 32'd0) || (q_fmt == 2'd3);
    wire         e_size   = (q_w == 16'd0) || (q_w > RI_OVL_MAX_W) || (q_h == 16'd0) || (q_h > RI_OVL_MAX_H);
    wire         e_stride = (q_s[2:0] != 3'd0) || ({2'd0, q_s} < q_wb) || (q_str[31:16] != 16'd0);
    wire         e_align  = (q_base[2:0] != 3'd0);
    wire         e_band   = (q_bf > q_bl) || (q_bl >= q_h);
    wire  [32:0] q_end    = {1'b0, q_base} + {6'd0, q_prod} + {15'd0, q_wb};
    wire         e_range  = (q_base < RI_FB_BYTE) || (q_end > ({1'b0, RI_FB_BYTE} + {1'b0, RI_FB_SIZE}));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_req <= 1'b0; da_s1 <= 1'b0; da_s2 <= 1'b0; da_s3 <= 1'b0; vs <= '0; q_prod <= '0;
            f_torn <= 1'b0; f_ctl <= 1'b0; f_size <= 1'b0; f_stride <= 1'b0; f_align <= 1'b0; f_band <= 1'b0; f_range <= 1'b0;
            for (int i = 0; i < 8; i++) dq[i] <= '0;
            nd_on <= 1'b0; nd_fmt <= '0; nd_base <= '0; nd_w <= '0; nd_h <= '0; nd_s <= '0; nd_bf <= '0; nd_bl <= '0;
            ovl_gen <= '0; ovl_state <= RO_S_OFF; ovl_err <= RO_E_NONE; ovl_torn <= '0; ovl_clip <= 1'b0;
        end else begin
            da_s1 <= d_ack; da_s2 <= da_s1; da_s3 <= da_s2;
            // one request a refresh, never two outstanding
            // (the checks below run every clock: they only make the next descriptor ready sooner)
            if (ce && h_pos == 12'd0 && vb_first && (da_s2 == d_req)) d_req <= !d_req;
            ovl_clip <= nd_on && ((nd_h > lines) || (nd_w > rw));   // (0.10) or wider than the raster
            case (vs)
                3'd0: if (da_s2 != da_s3) begin                  // the answer: copy (stable since the flip)
                    for (int i = 0; i < 8; i++) dq[i] <= d_w[i];
                    vs <= 3'd1;
                end
                3'd1: begin
                    q_prod <= ({15'd0, q_h[11:0]} - 27'd1) * {11'd0, q_s};  // only read when SIZE passed (h <= 2,048: 2,047 x 65,535 < 2^27)
                    vs <= 3'd2;
                end
                3'd2: begin                                      // (hd_raster) the checks, registered
                    f_torn <= (dq[0] != dq[7]);
                    f_ctl <= e_ctl; f_size <= e_size; f_stride <= e_stride; f_align <= e_align;
                    f_band <= e_band; f_range <= e_range;
                    vs <= 3'd3;
                end
                default: begin
                    vs <= 3'd0;
                    if (f_torn) begin                            // torn: the descriptor in use kept
                        if (ovl_torn != 8'hFF) ovl_torn <= ovl_torn + 8'd1;
                    end else begin
                        ovl_gen <= dq[0];
                        if (!q_ctl[0]) begin                         // RI_OVL_CTL_ENABLE_BIT
                            nd_on <= 1'b0; ovl_state <= RO_S_OFF; ovl_err <= RO_E_NONE;
                        end else if (f_ctl || f_size || f_stride || f_align || f_band || f_range) begin
                            nd_on <= 1'b0; ovl_state <= RO_S_REFUSED;
                            ovl_err <= f_ctl ? RO_E_CTL : f_size ? RO_E_SIZE : f_stride ? RO_E_STRIDE :
                                       f_align ? RO_E_ALIGN : f_band ? RO_E_BAND : RO_E_RANGE;
                        end else begin
                            nd_on <= 1'b1; ovl_state <= RO_S_ACCEPTED; ovl_err <= RO_E_NONE;
                            nd_fmt <= q_fmt; nd_base <= q_base; nd_w <= q_w[11:0]; nd_h <= q_h[11:0];
                            nd_s <= q_s; nd_bf <= q_bf[11:0]; nd_bl <= q_bl[11:0];
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================================================
    // clk_vid: the line control
    // =========================================================================================
    // the next raster line's frame line (disp_reader's rule): Progressive v + 1 (the last line
    // -> 0); 480i the field's next line v + 2, after a field's last line the other field's first
    wire  [10:0] fl = v_pos[11:1];
    wire         il_last = v_pos[0] ? (fl == (pal ? 11'd311 : 11'd261)) : (fl == (pal ? 11'd312 : 11'd262));
    wire  [11:0] nxt_line = il ? (il_last ? {11'd0, ~v_pos[0]} : v_pos + 12'd2)
                               : prog240_i ? ((v_pos == rast_last) ? 12'd0 : {v_pos[10:0] + 11'd1, 1'b0})
                                           : ((v_pos == rast_last) ? 12'd0 : v_pos + 12'd1);

    // this refresh's descriptor (taken at its first line)
    logic        r_on, r_at;
    logic [1:0]  r_fmt;
    logic [31:0] r_base;
    logic [11:0] r_w;
    logic [15:0] r_s;
    logic [11:0] r_bf, r_bl;
    logic signed [12:0] r_ox;               // (0.10) signed: a canvas wider than the raster is clipped both sides
    logic signed [12:0] r_oy;
    logic [10:0] r_words;                   // 64-bit words a canvas line (<= 1,024: 2,048 at 8888)
    // the command to clk_mem (held from one issue to the next)
    logic        cmd_tog;
    logic        cmd_filt, cmd_pro, cmd_slot;
    logic [2:0]  cmd_v;                     // c - 1, c, c + 1 valid
    logic [28:0] cmd_a0, cmd_a1, cmd_a2;    // their word addresses
    logic [10:0] cmd_words;
    logic [1:0]  cmd_fmt;
    logic [11:0] cmd_w;
    logic        done_s1, done_s2;
    logic        done_tog;                  // clk_mem
    wire         cmd_pending = (done_s2 != cmd_tog);
    // the sequencer
    logic [2:0]  lseq;
    logic [11:0] ln_line;
    logic        ln_first, ln_act, chain;
    logic signed [12:0] ln_c;
    logic signed [29:0] ln_prod;          // c x stride, SIGNED: c is -1 on the line above the canvas,
                                          // and c + 1's address (base + 0) is derived from it
    logic [31:0] ln_a;
    logic [2:0]  ln_v;
    // the line being shown, and the next one's (commanded during this line)
    logic        cur_ok, cur_slot, nx_want, nx_iss, nx_slot;
    wire         line_ok_d0 = nx_want && nx_iss && !cmd_pending;

    wire signed [12:0] ln_cm = ln_c - 13'sd1, ln_cp = ln_c + 13'sd1;
    wire         v_m = (ln_cm >= $signed({1'd0, r_bf})) && (ln_cm <= $signed({1'd0, r_bl}));
    wire         v_0 = (ln_c  >= $signed({1'd0, r_bf})) && (ln_c  <= $signed({1'd0, r_bl}));
    wire         v_p = (ln_cp >= $signed({1'd0, r_bf})) && (ln_cp <= $signed({1'd0, r_bl}));
    wire  [31:0] ln_am = ln_a - {16'd0, r_s}, ln_ap = ln_a + {16'd0, r_s};
    wire         cmd_pro_next = r_at && !chain;
    wire signed [12:0] ox_n = $signed({1'b0, rw}) - $signed({1'b0, nd_w});   // >>> 1: the canvas's left edge
    wire signed [12:0] oy_n = $signed({1'b0, lines_n}) - $signed({1'b0, nd_h}); // >>> 1: its top (the next frame's)
    wire  [12:0] wd_32 = {1'b0, nd_w} + 13'd1, wd_16 = {1'b0, nd_w} + 13'd3;  // 64-bit words a line: 8888 >> 1, 16 bpp >> 2
    wire  [1:0]  n_valid = {1'b0, ln_v[0] & cmd_pro_next} + {1'b0, ln_v[1]} + {1'b0, ln_v[2] & r_at};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_on <= 1'b0; r_at <= 1'b0; r_fmt <= '0; r_base <= '0; r_w <= '0; r_s <= '0; r_bf <= '0; r_bl <= '0;
            r_ox <= '0; r_oy <= '0; r_words <= '0;
            cmd_tog <= 1'b0; cmd_filt <= 1'b0; cmd_pro <= 1'b0; cmd_slot <= 1'b0; cmd_v <= '0;
            cmd_a0 <= '0; cmd_a1 <= '0; cmd_a2 <= '0; cmd_words <= '0; cmd_fmt <= '0; cmd_w <= '0;
            done_s1 <= 1'b0; done_s2 <= 1'b0;
            lseq <= '0; ln_line <= '0; ln_first <= 1'b0; ln_act <= 1'b0; chain <= 1'b0; ln_c <= '0;
            ln_prod <= '0; ln_a <= '0; ln_v <= '0;
            cur_ok <= 1'b0; cur_slot <= 1'b0; nx_want <= 1'b0; nx_iss <= 1'b0; nx_slot <= 1'b0;
            ovl_late <= '0; ovl_lines <= '0; ovl_at <= 1'b0;
        end else begin
            done_s1 <= done_tog; done_s2 <= done_s1;
            if (!ce) ;                      // (hd_raster) the line control advances a dot at a time
            else if (h_pos == 12'd0) begin
                // this line: its command was issued during the previous line
                cur_ok <= line_ok_d0; cur_slot <= nx_slot;
                if (nx_want && !line_ok_d0 && ovl_late != 16'hFFFF) ovl_late <= ovl_late + 16'd1;
                nx_want <= 1'b0; nx_iss <= 1'b0;
                // the next line's work (its first-line flag a step later: hd_raster's 81 MHz)
                ln_line <= nxt_line;
                lseq <= 3'd7;
            end else begin
                case (lseq)
                    3'd7: begin
                        ln_first <= (ln_line == 12'd0) || (il && ln_line == 12'd1);
                        lseq <= 3'd1;
                    end
                    3'd1: begin
                        if (ln_first) begin                     // a refresh begins: its descriptor
                            r_on <= nd_on && sess; r_at <= il && at_en; r_fmt <= nd_fmt; r_base <= nd_base;
                            r_w <= nd_w; r_s <= nd_s; r_bf <= nd_bf; r_bl <= nd_bl;
                            r_ox <= ox_n >>> 1;
                            r_oy <= oy_n >>> 1;
                            r_words <= (nd_fmt == RO_FMT_8888) ? wd_32[11:1] : wd_16[12:2];
                            ovl_at <= il && at_en;
                            chain <= 1'b0;
                        end
                        lseq <= 3'd2;
                    end
                    3'd2: begin
                        ln_act <= r_on && (ln_line < lines);
                        ln_c <= $signed({1'b0, ln_line}) - r_oy;
                        lseq <= 3'd3;
                    end
                    3'd3: begin
                        ln_prod <= ln_c * $signed({1'b0, r_s});  // -1,024 .. 3,071 lines x < 65,536 bytes
                        ln_v <= {v_p, v_0, v_m};
                        lseq <= 3'd4;
                    end
                    3'd4: begin
                        ln_a <= r_base + {{2{ln_prod[29]}}, ln_prod};
                        lseq <= 3'd5;
                    end
                    3'd5: begin
                        lseq <= 3'd0;
                        if (!ln_act) chain <= 1'b0;
                        else begin
                            nx_want <= 1'b1;
                            if (cmd_pending) chain <= 1'b0;     // the engine is behind: not commanded
                            else begin
                                cmd_filt <= r_at; cmd_pro <= cmd_pro_next; cmd_v <= ln_v;
                                cmd_a0 <= ln_am[31:3]; cmd_a1 <= ln_a[31:3]; cmd_a2 <= ln_ap[31:3];
                                cmd_words <= r_words; cmd_fmt <= r_fmt; cmd_w <= r_w;
                                cmd_slot <= !cmd_slot; nx_slot <= !cmd_slot;
                                cmd_tog <= !cmd_tog; nx_iss <= 1'b1;
                                chain <= r_at;
                                ovl_lines <= ovl_lines + {30'd0, n_valid};
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================================
    // clk_vid: the read-out, LAT 9 dots (disp_reader's: hd_raster deepened both for 81 MHz)
    // =========================================================================================
    // stage 0 the canvas column and its flag, stage 1 the RAM word, stage 2 the M10K's output
    // register, stages 3-7 delays, stage 8 the output (0 outside the canvas, off, or late)
    wire         dot0 = (h_pos == 12'd0);
    wire         e_ok = dot0 ? line_ok_d0 : cur_ok;
    wire         e_slot = dot0 ? nx_slot : cur_slot;
    wire  [10:0] x = (il || prog240_i) ? {1'b0, h_pos[10:1]} : h_pos[10:0];
    wire signed [12:0] x_c = $signed({2'b0, x}) - r_ox;      // the canvas column (r_ox < 0: clipped at the left)
    wire         in_x = (x_c >= 13'sd0) && (x_c < $signed({1'b0, r_w}));
    logic [10:0] s0_x;
    logic        s0_slot;
    logic [8:1]  in_d;
    logic [31:0] q1, q2, q3, q4, q5, q6, q7;
    always_ff @(posedge clk) if (ce) begin
        s0_x <= x_c[10:0]; s0_slot <= e_slot;
        q1 <= slot_ram[{s0_slot, s0_x}];
        in_d <= {in_d[7:1], de_in && e_ok && in_x};
        q2 <= q1; q3 <= q2; q4 <= q3; q5 <= q4; q6 <= q5; q7 <= q6;
        {pr, pg, pb, pa} <= in_d[8] ? q7 : 32'd0;
    end

    // =========================================================================================
    // clk_mem: the engine
    // =========================================================================================
    logic [2:0]  m_tog;                     // cmd_tog, synchronised
    logic [2:0]  dr_m;                      // d_req, synchronised
    wire         m_cmd = m_tog[2] != m_tog[1];
    wire         m_dreq = dr_m[2] != dr_m[1];
    logic        c_pend, d_pend;            // a command / a descriptor request waiting
    // the captured command
    logic        m_busy, m_slot;
    logic [1:0]  m_fmt;
    logic [11:0] m_w;
    logic [10:0] m_words;
    logic [1:0]  n_ops;                     // ops - 1
    logic        o_v [0:2];
    logic [28:0] o_a [0:2];
    logic [1:0]  o_k [0:2];
    // the descriptor read
    logic        d_busy, d_issued;
    logic [2:0]  d_n;
    // the fetch
    logic [1:0]  i_op;
    logic        i_done;
    logic [10:0] i_left;
    logic [28:0] i_addr;
    logic [7:0]  inflight;                  // beats issued, not yet landed
    // the beat FIFO
    logic [63:0] f_dout;
    logic        f_valid, f_rd;
    logic [7:0]  f_count;
    // the consumer
    logic [1:0]  k_op;
    logic        k_done;
    logic [10:0] k_x;
    logic [1:0]  k_pix;
    logic [2:0]  k_gap;
    logic [63:0] bw;

    wire  [7:0]  i_burst = (i_left > 11'd8) ? 8'd8 : {1'b0, i_left[6:0]};
    wire         i_room = ({1'b0, f_count} + {1'b0, inflight} + {1'b0, i_burst}) <= 9'd64;
    wire         last_pix = ({1'b0, k_x} == m_w - 12'd1);
    wire         pix_16 = (m_fmt != RO_FMT_8888);
    // the consumer's step: a valid op needs its beat (the held one, or the FIFO's head at a beat's first pixel)
    wire         k_act = m_busy && !k_done && (k_gap == 3'd0);
    wire         k_need = o_v[k_op] && (k_pix == 2'd0);
    wire         k_go = k_act && (!k_need || f_valid);
    wire  [63:0] k_beat = (k_pix == 2'd0) ? f_dout : bw;
    logic [31:0] k_raw;
    always_comb begin
        k_raw = 32'd0;
        if (pix_16)
            case (k_pix)
                2'd0: k_raw = {16'd0, k_beat[15:0]};
                2'd1: k_raw = {16'd0, k_beat[31:16]};
                2'd2: k_raw = {16'd0, k_beat[47:32]};
                default: k_raw = {16'd0, k_beat[63:48]};
            endcase
        else
            case (k_pix[0])
                1'b0: k_raw = k_beat[31:0];
                default: k_raw = k_beat[63:32];
            endcase
        if (!o_v[k_op]) k_raw = 32'd0;
    end
    assign f_rd = k_go && k_need;

    sfifo #(.DW(64), .AW(6)) u_beats (
        .clk        (mclk),
        .rst_n      (mrst_n),
        .din        (ddr_readdata),
        .wr_en      (ddr_readdatavalid && !d_busy),
        .full       (),
        .dout       (f_dout),
        .dout_valid (f_valid),
        .rd_en      (f_rd),
        .count      (f_count)
    );

    // the pipeline
    logic        p1_v, p2_v, p3_v, p4_v, p5_v;
    logic [1:0]  p1_k, p2_k, p3_k, p4_k, p5_k;
    logic [10:0] p1_x, p2_x, p3_x, p4_x, p5_x;
    logic [31:0] p1_raw;
    logic [7:0]  c2_r, c2_g, c2_b, c2_a;
    logic [15:0] m3_r, m3_g, m3_b;
    logic [7:0]  a3;
    logic [7:0]  p4_r, p4_g, p4_b, p4_a;
    logic [39:0] acc_q, acc5;
    logic [31:0] out5;
    logic [39:0] acc_ram [0:2047];

    // s1 -> s2: the unpack
    logic [7:0]  u_r, u_g, u_b, u_a;
    always_comb begin
        case (m_fmt)
            RO_FMT_1555: begin
                u_a = p1_raw[15] ? 8'd255 : 8'd0;
                u_r = {p1_raw[14:10], p1_raw[14:12]};
                u_g = {p1_raw[9:5],   p1_raw[9:7]};
                u_b = {p1_raw[4:0],   p1_raw[4:2]};
            end
            RO_FMT_4444: begin
                u_a = {p1_raw[15:12], p1_raw[15:12]};
                u_r = {p1_raw[11:8],  p1_raw[11:8]};
                u_g = {p1_raw[7:4],   p1_raw[7:4]};
                u_b = {p1_raw[3:0],   p1_raw[3:0]};
            end
            default: begin
                u_a = p1_raw[31:24]; u_r = p1_raw[23:16]; u_g = p1_raw[15:8]; u_b = p1_raw[7:0];
            end
        endcase
    end
    // s3 -> s4: div255, exact for x <= 65,535
    wire  [16:0] t_r = {1'b0, m3_r} + 17'd128, t_g = {1'b0, m3_g} + 17'd128, t_b = {1'b0, m3_b} + 17'd128;
    wire  [17:0] d_r = {1'b0, t_r} + {9'd0, t_r[16:8]}, d_g = {1'b0, t_g} + {9'd0, t_g[16:8]},
                 d_b = {1'b0, t_b} + {9'd0, t_b[16:8]};
    // s4 -> s5: the op, per component ({r, g, b, a}; the accumulator 10 bits each: at most
    // 255 + 2 x 255 after ADD2, 1,022 in FINAL's sum)
    wire  [9:0]  a_r = acc_q[39:30], a_g = acc_q[29:20], a_b = acc_q[19:10], a_a = acc_q[9:0];
    wire  [9:0]  d2_r = a_r + {1'b0, p4_r, 1'b0}, d2_g = a_g + {1'b0, p4_g, 1'b0},
                 d2_b = a_b + {1'b0, p4_b, 1'b0}, d2_a = a_a + {1'b0, p4_a, 1'b0};
    wire  [9:0]  s_r = a_r + {2'd0, p4_r} + 10'd2, s_g = a_g + {2'd0, p4_g} + 10'd2,
                 s_b = a_b + {2'd0, p4_b} + 10'd2, s_a = a_a + {2'd0, p4_a} + 10'd2;
    wire  [39:0] p4_w = {2'd0, p4_r, 2'd0, p4_g, 2'd0, p4_b, 2'd0, p4_a};
    logic [39:0] o_acc;
    logic [31:0] o_out;
    always_comb begin
        case (p4_k)
            K_LOAD:  begin o_acc = p4_w;                     o_out = 32'd0; end
            K_ADD2:  begin o_acc = {d2_r, d2_g, d2_b, d2_a}; o_out = 32'd0; end
            K_FINAL: begin o_acc = p4_w;                     o_out = {s_r[9:2], s_g[9:2], s_b[9:2], s_a[9:2]}; end
            default: begin o_acc = 40'd0;                    o_out = {p4_r, p4_g, p4_b, p4_a}; end
        endcase
    end

    always_ff @(posedge mclk) begin
        if (p5_v && p5_k != K_PLAIN) acc_ram[p5_x] <= acc5;
        if (p5_v && (p5_k == K_FINAL || p5_k == K_PLAIN)) slot_ram[{m_slot, p5_x}] <= out5;
        acc_q <= acc_ram[p3_x];
    end

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            m_tog <= '0; dr_m <= '0; c_pend <= 1'b0; d_pend <= 1'b0; d_ack <= 1'b0; done_tog <= 1'b0;
            m_busy <= 1'b0; m_slot <= 1'b0; m_fmt <= '0; m_w <= '0; m_words <= '0; n_ops <= '0;
            for (int i = 0; i < 3; i++) begin o_v[i] <= 1'b0; o_a[i] <= '0; o_k[i] <= '0; end
            for (int i = 0; i < 8; i++) d_w[i] <= '0;
            d_busy <= 1'b0; d_issued <= 1'b0; d_n <= '0;
            i_op <= '0; i_done <= 1'b1; i_left <= '0; i_addr <= '0; inflight <= '0;
            k_op <= '0; k_done <= 1'b1; k_x <= '0; k_pix <= '0; k_gap <= '0; bw <= '0;
            ddr_address <= '0; ddr_burstcount <= 8'd8; ddr_read <= 1'b0;
            p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; p4_v <= 1'b0; p5_v <= 1'b0;
            p1_k <= '0; p2_k <= '0; p3_k <= '0; p4_k <= '0; p5_k <= '0;
            p1_x <= '0; p2_x <= '0; p3_x <= '0; p4_x <= '0; p5_x <= '0; p1_raw <= '0;
            c2_r <= '0; c2_g <= '0; c2_b <= '0; c2_a <= '0; m3_r <= '0; m3_g <= '0; m3_b <= '0; a3 <= '0;
            p4_r <= '0; p4_g <= '0; p4_b <= '0; p4_a <= '0; acc5 <= '0; out5 <= '0;
        end else begin
            m_tog <= {m_tog[1:0], cmd_tog};
            dr_m <= {dr_m[1:0], d_req};
            if (m_cmd) c_pend <= 1'b1;
            if (m_dreq) d_pend <= 1'b1;
            if (ddr_readdatavalid) inflight <= inflight - 8'd1;

            // ---- start: the descriptor first (between commands), else the command ----
            if (!m_busy && !d_busy && inflight == 8'd0 && !ddr_read) begin
                if (d_pend && !m_cmd) begin
                    d_pend <= 1'b0; d_busy <= 1'b1; d_issued <= 1'b0; d_n <= '0;
                end else if (c_pend && !m_cmd) begin
                    // the fields have been stable since the toggle (two mclk cycles ago at least)
                    c_pend <= 1'b0; m_busy <= 1'b1;
                    m_slot <= cmd_slot; m_fmt <= cmd_fmt; m_w <= cmd_w; m_words <= cmd_words;
                    if (cmd_filt && cmd_pro) begin
                        n_ops <= 2'd2;
                        o_v[0] <= cmd_v[0]; o_a[0] <= cmd_a0; o_k[0] <= K_LOAD;
                        o_v[1] <= cmd_v[1]; o_a[1] <= cmd_a1; o_k[1] <= K_ADD2;
                        o_v[2] <= cmd_v[2]; o_a[2] <= cmd_a2; o_k[2] <= K_FINAL;
                    end else if (cmd_filt) begin
                        n_ops <= 2'd1;
                        o_v[0] <= cmd_v[1]; o_a[0] <= cmd_a1; o_k[0] <= K_ADD2;
                        o_v[1] <= cmd_v[2]; o_a[1] <= cmd_a2; o_k[1] <= K_FINAL;
                        o_v[2] <= 1'b0;     o_a[2] <= '0;     o_k[2] <= K_PLAIN;
                    end else begin
                        n_ops <= 2'd0;
                        o_v[0] <= cmd_v[1]; o_a[0] <= cmd_a1; o_k[0] <= K_PLAIN;
                        o_v[1] <= 1'b0;     o_a[1] <= '0;     o_k[1] <= K_PLAIN;
                        o_v[2] <= 1'b0;     o_a[2] <= '0;     o_k[2] <= K_PLAIN;
                    end
                    i_op <= '0; i_done <= 1'b0; i_left <= cmd_words;
                    i_addr <= (cmd_filt && cmd_pro) ? cmd_a0 : cmd_a1;
                    k_op <= '0; k_done <= 1'b0; k_x <= '0; k_pix <= '0; k_gap <= '0;
                end
            end

            // ---- the descriptor's beats ----
            if (d_busy && ddr_readdatavalid) begin
                d_w[d_n] <= ddr_readdata[31:0];
                d_n <= d_n + 3'd1;
                if (d_n == 3'd7) begin d_busy <= 1'b0; d_ack <= !d_ack; end
            end

            // ---- the Avalon command: held while waitrequest, never withdrawn ----
            if (!ddr_read || !ddr_waitrequest) begin
                ddr_read <= 1'b0;
                if (d_busy && !d_issued) begin
                    ddr_read <= 1'b1; ddr_address <= RI_OVL_DESC_WORD; ddr_burstcount <= 8'd8;
                    d_issued <= 1'b1; inflight <= inflight + 8'd8 - {7'd0, ddr_readdatavalid};
                end else if (m_busy && !i_done) begin
                    if (!o_v[i_op] || i_left == 11'd0) begin
                        // the next op (an invalid one issues nothing)
                        if (i_op == n_ops) i_done <= 1'b1;
                        else begin
                            i_op <= i_op + 2'd1; i_left <= m_words;
                            case (i_op)
                                2'd0: i_addr <= o_a[1];
                                default: i_addr <= o_a[2];
                            endcase
                        end
                    end else if (i_room) begin
                        ddr_read <= 1'b1; ddr_address <= i_addr; ddr_burstcount <= i_burst;
                        i_addr <= i_addr + {21'd0, i_burst}; i_left <= i_left - {3'b0, i_burst};
                        inflight <= inflight + i_burst - {7'd0, ddr_readdatavalid};
                    end
                end
            end

            // ---- the consumer: a pixel a clock ----
            p1_v <= 1'b0;
            if (m_busy && !k_done && k_gap != 3'd0) k_gap <= k_gap - 3'd1;
            if (k_go) begin
                p1_v <= 1'b1; p1_k <= o_k[k_op]; p1_x <= k_x; p1_raw <= k_raw;
                if (k_need) bw <= f_dout;
                k_pix <= (last_pix || (pix_16 ? (k_pix == 2'd3) : (k_pix == 2'd1))) ? 2'd0 : k_pix + 2'd1;
                if (last_pix) begin
                    k_x <= '0;
                    if (k_op == n_ops) k_done <= 1'b1;
                    else begin k_op <= k_op + 2'd1; k_gap <= 3'd4; end
                end else k_x <= k_x + 11'd1;
            end
            // s2: unpacked
            p2_v <= p1_v; p2_k <= p1_k; p2_x <= p1_x;
            c2_r <= u_r; c2_g <= u_g; c2_b <= u_b; c2_a <= u_a;
            // s3: the products
            p3_v <= p2_v; p3_k <= p2_k; p3_x <= p2_x;
            m3_r <= c2_r * c2_a; m3_g <= c2_g * c2_a; m3_b <= c2_b * c2_a; a3 <= c2_a;
            // s4: P (acc_q lands beside it)
            p4_v <= p3_v; p4_k <= p3_k; p4_x <= p3_x;
            p4_r <= d_r[15:8]; p4_g <= d_g[15:8]; p4_b <= d_b[15:8]; p4_a <= a3;
            // s5: the op
            p5_v <= p4_v; p5_k <= p4_k; p5_x <= p4_x;
            acc5 <= o_acc; out5 <= o_out;
            // done: every op consumed and the pipeline drained (the last write is at the next edge
            // after p5; done_tog crosses two flops before the raster reads the slot)
            if (m_busy && k_done && i_done && !p1_v && !p2_v && !p3_v && !p4_v && !p5_v) begin
                m_busy <= 1'b0; done_tog <= !done_tog;
            end
        end
    end
endmodule

`default_nettype wire
