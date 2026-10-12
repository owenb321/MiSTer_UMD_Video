#!/usr/bin/env python3
"""The bug bundle's media gate (docs/bug_reports.md section 5): every library image -> a bundle
(tools/umd_report.py, its own audit and verify included) -> a sparse reconstruction, then the
ORIGINAL and the RECONSTRUCTION read by the repository's own tools, which must agree:

  nav      umd_playlist --json, umd_clpi --entries --json, umd_nav_ref --chapters: identical
  headers  each stream head's video ES (psmf_ref's demux, not the tool's): every SPS / PPS and
           every slice header decoded by h264_fe_ref (an independent parser) to identical field
           records; every audio AU header (chained from the first PES's pointer) byte-identical;
           every subtitle unit's 20-byte header identical and its picture the same size
  ceilings the largest non-zero run / count per pack the audit measured, against its ceilings
  menus    (--menus) tools/menu_lib.py over the reconstructions: each disc's class the one
           tools/menu_lib_classes.txt records for its original

Needs ${UMD_ISO_DIR:-~/umd-isos}; with no images it prints SKIP and exits 2 (never a pass).

    corpus_report.py [--jobs N] [--menus] [--keep] [images...]
"""
import argparse
import glob
import json
import multiprocessing
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
import h264_fe_ref as fe            # noqa: E402
import psmf_ref                     # noqa: E402
import umd_report as ur             # noqa: E402
from cabac_ref import BitReader     # noqa: E402

OUT = os.path.join(ROOT, ".sim", "report")


def run(args):
    p = subprocess.run([sys.executable] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, errors="replace")
    return p.returncode, p.stdout


def head_bytes(path, lba, n, size):
    with open(path, "rb") as f:
        f.seek(lba * ur.SEC)
        b = f.read(n * ur.SEC)
    if size < n * ur.SEC:
        b = b[:size]
    return b.ljust(n * ur.SEC, b"\0")


def video_records(es):
    """[(nal type, the header field records)] for every SPS, PPS and slice."""
    out, sps, pps = [], {}, {}
    for ref, ntype, rbsp in fe.nal_units(es):
        rec = []
        try:
            if ntype == 7:
                s = fe.parse_sps(rbsp, rec)
                sps[s.id] = s
            elif ntype == 8:
                p = fe.parse_pps(rbsp, sps, rec)
                pps[p.id] = p
            elif ntype in (1, 5):
                fe.parse_slice_header(BitReader(rbsp), ntype, ref, sps, pps, rec)
            else:
                continue
        except Exception as e:                       # a NAL the window cut: recorded as such
            rec.append("cut %s" % type(e).__name__)
        out.append((ntype, rec))
    return out


def audio_headers(es, marks):
    out = []
    faps = [off + fap for off, _p, _d, fap in marks if fap is not None and fap < 0xFFFF]
    pos = faps[0] if faps else None
    while pos is not None and pos + 8 <= len(es) and es[pos:pos + 2] == b"\x0f\xd0":
        out.append((pos, es[pos:pos + 8]))
        pos += 16 + ((es[pos + 2] << 8 | es[pos + 3]) & 0x3FF) * 8
    return out


def sub_units(es, marks):
    out = []
    for off, pts, _d, _f in marks:
        if pts is not None and es[off + 4:off + 8] == b"0088":
            try:
                dims = ur.png_ihdr(es[off + 20:off + 20 + ur.be32(es, off) - 16])[:2]
            except Exception:
                dims = None
            out.append((off, es[off:off + 20], dims))
    return out


def compare_head(orig, repro):
    """'' when every header agrees, else what differs."""
    ro, rr = psmf_ref.parse(orig), psmf_ref.parse(repro)
    for (sid, sub), _n in sorted(ro.streams().items()):
        kind = "video" if sid == 0xE0 else ("audio" if sid == 0xBD and sub is not None and sub < 0x10 else
                                            "sub" if sid == 0xBD and sub is not None and 0x80 <= sub <= 0x9F else None)
        if kind is None:
            continue
        eo, mo = psmf_ref.es(orig, ro, kind, sub if kind != "video" else None)
        er, mr = psmf_ref.es(repro, rr, kind, sub if kind != "video" else None)
        if [m[:2] for m in mo] != [m[:2] for m in mr]:
            return "%s 0x%02X: the PES time stamps differ" % (kind, sub or sid)
        if kind == "video":
            a, b = video_records(eo), video_records(er)
            if a != b:
                i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
                return "video: NAL %d of %d/%d differs: %r vs %r" % (i, len(a), len(b), a[i:i + 1], b[i:i + 1])
        elif kind == "audio":
            if audio_headers(eo, mo) != audio_headers(er, mr):
                return "audio 0x%02X: the AU headers differ" % sub
        else:
            if sub_units(eo, mo) != sub_units(er, mr):
                return "subtitle 0x%02X: a unit header or picture size differs" % sub
    return ""


