// umd_host_logic.h -- the UMD Main's host-port decisions (docs/hps_host.md §3.2, B4), as a
// pure function: what to read, start, cancel and send, given the clock, the last HOST_RD and
// the worker's state. No Main dependency, no I/O: umd_host.cpp does the SPI, the mappings and
// the worker; bench/umd/run_hps_host.sh drives this on the PC against a C model of sub_top's
// acceptance rule (tools/hps_host_check.cpp).
//
// THE RULES (each one a reason the fabric's side, umd/sub/sub_top.sv, relies on):
//   * One job at a time, in order: a new request is served only when the worker is idle (a
//     cancelled job included: it stops at a row boundary first). A dropped request's late
//     pixels then always land before the next request's (hps_host.md §3.2).
//   * Cancel when the job's request is gone: HOST_RD shows no request, another seq, or another
//     gen (a flush). A cancelled job sends NO completion (the fabric would only count it stale).
//   * One completion per HOST_WR (umd_host.sv's contract: two inside one crossing round merge).
//   * A completion lost on the way (the request still up with its seq and gen) is resent after
//     RESEND_MS, at most RESEND_MAX times; a duplicate the fabric already took is only counted
//     stale. Past FORGET_MS the pair is treated as a NEW request: a core reload restarts seq
//     and gen at the same values, and the old completion must never be resent for the new
//     core's first unit.
//   * Anything that says the core is not ours -- MAGIC missing, not the UMD core -- clears the
//     remembered completion and cancels the job (umd_host_off()).
//   * The heartbeat: a HOST_WR at least every HEARTBEAT_MS (the core's timeout is 2.49 s, and
//     stock Main's menus sleep up to 2 s on the poll thread: B2). Sent while MAGIC answers,
//     whatever the PROTO: a mismatched core shows "Update the UMD Main" from it.
//   * The read rate: every READ_FAST_MS while a request is up, a job is in flight, or a request
//     was seen in the last ACTIVE_MS (subtitles are running: the NEXT request must not wait a
//     slow period -- The Mummy's units are 0.1 s apart and the decode takes up to ~31 ms), else
//     every READ_SLOW_MS (no subtitles: the idle cost near zero; a 13-word read is ~15 us, B2).
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UMD_HOST_VERSION     1      // the host's own version, in the heartbeat word's low byte
#define UMD_HOST_READ_FAST_MS 2
#define UMD_HOST_READ_SLOW_MS 50
#define UMD_HOST_HEARTBEAT_MS 100
#define UMD_HOST_RESEND_MS    5
#define UMD_HOST_RESEND_MAX   3
#define UMD_HOST_FORGET_MS    100
#define UMD_HOST_ACTIVE_MS    10000

// a HOST_RD, decoded (umd_host_proto.h's words)
typedef struct {
	int      magic;                 // word 0 was MAGIC (a UMD core with the port answered)
	int      proto_ok;              // word 1's PROTO is ours
	int      req;                   // a request is outstanding
	int      buf;                   // its plane
	uint8_t  seq, gen;
	uint16_t x, y;
	uint32_t start, len;            // ring word, PNG bytes
} umd_host_rd;

// the worker, as the poll side sees it
enum { UMD_W_IDLE = 0, UMD_W_BUSY = 1, UMD_W_DONE = 2 };
typedef struct {
	int      state;                 // UMD_W_*
	uint8_t  seq, gen;              // the job's (BUSY / DONE)
	int      cancelled;             // DONE: it stopped on a cancel
	int      err;                   // DONE: umd_sub_err (0 decoded)
	uint32_t w, h;                  // DONE: the image's size
} umd_host_worker;

typedef struct {
	uint32_t t_rd, t_hb;            // the last read, the last HOST_WR
	uint32_t t_req;                 // the last read that showed a request
	int      have_req;
	int      have_rd;
	umd_host_rd rd;                 // the last read
	int      job;                   // a job in flight (started, not yet DONE)
	uint8_t  job_seq, job_gen;
	int      cancel_sent;
	int      have_last;             // a completion sent, remembered for a resend
	uint8_t  last_seq, last_gen;
	uint16_t last_done, last_w, last_h;
	uint32_t t_last;
	int      resends;
	// counters (the HIL's /tmp/umd_host.json)
	uint32_t n_rd, n_wr, n_served, n_cancelled, n_resent, n_forgot, n_refused, n_nomagic, n_badproto;
} umd_host_state;

// what to do this tick
typedef struct {
	int      read;                  // do a HOST_RD now (then call umd_host_step again with it)
	int      start;                 // give the worker this job
	uint8_t  j_seq, j_gen;
	int      j_buf;
	uint16_t j_x, j_y;
	uint32_t j_start, j_len;
	int      cancel;                // set the worker's cancel flag
	int      consume;               // the worker's DONE result was taken: set it IDLE
	int      write;                 // do a HOST_WR with these words (1-4)
	uint16_t wr[4];                 // {PROTO << 8 | version, done, w, h}
} umd_host_act;

void umd_host_init(umd_host_state *s);

// rd: the HOST_RD just made (NULL when none this tick). now: ms, any origin, wraps.
void umd_host_step(umd_host_state *s, uint32_t now, const umd_host_rd *rd,
                   const umd_host_worker *wk, umd_host_act *a);

// the core is not ours (not UMD, or gone): forget the remembered completion, cancel a job
void umd_host_off(umd_host_state *s, const umd_host_worker *wk, umd_host_act *a);

// 16-bit saturation of the image's size for the completion (sub_flip clips at 720 x 480)
static inline uint16_t umd_host_sat16(uint32_t v) { return v > 0xFFFFu ? 0xFFFFu : (uint16_t)v; }

#ifdef __cplusplus
}
#endif
