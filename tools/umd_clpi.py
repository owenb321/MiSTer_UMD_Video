#!/usr/bin/env python3
"""CLIPINF/NNNNN.CLP (magic CLPI0088) parser, and a cross-check against the clip's .MPS.

Layout, decoded by this tool on the local discs (docs/umd_video_format.md "CLIPINF";
big-endian throughout). Fields marked (?) are carried raw and censused, not interpreted:

    0x00  "CLPI0088"
    0x08  u32 stream_info_off   (0x30 on every disc)
    0x0C  u32 ep_map_off
    0x10  u32 extra_off         (a section of length 2, contents 00 00 (?))
    0x14  28 bytes (?)          (header_misc)

    stream_info (at stream_info_off):
      u32 length                (bytes after this field)
      u48 presentation start PTS (90 kHz; 90000 = 1.000 s on every clip seen)
      u48 presentation end PTS
      u16 n_streams
      n_streams x 14:  u8 stream_id, u8 substream_id (0 for 0xE0), u32 (?)=8,
                       8 attribute bytes:
                         video  (0xE0):  byte0 low nibble = frame rate (1 23.976
                                progressive, 4 29.97 -- the Blu-ray codes), high
                                nibble 1 (?); byte1 high nibble = aspect (1 16:9 =
                                SAR 40:33, 2 4:3 = SAR 10:11); agrees with the SPS on
                                every clip of the census
                         audio  (0xBD 0x00-0x0F): bytes2-3 language (ASCII), byte4
                                channels (?) 2, byte5 rate code (?) 1
                         subtitle (0xBD 0x80-0x9F): bytes2-3 language

    extra (at extra_off): u32 length, then `length` bytes (?)

    ep_map (at ep_map_off):
      u32 length, u16 (?)=1, u16 n_maps       <- entry offsets are relative to n_maps
      n_maps x 10:  u8 stream_id, u8 substream_id, u32 n_entries, u32 entries_off
      entries, 10 bytes each: u16 flags, u32 PTS (90 kHz), u32 sector (relative to the
      first sector of the clip's .MPS)
        video map: every sector holds a video PES whose PTS equals the entry's and
                   whose payload opens an access unit with AUD + SPS (verify());
                   flags top 2 bits 11, low 14 bits (?): NOT the I-picture's sector
                   span or any following AU's offset (tested; not needed to seek)
        subtitle map (0xBD 0x80-0x9F): the sector of each subtitle unit; flags 0

Field widths (the "design to the spec maximum" inputs): n_streams u16, n_maps u16,
n_entries u32, sector u32, PTS u32 (so 33-bit PTS values above 2^32 cannot be
represented: a clip must start below ~13.25 h -- never near on a disc).

    umd_clpi.py disc.iso [--clip N] [--entries] [--verify] [--json]
"""
import argparse
import json
import struct
import sys

MAGIC = b"CLPI0088"
SEC = 2048


class ClpiError(Exception):
    pass


def _u48(b, o):
    return (struct.unpack(">H", b[o:o + 2])[0] << 32) | struct.unpack(">I", b[o + 2:o + 6])[0]


def _section(raw, off, what):
    if off + 4 > len(raw):
        raise ClpiError("%s offset 0x%x past the end (%d bytes)" % (what, off, len(raw)))
    ln = struct.unpack(">I", raw[off:off + 4])[0]
    if off + 4 + ln > len(raw):
        raise ClpiError("%s at 0x%x: length %d runs past the end" % (what, off, ln))
    return ln


def stream_kind(sid, sub):
    if sid == 0xE0:
        return "video"
    if sid == 0xBD and sub < 0x10:
        return "audio"
    if sid == 0xBD and 0x80 <= sub <= 0x9F:        # measured to 0x9C (Desperado)
        return "subtitle"
    return "unknown"


