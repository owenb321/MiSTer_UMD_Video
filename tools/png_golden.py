#!/usr/bin/env python3
"""Fixtures for bench/umd/png_tb.sv (umd/png/png_top.sv): synthetic PNGs that reach
every PNG / DEFLATE feature, the invalid cases with their expected verdicts, and the
subtitle corpus -- with goldens from independent decoders (docs/png_decode.md §5).

ORACLES (never a model written for this RTL):
  * zlib (zlib.decompress) -- the inflated bytes, and the verdict on every DEFLATE case;
  * libpng (tools/png_oracle.c, compiled into .sim/) -- the pixels of every case at
    16-bit precision, and the verdict on every PNG-level case;
  * PIL -- cross-check of libpng where PIL is right (<= 8 bits; not a grey tRNS key
    below 8 bits), and the source of palette INDICES for the unfiltered-row arm;
  * ffmpeg -- cross-check of libpng on the 16-bit types.
The generator FAILS on any disagreement outside the documented PIL/ffmpeg gaps
(measured 2026-09-25, png_oracle.c's header).

tools/inflate_ref.py (a puff port) is NOT an oracle: it counts coverage -- events whose
mis-handling would change the output -- and the generator requires every named
coverage item to be reached by some case.

Fixture per case (bench/umd/README.md conventions, one hex word per line):
  <stem>.hex        the PNG bytes (in_last on the last one)
  <stem>.inf.hex    zlib's inflated bytes (the inflate tap)          [valid cases]
  <stem>.raw.hex    unfiltered row bytes, pass by pass (the unfilter tap)
  <stem>.rmask.hex  per raw byte, the bits the oracle defines (row padding bits: 0)
  <stem>.pix.hex    {x16, y16, r8, g8, b8, a8} in emission order (Adam7: pass order)
  <stem>.meta.hex   err, warn, w, h, ctype, depth, interlace, n_in, n_inf, n_raw,
                    n_pix, check_data
and <out>/<list>.txt: one stem per line, in order.

    png_golden.py --out DIR [--list NAME] [--corpus CACHE --corpus-sel sample|all]
                  [--only REGEX] [--no-synth]
"""
import argparse
import binascii
import heapq
import io
import json
import os
import random
import re
import struct
import subprocess
import sys
import zlib
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import inflate_ref  # noqa: E402

# ---- error / warning codes: MUST equal umd/png/png_pkg.svh ------------------------------
E = dict(OK=0, SIG=1, CRC=2, IHDR=3, SIZE=4, CRITICAL=5, ORDER=6, PLTE=7, TRUNC=8,
         ZCHECK=9, ZMETHOD=10, ZWINDOW=11, ZDICT=12, BTYPE=13, STORED=14, NSYMS=15,
         CLSET=16, REPEAT=17, NOEOB=18, LITSET=19, DISTSET=20, LITCODE=21, DISTCODE=22,
         FAR=23, ADLER=24, ZSHORT=25, FILTER=26, SHORT=27)
W = dict(ANC_CRC=1, ZEXTRA=2, LONG=4, AFTER_IEND=8, IGNORED=16, INDEX=32)
# zlib's message -> our code (the DEFLATE-level verdicts)
ZMSG = {"incorrect header check": "ZCHECK", "unknown compression method": "ZMETHOD",
        "invalid window size": "ZWINDOW", "need dictionary": "ZDICT",
        "invalid block type": "BTYPE", "invalid stored block lengths": "STORED",
        "too many length or distance symbols": "NSYMS", "invalid code lengths set": "CLSET",
        "invalid bit length repeat": "REPEAT", "invalid code -- missing end-of-block": "NOEOB",
        "invalid literal/lengths set": "LITSET", "invalid distances set": "DISTSET",
        "invalid literal/length code": "LITCODE", "invalid distance code": "DISTCODE",
        "invalid distance too far back": "FAR", "incorrect data check": "ADLER",
        "incomplete or truncated stream": "ZSHORT"}

MAX_ROW_BYTES = 8192        # umd/png: the previous-row buffer (docs/png_decode.md §3)
MAX_DIM = 65535             # 16-bit coordinates

SIG = b"\x89PNG\r\n\x1a\n"
ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
         (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
DEPTHS = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}


class GoldenError(Exception):
    pass


# =========================================================================================
# DEFLATE writer -- emits streams zlib's encoder never makes (the edges), from tokens
# =========================================================================================
LBASE = inflate_ref.LBASE
LEXT = inflate_ref.LEXT
DBASE = inflate_ref.DBASE
DEXT = inflate_ref.DEXT
CLORDER = inflate_ref.CLORDER


class BitWriter(object):
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def bits(self, v, n):                 # LSB first
        self.acc |= (v & ((1 << n) - 1)) << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def code(self, c, n):                 # Huffman codes go MSB first
        r = 0
        for i in range(n):
            r = r << 1 | (c >> i & 1)
        self.bits(r, n)

    def align(self):
        if self.n:
            self.bits(0, 8 - self.n)

    def data(self):
        o = bytearray(self.out)
        if self.n:
            o.append(self.acc & 0xFF)
        return bytes(o)


def canonical(lengths):
    """RFC 1951 3.2.2: lengths -> codes (symbols with length 0 get None)."""
    bl = Counter(ln for ln in lengths if ln)
    code = 0
    nxt = {}
    for b in range(1, 16):
        code = (code + bl.get(b - 1, 0)) << 1
        nxt[b] = code
    out = []
    for ln in lengths:
        if ln:
            out.append(nxt[ln])
            nxt[ln] += 1
        else:
            out.append(None)
    return out


