#!/usr/bin/env python3
"""Every subtitle PNG of every disc image, cached once, and held to the rules the fabric
decoder enforces (docs/png_decode.md) -- the P7 corpus.

PIL (umd_sub_extract.png_info) says a PNG decodes; it forgives things the RTL refuses or
flags. This tool says, per PNG, what a strict reader sees:

  * the signature, each chunk's CRC-32 (critical and ancillary counted apart), anything
    after IEND, chunk order (IHDR first, PLTE before IDAT, IDAT contiguous)
  * IHDR: colour type, bit depth, interlace, width, height
  * the zlib stream over the concatenated IDAT: header (CM, CINFO, FDICT, FLEVEL),
    a strict decompress (zlib checks the Adler-32), bytes after the zlib stream,
    whether the stream ended at all
  * the inflated length against the exact row-byte total (Adam7 pass geometry included)
  * filter-byte histogram, PLTE / tRNS lengths, the largest palette index used (PIL)

`--dump` caches each disc's units under DIR/<disc>/ (a PNG per unit + index.json with
pts / x / y / duration), so benches read the cache instead of re-walking an ISO; a disc
already cached is not walked again.

    png_corpus.py --dump bench/umd/fixtures/gen/png_corpus [--jobs N] [images...]
    png_corpus.py --report bench/umd/fixtures/gen/png_corpus [--json out.json]

Without image arguments, every .iso under $UMD_ISO_DIR (recursive; .zip images are
reported as skipped).
"""
import argparse
import binascii
import glob
import io
import json
import multiprocessing
import os
import re
import struct
import sys
import traceback
import zlib
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SIG = b"\x89PNG\r\n\x1a\n"
# Adam7: (x0, y0, dx, dy) per pass (PNG spec 8.2)
ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
         (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def slug(path):
    s = re.sub(r"[^A-Za-z0-9]+", "_", os.path.splitext(os.path.basename(path))[0]).strip("_")
    return s[:60]


def row_bytes(w, ctype, depth):
    return (w * CHANNELS[ctype] * depth + 7) // 8


def raw_size(w, h, ctype, depth, interlace):
    """Bytes the zlib stream must inflate to: filter byte + row bytes per row, per pass."""
    if not interlace:
        return h * (1 + row_bytes(w, ctype, depth))
    n = 0
    for x0, y0, dx, dy in ADAM7:
        pw = (w - x0 + dx - 1) // dx if w > x0 else 0
        ph = (h - y0 + dy - 1) // dy if h > y0 else 0
        if pw and ph:
            n += ph * (1 + row_bytes(pw, ctype, depth))
    return n


def filter_bytes(raw, w, h, ctype, depth, interlace):
    """The filter byte of every row, in stream order (raw must be the exact length)."""
    out = []
    passes = ADAM7 if interlace else ((0, 0, 1, 1),)
    o = 0
    for x0, y0, dx, dy in passes:
        pw = (w - x0 + dx - 1) // dx if w > x0 else 0
        ph = (h - y0 + dy - 1) // dy if h > y0 else 0
        if not (pw and ph):
            continue
        rb = row_bytes(pw, ctype, depth)
        for _ in range(ph):
            out.append(raw[o])
            o += 1 + rb
    return out


def strict(png):
    """-> dict of what a strict reader sees; never raises on malformed input."""
    r = {"sig_ok": png[:8] == SIG, "crc_bad_critical": 0, "crc_bad_ancillary": 0,
         "after_iend": 0, "chunks": [], "order_ok": True}
    o = 8
    idat = bytearray()
    seen_idat_end = False
    plte = trns = None
    ihdr = None
    while o + 12 <= len(png):
        ln, = struct.unpack(">I", png[o:o + 4])
        typ = png[o + 4:o + 8]
        data = png[o + 8:o + 8 + ln]
        crc, = struct.unpack(">I", png[o + 8 + ln:o + 12 + ln]) if o + 12 + ln <= len(png) else (None,)
        ok = crc is not None and binascii.crc32(typ + data) & 0xFFFFFFFF == crc
        name = typ.decode("latin-1")
        crit = bool(typ[:1]) and typ[0] & 0x20 == 0
        r["chunks"].append(name)
        if not ok:
            r["crc_bad_critical" if crit else "crc_bad_ancillary"] += 1
        if name == "IHDR":
            if len(r["chunks"]) != 1:
                r["order_ok"] = False
            w, h, depth, ctype, comp, filt, il = struct.unpack(">IIBBBBB", data[:13])
            ihdr = dict(w=w, h=h, depth=depth, ctype=ctype, comp=comp, filt=filt, interlace=il)
        elif name == "PLTE":
            if idat:
                r["order_ok"] = False
            plte = len(data) // 3
        elif name == "tRNS":
            trns = len(data)
        elif name == "IDAT":
            if seen_idat_end:
                r["order_ok"] = False          # IDAT chunks must be consecutive
            idat += data
        elif idat:
            seen_idat_end = True
        o += 12 + ln
        if name == "IEND":
            break
    r["after_iend"] = len(png) - o
    r["ihdr"] = ihdr
    r["plte"] = plte
    r["trns"] = trns
    r["idat_bytes"] = len(idat)
    if len(idat) >= 2:
        cmf, flg = idat[0], idat[1]
        r["zhdr"] = dict(cm=cmf & 15, cinfo=cmf >> 4, fdict=(flg >> 5) & 1, flevel=flg >> 6,
                         fcheck_ok=(cmf * 256 + flg) % 31 == 0)
    d = zlib.decompressobj()
    try:
        raw = d.decompress(bytes(idat))
        r["zlib_ok"] = True
        r["zlib_eof"] = d.eof
        r["zlib_extra"] = len(d.unused_data)
    except zlib.error as e:
        raw = b""
        r["zlib_ok"] = False
        r["zlib_err"] = str(e)
    r["inflated"] = len(raw)
    if ihdr and ihdr["ctype"] in CHANNELS:
        exp = raw_size(ihdr["w"], ihdr["h"], ihdr["ctype"], ihdr["depth"], ihdr["interlace"])
        r["raw_expected"] = exp
        r["raw_delta"] = len(raw) - exp
        if len(raw) >= exp:
            fb = filter_bytes(raw, ihdr["w"], ihdr["h"], ihdr["ctype"], ihdr["depth"], ihdr["interlace"])
            r["filters"] = dict(Counter(fb))
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(png))
        im.load()
        if im.mode == "P":
            r["max_index"] = max(im.tobytes()) if im.width and im.height else None
        r["pil_ok"] = True
    except Exception as e:                      # PIL raises its own types
        r["pil_ok"] = False
        r["pil_err"] = str(e)[:200]
    return r


