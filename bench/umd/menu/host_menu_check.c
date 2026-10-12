// host_menu_check.c -- P9 M3's bench for the UMD Main's P9 host-row logic (main/support/umd/
// umd_menu_logic.c) against a C model of the core's side: umd/umd_host.sv's P9 rows (records taken
// once by seq and HELD until their consumer takes them, then echoed -- its exact take conditions;
// the 8-deep event FIFO read by count, popped up to the host's EV_RP) and player_ctl's answers (a
// PLAYLIST refused as BAD while busy, a seek, a landing, CHAPTER posted only when the rank changes
// and never reset by a new playlist, TITLE_END; stale CHAPTER / TITLE_END of the old playlist
// pushed after a PLAYLIST's take).
//
//   host_menu_check [--seeds N] [--ticks N]       -> "PASS: host_menu_check" or FAIL lines
//
// Per seed: 1 ms ticks; the host reads every tick on the fast rate, else every 50, and writes when
// the logic asks -- 30 % of those writes DROPPED (a subtitle-only HOST_WR carries 4 words: EV_RP and
// the records stay as they were) -- or every 100 ms (the heartbeat); the core starts with RANDOM
// echoes and event counts (a Main restarted under a running core). player_ctl's events trail what
// caused them, as in the RTL (a push waits for a cycle with no other push; the landing's CHAPTER
// follows its chapter query): a BAD 0-3 ms after its take, the landing's CHAPTER 0-5 ms after the
// picture shows. A third of the PLAYLISTs replay the playlist that is playing. The worker pushes random intents for most of the run,
// then nothing, so everything drains. Scored:
//   S1 every intent reaches the core exactly once, in order, whole, per channel (a PLAYLIST refused
//      as BAD counts when it is taken without a refusal); nothing is taken that was not pushed
//   S2 every KEY the core pushed (and did not lose) reaches the worker once, in order
//   S3 every landing gives one LANDED (its playlist) then one CHAPTER (the chapter it landed in)
//   S4 every in-play CHAPTER / TITLE_END reaches the worker once, in order, unless the host read it
//      with a PLAYLIST pending -- pushed by the worker and not yet LANDED or GAVE_UP, the worker's own
//      count (the script has called play(): the old playlist's end must not reach it), including one
//      the core posts in the very tick of the push; the stale ones pushed after a take never do
//   S5 no resync of the event counts
//   S6 (P6d, docs/panel.md F1 / F5) every press the worker pushed reaches the core exactly once, in
//      order (the core takes a new seq at once and echoes it); every flip's plane (0-3) as pushed; the
//      ui_sub level the worker set is the core's once the run drains
// (A duplicate CHAPTER would break S4's exact sequence; two in a row with one number are legitimate
// across a landing: a new play starting in chapter 1 after chapter 1.)
#include "umd_menu_logic.h"
#include "umd_host_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int now_tick_v(void);
static uint32_t rng;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static int chance(int permille) { return (int)(rnd() % 1000) < permille; }

#define MAXN 8192

typedef struct { uint8_t code, arg; uint16_t pl; uint32_t item; uint64_t pts; } rec;

// ---- the core ----------------------------------------------------------------------------------
static struct {
	uint8_t  cmd_ack, flip_ack, pcm_ack, win_ack;
	uint8_t  c_held_seq, t_fseq_q, t_pseq_q;
	int      hc_v, hf_req, hp_req, hc_wait, hf_wait, hp_wait;
	rec      hc;
	uint16_t hf_x, hp_start;
	uint16_t fc[8], fd[8];
	int      fid[8];                     // each slot's index into the in-play ledger, -1 none
	uint8_t  ev_wc, ev_rc, ev_rp_h, ev_lost;
	int      state, seeking, shown, seek_left, play_ticks, play_left;
	uint16_t playlist, chapter, rank_q, target;
	uint8_t  press_ack;                  // P6d: the press record's echo (taken at once)
	int      uis;                        // ... and ui_sub as the core holds it
} C;

