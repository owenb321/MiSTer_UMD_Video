#!/usr/bin/env python3
"""menu_vag_check.py -- P9 M3 (C)'s gate: the menus' sound effects decoded by the UMD Main's
vag.c (bench/umd/menu/vag_dump.c) against ffmpeg's adpcm_psx, every channel of every sound of every
RCO on every disc image, sample for sample; and its 48 kHz resample against this file's own (the
definition: frame k at k * rate / 48000, a + (b - a) * frac truncated toward zero, the last sample
held past a channel's end).

    menu_vag_check.py [--iso-dir DIR] [--dump VAG_DUMP]

Prints "PASS: menu_vag_check" or the first differences and "FAIL"; "SKIP" (exit 0) without images.
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import umd_iso  # noqa: E402


def ffmpeg_vag(path):
    # every RCO channel's VAG header says version 4 (115 of 115 in the library, mono and stereo
    # sounds alike: a stereo sound is two VAGs), which ffmpeg's VAG demuxer reads as two channels
    # interleaved by 16-byte blocks (the PS2's files): the oracle is its adpcm_psx DECODE, so it gets
    # a copy saying mono (version 3), the ADPCM data unchanged
    v = bytearray(open(path, "rb").read())
    v[4:8] = b"\x00\x00\x00\x03"
    mono = path + ".mono.vag"
    open(mono, "wb").write(v)
    p = subprocess.run(["ffmpeg", "-v", "error", "-f", "vag", "-i", mono, "-f", "s16le", "-acodec", "pcm_s16le", "-"],
                       capture_output=True)
    if p.returncode:
        return None
    return np.frombuffer(p.stdout, "<i2")


def vag_file(blocks, rate=44100):
    data = b"".join(blocks)
    hdr = b"VAGp" + (3).to_bytes(4, "big") + bytes(4) + len(data).to_bytes(4, "big") + rate.to_bytes(4, "big") + bytes(12) + b"synthetic".ljust(16, b"\0")
    return hdr + data


def synthetic(dump):
    import random
    rnd = random.Random(7)
    cases = {
        # full-scale positive then negative nibbles at shift 0 through every filter: the history runs
        # far past 16 bits (the output clipped, the history not)
        "overflow": [bytes([f << 4 | 0, 0]) + bytes([0x77] * 14) for f in (4, 4, 4, 2, 2)] +
                    [bytes([f << 4 | 0, 0]) + bytes([0x88] * 14) for f in (4, 4, 3, 3)],
        # a block flagged 7 between sounding blocks: silence, and the history it leaves at 0
        "flag7": [bytes([0x42, 0]) + bytes(rnd.randrange(256) for _ in range(14)) for _ in range(3)] +
                 [bytes([0x42, 7]) + bytes(rnd.randrange(256) for _ in range(14))] +
                 [bytes([0x31, 0]) + bytes(rnd.randrange(256) for _ in range(14)) for _ in range(3)],
        # every filter and shift, random nibbles
        "sweep": [bytes([f << 4 | sh, 0]) + bytes(rnd.randrange(256) for _ in range(14)) for f in range(5) for sh in range(13)],
    }
    fails = 0
    with tempfile.TemporaryDirectory() as t:
        for nm, blocks in cases.items():
            vp = os.path.join(t, nm + ".vag")
            open(vp, "wb").write(vag_file(blocks))
            sp = os.path.join(t, nm + ".s16")
            p = subprocess.run([dump, "--vag", vp, sp], capture_output=True, text=True)
            ours = np.fromfile(sp, "<i2") if p.returncode == 0 and os.path.exists(sp) else None
            ref = ffmpeg_vag(vp)
            if ours is None or ref is None or len(ours) != len(ref) or (ours != ref).any():
                fails += 1
                at = "-" if ours is None or ref is None or len(ours) != len(ref) else int(np.argmax(ours != ref))
                print("  FAIL synthetic %s: differs from ffmpeg (first at %s)" % (nm, at))
    print("menu_vag_check: synthetic VAGs %s" % ("equal to ffmpeg's" if not fails else "DIFFER"))
    return fails


def resample(chs, rate):
    n = max(len(c) for c in chs)
    f = (n * 48000 + rate - 1) // rate
    out = np.zeros((f, len(chs)), np.int64)
    k = np.arange(f, dtype=np.int64)
    pos = k * rate
    i, fr = pos // 48000, pos % 48000
    for c, ch in enumerate(chs):
        ch = np.asarray(ch, np.int64)
        m = len(ch)
        a = ch[np.minimum(i, m - 1)]
        b = ch[np.minimum(i + 1, m - 1)]
        d = (b - a) * fr
        out[:, c] = a + np.where(d < 0, -((-d) // 48000), d // 48000)      # toward zero
    return out.reshape(-1).astype("<i2")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--dump", default=os.path.join(ROOT, ".sim/menu/vag_dump"))
    a = ap.parse_args()
    # SYNTHETIC VAGs first: what the library never exercises -- a history driven past 16 bits (every
    # filter at shift 0 on full-scale nibbles: ffmpeg keeps the history unclipped), a block flagged 7
    # between sounding ones, every shift and filter
    syn_fail = synthetic(a.dump)
    isos = sorted(p for p in glob.glob(os.path.join(a.iso_dir, "*")) if p.lower().endswith(".iso"))
    if not isos and not syn_fail:
        print("SKIP: menu_vag_check: no images under %s (the synthetic VAGs equal)" % a.iso_dir)
        return 0
    if not isos:
        print("SKIP: menu_vag_check: no images under %s" % a.iso_dir)
        return 0
    n_snd = n_ch = n_smp = 0
    fails = syn_fail
    rates = {}
    for iso in isos:
        with umd_iso.UmdIso(iso) as u:
            try:
                names = [n for n in u.listdir("/UMD_VIDEO/RESOURCE") if n.upper().endswith(".RCO")]
            except Exception:
                continue
            for name in names:
                with tempfile.TemporaryDirectory() as t:
                    rp = os.path.join(t, "x.rco")
                    open(rp, "wb").write(u.read("/UMD_VIDEO/RESOURCE/" + name, record=False))
                    p = subprocess.run([a.dump, rp, t], capture_output=True, text=True)
                    for line in p.stdout.splitlines():
                        f = line.split()
                        where = "%s %s entry %s" % (os.path.basename(iso), name, f[1] if len(f) > 1 else "?")
                        if f[0] == "ERR":
                            fails += 1
                            print("  FAIL %s: %s" % (where, line))
                            continue
                        _, ent, nch, rate, n0, n1, frames = f
                        nch, rate = int(nch), int(rate)
                        rates[rate] = rates.get(rate, 0) + 1
                        n_snd += 1
                        chs = []
                        for c in range(nch):
                            ours = np.fromfile(os.path.join(t, "%s_%d.s16" % (ent, c)), "<i2")
                            ref = ffmpeg_vag(os.path.join(t, "%s_%d.vag" % (ent, c)))
                            n_ch += 1
                            n_smp += len(ours)
                            if ref is None or len(ref) != len(ours) or (ref != ours).any():
                                fails += 1
                                if fails <= 10:
                                    diff = "ffmpeg refused it" if ref is None else \
                                        "%d vs ffmpeg's %d samples" % (len(ours), len(ref)) if len(ref) != len(ours) else \
                                        "first difference at sample %d" % int(np.argmax(ref != ours))
                                    print("  FAIL %s channel %d: %s" % (where, c, diff))
                            chs.append(ours)
                        r48 = np.fromfile(os.path.join(t, "%s.r48" % ent), "<i2")
                        want = resample(chs, rate)
                        if len(want) != len(r48) or (want != r48).any():
                            fails += 1
                            if fails <= 10:
                                print("  FAIL %s: the 48 kHz resample differs (%d vs %d samples)" % (where, len(r48), len(want)))
    print("menu_vag_check: %d sounds, %d channels, %d samples equal to ffmpeg's adpcm_psx; rates %s"
          % (n_snd, n_ch, n_smp, dict(sorted(rates.items()))))
    if fails:
        print("FAIL: menu_vag_check (%d)" % fails)
        return 1
    print("PASS: menu_vag_check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
