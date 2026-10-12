#!/usr/bin/env bash
# build_arm.sh -- menu_host_check for the DE10-Nano's A9 (fj#74, the renderer's cost measured where it runs):
# the Main's own toolchain image (main/docker, gcc-arm 10.2) and the Main's flags (-O3; the Makefile sets no
# -mcpu / -mfpu), linked against the Main's libpng16 / zlib (Main_MiSTer/lib/imlib2) and its miniz for the RCO tables (lib/miniz): main/build_main.sh
# must have run once. JPEG is stubbed (no libjpeg there): a disc whose menus carry JPEGs draws them blank.
#   bench/umd/menu/build_arm.sh [EXTRA_CFLAGS...]   -> .sim/menu-arm/menu_host_check
#   UMD_SUPPORT=DIR OUT=FILE ...: another copy of main/support/umd (a reference build: tools/menu_render_ab.py)
#   -DMENU_PROF: the renderer's per-item and per-phase times at the run's end (menu.c, "PROF" lines)
# Run it on the MiSTer against an image on its share; "CORE render ... ms a frame" is the A9's cost.
set -euo pipefail
cd "$(dirname "$0")/../../.."
if [ -z "${IN_MAIN_DOCKER:-}" ]; then            # (the Main's image: main/docker_reexec.sh builds it on first use)
    exec docker run --rm -u "$(id -u):$(id -g)" -e IN_MAIN_DOCKER=1 -e HOME=/tmp -e UMD_SUPPORT -e OUT -v "$PWD":"$PWD" -w "$PWD" \
        "${MAIN_DOCKER_IMAGE:-mister-umd-main:gcc-arm-10.2}" bench/umd/menu/build_arm.sh "$@"
fi
LIB=main/.build/Main_MiSTer/lib/imlib2
[ -f "$LIB/libpng16.so" ] || { echo "build_arm: $LIB missing -- run main/build_main.sh once"; exit 1; }
S=${UMD_SUPPORT:-main/support/umd}
OUT=${OUT:-.sim/menu-arm/menu_host_check}
mkdir -p "$(dirname "$OUT")"
arm-none-linux-gnueabihf-gcc -std=gnu99 -O3 "$@" -DBENCH_NO_JPEG -D_FILE_OFFSET_BITS=64 -D_POSIX_C_SOURCE=200809L \
    -I$S/menu -I$S -Imain/support/umd/libpng -Imain/.build/Main_MiSTer/lib/miniz -o "$OUT" \
    bench/umd/menu/menu_host_check.c bench/umd/menu/img_decode.c \
    $S/menu/rco.c $S/menu/vsmx.c $S/menu/menu.c $S/menu/vag.c $S/menu/umd_iso.c $S/menu/umd_playlist.c \
    $S/umd_menu_host.c $S/umd_menu_logic.c $S/umd_menu_run.c $S/umd_panel.c $S/umd_panel_art.c $S/umd_disc_screen.c main/.build/Main_MiSTer/lib/miniz/miniz.c \
    -L$LIB -lpng16 -lz -lm -Wl,--allow-shlib-undefined
echo "build_arm: $OUT ($*)"
