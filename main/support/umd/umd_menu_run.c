// umd_menu_run.c -- see umd_menu_run.h.
#include "umd_menu_run.h"

#include <math.h>
#include <stdarg.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void rtr(umd_menu_run *r, const char *fmt, ...)
{
	if (!r->sv.trace) return;
	char b[300];
	int n = snprintf(b, sizeof(b), "%8u ", r->now);
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b + n, sizeof(b) - (size_t)n, fmt, ap);
	va_end(ap);
	r->sv.trace(r->sv.ud, b);
}

// ---- the host's services ------------------------------------------------------------------------
static int s_load_rco(void *ud, const char *name, const uint8_t **buf, size_t *len)
{
	umd_menu_run *r = (umd_menu_run *)ud;
	char path[64];
	snprintf(path, sizeof(path), "/UMD_VIDEO/RESOURCE/%s.RCO", name);
	uint8_t *b = NULL;
	size_t n = 0;
	if (!r->have_disc || umd_iso_read_file(&r->iso, path, 32u << 20, &b, &n)) return -1;
	free(r->rco_buf);                       // (the engine copies what it keeps of the previous one)
	r->rco_buf = b;
	*buf = b; *len = n;
	return 0;
}
static int s_decode(void *ud, int f, const uint8_t *d, size_t n, int *w, int *h, uint8_t **rgba)
{
	umd_menu_run *r = (umd_menu_run *)ud;
	return r->sv.decode_image ? r->sv.decode_image(r->sv.ud, f, d, n, w, h, rgba) : -1;
}
static void s_trace(void *ud, const char *line)
{
	umd_menu_run *r = (umd_menu_run *)ud;
	if (r->sv.trace) r->sv.trace(r->sv.ud, line);
}
// RS1: a store to the card, skipped when it repeats the disc's last (a quit stores what onExit's
// setUserData and the resume point already stored: three fsync'd writes become one)
static void kept_put(umd_menu_run *r, const char *t, size_t n)
{
	if (!r->sv.kept_store || !r->disc_id[0]) return;
	if (r->kept_last && r->kept_last_n == n && !memcmp(r->kept_last, t, n)) { r->n_kept_same++; return; }
	free(r->kept_last);
	r->kept_last = NULL; r->kept_last_n = 0;
	if (r->sv.kept_store(r->sv.ud, r->disc_id, t, n)) {      // (unknown on the card now: the next store retries)
		r->n_kept_fail++;
		rtr(r, "HOST the kept text for %s NOT written to the card (%u bytes; %u refused)", r->disc_id, (unsigned)n, r->n_kept_fail);
		return;
	}
	r->n_kept_writes++;
	r->kept_last = (char *)malloc(n + 1);
	if (r->kept_last) { memcpy(r->kept_last, t, n); r->kept_last[n] = 0; }
	r->kept_last_n = n;
}
static void store_kept(umd_menu_run *r)
{
	if (!r->sv.kept_store || !r->disc_id[0] || !r->H.m) return;
	size_t n;
	char *t = umd_mh_kept(&r->H, &n);
	if (t) { kept_put(r, t, n); free(t); }
}
static void s_kept_changed(void *ud) { store_kept((umd_menu_run *)ud); }

// RS4, the disc screen (below the runner's own functions)
static void ds_free_art(umd_menu_run *r);
static void ds_rd(umd_menu_run *r, const umd_menu_rd *rd);
static void ds_forget(umd_menu_run *r);

