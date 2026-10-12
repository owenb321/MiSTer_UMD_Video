// menu_host_check.c -- P9 M3's integration bench: a disc's menus run as the UMD Main will run them.
// The real engine (menu/), the real menu host (umd_menu_host.c: the numbering boundary, the mount,
// the levels, the keys, the resume point) and the real host-row logic (umd_menu_logic.c) against a
// model of the core's side (umd/umd_host.sv's take conditions, player_ctl's answers), reading the
// disc through umd_iso + umd_playlist as the Main does.
//
//   menu_host_check IMAGE.iso [--start NAME | --lang XX | --lang-opt N (the OSD's Menu Language)] [--ms N] [--key T:NAME ...] [--relaunch T ...]
//                   [--seed N] [--lat LO:HI] [--mount-lat MS] [--drop PERMILLE] [--shots N]
//                   [--skip T:POS ...] [--idle T] [--narrow N,...] [--menu-aa T:N] [--menus-off]
//
// The startup RCO: umd_mh_pick_start over RESOURCE/ (--lang, EN by default), or --start.
// Prints the engine's trace and the core's (tools/menu_gate.py --host scores it with the same
// checkpoints as menu_run, its "resume" read as a PLAYLIST at a place):
//   PLAYER play playlist N chapter C   a PLAYLIST taken (N the script's number: the INDEX + 1, C the
//                                      chapter whose start it names) -- or "at T ms" (not a chapter
//                                      start: a resume), from its playlist's start
//   PLAYER stop / PLAYER busy: playlist N refused / PLAYER audio n / PLAYER subtitles ...
//   PLAYER chapter C / PLAYER end of playlist N
//   CORE levels grab 0x... ui U menu M  the levels the host wrote, at each change
//   CORE key NAME -> host | transport stop | transport pause | ignored
//   RELAUNCH: quit / ... kept, resume point kept|none   QUIT (P9-6): ...
//
// The core: a mount auto-plays the longest playlist (the reader's rule); a PLAYLIST taken while a
// seek is in flight is refused (BAD, 0-3 ms later); a seek takes --lat ms (seeded, 50-400 default)
// and lands at its (item, PTS); the picture's PTS advances 90 a ms through the items; CHAPTER posts
// when the rank changes (never reset by a playlist: the host posts the start chapter), the CHAPTER
// word 0 through a seek and 0-40 ms after its landing (the tracker's ranking, as player_ctl); TITLE_END at
// the last item's OUT (the state stays PLAY on the last picture, as player_ctl's, till a seek). A key at T goes to the host when the GRAB word has its bit,
// else the transport takes it (Circle stops, Cross pauses, Start plays / pauses). A relaunch: the
// host quits (onExit, the kept text), the core remounts (the feature again, the counts and seqs kept),
// a NEW logic state (adopting the seqs) and a NEW host started with the kept text; after a QUIT
// (P9-6) it is the image selected again, with the text the quit kept. --drop loses that
// many writes in 1000 (the heartbeat resends). --skip moves the playing title's place to POS ms at T,
// as if the time had passed (a long film's end, reached in seconds): chapters post on the rank change.
// --menu-aa T:N: from T the core reports a menu's fit to a 4:3 CRT N (0 Fit 1 Letterbox 2 Crop; the
// 480i raster under Analog Aspect: analog.md S7); repeatable (in time order); "CORE menu fit N", and each frame put reports the
// box it draws in ("CORE frame rows Y0-Y1 cols X0-X1" / "CORE frame empty") when it changes.
// --menus-off: the OSD's Disc Menus Off at every mount (M3b): the runner arms nothing.
// --walk [IDLE_MS]: THE M4 LIBRARY PROBE (docs/p9.md M4) -- a user who presses Cross on what a page
// offers: when a page that draws is up with the keys grabbed and nothing has changed for IDLE_MS
// (default 6000: no level, play, focus, page or resource change), press Cross; if the last press
// changed nothing, Down (then Right, then Cross again: a page whose default does nothing). "WALK
// <KEY> (focus F, page P)" each press; "WALK FEATURE playlist N" the first CONTENT play (the host's
// menuMode 0) of a playlist at least half the longest's duration (PLAYLIST.UMD: the reader's own
// choice of the feature) -- the page pressed last is the disc's way to its feature. --walk-max N:
// presses at most (default 12). Then Square 5 s into the feature (the PSP's way back to a disc's menu,
// onMenu): "WALK MENU AGAIN" when a page that draws comes up within 15 s, else "WALK NO MENU after
// Square"; then Cross IDLE_MS after that page came up: "WALK BACK resumed|restarted|other
// playlist N" -- the feature continued at its place, from its start, or something else played
// (data on the resume point's rule, not a verdict: a menu's default may be Play, not Resume);
// --walk-end MS: end the run MS after that (default 3000);
// --walk-shot FILE.png: each press writes the plane (over a checkerboard) there, so the file ends
// as the page the feature was played from.
// --powercut T (RS1, docs/resume.md): the power cut at T -- nothing runs (no onExit, no store: the card
// keeps what the runner last wrote), then the image is launched again as at power-on: a new runner, the
// mount. "POWERCUT: N bytes on the card, resume point kept playlist P at X ms | none"; each store to the
// card prints "CARD store ID: N bytes, <its R line>[ + user data]". --card-full: every store refused
// ("CARD full: ID not written"; the runner must trace it and retry at the next store).
// --sub T (RS2): subtitles on, track 0, at T (the transport's Subtitle button); SELECT is the transport's
// Audio (the next of two tracks). --kept TEXT: the card holds TEXT (its R line) for the disc at the start.
// --start-lat MS (fj#76): the start takes MS ms, as the rig's does (the kept text from the card, the RCO
// loaded and parsed, the script's start, before its first play() is queued). The glue's two threads:
// the poll side steps the logic on while the worker is inside the start, and the events it reads wait
// in the mailbox until the worker's next drain -- after the start. The bench is single-threaded (step
// then feed, every ms), so at the tick that fires the start it runs MS ms of the core and the logic's
// steps first, holding their events, then the start, then feeds what it held. The keys, skips and
// relaunches timed inside those MS ms are not looked at. 0 (the default): the start is instant.
// --draw-trace T: the draw list of the first frame rendered at or after T (DRAW lines: the quad's box,
// alpha, image and its size; menu.c collect_quad) -- the renderer's cost per layer (fj#74).
// --no-item-cache: the renderer's item cache off (fj#74): CORE INC compares every clipped draw with the full
// render again, as before the cache (an item's entry is drawn unclipped).
// --idle T: the OSD's Reset at T (the core idle, its image unloaded; no Main hook fires). The core
// flags a frame written into the plane on screen or about to show (CORE PLANE WRITE: END not ok).
#include "umd_menu_run.h"
#include "umd_host_proto.h"
#include "img_decode.h"
#include "umd_iso.h"

