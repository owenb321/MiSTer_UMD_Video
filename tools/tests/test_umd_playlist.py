#!/usr/bin/env python3
"""umd_playlist.parse()/main_playlist() on synthetic UMDV0088 files built from the
layout measured on real discs (docs/umd_video_format.md "PLAYLIST.UMD"), not from the
parser: multiple playlists with self-relative section offsets, a two-item playlist (the
spec width allows it though no disc uses one), marks, the main-playlist rule (the
longest, NOT #0), and the rejections.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_playlist  # noqa: E402

T = S.Score("test_umd_playlist")
entry = S.entry
playlist_file = S.playlist_file

ents = [entry("Title", [("00001", 90000, 90000 * 19)], [(5, 0, 90000, "Mark0")]),
        entry("Tr01", [("00002", 90000, 90000 * 60)], []),
        entry("Main", [("00003", 90000, 90000 * 5000), ("00004", 90000, 90000 * 100)],
              [(0, 0, 90000, "Mark0"), (9, 1, 180000, "Mark2731")])]
raw = playlist_file(ents)

print("[parse]")
p = umd_playlist.parse(raw)
T.check("disc name", p["disc_name"], "UMDV-SAMPLE")
T.check("playlist count", len(p["playlists"]), 3)
T.check("names", [e["name"] for e in p["playlists"]], ["Title", "Tr01", "Main"])
T.check("datetime", p["playlists"][0]["datetime"], "20040815230000")
T.check("two items", [(i["clip_name"], i["in_pts"], i["out_pts"]) for i in p["playlists"][2]["items"]],
        [("00003", 90000, 450000000), ("00004", 90000, 9000000)])
T.check("marks", [(m["flags"], m["item"], m["pts"], m["name"]) for m in p["playlists"][2]["marks"]],
        [(0, 0, 90000, "Mark0"), (9, 1, 180000, "Mark2731")])
T.check("empty marks", p["playlists"][1]["marks"], [])
T.check("main = the longest, not #0", umd_playlist.main_playlist(p), 2)

print("[rejections]")
T.raises("magic", lambda: umd_playlist.parse(b"UMDV0099" + raw[8:]),
         umd_playlist.PlaylistError, "magic")
T.raises("truncated", lambda: umd_playlist.parse(raw[:-7]), umd_playlist.PlaylistError,
         "runs past")
bad = bytearray(raw)
struct.pack_into(">H", bad, 0x134, 2)               # claims 2 playlists, carries 3
T.raises("playlist count short", lambda: umd_playlist.parse(bytes(bad)),
         umd_playlist.PlaylistError, "unaccounted")
e2 = entry("X", [("00001", 90000, 180000)], [(0, 0, 90000, "M")])
e2 = bytearray(e2)
mo = struct.unpack(">H", e2[6:8])[0]
struct.pack_into(">H", e2, mo + 4, 2)               # 2 marks claimed, 1 present
T.raises("mark count", lambda: umd_playlist.parse(playlist_file([bytes(e2)])),
         umd_playlist.PlaylistError, "does not hold")
e3 = bytearray(entry("X", [("00001", 90000, 180000)], []))
struct.pack_into(">H", e3, 4, 0x24)                 # items_off onto the info section
T.raises("items_off into the info section is rejected",
         lambda: umd_playlist.parse(playlist_file([bytes(e3)])),
         umd_playlist.PlaylistError, "length")
T.finish()
