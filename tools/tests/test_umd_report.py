#!/usr/bin/env python3
"""umd_report.py (the bug bundle, docs/bug_reports.md) on a synthetic disc, no media.

The disc is built HERE from the format notes, with this file's own encoders (a bit writer
with emulation prevention, a PNG writer cycling the five row filters, the RCO tables), never
from umd_report's helpers, and read back with the repository's other parsers (umd_iso,
psmf_ref) -- so a scrub bug and a test bug have to agree to hide.

Covers: the tree and the table files byte-exact; a file outside the capture list absent; the
RCO's non-media bytes exact, each PNG / JPEG replaced by a stand-in of the same size and alpha
box, each VAG's header kept and samples zeroed; the stream head's pack / PES headers, system
header, index pack, SPS / PPS / SEI / AUD exact, each slice (IDR field, P with list
modification + weights + MMCO, B) exact to the end of its header and zero after, audio AU
headers exact and bodies zero, the subtitle unit's header exact and its picture a blank of
the same size, unknown NAL types and a garbage sector zero; a bare .MPS; and the audit
refusing each kind of leak -- including leaks a re-scrub cannot see (the parser-free ceiling,
the subtitle check), a silhouette, a stray sector -- and verify refusing a changed table.
"""
import os
import random
import shutil
import struct
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_iso  # noqa: E402
import psmf_ref  # noqa: E402
import umd_report as ur  # noqa: E402

T = S.Score("test_umd_report")
check = T.check
SEC = S.SEC
rnd = random.Random(20261006)


def noise(n, nonzero=True):
    return bytes(rnd.randrange(1 if nonzero else 0, 256) for _ in range(n))


# ---------------------------------------------------------------- H.264 bits
class BW(object):
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        self.bits += [(v >> (n - 1 - i)) & 1 for i in range(n)]

    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(n - 1, 0)
        self.u(n, v)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def align_ones(self):
        while len(self.bits) % 8:
            self.bits.append(1)

    def trailing(self):
        self.bits.append(1)
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        assert len(self.bits) % 8 == 0
        return bytes(int("".join(map(str, self.bits[i:i + 8])), 2) for i in range(0, len(self.bits), 8))


def epb(rbsp):
    out, z = bytearray(), 0
    for b in rbsp:
        if z >= 2 and b <= 3:
            out.append(3)
            z = 0
        out.append(b)
        z = z + 1 if b == 0 else 0
    return bytes(out)


def sps():
    w = BW()
    w.u(8, 77); w.u(8, 0x40); w.u(8, 30); w.ue(0)
    w.ue(0)                       # log2_max_frame_num 4
    w.ue(0); w.ue(2)              # POC type 0, lsb 6 bits
    w.ue(3); w.u(1, 0); w.ue(44); w.ue(14)
    w.u(1, 0); w.u(1, 0)          # frame_mbs_only 0 (fields), mbaff 0
    w.u(1, 1); w.u(1, 0); w.u(1, 0)
    w.trailing()
    return b"\x67" + epb(w.bytes())


def pps():
    w = BW()
    w.ue(0); w.ue(0); w.u(1, 1); w.u(1, 1); w.ue(0); w.ue(2); w.ue(0)
    w.u(1, 1); w.u(2, 0); w.se(0); w.se(0); w.se(0)
    w.u(1, 1); w.u(1, 0); w.u(1, 0)
    w.trailing()
    return b"\x68" + epb(w.bytes())


