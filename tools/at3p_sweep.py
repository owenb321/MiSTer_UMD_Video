#!/usr/bin/env python3
"""The ATRAC3plus model against ffmpeg over the whole library: every clip, every audio
track, a few windows each (the decoder starts cold at each window, as ffmpeg does on
the same cut). Reports the worst and RMS error per track (float path; with --fixed also
the fixed-point path, tools/at3p_fixed.py), every refusal, and the coverage UNION --
the coding paths no disc reaches are listed: decoded, but untested
(docs/at3p_decoder.md S2.3).

    UMD_ISO_DIR=... at3p_sweep.py [paths...] [--jobs 6] [--windows 3] [--aus 48]
                                  [--fixed] [--tsv out.tsv]
Exit 0 when every window is inside the gates (float <= FLOAT_GATE_LSB; fixed <=
at3p_fixed.GATE_LSB); 1 otherwise; 2 SKIP (no images).
"""
import argparse
import multiprocessing as mp
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402

FLOAT_GATE_LSB = 0.05     # the float path mirrors ffmpeg; measured worst 0.016 (S2.2)
ZERO_FRACTION_SKIP = 0.05


def track_windows(n, windows, w):
    if n <= w:
        return [0]
    if windows == 1:
        return [0]
    return sorted(set(int(k * (n - w) / (windows - 1)) for k in range(windows)))


