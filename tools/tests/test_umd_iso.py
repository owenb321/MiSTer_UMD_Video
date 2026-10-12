#!/usr/bin/env python3
"""umd_iso.UmdIso on a synthetic image built from ECMA-119 (tests/umd_synth.py).

Covers: PVD scan to the terminator, the system id, a two-level walk, ';1' stripping,
a directory spanning two sectors, a contiguous multi-extent file (joined AND listed),
the visited-sector record, and the rejections (no CD001, gapped multi-extent,
non-final record never closed).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE)))
import umd_synth as S  # noqa: E402
import umd_iso  # noqa: E402

T = S.Score("test_umd_iso")
check = T.check


def raises(label, fn, frag):
    T.raises(label, fn, umd_iso.IsoError, frag)


def image(multi=((200, 4096, 0x80), (202, 100, 0x00)), clip_names=40):
    """root(22) -> UMD_DATA.BIN, UMD_VIDEO(23) -> PLAYLIST.UMD, STREAM(24, 2 sectors)
    -> NNNNN.MPS x clip_names, BIG.MPS multi-extent."""
    b = S.ImageBuilder(300)
    b.put(16, S.pvd(22, 2048, 300))
    b.put(17, S.terminator())
    b.put(22, S.dir_sectors(22, 22, [(b"UMD_DATA.BIN;1", 30, 48, 0),
                                     (b"UMD_VIDEO", 23, 2048, 2)]))
    b.put(23, S.dir_sectors(23, 22, [(b"PLAYLIST.UMD;1", 31, 5000, 0),
                                     (b"STREAM", 24, 4096, 2)]))
    ents = [(b"%05d.MPS;1" % (i + 1), 100 + i, 2048, 0) for i in range(clip_names)]
    ents += [(b"BIG.MPS;1", l, s, f) for l, s, f in multi]
    b.put(24, S.dir_sectors(24, 23, ents, nsec=2))
    b.put(30, b"Title     |0123456789ABCDEF|0002|V".ljust(48, b"\0"))
    b.put(31, bytes(range(256)) * 20)
    return b.build()


print("[walk]")
iso = umd_iso.UmdIso(image())
check("system id", iso.system_id, "UMD VIDEO")
check("VD lbas", iso.vd_lbas, [16, 17])
check("volume sectors", iso.volume_sectors, 300)
check("playlist extent", (iso.extent("/UMD_VIDEO/PLAYLIST.UMD").lba,
                          iso.extent("umd_video/playlist.umd").size), (31, 5000))
check("dir listed", iso.files["/UMD_VIDEO/STREAM"].is_dir, True)
check("40 clips across a 2-sector directory", iso.clips(), list(range(1, 41)))
check("clip 40 extent", iso.extent("/UMD_VIDEO/STREAM/00040.MPS").lba, 139)
check("multi-extent joined", (iso.extent("/UMD_VIDEO/STREAM/BIG.MPS").lba,
                              iso.extent("/UMD_VIDEO/STREAM/BIG.MPS").size), (200, 4196))
check("multi-extent listed", iso.multi_extent, ["/UMD_VIDEO/STREAM/BIG.MPS"])
check("visited = VDs + dirs", iso.visited, [16, 17, 22, 23, 24, 25])
check("playlist bytes", iso.read("/UMD_VIDEO/PLAYLIST.UMD"), (bytes(range(256)) * 20)[:5000])
check("read recorded", iso.visited[-3:], [31, 32, 33])
check("lba runs", iso.lba_runs(), [[16, 2], [22, 4], [31, 3]])
ud = iso.umd_data()
check("UMD_DATA disc id", (ud["product"], ud["disc_id"], ud["version"], ud["flags"]),
      ("Title", "0123456789ABCDEF", "0002", "V"))

print("[rejections]")
bad = bytearray(image())
bad[16 * 2048 + 1:16 * 2048 + 6] = b"XXXXX"
raises("no CD001", lambda: umd_iso.UmdIso(bytes(bad)), "CD001")
raises("gapped multi-extent", lambda: umd_iso.UmdIso(image(((200, 4096, 0x80), (210, 100, 0)))),
       "not contiguous")
raises("unclosed multi-extent", lambda: umd_iso.UmdIso(image(((200, 4096, 0x80),))),
       "no final record")
raises("missing file", lambda: iso.extent("/NOPE"), "not in image")

T.finish()
