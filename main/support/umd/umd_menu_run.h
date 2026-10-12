// umd_menu_run.h -- the UMD Main's disc-menu runner (P9 M3 E2, docs/p9.md): everything the glue
// (umd_menu.cpp) does that a bench can hold, as pure C. The disc (the image read through umd_iso,
// PLAYLIST.UMD, the startup RCO), the menu host (umd_menu_host.c), the mount / start / quit state,
// the kept text per disc, and the render-when rule. umd_menu.cpp adds only what no bench can: the
// threads, the SPI, the files, the plane mapping, Main's calls. bench/umd/menu/menu_host_check.c
// drives this against its core model, single-threaded, exactly as the worker does.
//
// THE THREADS (umd_menu.cpp): this runs on the WORKER. Every call that may touch the logic state
// (umd_menu_logic: the queues the engine's plays push into, the levels) is made with the glue's lock
// held -- all of them but umd_mr_draw_frame, which only reads the engine and writes the runner's
// own frame. The poll thread never calls this: it runs umd_menu_step under the lock with the levels
// this published (umd_mr_levels).
//
// THE RULES (beside umd_menu_host.h's):
//   * A MOUNT (Main's image hook) quits the disc that was up (its onExit, its kept text stored),
//     opens the new one -- the image, PLAYLIST.UMD, the disc id, the startup RCO by the language --
//     resets the logic (the seqs adopt again) and ARMS the start; the start fires at the first
//     HOST_RD that umd_mh_ready accepts (the mount landed). An image without UMD_VIDEO, PLAYLIST.UMD
//     or a startup RCO arms nothing: the core plays on its own (traced).
//   * THE CORE IDLE after the start (HOST_RD's state 0: the OSD's Reset unloaded the image; neither
//     hook fires for it) = the disc is gone: quit, levels down, nothing re-armed until a mount. Idle
//     never occurs otherwise once a title plays (a seek shows play, a title's end stop).
//   * P9-6 (Circle the script did not take): quit, STOP, and the OSD opens (the glue's open_osd).
//   * A CORE CHANGE (Main's fpga_load_rbf, umd_mr_shutdown): quit, the kept text stored, before Main
//     re-execs.
//   * The kept text: per disc id, stored at every change the host reports and at every quit; loaded
//     at a start (onContinuePlay when the scripts kept data -- menu.h "RELAUNCH"). On the SD card
//     (RS1, docs/resume.md): a power-off after a quit keeps it; a power cut while the engine runs keeps
//     the text the last store wrote (no onExit runs), and the next launch acts on that.
//   * RS1: a store equal to the disc's last (stored, or loaded at the start) is skipped -- each is an
//     fsync'd write to the SD card, and a quit repeats what onExit's setUserData and the resume point
//     stored just before it.
//   * THE DISC ID is read at every mount that opens the image, Disc Menus Off included (RS2's tracker
//     keys its point by it), and PLAYLIST.UMD with it (the tracker checks a point against it).
//   * RS2, THE TRACKER (docs/resume.md §3): when no engine runs the disc -- Disc Menus Off, a disc
//     without menus, an engine that refused it -- the runner keeps the point itself, in the engine's
//     text (the R line alone, its streams as play()'s ids). It samples {playlist, the shown picture's
//     item, PTS, audio track, subtitles on / track} from every read in play / pause with a picture and
//     not seeking, and stores it (R6) at Pause (play -> pause), at Stop (-> stop), at the core gone idle
//     (the OSD's Reset) and at every quit (a mount, an eject, a core change). A title's end deletes the
//     file and takes no sample until a seek (R5c's STOP after it must not write the end back). At a
//     mount with a point (Disc Menus Off or no menus), once the core's own start has landed
//     (umd_mh_ready), it sends PLAYLIST(point) and the streams; no sample until that landing (LANDED),
//     and a GAVE_UP or a point the disc cannot have (a playlist or item past PLAYLIST.UMD) deletes it.
//     A text whose R line has no point (the engine's, Disc Menus On) is left as it is.
//   * RS4, THE DISC SCREEN (R5, docs/resume.md §6; umd_disc_screen.c the page): while the core is stopped
//     (state 3, not seeking) with a disc image open and no engine running -- Disc Menus Off, no menus, an
//     engine that refused the disc, or a menu disc after P9-6's quit (R5f) -- the runner shows the disc's
//     art under `ui` + `menu` (16:9 presented, the CRT's fit reported, the transport HUD hidden): its own
//     frame buffer (the engine's incremental renderer keeps its own), drawn whole, flipped as the engine's
//     pages are; redrawn when the fit or the Play line changes; hidden at Play. The art (PIC1, ICON0,
//     PARAM.SFO) is read and decoded at its first showing (a side past UMD_DS_MAX_SIDE refused, traced).
//     The Play line says what Play resumes: with no engine, "> Resume H:MM:SS" at the stopped picture (Play
//     releases the freeze there), "> Play" after the title's end; after a menu disc's quit (R5f), the point
//     the engine kept at the quit -- "> Resume" at its place, "> Play" with none (fj#89: not the core's place).
//     R7, STOP ON THE DISC SCREEN FORGETS THE DISC'S PLACE (the user, 2026-10-10: the double stop): the
//     runner grabs Stop while the page is up (the core ignores a Stop in STOP), deletes the disc's kept
//     text whole (a menu disc's user data too: its relaunch is a fresh start, onAutoPlay) and shows
//     "> Play"; with no engine, Play then starts the title from its start (R5c's path).
//     R5c: with no engine, a title's end sends STOP (the disc screen); Play there (the state leaving
//     stop) sends a PLAYLIST to the title's start -- a Stop's Play otherwise releases the freeze at the end.
//     The panel opened over it draws on its own planes over a copy of the page (a full-screen flip).
//     R5f: after a menu disc's P9-6 quit, Play on the disc screen relaunches the disc's engine with its
//     kept text (the start re-armed: onContinuePlay), as choosing the disc on the PSP's XMB does.
//   * SOUNDS (a script's sound.play()): each placed ONCE in the core's PCM region (2^20 64-bit
//     words, 8 MB: docs/p9.md §3.2 item 5), by the engine's key, then a PCM trigger each play; a
//     full region starts over from its bottom (the sounds placed are forgotten); a sound past the
//     whole region is refused, traced (the 8 MB cap, spec_hardening.md); stop() triggers length 0.
//   * RENDER, PIPELINED (M4h, docs/p9.md: the flip's round trip was ~29 ms of a ~66 ms period, the worker idle
//     in it): a frame is DRAWN into the A9's own buffers (the 480 x 272 canvas's damage stretched into r->frame,
//     THE CANVAS below; the panel over it on a copy) when the page is up (`ui`), the engine is dirty (or a frame
//     is owed: `ui` just rose, the CRT fit or the panel's view changed) and no drawn frame awaits its put --
//     WHILE the previous flip is still out; it is PUT when the flip channel is idle (no flip queued or awaiting
//     its echo) and no subtitle decode is in flight (a unit requested just before `ui` rose may still be writing
//     a plane): the buffer the last acknowledged flip moved away from is then free (hps_host.md §3.4); the put
//     whole (720 x 480, MENU_PX_PLANE), then flipped in. A frame owed after a draw (`ui` rose, the fit or the
//     panel changed) drops the drawn one: it is drawn again, never put stale. The disc screen (RS4) draws at its
//     put, as before.
//   * THE CONTROL PANEL (P6d, docs/panel.md §3.3-§3.4; umd_panel.c the decisions): it runs whatever the
//     engine does -- Disc Menus Off, a disc with no menus. Every HOST_RD reaches it; a grabbed press goes
//     to it when its grab mask covers the button, to the engine otherwise. Its actions: a press record
//     (umd_menu_push_press), PLAY (a player command), UMD Menu (the engine's own UMD Menu key), the quit
//     (P9-6's path). Its grab is ORed into the engine's; it raises ui_sub in playback.
//     - Over a disc menu it is drawn into a COPY of the engine's frame (the frame stays the incremental
//       renderer's base) and goes out with it.
//     - In playback it has its own planes, 2 / 3: the page is the subtitle sub_sched shows (read back from
//       its plane: sub_unit / plane_get) under the panel, the flip's rectangle their union
//       (umd_mr_panel_want / _frame / _flip, as the engine's three steps).
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "umd_menu_host.h"
#include "umd_panel.h"
#include "umd_disc_screen.h"
#include "menu/umd_iso.h"
#include "menu/umd_playlist.h"

