// bench/umd/p3_chain_tb.sv -- the P3 chain as emu composes it: a reader-shaped byte
// pusher -> ps_stream_fifo -> ps_demux (clk_sys) -> vidfeed_cdc -> h264_top (clk_dec),
// with es_probe beside the demux, the front end's reset through cdc_reset, the
// counters back through cdc_snap, and the end-of-title flush from the reader's
// title_done -- scored against tools/p3_chain_golden.py (docs/h264_frontend.md S6).
//
// +stem=<path>: <stem>.ps.hex (the packs), .se.hex / .meta.hex (the front end's golden,
// tools/h264_top_golden.py's format), .dmeta.hex (the demux golden), .cmeta.hex (pack
// bytes, the tracks). +stall=1: a random-ready SE sink, so the front end stalls, the
// CDC FIFO fills, the demux waits and the pusher has to honour busy -- the whole
// backpressure path, which the runner requires to have been exercised. +dec_ps=N:
// clk_dec's period in ps (12346 = 81 MHz; the runner also runs a non-integer ratio).
//
//   [se]     every SE word equals the model's, in order (`!==`); the count matches
//            (a partial fixture -- a disc cut mid-NAL -- scores the whole NAL units)
//   [count]  nal / slice / picture / SPS / PPS counters equal the model's
//   [err]    err_count equals meta[9] (0; 1 for the cut unit of a partial fixture)
//   [refuse] no refusal (a refused stream is not a chain fixture)
//   [probe]  es_probe's video / audio / subtitle byte counts and the video CRC equal
//            the demux golden: the bytes reached the sinks exactly once each
//   [flush]  the flush pulse comes >= FLUSH_IDLE clk_dec cycles after title_done, and
//            within 100000; without it the last NAL unit never decodes
//   [snap]   every cdc_snap copy of slice_count is >= the previous copy and <= the live
//            counter, and the final copies equal the counters
//   [hang]   an SE word within 400000 clk_dec cycles of the previous while busy
//   [idle]   the chain returns to idle after the flush
//   [range]  with +stall=1 the CDC FIFO stalled the demux at least once, and the
//            demux stalled the pusher at least once (else the arm tested nothing)
// PASS marker: "PASS: p3_chain_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module p3_chain_tb;

localparam MAXPS = 1 << 20;                // 512 packs
localparam MAXS  = 1 << 23;
localparam FLUSH_IDLE = 4096;

reg clk_sys = 1'b0;
always #18.5185 clk_sys = ~clk_sys;        // 27 MHz
real dec_half = 6.173;
reg clk_dec = 1'b0;
always #(dec_half) clk_dec = ~clk_dec;     // 81 MHz unless +dec_ps

reg rst_n = 1'b0;
reg start = 1'b0;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- fixture ---------------------------------------------------------------------------
reg  [7:0]  ps_m [0:MAXPS-1];
reg  [47:0] se_m [0:MAXS-1];
reg  [31:0] meta [0:31];
reg  [31:0] dm   [0:15];
reg  [31:0] cm   [0:3];
string  stem;
integer stall = 0, dec_ps, n_ps, n_se, partial = 0, seed_v;
reg  [3:0] aud_track;
reg  [4:0] sp_track;
reg        sp_enable;

