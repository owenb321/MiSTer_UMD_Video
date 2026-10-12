// vsmx.h -- the disc menus' script VM (P9 M1b, docs/p9.md S3.3): VSMX bytecode, as the RCOs carry
// it (a compiled JavaScript dialect), run as written. Portable C (the PC and the UMD Main).
//
// THE FORMAT (RCOMage's vsmx.c, JPCSP's VSMXCode; checked on the library's disassembly): a 13-word
// header {"VSMX", 0x10000, code (offset, length), text (offset, length, count), properties
// (offset, length, count), names (offset, length, count)}; the code is 8-byte groups {u32 id,
// u32 value}, the opcode in the id's low byte; text and property strings UTF-16LE, names latin-1,
// all NUL-terminated and indexed by the value.
//
// THE SEMANTICS (each measured on the bytecode where JPCSP is silent or wrong; docs/p9.md S3.3):
//   * numbers are float32; an INT constant becomes a float32;
//   * every expression opcode pushes exactly one value, every call pushes its result (undefined
//     when a native returns nothing: JPCSP's #445 crash was a call that pushed none);
//   * END_STMT pops ONE value if the frame has one (the && / || chains run COPY, JUMP_FALSE,
//     END_STMT mid-expression: JPCSP's stack clear would drop a pending call's callee);
//   * OBJECT pushes a new object (`x = {}`), OBJ_ADD_ATTR stores into the object it leaves on the
//     stack (object literals), SET_ATTR stores, pops both and pushes the value (an assignment is an
//     expression: The Rock's tryToCloseBlack tests `s.playListNumber != 4 && (s.playStatus = 1)`,
//     the library's one SET_ATTR not followed by END_STMT, which pops it), ARRAY / ARRAY_ELEM build an array
//     literal, ARRAY_INDEX_ASSIGN stores `a[k] = v` and pushes nothing;
//   * an EMPTY ARRAY is false (JPCSP's VSMXArray, observed on a PSP; Austin Powers 2's
//     Chapter_menu2 passes [] for "no position pages" and tests `!a9 || !a10`: as true JavaScript
//     it opens p_CMMM_1_p, a page the disc does not have); every other object is true;
//   * a property read on a missing name is undefined (the name is not created); prototypes chain
//     (`new F()` objects look up F.prototype);
//   * THE EMPTY CONSTANT (opcode 0x24, JPCSP's CONST_EMPTYARRAY, which its decompiler writes `{}`) is
//     "nothing": loosely equal (==, !=) to an empty array, undefined and null (X-Men's `btn != []`
//     with btn the constant; Now That's Music's `currentPage != []` with currentPage unset). An array
//     LITERAL (0x2B ARRAY, even with no element) compares by identity, as JavaScript: Batman & Robin's
//     onMenu runs only `if (fArray != [])` -- its pending-action array, empty in the film -- and its
//     Square works on a PSP; Austin Powers 2's `fArray != []` holds for [8, show_ls] (docs/p9.md M4,
//     vsmx.c's loose_eq); strict equality is identity;
//   * try / catch (0x41-0x44, X-Men's only use; JPCSP leaves them unimplemented): measured on its
//     MMAnim (docs/p9.md M3) -- a script's TypeError inside a try (a call of a non-function, a method
//     of undefined, `new` of a non-constructor) unwinds to its catch with the error's text as the
//     exception; the VM's own errors (a refusal, a bound, a malformed script) are never caught;
//   * opcodes 0x16 INSTANCEOF, 0x17 IN, 0x37, 0x40, 0x48, 0x49 occur on no library disc: REFUSED
//     (the script stops with a reason; the engine falls back to direct play, docs/p9.md S5).
//
// BOUNDS (docs/p9.md S6): the operand stack, the call depth and the heap are fixed sizes set at
// creation; hitting one stops the script with a reason (vm->err) -- never a crash, never silent.
// The heap is collected (mark and sweep) only between runs, the VM idle.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vm vm;
typedef struct vm_obj vm_obj;

typedef enum { V_UNDEF, V_NULL, V_BOOL, V_NUM, V_STR, V_OBJ,
               V_REF, V_METHOD } vm_type;        // V_REF / V_METHOD live on the operand stack only
typedef enum { R_GLOBAL, R_PROP, R_LOCAL } vm_refkind;

