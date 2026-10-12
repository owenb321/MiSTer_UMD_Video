// umd/sub/sub_plane_wr.sv -- a subtitle image into a DDR3 plane: premultiplied ARGB8888,
// 720-pixel pitch, absolute coordinates (docs/subtitles.md §2)
//
// In: the decoder's pixels (straight RGBA + the pixel's x, y in the image) and, in band
// after the last one, the image's end marker {err, w, h}. The pixel lands at (x + ux,
// y + uy) of plane `buf`; outside 720x480 it is clipped and counted (no disc does it, the
// header's u16 x / y allow it). Colour is premultiplied here:
//     c' = round(c * a / 255) = (c*a + 128 + ((c*a + 128) >> 8)) >> 8     (exact for 8 bits)
// and stored {A, R', G', B'} with A in [31:24]; two pixels a 64-bit word, the even x in
// [31:0]. Pixels in consecutive words are combined into bursts of up to 8 words (a row of
// a non-interlaced image: 16 pixels a burst); anything else -- a new row, Adam7's strided
// passes -- closes the burst, and a word holding one pixel is written with 4 byte enables.
// Two 8-word burst buffers, ping-pong. The end marker is passed on (e_valid) only once
// every burst of the image is written, so the scheduler never shows a plane mid-write.
// flush (a seek, a track change) drops the image, but a burst already on the port runs to
// its last beat: the controller waits for every beat of a write burst it accepted, and
// ddr_mux2 keeps the channel inside one, so an abandoned burst would hang ram2 -- the
// video's display reader with it (found composing the overlay, docs/compositor.md §8).
// The filling side restarts in the other buffer, the one the engine takes next.
//
// Timing (mclk is the DDR3 port's 90 MHz, tools/fit_unit.sh): the address (y * 360 + x /
// 2 after the unit's offset, three adders deep), the clip test and the premultiply are
// computed as a word is TAKEN and registered (stage s0); the word merging and the burst
// control work from s0. Unregistered, the path from the FIFO head through the adders, the
// word compares and the accept closed at 75.5 MHz (the cold corner).
//
// DDR3: a write-only Avalon master (sub_mem's second client).

