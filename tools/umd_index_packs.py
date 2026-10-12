#!/usr/bin/env python3
"""The 0xBF (private stream 2) index packs of a UMD .MPS: decode, and verify against
the video they index.

One 0xBF PES sits in the pack at EVERY video EP-map sector (umd_clpi.py) -- i.e. at
the head of each GOP -- and describes the GOP that follows. Decoded by this tool
(docs/umd_video_format.md "Index packs"; big-endian):

    +0   u8 0x01, u8 0xE0          (?) version, and the video stream id
    +2   u16 ref_end[4]            end sector of the 1st..4th reference picture (I/P) of
                                   the GOP, relative to this pack (0 = it ends in this
                                   very sector; 0xFFFF = the GOP has no such picture,
                                   The Incredibles) -- the DVD DSI VOBU_1STREF_EA idea.
                                   On field-coded GOPs the UNIT depends on the authoring:
                                   reference FIELDS on the US/UK discs, reference FRAMES
                                   (field pairs, ending at the second field) on Tom &
                                   Jerry Vol. 1 (Japan). verify() accepts either and
                                   counts which
    +10  u32 (?)                   0
    +14  u16 body_len              2 + 4 n
    +16  u16 n                     access units in the GOP
    +18  n x 4: u8 pic_struct, u8 flags, u16 au_bytes
                                   pic_struct = that AU's SEI pic_struct (3/4/5/6 on
                                   the 3:2 features, 1/2 = top/bottom FIELD on
                                   field-coded trailers); flags 0x80 on all but the
                                   last few (?); au_bytes = the AU's ES size MOD 65536
                                   (a 16-bit field: I-pictures over 64 KB wrap -- seen
                                   on Akira and xXx)
    end  4 bytes 00 (?)

Not needed to PLAY (the EP map seeks); useful for trick play (fast-forward from the
reference-end sectors) and as a free per-GOP golden of AU sizes for the P3 NAL parser.

    umd_index_packs.py disc.iso --clip N [--packs N] [--verify] [--dump K]
"""
import argparse
import bisect
import struct
import sys


class IndexError_(Exception):
    pass


def parse(pl):
    if len(pl) < 22 or pl[0] != 0x01 or pl[1] != 0xE0:
        raise IndexError_("not an index payload (%s)" % pl[:4].hex())
    refs = list(struct.unpack(">4H", pl[2:10]))
    unk, = struct.unpack(">I", pl[10:14])
    body, n = struct.unpack(">HH", pl[14:18])
    if 18 + 4 * n + 4 != len(pl) or body != 2 + 4 * n:
        raise IndexError_("index length mismatch: body %d, n %d, payload %d"
                          % (body, n, len(pl)))
    ents = [(pl[18 + 4 * i], pl[19 + 4 * i], struct.unpack(">H", pl[20 + 4 * i:22 + 4 * i])[0])
            for i in range(n)]
    return {"refs": refs, "unk": unk, "entries": ents, "tail": pl[-4:].hex()}


