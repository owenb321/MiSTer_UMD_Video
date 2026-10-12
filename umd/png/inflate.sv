// umd/png/inflate.sv -- zlib (RFC 1950) + DEFLATE (RFC 1951) decoder, bit-serial
//
// The decode method is puff's (zlib contrib/puff; tools/inflate_ref.py is a port): a
// canonical Huffman code is held as count[len] (codes of each length) plus the symbols
// sorted by code, and a symbol is decoded ONE CODE BIT PER CYCLE by walking the lengths
// with (code, first, index) -- no lookup table, no barrel shifter. A block's tables are
// built from its code lengths by a Kraft pass (offsets + over/incomplete checks, 15
// cycles) and a counting sort (one symbol a cycle). Area over speed on purpose: the
// largest subtitle inflates to ~106 KB, and a few cycles a byte is milliseconds
// (docs/png_decode.md §2, §6).
//
// Memories (one synchronous read port each): the 32 KB window -- the spec maximum, and
// subtitle PNGs use distances up to 32,486 -- the symbol table (lit/len 288 at 0,
// distance 32 at 288, code-length 19 at 320) and the code lengths (lit/len at 0,
// distance at 288).
//
// Verdicts follow zlib's, message for message (png_pkg): the zlib header and the
// Adler-32 are part of the stream; an incomplete code is legal only as a lone 1-bit
// code (lit/len and distance), an empty distance code only until a match uses it.
// A code-length code with no codes at all is refused here as E_CLSET when a length is
// decoded (zlib decodes it as zeros and then reports a missing end-of-block): the one
// verdict that is not zlib's, on a stream no encoder writes.
//
// Handshakes: in_* is the IDAT payload (in_end: nothing more will come, so a bit
// needed now is E_ZSHORT); out_* one byte at a time. `done` rises when the Adler
// matched or at the first error (`err`); in_ready stays low after it (the chunk layer
// drops what is left of the IDAT data).

