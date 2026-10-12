// vsmx.c -- the disc menus' script VM (vsmx.h has the format, the semantics and the bounds).
#include "vsmx.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    OP_NOTHING = 0x00, OP_ASSIGN, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_POS, OP_NEG, OP_NOT,
    OP_PINC = 0x0a, OP_PDEC, OP_INC, OP_DEC, OP_EQ, OP_NE, OP_SEQ, OP_SNE, OP_LT, OP_LE, OP_GE, OP_GT,
    OP_INSTANCEOF = 0x16, OP_IN, OP_TYPEOF, OP_BAND, OP_BXOR, OP_BOR, OP_BNOT, OP_SHL, OP_SHR, OP_USHR,
    OP_COPY = 0x20, OP_SWAP, OP_END_STMT, OP_NULL, OP_EMPTYARRAY, OP_BOOL, OP_INT, OP_FLOAT, OP_STRING,
    OP_OBJECT = 0x29, OP_FUNCTION, OP_ARRAY, OP_THIS, OP_LOCAL, OP_VARIABLE, OP_PROPERTY, OP_METHOD,
    OP_SET_ATTR = 0x31, OP_UNSET, OP_OBJ_ADD_ATTR, OP_INDEX, OP_INDEX_KEEP, OP_INDEX_ASSIGN, OP_INDEX_DELETE,
    OP_ARRAY_ELEM = 0x38, OP_JUMP, OP_JUMP_TRUE, OP_JUMP_FALSE, OP_CALL_FUNC, OP_CALL_METHOD, OP_CALL_NEW,
    OP_RETURN = 0x3f, OP_TRY_IN = 0x41, OP_TRY_OUT, OP_CATCH_IN, OP_CATCH_OUT, OP_END = 0x45, OP_DEBUG_FILE,
    OP_DEBUG_LINE
};

// a try block's handler (try / catch: X-Men, measured 2026-10-02 -- below, OP_TRY_IN)
typedef struct {
    uint32_t  catch_pc;        // its CATCH_IN
    uint32_t  sp, fp;          // the operand stack and the call depth at the TRY_IN
} handler;
#define HANDLERS_MAX 32

typedef struct {
    uint32_t  ret_pc;
    uint32_t  base;            // the operand stack's base for this frame
    vm_value *locals;
    uint32_t  nlocals;
    vm_value  self;
    vm_value *args;            // the arguments passed (all of them): local slot 0 is `arguments`
    uint32_t  nargs_in;
    int       args_built;
    int       return_this;     // a constructor: the result is `this`
    int       stop;            // the frame vm_call / vm_run_main started: the loop returns here
} frame;

struct vm {
    const uint8_t *code;
    uint32_t  ninstr;
    vm_obj  **text, **prop, **name;
    uint32_t  ntext, nprop, nname;
    vm_obj   *globals;
    vm_value *stack;
    uint32_t  sp, stack_max;
    frame    *fr;
    uint32_t  fp, frames_max;
    vm_obj   *heap;
    uint32_t  nheap, heap_max;
    vm_obj  **roots;
    uint32_t  nroots, croots;
    vm_obj   *proto_array, *proto_string;   // the builtin methods (natives) of arrays / strings
    vm_obj   *k_length, *k_proto;           // the "length" and "prototype" names
    char      err[256];
    vm_trace_fn trace;
    void     *trace_ud;
    int       trace_calls;              // a debug aid: VSMX_TRACE_CALLS=1 traces every script call
    int       catchable;                // the error is a script's TypeError (a try catches it), not the VM's
    handler   h[HANDLERS_MAX];
    uint32_t  nh;
};

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static void verr(vm *v, const char *fmt, ...)
{
    if (v->err[0]) return;                   // the first reason stands
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(v->err, sizeof(v->err), fmt, ap);
    va_end(ap);
    v->catchable = 0;                        // the VM's own: a refusal, a bound, a malformed script
}

// a script's TypeError (a call of a non-function, a method of undefined, ...): a try catches it
static void vthrow(vm *v, const char *fmt, ...)
{
    if (v->err[0]) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(v->err, sizeof(v->err), fmt, ap);
    va_end(ap);
    v->catchable = 1;
}

int vm_error_caught(const vm *v)
{
    return v->err[0] && v->catchable && v->nh && v->h[v->nh - 1].fp <= v->fp;
}
int vm_error_catchable(const vm *v) { return v->err[0] && v->catchable; }
void vm_error_clear(vm *v) { v->err[0] = 0; v->catchable = 0; }

const char *vm_error(const vm *v) { return v->err; }
void vm_set_trace(vm *v, vm_trace_fn fn, void *ud) { v->trace = fn; v->trace_ud = ud; }
void vm_trace(vm *v, const char *fmt, ...)
{
    if (!v->trace) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    v->trace(v->trace_ud, buf);
}

// ---- the heap ------------------------------------------------------------------------------------
static vm_obj *alloc_obj(vm *v, uint8_t kind)
{
    if (v->nheap >= v->heap_max) { verr(v, "heap full (%u objects)", v->heap_max); return NULL; }
    vm_obj *o = (vm_obj *)calloc(1, sizeof(vm_obj));
    if (!o) { verr(v, "out of memory"); return NULL; }
    o->kind = kind;
    o->gc_next = v->heap; v->heap = o; v->nheap++;
    return o;
}

static void free_obj(vm_obj *o)
{
    free(o->s); free(o->props); free(o->el); free(o);
}

static vm_obj *new_str(vm *v, const char *s, uint32_t n)
{
    vm_obj *o = alloc_obj(v, O_STR);
    if (!o) return NULL;
    o->s = (char *)malloc(n + 1);
    if (!o->s) { verr(v, "out of memory"); return o; }
    memcpy(o->s, s, n); o->s[n] = 0; o->slen = n;
    return o;
}

vm_value vm_undef(void) { vm_value x; memset(&x, 0, sizeof(x)); x.t = V_UNDEF; return x; }
vm_value vm_null(void) { vm_value x = vm_undef(); x.t = V_NULL; return x; }
vm_value vm_bool(int b) { vm_value x = vm_undef(); x.t = V_BOOL; x.u.b = !!b; return x; }
vm_value vm_num(float n) { vm_value x = vm_undef(); x.t = V_NUM; x.u.n = n; return x; }
vm_value vm_objv(vm_obj *o)
{
    vm_value x = vm_undef();
    if (!o) return x;
    x.t = (o->kind == O_STR) ? V_STR : V_OBJ; x.u.o = o;
    return x;
}
vm_value vm_str(vm *v, const char *s) { return vm_objv(new_str(v, s, (uint32_t)strlen(s))); }

vm_obj *vm_new_object(vm *v, const char *cls) { vm_obj *o = alloc_obj(v, O_OBJECT); if (o) o->cls = cls; return o; }
vm_obj *vm_new_array(vm *v, uint32_t n)
{
    vm_obj *o = alloc_obj(v, O_ARRAY);
    if (!o) return NULL;
    o->proto = v->proto_array;
    if (n) {
        o->el = (vm_value *)calloc(n, sizeof(vm_value));
        if (!o->el) { verr(v, "out of memory"); return o; }
        o->nel = o->cel = n;
    }
    return o;
}
vm_obj *vm_new_native(vm *v, const char *name, vm_native fn, void *ud)
{
    vm_obj *o = alloc_obj(v, O_NATIVE);
    if (!o) return NULL;
    o->fn = fn; o->ud = ud; o->cls = name;
    return o;
}

