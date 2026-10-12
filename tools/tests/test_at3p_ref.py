#!/usr/bin/env python3
"""The ATRAC3plus models (tools/at3p_ref.py float, tools/at3p_fixed.py fixed) --
docs/at3p_decoder.md S2, S4.

  [units]   no media: the bit reader, canonical Huffman codes (incl. ffmpeg's hole
            behaviour), the frame-level refusals, the fixed ROMs' angle formulas
            against the float transforms.
  [tables]  tools/at3p_tables.py equals a fresh transcription of the pinned ffmpeg
            source (SKIP without $UMD_REFS_DIR/ffmpeg-9.0.1).
  [ffmpeg]  one track per params word the discs use (0x4855 / 0x483F / 0x487F / 0x482A):
            the float path within FLOAT_GATE_LSB of the ffmpeg binary, the fixed path
            within at3p_fixed.GATE_LSB, on windows with real signal (the reference's
            peak is checked: a silent window proves nothing).
  [mute]    the mute flag no disc sets, flipped into real frames: ffmpeg is the oracle.
  [refuse]  a mono unit where the stream is stereo: the model refuses, ffmpeg drops it.
  The [ffmpeg]/[mute]/[refuse] arms SKIP without ffmpeg or $UMD_ISO_DIR.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, TOOLS)
import umd_synth as S  # noqa: E402
import at3p_ref as R  # noqa: E402
import at3p_fixed as F  # noqa: E402
import at3p_sweep as SW  # noqa: E402

T = S.Score("test_at3p_ref")

print("[units]")
b = R.Bits(bytes([0b10110010, 0b01111111]))
T.check("bits: 1, 011, 0010 0111, then 4 ones", (b.get(1), b.get(3), b.get(8), b.get(4)),
        (1, 3, 0x27, 0xF))
T.check("bits: past the end reads zeros and counts", (b.get(5), b.overrun), (0, 5))
v = R.Vlc([1, 2] + [0] * 10, [0, 1, 7], "wl0")          # codes 0, 10, 11
b = R.Bits(bytes([0b01011000]))
T.check("vlc: canonical codes in list order", [v.read(b) for _ in range(3)], [0, 1, 7])
h = R.Vlc([1, 0, 1] + [0] * 9, [5, 9], "holey")          # codes 0, 100; 101..111 are holes
b = R.Bits(bytes([0b10100000]))
T.check("vlc: a hole returns -1 and consumes nothing", (h.read(b), b.pos, h.holes), (-1, 0, 1))
T.check("vlc: every ffmpeg codebook builds (8,366 spectrum symbols used)",
        R.VLC["spec_xlat_used"], 8366)
T.check("frame: a lone terminator decodes to silence",
        float(abs(R.Decoder().decode(bytes([0b01100000]) + bytes(7))).max()), 0.0)
T.raises("frame: start bit 1 refused", lambda: R.Decoder().decode(bytes([0x80, 0])),
         R.At3pError, "START_BIT")
T.raises("frame: a mono unit refused", lambda: R.Decoder().decode(bytes([0x00, 0])),
         R.At3pError, "CH_CONFIG")
T.raises("frame: an extension unit refused", lambda: R.Decoder().decode(bytes([0x40, 0])),
         R.At3pError, "CH_UNIT_EXTENSION")
import numpy as np  # noqa: E402
M = np.array([[F.cosq(F.imdct_m(n, k)) / 2.0 ** 25 for k in range(128)] for n in range(256)])
T.check("fixed: the IMDCT angle formula is ffmpeg's transform",
        bool(np.abs(M - R.IMDCT_M).max() < 1e-6), True)
D = np.array([[F.ipqf_dct(i, j)[0] * F.cosq(F.ipqf_dct(i, j)[1]) / 2.0 ** 35
               for j in range(16)] for i in range(16)])
T.check("fixed: the IPQF DCT formula is ffmpeg's transform",
        bool(np.abs(D - R.IPQF_M).max() < 1e-9), True)
T.check("fixed: the scale factors are held exactly",
        all(m * 2.0 ** -e == float(np.float32(v)) for m, e, v in zip(F.SF_M, F.SF_E, R.T.SF_TAB)),
        True)

print("[tables]")
r = subprocess.run([sys.executable, os.path.join(TOOLS, "gen_at3p_tables.py"), "--check"],
                   capture_output=True, text=True)
if r.returncode == 2:
    print("  SKIP: no pinned ffmpeg source (set UMD_REFS_DIR)")
else:
    T.check("at3p_tables.py is a fresh transcription", r.returncode, 0)

iso_dir = os.path.expanduser(os.environ.get("UMD_ISO_DIR", "~/umd-isos"))
TRACKS = [   # (image, clip or None = the main title, params word)
    ("Akira (PSP Video).iso", None, 0x4855),
    ("Godzilla (PSP Video).ISO", None, 0x483F),
    ("Goo Goo Dolls - Live in Alaska (2005).ISO", None, 0x487F),
    ("The Animatrix (2003).ISO", 1, 0x482A),
]
have = shutil.which("ffmpeg") and all(os.path.exists(os.path.join(iso_dir, t[0])) for t in TRACKS)

print("[ffmpeg]")
if not have:
    print("  SKIP: ffmpeg or the disc images missing (set UMD_ISO_DIR)")
else:
    cache = {}
    for img, clip, prm in TRACKS:
        clip, aus, info = R.disc_aus(os.path.join(iso_dir, img), clip, 0, 60000)
        cache[img] = aus
        T.check("%s: params word" % img, sorted(info["params"]), [prm])
        st = R.check(aus, len(aus) // 2, 24, fixed=True)
        T.check("%s: real signal in the window (peak > 0.02)" % img, st["ref_peak"] > 0.02, True)
        T.check("%s: float within %.2f LSB (%.4f)" % (img, SW.FLOAT_GATE_LSB, st["max_lsb"]),
                st["max_lsb"] <= SW.FLOAT_GATE_LSB, True)
        T.check("%s: fixed within %.1f LSB (%.3f)" % (img, F.GATE_LSB, st["fx_max_lsb"]),
                st["fx_max_lsb"] <= F.GATE_LSB, True)
        T.check("%s: no internal saturation" % img,
                {k: v for k, v in st["fx_sat"].items() if k != "pcm"}, {})

    print("[mute]")
    aus = cache["Akira (PSP Video).iso"]
    k0 = len(aus) // 2
    sel = list(aus[k0:k0 + 16])
    for k in range(4, 10):                  # mute bit: after start(1) type(2) nqu(5) = bit 8
        o, p, fr = sel[k]
        fr = bytearray(fr)
        fr[1] |= 0x80
        sel[k] = (o, p, bytes(fr))
    st = R.check(sel, 0, None, fixed=True)
    T.check("mute: the path runs (%d frames)" % st["cov"].get("mute", 0), st["cov"].get("mute"), 6)
    T.check("mute: real signal around it", st["ref_peak"] > 0.02, True)
    T.check("mute: float within the gate (%.4f)" % st["max_lsb"], st["max_lsb"] <= SW.FLOAT_GATE_LSB, True)
    T.check("mute: fixed within the gate (%.3f)" % st["fx_max_lsb"], st["fx_max_lsb"] <= F.GATE_LSB, True)

    print("[refuse]")
    o, p, fr = aus[k0]
    fr = bytearray(fr)
    fr[0] = fr[0] & 0x9F                    # unit type 01 (stereo) -> 00 (mono)
    T.raises("mono unit: the model refuses", lambda: R.Decoder().decode(bytes(fr)),
             R.At3pError, "CH_CONFIG")
    import at3p_extract as X
    ref = R.ffmpeg_f32(X.to_oma([aus[k0 - 1], (o, p, bytes(fr)), aus[k0 + 1]]))
    T.check("mono unit: ffmpeg drops the frame too", len(ref), 2 * R.FRAME_SAMPLES)
T.finish()
