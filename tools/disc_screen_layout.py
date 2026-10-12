#!/usr/bin/env python3
"""disc_screen_layout.py -- R5, the disc screen (docs/resume.md §6): the page the UMD Main draws while a
disc is stopped and no menu engine runs -- the disc's own XMB art (UMD_VIDEO/PIC1.PNG over the page;
ICON0.PNG, the thumbnail, on a card), its title (PARAM.SFO TITLE) and the Play line -- as the PSP's XMB
shows an inserted UMD. PSP-INSPIRED, NOT RECREATED (transport_hud.md): the HUD's font and box tint.

THE GOLDEN of main/support/umd/umd_disc_screen.c (bench/umd/run_disc_screen.sh scores the C against
page() pixel for pixel): integers only, the C's order of operations.
  * PIC1 scaled bilinear into the fit's target (0 the raster, 1 the 4:3 CRT's Letterbox 720 x 360 at line
    60, 2 Crop: the centre 640 of the 854-wide scene -- umd_mh_fit's, analog.md S7): each destination
    pixel's centre mapped into the source span in 16.16, clamped to the image, two taps a side with 8-bit
    weights on the PREMULTIPLIED source (round(c a / 255)), rounded once at the end; over the cleared page
    (R5a revised: nothing behind it).
  * the card (R5e, approved 2026-10-07): the panel's rounded box in the HUD's tint, 612 x 118 at (54, 260),
    ICON0 at 144 x 94 inside it, the title (word-wrapped, two lines, "..." past them) in white, the Play
    line in grey -- the HUD's font (panel_layout.text_rgba).
  * the title (display_title): the SFO's with fullwidth ASCII folded and U+2122 as "TM" when every
    character is then printable ASCII, else the image's file name without its extension.

  disc_screen_layout.py --mockups [--iso-dir DIR] [--out DIR]
      the approved card over each sample disc, to .sim/disc_screen_mockups/ (the discs' art is the
      studios': never committed). Rejected at the review (resume.md §6): variant A, the XMB's bare type
      on the art (unreadable on light art), and the wave behind the art (R5a revised).
  disc_screen_layout.py --page OUT.rgba [--pic1 RAW W H] [--icon0 RAW W H] --title T --hint H --fit F
      one page as raw premultiplied RGBA (the bench's reference; RAW files straight RGBA8)
"""
import argparse
import glob
import io
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import panel_layout as PL  # noqa: E402

W, H = 720, 480
BOX_X, BOX_W, PAD = 54, 612, 12
ICON_W, ICON_H = 144, 94
BOX_H = ICON_H + 2 * PAD
BOX_Y = 378 - BOX_H
CELL_W, CELL_H = 10, 24
WHITE, GREY = PL.WHITE, PL.GREY

SAMPLES = [                                 # (the image's name prefix, why it is a sample)
    ("Akira", "RGB art"),
    ("Short Circuit", "an RGBA thumbnail (opaque, as every one)"),
    ("Pirates of The Caribbean", "a long title; the only art not opaque (0.7 %)"),
    ("Now Thats What I Call Music", "no ICON0"),
    ("Ghost in the Shell", "a title with Japanese characters: the file name"),
    ("Transporter 2", "RGBA art (opaque)"),
]


# ---- the title -----------------------------------------------------------------------------------

def display_title(title, image_name):
    out, ok = [], True
    for ch in (title or ""):
        c = ord(ch)
        if 0xFF01 <= c <= 0xFF5E:
            out.append(chr(c - 0xFEE0))
        elif c == 0x2122:
            out.append("TM")
        elif 32 <= c <= 126:
            out.append(ch)
        else:
            ok = False
            break
    t = "".join(out).strip(" ")
    if ok and t:
        return t
    n = os.path.basename(image_name or "")
    d = n.rfind(".")
    return n[:d] if d > 0 else n