struct vm;
static int key_eq(const vm_obj *a, const vm_obj *b)
{
    return a == b || (a->slen == b->slen && !memcmp(a->s, b->s, a->slen));
}

static vm_prop *find_own(vm_obj *o, const vm_obj *key)
{
    for (uint32_t i = 0; i < o->nprops; i++)
        if (key_eq(o->props[i].key, key)) return &o->props[i];
    return NULL;
}

static void set_prop(vm *v, vm_obj *o, vm_obj *key, vm_value val)
{
    vm_prop *p = find_own(o, key);
    if (p) { p->val = val; return; }
    if (o->nprops == o->cprops) {
        uint32_t nc = o->cprops ? 2 * o->cprops : 4;
        vm_prop *np = (vm_prop *)realloc(o->props, nc * sizeof(vm_prop));
        if (!np) { verr(v, "out of memory"); return; }
        o->props = np; o->cprops = nc;
    }
    o->props[o->nprops].key = key; o->props[o->nprops].val = val; o->nprops++;
}

static void del_prop(vm_obj *o, const vm_obj *key)
{
    for (uint32_t i = 0; i < o->nprops; i++)
        if (key_eq(o->props[i].key, key)) { o->props[i] = o->props[--o->nprops]; return; }
}

// an array index from a key value: a non-negative whole number, or a string of digits
static int as_index(vm_value k, uint32_t *idx)
{
    if (k.t == V_NUM) {
        if (k.u.n >= 0 && k.u.n == floorf(k.u.n) && k.u.n < 4294967296.0f) { *idx = (uint32_t)k.u.n; return 1; }
        return 0;
    }
    if (k.t == V_STR && k.u.o->slen && k.u.o->slen < 10) {
        uint32_t n = 0;
        for (uint32_t i = 0; i < k.u.o->slen; i++) {
            char c = k.u.o->s[i];
            if (c < '0' || c > '9') return 0;
            n = n * 10 + (uint32_t)(c - '0');
        }
        *idx = n;
        return 1;
    }
    return 0;
}

static void array_resize(vm *v, vm_obj *a, uint32_t n)
{
    if (n > a->cel) {
        uint32_t nc = a->cel ? a->cel : 4;
        while (nc < n) nc *= 2;
        vm_value *ne = (vm_value *)realloc(a->el, nc * sizeof(vm_value));
        if (!ne) { verr(v, "out of memory"); return; }
        a->el = ne; a->cel = nc;
    }
    for (uint32_t i = a->nel; i < n; i++) a->el[i] = vm_undef();
    a->nel = n;
}

void vm_array_push(vm *v, vm_obj *a, vm_value val)
{
    array_resize(v, a, a->nel + 1);
    if (!v->err[0]) a->el[a->nel - 1] = val;
}

// a key: a NUMBER index truncated toward zero, as the PSP's VSMX (every number a float; JPCSP casts
// an index to int): Final Fantasy, Godzilla et al. take `children[getNumButtons(g) / 2]`, 1.5 for
// three buttons -- JavaScript's undefined there stopped their menus
static vm_obj *key_of(vm *v, vm_value k)
{
    if (k.t == V_STR) return k.u.o;
    char buf[64];
    if (k.t == V_NUM && isfinite(k.u.n) && fabsf(k.u.n) < 2147483648.0f) snprintf(buf, sizeof(buf), "%d", (int)k.u.n);
    else vm_tostr(k, buf, sizeof(buf));
    return new_str(v, buf, (uint32_t)strlen(buf));
}


// a property's value: own, then the prototype chain; arrays' elements and length; strings' length
static vm_value get_prop(vm *v, vm_value ov, vm_obj *key)
{
    if (ov.t == V_STR) {
        if (key_eq(key, v->k_length)) return vm_num((float)ov.u.o->slen);
        vm_prop *p = v->proto_string ? find_own(v->proto_string, key) : NULL;
        return p ? p->val : vm_undef();
    }
    if (ov.t != V_OBJ) return vm_undef();
    vm_obj *o = ov.u.o;
    if (o->kind == O_ARRAY) {
        if (key_eq(key, v->k_length)) return vm_num((float)o->nel);
        vm_value kv = vm_objv(key);
        uint32_t idx;
        if (as_index(kv, &idx)) return idx < o->nel ? o->el[idx] : vm_undef();
    }
    if ((o->kind == O_FUNC) && key_eq(key, v->k_proto) && !find_own(o, key)) {
        // a script function's prototype, made on first use (`F.prototype.m = ...`)
        vm_obj *p = vm_new_object(v, "prototype");
        if (p) set_prop(v, o, key, vm_objv(p));
    }
    for (int depth = 0; o && depth < 64; depth++, o = o->proto) {
        vm_prop *p = find_own(o, key);
        if (p) return p->val;
    }
    return vm_undef();
}

static void put_prop(vm *v, vm_value ov, vm_obj *key, vm_value val)
{
    if (ov.t != V_OBJ) return;                   // a primitive's property: dropped (as JS)
    vm_obj *o = ov.u.o;
    if (o->kind == O_ARRAY) {
        if (key_eq(key, v->k_length)) { array_resize(v, o, (uint32_t)vm_toint(val)); return; }
        uint32_t idx;
        if (as_index(vm_objv(key), &idx)) {
            if (idx >= o->nel) array_resize(v, o, idx + 1);
            if (!v->err[0]) o->el[idx] = val;
            return;
        }
    }
    set_prop(v, o, key, val);
}

void vm_set(vm *v, vm_obj *o, const char *key, vm_value val)
{
    vm_obj *k = new_str(v, key, (uint32_t)strlen(key));
    if (k) put_prop(v, vm_objv(o), k, val);
}
vm_value vm_get(vm *v, vm_obj *o, const char *key)
{
    vm_obj k;
    memset(&k, 0, sizeof(k));
    k.kind = O_STR; k.s = (char *)key; k.slen = (uint32_t)strlen(key);
    return get_prop(v, vm_objv(o), &k);
}

// ---- conversions ---------------------------------------------------------------------------------
float vm_tonum(vm_value x)
{
    switch (x.t) {
    case V_NUM:  return x.u.n;
    case V_BOOL: return (float)x.u.b;
    case V_NULL: return 0.0f;
    case V_STR: {
        char *end;
        if (!x.u.o->slen) return 0.0f;
        double d = strtod(x.u.o->s, &end);
        while (*end == ' ') end++;
        return *end ? NAN : (float)d;
    }
    default:     return NAN;
    }
}

int vm_toint(vm_value x)
{
    float f = vm_tonum(x);
    if (!(f == f) || isinf(f)) return 0;
    double d = fmod(trunc((double)f), 4294967296.0);
    if (d < 0) d += 4294967296.0;
    return (int)(int32_t)(uint32_t)d;
}

int vm_tobool(vm_value x)
{
    switch (x.t) {
    case V_BOOL: return x.u.b;
    case V_NUM:  return x.u.n != 0.0f && x.u.n == x.u.n;
    case V_STR:  return x.u.o->slen != 0;
    case V_OBJ:  return x.u.o->kind != O_ARRAY || x.u.o->nel != 0;    // an empty array is false (vsmx.h)
    default:     return 0;
    }
}

int vm_is_func(vm_value x) { return x.t == V_OBJ && (x.u.o->kind == O_FUNC || x.u.o->kind == O_NATIVE); }

