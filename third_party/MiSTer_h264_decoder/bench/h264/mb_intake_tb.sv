// bench/h264/mb_intake_tb.sv -- h264/dec/mb_intake.sv on a real stream's macroblock words
// against tools/intake_golden.py (the model's own intake + expand_mb)
//
// +stem=<path>: <stem>.mbw.hex (the words), .dsc.hex (the descriptor per macroblock),
// .meta.hex. The bench feeds the words with random gaps (+stall=N), drives the slice
// inputs from each descriptor's header word, and at every mb_valid compares:
//   [dsc]   every descriptor field (`!==`)
//   [coef]  every coded block's levels read back through the coefficient port, I_PCM's samples
//   [err]   err_order never pulses
//   [count] every macroblock of the stream arrived
// then releases it after a random delay. PASS marker: "PASS: mb_intake_tb".
`timescale 1ns/1ps
module mb_intake_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] mb %0d: %0s", arm, n_mb, msg); $fatal(1); end

localparam MAXW = 1 << 22;
localparam MAXD = 1 << 23;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

reg  [1:0]  slice_type = 2'd2;
reg  [5:0]  num_ref_l0 = 6'd1, num_ref_l1 = 6'd1;
reg         in_valid = 1'b0;
wire        in_ready;
reg  [7:0]  in_kind = 8'd0, in_aux = 8'd0;
reg  [15:0] in_val = 16'd0;
wire        mb_valid;
reg         mb_release = 1'b0;
wire [13:0] mb_addr;
wire        mb_skip, mb_is_intra, mb_end_of_slice, mb_pcm, mb_t8, err_order;
wire [5:0]  mb_type, mb_cbp;
wire [15:0] mb_sub_types, mb_prev_flag, mb_nz;
wire [4:0]  mb_itype;
wire signed [7:0] mb_qp_delta;
wire [1:0]  mb_chroma_mode;
wire [47:0] mb_rem_mode;
wire [39:0] mb_refs;
wire [31:0]   mvd_q;
wire [31:0] mb_pred;
wire [3:0]  mb_direct8;
wire [26:0] mb_coded;
reg  [8:0]  coef_addr = 9'd0;
wire [1:0]  mb_cbank;
wire signed [15:0] coef_data;

mb_intake dut (
    .clk(clk), .rst_n(rst_n), .slice_type(slice_type), .num_ref_l0(num_ref_l0), .num_ref_l1(num_ref_l1),
    .in_valid(in_valid), .in_ready(in_ready), .in_kind(in_kind), .in_aux(in_aux), .in_val(in_val),
    .mb_valid(mb_valid), .mb_release(mb_release), .mb_addr(mb_addr), .mb_skip(mb_skip), .mb_type(mb_type),
    .mb_sub_types(mb_sub_types), .mb_is_intra(mb_is_intra), .mb_itype(mb_itype), .mb_cbp(mb_cbp),
    .mb_qp_delta(mb_qp_delta), .mb_chroma_mode(mb_chroma_mode), .mb_end_of_slice(mb_end_of_slice),
    .mb_prev_flag(mb_prev_flag), .mb_rem_mode(mb_rem_mode), .mb_refs(mb_refs), .mvd_ra(5'd0), .mvd_q(mvd_q), .mb_pred(mb_pred),
    .mb_direct8(mb_direct8), .mb_coded(mb_coded), .mb_nz(mb_nz), .mb_pcm(mb_pcm), .mb_t8(mb_t8),
    .mb_cbank(mb_cbank), .coef_bank(mb_cbank), .coef_addr(coef_addr), .coef_data(coef_data), .err_order(err_order));

reg  [47:0] mbw [0:MAXW-1];
reg  [31:0] dsc [0:MAXD-1];
reg  [31:0] meta [0:3];
string stem;
integer n_w, n_d, n_mbs, wi = 0, di = 0, n_mb = 0, stall = 0, n_coefs = 0;

always @(posedge clk) if (rst_n && err_order) `FAIL("err", "err_order")

// the word feeder: random gaps; slice inputs from the descriptor the next MB will be scored on
reg [31:0] next_hdr;
initial begin
    if (!$value$plusargs("stem=%s", stem)) begin $display("FAIL [harness] +stem="); $fatal(1); end
    void'($value$plusargs("stall=%d", stall));
    $readmemh({stem, ".meta.hex"}, meta);
    n_w = meta[0]; n_d = meta[1]; n_mbs = meta[2];
    $readmemh({stem, ".mbw.hex"}, mbw, 0, n_w - 1);
    $readmemh({stem, ".dsc.hex"}, dsc, 0, n_d - 1);
    #23 rst_n = 1'b1;
