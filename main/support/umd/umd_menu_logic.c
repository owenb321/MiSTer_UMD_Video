// umd_menu_logic.c -- see umd_menu_logic.h.
#include "umd_menu_logic.h"
#include "umd_host_proto.h"

#include <string.h>

void umd_menu_decode(const uint16_t *w, int nwords, umd_menu_rd *rd)
{
	memset(rd, 0, sizeof(*rd));
	rd->magic = nwords > UMD_HOST_RD_PROTO && w[UMD_HOST_RD_MAGIC] == UMD_HOST_MAGIC;
	rd->proto_ok = rd->magic && (w[UMD_HOST_RD_PROTO] >> 8) == UMD_HOST_PROTO;
	// the menus need the P9 rows (through press_ack); a core with fewer runs without them. The rows
	// appended since (A12 SD2) are optional: a core that has them says so in NWORDS
	int have = (w[UMD_HOST_RD_PROTO] & 0xFF) < nwords ? (w[UMD_HOST_RD_PROTO] & 0xFF) : nwords;
	rd->nwords_ok = rd->proto_ok && have > UMD_HOST_RD_PRESS_ACK;
	if (!rd->nwords_ok) return;
	rd->host_ok   = (w[UMD_HOST_RD_STATUS] >> 15) & 1;
	rd->state     = (w[UMD_HOST_RD_PLAY] >> 13) & 7;
	rd->seeking   = (w[UMD_HOST_RD_PLAY] >> 12) & 1;
	rd->shown     = (w[UMD_HOST_RD_PLAY] >> 7) & 1;
	rd->sub_on    = (w[UMD_HOST_RD_PLAY] >> 8) & 1;
	rd->sub_track = w[UMD_HOST_RD_PLAY] & 0x1F;
	rd->audio_track = w[UMD_HOST_RD_AUDIO] & 0xF;
	rd->pic_known = (w[UMD_HOST_RD_AUDIO] >> 14) & 1;
	rd->pic_wide = (w[UMD_HOST_RD_AUDIO] >> 13) & 1;
	rd->menu_aa = (w[UMD_HOST_RD_AUDIO] >> 11) & 3;
	rd->zoom = (w[UMD_HOST_RD_AUDIO] >> 10) & 1;            // fj#71 (0 from a core before it)
	rd->cmd_ack   = (uint8_t)(w[UMD_HOST_RD_ACKS] >> 8);
	rd->flip_ack  = (uint8_t)w[UMD_HOST_RD_ACKS];
	rd->pcm_ack   = (uint8_t)(w[UMD_HOST_RD_PCM_ACK] >> 8);
	rd->win_ack   = (uint8_t)w[UMD_HOST_RD_PCM_ACK];
	rd->goto_open = (w[UMD_HOST_RD_STATUS] >> 9) & 1;         // P6d
	rd->sub_any   = (w[UMD_HOST_RD_STATUS] >> 8) & 1;
	rd->ui_sub    = (w[UMD_HOST_RD_STATUS] >> 7) & 1;
	rd->press_ack = (uint8_t)w[UMD_HOST_RD_PRESS_ACK];
	rd->sub_vis   = (w[UMD_HOST_RD_SHOWN] >> 15) & 1;
	rd->sub_seq   = (uint8_t)w[UMD_HOST_RD_SHOWN];
	// A12 SD2: the fabric decodes, and says which plane and rectangle the shown unit is in
	rd->sub_rect_v = have > UMD_HOST_RD_SUB_H;
	if (rd->sub_rect_v) {
		rd->sub_buf = (w[UMD_HOST_RD_SUB_PLANE] >> 15) & 1;
		rd->sub_x = w[UMD_HOST_RD_SUB_X]; rd->sub_y = w[UMD_HOST_RD_SUB_Y];
		rd->sub_w = w[UMD_HOST_RD_SUB_W]; rd->sub_h = w[UMD_HOST_RD_SUB_H];
	}
	rd->chapter   = w[UMD_HOST_RD_CHAPTER];
	rd->n_chapters = w[UMD_HOST_RD_N_CHAPTERS];
	rd->playlist  = w[UMD_HOST_RD_PLAYLIST];
	rd->n_items   = (uint32_t)w[UMD_HOST_RD_N_ITEMS_LO] | (uint32_t)w[UMD_HOST_RD_N_ITEMS_HI] << 16;
	rd->key_item  = (uint32_t)w[UMD_HOST_RD_KEY_LO] | (uint32_t)w[UMD_HOST_RD_KEY_HI] << 16;
	rd->pts       = (uint64_t)w[UMD_HOST_RD_PTS_LO] | (uint64_t)w[UMD_HOST_RD_PTS_MID] << 16 | (uint64_t)(w[UMD_HOST_RD_PTS_HI] & 1) << 32;
	rd->ev_w      = (uint8_t)w[UMD_HOST_RD_EV_W];
	rd->ev_lost   = (uint8_t)(w[UMD_HOST_RD_EV_W] >> 8);
	rd->ev_r      = (uint8_t)w[UMD_HOST_RD_EV_R];
	for (int k = 0; k < 4; k++) {
		rd->ev_code[k] = w[UMD_HOST_RD_EV0_CODE + 2 * k];
		rd->ev_data[k] = w[UMD_HOST_RD_EV0_DATA + 2 * k];
	}
}

