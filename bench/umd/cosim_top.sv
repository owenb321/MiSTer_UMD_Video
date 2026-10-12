// bench/umd/cosim_top.sv -- the Verilator cosim's top (bench/umd/cosim_main.cpp): the
// decoder as emu composes it -- the front end (umd/h264/h264_top.sv) straight into the
// reconstruction (umd/h264/recon_top.sv) on clk_dec, the DPB client on the memory clock
// -- with the probes the C++ harness scores through brought out as ports (hierarchical
// reads: the harness never reaches into the model by name).
//
//   ES bytes (the harness) -> h264_top -> SE words -> recon_top -> Avalon-MM (the
//   harness's DDR model)
//
// P6b1, THE SEEK: `seek_rst_n` (clk, the harness's) pulls the decoder's reset as a mount
// does in emu -- rst_n of h264_top and recon_top, cdc_reset'ed into the memory clock for
// dpb_mem, and ddr_mux2's abort of master A (two flops on mclk, as emu's dpb_abort_q) --
// while `ps_rst_n` stays high: the parameter sets survive (docs/transport.md S2.1). The
// DPB client reaches the DDR model THROUGH ddr_mux2, as in emu (master B idle), so an
// abort mid-burst is policed by the model's Avalon arms.
//
// P6b4, TRICK PLAY: `one_frame` (the harness's +one_frame) is h264_top's: the stream ends
// after the entry's first frame (docs/transport.md S2.6).
//
// Probes: the [pre] arm's macroblock (the 48 words of the sample bank the cycle recon_mb
// starts deblocking it, as recon_top_tb.sv reads them), the [post] arm's write
// accounting, the [hang] arm's macroblock-done pulse and the counters of both halves.
// docs/h264_recon.md S5.
`default_nettype none
module cosim_top (
    input  wire         clk,
    input  wire         mclk,
    input  wire         rst_n,
    input  wire         ps_rst_n,         // P6b1: the parameter sets' reset (a seek leaves it high)
    input  wire         seek_rst_n,       // P6b1: the seek -- the decoder's reset alone (clk domain)
    input  wire         mrst_n,
    // the elementary stream
    input  wire   [7:0] es_byte,
    input  wire         es_valid,
    output wire         es_ready,
    input  wire         es_flush,
    input  wire         es_mark,          // P8: the PES sideband (cosim_main +marks=, else 0): the first
    input  wire  [32:0] es_pts,           //   payload byte of a PES with a PTS, that PTS
    input  wire   [1:0] es_ep,            //   and its item tag
    input  wire         one_frame,        // P6b4: trick play -- the front end ends the stream after the first frame
    // the display's hold on DPB stores (the harness holds a picture's store until scored)
    input  wire  [19:0] disp_hold,
    // DDR3 (Avalon-MM, mclk)
    output wire  [28:0] ddr_address,
    output wire   [7:0] ddr_burstcount,
    output wire         ddr_read,
    output wire         ddr_write,
    output wire  [63:0] ddr_writedata,
    output wire   [7:0] ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,
    // reconstruction status
    output wire         pic_start,
    output wire         pic_done,
    output wire   [4:0] cur_store,
    output wire   [1:0] cur_struct,
    output wire   [4:0] done_store,
    output wire   [1:0] done_struct,
    output wire   [7:0] width_mbs,
    output wire   [7:0] frame_height_mbs,
    output wire         idle,
    output wire  [31:0] pic_count,
    output wire  [31:0] mb_count,
    output wire  [31:0] err_count,
    output wire   [3:0] err_code,
    output wire  [31:0] mb_err_count,
    output wire  [31:0] ref_size,
    // P6b1: the recovery-point start (recon_dpb)
    output wire  [15:0] rp_starts,
    output wire  [15:0] rp_non_idr,
    output wire  [15:0] rp_pre,
    output wire  [15:0] rp_lead,
    output wire  [15:0] rp_mmco,
    // P5d, the output process: the stores emitted to the display, the end of stream
    output wire         pinfo_second,     // the picture opening is its store's second field
    output wire         emit_valid,
    output wire   [4:0] emit_store,
    output wire         emit_frame,
    output wire         emit_unpaired,
    output wire         eos_done,
    output wire  [31:0] stall_cycles,
    // front-end status
    output wire         fe_busy,
    output wire  [31:0] fe_pic_count,
    output wire  [31:0] fe_refused_count,
    output wire   [3:0] fe_refused_code,
    output wire  [31:0] fe_err_count,
    output wire   [3:0] fe_err_code,
    output wire  [31:0] se_words,
    // probes
    output wire         pre_db,           // a macroblock's samples are complete, pre-deblock
    output wire   [6:0] pre_mbx,
    output wire   [6:0] pre_mby,
    output wire [3071:0] pre_words,       // its 48 words: luma rows 0..15 x 2, Cb 8, Cr 8
    output wire         mb_done,
    output wire   [7:0] mb_state,
    output wire   [7:0] inter_state,      // recon_inter.st: the fetch side   (the profile, +prof)
    output wire   [7:0] interp_state,     // recon_inter.k: the interpolation side
    output wire   [7:0] engine_state,     // recon_mb.es: the back engine (deblock, writeback)
    output wire   [7:0] res_state,        // recon_mb.rs: the residual engine
    // P6b1: the abort's coverage (mclk): flushing, with a write burst open / A reads outstanding
    output wire         abort_flush,
    output wire         abort_wburst,
    output wire         abort_reads,
    output wire   [7:0] dbg_dpb_state,    // for the [hang] message: recon_dpb's FSM, recon_top's router,
    output wire   [7:0] dbg_router_state, //   the front end's FSM and mb_syntax's
    output wire   [7:0] dbg_fe_state,
    output wire   [7:0] dbg_mbs_state,
    output wire         a_wr_early,       // the DPB client PRESENTS a write while the mux counts its reads
                                          // outstanding (dpb_mem's rule; the mux would hold it -- [ddr])
    output wire         wr_cmd,           // a DPB write burst accepted by the memory client (clk)
    output wire  [31:0] wr_landed         // write bursts completed at the port (dpb_mem)
);
    // ---- P6b1: the decoder's reset, as emu's mount path makes it ----------------------
    wire dec_rst_n = rst_n & seek_rst_n;
    wire mem_dec_n;
    cdc_reset u_mrst (.clk(mclk), .rst_n_in(dec_rst_n), .rst_n_out(mem_dec_n));
    wire dpb_mrst_n = mrst_n & mem_dec_n;
    logic [1:0] abort_q;
    always_ff @(posedge mclk or negedge mrst_n)
        if (!mrst_n) abort_q <= 2'b11;
        else         abort_q <= {abort_q[0], ~mem_dec_n};
    wire [28:0] a_address;
    wire  [7:0] a_burstcount, a_byteenable;
    wire        a_read, a_write, a_waitrequest, a_readdatavalid;
    wire [63:0] a_writedata, a_readdata;
    ddr_mux2 u_mux (
        .clk(mclk), .rst_n(mrst_n),
        .a_address(a_address), .a_burstcount(a_burstcount), .a_read(a_read), .a_write(a_write),
        .a_writedata(a_writedata), .a_byteenable(a_byteenable), .a_abort(abort_q[1]),
        .a_waitrequest(a_waitrequest), .a_readdata(a_readdata), .a_readdatavalid(a_readdatavalid),
        .b_address(29'd0), .b_burstcount(8'd0), .b_read(1'b0), .b_write(1'b0), .b_writedata(64'd0),
        .b_waitrequest(), .b_readdata(), .b_readdatavalid(),
        .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
        .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
        .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));

    wire        se_valid, se_ready;
    wire  [7:0] se_kind, se_aux;
    wire [31:0] se_val;
    wire [31:0] fe_nal, fe_slice, fe_sps, fe_pps;
    wire [39:0] fe_bins;

    h264_top u_fe (
        .clk(clk), .rst_n(dec_rst_n), .ps_rst_n(ps_rst_n), .clear(1'b0),
        .es_byte(es_byte), .es_valid(es_valid), .es_ready(es_ready), .es_flush(es_flush),
        .es_mark(es_mark), .es_pts(es_pts), .es_ep(es_ep),            // P8: the PES sideband (+marks=), else 0
        .one_frame(one_frame),
        .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
        .sp_pps(), .sp_sps(), .sp_slice_type(), .sp_field(), .sp_bottom(), .sp_idr(),
        .sp_frame_num(), .sp_poc_lsb(),
        .busy(fe_busy), .nal_count(fe_nal), .slice_count(fe_slice), .pic_count(fe_pic_count),
        .sps_count(fe_sps), .pps_count(fe_pps), .refused_count(fe_refused_count),
        .refused_code(fe_refused_code), .err_count(fe_err_count), .err_code(fe_err_code),
        .bin_total(fe_bins));

    recon_top #(.DPB_BASE(29'h0600_0000)) dut (
        .clk(clk), .rst_n(dec_rst_n), .ps_rst_n(ps_rst_n), .clear(1'b0),
        .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
        .disp_hold(disp_hold), .disp_frz(1'b0), .pic_start(pic_start), .cur_store(cur_store), .cur_struct(cur_struct),
        .pic_done(pic_done), .done_store(done_store), .done_struct(done_struct),
        .width_mbs(width_mbs), .frame_height_mbs(frame_height_mbs), .idle(idle),
        .pinfo_second(pinfo_second), .emit_valid(emit_valid), .emit_store(emit_store), .emit_frame(emit_frame),
        .emit_unpaired(emit_unpaired), .eos_done(eos_done), .stall_cycles(stall_cycles),
        .mclk(mclk), .mrst_n(dpb_mrst_n),
        .ddr_address(a_address), .ddr_burstcount(a_burstcount), .ddr_read(a_read), .ddr_write(a_write),
        .ddr_writedata(a_writedata), .ddr_byteenable(a_byteenable), .ddr_waitrequest(a_waitrequest),
        .ddr_readdata(a_readdata), .ddr_readdatavalid(a_readdatavalid),
        .pic_count(pic_count), .mb_count(mb_count), .err_count(err_count), .err_code(err_code), .ref_size(ref_size),
        .rp_starts(rp_starts), .rp_non_idr(rp_non_idr), .rp_pre(rp_pre), .rp_lead(rp_lead), .rp_mmco(rp_mmco));

    // SE words the reconstruction accepted
    logic [31:0] se_n;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) se_n <= '0;
        else if (se_valid && se_ready) se_n <= se_n + 1'b1;
    assign se_words = se_n;

    assign mb_err_count = dut.u_mb.err_count;
    assign pre_db  = dut.u_mb.dbg_pre_db;
    assign pre_mbx = dut.u_mb.mbx;
    assign pre_mby = dut.u_mb.mby;
    genvar k;
    generate for (k = 0; k < 48; k++) begin : PW
        assign pre_words[64*k +: 64] = (dut.u_mb.dbg_bank == 2'd2) ? dut.u_mb.bank2[k] :
                                       (dut.u_mb.dbg_bank == 2'd1) ? dut.u_mb.bank1[k] : dut.u_mb.bank0[k];
    end endgenerate
    assign mb_done   = dut.u_mb.mb_done;
    assign mb_state  = 8'(dut.u_mb.ms);
    assign inter_state  = 8'(dut.u_mb.u_inter.st);
    assign interp_state = 8'(dut.u_mb.u_inter.k);
    assign engine_state = 8'(dut.u_mb.es);
    assign res_state    = 8'(dut.u_mb.rs);
    assign wr_cmd    = dut.m_cmd_valid && dut.c_cmd_ready && dut.m_cmd_write;
    // (the probes above reset with the decoder on a seek, as the harness expects)
    assign dbg_dpb_state    = 8'(dut.u_dpb.ds);
    assign dbg_router_state = 8'(dut.rs);
    assign dbg_fe_state     = 8'(u_fe.state);
    assign dbg_mbs_state    = 8'(u_fe.mbs.state);
    assign abort_flush  = u_mux.a_flush;
    assign abort_wburst = (u_mux.a_wburst != 8'd0);
    assign abort_reads  = (u_mux.a_out != 5'd0);
    assign a_wr_early   = a_write && (u_mux.a_out != 5'd0) && !u_mux.a_flush;
    assign wr_landed = dut.u_mem.stat_writes;
endmodule
`default_nettype wire