def huff_lengths(freqs, maxlen=15):
    """Huffman code lengths for the symbols with freq > 0 (complete code for >= 2
    symbols; a lone symbol gets length 1). Flattens the frequencies until <= maxlen."""
    syms = [i for i, f in enumerate(freqs) if f]
    lens = [0] * len(freqs)
    if len(syms) == 1:
        lens[syms[0]] = 1
        return lens
    f = list(freqs)
    while True:
        h = [(f[s], i, [s]) for i, s in enumerate(syms)]
        heapq.heapify(h)
        depth = Counter()
        k = len(h)
        while len(h) > 1:
            a = heapq.heappop(h)
            b = heapq.heappop(h)
            for s in a[2] + b[2]:
                depth[s] += 1
            heapq.heappush(h, (a[0] + b[0], k, a[2] + b[2]))
            k += 1
        if max(depth.values()) <= maxlen:
            for s in syms:
                lens[s] = depth[s]
            return lens
        f = [(x + 1) // 2 + 1 if x else 0 for x in f]


def len_sym(ln):
    for i in range(28, -1, -1):
        if ln >= LBASE[i]:
            if i == 28 and ln != 258:
                continue
            return i, ln - LBASE[i]
    raise ValueError(ln)


def dist_sym(d):
    for i in range(29, -1, -1):
        if d >= DBASE[i]:
            return i, d - DBASE[i]
    raise ValueError(d)


def lz(data, start=0, cands=(), minlen=3, far=False, rng=None):
    """Greedy LZ77 of data[start:] with a 32 KB window and max length 258. `cands`:
    distances always tried (to force far / aligned matches). -> tokens:
    ('lit', b) / ('match', len, dist)."""
    head = {}
    toks = []
    i = start
    for j in range(max(0, start - 32768), start):
        head.setdefault(bytes(data[j:j + 3]), []).append(j)
    while i < len(data):
        best = (0, 0)
        tried = set()
        key = bytes(data[i:i + 3])
        chain = head.get(key, [])
        for j in list(reversed(chain[-64:])) + [i - d for d in cands]:
            d = i - j
            if d < 1 or d > 32768 or d > i or d in tried:
                continue
            tried.add(d)
            n = 0
            while n < 258 and i + n < len(data) and data[i + n] == data[i + n - d]:
                n += 1
            if n > best[0] or (n == best[0] and far and d > best[1]):
                best = (n, d)
        if best[0] >= minlen:
            toks.append(("match", best[0], best[1]))
            step = best[0]
        else:
            toks.append(("lit", data[i]))
            step = 1
        for k in range(i, i + step):
            head.setdefault(bytes(data[k:k + 3]), []).append(k)
        i += step
    return toks


def tok_syms(toks, len258_284=False):
    """-> list of (litlen symbol, extra, nbits, dist symbol, extra, nbits) / literal."""
    out = []
    for t in toks:
        if t[0] == "lit":
            out.append((t[1],))
        elif t[0] == "eob":
            out.append((256,))
        else:
            _, ln, d = t
            if ln == 258 and len258_284:
                ls, le, lb = 27, 31, 5
            else:
                i, le = len_sym(ln)
                ls, lb = i, LEXT[i]
            ds, de = dist_sym(d)
            out.append((257 + ls, le, lb, ds, de, DEXT[ds]))
    return out


def emit_syms(bw, syms, lcodes, llens, dcodes, dlens):
    for s in syms:
        bw.code(lcodes[s[0]], llens[s[0]])
        if len(s) > 1:
            bw.bits(s[1], s[2])
            bw.code(dcodes[s[3]], dlens[s[3]])
            bw.bits(s[4], s[5])


FIXED_L = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
FIXED_D = [5] * 32


def block_stored(bw, data, final, nlen_xor=0xFFFF):
    bw.bits(final, 1)
    bw.bits(0, 2)
    bw.align()
    bw.bits(len(data), 16)
    bw.bits(len(data) ^ nlen_xor, 16)
    for b in data:
        bw.bits(b, 8)


def block_fixed(bw, toks, final, len258_284=False, raw_syms=None):
    bw.bits(final, 1)
    bw.bits(1, 2)
    syms = raw_syms if raw_syms is not None else tok_syms(toks, len258_284) + [(256,)]
    emit_syms(bw, syms, canonical(FIXED_L), FIXED_L, canonical(FIXED_D), FIXED_D)


def cl_encode(lengths, rep16_ok=True, rep_ok=True):
    """Code-length sequence -> [(sym, extra, nbits)] with 16/17/18 run coding."""
    out = []
    i = 0
    n = len(lengths)
    while i < n:
        v = lengths[i]
        run = 1
        while i + run < n and lengths[i + run] == v:
            run += 1
        if v == 0 and rep_ok and run >= 3:
            r = min(run, 138)
            if r >= 11:
                out.append((18, r - 11, 7))
            else:
                out.append((17, r - 3, 3))
            i += r
            continue
        if v != 0 and rep16_ok and rep_ok and run >= 4:
            out.append((v, 0, 0))
            r = min(run - 1, 6)
            out.append((16, r - 3, 2))
            i += 1 + r
            continue
        out.append((v, 0, 0))
        i += 1
    return out


def block_dynamic(bw, toks, final, llens=None, dlens=None, len258_284=False,
                  hlit=None, hdist=None, hclen=None, cl_seq=None, cl_lens=None,
                  raw_syms=None, rep16_ok=True):
    """A dynamic block. Lengths default to Huffman over the tokens' frequencies; every
    header field can be forced (the edge and invalid cases)."""
    syms = raw_syms if raw_syms is not None else tok_syms(toks, len258_284) + [(256,)]
    if llens is None:
        lf = [0] * 286
        df = [0] * 30
        for s in syms:
            lf[s[0]] += 1
            if len(s) > 1:
                df[s[3]] += 1
        llens = huff_lengths(lf)
        dlens = huff_lengths(df) if any(df) else [0] * 30
    nl = hlit if hlit is not None else max(257, max(i for i, v in enumerate(llens) if v) + 1)
    nd = hdist if hdist is not None else max(1, max([i + 1 for i, v in enumerate(dlens) if v] or [1]))
    ll = (list(llens) + [0] * 300)[:nl]
    dl = (list(dlens) + [0] * 40)[:nd]
    seq = cl_seq if cl_seq is not None else cl_encode(ll + dl, rep16_ok=rep16_ok)
    if cl_lens is None:
        cf = [0] * 19
        for s in seq:
            cf[s[0]] += 1
        cl_lens = huff_lengths(cf, 7)
    nc = hclen if hclen is not None else max(4, max(i + 1 for i, s in enumerate(CLORDER) if cl_lens[s]))
    bw.bits(final, 1)
    bw.bits(2, 2)
    bw.bits(nl - 257, 5)
    bw.bits(nd - 1, 5)
    bw.bits(nc - 4, 4)
    for i in range(nc):
        bw.bits(cl_lens[CLORDER[i]], 3)
    ccodes = canonical(cl_lens)
    for s, e, nb in seq:
        bw.code(ccodes[s], cl_lens[s])
        if nb:
            bw.bits(e, nb)
    lfull = (list(llens) + [0] * 300)[:288]
    dfull = (list(dlens) + [0] * 32)[:32]
    emit_syms(bw, syms, canonical(lfull), lfull, canonical(dfull), dfull)
    return llens, dlens


def zwrap(raw_deflate, payload, cmf=0x78, flg=None, adler=None):
    if flg is None:
        flg = 0
        while (cmf * 256 + flg) % 31:
            flg += 1
        flg |= 0                                   # FLEVEL 0 is legal and checked
        while (cmf * 256 + flg) % 31:
            flg += 1
    a = zlib.adler32(payload) if adler is None else adler
    return bytes([cmf, flg]) + raw_deflate + struct.pack(">I", a & 0xFFFFFFFF)


# =========================================================================================
# PNG writer
# =========================================================================================
def chunk(typ, data, crc=None):
    c = binascii.crc32(typ + data) & 0xFFFFFFFF if crc is None else crc
    return struct.pack(">I", len(data)) + typ + data + struct.pack(">I", c)


def row_bytes(w, ctype, depth):
    return (w * CHANNELS[ctype] * depth + 7) // 8


def passes(w, h, interlace):
    """-> [(pass, x0, y0, dx, dy, pw, ph)] for the non-empty passes."""
    out = []
    for p, (x0, y0, dx, dy) in enumerate(ADAM7 if interlace else ((0, 0, 1, 1),)):
        pw = (w - x0 + dx - 1) // dx if w > x0 else 0
        ph = (h - y0 + dy - 1) // dy if h > y0 else 0
        if pw and ph:
            out.append((p, x0, y0, dx, dy, pw, ph))
    return out


def pack_row(samples, depth):
    """Samples (ints) -> bytes, MSB first, padding bits 0."""
    if depth >= 8:
        nb = depth // 8
        return b"".join(s.to_bytes(nb, "big") for s in samples)
    out = bytearray()
    acc = 0
    n = 0
    for s in samples:
        acc = acc << depth | s
        n += depth
        if n == 8:
            out.append(acc)
            acc = n = 0
    if n:
        out.append(acc << (8 - n))
    return bytes(out)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def filter_rows(rows, bpp, ftypes, cov):
    """Encoder side: raw rows (one pass) -> filtered bytes; counts the unfilter coverage
    events a mutation would change."""
    out = bytearray()
    prev = bytes(len(rows[0])) if rows else b""
    for r, (row, ft) in enumerate(zip(rows, ftypes)):
        out.append(ft)
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 0:
                pr = 0
            elif ft == 1:
                pr = a
            elif ft == 2:
                pr = b
            elif ft == 3:
                pr = (a + b) >> 1
                if a + b > 255:
                    cov["avg_sum_gt255"] += 1
            else:
                pr = paeth(a, b, c)
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                # the ties whose order changes the result (pa == pb with a != b cannot
                # matter: it forces a + b = 2c, so pc = 0 and c wins either way)
                if pa == pc and a != c and pa <= pb:
                    cov["paeth_tie_ac"] += 1
                if pb == pc and b != c and pb < pa:
                    cov["paeth_tie_bc"] += 1
            if ft in (1, 3, 4) and i >= bpp and a != 0 and bpp > 1:
                cov["bpp%d_left_nonzero" % bpp] += 1
            if ft in (2, 3, 4) and r == 0:
                cov["first_row_up_family"] += 1
            out.append((x - pr) & 0xFF)
        prev = row
    return bytes(out)


class Img(object):
    """An image: w, h, ctype, depth, interlace, samples[y][x] = tuple per channel (raw
    sample values), palette [(r,g,b)], trns (bytes for type 3 / tuple key for 0/2)."""

    def __init__(self, w, h, ctype, depth, interlace=0, samples=None, palette=None, trns=None):
        self.w, self.h, self.ctype, self.depth, self.interlace = w, h, ctype, depth, interlace
        self.samples = samples
        self.palette = palette
        self.trns = trns

    def raw_passes(self):
        """-> [(pass info, [row bytes])]"""
        out = []
        ch = CHANNELS[self.ctype]
        for p, x0, y0, dx, dy, pw, ph in passes(self.w, self.h, self.interlace):
            rows = []
            for j in range(ph):
                y = y0 + j * dy
                s = []
                for i in range(pw):
                    s.extend(self.samples[y][x0 + i * dx][:ch])
                rows.append(pack_row(s, self.depth))
            out.append(((p, x0, y0, dx, dy, pw, ph), rows))
        return out


def bpp_of(ctype, depth):
    return max(1, CHANNELS[ctype] * depth // 8)


def build_png(img, ftype_fn=None, cov=None, idat_split=None, extra_chunks=(),
              zstream=None, payload_override=None, plte_bytes=None, trns_bytes=None,
              chunks_override=None, sig=SIG, ihdr_override=None, after_iend=b"",
              level=9, strategy=0, wbits=15):
    """-> (png bytes, payload). ftype_fn(pass, row) -> filter type."""
    cov = cov if cov is not None else Counter()
    payload = bytearray()
    for (p, x0, y0, dx, dy, pw, ph), rows in img.raw_passes():
        ft = [ftype_fn(p, j) if ftype_fn else 0 for j in range(ph)]
        prev_nonzero = payload and any(payload[-8:])
        if img.interlace and p > 0 and prev_nonzero and ft and ft[0] in (2, 3, 4):
            cov["pass_start_up_family_after_nonzero"] += 1
        payload += filter_rows(rows, bpp_of(img.ctype, img.depth), ft, cov)
    if payload_override is not None:
        payload = bytearray(payload_override)
    if zstream is None:
        co = zlib.compressobj(level, zlib.DEFLATED, wbits, 9, strategy)
        zstream = co.compress(bytes(payload)) + co.flush()
    ihdr = ihdr_override if ihdr_override is not None else struct.pack(
        ">IIBBBBB", img.w, img.h, img.depth, img.ctype, 0, 0, img.interlace)
    if chunks_override is not None:
        return sig + b"".join(chunks_override(ihdr, zstream)) + after_iend, bytes(payload)
    out = sig + chunk(b"IHDR", ihdr)
    for c in extra_chunks:
        out += c
    if plte_bytes is None and img.palette:
        plte_bytes = b"".join(bytes(c) for c in img.palette)
    if plte_bytes is not None:
        out += chunk(b"PLTE", plte_bytes)
    if trns_bytes is None and img.trns is not None:
        if img.ctype == 3:
            trns_bytes = bytes(img.trns)
        else:
            trns_bytes = b"".join(struct.pack(">H", v) for v in img.trns)
    if trns_bytes is not None:
        out += chunk(b"tRNS", trns_bytes)
    parts = [zstream] if idat_split is None else idat_split(zstream)
    for part in parts:
        out += chunk(b"IDAT", part)
    out += chunk(b"IEND", b"") + after_iend
    return out, bytes(payload)


# =========================================================================================
# oracles
# =========================================================================================
ORACLE_BIN = os.path.join(ROOT, ".sim", "png_oracle")


def build_oracle():
    src = os.path.join(HERE, "png_oracle.c")
    if (not os.path.exists(ORACLE_BIN)) or os.path.getmtime(ORACLE_BIN) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(ORACLE_BIN), exist_ok=True)
        subprocess.run(["cc", "-O2", "-Wall", "-o", ORACLE_BIN, src, "-lpng16"], check=True)


def libpng(png):
    """-> (verdict 'OK'/'ERR', header dict or message, [(r,g,b,a) 16-bit], warnings)."""
    r = subprocess.run([ORACLE_BIN], input=png, capture_output=True)
    warns = [ln[5:] for ln in r.stderr.decode(errors="replace").splitlines() if ln.startswith("WARN ")]
    nl = r.stdout.find(b"\n")
    head = r.stdout[:nl].decode(errors="replace") if nl >= 0 else r.stdout.decode(errors="replace")
    if not head.startswith("OK "):
        return "ERR", head[4:] if head.startswith("ERR ") else "(no output, rc %d)" % r.returncode, None, warns
    _, w, h, ct, d, il = head.split()
    body = r.stdout[nl + 1:]
    px = [struct.unpack(">HHHH", body[i:i + 8]) for i in range(0, len(body), 8)]
    hd = dict(w=int(w), h=int(h), ctype=int(ct), depth=int(d), interlace=int(il))
    if len(px) != hd["w"] * hd["h"]:
        raise GoldenError("libpng oracle: %d pixels for %dx%d" % (len(px), hd["w"], hd["h"]))
    return "OK", hd, px, warns


def pil_rgba(png):
    from PIL import Image
    im = Image.open(io.BytesIO(png))
    im.load()
    b = im.convert("RGBA").tobytes()
    return [tuple(b[i:i + 4]) for i in range(0, len(b), 4)], im


def ffmpeg_rgba64(png):
    r = subprocess.run(["ffmpeg", "-v", "error", "-f", "png_pipe", "-i", "-", "-f", "rawvideo",
                        "-pix_fmt", "rgba64be", "-"], input=png, capture_output=True)
    o = r.stdout
    return [struct.unpack(">HHHH", o[i:i + 8]) for i in range(0, len(o), 8)]


def zlib_verdict(z):
    """-> ('OK', bytes, extra) or ('ERR', code name, None)."""
    d = zlib.decompressobj()
    try:
        out = d.decompress(z)
    except zlib.error as e:
        m = re.sub(r"^Error -?\d+ while decompressing data: ", "", str(e))
        if m == "Error 2 while decompressing data":     # Z_NEED_DICT, no message
            m = "need dictionary"
        if m not in ZMSG:
            raise GoldenError("zlib message not mapped: %r" % m)
        return "ERR", ZMSG[m], None
    if not d.eof:
        return "ERR", "ZSHORT", out
    return "OK", out, len(d.unused_data)


# =========================================================================================
# cases
# =========================================================================================
class Case(object):
    def __init__(self, name, png, err="OK", warn=0, why="", stricter=False, data=True,
                 img=None, exp_payload=None):
        self.name = name
        self.png = png
        self.err = err
        self.warn = warn
        self.why = why
        self.stricter = stricter      # libpng accepts (benign) what we refuse: documented
        self.data = data              # score the data taps (valid cases)
        self.img = img
        self.exp_payload = exp_payload


def rnd_samples(rng, w, h, ctype, depth, maxv=None, lo_entropy=False):
    ch = CHANNELS[ctype]
    top = (1 << depth) - 1 if maxv is None else maxv
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            if lo_entropy:
                row.append(tuple(rng.choice((0, 1, 2, 3, top, top - 1)) & top for _ in range(ch)))
            else:
                row.append(tuple(rng.randint(0, top) for _ in range(ch)))
        rows.append(row)
    return rows


def rnd_palette(rng, n):
    return [(rng.randint(0, 255), rng.randint(0, 255), rng.randint(0, 255)) for _ in range(n)]


def synth_cases(seed=20260925):
    rng = random.Random(seed)
    cov = Counter()
    cases = []

    def add(c):
        cases.append(c)
        return c

    def mixed_filters(p, j):
        return rng.randint(0, 4)

    # ---- every legal (type, depth), plain and Adam7, mixed filters -------------------------
    for ct in (0, 2, 3, 4, 6):
        for d in DEPTHS[ct]:
            for il in (0, 1):
                for (w, h) in ((13, 11), (1, 1), (9, 9)):
                    lo = rng.random() < 0.5
                    s = rnd_samples(rng, w, h, ct, d, maxv=None if ct != 3 else min((1 << d) - 1, 40),
                                    lo_entropy=lo)
                    pal = rnd_palette(rng, min(1 << d, 41)) if ct == 3 else None
                    trns = None
                    if ct == 3 and rng.random() < 0.7:
                        trns = [rng.randint(0, 255) for _ in range(rng.randint(1, len(pal)))]
                    img = Img(w, h, ct, d, il, s, pal, trns)
                    png, pl = build_png(img, mixed_filters, cov)
                    add(Case("t%d_d%d_il%d_%dx%d" % (ct, d, il, w, h), png, img=img))

    # ---- filters: each type over whole images, and the tie / overflow makers --------------
    for ft in range(5):
        for ct, d in ((0, 8), (2, 16), (6, 16), (6, 8), (4, 8), (3, 4)):
            s = rnd_samples(rng, 17, 7, ct, d, lo_entropy=(ft == 4), maxv=15 if ct == 3 else None)
            pal = rnd_palette(rng, 16) if ct == 3 else None
            img = Img(17, 7, ct, d, 0, s, pal)
            png, _ = build_png(img, lambda p, j, ft=ft: ft, cov)
            add(Case("filter%d_t%d_d%d" % (ft, ct, d), png, img=img))
    # Average with a + b > 255: bright rows
    s = [[(rng.randint(200, 255),) for _ in range(40)] for _ in range(6)]
    img = Img(40, 6, 0, 8, 0, s)
    add(Case("filter3_bright", build_png(img, lambda p, j: 3, cov)[0], img=img))
    # Paeth ties with distinct values: a and b symmetric around c
    s = [[(rng.choice((10, 20, 30)),) for _ in range(40)] for _ in range(8)]
    img = Img(40, 8, 0, 8, 0, s)
    add(Case("filter4_ties", build_png(img, lambda p, j: 4, cov)[0], img=img))
    # Adam7: a nonzero previous pass, the next pass starting on Up / Average / Paeth
    for ft in (2, 3, 4):
        s = [[(200 + (x * 7 + y * 3) % 50,) for x in range(16)] for y in range(16)]
        img = Img(16, 16, 0, 8, 1, s)
        add(Case("adam7_passstart_f%d" % ft, build_png(img, lambda p, j, ft=ft: ft if j == 0 else rng.randint(0, 4), cov)[0], img=img))
    # Adam7 odd sizes (empty passes)
    for (w, h) in ((1, 1), (2, 3), (3, 2), (5, 1), (1, 5), (7, 7), (8, 8), (9, 9), (33, 17)):
        for ct, d in ((0, 1), (3, 2), (2, 8), (6, 16)):
            s = rnd_samples(rng, w, h, ct, d, maxv=3 if ct == 3 else None)
            pal = rnd_palette(rng, 4) if ct == 3 else None
            img = Img(w, h, ct, d, 1, s, pal)
            add(Case("adam7_%dx%d_t%d_d%d" % (w, h, ct, d), build_png(img, mixed_filters, cov)[0], img=img))
    # sub-byte widths ending mid-byte, every sub-byte depth, grey and palette
    for d in (1, 2, 4):
        for w in (1, 3, 5, 7, 9, 15, 17, 31, 33):
            for ct in (0, 3):
                s = rnd_samples(rng, w, 3, ct, d)
                pal = rnd_palette(rng, 1 << d) if ct == 3 else None
                img = Img(w, 3, ct, d, 0, s, pal)
                add(Case("pad_t%d_d%d_w%d" % (ct, d, w), build_png(img, mixed_filters, cov)[0], img=img))

    # ---- transparency -------------------------------------------------------------------
    # grey key at every depth: one pixel matches exactly, one misses (16-bit: low byte only)
    for d in (1, 2, 4, 8, 16):
        top = (1 << d) - 1
        key = top // 2 if d > 1 else 1
        miss = key ^ 1 if d == 16 else (key + 1) & top
        s = [[(key,), (miss,), (0,), (top,)] * 3 for _ in range(3)]
        img = Img(12, 3, 0, d, 0, s, trns=(key,))
        add(Case("trns_grey_d%d" % d, build_png(img, mixed_filters, cov)[0], img=img))
        cov["trns_key_hit"] += 1
        if d == 16:
            cov["trns_key16_lowbyte_miss"] += 1
    # a key above the depth's range never matches
    img = Img(4, 1, 0, 2, 0, [[(0,), (1,), (2,), (3,)]], trns=(7,))
    add(Case("trns_grey_key_out_of_range", build_png(img)[0], img=img))
    # an out-of-range RGB8 key: libpng masks it to the depth (0x101 matches 1)
    img = Img(2, 1, 2, 8, 0, [[(1, 2, 3), (1, 2, 4)]], trns=(0x101, 0x202, 0x303))
    add(Case("trns_rgb8_key_out_of_range", build_png(img)[0], img=img))
    for d in (8, 16):
        top = (1 << d) - 1
        key = (rng.randint(0, top), rng.randint(0, top), rng.randint(0, top))
        miss = (key[0], key[1], key[2] ^ 1)
        s = [[key, miss, (0, 0, 0), key] for _ in range(2)]
        img = Img(4, 2, 2, d, 0, s, trns=key)
        add(Case("trns_rgb_d%d" % d, build_png(img, mixed_filters, cov)[0], img=img))
    # palette: tRNS shorter than PLTE (indices past it opaque), exact, one entry
    for n_t in (1, 7, 16):
        pal = rnd_palette(rng, 16)
        s = [[(x % 16,) for x in range(16)] for _ in range(2)]
        img = Img(16, 2, 3, 4, 0, s, pal, [rng.randint(0, 254) for _ in range(n_t)])
        add(Case("trns_pal_%d_of_16" % n_t, build_png(img)[0], img=img))
        if n_t < 16:
            cov["trns_index_past_trns"] += 1
    # 256-entry palette at 8 bits, full tRNS
    pal = rnd_palette(rng, 256)
    s = [[((x + 16 * y) % 256,) for x in range(16)] for y in range(16)]
    img = Img(16, 16, 3, 8, 0, s, pal, [rng.randint(0, 255) for _ in range(256)])
    add(Case("pal256_trns256", build_png(img, mixed_filters, cov)[0], img=img))

    # ---- chunk structure ------------------------------------------------------------------
    s = rnd_samples(rng, 30, 20, 2, 8)
    img = Img(30, 20, 2, 8, 0, s)

    def split_every(n):
        return lambda z: [z[i:i + n] for i in range(0, len(z), n)]
    add(Case("idat_split_1", build_png(img, mixed_filters, idat_split=split_every(1))[0], img=img))
    add(Case("idat_split_7", build_png(img, mixed_filters, idat_split=split_every(7))[0], img=img))
    add(Case("idat_zero_len", build_png(img, mixed_filters,
                                        idat_split=lambda z: [b"", z[:5], b"", z[5:], b""])[0], img=img))
    anc = [chunk(b"tEXt", b"Comment\x00made by png_golden"), chunk(b"gAMA", struct.pack(">I", 45455)),
           chunk(b"prVt", bytes(range(40))), chunk(b"zzZZ", b"")]
    add(Case("ancillary_chunks", build_png(img, mixed_filters, extra_chunks=anc)[0], img=img))
    png, _ = build_png(img, mixed_filters)
    # an ancillary chunk after IDAT, before IEND
    iend = chunk(b"IEND", b"")
    add(Case("ancillary_after_idat", png[:-len(iend)] + chunk(b"tIME", bytes(7)) + iend, img=img))
    # bytes after IEND (before in_last): flagged, image shown
    add(Case("after_iend", png + b"\x00junk", warn=W["AFTER_IEND"], img=img))
    # zlib levels / strategies / windows over one image
    big = Img(64, 48, 6, 8, 0, rnd_samples(rng, 64, 48, 6, 8, lo_entropy=True))
    for lvl, strat, wb in ((0, 0, 15), (1, 0, 15), (9, zlib.Z_FIXED, 15), (9, zlib.Z_RLE, 15),
                           (9, zlib.Z_HUFFMAN_ONLY, 15), (9, 0, 9), (6, 0, 10)):
        add(Case("zlib_l%d_s%d_w%d" % (lvl, strat, wb),
                 build_png(big, mixed_filters, level=lvl, strategy=strat, wbits=wb)[0], img=big))

    # ---- DEFLATE edges, each inside a valid PNG (grey8 rows; the stride aligns repeats) ----
    def grey_img(w, h, fill):
        return Img(w, h, 0, 8, 0, [[(fill(x, y),) for x in range(w)] for y in range(h)])

    def deflate_case(name, img, make_raw, cov_need=()):
        """make_raw(payload) -> raw DEFLATE; checked by zlib, counted by inflate_ref."""
        _, payload = build_png(img)
        raw = make_raw(payload)
        z = zwrap(raw, payload)
        v = zlib_verdict(z)
        if v[0] != "OK" or v[1] != payload:
            raise GoldenError("%s: zlib does not accept the stream (%s)" % (name, v[1]))
        out, inf = inflate_ref.inflate_zlib(z)
        for k in cov_need:
            if not inf.cov[k]:
                raise GoldenError("%s: coverage %s not reached" % (name, k))
        cov.update({k: v for k, v in inf.cov.items() if k != "max_dist"})
        return add(Case(name, build_png(img, zstream=z)[0], img=img))

    # stored: LEN 0 blocks, a 65535 block
    img = grey_img(255, 260, lambda x, y: (x * 31 + y * 7) & 0xFF)

    def stored_mix(p):
        bw = BitWriter()
        block_stored(bw, b"", 0)
        block_stored(bw, p[:65535], 0)
        block_stored(bw, b"", 0)
        block_stored(bw, p[65535:], 1)
        return bw.data()
    deflate_case("stored_0_65535", img, stored_mix, ("stored_len0", "stored_len65535"))

    # far matches: stride 256 rows repeat after 128 rows (dist 32768), random bytes
    rows = [[rng.randint(0, 255) for _ in range(255)] for _ in range(128)]
    img = Img(255, 200, 0, 8, 0, [[(rows[y % 128][x],) for x in range(255)] for y in range(200)])

    def far(p):
        bw = BitWriter()
        toks = lz(p, cands=(32768,), far=True)
        block_dynamic(bw, toks, 1)
        return bw.data()
    deflate_case("dist32768", img, far, ("dist32768", "dist_gt16k_differs", "dist_extra_nonzero"))
    # dist 20000 (stride 250 x 80 rows), fixed Huffman, len 258 as 284+31
    rows = [[rng.randint(0, 255) for _ in range(249)] for _ in range(80)]
    img = Img(249, 130, 0, 8, 0, [[(rows[y % 80][x],) for x in range(249)] for y in range(130)])

    def far_fixed(p):
        bw = BitWriter()
        toks = lz(p, cands=(20000,), far=True)
        block_fixed(bw, toks, 1, len258_284=True)
        return bw.data()
    deflate_case("dist20000_fixed_len284", img, far_fixed, ("len258_code284", "dist_gt16k_differs", "fixed"))
    # overlapping copies (dist 1..3), len 258 by 285, multi-block with matches into
    # earlier blocks, a block of each type
    img = grey_img(100, 90, lambda x, y: 0 if y % 3 == 0 else (x % 2) * 5 if y % 3 == 1 else (x // 3 + y) & 3)

    def multi(p):
        bw = BitWriter()
        n = len(p)
        a, b = n // 4, n // 2
        block_stored(bw, p[:a], 0)
        block_fixed(bw, lz(p[:b], start=a), 0)
        block_dynamic(bw, lz(p, start=b), 1)
        return bw.data()
    deflate_case("multi_block_overlap", img, multi,
                 ("overlap_dist1", "overlap_dist_gt1", "match_into_earlier_block", "len258_code285",
                  "multi_block"))
    # HLIT 286 / HDIST 30 / HCLEN 19, all literal codes present, a 15-bit code
    img = grey_img(120, 60, lambda x, y: rng.randint(0, 255) if (x + y) % 5 else 0)

    def maxhdr(p):
        bw = BitWriter()
        toks = lz(p)
        syms = tok_syms(toks) + [(256,)]
        lf = [1] * 286
        df = [1] * 30
        for s in syms:
            lf[s[0]] += 100
            if len(s) > 1:
                df[s[3]] += 100
        fib = [1, 1]
        while len(fib) < 16:
            fib.append(fib[-1] + fib[-2])
        for i in range(16):                      # a skewed tail -> a 15-bit code
            lf[270 + i] = fib[i]
        ll = huff_lengths(lf)
        dl = huff_lengths(df)
        block_dynamic(bw, None, 1, llens=ll, dlens=dl, hlit=286, hdist=30, hclen=19, raw_syms=syms)
        return bw.data()
    deflate_case("hlit286_hdist30_hclen19", img, maxhdr, ("hlit286", "hdist30", "hclen19", "code_len15_table"))
    # a 15-bit code actually decoded
    img = grey_img(64, 64, lambda x, y: [0, 0, 0, 0, 1, 1, 2, 3][(x * y) % 8] if (x + 2 * y) % 97 else 200 + y % 11)

    def deep(p):
        bw = BitWriter()
        toks = [("lit", b) for b in p]
        syms = tok_syms(toks) + [(256,)]
        f = Counter(s[0] for s in syms)
        order = sorted(f, key=lambda k: -f[k])
        ll = [0] * 286
        # lengths 1,2,...,14,15,15 over the 16 most common, then the rest must fit: use a
        # complete code built by Huffman over fibonacci-like weights
        wts = [0] * 286
        fib = [1, 1]
        while len(fib) < len(order) + 1:
            fib.append(fib[-1] + fib[-2])
        for i, s in enumerate(reversed(order)):
            wts[s] = fib[i]
        ll = huff_lengths(wts)
        block_dynamic(bw, None, 1, llens=ll, dlens=[0] * 30, raw_syms=syms)
        return bw.data()
    deflate_case("code_len15_decoded", img, deep, ("code_len15_decoded", "dist_empty"))
    # a single distance code (length 1), repeat 16 across the lit/dist boundary
    img = grey_img(90, 40, lambda x, y: (x % 7) * 9 if y % 2 else (x % 7) * 9)

    def single_dist(p):
        bw = BitWriter()
        toks = []
        i = 0
        while i < len(p):
            if i >= 91 and p[i:i + 5] == p[i - 91:i - 86]:
                n = 5
                while n < 258 and i + n < len(p) and p[i + n] == p[i + n - 91]:
                    n += 1
                toks.append(("match", n, 91))
                i += n
            else:
                toks.append(("lit", p[i]))
                i += 1
        syms = tok_syms(toks) + [(256,)]
        lf = [0] * 286
        for s in syms:
            lf[s[0]] += 1
        ll = huff_lengths(lf)
        ds = dist_sym(91)[0]
        dl = [0] * 30
        dl[ds] = 1
        # make the literal table end with the same length as the first distance lengths,
        # so a 16 straddles the boundary: pad HLIT so trailing lit lengths equal ll[-1]
        block_dynamic(bw, None, 1, llens=ll, dlens=dl, raw_syms=syms)
        return bw.data()
    deflate_case("dist_single_code", img, single_dist, ("dist_single_code",))

    def rep16_boundary(p):
        """Flat codes built directly: the last three literal/length lengths and the first
        three distance lengths are all 5, their neighbours are not -> exactly one run of
        six 5s, coded as 5 + 16(x5), which straddles the HLIT boundary."""
        bw = BitWriter()
        toks = lz(p)
        syms = tok_syms(toks) + [(256,)]
        used = sorted({s_[0] for s_ in syms})
        nl = used[-1] + 1
        tail = [nl - 3, nl - 2, nl - 1]
        members = sorted(set(used) | set(tail))
        n = len(members)
        if not 33 <= n <= 61:
            raise GoldenError("rep16 boundary: %d literal/length symbols, need 33..61" % n)
        short = 64 - n                              # a flat 5/6-bit complete code
        ll = [0] * 286
        order = tail + [m for m in members if m not in tail and m != nl - 4] + \
            ([nl - 4] if nl - 4 in members else [])
        for k, m in enumerate(order):
            ll[m] = 5 if k < short else 6
        dl = [5] * 30                               # 30 symbols: two of 4 bits, 28 of 5
        dl[3] = dl[4] = 4
        block_dynamic(bw, None, 1, llens=ll, dlens=dl, hlit=nl, hdist=30, raw_syms=syms)
        return bw.data()
    img = grey_img(90, 40, lambda x, y: rng.randint(0, 40))
    deflate_case("rep16_across_boundary", img, rep16_boundary, ("rep16_across_lit_dist",))

    # ---- size bounds ----------------------------------------------------------------------
    for (name, w, h, ct, d) in (("rowbytes_8192_grey8", 8192, 2, 0, 8), ("rowbytes_8192_rgba16", 1024, 3, 6, 16),
                                ("rowbytes_8192_grey1", 65535, 1, 0, 1)):
        s = rnd_samples(rng, w, h, ct, d, lo_entropy=True)
        img = Img(w, h, ct, d, 0, s)
        add(Case(name, build_png(img, mixed_filters)[0], img=img))
    img = Img(1, 65535, 0, 1, 0, [[(y & 1,)] for y in range(65535)])
    add(Case("height_65535", build_png(img)[0], img=img))
    # one past: refused before any data (libpng accepts -> stricter, documented)
    for (name, w, h, ct, d) in (("rowbytes_8193", 8193, 1, 0, 8), ("rowbytes_8200_rgba16", 1025, 1, 6, 16),
                                ("width_65536", 65536, 1, 0, 1), ("height_65536", 1, 65536, 0, 1)):
        img = Img(w, h, ct, d, 0, [[(0,) * CHANNELS[ct]] * w for _ in range(h)])
        add(Case(name, build_png(img)[0], err="SIZE", stricter=True, data=False, why="our bound"))
    return cases, cov


def invalid_cases(seed=4242):
    """One defect per case; the expected code is by construction, and the generator
    checks it against zlib's message (DEFLATE) or libpng's verdict (PNG level)."""
    rng = random.Random(seed)
    cases = []
    s = rnd_samples(rng, 20, 10, 0, 8)
    img = Img(20, 10, 0, 8, 0, s)
    png, payload = build_png(img)

    def add(name, png, err, stricter=False, warn=0, why=""):
        cases.append(Case(name, png, err=err, warn=warn, stricter=stricter, data=False, why=why))

    def with_z(z, img=img):
        return build_png(img, zstream=z)[0]

    # PNG level
    add("bad_signature", b"\x89PNG\r\n\x1a\x0b" + png[8:], "SIG")
    ihdr_at = 8
    bad = bytearray(png)
    bad[ihdr_at + 8 + 13 + 3] ^= 1                      # IHDR CRC's last byte
    add("crc_ihdr", bytes(bad), "CRC")
    i = png.index(b"IDAT") - 4
    ln, = struct.unpack(">I", png[i:i + 4])
    bad = bytearray(png)
    bad[i + 8 + ln] ^= 0x80
    add("crc_idat", bytes(bad), "CRC")
    bad = bytearray(png)
    bad[-1] ^= 1
    add("crc_iend", bytes(bad), "CRC", stricter=True, why="libpng: benign 'IEND: CRC error'")
    bad = bytearray(png)
    bad[i + 8 + 3] ^= 0x10                              # IDAT data changed, CRC stale
    # the first error in stream order wins (libpng's verdict too): the data's own
    # inflate error, found before the chunk's CRC is read
    zv = zlib_verdict(idat_of(bytes(bad)))
    add("crc_idat_data", bytes(bad), zv[1] if zv[0] == "ERR" else "CRC")
    # an ancillary chunk with a bad CRC: ignored, flagged (libpng: benign)
    add("crc_ancillary", build_png(img, extra_chunks=[chunk(b"tEXt", b"a\x00b", crc=1)])[0], "OK",
        warn=W["ANC_CRC"])
    cases[-1].data = True
    cases[-1].img = img
    # tRNS with a bad CRC on a palette image: discarded (all opaque) -- libpng agrees
    pal = rnd_palette(rng, 4)
    pimg = Img(8, 2, 3, 2, 0, [[(x % 4,) for x in range(8)] for _ in range(2)], pal)
    add("crc_trns_discarded", build_png(pimg, extra_chunks=[])[0].replace(
        b"IDAT", b"IDAT", 1), "OK")
    good, _ = build_png(pimg)
    k = good.index(b"IDAT") - 4
    cases[-1].png = good[:k] + chunk(b"tRNS", bytes([0, 0, 0, 0]), crc=7) + good[k:]
    cases[-1].warn = W["ANC_CRC"]
    cases[-1].data = True
    cases[-1].img = pimg
    add("critical_unknown", build_png(img, extra_chunks=[chunk(b"ABCD", b"x")])[0], "CRITICAL")
    # IHDR defects
    for name, (d, ct, comp, filt, il, w, h) in (
            ("ihdr_depth16_palette", (16, 3, 0, 0, 0, 20, 10)),
            ("ihdr_depth3", (3, 0, 0, 0, 0, 20, 10)),
            ("ihdr_ctype5", (8, 5, 0, 0, 0, 20, 10)),
            ("ihdr_rgb_depth4", (4, 2, 0, 0, 0, 20, 10)),
            ("ihdr_compression1", (8, 0, 1, 0, 0, 20, 10)),
            ("ihdr_filter1", (8, 0, 0, 1, 0, 20, 10)),
            ("ihdr_interlace2", (8, 0, 0, 0, 2, 20, 10)),
            ("ihdr_width0", (8, 0, 0, 0, 0, 0, 10)),
            ("ihdr_height0", (8, 0, 0, 0, 0, 20, 0))):
        add(name, build_png(img, ihdr_override=struct.pack(">IIBBBBB", w, h, d, ct, comp, filt, il))[0], "IHDR")
    add("ihdr_len14", build_png(img, ihdr_override=struct.pack(">IIBBBBB", 20, 10, 8, 0, 0, 0, 0) + b"\0")[0], "IHDR")
    # chunk order
    z = zlib.compress(payload)
    add("no_ihdr_first", build_png(img, chunks_override=lambda ih, z: [
        chunk(b"tEXt", b"a\x00b"), chunk(b"IHDR", ih), chunk(b"IDAT", z), chunk(b"IEND", b"")])[0], "ORDER")
    add("iend_before_idat", build_png(img, chunks_override=lambda ih, z: [
        chunk(b"IHDR", ih), chunk(b"IEND", b""), chunk(b"IDAT", z)])[0], "ORDER")
    # the IDAT data ends at the first other chunk: the zlib stream is cut there, which
    # comes first in stream order (libpng: "Not enough image data")
    add("idat_not_contiguous", build_png(img, chunks_override=lambda ih, z: [
        chunk(b"IHDR", ih), chunk(b"IDAT", z[:10]), chunk(b"tEXt", b"a\x00b"),
        chunk(b"IDAT", z[10:]), chunk(b"IEND", b"")])[0], "ZSHORT")
    # a whole stream, then another IDAT after a different chunk: extra data (libpng
    # accepts it silently)
    add("idat_after_other_chunk", build_png(img, chunks_override=lambda ih, z: [
        chunk(b"IHDR", ih), chunk(b"IDAT", z), chunk(b"tEXt", b"a\x00b"),
        chunk(b"IDAT", b"\x00"), chunk(b"IEND", b"")])[0], "OK", warn=W["ZEXTRA"])
    cases[-1].data = True
    cases[-1].img = img
    add("ihdr_twice", build_png(img, chunks_override=lambda ih, z: [
        chunk(b"IHDR", ih), chunk(b"IHDR", ih), chunk(b"IDAT", z), chunk(b"IEND", b"")])[0], "ORDER")
    add("palette_no_plte", build_png(pimg, plte_bytes=None, chunks_override=lambda ih, z: [
        chunk(b"IHDR", ih), chunk(b"IDAT", z), chunk(b"IEND", b"")])[0], "ORDER")
    good, _ = build_png(pimg)
    k = good.index(b"IDAT") - 4
    kend = good.index(b"IEND") - 4
    add("plte_after_idat", good[:good.index(b"PLTE") - 4] + good[k:kend] +
        chunk(b"PLTE", b"".join(bytes(c) for c in pal)) + good[kend:], "ORDER")
    # PLTE defects
    add("plte_len_not3", build_png(pimg, plte_bytes=b"".join(bytes(c) for c in pal) + b"\x01")[0], "PLTE")
    # more entries than the depth can index: unreachable, accepted silently (libpng)
    add("plte_more_than_depth", build_png(pimg, plte_bytes=b"".join(bytes(c) for c in pal) + bytes(3))[0], "OK")
    cases[-1].data = True
    cases[-1].img = pimg
    add("plte_257", build_png(Img(4, 1, 3, 8, 0, [[(1,)] * 4], pal), plte_bytes=bytes(3 * 257))[0], "PLTE")
    add("plte_zero", build_png(pimg, plte_bytes=b"")[0], "PLTE")
    # PLTE in a grey image: ignored (libpng benign)
    add("plte_in_grey", build_png(img, plte_bytes=bytes(9))[0], "OK", warn=W["IGNORED"])
    cases[-1].data = True
    cases[-1].img = img
    # tRNS longer than PLTE: discarded whole (libpng), flagged
    t_img = Img(8, 2, 3, 2, 0, [[(x % 4,) for x in range(8)] for _ in range(2)], pal)
    add("trns_longer_than_plte", build_png(t_img, trns_bytes=bytes([1, 2, 3, 4, 5]))[0], "OK",
        warn=W["IGNORED"])
    cases[-1].data = True
    cases[-1].img = Img(8, 2, 3, 2, 0, t_img.samples, pal)       # expected: opaque
    # a palette index past PLTE: black, opaque (libpng), flagged
    x_img = Img(8, 1, 3, 2, 0, [[(x % 4,) for x in range(8)]], pal[:3])
    add("index_past_plte", build_png(x_img)[0], "OK", warn=W["INDEX"])
    cases[-1].data = True
    cases[-1].img = x_img
    # filter byte 5
    bad_payload = bytearray(payload)
    bad_payload[21 * 3] = 5
    add("filter5", with_z(zlib.compress(bytes(bad_payload))), "FILTER")
    # image data: short (the zlib stream ends early) / long (extra inflated bytes)
    add("image_short", with_z(zlib.compress(payload[:-7])), "SHORT", stricter=True,
        why="libpng: benign 'Not enough image data'")
    add("image_long", with_z(zlib.compress(payload + b"\0" * 30)), "OK", warn=W["LONG"])
    cases[-1].data = True
    cases[-1].img = img
    cases[-1].exp_payload = payload + b"\0" * 30
    # bytes after the zlib stream inside IDAT: flagged, image shown
    add("zlib_extra", with_z(zlib.compress(payload) + b"\x01\x02\x03"), "OK", warn=W["ZEXTRA"])
    cases[-1].data = True
    cases[-1].img = img
    # the zlib stream truncated (IDAT ends before it)
    add("zlib_truncated", with_z(zlib.compress(payload)[:-9]), "ZSHORT")
    # the input ends before IEND (in_last early)
    add("input_truncated", png[:-20], "TRUNC")
    add("input_truncated_in_sig", png[:5], "TRUNC")
    # zlib header
    zc = zlib.compress(payload)
    add("zhdr_check", with_z(bytes([zc[0], zc[1] ^ 1]) + zc[2:]), "ZCHECK")
    add("zhdr_method", with_z(bytes([0x79, next(f for f in range(256) if (0x79 * 256 + f) % 31 == 0)]) + zc[2:]), "ZMETHOD")
    add("zhdr_window", with_z(bytes([0x88, next(f for f in range(256) if (0x88 * 256 + f) % 31 == 0)]) + zc[2:]), "ZWINDOW")
    add("zhdr_dict", with_z(bytes([0x78, next(f for f in range(32, 256) if f & 0x20 and (0x78 * 256 + f) % 31 == 0)]) + zc[2:]), "ZDICT")
    add("adler", with_z(zc[:-1] + bytes([zc[-1] ^ 1])), "ADLER")
    # DEFLATE: each defect alone
    toks = lz(payload)

    def zcase(name, raw, code, why=""):
        z = zwrap(raw, payload)
        add(name, with_z(z), code, why=why)

    bw = BitWriter()
    bw.bits(1, 1)
    bw.bits(3, 2)
    bw.bits(0, 16)
    zcase("btype3", bw.data(), "BTYPE")
    bw = BitWriter()
    block_stored(bw, payload, 1, nlen_xor=0xFFFE)
    zcase("stored_nlen", bw.data(), "STORED")
    bw = BitWriter()
    block_dynamic(bw, toks, 1, hlit=287 + 0)
    zcase("hlit287", bw.data(), "NSYMS")
    bw = BitWriter()
    ll, dl = block_dynamic(BitWriter(), toks, 1)
    block_dynamic(bw, toks, 1, llens=ll, dlens=dl, hdist=31)
    zcase("hdist31", bw.data(), "NSYMS")
    # code-length code over-subscribed / incomplete
    seq = cl_encode(ll[:257] + dl[:1])
    bw = BitWriter()
    cl = [0] * 19
    for sym, _, _ in seq:
        cl[sym] = 1
    block_dynamic(bw, toks, 1, llens=ll, dlens=dl, cl_lens=[1 if cl[i] else 0 for i in range(19)])
    zcase("clcode_oversubscribed", bw.data(), "CLSET")
    cf = [0] * 19
    for sym, _, _ in cl_encode(ll + dl[:max(1, max([i + 1 for i, v in enumerate(dl) if v] or [1]))]):
        cf[sym] += 1
    cll = huff_lengths(cf, 7)
    incomplete = [v + 1 if v else 0 for v in cll]       # every code one bit longer
    if max(incomplete) <= 7:
        bw = BitWriter()
        block_dynamic(bw, toks, 1, llens=ll, dlens=dl, cl_lens=incomplete)
        zcase("clcode_incomplete", bw.data(), "CLSET")
    # repeat 16 first; repeat past the end
    bw = BitWriter()
    nd = max(1, max([i + 1 for i, v in enumerate(dl) if v] or [1]))
    nl = max(257, max(i for i, v in enumerate(ll) if v) + 1)
    seq = [(16, 0, 2)] + cl_encode(ll[:nl] + dl[:nd])
    block_dynamic(bw, toks, 1, llens=ll, dlens=dl, cl_seq=seq)
    zcase("repeat16_first", bw.data(), "REPEAT")
    seq = cl_encode(ll[:nl] + dl[:nd])
    seq = seq[:-1] + [(18, 127, 7)]
    bw = BitWriter()
    block_dynamic(bw, toks, 1, llens=ll, dlens=dl, cl_seq=seq)
    zcase("repeat_overflow", bw.data(), "REPEAT")
    # no end-of-block code
    ll2 = list(ll)
    ll2[256] = 0
    syms = tok_syms(toks)
    lf = [0] * 286
    for s_ in syms:
        lf[s_[0]] += 1
    ll2 = huff_lengths(lf)
    ll2[256] = 0
    bw = BitWriter()
    block_dynamic(bw, None, 1, llens=ll2, dlens=dl, raw_syms=syms)
    zcase("no_eob", bw.data(), "NOEOB")
    # literal/length set over-subscribed / incomplete (not a lone 1-bit code)
    ll3 = list(ll)
    ll3[0] = 1
    ll3[1] = 1
    ll3[2] = 1
    bw = BitWriter()
    block_dynamic(bw, None, 1, llens=ll3, dlens=dl, raw_syms=[(0,), (256,)])
    zcase("litset_oversubscribed", bw.data(), "LITSET")
    ll4 = [0] * 286
    ll4[256] = 2
    ll4[0] = 2
    bw = BitWriter()
    block_dynamic(bw, None, 1, llens=ll4, dlens=[0] * 30, raw_syms=[(0,), (256,)])
    zcase("litset_incomplete", bw.data(), "LITSET")
    dl2 = [0] * 30
    dl2[0] = 2
    dl2[3] = 2
    bw = BitWriter()
    block_dynamic(bw, toks, 1, llens=ll, dlens=dl2, raw_syms=[(0,), (256,)])
    zcase("distset_incomplete", bw.data(), "DISTSET")
    dl3 = [1] * 3 + [0] * 27
    bw = BitWriter()
    block_dynamic(bw, toks, 1, llens=ll, dlens=dl3, raw_syms=[(0,), (256,)])
    zcase("distset_oversubscribed", bw.data(), "DISTSET")
    # fixed block: literal/length 286 and 287, distance 30 and 31
    for sym in (286, 287):
        bw = BitWriter()
        block_fixed(bw, None, 1, raw_syms=[(0,), (sym, 0, 0, 0, 0, 0), (256,)])
        zcase("fixed_lit%d" % sym, bw.data(), "LITCODE")
    for ds in (30, 31):
        bw = BitWriter()
        block_fixed(bw, None, 1, raw_syms=[(0,), (0,), (257, 0, 0, ds, 0, 0), (256,)])
        zcase("fixed_dist%d" % ds, bw.data(), "DISTCODE")
    # a match with an empty distance tree
    lf = [0] * 286
    lf[0] = 1
    lf[256] = 1
    lf[257] = 1
    ll5 = huff_lengths(lf)
    bw = BitWriter()
    block_dynamic(bw, None, 1, llens=ll5, dlens=[0] * 30,
                  raw_syms=[(0,), (257, 0, 0, 0, 0, 0), (256,)])
    zcase("dist_empty_used", bw.data(), "DISTCODE")
    # distance too far back: first symbol is a match
    bw = BitWriter()
    block_fixed(bw, [("lit", 1), ("match", 3, 2)], 1)
    zcase("far_back", bw.data(), "FAR")
    # ---- the stream-order rule (design-defined: libpng reads whole chunks, so it may
    # name the CRC / the truncation first). A chunk-level verdict waits until what inflate
    # was handed is decoded (png_chunks C_PEND); both cases go RED if it does not.
    # (a) the unit ends ON the byte inflate refuses: BTYPE 3, not E_TRUNC
    z = bytes([0x78, 0x01, 0x07]) + bytes(20)
    full = build_png(img, zstream=z)[0]
    k = full.index(b"IDAT") + 4 + 2                     # the 0x07 byte
    add("pend_trunc_on_inflate_error", full[:k + 1], "BTYPE", stricter=True,
        why="stream order: the data error is in the last byte the unit carries")
    # (b) the IDAT's last byte completes a too-far distance's 13 extra bits (eight of
    # them in that byte: inflate is busy ~10 cycles after taking it) and the chunk's
    # CRC is bad: E_FAR, not E_CRC
    bw = BitWriter()
    block_fixed(bw, None, 1, raw_syms=[(0,), (200,), (201,), (202,), (203,),
                                       (257, 0, 0, 29, 8191, 13)])
    raw = bw.data()
    if bw.n != 0:
        raise GoldenError("pend_idat_crc_after_far: the extra bits do not end on a byte")
    zf = bytes([0x78, 0x01]) + raw
    good = build_png(img, zstream=zf)[0]
    j = good.index(b"IDAT") - 4
    ln, = struct.unpack(">I", good[j:j + 4])
    bad = bytearray(good)
    bad[j + 8 + ln + 3] ^= 1                            # the IDAT CRC
    add("pend_idat_crc_after_far", bytes(bad), "FAR", stricter=True,
        why="stream order: the inflate error is in the chunk's data, before its CRC")
    # far back after a stored block boundary (dist = output + 1)
    bw = BitWriter()
    block_stored(bw, payload[:100], 0)
    block_fixed(bw, [("match", 3, 101)], 1)
    zcase("far_back_101", bw.data(), "FAR")
    return cases


# =========================================================================================
# goldens
# =========================================================================================
def idat_of(png):
    """The zlib stream: the payloads of the first run of consecutive IDAT chunks (the
    data ends at the first other chunk, as for the RTL and libpng)."""
    o = 8
    z = bytearray()
    seen = False
    while o + 8 <= len(png):
        ln, = struct.unpack(">I", png[o:o + 4])
        t = png[o + 4:o + 8]
        if t == b"IDAT":
            z += png[o + 8:o + 8 + ln]
            seen = True
        elif seen or t == b"IEND":
            break
        o += 12 + ln
    return bytes(z)


def strip_ancillary(png):
    """The PNG without its ancillary chunks (PIL refuses a bad ancillary CRC; palette
    indices never depend on an ancillary chunk)."""
    o = 8
    out = bytearray(png[:8])
    while o + 12 <= len(png):
        ln, = struct.unpack(">I", png[o:o + 4])
        if png[o + 4] & 0x20 == 0:
            out += png[o:o + 12 + ln]
        o += 12 + ln
    return bytes(out)


def expected_pixels(case, hd, px16):
    """-> (pix words in emission order, raw bytes, raw masks) from libpng's pixels (and
    PIL's palette indices for type 3)."""
    w, h, ct, d, il = hd["w"], hd["h"], hd["ctype"], hd["depth"], hd["interlace"]
    ch = CHANNELS[ct]
    idx = None
    if ct == 3:
        from PIL import Image
        im = Image.open(io.BytesIO(strip_ancillary(case.png)))   # indices only
        im.load()
        if im.mode != "P":
            raise GoldenError("%s: PIL mode %s for a palette image" % (case.name, im.mode))
        idx = im.tobytes()
    top = (1 << d) - 1
    pix = []
    raw = bytearray()
    mask = bytearray()
    for p, x0, y0, dx, dy, pw, ph in passes(w, h, il):
        for j in range(ph):
            y = y0 + j * dy
            samples = []
            for i in range(pw):
                x = x0 + i * dx
                r, g, b, a = px16[y * w + x]
                pix.append((x, y, r >> 8, g >> 8, b >> 8, a >> 8))
                if ct == 3:
                    samples.append(idx[y * w + x])
                elif d == 16:
                    samples.extend((r, g, b, a)[k] for k in {0: (0,), 2: (0, 1, 2), 4: (0, 3), 6: (0, 1, 2, 3)}[ct])
                elif d == 8:
                    samples.extend(((r, g, b, a)[k] >> 8) for k in {0: (0,), 2: (0, 1, 2), 4: (0, 3), 6: (0, 1, 2, 3)}[ct])
                else:
                    samples.append((r * top + 32767) // 65535)
            rb = pack_row(samples, d)
            raw += rb
            nbits = pw * ch * d
            for k in range(len(rb)):
                left = nbits - 8 * k
                mask.append(0xFF if left >= 8 else (0xFF << (8 - left)) & 0xFF)
    return pix, bytes(raw), bytes(mask)


def cross_check(case, hd, px16):
    """PIL (where right) and ffmpeg (16-bit types) must agree with libpng."""
    ct, d = hd["ctype"], hd["depth"]
    grey_key_low = ct == 0 and d < 8 and b"tRNS" in case.png
    ignored_trns = bool(case.warn & W["IGNORED"]) and ct == 3
    anc_crc = bool(case.warn & W["ANC_CRC"])        # PIL refuses any CRC error
    if d <= 8 and not grey_key_low and not ignored_trns and not anc_crc:
        p, _ = pil_rgba(case.png)
        want = [tuple(v >> 8 for v in q) for q in px16]
        if p != want:
            i = next(k for k in range(len(p)) if p[k] != want[k])
            raise GoldenError("%s: PIL disagrees with libpng at pixel %d: %s vs %s" % (case.name, i, p[i], want[i]))
        return "pil"
    if d == 16:
        f = ffmpeg_rgba64(case.png)
        if f != px16:
            i = next((k for k in range(min(len(f), len(px16))) if f[k] != px16[k]), min(len(f), len(px16)))
            raise GoldenError("%s: ffmpeg disagrees with libpng at pixel %d" % (case.name, i))
        return "ffmpeg"
    return "libpng-only"


def libpng_code(msg):
    """libpng's fatal message -> our code, where it names one (else None)."""
    if msg.startswith("IDAT: ") and msg[6:] in ZMSG:
        return ZMSG[msg[6:]]
    if msg.endswith("CRC error"):
        return "CRC"
    return None


def check_verdict(case):
    """The expected verdict against the oracle that owns it."""
    v, hd, px, warns = libpng(case.png)
    if v == "ERR" and case.err != "OK" and not case.stricter:
        lc = libpng_code(hd)
        if lc is not None and lc != case.err:
            raise GoldenError("%s: expected %s, libpng says %r" % (case.name, case.err, hd))
    z = idat_of(case.png)
    if case.err == "OK":
        if v != "OK":
            raise GoldenError("%s: expected a valid image, libpng: %s" % (case.name, hd))
        return v, hd, px, warns
    if case.err in ZMSG.values() and case.err not in ("ZSHORT",):
        zv = zlib_verdict(z)
        if zv[0] != "ERR" or zv[1] != case.err:
            raise GoldenError("%s: expected zlib %s, zlib says %s" % (case.name, case.err, zv[1] if zv[0] == "ERR" else "OK"))
        try:
            inflate_ref.inflate_zlib(z)
            raise GoldenError("%s: inflate_ref accepts what zlib refuses" % case.name)
        except inflate_ref.InflateError as e:
            if ZMSG.get(str(e)) != case.err:
                raise GoldenError("%s: inflate_ref says %r, zlib %s" % (case.name, str(e), case.err))
    if case.err == "ZSHORT":
        if zlib_verdict(z)[0:2] != ("ERR", "ZSHORT"):
            raise GoldenError("%s: zlib does not see a truncated stream" % case.name)
    if case.stricter:
        return v, hd, px, warns                     # libpng may accept: documented
    if v == "OK" and not (case.err == "SHORT"):
        raise GoldenError("%s: expected %s, libpng accepts it (warnings %s)" % (case.name, case.err, warns))
    return v, hd, px, warns


def write_hex(path, words, width):
    fmt = "%%0%dx\n" % (width // 4)
    with open(path, "w") as f:
        for w_ in words:
            f.write(fmt % w_)


def emit(case, outdir, stats):
    v, hd, px, warns = check_verdict(case)
    stem = os.path.join(outdir, case.name)
    write_hex(stem + ".hex", case.png, 8)
    z = idat_of(case.png)
    n_inf = n_raw = n_pix = 0
    h = dict(w=0, h=0, ctype=0, depth=0, interlace=0)
    if case.data:
        zv = zlib_verdict(z)
        if zv[0] != "OK":
            raise GoldenError("%s: data case but zlib refuses: %s" % (case.name, zv[1]))
        inf = zv[1]
        if case.exp_payload is not None and inf != case.exp_payload:
            raise GoldenError("%s: inflated payload differs from the writer's" % case.name)
        pix, raw, mask = expected_pixels(case, hd, px)
        stats["xcheck_" + cross_check(case, hd, px)] += 1
        write_hex(stem + ".inf.hex", inf, 8)
        write_hex(stem + ".raw.hex", raw, 8)
        write_hex(stem + ".rmask.hex", mask, 8)
        write_hex(stem + ".pix.hex",
                  [(x << 48) | (y << 32) | (r << 24) | (g << 16) | (b << 8) | a for x, y, r, g, b, a in pix], 64)
        n_inf, n_raw, n_pix = len(inf), len(raw), len(pix)
        h = hd
        # the image the case was built from, where known, must be what libpng decoded
        if case.img is not None and case.img.ctype in (0, 2, 4, 6) and not (case.warn & W["IGNORED"]):
            _check_samples(case, hd, px)
    else:
        for ext in (".inf.hex", ".raw.hex", ".rmask.hex", ".pix.hex"):
            write_hex(stem + ext, [0], 8)
    meta = [E[case.err], case.warn, h["w"], h["h"], h["ctype"], h["depth"], h["interlace"],
            len(case.png), n_inf, n_raw, n_pix, 1 if case.data else 0]
    write_hex(stem + ".meta.hex", meta, 32)
    stats["cases"] += 1
    stats["inflated"] += n_inf
    return stem


def _check_samples(case, hd, px):
    img = case.img
    top = (1 << img.depth) - 1
    for y in range(img.h):
        for x in range(img.w):
            s = img.samples[y][x]
            r, g, b, a = px[y * img.w + x]
            got = {0: (r,), 2: (r, g, b), 4: (r, a), 6: (r, g, b, a)}[img.ctype]
            want = tuple(v * 65535 // top for v in s)
            if got != want:
                raise GoldenError("%s: libpng pixel (%d,%d) %s, image %s" % (case.name, x, y, got, want))


def corpus_cases(cache, sel, rng_seed=5):
    import png_corpus
    out = []
    by_disc = {}
    for disc, u in png_corpus.iter_cache(cache):
        by_disc.setdefault(disc, []).append(u)
    for disc, us in sorted(by_disc.items()):
        pick = us
        if sel == "sample":
            big = max(us, key=lambda u: os.path.getsize(u["path"]))
            pick = [big]
            if re.match(r"^(Akira|Family_Guy)", disc):
                pick = us[:20] + ([big] if big not in us[:20] else [])
        for u in pick:
            with open(u["path"], "rb") as f:
                png = f.read()
            c = Case("corpus_%s_%s" % (disc, os.path.splitext(u["file"])[0]), png)
            out.append(c)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(ROOT, "bench/umd/fixtures/gen/png"))
    ap.add_argument("--list", default="cases")
    ap.add_argument("--corpus")
    ap.add_argument("--corpus-sel", default="sample", choices=("sample", "all"))
    ap.add_argument("--only")
    ap.add_argument("--no-synth", action="store_true")
    a = ap.parse_args(argv)
    build_oracle()
    os.makedirs(a.out, exist_ok=True)
    cases = []
    cov = Counter()
    if not a.no_synth:
        sc, cov = synth_cases()
        cases += sc + invalid_cases()
    if a.corpus:
        cases += corpus_cases(a.corpus, a.corpus_sel)
    if a.only:
        cases = [c for c in cases if re.search(a.only, c.name)]
    names = Counter(c.name for c in cases)
    dup = [n for n, k in names.items() if k > 1]
    if dup:
        raise GoldenError("duplicate case names: %s" % dup[:5])
    if not a.no_synth and not a.only:
        # every DEFLATE / filter / transparency feature the mutations target is reached
        for z_case in cases:
            if z_case.data:
                try:
                    _, inf = inflate_ref.inflate_zlib(idat_of(z_case.png))
                    cov.update({k: v for k, v in inf.cov.items() if k != "max_dist"})
                except inflate_ref.InflateError:
                    pass
        need = ("stored", "fixed", "dynamic", "stored_len0", "stored_len65535", "dist32768",
                "dist_gt16k_differs", "dist_extra_nonzero", "len_extra_nonzero", "len258_code285",
                "len258_code284", "overlap_dist1", "overlap_dist_gt1", "match_into_earlier_block",
                "multi_block", "rep16", "rep17", "rep18", "rep16_across_lit_dist", "hlit286",
                "hdist30", "hclen19", "code_len15_table", "code_len15_decoded", "dist_single_code",
                "dist_empty", "avg_sum_gt255", "paeth_tie_ac", "paeth_tie_bc", "bpp8_left_nonzero",
                "bpp6_left_nonzero", "first_row_up_family", "pass_start_up_family_after_nonzero",
                "trns_key_hit", "trns_key16_lowbyte_miss", "trns_index_past_trns")
        miss = [k for k in need if not cov[k]]
        if miss:
            raise GoldenError("coverage not reached: %s" % miss)
    stats = Counter()
    stems = []
    for c in cases:
        stems.append(emit(c, a.out, stats))
    with open(os.path.join(a.out, a.list + ".txt"), "w") as f:
        for s in stems:
            f.write(os.path.relpath(s, ROOT) + "\n")
    print("png_golden: %d cases (%d valid, %d refused), %d inflated bytes; cross-checks %s"
          % (stats["cases"], sum(1 for c in cases if c.err == "OK"), sum(1 for c in cases if c.err != "OK"),
             stats["inflated"], {k[7:]: v for k, v in stats.items() if k.startswith("xcheck_")}))
    if not a.no_synth and not a.only:
        print("coverage: " + ", ".join("%s=%d" % (k, cov[k]) for k in sorted(cov) if k != "literal" and k != "match"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GoldenError as e:
        sys.exit("png_golden: FAIL: %s" % e)