#include <png.h>
#include <time.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rng;
#ifdef MENU_PROF
static void prof_line(const char *l, void *ud) { (void)ud; printf("%8u %s\n", 0u, l); }
#endif
// --start-lat's mailbox: the poll side's reads and events, held while the worker is inside the start
enum { MBOX_MAX = 2000 };
static struct { int have; umd_menu_rd rd; umd_menu_event ev[UMD_MENU_EVQ]; int nev; } mbox[MBOX_MAX];
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static umd_playlists PL;
static umd_iso ISO;
static FILE *isof;
static uint32_t now;
static int lat_lo = 50, lat_hi = 400, drop_pm, mount_lat = -1, start_lat;
static uint32_t draw_trace_at;
static int no_item_cache;               // --no-item-cache: menu_item_cache(0) (fj#74: CORE INC sees clipped draws again)
static uint64_t frames_hash = 1469598103934665603ull;   // FNV-1a over every frame the runner flipped (fj#74)          // --draw-trace T: the draw list of the first frame rendered at or after T
static uint8_t narrow[65536];                  // --narrow: the playlists (indices) whose pictures are 4:3
static int menu_aa;                              // --menu-aa T:N: the core's menu fit (HOST_RD AUDIO [12:11]) from T
static struct { uint32_t at; int fit; } aa_q[16];  // (repeatable, in time order: M4h's fit changes mid-menu)
static int n_aa, aa_i;
static int menus_off;                           // --menus-off: the OSD's Disc Menus Off (M3b)
static int fr_y0 = -2, fr_y1 = -2, fr_x0, fr_x1;   // the drawn box of the last frame put (printed at a change)
static uint32_t walk_idle, walk_max = 12, walk_end = 3000, walk_n, walk_last, walk_change, walk_feature, walk_sq, walk_done;
static uint32_t walk_menu_again, walk_back_at;
static int walk_feature_pl = -1;
static int walk_last_key = -1;
static const char *walk_shot;
static uint64_t pl_longest;
static double rend_us, rend_max;                // --: the frames' render time on this PC (us)                     // the longest playlist's duration (90 kHz)
static uint8_t *inc_ref;                         // M4d: the whole render each incremental frame is checked against
static unsigned n_inc, inc_bad;
static int drawn_fit = -1;                       // RENDER, PIPELINED: the CRT fit the drawn frame was drawn with
static unsigned stale_put;                       // ... a frame put with another fit than the one it was drawn with

static size_t iso_rd(void *ud, uint64_t off, void *buf, size_t n)
{
	FILE *f = (FILE *)ud;
	if (fseeko(f, (off_t)off, SEEK_SET)) return 0;
	return fread(buf, 1, n, f);
}

// a playlist's place in ms from its start
static uint32_t pos_ms(uint16_t pl, uint32_t item, uint64_t pts)
{
	const umd_pl_entry *e = &PL.e[pl];
	uint64_t acc = 0;
	for (uint32_t k = 0; k < item && k < e->nitems; k++) acc += e->items[k].out > e->items[k].in ? e->items[k].out - e->items[k].in : 0;
	if (item < e->nitems && pts > e->items[item].in) acc += pts - e->items[item].in;
	return (uint32_t)(acc / 90);
}
// the rank: chapters whose start is at or before (item, pts)
static uint16_t rank_at(uint16_t pl, uint32_t item, uint64_t pts)
{
	uint16_t r = 0;
	for (uint32_t c = 1; c <= PL.e[pl].nchapters; c++) {
		uint32_t ci; uint64_t cp;
		if (umd_pl_chapter(&PL, pl, c, &ci, &cp)) break;
		if (ci < item || (ci == item && cp <= pts)) r = (uint16_t)c;
	}
	return r;
}

static uint64_t pl_dur(uint32_t i)
{
	uint64_t d = 0;
	for (uint32_t k = 0; k < PL.e[i].nitems; k++) d += PL.e[i].items[k].out > PL.e[i].items[k].in ? PL.e[i].items[k].out - PL.e[i].items[k].in : 0;
	return d;
}

static umd_menu_run R;

// ---- the core -----------------------------------------------------------------------------------
static struct {
	uint8_t  cmd_ack, flip_ack, pcm_ack, win_ack;
	uint8_t  c_held_seq, t_fseq_q, t_pseq_q;
	int      hc_v, hf_req, hp_req, hc_wait, hf_wait, hp_wait;
	umd_menu_pcmd hc;
	uint16_t fc[8], fd[8];
	uint8_t  ev_wc, ev_rc, ev_rp_h, ev_lost;
	int      state, seeking, shown, seek_left, sub_on, sub_track, audio_track;
	int      ended;                 // the title's END: PLAY held on the last picture (player_ctl), till a seek
	uint16_t playlist, chapter, rank_q, target, grab;
	int      rank_left;             // ms until the tracker ranks the landing (the word 0 till then)
	uint32_t item, t_item;
	uint64_t pts, t_pts;
	int      ui, menu, win_on, mute;
	uint16_t win_x, win_y, win_w, win_h;
	uint32_t n_flips;
	int      hf_buf, front, plane_bad;   // the flip in flight's buffer, the buffer shown (-1 none)
	uint32_t hp_start, hp_len; int hp_st; // the PCM trigger held
	uint32_t n_pcm;
	uint8_t  press_ack;             // P6d / fj#72: the last press record taken (the core echoes it at once)
} C;

static struct { uint32_t due; uint16_t code, data; } dly[64];
static int n_dly;

static void ev_push(uint16_t code, uint16_t data)
{
	if ((uint8_t)(C.ev_wc - C.ev_rc) >= 8) { if (C.ev_lost != 0xFF) C.ev_lost++; printf("%8u CORE event lost (code %u)\n", now, code); return; }
	C.fc[C.ev_wc & 7] = code; C.fd[C.ev_wc & 7] = data;
	C.ev_wc++;
}
static void ev_later(uint32_t delay, uint16_t code, uint16_t data)
{
	if (n_dly < 64) { dly[n_dly].due = now + delay; dly[n_dly].code = code; dly[n_dly].data = data; n_dly++; }
}

static void seek_to(uint16_t pl, uint32_t item, uint64_t pts)
{
	C.seeking = 1; C.shown = 0; C.target = pl; C.t_item = item; C.t_pts = pts; C.chapter = 0; C.rank_left = 0; C.ended = 0;
	C.seek_left = lat_lo + (int)(rnd() % (uint32_t)(lat_hi - lat_lo + 1));
	if (C.state == 0 || C.state == 3) C.state = 1;
}

static void mount(void)
{
	uint16_t best = 0; uint64_t bd = 0;
	for (uint32_t i = 0; i < PL.n; i++) {
		uint64_t d = 0;
		for (uint32_t k = 0; k < PL.e[i].nitems; k++) d += PL.e[i].items[k].out > PL.e[i].items[k].in ? PL.e[i].items[k].out - PL.e[i].items[k].in : 0;
		if (d > bd) { bd = d; best = (uint16_t)i; }
	}
	printf("%8u CORE mount: the feature, playlist %u\n", now, best + 1);
	C.state = 1;
	C.audio_track = 0; C.sub_on = 0; C.sub_track = 0;      // (player_ctl: the track picked anew, subtitles off -- S1)
	C.rank_q = 0;                                         // (player_ctl's mount clears rank_q: its chapter 1 posts, fj#76)
	seek_to(best, 0, PL.e[best].nitems ? PL.e[best].items[0].in : 0);
	if (mount_lat >= 0) C.seek_left = mount_lat;          // (a slow mount: an image on a share)
}

