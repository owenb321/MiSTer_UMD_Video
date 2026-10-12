// menu.c -- the disc menu engine: the RCO's objects as script objects, the natives the scripts
// call, events, timers, focus and keys, the player's callbacks (menu.h; docs/p9.md S3.3).
//
// THE OBJECT MODEL (JPCSP's description, checked against the scripts' own accesses):
//   resource.pagetable.<page>            a page: open() / activate() / close(); its `root`
//   <page>.root.children.<label>         the page's objects, each with `children` of its own
//   resource.animtable.<label>           an animation: play() / stop()
//   resource.soundtable.<label>          a sound: play()
//   resource.texturetable.<label>        an image (assigned to an object's `texture`)
//   movieplayer, controller, timer, Math, writeln, parseInt, ...
// Events are an object's event attributes: a script function ("script:/<vsmx>/<fn>", called with
// the object as `this`), an animation to play, or an object to focus (a D-pad move).
//
// M1b ran the scripts and traced every native. M1c draws: tweens (the RCO's MoveTo / Recolour /
// Resize / Rotate / Fade and the scripts' anim* methods) move each object's state, and
// menu_render() draws the open pages (THE SCENE, below).
//
// THE SCENE (docs/p9.md S3.3 M1c; each rule from the discs' own data, JPCSP where they are silent):
//   * the space is 854 x 480, origin at the centre, y UP: full-screen planes are 854 x 480 at
//     (0, 0) (Family Guy's plnEP*), Ep01 at y 170 sits above Ep05 at y -150;
//   * an object is drawn centred on its position, its size its width / height or, when those are
//     0, its image's; times its scale. A child's position is in its parent's space: the parent's
//     position, rotation and scale carry down; so do the colour scales (multiplied); ALPHA DOES NOT
//     (fj#69, below: a write to an object's alpha is handed down to its subtree instead);
//   * a Plane without an image is a solid rectangle in its colour (Family Guy's `Black`, faded in
//     by animBlack; Akira's pageWaitDummy);
//   * pages are drawn in the RCO's order, each object before its children;
//   * an object's image is its `texture` property when a script set one (903 library sites:
//     `obj.texture = resource.texturetable.X`), else its RCO `image`;
//   * durations are milliseconds and tweens do not block an animation, Delays do: Family Guy's
//     ATTENTION and FBI pages (Recolour 250, Delay 7000, Recolour 250, Delay 250) start 7.20 s
//     apart in the capture against 7.25 here (7.75 if the fades blocked);
//     a rotation is in RADIANS about the object's position (X-Men: z = -6.28, one turn; the sense,
//     counter-clockwise for a positive z in the y-up space, is JPCSP's and not yet measured);
//     a tween is linear (accelMode is traced, its curves not yet measured); an ANIMATION's steps on
//     the same property RUN TOGETHER, applied in the order they started, so the one that ends last
//     wins (JPCSP's scheduler; Family Guy's focused Ep01 gets animColor(.., 1, 250) and, at the same
//     moment, animShowMMBtns' Recolour to 0.7 over 100 ms: it ends lit, as its script means -- the
//     capture's 1.1x scale is measured, its alpha is not, the camera saturates); a SCRIPT's anim*()
//     REPLACES the running tweens of its property, and set* cancels them (P9 M4b: MCR disc 2's
//     highlights); a script's animRotate() turns the short way (Astro Boy's drum; pos_method).
#include "menu.h"
#include "vag.h"
#include "rco.h"
#include "rco_attrs.h"
#include "vsmx.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
// the A9's NEON for this file (the vector step): the Main's Makefile sets no -mfpu, and the flag for one
// file is a pragma (fj#74)
#if defined(__arm__) && !defined(__ARM_NEON) && defined(__GNUC__) && !defined(__clang__)
#pragma GCC target ("fpu=neon")
#endif
#ifdef MENU_PROF
#include <time.h>
#endif
#include <string.h>

// the animation clock: milliseconds per unit of an RCO animation's duration / delay: 1, measured
// on Family Guy's capture (docs/p9.md S3.3 M1c)
#ifndef MENU_ANIM_UNIT_MS
#define MENU_ANIM_UNIT_MS 1.0f
#endif

enum { REF_EVENT = 0x400, REF_TEXT = 0x401, REF_IMG = 0x402, REF_MODEL = 0x403, REF_FONT = 0x405,
       REF_OBJ2 = 0x407, REF_ANIM = 0x408, REF_OBJ = 0x409, REF_NONE = 0xFFFF };

typedef struct node {
    int      ent;               // its RCO entry
    uint8_t  table, type;
    vm_obj  *obj;               // its script object
    vm_obj  *holder;            // where its children's labels live (a page's `root`, else obj)
    int      page;              // the node index of its page (objects), -1 none
    int      last_focus;        // a page's: the node last focused in it, -1 none
    int      fi_pending;        // a page's: the node whose onFocusIn its open() delivered, until its
                                // first activate() (FOCUS AT ACTIVATION, n_activate); -1 none
    uint32_t fi_t;              // ... and when (the open's instant)
    int      visible;
    float    pos[3], col[4], size[3], scale[3];
    float    base_a;            // the alpha its own last write gave it (authored at a reset): what an
                                // ancestor's alpha write scales (fj#69, ALPHA IS WRITTEN DOWN)
    float    rot[3];            // RADIANS (X-Men's menu turns its orbs by z = -6.28: one full turn)
    float    crop[4];           // setCrop / animCrop: (x, y, w, h) of the object, fractions from its
                                // top left; what lies outside is not drawn (a MODEL, below)
} node;

enum { P_POS, P_COL, P_SIZE, P_SCALE, P_ROT, P_CROP, P_N };
static const char *const PROP_NAME[P_N] = { "pos", "colour", "size", "scale", "rotation", "crop" };

typedef struct tween {
    int      node, prop, n;
    float    from[4], to[4];
    uint32_t t0, dur;
    int      src;                   // the animation whose step started it (its node), -1 a script's
} tween;

// a decoded image (premultiplied RGBA8), per RCO image entry; on first use
typedef struct image_c {
    uint8_t *px;
    int      w, h, tried;
    int      tx0, ty0, tx1, ty1;     // the box of its texels with alpha (tx0 > tx1: none): the
                                     // renderer skips the transparent margins
    int      opaque;                 // every texel's alpha 255 (fj#74: draw_axis's opaque step)
} image_c;

typedef struct anim_run {
    int      node;              // the animation (a node of the anim table)
    int      cursor;            // the next action (an entry index), -1 done
    uint32_t wake;              // time to continue (a Delay)
    int      target;            // the object it was played on (an argument), -1 none
    int      locks;             // its Lock holds the keys (until it ends, an Unlock, or its page closes)
} anim_run;

typedef struct timer_s {
    int      id;
    uint32_t period, due;
    vm_obj  *fn;
    vm_value args[8];
    int      nargs;
} timer_s;

// a value kept across script VMs (controller.setUserData; a resource change)
typedef struct kept {
    uint8_t  t;                 // V_UNDEF .. V_OBJ (V_OBJ: an array or an object)
    float    n;
    int      b;
    char    *s;
    int      is_array;
    int      nkids;
    char   **keys;              // objects' keys (NULL for an array)
    struct kept *kids;
} kept;

#define DMG_MAX 8               // the damage rectangles a frame keeps (dmg_add, menu_render_view_inc)

struct menu {
    menu_host h;
    rco      r;
    const uint8_t *rbuf;
    size_t   rlen;
    vm      *v;
    char     err[256];
    char     cur[16], next_res[16];
    uint32_t now;
    uint32_t debt;              // ms the clock ran ahead in a script's busy-wait (busy_poll), absorbed by menu_tick
    int      poll_node;         // the node a busy-wait polls (its trace once a streak), -1 none
    node    *nodes;
    int      nnodes;
    int     *by_ent;            // entry index -> node index (-1)
    int      focus, active_page;
    anim_run runs[64];
    int      nruns;
    uint32_t n_focus_set;       // the scripts' setFocus() calls (open()'s default focus yields to one)
    timer_s  timers[32];
    int      ntimers, next_timer;
    vm_obj  *controller, *movieplayer;
    vm_obj  *proto_page, *proto_obj, *proto_anim, *proto_sound, *proto_image;
    kept     userdata;
    int      has_userdata;
    tween   *tw;                // the running tweens, grown on demand (THE TWEEN TABLE GROWS, tween_one)
    int      ntw, tw_cap;
    image_c *img;               // per entry (r.n)
    struct sound_c { int16_t *pcm; uint32_t frames; int nch, tried; } *snd;   // per entry, decoded at 48 kHz
    float    video[4];          // the movie window: centre x, y, size w, h (the scene's space)
    int      trace_draw;
    int      io_warned;             // an iconOffset anchor not understood was traced (once)
    int      fit_warned;            // a size-mode word not understood was traced (once)
    int      tw_src;                // the animation whose step is starting a tween (-1: a script)
    int      general_only;      // menu_render_general: the fast path off (the benches' reference)
    int      dirty;              // something ran since the last render (menu_dirty)
    // the draw list (this frame's, the previous incremental frame's) and the incremental target's key
    struct dritem *dl, *dl_prev;
    int      ndl, ndl_prev, dl_cap, dl_prev_cap;
    int      inc_valid, inc_w, inc_h, inc_stride, inc_layout, inc_general;
    uint8_t *inc_px;
    float    inc_view[4];
    uint64_t inc_damaged;        // pixels the incremental render redrew, in all (the benches' report)
    int      dmg_last[DMG_MAX][4], n_dmg_last;   // the last incremental frame's rectangles (menu_inc_damage)
    uint32_t *hl;               // draw_axis's lines (fj#74): 2 lines x (R / B, G / A), then the columns' u0, u1, fu x hl_w
    struct icache *ic;           // the item cache (fj#74, THE ITEM CACHE below): one per node
    int      ic_n, ic_warned, ic_off;
    size_t   ic_bytes;
    uint32_t ic_built;
    int      hl_w;
#ifdef MENU_PROF
    uint64_t prof_fill_ns, prof_step_ns, prof_fill_px, prof_step_px;   // MENU_PROF: draw_axis's line fills / pixel steps
    uint64_t *prof_ns, *prof_px; // MENU_PROF (fj#74, the A9 profile): per node, the incremental draws' time and pixels
    int      prof_n;
#endif
};

static void mtrace(menu *m, const char *fmt, ...)
{
    if (!m->h.trace) return;
    char buf[640];
    int l = snprintf(buf, sizeof(buf), "%8u ", m->now);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf + l, sizeof(buf) - (size_t)l, fmt, ap);
    va_end(ap);
    m->poll_node = -1;
    m->h.trace(m->h.ud, buf);
}

static void merr(menu *m, const char *fmt, ...)
{
    if (m->err[0]) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(m->err, sizeof(m->err), fmt, ap);
    va_end(ap);
    mtrace(m, "STOP %s", m->err);
}

const char *menu_error(const menu *m) { return m->err; }
uint32_t menu_now(const menu *m) { return m->now; }
void menu_set_clock(menu *m, uint32_t now) { m->now = now; }

static void vm_tr(void *ud, const char *line) { mtrace((menu *)ud, "%s", line); }

// ---- attributes of an RCO entry, by name -----------------------------------------------------------
// the word index of attribute `name` (a reference's first word), -1 none; *kind its kind
static int attr_at(const rco_entry *e, const char *name, int *kind)
{
    const rco_type_def *td = NULL;
    if (e->table == RCO_T_OBJECT && e->type < RCO_OBJ_NTYPES) td = &RCO_OBJ_TYPES[e->type];
    if (e->table == RCO_T_ANIM && e->type < RCO_ANIM_NTYPES) td = &RCO_ANIM_TYPES[e->type];
    if (!td) return -1;
    int w = 0;
    for (int i = 0; i < td->nattrs; i++) {
        int k = td->attrs[i].kind;
        if (!strcmp(td->attrs[i].name, name)) { if (kind) *kind = k; return w; }
        w += (k == RCO_A_INT || k == RCO_A_FLOAT || k == RCO_A_UNK) ? 1 : 2;
    }
    return -1;
}

static float attr_f(const rco_entry *e, const char *name, float dflt)
{
    int k, w = attr_at(e, name, &k);
    if (w < 0) return dflt;
    uint32_t bits = rco_word(e, (uint32_t)w);
    if (k == RCO_A_INT) return (float)(int32_t)bits;
    float f; memcpy(&f, &bits, 4);
    return f;
}

// a reference attribute: its type and pointer (REF_NONE when absent)
static uint32_t attr_ref(const rco_entry *e, const char *name, uint32_t *ptr)
{
    int k, w = attr_at(e, name, &k);
    *ptr = 0xFFFFFFFFu;
    if (w < 0 || k == RCO_A_INT || k == RCO_A_FLOAT || k == RCO_A_UNK) return REF_NONE;
    *ptr = rco_word(e, (uint32_t)w + 1);
    return rco_word(e, (uint32_t)w) & 0xFFFF;
}

static node *node_of(menu *m, vm_value self)
{
    (void)m;
    return (self.t != V_OBJ || !self.u.o->host) ? NULL : (node *)self.u.o->host;
}

// ---- events -----------------------------------------------------------------------------------------
static void anim_play(menu *m, int ni, int target);
static void set_focus(menu *m, int ni);

// the keys locked: a run that Locked is still running (finished runs leave at the tick's compaction)
static int keys_locked(const menu *m)
{
    for (int i = 0; i < m->nruns; i++) if (m->runs[i].locks) return 1;
    return 0;
}

// A script's call failed. An error its own try will catch propagates to it. A script's TypeError
// otherwise ABANDONS that handler and the disc goes on: on the PSP a handler's error does not stop
// the player (Dude, Where's My Car's onFocusIn reads `animtable["animMMBreath_" + 0 + "_o"]`, none,
// before its caller sets the focus number; its menu works on the PSP). Traced as SCRIPT ERROR, so a
// sweep still sees an engine gap behind one. The VM's own errors (a refusal, a bound) stop the engine.
static int call_failed(menu *m, const char *what)
{
    if (vm_error_caught(m->v)) { mtrace(m, "THROW %s: %s (to the enclosing try)", what, vm_error(m->v)); return -1; }
    if (vm_error_catchable(m->v)) {
        mtrace(m, "SCRIPT ERROR %s: %s (the handler abandoned; the disc goes on)", what, vm_error(m->v));
        vm_error_clear(m->v);
        return -1;
    }
    merr(m, "%s: %s", what, vm_error(m->v));
    return -1;
}

static int run_script_event(menu *m, const char *ev, vm_value self, const char *why)
{
    // "script:/<vsmx label>/<function>"
    const char *fn = strrchr(ev, '/');
    if (strncmp(ev, "script:", 7) || !fn) { mtrace(m, "EVENT %s %s (not a script: ignored)", why, ev); return 0; }
    fn++;
    vm_value f = vm_get(m->v, vm_globals(m->v), fn);
    if (!vm_is_func(f)) { mtrace(m, "EVENT %s %s (no such function)", why, fn); return 0; }
    mtrace(m, "EVENT %s -> %s", why, fn);
    vm_value r, arg = self;
    if (vm_call(m->v, f, self, 1, &arg, &r)) return call_failed(m, fn);
    return 0;
}

// fire an event attribute of an entry: a script, an animation, or a focus move
static int fire(menu *m, int ni, const char *attr)
{
    if (ni < 0) return 0;
    const rco_entry *e = &m->r.e[m->nodes[ni].ent];
    uint32_t ptr, t = attr_ref(e, attr, &ptr);
    char why[96];
    snprintf(why, sizeof(why), "%s.%s", e->label, attr);
    if (t == REF_NONE) return 0;
    if (t == REF_EVENT) {
        const char *ev = rco_event(&m->r, ptr);
        if (!ev) { mtrace(m, "EVENT %s: a bad event offset 0x%x", why, ptr); return 0; }
        return run_script_event(m, ev, vm_objv(m->nodes[ni].obj), why);
    }
    int target = rco_by_offset(&m->r, ptr);
    int tn = target >= 0 ? m->by_ent[target] : -1;
    if (tn < 0) { mtrace(m, "EVENT %s: a reference 0x%x to nothing", why, ptr); return 0; }
    if (t == REF_ANIM) { mtrace(m, "EVENT %s -> play %s", why, m->r.e[target].label); anim_play(m, tn, ni); return 0; }
    if (t == REF_OBJ || t == REF_OBJ2) { mtrace(m, "EVENT %s -> focus %s", why, m->r.e[target].label); set_focus(m, tn); return 0; }
    mtrace(m, "EVENT %s: reference type 0x%x ignored", why, t);
    return 0;
}

// an object's handler: a property the SCRIPT set on the object (`btn.onPush = on_ok`; 14 of 84
// discs, Austin Powers 2's buttons have no other) replaces the RCO's attribute -- a function runs
// with the object as `this` and argument, any other value (`btn.onPush = []`) clears it; with no
// such property the RCO's attribute `a1` (else `a2`: a ubutton's onUp is a button's onFocusUp)
// fires. Returns 1 if the object had a handler of either kind.
static int handler(menu *m, int ni, const char *sname, const char *a1, const char *a2)
{
    if (ni < 0 || m->err[0]) return 0;
    const rco_entry *e = &m->r.e[m->nodes[ni].ent];
    vm_value self = vm_objv(m->nodes[ni].obj), f = vm_get(m->v, m->nodes[ni].obj, sname);
    if (f.t != V_UNDEF) {
        if (!vm_is_func(f)) { mtrace(m, "HANDLER %s.%s: cleared", e->label, sname); return 1; }
        mtrace(m, "HANDLER %s.%s", e->label, sname);
        vm_value r;
        if (vm_call(m->v, f, self, 1, &self, &r)) {
            char w[96];
            snprintf(w, sizeof(w), "%s.%s", e->label, sname);
            call_failed(m, w);
        }
        return 1;
    }
    uint32_t ptr;
    if (a1 && attr_ref(e, a1, &ptr) != REF_NONE) { fire(m, ni, a1); return 1; }
    if (a2 && attr_ref(e, a2, &ptr) != REF_NONE) { fire(m, ni, a2); return 1; }
    return 0;
}

static void set_focus(menu *m, int ni)
{
    if (ni == m->focus) return;
    int old = m->focus;
    m->focus = ni;
    if (ni >= 0 && m->nodes[ni].page >= 0) m->nodes[m->nodes[ni].page].last_focus = ni;
    mtrace(m, "FOCUS %s", ni >= 0 ? m->r.e[m->nodes[ni].ent].label : "-");
    if (old >= 0) handler(m, old, "onFocusOut", "onFocusOut", NULL);
    if (ni >= 0) handler(m, ni, "onFocusIn", "onFocusIn", NULL);
}

// ---- tweens -------------------------------------------------------------------------------------------
static float *prop_of(node *nd, int prop)
{
    switch (prop) {
    case P_POS: return nd->pos;
    case P_COL: return nd->col;
    case P_SIZE: return nd->size;
    case P_SCALE: return nd->scale;
    case P_ROT: return nd->rot;
    case P_CROP: return nd->crop;
    default: return nd->pos;
    }
}
static int prop_n(int prop) { return prop == P_COL || prop == P_CROP ? 4 : 3; }

static void tween_cancel(menu *m, int ni, int prop)
{
    int j = 0;
    for (int i = 0; i < m->ntw; i++) if (!(m->tw[i].node == ni && m->tw[i].prop == prop)) m->tw[j++] = m->tw[i];
    m->ntw = j;
}

static void tween_one(menu *m, int ni, int prop, const float *to, unsigned mask, uint32_t dur);

// ALPHA IS WRITTEN DOWN, NOT INHERITED (fj#69; the maintainer's PSP checks, 2026-10-10). A parent's alpha
// is not multiplied into its children when they are drawn; a WRITE to an object's alpha (an animation's
// Fade or Recolour, a script's setColor / animColor) tweens each of its descendants, over the same time,
// to that descendant's own alpha (base_a: its own last write, else its authored one) times the value
// written. The later write to an object wins, its own or an ancestor's. What the PSP shows:
//   * Hackers: the main menu's four entries are children of Wheel, authored alpha 0, which nothing
//     writes -- the PSP shows them (a drum). The Transporter's buttons under imageless alpha-0 pivots
//     and The Fifth Element's PLAY MOVIE under gpRootPage, the same;
//   * X-Men's Set Up: animMM_To_Setup fades grpSetupLang to 0, then anim_aud_expand fades each language
//     button to 1 and 0.8 -- the PSP shows them (the buttons' own, later writes win);
//   * X-Men's main menu: animMMOpenIntro fades grpMMBtn to 0, holds 13 s, fades it to 0.5 and 0.8 --
//     the PSP's buttons appear after ~13 s, and only the focused one's glow is lit (the glows' own
//     alpha is 0: 0 times 0.8);
//   * The Incredibles: animTransToSetUp fades grpMM to 0 -- its buttons fade out with it on the PSP;
//     back at the main menu grpMM's fade to 1 returns each button to what its script last gave it.
// Multiplying (the rule before) hid the first two; an ancestor's write setting the subtree to the value
// itself lit every X-Men glow; its descendants' AUTHORED alpha times the value (not their own last write)
// lost The Incredibles' buttons on the way back. Colour (RGB) still multiplies: no disc tells it apart.
static void alpha_down(menu *m, int ent, float a, uint32_t dur)
{
    for (int c = m->r.e[ent].first; c >= 0; c = m->r.e[c].next) {
        int di = m->by_ent[c];
        if (di < 0) continue;
        const float to[4] = { 0, 0, 0, m->nodes[di].base_a * a };
        tween_one(m, di, P_COL, to, 8, dur);
        alpha_down(m, c, a, dur);
    }
}

// move property `prop` of node `ni` to `to` (mask: which components, the rest kept) over `dur` ms; an
// alpha written down its subtree (ALPHA IS WRITTEN DOWN, above)
static void tween_start(menu *m, int ni, int prop, const float *to, unsigned mask, uint32_t dur)
{
    tween_one(m, ni, prop, to, mask, dur);
    if (prop == P_COL && (mask & 8)) {
        m->nodes[ni].base_a = to[3];
        alpha_down(m, m->nodes[ni].ent, to[3], dur);
    }
}