// the glue's lock (umd_menu_set_lock): every call takes it for its own body, so the worker runs the
// engine, reads the image and draws without it; NULL (the benches): none
#define LK(s)   do { if ((s)->lk) (s)->lk((s)->lk_ud, 1); } while (0)
#define UNLK(s) do { if ((s)->lk) (s)->lk((s)->lk_ud, 0); } while (0)

void umd_menu_init(umd_menu_state *s)
{
	void (*lk)(void *, int) = s->lk;            // (kept across a reset: a mount re-inits under it)
	void *ud = s->lk_ud;
	if (lk) lk(ud, 1);
	uint32_t gen = s->play_gen;                 // (kept too: an event read before a mount stays stale)
	memset(s, 0, sizeof(*s));
	s->lk = lk; s->lk_ud = ud;
	s->play_gen = gen;
	if (lk) lk(ud, 0);
}

void umd_menu_set_lock(umd_menu_state *s, void (*lk)(void *ud, int on), void *ud)
{
	s->lk = lk; s->lk_ud = ud;
}

int umd_menu_flip_idle(umd_menu_state *s)
{
	LK(s);
	int idle = !s->flip_busy && !s->n_flip;
	UNLK(s);
	return idle;
}

#define PUSH(q, n, x) do { LK(s); int full = s->n == UMD_MENU_QLEN; if (full) s->n_full++; else s->q[s->n++] = *(x); UNLK(s); return full ? -1 : 0; } while (0)
int umd_menu_push_cmd(umd_menu_state *s, const umd_menu_pcmd *c)
{
	LK(s);
	int full = s->n_cmd == UMD_MENU_QLEN;
	if (full) s->n_full++;
	else {
		s->q_cmd[s->n_cmd++] = *c;
		if (c->code == UMD_PC_PLAYL) s->play_gen++;   // (fj#76: what was read before it is stale)
	}
	UNLK(s);
	return full ? -1 : 0;
}
int umd_menu_push_flip(umd_menu_state *s, const umd_menu_flip *f) { PUSH(q_flip, n_flip, f); }
int umd_menu_push_pcm(umd_menu_state *s, const umd_menu_pcm *p)   { PUSH(q_pcm, n_pcm, p); }
int umd_menu_push_press(umd_menu_state *s, uint16_t mask)          { PUSH(q_press, n_press, &mask); }

static void post(const umd_menu_state *s, umd_menu_event *ev, int *nev, int kind, uint32_t data)
{
	if (*nev < UMD_MENU_EVQ) { ev[*nev].kind = kind; ev[*nev].data = data; ev[*nev].gen = s->play_gen; (*nev)++; }
}

// a PLAYLIST the script has asked for and not yet landed: in flight, being retried, or still QUEUED
// (the events are read before the queue is sent: a TITLE_END read between a play() and its send is
// the old playlist's too -- found by the review)
static int pl_ahead(const umd_menu_state *s)
{
	if (s->inflight || s->land_wait) return 1;
	for (int i = 0; i < s->n_cmd; i++) if (s->q_cmd[i].code == UMD_PC_PLAYL) return 1;
	return 0;
}