// the ledgers
static rec      want_cmd[MAXN];  static int n_want_cmd;
static rec      took_ok[MAXN];   static int n_took_ok;     // taken and not refused
static int      n_want_flip, n_took_flip, n_want_pcm, n_took_pcm, flip_order_bad, pcm_order_bad;
static int      n_want_press, n_took_press, press_order_bad, flip_buf_bad;   // P6d
static uint16_t keys_pushed[MAXN]; static int n_keys_pushed;
static int      play_ev_kind[MAXN]; static uint16_t play_ev_data[MAXN]; static int n_play_ev;   // in play
static int      play_ev_stale[MAXN];
static uint16_t land_pl[MAXN], land_ch[MAXN]; static int n_land;
static uint16_t keys_got[MAXN]; static int n_keys_got;
static int      got_play_kind[MAXN]; static uint16_t got_play_data[MAXN]; static int n_got_play;
static uint16_t got_land_pl[MAXN], got_land_ch[MAXN]; static int n_got_land;
static int      s5_bad, after_landed, pl_pending;

static int verbose2;
static int ev_push_id(uint16_t code, uint16_t data, int id)
{
	if (verbose2) printf("      %6d core push code %u data %u%s\n", now_tick_v(), code, data, id >= 0 ? " (in play)" : "");
	if ((uint8_t)(C.ev_wc - C.ev_rc) >= 8) { if (C.ev_lost != 0xFF) C.ev_lost++; return 0; }
	C.fc[C.ev_wc & 7] = code; C.fd[C.ev_wc & 7] = data; C.fid[C.ev_wc & 7] = id;
	C.ev_wc++;
	return 1;
}
static int ev_push(uint16_t code, uint16_t data) { return ev_push_id(code, data, -1); }

// events that trail their cause
static struct { int due; uint16_t code, data; } dly[64];
static int n_dly, now_tick;
static int now_tick_v(void) { return now_tick; }
static void ev_later(int delay, uint16_t code, uint16_t data)
{
	if (n_dly < 64) { dly[n_dly].due = now_tick + delay; dly[n_dly].code = code; dly[n_dly].data = data; n_dly++; }
}
// an in-play event: in the ledger first, so its FIFO slot carries its index
static void ev_push_play(int kind, uint16_t code, uint16_t data)
{
	if (n_play_ev >= MAXN) return;
	if (ev_push_id(code, data, n_play_ev)) {
		play_ev_kind[n_play_ev] = kind; play_ev_data[n_play_ev] = kind == UMD_ME_CHAPTER ? data : 0; play_ev_stale[n_play_ev] = 0;
		n_play_ev++;
	}
}

static void core_rd(uint16_t *w)
{
	memset(w, 0, UMD_HOST_NWORDS * sizeof(uint16_t));
	w[UMD_HOST_RD_MAGIC]   = UMD_HOST_MAGIC;
	w[UMD_HOST_RD_PROTO]   = (uint16_t)(UMD_HOST_PROTO << 8 | UMD_HOST_NWORDS);
	w[UMD_HOST_RD_STATUS]  = (uint16_t)(0x8000 | C.uis << 7);
	w[UMD_HOST_RD_PRESS_ACK] = C.press_ack;
	w[UMD_HOST_RD_PLAY]    = (uint16_t)(C.state << 13 | C.seeking << 12 | C.shown << 7);
	w[UMD_HOST_RD_ACKS]    = (uint16_t)(C.cmd_ack << 8 | C.flip_ack);
	w[UMD_HOST_RD_PCM_ACK] = (uint16_t)(C.pcm_ack << 8 | C.win_ack);
	w[UMD_HOST_RD_CHAPTER] = C.chapter;
	w[UMD_HOST_RD_PLAYLIST] = C.playlist;
	w[UMD_HOST_RD_EV_W]    = (uint16_t)(C.ev_lost << 8 | C.ev_wc);
	w[UMD_HOST_RD_EV_R]    = C.ev_rc;
	uint8_t avail = (uint8_t)(C.ev_wc - C.ev_rc);
	for (int k = 0; k < 4 && k < avail; k++) {
		uint8_t i = (uint8_t)(C.ev_rc + k);
		w[UMD_HOST_RD_EV0_CODE + 2 * k] = C.fc[i & 7];
		w[UMD_HOST_RD_EV0_DATA + 2 * k] = C.fd[i & 7];
	}
}

