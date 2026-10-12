#!/usr/bin/env python3
"""apply_integration.py -- the UMD Main's edits to a stock Main_MiSTer tree (main/README.md):
user_io.cpp's two, and (P9) the Makefile's C sources.

MiSTer_DVD's patcher is 821 lines because its Main plays physical discs; this one only
adds a poll-loop tick, so it makes exactly two edits to user_io.cpp and nothing else (the
Makefile globs support/*/*.cpp; is_umd() lives in the overlay, from Main's public
user_io_get_core_name()). Each edit is idempotent and anchor-based: an anchor a stock
bump moved fails LOUDLY, naming the step, instead of silently mis-patching. The anchors
are the ones MiSTer_DVD's build verified at MAIN_MISTER_REF (build_main.sh).

    apply_integration.py STOCK_MAIN_DIR
"""
import os
import sys

if len(sys.argv) != 2:
    sys.exit(__doc__)
path = os.path.join(sys.argv[1], "user_io.cpp")
u = open(path, encoding="utf-8", errors="surrogateescape").read()


def insert_after(text, anchor, block, step, marker):
    if marker in text:
        print("[integration] step %d: already applied" % step)
        return text
    if text.count(anchor) != 1:
        sys.exit("[integration] STEP %d FAILED: anchor %r found %d times in user_io.cpp -- a stock "
                 "Main bump moved it; re-anchor this step" % (step, anchor, text.count(anchor)))
    i = text.index(anchor) + len(anchor)
    eol = text.index("\n", i)
    print("[integration] step %d: applied" % step)
    return text[:eol + 1] + block + text[eol + 1:]


# 1. the overlay's header, after a stock include
u = insert_after(u, '#include "ide_cdrom.h"', '#include "support/umd/umd_ctl.h"\n', 1, "support/umd/umd_ctl.h")
# 2. the tick, first in user_io_poll() (it returns at once unless the UMD core runs and
#    the rig is armed; see umd_ctl.cpp)
u = insert_after(u, "\tadd_frame_callback(screenshot_cb);",
                 "\tumd_ctl_tick();    // umd:hil -- telemetry + control FIFO, armed by /media/fat/umd_hil\n",
                 2, "umd_ctl_tick();")
# 4. P9: the menus learn of a mount -- after the core is told (UIO_SET_SDSTAT), the image open or
#    ejected (umd_menu_mounted ignores another core and another slot)
u = insert_after(u, '#include "support/umd/umd_ctl.h"', '#include "support/umd/umd_menu.h"\n', 4, "support/umd/umd_menu.h")
u = insert_after(u, "\tspi_uio_cmd8(UIO_SET_SDSTAT, (1 << index) | (writable ? 0 : 0x80));",
                 "\tumd_menu_mounted(index, ret, name);    // umd:p9 -- the disc menus: a mount quits the disc up, arms the new\n",
                 4, "umd_menu_mounted(index")
open(path, "w", encoding="utf-8", errors="surrogateescape").write(u)

# 5. P9: a core load (fpga_load_rbf re-execs Main) quits the disc first, its kept text written
fp = os.path.join(sys.argv[1], "fpga_io.cpp")
f = open(fp, encoding="utf-8", errors="surrogateescape").read()
f = insert_after(f, '#include "fpga_io.h"', '#include "support/umd/umd_menu.h"\n', 5, "support/umd/umd_menu.h")
f = insert_after(f, "int fpga_load_rbf(const char *name, const char *cfg, const char *xml)\n{",
                 "\tumd_menu_shutdown();    // umd:p9 -- the disc menus quit, their kept text written, before the reload\n",
                 5, "umd_menu_shutdown();")
open(fp, "w", encoding="utf-8", errors="surrogateescape").write(f)

# 3. the Makefile compiles support/*/*.cpp only: the overlay's C sources -- the menu engine
#    (support/umd/menu/, P9) and the menu host and logic (support/umd/*.c) -- join C_SRC
mk_path = os.path.join(sys.argv[1], "Makefile")
mk = open(mk_path, encoding="utf-8").read()
mk_anchor = "C_SRC =   $(wildcard *.c) \\\n"
if "./support/umd/menu/*.c" in mk:
    print("[integration] step 3: already applied")
elif mk.count(mk_anchor) != 1:
    sys.exit("[integration] STEP 3 FAILED: anchor %r found %d times in Makefile -- a stock Main bump "
             "moved it; re-anchor this step" % (mk_anchor, mk.count(mk_anchor)))
else:
    mk = mk.replace(mk_anchor, mk_anchor + "          $(wildcard ./support/umd/*.c) \\\n"
                    "          $(wildcard ./support/umd/menu/*.c) \\\n")
    open(mk_path, "w", encoding="utf-8").write(mk)
    print("[integration] step 3: applied")
