// h264/ddr_mux2.sv -- two burst masters on one DDRAM (f2sdram) port: A reads and writes
// (the DPB client); B reads and writes (P6a: the compressed-video buffer, h264/vbuf.sv --
// until then B only read: the P4 display smoke reader)
//
// Why not umd/ddr_arb.sv: its second master is write-only (MiSTer_DVD's audio writer);
// the display needs reads, whose responses must be routed back to their owner. The P5
// display moves to its own port (ram2, docs/hw_budget_and_lessons.md S2: a second read
// master costs the decoder arbitration occupancy); for P4's decode-order smoke picture
// sharing ram1 is enough, and this mux keeps the port's rules:
//   * one command channel: only the granted master drives it, the other sees waitrequest;
//   * a write burst keeps the grant until its last beat is accepted (beats may gap);
//   * NO write is issued while any read beat is outstanding -- the rule MiSTer_DVD's
//     bridge earned on this board (dvd/mem_shim_burst.sv) held for the port, not per
//     master: A's write waits for B's reads too;
//   * read responses return in command order: a FIFO of (owner, beats) per accepted read
//     burst routes readdatavalid to the owner at its head.
// Fairness: after each command A has accepted, B takes the channel if it is waiting (so a
// display line fetch never waits behind a whole macroblock of window reads) -- and also
// while A presents a write that is waiting for the reads to drain (else B would wait out
// the whole read latency) -- once per blocked write (b_cut), so B's reads cannot keep
// re-blocking A's write for ever.
// Abort (a_abort, level, clk-synchronous): A's master is being reset (a mount). The port
// must not be left inside a write burst -- the controller would wait for its beats
// forever -- nor may A's outstanding read beats reach the master once it runs again. So
// while aborting and until the port is clean: A's commands are not presented (A sees
// waitrequest), the rest of an open write burst is completed with byteenable 0 (writes
// of nothing), and A's read beats are swallowed. `a_flush` ends when no write burst is
// open and no A read is outstanding, after a_abort has dropped.
// A REQUEST IS NEVER WITHDRAWN (2026-09-26): a command the port held off with waitrequest
// is presented again, unchanged, until the port accepts it -- even when A withdraws it
// (A's master is reset: a mount, or the core RESET on a reload, both of which the abort
// follows a couple of cycles later). Avalon forbids withdrawing, and the rig showed what
// it costs: loading a title over a playing one left the HPS f2sdram port hung for good
// (it returned no read beat again, BUSY forever) about 1 in 8 times, until a reboot
// (docs/hil_harness.md "Facts that bite"). Such an ORPHAN is completed on A's behalf: a
// read's beats are swallowed by the flush (a_out counts it); a write beat goes out exactly
// as presented -- A's own data (changing even its byte enables under waitrequest is the
// same violation) -- and the rest of its burst then completes masked, as above.
// The mux itself is reset only with the PLL (emu), never by RESET or a mount: the
// requests it holds must survive both.
// B WRITES (P6a, 2026-09-27): a B write burst pins the grant as A's does (b_wburst), obeys
// the same port rule (no write while any read beat is outstanding: b_wr_blocked), and a
// B write blocked on reads HOLDS the grant until they drain -- releasing it would hand A
// the channel to add reads and re-block B for ever. A waits at most one read latency.
// B has NO abort: its master (vbuf) never withdraws a command -- on a mount it finishes
// the command it presents and only then clears (vbuf.sv). A request B withdrew would be an
// Avalon violation the benches' ddr_model reports ([avalon]).

