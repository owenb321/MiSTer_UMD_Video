// menu_run.c -- the menu engine on the PC with a model player (P9 M1b): run a disc's startup and a
// key script, printing the engine's trace (every native, callback, event, timer, focus change).
//
//   menu_run DIR [--start EN100000] [--ms 60000] [--step 10] [--key T:NAME ...]
//            [--shot T:FILE.png ...] [--size WxH] [--under FILE.png] [--relaunch T ...] [--time-render T:N]
// --shot writes the menu plane at time T (ms) as drawn by menu_render, at --size (720x480 the
// plane, 480x272 the PSP's screen), over a checkerboard or over --under (a picture scaled to fit:
// the video under the menu, for a side-by-side with a capture); its line in the trace gives the
// pixels blended.
// --relaunch quits the disc at T and launches it again, as the PSP's captures did: onExit, the
// user data kept (menu_save -> menu_load) and the player's resume point (a playing content
// playlist's place), a NEW engine, onContinuePlay (menu.h "RELAUNCH").
// DIR is tools/menu_fixture.py's: the RCOs and playlists.txt. The model player: play() starts the
// playlist the script names (argument 2, numbered FROM 1 in PLAYLIST.UMD's order: Akira's capture
// plays its 40 s logo clip, script 5 = index 4, then loops the menu, script 6 = index 5; docs/p9.md
// S3.3) at its chapter (argument 3, from 1), and ends it after the
// playlist's remaining time (onPlayListEnd); stop() ends it silently; its chapters post onChapter,
// the start chapter included; its named marks (marks.txt) post onMark from its start place on (a
// mark AT the start too), as umd_menu_host does.
// Exit status 0 unless the engine stopped (a refused opcode, an undefined method, a bound hit).
#define _POSIX_C_SOURCE 199309L      // (clock_gettime for --time-render)
#include "menu.h"
#include "img_decode.h"

#include <png.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int idx; uint32_t dur, nch, ch[512]; } plist;

static plist pls[512];
static int npls;
typedef struct { int idx; uint32_t t; char name[32]; } pmark;    // marks.txt: a named mark, by time
static pmark mks[4096];
static int nmks;
static const char *dir;
static uint8_t *rco_buf;
static menu *M;
static uint32_t now;

typedef struct {
    int playing, playlist, chapter, next_ch, next_mk, video, audio, aflag, sub, sflag, menu_mode;
    uint32_t t0, end, pos;          // pos: the resume point's place in its playlist
    int held;                       // fj#65: pauseMode 1 -- paused at the start place (hold_t)
    uint32_t hold_t, play_at;       // play_at: the engine's clock at the play() (fj#66)
} player;
static player P;
// the resume point (a MODEL, M1d measures the PSP's rule): a playback with menuMode 0 (content, not
// a menu's background) that is stopped or replaced by another play() leaves its place; resume()
// continues it; it ends with its playlist
static player R;
static int has_r;

static const plist *find_pl(int num)            // the script's playlist number (from 1)
{
    for (int i = 0; i < npls; i++) if (pls[i].idx == num - 1) return &pls[i];
    return NULL;
}

// the first of a playlist's named marks at or after `off` ms from its start (nmks: none)
static int first_mark(int num, uint32_t off)
{
    for (int i = 0; i < nmks; i++) if (mks[i].idx == num - 1 && mks[i].t >= off) return i;
    return nmks;
}

static void h_trace(void *ud, const char *line) { (void)ud; printf("%s\n", line); }

static void keep_resume(void)
{
    if (P.playing && !P.menu_mode && now < P.end) {
        R = P; R.pos = now - P.t0; has_r = 1;
        printf("%8u PLAYER resume point: playlist %d at %u ms\n", now, R.playlist, R.pos);
    }
}

