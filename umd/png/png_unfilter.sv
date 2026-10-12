// umd/png/png_unfilter.sv -- PNG scanline reconstruction (filters 0-4) and the Adam7
// pass walk (PNG spec 9, 8.2; docs/png_decode.md §3)
//
// In: the inflated bytes (a filter byte, then the row's bytes, row after row, pass after
// pass). Out: the reconstructed row bytes, one a cycle, with the row's geometry beside
// them (the pixel stage latches it at r_sol).
//
// The filter step is the pixel's byte count rounded up to 1 (bpp 1, 2, 3, 4, 6, 8 for
// every colour type and depth). The previous row lives in an 8 KB RAM (MAX_ROW_BYTES;
// the chunk layer refuses wider rows) holding RECONSTRUCTED bytes -- the inflate window
// holds filtered ones, so it cannot stand in. It is read one column ahead: the byte at
// col+1 is requested while col is written, so a byte a cycle needs no forwarding, and
// the filter-byte cycle re-reads column 0 after the row that just wrote it. "a" and "c"
// (bpp bytes back, in this row and the previous one) come from 8-byte histories.
//
// Adam7: 7 passes, each (x0, y0, 2^ldx, 2^ldy); a pass with no columns or no rows has no
// bytes at all (not even filter bytes) and is skipped; each pass starts with "no
// previous row" (b = c = 0 on its first row). Non-interlaced is one pass (0, 0, 1, 1).
//
// Verdicts: a filter type > 4 is E_FILTER; the zlib stream ending (up_done) before the
// last row is E_SHORT (libpng calls it benign; the decoder is stricter); bytes after the
// last row are dropped and flagged (W_LONG).

