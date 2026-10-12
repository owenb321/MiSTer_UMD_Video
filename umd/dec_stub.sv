// umd/dec_stub.sv -- placeholder owner of the clk_dec (81 MHz) domain
//
// WHY THIS EXISTS. tools/fmax_check.sh (run by build_release.sh on every build) reads
// the timing report for a "clk_dec" row and gates the build on it at BOTH slow
// corners. A PLL output with no registers behind it gets no Fmax row at all, and the
// gate then reports the build as marginal. Before the H.264 front end landed (roadmap
// P3, umd/h264/h264_top.sv) this was the only register in that domain, so the gate
// stayed meaningful from the first scaffold fit onward.
//
// Kept after P3 for the front panel's sign of life: the counter's MSB, two-flop
// synchronised into clk_sys, blinks LED_USER at ~4.8 Hz (81 MHz / 2^24) whether or
// not a title is streaming -- a heartbeat that does not depend on the decoder.

module dec_stub (
    input  wire clk_dec,
    input  wire clk_sys,
    input  wire rst_n,       // clk_sys-domain reset, treated as async here
    output wire dec_alive    // clk_sys domain, ~4.8 Hz square wave
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
