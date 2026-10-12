#!/usr/bin/env python3
"""menu_iso_synth.py -- synthetic UMD images for P9 M3's image reader (main/support/umd/menu/
umd_iso.c), with the ISO9660 cases no library disc has (menu_iso_check.py on the library sees
none of them: no ';1' suffix, no trailing '.', no multi-extent file, no padded UMD_DATA.BIN field).

    menu_iso_synth.py OUTDIR       -> OUTDIR/syn_iso_{basic,gapped,deep}.iso

syn_iso_basic   a boot record before the PVD; ';1' suffixes; a lower-case name; "README." (a
                trailing dot); UMD_VIDEO/ over two sectors with PLAYLIST.UMD in the second;
                RESOURCE/EN100000.RCO in two CONTIGUOUS extents (flag 0x80 on the first);
                UMD_DATA.BIN's product and id padded with spaces; a directory chain to the
                ECMA-119 limit (UMD_VIDEO/A/../G: 8 levels) with a file at its bottom
syn_iso_gapped  RESOURCE/EN100000.RCO in two GAPPED extents: tools/umd_iso.py refuses the image,
                and umd_iso.c must refuse it too (menu_iso_check.py requires an ERR line)
syn_iso_deep    the chain one level deeper (A/../H, 9 levels): refused by both
Built with tools/tests/umd_synth.py (the P2 reader's synthetic images); the expected outputs come
from tools/umd_iso.py, never from the C.
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "tests"))
import umd_synth as S  # noqa: E402

SEC = 2048


class Img(object):
    def __init__(self, total):
        self.total = total
        self.b = bytearray(total * SEC)

    def put(self, lba, data):
        self.b[lba * SEC:lba * SEC + len(data)] = data


def blob(n, seed):
    r = random.Random(seed)
    return bytes(r.getrandbits(8) for _ in range(n))


def build(gapped, deep=False):
    d = Img(400)
    boot = bytearray(SEC)
    boot[0], boot[1:6], boot[6] = 0, b"CD001", 1
    d.put(16, bytes(boot))
    d.put(17, S.pvd(20, SEC, d.total))
    d.put(18, S.terminator())
    umd_data = b"  TEST-00001  |  0123456789ABCDEF |1.00|G|".ljust(48, b"\0")
    readme = blob(300, 1)
    pl = blob(5000, 2)
    rco_a = blob(2 * SEC, 3)                   # the first extent: whole sectors
    rco_b = blob(700, 4)
    fr = blob(1500, 5)
    low = blob(64, 6)
    bottom = blob(10, 7)
    # root (20), UMD_VIDEO (21-22, two sectors), RESOURCE (23), A..H (30-37)
    d.put(20, S.dir_sectors(20, 20, [(b"UMD_DATA.BIN;1", 100, len(umd_data), 0), (b"README.;1", 101, len(readme), 0),
                                     (b"UMD_VIDEO", 21, 2 * SEC, 2)]))
    dummies = [(b"DUMMY_%02d.DAT;1" % i, 102, 1, 0) for i in range(44)]
    d.put(21, S.dir_sectors(21, 20, dummies + [(b"PLAYLIST.UMD;1", 110, len(pl), 0), (b"RESOURCE", 23, SEC, 2),
                                                (b"A", 30, SEC, 2)], nsec=2))
    second = 140 if gapped else 122            # after the first extent's two sectors (120-121), or not
    d.put(23, S.dir_sectors(23, 21, [(b"EN100000.RCO;1", 120, len(rco_a), 0x80), (b"EN100000.RCO;1", second, len(rco_b), 0),
                                     (b"FR100000.RCO;1", 130, len(fr), 0), (b"en000001.rco;1", 135, len(low), 0)]))
    parent = 21
    chain = b"ABCDEFGH" if deep else b"ABCDEFG"
    for i, nm in enumerate(chain):
        lba = 30 + i
        nxt = [(bytes([chain[i + 1]]), lba + 1, SEC, 2)] if i < len(chain) - 1 else [(b"BOTTOM.DAT;1", 150, len(bottom), 0)]
        d.put(lba, S.dir_sectors(lba, parent, nxt))
        parent = lba
    d.put(100, umd_data)
    d.put(101, readme)
    d.put(102, b"x")
    d.put(110, pl)
    d.put(120, rco_a)
    d.put(second, rco_b)
    d.put(130, fr)
    d.put(135, low)
    d.put(150, bottom)
    return bytes(d.b)


def main(argv):
    if len(argv) != 1:
        sys.exit(__doc__)
    os.makedirs(argv[0], exist_ok=True)
    for stem, gapped, deep in (("syn_iso_basic", False, False), ("syn_iso_gapped", True, False), ("syn_iso_deep", False, True)):
        open(os.path.join(argv[0], stem + ".iso"), "wb").write(build(gapped, deep))
        print(stem)


if __name__ == "__main__":
    main(sys.argv[1:])
