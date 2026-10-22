// bench/h264/f2sdram_term_tb.sv -- sys/f2sdram_safe_terminator.sv as the rig uses it: the
// last thing between the core's DDR3 master and the HPS f2sdram port, completing an open
// transaction on the core's behalf when Main resets the core to load another bitstream
// (docs/hil_harness.md "Facts that bite", the reload hang).
//
// The master is dpb_mem's shape: write bursts of 1-8 beats whose `write` DROPS between
// beats while the next beat is fetched (+gaps; legal Avalon), reads of 1-8 beats, no write
// while reads are outstanding; it never withdraws a request held under waitrequest (the
// fixed ddr_mux2). The core reset reaches it two clk_mem cycles BEFORE the terminator
// locks (emu takes RESET straight from sys_top; sysmem syncs it through two flops).
//
// Each of +locks=N (300) events: the master reset at an instant (a quarter aimed inside a
// write burst, a quarter each at a read and a write beat held under waitrequest), the
// terminator's rst_req_sync 0-2 cycles later, held 400 cycles, then:
//   [owed]  the slave (ddr_model, standing in for the HPS port) has no write burst left
//           open -- a burst short of its burstcount leaves the port waiting for beats,
//           and the next core's traffic is absorbed into it (the rig: writes accepted,
//           the first read never returned);
//   [ddr] / [avalon]  ddr_model's own rules on everything the terminator presents.
// Then both released, the master restarts, 50-400 cycles of traffic, the next event.
//   [cov]   enough locks caught a burst open, a held read and a held write beat.
// PASS marker: "PASS: f2sdram_term_tb".

`timescale 1ns/1ps
`default_nettype none

