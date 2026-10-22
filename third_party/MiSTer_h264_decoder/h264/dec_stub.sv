// h264/dec_stub.sv -- placeholder owner of the clk_dec (96.43 MHz; 81 before P5b) domain
//
// Inherited from MiSTer_UMD_Video (umd/dec_stub.sv), where it held the domain from the
// scaffold until the H.264 front end landed.
//
// WHY THIS EXISTS. tools/fmax_check.sh (run by build_release.sh on every build) reads
// the timing report for a "clk_dec" row and gates the build on it at BOTH slow
// corners. A PLL output with no registers behind it gets no Fmax row at all, and the
// gate then reports the build as marginal. Until the decoder is harvested
// (docs/roadmap.md P2) this is the only register in that domain, so the gate stays
// meaningful from the first scaffold fit onward.
//
// Keep it after the decoder lands, for the front panel's sign of life: the counter's
// MSB, two-flop synchronised into clk_sys, blinks LED_USER at ~5.7 Hz (96.43 MHz / 2^24)
// whether or not a stream is playing -- a heartbeat that does not depend on the decoder.

module dec_stub (
    input  wire clk_dec,
    input  wire clk_sys,
    input  wire rst_n,       // clk_sys-domain reset, treated as async here
    output wire dec_alive    // clk_sys domain, ~6.2 Hz square wave (clk_dec / 2^24)
);

reg [23:0] cnt;
always @(posedge clk_dec or negedge rst_n) begin
    if (!rst_n) cnt <= 24'd0;
    else        cnt <= cnt + 24'd1;
end

// 2-FF synchroniser into clk_sys (a single slowly-toggling bit, so no handshake needed)
reg [1:0] sync_q;
always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) sync_q <= 2'b00;
    else        sync_q <= {sync_q[0], cnt[23]};
end
assign dec_alive = sync_q[1];

endmodule