// ---- RS2, the tracker (umd_menu_run.h THE TRACKER, docs/resume.md §3) -------------------------------
// a place's chapter: the chapters starting at or before (item, pts) (the PLAYLIST command's rank)
static uint16_t tr_rank(const umd_menu_run *r, uint16_t pl, uint32_t item, uint64_t pts)
{
	uint16_t k = 0;
	for (uint32_t c = 1; c <= r->pl.e[pl].nchapters && c <= 0xFFFF; c++) {
		uint32_t ci; uint64_t cp;
		if (umd_pl_chapter(&r->pl, pl, c, &ci, &cp)) break;
		if (ci < item || (ci == item && cp <= pts)) k = (uint16_t)c; else break;
	}
	return k;
}
static void tr_save(umd_menu_run *r, const char *why)
{
	if (!r->tr_on || !r->tr_have) return;
	char t[160];
	int n = snprintf(t, sizeof(t), "R 1 %u %u %llu %d %d 1 %d %d\n", r->tr_pl, r->tr_item, (unsigned long long)r->tr_pts,
	                 0xE000, 0xBD00 + r->tr_audio, 0xBD80 + r->tr_sub, r->tr_sub_on);
	uint32_t was = r->n_kept_writes + r->n_kept_same;
	kept_put(r, t, (size_t)n);
	if (r->n_kept_writes + r->n_kept_same != was) r->n_tr_saves++;
	rtr(r, "HOST resume point saved (%s): playlist %u item %u pts %llu, audio %u, subtitles %s %u", why, r->tr_pl + 1,
	    r->tr_item, (unsigned long long)r->tr_pts, r->tr_audio, r->tr_sub_on ? "on" : "off", r->tr_sub);
}
static void tr_forget(umd_menu_run *r, const char *why)
{
	kept_put(r, "", 0);
	r->tr_have = 0;
	rtr(r, "HOST resume point forgotten: %s", why);
}
// at a mount the engine does not take: the tracker on, the disc's point (if any) to resume
static void tr_arm(umd_menu_run *r)
{
	r->tr_on = 1; r->tr_have = 0; r->tr_state_was = -1; r->tr_wait_seek = 0; r->tr_go = 0; r->tr_landing = 0;
	if (!r->sv.kept_load || !r->disc_id[0] || !r->have_pl) return;
	size_t n = 0;
	char *t = r->sv.kept_load(r->sv.ud, r->disc_id, &n);
	free(r->kept_last);                         // (what the card holds: an equal store is skipped)
	r->kept_last = t; r->kept_last_n = t ? n : 0;
	unsigned have, pl, item; unsigned long long pts; int v, a, af, sb, sf;
	if (!t || sscanf(t, "R %u %u %u %llu %d %d %d %d %d", &have, &pl, &item, &pts, &v, &a, &af, &sb, &sf) != 9 || !have) return;
	if (pl >= r->pl.n || item >= r->pl.e[pl].nitems) {
		r->n_tr_dropped++;
		tr_forget(r, "its playlist / item is not on the disc");
		return;
	}
	r->tr_go = 1;
	r->tr_go_pl = (uint16_t)pl; r->tr_go_item = item; r->tr_go_pts = pts;
	r->tr_go_audio = (a >= 0xBD00 && a <= 0xBD0F) ? a - 0xBD00 : -1;
	r->tr_go_sub = (sb >= 0xBD80 && sb <= 0xBD9F && sf) ? 0x20 | (sb - 0xBD80) : -1;
	rtr(r, "HOST resume point found: playlist %u item %u pts %llu", pl + 1, item, pts);
}
// every read while the tracker is on: the sample, the Pause / Stop saves, the idle core
static void tr_rd(umd_menu_run *r, const umd_menu_rd *rd)
{
	if (rd->state == 0) {                       // the OSD's Reset (no hook): the disc is gone
		if (r->tr_state_was > 0) tr_save(r, "the core went idle");
		r->tr_state_was = 0;
		return;
	}
	if (r->tr_wait_seek && rd->seeking) r->tr_wait_seek = 0;
	if (!r->tr_go && !r->tr_landing && !r->tr_wait_seek && (rd->state == 1 || rd->state == 2) && rd->shown && !rd->seeking) {
		r->tr_have = 1;
		r->tr_pl = (uint16_t)rd->playlist; r->tr_item = rd->key_item; r->tr_pts = rd->pts;
		r->tr_audio = rd->audio_track; r->tr_sub = rd->sub_track; r->tr_sub_on = rd->sub_on;
	}
	if (r->tr_state_was == 1 && rd->state == 2) tr_save(r, "pause");
	else if ((r->tr_state_was == 1 || r->tr_state_was == 2) && rd->state == 3) tr_save(r, "stop");
	r->tr_state_was = rd->state;
}
static void tr_events(umd_menu_run *r, const umd_menu_event *ev, int nev)
{
	for (int i = 0; i < nev; i++) {
		if (ev[i].kind == UMD_ME_PL_END) {          // R4: the title played to its end
			tr_forget(r, "the title ended");
			r->tr_wait_seek = 1; r->tr_go = 0; r->tr_landing = 0;
			// R5c: the XMB's return to the disc -- STOP, the disc screen, its "> Play"
			umd_menu_pcmd c;
			memset(&c, 0, sizeof(c));
			c.code = UMD_PC_STOP;
			umd_menu_push_cmd(r->L, &c);
			r->ds_ended = 1;
		} else if (ev[i].kind == UMD_ME_LANDED && r->tr_landing && ev[i].data == r->tr_go_pl) {
			r->tr_landing = 0;
			r->n_tr_resumes++;
			rtr(r, "HOST resume landed: playlist %u", r->tr_go_pl + 1);
		} else if (ev[i].kind == UMD_ME_GAVE_UP && r->tr_landing && ev[i].data == r->tr_go_pl) {
			r->tr_landing = 0;
			r->n_tr_dropped++;
			tr_forget(r, "the core never took it");
		}
	}
}
// the mount's start landed: the point sent (PLAYLIST, then the streams, as the engine's resume)
static void tr_go(umd_menu_run *r)
{
	if (!r->tr_on || !r->tr_go || !r->have_rd || !umd_mh_ready(&r->rd)) return;
	r->tr_go = 0;
	r->tr_landing = 1;
	umd_menu_pcmd c;
	memset(&c, 0, sizeof(c));
	c.code = UMD_PC_PLAYL; c.pl = r->tr_go_pl; c.item = r->tr_go_item; c.pts = r->tr_go_pts;
	c.chapter = tr_rank(r, r->tr_go_pl, r->tr_go_item, r->tr_go_pts);
	umd_menu_push_cmd(r->L, &c);
	if (r->tr_go_audio >= 0 && r->tr_go_audio != (int)r->rd.audio_track) {
		memset(&c, 0, sizeof(c));
		c.code = UMD_PC_AUDIO_SET; c.arg = (uint8_t)r->tr_go_audio;
		umd_menu_push_cmd(r->L, &c);
	}
	if (r->tr_go_sub >= 0) {
		memset(&c, 0, sizeof(c));
		c.code = UMD_PC_SUB_SET; c.item = (uint32_t)r->tr_go_sub;
		umd_menu_push_cmd(r->L, &c);
	}
	rtr(r, "HOST resume: playlist %u item %u pts %llu", r->tr_go_pl + 1, r->tr_go_item, (unsigned long long)r->tr_go_pts);
}
static void s_quit(void *ud) { ((umd_menu_run *)ud)->quit_osd = 1; }
static void s_sound(void *ud, uint32_t key, const int16_t *pcm, uint32_t frames, int nch)
{
	umd_menu_run *r = (umd_menu_run *)ud;
	umd_menu_pcm p;
	memset(&p, 0, sizeof(p));
	if (!frames || !pcm) { umd_menu_push_pcm(r->L, &p); return; }      // stop
	r->n_sounds++;
	int k = 0;
	while (k < r->n_snd && r->snd[k].key != key) k++;
	if (k == r->n_snd) {
		uint64_t words = ((uint64_t)frames * (uint64_t)nch + 3) / 4;
		if (words > UMD_MR_PCM_WORDS) {
			r->n_refused++;
			rtr(r, "HOST sound %08x refused: %u frames past the 8 MB region", key, frames);
			return;
		}
		if (r->pcm_top + words > UMD_MR_PCM_WORDS || r->n_snd == (int)(sizeof(r->snd) / sizeof(r->snd[0]))) {
			rtr(r, "HOST the PCM region full: its sounds forgotten, placed again from the bottom");
			r->n_snd = 0; r->pcm_top = 0; k = 0;
		}
		r->snd[k].key = key; r->snd[k].word = r->pcm_top; r->snd[k].frames = frames; r->snd[k].stereo = nch == 2;
		if (r->sv.pcm_put) r->sv.pcm_put(r->sv.ud, r->pcm_top, pcm, frames * (uint32_t)nch);
		r->pcm_top += (uint32_t)words;
		r->n_snd++;
		r->n_placed++;
		rtr(r, "HOST sound %08x placed at word %u: %u frames, %s", key, r->snd[k].word, frames, nch == 2 ? "stereo" : "mono");
	}
	p.start = r->snd[k].word; p.len = r->snd[k].frames; p.stereo = r->snd[k].stereo;
	umd_menu_push_pcm(r->L, &p);
}