static void core_rd(uint16_t *w)
{
	memset(w, 0, UMD_HOST_NWORDS * sizeof(uint16_t));
	w[UMD_HOST_RD_MAGIC]   = UMD_HOST_MAGIC;
	w[UMD_HOST_RD_PROTO]   = (uint16_t)(UMD_HOST_PROTO << 8 | UMD_HOST_NWORDS);
	w[UMD_HOST_RD_STATUS]  = (uint16_t)(0x8000 | C.ui << 13 | C.menu << 12 | C.win_on << 11);
	w[UMD_HOST_RD_PLAY]    = (uint16_t)(C.state << 13 | C.seeking << 12 | C.sub_on << 8 | C.shown << 7 | (C.sub_track & 0x1F));
	while (aa_i < n_aa && now >= aa_q[aa_i].at) { menu_aa = aa_q[aa_i++].fit; printf("%8u CORE menu fit %d\n", now, menu_aa); }
	w[UMD_HOST_RD_AUDIO]   = (uint16_t)(1u << 14 | (narrow[C.playlist] ? 0u : 1u << 13) | (unsigned)menu_aa << 11 | (C.audio_track & 0xF));
	w[UMD_HOST_RD_ACKS]    = (uint16_t)(C.cmd_ack << 8 | C.flip_ack);
	w[UMD_HOST_RD_PCM_ACK] = (uint16_t)(C.pcm_ack << 8 | C.win_ack);
	w[UMD_HOST_RD_PRESS_ACK] = C.press_ack;
	w[UMD_HOST_RD_CHAPTER] = C.chapter;
	w[UMD_HOST_RD_N_CHAPTERS] = (uint16_t)PL.e[C.playlist].nchapters;
	w[UMD_HOST_RD_PLAYLIST] = C.playlist;
	w[UMD_HOST_RD_N_ITEMS_LO] = (uint16_t)PL.e[C.playlist].nitems;
	w[UMD_HOST_RD_KEY_LO]  = (uint16_t)C.item;
	w[UMD_HOST_RD_KEY_HI]  = (uint16_t)(C.item >> 16);
	w[UMD_HOST_RD_PTS_LO]  = (uint16_t)C.pts;
	w[UMD_HOST_RD_PTS_MID] = (uint16_t)(C.pts >> 16);
	w[UMD_HOST_RD_PTS_HI]  = (uint16_t)(C.pts >> 32 & 1);
	w[UMD_HOST_RD_EV_W]    = (uint16_t)(C.ev_lost << 8 | C.ev_wc);
	w[UMD_HOST_RD_EV_R]    = C.ev_rc;
	uint8_t avail = (uint8_t)(C.ev_wc - C.ev_rc);
	for (int k = 0; k < 4 && k < avail; k++) {
		uint8_t i = (uint8_t)(C.ev_rc + k);
		w[UMD_HOST_RD_EV0_CODE + 2 * k] = C.fc[i & 7];
		w[UMD_HOST_RD_EV0_DATA + 2 * k] = C.fd[i & 7];
	}
}

static void core_wr(const uint16_t *w)
{
	uint8_t cseq = (uint8_t)(w[UMD_HOST_WR_PCMD] >> 8);
	if (cseq != C.cmd_ack && !C.hc_v) {
		C.hc_v = 1; C.c_held_seq = cseq; C.hc_wait = (int)(rnd() % 6);
		C.hc.code = (uint8_t)(w[UMD_HOST_WR_PCMD] >> 4 & 0xF);
		C.hc.arg  = (uint8_t)(w[UMD_HOST_WR_PCMD] & 0xF);
		C.hc.pl   = w[UMD_HOST_WR_PCMD_PL];
		C.hc.item = (uint32_t)w[UMD_HOST_WR_PCMD_ITEM_LO] | (uint32_t)w[UMD_HOST_WR_PCMD_ITEM_HI] << 16;
		C.hc.pts  = (uint64_t)w[UMD_HOST_WR_PCMD_PTS0] | (uint64_t)w[UMD_HOST_WR_PCMD_PTS1] << 16 | (uint64_t)w[UMD_HOST_WR_PCMD_PTS2] << 32;
	}
	C.ev_rp_h = (uint8_t)w[UMD_HOST_WR_EV_RP];
	// a press record (P6d's panel, fj#72's transport keys): the buttons as pressed, ORed in after the grab --
	// the transport's (the model traces it; player_ctl acts on it in the core)
	uint8_t kseq = (uint8_t)(w[UMD_HOST_WR_PRESS] >> 8);
	if (kseq != C.press_ack) {
		printf("%8u CORE press 0x%04x\n", now, w[UMD_HOST_WR_PRESS_MASK]);
		C.press_ack = kseq;
	}
	uint8_t fseq = (uint8_t)(w[UMD_HOST_WR_FLIP] >> 8);
	if (fseq != C.flip_ack && fseq != C.t_fseq_q && !C.hf_req) {
		C.hf_req = 1; C.t_fseq_q = fseq; C.hf_wait = (int)(rnd() % 17);   // (latched at a vblank)
		C.hf_buf = (w[UMD_HOST_WR_FLIP] & 1) ? (w[UMD_HOST_WR_FLIP] >> 1 & 1) : -1;
	}
	uint8_t pseq = (uint8_t)(w[UMD_HOST_WR_PCM] >> 8);
	if (pseq != C.pcm_ack && pseq != C.t_pseq_q && !C.hp_req) {
		C.hp_req = 1; C.t_pseq_q = pseq; C.hp_wait = (int)(rnd() % 4);
		C.hp_st = w[UMD_HOST_WR_PCM] & 1;
		C.hp_start = (uint32_t)w[UMD_HOST_WR_PCM_START_LO] | (uint32_t)(w[UMD_HOST_WR_PCM_START_HI] & 0xFF) << 16;
		C.hp_len = (uint32_t)w[UMD_HOST_WR_PCM_LEN_LO] | (uint32_t)(w[UMD_HOST_WR_PCM_LEN_HI] & 0xFF) << 16;
	}
	uint16_t grab = w[UMD_HOST_WR_GRAB] & 0x0FFF;
	int ui = w[UMD_HOST_WR_CTL] >> 15 & 1, mn = w[UMD_HOST_WR_CTL] >> 14 & 1;
	if (grab != C.grab || ui != C.ui || mn != C.menu) {
		printf("%8u CORE levels grab 0x%03x ui %d menu %d\n", now, grab, ui, mn);
		walk_change = now;
	}
	if (ui != C.ui) C.front = -1;            // (any change of ui hides the plane: hps_host.md §3.4)
	int mute = w[UMD_HOST_WR_CTL] >> 13 & 1;
	if (mute != C.mute) printf("%8u CORE audio %s\n", now, mute ? "muted" : "heard");
	C.grab = grab; C.ui = ui; C.menu = mn; C.mute = mute;
	int won = w[UMD_HOST_WR_WIN] & 1;
	uint16_t wx = w[UMD_HOST_WR_WIN_X], wy = w[UMD_HOST_WR_WIN_Y], ww = w[UMD_HOST_WR_WIN_W], wh = w[UMD_HOST_WR_WIN_H];
	if (won != C.win_on || (won && (wx != C.win_x || wy != C.win_y || ww != C.win_w || wh != C.win_h))) {
		if (won) printf("%8u CORE window %u %u %ux%u\n", now, wx, wy, ww, wh);
		else printf("%8u CORE window off\n", now);
	}
	C.win_on = won; C.win_x = wx; C.win_y = wy; C.win_w = ww; C.win_h = wh;
	C.win_ack = (uint8_t)(w[UMD_HOST_WR_WIN] >> 8);
}

