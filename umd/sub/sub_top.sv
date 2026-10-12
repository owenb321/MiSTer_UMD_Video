// umd/sub/sub_top.sv -- subtitles, from the demultiplexer's bytes to a unit in DDR3, the
// host's decode of it into a plane, and the requests that show and hide that plane
// (docs/subtitles.md §2; A7, docs/hps_host.md §3.2)
//
//   sclk  ps_demux sp_* -> sub_in ==fifo_dc==> (mclk) sub_unit -> sub_ring (DDR3 ring)
//   mclk  sub_sched: STC, the queue, the two planes, the display's requests / acks
//   mclk  the host request: the unit sub_sched takes, out to the HPS (umd_host crosses it);
//         the host reads the unit from the ring, decodes it into plane h_buf itself, and
//         completes -- the completion is sub_sched's end of decode
//   mclk  sub_mem: the ring writer's register in front of ddr_mux2's A on ram2
// Clocks: sclk the demux's, mclk the DDR3 port's. The STC and flush arrive on mclk, the
// display's d_* live on mclk (the compositor crosses them).
//
// THE HOST HANDSHAKE (mclk; umd_host.sv carries it to EXT_BUS on clk_sys):
//   h_req (level) with {h_seq, h_buf, h_x, h_y, h_start, h_len}: a unit to decode into
//   plane h_buf, from word h_start of the ring, h_len bytes. It stays up until its
//   completion is accepted or a flush drops it. h_seq counts requests mod 256 and is never
//   reset by a flush (a late completion of a dropped request then never matches the next
//   one); h_gen counts flushes (the host abandons a decode whose gen is stale).
//   h_done (a pulse) with {h_done_seq, h_done_err, h_done_w, h_done_h}: ACCEPTED only if a
//   request is outstanding and the seq matches, and not in a flush's cycle; then the unit's
//   ring words are freed and sub_sched gets its e_* (err != 0: refused, never shown). Any
//   other completion is ignored and counted in n_stale. The host serves one request at a
//   time, in order, so a dropped request's late pixels land before the next request's, in
//   the back plane, before the completion that shows it (hps_host.md §3.2).
//   h_vis / h_shown_seq: the front plane is shown, and the seq of the unit in it.
// flush: every stage drops what it holds; gen moves.