def slice_nal(kind):
    """(the NAL, the length of its header part in NAL bytes)."""
    w = BW()
    if kind == "idr":                       # I, a field, deblocking offsets
        hdr = 0x65
        w.ue(0); w.ue(7); w.ue(0); w.u(4, 0); w.u(1, 1); w.u(1, 0); w.ue(65535); w.u(6, 0)   # idr_pic_id 65535: an EPB in the header
        w.u(1, 0); w.u(1, 0)                 # no_output_of_prior_pics, long_term_reference
        w.se(-3); w.ue(0); w.se(1); w.se(-1)
        body = 600
    elif kind == "p":                       # P frame: override, list modification, weights, MMCO
        hdr = 0x41
        w.ue(0); w.ue(5); w.ue(0); w.u(4, 1); w.u(1, 0); w.u(6, 4); w.se(0)
        w.u(1, 1); w.ue(1)
        w.u(1, 1); w.ue(0); w.ue(0); w.ue(3)
        w.ue(5); w.ue(5)
        for _ in range(2):
            w.u(1, 1); w.se(2); w.se(-1); w.u(1, 0)
        w.u(1, 1); w.ue(1); w.ue(0); w.ue(0)
        w.ue(1); w.se(2); w.ue(1)
        body = 400
    elif kind == "pfield":                  # P, a bottom field, reference, sliding window
        hdr = 0x21
        w.ue(0); w.ue(0); w.ue(0); w.u(4, 3); w.u(1, 1); w.u(1, 1); w.u(6, 9)
        w.u(1, 0); w.u(1, 0)                 # no override, no list modification
        w.ue(3); w.ue(2)                     # the weight table (weighted_pred_flag): 3 refs
        for _ in range(3):
            w.u(1, 0); w.u(1, 0)
        w.u(1, 0)                            # sliding window
        w.ue(0); w.se(-4); w.ue(2); w.se(1); w.se(0)
        body = 350
    else:                                   # B, non-reference
        hdr = 0x01
        w.ue(0); w.ue(6); w.ue(0); w.u(4, 2); w.u(1, 0); w.u(6, 2); w.se(0)
        w.u(1, 1); w.u(1, 0); w.u(1, 0); w.u(1, 0)
        w.ue(2); w.se(0); w.ue(0); w.se(0); w.se(0)
        body = 300
    w.align_ones()
    head = w.bytes()
    if kind == "idr":
        assert b"\x00\x00\x03" in epb(head), "the IDR header must carry an emulation prevention byte"
    nal = bytes([hdr]) + epb(head + noise(body, nonzero=False))
    return nal, 1 + len(epb(head))


def video_es():
    """[(NAL bytes, kept length)] and the ES (start codes included)."""
    nals = [(b"\x09\xf0", 2), (sps(), None), (pps(), None),
            (b"\x06\x01\x05" + noise(5) + b"\x80", None)]
    for k in ("idr", "p", "b", "pfield", "b"):
        nals.append(slice_nal(k))
        nals.append((b"\x09\x30", 2))
    nals.append((b"\x0e" + noise(40), 1))             # an unknown type: its header byte only
    nals.append((b"\x0c" + b"\xff" * 30, 1))          # filler: its header byte only
    out = [(n, len(n) if k is None else k) for n, k in nals]
    return out, b"".join(b"\x00\x00\x01" + n for n, _ in out)


# ---------------------------------------------------------------- PNG / JPEG / VAG
def png(w, h, ct, pixels, plte=None, trns=None, depth=8):
    """Rows filtered with type (y mod 5): 0 none, 1 Sub, 2 Up, 3 Average, 4 Paeth."""
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    raw, prev = bytearray(), bytearray(w * bpp)
    for y in range(h):
        row = bytearray(pixels[y])
        ft = y % 5
        f = bytearray(len(row))
        for i in range(len(row)):
            a = row[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            pred = (0, a, b, (a + b) // 2, ur._paeth(a, b, c))[ft] if ft else 0
            f[i] = (row[i] - pred) & 0xFF
        raw += bytes([ft]) + f
        prev = row

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ct, 0, 0, 0))
    if plte:
        out += chunk(b"PLTE", plte)
    if trns:
        out += chunk(b"tRNS", trns)
    return out + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


def rgba_boxed(w, h, box):
    x0, y0, x1, y1 = box
    rows = []
    for y in range(h):
        r = bytearray()
        for x in range(w):
            inside = x0 <= x <= x1 and y0 <= y <= y1
            r += bytes((rnd.randrange(256), rnd.randrange(256), rnd.randrange(256), rnd.randrange(1, 256) if inside else 0))
        rows.append(r)
    return rows


def jpeg(w, h, n=3000):
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, h, w, 1) + b"\x01\x11\x00"
    return b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" + sof + noise(n) + b"\xff\xd9"


def vag(n=1000):
    return b"VAGp" + struct.pack(">IIII", 4, 0, n, 44100) + bytes(28) + noise(n)


