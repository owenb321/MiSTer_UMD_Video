// umd/sub/sub_dec.sv -- the subtitle decode in the fabric, answering sub_top's host handshake
// (A12 SD1, docs/nav_engine.md §10; the handshake: sub_top.sv's header)
//
// Since A7 (PR fj#34) sub_top asks a HOST to decode each unit: h_req (a level) with {seq, buf,
// x, y, start, len}, answered by h_done with {seq, err, w, h}. This module is that host, in
// fabric, doing what the UMD Main's umd_sub did: read the unit's `len` bytes from the DDR3 ring
// at word `start`, decode them with png_top (sub_png: the hardwired decoder, E1), write plane
// `buf` at (x, y) premultiplied (sub_plane_wr), and complete -- only once every burst of the
// image is written (sub_plane_wr passes its end marker on then), so the scheduler never shows a
// plane mid-write. Why behind the handshake rather than the pre-fj#34 sub_top: the scheduler, its
// flush and stale-completion rules, sub_flip and the panel's ui_sub mode (P6d) stay as built
// and rig-confirmed.
//
// The ring: 2**RAW 64-bit words at RING_BASE; a unit's byte 8k+i is bits [8i+7:8i] of its word
// k, every unit starts on a word, and a unit may wrap at the ring's end (sub_ring.sv). The
// reader issues bursts of at most 8 words that never cross the ring's end, into a 16-word
// FIFO (a burst only when 8 slots are free, counting the beats still in flight), and unpacks
// them into sub_png's byte port, `last` on the unit's final byte. A unit of length 0 completes
// at once, refused (E_TRUNC: the input ended before IEND, as the decoder would say).
//
// flush (a seek, a track change): the decode is dropped -- sub_png's pclk side is reset
// (cdc_reset), sub_plane_wr runs a burst already on the port to its last beat, the FIFO
// empties -- and read beats still in flight are drained and discarded before the next request
// starts. A dropped request is never completed (sub_top would ignore it: its seq moved).
//
// DDR3: two Avalon masters for sub_mem (r_*: reads; w_*: sub_plane_wr's writes).

