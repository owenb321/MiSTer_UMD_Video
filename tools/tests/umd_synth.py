"""Synthetic-byte builders for the Phase 1 parser tests.

Written from the format documents (ECMA-119, ISO/IEC 13818-1, docs/umd_video_format.md),
NOT from the parsers under test, so a parser bug and a builder bug have to agree to hide.
Not a test itself (the runner globs test_*.py).
"""
import struct

SEC = 2048


# --- ISO9660 ---------------------------------------------------------------------
def dir_record(name, lba, size, flags):
    """One ECMA-119 §9.1 directory record (both-endian fields)."""
    nm = name if isinstance(name, bytes) else name.encode("ascii")
    ln = 33 + len(nm)
    ln += ln & 1                                   # pad to even length
    r = bytearray(ln)
    r[0] = ln
    r[2:10] = struct.pack("<I", lba) + struct.pack(">I", lba)
    r[10:18] = struct.pack("<I", size) + struct.pack(">I", size)
    r[25] = flags
    r[28:32] = struct.pack("<H", 1) + struct.pack(">H", 1)
    r[32] = len(nm)
    r[33:33 + len(nm)] = nm
    return bytes(r)


def dir_sectors(self_lba, parent_lba, entries, nsec=1):
    """A directory: '.', '..', then entries [(name, lba, size, flags)], records
    never straddling a sector."""
    recs = [dir_record(b"\x00", self_lba, nsec * SEC, 2),
            dir_record(b"\x01", parent_lba, SEC, 2)]
    recs += [dir_record(n, l, s, f) for n, l, s, f in entries]
    out, cur = [], b""
    for r in recs:
        if len(cur) + len(r) > SEC:
            out.append(cur.ljust(SEC, b"\0"))
            cur = b""
        cur += r
    out.append(cur.ljust(SEC, b"\0"))
    while len(out) < nsec:
        out.append(b"\0" * SEC)
    assert len(out) == nsec, "directory does not fit in %d sectors" % nsec
    return b"".join(out)


def pvd(root_lba, root_size, total, system_id=b"UMD VIDEO"):
    d = bytearray(SEC)
    d[0] = 1
    d[1:6] = b"CD001"
    d[6] = 1
    d[8:40] = system_id.ljust(32)
    d[40:72] = b" " * 32
    d[80:88] = struct.pack("<I", total) + struct.pack(">I", total)
    d[128:132] = struct.pack("<H", SEC) + struct.pack(">H", SEC)
    d[156:190] = dir_record(b"\x00", root_lba, root_size, 2)
    return bytes(d)


def terminator():
    d = bytearray(SEC)
    d[0] = 255
    d[1:6] = b"CD001"
    d[6] = 1
    return bytes(d)


class ImageBuilder(object):
    """Sector-addressed image: put(lba, bytes) then build()."""

    def __init__(self, nsec):
        self.buf = bytearray(nsec * SEC)

    def put(self, lba, data):
        self.buf[lba * SEC:lba * SEC + len(data)] = data

    def build(self):
        return bytes(self.buf)


# --- MPEG-2 program stream --------------------------------------------------------
def pts_bytes(pts, marker=0x2):
    """The 5-byte PTS/DTS field (§2.4.3.7): '0010'/'0011'/'0001' + 33 bits + markers."""
    return bytes([(marker << 4) | (((pts >> 30) & 7) << 1) | 1,
                  (pts >> 22) & 0xFF, (((pts >> 15) & 0x7F) << 1) | 1,
                  (pts >> 7) & 0xFF, ((pts & 0x7F) << 1) | 1])


def pack_header(scr=0, mux_rate=0x3FFFF, stuffing=0):
    """14-byte MPEG-2 pack header (+ stuffing 0xFF)."""
    b = bytearray(14)
    b[0:4] = b"\x00\x00\x01\xba"
    b[4] = 0x44 | (((scr >> 30) & 7) << 3) | ((scr >> 28) & 3)
    b[5] = (scr >> 20) & 0xFF
    b[6] = (((scr >> 15) & 0x1F) << 3) | 4 | ((scr >> 13) & 3)
    b[7] = (scr >> 5) & 0xFF
    b[8] = ((scr & 0x1F) << 3) | 4
    b[9] = 1
    b[10] = (mux_rate >> 14) & 0xFF
    b[11] = (mux_rate >> 6) & 0xFF
    b[12] = ((mux_rate & 0x3F) << 2) | 3
    b[13] = 0xF8 | stuffing
    return bytes(b) + b"\xff" * stuffing


def pes(stream_id, payload, pts=None, dts=None):
    """An MPEG-2 PES packet. For 0xBB/0xBE/0xBF the payload follows the length
    directly (no optional header)."""
    if stream_id in (0xBB, 0xBE, 0xBF):
        return b"\x00\x00\x01" + bytes([stream_id]) + struct.pack(">H", len(payload)) + payload
    flags = 0
    opt = b""
    if pts is not None and dts is not None:
        flags = 0xC0
        opt = pts_bytes(pts, 3) + pts_bytes(dts, 1)
    elif pts is not None:
        flags = 0x80
        opt = pts_bytes(pts, 2)
    hdr = bytes([0x81, flags, len(opt)]) + opt
    body = hdr + payload
    return b"\x00\x00\x01" + bytes([stream_id]) + struct.pack(">H", len(body)) + body


