// umd_host.cpp -- see umd_host.h; the decisions are umd_host_logic.cpp's (pure, PC-benched).
//
// Two threads (docs/hps_host.md §1 "Where each part runs"):
//   * the POLL thread (Main's, CPU 1): every EXT_BUS transaction -- HOST_RD at the logic's
//     rate, HOST_WR for the heartbeat and the completions. Nothing slow runs here: it also
//     services the core's sector reads.
//   * the WORKER (ours, pinned to CPU 0, like Main's offload thread): one job at a time --
//     copy the unit out of the ring (uncached, 32-bit loads), decode it into the plane
//     (umd_sub_decode: palette fast path, 64-bit stores), a store barrier, then DONE.
//   The hand-off is one slot each way: the job (written by the poll thread while the worker is
//   IDLE, then a semaphore post), the worker's state (an atomic), the cancel flag (an atomic
//   the decode polls once a row: a flush's job stops within a row).
//
// Memory: the core's 64-bit word W is HPS byte W * 8 (hps_host.md §1). The ring is 2^20 words
// at 0x3200_0000 (8 MB), the planes at 0x3280_0000 / 0x32C0_0000. They are mapped once, by the
// worker, through Main's shmem_map (/dev/mem, O_SYNC: uncached). A unit's length comes from the
// fabric (u32): over the ring's size it is refused before anything is allocated.
//
// A cancelled job's partial rows stay in the back plane, harmlessly: while a decode is
// outstanding no flip can be pending (sub_sched's q_take needs the back plane free and no
// request at the display), so a flush only hides the front plane, and the next request writes
// the same back plane before its completion shows it (hps_host.md §3.2).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>

#include "../../user_io.h"
#include "../../spi.h"
#include "../../shmem.h"
#include "umd_host_proto.h"
#include "umd_host_logic.h"
#include "umd_sub.h"
#include "umd_host.h"
#include "umd_menu.h"
#include "umd_menu_logic.h"

#define RING_HPS     0x32000000u
#define RING_WORDS   (1u << 20)
#define PLANE0_HPS   0x32800000u
#define PLANE1_HPS   0x32C00000u
#define PLANE_BYTES  (UMD_PLANE_W * UMD_PLANE_H * 4u)
#define PLANE_MAP    ((PLANE_BYTES + 4095u) & ~4095u)

static umd_host_state st;
static int st_up = 0;

// ---- the worker -------------------------------------------------------------------------------
static pthread_t  w_thread;
static int        w_started = 0;
static sem_t      w_sem;
static int        w_state = UMD_W_IDLE;     // __atomic: UMD_W_*
static int        w_cancel = 0;             // __atomic
static struct { uint8_t seq, gen; int buf; uint16_t x, y; uint32_t start, len; } w_job;
static struct { int cancelled, err; uint32_t w, h; uint32_t us; } w_res;
static uint32_t   w_us_max = 0, w_us_last = 0, w_len_max = 0;
// P6d (docs/panel.md §2): what each subtitle plane holds -- the unit last decoded into it whole -- for the
// control panel, which draws the subtitle sub_sched shows under itself (umd_host_unit). A decode starting
// into a plane voids its entry first: a partial or cancelled one never names a unit.
static pthread_mutex_t lk_unit = PTHREAD_MUTEX_INITIALIZER;
static struct { int valid; uint8_t seq; uint16_t x, y; uint32_t w, h; } unit_tab[2];

static uint64_t now_us()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000u;
}

static int w_cancel_cb(void *) { return __atomic_load_n(&w_cancel, __ATOMIC_ACQUIRE); }