`default_nettype none

module sub_top #(
    parameter logic [28:0] RING_BASE = 29'h0640_0000,
    parameter int          RAW       = 20,
    parameter int          MAW       = 6,
    // A12 SD1 (docs/nav_engine.md §10): 1 -- the fabric answers the host handshake itself
    // (umd/sub/sub_dec.sv: png_top into the plane); h_done* below are then unused. 0 -- an
    // external host answers it (A7's HPS; the mock-host benches)
    parameter bit          FABRIC_DEC = 1'b1,
    parameter logic [28:0] PLANE0    = 29'h0650_0000,
    parameter logic [28:0] PLANE1    = 29'h0658_0000
) (
    input  wire         sclk,
    input  wire         srst_n,
    input  wire  [7:0]  sp_byte,
    input  wire         sp_valid,
    input  wire         sp_frame_start,
    input  wire  [32:0] sp_pts,
    input  wire         sp_pts_valid,

    input  wire         pclk,               // png_top's clock (FABRIC_DEC)
    input  wire         mclk,
    input  wire         mrst_n,
    input  wire         flush,
    input  wire  [32:0] stc,
    input  wire         stc_valid,

    output logic        d_req,
    output logic        d_buf,
    output logic        d_vis,
    output logic [15:0] d_x,
    output logic [15:0] d_y,
    output logic [15:0] d_w,
    output logic [15:0] d_h,
    input  wire         d_ack,

    // the host (mclk)
    output logic        h_req,
    output logic [7:0]  h_seq,
    output logic        h_buf,
    output logic [15:0] h_x,
    output logic [15:0] h_y,
    output logic [RAW-1:0] h_start,
    output logic [31:0] h_len,
    output logic [7:0]  h_gen,
    output logic        h_vis,
    output logic [7:0]  h_shown_seq,
    output logic        h_sbuf,             // A12 SD2: the plane and rectangle of the unit h_shown_seq names
    output logic [15:0] h_sx,
    output logic [15:0] h_sy,
    output logic [15:0] h_sw,
    output logic [15:0] h_sh,
    /* verilator lint_off UNUSEDSIGNAL */      // (FABRIC_DEC 1: the fabric's own completion)
    input  wire         h_done,             // (an external host's completion: FABRIC_DEC 0)
    input  wire  [7:0]  h_done_seq,
    input  wire  [4:0]  h_done_err,
    input  wire  [15:0] h_done_w,
    input  wire  [15:0] h_done_h,
    /* verilator lint_on UNUSEDSIGNAL */

    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,
    output logic [15:0] n_clipped,          // the fabric decoder's pixels outside 720x480

    // counters (sclk: in_*; the rest mclk)
    output logic [15:0] in_lost,
    output logic [15:0] in_pts_lost,
    output logic [15:0] n_units,
    output logic [15:0] n_truncated,
    output logic [15:0] n_overrun,
    output logic [15:0] n_orphan,
    output logic [15:0] n_lost,
    output logic [15:0] n_ring_full,
    output logic [15:0] n_badhdr,
    output logic [15:0] n_oddfield,
    output logic [15:0] n_shown,
    output logic [15:0] n_late,
    output logic [15:0] n_missed,
    output logic [15:0] n_refused,
    output logic [15:0] n_stale             // completions ignored (no request, or not its seq)
);

    // ---- the bytes in -----------------------------------------------------------------------------------
    logic [7:0]  s_byte;
    logic        s_start, s_ptsv, s_gap, s_valid, s_ready;
    logic [32:0] s_pts;
    sub_in u_in (
        .sclk, .srst_n, .sp_byte, .sp_valid, .sp_frame_start, .sp_pts, .sp_pts_valid,
        .n_lost (in_lost), .n_pts_lost (in_pts_lost),
        .mclk, .mrst_n, .s_byte, .s_start, .s_ptsv, .s_pts, .s_gap, .s_valid, .s_ready
    );

    logic        u_begin, u_accept, u_valid, u_last, u_ready, u_abort;
    logic [31:0] u_len, u_words;
    logic [7:0]  u_byte;
    logic [32:0] rec_pts;
    logic [31:0] rec_dur;
    logic [15:0] rec_x, rec_y;
    sub_unit u_unit (
        .clk (mclk), .rst_n (mrst_n), .flush,
        .s_byte, .s_start, .s_ptsv, .s_pts, .s_gap, .s_valid, .s_ready,
        .u_begin, .u_len, .u_words, .u_accept, .u_byte, .u_valid, .u_last, .u_ready, .u_abort,
        .rec_pts, .rec_dur, .rec_x, .rec_y,
        .n_units, .n_truncated, .n_overrun, .n_orphan, .n_lost, .n_refused (n_ring_full),
        .n_badhdr, .n_oddfield
    );

    // ---- the ring ----------------------------------------------------------------------------------------
    logic        q_valid, q_take, accept;
    logic [32:0] q_pts;
    logic [31:0] q_dur, q_len;
    logic [15:0] q_x, q_y;
    logic [RAW-1:0] q_start;
    /* verilator lint_off UNUSEDSIGNAL */      // status the integration may read (a HUD row)
    logic        flushing, rd_busy;         // rd_busy: the same interval as sub_sched's B_DEC
    logic [MAW:0] ring_units;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [28:0] ra_address;
    logic [7:0]  ra_burstcount, ra_byteenable;
    logic        ra_write, ra_waitrequest;
    logic [63:0] ra_writedata;
    sub_ring #(.RING_BASE (RING_BASE), .RAW (RAW), .MAW (MAW)) u_ring (
        .clk (mclk), .rst_n (mrst_n), .flush, .flushing,
        .u_begin, .u_len, .u_words, .u_accept, .u_byte, .u_valid, .u_last, .u_ready, .u_abort,
        .rec_pts, .rec_dur, .rec_x, .rec_y,
        .q_valid, .q_pts, .q_dur, .q_x, .q_y, .q_len, .q_start, .q_take, .rd_busy, .done (accept),
        .ddr_address (ra_address), .ddr_burstcount (ra_burstcount), .ddr_write (ra_write),
        .ddr_writedata (ra_writedata), .ddr_byteenable (ra_byteenable),
        .ddr_waitrequest (ra_waitrequest), .n_units (ring_units)
    );

    // the completion: the fabric decoder's (FABRIC_DEC), or the external host's
    logic        c_done;
    logic [7:0]  c_seq;
    logic [4:0]  c_err;
    logic [15:0] c_w, c_h;

    // ---- the scheduler, its decode partner being the host --------------------------------------------------
    logic        wr_buf, e_ready;
    logic [15:0] wr_x, wr_y;
    sub_sched u_sched (
        .clk (mclk), .rst_n (mrst_n), .flush, .stc, .stc_valid,
        .q_valid, .q_pts, .q_dur, .q_x, .q_y, .q_take,
        .wr_buf, .wr_x, .wr_y,
        .e_valid (accept), .e_err (c_err), .e_w (c_w), .e_h (c_h), .e_ready,
        .d_req, .d_buf, .d_vis, .d_x, .d_y, .d_w, .d_h, .d_ack,
        .n_shown, .n_late, .n_missed, .n_refused
    );

    // ---- the host request and its completion -------------------------------------------------------------
    // e_ready is sub_sched's "a decode is outstanding" (B_DEC): from q_take to the accepted
    // completion, or a flush. The ring's rd_busy is the same interval.
    assign h_req   = e_ready;
    assign h_buf   = wr_buf;
    assign h_x     = wr_x;
    assign h_y     = wr_y;
    assign accept  = c_done && e_ready && (c_seq == h_seq) && !flush;

    logic        flush_d;
    logic [7:0]  b_seq;                     // the unit in the back plane, decoded and ready
    always_ff @(posedge mclk) begin
        if (!mrst_n) begin
            h_seq <= '0; h_gen <= '0; h_vis <= 1'b0; h_shown_seq <= '0; b_seq <= '0;
            n_stale <= '0; flush_d <= 1'b0; h_start <= '0; h_len <= '0;
            h_sbuf <= 1'b0; h_sx <= '0; h_sy <= '0; h_sw <= '0; h_sh <= '0;
        end else begin
            flush_d <= flush;
            if (flush && !flush_d) h_gen <= h_gen + 8'd1;
            if (q_take) begin
                h_seq   <= h_seq + 8'd1;
                h_start <= q_start;
                h_len   <= q_len;
            end
            if (accept) b_seq <= h_seq;
            if (c_done && !accept) n_stale <= n_stale + 16'd1;
            if (d_req && d_ack) begin
                h_vis <= d_vis;
                if (d_vis) begin
                    h_shown_seq <= b_seq;
                    h_sbuf <= d_buf; h_sx <= d_x; h_sy <= d_y; h_sw <= d_w; h_sh <= d_h;
                end
            end
        end
    end

    // ---- the decode: in the fabric (A12 SD1), or the external host's -------------------------------------
    logic [28:0] dr_address, dw_address;
    logic [7:0]  dr_burstcount, dw_burstcount, dw_byteenable;
    logic        dr_read, dr_waitrequest, dr_readdatavalid, dw_write, dw_waitrequest;
    logic [63:0] dr_readdata, dw_writedata;
    generate if (FABRIC_DEC) begin : g_dec
        sub_dec #(.RING_BASE (RING_BASE), .RAW (RAW), .PLANE0 (PLANE0), .PLANE1 (PLANE1)) u_dec (
            .mclk, .mrst_n, .flush, .pclk,
            .h_req, .h_seq, .h_buf, .h_x, .h_y, .h_start, .h_len,
            .h_done (c_done), .h_done_seq (c_seq), .h_done_err (c_err), .h_done_w (c_w), .h_done_h (c_h),
            .r_address (dr_address), .r_burstcount (dr_burstcount), .r_read (dr_read),
            .r_waitrequest (dr_waitrequest), .r_readdata (dr_readdata), .r_readdatavalid (dr_readdatavalid),
            .w_address (dw_address), .w_burstcount (dw_burstcount), .w_write (dw_write),
            .w_writedata (dw_writedata), .w_byteenable (dw_byteenable), .w_waitrequest (dw_waitrequest),
            .n_clipped
        );
    end else begin : g_host
        assign c_done = h_done; assign c_seq = h_done_seq; assign c_err = h_done_err;
        assign c_w = h_done_w; assign c_h = h_done_h;
        assign dr_address = '0; assign dr_burstcount = 8'd1; assign dr_read = 1'b0;
        assign dw_address = '0; assign dw_burstcount = 8'd1; assign dw_write = 1'b0;
        assign dw_writedata = '0; assign dw_byteenable = '0; assign n_clipped = '0;
    end endgenerate

    // ---- one master: the ring writer first, the decoder's reads, its plane writes -----------------------
    sub_mem u_mem (
        .clk (mclk), .rst_n (mrst_n),
        .a_address (ra_address), .a_burstcount (ra_burstcount), .a_write (ra_write),
        .a_writedata (ra_writedata), .a_byteenable (ra_byteenable), .a_waitrequest (ra_waitrequest),
        .r_address (dr_address), .r_burstcount (dr_burstcount), .r_read (dr_read),
        .r_waitrequest (dr_waitrequest), .r_readdata (dr_readdata), .r_readdatavalid (dr_readdatavalid),
        .w_address (dw_address), .w_burstcount (dw_burstcount), .w_write (dw_write),
        .w_writedata (dw_writedata), .w_byteenable (dw_byteenable), .w_waitrequest (dw_waitrequest),
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid
    );

endmodule

`default_nettype wire
