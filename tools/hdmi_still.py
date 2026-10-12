#!/usr/bin/env python3
"""hdmi_still.py -- the rig's HDMI output checked on a STILL picture (docs/hil_harness.md "HDMI
capture"): 1080p60 from the capture card, luma only and streamed (no file: 60 s raw is ~7 GB), a
reference from the median of 15 frames after a 2 s lock warm-up, then every frame's pixels against
it. A digital capture of a paused picture repeats exactly, so ANY difference outside --mask is the
output path (ascal's read side, a pll_hdmi timing failure) or something on screen that moves.
Pause the picture (the diagnostic HUD, whose WT counter counted while paused, left the core: A11;
--mask still hides any region that moves).

    hdmi_still.py [--seconds 60] [--dev /dev/video0] [--mask y0:y1:x0:x1 ...] [--out PREFIX]
Prints "max pixel diff" and the frames with differing rows; saves PREFIX_ref.png / _worst.npy.
"""
import argparse
import subprocess
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--seconds", type=float, default=60)
ap.add_argument("--dev", default="/dev/video0")
ap.add_argument("--mask", action="append", default=[])
ap.add_argument("--out", default="hdmi_still")
a = ap.parse_args()
masks = [tuple(int(v) for v in m.split(":")) for m in a.mask]
W, H = 1920, 1080
cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "v4l2", "-input_format", "yuyv422",
       "-video_size", "%dx%d" % (W, H), "-framerate", "60", "-i", a.dev,
       "-t", str(a.seconds + 2), "-f", "rawvideo", "-pix_fmt", "gray", "-"]
p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
n = 0; ref = None; warm = []; stats = []; worst = None
while True:
    b = p.stdout.read(W * H)
    if len(b) < W * H: break
    f = np.frombuffer(b, np.uint8).reshape(H, W)
    n += 1
    if n <= 120: continue                    # 2 s warm-up (lock)
    if ref is None:
        warm.append(f.copy())
        if len(warm) == 15: ref = np.median(np.stack(warm), axis=0).astype(np.int16)
        continue
    d = np.abs(f.astype(np.int16) - ref)
    for y0, y1, x0, x1 in masks: d[y0:y1, x0:x1] = 0
    rowmax = d.max(axis=1)
    bad = int((rowmax > 24).sum())
    stats.append((n, int(d.max()), float(d.mean()), bad))
    if worst is None or bad > worst[0]: worst = (bad, n, f.copy())
p.wait()
print("frames %d scored %d" % (n, len(stats)))
if stats:
    a = np.array([s[1:] for s in stats])
    print("max pixel diff: max %d median %d; mean diff max %.3f; frames with >0 bad rows: %d; worst bad rows %d"
          % (a[:, 0].max(), np.median(a[:, 0]), a[:, 1].max(), int((a[:, 2] > 0).sum()), int(a[:, 2].max())))
    np.save(a.out + "_ref.npy", ref.astype(np.uint8))
    if worst and worst[0] > 0:
        np.save(a.out + "_worst.npy", worst[2]); print("worst frame", worst[1])
    from PIL import Image
    Image.fromarray(ref.astype(np.uint8)).save(a.out + "_ref.png")