static void *worker(void *)
{
	volatile uint32_t *ring = NULL, *plane[2] = {NULL, NULL};
	for (;;) {
		sem_wait(&w_sem);
		uint64_t t0 = now_us();
		if (!ring) {
			ring = (volatile uint32_t *)shmem_map(RING_HPS, RING_WORDS * 8u);
			plane[0] = (volatile uint32_t *)shmem_map(PLANE0_HPS, PLANE_MAP);
			plane[1] = (volatile uint32_t *)shmem_map(PLANE1_HPS, PLANE_MAP);
		}
		umd_sub_result r;
		memset(&r, 0, sizeof(r));
		int cancelled = 0;
		if (!ring || !plane[0] || !plane[1]) {
			r.err = UMD_SUB_NOMEM;
		} else if (w_job.len == 0 || w_job.len > RING_WORDS * 8u) {
			r.err = UMD_SUB_REFUSED;                // longer than the ring: no allocation
		} else {
			uint8_t *png = (uint8_t *)malloc(w_job.len);
			if (!png) r.err = UMD_SUB_NOMEM;
			else {
				if (umd_ring_copy(ring, RING_WORDS, w_job.start, w_job.len, png) != w_job.len)
					r.err = UMD_SUB_REFUSED;
				else if (w_cancel_cb(NULL))
					r.err = UMD_SUB_CANCELLED;
				else {
					pthread_mutex_lock(&lk_unit);
					unit_tab[w_job.buf & 1].valid = 0;
					pthread_mutex_unlock(&lk_unit);
					umd_sub_decode(png, w_job.len, w_job.x, w_job.y, plane[w_job.buf & 1], &r, w_cancel_cb, NULL);
				}
				free(png);
			}
		}
		if (r.err == UMD_SUB_CANCELLED) cancelled = 1;
		__sync_synchronize();                       // the plane's last row out of the write buffer
		if (!cancelled && r.err == 0) {
			pthread_mutex_lock(&lk_unit);
			int b = w_job.buf & 1;
			unit_tab[b].valid = 1; unit_tab[b].seq = w_job.seq;
			unit_tab[b].x = w_job.x; unit_tab[b].y = w_job.y; unit_tab[b].w = r.w; unit_tab[b].h = r.h;
			pthread_mutex_unlock(&lk_unit);
		}
		w_res.cancelled = cancelled;
		w_res.err = r.err;
		w_res.w = r.w;
		w_res.h = r.h;
		w_res.us = (uint32_t)(now_us() - t0);
		if (w_res.us > w_us_max) w_us_max = w_res.us;
		w_us_last = w_res.us;
		if (w_job.len > w_len_max) w_len_max = w_job.len;
		__atomic_store_n(&w_state, UMD_W_DONE, __ATOMIC_RELEASE);
	}
	return NULL;
}

static void worker_start()
{
	if (w_started) return;
	sem_init(&w_sem, 0, 0);
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(0, &set);                               // Main's poll is on CPU 1 (main.cpp)
	pthread_attr_setaffinity_np(&attr, sizeof(set), &set);
	if (pthread_create(&w_thread, &attr, worker, NULL) == 0) w_started = 1;
	pthread_attr_destroy(&attr);
}

static void worker_view(umd_host_worker *wk)
{
	memset(wk, 0, sizeof(*wk));
	wk->state = __atomic_load_n(&w_state, __ATOMIC_ACQUIRE);
	wk->seq = w_job.seq;
	wk->gen = w_job.gen;
	if (wk->state == UMD_W_DONE) {
		wk->cancelled = w_res.cancelled;
		wk->err = w_res.err;
		wk->w = w_res.w;
		wk->h = w_res.h;
	}
}

// ---- the port ----------------------------------------------------------------------------------
// One port, two logics (docs/p9.md M3 E2): a HOST_RD's 38 words feed this file's decisions and the
// menus' (umd_menu.cpp); a HOST_WR carries words 1-4 (the heartbeat, a completion) and, once the menu
// side has adopted the core's seqs, words 5-37 (its records and levels) -- the menus' words from their
// last step, re-sent unchanged by a subtitle write (each record is once-only by its seq).
static uint16_t menu_wr[UMD_HOST_WR_NWORDS];
static uint16_t rd_raw[UMD_HOST_NWORDS];
static void host_rd(umd_host_rd *rd)
{
	uint16_t *w = rd_raw;
	w[0] = spi_uio_cmd_cont(UMD_HOST_CMD_RD);
	for (int i = 1; i < UMD_HOST_NWORDS; i++) w[i] = spi_w(0);
	DisableIO();
	memset(rd, 0, sizeof(*rd));
	rd->magic    = (w[UMD_HOST_RD_MAGIC] == UMD_HOST_MAGIC);
	rd->proto_ok = rd->magic && (w[UMD_HOST_RD_PROTO] >> 8) == UMD_HOST_PROTO;
	rd->req      = (w[UMD_HOST_RD_REQ] >> 15) & 1;
	rd->buf      = (w[UMD_HOST_RD_REQ] >> 14) & 1;
	rd->seq      = (uint8_t)w[UMD_HOST_RD_REQ];
	rd->gen      = (uint8_t)w[UMD_HOST_RD_GEN];
	rd->x        = w[UMD_HOST_RD_REQ_X];
	rd->y        = w[UMD_HOST_RD_REQ_Y];
	rd->start    = (uint32_t)w[UMD_HOST_RD_REQ_START_LO] | (uint32_t)(w[UMD_HOST_RD_REQ_START_HI] & 0xF) << 16;
	rd->len      = (uint32_t)w[UMD_HOST_RD_REQ_LEN_LO] | (uint32_t)w[UMD_HOST_RD_REQ_LEN_HI] << 16;
}

static void host_wr(const uint16_t *wr)
{
	spi_uio_cmd_cont(UMD_HOST_CMD_WR);
	for (int i = 0; i < 4; i++) spi_w(wr[i]);
	if (umd_menu_writes())
		for (int i = UMD_HOST_WR_PCMD; i < UMD_HOST_WR_NWORDS; i++) spi_w(menu_wr[i]);
	DisableIO();
}

