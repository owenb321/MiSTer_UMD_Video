// umd_menu_host.c -- see umd_menu_host.h.
#include "umd_menu_host.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void tr(umd_menu_host *h, const char *fmt, ...)
{
	if (!h->sv.trace) return;
	char b[300];
	int n = snprintf(b, sizeof(b), "%8u ", h->m ? menu_now(h->m) : 0u);  // (the engine's clock, as its own lines)
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b + n, sizeof(b) - (size_t)n, fmt, ap);
	va_end(ap);
	h->sv.trace(h->sv.ud, b);
}

static void push_cmd_ch(umd_menu_host *h, uint8_t code, uint8_t arg, uint16_t pl, uint32_t item, uint64_t pts, uint16_t chapter)
{
	umd_menu_pcmd c;
	memset(&c, 0, sizeof(c));
	c.code = code; c.arg = arg; c.pl = pl; c.item = item; c.pts = pts; c.chapter = chapter;
	if (h->detached) { tr(h, "HOST command %u dropped: the core no longer holds this disc (its onExit)", code); return; }
	if (umd_menu_push_cmd(h->L, &c)) tr(h, "HOST command %u dropped: the queue is full", code);
}
static void push_cmd(umd_menu_host *h, uint8_t code, uint8_t arg, uint16_t pl, uint32_t item, uint64_t pts)
{
	push_cmd_ch(h, code, arg, pl, item, pts, 0);
}

// a place's chapter: the number of chapters starting at or before (item, pts); 0 before the first
static uint16_t rank_at(const umd_menu_host *h, uint16_t pl, uint32_t item, uint64_t pts)
{
	uint16_t r = 0;
	for (uint32_t c = 1; c <= h->pl->e[pl].nchapters && c <= 0xFFFF; c++) {
		uint32_t ci; uint64_t cp;
		if (umd_pl_chapter(h->pl, pl, c, &ci, &cp)) break;
		if (ci < item || (ci == item && cp <= pts)) r = (uint16_t)c; else break;
	}
	return r;
}

// the content play() in force becomes the resume point when something interrupts it
static void keep_resume(umd_menu_host *h)
{
	if (!h->playing.have) return;
	// (an ENDED playlist cleared `playing` at its PL_END; nothing leaves the core stopped under a
	// content play: Circle, the transport's Stop, is grabbed in CONTENT, keyboard included)
	// THE OSD'S RESET (fj#88, the 2026-10-08 Resets): its quit follows the first idle read (state 0), so the
	// place is the last read in play / pause -- else the onExit saved "in the film" beside no point
	const umd_menu_rd *rd = (h->have_rd && h->rd.state == 0 && h->have_play) ? &h->rd_play : &h->rd;
	if (h->have_rd && (rd->state == 1 || rd->state == 2) && rd->playlist == h->playing.pl && rd->shown) {
		h->resume = h->playing;
		h->resume.item = rd->key_item;
		h->resume.pts = rd->pts;
		h->resume.have = 1;
		h->resume_used = 0;
		tr(h, "HOST resume point: playlist %u item %u pts %llu", h->resume.pl + 1, h->resume.item, (unsigned long long)h->resume.pts);
		if (h->sv.kept_changed) h->sv.kept_changed(h->sv.ud);
	}
	h->playing.have = 0;
}

// play()'s streams: audio 0xBD00 + n, subtitles 0xBD80 + n with their flag; -1 unchanged
static void push_streams(umd_menu_host *h, int audio, int sub, int sflag)
{
	// (sent whatever plays now: the HOST_RD in hand may predate the PLAYLIST's landing; player_ctl
	// refuses the track already playing with a BAD the logic only counts)
	if (audio >= 0xBD00 && audio <= 0xBD0F)
		push_cmd(h, UMD_PC_AUDIO_SET, (uint8_t)(audio - 0xBD00), 0, 0, 0);
	if (sub >= 0xBD80 && sub <= 0xBD9F)
		push_cmd(h, UMD_PC_SUB_SET, 0, 0, (uint32_t)((sflag ? 0x20 : 0) | (sub - 0xBD80)), 0);
}

static int arg_i(const menu_play *p, int k, int dflt) { return p->n > k ? (int)p->a[k] : dflt; }

// NAMED MARKS: PLAYLIST.UMD's marks other than chapters (type 16, named: "initMenu", "Endmark2", ...)
// reach the script as movieplayer.onMark when the shown picture passes them -- the core posts no mark
// event, so the host watches HOST_RD's place (the shown picture's item and PTS) on the playlist it
// asked for. A play arms them from its start place (a mark AT the start fires); they fire at the
// landing's next reads, in (item, PTS) order. MODEL: no capture shows a mark's timing (the PSP's is
// within a frame or so; this one within a HOST_RD read, 10-50 ms). Now That's What I Call Music opens
// every menu page at its clip's "initMenu"; The Rock and Lost leave trailers at their Endmarks
static void marks_from(umd_menu_host *h, uint32_t item, uint64_t pts)
{
	h->mk_on = 0; h->mk_fresh = 1; h->mk_seek = 0;
	h->mk_item = item; h->mk_pts = pts;
}

