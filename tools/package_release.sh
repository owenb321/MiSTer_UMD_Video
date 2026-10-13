#!/usr/bin/env bash
# package_release.sh -- stage the SD-card tree for a release and zip it.
#
# Two artefacts ship (A7, docs/hps_host.md §1): the core's .rbf, and the UMD Main
# (`MiSTer_UMD`, main/build_main.sh): a build of the MiSTer's own Main program with the
# subtitle decode added. The zip mirrors the SD root, so a user extracts one thing:
#   _Other/UMD_YYYYMMDD.rbf   the core
#   MiSTer_UMD                the UMD Main -- at the root: `[UMD] main=MiSTer_UMD` names it there
#   MiSTer_UMD.json           its provenance (the commit, the stock Main it is built on)
#   UMD_INSTALL.txt           the install steps, the MiSTer.ini lines, the source pointer
#   umd_report.py             the bug-report bundle tool (tools/umd_report.py, docs/bug_reports.md
#                             R4): self-contained python3, run on the MiSTer or a PC
#
#   ./tools/package_release.sh [--rbf releases/UMD_YYYYMMDD.rbf] [--main main/.build/MiSTer_UMD]
#     -> releases/MiSTer_UMD_Video_<version>.zip
#
# <version> is CORE_VERSION from umd/emu.sv (v0.1.0 on a release commit, dev-<slug> on a
# feature branch), so the zip names the same build the OSD and the .rbf name.
#
# Refuses: a _MARGINAL_ .rbf; a UMD Main with no manifest, built from a dirty tree, or from a
# different commit than the .rbf (its .rbf.json): the two must speak the same host-port PROTO,
# and the same commit is what guarantees it.
set -euo pipefail
cd "$(dirname "$0")/.."

RBF=""
MAIN="main/.build/MiSTer_UMD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rbf) RBF="$2"; shift 2 ;;
    --main) MAIN="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

VER="$(sed -n 's/.*`define CORE_VERSION "\([^"]*\)".*/\1/p' umd/emu.sv | head -1)"
[ -n "$VER" ] || { echo "no CORE_VERSION in umd/emu.sv" >&2; exit 1; }

if [ -z "$RBF" ]; then
  RBF="$(ls -t releases/UMD_*.rbf 2>/dev/null | grep -v MARGINAL | head -1 || true)"
  [ -n "$RBF" ] || { echo "no releases/UMD_*.rbf -- build one first" >&2; exit 1; }
fi
[ -f "$RBF" ] || { echo "not found: $RBF" >&2; exit 1; }
case "$(basename "$RBF")" in *MARGINAL*) echo "refusing to package a _MARGINAL_ build" >&2; exit 1 ;; esac

# ---- the UMD Main: present, clean, built from the .rbf's commit ----
[ -f "$MAIN" ] || { echo "no UMD Main at $MAIN -- USE_DOCKER=1 main/build_main.sh" >&2; exit 1; }
[ -f "$MAIN.json" ] || { echo "no $MAIN.json -- rebuild the Main (main/build_main.sh writes it)" >&2; exit 1; }
[ -f "$RBF.json" ] || { echo "no $RBF.json -- the .rbf's manifest (build_release.sh writes it)" >&2; exit 1; }
python3 - "$MAIN" "$MAIN.json" "$RBF.json" <<'PY'
import hashlib, json, sys
main, mj, rj = sys.argv[1:4]
m = json.load(open(mj)); r = json.load(open(rj))
sha = hashlib.sha256(open(main, "rb").read()).hexdigest()
err = []
if m.get("sha256") != sha: err.append("the binary is not the one its manifest describes")
if m["git"].get("dirty"): err.append("the UMD Main was built from a dirty tree")
if r["git"].get("dirty"): err.append("the .rbf was built from a dirty tree")
if m["git"].get("sha") != r["git"].get("sha"):
    err.append("the UMD Main (%s) and the .rbf (%s) come from different commits" % (m["git"]["sha"][:7], r["git"]["sha"][:7]))
if err:
    print("refusing to package:\n  " + "\n  ".join(err), file=sys.stderr); sys.exit(1)
print("   main : %s (commit %s, host PROTO %s, Main_MiSTer %s)" % (m["binary"], m["git"]["sha"][:7], m["host_proto"], m["main_mister"]["ref"]))
PY
MAIN_REF="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['main_mister']['ref'])" "$MAIN.json")"
GIT_SHA="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['git']['sha'][:12])" "$MAIN.json")"
RBF_SHOWN="$(printf '%-27s' "_Other/$(basename "$RBF")")"
echo "   core : $(basename "$RBF")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/_Other"
cp "$RBF" "$STAGE/_Other/"
cp "$MAIN" "$STAGE/MiSTer_UMD"
chmod +x "$STAGE/MiSTer_UMD"
cp "$MAIN.json" "$STAGE/MiSTer_UMD.json"
cp tools/umd_report.py "$STAGE/umd_report.py"
cat > "$STAGE/UMD_INSTALL.txt" <<TXT
MiSTer UMD Video player core -- $VER

