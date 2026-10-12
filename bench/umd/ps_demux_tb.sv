// bench/umd/ps_demux_tb.sv -- ps_stream_fifo + ps_demux against psmf_ref goldens
//
// +stem=<path>: <stem>.hex is a program stream (an umd_fixture.py pack cut of a real
// clip, or a tools/umd_demux_cases.py stream); tools/psmf_golden.py wrote the goldens
// beside it (.vid/.vmk/.aud/.amk/.sub/.smk/.dmeta). Bytes are fed the way umd_reader
// feeds them: single-cycle stream_valid pulses throttled by a registered busy
// (ps_stream_fifo's almost_full), and video/audio are backpressured at random.
//
//   [video]   every video ES byte, in order (`!==`), and nothing more
//   [vmark]   vid_mark exactly on the first payload byte of each video PES with a PTS,
//             with vid_pts equal to that PES's PTS
//   [audio]   the selected track's bytes from its first access unit, and nothing more
//   [amark]   aud_frame_start on each PES's first forwarded byte, with its PTS/valid
//   [sub]     the selected subtitle track's bytes and PES starts (PTS/valid)
//   [ep]      (P6b3i) every video PTS leaves with the item tag of the sector its PES header
//             was in (the bench tags each input byte with its sector index mod 4), checked
//             where the consumer reads it: the video's at its marked byte (the vbuf's stamp),
//             the audio's at its PES's first forwarded byte (the ring's tag). (A first cut
//             checked the cycle after the latch, the one cycle a tag cleared every cycle is
//             right: it let exactly that bug through to the rig)
//   [stats]   pes_hdr_ok / aud_ss_seen / aud_pes_hit counts, saw_pack
//   [taps]    (P8) sub_ss_seen's count, and the audio / subtitle ids the two taps named, as masks
//             (a bare stream file's tracks are learned from them: docs/bare_streams.md)
//   [probe]   es_probe on the same outputs: byte counts, the zlib CRC-32 of the first
//             64 KiB of video ES (crc_done iff the window holds that many), and the
//             per-"second" pes_hdr_ok rate against the bench's own window count
//
// PASS marker: "PASS: ps_demux_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module ps_demux_tb;

localparam MAXIN = 1 << 21;
localparam MAXMK = 1 << 14;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

// ---- fixture ------------------------------------------------------------------------
reg  [7:0] inb  [0:MAXIN-1];
reg  [7:0] gvid [0:MAXIN-1];
reg  [7:0] gaud [0:MAXIN-1];
reg  [7:0] gsub [0:MAXIN-1];
reg [31:0] vmk  [0:3*MAXMK-1];
reg [31:0] amk  [0:3*MAXMK-1];
reg [31:0] smk  [0:3*MAXMK-1];
reg [31:0] dm   [0:31];
localparam PROBE_SEC = 3;         // tiny on purpose: a third of the pulses land on a window's last cycle
string  stem;
integer n_in, n_vid, n_vmk, n_aud, n_amk, n_sub, n_smk, seed = 7;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

// ---- DUT: the emu chain's front ----------------------------------------------------
reg  [7:0] src_byte = 8'd0;
reg  [1:0] src_ep = 2'd0;
wire [1:0] f_ep, vid_ep, aud_ep;
reg  [1:0] take_ep = 2'd0;             // the tag of the byte the demux took last
reg        src_valid = 1'b0;
wire       fifo_af;
wire [7:0] f_byte;
wire       f_valid, f_ready;
ps_stream_fifo #(.DW(10)) fifo (
    .clk(clk), .rst_n(rst_n), .wr_data({src_ep, src_byte}), .wr_en(src_valid),
    .almost_full(fifo_af), .out_byte({f_ep, f_byte}), .out_valid(f_valid), .out_ready(f_ready));

