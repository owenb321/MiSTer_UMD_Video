#!/usr/bin/env python3
# =============================================================================
# umd_report.py -- a small, shareable repro bundle for a UMD Video core bug
# =============================================================================
# WHAT IT IS FOR
#
# Most bugs reported against the MiSTer UMD Video core happen on a disc image the
# maintainer does not own: "it plays the wrong title", "this disc cannot be
# played", "the menu does nothing when I press Cross". Diagnosing those needs the
# disc's STRUCTURE -- its navigation tables, its menu scripts, its stream headers --
# and none of its pictures or sound. A UMD image is 1-2 GB; the structure is a few
# hundred kilobytes.
#
# The bundle stores {LBA -> 2048-byte sector} at the sectors' ORIGINAL addresses.
# `unpack` writes them into a SPARSE file of the original size: every captured
# sector at its true offset, everything else zero. Every tool that walks an ISO by
# absolute LBA works on the reconstruction unchanged, and it is already shaped like
# a bench fixture.
#
# WHAT A BUNDLE HOLDS (docs/bug_reports.md, decisions R1-R4)
#
#   * the ISO9660 volume descriptors, path tables and directories;
#   * UMD_DATA.BIN, PARAM.SFO, PLAYLIST.UMD and every CLIPINF/*.CLP, whole;
#   * every RESOURCE/*.RCO (the disc menus) with its scripts, object tree and
#     animations byte-exact, and its MEDIA BLANKED: each image replaced in place by
#     a flat grey image of the same format and size (opaque inside the original's
#     alpha box, transparent outside), each sound kept as its header with silent
#     samples;
#   * the head of every STREAM/*.MPS (default 1,024 packs) with only its HEADERS
#     kept: pack / PES headers (the time stamps), the index packs, the H.264
#     parameter sets, SEI and access unit delimiters, each slice up to the end of
#     its slice header, each ATRAC3plus frame's 8-byte header, each subtitle's
#     timing / position header with a blank picture of the same size. Picture and
#     sound payloads are zero. ANYTHING NOT POSITIVELY CLASSIFIED IS ZERO: a bundle
#     can lose a header, never leak a payload.
#
# A bare .MPS file is accepted too (the same stream scrub, no tables).
#
# THE CONTENT GUARANTEE IS ENFORCED, NOT PROMISED
#
# audit() walks the finished bundle (read back from the zip) before it is handed
# over, and refuses it -- naming the file, the sector and the stream -- unless every
# RCO image is flat, every sound silent, no media region byte lies outside an
# entry, every slice is zero past its header, and, independent of any parser, no
# pack carries a long run of non-zero payload bytes or more non-zero payload bytes
# than a fixed ceiling. Never relax this "just for one bug".
#
# PRIVACY: the manifest records the image's BASENAME only -- no path, user name or
# host. The bundle is summarised on stdout after it is written.
#
# This file is deliberately SELF-CONTAINED (stdlib only; it duplicates a small
# ISO9660 walk, a PNG reader / writer, a flat JPEG writer and the H.264 header
# parse rather than importing the repository's tools) because a reporter runs this
# ONE file -- from the release zip or the repository -- without a checkout.
#
# Usage (reporter, on a PC, with their own image):
#   python3 umd_report.py disc.iso
#   python3 umd_report.py disc.iso --core-version "UMD v0.1.0 261006" --note "Cross does nothing"
#
# Usage (maintainer, on a received bundle):
#   python3 tools/umd_report.py info   umdreport-*.zip
#   python3 tools/umd_report.py audit  umdreport-*.zip
#   python3 tools/umd_report.py unpack umdreport-*.zip -o repro.iso
#   python3 tools/umd_playlist.py repro.iso
# =============================================================================

import argparse
import bisect
import datetime
import io
import json
import os
import re
import struct
import sys
import zipfile
import zlib

SEC = 2048
SCHEMA = 1
TOOL_VERSION = "1"
DEFAULT_PACKS = 1024           # the head of each .MPS: ~2 MB of sectors, a few seconds

# The parser-free ceilings of the audit (section 4 of docs/bug_reports.md): in each
# captured .MPS pack, over the payload bytes of video / private-1 PES packets, the
# longest run of non-zero bytes and the count of non-zero bytes. A kept header is
# short (the longest seen: an SPS with its VUI, a picture timing SEI); a leaked
# slice or audio frame is long runs of entropy-coded bytes.
MAX_NONZERO_RUN = 160
MAX_NONZERO_PER_PACK = 1536    # the library's largest: 889 (a still clip's first pack); a leaked pack ~2,000

BUNDLE_README = """\
MiSTer UMD Video core -- bug repro bundle
=========================================

This archive holds the STRUCTURE of one UMD Video disc image, at the sectors'
original addresses: the filesystem, the navigation tables (PARAM.SFO,
PLAYLIST.UMD, the clip information files), the disc menus' scripts and layout
with every image replaced by a flat grey box and every sound silenced, and the
first packs of each video stream with only their headers kept (time stamps,
parameter sets, slice and frame headers).

It holds NO watchable picture and NO audible sound. Every sector was checked
before the archive was written (umd_report.py audit). It can be checked again:

    python3 umd_report.py audit <this zip>

manifest.json says what was captured and from which image (its file name only).
"""


class ReportError(Exception):
    pass


class AuditError(Exception):
    pass


def be16(b, o):
    return (b[o] << 8) | b[o + 1]


def be32(b, o):
    return struct.unpack(">I", bytes(b[o:o + 4]))[0]


def le16(b, o):
    return b[o] | (b[o + 1] << 8)


def le32(b, o):
    return struct.unpack("<I", bytes(b[o:o + 4]))[0]


# =============================================================================
# The image: a file, or (for verify / audit / unpack) the bundle's sectors
# =============================================================================
class FileImage(object):
    def __init__(self, path):
        self.f = open(path, "rb")
        self.size = os.path.getsize(path)

    def sec(self, lba):
        self.f.seek(lba * SEC)
        return self.f.read(SEC).ljust(SEC, b"\0")

    def close(self):
        self.f.close()


class SparseImage(object):
    """The bundle's sectors; everything else reads as zero."""

    def __init__(self, sectors, size):
        self.sectors, self.size = sectors, size

    def sec(self, lba):
        return self.sectors.get(lba, b"\0" * SEC)

    def close(self):
        pass


def read_span(img, lba, nbytes):
    n = (nbytes + SEC - 1) // SEC
    return b"".join(img.sec(lba + i) for i in range(n))[:nbytes]


