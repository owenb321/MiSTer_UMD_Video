# Resume per disc (roadmap P8)

**Status:** ✅ **MERGED (PR fj#61), HW-CONFIRMED** (2026-10-07): RS1-RS3 (the resume)
and RS4 (R5, the disc screen) built, benched and ✅ HW-CONFIRMED on .236. Decisions R1-R6 (R6: saved at
the stop-type actions only) and R5a-R5f with the maintainer, 2026-10-06 / 07. The UMD Main only: **no
fabric change** (R5a revised); `CORE_VERSION` stays `main`'s (`dev-naveng`: the maintainer, 2026-10-07),
so the merge keeps the pinned SEED -- this branch changes no netlist.

**fj#88 / fj#89 + R7 (2026-10-10, the UMD Main only) ✅ MERGED (PR fj#91), ✅ HW-CONFIRMED (.236, the maintainer's own test included):** the quit keeps the point
before the script's `onExit`, a used point lasts until its landing, the disc screen's Play line follows the
point that is kept, and **Stop on the disc screen forgets the disc's place** (R7). See §7.

## 1. What the user gets

Reopening a disc continues where it stopped: after another disc, another core, or the MiSTer being
switched off. No prompt, no setting. Playing a title to its end forgets the point, so the next load
starts fresh. With a stock Main there is no resume (the stock-Main rule: a feature beyond playback
may live on the HPS; nothing changes for that user).

| | |
|---|---|
| **R1** persistence | **Survives a power cycle**: one small file per disc on the SD card (strictly under Main's root, `getRootDir()`: `/media/usbN` when Main's storage is USB). Keyed by the disc id, so a disc played from a PSP over USB (`psp_disc.md`) resumes like its image. (The PSP keeps resume points in RAM and loses them at reboot -- `p9.md` M1d -- a hardware artifact we do not copy.) |
| **R2** a disc played without its menus (Disc Menus Off, or a disc with none) | **Resumes automatically** at the mount, as the PSP does. Starting over is Go To or Prev Chapter. |
| **R3** a setting | **None: always on.** No OSD option, no CONF_STR change. |
| **R4** forgetting | **At the title's end** (TITLE_END). Stop, another disc, another core, power-off keep it. On a menu disc the disc's own rules also apply, as today (a script's `stop()` or a new content play clear the player's point: `p9.md` rule 7, M4 item 2). |
| **R7** forgetting by hand (the user, 2026-10-10) | **Stop on the disc screen** forgets the disc's place: the file deleted whole (a menu disc's user data too), "> Play", and Play starts the disc from the beginning. The double stop of DVD players. Before it, nothing but a title's end (or the disc's own rules) forgot a place. §7. |
| **R6** when it is saved (2026-10-06, RS1) | **At the stop-type actions only, no periodic save.** The maintainer: "can't we just write a save point whenever one of the stop-related actions is taken?" A power cut has no hook, so the point a pulled plug leaves is the last such save, not the place playing. Replaces the first design's 30 s refresh (below, "Rejected"). |

Out of scope: **bare `.MPS` files** (no disc id, and no seek: `bare_streams.md` §3).

## 2. What exists (survey 2026-10-06)