reg        vid_ready = 1'b0, aud_ready = 1'b0;
reg  [3:0] aud_track = 4'd0;
reg  [4:0] sp_track = 5'd0;
reg        sp_enable = 1'b0;
wire [7:0] vid_byte, aud_byte, sp_byte;
wire       vid_valid, vid_mark, aud_valid, aud_frame_start, sp_valid, sp_frame_start;
wire [32:0] vid_pts, aud_pts, aud_frame_pts, sp_pts;
wire       vid_pts_valid, aud_pts_valid, aud_frame_pts_valid, sp_pts_valid;
wire       pes_hdr_ok, aud_ss_seen, aud_pes_hit, saw_pack;
wire [3:0] aud_ss_id;
wire       sub_ss_seen;                // P8
wire [4:0] sub_ss_id;
integer    c_sseen = 0;
reg [15:0] m_aud = 16'd0;
reg [31:0] m_sub = 32'd0;
ps_demux dut (
    .clk(clk), .rst_n(rst_n), .in_byte(f_byte), .in_ep(f_ep), .in_valid(f_valid), .in_ready(f_ready), .vid_ep(vid_ep), .aud_frame_ep(aud_ep),
    .aud_track(aud_track), .aud_realign(1'b0), .sp_track(sp_track), .sp_enable(sp_enable),
    .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready), .vid_mark(vid_mark),
    .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_frame_start(aud_frame_start),
    .aud_ready(aud_ready), .vid_pts(vid_pts), .vid_pts_valid(vid_pts_valid),
    .aud_pts(aud_pts), .aud_pts_valid(aud_pts_valid), .aud_frame_pts(aud_frame_pts),
    .aud_frame_pts_valid(aud_frame_pts_valid), .sp_byte(sp_byte), .sp_valid(sp_valid),
    .sp_frame_start(sp_frame_start), .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
    .pes_hdr_ok(pes_hdr_ok), .aud_ss_seen(aud_ss_seen), .aud_ss_id(aud_ss_id),
    .sub_ss_seen(sub_ss_seen), .sub_ss_id(sub_ss_id),
    .aud_pes_hit(aud_pes_hit), .saw_pack(saw_pack));

wire [31:0] p_vb, p_ab, p_sb, p_crc;
wire        p_done;
wire [15:0] p_rate;
es_probe #(.CRC_BYTES(65536), .SEC_CYCLES(PROBE_SEC)) probe (
    .clk(clk), .rst_n(rst_n), .clear(1'b0), .vid_byte(vid_byte),
    .vid_take(vid_valid && vid_ready), .aud_take(aud_valid && aud_ready), .sub_take(sp_valid),
    .pes_hdr_ok(pes_hdr_ok), .vid_bytes(p_vb), .aud_bytes(p_ab), .sub_bytes(p_sb),
    .vid_crc(p_crc), .crc_done(p_done), .pes_rate(p_rate));