const char *vm_tostr(vm_value x, char *buf, size_t n)
{
    switch (x.t) {
    case V_UNDEF: snprintf(buf, n, "undefined"); break;
    case V_NULL:  snprintf(buf, n, "null"); break;
    case V_BOOL:  snprintf(buf, n, "%s", x.u.b ? "true" : "false"); break;
    case V_NUM:
        if (x.u.n != x.u.n) snprintf(buf, n, "NaN");
        else if (isinf(x.u.n)) snprintf(buf, n, x.u.n > 0 ? "Infinity" : "-Infinity");
        else if (x.u.n == floorf(x.u.n) && fabsf(x.u.n) < 1e9f) snprintf(buf, n, "%d", (int)x.u.n);
        else snprintf(buf, n, "%.7g", (double)x.u.n);
        break;
    case V_STR:   snprintf(buf, n, "%s", x.u.o->s); break;
    case V_OBJ:
        if (x.u.o->kind == O_ARRAY) snprintf(buf, n, "[array %u]", x.u.o->nel);
        else if (x.u.o->kind == O_FUNC) snprintf(buf, n, "[function @%u]", x.u.o->pc);
        else if (x.u.o->kind == O_NATIVE) snprintf(buf, n, "[native %s]", x.u.o->cls ? x.u.o->cls : "?");
        else snprintf(buf, n, "[object %s]", x.u.o->cls ? x.u.o->cls : "Object");
        break;
    default:      snprintf(buf, n, "[ref]"); break;
    }
    return buf;
}

// ---- the operand stack ---------------------------------------------------------------------------
static int push(vm *v, vm_value x)
{
    if (v->sp >= v->stack_max) { verr(v, "operand stack full (%u)", v->stack_max); return -1; }
    v->stack[v->sp++] = x;
    return 0;
}

static vm_value pop_raw(vm *v)
{
    frame *f = v->fp ? &v->fr[v->fp - 1] : NULL;
    if (v->sp == (f ? f->base : 0)) { verr(v, "operand stack underflow"); return vm_undef(); }
    return v->stack[--v->sp];
}

// a stack element's value (a reference read; a method's function)
static vm_value deref(vm *v, vm_value x)
{
    if (x.t == V_REF) {
        switch (x.rk) {
        case R_GLOBAL: return get_prop(v, vm_objv(v->globals), x.k.key);
        case R_PROP:   return get_prop(v, x.u.o ? vm_objv(x.u.o) : vm_undef(), x.k.key);
        case R_LOCAL: {
            frame *f = &v->fr[v->fp - 1];
            if (x.k.local == 0 && !f->args_built && f->nlocals) {
                vm_obj *a = vm_new_array(v, 0);
                for (uint32_t i = 0; a && i < f->nargs_in; i++) vm_array_push(v, a, f->args[i]);
                if (a) f->locals[0] = vm_objv(a);
                f->args_built = 1;
            }
            return ((uint32_t)x.k.local < f->nlocals) ? f->locals[x.k.local] : vm_undef();
        }
        }
    }
    if (x.t == V_METHOD) return get_prop(v, x.u.o ? vm_objv(x.u.o) : vm_undef(), x.k.key);
    return x;
}

static vm_value pop_val(vm *v) { return deref(v, pop_raw(v)); }

static void assign(vm *v, vm_value r, vm_value val)
{
    if (r.t != V_REF) { verr(v, "assignment to a non-reference"); return; }
    switch (r.rk) {
    case R_GLOBAL: put_prop(v, vm_objv(v->globals), r.k.key, val); break;
    case R_PROP:   if (r.u.o) put_prop(v, vm_objv(r.u.o), r.k.key, val); break;
    case R_LOCAL: {
        frame *f = &v->fr[v->fp - 1];
        if (r.k.local == 0) f->args_built = 1;            // (`arguments` assigned: kept)
        if ((uint32_t)r.k.local < f->nlocals) f->locals[r.k.local] = val;
        else verr(v, "local slot %d out of range (%u)", r.k.local, f->nlocals);
        break;
    }
    }
}

// ---- equality (JS's loose and strict) -------------------------------------------------------------
static int strict_eq(vm_value a, vm_value b)
{
    if (a.t != b.t) return 0;
    switch (a.t) {
    case V_UNDEF: case V_NULL: return 1;
    case V_BOOL: return a.u.b == b.u.b;
    case V_NUM:  return a.u.n == b.u.n;
    case V_STR:  return key_eq(a.u.o, b.u.o);
    case V_OBJ:  return a.u.o == b.u.o;
    default:     return 0;
    }
}

static int is_nothing(vm_value x) { return x.t == V_OBJ && x.u.o->kind == O_ARRAY && x.u.o->nothing && !x.u.o->nel; }

static int loose_eq(vm_value a, vm_value b)
{
    // THE EMPTY CONSTANT (0x24, vsmx.h) equals an empty array: X-Men's `if (btn != []) btn.animScale(..)`
    // holds the constant in btn when no button is meant (as JavaScript it calls a method of an empty
    // array and throws). An array LITERAL (0x2B), even empty, is compared by identity: Batman & Robin's
    // onMenu acts only `if (fArray != [])` with fArray its empty pending-action array (docs/p9.md M4),
    // and a non-empty one is not equal to [] (Austin Powers 2's `fArray != []` holds for [8, show_ls] or
    // its language page never shows). Strict equality stays identity.
    if (a.t == V_OBJ && b.t == V_OBJ && a.u.o->kind == O_ARRAY && b.u.o->kind == O_ARRAY && !a.u.o->nel && !b.u.o->nel
        && (a.u.o->nothing || b.u.o->nothing)) return 1;
    if (a.t == b.t) return strict_eq(a, b);
    if ((a.t == V_UNDEF || a.t == V_NULL) && (b.t == V_UNDEF || b.t == V_NULL)) return 1;
    // ... and [] is "nothing" beside undefined / null: Now That's Music guards `if (localData.currentPage
    // != []) localData.currentPage.close()` with currentPage never set (as JavaScript the guard passes
    // and the call throws; its menu works on the PSP). A MODEL from that idiom, not measured alone.
    if (((a.t == V_UNDEF || a.t == V_NULL) && is_nothing(b)) || ((b.t == V_UNDEF || b.t == V_NULL) && is_nothing(a))) return 1;
    if (a.t == V_UNDEF || a.t == V_NULL || b.t == V_UNDEF || b.t == V_NULL) return 0;
    // an object against a string: its string form, as JavaScript (Final Fantasy's getNumButtons drops a
    // group's last child when `children[n - 1] == '[object Plane]'`)
    if ((a.t == V_OBJ && b.t == V_STR) || (a.t == V_STR && b.t == V_OBJ)) {
        char t[128];
        vm_value o = a.t == V_OBJ ? a : b, st = a.t == V_STR ? a : b;
        vm_tostr(o, t, sizeof(t));
        return !strcmp(t, st.u.o->s);
    }
    if (a.t == V_OBJ || b.t == V_OBJ) return 0;            // (no valueOf on the scripts' objects)
    return vm_tonum(a) == vm_tonum(b);
}

static int is_textual(vm_value x) { return x.t == V_STR; }

