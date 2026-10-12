// hps_host_check.cpp -- B4's PC bench (docs/hps_host.md §6): the UMD Main's host decisions
// (main/support/umd/umd_host_logic.cpp) against a model of the FABRIC's side, written from
// the RTL, not from the host: umd/sub/sub_top.sv's host block (seq counts requests and is
// never reset by a flush; gen counts flushes; a completion is accepted only with a request up,
// its seq matching and not in a flush's cycle; the rest counted stale) and umd_host.sv's
// heartbeat (2^26 / 27 MHz = 2.49 s). The worker is faked: each job takes a scripted time and
// stops within a "row" (1 ms) of a cancel. Time steps 40 us (Main's poll pass is ~36 us: B2).
//
//   hps_host_check            all scenarios; PASS hps_host_check
//
// Arms (each line "FAIL [arm] ..."; run_hps_host.sh --red proves each can fail):
//   [served]    every request the fabric posts is accepted exactly once, from a job the host
//               started while THAT request was outstanding (no completion for a unit never decoded)
//   [stale]     the fabric counts no stale completion beyond the scenario's allowance (a
//               completion racing a flush the host had not yet read)
//   [cancel]    a job whose request was flushed is cancelled within 2 read periods + 1 row
//   [order]     the worker is never given a job while it is busy (one at a time, in order)
//   [heartbeat] host_ok never drops while the host runs, and HOST_WRs are never more than
//               HEARTBEAT_MS + a tick apart while the core answers
//   [rate]      with subtitles running, a request waits at most READ_FAST_MS + a tick to be read
//   [latency]   every request is accepted within the longest decode + 25 ms (a lost completion
//               resent, not left to the forget rule)
//   [reload]    after a core reload no completion of the old core's is accepted by the new one
//   [proto]     a core of another PROTO: no job, the heartbeat still sent
//   [sat]       a 1,000,000-wide image completes with w = 0xFFFF

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <vector>

#include "umd_host_proto.h"
#include "umd_host_logic.h"

// the bench's OWN expectations (docs/hps_host.md §6 "B4"), never the header's constants: a
// mutated header must not move the bar it is measured against
#define EXP_HEARTBEAT_MS 100       // umd_host.sv times out at 2.49 s; Main's menus sleep 2 s
#define EXP_FAST_MS      2         // a request read this soon while subtitles run
#define EXP_SLOW_MS      50        // ... and after a long quiet
#define EXP_ACTIVE_MS    10000     // "subtitles running": a request seen this recently
#define EXP_CANCEL_MS    (2 * EXP_FAST_MS + 1)