// the rate, modelled from its definition: pes_hdr_ok pulses per PROBE_SEC-cycle window
integer w_cyc = 0, w_cnt = 0, w_last = -1;
always @(posedge clk) if (rst_n) begin
    if (w_last >= 0 && p_rate !== w_last[15:0])
        `FAIL("probe", $sformatf("pes_rate %0d, want %0d", p_rate, w_last))
    if (w_cyc == PROBE_SEC - 1) begin
        w_last = w_cnt + pes_hdr_ok; w_cnt = 0; w_cyc = 0;
    end else begin
        w_cnt = w_cnt + pes_hdr_ok; w_cyc = w_cyc + 1;
    end
end

// ---- source: umd_reader's output shape (pulse valid, registered busy) ---------------
integer ip = 0;
reg busy_q = 1'b0;
always @(posedge clk) begin
    busy_q    <= fifo_af;
    src_valid <= 1'b0;
    if (rst_n && !busy_q && ip < n_in && ($unsigned($random(seed)) % 3) != 0) begin
        src_byte  <= inb[ip];
        src_ep    <= ip[12:11];
        src_valid <= 1'b1;
        ip = ip + 1;
    end
    vid_ready <= ($unsigned($random(seed)) % 5) != 0;
    aud_ready <= ($unsigned($random(seed)) % 4) != 0;
end

// ---- scoring ------------------------------------------------------------------------
integer nv = 0, kv = 0, na = 0, ka = 0, ns = 0, ks = 0;
integer c_hdr = 0, c_seen = 0, c_hit = 0;
always @(posedge clk) if (rst_n) begin
    if (vid_valid && vid_ready) begin
        if (nv >= n_vid) `FAIL("video", $sformatf("extra video byte %02x at %0d", vid_byte, nv))
        if (vid_byte !== gvid[nv])
            `FAIL("video", $sformatf("video byte %0d is %02x, want %02x", nv, vid_byte, gvid[nv]))
        if (kv < n_vmk && vmk[3*kv] == nv) begin
            if (!vid_mark) `FAIL("vmark", $sformatf("no vid_mark at video byte %0d", nv))
            if (vid_pts !== {vmk[3*kv+2][0], vmk[3*kv+1]})
                `FAIL("vmark", $sformatf("vid_pts %0d at byte %0d, want %0d", vid_pts, nv, {vmk[3*kv+2][0], vmk[3*kv+1]}))
            kv = kv + 1;
        end else if (vid_mark)
            `FAIL("vmark", $sformatf("vid_mark at video byte %0d, not a PTS PES start", nv))
        nv = nv + 1;
    end
    if (aud_valid && aud_ready) begin
        if (na >= n_aud) `FAIL("audio", $sformatf("extra audio byte %02x at %0d", aud_byte, na))
        if (aud_byte !== gaud[na])
            `FAIL("audio", $sformatf("audio byte %0d is %02x, want %02x", na, aud_byte, gaud[na]))
        if (ka < n_amk && amk[3*ka] == na) begin
            if (!aud_frame_start) `FAIL("amark", $sformatf("no aud_frame_start at audio byte %0d", na))
            if (aud_frame_pts_valid !== amk[3*ka+2][1] ||
                (amk[3*ka+2][1] && aud_frame_pts !== {amk[3*ka+2][0], amk[3*ka+1]}))
                `FAIL("amark", $sformatf("audio byte %0d: pts %0d valid %0d, want %0d valid %0d", na,
                                         aud_frame_pts, aud_frame_pts_valid, {amk[3*ka+2][0], amk[3*ka+1]}, amk[3*ka+2][1]))
            ka = ka + 1;
        end else if (aud_frame_start)
            `FAIL("amark", $sformatf("aud_frame_start at audio byte %0d, not a PES start", na))
        na = na + 1;
    end
    if (sp_valid) begin
        if (ns >= n_sub) `FAIL("sub", $sformatf("extra subtitle byte %02x at %0d", sp_byte, ns))
        if (sp_byte !== gsub[ns])
            `FAIL("sub", $sformatf("subtitle byte %0d is %02x, want %02x", ns, sp_byte, gsub[ns]))
        if (ks < n_smk && smk[3*ks] == ns) begin
            if (!sp_frame_start) `FAIL("sub", $sformatf("no sp_frame_start at subtitle byte %0d", ns))
            if (sp_pts_valid !== smk[3*ks+2][1] ||
                (smk[3*ks+2][1] && sp_pts !== {smk[3*ks+2][0], smk[3*ks+1]}))
                `FAIL("sub", $sformatf("subtitle byte %0d: pts %0d valid %0d", ns, sp_pts, sp_pts_valid))
            ks = ks + 1;
        end else if (sp_frame_start)
            `FAIL("sub", $sformatf("sp_frame_start at subtitle byte %0d, not a PES start", ns))
        ns = ns + 1;
    end
    // [ep]: vid_pts_valid pulses the cycle after the last PTS byte was taken
    if (vid_valid && vid_mark && vid_ep !== take_ep)
        `FAIL("ep", $sformatf("a video mark left with item tag %0d, its PES's sector is tagged %0d", vid_ep, take_ep))
    if (aud_frame_start && aud_frame_pts_valid && aud_ep !== take_ep)
        `FAIL("ep", $sformatf("an audio frame start left with item tag %0d, its PES's sector is tagged %0d", aud_ep, take_ep))
    if (f_valid && f_ready) take_ep <= f_ep;
    c_hdr  = c_hdr  + pes_hdr_ok;
    c_seen = c_seen + aud_ss_seen;
    c_sseen = c_sseen + sub_ss_seen;
    if (aud_ss_seen) m_aud[aud_ss_id] = 1'b1;
    if (sub_ss_seen) m_sub[sub_ss_id] = 1'b1;
    c_hit  = c_hit  + aud_pes_hit;