def parse(raw):
    if raw[:8] != MAGIC:
        raise ClpiError("no CLPI0088 magic (got %r)" % raw[:8])
    if len(raw) < 0x30:
        raise ClpiError("header truncated")
    si_off, ep_off, ex_off = struct.unpack(">III", raw[8:20])
    out = {"size": len(raw), "stream_info_off": si_off, "ep_map_off": ep_off,
           "extra_off": ex_off, "header_misc": raw[0x14:0x30].hex()}

    # stream info
    ln = _section(raw, si_off, "stream_info")
    b = si_off + 4
    out["start_pts"] = _u48(raw, b)
    out["end_pts"] = _u48(raw, b + 6)
    n = struct.unpack(">H", raw[b + 12:b + 14])[0]
    if 14 + 14 * n != ln:
        raise ClpiError("stream_info length %d does not hold %d streams" % (ln, n))
    streams = []
    for k in range(n):
        e = raw[b + 14 + 14 * k:b + 28 + 14 * k]
        sid, sub, unk = struct.unpack(">BBI", e[:6])
        attr = e[6:14]
        s = {"stream_id": sid, "substream_id": sub, "kind": stream_kind(sid, sub),
             "unk": unk, "attr": attr.hex()}
        if s["kind"] in ("audio", "subtitle"):
            s["lang"] = attr[2:4].decode("latin-1")
        if s["kind"] == "audio":
            s["channels"] = attr[4]
            s["rate_code"] = attr[5]
        streams.append(s)
    out["streams"] = streams

    # extra section
    ln = _section(raw, ex_off, "extra")
    out["extra"] = raw[ex_off + 4:ex_off + 4 + ln].hex()

    # EP map
    ln = _section(raw, ep_off, "ep_map")
    out["ep_unk"], nmaps = struct.unpack(">HH", raw[ep_off + 4:ep_off + 8])
    base = ep_off + 6
    maps = []
    spans = []
    for k in range(nmaps):
        sid, sub, cnt, off = struct.unpack(">BBII", raw[ep_off + 8 + 10 * k:ep_off + 18 + 10 * k])
        a = base + off
        if a < ep_off + 8 + 10 * nmaps or a + 10 * cnt > ep_off + 4 + ln:
            raise ClpiError("EP map %02x/%02x: %d entries at 0x%x fall outside the section"
                            % (sid, sub, cnt, a))
        ents = [struct.unpack(">HII", raw[a + 10 * j:a + 10 * j + 10]) for j in range(cnt)]
        maps.append({"stream_id": sid, "substream_id": sub, "kind": stream_kind(sid, sub),
                     "entries": ents})
        spans.append((a, a + 10 * cnt))
    # the entry tables must tile the section exactly: no gap, no overlap, no tail
    pos = ep_off + 8 + 10 * nmaps
    for a, b in sorted(spans):
        if a != pos:
            raise ClpiError("EP map section has %d unaccounted bytes at 0x%x" % (a - pos, pos))
        pos = b
    if pos != ep_off + 4 + ln:
        raise ClpiError("EP map section has %d unaccounted bytes at 0x%x"
                        % (ep_off + 4 + ln - pos, pos))
    out["ep_maps"] = maps
    return out


def video_map(c):
    for m in c["ep_maps"]:
        if m["kind"] == "video":
            return m["entries"]
    return []


def lookup(c, pts):
    """The last video EP entry at or before `pts` -> (pts, sector), or the first."""
    ents = video_map(c)
    best = ents[0] if ents else None
    for e in ents:
        if e[1] <= pts:
            best = e
        else:
            break
    return None if best is None else (best[1], best[2])


def from_iso(iso, clip):
    return parse(iso.read("/UMD_VIDEO/CLIPINF/%05d.CLP" % clip))