def hint(resume, ms):
    if not resume:
        return "> Play"
    s = ms // 1000
    return "> Resume %d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60)


def title_lines(title, max_chars, max_lines=2):
    lines, cur = [], ""
    for wd in title.split(" "):
        if not wd:
            continue
        while len(wd) > max_chars:                       # (a word longer than a line: broken)
            if cur:
                lines.append(cur)
                cur = ""
            lines.append(wd[:max_chars])
            wd = wd[max_chars:]
        if not cur:
            cur = wd
        elif len(cur) + 1 + len(wd) <= max_chars:
            cur += " " + wd
        else:
            lines.append(cur)
            cur = wd
    if cur:
        lines.append(cur)
    if len(lines) > max_lines:
        lines = lines[:max_lines - 1] + [lines[max_lines - 1][:max_chars - 3] + "..."]
    return lines


# ---- the arithmetic ------------------------------------------------------------------------------

def _taps(s0, sw, n, size):
    d = np.arange(n, dtype=np.int64)
    u = s0 + ((2 * d + 1) * sw) // (2 * n) - 32768
    u = np.clip(u, 0, (size - 1) << 16)
    i0 = u >> 16
    i1 = np.minimum(i0 + 1, size - 1)
    return i0, i1, (u >> 8) & 255


def scale(img, sx0, sy0, sw, sh, dw, dh):
    """straight RGBA (h, w, 4) uint8 -> premultiplied (dh, dw, 4) int64, the C's bilinear"""
    a = img.astype(np.int64)
    p = a.copy()
    p[..., :3] = PL.premul(a[..., :3], a[..., 3:4])
    ih, iw = img.shape[:2]
    i0, i1, fx = _taps(sx0, sw, dw, iw)
    j0, j1, fy = _taps(sy0, sh, dh, ih)
    fx = fx[None, :, None]
    fy = fy[:, None, None]
    r0, r1 = p[j0], p[j1]
    h0 = r0[:, i0] * (256 - fx) + r0[:, i1] * fx
    h1 = r1[:, i0] * (256 - fx) + r1[:, i1] * fx
    return (h0 * (256 - fy) + h1 * fy + 32768) >> 16


def rbox(w, h, rgba):
    r8 = 8 * PL.BOX_R
    yy, xx = np.mgrid[0:h * 4, 0:w * 4]
    px8, py8 = 2 * xx + 1, 2 * yy + 1
    dx = np.maximum(0, np.maximum(r8 - px8, px8 - (8 * w - r8)))
    dy = np.maximum(0, np.maximum(r8 - py8, py8 - (8 * h - r8)))
    n = ((dx * dx + dy * dy) <= r8 * r8).reshape(h, 4, w, 4).sum(axis=(1, 3)).astype(np.int64)
    out = np.zeros((h, w, 4), dtype=np.int64)
    for c in range(4):
        out[..., c] = (n * rgba[c] + 8) // 16
    return out


def put(pg, x0, y0, el):
    h, w = el.shape[:2]
    pg[y0:y0 + h, x0:x0 + w] = PL.over(pg[y0:y0 + h, x0:x0 + w], el)