def fill_pack(packets, scr=0):
    """One 2048-byte pack: header + packets + a padding PES filling the rest
    (or pad bytes if fewer than 6 remain -- we assert that does not happen)."""
    body = pack_header(scr) + b"".join(packets)
    room = SEC - len(body)
    assert room == 0 or room >= 6, "cannot pad %d bytes with a PES" % room
    if room:
        body += pes(0xBE, b"\xff" * (room - 6))
    assert len(body) == SEC
    return body


# --- UMD navigation files (layouts from docs/umd_video_format.md) --------------------
def u48(v):
    return struct.pack(">HI", v >> 32, v & 0xFFFFFFFF)


def clpi(streams, maps, start=90000, end=900000, extra=b"\x00\x00"):
    """streams: [(sid, sub, attr8)]; maps: [(sid, sub, [(flags, pts, sector)])]."""
    si = u48(start) + u48(end) + struct.pack(">H", len(streams))
    for sid, sub, attr in streams:
        si += struct.pack(">BBI", sid, sub, 8) + attr
    si = struct.pack(">I", len(si)) + si
    ex = struct.pack(">I", len(extra)) + extra
    # EP: u32 len, u16 1, u16 n, n x 10 map headers, then entries; offsets from n_maps
    hdr_len = 4 + 10 * len(maps)            # from the n_maps field to the first entry
    body = b""
    heads = b""
    for sid, sub, ents in maps:
        heads += struct.pack(">BBII", sid, sub, len(ents), hdr_len + len(body) - 2)
        body += b"".join(struct.pack(">HII", *e) for e in ents)
    epc = struct.pack(">HH", 1, len(maps)) + heads + body
    ep = struct.pack(">I", len(epc)) + epc
    si_off = 0x30
    ex_off = si_off + len(si)
    ep_off = ex_off + len(ex)
    head = b"CLPI0088" + struct.pack(">III", si_off, ep_off, ex_off) + bytes(0x30 - 20)
    return head + si + ex + ep


def entry(name, items, marks):
    """One playlist entry, sections laid out info -> items -> marks after a 0x24 head."""
    info = b"\x00\x00" + bytes.fromhex("20040815230000") + b"\x00\x00\x06\x09\x00"
    info += bytes([len(name)]) + name.encode() + bytes(255 - len(name))
    info_s = struct.pack(">I", len(info)) + info
    it = struct.pack(">I", len(items))
    for clip, i, o in items:
        body = struct.pack(">H", len(clip)) + clip.encode().ljust(8, b"\0") + u48(i) + u48(o)
        it += struct.pack(">I", len(body)) + body
    items_s = struct.pack(">I", len(it)) + it
    mk = struct.pack(">H", len(marks))
    for m in marks:                      # (flags, item, pts, name[, type]): type 5 by default
        fl, item, pts, nm = m[:4]
        typ = m[4] if len(m) > 4 else 5
        mk += bytes([typ, fl]) + struct.pack(">H", item) + u48(pts) + u48(0) + nm.encode().ljust(24, b"\0")
    marks_s = struct.pack(">I", len(mk)) + mk
    items_off = 0x24 + len(info_s)
    marks_off = items_off + len(items_s)
    body = struct.pack(">HH", items_off, marks_off) + bytes(0x24 - 8) + info_s + items_s + marks_s
    return struct.pack(">I", len(body)) + body


def playlist_file(entries):
    disc = struct.pack(">I", 1) + bytes([11]) + b"UMDV-SAMPLE" + bytes(255 - 11)
    head = b"UMDV0088" + struct.pack(">I", 0x130) + bytes(0x28 - 12)
    head += struct.pack(">I", len(disc)) + disc
    assert len(head) == 0x130
    pl = struct.pack(">H", len(entries)) + b"".join(entries)
    return head + struct.pack(">I", len(pl)) + pl



# --- the shared scoring harness (tools/tests/test_status_bits.py's shape) -----------
class Score(object):
    """check()/raises() print PASS/FAIL per line; finish() prints the ALL GREEN
    marker run_tests.sh requires positively, and exits non-zero on any failure."""

    def __init__(self, name):
        self.name, self.fails = name, 0

    @staticmethod
    def _short(v):
        r = repr(v)
        return r[:77] + "..." if len(r) > 80 else r

    def check(self, label, got, want):
        ok = got == want
        print("  %s %s: %s%s" % ("PASS" if ok else "FAIL", label, self._short(got),
                                 "" if ok else " want " + self._short(want)))
        self.fails += 0 if ok else 1

    def raises(self, label, fn, exc, frag):
        try:
            fn()
        except exc as e:
            ok = frag in str(e)
            print("  %s %s: raised %s" % ("PASS" if ok else "FAIL", label, e))
            self.fails += 0 if ok else 1
            return
        print("  FAIL %s: did not raise" % label)
        self.fails += 1

    def finish(self):
        import sys
        print("%s: %s" % (self.name, "ALL GREEN" if not self.fails
                          else "%d FAILURE(S)" % self.fails))
        sys.exit(1 if self.fails else 0)
