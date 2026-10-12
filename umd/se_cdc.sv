// umd/se_cdc.sv -- the syntax-element stream across clock domains (h264_top on clk_dec
// -> recon_top on clk_sys in the P4 smoke clocking, docs/h264_recon.md S4)
//
// A 32-word umd/fifo_dc and, on the read side, an output register that turns the
// FIFO's pull port (dout the cycle after rd_en) into a valid / ready word: a word is
// popped only when the register will be free when it lands (empty, or being taken this
// cycle, and nothing already in flight). At most a word every two read cycles; the
// reconstruction takes far fewer (hundreds of words a macroblock of thousands of
// cycles), and recon_top buffers 2,048 more behind it.
// Resets: one per side, released synchronously to each clock (fifo_dc's rules).

`default_nettype none

module se_cdc (
    input  wire         wr_clk,
    input  wire         wr_rst_n,
    input  wire         in_valid,
    output logic        in_ready,
    input  wire  [47:0] in_data,

    input  wire         rd_clk,
    input  wire         rd_rst_n,
    output logic        out_valid,
    input  wire         out_ready,
    output logic [47:0] out_data
);

    wire  [47:0] f_dout;
    wire         f_full, f_empty, f_valid;
    logic        f_rd;
    fifo_dc #(.DW(48), .AW(5)) u_fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .din(in_data), .wr_en(in_valid && !f_full),
        .full(f_full), .wr_free(),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .dout(f_dout), .rd_en(f_rd), .empty(f_empty), .valid(f_valid));
    assign in_ready = !f_full;

    logic        pend;                     // a word popped, landing next cycle
    wire         take = out_valid && out_ready;
    assign f_rd = !f_empty && !pend && (!out_valid || take);
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            out_valid <= 1'b0; pend <= 1'b0; out_data <= '0;
        end else begin
            if (f_rd)         pend <= 1'b1;
            else if (f_valid) pend <= 1'b0;
            if (f_valid) begin out_valid <= 1'b1; out_data <= f_dout; end
            else if (take)     out_valid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
