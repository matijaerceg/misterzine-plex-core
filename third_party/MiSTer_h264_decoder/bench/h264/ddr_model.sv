// bench/h264/ddr_model.sv -- an Avalon-MM burst slave standing in for the DDRAM port
//
// Backed by a window of 2**AW 64-bit words from word address BASE (Icarus has no
// associative arrays; an access outside the window is a $fatal), with byte enables on
// writes. Random waitrequest (+wait_pct), a random read latency per
// burst (+lat_min/+lat_max mclk cycles) with beats returned in order -- pipelined:
// several accepted read bursts can be in flight and return back to back, as the
// f2sdram bridge does. A write burst is accepted beat by beat (gaps allowed: `write`
// may drop between beats; address and burstcount are ignored after the first beat).
//
// Policing (each a $fatal, so a client violating the rules cannot pass a bench):
//   * a write beat accepted while read beats are outstanding (the ordering rule);
//   * a burst of more than 8 beats, or 0;
//   * a read accepted inside an open write burst (the burst was never completed);
//   * a read accepted while the response queue holds 256 beats (a client without credit);
//   * [avalon] a request WITHDRAWN or CHANGED while waitrequest held it: the master must
//     keep read / write, and on a burst's first beat address and burstcount, and on a
//     write writedata and byteenable, until the cycle it is accepted. A withdrawn request
//     is how the rig's HPS DDR3 port was left hung for good on a core reload
//     (docs/hil_harness.md "Facts that bite", 2026-09-26).
// `hits` counts words read that were never written (a client reading uninitialised
// memory gets X-free zeros but the count is visible to the bench).

`timescale 1ns/1ps
`default_nettype none