static int place_lt(uint32_t ai, uint64_t ap, uint32_t bi, uint64_t bp) { return ai < bi || (ai == bi && ap < bp); }

static void marks_pass(umd_menu_host *h)
{
	const umd_menu_rd *rd = &h->rd;
	if (!h->mk_on || h->playing_pl < 0 || rd->playlist != (uint32_t)h->playing_pl) return;
	if (rd->seeking) { if (!h->mk_fresh) h->mk_seek = 1; return; }
	if (!(rd->state == 1 || rd->state == 2) || !rd->shown) return;
	uint32_t ci = rd->key_item;
	uint64_t cp = rd->pts;
	if (h->mk_seek || place_lt(ci, cp, h->mk_item, h->mk_pts)) {     // jumped (or back): nothing passed
		h->mk_seek = 0; h->mk_fresh = 0; h->mk_item = ci; h->mk_pts = cp;
		return;
	}
	const umd_pl_entry *e = &h->pl->e[h->playing_pl];
	// the marks in (last, current] -- [start, current] the first time -- earliest first
	int incl = h->mk_fresh;
	uint32_t li = h->mk_item;
	uint64_t lp = h->mk_pts;
	h->mk_fresh = 0; h->mk_item = ci; h->mk_pts = cp;
	for (;;) {
		int best = -1;
		for (uint32_t k = 0; k < e->nmarks; k++) {
			const umd_pl_mark *mk = &e->marks[k];
			if (mk->type == 5 || !mk->name[0]) continue;             // (chapters are onChapter's)
			int after = incl ? !place_lt(mk->item, mk->pts, li, lp) : place_lt(li, lp, mk->item, mk->pts);
			if (!after || place_lt(ci, cp, mk->item, mk->pts)) continue;
			if (best < 0 || place_lt(mk->item, mk->pts, e->marks[best].item, e->marks[best].pts)) best = (int)k;
		}
		if (best < 0 || !h->m || h->mode == UMD_MH_NONE) break;
		const umd_pl_mark *mk = &e->marks[best];
		tr(h, "HOST mark %s (playlist %d item %u pts %llu)", mk->name, h->playing_pl + 1, mk->item, (unsigned long long)mk->pts);
		incl = 0; li = mk->item; lp = mk->pts;
		menu_mark(h->m, mk->name);
		// (a play the handler started re-armed the marks for ITS playlist: this one's are done)
		if (!h->mk_on || h->mk_fresh) break;
	}
}

// ---- the engine's host interface ----------------------------------------------------------------
// A USED POINT IS USED UP AT THE LANDING, NOT AT THE ASK (fj#88, the rig 2026-10-10): resume() once
// dropped the point at once and rewrote the file; a quit before the resumed film's first picture (or
// an onExit that stops it, fj#89) then kept no new one, while the script's onExit saved "in the film" --
// The Animatrix's onContinuePlay calls resume() unchecked, and the disc loaded to black. Kept (written
// R 1) until the resumed play is seen, the R line and the script's data cannot disagree. Dropped in memory
// only: the card keeps the last save (R6) -- a store here would write R 0 beside the last onExit's "in the
// film" until the next quit, the same disagreement after a power cut; the next store (a quit, setUserData)
// writes what holds then
static void drop_used(umd_menu_host *h, const char *why)
{
	h->resume_used = 0;
	h->resume.have = 0;
	tr(h, "HOST resume point used up: %s", why);
}