# =============================================================================
# ISO9660 (ECMA-119): the volume descriptors, path tables and every directory
# =============================================================================
class Iso(object):
    def __init__(self, img):
        self.img = img
        self.files = {}            # path -> (lba, size, is_dir)
        self.meta = set()          # LBAs of volume descriptors, path tables, directories
        self.multi_extent = []
        lba = 16
        pvd = None
        while True:
            if lba >= 16 + 32:
                raise ReportError("no volume descriptor terminator: not an ISO9660 image")
            d = img.sec(lba)
            if d[1:6] != b"CD001":
                raise ReportError("not an ISO9660 image (no CD001 at sector %d)" % lba)
            self.meta.add(lba)
            if d[0] == 1 and pvd is None:
                pvd = d
            if d[0] == 255:
                break
            lba += 1
        if pvd is None:
            raise ReportError("no primary volume descriptor")
        if le16(pvd, 128) != SEC:
            raise ReportError("logical block size %d, not 2048" % le16(pvd, 128))
        self.system_id = pvd[8:40].decode("latin-1").strip()
        self.volume_id = pvd[40:72].decode("latin-1").strip()
        pt_size = le32(pvd, 132)
        for off, endian in ((140, "<"), (144, "<"), (148, ">"), (152, ">")):
            plba = struct.unpack(endian + "I", pvd[off:off + 4])[0]
            if plba:
                for i in range((pt_size + SEC - 1) // SEC):
                    self.meta.add(plba + i)
        root_lba, root_len = le32(pvd, 158), le32(pvd, 166)
        self.files[""] = (root_lba, root_len, True)
        self._walk("", root_lba, root_len, 0)

    def _records(self, dlba, dlen):
        out = []
        for s in range((dlen + SEC - 1) // SEC):
            self.meta.add(dlba + s)
            buf = self.img.sec(dlba + s)
            p = 0
            while p < SEC:
                rl = buf[p]
                if rl == 0:
                    break
                if rl < 34 or p + rl > SEC:
                    raise ReportError("bad directory record at sector %d" % (dlba + s))
                out.append((buf[p + 33:p + 33 + buf[p + 32]], le32(buf, p + 2), le32(buf, p + 10), buf[p + 25]))
                p += rl
        return out

    def _walk(self, prefix, dlba, dlen, depth):
        if depth > 8:
            raise ReportError("directory depth above 8 at %s" % prefix)
        subdirs, pending = [], None
        for nm, lba, size, fl in self._records(dlba, dlen):
            if nm in (b"\x00", b"\x01"):
                continue
            name = nm.decode("latin-1").upper().split(";")[0].rstrip(".")
            path = prefix + "/" + name
            if fl & 2:
                self.files[path] = (lba, size, True)
                subdirs.append((path, lba, size))
                continue
            if fl & 0x80 or pending is not None:          # multi-extent (ECMA-119 9.1.6)
                if pending is None:
                    pending = (path, [])
                if pending[0] != path:
                    raise ReportError("multi-extent file %s has no final record" % pending[0])
                pending[1].append((lba, size))
                if fl & 0x80:
                    continue
                parts = pending[1]
                pending = None
                self.multi_extent.append(path)
                pos = parts[0][0]
                for plba, psize in parts:
                    if plba != pos:
                        raise ReportError("multi-extent file %s is not contiguous" % path)
                    pos = plba + psize // SEC
                self.files[path] = (parts[0][0], sum(p[1] for p in parts), False)
                continue
            self.files[path] = (lba, size, False)
        for path, lba, size in subdirs:
            self._walk(path, lba, size, depth + 1)

    def read(self, path):
        lba, size, _ = self.files[path]
        return read_span(self.img, lba, size)


# =============================================================================
# PNG: read (dimensions, the alpha box, flatness) and write a flat one
# =============================================================================
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def png_chunks(data):
    if data[:8] != PNG_SIG:
        raise ReportError("not a PNG")
    p, out = 8, []
    while p + 8 <= len(data):
        n = be32(data, p)
        typ = bytes(data[p + 4:p + 8])
        out.append((typ, bytes(data[p + 8:p + 8 + n])))
        p += 12 + n
        if typ == b"IEND":
            break
    return out


def png_ihdr(data):
    ch = png_chunks(data)
    if not ch or ch[0][0] != b"IHDR":
        raise ReportError("PNG without IHDR")
    w, h, depth, ct, _cm, _fm, il = struct.unpack(">IIBBBBB", ch[0][1][:13])
    return w, h, depth, ct, il, ch


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _unfilter(raw, pos, w, h, bpp_bits):
    """Rows of one (sub)image; returns (rows, next position)."""
    stride = (w * bpp_bits + 7) // 8
    bpp = max(1, bpp_bits // 8)
    prev = bytearray(stride)
    rows = []
    for _ in range(h):
        ft = raw[pos]
        cur = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ft == 1:
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
        elif ft == 2:
            cur = bytearray((x + y) & 0xFF for x, y in zip(cur, prev))
        elif ft == 3:
            for i in range(stride):
                cur[i] = (cur[i] + (((cur[i - bpp] if i >= bpp else 0) + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + _paeth(a, prev[i], c)) & 0xFF
        elif ft != 0:
            raise ReportError("PNG filter type %d" % ft)
        rows.append(cur)
        prev = cur
    return rows, pos


ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _visible(row, w, ct, depth, trns):
    """One unfiltered row -> bytes, one per pixel, non-zero where its alpha is."""
    nch = CHANNELS[ct]
    if ct in (4, 6):
        k = nch - 1
        if depth == 8:
            return bytes(row[k::nch])[:w]
        return bytes(a | b for a, b in zip(row[2 * k::2 * nch], row[2 * k + 1::2 * nch]))[:w]
    if depth == 8:
        idx = bytes(row[:w * nch])
    elif depth == 16:
        idx = None
    else:
        per = 8 // depth
        idx = bytes((row[i // per] >> (8 - depth * (i % per + 1))) & ((1 << depth) - 1) for i in range(w))
    if ct == 3:
        tbl = bytes((trns[i] if i < len(trns) else 255) for i in range(256))
        return idx.translate(tbl)
    # grey / RGB with a tRNS key: transparent where the sample(s) equal it
    step = nch * (2 if depth == 16 else 1)
    out = bytearray(w)
    for x in range(w):
        if depth == 16:
            s = tuple(be16(row, 2 * (x * nch + c)) for c in range(nch))
        elif depth == 8:
            s = tuple(idx[x * nch + c] for c in range(nch))
        else:
            s = (idx[x],)
        key = tuple(be16(trns, 2 * c) for c in range(nch))
        out[x] = 0 if s == key else 1
    return bytes(out)


def png_alpha_box(data):
    """The box of the pixels with non-zero alpha, (x0, y0, x1, y1) inclusive, or None
    (the engine draws nothing of an image without one: menu.c's texel box)."""
    w, h, depth, ct, il, ch = png_ihdr(data)
    if ct not in CHANNELS:
        raise ReportError("PNG colour type %d" % ct)
    trns = b"".join(c[1] for c in ch if c[0] == b"tRNS")
    if ct in (0, 2) and not trns or ct == 3 and (not trns or min(trns) == 255):
        return (0, 0, w - 1, h - 1)                         # no alpha: the whole image
    raw = zlib.decompress(b"".join(c[1] for c in ch if c[0] == b"IDAT"))
    pos = 0
    x0 = y0 = None
    x1 = y1 = -1
    for px, py, dx, dy in (ADAM7 if il else ((0, 0, 1, 1),)):
        pw, ph = (w - px + dx - 1) // dx, (h - py + dy - 1) // dy
        if pw <= 0 or ph <= 0:
            continue
        rows, pos = _unfilter(raw, pos, pw, ph, CHANNELS[ct] * depth)
        for j, row in enumerate(rows):
            v = _visible(row, pw, ct, depth, trns)
            lead = len(v) - len(v.lstrip(b"\0"))
            if lead == len(v):
                continue
            a, b = px + lead * dx, px + (len(v.rstrip(b"\0")) - 1) * dx
            y = py + j * dy
            x0 = a if x0 is None else min(x0, a)
            y0 = y if y0 is None else min(y0, y)
            x1, y1 = max(x1, b), max(y1, y)
    return None if x0 is None else (x0, y0, x1, y1)


def _chunk(typ, body):
    return struct.pack(">I", len(body)) + typ + body + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF)


GREY = (128, 128, 128)


def png_flat(w, h, box, depth=1, alpha=255):
    """A palette PNG of w x h: index 1 (grey, `alpha`) inside `box`, index 0 (transparent)
    outside; box None = all transparent. An opaque box over the whole image is one palette
    entry and no tRNS (the smallest form: Hackers' 113-byte 214 x 120 menu image)."""
    per = 8 // depth
    if alpha == 255 and box == (0, 0, w - 1, h - 1):
        ihdr = struct.pack(">IIBBBBB", w, h, depth, 3, 0, 0, 0)
        return (PNG_SIG + _chunk(b"IHDR", ihdr) + _chunk(b"PLTE", bytes(GREY))
                + _chunk(b"IDAT", zlib.compress((b"\0" + bytes((w + per - 1) // per)) * h, 9)) + _chunk(b"IEND", b""))
    stride = (w + per - 1) // per
    out_row = b"\0" + bytes(stride)
    if box is None:
        raw = out_row * h
    else:
        x0, y0, x1, y1 = box
        bits = bytearray(stride)
        for x in range(x0, x1 + 1):
            bits[x // per] |= 1 << (8 - depth * (x % per + 1))
        in_row = b"\0" + bytes(bits)
        raw = out_row * y0 + in_row * (y1 - y0 + 1) + out_row * (h - 1 - y1)
    ihdr = struct.pack(">IIBBBBB", w, h, depth, 3, 0, 0, 0)
    return (PNG_SIG + _chunk(b"IHDR", ihdr) + _chunk(b"PLTE", bytes((0, 0, 0) + GREY))
            + _chunk(b"tRNS", bytes((0, alpha))) + _chunk(b"IDAT", zlib.compress(raw, 9)) + _chunk(b"IEND", b""))


def _inflate_all(data):
    d = zlib.decompressobj()
    out = d.decompress(data) + d.flush()
    if not d.eof or d.unused_data:
        raise ReportError("IDAT is not one whole zlib stream")
    return out


def png_flat_check(data):
    """True when `data` is a png_flat() stand-in: its size, depth, alpha and box are read
    back from it, the stand-in for them is written afresh, and the two must have the same
    chunks in the same order with the same contents -- IDAT compared DECOMPRESSED, so a
    stand-in written by another zlib (the MiSTer's) passes. A silhouette, a second colour,
    an extra chunk or data after the zlib stream all fail."""
    try:
        w, h, depth, ct, il, ch = png_ihdr(data)
        if ct != 3 or il or depth not in (1, 2, 4, 8) or _png_end(data) != len(data):
            return False
        trns = [c[1] for c in ch if c[0] == b"tRNS"]
        alpha = trns[0][1] if trns and len(trns[0]) >= 2 else 255
        raw = _inflate_all(b"".join(c[1] for c in ch if c[0] == b"IDAT"))
        stride = 1 + (w * depth + 7) // 8
        rows = [raw[i:i + stride] for i in range(0, len(raw), stride)]
        inside = [y for y, r in enumerate(rows) if any(r)]
        box = None
        if inside:
            per = 8 // depth
            r = rows[inside[0]]
            xs = [x for x in range(w) if (r[1 + x // per] >> (8 - depth * (x % per + 1))) & ((1 << depth) - 1)]
            box = (xs[0], inside[0], xs[-1], inside[-1]) if xs else None
        for cand in (png_flat(w, h, box, depth, alpha), png_flat(w, h, (0, 0, w - 1, h - 1), depth, 255)):
            cc = png_chunks(cand)
            if [c[0] for c in cc] != [c[0] for c in ch]:
                continue
            if all(x[1] == y[1] for x, y in zip(cc, ch) if x[0] != b"IDAT") and \
                    _inflate_all(b"".join(c[1] for c in cc if c[0] == b"IDAT")) == raw:
                return True
        return False
    except Exception:
        return False


# =============================================================================
# JPEG: the dimensions, and a flat grey one (baseline, grey scale, every block DC 0)
# =============================================================================
def jpeg_dims(data):
    if data[:2] != b"\xff\xd8":
        raise ReportError("not a JPEG")
    p = 2
    while p + 4 <= len(data):
        if data[p] != 0xFF:
            raise ReportError("JPEG marker expected at %d" % p)
        m = data[p + 1]
        if m == 0xFF:
            p += 1
            continue
        if m in (0x01,) or 0xD0 <= m <= 0xD7:
            p += 2
            continue
        ln = be16(data, p + 2)
        if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            return be16(data, p + 7), be16(data, p + 5)          # (w, h)
        if m == 0xDA:
            break
        p += 2 + ln
    raise ReportError("JPEG without a frame header")


def jpeg_flat(w, h):
    """Every 8x8 block: DC difference 0 (code '0'), end of block (code '0'): mid grey."""
    def seg(m, body):
        return b"\xff" + bytes([m]) + struct.pack(">H", len(body) + 2) + body
    dqt = seg(0xDB, b"\x00" + b"\x01" * 64)
    sof = seg(0xC0, b"\x08" + struct.pack(">HH", h, w) + b"\x01\x01\x11\x00")
    one = b"\x01" + b"\x00" * 15                                  # one code of length 1
    dht = seg(0xC4, b"\x00" + one + b"\x00" + b"\x10" + one + b"\x00")
    sos = seg(0xDA, b"\x01\x01\x00\x00\x3f\x00")
    nbits = 2 * ((w + 7) // 8) * ((h + 7) // 8)
    scan = bytearray(nbits // 8)
    if nbits % 8:
        scan.append((1 << (8 - nbits % 8)) - 1)                   # the last byte padded with 1s
    return b"\xff\xd8" + dqt + sof + dht + sos + bytes(scan) + b"\xff\xd9"


# =============================================================================
# RCO (the disc menus): the image and sound entries, and the media regions
# =============================================================================
H_SOUND, H_IMAGE = 3, 5
H_IMGDATA, H_SOUNDDATA, H_MODELDATA = 28, 30, 32


class Rco(object):
    """The header words, the image entries [(fmt, cmp, at, len)] and sound channels
    [(at, len)] as file offsets, and the media regions [(at, len)]."""

    def __init__(self, data):
        if len(data) < 16 + 4 * 37 or data[:4] != b"\0PRF":
            raise ReportError("not an RCO")
        self.comp = le32(data, 12)
        self.h = [le32(data, 16 + 4 * i) for i in range(37)]
        tree = data
        if self.comp >> 4:
            if (self.comp >> 4) != 1:
                raise ReportError("RCO tables packed with RLZ")
            lp, lu = le32(data, 0xA4), le32(data, 0xA8)
            tree = bytes(data[:0xA4]) + zlib.decompress(bytes(data[0xB0:0xB0 + lp]))
            if len(tree) != 0xA4 + lu:
                raise ReportError("RCO packed tables inflate to the wrong size")
        self.images, self.sounds = [], []
        for at, x in self._table(tree, self.h[H_IMAGE], 4):
            w0 = le32(tree, at + 0x28)
            ln, off = le32(tree, at + 0x2C), le32(tree, at + 0x30)
            self.images.append((w0 & 0xFFFF, w0 >> 16, self.h[H_IMGDATA] + off, ln))
        for at, x in self._table(tree, self.h[H_SOUND], 6):
            nch = le16(tree, at + 0x2A)
            for c in range(min(nch, (x - 12) // 8)):
                sz, off = le32(tree, at + 0x34 + 8 * c), le32(tree, at + 0x38 + 8 * c)
                if sz:
                    self.sounds.append((self.h[H_SOUNDDATA] + off, sz))
        self.regions = []
        for k in (H_IMGDATA, H_SOUNDDATA, H_MODELDATA):
            at, ln = self.h[k], self.h[k + 1]
            if at not in (0, 0xFFFFFFFF) and ln:
                self.regions.append((at, ln))

    @staticmethod
    def _table(tree, root, table):
        """The (offset, extra length) of each type-1 entry under a table's root entry."""
        if root in (0, 0xFFFFFFFF) or root + 0x28 > len(tree):
            return []
        if tree[root + 1] != table:
            raise ReportError("RCO table %d's root is not that table" % table)
        n = le32(tree, root + 16)
        at = root + 0x28
        out = []
        for _ in range(n):
            if at + 0x30 > len(tree):
                raise ReportError("RCO entry past the tables")
            tid, nxt, nsub = le16(tree, at), le32(tree, at + 20), le32(tree, at + 16)
            if (tid >> 8) != table or nsub:
                raise ReportError("RCO table %d holds an unexpected entry at 0x%x" % (table, at))
            if table == 4:
                x = nxt - 0x28 if nxt else 12 + (4 if le16(tree, at + 0x2A) else 0)
            else:
                x = 12 + 8 * max(2, le16(tree, at + 0x2A))
            if (tid & 0xFF) == 1:
                out.append((at, x))
            at = at + nxt if nxt else at + 0x28 + x
        return out


def blank_rco(data, stats):
    """The RCO with its media regions and every entry's bytes zeroed, then each image's
    flat stand-in and each sound's VAG header written back."""
    r = Rco(data)
    out = bytearray(data)
    for at, ln in r.regions:
        out[at:at + ln] = bytes(min(ln, max(0, len(out) - at)))
    for fmt, cmp, at, ln in r.images:
        out[at:at + ln] = bytes(min(ln, max(0, len(out) - at)))
    for at, ln in r.sounds:
        out[at:at + ln] = bytes(min(ln, max(0, len(out) - at)))
    for fmt, cmp, at, ln in r.images:
        src = bytes(data[at:at + ln])
        rep = None
        try:
            if cmp == 0 and fmt == 0:
                w, h = png_ihdr(src)[:2]
                rep = png_flat(w, h, png_alpha_box(src))
            elif cmp == 0 and fmt == 1:
                w, h = jpeg_dims(src)
                rep = jpeg_flat(w, h)
        except Exception:
            rep = None
        if rep is not None and len(rep) <= ln:
            out[at:at + len(rep)] = rep
            stats["images_blanked"] = stats.get("images_blanked", 0) + 1
        else:
            stats["images_zeroed"] = stats.get("images_zeroed", 0) + 1     # not drawn by the engine
    for at, ln in r.sounds:
        if data[at:at + 4] == b"VAGp" and ln >= 48:
            out[at:at + 48] = data[at:at + 48]
            stats["sounds_silenced"] = stats.get("sounds_silenced", 0) + 1
        else:
            stats["sounds_zeroed"] = stats.get("sounds_zeroed", 0) + 1
    return bytes(out)


def audit_rco(path, data):
    """Every image flat or zero, every sound's samples zero, no stray media byte."""
    r = Rco(data)
    covered = []
    for fmt, cmp, at, ln in r.images:
        img = data[at:at + ln]
        covered.append((at, ln))
        if not any(img):
            continue
        if fmt == 0 and img[:8] == PNG_SIG:
            end = _png_end(img)
            if not png_flat_check(img[:end]) or any(img[end:]):
                raise AuditError("%s: the image at 0x%x is not a flat stand-in" % (path, at))
        elif fmt == 1 and img[:2] == b"\xff\xd8":
            w, h = jpeg_dims(img)
            flat = jpeg_flat(w, h)
            if img[:len(flat)] != flat or any(img[len(flat):]):
                raise AuditError("%s: the JPEG at 0x%x is not a flat stand-in" % (path, at))
        else:
            raise AuditError("%s: the image at 0x%x is neither zero nor a flat stand-in" % (path, at))
    for at, ln in r.sounds:
        covered.append((at, ln))
        snd = data[at:at + ln]
        body = snd[48:] if snd[:4] == b"VAGp" else snd
        if any(body):
            raise AuditError("%s: the sound at 0x%x has non-zero samples" % (path, at))
    for at, ln in r.regions:
        mask = bytearray(ln)
        for cat, cln in covered:
            lo, hi = max(cat, at), min(cat + cln, at + ln)
            if lo < hi:
                mask[lo - at:hi - at] = b"\x01" * (hi - lo)
        for i in range(ln):
            if not mask[i] and at + i < len(data) and data[at + i]:
                raise AuditError("%s: a media byte outside every entry at 0x%x" % (path, at + i))


def _png_end(data):
    p = 8
    while p + 12 <= len(data):
        n = be32(data, p)
        typ = data[p + 4:p + 8]
        p += 12 + n
        if typ == b"IEND":
            return p
    return len(data)


# =============================================================================
# H.264: the parameter sets and the slice header's length
# =============================================================================
class Bits(object):
    def __init__(self, data):
        self.d, self.p = data, 0

    def bit(self):
        if self.p >= 8 * len(self.d):
            raise EOFError
        v = (self.d[self.p >> 3] >> (7 - (self.p & 7))) & 1
        self.p += 1
        return v

    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.bit()
        return v

    def ue(self):
        z = 0
        while self.bit() == 0:
            z += 1
            if z > 31:
                raise ReportError("exp-Golomb code too long")
        return (1 << z) - 1 + self.u(z)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


def rbsp_of(nal, limit=None):
    """(rbsp, epbs): the NAL's payload (of its first `limit` bytes) with the emulation
    prevention bytes removed, and for each one removed, how many rbsp bytes preceded it
    (rbsp byte k sits at NAL offset 1 + k + the number of those <= k)."""
    end = len(nal) if limit is None else min(len(nal), limit)
    seg = bytes(nal[1:end])
    if b"\x00\x00\x03" not in seg:
        return seg, []
    out, epbs, zeros = bytearray(), [], 0
    for b in seg:
        if zeros >= 2 and b == 3:
            epbs.append(len(out))
            zeros = 0
            continue
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out), epbs


def _skip_scaling(br, n):
    for i in range(n):
        if br.bit():
            size = 16 if i < 6 else 64
            last = nxt = 8
            for _ in range(size):
                if nxt:
                    nxt = (last + br.se() + 256) % 256
                last = nxt or last


HIGH = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)


def parse_sps(rbsp):
    br = Bits(rbsp)
    s = {"profile": br.u(8)}
    br.u(16)
    sid = br.ue()
    s["chroma"] = 1
    if s["profile"] in HIGH:
        s["chroma"] = br.ue()
        if s["chroma"] == 3:
            br.bit()
        br.ue()
        br.ue()
        br.bit()
        if br.bit():
            _skip_scaling(br, 12 if s["chroma"] == 3 else 8)
    s["log2_fn"] = br.ue() + 4
    s["poc_type"] = br.ue()
    if s["poc_type"] == 0:
        s["log2_poc"] = br.ue() + 4
    elif s["poc_type"] == 1:
        s["dpoc_zero"] = br.bit()
        br.se()
        br.se()
        for _ in range(br.ue()):
            br.se()
    br.ue()
    br.bit()
    br.ue()
    br.ue()
    s["frame_mbs_only"] = br.bit()
    return sid, s


def parse_pps(rbsp):
    br = Bits(rbsp)
    pid = br.ue()
    p = {"sps": br.ue(), "cabac": br.bit(), "bfpo": br.bit()}
    p["fmo"] = br.ue()
    p["nref"] = [br.ue() + 1, br.ue() + 1]
    p["wp"] = br.bit()
    p["wbi"] = br.u(2)
    br.se()
    br.se()
    br.se()
    p["dfc"] = br.bit()
    br.bit()
    p["rpc"] = br.bit()
    return pid, p


HEADER_PREFIX = 64         # NAL bytes unescaped for a first try at a slice header (most are < 40)


def slice_header_bytes(nal, sps_map, pps_map):
    """The NAL bytes up to and including the one holding the slice header's last bit
    (CABAC: its alignment ones); None when the header cannot be parsed (an unknown
    parameter set, FMO, a truncated NAL). A header longer than HEADER_PREFIX is parsed
    again over the whole NAL."""
    n = _slice_header_bytes(nal, sps_map, pps_map, HEADER_PREFIX)
    if n == "short":
        n = _slice_header_bytes(nal, sps_map, pps_map, None)
    return None if n == "short" else n


def _slice_header_bytes(nal, sps_map, pps_map, limit):
    rbsp, epbs = rbsp_of(nal, limit)
    truncated = limit is not None and len(nal) > limit
    br = Bits(rbsp)
    ntype, ref = nal[0] & 0x1F, (nal[0] >> 5) & 3
    try:
        br.ue()
        st = br.ue() % 5
        pid = br.ue()
        if pid not in pps_map:
            return None
        pps = pps_map[pid]
        if pps["sps"] not in sps_map or pps["fmo"]:
            return None
        sps = sps_map[pps["sps"]]
        br.u(sps["log2_fn"])
        field = 0
        if not sps["frame_mbs_only"]:
            field = br.bit()
            if field:
                br.bit()
        if ntype == 5:
            br.ue()
        if sps["poc_type"] == 0:
            br.u(sps["log2_poc"])
            if pps["bfpo"] and not field:
                br.se()
        if sps["poc_type"] == 1 and not sps["dpoc_zero"]:
            br.se()
            if pps["bfpo"] and not field:
                br.se()
        if pps["rpc"]:
            br.ue()
        if st == 1:
            br.bit()
        nref = list(pps["nref"])
        if st in (0, 1, 3):                              # P, B, SP
            if br.bit():
                nref[0] = br.ue() + 1
                if st == 1:
                    nref[1] = br.ue() + 1
            for _ in range(2 if st == 1 else 1):
                if br.bit():
                    while True:
                        idc = br.ue()
                        if idc == 3:
                            break
                        if idc > 5:
                            return None
                        br.ue()
        if (pps["wp"] and st in (0, 3)) or (pps["wbi"] == 1 and st == 1):
            br.ue()
            if sps["chroma"]:
                br.ue()
            for lx in range(2 if st == 1 else 1):
                for _ in range(nref[lx]):
                    if br.bit():
                        br.se()
                        br.se()
                    if sps["chroma"] and br.bit():
                        for _ in range(4):
                            br.se()
        if ref:
            if ntype == 5:
                br.bit()
                br.bit()
            elif br.bit():
                while True:
                    op = br.ue()
                    if op == 0:
                        break
                    if op > 6:
                        return None
                    if op in (1, 3):
                        br.ue()
                    if op == 2:
                        br.ue()
                    if op in (3, 6):
                        br.ue()
                    if op == 4:
                        br.ue()
        if pps["cabac"] and st not in (2, 4):
            br.ue()
        br.se()
        if st in (3, 4):
            if st == 3:
                br.bit()
            br.se()
        if pps["dfc"]:
            if br.ue() != 1:
                br.se()
                br.se()
        if pps["cabac"]:
            while br.p & 7:
                if br.bit() != 1:              # cabac_alignment_one_bit: a misparse shows here
                    return None
    except EOFError:
        return "short" if truncated else None
    except ReportError:
        return None
    nbytes = (br.p + 7) // 8
    if nbytes == 0 or nbytes > len(rbsp):
        return None
    return 1 + nbytes + bisect.bisect_right(epbs, nbytes - 1)


NAL_KEEP = (6, 7, 8, 9, 10, 11, 13, 15)       # SEI, SPS, PPS, AUD, end of seq / stream, SPS ext, subset SPS


# =============================================================================
# The program stream scrub (one .MPS head)
# =============================================================================
class Es(object):
    """One elementary stream's bytes, gathered from its PES payloads, with where each
    byte came from in the capture buffer."""

    def __init__(self):
        self.data = bytearray()
        self.segs = []            # (es offset, buffer offset, length)
        self.starts = []          # the segments' es offsets (a binary search for spans())
        self.pes = []             # (es offset, has PTS, first-AU pointer or None)

    def add(self, buf, at, ln, has_pts, fap=None):
        self.pes.append((len(self.data), has_pts, fap if fap is None or fap < ln else None))
        self.segs.append((len(self.data), at, ln))
        self.starts.append(len(self.data))
        self.data += buf[at:at + ln]

    def spans(self, lo, hi):
        """(buffer offset, length) pieces of ES bytes [lo, hi)."""
        out = []
        k = max(0, bisect.bisect_right(self.starts, lo) - 1)
        while k < len(self.segs) and self.segs[k][0] < hi:
            eo, bo, ln = self.segs[k]
            a, b = max(lo, eo), min(hi, eo + ln)
            if a < b:
                out.append((bo + a - eo, b - a))
            k += 1
        return out


def parse_packets(sec):
    """[(stream id, packet start, packet end)] of a 2048-byte pack; None if not an
    MPEG-2 pack. A packet that runs past the pack is cut at it."""
    if sec[:4] != b"\x00\x00\x01\xba" or (sec[4] >> 6) != 1:
        return None
    p = 14 + (sec[13] & 7)
    out = []
    while p + 6 <= SEC and sec[p:p + 3] == b"\x00\x00\x01":
        sid = sec[p + 3]
        end = min(SEC, p + 6 + be16(sec, p + 4))
        out.append((sid, p, end))
        p = end
    return out


def gather(buf, stats):
    """The header pieces [(buffer offset, length)] and the video / audio / subtitle
    elementary streams of `buf` (whole packs)."""
    keep = []
    video, audio, subs = {}, {}, {}
    for base in range(0, len(buf) - SEC + 1, SEC):
        sec = buf[base:base + SEC]
        pk = parse_packets(sec)
        if pk is None:
            if any(sec):
                stats["packs_unparsed"] = stats.get("packs_unparsed", 0) + 1
            continue
        keep.append((base, 14 + (sec[13] & 7)))
        for sid, p, end in pk:
            a = base + p
            if sid in (0xBB, 0xBF):            # system header, index pack: whole
                keep.append((a, end - p))
                continue
            if sid == 0xBE or end - p < 9 or (sec[p + 6] >> 6) != 2:
                keep.append((a, min(6, end - p)))
                continue
            hl = 9 + sec[p + 8]
            keep.append((a, min(hl, end - p)))
            pay, pl = a + hl, end - p - hl
            if pl <= 0:
                continue
            has_pts = bool(sec[p + 7] & 0x80)
            if 0xE0 <= sid <= 0xEF:
                video.setdefault(sid, Es()).add(buf, pay, pl, has_pts)
            elif sid == 0xBD:
                sub = buf[pay]
                if sub <= 0x0F and pl >= 4:
                    keep.append((pay, 4))
                    audio.setdefault(sub, Es()).add(buf, pay + 4, pl - 4, has_pts, be16(buf, pay + 2))
                elif 0x80 <= sub <= 0x9F and pl >= 2:
                    keep.append((pay, 2))
                    subs.setdefault(sub, Es()).add(buf, pay + 2, pl - 2, has_pts)
                else:
                    keep.append((pay, 1))
    return keep, video, audio, subs


def scrub_stream(buf, stats):
    """The scrubbed copy of `buf` (whole packs): zero except what is classified as a header."""
    out = bytearray(len(buf))
    keep, video, audio, subs = gather(buf, stats)
    for es in video.values():
        keep += _video_keep(es, stats)
    for es in audio.values():
        keep += _audio_keep(es, stats)
    for at, ln in keep:
        out[at:at + ln] = buf[at:at + ln]
    for es in subs.values():
        for at, data in _sub_blank(es, stats):
            out[at:at + len(data)] = data
    return bytes(out)


def _nals(es):
    """(start-code offset, payload start, payload end) of each NAL unit in an ES."""
    d = es.data
    i = d.find(b"\x00\x00\x01")
    out = []
    while i >= 0:
        s = i + 3
        j = d.find(b"\x00\x00\x01", s)
        out.append((i, s, len(d) if j < 0 else j))   # trailing zeros stay: a re-scrub parses alike
        i = j
    return out


def _video_keep(es, stats):
    keep = []
    sps, pps = {}, {}
    for sc, s, e in _nals(es):
        keep += es.spans(sc, s)                         # the start code
        if s >= e:
            continue
        nal = bytes(es.data[s:e])
        ntype = nal[0] & 0x1F
        n = 1
        if ntype in NAL_KEEP:
            n = len(nal)
            try:
                if ntype == 7:
                    k, v = parse_sps(rbsp_of(nal)[0])
                    sps[k] = v
                elif ntype == 8:
                    k, v = parse_pps(rbsp_of(nal)[0])
                    pps[k] = v
            except (EOFError, ReportError):
                pass
        elif ntype in (1, 5):
            hb = slice_header_bytes(nal, sps, pps)
            if hb is None:
                stats["slices_unparsed"] = stats.get("slices_unparsed", 0) + 1
            else:
                n = hb
                stats["slices_kept_as_headers"] = stats.get("slices_kept_as_headers", 0) + 1
        keep += es.spans(s, s + n)
    return keep


def _audio_keep(es, stats):
    """Each ATRAC3plus AU's 8-byte header, chained by its frame length, re-anchored on
    the next PES's first-AU pointer when the chain loses the sync word."""
    keep, d = [], es.data
    anchors = [eo + fap for eo, _pts, fap in es.pes if fap is not None]
    pos = anchors[0] if anchors else None
    while pos is not None and pos < len(d):
        if d[pos:pos + 2] == b"\x0f\xd0":
            keep += es.spans(pos, min(pos + 8, len(d)))
            stats["audio_frames_kept_as_headers"] = stats.get("audio_frames_kept_as_headers", 0) + 1
            if pos + 4 > len(d):
                break
            pos += 8 + (be16(d, pos + 2) & 0x3FF) * 8 + 8
            continue
        stats["audio_resyncs"] = stats.get("audio_resyncs", 0) + 1
        pos = next((a for a in anchors if a > pos), None)
    return keep


def _sub_blank(es, stats):
    """Each subtitle unit (it opens a PES with a PTS, "0088" at +4): its 20-byte header
    kept, its picture replaced by a flat 4-bit PNG of the same size (zero if it cannot be)."""
    out, d = [], es.data
    for eo, has_pts, _ in es.pes:
        if not has_pts or d[eo + 4:eo + 8] != b"0088" or eo + 20 > len(d):
            continue
        ln = be32(d, eo)
        png_len = ln - 16
        img = bytes(d[eo + 20:eo + 20 + max(0, png_len)])
        data = bytes(d[eo:eo + 20])
        try:
            w, h = png_ihdr(img)[:2]
            end = _png_end(img)
            if png_flat_check(img[:end]) and not any(img[end:]):
                rep = img[:end]                  # already a stand-in (a re-scrub): kept as written
            else:
                rep = png_flat(w, h, (0, 0, w - 1, h - 1), depth=4, alpha=160)
            if len(rep) <= png_len:
                data += rep
                stats["subtitles_blanked"] = stats.get("subtitles_blanked", 0) + 1
        except Exception:
            stats["subtitles_zeroed"] = stats.get("subtitles_zeroed", 0) + 1
        pos = eo
        for bo, ln2 in es.spans(eo, eo + len(data)):
            out.append((bo, data[pos - eo:pos - eo + ln2]))
            pos += ln2
    return out


def audit_subtitles(path, sub, es):
    """Every byte of a subtitle stream is a unit's 20-byte header, a flat stand-in
    written afresh from that unit's own size, or zero."""
    d = es.data
    ok = bytearray(len(d))
    for eo, has_pts, _ in es.pes:
        if not has_pts or d[eo + 4:eo + 8] != b"0088" or eo + 20 > len(d):
            continue
        ok[eo:eo + 20] = b"\x01" * 20
        img = bytes(d[eo + 20:eo + 20 + max(0, be32(d, eo) - 16)])
        if any(img):
            end = _png_end(img) if img[:8] == PNG_SIG else 0
            if not end or not png_flat_check(img[:end]):
                raise AuditError("%s: subtitle stream 0x%02X: a unit's picture at %d is not a blank stand-in"
                                 % (path, sub, eo))
            ok[eo + 20:eo + 20 + end] = b"\x01" * end
    for i, b in enumerate(d):
        if b and not ok[i]:
            raise AuditError("%s: subtitle stream 0x%02X: a byte at %d outside every unit header" % (path, sub, i))


def audit_stream(path, buf, first_lba):
    """The parser-free ceilings, then the classified re-check: every non-zero byte of
    the head is one a scrub of the head itself keeps (or a flat subtitle stand-in)."""
    for base in range(0, len(buf) - SEC + 1, SEC):
        sec = buf[base:base + SEC]
        pk = parse_packets(sec)
        lba = first_lba + base // SEC
        if pk is None:
            if any(sec):
                raise AuditError("%s: sector %d is not a pack but is not zero" % (path, lba))
            continue
        nz = run = 0
        for sid, p, end in pk:
            if sid in (0xBB, 0xBF):
                continue
            hl = 9 + sec[p + 8] if end - p >= 9 and sid != 0xBE and (sec[p + 6] >> 6) == 2 else 6
            if sid == 0xBD and p + hl < end and 0x80 <= sec[p + hl] <= 0x9F:
                continue                       # subtitles: checked unit by unit below
            for b in sec[p + hl:end]:
                if b:
                    nz += 1
                    run += 1
                    if run > MAX_NONZERO_RUN:
                        raise AuditError("%s: sector %d, stream 0x%02X: a run of more than %d non-zero "
                                         "payload bytes" % (path, lba, sid, MAX_NONZERO_RUN))
                else:
                    run = 0
            run = 0
        if nz > MAX_NONZERO_PER_PACK:
            raise AuditError("%s: sector %d: %d non-zero payload bytes (ceiling %d)"
                             % (path, lba, nz, MAX_NONZERO_PER_PACK))
    _keep, _v, _a, subs = gather(buf, {})
    for sub, es in subs.items():
        audit_subtitles(path, sub, es)
    again = scrub_stream(buf, {})
    if again != buf:
        i = next(k for k in range(len(buf)) if again[k] != buf[k])
        raise AuditError("%s: sector %d byte %d holds a byte no header accounts for"
                         % (path, first_lba + i // SEC, i % SEC))


# =============================================================================
# Collect, write, read back, audit
# =============================================================================
TABLE_FILES = re.compile(r"^(/UMD_DATA\.BIN|/UMD_VIDEO/PARAM\.SFO|/UMD_VIDEO/PLAYLIST\.UMD|/UMD_VIDEO/CLIPINF/[^/]+\.CLP)$")
RCO_FILES = re.compile(r"^/UMD_VIDEO/RESOURCE/[^/]+\.RCO$")
MPS_FILES = re.compile(r"^/UMD_VIDEO/STREAM/[^/]+\.MPS$")


def sniff(img):
    if img.sec(16)[1:6] == b"CD001":
        return "iso"
    s0 = img.sec(0)
    if s0[:4] == b"\x00\x00\x01\xba":
        return "mps"
    if s0[:4] == b"PSMF":
        raise ReportError("a .PMF is not played by the core (out of scope): no bundle needed")
    raise ReportError("neither a UMD Video image nor a bare .MPS")


def put_file(sectors, lba, data):
    for i in range(0, len(data), SEC):
        sectors[lba + i // SEC] = bytes(data[i:i + SEC]).ljust(SEC, b"\0")


def collect(path, packs=DEFAULT_PACKS):
    """{lba: sector}, the per-file record, the scrub counters, the disc's identity."""
    img = FileImage(path)
    try:
        kind = sniff(img)
        sectors, files, stats, ident = {}, [], {}, {}
        if kind == "mps":
            n = min(packs, img.size // SEC)
            buf = read_span(img, 0, n * SEC)
            put_file(sectors, 0, scrub_stream(buf, stats))
            files.append({"path": os.path.basename(path), "kind": "stream-head", "lba": 0,
                          "size": img.size, "sectors": n})
            return kind, sectors, files, stats, ident
        iso = Iso(img)
        ident["system_id"], ident["volume_id"] = iso.system_id, iso.volume_id
        for lba in iso.meta:
            sectors[lba] = img.sec(lba)
        for fpath in sorted(iso.files):
            lba, size, is_dir = iso.files[fpath]
            if is_dir:
                continue
            rec = {"path": fpath, "lba": lba, "size": size}
            if TABLE_FILES.match(fpath):
                data = iso.read(fpath)
                put_file(sectors, lba, data)
                rec.update(kind="table", sectors=(size + SEC - 1) // SEC)
                if fpath == "/UMD_VIDEO/PARAM.SFO":
                    ident.update(parse_sfo(data))
            elif RCO_FILES.match(fpath):
                data = iso.read(fpath)
                try:
                    put_file(sectors, lba, blank_rco(data, stats))
                    rec.update(kind="rco", sectors=(size + SEC - 1) // SEC)
                except ReportError as e:
                    rec.update(kind="not-captured", reason="RCO: %s" % e)
            elif MPS_FILES.match(fpath):
                n = min(packs, (size + SEC - 1) // SEC)
                buf = read_span(img, lba, n * SEC)
                if n * SEC > size:
                    buf = buf[:size].ljust(n * SEC, b"\0")
                put_file(sectors, lba, scrub_stream(buf, stats))
                rec.update(kind="stream-head", sectors=n)
            else:
                rec.update(kind="not-captured")
            files.append(rec)
        if iso.multi_extent:
            ident["multi_extent"] = iso.multi_extent
        return kind, sectors, files, stats, ident
    finally:
        img.close()


def parse_sfo(data):
    """PARAM.SFO's TITLE and DISC_ID (the PSF key table)."""
    out = {}
    try:
        if data[:4] != b"\0PSF":
            return out
        kt, dt, n = le32(data, 8), le32(data, 12), le32(data, 16)
        for i in range(n):
            e = 20 + 16 * i
            ko, fmt, ln, do = le16(data, e), le16(data, e + 2), le32(data, e + 4), le32(data, e + 12)
            key = data[kt + ko:data.index(b"\0", kt + ko)].decode("latin-1")
            if key in ("TITLE", "DISC_ID") and fmt == 0x0204:
                out[key.lower()] = data[dt + do:dt + do + ln].split(b"\0")[0].decode("utf-8", "replace")
    except Exception:
        pass
    return out


def runs(lbas):
    out = []
    for lba in sorted(lbas):
        if out and out[-1][0] + out[-1][1] == lba:
            out[-1][1] += 1
        else:
            out.append([lba, 1])
    return out


def write_bundle(out, sectors, manifest):
    manifest["extents"] = runs(sectors)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr("README.txt", BUNDLE_README)
        z.writestr("manifest.json", json.dumps(manifest, indent=1, sort_keys=True))
        z.writestr("sectors.bin", b"".join(sectors[k] for k in sorted(sectors)))


def read_bundle(path):
    with zipfile.ZipFile(path) as z:
        man = json.loads(z.read("manifest.json"))
        blob = z.read("sectors.bin")
    sectors, p = {}, 0
    for lba, n in man["extents"]:
        for i in range(n):
            sectors[lba + i] = blob[p:p + SEC]
            p += SEC
    if p != len(blob):
        raise ReportError("sectors.bin does not match the manifest's extents")
    return man, sectors


def audit(man, sectors):
    """The content check over a bundle as read back (docs/bug_reports.md section 4)."""
    img = SparseImage(sectors, man["image"]["size"])
    for rec in man["files"]:
        if rec["kind"] == "stream-head":
            buf = b"".join(sectors.get(rec["lba"] + i, b"\0" * SEC) for i in range(rec["sectors"]))
            audit_stream(rec["path"], buf, rec["lba"])
        elif rec["kind"] == "rco":
            audit_rco(rec["path"], read_span(img, rec["lba"], rec["size"]))
    known = set()
    for rec in man["files"]:
        if rec["kind"] in ("table", "rco", "stream-head"):
            known.update(range(rec["lba"], rec["lba"] + rec["sectors"]))
    if man["kind"] == "iso":
        known |= Iso(img).meta
    stray = sorted(set(sectors) - known)
    if stray:
        raise AuditError("sector %d is in the bundle but belongs to no captured file" % stray[0])


def verify(path, man, sectors):
    """The bundle against the original: the tree, the table files, every RCO byte
    outside its media, and the stream heads re-scrubbed, identical."""
    src = FileImage(path)
    img = SparseImage(sectors, man["image"]["size"])
    try:
        if man["kind"] == "iso":
            a, b = Iso(src), Iso(img)
            if a.files != b.files:
                raise ReportError("verify: the rebuilt tree differs from the image's")
        for rec in man["files"]:
            if rec["kind"] == "table":
                if read_span(img, rec["lba"], rec["size"]) != read_span(src, rec["lba"], rec["size"]):
                    raise ReportError("verify: %s differs" % rec["path"])
            elif rec["kind"] == "rco":
                o, r = read_span(src, rec["lba"], rec["size"]), read_span(img, rec["lba"], rec["size"])
                rco = Rco(o)
                media = bytearray(len(o))
                for at, ln in rco.regions + [(i[2], i[3]) for i in rco.images] + rco.sounds:
                    media[at:at + ln] = b"\x01" * max(0, min(ln, len(o) - at))
                if any(o[i] != r[i] for i in range(len(o)) if not media[i]):
                    raise ReportError("verify: %s's tables differ" % rec["path"])
            elif rec["kind"] == "stream-head":
                n = rec["sectors"]
                o = read_span(src, rec["lba"], n * SEC)
                if rec["size"] < n * SEC:
                    o = o[:rec["size"]].ljust(n * SEC, b"\0")
                r = b"".join(sectors.get(rec["lba"] + i, b"\0" * SEC) for i in range(n))
                if scrub_stream(o, {}) != r:
                    raise ReportError("verify: %s's head differs" % rec["path"])
    finally:
        src.close()


# =============================================================================
# Commands
# =============================================================================
def safe_slug(s):
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-")
    return s[:40] or "disc"


def prompt(label, default=""):
    try:
        v = input("%s%s: " % (label, " [%s]" % default if default else ""))
    except EOFError:
        return default
    return v.strip() or default


def cmd_make(args):
    if not os.path.isfile(args.image):
        raise ReportError("no such file: %s" % args.image)
    core = args.core_version
    note = args.note
    if not args.no_prompt and sys.stdin.isatty():
        if core is None:
            core = prompt("The OSD's version line (UMD <version> <yymmdd>), if you have it")
        if note is None:
            note = prompt("What went wrong, in a line")
    print("reading %s ..." % os.path.basename(args.image))
    kind, sectors, files, stats, ident = collect(args.image, args.packs)
    man = {
        "schema": SCHEMA, "tool_version": TOOL_VERSION, "kind": kind,
        "made": datetime.date.today().isoformat(),
        "image": {"name": os.path.basename(args.image), "size": os.path.getsize(args.image)},
        "disc": ident, "core_version": core or "", "note": note or "",
        "packs_per_stream": args.packs, "files": files, "scrub": stats,
    }
    title = ident.get("title") or os.path.splitext(os.path.basename(args.image))[0]
    out = args.output or "umdreport-%s-%s.zip" % (safe_slug(title), datetime.date.today().strftime("%Y%m%d"))
    write_bundle(out, sectors, man)
    try:
        man2, sec2 = read_bundle(out)
        audit(man2, sec2)
        verify(args.image, man2, sec2)
    except (AuditError, ReportError) as e:
        os.remove(out)
        raise ReportError("the bundle failed its own check and was NOT written: %s" % e)
    summarise(out, man2, sec2)
    print("\nAttach %s to your report. It holds no picture and no sound (checked)." % out)
    return 0


def summarise(path, man, sectors):
    kinds = {}
    for rec in man["files"]:
        kinds[rec["kind"]] = kinds.get(rec["kind"], 0) + 1
    print("bundle: %s (%d KB)" % (path, os.path.getsize(path) // 1024))
    print("  image: %s, %d bytes (%s)" % (man["image"]["name"], man["image"]["size"], man["kind"]))
    for k in ("title", "disc_id"):
        if man["disc"].get(k):
            print("  %s: %s" % (k.replace("_", " "), man["disc"][k]))
    if man.get("core_version"):
        print("  core: %s" % man["core_version"])
    if man.get("note"):
        print("  note: %s" % man["note"])
    print("  sectors: %d captured of %d" % (len(sectors), (man["image"]["size"] + SEC - 1) // SEC))
    print("  files: " + ", ".join("%d %s" % (v, k) for k, v in sorted(kinds.items())))
    for k, v in sorted(man["scrub"].items()):
        print("  %s: %d" % (k.replace("_", " "), v))
    for k in ("multi_extent",):
        if man["disc"].get(k):
            print("  NOTE multi-extent files: %s" % ", ".join(man["disc"][k]))


def cmd_info(args):
    man, sectors = read_bundle(args.bundle)
    summarise(args.bundle, man, sectors)
    for rec in man["files"]:
        print("    %-12s %8s  %s" % (rec["kind"], rec.get("sectors", "-"), rec["path"]))
    audit(man, sectors)
    print("audit: PASS (no picture, no sound)")
    return 0


def cmd_audit(args):
    man, sectors = read_bundle(args.bundle)
    audit(man, sectors)
    print("audit: PASS (no picture, no sound)")
    return 0


def cmd_unpack(args):
    man, sectors = read_bundle(args.bundle)
    with open(args.output, "wb") as f:
        for lba, n in man["extents"]:
            f.seek(lba * SEC)
            f.write(b"".join(sectors[lba + i] for i in range(n)))
        f.truncate(man["image"]["size"])
    print("unpacked: %s (%d bytes, %d sectors written, the rest a hole)"
          % (args.output, man["image"]["size"], len(sectors)))
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cmds = ("make", "info", "audit", "unpack")
    if argv and argv[0] not in cmds and argv[0] not in ("-h", "--help"):
        argv.insert(0, "make")
    ap = argparse.ArgumentParser(description="A repro bundle for the MiSTer UMD Video core: the disc's "
                                 "structure, never its pictures or sound.")
    sp = ap.add_subparsers(dest="cmd")
    m = sp.add_parser("make", help="make a bundle from an image (the default)")
    m.add_argument("image")
    m.add_argument("-o", "--output")
    m.add_argument("--packs", type=int, default=DEFAULT_PACKS, help="packs of each stream's head (default %(default)s)")
    m.add_argument("--core-version")
    m.add_argument("--note")
    m.add_argument("--no-prompt", action="store_true")
    for name in ("info", "audit"):
        p = sp.add_parser(name)
        p.add_argument("bundle")
    u = sp.add_parser("unpack")
    u.add_argument("bundle")
    u.add_argument("-o", "--output", required=True)
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 2
    try:
        return {"make": cmd_make, "info": cmd_info, "audit": cmd_audit, "unpack": cmd_unpack}[args.cmd](args)
    except AuditError as e:
        print("umd_report: AUDIT FAILED: %s" % e, file=sys.stderr)
        return 1
    except ReportError as e:
        print("umd_report: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