// ---- frames and calls ------------------------------------------------------------------------------
static int push_frame(vm *v, vm_obj *fn, vm_value self, int argc, const vm_value *argv, int return_this, int stop)
{
    if (v->fp >= v->frames_max) { verr(v, "call depth full (%u)", v->frames_max); return -1; }
    frame *f = &v->fr[v->fp];
    f->nlocals = fn->nargs + fn->nlocals + 1;
    f->locals = (vm_value *)calloc(f->nlocals, sizeof(vm_value));
    if (!f->locals) { verr(v, "out of memory"); return -1; }
    for (uint32_t i = 0; i < f->nlocals; i++) f->locals[i] = vm_undef();
    for (uint32_t i = 1; i <= fn->nargs && (int)i <= argc; i++) f->locals[i] = argv[i - 1];
    // LOCAL SLOT 0 IS `arguments` (the parameters are 1..nargs): 102 library reads of its .length, 97
    // of an element -- Hackers' addCardPL(...) takes its playlists variadically (no parameter); left
    // undefined (JPCSP's), its info cards never played and Play Movie did nothing (docs/p9.md M4).
    // Built as an array at its first read (the heap is bounded: not one per call)
    f->args = NULL; f->nargs_in = 0; f->args_built = 0;
    if (argc > 0) {
        f->args = (vm_value *)malloc((size_t)argc * sizeof(vm_value));
        if (!f->args) { free(f->locals); f->locals = NULL; verr(v, "out of memory"); return -1; }
        memcpy(f->args, argv, (size_t)argc * sizeof(vm_value));
        f->nargs_in = (uint32_t)argc;
    }
    f->base = v->sp;
    f->self = self;
    f->return_this = return_this;
    f->stop = stop;
    v->fp++;
    return 0;
}

static void pop_frame(vm *v)
{
    frame *f = &v->fr[--v->fp];
    v->sp = f->base;
    free(f->locals);
    f->locals = NULL;
    free(f->args);
    f->args = NULL;
    while (v->nh && v->h[v->nh - 1].fp > v->fp) v->nh--;     // its try blocks (a return inside one)
}

static int interpret(vm *v, uint32_t pc);

// call a function value from the loop: a script function continues in the loop at its first
// instruction (`*pc` updated); a native runs now and its result is pushed
static vm_value nat_array(vm *v, vm_value self, int argc, const vm_value *argv, void *ud);
static vm_value nat_object(vm *v, vm_value self, int argc, const vm_value *argv, void *ud);

static int call_value(vm *v, vm_value fnv, vm_value self, int argc, const vm_value *argv, int is_new, uint32_t *pc)
{
    if (fnv.t != V_OBJ || (fnv.u.o->kind != O_FUNC && fnv.u.o->kind != O_NATIVE)) {
        char b[64];
        vthrow(v, "call of a non-function (%s)", vm_tostr(fnv, b, sizeof(b)));
        return -1;
    }
    vm_obj *fn = fnv.u.o;
    if (fn->kind == O_NATIVE) {
        vm_value r = fn->fn(v, self, argc, argv, fn->ud);
        if (v->err[0]) return -1;
        return push(v, is_new && r.t == V_UNDEF ? self : r);
    }
    if (fn->pc >= v->ninstr) { verr(v, "function start %u past the code", fn->pc); return -1; }
    if (v->trace_calls) vm_trace(v, "SCALL %u from %u (%d args)", fn->pc, *pc, argc);
    if (push_frame(v, fn, self, argc, argv, is_new, 0)) return -1;
    v->fr[v->fp - 1].ret_pc = *pc;
    *pc = fn->pc;
    return 0;
}

int vm_call(vm *v, vm_value fnv, vm_value self, int argc, const vm_value *argv, vm_value *ret)
{
    *ret = vm_undef();
    if (v->err[0]) return -1;
    if (fnv.t != V_OBJ || (fnv.u.o->kind != O_FUNC && fnv.u.o->kind != O_NATIVE)) {
        verr(v, "callback is not a function");
        return -1;
    }
    vm_obj *fn = fnv.u.o;
    if (fn->kind == O_NATIVE) {
        *ret = fn->fn(v, self, argc, argv, fn->ud);
        return v->err[0] ? -1 : 0;
    }
    uint32_t sp0 = v->sp, fp0 = v->fp;
    if (push_frame(v, fn, self, argc, argv, 0, 1)) return -1;
    v->fr[v->fp - 1].ret_pc = 0xFFFFFFFFu;
    int rc = interpret(v, fn->pc);
    if (rc == 0 && v->sp > sp0) *ret = v->stack[--v->sp];
    // (an error unwinds every frame this call made)
    while (v->fp > fp0) pop_frame(v);
    v->sp = sp0;
    return rc;
}

// ---- the loop ---------------------------------------------------------------------------------------
static float f32(uint32_t bits) { float f; memcpy(&f, &bits, 4); return f; }