static void e_play(void *ud, const menu_play *p)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	int num = arg_i(p, 2, 0), ch = arg_i(p, 3, 1), menu_mode = arg_i(p, 1, 0) != 0;
	if (num < 1 || (uint32_t)num > h->pl->n) {
		h->n_refused_play++;
		tr(h, "HOST play refused: playlist %d is not on the disc (%u)", num, h->pl->n);
		return;
	}
	uint16_t idx = (uint16_t)(num - 1);
	uint32_t item = 0;
	uint64_t pts = h->pl->e[idx].nitems ? h->pl->e[idx].items[0].in : 0;
	if (ch >= 1 && umd_pl_chapter(h->pl, idx, (uint32_t)ch, &item, &pts)) {
		tr(h, "HOST play: playlist %d has no chapter %d: from its start", num, ch);
		pts = h->pl->e[idx].nitems ? h->pl->e[idx].items[0].in : 0, item = 0;
	}
	// THE RESUME POINT is a content play interrupted by a MENU's play (menuMode 1: Akira's film, Square,
	// its menu clip; Cross resumes the film) or by the quit. Replaced by another content play it is
	// gone, as by the script's stop() (Die Hard): Lost's trailers end at their Endmarks with the next
	// trailer's play, and its PlayEpisodeContinue's stop(); resume() then resumed a trailer over the
	// episode (docs/p9.md M4). MODEL from the discs' scripts; no capture tells a stop from a play
	if (menu_mode) keep_resume(h);
	else h->playing.have = 0;
	// (fj#88: a content play before the resumed one landed replaces the point, as any content play; a
	// menu's play interrupts it before a picture was seen -- the point stays, usable again)
	if (h->resume_used && !menu_mode) drop_used(h, "a content play() before its landing");
	else if (h->resume_used) { h->resume_used = 0; tr(h, "HOST resume point kept: a menu's play() before its landing"); }
	marks_from(h, item, pts);
	h->stopped = 0;
	uint16_t rank = rank_at(h, idx, item, pts);
	push_cmd_ch(h, UMD_PC_PLAYL, 0, idx, item, pts, rank);
	push_streams(h, arg_i(p, 5, -1), arg_i(p, 7, -1), arg_i(p, 8, 0));
	// PAUSEMODE 1 STARTS PAUSED ON THE REQUESTED CHAPTER'S FIRST PICTURE (fj#65, the maintainer's PSP,
	// 2026-10-10): The Animatrix keeps one still per one-second chapter of playlist 23 and asks each page's
	// own chapter -- the PSP holds it (no flashing through the next chapters' stills); Goldmember's Great
	// Titles shows its Background loop as a still, not playing. Held, the playlist reaches no later
	// chapter and no end. The PAUSE follows the PLAYLIST on the command channel, which the logic holds
	// until the landing: the core shows the first picture, then 1-3 more frames (the landing seen at a
	// HOST_RD, the PAUSE's take) before the freeze -- inside the first chapter of every library use
	// (15 discs, every one a menu background: menuMode 1)
	if (arg_i(p, 0, 0) == 1) {
		h->n_held++;
		tr(h, "HOST pauseMode 1: playlist %d held at its first picture", num);
		push_cmd(h, UMD_PC_PAUSE, 0, 0, 0, 0);
	}
	h->content = !menu_mode;
	h->cur_menu_mode = menu_mode;
	h->pl_pending = 1;
	h->asked_chapter = rank ? rank : 1;
	h->play_at = h->m ? menu_now(h->m) : 0;
	// AUDIO ON (argument 6; p9.md S1): 0 plays the playlist silent. Family Guy's episode page loops
	// playlist 8 with it 0 -- an authored loop the PSP never lets be heard (its fades in and out were
	// the "engine idling" on the rig: the maintainer, 2026-10-03); every other play of the disc says 1
	h->mute = arg_i(p, 6, 1) == 0;
	h->playing_pl = idx;
	memset(&h->playing, 0, sizeof(h->playing));
	h->playing.have = !menu_mode;
	h->playing.pl = idx;
	h->playing.video = arg_i(p, 4, -1); h->playing.audio = arg_i(p, 5, -1); h->playing.aflag = arg_i(p, 6, -1);
	h->playing.sub = arg_i(p, 7, -1); h->playing.sflag = arg_i(p, 8, -1);
}

static void e_stop(void *ud)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	h->playing.have = 0;
	if (h->resume_used) drop_used(h, "the script's stop() before its landing");   // (M4 rule 2)
	h->mk_on = 0;
	h->stopped = 1;
	push_cmd(h, UMD_PC_STOP, 0, 0, 0, 0);
	h->content = 0;
}

static int e_resume(void *ud)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (!h->resume.have || h->resume_used) return -1;
	umd_mh_resume r = h->resume;
	marks_from(h, r.item, r.pts);
	h->stopped = 0;
	uint16_t rank = rank_at(h, r.pl, r.item, r.pts);
	push_cmd_ch(h, UMD_PC_PLAYL, 0, r.pl, r.item, r.pts, rank);
	push_streams(h, r.audio, r.sub, r.sflag);
	h->pl_pending = 1;
	h->asked_chapter = rank ? rank : 1;
	h->cur_menu_mode = 0;
	h->playing = r;
	h->playing_pl = r.pl;
	h->content = 1;
	h->mute = r.aflag == 0;
	h->resume_used = 1;                     // (fj#88: dropped at the landing, umd_mh_events)
	tr(h, "HOST resume point in use: playlist %u item %u pts %llu", r.pl + 1, r.item, (unsigned long long)r.pts);
	return 0;
}

