// menu.h -- the disc menu engine (P9, docs/p9.md S3.3): an RCO's scene and script, driven by time,
// keys and the player's events. Portable C: the PC (bench/umd/menu/menu_run.c, a model player)
// and the UMD Main (M3, the core's host rows).
//
// The host is the player: the engine asks it to play / stop / resume and for its status, and to
// load another RCO (controller.changeResource); the host tells the engine the time (menu_tick),
// the keys and the player's events. Every native call and every callback is traced (the M1b gate:
// a disc's startup chain runs to its main menu with no refused opcode, no undefined method, no
// bound hit).
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct menu menu;

enum { MENU_KEY_UP, MENU_KEY_DOWN, MENU_KEY_LEFT, MENU_KEY_RIGHT, MENU_KEY_CROSS, MENU_KEY_CIRCLE,
       MENU_KEY_TRIANGLE, MENU_KEY_SQUARE, MENU_KEY_START, MENU_KEY_SELECT, MENU_KEY_L, MENU_KEY_R,
       MENU_NKEYS };

// movieplayer.play's arguments as the scripts pass them; `n` is how many were given. In order
// (JPCSP's names): pauseMode (1: start PAUSED on the requested chapter's first picture -- MEASURED,
// the maintainer's PSP 2026-10-10: The Animatrix's one-second still chapters, Goldmember's loop held as a
// still; fj#65, docs/p9.md M4k), menuMode (1: a menu's background clip), the playlist NUMBER (from 1, in
// PLAYLIST.UMD's order: the host plays index n - 1), the chapter (from 1), then the raw stream
// ids (video 0xE000, audio 0xBD00 + n, -1: unchanged; docs/p9.md S1) with their flags.
typedef struct {
    int n;
    float a[12];
} menu_play;

// the player's state as getPlayerStatus / getResumeInfo give it to the scripts; `playing` is 0 / 1,
// reported to the scripts as playStatus 2 (stopped) / 1 (playing) -- the library's scripts test
// `playStatus != 2` before a stop
// THE PLAYER'S STATUS (getPlayerStatus): playStatus 1 playing, 2 paused, 0 stopped -- the scripts test
// only 1 and 2, as "a playback is up" (`== 1 || == 2`: Hellboy, xXx, ... wait after stop(1, false)
// until it is neither, else time out back to their menu: 2 cannot be "stopped"; docs/p9.md M4);
// menuMode 1 unless CONTENT plays (a menuMode-0 play() or a resume, not stopped or ended): Hellboy's
// ChangeResource stops and waits while `menuMode != 1`, so a stopped player must read 1 (90 library
// tests of `menuMode != 1`)
typedef struct {
    int playing, playlist, chapter, video, audio, audio_flag, subtitle, subtitle_flag;
    int paused, menu_mode;
} menu_status;

typedef struct {
    void *ud;
    void (*play)(void *ud, const menu_play *p);
    void (*stop)(void *ud);
    // the PLAYER keeps the resume point (the scripts only ask): resume() continues it and returns 0,
    // or returns -1 with none (119 library sites test `resume() == 0`, 26 `== -1`); resume_info
    // fills `s` and returns 0, or -1 with none; change_resume sets its streams (video .. subtitle
    // flag in s, changeResumeInfo's five arguments)
    int  (*resume)(void *ud);
    int  (*resume_info)(void *ud, menu_status *s);
    void (*change_resume)(void *ud, const menu_status *s);
    void (*status)(void *ud, menu_status *s);
    // the bytes of RESOURCE/<name>.RCO (they must stay valid until the next load or menu_free)
    int  (*load_rco)(void *ud, const char *name, const uint8_t **buf, size_t *len);
    // the trace (one line, no newline)
    void (*trace)(void *ud, const char *line);
    // decode an RCO image (format 0 PNG, 1 JPEG) into malloc'd straight RGBA8, rows top first;
    // 0 ok (the engine frees *rgba). The PC: libpng / libjpeg; the UMD Main: libpng / Imlib2.
    int  (*decode_image)(void *ud, int format, const uint8_t *data, size_t len, int *w, int *h, uint8_t **rgba);
    // a script ran setUserData: the host writes the disc's kept data now (a quit without onExit -- a
    // power cut -- still finds it); NULL: none
    void (*kept_changed)(void *ud);
    // a sound plays (a script's sound.play(): resource.soundtable.<label>, or a FireEvent's sound):
    // key names it (stable for a resource's entry: a cache key), pcm its 48 kHz 16-bit frames
    // interleaved (nch 1 or 2; valid during the call; vag.c decodes them, once); frames 0 stops
    // what plays (sound.stop()). NULL: silent
    void (*sound)(void *ud, uint32_t key, const int16_t *pcm, uint32_t frames, int nch);
    // the resource changes (controller.changeResource), before RESOURCE/<name>.RCO loads: the system's
    // part of the change (fj#66: the host stops a menu's playback); NULL: none
    void (*change_resource)(void *ud, const char *name);
} menu_host;

