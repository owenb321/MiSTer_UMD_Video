// umd_menu_host.h -- the UMD Main's menu host (P9 M3, docs/p9.md): the engine (menu/menu.c) on one
// side, the core's P9 rows (umd_menu_logic: the intents, the events, the levels) on the other. Pure
// C, no Main dependency: umd_menu.cpp runs it on the menu worker; bench/umd/menu/menu_host_check.c
// drives it with the real engine on the captured discs against the core model.
//
// THE RULES (each one a reason a script, the captures or the core relies on):
//   * NUMBERING: a script's playlist NUMBER is PLAYLIST.UMD's index + 1 (docs/p9.md M1b rule 1);
//     the core's NAV_PLAY and HOST_RD's PLAYLIST word are the index. This file is the one boundary:
//     play() / resume() subtract, getPlayerStatus / getResumeInfo / onPlayListEnd add (Austin Powers
//     2 compares playListNumber with 8 to show its language page).
//   * THE MOUNT: the engine starts when the core's mount has LANDED (umd_mh_ready: a title playing,
//     its picture shown, no seek in flight). Started at the first non-idle state, the script's first
//     play() raced the mount's own seek: refused as busy, retried ~1 s, given up on a slow mount (an
//     image on a network share) -- the startup chain stalled for good (found by menu_host_check). The
//     feature's first frames show meanwhile (the core's own start, a studio logo or black). The
//     disc's RCO and PLAYLIST.UMD are loaded FIRST: a disc the engine refuses (no RCO, a refused
//     script) leaves the core alone -- no STOP, every level 0, stock playback with a message
//     (docs/p9.md S5). A disc it takes: STOP with `menu` up (the stop screen black, not the feature
//     the core auto-plays at a mount), then menu_start / menu_continue.
//   * THE LEVELS are DERIVED, never set by the engine (three states):
//       MENU    a page is open, or the last play() was a menu's background (menuMode 1), or nothing
//               plays: grab every button the menus use, `menu` up (the HUD hidden), `ui` while a
//               page is open (the plane is the host's);
//       CONTENT the last play() was content (menuMode 0) and no page is open: grab Square (the
//               script's onMenu, the maintainer's capture) and Circle (the PSP's system stop, below),
//               the rest the transport's (Triangle the HUD -- the PSP's own panel), `menu` and `ui`
//               down;
//       NONE    the engine refused or stopped: nothing grabbed, every level down.
//   * KEYS: a KEY event is a PRESS mask in the joystick's bit order (the D-pad bits 0-3, then the J1
//     list of CONF_STR from bit 4); each set bit is one key to the engine, in this file's fixed order.
//     A key the engine does not take (menu_key 0) is the SYSTEM's: Circle quits the disc (P9-6:
//     the glue runs onExit, keeps the data, stops, opens the OSD) wherever the script does not take
//     it -- the top page, a menu's clip, a logo, the film. The PSP's own Circle outside a sub-page
//     is its system stop, back to the XMB: the three captures (docs/p9.md S2), and the maintainer's
//     test during Akira's warning (2026-10-02). Start is play / pause (the PSP's, measured the same
//     day: a menu's clip too). The rest are dropped: L / R ("not available here" on the PSP),
//     Triangle (the PSP's system panel: menu, volume, display, help, stop -- the MiSTer has its
//     OSD, D10 dropped a panel), Select (the PSP's XMB overlay over a paused picture -- the OSD's
//     job here; in CONTENT Select stays P6b6's Audio button).
//   * THE RESUME POINT is the host's (docs/p9.md M1b rule 7): the place of a content play()
//     (menuMode 0) when a stop or another play() interrupts it -- its playlist, HOST_RD's shown key
//     (item, PTS) and its streams; and the quit's (a relaunch resumes the film: Akira's capture),
//     taken BEFORE the script's onExit (fj#89: Aliens' and The Animatrix's onExit stop the film).
//     resume() replays it through PLAYLIST at that key (the core's own
//     Stop / Play resume does not survive a menu's play in between); the point stays kept until that
//     play lands (fj#88, `resume_used`). A playlist that ends leaves none.
//   * STREAMS in play(): audio 0xBD00 + n -> AUDIO_SET n (player_ctl refuses the track playing:
//     a BAD the logic counts, nothing more);
//     subtitles 0xBD80 + n with their flag -> SUB_SET; -1 leaves a stream as it is. Sent after the
//     PLAYLIST (umd_menu_logic holds the channel until it lands).
//   * THE VIDEO WINDOW: menu_video_window in the scene's 854 x 480 (centre, size) mapped onto the
//     720 x 480 raster, the source a 720 x 480 picture (Q10.16 steps); the whole screen means off.
//     Under a menu (MENU) the core presents 16:9, so a 4:3 picture (HOST_RD's aspect bits) is fitted
//     into the window at its shape, centred: the whole screen gives 540 x 480 at x 90, as the PSP
//     pillarboxes it.
#pragma once

