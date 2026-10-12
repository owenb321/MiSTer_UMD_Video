// umd/plane_blend.sv -- one premultiplied plane over the layers below it (docs/compositor.md
// §3): out = src + (1 - a) dst per channel,
//     out = min(255, s + ((t + 128 + ((t + 128) >> 8)) >> 8)),   t = d (255 - a)
// the second term being round(d (255 - a) / 255) exactly (the plane writer's premultiply,
// main/support/umd/umd_sub.cpp, the HPS's plane writer since A7). A valid premultiplied pixel (every colour <= a, which the
// writer and the bilinear filter both keep) never reaches the clip; a plane from another
// owner might, and saturates instead of wrapping.
// LAT 2: the products, then the rounding, the sum and the clip. src and dst arrive aligned.

`default_nettype none

module plane_blend (
    input  wire        clk,
    input  wire  [7:0] s_a,
    input  wire  [7:0] s_r,
    input  wire  [7:0] s_g,
    input  wire  [7:0] s_b,
    input  wire  [7:0] d_r,
    input  wire  [7:0] d_g,
    input  wire  [7:0] d_b,
    output logic [7:0] r,
    output logic [7:0] g,
    output logic [7:0] b
);

    logic [15:0] t_r, t_g, t_b;
    logic [7:0]  s1_r, s1_g, s1_b;
    wire  [7:0]  na = 8'd255 - s_a;
    always_ff @(posedge clk) begin
        t_r <= d_r * na; t_g <= d_g * na; t_b <= d_b * na;
        s1_r <= s_r; s1_g <= s_g; s1_b <= s_b;
    end

    // t + 128 <= 65,153 and adding its top byte stays below 65,536: 16 bits suffice
    wire [15:0] u_r = t_r + 16'd128, u_g = t_g + 16'd128, u_b = t_b + 16'd128;
    /* verilator lint_off UNUSEDSIGNAL */      // >> 8: the low byte is dropped
    wire [15:0] v_r = u_r + {8'd0, u_r[15:8]};
    wire [15:0] v_g = u_g + {8'd0, u_g[15:8]};
    wire [15:0] v_b = u_b + {8'd0, u_b[15:8]};
    /* verilator lint_on UNUSEDSIGNAL */
    wire [8:0]  m_r = {1'b0, s1_r} + {1'b0, v_r[15:8]};
    wire [8:0]  m_g = {1'b0, s1_g} + {1'b0, v_g[15:8]};
    wire [8:0]  m_b = {1'b0, s1_b} + {1'b0, v_b[15:8]};
    always_ff @(posedge clk) begin
        r <= m_r[8] ? 8'd255 : m_r[7:0];
        g <= m_g[8] ? 8'd255 : m_g[7:0];
        b <= m_b[8] ? 8'd255 : m_b[7:0];
    end

endmodule

`default_nettype wire