static void tween_one(menu *m, int ni, int prop, const float *to, unsigned mask, uint32_t dur)
{
    float *cur = prop_of(&m->nodes[ni], prop);
    int n = prop_n(prop);
    if (dur == 0) { tween_cancel(m, ni, prop); for (int i = 0; i < n; i++) if (mask >> i & 1) cur[i] = to[i]; return; }
    // ANOTHER ANIMATION'S STEP REPLACES (fj#68): an animation's step cancels the running tweens of that
    // property of that node that a DIFFERENT animation started; its own animation's steps and a script's
    // tweens stack with it (rule 3, the later end wins). The Rock's main menu: animRootOpen fires
    // activateMainPage (the focus's onFocusIn again: animPlayFocus) and in the same step starts its 600 ms
    // MoveTos of every row to its unfocused place; animPlayFocus's 400 ms MoveTo of btnPlay to the focused
    // place starts 100 ms later and ended first, so the row ended unfocused -- the PSP shows PLAY focused
    // (the maintainer's photo, 2026-10-08). Family Guy's capture (a script's animColor(1, 250) beside a page
    // animation's 100 ms Recolour to 0.7: lit) is the script / animation pair, which still stacks.
    if (m->tw_src >= 0) {
        int j = 0;
        for (int i = 0; i < m->ntw; i++) {
            const tween *o = &m->tw[i];
            if (o->node == ni && o->prop == prop && o->src >= 0 && o->src != m->tw_src)
                mtrace(m, "TWEEN %s %s: %s's replaced by %s's", m->r.e[m->nodes[ni].ent].label, PROP_NAME[prop],
                       m->r.e[m->nodes[o->src].ent].label, m->r.e[m->nodes[m->tw_src].ent].label);
            else m->tw[j++] = *o;
        }
        m->ntw = j;
    }
    // THE TWEEN TABLE GROWS (fj#69): a fade of a group or a page is a tween on each of its descendants
    // (ALPHA IS WRITTEN DOWN), so its size is a page's, not a count of steps. The library's largest page
    // holds 112 objects (Office Space's pageRoot; Sin City's pageSS 90, Constantine's pageScenes 73, over
    // 252 RCOs, 2026-10-10): two page fades overlapping came within reach of the fixed 256 it was. The
    // RCO bounds a page by its entry count only, so the table doubles as needed, from 256; each growth
    // is traced, and only an allocation failure stops the engine.
    if (m->ntw == m->tw_cap) {
        int cap = m->tw_cap ? m->tw_cap * 2 : 256;
        tween *g = realloc(m->tw, (size_t)cap * sizeof(*g));
        if (!g) { merr(m, "tweens: no memory for %d", cap); return; }
        if (m->tw_cap) mtrace(m, "TWEENS %d running: the table grows to %d", m->ntw, cap);
        m->tw = g; m->tw_cap = cap;
    }
    tween *t = &m->tw[m->ntw++];
    t->node = ni; t->prop = prop; t->n = n; t->t0 = m->now; t->dur = dur; t->src = m->tw_src;
    for (int i = 0; i < n; i++) { t->from[i] = cur[i]; t->to[i] = (mask >> i & 1) ? to[i] : cur[i]; }
}

static void tweens_tick(menu *m)
{
    int j = 0;
    for (int i = 0; i < m->ntw; i++) {
        tween *t = &m->tw[i];
        float f = m->now >= t->t0 + t->dur ? 1.0f : (float)(m->now - t->t0) / (float)t->dur;
        float *cur = prop_of(&m->nodes[t->node], t->prop);
        for (int k = 0; k < t->n; k++) cur[k] = t->from[k] + (t->to[k] - t->from[k]) * f;
        if (f < 1.0f) m->tw[j++] = *t;
        else m->dirty = 1;                       // (its last step: drawn even if no tween is left)
    }
    m->ntw = j;
}

// ---- animations ----------------------------------------------------------------------------------------
static void anim_step(menu *m, anim_run *a);

// AN ANIMATION PLAYS ONCE AT A TIME (P9, the maintainer on the rig, 2026-10-04: MCR disc 2 left
// highlights lit after rapid presses): playing an animation that is still running drops that run --
// its remaining steps, its FireEvents and its Lock -- and starts it afresh on the new object; the
// tweens it already started run on. MCR's animOpenMenu_01 (Recolours at +300 ms, a Recolour and
// FireEvent focusIn at +500, Unlock) was running on one button when the menu video's Loop_HL_ON mark
// re-opened the page and focused another: the old run's +500 steps lit the button focusOut had just
// faded. A model (an RCO animation is one object with one playback), not a capture.
static void anim_play(menu *m, int ni, int target)
{
    const rco_entry *e = &m->r.e[m->nodes[ni].ent];
    for (int i = 0; i < m->nruns; i++)
        if (m->runs[i].node == ni && m->runs[i].cursor >= 0) {
            mtrace(m, "ANIM %s restarted (its run dropped)", e->label);
            m->runs[i].cursor = -1; m->runs[i].locks = 0;
        }
    if (m->nruns == (int)(sizeof(m->runs) / sizeof(m->runs[0]))) { merr(m, "animation runs full (%d)", m->nruns); return; }
    anim_run *a = &m->runs[m->nruns++];
    a->node = ni; a->cursor = e->first; a->wake = m->now; a->target = target; a->locks = 0;
    anim_step(m, a);
}

static void anim_step(menu *m, anim_run *a)
{
    while (a->cursor >= 0 && a->wake <= m->now && !m->err[0]) {
        const rco_entry *e = &m->r.e[a->cursor];
        a->cursor = e->next;
        const char *tn = e->type < RCO_ANIM_NTYPES ? RCO_ANIM_TYPES[e->type].name : "?";
        if (e->type == 7) {                                     // Delay
            float t = attr_f(e, "time", 0.0f);
            a->wake = m->now + (uint32_t)(t * MENU_ANIM_UNIT_MS + 0.5f);
            continue;
        }
        if (e->type == 8) {                                     // FireEvent
            uint32_t ptr, t = attr_ref(e, "event", &ptr);
            if (t == REF_EVENT) {
                const char *ev = rco_event(&m->r, ptr);
                if (ev) run_script_event(m, ev, a->target >= 0 ? vm_objv(m->nodes[a->target].obj) : vm_null(), "FireEvent");
                continue;
            }
            // ... or another ANIMATION (or an object: a focus move), as an event attribute's reference:
            // Alien's animFadeInRootBtns ends in `FireEvent @animBlipRootBtns`, whose run focuses Play
            // Movie -- ignored, the menu kept a ghost button's focus and no key did anything; 43 such
            // references in the library's startup paths (docs/p9.md M4). Played on this run's object
            int en = rco_by_offset(&m->r, ptr), tn = en >= 0 ? m->by_ent[en] : -1;
            if (t == REF_ANIM && tn >= 0) {
                mtrace(m, "EVENT FireEvent -> play %s", m->r.e[en].label);
                int tg = a->target, at = (int)(a - m->runs);
                anim_play(m, tn, tg);
                a = &m->runs[at];                               // (the runs array is fixed: the same run)
            } else if ((t == REF_OBJ || t == REF_OBJ2) && tn >= 0) {
                mtrace(m, "EVENT FireEvent -> focus %s", m->r.e[en].label);
                set_focus(m, tn);
            } else mtrace(m, "ANIM FireEvent ref type 0x%x ignored", t);
            continue;
        }
        // A LOCK BELONGS TO ITS ANIMATION RUN: the keys are locked while a run that Locked still runs;
        // an Unlock (any run's) frees them all; closing the page a run plays on drops its Lock (n_close).
        // Ghost in the Shell 2.0's menuOpen / menuOpen2 / InEffect Lock and end without an Unlock (its
        // RCO has two Unlocks in all): as a flag its chapter menu stayed locked for good (the rig,
        // 2026-10-03). Nirvana opens its root under two Locks and one Unlock; Audioslave's lockKeys is
        // Lock, 44 minutes, Unlock, on the lockScreen its script closes for the main menu; Family Guy's
        // pageDummy is Lock, 3 s, Unlock. The library: 1,854 Locks, 1,690 Unlocks (docs/p9.md M4)
        if (e->type == 9 || e->type == 10) {
            if (e->type == 9) a->locks = 1;
            else for (int i = 0; i < m->nruns; i++) m->runs[i].locks = 0;
            mtrace(m, "ANIM %s (%d)", e->type == 9 ? "lock" : "unlock", keys_locked(m));
            continue;
        }
        // MoveTo / Recolour / Rotate / Resize / Fade / SlideOut: a tween on its object, else on the
        // object the animation was played on
        uint32_t ptr, rt = attr_ref(e, "object", &ptr);
        int te = (rt != REF_NONE) ? rco_by_offset(&m->r, ptr) : -1;
        int tn_i = te >= 0 ? m->by_ent[te] : a->target;
        float dur = attr_f(e, "duration", 0.0f), to[4];
        int accel = (int)attr_f(e, "accelMode", 0.0f);
        mtrace(m, "ANIM %s %s dur %.0f%s", tn, tn_i >= 0 ? m->r.e[m->nodes[tn_i].ent].label : "-", (double)dur,
               accel ? " (accelMode not modelled)" : "");
        if (tn_i < 0) continue;
        uint32_t ms = (uint32_t)(dur * MENU_ANIM_UNIT_MS + 0.5f);
        m->tw_src = a->node;
        switch (e->type) {
        case 2:
            // MoveTo: to (x, y, z), ABSOLUTE -- measured on The Island (the maintainer's photo of its
            // scene selection, 2026-10-02): plnScenesHole lies at posX -900 and `MoveTo x=0` brings it
            // on; leaving, `MoveTo plnUp x=718` / `btnSSMain x=634` return them to their RCO places.
            // (JPCSP's offset reading left the page off screen.)
            to[0] = attr_f(e, "x", 0); to[1] = attr_f(e, "y", 0); to[2] = attr_f(e, "z", 0);
            tween_start(m, tn_i, P_POS, to, 7, ms); break;
        case 3:                                                 // Recolour
            to[0] = attr_f(e, "red", 1); to[1] = attr_f(e, "green", 1); to[2] = attr_f(e, "blue", 1); to[3] = attr_f(e, "alpha", 1);
            tween_start(m, tn_i, P_COL, to, 15, ms); break;
        case 4:                                                 // Rotate
            to[0] = attr_f(e, "x", 0); to[1] = attr_f(e, "y", 0); to[2] = attr_f(e, "z", 0);
            tween_start(m, tn_i, P_ROT, to, 7, ms); break;
        case 5:                                                 // Resize: the scale (Family Guy: 1.1)
            to[0] = attr_f(e, "width", 1); to[1] = attr_f(e, "height", 1); to[2] = attr_f(e, "depth", 1);
            tween_start(m, tn_i, P_SCALE, to, 7, ms); break;
        case 6:     // Fade: `transparency` IS the alpha (no disc of the three; the library's 299 say so by
                    // name: animListButtonVisible opens with transparency 1, animListButtonHide with 0)
            to[3] = attr_f(e, "transparency", 1);
            tween_start(m, tn_i, P_COL, to, 8, ms); break;
        default: break;                                         // SlideOut: traced only
        }
        m->tw_src = -1;
    }
}

static void anims_tick(menu *m)
{
    tweens_tick(m);
    for (int i = 0; i < m->nruns && !m->err[0]; i++) anim_step(m, &m->runs[i]);
    int j = 0;
    for (int i = 0; i < m->nruns; i++) if (m->runs[i].cursor >= 0) m->runs[j++] = m->runs[i];   // (its Lock ends with it)
    if (j != m->nruns) m->dirty = 1;
    m->nruns = j;
}

// ---- natives ------------------------------------------------------------------------------------------
#define NATIVE(fn) static vm_value fn(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
#define M ((menu *)ud)

static void args_str(int argc, const vm_value *argv, char *out, size_t n)
{
    size_t l = 0;
    out[0] = 0;
    for (int i = 0; i < argc && l < n; i++) {
        char b[96];
        l += (size_t)snprintf(out + l, n - l, "%s%s", i ? ", " : "", vm_tostr(argv[i], b, sizeof(b)));
    }
}

static const char *label_of(menu *m, vm_value self)
{
    node *nd = node_of(m, self);
    return nd ? m->r.e[nd->ent].label : "?";
}

NATIVE(n_writeln)
{
    (void)self; (void)v;
    char b[512];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "writeln %s", b);
    return vm_undef();
}

// ---- sounds (P9 M3 C): a soundtable entry's play() / stop() ----------------------------------------
// The sound's channels are decoded once (vag.c: ffmpeg's adpcm_psx, then 48 kHz) and handed to the
// host with a key that names the resource's entry (the host caches where it put them)
static uint32_t sound_key(const menu *m, int ent)
{
    uint32_t h = 2166136261u;                   // FNV-1a over "<resource>#<entry>"
    for (const char *c = m->cur; *c; c++) h = (h ^ (uint8_t)*c) * 16777619u;
    h = (h ^ '#') * 16777619u;
    for (int k = 0; k < 4; k++) h = (h ^ (uint8_t)(ent >> (8 * k))) * 16777619u;
    return h;
}
NATIVE(n_sound_play)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.play()", label_of(M, self));
    if (!nd || !M->snd || !M->h.sound) return vm_undef();
    struct sound_c *s = &M->snd[nd->ent];
    if (!s->tried) {
        s->tried = 1;
        uint32_t fmt, nch, len[2], ns[2] = { 0, 0 }, rate = 0, rate1 = 0;
        const uint8_t *data[2];
        int16_t *pcm[2] = { NULL, NULL };
        if (rco_sound(&M->r, nd->ent, &fmt, &nch, data, len) || fmt != 1)
            mtrace(M, "SOUND %s: not a VAG sound I read", label_of(M, self));
        else if (vag_decode(data[0], len[0], &pcm[0], &ns[0], &rate) ||
                 (nch == 2 && vag_decode(data[1], len[1], &pcm[1], &ns[1], &rate1)) || (nch == 2 && rate1 != rate))
            mtrace(M, "SOUND %s: not decoded", label_of(M, self));
        else {
            const int16_t *const ch[2] = { pcm[0], pcm[1] };
            if (vag_to_48k(ch, ns, (int)nch, rate, &s->pcm, &s->frames)) s->pcm = NULL;
            else s->nch = (int)nch;
        }
        free(pcm[0]); free(pcm[1]);
    }
    if (s->pcm && s->frames) M->h.sound(M->h.ud, sound_key(M, nd->ent), s->pcm, s->frames, s->nch);
    return vm_undef();
}
NATIVE(n_sound_stop)
{
    (void)v; (void)argc; (void)argv;
    mtrace(M, "%s.stop()", label_of(M, self));
    if (M->h.sound) M->h.sound(M->h.ud, 0, NULL, 0, 0);
    return vm_undef();
}


static vm_value pos_method(menu *m, vm_value self, int argc, const vm_value *argv, const char *name, int which, int anim)
{
    node *nd = node_of(m, self);
    char b[512];
    args_str(argc, argv, b, sizeof(b));
    mtrace(m, "%s.%s(%s)", nd ? m->r.e[nd->ent].label : "?", name, b);
    if (!nd) return vm_undef();
    // set*(values...) applies at once; anim*(values..., ms) tweens over its LAST argument
    int prop = which == 0 ? P_POS : which == 1 ? P_COL : which == 2 ? P_SIZE : which == 3 ? P_SCALE : which == 4 ? P_ROT : P_CROP;
    int n = prop_n(prop), nv = anim ? argc - 1 : argc;
    float to[4] = { 0, 0, 0, 0 };
    unsigned mask = 0;
    for (int i = 0; i < n && i < nv; i++) { to[i] = vm_tonum(argv[i]); mask |= 1u << i; }
    uint32_t ms = (anim && argc > 0) ? (uint32_t)fmaxf(vm_tonum(argv[argc - 1]), 0.0f) : 0;
    if (!anim) tween_cancel(m, (int)(nd - m->nodes), prop);
    // A SCRIPT'S TWEEN REPLACES (P9 M4b, 2026-10-04): an animXxx() call cancels the running tweens of that
    // property of that node (an animation's included), from where they have got to; an animation's own steps
    // stack, as before. MCR disc 2: its focus animation's long Recolours (500-800 ms) outlived focusOut's
    // animColor(..., 0, 100) and lit the highlight again ("the highlights don't clear", the maintainer on the
    // rig). Family Guy: its focus script's animColor(1, 250) and a page animation's 100 ms Recolour to 0.7
    // start in one instant on the focused episode, and the PSP capture shows it lit -- an animation's step
    // does not replace a script's tween (one rule for every step would have it 0.7).
    // A SCRIPT'S ROTATION TAKES THE SHORT WAY (P9 M4b, the maintainer on the rig, 2026-10-04): an
    // animRotate() target is reached by the turn of at most half a circle from where the object is.
    // Astro Boy's drum script normalises its targets into (-pi, pi] (from -pi a quarter turn on is
    // +pi/2): a straight tween spun the drum three quarters backwards at the wrap. An animation's
    // Rotate step stays literal (X-Men's grpMMBtn turns z -6.28, a full turn, over 2.2 s).
    if (anim && prop == P_ROT) {
        const float *cur = nd->rot;
        for (int i = 0; i < 3; i++) if (mask >> i & 1) {
            float d = remainderf(to[i] - cur[i], 6.2831853f);     // (-pi, pi]
            to[i] = cur[i] + d;
        }
    }
    tween_cancel(m, (int)(nd - m->nodes), prop);
    tween_start(m, (int)(nd - m->nodes), prop, to, mask, ms);
    return vm_undef();
}

NATIVE(n_setPos)     { (void)v; return pos_method(M, self, argc, argv, "setPos", 0, 0); }
NATIVE(n_animPos)    { (void)v; return pos_method(M, self, argc, argv, "animPos", 0, 1); }
NATIVE(n_setColor)   { (void)v; return pos_method(M, self, argc, argv, "setColor", 1, 0); }
NATIVE(n_animColor)  { (void)v; return pos_method(M, self, argc, argv, "animColor", 1, 1); }
NATIVE(n_setSize)    { (void)v; return pos_method(M, self, argc, argv, "setSize", 2, 0); }
NATIVE(n_animSize)   { (void)v; return pos_method(M, self, argc, argv, "animSize", 2, 1); }
NATIVE(n_setScale)   { (void)v; return pos_method(M, self, argc, argv, "setScale", 3, 0); }
NATIVE(n_animScale)  { (void)v; return pos_method(M, self, argc, argv, "animScale", 3, 1); }
NATIVE(n_setRotate)  { (void)v; return pos_method(M, self, argc, argv, "setRotate", 4, 0); }
NATIVE(n_animRotate) { (void)v; return pos_method(M, self, argc, argv, "animRotate", 4, 1); }
// setCrop / animCrop (x, y, w, h): 8 discs; Matrix Reloaded crops the left / right half (0, 0, 0.5, 1)
// / (0.5, 0, 0.5, 1), Toy Story a strip (0, 0.915, 1, 0.025), the common wipe (0, 0, 1, 0) -> (0, 0,
// 1, 1) -> (0, 1, 1, 0). The part is drawn IN PLACE, the texture not stretched over the object: a
// MODEL (a wipe reads so), until a capture of one of them
NATIVE(n_setCrop)    { (void)v; return pos_method(M, self, argc, argv, "setCrop", 5, 0); }
NATIVE(n_animCrop)   { (void)v; return pos_method(M, self, argc, argv, "animCrop", 5, 1); }

// getPos / getSize / getColor / getScale: an ARRAY (the library reads them by index: getPos()[1]
// 221 times, getSize()[0] 101, getColor()[3] 37; JPCSP's getPos fills 0..2), also carrying the
// named fields a few scripts read (.x 26, .y 23, .width 5)
static vm_value triple(vm *v, const float *x, int n, const char *k0, const char *k1, const char *k2, const char *k3)
{
    vm_obj *o = vm_new_array(v, 0);
    if (!o) return vm_undef();
    for (int i = 0; i < n; i++) vm_array_push(v, o, vm_num(x[i]));
    vm_set(v, o, k0, vm_num(x[0])); vm_set(v, o, k1, vm_num(x[1])); vm_set(v, o, k2, vm_num(x[2]));
    if (n > 3) vm_set(v, o, k3, vm_num(x[3]));
    return vm_objv(o);
}
// A BUSY-WAIT: Austin Powers in Goldmember's delay is `picto.animPos(200, 0, 0, ms)` then
// `while (picto.getPos()[0] != 200) {}` -- on the PSP the animation moves while the script spins. A
// get* of an object with a tween running therefore advances the clock 1 ms a poll (the tweens with
// it), so the wait ends after the animation's own duration; the clock runs ahead by that much and
// menu_tick absorbs it from the next real time. What the script does after its wait comes early in
// real time by the wait; its later timers are not. (The PSP shows the frames of the wait; the
// engine draws its end.) Traced once a streak, not a line a poll.
#define BUSY_MAX_MS 600000u
static int busy_poll(menu *m, node *nd)
{
    int ni = (int)(nd - m->nodes), moving = 0;
    for (int i = 0; i < m->ntw && !moving; i++) moving = m->tw[i].node == ni;
    if (!moving || m->debt >= BUSY_MAX_MS) return 0;
    m->now++; m->debt++;
    tweens_tick(m);
    m->dirty = 1;
    if (m->poll_node != ni) {
        mtrace(m, "BUSY-WAIT on %s (a script polling a moving object: 1 ms a poll)", m->r.e[nd->ent].label);
        m->poll_node = ni;
    }
    return 1;
}
static vm_value get_prop(menu *m, vm *v, vm_value self, const char *name, int prop)
{
    node *nd = node_of(m, self);
    if (!nd || !busy_poll(m, nd)) mtrace(m, "%s.%s()", label_of(m, self), name);
    if (!nd) return vm_undef();
    switch (prop) {
    case P_POS:   return triple(v, nd->pos, 3, "x", "y", "z", NULL);
    case P_COL:   return triple(v, nd->col, 4, "red", "green", "blue", "alpha");
    case P_SCALE: return triple(v, nd->scale, 3, "width", "height", "depth", NULL);
    case P_ROT:   return triple(v, nd->rot, 3, "x", "y", "z", NULL);
    default:      return triple(v, nd->size, 3, "width", "height", "depth", NULL);
    }
}
NATIVE(n_getPos)    { (void)argc; (void)argv; return get_prop(M, v, self, "getPos", P_POS); }
NATIVE(n_getColor)  { (void)argc; (void)argv; return get_prop(M, v, self, "getColor", P_COL); }
NATIVE(n_getScale)  { (void)argc; (void)argv; return get_prop(M, v, self, "getScale", P_SCALE); }
NATIVE(n_getRotate) { (void)argc; (void)argv; return get_prop(M, v, self, "getRotate", P_ROT); }
NATIVE(n_getSize)   { (void)argc; (void)argv; return get_prop(M, v, self, "getSize", P_SIZE); }