// ---- the runner --------------------------------------------------------------------------------
void umd_mr_init(umd_menu_run *r, const umd_mr_services *sv, umd_menu_state *L)
{
	memset(r, 0, sizeof(*r));
	r->sv = *sv;
	r->L = L;
	r->front = -1; r->flipping = -1;
	umd_panel_init(&r->P);                  // P6d: the control panel
	r->pfront = r->pflipping = -1;
	r->psub_was = -1;
	r->hs.ud = r; r->hs.load_rco = s_load_rco; r->hs.decode_image = s_decode;
	r->hs.trace = sv->trace ? s_trace : NULL;
	r->hs.kept_changed = s_kept_changed; r->hs.quit = s_quit; r->hs.sound = s_sound;
	umd_mh_init(&r->H, &r->hs, L, &r->pl);
}

// quit the disc that is up: its onExit, its kept text stored, the engine gone (the levels follow)
static void quit(umd_menu_run *r, const char *why, int detached)
{
	tr_save(r, why);                        // RS2: the tracker's point (no engine)
	r->tr_on = 0; r->tr_go = 0; r->tr_landing = 0;
	if (r->H.m && r->H.mode != UMD_MH_NONE) {
		size_t n;
		char *t = umd_mh_quit(&r->H, &n, detached);
		if (t) kept_put(r, t, n);
		free(t);
		// fj#89: the point the relaunch can resume (the disc screen's Play line), as written
		r->ds_pt_have = r->H.resume.have;
		r->ds_pt_pl = r->H.resume.pl; r->ds_pt_item = r->H.resume.item; r->ds_pt_pts = r->H.resume.pts;
		r->n_quits++;
		rtr(r, "HOST quit (%s): %u bytes kept for %s", why, (unsigned)n, r->disc_id);
	}
	umd_mh_free(&r->H);
	r->armed = 0;
	r->started = 0;                         // (umd_menu_away posts only while a disc runs: else a busy loop)
	r->front = -1; r->flipping = -1; r->need_frame = 0; r->staged = 0;
}

static void drop_disc(umd_menu_run *r)
{
	if (r->have_pl) umd_pl_free(&r->pl);
	r->have_pl = 0; r->have_disc = 0;
	r->disc_id[0] = 0; r->start[0] = 0;
	free(r->kept_last); r->kept_last = NULL; r->kept_last_n = 0;
	ds_free_art(r);
	r->ds_up = 0; r->ds_state_was = -1; r->ds_key[0] = 0; r->ds_relaunch = 0; r->ds_pt_have = 0;
	r->n_snd = 0; r->pcm_top = 0;              // (a new disc: its sounds placed anew)
	free(r->rco_buf); r->rco_buf = NULL;
	umd_mh_init(&r->H, &r->hs, r->L, &r->pl);
}

void umd_mr_free(umd_menu_run *r)
{
	quit(r, "freed", 1);
	drop_disc(r);
	free(r->canvas); r->canvas = NULL;
	free(r->frame); r->frame = NULL;
	free(r->pframe); r->pframe = NULL;
	free(r->ds_frame); r->ds_frame = NULL;
}

static char *res_names[256];
static int n_res;
static void res_ent(void *ud, const char *name, const umd_iso_entry *e)
{
	(void)ud; (void)e;
	if (n_res < 256) { size_t l = strlen(name) + 1; res_names[n_res] = (char *)malloc(l); if (res_names[n_res]) memcpy(res_names[n_res++], name, l); }
}

int umd_mr_mount(umd_menu_run *r, int ok, size_t (*read)(void *ud, uint64_t off, void *buf, size_t n),
                 void *read_ud, uint64_t size, const char *lang, uint32_t now)
{
	r->now = now;
	quit(r, "a new mount", 1);                // (fj#70: the new image is already the core's)
	drop_disc(r);
	umd_menu_init(r->L);                     // the core's seqs adopted again at the next read
	umd_panel_init(&r->P);                  // P6d: a mount closes the panel (a new title)
	r->started = 0; r->have_rd = 0;
	if (!ok) { rtr(r, "HOST eject"); return -1; }
	if (umd_iso_open(&r->iso, read, read_ud, size)) { rtr(r, "HOST the image: %s -- the core plays on its own", r->iso.err); return -1; }
	r->have_disc = 1;
	// the disc id first (RS1): Disc Menus Off and a disc without menus need it too (RS2's resume)
	if (umd_iso_disc_id(&r->iso, r->disc_id, sizeof(r->disc_id))) r->disc_id[0] = 0;
	uint8_t *raw = NULL;
	size_t rawn = 0;
	if (umd_iso_read_file(&r->iso, "/UMD_VIDEO/PLAYLIST.UMD", 64u << 20, &raw, &rawn)) {
		rtr(r, "HOST no PLAYLIST.UMD (%s) -- the core plays on its own", r->iso.err);
		return -1;
	}
	int bad = umd_pl_parse(&r->pl, raw, rawn);
	free(raw);
	if (bad) { rtr(r, "HOST PLAYLIST.UMD refused: %s -- the core plays on its own", r->pl.err); return -1; }
	r->have_pl = 1;
	// M3b, Disc Menus Off (the maintainer, 2026-10-03): the disc that was up is quit as by any mount
	// (above: its onExit, its kept text), then nothing is armed -- the core plays the mount's own
	// choice, the longest playlist, as on a stock Main; RS2: the tracker keeps its point
	if (r->menus_off) {
		rtr(r, "HOST mount: disc %s, Disc Menus Off -- the core plays the disc on its own", r->disc_id[0] ? r->disc_id : "-");
		tr_arm(r);
		return -1;
	}
	n_res = 0;
	umd_iso_listdir(&r->iso, "/UMD_VIDEO/RESOURCE", res_ent, NULL);
	int none = umd_mh_pick_start((const char *const *)res_names, n_res, lang, r->start);
	for (int i = 0; i < n_res; i++) free(res_names[i]);
	if (none) { r->start[0] = 0; rtr(r, "HOST no startup RCO: the disc has no menus, the core plays it"); tr_arm(r); return -1; }
	r->armed = 1;
	rtr(r, "HOST mount: disc %s, start %s (language %s): armed", r->disc_id[0] ? r->disc_id : "-", r->start, lang ? lang : "EN");
	return 0;
}

// P9-6: the quit the host asked for (Circle the script did not take), at once: the disc's onExit, its
// kept text, STOP, the OSD
static void quit_p96(umd_menu_run *r)
{
	if (!r->quit_osd) return;
	r->quit_osd = 0;
	quit(r, "Circle, P9-6", 0);
	r->ds_relaunch = r->have_pl && r->start[0];     // (R5f: Play on the disc screen relaunches it)
	umd_menu_pcmd c;
	memset(&c, 0, sizeof(c));
	c.code = UMD_PC_STOP;
	umd_menu_push_cmd(r->L, &c);
	if (r->sv.open_osd) r->sv.open_osd(r->sv.ud);
}