static int interpret(vm *v, uint32_t pc)
{
    uint32_t fp_entry = v->fp;          // returns when the frame it started in returns
    vm_value a, b, c, r;
    char buf[64];
    for (;;) {
        if (v->err[0]) {
            // a script error inside a try of this run's frames: unwind to its catch, the error's text
            // as the exception (`catch (err)` stores it: VARIABLE err, SWAP, ASSIGN)
            if (!v->catchable || !v->nh || v->h[v->nh - 1].fp < fp_entry) return -1;
            handler hd = v->h[--v->nh];
            while (v->fp > hd.fp) pop_frame(v);
            v->sp = hd.sp;
            char msg[sizeof(v->err)];
            memcpy(msg, v->err, sizeof(msg));
            v->err[0] = 0; v->catchable = 0;
            vm_trace(v, "CAUGHT %s", msg);
            push(v, vm_str(v, msg));
            pc = hd.catch_pc + 1;
            continue;
        }
        if (pc >= v->ninstr) { verr(v, "pc %u past the code", pc); return -1; }
        uint32_t id = le32(v->code + 8 * pc), val = le32(v->code + 8 * pc + 4);
        uint32_t op = id & 0xFF;
        uint32_t at = pc++;
        switch (op) {
        case OP_NOTHING: case OP_DEBUG_FILE: case OP_DEBUG_LINE: break;
        case OP_ASSIGN:
            a = pop_val(v); r = pop_raw(v);
            assign(v, r, a); push(v, a);
            break;
        case OP_ADD:
            b = pop_val(v); a = pop_val(v);
            if (is_textual(a) || is_textual(b)) {
                char ba[256], bb[256];
                const char *sa = vm_tostr(a, ba, sizeof(ba)), *sb = vm_tostr(b, bb, sizeof(bb));
                size_t la = (a.t == V_STR) ? a.u.o->slen : strlen(sa), lb = (b.t == V_STR) ? b.u.o->slen : strlen(sb);
                if (a.t == V_STR) sa = a.u.o->s;
                if (b.t == V_STR) sb = b.u.o->s;
                char *t = (char *)malloc(la + lb + 1);
                if (!t) { verr(v, "out of memory"); break; }
                memcpy(t, sa, la); memcpy(t + la, sb, lb); t[la + lb] = 0;
                vm_obj *s = new_str(v, t, (uint32_t)(la + lb));
                free(t);
                push(v, vm_objv(s));
            } else push(v, vm_num(vm_tonum(a) + vm_tonum(b)));
            break;
        case OP_SUB: b = pop_val(v); a = pop_val(v); push(v, vm_num(vm_tonum(a) - vm_tonum(b))); break;
        case OP_MUL: b = pop_val(v); a = pop_val(v); push(v, vm_num(vm_tonum(a) * vm_tonum(b))); break;
        case OP_DIV: b = pop_val(v); a = pop_val(v); push(v, vm_num(vm_tonum(a) / vm_tonum(b))); break;
        case OP_MOD: b = pop_val(v); a = pop_val(v); push(v, vm_num(fmodf(vm_tonum(a), vm_tonum(b)))); break;
        case OP_POS: a = pop_val(v); push(v, vm_num(vm_tonum(a))); break;
        case OP_NEG: a = pop_val(v); push(v, vm_num(-vm_tonum(a))); break;
        case OP_NOT: a = pop_val(v); push(v, vm_bool(!vm_tobool(a))); break;
        case OP_PINC: case OP_PDEC: case OP_INC: case OP_DEC: {
            r = pop_raw(v);
            float old = vm_tonum(deref(v, r));
            float nw = (op == OP_PINC || op == OP_INC) ? old + 1.0f : old - 1.0f;
            assign(v, r, vm_num(nw));
            push(v, vm_num((op == OP_PINC || op == OP_PDEC) ? nw : old));
            break;
        }
        case OP_EQ:  b = pop_val(v); a = pop_val(v); push(v, vm_bool(loose_eq(a, b))); break;
        case OP_NE:  b = pop_val(v); a = pop_val(v); push(v, vm_bool(!loose_eq(a, b))); break;
        case OP_SEQ: b = pop_val(v); a = pop_val(v); push(v, vm_bool(strict_eq(a, b))); break;
        case OP_SNE: b = pop_val(v); a = pop_val(v); push(v, vm_bool(!strict_eq(a, b))); break;
        case OP_LT: case OP_LE: case OP_GE: case OP_GT: {
            b = pop_val(v); a = pop_val(v);
            int res;
            if (a.t == V_STR && b.t == V_STR) {
                int cmp = strcmp(a.u.o->s, b.u.o->s);
                res = op == OP_LT ? cmp < 0 : op == OP_LE ? cmp <= 0 : op == OP_GE ? cmp >= 0 : cmp > 0;
            } else {
                float fa = vm_tonum(a), fb = vm_tonum(b);
                res = op == OP_LT ? fa < fb : op == OP_LE ? fa <= fb : op == OP_GE ? fa >= fb : fa > fb;
            }
            push(v, vm_bool(res));
            break;
        }
        case OP_TYPEOF: {
            a = pop_val(v);
            const char *t = a.t == V_UNDEF ? "undefined" : a.t == V_BOOL ? "boolean" : a.t == V_NUM ? "number" :
                            a.t == V_STR ? "string" : vm_is_func(a) ? "function" : "object";
            push(v, vm_str(v, t));
            break;
        }
        case OP_BAND: b = pop_val(v); a = pop_val(v); push(v, vm_num((float)(vm_toint(a) & vm_toint(b)))); break;
        case OP_BXOR: b = pop_val(v); a = pop_val(v); push(v, vm_num((float)(vm_toint(a) ^ vm_toint(b)))); break;
        case OP_BOR:  b = pop_val(v); a = pop_val(v); push(v, vm_num((float)(vm_toint(a) | vm_toint(b)))); break;
        case OP_BNOT: a = pop_val(v); push(v, vm_num((float)(~vm_toint(a)))); break;
        case OP_SHL:  b = pop_val(v); a = pop_val(v); push(v, vm_num((float)(int32_t)((uint32_t)vm_toint(a) << (vm_toint(b) & 31)))); break;
        case OP_SHR:  b = pop_val(v); a = pop_val(v); push(v, vm_num((float)(vm_toint(a) >> (vm_toint(b) & 31)))); break;
        case OP_USHR: b = pop_val(v); a = pop_val(v); push(v, vm_num((float)((uint32_t)vm_toint(a) >> (vm_toint(b) & 31)))); break;
        case OP_COPY:
            a = pop_raw(v); push(v, a); push(v, a);
            break;
        case OP_SWAP:
            b = pop_raw(v); a = pop_raw(v); push(v, b); push(v, a);
            break;
        case OP_END_STMT: {
            frame *f = v->fp ? &v->fr[v->fp - 1] : NULL;
            if (v->sp > (f ? f->base : 0)) v->sp--;
            break;
        }
        case OP_NULL:       push(v, vm_null()); break;
        case OP_EMPTYARRAY: { vm_obj *e = vm_new_array(v, 0); if (e) e->nothing = 1; push(v, vm_objv(e)); break; }
        case OP_BOOL:       push(v, vm_bool(val != 0)); break;
        case OP_INT:        push(v, vm_num((float)(int32_t)val)); break;
        case OP_FLOAT:      push(v, vm_num(f32(val))); break;
        case OP_STRING:
            if (val >= v->ntext) { verr(v, "string %u past the table (%u) at %u", val, v->ntext, at); break; }
            push(v, vm_objv(v->text[val]));
            break;
        case OP_OBJECT:     push(v, vm_objv(vm_new_object(v, NULL))); break;
        case OP_FUNCTION: {
            vm_obj *f = alloc_obj(v, O_FUNC);
            if (!f) break;
            f->nargs = (id >> 8) & 0xFF; f->nlocals = (id >> 24) & 0xFF; f->pc = val;
            push(v, vm_objv(f));
            break;
        }
        case OP_ARRAY:      push(v, vm_objv(vm_new_array(v, 0))); break;
        case OP_THIS:       push(v, v->fp ? v->fr[v->fp - 1].self : vm_objv(v->globals)); break;
        case OP_LOCAL:
            if (!v->fp) { verr(v, "a local outside a function at %u", at); break; }
            r = vm_undef(); r.t = V_REF; r.rk = R_LOCAL; r.k.local = (int)val;
            push(v, r);
            break;
        case OP_VARIABLE:
            if (val >= v->nname) { verr(v, "name %u past the table (%u) at %u", val, v->nname, at); break; }
            r = vm_undef(); r.t = V_REF; r.rk = R_GLOBAL; r.k.key = v->name[val];
            push(v, r);
            break;
        case OP_PROPERTY:
            if (val >= v->nprop) { verr(v, "property %u past the table (%u) at %u", val, v->nprop, at); break; }
            a = pop_val(v);
            if (a.t == V_OBJ) { r = vm_undef(); r.t = V_REF; r.rk = R_PROP; r.u.o = a.u.o; r.k.key = v->prop[val]; push(v, r); }
            else push(v, get_prop(v, a, v->prop[val]));
            break;
        case OP_METHOD:
            if (val >= v->nprop) { verr(v, "property %u past the table (%u) at %u", val, v->nprop, at); break; }
            a = pop_val(v);
            r = vm_undef(); r.t = V_METHOD; r.u.o = (a.t == V_OBJ || a.t == V_STR) ? a.u.o : NULL; r.k.key = v->prop[val];
            if (!r.u.o) { vthrow(v, "method .%s of %s at %u", v->prop[val]->s, vm_tostr(a, buf, sizeof(buf)), at); break; }
            push(v, r);
            break;
        case OP_SET_ATTR:
            if (val >= v->nprop) { verr(v, "property %u past the table (%u) at %u", val, v->nprop, at); break; }
            a = pop_val(v); b = pop_val(v);
            put_prop(v, b, v->prop[val], a);
            push(v, a);             // (an assignment is an expression: vsmx.h)
            break;
        case OP_UNSET:
            if (val >= v->nprop) { verr(v, "property %u past the table (%u) at %u", val, v->nprop, at); break; }
            b = pop_val(v);
            if (b.t == V_OBJ) del_prop(b.u.o, v->prop[val]);
            break;
        case OP_OBJ_ADD_ATTR:
            if (val >= v->nprop) { verr(v, "property %u past the table (%u) at %u", val, v->nprop, at); break; }
            a = pop_val(v);
            if (v->sp == 0) { verr(v, "operand stack underflow"); break; }
            put_prop(v, deref(v, v->stack[v->sp - 1]), v->prop[val], a);
            break;
        case OP_INDEX:
            b = pop_val(v); a = pop_val(v);
            if (a.t == V_OBJ) { vm_obj *k = key_of(v, b); r = vm_undef(); r.t = V_REF; r.rk = R_PROP; r.u.o = a.u.o; r.k.key = k; push(v, r); }
            else push(v, get_prop(v, a, key_of(v, b)));
            break;
        case OP_INDEX_KEEP:
            b = pop_val(v);
            if (v->sp == 0) { verr(v, "operand stack underflow"); break; }
            a = deref(v, v->stack[v->sp - 1]);
            push(v, get_prop(v, a, key_of(v, b)));
            break;
        case OP_INDEX_ASSIGN:
            a = pop_val(v); b = pop_val(v); c = pop_val(v);
            put_prop(v, c, key_of(v, b), a);
            break;
        case OP_ARRAY_ELEM:
            a = pop_val(v); b = pop_val(v);
            if (b.t != V_OBJ || b.u.o->kind != O_ARRAY) { verr(v, "array element into a non-array at %u", at); break; }
            vm_array_push(v, b.u.o, a); push(v, b);
            break;
        case OP_JUMP:       pc = val; break;
        case OP_JUMP_TRUE:  a = pop_val(v); if (vm_tobool(a)) pc = val; break;
        case OP_JUMP_FALSE: a = pop_val(v); if (!vm_tobool(a)) pc = val; break;
        case OP_CALL_FUNC: case OP_CALL_METHOD: case OP_CALL_NEW: {
            int argc = (int)val;
            vm_value argv[64];
            if (argc > 64) { verr(v, "a call with %d arguments at %u", argc, at); break; }
            for (int i = argc - 1; i >= 0; i--) argv[i] = pop_val(v);
            r = pop_raw(v);
            if (v->err[0]) break;
            if (op == OP_CALL_FUNC) {
                a = deref(v, r);
                if (call_value(v, a, vm_objv(v->globals), argc, argv, 0, &pc)) {
                    if (!strstr(v->err, " at ")) { size_t l = strlen(v->err); snprintf(v->err + l, sizeof(v->err) - l, " at %u", at); }
                }
            } else if (op == OP_CALL_METHOD) {
                vm_value self;
                if (r.t == V_METHOD) {
                    self = vm_objv(r.u.o);
                    a = get_prop(v, self, r.k.key);
                    // Function.prototype.call / .apply (P9 M4b: Astro Boy's carousel -- its timer calls
                    // `f.call(this, ...)` to open the page chosen; without it the menu stayed on its hold
                    // page, every key unhandled): `this` the first argument (the globals for undefined /
                    // null), then the rest (call) or an array's elements (apply)
                    if (!vm_is_func(a) && vm_is_func(self) &&
                        ((r.k.key->slen == 4 && !memcmp(r.k.key->s, "call", 4)) ||
                         (r.k.key->slen == 5 && !memcmp(r.k.key->s, "apply", 5)))) {
                        vm_value th = argc > 0 ? argv[0] : vm_undef();
                        if (th.t == V_UNDEF || th.t == V_NULL) th = vm_objv(v->globals);
                        vm_value av[64];
                        int ac = 0;
                        if (r.k.key->slen == 4) {
                            for (int i = 1; i < argc; i++) av[ac++] = argv[i];
                        } else if (argc > 1 && argv[1].t == V_OBJ && argv[1].u.o->kind == O_ARRAY) {
                            vm_obj *ar = argv[1].u.o;
                            if (ar->nel > 64) { verr(v, "apply with %u arguments at %u", ar->nel, at); break; }
                            for (uint32_t i = 0; i < ar->nel; i++) av[ac++] = ar->el[i];
                        }
                        call_value(v, self, th, ac, av, 0, &pc);
                        break;
                    }
                    if (!vm_is_func(a)) {
                        vthrow(v, "undefined method .%s on %s at %u", r.k.key->s, vm_tostr(self, buf, sizeof(buf)), at);
                        break;
                    }
                } else {
                    a = deref(v, r);
                    self = pop_val(v);          // (INDEX_KEEP left the object under the function)
                }
                call_value(v, a, self, argc, argv, 0, &pc);
            } else {
                a = deref(v, r);
                if (a.t == V_OBJ && a.u.o->kind == O_NATIVE && (a.u.o->fn == nat_array || a.u.o->fn == nat_object)) {
                    push(v, a.u.o->fn(v, vm_undef(), argc, argv, NULL));
                } else if (a.t == V_OBJ && a.u.o->kind == O_FUNC) {
                    vm_obj *o = vm_new_object(v, NULL);
                    vm_value pr = get_prop(v, a, v->k_proto);
                    if (o && pr.t == V_OBJ) o->proto = pr.u.o;
                    call_value(v, a, vm_objv(o), argc, argv, 1, &pc);
                } else if (vm_is_func(a)) {
                    call_value(v, a, vm_objv(vm_new_object(v, a.u.o->cls)), argc, argv, 1, &pc);
                } else {
                    vthrow(v, "new of a non-constructor (%s) at %u", vm_tostr(a, buf, sizeof(buf)), at);
                }
            }
            break;
        }
        case OP_RETURN: {
            frame *f = v->fp ? &v->fr[v->fp - 1] : NULL;
            if (!f) return 0;                         // a return at the top level ends the run
            a = (v->sp > f->base) ? pop_val(v) : vm_undef();
            if (f->return_this) a = f->self;
            uint32_t ret_pc = f->ret_pc;
            int stop = f->stop;
            pop_frame(v);
            push(v, a);
            if (stop || v->fp < fp_entry) return v->err[0] ? -1 : 0;
            pc = ret_pc;
            break;
        }
        // try / catch (JPCSP: VID_TRY_BLOCK_IN .. VID_CATCH_FINALLY_BLOCK_OUT, unimplemented there;
        // measured on X-Men's MMAnim): TRY_IN's value is its CATCH_IN; TRY_OUT ends the guarded code,
        // which then falls into CATCH_IN, whose value is past the catch block (2754 there); an
        // exception enters the catch just after CATCH_IN with its value pushed; CATCH_OUT ends it
        case OP_TRY_IN:
            if (v->nh == HANDLERS_MAX) { verr(v, "try blocks nested past %d at %u", HANDLERS_MAX, at); break; }
            if (val >= v->ninstr) { verr(v, "a catch at %u past the code at %u", val, at); break; }
            v->h[v->nh].catch_pc = val; v->h[v->nh].sp = v->sp; v->h[v->nh].fp = v->fp; v->nh++;
            break;
        case OP_TRY_OUT:
            if (v->nh && v->h[v->nh - 1].fp == v->fp) v->nh--;
            break;
        case OP_CATCH_IN:
            pc = val;                       // reached in order: the try ended without an exception
            break;
        case OP_CATCH_OUT:
            break;
        case OP_END:
            return 0;
        default:
            verr(v, "opcode 0x%02x at %u is refused (unmeasured)", op, at);
            return -1;
        }
    }
}

