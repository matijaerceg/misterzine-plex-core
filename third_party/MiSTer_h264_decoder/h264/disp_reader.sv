// h264/disp_reader.sv -- the display reader: a DPB store, straight from DDR3 on its own
// port (ram2), FITTED to the 720x480 / 720x576 raster (docs/display.md; docs/analog.md §5, P6 step 3;
// born as the P4 smoke display, docs/h264_recon.md S4)
//
// WHICH picture is emu's business (disp_ctl); WHERE and HOW BIG is h264/disp_fit.sv's (the
// fit_* inputs: the output rectangle, the Q.16 steps, the power-of-two decimation, the
// crop's origin and size -- quasi-static, published together, changed only at a pickup).
//
// THE FIT (docs/analog.md §5, tools/disp_fit_ref.py, the render golden tools/disp_golden.py):
// the store is read as DECIMATED ROWS -- decimated row k is the box of source rows
// [k dv, k dv + dv) and, within it, samples [m dh, m dh + dh): (sum + 2^(s-1)) >> s, s =
// dh_l2 + dv_l2 -- held in a ring of four tagged line slots. Output pixel x of frame line
// L samples source position (lx + (x - ox0 + 1/2) sx - 1/2, ty + (L - oy0 + 1/2) sy - 1/2),
// in decimated units (p - (d - 1) / 2) / d, clamped to the crop: luma is the 2-tap blend
// (a (256 - w) + b w + 128) >> 8 horizontally on rows k and k + 1, then vertically; chroma
// is NEAREST (the luma tap k + (w >= 128), >> 1: chroma is decimated by the same factors,
// so the 4:2:0 ratio holds) -- except at the identity fit (CHROMA AT THE IDENTITY, docs/display.md:
// Native (HDMI), the 1:1 Progressive picture), where chroma is INTERPOLATED at H.264's default siting
// (chroma_sample_loc_type 0): an odd column (c[x >> 1] + c[(x + 1) >> 1] + 1) >> 1, then on a frame
// store row 2m (3 c[m] + c[m - 1] + 2) >> 2, row 2m + 1 (3 c[m] + c[m + 1] + 2) >> 2 -- the
// hard 2-pixel colour steps nearest leaves beside saturated detail (red above all) gone, at
// shifts and adds: the neighbours are the previous dot's read and the kernel's rows a / d, already
// held. Outside the rectangle: black, de_out 0. At 480i frame line L
// is v_pos (the field's own lines): every field is its own sample of the one resample.
//
// ANTI-TWITTER (P6 step 4, docs/analog.md §9; fit_vpf 4, published by disp_fit: the option,
// 480i, a frame store): decimated LUMA row k is the SLIDING box of source rows [k dv, k dv +
// 2 dv) -- each row overlaps the next by half -- rounded >> (dh_l2 + dv_l2 + 1); the vertical
// position moves half a decimated row up (the offset (2 dv - 1) / 2 for (dv - 1) / 2), the
// taps clamp to [kmin, kmax - 1] (the last box inside the picture), and chroma -- fetched and
// boxed as before, unfiltered -- is read at the SECOND tap (the nearest row to the unshifted
// position). At the identity that is the (1, 2, 1) on the frame lines around each field
// line, the same kernel in both fields; two rows a line as without it.
//
// A store of fields (pic_field) holds them line-interleaved -- luma line y is field (y & 1)'s
// line y >> 1 -- and so does its chroma; at dv = 1 luma row y takes chroma row 2 (y >> 2) +
// (y & 1), its OWN field's; a frame store row y >> 1 (with dv > 1, row k >> 1: a scaled
// field store is shown woven -- the known limit, docs/analog.md §5).
//
// THE KERNEL (P5f) is kept for the identity fit (Progressive, steps 1.0, no decimation:
// 720x480, or the snapped 704x480 at its offset): on a store of fields, per channel,
//   Weave (mode 0, and 3)  b
//   Blend (mode 2)         (a + 2b + d + 1) >> 2     every line: half of each field, no comb
//   Bob   (mode 1)         keep field pic_parity: its lines b, the other field's (a + d + 1) >> 1
// on the rows above (a), at (b) and below (d) the line; a single field (pic_single) is
// bobbed on its own field in every mode. Edges MIRROR (a := d on the first row, d := a on
// the last). A frame store is b in every mode (H.264 says which pictures are fields). Blend's
// rounding is ffmpeg's `interlace` lowpass. The mode is latched at each refresh's first
// request, so a menu change never splits a picture.
//
// clk_vid (the raster, a dot per `ce`; clk_sys until hd_raster, docs/hd_raster.md S3): at the first dot of every line the NEXT raster line's rows are
// worked out (a few cycles: its frame line, the Q.16 row position, the two taps and the
// weight; at the identity also the kernel's a) and looked up in the four slots' tags; a row
// not held is given a slot -- never one the current line reads, never one the next line
// needs -- and the missing rows (at most two) go to clk_mem as one command (a toggle).
// A refresh's first request invalidates the tags (a new picture may be shown). At the
// identity this is exactly the old rule: row v + 2 fetched during line v, the window v - 1
// .. v + 1 held. A command not finished when its line begins is counted (fetch_late: past
// the fit's caps a line's rows can exceed the fetch budget -- visible, never silent).
// The read-out (hd_raster: nine stages, each an 81 MHz clock): stage 0 the column position
// (an accumulator of sx; every other dot at 480i) in decimated columns, stage 1 the taps
// clamped and the RAM words (each slot row copy banked by word parity, so a word and its
// successor are read at once), stage 2 the M10K's output register, stage 3 the bytes, stage 4
// the horizontal blend, stage 5 the vertical blend or the kernel, stage 6 C / D / E and the
// products, stage 7 the sums, stage 8 the clip -- LAT 9 dots from (h_pos, v_pos, de_in) to
// (r, g, b, de_out); vid_out delays sync and DE the same (check_emu_wiring reads this line):
//   R = (Kc C + Krv E + 128) >> 8, G = (Kc C - Kbg D - Krg E + 128) >> 8,
//   B = (Kc C + Kbb D + 128) >> 8     with C = Y - Yoff, D = Cb - 128, E = Cr - 128
// (0.16, docs/colour.md) the integers are the picture's colour code's -- BT.601 / 709 / 2020 x limited /
// full (tools/colour_ref.py derives them from Kr / Kb); code 1, BT.601 limited, is the 0.15 conversion
// (298, 409, 100, 208, 516, Yoff 16). The code is latched at a refresh's first request with the
// deinterlace mode, so a picture's colour never changes inside a refresh.
// clk_mem: each commanded decimated row into its slot -- per plane (Y 2W words a source
// row, Cb / Cr W), dv source rows, read bursts of up to 8 words; each beat's samples summed
// dh at a time into the word being built, the dv rows summed in an accumulator line (a
// read-modify-write per word, sequential addresses), the last row's sums rounded into the
// slot. Addresses (docs/h264_recon.md S2.2): base + store << 18; Cb at 32 W HF, Cr at
// 40 W HF; the coded size is a multiple of 16 and the factors at most 8, so no box
// straddles a picture edge.
//
// THE AREA PRE-FILTER (docs/analog.md §11b; fit_hpf / fit_vpf, published by disp_fit): per axis on
// the decimated grid, a code A 0..4 = weights (8 - A, A) in eighths over boxes / samples k, k + 1;
// anti-twitter's sliding rows above are vpf 4. Both in the fetch: vertically nb = 1 + (A > 0)
// boxes of dv luma rows, row i weighted (i < dv ? 8 - A : A) into the accumulator; horizontally
// at the slot write, sample m = (8 - A) V_m + A V_m+1 of the vertical sums (a word written when
// the next word's first lane is in; the row's last flushed after, its missing neighbour
// replicated -- never read); one rounding, (sum + 2^(s+5)) >> (s + 6). The read-out: positions
// A / 8 of a decimated sample up, taps clamped to kmax - (A > 0), chroma (unfiltered) at the tap
// nearest the UNSHIFTED position: w + 32 A >= 128 ? k1 : k0, vertically the slot by the same rule.
//
// No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none