NATIVE(n_setFocus)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.setFocus()", label_of(M, self));
    M->n_focus_set++;                       // (a script's own focus: open() keeps it, n_open)
    if (nd) set_focus(M, (int)(nd - M->nodes));
    return vm_undef();
}

NATIVE(n_show)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.show()", label_of(M, self));
    if (nd) nd->visible = 1;
    return vm_undef();
}
NATIVE(n_hide)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.hide()", label_of(M, self));
    if (nd) nd->visible = 0;
    return vm_undef();
}

// an object's authored attributes (its RCO entry's): at the build, and again at each open() of
// its page (n_open)
static int node_reset(menu *m, node *nd)
{
    const rco_entry *e = &m->r.e[nd->ent];
    float p[3] = { 0, 0, 0 }, c[4] = { 1, 1, 1, 1 }, z[3] = { 0, 0, 0 }, s[3] = { 1, 1, 1 }, r[3] = { 0, 0, 0 }, k[4] = { 0, 0, 1, 1 };
    if (e->table == RCO_T_OBJECT) {
        p[0] = attr_f(e, "posX", 0); p[1] = attr_f(e, "posY", 0); p[2] = attr_f(e, "posZ", 0);
        c[0] = attr_f(e, "redScale", 1); c[1] = attr_f(e, "greenScale", 1); c[2] = attr_f(e, "blueScale", 1); c[3] = attr_f(e, "alphaScale", 1);
        z[0] = attr_f(e, "width", 0); z[1] = attr_f(e, "height", 0); z[2] = attr_f(e, "depth", 0);
        s[0] = attr_f(e, "scaleWidth", 1); s[1] = attr_f(e, "scaleHeight", 1); s[2] = attr_f(e, "scaleDepth", 1);
    }
    int changed = memcmp(nd->pos, p, sizeof(p)) || memcmp(nd->col, c, sizeof(c)) || memcmp(nd->size, z, sizeof(z)) ||
                  memcmp(nd->scale, s, sizeof(s)) || memcmp(nd->rot, r, sizeof(r)) || memcmp(nd->crop, k, sizeof(k));
    nd->base_a = c[3];
    memcpy(nd->pos, p, sizeof(p)); memcpy(nd->col, c, sizeof(c)); memcpy(nd->size, z, sizeof(z));
    memcpy(nd->scale, s, sizeof(s)); memcpy(nd->rot, r, sizeof(r)); memcpy(nd->crop, k, sizeof(k));
    (void)m;
    return changed;
}

// a page: open() fires onInit and shows it, focusing its first button (as JPCSP's PageObject;
// Family Guy depends on it: its menu opens with Ep01 lit, and its episode page takes the focus from
// the btnMMTmpFocus it parks it on. Narrowed to "only if no open page holds the focus", Family
// Guy's Play button never gets it. Austin Powers 2 opens seven pages in a row, each move firing its
// script-set onFocusIn / onFocusOut, then sets its focus itself: the same end state); activate()
// fires onActivate and makes it the page that takes Circle (onCancel); close() hides it
static int first_button(menu *m, int ent)
{
    for (int c = m->r.e[ent].first; c >= 0; c = m->r.e[c].next) {
        if (m->r.e[c].table == RCO_T_OBJECT && (m->r.e[c].type == 26 || m->r.e[c].type == 3)) return m->by_ent[c];
        int d = first_button(m, c);
        if (d >= 0) return d;
    }
    return -1;
}
NATIVE(n_open)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.open()", label_of(M, self));
    if (!nd) return self;
    // OPEN BUILDS THE PAGE AFRESH: its objects (the page's own colour too, which an animation played
    // on its root tweens) are back at their authored attributes, the tweens on them dropped. Family
    // Guy leaves an episode page through CloseEpisodePage01, `animEpisodeToRoot.play(pageEpisode.root)`
    // -- a Recolour to alpha 0 -- and its next open's onInit fades plnEPxx in from the authored 0, its
    // onActivate the buttons to 0.7: the PSP shows the page again (the maintainer's, every episode);
    // kept, the page stayed at alpha 0, a black screen (the rig, 2026-10-03). A page whose objects
    // differed is traced (RESET), so a disc that sets one before its open shows in a sweep. Only a
    // CLOSED page is built afresh: Austin Powers 2 calls pageRootMenu.open() again and again while it
    // is up, setting its objects between the calls (the rig, 2026-10-03) -- an open page is left as
    // it is, as before the rule (what its captures were matched with)
    if (nd->table == RCO_T_OBJECT && nd->type == 1 && !nd->visible) {
        int pi = (int)(nd - M->nodes), n = 0;
        for (int i = 0; i < M->nnodes; i++) {
            if (i != pi && M->nodes[i].page != pi) continue;
            node *c = &M->nodes[i];
            int hid = i != pi && c->table == RCO_T_OBJECT && c->type != 1 && !c->visible;   // (hide())
            if (hid) c->visible = 1;
            n += node_reset(M, c) | hid;
            int j = 0;
            for (int t = 0; t < M->ntw; t++) if (M->tw[t].node != i) M->tw[j++] = M->tw[t];
            M->ntw = j;
        }
        if (n) mtrace(M, "RESET %s: %d objects back at their authored attributes", label_of(M, self), n);
        // ... and a focus held in it is gone with its widgets (no onFocusOut): the first button's focus
        // below fires its onFocusIn again, as on a page built new. Akira: Square in the film reopens
        // pageRoot with btnPlay's focus left from before the film; its onFocusIn lights PLAY's overlay
        // (the capture at 1:35: PLAY lit), which the reset had put back at its authored alpha 0
        if (M->focus >= 0 && (M->focus == pi || M->nodes[M->focus].page == pi)) {
            mtrace(M, "FOCUS - (%s built afresh)", label_of(M, self));
            M->focus = -1;
        }
        M->dirty = 1;
    }
    // onInit only when the page OPENS (closed -> open): Die Hard's onInit_pageRoot calls
    // pageRoot.open() itself, which fired onInit again without end (the engine stopped on its
    // animation bound; the disc works on a PSP, so the PSP cannot fire it again: docs/p9.md M4)
    int was_open = nd->visible;
    nd->visible = 1;
    // ... and the first button's focus is the page's DEFAULT: a focus its onInit set (directly or
    // through what it calls -- Godzilla Final Wars' onInit_RootMenu activates the page, whose
    // onActivate focuses RootMenuButton) stands; taken over, the focus sat on RootMenuLock, which
    // takes no key, and the menu was dead (docs/p9.md M4)
    uint32_t fset = M->n_focus_set;
    if (!was_open || nd->table != RCO_T_OBJECT || nd->type != 1) fire(M, (int)(nd - M->nodes), "onInit");
    int b = first_button(M, nd->ent);
    if (b >= 0 && !M->err[0] && M->n_focus_set == fset) set_focus(M, b);
    // (FOCUS AT ACTIVATION, n_activate: the focus this open gave the page, its onFocusIn delivered now)
    if (!was_open && nd->table == RCO_T_OBJECT && nd->type == 1) {
        int pi = (int)(nd - M->nodes);
        nd->fi_pending = (M->focus >= 0 && M->nodes[M->focus].page == pi && M->active_page != pi) ? M->focus : -1;
        nd->fi_t = M->now;
    }
    return self;
}
NATIVE(n_activate)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.activate()", label_of(M, self));
    if (!nd) return self;
    M->active_page = (int)(nd - M->nodes);
    // A FOCUS PER PAGE: the keys go to the active page's own focus, so activating a page brings back
    // the button it last had -- before its onActivate, which may move it on (Akira: Circle in the AUDIO
    // pop-up runs `pageRoot.activate()` alone, and the next Cross is AUDIO's again -- the PSP closes the
    // pop-up "without making a choice" (the maintainer, 2026-10-02); its Left / Right set
    // RootButtonFocus, which onActivate_pageRoot then focuses, `== '[object Button]'`)
    if (nd->last_focus >= 0 && (M->focus < 0 || M->nodes[M->focus].page != M->active_page)) set_focus(M, nd->last_focus);
    // FOCUS AT ACTIVATION (docs/p9.md M4e, the maintainer's rig session 2026-10-07: X2, Aliens): a page
    // opened in one instant and activated in a later one gets its focused object's onFocusIn again, once,
    // at the activation. X2's OnFocusInBtn lights a button only once g_AppState names the page, which the
    // script sets as it activates it, 2.8 s after open(); Aliens' opening animations recolour the focused
    // button back to its idle colour after open() and end in pg_mm.activate() / pg_la.activate(). The
    // PSP shows both lit, so its focus-in arrives at (or again at) the activation. A page opened and
    // activated in the same instant -- most of the library -- is untouched (no second rollover sound).
    // A MODEL from those discs' scripts and the maintainer's observation (no capture of it)
    if (nd->fi_pending >= 0 && M->focus == nd->fi_pending && M->now != nd->fi_t && !M->err[0]) {
        mtrace(M, "FOCUS %s: onFocusIn again at its page's activation", M->r.e[M->nodes[M->focus].ent].label);
        handler(M, M->focus, "onFocusIn", "onFocusIn", NULL);
    }
    nd->fi_pending = -1;
    fire(M, M->active_page, "onActivate");
    return self;
}
NATIVE(n_close)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.close()", label_of(M, self));
    if (nd) { nd->visible = 0; nd->fi_pending = -1; }
    // A PAGE'S ANIMATIONS END WITH IT (the maintainer on the rig, 2026-10-10): a run played on the page
    // (its root) or on an object in it stops when the page closes -- its later steps and FireEvents
    // with it, its Lock freed. The Animatrix's main menu plays mainTimer on its root (Delay 60000, then
    // a fade to black and FireEvent TimeOut, which plays the first segment); choosing a segment from the
    // chapter page closes main_menu, and the timer, left running, cut to The Final Flight of the Osiris a
    // minute after the main menu opened, twice in one session. No script stops it, so on the PSP the
    // close must. (Before this only the run's Lock was dropped: Audioslave's lockKeys, Lock / 44 min /
    // Unlock on the lockScreen its script closes.) A run ended inside its own FireEvent stops there:
    // anim_step's loop reads the cursor after the event.
    int pi = nd ? (int)(nd - M->nodes) : -1;
    for (int i = 0; nd && i < M->nruns; i++) {
        anim_run *r = &M->runs[i];
        int t = r->target;
        if (r->cursor >= 0 && t >= 0 && (t == pi || M->nodes[t].page == pi)) {
            mtrace(M, "ANIM %s stopped (its page closed)%s", M->r.e[M->nodes[r->node].ent].label, r->locks ? ": unlock" : "");
            r->cursor = -1;
            r->locks = 0;
        }
    }
    return vm_undef();
}

NATIVE(n_anim_play)
{
    (void)v;
    node *nd = node_of(M, self);
    char b[256];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "%s.play(%s)", label_of(M, self), b);
    if (!nd) return vm_undef();
    if (nd->table == RCO_T_ANIM) {
        node *t = argc > 0 ? node_of(M, argv[0]) : NULL;
        anim_play(M, (int)(nd - M->nodes), t ? (int)(t - M->nodes) : -1);
    }
    return vm_undef();
}
NATIVE(n_anim_stop)
{
    (void)v; (void)argc; (void)argv;
    node *nd = node_of(M, self);
    mtrace(M, "%s.stop()", label_of(M, self));
    if (nd) for (int i = 0; i < M->nruns; i++) if (M->runs[i].node == (int)(nd - M->nodes)) M->runs[i].cursor = -1;
    return vm_undef();
}

// ---- movieplayer ----------------------------------------------------------------------------------------
NATIVE(n_mp_play)
{
    (void)v; (void)self;
    menu_play p;
    memset(&p, 0, sizeof(p));
    char b[512];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "movieplayer.play(%s)", b);
    p.n = argc > 12 ? 12 : argc;
    for (int i = 0; i < p.n; i++) p.a[i] = vm_tonum(argv[i]);
    if (M->h.play) M->h.play(M->h.ud, &p);
    return vm_undef();
}
NATIVE(n_mp_stop)   { (void)v; (void)self; char b[256]; args_str(argc, argv, b, sizeof(b)); mtrace(M, "movieplayer.stop(%s)", b); if (M->h.stop) M->h.stop(M->h.ud); return vm_undef(); }
NATIVE(n_mp_resume)
{
    (void)v; (void)self; (void)argc; (void)argv;
    int r = M->h.resume ? M->h.resume(M->h.ud) : -1;
    mtrace(M, "movieplayer.resume() -> %d", r);
    return vm_num((float)r);
}

static vm_value status_obj(vm *v, const menu_status *s)
{
    vm_obj *o = vm_new_object(v, "PlayerStatus");
    if (!o) return vm_undef();
    vm_set(v, o, "playListNumber", vm_num((float)s->playlist));
    vm_set(v, o, "chapterNumber", vm_num((float)s->chapter));
    vm_set(v, o, "videoNumber", vm_num((float)s->video));
    vm_set(v, o, "audioNumber", vm_num((float)s->audio));
    vm_set(v, o, "audioFlag", vm_num((float)s->audio_flag));
    vm_set(v, o, "subtitleNumber", vm_num((float)s->subtitle));
    vm_set(v, o, "subtitleFlag", vm_num((float)s->subtitle_flag));
    vm_set(v, o, "playStatus", vm_num(s->playing ? (s->paused ? 2.0f : 1.0f) : 0.0f));
    vm_set(v, o, "menuMode", vm_num((float)(s->menu_mode != 0)));
    return vm_objv(o);
}
NATIVE(n_mp_status)
{
    (void)self; (void)argc; (void)argv;
    menu_status s;
    memset(&s, 0, sizeof(s));
    if (M->h.status) M->h.status(M->h.ud, &s);
    mtrace(M, "movieplayer.getPlayerStatus() -> playing %d playlist %d chapter %d", s.playing, s.playlist, s.chapter);
    return status_obj(v, &s);
}
NATIVE(n_mp_getresume)
{
    (void)self; (void)argc; (void)argv;
    menu_status s;
    memset(&s, 0, sizeof(s));
    int kept = M->h.resume_info && M->h.resume_info(M->h.ud, &s) == 0;
    if (kept) mtrace(M, "movieplayer.getResumeInfo() -> playlist %d chapter %d", s.playlist, s.chapter);
    else mtrace(M, "movieplayer.getResumeInfo() -> none");
    return kept ? status_obj(v, &s) : vm_undef();
}
NATIVE(n_mp_changeresume)
{
    (void)v; (void)self;
    char b[256];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "movieplayer.changeResumeInfo(%s)", b);
    if (argc >= 5 && M->h.change_resume) {
        menu_status s;
        memset(&s, 0, sizeof(s));
        s.video = vm_toint(argv[0]); s.audio = vm_toint(argv[1]); s.audio_flag = vm_toint(argv[2]);
        s.subtitle = vm_toint(argv[3]); s.subtitle_flag = vm_toint(argv[4]);
        M->h.change_resume(M->h.ud, &s);
    }
    return vm_undef();
}
// the movie window (the scene's space: setPos the centre, setSize the size; Austin Powers 2 sets
// (0, 0) and 854 x 480 for the whole screen); M3 hands it to the fabric's video window (P9-5)
NATIVE(n_mp_setpos)
{
    (void)v; (void)self;
    char b[256];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "movieplayer.setPos(%s)", b);
    if (argc >= 2) { M->video[0] = vm_tonum(argv[0]); M->video[1] = vm_tonum(argv[1]); }
    return vm_undef();
}
NATIVE(n_mp_setsize)
{
    (void)v; (void)self;
    char b[256];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "movieplayer.setSize(%s)", b);
    if (argc >= 2) { M->video[2] = vm_tonum(argv[0]); M->video[3] = vm_tonum(argv[1]); }
    return vm_undef();
}

// ... and read back (The Island's scene selection: `movieplayer.getSize()[0] != 854`), arrays as a
// plane's getPos / getSize
NATIVE(n_mp_getpos)
{
    (void)argc; (void)argv; (void)self;
    float x[3] = { M->video[0], M->video[1], 0.0f };
    mtrace(M, "movieplayer.getPos()");
    return triple(v, x, 3, "x", "y", "z", NULL);
}
NATIVE(n_mp_getsize)
{
    (void)argc; (void)argv; (void)self;
    float x[3] = { M->video[2], M->video[3], 0.0f };
    mtrace(M, "movieplayer.getSize()");
    return triple(v, x, 3, "width", "height", "depth", NULL);
}

void menu_video_window(const menu *m, float *x, float *y, float *w, float *h)
{
    *x = m->video[0]; *y = m->video[1]; *w = m->video[2]; *h = m->video[3];
}

// ---- controller ----------------------------------------------------------------------------------------
static char *dupstr(const char *s)       // (strdup is POSIX, not C99)
{
    size_t n = strlen(s) + 1;
    char *d = (char *)malloc(n);
    if (d) memcpy(d, s, n);
    return d;
}

static void kept_free(kept *k)
{
    free(k->s);
    for (int i = 0; i < k->nkids; i++) { kept_free(&k->kids[i]); if (k->keys) free(k->keys[i]); }
    free(k->kids); free(k->keys);
    memset(k, 0, sizeof(*k));
}
static void keep_value(vm *v, vm_value x, kept *k, int depth)
{
    memset(k, 0, sizeof(*k));
    k->t = x.t;
    if (x.t == V_NUM) k->n = x.u.n;
    else if (x.t == V_BOOL) k->b = x.u.b;
    else if (x.t == V_STR) k->s = dupstr(x.u.o->s);
    else if (x.t == V_OBJ && depth < 8 && !x.u.o->host) {
        vm_obj *o = x.u.o;
        k->is_array = (o->kind == O_ARRAY);
        k->nkids = (int)(k->is_array ? o->nel : o->nprops);
        k->kids = (kept *)calloc((size_t)(k->nkids ? k->nkids : 1), sizeof(kept));
        if (!k->is_array) k->keys = (char **)calloc((size_t)(k->nkids ? k->nkids : 1), sizeof(char *));
        for (int i = 0; i < k->nkids; i++) {
            if (k->is_array) keep_value(v, o->el[i], &k->kids[i], depth + 1);
            else { k->keys[i] = dupstr(o->props[i].key->s); keep_value(v, o->props[i].val, &k->kids[i], depth + 1); }
        }
    } else k->t = V_UNDEF;           // a scene object / a function: not kept (none seen)
}
static vm_value restore_value(vm *v, const kept *k)
{
    switch (k->t) {
    case V_NULL: return vm_null();
    case V_NUM:  return vm_num(k->n);
    case V_BOOL: return vm_bool(k->b);
    case V_STR:  return vm_str(v, k->s);
    case V_OBJ: {
        vm_obj *o = k->is_array ? vm_new_array(v, 0) : vm_new_object(v, NULL);
        if (!o) return vm_undef();
        for (int i = 0; i < k->nkids; i++) {
            if (k->is_array) vm_array_push(v, o, restore_value(v, &k->kids[i]));
            else vm_set(v, o, k->keys[i], restore_value(v, &k->kids[i]));
        }
        return vm_objv(o);
    }
    default: return vm_undef();
    }
}
NATIVE(n_ctl_getuser)
{
    (void)self; (void)argc; (void)argv;
    mtrace(M, "controller.getUserData() -> %s", M->has_userdata ? "kept" : "none");
    return M->has_userdata ? restore_value(v, &M->userdata) : vm_undef();
}
NATIVE(n_ctl_setuser)
{
    (void)self;
    char b[256];
    args_str(argc, argv, b, sizeof(b));
    mtrace(M, "controller.setUserData(%s)", b);
    kept_free(&M->userdata);
    if (argc > 0) { keep_value(v, argv[0], &M->userdata, 0); M->has_userdata = 1; }
    if (M->h.kept_changed) M->h.kept_changed(M->h.ud);
    return vm_bool(1);
}
NATIVE(n_ctl_change)
{
    (void)v; (void)self;
    char b[64] = "";
    if (argc > 0) vm_tostr(argv[0], b, sizeof(b));
    mtrace(M, "controller.changeResource(%s)", b);
    snprintf(M->next_res, sizeof(M->next_res), "%s", b);
    return vm_bool(1);
}
// controller.end(): 48 of 84 scripts call it when the feature ends (Akira, Kill Bill, Gone in 60
// Seconds: `if (controller.end()) OpenRoot_Normal();` -- true opens the disc's menu; 28 Days Later
// ignores the answer). True: MEASURED, Akira's film end goes to its menu on the PSP (the maintainer,
// 2026-10-02; docs/p9.md M3 E1).
NATIVE(n_ctl_end)
{
    (void)v; (void)self; (void)argc; (void)argv;
    mtrace(M, "controller.end() -> true (the disc's menu)");
    return vm_bool(1);
}