// ---- the control panel (P6d, docs/panel.md §3.3) -------------------------------------------------------
static int engine_runs(const umd_menu_run *r) { return r->started && r->H.m && r->H.mode != UMD_MH_NONE; }
// a frame owed (RENDER, PIPELINED): a drawn frame not yet put is dropped -- it is drawn again, never put stale
static void owe_frame(umd_menu_run *r) { r->need_frame = 1; r->staged = 0; }

// the panel's presses: its actions out, a UMD Menu as the engine's own key (into e2, the engine's events)
static void panel_keys(umd_menu_run *r, uint32_t mask, umd_menu_event *e2, int *n2, int cap)
{
	umd_panel_act a[16];
	int n = umd_panel_key(&r->P, mask, a, 16);
	for (int k = 0; k < n; k++) {
		r->n_panel_acts++;
		switch (a[k].kind) {
		case UMD_PA_PRESS:
			rtr(r, "PANEL press %04x", a[k].arg);
			if (r->ds_up && (a[k].arg & (1u << UMD_PB_STOP))) { ds_forget(r); break; }   // (R7)
			umd_menu_push_press(r->L, (uint16_t)a[k].arg);
			break;
		case UMD_PA_CMD: {
			umd_menu_pcmd c;
			memset(&c, 0, sizeof(c));
			c.code = (uint8_t)a[k].arg;
			rtr(r, "PANEL command %u", c.code);
			umd_menu_push_cmd(r->L, &c);
			break;
		}
		case UMD_PA_MENU:                       // the disc's own UMD Menu (its onMenu)
			rtr(r, "PANEL UMD Menu");
			if (*n2 < cap) { e2[*n2].kind = UMD_ME_KEY; e2[*n2].data = 1u << UMD_PB_MENU; e2[*n2].gen = 0; (*n2)++; }
			break;
		case UMD_PA_QUIT:                       // Stop over a disc menu: P9-6's quit
			rtr(r, "PANEL Stop over a disc menu: quit (P9-6)");
			r->quit_osd = 1;
			break;
		}
	}
}

void umd_mr_feed(umd_menu_run *r, const umd_menu_rd *rd, const umd_menu_event *ev, int nev)
{
	if (rd && rd->nwords_ok) {
		r->rd = *rd;
		r->have_rd = 1;
		umd_mh_rd(&r->H, rd);
		// the panel reads every HOST_RD, the engine or none (a disc menu up: the engine's ui, as published)
		umd_panel_rd prd;
		prd.state = rd->state; prd.seeking = rd->seeking; prd.goto_open = rd->goto_open; prd.sub_any = rd->sub_any;
		prd.engine = engine_runs(r);
		prd.menu_up = prd.engine && r->ui_was;
		umd_panel_read(&r->P, &prd, r->now);
	}
	// a grabbed press goes to the panel when its grab covers the button, to the engine otherwise
	enum { CAP = UMD_MENU_EVQ + 8 };
	umd_menu_event e2[CAP];
	int n2 = 0;
	for (int i = 0; i < nev; i++) {
		umd_menu_event e = ev[i];
		if (e.kind == UMD_ME_KEY) {
			uint16_t pg;
			int show;
			umd_panel_levels(&r->P, &pg, &show);
			uint32_t pk = e.data & pg;
			e.data &= ~(uint32_t)pg;
			if (pk) panel_keys(r, pk, e2, &n2, CAP);
			if (r->ds_up && (e.data & (1u << UMD_JB_STOP))) {     // R7: Stop on the disc screen (grabbed)
				ds_forget(r);
				e.data &= ~(1u << UMD_JB_STOP);
			}
			if (!e.data) continue;
		}
		if (n2 < CAP) e2[n2++] = e;
	}
	if (n2) umd_mh_events(&r->H, e2, n2);
	// RS2: the read's events before its sample (a title's end and its STOP arrive in one read: the end
	// forgets the point first, so the STOP finds nothing to write)
	if (r->tr_on) tr_events(r, e2, n2);
	if (r->tr_on && rd && rd->nwords_ok) tr_rd(r, rd);
	if (rd && rd->nwords_ok && !engine_runs(r)) ds_rd(r, rd);
	quit_p96(r);
}

// ---- RS4, the disc screen (umd_menu_run.h THE DISC SCREEN) ---------------------------------------------
static void ds_free_art(umd_menu_run *r)
{
	free(r->ds_pic1); free(r->ds_icon0);
	r->ds_pic1 = r->ds_icon0 = NULL;
	r->ds_loaded = 0; r->ds_ended = 0; r->ds_title[0] = 0;
}

static uint8_t *ds_png(umd_menu_run *r, const char *path, int *w, int *h)
{
	uint8_t *b = NULL, *rgba = NULL;
	size_t n = 0;
	*w = *h = 0;
	if (umd_iso_read_file(&r->iso, path, 16u << 20, &b, &n)) return NULL;
	umd_ds_png_plain(b, &n);                       // (the stored colours, as the PSP shows them)
	int bad = !r->sv.decode_image || r->sv.decode_image(r->sv.ud, 0, b, n, w, h, &rgba);
	free(b);
	if (bad || !rgba) { rtr(r, "HOST disc screen: %s not decoded", path); r->n_ds_refused++; return NULL; }
	if (*w <= 0 || *h <= 0 || *w > UMD_DS_MAX_SIDE || *h > UMD_DS_MAX_SIDE) {
		rtr(r, "HOST disc screen: %s refused, %d x %d past %d a side", path, *w, *h, UMD_DS_MAX_SIDE);
		r->n_ds_refused++;
		free(rgba);
		return NULL;
	}
	return rgba;
}

static void ds_load(umd_menu_run *r)
{
	if (r->ds_loaded || !r->have_disc) return;
	r->ds_loaded = 1;
	r->ds_pic1 = ds_png(r, "/UMD_VIDEO/PIC1.PNG", &r->ds_pw, &r->ds_ph);
	r->ds_icon0 = ds_png(r, "/UMD_VIDEO/ICON0.PNG", &r->ds_iw, &r->ds_ih);
	char sfo_title[UMD_DS_TITLE_MAX] = "";
	uint8_t *b = NULL;
	size_t n = 0;
	if (umd_iso_read_file(&r->iso, "/UMD_VIDEO/PARAM.SFO", 1u << 20, &b, &n) == 0) umd_ds_sfo_title(b, n, sfo_title, sizeof(sfo_title));
	free(b);
	umd_ds_display_title(sfo_title, r->image_name, r->ds_title, sizeof(r->ds_title));
	rtr(r, "HOST disc screen art: PIC1 %d x %d, ICON0 %d x %d, title \"%s\"", r->ds_pw, r->ds_ph, r->ds_iw, r->ds_ih, r->ds_title);
}

