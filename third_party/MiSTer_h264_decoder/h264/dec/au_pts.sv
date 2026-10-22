// h264/dec/au_pts.sv -- attach each PES PTS to the access unit it belongs to, by byte
// position (ISO 13818-1 2.4.3.7; roadmap P5c, docs/display.md)
//
// THE RULE: a PES packet's PTS belongs to the first access unit that starts at or after
// the first byte of that packet's payload. Both positions are counted by nal_parser on
// ONE counter (the bytes it has taken since reset, modulo 2^PW):
//   stamp  the position of the PES payload's first byte (ps_demux's vid_mark rides with
//          that byte through vidfeed_cdc, with the PTS)
//   au     the position of the access unit's first start code (7.4.1.2.3: an AUD, SPS,
//          PPS, SEI or NAL types 14..18 after a VCL NAL unit, else the first slice of a
//          new primary picture; nal_parser reports the 3-byte start code's first byte)
// A stamp at or before an access unit's start belongs to that access unit if no earlier
// access unit took it. So at every access-unit start ALL waiting stamps at or before it
// are popped and the LATEST is the tag; any other popped stamp belonged to a PES with no
// access-unit start of its own (a PTS 13818-1 forbids there) and is counted in `drops`,
// never silently used. The tag is held until the next access-unit start.
//
// Why not MiSTer_DVD's pts_assoc.sv (docs/harvest.md): it pops ONE stamp per picture
// (a stale stamp then lands on the next picture) and rate-limits stamps for a 2 MB VBUF
// in flight; here the positions are counted at the front end's own input, so the stamps
// in flight are only the few bytes nal_parser holds -- DEPTH 4 is ample. A full queue
// EVICTS THE OLDEST stamp, counted: an access unit start trails the input by at most a
// slice header's span, so by the time a fifth stamp arrives every start that could still
// want the oldest has been served (it can only be superseded now), while the newest is
// the one stamp that can still be a tag. (A first draft dropped the newest: on
// tools/h264_top_golden.py --synth-marks, five stamps before one access unit, it lost the
// right tag.) Wrong only if four PTS-bearing PES payloads start inside one slice header's
// span -- no program stream packetiser produces that.
//
// Modular compare: head <= au iff (au - head) has its top bit clear -- exact while the
// two are within 2^(PW-1) bytes (8 MB at PW 24; a Level 3.0 access unit is < 1.25 MB).

`default_nettype none

module au_pts #(
    parameter int DEPTH = 4,
    parameter int PW    = 24
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          clear,          // forget every stamp and the tag (a new title)

    input  wire          push,           // a marked byte was taken at push_pos
    input  wire [32:0]   push_pts,
    input  wire [PW-1:0] push_pos,

    input  wire          au_start,       // pulse: an access unit starts at au_pos
    input  wire [PW-1:0] au_pos,
    output logic         busy,           // popping (a few cycles after au_start)

    output logic         tag_valid,      // the access unit's PTS (held until the next au_start)
    output logic [32:0]  tag_pts,
    output logic [31:0]  drops           // stamps discarded (superseded or queue full)
);

    logic [32:0]   e_pts [0:DEPTH-1];
    logic [PW-1:0] e_pos [0:DEPTH-1];
    logic [$clog2(DEPTH+1)-1:0] cnt;
    logic [PW-1:0] a_pos;
    logic          cand_v;
    logic [32:0]   cand_pts;

    wire [PW-1:0] gap  = a_pos - e_pos[0];
    wire          pop   = busy && (cnt != '0) && !gap[PW-1];
    wire          full  = (cnt == DEPTH[$clog2(DEPTH+1)-1:0]);
    wire          evict = push && full && !pop;         // full: the OLDEST stamp makes room

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= '0; a_pos <= '0; busy <= 1'b0; cand_v <= 1'b0; cand_pts <= '0;
            tag_valid <= 1'b0; tag_pts <= '0; drops <= '0;
            for (int i = 0; i < DEPTH; i++) begin e_pts[i] <= '0; e_pos[i] <= '0; end
        end else if (clear) begin
            cnt <= '0; busy <= 1'b0; cand_v <= 1'b0; tag_valid <= 1'b0; drops <= '0;
        end else begin
            // the queue: pop the head (shift) and / or append at the tail; every push is
            // taken (a full queue evicts its head first, counted)
            if (pop || evict) begin
                for (int i = 0; i < DEPTH - 1; i++) begin e_pts[i] <= e_pts[i+1]; e_pos[i] <= e_pos[i+1]; end
            end
            if (push) begin
                e_pts[(pop || evict) ? cnt - 1'b1 : cnt] <= push_pts;
                e_pos[(pop || evict) ? cnt - 1'b1 : cnt] <= push_pos;
            end
            if (pop && !push)      cnt <= cnt - 1'b1;
            else if (!pop && push && !evict) cnt <= cnt + 1'b1;
            drops <= drops + {31'd0, evict} + {31'd0, pop && cand_v};

            // the association
            if (au_start) begin
                a_pos <= au_pos; busy <= 1'b1; cand_v <= 1'b0;
            end else if (busy) begin
                if (pop) begin
                    cand_v <= 1'b1; cand_pts <= e_pts[0];                  // (a superseded one is counted above)
                end else begin
                    busy <= 1'b0;
                    tag_valid <= cand_v; tag_pts <= cand_pts;
                end
            end
        end
    end

endmodule

`default_nettype wire