menu *menu_new(const menu_host *h);
void  menu_free(menu *m);
// load RESOURCE/<name>.RCO, run its script, call controller.onAutoPlay; 0 ok
int   menu_start(menu *m, const char *name);

// RELAUNCH (M1d, docs/p9.md S3.3; the PSP captures: Akira relaunched goes back into its film,
// Austin Powers 2 back to its main menu without its logo and language page). Quitting a disc calls
// controller.onExit (the scripts save their state through setUserData there: Akira's onExit, Austin
// Powers 2's), then the host keeps the disc's user data (menu_save) and the player its resume point.
// Launching a disc with kept data restores it (menu_load, before the start) and calls
// controller.onContinuePlay instead of onAutoPlay (menu_continue): Austin Powers 2's onAutoPlay
// plays its logo unconditionally, so only onContinuePlay can skip it.
void  menu_exit(menu *m);
// the kept user data as bytes (a compact text form); returns the length (0: none kept), writing at
// most `cap` (call with cap 0 for the size)
size_t menu_save(const menu *m, char *buf, size_t cap);
// restore kept user data saved by menu_save; 0 ok, -1 malformed (nothing restored)
int   menu_load(menu *m, const char *buf, size_t len);
// as menu_start, calling controller.onContinuePlay
int   menu_continue(menu *m, const char *name);
// advance the clock: timers fire (in time order), then any pending resource change happens
void  menu_tick(menu *m, uint32_t ms);
// a key; 1 when the engine took it (a handler ran, or input is locked), 0 when nothing did -- the
// SYSTEM's then (P9-6: Circle at the top page quits the disc; Start shows "not available here")
int   menu_key(menu *m, int key);
// the player: a playlist ended / a chapter began / the picture passed a named mark (PLAYLIST.UMD's
// type-16 marks: movieplayer.onMark with mark_name -- Now That's Music opens its menus at "initMenu",
// The Rock and Lost leave their trailers at their Endmarks; docs/p9.md M4)
void  menu_playlist_end(menu *m, int playlist);
void  menu_chapter(menu *m, int chapter);
void  menu_mark(menu *m, const char *name);
// "" while the engine runs; else why it stopped (the host then plays the disc directly, S5)
const char *menu_error(const menu *m);
uint32_t menu_now(const menu *m);
// set the engine's clock (ms) before a start: a relaunched engine continues the host's time line
void  menu_set_clock(menu *m, uint32_t now);

// draw the open pages into `px` (w x h, `stride` bytes a row; PREMULTIPLIED, cleared to transparent
// first) in `layout`: MENU_PX_RGBA (bytes R, G, B, A) or MENU_PX_PLANE, the subtitle plane's pixel
// (a little-endian uint32 {A, R, G, B}: bytes B, G, R, A; docs/hps_host.md S3.4). The scene's space
// is 854 x 480 with its origin at the centre and y up (docs/p9.md S3.3, M1c), mapped onto the target
// whole -- 720 x 480 for the plane (16:9 anamorphic), 480 x 272 to lay beside the PSP's screen.
// Returns the pixels blended (the cost). M3 renders into a cached buffer and copies to the uncached
// plane with aligned 32-bit stores (a blend reads its destination: never on uncached memory).
enum { MENU_PX_RGBA, MENU_PX_PLANE };
uint32_t menu_render(menu *m, uint8_t *px, int w, int h, int stride, int layout);
// ... a rectangle of the scene onto the whole target: its left x, top y, width, height in the scene's
// units (centre origin, y up). menu_render is (-427, 240, 854, 480); the host's fits for a 4:3 CRT
// (docs/analog.md S7): Letterbox the whole scene into a 720 x 360 band, Crop (-320, 240, 640, 480)
uint32_t menu_render_view(menu *m, uint8_t *px, int w, int h, int stride, int layout,
                          float sx, float sy, float sw, float sh);