- **The seek.** HOST_WR's PLAYLIST command (code 13, `player_ctl` `C_PLAYL`, the reader's NAV_PLAY):
  (playlist, item, 48-bit PTS), exact, accepted in any state including stopped. Its landing is
  watched by `umd_menu_logic.c` (a seek seen, then `playlist == land_pl && shown && !seeking && state
  1|2` posts `UMD_ME_LANDED`); BAD (busy) is retried every 40 ms up to 25 times, then GAVE_UP.
  Streams after it with AUDIO_SET / SUB_SET (as `umd_menu_host.c`'s `e_resume`).
- **The position.** Every HOST_RD reaches `umd_mr_feed` (`umd_menu_run.c`) whether the engine runs or
  not: state, `shown`, PLAYLIST, KEY (the shown picture's item), PTS (33-bit), the audio / subtitle
  tracks, the event FIFO (TITLE_END = 3).
- **The menu engine's resume** (`umd_menu_host.c` `keep_resume` / `e_resume`, the kept text
  `"R <have> <pl> <item> <pts> <video> <audio> <aflag> <sub> <sflag>\n"` + the script's
  `setUserData`): stored in **`/tmp/umd_menu/<id>.txt`** at an interruption and at every quit, loaded
  at the start (a continue -- `onContinuePlay` -- when user data follows the R line). Lost at
  power-off by design (`p9.md` 596-600).
- **The disc id**: `umd_iso_disc_id()` reads `UMD_DATA.BIN` -> `"<title>_<hex id>"` (25 of 25 census
  ids unique). Read in `umd_mr_mount` only AFTER the Disc Menus Off return: that path had none (RS1
  moved the read before it).
- **The hooks**: a mount / eject (`umd_menu_mounted`, OSD Load Video included), a core change
  (`umd_menu_shutdown`, first in `fpga_load_rbf`), the core gone (`umd_menu_away`). None at power-off.

## 3. Design

**Storage.** `/media/fat/config/umd/<disc id>.txt` (stock Main's `config/` convention), the same
text format the engine already writes. Written to `<file>.tmp`, `fsync`ed, renamed (FAT renames
atomically enough for a power cut between: the old file or the new, never half). An empty text deletes
the file. **The engine's kept text moves here too** (`KEPT_DIR`): a menu disc's continue survives a
power-off as well. Old `/tmp/umd_menu/` files are not migrated (they were lost at every power-off).

**When the point is written (R6)** -- one small file, only at a stop-type action:
- at every quit hook: a mount, an eject, a core change, the core gone (the OSD's Reset);
- **with no engine** (RS2): also at **Stop** and **Pause** (the state words 3 / 2), so "pause, then
  switch off" keeps the place;
- with the engine: as the engine stores today -- each quit (P9-6's Circle included: the PSP's Stop on
  a menu disc), a menu's interruption (`keep_resume`), a script's `setUserData`;
- at TITLE_END: deleted (R4). **Then nothing is saved until a new landing** (state 1 / 2, `shown`, not
  seeking, after a seek, a PLAYLIST or a mount): R5c's STOP follows TITLE_END, and a Stop save
  there would write the title's last place back -- the next launch would resume at the credits.
  The tracker's sample is cleared at TITLE_END; a Stop / Pause / quit with no sample saves nothing.

A power cut runs nothing, so it leaves the last save: a cut during playback loses the place played since.

**Two owners, never both.**
- **The engine runs** (Disc Menus On and a startup RCO): it owns the file as today, now on the card.
  After a power cut the next launch acts on the last text stored: a quit's (onExit ran) is the
  relaunch (`onContinuePlay`, the film at its point: `akira-host-quit-powercut`); with none since the
  disc's start, the disc starts fresh, as the PSP after a reboot (`akira-host-powercut`).
- **No engine** (Disc Menus Off, or no menus): a **generic tracker** in `umd_menu_run.c` samples
  `{playlist, key item, pts, audio, sub on / track}` from every read in state 1 / 2 with `shown` and
  not seeking (the engine's `keep_resume` rule), and writes the R line at the saves above. At the
  mount, once the core's own start has landed (`state 1|2 && shown && !seeking`, the engine's
  `umd_mh_ready`), it pushes PLAYLIST(pl, item, pts), then AUDIO_SET and (with subtitles on) SUB_SET.
  A refusal (GAVE_UP, or a playlist the disc does not have) deletes the file and plays on.
- The disc id is read **before** the Disc Menus Off return (it costs one small file read).

**Rejected: a 30 s refresh while playing** (built and benched in RS1, then removed, 2026-10-06). It
was the only defence against a power cut. On a menu disc it could not work: after a cut the disc's own
chain runs, and Akira's Play item decides resume-or-start from data its script writes only in
`onExit`, so it started the film from the beginning with the point on the card; and the restarted
chain's logos, themselves a content play, replaced the film's point 30 s later. A continue
(`onContinuePlay`) with no user data was tried too: Akira opened its menu, and Play still started
over. For a disc without menus the refresh would work, but the maintainer chose one rule for both (R6).

**Known limitations (planned):**
- **The first moment of the title shows** before the resume seek lands: the core starts the longest
  playlist at a mount by itself (the reader's walk), and the seek follows within ~1 s. To measure on
  the rig; a mute / pause around it is possible later (PAUSE before PLAYLIST) if it is ugly.
- A disc whose `UMD_DATA.BIN` is missing or empty has no id: no resume (logged).
- Two copies of one disc (the same id) share one point.
- **A card that refuses the write** (full, read-only) keeps no point. Each refusal is traced
  ("NOT written to the card"), counted (`umd_menu_stats` `kept_fail`) and printed on Main's console;
  the next store retries even when its text repeats. Nothing on screen says so.
- **A power cut during playback loses the place played since the last save** (R6), **and a save is
  not durable for its first few seconds** (the exFAT card, §4b): switching off within ~2 s of a Pause
  or Stop keeps the save before it. Every save is
  `fsync`ed, ~100 bytes. A store equal to what the card holds is skipped (`umd_menu_run.c`
  `kept_put`): a quit on a menu disc wrote the same text up to three times (the script's
  `setUserData` in `onExit`, the resume point, the quit's own store), now at most twice.

## 4. Verification

- **Bench** (`bench/umd/run_menu.sh [mhost]`, `menu/menu_host_check.c` against its core model): the
  generic tracker -- a point taken only in play / pause with a picture; written at each quit hook, at
  Stop and at Pause; deleted at TITLE_END; at a mount with a file, PLAYLIST then the streams after the
  core's landing; GAVE_UP deletes. RED arms for each rule. RS1's, built: `--powercut T` (nothing runs,
  the image launched again), `CARD store` lines, `akira-host-powercut` / `akira-host-quit-powercut`,
  `fg-host-menus-off` reading the id, `akira-host-cardfull` (`--card-full`: every write refused);
  RED H53-H57 (H54: a differing store skipped as a repeat; the
  first H54, a quit storing nothing, is equivalent: every change of the kept text is stored when it
  happens, so the quit's own store only repeats the last).
- **Rig** (UMD Main deployed, any rig): Akira, Disc Menus Off -- play 2 min, mount another disc,
  remount Akira: it lands at the point, its audio track kept; **reboot the MiSTer**, launch it: the
  same; seek to the last minute and let it end: the next launch starts at the beginning. Family Guy,
  Disc Menus On -- quit from the film, reboot, relaunch: the relaunch (`onContinuePlay`) as without
  the reboot; `config/umd/` holds the disc's file. The first-moment glimpse measured (§3).
- Manual: a Resume section in `playback/` (what resumes, when it is forgotten, stock Main: none),
  the disc-menus page's note on power-off.

### 4b. On the rig (RS3, 2026-10-07, .236; `UMD_bare_20261005_1945.rbf` + the UMD Main from `9553414`)

| Check | Result |
|---|---|
| Disc Menus Off: the disc id at the mount | ✅ `HOST mount: disc Akira_8A020D2D8C48A972, Disc Menus Off` |
| Stop saves; the file on the card | ✅ `config/umd/Akira_8A020D2D8C48A972.txt`, the R line with the place. (The transport's Audio and Subtitle keys show the current setting at the first press and change it at the second: the first try saved audio 0 / subtitles off, correctly.) |
| Audio 2 (Japanese) + subtitles on, Stop, another disc mounted, Akira again | ✅ resumed: PLAYLIST sent 107 ms after the mount, landed 245 ms later, Japanese audio and English subtitles back on screen; Matrix kept its own point |
| A clean reboot (`sync`, `reboot`), then Akira | ✅ found, sent 150 ms after the mount, landed |
| A hard reset (`sysrq b`, no sync) ~9 s after a Pause save | ✅ the new point survived |
| **A hard reset ~2 s after a Pause save** | ⚠ **the save was lost** (a known limitation, below): `ls` showed the new file (03:57:25) before the reset; after it the card held the previous one (03:54:50). Reproduced twice (once with the gap under 1 s). Below. |
| Skip to the last chapter, FF to the end | ✅ `forgotten: the title ended`, the file deleted; Pause, Play and Stop over the ended title wrote nothing |
| Family Guy, Disc Menus On: an episode, Circle (P9-6 quit), the disc again | ✅ 86 bytes kept in `config/umd/_11DDC9B0F726EBBA.txt`; `onContinuePlay`, `resume() -> 0`, back in the episode (playlist 2) |

**Known limitation (the maintainer, 2026-10-07: "leave that as a limitation"): a save is not durable
for its first few seconds.** The card is exFAT mounted `sync,dirsync`
(MiSTer kernel 5.15.1); the store writes `.tmp`, `fsync`s it, renames it and `fsync`s the directory,
yet a SoC reset ~2 s later loses the rename (the old file stays), while ~9 s later it survives -- the
pattern of the kernel's periodic writeback (`dirty_writeback_centisecs` 500), as if the exFAT driver's
`fsync` left the directory entry dirty. A real power cut is no kinder than a reset (the card loses its
cache with its power). The likely fix is a filesystem-wide flush after the rename (`syncfs` on the
directory's fd, or `sync()`), or a write in place; **not tested**: the test needs hard resets of the
rig, which were stopped at the third. "Pause, then switch off" keeps the place only when a few
seconds pass between the two; the manual says so. To revisit if users report lost places.

## 5. Stages

- **RS1** 🔧 built 2026-10-06: the kept text on the SD card (`umd_menu.cpp`: `config/umd/<id>.txt`
  through Main's `getFullPath`, `fsync`ed, renamed, the directory `fsync`ed; the JPEG scratch file
  stays in `/tmp/umd_menu`), the disc id before the Disc Menus Off return (`umd_mr_mount`), the start
  traced as a continue or not (`umd_menu_host` `continued`), a store repeating the card's text
  skipped (`kept_put`); bench as §4. On the rig at RS3.
- **RS2** 🔧 built 2026-10-06: the tracker in `umd_menu_run.c` (`tr_arm` / `tr_rd` / `tr_events` / `tr_go`,
  the rules in `umd_menu_run.h` "THE TRACKER"). As built beyond §3:
  - **Who owns it:** Disc Menus Off and a disc with no startup RCO (none of the 84 library images:
    the path is benched through Disc Menus Off) arm it with the mount-time resume; an engine that
    refuses the disc at its start hands it over without one (sampled and saved, not resumed).
  - **The text** is the engine's: the R line alone, the streams as play()'s ids (audio 0xBD00 + n,
    subtitles 0xBD80 + n and their flag, video 0xE000). A later Disc Menus On launch reads it as the
    engine's resume point (a fresh start whose `resume()` finds it); the tracker's saves drop an
    engine's user data. A text whose R line holds no point is left alone.
  - **PLAYLIST.UMD is read before the Disc Menus Off return** too: a point is checked against it (a
    playlist or item past it is forgotten) and the PLAYLIST command carries the point's chapter.
  - **The streams** follow the PLAYLIST, as `e_resume`'s: AUDIO_SET when the point's track is not
    the one the mount picked, SUB_SET when its subtitles were on (S1: a mount turns them off).
  - **The order in a read:** its events before its sample, so a title's end forgets the point before
    any STOP in the same read could write it back.
  - **The bench's core model corrected:** at a title's end it went to STOP; `player_ctl` stays in PLAY
    on the last picture (`ended`, TITLE_END posted once). It now holds PLAY till a seek, and the core's
    mount re-picks the audio track and turns the subtitles off. The model's Audio key (SELECT) steps
    two tracks; `--sub T` turns the subtitles on; `--kept TEXT` puts a text on the card.
  - Bench: `akira-off-stop-powercut` (audio and subtitles kept), `-pause-powercut`, `-end`,
    `-badpoint`, `-relaunch`, `-reset`; RED H58-H64. Not benched: GAVE_UP's deletion (the logic's
    retry and give-up are `run_hps_host`'s / U6's), the engine-refused hand-over.
- **RS3** ✅ on the rig 2026-10-07 (§4b): every check passes; a save lost by a reset within ~2 s of it
  is a known limitation (the maintainer). The manual was written with RS1 / RS2.
- **RS4** R5, the disc screen: ✅ mockups approved 2026-10-07 (R5e, the card). 🔧 Built 2026-10-07, all
  in the UMD Main (R5a revised: no fabric):
  1. ✅ the page: `umd_disc_screen.c` (PIC1 bilinear into the fit's target, the card, the HUD font; the
     SFO's TITLE; the title shown; the Play line), pixel-exact against `tools/disc_screen_layout.py`
     rewritten to its integer arithmetic: `bench/umd/run_disc_screen.sh --red` -- [sfo] 84 SFOs,
     [title] 99, [hint], [lib] 84 library pages, [fit], [syn]; RED D1-D12.
  2. ✅ the owner (`umd_menu_run.c`, "THE DISC SCREEN" in its header): shown while the core is stopped,
     not seeking, a disc image open, no engine running and none armed -- Disc Menus Off, no menus, an
     engine that refused the disc, a menu disc after P9-6's quit (R5f); levels `ui` + `menu` (16:9, the
     CRT's fit, the HUD hidden); its own buffer (`ds_frame`: the engine's incremental renderer keeps
     `frame`), drawn whole when the fit or the Play line changes, flipped as the engine's pages; the art
     read and decoded at the first showing (`decode_image`, a side past 4096 refused and traced); the
     panel's page over it copies it whole (a full-screen flip), and its close redraws the page.
  3. ✅ R5c: the tracker's TITLE_END pushes STOP (`ds_ended`: "> Play"); the state leaving stop with
     `ds_ended` sends a PLAYLIST to the title's start (a Stop's Play would release the freeze at the end).
     **R5f, as built:** after a menu disc's P9-6 quit, Play on the disc screen re-arms the engine's start
     with the kept text (`ds_relaunch`): `onContinuePlay`, as choosing the disc on the PSP's XMB.
  4. ✅ the bench: `akira-off-discscreen`, `-end-discscreen`, `akira-quit-discscreen`,
     `akira-off-discscreen-crt`, `fg-host-levels`' never (the engine's own STOP); RED H65-H72.
     (menu_host_check's M4d check skips the disc screen's frames: the engine is gone.)
  5. ✅ the manual (`disc-menus.md` "The disc screen", `controls.md`, `loading.md`); ✅ the rig (below).

  **On the rig (2026-10-07, .236 at 480i on a CRT: the Letterbox fit; `UMD_bare_20261005_1945.rbf` + this
  branch's UMD Main):** Akira, Disc Menus Off -- Stop: the page up, **its raster pixel-exact against the
  golden** (0 of 345,600 pixels differ, decode to composite), "> Resume" at the stopped place; Play: hidden,
  the film back; the panel over it (a copy of the page under it) and its close (the page redrawn); the
  title's end: "> Play", and Play the title from its start (Chapter 1, 0:00:04). Family Guy, Disc Menus On --
  Circle (P9-6): the disc screen; Play (the OSD closed first: P9-6 opens the file browser, which holds the
  keyboard) relaunched the menus, `onContinuePlay` -> `resume()` -> the episode. Ghost in the Shell 2.0:
  the file name for its Japanese title.
  **Found by the rig: the art's colour chunks** (`umd_ds_png_plain`, `umd_disc_screen.h`): the first build's
  page was 2-12 levels brighter than the golden in the art alone (Akira's `gAMA` 55531, libpng's simplified
  API converting it to sRGB; the bench decoded both sides with PIL, so it could not see it). 121 of the
  library's 167 PIC1 / ICON0 carry gAMA / cHRM / iCCP; the chunks are now dropped before the decode, the
  stored values shown as the PSP's XMB shows them, [png] in `run_disc_screen.sh` (RED D13-D14).

## 6. R5, the disc screen (the maintainer, 2026-10-06; R5a-R5d taken the same day)

**The requirement.** When a disc is stopped, show its own art instead of the idle wave, as the PSP's
XMB shows a UMD: the background picture and the thumbnail.

**What the disc carries** (census 2026-10-06, `UMD_VIDEO/` of the 84 library images):

| File | Present | Form | The XMB's use |
|---|---|---|---|
| `PIC1.PNG` | 84 of 84 | 480 x 272 (one 480 x 270), 8-bit RGB on 68, RGBA on 15 -- **every one opaque but Pirates of the Caribbean's** (alpha < 255 on 0.7 % of its pixels; measured 2026-10-07, the first census counted the colour type only) | the full-screen background |
| `ICON0.PNG` | 83 of 84 (Now That's What I Call Music 2006 has none) | 144 x 80, RGB on 78, RGBA on 5 (opaque) | the thumbnail in the Video column |
| `PARAM.SFO` `TITLE` | all | text (`umd_sfo.py`) | the title beside the thumbnail |
| `ICON1.PMF` | 63 | 144 x 80 PSMF, the animated thumbnail | played in the thumbnail's place when focused |
| `SND0.AT3` | 61 | ATRAC3plus | played with it |
| `PIC0.PNG` | 2 (Terminator 2) | 310 x 180 RGBA | an information overlay |

The PSP composites `PIC1` over its own wave; with the library's art opaque, the wave shows through
none of it (Pirates' 0.7 % aside). Titles: UTF-8 up to 128 bytes; the library's run to 55 characters,
two carry Japanese (Ghost in the Shell 2.0, Tom & Jerry), one a (TM) sign.

**What the core does today** (survey 2026-10-06):
- **Stop** (`player_ctl` ST_STOP): the wave. `emu`'s `wave_vis = ~media_seen | (pc_idle & ~host_menu)`;
  the picture is held frozen behind it, and Play releases the freeze (`transport.md` §9).
- **A title's end**: the last picture stays up frozen (`disp_ctl` `ended`). The state stays PLAY, and
  `player_ctl` posts TITLE_END once.
- **No disc**: the wave. `show_pic = media_seen & (~pc_idle | host_ui | host_uis)` means no plane can
  be shown without a mount.
- **A host plane over a stop** already works under `ui` (the disc menus' "a menu over a stopped
  player", `p9.md`) or `ui_sub` (the panel), **over black**: `pic_on = pic_de & ~pc_idle`.
  `panel.md` §7: a plane over the wave needs `xmb_wave`'s LAT 4 aligned with the overlay's LAT 7.
- The UMD Main can already read the files (`umd_iso_read_file`) and decode them (`dec_png`, libpng's
  simplified API to RGBA8). It draws 720 x 480 premultiplied ARGB pages into planes 0 / 1
  (`umd_mr_render_*`) and the panel into 2 / 3.

**Which side of the line.** Beyond playback, so it is **a UMD Main feature** (the stock-Main rule). A
stock-Main user keeps the wave at a stop.

**The owner.** The menu runner exists only on a mount with menus, and quits at state 0. The disc
screen needs the same no-engine owner that RS2's generic tracker adds in `umd_menu_run.c`, so they
are one owner: it tracks the point AND draws the disc screen. **When the menu engine runs, it owns
the screen** (the disc's own stop rules, `p9.md`), and the disc screen never contends for the plane.

**The page** (to be mocked, as P6d's C0 was): `PIC1` scaled to fill the 720 x 480 page at the
picture aspect, `ICON0` and the title placed as the XMB places them. The page is drawn once per stop,
into plane 0 / 1, shown under `ui`. The panel (planes 2 / 3) still opens over it.

**Decisions** (the maintainer, 2026-10-06):

| | |
|---|---|
| **R5a** behind the art | **REVISED 2026-10-07: black** (the UMD Main only, no `.rbf`; the CRT's letterbox bands black, as under the disc menus). The first answer below rested on a wrong census (15 transparent backgrounds: every one is opaque but Pirates', 0.7 %); the wave would show only in the 4:3 CRT's bands. First answer: **The wave, as on the PSP.** The wave is delayed to the overlay's latency (LAT 4 -> 7) and fed under the plane while stopped with the disc screen up: a small `emu` change and a fit. The RGBA backgrounds show the wave through them. (Rejected: black, HPS only, no `.rbf`.) |
| **R5b** at the mount | **Play at once, as today.** A saved point lands ~1 s after the core's own start (§3's glimpse stays); an MGL launch still plays the feature at once. (Rejected: the disc screen first.) |
| **R5c** at a title's end | **A STOP and the disc screen**, as the XMB returns to the disc: the host sends STOP on TITLE_END, discs without the menu engine only. R4 forgets the point at the same event. (Rejected: the last picture frozen.) This changes what P6b7's end-of-title rig gate shows. |
| **R5d** `ICON1.PMF` / `SND0.AT3` | **Out of scope: static art only** (`PIC1`, `ICON0`, the title). A later stage if wanted. |
| **R5e** the layout (2026-10-07) | **B, the card** (the mockups, below): the mockups APPROVED. |
| **R5f** on a menu disc (2026-10-07) | **Yes, after the quit**: Stop (Circle) quits a menu disc and opens the OSD over the Stop screen -- the PSP's way back to its XMB -- so once the engine has quit, the disc screen takes the plane there too. |

**The mockups (RS4's first step, 2026-10-07)**: `tools/disc_screen_layout.py --mockups` -> `.sim/
disc_screen_mockups/` (the discs' art: never committed), over a rig screenshot of the core's Stop
screen (October's wave, the transport HUD's stop mark put back on top). Six sample discs, two variants:
- **A, "XMB"**: `PIC1` scaled to the raster (16:9: x 1.5, y 480 / 272), `ICON0` at the PSP's
  proportions (216 x 141) left of centre, the title and a Play line beside it, no box. **Fails on
  light art**: white type over Akira's white background is unreadable; marginal over Pirates.
- **B, "card"**: `PIC1` the same; a box in the HUD's tint (`panel_layout.BOX_RGBA`, the panel's K16)
  across the lower third, above the HUD's stop mark (lines 386-414): `ICON0` at 2/3 (144 x 94), the
  title (two lines, word-wrapped, an ellipsis past them), the Play line ("> Resume 0:02:04" after a
  Stop, "> Play" after the title's end). Reads on every sample.
- A title the HUD font cannot draw (outside ASCII after NFKC) shows the image's file name instead
  (Ghost in the Shell 2.0 (2008)).
- The 4:3 CRT: the page letterboxed into 720 x 360 at line 60, as the menus (analog.md S7) -- the
  only place R5a's wave would show on the library.

**Known limitations (planned):**
- **A subtitle showing at the stop does not come back at Play** until the next unit: either edge of
  `ui` is a subtitle flush (`hps_host.md` §3.4 "As built"), and Play releases the freeze rather than
  re-reading. The panel's `ui_sub` path keeps the subtitles; drawing the disc screen there instead is
  the alternative if this matters on the rig.
- Now That's What I Call Music 2006 has no `ICON0`: the page shows `PIC1` and the title only.
- No disc means no page: the wave, as today.
- **After P9-6's quit the file browser opens over the disc screen** and holds the keyboard: one OSD press
  closes it, then Play relaunches the disc (measured on the rig from a clean quit, 2026-10-07).
- A refused disc stays in PLAY (`player_ctl` changes no state on a refusal): "This disc cannot be played."
  shows as before; a Stop afterwards brings the disc screen (its `menu` level hides the transport HUD).
- The panel over the disc screen flips a full-screen page (a copy of the disc screen under it) at each of
  its changes -- a full uncached store each (B2's measure: milliseconds), a few times an opening.
- **Not seen on hardware:** the raster's own fit (0, a 480p / HDMI output -- .236 runs a CRT at 480i, so
  only Letterbox was seen), Crop (2), a disc without ICON0. All three are bench-exact (`run_disc_screen.sh`
  [lib] / [fit] / [syn]).

## 7. fj#88 / fj#89 and R7: the point kept, the Play line, forgetting (2026-10-10)

**Found** by the maintainer on .236 (the UMD Main of `fix/menu-alpha`; both causes predate it).
- **fj#88:** The Animatrix loaded to black. Its file: `R 0 2 0 38357229 -1 48384 -1 48512 1` (no point, the
  film's place still in the fields) with user data saying "in the film". Its `onContinuePlay` calls
  `resume()` and ignores the result (JA100000, disassembled with `tools/rco_census.py`'s `disasm`): no page,
  no play, the core stopped under a black menu.
- **fj#89 (1):** a P9-6 quit lost Aliens' film point: `umd_mh_quit` ran `menu_exit` (the script's `onExit`)
  first, Aliens' `onExit` calls `stop(-1, false)`, `e_stop` cleared `playing`, and `keep_resume` found
  nothing. **The Animatrix's `onExit` calls `stop()` too**: one way fj#88's file was made (the point used by
  `e_resume`, no new one at the next quit, the script's data saved "in the film").
- **The OSD's Reset** (the issue's own suspicion, the 2026-10-08 Resets; found again in review): its quit
  runs after the first idle read (state 0), which `keep_resume` read as "nothing playing" -- the point lost
  whatever the order of `onExit`. The bench reproduced the rig's Aliens file exactly (`R 0 0 0 0 ...` beside
  the onExit's data).
- **fj#89 (2):** the disc screen's "> Resume X:XX:XX" was built from the core's current place (a warning clip,
  a menu loop), not from the point kept: it promised a resume Play did not give.

**The rules, as built** (`umd_menu_host.c`, `umd_menu_run.c`):
1. **The quit keeps the point BEFORE the script's `onExit`** (`umd_mh_quit`: `keep_resume`, then
   `menu_exit`). The quit is the system's interruption of the film; Family Guy's `onExit` does not stop,
   which is why RS3's checks passed. A script's `stop()` outside a quit still keeps no point (M4 rule 2).
   Consequence: a quit during a disc's opening clips (themselves content plays) now keeps a point on Aliens
   as it already did on Akira; the script decides what to do with it (Aliens checks the point is the feature
   before `resume()`).
2. **A used point lasts until its landing** (`resume_used`): `resume()` no longer drops the point at the ask.
   It is written `R 1` until the resumed play's `UMD_ME_LANDED` (the latest play generation), then dropped
   **in memory only**: a store there would write `R 0` beside the last `onExit`'s "in the film" until the next
   quit -- the same disagreement after a power cut. The card keeps the last save (R6); the next store (a quit,
   `setUserData`) writes what holds then. A quit before the landing keeps it (the onExit's `stop()` included); a menu's `play()` before
   the landing keeps it usable; a content `play()` or the script's `stop()` before it drops it (as they would
   have after the landing); a GAVE_UP keeps it. So the R line and the script's data cannot disagree.
   (Decided 2026-10-10: at the landing, not "until replaced or ended" -- that would leave an earlier place
   after a script's `stop()`, against M4 rule 2.)
3. **The Play line says what Play resumes.** After a menu disc's quit (R5f) it is the point the quit kept
   (`ds_pt_*`, copied before the engine is freed): "> Resume" at its place, "> Play" with none. With no
   engine it stays the core's stopped picture -- Play releases the freeze exactly there -- and "> Play"
   after the end or a forget.
4. **The OSD's Reset keeps the point** (`rd_play`): the host keeps the last read in play / pause (a stop
   clears it, the idle read leaves it), and a quit seen on an idle read takes the place from it.
5. **R7, Stop on the disc screen forgets.** The runner adds Stop to the grab while the page is up (the core
   ignores a Stop in STOP, `transport.md` D5, so nothing is taken from it; the keyboard's Stop too). The press
   (or the panel's Stop item there) deletes the disc's kept text whole (`ds_forget`): a menu disc's user data
   with it, so its relaunch is a fresh start (`onAutoPlay`) and cannot meet a script that expects a point.
   With no engine the tracker's sample is dropped (no sample until a seek) and Play sends the PLAYLIST to the
   title's start (R5c's path, `ds_ended` = 2).

**Still open:** a script that saves its data DURING the film (`setUserData` outside `onExit`) after its
resumed play landed stores `R 0` (the point used up) beside "in the film"; a power cut (no hook) then leaves
that pair. Any quit rewrites both halves together. Aliens and The Animatrix save in `onExit` only (their
disassembly); the rest of the library is not surveyed for it.

**No recovery for files that already disagree** (decided 2026-10-10: no users yet). The rig's Animatrix file
is deleted by hand. A file in that state still loads to black: the fix prevents new ones.

**Bench** (`tools/menu_gate.py --host`, `bench/umd/run_menu.sh`): `aliens-quit-resume`,
`aliens-quit-menu-play`, `animatrix-relaunch-resume` (fj#88 reproduced on `main`: 53 bytes kept, no point),
`animatrix-relaunch-before-landing` (seeks 600 ms; the second relaunch inside the resume's seek),
`aliens-reset-resume` (the OSD's Reset in the film, then the image again),
`akira-off-discscreen-forget`, `akira-quit-discscreen-forget`; `akira-host-cardfull`'s first refused store is
now the R line alone (38 bytes, before `onExit`'s data) and `akira-off-discscreen`'s grab 0x040. RED H90-H98.
Unarmed: a content play / a script's `stop()` before the resumed play lands (no library scenario asks either).

**Known limitations:**
- A quit during a menu disc's opening clips keeps a point in them (rule 1), as the PSP does (`p9.md`'s
  2026-10-02 tests: "quit during the logo, relaunch: the logo resumes"); the disc screen then says "> Resume"
  with the clip's time, and Play does what the disc's script does with it (Aliens opens its menu).
- R7 forgets the whole kept text of a menu disc: the settings its script keeps there (an audio choice) go too,
  as a disc never played.

**On the rig (2026-10-10, .236; `UMD_zoom_20261009_2050.rbf` + this branch's UMD Main; the rig restored after):**

| Check | Result |
|---|---|
| Aliens, menus on: the film, Stop (P9-6) | ✅ `HOST resume point` before `onExit`'s `stop(-1, false)`, the file `R 1 0 0 4012664 ...`, the disc screen "> Resume 0:00:43" |
| ... Play on the disc screen (the OSD closed first) | ✅ `getResumeInfo() -> playlist 1`, `resume() -> 0`, used up at the landing (742 ms later), the film's opening titles on screen |
| A fresh load of Aliens | ✅ the continue resumed the film at 1:17 from the card |
| Aliens: Stop (P9-6), then Stop on the disc screen | ✅ "forgotten", the file deleted, "> Play"; Play: a fresh start (`onAutoPlay`, the opening clips) |
| The Animatrix (fj#88): a load, then Akira mounted over it in the same session (the mount quit) | ✅ the continue resumed playlist 7; the quit kept `R 1 6 0 155375130 ...` although its `onExit` called `stop()` |
| The OSD's Reset in a film (rule 4; 2026-10-11, the UMD Main of `ffce397`, the Reset pulsed through `/tmp/umd_ctl` `osd [0]`) | ✅ Aliens' film at 0:37: `HOST resume point` then `onExit`'s `stop(-1, false)`, the file `R 1 0 0 3393299 ...`; loaded again, `resume() -> 0` there |
| Akira, Disc Menus Off: Stop, Stop, Play | ✅ "> Resume 0:00:25", then "forgotten", "> Play"; Play: playlist 5 from its start |

One harness round lost its keys: an OSD press sent while P9-6's file browser was still opening left the OSD in a
state that held the keyboard until the next core load (screenshots cannot show the OSD). Done again with the
browser open first (as RS3's note), every step passed. A harness-timing matter, not the Main's.