static void e_status(void *ud, menu_status *s)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	memset(s, 0, sizeof(*s));
	if (!h->have_rd) return;
	// (stopped from the script's stop() on, before the core's STOP lands: Hellboy polls 250 ms after)
	s->playing = (h->rd.state == 1 || h->rd.state == 2) && !h->stopped;
	s->paused = h->rd.state == 2;
	s->menu_mode = !h->content;
	s->playlist = h->rd.playlist + 1;                          // the script's number
	// the chapter last posted to the script (the landing's, then the core's events): the core's word
	// reads 0 through a seek and just after its landing
	s->chapter = h->chapter ? h->chapter : h->rd.chapter;
	// A play() NOT YET LANDED IS THE ONE REPORTED (fj#65, Goldmember, the maintainer's PSP 2026-10-10): its
	// main menu's onChangeResource asks play(1, 1, 3, 1) (the Warning, held) and in the same instant
	// init_mm() reads getPlayerStatus().playListNumber, replacing it with the Background loop when that
	// is not 4. The PSP shows the loop moving: its status already names 3. The core's word still read
	// 4 (the Background held under Great Titles), so the Warning clip played under the menu. The
	// same skew as M4f's stale CHAPTER (fj#76), on the status instead of an event
	if (h->pl_pending && h->playing_pl >= 0) {
		s->playlist = h->playing_pl + 1;
		s->chapter = h->asked_chapter;
	}
	s->video = 0xE000;
	s->audio = 0xBD00 + h->rd.audio_track;
	s->audio_flag = 1;
	s->subtitle = 0xBD80 + h->rd.sub_track;
	s->subtitle_flag = h->rd.sub_on;
}

// THE SYSTEM STOPS A MENU'S PLAYBACK AT A RESOURCE CHANGE (fj#66, the maintainer's PSP 2026-10-10: A Few
// Good Men's Play Movie shows BLACK between its warning cards). The cards fade over a page with no
// backdrop (EN000001's pageMenuWarnings, a template on 10 library discs), and nothing in the script stops
// the menu loop (menuMode 1) before its changeResource -- the library's scripts stop a CONTENT play
// themselves before one (p9.md M4 rule 5) and never a menu's. A play() asked in the same instant as the
// change is the new resource's own and is kept (traced)
static void e_change_resource(void *ud, const char *name)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (!h->cur_menu_mode || h->stopped || h->playing_pl < 0) return;
	if (h->m && menu_now(h->m) == h->play_at) {
		tr(h, "HOST changeResource(%s): playlist %d asked in the same instant, kept", name, h->playing_pl + 1);
		return;
	}
	h->n_res_stop++;
	tr(h, "HOST changeResource(%s): the menu's playlist %d stopped", name, h->playing_pl + 1);
	e_stop(h);
}

static int e_resume_info(void *ud, menu_status *s)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (!h->resume.have || h->resume_used) return -1;
	memset(s, 0, sizeof(*s));
	s->playlist = h->resume.pl + 1;
	s->video = h->resume.video; s->audio = h->resume.audio; s->audio_flag = h->resume.aflag;
	s->subtitle = h->resume.sub; s->subtitle_flag = h->resume.sflag;
	return 0;
}

static void e_change_resume(void *ud, const menu_status *s)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (!h->resume.have || h->resume_used) return;
	h->resume.video = s->video; h->resume.audio = s->audio; h->resume.aflag = s->audio_flag;
	h->resume.sub = s->subtitle; h->resume.sflag = s->subtitle_flag;
	if (h->sv.kept_changed) h->sv.kept_changed(h->sv.ud);
}

static int e_load(void *ud, const char *name, const uint8_t **buf, size_t *len)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	return h->sv.load_rco ? h->sv.load_rco(h->sv.ud, name, buf, len) : -1;
}
static int e_decode(void *ud, int f, const uint8_t *d, size_t n, int *w, int *hh, uint8_t **rgba)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	return h->sv.decode_image ? h->sv.decode_image(h->sv.ud, f, d, n, w, hh, rgba) : -1;
}
static void e_trace(void *ud, const char *line)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (h->sv.trace) h->sv.trace(h->sv.ud, line);
}
static void e_sound(void *ud, uint32_t key, const int16_t *pcm, uint32_t frames, int nch)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (h->sv.sound) h->sv.sound(h->sv.ud, key, pcm, frames, nch);
}
static void e_kept(void *ud)
{
	umd_menu_host *h = (umd_menu_host *)ud;
	if (h->sv.kept_changed) h->sv.kept_changed(h->sv.ud);
}

// ---- the host -----------------------------------------------------------------------------------
void umd_mh_init(umd_menu_host *h, const umd_mh_services *sv, umd_menu_state *L, const umd_playlists *pl)
{
	memset(h, 0, sizeof(*h));
	h->sv = *sv;
	h->L = L;
	h->pl = pl;
	h->mode = UMD_MH_NONE;
	h->playing_pl = -1;
}

