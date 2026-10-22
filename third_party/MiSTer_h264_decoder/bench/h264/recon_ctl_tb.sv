// bench/h264/recon_ctl_tb.sv -- the reconstruction's control path on a real SE stream:
// recon_hdr (parameter store, slice-header capture) -> recon_dpb (POC, marking, store
// allocation) -> recon_lists (the reference lists), fed the words the front end emits
// (tools/h264_top_golden.py's <stem>.se.hex: the model's record list as the RTL's
// words). No macroblock pipeline: pipe_idle is tied high and macroblock words are
// skipped, so this gates exactly the per-slice control state.
//
// At every slice_go the bench prints the state it must match, one line each:
//   S <n> new <0|1> store <s> struct <F|T|B> poc <p> ref <0|1>
//   L<x> <n_act> <entry>...        entry = <store><F|T|B>/<poc>/<marking> or "-"
//   D <store>:<mt><mb>/<poc_t>/<poc_b>/<lt> ...   (new pictures: the DPB after the
//                                                  previous picture's marking)
// and tools/recon_ctl_check.py compares the log with the model's --dump (store numbers
// are the fabric's, frame ids the model's: the checker keeps the mapping and requires
// it to be consistent). The bench itself fails ([hang], [err]) on a control path that
// stops or raises an error the stream does not justify.
//
// PASS marker: "PASS: recon_ctl_tb" (the bench's own arms); the log is then scored.
`timescale 1ns/1ps
module recon_ctl_tb;

import h264_pkg::*;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam MAXS = 1 << 22;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

// ---- the DUTs -------------------------------------------------------------------------
reg         se_valid = 1'b0;
reg  [7:0]  se_kind = 8'd0, se_aux = 8'd0;
reg  [31:0] se_val = 32'd0;
reg         hdr_end = 1'b0;

wire        slice_ready;
wire [SPS_W-1:0] sps;
wire [PPS_W-1:0] pps;
wire [13:0] sh_first_mb;
wire [1:0]  sh_slice_type, sh_nal_ref_idc, sh_disable_deblock;
wire        sh_idr, sh_field_pic, sh_bottom_field, sh_direct_spatial, sh_has_weights;
wire        sh_no_output_of_prior_pics, sh_long_term_reference, sh_adaptive_marking, sh_mmco5;
wire [15:0] sh_frame_num, sh_poc_lsb;
wire [31:0] sh_delta_poc_bottom, sh_delta_poc0, sh_delta_poc1;
wire [5:0]  sh_num_ref_l0, sh_num_ref_l1, sh_qp, sh_n_mods_l0, sh_n_mods_l1;
wire [2:0]  sh_luma_log2_wd, sh_chroma_log2_wd;
wire signed [4:0] sh_alpha_off, sh_beta_off;
wire [6:0]  sh_n_mmco;
wire [50:0] wt_data;
wire [6:0]  mod_addr;
wire [33:0] mod_data;
wire [5:0]  mmco_addr;
wire [66:0] mmco_data;
wire [7:0]  poc1_addr;
wire [31:0] poc1_data, poc1_total;
wire        err_no_pps, err_no_sps, err_poc1, err_mmco_ovf;

recon_hdr hdr (
    .clk(clk), .rst_n(rst_n), .clear(1'b0),
    .se_valid(se_valid), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val), .hdr_end(hdr_end),
    .slice_ready(slice_ready), .sps(sps), .pps(pps), .sh_first_mb(sh_first_mb), .sh_slice_type(sh_slice_type),
    .sh_nal_ref_idc(sh_nal_ref_idc), .sh_idr(sh_idr), .sh_frame_num(sh_frame_num), .sh_field_pic(sh_field_pic),
    .sh_bottom_field(sh_bottom_field), .sh_poc_lsb(sh_poc_lsb), .sh_delta_poc_bottom(sh_delta_poc_bottom),
    .sh_delta_poc0(sh_delta_poc0), .sh_delta_poc1(sh_delta_poc1), .sh_direct_spatial(sh_direct_spatial),
    .sh_num_ref_l0(sh_num_ref_l0), .sh_num_ref_l1(sh_num_ref_l1), .sh_luma_log2_wd(sh_luma_log2_wd),
    .sh_chroma_log2_wd(sh_chroma_log2_wd), .sh_has_weights(sh_has_weights),
    .sh_no_output_of_prior_pics(sh_no_output_of_prior_pics), .sh_long_term_reference(sh_long_term_reference),
    .sh_adaptive_marking(sh_adaptive_marking), .sh_mmco5(sh_mmco5), .sh_qp(sh_qp),
    .sh_disable_deblock(sh_disable_deblock), .sh_alpha_off(sh_alpha_off), .sh_beta_off(sh_beta_off),
    .sh_n_mods_l0(sh_n_mods_l0), .sh_n_mods_l1(sh_n_mods_l1), .sh_n_mmco(sh_n_mmco),
    .wt_addr(6'd0), .wt_data(wt_data), .mod_addr(mod_addr), .mod_data(mod_data),
    .mmco_addr(mmco_addr), .mmco_data(mmco_data), .poc1_addr(poc1_addr), .poc1_data(poc1_data), .poc1_total(poc1_total),
    .err_no_pps(err_no_pps), .err_no_sps(err_no_sps), .err_poc1(err_poc1), .err_mmco_ovf(err_mmco_ovf));

wire        pic_start, pic_new, lists_go, lists_done, slice_go, dpb_busy;
wire [4:0]  cur_store;
wire [1:0]  cur_struct;
wire        cur_isref;
wire signed [31:0] cur_poc;
wire [20*2-1:0]  st_ref_t, st_ref_b;
wire [19:0]      st_dec_t, st_dec_b, st_frame, st_busy;
wire [4:0]  tab_ra_lists;
wire signed [31:0] tab_q_poc_t, tab_q_poc_b, tab_q_fnw;
wire [20*5-1:0]  st_lt;
wire        err_gap, err_no_store, err_window, err_mmco, err_mod;

recon_dpb dpb (
    .clk(clk), .rst_n(rst_n), .clear(1'b0),
    .slice_ready(slice_ready), .sps(sps), .pps(pps), .sh_first_mb(sh_first_mb), .sh_slice_type(sh_slice_type),
    .sh_nal_ref_idc(sh_nal_ref_idc), .sh_idr(sh_idr), .sh_frame_num(sh_frame_num), .sh_field_pic(sh_field_pic),
    .sh_bottom_field(sh_bottom_field), .sh_poc_lsb(sh_poc_lsb), .sh_delta_poc_bottom(sh_delta_poc_bottom),
    .sh_delta_poc0(sh_delta_poc0), .sh_delta_poc1(sh_delta_poc1), .sh_long_term_reference(sh_long_term_reference),
    .sh_adaptive_marking(sh_adaptive_marking), .sh_mmco5(sh_mmco5), .sh_n_mmco(sh_n_mmco),
    .mmco_addr(mmco_addr), .mmco_data(mmco_data), .poc1_addr(poc1_addr), .poc1_data(poc1_data), .poc1_total(poc1_total),
    .pipe_idle(1'b1), .disp_hold(20'd0), .disp_frz(1'b0),
    .pic_start(pic_start), .pic_new(pic_new), .cur_store(cur_store), .cur_struct(cur_struct), .cur_isref(cur_isref),
    .cur_poc(cur_poc), .lists_go(lists_go), .lists_done(lists_done), .slice_go(slice_go), .busy(dpb_busy),
    .st_ref_t(st_ref_t), .st_ref_b(st_ref_b), .st_dec_t(st_dec_t), .st_dec_b(st_dec_b), .st_lt(st_lt), .st_frame(st_frame), .st_busy(st_busy),
    .tab_ra_lists(tab_ra_lists), .tab_ra_slice(5'd0), .tab_q_poc_t(tab_q_poc_t), .tab_q_poc_b(tab_q_poc_b), .tab_q_fnw(tab_q_fnw),
    .err_gap(err_gap), .err_no_store(err_no_store), .err_window(err_window), .err_mmco(err_mmco));

sps_t sps_s;
assign sps_s = sps;
reg  [5:0]  rd0_idx = 6'd0, rd1_idx = 6'd0;
wire [7:0]  rd0_entry, rd1_entry;
recon_lists lists (
    .clk(clk), .rst_n(rst_n), .go(lists_go), .done(lists_done),
    .slice_type(sh_slice_type), .field_pic(sh_field_pic), .bottom(sh_bottom_field), .cur_store(cur_store),
    .cur_poc(cur_poc), .frame_num(sh_frame_num), .log2_max_frame_num(sps_s.log2_max_frame_num_minus4 + 4'd4),
    .num_ref_l0(sh_num_ref_l0), .num_ref_l1(sh_num_ref_l1), .n_mods_l0(sh_n_mods_l0), .n_mods_l1(sh_n_mods_l1),
    .mod_addr(mod_addr), .mod_data(mod_data),
    .st_ref_t(st_ref_t), .st_ref_b(st_ref_b), .st_dec_t(st_dec_t), .st_dec_b(st_dec_b), .st_lt(st_lt),
    .tab_ra(tab_ra_lists), .tab_q_poc_t(tab_q_poc_t), .tab_q_poc_b(tab_q_poc_b), .tab_q_fnw(tab_q_fnw),
    .rd0_idx(rd0_idx), .rd0_entry(rd0_entry), .rd1_idx(rd1_idx), .rd1_entry(rd1_entry), .err_mod(err_mod));

// ---- the fixture -----------------------------------------------------------------------
reg  [47:0] se_m [0:MAXS-1];
reg  [31:0] meta [0:15];
string      stem;
integer     n_se, si, n_slices = 0, n_err = 0;
reg         in_hdr = 1'b0;                       // header words seen since the last MB words

// errors are counted (an expected-error stream would say so in its meta; none do here)
always @(posedge clk) if (rst_n && (err_no_pps || err_no_sps || err_poc1 || err_mmco_ovf || err_gap ||
                                    err_no_store || err_window || err_mmco || err_mod)) begin
    $display("ERR pps %0d sps %0d poc1 %0d mmco_ovf %0d gap %0d no_store %0d window %0d mmco %0d mod %0d",
             err_no_pps, err_no_sps, err_poc1, err_mmco_ovf, err_gap, err_no_store, err_window, err_mmco, err_mod);
    n_err = n_err + 1;
end

function automatic string sname(input [1:0] st);
    return (st == 2'd0) ? "F" : (st == 2'd1) ? "T" : "B";
endfunction
function automatic integer store_poc(input [4:0] s, input [1:0] st);
    integer t, b;
    t = $signed(dpb.poc_t_m[s]); b = $signed(dpb.poc_b_m[s]);
    return (st == 2'd1) ? t : (st == 2'd2) ? b : ((t < b) ? t : b);
endfunction
function automatic integer store_mark(input [4:0] s, input [1:0] st);
    integer t, b;
    t = st_ref_t[2*s +: 2]; b = st_ref_b[2*s +: 2];
    return (st == 2'd1) ? t : (st == 2'd2) ? b : ((t == b) ? t : 0);
endfunction

task automatic dump_slice(input bit newp);
    string line;
    integer n;
    line = $sformatf("S %0d new %0d store %0d struct %s poc %0d ref %0d", n_slices, newp, cur_store, sname(cur_struct), cur_poc, cur_isref);
    $display("%s", line);
    if (newp) begin
        line = "D";
        for (int s = 0; s < 20; s++) begin
            if (st_ref_t[2*s +: 2] != 2'd0 || st_ref_b[2*s +: 2] != 2'd0)
                line = {line, $sformatf(" %0d:%0d%0d/%0d/%0d", s, st_ref_t[2*s +: 2], st_ref_b[2*s +: 2],
                                        (st_ref_t[2*s +: 2] != 0) ? $signed(dpb.poc_t_m[s]) : 0,
                                        (st_ref_b[2*s +: 2] != 0) ? $signed(dpb.poc_b_m[s]) : 0)};
        end
        $display("%s", line);
    end
    if (sh_slice_type != 2'd2) begin
        for (int l = 0; l < 2; l++) begin
            if (l == 1 && sh_slice_type != 2'd1) continue;
            n = (l == 0) ? sh_num_ref_l0 : sh_num_ref_l1;
            line = $sformatf("L%0d %0d", l, n);
            for (int e = 0; e < n; e++) begin
                logic [7:0] ent;
                // the lists' RAMs, read hierarchically (the ports are registered reads)
                ent = (l == 0) ? lists.lm0[e] : lists.lm1[e];
                if (!ent[7]) line = {line, " -"};
                else line = {line, $sformatf(" %0d%s/%0d/%0d", ent[6:2], sname(ent[1:0]), store_poc(ent[6:2], ent[1:0]),
                                             store_mark(ent[6:2], ent[1:0]))};
            end
            $display("%s", line);
        end
    end
endtask

integer wait_cyc;
initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "+stem= missing")
    $readmemh({stem, ".meta.hex"}, meta);
    // the control words only (NAL, header, MB_START): the runner filters <stem>.se.hex
    if (!$value$plusargs("n_ctl=%d", n_se)) `FAIL("harness", "+n_ctl= missing")
    $readmemh({stem, ".ctl.hex"}, se_m, 0, n_se - 1);
    #23 rst_n = 1'b1;
    @(negedge clk);
    for (si = 0; si < n_se; si = si + 1) begin
        logic [7:0] k;
        k = se_m[si][47:40];
        if (k == 8'd17 || k == 8'd18) begin
            se_valid = 1'b1; se_kind = k; se_aux = se_m[si][39:32]; se_val = se_m[si][31:0];
            @(negedge clk);
            se_valid = 1'b0;
            if (k == 8'd18) in_hdr = 1'b1;
            if (k == 8'd17) in_hdr = (se_m[si][36:32] == 5'd1 || se_m[si][36:32] == 5'd5) ? 1'b0 : in_hdr;
        end else if (k == 8'd1 && in_hdr) begin
            // the first macroblock of a slice: the header is complete
            bit newp;
            in_hdr = 1'b0;
            hdr_end = 1'b1;
            @(negedge clk);
            hdr_end = 1'b0;
            wait_cyc = 0;
            while (!slice_go) begin
                @(negedge clk);
                wait_cyc = wait_cyc + 1;
                if (wait_cyc > 20000) `FAIL("hang", $sformatf("slice %0d: no slice_go", n_slices))
            end
            newp = pic_new;
            dump_slice(newp);
            n_slices = n_slices + 1;
        end
        // other macroblock words: skipped (no pipeline in this bench)
    end
    // a trailing NAL word closes the last parameter set / slice for recon_hdr
    se_valid = 1'b1; se_kind = 8'd17; se_aux = 8'd9; se_val = 32'd0;
    @(negedge clk); se_valid = 1'b0;
    repeat (10) @(negedge clk);
    if (n_slices != meta[3]) `FAIL("count", $sformatf("%0d slices, the stream has %0d", n_slices, meta[3]))
    $display("recon_ctl_tb: %0d slices, %0d error pulses", n_slices, n_err);
    $display("PASS: recon_ctl_tb");
    $finish;
end

endmodule