# ---------------------------------------------------------------- the RCO
def rco():
    """Header, an image table (PNG with an alpha box, palette PNG, JPEG), a sound table
    (one mono VAG), an unreferenced 'script' blob, the media regions. Returns (bytes, the
    script blob's offset and bytes, [(image offset, original bytes)], (vag offset, bytes))."""
    p1 = png(40, 30, 6, rgba_boxed(40, 30, (5, 4, 30, 20)))
    p2 = png(16, 16, 3, [bytes(rnd.randrange(4) for _ in range(16)) for _ in range(16)], plte=noise(12))
    j1 = jpeg(64, 48)
    v1 = vag()
    images = [(0, p1), (0, p2), (1, j1)]
    tree = bytearray()
    base = 0xA4
    img_root = base
    tree += struct.pack("<HHIIIIIIIII", 0x0400, 0, 0xFFFFFFFF, 0x28, 0, len(images), 0, 0, 0, 0, 0)
    imgdata = bytearray()
    for i, (fmt, b) in enumerate(images):
        nxt = 0x28 + 12 if i < len(images) - 1 else 0
        tree += struct.pack("<HHIIIIIIIII", 0x0401, 0, 0xFFFFFFFF, 0x28, 0, 0, nxt, 0, 0, 0, 0)
        tree += struct.pack("<HHII", fmt, 0, len(b), len(imgdata))
        imgdata += b + bytes((-len(b)) % 4)
    snd_root = base + len(tree)
    tree += struct.pack("<HHIIIIIIIII", 0x0600, 0, 0xFFFFFFFF, 0x28, 0, 1, 0, 0, 0, 0, 0)
    tree += struct.pack("<HHIIIIIIIII", 0x0601, 0, 0xFFFFFFFF, 0x28, 0, 0, 0, 0, 0, 0, 0)
    tree += struct.pack("<HHIIIIII", 1, 1, len(v1), 0, len(v1), 0, 0, 0)
    script_at = base + len(tree)
    script = noise(300)
    tree += script
    img_at = base + len(tree)
    snd_at = img_at + len(imgdata)
    h = [0xFFFFFFFF] * 37
    h[ur.H_IMAGE], h[ur.H_SOUND] = img_root, snd_root
    h[ur.H_IMGDATA], h[ur.H_IMGDATA + 1] = img_at, len(imgdata)
    h[ur.H_SOUNDDATA], h[ur.H_SOUNDDATA + 1] = snd_at, len(v1)
    h[ur.H_MODELDATA], h[ur.H_MODELDATA + 1] = 0, 0
    head = b"\0PRF" + struct.pack("<III", 0x71, 0, 0x01) + struct.pack("<37I", *h)
    assert len(head) == base
    data = head + bytes(tree) + bytes(imgdata) + v1
    offs, p = [], img_at
    for fmt, b in images:
        offs.append((fmt, p, b))
        p += len(b) + ((-len(b)) % 4)
    return data, (script_at, script), offs, (snd_at, v1)


