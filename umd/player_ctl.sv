// umd/player_ctl.sv -- the player control block (P6b3, docs/transport.md S2; the contract of
// docs/menus.md S4 item 3): every transport decision, on clk_sys. Its clients are the
// buttons and keys (P6b), the panel (P6c) and the disc menus' engine (P9); its golden is
// tools/player_ctl_ref.py, written from tools/umd_nav_ref.py and transport.md S2.1-S2.5,
// and its bench bench/umd/run_player_ctl.sh.
//
// COMMANDS (cmd_valid, one a cycle; codes are stable -- the panel and the menus quote them):
//   1 PLAYPAUSE  play <-> pause; from STOP, play (the PSP's START; emu's Select, the PSP's X, too
//                since 2026-10-07: docs/transport.md D10)
//   2 PAUSE      pause (the panel's Pause item); nothing while paused or stopped; during trick
//                play, play (the PSP's X ends the scrubbing at normal speed, as the opposite arrow does: fj#57)
//   3 PLAY       play: from pause or stop
//   4 STOP       the idle screen, the picture held behind it; PLAY resumes where it stopped
//   5 NEXT / 6 PREV   a chapter press (S2.5)
//   7 SEEK       Go To (cmd_item, cmd_pts): a seek landing exactly there
//   8 AUDIO      the next declared audio track (wrapping); 9 AUDIO_SET: track cmd_arg
//   10 FF / 11 REW  trick play (P6b4, below): a speed a press, Forward / Reverse 1-3; the
//                opposite one returns to play (the PSP)
//   12 SUB       the subtitles (P7, docs/subtitles.md §7, S1 / S2): Off -> the lowest declared
//                track (0x80 + n) -> each higher declared track -> Off
//   13 PLAYLIST  P9 (docs/p9.md §3.2): play playlist cmd_pl from (cmd_item, cmd_pts) -- a disc
//                menu's movieplayer.play. A Go To through the reader's NAV_PLAY: the same
//                freeze / flush / landing, from any state (a menu plays from STOP), ending
//                trick play; it resumes play. A playlist >= rd_n_playlists is refused here
//                (BAD), so the reader never takes a PLAY it would not flush for; an item past
//                the playlist's last is the READER's to clamp (it plays the first, NE_ITEM).
//                Refused (BAD) while a press gesture or a seek is in flight: the host retries.
//   14 SUB_SET   P9: the subtitles set outright, cmd_item[5] on, [4:0] the track (0x80 + n):
//                the SUB flush with that state; a track the clip does not declare is BAD.
//                Needs host_ok as SUB does (else HOST); BAD while a change is in flight
//   15 TIME      P6c, Go To by time: a seek to the PLAYING playlist's time cmd_pts (90 kHz
//                ticks), through the reader's NAV_TIME (the item walk finds the item; past the
//                end the last item's OUT - 4: the title then ends, D16). A TIME the reader
//                clamped so -- the last item's OUT - 4 -- lands WITHOUT the skip, as a hop does
//                but playing on: the last entry's I picture and the rest of its GOP play out to
//                the title's END, not its last picture alone (a UX choice since
//                fix/skip-last-picture; it was the workaround for the reader's OUT - 1 clamp,
//                whose skip dropped the last picture too -- display.md §11, p6c.md §10). As SEEK otherwise:
//                taken with no gesture in flight and not stopped; during trick play it ends it
//                (the seek once the hop in flight lands); else BAD.
// Every other code is counted (n_bad) and ignored.
//
// THE GO TO QUERY PORT (P6c, umd/goto_ctl.sv): Go To's chapter selector asks the reader's
// NAV_CHAP from a key of its own (gq_req held, gq_key) while no gesture is in flight; the
// tracker's query goes first. gq_done pulses with the answer (the reader's ch_* outputs,
// read by goto_ctl directly); nothing here acts on it.
//
// A SEEK (S2.1): FREEZE (the display holds its store, the STC and the audio stop) ->
// RESOLVE (a chapter press asks the reader's NAV_CHAP, from the PENDING key: repeated
// presses are judged one after another, each from the previous one's target, as
// umd_nav_ref.presses does; presses within MERGE_CYC of the last one merge into ONE seek)
// -> NAV_SEEK (the reader drops every undelivered byte at the accepting edge) -> THE FLUSH:
// at that same edge `seek_flush` rises, a level the whole pipeline behind the reader
// resets on (the demux, the vbuf's clear, the decoder with its parameter sets kept, the
// audio chain) and the display drains its queue on (disp_ctl resync). It is held at least
// FLUSH_MIN cycles (the clk_dec / clk_mem copies are cdc_reset'd from it: the mount's 16)
// and until the output queue has been idle IDLE_MIN cycles in a row (every queued record
// taken and released, the decoder held in reset so nothing new arrives); `rd_hold` holds
// the reader's stream a few cycles longer, so no byte enters a FIFO still in reset -> LAND:
// the landing's item start writes its entry in the display's item table (below: nav_skip,
// the key clamped into IN..OUT, is its target -- the display skips the stores before it,
// D2) -> the first new pickup ends the seek. A WATCHDOG (WD_CYC, 3 s
// unfrozen) ends a landing with no picture: counted, an event, and the display told to show
// whatever arrives (no skip), never a hang.
//
// PAUSE freezes (S2.3; the display's refresh-aligned freeze holds the STC and the audio
// together). STOP is the same freeze behind the idle screen (D5); PLAY resumes by releasing
// it -- exact and instant. (transport.md S2.3 planned a seek back to the stop point; the
// freeze lands on the same picture without one: decided in P6b3, S9.) A seek resumes play.
//
// CHAPTERS: after every landing, and whenever the shown picture reaches the next chapter's
// key, a NAV_CHAP from the shown key (key_item, sh_pts) updates `chapter` (its rank) and the
// next chapter's key; a changed rank posts an event. While presses are pending `chapter` is
// the projected one, held until the landing (never flickering back). Next past the last
// chapter posts NO_CHAPTER (the PSP's "There is no chapter available.") and does nothing
// else; Prev restarts the chapter unless the key is less than 1 s after its start (then the
// one before; the first chapter restarts) -- D3.
//
// THE ITEMS (P6b3i, D8): every picture carries its playlist item's tag (the index mod 4). At
// every item start -- the mount's, the walk's, a seek's landing -- this block writes the
// display's 4-entry item table {IN (a seek: its target), OUT, last, skip} and keeps the
// tag's item (u32); key_item is the shown picture's (its tag at each pickup). A resync
// clears the display's table on its rising edge, so a landing's write (it comes later) is
// never lost. THE HOLD: the reader may not start item j while the shown item is j - 4 or
// earlier (item_hold): a fifth item in flight would alias a tag the display still shows.
// It cannot deadlock -- item j - 4's last pictures need only item j - 3's first to leave the
// DPB. It is lifted while a seek is in flight (the display is frozen and the flush drains
// everything; a Go To must reach the reader), and counted (n_hold), never silent.
//
// TRICK PLAY (P6b4, S2.6, D1): FF / REW enter it from play or pause (a picture shown, no
// gesture in flight); each further press in the same direction steps the speed (1-3, then
// stays), the opposite one, PLAY / PLAYPAUSE, PAUSE, STOP, a chapter press or a Go To end it.
// A HOP is a seek (the whole discontinuity above) to a TARGET carried from hop to hop: +/- the
// speed's rate (20 / 33 / 55x, the PSP's, measured on Akira) x the wall time since the last
// hop was issued (a 90 kHz strobe adds rate x TICK_N ticks, so the rate holds whatever a hop
// costs), issued at least HOP_MIN after the last one (so a hop advances past the widest entry
// gap: 1.97 s / 20x < 125 ms) and only once its picture was shown. While a hop is the landing
// (`one_frame`, set and cleared only at a seek's accepting edge, so the decoder's clock domain
// sees it change only under the flush's reset) the front end ends the stream after the entry's
// first frame (h264_top), the landing writes its entry WITHOUT a skip (the display shows the
// entry's I on arrival, anchored by the resync), the audio chain is held in reset (silent; the
// demux's audio is taken and dropped) and a TITLE_END is not posted (every hop's stream ends).
// Between hops the reader's stream is held (rd_hold). The carried target becomes the READER's
// clamped target (nav_skip); a clamp that moved it (forward: down to OUT - 4; reverse: up to IN,
// or the request saturated at 0) is the item's EDGE, and the next hop crosses to the next
// item's IN (PTS 0, clamped) or the previous item's end (PTS all ones, clamped) -- the
// overshoot dropped: no item's duration is known here. Past the title's last item forward or
// its first reverse, play resumes. umd_nav_ref.hop_request / hop_land are the rule.
// LEAVING IT: play resumes by a seek to the shown key -- the last hop's I, exact (D2) -- made
// by the seek machine whenever it is idle in PLAY with a hop's landing still the decoder's
// (a stop during trick play holds the I; PLAY then makes that seek; a PAUSE plays, fj#57). A chapter press keys
// its burst from the picture shown at its first press (kept aside until the hop in flight
// lands); a Go To seeks to its key.
//
// THE AUDIO TRACK (S2.3, D7): aud_track defaults to the lowest declared track at a mount and
// whenever the playing clip no longer declares it. A switch resets the audio chain for
// AUD_RST_CYC cycles; its LAST cycle carries the new aud_track and the demux's realign, and
// the chain leaves reset the cycle after (so the first byte the new chain takes is an access
// unit's first, of the new track: a realign in the release's own cycle let the one old-track
// byte the demux had on its output that cycle into the fresh ring -- the framer slid over it;
// found by run_av_sync.sh S12, P6b7). The video plays on; the new track starts at its PTS (up to ~2 s of silence).
//
// THE SUBTITLES (P7, docs/subtitles.md §7; the maintainer's S1 / S2): off at a mount; SUB steps
// Off -> the lowest declared subtitle track -> each higher declared one -> Off. A change holds
// sub_flush SUB_FL_CYC cycles (emu flushes the overlay with it and keeps the demux's subtitle
// output off, so a unit cut by the switch is dropped as orphan bytes, counted); its last-but-one
// cycle applies the new {sub_on, sub_track} and posts SUB. A clip that no longer declares the
// track on screen turns them off the same way. A press with no declared track posts SUB off.
// A7 (docs/hps_host.md §5): the subtitles are decoded by the UMD Main, so SUB needs host_ok
// (umd_host: its heartbeat). Without it a press changes nothing and posts HOST (data[0]:
// host_bad, a UMD Main with the wrong PROTO) -- the HUD's message; and subtitles on while the
// host is gone (a Main that stopped) turn off the flush's way, posting SUB off then HOST.
//
// BARE STREAMS (P8, docs/bare_streams.md): `bare` is the reader's "a bare .MPS / .PMF file" --
// one item, no EP map, no marks. A command that would seek (FF / REW, SEEK, TIME, PLAYLIST) is
// never issued: it posts UNAVAIL (the HUD's "Not available for this file."), nothing else
// changes. (The reader refuses such a seek too, NE_NOMAP with nothing flushed -- but this
// block's own flush would still have cut the stream: the gate belongs here.) Chapter presses
// query as ever and find none (NO_CHAPTER). The tracks come from the stream (emu ORs in what the
// demux sees), so the default-track rule is judged every cycle, not at the item start: the
// mask only grows on a bare title (no seek re-reads anything), so a choice made stays.
//
// EVENTS: an 8-deep FIFO of {code, data}: 1 CHAPTER (rank), 2 SEEK_DONE, 3 TITLE_END,
// 4 NO_CHAPTER, 5 SEEK_WD (the watchdog), 6 NAV_ERR (nav_err), 7 TRACK (the track),
// 8 BAD (the command code), 9 SUB ({on, track}: data[5] on, data[4:0] the track; data[6] the disc asked
// it -- a SUB_SET, P9 M4b: the HUD shows no tag for those, as the PSP shows nothing), 10 HOST (A7:
// subtitles refused or dropped for want of the UMD Main; data[0] host_bad). A push into a full
// FIFO is counted (ev_lost), never silent. 11 UNAVAIL (P8: a seek asked of a bare stream).
//
// RESETS: rst_n is the CORE reset. The gesture state (pending presses, the pending target,
// the merge timer) survives the flush it causes (MiSTer_DVD's reset-domain rule); a mount
// clears the title's state synchronously.
//
// Quartus 17: no functions, no N'() casts.

