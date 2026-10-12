# Bug reports: the sparse-sector repro bundle (P8)

**Status: ✅ MERGED (PR fj#54, 2026-10-06; decisions R1-R4 taken by the maintainer the same day): `tools/umd_report.py`, `tools/tests/test_umd_report.py` (+13 RED arms), the library gate
`tools/tests/corpus_report.py` ALL GREEN on 84 images, menus included; run on the MiSTer (§7).** The
user page is `site/content/reference/reporting-a-bug.md`; the release zip carries the tool
(`tools/package_release.sh`).

The idea comes from MiSTer_DVD's `dvd_report.py`: a navigation bug needs the disc's TABLES and
nothing else, and those are a tiny fraction of an image. A reporter runs one self-contained script
against their own `.iso` on a PC and sends a small zip; `unpack` rebuilds a **sparse** image of the
original size with the captured sectors at their original addresses, so every tool that walks an
ISO by absolute LBA works on the reconstruction unchanged -- and the bundle is already shaped like a
bench fixture (`tools/umd_fixture.py --nav` cuts one from it).

The first version of this note (2026-09-23) planned "the first N packs" of each stream and "a window
around the reported time". The first AU of a clip is an I picture -- a watchable still -- so that
plan broke its own guarantee; and the core has grown disc menus, subtitles and a Main since. This
plan replaces it.

## 1. Measured (2026-10-06, the 84-image library)

| what | min | median | max |
|---|---|---|---|
| the navigation files (`UMD_DATA.BIN`, `PARAM.SFO`, `PLAYLIST.UMD`, every `CLIPINF/*.CLP`) | 41 KB | 97 KB | 289 KB |
| the menu containers (`RESOURCE/*.RCO`), whole | 44 KB | 680 KB | 3,476 KB |

RCO media (the agent survey of `main/support/umd/menu/rco.c`, `menu.c`, `vag.c`): images are PNG
(format 0) or JPEG (1), never compressed per image (the engine refuses one that is), their bytes at
IMGDATA (header word 28) + the entry's offset; sounds are one complete VAG per channel at SOUNDDATA
(word 30) + the channel's offset. Both are read from the raw file, outside any packed table region.
The engine sizes a quad from the image's OWN dimensions when the object's width or height is 0
(`menu.c` ~1652), anchors `iconOffset` by them, and computes an alpha bounding box; an image that fails
to decode is not drawn at all, and a page that draws nothing does not take the presentation
(`umd_menu_host.c` ~488). So a blanked image must stay a VALID image of the same size.

## 2. Decisions (the maintainer, 2026-10-06)

- **R1 -- the menus: scripts kept, art blanked.** Every RCO is captured whole except its media:
  each image is replaced in place by a valid image of the same format and dimensions (flat grey,
  opaque inside the original's alpha bounding box, transparent outside), zero-padded to the original
  length; each VAG keeps its 48-byte header (rate, size) and its ADPCM is zeroed (silence of the same
  length: a press's timing is kept). The VSMX script, the object tree, the animations and the text
  tables stay byte-exact, so the engine runs the disc's own logic on the reconstruction.
- **R2 -- the stream: headers kept, payloads zeroed.** From the head of each `.MPS` (default 1,024
  packs, ~2 MB of sectors, a few seconds): pack and PES headers (the PTS), the system header, padding,
  the index packs (0xBF) whole; on video (0xE0) the non-VCL NAL units (SPS, PPS, SEI, AUD, end of
  sequence / stream) whole and each slice NAL up to the end of its slice header, the rest zero; on
  audio (0xBD 0x00-0x0F) the 4-byte sub-header and every AU's 8-byte header (sync, params), the frame
  bodies zero -- the core then refuses each frame as `E_CH_CONFIG` and plays its silence, the AU count
  and timing intact; on subtitles (0xBD 0x80-0x9F) the 20-byte unit header (duration, x, y) and a
  valid blank 4-bit PNG of the same size in place of the picture. **Anything the scrubber cannot
  classify is zeroed**: a bundle can lose a header, never leak a payload. A bare `.MPS` is accepted
  (the same scrub, no tables).
- **R3 -- no time window.** No real payload is ever captured, not even opt-in. A glitch at a time T is
  reported with the time and the diagnostic log; the maintainer reproduces it on a copy of their own.
- **R4 -- distribution: both.** `tools/umd_report.py` is ONE stdlib-only file (it duplicates the ISO
  walk, a PNG reader / writer, a flat JPEG writer and the H.264 header parse rather than importing
  `umd_iso` and friends: a reporter has no checkout), and `tools/package_release.sh` ships it in the
  release zip, so the manual points at a file the user already has.

## 3. The bundle

A plain `.zip` (GitHub accepts no custom attachment extension): `README.txt` (what it holds and does
not), `manifest.json`, `sectors.bin` + `extents.json` ({first LBA, count} runs, ascending). The
manifest: schema, tool version, the image's BASENAME (never a path, host or user), its size and
volume id, the disc id and title from `PARAM.SFO`, the optional core-version line and note the
reporter gives, what was captured per file (kind: table / rco / stream head), the scrub counters
(images / sounds blanked, slices / AUs / units kept as headers, bytes zeroed as unclassified), any
multi-extent file, and every bound that was hit (printed too: the spec-maximum rule).

Subcommands: `make IMAGE` (the default), `info BUNDLE`, `unpack BUNDLE -o repro.iso` (sparse, the
original size), and `audit BUNDLE` (the content check alone, for the maintainer on a received bundle).

## 4. The content guarantee, enforced not promised

`audit()` runs over the final captured set before anything is written, and again in `info`. It is a
SECOND, independent walk -- not the scrubber's own bookkeeping:

- every RCO image region decodes to a flat image (one colour, alpha 0 / 255 only) or is zero; every
  VAG's ADPCM is zero; no byte in the IMGDATA / SOUNDDATA / model regions outside a re-checked entry
  is non-zero;
- every captured `.MPS` sector re-parsed: a slice NAL has no non-zero byte past its re-parsed header
  (+ the byte holding the header's last bit); an audio frame body, a subtitle picture other than a
  flat blank, an unknown stream id's payload: all zero;
- a coarse, parser-free ceiling per pack (non-zero PES payload bytes <= a fixed budget, stated in the
  code) so a parser bug cannot widen what the exact check admits.

A failure refuses the bundle loudly, naming the file, LBA, stream and byte count. Never relax this
"just for one bug". After writing, `make` unpacks its own bundle and checks it: every table file and
every RCO's non-media bytes identical to the original's, the stream heads' headers identical.

## 5. Verification

- `tools/tests/test_umd_report.py`, no media: images from `tools/tests/umd_synth.py` (tables, an RCO
  with PNG / JPEG / VAG entries, a stream head with every stream kind across PES boundaries); RED
  arms in `red_umd.py`, each caught by its own test -- above all the audit (a scrubber that keeps a
  slice body, an image left unblanked, a VAG not zeroed: each must make the audit refuse).
- `tools/tests/corpus_umd.sh`: every library image -> bundle -> unpack, then on the original and the
  reconstruction `umd_playlist`, `umd_clpi` and `umd_nav_ref` byte-identical, the menu engine's
  library class (`tools/menu_lib.py`) identical, `umd_fixture.py --nav`'s reader expectations
  identical, and the SPS / PPS / slice headers of the stream head identical (`tools/h264_fields.py`).
  Bundle sizes reported.

## 6. Not automatic on the player (yet)

MiSTer_DVD triggers its bundle from a gamepad chord in its Main. The UMD Main (A7 / P9) could do the
same; it is out of scope for this stage (the PC tool first), recorded here as the follow-on.

## 7. As built (2026-10-06)

**The library (`corpus_report.py --menus`, 84 images): ALL GREEN.** Bundles 74-1,582 KB (median
211; the largest, Now That's What I Call Music 2006, has 30 clips and so 30 stream heads), 0-8 s each
on this PC. On every image the original and the reconstruction give identical `umd_playlist --json`,
`umd_clpi --entries --json` and `umd_nav_ref --chapters`; every SPS, PPS and slice header of the
stream heads decodes (h264_fe_ref, not the tool's parser) to identical fields; every AU header and
subtitle unit header is identical; and `menu_lib.py --check` puts every reconstruction in its
original's class (81 menu, 3 autoplay). Scrubbed: 5,642 RCO images, 115 sounds, 395 subtitle
pictures, 347,553 slices, 185,239 audio frames; nothing unclassified.

**The audit's ceilings, measured:** the longest non-zero payload run in any captured pack is 20 bytes
(ceiling 160); the most non-zero payload bytes in one pack 889 (ceiling 1,536, raised from 1,024: the
first pack of a still clip -- the warning screens -- holds dozens of tiny pictures, each an AUD, a
picture timing SEI and a slice header). A leaked pack is ~2,000.

**On the MiSTer** (.201, Python 3.9.6, an image on the NAS share): Akira in 34.5 s; the bundle made
there passes `audit` on this PC and this PC's on the MiSTer.

**Found while building:**

- *zlib differs between machines.* The MiSTer's zlib compresses a stand-in to other bytes (the first
  MiSTer bundle was 195 KB, this PC's 192). The audit therefore compares a stand-in's chunks and its
  DECOMPRESSED image with a fresh one, never the compressed bytes, and a re-scrub keeps a stand-in it
  finds as written. Without that, a bundle made on the MiSTer failed its audit on a PC.
- *Hackers' 113-byte menu image* (214 x 120, one colour, opaque): the two-colour stand-in (125 bytes)
  did not fit, so it was zeroed (the engine then draws nothing). An image opaque over its whole area
  now gets a one-entry palette and no tRNS (97 bytes).
- *Speed:* the first version took 6.6 s on this PC and 10 min 50 s on the MiSTer for Akira. Two
  quadratic spots: mapping ES bytes back to sectors (now a binary search), and unescaping each whole
  slice to read a header of a few dozen bytes (now a 64-byte prefix, retried whole only if the header
  runs past it, with a fast path when it holds no emulation prevention byte).
- *A misparsed slice header* can come out the same byte length (the RED arm that skipped
  `bottom_field_flag` survived at first). The parse now requires the CABAC alignment bits to be ones,
  as the spec does; a misparse that breaks them zeroes the slice (counted, `slices_unparsed`).

**Known limitations:**

- An image whose stand-in cannot fit in its own bytes is zeroed and counted (`images_zeroed`); the
  engine then draws nothing for that object (none in the library since the one-colour form).
- Only the HEAD of each stream is captured: a bug at a later time is reported with its time and the
  diagnostic log (R3). Subtitles appear in a head only when the title starts with one.
- `ICON0.PNG`, `PIC1.PNG`, `ICON1.PMF`, `SND0.AT3` and any other file outside the list are not
  captured (listed in the manifest as `not-captured`): the core does not read them.
- A bundle is audited by the same tool version that wrote it (`tool_version` in the manifest); the
  stand-ins' form may change between versions.

## 8. Housekeeping

Tools, packaging and the manual only: no netlist change, so `CORE_VERSION` is not touched on this
branch (a change would re-roll the fitter seed for nothing).