end
integer dsc_next = 0;           // index of the next MB's descriptor (for its slice inputs)
reg     mb_start_set = 1'b0;    // the presented MB_START's inputs are set (once per MB_START)
reg accepted = 1'b0;            // the presented word was taken at the last rising edge
always @(posedge clk) accepted <= in_valid && in_ready;
always @(negedge clk) if (rst_n) begin
    if (accepted) wi = wi + 1;
    if (wi < n_w && (stall == 0 || $urandom_range(0, stall) == 0)) begin
        in_valid = 1'b1; in_kind = mbw[wi][47:40]; in_aux = mbw[wi][39:32]; in_val = mbw[wi][15:0];
        // a macroblock's slice inputs: from its descriptor's header word, set at its MB_START
        if (mbw[wi][47:40] == 8'd1 && !mb_start_set) begin
            next_hdr = dsc[dsc_next];
            slice_type = next_hdr[13:12]; num_ref_l0 = next_hdr[11:6]; num_ref_l1 = next_hdr[5:0];
            dsc_next = dsc_next + 46 + dsc[dsc_next + 45];
            mb_start_set = 1'b1;
        end
        if (mbw[wi][47:40] != 8'd1) mb_start_set = 1'b0;
    end else begin
        in_valid = 1'b0;
    end
end

task automatic chk(input string what, input [31:0] got, input [31:0] want);
    if (got !== want) `FAIL("dsc", $sformatf("%s %h, want %h", what, got, want))
endtask

// the scorer
always @(posedge clk) if (rst_n && mb_valid && !mb_release) begin : score
    integer base, nc, k, sl, n;
    reg [31:0] w2;
    base = di;
    if (dsc[base][31:16] !== 16'hD5C0) `FAIL("harness", "descriptor out of step")
    w2 = dsc[base + 2];
    chk("addr", {18'd0, mb_addr}, dsc[base + 1]);
    chk("skip", mb_skip, w2[28]); chk("is_intra", mb_is_intra, w2[27]); chk("pcm", mb_pcm, w2[26]);
    chk("eos", mb_end_of_slice, w2[25]); chk("itype", mb_itype, w2[24:20]); chk("mb_type", mb_type, w2[19:14]);
    chk("cbp", mb_cbp, w2[13:8]); chk("chroma", mb_chroma_mode, w2[1:0]); chk("t8", mb_t8, w2[29]);
    chk("sub_types", mb_sub_types, dsc[base + 3][23:8]); chk("qp_delta", {24'd0, mb_qp_delta[7:0]}, {24'd0, dsc[base + 3][7:0]});
    chk("prev_flag", mb_prev_flag, dsc[base + 4]);
    chk("rem[31:0]", mb_rem_mode[31:0], dsc[base + 5]); chk("rem[47:32]", mb_rem_mode[47:32], dsc[base + 6]);
    chk("refs[31:0]", mb_refs[31:0], dsc[base + 7]); chk("refs[39:32]", mb_refs[39:32], dsc[base + 8]);
    // the mvd RAM (read hierarchically): every block that uses the list carries its
    // (sub-)partition's mvd; a block that does not is never read and not scored
    for (k = 0; k < 32; k = k + 1) if (dsc[base + 41][k]) chk($sformatf("mvd[%0d]", k), dut.mvd_ram[{dut.rb, k[4:0]}], dsc[base + 9 + k]);   // the output bank
    chk("pred", mb_pred, dsc[base + 41]); chk("direct8", mb_direct8, dsc[base + 42]);
    chk("coded", mb_coded, dsc[base + 43]); chk("nz", mb_nz, dsc[base + 44]);
    nc = dsc[base + 45];
    // the levels through the coefficient port
    k = 0;
    while (k < nc) begin
        sl = dsc[base + 46 + k][31:16]; n = dsc[base + 46 + k][15:0];
        for (integer p = 0; p < n; p = p + 1) begin
            @(negedge clk); coef_addr = (sl == 31) ? p : {sl[4:0], p[3:0]};
            @(posedge clk); #1;
            if (coef_data !== dsc[base + 47 + k + p][15:0])
                `FAIL("coef", $sformatf("slot %0d pos %0d: %0d, want %0d", sl, p, coef_data, $signed(dsc[base + 47 + k + p][15:0])))
            n_coefs = n_coefs + 1;
        end
        k = k + 1 + n;
    end
    di = base + 46 + nc;
    n_mb = n_mb + 1;
    repeat ($urandom_range(0, 3)) @(posedge clk);
    @(negedge clk); mb_release = 1'b1;
    @(negedge clk); mb_release = 1'b0;
    if (n_mb == n_mbs) begin
        repeat (5) @(posedge clk);
        if (di != n_d) `FAIL("count", $sformatf("descriptor words %0d of %0d", di, n_d))
        $display("mb_intake_tb: %0d macroblocks, %0d levels / samples read back (stall %0d)", n_mb, n_coefs, stall);
        $display("PASS: mb_intake_tb");
        $finish;
    end
end
initial begin #2_000_000_000; `FAIL("hang", "timeout") end

endmodule