1. Extract this zip to the ROOT of your MiSTer SD card. If you copy files over the
   network (SSH/SFTP) instead of pulling the card, that root is /media/fat. You get:
     $RBF_SHOWN - the core (MiSTer's menu lists it under Other)
     MiSTer_UMD                  - the UMD Main; keep it at the root
     MiSTer_UMD.json             - which build it is
     umd_report.py               - makes a bug-report bundle (step 5)

2. For the UMD Main's features -- the discs' own menus, the control panel, a stopped disc's
   art, remembering where each disc stopped, a real UMD from a PSP -- add these two lines to
   /media/fat/MiSTer.ini (add the section; do NOT replace the file -- and if there is no
   MiSTer.ini, create one with just these lines):

     [UMD]
     main=MiSTer_UMD

   MiSTer then runs the UMD Main while the UMD core is loaded, and your usual Main for
   every other core. Without the lines the core still plays every disc the same way --
   picture, sound, subtitles, chapters and the rest -- going straight to the film instead
   of the disc's menus; the Control Panel button says "The control panel needs the UMD Main.".

3. Put UMD Video .iso images anywhere the file picker can reach (games/UMD/ is the
   convention), launch UMD, and pick an image from Load Video.

4. A real UMD: a PSP with custom firmware (ARK-5) can share the disc in its drive over USB.
   On the PSP: Settings > Custom Firmware Settings > USB Device = UMD (USB Read-Only on
   Auto), plug it into the MiSTer and enter USB mode. With the UMD Main (step 2), open UMD:
   the disc plays by itself. To change discs, leave USB mode on the PSP, swap, and enter
   USB mode again. (Without the UMD Main, see the manual's "Playing a real UMD".)

5. Reporting a bug on a disc: make a bundle of its structure (no picture, no sound) and
   attach it to the report. On the MiSTer, over SSH:
     python3 /media/fat/umd_report.py /media/fat/games/UMD/<image>.iso
   or on a PC with Python 3: python3 umd_report.py <image>.iso

Updating: extract the new zip over the old files; the core and the UMD Main must come
from the same release (a mismatched pair says "Update the UMD Main for the control panel.").
Removing the UMD Main: delete the two MiSTer.ini lines and MiSTer_UMD.

Source: the UMD Main is the MiSTer project's Main_MiSTer (GPL-3.0-or-later) at commit
$MAIN_REF (https://github.com/MiSTer-devel/Main_MiSTer), with this project's main/
directory added -- the MiSTer_UMD_Video repository at commit $GIT_SHA, whose
main/build_main.sh builds it. It loads the libpng already on every MiSTer.
TXT

OUT="releases/MiSTer_UMD_Video_${VER}.zip"
rm -f "$OUT"
python3 - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(stage):
        for f in sorted(files):
            p = os.path.join(root, f)
            zi = zipfile.ZipInfo.from_file(p, os.path.relpath(p, stage))
            if f == "MiSTer_UMD":
                zi.external_attr = 0o755 << 16          # executable on extraction
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(p, "rb") as fh:
                z.writestr(zi, fh.read())
print('packaged', out, os.path.getsize(out), 'bytes')
PY
