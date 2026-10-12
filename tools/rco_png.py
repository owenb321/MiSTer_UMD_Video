#!/usr/bin/env python3
"""Every PNG inside the discs' menu containers (UMD_VIDEO/RESOURCE/*.RCO), cached for the
PNG decoder's benches -- the menu art is the population the subtitles never exercise
(8-bit / 2-bit / 1-bit indexed, RGBA8, RGB: docs/menus.md §1), and Phase 9's M0 census
starts here.

An RCO (Sony's resource container, "\\0PRF") carries its images in one image-data region
whose offset and length are header words 28 / 29 after the 16-byte prologue (the layout
rcomage documents). On the discs every image in it is a plain PNG (header compression
field 1: no zlib / RLZ image packing seen). Each PNG is found by its signature and cut by
walking its chunk lengths to IEND (bounds-checked). The WHOLE region is accounted for,
and it is not all PNG: some menus carry **JPEG** (JFIF) images too (measured 2026-09-26),
which are cut by their markers (SOI .. EOI) and measured -- size, baseline / progressive,
the chroma sampling -- for Phase 9, but are not the PNG decoder's. Anything else beyond
alignment padding is counted as `unaccounted`, never silently skipped.

    rco_png.py --dump bench/umd/fixtures/gen/rco_png [--jobs N] [images...]
    rco_png.py --report bench/umd/fixtures/gen/rco_png     (png_corpus.py's strict audit)

The cache has png_corpus.py's layout (DIR/<disc>/index.json + one PNG a file), so
png_corpus --report, png_golden --corpus and run_png.sh --sweep take it as they are.
"""
import argparse
import json
import multiprocessing
import os
import struct
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SIG = b"\x89PNG\r\n\x1a\n"


def png_end(b, o):
    """Walk the PNG at b[o:] to the end of IEND -> end offset, or None if malformed."""
    p = o + 8
    while p + 12 <= len(b):
        ln, = struct.unpack(">I", b[p:p + 4])
        typ = b[p + 4:p + 8]
        if ln > len(b) - p - 12:
            return None
        p += 12 + ln
        if typ == b"IEND":
            return p
    return None


def jpeg_end(b, o, end):
    """The JPEG at b[o:] (SOI) -> (end offset past EOI, info), or (None, None). Walks the
    marker segments to SOS, then scans the entropy-coded data for EOI (FFD9, stuffing FF00
    and restart markers FFD0-D7 skipped)."""
    if b[o:o + 2] != b"\xff\xd8":
        return None, None
    p = o + 2
    info = {"w": 0, "h": 0, "sof": None, "sampling": None}
    while p + 4 <= end:
        if b[p] != 0xFF:
            return None, None
        m = b[p + 1]
        if m == 0xFF:
            p += 1
            continue
        ln = (b[p + 2] << 8) | b[p + 3]
        if m in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            info["sof"] = m - 0xC0
            info["h"], info["w"] = struct.unpack(">HH", b[p + 5:p + 9])
            nc = b[p + 9]
            info["sampling"] = ",".join("%dx%d" % (b[p + 11 + 3 * i] >> 4, b[p + 11 + 3 * i] & 15) for i in range(nc))
        p += 2 + ln
        if m == 0xDA:                                  # SOS: entropy-coded data follows
            while p + 1 < end:
                if b[p] == 0xFF and b[p + 1] not in (0x00,) and not (0xD0 <= b[p + 1] <= 0xD7):
                    if b[p + 1] == 0xD9:
                        return p + 2, info
                    break                              # another marker (progressive: next scan)
                p += 1
    return None, None


def rco_pngs(b, jpegs=None):
    """-> (pngs [(offset, bytes)], info) of one RCO's image-data region; JPEGs found in it
    are appended to `jpegs` as (offset, bytes, info)."""
    if b[:4] != b"\x00PRF":
        return [], {"not_rco": 1}
    f = struct.unpack("<37I", b[16:16 + 37 * 4])
    comp = struct.unpack("<I", b[12:16])[0]
    start, length = f[28], f[29]
    info = {"compression": comp, "img_region": length, "unaccounted": 0, "padding": 0, "malformed": 0,
            "jpeg": 0, "jpeg_bytes": 0}
    if start == 0xFFFFFFFF or length == 0:
        return [], info
    end = min(len(b), start + length)
    out = []
    o = start
    while o < end:
        k = b.find(SIG, o, end)
        gstop = k if k >= 0 else end
        # the stretch before the next PNG: alignment padding, JPEGs, or unaccounted
        while o < gstop:
            z = o
            while z < gstop and z - o < 3 and b[z] == 0:
                z += 1
            info["padding"] += z - o
            o = z
            if o >= gstop:
                break
            je, ji = jpeg_end(b, o, gstop)
            if je is not None:
                info["jpeg"] += 1
                info["jpeg_bytes"] += je - o
                if jpegs is not None:
                    jpegs.append((o, bytes(b[o:je]), ji))
                o = je
            else:
                info["unaccounted"] += gstop - o
                o = gstop
        if k < 0:
            break
        e = png_end(b, k)
        if e is None or e > end:
            info["malformed"] += 1
            o = k + 8
            continue
        out.append((k, bytes(b[k:e])))
        o = e
    return out, info


