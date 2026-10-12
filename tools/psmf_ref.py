#!/usr/bin/env python3
"""Pack/PES golden for UMD Video .MPS streams -- the reference ps_demux (P2) is
scored against.

Lifted from MiSTer_DVD's tools/mpeg1_ps_ref.py parse() and pts_map.py walk_ps(), with
the private-stream-1 branch the UMD numbering needs (spu_ref.iter_subpic_pes()'s
substream filter). An .MPS is an MPEG-2 program stream in 2048-byte packs
(docs/umd_video_format.md "The stream"):

    0xE0          H.264 Annex-B video
    0xBD sub 0x00-0x0F  ATRAC3plus audio, 4-byte sub-header [sub, 0x00, FAP hi, FAP lo];
                  FAP = offset from the byte AFTER the sub-header to the first access
                  unit header (0F D0 48 55 00 00 00 00) that starts in this PES
    0xBD sub 0x80-0x9F  subtitles, 2-byte sub-header [sub, 0x00] (umd_sub_extract.py);
                  Desperado's CLPI declares 29 subtitle streams, 0x80-0x9C, so the
                  range is NOT the 16 the first survey assumed. Anything else under
                  0xBD is `bd_other`, counted.
    0xBF          private stream 2 (the per-GOP index packs, umd_index_packs.py)
    0xBB / 0xBE   system header / padding, skipped by length

Every byte of the input is attributed to exactly one class (`Result.acct`), so a gate
can require the totals to equal the input size: a walker that loses sync, or skips a
packet it did not understand, shows as a missing byte instead of passing quietly.

    psmf_ref.py disc.iso --clip 1 [--packs N]              # summary + byte accounting
    psmf_ref.py disc.iso --clip 1 --es audio:0 -o a.bin    # one elementary stream
    psmf_ref.py 00001.MPS ...                               # a bare stream file
    psmf_ref.py INTRO.PMF ...                               # a PSMF file: header skipped

A `.PMF` (PSP game cutscenes, the XMB's ICON1.PMF) is the same program stream behind a
PSMF header (`psmf_header()`; layout from JPCSP scePsmf.java / sceMpeg.java, checked
against the library's ICON1.PMFs and a census of game PMFs: docs/bare_streams.md).
"""
import argparse
import mmap
import os
import struct
import sys

SEC = 2048
SUB_LO, SUB_HI = 0x80, 0x9F   # subtitle substreams (measured to 0x9C; CLPI's id is a u8)

# accounting classes (Result.acct keys), in report order
ACCT = ("pack", "system", "padding", "private2", "video_hdr", "video", "audio_hdr",
        "audio", "sub_hdr", "sub", "bd_other", "other_pes", "end", "junk")


class PsError(Exception):
    pass


class Packet(object):
    """One PES packet. `payload` excludes the PES header and, for 0xBD, the
    sub-header (kept in `subhdr`: 4 bytes for audio, 2 for subtitles)."""
    __slots__ = ("offset", "sid", "sub", "pts", "dts", "subhdr", "payload_off",
                 "payload_len", "pes_len")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

    @property
    def fap(self):
        if self.subhdr is None or len(self.subhdr) < 4 or self.kind != "audio":
            return None
        return (self.subhdr[2] << 8) | self.subhdr[3]

    @property
    def kind(self):
        if self.sid == 0xE0:
            return "video"
        if self.sid == 0xBD:
            if self.sub is not None and self.sub < 0x10:
                return "audio"
            if self.sub is not None and SUB_LO <= self.sub <= SUB_HI:
                return "sub"
            return "bd_other"
        if self.sid == 0xBF:
            return "private2"
        return "other_pes"


class Result(object):
    def __init__(self):
        self.packets = []
        self.acct = dict((k, 0) for k in ACCT)
        self.packs = 0
        self.unaligned_packs = 0      # pack headers not on a 2048 boundary
        self.short_bd = 0             # 0xBD PES shorter than its class's sub-header
        self.counts = {}              # {(sid, sub): PES count}, kept even when keep=False
        self.bytes = 0

    def total(self):
        return sum(self.acct.values())

    def streams(self):
        """{(sid, sub): PES count} for every PES-bearing stream (not 0xBB/0xBE)."""
        return dict(self.counts)


# --- the PSMF header of a .PMF (big-endian; JPCSP scePsmf.java PSMFHeader) ----------
PSMF_MAGIC = b"PSMF"