`default_nettype none

module sub_dec #(
    parameter logic [28:0] RING_BASE = 29'h0640_0000,
    parameter int          RAW       = 20,
    parameter logic [28:0] PLANE0    = 29'h0650_0000,
    parameter logic [28:0] PLANE1    = 29'h0658_0000
) (
    input  wire         mclk,
    input  wire         mrst_n,
    input  wire         flush,
    input  wire         pclk,

    // sub_top's request (held until completed or flushed)
    input  wire         h_req,
    input  wire  [7:0]  h_seq,
    input  wire         h_buf,
    input  wire  [15:0] h_x,
    input  wire  [15:0] h_y,
    input  wire  [RAW-1:0] h_start,
    input  wire  [31:0] h_len,
    // ... and its completion (a pulse)
    output logic        h_done,
    output logic [7:0]  h_done_seq,
    output logic [4:0]  h_done_err,
    output logic [15:0] h_done_w,
    output logic [15:0] h_done_h,

    // the ring reader (reads)
    output logic [28:0] r_address,
    output logic [7:0]  r_burstcount,
    output logic        r_read,
    input  wire         r_waitrequest,
    input  wire  [63:0] r_readdata,
    input  wire         r_readdatavalid,

    // the plane writer (writes)
    output logic [28:0] w_address,
    output logic [7:0]  w_burstcount,
    output logic        w_write,
    output logic [63:0] w_writedata,
    output logic [7:0]  w_byteenable,
    input  wire         w_waitrequest,

    output logic [15:0] n_clipped
);
    localparam int RWORDS = 1 << RAW;

    // ---- flush, and png_top's reset (as sub_top had it before PR fj#34) ------------------------
    logic flush_r;
    always_ff @(posedge mclk) flush_r <= !mrst_n || flush;
    wire  m2rst_n = !flush_r;               // sub_png's mclk side: a flop, never logic, on a reset pin
    logic prst_n;
    cdc_reset u_prst (.clk (pclk), .rst_n_in (m2rst_n), .rst_n_out (prst_n));

    // ---- the request ---------------------------------------------------------------------------
    logic           busy;                   // a request taken, not yet completed
    logic           done_v;                 // the last completed request's seq (do not restart it)
    logic [7:0]     done_seq, cur_seq;
    logic           cur_buf;
    logic [15:0]    cur_x, cur_y;
    logic [RAW-1:0] rptr;                   // the next word to read
    logic [31:0]    wleft;                  // words still to request
    logic [31:0]    bleft;                  // bytes still to hand to sub_png
    logic [5:0]     inflight;               // read beats requested, not yet returned
    logic           drain;                  // after a flush: beats in flight are discarded

    // ---- the word FIFO (16 x 64) -----------------------------------------------------------------
    logic [63:0] fq [0:15];
    logic [3:0]  fq_wp, fq_rp;
    logic [4:0]  fq_n;
    logic [2:0]  bi;                        // the byte of the head word next out

    // a burst: up to 8 words, not past the ring's end, only with 8 free slots
    wire [RAW:0]  to_end = RWORDS[RAW:0] - {1'b0, rptr};
    wire [31:0]   b_lim  = (to_end < 'd8) ? {{(31-RAW){1'b0}}, to_end} : 32'd8;
    wire [31:0]   b_n    = (wleft < b_lim) ? wleft : b_lim;
    wire          room   = ({1'b0, fq_n} + {1'b0, inflight}) <= 7'd8;

    // ---- sub_png ---------------------------------------------------------------------------------
    logic        b_ready, p_valid, p_end, p_ready;
    logic [15:0] p_x, p_y, p_w, p_h;
    logic [31:0] p_rgba;
    logic [4:0]  p_err;
    wire         b_valid = busy && !drain && (fq_n != 5'd0) && (bleft != 32'd0);
    wire  [7:0]  b_byte  = fq[fq_rp][{bi, 3'b000} +: 8];
    wire         b_last  = (bleft == 32'd1);
    wire         b_take  = b_valid && b_ready;
    sub_png u_png (
        .mclk, .mrst_n (m2rst_n), .pclk, .prst_n,
        .b_byte, .b_valid, .b_last, .b_ready,
        .p_valid, .p_end, .p_x, .p_y, .p_rgba, .p_err, .p_w, .p_h, .p_ready
    );

    // ---- sub_plane_wr ------------------------------------------------------------------------------
    logic        e_valid;
    logic [4:0]  e_err;
    logic [15:0] e_w, e_h;
    sub_plane_wr #(.PLANE0 (PLANE0), .PLANE1 (PLANE1)) u_pw (
        .clk (mclk), .rst_n (mrst_n), .flush,
        .buf_sel (cur_buf), .ux (cur_x), .uy (cur_y),
        .p_valid, .p_end, .p_x, .p_y, .p_rgba, .p_ready, .p_err, .p_w, .p_h,
        .e_valid, .e_err, .e_w, .e_h, .e_ready (1'b1),
        .ddr_address (w_address), .ddr_burstcount (w_burstcount), .ddr_write (w_write),
        .ddr_writedata (w_writedata), .ddr_byteenable (w_byteenable),
        .ddr_waitrequest (w_waitrequest), .n_clipped
    );

    // ---- the reader, the FIFO, the completion ------------------------------------------------------
    wire r_acc = r_read && !r_waitrequest;
    wire start = h_req && !busy && !drain && !flush && (inflight == 6'd0) &&
                 !(done_v && h_seq == done_seq);
    always_ff @(posedge mclk) begin
        if (!mrst_n) begin
            busy <= 1'b0; done_v <= 1'b0; r_read <= 1'b0; inflight <= '0; drain <= 1'b0;
            fq_wp <= '0; fq_rp <= '0; fq_n <= '0; bi <= '0; h_done <= 1'b0;
            r_burstcount <= 8'd1; r_address <= '0;
        end else begin
            h_done <= 1'b0;
            // beats back from DDR3 (kept unless a flush is draining them)
            inflight <= inflight + (r_acc ? r_burstcount[5:0] : 6'd0) - {5'd0, r_readdatavalid};
            if (r_readdatavalid && !drain && !flush) begin
                fq[fq_wp] <= r_readdata;
                fq_wp <= fq_wp + 4'd1;
            end
            // the FIFO's count: a beat in, a word out
            fq_n <= fq_n + {4'd0, r_readdatavalid && !drain && !flush}
                         - {4'd0, b_take && (bi == 3'd7 || b_last)};
            if (b_take) begin
                bleft <= bleft - 32'd1;
                if (bi == 3'd7 || b_last) begin bi <= 3'd0; fq_rp <= fq_rp + 4'd1; end
                else bi <= bi + 3'd1;
            end
            if (r_acc) r_read <= 1'b0;

            if (flush) begin
                // drop the decode; the beats in flight are drained before the next request
                busy <= 1'b0; done_v <= 1'b0;
                fq_wp <= '0; fq_rp <= '0; fq_n <= '0; bi <= '0;
                drain <= 1'b1;                      // a read still requested stays so (Avalon)
                                                    //   until accepted; its beats are drained
            end else begin
                if (drain && inflight == 6'd0 && !r_read) drain <= 1'b0;
                if (start) begin
                    busy <= 1'b1; cur_seq <= h_seq; cur_buf <= h_buf; cur_x <= h_x; cur_y <= h_y;
                    rptr <= h_start;
                    wleft <= {3'd0, h_len[31:3]} + {31'd0, h_len[2:0] != 3'd0};
                    bleft <= h_len;
                    bi <= 3'd0;
                    if (h_len == 32'd0) begin         // nothing to decode: refused at once
                        busy <= 1'b0; done_v <= 1'b1; done_seq <= h_seq;
                        h_done <= 1'b1; h_done_seq <= h_seq; h_done_err <= 5'd8;   // E_TRUNC
                        h_done_w <= 16'd0; h_done_h <= 16'd0;
                    end
                end else if (busy && !r_read && wleft != 32'd0 && room) begin
                    r_read       <= 1'b1;
                    r_address    <= RING_BASE + {{(29-RAW){1'b0}}, rptr};
                    r_burstcount <= b_n[7:0];
                    rptr         <= rptr + b_n[RAW-1:0];
                    wleft        <= wleft - b_n;
                end
                if (busy && e_valid) begin            // every burst written: complete
                    busy <= 1'b0; done_v <= 1'b1; done_seq <= cur_seq;
                    h_done <= 1'b1; h_done_seq <= cur_seq; h_done_err <= e_err;
                    h_done_w <= e_w; h_done_h <= e_h;
                end
            end
        end
    end

endmodule

`default_nettype wire