def slug(path):
    import png_corpus
    return png_corpus.slug(path)


def dump_one(args):
    img, outdir = args
    import umd_iso
    d = os.path.join(outdir, slug(img))
    if os.path.exists(os.path.join(d, "index.json")):
        return img, "cached", None
    try:
        iso = umd_iso.UmdIso(img)
        names = [n for n in iso.listdir("/UMD_VIDEO/RESOURCE") if n.upper().endswith(".RCO")]
        units, infos = [], {}
        jp = []
        for n in names:
            b = iso.read("/UMD_VIDEO/RESOURCE/" + n, record=False)
            js = []
            pngs, info = rco_pngs(b, js)
            infos[n] = info
            for i, (off, data, ji) in enumerate(js):
                jp.append({"rco": n, "i": i, "offset": off, "data": data, **ji})
            for i, (off, png) in enumerate(pngs):
                units.append({"rco": n, "i": i, "offset": off, "png": png})
        iso.close()
        os.makedirs(d, exist_ok=True)
        idx = []
        for u in units:
            name = "%s_%03d.png" % (os.path.splitext(u["rco"])[0], u["i"])
            with open(os.path.join(d, name), "wb") as f:
                f.write(u.pop("png"))
            u.update(file=name, x=0, y=0, duration=0)
            idx.append(u)
        jidx = []
        if jp:
            os.makedirs(os.path.join(d, "jpeg"), exist_ok=True)
        for u in jp:
            name = "%s_%03d.jpg" % (os.path.splitext(u["rco"])[0], u["i"])
            with open(os.path.join(d, "jpeg", name), "wb") as f:
                f.write(u.pop("data"))
            u["file"] = name
            jidx.append(u)
        with open(os.path.join(d, "index.json.tmp"), "w") as f:
            json.dump({"image": os.path.basename(img), "units": idx, "rco": infos, "jpeg": jidx}, f)
        os.replace(os.path.join(d, "index.json.tmp"), os.path.join(d, "index.json"))
        return img, "%d RCO, %d PNG, %d JPEG" % (len(names), len(idx), len(jidx)), None
    except Exception:
        return img, "error", traceback.format_exc()[-800:]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="*")
    ap.add_argument("--dump", metavar="DIR")
    ap.add_argument("--report", metavar="DIR")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    import png_corpus
    rc = 0
    if a.dump:
        imgs = [i for i in png_corpus.images(a.images) if i.lower().endswith(".iso")]
        with multiprocessing.Pool(a.jobs) as pool:
            for img, st, tb in pool.imap_unordered(dump_one, [(i, a.dump) for i in imgs]):
                print("[%s] %s: %s" % ("err" if tb else "ok", os.path.basename(img), st), flush=True)
                if tb:
                    print(tb)
                    rc = 1
    if a.report:
        # the region accounting first (what the strict audit cannot see), then the audit
        tot = {"rco": 0, "unaccounted": 0, "malformed": 0, "padding": 0, "jpeg": 0, "jpeg_bytes": 0}
        comps = {}
        jk = {}
        jmax = (0, 0, "")
        for dname in sorted(os.listdir(a.report)):
            p = os.path.join(a.report, dname, "index.json")
            if not os.path.exists(p):
                continue
            with open(p) as f:
                idx = json.load(f)
            for n, info in idx["rco"].items():
                tot["rco"] += 1
                for k in ("unaccounted", "malformed", "padding", "jpeg", "jpeg_bytes"):
                    tot[k] += info.get(k, 0)
                comps[info.get("compression")] = comps.get(info.get("compression"), 0) + 1
                if info.get("unaccounted") or info.get("malformed"):
                    print("  %s/%s: %d bytes unaccounted, %d malformed" % (dname, n, info["unaccounted"], info["malformed"]))
            for j in idx.get("jpeg", []):
                key = "SOF%s %s" % (j["sof"], j["sampling"])
                jk[key] = jk.get(key, 0) + 1
                if j["w"] * j["h"] > jmax[0] * jmax[1]:
                    jmax = (j["w"], j["h"], "%s/%s" % (dname, j["file"]))
        print("RCO files %d; header compression field %s; image regions: %d bytes padding, %d unaccounted, %d malformed PNG"
              % (tot["rco"], comps, tot["padding"], tot["unaccounted"], tot["malformed"]))
        print("JPEG images %d (%d bytes): %s; largest %dx%d (%s)" % (tot["jpeg"], tot["jpeg_bytes"], jk, jmax[0], jmax[1], jmax[2]))
        png_corpus.report(a.report, a.json, a.jobs)
    return rc


if __name__ == "__main__":
    sys.exit(main())