// a whole HOST_WR (PROTO matched), umd_host.sv's take conditions
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
	uint8_t fseq = (uint8_t)(w[UMD_HOST_WR_FLIP] >> 8);
	if (fseq != C.flip_ack && fseq != C.t_fseq_q && !C.hf_req) {
		C.hf_req = 1; C.t_fseq_q = fseq; C.hf_wait = (int)(rnd() % 17); C.hf_x = w[UMD_HOST_WR_FLIP_X];
		if (((w[UMD_HOST_WR_FLIP] >> 1) & 3) != (C.hf_x & 3)) flip_buf_bad++;     // P6d: the plane as pushed
	}
	uint8_t pseq = (uint8_t)(w[UMD_HOST_WR_PCM] >> 8);
	if (pseq != C.pcm_ack && pseq != C.t_pseq_q && !C.hp_req) {
		C.hp_req = 1; C.t_pseq_q = pseq; C.hp_wait = (int)(rnd() % 4); C.hp_start = w[UMD_HOST_WR_PCM_START_LO];
	}
	C.win_ack = (uint8_t)(w[UMD_HOST_WR_WIN] >> 8);
	// P6d: the press record, taken at once by its seq (umd_host.sv: a one-cycle pulse, echoed at once)
	uint8_t xseq = (uint8_t)(w[UMD_HOST_WR_PRESS] >> 8);
	if (xseq != C.press_ack) {
		if (w[UMD_HOST_WR_PRESS_MASK] != (uint16_t)(n_took_press + 1)) press_order_bad++;
		n_took_press++;
		C.press_ack = xseq;
	}
	C.uis = (w[UMD_HOST_WR_CTL] >> 12) & 1;
}

// player_ctl takes a command
static void player_take(const rec *c)
{
	if (verbose2) printf("      %6d core take code %u pl %u (playing %u seeking %d)\n", now_tick, c->code, c->pl, C.playlist, C.seeking);
	if (c->code != UMD_PC_PLAYL) {
		if (n_took_ok < MAXN) took_ok[n_took_ok++] = *c;
		return;
	}
	if (C.seeking || chance(300)) { ev_later((int)(rnd() % 4), UMD_EV_BAD, UMD_PC_PLAYL); return; }     // busy: refused
	if (n_took_ok < MAXN) took_ok[n_took_ok++] = *c;
	// a chapter query in flight answers BEFORE the seek starts (player_ctl's NAV_PLAY waits for
	// !q_busy): a late landing CHAPTER posts now, after the take -- the host drops it as the old
	// playlist's
	for (int i = 0; i < n_dly;) {
		if (dly[i].code == UMD_EV_CHAPTER) { ev_push(dly[i].code, dly[i].data); dly[i] = dly[--n_dly]; } else i++;
	}
	// the old playlist's last words, after the take: stale
	if (C.state == 1 && chance(400)) ev_push(UMD_EV_CHAPTER, (uint16_t)(C.rank_q + 1));
	if (C.state == 1 && chance(300)) ev_push(UMD_EV_TITLE_END, 0);
	C.seeking = 1; C.seek_left = 3 + (int)(rnd() % 20); C.target = c->pl; C.shown = 0;
}

