#!/usr/bin/env python3
"""The navigation engine: its ISA, the assembler, an instruction-level emulator, and the
N1 harness that scores umd/nav/nav.uasm against the reader's own fixtures
(docs/nav_engine.md S5, S7).

The engine replaces umd_reader.sv's parse (the ISO9660 walk, PARAM.SFO, PLAYLIST.UMD, the
CLPs, the EP maps, the marks, the navigation commands) with a program; the pump (the sd
handshake, the stream cache, the output pipe) stays hardware. This file is the executable
definition of the machine: the RTL (umd/nav/nav_seq.sv, N2) must match the emulator
instruction by instruction.

Word: 40 bits = op[39:34] rd[33:30] rs[29:26] rt[25:22] imm[21:6] aux[5:0] (at3p_isa.py's).
Registers r0..r15, 32 bits; r0 reads 0. A carry flag C. Four cycles an instruction.

  alu   rd, rs, rt        rd = rs FN rt            (FN in aux)
  alui  rd, rs, imm       rd = rs FN zext16(imm)
  lui   rd, imm           rd = imm << 16
  ld    rd, imm[rs]       rd = DATA[rs + imm]      (scratch RAM, or I/O at 0x800 up)
  st    rd, imm[rs]       DATA[rs + imm] = rd
  lbf   rd, imm[rs], n    rd = n bytes (1-4) big-endian at byte rs + imm of the current file
  lbl   rd, imm[rs], n    ... little-endian
  b<c>  rs, rt, label     c in eq ne ltu geu; b<c>i rs, k, label against a 10-bit constant
  bcs / bcc label         on C
  jmp / call label, ret   (call stack 8 deep)
  wait  mask              stall until (STATUS & mask) != 0

FN: add sub adc sbc and or xor shl shr sltu seq sne. add / adc set C to the carry out;
sub / sbc to the borrow (rs < rt unsigned, with the incoming borrow for sbc). Nothing else
touches C.

A file byte at offset o is in sector F_LBA + (o >> 11); a sector past F_LAST reads 0 (the
RTL's no-cross rule: a directory sector, a file's last sector). Two sector slots, by LBA
(the older replaced); a miss reads the sector over sd.

    nav_isa.py --asm [umd/nav/nav.uasm] [-o umd/nav/nav_ucode.mem]
    nav_isa.py --fixture STEM [STEM ...] [--lat CYCLES] [-v]      # N1: score the program
"""
import argparse
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
UASM = os.path.join(REPO, "umd", "nav", "nav.uasm")
UMEM = os.path.join(REPO, "umd", "nav", "nav_ucode.mem")

OPS = ["nop", "alu", "alui", "lui", "ld", "st", "lbf", "lbl", "br", "bri", "bcs", "bcc",
       "jmp", "call", "ret", "wait"]
OP = {n: i for i, n in enumerate(OPS)}
FNS = ["add", "sub", "adc", "sbc", "and", "or", "xor", "shl", "shr", "sltu", "seq", "sne"]
FN = {n: i for i, n in enumerate(FNS)}
CONDS = ["eq", "ne", "ltu", "geu"]
STACK_DEPTH = 8
CPI = 4                         # cycles an instruction
M32 = 0xFFFFFFFF

# ---- the data space ----------------------------------------------------------------------
RAM_WORDS = 0x200               # scratch: the walk's variables
IO_BASE = 0x800
# I/O: inputs (reads)
IO_IN = ["I_FSIZE_LO", "I_FSIZE_HI", "I_STATUS", "I_NAV_OP", "I_NAV_PL", "I_NAV_ITEM",
         "I_NAV_PTS_LO", "I_NAV_PTS_HI", "I_P_LEFT", "I_P_CLIP_LEFT", "I_STATE"]
# I/O: the reader's outputs and controls (writes; outputs read back what was written)
IO_OUT = ["O_STATE", "O_ERR", "O_STREAMING", "O_TITLE_DONE", "O_FLAGS", "O_BARE",
          "O_TITLE_LEN", "O_MAIN_PL", "O_N_PLAYLISTS", "O_N_ITEMS", "O_ITEM_IDX",
          "O_CLIP_NAME_HI", "O_CLIP_NAME_LO", "O_ITEM_IN_LO", "O_ITEM_IN_HI", "O_ITEM_OUT_LO",
          "O_ITEM_OUT_HI", "O_ITEM_BASE_LO", "O_ITEM_BASE_HI", "O_PL_DUR_LO", "O_PL_DUR_HI",
          "O_MPS_LBA", "O_MPS_BYTES", "O_CLIP_START_LO", "O_CLIP_START_HI", "O_CLIP_END_LO",
          "O_CLIP_END_HI", "O_N_STREAMS", "O_N_VIDEO", "O_N_UNKNOWN", "O_VID_ATTR",
          "O_AUD_PRESENT", "O_SUB_PRESENT", "O_EP_MAP_OFF", "O_NAV_ERR", "O_NAV_LAND",
          "O_NAV_EP_IDX", "O_NAV_EP_PTS", "O_NAV_EP_SEC", "O_NAV_SKIP_LO", "O_NAV_SKIP_HI",
          "O_EP_FLAGS", "O_CH_RANK", "O_CH_COUNT", "O_CH_VALID", "O_CH_CUR_LO", "O_CH_CUR_HI",
          "O_CH_PREV_LO", "O_CH_PREV_HI", "O_CH_NEXT_LO", "O_CH_NEXT_HI",
          # controls
          "O_ACC_ITEMS", "O_NAV_READY", "O_NAV_DONE", "O_ITEM_START", "O_F_LBA", "O_F_LAST",
          "P_LBA", "P_LEFT", "P_CLIP_LEFT", "P_CLIP_LIM", "P_TAG", "P_CMD"]
IO = {}
for i, n in enumerate(IO_IN):
    IO[n] = IO_BASE + i
for i, n in enumerate(IO_OUT):
    IO[n] = IO_BASE + 0x40 + i
IO["O_TITLE_MEM"] = IO_BASE + 0x100        # + k, k < 128: a byte of title_mem
IO["O_LANG_MEM"] = IO_BASE + 0x180         # + k, k < 48: a language word
IO_ADDR = {v: k for k, v in IO.items()}

# STATUS bits (reads; `wait` masks)
ST = {"ST_PEND": 0, "ST_PUMP_IDLE": 1, "ST_EMPTY": 2, "ST_NOHOLD": 3, "ST_HOLD": 4,
      "ST_ACCEPTED": 5, "ST_STOPPED": 6}
# pump commands (P_CMD)
PC_STREAM, PC_PAUSE, PC_RESUME = 1, 2, 3
# O_FLAGS bits
FL_SFO_WARN, FL_TRUNC, FL_DUR_SAT, FL_PMF_WARN = 1, 2, 4, 8


