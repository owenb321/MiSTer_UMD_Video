#!/bin/bash
# build_main.sh -- the HIL Main for the UMD core (main/README.md): stock Main_MiSTer at a
# pinned commit plus the overlay under main/support/umd/, patched by
# main/integration/apply_integration.py. HARVESTED from MiSTer_DVD main/build_main.sh.
#
# It never modifies this repo's tree: stock Main is fetched into a scratch build dir
# (git-ignored), the overlay copied in, the ARM binary emitted there.
#
#   USE_DOCKER=1 main/build_main.sh      -> main/.build/MiSTer_UMD
# Env: USE_DOCKER, MAIN_DOCKER_IMAGE, MAIN_MISTER_SRC (an existing checkout to copy),
#      MAIN_MISTER_REF, CROSS_COMPILE, BUILD_DIR -- as MiSTer_DVD's.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"

# Stock base: the commit MiSTer_DVD's integration anchors were verified against (its
# build_main.sh). Bump deliberately; a moved anchor makes the patcher fail naming the step.
MAIN_MISTER_URL="${MAIN_MISTER_URL:-https://github.com/MiSTer-devel/Main_MiSTer.git}"
MAIN_MISTER_REF="${MAIN_MISTER_REF:-7317947}"
BUILD_DIR="${BUILD_DIR:-$HERE/.build}"
STOCK="$BUILD_DIR/Main_MiSTer"
OUT_NAME="MiSTer_UMD"          # the one binary for users and the HIL (hps_host.md §1, H1 / H2)

echo "== $OUT_NAME build =="
mkdir -p "$BUILD_DIR"
rm -rf "$STOCK"
if [ -n "${MAIN_MISTER_SRC:-}" ]; then
    cp -a "$MAIN_MISTER_SRC" "$STOCK"
    ( cd "$STOCK" && git checkout -q "$MAIN_MISTER_REF" )
    rm -rf "$STOCK/.git" "$STOCK/obj" "$STOCK/build"
else
    git clone --quiet "$MAIN_MISTER_URL" "$STOCK"
    ( cd "$STOCK" && git checkout -q "$MAIN_MISTER_REF" )
    rm -rf "$STOCK/.git"
fi
# the overlay (the Makefile globs support/*/*.cpp); the field table must be current
python3 "$HERE/../tools/telem_layout.py" --check
python3 "$HERE/../tools/host_layout.py" --check     # the host port's words (umd_host_proto.h, B3)
mkdir -p "$STOCK/support/umd"
cp "$HERE"/support/umd/*.cpp "$HERE"/support/umd/*.c "$HERE"/support/umd/*.h "$STOCK/support/umd/"
# the menu engine (P9, C; the Makefile's C_SRC gains it: integration step 3)
mkdir -p "$STOCK/support/umd/menu"
cp "$HERE"/support/umd/menu/*.c "$HERE"/support/umd/menu/*.h "$STOCK/support/umd/menu/"
# libpng 1.6.37's headers: the version Main runs with (the Linux image's; it links against
# the tree's 1.6.28 .so, same soname) -- umd_sub.cpp, docs/hps_host.md §3.3
cp -r "$HERE"/support/umd/libpng "$STOCK/support/umd/"
python3 "$HERE/integration/apply_integration.py" "$STOCK"
make -C "$STOCK" ${CROSS_COMPILE:+CROSS_COMPILE="$CROSS_COMPILE"} -j"$(nproc)"
if [ -f "$STOCK/bin/MiSTer" ]; then
    cp "$STOCK/bin/MiSTer" "$BUILD_DIR/$OUT_NAME"
    # provenance (B5): what tools/package_release.sh checks against the .rbf's manifest -- the
    # same commit (so the same host-port PROTO), a clean tree, the pinned stock base
    REPO="$(cd "$HERE/.." && pwd)"
    G="git -c safe.directory=* -C $REPO"
    SHA="$($G rev-parse HEAD 2>/dev/null || echo unknown)"
    DIRTY=false; $G diff --quiet HEAD -- 2>/dev/null || DIRTY=true
    PROTO="$(sed -n 's/^#define UMD_HOST_PROTO  *\([0-9]*\).*/\1/p' "$HERE/support/umd/umd_host_proto.h")"
    SUM="$(sha256sum "$BUILD_DIR/$OUT_NAME" | cut -d' ' -f1)"
    cat > "$BUILD_DIR/$OUT_NAME.json" <<JSON
{
  "binary": "$OUT_NAME",
  "bytes": $(stat -c %s "$BUILD_DIR/$OUT_NAME"),
  "sha256": "$SUM",
  "git": {"sha": "$SHA", "dirty": $DIRTY},
  "main_mister": {"url": "$MAIN_MISTER_URL", "ref": "$MAIN_MISTER_REF"},
  "host_proto": ${PROTO:-0},
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
    echo "== done: $BUILD_DIR/$OUT_NAME ($(stat -c %s "$BUILD_DIR/$OUT_NAME") bytes), manifest $OUT_NAME.json"
else
    echo "!! the build did not produce $STOCK/bin/MiSTer" >&2; exit 1
fi