// ---- the script's tables --------------------------------------------------------------------------
static int utf16_table(vm *v, const uint8_t *base, uint32_t len, uint32_t count, vm_obj ***out, uint32_t *n)
{
    *out = (vm_obj **)calloc(count ? count : 1, sizeof(vm_obj *));
    if (!*out) return -1;
    uint32_t o = 0, i = 0;
    while (i < count && o + 1 < len) {
        char tmp[1024];
        uint32_t tl = 0;
        while (o + 1 < len) {
            uint32_t ch = (uint32_t)base[o] | (uint32_t)base[o + 1] << 8;
            o += 2;
            if (!ch) break;
            // UTF-16 -> UTF-8 (surrogates kept as two code points: the scripts' strings are BMP)
            if (tl + 4 >= sizeof(tmp)) continue;
            if (ch < 0x80) tmp[tl++] = (char)ch;
            else if (ch < 0x800) { tmp[tl++] = (char)(0xC0 | ch >> 6); tmp[tl++] = (char)(0x80 | (ch & 0x3F)); }
            else { tmp[tl++] = (char)(0xE0 | ch >> 12); tmp[tl++] = (char)(0x80 | ((ch >> 6) & 0x3F)); tmp[tl++] = (char)(0x80 | (ch & 0x3F)); }
        }
        (*out)[i] = new_str(v, tmp, tl);
        if (!(*out)[i]) return -1;
        i++;
    }
    *n = i;
    return 0;
}