static int is_start(const char *n)          // "XX100000.RCO", any two capitals
{
	return strlen(n) == 12 && n[0] >= 'A' && n[0] <= 'Z' && n[1] >= 'A' && n[1] <= 'Z' && !strcmp(n + 2, "100000.RCO");
}

int umd_mh_pick_start(const char *const *names, int n, const char *lang, char out[16])
{
	const char *best = NULL;
	for (int pass = 0; pass < 3 && !best; pass++)
		for (int i = 0; i < n; i++) {
			if (!is_start(names[i])) continue;
			if (pass == 0 && !(lang && strlen(lang) == 2 && !strncmp(names[i], lang, 2))) continue;
			if (pass == 1 && strncmp(names[i], "EN", 2)) continue;
			if (pass == 2 && best && strcmp(names[i], best) >= 0) continue;
			best = names[i];
			if (pass < 2) break;
		}
	if (!best) return -1;
	memcpy(out, best, 8);
	out[8] = 0;
	return 0;
}

const char *umd_mh_lang_code(unsigned option)
{
	static const char *const codes[] = { "EN", "FR", "ES", "DE", "IT", "NL", "JA" };   // (CONF_STR's order)
	return option < sizeof(codes) / sizeof(codes[0]) ? codes[option] : NULL;
}

int umd_mh_ready(const umd_menu_rd *rd)
{
	return rd->nwords_ok && (rd->state == 1 || rd->state == 2) && rd->shown && !rd->seeking;
}

void umd_mh_free(umd_menu_host *h)
{
	if (h->m) menu_free(h->m);
	h->m = NULL;
	h->mode = UMD_MH_NONE;
}

// the kept text: "R <have> <pl> <item> <pts> <video> <audio> <aflag> <sub> <sflag>\n" then menu_save's
static int parse_kept(umd_menu_host *h, const char *kept, size_t len, const char **ud_text, size_t *ud_len)
{
	*ud_text = NULL; *ud_len = 0;
	if (!kept || len < 2 || kept[0] != 'R') return -1;
	const char *nl = memchr(kept, '\n', len);
	if (!nl) return -1;
	char line[160];
	size_t ll = (size_t)(nl - kept) < sizeof(line) - 1 ? (size_t)(nl - kept) : sizeof(line) - 1;
	memcpy(line, kept, ll); line[ll] = 0;
	unsigned have, pl, item; unsigned long long pts; int v, a, af, s, sf;
	if (sscanf(line, "R %u %u %u %llu %d %d %d %d %d", &have, &pl, &item, &pts, &v, &a, &af, &s, &sf) != 9) return -1;
	if (have && pl < h->pl->n) {
		h->resume.have = 1; h->resume.pl = (uint16_t)pl; h->resume.item = item; h->resume.pts = pts;
		h->resume.video = v; h->resume.audio = a; h->resume.aflag = af; h->resume.sub = s; h->resume.sflag = sf;
	}
	*ud_text = nl + 1;
	*ud_len = len - (size_t)(nl + 1 - kept);
	return 0;
}

int umd_mh_start(umd_menu_host *h, const char *name, const char *kept, size_t kept_len, uint32_t now_ms)
{
	umd_mh_free(h);
	const uint8_t *b; size_t n;
	if (!h->sv.load_rco || h->sv.load_rco(h->sv.ud, name, &b, &n)) {
		tr(h, "HOST no RESOURCE/%s.RCO: the disc plays on its own", name);
		return -1;
	}
	h->content = 0; h->mute = 0; h->chapter = 0; h->playing_pl = -1; h->quit_req = 0; h->stopped = 0; h->detached = 0;
	h->pl_pending = 0; h->cur_menu_mode = 0; h->resume_used = 0;
	memset(&h->playing, 0, sizeof(h->playing));
	memset(&h->resume, 0, sizeof(h->resume));
	menu_host mh;
	memset(&mh, 0, sizeof(mh));
	mh.ud = h; mh.play = e_play; mh.stop = e_stop; mh.resume = e_resume; mh.resume_info = e_resume_info;
	mh.change_resume = e_change_resume; mh.status = e_status; mh.load_rco = e_load; mh.trace = e_trace;
	mh.decode_image = e_decode; mh.kept_changed = e_kept; mh.sound = e_sound; mh.change_resource = e_change_resource;
	h->m = menu_new(&mh);
	if (!h->m) return -1;
	menu_set_clock(h->m, now_ms);
	const char *ud_text = NULL;
	size_t ud_len = 0;
	int cont = parse_kept(h, kept, kept_len, &ud_text, &ud_len) == 0 && ud_len > 0 && menu_load(h->m, ud_text, ud_len) == 0;
	h->continued = cont;
	// the stop screen black behind `menu` until the script's first play lands (not the feature the
	// core auto-plays at a mount)
	push_cmd(h, UMD_PC_STOP, 0, 0, 0, 0);
	h->mode = UMD_MH_MENU;
	h->content = 0;
	int rc = cont ? menu_continue(h->m, name) : menu_start(h->m, name);
	if (rc || menu_error(h->m)[0]) {
		tr(h, "HOST the engine refused the disc (%s): it plays on its own", menu_error(h->m));
		push_cmd(h, UMD_PC_PLAY, 0, 0, 0, 0);               // undo the STOP: stock playback
		h->mode = UMD_MH_NONE;
		return -1;
	}
	return 0;
}

