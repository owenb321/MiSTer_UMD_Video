#!/usr/bin/env python3
"""Cut a UMD Video image down for a hardware test: keep every sector up to the end of
the main title's first --packs packs, and patch that .MPS's directory record so the
filesystem agrees (the file ends where the image does).

A whole image is 1.1-1.8 GB; a P2 hardware gate needs the walk plus a few MB of stream.
Everything the reader reads (volume descriptors, directories, PARAM.SFO, PLAYLIST.UMD,
the main clip's CLP) must lie below the cut, and the tool refuses otherwise. The walk,
the title, the playlist pick and the first MiB of video ES -- the P2 readout's CRC --
are exactly the full image's (tools/psmf_golden.py --crc gives the same value on both).
The output is for the maintainer's own rig and never leaves it; it is not a fixture.

    umd_trim.py disc.iso --packs 32768 -o trimmed.iso      # 64 MiB of stream
    umd_trim.py --smallest $UMD_ISO_DIR                     # which disc trims smallest
"""
import argparse
import glob
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import umd_iso  # noqa: E402
import umd_playlist  # noqa: E402

SEC = 2048


def main_mps(iso):
    pl = umd_playlist.from_iso(iso)
    item = pl["playlists"][umd_playlist.main_playlist(pl)]["items"][0]
    return item["clip_name"], iso.extent("/UMD_VIDEO/STREAM/%s.MPS" % item["clip_name"])


def trim(src, packs, out):
    with umd_iso.UmdIso(src) as iso:
        clip, mps = main_mps(iso)
        if src in iso.multi_extent or "/UMD_VIDEO/STREAM/%s.MPS" % clip in iso.multi_extent:
            raise SystemExit("umd_trim: the main .MPS is multi-extent; not handled")
        keep = min(packs, mps.nsec)
        cut = mps.lba + keep
        for path in ("/UMD_VIDEO/PARAM.SFO", "/UMD_VIDEO/PLAYLIST.UMD",
                     "/UMD_VIDEO/CLIPINF/%s.CLP" % clip, "/UMD_VIDEO/STREAM",
                     "/UMD_VIDEO/CLIPINF", "/UMD_VIDEO", ""):
            if path and not iso.exists(path):
                continue
            e = iso.files[""] if path == "" else iso.extent(path)
            if e.lba + e.nsec > cut:
                raise SystemExit("umd_trim: %s lies past the cut (LBA %d)" % (path or "/", cut))
        st = iso.extent("/UMD_VIDEO/STREAM")
        dirbuf = bytearray(iso.read_sectors(st.lba, st.nsec))
    # find the .MPS record in STREAM/ and patch its both-endian data length
    name = ("%s.MPS" % clip).encode()
    p, hit = 0, None
    while p < len(dirbuf):
        rl = dirbuf[p]
        if rl == 0:
            p = (p // SEC + 1) * SEC
            continue
        nl = dirbuf[p + 32]
        if dirbuf[p + 33:p + 33 + nl].split(b";")[0] == name:
            hit = p
            break
        p += rl
    if hit is None:
        raise SystemExit("umd_trim: %s not found in STREAM/" % name.decode())
    size = keep * SEC if keep < mps.nsec else mps.size
    dirbuf[hit + 10:hit + 18] = struct.pack("<I", size) + struct.pack(">I", size)
    with open(src, "rb") as f, open(out, "wb") as g:
        left = cut * SEC
        while left:
            b = f.read(min(left, 1 << 22))
            if not b:
                raise SystemExit("umd_trim: %s is shorter than its own filesystem" % src)
            g.write(b)
            left -= len(b)
        g.seek(st.lba * SEC)
        g.write(dirbuf)
    return clip, mps.lba, keep, cut * SEC


def cli(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso", nargs="?")
    ap.add_argument("--packs", type=int, default=32768)
    ap.add_argument("-o", "--out")
    ap.add_argument("--smallest", metavar="DIR")
    a = ap.parse_args(argv)
    if a.smallest:
        rows = []
        for f in sorted(glob.glob(os.path.join(a.smallest, "*"))):
            if not f.lower().endswith(".iso"):
                continue
            try:
                with umd_iso.UmdIso(f) as iso:
                    clip, mps = main_mps(iso)
                    rows.append((mps.lba, clip, f))
            except Exception as e:  # noqa: BLE001 -- a survey, report and go on
                print("  skip %s: %s" % (os.path.basename(f), e))
        for lba, clip, f in sorted(rows)[:8]:
            print("%6.1f MiB before the stream  clip %s  %s" % (lba * SEC / 2.0**20, clip,
                                                              os.path.basename(f)))
        return 0
    if not a.iso or not a.out:
        ap.error("give an image and -o")
    clip, lba, keep, n = trim(a.iso, a.packs, a.out)
    print("%s: clip %s at LBA %d, %d packs kept, %.1f MiB" % (a.out, clip, lba, keep,
                                                              n / 2.0**20))
    return 0


if __name__ == "__main__":
    sys.exit(cli())
