// umd_menu_logic.h -- the UMD Main's P9 host-row decisions (docs/p9.md M3, docs/hps_host.md §2
// "P9's rows, as built"), as pure functions: no Main dependency, no I/O. umd_menu.cpp does the SPI,
// the worker thread and the engine; bench/umd/menu/host_menu_check.c drives this on the PC against a
// C model of umd/umd_host.sv's P9 side (the held records, the echoes, the event FIFO).
//
// THE HAND-OFF (two threads, as umd_host.cpp's subtitle worker):
//   * the WORKER (CPU 0) owns the engine (menu.c) and the renderer. What it asks of the core is an
//     INTENT -- a player command, a plane flip, a PCM trigger -- pushed onto this state's queues
//     (the glue holds a lock around umd_menu_push and umd_menu_step), and LEVELS it sets in place
//     (the grab mask, ui, menu, the video window).
//   * the POLL thread (Main's, CPU 1) runs umd_menu_step at every HOST_RD: it sends the queued
//     intents one at a time per channel, reads the core's events, and returns EVENTS for the worker
//     (a key, a chapter, a playlist's end) in order.
//   * umd_host_away (another core, or none): umd_menu_init again; the queues and the events go.
//
// THE RULES (each one a reason the fabric's side, umd/umd_host.sv, relies on):
//   * ONCE-ONLY: a player command, a flip and a PCM trigger each carry a seq; the core takes a record
//     at its last word when the seq differs from the last it took, HOLDS it until its consumer takes
//     it, and only then echoes the seq. A new seq sent while one is held is NOT seen -- so each
//     channel sends its next record only after the echo of the last. At the first HOST_RD the seqs
//     are ADOPTED from the echoes (a restarted Main must not resend what the core already took).
//   * EVENTS are read by count: HOST_RD gives the write count, the core's read count and the first
//     four unread; the host consumes in order and writes back the count it consumed up to (EV_RP).
//     Entries the host consumed but the core has not yet popped are skipped by position, so a
//     repeated HOST_RD never delivers an event twice; a count gap past the FIFO's 8 resyncs, counted.
//   * PLAYLIST (player_ctl code 13) refused as BAD means busy (a seek or gesture in flight): the
//     glue checks the playlist against its own PLAYLIST.UMD before pushing, so a BAD carries no
//     other meaning. It is resent after RETRY_MS, at most RETRY_MAX times, then given up (an event).
//     A PLAYLIST HOLDS the command channel from its send to its landing (or its giving up): the
//     next command waits, so a retry can never land after a newer command (a script's play() then
//     stop() stays in that order) -- found by the bench.
//   * THE START CHAPTER: the scripts expect onChapter for the chapter a play STARTS in (docs/p9.md
//     M1b rule 3); player_ctl posts CHAPTER only when the rank CHANGES. So after a PLAYLIST is taken
//     the logic waits for its landing (HOST_RD: that playlist, a picture shown, not seeking) and
//     posts the shown chapter itself; a CHAPTER event then passes only when it differs from the last
//     one posted. The landing must FOLLOW a seek seen after the take: replaying the playlist that is
//     playing (Family Guy loops its menu's playlist 9) otherwise "lands" on the old picture before
//     the seek shows -- found by the bench. While a PLAYLIST is in flight -- or still QUEUED: the events are read before the queue
//     is sent -- CHAPTER and TITLE_END events are the old playlist's: dropped.
//   * P6d (docs/panel.md F1): a PRESS channel -- the control panel's item sent as its button's press
//     mask (HOST_WR's press record), once-only by seq like the others; the core takes it at once and
//     echoes it (press_ack), so the next follows the echo. And the level ui_sub (the panel's mode).
//   * THE READ RATE: fast while anything is queued, a record awaits its echo, a landing is awaited,
//     or a button is grabbed (a menu answers keys); else none of its own (the subtitle logic reads).
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UMD_MENU_QLEN       64      // per channel; a full queue refuses the push (counted)
#define UMD_MENU_RETRY_MS   40
#define UMD_MENU_RETRY_MAX  25      // ~1 s of a seek in flight
#define UMD_MENU_EVQ        16      // events out per step (the core shows at most 4 a read)
#define UMD_MENU_READ_KEYS_MS 10    // the read rate when only the grabbed buttons are awaited: the poll
                                    // thread's cost (the rig: 47 % of a CPU at 2 ms), a key's latency
                                    // still under a 60 Hz frame (the PSP polls its pad per frame)