// ---- timer, Math, globals --------------------------------------------------------------------------------
NATIVE(n_setinterval)
{
    (void)v; (void)self;
    if (argc < 2 || !vm_is_func(argv[0])) { mtrace(M, "timer.setInterval: not a function"); return vm_num(-1.0f); }
    if (M->ntimers == (int)(sizeof(M->timers) / sizeof(M->timers[0]))) { merr(M, "timers full (%d)", M->ntimers); return vm_num(-1.0f); }
    timer_s *t = &M->timers[M->ntimers++];
    t->id = ++M->next_timer;
    t->period = (uint32_t)(vm_tonum(argv[1]) > 1.0f ? vm_tonum(argv[1]) : 1.0f);
    t->due = M->now + t->period;
    t->fn = argv[0].u.o;
    vm_root_add(v, t->fn);
    t->nargs = 0;
    for (int i = 2; i < argc && t->nargs < 8; i++) {
        t->args[t->nargs++] = argv[i];
        if (argv[i].t == V_OBJ || argv[i].t == V_STR) vm_root_add(v, argv[i].u.o);
    }
    mtrace(M, "timer.setInterval(%u ms) -> %d", t->period, t->id);
    return vm_num((float)t->id);
}
NATIVE(n_clearinterval)
{
    (void)self;
    int id = argc > 0 ? vm_toint(argv[0]) : -1;
    mtrace(M, "timer.clearInterval(%d)", id);
    for (int i = 0; i < M->ntimers; i++) if (M->timers[i].id == id) {
        vm_root_del(v, M->timers[i].fn);
        for (int k = 0; k < M->timers[i].nargs; k++)
            if (M->timers[i].args[k].t == V_OBJ || M->timers[i].args[k].t == V_STR) vm_root_del(v, M->timers[i].args[k].u.o);
        M->timers[i] = M->timers[--M->ntimers];
        break;
    }
    return vm_undef();
}
NATIVE(n_floor)  { (void)v; (void)self; (void)ud; return vm_num(argc ? floorf(vm_tonum(argv[0])) : NAN); }
NATIVE(n_ceil)   { (void)v; (void)self; (void)ud; return vm_num(argc ? ceilf(vm_tonum(argv[0])) : NAN); }
NATIVE(n_round)  { (void)v; (void)self; (void)ud; return vm_num(argc ? floorf(vm_tonum(argv[0]) + 0.5f) : NAN); }
NATIVE(n_abs)    { (void)v; (void)self; (void)ud; return vm_num(argc ? fabsf(vm_tonum(argv[0])) : NAN); }
NATIVE(n_sin)    { (void)v; (void)self; (void)ud; return vm_num(argc ? sinf(vm_tonum(argv[0])) : NAN); }
NATIVE(n_cos)    { (void)v; (void)self; (void)ud; return vm_num(argc ? cosf(vm_tonum(argv[0])) : NAN); }
NATIVE(n_sqrt)   { (void)v; (void)self; (void)ud; return vm_num(argc ? sqrtf(vm_tonum(argv[0])) : NAN); }
NATIVE(n_min)    { (void)v; (void)self; (void)ud; float r = INFINITY; for (int i = 0; i < argc; i++) r = fminf(r, vm_tonum(argv[i])); return vm_num(r); }
NATIVE(n_max)    { (void)v; (void)self; (void)ud; float r = -INFINITY; for (int i = 0; i < argc; i++) r = fmaxf(r, vm_tonum(argv[i])); return vm_num(r); }
NATIVE(n_random) { (void)v; (void)self; (void)ud; (void)argc; (void)argv; return vm_num((float)rand() / ((float)RAND_MAX + 1.0f)); }
NATIVE(n_parseint)   { (void)v; (void)self; (void)ud; return argc ? vm_num(truncf(vm_tonum(argv[0]))) : vm_num(NAN); }
NATIVE(n_parsefloat) { (void)v; (void)self; (void)ud; return argc ? vm_num(vm_tonum(argv[0])) : vm_num(NAN); }
NATIVE(n_isnan)      { (void)v; (void)self; (void)ud; float f = argc ? vm_tonum(argv[0]) : NAN; return vm_bool(f != f); }

static void natf(menu *m, vm_obj *o, const char *name, vm_native fn)
{
    vm_set(m->v, o, name, vm_objv(vm_new_native(m->v, name, fn, m)));
}

// ---- the resource tables ---------------------------------------------------------------------------------
static vm_obj *proto_for(menu *m, const rco_entry *e)
{
    if (e->table == RCO_T_ANIM) return m->proto_anim;
    if (e->table == RCO_T_SOUND) return m->proto_sound;
    if (e->table == RCO_T_IMAGE) return m->proto_image;
    if (e->table == RCO_T_OBJECT && e->type == 1) return m->proto_page;
    return m->proto_obj;
}

// make the script objects of the entries under `ent` (a table, or an object), labelled into `holder`
static void build(menu *m, int ent, vm_obj *holder, int page, vm_obj *parent)
{
    int i = 0;
    for (int c = m->r.e[ent].first; c >= 0; c = m->r.e[c].next, i++) {
        const rco_entry *e = &m->r.e[c];
        if (m->nnodes >= m->r.n) break;
        node *nd = &m->nodes[m->nnodes];
        memset(nd, 0, sizeof(*nd));
        nd->ent = c; nd->table = e->table; nd->type = e->type; nd->page = page; nd->last_focus = -1; nd->fi_pending = -1;
        m->by_ent[c] = m->nnodes++;
        // (a UButton's string form is "[object Button]" on the PSP: Akira restores its focus when the
        // pop-up closes with `if (RootButtonFocus == '[object Button]') RootButtonFocus.setFocus()`)
        const char *cls = (e->table == RCO_T_OBJECT && e->type == 26) ? "Button" :
                          (e->table == RCO_T_OBJECT && e->type < RCO_OBJ_NTYPES) ? RCO_OBJ_TYPES[e->type].name :
                          (e->table == RCO_T_ANIM && e->type < RCO_ANIM_NTYPES) ? RCO_ANIM_TYPES[e->type].name :
                          e->table == RCO_T_SOUND ? "Sound" : e->table == RCO_T_IMAGE ? "Image" : "Entry";
        vm_obj *o = vm_new_object(m->v, cls);
        if (!o) return;
        o->host = nd; o->proto = proto_for(m, e);
        nd->obj = o; nd->holder = o;
        if (e->table == RCO_T_OBJECT) nd->visible = e->type != 1;     // objects show; a page shows once opened
        node_reset(m, nd);
        char lab[16];
        const char *name = e->label[0] ? e->label : (snprintf(lab, sizeof(lab), "%04d", i), lab);
        vm_set(m->v, o, "name", vm_str(m->v, name));
        // `parent`: the object whose `children` holds it (a page's root for the page's own; Kill Bill's
        // `this.parent.children["plnMM" + this.name.substring(5)]`)
        if (parent) vm_set(m->v, o, "parent", vm_objv(parent));
        if (holder->kind == O_ARRAY) {
            // `children` is array-like on the PSP: children[i] in the RCO's order and .length, beside the
            // labels (16 library discs read children.length; Austin Powers 2 walks its pages' children by
            // index -- with labels alone its menus draw nothing). A digit-only label is an index already:
            // the fallback "%04d" is its own position; a real one that is not is traced, never lost
            // quietly (none on the library's 246 RCOs, 2026-10-02).
            vm_array_push(m->v, holder, vm_objv(o));
            const char *q = name;
            while (*q >= '0' && *q <= '9') q++;
            if (*q) vm_set(m->v, holder, name, vm_objv(o));
            else if ((uint32_t)atol(name) != holder->nel - 1)
                mtrace(m, "LABEL %s is all digits but child %u: reachable as children[%u] only", name, holder->nel - 1, holder->nel - 1);
        } else vm_set(m->v, holder, name, vm_objv(o));
        if (e->table == RCO_T_OBJECT && e->type == 1) {
            // a page: its children live in its `root`
            vm_obj *root = vm_new_object(m->v, "root");
            root->host = nd;            // an animation played on the root tweens the page (its children inherit)
            vm_set(m->v, o, "root", vm_objv(root));
            nd->holder = root;
            page = (int)(nd - m->nodes);
        }
        if (e->first >= 0) {
            vm_obj *kids = vm_new_array(m->v, 0);
            vm_set(m->v, nd->holder, "children", vm_objv(kids));
            // a page's children are its root's -- and the page's own too (Family Guy's Previews:
            // `this.children['btnPreviewsTr01']` in the page's onInit; undefined there, its menu was
            // dead on the rig: the maintainer, 2026-10-03)
            if (e->table == RCO_T_OBJECT && e->type == 1) vm_set(m->v, o, "children", vm_objv(kids));
            build(m, c, kids, (e->table == RCO_T_OBJECT && e->type == 1) ? (int)(nd - m->nodes) : page, nd->holder);
        }
        if (e->table == RCO_T_OBJECT && e->type == 1) page = nd->page;
    }
}

// ---- the renderer (M1c; THE SCENE at the top of this file) -------------------------------------------
static void ic_free_all(menu *m);
static void images_free(menu *m)
{
    if (m->img) for (int i = 0; i < m->r.n; i++) free(m->img[i].px);
    free(m->img);
    m->img = NULL;
    if (m->snd) for (int i = 0; i < m->r.n; i++) free(m->snd[i].pcm);
    free(m->snd);
    m->snd = NULL;
}

// an image entry decoded (premultiplied), NULL when it cannot be (traced once)
static const image_c *image_get(menu *m, int ent)
{
    image_c *c = &m->img[ent];
    if (c->tried) return c->px ? c : NULL;
    c->tried = 1;
    uint32_t fmt, cmp, len, un;
    const uint8_t *data;
    if (rco_image(&m->r, ent, &fmt, &cmp, &data, &len, &un)) { mtrace(m, "IMAGE %s: no data", m->r.e[ent].label); return NULL; }
    if (cmp != 0) { mtrace(m, "IMAGE %s: compression %u not handled", m->r.e[ent].label, cmp); return NULL; }
    if (!m->h.decode_image || m->h.decode_image(m->h.ud, (int)fmt, data, len, &c->w, &c->h, &c->px) || !c->px) {
        mtrace(m, "IMAGE %s: format %u not decoded", m->r.e[ent].label, fmt);
        c->px = NULL;
        return NULL;
    }
    // premultiplied by the subtitle plane's exact formula (sub_plane_wr.sv, umd_sub.cpp)
    for (size_t i = 0; i < (size_t)c->w * (size_t)c->h; i++) {
        uint8_t *p = c->px + 4 * i;
        unsigned a = p[3];
        for (int k = 0; k < 3; k++) { unsigned t = p[k] * a + 128; p[k] = (uint8_t)((t + (t >> 8)) >> 8); }
    }
    c->tx0 = c->w; c->ty0 = c->h; c->tx1 = -1; c->ty1 = -1;
    c->opaque = 1;
    for (size_t i = 0; i < (size_t)c->w * (size_t)c->h; i++) if (c->px[4 * i + 3] != 255) { c->opaque = 0; break; }
    for (int y = 0; y < c->h; y++)
        for (int x = 0; x < c->w; x++)
            if (c->px[4 * ((size_t)y * (size_t)c->w + (size_t)x) + 3]) {
                if (x < c->tx0) c->tx0 = x;
                if (x > c->tx1) c->tx1 = x;
                if (y < c->ty0) c->ty0 = y;
                if (y > c->ty1) c->ty1 = y;
            }
    return c;
}

// the image an object shows: a script-set `texture`, else its RCO `image`; -1 none
static int image_of(menu *m, node *nd)
{
    vm_value t = vm_get(m->v, nd->obj, "texture");
    if (t.t == V_OBJ && t.u.o->host) {
        node *tn = (node *)t.u.o->host;
        if (tn->table == RCO_T_IMAGE) return tn->ent;
    }
    uint32_t ptr, rt = attr_ref(&m->r.e[nd->ent], "image", &ptr);
    return rt == REF_IMG ? rco_by_offset(&m->r, ptr) : -1;
}

typedef struct { float a, b, c, d, e, f; } affine;      // X = a x + b y + c, Y = d x + e y + f

typedef struct {
    uint8_t *px;
    int      w, h, stride;
    int      ri, bi;                // the byte of red and of blue in a pixel (the layout)
    uint32_t blended;
} canvas;

// `left`: the quad starts at local x 0, not -w / 2 (no caller sets it now: draw_node turns every
// iconOffset anchor into a translation, docs/p9.md M4b)
// THE FAST PATH: an object neither rotated nor sheared (nearly every one): its pixel centres step a
// texture row in a straight line, so the inverse transform is two divisions a row and the visible
// columns one interval a row. The sampling is 16.16 fixed point, the bilinear weights 0..256, and
// two channels go through each multiply (R and B, G and A, in 16-bit lanes of a 32-bit word: the
// products stay under 2^16). An opaque result is stored without reading the target; the blend's
// / 255 is (t + (t >> 8)) >> 8 with t = x + 128 (the A9 has no divide). The result is the general
// path's within an LSB or two; no captured picture moves (the gate checks places and alphas). The
// texture's transparent margins (its alpha box) are skipped before any fetch. The rig measured the
// float path at 60-350 ms a frame on the A9 (docs/p9.md M3, the first rig session).
#define LANES 0x00FF00FFu
static inline uint32_t lerp2(uint32_t a, uint32_t b, uint32_t w)    // two lanes, w 0..256
{
    return ((a * (256u - w) + b * w) >> 8) & LANES;
}
static inline uint32_t div255x2(uint32_t t)                         // two lanes: x / 255, t = x + 128
{
    return ((t + ((t >> 8) & LANES)) >> 8) & LANES;
}

