// umd/recon_out.sv -- the reconstruction's output queue to the display (P5d,
// docs/display.md S6): what recon_top's output process emits (clk_dec), as records the
// display takes (clk_sys), and the display's releases back as the DPB's holds.
//
//   clk_dec  pinfo_*  every picture's display facts when it opens, by store: the "a"
//                     half (its first picture: size, cropping, aspect, the VUI timing --
//                     num_units_in_tick / time_scale, P5e divides them on clk_sys --
//                     pic_struct, PTS, IDR) or, for a pair's second field, the "b" half
//                     (its pic_struct and PTS). A table, 32 entries a half, written here,
//                     read by clk_sys.
//            emit_*   one store to show, in output order (C.4.5.3, the store is the unit:
//                     emitted whole, once per allocation). It goes on the record FIFO and
//                     its hold bit rises (oq_hold -> recon_dpb's disp_hold: the decoder
//                     cannot reuse the store until the display gives it back).
//            pinfo_ep the picture's playlist item tag (P6b3i: the item index mod 4, with its
//                     PTS; docs/transport.md), kept per half like the PTS
//            eos_done the end-of-stream flush is complete: an END record follows the last
//                     store (the display holds the last picture; P5e).
//   clk_sys  rec_*    the record at the head: its FIFO word, then its table row (the
//                     store's facts cannot change while it is queued: a store is written
//                     only when it opens, and it cannot open again while held). rec_take
//                     consumes it.
//            rel_*    a store the display is done with: through the release FIFO, its
//                     hold bit falls.
//
// Depths: a store is emitted at most once per allocation and held until released, so at
// most NSTORE (20) records are ever queued -- the 32-deep FIFOs cannot fill (a push
// while full is counted, rec_ovf, and would be a design error, never silent). A release
// of a store not held is counted too (rel_bad: a display bug).
//
// Resets: one per domain (fifo_dc's rules). The mount resets both with the decoder. A
// seek does NOT reset this module (P6b3, docs/transport.md S2.1): the decoder resets
// behind it, and the display drains the queue (disp_ctl takes and releases every queued
// record unseen) while the store on screen stays held here. rec_idle (clk_sys) says the
// drain is complete: nothing queued, nothing in the read pipe.