static void h_play(void *ud, const menu_play *p)
{
    (void)ud;
    if (p->n > 1 && p->a[1] != 0) keep_resume();     // (a menu's play keeps it; another content play does not: umd_menu_host)
    int pl = p->n > 2 ? (int)p->a[2] : 0, ch = p->n > 3 ? (int)p->a[3] : 1;
    const plist *l = find_pl(pl);
    P.playing = 1; P.playlist = pl; P.chapter = ch < 1 ? 1 : ch; P.menu_mode = p->n > 1 && p->a[1] != 0;
    P.video = p->n > 4 ? (int)p->a[4] : 0; P.audio = p->n > 5 ? (int)p->a[5] : 0; P.aflag = p->n > 6 ? (int)p->a[6] : 0;
    P.sub = p->n > 7 ? (int)p->a[7] : 0; P.sflag = p->n > 8 ? (int)p->a[8] : 0;
    uint32_t off = (l && P.chapter - 1 < (int)l->nch) ? l->ch[P.chapter - 1] : 0;
    P.t0 = now - off;
    P.end = P.t0 + (l ? l->dur : 0);
    // (the next chapter index to post, from 0): the START chapter is posted too, at the first
    // picture -- JPCSP's player resets its chapter to -1 at each play, and Austin Powers 2 shows its
    // language page from that onChapter (init_ls arms fArray, onChapter calls show_ls)
    P.next_ch = P.chapter - 1;
    P.next_mk = first_mark(pl, off);
    // pauseMode 1 starts paused on the requested chapter's first picture (fj#65, the maintainer's PSP,
    // 2026-10-10; umd_menu_host): its start chapter and a mark AT the start post, nothing later, no end
    P.held = p->n > 0 && p->a[0] == 1;
    P.hold_t = now;
    P.play_at = menu_now(M);
    printf("%8u PLAYER play playlist %d chapter %d (%u ms left)%s%s\n", now, pl, P.chapter, P.end - now,
           l ? "" : " -- NO SUCH PLAYLIST", P.held ? " held (pauseMode 1)" : "");
}
static void h_stop(void *ud) { (void)ud; P.playing = 0; printf("%8u PLAYER stop\n", now); }
// the system stops a menu's playback (menuMode 1) at a resource change, unless the script asked it in
// the same instant (fj#66, the maintainer's PSP 2026-10-10: A Few Good Men's warning cards over black)
static void h_change_resource(void *ud, const char *name)
{
    (void)ud;
    if (!P.playing || !P.menu_mode || P.play_at == menu_now(M)) return;
    printf("%8u PLAYER stop (changeResource %s: the system's)\n", now, name);
    P.playing = 0;
}
static int h_resume(void *ud)
{
    (void)ud;
    if (!has_r) { printf("%8u PLAYER resume: none\n", now); return -1; }
    uint32_t dur = R.end - R.t0;
    P = R; P.playing = 1; P.held = 0; has_r = 0;
    P.t0 = now - R.pos; P.end = P.t0 + dur;
    P.next_mk = first_mark(P.playlist, R.pos);
    printf("%8u PLAYER resume playlist %d at %u ms\n", now, P.playlist, R.pos);
    return 0;
}
static int h_resume_info(void *ud, menu_status *s)
{
    (void)ud;
    if (!has_r) return -1;
    s->playing = 0; s->playlist = R.playlist; s->chapter = R.chapter; s->video = R.video;
    s->audio = R.audio; s->audio_flag = R.aflag; s->subtitle = R.sub; s->subtitle_flag = R.sflag;
    return 0;
}
static void h_change_resume(void *ud, const menu_status *s)
{
    (void)ud;
    if (!has_r) return;
    R.video = s->video; R.audio = s->audio; R.aflag = s->audio_flag; R.sub = s->subtitle; R.sflag = s->subtitle_flag;
}
static void h_status(void *ud, menu_status *s)
{
    (void)ud;
    s->playing = P.playing; s->paused = P.playing && P.held; s->menu_mode = !P.playing || P.menu_mode; s->playlist = P.playlist; s->chapter = P.chapter; s->video = P.video;
    s->audio = P.audio; s->audio_flag = P.aflag; s->subtitle = P.sub; s->subtitle_flag = P.sflag;
}
static int h_load(void *ud, const char *name, const uint8_t **buf, size_t *len)
{
    (void)ud;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.RCO", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    free(rco_buf);
    rco_buf = (uint8_t *)malloc((size_t)n);
    if (!rco_buf || fread(rco_buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); return -1; }
    fclose(f);
    *buf = rco_buf; *len = (size_t)n;
    return 0;
}