// THE VECTOR STEP (fj#74): the line path's pixel step four pixels at a time, in GCC's generic vectors --
// NEON on the A9 (menu.c is built with it: the pragma at the top), SSE on the PC, so the PC benches run
// the very code the Main runs. The scalar path keeps two 8-bit channels in the 16-bit lanes of a 32-bit
// word and every intermediate stays under 2^16 in its lane (a lerp <= 255 x 256, a modulation <= 255 x
// 256 + 128, the blend's t <= 255 x 255 + 128 and t + (t >> 8) <= 65,407, the sum before the
// saturation <= 510), so the same steps in 16-bit vector lanes give the same integers. Two things the
// scalar path branches on are folded: an opaque source (keep 0) is the general blend's result exactly
// (div255(0 + 128) = 0), and a source that is zero after the modulation leaves the target unchanged (a
// select; the blended count counts only the others).
#if defined(__GNUC__) && !defined(__clang__)
#define MENU_VEC 1
typedef uint16_t u16x8 __attribute__((vector_size(16)));
typedef uint32_t u32x4 __attribute__((vector_size(16)));
// (loads and stores as vectors: vld1 / vst1. A memcpy into a vector went through the core registers and
// the stack on the A9 -- four ldr, stmia, vldr -- and the step ran at 70 ns a pixel)
typedef uint16_t u16x8_ua __attribute__((vector_size(16), aligned(4), may_alias));
typedef uint32_t u32x4_ua __attribute__((vector_size(16), aligned(4), may_alias));
static inline u16x8 ld16(const uint32_t *p) { return *(const u16x8_ua *)p; }
static inline u32x4 ld32(const uint32_t *p) { return *(const u32x4_ua *)p; }
static inline void st32(uint32_t *p, u32x4 v) { *(u32x4_ua *)p = v; }
// min(v, 255) per lane: NEON's vmin on the A9 (one op where the generic form is four); the generic form
// on the PC computes the same value (v <= 510 here: v - (v - 255) when v > 255)
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
static inline u16x8 min255(u16x8 v) { return (u16x8)vminq_u16((uint16x8_t)v, vdupq_n_u16(255)); }
#else
static inline u16x8 min255(u16x8 v) { const u16x8 c = (u16x8){0} + 255; return v - ((u16x8)(v > c) & (v - c)); }
#endif
#endif
static void draw_axis(menu *m, canvas *cv, const affine *A, float qw, float qh, float lx0,
                      int ix0, int ix1, int iy0, int iy1, const image_c *im, const float *col, const float *cr,
                      const int *clip)
{
    (void)m;
    float hy = qh * 0.5f;
    float ca = fminf(fmaxf(col[3], 0.0f), 1.0f);
    uint32_t ka = (uint32_t)(ca * 256.0f + 0.5f);
    uint32_t k0 = (uint32_t)(fminf(fmaxf(col[0], 0.0f), 1.0f) * ca * 256.0f + 0.5f);
    uint32_t k1 = (uint32_t)(fminf(fmaxf(col[1], 0.0f), 1.0f) * ca * 256.0f + 0.5f);
    uint32_t k2 = (uint32_t)(fminf(fmaxf(col[2], 0.0f), 1.0f) * ca * 256.0f + 0.5f);
    int plane = cv->ri == 2;                                // the target's R at byte 2 (MENU_PX_PLANE)
    float fx_lo = fmaxf(0.0f, cr[0]), fx_hi = fminf(1.0f, cr[0] + cr[2]);
    float fy_lo = fmaxf(0.0f, cr[1]), fy_hi = fminf(1.0f, cr[1] + cr[3]);
    if (fx_lo >= fx_hi || fy_lo >= fy_hi) return;
    // the visible columns: fx(X) = fx0 + (X - ix0) dfx in [fx_lo, fx_hi), dfx > 0 (draw_quad's test)
    float dfx = 1.0f / (A->a * qw);
    float fx0 = (((float)ix0 + 0.5f - A->c) / A->a - lx0) / qw;
    int xs = ix0 + (int)ceilf((fx_lo - fx0) / dfx), xe = ix0 + (int)ceilf((fx_hi - fx0) / dfx);
    if (xs < ix0) xs = ix0;
    if (xe > ix1) xe = ix1;
    if (xs >= xe) return;
    int32_t du = 0, u_first = 0;
    int tx0 = 0, tx1 = 0;
    if (im) {
        if (im->tx0 > im->tx1) return;                      // (no texel with alpha)
        du = (int32_t)lroundf(dfx * (float)im->w * 65536.0f);
        u_first = (int32_t)lroundf(((fx0 + (float)(xs - ix0) * dfx) * (float)im->w - 0.5f) * 65536.0f);
        tx0 = im->tx0; tx1 = im->tx1;
    }
    // a solid quad's premultiplied colour (R / B and G / A lanes)
    uint32_t sol_rb = 0, sol_ga = 0, sol_a = 0;
    if (!im) {
        uint32_t r = (255 * k0 + 128) >> 8, g = (255 * k1 + 128) >> 8, bb = (255 * k2 + 128) >> 8;
        sol_a = (255 * ka + 128) >> 8;
        sol_rb = plane ? (bb | r << 16) : (r | bb << 16);
        sol_ga = g | sol_a << 16;
        if (!sol_a && !(sol_rb | sol_ga)) return;
    }
    int same_k = k0 == ka && k1 == ka && k2 == ka;         // (the usual: a colour (1, 1, 1, a))
    // the clip (a damage rectangle, menu_render_view_inc): only the loops shrink -- the span, the first
    // texel step and its increment are the unclipped ones, U advanced by whole steps, so a clipped draw
    // writes exactly the pixels the full draw writes there
    int cxs = xs > clip[0] ? xs : clip[0], cxe = xe < clip[2] ? xe : clip[2];
    if (cxs >= cxe) return;
    u_first += (int32_t)(cxs - xs) * du;
    int cy0 = iy0 > clip[1] ? iy0 : clip[1], cy1 = iy1 < clip[3] ? iy1 : clip[3];
    // THE LINE CACHE (fj#74, the A9: ~80 cycles a bilinear pixel, The Rock's menu 177 ms a frame): the
    // filter is lerp(lerp(row v0 at fu), lerp(row v1 at fu), fv) -- horizontal first --, and the two
    // horizontal results depend only on the texel row and the column, not on the target row. A texture
    // drawn at 1x or larger vertically shares each texel row between target rows (The Rock's plnBGHuge
    // 2.9x, plnBGGrid 2x, plnRootBlack 8.5x), so a texel row's horizontal lerps are computed once into a
    // line (hl: R / B and G / A per column) and each pixel does the vertical step alone: the same
    // integers in the same order, the result bit-identical to the per-pixel path (the benches compare the
    // frames' hashes with the build before it). A downscaled texture (a new texel row every target row)
    // keeps the per-pixel path. The transparent-margin and all-zero skips become the zero test after
    // the modulation: a premultiplied transparent texel is 0 in every channel (image_get), so both
    // skip exactly the pixels the per-pixel path skips.
    int nx = cxe - cxs;
    int lines = im && fabsf(A->e) * qh >= (float)im->h;
    if (lines && m->hl_w < nx) {
        uint32_t *n = (uint32_t *)realloc(m->hl, (size_t)nx * 7 * sizeof(uint32_t));
        if (n) { m->hl = n; m->hl_w = nx; } else lines = 0;
    }
    int lkey[2] = { -1, -1 };                               // the texel row in each line
    uint32_t *lrb[2] = { NULL, NULL }, *lga[2] = { NULL, NULL };
    // THE COLUMNS: every texel row of the draw reads the same two texel columns at the same weight per
    // target column -- computed once here (u0, u1 clamped as the per-pixel path clamps them; fu in both
    // 16-bit lanes), not once a texel row
    uint32_t *cu0 = NULL, *cu1 = NULL, *cfw = NULL;
    // THE OPAQUE STEP: an opaque texture at full colour (every texel's alpha 255, k0..ka 256) modulates
    // to itself ((x 256 + 128) >> 8 = x) and blends to itself (keep 0): the step stores the filtered
    // value without reading the target -- the same result
    int opq = 0;
    if (lines) {
        lrb[0] = m->hl; lga[0] = m->hl + nx; lrb[1] = m->hl + 2 * nx; lga[1] = m->hl + 3 * nx;
        cu0 = m->hl + 4 * nx; cu1 = m->hl + 5 * nx; cfw = m->hl + 6 * nx;
        int32_t U = u_first;
        for (int i = 0; i < nx; i++, U += du) {
            int u0 = U >> 16, u1 = u0 + 1;
            uint32_t fu = ((uint32_t)U >> 8) & 0xFF;
            if (u0 < 0) u0 = 0;
            if (u1 > im->w - 1) u1 = im->w - 1;
            if (u0 > im->w - 1) u0 = im->w - 1;
            cu0[i] = (uint32_t)u0; cu1[i] = (uint32_t)u1; cfw[i] = fu | fu << 16;
        }
        opq = im->opaque && ka == 256 && k0 == 256 && k1 == 256 && k2 == 256;
    }
    for (int Y = cy0; Y < cy1; Y++) {
        float ly = ((float)Y + 0.5f - A->f) / A->e;
        if (ly <= -hy || ly > hy) continue;
        float fy = 0.5f - ly / qh;
        if (fy < fy_lo || fy >= fy_hi) continue;
        uint32_t *row = (uint32_t *)(cv->px + (size_t)Y * (size_t)cv->stride);
        const uint32_t *r0 = NULL, *r1 = NULL;
        uint32_t fv = 0;
        int v0 = 0, v1 = 0;
        if (im) {
            float v = fy * (float)im->h - 0.5f;
            v0 = (int)floorf(v);
            fv = (uint32_t)((v - (float)v0) * 256.0f);
            v1 = v0 + 1;
            if (v1 < im->ty0 || v0 > im->ty1) continue;     // both texel rows transparent
            if (v0 < 0) v0 = 0;
            if (v1 > im->h - 1) v1 = im->h - 1;
            if (v0 > im->h - 1) v0 = im->h - 1;
            r0 = (const uint32_t *)(im->px + 4 * (size_t)v0 * (size_t)im->w);
            r1 = (const uint32_t *)(im->px + 4 * (size_t)v1 * (size_t)im->w);
        }
        if (lines) {
            // the lines of rows v0 and v1 (a line already holding one is kept)
            int want[2] = { v0, v1 };
            int at[2];
            for (int k = 0; k < 2; k++) at[k] = lkey[0] == want[k] ? 0 : lkey[1] == want[k] ? 1 : -1;
#ifdef MENU_PROF
            struct timespec pf0, pf1;
            clock_gettime(CLOCK_MONOTONIC, &pf0);
#endif
            for (int k = 0; k < 2; k++) {
                if (at[k] >= 0) continue;
#ifdef MENU_PROF
                m->prof_fill_px += (uint64_t)nx;
#endif
                int slot = (at[1 - k] == 0) ? 1 : (at[1 - k] == 1) ? 0 : k;   // (not the line the other row uses)
                if (k == 1 && at[0] == slot) slot = 1 - slot;
                const uint32_t *tr = k == 0 ? r0 : r1;
                uint32_t *hrb = lrb[slot], *hga = lga[slot];
                int i = 0;
#ifdef MENU_VEC
                {
                    const u32x4 lanes = (u32x4){0} + LANES;
                    const u16x8 c256 = (u16x8){0} + 256;
                    for (; i + 4 <= nx; i += 4) {
                        u32x4 p0 = { tr[cu0[i]], tr[cu0[i + 1]], tr[cu0[i + 2]], tr[cu0[i + 3]] };
                        u32x4 p1 = { tr[cu1[i]], tr[cu1[i + 1]], tr[cu1[i + 2]], tr[cu1[i + 3]] };
                        u16x8 w = ld16(cfw + i), iw = c256 - w;
                        st32(hrb + i, (u32x4)(((u16x8)(p0 & lanes) * iw + (u16x8)(p1 & lanes) * w) >> 8));
                        st32(hga + i, (u32x4)(((u16x8)((p0 >> 8) & lanes) * iw + (u16x8)((p1 >> 8) & lanes) * w) >> 8));
                    }
                }
#endif
                for (; i < nx; i++) {
                    uint32_t p0 = tr[cu0[i]], p1 = tr[cu1[i]], fu = cfw[i] & 0xFF;
                    hrb[i] = lerp2(p0 & LANES, p1 & LANES, fu);
                    hga[i] = lerp2((p0 >> 8) & LANES, (p1 >> 8) & LANES, fu);
                }
                lkey[slot] = want[k];
                at[k] = slot;
            }
#ifdef MENU_PROF
            clock_gettime(CLOCK_MONOTONIC, &pf1);
            m->prof_fill_ns += (uint64_t)((pf1.tv_sec - pf0.tv_sec) * 1000000000LL + (pf1.tv_nsec - pf0.tv_nsec));
            pf0 = pf1;
            m->prof_step_px += (uint64_t)nx;
#endif
            const uint32_t *a_rb = lrb[at[0]], *a_ga = lga[at[0]], *b_rb = lrb[at[1]], *b_ga = lga[at[1]];
            uint32_t *o = row + cxs;
            int i = 0;
            if (opq) {
#ifdef MENU_VEC
                const u16x8 w1 = (u16x8){0} + (uint16_t)(256u - fv), w2 = (u16x8){0} + (uint16_t)fv;
                for (; i + 4 <= nx; i += 4) {
                    u16x8 rb = (ld16(a_rb + i) * w1 + ld16(b_rb + i) * w2) >> 8;
                    u16x8 ga = (ld16(a_ga + i) * w1 + ld16(b_ga + i) * w2) >> 8;
                    if (plane) rb = __builtin_shuffle(rb, (u16x8){ 1, 0, 3, 2, 5, 4, 7, 6 });
                    st32(o + i, (u32x4)rb | ((u32x4)ga << 8));
                }
#endif
                for (; i < nx; i++) {
                    uint32_t rb = lerp2(a_rb[i], b_rb[i], fv), ga = lerp2(a_ga[i], b_ga[i], fv);
                    if (plane) rb = ((rb << 16) | (rb >> 16)) & LANES;
                    o[i] = rb | ga << 8;
                }
                cv->blended += (uint32_t)nx;            // (alpha 255 everywhere: every pixel written)
                i = nx;
            }
#ifdef MENU_VEC
            {
                const u16x8 w1 = (u16x8){0} + (uint16_t)(256u - fv), w2 = (u16x8){0} + (uint16_t)fv;
                // the texel's R / B lanes by k0 / k2, G / A by k1 / ka, before the plane's swap (as the scalar)
                const u16x8 krb = { (uint16_t)k0, (uint16_t)k2, (uint16_t)k0, (uint16_t)k2, (uint16_t)k0, (uint16_t)k2, (uint16_t)k0, (uint16_t)k2 };
                const u16x8 kga = { (uint16_t)k1, (uint16_t)ka, (uint16_t)k1, (uint16_t)ka, (uint16_t)k1, (uint16_t)ka, (uint16_t)k1, (uint16_t)ka };
                const u16x8 c80 = (u16x8){0} + 0x80, c255 = (u16x8){0} + 255;
                const u32x4 lanes = (u32x4){0} + LANES;
                u32x4 nblend = { 0, 0, 0, 0 };                  // (a vector: a NEON lane read into a core register
                                                                // stalls the A9 for many cycles -- once a row, not a pixel)
                for (; i + 4 <= nx; i += 4) {
                    u16x8 rb = (ld16(a_rb + i) * w1 + ld16(b_rb + i) * w2) >> 8;
                    u16x8 ga = (ld16(a_ga + i) * w1 + ld16(b_ga + i) * w2) >> 8;
                    rb = (rb * krb + c80) >> 8;                     // (same_k: krb = kga = ka)
                    ga = (ga * kga + c80) >> 8;
                    // (no select for an untouched pixel: a zero source blends to the target exactly --
                    // keep 255, and div255(d x 255 + 128) = d for every d -- so only the count needs nz)
                    nblend -= (u32x4)((u32x4)(rb | ga) != 0);
                    if (plane) rb = __builtin_shuffle(rb, (u16x8){ 1, 0, 3, 2, 5, 4, 7, 6 });
                    u16x8 keep = c255 - __builtin_shuffle(ga, (u16x8){ 1, 1, 3, 3, 5, 5, 7, 7 });
                    u32x4 d = ld32(o + i);
                    u16x8 trb = (u16x8)(d & lanes) * keep + c80, tga = (u16x8)((d >> 8) & lanes) * keep + c80;
                    u16x8 orb = min255(rb + ((trb + (trb >> 8)) >> 8)), oga = min255(ga + ((tga + (tga >> 8)) >> 8));
                    st32(o + i, (u32x4)orb | ((u32x4)oga << 8));
                }
                cv->blended += nblend[0] + nblend[1] + nblend[2] + nblend[3];
            }
#endif
            for (; i < nx; i++) {
                uint32_t rb = lerp2(a_rb[i], b_rb[i], fv), ga = lerp2(a_ga[i], b_ga[i], fv);
                if (same_k) {
                    rb = ((rb * ka + 0x00800080u) >> 8) & LANES;
                    ga = ((ga * ka + 0x00800080u) >> 8) & LANES;
                } else {
                    rb = (((rb & 0xFF) * k0 + 128) >> 8) | (((((rb >> 16) & 0xFF) * k2 + 128) >> 8) << 16);
                    ga = (((ga & 0xFF) * k1 + 128) >> 8) | (((((ga >> 16) & 0xFF) * ka + 128) >> 8) << 16);
                }
                if (!(rb | ga)) continue;
                if (plane) rb = ((rb << 16) | (rb >> 16)) & LANES;
                uint32_t sa = ga >> 16, out;
                if (sa >= 255) out = rb | ga << 8;
                else {
                    uint32_t dpx = o[i], keep = 255 - sa;
                    uint32_t o_rb = rb + div255x2((dpx & LANES) * keep + 0x00800080u);
                    uint32_t o_ga = ga + div255x2(((dpx >> 8) & LANES) * keep + 0x00800080u);
                    o_rb |= ((o_rb & 0x01000100u) >> 8) * 0xFF; o_ga |= ((o_ga & 0x01000100u) >> 8) * 0xFF;
                    out = (o_rb & LANES) | (o_ga & LANES) << 8;
                }
                o[i] = out;
                cv->blended++;
            }
#ifdef MENU_PROF
            clock_gettime(CLOCK_MONOTONIC, &pf1);
            m->prof_step_ns += (uint64_t)((pf1.tv_sec - pf0.tv_sec) * 1000000000LL + (pf1.tv_nsec - pf0.tv_nsec));
#endif
            continue;
        }
        int32_t U = u_first;
        for (int X = cxs; X < cxe; X++, U += du) {
            uint32_t s_rb, s_ga, sa;
            if (im) {
                int u0 = U >> 16, u1 = u0 + 1;
                if (u1 < tx0 || u0 > tx1) continue;         // a transparent margin
                uint32_t fu = ((uint32_t)U >> 8) & 0xFF;
                if (u0 < 0) u0 = 0;
                if (u1 > im->w - 1) u1 = im->w - 1;
                if (u0 > im->w - 1) u0 = im->w - 1;
                uint32_t p00 = r0[u0], p01 = r0[u1], p10 = r1[u0], p11 = r1[u1];
                if (!((p00 | p01 | p10 | p11) >> 24)) continue;   // premultiplied: nothing there
                // texels are bytes R, G, B, A: the R / B lanes and the G / A lanes
                uint32_t rb = lerp2(lerp2(p00 & LANES, p01 & LANES, fu), lerp2(p10 & LANES, p11 & LANES, fu), fv);
                uint32_t ga = lerp2(lerp2((p00 >> 8) & LANES, (p01 >> 8) & LANES, fu),
                                    lerp2((p10 >> 8) & LANES, (p11 >> 8) & LANES, fu), fv);
                if (same_k) {
                    rb = ((rb * ka + 0x00800080u) >> 8) & LANES;
                    ga = ((ga * ka + 0x00800080u) >> 8) & LANES;
                } else {
                    rb = (((rb & 0xFF) * k0 + 128) >> 8) | (((((rb >> 16) & 0xFF) * k2 + 128) >> 8) << 16);
                    ga = (((ga & 0xFF) * k1 + 128) >> 8) | (((((ga >> 16) & 0xFF) * ka + 128) >> 8) << 16);
                }
                if (plane) rb = ((rb << 16) | (rb >> 16)) & LANES;  // B at byte 0, R at byte 2
                s_rb = rb; s_ga = ga; sa = ga >> 16;
                if (!(s_rb | s_ga)) continue;
            } else {
                s_rb = sol_rb; s_ga = sol_ga; sa = sol_a;
            }
            uint32_t out;
            if (sa >= 255) out = s_rb | s_ga << 8;                   // opaque: the target not read
            else {
                uint32_t dpx = row[X], keep = 255 - sa;
                uint32_t o_rb = s_rb + div255x2((dpx & LANES) * keep + 0x00800080u);
                uint32_t o_ga = s_ga + div255x2(((dpx >> 8) & LANES) * keep + 0x00800080u);
                // (saturate each lane: the rounding may pass 255 by one)
                o_rb |= ((o_rb & 0x01000100u) >> 8) * 0xFF; o_ga |= ((o_ga & 0x01000100u) >> 8) * 0xFF;
                out = (o_rb & LANES) | (o_ga & LANES) << 8;
            }
            row[X] = out;
            cv->blended++;
        }
    }
}

// THE ROTATED PATH (M4: Spider-Man 2's turning webs, X-Men's orbs mid-turn): any invertible transform.
// Along a target row the object's coordinates are linear in X, so the visible span is the
// intersection of two intervals (fx in the crop's columns, fy in its rows) and the texture position
// steps by a constant in 16.16, both axes; the texel fetch, the bilinear weights and the blend are
// draw_axis's. Measured against the general path at every gate shot (menu_run's SHOT line: at most 8
// levels apart, at most 0.5 % of the pixels more than 2); the general path took 41 ms a frame for
// Spider-Man 2's main menu on the PC (~0.8 s on the A9)
static void draw_affine(menu *m, canvas *cv, const affine *A, float det, float qw, float qh, float lx0,
                        int ix0, int ix1, int iy0, int iy1, const image_c *im, const float *col, const float *cr,
                        const int *clip)
{
    (void)m;
    float ca = fminf(fmaxf(col[3], 0.0f), 1.0f);
    uint32_t ka = (uint32_t)(ca * 256.0f + 0.5f);
    uint32_t k0 = (uint32_t)(fminf(fmaxf(col[0], 0.0f), 1.0f) * ca * 256.0f + 0.5f);
    uint32_t k1 = (uint32_t)(fminf(fmaxf(col[1], 0.0f), 1.0f) * ca * 256.0f + 0.5f);
    uint32_t k2 = (uint32_t)(fminf(fmaxf(col[2], 0.0f), 1.0f) * ca * 256.0f + 0.5f);
    int plane = cv->ri == 2;
    float fx_lo = fmaxf(0.0f, cr[0]), fx_hi = fminf(1.0f, cr[0] + cr[2]);
    float fy_lo = fmaxf(0.0f, cr[1]), fy_hi = fminf(1.0f, cr[1] + cr[3]);
    if (fx_lo >= fx_hi || fy_lo >= fy_hi) return;
    if (im && im->tx0 > im->tx1) return;
    uint32_t sol_rb = 0, sol_ga = 0, sol_a = 0;
    if (!im) {
        uint32_t r = (255 * k0 + 128) >> 8, g = (255 * k1 + 128) >> 8, bb = (255 * k2 + 128) >> 8;
        sol_a = (255 * ka + 128) >> 8;
        sol_rb = plane ? (bb | r << 16) : (r | bb << 16);
        sol_ga = g | sol_a << 16;
        if (!sol_a && !(sol_rb | sol_ga)) return;
    }
    int same_k = k0 == ka && k1 == ka && k2 == ka;
    // per target pixel X: fx = (lx - lx0) / qw, fy = 0.5 - ly / qh, lx and ly the inverse transform
    float dfx = A->e / det / qw, dfy = A->d / det / qh;           // (d fy / dX = -(-d / det) / qh)
    int cy0 = iy0 > clip[1] ? iy0 : clip[1], cy1 = iy1 < clip[3] ? iy1 : clip[3];
    for (int Y = cy0; Y < cy1; Y++) {
        float py = (float)Y + 0.5f - A->f, px = (float)ix0 + 0.5f - A->c;
        float fx0 = ((A->e * px - A->b * py) / det - lx0) / qw;
        float fy0 = 0.5f - ((-A->d * px + A->a * py) / det) / qh;
        // the span of X (from ix0) with fx in [fx_lo, fx_hi) and fy in [fy_lo, fy_hi)
        float lo = 0.0f, hi = (float)(ix1 - ix0);
        if (dfx > 0) { lo = fmaxf(lo, (fx_lo - fx0) / dfx); hi = fminf(hi, (fx_hi - fx0) / dfx); }
        else if (dfx < 0) { lo = fmaxf(lo, (fx_hi - fx0) / dfx); hi = fminf(hi, (fx_lo - fx0) / dfx); }
        else if (fx0 < fx_lo || fx0 >= fx_hi) continue;
        if (dfy > 0) { lo = fmaxf(lo, (fy_lo - fy0) / dfy); hi = fminf(hi, (fy_hi - fy0) / dfy); }
        else if (dfy < 0) { lo = fmaxf(lo, (fy_hi - fy0) / dfy); hi = fminf(hi, (fy_lo - fy0) / dfy); }
        else if (fy0 < fy_lo || fy0 >= fy_hi) continue;
        int xs = ix0 + (int)ceilf(lo), xe = ix0 + (int)ceilf(hi);
        if (xs < ix0) xs = ix0;
        if (xe > ix1) xe = ix1;
        if (xs >= xe) continue;
        uint32_t *row = (uint32_t *)(cv->px + (size_t)Y * (size_t)cv->stride);
        int32_t U = 0, V = 0, du = 0, dv = 0;
        if (im) {
            float k = (float)(xs - ix0);
            U = (int32_t)lroundf(((fx0 + k * dfx) * (float)im->w - 0.5f) * 65536.0f);
            V = (int32_t)lroundf(((fy0 + k * dfy) * (float)im->h - 0.5f) * 65536.0f);
            du = (int32_t)lroundf(dfx * (float)im->w * 65536.0f);
            dv = (int32_t)lroundf(dfy * (float)im->h * 65536.0f);
        }
        // (the clip: as draw_axis's, the steps from the unclipped span's start)
        int cxs = xs > clip[0] ? xs : clip[0], cxe = xe < clip[2] ? xe : clip[2];
        if (cxs >= cxe) continue;
        U += (int32_t)(cxs - xs) * du; V += (int32_t)(cxs - xs) * dv;
        for (int X = cxs; X < cxe; X++, U += du, V += dv) {
            uint32_t s_rb, s_ga, sa;
            if (im) {
                int u0 = U >> 16, u1 = u0 + 1, v0 = V >> 16, v1 = v0 + 1;
                if (u1 < im->tx0 || u0 > im->tx1 || v1 < im->ty0 || v0 > im->ty1) continue;
                uint32_t fu = ((uint32_t)U >> 8) & 0xFF, fv = ((uint32_t)V >> 8) & 0xFF;
                if (u0 < 0) u0 = 0;
                if (u1 > im->w - 1) u1 = im->w - 1;
                if (u0 > im->w - 1) u0 = im->w - 1;
                if (v0 < 0) v0 = 0;
                if (v1 > im->h - 1) v1 = im->h - 1;
                if (v0 > im->h - 1) v0 = im->h - 1;
                const uint32_t *r0 = (const uint32_t *)(im->px + 4 * (size_t)v0 * (size_t)im->w);
                const uint32_t *r1 = (const uint32_t *)(im->px + 4 * (size_t)v1 * (size_t)im->w);
                uint32_t p00 = r0[u0], p01 = r0[u1], p10 = r1[u0], p11 = r1[u1];
                if (!((p00 | p01 | p10 | p11) >> 24)) continue;
                uint32_t rb = lerp2(lerp2(p00 & LANES, p01 & LANES, fu), lerp2(p10 & LANES, p11 & LANES, fu), fv);
                uint32_t ga = lerp2(lerp2((p00 >> 8) & LANES, (p01 >> 8) & LANES, fu),
                                    lerp2((p10 >> 8) & LANES, (p11 >> 8) & LANES, fu), fv);
                if (same_k) {
                    rb = ((rb * ka + 0x00800080u) >> 8) & LANES;
                    ga = ((ga * ka + 0x00800080u) >> 8) & LANES;
                } else {
                    rb = (((rb & 0xFF) * k0 + 128) >> 8) | (((((rb >> 16) & 0xFF) * k2 + 128) >> 8) << 16);
                    ga = (((ga & 0xFF) * k1 + 128) >> 8) | (((((ga >> 16) & 0xFF) * ka + 128) >> 8) << 16);
                }
                if (plane) rb = ((rb << 16) | (rb >> 16)) & LANES;
                s_rb = rb; s_ga = ga; sa = ga >> 16;
                if (!(s_rb | s_ga)) continue;
            } else {
                s_rb = sol_rb; s_ga = sol_ga; sa = sol_a;
            }
            uint32_t out;
            if (sa >= 255) out = s_rb | s_ga << 8;
            else {
                uint32_t dpx = row[X], keep = 255 - sa;
                uint32_t o_rb = s_rb + div255x2((dpx & LANES) * keep + 0x00800080u);
                uint32_t o_ga = s_ga + div255x2(((dpx >> 8) & LANES) * keep + 0x00800080u);
                o_rb |= ((o_rb & 0x01000100u) >> 8) * 0xFF; o_ga |= ((o_ga & 0x01000100u) >> 8) * 0xFF;
                out = (o_rb & LANES) | (o_ga & LANES) << 8;
            }
            row[X] = out;
            cv->blended++;
        }
    }
}

// THE DRAW LIST (P9, the damage rectangles; docs/p9.md "M4d"): a frame is first COLLECTED -- every
// quad the tree draws, in order, with all that decides its pixels (its transform, size, colour, crop,
// image) and its box on the target -- and then drawn. A full render clears the target and draws the
// list; the incremental render (menu_render_view_inc) compares it with the previous frame's and
// redraws only the damage: the boxes, old and new, of the items that changed, appeared, went or moved
// in the order. Inside a damaged rectangle every item that touches it is drawn again from a cleared
// background, so the composite there is the full render's exactly (the benches compare them, every
// frame: menu_host_check's CORE INC check).
typedef struct dritem {
    int      ni, ie;                // the node; its image entry (-1 none)
    const image_c *im;
    affine   A;                     // the quad's transform (its anchor applied)
    float    qw, qh, col[4], cr[4];
    int      bx0, by0, bx1, by1;    // its box on the target, clipped to it (bx0 >= bx1: none)
} dritem;
#define DR_KEY_BYTES offsetof(dritem, bx0)          // (the fields compared: all but the box, derived)

