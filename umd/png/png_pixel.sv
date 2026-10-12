// umd/png/png_pixel.sv -- reconstructed row bytes -> RGBA8888 pixels with (x, y)
// (PNG spec 7.2, 11.2.3, 11.3.2.1; docs/png_decode.md §3)
//
// Samples are unpacked MSB first; the padding bits at the end of a row are dropped. The
// output is straight (not premultiplied) RGBA as libpng expands it (tools/png_oracle.c,
// the oracle): grey below 8 bits scales by bit replication (x255 / x85 / x17), a 16-bit
// sample keeps its high byte, and a tRNS key is compared with the RAW sample at its full
// depth (a 16-bit key that differs only in the low byte does not match; below 16 bits
// the key is masked to the depth first, as libpng does). A palette index
// at or past the PLTE entries draws opaque black and sets warn_index (libpng: black,
// silently); an index past the tRNS entries is opaque.
//
// The palette RGB (256 x 24) and alpha (256 x 8) RAMs are written by png_chunks during
// PLTE / tRNS -- before any IDAT byte, so never while a pixel reads them.
//
// Pipeline: assembly (a sub-byte sample from the held byte, or a whole pixel's bytes)
// -> s1 (the palette read in flight) -> the output register. One pixel a cycle from a
// held byte; a pixel of n bytes every n + 1 cycles.