static void player_take(const umd_menu_pcmd *c)
{
	switch (c->code) {
	case UMD_PC_PLAYL: {
		if (C.seeking) {
			printf("%8u PLAYER busy: playlist %u refused\n", now, c->pl + 1);
			ev_later(rnd() % 4, UMD_EV_BAD, UMD_PC_PLAYL);
			return;
		}
		if (c->pl >= PL.n) { printf("%8u PLAYER playlist %u: NO SUCH PLAYLIST\n", now, c->pl + 1); ev_later(1, UMD_EV_BAD, UMD_PC_PLAYL); return; }
		uint16_t r = rank_at(c->pl, c->item, c->pts);
		uint32_t ci = 0; uint64_t cp = 0;
		int at_start = (r >= 1 && !umd_pl_chapter(&PL, c->pl, r, &ci, &cp) && ci == c->item && cp == c->pts) ||
		               (r == 0 && c->item == 0 && PL.e[c->pl].nitems && c->pts == PL.e[c->pl].items[0].in);
		if (walk_back_at && !walk_done) {
			walk_done = now;
			if ((int)c->pl != walk_feature_pl) printf("%8u WALK BACK other playlist %u\n", now, c->pl + 1);
			else printf("%8u WALK BACK %s\n", now, at_start && r <= 1 ? "restarted" : "resumed");
		}
		if (at_start) printf("%8u PLAYER play playlist %u chapter %u (%u ms)\n", now, c->pl + 1, r ? r : 1, pos_ms(c->pl, PL.e[c->pl].nitems - 1, PL.e[c->pl].items[PL.e[c->pl].nitems - 1].out));
		else printf("%8u PLAYER play playlist %u at %u ms\n", now, c->pl + 1, pos_ms(c->pl, c->item, c->pts));
		seek_to(c->pl, c->item, c->pts);
		walk_change = now;
		if (walk_idle && !walk_feature && R.H.content && pl_dur(c->pl) * 2 >= pl_longest) {
			walk_feature = now;
			walk_feature_pl = c->pl;
			printf("%8u WALK FEATURE playlist %u (%u of %u ms) after %u presses\n", now, c->pl + 1,
			       (unsigned)(pl_dur(c->pl) / 90), (unsigned)(pl_longest / 90), walk_n);
		}
		return;
	}
	case UMD_PC_STOP:
		printf("%8u PLAYER stop\n", now);
		if (C.state == 1 || C.state == 2) C.state = 3;
		return;
	case UMD_PC_PLAYPAUSE:
		if (C.state == 1) { C.state = 2; printf("%8u PLAYER pause\n", now); }
		else if (C.state == 2 || C.state == 3) { C.state = 1; printf("%8u PLAYER play (transport)\n", now); }
		return;
	case UMD_PC_PAUSE:                       // (player_ctl: from play only; nothing while paused or stopped)
		if (C.state == 1) { C.state = 2; printf("%8u PLAYER pause (held)\n", now); }
		return;
	case UMD_PC_PLAY:
		printf("%8u PLAYER play (transport)\n", now);
		if (C.state == 2 || C.state == 3) C.state = 1;
		return;
	case UMD_PC_AUDIO_SET:
		if (c->arg == C.audio_track || C.state == 3) { ev_later(1, UMD_EV_BAD, UMD_PC_AUDIO_SET); printf("%8u PLAYER audio %u refused\n", now, c->arg); return; }
		C.audio_track = c->arg;
		printf("%8u PLAYER audio %u\n", now, c->arg);
		return;
	case UMD_PC_SUB_SET:
		C.sub_on = c->item >> 5 & 1; C.sub_track = c->item & 0x1F;
		printf("%8u PLAYER subtitles %s track %u\n", now, C.sub_on ? "on" : "off", C.sub_track);
		return;
	default:
		printf("%8u PLAYER command %u\n", now, c->code);
	}
}

// --skip: the place POS ms into the playing playlist
static void core_skip(uint32_t pos)
{
	const umd_pl_entry *e = &PL.e[C.playlist];
	uint64_t left = (uint64_t)pos * 90;
	for (uint32_t k = 0; k < e->nitems; k++) {
		uint64_t d = e->items[k].out > e->items[k].in ? e->items[k].out - e->items[k].in : 0;
		if (left < d || k + 1 == e->nitems) { C.item = k; C.pts = e->items[k].in + (left < d ? left : d); break; }
		left -= d;
	}
	printf("%8u CORE skip: playlist %u at %u ms\n", now, C.playlist + 1, pos);
}

static void core_tick(void)
{
	for (int i = 0; i < n_dly;) {
		if (dly[i].due <= now) { ev_push(dly[i].code, dly[i].data); dly[i] = dly[--n_dly]; } else i++;
	}
	if (C.hc_v && C.hc_wait-- <= 0) { C.hc_v = 0; C.cmd_ack = C.c_held_seq; player_take(&C.hc); }
	if (C.hf_req && C.hf_wait-- <= 0) { C.hf_req = 0; C.flip_ack = C.t_fseq_q; C.n_flips++; C.front = C.hf_buf; }
	if (C.hp_req && C.hp_wait-- <= 0) {
		C.hp_req = 0; C.pcm_ack = C.t_pseq_q; C.n_pcm++;
		if (C.hp_len) printf("%8u CORE pcm start %u len %u %s\n", now, C.hp_start, C.hp_len, C.hp_st ? "stereo" : "mono");
		else printf("%8u CORE pcm stop\n", now);
	}
	while (C.ev_rc != C.ev_rp_h && C.ev_rc != C.ev_wc) C.ev_rc++;
	if (C.seeking) {
		if (--C.seek_left <= 0) {
			C.seeking = 0; C.shown = 1; C.state = 1;
			C.playlist = C.target; C.item = C.t_item; C.pts = C.t_pts;
			// the tracker ranks the landing 0-40 ms later (player_ctl: a NAV_CHAP from the shown key);
			// the word reads 0 till then (and through the seek): the rig, 2026-10-03
			C.rank_left = 1 + (int)(rnd() % 41);
		}
		return;
	}
	if (C.rank_left > 0 && --C.rank_left == 0) {
		C.chapter = rank_at(C.playlist, C.item, C.pts);
		if (C.chapter != C.rank_q) ev_push(UMD_EV_CHAPTER, C.chapter);          // (on a change only)
		C.rank_q = C.chapter;
	}
	if (C.state != 1 || C.ended) return;
	const umd_pl_entry *e = &PL.e[C.playlist];
	C.pts += 90;
	while (C.item < e->nitems && C.pts >= e->items[C.item].out) {
		if (C.item + 1 >= e->nitems) {
			// player_ctl at the display's END: the state stays PLAY on the last picture, TITLE_END posted
			// once (RS2 corrected the model, which stopped: resume.md §3)
			C.ended = 1; C.pts -= 90;
			printf("%8u PLAYER end of playlist %u\n", now, C.playlist + 1);
			ev_push(UMD_EV_TITLE_END, 0);
			return;
		}
		C.item++; C.pts = e->items[C.item].in;
	}
	uint16_t r = rank_at(C.playlist, C.item, C.pts);
	if (C.rank_left == 0 && r != C.rank_q) {
		C.chapter = r; C.rank_q = r;
		printf("%8u PLAYER chapter %u\n", now, r);
		ev_push(UMD_EV_CHAPTER, r);
	}
}