#ifdef __cplusplus
extern "C" {
#endif

#define UMD_MR_W 720
#define UMD_MR_H 480
// THE CANVAS (M4h, docs/p9.md): the engine draws the scene at the PSP's own screen, 480 x 272, and
// menu_scale stretches what changed onto the 720 x 480 frame through the CRT fit -- 2.65x fewer pixels drawn
// (The Rock's main menu 48.3 -> 33.9 ms a frame on the A9, the stretch included); the PSP's TV out does not
// compose its video at 480 x 272 (measured); the canvas is what the PSP's own screen shows (art at a fractional
// place or scale resampled twice: a little softer than drawn at 720 x 480). Not measured: stretching in fabric instead (plane_reader's SCALE 1:
// ~+100-200 ALM, +12 DSP, a run-time mode beside the subtitles' 1:1) -- the A9's stretch and the copy into
// DDR3 at 480 x 272 (~4 ms, not ~10) saved; a candidate when the area allows (p9.md M4h)
#define UMD_MR_CW 480
#define UMD_MR_CH 272
// THE TICK (M4h): the engine advances at most every UMD_MR_TICK_MS (its designed step). The worker wakes at every
// poll's message -- every 2 ms while a flip is out -- and ticked each time: 222 ticks a second at ~1.75 ms on The
// Rock's menu, 39 % of the worker (measured, docs/p9.md M4h); the reads and events are still fed at every wake
#define UMD_MR_TICK_MS 10
#define UMD_MR_PCM_WORDS (1u << 20)            // the core's PCM region: 8 MB (umd/pcm_shot.sv)

typedef struct {
	void *ud;
	// the image's PNG / JPEG into RGBA (malloc'd; menu.h's decode_image)
	int  (*decode_image)(void *ud, int format, const uint8_t *data, size_t len, int *w, int *h, uint8_t **rgba);
	// the kept text of a disc (malloc'd, NULL none) / store it (an empty text removes it): 0 written,
	// -1 not (RS1: the SD card full or read-only -- counted and traced, retried at the next store)
	char *(*kept_load)(void *ud, const char *disc_id, size_t *len);
	int  (*kept_store)(void *ud, const char *disc_id, const char *text, size_t len);
	// a rendered frame (UMD_MR_W x UMD_MR_H, MENU_PX_PLANE, stride UMD_MR_W * 4) into plane `buf`
	void (*plane_put)(void *ud, int buf, const uint8_t *frame);
	// a sound's 48 kHz 16-bit frames into the PCM region at 64-bit word `word` (umd/pcm_shot.sv: mono
	// four samples, stereo two frames a word, little-endian from bit 0; the last word zero-padded)
	void (*pcm_put)(void *ud, uint32_t word, const int16_t *pcm, uint32_t samples);
	// P9-6: open Main's OSD (the glue does it on the poll thread)
	void (*open_osd)(void *ud);
	// the trace, NULL off (a menu traces thousands of lines a second)
	void (*trace)(void *ud, const char *line);
	// P6d, the panel over a subtitle: the plane (0 / 1) and rectangle the subtitle unit `seq` was decoded
	// into (0; -1 not known: drawn without it); a rectangle of that plane read back into `frame` (720 x 480
	// x 4, the plane's layout) at the same place; a rectangle of `frame` into the panel's plane 2 / 3
	int  (*sub_unit)(void *ud, uint8_t seq, int *buf, int *x, int *y, int *w, int *h);
	void (*plane_get)(void *ud, int buf, int x, int y, int w, int h, uint8_t *frame);
	void (*plane_put_rect)(void *ud, int buf, const uint8_t *frame, int x, int y, int w, int h);
} umd_mr_services;

// THE PROFILE (M4h, docs/p9.md): running sums of a step's wall time and of the calling thread's CPU time (us)
// -- a wall time well above the CPU time is a thread waiting for a core, not slow code; the glue adds the
// whole frame and the plane put (umd_menu.cpp), the benches print them
typedef struct { uint64_t n, wall_us, cpu_us; } umd_mr_acc;
typedef struct { uint64_t wall_us, cpu_us; } umd_mr_t0;
umd_mr_t0 umd_mr_clock(void);
void      umd_mr_acc_add(umd_mr_acc *a, umd_mr_t0 since);

typedef struct {
	umd_mr_services sv;
	umd_menu_state *L;
	umd_menu_host   H;
	umd_mh_services hs;
	// the disc
	umd_iso         iso;
	umd_playlists   pl;
	int             have_disc, have_pl;
	char            disc_id[64];
	char            start[16];
	const uint8_t  *rco;
	uint8_t        *rco_buf;
	// the state
	int             armed;                 // a mount: the start awaits umd_mh_ready
	int             menus_off;             // the OSD's Disc Menus Off (M3b): a mount plays the disc on its own
	int             started;               // the engine runs (or ran) for this mount
	int             quit_osd;              // a P9-6 quit asked for (handled at the next tick)
	uint32_t        now;
	umd_menu_rd     rd;
	int             have_rd;
	// the render
	uint8_t        *canvas;                // the engine's incremental target (UMD_MR_CW x UMD_MR_CH, M4h)
	umd_mr_acc      p_draw, p_stretch;     // THE PROFILE: the engine's draw into the canvas, the stretch onto the frame
	uint32_t        tick_acc;              // THE TICK: ms not yet given to the engine
	int             staged;                // THE PIPELINE: a frame drawn, not yet put (its pixels: staged_out)
	const uint8_t  *staged_out;
	uint8_t        *frame;
	int             front;                 // the plane buffer shown (-1 none)
	int             flipping;              // a flip pushed, its buffer (-1 none)
	int             ui_was;                // the last levels' ui (a rise forces a frame)
	int             need_frame;
	int             fit_was;               // the CRT fit the last frame was drawn with (umd_mh_fit)
	int             inc_fit;               // the fit r->frame was last stretched with whole (umd_mr_draw_inc)
	uint32_t        n_frames, n_quits, n_starts;
	// the control panel (P6d)
	umd_panel       P;
	uint8_t        *pframe;                // its page (playback), or the engine's frame with it on (a disc menu)
	int             pfront, pflipping;     // the panel plane shown (2 / 3, -1 none); a flip of one in flight
	uint32_t        pview_was;             // what the last page showed (umd_panel_view), 0 none
	int             psub_was;              // ... the subtitle under it: -1 none, else its seq
	int             pneed;                 // a page owed (ui_sub just rose)
	uint32_t        fview_was;             // over a disc menu: the view the last frame carried (0 none)
	int             uis_was;               // the last levels' ui_sub
	int             prx, pry, prw, prh;    // the page drawn: its rectangle, view and subtitle (for its flip)
	uint32_t        pv_drawn;
	int             ps_drawn;
	int             pz_was, pz_drawn;      // fj#71: Zoom in force when the page was flipped / drawn (the subtitle's place)
	uint32_t        n_panel_pages, n_panel_acts;
	// the sounds placed in the PCM region
	struct { uint32_t key, word, frames; uint8_t stereo; } snd[256];
	int             n_snd;
	uint32_t        pcm_top;               // the next free word
	uint32_t        n_sounds, n_placed, n_refused;
	// RS1: the disc's text as the card holds it (the last stored or loaded; NULL unknown)
	char           *kept_last;
	size_t          kept_last_n;
	uint32_t        n_kept_writes, n_kept_same, n_kept_fail;   // stores written / skipped as repeats / refused
	// RS2, the tracker: the point when no engine runs (umd_menu_run.h THE TRACKER)
	int             tr_on;                 // the tracker owns this mount's point
	int             tr_have;               // a sample taken
	uint16_t        tr_pl;
	uint32_t        tr_item;
	uint64_t        tr_pts;
	uint8_t         tr_audio, tr_sub, tr_sub_on;
	int             tr_state_was;          // the last read's state (the Pause / Stop edges), -1 none
	int             tr_wait_seek;          // a title ended: no sample until a seek
	int             tr_go;                 // a point to resume once the mount's start lands
	int             tr_landing;            // its PLAYLIST sent, the landing awaited
	uint16_t        tr_go_pl;
	uint32_t        tr_go_item;
	uint64_t        tr_go_pts;
	int             tr_go_audio, tr_go_sub;     // -1 none; tr_go_sub the SUB_SET item (on | track)
	uint32_t        n_tr_saves, n_tr_resumes, n_tr_dropped;
	// RS4, the disc screen (umd_menu_run.h THE DISC SCREEN)
	char            image_name[256];       // the mounted image's path (the glue's, before umd_mr_mount)
	int             ds_up;                 // shown (the levels' ui + menu)
	int             ds_loaded;             // the art read and decoded (at its first showing)
	int             ds_ended;              // the title ended (1) or R7 forgot its place (2): "> Play", Play restarts it
	uint8_t        *ds_pic1, *ds_icon0;    // straight RGBA (NULL none)
	int             ds_pw, ds_ph, ds_iw, ds_ih;
	char            ds_title[160];
	uint8_t        *ds_frame;              // the page (UMD_DS_W x UMD_DS_H x 4, the plane's layout)
	char            ds_key[64];            // what the shown page was drawn with (fit + the Play line)
	char            ds_want_key[64];
	int             ds_state_was;          // the last read's state (Play after the end), -1 none
	int             ds_relaunch;           // R5f: a menu disc quit by P9-6 -- Play relaunches its engine
	int             ds_pt_have;            // fj#89: the engine's point kept at that quit (the Play line's)
	uint16_t        ds_pt_pl;
	uint32_t        ds_pt_item;
	uint64_t        ds_pt_pts;
	uint32_t        n_ds_shows, n_ds_frames, n_ds_refused, n_ds_forgets;
} umd_menu_run;

void umd_mr_init(umd_menu_run *r, const umd_mr_services *sv, umd_menu_state *L);
void umd_mr_free(umd_menu_run *r);
// a mount (ok 0: an eject): read(ud, off, buf, n) the image of `size` bytes; lang the Menu Language's
// two letters (umd_mh_lang_code, NULL English). 0 armed, -1 nothing to run (the core plays alone)
int  umd_mr_mount(umd_menu_run *r, int ok, size_t (*read)(void *ud, uint64_t off, void *buf, size_t n),
                  void *read_ud, uint64_t size, const char *lang, uint32_t now);
// one HOST_RD and the events umd_menu_step returned with it, in order (never two reads merged)
void umd_mr_feed(umd_menu_run *r, const umd_menu_rd *rd, const umd_menu_event *ev, int nev);
// the clock: the engine's tick, the start, the quits
void umd_mr_tick(umd_menu_run *r, uint32_t now);
// the levels to publish for the poll thread
void umd_mr_levels(umd_menu_run *r, umd_menu_levels *lv);
// RENDER, PIPELINED (RENDER above): _draw_want says a frame should be drawn now (the flip may be out), _draw
// draws it into the A9's buffers; _put_want says which plane buffer to put the drawn frame into (-1 none: the
// flip still out, a subtitle decode in flight, nothing drawn), _put hands it to plane_put; _flip queues the flip
int  umd_mr_draw_want(umd_menu_run *r);
void umd_mr_draw_frame(umd_menu_run *r);
int  umd_mr_put_want(umd_menu_run *r, int sub_busy);
void umd_mr_put_frame(umd_menu_run *r, int buf);
// the frame the engine's state draws, through the menu's CRT fit (analog.md S7), into px (720 x 480 x 4,
// the plane's layout): the scene at 480 x 272, stretched (THE CANVAS); returns the fit (umd_mh_fit).
// umd_mr_draw_frame's drawing
int  umd_mr_draw(umd_menu_run *r, uint8_t *px);       // whole (a reference: its own canvas)
int  umd_mr_draw_inc(umd_menu_run *r, uint8_t *px);   // incremental: r->canvas, px the previous frame (r->frame)
void umd_mr_render_flip(umd_menu_run *r, int buf);
// THE PANEL'S OWN PAGE (playback, ui_sub), the same three steps: _want (locked) says which of its planes to
// draw (2 / 3, -1 none), _frame (unlocked) draws it, _flip (locked) queues the flip
int  umd_mr_panel_want(umd_menu_run *r);
void umd_mr_panel_frame(umd_menu_run *r, int buf);
void umd_mr_panel_flip(umd_menu_run *r, int buf);
// the trace on or off (NULL), the host's and the engine's with it
void umd_mr_set_trace(umd_menu_run *r, void (*trace)(void *ud, const char *line));
// a core change: quit and store, now
void umd_mr_shutdown(umd_menu_run *r);

#ifdef __cplusplus
}
#endif
