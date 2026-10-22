// h264/dec/dpb_mem.sv -- the DPB's DDR3 client: burst reads and writes on the DDRAM
// (f2sdram) port from the clk_dec domain (docs/h264_recon.md S2.2)
//
// clk side (the reconstruction): a command stream (write flag, 64-bit-word address,
// 1..8 beats), a write-data stream (one 64-bit word + byte enables per beat, in
// command order, allowed to arrive after its command) and a read-data stream (the
// beats of every read, in command order). mclk side: one Avalon-MM burst master
// (through umd/ddr_arb.sv's priority port in emu).
//
// The two rules MiSTer_DVD's bridge earned on this board (dvd/mem_shim_burst.sv):
//   * a WRITE is never issued while a read burst's beats are outstanding (strictly
//     in order: the write waits for `outstanding == 0`);
//   * a read is issued only with room for every beat it will return -- the credit
//     is the read FIFO's free count as its (mclk) write side sees it, minus the
//     beats already outstanding -- so readdatavalid never meets a full FIFO.
// Reads may pipeline (several bursts in flight; the bridge returns beats in order).
// A write burst presents address + burstcount on every beat and may GAP (write
// dropped between beats while the data FIFO is empty); ddr_arb pins the grant.
//
// Three dual-clock FIFOs (h264/fifo_dc.sv): commands and write data clk -> mclk, read
// data mclk -> clk. Each is popped with its one-word-in-flight pull discipline.

