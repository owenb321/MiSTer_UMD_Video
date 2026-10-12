// umd/umd_reader.sv -- in-fabric UMD Video image reader (roadmap P2)
//
// THE NAVIGATION ENGINE (A12, docs/nav_engine.md): everything above that parses -- the ISO9660
// walk, PARAM.SFO, PLAYLIST.UMD, the CLPs, the EP-map lookups, the marks, every navigation
// command and every verdict -- is a PROGRAM (umd/nav/nav.uasm) on a microcoded engine
// (umd/nav/nav_seq.sv); tools/nav_isa.py is its executable definition, and
// bench/umd/run_nav_model.sh scores it on this bench's own fixtures. What stays hardware here:
// the sd handshake, the two sector slots the program's file loads read, the pump (the stream's
// sectors into the 16 KB cache, its stop counters and item tags), the output pipe, the
// navigation take (its acceptance rule and flush ON the accepting edge), item_hold's guard on
// the state write, and the output registers the program writes over its I/O port
// (umd/nav/nav_io.svh, generated). The contract below is unchanged.
//
// Walks a mounted UMD Video .iso over the hps_io sd_* block port and streams the main
// title's MPEG program-stream packs, back to back, into a byte stream (the same
// stream_data / stream_valid / busy contract as block_streamer, which it replaces):
//
//   PVD (LBA 16.., first type-1 descriptor) -> root dir -> UMD_VIDEO/
//     -> PARAM.SFO     TITLE found BY KEY (a third key sits between on 11 of 33 discs),
//                      up to 128 bytes into title_mem (the key's max_len)
//     -> PLAYLIST.UMD  every playlist's duration = sum(OUT - IN) over its items; the
//                      LONGEST wins (first on a tie), NOT playlist 0 (Hero, Kill Bill 2,
//                      The Incredibles put an intro at #0) -- umd_playlist.main_playlist()
//     -> for each item of that playlist, in order:
//          CLIPINF/<clip>.CLP  stream table -> audio/subtitle presence + languages,
//                              video attribute bytes, clip PTS range, ep_map offset
//          STREAM/<clip>.MPS   every extent, streamed sector by sector
//
// The reference walk is tools/umd_fixture.py nav_walk(); goldens are the P1 parsers.
// Format facts: docs/umd_video_format.md. Design notes: docs/umd_reader.md.
//
// Kept from MiSTer_DVD's dvd_iso_reader.sv (docs/harvest.md): the sector read into a
// 2 KB SYNCHRONOUS parse_buf (one M10K), the 45-byte register shadow `rbuf` copied from
// it by a fetch sequencer (all field taps read the shadow, never parse_buf -- async
// multi-offset reads of parse_buf once blew a fit to 226 % ALM), the sector-crossing
// shadow fetch, the 16 KB circular stream cache and its 2-stage output pipe. The walk
// itself is new. Changes to the kept parts:
//   * FETCH_N 45 -> 48: a directory record's name starts at byte 33 and the longest
//     name matched is 8+1+3 chars plus a ";N" version suffix = byte 46.
//   * the shadow fetch never crosses out of the current directory sector (records never
//     straddle, ECMA-119 6.8.1.1) nor past a file's last sector: those bytes read as 0
//     and no stray sector is requested.
//   * one generic name matcher (tname/tlen) instead of a wire per name; a ";N" version
//     suffix is accepted (no surveyed disc carries one, the standard allows it).
//   * the sd handshake runs outside the state case and every request site issues only
//     on !rq_busy && !rq_done, so a start/stop mid-transfer lets the old block land
//     (into a buffer nobody trusts: pb_valid is cleared, wr_ptr reset) before the next
//     request goes out, and its completion is never taken for the new one's.
//
// DESIGN TO THE SPEC MAXIMUM (CLAUDE.md): counts are the fields' own widths -- playlists
// u16, items u32, streams u16, SFO entries u32, file offsets u32 -- and every walk
// terminates because each step moves a u32 offset strictly forward and a fetch at or
// past the file's size is refused (S_OOB). A multi-extent .MPS is followed by resuming
// the STREAM/ directory walk at the next record, so there is no extent table to
// overflow. Two bounds are smaller than the format and are VISIBLE, never silent:
//   * title_trunc: a TITLE longer than 128 bytes keeps its first 128 (128 = the key's
//     max_len on every disc; 55 bytes is the longest seen).
//   * dur_sat: a playlist duration sum above 2^64 ticks saturates (unreachable: it
//     needs >65536 items of 2^48 ticks each).
// Refused LOUDLY with err_code (never streamed as garbage): no ISO9660 PVD, no
// UMD_VIDEO/, no or malformed PLAYLIST.UMD / CLP, a missing clip, an interleaved
// (file-unit) .MPS, a multi-extent navigation file.
//
// IN / OUT and the navigation port (P6b2, docs/transport.md S2.4, golden
// tools/umd_nav_ref.py): every item start is an EP lookup. The CLP's video EP map (the
// map whose stream_id is 0xE0, searched, never assumed to be map 0) is binary-searched
// twice: the LAST entry at or before the target (IN, or a seek's PTS clamped into
// [IN, OUT): OUT - 1 for a target at or past OUT, P6b4) is where the item starts streaming, and the FIRST entry at or after OUT is
// where it stops (none: the clip's end). The start sector is clip-relative and is found
// through the .MPS extents by the same directory walk that continues a multi-extent
// stream. Commands, one at a time, taken only while nav_ready:
//   NAV_SEEK (item, pts)  atomic: every byte not yet delivered is dropped at the
//       accepting edge (the cache and the output pipe flush, title_done falls), the item
//       record is found, its CLP re-read (the track outputs follow the landed clip),
//       the lookups made, and the stream restarts at the entry. nav_done when the stream
//       starts, with the landing (nav_ep_*) and the clamped target (nav_skip: the display
//       shows from there, D2). A bad item is refused before anything is flushed.
//   NAV_CHAP (item, pts)  a full scan of the main playlist's marks, served between
//       stream sector reads (the stream resumes exactly where it was): the type-5 marks
//       on items that exist, ordered by the key (item, PTS) -- never by table order.
//       rank = how many are at or before the key; cur / prev = the last two of them, next
//       = the first after it. A scan, not a table: 65,535 marks (u16) are ~1,300 sector
//       reads, slow and visible, never truncated.
//   NAV_PLAY (pl, item, pts)  P9 (docs/p9.md S3.2, P9-2): play playlist `pl` from (item, pts)
//       -- a disc menu's movieplayer.play. Atomic like a seek: at the accepting edge every byte
//       not yet delivered is dropped; PLAYLIST.UMD's table is read again with `pl` forced in
//       place of the longest (the items, IN / OUT, marks and pl_dur all follow it), then the
//       seek's item walk lands on (item, pts) and the playlist plays on from there to its own
//       end. A playlist that does not exist is refused with nothing flushed (NE_ITEM, as a
//       seek's missing item); a target item past the chosen playlist's last starts it from
//       its first item at IN, flagged NE_ITEM (its item count is known only once it is read).
//       The playlist stays chosen until the next NAV_PLAY or mount (main_pl reports it).
//   NAV_TIME (pts = a time)  P6c (docs/p6c.md §9, D15 / D16): Go To by time -- a seek whose
//       target is the PLAYING playlist's time in 90 kHz ticks (umd_nav_ref.Title.time_seek).
//       The seek's item walk subtracts each record's OUT - IN from the time until the item
//       whose span holds it ([start, start + OUT - IN): a time on a boundary is the next
//       item's IN; an item of no duration holds none), and lands there at IN + the rest; past
//       the end the LAST item, at its OUT (the seek's clamp makes it OUT - 1: the title ends
//       within a picture). Atomic like a seek; refused (NE_ITEM, nothing flushed) only on a
//       playlist with no item.
// The downstream flush a seek implies (demux, vbuf, decoder, display, audio) is
// player_ctl's (P6b3), which holds `busy` until it is released: the reader only
// guarantees that every byte after the accepting edge comes from the landing.
//
// THE ITEM TAG (P6b3i, docs/transport.md D8): every byte leaves with stream_ep, the item
// index mod 4 of the item its sector belongs to (a tag per cache slot, written when the
// sector is requested). The demux latches it with each video PTS; it rides with the PTS to
// the display, which maps it back to the item through player_ctl's table. item_hold keeps
// the walk from starting the next item (S_ITEM) while player_ctl says a fifth item would
// alias a tag the display still shows.
//
// BARE STREAMS (P8, docs/bare_streams.md): the first read is sector 0, sniffed. A pack header
// (00 00 01 BA) is a bare .MPS -- a disc's STREAM/NNNNN.MPS on its own --, "PSMF" a .PMF (PSP
// game cutscenes: a PSMF header, then the same program stream; JPCSP scePsmf.java). Anything
// else is an image, walked as above (no ISO's sector 0 reads as either: tools/pmf_census.py
// --sector0 over the library). A bare stream is ONE synthesized item of ONE playlist: no title,
// no marks, no EP map (ep_flags[0]), OUT at the end of time (the END record ends it), IN =
// 90000 (a CLP's start PTS, always; JPCSP's PSMF validity rule) -- the HUD's time origin
// only: nav_skip 0, so the display drops nothing --, pl_dur 0 (unknown). The tracks come from the stream (emu, the demux's taps), not
// from here. Navigation: SEEK / TIME / PLAY answered NE_NOMAP with nothing flushed, CHAP with
// no chapter. A PSMF header is checked as JPCSP's sceMpeg checks it (stream offset non-zero,
// 2048-aligned, inside the file: else E_BARE); a stream size disagreeing with the file is
// streamed to the nearer end and flagged (pmf_warn). A file of 4 GB or more is E_BARE
// (S_MPS's extent is u32 bytes; a UMD clip is < 1.8 GB).
//
// KNOWN LIMITATIONS:
//   * The track tables are rewritten when the NEXT item's CLP is parsed, which happens
//     while the previous item's tail is still in the cache (multi-item playlists only:
//     3 of 89 main titles; the item boundary is P8's handoff, transport.md D8).
//   * An EP entry's PTS is u32: a lookup whose target is at or past 2^32 ticks (13.25 h)
//     lands on the last entry and is flagged (ep_flags[2], NE_WIDE), never wrapped.