static void apply(umd_host_act *a)
{
	if (a->consume) __atomic_store_n(&w_state, UMD_W_IDLE, __ATOMIC_RELEASE);
	if (a->cancel)  __atomic_store_n(&w_cancel, 1, __ATOMIC_RELEASE);
	if (a->write)   host_wr(a->wr);
	if (a->start) {
		w_job.seq = a->j_seq; w_job.gen = a->j_gen; w_job.buf = a->j_buf;
		w_job.x = a->j_x; w_job.y = a->j_y; w_job.start = a->j_start; w_job.len = a->j_len;
		__atomic_store_n(&w_cancel, 0, __ATOMIC_RELEASE);
		__atomic_store_n(&w_state, UMD_W_BUSY, __ATOMIC_RELEASE);
		sem_post(&w_sem);
	}
}

void umd_host_tick()
{
	if (!st_up) { umd_host_init(&st); st_up = 1; }
	worker_start();
	uint32_t now = (uint32_t)(now_us() / 1000u);
	umd_host_worker wk;
	umd_host_act a;
	worker_view(&wk);
	umd_host_step(&st, now, NULL, &wk, &a);
	// the menus' read rate: UMD_HOST_READ_FAST_MS while their logic asks for it (a record awaits its
	// echo, a landing, a grabbed button), else the subtitle side's own rate
	static uint32_t t_menu_rd = 0;
	static int menu_fast = 0;
	int want_read = a.read || (menu_fast && now - t_menu_rd >= (umd_menu_keys_only() ? UMD_MENU_READ_KEYS_MS : UMD_HOST_READ_FAST_MS));
	apply(&a);
	int menu_ww = 0;
	if (want_read) {
		umd_host_rd rd;
		host_rd(&rd);
		t_menu_rd = now;
		worker_view(&wk);
		umd_host_step(&st, now, &rd, &wk, &a);
		apply(&a);
		umd_menu_poll(now, rd.magic && rd.proto_ok ? rd_raw : NULL, menu_wr, &menu_ww, &menu_fast);
	} else {
		umd_menu_poll(now, NULL, menu_wr, &menu_ww, &menu_fast);
	}
	umd_menu_sub_busy(st.job);
	// the menus' own write when the subtitle side wrote nothing new: the bare heartbeat in words 1-4
	// (no completion bit: a completion is never sent twice)
	if (menu_ww && umd_menu_writes()) {
		const uint16_t hb[4] = { (uint16_t)(UMD_HOST_PROTO << 8 | UMD_HOST_VERSION), 0, 0, 0 };
		host_wr(hb);
	}
}

void umd_host_away()
{
	umd_menu_away();
	pthread_mutex_lock(&lk_unit);
	unit_tab[0].valid = unit_tab[1].valid = 0;      // (another core: the planes' units are gone)
	pthread_mutex_unlock(&lk_unit);
	if (!st_up) return;
	umd_host_worker wk;
	umd_host_act a;
	worker_view(&wk);
	umd_host_off(&st, &wk, &a);
	if (a.cancel) __atomic_store_n(&w_cancel, 1, __ATOMIC_RELEASE);
	// a finished job is consumed now (its completion would go to no one)
	if (wk.state == UMD_W_DONE) { __atomic_store_n(&w_state, UMD_W_IDLE, __ATOMIC_RELEASE); st.job = 0; st.cancel_sent = 0; }
}

int umd_host_unit(uint8_t seq, int *buf, int *x, int *y, int *w, int *h)
{
	int found = -1;
	pthread_mutex_lock(&lk_unit);
	for (int b = 0; b < 2; b++)
		if (unit_tab[b].valid && unit_tab[b].seq == seq) {
			*buf = b; *x = unit_tab[b].x; *y = unit_tab[b].y;
			*w = unit_tab[b].w > 0xFFFF ? 0xFFFF : (int)unit_tab[b].w;
			*h = unit_tab[b].h > 0xFFFF ? 0xFFFF : (int)unit_tab[b].h;
			found = 0;
			break;
		}
	pthread_mutex_unlock(&lk_unit);
	return found;
}

void umd_host_stats(FILE *f)
{
	fprintf(f, "{\"rd\":%u,\"wr\":%u,\"served\":%u,\"cancelled\":%u,\"resent\":%u,\"forgot\":%u,"
	           "\"refused\":%u,\"nomagic\":%u,\"badproto\":%u,\"job\":%d,\"worker\":%d,"
	           "\"us_last\":%u,\"us_max\":%u,\"len_max\":%u,\"last_seq\":%u,\"rd_req\":%d,\"rd_seq\":%u,\"rd_gen\":%u}",
	        st.n_rd, st.n_wr, st.n_served, st.n_cancelled, st.n_resent, st.n_forgot,
	        st.n_refused, st.n_nomagic, st.n_badproto, st.job, __atomic_load_n(&w_state, __ATOMIC_ACQUIRE),
	        w_us_last, w_us_max, w_len_max, st.last_seq, st.rd.req, st.rd.seq, st.rd.gen);
}