void umd_mh_rd(umd_menu_host *h, const umd_menu_rd *rd)
{
	if (!rd->nwords_ok) return;
	h->rd = *rd;
	h->have_rd = 1;
	if (rd->state == 1 || rd->state == 2) { h->rd_play = *rd; h->have_play = 1; }
	else if (rd->state != 0) h->have_play = 0;      // (a stop: no place; the idle read keeps the last)
	marks_pass(h);
}

void umd_mh_events(umd_menu_host *h, const umd_menu_event *ev, int n)
{
	// the press mask's bits to the engine, in this order
	static const struct { int bit, key; } order[] = {
		{ UMD_JB_UP, MENU_KEY_UP }, { UMD_JB_DOWN, MENU_KEY_DOWN }, { UMD_JB_LEFT, MENU_KEY_LEFT },
		{ UMD_JB_RIGHT, MENU_KEY_RIGHT }, { UMD_JB_PAUSE, MENU_KEY_CROSS }, { UMD_JB_STOP, MENU_KEY_CIRCLE },
		{ UMD_JB_DISPLAY, MENU_KEY_TRIANGLE }, { UMD_JB_UMDMENU, MENU_KEY_SQUARE }, { UMD_JB_PLAYPAUSE, MENU_KEY_START },
		{ UMD_JB_AUDIO, MENU_KEY_SELECT }, { UMD_JB_PREV, MENU_KEY_L }, { UMD_JB_NEXT, MENU_KEY_R } };
	for (int i = 0; i < n && h->m && h->mode != UMD_MH_NONE; i++) {
		switch (ev[i].kind) {
		case UMD_ME_KEY:
			for (size_t k = 0; k < sizeof(order) / sizeof(order[0]); k++) {
				if (!(ev[i].data >> order[k].bit & 1)) continue;
				int took = menu_key(h->m, order[k].key);
				// Start not the script's: play / pause, as the PSP (the maintainer's test, 2026-10-02)
				if (!took && order[k].key == MENU_KEY_START) push_cmd(h, UMD_PC_PLAYPAUSE, 0, 0, 0, 0);
				// THE SYSTEM'S TRANSPORT UNDER A PAGE THAT DRAWS NOTHING (fj#72, the maintainer's rig session
				// 2026-10-07): The Office's scene play opens pageWaitDummy, fades it to alpha 0 and never
				// closes it, so the page grabs every button through the whole episode and the engine drops
				// L / R, FF / REW as unhandled -- chapter skip and seeking were dead. With content playing
				// under a page that is not presented (`pres` 0: menu_shows() nothing), a transport key the
				// script did not take is the system's, as on a PSP: injected as its own press (P6d's press
				// path, ORed in after the grab: the core's transport takes it). Only the keys that move the
				// title -- L / R (chapters), Left / Right (REW / FF) -- and Select (the audio track): Cross
				// (pause) is NOT forwarded, the PSP unmeasured (the walk presses it on such a page through
				// The Office's opening clips, which it would pause; Start still plays / pauses). A key
				// dropped inside a Lock was taken (Family Guy's pageDummy holds the keys 3 s on purpose);
				// Circle, Start, Square, Triangle keep their own rules; a page that draws (Austin Powers 2's
				// scene list over its film) keeps every key the script's
				if (!took && h->content && !h->pres && h->have_rd && (h->rd.state == 1 || h->rd.state == 2) &&
				    (order[k].key == MENU_KEY_LEFT || order[k].key == MENU_KEY_RIGHT || order[k].key == MENU_KEY_L ||
				     order[k].key == MENU_KEY_R || order[k].key == MENU_KEY_SELECT)) {
					tr(h, "HOST button %d not the script's under a page that draws nothing: the transport's", order[k].bit);
					if (umd_menu_push_press(h->L, (uint16_t)(1u << order[k].bit))) tr(h, "HOST press dropped: the queue is full");
				}
				if (!took && order[k].key == MENU_KEY_CIRCLE && !h->quit_req) {
					h->quit_req = 1;                // P9-6: the system's stop, the PSP's way to the XMB
					tr(h, "HOST Circle not the script's: quit the disc (P9-6)");
					if (h->sv.quit) h->sv.quit(h->sv.ud);
				}
			}
			break;
		case UMD_ME_CHAPTER:
			// A CHAPTER READ BEFORE THE LATEST play() WAS QUEUED is the old play's (fj#76, the rig, 2026-10-08):
			// the poll thread passed it with nothing ahead, the worker delivered it after the script's play().
			// Aliens resumed from a kept place: the mount's own feature play ranked chapter 1 while the start
			// loaded the RCO; onContinuePlay asked the menu loop (playlist 2); the stale onChapter reported
			// playlist 1, whose handler (on_chapter_movie) set g_app_state = MOVIE_PLAY -- and the loop's
			// own chapter 3 then found no MAINMENU_TRANS_IN and never opened the menu (EN100000's script).
			// (h->L's play_gen: the worker alone writes it, through umd_menu_push_cmd)
			if (ev[i].gen != h->L->play_gen) {
				h->n_stale_chapter++;
				tr(h, "HOST chapter %u dropped: read before the latest play() was asked", ev[i].data);
				break;
			}
			h->chapter = (uint16_t)ev[i].data;
			menu_chapter(h->m, (int)ev[i].data);
			break;
		case UMD_ME_PL_END:
			// (the playlist that ended: one the script has since replaced is not reported)
			if ((int)ev[i].data != h->playing_pl) { tr(h, "HOST end of playlist %u dropped: %d was asked since", ev[i].data + 1, h->playing_pl + 1); break; }
			h->playing.have = 0;                    // an ended playlist leaves no resume point
			h->content = 0;
			h->mk_on = 0;
			menu_playlist_end(h->m, (int)ev[i].data + 1);
			break;
		case UMD_ME_LANDED:
			if ((int)ev[i].data == h->playing_pl) h->mk_on = 1;
			// (fj#65: the status reports the core's word again -- only the latest play()'s landing: one read
			// before it was queued is an older play of the same playlist, Family Guy's loop)
			if ((int)ev[i].data == h->playing_pl && ev[i].gen == h->L->play_gen) {
				h->pl_pending = 0;
				if (h->resume_used) drop_used(h, "the resumed play landed");
			}
			break;
		case UMD_ME_GAVE_UP:
			tr(h, "HOST playlist %u never landed (the core stayed busy): given up", ev[i].data + 1);
			if (ev[i].gen == h->L->play_gen) {
				h->pl_pending = 0;
				if (h->resume_used) { h->resume_used = 0; tr(h, "HOST resume point kept: its play never landed"); }
			}
			break;
		default:
			break;
		}
	}
}