// ---- emu's front-end reset: a 16-cycle stretch of the mount pulse, released into clk_dec ----
reg [3:0] fe_clr_cnt = 4'd0;
always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n)                  fe_clr_cnt <= 4'd0;
    else if (start)              fe_clr_cnt <= 4'd15;
    else if (fe_clr_cnt != 4'd0) fe_clr_cnt <= fe_clr_cnt - 4'd1;
end
wire fe_rst_n = rst_n & (fe_clr_cnt == 4'd0);
wire fe_rst_dec_n;
cdc_reset fe_rst_cdc (.clk(clk_dec), .rst_n_in(fe_rst_n), .rst_n_out(fe_rst_dec_n));

// ---- the pusher: umd_reader's shape, one byte per two clocks, busy read combinationally ----
reg  [7:0] stream_data = 8'd0;
reg        stream_valid = 1'b0;
wire       stream_busy;
integer    pi = 0, busy_cyc = 0;
reg        feed_on = 1'b0, title_done = 1'b0;
always @(posedge clk_sys) begin
    stream_valid <= 1'b0;
    if (feed_on && pi < n_ps) begin
        if (stream_busy) busy_cyc <= busy_cyc + 1;
        else if (!stream_valid) begin stream_data <= ps_m[pi]; stream_valid <= 1'b1; pi <= pi + 1; end
    end
end

// ---- the chain ---------------------------------------------------------------------------
wire  [7:0] dmx_in_byte, vid_byte, aud_byte, sp_byte;
wire        dmx_in_valid, dmx_in_ready, vid_valid, vid_ready, vid_mark, aud_valid, sp_valid, pes_hdr_ok;
wire [32:0] vid_pts;
ps_stream_fifo fifo (
    .clk(clk_sys), .rst_n(rst_n), .wr_data(stream_data), .wr_en(stream_valid),
    .almost_full(stream_busy), .out_byte(dmx_in_byte), .out_valid(dmx_in_valid), .out_ready(dmx_in_ready));
ps_demux dmx (
    .clk(clk_sys), .rst_n(rst_n & ~start), .in_byte(dmx_in_byte), .in_ep(2'd0), .in_valid(dmx_in_valid), .in_ready(dmx_in_ready),
    .aud_track(aud_track), .aud_realign(1'b0), .sp_track(sp_track), .sp_enable(sp_enable),
    .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready), .vid_mark(vid_mark),
    .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_frame_start(), .aud_ready(1'b1),
    .vid_pts(vid_pts), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(), .aud_frame_pts(), .aud_frame_pts_valid(),
    .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
    .pes_hdr_ok(pes_hdr_ok), .aud_ss_seen(), .aud_ss_id(), .aud_pes_hit(), .saw_pack());

wire [31:0] vb, ab, sb, crc;
wire        crc_done;
es_probe #(.CRC_BYTES(65536), .SEC_CYCLES(27_000_000)) probe (
    .clk(clk_sys), .rst_n(rst_n), .clear(start), .vid_byte(vid_byte),
    .vid_take(vid_valid && vid_ready), .aud_take(aud_valid), .sub_take(sp_valid), .pes_hdr_ok(pes_hdr_ok),
    .vid_bytes(vb), .aud_bytes(ab), .sub_bytes(sb), .vid_crc(crc), .crc_done(crc_done), .pes_rate());

wire [41:0] es_data;                        // {pts, mark, byte}: emu's P5c crossing
wire       es_valid, es_ready, es_flush, fe_flushed;
vidfeed_cdc #(.FLUSH_IDLE(FLUSH_IDLE), .DW(42)) cdc (
    .wr_clk(clk_sys), .wr_rst_n(fe_rst_n), .wr_data({vid_pts, vid_mark, vid_byte}), .wr_valid(vid_valid),
    .wr_ready(vid_ready), .wr_flush(title_done),
    .rd_clk(clk_dec), .rd_rst_n(fe_rst_dec_n), .rd_data(es_data), .rd_valid(es_valid), .rd_ready(es_ready),
    .rd_flush(es_flush), .rd_flushed(fe_flushed));

wire        se_valid;
reg         se_ready = 1'b1;
wire [7:0]  se_kind, se_aux;
wire [31:0] se_val;
wire        busy;
wire [31:0] nal_count, slice_count, pic_count, sps_count, pps_count, refused_count, err_count;
wire [3:0]  refused_code, err_code;
wire [39:0] bin_total;
wire [31:0] pt_seen, pt_missing, pt_bad, sei_err, pts_tag, pts_drop;
h264_top fe (
    .clk(clk_dec), .rst_n(fe_rst_dec_n), .ps_rst_n(fe_rst_dec_n), .clear(1'b0),
    .es_byte(es_data[7:0]), .es_valid(es_valid), .es_ready(es_ready), .es_flush(es_flush),
    .es_mark(es_data[8]), .es_pts(es_data[41:9]), .es_ep(2'd0), .one_frame(1'b0),
    .se_valid(se_valid), .se_ready(se_ready), .se_kind(se_kind), .se_aux(se_aux), .se_val(se_val),
    .sp_pps(), .sp_sps(), .sp_slice_type(), .sp_field(), .sp_bottom(), .sp_idr(), .sp_frame_num(), .sp_poc_lsb(),
    .busy(busy), .nal_count(nal_count), .slice_count(slice_count), .pic_count(pic_count),
    .sps_count(sps_count), .pps_count(pps_count), .refused_count(refused_count), .refused_code(refused_code),
    .err_count(err_count), .err_code(err_code), .bin_total(bin_total),
    .pt_seen_count(pt_seen), .pt_missing_count(pt_missing), .pt_bad_count(pt_bad), .sei_err_count(sei_err),
    .pts_tag_count(pts_tag), .pts_drop_count(pts_drop), .last_pic_struct());

reg [31:0] se_words = 32'd0;
always @(posedge clk_dec or negedge fe_rst_dec_n)
    if (!fe_rst_dec_n) se_words <= 32'd0; else if (se_valid && se_ready) se_words <= se_words + 32'd1;

wire [32*5:0] snap;
wire          snap_tick;
wire [31:0]   sn_nal, sn_slice, sn_pic, sn_err, sn_se;
wire          sn_flushed;
cdc_snap #(.W(32*5+1)) snapper (
    .src_clk(clk_dec), .src_rst_n(fe_rst_dec_n), .src_data({nal_count, slice_count, pic_count, err_count, se_words, fe_flushed}),
    .dst_clk(clk_sys), .dst_rst_n(rst_n), .dst_data(snap), .dst_tick(snap_tick));
assign {sn_nal, sn_slice, sn_pic, sn_err, sn_se, sn_flushed} = snap;

// ---- scoring --------------------------------------------------------------------------------
integer si = 0, idle_cyc = 0, nal_seen = 0, mb_seen = 0;
reg [47:0] want;
always @(posedge clk_dec) if (rst_n) begin
    se_ready <= (stall == 0) ? 1'b1 : (($urandom % 3) != 0);
    if (se_valid && se_ready) begin
        idle_cyc <= 0;
        want = se_m[si];
        if (partial && si >= n_se) ;
        else if ({se_kind, se_aux, se_val} !== want)
            `FAIL("se", $sformatf("word %0d: got kind %0d aux %0d val %0d, want kind %0d aux %0d val %0d (NAL unit %0d, %0d macroblocks)",
                                  si, se_kind, se_aux, $signed(se_val), want[47:40], want[39:32], $signed(want[31:0]), nal_seen, mb_seen))
        if (se_kind == 8'd17) nal_seen <= nal_seen + 1;
        if (se_kind == 8'd1) mb_seen <= mb_seen + 1;
        si <= si + 1;
    end else if (busy) begin
        idle_cyc <= idle_cyc + 1;
        if (idle_cyc > 400000) `FAIL("hang", $sformatf("no SE word for 400000 cycles after word %0d (NAL unit %0d)", si, nal_seen))
    end
end

integer stall_cyc = 0, snaps = 0;
reg [31:0] sn_prev = 32'd0;
always @(posedge clk_sys) if (rst_n) begin
    if (vid_valid && !vid_ready) stall_cyc <= stall_cyc + 1;
    if (snap_tick) begin
        snaps <= snaps + 1;
        if (sn_slice < sn_prev) `FAIL("snap", $sformatf("slice copy went backwards: %0d after %0d", sn_slice, sn_prev))
        if (sn_slice > slice_count) `FAIL("snap", $sformatf("slice copy %0d ahead of the counter %0d", sn_slice, slice_count))
        sn_prev <= sn_slice;
    end
end

integer t_done, t_flush = -1, k;
always @(posedge clk_dec) if (es_flush && t_flush < 0) t_flush = $time;

initial begin
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "no +stem")
    if (!$value$plusargs("stall=%d", stall)) stall = 0;
    if ($value$plusargs("dec_ps=%d", dec_ps)) dec_half = dec_ps / 2000.0;
    seed_v = stall + 11; k = $urandom(seed_v);
    $readmemh({stem, ".meta.hex"}, meta);
    $readmemh({stem, ".dmeta.hex"}, dm);
    $readmemh({stem, ".cmeta.hex"}, cm);
    n_ps = cm[0]; n_se = meta[1]; partial = (meta[11] === 32'd1);
    aud_track = cm[1][3:0]; sp_track = (cm[2] == 32'hFF) ? 5'd0 : cm[2][4:0]; sp_enable = (cm[2] != 32'hFF);
    if (n_ps > MAXPS || n_se > MAXS) `FAIL("harness", "fixture too large")
    $readmemh({stem, ".ps.hex"}, ps_m, 0, n_ps - 1);
    if (n_se > 0) $readmemh({stem, ".se.hex"}, se_m, 0, n_se - 1);

    repeat (5) @(posedge clk_sys);
    rst_n = 1'b1;
    repeat (5) @(posedge clk_sys);
    @(posedge clk_sys) start <= 1'b1;
    @(posedge clk_sys) start <= 1'b0;
    repeat (40) @(posedge clk_sys);            // the reset stretch, as a real image walk would cover
    feed_on = 1'b1;
    k = 0;
    while (pi < n_ps) begin @(posedge clk_sys); k = k + 1; if (k > 100_000_000) `FAIL("hang", "the packs were never consumed") end
    @(posedge clk_sys); #1;
    title_done = 1'b1;                         // umd_reader's level: every byte pushed
    t_done = $time;
    k = 0;
    // the flush comes FLUSH_IDLE cycles after the last byte drained (a few thousand at
    // most): this wait must stay well inside the [hang] budget, or a missing flush lands
    // in the wrong arm
    while (!fe_flushed) begin @(posedge clk_dec); k = k + 1; if (k > 100_000) `FAIL("flush", "no flush pulse within 100000 cycles of title_done") end
    if ((t_flush - t_done) / (2 * dec_half) < FLUSH_IDLE)
        `FAIL("flush", $sformatf("the flush came %0d clk_dec cycles after title_done, before FLUSH_IDLE (%0d) quiet cycles",
                                 (t_flush - t_done) / (2 * dec_half), FLUSH_IDLE))
    k = 0;
    while (busy || (si < n_se && !partial)) begin @(posedge clk_dec); k = k + 1; if (k > 40_000_000) `FAIL("hang", $sformatf("never idle: %0d of %0d words", si, n_se)) end
    repeat (200) @(posedge clk_sys);           // the snapshot's last round trips
    if (busy) `FAIL("idle", "busy after the flush")
    if (partial ? (si < n_se) : (si !== n_se)) `FAIL("se", $sformatf("%0d SE words emitted, %0d expected", si, n_se))
    if (nal_count !== meta[2] || slice_count !== meta[3] || pic_count !== meta[4] || sps_count !== meta[5] || pps_count !== meta[6])
        `FAIL("count", $sformatf("nal %0d/%0d slices %0d/%0d pics %0d/%0d sps %0d/%0d pps %0d/%0d (got/want)",
                                 nal_count, meta[2], slice_count, meta[3], pic_count, meta[4], sps_count, meta[5], pps_count, meta[6]))
    if (refused_count !== 32'd0) `FAIL("refuse", $sformatf("refused %0d code %0d", refused_count, refused_code))
    if (err_count !== meta[9]) `FAIL("err", $sformatf("err_count %0d (code %0d), want %0d", err_count, err_code, meta[9]))
    // P5c: the picture timing / PTS counters (scored on a complete fixture only)
    if (meta[12] !== 32'hFFFFFFFF && {pt_seen, pt_missing, pt_bad, sei_err, pts_tag, pts_drop} !==
                                      {meta[12], meta[13], meta[14], meta[15], meta[16], meta[17]})
        `FAIL("p5c", $sformatf("pic_timing %0d/%0d missing %0d/%0d bad %0d/%0d malformed SEI %0d/%0d PTS tagged %0d/%0d dropped %0d/%0d (got/want)",
                               pt_seen, meta[12], pt_missing, meta[13], pt_bad, meta[14], sei_err, meta[15], pts_tag, meta[16], pts_drop, meta[17]))
    if (vb !== dm[1] || ab !== dm[3] || sb !== dm[5])
        `FAIL("probe", $sformatf("bytes video %0d audio %0d sub %0d, want %0d %0d %0d", vb, ab, sb, dm[1], dm[3], dm[5]))
    if (crc !== dm[12] || crc_done !== (dm[13] == 65536))
        `FAIL("probe", $sformatf("video CRC %08x done %0d, want %08x", crc, crc_done, dm[12]))
    if (sn_nal !== nal_count || sn_slice !== slice_count || sn_pic !== pic_count || sn_err !== err_count ||
        sn_se !== se_words || sn_flushed !== 1'b1 || snaps == 0)
        `FAIL("snap", $sformatf("final copies nal %0d slice %0d pic %0d err %0d se %0d flushed %0d (%0d copies), counters %0d %0d %0d %0d %0d",
                                sn_nal, sn_slice, sn_pic, sn_err, sn_se, sn_flushed, snaps, nal_count, slice_count, pic_count, err_count, se_words))
    if (stall != 0 && (stall_cyc == 0 || busy_cyc == 0))
        `FAIL("range", $sformatf("+stall exercised nothing: the CDC FIFO stalled the demux %0d cycles, the demux stalled the pusher %0d", stall_cyc, busy_cyc))
    $display("p3_chain_tb: %0s: %0d packs -> video %0d B (CRC %08x), %0d NAL units, %0d slices, %0d SE words, errors %0d; the demux waited %0d cycles on the front end, the pusher %0d on the demux; flush %0d cycles after title_done; %0d snapshots",
             stem, n_ps / 2048, vb, crc, nal_count, slice_count, si, err_count, stall_cyc, busy_cyc, (t_flush - t_done) / (2 * dec_half), snaps);
    $display("PASS: p3_chain_tb");
    $finish;
end

endmodule