module f2sdram_term_tb;
    logic clk = 0;
    always #5.555 clk = ~clk;                 // clk_mem, 90 MHz

    int   n_locks;
    bit   gaps;
    initial begin
        gaps = $test$plusargs("gaps");
        if (!$value$plusargs("locks=%d", n_locks)) n_locks = 300;
    end

    // ---- the master (user logic) ----------------------------------------------------------
    logic        mrst = 1'b0;
    logic [28:0] m_addr;
    logic [7:0]  m_bc, m_be;
    logic        m_rd, m_wr;
    logic [63:0] m_wd;
    wire         s_wait, s_rdv;
    wire  [63:0] s_rdata;

    // ---- the terminator, then the port -----------------------------------------------------
    logic        rst_req_sync = 1'b0;
    wire  [28:0] p_addr;
    wire  [7:0]  p_bc, p_be;
    wire         p_rd, p_wr, p_wait, p_rdv;
    wire  [63:0] p_wd, p_rdata;
    // the terminator's address is 32 - log2(8) = 29 bits: word addresses, as sysmem wires it
    f2sdram_safe_terminator #(64, 8) term (
        .clk(clk), .rst_req_sync(rst_req_sync),
        .waitrequest_master(p_wait), .burstcount_master(p_bc), .address_master(p_addr),
        .readdata_master(p_rdata), .readdatavalid_master(p_rdv), .read_master(p_rd),
        .writedata_master(p_wd), .byteenable_master(p_be), .write_master(p_wr),
        .waitrequest_slave(s_wait), .burstcount_slave(m_bc), .address_slave(m_addr),
        .readdata_slave(s_rdata), .readdatavalid_slave(s_rdv), .read_slave(m_rd),
        .writedata_slave(m_wd), .byteenable_slave(m_be), .write_slave(m_wr)
    );
    int unwritten;
    ddr_model #(.AW(12)) ddr (
        .clk(clk), .rst_n(1'b1), .address(p_addr), .burstcount(p_bc), .read(p_rd), .write(p_wr),
        .writedata(p_wd), .byteenable(p_be), .waitrequest(p_wait), .readdata(p_rdata),
        .readdatavalid(p_rdv), .unwritten_reads(unwritten)
    );

    // dpb_mem's FSM, simplified: DECIDE -> READ (hold) | WR_BEAT (hold) -> WR_GAP -> ...
    typedef enum logic [1:0] {M_DECIDE, M_READ, M_WR_BEAT, M_WR_GAP} ms_t;
    ms_t  ms;
    int   want = 0, out_beats, beats_left, gap, n_wr_bursts, n_rd_bursts, n_gap_cycles;
    // read beats owed to the master: every burst the port accepted minus every beat back
    always_ff @(posedge clk)
        out_beats <= out_beats + ((m_rd && !s_wait) ? int'(m_bc) : 0) - (s_rdv ? 1 : 0);
    always_ff @(posedge clk) begin
        // a reset never withdraws a request the port is holding: finish that handshake first
        if (mrst && !((m_rd || m_wr) && s_wait)) begin
            ms <= M_DECIDE; m_rd <= 1'b0; m_wr <= 1'b0;
        end else case (ms)
            // the next operation is chosen once (1 in 3 a read), then waited for: a write
            // waits for the reads to drain (the ordering rule) and no read overtakes it
            M_DECIDE: if (!mrst) begin
                if (want == 0) want <= ($urandom % 3 == 0) ? 1 : 2;
                else if (want == 1) begin
                    want <= 0;
                    m_rd <= 1'b1; m_addr <= 29'h0600_0000 + ($urandom % 4000); m_bc <= 8'd1 + $urandom % 8;
                    ms <= M_READ;
                end else if (out_beats == 0) begin
                    want <= 0;
                    m_addr <= 29'h0600_0000 + ($urandom % 4000); m_bc <= 8'd1 + $urandom % 8;
                    beats_left <= 0;
                    m_wr <= 1'b1; m_wd <= {$urandom, $urandom}; m_be <= 8'hFF;
                    ms <= M_WR_BEAT;
                end
            end
            M_READ: if (!s_wait) begin
                m_rd <= 1'b0; n_rd_bursts <= n_rd_bursts + 1;
                ms <= M_DECIDE;
            end
            M_WR_BEAT: if (!s_wait) begin
                if (beats_left + 1 == m_bc) begin
                    m_wr <= 1'b0; n_wr_bursts <= n_wr_bursts + 1; ms <= M_DECIDE;
                end else begin
                    beats_left <= beats_left + 1;
                    gap = gaps ? ($urandom % 4) : 0;
                    if (gap == 0) m_wd <= {$urandom, $urandom};
                    else begin m_wr <= 1'b0; ms <= M_WR_GAP; end
                end
            end
            M_WR_GAP: begin
                n_gap_cycles <= n_gap_cycles + 1;
                if ($urandom % 2 == 0) begin m_wr <= 1'b1; m_wd <= {$urandom, $urandom}; ms <= M_WR_BEAT; end
            end
        endcase
    end
    initial begin ms = M_DECIDE; m_rd = 0; m_wr = 0; m_addr = 29'h0600_0000; m_bc = 1; m_be = 8'hFF; m_wd = 0;
                  out_beats = 0; beats_left = 0; n_wr_bursts = 0; n_rd_bursts = 0; n_gap_cycles = 0; end

    // +trace: every beat the port takes (the terminator's internals are not named: the
    // bench runs the stock module too, as its control arm)
    always @(posedge clk) if ($test$plusargs("trace") && (p_wr || p_rd) && !p_wait)
        $display("[%0t]   port %s a %h bc %0d be %h | slave rd %0d wr %0d | owed %0d, reads %0d",
                 $time, p_wr ? "W" : "R", p_addr, p_bc, p_be, m_rd, m_wr, ddr.wr_beats_left, ddr.outstanding);

    // ---- the lock events ------------------------------------------------------------------
    int mid_burst = 0, dly, guard;
    // what each lock caught (the cycle the terminator first sees its reset request)
    logic rst_q = 1'b0;
    int   lk_rd_held = 0, lk_wr_held = 0;
    always @(posedge clk) begin
        rst_q <= rst_req_sync;
        if (rst_req_sync && !rst_q) begin
            if (m_rd && p_wait) lk_rd_held++;
            if (m_wr && p_wait) lk_wr_held++;
        end
    end
    initial begin
        repeat (20) @(posedge clk);
        for (int k = 0; k < n_locks; k++) begin
            repeat (50 + $urandom % 350) @(posedge clk);
            // the events aimed: k % 4 == 0 inside a write burst (a random beat of it),
            // k % 4 == 1 at a read the port is holding off, k % 4 == 2 at a held write beat;
            // the rest anywhere. The reset
            // reaches the master 0-2 clk_mem cycles before the terminator locks (RESET is
            // asynchronous to clk_mem; emu takes it at once, sysmem through two flops).
            dly = 2;
            if (k % 4 == 0) begin
                guard = 0;
                while (ddr.wr_beats_left == 0 && guard < 5000) begin @(posedge clk); guard++; end
                repeat ($urandom % 3) @(posedge clk);
                dly = $urandom % 3;
            end else if (k % 4 == 1) begin
                guard = 0;
                while (!(m_rd && p_wait) && guard < 5000) begin @(posedge clk); guard++; end
                dly = 0;
            end else if (k % 4 == 2) begin
                guard = 0;
                while (!(m_wr && p_wait) && guard < 5000) begin @(posedge clk); guard++; end
                dly = 0;
            end
            if (ddr.wr_beats_left != 0) mid_burst++;
            if ($test$plusargs("trace")) $display("[%0t] lock %0d: mrst (ms %0d, wr_beats_left %0d, outstanding %0d)", $time, k, ms, ddr.wr_beats_left, ddr.outstanding);
            mrst <= 1'b1;
            repeat (dly) @(posedge clk);
            rst_req_sync <= 1'b1;
            repeat (400) @(posedge clk);
            if (ddr.wr_beats_left != 0) begin
                $display("FAIL [owed] lock %0d: the terminator left the port %0d beats short of a write burst (gaps %0d)",
                         k, ddr.wr_beats_left, gaps);
                $fatal(1);
            end
            rst_req_sync <= 1'b0;
            @(posedge clk);
            mrst <= 1'b0;
        end
        if (n_gap_cycles == 0 && gaps) begin $display("FAIL [cov] +gaps made no gap"); $fatal(1); end
        if (mid_burst < n_locks / 8 || lk_rd_held < n_locks / 40 || lk_wr_held < n_locks / 40) begin
            $display("FAIL [cov] of %0d locks: %0d inside a write burst, %0d on a held read, %0d on a held write beat",
                     n_locks, mid_burst, lk_rd_held, lk_wr_held); $fatal(1);
        end
        $display("  PASS term%s: %0d locks (%0d inside a write burst, %0d on a held read, %0d on a held write beat), %0d write bursts (%0d gap cycles), %0d read bursts, nothing owed",
                 gaps ? "_gaps" : "", n_locks, mid_burst, lk_rd_held, lk_wr_held, n_wr_bursts, n_gap_cycles, n_rd_bursts);
        $display("PASS: f2sdram_term_tb");
        $finish;
    end
endmodule

`default_nettype wire
