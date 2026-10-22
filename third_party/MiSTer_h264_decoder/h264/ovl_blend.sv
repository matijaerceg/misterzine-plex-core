// h264/ovl_blend.sv -- the overlay's composite (Phase 6b, interface 0.9; docs/architecture.md
// "The overlay plane", "The pixels and the composite" step 4): out = P + div255(V (255 - P_a))
// per colour, V the video emu selected (the picture, the idle screen or black), P the overlay's
// premultiplied colour and P_a its alpha (h264/ovl_plane.sv). div255(x) = (x + 128 + ((x + 128)
// >> 8)) >> 8 is exactly x / 255 rounded for x <= 65,535. Clamped at 255 -- not reachable, P <=
// P_a -- so a malformed P can never wrap to black.
//
// Combinational (PIPE 0): emu registered the result as the output stage (VGA_R / G / B), one
// register after the picture / idle selection. At 27 MHz three 8 x 8 products and their sums
// fit one clock with room; at 81 MHz (hd_raster) they do not: vid_out takes PIPE 1, a register
// after the products (on the dot), and delays sync / DE / CE_PIXEL / VGA_F1 one dot more
// (tools/check_emu_wiring.py reads vid_out's LAT_BLEND).

`default_nettype none

module ovl_blend #(
    parameter int PIPE = 0               // (hd_raster) 1: a register after the products (vid_out at 81 MHz)
) (
    input  wire        clk,              // PIPE 1 only (tie off otherwise)
    input  wire        ce,
    input  wire  [7:0] v_r,
    input  wire  [7:0] v_g,
    input  wire  [7:0] v_b,
    input  wire  [7:0] p_r,
    input  wire  [7:0] p_g,
    input  wire  [7:0] p_b,
    input  wire  [7:0] p_a,
    output wire  [7:0] r,
    output wire  [7:0] g,
    output wire  [7:0] b
);
    wire  [7:0]  ia  = 8'd255 - p_a;
    wire  [15:0] m_r0 = v_r * ia, m_g0 = v_g * ia, m_b0 = v_b * ia;
    logic [15:0] m_r, m_g, m_b;
    logic [7:0]  q_r, q_g, q_b;
    generate if (PIPE != 0) begin : g_pipe
        always_ff @(posedge clk) if (ce) begin
            m_r <= m_r0; m_g <= m_g0; m_b <= m_b0;
            q_r <= p_r;  q_g <= p_g;  q_b <= p_b;
        end
    end else begin : g_comb
        always_comb begin
            m_r = m_r0; m_g = m_g0; m_b = m_b0;
            q_r = p_r;  q_g = p_g;  q_b = p_b;
        end
    end endgenerate
    wire  [16:0] t_r = {1'b0, m_r} + 17'd128, t_g = {1'b0, m_g} + 17'd128, t_b = {1'b0, m_b} + 17'd128;
    wire  [17:0] d_r = {1'b0, t_r} + {9'd0, t_r[16:8]}, d_g = {1'b0, t_g} + {9'd0, t_g[16:8]},
                 d_b = {1'b0, t_b} + {9'd0, t_b[16:8]};
    wire  [8:0]  s_r = {1'b0, q_r} + {1'b0, d_r[15:8]}, s_g = {1'b0, q_g} + {1'b0, d_g[15:8]},
                 s_b = {1'b0, q_b} + {1'b0, d_b[15:8]};
    assign r = s_r[8] ? 8'd255 : s_r[7:0];
    assign g = s_g[8] ? 8'd255 : s_g[7:0];
    assign b = s_b[8] ? 8'd255 : s_b[7:0];
endmodule

`default_nettype wire