`default_nettype none

module inflate
    import png_pkg::*;
(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,              // begin a zlib stream (clears everything)

    input  wire  [7:0] in_byte,
    input  wire        in_valid,
    output logic       in_ready,
    input  wire        in_end,

    output logic [7:0] out_byte,
    output logic       out_valid,
    input  wire        out_ready,

    output logic       done,
    output logic [4:0] err
);

    typedef enum logic [4:0] {
        S_IDLE, S_ZH, S_BITS, S_BHDR, S_ST_LEN, S_ST_COPY, S_FIX_FILL, S_DYN_HDR, S_CL_READ,
        S_KRAFT, S_SORT, S_DEC, S_SYM, S_CL_SYM, S_CL_REP, S_CL_WRITE, S_LIT, S_LEN_X,
        S_DIST, S_DIST_X, S_COPY_PRE, S_COPY, S_ADLER, S_DONE
    } state_t;
    state_t state, bret;

    localparam logic [1:0] T_CL = 2'd0, T_LIT = 2'd1, T_DIST = 2'd2;
    localparam logic [8:0] TB_LIT = 9'd0, TB_DIST = 9'd288, TB_CL = 9'd320;
    localparam logic [1:0] AFTER_CL = 2'd0, AFTER_DIST = 2'd1, AFTER_LIT = 2'd2;

    // ---- bit reader: LSB first; the input byte is used in place when nothing is held --
    logic [7:0] bbuf;
    logic [3:0] bcnt;
    wire        have_bit = (bcnt != 4'd0) || in_valid;
    wire        cur_bit  = (bcnt != 4'd0) ? bbuf[0] : in_byte[0];

    // ---- n bits into acc (S_BITS), LSB first ------------------------------------------------
    logic [3:0]  nb, bpos;
    logic [15:0] acc;
    logic        xreq;                     // S_LEN_X / S_DIST_X: extra bits already requested

    // ---- block / tables ---------------------------------------------------------------------------
    logic        bfinal;
    logic [8:0]  nlen;                     // HLIT + 257 (fixed: 288)
    logic [5:0]  ndist;                    // HDIST + 1  (fixed: 32)
    logic [4:0]  nclen;                    // HCLEN + 4
    logic [2:0]  cl_len [0:18];
    logic [8:0]  cnt_l [1:15];
    logic [5:0]  cnt_d [1:15];
    logic [4:0]  cnt_c [1:7];
    logic [8:0]  ncod_l;
    logic [5:0]  ncod_d;
    logic [4:0]  ncod_c;
    logic [8:0]  offs [1:15];

    // build engine
    logic [1:0]  bt, after_bt;
    logic [3:0]  kl;
    logic signed [17:0] left;
    logic        over;
    logic [8:0]  osum;
    logic [8:0]  sidx;
    logic        sp_v;
    logic [8:0]  sp_sym;
    logic [2:0]  sp_cl;

    // decoder
    logic [1:0]  dt;
    logic [3:0]  dlen;
    logic [16:0] dcode, dfirst;
    logic [8:0]  dindex;

    // code lengths
    logic [8:0]  li;
    logic [3:0]  lprev, lval;
    logic [7:0]  lrep;
    logic        eob_nz;
    logic [4:0]  cl_pos;

    // symbols, matches, window
    logic [8:0]  sym_r;
    logic [8:0]  mlen;
    logic [4:0]  dsym;
    logic [15:0] mdist;
    logic [14:0] wp, src;
    logic [15:0] outcnt;                   // bytes out, saturating at 32768
    logic [7:0]  last_byte;
    logic [16:0] stlen;
    logic [2:0]  bytei;
    logic [23:0] acc32;                    // the last three header / LEN / Adler bytes
    logic [15:0] s1, s2;

    // ---- memories -----------------------------------------------------------------------------------
    logic [7:0]  win [0:32767];
    logic [14:0] win_ra;
    logic [7:0]  win_q;
    logic [8:0]  symt [0:511];
    logic [8:0]  symt_ra, symt_wa, symt_q;
    logic        symt_we;
    logic [3:0]  lent [0:511];
    logic [8:0]  lent_ra;
    logic [3:0]  lent_q, lent_wd;
    logic        lent_we;
    logic        emit;
    logic [7:0]  emit_b;

    // ---- length / distance bases (RFC 1951 3.2.5) ------------------------------------------------
    logic [8:0]  lbase;
    logic [2:0]  lext;
    always_comb begin
        case (sym_r[4:0])            // sym_r - 257 in S_LEN_X: 0..28
            5'd0:  begin lbase = 9'd3;   lext = 3'd0; end
            5'd1:  begin lbase = 9'd4;   lext = 3'd0; end
            5'd2:  begin lbase = 9'd5;   lext = 3'd0; end
            5'd3:  begin lbase = 9'd6;   lext = 3'd0; end
            5'd4:  begin lbase = 9'd7;   lext = 3'd0; end
            5'd5:  begin lbase = 9'd8;   lext = 3'd0; end
            5'd6:  begin lbase = 9'd9;   lext = 3'd0; end
            5'd7:  begin lbase = 9'd10;  lext = 3'd0; end
            5'd8:  begin lbase = 9'd11;  lext = 3'd1; end
            5'd9:  begin lbase = 9'd13;  lext = 3'd1; end
            5'd10: begin lbase = 9'd15;  lext = 3'd1; end
            5'd11: begin lbase = 9'd17;  lext = 3'd1; end
            5'd12: begin lbase = 9'd19;  lext = 3'd2; end
            5'd13: begin lbase = 9'd23;  lext = 3'd2; end
            5'd14: begin lbase = 9'd27;  lext = 3'd2; end
            5'd15: begin lbase = 9'd31;  lext = 3'd2; end
            5'd16: begin lbase = 9'd35;  lext = 3'd3; end
            5'd17: begin lbase = 9'd43;  lext = 3'd3; end
            5'd18: begin lbase = 9'd51;  lext = 3'd3; end
            5'd19: begin lbase = 9'd59;  lext = 3'd3; end
            5'd20: begin lbase = 9'd67;  lext = 3'd4; end
            5'd21: begin lbase = 9'd83;  lext = 3'd4; end
            5'd22: begin lbase = 9'd99;  lext = 3'd4; end
            5'd23: begin lbase = 9'd115; lext = 3'd4; end
            5'd24: begin lbase = 9'd131; lext = 3'd5; end
            5'd25: begin lbase = 9'd163; lext = 3'd5; end
            5'd26: begin lbase = 9'd195; lext = 3'd5; end
            5'd27: begin lbase = 9'd227; lext = 3'd5; end
            default: begin lbase = 9'd258; lext = 3'd0; end
        endcase
    end
    logic [15:0] dbase;
    logic [3:0]  dext;
    always_comb begin
        case (dsym)
            5'd0:  begin dbase = 16'd1;     dext = 4'd0;  end
            5'd1:  begin dbase = 16'd2;     dext = 4'd0;  end
            5'd2:  begin dbase = 16'd3;     dext = 4'd0;  end
            5'd3:  begin dbase = 16'd4;     dext = 4'd0;  end
            5'd4:  begin dbase = 16'd5;     dext = 4'd1;  end
            5'd5:  begin dbase = 16'd7;     dext = 4'd1;  end
            5'd6:  begin dbase = 16'd9;     dext = 4'd2;  end
            5'd7:  begin dbase = 16'd13;    dext = 4'd2;  end
            5'd8:  begin dbase = 16'd17;    dext = 4'd3;  end
            5'd9:  begin dbase = 16'd25;    dext = 4'd3;  end
            5'd10: begin dbase = 16'd33;    dext = 4'd4;  end
            5'd11: begin dbase = 16'd49;    dext = 4'd4;  end
            5'd12: begin dbase = 16'd65;    dext = 4'd5;  end
            5'd13: begin dbase = 16'd97;    dext = 4'd5;  end
            5'd14: begin dbase = 16'd129;   dext = 4'd6;  end
            5'd15: begin dbase = 16'd193;   dext = 4'd6;  end
            5'd16: begin dbase = 16'd257;   dext = 4'd7;  end
            5'd17: begin dbase = 16'd385;   dext = 4'd7;  end
            5'd18: begin dbase = 16'd513;   dext = 4'd8;  end
            5'd19: begin dbase = 16'd769;   dext = 4'd8;  end
            5'd20: begin dbase = 16'd1025;  dext = 4'd9;  end
            5'd21: begin dbase = 16'd1537;  dext = 4'd9;  end
            5'd22: begin dbase = 16'd2049;  dext = 4'd10; end
            5'd23: begin dbase = 16'd3073;  dext = 4'd10; end
            5'd24: begin dbase = 16'd4097;  dext = 4'd11; end
            5'd25: begin dbase = 16'd6145;  dext = 4'd11; end
            5'd26: begin dbase = 16'd8193;  dext = 4'd12; end
            5'd27: begin dbase = 16'd12289; dext = 4'd12; end
            5'd28: begin dbase = 16'd16385; dext = 4'd13; end
            default: begin dbase = 16'd24577; dext = 4'd13; end
        endcase
    end

    // HCLEN order position -> code-length symbol (16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15)
    logic [4:0] cl_sym_at;
    always_comb begin
        case (cl_pos)
            5'd0:  cl_sym_at = 5'd16; 5'd1:  cl_sym_at = 5'd17; 5'd2:  cl_sym_at = 5'd18;
            5'd3:  cl_sym_at = 5'd0;  5'd4:  cl_sym_at = 5'd8;  5'd5:  cl_sym_at = 5'd7;
            5'd6:  cl_sym_at = 5'd9;  5'd7:  cl_sym_at = 5'd6;  5'd8:  cl_sym_at = 5'd10;
            5'd9:  cl_sym_at = 5'd5;  5'd10: cl_sym_at = 5'd11; 5'd11: cl_sym_at = 5'd4;
            5'd12: cl_sym_at = 5'd12; 5'd13: cl_sym_at = 5'd3;  5'd14: cl_sym_at = 5'd13;
            5'd15: cl_sym_at = 5'd2;  5'd16: cl_sym_at = 5'd14; 5'd17: cl_sym_at = 5'd1;
            default: cl_sym_at = 5'd15;
        endcase
    end

    // ---- table views --------------------------------------------------------------------------------
    logic [8:0] dcnt, kcnt;
    always_comb begin
        case (dt)
            T_LIT:   dcnt = cnt_l[dlen];
            T_DIST:  dcnt = {3'd0, cnt_d[dlen]};
            default: dcnt = (dlen <= 4'd7) ? {4'd0, cnt_c[dlen[2:0]]} : 9'd0;
        endcase
        case (bt)
            T_LIT:   kcnt = cnt_l[kl];
            T_DIST:  kcnt = {3'd0, cnt_d[kl]};
            default: kcnt = (kl <= 4'd7) ? {4'd0, cnt_c[kl[2:0]]} : 9'd0;
        endcase
    end
    wire [8:0] d_ncod  = (dt == T_LIT) ? ncod_l : (dt == T_DIST) ? {3'd0, ncod_d} : {4'd0, ncod_c};
    wire [8:0] d_tbase = (dt == T_LIT) ? TB_LIT : (dt == T_DIST) ? TB_DIST : TB_CL;
    wire [8:0] b_n     = (bt == T_LIT) ? nlen : (bt == T_DIST) ? {3'd0, ndist} : 9'd19;
    wire [8:0] b_tbase = (bt == T_LIT) ? TB_LIT : (bt == T_DIST) ? TB_DIST : TB_CL;

    // decode step (S_DEC, one bit)
    wire [16:0] code_n  = dcode | {16'd0, cur_bit};
    wire [16:0] fc      = dfirst + {8'd0, dcnt};
    wire        found   = code_n < fc;
    wire [8:0]  index_n = dindex + dcnt;
    // not at this length, and no code is longer: the code is incomplete here
    wire        dmiss   = !found && ((index_n == d_ncod) || (dlen == 4'd15));
    wire [4:0]  miss_err = (dt == T_LIT) ? E_LITCODE : (dt == T_DIST) ? E_DISTCODE : E_CLSET;
    wire [4:0]  set_err  = (bt == T_LIT) ? E_LITSET  : (bt == T_DIST) ? E_DISTSET  : E_CLSET;

    // Kraft step (S_KRAFT)
    wire signed [17:0] left_n = (left <<< 1) - $signed({9'd0, kcnt});
    wire [8:0]  ncodes = osum + kcnt;
    // a lone 1-bit code: count[1] == 1 and nothing else (lit/len and distance only)
    wire        single = (bt != T_CL) && (ncodes == 9'd1) &&
                         ((bt == T_LIT) ? (cnt_l[1] == 9'd1) : (cnt_d[1] == 6'd1));
    wire        set_bad = over || (left_n < 0) || ((left_n > 0) && (ncodes != 9'd0) && !single);

    // code lengths: where length index li lands, how many there are, the repeat count
    wire [9:0]  ltotal    = {1'b0, nlen} + {4'd0, ndist};
    wire        l_is_dist = li >= nlen;
    wire [8:0]  l_addr    = l_is_dist ? (TB_DIST + (li - nlen)) : li;
    logic [7:0] rep_n;
    always_comb begin
        if (sym_r == 9'd16)      rep_n = 8'd3 + {6'd0, acc[1:0]};
        else if (sym_r == 9'd17) rep_n = 8'd3 + {5'd0, acc[2:0]};
        else                     rep_n = 8'd11 + {1'b0, acc[6:0]};
    end
    wire        rep_over = ({1'b0, li} + {2'd0, rep_n}) > ltotal;
    wire        l_last   = ({1'b0, li} + 10'd1) == ltotal;
    wire        eob_ok   = (li == 9'd256) ? (lval != 4'd0) : eob_nz;

    // fixed-code lengths by index (li: lit/len 0..287, then distance 288..319)
    logic [3:0] fix_len;
    always_comb begin
        if (li >= 9'd288)     fix_len = 4'd5;
        else if (li < 9'd144) fix_len = 4'd8;
        else if (li < 9'd256) fix_len = 4'd9;
        else if (li < 9'd280) fix_len = 4'd7;
        else                  fix_len = 4'd8;
    end

    // zlib header, stored LEN / NLEN, the distance
    wire [15:0] zh      = {acc32[7:0], in_byte};
    // mod 31 by folding base-32 digits (32 = 1 mod 31)
    wire [6:0]  zf1     = {2'd0, zh[4:0]} + {2'd0, zh[9:5]} + {2'd0, zh[14:10]} + {6'd0, zh[15]};
    wire [5:0]  zf2     = {1'b0, zf1[4:0]} + {4'd0, zf1[6:5]};
    wire        zcheck_ok = (zf2 == 6'd0) || (zf2 == 6'd31);
    // LEN lo, LEN hi, NLEN lo, NLEN hi: after three bytes acc32[23:0] = {LENlo, LENhi, NLENlo}
    wire [15:0] st_len  = {acc32[15:8], acc32[23:16]};
    wire [15:0] st_nlen = {in_byte, acc32[7:0]};
    wire [15:0] dist_n  = dbase + acc;

    // ---- output / window ------------------------------------------------------------------------------
    wire emit_ok = !out_valid || out_ready;

    // mod-65521 adler step
    wire [16:0] s1_a = {1'b0, s1} + {9'd0, emit_b};
    wire [15:0] s1_n = (s1_a >= 17'd65521) ? (s1_a[15:0] - 16'd65521) : s1_a[15:0];
    wire [16:0] s2_a = {1'b0, s2} + {1'b0, s1_n};
    wire [15:0] s2_n = (s2_a >= 17'd65521) ? (s2_a[15:0] - 16'd65521) : s2_a[15:0];

    // ---- what this state consumes ----------------------------------------------------------------------
    logic need_bit, need_byte;
    always_comb begin
        need_bit  = ((state == S_BITS) && (bpos != nb)) ||
                    ((state == S_DEC) && (d_ncod != 9'd0));
        need_byte = (state == S_ZH) || (state == S_ST_LEN) || (state == S_ADLER) ||
                    ((state == S_ST_COPY) && (stlen != 17'd0) && emit_ok);
        in_ready  = (need_bit && (bcnt == 4'd0)) || need_byte;
    end
    wire take_bit  = need_bit && have_bit;
    wire take_byte = need_byte && in_valid;
    wire starved   = in_end && !in_valid && ((need_bit && (bcnt == 4'd0)) || need_byte);

    // emission (literal, copy, stored)
    always_comb begin
        emit   = 1'b0;
        emit_b = 8'd0;
        case (state)
            S_LIT:     if (sym_r < 9'd256 && emit_ok) begin emit = 1'b1; emit_b = sym_r[7:0]; end
            S_COPY:    if (emit_ok) begin
                           emit   = 1'b1;
                           // distance 1 reads the byte being written: forward it
                           emit_b = (mdist == 16'd1) ? last_byte : win_q;
                       end
            S_ST_COPY: if (take_byte) begin emit = 1'b1; emit_b = in_byte; end
            default: ;
        endcase
    end

    // memory ports
    always_comb begin
        // the copy source advances with each emitted byte
        win_ra  = ((state == S_COPY) && emit) ? (src + 15'd1) : src;
        symt_ra = d_tbase + dindex + (code_n[8:0] - dfirst[8:0]);
        lent_ra = b_tbase + sidx;           // lit/len lengths at 0, distance at 288
        lent_we = (state == S_FIX_FILL) || ((state == S_CL_WRITE) && (lrep != 8'd0));
        lent_wd = (state == S_FIX_FILL) ? fix_len : lval;
        symt_we = 1'b0;
        symt_wa = 9'd0;
        if (state == S_SORT && sp_v) begin
            if (bt == T_CL) begin
                symt_we = (sp_cl != 3'd0);
                symt_wa = b_tbase + offs[{1'b0, sp_cl}];
            end else begin
                symt_we = (lent_q != 4'd0);
                symt_wa = b_tbase + offs[lent_q];
            end
        end
    end
    wire [2:0] cl_at_sidx = (sidx < 9'd19) ? cl_len[sidx[4:0]] : 3'd0;

    always_ff @(posedge clk) begin
        if (emit) win[wp] <= emit_b;
        win_q <= win[win_ra];
        if (symt_we) symt[symt_wa] <= sp_sym;
        symt_q <= symt[symt_ra];
        if (lent_we) lent[l_addr] <= lent_wd;
        lent_q <= lent[lent_ra];
    end

`define FAIL(c)       begin err <= (c); state <= S_DONE; end
`define GET(n, ret)   begin nb <= (n); bpos <= 4'd0; acc <= 16'd0; bret <= (ret); state <= S_BITS; end
`define DEC(t)        begin dt <= (t); dlen <= 4'd1; dcode <= 17'd0; dfirst <= 17'd0; dindex <= 9'd0; state <= S_DEC; end
`define BUILD(t, aft) begin bt <= (t); after_bt <= (aft); kl <= 4'd1; left <= 18'sd1; over <= 1'b0; osum <= 9'd0; state <= S_KRAFT; end
`define TO_ADLER      begin bytei <= 3'd0; bcnt <= 4'd0; state <= S_ADLER; end

    integer i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            done      <= 1'b0;
            err       <= E_OK;
            out_valid <= 1'b0;
            bcnt      <= 4'd0;
        end else begin
            // ---- bit reader ----
            if (take_bit) begin
                if (bcnt != 4'd0) begin
                    bbuf <= {1'b0, bbuf[7:1]};
                    bcnt <= bcnt - 4'd1;
                end else begin
                    bbuf <= {1'b0, in_byte[7:1]};
                    bcnt <= 4'd7;
                end
            end
            // ---- output register, window pointer, adler ----
            if (out_valid && out_ready) out_valid <= 1'b0;
            if (emit) begin
                out_valid <= 1'b1;
                out_byte  <= emit_b;
                wp        <= wp + 15'd1;
                last_byte <= emit_b;
                s1        <= s1_n;
                s2        <= s2_n;
                if (!outcnt[15]) outcnt <= outcnt + 16'd1;
            end

            if (starved && state != S_DONE && state != S_IDLE)
                `FAIL(E_ZSHORT)
            else
            case (state)
                S_IDLE: ;
                S_DONE: done <= 1'b1;

                // ---- zlib header: CMF, FLG (zlib's order of checks) ----
                S_ZH: if (take_byte) begin
                    acc32 <= {acc32[15:0], in_byte};
                    bytei <= bytei + 3'd1;
                    if (bytei == 3'd1) begin
                        if (!zcheck_ok)             `FAIL(E_ZCHECK)
                        else if (zh[11:8] != 4'd8)  `FAIL(E_ZMETHOD)
                        else if (zh[15:12] > 4'd7)  `FAIL(E_ZWINDOW)
                        else if (zh[5])             `FAIL(E_ZDICT)
                        else                        `GET(4'd3, S_BHDR)
                    end
                end

                S_BITS: if (bpos == nb) state <= bret;
                        else if (take_bit) begin
                            acc[bpos] <= cur_bit;
                            bpos      <= bpos + 4'd1;
                        end

                // ---- block header ----
                S_BHDR: begin
                    bfinal <= acc[0];
                    for (i = 1; i <= 15; i = i + 1) begin
                        cnt_l[i] <= 9'd0;
                        cnt_d[i] <= 6'd0;
                    end
                    for (i = 1; i <= 7; i = i + 1) cnt_c[i] <= 5'd0;
                    case (acc[2:1])
                        2'd0: begin                     // stored: drop to the byte boundary
                            bcnt  <= 4'd0;
                            bytei <= 3'd0;
                            state <= S_ST_LEN;
                        end
                        2'd1: begin
                            nlen  <= 9'd288;
                            ndist <= 6'd32;
                            li    <= 9'd0;
                            state <= S_FIX_FILL;
                        end
                        2'd2: `GET(4'd14, S_DYN_HDR)
                        default: `FAIL(E_BTYPE)
                    endcase
                end

                // ---- stored ----
                S_ST_LEN: if (take_byte) begin
                    acc32 <= {acc32[15:0], in_byte};
                    bytei <= bytei + 3'd1;
                    if (bytei == 3'd3) begin
                        if (st_len != ~st_nlen) `FAIL(E_STORED)
                        else begin
                            stlen <= {1'b0, st_len};
                            state <= S_ST_COPY;
                        end
                    end
                end
                S_ST_COPY: if (stlen == 17'd0) begin
                    if (bfinal) `TO_ADLER
                    else        `GET(4'd3, S_BHDR)
                end else if (take_byte) stlen <= stlen - 17'd1;

                // ---- fixed: the lengths written as a dynamic block's would be ----
                S_FIX_FILL: begin
                    if (li < 9'd288) cnt_l[fix_len] <= cnt_l[fix_len] + 9'd1;
                    else             cnt_d[fix_len] <= cnt_d[fix_len] + 6'd1;
                    li <= li + 9'd1;
                    if (li == 9'd319) `BUILD(T_LIT, AFTER_DIST)
                end

                // ---- dynamic header ----
                S_DYN_HDR: begin
                    nlen  <= {4'd0, acc[4:0]} + 9'd257;
                    ndist <= {1'b0, acc[9:5]} + 6'd1;
                    nclen <= {1'b0, acc[13:10]} + 5'd4;
                    if (acc[4:0] > 5'd29 || acc[9:5] > 5'd29) `FAIL(E_NSYMS)
                    else begin
                        for (i = 0; i < 19; i = i + 1) cl_len[i] <= 3'd0;
                        cl_pos <= 5'd0;
                        `GET(4'd3, S_CL_READ)
                    end
                end
                S_CL_READ: begin
                    cl_len[cl_sym_at] <= acc[2:0];
                    if (acc[2:0] != 3'd0) cnt_c[acc[2:0]] <= cnt_c[acc[2:0]] + 5'd1;
                    cl_pos <= cl_pos + 5'd1;
                    if (cl_pos + 5'd1 == nclen) `BUILD(T_CL, AFTER_CL)
                    else                        `GET(4'd3, S_CL_READ)
                end

                // ---- table build: Kraft (offsets, over / incomplete) ----
                S_KRAFT: begin
                    offs[kl] <= osum;
                    osum     <= ncodes;
                    left     <= left_n;
                    if (left_n < 0) over <= 1'b1;
                    kl <= kl + 4'd1;
                    if (kl == 4'd15) begin
                        if (set_bad) `FAIL(set_err)
                        else begin
                            case (bt)
                                T_LIT:   ncod_l <= ncodes;
                                T_DIST:  ncod_d <= ncodes[5:0];
                                default: ncod_c <= ncodes[4:0];
                            endcase
                            sidx  <= 9'd0;
                            sp_v  <= 1'b0;
                            state <= S_SORT;
                        end
                    end
                end
                // ---- table build: counting sort, one symbol a cycle ----
                S_SORT: begin
                    if (sp_v) begin                 // the length presented last cycle
                        if (bt == T_CL) begin
                            if (sp_cl != 3'd0) offs[{1'b0, sp_cl}] <= offs[{1'b0, sp_cl}] + 9'd1;
                        end else if (lent_q != 4'd0) offs[lent_q] <= offs[lent_q] + 9'd1;
                    end
                    sp_v   <= (sidx < b_n);
                    sp_sym <= sidx;
                    sp_cl  <= cl_at_sidx;
                    sidx   <= sidx + 9'd1;
                    if (sidx == b_n + 9'd1) begin
                        case (after_bt)
                            AFTER_CL: begin
                                li     <= 9'd0;
                                eob_nz <= 1'b0;
                                lprev  <= 4'd0;
                                `DEC(T_CL)
                            end
                            AFTER_DIST: `BUILD(T_DIST, AFTER_LIT)
                            default:    `DEC(T_LIT)
                        endcase
                    end
                end

                // ---- decode one symbol, one code bit a cycle ----
                S_DEC: if (d_ncod == 9'd0) `FAIL(miss_err)     // an empty code: nothing decodes
                       else if (take_bit) begin
                    if (found)      state <= S_SYM;             // symt_ra is presented now
                    else if (dmiss) `FAIL(miss_err)
                    else begin
                        dindex <= index_n;
                        dfirst <= fc << 1;
                        dcode  <= code_n << 1;
                        dlen   <= dlen + 4'd1;
                    end
                end
                S_SYM: begin
                    sym_r <= symt_q;
                    xreq  <= 1'b0;
                    case (dt)
                        T_CL:    state <= S_CL_SYM;
                        T_LIT:   state <= S_LIT;
                        default: state <= S_DIST;
                    endcase
                end

                // ---- code lengths ----
                S_CL_SYM: begin
                    lrep <= 8'd0;
                    if (sym_r < 9'd16) begin
                        lval  <= sym_r[3:0];
                        lrep  <= 8'd1;
                        state <= S_CL_WRITE;
                    end else if (sym_r == 9'd16) begin
                        if (li == 9'd0) `FAIL(E_REPEAT)
                        else begin lval <= lprev; `GET(4'd2, S_CL_REP) end
                    end else if (sym_r == 9'd17) begin
                        lval <= 4'd0; `GET(4'd3, S_CL_REP)
                    end else begin
                        lval <= 4'd0; `GET(4'd7, S_CL_REP)
                    end
                end
                S_CL_REP: begin
                    if (rep_over) `FAIL(E_REPEAT)
                    else begin
                        lrep  <= rep_n;
                        state <= S_CL_WRITE;
                    end
                end
                S_CL_WRITE: begin                   // one length a cycle (the port is above)
                    if (lval != 4'd0) begin
                        if (l_is_dist) cnt_d[lval] <= cnt_d[lval] + 6'd1;
                        else           cnt_l[lval] <= cnt_l[lval] + 9'd1;
                    end
                    if (li == 9'd256) eob_nz <= (lval != 4'd0);
                    lprev <= lval;
                    li    <= li + 9'd1;
                    lrep  <= lrep - 8'd1;
                    if (l_last) begin
                        if (!eob_ok) `FAIL(E_NOEOB)
                        else         `BUILD(T_LIT, AFTER_DIST)
                    end else if (lrep == 8'd1) `DEC(T_CL)
                end

                // ---- literal / length ----
                S_LIT: begin
                    if (sym_r < 9'd256) begin
                        if (emit_ok) `DEC(T_LIT)
                    end else if (sym_r == 9'd256) begin
                        if (bfinal) `TO_ADLER
                        else        `GET(4'd3, S_BHDR)
                    end else if (sym_r > 9'd285) `FAIL(E_LITCODE)
                    else begin
                        sym_r <= sym_r - 9'd257;
                        state <= S_LEN_X;
                    end
                end
                S_LEN_X: begin                      // sym_r: the length code 0..28
                    if (!xreq) begin
                        xreq <= 1'b1;
                        `GET({1'b0, lext}, S_LEN_X)
                    end else begin
                        mlen <= lbase + acc[8:0];
                        `DEC(T_DIST)
                    end
                end
                S_DIST: begin
                    if (sym_r > 9'd29) `FAIL(E_DISTCODE)
                    else begin
                        dsym  <= sym_r[4:0];
                        state <= S_DIST_X;
                    end
                end
                S_DIST_X: begin
                    if (!xreq) begin
                        xreq <= 1'b1;
                        `GET(dext, S_DIST_X)
                    end else if (!outcnt[15] && (dist_n > outcnt)) `FAIL(E_FAR)
                    else begin
                        mdist <= dist_n;
                        src   <= wp - dist_n[14:0];
                        state <= S_COPY_PRE;
                    end
                end
                S_COPY_PRE: state <= S_COPY;         // win_q <- win[src]
                S_COPY: if (emit) begin
                    src  <= src + 15'd1;
                    mlen <= mlen - 9'd1;
                    if (mlen == 9'd1) `DEC(T_LIT)
                end

                // ---- adler-32, big-endian ----
                S_ADLER: if (take_byte) begin
                    acc32 <= {acc32[15:0], in_byte};
                    bytei <= bytei + 3'd1;
                    if (bytei == 3'd3) begin
                        if ({acc32[23:0], in_byte} != {s2, s1}) `FAIL(E_ADLER)
                        else state <= S_DONE;
                    end
                end
                default: ;
            endcase

            if (start) begin
                state     <= S_ZH;
                done      <= 1'b0;
                err       <= E_OK;
                bcnt      <= 4'd0;
                bytei     <= 3'd0;
                wp        <= 15'd0;
                outcnt    <= 16'd0;
                s1        <= 16'd1;
                s2        <= 16'd0;
                out_valid <= 1'b0;
            end
        end
    end

`undef FAIL
`undef GET
`undef DEC
`undef BUILD
`undef TO_ADLER

endmodule

`default_nettype wire