`default_nettype none

module player_ctl #(
    parameter int MERGE_CYC   = 13_500_000,   // 500 ms: presses closer than this merge
    parameter int WD_CYC      = 81_000_000,   // 3 s: a landing with no picture
    parameter int FLUSH_MIN   = 16,
    parameter int IDLE_MIN    = 8,
    parameter int HOLD_TAIL   = 4,
    parameter int AUD_RST_CYC = 16,
    parameter int SUB_FL_CYC  = 16,          // P7: a subtitle change's flush
    parameter int HOP_MIN     = 3_375_000,    // 125 ms: the shortest wall time between hops
    parameter int TICK_DIV    = 300,          // cycles a trick-play strobe (27 MHz / 90 kHz)
    parameter int TICK_N      = 1             // 90 kHz ticks a strobe (the bench scales time)
) (
    input  wire         clk,               // clk_sys
    input  wire         rst_n,             // the core reset
    input  wire         mount,             // pulse: an image with media
    input  wire         eject,             // pulse: the image went away
    // commands
    input  wire         cmd_valid,
    input  wire  [3:0]  cmd_code,
    input  wire  [31:0] cmd_item,
    input  wire  [47:0] cmd_pts,
    input  wire  [3:0]  cmd_arg,
    input  wire  [15:0] cmd_pl,            // P9: PLAYLIST's playlist
    // the reader (umd_reader)
    input  wire         rd_item_start,
    input  wire  [31:0] rd_item_idx,
    input  wire  [31:0] rd_n_items,
    input  wire  [47:0] rd_item_out,
    input  wire  [15:0] rd_aud_present,
    input  wire  [31:0] rd_sub_present,    // P7: the playing clip's subtitle tracks (0x80 + n)
    input  wire  [15:0] rd_n_playlists,    // P9: PLAYLIST's bound
    input  wire         bare,              // P8: a bare stream file (no map: no seek; tracks from the stream)
    input  wire         host_ok,           // A7: the UMD Main's heartbeat (umd_host): SUB needs it
    input  wire         host_bad,          //   a UMD Main with the wrong PROTO
    output logic        nav_req,
    output logic [2:0]  nav_op,
    output logic [31:0] nav_item,
    output logic [47:0] nav_pts,
    output logic [15:0] nav_pl,            // P9: NAV_PLAY's playlist
    input  wire         nav_ready,
    input  wire         nav_done,
    input  wire  [2:0]  nav_err,
    input  wire  [31:0] nav_land,
    input  wire  [47:0] nav_skip,
    input  wire  [15:0] ch_rank,
    input  wire  [15:0] ch_count,
    input  wire  [2:0]  ch_valid,
    input  wire  [63:0] ch_cur,
    input  wire  [63:0] ch_prev,
    input  wire  [63:0] ch_next,
    input  wire         gq_req,            // P6c: Go To's chapter query (goto_ctl), held until gq_done
    input  wire  [63:0] gq_key,            //   its key {item u16, pts u48}
    output wire         gq_done,           //   pulse: its answer is on the reader's ch_* outputs
    output logic        rd_hold,           // OR into the reader's busy
    // the pipeline
    output logic        seek_flush,        // level: the discontinuity (above)
    output logic        aud_rst,           // level: the audio chain's reset (a track switch; trick play)
    output logic [3:0]  aud_track,
    output logic        aud_realign,
    output logic        sub_on,            // P7: the subtitles shown (S1: off at a mount)
    output logic [4:0]  sub_track,         //   their track (0x80 + sub_track)
    output logic        sub_flush,         //   level: a change's flush (the overlay; the demux's subtitle output off)
    output logic        one_frame,         // P6b4: the landing is a hop -- h264_top ends the stream
                                           // after the first frame (changes only at an accepting edge)
    // the display (disp_ctl)
    output logic        freeze,
    output logic        idle_screen,
    output logic        ep_we,             // the display's item table (disp_ctl ep_*)
    output logic [1:0]  ep_wi,
    output logic [32:0] ep_in,
    output logic [32:0] ep_out,
    output logic        ep_last,
    output logic        ep_skip,
    output wire         item_hold,         // the reader: do not start the next item yet (combinational)
    input  wire  [1:0]  sh_ep,             // the shown picture's item tag
    input  wire  [32:0] sh_pts,
    input  wire         sh_pts_v,
    input  wire         pick,              // pulse: a new store was shown
    input  wire         ended,             // the display ended (the title's END, or OUT)
    input  wire         rec_idle,          // recon_out: the queue is drained
    // status
    output logic [2:0]  state,             // ST_* below
    output logic        seeking,
    output logic [15:0] chapter,           // the shown (or projected) chapter, from 1; 0 none
    output logic [15:0] n_chapters,
    output logic [31:0] key_item,
    output logic [7:0]  n_hold,            // times the reader was held at an item start
    output logic [15:0] n_seeks,
    output logic [7:0]  n_wd,
    output logic [7:0]  n_bad,
    output logic [7:0]  n_press_lost,      // presses beyond the 8-deep queue
    output logic [2:0]  last_nav_err,
    output logic [32:0] land_pts,          // P6b7: the first picture shown after the last landing
                                           //   (a seek's, a hop's, the watchdog's, the mount's)
    output logic [19:0] seek_lat,          // P6b7: the last seek landed with a picture (not a hop):
                                           //   90 kHz ticks from its first action to that picture
    output logic [1:0]  tk_speed,          // P6b4: trick play's speed, 0 off, 1-3
    output logic        tk_rev,            //   and its direction (1: reverse)
    // events
    output logic        ev_valid,
    output logic [3:0]  ev_code,
    output logic [15:0] ev_data,
    input  wire         ev_pop,
    output logic [7:0]  ev_lost
);

    localparam [2:0] ST_IDLE = 3'd0, ST_PLAY = 3'd1, ST_PAUSE = 3'd2, ST_STOP = 3'd3;
    localparam [3:0] C_PLAYPAUSE = 4'd1, C_PAUSE = 4'd2, C_PLAY = 4'd3, C_STOP = 4'd4, C_NEXT = 4'd5,
                     C_PREV = 4'd6, C_SEEK = 4'd7, C_AUDIO = 4'd8, C_AUDIO_SET = 4'd9, C_FF = 4'd10, C_REW = 4'd11,
                     C_SUB = 4'd12, C_PLAYL = 4'd13, C_SUB_SET = 4'd14, C_TIME = 4'd15;
    localparam [3:0] EV_CHAPTER = 4'd1, EV_SEEK_DONE = 4'd2, EV_TITLE_END = 4'd3, EV_NO_CHAPTER = 4'd4,
                     EV_SEEK_WD = 4'd5, EV_NAV_ERR = 4'd6, EV_TRACK = 4'd7, EV_BAD = 4'd8, EV_SUB = 4'd9,
                     EV_HOST = 4'd10, EV_UNAVAIL = 4'd11;
    localparam [2:0] NAV_SEEK = 3'd1, NAV_CHAP = 3'd2, NAV_PLAY = 3'd3, NAV_TIME = 3'd4;
    localparam [2:0] NE_NONE = 3'd0;
    localparam [47:0] END_GUARD = 48'd4;        // a seek's target clamp below OUT (umd_reader.sv, umd_nav_ref.clamp)
    // the seek machine
    localparam [2:0] SK_NONE = 3'd0, SK_QUERY = 3'd1, SK_MERGE = 3'd2, SK_SEEK = 3'd3, SK_FLUSH = 3'd4,
                     SK_LAND = 3'd5, SK_PIC = 3'd6, SK_HOP = 3'd7;
    // trick play's exits (P6b4), taken in SK_HOP (no hop in flight)
    localparam [2:0] EX_NONE = 3'd0, EX_PLAY = 3'd1, EX_STOP = 3'd3,     // (3'd2 was EX_PAUSE: fj#57)
                     EX_CHAP = 3'd4, EX_SEEK = 3'd5,
                     EX_PLAYL = 3'd6,     // P9: a PLAYLIST during trick play
                     EX_TIME = 3'd7;      // P6c: a Go To by time during trick play
    // the rates (content seconds per real second; the PSP's Forward 1-3, measured on Akira:
    // docs/transport.md S2.6) in ticks a strobe
    localparam [31:0] TK_R1 = 20 * TICK_N, TK_R2 = 33 * TICK_N, TK_R3 = 55 * TICK_N;

    // ---- the event FIFO (8 deep) --------------------------------------------------------------
    logic [19:0] evq [0:7];
    logic [2:0]  ev_wp, ev_rp;
    logic [3:0]  ev_n;
    logic        ev_push;
    logic [3:0]  ev_pc;
    logic [15:0] ev_pd;
    assign ev_valid = (ev_n != 4'd0);
    assign {ev_code, ev_data} = evq[ev_rp];
    wire   ev_take = ev_valid && ev_pop;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_wp <= '0; ev_rp <= '0; ev_n <= '0; ev_lost <= '0;
        end else begin
            if (ev_push && (ev_n != 4'd8 || ev_take)) begin
                evq[ev_wp] <= {ev_pc, ev_pd}; ev_wp <= ev_wp + 3'd1;
            end else if (ev_push && ev_lost != 8'hFF) ev_lost <= ev_lost + 8'd1;
            if (ev_take) ev_rp <= ev_rp + 3'd1;
            ev_n <= ev_n + {3'd0, ev_push && (ev_n != 4'd8 || ev_take)} - {3'd0, ev_take};
        end
    end

    // ---- the audio track: the lowest declared, and the next after the current -----------------
    logic [3:0] trk_low, trk_nxt;
    logic       trk_any, trk_other;
    always_comb begin
        trk_low = 4'd0; trk_any = 1'b0;
        for (int i = 15; i >= 0; i--) if (rd_aud_present[i]) begin trk_low = i[3:0]; trk_any = 1'b1; end
        // the first declared track after aud_track, wrapping: search the rotated mask
        trk_nxt = aud_track; trk_other = 1'b0;
        for (int j = 15; j >= 1; j--) begin
            logic [3:0] t;
            t = aud_track + j[3:0];
            if (rd_aud_present[t]) begin trk_nxt = t; trk_other = 1'b1; end
        end
    end

    // ---- the subtitles (P7): the lowest declared track, and the next above the current ----------
    logic [4:0] sb_low, sb_nxt;
    logic       sb_any, sb_more;
    always_comb begin
        sb_low = 5'd0; sb_any = 1'b0; sb_nxt = sub_track; sb_more = 1'b0;
        for (int i = 31; i >= 0; i--) if (rd_sub_present[i]) begin sb_low = i[4:0]; sb_any = 1'b1; end
        for (int i = 31; i >= 1; i--) if (rd_sub_present[i] && (i[4:0] > sub_track)) begin sb_nxt = i[4:0]; sb_more = 1'b1; end
    end

    // ---- the press queue (8 deep, 1 = Prev) -------------------------------------------------------
    logic [7:0] pq;
    logic [3:0] pq_n;
    wire        pq_head = pq[0];

    // ---- state -----------------------------------------------------------------------------------
    logic [2:0]  sk;
    logic        titled;                   // a title is mounted
    logic        start_wait;               // the mount: waiting for the walk's first item start
    logic        have_tgt;
    logic [31:0] pend_item;
    logic [47:0] pend_pts;
    logic [15:0] proj;                     // the projected chapter while presses are pending
    logic        q_track;                  // the chapter query in flight is the tracker's
    logic        q_busy;                   // a NAV_CHAP / NAV_SEEK was taken, its nav_done pending
    logic        tr_need;                  // the tracker wants a query
    logic        tr_pick;                  // ... at the next picture (after a watchdog)
    logic [63:0] nxt_key;                  // the next chapter's key {item u16, pts u48}
    logic        nxt_v;
    logic [26:0] mtmr;                     // the merge timer
    logic [26:0] wtmr;                     // the watchdog
    logic [4:0]  fcnt;                     // the flush's minimum
    logic [3:0]  icnt;                     // the queue's idle run
    logic [2:0]  htail;
    logic        nd_seen;                  // the landing's nav_done (may precede the flush's end)
    logic [2:0]  nd_err;
    logic [31:0] nd_land;
    logic [47:0] nd_skip;
    logic [32:0] nd_out;                   // the landed item's OUT and last (the watchdog's rewrite)
    logic        nd_last, nd_lat;
    logic [31:0] pt_item [0:3];            // the tag -> item map
    logic        hold_ok, hold_q;
    // THE HOLD: combinational from the reader's item_idx, which moves to the next item as the
    // walk enters S_ITEM and is tested there in the same cycle (a registered hold was one
    // cycle late: the bench's mock walk started a fifth item through it)
    // Its reference: the item on screen; from a seek's landing until its first picture, the
    // landed item (the display shows that one next -- the old picture's would let the walk
    // run four items ahead during the watchdog's wait and alias the landing's own tag)
    wire [31:0] hold_ref  = (sk == SK_FLUSH || sk == SK_LAND || sk == SK_PIC) ? nd_land : key_item;
    assign item_hold = hold_ok && (rd_item_idx > hold_ref) && (rd_item_idx - hold_ref >= 32'd4);
    logic [4:0]  arst;                     // the audio reset's count
    logic [4:0]  sfl;                      // P7: a subtitle change's flush count
    logic        sb_new_on;                //   and the state it applies
    logic        sb_host;                  //   ... asked by the disc (SUB_SET): its SUB event says so (data[6])
    logic [4:0]  sb_new_trk;
    logic        pe_sub;                   //   its SUB event, pending
    logic        pe_host, pe_host_b;       // A7: a HOST event pending, and its host_bad
    logic [3:0]  trk_new;
    logic        trk_v;
    logic        ended_q;                  // this END's TITLE_END posted
    // trick play (P6b4)
    logic [2:0]  tk_exit;                  // an exit asked, taken when no hop is in flight
    logic        hop_next;                 // the seek being issued is a hop (one_frame at its accept)
    logic [31:0] tk_item;                  // the carried target (the reader's clamped nav_skip)
    logic [47:0] tk_pts;
    logic [47:0] tk_req;                   // the last hop's requested PTS (the clamp's reference)
    logic        tk_edge, tk_sat;          // the last landing was clamped at the item's edge; the
                                           // last reverse request saturated at 0
    logic [31:0] tk_delta;                 // rate x ticks since the last hop was issued (saturating)
    logic [26:0] tk_wall;                  // cycles since then
    logic [8:0]  tk_div;                   // the strobe's prescaler (free-running)
    logic [31:0] ck_item;                  // a chapter burst's key, pressed during trick play
    logic [47:0] ck_pts;
    logic [15:0] ck_pl;                    // P9: a PLAYLIST's playlist, asked during trick play
    logic [15:0] pend_pl;                  // P9: the seek being issued is a PLAY of this playlist
    logic        pl_next;                  //   ... when set
    logic        tm_next;                  // P6c: the seek being issued is a TIME (pend_pts the time)
    logic        tm_land;                  //   ... the landing in flight is a TIME's: its answer is the key
    logic        q_goto;                   // P6c: the query in flight is Go To's
    logic        aud_rst_q;                // the track switch's reset (aud_rst adds trick play's)
    logic [15:0] rank_q;                   // the last tracked rank (CHAPTER posts on a change)
    // P6b7 telemetry: the landing's first picture, and the seek's latency
    logic        ld_arm;                   // latch land_pts at the next pickup (the mount's, the watchdog's)
    // P6b7 (the rig's chapter gate): a chapter press's landing keeps its projected chapter
    logic        g_press;                  // the gesture in flight began with a press (SK_QUERY)
    logic        tr_land;                  // the tracker's next answer is the first after such a landing
    logic [19:0] lat_c;                    // 90 kHz ticks since the seek machine left SK_NONE / SK_HOP
    // sporadic events wait here for a cycle with no other push (one push a cycle)
    logic        pe_bad, pe_trk, pe_end;
    logic        pe_na;                    // P8: UNAVAIL
    logic [3:0]  pe_bad_c, pe_trk_t;

    wire [47:0] sh48 = {15'd0, sh_pts};
    // trick play: running (no exit asked yet), its rate, the strobe, the next request's parts
    wire        trk       = (tk_speed != 2'd0);
    wire [31:0] tk_rate   = (tk_speed == 2'd1) ? TK_R1 : (tk_speed == 2'd2) ? TK_R2 : TK_R3;
    wire        tk_strobe = (tk_div == TICK_DIV[8:0] - 9'd1);
    wire [47:0] tk_d48    = {16'd0, tk_delta};
    wire        tk_le     = (tk_pts <= tk_d48);            // a reverse request reaches PTS 0
    assign aud_rst = aud_rst_q | one_frame;
    // Prev's 1 s rule: the pending key within 90,000 ticks after the current chapter's start
    wire [47:0] d_cur    = pend_pts - ch_cur[47:0];
    wire        same_cur = (pend_item[31:16] == 16'd0) && (pend_item[15:0] == ch_cur[63:48]);
    wire        near_cur = same_cur && (d_cur < 48'd90000);
    // the tracker: the shown key reached the next chapter's
    // (the NEW picture's item: key_item updates at this same pickup; and ordered by the key,
    //  so a later item with no chapter of its own, or a mark past its item's OUT, still counts)
    wire [31:0] pk_item  = pt_item[sh_ep];
    wire        reached  = nxt_v && ((pk_item > {16'd0, nxt_key[63:48]}) ||
                                     ((pk_item == {16'd0, nxt_key[63:48]}) && (sh48 >= nxt_key[47:0])));
    // the press queue's updates (one place, so a push and a pop in one cycle both count)
    wire        pq_push  = cmd_valid && titled && (cmd_code == C_NEXT || cmd_code == C_PREV) &&
                           (state != ST_STOP) && (pq_n != 4'd8);
    wire        pq_dir   = (cmd_code == C_PREV);
    wire        pq_pop   = nav_done && !q_track && (sk == SK_QUERY);
    wire        pq_clr   = mount || eject || ((sk == SK_NONE) && (pq_n != 4'd0) && !sh_pts_v);
    // the cycles the seek machine, the queries and the tracker may push an event on
    wire        ev_main  = nav_done || (sk == SK_PIC && (pick || wtmr >= WD_CYC[26:0]));
    // the tracker's query and Go To's (P6c): the port free, no gesture in flight; the tracker first
    wire        tr_go    = (sk == SK_NONE || sk == SK_HOP) && tr_need && sh_pts_v && pq_n == 4'd0 && !nav_req &&
                           !q_busy && titled && !start_wait;
    wire        gq_go    = (sk == SK_NONE || sk == SK_HOP) && gq_req && !q_goto && pq_n == 4'd0 && !nav_req &&
                           !q_busy && titled && !start_wait && !tr_go && !(cmd_valid && titled);
    assign gq_done = nav_done && q_goto;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; sk <= SK_NONE; titled <= 1'b0; start_wait <= 1'b0; have_tgt <= 1'b0;
            pend_item <= '0; pend_pts <= '0; proj <= '0; q_track <= 1'b0; q_busy <= 1'b0; tr_need <= 1'b0; tr_pick <= 1'b0;
            nxt_key <= '0; nxt_v <= 1'b0; mtmr <= '0; wtmr <= '0; fcnt <= '0; icnt <= '0; htail <= '0;
            nd_seen <= 1'b0; nd_err <= '0; nd_land <= '0; nd_skip <= '0; arst <= '0; trk_new <= '0; trk_v <= 1'b0;
            ended_q <= 1'b0; pq <= '0; pq_n <= '0; rank_q <= '0;
            pe_bad <= 1'b0; pe_trk <= 1'b0; pe_end <= 1'b0; pe_bad_c <= '0; pe_trk_t <= '0;
            sfl <= '0; sb_new_on <= 1'b0; sb_new_trk <= '0; sb_host <= 1'b0; pe_sub <= 1'b0; sub_on <= 1'b0; sub_track <= '0; sub_flush <= 1'b0;
            pe_host <= 1'b0; pe_host_b <= 1'b0; pe_na <= 1'b0;
            nav_req <= 1'b0; nav_op <= '0; nav_item <= '0; nav_pts <= '0; rd_hold <= 1'b0; seek_flush <= 1'b0;
            aud_rst_q <= 1'b0; aud_track <= '0; aud_realign <= 1'b0; freeze <= 1'b0; idle_screen <= 1'b0;
            one_frame <= 1'b0; tk_speed <= '0; tk_rev <= 1'b0; tk_exit <= EX_NONE; hop_next <= 1'b0;
            tk_item <= '0; tk_pts <= '0; tk_req <= '0; tk_edge <= 1'b0; tk_sat <= 1'b0; tk_delta <= '0;
            tk_wall <= '0; tk_div <= '0; ck_item <= '0; ck_pts <= '0;
            ck_pl <= '0; pend_pl <= '0; pl_next <= 1'b0; nav_pl <= '0; tm_next <= 1'b0; tm_land <= 1'b0; q_goto <= 1'b0;
            ep_we <= 1'b0; ep_wi <= '0; ep_in <= '0; ep_out <= '0; ep_last <= 1'b0; ep_skip <= 1'b0;
            hold_ok <= 1'b0; hold_q <= 1'b0; n_hold <= '0; nd_out <= '0; nd_last <= 1'b0; nd_lat <= 1'b0;
            for (int i = 0; i < 4; i++) pt_item[i] <= '0;
            seeking <= 1'b0; chapter <= '0; n_chapters <= '0; key_item <= '0;
            n_seeks <= '0; n_wd <= '0; n_bad <= '0; n_press_lost <= '0; last_nav_err <= '0;
            land_pts <= '0; seek_lat <= '0; ld_arm <= 1'b0; lat_c <= '0; g_press <= 1'b0; tr_land <= 1'b0;
            ev_push <= 1'b0; ev_pc <= '0; ev_pd <= '0;
        end else begin
            ep_we <= 1'b0; aud_realign <= 1'b0; ev_push <= 1'b0;
            // (before the commands: a press's reset of the merge timer must win)
            if (mtmr != 27'h7FFFFFF) mtmr <= mtmr + 27'd1;

            // ---- the reader's port: a request is held until taken; its answer frees it ----
            if (nav_req && nav_ready) begin nav_req <= 1'b0; q_busy <= 1'b1; end
            if (nav_done) begin q_busy <= 1'b0; q_goto <= 1'b0; end

            // ---- commands ----
            if (cmd_valid && titled && bare &&
                (cmd_code == C_FF || cmd_code == C_REW || cmd_code == C_SEEK || cmd_code == C_TIME ||
                 cmd_code == C_PLAYL)) begin
                pe_na <= 1'b1;                        // P8: a bare stream cannot seek
            end else if (cmd_valid && titled) begin
                case (cmd_code)
                    // (P6b4: during trick play these end it -- PLAY / PLAYPAUSE / PAUSE by the seek to
                    //  the shown key, STOP holding its picture. PAUSE plays as the PSP's X does: fj#57)
                    C_PLAYPAUSE: if (trk) begin tk_speed <= 2'd0; tk_exit <= EX_PLAY; end
                                 else if (state == ST_PLAY) state <= ST_PAUSE; else state <= ST_PLAY;
                    C_PAUSE:     if (trk) begin tk_speed <= 2'd0; tk_exit <= EX_PLAY; end
                                 else if (state == ST_PLAY) state <= ST_PAUSE;
                    C_PLAY:      if (trk) begin tk_speed <= 2'd0; tk_exit <= EX_PLAY; end
                                 else state <= ST_PLAY;
                    C_STOP:      if (trk) begin tk_speed <= 2'd0; tk_exit <= EX_STOP; end
                                 else state <= ST_STOP;
                    C_FF, C_REW: if (trk) begin
                        // the same direction: the next speed (3 stays); the opposite: play
                        if (tk_rev == (cmd_code == C_REW)) begin
                            if (tk_speed != 2'd3) tk_speed <= tk_speed + 2'd1;
                        end else begin tk_speed <= 2'd0; tk_exit <= EX_PLAY; end
                    end else if ((state == ST_PAUSE || (state == ST_PLAY && !one_frame)) && sk == SK_NONE &&
                                 pq_n == 4'd0 && sh_pts_v && !nav_req) begin
                        // (playing on a hop's stream the seek machine is about to restore play)
                        // enter it from the shown key: the first hop HOP_MIN from now
                        tk_speed <= 2'd1; tk_rev <= (cmd_code == C_REW); tk_exit <= EX_NONE;
                        tk_item <= key_item; tk_pts <= sh48; tk_edge <= 1'b0; tk_sat <= 1'b0;
                        tk_delta <= '0; tk_wall <= '0; have_tgt <= 1'b0; state <= ST_PLAY; sk <= SK_HOP;
                    end else if (n_press_lost != 8'hFF) n_press_lost <= n_press_lost + 8'd1;
                    C_NEXT, C_PREV: if (state != ST_STOP) begin
                        // (queued below, with the pops, in one place)
                        if (pq_n == 4'd8 && n_press_lost != 8'hFF) n_press_lost <= n_press_lost + 8'd1;
                        // a burst's first press: its key is the shown one NOW (the picture may
                        // move before the port is free); during a seek it is the pending
                        // target, kept
                        if (pq_n != 4'd8 && sk == SK_NONE && pq_n == 4'd0) begin
                            pend_item <= key_item; pend_pts <= sh48;
                        end
                        // P6b4: during trick play the burst's key is the picture shown now,
                        // kept aside (pend is the hop's) until the hop in flight lands
                        if (pq_n != 4'd8 && pq_n == 4'd0 && (trk || sk == SK_HOP)) begin
                            ck_item <= key_item; ck_pts <= sh48;
                        end
                        if (trk || sk == SK_HOP) begin tk_speed <= 2'd0; tk_exit <= EX_CHAP; end
                        mtmr <= '0;
                    end
                    C_SEEK: if (sk == SK_NONE && state != ST_STOP && cmd_item < rd_n_items) begin
                        pend_item <= cmd_item; pend_pts <= cmd_pts; have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0;
                        proj <= chapter;                   // (shown until the landing's tracker answer)
                    end else if (trk && cmd_item < rd_n_items) begin
                        // P6b4: ends trick play; the seek once the hop in flight has landed
                        tk_speed <= 2'd0; tk_exit <= EX_SEEK; ck_item <= cmd_item; ck_pts <= cmd_pts;
                    end else begin
                        pe_bad <= 1'b1; pe_bad_c <= cmd_code;
                        if (n_bad != 8'hFF) n_bad <= n_bad + 8'd1;
                    end
                    // P6c: Go To by time -- the reader's NAV_TIME finds the item
                    C_TIME: if (sk == SK_NONE && state != ST_STOP && rd_n_items != 32'd0) begin
                        pend_pts <= cmd_pts; tm_next <= 1'b1; have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0;
                        proj <= chapter;
                    end else if (trk && rd_n_items != 32'd0) begin
                        tk_speed <= 2'd0; tk_exit <= EX_TIME; ck_pts <= cmd_pts;
                    end else begin
                        pe_bad <= 1'b1; pe_bad_c <= cmd_code;
                        if (n_bad != 8'hFF) n_bad <= n_bad + 8'd1;
                    end
                    C_AUDIO, C_AUDIO_SET: if (arst == 5'd0 && trk_v && state != ST_STOP &&
                                              (cmd_code == C_AUDIO ? trk_other
                                                                   : (rd_aud_present[cmd_arg] && cmd_arg != aud_track))) begin
                        arst <= AUD_RST_CYC[4:0]; aud_rst_q <= 1'b1;
                        trk_new <= (cmd_code == C_AUDIO) ? trk_nxt : cmd_arg;
                    end
                    // P7: Off -> the lowest declared -> each higher -> Off (S2); a press with no
                    // declared track still answers (SUB off: the HUD says so)
                    // A7: without the UMD Main nothing changes; the HUD says why
                    C_SUB: if (!host_ok) begin
                        pe_host <= 1'b1; pe_host_b <= host_bad;
                    end else if (sfl == 5'd0 && titled && !start_wait) begin
                        sfl <= SUB_FL_CYC[4:0]; sb_host <= 1'b0;
                        sb_new_on  <= sub_on ? sb_more : sb_any;
                        sb_new_trk <= sub_on ? (sb_more ? sb_nxt : sub_track) : sb_low;
                    end
                    // P9: a playlist from a key (a menu's play): a Go To through NAV_PLAY
                    C_PLAYL: if (cmd_pl < rd_n_playlists && sk == SK_NONE && !trk) begin
                        pend_item <= cmd_item; pend_pts <= cmd_pts; pend_pl <= cmd_pl; pl_next <= 1'b1;
                        have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0;
                    end else if (cmd_pl < rd_n_playlists && trk) begin
                        tk_speed <= 2'd0; tk_exit <= EX_PLAYL; ck_item <= cmd_item; ck_pts <= cmd_pts; ck_pl <= cmd_pl;
                    end else begin
                        pe_bad <= 1'b1; pe_bad_c <= cmd_code;
                        if (n_bad != 8'hFF) n_bad <= n_bad + 8'd1;
                    end
                    // P9: the subtitles set outright (the SUB flush's way)
                    C_SUB_SET: if (!host_ok) begin
                        pe_host <= 1'b1; pe_host_b <= host_bad;
                    end else if (sfl == 5'd0 && titled && !start_wait && (!cmd_item[5] || rd_sub_present[cmd_item[4:0]])) begin
                        sfl <= SUB_FL_CYC[4:0]; sb_host <= 1'b1;
                        sb_new_on <= cmd_item[5]; sb_new_trk <= cmd_item[5] ? cmd_item[4:0] : sub_track;
                    end else begin
                        pe_bad <= 1'b1; pe_bad_c <= cmd_code;
                        if (n_bad != 8'hFF) n_bad <= n_bad + 8'd1;
                    end
                    default: begin
                        pe_bad <= 1'b1; pe_bad_c <= cmd_code;
                        if (n_bad != 8'hFF) n_bad <= n_bad + 8'd1;
                    end
                endcase
            end

            // ---- P7: a subtitle change: the flush, the new state in its last-but-one cycle ----
            if (sfl != 5'd0) begin
                sfl <= sfl - 5'd1;
                if (sfl == 5'd2) begin
                    sub_on <= sb_new_on; sub_track <= sb_new_trk; pe_sub <= 1'b1;
                end
            end else if (sub_on && !host_ok) begin
                // A7: the UMD Main is gone (no heartbeat): off, flushed -- nothing would decode
                // the units -- and the HUD says why
                sfl <= SUB_FL_CYC[4:0]; sb_new_on <= 1'b0; sb_new_trk <= sub_track; sb_host <= 1'b0;
                pe_host <= 1'b1; pe_host_b <= host_bad;
            end else if (rd_item_start && sub_on && !rd_sub_present[sub_track]) begin
                // the playing clip no longer declares it (a multi-item title): off, flushed.
                // At an item start only, when the reader's mask is complete (the audio rule's
                // note above: judged every cycle, every seek turned the subtitles off)
                sfl <= SUB_FL_CYC[4:0]; sb_new_on <= 1'b0; sb_new_trk <= sub_track; sb_host <= 1'b0;
            end
            sub_flush <= (sfl > 5'd1);

            // ---- the audio switch: the chain reset; the track and the realign in its last cycle ----
            if (arst != 5'd0) begin
                arst <= arst - 5'd1;
                if (arst == 5'd2) begin
                    aud_track <= trk_new; aud_realign <= 1'b1;
                    pe_trk <= 1'b1; pe_trk_t <= trk_new;
                end
                if (arst == 5'd1) aud_rst_q <= 1'b0;
            end else if ((rd_item_start || bare) && trk_any && (!trk_v || !rd_aud_present[aud_track])) begin
                // the default: the lowest declared track (a mount, once the title's first CLP is
                // read; a clip that does not declare the current one). Judged AT an item start
                // only (P7, found on the rig 2026-09-30): umd_reader clears the masks at every
                // CLP header and fills them stream by stream before the item start, so judged
                // every cycle a seek's CLP re-read reset a chosen track to the lowest.
                aud_track <= trk_low; trk_v <= 1'b1;
                if (trk_v) aud_realign <= 1'b1;
            end

            // ---- trick play's clocks (P6b4; before the seek machine: a hop's issue resets them) ----
            tk_div <= tk_strobe ? 9'd0 : tk_div + 9'd1;
            if (trk && tk_strobe) tk_delta <= (tk_delta > 32'hFFFF_FFFF - tk_rate) ? 32'hFFFF_FFFF : tk_delta + tk_rate;
            if (trk && tk_wall != 27'h7FFFFFF) tk_wall <= tk_wall + 27'd1;

            // ---- the seek machine ----
            case (sk)
                SK_NONE: begin
                    if (pq_n != 4'd0 && sh_pts_v && state != ST_STOP && !q_busy && !nav_req) begin
                        // a gesture begins from its first press's key (pend, latched then)
                        have_tgt <= 1'b0; proj <= chapter; g_press <= 1'b1;
                        sk <= SK_QUERY;
                    end else if (pq_n != 4'd0 && !sh_pts_v) begin
                        // nothing shown yet: nothing to skip from (the queue is cleared below)
                        if (n_press_lost != 8'hFF) n_press_lost <= n_press_lost + 8'd1;
                    end else if (pq_n == 4'd0 && one_frame && state == ST_PLAY && sh_pts_v && !(cmd_valid && titled)) begin
                        // P6b4: playing, but the decoder's stream is a hop's (it ended after one
                        // frame): play resumes by a seek to the shown key -- the last hop's I
                        pend_item <= key_item; pend_pts <= sh48; sk <= SK_SEEK; g_press <= 1'b0;
                    end
                end
                SK_HOP: begin
                    // P6b4, between hops: the reader held; an exit, or the next hop when due
                    rd_hold <= 1'b1;
                    if (tk_exit != EX_NONE) begin
                        tk_exit <= EX_NONE; sk <= SK_NONE;
                        if (!one_frame) rd_hold <= 1'b0;           // no hop made: playing still
                        case (tk_exit)
                            EX_STOP:  state <= ST_STOP;
                            EX_CHAP:  begin pend_item <= ck_item; pend_pts <= ck_pts; end
                            EX_SEEK:  begin pend_item <= ck_item; pend_pts <= ck_pts; have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0; end
                            EX_PLAYL: begin
                                pend_item <= ck_item; pend_pts <= ck_pts; pend_pl <= ck_pl; pl_next <= 1'b1;
                                have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0;
                            end
                            EX_TIME:  begin pend_pts <= ck_pts; tm_next <= 1'b1; have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0; end
                            default: ;                            // EX_PLAY: SK_NONE seeks to the shown key
                        endcase
                    end else if (tk_wall >= HOP_MIN[26:0] && !nav_req && !q_busy && !(cmd_valid && titled)) begin
                        // (not in a command's cycle: an exit asked now is seen next cycle, before
                        //  another hop -- P6b7, the bench's ntwicm_2 caught a PLAY and a hop in one cycle)
                        tk_delta <= '0; tk_wall <= '0; tk_sat <= 1'b0;
                        if (tk_edge) begin
                            // the last landing was clamped at the item's edge: cross, or at the
                            // title's end / start, play resumes
                            if (!tk_rev && (tk_item + 32'd1 < rd_n_items)) begin
                                pend_item <= tk_item + 32'd1; pend_pts <= '0; tk_req <= '0; hop_next <= 1'b1; sk <= SK_SEEK;
                            end else if (tk_rev && tk_item != 32'd0) begin
                                pend_item <= tk_item - 32'd1; pend_pts <= '1; tk_req <= '1; hop_next <= 1'b1; sk <= SK_SEEK;
                            end else begin
                                tk_speed <= 2'd0; tk_exit <= EX_PLAY;
                            end
                        end else if (!tk_rev) begin
                            pend_item <= tk_item; pend_pts <= tk_pts + tk_d48; tk_req <= tk_pts + tk_d48;
                            hop_next <= 1'b1; sk <= SK_SEEK;
                        end else begin
                            pend_item <= tk_item; pend_pts <= tk_le ? 48'd0 : tk_pts - tk_d48;
                            tk_req <= tk_le ? 48'd0 : tk_pts - tk_d48; tk_sat <= tk_le;
                            hop_next <= 1'b1; sk <= SK_SEEK;
                        end
                    end
                end
                SK_QUERY: begin
                    if (!nav_req && !q_busy && !q_track) begin
                        nav_req <= 1'b1; nav_op <= NAV_CHAP; nav_item <= pend_item; nav_pts <= pend_pts;
                    end
                end
                SK_MERGE: begin
                    if (pq_n != 4'd0) sk <= SK_QUERY;
                    else if (mtmr >= MERGE_CYC[26:0]) sk <= have_tgt ? SK_SEEK : SK_NONE;
                end
                SK_SEEK: begin
                    if (!nav_req && !q_busy) begin
                        nav_req <= 1'b1; nav_op <= pl_next ? NAV_PLAY : tm_next ? NAV_TIME : NAV_SEEK;
                        nav_item <= pend_item; nav_pts <= pend_pts; nav_pl <= pend_pl;
                    end
                    if (nav_req && nav_ready && (nav_op == NAV_SEEK || nav_op == NAV_PLAY || nav_op == NAV_TIME)) begin
                        // the accepting edge: the reader flushes; so does everything behind it
                        seek_flush <= 1'b1; rd_hold <= 1'b1; fcnt <= FLUSH_MIN[4:0]; icnt <= '0;
                        nd_seen <= 1'b0; nd_lat <= 1'b1; n_seeks <= n_seeks + 16'd1; sk <= SK_FLUSH;
                        one_frame <= hop_next; hop_next <= 1'b0;          // P6b4: a hop's landing, or not
                        if (state == ST_PAUSE || pl_next) state <= ST_PLAY;   // a seek resumes play; a PLAY from STOP too
                        pl_next <= 1'b0; tm_next <= 1'b0; tm_land <= tm_next;
                    end
                end
                SK_FLUSH: begin
                    if (fcnt != 5'd0) fcnt <= fcnt - 5'd1;
                    icnt <= rec_idle ? ((icnt == 4'hF) ? icnt : icnt + 4'd1) : 4'd0;
                    if (fcnt == 5'd0 && icnt >= IDLE_MIN[3:0]) begin
                        seek_flush <= 1'b0; htail <= HOLD_TAIL[2:0]; wtmr <= '0; sk <= SK_LAND;
                    end
                end
                SK_LAND: begin
                    if (htail != 3'd0) htail <= htail - 3'd1;
                    else rd_hold <= 1'b0;
                    // (the landing's entry was written at its item start, below)
                    if (nd_seen && htail == 3'd0) sk <= SK_PIC;
                end
                SK_PIC: begin
                    if (pick) begin
                        // (P6b4: a hop's picture -- the next hop, or trick play's exit, from SK_HOP)
                        sk <= one_frame ? SK_HOP : SK_NONE; have_tgt <= 1'b0; tr_need <= 1'b1; nxt_v <= 1'b0;
                        if (!one_frame) begin ev_push <= 1'b1; ev_pc <= EV_SEEK_DONE; ev_pd <= n_seeks; seek_lat <= lat_c; end
                        tr_land <= g_press && !one_frame;
                    end else if (ended && !one_frame) begin
                        // the display ENDED with no picture: the landing's target lay past every
                        // picture and the stream's END came inside the skip (disp_ctl's skip_eos;
                        // an OUT past the title's content, display.md §11) -- the seek is done, the
                        // title's end follows (pe_end, below), no watchdog. A hop's entries take no
                        // skip: its picture always comes (one_frame keeps the watchdog)
                        // (land_pts holds: this landing showed no picture)
                        sk <= SK_NONE; have_tgt <= 1'b0; tr_pick <= 1'b1; nxt_v <= 1'b0; key_item <= nd_land;
                        tr_land <= 1'b0;
                        ev_push <= 1'b1; ev_pc <= EV_SEEK_DONE; ev_pd <= n_seeks;
                    end else if (wtmr >= WD_CYC[26:0] && !rd_item_start) begin
                        // no picture: the landed item's entry rewritten without a skip -- the
                        // display shows whatever arrives -- counted, never a hang
                        ep_we <= 1'b1; ep_wi <= nd_land[1:0]; ep_in <= nd_skip[32:0]; ep_out <= nd_out;
                        ep_last <= nd_last; ep_skip <= 1'b0;
                        // (the tracker asks from the first NEW picture, not the one held; the
                        //  hold measures from the landed item, which shows next -- the held
                        //  picture's would release the walk onto the landing's own tag)
                        sk <= one_frame ? SK_HOP : SK_NONE; have_tgt <= 1'b0; tr_pick <= 1'b1; nxt_v <= 1'b0; key_item <= nd_land;
                        if (n_wd != 8'hFF) n_wd <= n_wd + 8'd1;
                        ld_arm <= 1'b1;                            // (land_pts: its first picture, later)
                        tr_land <= 1'b0;
                        ev_push <= 1'b1; ev_pc <= EV_SEEK_WD; ev_pd <= n_seeks;
                    end
                end
                default: sk <= SK_NONE;
            endcase
            if ((sk == SK_LAND || sk == SK_PIC) && !freeze && wtmr != 27'h7FFFFFF) wtmr <= wtmr + 27'd1;
            // P6b7 telemetry: a landing's first picture (sh_pts is the new store's when pick is
            // seen: disp_ctl moves both in one cycle), and the latency from the gesture's first
            // action (the query of a press, the merge window included; a Go To's seek; a trick
            // exit's restoring seek) to that picture
            if (pick && (ld_arm || sk == SK_PIC)) begin land_pts <= sh_pts; ld_arm <= 1'b0; end
            if (sk == SK_NONE || sk == SK_HOP) lat_c <= '0;
            else if (tk_strobe && lat_c != 20'hFFFFF) lat_c <= lat_c + 20'd1;
            // the landing's answer (it can come before the flush ends: kept)
            if (nav_done && !q_track && (sk == SK_FLUSH || sk == SK_LAND)) begin
                nd_seen <= 1'b1; nd_err <= nav_err; nd_land <= nav_land; nd_skip <= nav_skip;
                last_nav_err <= nav_err;
                // P6c: a TIME's pending key is where the reader put it (a press during the seek
                // is judged from there, as from a Go To's key)
                if (tm_land) begin pend_item <= nav_land; pend_pts <= nav_skip; tm_land <= 1'b0; end
                if (nav_err != NE_NONE) begin ev_push <= 1'b1; ev_pc <= EV_NAV_ERR; ev_pd <= {13'd0, nav_err}; end
                if (one_frame) begin
                    // P6b4: the carried target is the reader's clamped one; a clamp that moved it
                    // marks the item's edge. A hop the reader refused ends trick play.
                    tk_item <= nav_land; tk_pts <= nav_skip;
                    tk_edge <= tk_rev ? (tk_sat || nav_skip > tk_req) : (nav_skip < tk_req);
                    if (nav_err != NE_NONE && trk) begin tk_speed <= 2'd0; tk_exit <= EX_PLAY; end
                end
            end

            // ---- a press's answer: judged from the pending key (umd_nav_ref.presses) ----
            if (nav_done && !q_track && sk == SK_QUERY) begin
                last_nav_err <= nav_err;
                sk <= SK_MERGE;
                if (nav_err != NE_NONE) begin
                    ev_push <= 1'b1; ev_pc <= EV_NAV_ERR; ev_pd <= {13'd0, nav_err};
                end else if (!pq_head) begin                               // Next
                    if (ch_valid[2]) begin
                        pend_item <= {16'd0, ch_next[63:48]}; pend_pts <= ch_next[47:0];
                        have_tgt <= 1'b1; proj <= ch_rank + 16'd1;
                    end else begin
                        ev_push <= 1'b1; ev_pc <= EV_NO_CHAPTER; ev_pd <= ch_rank;
                    end
                end else if (ch_valid[0]) begin                              // Prev
                    if (near_cur && ch_rank > 16'd1 && ch_valid[1]) begin
                        pend_item <= {16'd0, ch_prev[63:48]}; pend_pts <= ch_prev[47:0]; proj <= ch_rank - 16'd1;
                    end else begin
                        pend_item <= {16'd0, ch_cur[63:48]}; pend_pts <= ch_cur[47:0]; proj <= ch_rank;
                    end
                    have_tgt <= 1'b1;
                end
            end

            // ---- the chapter tracker ----
            if (pick && (reached || tr_pick)) begin tr_need <= 1'b1; tr_pick <= 1'b0; end
            if (tr_go) begin
                nav_req <= 1'b1; nav_op <= NAV_CHAP; nav_item <= key_item; nav_pts <= sh48;
                q_track <= 1'b1; tr_need <= 1'b0;
            end else if (gq_go) begin
                // P6c: Go To's chapter selector (its answer is goto_ctl's alone: gq_done)
                nav_req <= 1'b1; nav_op <= NAV_CHAP; nav_item <= {16'd0, gq_key[63:48]}; nav_pts <= gq_key[47:0];
                q_goto <= 1'b1;
            end
            if (nav_done && q_track) begin
                q_track <= 1'b0; tr_land <= 1'b0;
                if (nav_err == NE_NONE) begin
                    nxt_key <= ch_next; nxt_v <= ch_valid[2]; n_chapters <= ch_count;
                    if (tr_land && ch_rank < chapter) begin
                        // P6b7: a chapter press's landing shows the picture CONTAINING the mark (D2),
                        // which may begin before it (3:2 film: 1,502 / 3,004 ticks on Akira; one tick
                        // on The Rock). Ranked by its PTS it is the previous chapter: keep the
                        // projected one (the next pickup crosses the mark: `reached`, nxt_key being
                        // that mark, asks again and agrees). The rig's chapter gate found the HUD
                        // showing "Chapter 5" for one picture of a jump to 6. (rank_q is left: the
                        // CHAPTER event posts at that crossing, as for a landing on the mark itself.)
                    end else begin
                        if (ch_rank != rank_q) begin
                            ev_push <= 1'b1; ev_pc <= EV_CHAPTER; ev_pd <= ch_rank;
                        end
                        rank_q <= ch_rank;
                        if (sk == SK_NONE || sk == SK_HOP) chapter <= ch_rank;
                    end
                end else begin
                    last_nav_err <= nav_err;
                    ev_push <= 1'b1; ev_pc <= EV_NAV_ERR; ev_pd <= {13'd0, nav_err};
                end
            end
            // the projected chapter while a gesture is pending, until the landing
            if (sk == SK_MERGE || sk == SK_SEEK || sk == SK_FLUSH || sk == SK_LAND || sk == SK_PIC) begin
                if (have_tgt) chapter <= proj;
            end

            // ---- the title's end ----
            // once per END, when no seek is in flight: an END that came DURING one (a landing past
            // every picture, above) is posted when the seek machine is back at rest; the resync
            // clears `ended`, and with it the flag (a hop's stream ends: P6b4, one_frame)
            if (!ended) ended_q <= 1'b0;
            else if (!ended_q && sk == SK_NONE && !one_frame) begin pe_end <= 1'b1; ended_q <= 1'b1; end

            // ---- every item start (the mount's, the walk's, a seek's landing): its entry in
            //      the display's item table {IN or the seek's target, OUT, last, skip} ----
            if (rd_item_start) begin
                ep_we <= 1'b1; ep_wi <= rd_item_idx[1:0]; ep_in <= nav_skip[32:0]; ep_out <= rd_item_out[32:0];
                ep_last <= (rd_item_idx == rd_n_items - 32'd1);
                // a hop: its I on arrival; P6c, a TIME past the end too (it plays out to END)
                // (END_GUARD: the reader's clamp below OUT, umd_reader.sv -- the two must agree:
                //  the reader's is checked against umd_nav_ref by run_umd_reader, this copy against
                //  the bench's mock reader by run_player_ctl G10)
                // (P8: a bare file's item no skip -- nothing before its IN to drop, and the reader
                //  leaves nav_skip unwritten there)
                ep_skip <= !one_frame && !bare && !(tm_land && rd_item_idx == rd_n_items - 32'd1 &&
                                           nav_skip == rd_item_out - END_GUARD);
                pt_item[rd_item_idx[1:0]] <= rd_item_idx;
                if (nd_lat) begin
                    nd_lat <= 1'b0; nd_out <= rd_item_out[32:0]; nd_last <= (rd_item_idx == rd_n_items - 32'd1);
                end
                if (start_wait) begin start_wait <= 1'b0; key_item <= rd_item_idx; end
            end
            // the shown picture's item
            if (pick) key_item <= pt_item[sh_ep];
            // THE HOLD's qualifier (the compare is combinational, below); counted per episode
            // (lifted only while a seek waits for the reader or its landing is not known yet)
            hold_ok <= titled && !start_wait && ((sk == SK_NONE || sk == SK_QUERY || sk == SK_MERGE || sk == SK_HOP) ||
                                                 ((sk == SK_FLUSH || sk == SK_LAND || sk == SK_PIC) && nd_seen));
            hold_q  <= item_hold;
            if (item_hold && !hold_q && n_hold != 8'hFF) n_hold <= n_hold + 8'd1;

            // ---- the press queue: a push, a pop (the head answered), or both in one cycle ----
            if (pq_clr) pq_n <= '0;
            else case ({pq_push, pq_pop})
                2'b10: begin pq[pq_n[2:0]] <= pq_dir; pq_n <= pq_n + 4'd1; end
                2'b01: begin pq <= {1'b0, pq[7:1]}; pq_n <= pq_n - 4'd1; end
                2'b11: begin
                    pq <= {1'b0, pq[7:1]};
                    pq[pq_n[2:0] - 3'd1] <= pq_dir;
                end
                default: ;
            endcase

            // ---- a mount / an eject: the title's state, synchronously (never the flush) ----
            if (mount || eject) begin
                state <= mount ? ST_PLAY : ST_IDLE; titled <= mount; start_wait <= mount;
                sk <= SK_NONE; have_tgt <= 1'b0; pq_n <= '0; q_track <= 1'b0; q_busy <= 1'b0; tr_need <= 1'b0; tr_pick <= 1'b1;
                nxt_v <= 1'b0; nav_req <= 1'b0; seek_flush <= 1'b0; rd_hold <= 1'b0; arst <= '0; aud_rst_q <= 1'b0;
                one_frame <= 1'b0; tk_speed <= 2'd0; tk_exit <= EX_NONE; hop_next <= 1'b0; pl_next <= 1'b0;
                tm_next <= 1'b0; tm_land <= 1'b0; q_goto <= 1'b0;
                trk_v <= 1'b0; chapter <= '0; n_chapters <= '0; key_item <= '0; rank_q <= '0; nd_lat <= 1'b0;
                ld_arm <= mount; g_press <= 1'b0; tr_land <= 1'b0;
                sub_on <= 1'b0; sfl <= '0; pe_sub <= 1'b0;     // P7 (S1): off at a mount
                pe_na <= 1'b0;
            end

            // ---- the sporadic events, on a cycle with no other push (ev_main: every cycle
            //      that may push above -- ev_push itself is last cycle's) ----
            if (!ev_main) begin
                if (pe_bad) begin
                    ev_push <= 1'b1; ev_pc <= EV_BAD; ev_pd <= {12'd0, pe_bad_c}; pe_bad <= 1'b0;
                end else if (pe_trk) begin
                    ev_push <= 1'b1; ev_pc <= EV_TRACK; ev_pd <= {12'd0, pe_trk_t}; pe_trk <= 1'b0;
                end else if (pe_end) begin
                    ev_push <= 1'b1; ev_pc <= EV_TITLE_END; ev_pd <= '0; pe_end <= 1'b0;
                end else if (pe_sub) begin
                    ev_push <= 1'b1; ev_pc <= EV_SUB; ev_pd <= {9'd0, sb_host, sub_on, sub_track}; pe_sub <= 1'b0;
                end else if (pe_host) begin
                    ev_push <= 1'b1; ev_pc <= EV_HOST; ev_pd <= {15'd0, pe_host_b}; pe_host <= 1'b0;
                end else if (pe_na) begin
                    ev_push <= 1'b1; ev_pc <= EV_UNAVAIL; ev_pd <= '0; pe_na <= 1'b0;
                end
            end

            // ---- the outputs that follow the state ----
            seeking     <= (sk != SK_NONE);
            // (a gesture freezes once a press has found a target: Next at the last chapter
            //  leaves playback alone)
            freeze      <= (state == ST_PAUSE) || (state == ST_STOP) ||
                           (have_tgt && (sk == SK_QUERY || sk == SK_MERGE)) || (sk == SK_SEEK) || (sk == SK_FLUSH);
            idle_screen <= (state == ST_STOP);
        end
    end

endmodule

`default_nettype wire
