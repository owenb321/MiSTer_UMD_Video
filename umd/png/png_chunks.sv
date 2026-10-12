// umd/png/png_chunks.sv -- the PNG container: signature, chunks, CRC-32, IHDR / PLTE /
// tRNS, and the IDAT payload handed to inflate (docs/png_decode.md §3)
//
// One byte a cycle. Every chunk's CRC-32 is checked: a bad critical chunk (IHDR, PLTE,
// IDAT, IEND) is fatal (E_CRC; IEND too, where libpng only warns), a bad ancillary chunk
// is discarded and flagged (W_ANC_CRC) -- so a tRNS is committed (trns_n, the key) only
// after its CRC, its entries written early are invisible until then.
//
// libpng's verdicts decide what is fatal and what is ignored (measured with
// tools/png_oracle.c; tools/png_golden.py checks every refused case against it):
//   fatal   : a type byte that is not a letter, an unknown critical chunk (E_CRITICAL);
//             a length >= 2^31, IHDR not first or twice, PLTE after IDAT, a palette
//             image without PLTE, IEND before IDAT (E_ORDER); a PLTE of
//             0 / > 256 entries / not 3n bytes in a palette image, or twice (E_PLTE)
//   ignored : PLTE in a grey image; a PLTE in a truecolour image (silently, a suggested
//             palette); a tRNS out of place, twice, of the wrong length, in a type with
//             an alpha channel, or longer than the palette; data in IEND (W_IGNORED)
//   kept    : a PLTE with more entries than the depth can index (unreachable)
//   dropped : IDAT data after the first run of IDAT chunks -- the zlib stream ends at
//             the first other chunk (inflate: E_ZSHORT if it was not complete);
//             complete, a later IDAT is extra data (W_ZEXTRA), as libpng takes it
//
// The input is a unit (in_last on its final byte): after IEND the rest is drained
// (W_AFTER_IEND), after a fatal error -- here or downstream (`abort`) -- everything is
// drained, and an in_last before IEND is E_TRUNC. `finished` = the unit is consumed.
//
// A verdict here is the FIRST error in stream order, as libpng reports it: a fatal error
// found by this layer is held (C_PEND, no input taken) until the pipeline is `quiet` --
// inflate waiting for input or finished, its output taken -- so an inflate / filter
// error in bytes already delivered, still being decoded, wins; the verdict does not
// depend on how the handshakes were timed (bench/umd/png_tb.sv +stall).