end

initial begin : main
    integer t;
    if (!$value$plusargs("stem=%s", stem)) begin $display("FAIL [harness] no +stem"); $fatal(1); end
    $readmemh({stem, ".dmeta.hex"}, dm);
    n_in = dm[0]; n_vid = dm[1]; n_vmk = dm[2]; n_aud = dm[3]; n_amk = dm[4]; n_sub = dm[5]; n_smk = dm[6];
    if (n_in > MAXIN || n_vmk > MAXMK || n_amk > MAXMK || n_smk > MAXMK) begin
        $display("FAIL [harness] fixture too large"); $fatal(1);
    end
    $readmemh({stem, ".hex"}, inb, 0, n_in - 1);
    if (n_vid) $readmemh({stem, ".vid.hex"}, gvid, 0, n_vid - 1);
    if (n_aud) $readmemh({stem, ".aud.hex"}, gaud, 0, n_aud - 1);
    if (n_sub) $readmemh({stem, ".sub.hex"}, gsub, 0, n_sub - 1);
    if (n_vmk) $readmemh({stem, ".vmk.hex"}, vmk, 0, 3 * n_vmk - 1);
    if (n_amk) $readmemh({stem, ".amk.hex"}, amk, 0, 3 * n_amk - 1);
    if (n_smk) $readmemh({stem, ".smk.hex"}, smk, 0, 3 * n_smk - 1);
    aud_track = dm[7][3:0];
    sp_enable = (dm[8] != 32'hFF);
    sp_track  = dm[8][4:0];
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    t = 0;
    while ((ip < n_in || f_valid) && t < 20 * n_in + 1000) begin @(posedge clk); t = t + 1; end
    if (ip < n_in || f_valid) begin $display("FAIL [harness] stream stalled at input byte %0d", ip); $fatal(1); end
    repeat (50) @(posedge clk);
    if (nv != n_vid) `FAIL("video", $sformatf("%0d video bytes, want %0d", nv, n_vid))
    if (kv != n_vmk) `FAIL("vmark", $sformatf("%0d video marks, want %0d", kv, n_vmk))
    if (na != n_aud) `FAIL("audio", $sformatf("%0d audio bytes, want %0d", na, n_aud))
    if (ka != n_amk) `FAIL("amark", $sformatf("%0d audio frame starts, want %0d", ka, n_amk))
    if (ns != n_sub || ks != n_smk) `FAIL("sub", $sformatf("%0d subtitle bytes / %0d starts, want %0d / %0d", ns, ks, n_sub, n_smk))
    if (c_hdr != dm[9] || c_seen != dm[10] || c_hit != dm[11] || saw_pack !== 1'b1)
        `FAIL("stats", $sformatf("pes_hdr_ok %0d aud_ss_seen %0d aud_pes_hit %0d saw_pack %0d, want %0d %0d %0d 1",
                                 c_hdr, c_seen, c_hit, saw_pack, dm[9], dm[10], dm[11]))
    if (c_sseen != dm[14] || m_aud !== dm[15][15:0] || m_sub !== dm[16])
        `FAIL("taps", $sformatf("sub_ss_seen %0d, audio ids %04x, subtitle ids %08x, want %0d %04x %08x",
                                c_sseen, m_aud, m_sub, dm[14], dm[15][15:0], dm[16]))
    if (p_vb != n_vid || p_ab != n_aud || p_sb != n_sub)
        `FAIL("probe", $sformatf("byte counts %0d/%0d/%0d, want %0d/%0d/%0d", p_vb, p_ab, p_sb, n_vid, n_aud, n_sub))
    if (p_crc !== dm[12] || p_done !== (dm[13] == 65536))
        `FAIL("probe", $sformatf("video CRC %08x done %0d, want %08x done %0d", p_crc, p_done, dm[12], dm[13] == 65536))
    $display("ps_demux_tb: %0d in -> video %0d B (%0d marks), audio 0x%02x %0d B (%0d starts), subtitle %0d B (%0d starts), %0d packs",
             n_in, nv, kv, aud_track, na, ka, ns, ks, c_hdr);
    $display("PASS: ps_demux_tb");
    $finish;
end

endmodule