static void collect_quad(menu *m, int ni, int ie, int cw, int ch, const affine *A, float qw, float qh,
                         const image_c *im, const float *col)
{
    float det = A->a * A->e - A->b * A->d;
    if (fabsf(det) < 1e-9f || qw <= 0 || qh <= 0) return;
    // the target bounding box of the four corners
    float hx = qw * 0.5f, hy = qh * 0.5f, lx0 = -hx;
    const float cx[4] = { lx0, lx0 + qw, lx0 + qw, lx0 }, cy[4] = { hy, hy, -hy, -hy };
    float x0 = 1e9f, x1 = -1e9f, y0 = 1e9f, y1 = -1e9f;
    for (int i = 0; i < 4; i++) {
        float xs = A->a * cx[i] + A->b * cy[i] + A->c, ys = A->d * cx[i] + A->e * cy[i] + A->f;
        x0 = fminf(x0, xs); x1 = fmaxf(x1, xs); y0 = fminf(y0, ys); y1 = fmaxf(y1, ys);
    }
    if (m->trace_draw)
        mtrace(m, "DRAW %s %.1f %.1f %.1f %.1f a%.2f %s %dx%d", m->r.e[m->nodes[ni].ent].label, (double)x0, (double)y0, (double)x1,
               (double)y1, (double)col[3], ie >= 0 ? m->r.e[ie].label : "-", im ? im->w : 0, im ? im->h : 0);
    if (m->ndl == m->dl_cap) {
        int cap = m->dl_cap ? 2 * m->dl_cap : 256;
        dritem *n = (dritem *)realloc(m->dl, (size_t)cap * sizeof(dritem));
        if (!n) { merr(m, "out of memory (the draw list)"); return; }
        m->dl = n; m->dl_cap = cap;
    }
    dritem *it = &m->dl[m->ndl++];
    memset(it, 0, sizeof(*it));                     // (the padding too: the items are compared bytewise)
    it->ni = ni; it->ie = ie; it->im = im; it->A = *A; it->qw = qw; it->qh = qh;
    memcpy(it->col, col, sizeof(it->col)); memcpy(it->cr, m->nodes[ni].crop, sizeof(it->cr));
    int ix0 = (int)floorf(x0), ix1 = (int)ceilf(x1), iy0 = (int)floorf(y0), iy1 = (int)ceilf(y1);
    if (ix0 < 0) ix0 = 0;
    if (iy0 < 0) iy0 = 0;
    if (ix1 > cw) ix1 = cw;
    if (iy1 > ch) iy1 = ch;
    it->bx0 = ix0; it->by0 = iy0; it->bx1 = ix1; it->by1 = iy1;
}

// an item drawn, only inside clip {x0, y0, x1, y1}
static void draw_item(menu *m, canvas *cv, const dritem *it, const int *clip)
{
    const affine *A = &it->A;
    const image_c *im = it->im;
    const float *col = it->col, *cr = it->cr;
    float qw = it->qw, qh = it->qh, hy = qh * 0.5f, lx0 = -qw * 0.5f;
    float det = A->a * A->e - A->b * A->d;
    int ix0 = it->bx0, ix1 = it->bx1, iy0 = it->by0, iy1 = it->by1;
    if (ix0 >= ix1 || iy0 >= iy1 || ix1 <= clip[0] || ix0 >= clip[2] || iy1 <= clip[1] || iy0 >= clip[3]) return;
    // (axis-aligned up to a float's noise: X-Men's orbs rest after whole turns of 2 pi, sin ~ 1e-7)
    if (!m->general_only && A->a > 0.0f && A->e != 0.0f && fabsf(A->b) <= 1e-5f * A->a && fabsf(A->d) <= 1e-5f * fabsf(A->e)) {
        draw_axis(m, cv, A, qw, qh, lx0, ix0, ix1, iy0, iy1, im, col, cr, clip);
        return;
    }
    if (!m->general_only) {
        draw_affine(m, cv, A, det, qw, qh, lx0, ix0, ix1, iy0, iy1, im, col, cr, clip);
        return;
    }
    float ca = fminf(fmaxf(col[3], 0.0f), 1.0f);
    float m0 = fminf(fmaxf(col[0], 0.0f), 1.0f) * ca, m1 = fminf(fmaxf(col[1], 0.0f), 1.0f) * ca, m2 = fminf(fmaxf(col[2], 0.0f), 1.0f) * ca;
    int gx0 = ix0 > clip[0] ? ix0 : clip[0], gx1 = ix1 < clip[2] ? ix1 : clip[2];
    int gy0 = iy0 > clip[1] ? iy0 : clip[1], gy1 = iy1 < clip[3] ? iy1 : clip[3];
    for (int Y = gy0; Y < gy1; Y++) {
        uint8_t *row = cv->px + (size_t)Y * (size_t)cv->stride;
        for (int X = gx0; X < gx1; X++) {
            float px = (float)X + 0.5f - A->c, py = (float)Y + 0.5f - A->f;
            float lx = (A->e * px - A->b * py) / det, ly = (-A->d * px + A->a * py) / det;
            if (lx < lx0 || lx >= lx0 + qw || ly <= -hy || ly > hy) continue;
            float fx = (lx - lx0) / qw, fy = 0.5f - ly / qh;            // (from the top left)
            if (fx < cr[0] || fx >= cr[0] + cr[2] || fy < cr[1] || fy >= cr[1] + cr[3]) continue;
            float s[4];
            if (im) {
                // bilinear, texel centres at +0.5, clamped at the edges; image row 0 at the top
                float u = (lx - lx0) / qw * (float)im->w - 0.5f, v = (0.5f - ly / qh) * (float)im->h - 0.5f;
                int u0 = (int)floorf(u), v0 = (int)floorf(v);
                float fu = u - (float)u0, fv = v - (float)v0;
                int u1 = u0 + 1, v1 = v0 + 1;
                if (u0 < 0) u0 = 0;
                if (v0 < 0) v0 = 0;
                if (u1 > im->w - 1) u1 = im->w - 1;
                if (v1 > im->h - 1) v1 = im->h - 1;
                if (u0 > im->w - 1) u0 = im->w - 1;
                if (v0 > im->h - 1) v0 = im->h - 1;
                const uint8_t *p00 = im->px + 4 * ((size_t)v0 * (size_t)im->w + (size_t)u0), *p01 = im->px + 4 * ((size_t)v0 * (size_t)im->w + (size_t)u1);
                const uint8_t *p10 = im->px + 4 * ((size_t)v1 * (size_t)im->w + (size_t)u0), *p11 = im->px + 4 * ((size_t)v1 * (size_t)im->w + (size_t)u1);
                for (int k = 0; k < 4; k++)
                    s[k] = ((float)p00[k] * (1 - fu) + (float)p01[k] * fu) * (1 - fv) + ((float)p10[k] * (1 - fu) + (float)p11[k] * fu) * fv;
                s[0] *= m0; s[1] *= m1; s[2] *= m2; s[3] *= ca;
            } else {
                s[0] = 255.0f * m0; s[1] = 255.0f * m1; s[2] = 255.0f * m2; s[3] = 255.0f * ca;
            }
            if (s[3] <= 0.0f && s[0] <= 0.0f && s[1] <= 0.0f && s[2] <= 0.0f) continue;
            uint8_t *d = row + 4 * X;
            float k = 1.0f - s[3] / 255.0f;
            const int at[4] = { cv->ri, 1, cv->bi, 3 };
            for (int c = 0; c < 4; c++) {
                float o = s[c] + (float)d[at[c]] * k;
                d[at[c]] = (uint8_t)(o >= 255.0f ? 255 : o <= 0.0f ? 0 : (int)(o + 0.5f));
            }
            cv->blended++;
        }
    }
}

// THE SCENE IS 3-D (P9 M4b, Astro Boy's carousel, 2026-10-04): an object's space is its parent's, then
// translate (pos x, y, z), rotate (z . y . x, radians: x applied first), scale -- a 3 x 4 matrix carried
// down the tree in the scene's space; a quad (local z 0) is projected ORTHOGRAPHICALLY onto the screen
// (z dropped) and then through the view (V). The drum menus of Astro Boy, Men in Black, Spider-Man and A
// Few Good Men turn a Group about X with labels at y / z on a circle (each counter-turned to face front);
// Cowboy Bebop turns about Y. MODEL, not measured on a PSP: the projection (orthographic, no perspective)
// and the drawing order (the tree's, not sorted by depth: the drums fade their back faces out).
typedef struct { float m[3][4]; } mat34;
static void collect_node(menu *m, int cw, int ch, int ni, const mat34 *P, const affine *V, const float *pcol)
{
    node *nd = &m->nodes[ni];
    if (!nd->visible) return;
    const rco_entry *e = &m->r.e[nd->ent];
    float cx = cosf(nd->rot[0]), sx = sinf(nd->rot[0]), cy = cosf(nd->rot[1]), sy = sinf(nd->rot[1]);
    float cz = cosf(nd->rot[2]), sz = sinf(nd->rot[2]);
    // R = Rz Ry Rx
    float R[3][3] = {
        { cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
        { sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
        { -sy,     cy * sx,                cy * cx } };
    float L[3][4];
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) L[r][c] = R[r][c] * nd->scale[c];
        L[r][3] = nd->pos[r];
    }
    mat34 Mw;
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 4; c++)
            Mw.m[r][c] = P->m[r][0] * L[0][c] + P->m[r][1] * L[1][c] + P->m[r][2] * L[2][c] + (c == 3 ? P->m[r][3] : 0.0f);
    // the quad's plane (local x, y) projected (z dropped), then the view
    affine S = { Mw.m[0][0], Mw.m[0][1], Mw.m[0][3], Mw.m[1][0], Mw.m[1][1], Mw.m[1][3] };
    affine W = { V->a * S.a + V->b * S.d, V->a * S.b + V->b * S.e, V->a * S.c + V->b * S.f + V->c,
                 V->d * S.a + V->e * S.d, V->d * S.b + V->e * S.e, V->d * S.c + V->e * S.f + V->f };
    // (the colour scales multiply down, the alpha does not: ALPHA IS WRITTEN DOWN, fj#69 -- a transparent
    // object's children are still drawn)
    float col[4] = { pcol[0] * nd->col[0], pcol[1] * nd->col[1], pcol[2] * nd->col[2], nd->col[3] };
    if (col[3] > 0.0f && e->table == RCO_T_OBJECT && (e->type == 2 || e->type == 26)) {     // Plane, UButton
        int ie = image_of(m, nd);
        const image_c *im = ie >= 0 ? image_get(m, ie) : NULL;
        // THE SIZE MODE (fj#73): a Plane's unknownInt18 / a UButton's unknownInt32 says whether the image
        // fills the object's width x height (0) or is drawn at its own size (0xFFFF on a Plane, -1 on a
        // UButton; the library has no other value), the object's scale applied either way. The Rock's
        // scene titles (62 .. 235 x 10 .. 12 in one 470 x 24 box, x 1.9) are drawn their own width on
        // the PSP (the maintainer's photo, 2026-10-08: "01. LOGOS" ~128 units wide, 62 x 1.9 = 118,
        // not 893); the planes that fill their box there (plnBGGrid 854 x 480 for 427 x 240, the bars)
        // carry 0. The library's 246 RCOs: 1,656 objects carry the flag, 1,491 of them with no box
        // (drawn at the image's size already); the other 165 are text in a box sized for another
        // language or the longest title, X-Men's arrows (114 x 36 in 498 x 66), Hackers' square icon in
        // a 256 x 72 box (docs/p9.md M4i). JPCSP does not read the word (it always fills the box).
        // A script's texture is drawn at ITS size. No script sizes a Plane or a UButton (setSize only
        // on movieplayer), so a flagged object's width / height is never read here.
        float qw = nd->size[0], qh = nd->size[1];
        int fw = (int)attr_f(e, e->type == 2 ? "unknownInt18" : "unknownInt32", 0.0f);
        if (fw != 0 && fw != 0xFFFF && fw != -1 && !m->fit_warned) {
            m->fit_warned = 1;
            mtrace(m, "SIZE %s: size mode %d not understood (drawn at the image's size)", e->label, fw);
        }
        if (im) {
            if (qw == 0 || fw != 0) qw = (float)im->w;
            if (qh == 0 || fw != 0) qh = (float)im->h;
        }
        // iconOffset is the object's ANCHOR, two digits (P9, MCR disc 2's highlights, 2026-10-04): the
        // low one horizontal -- 0 the centre, 1 the left edge, 2 the right --, the high one vertical
        // -- 0 the centre, 1 the top edge, 2 the bottom: its position is that point of the quad, and
        // it scales about it (Austin Powers 2 measured 1 on a PSP capture; 17 = top-left lines MCR's
        // highlights up with its video's text and puts Kill Bill's 868-wide lines on the screen's
        // top and bottom rows; Stargate's 16 / 32 banners hang from the top / stand on the bottom).
        // The library: 0, 1, 2, 16, 17, 32, 33, 34 (docs/p9.md M4b). The anchor is a translation in
        // the object's own space, before its scale; the children keep the object's frame.
        int io = (int)attr_f(e, "iconOffset", 0.0f), ah = io & 15, av = (io >> 4) & 15;
        if ((ah > 2 || av > 2 || io < 0) && !m->io_warned) {
            m->io_warned = 1;
            mtrace(m, "ANCHOR %s: iconOffset %d not understood (drawn from its centre)", e->label, io);
        }
        float dx = ah == 1 ? qw * 0.5f : ah == 2 ? -qw * 0.5f : 0.0f;
        float dy = av == 1 ? -qh * 0.5f : av == 2 ? qh * 0.5f : 0.0f;
        affine Wq = W;
        Wq.c += W.a * dx + W.b * dy;
        Wq.f += W.d * dx + W.e * dy;
        if (im || (e->type == 2 && ie < 0)) collect_quad(m, ni, ie, cw, ch, &Wq, qw, qh, im, col);
    }
    for (int c = e->first; c >= 0; c = m->r.e[c].next)
        if (m->by_ent[c] >= 0) collect_node(m, cw, ch, m->by_ent[c], &Mw, V, col);
}

void menu_trace_draw(menu *m, int on) { m->trace_draw = on; }
void menu_render_general(menu *m, int on) { m->general_only = on; }
void menu_item_cache(menu *m, int on) { m->ic_off = !on; }

uint32_t menu_render(menu *m, uint8_t *px, int w, int h, int stride, int layout)
{
    return menu_render_view(m, px, w, h, stride, layout, -427.0f, 240.0f, 854.0f, 480.0f);
}

// the frame's draw list (m->dl): the pages in the RCO's order; a page's own state (its root's tweens)
// carries down
static void collect(menu *m, int w, int h, float sx, float sy, float sw, float sh)
{
    m->ndl = 0;
    if (!m->nodes || m->err[0]) return;
    // the scene's space (854 x 480, origin at the centre, y up): the view's rectangle onto the whole target
    affine root = { (float)w / sw, 0, -sx * (float)w / sw, 0, -(float)h / sh, sy * (float)h / sh };
    const float one[4] = { 1, 1, 1, 1 };
    const mat34 ident = { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 } } };
    for (int i = 0; i < m->nnodes; i++)
        if (m->nodes[i].table == RCO_T_OBJECT && m->nodes[i].type == 1)
            collect_node(m, w, h, i, &ident, &root, one);
}

// THE ITEM CACHE (fj#74): an item whose draw-list entry -- every field that decides its pixels, the damage
// renderer's key -- is the previous frame's produces the same source again: its source values at the
// target's resolution (premultiplied, modulated, in the target's layout: exactly what the drawing paths
// blend) are kept, and later frames blend from them -- one load and the blend, no line fill, no filter.
// The values are taken by drawing the item onto a cleared buffer: a blend over 0 returns the source
// exactly (keep x 0 + 128 rounds to 0, nothing saturates), and a pixel the source leaves out stays 0,
// which the cached draw skips as the paths skip it. Only the incremental render uses the caches; the
// full render (the benches' reference, menu_host_check's CORE INC check every frame) draws everything,
// so a stale entry differs there. An entry is built once an item is unchanged for one frame (a moving
// item never pays for one), for the axis paths only, from IC_MIN pixels; IC_MAX bounds the memory (a
// trace line when it is reached: the item is then drawn as before). The Rock's main menu: the grid, the
// overlay, the eight bars and the buttons cached, the moving background and boxes not.
#define IC_MIN 1024
#define IC_MAX (24u << 20)
typedef struct icache {
    uint8_t   key[DR_KEY_BYTES];
    int       have, stable;
    int       x0, y0, x1, y1;   // the box the values cover (the item's, on the target)
    uint32_t *s;
} icache;

static void ic_drop(menu *m, icache *c)
{
    if (!c->s) return;
    m->ic_bytes -= (size_t)(c->x1 - c->x0) * (size_t)(c->y1 - c->y0) * 4;
    free(c->s);
    c->s = NULL;
}

static void ic_free_all(menu *m)
{
    for (int i = 0; i < m->ic_n; i++) ic_drop(m, &m->ic[i]);
    free(m->ic);
    m->ic = NULL; m->ic_n = 0; m->ic_bytes = 0;
}

static int axis_of(const menu *m, const dritem *it)            // draw_item's choice of draw_axis
{
    const affine *A = &it->A;
    return !m->general_only && A->a > 0.0f && A->e != 0.0f && fabsf(A->b) <= 1e-5f * A->a && fabsf(A->d) <= 1e-5f * fabsf(A->e);
}

// this frame's list against the entries: unchanged ones count up (and are built at the second frame),
// changed ones are dropped
static void ic_update(menu *m, const canvas *cv)
{
    if (m->ic_off) { if (m->ic) ic_free_all(m); return; }
    if (m->ic_n != m->nnodes) {
        ic_free_all(m);
        m->ic = (icache *)calloc((size_t)m->nnodes + 1, sizeof(icache));
        if (!m->ic) return;
        m->ic_n = m->nnodes;
    }
    for (int i = 0; i < m->ndl; i++) {
        const dritem *it = &m->dl[i];
        if (it->ni < 0 || it->ni >= m->ic_n) continue;
        icache *c = &m->ic[it->ni];
        if (c->have && !memcmp(c->key, it, DR_KEY_BYTES)) c->stable++;
        else {
            ic_drop(m, c);
            memcpy(c->key, it, DR_KEY_BYTES);
            c->have = 1;
            c->stable = 0;
        }
        if (c->s || c->stable < 1 || !it->im || !axis_of(m, it)) continue;
        int bw = it->bx1 - it->bx0, bh = it->by1 - it->by0;
        if (bw <= 0 || bh <= 0 || (long)bw * bh < IC_MIN) continue;
        size_t bytes = (size_t)bw * (size_t)bh * 4;
        if (m->ic_bytes + bytes > IC_MAX) {
            if (!m->ic_warned) { m->ic_warned = 1; mtrace(m, "CACHE full (%u bytes): %s drawn uncached", (unsigned)m->ic_bytes, m->r.e[m->nodes[it->ni].ent].label); }
            continue;
        }
        c->s = (uint32_t *)calloc((size_t)bw * (size_t)bh, 4);
        if (!c->s) continue;
        c->x0 = it->bx0; c->y0 = it->by0; c->x1 = it->bx1; c->y1 = it->by1;
        // the item drawn onto the cleared buffer, in the target's coordinates (the buffer's origin at the box)
        canvas cc = { (uint8_t *)((uintptr_t)c->s - (size_t)c->y0 * (size_t)bw * 4 - (size_t)c->x0 * 4), cv->w, cv->h,
                      bw * 4, cv->ri, cv->bi, 0 };
        const int box[4] = { c->x0, c->y0, c->x1, c->y1 };
        draw_item(m, &cc, it, box);
        m->ic_bytes += bytes;
        m->ic_built++;
    }
}

// an item from its entry, only inside clip: the blend of the drawing paths (draw_axis's line path)
static void draw_cached(canvas *cv, const icache *c, const int *clip)
{
    int x0 = c->x0 > clip[0] ? c->x0 : clip[0], x1 = c->x1 < clip[2] ? c->x1 : clip[2];
    int y0 = c->y0 > clip[1] ? c->y0 : clip[1], y1 = c->y1 < clip[3] ? c->y1 : clip[3];
    if (x0 >= x1 || y0 >= y1) return;
    int bw = c->x1 - c->x0, nx = x1 - x0;
    uint32_t n = 0;
    for (int Y = y0; Y < y1; Y++) {
        const uint32_t *sr = c->s + (size_t)(Y - c->y0) * (size_t)bw + (size_t)(x0 - c->x0);
        uint32_t *o = (uint32_t *)(cv->px + (size_t)Y * (size_t)cv->stride) + x0;
        int i = 0;
#ifdef MENU_VEC
        {
            const u16x8 c80 = (u16x8){0} + 0x80, c255 = (u16x8){0} + 255;
            const u32x4 lanes = (u32x4){0} + LANES;
            u32x4 nb = { 0, 0, 0, 0 };
            for (; i + 4 <= nx; i += 4) {
                __builtin_prefetch(sr + i + 64);            // (the entry streams from DRAM: the A9 waits on each line's miss)
                u32x4 s = ld32(sr + i);
                nb -= (u32x4)(s != 0);
                u16x8 rb = (u16x8)(s & lanes), ga = (u16x8)((s >> 8) & lanes);
                u16x8 keep = c255 - __builtin_shuffle(ga, (u16x8){ 1, 1, 3, 3, 5, 5, 7, 7 });
                u32x4 d = ld32(o + i);
                u16x8 trb = (u16x8)(d & lanes) * keep + c80, tga = (u16x8)((d >> 8) & lanes) * keep + c80;
                u16x8 orb = min255(rb + ((trb + (trb >> 8)) >> 8)), oga = min255(ga + ((tga + (tga >> 8)) >> 8));
                st32(o + i, (u32x4)orb | ((u32x4)oga << 8));
            }
            n += nb[0] + nb[1] + nb[2] + nb[3];
        }
#endif
        for (; i < nx; i++) {
            uint32_t s = sr[i];
            if (!s) continue;
            uint32_t s_rb = s & LANES, s_ga = (s >> 8) & LANES, sa = s >> 24, out;
            if (sa >= 255) out = s;
            else {
                uint32_t dpx = o[i], keep = 255 - sa;
                uint32_t o_rb = s_rb + div255x2((dpx & LANES) * keep + 0x00800080u);
                uint32_t o_ga = s_ga + div255x2(((dpx >> 8) & LANES) * keep + 0x00800080u);
                o_rb |= ((o_rb & 0x01000100u) >> 8) * 0xFF; o_ga |= ((o_ga & 0x01000100u) >> 8) * 0xFF;
                out = (o_rb & LANES) | (o_ga & LANES) << 8;
            }
            o[i] = out;
            n++;
        }
    }
    cv->blended += n;
}

