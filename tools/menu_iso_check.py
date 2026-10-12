#!/usr/bin/env python3
"""menu_iso_check.py -- P9 M3: the UMD Main's image reader (main/support/umd/menu/umd_iso.c, run by
bench/umd/menu/iso_dump.c) against tools/umd_iso.py, the P1 tools' walk, on every image.

    menu_iso_check.py [--iso-dir DIR] [--dump .sim/menu/iso_dump]

Per image, EQUAL: the whole tree (every entry's path, LBA, size, dir flag), the disc id
("<product>_<discid>" from UMD_DATA.BIN, trimmed, filename-safe), and the CRC-32 and length of
PLAYLIST.UMD, UMD_DATA.BIN and every RESOURCE/*.RCO. Prints "PASS: menu_iso_check" or FAIL lines;
"SKIP" (exit 0) without images.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import umd_iso  # noqa: E402


def expect(path):
    out = []
    with umd_iso.UmdIso(path) as iso:
        for k, e in iso.files.items():
            if k:
                out.append("E %s %d %d %d" % (k, e.lba, e.size, 1 if e.is_dir else 0))
        ud = iso.umd_data()
        if ud:
            ident = "%s_%s" % (ud["product"].strip(), ud["disc_id"].strip())
            out.append("ID " + re.sub(r"[^A-Za-z0-9-]", "_", ident))
        else:
            out.append("ID -")
        files = ["/UMD_VIDEO/PLAYLIST.UMD", "/UMD_DATA.BIN"]
        files += ["/UMD_VIDEO/RESOURCE/" + n for n in iso.listdir("/UMD_VIDEO/RESOURCE") if n.endswith(".RCO")]
        for f in files:
            if iso.exists(f):
                b = iso.read(f, record=False)
                out.append("C %s %d %08x" % (f, len(b), zlib.crc32(b) & 0xFFFFFFFF))
            else:
                out.append("C %s absent" % f)
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--dump", default=os.path.join(os.path.dirname(HERE), ".sim/menu/iso_dump"))
    a = ap.parse_args()
    isos = sorted(p for p in glob.glob(os.path.join(a.iso_dir, "*")) if p.lower().endswith(".iso"))
    if not isos:
        print("SKIP: menu_iso_check: no images under %s" % a.iso_dir)
        return 0
    n = bad = skipped = entries = refused = 0
    for p in isos:
        out = subprocess.run([a.dump, p], stdout=subprocess.PIPE, universal_newlines=True).stdout.splitlines()
        try:
            want = expect(p)
        except umd_iso.IsoError as e:               # the P1 walk refuses it: umd_iso.c must too
            n += 1
            if any(l.startswith("ERR") for l in out):
                refused += 1
                print("  ok   %s: refused by both (%s)" % (os.path.basename(p), e))
            else:
                bad += 1
                print("  FAIL %s: umd_iso.py refuses it (%s), umd_iso.c does not" % (os.path.basename(p), e))
            continue
        got = out
        got = sorted(l for l in got if not l.startswith("ERR"))
        n += 1
        entries += sum(1 for l in want if l.startswith("E "))
        if got != want:
            bad += 1
            miss = [l for l in want if l not in got][:2]
            extra = [l for l in got if l not in want][:2]
            print("  FAIL %s: missing %s, extra %s" % (os.path.basename(p), miss, extra))
    print("menu_iso_check: %d images (%d entries), %d differ, %d refused by both, %d skipped" % (n, entries, bad, refused, skipped))
    if bad or n == 0:
        print("FAIL: menu_iso_check")
        return 1
    print("PASS: menu_iso_check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