static int latin1_table(vm *v, const uint8_t *base, uint32_t len, uint32_t count, vm_obj ***out, uint32_t *n)
{
    *out = (vm_obj **)calloc(count ? count : 1, sizeof(vm_obj *));
    if (!*out) return -1;
    uint32_t o = 0, i = 0;
    while (i < count && o < len) {
        uint32_t s = o;
        while (o < len && base[o]) o++;
        (*out)[i] = new_str(v, (const char *)base + s, o - s);
        if (!(*out)[i]) return -1;
        o++; i++;
    }
    *n = i;
    return 0;
}

// ---- builtins: arrays and strings (the methods the library's scripts call) -------------------------
static vm_value nat_push(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)ud;
    if (self.t != V_OBJ || self.u.o->kind != O_ARRAY) return vm_undef();
    for (int i = 0; i < argc; i++) vm_array_push(v, self.u.o, argv[i]);
    return vm_num((float)self.u.o->nel);
}
static vm_value nat_pop(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)v; (void)argc; (void)argv; (void)ud;
    if (self.t != V_OBJ || self.u.o->kind != O_ARRAY || !self.u.o->nel) return vm_undef();
    return self.u.o->el[--self.u.o->nel];
}
static vm_value nat_shift(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)v; (void)argc; (void)argv; (void)ud;
    if (self.t != V_OBJ || self.u.o->kind != O_ARRAY || !self.u.o->nel) return vm_undef();
    vm_obj *a = self.u.o;
    vm_value x = a->el[0];
    memmove(a->el, a->el + 1, (a->nel - 1) * sizeof(vm_value));
    a->nel--;
    return x;
}
static vm_value nat_join(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)ud;
    if (self.t != V_OBJ || self.u.o->kind != O_ARRAY) return vm_str(v, "");
    char sep[16] = ",", out[2048] = "", b[256];
    if (argc > 0) vm_tostr(argv[0], sep, sizeof(sep));
    size_t l = 0;
    for (uint32_t i = 0; i < self.u.o->nel; i++) {
        const char *s = (self.u.o->el[i].t == V_UNDEF || self.u.o->el[i].t == V_NULL) ? "" : vm_tostr(self.u.o->el[i], b, sizeof(b));
        l += (size_t)snprintf(out + l, sizeof(out) - l, "%s%s", i ? sep : "", s);
        if (l >= sizeof(out)) break;
    }
    return vm_str(v, out);
}
// Array(...) and Object() build as `new` does, called with or without it (JavaScript's rule;
// Austin Powers 2 passes Array(1, 1, 1, 1) as colours: a string there leaves its menus at NaN)
static vm_value nat_array(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)self; (void)ud;
    vm_obj *arr;
    if (argc == 1 && argv[0].t == V_NUM) arr = vm_new_array(v, (uint32_t)vm_toint(argv[0]));
    else { arr = vm_new_array(v, 0); for (int i = 0; arr && i < argc; i++) vm_array_push(v, arr, argv[i]); }
    return arr ? vm_objv(arr) : vm_undef();
}
static vm_value nat_object(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)self; (void)argc; (void)argv; (void)ud;
    vm_obj *o = vm_new_object(v, NULL);
    return o ? vm_objv(o) : vm_undef();
}

static vm_value nat_tostring(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)argc; (void)argv; (void)ud;
    char b[256];
    return vm_str(v, vm_tostr(self, b, sizeof(b)));
}
static vm_value nat_charat(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)ud;
    if (self.t != V_STR || argc < 1) return vm_str(v, "");
    int i = vm_toint(argv[0]);
    if (i < 0 || (uint32_t)i >= self.u.o->slen) return vm_str(v, "");
    char t[2] = { self.u.o->s[i], 0 };
    return vm_str(v, t);
}
static vm_value nat_substring(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)ud;
    if (self.t != V_STR) return vm_str(v, "");
    int n = (int)self.u.o->slen;
    int s = argc > 0 ? vm_toint(argv[0]) : 0, e = argc > 1 ? vm_toint(argv[1]) : n;
    if (s < 0) s = 0;
    if (e > n) e = n;
    if (s > e) { int t = s; s = e; e = t; }
    return vm_objv(new_str(v, self.u.o->s + s, (uint32_t)(e - s)));
}
// slice (JavaScript's: negative counts from the end; Bad Boys II's `this.name.slice(7)`)
static vm_value nat_slice(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)ud;
    if (self.t != V_STR) return vm_str(v, "");
    int n = (int)self.u.o->slen;
    int s = argc > 0 ? vm_toint(argv[0]) : 0, e = argc > 1 && argv[1].t != V_UNDEF ? vm_toint(argv[1]) : n;
    if (s < 0) s += n;
    if (e < 0) e += n;
    if (s < 0) s = 0;
    if (e > n) e = n;
    if (s >= e) return vm_str(v, "");
    return vm_objv(new_str(v, self.u.o->s + s, (uint32_t)(e - s)));
}
// toLowerCase / toUpperCase (X-Men 2's `g_CurrSub.toString().toLowerCase()`), ASCII
static vm_value str_case(vm *v, vm_value self, int up)
{
    if (self.t != V_STR) return vm_str(v, "");
    vm_obj *o = new_str(v, self.u.o->s, self.u.o->slen);
    if (!o) return vm_undef();
    for (uint32_t i = 0; i < o->slen; i++) {
        char c = o->s[i];
        if (up && c >= 'a' && c <= 'z') o->s[i] = (char)(c - 32);
        if (!up && c >= 'A' && c <= 'Z') o->s[i] = (char)(c + 32);
    }
    return vm_objv(o);
}
static vm_value nat_lower(vm *v, vm_value self, int argc, const vm_value *argv, void *ud) { (void)argc; (void)argv; (void)ud; return str_case(v, self, 0); }
static vm_value nat_upper(vm *v, vm_value self, int argc, const vm_value *argv, void *ud) { (void)argc; (void)argv; (void)ud; return str_case(v, self, 1); }
static vm_value nat_indexof(vm *v, vm_value self, int argc, const vm_value *argv, void *ud)
{
    (void)ud;
    if (argc < 1) return vm_num(-1.0f);
    if (self.t == V_STR) {
        char b[256];
        const char *p = strstr(self.u.o->s, vm_tostr(argv[0], b, sizeof(b)));
        return vm_num(p ? (float)(p - self.u.o->s) : -1.0f);
    }
    if (self.t == V_OBJ && self.u.o->kind == O_ARRAY) {
        for (uint32_t i = 0; i < self.u.o->nel; i++) if (strict_eq(self.u.o->el[i], argv[0])) return vm_num((float)i);
    }
    (void)v;
    return vm_num(-1.0f);
}