static void core_tick(void)
{
	now_tick++;
	for (int i = 0; i < n_dly;) {
		if (dly[i].due <= now_tick) { ev_push(dly[i].code, dly[i].data); dly[i] = dly[--n_dly]; } else i++;
	}
	if (C.hc_v && C.hc_wait-- <= 0) { C.hc_v = 0; C.cmd_ack = C.c_held_seq; player_take(&C.hc); }
	if (C.hf_req && C.hf_wait-- <= 0) {
		C.hf_req = 0; C.flip_ack = C.t_fseq_q;
		if (C.hf_x != n_took_flip) flip_order_bad++;
		n_took_flip++;
	}
	if (C.hp_req && C.hp_wait-- <= 0) {
		C.hp_req = 0; C.pcm_ack = C.t_pseq_q;
		if (C.hp_start != n_took_pcm) pcm_order_bad++;
		n_took_pcm++;
	}
	while (C.ev_rc != C.ev_rp_h && C.ev_rc != C.ev_wc) C.ev_rc++;
	if (C.seeking && --C.seek_left <= 0) {
		C.seeking = 0; C.playlist = C.target; C.shown = 1; C.state = 1; C.play_ticks = 0;
		C.play_left = 200 + (int)(rnd() % 3000);
		C.chapter = (uint16_t)(1 + rnd() % 3);
		if (n_land < MAXN) { land_pl[n_land] = C.playlist; land_ch[n_land] = C.chapter; n_land++; }
		// player_ctl's own CHAPTER, only when the rank changed (rank_q never reset by a playlist):
		// the host has posted that chapter at the landing already
		if (C.chapter != C.rank_q) ev_later((int)(rnd() % 6), UMD_EV_CHAPTER, C.chapter);
		C.rank_q = C.chapter;
	} else if (C.state == 1 && !C.seeking) {
		C.play_ticks++;
		// in play, well after the landing: a chapter change, the playlist's end
		if (C.play_ticks > 40 && n_dly == 0 && chance(4)) {
			C.chapter++; C.rank_q = C.chapter;
			ev_push_play(UMD_ME_CHAPTER, UMD_EV_CHAPTER, C.chapter);
		}
		if (C.play_ticks > 40 && --C.play_left <= 0) {
			C.state = 3;
			ev_push_play(UMD_ME_PL_END, UMD_EV_TITLE_END, 0);
		}
	}
	if (chance(10)) {
		uint16_t m = (uint16_t)(1 + rnd() % 0xFFF);
		if (ev_push(UMD_EV_KEY, m) && n_keys_pushed < MAXN) keys_pushed[n_keys_pushed++] = m;
	}
}