// the plane over a checkerboard (or a picture) to a PNG
static uint8_t *under_px;
static int under_w, under_h;
static void shot(const char *path, int w, int h)
{
    uint8_t *pl = (uint8_t *)malloc((size_t)w * (size_t)h * 4), *rgb = (uint8_t *)malloc((size_t)w * (size_t)h * 3);
    uint32_t nb = menu_render(M, pl, w, h, w * 4, MENU_PX_RGBA);
    // the plane's layout (M3's): the same picture with red and blue swapped, byte for byte
    uint8_t *pp = (uint8_t *)malloc((size_t)w * (size_t)h * 4);
    menu_render(M, pp, w, h, w * 4, MENU_PX_PLANE);
    int same = 1;
    for (size_t i = 0; i < (size_t)w * (size_t)h && same; i++)
        same = pp[4 * i] == pl[4 * i + 2] && pp[4 * i + 1] == pl[4 * i + 1] && pp[4 * i + 2] == pl[4 * i] && pp[4 * i + 3] == pl[4 * i + 3];
    // the fast path against the general one (the reference), the same frame: at most 8 levels apart,
    // and at most 0.5 % of the pixels more than 2 (its integer rounding at the edges)
    menu_render_general(M, 1);
    menu_render(M, pp, w, h, w * 4, MENU_PX_RGBA);
    menu_render_general(M, 0);
    int fmax = 0;
    size_t fover = 0;
    for (size_t i = 0; i < (size_t)w * (size_t)h * 4; i++) {
        int d = pl[i] > pp[i] ? pl[i] - pp[i] : pp[i] - pl[i];
        if (d > fmax) fmax = d;
        if (d > 2) fover++;
    }
    int fast_ok = fmax <= 8 && fover * 200 <= (size_t)w * (size_t)h * 4;
    free(pp);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *p = pl + 4 * ((size_t)y * (size_t)w + (size_t)x);
        uint8_t bg[3];
        if (under_px) {
            const uint8_t *u = under_px + 4 * ((size_t)(y * under_h / h) * (size_t)under_w + (size_t)(x * under_w / w));
            bg[0] = u[0]; bg[1] = u[1]; bg[2] = u[2];
        } else { uint8_t c = ((x / 16 + y / 16) & 1) ? 96 : 64; bg[0] = bg[1] = bg[2] = c; }
        for (int k = 0; k < 3; k++) rgb[3 * ((size_t)y * (size_t)w + (size_t)x) + (size_t)k] = (uint8_t)(p[k] + bg[k] * (255 - p[3]) / 255);
    }
    png_image im;
    memset(&im, 0, sizeof(im));
    im.version = PNG_IMAGE_VERSION; im.width = (png_uint_32)w; im.height = (png_uint_32)h; im.format = PNG_FORMAT_RGB;
    if (!png_image_write_to_file(&im, path, 0, rgb, 0, NULL)) fprintf(stderr, "menu_run: cannot write %s\n", path);
    printf("%8u SHOT %s (%dx%d, %u pixels blended, plane layout %s, fast path %s: max %d, %u above 2)\n", now, path, w, h, nb,
           same ? "ok" : "DIFFERS", fast_ok ? "ok" : "DIFFERS", fmax, (unsigned)fover);
    free(pl); free(rgb);
}

static int key_code(const char *s)
{
    static const char *names[MENU_NKEYS] = { "UP", "DOWN", "LEFT", "RIGHT", "CROSS", "CIRCLE", "TRIANGLE",
                                             "SQUARE", "START", "SELECT", "L", "R" };
    for (int i = 0; i < MENU_NKEYS; i++) if (!strcmp(s, names[i])) return i;
    return -1;
}

