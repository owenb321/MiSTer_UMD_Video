// umd/cdc.sv -- the small clock-domain-crossing helpers emu composes the clk_dec
// front end with (docs/h264_frontend.md S6). Three modules, one file, so the qsf
// names one thing and a reader finds every crossing in one place:
//
//   cdc_reset  a reset into a clock domain: asserted asynchronously, RELEASED on the
//              destination clock through two flops (recovery/removal timing is then
//              a same-domain matter). Every clk_dec module takes its reset from one.
//   cdc_pulse  a one-cycle pulse from one domain into another (toggle + two flops +
//              an edge). Two pulses inside ~3 destination cycles merge into one: for
//              events that are hundreds of cycles apart (a mount, a title end).
//   cdc_snap   a W-bit bus snapshot for a readout: the destination asks, the source
//              latches all W bits IN ONE OF ITS CYCLES and answers, the destination
//              copies the latched value. A four-phase toggle handshake, so the copy
//              is a value the bus actually held -- never a tear between bits that a
//              per-bit synchroniser would make of a counter mid-carry (0x0FFF ->
//              0x1000 read as 0x1FFF). ~4 cycles of each clock per round, repeating.
//
// sys/sys_top.sdc places clk_sys and clk_dec in one exclusive group with the other
// PLL outputs -- the crossings are timed as same-group transfers -- so these are about
// correctness by construction (one launch edge per captured value), not about false
// paths. A CDC that is not one of these three shapes needs its own note.

`default_nettype none

module cdc_reset (
    input  wire clk,          // the destination clock
    input  wire rst_n_in,     // any domain; asynchronous assert
    output wire rst_n_out     // asserted with rst_n_in, released two clk edges after it
);
    logic q1, q2;
    always_ff @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in) begin q1 <= 1'b0; q2 <= 1'b0; end
        else           begin q1 <= 1'b1; q2 <= q1;   end
    end
    assign rst_n_out = q2;
endmodule


module cdc_pulse (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,
    input  wire dst_clk,
    input  wire dst_rst_n,
    output logic dst_pulse
);
    logic tog;
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)     tog <= 1'b0;
        else if (src_pulse) tog <= ~tog;
    end
    logic t1, t2, t3;
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin t1 <= 1'b0; t2 <= 1'b0; t3 <= 1'b0; dst_pulse <= 1'b0; end
        else begin t1 <= tog; t2 <= t1; t3 <= t2; dst_pulse <= t2 ^ t3; end
    end
endmodule


module cdc_snap #(
    parameter int W = 32
) (
    input  wire          src_clk,
    input  wire          src_rst_n,
    input  wire [W-1:0]  src_data,

    input  wire          dst_clk,
    input  wire          dst_rst_n,
    output logic [W-1:0] dst_data,
    output logic         dst_tick       // one cycle per fresh copy
);
    // source: answer a request by latching the bus and flipping ack
    logic         req, ack;
    logic         s_q1, s_q2;           // req synchronised into src_clk
    logic [W-1:0] hold;
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin s_q1 <= 1'b0; s_q2 <= 1'b0; ack <= 1'b0; hold <= '0; end
        else begin
            s_q1 <= req; s_q2 <= s_q1;
            if (s_q2 != ack) begin hold <= src_data; ack <= s_q2; end
        end
    end
    // destination: when the answer to the current request is in, copy and ask again.
    // hold is at least two dst_clk cycles old by then (ack changed in the same src
    // edge as hold and took two dst flops to arrive), so the copy sees settled bits.
    logic d_q1, d_q2;                   // ack synchronised into dst_clk
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin d_q1 <= 1'b0; d_q2 <= 1'b0; req <= 1'b0; dst_data <= '0; dst_tick <= 1'b0; end
        else begin
            d_q1 <= ack; d_q2 <= d_q1;
            dst_tick <= 1'b0;
            if (d_q2 == req) begin dst_data <= hold; dst_tick <= 1'b1; req <= ~req; end
        end
    end
endmodule

`default_nettype wire