static void builtin(vm *v, vm_obj *o, const char *name, vm_native fn)
{
    vm_set(v, o, name, vm_objv(vm_new_native(v, name, fn, NULL)));
}

// ---- creation, roots, collection -------------------------------------------------------------------
vm_obj *vm_globals(vm *v) { return v->globals; }

vm *vm_new(const uint8_t *x, uint32_t len, const vm_limits *lim, char *err, size_t errlen)
{
    if (len < 52 || memcmp(x, "VSMX", 4)) { snprintf(err, errlen, "not a VSMX script"); return NULL; }
    uint32_t h[13];
    for (int i = 0; i < 13; i++) h[i] = le32(x + 4 * i);
    // h: sig, version, code off / len, text off / len / count, prop off / len / count, names off / len / count
    if ((uint64_t)h[2] + h[3] > len || (uint64_t)h[4] + h[5] > len || (uint64_t)h[7] + h[8] > len ||
        (uint64_t)h[10] + h[11] > len || h[3] % 8) {
        snprintf(err, errlen, "a VSMX table past the script");
        return NULL;
    }
    vm *v = (vm *)calloc(1, sizeof(vm));
    if (!v) { snprintf(err, errlen, "out of memory"); return NULL; }
    v->stack_max = lim->stack_max; v->frames_max = lim->frames_max; v->heap_max = lim->heap_max;
    v->trace_calls = getenv("VSMX_TRACE_CALLS") != NULL;
    v->stack = (vm_value *)calloc(v->stack_max, sizeof(vm_value));
    v->fr = (frame *)calloc(v->frames_max, sizeof(frame));
    v->code = x + h[2]; v->ninstr = h[3] / 8;
    if (!v->stack || !v->fr ||
        utf16_table(v, x + h[4], h[5], h[6], &v->text, &v->ntext) ||
        utf16_table(v, x + h[7], h[8], h[9], &v->prop, &v->nprop) ||
        latin1_table(v, x + h[10], h[11], h[12], &v->name, &v->nname)) {
        snprintf(err, errlen, "%s", v->err[0] ? v->err : "out of memory");
        vm_free(v);
        return NULL;
    }
    v->k_length = new_str(v, "length", 6);
    v->k_proto = new_str(v, "prototype", 9);
    v->globals = vm_new_object(v, "global");
    v->proto_array = vm_new_object(v, "Array.prototype");
    v->proto_string = vm_new_object(v, "String.prototype");
    builtin(v, v->proto_array, "push", nat_push);
    builtin(v, v->proto_array, "pop", nat_pop);
    builtin(v, v->proto_array, "shift", nat_shift);
    builtin(v, v->proto_array, "join", nat_join);
    builtin(v, v->proto_array, "indexOf", nat_indexof);
    builtin(v, v->proto_array, "toString", nat_join);
    builtin(v, v->proto_string, "charAt", nat_charat);
    builtin(v, v->proto_string, "substring", nat_substring);
    builtin(v, v->proto_string, "slice", nat_slice);
    builtin(v, v->proto_string, "toLowerCase", nat_lower);
    builtin(v, v->proto_string, "toUpperCase", nat_upper);
    builtin(v, v->proto_string, "indexOf", nat_indexof);
    builtin(v, v->proto_string, "toString", nat_tostring);
    vm_set(v, v->globals, "undefined", vm_undef());
    vm_set(v, v->globals, "Array", vm_objv(vm_new_native(v, "Array", nat_array, NULL)));
    vm_set(v, v->globals, "Object", vm_objv(vm_new_native(v, "Object", nat_object, NULL)));
    if (v->err[0]) { snprintf(err, errlen, "%s", v->err); vm_free(v); return NULL; }
    return v;
}

void vm_free(vm *v)
{
    if (!v) return;
    while (v->fp) pop_frame(v);
    for (vm_obj *o = v->heap, *n; o; o = n) { n = o->gc_next; free_obj(o); }
    free(v->stack); free(v->fr); free(v->text); free(v->prop); free(v->name); free(v->roots);
    free(v);
}

void vm_root_add(vm *v, vm_obj *o)
{
    if (v->nroots == v->croots) {
        uint32_t nc = v->croots ? 2 * v->croots : 16;
        vm_obj **nr = (vm_obj **)realloc(v->roots, nc * sizeof(vm_obj *));
        if (!nr) { verr(v, "out of memory"); return; }
        v->roots = nr; v->croots = nc;
    }
    v->roots[v->nroots++] = o;
}
void vm_root_del(vm *v, vm_obj *o)
{
    for (uint32_t i = 0; i < v->nroots; i++)
        if (v->roots[i] == o) { v->roots[i] = v->roots[--v->nroots]; return; }
}

static void mark(vm_obj *o)
{
    // an explicit stack: no recursion on deep structures
    vm_obj *stk[4096];
    int sp = 0;
    if (!o || o->mark) return;
    o->mark = 1; stk[sp++] = o;
    while (sp) {
        vm_obj *x = stk[--sp];
        if (x->proto && !x->proto->mark) { x->proto->mark = 1; if (sp < 4096) stk[sp++] = x->proto; else mark(x->proto); }
        for (uint32_t i = 0; i < x->nprops; i++) {
            vm_obj *k = x->props[i].key, *vo = (x->props[i].val.t == V_STR || x->props[i].val.t == V_OBJ) ? x->props[i].val.u.o : NULL;
            if (k && !k->mark) k->mark = 1;
            if (vo && !vo->mark) { vo->mark = 1; if (sp < 4096) stk[sp++] = vo; else mark(vo); }
        }
        for (uint32_t i = 0; i < x->nel; i++) {
            vm_obj *vo = (x->el[i].t == V_STR || x->el[i].t == V_OBJ) ? x->el[i].u.o : NULL;
            if (vo && !vo->mark) { vo->mark = 1; if (sp < 4096) stk[sp++] = vo; else mark(vo); }
        }
    }
}

void vm_gc(vm *v)
{
    if (v->fp || v->sp) return;                   // only between runs
    for (vm_obj *o = v->heap; o; o = o->gc_next) o->mark = 0;
    mark(v->globals); mark(v->proto_array); mark(v->proto_string);
    mark(v->k_length); mark(v->k_proto);
    for (uint32_t i = 0; i < v->ntext; i++) mark(v->text[i]);
    for (uint32_t i = 0; i < v->nprop; i++) mark(v->prop[i]);
    for (uint32_t i = 0; i < v->nname; i++) mark(v->name[i]);
    for (uint32_t i = 0; i < v->nroots; i++) mark(v->roots[i]);
    vm_obj **pp = &v->heap;
    while (*pp) {
        vm_obj *o = *pp;
        if (!o->mark) { *pp = o->gc_next; free_obj(o); v->nheap--; }
        else pp = &o->gc_next;
    }
}

int vm_run_main(vm *v)
{
    v->err[0] = 0;
    int rc = interpret(v, 0);
    while (v->fp) pop_frame(v);
    v->sp = 0;
    return rc ? -1 : (v->err[0] ? -1 : 0);
}