void umd_mh_tick(umd_menu_host *h, uint32_t ms)
{
	if (h->m && h->mode != UMD_MH_NONE) menu_tick(h->m, ms);
	if (h->m && h->mode != UMD_MH_NONE && menu_error(h->m)[0]) {
		tr(h, "HOST the engine stopped (%s): the disc plays on its own", menu_error(h->m));
		h->mode = UMD_MH_NONE;
	}
}

// a menu's fit to the raster (docs/analog.md S7): the target rectangle (tx, ty, tw, th) on the 720 x 480
// raster and the scene's view (left vx, top vy, vw x vh, centre origin, y up) drawn into it. Fit: the
// whole scene on the whole raster; Letterbox: the whole scene into 720 x 360 at line 60; Crop: the
// scene's centre 640 x 480 on the whole raster. Only while the menu is presented (`pres`)
int umd_mh_fit(const umd_menu_host *h, float *tx, float *ty, float *tw, float *th, float *vx, float *vy, float *vw, float *vh)
{
	int fit = (h->pres && h->have_rd) ? h->rd.menu_aa : 0;
	if (fit > 2) fit = 0;
	*tx = 0; *ty = fit == 1 ? 60.0f : 0.0f; *tw = 720; *th = fit == 1 ? 360.0f : 480.0f;
	*vx = fit == 2 ? -320.0f : -427.0f; *vy = 240; *vw = fit == 2 ? 640.0f : 854.0f; *vh = 480;
	return fit;
}