`default_nettype none

module png_unfilter
    import png_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire        hdr_valid,
    input  wire [15:0] hdr_w,
    input  wire [15:0] hdr_h,
    input  wire [2:0]  hdr_ctype,
    input  wire [4:0]  hdr_depth,
    input  wire        hdr_il,

    input  wire  [7:0] f_byte,
    input  wire        f_valid,
    output logic       f_ready,
    input  wire        up_done,            // inflate finished cleanly: no more bytes

    output logic [7:0]  r_byte,
    output logic        r_valid,
    input  wire         r_ready,
    output logic        r_sol,             // the row's first byte
    output logic [15:0] r_y,
    output logic [2:0]  r_x0,
    output logic [1:0]  r_ldx,
    output logic [15:0] r_pw,

    output logic       complete,           // every row out (and taken)
    output logic [4:0] err,
    output logic       warn_long
);

    typedef enum logic [2:0] {U_IDLE, U_PASS, U_FB, U_DATA, U_DONE, U_ERR} ustate_t;
    ustate_t state;

    logic [15:0] w, h;
    logic        il;
    logic [2:0]  pass;
    logic [15:0] pw, ph, j, y;
    logic [2:0]  x0;
    logic [1:0]  ldx, ldy;
    logic [13:0] rowbytes, col;
    logic [2:0]  ftype;
    logic [3:0]  bpp;
    logic [6:0]  bits_pp;

    // ---- the pass table ----------------------------------------------------------------------
    logic [2:0] px0, py0;
    logic [1:0] pldx, pldy;
    always_comb begin
        if (!il) begin px0 = 3'd0; py0 = 3'd0; pldx = 2'd0; pldy = 2'd0; end
        else case (pass)
            3'd0: begin px0 = 3'd0; py0 = 3'd0; pldx = 2'd3; pldy = 2'd3; end
            3'd1: begin px0 = 3'd4; py0 = 3'd0; pldx = 2'd3; pldy = 2'd3; end
            3'd2: begin px0 = 3'd0; py0 = 3'd4; pldx = 2'd2; pldy = 2'd3; end
            3'd3: begin px0 = 3'd2; py0 = 3'd0; pldx = 2'd2; pldy = 2'd2; end
            3'd4: begin px0 = 3'd0; py0 = 3'd2; pldx = 2'd1; pldy = 2'd2; end
            3'd5: begin px0 = 3'd1; py0 = 3'd0; pldx = 2'd1; pldy = 2'd1; end
            default: begin px0 = 3'd0; py0 = 3'd1; pldx = 2'd0; pldy = 2'd1; end
        endcase
    end
    // pass width / height: ceil((w - x0) / dx) when w > x0
    wire [15:0] w_m = w - {13'd0, px0} - 16'd1;
    wire [15:0] h_m = h - {13'd0, py0} - 16'd1;
    wire [15:0] ppw = (w > {13'd0, px0}) ? ((w_m >> pldx) + 16'd1) : 16'd0;
    wire [15:0] pph = (h > {13'd0, py0}) ? ((h_m >> pldy) + 16'd1) : 16'd0;
    /* verilator lint_off UNUSEDSIGNAL */      // the top bits: 0 for any accepted image
    logic [22:0] prowbits;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        case (bits_pp)
            7'd1:  prowbits = {7'd0, ppw};
            7'd2:  prowbits = {6'd0, ppw, 1'b0};
            7'd4:  prowbits = {5'd0, ppw, 2'b0};
            7'd8:  prowbits = {4'd0, ppw, 3'b0};
            7'd16: prowbits = {3'd0, ppw, 4'b0};
            7'd24: prowbits = {3'd0, ppw, 4'b0} + {4'd0, ppw, 3'b0};
            7'd32: prowbits = {2'd0, ppw, 5'b0};
            7'd48: prowbits = {2'd0, ppw, 5'b0} + {3'd0, ppw, 4'b0};
            default: prowbits = {1'd0, ppw, 6'b0};
        endcase
    end
    // <= MAX_ROW_BYTES: png_chunks refused anything wider, so 14 bits hold it
    wire [13:0] prowbytes = prowbits[16:3] + {13'd0, (prowbits[2:0] != 3'd0)};

    // bits per pixel, bytes per filter step
    logic [6:0] hbits;
    always_comb begin
        case (hdr_ctype)
            3'd2:    hbits = (hdr_depth == 5'd16) ? 7'd48 : 7'd24;
            3'd4:    hbits = (hdr_depth == 5'd16) ? 7'd32 : 7'd16;
            3'd6:    hbits = (hdr_depth == 5'd16) ? 7'd64 : 7'd32;
            default: hbits = {2'd0, hdr_depth};
        endcase
    end

    // ---- previous row RAM (reconstructed bytes), read one column ahead ---------------------
    logic [7:0]  prow [0:MAX_ROW_BYTES-1];
    logic [12:0] pr_ra;
    logic [7:0]  pr_q;
    logic        pr_we;
    logic [7:0]  recon;

    // ---- the filter arithmetic -------------------------------------------------------------------
    logic [7:0] a_hist [0:7];              // [0] = the last reconstructed byte of this row
    logic [7:0] c_hist [0:7];              // [0] = the previous row's byte above it
    logic [7:0] a_bpp, c_bpp;
    always_comb begin
        case (bpp)
            4'd1: begin a_bpp = a_hist[0]; c_bpp = c_hist[0]; end
            4'd2: begin a_bpp = a_hist[1]; c_bpp = c_hist[1]; end
            4'd3: begin a_bpp = a_hist[2]; c_bpp = c_hist[2]; end
            4'd4: begin a_bpp = a_hist[3]; c_bpp = c_hist[3]; end
            4'd6: begin a_bpp = a_hist[5]; c_bpp = c_hist[5]; end
            default: begin a_bpp = a_hist[7]; c_bpp = c_hist[7]; end
        endcase
    end
    wire        first_row = (j == 16'd0);
    wire        left_ok   = (col >= {10'd0, bpp});
    wire [7:0]  fa = left_ok ? a_bpp : 8'd0;
    wire [7:0]  fb = first_row ? 8'd0 : pr_q;
    wire [7:0]  fc = (left_ok && !first_row) ? c_bpp : 8'd0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [8:0]  avg_sum = {1'b0, fa} + {1'b0, fb};      // the 9-bit sum, halved
    /* verilator lint_on UNUSEDSIGNAL */
    wire [7:0]  avg_half = avg_sum[8:1];
    // Paeth: p = a + b - c; pa = |b - c|, pb = |a - c|, pc = |a + b - 2c|
    wire signed [9:0] da  = $signed({2'b0, fa}) - $signed({2'b0, fc});
    wire signed [9:0] db  = $signed({2'b0, fb}) - $signed({2'b0, fc});
    wire signed [9:0] dab = da + db;
    wire [9:0]  pa = db[9]  ? -db  : db;
    wire [9:0]  pb = da[9]  ? -da  : da;
    wire [9:0]  pc = dab[9] ? -dab : dab;
    wire [7:0]  paeth = ((pa <= pb) && (pa <= pc)) ? fa : (pb <= pc) ? fb : fc;
    always_comb begin
        case (ftype)
            3'd0:    recon = f_byte;
            3'd1:    recon = f_byte + fa;
            3'd2:    recon = f_byte + fb;
            3'd3:    recon = f_byte + avg_half;
            default: recon = f_byte + paeth;
        endcase
    end

    // ---- handshakes -----------------------------------------------------------------------------------
    wire out_free = !r_valid || r_ready;
    always_comb begin
        case (state)
            U_FB:    f_ready = 1'b1;
            U_DATA:  f_ready = out_free;
            U_DONE:  f_ready = 1'b1;              // bytes past the image: dropped
            default: f_ready = 1'b0;
        endcase
    end
    wire take = f_valid && f_ready;
    wire take_data = take && (state == U_DATA);
    wire row_end   = (col == rowbytes - 14'd1);

    always_comb begin
        pr_we = take_data;
        if (state == U_DATA) pr_ra = take_data ? (col[12:0] + 13'd1) : col[12:0];
        else                 pr_ra = 13'd0;
    end

    always_ff @(posedge clk) begin
        if (pr_we) prow[col[12:0]] <= recon;
        pr_q <= prow[pr_ra];
    end

    assign complete = (state == U_DONE) && !r_valid;

    integer k;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= U_IDLE;
            err       <= E_OK;
            warn_long <= 1'b0;
            r_valid   <= 1'b0;
        end else begin
            if (r_valid && r_ready) r_valid <= 1'b0;
            case (state)
                U_IDLE: if (hdr_valid) begin
                    w       <= hdr_w;
                    h       <= hdr_h;
                    il      <= hdr_il;
                    bits_pp <= hbits;
                    case (hbits)
                        7'd16:   bpp <= 4'd2;
                        7'd24:   bpp <= 4'd3;
                        7'd32:   bpp <= 4'd4;
                        7'd48:   bpp <= 4'd6;
                        7'd64:   bpp <= 4'd8;
                        default: bpp <= 4'd1;
                    endcase
                    pass  <= 3'd0;
                    state <= U_PASS;
                end
                U_PASS: begin
                    if (ppw == 16'd0 || pph == 16'd0) begin      // an empty pass: no bytes
                        if (!il || pass == 3'd6) state <= U_DONE;
                        pass <= pass + 3'd1;
                    end else begin
                        pw       <= ppw;
                        ph       <= pph;
                        x0       <= px0;
                        ldx      <= pldx;
                        ldy      <= pldy;
                        y        <= {13'd0, py0};
                        j        <= 16'd0;
                        rowbytes <= prowbytes;
                        state    <= U_FB;
                    end
                end
                U_FB: if (take) begin
                    if (f_byte > 8'd4) begin
                        err   <= E_FILTER;
                        state <= U_ERR;
                    end else begin
                        ftype <= f_byte[2:0];
                        col   <= 14'd0;
                        state <= U_DATA;
                    end
                end else if (up_done && !f_valid) begin
                    err   <= E_SHORT;
                    state <= U_ERR;
                end
                U_DATA: if (take) begin
                    r_valid <= 1'b1;
                    r_byte  <= recon;
                    r_sol   <= (col == 14'd0);
                    r_y     <= y;
                    r_x0    <= x0;
                    r_ldx   <= ldx;
                    r_pw    <= pw;
                    a_hist[0] <= recon;
                    c_hist[0] <= fb;
                    for (k = 1; k < 8; k = k + 1) begin
                        a_hist[k] <= a_hist[k-1];
                        c_hist[k] <= c_hist[k-1];
                    end
                    col <= col + 14'd1;
                    if (row_end) begin
                        j <= j + 16'd1;
                        y <= y + (16'd1 << ldy);
                        if (j == ph - 16'd1) begin
                            if (!il || pass == 3'd6) state <= U_DONE;
                            else begin pass <= pass + 3'd1; state <= U_PASS; end
                        end else state <= U_FB;
                    end
                end else if (up_done && !f_valid) begin
                    err   <= E_SHORT;
                    state <= U_ERR;
                end
                U_DONE: if (take) warn_long <= 1'b1;
                default: ;
            endcase

            if (start) begin
                state     <= U_IDLE;
                err       <= E_OK;
                warn_long <= 1'b0;
                r_valid   <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