static int n_fail = 0;
static const char *scen = "";
static void fail(const char *arm, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void fail(const char *arm, const char *fmt, ...)
{
	if (n_fail++ > 20) return;
	va_list ap;
	printf("FAIL [%s] %s: ", arm, scen);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

// ---- the fabric (sub_top's host block + umd_host's heartbeat) ---------------------------------
struct Fabric {
	int up = 1;                 // the core answers (MAGIC)
	int proto = UMD_HOST_PROTO;
	int req = 0, buf = 0, front = 0;
	uint8_t seq = 0, gen = 0;
	int cur = -1;               // the outstanding request's id
	int next_id = 0;
	int pending = 0;            // units queued behind it
	std::vector<int> accepted;  // per request id: times accepted
	std::vector<int> started;   // per request id: a job was started while it was outstanding
	std::vector<uint32_t> w_of; // per request id: the image's width (the [sat] case)
	std::vector<uint64_t> t_up; // per request id: when it went up (us)
	int n_stale = 0;
	int drop_next = 0;          // lose the next N completions on the way (a merged toggle)
	uint64_t hb_until = 0;      // host_ok while t < hb_until (us)
	int host_ok_seen = 0;
	uint32_t req_since = 0;     // when the current request went up (ms)
	uint32_t last_req_ms = 0;   // the PREVIOUS request's time (the bench's "subtitles running")
	int last_req_ms_valid = 0;
	int read_since_req = 0;
	void take(uint32_t now_ms) {
		if (!up || req || pending == 0) return;
		pending--;
		seq++;
		req = 1; buf = !front; cur = next_id++;
		accepted.push_back(0); started.push_back(0); w_of.push_back(640); t_up.push_back(0);
		if (cur > 0) { last_req_ms = req_since; last_req_ms_valid = 1; }
		req_since = now_ms; read_since_req = 0;
	}
	void flush() { if (req) req = 0; cur = -1; gen++; }
	void reload() { up = 0; req = 0; cur = -1; seq = 0; gen = 0; front = 0; pending = 0; }
	uint32_t lat_max_ms = 0;
	void wr(uint64_t t_us, const uint16_t *w) {
		if (!up) return;
		if ((w[0] >> 8) == proto) hb_until = t_us + 2490000; // 2^26 / 27 MHz
		if (!(w[1] & 0x8000)) return;
		if (drop_next > 0) { drop_next--; return; }
		uint8_t s = (uint8_t)w[1];
		if (req && s == seq) {
			accepted[cur]++;
			if (!started[cur]) fail("served", "request %d (seq %u gen %u) accepted with no job started for it", cur, seq, gen);
			if (cur < (int)w_of.size() && w_of[cur] > 0xFFFF && w[2] != 0xFFFF)
				fail("sat", "a %u-wide image completed with w = %u", w_of[cur], w[2]);
			req = 0;
			uint32_t lat = (uint32_t)((t_us - t_up[cur]) / 1000);
			if (lat > lat_max_ms) lat_max_ms = lat;
			if (((w[1] >> 8) & 0x1F) == 0) front = !front;   // shown (sub_sched flips to it)
			cur = -1;
		} else n_stale++;
	}
	void rd(umd_host_rd *r) {
		memset(r, 0, sizeof(*r));
		r->magic = up;
		r->proto_ok = up && proto == UMD_HOST_PROTO;
		r->req = req; r->buf = buf; r->seq = seq; r->gen = gen;
		r->x = 100; r->y = 400; r->start = 0x123; r->len = 4000;
		if (req) read_since_req = 1;
	}
};

// ---- the fake worker ------------------------------------------------------------------------------
struct Worker {
	int state = UMD_W_IDLE, cancel = 0, cancelled = 0;
	uint8_t seq = 0, gen = 0;
	uint64_t done_at = 0, cancel_at = 0;
	uint32_t w = 0, h = 0;
	int job_id = -1;
};

struct Run {
	uint32_t dur_ms_min = 2, dur_ms_max = 40;   // a decode's time
	int units = 40;
	double p_flush = 0;                         // a flush per job, this chance (mid-decode)
	double p_drop = 0;                          // a completion lost, this chance
	int reload_at = -1;                         // reload after this many accepted
	uint32_t reload_gap_ms = 2000;              // MAGIC missing this long
	int bad_proto = 0;
	int idle_ms = 0;                            // run idle first (the heartbeat, the read rate)
	int sat_unit = -1;                          // this request's image is 1,000,000 wide
	uint32_t gap_min = 100, gap_max = 400;      // ms between units (a disc's lines)
	int reload_nogap = 0;                       // reload with MAGIC never missing; its first unit
	uint32_t reload_delay_ms = 0;               //   this long after (the forget rule's case)
};

static unsigned rng = 1;
static uint32_t rnd(uint32_t n) { rng = rng * 1103515245u + 12345u; return (rng >> 8) % (n ? n : 1); }

static void run(const char *name, const Run &R)
{
	scen = name;
	Fabric F;
	Worker W;
	umd_host_state S;
	umd_host_init(&S);
	F.proto = R.bad_proto ? UMD_HOST_PROTO + 1 : UMD_HOST_PROTO;
	F.pending = 0;
	int arrived = 0, after_reload = 0;
	uint64_t next_arrival = (uint64_t)R.idle_ms * 1000;
	int reloaded = 0, n_jobs = 0, races = 0;
	uint64_t t = 0, reload_t = 0, last_wr = 0;
	uint64_t flushed_at = 0; int flush_job = -1;
	const uint64_t step = 40;                   // us
	const uint64_t t_end = (uint64_t)(R.idle_ms + 60000) * 1000;
	if (R.idle_ms) F.pending = 0;
	while (t < t_end) {
		t += step;
		uint32_t now = (uint32_t)(t / 1000);
		// the units arrive, a disc's lines apart
		if (F.up && t >= next_arrival && ((!reloaded && arrived < R.units) || (reloaded && after_reload < 8 &&
		    t >= reload_t + (uint64_t)(R.reload_gap_ms + R.reload_delay_ms) * 1000))) {
			F.pending++;
			if (reloaded) after_reload++; else arrived++;
			next_arrival = t + 1000ull * (R.gap_min + rnd(R.gap_max - R.gap_min + 1));
		}
		// the fabric: take the next unit when free; a reload; the heartbeat's state
		if (!F.up && reloaded && t >= reload_t + (uint64_t)R.reload_gap_ms * 1000) {
			F.up = 1; F.hb_until = 0;
		}
		F.take(now);
		if (F.req && F.t_up[F.cur] == 0) F.t_up[F.cur] = t;
		if (F.req && F.cur == R.sat_unit) F.w_of[F.cur] = 1000000;
		if (F.up && t > 300000 && t < F.hb_until) F.host_ok_seen = 1;
		if (F.up && F.host_ok_seen && t >= F.hb_until && !R.bad_proto && !(reloaded && t < reload_t + (uint64_t)(R.reload_gap_ms + 3000) * 1000))
			fail("heartbeat", "host_ok dropped at %.3f s (last HOST_WR %.3f s ago)", t / 1e6, (t - last_wr) / 1e6), F.hb_until = t + 2490000;
		// the worker
		if (W.state == UMD_W_BUSY) {
			if (W.cancel && !W.cancel_at) W.cancel_at = t;
			if (W.cancel && t >= W.cancel_at + 1000) { W.state = UMD_W_DONE; W.cancelled = 1; }
			else if (t >= W.done_at) { W.state = UMD_W_DONE; W.cancelled = 0; }
		}
		umd_host_worker wk;
		memset(&wk, 0, sizeof(wk));
		wk.state = W.state; wk.seq = W.seq; wk.gen = W.gen;
		if (W.state == UMD_W_DONE) { wk.cancelled = W.cancelled; wk.err = W.cancelled ? 3 : 0; wk.w = W.w; wk.h = W.h; }
		// the host's tick (as umd_host_tick does it)
		umd_host_act a;
		for (int pass = 0; pass < 2; pass++) {
			umd_host_rd rd;
			if (pass == 1) F.rd(&rd);
			umd_host_step(&S, now, pass ? &rd : NULL, &wk, &a);
			if (a.consume) { W.state = UMD_W_IDLE; wk.state = UMD_W_IDLE; }
			if (a.cancel) W.cancel = 1;
			if (a.write) {
				if (a.wr[1] & 0x8000) {
					// a completion: its FIRST transmission lost on the way, sometimes (a resend
					// is never lost too: a loss is two completions merged in one crossing round,
					// which this host never sends -- umd_host.sv's contract)
					static int last_req_dropped = -1;
					if (R.p_drop > 0 && F.cur >= 0 && F.cur != last_req_dropped && rnd(1000) < (uint32_t)(R.p_drop * 1000)) {
						F.drop_next = 1; last_req_dropped = F.cur;
					} else if (F.cur >= 0) last_req_dropped = (F.cur == last_req_dropped) ? last_req_dropped : -1;
				}
				// [stale]: a completion the fabric counts stale must be one the host still believed in
				// (its last read showed that seq outstanding: a race with a flush it had not read yet)
				int believed = S.have_rd && S.rd.req && S.rd.seq == (uint8_t)a.wr[1];
				int st0 = F.n_stale;
				if (F.up && last_wr && t - last_wr > 1000ull * (EXP_HEARTBEAT_MS + 1) && !(reloaded && t < reload_t + 3000000ull + (uint64_t)R.reload_gap_ms * 1000))
					fail("heartbeat", "HOST_WRs %.1f ms apart", (t - last_wr) / 1e3);
				F.wr(t, a.wr); last_wr = t;
				if (F.n_stale > st0) {
					if (believed) races++;
					else fail("stale", "a completion of seq %u sent after the host read it gone", (uint8_t)a.wr[1]);
				}
			}
			if (a.start) {
				if (W.state != UMD_W_IDLE) fail("order", "a job started while the worker is busy");
				if (!(F.req && a.j_seq == F.seq && a.j_gen == F.gen)) fail("served", "a job started for seq %u gen %u, not outstanding", a.j_seq, a.j_gen);
				else F.started[F.cur] = 1;
				W.state = UMD_W_BUSY; W.cancel = 0; W.cancel_at = 0; W.seq = a.j_seq; W.gen = a.j_gen;
				W.done_at = t + 1000ull * (R.dur_ms_min + rnd(R.dur_ms_max - R.dur_ms_min + 1));
				W.w = (F.cur >= 0) ? F.w_of[F.cur] : 640; W.h = 80; W.job_id = F.cur;
				wk.state = UMD_W_BUSY; wk.seq = W.seq; wk.gen = W.gen;
				n_jobs++;
				// a flush mid-decode, sometimes (a seek)
				if (R.p_flush > 0 && rnd(1000) < (uint32_t)(R.p_flush * 1000)) { flushed_at = t + 500 + rnd(3000); flush_job = F.cur; }
			}
			if (!a.read) break;
		}
		if (flushed_at && t >= flushed_at) {
			if (F.cur == flush_job && F.req) { F.flush(); F.pending++; }   // the unit comes again later (a new one)
			flushed_at = 0;
		}
		// [cancel]: the flushed job stopped within two read periods and a row
		if (W.state == UMD_W_BUSY && W.job_id >= 0 && F.cur != W.job_id) {
			static uint64_t gone_at = 0; static int gone_job = -2;
			if (gone_job != W.job_id) { gone_job = W.job_id; gone_at = t; }
			if (t - gone_at > 1000ull * EXP_CANCEL_MS + 2 * step && t < W.done_at)
				fail("cancel", "job %d still running %.1f ms after its request went", W.job_id, (t - gone_at) / 1e3), gone_job = -3;
		}
		// [rate]: with subtitles running (a request seen in the last ACTIVE_MS), a new request is
		// read within READ_FAST + a tick; after a long quiet, within READ_SLOW + a tick
		if (F.req && !F.read_since_req) {
			// ("subtitles running": the bench's own view -- a request went up within EXP_ACTIVE_MS)
			uint32_t lim = (F.last_req_ms_valid && now - F.last_req_ms < EXP_ACTIVE_MS) ? EXP_FAST_MS + 1 : EXP_SLOW_MS + 1;
			if (now - F.req_since > lim && S.n_rd)
				fail("rate", "request seq %u unread %u ms after it went up (limit %u)", F.seq, now - F.req_since, lim), F.read_since_req = 1;
		}
		// a core reload
		if (R.reload_at >= 0 && !reloaded) {
			int acc = 0;
			for (int x : F.accepted) acc += x;
			if (acc >= R.reload_at && W.state == UMD_W_IDLE && !F.req) {
				F.reload(); reloaded = 1; reload_t = t;
				F.last_req_ms_valid = 0;
				next_arrival = t;                       // the new core's first unit as soon as it is up
				if (R.reload_nogap) F.up = 1;           // MAGIC never missing (only the forget rule can tell)
			}
		}
		// done: everything accepted
		if (F.up && F.pending == 0 && !F.req && W.state == UMD_W_IDLE && arrived >= R.units &&
		    (R.reload_at < 0 || (reloaded && after_reload >= 8)) && t > next_arrival + 200000)
			break;
	}
	// the counts
	int n_req = (int)F.accepted.size(), n_acc = 0, n_flushed = 0;
	for (int i = 0; i < n_req; i++) {
		n_acc += F.accepted[i];
		if (F.accepted[i] > 1) fail("served", "request %d accepted %d times", i, F.accepted[i]);
	}
	if (R.bad_proto) {
		if (n_jobs) fail("proto", "%d jobs started for a core of another PROTO", n_jobs);
		if (S.n_wr == 0) fail("proto", "no heartbeat sent to a core of another PROTO");
	} else {
		for (int i = 0; i < n_req; i++) if (!F.accepted[i] && F.started[i] == 0 && i != F.cur) n_flushed++;
		if (F.pending != 0 || F.req) fail("served", "%d units left, a request up at the end", F.pending);
		for (int i = 0; i < n_req; i++) if (!F.accepted[i] && !(R.p_flush > 0)) fail("served", "request %d never accepted", i);
		if (R.p_flush == 0 && F.lat_max_ms > R.dur_ms_max + 25)
			fail("latency", "a request accepted %u ms after it went up (the decode at most %u)", F.lat_max_ms, R.dur_ms_max);
		(void)n_flushed;
	}
	printf("hps_host_check: %-10s %3d requests, %3d accepted, %3d jobs, served %u, cancelled %u, resent %u, forgot %u, "
	       "stale %d (%d races), worst latency %u ms, rd %u, wr %u\n", name, n_req, n_acc, n_jobs, S.n_served, S.n_cancelled,
	       S.n_resent, S.n_forgot, F.n_stale, races, F.lat_max_ms, S.n_rd, S.n_wr);
}

int main()
{
	{ Run r; run("normal", r); }
	{ Run r; r.p_flush = 0.3; r.units = 60; run("flush", r); }
	{ Run r; r.p_drop = 0.3; r.units = 60; run("lost", r); }
	{ Run r; r.reload_at = 1; r.reload_gap_ms = 50; run("reload50", r); }
	{ Run r; r.reload_at = 5; r.reload_gap_ms = 2000; run("reload2s", r); }
	{ Run r; r.reload_at = 1; r.reload_nogap = 1; r.reload_gap_ms = 0; r.reload_delay_ms = 300; run("reloadng", r); }
	{ Run r; r.bad_proto = 1; r.units = 5; run("badproto", r); }
	{ Run r; r.idle_ms = 10000; r.units = 5; run("idle", r); }
	{ Run r; r.sat_unit = 3; r.units = 6; run("sat", r); }
	if (n_fail) { printf("FAIL hps_host_check: %d failures\n", n_fail); return 1; }
	printf("PASS hps_host_check\n");
	return 0;
}