`default_nettype none

module png_chunks
    import png_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        abort,              // a fatal error downstream: drain the unit
    input  wire        quiet,              // every byte handed to inflate is fully decoded

    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    input  wire        in_last,
    output logic       in_ready,

    // the image header, valid from hdr_valid (a pulse) to the next start
    output logic        hdr_valid,
    output logic [15:0] hdr_w,
    output logic [15:0] hdr_h,
    output logic [2:0]  hdr_ctype,
    output logic [4:0]  hdr_depth,
    output logic        hdr_il,

    // the zlib stream (the IDAT payloads, concatenated)
    output logic       z_start,            // pulse: a stream begins (IHDR accepted)
    output logic [7:0] z_byte,
    output logic       z_valid,
    input  wire        z_ready,
    input  wire        z_done,             // inflate finished: what is left is dropped
    output logic       z_end,              // no more IDAT data will come

    // the palette (written during PLTE / tRNS; entries past plte_n / trns_n are unset)
    output logic        pal_we,
    output logic [7:0]  pal_wa,
    output logic [23:0] pal_wd,
    output logic        alpha_we,
    output logic [7:0]  alpha_wa,
    output logic [7:0]  alpha_wd,
    output logic [8:0]  plte_n,
    output logic [8:0]  trns_n,
    output logic        key_valid,         // a grey (key_r) / truecolour key from tRNS
    output logic [15:0] key_r,
    output logic [15:0] key_g,
    output logic [15:0] key_b,

    output logic       finished,
    output logic [4:0] err,
    output logic [5:0] warn
);

    typedef enum logic [3:0] {C_IDLE, C_SIG, C_LEN, C_TYPE, C_DATA, C_CRC, C_AFTER, C_DRAIN, C_PEND, C_FIN} cstate_t;
    cstate_t state;

    typedef enum logic [2:0] {K_IHDR, K_PLTE, K_TRNS, K_IDAT, K_IDAT2, K_IEND, K_SKIP} kind_t;
    kind_t kind;

    logic [31:0] clen;                     // chunk length
    logic [31:0] bc;                       // bytes left in this field
    logic [23:0] ctyp;                     // the type's first three bytes
    logic [31:0] crc;
    logic        ignore;                   // PLTE / tRNS / IEND data ignored (no commit)
    logic        seen_ihdr, seen_plte, seen_trns, seen_idat, idat_ended;
    logic [2:0]  sigi;
    logic [3:0]  hi;                       // IHDR byte index
    // IHDR's width / height are u31 (bit 31 set: E_IHDR); past 65535 the PNG is refused (E_SIZE),
    // so 16 bits are kept, with bit 31 (w_top) and "bits 30:16 not all zero" (w_hi) as flags --
    // the same verdicts as the 32-bit fields (docs/area_plan.md A3)
    logic [15:0] ih_w, ih_h;
    logic        w_top, w_hi, h_top, h_hi;
    logic [7:0]  ih_depth, ih_ctype, ih_comp, ih_filt, ih_il;
    logic [1:0]  comp;                     // PLTE: colour component 0..2
    logic [8:0]  ent;                      // PLTE / tRNS entry index
    logic [7:0]  pr, pg;
    // the tRNS key is written straight into key_r / g / b; key_valid rises only on a good
    // CRC (a bad one leaves it 0, and seen_trns ignores any later tRNS), so no shadow is kept
    logic [2:0]  ki;
    logic [4:0]  pend_err;                 // C_PEND: the verdict waiting for `quiet`
    logic        pend_last;                //         and whether in_last was taken

    // ---- CRC-32 (reflected 0xEDB88320) over type + data --------------------------------------
    logic [31:0] crc_n;
    always_comb begin
        crc_n = crc ^ {24'd0, in_byte};
        for (int k = 0; k < 8; k++)
            crc_n = crc_n[0] ? ((crc_n >> 1) ^ 32'hEDB88320) : (crc_n >> 1);
    end

    // ---- consuming ---------------------------------------------------------------------------------
    wire idat_data  = (state == C_DATA) && (kind == K_IDAT);
    always_comb begin
        in_ready = 1'b0;
        case (state)
            C_SIG, C_LEN, C_TYPE, C_CRC, C_AFTER, C_DRAIN: in_ready = 1'b1;
            C_DATA: in_ready = idat_data ? (z_ready || z_done) : 1'b1;
            default: ;
        endcase
        if (abort && state != C_IDLE && state != C_FIN && state != C_PEND) in_ready = 1'b1;
    end
    wire take = in_valid && in_ready;
    assign z_byte  = in_byte;
    assign z_valid = idat_data && in_valid && !z_done && !abort;
    // (not in C_PEND: a pending verdict must not end the stream and starve inflate into
    // an E_ZSHORT of its own -- the unit ending inside IDAT data is E_TRUNC)
    assign z_end   = idat_ended || (state == C_AFTER) || (state == C_FIN) || (state == C_DRAIN);
    assign finished = (state == C_FIN);

    // ---- the chunk type, decided when its 4th byte arrives -----------------------------------
    wire [31:0] typ_n = {ctyp, in_byte};
`define LETTER(c) ((((c) >= 8'd65) && ((c) <= 8'd90)) || (((c) >= 8'd97) && ((c) <= 8'd122)))
    wire        typ_ok   = `LETTER(typ_n[31:24]) && `LETTER(typ_n[23:16]) &&
                           `LETTER(typ_n[15:8])  && `LETTER(typ_n[7:0]);