// (hd_raster) no M10K shift registers: a delay chain on the dot inferred as altshift_taps put a RAM's
// slow clock-to-out on an 81 MHz path (the first stage-A fit)
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module disp_reader #(
    parameter logic [28:0] DPB_BASE = 29'h0600_0000
) (
    // the raster (clk_vid since hd_raster: docs/hd_raster.md S3) and its dot enable
    input  wire         clk,
    input  wire         ce,                // the dot: one clock in three on the 27 MHz rasters, every clock native
    input  wire         rst_n,
    input  wire         gradient_dither,    // asynchronous OSD level; synchronized and latched per frame below
    input  wire  [11:0] h_pos,
    input  wire  [11:0] v_pos,
    input  wire         de_in,
    // P6: the 480i raster -- a pixel is two dots (h_pos counts dots), v_pos the frame line of
    // the field being scanned
    input  wire         il,
    input  wire         prog240,           // progressive 240p/288p: two dots per pixel, half-height output
    input  wire         pal,               // P6 step 6: the 625-line raster (576 active; fields of 312 / 313)
    input  wire  [11:0] lines,             // (hdmi_raster stage 2) progressive: the current frame's active lines
    input  wire  [11:0] last_line,         // ... and its last line's index (sync_gen: 480 / 524, 576 / 624, native)
    input  wire         pic_valid,         // a picture has been decoded (quasi-static)
    input  wire  [4:0]  pic_store,         // its store
    input  wire         pic_field,         // the store holds fields (chroma rows per field)
    input  wire  [7:0]  pic_w_mbs,         // the CODED size
    input  wire  [7:0]  pic_hf_mbs,
    input  wire         pic_parity,        // the field to show (P5e; Bob keeps it)
    input  wire         pic_single,        // the store holds ONE field (bobbed in every mode)
    input  wire  [1:0]  deint_mode,        // 0 Weave, 1 Bob, 2 Blend, 3 Weave (the menu, status[4:3])
    input  wire  [2:0]  pic_colour,        // (0.16) the picture's colour code, 1..6 (docs/colour.md); 0 / 7 shown as 1
    input  wire  [5:0]  pic_siting,        // (docs/chroma.md) its chroma siting {bottom field, top field / frame}, each 0..5
    // the fit (h264/disp_fit.sv, quasi-static)
    input  wire  [12:0] fit_ow,
    input  wire  [12:0] fit_oh,
    input  wire  [13:0] fit_ox0,           // two's complement
    input  wire  [13:0] fit_oy0,
    input  wire  [27:0] fit_sx,            // Q.16
    input  wire  [27:0] fit_sy,
    input  wire  [1:0]  fit_dh_l2,
    input  wire  [1:0]  fit_dv_l2,
    input  wire  [11:0] fit_lx,            // the crop's origin
    input  wire  [11:0] fit_ty,
    input  wire  [11:0] fit_wc,            // the cropped size
    input  wire  [11:0] fit_hc,
    input  wire  [2:0]  fit_hpf,           // (§11b) the pre-filters: 0..4 (8 - A, A, 0), 5 (2, 4, 2);
    input  wire  [2:0]  fit_vpf,           // vpf 4 is also anti-twitter's sliding rows (docs/analog.md §9)
    // (1.2) the calibrated viewport clips the fitted picture at the raster input.
    input  wire         clip_enable,
    input  wire  [11:0] clip_x,
    input  wire  [11:0] clip_y,
    input  wire  [11:0] clip_w,
    input  wire  [11:0] clip_h,
    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b,
    output logic        de_out,            // the dot is inside the picture's rectangle
    output logic [15:0] fetch_late,        // lines whose rows were not all fetched in time

    // DDR3 reads (clk_mem): a read-only master (emu: DDRAM2, ram2)
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,
    // the judder gate's independent half (clk_mem): the (store, parity) changes this
    // reader FETCHED, refresh by refresh (captured with each refresh's first command) --
    // disp_ctl counts the ones it decided; over any span the two are equal (docs/display.md S7)
    output logic [31:0] fetch_changes
);

    wire prog240_i = (prog240 === 1'b1);    // older named-port benches may omit this optional mode

    // ---- the luma line slots: 4 x Y 256 words: 2,048 samples (hd_raster stage B, docs/hd_raster.md §5: the
    // native raster up to 2,048 wide -- the decoder's 128-MB side bound) ----
    // copy a plain (the kernel's row above), copies b and d each in two banks by word parity (a word and its
    // successor in one cycle: the horizontal taps). Simple dual-clock RAMs, one read port each (M10K).
    logic [63:0] ya_ram [0:1023];
    logic [63:0] ybe_ram [0:511];          // copy b, even words: {slot, word >> 1}
    logic [63:0] ybo_ram [0:511];
    logic [63:0] yde_ram [0:511];          // copy d
    logic [63:0] ydo_ram [0:511];
    // ---- (docs/chroma.md §3) the chroma line slots: 8 x (Cb, Cr 128 words: 1,024 samples), tagged by the
    // store's decimated chroma row, apart from luma's. Per plane two copies (the line's two chroma rows),
    // each in two banks by word parity: {slot, word >> 1}
    logic [63:0] cb0e_ram [0:511], cb0o_ram [0:511], cb1e_ram [0:511], cb1o_ram [0:511];
    logic [63:0] cr0e_ram [0:511], cr0o_ram [0:511], cr1e_ram [0:511], cr1o_ram [0:511];
    logic        lb_we_y, lb_we_cb, lb_we_cr;
    logic [2:0]  lb_slot;                  // luma: [1:0]; chroma: all three
    logic [7:0]  lb_word;
    logic [63:0] lb_wdata;
    always_ff @(posedge mclk) begin
        if (lb_we_y) begin
            ya_ram[{lb_slot[1:0], lb_word}] <= lb_wdata;
            if (!lb_word[0]) begin ybe_ram[{lb_slot[1:0], lb_word[7:1]}] <= lb_wdata; yde_ram[{lb_slot[1:0], lb_word[7:1]}] <= lb_wdata; end
            else             begin ybo_ram[{lb_slot[1:0], lb_word[7:1]}] <= lb_wdata; ydo_ram[{lb_slot[1:0], lb_word[7:1]}] <= lb_wdata; end
        end
        if (lb_we_cb) begin
            if (!lb_word[0]) begin cb0e_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; cb1e_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; end
            else             begin cb0o_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; cb1o_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; end
        end
        if (lb_we_cr) begin
            if (!lb_word[0]) begin cr0e_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; cr1e_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; end
            else             begin cr0o_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; cr1o_ram[{lb_slot, lb_word[6:1]}] <= lb_wdata; end
        end
    end

    // =========================================================================================
    // clk_vid (clk_sys until hd_raster): the line control
    // =========================================================================================
    // (hd_raster) the fit as local registers: the inputs are the raster bundle's copies, across the
    // chip; everything on clk_vid reads these (the clk_mem side captures the inputs themselves)
    logic [12:0] r_ow, r_oh;
    logic [13:0] r_ox0, r_oy0;
    logic [27:0] r_sx, r_sy;
    logic [1:0]  r_dh, r_dv;
    logic [11:0] r_lx, r_ty, r_wc, r_hc;
    logic [2:0]  r_hpf, r_vpf;
    logic        r_clip_enable;
    logic [11:0] r_clip_x, r_clip_y, r_clip_w, r_clip_h;
    logic [11:0] kmin_x, kmax_x, ty_d, tyh_d;   // the crop's bounds in decimated columns / rows
    // (docs/chroma.md §2) the crop's chroma bounds: decimated chroma columns; rows -- a frame's decimated
    // chroma rows, or a store of fields at dv = 1 its field chroma rows (the store's rows 2 k + p)
    logic [11:0] ckmin_x, ckmax_x, cymin, cymax;
    wire         cfield = pic_field && (r_dv == 2'd0);
    logic signed [44:0] c_sy;                  // sy / 2 - 1/2, the row position's constant part
    logic [43:0] c_vo;                         // (§11b) the rows' offset: ((dv - 1) / 2 + dv S_v / 8) << 16
    logic [24:0] c_ho;                         // ... the columns': dh S_h / 8 << 16 (into pos0)
    // (§11b) each code's centre offset A (eighths) and its extra box (A > 0)
    wire  [3:0]  sh_h = {1'b0, r_hpf};
    wire  [3:0]  sh_v = {1'b0, r_vpf};
    wire  [1:0]  nx_h = {1'b0, r_hpf != 3'd0};
    wire  [1:0]  nx_v = {1'b0, r_vpf != 3'd0};
    always_ff @(posedge clk) if (ce) begin
        r_ow <= fit_ow; r_oh <= fit_oh; r_ox0 <= fit_ox0; r_oy0 <= fit_oy0; r_sx <= fit_sx; r_sy <= fit_sy;
        r_dh <= fit_dh_l2; r_dv <= fit_dv_l2; r_lx <= fit_lx; r_ty <= fit_ty; r_wc <= fit_wc; r_hc <= fit_hc;
        r_hpf <= fit_hpf; r_vpf <= fit_vpf;
        kmin_x <= r_lx >> r_dh;
        kmax_x <= ((r_lx + r_wc - 12'd1) >> r_dh) - {10'd0, nx_h};
        ty_d   <= r_ty >> r_dv;
        tyh_d  <= (r_ty + r_hc - 12'd1) >> r_dv;
        c_sy   <= $signed({18'd0, r_sy[27:1]}) - 45'sd32768;
        c_vo   <= ({40'd0, (4'd1 << r_dv) - 4'd1} << 15) + ({40'd0, sh_v} << (5'd13 + {3'd0, r_dv}));
        c_ho   <= {21'd0, sh_h} << (5'd13 + {3'd0, r_dh});
        ckmin_x <= r_lx >> ({1'b0, r_dh} + 3'd1);
        ckmax_x <= ((({1'b0, r_lx} + {1'b0, r_wc}) >> 1) - 13'd1) >> r_dh;
        cymin   <= cfield ? (r_ty >> 2) : (r_ty >> ({1'b0, r_dv} + 3'd1));
        cymax   <= cfield ? ((({1'b0, r_ty} + {1'b0, r_hc}) >> 2) - 13'd1)
                          : ((({1'b0, r_ty} + {1'b0, r_hc}) >> 1) - 13'd1) >> r_dv;
    end
    // Keep the viewport on the same CE edge as the fit registers above. The fit and its
    // clip viewport crossed from clk_sys together; this local capture prevents a one-CE
    // frame fragment from combining the new clip with the previous fit.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_clip_enable <= 1'b0; r_clip_x <= '0; r_clip_y <= '0; r_clip_w <= '0; r_clip_h <= '0;
        end else if (ce) begin
            r_clip_enable <= clip_enable; r_clip_x <= clip_x; r_clip_y <= clip_y;
            r_clip_w <= clip_w; r_clip_h <= clip_h;
        end
    end
    // the kernel's predicate: the identity fit on the progressive raster
    wire         ident = !il && (r_sx == 28'h001_0000) && (r_sy == 28'h001_0000) &&
                         (r_dh == 2'd0) && (r_dv == 2'd0);
    wire         kern_ok_now = ident && pic_field;   // the kernel applies (a store of fields at the identity)
    // the next raster line's frame line: Progressive v + 1 (524 -> 0; 624 at 50 Hz); 480i the
    // field's next line v + 2, and after a field's last line (the even field has 263, the odd
    // 262; 313 / 312 at 576i) the other field's first
    wire  [10:0] fl = v_pos[11:1];
    wire         il_last = v_pos[0] ? (fl == (pal ? 11'd311 : 11'd261)) : (fl == (pal ? 11'd312 : 11'd262));
    wire  [11:0] nxt_line = il ? (il_last ? {11'd0, ~v_pos[0]} : v_pos + 12'd2)
                               : prog240_i ? ((v_pos == last_line) ? 12'd0 : {v_pos[10:0] + 11'd1, 1'b0})
                                         : ((v_pos == last_line) ? 12'd0 : v_pos + 12'd1);
    // the tag table: the decimated row each slot holds
    logic [11:0] tag  [0:3];
    logic [3:0]  tag_v;
    // the command to clk_mem (held from one issue to the next)
    logic        cmd_tog;
    logic [1:0]  cmd_n;                    // rows to fetch (0..2)
    logic [11:0] cmd_row0, cmd_row1;
    logic [1:0]  cmd_slot0, cmd_slot1;
    logic        cmd_first;                // a refresh's first line (fetch_changes)
    logic [1:0]  k_mode;                   // the deinterlace mode, latched at a refresh's first request
    logic [2:0]  k_col;                    // (0.16) the colour code, latched with it
    logic [5:0]  k_sit;                    // (docs/chroma.md) the chroma siting {bottom, top}, latched with it
    // the current line's read-out parameters, and the next line's being prepared
    logic [1:0]  cur_sa, cur_sb, cur_sd;   // luma slots: kernel a / tap row b (k) / d (k + 1)
    logic [7:0]  cur_wy;
    logic        cur_in, cur_kern_ok, cur_par;
    logic [1:0]  nx_sa, nx_sb, nx_sd;
    logic [7:0]  nx_wy;
    logic        nx_in, nx_par;
    // (chroma.md §3) the line's chroma: its two rows' slots, the row weight, the horizontal siting (centred)
    logic [2:0]  cur_cs0, cur_cs1, nx_cs0, nx_cs1;
    logic [7:0]  cur_wcy, nx_wcy;
    logic        cur_chs, nx_chs;
    // ... the chroma tags (the store's decimated chroma row each chroma slot holds) and the command's chroma rows
    logic [11:0] ctag [0:7];
    logic [7:0]  ctag_v;
    logic [1:0]  ccmd_n;
    logic [11:0] ccmd_row0, ccmd_row1;
    logic [2:0]  ccmd_slot0, ccmd_slot1;
    // ... the sequencer's chroma: the row position (Q.16) in the frame's or the field's chroma rows
    logic signed [43:0] c_a, c_b, c_u;
    logic        c_cp, c_hs;               // the field p (a store of fields), the centred horizontal siting
    logic [16:0] c_voff;                   // the vertical siting's offset (Q.16: 0, 1/2, 1 luma row)
    wire  [17:0] c_vfs = {1'b0, c_voff} + {1'b0, c_cp, 16'd0};
    wire  [16:0] c_vf  = c_vfs[17:1];      // a field's: (voff + p) / 2 of its own line pair (0 .. 1)
    logic [11:0] c_k0, c_k1, c_r0, c_r1;
    logic [7:0]  c_w;
    logic        ch0, ch1;
    logic [2:0]  cs0, cs1, cal0, cal1;
    logic [7:0]  cprot, cal_skip;
    logic [7:0]  clt [0:7];                // clt[i][j]: ctag i < ctag j (registered with the protection)
    // the sequencer, from the first dot of each line (hd_raster: 15 steps -- the row position's
    // product in two halves and its sums one a step, so each fits an 81 MHz clock)
    logic [3:0]  lseq;
    logic        ln_first, ln_act;
    logic [11:0] ln_line;
    logic signed [14:0] ln_l;              // the frame line within the rectangle
    logic signed [43:0] ln_pa, ln_pb, ln_prod, ln_pt, ln_pos, ln_um;
    logic signed [31:0] ln_u;
    logic signed [19:0] ln_k;
    logic [11:0] ln_k0, ln_k1, ln_ra, ln_rd;
    logic [7:0]  ln_w;
    logic [11:0] kmin_y, kmax_y;
    logic [1:0]  s_b, s_d, s_a;
    logic        h_b, h_d, h_a;
    logic [1:0]  al0, al1;
    logic [3:0]  lt [0:3];                 // lt[i][j]: tag i < tag j (registered with the protection)
    logic        cmd_done_s1, cmd_done_s2, cmd_done_s3;
    logic        done_tog;                 // clk_mem
    wire         cmd_pending = (cmd_done_s2 != cmd_tog);

    // tag lookups (combinational over the four slots)
    logic        lk_b_h, lk_d_h, lk_a_h;
    logic [1:0]  lk_b_s, lk_d_s, lk_a_s;
    always_comb begin
        lk_b_h = 1'b0; lk_d_h = 1'b0; lk_a_h = 1'b0; lk_b_s = 2'd0; lk_d_s = 2'd0; lk_a_s = 2'd0;
        for (int i = 3; i >= 0; i--) begin
            if (tag_v[i] && tag[i] == ln_k0) begin lk_b_h = 1'b1; lk_b_s = i[1:0]; end
            if (tag_v[i] && tag[i] == ln_rd) begin lk_d_h = 1'b1; lk_d_s = i[1:0]; end
            if (tag_v[i] && tag[i] == ln_ra) begin lk_a_h = 1'b1; lk_a_s = i[1:0]; end
        end
    end
    // allocation: a slot the current line does not read and the next line does not need
    // (held), invalid first, else the lowest row; `al_skip` excludes a slot just allocated.
    // (Rows only increase within a refresh, so the lowest-row victim is never one in use: the
    // protection is a guard for any other policy -- its removal is an equivalent mutant.)
    // The rows' order comes from lt, registered a step earlier (the tags do not change between).
    logic [3:0]  prot;
    logic [1:0]  al_pick;
    logic        al_ok;
    logic [3:0]  al_skip;
    always_comb begin
        al_ok = 1'b0; al_pick = 2'd0;
        for (int i = 3; i >= 0; i--)
            if (!prot[i] && !al_skip[i] && !tag_v[i]) begin al_ok = 1'b1; al_pick = i[1:0]; end
        if (!al_ok)
            for (int i = 3; i >= 0; i--)
                if (!prot[i] && !al_skip[i] && (!al_ok || lt[i][al_pick])) begin al_ok = 1'b1; al_pick = i[1:0]; end
    end
    // (docs/chroma.md §3) the chroma slots: lookups of the line's two rows, and the allocation as luma's --
    // invalid and unprotected first, else the lowest row (rows only increase within a refresh, per field)
    logic        clk0_h, clk1_h;
    logic [2:0]  clk0_s, clk1_s;
    always_comb begin
        clk0_h = 1'b0; clk1_h = 1'b0; clk0_s = 3'd0; clk1_s = 3'd0;
        for (int i = 7; i >= 0; i--) begin
            if (ctag_v[i] && ctag[i] == c_r0) begin clk0_h = 1'b1; clk0_s = i[2:0]; end
            if (ctag_v[i] && ctag[i] == c_r1) begin clk1_h = 1'b1; clk1_s = i[2:0]; end
        end
    end
    // (chroma.md §2) the line's chroma field and siting, from the UNSHIFTED row position ln_pos (step 6):
    // a store of fields at dv = 1 takes the field of the row nearest it -- or, on Bob's rebuilt line
    // (the identity's kernel, the other field's parity), the kept field; that field's siting type
    // (the bottom's for field 1), else the frame's (the top's)
    wire signed [43:0] ln_posr = ln_pos + 44'sd32768;
    wire         c_pn   = ln_posr[16];
    wire         c_bob  = ident && pic_field && (pic_single || k_mode == 2'd1) && (c_pn != pic_parity);
    wire         c_cpn  = c_bob ? pic_parity : c_pn;
    wire  [2:0]  c_typ  = (cfield && c_cpn) ? k_sit[5:3] : k_sit[2:0];
    wire  [16:0] c_vofn = (c_typ <= 3'd1) ? 17'h08000 : (c_typ <= 3'd3) ? 17'h00000 : 17'h10000;
    wire signed [27:0] c_kw = c_u[43:16];
    wire         c_below = c_kw < $signed({16'd0, cymin});
    logic [2:0]  cal_pick;
    logic        cal_ok;
    // (in parallel, not luma's running minimum: over eight slots that loop chained eight compares -- clk_vid's
    // worst path in the first fit, 62.5 MHz. A candidate is the victim when no other candidate holds a lower
    // row; one level of terms, then the lowest index)
    wire  [7:0]  ccand = ~cprot & ~cal_skip;
    wire  [7:0]  cinv  = ccand & ~ctag_v;
    logic [7:0]  cmin_v;
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            cmin_v[i] = ccand[i];
            for (int j = 0; j < 8; j++)
                if (j != i && ccand[j] && clt[j][i]) cmin_v[i] = 1'b0;
        end
    end
    wire  [7:0]  cpool = (cinv != 8'd0) ? cinv : cmin_v;
    always_comb begin
        cal_ok = (ccand != 8'd0); cal_pick = 3'd0;
        for (int i = 7; i >= 0; i--) if (cpool[i]) cal_pick = i[2:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 4; i++) begin tag[i] <= '0; lt[i] <= '0; end
            tag_v <= '0; cmd_tog <= 1'b0; cmd_n <= '0; cmd_row0 <= '0; cmd_row1 <= '0;
            cmd_slot0 <= '0; cmd_slot1 <= '0; cmd_first <= 1'b0; k_mode <= 2'd0; k_col <= 3'd1;
            cur_sa <= '0; cur_sb <= '0; cur_sd <= '0; cur_wy <= '0; cur_in <= 1'b0;
            cur_kern_ok <= 1'b0;
            nx_sa <= '0; nx_sb <= '0; nx_sd <= '0; nx_wy <= '0; nx_in <= 1'b0;
            k_sit <= '0;
            cur_cs0 <= '0; cur_cs1 <= '0; nx_cs0 <= '0; nx_cs1 <= '0; cur_wcy <= '0; nx_wcy <= '0;
            cur_chs <= 1'b0; nx_chs <= 1'b0;
            for (int i = 0; i < 8; i++) begin ctag[i] <= '0; clt[i] <= '0; end
            ctag_v <= '0; ccmd_n <= '0; ccmd_row0 <= '0; ccmd_row1 <= '0; ccmd_slot0 <= '0; ccmd_slot1 <= '0;
            c_a <= '0; c_b <= '0; c_u <= '0; c_cp <= 1'b0; c_hs <= 1'b0; c_voff <= '0;
            c_k0 <= '0; c_k1 <= '0; c_r0 <= '0; c_r1 <= '0; c_w <= '0;
            ch0 <= 1'b0; ch1 <= 1'b0; cs0 <= '0; cs1 <= '0; cal0 <= '0; cal1 <= '0; cprot <= '0; cal_skip <= '0;
            lseq <= '0; ln_first <= 1'b0; ln_act <= 1'b0; ln_line <= '0; ln_l <= '0;
            ln_pa <= '0; ln_pb <= '0; ln_prod <= '0; ln_pt <= '0; ln_pos <= '0; ln_um <= '0;
            ln_u <= '0; ln_k <= '0; ln_k0 <= '0; ln_k1 <= '0; ln_ra <= '0; ln_rd <= '0; ln_w <= '0;
            kmin_y <= '0; kmax_y <= '0; cur_par <= 1'b0; nx_par <= 1'b0;
            s_b <= '0; s_d <= '0; s_a <= '0; h_b <= 1'b0; h_d <= 1'b0; h_a <= 1'b0;
            al0 <= '0; al1 <= '0; prot <= '0; al_skip <= '0;
            cmd_done_s1 <= 1'b0; cmd_done_s2 <= 1'b0; cmd_done_s3 <= 1'b0; fetch_late <= '0;
        end else begin
            cmd_done_s1 <= done_tog; cmd_done_s2 <= cmd_done_s1; cmd_done_s3 <= cmd_done_s2;
            if (!ce) ;                     // (hd_raster) the line control advances a dot at a time
            else if (h_pos == 12'd0) begin
                // this line's parameters (prepared during the previous line)
                cur_sa <= nx_sa; cur_sb <= nx_sb; cur_sd <= nx_sd; cur_wy <= nx_wy;
                cur_in <= nx_in; cur_kern_ok <= kern_ok_now; cur_par <= nx_par;
                cur_cs0 <= nx_cs0; cur_cs1 <= nx_cs1; cur_wcy <= nx_wcy; cur_chs <= nx_chs;
                // its rows were commanded during the previous line: counted if not all in
                if (nx_in && cmd_pending && fetch_late != 16'hFFFF) fetch_late <= fetch_late + 16'd1;
                // the next line's work
                ln_line <= nxt_line;
                ln_first <= (nxt_line == 12'd0) || (il && nxt_line == 12'd1);
                ln_act <= pic_valid && (nxt_line < (il ? (pal ? 12'd576 : 12'd480) : lines));
                lseq <= 4'd1;
            end else begin
                case (lseq)
                    4'd1: begin
                        ln_l <= $signed({3'd0, ln_line}) - $signed({r_oy0[13], r_oy0});
                        // (§11b / anti-twitter: the last pre-filtered row inside the picture is nb - 1 up)
                        kmin_y <= ty_d; kmax_y <= tyh_d - {10'd0, nx_v};
                        if (ln_first) begin tag_v <= '0; ctag_v <= '0; k_mode <= deint_mode; k_col <= pic_colour; k_sit <= pic_siting; end
                        lseq <= 4'd2;
                    end
                    4'd2: begin
                        // l sy, in two halves of sy
                        ln_pa <= ln_l * $signed({1'b0, r_sy[13:0]});
                        ln_pb <= ln_l * $signed({1'b0, r_sy[27:14]});
                        lseq <= 4'd3;
                    end
                    4'd3: begin
                        ln_prod <= ln_pa + (ln_pb <<< 14);
                        lseq <= 4'd4;
                    end
                    4'd4: begin
                        ln_pt <= $signed({16'd0, r_ty, 16'd0}) + ln_prod;
                        lseq <= 4'd5;
                    end
                    4'd5: begin
                        ln_pos <= ln_pt + c_sy[43:0];
                        lseq <= 4'd6;
                    end
                    4'd6: begin
                        // (p - ((dv - 1) << 15) - (dv S_v << 13)) >>> dv_l2: the pre-filtered row k
                        // is centred S_v / 8 lower (§11b; anti-twitter's S_v = 4: the old (2 dv - 1)
                        // << 15) -- the offset here, the shift next
                        ln_um <= ln_pos - $signed(c_vo);
                        // (chroma.md §2) chroma: a field's own rows, (Y - p) / 2; a frame's, less (dv - 1)
                        c_a <= cfield ? (ln_pos - (c_cpn ? 44'sd65536 : 44'sd0))
                                      : (ln_pos - $signed({24'd0, (4'd1 << r_dv) - 4'd1, 16'd0}));
                        c_cp <= c_cpn; c_voff <= c_vofn; c_hs <= c_typ[0];
                        lseq <= 4'd7;
                    end
                    4'd7: begin
                        case (r_dv)
                            2'd0: ln_u <= ln_um[31:0];
                            2'd1: ln_u <= ln_um >>> 1;
                            2'd2: ln_u <= ln_um >>> 2;
                            default: ln_u <= ln_um >>> 3;
                        endcase
                        // ... less the siting's offset (a field's rows halved first; a field's offset is
                        // (voff + p) / 2 of its own line pair -- Figure E-1's field siting, chroma.md §2)
                        c_b <= cfield ? ((c_a >>> 1) - $signed({27'd0, c_vf})) : (c_a - $signed({27'd0, c_voff}));
                        lseq <= 4'd8;
                    end
                    4'd8: begin
                        ln_k <= ln_u >>> 16;
                        ln_w <= ln_u[15:8];
                        // ... the decimated chroma row position: a field's / 2, a frame's / (2 dv)
                        if (cfield) c_u <= c_b >>> 1;
                        else case (r_dv)
                            2'd0: c_u <= c_b >>> 1;
                            2'd1: c_u <= c_b >>> 2;
                            2'd2: c_u <= c_b >>> 3;
                            default: c_u <= c_b >>> 4;
                        endcase
                        lseq <= 4'd9;
                    end
                    4'd9: begin
                        // the taps, clamped to the crop; the weight 0 above it
                        ln_k0 <= ($signed(ln_k) < $signed({8'd0, kmin_y})) ? kmin_y :
                                 ($signed(ln_k) > $signed({8'd0, kmax_y})) ? kmax_y : ln_k[11:0];
                        ln_rd <= ($signed(ln_k) + 20'sd1 < $signed({8'd0, kmin_y})) ? kmin_y :
                                 ($signed(ln_k) + 20'sd1 > $signed({8'd0, kmax_y})) ? kmax_y : ln_k[11:0] + 12'd1;
                        if ($signed(ln_k) < $signed({8'd0, kmin_y})) ln_w <= 8'd0;
                        // ... chroma's taps, clamped to the crop's chroma rows; the weight 0 above it
                        c_k0 <= c_below ? cymin : (c_kw > $signed({16'd0, cymax})) ? cymax : c_kw[11:0];
                        c_k1 <= c_below ? cymin : (c_kw + 28'sd1 > $signed({16'd0, cymax})) ? cymax : c_kw[11:0] + 12'd1;
                        c_w  <= c_below ? 8'd0 : c_u[15:8];
                        lseq <= 4'd10;
                    end
                    4'd10: begin
                        // the kernel's rows at the identity: a = k - 1 (k + 1 at the first
                        // row), d = k + 1 (k - 1 at the last); else a = k, d the second tap
                        if (ident) begin
                            ln_ra <= (ln_k0 == kmin_y) ? ((ln_k0 == kmax_y) ? ln_k0 : ln_k0 + 12'd1) : ln_k0 - 12'd1;
                            ln_rd <= (ln_k0 == kmax_y) ? ((ln_k0 == kmin_y) ? ln_k0 : ln_k0 - 12'd1) : ln_k0 + 12'd1;
                        end else ln_ra <= ln_k0;
                        // ... the store's chroma rows: a field's 2 k + p, a frame's k
                        c_r0 <= cfield ? {c_k0[10:0], c_cp} : c_k0;
                        c_r1 <= cfield ? {c_k1[10:0], c_cp} : c_k1;
                        lseq <= 4'd11;
                    end
                    4'd11: begin
                        // lookups; protect the current line's slots and the next line's held rows;
                        // the rows' order for the allocation
                        h_b <= lk_b_h; s_b <= lk_b_s; h_d <= lk_d_h; s_d <= lk_d_s; h_a <= lk_a_h; s_a <= lk_a_s;
                        prot <= (cur_in ? ((4'b1 << cur_sa) | (4'b1 << cur_sb) | (4'b1 << cur_sd)) : 4'b0) |
                                (lk_b_h ? (4'b1 << lk_b_s) : 4'b0) | (lk_d_h ? (4'b1 << lk_d_s) : 4'b0) |
                                (lk_a_h ? (4'b1 << lk_a_s) : 4'b0);
                        for (int i = 0; i < 4; i++)
                            for (int j = 0; j < 4; j++) lt[i][j] <= (tag[i] < tag[j]);
                        al_skip <= '0;
                        // (chroma.md §3) chroma likewise: its two rows' lookups, the current line's two slots
                        // and the next line's held rows protected, the rows' order
                        ch0 <= clk0_h; cs0 <= clk0_s; ch1 <= clk1_h; cs1 <= clk1_s;
                        cprot <= (cur_in ? ((8'd1 << cur_cs0) | (8'd1 << cur_cs1)) : 8'd0) |
                                 (clk0_h ? (8'd1 << clk0_s) : 8'd0) | (clk1_h ? (8'd1 << clk1_s) : 8'd0);
                        for (int i = 0; i < 8; i++)
                            for (int j = 0; j < 8; j++) clt[i][j] <= (ctag[i] < ctag[j]);
                        cal_skip <= '0;
                        lseq <= 4'd12;
                    end
                    4'd12: begin
                        // the first missing row's slot
                        al0 <= al_pick; al_skip <= 4'b1 << al_pick;
                        cal0 <= cal_pick; cal_skip <= 8'd1 << cal_pick;
                        lseq <= 4'd13;
                    end
                    4'd13: begin
                        al1 <= al_pick;
                        cal1 <= cal_pick;
                        lseq <= 4'd14;
                    end
                    4'd14: begin
                        // the missing rows: b first, then d, then a (distinct rows only)
                        if (!ln_act || ln_l < 15'sd0 || ln_l >= $signed({2'd0, r_oh})) begin
                            nx_in <= 1'b0;
                        end else begin
                            // which rows are missing, in order, and their slots
                            if (!h_b) begin
                                cmd_row0 <= ln_k0; cmd_slot0 <= al0; tag[al0] <= ln_k0; tag_v[al0] <= 1'b1; s_b <= al0;
                                if (!h_d && ln_rd != ln_k0) begin
                                    cmd_row1 <= ln_rd; cmd_slot1 <= al1; tag[al1] <= ln_rd; tag_v[al1] <= 1'b1;
                                    cmd_n <= 2'd2;
                                end else if (!h_a && ln_ra != ln_k0 && ln_ra != ln_rd) begin
                                    cmd_row1 <= ln_ra; cmd_slot1 <= al1; tag[al1] <= ln_ra; tag_v[al1] <= 1'b1;
                                    cmd_n <= 2'd2;
                                end else cmd_n <= 2'd1;
                            end else if (!h_d && ln_rd != ln_k0) begin
                                cmd_row0 <= ln_rd; cmd_slot0 <= al0; tag[al0] <= ln_rd; tag_v[al0] <= 1'b1;
                                if (!h_a && ln_ra != ln_k0 && ln_ra != ln_rd) begin
                                    cmd_row1 <= ln_ra; cmd_slot1 <= al1; tag[al1] <= ln_ra; tag_v[al1] <= 1'b1;
                                    cmd_n <= 2'd2;
                                end else cmd_n <= 2'd1;
                            end else if (!h_a && ln_ra != ln_k0 && ln_ra != ln_rd) begin
                                cmd_row0 <= ln_ra; cmd_slot0 <= al0; tag[al0] <= ln_ra; tag_v[al0] <= 1'b1;
                                cmd_n <= 2'd1;
                            end else cmd_n <= 2'd0;
                            // (chroma.md §3) the missing chroma rows (distinct only), beside the luma rows
                            if (!ch0) begin
                                ccmd_row0 <= c_r0; ccmd_slot0 <= cal0; ctag[cal0] <= c_r0; ctag_v[cal0] <= 1'b1;
                                if (!ch1 && c_r1 != c_r0) begin
                                    ccmd_row1 <= c_r1; ccmd_slot1 <= cal1; ctag[cal1] <= c_r1; ctag_v[cal1] <= 1'b1;
                                    ccmd_n <= 2'd2;
                                end else ccmd_n <= 2'd1;
                            end else if (!ch1 && c_r1 != c_r0) begin
                                ccmd_row0 <= c_r1; ccmd_slot0 <= cal0; ctag[cal0] <= c_r1; ctag_v[cal0] <= 1'b1;
                                ccmd_n <= 2'd1;
                            end else ccmd_n <= 2'd0;
                            cmd_first <= ln_first;
                            cmd_tog <= !cmd_tog;
                            nx_in <= 1'b1;
                        end
                        // (a refresh's first line counts its fetch changes even when it shows
                        // nothing: an empty command carries the flag)
                        if (ln_first && !(ln_act && ln_l >= 15'sd0 && ln_l < $signed({2'd0, r_oh}))) begin
                            cmd_n <= 2'd0; ccmd_n <= 2'd0; cmd_first <= 1'b1; cmd_tog <= !cmd_tog;
                        end
                        nx_wy <= ln_w; nx_par <= ln_k0[0];
                        nx_wcy <= c_w; nx_chs <= c_hs;
                        lseq <= 4'd15;
                    end
                    4'd15: begin
                        // the next line's slots: every row it needs is tagged now (the tags
                        // written in the last state), so a second lookup finds them
                        nx_sb <= lk_b_s; nx_sd <= lk_d_s; nx_sa <= lk_a_s;
                        nx_cs0 <= clk0_s; nx_cs1 <= clk1_s;   // (chroma.md §3) its chroma rows' slots
                        lseq <= 4'd0;
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================================
    // clk_vid: the read-out, LAT 9 dots (hd_raster: was 5 at 27 MHz -- each stage now fits an 81 MHz
    // clock, docs/hd_raster.md S12: the position apart from the address, the M10K's own output
    // register, the byte select apart from the horizontal blend, the vertical blend apart from the
    // colour products, the sums apart from the clip)
    // =========================================================================================
    // the column position: pos0 = lx << 16 + (0 - ox0) sx + sx / 2 - 1/2 (Q.16, the rectangle's
    // pixel -ox0 at raster x 0), a per-picture constant registered continuously (its product in two
    // halves); then + sx per pixel (every other dot at 480i)
    logic signed [44:0] pos0_a, pos0_b, pos0_p, pos0_c, pos0;
    logic signed [44:0] xacc;
    logic signed [14:0] nox;
    always_ff @(posedge clk) if (ce) begin
        nox    <= $signed(15'sd0) - $signed({r_ox0[13], r_ox0});
        pos0_a <= nox * $signed({1'b0, r_sx[13:0]});
        pos0_b <= nox * $signed({1'b0, r_sx[27:14]});
        pos0_p <= pos0_a + (pos0_b <<< 14);
        pos0_c <= $signed({17'd0, r_lx, 16'd0}) + $signed({18'd0, r_sx[27:1]}) - 45'sd32768 - $signed({20'd0, c_ho});
        pos0   <= pos0_c + pos0_p;
    end
    wire         px0 = (h_pos == 12'd0) || ((il || prog240_i) && h_pos == 12'd1);
    wire signed [44:0] px_pos = px0 ? pos0 : xacc;
    always_ff @(posedge clk) if (ce) begin
        if (h_pos == 12'd0) xacc <= pos0 + $signed({17'd0, r_sx});
        else if (!(il || prog240_i) || (h_pos[0] && h_pos != 12'd1)) xacc <= xacc + $signed({17'd0, r_sx});
    end
    // (docs/chroma.md §2) the chroma column: the UNSHIFTED luma position (pos0 + the Area filter's c_ho)
    // less (dh - 1) and the line's horizontal siting (co-sited 0, centred 1/2), a start per siting; the
    // same + sx a pixel in its own accumulator (no subtract in front of the RAM address); over 2 dh below
    logic signed [44:0] pos0c0, pos0c1, cxacc;
    always_ff @(posedge clk) if (ce) begin
        pos0c0 <= pos0 + $signed({20'd0, c_ho}) - $signed({25'd0, (4'd1 << r_dh) - 4'd1, 16'd0});
        pos0c1 <= pos0c0 - 45'sd32768;
    end
    // at dot 0 the line's parameters are being registered: read with the prepared ones
    wire         dot0 = (h_pos == 12'd0);
    wire  [1:0]  e_sa = dot0 ? nx_sa : cur_sa, e_sb = dot0 ? nx_sb : cur_sb, e_sd = dot0 ? nx_sd : cur_sd;
    wire  [2:0]  e_cs0 = dot0 ? nx_cs0 : cur_cs0, e_cs1 = dot0 ? nx_cs1 : cur_cs1;   // (chroma.md) the line's chroma
    wire  [7:0]  e_wcy = dot0 ? nx_wcy : cur_wcy;
    wire         e_chs = dot0 ? nx_chs : cur_chs;
    wire  signed [44:0] p0c = e_chs ? pos0c1 : pos0c0;
    wire  signed [44:0] px_c = px0 ? p0c : cxacc;
    always_ff @(posedge clk) if (ce) begin
        if (h_pos == 12'd0) cxacc <= p0c + $signed({17'd0, r_sx});
        else if (!(il || prog240_i) || (h_pos[0] && h_pos != 12'd1)) cxacc <= cxacc + $signed({17'd0, r_sx});
    end
    wire  [7:0]  e_wy = dot0 ? nx_wy : cur_wy;
    wire         e_in = dot0 ? nx_in : cur_in;
    wire         e_ko = dot0 ? kern_ok_now : cur_kern_ok;
    wire         e_par = dot0 ? nx_par : cur_par;
    // stage 0: the position in decimated columns, the raster column, this line's parameters
    logic signed [44:0] px_u;
    always_comb begin
        case (r_dh)
            2'd0: px_u = px_pos;
            2'd1: px_u = (px_pos - 45'sd32768) >>> 1;
            2'd2: px_u = (px_pos - 45'sd98304) >>> 2;
            default: px_u = (px_pos - 45'sd229376) >>> 3;
        endcase
    end
    logic signed [44:0] px_cu;               // (chroma.md) the decimated chroma column: / (2 dh)
    always_comb begin
        case (r_dh)
            2'd0: px_cu = px_c >>> 1;
            2'd1: px_cu = px_c >>> 2;
            2'd2: px_cu = px_c >>> 3;
            default: px_cu = px_c >>> 4;
        endcase
    end
    // the raster column (the rectangle's bounds are in pixels)
    wire  [10:0] x = (il || prog240_i) ? {1'b0, h_pos[10:1]} : h_pos[10:0];    // (hd_raster: up to 2,048 native)
    wire signed [14:0] rect_x_end = $signed({r_ox0[13], r_ox0}) + $signed({2'b0, r_ow});
    wire         in_x = ($signed({4'd0, x}) >= $signed({r_ox0[13], r_ox0})) &&
                        ($signed({4'd0, x}) < rect_x_end);
    wire         in_clip_x = !r_clip_enable || (x >= r_clip_x && x < r_clip_x + r_clip_w);
    wire [11:0]  raster_y = prog240_i ? {v_pos[10:0], 1'b0} : v_pos;
    wire         in_clip_y = !r_clip_enable || (raster_y >= r_clip_y && raster_y < r_clip_y + r_clip_h);
    // this line's kernel: 0 b, 1 the bob's rebuilt line (a + d + 1) >> 1, 2 the blend
    wire         bob  = pic_field && (pic_single || k_mode == 2'd1);
    // (the row's parity: at the identity the source row, v_pos's own less the crop's offset)
    wire  [1:0]  kern = !e_ko ? 2'd0 :
                        bob ? ((e_par == pic_parity) ? 2'd0 : 2'd1) :
                        (k_mode == 2'd2) ? 2'd2 : 2'd0;
    // Dither only the final RGB precision reduction, before analog conversion.
    // Same threshold for R/G/B preserves neutral grays. Stable frame coordinates
    // avoid field-to-field pattern inversion. Two-dot pixels share a threshold.
    `include "rgb_dither.svh"
    (* async_reg = "true" *) logic gd_sync1, gd_sync2;
    logic gd_frame;
    logic [7:0] gd_pipe [0:6];
    integer gd_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gd_sync1 <= 1'b0; gd_sync2 <= 1'b0; gd_frame <= 1'b0;
            for (gd_i = 0; gd_i < 7; gd_i = gd_i + 1) gd_pipe[gd_i] <= 8'd128;
        end else begin
            gd_sync1 <= gradient_dither; gd_sync2 <= gd_sync1;
            if (ce) begin
                if (h_pos == 0 && v_pos == 0) gd_frame <= gd_sync2;
                gd_pipe[0] <= gd_frame ? rgb_dither_rank(x[3:0], v_pos[3:0]) : 8'd128;
                for (gd_i = 1; gd_i < 7; gd_i = gd_i + 1) gd_pipe[gd_i] <= gd_pipe[gd_i-1];
            end
        end
    end
    logic signed [28:0] s0_k;
    logic [7:0]  s0_f, s0_wy;
    logic [1:0]  s0_sa, s0_sb, s0_sd, s0_kern;
    logic        s0_in, s0_ko;
    logic signed [28:0] s0_ck;               // (chroma.md) the chroma column, its weight, the line's slots / row weight
    logic [7:0]  s0_cf, s0_wcy;
    logic [2:0]  s0_cs0, s0_cs1;
    always_ff @(posedge clk) if (ce) begin
        s0_k <= px_u[44:16]; s0_f <= px_u[15:8];
        s0_sa <= e_sa; s0_sb <= e_sb; s0_sd <= e_sd; s0_wy <= e_wy; s0_ko <= e_ko;
        s0_kern <= kern;
        s0_ck <= px_cu[44:16]; s0_cf <= px_cu[15:8]; s0_cs0 <= e_cs0; s0_cs1 <= e_cs1; s0_wcy <= e_wcy;
        s0_in <= pic_valid && de_in && e_in && in_x && in_clip_x && in_clip_y;
    end
    // stage 1: the taps, clamped to the crop, and the RAM addresses
    wire  [10:0] x_k0 = (s0_k < $signed({17'd0, kmin_x})) ? kmin_x[10:0] :
                        (s0_k > $signed({17'd0, kmax_x})) ? kmax_x[10:0] : s0_k[10:0];
    wire  [10:0] x_k1 = (s0_k + 29'sd1 < $signed({17'd0, kmin_x})) ? kmin_x[10:0] :
                        (s0_k + 29'sd1 > $signed({17'd0, kmax_x})) ? kmax_x[10:0] : s0_k[10:0] + 11'd1;
    wire  [7:0]  x_w  = (s0_k < $signed({17'd0, kmin_x})) ? 8'd0 : s0_f;
    wire  [7:0]  wa   = x_k0[10:3];                     // the first tap's word
    wire  [6:0]  a_ev = (wa + 8'd1) >> 1;               // the even bank holds wa or wa + 1
    wire  [6:0]  a_od = wa[7:1];                        // the odd bank the other
    // (docs/chroma.md) chroma's taps, clamped to the crop's decimated chroma columns; the weight 0 left of it
    wire  [9:0]  c_x0 = (s0_ck < $signed({17'd0, ckmin_x})) ? ckmin_x[9:0] :
                        (s0_ck > $signed({17'd0, ckmax_x})) ? ckmax_x[9:0] : s0_ck[9:0];
    wire  [9:0]  c_x1 = (s0_ck + 29'sd1 < $signed({17'd0, ckmin_x})) ? ckmin_x[9:0] :
                        (s0_ck + 29'sd1 > $signed({17'd0, ckmax_x})) ? ckmax_x[9:0] : s0_ck[9:0] + 10'd1;
    wire  [7:0]  c_wx = (s0_ck < $signed({17'd0, ckmin_x})) ? 8'd0 : s0_cf;
    wire  [6:0]  cwa  = c_x0[9:3];                      // the first tap's word
    wire  [7:0]  cwa1 = {1'b0, cwa} + 8'd1;
    wire  [5:0]  c_ev = cwa1[6:1];                      // the even bank holds cwa or cwa + 1 (no N'() cast: Quartus 17)
    wire  [5:0]  c_od = cwa[6:1];
    // (the RAM words, on the dot like every stage: read every clock, the register would hold the
    // NEXT dot's word by the time the next stage takes it beside this dot's byte selects)
    logic [63:0] q_ya, q_ybe, q_ybo, q_yde, q_ydo;
    logic [63:0] q_cb0e, q_cb0o, q_cb1e, q_cb1o, q_cr0e, q_cr0o, q_cr1e, q_cr1o;
    always_ff @(posedge clk) if (ce) begin
        q_ya  <= ya_ram[{s0_sa, wa}];
        q_ybe <= ybe_ram[{s0_sb, a_ev}];
        q_ybo <= ybo_ram[{s0_sb, a_od}];
        q_yde <= yde_ram[{s0_sd, a_ev}];
        q_ydo <= ydo_ram[{s0_sd, a_od}];
        q_cb0e <= cb0e_ram[{s0_cs0, c_ev}]; q_cb0o <= cb0o_ram[{s0_cs0, c_od}];
        q_cb1e <= cb1e_ram[{s0_cs1, c_ev}]; q_cb1o <= cb1o_ram[{s0_cs1, c_od}];
        q_cr0e <= cr0e_ram[{s0_cs0, c_ev}]; q_cr0o <= cr0o_ram[{s0_cs0, c_od}];
        q_cr1e <= cr1e_ram[{s0_cs1, c_ev}]; q_cr1o <= cr1o_ram[{s0_cs1, c_od}];
    end
    // stage 2: the M10K's output register (nothing between the RAM and it)
    logic [63:0] q2_ya, q2_ybe, q2_ybo, q2_yde, q2_ydo;
    logic [63:0] q2_cb0e, q2_cb0o, q2_cb1e, q2_cb1o, q2_cr0e, q2_cr0o, q2_cr1e, q2_cr1o;
    always_ff @(posedge clk) if (ce) begin
        q2_ya <= q_ya; q2_ybe <= q_ybe; q2_ybo <= q_ybo; q2_yde <= q_yde; q2_ydo <= q_ydo;
        q2_cb0e <= q_cb0e; q2_cb0o <= q_cb0o; q2_cb1e <= q_cb1e; q2_cb1o <= q_cb1o;
        q2_cr0e <= q_cr0e; q2_cr0o <= q_cr0o; q2_cr1e <= q_cr1e; q2_cr1o <= q_cr1o;
    end
    // the side band through stages 1 and 2: which bytes and weights
    logic [2:0]  s1_b0, s1_b1, s2_b0, s2_b1;
    logic        s1_wodd, s1_same, s2_wodd, s2_same;
    logic [7:0]  s1_w, s1_wy, s2_w, s2_wy;
    logic [1:0]  s1_k, s2_k;
    logic        s1_in, s2_in, s1_ko, s2_ko;
    logic [2:0]  s1_cb0, s1_cb1, s2_cb0, s2_cb1;     // (chroma.md) its taps' bytes, words, weights
    logic        s1_codd, s1_csame, s2_codd, s2_csame;
    logic [7:0]  s1_cwx, s1_cwy, s2_cwx, s2_cwy;
    // stage 3: the bytes (and the horizontal differences)
    wire  [63:0] yb_w0 = s2_wodd ? q2_ybo : q2_ybe, yb_w1 = s2_wodd ? q2_ybe : q2_ybo;   // word wa, wa + 1
    wire  [63:0] yd_w0 = s2_wodd ? q2_ydo : q2_yde, yd_w1 = s2_wodd ? q2_yde : q2_ydo;
    logic [7:0]  sb0, sb1, sd0, sd1, sa_;
    always_comb begin
        // (the byte within a word by a case: no variable part-select, Quartus 17)
        case (s2_b0)
            3'd0: begin sb0 = yb_w0[7:0];   sd0 = yd_w0[7:0];   sa_ = q2_ya[7:0];   end
            3'd1: begin sb0 = yb_w0[15:8];  sd0 = yd_w0[15:8];  sa_ = q2_ya[15:8];  end
            3'd2: begin sb0 = yb_w0[23:16]; sd0 = yd_w0[23:16]; sa_ = q2_ya[23:16]; end
            3'd3: begin sb0 = yb_w0[31:24]; sd0 = yd_w0[31:24]; sa_ = q2_ya[31:24]; end
            3'd4: begin sb0 = yb_w0[39:32]; sd0 = yd_w0[39:32]; sa_ = q2_ya[39:32]; end
            3'd5: begin sb0 = yb_w0[47:40]; sd0 = yd_w0[47:40]; sa_ = q2_ya[47:40]; end
            3'd6: begin sb0 = yb_w0[55:48]; sd0 = yd_w0[55:48]; sa_ = q2_ya[55:48]; end
            default: begin sb0 = yb_w0[63:56]; sd0 = yd_w0[63:56]; sa_ = q2_ya[63:56]; end
        endcase
        case (s2_b1)
            3'd0: begin sb1 = s2_same ? yb_w0[7:0]   : yb_w1[7:0];   sd1 = s2_same ? yd_w0[7:0]   : yd_w1[7:0];   end
            3'd1: begin sb1 = s2_same ? yb_w0[15:8]  : yb_w1[15:8];  sd1 = s2_same ? yd_w0[15:8]  : yd_w1[15:8];  end
            3'd2: begin sb1 = s2_same ? yb_w0[23:16] : yb_w1[23:16]; sd1 = s2_same ? yd_w0[23:16] : yd_w1[23:16]; end
            3'd3: begin sb1 = s2_same ? yb_w0[31:24] : yb_w1[31:24]; sd1 = s2_same ? yd_w0[31:24] : yd_w1[31:24]; end
            3'd4: begin sb1 = s2_same ? yb_w0[39:32] : yb_w1[39:32]; sd1 = s2_same ? yd_w0[39:32] : yd_w1[39:32]; end
            3'd5: begin sb1 = s2_same ? yb_w0[47:40] : yb_w1[47:40]; sd1 = s2_same ? yd_w0[47:40] : yd_w1[47:40]; end
            3'd6: begin sb1 = s2_same ? yb_w0[55:48] : yb_w1[55:48]; sd1 = s2_same ? yd_w0[55:48] : yd_w1[55:48]; end
            default: begin sb1 = s2_same ? yb_w0[63:56] : yb_w1[63:56]; sd1 = s2_same ? yd_w0[63:56] : yd_w1[63:56]; end
        endcase
    end
    // (docs/chroma.md) chroma's bytes: rows 0 / 1 (the line's two chroma rows), taps 0 / 1, Cb and Cr
    wire  [63:0] cb0_w0 = s2_codd ? q2_cb0o : q2_cb0e, cb0_w1 = s2_codd ? q2_cb0e : q2_cb0o;
    wire  [63:0] cb1_w0 = s2_codd ? q2_cb1o : q2_cb1e, cb1_w1 = s2_codd ? q2_cb1e : q2_cb1o;
    wire  [63:0] cr0_w0 = s2_codd ? q2_cr0o : q2_cr0e, cr0_w1 = s2_codd ? q2_cr0e : q2_cr0o;
    wire  [63:0] cr1_w0 = s2_codd ? q2_cr1o : q2_cr1e, cr1_w1 = s2_codd ? q2_cr1e : q2_cr1o;
    logic [7:0]  cu00, cu01, cu10, cu11, cv00, cv01, cv10, cv11;
    always_comb begin
        case (s2_cb0)
            3'd0: begin cu00 = cb0_w0[7:0]; cu10 = cb1_w0[7:0]; cv00 = cr0_w0[7:0]; cv10 = cr1_w0[7:0]; end
            3'd1: begin cu00 = cb0_w0[15:8]; cu10 = cb1_w0[15:8]; cv00 = cr0_w0[15:8]; cv10 = cr1_w0[15:8]; end
            3'd2: begin cu00 = cb0_w0[23:16]; cu10 = cb1_w0[23:16]; cv00 = cr0_w0[23:16]; cv10 = cr1_w0[23:16]; end
            3'd3: begin cu00 = cb0_w0[31:24]; cu10 = cb1_w0[31:24]; cv00 = cr0_w0[31:24]; cv10 = cr1_w0[31:24]; end
            3'd4: begin cu00 = cb0_w0[39:32]; cu10 = cb1_w0[39:32]; cv00 = cr0_w0[39:32]; cv10 = cr1_w0[39:32]; end
            3'd5: begin cu00 = cb0_w0[47:40]; cu10 = cb1_w0[47:40]; cv00 = cr0_w0[47:40]; cv10 = cr1_w0[47:40]; end
            3'd6: begin cu00 = cb0_w0[55:48]; cu10 = cb1_w0[55:48]; cv00 = cr0_w0[55:48]; cv10 = cr1_w0[55:48]; end
            default: begin cu00 = cb0_w0[63:56]; cu10 = cb1_w0[63:56]; cv00 = cr0_w0[63:56]; cv10 = cr1_w0[63:56]; end
        endcase
        case (s2_cb1)
            3'd0: begin cu01 = s2_csame ? cb0_w0[7:0] : cb0_w1[7:0]; cu11 = s2_csame ? cb1_w0[7:0] : cb1_w1[7:0]; cv01 = s2_csame ? cr0_w0[7:0] : cr0_w1[7:0]; cv11 = s2_csame ? cr1_w0[7:0] : cr1_w1[7:0]; end
            3'd1: begin cu01 = s2_csame ? cb0_w0[15:8] : cb0_w1[15:8]; cu11 = s2_csame ? cb1_w0[15:8] : cb1_w1[15:8]; cv01 = s2_csame ? cr0_w0[15:8] : cr0_w1[15:8]; cv11 = s2_csame ? cr1_w0[15:8] : cr1_w1[15:8]; end
            3'd2: begin cu01 = s2_csame ? cb0_w0[23:16] : cb0_w1[23:16]; cu11 = s2_csame ? cb1_w0[23:16] : cb1_w1[23:16]; cv01 = s2_csame ? cr0_w0[23:16] : cr0_w1[23:16]; cv11 = s2_csame ? cr1_w0[23:16] : cr1_w1[23:16]; end
            3'd3: begin cu01 = s2_csame ? cb0_w0[31:24] : cb0_w1[31:24]; cu11 = s2_csame ? cb1_w0[31:24] : cb1_w1[31:24]; cv01 = s2_csame ? cr0_w0[31:24] : cr0_w1[31:24]; cv11 = s2_csame ? cr1_w0[31:24] : cr1_w1[31:24]; end
            3'd4: begin cu01 = s2_csame ? cb0_w0[39:32] : cb0_w1[39:32]; cu11 = s2_csame ? cb1_w0[39:32] : cb1_w1[39:32]; cv01 = s2_csame ? cr0_w0[39:32] : cr0_w1[39:32]; cv11 = s2_csame ? cr1_w0[39:32] : cr1_w1[39:32]; end
            3'd5: begin cu01 = s2_csame ? cb0_w0[47:40] : cb0_w1[47:40]; cu11 = s2_csame ? cb1_w0[47:40] : cb1_w1[47:40]; cv01 = s2_csame ? cr0_w0[47:40] : cr0_w1[47:40]; cv11 = s2_csame ? cr1_w0[47:40] : cr1_w1[47:40]; end
            3'd6: begin cu01 = s2_csame ? cb0_w0[55:48] : cb0_w1[55:48]; cu11 = s2_csame ? cb1_w0[55:48] : cb1_w1[55:48]; cv01 = s2_csame ? cr0_w0[55:48] : cr0_w1[55:48]; cv11 = s2_csame ? cr1_w0[55:48] : cr1_w1[55:48]; end
            default: begin cu01 = s2_csame ? cb0_w0[63:56] : cb0_w1[63:56]; cu11 = s2_csame ? cb1_w0[63:56] : cb1_w1[63:56]; cv01 = s2_csame ? cr0_w0[63:56] : cr0_w1[63:56]; cv11 = s2_csame ? cr1_w0[63:56] : cr1_w1[63:56]; end
        endcase
    end
    logic [7:0]  s3_b0, s3_d0, s3_ya, s3_w, s3_wy;
    logic signed [9:0] s3_db, s3_dd;
    logic [7:0]  s3_cu0, s3_cu1, s3_cv0, s3_cv1, s3_cwx, s3_cwy;   // (chroma.md) each row's first tap and difference
    logic signed [9:0] s3_du0, s3_du1, s3_dv0, s3_dv1;
    logic [1:0]  s3_k;
    logic        s3_in, s3_ko;
    // stage 4: the horizontal blend, (a (256 - w) + b w + 128) >> 8 = (256 a + (b - a) w + 128) >> 8
    wire signed [18:0] hb_s = $signed({3'd0, s3_b0, 8'd0}) + s3_db * $signed({1'b0, s3_w}) + 19'sd128;
    wire signed [18:0] hd_s = $signed({3'd0, s3_d0, 8'd0}) + s3_dd * $signed({1'b0, s3_w}) + 19'sd128;
    logic [7:0]  s4_hb, s4_hd, s4_ya, s4_wy;
    logic [1:0]  s4_k;
    logic        s4_in, s4_ko;
    // (docs/chroma.md) chroma horizontally, luma's form, on both rows of each plane
    wire signed [18:0] hu0_s = $signed({3'd0, s3_cu0, 8'd0}) + s3_du0 * $signed({1'b0, s3_cwx}) + 19'sd128;
    wire signed [18:0] hu1_s = $signed({3'd0, s3_cu1, 8'd0}) + s3_du1 * $signed({1'b0, s3_cwx}) + 19'sd128;
    wire signed [18:0] hv0_s = $signed({3'd0, s3_cv0, 8'd0}) + s3_dv0 * $signed({1'b0, s3_cwx}) + 19'sd128;
    wire signed [18:0] hv1_s = $signed({3'd0, s3_cv1, 8'd0}) + s3_dv1 * $signed({1'b0, s3_cwx}) + 19'sd128;
    logic [7:0]  s4_hu0, s4_hu1, s4_hv0, s4_hv1, s4_cwy;
    // stage 5: the vertical blend or the kernel
    wire  [9:0]  yl = {2'd0, s4_ya} + {1'd0, s4_hb, 1'b0} + {2'd0, s4_hd} + 10'd1;
    wire  [8:0]  ym = {1'd0, s4_ya} + {1'd0, s4_hd} + 9'd1;
    // (the vertical blend as two products, (256 - w) b + w d + 128 -- the same integer as
    // 256 b + (d - b) w + 128, without a subtract in front of the multiply: hd_raster's 81 MHz)
    wire  [8:0]  iwy  = 9'd256 - {1'b0, s4_wy};
    wire  [17:0] yv_s = {1'b0, s4_hb} * iwy + {1'b0, s4_hd} * {1'b0, s4_wy} + 18'd128;
    // (docs/chroma.md) chroma vertically, luma's two-product form: the line's row weight. No kernel: Bob's
    // rebuilt line reads the kept field's rows, Blend its own field's (the line control chose them)
    wire  [8:0]  iwc  = 9'd256 - {1'b0, s4_cwy};
    wire  [17:0] cu_s = {1'b0, s4_hu0} * iwc + {1'b0, s4_hu1} * {1'b0, s4_cwy} + 18'd128;
    wire  [17:0] cv_s = {1'b0, s4_hv0} * iwc + {1'b0, s4_hv1} * {1'b0, s4_cwy} + 18'd128;
    logic [7:0]  s5_yl, s5_ym, s5_yv, s5_yb, s5_u, s5_v;   // luma's candidates: chosen in stage 6
    logic [1:0]  s5_k;
    logic        s5_ko;
    logic        s5_in, s6_in, s7_in;
    // stage 6: luma's kernel, C / D / E and the products
    wire  [7:0]  yk = (s5_k == 2'd2) ? s5_yl : (s5_k == 2'd1) ? s5_ym : !s5_ko ? s5_yv : s5_yb;
    // (0.16) the colour code's integers (tools/colour_ref.py --sv), registered from the latched code:
    // static through a refresh, so the products below see registers, not a mux in their cone
    logic [4:0]  cf_yoff;
    logic [9:0]  cf_c, cf_rv, cf_bg, cf_rg, cf_bb;
    always_ff @(posedge clk) begin
        case (k_col)
            3'd2:    begin cf_yoff <= 5'd0;  cf_c <= 10'd256; cf_rv <= 10'd359; cf_bg <= 10'd88;  cf_rg <= 10'd183; cf_bb <= 10'd454; end
            3'd3:    begin cf_yoff <= 5'd16; cf_c <= 10'd298; cf_rv <= 10'd459; cf_bg <= 10'd55;  cf_rg <= 10'd136; cf_bb <= 10'd541; end
            3'd4:    begin cf_yoff <= 5'd0;  cf_c <= 10'd256; cf_rv <= 10'd403; cf_bg <= 10'd48;  cf_rg <= 10'd120; cf_bb <= 10'd475; end
            3'd5:    begin cf_yoff <= 5'd16; cf_c <= 10'd298; cf_rv <= 10'd430; cf_bg <= 10'd48;  cf_rg <= 10'd167; cf_bb <= 10'd548; end
            3'd6:    begin cf_yoff <= 5'd0;  cf_c <= 10'd256; cf_rv <= 10'd377; cf_bg <= 10'd42;  cf_rg <= 10'd146; cf_bb <= 10'd482; end
            default: begin cf_yoff <= 5'd16; cf_c <= 10'd298; cf_rv <= 10'd409; cf_bg <= 10'd100; cf_rg <= 10'd208; cf_bb <= 10'd516; end
        endcase
    end
    wire signed [9:0]  c2 = $signed({2'b0, yk}) - $signed({5'd0, cf_yoff});
    wire signed [9:0]  d2 = $signed({2'b0, s5_u}) - 10'sd128;
    wire signed [9:0]  e2 = $signed({2'b0, s5_v}) - 10'sd128;
    logic signed [19:0] p_c, p_ecr, p_dcb, p_dg, p_eg;
    // stage 7: the sums; stage 8: the clip
    logic signed [19:0] rr, gg, bb;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_b0 <= '0; s1_b1 <= '0; s1_wodd <= 1'b0; s1_same <= 1'b1; s1_w <= '0; s1_wy <= '0;
            s1_k <= '0; s1_in <= 1'b0; s1_ko <= 1'b0;
            s1_cb0 <= '0; s1_cb1 <= '0; s1_codd <= 1'b0; s1_csame <= 1'b1; s1_cwx <= '0; s1_cwy <= '0;
            s2_cb0 <= '0; s2_cb1 <= '0; s2_codd <= 1'b0; s2_csame <= 1'b1; s2_cwx <= '0; s2_cwy <= '0;
            s2_b0 <= '0; s2_b1 <= '0; s2_wodd <= 1'b0; s2_same <= 1'b1; s2_w <= '0; s2_wy <= '0;
            s2_k <= '0; s2_in <= 1'b0; s2_ko <= 1'b0;
            s3_b0 <= '0; s3_d0 <= '0; s3_ya <= '0;
            s3_w <= '0; s3_wy <= '0; s3_db <= '0; s3_dd <= '0; s3_k <= '0; s3_in <= 1'b0; s3_ko <= 1'b0;
            s3_cu0 <= '0; s3_cu1 <= '0; s3_cv0 <= '0; s3_cv1 <= '0; s3_cwx <= '0; s3_cwy <= '0;
            s3_du0 <= '0; s3_du1 <= '0; s3_dv0 <= '0; s3_dv1 <= '0;
            s4_hb <= '0; s4_hd <= '0; s4_ya <= '0;
            s4_wy <= '0; s4_k <= '0; s4_in <= 1'b0; s4_ko <= 1'b0;
            s4_hu0 <= '0; s4_hu1 <= '0; s4_hv0 <= '0; s4_hv1 <= '0; s4_cwy <= '0;
            s5_yl <= '0; s5_ym <= '0; s5_yv <= '0; s5_yb <= '0; s5_k <= '0; s5_ko <= 1'b0;
            s5_u <= '0; s5_v <= '0; s5_in <= 1'b0; s6_in <= 1'b0; s7_in <= 1'b0;
            p_c <= '0; p_ecr <= '0; p_dcb <= '0; p_dg <= '0; p_eg <= '0;
            rr <= '0; gg <= '0; bb <= '0;
            r <= '0; g <= '0; b <= '0; de_out <= 1'b0;
        end else if (ce) begin
            // stage 1 (the RAM read above) -- remember which bytes and weights
            s1_b0 <= x_k0[2:0]; s1_b1 <= x_k1[2:0];
            s1_wodd <= wa[0]; s1_same <= (x_k1[10:3] == wa);
            s1_w <= x_w; s1_wy <= s0_wy; s1_k <= s0_kern; s1_in <= s0_in; s1_ko <= s0_ko;
            s1_cb0 <= c_x0[2:0]; s1_cb1 <= c_x1[2:0]; s1_codd <= cwa[0]; s1_csame <= (c_x1[9:3] == cwa);
            s1_cwx <= c_wx; s1_cwy <= s0_wcy;
            // stage 2 (the RAM's output register)
            s2_b0 <= s1_b0; s2_b1 <= s1_b1; s2_wodd <= s1_wodd; s2_same <= s1_same;
            s2_w <= s1_w; s2_wy <= s1_wy; s2_k <= s1_k; s2_in <= s1_in; s2_ko <= s1_ko;
            s2_cb0 <= s1_cb0; s2_cb1 <= s1_cb1; s2_codd <= s1_codd; s2_csame <= s1_csame; s2_cwx <= s1_cwx; s2_cwy <= s1_cwy;
            // stage 3: the bytes (the kernel's a is its first tap)
            s3_b0 <= sb0; s3_d0 <= sd0; s3_ya <= sa_;
            s3_db <= $signed({2'b0, sb1}) - $signed({2'b0, sb0});
            s3_dd <= $signed({2'b0, sd1}) - $signed({2'b0, sd0});
            s3_w <= s2_w; s3_wy <= s2_wy; s3_k <= s2_k; s3_in <= s2_in; s3_ko <= s2_ko;
            s3_cu0 <= cu00; s3_du0 <= $signed({2'b0, cu01}) - $signed({2'b0, cu00});
            s3_cu1 <= cu10; s3_du1 <= $signed({2'b0, cu11}) - $signed({2'b0, cu10});
            s3_cv0 <= cv00; s3_dv0 <= $signed({2'b0, cv01}) - $signed({2'b0, cv00});
            s3_cv1 <= cv10; s3_dv1 <= $signed({2'b0, cv11}) - $signed({2'b0, cv10});
            s3_cwx <= s2_cwx; s3_cwy <= s2_cwy;
            // stage 4: the horizontal blend
            s4_hb <= hb_s[15:8]; s4_hd <= hd_s[15:8];
            s4_ya <= s3_ya;
            s4_hu0 <= hu0_s[15:8]; s4_hu1 <= hu1_s[15:8]; s4_hv0 <= hv0_s[15:8]; s4_hv1 <= hv1_s[15:8]; s4_cwy <= s3_cwy;
            s4_wy <= s3_wy; s4_k <= s3_k; s4_in <= s3_in; s4_ko <= s3_ko;
            // stage 5: the vertical blend / the kernel (luma's choice in stage 6)
            s5_yl <= yl[9:2]; s5_ym <= ym[8:1]; s5_yv <= yv_s[15:8]; s5_yb <= s4_hb; s5_k <= s4_k; s5_ko <= s4_ko;
            s5_u <= cu_s[15:8]; s5_v <= cv_s[15:8]; s5_in <= s4_in;
            // stage 6: the products
            p_c <= $signed({1'b0, cf_c}) * c2; p_ecr <= $signed({1'b0, cf_rv}) * e2; p_dcb <= $signed({1'b0, cf_bb}) * d2;
            p_dg <= $signed({1'b0, cf_bg}) * d2; p_eg <= $signed({1'b0, cf_rg}) * e2;
            s6_in <= s5_in;
            // stage 7: the sums
            rr <= (p_c + p_ecr + $signed({12'd0, gd_pipe[6]})) >>> 8;
            gg <= (p_c - p_dg - p_eg + $signed({12'd0, gd_pipe[6]})) >>> 8;
            bb <= (p_c + p_dcb + $signed({12'd0, gd_pipe[6]})) >>> 8;
            s7_in <= s6_in;
            // stage 8: the clip
            r <= !s7_in ? 8'd0 : (rr < 0) ? 8'd0 : (rr > 255) ? 8'd255 : rr[7:0];
            g <= !s7_in ? 8'd0 : (gg < 0) ? 8'd0 : (gg > 255) ? 8'd255 : gg[7:0];
            b <= !s7_in ? 8'd0 : (bb < 0) ? 8'd0 : (bb > 255) ? 8'd255 : bb[7:0];
            de_out <= s7_in;
        end
    end

    // =========================================================================================
    // clk_mem: fetch the commanded rows
    // =========================================================================================
    // The command and the picture cross as quasi-static values, captured when the command's
    // toggle has crossed (the values were set with it, a line's worth of cycles before the
    // next can change them; h264/h264.sdc bounds the captures). A command that arrives while
    // one runs is taken when the engine is free (its toggle is compared with the last taken).
    logic [2:0]  m_tog;
    logic        m_seen;
    logic [4:0]  m_store;
    logic [7:0]  m_w, m_hf;
    logic        m_field, m_first, m_par, m_valid;
    logic [2:0]  m_hpf, m_vpf;             // (§11b) the pre-filters
    logic [1:0]  m_dh, m_dv, m_n;
    logic [11:0] m_row0, m_row1;
    logic [1:0]  m_slot0, m_slot1;
    logic [1:0]  m_cn;                     // (docs/chroma.md §3) the command's chroma rows: count, rows, slots
    logic [11:0] m_crow0, m_crow1;
    logic [2:0]  m_cslot0, m_cslot1;
    logic        fc_seen, fc_par;
    logic [4:0]  fc_store;

    typedef enum logic [2:0] {F_IDLE, F_ROW, F_SETUP1, F_SETUP2, F_CMD, F_WAIT, F_DRAIN} fstate_t;
    fstate_t fs;
    logic [1:0]  f_done;                   // the command's luma rows finished
    logic        f_chr;                    // (chroma.md §3) its chroma rows' turn
    logic [1:0]  f_cd;                     // ... the chroma rows finished
    logic [11:0] f_row;                    // the decimated luma row
    logic [11:0] f_crow;                   // the store's decimated chroma row
    logic [2:0]  f_slot;                   // luma: [1:0]; chroma: all three
    logic [1:0]  plane;                    // 0 Y, 1 Cb, 2 Cr
    logic [3:0]  f_i;                      // the source row within the box (0 .. dv - 1)
    logic [8:0]  f_word, f_got, f_words;   // the plane row's words: requested, received, total
    logic [20:0] pm_r;                     // W * HF (macroblocks a plane)
    logic [28:0] ly_r, lc_r;
    logic [28:0] row_base;
    logic [1:0]  f_drain;
    wire  [28:0] store_base = DPB_BASE + {6'd0, m_store, 18'd0};   // 2 MiB stores (h264_recon.md S2.2)
    wire  [8:0]  left = f_words - f_word;
    wire  [3:0]  dv_n = 4'd1 << m_dv;
    // (§11b) the luma pre-filter's boxes: 1, or 2 under a code (anti-twitter's sliding rows: 4); its
    // weight for the box a source row is in (8 - A, then A); chroma one box, weight 8 (unfiltered)
    wire         f_box = (m_dv == 2'd0) ? f_i[0] : (m_dv == 2'd1) ? f_i[1] : (m_dv == 2'd2) ? f_i[2] : f_i[3];
    wire  [3:0]  w_row = (plane != 2'd0) ? 4'd8 :
                         !f_box          ? 4'd8 - {1'b0, m_vpf} : {1'b0, m_vpf};
    // the source rows in this plane's box: dv, 2 dv for luma under a code (2 dv <= 8: disp_fit's budget)
    wire  [4:0]  rows_m1 = ((plane == 2'd0 && m_vpf != 3'd0) ? {dv_n, 1'b0} : {1'b0, dv_n}) - 5'd1;
    // the box's first source rows: luma f_row dv; chroma (docs/chroma.md §3) the commanded store chroma
    // row c dv -- a frame's decimated row, or a store of fields' line-interleaved row 2 k + p at dv = 1
    wire  [14:0] y_src0 = {3'd0, f_row} << m_dv;
    wire  [14:0] c_src0 = {3'd0, f_crow} << m_dv;
    wire  [14:0] y_src  = y_src0 + {11'd0, f_i};                      // this source row
    wire  [14:0] c_src  = c_src0 + {11'd0, f_i};
    wire  [23:0] ly_p = y_src * {m_w, 1'b0};                          // its offset in the plane (2W words a row)
    wire  [23:0] lc_p = c_src * m_w;                                  // (W words a chroma row)

    // ---- the beat path: the dh sums, the word being built, the accumulator -------------------
    // beat t: the sums (combinational) into lanes; the accumulator word read at the output
    // word's index; t + 1: the complete word summed with the accumulator (or alone on the
    // box's first row) and written back, or rounded into the slot on its last row
    logic [7:0]  bt [0:7];
    // (2026-10-06, the retime) the bridge's read data registered once: f2sdram's output -> the dh sums ->
    // p_stg in one clk_mem cycle closed at -0.20 ns at -40 C. Every beat is a clock later; F_WAIT counts the
    // registered beats, so the drain follows the last one as before
    logic [63:0] rd_q;
    logic        rd_vq;
    always_ff @(posedge mclk or negedge mrst_n)
        if (!mrst_n) begin rd_q <= '0; rd_vq <= 1'b0; end
        else begin rd_q <= ddr_readdata; rd_vq <= ddr_readdatavalid; end
    always_comb for (int i = 0; i < 8; i++) bt[i] = rd_q[8*i +: 8];
    logic [10:0] hs [0:7];                 // this beat's sums (dh at a time), lanes 0 .. 8/dh - 1
    always_comb begin
        for (int i = 0; i < 8; i++) hs[i] = '0;
        case (m_dh)
            2'd0: for (int i = 0; i < 8; i++) hs[i] = {3'd0, bt[i]};
            2'd1: for (int i = 0; i < 4; i++) hs[i] = {3'd0, bt[2*i]} + {3'd0, bt[2*i+1]};
            2'd2: for (int i = 0; i < 2; i++) hs[i] = {3'd0, bt[4*i]} + {3'd0, bt[4*i+1]} + {3'd0, bt[4*i+2]} + {3'd0, bt[4*i+3]};
            default: hs[0] = {3'd0, bt[0]} + {3'd0, bt[1]} + {3'd0, bt[2]} + {3'd0, bt[3]} +
                             {3'd0, bt[4]} + {3'd0, bt[5]} + {3'd0, bt[6]} + {3'd0, bt[7]};
        endcase
    end
    logic [10:0] stg [0:7];                // the word being built
    logic [10:0] stg_n [0:7];
    wire  [2:0]  sub = (m_dh == 2'd0) ? 3'd0 : (m_dh == 2'd1) ? {2'd0, f_got[0]} :
                       (m_dh == 2'd2) ? {1'b0, f_got[1:0]} : f_got[2:0];      // the beat within the word
    wire         w_done = (sub == ((3'd1 << m_dh) - 3'd1)) || (f_got + 9'd1 == f_words);
    wire  [7:0]  w_idx = f_got[8:0] >> m_dh;                                 // the output word (<= 255)
    always_comb begin
        for (int i = 0; i < 8; i++) stg_n[i] = (sub == 3'd0) ? 11'd0 : stg[i];
        case (m_dh)
            2'd0: for (int i = 0; i < 8; i++) stg_n[i] = hs[i];
            2'd1: for (int i = 0; i < 4; i++) stg_n[{sub[0], 2'd0} + i] = hs[i];
            2'd2: for (int i = 0; i < 2; i++) stg_n[{sub[1:0], 1'b0} + i] = hs[i];
            default: stg_n[sub] = hs[0];
        endcase
    end
    // the accumulator: 8 lanes of 17 bits a word (dh dv <= 64 samples of 8 bits, weighted <= 8: §11b)
    logic [135:0] acc_ram [0:255];
    logic [135:0] acc_q;
    always_ff @(posedge mclk) acc_q <= acc_ram[w_idx];   // addressed at the beat: its word at t + 1
    logic         p_v, p_first, p_last, p_end;
    logic [7:0]   p_idx;
    logic [10:0]  p_stg [0:7];
    logic [3:0]   p_w;                     // (§11b) the row's weight (eighths)
    logic         acc_we;
    logic [7:0]   acc_wa;
    logic [135:0] acc_wd;
    always_ff @(posedge mclk) if (acc_we) acc_ram[acc_wa] <= acc_wd;
    logic [16:0]  sum_l [0:7];
    logic [14:0]  wst [0:7];               // p_stg x p_w (0..8) as shifts and adds: no DSP (the last nine
                                           // were taken by a product here, 2026-10-05)
    always_comb
        for (int i = 0; i < 8; i++) begin
            wst[i] = (p_w[3] ? {1'b0, p_stg[i], 3'd0} : 15'd0) + (p_w[2] ? {2'b0, p_stg[i], 2'd0} : 15'd0) +
                     (p_w[1] ? {3'b0, p_stg[i], 1'd0} : 15'd0) + (p_w[0] ? {4'b0, p_stg[i]} : 15'd0);
            sum_l[i] = (p_first ? 17'd0 : acc_q[17*i +: 17]) + {2'd0, wst[i]};
        end
    // (§11b) the horizontal pre-filter at the slot write: the last box row's vertical sums V of a
    // word (hn, t + 2) complete the word before it (hp: its lanes 0..7 and the new word's lane 0
    // are V_m, V_m+1); the row's last word is flushed a clock later with its own last lane
    // replicated (beyond the picture: never read). One rounding: (sum + 2^(s+5)) >> (s + 6)
    logic         hn_v, hn_end, hp_v, hf_v;
    logic [16:0]  hn [0:7];
    logic [16:0]  hp [0:7];
    logic [7:0]   hn_idx, hp_idx;
    logic [2:0]   hn_slot, hp_slot;
    logic [1:0]   hn_plane, hp_plane;
    logic [2:0]   hn_pf, hp_pf, hn_s, hp_s;
    logic [16:0]  hx [0:8];                // the lanes the word being written reads
    always_comb begin
        for (int i = 0; i < 8; i++) hx[i] = hp[i];
        hx[8] = hf_v ? hp[7] : hn[0];
    end
    // the weights as shifts and adds (no DSP): (8 - A, A) = 8 a + A (b - a), A 0..4 (b - a signed;
    // the sum is never negative)
    logic [20:0]  hsum [0:7];
    logic signed [17:0] hdf [0:7];
    logic signed [20:0] had [0:7];
    logic [7:0]   out_l [0:7];
    // (2026-10-06, the retime) the weighted sums registered (hq), the rounding and the slot write a
    // clock later: hp -> lb_wdata in one clk_mem cycle closed at -1.08 ns (SEED 3, -40 C). The write
    // lands one clock later than before -- still a clock before the command's done (F_DRAIN, F_ROW)
    logic         hq_v;
    logic [20:0]  hq [0:7];
    logic [2:0]   hq_s;
    logic [2:0]   hq_slot;
    logic [1:0]   hq_plane;
    logic [7:0]   hq_idx;
    always_comb
        for (int i = 0; i < 8; i++) begin
            hdf[i] = $signed({1'b0, hx[i+1]}) - $signed({1'b0, hx[i]});
            case (hp_pf)
                3'd1:    had[i] = {{3{hdf[i][17]}}, hdf[i]};
                3'd2:    had[i] = {{2{hdf[i][17]}}, hdf[i], 1'b0};
                3'd3:    had[i] = {{3{hdf[i][17]}}, hdf[i]} + {{2{hdf[i][17]}}, hdf[i], 1'b0};
                3'd4:    had[i] = {hdf[i][17], hdf[i], 2'b00};
                default: had[i] = 21'sd0;
            endcase
            hsum[i] = $unsigned($signed({1'b0, hx[i], 3'd0}) + had[i]);
            case (hq_s)
                3'd0: out_l[i] = (hq[i] + 21'd32)   >> 6;
                3'd1: out_l[i] = (hq[i] + 21'd64)   >> 7;
                3'd2: out_l[i] = (hq[i] + 21'd128)  >> 8;
                3'd3: out_l[i] = (hq[i] + 21'd256)  >> 9;
                3'd4: out_l[i] = (hq[i] + 21'd512)  >> 10;
                3'd5: out_l[i] = (hq[i] + 21'd1024) >> 11;
                default: out_l[i] = (hq[i] + 21'd2048) >> 12;
            endcase
        end

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            m_tog <= '0; m_seen <= 1'b0; m_store <= '0; m_w <= '0; m_hf <= '0; m_field <= 1'b0;
            m_first <= 1'b0; m_par <= 1'b0; m_valid <= 1'b0; m_hpf <= '0; m_vpf <= '0; m_dh <= '0; m_dv <= '0; m_n <= '0;
            m_row0 <= '0; m_row1 <= '0; m_slot0 <= '0; m_slot1 <= '0;
            m_cn <= '0; m_crow0 <= '0; m_crow1 <= '0; m_cslot0 <= '0; m_cslot1 <= '0;
            f_chr <= 1'b0; f_cd <= '0; f_crow <= '0;
            fc_seen <= 1'b0; fc_par <= 1'b0; fc_store <= '0; fetch_changes <= '0; done_tog <= 1'b0;
            fs <= F_IDLE; f_done <= '0; f_row <= '0; f_slot <= '0; plane <= '0; f_i <= '0;
            f_word <= '0; f_got <= '0; f_words <= '0; pm_r <= '0; ly_r <= '0; lc_r <= '0; row_base <= '0;
            f_drain <= '0;
            ddr_address <= '0; ddr_burstcount <= 8'd1; ddr_read <= 1'b0;
            lb_we_y <= 1'b0; lb_we_cb <= 1'b0; lb_we_cr <= 1'b0; lb_slot <= '0; lb_word <= '0; lb_wdata <= '0;
            for (int i = 0; i < 8; i++) begin stg[i] <= '0; p_stg[i] <= '0; end
            p_v <= 1'b0; p_first <= 1'b0; p_last <= 1'b0; p_end <= 1'b0; p_idx <= '0; p_w <= '0;
            acc_we <= 1'b0; acc_wa <= '0; acc_wd <= '0;
            hn_v <= 1'b0; hn_end <= 1'b0; hp_v <= 1'b0; hf_v <= 1'b0; hn_idx <= '0; hp_idx <= '0;
            hn_slot <= '0; hp_slot <= '0; hn_plane <= '0; hp_plane <= '0; hn_pf <= '0; hp_pf <= '0; hn_s <= '0; hp_s <= '0;
            for (int i = 0; i < 8; i++) begin hn[i] <= '0; hp[i] <= '0; hq[i] <= '0; end
            hq_v <= 1'b0; hq_s <= '0; hq_slot <= '0; hq_plane <= '0; hq_idx <= '0;
        end else begin
            m_tog <= {m_tog[1:0], cmd_tog};
            lb_we_y <= 1'b0; lb_we_cb <= 1'b0; lb_we_cr <= 1'b0; acc_we <= 1'b0; p_v <= 1'b0; hn_v <= 1'b0;
            // beat t: the word being built (the accumulator read at its index, above)
            if (rd_vq) begin
                for (int i = 0; i < 8; i++) stg[i] <= stg_n[i];
                f_got <= f_got + 9'd1;
                if (w_done) begin
                    p_v <= 1'b1; p_idx <= w_idx; p_first <= (f_i == 4'd0); p_last <= ({1'b0, f_i} == rows_m1);
                    p_end <= (f_got + 9'd1 == f_words); p_w <= w_row;
                    for (int i = 0; i < 8; i++) p_stg[i] <= stg_n[i];
                end
            end
            // t + 1 (the accumulator word read at t is in acc_q): write back, or (the box's last
            // row) the vertical sums to the horizontal stage
            if (p_v) begin
                if (p_last) begin
                    hn_v <= 1'b1; hn_end <= p_end; hn_idx <= p_idx; hn_slot <= f_slot; hn_plane <= plane;
                    hn_pf <= (plane == 2'd0) ? m_hpf : 3'd0;
                    hn_s <= {1'b0, m_dh} + {1'b0, m_dv};
                    for (int i = 0; i < 8; i++) hn[i] <= sum_l[i];
                end else begin
                    acc_we <= 1'b1; acc_wa <= p_idx;
                    for (int i = 0; i < 8; i++) acc_wd[17*i +: 17] <= sum_l[i];
                end
            end
            // t + 2: the word before this one (hp) completed by this one's first lanes and written;
            // this one held; the row's last flushed at t + 3 (hf_v)
            hf_v <= 1'b0;
            // t + 3: the registered sums rounded into the slot
            hq_v <= 1'b0;
            if (hq_v) begin
                lb_slot <= hq_slot; lb_word <= hq_idx;
                for (int i = 0; i < 8; i++) lb_wdata[8*i +: 8] <= out_l[i];
                lb_we_y <= (hq_plane == 2'd0); lb_we_cb <= (hq_plane == 2'd1); lb_we_cr <= (hq_plane == 2'd2);
            end
            if (hn_v || hf_v) begin
                if (hp_v) begin
                    hq_v <= 1'b1; hq_slot <= hp_slot; hq_idx <= hp_idx; hq_plane <= hp_plane; hq_s <= hp_s;
                    for (int i = 0; i < 8; i++) hq[i] <= hsum[i];
                end
                if (hn_v) begin
                    hp_v <= 1'b1; hp_idx <= hn_idx; hp_slot <= hn_slot; hp_plane <= hn_plane; hp_pf <= hn_pf; hp_s <= hn_s;
                    for (int i = 0; i < 8; i++) hp[i] <= hn[i];
                    hf_v <= hn_end;
                end else hp_v <= 1'b0;             // the flush: the row's last word written
            end
            case (fs)
                F_IDLE: if (m_tog[2] != m_seen) begin
                    // take the command and the picture (stable, see above)
                    m_seen <= m_tog[2];
                    m_store <= pic_store; m_w <= pic_w_mbs; m_hf <= pic_hf_mbs; m_field <= pic_field;
                    m_par <= pic_parity; m_valid <= pic_valid; m_first <= cmd_first; m_dh <= fit_dh_l2; m_dv <= fit_dv_l2;
                    m_hpf <= fit_hpf; m_vpf <= fit_vpf;
                    m_n <= cmd_n; m_row0 <= cmd_row0; m_row1 <= cmd_row1; m_slot0 <= cmd_slot0; m_slot1 <= cmd_slot1;
                    m_cn <= ccmd_n; m_crow0 <= ccmd_row0; m_crow1 <= ccmd_row1; m_cslot0 <= ccmd_slot0; m_cslot1 <= ccmd_slot1;
                    f_done <= '0; f_chr <= 1'b0; f_cd <= '0;
                    fs <= F_ROW;
                end
                F_ROW: begin
                    // (each refresh's first command: the (store, parity) it fetched -- once a
                    // picture is shown: before one, nothing was fetched)
                    if (m_first && m_valid && f_done == 2'd0) begin
                        if (!fc_seen || m_store != fc_store || m_par != fc_par) fetch_changes <= fetch_changes + 32'd1;
                        fc_seen <= 1'b1; fc_store <= m_store; fc_par <= m_par;
                    end
                    // (a first command's changes are counted once: m_first drops after it)
                    if (f_done == 2'd0) m_first <= 1'b0;
                    // (chroma.md §3) the luma rows (Y), then the chroma rows (Cb, Cr)
                    if (!f_chr) begin
                        if (f_done == m_n) f_chr <= 1'b1;
                        else begin
                            f_row <= (f_done == 2'd0) ? m_row0 : m_row1; f_slot <= {1'b0, (f_done == 2'd0) ? m_slot0 : m_slot1};
                            plane <= 2'd0; f_i <= 4'd0;
                            fs <= F_SETUP1;
                        end
                    end else if (f_cd == m_cn) begin
                        done_tog <= !done_tog; fs <= F_IDLE;
                    end else begin
                        f_crow <= (f_cd == 2'd0) ? m_crow0 : m_crow1; f_slot <= (f_cd == 2'd0) ? m_cslot0 : m_cslot1;
                        plane <= 2'd1; f_i <= 4'd0;
                        fs <= F_SETUP1;
                    end
                end
                F_SETUP1: begin
                    // the plane row's address: luma (row) 2W words a row; chroma W words a row
                    pm_r <= {13'd0, m_w} * {13'd0, m_hf};
                    ly_r <= {5'd0, ly_p};
                    lc_r <= {5'd0, lc_p};
                    fs <= F_SETUP2;
                end
                F_SETUP2: begin
                    row_base <= (plane == 2'd0) ? store_base + ly_r :
                                (plane == 2'd1) ? store_base + {3'd0, pm_r, 5'd0} + lc_r :
                                                  store_base + {3'd0, pm_r, 5'd0} + {5'd0, pm_r, 3'd0} + lc_r;
                    f_word <= '0; f_got <= '0; f_words <= (plane == 2'd0) ? {m_w, 1'b0} : {1'b0, m_w};
                    fs <= F_CMD;
                end
                F_CMD: begin
                    // a command is held until accepted; the next one follows in the same cycle
                    if (!ddr_read || !ddr_waitrequest) begin
                        if (f_word < f_words) begin
                            ddr_read <= 1'b1;
                            ddr_address <= row_base + {20'd0, f_word};
                            ddr_burstcount <= (left > 9'd8) ? 8'd8 : left[7:0];
                            f_word <= f_word + ((left > 9'd8) ? 9'd8 : left);
                        end else begin
                            ddr_read <= 1'b0;
                            fs <= F_WAIT;
                        end
                    end
                end
                F_WAIT: if (f_got == f_words) begin f_drain <= 2'd2; fs <= F_DRAIN; end
                F_DRAIN: begin
                    // the last word through the accumulator before the next row reads it
                    if (f_drain != 2'd0) f_drain <= f_drain - 2'd1;
                    else if ({1'b0, f_i} != rows_m1) begin
                        f_i <= f_i + 4'd1; fs <= F_SETUP1;
                    end else if (plane == 2'd0) begin
                        f_done <= f_done + 2'd1; fs <= F_ROW;          // a luma row: Y only
                    end else if (plane == 2'd1) begin
                        plane <= 2'd2; f_i <= 4'd0; fs <= F_SETUP1;   // a chroma row: Cb, then Cr
                    end else begin
                        f_cd <= f_cd + 2'd1; fs <= F_ROW;
                    end
                end
                default: fs <= F_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
