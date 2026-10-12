// umd/plane_reader.sv -- one overlay plane on the 720x480 raster: premultiplied ARGB8888
// from DDR3 (ram2), a source rectangle scaled bilinearly onto a destination rectangle
// (docs/compositor.md; the menus' fabric contract, docs/menus.md §4 items 1-2; the
// subtitle plane, docs/subtitles.md §2, is the 1:1 case)
//
// The plane: a buffer of 720-pixel pitch (360 words a row), {A, R, G, B} with A in
// [31:24], two pixels a 64-bit word, the even x in [31:0] (main/support/umd/umd_sub.cpp writes it since A7).
// The geometry (clk_sys, quasi-static: changed only in the vertical blank, raster lines
// 480..523, when no line is requested):
//   vis; base (the word address of the buffer's pixel (0, 0));
//   the source rectangle sx, sy, sw, sh in the buffer; the destination dx, dy, dw, dh on
//   the raster; hstep / vstep (U10.16: source pixels a destination pixel) and hstart /
//   vstart (S11.16: the source position of the rectangle's first dot / line, relative to
//   (sx, sy)). The owner computes them (docs/compositor.md §2); 1:1 is step 1.0, start 0.
// A bad geometry (sw or sh 0, or the source rectangle past the 720x480 buffer: a fetch
// would read the next row) is refused: nothing is shown and geo_bad is raised.
//
// The algorithm (docs/compositor.md §2, the golden is tools/plane_golden.py):
//   line n of the rectangle (k = n - dy): Y = vstart + k * vstep (accumulated);
//   dot h (j = h - dx):                   X = hstart + j * hstep (accumulated);
//   each clamped: negative -> 0 with weight 0; integer part >= size - 1 -> size - 1 with
//   weight 0; else the integer part with the weight = the fraction's top 8 bits.
//   p00 = P(c, r), p01 = P(c+1, r), p10 = P(c, r+1), p11 = P(c+1, r+1) in the source
//   rectangle; a neighbour of weight 0 is taken as its partner (never read: a row that
//   was not fetched, a column past the rectangle);
//   top = 256 p00 + (p01 - p00) fx, bot = 256 p10 + (p11 - p10) fx (exact),
//   out = (256 top + (bot - top) fy + 32768) >> 16 per channel.
// At 1:1 every weight is 0 and out = p00 exactly (the pass-through, a bench arm).
// Outside the destination rectangle, or not vis: transparent (0, 0, 0, 0).
//
// clk_sys: one dot a clock (sync_gen's raster, clk_en = 1). At the first dot of every
// line the NEXT line is requested as disp_reader does (line 0 at line 524): its source
// row, whether the row below is needed (fy != 0), whether the line is inside the
// rectangle; a toggle crosses to clk_mem. LAT 5 from (h_pos, v_pos, de_in) to (a, r, g, b).
// clk_mem: the source span's words (sx >> 1 .. (sx + sw - 1) >> 1) of the row, then of
// the row below if needed, in bursts of up to 8, into four line buffers: {top row, bottom
// row} x {even pixels, odd pixels}, each 2 halves (the line's parity) x 512 x 32 bits, so
// the four neighbours of a dot are read in one clock (E at (col + 1) >> 1, O at col >> 1).
// A request that arrives while the previous line is still being fetched is lost (the line
// shows the buffer half's old contents): n_late counts it.
//
// SCALE (docs/area_plan.md A3): 1 (the default) is the bilinear reader above, the menus'
// plane (P9). 0 is the 1:1 reader the subtitle plane needs (a subtitle image is placed on
// the 720x480 raster as it is: the format's rule, umd_video_format.md "Subtitles"): the
// source position of dot h is h - dx, of line n is n - dy, with no fraction, so both weights
// are 0 and the output is p00 -- bit-identical to SCALE 1 driven at step 1.0, start 0.
// Synthesis then drops the accumulators, the four channels' multipliers (12 DSP) and the
// bottom row's two line buffers (never fetched, never read). hstep / vstep / hstart /
// vstart are ignored; dw / dh still bound the destination (the owner passes sw / sh).
//
// 480i (`il`, docs/analog.md S2): h_pos counts dots (a pixel is two: the column is h_pos >> 1)
// and v_pos is the frame line; plane line n is shown on raster frame line n (raw raster
// coordinates: V11). A field's next line is n + 2, its buffer half alternates with n[1], and
// the field's first line is requested in the previous field's last blank line (523: line 0,
// 524: line 1). ⚠ SCALE 1 is NOT 480i-ready: its accumulators step once a requested line and
// once a clock (both assume the 480p raster); P9's menu plane must step them by the field.