static int fails, verbose;
#define FAIL(...) do { if (fails++ < 12) { printf("  FAIL seed %u: ", seed); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void run(uint32_t seed, int ticks)
{
	rng = seed * 2654435761u + 1;
	memset(&C, 0, sizeof(C));
	for (int k = 0; k < 8; k++) C.fid[k] = -1;
	n_dly = 0; now_tick = 0;
	C.cmd_ack = (uint8_t)rnd(); C.flip_ack = (uint8_t)rnd(); C.pcm_ack = (uint8_t)rnd();
	C.t_fseq_q = C.flip_ack; C.t_pseq_q = C.pcm_ack;
	C.press_ack = (uint8_t)rnd();
	n_want_press = n_took_press = press_order_bad = flip_buf_bad = 0;
	C.ev_wc = C.ev_rc = C.ev_rp_h = (uint8_t)rnd();
	n_want_cmd = n_took_ok = n_want_flip = n_took_flip = n_want_pcm = n_took_pcm = 0;
	flip_order_bad = pcm_order_bad = 0;
	n_keys_pushed = n_play_ev = n_land = n_keys_got = n_got_play = n_got_land = 0;
	s5_bad = 0; after_landed = 0; pl_pending = 0;
	umd_menu_state s;
	memset(&s, 0, sizeof(s));
	umd_menu_init(&s);
	umd_menu_levels lv;
	memset(&lv, 0, sizeof(lv));
	uint16_t rdw[UMD_HOST_NWORDS], wr[UMD_HOST_WR_NWORDS];
	memset(wr, 0, sizeof(wr));
	uint32_t last_rd = 0, last_wr = 0;
	int fast = 1;
	uint16_t last_ch = 0;
	int have_ch = 0;
	for (uint32_t t = 1; t <= (uint32_t)ticks; t++) {
		core_tick();
		// the worker: intents for most of the run, then the drain
		if (t < (uint32_t)ticks * 7 / 10) {
			if (chance(6) && n_want_cmd < MAXN) {
				umd_menu_pcmd c;
				memset(&c, 0, sizeof(c));
				c.code = chance(600) ? UMD_PC_PLAYL : (chance(500) ? UMD_PC_STOP : UMD_PC_PLAY);
				c.pl = chance(330) ? C.playlist : (uint16_t)(rnd() % 40); c.item = (uint32_t)n_want_cmd << 8 | (rnd() & 0xFF);
				c.pts = ((uint64_t)rnd() << 16 ^ rnd()) & 0xFFFFFFFFFFFFull;
				if (umd_menu_push_cmd(&s, &c) == 0) {
					rec r = { c.code, c.arg, c.pl, c.item, c.pts };
					want_cmd[n_want_cmd++] = r;
					if (c.code == UMD_PC_PLAYL) {
						pl_pending++;
						// the old playlist's last word in the very tick of the play(): read before
						// the queue is sent
						if (C.state == 1 && !C.seeking && chance(500)) {
							if (chance(500)) ev_push_play(UMD_ME_PL_END, UMD_EV_TITLE_END, 0);
							else ev_push_play(UMD_ME_CHAPTER, UMD_EV_CHAPTER, (uint16_t)(C.rank_q + 100));
						}
					}
				}
			}
			if (chance(20)) { umd_menu_flip f = { (uint8_t)(n_want_flip & 3), 1, (uint16_t)n_want_flip, 0, 720, 480 }; if (umd_menu_push_flip(&s, &f) == 0) n_want_flip++; }
			if (chance(10) && umd_menu_push_press(&s, (uint16_t)(n_want_press + 1)) == 0) n_want_press++;   // P6d
			if (chance(2)) lv.ui_sub = !lv.ui_sub;
			if (chance(8))  { umd_menu_pcm p = { (uint32_t)n_want_pcm, 100, 0 }; if (umd_menu_push_pcm(&s, &p) == 0) n_want_pcm++; }
			if (chance(2)) lv.grab = (uint16_t)(rnd() & 0xFFF);
			if (chance(2)) { lv.win.on = !lv.win.on; lv.win.x = (uint16_t)(rnd() % 720); }
		}
		umd_menu_rd rd, *prd = NULL;
		if (t - last_rd >= (fast ? 1u : 50u)) {
			core_rd(rdw);
			umd_menu_decode(rdw, UMD_HOST_NWORDS, &rd);
			prd = &rd;
			last_rd = t;
		}
		umd_menu_event ev[UMD_MENU_EVQ];
		int nev = 0, ww = 0;
		uint8_t rp0 = s.rp;
		int pending0 = pl_pending;              // (the worker's count: pushed, not landed or given up)
		umd_menu_step(&s, t, prd, &lv, ev, &nev, wr, &ww, &fast);
		// the core events this step consumed: an in-play one read with a PLAYLIST in flight is stale
		if (prd && s.adopted)
			for (uint8_t p = rp0; p != s.rp; p++) {
				int id = C.fid[p & 7];
				if (id >= 0 && pending0) play_ev_stale[id] = 1;
			}
		for (int i = 0; i < nev; i++) {
			if (verbose2 && ev[i].kind != UMD_ME_KEY) printf("      %6u host -> worker kind %d data %u (inflight %d land_wait %d last_ch %u)\n", t, ev[i].kind, ev[i].data, s.inflight, s.land_wait, s.last_chapter);
			if (ev[i].kind == UMD_ME_KEY) { if (n_keys_got < MAXN) keys_got[n_keys_got++] = (uint16_t)ev[i].data; continue; }
			if (ev[i].kind == UMD_ME_GAVE_UP && pl_pending) pl_pending--;
			if (ev[i].kind == UMD_ME_LANDED) {
				if (pl_pending) pl_pending--;
				if (n_got_land < MAXN) got_land_pl[n_got_land] = (uint16_t)ev[i].data;
				after_landed = 1;
				continue;
			}
			if (ev[i].kind == UMD_ME_CHAPTER) {
				if (have_ch && ev[i].data == last_ch) s5_bad++;
				last_ch = (uint16_t)ev[i].data; have_ch = 1;
				if (after_landed) { if (n_got_land < MAXN) got_land_ch[n_got_land++] = (uint16_t)ev[i].data; after_landed = 0; continue; }
			}
			if (ev[i].kind == UMD_ME_CHAPTER || ev[i].kind == UMD_ME_PL_END) {
				if (n_got_play < MAXN) { got_play_kind[n_got_play] = ev[i].kind; got_play_data[n_got_play++] = ev[i].kind == UMD_ME_CHAPTER ? (uint16_t)ev[i].data : 0; }
			}
			after_landed = 0;
		}
		if (s.adopted && ((ww && !chance(300)) || t - last_wr >= 100)) { core_wr(wr); last_wr = t; }
	}
	// S1
	if (n_took_ok != n_want_cmd) FAIL("S1: %d commands pushed, %d taken (unrefused)", n_want_cmd, n_took_ok);
	for (int i = 0; i < n_want_cmd && i < n_took_ok; i++)
		if (memcmp(&want_cmd[i], &took_ok[i], sizeof(rec))) {
			FAIL("S1: command %d differs (code %u/%u pl %u/%u item %u/%u pts %llx/%llx)", i, want_cmd[i].code, took_ok[i].code,
			     want_cmd[i].pl, took_ok[i].pl, want_cmd[i].item, took_ok[i].item,
			     (unsigned long long)want_cmd[i].pts, (unsigned long long)took_ok[i].pts);
			break;
		}
	if (n_took_flip != n_want_flip || flip_order_bad) FAIL("S1: %d flips pushed, %d taken, %d out of order", n_want_flip, n_took_flip, flip_order_bad);
	if (n_took_pcm != n_want_pcm || pcm_order_bad) FAIL("S1: %d PCM triggers pushed, %d taken, %d out of order", n_want_pcm, n_took_pcm, pcm_order_bad);
	// S6 (P6d)
	if (n_took_press != n_want_press || press_order_bad) FAIL("S6: %d presses pushed, %d taken, %d out of order", n_want_press, n_took_press, press_order_bad);
	if (flip_buf_bad) FAIL("S6: %d flips reached the core on another plane", flip_buf_bad);
	if (C.uis != lv.ui_sub) FAIL("S6: ui_sub %d at the core, the worker's %d", C.uis, lv.ui_sub);
	// S2
	if (n_keys_got != n_keys_pushed || memcmp(keys_got, keys_pushed, (size_t)n_keys_got * 2))
		FAIL("S2: %d keys pushed, %d delivered%s", n_keys_pushed, n_keys_got, n_keys_got == n_keys_pushed ? " (out of order)" : "");
	// S3
	if (n_got_land != n_land) FAIL("S3: %d landings, %d LANDED+CHAPTER pairs", n_land, n_got_land);
	for (int i = 0; i < n_land && i < n_got_land; i++)
		if (got_land_pl[i] != land_pl[i] || got_land_ch[i] != land_ch[i]) {
			FAIL("S3: landing %d: playlist %u chapter %u, delivered %u / %u", i, land_pl[i], land_ch[i], got_land_pl[i], got_land_ch[i]);
			break;
		}
	// S4
	int n_exp = 0;
	for (int i = 0; i < n_play_ev; i++) if (!play_ev_stale[i]) { play_ev_kind[n_exp] = play_ev_kind[i]; play_ev_data[n_exp++] = play_ev_data[i]; }
	if (n_got_play != n_exp) FAIL("S4: %d in-play events expected, %d delivered", n_exp, n_got_play);
	for (int i = 0; i < n_exp && i < n_got_play; i++)
		if (got_play_kind[i] != play_ev_kind[i] || got_play_data[i] != play_ev_data[i]) { FAIL("S4: in-play event %d differs", i); break; }
	if (verbose && n_got_play != n_exp) {
		for (int i = 0; i < n_exp || i < n_got_play; i++)
			printf("    %3d want %d/%u  got %d/%u\n", i, i < n_exp ? play_ev_kind[i] : 0, i < n_exp ? play_ev_data[i] : 0,
			       i < n_got_play ? got_play_kind[i] : 0, i < n_got_play ? got_play_data[i] : 0);
	}
	// S5
	if (s.n_resync) FAIL("S5: %u event-count resyncs", s.n_resync);
}

int main(int argc, char **argv)
{
	int seeds = 200, ticks = 20000;
	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--seeds")) seeds = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--ticks")) ticks = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--verbose")) verbose = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--only")) { int k = atoi(argv[i + 1]); verbose2 = 1; run((uint32_t)k, 20000); return 0; }
	}
	long cmds = 0, keys = 0, lands = 0, plev = 0, presses = 0;
	for (int k = 1; k <= seeds; k++) {
		run((uint32_t)k, ticks);
		cmds += n_want_cmd; keys += n_keys_pushed; lands += n_land; plev += n_play_ev; presses += n_want_press;
	}
	printf("host_menu_check: %d seeds x %d ms: %ld commands, %ld keys, %ld landings, %ld in-play events, %ld presses (P6d)\n",
	       seeds, ticks, cmds, keys, lands, plev, presses);
	if (presses == 0) { printf("FAIL: S6 no press was exercised\n"); fails++; }
	if (fails) { printf("FAIL: host_menu_check (%d)\n", fails); return 1; }
	printf("PASS: host_menu_check\n");
	return 0;
}