#include <stdint.h>
#include <stddef.h>

#include "menu/menu.h"
#include "menu/umd_playlist.h"
#include "umd_menu_logic.h"

#ifdef __cplusplus
extern "C" {
#endif

// the joystick bits (umd/emu.sv CONF_STR's J1 list from bit 4; the PSP buttons by P6b6's defaults,
// docs/transport.md "As built in P6b6"). check_emu_wiring.py pins the J1 order these follow.
enum {
	UMD_JB_RIGHT = 0, UMD_JB_LEFT = 1, UMD_JB_DOWN = 2, UMD_JB_UP = 3,
	UMD_JB_PLAYPAUSE = 4,   // Start
	UMD_JB_PAUSE = 5,       // Cross (x)
	UMD_JB_STOP = 6,        // Circle (o)
	UMD_JB_PREV = 7,        // L
	UMD_JB_NEXT = 8,        // R
	UMD_JB_AUDIO = 9,       // Select
	UMD_JB_DISPLAY = 10,    // Triangle
	UMD_JB_UMDMENU = 11,    // Square
};
#define UMD_MH_GRAB_MENU    0x0FFFu                    // every bit above
#define UMD_MH_GRAB_CONTENT ((1u << UMD_JB_UMDMENU) | (1u << UMD_JB_STOP))

enum { UMD_MH_NONE, UMD_MH_MENU, UMD_MH_CONTENT };

typedef struct {
	// the glue's services (the Main: the mounted image, the trace, the images, the kept file)
	void *ud;
	int  (*load_rco)(void *ud, const char *name, const uint8_t **buf, size_t *len);
	int  (*decode_image)(void *ud, int format, const uint8_t *data, size_t len, int *w, int *h, uint8_t **rgba);
	void (*trace)(void *ud, const char *line);
	void (*kept_changed)(void *ud);        // setUserData ran or the resume point moved: write the file
	void (*quit)(void *ud);                // P9-6: a Circle the script did not take (the glue runs umd_mh_quit)
	void (*sound)(void *ud, uint32_t key, const int16_t *pcm, uint32_t frames, int nch);   // menu.h's
} umd_mh_services;

typedef struct {
	int      have;
	uint16_t pl;                           // the INDEX
	uint32_t item;
	uint64_t pts;
	int      video, audio, aflag, sub, sflag;
} umd_mh_resume;

typedef struct {
	menu            *m;
	umd_mh_services  sv;
	umd_menu_state  *L;                    // the poll side's logic (the glue locks around both)
	const umd_playlists *pl;
	umd_menu_rd      rd;                   // the last HOST_RD
	umd_menu_rd      rd_play;              // fj#88: the last read in play / pause (a stop clears have_play): the
	int              have_play;            // OSD's Reset quit sees the idle read in `rd`, the film's place here
	int              have_rd;
	int              mode;                 // UMD_MH_*
	int              content;              // the last play() was content (menuMode 0)
	int              mute;                 // the last play() / resume() had its audio off (argument 6 = 0)
	int              stopped;              // the script's stop() since its last play() / resume()
	int              continued;            // the start was a continue (kept user data: onContinuePlay)
	int              pres;                 // the menu PRESENTED (16:9, fitted to a CRT): umd_mh_levels
	uint16_t         chapter;              // the chapter last posted to the script (getPlayerStatus answers it)
	int              playing_pl;           // the index the last play() asked (-1 none)
	int              pl_pending;           // fj#65: that play() (or a resume()) not yet landed: getPlayerStatus
	uint16_t         asked_chapter;        // reports it and this chapter, not the core's old playlist
	uint32_t         play_at;              // fj#66: the engine's clock at the last play() (a play asked in
	                                       // the same instant as a changeResource is kept)
	int              cur_menu_mode;        // the last play() was a menu's (menuMode 1): fj#66 stops it at a changeResource
	umd_mh_resume    playing;              // the content play() in force (to become the resume point)
	umd_mh_resume    resume;
	int              resume_used;          // fj#88: resume() asked for it, its landing not yet seen -- kept
	                                       // (written R 1) and dropped at the landing, never at the ask
	// NAMED MARKS (movieplayer.onMark): armed at the play's landing; the place last passed; a seek
	// after the landing (the transport's chapter skip) moves it without firing what it jumped over
	int              mk_on, mk_fresh, mk_seek;
	uint32_t         mk_item;
	uint64_t         mk_pts;
	int              quit_req;
	int              detached;             // a quit after which the core no longer holds this disc: the
	                                       // script's player commands are traced and dropped (umd_mh_quit)
	uint32_t         n_refused_play, n_sound_skipped;
	uint32_t         n_stale_chapter;      // fj#76: CHAPTERs read before the latest play() was queued, dropped
	uint32_t         n_held;               // fj#65: play()s with pauseMode 1, held on their first picture
	uint32_t         n_res_stop;           // fj#66: menu playbacks the system stopped at a changeResource
	char             disc[64];
} umd_menu_host;

void umd_mh_init(umd_menu_host *h, const umd_mh_services *sv, umd_menu_state *L, const umd_playlists *pl);
// the startup RCO among RESOURCE/'s entries ("ES100000.RCO", ...): <lang>100000 (two letters, the
// system's language), else EN100000, else the first *100000.RCO by name -- 4 of 84 discs have no
// EN100000 (Iron Man: ES only; Ghost in the Shell 2.0, The Animatrix, Tom & Jerry: JA only). out
// gets the name without ".RCO"; -1: no startup RCO (the disc has no menus: it plays on its own)
int  umd_mh_pick_start(const char *const *names, int n, const char *lang, char out[16]);
// the OSD's Menu Language (CONF_STR O[14:11], umd/emu.sv) as a startup RCO's two letters: 0 English,
// 1 French, 2 Spanish, 3 German, 4 Italian, 5 Dutch, 6 Japanese; NULL past the list (English then)
const char *umd_mh_lang_code(unsigned option);
// the mount has landed: the moment to call umd_mh_start
int  umd_mh_ready(const umd_menu_rd *rd);
void umd_mh_free(umd_menu_host *h);
// the core reported a title: load `name` (e.g. "EN100000"), STOP behind `menu`, then start -- or
// continue with `kept` (menu_save's text + the resume line, NULL none). 0 the engine runs, -1 refused
// (mode NONE: the core plays on its own). now_ms: the glue's clock (the engine's timers and trace)
int  umd_mh_start(umd_menu_host *h, const char *name, const char *kept, size_t kept_len, uint32_t now_ms);
// each HOST_RD
void umd_mh_rd(umd_menu_host *h, const umd_menu_rd *rd);
// the events umd_menu_step returned, in order
void umd_mh_events(umd_menu_host *h, const umd_menu_event *ev, int n);
// advance the engine's clock
void umd_mh_tick(umd_menu_host *h, uint32_t ms);
// the levels now
// a menu's fit to the raster (analog.md S7): 0 Fit 1 Letterbox 2 Crop; the target rectangle on the
// 720 x 480 raster and the scene's view drawn into it (menu_render_view's)
int  umd_mh_fit(const umd_menu_host *h, float *tx, float *ty, float *tw, float *th, float *vx, float *vy, float *vw, float *vh);
void umd_mh_levels(umd_menu_host *h, umd_menu_levels *lv);
// quit the disc (P9-6, a new image, a core change): onExit, then the data to keep (malloc'd text).
// detached: the core no longer holds this disc (a new image is already mounted, the OSD's Reset, a core
// change) -- onExit's player commands are DROPPED, never sent: the next disc would take them (fj#70:
// Interstella 5555's onExit stop() stopped The Matrix loaded after it, 3 of 3 on the rig). The reads
// (getPlayerStatus, getResumeInfo) still answer from the last HOST_RD and the resume point. P9-6's own
// quit (Circle at the top) is not detached: the core still holds the disc, and stops it anyway
char *umd_mh_quit(umd_menu_host *h, size_t *len, int detached);
// the kept data now (malloc'd text; NULL none): the line "R <resume point>\n" FIRST, then menu_save's text
char *umd_mh_kept(umd_menu_host *h, size_t *len);

#ifdef __cplusplus
}
#endif
