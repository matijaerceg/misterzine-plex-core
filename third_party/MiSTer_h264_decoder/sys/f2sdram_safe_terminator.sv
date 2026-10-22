// ============================================================================
//
//                f2sdram_safe_terminator for MiSTer platform
//
// ============================================================================
// Copyright (c) 2021 bellwood420
//
// Background:
//
//   Terminating a transaction of burst writing(/reading) in its midstream
//   seems to cause an illegal state to f2sdram interface.
//
//   Forced reset request that occurs when loading other core is inevitable.
//
//   So if it happens exactly within the transaction period,
//   unexpected issues with accessing to f2sdram interface will be caused
//   in next loaded core.
//
//   It seems that only way to reset broken f2sdram interface is to reset
//   whole SDRAM Controller Subsystem from HPS via permodrst register
//   in Reset Manager.
//   But it cannot be done safely while Linux is running.
//   It is usually done when cold or warm reset is issued in HPS.
//
//   Main_MiSTer is issuing reset for FPGA <> HPS bridges
//   via brgmodrst register in Reset Manager when loading rbf.
//   But it has no effect on f2sdram interface.
//   f2sdram interface seems to belong to SDRAM Controller Subsystem
//   rather than FPGA-to-HPS bridge.
//
//   Main_MiSTer is also trying to issuing reset for f2sdram ports
//   via fpgaportrst register in SDRAM Controller Subsystem when loading rbf.
//   But according to the Intel's document, fpgaportrst register can be
//   used to stretch the port reset.
//   It seems that it cannot be used to assert the port reset.
//
//   According to the Intel's document, there seems to be a reset port on
//   Avalon-MM slave interface, but it cannot be found in Qsys generated HDL.
//
//   To conclude, the only thing FPGA can do is not to break the transaction.
//   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//
// Purpose:
//   To prevent the issue, this module completes ongoing transaction
//   on behalf of user logic, when reset is asserted.
//
// Usage:
//   Insert this module into the bus line between
//   f2sdram (Avalon-MM slave) and user logic (Avalon-MM master).
//
// Notice:
//   Asynchronous reset request is not supported.
//   Please feed reset request synchronized to clock.
//
module f2sdram_safe_terminator #(
  parameter     DATA_WIDTH = 64,
  parameter     BURSTCOUNT_WIDTH = 8
) (
	// clk should be the same as one provided to f2sdram port
	// clk should not be stop when reset is asserted
	input         clk,
	// rst_req_sync should be synchronized to clk
	// Asynchronous reset request is not supported
	input         rst_req_sync,

	// Master port: connecting to Alavon-MM slave(f2sdram)
	input                         waitrequest_master,
	output [BURSTCOUNT_WIDTH-1:0] burstcount_master,
	output    [ADDRESS_WITDH-1:0] address_master,
	input        [DATA_WIDTH-1:0] readdata_master,
	input                         readdatavalid_master,
	output                        read_master,
	output       [DATA_WIDTH-1:0] writedata_master,
	output [BYTEENABLE_WIDTH-1:0] byteenable_master,
	output                        write_master,

	// Slave port: connecting to Alavon-MM master(user logic)
	output                        waitrequest_slave,
	input  [BURSTCOUNT_WIDTH-1:0] burstcount_slave,
	input     [ADDRESS_WITDH-1:0] address_slave,
	output       [DATA_WIDTH-1:0] readdata_slave,
	output                        readdatavalid_slave,
	input                         read_slave,
	input        [DATA_WIDTH-1:0] writedata_slave,
	input  [BYTEENABLE_WIDTH-1:0] byteenable_slave,
	input                         write_slave
);

localparam BYTEENABLE_WIDTH = DATA_WIDTH/8;
localparam ADDRESS_WITDH    = 32-$clog2(BYTEENABLE_WIDTH);

/*
* Capture init reset deaseert
*/
reg init_reset_deasserted = 1'b0;

always_ff @(posedge clk) begin
	if (!rst_req_sync) begin
		init_reset_deasserted <= 1'b1;
	end
end

/*
* Lock stage
*/
reg lock_stage = 1'b0;

always_ff @(posedge clk) begin
	if (rst_req_sync) begin
		// Reset assert
		if (init_reset_deasserted) begin
			lock_stage <= 1'b1;
		end
	end
	else begin
		// Reset deassert
		lock_stage <= 1'b0;
	end
end

