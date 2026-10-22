// bench/h264/disp_anc_tb.sv -- the audio anchor in the display scheduler (h264/disp_sched.sv,
// interface 0.5; docs/architecture.md "Audio (Phase 4)": "audio starts the clock"). The rule
// from the design text: when the audio starts the STC (ext_anc, no picture has), the first
// picture is SCHEDULED against the running clock -- due when STC >= its PTS - half a refresh
// -- unless it is more than FWD_MAX ahead of the STC or LATE_MAX behind it, when it
// re-anchors like any picture off the timeline; once anchored, ext_anc changes nothing.
//
//   +arm=X1  a picture 0.2 s ahead of the audio's clock: waits, then taken without anchoring
//   +arm=X2  a picture 1 s ahead (> FWD_MAX 0.5 s): re-anchors at its first refresh
//   +arm=X3  a picture 3 s behind (> LATE_MAX 2.7 s): re-anchors at its first refresh
//   +arm=X4  a picture 1 s behind: taken at once, not anchored (lateness is not a discontinuity)
//   +arm=X5  a picture anchored first; a later ext_anc moves nothing
//   +arm=X6  an untagged picture after the audio anchor: taken at once, the clock kept
// (1.1, docs/architecture.md "Queued audio: a late picture never runs the clock back over it") with
// aud_lead -- the queued audio ahead of the clock -- a picture's LATENESS never anchors:
//   +arm=X7  X3 with aud_lead high: taken at once, NOT anchored, the clock kept
//   +arm=X8  a picture 2.65 s behind the audio's clock taken (not anchored: the timeline set), the clock
//            run on until the next, contiguous on the timeline, is past LATE_MAX: with aud_lead high it
//            is taken at once, NOT anchored (disc's lateness leg)
//   +arm=X9  X8 with aud_lead low (a stall: the audio ran dry or came late): it re-anchors, as in 1.0
//   +arm=X10 aud_lead high, a picture anchored, then one 1 s past the timeline (> FWD_MAX): it re-anchors
//            (the timeline's legs keep anchoring)
//
// The bench drives disp_sched's contract directly: a tick every 300 cycles, eval then
// pickup (a cycle later) every 50,000 cycles (a "refresh"), half a refresh 750 ticks.
// Checks: [take] the picture taken at the wrong refresh; [anchor] anchored when it must not
// be, or not when it must; [stc] the clock moved other than by its ticks. Scoring with !==;
// PASS: disp_anc_tb is printed only when every check held.

`timescale 1ns/1ps
`default_nettype none

