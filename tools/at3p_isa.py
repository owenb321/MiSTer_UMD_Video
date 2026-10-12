#!/usr/bin/env python3
"""The ATRAC3plus decoder's sequencer: its ISA, the assembler, and an instruction-level
emulator (docs/at3p_decoder.md S3.4).

The fabric decoder is a microcoded sequencer (parse + synthesis control) driving
hardwired vector loops on one 27x27 multiplier. This file is the executable
definition of that machine: the RTL (umd/at3p/at3p_seq.sv and the vector engines)
must match the emulator instruction by instruction (register writes, PC) and word by
word (buffers, PCM).

Word: 40 bits = op[39:34] rd[33:30] rs[29:26] rt[25:22] imm[21:6] aux[5:0].
Registers r0..r15, 16 bits, two's complement; r0 reads 0. r8..r15 carry vector-op args.

  alu   rd, rs, rt        rd = rs FN rt            (FN in aux)
  alui  rd, rs, imm       rd = rs FN sext16(imm)
  ld    rd, imm[rs+rt]    rd = MEM[(rs + rt + imm) & 0x3FFF]
  st    rd, imm[rs+rt]    MEM[...] = rd
  get   rd, n             rd = the next n bits (n = imm, 0..16), MSB first
  getr  rd, rt            rd = the next rt bits
  vlc   rd, imm[rs]       rd = Huffman symbol from codebook rs + imm (a hole: E_VLC_HOLE)
  b<c>  rs, rt, label     branch if rs <c> rt; c in eq ne lt ge (signed)
  b<c>i rs, k, label      ... against a signed 10-bit constant k = {rt, aux}
  jmp / call label, ret   (call stack depth 8)
  err   code              count the error, mute the frame, restart at the ERROR vector
  vop   op                a vector op, args in r8..r15, blocks until done
  bleft rd                rd = bits left in the frame (saturated to 32767)
  frame rs                start a frame of rs bytes (bits past it read 0 and count)
  fend                    discard the rest of the frame
  mark  imm               no-op for the RTL; the emulator and benches snapshot here

Memory (16-bit words): 0x0000-0x07FF the record RAM; 0x1000-0x1FFF the constant ROM;
0x2000-0x2FFF the quantised spectrum (6-bit, ch x 2048 + line); 0x3000-0x30FF the gain
exponent table the IMDCT reads (8-bit: E1 then E2).

    at3p_isa.py --asm umd/at3p/at3p.uasm [-o umd/at3p/at3p_ucode.mem] [--check]
    at3p_isa.py --disc IMAGE.iso [--clip N] [--skip N] [--aus N]   # emulate vs the models
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_tables as T  # noqa: E402
import at3p_fixed as F  # noqa: E402

REPO = os.path.dirname(HERE)
UASM = os.path.join(REPO, "umd", "at3p", "at3p.uasm")
UMEM = os.path.join(REPO, "umd", "at3p", "at3p_ucode.mem")
CMEM = os.path.join(REPO, "umd", "at3p", "at3p_const.mem")

OPS = ["nop", "alu", "alui", "ld", "st", "get", "getr", "vlc", "br", "bri", "jmp", "call",
       "ret", "err", "vop", "bleft", "frame", "fend", "mark"]
OP = {n: i for i, n in enumerate(OPS)}
FNS = ["add", "sub", "and", "or", "xor", "shl", "sar", "shr", "slt", "sltu", "seq", "sne",
       "min", "max", "sext", "log2", "abs"]
FN = {n: i for i, n in enumerate(FNS)}
CONDS = ["eq", "ne", "lt", "ge"]
VOPS = ["dq", "nz", "xclr", "xnorm", "imdct", "tzero", "rclr", "wave", "rsat", "rwin",
        "rzero", "addt", "ipqf", "pcmz"]
VOP = {n: i for i, n in enumerate(VOPS)}

MEM_REC, MEM_CONST, MEM_SPEC, MEM_E = 0x0000, 0x1000, 0x2000, 0x3000
E_VLC_HOLE = 18           # a Huffman code in no codebook: the frame is refused
STACK_DEPTH = 8


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def encode(op, rd=0, rs=0, rt=0, imm=0, aux=0):
    return (OP[op] << 34) | ((rd & 15) << 30) | ((rs & 15) << 26) | ((rt & 15) << 22) | \
        ((imm & 0xFFFF) << 6) | (aux & 63)


def decode(w):
    return (OPS[(w >> 34) & 63], (w >> 30) & 15, (w >> 26) & 15, (w >> 22) & 15,
            (w >> 6) & 0xFFFF, w & 63)


# ------------------------------------------------------------------- constant ROM

def build_const():
    """The constant ROM: the parse's small tables, one 16-bit word each. Returns
    (words, {name: base}); the .uasm refers to them by name (C_<NAME>)."""
    words, base = [], {}

    def put(name, vals):
        base[name] = MEM_CONST + len(words)
        words.extend(v & 0xFFFF for v in vals)

    put("WL_WEIGHTS", [v for row in T.WL_WEIGHTS for v in row])          # [6][32]
    put("SF_WEIGHTS", [v for row in T.SF_WEIGHTS for v in row])          # [2][32]
    put("QU_NUM_TO_SEG", T.QU_NUM_TO_SEG)
    put("QU_TO_SUBBAND", T.QU_TO_SUBBAND)
    put("SB_NUM_POWGRPS", T.SUBBAND_TO_NUM_POWGRPS)
    put("WL_SHAPES", [v for a in T.WL_SHAPES for b in a for v in b])     # [8][16][9]
    put("SF_SHAPES", [v for a in T.SF_SHAPES for v in a])                # [64][9]
    put("CT_R2F", [v for a in T.CT_RESTRICTED_TO_FULL for b in a for v in b])   # [2][7][4]
    put("SPEC_TABS", [g | (n << 4) | (b << 8) | (s << 12) for g, n, b, s in T.SPECTRA_TABS])
    put("QU_TO_SPEC_POS", T.QU_TO_SPEC_POS)
    put("SB_TO_POWGRP", T.SUBBAND_TO_POWGRP)
    put("SB_TO_QU", T.SUBBAND_TO_QU)
    return words, base


CONST, CBASE = build_const()


# VLC codebook ids (the hardware's header ROM; the spectrum aliases resolved)
VLC_WL, VLC_CT, VLC_SF, VLC_GAIN, VLC_TONE, VLC_SPEC = 0, 4, 8, 16, 27, 34
VLC_TABLES = (R.VLC["wl"] + R.VLC["ct"] + R.VLC["sf"] + R.VLC["gain"] + R.VLC["tone"]
              + R.VLC["spec"])
assert len(VLC_TABLES) == 146


# --------------------------------------------------------------------- assembler

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
    """-> (words, labels, lines). Two passes; .equ constants, .reg aliases, labels."""
    equ = {"C_" + k: v for k, v in CBASE.items()}
    equ.update({"VLC_WL": VLC_WL, "VLC_CT": VLC_CT, "VLC_SF": VLC_SF, "VLC_GAIN": VLC_GAIN,
                "VLC_TONE": VLC_TONE, "VLC_SPEC": VLC_SPEC, "MEM_SPEC": MEM_SPEC,
                "MEM_E": MEM_E})
    aliases = {}
    labels = {}
    stmts = []
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
            labels[m.group(1)] = len(stmts)
            line = m.group(2).strip()
        if not line:
            continue
        if line.startswith(".equ"):
            _, name, val = line.split(None, 2)
            try:
                equ[name] = int(eval(val, {"__builtins__": {}}, dict(equ)))
            except Exception as e:
                raise AsmError("line %d: .equ %s = %r (%s)" % (ln, name, val, e))
            continue
        if line.startswith(".reg"):
            _, name, reg = line.split(None, 2)
            aliases[name.lower()] = reg.strip().lower()
            continue
        stmts.append((ln, line, dict(aliases)))

    def ev(expr, ln):
        env = dict(equ)
        env.update(labels)
        try:
            return int(eval(expr, {"__builtins__": {}}, env))
        except Exception as e:
            raise AsmError("line %d: cannot evaluate %r (%s)" % (ln, expr, e))

    words = []
    for ln, line, al in stmts:
        m = re.match(r"(\w+)\s*(.*)$", line)
        mn, rest = m.group(1).lower(), m.group(2)
        args = [a.strip() for a in re.split(r",(?![^\[]*\])", rest)] if rest else []

        def reg(i):
            return _regnum(args[i], al)

        def memref(s):
            """imm[ra+rb] | imm[ra] | imm | [ra]"""
            m2 = re.fullmatch(r"(.*?)\s*\[([^\]]*)\]", s)
            if not m2:
                return ev(s, ln), 0, 0
            imm = ev(m2.group(1), ln) if m2.group(1).strip() else 0
            rr = [r.strip() for r in m2.group(2).split("+")]
            ra = _regnum(rr[0], al) if rr and rr[0] else 0
            rb = _regnum(rr[1], al) if len(rr) > 1 else 0
            return imm, ra, rb
        try:
            if mn in FN and mn not in ("log2", "abs", "sext"):
                if re.fullmatch(r"r\d+", al.get(args[2].strip().lower(), args[2].strip().lower())):
                    words.append(encode("alu", reg(0), reg(1), reg(2), 0, FN[mn]))
                else:                               # a constant: the immediate form
                    words.append(encode("alui", reg(0), reg(1), 0, ev(args[2], ln), FN[mn]))
            elif mn.endswith("i") and mn[:-1] in FN and mn[:-1] not in ("log2", "abs"):
                words.append(encode("alui", reg(0), reg(1), 0, ev(args[2], ln), FN[mn[:-1]]))
            elif mn == "sext":
                words.append(encode("alui", reg(0), reg(1), 0, ev(args[2], ln), FN["sext"]))
            elif mn == "sextr":
                words.append(encode("alu", reg(0), reg(1), reg(2), 0, FN["sext"]))
            elif mn in ("log2", "abs"):
                words.append(encode("alu", reg(0), reg(1), 0, 0, FN[mn]))
            elif mn == "li":
                words.append(encode("alui", reg(0), 0, 0, ev(args[1], ln), FN["add"]))
            elif mn == "mov":
                words.append(encode("alu", reg(0), reg(1), 0, 0, FN["add"]))
            elif mn in ("ld", "st"):
                imm, ra, rb = memref(args[1])
                words.append(encode(mn, reg(0), ra, rb, imm))
            elif mn == "get":
                words.append(encode("get", reg(0), 0, 0, ev(args[1], ln)))
            elif mn == "getr":
                words.append(encode("getr", reg(0), 0, reg(1)))
            elif mn == "vlc":
                imm, ra, _rb = memref(args[1])
                words.append(encode("vlc", reg(0), ra, 0, imm))
            elif mn[:1] == "b" and mn[1:3] in CONDS and len(mn) == 3:
                words.append(encode("br", CONDS.index(mn[1:3]), reg(0), reg(1), ev(args[2], ln)))
            elif mn[:1] == "b" and mn[1:3] in CONDS and mn[3:] == "i":
                c = ev(args[1], ln)
                if not -512 <= c <= 511:
                    raise AsmError("line %d: branch constant %d outside -512..511" % (ln, c))
                c &= 0x3FF
                words.append(encode("bri", CONDS.index(mn[1:3]), reg(0), c >> 6, ev(args[2], ln),
                                    c & 63))
            elif mn in ("jmp", "call"):
                words.append(encode(mn, 0, 0, 0, ev(args[0], ln)))
            elif mn in ("ret", "fend", "nop"):
                words.append(encode(mn))
            elif mn in ("err", "mark"):
                words.append(encode(mn, 0, 0, 0, ev(args[0], ln)))
            elif mn == "vop":
                words.append(encode("vop", 0, 0, 0, VOP[args[0].lower()]))
            elif mn == "bleft":
                words.append(encode("bleft", reg(0)))
            elif mn == "frame":
                words.append(encode("frame", 0, reg(0)))
            else:
                raise AsmError("line %d: unknown instruction %r" % (ln, mn))
        except (IndexError, KeyError) as e:
            raise AsmError("line %d: bad operands for %r (%s)" % (ln, line, e))
        except AsmError as e:
            if "line" in str(e):
                raise
            raise AsmError("line %d: %s in %r" % (ln, e, line))
    lines = [ln for ln, _l, _a in stmts]
    return words, labels, lines


# ---------------------------------------------------------------------- emulator

class NeedInput(Exception):
    pass


class Machine:
    """The sequencer and its vector engines. feed(bytes) then run(): runs until the
    input is exhausted inside a GET; PCM stereo frames land in self.pcm (a list of
    (2, 2048) int arrays), snapshots at `mark` in self.marks."""

    def __init__(self, words, labels, fast=False):
        self.fast = fast        # parse-only: vector ops cost their cycles, compute nothing
        self.prog = words
        self.labels = labels
        self.reg = [0] * 16
        self.pc = labels.get("RESET", 0)
        self.stack = []
        self.rec = [0] * 0x800
        self.spec = [0] * 4096
        self.etab = [0] * 256
        # bit reader
        self.inbuf = bytearray()
        self.inpos = 0
        self.acc = 0          # bit accumulator
        self.nacc = 0
        self.in_frame = False
        self.frame_bytes = 0
        self.frame_taken = 0  # bytes of the frame pulled from the input
        self.frame_bits = 0   # bits of the frame consumed
        self.overrun = 0
        # vector state
        self.X = [0] * 128
        self.Xn = [0] * 128
        self.xs = 0
        self.TB = [0] * 2048
        self.P = [[0] * 2048 for _ in range(2)]
        self.reg_buf = [[0] * 128 for _ in range(2)]
        self.fu = F.FixedUnit()
        self.pcm0 = [0] * 2048
        self.pcm = []
        self.sat = F.Sat()
        self.errors = {}
        self.cycles = 0
        self.marks = []
        self.mark_hook = None
        self.vop_hook = None
        self.trace = None

    # -- the bit reader -------------------------------------------------------
    def feed(self, data):
        self.inbuf += data

    def _pull(self):
        """One more byte into the accumulator: the input, or zeros past the frame."""
        if self.in_frame and self.frame_taken >= self.frame_bytes:
            self.acc = (self.acc << 8)
            self.nacc += 8
            return
        if self.inpos >= len(self.inbuf):
            raise NeedInput()
        self.acc = (self.acc << 8) | self.inbuf[self.inpos]
        self.inpos += 1
        self.nacc += 8
        if self.in_frame:
            self.frame_taken += 1

    def peek(self, n):
        while self.nacc < n:
            self._pull()
        return (self.acc >> (self.nacc - n)) & ((1 << n) - 1) if n else 0

    def skip(self, n):
        self.nacc -= n
        self.acc &= (1 << self.nacc) - 1
        if self.in_frame:
            self.frame_bits += n
            if self.frame_bits > self.frame_bytes * 8:
                self.overrun = max(self.overrun, self.frame_bits - self.frame_bytes * 8)

    def getbits(self, n):
        v = self.peek(n)
        self.skip(n)
        self.cycles += 1 + n // 8
        return v

    def vlc(self, tid):
        """The fabric's decoder walks the code lengths one bit at a time and consumes as
        it goes (docs/at3p_decoder.md S3.2): a code that is in no codebook (a hole, only
        in a corrupt stream) cannot be un-read, so the frame is REFUSED (E_VLC_HOLE)
        where ffmpeg returns -1 and reads on. Returns None for a hole."""
        v = VLC_TABLES[tid]
        idx = self.peek(v.max_len)
        s, ln = v.table[idx]
        self.cycles += 2 * (ln if ln else 12) + 2
        if ln == 0:
            v.holes += 1
            return None
        self.skip(ln)
        return s

    # -- memory -----------------------------------------------------------------
    def load(self, a):
        a &= 0x3FFF
        if a < 0x800:
            return s16(self.rec[a])
        if MEM_CONST <= a < MEM_CONST + len(CONST):
            return s16(CONST[a - MEM_CONST])
        # the spectrum and the exponent table are write-only for the program (their one
        # read port is the vector engines'); a load there is a program bug
        raise RuntimeError("load from 0x%04x at pc %d (unmapped or write-only)" % (a, self.pc))

    def store(self, a, v):
        a &= 0x3FFF
        if a < 0x800:
            self.rec[a] = v & 0xFFFF
        elif MEM_SPEC <= a < MEM_SPEC + 4096:
            self.spec[a - MEM_SPEC] = R.sign_extend(v, 6)
        elif MEM_E <= a < MEM_E + 256:
            self.etab[a - MEM_E] = R.sign_extend(v, 8)
        else:
            raise RuntimeError("store to 0x%04x at pc %d" % (a, self.pc))

    # -- the ALU ---------------------------------------------------------------------
    @staticmethod
    def alu(fn, a, b):
        f = FNS[fn]
        if f == "add":
            r = a + b
        elif f == "sub":
            r = a - b
        elif f == "and":
            r = a & b
        elif f == "or":
            r = a | b
        elif f == "xor":
            r = a ^ b
        elif f == "shl":
            r = a << (b & 15)
        elif f == "sar":
            r = a >> (b & 15)
        elif f == "shr":
            r = (a & 0xFFFF) >> (b & 15)
        elif f == "slt":
            r = int(a < b)
        elif f == "sltu":
            r = int((a & 0xFFFF) < (b & 0xFFFF))
        elif f == "seq":
            r = int(a == b)
        elif f == "sne":
            r = int(a != b)
        elif f == "min":
            r = min(a, b)
        elif f == "max":
            r = max(a, b)
        elif f == "sext":
            r = R.sign_extend(a, b) if b else 0
        elif f == "log2":
            r = R.av_log2(a & 0xFFFF)
        elif f == "abs":
            r = abs(a)
        return s16(r)

    # -- vector ops ------------------------------------------------------------------
    def vop(self, k):
        self._vop(k)
        if self.vop_hook:
            self.vop_hook(self, k)

    def checksums(self):
        """The engine buffers' checksums after a vector op (the RTL bench computes the
        same over its M10Ks): sum (i + 1) (v mod 2^width), mod 2^32."""
        def ck(vals, w):
            m = (1 << w) - 1
            return sum((i + 1) * (v & m) for i, v in enumerate(vals)) & 0xFFFFFFFF
        return (ck(self.X, 40), ck(self.TB, 24), ck(self.P[0] + self.P[1], 24),
                ck(self.reg_buf[0] + self.reg_buf[1], 27))

    def _vop(self, k):
        r = self.reg
        name = VOPS[k]
        if self.fast:
            if name in ("ipqf", "pcmz") and (name == "pcmz" or r[8] == 1):
                self.pcm.append(None)
            return
        if name == "dq":            # r8 spec addr, r9 count, r10 dest, r11 wl, r12 sf
            wl, sf = r[11], r[12]
            qm = F.rsr(F.MANT_Q19[wl] * F.SF_M[sf], 9)
            sh = F.SF_E[sf] + 10 - F.FXW
            for i in range(r[9]):
                self.X[r[10] + i] = self.sat(F.rsr(self.spec[r[8] + i] * qm, sh), F.WXW, "X")
            self.cycles += 2 + r[9]
        elif name == "nz":          # r8 rng, r9 count, r10 dest, r11 wl, r12 sf, r13 lev, r14 gcv
            wl, sf = r[11], r[12]
            qm = F.rsr(F.MANT_Q19[wl] * F.SF_M[sf], 9)
            qn = F.rsr(qm * F.PWC_Q5[r[13]], 7)
            sh = 15 + 8 + F.SF_E[sf] + wl + r[14] - F.FXW
            for i in range(r[9]):
                self.X[r[10] + i] = self.sat(
                    self.X[r[10] + i] + F.rsr(F.NOISE_Q15[(r[8] + i) & 0x3FF] * qn, sh),
                    F.WXW, "X")
            self.cycles += 3 + r[9]
        elif name == "xclr":
            self.X = [0] * 128
            self.cycles += 128
        elif name == "xnorm":       # r8 negate
            neg = r[8]
            X = [self.sat(-x if neg else x, F.WXW, "X") for x in self.X]
            self.Xn, self.xs = F.normalize(X)
            self.X = list(self.Xn)              # in place, as the RTL's buffer
            self.cycles += 2 * 128
        elif name == "imdct":       # r8 sb, r9 wind_id, r10 time offset, r11 overlap (ch)
            ch, off = r[11], r[10]
            E1, E2 = self.etab[:128], self.etab[128:]
            out, pn = _imdct_gain_norm(self.Xn, self.xs, r[9], r[8], self.P[ch][off:off + 128],
                                       E1, E2, self.sat)
            self.TB[off:off + 128] = out
            self.P[ch][off:off + 128] = pn
            self.cycles += 128 * 128 + 3 * 256 + 16
        elif name == "tzero":       # r8 time offset, r9 ch, r10 count
            for i in range(r[10]):
                self.TB[r[8] + i] = 0
                self.P[r[9]][r[8] + i] = 0
            self.cycles += r[10]
        elif name == "rclr":        # r8 region
            self.reg_buf[r[8]] = [0] * 128
            self.cycles += 128
        elif name == "wave":        # r8 region, r9 freq, r10 phase, r11 amp_sf, r12 reg_offset
            buf = self.reg_buf[r[8]]
            f = r[9]
            pos = (((r[10] & 0x1F) << 6) - (r[12] ^ 128) * f) & 2047
            amp = F.AMPQ[r[11]]
            for i in range(128):
                buf[i] = self.sat(buf[i] + F.rsr(F.sinq(pos) * amp, F.CB + F.AB - F.FT), 27,
                                  "tone")
                pos = (pos + f) & 2047
            self.cycles += 2 + 128
        elif name == "rsat":        # r8 region, r9 invert
            b = [self.sat(v, F.WT, "tone") for v in self.reg_buf[r[8]]]
            if r[9]:
                b = [self.sat(-v, F.WT, "tone") for v in b]
            self.reg_buf[r[8]] = b
            self.cycles += 128
        elif name == "rwin":        # r8 region, r9 i0, r10 count, r11 hann base, r12 step
            b = self.reg_buf[r[8]]
            for kk in range(r[10]):
                b[r[9] + kk] = F.rsr(b[r[9] + kk] * F.HANNQ[r[11] + r[12] * kk], F.CB)
            self.cycles += 2 + r[10]
        elif name == "rzero":       # r8 region, r9 i0, r10 count
            b = self.reg_buf[r[8]]
            for kk in range(r[10]):
                b[r[9] + kk] = 0
            self.cycles += r[10]
        elif name == "addt":        # r8 time offset
            off = r[8]
            for i in range(128):
                self.TB[off + i] = self.sat(self.TB[off + i] + self.reg_buf[0][i] +
                                            self.reg_buf[1][i], F.WT, "tone_add")
            self.cycles += 128
        elif name == "ipqf":        # r8 ch
            out = F.ipqf_fx(self.fu, r[8], self.TB, self.sat)
            if r[8] == 0:
                self.pcm0 = out
            else:
                self.pcm.append((self.pcm0, out))
            self.cycles += 128 * (256 + 384 + 8)
        elif name == "pcmz":
            self.pcm.append(([0] * 2048, [0] * 2048))
            self.cycles += 2048
        else:
            raise RuntimeError("vop %d" % k)

    # -- the sequencer ---------------------------------------------------------------
    def step(self):
        w = self.prog[self.pc]
        op, rd, rs, rt, imm, aux = decode(w)
        r = self.reg
        npc = self.pc + 1
        wr = None
        if op == "alu":
            wr = self.alu(aux, r[rs], r[rt])
        elif op == "alui":
            wr = self.alu(aux, r[rs], s16(imm))
        elif op == "ld":
            wr = self.load(r[rs] + r[rt] + imm)
            self.cycles += 1
        elif op == "st":
            a = (r[rs] + r[rt] + imm) & 0x3FFF
            self.store(a, r[rd])
            if self.trace is not None:
                self.trace.append((self.pc, 1, a, r[rd] & 0xFFFF))
        elif op == "get":
            wr = self.getbits(imm)
        elif op == "getr":
            n = r[rt]
            if not 0 <= n <= 16:
                raise RuntimeError("getr %d bits at pc %d" % (n, self.pc))
            wr = self.getbits(n)
        elif op == "vlc":
            wr = self.vlc(r[rs] + s16(imm))
            if wr is None:
                self.errors[E_VLC_HOLE] = self.errors.get(E_VLC_HOLE, 0) + 1
                self.stack = []
                npc = self.labels["ERROR"]
        elif op in ("br", "bri"):
            a = r[rs]
            b = r[rt] if op == "br" else R.sign_extend((rt << 6) | aux, 10)
            c = CONDS[rd]
            if (c == "eq" and a == b) or (c == "ne" and a != b) or (c == "lt" and a < b) or \
                    (c == "ge" and a >= b):
                npc = imm
                self.cycles += 1
        elif op == "jmp":
            npc = imm
        elif op == "call":
            if len(self.stack) >= STACK_DEPTH:
                raise RuntimeError("call stack overflow at pc %d" % self.pc)
            self.stack.append(npc)
            npc = imm
        elif op == "ret":
            npc = self.stack.pop()
        elif op == "err":
            self.errors[imm] = self.errors.get(imm, 0) + 1
            self.stack = []
            npc = self.labels["ERROR"]
        elif op == "vop":
            self.vop(imm)
        elif op == "bleft":
            left = self.frame_bytes * 8 - self.frame_bits if self.in_frame else 0
            wr = max(0, min(left, 32767))
        elif op == "frame":
            self.in_frame = True
            self.frame_bytes = r[rs] & 0xFFFF
            self.frame_taken = 0
            self.frame_bits = 0
            self.overrun = 0
            assert self.nacc == 0, "frame starts with bits buffered"
        elif op == "fend":
            left = self.frame_bytes - self.frame_taken
            self.in_frame = False
            self.acc = self.nacc = 0
            for _ in range(left):
                if self.inpos >= len(self.inbuf):
                    raise NeedInput()
                self.inpos += 1
            self.cycles += left
        elif op == "mark":
            self.marks.append(imm)
            if self.mark_hook:
                self.mark_hook(self, imm)
        if wr is not None and rd:
            r[rd] = wr
            if self.trace is not None:
                self.trace.append((self.pc, 0, rd, wr & 0xFFFF))
        self.cycles += 1
        self.pc = npc

    def run(self, max_steps=None):
        n = 0
        while max_steps is None or n < max_steps:
            save = (self.pc, list(self.reg), self.inpos, self.acc, self.nacc, self.frame_taken,
                    self.frame_bits)
            try:
                self.step()
            except NeedInput:
                (self.pc, self.reg, self.inpos, self.acc, self.nacc, self.frame_taken,
                 self.frame_bits) = save
                self.reg = list(self.reg)
                return "need_input"
            n += 1
        return "steps"


def _imdct_gain_norm(Xn, s, wind_id, sb, P, E1, E2, sat):
    """at3p_fixed.imdct_gain_fx after its normalize() (the engine gets X27 and s)."""
    X = Xn[::-1] if sb & 1 else Xn
    h = [0] * 128
    for i in range(128):
        n = 64 + i
        acc = 0
        for k in range(128):
            if X[k]:
                acc += X[k] * F.cosq(F.imdct_m(n, k))
        h[i] = sat(F.rsr(acc, F.CB + F.FXW - s - 20), 40, "imdct")
    y = [0] * 256
    for i in range(64):
        y[i] = -h[63 - i]
        y[255 - i] = h[64 + i]
    y[64:192] = h
    w = F.window(wind_id)
    v = [0] * 256
    for n in range(256):
        if not w[n]:
            continue
        e = E1[n] if n < 128 else E2[n - 128]
        M = F.rsr(w[n] * F.F4[e & 3], F.CB)
        v[n] = F.rsr(y[n] * M, 20 + F.CB - F.FT - (e >> 2))
    out = [sat(v[i] + P[i], F.WT, "gain") for i in range(128)]
    return out, [sat(v[128 + i], F.WT, "overlap") for i in range(128)]


def read_source(path):
    """The program text with `.include "file"` expanded (relative to the including file)."""
    out = []
    with open(path) as f:
        for line in f:
            m = re.match(r'\s*\.include\s+"([^"]+)"', line)
            if m:
                out.append(read_source(os.path.join(os.path.dirname(path), m.group(1))))
            else:
                out.append(line)
    return "".join(out)


def load_program(path=UASM):
    return assemble(read_source(path))


def vlc_roms():
    """The Huffman unit's ROMs: HDR[table] = the codebook's first symbol in SYM;
    CNT[table * 16 + len] = the number of codes of length len (1..12); SYM = the symbols
    in code order. The spectrum tables' aliases share their base codebook's entries."""
    hdr, cnt, sym = [], [0] * (len(VLC_TABLES) * 16), []
    seen = {}
    for t, v in enumerate(VLC_TABLES):
        if id(v) not in seen:
            seen[id(v)] = len(sym)
            sym.extend(v.syms)
        hdr.append(seen[id(v)])
        for ln in v.lens:
            cnt[t * 16 + ln] += 1
    return hdr, cnt, sym


def vec_roms():
    """The vector engines' ROMs (tools/at3p_fixed.py's constants, exactly)."""
    ipqf = [0] * 512                          # {c2, t, i}: c1 at t*16+i, c2 at 256 + t*16+i
    for t in range(12):
        for i in range(16):
            ipqf[t * 16 + i] = F.IPQF1_Q[t][i] & ((1 << 27) - 1)
            ipqf[256 + t * 16 + i] = F.IPQF2_Q[t][i] & ((1 << 27) - 1)
    return {
        "at3p_cos.mem": (F.COSQ, 26),
        "at3p_noise.mem": ([v & 0xFFFF for v in F.NOISE_Q15], 16),
        "at3p_ipqf.mem": (ipqf, 27),
        "at3p_amp.mem": (F.AMPQ, 26),
        "at3p_mant.mem": (F.MANT_Q19, 19),
        "at3p_sfm.mem": (list(F.SF_M), 16),
        "at3p_sfe.mem": (list(F.SF_E), 5),
        "at3p_pwc.mem": (F.PWC_Q5, 7),
        "at3p_f4.mem": (F.F4, 27),
    }


def ucode_svh(words, labels):
    return ("// umd/at3p/at3p_ucode.svh -- generated by tools/at3p_isa.py --asm; do not edit.\n"
            "localparam int UC_WORDS = %d;\n"
            "localparam logic [11:0] UC_RESET = 12'd%d;\n"
            "localparam logic [11:0] UC_ERROR = 12'd%d;\n"
            "localparam int VLC_SYMS = %d;\n"
            "localparam int CONST_WORDS = %d;\n" % (
                len(words), labels.get("RESET", 0), labels["ERROR"], len(vlc_roms()[2]),
                len(CONST)))


def mem_text(words, width):
    digits = (width + 3) // 4
    return "".join("%0*x\n" % (digits, w) for w in words)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--asm", nargs="?", const=UASM)
    ap.add_argument("-o", "--out", default=UMEM)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--disc")
    ap.add_argument("--clip", type=int)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--aus", type=int, default=8)
    a = ap.parse_args(argv)
    if a.asm:
        words, labels, _ = load_program(a.asm)
        hdr, cnt, sym = vlc_roms()
        d = os.path.dirname(a.out)
        texts = {a.out: mem_text(words, 40), CMEM: mem_text(CONST, 16),
                 os.path.join(d, "at3p_vlc_hdr.mem"): mem_text(hdr, 14),
                 os.path.join(d, "at3p_vlc_cnt.mem"): mem_text(cnt, 9),
                 os.path.join(d, "at3p_vlc_sym.mem"): mem_text(sym, 8),
                 os.path.join(d, "at3p_ucode.svh"): ucode_svh(words, labels)}
        for name, (vals, width) in vec_roms().items():
            texts[os.path.join(d, name)] = mem_text(vals, width)
        if a.check:
            bad = [p for p, t in texts.items() if not os.path.exists(p) or open(p).read() != t]
            print("at3p_isa: %s" % ("FAIL stale: " + " ".join(bad) if bad else
                                    "PASS (%d words, %d const)" % (len(words), len(CONST))))
            return 1 if bad else 0
        for p, t in texts.items():
            with open(p, "w") as f:
                f.write(t)
        print("at3p_isa: %d words -> %s; %d const words -> %s" % (len(words), a.out,
                                                                   len(CONST), CMEM))
    return 0


if __name__ == "__main__":
    sys.exit(main())