`undef LETTER
    wire        typ_crit = !typ_n[29];                  // bit 5 of the first byte clear
    localparam logic [31:0] T_IHDR = 32'h49484452, T_PLTE = 32'h504C5445, T_TRNS = 32'h74524E53,
                            T_IDAT = 32'h49444154, T_IEND = 32'h49454E44;

    // ---- IHDR checks (at its CRC) ----------------------------------------------------------------
    logic depth_ok;
    logic [6:0] bits_pp;                   // bits per pixel
    always_comb begin
        case (ih_ctype)
            8'd0: depth_ok = (ih_depth == 8'd1) || (ih_depth == 8'd2) || (ih_depth == 8'd4) ||
                             (ih_depth == 8'd8) || (ih_depth == 8'd16);
            8'd3: depth_ok = (ih_depth == 8'd1) || (ih_depth == 8'd2) || (ih_depth == 8'd4) ||
                             (ih_depth == 8'd8);
            8'd2, 8'd4, 8'd6: depth_ok = (ih_depth == 8'd8) || (ih_depth == 8'd16);
            default: depth_ok = 1'b0;
        endcase
        case (ih_ctype)
            8'd2:    bits_pp = (ih_depth == 8'd16) ? 7'd48 : 7'd24;
            8'd4:    bits_pp = (ih_depth == 8'd16) ? 7'd32 : 7'd16;
            8'd6:    bits_pp = (ih_depth == 8'd16) ? 7'd64 : 7'd32;
            default: bits_pp = ih_depth[6:0];
        endcase
    end
    // row bits = w * bits_pp, as shifts (24 = 16 + 8, 48 = 32 + 16)
    logic [22:0] rowbits;
    always_comb begin
        case (bits_pp)
            7'd1:  rowbits = {7'd0, ih_w};
            7'd2:  rowbits = {6'd0, ih_w, 1'b0};
            7'd4:  rowbits = {5'd0, ih_w, 2'b0};
            7'd8:  rowbits = {4'd0, ih_w, 3'b0};
            7'd16: rowbits = {3'd0, ih_w, 4'b0};
            7'd24: rowbits = {3'd0, ih_w, 4'b0} + {4'd0, ih_w, 3'b0};
            7'd32: rowbits = {2'd0, ih_w, 5'b0};
            7'd48: rowbits = {2'd0, ih_w, 5'b0} + {3'd0, ih_w, 4'b0};
            default: rowbits = {1'd0, ih_w, 6'b0};
        endcase
    end
    wire [19:0] rowbytes  = rowbits[22:3] + {19'd0, (rowbits[2:0] != 3'd0)};
    wire        ihdr_bad  = ((ih_w == 16'd0) && !w_hi && !w_top) || ((ih_h == 16'd0) && !h_hi && !h_top) || w_top || h_top ||
                            !depth_ok || (ih_comp != 8'd0) || (ih_filt != 8'd0) || (ih_il > 8'd1);
    wire        ihdr_big  = w_top || w_hi || h_top || h_hi ||
                            (rowbytes > MAX_ROW_BYTES);

    wire [31:0] crc_fin  = ~crc;
    wire        crc_good = ({clen[23:0], in_byte} == crc_fin);   // at the CRC's last byte
    wire        crit     = (kind != K_SKIP) && (kind != K_TRNS);

    // the signature, 89 50 4E 47 0D 0A 1A 0A
    logic [7:0] sig_want;
    always_comb begin
        case (sigi)
            3'd0: sig_want = 8'h89; 3'd1: sig_want = 8'h50; 3'd2: sig_want = 8'h4E; 3'd3: sig_want = 8'h47;
            3'd4: sig_want = 8'h0D; 3'd5: sig_want = 8'h0A; 3'd6: sig_want = 8'h1A; default: sig_want = 8'h0A;
        endcase
    end

`define CFAIL(c) begin pend_err <= (c); pend_last <= take && in_last; state <= C_PEND; end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= C_IDLE;
            err       <= E_OK;
            warn      <= 6'd0;
            hdr_valid <= 1'b0;
            z_start   <= 1'b0;
            pal_we    <= 1'b0;
            alpha_we  <= 1'b0;
        end else begin
            hdr_valid <= 1'b0;
            z_start   <= 1'b0;
            pal_we    <= 1'b0;
            alpha_we  <= 1'b0;

            if (state == C_PEND) begin
                // an earlier error downstream wins; else commit ours once all is decoded
                if (abort) begin
                    if (pend_last) state <= C_FIN; else state <= C_DRAIN;
                end else if (quiet) begin
                    err <= pend_err;
                    if (pend_last) state <= C_FIN; else state <= C_DRAIN;
                end
            end else if (abort && state != C_IDLE && state != C_FIN && state != C_DRAIN) begin
                if (take && in_last) state <= C_FIN; else state <= C_DRAIN;
            end else if (take) begin
                case (state)
                    C_SIG: begin
                        sigi <= sigi + 3'd1;
                        if (in_byte != sig_want)   `CFAIL(E_SIG)
                        else if (in_last)          `CFAIL(E_TRUNC)
                        else if (sigi == 3'd7) begin state <= C_LEN; bc <= 32'd4; end
                    end

                    C_LEN: begin
                        clen <= {clen[23:0], in_byte};
                        bc   <= bc - 32'd1;
                        if (in_last) `CFAIL(E_TRUNC)
                        else if (bc == 32'd1) begin
                            if (clen[23]) `CFAIL(E_ORDER)             // >= 2^31
                            else begin
                                state <= C_TYPE;
                                bc    <= 32'd4;
                                crc   <= 32'hFFFFFFFF;
                            end
                        end
                    end

                    C_TYPE: begin
                        ctyp <= typ_n[23:0];
                        crc  <= crc_n;
                        bc   <= bc - 32'd1;
                        if (in_last) `CFAIL(E_TRUNC)
                        else if (bc == 32'd1) begin
                            ignore <= 1'b0;
                            kind   <= K_SKIP;
                            hi     <= 4'd0;
                            comp   <= 2'd0;
                            ent    <= 9'd0;
                            ki     <= 3'd0;
                            if (seen_idat && typ_n != T_IDAT) idat_ended <= 1'b1;
                            bc <= clen;
                            if (clen == 32'd0) begin state <= C_CRC; bc <= 32'd4; end
                            else state <= C_DATA;
                            if (!typ_ok)                                  `CFAIL(E_CRITICAL)
                            else if (!seen_ihdr && typ_n != T_IHDR)       `CFAIL(E_ORDER)
                            else if (typ_n == T_IHDR) begin
                                seen_ihdr <= 1'b1;
                                if (seen_ihdr)                            `CFAIL(E_ORDER)
                                else if (clen != 32'd13)                  `CFAIL(E_IHDR)
                                else kind <= K_IHDR;
                            end else if (typ_n == T_IDAT) begin
                                if (idat_ended)                           kind <= K_IDAT2;
                                else if (ih_ctype == 8'd3 && !seen_plte)  `CFAIL(E_ORDER)
                                else begin kind <= K_IDAT; seen_idat <= 1'b1; end
                            end else if (typ_n == T_PLTE) begin
                                if (seen_idat)                            `CFAIL(E_ORDER)
                                else if (seen_plte)                       `CFAIL(E_PLTE)
                                else if (ih_ctype == 8'd3 && (clen == 32'd0 || clen > 32'd768))
                                                                          `CFAIL(E_PLTE)
                                else begin
                                    kind      <= K_PLTE;
                                    seen_plte <= 1'b1;
                                    // grey: ignored (flagged); truecolour: a suggested
                                    // palette, ignored (flagged only if malformed)
                                    if (ih_ctype == 8'd0 || ih_ctype == 8'd4) begin
                                        ignore <= 1'b1; warn[W_IGNORED] <= 1'b1;
                                    end else if (ih_ctype != 8'd3) begin
                                        ignore <= 1'b1;
                                        if (clen == 32'd0 || clen > 32'd768) warn[W_IGNORED] <= 1'b1;
                                    end
                                end
                            end else if (typ_n == T_TRNS) begin
                                kind <= K_TRNS;
                                if (seen_idat || seen_trns || ih_ctype == 8'd4 || ih_ctype == 8'd6 ||
                                    (ih_ctype == 8'd3 && (!seen_plte || clen == 32'd0 || clen > {23'd0, plte_n})) ||
                                    (ih_ctype == 8'd0 && clen != 32'd2) ||
                                    (ih_ctype == 8'd2 && clen != 32'd6)) begin
                                    ignore <= 1'b1;
                                    warn[W_IGNORED] <= 1'b1;
                                end
                                seen_trns <= 1'b1;
                            end else if (typ_n == T_IEND) begin
                                if (!seen_idat)                           `CFAIL(E_ORDER)
                                else begin
                                    kind <= K_IEND;
                                    if (clen != 32'd0) begin ignore <= 1'b1; warn[W_IGNORED] <= 1'b1; end
                                end
                            end else if (typ_crit)                        `CFAIL(E_CRITICAL)
                        end
                    end

                    C_DATA: begin
                        crc <= crc_n;
                        bc  <= bc - 32'd1;
                        case (kind)
                            K_IHDR: begin
                                hi <= hi + 4'd1;
                                case (hi)
                                    4'd0: begin w_top <= in_byte[7]; w_hi <= (in_byte[6:0] != 7'd0); end
                                    4'd1: w_hi <= w_hi || (in_byte != 8'd0);
                                    4'd2, 4'd3: ih_w <= {ih_w[7:0], in_byte};
                                    4'd4: begin h_top <= in_byte[7]; h_hi <= (in_byte[6:0] != 7'd0); end
                                    4'd5: h_hi <= h_hi || (in_byte != 8'd0);
                                    4'd6, 4'd7: ih_h <= {ih_h[7:0], in_byte};
                                    4'd8:  ih_depth <= in_byte;
                                    4'd9:  ih_ctype <= in_byte;
                                    4'd10: ih_comp  <= in_byte;
                                    4'd11: ih_filt  <= in_byte;
                                    default: ih_il  <= in_byte;
                                endcase
                            end
                            K_PLTE: if (!ignore) begin
                                comp <= (comp == 2'd2) ? 2'd0 : comp + 2'd1;
                                if (comp == 2'd0) pr <= in_byte;
                                if (comp == 2'd1) pg <= in_byte;
                                if (comp == 2'd2) begin
                                    pal_we <= 1'b1;
                                    pal_wa <= ent[7:0];
                                    pal_wd <= {pr, pg, in_byte};
                                    ent    <= ent + 9'd1;
                                end
                            end
                            K_TRNS: if (!ignore) begin
                                if (ih_ctype == 8'd3) begin
                                    alpha_we <= 1'b1;
                                    alpha_wa <= ent[7:0];
                                    alpha_wd <= in_byte;
                                    ent      <= ent + 9'd1;
                                end else begin
                                    ki <= ki + 3'd1;
                                    case (ki)
                                        3'd0: key_r[15:8] <= in_byte;
                                        3'd1: key_r[7:0] <= in_byte;
                                        3'd2: key_g[15:8] <= in_byte;
                                        3'd3: key_g[7:0] <= in_byte;
                                        3'd4: key_b[15:8] <= in_byte;
                                        default: key_b[7:0] <= in_byte;
                                    endcase
                                end
                            end
                            K_IDAT: if (z_done && !abort && !z_ready) warn[W_ZEXTRA] <= 1'b1;
                            K_IDAT2: if (!abort) warn[W_ZEXTRA] <= 1'b1;
                            default: ;
                        endcase
                        if (in_last) `CFAIL(E_TRUNC)
                        else if (bc == 32'd1) begin
                            state <= C_CRC;
                            bc    <= 32'd4;
                        end
                    end

                    C_CRC: begin
                        bc   <= bc - 32'd1;
                        clen <= {clen[23:0], in_byte};        // the stored CRC, in clen
                        if (bc != 32'd1) begin
                            if (in_last) `CFAIL(E_TRUNC)
                        end
                        else if (!crc_good && crit)                                    `CFAIL(E_CRC)
                        else if (crc_good && kind == K_IHDR && ihdr_bad)               `CFAIL(E_IHDR)
                        else if (crc_good && kind == K_IHDR && ihdr_big)               `CFAIL(E_SIZE)
                        else if (crc_good && kind == K_PLTE && !ignore && comp != 2'd0) `CFAIL(E_PLTE)
                        else if (in_last && !(crc_good && kind == K_IEND))             `CFAIL(E_TRUNC)
                        else begin
                            state <= C_LEN;
                            bc    <= 32'd4;
                            if (!crc_good) warn[W_ANC_CRC] <= 1'b1;     // discarded
                            else case (kind)
                                K_IHDR: begin
                                    hdr_valid <= 1'b1;
                                    z_start   <= 1'b1;
                                    hdr_w     <= ih_w;
                                    hdr_h     <= ih_h;
                                    hdr_ctype <= ih_ctype[2:0];
                                    hdr_depth <= ih_depth[4:0];
                                    hdr_il    <= ih_il[0];
                                end
                                K_PLTE: if (!ignore) plte_n <= ent;
                                K_TRNS: if (!ignore) begin
                                    if (ih_ctype == 8'd3) trns_n <= ent;
                                    else begin
                                        key_valid <= 1'b1;
                                    end
                                end
                                K_IEND: if (in_last) state <= C_FIN; else state <= C_AFTER;
                                default: ;
                            endcase
                        end
                    end

                    C_AFTER: begin
                        warn[W_AFTER_IEND] <= 1'b1;
                        if (in_last) state <= C_FIN;
                    end

                    C_DRAIN: if (in_last) state <= C_FIN;
                    default: ;
                endcase
            end

            if (start) begin
                state      <= C_SIG;
                err        <= E_OK;
                warn       <= 6'd0;
                sigi       <= 3'd0;
                seen_ihdr  <= 1'b0;
                seen_plte  <= 1'b0;
                seen_trns  <= 1'b0;
                seen_idat  <= 1'b0;
                idat_ended <= 1'b0;
                plte_n     <= 9'd0;
                trns_n     <= 9'd0;
                key_valid  <= 1'b0;
                ih_ctype   <= 8'd0;
            end
        end
    end

`undef CFAIL

endmodule

`default_nettype wire