def page(pic1, icon0, title, hint_text, fit=0):
    """-> premultiplied (480, 720, 4) int64, R G B A; pic1 / icon0 straight RGBA uint8 arrays or None"""
    pg = np.zeros((H, W, 4), dtype=np.int64)
    if pic1 is not None and pic1.size:
        ih, iw = pic1.shape[:2]
        W16, H16 = iw << 16, ih << 16
        if fit == 1:
            put(pg, 0, 60, scale(pic1, 0, 0, W16, H16, W, 360))
        elif fit == 2:
            put(pg, 0, 0, scale(pic1, W16 * 107 // 854, 0, W16 * 640 // 854, H16, W, H))
        else:
            put(pg, 0, 0, scale(pic1, 0, 0, W16, H16, W, H))
    put(pg, BOX_X, BOX_Y, rbox(BOX_W, BOX_H, PL.BOX_RGBA))
    ix, iy = BOX_X + PAD, BOX_Y + PAD
    tx = ix + 6
    if icon0 is not None and icon0.size:
        ih, iw = icon0.shape[:2]
        put(pg, ix, iy, scale(icon0, 0, 0, iw << 16, ih << 16, ICON_W, ICON_H))
        tx = ix + ICON_W + 18
    for k, ln in enumerate(title_lines(title or "", (BOX_X + BOX_W - 14 - tx) // CELL_W)):
        put(pg, tx, iy + 4 + k * CELL_H, PL.text_rgba(ln, WHITE))
    if hint_text:
        put(pg, tx, iy + ICON_H - CELL_H, PL.text_rgba(hint_text, GREY))
    return pg


# ---- the disc's art ------------------------------------------------------------------------------

def disc_art(path):
    """-> (PIC1 straight RGBA array or None, ICON0 or None, the SFO title)"""
    from PIL import Image
    from umd_iso import UmdIso
    import umd_sfo
    iso = UmdIso(path)

    def png(name):
        p = "/UMD_VIDEO/" + name
        if not iso.exists(p):
            return None
        return np.asarray(Image.open(io.BytesIO(iso.read(p))).convert("RGBA"), dtype=np.uint8)
    title = ""
    if iso.exists("/UMD_VIDEO/PARAM.SFO"):
        title = str(umd_sfo.parse(iso.read("/UMD_VIDEO/PARAM.SFO")).get("TITLE", ""))
    return png("PIC1.PNG"), png("ICON0.PNG"), title


def find_iso(iso_dir, prefix):
    for p in sorted(glob.glob(os.path.join(iso_dir, "*"))):
        if os.path.basename(p).lower().startswith(prefix.lower()) and p.lower().endswith(".iso"):
            return p
    return None


# ---- the mockups ---------------------------------------------------------------------------------

def mockups(iso_dir, out):
    from PIL import Image
    os.makedirs(out, exist_ok=True)
    black = np.zeros((H, W, 3), dtype=np.uint8)          # (R5a revised: black behind the page)
    for prefix, why in SAMPLES:
        iso = find_iso(iso_dir, prefix)
        if not iso:
            print("  SKIP %s: no image" % prefix)
            continue
        pic1, icon0, title = disc_art(iso)
        t = display_title(title, iso)
        tag = prefix.split()[0].lower()
        cases = [("card_%s" % tag, hint(True, 124000), 0)]
        if tag == "akira":
            cases += [("card_akira_ended", hint(False, 0), 0), ("card_akira_crt43", hint(True, 124000), 1),
                      ("card_akira_crop", hint(True, 124000), 2)]
        for name, h, fit in cases:
            Image.fromarray(PL.blend_video(black, page(pic1, icon0, t, h, fit))).save(os.path.join(out, name + ".png"))
        print("  %-28s %-48s shown %r" % (prefix, why, t))
    print("mockups: %s" % out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mockups", action="store_true")
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--out", default=os.path.join(ROOT, ".sim/disc_screen_mockups"))
    ap.add_argument("--page")
    ap.add_argument("--pic1", nargs=3)
    ap.add_argument("--icon0", nargs=3)
    ap.add_argument("--title", default="")
    ap.add_argument("--hint", default="")
    ap.add_argument("--fit", type=int, default=0)
    a = ap.parse_args(argv)
    if a.mockups:
        mockups(a.iso_dir, a.out)
        return 0
    if a.page:
        def raw(spec):
            if not spec:
                return None
            w, h = int(spec[1]), int(spec[2])
            return np.fromfile(spec[0], dtype=np.uint8).reshape(h, w, 4)
        page(raw(a.pic1), raw(a.icon0), a.title, a.hint, a.fit).astype(np.uint8).tofile(a.page)
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