def verdict(r):
    """The problems a strict reader would act on (empty list = clean)."""
    p = []
    if not r["sig_ok"]:
        p.append("signature")
    if r["crc_bad_critical"]:
        p.append("crc_critical")
    if r["crc_bad_ancillary"]:
        p.append("crc_ancillary")
    if r["after_iend"]:
        p.append("after_iend")
    if not r["order_ok"]:
        p.append("chunk_order")
    if not r.get("zlib_ok"):
        p.append("zlib:" + r.get("zlib_err", "?"))
    elif not r.get("zlib_eof"):
        p.append("zlib_no_end")
    if r.get("zlib_extra"):
        p.append("zlib_extra")
    if r.get("raw_delta"):
        p.append("raw_short" if r["raw_delta"] < 0 else "raw_long")
    z = r.get("zhdr")
    if z and (z["cm"] != 8 or z["cinfo"] > 7 or z["fdict"] or not z["fcheck_ok"]):
        p.append("zlib_header")
    if r["plte"] is not None and r.get("max_index") is not None and r["max_index"] >= r["plte"]:
        p.append("index_past_plte")
    if r["trns"] is not None and r["plte"] is not None and r["trns"] > r["plte"]:
        p.append("trns_past_plte")
    if max(r.get("filters", {0: 0})) > 4:
        p.append("filter_type")
    return p


def dump_one(args):
    img, out = args
    import psmf_ref
    import umd_iso
    import umd_sub_extract
    d = os.path.join(out, slug(img))
    if os.path.exists(os.path.join(d, "index.json")):
        return img, "cached", None
    try:
        iso = umd_iso.UmdIso(img)
        clips = iso.clips()
        iso.close()
        units = []
        for n in clips:
            src = psmf_ref.Source(img, n)
            try:
                r = psmf_ref.parse(src.mm, src.start, src.end)
                for s in sorted(set(p.sub for p in r.packets if p.kind == "sub")):
                    pes = [(p.pts, bytes(src.mm[p.payload_off:p.payload_off + p.payload_len]))
                           for p in r.packets if p.kind == "sub" and p.sub == s]
                    us, info = umd_sub_extract.units(pes)
                    for i, u in enumerate(us):
                        units.append(dict(clip=n, sub=s, i=i, pts=u["pts"], x=u["hdr"]["x"],
                                          y=u["hdr"]["y"], duration=u["hdr"]["duration"],
                                          png=u["png"]))
            finally:
                src.close()
        os.makedirs(d, exist_ok=True)
        idx = []
        for u in units:
            name = "c%05d_s%02x_%05d.png" % (u["clip"], u["sub"], u["i"])
            with open(os.path.join(d, name), "wb") as f:
                f.write(u.pop("png"))
            u["file"] = name
            idx.append(u)
        with open(os.path.join(d, "index.json.tmp"), "w") as f:
            json.dump({"image": os.path.basename(img), "units": idx}, f)
        os.replace(os.path.join(d, "index.json.tmp"), os.path.join(d, "index.json"))
        return img, "dumped %d units" % len(idx), None
    except Exception:
        return img, "error", traceback.format_exc()[-800:]