/*
* UMD-FORK (2026-09-26): the write burst tracked at the PORT, and the lock from that.
*
* Stock tracked the burst at the slave side and counted a beat on every cycle with
* `state_write && !waitrequest_master` -- no `write` term -- and ended a burst when its
* counter reached burstcount-1 whether or not that last beat had been accepted. A master
* that drops `write` between beats (legal Avalon; umd/h264/dpb_mem.sv does it on every
* burst while it fetches the next beat) or whose last beat meets waitrequest desynced the
* tracker; a core reset landing inside a write burst then completed it short (or not at
* all) and the HPS port waited for beats that never came: the next core's writes were
* absorbed into the old burst and its first read never returned -- the UMD core's reload
* hang, ~1 load in 8 (docs/hil_harness.md "Facts that bite";
* bench/umd/f2sdram_term_tb.sv reproduces it on the stock code: [owed]).
*
* Here the tracker counts the beats the PORT accepts (write_master && !waitrequest_master:
* the slave's before the lock, the terminator's own after it), so it is exact whatever the
* master does between beats. At the lock (the first cycle of the reset request; the
* slave's signals reach the port that cycle for the last time):
*   - a write burst the port has started and not finished (after this cycle's beat) is
*     completed with masked beats;
*   - a write beat held under waitrequest (a burst's first or a later one) is kept
*     presented exactly as it was -- its own byte enables and data (Avalon: nothing
*     changes under waitrequest) -- and the rest of its burst completed masked;
*   - a read held under waitrequest is kept presented until accepted;
*   - otherwise nothing: accepted reads complete on their own.
* The terminator lets go only when the reset is released AND nothing is being completed:
* a release never withdraws a command either.
*/
wire port_wbeat = write_master && !waitrequest_master;

reg                        wr_open       = 1'b0;   // a write burst started at the port, beats owed
reg [BURSTCOUNT_WIDTH-1:0] wr_left       = 0;      // beats still owed to the port
reg [BURSTCOUNT_WIDTH-1:0] wr_bc_latch   = 0;
reg [ADDRESS_WITDH-1:0]    wr_addr_latch = 0;

// the burst state after this cycle
wire                        wr_first  = port_wbeat && !wr_open;
wire [BURSTCOUNT_WIDTH-1:0] next_left = !port_wbeat ? wr_left :
                                        wr_open     ? wr_left - 1'd1 : burstcount_master - 1'd1;
wire                        next_open = port_wbeat ? (next_left != 0) : wr_open;

always_ff @(posedge clk) begin
	wr_open <= next_open;
	wr_left <= next_left;
	if (wr_first) begin
		wr_bc_latch   <= burstcount_master;
		wr_addr_latch <= address_master;
	end
end

reg [BURSTCOUNT_WIDTH-1:0] burstcount_latch = 0;
reg [ADDRESS_WITDH-1:0]    address_latch    = 0;

reg [BYTEENABLE_WIDTH-1:0] byteenable_latch = 0;

reg terminating       = 0;
reg read_terminating  = 0;
reg write_terminating = 0;
reg be_keep           = 0;   // a write beat held under waitrequest at the lock: its own enables until taken

always_ff @(posedge clk) begin
	if (rst_req_sync && init_reset_deasserted && !lock_stage && !terminating) begin
		// the lock
		terminating      <= 1;
		burstcount_latch <= burstcount_slave;
		address_latch    <= address_slave;
		byteenable_latch <= byteenable_slave;
		be_keep          <= write_slave && waitrequest_master;
		if (next_open) begin
			write_terminating <= 1;
			burstcount_latch  <= wr_first ? burstcount_master : wr_bc_latch;
			address_latch     <= wr_first ? address_master : wr_addr_latch;
		end
		else if (write_slave && waitrequest_master) begin
			write_terminating <= 1;
		end
		else if (read_slave && waitrequest_master) begin
			read_terminating  <= 1;
		end
	end
	else begin
		if (read_terminating && !waitrequest_master) read_terminating <= 0;
		if (port_wbeat) be_keep <= 0;
		if (write_terminating && port_wbeat && !next_open) write_terminating <= 0;
		if (!rst_req_sync && !read_terminating && !write_terminating) terminating <= 0;
	end
end

/*
* Bus mux depending on the stage.
*/
always_comb begin
	if (terminating) begin
		burstcount_master = burstcount_latch;
		address_master    = address_latch;
		read_master       = read_terminating;
		write_master      = write_terminating;
		byteenable_master = be_keep ? byteenable_latch : {BYTEENABLE_WIDTH{1'b0}};
	end
	else begin
		burstcount_master = burstcount_slave;
		address_master    = address_slave;
		read_master       = read_slave;
		byteenable_master = byteenable_slave;
		write_master      = write_slave;
	end
end

// Just passing master <-> slave
assign writedata_master    = writedata_slave;
assign readdata_slave      = readdata_master;
assign readdatavalid_slave = readdatavalid_master;
assign waitrequest_slave   = waitrequest_master;

endmodule