// player_ctl's codes (umd/player_ctl.sv)
enum { UMD_PC_PLAYPAUSE = 1, UMD_PC_PAUSE = 2, UMD_PC_PLAY = 3, UMD_PC_STOP = 4, UMD_PC_SEEK = 7,
       UMD_PC_AUDIO_SET = 9, UMD_PC_PLAYL = 13, UMD_PC_SUB_SET = 14 };
enum { UMD_EV_CHAPTER = 1, UMD_EV_TITLE_END = 3, UMD_EV_BAD = 8, UMD_EV_KEY = 15 };

typedef struct {
	uint8_t  code, arg;             // player_ctl's code and its 4-bit arg
	uint16_t pl;                    // PLAYLIST: the playlist INDEX (the script's number - 1)
	uint32_t item;                  // SEEK / PLAYLIST: the item; SUB_SET: [5] on [4:0] track
	uint64_t pts;                   // SEEK / PLAYLIST: the PTS (48 bits sent)
	uint16_t chapter;               // PLAYLIST: the chapter its landing posts (not sent; 0: the core's word)
} umd_menu_pcmd;

typedef struct {
	uint8_t  buf, shown;            // the plane, shown
	uint16_t x, y, w, h;            // on the screen
} umd_menu_flip;

typedef struct {
	uint32_t start;                 // the first 64-bit word in the PCM region (24 bits)
	uint32_t len;                   // sample frames (24 bits; 0 stops)
	uint8_t  stereo;
} umd_menu_pcm;

typedef struct {
	int      on;
	uint16_t x, y, w, h;            // the rectangle on the raster
	uint32_t hs, vs, x0, y0;        // Q10.16 (26 bits)
} umd_menu_win;

typedef struct {
	uint16_t grab;                  // the buttons the engine takes (joystick bit order)
	int      ui, menu;
	int      ui_sub;                // P6d: the control panel's mode (the plane the host's, the subtitles running)
	int      mute;                  // the film's audio off: play()'s argument 6 (audio on) was 0
	umd_menu_win win;
} umd_menu_levels;

// what the worker hears, in order
enum { UMD_ME_KEY = 1, UMD_ME_CHAPTER, UMD_ME_PL_END, UMD_ME_LANDED, UMD_ME_GAVE_UP, UMD_ME_CMD_TAKEN };
typedef struct {
	int      kind;
	uint32_t data;                  // KEY: the press mask; CHAPTER: the chapter (from 1);
	                                // LANDED / GAVE_UP: the playlist index; CMD_TAKEN: player_ctl's code
	uint32_t gen;                   // the state's play_gen when the step read it (fj#76: umd_mh_events
	                                // drops a CHAPTER read before the latest play() was queued)
} umd_menu_event;

// the P9 rows of a HOST_RD, decoded (umd_host_proto.h's words)
typedef struct {
	int      magic, proto_ok, nwords_ok;     // a core with the P9 rows (NWORDS >= 38)
	int      host_ok;                        // the core sees the heartbeat
	int      state, seeking, shown;          // player_ctl: 0 idle 1 play 2 pause 3 stop; a picture shown
	int      sub_on, sub_track, audio_track; // the subtitles (on, 0x80 + n's n), the audio track (n)
	int      pic_known, pic_wide;            // the shown picture's aspect (its VUI): 16:9, else 4:3
	int      menu_aa;                        // a menu's fit to a 4:3 CRT: 0 Fit 1 Letterbox 2 Crop (analog.md S7)
	int      zoom;                           // fj#71: Zoom in force -- only raster lines 60 .. 419 shown (docs/zoom.md)
	uint8_t  cmd_ack, flip_ack, pcm_ack, win_ack;
	int      goto_open, sub_any, ui_sub;     // P6d: Go To's editor up, the title has subtitles, ui_sub in force
	uint8_t  press_ack;                      // P6d: the last press record taken
	int      sub_vis;                        // P6d: the subtitle plane's front shown (HOST_RD `shown`)
	uint8_t  sub_seq;                        // ... the seq of the unit in it (what sub_sched shows)
	int      sub_rect_v;                     // A12 SD2: the core reports that unit's plane and rectangle
	int      sub_buf, sub_x, sub_y, sub_w, sub_h;   // ... (the fabric decodes it: no host record)
	uint16_t chapter, n_chapters, playlist;
	uint32_t n_items, key_item;
	uint64_t pts;
	uint8_t  ev_w, ev_lost, ev_r;
	uint16_t ev_code[4], ev_data[4];
} umd_menu_rd;