def pack_extremes(buf):
    run_max = nz_max = 0
    for base in range(0, len(buf) - ur.SEC + 1, ur.SEC):
        sec = buf[base:base + ur.SEC]
        pk = ur.parse_packets(sec)
        if not pk:
            continue
        nz = 0
        for sid, p, end in pk:
            if sid in (0xBB, 0xBF):
                continue
            hl = 9 + sec[p + 8] if end - p >= 9 and sid != 0xBE and (sec[p + 6] >> 6) == 2 else 6
            if sid == 0xBD and p + hl < end and 0x80 <= sec[p + hl] <= 0x9F:
                continue
            run = 0
            for b in sec[p + hl:end]:
                run = run + 1 if b else 0
                nz += 1 if b else 0
                run_max = max(run_max, run)
        nz_max = max(nz_max, nz)
    return run_max, nz_max


def one(img):
    key = os.path.splitext(os.path.basename(img))[0]
    zp = os.path.join(OUT, key + ".zip")
    rp = os.path.join(OUT, "iso", os.path.basename(img))
    r = {"key": key, "fails": []}
    t0 = time.time()
    rc, out = run([os.path.join(TOOLS, "umd_report.py"), img, "--no-prompt", "-o", zp])
    r["make_s"] = round(time.time() - t0, 1)
    if rc:
        r["fails"].append("make: " + out.strip().splitlines()[-1])
        return r
    r["kb"] = os.path.getsize(zp) // 1024
    rc, out = run([os.path.join(TOOLS, "umd_report.py"), "unpack", zp, "-o", rp])
    if rc:
        r["fails"].append("unpack: " + out.strip())
        return r
    for tool, extra in (("umd_playlist.py", ["--json"]), ("umd_clpi.py", ["--entries", "--json"]),
                        ("umd_nav_ref.py", ["--chapters"])):
        a, b = run([os.path.join(TOOLS, tool), img] + extra), run([os.path.join(TOOLS, tool), rp] + extra)
        if a != b:
            r["fails"].append("%s differs (rc %d vs %d)" % (tool, a[0], b[0]))
    man, sectors = ur.read_bundle(zp)
    r["scrub"] = man["scrub"]
    run_max = nz_max = 0
    for rec in man["files"]:
        if rec["kind"] != "stream-head":
            continue
        o = head_bytes(img, rec["lba"], rec["sectors"], rec["size"])
        p = b"".join(sectors.get(rec["lba"] + i, b"\0" * ur.SEC) for i in range(rec["sectors"]))
        why = compare_head(o, p)
        if why:
            r["fails"].append("%s: %s" % (rec["path"], why))
        a, b = pack_extremes(p)
        run_max, nz_max = max(run_max, a), max(nz_max, b)
    r["run_max"], r["nz_max"] = run_max, nz_max
    return r


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--menus", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep the reconstructions under .sim/report/iso")
    a = ap.parse_args(argv)
    d = os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos"))
    imgs = a.images or sorted(p for p in glob.glob(os.path.join(d, "*")) if p.lower().endswith(".iso"))
    if not imgs:
        print("corpus_report: SKIP -- no .iso in %s (set UMD_ISO_DIR)" % d)
        return 2
    os.makedirs(os.path.join(OUT, "iso"), exist_ok=True)
    with multiprocessing.Pool(a.jobs) as pool:
        res = pool.map(one, imgs)
    fails = 0
    for r in res:
        st = "FAIL" if r["fails"] else "ok"
        fails += bool(r["fails"])
        print("%-60s %-4s %5s KB %5.1f s  run %3s  nz %4s  %s" % (
            r["key"][:60], st, r.get("kb", "-"), r["make_s"], r.get("run_max", "-"), r.get("nz_max", "-"),
            "; ".join(r["fails"])))
    ok = [r for r in res if not r["fails"]]
    if ok:
        print("corpus_report: bundles %d-%d KB (median %d), make %.0f-%.0f s; the largest run %d (ceiling %d), "
              "non-zero bytes a pack %d (ceiling %d)" % (
                  min(r["kb"] for r in ok), max(r["kb"] for r in ok), sorted(r["kb"] for r in ok)[len(ok) // 2],
                  min(r["make_s"] for r in ok), max(r["make_s"] for r in ok),
                  max(r["run_max"] for r in ok), ur.MAX_NONZERO_RUN, max(r["nz_max"] for r in ok),
                  ur.MAX_NONZERO_PER_PACK))
        tot = {}
        for r in ok:
            for k, v in r["scrub"].items():
                tot[k] = tot.get(k, 0) + v
        print("corpus_report: scrub totals " + ", ".join("%s %d" % kv for kv in sorted(tot.items())))
    if a.menus:
        rc, out = run([os.path.join(TOOLS, "menu_lib.py"), "--jobs", str(a.jobs), "--check",
                       os.path.join(TOOLS, "menu_lib_classes.txt")] + sorted(
                           os.path.join(OUT, "iso", os.path.basename(i)) for i in imgs))
        open(os.path.join(OUT, "menus.log"), "w").write(out)
        last = [l for l in out.splitlines() if l.startswith(("PASS", "FAIL", "menu_lib:"))]
        print("menus: " + " | ".join(last[-3:]))
        fails += 0 if "PASS: menu_lib" in out else 1
    if not a.keep:
        shutil.rmtree(os.path.join(OUT, "iso"), ignore_errors=True)
    print("corpus_report: %d images, %d FAIL -- %s" % (len(res), fails, "ALL GREEN" if not fails else "FAILURES"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