static void event_in(umd_menu_state *s, uint32_t now, uint16_t code, uint16_t data, umd_menu_event *ev, int *nev)
{
	s->n_events++;
	switch (code) {
	case UMD_EV_KEY:
		post(s, ev, nev, UMD_ME_KEY, data);
		break;
	case UMD_EV_CHAPTER:
		if (pl_ahead(s)) { s->n_dropped++; break; }       // the old playlist's
		if (data != s->last_chapter) { post(s, ev, nev, UMD_ME_CHAPTER, data); s->last_chapter = data; }
		break;
	case UMD_EV_TITLE_END:
		if (pl_ahead(s)) { s->n_dropped++; break; }
		post(s, ev, nev, UMD_ME_PL_END, s->land_pl);
		break;
	case UMD_EV_BAD:
		s->n_bad++;
		if ((data & 0xF) == UMD_PC_PLAYL && s->inflight && s->have_last_pl) {
			s->land_wait = 0;
			s->seen_seek = 0;
			if (s->retries < UMD_MENU_RETRY_MAX) {
				s->retries++;
				s->retry_at = now + UMD_MENU_RETRY_MS;
				s->retry_due = 1;
			} else {
				s->n_gave_up++;
				s->inflight = 0;
				post(s, ev, nev, UMD_ME_GAVE_UP, s->last_pl.pl);
			}
		}
		break;
	default:
		break;
	}
}

static void step(umd_menu_state *s, uint32_t now, const umd_menu_rd *rd, const umd_menu_levels *lv,
                 umd_menu_event *ev, int *nev, uint16_t *wr, int *want_write, int *want_fast);