// the movie window: the scene's (centre, size) through the fit onto the raster, a 720 x 480 source
static void window(umd_menu_host *h, umd_menu_win *w)
{
	memset(w, 0, sizeof(*w));
	float cx, cy, ww, hh, tx, ty, tw, th, vx, vy, vw, vh;
	menu_video_window(h->m, &cx, &cy, &ww, &hh);
	if (ww <= 0 || hh <= 0) return;
	int fit = umd_mh_fit(h, &tx, &ty, &tw, &th, &vx, &vy, &vw, &vh);
	// THE ASPECT: under a menu the core presents 16:9 (a menu is drawn in the PSP's 854 x 480 space,
	// every disc), so a 4:3 picture is fitted into the movie window at its own shape, centred -- the
	// PSP pillarboxes it (Family Guy's episodes; the maintainer, the first rig session). The scene's
	// units are square at 16:9: a 4:3 picture h high is h * 4 / 3 wide
	if (h->pres && h->have_rd && h->rd.pic_known && !h->rd.pic_wide) {
		float fw = hh * 4.0f / 3.0f, fh = hh;
		if (fw > ww) { fw = ww; fh = ww * 3.0f / 4.0f; }
		ww = fw; hh = fh;
	} else if (!fit && fabsf(ww - 854) < 1 && fabsf(hh - 480) < 1 && fabsf(cx) < 1 && fabsf(cy) < 1) return;
	float l = tx + (cx - ww / 2 - vx) * tw / vw, t = ty + (vy - (cy + hh / 2)) * th / vh;
	float W = ww * tw / vw, H = hh * th / vh;
	uint32_t hs = (uint32_t)(720.0f * 65536.0f / W), vs = (uint32_t)(480.0f * 65536.0f / H);
	float x0 = 0, y0 = 0, r = l + W, b = t + H;
	if (l < tx) { x0 = tx - l; l = tx; }
	if (t < ty) { y0 = ty - t; t = ty; }
	if (r > tx + tw) r = tx + tw;
	if (b > ty + th) b = ty + th;
	if (r <= l || b <= t) return;
	w->on = 1;
	w->x = (uint16_t)(l + 0.5f); w->y = (uint16_t)(t + 0.5f);
	w->w = (uint16_t)(r - l + 0.5f); w->h = (uint16_t)(b - t + 0.5f);
	w->hs = hs & 0x3FFFFFF; w->vs = vs & 0x3FFFFFF;
	w->x0 = (uint32_t)(x0 * (float)hs) & 0x3FFFFFF; w->y0 = (uint32_t)(y0 * (float)vs) & 0x3FFFFFF;
}

void umd_mh_levels(umd_menu_host *h, umd_menu_levels *lv)
{
	memset(lv, 0, sizeof(*lv));
	if (!h->m || h->mode == UMD_MH_NONE) return;
	int page = menu_page_open(h->m);
	h->mode = (page || !h->content) ? UMD_MH_MENU : UMD_MH_CONTENT;
	// THE PRESENTATION follows what is SEEN: with content playing, a page that draws nothing keeps the
	// content's (its aspect, no fit, no pillarbox, the HUD) while it still takes the keys. Family Guy
	// opens pageDummy (one plane at alpha 0) for 3 s as an episode starts: as a menu, the 4:3 episode
	// showed pillarboxed in a 16:9 raster -- squeezed on the maintainer's CRT -- until it closed
	h->pres = !h->content || (page && menu_shows(h->m));
	if (h->mode == UMD_MH_MENU) { lv->grab = UMD_MH_GRAB_MENU; lv->menu = h->pres; lv->ui = page; }
	else lv->grab = UMD_MH_GRAB_CONTENT;
	lv->mute = h->mute;
	window(h, &lv->win);
}

char *umd_mh_kept(umd_menu_host *h, size_t *len)
{
	*len = 0;
	if (!h->m) return NULL;
	size_t n = menu_save(h->m, NULL, 0);
	char head[160];
	int hl = snprintf(head, sizeof(head), "R %d %u %u %llu %d %d %d %d %d\n", h->resume.have ? 1 : 0, h->resume.pl,
	                  h->resume.item, (unsigned long long)h->resume.pts, h->resume.video, h->resume.audio,
	                  h->resume.aflag, h->resume.sub, h->resume.sflag);
	char *t = (char *)malloc((size_t)hl + n + 1);
	if (!t) return NULL;
	memcpy(t, head, (size_t)hl);
	if (n) menu_save(h->m, t + hl, n);
	*len = (size_t)hl + n;
	t[*len] = 0;
	return t;
}

char *umd_mh_quit(umd_menu_host *h, size_t *len, int detached)
{
	*len = 0;
	if (!h->m || h->mode == UMD_MH_NONE) return NULL;
	h->detached = detached;
	// THE QUIT KEEPS THE POINT BEFORE THE SCRIPT'S onExit (fj#89, the rig 2026-10-10): the quit is the
	// system's interruption of the film, and Aliens' onExit (stop(-1, false)) and The Animatrix's
	// (stop()) stop it -- e_stop cleared `playing`, and the film's place was lost (fj#88's file, likely).
	// Family Guy's onExit does not stop: the 2026-10-07 checks passed on it. A script's stop() outside a
	// quit still keeps no point (M4 rule 2, Die Hard)
	keep_resume(h);
	// (fj#88: a resume asked and not yet landed -- the quit keeps that point, the onExit's stop() included)
	if (h->resume_used) { h->resume_used = 0; tr(h, "HOST resume point kept: quit before its landing"); }
	menu_exit(h->m);
	return umd_mh_kept(h, len);
}
