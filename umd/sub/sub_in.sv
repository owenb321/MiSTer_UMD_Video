// umd/sub/sub_in.sv -- the demultiplexer's subtitle bytes into the subtitle clock domain
// (docs/subtitles.md §2)
//
// ps_demux's sp_* has no ready: a byte offered is gone. On the demux's clock (sclk) every
// byte goes into a 4 KB dual-clock FIFO as {gap, start, ptsv, byte} -- start on the first
// payload byte of each PES, ptsv when that PES carried a PTS -- and each such PTS into a
// small second FIFO. A byte that meets a full FIFO is lost: counted, and the next byte
// written carries `gap`, so sub_unit aborts the unit it cut (never glues across a hole).
// A PTS that meets a full PTS FIFO is dropped with its flag (the PES is then a
// continuation or an orphan to sub_unit), counted. On mclk the two are re-paired: a start
// byte with ptsv is presented only with its PTS.

`default_nettype none

module sub_in (
    input  wire         sclk,
    input  wire         srst_n,
    input  wire  [7:0]  sp_byte,
    input  wire         sp_valid,
    input  wire         sp_frame_start,
    input  wire  [32:0] sp_pts,
    input  wire         sp_pts_valid,
    output logic [15:0] n_lost,             // bytes lost (sclk)
    output logic [15:0] n_pts_lost,

    input  wire         mclk,
    input  wire         mrst_n,
    output logic [7:0]  s_byte,
    output logic        s_start,
    output logic        s_ptsv,
    output logic [32:0] s_pts,
    output logic        s_gap,
    output logic        s_valid,
    input  wire         s_ready
);

    // ---- sclk: write both FIFOs -------------------------------------------------------------------
    logic        bf_full, pf_full, lost;
    wire         want_pts = sp_frame_start && sp_pts_valid;
    wire         pts_ok   = want_pts && !pf_full && !bf_full;
    wire         bwr      = sp_valid && !bf_full;
    always_ff @(posedge sclk) begin
        if (!srst_n) begin lost <= 1'b0; n_lost <= '0; n_pts_lost <= '0; end
        else if (sp_valid) begin
            if (bf_full) begin lost <= 1'b1; n_lost <= n_lost + 16'd1; end
            else begin
                lost <= 1'b0;
                if (want_pts && pf_full) n_pts_lost <= n_pts_lost + 16'd1;
            end
        end
    end

    logic [10:0] bf_dout;
    logic        bf_empty, bf_valid, bf_rd;
    fifo_dc #(.DW(11), .AW(12)) u_bf (
        .wr_clk (sclk), .wr_rst_n (srst_n), .din ({lost, sp_frame_start, pts_ok, sp_byte}), .wr_en (bwr),
        .full (bf_full), .wr_free (),
        .rd_clk (mclk), .rd_rst_n (mrst_n), .dout (bf_dout), .rd_en (bf_rd), .empty (bf_empty), .valid (bf_valid)
    );
    logic [32:0] pf_dout;
    logic        pf_empty, pf_valid, pf_rd;
    fifo_dc #(.DW(33), .AW(4)) u_pf (
        .wr_clk (sclk), .wr_rst_n (srst_n), .din (sp_pts), .wr_en (pts_ok),
        .full (pf_full), .wr_free (),
        .rd_clk (mclk), .rd_rst_n (mrst_n), .dout (pf_dout), .rd_en (pf_rd), .empty (pf_empty), .valid (pf_valid)
    );

    // ---- mclk: one-entry heads over both pull ports -------------------------------------------------
    logic [10:0] bh;
    logic        bh_v, bpend;
    logic [32:0] ph;
    logic        ph_v, ppend;
    wire         need_pts = bh[8];
    assign s_valid = bh_v && (!need_pts || ph_v);
    assign {s_gap, s_start, s_ptsv, s_byte} = bh;
    assign s_pts   = ph;
    wire         take  = s_valid && s_ready;
    assign bf_rd = !bf_empty && !bpend && (!bh_v || take);
    assign pf_rd = !pf_empty && !ppend && (!ph_v || (take && need_pts));
    always_ff @(posedge mclk) begin
        if (!mrst_n) begin bh_v <= 1'b0; bpend <= 1'b0; ph_v <= 1'b0; ppend <= 1'b0; end
        else begin
            bpend <= bf_rd;
            ppend <= pf_rd;
            if (take) bh_v <= 1'b0;
            if (take && need_pts) ph_v <= 1'b0;
            if (bpend && bf_valid) begin bh <= bf_dout; bh_v <= 1'b1; end
            if (ppend && pf_valid) begin ph <= pf_dout; ph_v <= 1'b1; end
        end
    end

endmodule

`default_nettype wire