// an item of the incremental render: from its entry when it has one
static void draw_one(menu *m, canvas *cv, const dritem *it, const int *clip, int cached)
{
    const icache *c = (cached && m->ic && it->ni >= 0 && it->ni < m->ic_n) ? &m->ic[it->ni] : NULL;
    if (c && c->s) draw_cached(cv, c, clip);
    else draw_item(m, cv, it, clip);
}

// THE BANDS (fj#74): a rectangle is drawn BAND rows at a time, every item into one band before the next, so
// the band stays in the A9's caches through all of a frame's layers (its L2 is 512 KB, a 720 x 480 frame
// 1.38 MB: drawn layer by layer, The Rock's 24 items streamed the whole frame to and from DRAM 24 times).
// A clipped draw writes exactly the pixels the whole draw writes there (draw_axis's clip), so the result
// is the same; each band costs every item its setup again (and the line cache its two first lines).
#define BAND 32
static void draw_rect(menu *m, canvas *cv, const int *c, int cached)
{
    for (int y0 = c[1]; y0 < c[3]; y0 += BAND) {
        int b[4] = { c[0], y0, c[2], y0 + BAND < c[3] ? y0 + BAND : c[3] };
        for (int i = 0; i < m->ndl; i++) draw_one(m, cv, &m->dl[i], b, cached);
    }
}

uint32_t menu_render_view(menu *m, uint8_t *px, int w, int h, int stride, int layout,
                          float sx, float sy, float sw, float sh)
{
    m->dirty = 0;
    for (int y = 0; y < h; y++) memset(px + (size_t)y * (size_t)stride, 0, (size_t)w * 4);
    collect(m, w, h, sx, sy, sw, sh);
    canvas cv = { px, w, h, stride, layout == MENU_PX_PLANE ? 2 : 0, layout == MENU_PX_PLANE ? 0 : 2, 0 };
    const int all[4] = { 0, 0, w, h };
    draw_rect(m, &cv, all, 0);                   // (no item cache: the benches' reference)
    return cv.blended;
}

// the damage: at most DMG_MAX rectangles, merged when they overlap (or when one more is needed: the
// pair whose union grows least)
static void dmg_add(int (*d)[4], int *n, int x0, int y0, int x1, int y1)
{
    if (x0 >= x1 || y0 >= y1) return;
    int r[4] = { x0, y0, x1, y1 };
    for (;;) {
        int hit = -1;
        for (int i = 0; i < *n && hit < 0; i++)
            if (r[0] <= d[i][2] && d[i][0] <= r[2] && r[1] <= d[i][3] && d[i][1] <= r[3]) hit = i;
        if (hit < 0) break;
        if (d[hit][0] < r[0]) r[0] = d[hit][0];
        if (d[hit][1] < r[1]) r[1] = d[hit][1];
        if (d[hit][2] > r[2]) r[2] = d[hit][2];
        if (d[hit][3] > r[3]) r[3] = d[hit][3];
        d[hit][0] = d[*n - 1][0]; d[hit][1] = d[*n - 1][1]; d[hit][2] = d[*n - 1][2]; d[hit][3] = d[*n - 1][3];
        (*n)--;
    }
    if (*n < DMG_MAX) { memcpy(d[(*n)++], r, sizeof(r)); return; }
    int best = 0;
    long grow = -1;
    for (int i = 0; i < *n; i++) {
        long ux0 = d[i][0] < r[0] ? d[i][0] : r[0], uy0 = d[i][1] < r[1] ? d[i][1] : r[1];
        long ux1 = d[i][2] > r[2] ? d[i][2] : r[2], uy1 = d[i][3] > r[3] ? d[i][3] : r[3];
        long g = (ux1 - ux0) * (uy1 - uy0) - (long)(d[i][2] - d[i][0]) * (d[i][3] - d[i][1]);
        if (grow < 0 || g < grow) { grow = g; best = i; }
    }
    int x0b = d[best][0], y0b = d[best][1], x1b = d[best][2], y1b = d[best][3];
    d[best][0] = d[*n - 1][0]; d[best][1] = d[*n - 1][1]; d[best][2] = d[*n - 1][2]; d[best][3] = d[*n - 1][3];
    (*n)--;
    dmg_add(d, n, x0b < r[0] ? x0b : r[0], y0b < r[1] ? y0b : r[1], x1b > r[2] ? x1b : r[2], y1b > r[3] ? y1b : r[3]);
}

uint32_t menu_render_view_inc(menu *m, uint8_t *px, int w, int h, int stride, int layout,
                              float sx, float sy, float sw, float sh)
{
    m->dirty = 0;
    // the target must be the one the previous incremental frame was drawn into, unchanged since --
    // the same buffer, geometry, layout, view and path -- else the frame is drawn whole
    int same = m->inc_valid && m->inc_px == px && m->inc_w == w && m->inc_h == h && m->inc_stride == stride &&
               m->inc_layout == layout && m->inc_view[0] == sx && m->inc_view[1] == sy && m->inc_view[2] == sw &&
               m->inc_view[3] == sh && m->inc_general == m->general_only;
    // this frame's list into m->dl (the spare); the previous incremental frame's stays in m->dl_prev
    // (a full render between two incremental ones fills only the spare: it never disturbs that)
    const dritem *prev = m->dl_prev;
    int nprev = m->ndl_prev;
    collect(m, w, h, sx, sy, sw, sh);
    canvas cv = { px, w, h, stride, layout == MENU_PX_PLANE ? 2 : 0, layout == MENU_PX_PLANE ? 0 : 2, 0 };
    ic_update(m, &cv);
    int d[DMG_MAX][4], nd = 0;
    if (!same) {
        d[0][0] = 0; d[0][1] = 0; d[0][2] = w; d[0][3] = h; nd = 1;
    } else {
        int n = m->ndl > nprev ? m->ndl : nprev;
        for (int i = 0; i < n; i++) {
            const dritem *a = i < m->ndl ? &m->dl[i] : NULL, *b = i < nprev ? &prev[i] : NULL;
            if (a && b && !memcmp(a, b, DR_KEY_BYTES)) continue;
            if (a) dmg_add(d, &nd, a->bx0, a->by0, a->bx1, a->by1);
            if (b) dmg_add(d, &nd, b->bx0, b->by0, b->bx1, b->by1);
        }
    }
    m->n_dmg_last = 0;
    for (int k = 0; k < nd; k++) {
        int *c = d[k];
        if (c[0] < 0) c[0] = 0;
        if (c[1] < 0) c[1] = 0;
        if (c[2] > w) c[2] = w;
        if (c[3] > h) c[3] = h;
        if (c[0] >= c[2] || c[1] >= c[3]) continue;
        memcpy(m->dmg_last[m->n_dmg_last++], c, sizeof(m->dmg_last[0]));
        for (int y = c[1]; y < c[3]; y++) memset(px + (size_t)y * (size_t)stride + 4 * (size_t)c[0], 0, 4 * (size_t)(c[2] - c[0]));
#ifdef MENU_PROF
        if (m->prof_n != m->nnodes) {
            free(m->prof_ns); free(m->prof_px);
            m->prof_ns = (uint64_t *)calloc((size_t)m->nnodes + 1, sizeof(uint64_t));
            m->prof_px = (uint64_t *)calloc((size_t)m->nnodes + 1, sizeof(uint64_t));
            m->prof_n = m->prof_ns && m->prof_px ? m->nnodes : 0;
        }
        for (int y0 = c[1]; y0 < c[3]; y0 += BAND)
        for (int i = 0; i < m->ndl; i++) {
            int bb[4] = { c[0], y0, c[2], y0 + BAND < c[3] ? y0 + BAND : c[3] };
            struct timespec t0, t1;
            uint32_t b0 = cv.blended;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            draw_one(m, &cv, &m->dl[i], bb, 1);
            clock_gettime(CLOCK_MONOTONIC, &t1);
            int ni = m->dl[i].ni;
            if (ni >= 0 && ni < m->prof_n) {
                m->prof_ns[ni] += (uint64_t)((t1.tv_sec - t0.tv_sec) * 1000000000LL + (t1.tv_nsec - t0.tv_nsec));
                m->prof_px[ni] += cv.blended - b0;
            }
        }
#else
        draw_rect(m, &cv, c, 1);
#endif
        m->inc_damaged += (uint64_t)(c[2] - c[0]) * (uint64_t)(c[3] - c[1]);
    }
    // this frame becomes the previous one
    { dritem *t = m->dl_prev; int tc = m->dl_prev_cap; m->dl_prev = m->dl; m->dl_prev_cap = m->dl_cap; m->dl = t; m->dl_cap = tc; }
    m->ndl_prev = m->ndl; m->ndl = 0;
    m->inc_valid = !m->err[0]; m->inc_px = px; m->inc_w = w; m->inc_h = h; m->inc_stride = stride; m->inc_layout = layout;
    m->inc_view[0] = sx; m->inc_view[1] = sy; m->inc_view[2] = sw; m->inc_view[3] = sh; m->inc_general = m->general_only;
    return cv.blended;
}

uint32_t menu_render_inc(menu *m, uint8_t *px, int w, int h, int stride, int layout)
{
    return menu_render_view_inc(m, px, w, h, stride, layout, -427.0f, 240.0f, 854.0f, 480.0f);
}

uint64_t menu_inc_damaged(const menu *m) { return m->inc_damaged; }

int menu_inc_damage(const menu *m, int (*r)[4], int max)
{
    int n = m->n_dmg_last < max ? m->n_dmg_last : max;
    memcpy(r, m->dmg_last, (size_t)n * sizeof(m->dmg_last[0]));
    return n;
}

// THE CANVAS SCALE (M4h, docs/p9.md): the menu is drawn at the PSP's own 480 x 272 (the canvas) and this
// stretches it onto the plane -- the PSP's TV out keeps the video at 720 x 480 under its menus (measured,
// p9.md M4h); the canvas is what the PSP's own screen shows (art at a fractional place or scale is resampled
// twice: a little softer than a direct draw at 720 x 480). The source rectangle (rx, ry, rw, rh, in source pixels: a CRT fit's view) onto the whole of
// dst, bilinear with draw_axis's conventions: 16.16 positions at the pixel centres, weights 0..256, clamped
// at the source's edges, horizontal first (R / B and G / A in 16-bit lanes), then vertical. Every channel
// alike (any byte layout; premultiplied, so no fringe). The target is WRITTEN, not blended. A pixel's
// position is first + X x step, never accumulated, so a clipped call writes exactly what the whole call
// writes there (the runner scales only the damage). Each source row's horizontal pass is kept in one of two
// lines (THE LINE CACHE), the columns' (u0, u1, fu) computed once a call.
void menu_scale(const uint8_t *src, int sw, int sh, int sstride, uint8_t *dst, int dw, int dh, int dstride,
                float rx, float ry, float rw, float rh, const int *clip)
{
    int cx0 = clip ? clip[0] : 0, cy0 = clip ? clip[1] : 0, cx1 = clip ? clip[2] : dw, cy1 = clip ? clip[3] : dh;
    if (cx0 < 0) cx0 = 0;
    if (cy0 < 0) cy0 = 0;
    if (cx1 > dw) cx1 = dw;
    if (cy1 > dh) cy1 = dh;
    if (cx0 >= cx1 || cy0 >= cy1 || sw <= 0 || sh <= 0) return;
    int32_t du = (int32_t)lroundf(rw / (float)dw * 65536.0f), dv = (int32_t)lroundf(rh / (float)dh * 65536.0f);
    int32_t u_first = (int32_t)lroundf((rx + 0.5f * rw / (float)dw - 0.5f) * 65536.0f);
    int32_t v_first = (int32_t)lroundf((ry + 0.5f * rh / (float)dh - 0.5f) * 65536.0f);
    int nx = cx1 - cx0;
    uint32_t *t = (uint32_t *)malloc((size_t)nx * 7 * sizeof(uint32_t));
    if (!t) return;
    uint32_t *lrb[2] = { t, t + 2 * nx }, *lga[2] = { t + nx, t + 3 * nx };
    uint32_t *cu0 = t + 4 * nx, *cu1 = t + 5 * nx, *cfw = t + 6 * nx;
    for (int i = 0; i < nx; i++) {
        int32_t U = u_first + (int32_t)(cx0 + i) * du;
        int u0 = U >> 16, u1 = u0 + 1;
        uint32_t fu = ((uint32_t)U >> 8) & 0xFF;
        if (u0 < 0) u0 = 0;
        if (u1 < 0) u1 = 0;
        if (u0 > sw - 1) u0 = sw - 1;
        if (u1 > sw - 1) u1 = sw - 1;
        cu0[i] = (uint32_t)u0; cu1[i] = (uint32_t)u1; cfw[i] = fu | fu << 16;
    }
#ifdef MENU_VEC
    // THE WINDOW (the A9: a fetch of four texel pairs by eight loads into vector lanes cost ~39 ns a pixel,
    // the fill 7.7 of the stretch's 13 ms): stretched UP, four neighbouring target columns read within eight
    // neighbouring source pixels, so a group's two vectors of texels are two byte shuffles (vtbl) of one
    // 32-byte load at the group's base -- the same texels, the same result. A group whose texels lie further
    // apart (a downscale) or a source under 8 wide keeps the per-lane fetch (gw[g] < 0).
    typedef uint8_t u8x16 __attribute__((vector_size(16)));
    typedef uint8_t u8x16_ua __attribute__((vector_size(16), aligned(4), may_alias));
    int ng = nx / 4;
    int32_t *gw = (int32_t *)malloc((size_t)(ng ? ng : 1) * sizeof(int32_t));
    u8x16 *gm = gw ? (u8x16 *)malloc((size_t)(ng ? ng : 1) * 2 * sizeof(u8x16)) : NULL;
    if (!gm) { free(gw); gw = NULL; }
    for (int g = 0; gw && g < ng; g++) {
        int i = 4 * g, base = (int)cu0[i];
        if (base > sw - 8) base = sw - 8;
        gw[g] = base;
        for (int k = 0; k < 4 && gw[g] >= 0; k++)
            if ((int)cu0[i + k] < base || (int)cu0[i + k] > base + 7 || (int)cu1[i + k] < base || (int)cu1[i + k] > base + 7) gw[g] = -1;
        if (gw[g] < 0) continue;
        u8x16 m0, m1;
        for (int k = 0; k < 4; k++)
            for (int b = 0; b < 4; b++) {
                m0[4 * k + b] = (uint8_t)(4 * ((int)cu0[i + k] - base) + b);
                m1[4 * k + b] = (uint8_t)(4 * ((int)cu1[i + k] - base) + b);
            }
        gm[2 * g] = m0; gm[2 * g + 1] = m1;
    }
#endif
    int lkey[2] = { -1, -1 };
    for (int Y = cy0; Y < cy1; Y++) {
        int32_t V = v_first + (int32_t)Y * dv;
        int v0 = V >> 16, v1 = v0 + 1;
        uint32_t fv = ((uint32_t)V >> 8) & 0xFF;
        if (v0 < 0) v0 = 0;
        if (v1 < 0) v1 = 0;
        if (v0 > sh - 1) v0 = sh - 1;
        if (v1 > sh - 1) v1 = sh - 1;
        int want[2] = { v0, v1 }, at[2];
        for (int k = 0; k < 2; k++) at[k] = lkey[0] == want[k] ? 0 : lkey[1] == want[k] ? 1 : -1;
        for (int k = 0; k < 2; k++) {
            if (at[k] >= 0) continue;
            int slot = (at[1 - k] == 0) ? 1 : (at[1 - k] == 1) ? 0 : k;   // (not the line the other row uses)
            if (k == 1 && at[0] == slot) slot = 1 - slot;
            const uint32_t *tr = (const uint32_t *)(src + (size_t)want[k] * (size_t)sstride);
            uint32_t *hrb = lrb[slot], *hga = lga[slot];
            int i = 0;
#ifdef MENU_VEC
            {
                const u32x4 lanes = (u32x4){0} + LANES;
                const u16x8 c256 = (u16x8){0} + 256;
                for (; i + 4 <= nx; i += 4) {
                    u32x4 p0, p1;
                    int g = i >> 2;
                    if (gw && gw[g] >= 0) {
                        const uint32_t *wp = tr + gw[g];
                        u8x16 lo = *(const u8x16_ua *)wp, hi = *(const u8x16_ua *)(wp + 4);
                        p0 = (u32x4)__builtin_shuffle(lo, hi, gm[2 * g]);
                        p1 = (u32x4)__builtin_shuffle(lo, hi, gm[2 * g + 1]);
                    } else {
                        p0 = (u32x4){ tr[cu0[i]], tr[cu0[i + 1]], tr[cu0[i + 2]], tr[cu0[i + 3]] };
                        p1 = (u32x4){ tr[cu1[i]], tr[cu1[i + 1]], tr[cu1[i + 2]], tr[cu1[i + 3]] };
                    }
                    u16x8 w = ld16(cfw + i), iw = c256 - w;
                    st32(hrb + i, (u32x4)(((u16x8)(p0 & lanes) * iw + (u16x8)(p1 & lanes) * w) >> 8));
                    st32(hga + i, (u32x4)(((u16x8)((p0 >> 8) & lanes) * iw + (u16x8)((p1 >> 8) & lanes) * w) >> 8));
                }
            }
#endif
            for (; i < nx; i++) {
                uint32_t p0 = tr[cu0[i]], p1 = tr[cu1[i]], fu = cfw[i] & 0xFF;
                hrb[i] = lerp2(p0 & LANES, p1 & LANES, fu);
                hga[i] = lerp2((p0 >> 8) & LANES, (p1 >> 8) & LANES, fu);
            }
            lkey[slot] = want[k];
            at[k] = slot;
        }
        const uint32_t *a_rb = lrb[at[0]], *a_ga = lga[at[0]], *b_rb = lrb[at[1]], *b_ga = lga[at[1]];
        uint32_t *o = (uint32_t *)(dst + (size_t)Y * (size_t)dstride) + cx0;
        int i = 0;
#ifdef MENU_VEC
        {
            const u16x8 w1 = (u16x8){0} + (uint16_t)(256u - fv), w2 = (u16x8){0} + (uint16_t)fv;
            for (; i + 4 <= nx; i += 4) {
                u16x8 rb = (ld16(a_rb + i) * w1 + ld16(b_rb + i) * w2) >> 8;
                u16x8 ga = (ld16(a_ga + i) * w1 + ld16(b_ga + i) * w2) >> 8;
                st32(o + i, (u32x4)rb | ((u32x4)ga << 8));
            }
        }
#endif
        for (; i < nx; i++) o[i] = lerp2(a_rb[i], b_rb[i], fv) | lerp2(a_ga[i], b_ga[i], fv) << 8;
    }
#ifdef MENU_VEC
    free(gw); free(gm);
#endif
    free(t);
}

#ifdef MENU_PROF
// the incremental draws' cost per node since the resource loaded: "PROF label ms px ns/px", the costliest first
void menu_prof_dump(menu *m, void (*out)(const char *line, void *ud), void *ud)
{
    char h[200];
    snprintf(h, sizeof(h), "PROF line fills %.1f ms (%llu px, %.1f ns/px); line steps %.1f ms (%llu px, %.1f ns/px)",
             (double)m->prof_fill_ns / 1e6, (unsigned long long)m->prof_fill_px, m->prof_fill_px ? (double)m->prof_fill_ns / (double)m->prof_fill_px : 0.0,
             (double)m->prof_step_ns / 1e6, (unsigned long long)m->prof_step_px, m->prof_step_px ? (double)m->prof_step_ns / (double)m->prof_step_px : 0.0);
    out(h, ud);
    for (int k = 0; k < 40; k++) {
        int best = -1;
        for (int i = 0; i < m->prof_n; i++) if (m->prof_ns[i] && (best < 0 || m->prof_ns[i] > m->prof_ns[best])) best = i;
        if (best < 0) break;
        char b[200];
        snprintf(b, sizeof(b), "PROF %-24s %9.1f ms %11llu px %6.1f ns/px", m->r.e[m->nodes[best].ent].label,
                 (double)m->prof_ns[best] / 1e6, (unsigned long long)m->prof_px[best],
                 m->prof_px[best] ? (double)m->prof_ns[best] / (double)m->prof_px[best] : 0.0);
        out(b, ud);
        m->prof_ns[best] = 0;
    }
}
#endif