static const char *KN[12] = { "RIGHT", "LEFT", "DOWN", "UP", "START", "CROSS", "CIRCLE", "L", "R", "SELECT", "TRIANGLE", "SQUARE" };
static void core_key(int bit)
{
	if (C.grab >> bit & 1) {
		printf("%8u CORE key %s -> host\n", now, KN[bit]);
		ev_push(UMD_EV_KEY, (uint16_t)(1u << bit));
		return;
	}
	if (bit == UMD_JB_STOP && (C.state == 1 || C.state == 2)) { C.state = 3; printf("%8u CORE key %s -> transport stop\n", now, KN[bit]); }
	// (Cross, the J1 list's Select, is PLAYPAUSE as Start is: the maintainer, 2026-10-07)
	else if ((bit == UMD_JB_PLAYPAUSE || bit == UMD_JB_PAUSE) && (C.state == 2 || C.state == 3)) { C.state = 1; printf("%8u CORE key %s -> transport play\n", now, KN[bit]); }
	else if ((bit == UMD_JB_PLAYPAUSE || bit == UMD_JB_PAUSE) && C.state == 1) { C.state = 2; printf("%8u CORE key %s -> transport pause\n", now, KN[bit]); }
	else if (bit == UMD_JB_AUDIO && (C.state == 1 || C.state == 2)) {      // (RS2: the next of two tracks)
		C.audio_track = (C.audio_track + 1) & 1;
		printf("%8u CORE key %s -> transport audio %d\n", now, KN[bit], C.audio_track);
	}
	else printf("%8u CORE key %s -> ignored\n", now, KN[bit]);
}

// ---- the glue's services (umd_menu_run.h's) ------------------------------------------------------
static char *store_text, store_id[64];
static int kept_pre;                             // --kept TEXT: the card's text for the disc at the start (any id)
static size_t store_n;
static void sv_trace(void *ud, const char *line)
{
	(void)ud;
	printf("%s\n", line);
	// (the walk's idleness: the engine moved focus, a page or the resource)
	if (strstr(line, " FOCUS ") || strstr(line, ".open()") || strstr(line, ".close()") || strstr(line, " RESOURCE "))
		walk_change = now;
}
static char *sv_kept_load(void *ud, const char *id, size_t *len)
{
	(void)ud;
	*len = 0;
	if (!store_text || (strcmp(id, store_id) && !kept_pre)) return NULL;
	char *t = (char *)malloc(store_n + 1);
	if (!t) return NULL;
	memcpy(t, store_text, store_n); t[store_n] = 0;
	*len = store_n;
	return t;
}
static int card_full;                            // --card-full: every store refused (the card full / read-only)
static uint32_t sub_at;                          // --sub T: subtitles on (track 0) at T, as the Subtitle button
static int sv_kept_store(void *ud, const char *id, const char *text, size_t len)
{
	(void)ud;
	if (card_full) { printf("%8u CARD full: %s not written\n", now, id); return -1; }
	const char *nl = memchr(text, '\n', len);
	printf("%8u CARD store %s: %u bytes, %.*s%s\n", now, id, (unsigned)len, nl ? (int)(nl - text) : 0, text,
	       nl && (size_t)(nl + 1 - text) < len ? " + user data" : "");
	free(store_text);
	store_text = (char *)malloc(len + 1);
	if (!store_text) { store_n = 0; return -1; }
	memcpy(store_text, text, len); store_text[len] = 0;
	store_n = len;
	snprintf(store_id, sizeof(store_id), "%s", id);
	return 0;
}
static const char *store_resume(void) { return store_text && !strncmp(store_text, "R 1 ", 4) ? "kept" : "none"; }
// the kept point's place in ms from its playlist's start (-1 none)
static long store_point_ms(unsigned *plp)
{
	unsigned have, pl, item;
	unsigned long long pts;
	if (!store_text || sscanf(store_text, "R %u %u %u %llu", &have, &pl, &item, &pts) != 4 || !have || pl >= PL.n) return -1;
	*plp = pl + 1;
	return (long)pos_ms((uint16_t)pl, item, pts);
}
static void sv_open_osd(void *ud)
{
	(void)ud;
	printf("%8u QUIT (P9-6): %u bytes kept, resume point %s; STOP, the OSD opens\n", now, (unsigned)store_n, store_resume());
}
static int n_put;
static uint64_t pcm_bytes;
static void sv_pcm_put(void *ud, uint32_t word, const int16_t *pcm, uint32_t samples)
{
	(void)ud; (void)word; (void)pcm;
	pcm_bytes += (uint64_t)samples * 2;
}
// a frame into a plane the display shows, or will show at the next vblank (a flip latched, not yet
// applied), tears on screen: hps_host.md §3.4 "the host draws into a buffer only after the flip
// away from it is acknowledged"
static void sv_plane_put(void *ud, int buf, const uint8_t *frame)
{
	(void)ud;
	n_put++;
	// the rows the frame draws on (the plane is 720 x 480, 4 bytes a dot, 0 where nothing is drawn): a
	// menu fitted by Letterbox stays inside lines 60-419 (docs/analog.md S7)
	int y0 = -1, y1 = -1, x0 = 720, x1 = -1;
	for (int y = 0; y < 480; y++) {
		const uint32_t *row = (const uint32_t *)(frame + (size_t)y * 720 * 4);
		for (int x = 0; x < 720; x++) if (row[x]) {
			if (y0 < 0) y0 = y;
			y1 = y;
			if (x < x0) x0 = x;
			if (x > x1) x1 = x;
		}
	}
	if (y0 != fr_y0 || y1 != fr_y1 || x0 != fr_x0 || x1 != fr_x1) {
		if (y0 < 0) printf("%8u CORE frame empty\n", now);
		else printf("%8u CORE frame rows %d-%d cols %d-%d\n", now, y0, y1, x0, x1);
		fr_y0 = y0; fr_y1 = y1; fr_x0 = x0; fr_x1 = x1;
	}
	if (buf == C.front || (C.hf_req && buf == C.hf_buf)) {
		C.plane_bad++;
		printf("%8u CORE PLANE WRITE into buffer %d %s\n", now, buf, buf == C.front ? "on screen" : "about to show");
	}
}

// --walk-shot: the plane as the core shows it (premultiplied B, G, R, A bytes) over a checkerboard
static void walk_png(void)
{
	if (!walk_shot || !R.frame) return;
	uint8_t *rgb = (uint8_t *)malloc((size_t)UMD_MR_W * UMD_MR_H * 3);
	if (!rgb) return;
	for (int y = 0; y < UMD_MR_H; y++) for (int x = 0; x < UMD_MR_W; x++) {
		const uint8_t *p = R.frame + 4 * ((size_t)y * UMD_MR_W + (size_t)x);
		unsigned bg = ((x / 16 + y / 16) & 1) ? 96 : 64;
		uint8_t *o = rgb + 3 * ((size_t)y * UMD_MR_W + (size_t)x);
		for (int k = 0; k < 3; k++) o[k] = (uint8_t)(p[2 - k] + bg * (255u - p[3]) / 255u);
	}
	png_image im;
	memset(&im, 0, sizeof(im));
	im.version = PNG_IMAGE_VERSION; im.width = UMD_MR_W; im.height = UMD_MR_H; im.format = PNG_FORMAT_RGB;
	png_image_write_to_file(&im, walk_shot, 0, rgb, 0, NULL);
	free(rgb);
}

static void core_key(int bit);