def asm_env():
    env = dict(IO)
    env.update({k: 1 << v for k, v in ST.items()})
    env.update({"PC_STREAM": PC_STREAM, "PC_PAUSE": PC_PAUSE, "PC_RESUME": PC_RESUME,
                "FL_SFO_WARN": FL_SFO_WARN, "FL_TRUNC": FL_TRUNC, "FL_DUR_SAT": FL_DUR_SAT,
                "FL_PMF_WARN": FL_PMF_WARN})
    return env


def encode(op, rd=0, rs=0, rt=0, imm=0, aux=0):
    return (OP[op] << 34) | ((rd & 15) << 30) | ((rs & 15) << 26) | ((rt & 15) << 22) | \
        ((imm & 0xFFFF) << 6) | (aux & 63)


def decode(w):
    return (OPS[(w >> 34) & 63], (w >> 30) & 15, (w >> 26) & 15, (w >> 22) & 15,
            (w >> 6) & 0xFFFF, w & 63)


# --------------------------------------------------------------------------- assembler

class AsmError(Exception):
    pass


def _regnum(tok, aliases):
    tok = tok.strip().lower()
    tok = aliases.get(tok, tok)
    m = re.fullmatch(r"r(\d+)", tok)
    if not m or int(m.group(1)) > 15:
        raise AsmError("not a register: %r" % tok)
    return int(m.group(1))


def assemble(text):
    """-> (words, labels, lines). Two passes; .equ constants, .reg aliases, labels.
    Pseudo-instructions: li (one word when the constant fits 16 bits, else lui + or),
    mov, nop, sub/add/... with a constant (the alui form)."""
    equ = asm_env()
    aliases = {}
    labels = {}
    stmts = []

    def ev0(expr, ln):
        try:
            return int(eval(expr, {"__builtins__": {}}, dict(equ)))
        except Exception as e:
            raise AsmError("line %d: cannot evaluate %r (%s)" % (ln, expr, e))

    # pass 1: sizes (li may take two words: its constant must be known in pass 1, or it
    # is assumed wide)
    for ln, raw in enumerate(text.splitlines(), 1):
        line = re.sub(r"[;#].*", "", raw).strip()
        if not line:
            continue
        while True:
            m = re.match(r"([A-Za-z_][\w.]*):\s*(.*)$", line)
            if not m:
                break
            if m.group(1) in labels:
                raise AsmError("line %d: label %s twice" % (ln, m.group(1)))
            labels[m.group(1)] = sum(n for _l, _t, _a, n in stmts)
            line = m.group(2).strip()
        if not line:
            continue
        if line.startswith(".equ"):
            _, name, val = line.split(None, 2)
            equ[name] = ev0(val, ln)
            continue
        if line.startswith(".reg"):
            _, name, reg = line.split(None, 2)
            aliases[name.lower()] = reg.strip().lower()
            continue
        n = 1
        mm = re.match(r"(\w+)\s*(.*)$", line)
        if mm.group(1).lower() == "li":
            parts = [a.strip() for a in mm.group(2).split(",", 1)]
            try:
                v = int(eval(parts[1], {"__builtins__": {}}, dict(equ))) & M32
                n = 1 if v < 0x10000 else 2
            except Exception:
                n = 2
        stmts.append((ln, line, dict(aliases), n))

    def ev(expr, ln):
        env = dict(equ)
        env.update(labels)
        try:
            return int(eval(expr, {"__builtins__": {}}, env))
        except Exception as e:
            raise AsmError("line %d: cannot evaluate %r (%s)" % (ln, expr, e))

    words = []
    lines = []
    for ln, line, al, nw in stmts:
        m = re.match(r"(\w+)\s*(.*)$", line)
        mn, rest = m.group(1).lower(), m.group(2)
        args = [a.strip() for a in re.split(r",(?![^\[]*\])", rest)] if rest else []

        def reg(i):
            return _regnum(args[i], al)

        def is_reg(s):
            s = s.strip().lower()
            return re.fullmatch(r"r\d+", al.get(s, s)) is not None

        def memref(s):
            """imm[ra] | imm | [ra]"""
            m2 = re.fullmatch(r"(.*?)\s*\[([^\]]*)\]", s)
            if not m2:
                return ev(s, ln), 0
            imm = ev(m2.group(1), ln) if m2.group(1).strip() else 0
            ra = _regnum(m2.group(2), al) if m2.group(2).strip() else 0
            return imm, ra
        out = []
        try:
            if mn in FN:
                if is_reg(args[2]):
                    out.append(encode("alu", reg(0), reg(1), reg(2), 0, FN[mn]))
                else:
                    v = ev(args[2], ln)
                    if not 0 <= v <= 0xFFFF:
                        raise AsmError("line %d: immediate %d outside 0..65535" % (ln, v))
                    out.append(encode("alui", reg(0), reg(1), 0, v, FN[mn]))
            elif mn == "li":
                v = ev(args[1], ln) & M32
                if nw == 1:
                    if v >= 0x10000:
                        raise AsmError("line %d: li constant changed size between passes" % ln)
                    out.append(encode("alui", reg(0), 0, 0, v, FN["add"]))
                else:
                    out.append(encode("lui", reg(0), 0, 0, v >> 16))
                    out.append(encode("alui", reg(0), reg(0), 0, v & 0xFFFF, FN["or"]))
            elif mn == "lui":
                out.append(encode("lui", reg(0), 0, 0, ev(args[1], ln)))
            elif mn == "mov":
                out.append(encode("alu", reg(0), reg(1), 0, 0, FN["add"]))
            elif mn in ("ld", "st"):
                imm, ra = memref(args[1])
                # a store's data register goes in rt as well: the engine reads it through its
                # second register-file port (nav_seq.sv)
                out.append(encode(mn, reg(0), ra, reg(0) if mn == "st" else 0, imm))
            elif mn in ("lbf", "lbl"):
                imm, ra = memref(args[1])
                n = ev(args[2], ln)
                if not 1 <= n <= 4:
                    raise AsmError("line %d: %s of %d bytes" % (ln, mn, n))
                out.append(encode(mn, reg(0), ra, 0, imm, n))
            elif mn[:1] == "b" and mn[1:] in CONDS:
                out.append(encode("br", CONDS.index(mn[1:]), reg(0), reg(1), ev(args[2], ln)))
            elif mn[:1] == "b" and mn[1:-1] in CONDS and mn[-1] == "i":
                c = ev(args[1], ln)
                if not 0 <= c <= 1023:
                    raise AsmError("line %d: branch constant %d outside 0..1023" % (ln, c))
                out.append(encode("bri", CONDS.index(mn[1:-1]), reg(0), c >> 6, ev(args[2], ln),
                                  c & 63))
            elif mn in ("bcs", "bcc", "jmp", "call"):
                out.append(encode(mn, 0, 0, 0, ev(args[0], ln)))
            elif mn in ("ret", "nop"):
                out.append(encode(mn))
            elif mn == "wait":
                out.append(encode("wait", 0, 0, 0, ev(args[0], ln)))
            else:
                raise AsmError("line %d: unknown instruction %r" % (ln, mn))
        except (IndexError, KeyError) as e:
            raise AsmError("line %d: bad operands for %r (%s)" % (ln, line, e))
        if len(out) != nw:
            raise AsmError("line %d: size changed between passes" % ln)
        words += out
        lines += [ln] * len(out)
    return words, labels, lines