// ... INCREMENTAL (P9 M4d, the damage rectangles): px must hold the previous menu_render_*_inc frame,
// drawn into the same buffer with the same geometry, layout and view (else the frame is drawn whole);
// only the boxes of what changed since are cleared and drawn again -- the result equals menu_render_view's
// exactly. A full menu_render_* into another buffer between two incremental frames does not disturb it.
// Returns the pixels blended (this frame's cost).
uint32_t menu_render_view_inc(menu *m, uint8_t *px, int w, int h, int stride, int layout,
                              float sx, float sy, float sw, float sh);
uint32_t menu_render_inc(menu *m, uint8_t *px, int w, int h, int stride, int layout);
// the pixels the incremental renders redrew, in all (the benches' report)
uint64_t menu_inc_damaged(const menu *m);
// the last incremental frame's redrawn rectangles {x0, y0, x1, y1} in its target's pixels (clipped, none
// empty; the whole target when it was drawn whole), at most `max` (8 suffice): their count
int menu_inc_damage(const menu *m, int (*r)[4], int max);
// THE CANVAS SCALE (M4h): src's rectangle (rx, ry, rw, rh, source pixels) bilinear onto the whole of dst,
// every channel alike (premultiplied, any layout), dst WRITTEN (not blended); only dst's pixels inside clip
// {x0, y0, x1, y1} (NULL all) -- exactly what the whole call writes there
void menu_scale(const uint8_t *src, int sw, int sh, int sstride, uint8_t *dst, int dw, int dh, int dstride,
                float rx, float ry, float rw, float rh, const int *clip);
#ifdef MENU_PROF
// MENU_PROF builds only (the A9 profile, fj#74): the incremental draws' cost per node, the costliest first
void menu_prof_dump(menu *m, void (*out)(const char *line, void *ud), void *ud);
#endif
// trace every object menu_render draws: "DRAW <label> x0 y0 x1 y1 a<alpha>" in target pixels
void menu_trace_draw(menu *m, int on);
// the renderer's general path only (the fast path for unrotated objects off): the benches' reference
void menu_render_general(menu *m, int on);
// the item cache (fj#74, menu.c THE ITEM CACHE) on / off -- on by default. Off: every item drawn, every frame, as the
// full render draws it (the benches: a clipped draw's exactness, which the cache's unclipped entries would hide)
void menu_item_cache(menu *m, int on);
#define MENU_ITEM_CACHE 1               // (the benches build against older trees too: tools/menu_render_ab.py --ref-commit)
// the movie window the scripts set (movieplayer.setPos / setSize) in the scene's space: the
// centre (x, y) and the size (w, h); the whole screen until a script sets it
void menu_video_window(const menu *m, float *x, float *y, float *w, float *h);
// the picture may have changed since the last menu_render (a script ran, a tween or an animation is
// running): the host renders and flips only then
int  menu_dirty(const menu *m);
// a page is open (the menu's picture is up: the host's grab and ui levels follow it)
int  menu_page_open(const menu *m);
// the focused object's label (NULL none) and its RCO object type (26 a UButton, 2 a Plane): the M4
// library probe's (bench/umd/menu/menu_host_check.c --walk)
const char *menu_focus(const menu *m, int *type);
// an open page draws something (an object visible at a non-zero alpha with a picture, or a bare
// plane): Family Guy's pageDummy -- open while its episode starts, to hold the keys -- draws nothing
int  menu_shows(const menu *m);

#ifdef __cplusplus
}
#endif