`default_nettype none

module recon_out #(
    parameter int NST = 20
) (
    // ---- clk_dec: the reconstruction's side ----
    input  wire          clk,
    input  wire          rst_n,
    input  wire          pinfo_we,
    input  wire  [4:0]   pinfo_store,
    input  wire          pinfo_second,
    input  wire  [7:0]   pinfo_w_mbs,
    input  wire  [7:0]   pinfo_hf_mbs,
    input  wire  [39:0]  pinfo_crop,
    input  wire  [39:0]  pinfo_aspect,       // {aspect_ratio_idc, sar_width, sar_height}
    input  wire          pinfo_timing_v,     // the SPS's VUI timing_info_present_flag
    input  wire  [31:0]  pinfo_nuit,         //   num_units_in_tick
    input  wire  [31:0]  pinfo_ts,           //   time_scale
    input  wire  [3:0]   pinfo_ps,
    input  wire          pinfo_ps_v,
    input  wire  [32:0]  pinfo_pts,
    input  wire          pinfo_pts_v,
    input  wire          pinfo_idr,
    input  wire  [1:0]   pinfo_ep,           // P6b3i: the item tag, meaningful with pinfo_pts_v
    input  wire          emit_valid,
    input  wire  [4:0]   emit_store,
    input  wire          emit_unpaired,
    input  wire          emit_first_bot,
    input  wire          emit_frame,
    input  wire          emit_dec_t,
    input  wire          emit_dec_b,
    input  wire          eos_done,
    output logic [NST-1:0] oq_hold,          // -> recon_top disp_hold
    output logic [31:0]  n_emit,             // stores emitted (the HUD)
    output logic [31:0]  n_rel,              // stores released
    output logic         rec_ovf,            // sticky: a record was pushed into a full FIFO
    output logic         rel_bad,            // sticky: a release of a store not held

    // ---- clk_sys: the display's side ----
    input  wire          sclk,
    input  wire          srst_n,
    output logic         rec_valid,
    input  wire          rec_take,
    output logic         rec_end,            // the END record (end of stream): no store
    output logic [4:0]   rec_store,
    output logic         rec_frame,          // coded as a frame
    output logic         rec_unpaired,       // a single field (dec_t / dec_b say which)
    output logic         rec_first_bot,      // a pair's first-decoded field is the bottom one
    output logic         rec_dec_t,
    output logic         rec_dec_b,
    output logic [7:0]   rec_w_mbs,
    output logic [7:0]   rec_hf_mbs,
    output logic [39:0]  rec_crop,
    output logic [39:0]  rec_aspect,
    output logic         rec_timing_v,
    output logic [31:0]  rec_nuit,
    output logic [31:0]  rec_ts,
    output logic [3:0]   rec_ps_a,           // pic_struct: the first picture's ...
    output logic         rec_ps_a_v,
    output logic [3:0]   rec_ps_b,           //   ... and a pair's second field's
    output logic         rec_ps_b_v,
    output logic [32:0]  rec_pts,            // the first picture's PTS (a pair's second field's
    output logic         rec_pts_v,          //   is in rec_pts_b)
    output logic [32:0]  rec_pts_b,
    output logic         rec_pts_b_v,
    output logic         rec_idr,
    output logic         rec_ep_v,           // P6b3i: the record's item tag, from the half that
    output logic [1:0]   rec_ep,             //   carries a PTS (the first, else a pair's second)
    input  wire          rel_valid,
    input  wire  [4:0]   rel_store,
    output wire          rec_idle            // nothing queued or in flight on this side (P6b3)
);

    // ---- the store table: a (201 bits) and b (39 bits), by store ----------------------
    localparam int AW_A = 203, AW_B = 41;
    logic [AW_A-1:0] tab_a [0:31];
    logic [AW_B-1:0] tab_b [0:31];
    always_ff @(posedge clk) begin
        if (pinfo_we && !pinfo_second)
            tab_a[pinfo_store] <= {pinfo_w_mbs, pinfo_hf_mbs, pinfo_crop, pinfo_aspect, pinfo_timing_v, pinfo_nuit,
                                   pinfo_ts, pinfo_ps, pinfo_ps_v, pinfo_pts, pinfo_pts_v, pinfo_idr, pinfo_ep};
        if (pinfo_we && pinfo_second)
            tab_b[pinfo_store] <= {pinfo_ps, pinfo_ps_v, pinfo_pts, pinfo_pts_v, pinfo_ep};
    end

    // ---- the record FIFO: {end, store, frame, unpaired, first_bot, dec_t, dec_b} -----
    logic [10:0] rq_din, rq_dout;
    logic        rq_we, rq_full, rq_empty, rq_rd, rq_valid;
    always_comb begin
        rq_we  = emit_valid || eos_done;
        rq_din = eos_done && !emit_valid ? {1'b1, 10'd0}
                                         : {1'b0, emit_store, emit_frame, emit_unpaired, emit_first_bot, emit_dec_t, emit_dec_b};
    end
    fifo_dc #(.DW(11), .AW(5)) u_rec (
        .wr_clk(clk), .wr_rst_n(rst_n), .din(rq_din), .wr_en(rq_we), .full(rq_full), .wr_free(),
        .rd_clk(sclk), .rd_rst_n(srst_n), .dout(rq_dout), .rd_en(rq_rd), .empty(rq_empty), .valid(rq_valid));

    // ---- the release FIFO: a store, clk_sys -> clk_dec -------------------------------
    logic [4:0] lq_dout;
    logic       lq_empty, lq_rd, lq_valid;
    fifo_dc #(.DW(5), .AW(5)) u_rel (
        .wr_clk(sclk), .wr_rst_n(srst_n), .din(rel_store), .wr_en(rel_valid), .full(), .wr_free(),
        .rd_clk(clk), .rd_rst_n(rst_n), .dout(lq_dout), .rd_en(lq_rd), .empty(lq_empty), .valid(lq_valid));
    assign lq_rd = !lq_empty;

    // ---- clk_dec: the holds ----------------------------------------------------------
    // (eos_done and an emission never coincide: recon_dpb raises eos_done in the cycle
    // after its last scan found nothing -- both pushes would still be one FIFO word, so
    // the END record would be lost; counted as an overflow if it ever happened)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oq_hold <= '0; n_emit <= '0; n_rel <= '0; rec_ovf <= 1'b0; rel_bad <= 1'b0;
        end else begin
            if (rq_we && (rq_full || (emit_valid && eos_done))) rec_ovf <= 1'b1;
            if (lq_valid) begin
                if (lq_dout >= NST[4:0] || !oq_hold[lq_dout]) rel_bad <= 1'b1;
                n_rel <= n_rel + 32'd1;
            end
            for (int i = 0; i < NST; i++) begin
                if (emit_valid && emit_store == i[4:0]) oq_hold[i] <= 1'b1;
                else if (lq_valid && lq_dout == i[4:0]) oq_hold[i] <= 1'b0;
            end
            if (emit_valid) n_emit <= n_emit + 32'd1;
        end
    end

    // ---- clk_sys: the head record, its FIFO word then its table row ------------------
    // p0: pop (rq_rd) -> p1: the word (rq_valid) captured -> p2: the table read at the
    // captured store (fifo_dc's dout is not held after the pop) -> p3: rec_valid
    logic       p_busy;                     // a word popped and not yet presented
    logic       p_tab;                      // the table read is in flight (p1 -> p2)
    logic [9:0] p_word;
    logic       p_end;
    logic [AW_A-1:0] ra;
    logic [AW_B-1:0] rb;
    assign rq_rd = !rq_empty && !p_busy && !rec_valid;
    assign rec_idle = rq_empty && !p_busy && !p_tab && !rec_valid;
    always_ff @(posedge sclk) begin
        if (p_tab) begin
            ra <= tab_a[p_word[9:5]];
            rb <= tab_b[p_word[9:5]];
        end
    end
    always_ff @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            p_busy <= 1'b0; p_tab <= 1'b0; p_word <= '0; p_end <= 1'b0; rec_valid <= 1'b0;
        end else begin
            if (rq_rd) p_busy <= 1'b1;
            p_tab <= 1'b0;
            if (rq_valid) begin p_word <= rq_dout[9:0]; p_end <= rq_dout[10]; p_tab <= 1'b1; end
            if (p_tab) begin rec_valid <= 1'b1; p_busy <= 1'b0; end
            if (rec_valid && rec_take) rec_valid <= 1'b0;
        end
    end
    logic [1:0] ep_a, ep_b;
    always_comb begin
        rec_end       = p_end;
        {rec_store, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b} = p_word;
        {rec_w_mbs, rec_hf_mbs, rec_crop, rec_aspect, rec_timing_v, rec_nuit, rec_ts, rec_ps_a, rec_ps_a_v, rec_pts,
         rec_pts_v, rec_idr, ep_a} = ra;
        {rec_ps_b, rec_ps_b_v, rec_pts_b, rec_pts_b_v, ep_b} = rb;
        rec_ep_v = rec_pts_v || rec_pts_b_v;
        rec_ep   = rec_pts_v ? ep_a : ep_b;
    end

endmodule

`default_nettype wire