// a place's time in ms from its playlist's start (the Play line)
static uint32_t ds_pos_ms(const umd_menu_run *r, uint32_t pl, uint32_t item, uint64_t pts)
{
	if (!r->have_pl || pl >= r->pl.n) return 0;
	const umd_pl_entry *e = &r->pl.e[pl];
	uint64_t acc = 0;
	for (uint32_t k = 0; k < item && k < e->nitems; k++) acc += e->items[k].out > e->items[k].in ? e->items[k].out - e->items[k].in : 0;
	if (item < e->nitems && pts > e->items[item].in) acc += pts - e->items[item].in;
	return (uint32_t)(acc / 90);
}

// R7: Stop on the disc screen forgets the disc's place (umd_menu_run.h THE DISC SCREEN)
static void ds_forget(umd_menu_run *r)
{
	r->n_ds_forgets++;
	kept_put(r, "", 0);                     // (the whole text: a menu disc's relaunch starts it fresh)
	if (r->tr_on) { r->tr_have = 0; r->tr_wait_seek = 1; r->tr_go = 0; r->tr_landing = 0; }
	if (!r->ds_relaunch) r->ds_ended = 2;   // (with no engine, Play: the title from its start, R5c's path)
	r->ds_pt_have = 0;
	rtr(r, "HOST disc screen: Stop -- the disc's place forgotten");
}

// every read with no engine: R5c's Play after the end (the state leaving stop: the title from its start)
static void ds_rd(umd_menu_run *r, const umd_menu_rd *rd)
{
	if (r->ds_relaunch && r->ds_state_was == 3 && (rd->state == 1 || rd->state == 2)) {
		r->ds_relaunch = 0;
		r->armed = 1;                           // (the start fires at the next ready read: a continue)
		rtr(r, "HOST disc screen: Play -- the disc's menus again (%s)", r->kept_last_n ? "its kept text" : "nothing kept: a fresh start");
	}
	if (r->ds_ended && r->ds_state_was == 3 && (rd->state == 1 || rd->state == 2) && r->have_pl && rd->playlist < r->pl.n) {
		umd_menu_pcmd c;
		memset(&c, 0, sizeof(c));
		c.code = UMD_PC_PLAYL; c.pl = (uint16_t)rd->playlist; c.item = 0;
		c.pts = r->pl.e[rd->playlist].nitems ? r->pl.e[rd->playlist].items[0].in : 0;
		c.chapter = tr_rank(r, c.pl, 0, c.pts);
		umd_menu_push_cmd(r->L, &c);
		rtr(r, "HOST disc screen: Play after %s -- playlist %u from its start", r->ds_ended == 2 ? "its place was forgotten" : "the title's end", c.pl + 1);
		r->ds_ended = 0;
	}
	r->ds_state_was = rd->state;
}

// shown or hidden by the core's state; its key (what the page shows) recomputed
static void ds_update(umd_menu_run *r)
{
	int want = r->have_disc && r->have_rd && r->rd.state == 3 && !r->rd.seeking && !engine_runs(r) && !r->armed;
	if (want && !r->ds_up) {
		ds_load(r);
		r->n_ds_shows++;
		owe_frame(r);
		rtr(r, "HOST disc screen up");
	} else if (!want && r->ds_up) rtr(r, "HOST disc screen down");
	r->ds_up = want;
	if (want) {
		char hint[32];
		// fj#89: what Play resumes -- after a menu disc's quit the engine's kept point (its relaunch), else
		// the core's stopped picture (Play releases the freeze there)
		if (r->ds_relaunch) umd_ds_hint(hint, sizeof(hint), r->ds_pt_have, ds_pos_ms(r, r->ds_pt_pl, r->ds_pt_item, r->ds_pt_pts));
		else umd_ds_hint(hint, sizeof(hint), !r->ds_ended, ds_pos_ms(r, r->rd.playlist, r->rd.key_item, r->rd.pts));
		snprintf(r->ds_want_key, sizeof(r->ds_want_key), "%d|%s", r->rd.menu_aa > 2 ? 0 : r->rd.menu_aa, hint);
	}
}

void umd_mr_tick(umd_menu_run *r, uint32_t now)
{
	uint32_t ms = now - r->now;
	r->now = now;
	// the start: armed by a mount, fired when the mount landed
	if (r->armed && !r->started && r->have_rd && umd_mh_ready(&r->rd)) {
		r->armed = 0;
		r->started = 1;
		size_t kn = 0;
		char *kept = r->sv.kept_load && r->disc_id[0] ? r->sv.kept_load(r->sv.ud, r->disc_id, &kn) : NULL;
		int rc = umd_mh_start(&r->H, r->start, kept, kn, now);
		free(r->kept_last);                     // (what the card holds: an equal store is skipped)
		r->kept_last = kept; r->kept_last_n = kept ? kn : 0;
		r->n_starts++;
		rtr(r, "HOST start %s%s: %s", r->start, r->H.continued ? " (continue)" : r->H.resume.have ? " (a resume point kept)" : "", rc ? "REFUSED, the core plays on its own" : "the engine runs");
		if (rc) { r->tr_on = 1; r->tr_have = 0; r->tr_state_was = -1; r->tr_wait_seek = 0; }   // (RS2: sampled, not resumed)
		owe_frame(r);
		return;
	}
	tr_go(r);
	ds_update(r);
	if (!r->started || !r->H.m || r->H.mode == UMD_MH_NONE) return;
	// the core idle: the OSD's Reset unloaded the image (no hook fires): the disc is gone
	if (r->have_rd && r->rd.state == 0) { quit(r, "the core went idle (Reset)", 1); return; }
	// THE TICK (umd_menu_run.h): the engine advances at most every UMD_MR_TICK_MS, by all the time owed
	r->tick_acc += ms;
	if (r->tick_acc >= UMD_MR_TICK_MS) { umd_mh_tick(&r->H, r->tick_acc); r->tick_acc = 0; }
	quit_p96(r);
}