int main(int argc, char **argv)
{
    const char *start = "EN100000";
    uint32_t ms = 60000, step = 10;
    struct { uint32_t t; int k; } keys[256];
    int nkeys = 0;
    struct { uint32_t t; const char *path; } shots[256];
    int nshots = 0, sw = 720, sh = 480;
    uint32_t relaunch[16];
    int nrel = 0;
    uint32_t time_t0 = 0, time_n = 0;          // --time-render T:N
    if (argc < 2) { fprintf(stderr, "usage: menu_run DIR [--start NAME] [--ms N] [--step N] [--key T:NAME ...]\n"); return 2; }
    dir = argv[1];
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--start") && i + 1 < argc) start = argv[++i];
        else if (!strcmp(argv[i], "--ms") && i + 1 < argc) ms = (uint32_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--step") && i + 1 < argc) step = (uint32_t)atol(argv[++i]);
        else if (!strcmp(argv[i], "--key") && i + 1 < argc && nkeys < 256) {
            char *c = strchr(argv[++i], ':');
            if (!c || key_code(c + 1) < 0) { fprintf(stderr, "bad --key %s\n", argv[i]); return 2; }
            keys[nkeys].t = (uint32_t)atol(argv[i]); keys[nkeys].k = key_code(c + 1); nkeys++;
        } else if (!strcmp(argv[i], "--shot") && i + 1 < argc && nshots < 256) {
            char *c = strchr(argv[++i], ':');
            if (!c) { fprintf(stderr, "bad --shot %s\n", argv[i]); return 2; }
            shots[nshots].t = (uint32_t)atol(argv[i]); shots[nshots].path = c + 1; nshots++;
        } else if (!strcmp(argv[i], "--time-render") && i + 1 < argc) {
            if (sscanf(argv[++i], "%u:%u", &time_t0, &time_n) != 2 || !time_n) { fprintf(stderr, "bad --time-render\n"); return 2; }
        } else if (!strcmp(argv[i], "--relaunch") && i + 1 < argc && nrel < 16) {
            relaunch[nrel++] = (uint32_t)atol(argv[++i]);
        } else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &sw, &sh) != 2 || sw < 1 || sh < 1 || sw > 4096 || sh > 4096) { fprintf(stderr, "bad --size\n"); return 2; }
        } else if (!strcmp(argv[i], "--under") && i + 1 < argc) {
            FILE *u = fopen(argv[++i], "rb");
            if (!u) { perror(argv[i]); return 2; }
            fseek(u, 0, SEEK_END); long un = ftell(u); fseek(u, 0, SEEK_SET);
            uint8_t *ub = (uint8_t *)malloc((size_t)un);
            if (!ub || fread(ub, 1, (size_t)un, u) != (size_t)un || bench_dec_png(ub, (size_t)un, &under_w, &under_h, &under_px)) { fprintf(stderr, "bad --under\n"); return 2; }
            fclose(u); free(ub);
        } else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    char path[1024];
    snprintf(path, sizeof(path), "%s/playlists.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return 2; }
    while (npls < 512 && fscanf(f, "%d %u %u", &pls[npls].idx, &pls[npls].dur, &pls[npls].nch) == 3) {
        for (uint32_t c = 0; c < pls[npls].nch; c++) {
            uint32_t x;
            if (fscanf(f, "%u", &x) != 1) break;
            if (c < 512) pls[npls].ch[c] = x;
        }
        if (pls[npls].nch > 512) pls[npls].nch = 512;
        npls++;
    }
    fclose(f);
    snprintf(path, sizeof(path), "%s/marks.txt", dir);
    f = fopen(path, "r");                      // (none: an older fixture, no marks)
    char ml[128];
    while (f && nmks < 4096 && fgets(ml, sizeof(ml), f)) {
        int n = 0;
        if (sscanf(ml, "%d %u %n", &mks[nmks].idx, &mks[nmks].t, &n) < 2) continue;
        ml[strcspn(ml, "\n")] = 0;
        snprintf(mks[nmks].name, sizeof(mks[nmks].name), "%s", ml + n);
        nmks++;
    }
    if (f) fclose(f);

    menu_host h;
    memset(&h, 0, sizeof(h));
    h.play = h_play; h.stop = h_stop; h.resume = h_resume; h.resume_info = h_resume_info;
    h.change_resume = h_change_resume; h.status = h_status; h.decode_image = bench_decode_image; h.load_rco = h_load; h.trace = h_trace;
    h.change_resource = h_change_resource;
    M = menu_new(&h);
    menu_trace_draw(M, nshots > 0);
    int rc = menu_start(M, start);
    for (now = 0; rc == 0 && now < ms && !menu_error(M)[0]; ) {
        uint32_t t = now + step;
        // the player first: chapters and the playlist's end, at their times
        if (P.playing) {
            const plist *l = find_pl(P.playlist);
            if (P.held && t > P.hold_t) t = P.hold_t;       // (held: the player's time stops at the start)
            while (l && P.next_ch < (int)l->nch && P.t0 + l->ch[P.next_ch] <= t && P.t0 + l->ch[P.next_ch] < P.end) {
                P.chapter = P.next_ch + 1;
                printf("%8u PLAYER chapter %d\n", P.t0 + l->ch[P.next_ch], P.chapter);
                P.next_ch++;
                menu_chapter(M, P.chapter);
            }
            while (P.playing && P.next_mk < nmks && mks[P.next_mk].idx == P.playlist - 1 && P.t0 + mks[P.next_mk].t <= t
                   && P.t0 + mks[P.next_mk].t < P.end) {
                const pmark *k = &mks[P.next_mk++];
                int pl_was = P.playlist;
                uint32_t t0_was = P.t0;
                printf("%8u PLAYER mark %s\n", P.t0 + k->t, k->name);
                menu_mark(M, k->name);
                if (P.playlist != pl_was || P.t0 != t0_was) break;     // (the handler played: its own marks now)
            }
            if (P.playing && P.end <= t) {
                P.playing = 0;          // (an ended playback leaves no resume point)
                printf("%8u PLAYER end of playlist %d\n", P.end, P.playlist);
                menu_playlist_end(M, P.playlist);
            }
        }
        menu_tick(M, step);
        now = menu_now(M);
        for (int i = 0; i < nkeys; i++) if (keys[i].t > now - step && keys[i].t <= now) menu_key(M, keys[i].k);
        for (int i = 0; i < nshots; i++) if (shots[i].t > now - step && shots[i].t <= now) shot(shots[i].path, sw, sh);
        if (time_n && time_t0 > now - step && time_t0 <= now) {
            // the renderer's cost at this state: N frames of 720 x 480 in the plane's layout
            uint8_t *px = (uint8_t *)malloc(720 * 480 * 4);
            struct timespec a, b;
            clock_gettime(CLOCK_MONOTONIC, &a);
            uint32_t nb = 0;
            for (uint32_t k = 0; k < time_n && px; k++) nb = menu_render(M, px, 720, 480, 720 * 4, MENU_PX_PLANE);
            clock_gettime(CLOCK_MONOTONIC, &b);
            double us = ((double)(b.tv_sec - a.tv_sec) * 1e6 + (double)(b.tv_nsec - a.tv_nsec) / 1e3) / time_n;
            printf("%8u RENDER %.0f us a frame (%u pixels blended)\n", now, us, nb);
            free(px);
        }
        for (int i = 0; i < nrel; i++) if (relaunch[i] > now - step && relaunch[i] <= now) {
            printf("%8u RELAUNCH: quit\n", now);
            menu_exit(M);
            size_t n = menu_save(M, NULL, 0);
            char *saved = n ? (char *)malloc(n) : NULL;
            if (saved) menu_save(M, saved, n);
            keep_resume();                      // the player keeps a playing content playlist's place
            P.playing = 0;
            menu_free(M);
            printf("%8u RELAUNCH: %u bytes of user data kept, resume point %s\n", now, (unsigned)n, has_r ? "kept" : "none");
            M = menu_new(&h);
            menu_trace_draw(M, nshots > 0);
            menu_set_clock(M, now);
            if (saved) menu_load(M, saved, n);
            rc = saved ? menu_continue(M, start) : menu_start(M, start);
            free(saved);
        }
    }
    const char *e = menu_error(M);
    printf("%8u END %s\n", now, e[0] ? e : "ok");
    int bad = e[0] != 0;                // (e is M's: read before menu_free)
    menu_free(M);
    free(rco_buf);
    return bad;
}