module umd_reader (
    input             clk,
    input             rst_n,

    input             start,          // pulse: a freshly mounted image (size != 0)
    input             stop,           // pulse: the image went away -> idle, cache flushed
    input      [63:0] file_size,      // image bytes (img_size)

    // hps_io sd_* (BLKSZ=4: one 2048-byte sector per request)
    output reg [31:0] sd_lba,
    output reg        sd_rd,
    input             sd_ack,
    input      [13:0] sd_buff_addr,
    input       [7:0] sd_buff_dout,
    input             sd_buff_wr,

    // program-stream bytes of the main title, in order
    output reg  [7:0] stream_data,
    output reg        stream_valid,
    output reg  [1:0] stream_ep,      // P6b3i: the byte's item index mod 4 (with stream_data)
    input             item_hold,      // P6b3i: do not start the next item yet
    input             busy,           // backpressure (ps_stream_fifo almost full)

    // status
    output      [5:0] state_o,
    output            active,         // level: walking or streaming (not idle/done/error)
    output reg  [3:0] err_code,       // 0 = none; E_* below. Latched until start/stop
    output reg        streaming,      // level: the walk is done, .MPS sectors flowing
    output reg        title_done,     // level: every item streamed and the cache drained
    output reg [31:0] secs_streamed,  // .MPS sectors delivered since start
    output            sfo_warn,       // PARAM.SFO missing/malformed/no TITLE (title empty)
    output            title_trunc,    // TITLE longer than title_mem (first 128 kept)
    output            dur_sat,        // a playlist duration sum saturated
    output reg  [1:0] bare,           // P8: 0 an image, 1 a bare .MPS, 2 a .PMF (sector 0 sniffed)
    output            pmf_warn,       // P8: the PSMF's stream size disagrees with the file's

    // PARAM.SFO TITLE (UTF-8, NUL-terminated as stored; title_len = bytes kept)
    input       [6:0] title_addr,
    output reg  [7:0] title_q,        // registered: title_mem[title_addr]
    input       [6:0] title_addr2,    // P6b5: a second read port (the transport HUD's)
    output reg  [7:0] title_q2,
    output reg  [7:0] title_len,

    // what is playing
    output reg [15:0] main_pl,        // index of the chosen (longest) playlist
    output reg [15:0] n_playlists,
    output reg [31:0] n_items,        // items in the chosen playlist
    output reg [31:0] item_idx,       // item now streaming
    output reg [63:0] clip_name,      // item's clip name, byte 0 in [63:56], NUL-padded
    output reg [47:0] item_in_pts,
    output reg [47:0] item_out_pts,
    output reg [47:0] item_base,      // P6b5: the earlier items' durations (sum of OUT - IN,
                                      //   saturating), with item_in_pts: the title's time
                                      //   at this item's IN (the HUD's elapsed)
    output     [63:0] pl_dur,         // P6b5: the chosen playlist's duration (the HUD's total)
    output reg        item_start,     // pulse: the first sector of a new item is requested
    output reg [31:0] mps_lba,        // first extent of the playing .MPS
    output reg [31:0] mps_bytes,      // size of that first extent

    // the playing clip's CLP stream table
    output reg [47:0] clip_start_pts,
    output reg [47:0] clip_end_pts,
    output reg [15:0] n_streams,
    output reg [15:0] n_video,        // 1 on every disc; anything else is worth a flag
    output reg [15:0] n_unknown,      // entries that are neither video, 0x00-0x0F nor 0x80-0x9F
    output reg  [7:0] vid_attr0,      // first video entry's attribute byte 0 (low nibble: rate)
    output reg  [7:0] vid_attr1,      //   ... byte 1 (high nibble: aspect)
    output reg [15:0] aud_present,    // bit n = audio substream 0x0n declared
    output reg [31:0] sub_present,    // bit n = subtitle substream 0x80+n declared
    output reg [31:0] ep_map_off,     // CLP byte offset of the EP map (P6 seeking)
    input       [5:0] lang_sel,       // 0-15 audio 0x00-0x0F, 16-47 subtitle 0x80-0x9F
    output reg [15:0] lang_q,         // registered: the entry's 2 ASCII language bytes

    // navigation (P6b2; the contract is docs/transport.md S2.4). The key is (item, pts):
    // a mark's PTS lies on its own item's clip timeline.
    input             nav_req,        // a command, taken on a cycle with nav_ready
    input       [2:0] nav_op,         // NAV_SEEK / NAV_CHAP / NAV_PLAY (P9) / NAV_TIME (P6c)
    input      [15:0] nav_pl,         // NAV_PLAY: the playlist
    input      [31:0] nav_item,
    input      [47:0] nav_pts,        //   (NAV_TIME: the time, in 90 kHz ticks)
    output            nav_ready,      // level: the title is streaming, draining or done,
                                      //   and no command is pending
    output reg        nav_done,       // pulse: the command's results below are valid
    output reg  [2:0] nav_err,        // NE_* below, with nav_done
    // where the playing item started (a seek's landing). Also rewritten by every item
    // start of the walk.
    output reg [31:0] nav_land,       // SEEK: the item it landed in (item_idx may already
                                      //   have moved on: an entry past the clip)
    output reg [31:0] nav_ep_idx,     // the video EP entry's index
    output reg [31:0] nav_ep_pts,     //   its PTS
    output reg [31:0] nav_ep_sec,     //   its sector, relative to the .MPS
    output reg [47:0] nav_skip,       // the target clamped into IN..OUT (a walk: IN)
    output reg  [2:0] ep_flags,       // the playing item's lookups: [0] no video map
                                      //   (streamed whole), [1] the entry lies past the
                                      //   clip (item skipped), [2] a target >= 2^32
    // NAV_CHAP
    output reg [15:0] ch_rank,        // chapters at or before the key
    output reg [15:0] ch_count,       // chapters on the title
    output reg  [2:0] ch_valid,       // [0] ch_cur, [1] ch_prev, [2] ch_next
    output reg [63:0] ch_cur,         // {item u16, pts u48}: the chapter holding the key,
    output reg [63:0] ch_prev,        //   the one before it (Prev's 1 s rule),
    output reg [63:0] ch_next         //   the first after the key
);

