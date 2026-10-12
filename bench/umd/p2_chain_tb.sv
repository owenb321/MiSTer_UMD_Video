// bench/umd/p2_chain_tb.sv -- the P2 chain as emu.sv composes it:
//   umd_reader -> ps_stream_fifo -> ps_demux -> es_probe
// over a --nav fixture (+stem=), with the reader's busy driven by the FIFO's almost_full
// (not a bench stimulus) and the default tracks picked the way emu picks them (the
// lowest declared audio / subtitle substream). Video and audio are backpressured at
// random: emu ties both sinks ready in P2, where the FIFO would never fill and the busy
// seam would go unexercised; P3's decoder stalls them. Scored at the end, against
// tools/psmf_golden.py run over the same stream packs (+golden=<stem>.dmeta.hex):
//
//   [chain]  es_probe's video / audio / subtitle byte counts and the video ES CRC-32
//            equal psmf_ref's; the reader raised no error
//
// Each unit has its own bench (run_umd_reader.sh, run_ps_demux.sh); this one exists for
// the SEAMS: a byte dropped when the demux stalls the FIFO, a demux that does not
// restart on a mount, a probe fed the wrong bus. PASS marker "PASS: p2_chain_tb".
`timescale 1ns/1ps
module p2_chain_tb;

localparam MAXSEC = 2048;             // a --nav fixture with its navigation script's sectors
localparam MAXREG = 128, RW = 11, MAXSSEQ = 8192;
reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0, start = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg  [7:0] img  [0:MAXSEC*2048-1];
reg [31:0] lbas [0:MAXSEC-1];
reg [31:0] meta [0:15];
reg [31:0] dm   [0:31];
reg [31:0] regw [0:RW*MAXREG-1];
reg [31:0] sseq [0:MAXSSEQ-1];
string stem, gstem;
integer n_sec, n_sseq, n_reg, seed = 3;

function integer find_sec(input [31:0] lba);
    integer i;
    begin
        find_sec = -1;
        for (i = 0; i < n_sec; i = i + 1) if (lbas[i] == lba) find_sec = i;
    end
endfunction

// The golden covers the walk's stream (phase 0, .sseq.hex) alone. Since P6b2 a fixture
// also holds the sectors its navigation script's seeks land on; the walk runs on into
// them when a seek lands just past phase 0, so an .MPS sector outside phase 0 reads as
// zeros here, as it did when fixtures held nothing else.
function served(input [31:0] lba);
    integer r, j;
    begin
        served = 1'b1;
        for (r = 0; r < n_reg; r = r + 1)
            if (regw[RW*r+2][31:16] == 8 && lba >= regw[RW*r] && lba < regw[RW*r] + regw[RW*r+1]) begin
                served = 1'b0;                  // an .MPS sector: only phase 0's
                for (j = 0; j < n_sseq; j = j + 1) if (sseq[j] == lba) served = 1'b1;
            end
    end
endfunction

// ---- sd model (hps_io's shape; sectors outside the fixture read as zeros) ----------
wire [31:0] sd_lba;
wire        sd_rd;
reg         sd_ack = 1'b0;
reg  [13:0] sd_buff_addr = 14'd0;
reg   [7:0] sd_buff_dout = 8'd0;
reg         sd_buff_wr = 1'b0;
initial begin : server
    integer i, sidx;
    wait (rst_n);
    forever begin
        @(posedge clk);
        if (sd_rd && !sd_ack) begin
            sidx = served(sd_lba) ? find_sec(sd_lba) : -1;
            repeat (2 + ($unsigned($random(seed)) % 24)) @(posedge clk);
            sd_ack <= 1'b1;
            for (i = 0; i < 2048; i = i + 1) begin
                @(posedge clk);
                sd_buff_addr <= i;
                sd_buff_dout <= (sidx >= 0) ? img[sidx*2048 + i] : 8'h00;
                sd_buff_wr   <= 1'b1;
                @(posedge clk);
                sd_buff_wr   <= 1'b0;
            end
            repeat (2) @(posedge clk);
            sd_ack <= 1'b0;
            @(posedge clk);
        end
    end
end

// ---- the chain -----------------------------------------------------------------------
wire  [7:0] stream_data;
wire        stream_valid, stream_busy;
wire  [3:0] rd_err;
wire        rd_done;
wire [31:0] rd_secs, sub_present;
wire [15:0] aud_present;
umd_reader rd (
    .clk(clk), .rst_n(rst_n), .start(start), .stop(1'b0), .file_size({meta[7], meta[6]}),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .stream_data(stream_data), .stream_valid(stream_valid), .stream_ep(), .item_hold(1'b0), .busy(stream_busy),
    .state_o(), .active(), .err_code(rd_err), .streaming(), .title_done(rd_done),
    .secs_streamed(rd_secs), .sfo_warn(), .title_trunc(), .dur_sat(), .title_addr(7'd0),
    .title_q(), .title_addr2(7'd0), .title_q2(), .item_base(), .pl_dur(), .title_len(), .main_pl(), .n_playlists(), .n_items(), .item_idx(),
    .clip_name(), .item_in_pts(), .item_out_pts(), .item_start(), .mps_lba(), .mps_bytes(),
    .clip_start_pts(), .clip_end_pts(), .n_streams(), .n_video(), .n_unknown(),
    .vid_attr0(), .vid_attr1(), .aud_present(aud_present), .sub_present(sub_present),
    .ep_map_off(), .lang_sel(6'd0), .lang_q(),
    // the navigation port (P6b2) is idle: this bench scores the walk's stream (phase 0)
    .nav_req(1'b0), .nav_op(3'd0), .nav_item(32'd0), .nav_pts(48'd0), .nav_pl(16'd0), .nav_ready(),
    .nav_done(), .nav_err(), .nav_land(), .nav_ep_idx(), .nav_ep_pts(), .nav_ep_sec(),
    .nav_skip(), .ep_flags(), .ch_rank(), .ch_count(), .ch_valid(), .ch_cur(), .ch_prev(),
    .ch_next());

reg  [3:0] aud_track;
reg  [4:0] sp_track;
integer ti;
always @* begin                        // emu.sv's pick: the lowest declared substream
    aud_track = 4'd0;
    for (ti = 15; ti >= 0; ti = ti - 1) if (aud_present[ti]) aud_track = ti[3:0];
    sp_track = 5'd0;
    for (ti = 31; ti >= 0; ti = ti - 1) if (sub_present[ti]) sp_track = ti[4:0];
end

// ready one cycle in four: slower than the reader's one byte per two clocks, so the FIFO
// really fills and the reader really has to honour busy (at 2 in 3 it never filled)
reg vid_ready = 1'b0, aud_ready = 1'b0;
always @(posedge clk) begin
    vid_ready <= ($unsigned($random(seed)) % 4) == 0;
    aud_ready <= ($unsigned($random(seed)) % 4) == 0;
end

wire [7:0] f_byte, vid_byte;
wire       f_valid, f_ready, vid_valid, aud_valid, sp_valid, pes_hdr_ok;
ps_stream_fifo fifo (
    .clk(clk), .rst_n(rst_n), .wr_data(stream_data), .wr_en(stream_valid),
    .almost_full(stream_busy), .out_byte(f_byte), .out_valid(f_valid), .out_ready(f_ready));
ps_demux dmx (
    .clk(clk), .rst_n(rst_n & ~start), .in_byte(f_byte), .in_ep(2'd0), .in_valid(f_valid), .in_ready(f_ready),
    .aud_track(aud_track), .aud_realign(1'b0), .sp_track(sp_track),
    .sp_enable(sub_present != 32'd0), .vid_byte(vid_byte), .vid_valid(vid_valid),
    .vid_ready(vid_ready), .vid_mark(), .aud_byte(), .aud_valid(aud_valid), .aud_frame_start(),
    .aud_ready(aud_ready), .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
    .aud_frame_pts(), .aud_frame_pts_valid(), .sp_byte(), .sp_valid(sp_valid),
    .sp_frame_start(), .sp_pts(), .sp_pts_valid(), .pes_hdr_ok(pes_hdr_ok), .aud_ss_seen(),
    .aud_ss_id(), .aud_pes_hit(), .saw_pack());

wire [31:0] vb, ab, sb, crc;
wire        crc_done;
es_probe #(.CRC_BYTES(65536), .SEC_CYCLES(27_000_000)) probe (
    .clk(clk), .rst_n(rst_n), .clear(start), .vid_byte(vid_byte),
    .vid_take(vid_valid && vid_ready), .aud_take(aud_valid && aud_ready), .sub_take(sp_valid), .pes_hdr_ok(pes_hdr_ok),
    .vid_bytes(vb), .aud_bytes(ab), .sub_bytes(sb), .vid_crc(crc), .crc_done(crc_done),
    .pes_rate());

initial begin : main
    integer t;
    if (!$value$plusargs("stem=%s", stem) || !$value$plusargs("golden=%s", gstem)) begin
        $display("FAIL [harness] need +stem and +golden"); $fatal(1);
    end
    $readmemh({stem, ".meta.hex"}, meta);
    n_sec = meta[0]; n_reg = meta[1]; n_sseq = meta[2];
    if (n_sec > MAXSEC) begin $display("FAIL [harness] fixture too large"); $fatal(1); end
    $readmemh({stem, ".hex"}, img, 0, n_sec * 2048 - 1);
    $readmemh({stem, ".lba.hex"}, lbas, 0, n_sec - 1);
    $readmemh({stem, ".reg.hex"}, regw, 0, RW * n_reg - 1);
    if (n_sseq > 0) $readmemh({stem, ".sseq.hex"}, sseq, 0, n_sseq - 1);
    $readmemh({gstem, ".dmeta.hex"}, dm);
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    @(posedge clk) start <= 1'b1;
    @(posedge clk) start <= 1'b0;
    // Until every fixture pack has LEFT the reader's cache: it buffers at most 7 whole
    // sectors (+1 in flight), so once n_sseq + 9 sectors were read the fixture's packs
    // are downstream -- or until a complete title finished. (n_sseq + 2 was tried first:
    // at a one-in-four ready rate the cached tail had not drained, and the counts came
    // up short on every real disc.)
    t = 0;
    while (rd_secs < n_sseq + 9 && !rd_done && rd_err == 4'd0 && t < 60_000_000) begin @(posedge clk); t = t + 1; end
    repeat (20000) @(posedge clk);
    if (rd_err !== 4'd0) `FAIL("chain", $sformatf("reader err_code %0d", rd_err))
    if (rd_secs < n_sseq) `FAIL("chain", $sformatf("only %0d of %0d packs streamed", rd_secs, n_sseq))
    if (vb !== dm[1] || ab !== dm[3] || sb !== dm[5])
        `FAIL("chain", $sformatf("bytes video %0d audio %0d sub %0d, want %0d %0d %0d (audio 0x%02x sub %0d)",
                                 vb, ab, sb, dm[1], dm[3], dm[5], aud_track, sp_track))
    if (crc !== dm[12] || crc_done !== (dm[13] == 65536))
        `FAIL("chain", $sformatf("video CRC %08x done %0d, want %08x", crc, crc_done, dm[12]))
    $display("p2_chain_tb: %0d packs -> video %0d B (CRC %08x), audio 0x%02x %0d B, subtitle %0d B",
             n_sseq, vb, crc, aud_track, ab, sb);
    $display("PASS: p2_chain_tb");
    $finish;
end

endmodule