def verify(iso_path, clip, samples=64):
    """Cross-check a clip's CLPI against its .MPS. Returns a list of problems ([] = ok).

    Per EP map: entries strictly increasing in PTS and sector, every sector inside the
    clip, and for up to `samples` entries (first, last, evenly spaced) the pack at that
    sector carries a PES of that stream with exactly that PTS; for video, the payload
    opens with an AUD (00 00 00 01 09) followed by an SPS."""
    import psmf_ref
    import umd_iso
    with umd_iso.UmdIso(iso_path) as iso:
        c = from_iso(iso, clip)
        nsec = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip).nsec
    src = psmf_ref.Source(iso_path, clip)
    bad = []
    try:
        for m in c["ep_maps"]:
            ents = m["entries"]
            tag = "map %02x/%02x" % (m["stream_id"], m["substream_id"])
            for a, b in zip(ents, ents[1:]):
                if not (b[1] > a[1] and b[2] > a[2]):
                    bad.append("%s not increasing at %r -> %r" % (tag, a, b))
                    break
            if ents and ents[-1][2] >= nsec:
                bad.append("%s sector %d past the clip (%d sectors)" % (tag, ents[-1][2], nsec))
                continue
            if not ents:
                continue
            step = max(1, len(ents) // samples)
            pick = sorted(set(list(range(0, len(ents), step)) + [len(ents) - 1]))
            want_sub = None if m["stream_id"] == 0xE0 else m["substream_id"]
            for j in pick:
                fl, pts, sec = ents[j]
                a = src.start + sec * SEC
                r = psmf_ref.parse(src.mm, a, a + SEC)
                hit = [p for p in r.packets if p.sid == m["stream_id"] and p.sub == want_sub]
                if not hit or hit[0].pts != pts:
                    bad.append("%s entry %d: sector %d has %s, want PTS %d" % (
                        tag, j, sec, "PTS %s" % hit[0].pts if hit else "no such PES", pts))
                    continue
                if m["kind"] == "video":
                    pl = bytes(src.mm[hit[0].payload_off:hit[0].payload_off + 16])
                    k = pl.find(b"\x00\x00\x01\x09")
                    if k < 0 or k > 1:
                        bad.append("%s entry %d: payload does not open with an AUD (%s)"
                                   % (tag, j, pl.hex()))
                    elif b"\x00\x00\x01\x27" not in pl and b"\x00\x00\x01\x67" not in pl:
                        bad.append("%s entry %d: no SPS after the AUD (%s)" % (tag, j, pl.hex()))
    finally:
        src.close()
    return bad


def zero_fraction(iso_path, clip):
    """Fraction of a clip's sectors that are all zero (a damaged rip: Desperado's
    clips 1-5 are 98-100 % zeros while its CLPI tables are intact)."""
    import mmap
    import umd_iso
    with umd_iso.UmdIso(iso_path) as iso:
        e = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip)
        mm = mmap.mmap(iso.f.fileno(), 0, access=mmap.ACCESS_READ)
        z = bytes(SEC)
        step = max(1, e.nsec // 4096)
        idx = range(0, e.nsec, step)
        hits = sum(1 for k in idx if mm[(e.lba + k) * SEC:(e.lba + k + 1) * SEC] == z)
        mm.close()
    return hits / float(len(idx)) if len(idx) else 0.0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--clip", type=int, help="default: every clip")
    ap.add_argument("--entries", action="store_true", help="print every EP entry")
    ap.add_argument("--verify", action="store_true", help="cross-check against the .MPS")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    import umd_iso
    with umd_iso.UmdIso(a.iso) as iso:
        clips = [a.clip] if a.clip else iso.clip_infos()
        parsed = {n: from_iso(iso, n) for n in clips}
        orphans = sorted(set(iso.clips()) - set(iso.clip_infos()))
    if a.json:
        for c in parsed.values():
            if not a.entries:
                for m in c["ep_maps"]:
                    m["n_entries"] = len(m.pop("entries"))
        json.dump(parsed, sys.stdout, indent=1)
        print()
        return 0
    rc = 0
    for n in orphans:
        print("clip %05d: STREAM/%05d.MPS has no CLIPINF" % (n, n))
    for n, c in parsed.items():
        print("clip %05d: %d bytes, PTS %d..%d (%.1f s)" % (
            n, c["size"], c["start_pts"], c["end_pts"], (c["end_pts"] - c["start_pts"]) / 90000.0))
        for s in c["streams"]:
            print("  stream %02x/%02x %-8s attr %s%s" % (
                s["stream_id"], s["substream_id"], s["kind"], s["attr"],
                "  lang %r" % s["lang"] if "lang" in s else ""))
        for m in c["ep_maps"]:
            print("  EP map %02x/%02x %-8s %d entries" % (m["stream_id"], m["substream_id"],
                                                         m["kind"], len(m["entries"])))
            if a.entries:
                for fl, pts, sec in m["entries"]:
                    print("    %04x %10d %8d" % (fl, pts, sec))
        if a.verify:
            bad = verify(a.iso, n)
            print("  verify: %s" % ("OK" if not bad else "%d PROBLEM(S)" % len(bad)))
            if bad and zero_fraction(a.iso, n) > 0.5:
                print("    (the .MPS is mostly zero-filled sectors: a damaged image)")
            for b in bad[:10]:
                print("    " + b)
            rc |= bool(bad)
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ClpiError as e:
        sys.exit("umd_clpi: %s" % e)
