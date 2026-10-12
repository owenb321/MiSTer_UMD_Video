// umd/at3p/at3p_top.sv -- the ATRAC3plus decoder: AU bytes in, s16 stereo PCM out
//
// The demux's audio byte stream (ps_demux aud_byte / aud_valid / aud_ready: AU aligned,
// 0F D0 params 00000000 frame ...) in; 2,048 stereo pairs an AU out, channel 0 as
// pcm_l. at3p_seq runs the microcode (AU header, parse, synthesis control); at3p_vec the
// synthesis loops. clk_sys (27 MHz): docs/at3p_decoder.md S3.1.
//
// Status for the HUD / the wiring: frames decoded, frames refused (with the last
// refusal's code: the model's At3pError names, umd/at3p/at3p.uasm E_*), frames read past
// their end, internal saturations (none on a legal stream), PCM clips (ffmpeg's s16
// clips the same samples). A refused frame is 2,048 silent pairs: the timing holds.

`default_nettype none

module at3p_top (
    input  wire         clk,
    input  wire         rst_n,

    input  wire   [7:0] in_byte,
    input  wire         in_valid,
    output logic        in_ready,

    output logic [15:0] pcm_l,
    output logic [15:0] pcm_r,
    output logic        pcm_valid,
    input  wire         pcm_ready,

    output logic [15:0] frames,
    output logic [15:0] refused,
    output logic  [7:0] last_err,
    output logic [15:0] overruns,
    output logic [15:0] sat_count,
    output logic [15:0] clip_count,

    // benches
    output logic        mark_valid,
    output logic [15:0] mark_id,
    output logic        vop_start,
    output logic  [3:0] vop_op,
    output logic        vop_done,
    output logic        tr_valid,
    output logic [11:0] tr_pc,
    output logic        tr_kind,
    output logic [13:0] tr_addr,
    output logic [15:0] tr_val
);

    logic [127:0] vop_args;
    logic  [11:0] spec_raddr;
    logic   [5:0] spec_rdata;
    logic   [7:0] e_raddr, e_rdata, err_code;
    logic         err_valid, overrun, overrun_q;

    at3p_seq u_seq (
        .clk, .rst_n, .in_byte, .in_valid, .in_ready,
        .vop_start, .vop_op, .vop_args, .vop_done,
        .spec_raddr, .spec_rdata, .e_raddr, .e_rdata,
        .mark_valid, .mark_id, .err_valid, .err_code, .overrun,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    at3p_vec u_vec (
        .clk, .rst_n, .start(vop_start), .op(vop_op), .args(vop_args), .done(vop_done),
        .spec_raddr, .spec_rdata, .e_raddr, .e_rdata,
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready, .sat_count, .clip_count);

    always_ff @(posedge clk) begin
        overrun_q <= overrun;
        if (!rst_n) begin
            frames <= 16'd0; refused <= 16'd0; last_err <= 8'd0; overruns <= 16'd0;
        end else begin
            if (mark_valid && mark_id == 16'd2) frames <= frames + 16'd1;   // M_FRAME
            if (err_valid) begin refused <= refused + 16'd1; last_err <= err_code; end
            if (overrun && !overrun_q) overruns <= overruns + 16'd1;
        end
    end

endmodule