# ----------------------------------------------------------------------------- the world

class Fail(Exception):
    def __init__(self, arm, msg):
        Exception.__init__(self, "FAIL [%s] %s" % (arm, msg))
        self.arm = arm


SEC = 2048
CACHE_BYTES = 16384
STEP = 512


class World:
    """Everything outside the engine, at sector granularity: the image (served from a
    fixture, every read checked as umd_reader_tb's [walk] / [order] / [stream] do), the
    pump (the stream cache, the output drain), the navigation latch with its acceptance
    rule, and the reader's output registers. Times are clk_sys cycles."""

    # hardware mutations (--hw-mut, run_nav_model.sh --red): the gate must see each
    HW_MUTS = ("slots0",        # R14: no sector slot -- every file byte an sd read ([thrash])
               "seek_noitem",   # N10: a SEEK accepted whatever its item
               "play_nopl",     # P1: a PLAY accepted whatever its playlist
               "time_noitems",  # T6: a TIME accepted on a playlist with no item
               "bare_accept",   # B5: a bare stream accepts SEEK / TIME / PLAY
               "noflush",       # N9: an accepted take does not flush the cache
               "guard_off")     # N26: item_hold's guard on the state write is gone ([hold])

    def __init__(self, fx, lat=4200, drain=2.33, hw_mut=()):
        self.fx = fx
        self.hw_mut = set(hw_mut)
        # item_hold, as umd_reader_tb drives it: up one cycle in three, re-drawn every
        # instruction (seeded by the fixture, so a run repeats)
        self.rng = random.Random(os.path.basename(fx.stem))
        self.hold = False
        self.lat = lat                  # an sd read, cycles
        self.drain = drain              # cycles an output byte: umd_reader_tb's pipe takes one in
                                        # two cycles, then waits out `busy` (25 %): 1 + 1 / 0.75
        self.now = 0
        self.out = {}                   # O_* -> value
        self.title = [0] * 128
        self.lang = [0] * 48
        self.status_stop = False
        self.reset_world()

    def reset_world(self):
        self.slots = []                 # [(lba, bytes)] most recent last, at most 2
        self.sd_free = 0                # the sd port is busy until
        # pump
        self.p = dict(lba=0, left=0, clip_left=0, clip_lim=0, tag=0)
        self.pump_on = False            # streaming requested and not stopped
        self.paused = False
        self.inflight = None            # (done_time, lba, tag, counted)
        self.level = 0                  # bytes in the cache
        self.q = []                     # [(lba, tag)] sectors in the cache, oldest first
        self.qoff = 0                   # bytes of q[0] delivered
        self.delivered = 0              # bytes out since the phase started (the harness's)
        self.last = self.now
        # navigation latch
        self.pend = False
        self.accepted = False
        self.cmd = None
        self.req = None                 # the harness's request: (op, pl, item, pts)
        self.take_hook = None
        for k in ("O_STATE", "O_ERR", "O_STREAMING", "O_TITLE_DONE", "O_NAV_READY"):
            self.out[k] = 0

    # -- time ---------------------------------------------------------------------
    def advance(self, t):
        """Run the pump and the output drain up to time t."""
        while True:
            # the next event: a request completing, or the cache running dry
            t_done = self.inflight[0] if self.inflight else None
            if t_done is not None and t_done <= t:
                self._drain_to(t_done)
                self._complete()
                self._pump_issue()
                continue
            self._drain_to(t)
            self._pump_issue()
            self._try_take()
            self.hold = self.rng.random() < 1.0 / 3
            return

    def _drain_to(self, t):
        """The output pipe: a byte every `drain` cycles while the cache holds one."""
        if self.level == 0:
            self.last = max(self.last, t)
            return
        n = min(int((t - self.last) / self.drain), self.level)
        if n <= 0:
            return
        self.last += n * self.drain
        while n > 0 and self.q:
            take = min(n, SEC - self.qoff)
            lba, tag = self.q[0]
            self.fx.on_bytes(lba, tag, self.qoff, take)
            self.qoff += take
            self.level -= take
            self.delivered += take
            n -= take
            if self.qoff == SEC:
                self.q.pop(0)
                self.qoff = 0
        if self.level == 0:
            self.last = t

    def _room(self):
        return self.level < CACHE_BYTES - SEC - 1

    def _pump_issue(self):
        p = self.p
        if not self.pump_on or self.paused or self.inflight is not None:
            return
        if self.now < self.sd_free:
            return
        if (p["clip_lim"] and p["clip_left"] == 0) or p["left"] == 0:
            self.pump_on = False                    # stopped by its own condition
            return
        if not self._room():
            return
        lba = p["lba"]
        self.fx.on_request(lba, stream=True)
        self.inflight = (self.now + self.lat, lba, p["tag"], True)
        self.sd_free = self.now + self.lat

    def _complete(self):
        _t, lba, tag, counted = self.inflight
        self.inflight = None
        if not counted:
            return                                  # abandoned at a flush: lands nowhere
        p = self.p
        self.q.append((lba, tag))
        self.level += SEC
        p["lba"] = (p["lba"] + 1) & M32
        p["left"] = (p["left"] - 1) & M32
        p["clip_left"] = (p["clip_left"] - 1) & M32

    def next_event(self):
        ts = []
        if self.inflight:
            ts.append(self.inflight[0])
        if self.level > 0:
            ts.append(self.last + self.level * self.drain + 1)
        if self.pump_on and not self.paused and self.inflight is None and self.now < self.sd_free:
            ts.append(self.sd_free)
        if not ts:
            return None
        # at most STEP cycles at a time: the harness's triggers (bytes delivered, a transfer in
        # flight) are sampled between steps, as the RTL bench samples them every cycle
        return min(min(ts), self.now + STEP)

    # -- the navigation latch -------------------------------------------------------
    def _try_take(self):
        if self.req is None or self.pend or not self.out.get("O_NAV_READY", 0):
            return
        op, pl, item, pts = self.req
        self.req = None
        bare = self.out.get("O_BARE", 0)
        acc_items = self.out.get("O_ACC_ITEMS", 0)
        m = self.hw_mut
        acc = (bare == 0 or "bare_accept" in m) and (
            (op == 1 and (item < acc_items or "seek_noitem" in m)) or
            (op == 4 and (acc_items != 0 or "time_noitems" in m)) or
            (op == 3 and (pl < self.out.get("O_N_PLAYLISTS", 0) or "play_nopl" in m)))
        self.cmd = (op, pl, item, pts)
        self.pend = True
        self.accepted = acc
        if acc:                                      # the RTL's take: flush at the edge
            if "noflush" not in self.hw_mut:
                self.flush()
            else:
                self.pump_on = False
            self.out["O_STREAMING"] = 0
            self.out["O_TITLE_DONE"] = 0
        if self.take_hook:
            self.take_hook(op, acc)

    def flush(self):
        self.q = []
        self.qoff = 0
        self.level = 0
        self.pump_on = False
        self.paused = False
        if self.inflight:
            self.inflight = (self.inflight[0], self.inflight[1], self.inflight[2], False)

    # -- the engine's ports -----------------------------------------------------------
    def status(self):
        s = 0
        if self.pend:
            s |= 1 << ST["ST_PEND"]
        if not self.pump_on or (self.paused and self.inflight is None):
            s |= 1 << ST["ST_PUMP_IDLE"]
        if self.level == 0:
            s |= 1 << ST["ST_EMPTY"]
        s |= 1 << ST["ST_HOLD" if self.hold else "ST_NOHOLD"]
        if self.accepted:
            s |= 1 << ST["ST_ACCEPTED"]
        if self.status_stop:
            s |= 1 << ST["ST_STOPPED"]
        return s

    def io_read(self, a):
        n = IO_ADDR.get(a)
        if n is None:
            raise RuntimeError("I/O read of 0x%x" % a)
        fs = self.fx.file_size
        if n == "I_FSIZE_LO":
            return fs & M32
        if n == "I_FSIZE_HI":
            return fs >> 32
        if n == "I_STATUS":
            return self.status()
        if n.startswith("I_NAV"):
            op, pl, item, pts = self.cmd or (0, 0, 0, 0)
            return {"I_NAV_OP": op, "I_NAV_PL": pl, "I_NAV_ITEM": item,
                    "I_NAV_PTS_LO": pts & M32, "I_NAV_PTS_HI": pts >> 32}[n]
        if n == "I_P_LEFT":
            return self.p["left"]
        if n == "I_P_CLIP_LEFT":
            return self.p["clip_left"]
        if n == "I_STATE":
            return self.out.get("O_STATE", 0)
        raise RuntimeError("read of the write-only output %s" % n)

    def io_write(self, a, v):
        if IO["O_TITLE_MEM"] <= a < IO["O_TITLE_MEM"] + 128:
            self.title[a - IO["O_TITLE_MEM"]] = v & 0xFF
            return
        if IO["O_LANG_MEM"] <= a < IO["O_LANG_MEM"] + 48:
            self.lang[a - IO["O_LANG_MEM"]] = v & 0xFFFF
            return
        n = IO_ADDR.get(a)
        if n is None or n.startswith("I_"):
            raise RuntimeError("I/O write of 0x%x" % a)
        if n == "O_STATE":
            # item_hold's guard (P6b3i): the walk may not leave S_ITEM (27) for the next item's
            # record (28) in a cycle item_hold is up -- that write is ignored; every other is taken
            # (S_ITEM -> the drain at the title's end does not wait for it, as in the RTL)
            if (self.out.get("O_STATE", 0) == 27 and (v & 63) == 28 and self.hold
                    and "guard_off" not in self.hw_mut):
                return
            if self.out.get("O_STATE", 0) == 27 and (v & 63) == 28 and self.hold:
                # umd_reader_tb's [hold], on the state register itself
                raise Fail("hold", "the walk left S_ITEM for the next item with item_hold up")
            self.out[n] = v & 63
            self.fx.on_state(v & 63)
            return
        if n == "O_NAV_DONE":
            self.pend = False
            self.accepted = False
            self.fx.on_nav_done()
            return
        if n == "O_ITEM_START":
            self.fx.check_hold()
            self.fx.on_item_start()
            return
        if n.startswith("P_"):
            if n == "P_CMD":
                if v == PC_STREAM:
                    self.fx.check_hold()
                    self.pump_on = True
                    self.paused = False
                elif v == PC_PAUSE:
                    self.paused = True
                elif v == PC_RESUME:
                    self.paused = False
                else:
                    raise RuntimeError("P_CMD %d" % v)
                return
            self.p[{"P_LBA": "lba", "P_LEFT": "left", "P_CLIP_LEFT": "clip_left",
                    "P_CLIP_LIM": "clip_lim", "P_TAG": "tag"}[n]] = v & M32
            return
        self.out[n] = v & M32
        if n == "O_TITLE_DONE" and v:
            self.fx.on_title_done()

    def file_byte(self, off, eng):
        """One byte of the current file (O_F_LBA, O_F_LAST); returns (byte, cycles)."""
        lba = (self.out.get("O_F_LBA", 0) + (off >> 11))
        if lba > self.out.get("O_F_LAST", 0) or lba > M32:
            return 0, 0
        for i, (l, data) in enumerate(self.slots):
            if l == lba:
                self.slots.append(self.slots.pop(i))   # most recent last
                return data[off & 2047], 0
        # a miss: the sd port (the pump must not be using it)
        if (self.inflight is not None and self.inflight[3]) or (self.pump_on and not self.paused):
            raise RuntimeError("a file load at pc %d while the pump owns the sd port" % eng.pc)
        wait = max(0, self.sd_free - self.now)
        self.fx.on_request(lba, stream=False)
        data = self.fx.sector(lba)
        self.slots.append((lba, data))
        if len(self.slots) > 2:
            self.slots.pop(0)
        if "slots0" in self.hw_mut and lba != 0:
            self.slots.pop()            # (sector 0, the sniff's, lies outside every region: kept)
        eng.note_read()
        return data[off & 2047], wait + self.lat