static void walk_step(void)
{
	if (walk_feature && !walk_done) {               // the second phase: Square in the feature
		if (!walk_sq && now >= walk_feature + 5000) {
			walk_sq = now;
			printf("%8u WALK SQUARE\n", now);
			core_key(UMD_JB_UMDMENU);
		} else if (walk_sq && !walk_menu_again && C.ui && C.menu) {
			walk_menu_again = now;
			printf("%8u WALK MENU AGAIN after %u ms\n", now, now - walk_sq);
		} else if (walk_menu_again && !walk_back_at && now - walk_menu_again >= walk_idle) {   // (a looping clip never idles)
			walk_back_at = now;
			const char *f = menu_focus(R.H.m, NULL);
			printf("%8u WALK CROSS (focus %s)\n", now, f ? f : "-");
			core_key(UMD_JB_PAUSE);
		} else if (walk_back_at && now >= walk_back_at + 15000) {
			walk_done = now;
			printf("%8u WALK BACK nothing played\n", now);
		} else if (walk_sq && !walk_menu_again && now >= walk_sq + 15000) {
			walk_done = now;
			printf("%8u WALK NO MENU after Square\n", now);
		}
		return;
	}
	if (!walk_idle || walk_feature || walk_n >= walk_max || !R.H.m || R.H.mode == UMD_MH_NONE) return;
	if (!C.ui || !C.menu || !(C.grab >> UMD_JB_PAUSE & 1)) return;
	if (now - walk_change < walk_idle || (walk_n && now - walk_last < walk_idle)) return;
	int type;
	const char *f = menu_focus(R.H.m, &type);
	// a press that changed nothing (no focus, page, play or level since): try the next of Down, Right, Cross
	int key = UMD_JB_PAUSE;
	if (walk_n && walk_change <= walk_last)
		key = walk_last_key == UMD_JB_PAUSE ? UMD_JB_DOWN : walk_last_key == UMD_JB_DOWN ? UMD_JB_RIGHT : UMD_JB_PAUSE;
	walk_png();
	printf("%8u WALK %s (focus %s%s)\n", now, key == UMD_JB_PAUSE ? "CROSS" : key == UMD_JB_DOWN ? "DOWN" : "RIGHT",
	       f ? f : "-", f && type != 26 ? ", not a button" : "");
	walk_n++; walk_last = now; walk_last_key = key;
	core_key(key);
}

static int key_bit(const char *s)
{
	// menu_run's names (the PSP's buttons) onto the joystick bits
	static const struct { const char *n; int b; } m[] = {
		{ "UP", UMD_JB_UP }, { "DOWN", UMD_JB_DOWN }, { "LEFT", UMD_JB_LEFT }, { "RIGHT", UMD_JB_RIGHT },
		{ "CROSS", UMD_JB_PAUSE }, { "CIRCLE", UMD_JB_STOP }, { "TRIANGLE", UMD_JB_DISPLAY }, { "SQUARE", UMD_JB_UMDMENU },
		{ "START", UMD_JB_PLAYPAUSE }, { "SELECT", UMD_JB_AUDIO }, { "L", UMD_JB_PREV }, { "R", UMD_JB_NEXT } };
	for (size_t i = 0; i < sizeof(m) / sizeof(m[0]); i++) if (!strcmp(s, m[i].n)) return m[i].b;
	return -1;
}