`default_nettype none

module png_pixel
    import png_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    input  wire        hdr_valid,
    input  wire [2:0]  hdr_ctype,
    input  wire [4:0]  hdr_depth,

    input  wire  [7:0] r_byte,
    input  wire        r_valid,
    output logic       r_ready,
    input  wire        r_sol,
    input  wire [15:0] r_y,
    input  wire [2:0]  r_x0,
    input  wire [1:0]  r_ldx,
    input  wire [15:0] r_pw,

    input  wire        pal_we,
    input  wire [7:0]  pal_wa,
    input  wire [23:0] pal_wd,
    input  wire        alpha_we,
    input  wire [7:0]  alpha_wa,
    input  wire [7:0]  alpha_wd,
    input  wire [8:0]  plte_n,
    input  wire [8:0]  trns_n,
    input  wire        key_valid,
    input  wire [15:0] key_r,
    input  wire [15:0] key_g,
    input  wire [15:0] key_b,

    output logic [15:0] px_x,
    output logic [15:0] px_y,
    output logic [31:0] px_rgba,           // {R, G, B, A}
    output logic        px_valid,
    input  wire         px_ready,

    output logic       idle,
    output logic       warn_index
);

    logic [2:0]  ctype;
    logic [4:0]  depth;
    logic [3:0]  nbytes;                   // bytes a pixel (depth >= 8)
    wire         sub = (depth < 5'd8);

    // row geometry, latched with the row's first byte
    logic [15:0] ry, rpw, i;
    logic [2:0]  rx0;
    logic [1:0]  rldx;

    // assembly
    logic [7:0]  hb;                       // sub-byte: the held byte, next sample at the top
    logic [3:0]  hn;                       // sub-byte: samples left to emit from it
    logic [63:0] ab;                       // whole-byte: the pixel's bytes, first at the top
    logic [3:0]  an;

    // s1
    logic        s1_valid;
    logic [15:0] s1_x, s1_y;
    logic [15:0] s1_v0, s1_v1, s1_v2, s1_v3;   // raw samples (zero-extended below 16 bits)

    wire out_free = !px_valid || px_ready;
    wire s1_free  = !s1_valid || out_free;

    // ---- the next pixel out of the assembly --------------------------------------------------
    logic        mk;                       // a pixel moves into s1 this cycle
    logic [15:0] v0, v1, v2, v3;
    logic [3:0]  spb;                      // samples a byte (sub-byte)
    always_comb begin
        case (depth)
            5'd1:    spb = 4'd8;
            5'd2:    spb = 4'd4;
            default: spb = 4'd2;
        endcase
        v0 = 16'd0; v1 = 16'd0; v2 = 16'd0; v3 = 16'd0;
        if (sub) begin
            case (depth)
                5'd1:    v0 = {15'd0, hb[7]};
                5'd2:    v0 = {14'd0, hb[7:6]};
                default: v0 = {12'd0, hb[7:4]};
            endcase
        end else if (depth == 5'd16) begin
            case (ctype)
                3'd2:    begin v0 = ab[47:32]; v1 = ab[31:16]; v2 = ab[15:0]; end
                3'd4:    begin v0 = ab[31:16]; v3 = ab[15:0]; end
                3'd6:    begin v0 = ab[63:48]; v1 = ab[47:32]; v2 = ab[31:16]; v3 = ab[15:0]; end
                default: v0 = ab[15:0];
            endcase
        end else begin
            case (ctype)
                3'd2:    begin v0 = {8'd0, ab[23:16]}; v1 = {8'd0, ab[15:8]}; v2 = {8'd0, ab[7:0]}; end
                3'd4:    begin v0 = {8'd0, ab[15:8]};  v3 = {8'd0, ab[7:0]}; end
                3'd6:    begin v0 = {8'd0, ab[31:24]}; v1 = {8'd0, ab[23:16]}; v2 = {8'd0, ab[15:8]}; v3 = {8'd0, ab[7:0]}; end
                default: v0 = {8'd0, ab[7:0]};
            endcase
        end
        mk = s1_free && (sub ? (hn != 4'd0) : (an == nbytes));
    end
    // accept a byte when nothing is held (sub-byte) / the pixel is not complete (whole-byte)
    always_comb r_ready = sub ? (hn == 4'd0) : (an != nbytes);
    wire take = r_valid && r_ready;

    // pixel x = x0 + i * dx
    wire [15:0] cur_x = {13'd0, rx0} + (i << rldx);

    // ---- palette RAMs (the read address follows what s1 will hold next cycle) -------------------
    logic [23:0] pal [0:255];
    logic [7:0]  alp [0:255];
    logic [23:0] pal_q;
    logic [7:0]  alp_q;
    wire  [7:0]  pal_ra = mk ? v0[7:0] : s1_v0[7:0];
    always_ff @(posedge clk) begin
        if (pal_we)   pal[pal_wa] <= pal_wd;
        if (alpha_we) alp[alpha_wa] <= alpha_wd;
        pal_q <= pal[pal_ra];
        alp_q <= alp[pal_ra];
    end

    // ---- compose s1 -> RGBA ------------------------------------------------------------------------
    logic [7:0] g8;
    always_comb begin
        case (depth)
            5'd1:    g8 = {8{s1_v0[0]}};
            5'd2:    g8 = {4{s1_v0[1:0]}};
            5'd4:    g8 = {2{s1_v0[3:0]}};
            5'd16:   g8 = s1_v0[15:8];
            default: g8 = s1_v0[7:0];
        endcase
    end
    wire [7:0] hi0 = (depth == 5'd16) ? s1_v0[15:8] : s1_v0[7:0];
    wire [7:0] hi1 = (depth == 5'd16) ? s1_v1[15:8] : s1_v1[7:0];
    wire [7:0] hi2 = (depth == 5'd16) ? s1_v2[15:8] : s1_v2[7:0];
    wire [7:0] hi3 = (depth == 5'd16) ? s1_v3[15:8] : s1_v3[7:0];
    // libpng compares a key below 16 bits masked to the depth (an out-of-range key
    // 7 at 2 bits matches the sample 3; png_do_expand)
    logic [15:0] kmask;
    always_comb begin
        case (depth)
            5'd1:    kmask = 16'h0001;
            5'd2:    kmask = 16'h0003;
            5'd4:    kmask = 16'h000F;
            5'd8:    kmask = 16'h00FF;
            default: kmask = 16'hFFFF;
        endcase
    end
    wire       key_hit = key_valid && (((s1_v0 ^ key_r) & kmask) == 16'd0) &&
                         ((ctype == 3'd0) || ((((s1_v1 ^ key_g) & kmask) == 16'd0) &&
                                              (((s1_v2 ^ key_b) & kmask) == 16'd0)));
    wire       idx_in_plte = {1'b0, s1_v0[7:0]} < plte_n;
    wire       idx_in_trns = {1'b0, s1_v0[7:0]} < trns_n;
    logic [31:0] rgba;
    always_comb begin
        case (ctype)
            3'd0: rgba = {g8, g8, g8, key_hit ? 8'd0 : 8'd255};
            3'd2: rgba = {hi0, hi1, hi2, key_hit ? 8'd0 : 8'd255};
            3'd3: rgba = {idx_in_plte ? pal_q : 24'd0, idx_in_trns ? alp_q : 8'd255};
            3'd4: rgba = {hi0, hi0, hi0, hi3};
            default: rgba = {hi0, hi1, hi2, hi3};
        endcase
    end

    assign idle = !s1_valid && !px_valid && (hn == 4'd0) && (an == 4'd0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid   <= 1'b0;
            px_valid   <= 1'b0;
            hn         <= 4'd0;
            an         <= 4'd0;
            warn_index <= 1'b0;
        end else begin
            if (hdr_valid) begin
                ctype <= hdr_ctype;
                depth <= hdr_depth;
                case (hdr_ctype)
                    3'd2:    nbytes <= (hdr_depth == 5'd16) ? 4'd6 : 4'd3;
                    3'd4:    nbytes <= (hdr_depth == 5'd16) ? 4'd4 : 4'd2;
                    3'd6:    nbytes <= (hdr_depth == 5'd16) ? 4'd8 : 4'd4;
                    default: nbytes <= (hdr_depth == 5'd16) ? 4'd2 : 4'd1;
                endcase
            end

            // output register
            if (px_valid && px_ready) px_valid <= 1'b0;
            if (s1_valid && out_free) begin
                px_valid <= 1'b1;
                px_x     <= s1_x;
                px_y     <= s1_y;
                px_rgba  <= rgba;
                if (ctype == 3'd3 && !idx_in_plte) warn_index <= 1'b1;
            end

            // s1
            if (s1_free) s1_valid <= 1'b0;
            if (mk) begin
                s1_valid <= 1'b1;
                s1_x     <= cur_x;
                s1_y     <= ry;
                s1_v0    <= v0;
                s1_v1    <= v1;
                s1_v2    <= v2;
                s1_v3    <= v3;
                i        <= i + 16'd1;
                if (sub) begin
                    hb <= hb << depth;
                    hn <= hn - 4'd1;
                end else an <= 4'd0;
            end

            // assembly
            if (take) begin
                if (r_sol) begin
                    ry   <= r_y;
                    rpw  <= r_pw;
                    rx0  <= r_x0;
                    rldx <= r_ldx;
                    i    <= 16'd0;
                end
                if (sub) begin
                    hb <= r_byte;
                    // samples in this byte: all of them, or what is left of the row
                    if (r_sol) hn <= (r_pw < {12'd0, spb}) ? r_pw[3:0] : spb;
                    else       hn <= ((rpw - i) < {12'd0, spb}) ? (rpw[3:0] - i[3:0]) : spb;
                end else begin
                    ab <= {ab[55:0], r_byte};
                    an <= an + 4'd1;
                end
            end

            if (start) begin
                s1_valid   <= 1'b0;
                px_valid   <= 1'b0;
                hn         <= 4'd0;
                an         <= 4'd0;
                warn_index <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
