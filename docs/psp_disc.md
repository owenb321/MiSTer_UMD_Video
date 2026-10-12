# Physical UMDs through a PSP ("USB Device: UMD")

**Status:** ✅ **MERGED (PR fj#84), ✅ HW-CONFIRMED** (2026-10-10): benched (`bench/umd/run_psp_scan.sh
--red`: 80 checks, 17 mutations each caught by its own arm), every rig check passed on .236 (§6) with the
maintainer's hands on the PSP, and the maintainer's own test (the manual's MGL under the UMD Main and the
stock Main) passed. The UMD Main only (a stock
Main: an MGL the user writes, from the manual): **no fabric change**, `CORE_VERSION` stays `main`'s (the
precedent: `resume.md`, `496f462`), so the merge keeps the pinned SEED -- no fit.

## 1. What the user gets

A PSP with custom firmware (ARK-5 measured) and **Settings > Custom Firmware Settings > USB
Device = UMD** shows up over USB as a read-only disk holding one file, `UMD9660.ISO`: an image of
the disc in its drive. Plug the PSP into the MiSTer, enter USB mode, open the UMD core: the disc plays.

- **With the UMD Main** (`hps_host.md` §1): found on `/media/usb0`..`usb7` and mounted by itself
  (no OSD pick), dropped when the PSP leaves USB mode; a disc changed inside USB mode asks for
  USB mode to be re-entered (one rule, §3). Menus, resume, the disc screen: as for any image
  (they key on the disc id, not the path).
- **With a stock Main**: an MGL with the absolute path `/media/usb0/UMD9660.ISO`, which the manual
  shows how to write (`getting-started/psp-disc.md`). **Not shipped in the release zip** (the
  maintainer, 2026-10-10). Stock Main's file browser cannot reach it: its root is `/media/fat`
  and `..` is hidden there (`file_io.cpp`'s scan), and `findPrefixDir` only looks for a
  `games/UMD` folder on a USB disk, which the PSP's disk has not.

Decided by the maintainer (2026-10-09): **auto-mount in the UMD Main + an MGL for stock Main**
(over an OSD entry, or MGLs alone); 2026-10-10: the MGL documented in the manual, not packaged.

## 2. Measured (2026-10-09/10, .236, ARK-5, step 0 of the plan)

**Where it comes from** (ARK-5's source, `PSP-Arkfive/ARK-5` at `a9b7454`): XMBControl's
`xmbpatch.c` puts **USB Device** (Memory Stick, Flash 0-3, **UMD**, Internal Storage on a Go) and
**USB Read-Only** (default `2` = Auto: read-only for any device but the Memory Stick,
`SystemControl/src/sctrl_se.c`) under the XMB's *Custom Firmware Settings*. VSHControl's
`usbdevice.c` hooks `sceUsbStart("USBStor_Driver")` and calls PRO CFW's prebuilt `usbdevice.prx`
(`pspUsbDeviceSetDevice(device - 1, readonly, 0)`), which presents the device as a FAT volume; for
the UMD that is one file, `UMD9660.ISO`, laid over the disc's sectors. The FAT is built when USB
starts, which is why an in-USB-mode swap keeps the old size (below). With USB Read-Only Off the
volume mounts rw: Main would then open the image `O_RDWR | O_SYNC` (it never writes it: `sd_wr`
is tied off in `emu.sv`); the manual says to leave it on Auto.

**The device.** `054c:01c8` "Sony PSP Type A", usb-storage, a **whole-disk vfat** (no partition
table) of 3,995,648 512-byte sectors whatever the disc, mounted `ro` by MiSTer's automount at the
first free `/media/usbN`. The file's mode is `r-x`, so Main's `FileCanWrite` is false and the
image opens `O_RDONLY`, buffered (the kernel's readahead works for it).

**The image is an ordinary UMD Video ISO.** National Treasure: 1,573,552,128 bytes = the PVD's
768,336 sectors exactly; system id `UMD VIDEO`; root `UMD_DATA.BIN` (`National Treasure -
2|32598|0002|V`) and `UMD_VIDEO/`. Christmas with the Kranks: 1,617,428,480. (The library's
National Treasure rip is another pressing, 1,790,509,056: not comparable byte for byte.)

**Read rates** (`dd` / `pread` on the MiSTer):

| access | rate / latency |
|---|---|
| sequential, buffered, 2 KB or 64 KB reads | **1.3 MB/s** (~635 packs/s; the spec maximum, Level 3.0's 10 Mbit/s, needs ~610: `p2_chain.md`) |
| random 2 KB, O_DIRECT | ~237 kB/s |
| a seek + 128 KB readahead | 0.7-1.4 s (2.7 s cold) |
| LBA 16 / 27, page cache dropped | ~10 ms (13 ms mean, 70 ms max under playback): the PSP caches the disc's head |

**Playback through the existing build** (`UMD_zoom_20261009_2050.rbf`, the UMD Main of `828efb6`,
mounted by an MGL with the absolute path -- which is also the stock-Main route):

- National Treasure, Disc Menus Off: playing ~5 s after the launch; over 60 s 59.94 pictures/s,
  errors 0, starve / late 0, `av_err` 0.02 ms; **the reader ~80-100 packs/s while the demux sits
  blocked on a full audio ring 96-97 % of the time** -- the USB rate is not the limit.
- Chapter Next / Prev: `seek_lat` 0.62-1.89 s (the SD baseline press-to-picture is 570-1,450 ms,
  `transport.md` §6). FF: hops every ~0.5-0.9 s, 18 in 8 s; the landing after Select 0.13 s.
  Errors 0 throughout.
- Pause 60 s, resume: seamless (no spin-down stall seen), starve 0.
- A poll of LBA 16 every 2 s with its page dropped, during playback: no effect (starve 0, `av_err`
  unchanged).
- Disc Menus On: the disc id derived (`National_Treasure_-_2_32598`), the engine runs, the
  startup promo plays.

**Changing discs** (the maintainer's hands, me on `dmesg` and a held fd):

| action | what happens |
|---|---|
| **leave USB mode** (or, by the same path, unplug) | USB disconnect; the mount and the file go within ~2 s; a read on an fd already open returns **EIO at once** (no hang) |
| **enter USB mode** | re-enumerated (a new usb device number); mounted again at the first free `/media/usbN` -- `usb0` again here, but **a new `sdX` and a new inode**, and `sdb` while an old fd still held `sda` |
| **swap the UMD while in USB mode** (two good discs) | **no USB event at all**: the file keeps its inode **and its size** (the old disc's), but reads return the NEW disc's sectors; one read blocked 8.1 s across the swap |
| swap in USB mode to a dirty disc (Die Hard, Jumanji: unreadable on the XMB too) | reads block for minutes (usb resets every 30 s in dmesg), even after the good disc goes back, until USB mode is left (then EIO) |
| the PSP's setting reset (after a hard reboot) | it came back as **Memory Stick** (`MP_ROOT`, `PSP`, mounted **rw**): no `UMD9660.ISO`, nothing for us; the manual says to check the setting |

## 3. Design (UMD Main: `main/support/umd/umd_psp.cpp` + `umd_psp_logic.c`)

Modelled on MiSTer_DVD's `dvd_phys.cpp` (`../MiSTer_DVD/docs/physical_disc.md`), cut to a file
instead of a drive.

- **Sectors stay synchronous** (step 0's gate: playback, trick play, pause, menus clean over USB).
  Main serves the core's 2048-byte requests from its 16 KB buffer on the poll thread as for any
  image. MiSTer_DVD's read-ahead ring (`dvd_readahead`, its step 49's deferred acknowledge) is NOT
  harvested; it is the fallback if a disc stalls (§5).
- **A worker thread does all the PSP's file I/O** (never the poll thread). About once a second it
  reads `/proc/mounts`, keeps the `/media/usb0..7` mounts whose disk is a PSP by sysfs (memory, no
  disk I/O): **Sony** -- the SCSI vendor contains `sony` in any case, or the USB `idVendor` is
  `054c` -- **and** `psp` anywhere in the SCSI model or the USB `product` string. The strings differ
  between PSPs: this one answers SCSI `Sony` / `PSP`, USB `054c` `PSP Type A`; another PSP's kernel
  log (an Arch Linux forum thread, model and firmware not given) reads SCSI `SONY` / `"PSP" MS`. The
  first build's exact `Sony` / `PSP` prefixes would have missed that one (the maintainer asked
  "are we sure that the vendor/model is Sony/PSP for all PSP models?"); Sony's own USB sticks are
  `054c` too, hence the `psp` test. It stats
  `UMD9660.ISO` there (vfat lookups are case-insensitive), opens it, drops LBA 16's page
  (`posix_fadvise(32768, 4096, DONTNEED)`: a 2 KB range drops nothing, the page is 4 KB), reads the
  PVD and closes it. **No other USB drive is ever looked into** (the maintainer asked whether the
  poll keeps a USB hard disk awake: measured, 20 s of the first design's `stat` on every mount read
  nothing from a FUSE NTFS stick -- the dentry cache answered --, but a cache miss would wake a
  sleeping disk, so the sysfs filter makes it certain). **It holds no fd between scans**: a held fd
  keeps the old `sdX` alive across a re-enumeration. A view = present, usbN, (st_dev, st_ino,
  st_size), the PVD's kind (`UMD VIDEO` / `PSP GAME` / other), a hash of the whole PVD sector (its
  dates, volume size and application field -- which carries the title -- tell discs apart), the
  PVD's volume bytes.
- **The decisions** (`umd_psp_logic.c`, benched by `bench/umd/run_psp_scan.sh`), one step per new
  view:
  - **an edge** -- the file appears, or reappears as another device / inode / usbN, or its PVD
    hash changes (a swap inside USB mode, which nothing else shows) -- clears `foreign` and
    `suppressed`: putting a disc in or entering USB mode is a deliberate act, as a disc insertion
    is for `dvd_phys`. **The first view since Main started is not an edge**: an MGL that loaded a
    library ISO with the PSP already attached keeps its image;
  - **vanished** while we own slot 0: unmount (`user_io_file_mount("", 0)`; the fabric's
    `img_ejected` stops the reader, display and audio);
  - **a UMD Video disc**, slot 0 not ours, not foreign, not suppressed, the FAT not stale: mount it;
  - **a disc swapped inside USB mode is never mounted under the old FAT, whatever its size**: owned,
    it is unmounted; then a message, "Disc changed on the PSP. Leave USB mode and enter it again to
    play it.", until an edge (USB mode re-entered: a new inode). The maintainer (2026-10-10): the
    first build remounted a smaller disc and asked only for a bigger one (reads past the vfat
    file's end return nothing), and "from a user perspective they won't be able to tell which disc
    will require it or not, and it just seems random" -- one rule;
  - **the first view, judged by size**: a Main started after a swap it never saw (a core reload)
    cannot see the hash change, so the first disc read is compared with the file: a fresh FAT is
    the PVD's size (National Treasure and Kranks exactly; 80 of the library's 84 dumps exactly, 4
    one sector short), so a file more than 1 MiB from it (`UMD_PSP_FAT_SLACK`) is stale -- the
    same message. Only the first view: after a re-entry the FAT is fresh by construction;
  - **a game disc** (`PSP GAME`): never mounted, one message per disc, "The PSP's disc is a game,
    not a UMD Video."; owned and swapped to a game: unmounted first;
  - anything else (another system id): mounted; the core's own refusal ("This disc cannot be
    played.") is the verdict.
- **Latches** (from `dvd_phys`): `foreign` -- the user (OSD, MGL, a library ISO) holds slot 0 with
  another file: never pre-empted until an edge; `suppressed` -- **any** unmount from the OSD (of
  the PSP's disc or of another image): the slot the user emptied stays empty until an edge (the
  first build put the PSP's disc back 0.8 s after a library ISO was unmounted -- found on the rig).
  Any mount of a PSP path (ours, an MGL's, the HIL FIFO's, the OSD's) is **owned** (adopted: its
  hash taken at the next read), so the vanish / swap rules apply to it -- and the game and stale
  rules too: an adopted game disc, or an adopted disc on a stale FAT, is unmounted before its
  message (found in review: the first build told and left it playing). Our own mount that fails to
  open is not retried until an edge. The mount hook is `umd_menu_mounted` (already patched in after
  `UIO_SET_SDSTAT`), which forwards to `umd_psp_note_mount`; our own calls are told apart by a flag
  set around them.
- **An MGL launch is waited out**: while `mgl_get()->done` is 0 the tick does nothing (no step, no
  mount, no message). `mgl_launch.md` lesson 1: an `Info` raised from a poll tick in that window
  freezes the launch; and the MGL's own mount comes last, so the first view after it finds the
  MGL's image (the PSP's path adopted, another image foreign). `dvd_phys` does the same.
- **Messages are Main's `Info` box, 2 s late**: the plane cannot be drawn with no image mounted
  (`emu.sv`'s `show_pic` needs `media_seen`, `resume.md` §6), and both messages come with slot 0
  empty. An unmount (the core goes idle) and a core load each change the video mode, and Main's
  own resolution box (`video_info`) replaces any `Info` shown before it -- the maintainer saw the
  first build's message blip. So a message waits 2 s (`PSP_MSG_DELAY_MS`) and shows for 5 s.
  Opening `show_pic` without a mount for it was offered and declined (a fit at 95 % ALM for two
  rare messages).
- **The tick** runs from `umd_ctl_tick` beside `umd_host_tick` (every user, the UMD core only);
  another core stops the scan (`umd_psp_away`).
- **Log**: decisions only, `/tmp/umd_psp.log` (not the scan), for a bug report. Counters in the
  HIL's `/tmp/umd_host.json` (`"psp"`).

## 4. Rejected

- **Reading `/dev/sdX` directly** (to see past the stale file size after an in-USB-mode swap):
  the FAT the PSP synthesises would have to be walked; leaving and re-entering USB mode does the
  same in one press. Rejected for its cost.
- **An fd held open to watch the disc**: it pins the old device across a re-enumeration (measured:
  `sdb` instead of `sda`).
- **Detecting a swap by (dev, ino, size)**: an in-USB-mode swap changes none of them (measured).
- **Remounting a disc swapped inside USB mode when it fits the old FAT** (the first build): right
  for a smaller disc, wrong for a bigger one, and the user cannot tell which (§3).
- **The message on the plane** (the disc screen's machinery): no plane shows without a mount; a
  fabric change for it was declined (§3).

## 5. Known limitations

- **A read the PSP does not answer blocks Main's poll thread**: a swap in USB mode stalls the
  OSD, subtitles and the panel ~8 s; a dirty disc stalls them until USB mode is left. The core's
  reads are Main's synchronous sector service; the worker cannot unblock them. If this proves a
  problem in use, the fix is MiSTer_DVD's ring with a deferred acknowledge (§3).
- **A read error is a zeroed sector**, silently (stock Main's sector service); the decoder's
  error counters see the damage, nothing names its cause.
- **Seeks cost the UMD drive's 0.6-1.9 s** (chapters, FF / REW hops, Go To): the disc, not the
  core.
- **A stock-Main user writes the MGL** (the manual's text names `/media/usb0`): with another USB
  disk mounted first, the number changes.
- **A disc changed inside USB mode** is not played until USB mode is re-entered (one rule, §3;
  the message says so).
- **On a stock Main nothing unmounts the PSP's file** (found by the maintainer on .236, 2026-10-10):
  after USB mode was left, National Treasure played on for minutes. Linux keeps a file's cached
  pages after its device goes, and Main's still-open fd reads them (LBA 16 read through
  `/proc/<Main>/fd` in 0.6 ms after the disconnect; a never-read sector near the end returned 0
  bytes). Main serves the cache, then zeroed blocks past it (the step-0 EIO test dropped the page
  first, so it never saw this). The manual tells a stock-Main user to stop before leaving USB
  mode. The UMD Main's scanner unmounts within a scan, so it does not apply there.
- **A PSP is recognised by sysfs strings** (§3; measured on one PSP, one more seen in a forum log):
  one naming itself neither Sony nor PSP in any of the four would not be found (the stock-Main
  MGL still works for it).
- **A message is lost when the OSD is open at its moment**: Main's `Info` does nothing then
  (`menustate > MENU_INFO`), and the scanner does not retry it. The unmount itself still happens.
- **The first-view size test** assumes a fresh FAT is within 1 MiB of the PVD's size (measured on
  2 discs over USB, 84 library dumps); a disc outside it would ask for a re-entry once, then play.
- **Not measured: whether the PVD poll keeps the PSP's UMD drive spinning** (the PSP caches the
  disc's head; the poll's read takes ~10 ms, and a 60 s pause resumed without a spin-up stall).

## 6. On the rig (2026-10-10, .236, the maintainer on the PSP)

Builds: the core `UMD_zoom_20261009_2050.rbf` (main's netlist, unchanged), the UMD Main of this
branch deployed by `mister.py deploy --main`, the core loaded with no image
(`load_core .../UMD_hil.rbf`).

| check | result |
|---|---|
| the core opened with the PSP attached, no image | mounted 0.4 s after the load command, before the core's 0.9 s OSD pop (no OSD seen); National Treasure's menus and startup promo, errors 0 |
| leave USB mode | unmounted within the scan; the idle screen; the menus quit, the place kept |
| enter USB mode again | mounted, with the fresh FAT's size |
| a swap inside USB mode (to a bigger disc, the first build) | unmounted at once, the message logged -- but it blipped: Main's resolution box replaced it -> the 2 s delay |
| the core reloaded on a stale FAT (Kranks under National Treasure's file) | the message stayed up 5 s; no mount; after re-entering USB mode Kranks played |
| swaps inside USB mode, both directions, smaller and back | each one the message, each re-entry a mount (the one rule) |
| a library ISO over the PSP's disc (the HIL FIFO's mount) | foreign, not pre-empted; unmounted from the "OSD" -> the slot stays empty (after the fix) |
| the PSP's disc unmounted from the "OSD" | not mounted again |
| a PSP game UMD | not mounted; "The PSP's disc is a game, not a UMD Video." shown |
| a USB stick first, then the PSP | the PSP on `/media/usb1` (`sdb`), found and played; the stick (FUSE NTFS) read 0 sectors over 15-20 s of scanning |
| an MGL of a library ISO, the PSP attached | the MGL's image plays, the PSP foreign, no freeze |
| an MGL of `/media/usb1/UMD9660.ISO` (the stock-Main route, under the UMD Main) | adopted: no second mount; plays |

After the review fixes (the looser PSP match, the adopted game / stale unmount) the build was
reloaded on the rig: the PSP on `usb1` found and mounted as before. Then `mister.py restore`, and
the two resume files these tests wrote (Kranks, National Treasure) removed.

Not run on the rig: the manual's MGL under a stock Main (`[UMD] main=` removed). Its path is stock
Main's own MGL code, the same that step 0 ran with an absolute path (§2); the maintainer's own test
covers it.