module disp_anc_tb;
    logic clk = 0;
    always #18.5 clk = ~clk;
    logic rst_n = 0;
    string arm;
    int fails = 0;
    task automatic fail(input string label, input string msg);
        $display("FAIL [%s] %s: %s", label, arm, msg);
        fails++;
        if (fails > 8) $fatal(1);
    endtask

    localparam int REFRESH = 50000;          // cycles a refresh here (166 ticks + 2/3)
    logic tick = 0, eval = 0, pickup = 0, ext_anc = 0, aud_lead = 0;
    logic [32:0] ext_pts = 0;
    logic head_valid = 0, head_tag = 0;
    logic [32:0] head_pts = 0;
    logic due, anchor_now, late, contig, next_due, anchored, next_valid;
    logic [32:0] stc;
    logic signed [33:0] disp_lag;

    disp_sched dut (
        .clk, .rst_n, .tick, .eval, .pickup, .ll(1'b0), .ext_anc, .ext_pts, .half(11'd750), .aud_lead,
        .head_valid, .head_tag, .head_pts, .head_dur_q3(27'd24024), .head_frame_t(23'd3003),
        .due, .anchor_now, .late, .contig, .next_due, .stc, .anchored, .next_valid, .disp_lag);

    // the tick; the refresh: eval at cycle 0 of the period, the pickup (taking a due head) at 10
    int tc = 0, rc = 0, refresh = 0;
    logic take_q = 0;
    int taken_at = -1;  logic anch_taken = 0;
    always @(posedge clk) if (rst_n) begin
        tick <= (tc == 299); tc <= (tc == 299) ? 0 : tc + 1;
        eval <= (rc == 0); rc <= (rc == REFRESH - 1) ? 0 : rc + 1;
        pickup <= (rc == 10) && due;
        if (rc == 10 && due && head_valid) begin
            taken_at <= refresh; anch_taken <= anchor_now; head_valid <= 1'b0;
        end
        if (rc == REFRESH - 1) refresh <= refresh + 1;
    end

    // [stc]: once the audio anchored it, the clock only counts ticks (or re-anchors at a take)
    // (sampled one edge later than the DUT's update: the tick, pickup and ext_anc it saw are
    // this edge's _q copies)
    logic [32:0] stc_q;  logic run_q = 0, tick_q = 0, pk_q = 0, anc_q = 0;
    always @(posedge clk) begin
        if (run_q && !(pk_q && anchor_now) && !anc_q && stc !== stc_q + (tick_q ? 33'd1 : 33'd0))
            fail("stc", $sformatf("the clock jumped %0d -> %0d", stc_q, stc));
        stc_q <= stc; run_q <= anchored; tick_q <= tick; pk_q <= pickup; anc_q <= ext_anc;
    end

    task automatic audio_anchor(input logic [32:0] at);
        @(posedge clk); ext_anc <= 1'b1; ext_pts <= at;
        @(posedge clk); ext_anc <= 1'b0;
        @(posedge clk);
        if (!anchored || stc !== at) fail("anchor", $sformatf("the audio anchor did not start the clock at %0d (%b %0d)", at, anchored, stc));
    endtask
    task automatic picture(input bit tg, input longint pts);
        head_tag <= tg; head_pts <= pts[32:0]; head_valid <= 1'b1;
    endtask
    task automatic wait_taken(input int limit);
        while (taken_at < 0 && refresh < limit) @(posedge clk);
        repeat (12) @(posedge clk);
    endtask

    localparam longint A = 1_000_000;      // the audio's first frame (ticks)
    initial begin
        int r0, want;
        if (!$value$plusargs("arm=%s", arm)) arm = "X1";
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (100) @(posedge clk);
        // (a case on the string trips iverilog's code generator: an if chain)
        if (arm == "X8" || arm == "X9") begin
            aud_lead = (arm == "X8");
            audio_anchor(A[32:0]);
            picture(1, A - 238500);                        // 2.65 s behind: taken at once, the timeline set
            wait_taken(refresh + 5);
            if (taken_at < 0 || anch_taken) fail("anchor", "the first picture (inside LATE_MAX) was not taken unanchored");
            // the clock runs on: the next picture, contiguous (A - 238500 + 3003), past LATE_MAX (243,000) by
            // ~4,500 ticks at its eval
            while (stc < A + 33'd12000) @(posedge clk);
            taken_at = -1;
            r0 = refresh;
            picture(1, A - 238500 + 3003);
            wait_taken(r0 + 5);
            if (taken_at < 0) fail("take", "the late picture was never taken");
            else if (taken_at > r0 + 2) fail("take", $sformatf("the late picture taken at refresh %0d, want at once", taken_at - r0));
            if (arm == "X8" && anch_taken) fail("anchor", "a late picture anchored the clock while the audio leads");
            if (arm == "X9" && !anch_taken) fail("anchor", "a picture past LATE_MAX did not re-anchor with the audio not leading");
        end else if (arm == "X10") begin
            aud_lead = 1'b1;
            picture(1, A);                                 // a picture anchors first
            wait_taken(5);
            if (!anch_taken) fail("anchor", "the first picture did not anchor");
            taken_at = -1;
            r0 = refresh;
            picture(1, A + 3003 + 90000);                  // 1 s past the timeline
            wait_taken(r0 + 5);
            // (not anchored, it would wait out its second: never taken within the limit)
            if (taken_at < 0 || !anch_taken) fail("anchor", "a jump past FWD_MAX did not re-anchor while the audio leads");
        end else if (arm == "X5") begin
            picture(1, A);                                 // a picture anchors first
            wait_taken(5);
            if (!anch_taken || !anchored) fail("anchor", "the first picture did not anchor");
            begin                                          // an ext_anc to a DIFFERENT time must move nothing
                logic [32:0] s0;
                @(posedge clk); s0 = stc; ext_anc <= 1'b1; ext_pts <= stc + 33'd50000;
                @(posedge clk); ext_anc <= 1'b0;
                repeat (3) @(posedge clk);
                if (stc - s0 > 33'd1) fail("stc", $sformatf("an ext_anc after a picture's anchor moved the clock %0d -> %0d", s0, stc));
            end
        end else begin
            audio_anchor(A[32:0]);
            r0 = refresh;
            if (arm == "X1")      picture(1, A + 18000);   // 0.2 s ahead
            else if (arm == "X2") picture(1, A + 90000);   // 1 s ahead
            else if (arm == "X3") picture(1, A - 270000);  // 3 s behind
            else if (arm == "X4") picture(1, A - 90000);   // 1 s behind
            else if (arm == "X6") picture(0, 0);           // untagged
            else if (arm == "X7") begin aud_lead = 1'b1; picture(1, A - 270000); end   // 3 s behind, the audio leading
            else begin $display("FAIL [harness] unknown arm %s", arm); $fatal(1); end
            wait_taken(r0 + 400);
            // X1: due when STC >= PTS - 750; the STC gains 166.7 ticks a refresh from A
            want = (arm == "X1") ? r0 + ((18000 - 750) * 3 + 499) / 500 : r0 + 1;
            if (taken_at < 0) fail("take", "the picture was never taken");
            else if (taken_at < want - 1 || taken_at > want + 1)
                fail("take", $sformatf("taken at refresh %0d, want %0d (+-1)", taken_at - r0, want - r0));
            if ((arm == "X2" || arm == "X3") && !anch_taken) fail("anchor", "a picture past the bounds was not re-anchored");
            if ((arm == "X1" || arm == "X4" || arm == "X6" || arm == "X7") && anch_taken) fail("anchor", "the picture re-anchored the audio's running clock");
            if ((arm == "X2" || arm == "X3") && anch_taken && stc < head_pts) fail("stc", "the re-anchor did not move the clock to the picture");
        end
        $display("disp_anc_tb: %s taken at refresh %0d, anchored %b, STC %0d", arm, taken_at, anch_taken, stc);
        if (fails == 0) $display("PASS: disp_anc_tb %s", arm);
        else $fatal(1);
        $finish;
    end
    initial begin #2s; $display("FAIL [hang] %s", arm); $fatal(1); end
endmodule

`default_nettype wire