# ---------------------------------------------------------------------------- the engine

class Engine:
    def __init__(self, words, labels, world):
        self.prog = words
        self.labels = labels
        self.w = world
        self.reg = [0] * 16
        self.c = 0
        self.pc = 1                     # the reset vector is STOP, as nav_seq's (fj#64): only a start walks
        self.stack = []
        self.ram = [0] * RAM_WORDS
        self.instr = 0
        self.wait_mask = 0
        self.busy_since_read = 0        # engine cycles since its last sector read
        self.max_busy = 0               # ... the largest such stretch (docs/nav_engine.md S2)

    def restart(self, stop=False):
        self.pc = 1 if stop else 0
        self.stack = []
        self.w.status_stop = stop

    def note_read(self):
        self.max_busy = max(self.max_busy, self.busy_since_read)
        self.busy_since_read = 0

    def load(self, a):
        a &= 0xFFFF
        if a < RAM_WORDS:
            return self.ram[a]
        if a >= IO_BASE:
            return self.w.io_read(a)
        raise RuntimeError("load from 0x%x at pc %d" % (a, self.pc))

    def store(self, a, v):
        a &= 0xFFFF
        if a < RAM_WORDS:
            self.ram[a] = v & M32
        elif a >= IO_BASE:
            self.w.io_write(a, v & M32)
        else:
            raise RuntimeError("store to 0x%x at pc %d" % (a, self.pc))

    def alu(self, f, a, b):
        c = self.c
        if f == "add":
            r = a + b
            self.c = r >> 32
        elif f == "adc":
            r = a + b + c
            self.c = r >> 32
        elif f == "sub":
            r = a - b
            self.c = int(a < b)
        elif f == "sbc":
            r = a - b - c
            self.c = int(a < b + c)
        elif f == "and":
            r = a & b
        elif f == "or":
            r = a | b
        elif f == "xor":
            r = a ^ b
        elif f == "shl":
            r = a << (b & 31)
        elif f == "shr":
            r = a >> (b & 31)
        elif f == "sltu":
            r = int(a < b)
        elif f == "seq":
            r = int(a == b)
        elif f == "sne":
            r = int(a != b)
        else:
            raise RuntimeError(f)
        return r & M32

    def step(self):
        """One instruction. Returns False when it is a `wait` whose condition is false
        (the caller advances time)."""
        w = self.prog[self.pc]
        op, rd, rs, rt, imm, aux = decode(w)
        R = self.reg
        npc = self.pc + 1
        cyc = CPI
        waited = 0
        if op == "wait":
            if not (self.w.status() & imm):
                self.wait_mask = imm
                return False
        elif op == "alu":
            v = self.alu(FNS[aux], R[rs], R[rt])
            if rd:
                R[rd] = v
        elif op == "alui":
            v = self.alu(FNS[aux], R[rs], imm)
            if rd:
                R[rd] = v
        elif op == "lui":
            if rd:
                R[rd] = (imm << 16) & M32
        elif op == "ld":
            v = self.load(R[rs] + imm)
            if rd:
                R[rd] = v
        elif op == "st":
            self.store(R[rs] + imm, R[rd])
        elif op in ("lbf", "lbl"):
            off = (R[rs] + imm) & M32
            v = 0
            bs = []
            for k in range(aux):
                b, extra = self.w.file_byte((off + k) & M32, self)
                cyc += 2 + extra
                waited += extra             # an sd read: waiting, not the engine's work (S2's bound)
                bs.append(b)
            if op == "lbl":
                bs.reverse()
            for b in bs:
                v = (v << 8) | b
            if rd:
                R[rd] = v
        elif op == "br" or op == "bri":
            a = R[rs]
            b = R[rt] if op == "br" else ((rt << 6) | aux)
            c = CONDS[rd]
            t = {"eq": a == b, "ne": a != b, "ltu": a < b, "geu": a >= b}[c]
            if t:
                npc = imm
        elif op == "bcs":
            if self.c:
                npc = imm
        elif op == "bcc":
            if not self.c:
                npc = imm
        elif op == "jmp":
            npc = imm
        elif op == "call":
            if len(self.stack) >= STACK_DEPTH:
                raise RuntimeError("call stack overflow at pc %d" % self.pc)
            self.stack.append(npc)
            npc = imm
        elif op == "ret":
            npc = self.stack.pop()
        elif op == "nop":
            pass
        else:
            raise RuntimeError("op %s at pc %d" % (op, self.pc))
        self.pc = npc
        self.instr += 1
        self.w.now += cyc
        self.busy_since_read += cyc - waited
        return True