void umd_mr_levels(umd_menu_run *r, umd_menu_levels *lv)
{
	umd_mh_levels(&r->H, lv);
	if (r->ds_up) {                             // RS4: the disc screen (16:9, the CRT's fit, no HUD)
		lv->ui = 1; lv->menu = 1;
		lv->grab |= 1u << UMD_JB_STOP;          // R7: its Stop forgets the place (the core ignores it there)
	}
	if (lv->ui && !r->ui_was) owe_frame(r);    // (the plane was hidden: draw the page whole)
	r->ui_was = lv->ui;
	// P6d: the panel's grab with the engine's; ui_sub in playback; over a disc menu a change of what it
	// shows redraws the engine's frame (it carries the panel)
	uint16_t pg;
	int show;
	umd_panel_levels(&r->P, &pg, &show);
	lv->grab |= pg;
	lv->ui_sub = (show == UMD_PS_UI_SUB);
	if (lv->ui_sub && !r->uis_was) r->pneed = 1;
	if (!lv->ui_sub && r->uis_was && r->ds_up) owe_frame(r);   // (the panel closed over the disc screen)
	r->uis_was = lv->ui_sub;
	uint32_t fv = (show == UMD_PS_FRAME) ? umd_panel_view(&r->P) : 0;
	if (fv != r->fview_was && lv->ui) owe_frame(r);
}

// RENDER, PIPELINED (umd_menu_run.h): a frame drawn while the flip is out, put when it is back.
// The CRT fit checked by BOTH wants: a fit that changed after a draw drops the drawn frame before its put
static void fit_check(umd_menu_run *r)
{
	float t[8];
	int fit = umd_mh_fit(&r->H, &t[0], &t[1], &t[2], &t[3], &t[4], &t[5], &t[6], &t[7]);
	if (fit != r->fit_was) { r->fit_was = fit; owe_frame(r); }      // (the CRT fit changed: redrawn)
}

int umd_mr_draw_want(umd_menu_run *r)
{
	if (r->ds_up && !engine_runs(r)) return 0;       // (RS4: the disc screen draws at its put)
	if (!r->H.m || r->H.mode == UMD_MH_NONE || !r->ui_was) return 0;
	fit_check(r);
	if (r->staged) return 0;                         // (one drawn frame awaits its put)
	return r->need_frame || menu_dirty(r->H.m);
}

int umd_mr_put_want(umd_menu_run *r, int sub_busy)
{
	if (r->ds_up && !engine_runs(r)) {               // RS4: the disc screen's page
		if (!r->ui_was || r->uis_was) return -1;  // (the panel open: its own page carries the disc screen)
		if (!umd_menu_flip_idle(r->L)) return -1;
		if (r->flipping >= 0) { r->front = r->flipping; r->flipping = -1; }
		if (sub_busy) return -1;
		if (!r->need_frame && !strcmp(r->ds_key, r->ds_want_key)) return -1;
		return r->front == 0 ? 1 : 0;
	}
	if (!r->H.m || r->H.mode == UMD_MH_NONE || !r->ui_was) return -1;
	fit_check(r);
	if (!umd_menu_flip_idle(r->L)) return -1;                 // a flip in flight: its buffer not yet ours
	if (r->flipping >= 0) { r->front = r->flipping; r->flipping = -1; }   // its echo came: shown
	if (sub_busy || !r->staged) return -1;
	return r->front == 0 ? 1 : 0;
}

// the disc screen's page into r->ds_frame (its key: the fit, then the Play line)
static void ds_draw(umd_menu_run *r)
{
	if (!r->ds_frame) r->ds_frame = (uint8_t *)malloc((size_t)UMD_DS_W * UMD_DS_H * 4);
	if (!r->ds_frame) return;
	const char *bar = strchr(r->ds_want_key, '|');
	umd_ds_img p = { r->ds_pic1, r->ds_pw, r->ds_ph }, i = { r->ds_icon0, r->ds_iw, r->ds_ih };
	umd_ds_draw(r->ds_frame, UMD_DS_W * 4, UMD_PANEL_PX_PLANE, r->ds_pic1 ? &p : NULL, r->ds_icon0 ? &i : NULL,
	            r->ds_title, bar ? bar + 1 : "", atoi(r->ds_want_key));
	snprintf(r->ds_key, sizeof(r->ds_key), "%s", r->ds_want_key);
	r->n_ds_frames++;
	rtr(r, "HOST disc screen drawn: fit %d, \"%s\"", atoi(r->ds_want_key), bar ? bar + 1 : "");
}

void umd_mr_draw_frame(umd_menu_run *r)
{
	if (!r->frame) r->frame = (uint8_t *)malloc((size_t)UMD_MR_W * UMD_MR_H * 4);
	if (!r->frame) return;
	r->fit_was = umd_mr_draw_inc(r, r->frame);
	const uint8_t *out = r->frame;
	// P6d: the panel over a disc menu, on a COPY (r->frame stays the incremental renderer's base)
	uint16_t pg;
	int show;
	umd_panel_levels(&r->P, &pg, &show);
	if (show == UMD_PS_FRAME) {
		if (!r->pframe) r->pframe = (uint8_t *)malloc((size_t)UMD_MR_W * UMD_MR_H * 4);
		if (r->pframe) {
			memcpy(r->pframe, r->frame, (size_t)UMD_MR_W * UMD_MR_H * 4);
			umd_panel_draw(&r->P, r->pframe, UMD_MR_W * 4, UMD_PANEL_PX_PLANE);
			out = r->pframe;
		}
	}
	r->fview_was = (show == UMD_PS_FRAME) ? umd_panel_view(&r->P) : 0;
	r->staged_out = out;
	r->staged = 1;
	r->need_frame = 0;
}

void umd_mr_put_frame(umd_menu_run *r, int buf)
{
	if (r->ds_up && !engine_runs(r)) {
		ds_draw(r);
		if (r->ds_frame && r->sv.plane_put) r->sv.plane_put(r->sv.ud, buf, r->ds_frame);
		r->n_frames++;
		return;
	}
	if (!r->staged) return;
	if (r->sv.plane_put) r->sv.plane_put(r->sv.ud, buf, r->staged_out);
	r->staged = 0;
	r->n_frames++;
}