void umd_menu_decode(const uint16_t *w, int nwords, umd_menu_rd *rd);

typedef struct {
	// the channels: a queue, the record on the wire, its seq, waiting for its echo
	umd_menu_pcmd q_cmd[UMD_MENU_QLEN];  int n_cmd;
	umd_menu_flip q_flip[UMD_MENU_QLEN]; int n_flip;
	umd_menu_pcm  q_pcm[UMD_MENU_QLEN];  int n_pcm;
	uint16_t      q_press[UMD_MENU_QLEN]; int n_press;   // P6d
	umd_menu_pcmd cur_cmd;  uint8_t cmd_seq;  int cmd_busy;
	umd_menu_flip cur_flip; uint8_t flip_seq; int flip_busy;
	umd_menu_pcm  cur_pcm;  uint8_t pcm_seq;  int pcm_busy;
	uint16_t      cur_press; uint8_t press_seq; int press_busy;   // P6d
	int      adopted;                // the seqs taken from the echoes
	// the levels on the wire
	umd_menu_levels lv;
	uint8_t  win_seq;
	// events
	uint8_t  rp;                     // the count the host consumed up to
	// PLAYLIST: the last one sent, its retries; the landing awaited
	umd_menu_pcmd last_pl;
	int      have_last_pl, retries;
	int      retry_due;              // a resend waiting for retry_at
	uint32_t retry_at;
	int      land_wait;              // a PLAYLIST taken, its landing not yet seen
	int      seen_seek;              // ... and its seek seen since the take
	uint16_t land_pl;
	int      inflight;               // a PLAYLIST sent, not yet answered (landed or BAD)
	uint16_t last_chapter;           // the last chapter posted (0 none)
	// THE PLAY GENERATION (fj#76): bumped at every PLAYLIST pushed (the worker's), stamped on every event
	// the step posts. The poll thread classifies an event against the queue as it reads it (a CHAPTER
	// with a PLAYLIST ahead is the old playlist's: dropped); the worker delivers it later, from the
	// glue's mailbox -- and a play() queued in between (the start's RCO load and onContinuePlay run
	// while the poll steps on) makes it stale after it passed. Kept across umd_menu_init (monotonic)
	uint32_t play_gen;
	// counters
	uint32_t n_presses;              // P6d
	uint32_t n_cmds, n_flips, n_pcms, n_events, n_bad, n_retries, n_gave_up, n_full, n_resync, n_dropped;
	int      keys_only;              // want_fast for the grabbed buttons alone (no record, no landing)
	// the glue's lock (umd_menu_set_lock), kept across umd_menu_init
	void   (*lk)(void *ud, int on);
	void    *lk_ud;
} umd_menu_state;

// a fresh state (the lock set by umd_menu_set_lock kept): zero the struct once before the first call
void umd_menu_init(umd_menu_state *s);
// THE THREADS (umd_menu.cpp): the worker pushes intents and reads the flip channel; the poll thread
// steps. Each call below takes the lock for its own body when one is set (NULL: the benches).
void umd_menu_set_lock(umd_menu_state *s, void (*lk)(void *ud, int on), void *ud);
// no flip queued or awaiting its echo (the render's rule)
int  umd_menu_flip_idle(umd_menu_state *s);
// queue an intent; 0 ok, -1 the queue is full (counted)
int  umd_menu_push_cmd(umd_menu_state *s, const umd_menu_pcmd *c);
int  umd_menu_push_flip(umd_menu_state *s, const umd_menu_flip *f);
int  umd_menu_push_pcm(umd_menu_state *s, const umd_menu_pcm *p);
int  umd_menu_push_press(umd_menu_state *s, uint16_t mask);      // P6d: buttons pressed (joystick bit order)

// one step at a HOST_RD (rd NULL: none this tick). lv: the levels now. Out: the events for the
// worker (*nev of them, at most UMD_MENU_EVQ), HOST_WR words 5..39 written into wr (the caller owns
// words 1-4: the heartbeat and the subtitle completion), *want_write when they changed, *want_fast
// when the logic needs the fast read rate.
void umd_menu_step(umd_menu_state *s, uint32_t now, const umd_menu_rd *rd, const umd_menu_levels *lv,
                   umd_menu_event *ev, int *nev, uint16_t *wr, int *want_write, int *want_fast);

#ifdef __cplusplus
}
#endif