def images(argv_imgs):
    if argv_imgs:
        return argv_imgs
    root = os.path.expanduser(os.environ.get("UMD_ISO_DIR", "~/umd-isos"))
    out = []
    for dp, _, fs in os.walk(root):
        for f in fs:
            if f.lower().endswith((".iso", ".zip")):
                out.append(os.path.join(dp, f))
    return sorted(out)


def iter_cache(root):
    """-> (disc, unit dict with 'path') over a --dump cache."""
    for d in sorted(os.listdir(root)):
        p = os.path.join(root, d, "index.json")
        if not os.path.exists(p):
            continue
        with open(p) as f:
            idx = json.load(f)
        for u in idx["units"]:
            u["path"] = os.path.join(root, d, u["file"])
            yield d, u


def _strict_file(path):
    with open(path, "rb") as f:
        png = f.read()
    return strict(png), len(png)


def _account(r, npng, disc, u, tot, probs, kinds, first, mx, per_disc):
    tot["units"] += 1
    per_disc[disc] += 1
    tot["png_bytes"] += npng
    tot["inflated_bytes"] += r["inflated"]
    h = r["ihdr"] or {}
    kinds["type%s/%sbit/il%s/plte%s/trns%s" % (h.get("ctype"), h.get("depth"), h.get("interlace"),
                                                r["plte"], r["trns"])] += 1
    for k, v in (("png", npng), ("inflated", r["inflated"]), ("w", h.get("w", 0)),
                 ("h", h.get("h", 0)), ("idat_chunks", r["chunks"].count("IDAT")),
                 ("right", u["x"] + h.get("w", 0)), ("bottom", u["y"] + h.get("h", 0)),
                 ("duration", u["duration"])):
        mx[k] = max(mx[k], v)
    # the frame is 720x480: a unit reaching past it would have to be clipped
    if u["x"] + h.get("w", 0) > 720 or u["y"] + h.get("h", 0) > 480:
        probs["outside_720x480"] += 1
        first.setdefault("outside_720x480", "%s/%s" % (disc, u["file"]))
    for c in set(r["chunks"]):
        kinds["chunk:" + c] += 1
    for fb, n in r.get("filters", {}).items():
        kinds["filter%d" % fb] += n
    z = r.get("zhdr") or {}
    kinds["zhdr cinfo%s flevel%s" % (z.get("cinfo"), z.get("flevel"))] += 1
    for p in verdict(r):
        probs[p] += 1
        first.setdefault(p, "%s/%s" % (disc, u["file"]))


def report(root, js=None, jobs=4):
    tot = Counter()
    probs = Counter()
    kinds = Counter()
    first = {}
    mx = Counter()
    per_disc = Counter()
    work = list(iter_cache(root))
    with multiprocessing.Pool(jobs) as pool:
        res = pool.imap(_strict_file, [u["path"] for _, u in work], chunksize=64)
        for (disc, u), (r, npng) in zip(work, res):
            _account(r, npng, disc, u, tot, probs, kinds, first, mx, per_disc)
    rep = {"discs": len(per_disc), "totals": dict(tot), "max": dict(mx), "kinds": dict(kinds),
           "problems": dict(probs), "first_example": first}
    if js:
        with open(js, "w") as f:
            json.dump(rep, f, indent=1)
    print("discs with subtitle units: %d; units %d; PNG bytes %d; inflated %d" %
          (len(per_disc), tot["units"], tot["png_bytes"], tot["inflated_bytes"]))
    print("max: " + ", ".join("%s=%s" % kv for kv in sorted(mx.items())))
    for k, v in sorted(kinds.items()):
        print("  %-40s %d" % (k, v))
    if probs:
        print("PROBLEMS:")
        for k, v in sorted(probs.items()):
            print("  %-24s %6d   e.g. %s" % (k, v, first[k]))
    else:
        print("no strict-reader problem on any unit")
    return rep


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="*")
    ap.add_argument("--dump", metavar="DIR")
    ap.add_argument("--report", metavar="DIR")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    rc = 0
    if a.dump:
        imgs = images(a.images)
        todo = [i for i in imgs if i.lower().endswith(".iso")]
        for i in imgs:
            if i not in todo:
                print("[skip] %s: .zip images are not walked" % os.path.basename(i))
        with multiprocessing.Pool(a.jobs) as pool:
            for img, st, tb in pool.imap_unordered(dump_one, [(i, a.dump) for i in todo]):
                print("[%s] %s: %s" % ("err" if tb else "ok", os.path.basename(img), st), flush=True)
                if tb:
                    print(tb)
                    rc = 1
    if a.report:
        report(a.report, a.json, a.jobs)
    return rc


if __name__ == "__main__":
    sys.exit(main())
