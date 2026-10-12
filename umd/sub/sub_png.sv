// umd/sub/sub_png.sv -- the PNG decoder on its own clock, between two dual-clock FIFOs
// (docs/subtitles.md §2 "Clocks")
//
// png_top has been synthesised but never timed: it runs on pclk -- clk_sys, the memory
// clock or anything else the integration fit chooses -- and everything around it on mclk.
//   mclk -> pclk: the unit's bytes, {last, byte}; the first byte after a `last` (or after a
//                 reset) starts a new PNG (png_top's start is pulsed from it)
//   pclk -> mclk: the pixels {x, y, RGBA}, then IN BAND after the last one the end marker
//                 {err, w, h} -- a separate pulse could overtake pixels still in the FIFO
// Each side's reset comes from the parent (a flush resets the pclk side through cdc_reset
// there, and both FIFOs).

`default_nettype none

module sub_png (
    input  wire         mclk,
    input  wire         mrst_n,
    input  wire         pclk,
    input  wire         prst_n,

    // the unit's bytes (mclk)
    input  wire  [7:0]  b_byte,
    input  wire         b_valid,
    input  wire         b_last,
    output logic        b_ready,

    // pixels and the end marker (mclk)
    output logic        p_valid,
    output logic        p_end,
    output logic [15:0] p_x,
    output logic [15:0] p_y,
    output logic [31:0] p_rgba,
    output logic [4:0]  p_err,
    output logic [15:0] p_w,
    output logic [15:0] p_h,
    input  wire         p_ready
);

    // ---- mclk -> pclk: bytes -----------------------------------------------------------------------
    logic        bf_full, bf_empty, bf_valid, bf_rd;
    logic [8:0]  bf_dout;
    assign b_ready = !bf_full;
    fifo_dc #(.DW(9), .AW(4)) u_bf (
        .wr_clk (mclk), .wr_rst_n (mrst_n), .din ({b_last, b_byte}), .wr_en (b_valid && !bf_full),
        .full (bf_full), .wr_free (),
        .rd_clk (pclk), .rd_rst_n (prst_n), .dout (bf_dout), .rd_en (bf_rd), .empty (bf_empty),
        .valid (bf_valid)
    );

    // pclk: a one-byte head over the pull port, and png_top
    logic [8:0]  head;
    logic        head_v, pend;              // pend: a pop is in flight
    logic        newu;                      // the next byte starts a new PNG
    logic        startp;
    logic        in_ready;
    logic        mark;                      // the end marker is due (done seen, not yet written)
    logic [4:0]  m_err;
    logic [15:0] m_w, m_h;
    wire         in_valid = head_v && !newu;
    wire         in_take  = in_valid && in_ready;
    assign bf_rd = !bf_empty && !pend && (!head_v || in_take);

    logic        hdr_valid, px_valid, px_ready, busy, done;
    logic [15:0] hdr_w, hdr_h, px_x, px_y;
    logic [4:0]  err;
    logic [31:0] px_rgba;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [2:0]  hdr_ctype;
    logic [4:0]  hdr_depth;
    logic        hdr_il;
    logic [5:0]  warn;
    /* verilator lint_on UNUSEDSIGNAL */
    png_top u_png (
        .clk (pclk), .rst_n (prst_n), .start (startp),
        .in_byte (head[7:0]), .in_valid (in_valid), .in_last (head[8]), .in_ready (in_ready),
        .hdr_valid, .hdr_w, .hdr_h, .hdr_ctype, .hdr_depth, .hdr_il,
        .px_x, .px_y, .px_rgba, .px_valid, .px_ready,
        .busy, .done, .err, .warn,
        .tap_inf_valid (), .tap_inf_byte (), .tap_raw_valid (), .tap_raw_byte ()
    );

    always_ff @(posedge pclk) begin
        if (!prst_n) begin
            head_v <= 1'b0; pend <= 1'b0; newu <= 1'b1; startp <= 1'b0;
        end else begin
            startp <= 1'b0;
            pend   <= bf_rd;
            if (in_take) head_v <= 1'b0;
            if (pend && bf_valid) begin head <= bf_dout; head_v <= 1'b1; end
            // a new PNG: pulse start with its first byte held, then feed
            // (only once the previous PNG is done and its end marker is written)
            if (head_v && newu && !startp && !busy && !mark) startp <= 1'b1;
            if (startp) newu <= 1'b0;
            if (in_take && head[8]) newu <= 1'b1;
        end
    end

    // ---- pclk -> mclk: pixels, then the end marker ------------------------------------------------
    // word: {end, x 16, y 16, rgba 32}; the marker's fields ride in the same bits:
    // {1, w 16, h 16, 27'd0, err 5}
    logic        pf_full, pf_empty, pf_valid, pf_rd;
    logic [64:0] pf_dout;
    assign px_ready = !pf_full && !mark;
    wire  [64:0] pf_din = mark ? {1'b1, m_w, m_h, 27'd0, m_err} : {1'b0, px_x, px_y, px_rgba};
    wire         pf_wr  = !pf_full && (mark || px_valid);
    always_ff @(posedge pclk) begin
        if (!prst_n) mark <= 1'b0;
        else begin
            if (hdr_valid) begin m_w <= hdr_w; m_h <= hdr_h; end
            if (startp)    begin m_w <= 16'd0; m_h <= 16'd0; end
            if (done) begin mark <= 1'b1; m_err <= err; end
            else if (mark && !pf_full) mark <= 1'b0;
        end
    end
    fifo_dc #(.DW(65), .AW(4)) u_pf (
        .wr_clk (pclk), .wr_rst_n (prst_n), .din (pf_din), .wr_en (pf_wr), .full (pf_full), .wr_free (),
        .rd_clk (mclk), .rd_rst_n (mrst_n), .dout (pf_dout), .rd_en (pf_rd), .empty (pf_empty),
        .valid (pf_valid)
    );

    // mclk: a one-word head over the pull port
    logic [64:0] ph;
    logic        ph_v, ppend;
    wire         p_take = p_valid && p_ready;
    assign pf_rd   = !pf_empty && !ppend && (!ph_v || p_take);
    assign p_valid = ph_v;
    assign p_end   = ph[64];
    assign p_x     = ph[63:48];
    assign p_y     = ph[47:32];
    assign p_rgba  = ph[31:0];
    assign p_w     = ph[63:48];
    assign p_h     = ph[47:32];
    assign p_err   = ph[4:0];
    always_ff @(posedge mclk) begin
        if (!mrst_n) begin ph_v <= 1'b0; ppend <= 1'b0; end
        else begin
            ppend <= pf_rd;
            if (p_take) ph_v <= 1'b0;
            if (ppend && pf_valid) begin ph <= pf_dout; ph_v <= 1'b1; end
        end
    end

endmodule

`default_nettype wire
