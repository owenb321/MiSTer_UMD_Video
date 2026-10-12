// umd/png/png_top.sv -- a PNG decoder in fabric: bytes in, RGBA8888 pixels with (x, y)
// out (docs/png_decode.md)
//
//   in_* --> png_chunks --z--> inflate --f--> png_unfilter --r--> png_pixel --> px_*
//            (CRC, IHDR,        (zlib,          (filters,         (unpack, palette,
//             PLTE, tRNS)        32 KB window)   Adam7 passes)     tRNS, 16 -> 8)
//
// Every colour type and bit depth, Adam7 included; one bound: row bytes <= 8192 and
// dimensions <= 65535 (E_SIZE, docs/png_decode.md §3). Pixels stream out as they are
// decoded -- in pass order for an interlaced image -- so a verdict found later (a bad
// Adler, a bad IEND CRC, a short image) arrives after pixels were emitted: the
// consumer holds the image until `done` and discards it when err != 0.
//
// A unit is one PNG (in_last on its final byte; the subtitle unit header says how long).
// `start` begins one; `done` pulses once it is consumed to in_last AND every stage has
// drained (or at the first fatal error, once the unit is drained). err is the FIRST
// fatal verdict (png_pkg); warn the benign ones.
//
// Taps for the bench (tap_inf: the inflated bytes as the unfilter takes them; tap_raw:
// the reconstructed bytes as the pixel stage takes them) and throughput counters.

`default_nettype none

module png_top
    import png_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    input  wire        in_last,
    output logic       in_ready,

    output logic        hdr_valid,
    output logic [15:0] hdr_w,
    output logic [15:0] hdr_h,
    output logic [2:0]  hdr_ctype,
    output logic [4:0]  hdr_depth,
    output logic        hdr_il,

    output logic [15:0] px_x,
    output logic [15:0] px_y,
    output logic [31:0] px_rgba,
    output logic        px_valid,
    input  wire         px_ready,

    output logic       busy,
    output logic       done,
    output logic [4:0] err,
    output logic [5:0] warn,

    output logic       tap_inf_valid,
    output logic [7:0] tap_inf_byte,
    output logic       tap_raw_valid,
    output logic [7:0] tap_raw_byte
);

    // chunks <-> inflate
    logic [7:0] z_byte;
    logic       z_valid, z_ready, z_start, z_end;
    logic [4:0] c_err, i_err, u_err;
    logic [5:0] c_warn;
    logic       finished;
    logic       fatal;

    // palette
    logic        pal_we, alpha_we, key_valid;
    logic [7:0]  pal_wa, alpha_wa, alpha_wd;
    logic [23:0] pal_wd;
    logic [8:0]  plte_n, trns_n;
    logic [15:0] key_r, key_g, key_b;

    // inflate -> unfilter
    logic [7:0] f_byte;
    logic       f_valid, f_ready;
    logic       i_done;

    // unfilter -> pixel
    logic [7:0]  r_byte;
    logic        r_valid, r_ready, r_sol;
    logic [15:0] r_y, r_pw;
    logic [2:0]  r_x0;
    logic [1:0]  r_ldx;
    logic        complete, warn_long, warn_index, p_idle;

    // the first fatal verdict, from any stage
    logic [4:0] err_q;
    wire  [4:0] err_now = (c_err != E_OK) ? c_err : (i_err != E_OK) ? i_err : u_err;
    assign fatal = (err_q != E_OK) || (err_now != E_OK);
    assign err   = err_q;

    png_chunks u_chunks (
        .clk, .rst_n, .start,
        .abort     (fatal && (c_err == E_OK)),
        .quiet     ((z_ready || i_done) && !f_valid),
        .in_byte, .in_valid, .in_last, .in_ready,
        .hdr_valid, .hdr_w, .hdr_h, .hdr_ctype, .hdr_depth, .hdr_il,
        .z_start, .z_byte, .z_valid, .z_ready, .z_done (i_done), .z_end,
        .pal_we, .pal_wa, .pal_wd, .alpha_we, .alpha_wa, .alpha_wd,
        .plte_n, .trns_n, .key_valid, .key_r, .key_g, .key_b,
        .finished, .err (c_err), .warn (c_warn)
    );

    inflate u_inflate (
        .clk, .rst_n,
        .start     (z_start || start),
        .in_byte   (z_byte), .in_valid (z_valid), .in_ready (z_ready), .in_end (z_end),
        .out_byte  (f_byte), .out_valid (f_valid), .out_ready (f_ready),
        .done      (i_done), .err (i_err)
    );

    png_unfilter u_unfilter (
        .clk, .rst_n, .start,
        .hdr_valid, .hdr_w, .hdr_h, .hdr_ctype, .hdr_depth, .hdr_il,
        .f_byte, .f_valid, .f_ready,
        .up_done   (i_done && (i_err == E_OK)),
        .r_byte, .r_valid, .r_ready, .r_sol, .r_y, .r_x0, .r_ldx, .r_pw,
        .complete, .err (u_err), .warn_long
    );

    png_pixel u_pixel (
        .clk, .rst_n, .start,
        .hdr_valid, .hdr_ctype, .hdr_depth,
        .r_byte, .r_valid, .r_ready, .r_sol, .r_y, .r_x0, .r_ldx, .r_pw,
        .pal_we, .pal_wa, .pal_wd, .alpha_we, .alpha_wa, .alpha_wd,
        .plte_n, .trns_n, .key_valid, .key_r, .key_g, .key_b,
        .px_x, .px_y, .px_rgba, .px_valid, .px_ready,
        .idle (p_idle), .warn_index
    );

    assign warn = c_warn | ({5'd0, warn_long} << W_LONG) | ({5'd0, warn_index} << W_INDEX);

    assign tap_inf_valid = f_valid && f_ready;
    assign tap_inf_byte  = f_byte;
    assign tap_raw_valid = r_valid && r_ready;
    assign tap_raw_byte  = r_byte;

    // the unit is over: consumed to in_last, and either failed or fully drained
    wire all_done = finished && (fatal || (i_done && complete && p_idle));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            err_q <= E_OK;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            if (busy && err_q == E_OK && err_now != E_OK) err_q <= err_now;
            if (busy && all_done) begin
                busy <= 1'b0;
                done <= 1'b1;
                if (err_q == E_OK && err_now != E_OK) err_q <= err_now;
            end
            if (start) begin
                err_q <= E_OK;
                busy  <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