`default_nettype none

module sub_plane_wr #(
    parameter logic [28:0] PLANE0 = 29'h0650_0000,
    parameter logic [28:0] PLANE1 = 29'h0658_0000
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         flush,

    // the image being written (from the scheduler, stable while it decodes)
    input  wire         buf_sel,
    input  wire  [15:0] ux,
    input  wire  [15:0] uy,

    // pixels and the end marker (from the decoder's crossing)
    input  wire         p_valid,
    input  wire         p_end,             // this word is the end marker, not a pixel
    input  wire  [15:0] p_x,
    input  wire  [15:0] p_y,
    input  wire  [31:0] p_rgba,            // pixel: {R, G, B, A}; marker: {err[4:0], ..}
    output logic        p_ready,
    input  wire  [4:0]  p_err,             // with p_end
    input  wire  [15:0] p_w,
    input  wire  [15:0] p_h,

    // the end, passed on once everything is in DDR3
    output logic        e_valid,
    output logic [4:0]  e_err,
    output logic [15:0] e_w,
    output logic [15:0] e_h,
    input  wire         e_ready,

    // DDR3 (write-only)
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,

    output logic [15:0] n_clipped
);

    // ---- stage s0: where the pixel goes and its premultiplied colour, registered ------------------
    logic        s0_v, s0_end, s0_clip, s0_odd;
    logic [18:0] s0_word;
    logic [31:0] s0_argb;
    logic [4:0]  s0_err;
    logic [15:0] s0_w, s0_h;
    logic        s_rdy;                    // s0 moves on this cycle (the merge takes it)
    assign p_ready = !s0_v || s_rdy;
    // The unit's position is quasi-static: sub_sched sets it as the unit is taken, hundreds
    // of cycles before its first pixel comes out of the decoder. It is registered here and
    // uy * 360 precomputed, so the per-pixel address is p_y * 360 + uy * 360 + ax / 2: the
    // route from the scheduler and one adder level leave the pixel path (it bound mclk at
    // 92.6 MHz in the overlay's unit fit, docs/compositor.md §7).
    logic [15:0] uxr, uyr;
    logic [18:0] uy360;
    always_ff @(posedge clk) begin
        uxr <= ux; uyr <= uy;
        uy360 <= {1'b0, uyr[8:0], 8'd0} + {3'd0, uyr[8:0], 6'd0} + {4'd0, uyr[8:0], 5'd0} + {6'd0, uyr[8:0], 3'd0};
    end
    wire  [16:0] ax = {1'b0, p_x} + {1'b0, uxr};
    wire  [16:0] ay = {1'b0, p_y} + {1'b0, uyr};
    wire         clip = (ax >= 17'd720) || (ay >= 17'd480);
    // word = ay * 360 + ax / 2 = p_y * 360 + uy * 360 + ax / 2 (360 = 256 + 64 + 32 + 8); an
    // unclipped pixel has p_y, uy < 480, so their low 9 bits are the whole values
    wire  [18:0] word = {2'd0, p_y[8:0], 8'd0} + {4'd0, p_y[8:0], 6'd0} + {5'd0, p_y[8:0], 5'd0} +
                        {7'd0, p_y[8:0], 3'd0} + uy360 + {10'd0, ax[9:1]};
    wire         odd = ax[0];

    // ---- premultiply ------------------------------------------------------------------------------
    wire  [7:0]  pa = p_rgba[7:0];
    wire  [15:0] mr = p_rgba[31:24] * pa + 16'd128;
    wire  [15:0] mg = p_rgba[23:16] * pa + 16'd128;
    wire  [15:0] mb = p_rgba[15:8]  * pa + 16'd128;
    // (c*a + 128) <= 65153, plus its high byte stays below 2^16: the sum needs 16 bits
    wire  [15:0] rr = mr + {8'd0, mr[15:8]};
    wire  [15:0] rg = mg + {8'd0, mg[15:8]};
    wire  [15:0] rb = mb + {8'd0, mb[15:8]};
    /* verilator lint_off UNUSEDSIGNAL */
    wire  [7:0]  rr_lo = rr[7:0], rg_lo = rg[7:0], rb_lo = rb[7:0];
    /* verilator lint_on UNUSEDSIGNAL */
    wire  [31:0] argb = {pa, rr[15:8], rg[15:8], rb[15:8]};

    // ---- the word being assembled, the two burst buffers -------------------------------------------
    logic        wv;                       // a word is open
    logic [18:0] wa;
    logic [63:0] wd;
    logic [7:0]  we;
    logic [63:0] bdat [0:15];
    logic [7:0]  bbe  [0:15];
    logic        fsel, wsel;
    logic [3:0]  fcnt;
    logic [18:0] faddr;
    logic [1:0]  bready;
    logic [3:0]  bcnt0, bcnt1;
    logic [18:0] baddr0, baddr1;
    logic        bbuf0, bbuf1;             // which plane each buffer is for
    logic        endq;                     // the end marker is being handled

    wire         is_pix   = s0_v && !s0_end;
    wire         same_w   = wv && (s0_word == wa);
    wire         next_w   = wv && (s0_word == wa + 19'd1);
    // the open word must go into the filling buffer; that buffer must be free
    wire         fbusy    = bready[fsel];
    // taking a pixel: into the open word (same word), or closing the open word first
    // (possible only if it can go into the filling buffer)
    always_comb begin
        s_rdy = 1'b0;
        if (s0_v && !endq) begin
            if (s0_end)               s_rdy = !e_valid;        // into the end sequence
            else if (s0_clip)         s_rdy = 1'b1;
            else if (same_w || !wv)   s_rdy = 1'b1;
            else                      s_rdy = !fbusy;           // the open word leaves
        end
    end
    wire         take_pix = is_pix && s_rdy && !s0_clip;
    // the open word goes into the buffer when a pixel of another word arrives
    wire         push_w   = take_pix && wv && !same_w;

    // ---- the DDR engine ---------------------------------------------------------------------------
    logic [3:0]  beat;
    logic        wr_act;
    wire  [3:0]  wcnt = wsel ? bcnt1 : bcnt0;
    wire  [18:0] wadr = wsel ? baddr1 : baddr0;
    wire         wpl  = wsel ? bbuf1 : bbuf0;
    assign ddr_address    = (wpl ? PLANE1 : PLANE0) + {10'd0, wadr};
    assign ddr_burstcount = {4'd0, wcnt};
    assign ddr_write      = wr_act;
    assign ddr_writedata  = bdat[{wsel, beat[2:0]}];
    assign ddr_byteenable = bbe[{wsel, beat[2:0]}];
    wire         wbeat = ddr_write && !ddr_waitrequest;
    wire         wdone = wbeat && (beat + 4'd1 == wcnt);

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            wv <= 1'b0; fcnt <= '0;
            endq <= 1'b0; e_valid <= 1'b0; s0_v <= 1'b0;
            // the burst on the port (if any) is kept; everything else is dropped
            fsel   <= wr_act ? !wsel : wsel;
            bready <= wr_act ? (wsel ? 2'b10 : 2'b01) : 2'b00;
            if (!rst_n) begin
                n_clipped <= '0; fsel <= 1'b0; wsel <= 1'b0; bready <= '0; wr_act <= 1'b0; beat <= '0;
            end
        end else begin
            // -- s0: take the next word from the input when s0 is free or moving on
            if (s0_v && s_rdy) s0_v <= 1'b0;
            if (p_valid && p_ready) begin
                s0_v    <= 1'b1;
                s0_end  <= p_end;
                s0_clip <= clip;
                s0_odd  <= odd;
                s0_word <= word;
                s0_argb <= argb;
                s0_err  <= p_err;
                s0_w    <= p_w;
                s0_h    <= p_h;
            end
            // -- a pixel
            if (is_pix && s_rdy && s0_clip) n_clipped <= n_clipped + 16'd1;
            if (take_pix) begin
                if (same_w) begin
                    if (s0_odd) begin wd[63:32] <= s0_argb; we[7:4] <= 4'hF; end
                    else        begin wd[31:0]  <= s0_argb; we[3:0] <= 4'hF; end
                end else begin
                    wv <= 1'b1;
                    wa <= s0_word;
                    wd <= s0_odd ? {s0_argb, 32'd0} : {32'd0, s0_argb};
                    we <= s0_odd ? 8'hF0 : 8'h0F;
                end
            end
            // -- the open word into the filling buffer (on a pixel of another word, or at the end)
            if (push_w || (endq && wv && !fbusy)) begin
                bdat[{fsel, fcnt[2:0]}] <= wd;
                bbe[{fsel, fcnt[2:0]}]  <= we;
                if (fcnt == 4'd0) faddr <= wa;
                if (!push_w) wv <= 1'b0;             // the end: the word is out
                if (fcnt == 4'd7 || (push_w && !next_w) || !push_w) begin
                    bready[fsel] <= 1'b1;
                    if (fsel) begin bcnt1 <= fcnt + 4'd1; baddr1 <= (fcnt == 4'd0) ? wa : faddr; bbuf1 <= buf_sel; end
                    else      begin bcnt0 <= fcnt + 4'd1; baddr0 <= (fcnt == 4'd0) ? wa : faddr; bbuf0 <= buf_sel; end
                    fsel <= !fsel;
                    fcnt <= '0;
                end else fcnt <= fcnt + 4'd1;
            end
            // -- the end marker: flush the open word and the filling buffer, wait for DDR3
            if (s0_v && s0_end && s_rdy) begin
                endq  <= 1'b1;
                e_err <= s0_err;
                e_w   <= s0_w;
                e_h   <= s0_h;
            end
            if (endq && !wv && fcnt != 4'd0 && !fbusy) begin
                bready[fsel] <= 1'b1;
                if (fsel) begin bcnt1 <= fcnt; baddr1 <= faddr; bbuf1 <= buf_sel; end
                else      begin bcnt0 <= fcnt; baddr0 <= faddr; bbuf0 <= buf_sel; end
                fsel <= !fsel;
                fcnt <= '0;
            end
            if (endq && !wv && fcnt == 4'd0 && bready == 2'b00 && !wr_act) begin
                endq    <= 1'b0;
                e_valid <= 1'b1;
            end
            if (e_valid && e_ready) e_valid <= 1'b0;
        end
        // -- the engine: runs through a flush (a burst is never abandoned), starts none in one
        if (rst_n) begin
            if (!wr_act) begin
                beat <= '0;
                if (bready[wsel] && !flush) wr_act <= 1'b1;
            end else if (wbeat) begin
                beat <= beat + 4'd1;
                if (wdone) begin
                    wr_act       <= 1'b0;
                    bready[wsel] <= 1'b0;
                    wsel         <= !wsel;
                end
            end
        end
    end

endmodule

`default_nettype wire