def psmf_header(head, file_size):
    """Parse a PSMF header (at least its first 2048 bytes) of a file of file_size bytes.

    Validated as JPCSP's sceMpeg validates it: the stream offset non-zero, 2048-aligned
    and inside the file (else PsError). The stream runs from the offset for the header's
    stream size, cut at the file's end; `size_mismatch` says when those disagree.
    Returns dict(version, stream_offset, stream_size, stream_end, size_mismatch,
    first_pts, last_pts, streams=[dict(sid, sub, ep_off, ep_n, w, h, ch, rate)])."""
    if head[:4] != PSMF_MAGIC:
        raise PsError("no PSMF magic")
    if len(head) < 0x82:
        raise PsError("PSMF header truncated")
    off, size = struct.unpack(">II", head[8:16])
    if off == 0 or off % SEC or off >= file_size:
        raise PsError("PSMF stream offset 0x%x invalid (file %d bytes)" % (off, file_size))
    end = min(off + size, file_size)
    h = {"version": head[4:8].decode("ascii", "replace"), "stream_offset": off,
         "stream_size": size, "stream_end": end, "size_mismatch": off + size != file_size,
         "first_pts": int.from_bytes(head[0x54:0x5A], "big"),
         "last_pts": int.from_bytes(head[0x5A:0x60], "big"), "streams": []}
    n = struct.unpack(">H", head[0x80:0x82])[0]
    for i in range(n):
        q = 0x82 + 16 * i
        e = head[q:q + 16]
        if len(e) < 16:
            raise PsError("PSMF stream table runs past the header (%d entries)" % n)
        ep_off, ep_n = struct.unpack(">II", e[4:12])
        h["streams"].append({"sid": e[0], "sub": e[1], "ep_off": ep_off, "ep_n": ep_n,
                             "w": e[12] * 16, "h": e[13] * 16, "ch": e[14], "rate": e[15]})
    return h


def _ts(b, o):
    """33-bit PTS/DTS from the 5-byte field at b[o]."""
    return (((b[o] >> 1) & 7) << 30 | b[o + 1] << 22 | (b[o + 2] >> 1) << 15 |
            b[o + 3] << 7 | b[o + 4] >> 1)


def parse(buf, start=0, end=None, keep=True):
    """Walk buf[start:end]. keep=False skips building Packet objects (byte accounting
    only -- fast enough for a whole 1.6 GB feature). Returns a Result."""
    end = len(buf) if end is None else end
    r = Result()
    r.bytes = end - start
    acct = r.acct
    counts = r.counts
    p = start
    while p < end:
        if p + 4 > end or buf[p:p + 3] != b"\x00\x00\x01":
            # resync: count the junk up to the next pack start (never silently skipped)
            q = buf.find(b"\x00\x00\x01\xba", p + 1, end)
            q = end if q < 0 else q
            acct["junk"] += q - p
            p = q
            continue
        sid = buf[p + 3]
        if sid == 0xBA:
            if (buf[p + 4] & 0xC0) != 0x40:
                raise PsError("MPEG-1 pack header at %d (a UMD stream is MPEG-2)" % p)
            n = 14 + (buf[p + 13] & 7)
            if (p - start) % SEC:
                r.unaligned_packs += 1
            r.packs += 1
            acct["pack"] += n
            p += n
            continue
        if sid == 0xB9:
            acct["end"] += 4
            p += 4
            continue
        if p + 6 > end:
            acct["junk"] += end - p
            break
        ln = (buf[p + 4] << 8) | buf[p + 5]
        tot = 6 + ln
        if p + tot > end:
            raise PsError("PES 0x%02x at %d runs past the end (%d > %d)"
                          % (sid, p, p + tot, end))
        if sid == 0xBB:
            acct["system"] += tot
        elif sid == 0xBE:
            acct["padding"] += tot
        elif sid == 0xBF:
            acct["private2"] += tot
            counts[(sid, None)] = counts.get((sid, None), 0) + 1
            if keep:
                r.packets.append(Packet(offset=p, sid=sid, payload_off=p + 6,
                                        payload_len=ln, pes_len=tot))
        elif sid == 0xE0 or sid == 0xBD or 0xC0 <= sid <= 0xEF:
            if (buf[p + 6] & 0xC0) != 0x80:
                raise PsError("PES 0x%02x at %d has no MPEG-2 header" % (sid, p))
            flags = buf[p + 7]
            hl = buf[p + 8]
            pts = dts = None
            if flags & 0x80:
                pts = _ts(buf, p + 9)
            if (flags & 0xC0) == 0xC0:
                dts = _ts(buf, p + 14)
            h = 9 + hl
            if h > tot:
                raise PsError("PES 0x%02x at %d: header longer than packet" % (sid, p))
            sub = subhdr = None
            if sid == 0xBD:
                if tot - h < 1:
                    raise PsError("0xBD at %d: no substream id" % p)
                sub = buf[p + h]
                # sub-header length by class: audio [sub, 0, FAP hi, FAP lo] = 4;
                # subtitles [sub, 0] = 2 (measured: a subtitle unit's u32 length only
                # adds up across PES with a 2-byte sub-header); anything else 1
                shl = 4 if sub < 0x10 else 2 if SUB_LO <= sub <= SUB_HI else 1
                if tot - h < shl:
                    r.short_bd += 1          # counted, kept whole as a short sub-header
                    # (none on the local discs once subtitles use 2 bytes: Akira's
                    # 3-byte '80 00 82' PES is a unit's last PNG byte)
                    shl = tot - h
                subhdr = bytes(buf[p + h:p + h + shl])
                if sub < 0x10:
                    cls = "audio"
                elif SUB_LO <= sub <= SUB_HI:
                    cls = "sub"
                else:
                    cls = "bd_other"
                if cls == "bd_other":
                    acct["bd_other"] += tot
                else:
                    acct[cls + "_hdr"] += h + len(subhdr)
                    acct[cls] += tot - h - len(subhdr)
                h += len(subhdr)
            elif sid == 0xE0:
                acct["video_hdr"] += h
                acct["video"] += tot - h
            else:
                acct["other_pes"] += tot
            counts[(sid, sub)] = counts.get((sid, sub), 0) + 1
            if keep:
                r.packets.append(Packet(offset=p, sid=sid, sub=sub, pts=pts, dts=dts,
                                        subhdr=subhdr, payload_off=p + h,
                                        payload_len=tot - h, pes_len=tot))
        else:
            acct["other_pes"] += tot
            counts[(sid, None)] = counts.get((sid, None), 0) + 1
            if keep:
                r.packets.append(Packet(offset=p, sid=sid, payload_off=p + 6,
                                        payload_len=ln, pes_len=tot))
        p += tot
    return r