int main(int argc, char **argv)
{
	const char *start = NULL, *lang = "EN";
	uint32_t ms = 60000, seed = 1;
	struct { uint32_t t; int b; } keys[256];
	struct { uint32_t t, pos; } skips[16];
	int nkeys = 0, nskips = 0;
	uint32_t relaunch[16], idle_at = 0, powercut[16];
	int nrel = 0, npc = 0;
	if (argc < 2) { fprintf(stderr, "usage: menu_host_check IMAGE.iso [--ms N] [--key T:NAME ...] [--relaunch T ...] [--seed N] [--lat LO:HI] [--drop PM]\n"); return 2; }
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--start") && i + 1 < argc) start = argv[++i];
		else if (!strcmp(argv[i], "--lang") && i + 1 < argc) lang = argv[++i];
		else if (!strcmp(argv[i], "--lang-opt") && i + 1 < argc) lang = umd_mh_lang_code((unsigned)atoi(argv[++i]));
		else if (!strcmp(argv[i], "--ms") && i + 1 < argc) ms = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--drop") && i + 1 < argc) drop_pm = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--shots") && i + 1 < argc) i++;              // (frames are always drawn whole now)
		else if (!strcmp(argv[i], "--mount-lat") && i + 1 < argc) mount_lat = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--start-lat") && i + 1 < argc) start_lat = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--draw-trace") && i + 1 < argc) draw_trace_at = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--no-item-cache")) no_item_cache = 1;
		else if (!strcmp(argv[i], "--idle") && i + 1 < argc) idle_at = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--menus-off")) menus_off = 1;
		else if (!strcmp(argv[i], "--walk")) walk_idle = (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9') ? (uint32_t)atol(argv[++i]) : 6000;
		else if (!strcmp(argv[i], "--walk-max") && i + 1 < argc) walk_max = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--walk-end") && i + 1 < argc) walk_end = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--walk-shot") && i + 1 < argc) walk_shot = argv[++i];
		else if (!strcmp(argv[i], "--menu-aa") && i + 1 < argc) {
			char *c = strchr(argv[++i], ':');
			if (c && n_aa < 16) { aa_q[n_aa].at = (uint32_t)atol(argv[i]); aa_q[n_aa++].fit = atoi(c + 1); }
		}
		else if (!strcmp(argv[i], "--narrow") && i + 1 < argc) {
			// the script's playlist numbers (from 1) whose pictures are 4:3, comma-separated
			for (char *t = strtok(argv[++i], ","); t; t = strtok(NULL, ",")) { long n = atol(t); if (n >= 1 && n <= 65536) narrow[n - 1] = 1; }
		}
		else if (!strcmp(argv[i], "--lat") && i + 1 < argc) {
			if (sscanf(argv[++i], "%d:%d", &lat_lo, &lat_hi) != 2 || lat_lo < 1 || lat_hi < lat_lo) { fprintf(stderr, "bad --lat\n"); return 2; }
		} else if (!strcmp(argv[i], "--key") && i + 1 < argc && nkeys < 256) {
			char *c = strchr(argv[++i], ':');
			if (!c || key_bit(c + 1) < 0) { fprintf(stderr, "bad --key %s\n", argv[i]); return 2; }
			keys[nkeys].t = (uint32_t)atol(argv[i]); keys[nkeys].b = key_bit(c + 1); nkeys++;
		} else if (!strcmp(argv[i], "--skip") && i + 1 < argc && nskips < 16) {
			if (sscanf(argv[++i], "%u:%u", &skips[nskips].t, &skips[nskips].pos) != 2) { fprintf(stderr, "bad --skip\n"); return 2; }
			nskips++;
		} else if (!strcmp(argv[i], "--relaunch") && i + 1 < argc && nrel < 16) relaunch[nrel++] = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--powercut") && i + 1 < argc && npc < 16) powercut[npc++] = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--card-full")) card_full = 1;
		else if (!strcmp(argv[i], "--sub") && i + 1 < argc) sub_at = (uint32_t)atol(argv[++i]);
		else if (!strcmp(argv[i], "--kept") && i + 1 < argc) {
			// (the card already holds this text for the disc: "\\n" in it ends the R line)
			const char *a = argv[++i];
			free(store_text);
			store_text = (char *)malloc(strlen(a) + 2);
			snprintf(store_text, strlen(a) + 2, "%s\n", a);
			store_n = strlen(store_text);
			kept_pre = 1;
		}
		else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
	}
	rng = seed * 2654435761u + 7;
	isof = fopen(argv[1], "rb");
	if (!isof) { perror(argv[1]); return 2; }
	fseeko(isof, 0, SEEK_END);
	uint64_t sz = (uint64_t)ftello(isof);
	// (the core model's own view of the disc: its playlists, as the reader's)
	uint8_t *raw = NULL; size_t rawn = 0;
	if (umd_iso_open(&ISO, iso_rd, isof, sz) || umd_iso_read_file(&ISO, "/UMD_VIDEO/PLAYLIST.UMD", 64u << 20, &raw, &rawn)) { fprintf(stderr, "iso: %s\n", ISO.err); return 2; }
	if (umd_pl_parse(&PL, raw, rawn)) { fprintf(stderr, "PLAYLIST.UMD: %s\n", PL.err); return 2; }
	free(raw);
	for (uint32_t i = 0; i < PL.n; i++) if (pl_dur(i) > pl_longest) pl_longest = pl_dur(i);

	memset(&C, 0, sizeof(C));
	C.cmd_ack = (uint8_t)rnd(); C.flip_ack = (uint8_t)rnd(); C.pcm_ack = (uint8_t)rnd();
	C.t_fseq_q = C.flip_ack; C.t_pseq_q = C.pcm_ack;
	C.ev_wc = C.ev_rc = C.ev_rp_h = (uint8_t)rnd();
	C.front = -1; C.hf_buf = -1;
	mount();

	// the glue's part, single-threaded: the runner on the worker, the logic on the poll side
	umd_menu_state L;
	memset(&L, 0, sizeof(L));
	umd_menu_init(&L);
	umd_mr_services sv;
	memset(&sv, 0, sizeof(sv));
	sv.decode_image = bench_decode_image; sv.kept_load = sv_kept_load; sv.kept_store = sv_kept_store;
	sv.plane_put = sv_plane_put; sv.open_osd = sv_open_osd; sv.trace = sv_trace; sv.pcm_put = sv_pcm_put;
	umd_mr_init(&R, &sv, &L);
	R.menus_off = menus_off;
	snprintf(R.image_name, sizeof(R.image_name), "%s", argv[1]);
	umd_mr_mount(&R, 1, iso_rd, isof, sz, lang, 0);
	if (start) snprintf(R.start, sizeof(R.start), "%s", start);
	int stopped_engine = 0;
	uint16_t rdw[UMD_HOST_NWORDS], wr[UMD_HOST_WR_NWORDS];
	memset(wr, 0, sizeof(wr));
	uint32_t last_rd = 0, last_wr = 0;
	int fast = 1;
	for (now = 1; now <= ms; now++) {
		if (walk_done && now > walk_done + walk_end) break;
		core_tick();
		if (now % 10 == 5) walk_step();
		for (int i = 0; i < nkeys; i++) if (keys[i].t == now) core_key(keys[i].b);
		for (int i = 0; i < nskips; i++) if (skips[i].t == now && !C.seeking && C.state) core_skip(skips[i].pos);
		if (sub_at && now == sub_at && (C.state == 1 || C.state == 2)) {
			C.sub_on = 1; C.sub_track = 0;
			printf("%8u CORE key SUBTITLE -> transport subtitles on track 0\n", now);
		}
		if (idle_at && now == idle_at) { C.state = 0; C.seeking = 0; C.shown = 0; printf("%8u CORE Reset: the image unloaded (idle)\n", now); }
		umd_menu_rd rd, *prd = NULL;
		if (now - last_rd >= (fast ? 2u : 50u)) {             // (UMD_HOST_READ_FAST_MS / _SLOW_MS)
			core_rd(rdw);
			umd_menu_decode(rdw, UMD_HOST_NWORDS, &rd);
			prd = &rd;
			last_rd = now;
		}
		umd_menu_levels lv;
		umd_mr_levels(&R, &lv);
		umd_menu_event ev[UMD_MENU_EVQ];
		int nev = 0, ww = 0;
		umd_menu_step(&L, now, prd, &lv, ev, &nev, wr, &ww, &fast);
		umd_mr_feed(&R, prd, ev, nev);
		if (now % 10 == 0) {
			// --start-lat: the start fires at this tick -- the poll side steps on through its load first
			int held = 0;
			if (start_lat > 0 && R.armed && !R.started && R.have_rd && umd_mh_ready(&R.rd)) {
				uint32_t t_fire = now;
				for (int k = 0; k < start_lat && k < MBOX_MAX && now < ms; k++) {
					now++;
					core_tick();
					mbox[k].have = 0;
					if (now - last_rd >= (fast ? 2u : 50u)) {
						core_rd(rdw);
						umd_menu_decode(rdw, UMD_HOST_NWORDS, &mbox[k].rd);
						mbox[k].have = 1;
						last_rd = now;
					}
					int hww = 0;
					umd_menu_step(&L, now, mbox[k].have ? &mbox[k].rd : NULL, &lv, mbox[k].ev, &mbox[k].nev, wr, &hww, &fast);
					if (L.adopted && ((hww && (int)(rnd() % 1000) >= drop_pm) || now - last_wr >= 100)) { core_wr(wr); last_wr = now; }
					held++;
				}
				printf("%8u CORE start at %u: %d ms of the poll's steps held in the mailbox (--start-lat)\n", now, t_fire, held);
			}
			umd_mr_tick(&R, now);
			for (int k = 0; k < held; k++) umd_mr_feed(&R, mbox[k].have ? &mbox[k].rd : NULL, mbox[k].ev, mbox[k].nev);
#ifdef MENU_ITEM_CACHE
			if (no_item_cache && R.H.m) menu_item_cache(R.H.m, 0);
#endif
			// RENDER, PIPELINED (umd_menu_run.h), as the worker: the drawn frame put when the flip is back, the next
			// drawn while it is out (a fresh draw with the channel idle goes out at once)
			int dtr = 0;
			for (int pass = 0; pass < 2; pass++) {
				int b = umd_mr_put_want(&R, 0);
				if (b >= 0) {
					if (R.staged && R.H.m) {             // (the put must show the fit the frame is drawn with)
						float t[8];
						int fit = umd_mh_fit(&R.H, &t[0], &t[1], &t[2], &t[3], &t[4], &t[5], &t[6], &t[7]);
						if (fit != drawn_fit) {
							if (!stale_put) printf("%8u CORE STALE PUT: a frame drawn at fit %d put at fit %d\n", now, drawn_fit, fit);
							stale_put++;
						}
					}
					umd_mr_put_frame(&R, b);
					umd_mr_render_flip(&R, b);
				}
				if (pass || !umd_mr_draw_want(&R)) break;
				dtr = draw_trace_at && now >= draw_trace_at && R.H.m;
				if (dtr) { menu_trace_draw(R.H.m, 1); draw_trace_at = 0; }
				struct timespec t0, t1;
				clock_gettime(CLOCK_MONOTONIC, &t0);
				umd_mr_draw_frame(&R);
				drawn_fit = R.fit_was;
				clock_gettime(CLOCK_MONOTONIC, &t1);
				double us = (double)(t1.tv_sec - t0.tv_sec) * 1e6 + (double)(t1.tv_nsec - t0.tv_nsec) / 1e3;
				rend_us += us; if (us > rend_max) rend_max = us;
				// M4d: the incremental frame equals the whole render, exactly, EVERY engine frame (not the
				// disc screen's, RS4: its own buffer, the engine gone)
				if (R.frame && R.H.m && R.H.mode != UMD_MH_NONE && !R.ds_up) {
					if (!inc_ref) inc_ref = (uint8_t *)malloc((size_t)UMD_MR_W * UMD_MR_H * 4);
					if (inc_ref) {
						umd_mr_draw(&R, inc_ref);
						n_inc++;
						if (memcmp(inc_ref, R.frame, (size_t)UMD_MR_W * UMD_MR_H * 4)) {
							if (!inc_bad) printf("%8u CORE INC MISMATCH: the incremental frame differs from the whole render\n", now);
							inc_bad++;
						}
					}
				}
				if (R.frame) for (size_t q = 0; q < (size_t)UMD_MR_W * UMD_MR_H * 4; q++) frames_hash = (frames_hash ^ R.frame[q]) * 1099511628211ull;
			}
			if (dtr) menu_trace_draw(R.H.m, 0);
		}
		if (R.H.m && R.H.mode == UMD_MH_NONE && !stopped_engine && menu_error(R.H.m)[0]) {
			stopped_engine = 1;
			printf("%8u HOST engine stopped: %s\n", now, menu_error(R.H.m));
		}
		if (L.adopted && ((ww && (int)(rnd() % 1000) >= drop_pm) || now - last_wr >= 100)) {
			// (before adoption the glue sends B4's four words: the P9 rows not written)
			core_wr(wr);
			last_wr = now;
		}
		for (int i = 0; i < npc; i++) if (powercut[i] == now) {
			unsigned ppl = 0;
			long pms = store_point_ms(&ppl);
			if (pms >= 0) printf("%8u POWERCUT: %u bytes on the card, resume point kept playlist %u at %ld ms\n", now, (unsigned)store_n, ppl, pms);
			else printf("%8u POWERCUT: %u bytes on the card, resume point none\n", now, (unsigned)store_n);
			// nothing runs: the engine and the runner gone without a quit (no onExit, no store)
			R.sv.trace = NULL; R.hs.trace = NULL; R.H.sv.trace = NULL; R.sv.kept_store = NULL;
			R.H.mode = UMD_MH_NONE;
			umd_mr_free(&R);
			// power on: the image launched again (the core plays the feature), a new runner
			mount();
			umd_mr_init(&R, &sv, &L);
			R.menus_off = menus_off;
	snprintf(R.image_name, sizeof(R.image_name), "%s", argv[1]);
			umd_mr_mount(&R, 1, iso_rd, isof, sz, lang, now);
			if (start) snprintf(R.start, sizeof(R.start), "%s", start);
		}
		for (int i = 0; i < nrel; i++) if (relaunch[i] == now) {
			int up = R.H.m && R.H.mode != UMD_MH_NONE;
			if (up) printf("%8u RELAUNCH: quit\n", now);
			else printf("%8u RELAUNCH: the image selected again (%u bytes kept)\n", now, (unsigned)store_n);
			// the image mounted again: the core auto-plays the feature; the runner quits the disc that
			// was up (its kept text stored) and arms the start
			mount();
			R.menus_off = menus_off;
	snprintf(R.image_name, sizeof(R.image_name), "%s", argv[1]);
			umd_mr_mount(&R, 1, iso_rd, isof, sz, lang, now);
			if (start) snprintf(R.start, sizeof(R.start), "%s", start);
			if (up) printf("%8u RELAUNCH: %u bytes of user data kept, resume point %s\n", now, (unsigned)store_n, store_resume());
		}
	}
	// the renderer's cost on THIS PC (the rig's A9 runs it ~30x slower: docs/p9.md M3, the second session)
	printf("%8u CORE render %u frames, %.0f ms in all, %.2f ms a frame, at most %.2f ms (this PC)\n", now, R.n_frames,
	       rend_us / 1e3, R.n_frames ? rend_us / 1e3 / R.n_frames : 0.0, rend_max / 1e3);
	// THE PROFILE (umd_menu_run.h): the runner's draw into the canvas and its stretch, mean wall / CPU a frame
	if (R.p_draw.n)
		printf("%8u CORE profile: draw %.2f / %.2f ms, stretch %.2f / %.2f ms a frame (wall / thread CPU, %llu frames)\n", now,
		       R.p_draw.wall_us / 1e3 / R.p_draw.n, R.p_draw.cpu_us / 1e3 / R.p_draw.n,
		       R.p_stretch.wall_us / 1e3 / R.p_stretch.n, R.p_stretch.cpu_us / 1e3 / R.p_stretch.n, (unsigned long long)R.p_draw.n);
	printf("%8u CORE frames hash %016llx (every frame flipped; fj#74: equal between two builds = the same pixels)\n", now, (unsigned long long)frames_hash);
	printf("%8u CORE inc %u frames checked, %u differ; %.0f px redrawn a frame (the canvas %d)\n", now, n_inc, inc_bad,
	       (R.H.m && R.n_frames) ? (double)menu_inc_damaged(R.H.m) / R.n_frames : 0.0, UMD_MR_CW * UMD_MR_CH);
	free(inc_ref);
