// h264/ddr_probe.sv -- a passive watcher on one Avalon-MM DDR3 port (harvested from UMD's
// umd/ddr_probe.sv at cc595c6, class S: the beat counters widened to 32 bits for
// the status block's words; docs/harvest.md). Here it watches ram1 (the DPB and the ring
// reader share it: docs/hw_budget_and_lessons.md S2) and its counts are status words 13
// and 28-29 (tools/ring_layout.py). UMD's note: what the HPS f2sdram port sees at emu's
// DDRAM* / DDRAM2* wires. Built after the P5e rig round (2026-09-26): a freeze that followed the
// RIG, not the build (the previous build froze identically; a reboot cured it), with no
// instrument that could say whether the core had stopped issuing, the port was refusing,
// or read beats never came back. These counters tell the three apart:
//   wr_beats   write beats accepted (write && !waitrequest), 32-bit (wraps)
//   rd_beats   read beats returned (readdatavalid), 32-bit (wraps)
//   owed       read beats accepted but not yet returned (sum of accepted burstcounts
//              minus returned beats; saturating at both ends)
//   busy       the current run of cycles with a request held under waitrequest
//              (saturating: 0xFFFF = at least 0.73 ms at 90 MHz -- a hang)
//   busy_max   the longest such run since reset (saturating)
// It only observes: no output reaches the port. clk_mem; the status block reads it through
// h264/ring_stat.sv's clk_mem snapshot.

`default_nettype none

module ddr_probe (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         read,
    input  wire         write,
    input  wire  [7:0]  burstcount,
    input  wire         waitrequest,
    input  wire         readdatavalid,
    output logic [31:0] wr_beats,
    output logic [31:0] rd_beats,
    output logic [15:0] owed,
    output logic [15:0] busy,
    output logic [15:0] busy_max
);
    wire req = read || write;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_beats <= '0; rd_beats <= '0; owed <= '0; busy <= '0; busy_max <= '0;
        end else begin
            if (write && !waitrequest) wr_beats <= wr_beats + 32'd1;
            if (readdatavalid) rd_beats <= rd_beats + 32'd1;
            // beats owed: + the accepted burst, - a returned beat (never below 0, never wraps)
            begin : owed_upd
                logic [16:0] o;
                o = {1'b0, owed};
                if (read && !waitrequest) o = o + {9'd0, burstcount};
                if (readdatavalid && o != 17'd0) o = o - 17'd1;
                owed <= (o > 17'h0FFFF) ? 16'hFFFF : o[15:0];
            end
            // the BUSY run: a request held under waitrequest
            if (req && waitrequest) begin
                if (busy != 16'hFFFF) busy <= busy + 16'd1;
                if (busy >= busy_max && busy_max != 16'hFFFF) busy_max <= busy + ((busy != 16'hFFFF) ? 16'd1 : 16'd0);
            end else busy <= '0;
        end
    end
endmodule

`default_nettype wire