module ddr_model #(
    parameter [28:0] BASE = 29'h0600_0000,   // the core's DDR3 window (byte 0x30000000)
    parameter int    AW   = 18
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [28:0] address,
    input  wire [7:0]  burstcount,
    input  wire        read,
    input  wire        write,
    input  wire [63:0] writedata,
    input  wire [7:0]  byteenable,
    output logic       waitrequest,
    output logic [63:0] readdata,
    output logic       readdatavalid,
    output int         unwritten_reads
);

    logic [63:0] mem [0:(1<<AW)-1];
    logic        wrt [0:(1<<AW)-1];
    initial for (int i = 0; i < (1 << AW); i++) wrt[i] = 1'b0;

    function automatic int widx(input logic [28:0] a);
        if (a < BASE || a >= BASE + (1 << AW)) begin
            $display("FAIL [ddr] address %h outside the model's window", a); $fatal(1);
        end
        return int'(a - BASE);
    endfunction
    int wait_pct = 30, lat_min = 4, lat_max = 20;
    bit trace = 0;
    initial begin
        trace = $test$plusargs("ddr_trace");
        if (!$value$plusargs("wait_pct=%d", wait_pct)) wait_pct = 30;
        if (!$value$plusargs("lat_min=%d", lat_min)) lat_min = 4;
        if (!$value$plusargs("lat_max=%d", lat_max)) lat_max = 20;
    end

    // response queue: (address, earliest return cycle) per beat, returned in order; the
    // latency runs from ACCEPTANCE, so bursts in flight overlap as they do on the bridge
    logic [28:0] rq_addr [$];
    int          rq_delay [$];
    int          now = 0;
    int          outstanding = 0;
    int          wr_beats_left = 0;
    logic [28:0] wr_addr;
    int          timer = 0;
    logic [63:0] cur;

    // [avalon]: what was presented last cycle under waitrequest
    logic        p_valid = 1'b0, p_rd, p_wr, p_first;
    logic [28:0] p_a;
    logic [7:0]  p_bc, p_be;
    logic [63:0] p_wd;
    always @(posedge clk) begin
        if (!rst_n) p_valid <= 1'b0;
        else begin
            if (p_valid && (read !== p_rd || write !== p_wr ||
                            (p_first && (address !== p_a || burstcount !== p_bc)) ||
                            (p_wr && (writedata !== p_wd || byteenable !== p_be)))) begin
                $display("FAIL [avalon] a %0s request %0s while waitrequest held it (address %h, burst %0d)",
                         p_rd ? "read" : "write", (read || write) ? "changed" : "withdrawn", p_a, p_bc);
                $fatal(1);
            end
            p_valid <= (read || write) && waitrequest;
            p_rd <= read; p_wr <= write; p_a <= address; p_bc <= burstcount; p_wd <= writedata; p_be <= byteenable;
            p_first <= (wr_beats_left == 0);
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            waitrequest <= 1'b1; readdatavalid <= 1'b0; readdata <= '0; unwritten_reads <= 0;
            rq_addr.delete(); rq_delay.delete(); outstanding = 0; wr_beats_left = 0; timer = 0;
        end else begin
            // the wait line for the NEXT cycle (random)
            waitrequest <= ($urandom_range(0, 99) < wait_pct);
            readdatavalid <= 1'b0;
            now = now + 1;
            // accept commands / beats when not waiting
            if (!waitrequest) begin
                if (read) begin
                    if (burstcount == 8'd0 || burstcount > 8'd8) begin
                        $display("FAIL [ddr] burstcount %0d", burstcount); $fatal(1);
                    end
                    if (wr_beats_left != 0) begin
                        $display("FAIL [ddr] read accepted with %0d beats of a write burst to come", wr_beats_left); $fatal(1);
                    end
                    if (rq_addr.size() + burstcount > 256) begin
                        $display("FAIL [ddr] read accepted with %0d beats queued (no credit)", rq_addr.size()); $fatal(1);
                    end
                    if (trace) $display("ddr: R %h x%0d", address, burstcount);
                    begin
                        int due;
                        due = now + $urandom_range(lat_min, lat_max);
                        for (int i = 0; i < burstcount; i++) begin
                            rq_addr.push_back(address + i[28:0]);
                            rq_delay.push_back(due);
                        end
                    end
                    outstanding += burstcount;
                end else if (write) begin
                    if (outstanding != 0) begin
                        $display("FAIL [ddr] write accepted with %0d read beats outstanding", outstanding); $fatal(1);
                    end
                    if (wr_beats_left == 0) begin
                        if (burstcount == 8'd0 || burstcount > 8'd8) begin
                            $display("FAIL [ddr] write burstcount %0d", burstcount); $fatal(1);
                        end
                        wr_beats_left = burstcount;
                        wr_addr = address;
                    end
                    begin
                        int wi;
                        wi = widx(wr_addr);
                        cur = wrt[wi] ? mem[wi] : 64'd0;
                        for (int b = 0; b < 8; b++)
                            if (byteenable[b]) cur[8*b +: 8] = writedata[8*b +: 8];
                        mem[wi] = cur; wrt[wi] = 1'b1;
                        if (trace) $display("ddr: W %h be %h data %h (beat %0d of burst)", wr_addr, byteenable, cur, wr_beats_left);
                    end
                    wr_addr = wr_addr + 1'b1;
                    wr_beats_left = wr_beats_left - 1;
                end
            end
            // return one beat per cycle once its delay elapsed
            if (rq_addr.size() > 0) begin
                if (now < rq_delay[0]) begin
                    timer = timer + 1;
                end else begin
                    begin
                        int ri;
                        ri = widx(rq_addr[0]);
                        if (wrt[ri]) readdata <= mem[ri];
                        else begin readdata <= 64'd0; unwritten_reads <= unwritten_reads + 1; end
                    end
                    readdatavalid <= 1'b1;
                    rq_addr.pop_front(); rq_delay.pop_front();
                    outstanding -= 1;
                    timer = 0;
                end
            end
        end
    end

    // a backdoor for benches: load / read words directly
    function automatic void poke(input logic [28:0] a, input logic [63:0] d);
        mem[widx(a)] = d; wrt[widx(a)] = 1'b1;
    endfunction
    function automatic logic [63:0] peek(input logic [28:0] a);
        return wrt[widx(a)] ? mem[widx(a)] : 64'd0;
    endfunction
    function automatic bit written(input logic [28:0] a);
        return wrt[widx(a)];
    endfunction

endmodule

`default_nettype wire