`default_nettype none

module plane_reader #(
    parameter bit SCALE = 1'b1          // 0: the 1:1 reader (the subtitle plane)
) (
    // the raster (clk_sys)
    input  wire         clk,
    input  wire         rst_n,
    input  wire  [11:0] h_pos,
    input  wire  [11:0] v_pos,
    input  wire         il,                 // the 480i raster
    input  wire         de_in,
    // the geometry (clk_sys, changed only in the vertical blank)
    input  wire         vis,
    input  wire  [28:0] base,
    input  wire  [9:0]  sx,
    input  wire  [8:0]  sy,
    input  wire  [9:0]  sw,
    input  wire  [8:0]  sh,
    input  wire  [9:0]  dx,
    input  wire  [8:0]  dy,
    input  wire  [9:0]  dw,
    input  wire  [8:0]  dh,
    input  wire  [25:0] hstep,
    input  wire  [25:0] vstep,
    input  wire  [27:0] hstart,
    input  wire  [27:0] vstart,
    output logic        geo_bad,
    // the dot, premultiplied (LAT 5)
    output logic [7:0]  a,
    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b,

    // DDR3 reads (clk_mem): a read-only master (rd_merge2's Q)
    input  wire         mclk,
    input  wire         mrst_n,
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,
    output logic [15:0] n_late
);

    // ---- the line buffers (written on clk_mem, read on clk_sys) ----------------------------
    logic [31:0] te [0:1023];              // top row, even pixels
    logic [31:0] to [0:1023];              // top row, odd pixels
    logic [31:0] be [0:1023];              // bottom row, even
    logic [31:0] bo [0:1023];              // bottom row, odd
    logic        lb_we_t, lb_we_b;
    logic [9:0]  lb_waddr;
    logic [63:0] lb_wdata;
    always_ff @(posedge mclk) begin
        if (lb_we_t) te[lb_waddr] <= lb_wdata[31:0];
    end
    always_ff @(posedge mclk) begin
        if (lb_we_t) to[lb_waddr] <= lb_wdata[63:32];
    end
    always_ff @(posedge mclk) begin
        if (lb_we_b) be[lb_waddr] <= lb_wdata[31:0];
    end
    always_ff @(posedge mclk) begin
        if (lb_we_b) bo[lb_waddr] <= lb_wdata[63:32];
    end

    // ---- clk_sys: the geometry's check -------------------------------------------------------
    wire [10:0] sxe = {1'b0, sx} + {1'b0, sw};
    wire [9:0]  sye = {1'b0, sy} + {1'b0, sh};
    assign geo_bad = vis && ((sw == 10'd0) || (sh == 9'd0) || (sxe > 11'd720) || (sye > 10'd480));
    wire        show = vis && !geo_bad;

    // ---- clk_sys: the line requests ----------------------------------------------------------
    // h_pos 0: the next line n and its Y; 1: clamped to the row, weight, bottom-row need;
    // 2: the request toggles, the line's half gets its weight and inside flag.
    logic        req_tog;
    logic [8:0]  rq_n;                     // the line requested
    logic        rq_go1, rq_go2;
    /* verilator lint_off UNUSEDSIGNAL */      // the fraction's low byte is below the weight
    logic signed [27:0] yacc, y1;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [8:0]  req_row;                  // the source row (absolute in the buffer)
    logic        req_need_b, req_in, req_half;
    logic [7:0]  fy_h [0:1];               // per buffer half: the line's vertical weight
    logic        in_h [0:1];               //   and whether it is inside the rectangle
    wire  [9:0]  n_ext = {1'b0, rq_n};
    wire         rq_inside = show && (n_ext >= {1'b0, dy}) && (n_ext < {1'b0, dy} + {1'b0, dh});
    // Y clamped: the row in the source rectangle and the weight
    wire  [11:0] y_int = y1[27:16];
    wire         y_lo = y1[27];
    wire         y_hi = !y_lo && ({1'b0, y_int} >= {4'd0, sh} - 13'd1);
    wire  [8:0]  rq_r = y_lo ? 9'd0 : y_hi ? sh - 9'd1 : y_int[8:0];
    wire  [7:0]  rq_fy = (!SCALE || y_lo || y_hi) ? 8'd0 : y1[15:8];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_tog <= 1'b0; rq_n <= '0; rq_go1 <= 1'b0; rq_go2 <= 1'b0; yacc <= '0; y1 <= '0;
            req_row <= '0; req_need_b <= 1'b0; req_in <= 1'b0; req_half <= 1'b0;
            fy_h[0] <= '0; fy_h[1] <= '0; in_h[0] <= 1'b0; in_h[1] <= 1'b0;
        end else begin
            rq_go1 <= 1'b0; rq_go2 <= 1'b0;
            // h_pos 0: which line (v 524 is the last blank line: line 0; 480i: 523 -> line 0,
            // 524 -> line 1, a field's next line two below)
            if (h_pos == 12'd0 && !il && (v_pos == 12'd524 || v_pos < 12'd479)) begin
                rq_n <= (v_pos == 12'd524) ? 9'd0 : v_pos[8:0] + 9'd1;
                rq_go1 <= 1'b1;
            end
            if (h_pos == 12'd0 && il && (v_pos == 12'd523 || v_pos == 12'd524 || v_pos < 12'd478)) begin
                rq_n <= (v_pos == 12'd523) ? 9'd0 : (v_pos == 12'd524) ? 9'd1 : v_pos[8:0] + 9'd2;
                rq_go1 <= 1'b1;
            end
            // h_pos 1: Y (the rectangle's first line starts it), then clamped
            if (rq_go1) begin
                if (rq_inside) begin
                    if (SCALE) begin
                        y1 <= (rq_n == dy) ? vstart : yacc;
                        yacc <= ((rq_n == dy) ? vstart : yacc) + {2'b00, vstep};
                    end else
                        y1 <= {3'd0, rq_n - dy, 16'd0};     // 1:1: the row, no fraction
                end
                rq_go2 <= 1'b1;
            end
            // h_pos 2: the row, the weight, the request
            if (rq_go2) begin
                req_row <= sy + rq_r;
                req_need_b <= (rq_fy != 8'd0);
                req_in <= rq_inside;
                req_half <= il ? rq_n[1] : rq_n[0];
                fy_h[il ? rq_n[1] : rq_n[0]] <= rq_fy;
                in_h[il ? rq_n[1] : rq_n[0]] <= rq_inside;
                req_tog <= !req_tog;
            end
        end
    end

    // ---- clk_sys: the dots ---------------------------------------------------------------------
    // d0 (h_pos): X; s1: X registered, inside; s2: clamped to the column and weight;
    // s3: the four line-buffer words; s4: the horizontal interpolation; s5: the vertical.
    wire         lsel = il ? v_pos[1] : v_pos[0];
    wire  [11:0] hp   = il ? {1'b0, h_pos[11:1]} : h_pos;    // the column
    wire         at_dx = ({2'd0, dx} == hp);
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [27:0] xacc, x1;
    /* verilator lint_on UNUSEDSIGNAL */
    wire  [11:0] h_rel = hp - {2'd0, dx};             // 1:1: the column (in_x bounds it)
    wire  signed [27:0] x_cur = !SCALE ? {h_rel, 16'd0} : at_dx ? hstart : xacc;
    wire  [11:0] dxe = {2'd0, dx} + {2'd0, dw};
    wire         in_x = (hp >= {2'd0, dx}) && (hp < dxe);
    logic        s1_in, s2_in, s3_in, s4_in;
    logic        s1_half, s2_half;
    logic [9:0]  s2_col;
    logic [7:0]  s2_fx, s3_fx, s3_fy;
    logic        s3_odd;
    logic [7:0]  s4_fy;
    logic [31:0] q_te, q_to, q_be, q_bo;
    wire  [11:0] x_int = x1[27:16];
    always_ff @(posedge clk) begin
        xacc <= x_cur + {2'b00, hstep};
    end
    // s3: the line buffers
    /* verilator lint_off UNUSEDSIGNAL */      // a word index: bit 0 is the parity
    wire  [9:0]  col_e = s2_col + 10'd1;
    /* verilator lint_on UNUSEDSIGNAL */
    always_ff @(posedge clk) begin
        q_te <= te[{s2_half, col_e[9:1]}];
        q_to <= to[{s2_half, s2_col[9:1]}];
        q_be <= be[{s2_half, col_e[9:1]}];
        q_bo <= bo[{s2_half, s2_col[9:1]}];
    end
    // s4: the neighbours (a weight-0 neighbour is its partner) and the rows' interpolation
    wire  [31:0] p00 = s3_odd ? q_to : q_te;
    wire  [31:0] p01r = s3_odd ? q_te : q_to;
    wire  [31:0] p01 = (s3_fx == 8'd0) ? p00 : p01r;
    wire  [31:0] p10r = s3_odd ? q_bo : q_be;
    wire  [31:0] p11r = s3_odd ? q_be : q_bo;
    wire  [31:0] p10 = (s3_fy == 8'd0) ? p00 : p10r;
    wire  [31:0] p11 = (s3_fy == 8'd0) ? p01 : ((s3_fx == 8'd0) ? p10r : p11r);
    logic [15:0] top [0:3];
    logic [15:0] bot [0:3];
    logic signed [9:0]  dt [0:3];
    logic signed [9:0]  db [0:3];
    logic signed [17:0] ptt [0:3];
    logic signed [17:0] pbb [0:3];
    // s5: out = (256 top + (bot - top) fy + 32768) >> 16
    logic signed [17:0] dv [0:3];
    logic signed [26:0] pv [0:3];
    logic [24:0] vv [0:3];

    always_comb begin
        for (int c = 0; c < 4; c++) begin
            // channel c: bits [8c +: 8] (0 B, 1 G, 2 R, 3 A); the index is a constant here
            dt[c] = $signed({2'b00, p01[8*c +: 8]}) - $signed({2'b00, p00[8*c +: 8]});
            db[c] = $signed({2'b00, p11[8*c +: 8]}) - $signed({2'b00, p10[8*c +: 8]});
            // SCALE 0: no multiplier at all (a parameter select folds at elaboration; the
            // stuck-at-0 weights alone left the 12 DSPs in place: unit fit, 2026-09-30)
            ptt[c] = SCALE ? dt[c] * $signed({1'b0, s3_fx}) : 18'sd0;
            pbb[c] = SCALE ? db[c] * $signed({1'b0, s3_fx}) : 18'sd0;
            dv[c] = $signed({2'b00, bot[c]}) - $signed({2'b00, top[c]});
            pv[c] = SCALE ? dv[c] * $signed({1'b0, s4_fy}) : 27'sd0;
            vv[c] = {1'b0, top[c], 8'd0} + pv[c][24:0] + 25'd32768;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1 <= '0; s1_in <= 1'b0; s2_in <= 1'b0; s3_in <= 1'b0; s4_in <= 1'b0;
            s1_half <= 1'b0; s2_half <= 1'b0; s2_col <= '0; s2_fx <= '0; s3_fx <= '0; s3_fy <= '0;
            s3_odd <= 1'b0; s4_fy <= '0;
            for (int c = 0; c < 4; c++) begin top[c] <= '0; bot[c] <= '0; end
            a <= '0; r <= '0; g <= '0; b <= '0;
        end else begin
            // s1
            x1 <= x_cur;
            s1_in <= de_in && in_x && in_h[lsel];
            s1_half <= lsel;
            // s2: clamp X to the source rectangle's column
            if (x1[27]) begin s2_col <= sx; s2_fx <= 8'd0; end
            else if ({1'b0, x_int} >= {3'd0, sw} - 13'd1) begin s2_col <= sx + sw - 10'd1; s2_fx <= 8'd0; end
            else begin s2_col <= sx + x_int[9:0]; s2_fx <= SCALE ? x1[15:8] : 8'd0; end
            s2_in <= s1_in; s2_half <= s1_half;
            // s3 (the reads above)
            s3_in <= s2_in; s3_fx <= s2_fx; s3_fy <= fy_h[s2_half]; s3_odd <= s2_col[0];
            // s4
            for (int c = 0; c < 4; c++) begin
                top[c] <= {p00[8*c +: 8], 8'd0} + ptt[c][15:0];
                bot[c] <= {p10[8*c +: 8], 8'd0} + pbb[c][15:0];
            end
            s4_in <= s3_in; s4_fy <= s3_fy;
            // s5
            b <= s4_in ? vv[0][23:16] : 8'd0;
            g <= s4_in ? vv[1][23:16] : 8'd0;
            r <= s4_in ? vv[2][23:16] : 8'd0;
            a <= s4_in ? vv[3][23:16] : 8'd0;
        end
    end

    // ---- clk_mem: fetch the requested line ---------------------------------------------------
    // The request's fields and the geometry cross as quasi-static values, captured when the
    // toggle has crossed (set two or more mclk cycles before it is seen; the geometry changes
    // only in the vertical blank). The row's address, row * 360 + sx >> 1, is built in two
    // setup cycles.
    typedef enum logic [2:0] {F_IDLE, F_SETUP1, F_SETUP2, F_CMD, F_WAIT} fstate_t;
    fstate_t fs;
    logic [2:0]  m_tog;
    logic [8:0]  m_row;
    logic        m_need_b, m_in, m_half;
    logic [28:0] m_base;
    logic [9:0]  m_sx, m_sw;
    logic        bottom;                   // fetching the row below
    logic [8:0]  w0;                       // the span's first word in the row
    logic [8:0]  f_words, f_word, f_got;
    logic [17:0] row360;
    logic [28:0] row_base;
    /* verilator lint_off UNUSEDSIGNAL */      // <= 719 for a valid geometry; a word index
    wire  [10:0] last_px = {1'b0, m_sx} + {1'b0, m_sw} - 11'd1;
    /* verilator lint_on UNUSEDSIGNAL */
    wire  [8:0]  left = f_words - f_word;
    wire         m_new = (m_tog[2] != m_tog[1]);
    wire  [8:0]  wr_k = w0 + f_got;

    always_ff @(posedge mclk or negedge mrst_n) begin
        if (!mrst_n) begin
            fs <= F_IDLE; m_tog <= '0; m_row <= '0; m_need_b <= 1'b0; m_in <= 1'b0; m_half <= 1'b0;
            m_base <= '0; m_sx <= '0; m_sw <= '0; bottom <= 1'b0; w0 <= '0;
            f_words <= '0; f_word <= '0; f_got <= '0; row360 <= '0; row_base <= '0;
            ddr_address <= '0; ddr_burstcount <= 8'd1; ddr_read <= 1'b0;
            lb_we_t <= 1'b0; lb_we_b <= 1'b0; lb_waddr <= '0; lb_wdata <= '0; n_late <= '0;
        end else begin
            m_tog <= {m_tog[1:0], req_tog};
            lb_we_t <= 1'b0; lb_we_b <= 1'b0;
            if (ddr_readdatavalid) begin
                lb_wdata <= ddr_readdata;
                lb_waddr <= {m_half, wr_k};
                lb_we_t <= !bottom; lb_we_b <= bottom;
                f_got <= f_got + 9'd1;
            end
            if (m_new && fs != F_IDLE && n_late != 16'hFFFF) n_late <= n_late + 16'd1;
            case (fs)
                F_IDLE: if (m_new) begin
                    m_row <= req_row; m_need_b <= req_need_b; m_in <= req_in; m_half <= req_half;
                    m_base <= base; m_sx <= sx; m_sw <= sw;
                    fs <= F_SETUP1;
                end
                F_SETUP1: begin
                    if (m_in) begin
                        row360 <= {1'b0, m_row, 8'd0} + {3'd0, m_row, 6'd0} + {4'd0, m_row, 5'd0} + {6'd0, m_row, 3'd0};
                        w0 <= m_sx[9:1];
                        f_words <= last_px[9:1] - m_sx[9:1] + 9'd1;
                        bottom <= 1'b0;
                        fs <= F_SETUP2;
                    end else fs <= F_IDLE;
                end
                F_SETUP2: begin
                    row_base <= m_base + {11'd0, row360} + {20'd0, w0};
                    f_word <= '0; f_got <= '0;
                    fs <= F_CMD;
                end
                F_CMD: begin
                    if (!ddr_read || !ddr_waitrequest) begin
                        if (f_word < f_words) begin
                            ddr_read <= 1'b1;
                            ddr_address <= row_base + {20'd0, f_word};
                            ddr_burstcount <= (left > 9'd8) ? 8'd8 : {1'b0, left[6:0]};
                            f_word <= f_word + ((left > 9'd8) ? 9'd8 : left);
                        end else begin
                            ddr_read <= 1'b0;
                            fs <= F_WAIT;
                        end
                    end
                end
                F_WAIT: begin
                    if (f_got == f_words) begin
                        if (bottom || !m_need_b) fs <= F_IDLE;
                        else begin
                            bottom <= 1'b1;
                            row_base <= row_base + 29'd360;
                            f_word <= '0; f_got <= '0;
                            fs <= F_CMD;
                        end
                    end
                end
                default: fs <= F_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