def sweep_iso(args):
    path, windows, w, fixed, emu = args
    import psmf_ref
    import umd_clpi
    import umd_iso
    import at3p_extract as X
    rows = []
    cov = {}
    try:
        with umd_iso.UmdIso(path) as iso:
            clips = iso.clips()
        for clip in clips:
            if umd_clpi.zero_fraction(path, clip) > ZERO_FRACTION_SKIP:
                rows.append((path, clip, -1, "SKIP", "damaged rip", 0, 0.0, 0.0, None, None))
                continue
            src = psmf_ref.Source(path, clip)
            try:
                r = psmf_ref.parse(src.mm, src.start, src.end)
                tracks = sorted(set(p.sub for p in r.packets if p.kind == "audio"))
                per = {}
                for t in tracks:
                    es, marks = psmf_ref.es(src.mm, r, "audio", t)
                    per[t] = X.split_aus(es, marks)
            finally:
                src.close()
            for t, (aus, info) in per.items():
                prm = ",".join("%04x" % p for p in sorted(info["params"]))
                if not aus:
                    rows.append((path, clip, t, "EMPTY", prm, 0, 0.0, 0.0, None, None))
                    continue
                worst = rms = 0.0
                fworst = frms = None
                verdict, note = "PASS", ""
                for sk in track_windows(len(aus), windows, w):
                    if emu:                 # the microcode: its parse record (and PCM), every frame
                        import at3p_emu
                        est = at3p_emu.check(aus[sk:sk + w], verbose=False,
                                             parse_only=(emu != "full"))
                        cov["emu_frames"] = cov.get("emu_frames", 0) + est["frames"]
                        if est["bad"]:
                            verdict, note = "EMU", "AU %d: %s" % (sk, est["reports"][0][:160])
                            break
                        continue
                    try:
                        st = R.check(aus, sk, w, fixed=fixed)
                    except R.At3pError as e:
                        verdict, note = "REFUSED", "AU %d: %s" % (sk, e)
                        break
                    worst = max(worst, st["max_lsb"])
                    rms = max(rms, st["rms_lsb"])
                    if fixed:
                        fworst = max(fworst or 0.0, st["fx_max_lsb"])
                        frms = max(frms or 0.0, st["fx_rms_lsb"])
                    for k, v in st["cov"].items():
                        cov[k] = cov.get(k, 0) + v
                    for k, v in st.get("fx_sat", {}).items():
                        cov["sat_" + k] = cov.get("sat_" + k, 0) + v
                    for k, v in st.get("fx_cond", {}).items():
                        cov["cond_" + k] = max(cov.get("cond_" + k, 0.0), v)
                rows.append((path, clip, t, verdict, prm + (" " + note if note else ""),
                             len(aus), worst, rms, fworst, frms))
    except Exception:
        rows.append((path, -1, -1, "ERROR", traceback.format_exc().strip().splitlines()[-1],
                     0, 0.0, 0.0, None, None))
    return rows, cov


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--windows", type=int, default=3)
    ap.add_argument("--aus", type=int, default=48)
    ap.add_argument("--fixed", action="store_true", help="also score the fixed path")
    ap.add_argument("--emu", action="store_true",
                    help="score the microcode's parse (tools/at3p_emu.py) instead of ffmpeg")
    ap.add_argument("--emu-full", action="store_true",
                    help="... its parse AND its PCM against tools/at3p_fixed.py (slow)")
    ap.add_argument("--tsv")
    a = ap.parse_args(argv)
    import umd_census
    isos = umd_census.gather(a.paths)
    if not isos:
        print("at3p_sweep: SKIP (no images)")
        return 2
    emu = "full" if a.emu_full else a.emu
    work = [(p, a.windows, a.aus, a.fixed, emu) for p in isos]
    rows, cov = [], {}
    with mp.Pool(a.jobs) as pool:
        for rr, cc in pool.imap_unordered(sweep_iso, work):
            rows += rr
            for k, v in cc.items():
                cov[k] = max(cov.get(k, 0.0), v) if k.startswith("cond_") else cov.get(k, 0) + v
            for r in rr:
                fx = "" if r[8] is None else "  fixed max %.2f rms %.3f" % (r[8], r[9])
                print("%-8s %-44s clip %3d tr %2d %5d AUs  float max %.4f rms %.5f%s  %s" % (
                    r[3], os.path.basename(r[0])[:44], r[1], r[2], r[5], r[6], r[7], fx, r[4]),
                    flush=True)
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    if a.tsv:
        with open(a.tsv, "w") as f:
            f.write("disc\tclip\ttrack\tverdict\tparams\taus\tfloat_max\tfloat_rms\tfixed_max\tfixed_rms\n")
            for r in rows:
                f.write("\t".join(str(x) for x in (os.path.basename(r[0]),) + r[1:]) + "\n")
    scored = [r for r in rows if r[3] == "PASS"]
    fail = [r for r in scored if r[6] > FLOAT_GATE_LSB]
    if a.fixed:
        import at3p_fixed
        fail += [r for r in scored if r[8] is not None and r[8] > at3p_fixed.GATE_LSB]
    bad = [r for r in rows if r[3] in ("REFUSED", "ERROR", "EMU")]
    if emu:
        print("microcode %s: %d frames scored" % ("parse + PCM" if emu == "full" else "parse",
                                                   cov.get("emu_frames", 0)))
    print("\n%d tracks scored, %d skipped/empty, %d refused/error, %d over the gate" % (
        len(scored), len([r for r in rows if r[3] in ("SKIP", "EMPTY")]), len(bad), len(fail)))
    if scored:
        print("float path: worst %.4f LSB, worst window rms %.5f LSB" % (
            max(r[6] for r in scored), max(r[7] for r in scored)))
        if a.fixed:
            print("fixed path: worst %.3f LSB, worst window rms %.4f LSB" % (
                max(r[8] for r in scored), max(r[9] for r in scored)))
    if not emu:                                # (the emulator runs feed no coverage counters)
        never = [k for k in R.cov_universe() if not cov.get(k)]
        print("coverage: %d of %d paths reached; never reached: %s" % (
            len(R.cov_universe()) - len(never), len(R.cov_universe()), " ".join(never) or "-"))
    sats = {k: v for k, v in cov.items() if k.startswith("sat_")}
    print("fixed-path saturations: %s  (pcm: ffmpeg's s16 clips the same samples; any other "
          "stage is a failure)" % (" ".join("%s=%d" % kv for kv in sorted(sats.items())) or "none"))
    inner = {k: v for k, v in sats.items() if k != "sat_pcm"}
    conds = {k[5:]: v for k, v in cov.items() if k.startswith("cond_")}
    if conds:
        print("fixed-path worst error by synthesis condition: %s" % " ".join(
            "%s=%.2f" % kv for kv in sorted(conds.items())))
    odd = sorted(k for k in cov if k not in R.cov_universe()
                 and not k.startswith(("sat_", "cond_", "emu_")))
    if odd:
        print("coverage keys outside the universe: %s" % " ".join(
            "%s=%d" % (k, cov[k]) for k in odd))
    ok = not fail and not bad and not inner
    print("at3p_sweep: %s" % ("ALL GREEN" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