typedef struct vm_value {
    uint8_t  t;
    uint8_t  rk;                // V_REF: its kind
    union {
        int      b;
        float    n;
        vm_obj  *o;             // V_STR (a string object), V_OBJ, V_REF / V_METHOD: the object
    } u;
    union {
        vm_obj  *key;           // V_REF R_GLOBAL / R_PROP, V_METHOD: the name (a string object)
        int      local;         // V_REF R_LOCAL: the slot
    } k;
} vm_value;

typedef enum { O_STR, O_OBJECT, O_ARRAY, O_FUNC, O_NATIVE } vm_objkind;

// a native function: `self` is `this`; argv[0..argc-1]; returns its result (V_UNDEF for none)
typedef vm_value (*vm_native)(vm *v, vm_value self, int argc, const vm_value *argv, void *ud);

typedef struct { vm_obj *key; vm_value val; } vm_prop;

struct vm_obj {
    uint8_t  kind;
    uint8_t  mark;
    uint8_t  nothing;           // O_ARRAY: made by the EMPTY constant (0x24), "nothing" while empty
    vm_obj  *gc_next;
    // O_STR
    char    *s;
    uint32_t slen;
    // O_OBJECT / O_ARRAY / O_FUNC / O_NATIVE: properties (also every array's named ones)
    vm_prop *props;
    uint32_t nprops, cprops;
    vm_obj  *proto;
    const char *cls;            // a class tag for natives / traces ("Page", "movieplayer", ...)
    void    *host;              // the host's object behind a native one (a scene object)
    // O_ARRAY
    vm_value *el;
    uint32_t nel, cel;
    // O_FUNC
    uint32_t pc, nargs, nlocals;
    // O_NATIVE
    vm_native fn;
    void    *ud;
};

typedef struct {
    uint32_t stack_max;         // operand slots (all frames)
    uint32_t frames_max;        // call depth
    uint32_t heap_max;          // live heap objects
} vm_limits;

// the trace: every native call and every callback entry, one line each (NULL: none)
typedef void (*vm_trace_fn)(void *ud, const char *line);

struct vm *vm_new(const uint8_t *vsmx, uint32_t len, const vm_limits *lim, char *err, size_t errlen);
void vm_free(vm *v);
const char *vm_error(const vm *v);               // "" until a script stopped
// the pending error is a script's TypeError that an enclosing try will catch (a handler a native ran
// threw inside the script's try): the host lets it propagate instead of stopping
int vm_error_caught(const vm *v);
// the pending error is a script's TypeError (a try could catch it), not the VM's own; and clearing it:
// the host abandons the handler that threw and goes on, as the PSP's player does
int vm_error_catchable(const vm *v);
void vm_error_clear(vm *v);
void vm_set_trace(vm *v, vm_trace_fn fn, void *ud);
void vm_trace(vm *v, const char *fmt, ...);

// the global object (the host adds its natives here before vm_run_main)
vm_obj *vm_globals(vm *v);
// run the script's top level (it defines its functions and globals); 0 ok
int  vm_run_main(vm *v);
// call a function value with `self` and arguments; *ret its result; 0 ok
int  vm_call(vm *v, vm_value fn, vm_value self, int argc, const vm_value *argv, vm_value *ret);
// collect garbage (the VM idle); the host's extra roots via vm_root_add
void vm_gc(vm *v);
void vm_root_add(vm *v, vm_obj *o);
void vm_root_del(vm *v, vm_obj *o);

// values
vm_value vm_undef(void);
vm_value vm_null(void);
vm_value vm_bool(int b);
vm_value vm_num(float n);
vm_value vm_str(vm *v, const char *s);
vm_value vm_objv(vm_obj *o);
vm_obj  *vm_new_object(vm *v, const char *cls);
vm_obj  *vm_new_array(vm *v, uint32_t n);
vm_obj  *vm_new_native(vm *v, const char *name, vm_native fn, void *ud);
void     vm_set(vm *v, vm_obj *o, const char *key, vm_value val);
vm_value vm_get(vm *v, vm_obj *o, const char *key);
void     vm_array_push(vm *v, vm_obj *a, vm_value val);
float    vm_tonum(vm_value x);
int      vm_toint(vm_value x);
int      vm_tobool(vm_value x);
// a value as text (for traces and string conversion): writes into buf, returns it
const char *vm_tostr(vm_value x, char *buf, size_t n);
int      vm_is_func(vm_value x);

#ifdef __cplusplus
}
#endif