def video_aus(mm, result, start):
    """Access units of the video ES (split at AUDs) -> [(first_sector, last_sector,
    bytes, nal_ref_idc)], sectors relative to `start`."""
    es = bytearray()
    ends, secs = [], []
    for p in result.packets:
        if p.sid != 0xE0:
            continue
        es += mm[p.payload_off:p.payload_off + p.payload_len]
        ends.append(len(es))
        secs.append((p.offset - start) // 2048)

    def sec_of(off):
        return secs[bisect.bisect_right(ends, off)]

    aud = []
    k = es.find(b"\x00\x00\x01\x09")
    while k >= 0:
        aud.append(k - 1 if k and es[k - 1] == 0 else k)   # a 4-byte start code's 00
        k = es.find(b"\x00\x00\x01\x09", k + 4)
    out = []
    for a, b in zip(aud, aud[1:] + [len(es)]):
        ref = None
        j = es.find(b"\x00\x00\x01", a + 4, b)
        while j >= 0:
            t = es[j + 3] & 0x1F
            if t in (1, 5):
                ref = (es[j + 3] >> 5) & 3
                break
            j = es.find(b"\x00\x00\x01", j + 3, b)
        out.append((sec_of(a), sec_of(b - 1), b - a, ref))
    return out


def ref_ends_fields(gop, sec):
    """End sectors of the GOP's first four reference PICTURES (a field picture counts
    alone), 0xFFFF-padded."""
    e = [g[1] - sec for g in gop if g[3]][:4]
    return e + [0xFFFF] * (4 - len(e))


def ref_ends_frames(gop, entries, sec):
    """End sectors of the first four reference FRAMES: a field pair (pic_struct 1/2
    entries, taken two at a time) is one frame ending at its second field."""
    out, i = [], 0
    while i < len(gop) and len(out) < 4:
        n = 2 if entries[i][0] in (1, 2) and i + 1 < len(gop) else 1
        if any(g[3] for g in gop[i:i + n]):
            out.append(gop[i + n - 1][1] - sec)
        i += n
    return out + [0xFFFF] * (4 - len(out))


def verify(iso_path, clip, packs=None):
    """For every index pack in range whose GOP is wholly inside it: ref_end[] equal the
    end sectors of the GOP's first four reference pictures (0xFFFF-padded), and the entries'
    sizes equal the GOP's AU sizes mod 65536. Returns (checked, problems, n_wrapped)."""
    import psmf_ref
    src = psmf_ref.Source(iso_path, clip)
    clip_end = src.end
    src.limit(packs)
    whole = src.end == clip_end                  # the clip's last GOP is complete
    bad = []
    checked = 0
    wrapped = [0]
    conv = {"field": 0, "frame": 0, "either": 0}
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
        aus = video_aus(src.mm, r, src.start)
        firsts = [a[0] for a in aus]
        idx = [p for p in r.packets if p.sid == 0xBF]
        for p in idx:
            sec = (p.offset - src.start) // 2048
            pl = bytes(src.mm[p.payload_off:p.payload_off + p.payload_len])
            try:
                d = parse(pl)
            except IndexError_ as e:
                bad.append("sector %d: %s" % (sec, e))
                continue
            i0 = bisect.bisect_left(firsts, sec)
            gop = aus[i0:i0 + len(d["entries"])]
            if len(gop) < len(d["entries"]) or (i0 + len(gop) >= len(aus) and not whole):
                continue                         # GOP runs past the parsed range
            checked += 1
            sizes = [e[2] for e in d["entries"]]
            if sizes != [g[2] & 0xFFFF for g in gop]:
                k = next(i for i, (x, y) in enumerate(zip(sizes, gop)) if x != y[2] & 0xFFFF)
                bad.append("sector %d: entry %d size %d != AU %d bytes (mod 65536)"
                           % (sec, k, sizes[k], gop[k][2]))
            wrapped[0] += sum(1 for g in gop if g[2] > 0xFFFF)
            by_field = ref_ends_fields(gop, sec)
            by_frame = ref_ends_frames(gop, d["entries"], sec)
            if d["refs"] == by_field == by_frame:
                conv["either"] += 1              # frame-coded GOPs: the readings agree
            elif d["refs"] == by_field:
                conv["field"] += 1
            elif d["refs"] == by_frame:
                conv["frame"] += 1
            else:
                bad.append("sector %d: ref_end %s != reference fields %s or frames %s"
                           % (sec, d["refs"], by_field, by_frame))
    finally:
        src.close()
    return checked, bad, wrapped[0], conv


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--clip", type=int, required=True)
    ap.add_argument("--packs", type=int)
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--dump", type=int, default=0, help="print the first K index packs")
    a = ap.parse_args(argv)
    import psmf_ref
    src = psmf_ref.Source(a.iso, a.clip)
    src.limit(a.packs)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
        idx = [p for p in r.packets if p.sid == 0xBF]
        n_max = 0
        kinds = {}                       # pic_struct histogram
        for k, p in enumerate(idx):
            d = parse(bytes(src.mm[p.payload_off:p.payload_off + p.payload_len]))
            n_max = max(n_max, len(d["entries"]))
            for e in d["entries"]:
                kinds[e[0]] = kinds.get(e[0], 0) + 1
            if k < a.dump:
                print("sector %d: ref_end %s, %d AUs, pic_struct %s" % (
                    (p.offset - src.start) // 2048, d["refs"], len(d["entries"]),
                    "".join(str(e[0]) for e in d["entries"][:24])))
        print("%d index packs, up to %d AUs per GOP, pic_struct %s" % (len(idx), n_max, kinds))
    finally:
        src.close()
    if a.verify:
        checked, bad, wrapped, conv = verify(a.iso, a.clip, a.packs)
        print("verify: %d GOPs checked, %s (%d AUs over 64 KB, size wrapped; ref_end "
              "counts fields in %d GOPs, frames in %d, either in %d)" % (
                  checked, "OK" if not bad else "%d PROBLEM(S)" % len(bad), wrapped,
                  conv["field"], conv["frame"], conv["either"]))
        for b in bad[:10]:
            print("  " + b)
        return 1 if bad or not checked else 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except IndexError_ as e:
        sys.exit("umd_index_packs: %s" % e)