static int load(menu *m, const char *name)
{
    const uint8_t *buf;
    size_t len;
    if (!m->h.load_rco || m->h.load_rco(m->h.ud, name, &buf, &len)) { merr(m, "no RESOURCE/%s.RCO", name); return -1; }
    // the previous resource goes
    for (int i = 0; i < m->ntimers; i++) { (void)0; }
    m->ntimers = 0; m->nruns = 0; m->focus = -1; m->active_page = -1; m->ntw = 0; m->poll_node = -1;
    m->inc_valid = 0; m->ndl = 0; m->ndl_prev = 0;     // (the draw lists name nodes and images of this resource)
    ic_free_all(m);                                   // (so do the item caches)
    images_free(m);
    if (m->v) vm_free(m->v);
    m->v = NULL;
    rco_free(&m->r);
    free(m->nodes); free(m->by_ent);
    m->nodes = NULL; m->by_ent = NULL; m->nnodes = 0;
    if (rco_load(&m->r, buf, len)) { merr(m, "%s.RCO: %s", name, m->r.err); return -1; }
    if (m->r.vsmx < 0) { merr(m, "%s.RCO has no script", name); return -1; }
    char err[200];
    vm_limits lim = { 65536, 256, 1u << 20 };
    m->v = vm_new(m->r.vsmx_data, m->r.vsmx_len, &lim, err, sizeof(err));
    if (!m->v) { merr(m, "%s.RCO's script: %s", name, err); return -1; }
    vm_set_trace(m->v, vm_tr, m);
    snprintf(m->cur, sizeof(m->cur), "%s", name);
    mtrace(m, "RESOURCE %s (%d entries, %u script instructions)", name, m->r.n, m->r.vsmx_len / 8);

    vm *v = m->v;
    vm_obj *g = vm_globals(v);
    m->nodes = (node *)calloc((size_t)m->r.n, sizeof(node));
    m->by_ent = (int *)malloc((size_t)m->r.n * sizeof(int));
    if (!m->nodes || !m->by_ent) { merr(m, "out of memory"); return -1; }
    for (int i = 0; i < m->r.n; i++) m->by_ent[i] = -1;
    m->img = (image_c *)calloc((size_t)m->r.n, sizeof(image_c));
    m->snd = (struct sound_c *)calloc((size_t)m->r.n, sizeof(*m->snd));
    if (!m->img || !m->snd) { merr(m, "out of memory"); return -1; }
    // the prototypes of the scene's objects (their natives)
    m->proto_obj = vm_new_object(v, "Object.proto");
    m->proto_page = vm_new_object(v, "Page.proto");
    m->proto_anim = vm_new_object(v, "Anim.proto");
    m->proto_sound = vm_new_object(v, "Sound.proto");
    m->proto_image = vm_new_object(v, "Image.proto");
    m->proto_page->proto = m->proto_obj;
    vm_root_add(v, m->proto_obj); vm_root_add(v, m->proto_page); vm_root_add(v, m->proto_anim);
    vm_root_add(v, m->proto_sound); vm_root_add(v, m->proto_image);
    natf(m, m->proto_obj, "setPos", n_setPos);     natf(m, m->proto_obj, "animPos", n_animPos);
    natf(m, m->proto_obj, "getPos", n_getPos);
    natf(m, m->proto_obj, "setColor", n_setColor); natf(m, m->proto_obj, "animColor", n_animColor);
    natf(m, m->proto_obj, "getColor", n_getColor);
    natf(m, m->proto_obj, "setSize", n_setSize);   natf(m, m->proto_obj, "animSize", n_animSize);
    natf(m, m->proto_obj, "getSize", n_getSize);
    natf(m, m->proto_obj, "setScale", n_setScale); natf(m, m->proto_obj, "animScale", n_animScale);
    natf(m, m->proto_obj, "getScale", n_getScale);
    natf(m, m->proto_obj, "setFocus", n_setFocus);
    natf(m, m->proto_obj, "show", n_show);         natf(m, m->proto_obj, "hide", n_hide);
    natf(m, m->proto_obj, "setRotate", n_setRotate); natf(m, m->proto_obj, "animRotate", n_animRotate);
    natf(m, m->proto_obj, "getRotate", n_getRotate);
    natf(m, m->proto_obj, "setCrop", n_setCrop);   natf(m, m->proto_obj, "animCrop", n_animCrop);
    natf(m, m->proto_page, "open", n_open);        natf(m, m->proto_page, "activate", n_activate);
    natf(m, m->proto_page, "close", n_close);
    natf(m, m->proto_anim, "play", n_anim_play);   natf(m, m->proto_anim, "stop", n_anim_stop);
    natf(m, m->proto_sound, "play", n_sound_play); natf(m, m->proto_sound, "stop", n_sound_stop);
    // resource.*table
    vm_obj *res = vm_new_object(v, "resource");
    vm_set(v, g, "resource", vm_objv(res));
    struct { int table; const char *name; } tabs[] = {
        { RCO_T_OBJECT, "pagetable" }, { RCO_T_ANIM, "animtable" }, { RCO_T_SOUND, "soundtable" }, { RCO_T_IMAGE, "texturetable" } };
    for (size_t t = 0; t < sizeof(tabs) / sizeof(tabs[0]); t++) {
        vm_obj *tab = vm_new_object(v, tabs[t].name);
        vm_set(v, res, tabs[t].name, vm_objv(tab));
        for (int i = 0; i < m->r.n; i++)
            if (m->r.e[i].table == tabs[t].table && m->r.e[i].type == 0 && m->r.e[i].depth == 1) { build(m, i, tab, -1, NULL); break; }
    }
    // movieplayer, controller, timer, Math, the global functions
    m->movieplayer = vm_new_object(v, "movieplayer");
    vm_set(v, g, "movieplayer", vm_objv(m->movieplayer));
    natf(m, m->movieplayer, "play", n_mp_play);         natf(m, m->movieplayer, "stop", n_mp_stop);
    natf(m, m->movieplayer, "resume", n_mp_resume);     natf(m, m->movieplayer, "getPlayerStatus", n_mp_status);
    natf(m, m->movieplayer, "getResumeInfo", n_mp_getresume);
    natf(m, m->movieplayer, "changeResumeInfo", n_mp_changeresume);
    natf(m, m->movieplayer, "setSize", n_mp_setsize);   natf(m, m->movieplayer, "setPos", n_mp_setpos);
    natf(m, m->movieplayer, "getSize", n_mp_getsize);   natf(m, m->movieplayer, "getPos", n_mp_getpos);
    vm_set(v, m->movieplayer, "audioLanguageCode", vm_str(v, "en"));
    vm_set(v, m->movieplayer, "subtitleLanguageCode", vm_str(v, "en"));
    m->controller = vm_new_object(v, "controller");
    vm_set(v, g, "controller", vm_objv(m->controller));
    natf(m, m->controller, "getUserData", n_ctl_getuser);
    natf(m, m->controller, "setUserData", n_ctl_setuser);
    natf(m, m->controller, "changeResource", n_ctl_change);
    natf(m, m->controller, "end", n_ctl_end);
    vm_obj *tm = vm_new_object(v, "timer");
    vm_set(v, g, "timer", vm_objv(tm));
    natf(m, tm, "setInterval", n_setinterval);          natf(m, tm, "clearInterval", n_clearinterval);
    vm_obj *mt = vm_new_object(v, "Math");
    vm_set(v, g, "Math", vm_objv(mt));
    natf(m, mt, "floor", n_floor); natf(m, mt, "ceil", n_ceil); natf(m, mt, "round", n_round);
    natf(m, mt, "abs", n_abs); natf(m, mt, "sin", n_sin); natf(m, mt, "cos", n_cos); natf(m, mt, "sqrt", n_sqrt);
    natf(m, mt, "min", n_min); natf(m, mt, "max", n_max); natf(m, mt, "random", n_random);
    vm_set(v, mt, "PI", vm_num(3.14159265f));
    natf(m, g, "writeln", n_writeln);  natf(m, g, "write", n_writeln);
    natf(m, g, "parseInt", n_parseint); natf(m, g, "parseFloat", n_parsefloat); natf(m, g, "isNaN", n_isnan);
    natf(m, g, "Int", n_parseint); natf(m, g, "Float", n_parsefloat);
    if (vm_error(v)[0]) { merr(m, "%s.RCO: %s", name, vm_error(v)); return -1; }
    if (vm_run_main(v)) { merr(m, "%s.RCO's script: %s", name, vm_error(v)); return -1; }
    vm_gc(v);
    return 0;
}

// 1 when the object has the callback (it ran), 0 none
static int callback(menu *m, vm_obj *o, const char *name, int argc, const vm_value *argv)
{
    if (m->err[0] || !o) return 0;
    m->dirty = 1;
    vm_value f = vm_get(m->v, o, name);
    if (!vm_is_func(f)) { mtrace(m, "CALLBACK %s.%s: none", o->cls ? o->cls : "?", name); return 0; }
    mtrace(m, "CALLBACK %s.%s", o->cls ? o->cls : "?", name);
    vm_value r;
    if (vm_call(m->v, f, vm_objv(o), argc, argv, &r)) {
        char w[96];
        snprintf(w, sizeof(w), "%s.%s", o->cls ? o->cls : "?", name);
        call_failed(m, w);
    }
    return 1;
}

// a pending resource change (controller.changeResource), after the run that asked for it
static void change_pending(menu *m)
{
    while (m->next_res[0] && !m->err[0]) {
        char name[16];
        snprintf(name, sizeof(name), "%s", m->next_res);
        m->next_res[0] = 0;
        if (m->h.change_resource) m->h.change_resource(m->h.ud, name);
        if (load(m, name)) return;
        callback(m, m->controller, "onChangeResource", 0, NULL);
        vm_gc(m->v);
    }
}

menu *menu_new(const menu_host *h)
{
    menu *m = (menu *)calloc(1, sizeof(menu));
    if (!m) return NULL;
    m->h = *h;
    m->focus = -1; m->active_page = -1; m->poll_node = -1; m->tw_src = -1;
    m->video[2] = 854.0f; m->video[3] = 480.0f;
    return m;
}

void menu_free(menu *m)
{
    if (!m) return;
    if (m->v) vm_free(m->v);
    images_free(m);
    rco_free(&m->r);
    free(m->nodes); free(m->by_ent);
    free(m->dl); free(m->dl_prev);
    free(m->hl);
    free(m->tw);
    ic_free_all(m);
#ifdef MENU_PROF
    free(m->prof_ns); free(m->prof_px);
#endif
    kept_free(&m->userdata);
    free(m);
}

// ---- relaunch: the kept user data as text (n<float>; b0|b1; s<len>:<bytes>; a<count> <items>;
// o<count> <s-key value>...; u undefined; z null) -----------------------------------------------------
static size_t kept_out(const kept *k, char *buf, size_t cap, size_t at)
{
    char tmp[48];
    int l;
    switch (k->t) {
    case V_NUM:  l = snprintf(tmp, sizeof(tmp), "n%.9g;", (double)k->n); break;
    case V_BOOL: l = snprintf(tmp, sizeof(tmp), "b%d", k->b ? 1 : 0); break;
    case V_NULL: l = snprintf(tmp, sizeof(tmp), "z"); break;
    case V_STR:  l = snprintf(tmp, sizeof(tmp), "s%u:", (unsigned)strlen(k->s)); break;
    case V_OBJ:  l = snprintf(tmp, sizeof(tmp), "%c%d ", k->is_array ? 'a' : 'o', k->nkids); break;
    default:     l = snprintf(tmp, sizeof(tmp), "u"); break;
    }
    for (int i = 0; i < l; i++, at++) if (at < cap) buf[at] = tmp[i];
    if (k->t == V_STR) for (const char *p = k->s; *p; p++, at++) if (at < cap) buf[at] = *p;
    if (k->t == V_OBJ)
        for (int i = 0; i < k->nkids; i++) {
            if (!k->is_array) {
                l = snprintf(tmp, sizeof(tmp), "s%u:", (unsigned)strlen(k->keys[i]));
                for (int j = 0; j < l; j++, at++) if (at < cap) buf[at] = tmp[j];
                for (const char *p = k->keys[i]; *p; p++, at++) if (at < cap) buf[at] = *p;
            }
            at = kept_out(&k->kids[i], buf, cap, at);
        }
    return at;
}

size_t menu_save(const menu *m, char *buf, size_t cap)
{
    return m->has_userdata ? kept_out(&m->userdata, buf, cap, 0) : 0;
}

// parse one value at *p (< end); 0 ok
static int kept_in(kept *k, const char **p, const char *end, int depth)
{
    memset(k, 0, sizeof(*k));
    if (*p >= end || depth > 8) return -1;
    char c = *(*p)++;
    char *e;
    switch (c) {
    case 'u': k->t = V_UNDEF; return 0;
    case 'z': k->t = V_NULL; return 0;
    case 'b': if (*p >= end) return -1; k->t = V_BOOL; k->b = *(*p)++ == '1'; return 0;
    case 'n': {
        char num[48]; size_t i = 0;
        while (*p < end && **p != ';' && i < sizeof(num) - 1) num[i++] = *(*p)++;
        num[i] = 0;
        if (*p >= end) return -1;
        (*p)++;
        k->t = V_NUM; k->n = strtof(num, &e);
        return e == num ? -1 : 0;
    }
    case 's': {
        unsigned long n = strtoul(*p, &e, 10);
        if (e == *p || e >= end || *e != ':' || (size_t)(end - e - 1) < n) return -1;
        k->t = V_STR; k->s = (char *)malloc(n + 1);
        if (!k->s) return -1;
        memcpy(k->s, e + 1, n); k->s[n] = 0;
        *p = e + 1 + n;
        return 0;
    }
    case 'a': case 'o': {
        long n = strtol(*p, &e, 10);
        if (e == *p || e >= end || *e != ' ' || n < 0 || n > 65536) return -1;
        *p = e + 1;
        k->t = V_OBJ; k->is_array = c == 'a'; k->nkids = (int)n;
        k->kids = (kept *)calloc((size_t)(n ? n : 1), sizeof(kept));
        if (!k->is_array) k->keys = (char **)calloc((size_t)(n ? n : 1), sizeof(char *));
        if (!k->kids || (!k->is_array && !k->keys)) return -1;
        for (long i = 0; i < n; i++) {
            if (!k->is_array) {
                kept key;
                if (kept_in(&key, p, end, depth + 1) || key.t != V_STR) { kept_free(&key); return -1; }
                k->keys[i] = key.s;
            }
            if (kept_in(&k->kids[i], p, end, depth + 1)) return -1;
        }
        return 0;
    }
    default: return -1;
    }
}

int menu_load(menu *m, const char *buf, size_t len)
{
    kept k;
    const char *p = buf;
    if (kept_in(&k, &p, buf + len, 0) || p != buf + len) { kept_free(&k); mtrace(m, "USERDATA malformed: not restored"); return -1; }
    kept_free(&m->userdata);
    m->userdata = k; m->has_userdata = 1;
    mtrace(m, "USERDATA restored (%u bytes)", (unsigned)len);
    return 0;
}

void menu_exit(menu *m)
{
    if (m->err[0] || !m->v) return;
    callback(m, m->controller, "onExit", 0, NULL);
    vm_gc(m->v);
}

int menu_continue(menu *m, const char *name)
{
    if (load(m, name)) return -1;
    callback(m, m->controller, "onContinuePlay", 0, NULL);
    if (m->v) vm_gc(m->v);
    change_pending(m);
    return m->err[0] ? -1 : 0;
}

int menu_start(menu *m, const char *name)
{
    if (load(m, name)) return -1;
    callback(m, m->controller, "onAutoPlay", 0, NULL);
    if (m->v) vm_gc(m->v);
    change_pending(m);
    return m->err[0] ? -1 : 0;
}

void menu_tick(menu *m, uint32_t ms)
{
    // (a busy-wait ran the clock ahead: real time catches up first)
    uint32_t d = m->debt < ms ? m->debt : ms;
    m->debt -= d; ms -= d;
    if (!ms) return;
    uint32_t end = m->now + ms;
    while (!m->err[0]) {
        // the next due timer or animation wake-up within this tick
        uint32_t due = end;
        for (int i = 0; i < m->ntimers; i++) if (m->timers[i].due < due) due = m->timers[i].due;
        for (int i = 0; i < m->nruns; i++) if (m->runs[i].wake > m->now && m->runs[i].wake < due) due = m->runs[i].wake;
        m->now = due;
        anims_tick(m);
        for (int i = 0; i < m->ntimers && !m->err[0]; i++) {
            if (m->timers[i].due > m->now) continue;
            timer_s *t = &m->timers[i];
            t->due += t->period;
            int id = t->id;
            mtrace(m, "TIMER %d", id);
            m->dirty = 1;
            vm_value r;
            vm_obj *fn = t->fn;
            vm_value args[8];
            int n = t->nargs;
            memcpy(args, t->args, sizeof(args));
            if (vm_call(m->v, vm_objv(fn), vm_objv(vm_globals(m->v)), n, args, &r)) {
                char w[32];
                snprintf(w, sizeof(w), "timer %d", id);
                call_failed(m, w);
                if (m->err[0]) break;
            }
        }
        if (m->v) vm_gc(m->v);
        change_pending(m);
        if (m->now >= end) break;
    }
}

int menu_key(menu *m, int key)
{
    static const char *names[MENU_NKEYS] = { "UP", "DOWN", "LEFT", "RIGHT", "CROSS", "CIRCLE", "TRIANGLE",
                                             "SQUARE", "START", "SELECT", "L", "R" };
    if (m->err[0] || key < 0 || key >= MENU_NKEYS) return 0;
    if (keys_locked(m)) { mtrace(m, "KEY %s (locked)", names[key]); return 1; }    // (the engine's: no system action)
    int done = 0;
    m->dirty = 1;
    mtrace(m, "KEY %s (focus %s, page %s)", names[key], m->focus >= 0 ? m->r.e[m->nodes[m->focus].ent].label : "-",
           m->active_page >= 0 ? m->r.e[m->nodes[m->active_page].ent].label : "-");
    // A CLOSED PAGE'S FOCUS TAKES NO KEY (docs/p9.md M4e, Forgejo fj#72): The Office closes its menu pages
    // for an episode, leaves its focus on Nav (pageRootMenu) and opens only pageWaitDummy (no button); Nav's
    // script-set onFocusLeft / Right then lit scene-select highlights in the closed pages and took Left /
    // Right through the whole episode (seeking dead, the rig). A key for the focused object goes to it only
    // while its page is open; else it is not the script's (the system's, umd_menu_host). A MODEL: a page's
    // widgets are gone when it closes (n_open's "built afresh"), so a PSP cannot deliver to them either
    int fo = m->focus;
    if (fo >= 0 && m->nodes[fo].page >= 0 && !m->nodes[m->nodes[fo].page].visible) {
        if (key <= MENU_KEY_CIRCLE) mtrace(m, "KEY %s: its focus %s is on a closed page", names[key], m->r.e[m->nodes[fo].ent].label);
        fo = -1;
    }
    switch (key) {
    case MENU_KEY_UP:    done = handler(m, fo, "onFocusUp", "onUp", "onFocusUp"); break;
    case MENU_KEY_DOWN:  done = handler(m, fo, "onFocusDown", "onDown", "onFocusDown"); break;
    case MENU_KEY_LEFT:  done = handler(m, fo, "onFocusLeft", "onLeft", "onFocusLeft"); break;
    case MENU_KEY_RIGHT: done = handler(m, fo, "onFocusRight", "onRight", "onFocusRight"); break;
    case MENU_KEY_CROSS: done = handler(m, fo, "onPush", "onPush", NULL); break;
    // the focused object's own (script-set) onCancel first, else the page's
    case MENU_KEY_CIRCLE:
        done = handler(m, fo, "onCancel", "onCancel", NULL);
        if (!done) done = handler(m, m->active_page, "onCancel", "onCancel", NULL);
        break;
    case MENU_KEY_TRIANGLE: done = handler(m, m->active_page, "onContextMenu", "onContextMenu", NULL); break;
    case MENU_KEY_SQUARE: done = callback(m, m->controller, "onMenu", 0, NULL); break;
    default: break;
    }
    if (!done) mtrace(m, "KEY %s unhandled (the system's)", names[key]);
    if (m->v) vm_gc(m->v);
    change_pending(m);
    return done > 0;
}

int menu_dirty(const menu *m) { return m->dirty || m->ntw > 0 || m->nruns > 0; }

static int shows_node(const menu *m, int ni)
{
    const node *nd = &m->nodes[ni];
    if (!nd->visible) return 0;
    const rco_entry *e = &m->r.e[nd->ent];
    // (as collect_node: its own alpha only, its children looked at whatever it is -- fj#69)
    if (nd->col[3] > 0.0f && e->table == RCO_T_OBJECT && (e->type == 2 || e->type == 26)) {
        int ie = image_of((menu *)m, (node *)nd);
        if (ie >= 0 ? image_get((menu *)m, ie) != NULL : e->type == 2 && nd->size[0] > 0 && nd->size[1] > 0) return 1;
    }
    for (int c = e->first; c >= 0; c = m->r.e[c].next)
        if (m->by_ent[c] >= 0 && shows_node(m, m->by_ent[c])) return 1;
    return 0;
}

int menu_shows(const menu *m)
{
    if (!m->nodes || m->err[0]) return 0;
    for (int i = 0; i < m->nnodes; i++)
        if (m->nodes[i].table == RCO_T_OBJECT && m->nodes[i].type == 1 && shows_node(m, i)) return 1;
    return 0;
}

const char *menu_focus(const menu *m, int *type)
{
    if (type) *type = -1;
    if (!m->nodes || m->focus < 0) return NULL;
    if (type) *type = m->nodes[m->focus].type;
    return m->r.e[m->nodes[m->focus].ent].label;
}

int menu_page_open(const menu *m)
{
    for (int i = 0; i < m->nnodes; i++)
        if (m->nodes[i].table == RCO_T_OBJECT && m->nodes[i].type == 1 && m->nodes[i].visible) return 1;
    return 0;
}

void menu_playlist_end(menu *m, int playlist)
{
    if (m->err[0] || !m->v) return;
    vm_obj *a = vm_new_object(m->v, "PlayListEnd");
    vm_set(m->v, a, "playListNumber", vm_num((float)playlist));
    vm_value arg = vm_objv(a);
    callback(m, m->movieplayer, "onPlayListEnd", 1, &arg);
    if (m->v) vm_gc(m->v);
    change_pending(m);
}

void menu_chapter(menu *m, int chapter)
{
    if (m->err[0] || !m->v) return;
    vm_obj *a = vm_new_object(m->v, "Chapter");
    vm_set(m->v, a, "chapterNumber", vm_num((float)chapter));
    vm_value arg = vm_objv(a);
    callback(m, m->movieplayer, "onChapter", 1, &arg);
    if (m->v) vm_gc(m->v);
    change_pending(m);
}

// the event's one property is the scripts' only read of it (60 `.mark_name` in the library, no other
// field of a mark event); the class name is a guess (no script reads it)
void menu_mark(menu *m, const char *name)
{
    if (m->err[0] || !m->v) return;
    vm_obj *a = vm_new_object(m->v, "Mark");
    vm_set(m->v, a, "mark_name", vm_str(m->v, name));
    vm_value arg = vm_objv(a);
    callback(m, m->movieplayer, "onMark", 1, &arg);
    if (m->v) vm_gc(m->v);
    change_pending(m);
}