// THE CANVAS (umd_menu_run.h, M4h): the menu's fit to a 4:3 CRT (analog.md S7) as a stretch -- the target
// rows (y0, h: the plane's whole width; Letterbox's band) and the view's rectangle in the canvas's pixels
// (the scene's 854 x 480 is the canvas's 480 x 272); the rest of the plane clear (Letterbox's bands: the
// window letterboxes the video the same)
typedef struct { int y0, h; float sx, sy, sw, sh; } mr_view;
static int mr_fit(umd_menu_run *r, mr_view *v)
{
	float tx, ty, tw, th, vx, vy, vw, vh;
	int fit = umd_mh_fit(&r->H, &tx, &ty, &tw, &th, &vx, &vy, &vw, &vh);
	if (!fit) { tx = 0; ty = 0; tw = UMD_MR_W; th = UMD_MR_H; vx = -427.0f; vy = 240.0f; vw = 854.0f; vh = 480.0f; }
	v->y0 = (int)ty; v->h = (int)th;
	v->sx = (vx + 427.0f) * (float)UMD_MR_CW / 854.0f; v->sy = (240.0f - vy) * (float)UMD_MR_CH / 480.0f;
	v->sw = vw * (float)UMD_MR_CW / 854.0f;           v->sh = vh * (float)UMD_MR_CH / 480.0f;
	return fit;
}
static void mr_bands(uint8_t *px, const mr_view *v)
{
	memset(px, 0, (size_t)v->y0 * UMD_MR_W * 4);
	memset(px + (size_t)(v->y0 + v->h) * UMD_MR_W * 4, 0, (size_t)(UMD_MR_H - v->y0 - v->h) * UMD_MR_W * 4);
}
// a canvas rectangle's pixels on the target: every target pixel whose two source columns / rows (floor(u),
// floor(u) + 1 at u = s + (X + 0.5) step - 0.5) reach into [a0, a1), and one more each side for the 16.16
// rounding (an extra pixel costs nothing: the stretch writes it as it was)
static void mr_span(float s, float sn, int dn, int a0, int a1, int *o0, int *o1)
{
	float k = (float)dn / sn;
	int lo = (int)floorf(((float)a0 - 1.0f - s + 0.5f) * k - 0.5f) - 1;
	int hi = (int)ceilf(((float)a1 - s + 0.5f) * k - 0.5f) + 2;
	*o0 = lo < 0 ? 0 : lo;
	*o1 = hi > dn ? dn : hi;
}

umd_mr_t0 umd_mr_clock(void)
{
	struct timespec w, c;
	clock_gettime(CLOCK_MONOTONIC, &w);
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &c);
	umd_mr_t0 t = { (uint64_t)w.tv_sec * 1000000u + (uint64_t)w.tv_nsec / 1000u, (uint64_t)c.tv_sec * 1000000u + (uint64_t)c.tv_nsec / 1000u };
	return t;
}
void umd_mr_acc_add(umd_mr_acc *a, umd_mr_t0 since)
{
	umd_mr_t0 t = umd_mr_clock();
	a->n++; a->wall_us += t.wall_us - since.wall_us; a->cpu_us += t.cpu_us - since.cpu_us;
}

// the frame into r->frame, INCREMENTALLY: the engine redraws what changed in the canvas
// (menu_render_view_inc), and only that is stretched -- the whole view at a new fit (the bands cleared)
int umd_mr_draw_inc(umd_menu_run *r, uint8_t *px)
{
	mr_view v;
	int fit = mr_fit(r, &v);
	if (!r->canvas) r->canvas = (uint8_t *)malloc((size_t)UMD_MR_CW * UMD_MR_CH * 4);
	if (!r->canvas) return fit;
	umd_mr_t0 t0 = umd_mr_clock();
	menu_render_inc(r->H.m, r->canvas, UMD_MR_CW, UMD_MR_CH, UMD_MR_CW * 4, MENU_PX_PLANE);
	umd_mr_acc_add(&r->p_draw, t0);
	t0 = umd_mr_clock();
	uint8_t *dst = px + (size_t)v.y0 * UMD_MR_W * 4;
	if (fit != r->inc_fit) {
		mr_bands(px, &v);
		menu_scale(r->canvas, UMD_MR_CW, UMD_MR_CH, UMD_MR_CW * 4, dst, UMD_MR_W, v.h, UMD_MR_W * 4, v.sx, v.sy, v.sw, v.sh, NULL);
	} else {
		int d[8][4];
		int nd = menu_inc_damage(r->H.m, d, 8);
		for (int k = 0; k < nd; k++) {
			int c[4];
			mr_span(v.sx, v.sw, UMD_MR_W, d[k][0], d[k][2], &c[0], &c[2]);
			mr_span(v.sy, v.sh, v.h, d[k][1], d[k][3], &c[1], &c[3]);
			menu_scale(r->canvas, UMD_MR_CW, UMD_MR_CH, UMD_MR_CW * 4, dst, UMD_MR_W, v.h, UMD_MR_W * 4, v.sx, v.sy, v.sw, v.sh, c);
		}
	}
	umd_mr_acc_add(&r->p_stretch, t0);
	r->inc_fit = fit;
	return fit;
}

// the frame into px WHOLE (a reference: the benches' checks), from a canvas of its own (a full render into
// another buffer leaves the incremental one's state alone)
int umd_mr_draw(umd_menu_run *r, uint8_t *px)
{
	mr_view v;
	int fit = mr_fit(r, &v);
	uint8_t *cv = (uint8_t *)malloc((size_t)UMD_MR_CW * UMD_MR_CH * 4);
	if (!cv) return fit;
	menu_render(r->H.m, cv, UMD_MR_CW, UMD_MR_CH, UMD_MR_CW * 4, MENU_PX_PLANE);
	mr_bands(px, &v);
	menu_scale(cv, UMD_MR_CW, UMD_MR_CH, UMD_MR_CW * 4, px + (size_t)v.y0 * UMD_MR_W * 4, UMD_MR_W, v.h, UMD_MR_W * 4,
	           v.sx, v.sy, v.sw, v.sh, NULL);
	free(cv);
	return fit;
}

void umd_mr_render_flip(umd_menu_run *r, int buf)
{
	umd_menu_flip f;
	memset(&f, 0, sizeof(f));
	f.buf = (uint8_t)buf; f.shown = 1; f.x = 0; f.y = 0; f.w = UMD_MR_W; f.h = UMD_MR_H;
	if (umd_menu_push_flip(r->L, &f) == 0) {
		r->flipping = buf;
		if (r->ds_up && !engine_runs(r)) r->need_frame = 0;
	} else owe_frame(r);                        // (refused: the put frame never shown -- drawn again)
}