`default_nettype none

module dpb_mem (
    // ---- clk_dec side --------------------------------------------------------------
    input  wire         clk,
    input  wire         rst_n,
    input  wire         cmd_valid,
    output logic        cmd_ready,
    input  wire         cmd_write,
    input  wire  [28:0] cmd_addr,          // 64-bit word address on the DDRAM port
    input  wire  [3:0]  cmd_len,           // beats, 1..8
    input  wire         wd_valid,
    output logic        wd_ready,
    input  wire  [63:0] wd_data,
    input  wire  [7:0]  wd_be,
    output logic        rd_valid,          // held with rd_data until rd_ready
    output logic [63:0] rd_data,
    input  wire         rd_ready,
    output logic [31:0] stat_reads,        // bursts issued (mclk counters, read raw: liveness only)
    output logic [31:0] stat_writes,       // write bursts completed (the bench: "every write landed")
    output logic        wr_drained,        // (clk) every write burst taken has been ACCEPTED by the
                                           // f2sdram port (its last beat); a picture is done only then

    // ---- mclk side: the Avalon-MM burst master ----------------------------------------
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid
);

    localparam int RD_AW = 6;              // 64 read beats buffered

    // ---- command FIFO (clk -> mclk) --------------------------------------------------
    wire        cf_full, cf_empty, cf_valid;
    wire [33:0] cf_dout;
    logic       cf_rd;
    assign cmd_ready = !cf_full;
    fifo_dc #(.DW(34), .AW(4)) cf (
        .wr_clk(clk), .wr_rst_n(rst_n), .din({cmd_write, cmd_addr, cmd_len}), .wr_en(cmd_valid && !cf_full),
        .full(cf_full), .wr_free(),
        .rd_clk(mclk), .rd_rst_n(mrst_n), .dout(cf_dout), .rd_en(cf_rd), .empty(cf_empty), .valid(cf_valid));

    // ---- write-data FIFO (clk -> mclk) -----------------------------------------------
    wire        wf_full, wf_empty, wf_valid;
    wire [71:0] wf_dout;
    logic       wf_rd;
    assign wd_ready = !wf_full;
    fifo_dc #(.DW(72), .AW(6)) wf (
        .wr_clk(clk), .wr_rst_n(rst_n), .din({wd_be, wd_data}), .wr_en(wd_valid && !wf_full),
        .full(wf_full), .wr_free(),
        .rd_clk(mclk), .rd_rst_n(mrst_n), .dout(wf_dout), .rd_en(wf_rd), .empty(wf_empty), .valid(wf_valid));

    // ---- read-data FIFO (mclk -> clk) ------------------------------------------------
    wire            rf_full, rf_empty, rf_valid;
    wire [RD_AW:0]  rf_free;
    wire [63:0]     rf_dout;
    logic           rf_rd;
    fifo_dc #(.DW(64), .AW(RD_AW)) rf (
        .wr_clk(mclk), .wr_rst_n(mrst_n), .din(ddr_readdata), .wr_en(ddr_readdatavalid),
        .full(rf_full), .wr_free(rf_free),
        .rd_clk(clk), .rd_rst_n(rst_n), .dout(rf_dout), .rd_en(rf_rd), .empty(rf_empty), .valid(rf_valid));

    // the clk-side read port: a two-entry skid (rd_data is the head, rd_sk1 behind it);
    // a pull is issued only when the skid will have room when the word lands, so a
    // beat can leave every cycle (the same shape as h264/sfifo.sv)
    // (fifo_dc's empty is registered from the advanced pointer, so a pull every cycle
    // is safe: the only word in flight is the one visible as rf_valid this cycle)
    logic [1:0]  rsk_n;
    logic [63:0] rd_sk1;
    wire         rd_pop = rd_valid && rd_ready;
    wire  [2:0]  rsk_after = {1'b0, rsk_n} - {2'b0, rd_pop} + {2'b0, rf_valid};
    assign rf_rd = !rf_empty && (rsk_after <= 3'd1);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid <= 1'b0; rd_data <= '0; rd_sk1 <= '0; rsk_n <= 2'd0;
        end else begin
            case ({rf_valid, rd_pop})
                2'b10: begin
                    if (rsk_n == 2'd0) rd_data <= rf_dout; else rd_sk1 <= rf_dout;
                    rsk_n <= rsk_n + 2'd1;
                end
                2'b01: begin
                    rd_data <= rd_sk1;
                    rsk_n <= rsk_n - 2'd1;
                end
                2'b11: begin
                    if (rsk_n == 2'd1) rd_data <= rf_dout;
                    else begin rd_data <= rd_sk1; rd_sk1 <= rf_dout; end
                end
                default: ;
            endcase
            rd_valid <= (rsk_n + {1'b0, rf_valid} - {1'b0, rd_pop}) != 2'd0;
        end
    end

    // ---- wr_drained: the write bursts taken (clk) against those completed (mclk), the
    // latter's count crossing back as a gray code (it steps by one; two flops). The
    // streamed writeback (exp/mb-pipeline) queues writes here faster than the port
    // drains them: "every command issued" is no longer "every write landed", and a
    // picture emitted to the display before its last rows land is read torn
    // (recon_top_tb [hold] found it). What it proves: ram1's port took every beat. It does
    // not prove the SDRAM controller committed them before a later ram2 read of the same
    // rows (the ports are not ordered against each other); the display reads a store at a
    // refresh boundary, milliseconds after the picture is done, which is the margin relied
    // on there (a read-back fence on ram1 would be the strict guarantee)
    logic [7:0]  wp_cnt;                   // clk: write commands taken
    logic [7:0]  wl_cnt, wl_g;             // mclk: write bursts completed, its gray code
    logic [7:0]  wl_s1, wl_s2, wl_b;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wp_cnt <= '0; wl_s1 <= '0; wl_s2 <= '0; wr_drained <= 1'b1; end
        else begin
            if (cmd_valid && !cf_full && cmd_write) wp_cnt <= wp_cnt + 8'd1;
            wl_s1 <= wl_g; wl_s2 <= wl_s1;
            wr_drained <= (wl_b == wp_cnt) && !(cmd_valid && cmd_write);
        end
    end
    always_comb begin
        wl_b[7] = wl_s2[7];
        for (int i = 6; i >= 0; i--) wl_b[i] = wl_b[i + 1] ^ wl_s2[i];
    end

    // ---- the mclk master -------------------------------------------------------------
    // the next command is prefetched into c_* while the current one is being issued, so
    // pipelined reads cost about two mclk cycles each and not the FIFO's pull latency
    typedef enum logic [2:0] {M_DECIDE, M_READ, M_WR_FETCH, M_WR_BEAT} mstate_t;
    mstate_t     ms;
    logic        c_valid;                  // c_* hold a command not yet issued
    logic        c_write;
    logic [28:0] c_addr;
    logic [3:0]  c_len;
    logic [3:0]  beats_left;
    logic [RD_AW+1:0] outstanding;         // read beats issued and not yet returned
    logic        cf_pending;
    // exp/mb-pipeline: the write data streams -- a two-word skid (wsk*) pulled from the data
    // FIFO every cycle it has room (the FIFO's pull discipline: the word in flight is the one
    // visible as wf_valid), so an accepted beat is followed by the next in the next cycle
    // (it fetched each beat after the last was accepted: ~3.5 mclk a beat, which bounded the
    // streamed writeback at ~260 clk_dec cycles a macroblock)
    logic [1:0]  wsk_n;
    logic [71:0] wsk0, wsk1;
    logic        w_load;                   // a word moves to ddr_writedata this cycle
    wire         w_have = (wsk_n != 2'd0) || wf_valid;
    wire  [71:0] w_next = (wsk_n != 2'd0) ? wsk0 : wf_dout;
    always_comb w_load = ((ms == M_WR_FETCH) && w_have) ||
                         ((ms == M_WR_BEAT) && !ddr_waitrequest && (beats_left != 4'd1) && w_have);
    wire  [2:0]  wsk_after = {1'b0, wsk_n} + {2'd0, wf_valid} - {2'd0, w_load};
    assign wf_rd = !wf_empty && (wsk_after <= 3'd1);

    wire [RD_AW+1:0] rf_free_w = {1'b0, rf_free};
    wire credit_ok = (outstanding + {{(RD_AW-2){1'b0}}, c_len}) <= rf_free_w;
    wire c_consume = (ms == M_DECIDE) && c_valid &&
                     (!c_write ? credit_ok : (outstanding == '0 && !ddr_readdatavalid));

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            ms <= M_DECIDE; cf_rd <= 1'b0; cf_pending <= 1'b0; wsk_n <= '0; wsk0 <= '0; wsk1 <= '0;
            ddr_read <= 1'b0; ddr_write <= 1'b0; ddr_address <= '0; ddr_burstcount <= 8'd1;
            ddr_writedata <= '0; ddr_byteenable <= 8'hFF;
            c_valid <= 1'b0; c_write <= 1'b0; c_addr <= '0; c_len <= 4'd1; beats_left <= '0;
            outstanding <= '0; stat_reads <= '0; stat_writes <= '0; wl_cnt <= '0; wl_g <= '0;
        end else begin
            cf_rd <= 1'b0;
            wl_g <= wl_cnt ^ (wl_cnt >> 1);
            // the skid: a word loaded into ddr_writedata leaves it (or bypasses it)
            if (w_load && wsk_n != 2'd0) begin
                wsk0 <= (wsk_n == 2'd2) ? wsk1 : wf_dout;
                if (wsk_n == 2'd2 && wf_valid) wsk1 <= wf_dout;
            end else if (!w_load && wf_valid) begin
                if (wsk_n == 2'd0) wsk0 <= wf_dout; else wsk1 <= wf_dout;
            end
            wsk_n <= wsk_after[1:0];
            cf_pending <= cf_rd;
            // the command prefetch: pull when c_* is free or being consumed this cycle
            if (cf_valid) begin
                {c_write, c_addr, c_len} <= cf_dout;
                c_valid <= 1'b1;
            end else if (c_consume) begin
                c_valid <= 1'b0;
            end
            if (!cf_empty && !cf_rd && !cf_pending && (!c_valid || c_consume)) cf_rd <= 1'b1;
            // read beats returning
            if (ddr_readdatavalid) outstanding <= outstanding - 1'b1;
            case (ms)
                M_DECIDE: begin                       // c_consume: the one issue condition
                    if (c_consume && !c_write) begin
                        ddr_read <= 1'b1; ddr_address <= c_addr; ddr_burstcount <= {4'd0, c_len};
                        ms <= M_READ;
                    end else if (c_consume) begin
                        beats_left <= c_len;
                        ddr_address <= c_addr; ddr_burstcount <= {4'd0, c_len};
                        ms <= M_WR_FETCH;
                    end
                end
                M_READ: begin                         // hold until accepted
                    if (!ddr_waitrequest) begin
                        ddr_read <= 1'b0;
                        outstanding <= outstanding + {{(RD_AW-2){1'b0}}, ddr_burstcount[3:0]} - {{(RD_AW+1){1'b0}}, ddr_readdatavalid};
                        stat_reads <= stat_reads + 1'b1;
                        ms <= M_DECIDE;
                    end
                end
                M_WR_FETCH: begin                     // the next beat, from the skid or the FIFO
                    if (w_have) begin
                        ddr_writedata <= w_next[63:0]; ddr_byteenable <= w_next[71:64];
                        ddr_write <= 1'b1;
                        ms <= M_WR_BEAT;
                    end
                end
                M_WR_BEAT: begin                      // hold until accepted; the next beat follows at once
                    if (!ddr_waitrequest) begin
                        if (beats_left == 4'd1) begin
                            ddr_write <= 1'b0;
                            stat_writes <= stat_writes + 1'b1;
                            wl_cnt <= wl_cnt + 8'd1;
                            ms <= M_DECIDE;
                        end else begin
                            beats_left <= beats_left - 1'b1;
                            if (w_have) begin ddr_writedata <= w_next[63:0]; ddr_byteenable <= w_next[71:64]; end
                            else begin ddr_write <= 1'b0; ms <= M_WR_FETCH; end
                        end
                    end
                end
                default: ms <= M_DECIDE;
            endcase
        end
    end

endmodule

`default_nettype wire