#ifdef MENU_PROF
	if (R.H.m) menu_prof_dump(R.H.m, prof_line, NULL);
#endif
	printf("%8u CORE %u flips taken, %u rendered; logic: %u commands, %u BAD, %u retries, %u given up, %u resyncs, %u dropped events\n",
	       now, C.n_flips, R.n_frames, L.n_cmds, L.n_bad, L.n_retries, L.n_gave_up, L.n_resync, L.n_dropped);
	// the last frame flipped must be the engine's state now when nothing moves any more: a tween that
	// ended between two frames left the screen on its last-but-one step (the rig: Family Guy's
	// episode art stuck half faded over its clip)
	int stale = 0;
	if (R.H.m && R.H.mode != UMD_MH_NONE && R.ui_was && R.frame && !menu_dirty(R.H.m) && R.flipping < 0) {
		uint8_t *fresh = (uint8_t *)malloc((size_t)UMD_MR_W * UMD_MR_H * 4);
		if (fresh) {
			umd_mr_draw(&R, fresh);
			// (RENDER, PIPELINED: a frame drawn but never put at rest is not on the screen either)
			stale = R.staged || memcmp(fresh, R.frame, (size_t)UMD_MR_W * UMD_MR_H * 4) != 0;
			free(fresh);
		}
		if (stale) printf("%8u CORE STALE FRAME: the screen is not the engine's state at rest\n", now);
	}
	int bad = stopped_engine || L.n_gave_up || L.n_resync || C.ev_lost || C.plane_bad || stale || inc_bad || stale_put;
	printf("%8u END %s\n", now, stopped_engine ? "the engine stopped" : bad ? "the rows misbehaved" : "ok");
	R.sv.trace = NULL; R.hs.trace = NULL; R.H.sv.trace = NULL;   // (the bench's own end: not the disc's quit)
	umd_mr_free(&R);
	free(store_text);
	umd_pl_free(&PL);
	fclose(isof);
	return bad;
}
