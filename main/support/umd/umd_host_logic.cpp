// umd_host_logic.cpp -- see umd_host_logic.h (the rules) and docs/hps_host.md §3.2, §6 "B4".
// Plain C that also compiles as C++ (Main builds support/*/*.cpp); the PC bench builds it too.

#include <string.h>

#include "umd_host_proto.h"
#include "umd_host_logic.h"

static inline uint32_t age(uint32_t now, uint32_t t) { return now - t; }   // wraps

void umd_host_init(umd_host_state *s)
{
	memset(s, 0, sizeof(*s));
}

static void write_words(umd_host_state *s, uint32_t now, umd_host_act *a,
                        uint16_t done, uint16_t w, uint16_t h)
{
	a->write = 1;
	a->wr[0] = (uint16_t)(UMD_HOST_PROTO << 8 | UMD_HOST_VERSION);
	a->wr[1] = done;
	a->wr[2] = w;
	a->wr[3] = h;
	s->t_hb = now;
	s->n_wr++;
}

static void cancel_job(umd_host_state *s, umd_host_act *a)
{
	if (s->job && !s->cancel_sent) {
		a->cancel = 1;
		s->cancel_sent = 1;
	}
}

void umd_host_off(umd_host_state *s, const umd_host_worker *wk, umd_host_act *a)
{
	memset(a, 0, sizeof(*a));
	(void)wk;
	s->have_last = 0;
	s->have_rd = 0;
	cancel_job(s, a);
}

void umd_host_step(umd_host_state *s, uint32_t now, const umd_host_rd *rd,
                   const umd_host_worker *wk, umd_host_act *a)
{
	memset(a, 0, sizeof(*a));

	// ---- the worker's result: a completion, unless the job was cancelled ----
	if (wk->state == UMD_W_DONE) {
		a->consume = 1;
		if (s->job && !s->cancel_sent && !wk->cancelled && wk->seq == s->job_seq && wk->gen == s->job_gen) {
			uint16_t done = (uint16_t)(0x8000u | (uint16_t)(wk->err & 0x1F) << 8 | wk->seq);
			uint16_t w = umd_host_sat16(wk->w), h = umd_host_sat16(wk->h);
			write_words(s, now, a, done, w, h);
			s->have_last = 1;
			s->last_seq = wk->seq; s->last_gen = wk->gen;
			s->last_done = done; s->last_w = w; s->last_h = h;
			s->t_last = now;
			s->resends = 0;
			s->n_served++;
			if (wk->err != 0) s->n_refused++;
		} else {
			s->n_cancelled++;               // stopped (or finished) after its request went: no completion
		}
		s->job = 0;
		s->cancel_sent = 0;
	}

	// ---- a read: is it time? (the glue reads and calls again with it) ----
	if (!rd) {
		int fast = (s->have_rd && s->rd.req) || s->job || wk->state != UMD_W_IDLE ||
		           (s->have_req && age(now, s->t_req) < UMD_HOST_ACTIVE_MS);
		uint32_t period = fast ? UMD_HOST_READ_FAST_MS : UMD_HOST_READ_SLOW_MS;
		if (!s->n_rd || age(now, s->t_rd) >= period)
			a->read = 1;
	} else {
		s->t_rd = now;
		s->n_rd++;
		if (!rd->magic) {
			// not our core (or not yet up): forget everything, write nothing
			s->n_nomagic++;
			s->have_last = 0;
			s->have_rd = 0;
			s->have_req = 0;
			cancel_job(s, a);
			return;
		}
		s->rd = *rd;
		s->have_rd = 1;
		if (rd->req) { s->t_req = now; s->have_req = 1; }
		if (!rd->proto_ok) {
			// a core of another PROTO: no serving; the heartbeat (below) tells it so
			s->n_badproto++;
			s->have_last = 0;
			cancel_job(s, a);
		} else {
			// the job's request gone (none, another seq, a flush's gen): cancel it
			if (s->job && (!rd->req || rd->seq != s->job_seq || rd->gen != s->job_gen))
				cancel_job(s, a);
			// a request, the worker idle (and no completion of ours this tick)
			if (!s->job && wk->state == UMD_W_IDLE && !a->consume && rd->req && !a->write) {
				int same = s->have_last && rd->seq == s->last_seq && rd->gen == s->last_gen;
				uint32_t t = age(now, s->t_last);
				if (same && t < UMD_HOST_FORGET_MS) {
					// the completion is on its way, or was lost: resend after a while
					if (t >= UMD_HOST_RESEND_MS * (uint32_t)(s->resends + 1) && s->resends < UMD_HOST_RESEND_MAX) {
						write_words(s, now, a, s->last_done, s->last_w, s->last_h);
						s->resends++;
						s->n_resent++;
					}
				} else {
					if (same) s->n_forgot++;    // too old to be ours: a new core's request
					s->have_last = 0;
					a->start = 1;
					a->j_seq = rd->seq; a->j_gen = rd->gen; a->j_buf = rd->buf;
					a->j_x = rd->x; a->j_y = rd->y; a->j_start = rd->start; a->j_len = rd->len;
					s->job = 1; s->job_seq = rd->seq; s->job_gen = rd->gen; s->cancel_sent = 0;
				}
			}
		}
	}

	// ---- the heartbeat ----
	if (!a->write && s->have_rd && s->rd.magic && age(now, s->t_hb) >= UMD_HOST_HEARTBEAT_MS)
		write_words(s, now, a, 0, 0, 0);
}