`include "umd/nav/nav_io.svh"

// =========================================================================
// Image size, the cache, the output pipe (unchanged from the hardwired reader)
// =========================================================================
localparam CACHE_AW   = 14;
localparam CACHE_SIZE = 2 ** CACHE_AW;          // 8 sectors
localparam BLK        = 2048;

reg  [7:0]          cache_mem [0:CACHE_SIZE-1];
reg  [CACHE_AW-1:0] wr_ptr;                     // always a multiple of 2048
reg  [CACHE_AW-1:0] rd_ptr;
wire [CACHE_AW-1:0] cache_level    = wr_ptr - rd_ptr;
reg  [1:0]          slot_ep [0:7];              // P6b3i: each cache slot's item tag
wire                cache_has_data = (wr_ptr != rd_ptr);
wire                cache_has_room = (cache_level < CACHE_SIZE - BLK - 1);

reg  [7:0] cache_rd_data;
always @(posedge clk) cache_rd_data <= cache_mem[rd_ptr];

// =========================================================================
// The two sector slots the program's file loads read (docs/nav_engine.md S7): a sector by
// LBA, the older replaced. One M10K each (2 KB).
// =========================================================================
reg  [7:0]  slot0 [0:2047];
reg  [7:0]  slot1 [0:2047];
reg  [7:0]  slot0_q, slot1_q;
reg  [31:0] slot_lba [0:1];
reg  [1:0]  slot_v;
reg         slot_old;                  // the slot a miss replaces

// =========================================================================
// Title and track-language stores (written by the program, one read port each)
// =========================================================================
reg  [7:0]  title_mem [0:127];
reg         tm_we;
reg  [6:0]  tm_wa;
reg  [7:0]  tm_wd;
always @(posedge clk) begin
    if (tm_we) title_mem[tm_wa] <= tm_wd;
    title_q  <= title_mem[title_addr];
    title_q2 <= title_mem[title_addr2];
end

reg  [15:0] lang_mem [0:47];
reg         lm_we;
reg  [5:0]  lm_wa;
reg  [15:0] lm_wd;
always @(posedge clk) begin
    if (lm_we) lang_mem[lm_wa] <= lm_wd;
    lang_q <= lang_mem[lang_sel];
end

// =========================================================================
// The engine
// =========================================================================
wire [15:0] io_addr;
wire [31:0] io_wdata;
wire        io_we, io_re;
reg  [31:0] io_rdata;
wire        fb_req;
wire [31:0] fb_off;
reg         fb_ack;
wire [7:0]  fb_byte;
wire [15:0] eng_status;
reg         eng_restart, eng_vector;

nav_seq u_seq (
    .clk(clk), .rst_n(rst_n), .restart(eng_restart), .vector(eng_vector),
    .io_addr(io_addr), .io_wdata(io_wdata), .io_we(io_we), .io_re(io_re), .io_rdata(io_rdata),
    .fb_req(fb_req), .fb_off(fb_off), .fb_ack(fb_ack), .fb_byte(fb_byte),
    .status(eng_status),
    .tr_valid(), .tr_pc(), .tr_we(), .tr_rd(), .tr_val()
);

// ---- registers the program writes that are not outputs ---------------------------------
reg  [31:0] acc_items;                 // ACC_ITEMS: the chosen playlist's items (the take's rule)
reg         ready_r;                   // nav_ready before the pending bit
reg  [31:0] f_lba, f_last;             // the current file
// the pump
reg  [31:0] p_lba, p_left, p_clip_left;
reg         p_clip_lim;
reg  [1:0]  p_tag;
reg         pump_on, paused, rd_wait;
// the navigation latch
reg         pend, accepted;
reg  [2:0]  c_op;
reg  [15:0] c_pl;
reg  [31:0] c_item;
reg  [47:0] c_pts;
reg  [5:0]  state;
reg  [3:0]  flags;                     // {pmf_warn, dur_sat, title_trunc, sfo_warn}
assign state_o = state;
assign active  = (state != 6'd0) && (state != 6'd39) && (state != 6'd40);
reg  [63:0] pl_dur_r;
assign pl_dur  = pl_dur_r;

// ---- navigation handshake: acceptance at the edge, as the hardwired reader ------------------
localparam [2:0] NAV_SEEK = 3'd1, NAV_CHAP = 3'd2, NAV_PLAY = 3'd3, NAV_TIME = 3'd4;
assign nav_ready = ready_r && !pend;
wire   nav_take  = nav_req && nav_ready;
wire   take_acc  = nav_take && (bare == 2'd0) &&
                   ((nav_op == NAV_SEEK && nav_item < acc_items) ||
                    (nav_op == NAV_TIME && acc_items != 32'd0) ||
                    (nav_op == NAV_PLAY && nav_pl < n_playlists));

// ---- status (the engine's `wait` and I_STATUS) ---------------------------------------------
wire pump_idle = !pump_on || (paused && !rd_wait);
reg  stopped;
assign eng_status = {9'd0, stopped, accepted, item_hold, !item_hold, !cache_has_data, pump_idle, pend};

// ---- I/O reads: combinational on the engine's address (its data is taken in D) -----------
always @* begin
    case (io_addr)
        A_I_FSIZE_LO:    io_rdata = file_size[31:0];
        A_I_FSIZE_HI:    io_rdata = file_size[63:32];
        A_I_STATUS:      io_rdata = {16'd0, eng_status};
        A_I_NAV_OP:      io_rdata = {29'd0, c_op};
        A_I_NAV_PL:      io_rdata = {16'd0, c_pl};
        A_I_NAV_ITEM:    io_rdata = c_item;
        A_I_NAV_PTS_LO:  io_rdata = c_pts[31:0];
        A_I_NAV_PTS_HI:  io_rdata = {16'd0, c_pts[47:32]};
        A_I_P_LEFT:      io_rdata = p_left;
        A_I_P_CLIP_LEFT: io_rdata = p_clip_left;
        A_I_STATE:       io_rdata = {26'd0, state};
        default:         io_rdata = 32'd0;
    endcase
end

// =========================================================================
// File loads: a byte of the current file a request (docs/nav_engine.md S7). The sector is
// F_LBA + off / 2048; past F_LAST it reads 0. A slot hit answers two cycles after the request
// (the slot's read address is the request's offset); a miss reads the sector over sd into the
// older slot first.
// =========================================================================
wire [32:0] fb_sec  = {1'b0, f_lba} + {12'd0, fb_off[31:11]};
wire        fb_past = (fb_sec > {1'b0, f_last});
wire        hit0    = slot_v[0] && !fb_sec[32] && (slot_lba[0] == fb_sec[31:0]);
wire        hit1    = slot_v[1] && !fb_sec[32] && (slot_lba[1] == fb_sec[31:0]);
always @(posedge clk) begin
    slot0_q <= slot0[fb_off[10:0]];
    slot1_q <= slot1[fb_off[10:0]];
end
localparam [1:0] FB_IDLE = 2'd0, FB_MISS = 2'd1, FB_FILL = 2'd2, FB_READ = 2'd3;
reg  [1:0]  fb_st;
reg         fb_zero, fb_sel;
reg         fill_slot;
assign fb_byte = fb_zero ? 8'h00 : (fb_sel ? slot1_q : slot0_q);

// =========================================================================
// sd byte writes: a slot or the stream cache, chosen at request time
// =========================================================================
reg         rq_busy, rq_done, rq_dst, sd_ack_d;     // rq_dst: 0 a slot (fill_slot), 1 the cache
always @(posedge clk)
    if (sd_buff_wr && !rq_dst && !fill_slot) slot0[sd_buff_addr[10:0]] <= sd_buff_dout;
always @(posedge clk)
    if (sd_buff_wr && !rq_dst &&  fill_slot) slot1[sd_buff_addr[10:0]] <= sd_buff_dout;
always @(posedge clk)
    if (sd_buff_wr && rq_dst)
        cache_mem[{wr_ptr[CACHE_AW-1:11], sd_buff_addr[10:0]}] <= sd_buff_dout;

// =========================================================================
// The hardware: the sd handshake, the pump, the file-load unit, the take, the program's
// registers
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sd_lba <= 32'd0; sd_rd <= 1'b0; sd_ack_d <= 1'b0;
        rq_busy <= 1'b0; rq_done <= 1'b0; rq_dst <= 1'b0; fill_slot <= 1'b0;
        wr_ptr <= 0; rd_wait <= 1'b0; pump_on <= 1'b0; paused <= 1'b0;
        slot_v <= 2'b00; slot_old <= 1'b0; fb_st <= FB_IDLE; fb_ack <= 1'b0;
        fb_zero <= 1'b0; fb_sel <= 1'b0;
        state <= 6'd0; err_code <= 4'd0; streaming <= 1'b0; title_done <= 1'b0;
        secs_streamed <= 32'd0; flags <= 4'd0; bare <= 2'd0; title_len <= 8'd0;
        ready_r <= 1'b0; pend <= 1'b0; accepted <= 1'b0; nav_done <= 1'b0; item_start <= 1'b0;
        tm_we <= 1'b0; lm_we <= 1'b0; eng_restart <= 1'b0; eng_vector <= 1'b0; stopped <= 1'b0;
        acc_items <= 32'd0; nav_err <= 3'd0;
    end else begin
        // ---- the sd handshake: independent of everything else, survives start / stop -----
        sd_ack_d <= sd_ack;
        rq_done  <= 1'b0;
        if (sd_ack) sd_rd <= 1'b0;
        if (rq_busy && sd_ack_d && !sd_ack) begin       // falling edge = block delivered
            rq_busy <= 1'b0;
            rq_done <= 1'b1;
        end

        item_start  <= 1'b0;
        nav_done    <= 1'b0;
        tm_we       <= 1'b0;
        lm_we       <= 1'b0;
        fb_ack      <= 1'b0;
        eng_restart <= 1'b0;

        if (start || stop) begin
            // ---- a hardware restart: the engine to its vector, the pump and the slots cleared,
            //      the status the downstream reads at once cleared in this cycle --------------
            eng_restart <= 1'b1; eng_vector <= stop; stopped <= stop;
            state <= start ? 6'd1 : 6'd0;
            wr_ptr <= 0; rd_wait <= 1'b0; pump_on <= 1'b0; paused <= 1'b0;
            slot_v <= 2'b00; fb_st <= FB_IDLE;
            err_code <= 4'd0; streaming <= 1'b0; title_done <= 1'b0; secs_streamed <= 32'd0;
            flags <= 4'd0; bare <= 2'd0; title_len <= 8'd0;
            ready_r <= 1'b0; pend <= 1'b0; accepted <= 1'b0;
        end else begin
            // ---- the navigation take (acceptance at the edge) -----------------------------
            if (nav_take) begin
                pend <= 1'b1; accepted <= take_acc;
                c_op <= nav_op; c_pl <= nav_pl; c_item <= nav_item; c_pts <= nav_pts;
                if (take_acc) begin                     // flush now: the cache, the output,
                    wr_ptr <= 0;                        //   streaming, title_done; the pump
                    rd_wait <= 1'b0;                    //   frozen (an in-flight block lands
                    pump_on <= 1'b0;                    //   uncounted)
                    paused <= 1'b0;
                    streaming <= 1'b0;
                    title_done <= 1'b0;
                end
            end

            // ---- the pump: the stream's sectors into the cache --------------------------------
            if (rd_wait) begin
                if (rq_done) begin
                    rd_wait       <= 1'b0;
                    wr_ptr        <= wr_ptr + 14'd2048;   // CACHE_AW = 14
                    p_lba         <= p_lba + 32'd1;
                    p_left        <= p_left - 32'd1;
                    p_clip_left   <= p_clip_left - 32'd1;
                    secs_streamed <= secs_streamed + 32'd1;
                end
            end else if (pump_on && !paused && !take_acc) begin
                if ((p_clip_lim && p_clip_left == 32'd0) || p_left == 32'd0)
                    pump_on <= 1'b0;                    // the item's stop, or the extent's end
                else if (cache_has_room && !rq_busy && !rq_done && fb_st == FB_IDLE && !fb_req) begin
                    sd_lba  <= p_lba;
                    sd_rd   <= 1'b1;
                    rq_busy <= 1'b1;
                    rq_dst  <= 1'b1;
                    rd_wait <= 1'b1;
                    slot_ep[wr_ptr[CACHE_AW-1:11]] <= p_tag;
                end
            end

            // ---- the file-load unit ------------------------------------------------------------
            case (fb_st)
                FB_IDLE: if (fb_req) begin
                    if (fb_past) begin
                        fb_zero <= 1'b1; fb_ack <= 1'b1;
                    end else if (hit0 || hit1) begin
                        fb_zero <= 1'b0; fb_sel <= hit1; fb_ack <= 1'b1;
                        slot_old <= !hit1;              // the other slot is now the older
                    end else
                        fb_st <= FB_MISS;
                end
                FB_MISS: if (!rq_busy && !rq_done) begin
                    sd_lba    <= fb_sec[31:0];
                    sd_rd     <= 1'b1;
                    rq_busy   <= 1'b1;
                    rq_dst    <= 1'b0;
                    fill_slot <= slot_old;
                    slot_v[slot_old] <= 1'b0;
                    fb_st     <= FB_FILL;
                end
                FB_FILL: if (rq_done) begin
                    slot_lba[fill_slot] <= fb_sec[31:0];
                    slot_v[fill_slot]   <= 1'b1;
                    slot_old            <= !fill_slot;
                    fb_st               <= FB_READ;     // the slot's read port: one cycle
                end
                default: begin                          // FB_READ: the byte is in
                    fb_zero <= 1'b0; fb_sel <= fill_slot; fb_ack <= 1'b1;
                    fb_st   <= FB_IDLE;
                end
            endcase

            // ---- the program's writes ----------------------------------------------------------
            if (io_we) begin
                if (io_addr[15:7] == A_O_TITLE_MEM[15:7]) begin
                    tm_we <= 1'b1; tm_wa <= io_addr[6:0]; tm_wd <= io_wdata[7:0];
                end else if (io_addr[15:7] == A_O_LANG_MEM[15:7]) begin
                    lm_we <= 1'b1; lm_wa <= io_addr[5:0]; lm_wd <= io_wdata[15:0];
                end else case (io_addr)
                    // item_hold's guard (P6b3i): S_ITEM (27) -> its record (28) is not taken in a
                    // cycle item_hold is up; every other state write is
                    A_O_STATE:        if (!(state == 6'd27 && io_wdata[5:0] == 6'd28 && item_hold))
                                          state <= io_wdata[5:0];
                    A_O_ERR:          err_code <= io_wdata[3:0];
                    A_O_STREAMING:    streaming <= io_wdata[0];
                    A_O_TITLE_DONE:   title_done <= io_wdata[0];
                    A_O_FLAGS:        flags <= io_wdata[3:0];
                    A_O_BARE:         bare <= io_wdata[1:0];
                    A_O_TITLE_LEN:    title_len <= io_wdata[7:0];
                    A_O_MAIN_PL:      main_pl <= io_wdata[15:0];
                    A_O_N_PLAYLISTS:  n_playlists <= io_wdata[15:0];
                    A_O_N_ITEMS:      n_items <= io_wdata;
                    A_O_ITEM_IDX:     item_idx <= io_wdata;
                    A_O_CLIP_NAME_HI: clip_name[63:32] <= io_wdata;
                    A_O_CLIP_NAME_LO: clip_name[31:0] <= io_wdata;
                    A_O_ITEM_IN_LO:   item_in_pts[31:0] <= io_wdata;
                    A_O_ITEM_IN_HI:   item_in_pts[47:32] <= io_wdata[15:0];
                    A_O_ITEM_OUT_LO:  item_out_pts[31:0] <= io_wdata;
                    A_O_ITEM_OUT_HI:  item_out_pts[47:32] <= io_wdata[15:0];
                    A_O_ITEM_BASE_LO: item_base[31:0] <= io_wdata;
                    A_O_ITEM_BASE_HI: item_base[47:32] <= io_wdata[15:0];
                    A_O_PL_DUR_LO:    pl_dur_r[31:0] <= io_wdata;
                    A_O_PL_DUR_HI:    pl_dur_r[63:32] <= io_wdata;
                    A_O_MPS_LBA:      mps_lba <= io_wdata;
                    A_O_MPS_BYTES:    mps_bytes <= io_wdata;
                    A_O_CLIP_START_LO: clip_start_pts[31:0] <= io_wdata;
                    A_O_CLIP_START_HI: clip_start_pts[47:32] <= io_wdata[15:0];
                    A_O_CLIP_END_LO:  clip_end_pts[31:0] <= io_wdata;
                    A_O_CLIP_END_HI:  clip_end_pts[47:32] <= io_wdata[15:0];
                    A_O_N_STREAMS:    n_streams <= io_wdata[15:0];
                    A_O_N_VIDEO:      n_video <= io_wdata[15:0];
                    A_O_N_UNKNOWN:    n_unknown <= io_wdata[15:0];
                    A_O_VID_ATTR:     {vid_attr1, vid_attr0} <= io_wdata[15:0];
                    A_O_AUD_PRESENT:  aud_present <= io_wdata[15:0];
                    A_O_SUB_PRESENT:  sub_present <= io_wdata;
                    A_O_EP_MAP_OFF:   ep_map_off <= io_wdata;
                    A_O_NAV_ERR:      nav_err <= io_wdata[2:0];
                    A_O_NAV_LAND:     nav_land <= io_wdata;
                    A_O_NAV_EP_IDX:   nav_ep_idx <= io_wdata;
                    A_O_NAV_EP_PTS:   nav_ep_pts <= io_wdata;
                    A_O_NAV_EP_SEC:   nav_ep_sec <= io_wdata;
                    A_O_NAV_SKIP_LO:  nav_skip[31:0] <= io_wdata;
                    A_O_NAV_SKIP_HI:  nav_skip[47:32] <= io_wdata[15:0];
                    A_O_EP_FLAGS:     ep_flags <= io_wdata[2:0];
                    A_O_CH_RANK:      ch_rank <= io_wdata[15:0];
                    A_O_CH_COUNT:     ch_count <= io_wdata[15:0];
                    A_O_CH_VALID:     ch_valid <= io_wdata[2:0];
                    A_O_CH_CUR_LO:    ch_cur[31:0] <= io_wdata;
                    A_O_CH_CUR_HI:    ch_cur[63:32] <= io_wdata;
                    A_O_CH_PREV_LO:   ch_prev[31:0] <= io_wdata;
                    A_O_CH_PREV_HI:   ch_prev[63:32] <= io_wdata;
                    A_O_CH_NEXT_LO:   ch_next[31:0] <= io_wdata;
                    A_O_CH_NEXT_HI:   ch_next[63:32] <= io_wdata;
                    A_O_ACC_ITEMS:    acc_items <= io_wdata;
                    A_O_NAV_READY:    ready_r <= io_wdata[0];
                    A_O_NAV_DONE:     begin nav_done <= 1'b1; pend <= 1'b0; accepted <= 1'b0; end
                    A_O_ITEM_START:   item_start <= 1'b1;
                    A_O_F_LBA:        f_lba <= io_wdata;
                    A_O_F_LAST:       f_last <= io_wdata;
                    A_P_LBA:          p_lba <= io_wdata;
                    A_P_LEFT:         p_left <= io_wdata;
                    A_P_CLIP_LEFT:    p_clip_left <= io_wdata;
                    A_P_CLIP_LIM:     p_clip_lim <= io_wdata[0];
                    A_P_TAG:          p_tag <= io_wdata[1:0];
                    A_P_CMD: case (io_wdata[2:0])
                        PC_STREAM: begin pump_on <= 1'b1; paused <= 1'b0; end
                        PC_PAUSE:  paused <= 1'b1;
                        PC_RESUME: paused <= 1'b0;
                        default: ;
                    endcase
                    default: ;
                endcase
            end
        end
    end
end

assign sfo_warn    = flags[0];
assign title_trunc = flags[1];
assign dur_sat     = flags[2];
assign pmf_warn    = flags[3];

// =========================================================================
// Output: one byte per two cycles while the consumer is not busy
// (block_streamer's pipe; the cache only ever holds .MPS bytes)
// =========================================================================
reg read_valid_pipe;
reg [1:0] ep_pipe;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stream_data     <= 8'd0;
        stream_valid    <= 1'b0;
        stream_ep       <= 2'd0;
        ep_pipe         <= 2'd0;
        read_valid_pipe <= 1'b0;
        rd_ptr          <= 0;
    end else if (start || stop || take_acc) begin   // an accepted SEEK / TIME / PLAY flushes
        rd_ptr          <= 0;
        stream_valid    <= 1'b0;
        read_valid_pipe <= 1'b0;
    end else begin
        stream_valid <= 1'b0;
        if (read_valid_pipe) begin
            stream_data     <= cache_rd_data;
            stream_ep       <= ep_pipe;
            stream_valid    <= 1'b1;
            read_valid_pipe <= 1'b0;
        end
        if (!busy && !read_valid_pipe && cache_has_data) begin
            rd_ptr          <= rd_ptr + 1'b1;
            ep_pipe         <= slot_ep[rd_ptr[CACHE_AW-1:11]];
            read_valid_pipe <= 1'b1;
        end
    end
end

endmodule