void umd_menu_step(umd_menu_state *s, uint32_t now, const umd_menu_rd *rd, const umd_menu_levels *lv,
                   umd_menu_event *ev, int *nev, uint16_t *wr, int *want_write, int *want_fast)
{
	LK(s);
	step(s, now, rd, lv, ev, nev, wr, want_write, want_fast);
	UNLK(s);
}
static void step(umd_menu_state *s, uint32_t now, const umd_menu_rd *rd, const umd_menu_levels *lv,
                 umd_menu_event *ev, int *nev, uint16_t *wr, int *want_write, int *want_fast)
{
	*nev = 0;
	*want_write = 0;
	// the levels: a changed window gets a new seq (it only echoes: the level is written in place)
	if (memcmp(&s->lv.win, &lv->win, sizeof(lv->win))) { s->win_seq++; *want_write = 1; }
	if (s->lv.grab != lv->grab || s->lv.ui != lv->ui || s->lv.menu != lv->menu || s->lv.mute != lv->mute ||
	    s->lv.ui_sub != lv->ui_sub) *want_write = 1;
	s->lv = *lv;

	if (rd && rd->nwords_ok) {
		if (!s->adopted) {
			// a restarted Main must not resend what the core already took
			s->cmd_seq = rd->cmd_ack; s->flip_seq = rd->flip_ack; s->pcm_seq = rd->pcm_ack;
			s->press_seq = rd->press_ack;
			s->rp = rd->ev_r;
			s->adopted = 1;
			*want_write = 1;
		}
		// the echoes first (a BAD in the same read follows its command's take)
		if (s->cmd_busy && rd->cmd_ack == s->cmd_seq) {
			s->cmd_busy = 0;
			post(s, ev, nev, UMD_ME_CMD_TAKEN, s->cur_cmd.code);
			if (s->cur_cmd.code == UMD_PC_PLAYL) { s->land_wait = 1; s->seen_seek = 0; s->land_pl = s->cur_cmd.pl; }
		}
		if (s->flip_busy && rd->flip_ack == s->flip_seq) s->flip_busy = 0;
		if (s->pcm_busy && rd->pcm_ack == s->pcm_seq) s->pcm_busy = 0;
		if (s->press_busy && rd->press_ack == s->press_seq) s->press_busy = 0;
		// the events, by count
		uint8_t avail = (uint8_t)(rd->ev_w - rd->ev_r), off = (uint8_t)(s->rp - rd->ev_r);
		if (avail > 8 || off > avail) {             // the counts disagree: resync to the core's
			s->n_resync++;
			s->rp = rd->ev_r;
			off = 0;
			if (avail > 8) avail = 0;
		}
		for (uint8_t k = off; k < avail && k < 4; k++) {
			event_in(s, now, rd->ev_code[k], rd->ev_data[k], ev, nev);
			s->rp++;
			*want_write = 1;
		}
		// the landing of a PLAYLIST: its seek seen, then that playlist, a picture shown, not seeking
		if (s->land_wait && rd->seeking) s->seen_seek = 1;
		if (s->land_wait && s->seen_seek && rd->playlist == s->land_pl && rd->shown && !rd->seeking && (rd->state == 1 || rd->state == 2)) {
			s->land_wait = 0;
			s->inflight = 0;
			s->retries = 0;
			post(s, ev, nev, UMD_ME_LANDED, s->land_pl);
			// THE LANDING'S CHAPTER is the one the play asked for: the core's word reads 0 through the
			// seek and is ranked a moment after the landing (player_ctl's tracker; its event only if the
			// rank changed). Posting the word lost Family Guy's main menu (its script opens the root at
			// chapter 2 only) when it still read 0 (the rig, 2026-10-03; docs/p9.md S3.3)
			uint16_t ch = s->last_pl.chapter ? s->last_pl.chapter : rd->chapter ? rd->chapter : 1;
			post(s, ev, nev, UMD_ME_CHAPTER, ch);
			s->last_chapter = ch;
		}
	}

	// a PLAYLIST refused as busy, resent (nothing else was sent since: it holds the channel)
	if (s->adopted && s->retry_due && (int32_t)(now - s->retry_at) >= 0 && !s->cmd_busy) {
		s->cur_cmd = s->last_pl;
		s->cmd_seq++;
		s->cmd_busy = 1;
		s->n_retries++;
		s->retry_due = 0;
		*want_write = 1;
	}

	// the next record of each channel, after the last one's echo
	if (s->adopted) {
		if (!s->cmd_busy && !s->inflight && s->n_cmd) {
			s->cur_cmd = s->q_cmd[0];
			memmove(&s->q_cmd[0], &s->q_cmd[1], (size_t)(--s->n_cmd) * sizeof(s->q_cmd[0]));
			s->cmd_seq++;
			s->cmd_busy = 1;
			s->n_cmds++;
			if (s->cur_cmd.code == UMD_PC_PLAYL) {
				s->last_pl = s->cur_cmd; s->have_last_pl = 1; s->inflight = 1; s->land_wait = 0; s->retries = 0;
			}
			*want_write = 1;
		}
		if (!s->flip_busy && s->n_flip) {
			s->cur_flip = s->q_flip[0];
			memmove(&s->q_flip[0], &s->q_flip[1], (size_t)(--s->n_flip) * sizeof(s->q_flip[0]));
			s->flip_seq++;
			s->flip_busy = 1;
			s->n_flips++;
			*want_write = 1;
		}
		if (!s->press_busy && s->n_press) {          // P6d: the next press after the last one's echo
			s->cur_press = s->q_press[0];
			memmove(&s->q_press[0], &s->q_press[1], (size_t)(--s->n_press) * sizeof(s->q_press[0]));
			s->press_seq++;
			s->press_busy = 1;
			s->n_presses++;
			*want_write = 1;
		}
		if (!s->pcm_busy && s->n_pcm) {
			s->cur_pcm = s->q_pcm[0];
			memmove(&s->q_pcm[0], &s->q_pcm[1], (size_t)(--s->n_pcm) * sizeof(s->q_pcm[0]));
			s->pcm_seq++;
			s->pcm_busy = 1;
			s->n_pcms++;
			*want_write = 1;
		}
	}

	// HOST_WR words 5..39 (valid once adopted: before that the glue sends B4's first four only)
	const umd_menu_pcmd *c = &s->cur_cmd;
	wr[UMD_HOST_WR_PCMD]       = (uint16_t)(s->cmd_seq << 8 | (c->code & 0xF) << 4 | (c->arg & 0xF));
	wr[UMD_HOST_WR_PCMD_PL]    = c->pl;
	wr[UMD_HOST_WR_PCMD_ITEM_LO] = (uint16_t)c->item;
	wr[UMD_HOST_WR_PCMD_ITEM_HI] = (uint16_t)(c->item >> 16);
	wr[UMD_HOST_WR_PCMD_PTS0]  = (uint16_t)c->pts;
	wr[UMD_HOST_WR_PCMD_PTS1]  = (uint16_t)(c->pts >> 16);
	wr[UMD_HOST_WR_PCMD_PTS2]  = (uint16_t)(c->pts >> 32);
	wr[UMD_HOST_WR_GRAB]       = s->lv.grab;
	wr[UMD_HOST_WR_CTL]        = (uint16_t)((s->lv.ui ? 0x8000 : 0) | (s->lv.menu ? 0x4000 : 0) | (s->lv.mute ? 0x2000 : 0) |
	                                        (s->lv.ui_sub ? 0x1000 : 0));
	wr[UMD_HOST_WR_EV_RP]      = s->rp;
	const umd_menu_flip *f = &s->cur_flip;
	wr[UMD_HOST_WR_FLIP]       = (uint16_t)(s->flip_seq << 8 | (f->buf & 3) << 1 | (f->shown & 1));   // (P6d: planes 0-3)
	wr[UMD_HOST_WR_FLIP_X]     = f->x;
	wr[UMD_HOST_WR_FLIP_Y]     = f->y;
	wr[UMD_HOST_WR_FLIP_W]     = f->w;
	wr[UMD_HOST_WR_FLIP_H]     = f->h;
	const umd_menu_pcm *p = &s->cur_pcm;
	wr[UMD_HOST_WR_PCM]        = (uint16_t)(s->pcm_seq << 8 | (p->stereo & 1));
	wr[UMD_HOST_WR_PCM_START_LO] = (uint16_t)p->start;
	wr[UMD_HOST_WR_PCM_START_HI] = (uint16_t)((p->start >> 16) & 0xFF);
	wr[UMD_HOST_WR_PCM_LEN_LO] = (uint16_t)p->len;
	wr[UMD_HOST_WR_PCM_LEN_HI] = (uint16_t)((p->len >> 16) & 0xFF);
	const umd_menu_win *w = &s->lv.win;
	wr[UMD_HOST_WR_WIN]        = (uint16_t)(s->win_seq << 8 | (w->on ? 1 : 0));
	wr[UMD_HOST_WR_WIN_X]      = w->x;
	wr[UMD_HOST_WR_WIN_Y]      = w->y;
	wr[UMD_HOST_WR_WIN_W]      = w->w;
	wr[UMD_HOST_WR_WIN_H]      = w->h;
	wr[UMD_HOST_WR_WIN_HS_LO]  = (uint16_t)w->hs;
	wr[UMD_HOST_WR_WIN_HS_HI]  = (uint16_t)((w->hs >> 16) & 0x3FF);
	wr[UMD_HOST_WR_WIN_VS_LO]  = (uint16_t)w->vs;
	wr[UMD_HOST_WR_WIN_VS_HI]  = (uint16_t)((w->vs >> 16) & 0x3FF);
	wr[UMD_HOST_WR_WIN_X0_LO]  = (uint16_t)w->x0;
	wr[UMD_HOST_WR_WIN_X0_HI]  = (uint16_t)((w->x0 >> 16) & 0x3FF);
	wr[UMD_HOST_WR_WIN_Y0_LO]  = (uint16_t)w->y0;
	wr[UMD_HOST_WR_WIN_Y0_HI]  = (uint16_t)((w->y0 >> 16) & 0x3FF);
	wr[UMD_HOST_WR_PRESS]      = (uint16_t)(s->press_seq << 8);          // P6d
	wr[UMD_HOST_WR_PRESS_MASK] = s->cur_press;
	if (!s->adopted) *want_write = 0;

	int busy = s->n_cmd || s->n_flip || s->n_pcm || s->n_press || s->cmd_busy || s->flip_busy || s->pcm_busy || s->press_busy ||
	           s->land_wait || s->inflight || s->retry_due;
	*want_fast = busy || s->lv.grab;
	s->keys_only = !busy && s->lv.grab;      // (the glue reads at UMD_MENU_READ_KEYS_MS then)
}