# ---------------------------------------------------------------- the stream
def au(nbytes=512):
    params = (2 << 13) | (2 << 10) | ((nbytes - 8) // 8)
    return b"\x0f\xd0" + struct.pack(">H", params) + b"\0\0\0\0" + noise(nbytes)


def sub_unit():
    w, h = 60, 20
    pic = png(w, h, 3, [bytes(rnd.randrange(256) for _ in range((w + 1) // 2)) for _ in range(h)],
              plte=noise(48), trns=noise(16, nonzero=False), depth=4)
    body = b"0088" + struct.pack(">IHHHH", 9000, 0x10, 100, 400, 0) + pic
    return struct.pack(">I", len(body)) + body, (w, h)


def stream():
    """Packs: the system header and an index pack, then video / audio / subtitle PES
    interleaved, a NAL / AU / unit straddling PES boundaries; then a garbage sector."""
    nals, ves = video_es()
    aus = [au() for _ in range(6)]
    aes = b"".join(aus)
    unit, dims = sub_unit()
    vcut = [len(ves) * k // 5 for k in range(6)]
    acut = [0, 300, 900, 1500, 2300, len(aes)]
    starts = [i * 520 for i in range(6)]
    packs = []
    for k in range(5):
        pk = []
        if k == 0:
            pk.append(S.pes(0xBB, b"\x80\xc3\x51\x20\xe9\x7f" + bytes(6)))
            pk.append(S.pes(0xBF, b"\x01\xe0" + noise(40)))
        pk.append(S.pes(0xE0, ves[vcut[k]:vcut[k + 1]], pts=9000 + 3003 * k if k in (0, 2) else None))
        a0, a1 = acut[k], acut[k + 1]
        fap = next((s - a0 for s in starts if a0 <= s < a1), 0xFFFF)
        pk.append(S.pes(0xBD, bytes([0x00, 0x00]) + struct.pack(">H", fap) + aes[a0:a1], pts=9000 + 1000 * k))
        if k == 1:
            pk.append(S.pes(0xBD, b"\x81\x00" + unit[:150], pts=12000))
        if k == 2:
            pk.append(S.pes(0xBD, b"\x81\x00" + unit[150:]))
        packs.append(S.fill_pack(pk, scr=k * 100))
    packs.append(noise(SEC))
    return b"".join(packs), nals, aus, unit, dims


# ---------------------------------------------------------------- the disc
LAYOUT = {"root": 18, "uv": 19, "clipinf": 20, "stream": 21, "res": 22, "data": 23, "sfo": 24,
          "pl": 25, "clp": 26, "icon": 27, "rco": 30, "mps": 60}


def disc():
    L = LAYOUT
    rdata, script, imgs, snd = rco()
    mps, nals, aus, unit, dims = stream()
    sfo = b"\0PSF" + noise(200)
    pl = S.playlist_file([S.entry("MAIN", [("00001", 90000, 900000)], [])])
    clp = S.clpi([(0xE0, 0, bytes(8))], [(0xE0, 0, [(0, 90000, 0)])])
    total = L["mps"] + len(mps) // SEC + 4
    b = S.ImageBuilder(total)
    b.put(16, S.pvd(L["root"], SEC, total))
    b.put(17, S.terminator())
    F = 0
    b.put(L["root"], S.dir_sectors(L["root"], L["root"], [("UMD_DATA.BIN;1", L["data"], 40, F),
                                                         ("UMD_VIDEO", L["uv"], SEC, 2)]))
    b.put(L["uv"], S.dir_sectors(L["uv"], L["root"], [
        ("CLIPINF", L["clipinf"], SEC, 2), ("ICON0.PNG;1", L["icon"], 1500, F),
        ("PARAM.SFO;1", L["sfo"], len(sfo), F), ("PLAYLIST.UMD;1", L["pl"], len(pl), F),
        ("RESOURCE", L["res"], SEC, 2), ("STREAM", L["stream"], SEC, 2)]))
    b.put(L["clipinf"], S.dir_sectors(L["clipinf"], L["uv"], [("00001.CLP;1", L["clp"], len(clp), F)]))
    b.put(L["res"], S.dir_sectors(L["res"], L["uv"], [("EN100000.RCO;1", L["rco"], len(rdata), F)]))
    b.put(L["stream"], S.dir_sectors(L["stream"], L["uv"], [("00001.MPS;1", L["mps"], len(mps), F)]))
    b.put(L["data"], b"Synthetic|UMDV-00000|0001|G" + bytes(13))
    b.put(L["sfo"], sfo)
    b.put(L["pl"], pl)
    b.put(L["clp"], clp)
    b.put(L["icon"], noise(1500))
    b.put(L["rco"], rdata)
    b.put(L["mps"], mps)
    return b.build(), {"rco": rdata, "script": script, "imgs": imgs, "snd": snd, "mps": mps,
                       "nals": nals, "aus": aus, "unit": unit, "dims": dims}


# ---------------------------------------------------------------- helpers
TMP = tempfile.mkdtemp(prefix="umdrep_")


def write(name, data):
    p = os.path.join(TMP, name)
    open(p, "wb").write(data)
    return p


def make(img_path, name="b.zip", packs=ur.DEFAULT_PACKS):
    out = os.path.join(TMP, name)
    rc = ur.main([img_path, "--no-prompt", "-o", out, "--packs", str(packs)])
    return rc, out


def repro(zp):
    man, sec = ur.read_bundle(zp)
    return man, sec, ur.SparseImage(sec, man["image"]["size"])


def span(sec, lba, n):
    return b"".join(sec.get(lba + i, bytes(SEC)) for i in range(n))


def audit_raises(label, man, sec, frag):
    try:
        ur.audit(man, sec)
    except ur.AuditError as e:
        ok = frag in str(e)
        print("  %s %s: refused (%s)" % ("PASS" if ok else "FAIL", label, e))
        T.fails += 0 if ok else 1
        return
    print("  FAIL %s: the audit passed" % label)
    T.fails += 1


def png_box(data):
    """The stand-in's visible box, decoded here (palette, 1-bit, filter 0 rows; an index is
    visible when its tRNS entry, 255 without one, is not 0)."""
    w, h = struct.unpack(">II", data[16:24])
    p, idat, trns = 8, b"", b""
    while p < len(data):
        n = struct.unpack(">I", data[p:p + 4])[0]
        if data[p + 4:p + 8] == b"tRNS":
            trns = data[p + 8:p + 8 + n]
        if data[p + 4:p + 8] == b"IDAT":
            idat += data[p + 8:p + 8 + n]
        if data[p + 4:p + 8] == b"IEND":
            break
        p += 12 + n
    raw = zlib.decompress(idat)
    stride = 1 + (w + 7) // 8
    vis = [(trns[i] if i < len(trns) else 255) > 0 for i in range(2)]
    pts = [(x, y) for y in range(h) for x in range(w)
           if vis[(raw[y * stride + 1 + x // 8] >> (7 - x % 8)) & 1]]
    if not pts:
        return None
    return (min(x for x, _ in pts), min(y for _, y in pts), max(x for x, _ in pts), max(y for _, y in pts))


# ================================================================= the arms
img, K = disc()
ip = write("disc.iso", img)
rc, zp = make(ip)
check("make: exit 0 (its own audit and verify passed)", rc, 0)
man, sec, rimg = repro(zp)
check("make: kind iso", man["kind"], "iso")
check("make: the image's basename only", man["image"]["name"], "disc.iso")
ur.audit(man, sec)
check("audit: the bundle as read back passes", True, True)

# -- the tree and the tables
up = os.path.join(TMP, "repro.iso")
ur.main(["unpack", zp, "-o", up])
check("unpack: the original size", os.path.getsize(up), len(img))
o, r = umd_iso.UmdIso(ip), umd_iso.UmdIso(up)
check("tree: every path, extent and size identical",
      {k: (v.lba, v.size, v.is_dir) for k, v in o.files.items()},
      {k: (v.lba, v.size, v.is_dir) for k, v in r.files.items()})
for f in ("/UMD_DATA.BIN", "/UMD_VIDEO/PARAM.SFO", "/UMD_VIDEO/PLAYLIST.UMD", "/UMD_VIDEO/CLIPINF/00001.CLP"):
    check("table %s identical" % f, r.read(f) == o.read(f), True)
check("ICON0.PNG not captured (zero)", any(r.read("/UMD_VIDEO/ICON0.PNG")), False)

# -- the RCO
rr = r.read("/UMD_VIDEO/RESOURCE/EN100000.RCO")
orc = K["rco"]
media = bytearray(len(orc))
hd = ur.Rco(orc)
for at, ln in hd.regions:
    media[at:at + ln] = b"\x01" * ln
check("rco: every byte outside the media regions identical",
      all(rr[i] == orc[i] for i in range(len(orc)) if not media[i]), True)
sa, sb = K["script"]
check("rco: the script blob exact", rr[sa:sa + len(sb)], sb)
fmt, at, src = K["imgs"][0]
rep = rr[at:at + len(src)]
check("rco png (RGBA, boxed): same size", struct.unpack(">II", rep[16:24]), (40, 30))
check("rco png (RGBA, boxed): the alpha box kept", png_box(rep), (5, 4, 30, 20))
end = ur._png_end(rep)
check("rco png: zero after IEND", any(rep[end:]), False)
fmt, at, src = K["imgs"][1]
rep = rr[at:at + len(src)]
check("rco png (palette, no tRNS): the whole image opaque", png_box(rep), (0, 0, 15, 15))
fmt, at, src = K["imgs"][2]
rep = rr[at:at + len(src)]
check("rco jpeg: a JPEG of the same size", (rep[:2], ur.jpeg_dims(rep)), (b"\xff\xd8", (64, 48)))
check("rco jpeg: not the original", rep[:len(src)] != src, True)
sat, sv = K["snd"]
check("rco vag: the 48-byte header kept", rr[sat:sat + 48], sv[:48])
check("rco vag: the samples zero", any(rr[sat + 48:sat + len(sv)]), False)

# -- the stream head
om, rm = K["mps"], span(sec, LAYOUT["mps"], len(K["mps"]) // SEC)
po, pr = psmf_ref.parse(om[:-SEC]), psmf_ref.parse(rm[:-SEC])
check("stream: the same packets", [(p.offset, p.sid, p.sub, p.pts) for p in po.packets],
      [(p.offset, p.sid, p.sub, p.pts) for p in pr.packets])
for k in range(5):
    q = k * SEC
    check("stream pack %d: the pack header exact" % k, rm[q:q + 14], om[q:q + 14])
p0 = [p for p in po.packets if p.sid == 0xBF][0]
check("stream: the index pack exact", rm[p0.offset:p0.offset + p0.pes_len], om[p0.offset:p0.offset + p0.pes_len])
pads = [p for p in pr.packets if p.sid == 0xBE]
check("stream: padding payloads zero", any(any(rm[p.payload_off:p.payload_off + p.payload_len]) for p in pads), False)
ves, _ = psmf_ref.es(rm, pr, "video")
pos, bad = 0, []
for i, (nal, keep) in enumerate(K["nals"]):
    pos += 3
    got = ves[pos:pos + len(nal)]
    want = nal[:keep] + bytes(len(nal) - keep)
    if got != want:
        bad.append((i, nal[0] & 0x1F, keep, next(j for j in range(len(nal)) if got[j] != want[j])))
    pos += len(nal)
check("stream video: every NAL exact to its kept length, zero after", bad, [])
aes, _ = psmf_ref.es(rm, pr, "audio", 0)
pos, bad = 0, 0
for a in K["aus"]:
    bad += aes[pos:pos + 8] != a[:8] or any(aes[pos + 8:pos + len(a)])
    pos += len(a)
check("stream audio: each AU header exact, its body zero", bad, 0)
ses, _ = psmf_ref.es(rm, pr, "sub", 0x81)
u = K["unit"]
check("stream subtitle: the 20-byte unit header exact", ses[:20], u[:20])
check("stream subtitle: a picture of the same size", ur.png_ihdr(ses[20:len(u)])[:2], K["dims"])
check("stream subtitle: not the original picture", ses[20:len(u)] != u[20:], True)
check("stream: the garbage sector zero", any(rm[-SEC:]), False)
check("scrub: counters", {k: man["scrub"].get(k) for k in ("images_blanked", "sounds_silenced", "subtitles_blanked",
                                                             "slices_kept_as_headers", "audio_frames_kept_as_headers",
                                                             "packs_unparsed")},
      {"images_blanked": 3, "sounds_silenced": 1, "subtitles_blanked": 1, "slices_kept_as_headers": 5,
       "audio_frames_kept_as_headers": 6, "packs_unparsed": 1})
check("scrub: no slice unparsed", man["scrub"].get("slices_unparsed"), None)

# -- a bare .MPS
mp = write("00001.MPS", K["mps"])
rc, zb = make(mp, "bare.zip")
mb, sb2, _ = repro(zb)
check("bare .MPS: kind mps, audit passes", (rc, mb["kind"]), (0, "mps"))
check("bare .MPS: the same scrub as in the image", span(sb2, 0, len(K["mps"]) // SEC), rm)
rc, zh = make(ip, "head.zip", packs=2)
mh, sh, _ = repro(zh)
check("--packs 2: two packs of the stream", [f["sectors"] for f in mh["files"] if f["kind"] == "stream-head"], [2])

# -- the audit refuses
def mutated(edit):
    s2 = dict(sec)
    edit(s2)
    return man, s2


def put_byte(s2, lba, off, v):
    b = bytearray(s2[lba])
    b[off] = v
    s2[lba] = bytes(b)


slice_pk = [p for p in pr.packets if p.sid == 0xE0][0]
body_at = slice_pk.payload_off + 400                  # inside the IDR slice's body
audit_raises("a slice body byte left non-zero", *mutated(
    lambda s2: put_byte(s2, LAYOUT["mps"], body_at, 0x5A)), "no header accounts for")
rco_lba = LAYOUT["rco"]
fmt, at, src = K["imgs"][0]
def leave_png(s2):
    b = bytearray(span(s2, rco_lba, (len(orc) + SEC - 1) // SEC))
    b[at:at + len(src)] = src
    for i in range(0, len(b), SEC):
        s2[rco_lba + i // SEC] = bytes(b[i:i + SEC])
audit_raises("an RCO image left as it was", *mutated(leave_png), "not a flat stand-in")
audit_raises("a VAG sample left non-zero", *mutated(
    lambda s2: put_byte(s2, rco_lba + (sat + 60) // SEC, (sat + 60) % SEC, 0x11)), "non-zero samples")
audit_raises("a stray sector", *mutated(lambda s2: s2.__setitem__(LAYOUT["mps"] + 50, noise(SEC))),
             "belongs to no captured file")
sil = ur.png_flat(40, 30, (5, 4, 30, 20))
check("png_flat_check: a stand-in passes", ur.png_flat_check(sil), True)
check("png_flat_check: the opaque whole-image form passes", ur.png_flat_check(ur.png_flat(214, 120, (0, 0, 213, 119))), True)
check("png_flat: the opaque whole-image form fits Hackers' 113 bytes", len(ur.png_flat(214, 120, (0, 0, 213, 119))) <= 113, True)
holed = bytearray(zlib.decompress(b"".join(c[1] for c in ur.png_chunks(sil) if c[0] == b"IDAT")))
holed[10 * 6 + 2] ^= 0x10                          # a hole in the box: a silhouette
sil2 = ur.PNG_SIG + ur._chunk(b"IHDR", struct.pack(">IIBBBBB", 40, 30, 1, 3, 0, 0, 0)) + \
    ur._chunk(b"PLTE", bytes((0, 0, 0) + ur.GREY)) + ur._chunk(b"tRNS", bytes((0, 255))) + \
    ur._chunk(b"IDAT", zlib.compress(bytes(holed))) + ur._chunk(b"IEND", b"")
check("png_flat_check: a silhouette in one colour fails", ur.png_flat_check(sil2), False)

# leaks a re-scrub cannot see: the scrubber itself broken the same way twice
real_video, real_sub = ur._video_keep, ur._sub_blank
def leaky_video(es, stats):
    return [(bo, ln) for eo, bo, ln in es.segs]          # every video byte kept
ur._video_keep = leaky_video
try:
    leak = ur.scrub_stream(K["mps"], {})
finally:
    ur._video_keep = real_video
def put_leak(s2):
    for i in range(len(leak) // SEC):
        s2[LAYOUT["mps"] + i] = leak[i * SEC:(i + 1) * SEC]
ur._video_keep = leaky_video
try:
    audit_raises("a scrubber that keeps whole slices (the parser-free ceiling)", *mutated(put_leak), "non-zero payload bytes")
finally:
    ur._video_keep = real_video
def leaky_sub(es, stats):
    return [(bo, bytes(es.data[eo:eo + ln])) for eo, bo, ln in es.segs]      # every subtitle byte kept
ur._sub_blank = leaky_sub
try:
    leak2 = ur.scrub_stream(K["mps"], {})
    def put_leak2(s2):
        for i in range(len(leak2) // SEC):
            s2[LAYOUT["mps"] + i] = leak2[i * SEC:(i + 1) * SEC]
    audit_raises("a scrubber that keeps the subtitle picture (the unit check)", *mutated(put_leak2),
                 "not a blank stand-in")
finally:
    ur._sub_blank = real_sub

# -- verify refuses a changed table
def bad_table(s2):
    put_byte(s2, LAYOUT["pl"], 100, (sec[LAYOUT["pl"]][100] + 1) & 0xFF)
_, s3 = mutated(bad_table)
try:
    ur.verify(ip, man, s3)
    check("verify: a changed PLAYLIST.UMD refused", "passed", "refused")
except ur.ReportError as e:
    check("verify: a changed PLAYLIST.UMD refused", "differs" in str(e), True)

shutil.rmtree(TMP, ignore_errors=True)
T.finish()