// ---- the panel's own page, in playback (P6d, docs/panel.md §2): planes 2 / 3, the subtitle under it ----
// fj#71 Zoom (docs/zoom.md Z3): only raster lines 60 .. 419 reach the screen, so a subtitle is placed as the
// fabric places its own (sub_overlay.sv): y clamped to [60, 420 - h], one taller than the band at 60 with
// its first 360 rows -- moved, never cut
#define UMD_ZOOM_Y0 60
#define UMD_ZOOM_Y1 420
static void zoom_place(int y, int h, int *zy, int *zh)
{
	*zh = h < UMD_ZOOM_Y1 - UMD_ZOOM_Y0 ? h : UMD_ZOOM_Y1 - UMD_ZOOM_Y0;
	if (h > UMD_ZOOM_Y1 - UMD_ZOOM_Y0 || y < UMD_ZOOM_Y0) *zy = UMD_ZOOM_Y0;
	else if (y + h > UMD_ZOOM_Y1) *zy = UMD_ZOOM_Y1 - h;
	else *zy = y;
}

static int sub_now(const umd_menu_run *r) { return (r->have_rd && r->rd.sub_vis) ? r->rd.sub_seq : -1; }

int umd_mr_panel_want(umd_menu_run *r)
{
	uint16_t pg;
	int show;
	umd_panel_levels(&r->P, &pg, &show);
	if (show != UMD_PS_UI_SUB) return -1;
	if (!umd_menu_flip_idle(r->L)) return -1;               // a flip in flight: its buffer not yet ours
	if (r->pflipping >= 0) { r->pfront = r->pflipping; r->pflipping = -1; }
	if (!r->pneed && umd_panel_view(&r->P) == r->pview_was && sub_now(r) == r->psub_was &&
	    (r->have_rd && r->rd.zoom) == r->pz_was) return -1;
	return r->pfront == 2 ? 3 : 2;
}

void umd_mr_panel_frame(umd_menu_run *r, int buf)
{
	if (!r->pframe) r->pframe = (uint8_t *)malloc((size_t)UMD_MR_W * UMD_MR_H * 4);
	if (!r->pframe) return;
	int x0, y0, w, h;
	umd_panel_rect(&x0, &y0, &w, &h);
	int x1 = x0 + w, y1 = y0 + h;
	// the subtitle sub_sched shows: its plane and rectangle -- reported by the core, which decodes it
	// (A12 SD2); from a core that does not (A7: the host decoded it), the host's own record of it
	int sub = sub_now(r), sb = 0, sx = 0, sy = 0, sw = 0, sh = 0, have = 0;
	if (sub >= 0 && r->rd.sub_rect_v) {
		sb = r->rd.sub_buf; sx = r->rd.sub_x; sy = r->rd.sub_y; sw = r->rd.sub_w; sh = r->rd.sub_h;
		have = 1;
	} else
		have = sub >= 0 && r->sv.sub_unit && r->sv.sub_unit(r->sv.ud, (uint8_t)sub, &sb, &sx, &sy, &sw, &sh) == 0;
	if (have) {
		if (sx < 0) { sw += sx; sx = 0; }
		if (sy < 0) { sh += sy; sy = 0; }
		if (sx + sw > UMD_MR_W) sw = UMD_MR_W - sx;
		if (sy + sh > UMD_MR_H) sh = UMD_MR_H - sy;
		have = sw > 0 && sh > 0;
	}
	// fj#71: where it goes on the raster -- under Zoom inside the band, as the fabric places its own
	int zoom = r->have_rd && r->rd.zoom, dy = sy, dh = sh;
	if (have && zoom) zoom_place(sy, sh, &dy, &dh);
	if (have) {
		if (sx < x0) x0 = sx;
		if (dy < y0) y0 = dy;
		if (sx + sw > x1) x1 = sx + sw;
		if (dy + dh > y1) y1 = dy + dh;
	}
	// the union cleared, the subtitle copied in, the panel over it -- over the disc screen (RS4), a copy of
	// its page, the whole raster
	if (r->ds_up && r->ds_frame && r->ds_key[0]) {
		memcpy(r->pframe, r->ds_frame, (size_t)UMD_MR_W * UMD_MR_H * 4);
		x0 = 0; y0 = 0; x1 = UMD_MR_W; y1 = UMD_MR_H;
	} else {
		for (int y = y0; y < y1; y++) memset(r->pframe + ((size_t)y * UMD_MR_W + (size_t)x0) * 4, 0, (size_t)(x1 - x0) * 4);
		if (have && r->sv.plane_get) {
			r->sv.plane_get(r->sv.ud, sb, sx, sy, sw, sh, r->pframe);
			if (dy != sy || dh != sh) {                // fj#71: its rows moved to dy, the rows it left cleared
				size_t row = (size_t)UMD_MR_W * 4, off = (size_t)sx * 4, n = (size_t)sw * 4;
				if (dy < sy) for (int k = 0; k < dh; k++)
					memmove(r->pframe + (size_t)(dy + k) * row + off, r->pframe + (size_t)(sy + k) * row + off, n);
				else for (int k = dh - 1; k >= 0; k--)
					memmove(r->pframe + (size_t)(dy + k) * row + off, r->pframe + (size_t)(sy + k) * row + off, n);
				for (int y = sy; y < sy + sh; y++)
					if (y < dy || y >= dy + dh) memset(r->pframe + (size_t)y * row + off, 0, n);
			}
		}
	}
	umd_panel_draw(&r->P, r->pframe, UMD_MR_W * 4, UMD_PANEL_PX_PLANE);
	if (r->sv.plane_put_rect) r->sv.plane_put_rect(r->sv.ud, buf, r->pframe, x0, y0, x1 - x0, y1 - y0);
	r->prx = x0; r->pry = y0; r->prw = x1 - x0; r->prh = y1 - y0;
	r->pv_drawn = umd_panel_view(&r->P);
	r->ps_drawn = sub;
	r->pz_drawn = zoom;
}

void umd_mr_panel_flip(umd_menu_run *r, int buf)
{
	umd_menu_flip f;
	memset(&f, 0, sizeof(f));
	f.buf = (uint8_t)buf; f.shown = 1;
	f.x = (uint16_t)r->prx; f.y = (uint16_t)r->pry; f.w = (uint16_t)r->prw; f.h = (uint16_t)r->prh;
	if (umd_menu_push_flip(r->L, &f) == 0) {
		r->pflipping = buf;
		r->pview_was = r->pv_drawn;
		r->psub_was = r->ps_drawn;
		r->pz_was = r->pz_drawn;
		r->pneed = 0;
		r->n_panel_pages++;
	}
}

void umd_mr_set_trace(umd_menu_run *r, void (*trace)(void *ud, const char *line))
{
	r->sv.trace = trace;
	r->hs.trace = trace ? s_trace : NULL;
	r->H.sv.trace = r->hs.trace;               // (the host's copy, until the next mount re-inits it)
}

void umd_mr_shutdown(umd_menu_run *r)
{
	quit(r, "a core change", 1);
}