`default_nettype none

module ddr_mux2 (
    input  wire         clk,
    input  wire         rst_n,

    input  wire  [28:0] a_address,
    input  wire  [7:0]  a_burstcount,
    input  wire         a_read,
    input  wire         a_write,
    input  wire  [63:0] a_writedata,
    input  wire  [7:0]  a_byteenable,
    input  wire         a_abort,
    output logic        a_waitrequest,
    output logic [63:0] a_readdata,
    output logic        a_readdatavalid,

    input  wire  [28:0] b_address,
    input  wire  [7:0]  b_burstcount,
    input  wire         b_read,
    input  wire         b_write,
    input  wire  [63:0] b_writedata,
    output logic        b_waitrequest,
    output logic [63:0] b_readdata,
    output logic        b_readdatavalid,

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

    logic        grant;                    // 0 A, 1 B
    logic [7:0]  a_wburst;                 // A's write beats still to come (grant pinned)
    logic        a_flush;                  // aborting: A's view of the port is closed
    logic [4:0]  a_out;                    // A's read bursts outstanding
    logic        b_cut;                    // B already cut in ahead of A's blocked write
    logic [7:0]  b_wburst;                 // B's write beats still to come (grant pinned)
    // the A command the port held off last cycle (Avalon: re-presented until accepted)
    logic        h_valid, h_rd, h_wr;
    logic [28:0] h_a;
    logic [7:0]  h_bc, h_be;
    logic [63:0] h_wd;
    wire         a_same  = (a_read == h_rd) && (a_write == h_wr) && (a_address == h_a) &&
                           (a_burstcount == h_bc) && (!h_wr || (a_writedata == h_wd && a_byteenable == h_be));
    wire         orphan  = h_valid && !grant && (a_flush || !a_same);   // A no longer presents it

    // the read-owner FIFO: one entry per accepted read burst
    logic        own [0:15];
    logic [7:0]  own_n [0:15];
    logic [3:0]  o_wr, o_rd;
    logic [4:0]  o_cnt;
    logic [7:0]  head_left;                // beats of the head burst still to return
    wire         reads_out = (o_cnt != 5'd0);
    wire         own_full  = o_cnt[4];     // 16 read bursts outstanding: no more reads

    // the command channel
    wire a_wr_blocked = a_write && (a_wburst == 8'd0) && reads_out;   // a new write waits for the reads
    wire b_wr_blocked = b_write && (b_wburst == 8'd0) && reads_out;
    wire b_req        = b_read || b_write;
    always_comb begin
        if (orphan) begin
            // the held-off command, again, until accepted: A has withdrawn it (see above)
            ddr_address = h_a; ddr_burstcount = h_bc;
            ddr_read = h_rd; ddr_write = h_wr;
            ddr_writedata = h_wd; ddr_byteenable = h_be;
            a_waitrequest = 1'b1;
            b_waitrequest = 1'b1;
        end else if (!grant && a_flush) begin
            // only the rest of an open write burst, masked
            ddr_address = a_address; ddr_burstcount = a_burstcount;
            ddr_read = 1'b0;
            ddr_write = (a_wburst != 8'd0);
            ddr_writedata = a_writedata; ddr_byteenable = 8'h00;
            a_waitrequest = 1'b1;
            b_waitrequest = 1'b1;
        end else if (!grant) begin
            ddr_address = a_address; ddr_burstcount = a_burstcount;
            ddr_read = a_read && (a_wburst == 8'd0) && !own_full;
            ddr_write = a_write && !a_wr_blocked;
            ddr_writedata = a_writedata; ddr_byteenable = a_byteenable;
            a_waitrequest = ddr_waitrequest || a_wr_blocked || (a_read && (a_wburst != 8'd0 || own_full));
            b_waitrequest = 1'b1;
        end else begin
            ddr_address = b_address; ddr_burstcount = b_burstcount;
            ddr_read = b_read && (b_wburst == 8'd0) && !own_full;
            ddr_write = b_write && !b_wr_blocked;
            ddr_writedata = b_writedata; ddr_byteenable = 8'hFF;
            a_waitrequest = 1'b1;
            b_waitrequest = ddr_waitrequest || b_wr_blocked || (b_read && (b_wburst != 8'd0 || own_full));
        end
        // the responses: to the owner of the head burst
        a_readdata = ddr_readdata; b_readdata = ddr_readdata;
        a_readdatavalid = ddr_readdatavalid && reads_out && !own[o_rd] && !a_flush;
        b_readdatavalid = ddr_readdatavalid && reads_out && own[o_rd];
    end

    wire a_rd_acc = !grant && ddr_read && !ddr_waitrequest;
    wire a_wr_acc = !grant && ddr_write && !ddr_waitrequest;
    wire b_rd_acc = grant && ddr_read && !ddr_waitrequest;
    wire b_wr_acc = grant && ddr_write && !ddr_waitrequest;
    wire b_wlast  = b_wr_acc && ((b_wburst == 8'd1) || (b_wburst == 8'd0 && b_burstcount == 8'd1));
    wire rd_acc   = a_rd_acc || b_rd_acc;
    wire a_idle   = (a_wburst == 8'd0) && ((!a_read && !a_write) || a_flush);
    wire head_last = ddr_readdatavalid && reads_out && (head_left == 8'd0 ? own_n[o_rd] : head_left) == 8'd1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_valid <= 1'b0; h_rd <= 1'b0; h_wr <= 1'b0; h_a <= '0; h_bc <= '0; h_be <= '0; h_wd <= '0;
            grant <= 1'b0; a_wburst <= '0; b_wburst <= '0; a_flush <= 1'b0; a_out <= '0; b_cut <= 1'b0; o_wr <= '0; o_rd <= '0; o_cnt <= '0; head_left <= '0;
            for (int i = 0; i < 16; i++) begin own[i] <= 1'b0; own_n[i] <= '0; end
        end else begin
            // what the port held off this cycle (an A command: B's master is never reset)
            h_valid <= !grant && (ddr_read || ddr_write) && ddr_waitrequest;
            if (!grant && (ddr_read || ddr_write)) begin
                h_rd <= ddr_read; h_wr <= ddr_write; h_a <= ddr_address; h_bc <= ddr_burstcount;
                h_wd <= ddr_writedata; h_be <= ddr_byteenable;
            end
            // the abort: open at once, closed when the port is clean of A
            if (a_abort) a_flush <= 1'b1;
            else if (a_flush && a_wburst == 8'd0 && a_out == 5'd0) a_flush <= 1'b0;
            a_out <= a_out + {4'd0, a_rd_acc} - {4'd0, head_last && !own[o_rd]};
            // one B command per blocked A write: cleared once A's write is accepted
            if (a_wr_acc || !a_write) b_cut <= 1'b0;
            // the write bursts' bookkeeping
            if (a_wr_acc) begin
                if (a_wburst == 8'd0) a_wburst <= a_burstcount - 8'd1;
                else a_wburst <= a_wburst - 8'd1;
            end
            if (b_wr_acc) begin
                if (b_wburst == 8'd0) b_wburst <= b_burstcount - 8'd1;
                else b_wburst <= b_wburst - 8'd1;
            end
            // the owner FIFO
            if (rd_acc) begin
                own[o_wr] <= grant; own_n[o_wr] <= ddr_burstcount; o_wr <= o_wr + 1'b1;
            end
            if (ddr_readdatavalid && reads_out) begin
                if ((head_left == 8'd0 ? own_n[o_rd] : head_left) == 8'd1) begin
                    o_rd <= o_rd + 1'b1; head_left <= '0;
                end else begin
                    head_left <= (head_left == 8'd0 ? own_n[o_rd] : head_left) - 8'd1;
                end
            end
            o_cnt <= o_cnt + {4'd0, rd_acc} - {4'd0, head_last};
            // the grant: B after each accepted A command, whenever A is idle or its write
            // waits for reads; A back when B is idle; never inside A's write burst
            if (!grant) begin
                // never while an ORPHAN is on the port: it is A's command, and its first
                // write beat opens a burst in the very cycle a_wburst still reads 0 (and
                // A, withdrawn, looks idle) -- B's read then landed inside A's burst: found
                // 2026-09-27 by ddr_mux2_tb once B was live, latent while B never requested
                if (b_req && !orphan && ((a_rd_acc) || (a_wr_acc && a_wburst == 8'd1) || (a_wr_acc && ddr_burstcount == 8'd1 && a_wburst == 8'd0) || a_idle || (a_wr_blocked && !b_cut)))
                    grant <= 1'b1;
                if (b_req && !orphan && a_wr_blocked && !b_cut) b_cut <= 1'b1;
            end else begin
                // one B command a grant; a write burst keeps it to its last beat, and a
                // write blocked on reads keeps it until they drain (B's rule, above)
                if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0)) grant <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