def es(buf, result, kind, sub=None):
    """Concatenate one elementary stream. kind: 'video' | 'audio' | 'sub' | 'private2'.
    Returns (bytes, marks) with marks = [(es_offset, pts, dts, fap)] for each PES
    (fap None for video/private2) -- the (offset, PTS) pairs pts_assoc and the audio
    realign are scored against."""
    out = bytearray()
    marks = []
    for p in result.packets:
        if p.kind != kind or (sub is not None and p.sub != sub):
            continue
        marks.append((len(out), p.pts, p.dts, p.fap))
        out += buf[p.payload_off:p.payload_off + p.payload_len]
    return bytes(out), marks


class Source(object):
    """An .MPS as a buffer: a bare file, or a clip inside an image (mmap, no copy)."""

    def __init__(self, path, clip=None):
        self.f = open(path, "rb")
        self.mm = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        self.psmf = None
        if clip is None:
            self.start, self.end = 0, len(self.mm)
            self.name = os.path.basename(path)
            if self.mm[:4] == PSMF_MAGIC:
                self.psmf = psmf_header(self.mm[:SEC], len(self.mm))
                self.start, self.end = self.psmf["stream_offset"], self.psmf["stream_end"]
        else:
            import umd_iso
            iso = umd_iso.UmdIso(path)
            e = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip)
            iso.close()
            self.start, self.end = e.lba * SEC, e.lba * SEC + e.size
            self.name = "%s clip %05d" % (os.path.basename(path), clip)

    def limit(self, packs):
        if packs:
            self.end = min(self.end, self.start + packs * SEC)

    def close(self):
        self.mm.close()
        self.f.close()


def _parse_es_arg(s):
    kind, _, sub = s.partition(":")
    if kind not in ("video", "audio", "sub", "private2"):
        raise SystemExit("--es wants video | audio:N | sub:0xNN | private2")
    return kind, (int(sub, 0) if sub else None)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("path", help="disc image (with --clip), a bare .MPS or a .PMF")
    ap.add_argument("--clip", type=int)
    ap.add_argument("--packs", type=int, help="only the first N packs")
    ap.add_argument("--es", help="video | audio:N | sub:0xNN | private2")
    ap.add_argument("-o", "--out")
    a = ap.parse_args(argv)
    src = Source(a.path, a.clip)
    src.limit(a.packs)
    try:
        r = parse(src.mm, src.start, src.end, keep=True)
        if a.es:
            kind, sub = _parse_es_arg(a.es)
            # es() offsets are absolute in the mmap
            data, marks = es(src.mm, r, kind, sub)
            if a.out:
                open(a.out, "wb").write(data)
            print("%s %s: %d bytes in %d PES, %d with PTS" % (
                src.name, a.es, len(data), len(marks), sum(1 for m in marks if m[1] is not None)))
            return 0
        if src.psmf:
            h = src.psmf
            print("%s: PSMF %s, stream at 0x%x, %d bytes%s, PTS %d..%d, streams %s" % (
                src.name, h["version"], h["stream_offset"], h["stream_size"],
                " (FILE DISAGREES)" if h["size_mismatch"] else "", h["first_pts"],
                h["last_pts"], " ".join("%02x/%02x" % (e["sid"], e["sub"]) for e in h["streams"])))
        print("%s: %d bytes, %d packs (%d unaligned)" % (src.name, r.bytes, r.packs,
                                                         r.unaligned_packs))
        for k in ACCT:
            if r.acct[k]:
                print("  %-10s %12d" % (k, r.acct[k]))
        print("  %-10s %12d  %s" % ("TOTAL", r.total(),
                                    "== size" if r.total() == r.bytes else "!= SIZE"))
        for (sid, sub), n in sorted(r.streams().items(), key=lambda kv: (kv[0][0], kv[0][1] or 0)):
            print("  stream 0x%02x%s  %d PES" % (sid, "" if sub is None else " sub 0x%02x" % sub, n))
        return 0 if r.total() == r.bytes and not r.acct["junk"] else 1
    finally:
        src.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PsError as e:
        sys.exit("psmf_ref: %s" % e)