# ------------------------------------------------------------------------------ fixtures

def _words(path):
    if not os.path.exists(path):
        return []
    return [int(x, 16) for x in open(path).read().split() if not x.startswith("//")]


def _bytes(path):
    return bytes(int(x, 16) for x in open(path).read().split() if not x.startswith("//"))


NAV_W = 32
RW = 11
KIND_MPS, KIND_PL = 8, 4
S_ITEM = 27
LIM = 400_000_000               # cycles a step may take before the harness gives up


class Fixture:
    """One --nav fixture and the bench's checks over it (umd_reader_tb.sv's arms, those that
    are the program's: [walk] [order] [sniff] [pick] [bare] [title] [stream] (the request
    order and every sector's item tag) [done] [tracks] [clip] [base] [nav] [err] [thrash]
    [seek] [time] [play] [chap]. [hold] and +restart are the pump's: the RTL bench keeps them.)"""

    def __init__(self, stem):
        self.stem = stem
        meta = _words(stem + ".meta.hex") + [0] * 16
        self.meta = meta
        n_sec, n_reg, n_sseq, complete = meta[0], meta[1], meta[2], meta[3]
        self.n_cmd, n_nseq = meta[8], meta[9]
        self.file_size = meta[6] | (meta[7] << 32)
        self.bare = meta[10]
        img = _bytes(stem + ".hex")
        lbas = _words(stem + ".lba.hex")[:n_sec]
        self.img = {l: img[i * SEC:(i + 1) * SEC] for i, l in enumerate(lbas)}
        regw = _words(stem + ".reg.hex")
        self.regs = [regw[RW * i:RW * (i + 1)] for i in range(n_reg)]
        self.sseq = _words(stem + ".sseq.hex")[:n_sseq] + _words(stem + ".nseq.hex")[:n_nseq]
        self.n_sseq = n_sseq
        self.sitem = _words(stem + ".sitem.hex")
        self.exp = _words(stem + ".exp.hex") + [0] * 32
        self.tbytes = _bytes(stem + ".title.hex")
        self.langs = _words(stem + ".lang.hex")
        self.cmds = _words(stem + ".nav.hex")
        bw = _words(stem + ".base.hex")
        self.n_base = bw[0] if bw else 0
        self.basew = bw
        self.complete = complete
        self.nav_secs = sum(r[1] for r in self.regs if (r[2] >> 16) != KIND_MPS)
        self.pl_secs = ([r[1] for r in self.regs if (r[2] >> 16) == KIND_PL] or [0])[-1]
        self.reset_counters()
        self.ph_off, self.ph_n, self.ph_cmp = 0, n_sseq, complete
        self.nav_phase = False
        self.world = None
        self.base_main = True
        self.base_chk = 0
        self.title_done_at = None

    def reset_counters(self):
        self.touched = [False] * len(self.regs)
        self.mreq = 0
        self.nav_reads = 0
        self.nbytes = 0
        self.want_sniff = True

    def sector(self, lba):
        return self.img.get(lba, bytes(SEC))

    def find_reg(self, lba):
        r = -1
        for i, g in enumerate(self.regs):
            if g[0] <= lba < g[0] + g[1]:
                r = i
        return r

    def dep(self, r, j):
        w = self.regs[r][(7 if self.nav_phase else 3) + j // 32]
        return (w >> (j % 32)) & 1

    # -- the sd model's checks -------------------------------------------------------
    def on_request(self, lba, stream):
        if self.want_sniff:
            self.want_sniff = False
            if lba != 0:
                raise Fail("sniff", "the first read after a start is LBA %d, not 0" % lba)
            self.nav_reads += 1
            return
        r = self.find_reg(lba)
        if r < 0:
            raise Fail("walk", "read of LBA %d outside every region" % lba)
        mps = (self.regs[r][2] >> 16) == KIND_MPS
        if mps and self.mreq < self.ph_n and lba != self.sseq[self.ph_off + self.mreq]:
            raise Fail("stream", "stream request %d of the phase at %d is LBA %d, want %d"
                       % (self.mreq, self.ph_off, lba, self.sseq[self.ph_off + self.mreq]))
        if not self.touched[r]:
            for j in range(len(self.regs)):
                if self.dep(r, j) and not self.touched[j]:
                    raise Fail("order", "region %d (LBA %d) read before region %d (LBA %d) it depends on"
                               % (r, self.regs[r][0], j, self.regs[j][0]))
            self.touched[r] = True
        if mps:
            self.mreq += 1
        else:
            self.nav_reads += 1
        if stream != mps:
            raise Fail("walk", "LBA %d read as %s but lies in a %s region"
                       % (lba, "stream" if stream else "a file load", "stream" if mps else "nav"))

    def on_bytes(self, lba, tag, off, n):
        if self.nbytes < self.ph_n * SEC:
            i = self.ph_off + self.nbytes // SEC
            if self.sseq[i] != lba:
                raise Fail("stream", "byte %d of the phase at %d comes from LBA %d, want %d"
                           % (self.nbytes, self.ph_off, lba, self.sseq[i]))
            if tag != (self.sitem[i] & 3):
                raise Fail("stream", "byte %d of the phase at %d (LBA %d): item tag %d, want %d"
                           % (self.nbytes, self.ph_off, lba, tag, self.sitem[i] & 3))
        self.nbytes += n

    def on_state(self, s):
        self.state = s

    def check_hold(self):
        """[hold] (P6b3i): an item starts only after the walk left S_ITEM -- the program reads
        its state back until the guarded write was taken (umd_reader_tb's arm, at the program)."""
        if self.world.out.get("O_STATE", 0) == 27 and not self.bare:
            raise Fail("hold", "an item starts while the walk is still in S_ITEM (the guarded write was not taken)")

    def on_title_done(self):
        if self.exp[0] != 0:
            return                  # a refused image: [err] waits for err_code, as the RTL bench does
        if self.nbytes != self.ph_n * SEC and self.ph_cmp:
            raise Fail("done", "title_done with %d bytes streamed, want exactly %d (phase at %d)"
                       % (self.nbytes, self.ph_n * SEC, self.ph_off))

    def on_item_start(self):
        o = self.world.out
        idx = o.get("O_ITEM_IDX", 0)
        if idx < self.n_base and self.base_main:
            want = self.basew[1 + 2 * idx] | ((self.basew[2 + 2 * idx] & 0xFFFF) << 32)
            got = o.get("O_ITEM_BASE_LO", 0) | (o.get("O_ITEM_BASE_HI", 0) << 32)
            if got != want:
                raise Fail("base", "item %d starts with base %d, want %d" % (idx, got, want))
            self.base_chk += 1

    def on_nav_done(self):
        self.nav_done = True

    # -- the run ----------------------------------------------------------------------
    def run(self, words, labels, lat=4200, verbose=False, hw_mut=()):
        w = World(self, lat=lat, hw_mut=hw_mut)
        self.world = w
        eng = Engine(words, labels, w)
        self.eng = eng
        self.state = 0
        self.nav_done = False
        eng.restart()
        o = w.out
        err_exp = self.exp[0]

        def run_until(pred, what, arm):
            t0 = w.now
            while not pred():
                if w.now - t0 > LIM:
                    raise Fail(arm, "%s never happened (state %d, pc %d)" % (what, self.state, eng.pc))
                if o.get("O_ERR", 0) and err_exp == 0:
                    raise Fail("nav", "walk ended in err_code %d (state %d)" % (o["O_ERR"], self.state))
                if not eng.step():
                    # a wait on item_hold: it is re-drawn every instruction
                    t = (w.now + CPI) if eng.wait_mask & (1 << ST["ST_NOHOLD"]) else w.next_event()
                    if t is None:
                        if pred():
                            return
                        raise Fail(arm, "%s: the engine waits on nothing (state %d, pc %d)"
                                   % (what, self.state, eng.pc))
                    w.now = max(w.now + 1, int(t))
                w.advance(w.now)

        if err_exp != 0:
            run_until(lambda: o.get("O_ERR", 0) != 0, "a refusal", "err")
            if o["O_ERR"] != err_exp:
                raise Fail("err", "err_code %d, want %d (state %d)" % (o["O_ERR"], err_exp, self.state))
            for _ in range(200):
                if not eng.step():
                    break
            if self.nbytes or o.get("O_STREAMING", 0):
                raise Fail("err", "streamed %d bytes after refusing" % self.nbytes)
            if self.want_sniff:
                raise Fail("sniff", "a refusal before the sniff read sector 0")
            if o.get("O_NAV_READY", 0):
                raise Fail("err", "nav_ready after a refusal")
            return "refused with err_code %d after %d navigation reads" % (o["O_ERR"], self.nav_reads)

        run_until(lambda: self.state == S_ITEM or (self.bare and o.get("O_STREAMING", 0)),
                  "the playlist walk's end", "pick")
        self.check_pick_title()
        if self.n_base > 0:
            want = self.basew[1 + 2 * self.n_base] | (self.basew[2 + 2 * self.n_base] << 32)
            got = o.get("O_PL_DUR_LO", 0) | (o.get("O_PL_DUR_HI", 0) << 32)
            if got != want:
                raise Fail("base", "pl_dur %d, want %d" % (got, want))
        self.checked0 = False
        for c in range(self.n_cmd):
            self.run_cmd(c, run_until)
        self.finish_phase("stream", run_until)
        self.checks0()
        if self.n_base > 0 and self.base_chk == 0:
            raise Fail("base", "no item start was checked")
        return ("playlist %d/%d, %d item(s), phase 0 %d sectors, %d command(s), %d navigation "
                "reads (%d nav sectors), %d item bases, %d instructions, longest stretch "
                "between sector reads %d cycles"
                % (o.get("O_MAIN_PL", 0), o.get("O_N_PLAYLISTS", 0), o.get("O_N_ITEMS", 0),
                   self.n_sseq, self.n_cmd, self.nav_reads, self.nav_secs, self.base_chk,
                   eng.instr, eng.max_busy))

    def check_pick_title(self):
        o, e = self.world.out, self.exp
        if o.get("O_MAIN_PL", 0) != (e[1] & 0xFFFF) or o.get("O_N_PLAYLISTS", 0) != (e[2] & 0xFFFF):
            raise Fail("pick", "main playlist %d of %d, want %d of %d"
                       % (o.get("O_MAIN_PL", 0), o.get("O_N_PLAYLISTS", 0), e[1], e[2]))
        fl = o.get("O_FLAGS", 0)
        if o.get("O_BARE", 0) != self.meta[10] or bool(fl & FL_PMF_WARN) != bool(self.meta[11] & 1):
            raise Fail("bare", "mode %d pmf_warn %d, want %d %d"
                       % (o.get("O_BARE", 0), bool(fl & FL_PMF_WARN), self.meta[10], self.meta[11]))
        flags = (bool(fl & FL_TRUNC) << 1) | bool(fl & FL_SFO_WARN)
        if o.get("O_TITLE_LEN", 0) != (e[4] & 0xFF) or flags != (e[5] & 3):
            raise Fail("title", "title_len %d flags %d, want %d / %d"
                       % (o.get("O_TITLE_LEN", 0), flags, e[4], e[5]))
        for i in range(e[4]):
            if self.world.title[i] != self.tbytes[i]:
                raise Fail("title", "title byte %d is %02x, want %02x"
                           % (i, self.world.title[i], self.tbytes[i]))

    def check_tracks_clip(self):
        o, e, bare = self.world.out, self.exp, self.bare
        g = lambda k: o.get(k, 0)
        if g("O_AUD_PRESENT") != (e[6] & 0xFFFF) or g("O_SUB_PRESENT") != e[7] or (not bare and (
                g("O_N_STREAMS") != (e[8] & 0xFFFF) or g("O_N_VIDEO") != (e[9] & 0xFFFF) or
                g("O_N_UNKNOWN") != (e[10] & 0xFFFF) or g("O_VID_ATTR") != (e[11] & 0xFFFF))):
            raise Fail("tracks", "aud %04x sub %08x n %d video %d unknown %d attr %04x, want %04x %08x %d %d %d %04x"
                       % (g("O_AUD_PRESENT"), g("O_SUB_PRESENT"), g("O_N_STREAMS"), g("O_N_VIDEO"),
                          g("O_N_UNKNOWN"), g("O_VID_ATTR"), e[6], e[7], e[8], e[9], e[10], e[11]))
        for i in range(48):
            if self.langs[i] & 0x10000 and self.world.lang[i] != (self.langs[i] & 0xFFFF):
                raise Fail("tracks", "language %d is %04x, want %04x"
                           % (i, self.world.lang[i], self.langs[i] & 0xFFFF))
        p48 = lambda lo, hi: g(lo) | ((g(hi) & 0xFFFF) << 32)
        ok = (bare or (p48("O_CLIP_START_LO", "O_CLIP_START_HI") == (e[12] | ((e[13] & 0xFFFF) << 32)) and
                       p48("O_CLIP_END_LO", "O_CLIP_END_HI") == (e[14] | ((e[15] & 0xFFFF) << 32)) and
                       g("O_EP_MAP_OFF") == e[16]))
        ok = ok and p48("O_ITEM_IN_LO", "O_ITEM_IN_HI") == (e[17] | ((e[18] & 0xFFFF) << 32))
        ok = ok and p48("O_ITEM_OUT_LO", "O_ITEM_OUT_HI") == (e[19] | ((e[20] & 0xFFFF) << 32))
        ok = ok and g("O_N_ITEMS") == e[3] and g("O_MPS_LBA") == e[24] and g("O_MPS_BYTES") == e[25]
        ok = ok and g("O_ITEM_IDX") == (e[26] if g("O_STREAMING") else e[3])
        if not ok:
            raise Fail("clip", "pts %d..%d ep %d in/out %d..%d items %d mps %d+%d item %d"
                       % (p48("O_CLIP_START_LO", "O_CLIP_START_HI"), p48("O_CLIP_END_LO", "O_CLIP_END_HI"),
                          g("O_EP_MAP_OFF"), p48("O_ITEM_IN_LO", "O_ITEM_IN_HI"),
                          p48("O_ITEM_OUT_LO", "O_ITEM_OUT_HI"), g("O_N_ITEMS"), g("O_MPS_LBA"),
                          g("O_MPS_BYTES"), g("O_ITEM_IDX")))
        name = ((g("O_CLIP_NAME_HI") << 32) | g("O_CLIP_NAME_LO"))
        want = (e[21] << 32) | e[22]
        for i in range(e[23]):
            if (name >> (56 - 8 * i)) & 0xFF != (want >> (56 - 8 * i)) & 0xFF:
                raise Fail("clip", "clip name byte %d is %02x" % (i, (name >> (56 - 8 * i)) & 0xFF))

    def checks0(self):
        if not self.checked0:
            self.checked0 = True
            self.check_tracks_clip()
            if self.nav_reads > 3 * self.nav_secs + 8 * self.exp[3] + 8:
                raise Fail("thrash", "%d navigation reads for %d navigation sectors"
                           % (self.nav_reads, self.nav_secs))

    def finish_phase(self, arm, run_until):
        w = self.world
        run_until(lambda: self.nbytes >= self.ph_n * SEC, "the phase's bytes", arm)
        if self.ph_cmp:
            run_until(lambda: w.out.get("O_TITLE_DONE", 0), "title_done", "done")
            t_end = w.now + 2000 * 4
            run_until(lambda: w.now >= t_end or (w.next_event() is None and self.state in (38, 39)),
                      "the settle", "done")
            if self.nbytes != self.ph_n * SEC:
                raise Fail("done", "%d bytes streamed, want exactly %d (phase at %d)"
                           % (self.nbytes, self.ph_n * SEC, self.ph_off))

    def run_cmd(self, c, run_until):
        w, o = self.world, self.world.out
        cw = self.cmds[NAV_W * c:NAV_W * (c + 1)]
        op, wh = cw[0] & 0xFF, (cw[0] >> 8) & 0xFF
        arm = {1: "seek", 2: "chap", 3: "play", 4: "time"}.get(op, "op")
        if wh == 0:
            self.finish_phase(arm, run_until)
        elif wh == 2:
            run_until(lambda: self.nbytes >= (self.ph_n * SEC) // 2, "half the phase", arm)
        else:
            run_until(lambda: (self.nbytes >= SEC or self.nbytes >= self.ph_n * SEC) and
                      w.inflight is not None and o.get("O_STREAMING", 0) and o.get("O_NAV_READY", 0),
                      "a transfer in flight", "harness")
        self.checks0()
        pts = cw[2] | ((cw[3] & 0xFFFF) << 32)
        took = []
        w.take_hook = lambda op_, acc: took.append(acc)
        self.nav_phase = True
        w.req = (op, cw[27] & 0xFFFF, cw[1], pts)
        self.nav_done = False
        w._try_take()
        run_until(lambda: bool(took), "nav_ready", arm)
        w.take_hook = None
        nav0 = self.nav_reads
        if ((op in (1, 4)) and cw[4] != 1 and not self.bare) or (op == 3 and cw[31] & 1):
            if op == 3:
                self.base_main = (cw[27] == self.meta[5])
            self.ph_off, self.ph_n, self.ph_cmp = self.n_sseq + cw[12], cw[11], cw[13]
            self.nbytes = 0
            self.mreq = 0
            if o.get("O_TITLE_DONE", 0):
                raise Fail("done", "command %d: title_done still up after a seek was taken" % c)
        run_until(lambda: self.nav_done, "nav_done", arm)
        g = lambda k: o.get(k, 0)
        if g("O_NAV_ERR") != (cw[4] & 7):
            raise Fail(arm, "command %d: nav_err %d, want %d" % (c, g("O_NAV_ERR"), cw[4]))
        if op == 3 and cw[31] & 1:
            dur = g("O_PL_DUR_LO") | (g("O_PL_DUR_HI") << 32)
            if g("O_MAIN_PL") != (cw[27] & 0xFFFF) or g("O_N_ITEMS") != cw[28] or dur != (cw[29] | (cw[30] << 32)):
                raise Fail("play", "command %d: playlist %d, %d items, duration %d, want %d %d %d"
                           % (c, g("O_MAIN_PL"), g("O_N_ITEMS"), dur, cw[27], cw[28], cw[29] | (cw[30] << 32)))
            base = g("O_ITEM_BASE_LO") | ((g("O_ITEM_BASE_HI") & 0xFFFF) << 32)
            if cw[31] & 2 and base != (cw[14] | ((cw[15] & 0xFFFF) << 32)):
                raise Fail("play", "command %d: item_base %d, want %d" % (c, base, cw[14] | ((cw[15] & 0xFFFF) << 32)))
            if cw[31] & 2 and g("O_NAV_LAND") != cw[5]:
                raise Fail("play", "command %d: landed in item %d, want %d" % (c, g("O_NAV_LAND"), cw[5]))
        arm2 = "time" if op == 4 else "seek"
        if ((op in (1, 4)) and cw[4] != 1 and not self.bare) or (op == 3 and cw[31] & 2):
            skip = g("O_NAV_SKIP_LO") | ((g("O_NAV_SKIP_HI") & 0xFFFF) << 32)
            got = (g("O_NAV_LAND"), g("O_NAV_EP_IDX"), g("O_NAV_EP_PTS"), g("O_NAV_EP_SEC"), skip,
                   g("O_EP_FLAGS") & 7)
            want = (cw[5], cw[6], cw[7], cw[8], cw[9] | ((cw[10] & 0xFFFF) << 32), cw[26] & 7)
            if got != want:
                raise Fail(arm2, "command %d (%d, %d): landed item/entry/pts/sector/skip/flags %r, want %r"
                           % (c, cw[1], pts, got, want))
        if op == 2 and self.nav_reads - nav0 > self.pl_secs + 2:
            raise Fail("chap", "command %d: %d sector reads for a PLAYLIST.UMD of %d"
                       % (c, self.nav_reads - nav0, self.pl_secs))
        if op == 2 and cw[4] == 0:
            got = (g("O_CH_RANK") & 0xFFFF, g("O_CH_COUNT") & 0xFFFF, g("O_CH_VALID") & 7)
            want = (cw[14] & 0xFFFF, cw[15] & 0xFFFF, cw[16] & 7)
            if got != want:
                raise Fail("chap", "command %d (%d, %d): rank/count/valid %r, want %r" % (c, cw[1], pts, got, want))
            for bit, (lo, hi), (wi, wl, wh2) in ((1, ("O_CH_CUR_LO", "O_CH_CUR_HI"), (17, 18, 19)),
                                                (2, ("O_CH_PREV_LO", "O_CH_PREV_HI"), (20, 21, 22)),
                                                (4, ("O_CH_NEXT_LO", "O_CH_NEXT_HI"), (23, 24, 25))):
                k = ((cw[wi] & 0xFFFF) << 48) | ((cw[wh2] & 0xFFFF) << 32) | cw[wl]
                v = g(lo) | (g(hi) << 32)
                if g("O_CH_VALID") & bit and v != k:
                    raise Fail("chap", "command %d: key %x, want %x (valid bit %d)" % (c, v, k, bit))


# ---------------------------------------------------------------------------------- main

def load_program(path=UASM):
    words, labels, _lines = assemble(open(path).read())
    return words, labels


def write_svh(path):
    """umd/nav/nav_io.svh: the I/O map, the status bits and the pump commands for the RTL, from
    the tables above (the program and the hardware cannot disagree on them)."""
    lines = ["// umd/nav/nav_io.svh -- GENERATED by tools/nav_isa.py --svh: do not edit.",
             "// The navigation engine's I/O map (docs/nav_engine.md S7)."]
    for n in IO_IN + IO_OUT + ["O_TITLE_MEM", "O_LANG_MEM"]:
        lines.append("localparam [15:0] A_%s = 16'h%04X;" % (n, IO[n]))
    for n, b in sorted(ST.items(), key=lambda kv: kv[1]):
        lines.append("localparam integer %s = %d;" % (n, b))
    lines += ["localparam [2:0] PC_STREAM = 3'd%d, PC_PAUSE = 3'd%d, PC_RESUME = 3'd%d;"
              % (PC_STREAM, PC_PAUSE, PC_RESUME),
              "localparam [3:0] FL_SFO_WARN = 4'd%d, FL_TRUNC = 4'd%d, FL_DUR_SAT = 4'd%d, FL_PMF_WARN = 4'd%d;"
              % (FL_SFO_WARN, FL_TRUNC, FL_DUR_SAT, FL_PMF_WARN)]
    open(path, "w").write("\n".join(lines) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--asm", nargs="?", const=UASM)
    ap.add_argument("-o", default=None)
    ap.add_argument("--svh", nargs="?", const=os.path.join(REPO, "umd", "nav", "nav_io.svh"))
    ap.add_argument("--fixture", nargs="+")
    ap.add_argument("--uasm", default=UASM, help="the program to score (a --red mutant)")
    ap.add_argument("--hw-mut", action="append", default=[], choices=World.HW_MUTS,
                    help="a hardware mutation of the model (run_nav_model.sh --red)")
    ap.add_argument("--lat", type=int, default=4200, help="cycles an sd read (the bench's ~4,200; the rig's ~21,600)")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args(argv)
    if a.asm:
        words, labels, _ = assemble(open(a.asm).read())
        if a.o:
            with open(a.o, "w") as f:
                for w in words:
                    f.write("%010x\n" % w)
        print("%s: %d words" % (a.asm, len(words)))
    if a.svh:
        write_svh(a.svh)
        print("%s written" % a.svh)
    if a.fixture:
        words, labels = load_program(a.uasm)
        bad = 0
        for stem in a.fixture:
            fx = Fixture(stem)
            try:
                msg = fx.run(words, labels, lat=a.lat, verbose=a.v, hw_mut=a.hw_mut)
                print("PASS %s: %s" % (os.path.basename(stem), msg))
            except Fail as e:
                bad += 1
                print("%s: %s" % (os.path.basename(stem), e))
            except RuntimeError as e:
                bad += 1
                print("FAIL [engine] %s: %s" % (os.path.basename(stem), e))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
