# MiSTer UMD Video Player Core

A **PSP UMD Video player core for the MiSTer FPGA platform** (DE10-Nano / Intel Cyclone V).

Put a `.iso` image of a UMD Video disc on the SD card and the core plays it: the H.264
video and ATRAC3plus audio are decoded **entirely in FPGA fabric**. On a stock Main the ARM
only serves SD blocks through the standard framework interface, exactly like any other core;
the optional **UMD Main** (below) adds the features that run on the ARM.

> **Status: v0.1.0, the first release: plays discs end to end.** On a stock Main the
> core plays a UMD Video image from start to end: H.264 decoded faster than real time on every
> disc tested and shown at its authored cadence, ATRAC3plus sound in step, subtitles, the audio
> and subtitle tracks, pause / stop / chapters / fast forward and rewind / Go To / A-B Repeat,
> a PSP-style on-screen display, 480p over HDMI and native 480i to a CRT. The **UMD Main**, a
> build of the MiSTer's Main program that ships with the core (two lines in `MiSTer.ini`), adds
> the discs' own menus run as on a PSP, the PSP's control panel, a stopped disc's own art, a
> remembered place per disc, and a real UMD played from a PSP over USB. The plan and its
> history are in [`docs/roadmap.md`](docs/roadmap.md).

📖 **[Read the manual](https://owenb321.github.io/MiSTer_UMD_Video/)** — install, controls, every setting,
the disc menus, CRT output, playing a real UMD from a PSP, troubleshooting.

Built as a sibling of [MiSTer_DVD](https://github.com/owenb321/MiSTer_DVD), from which it
takes the framework edits, the build gates, the verification discipline and, as each
phase needs it, the reusable plumbing (`docs/harvest.md`). Nothing of the DVD core's
MPEG-2 decoder or DVD navigation is here.

## How this was built

The RTL in this repository is written by an LLM working under human direction. The
human contribution is research, architecture direction and hardware QA: measuring what
is actually on the discs, deciding what to build and in what order, running each build on
real hardware and narrowing down what breaks. `docs/` records the reasoning behind the
non-trivial decisions. This is stated up front because it is a fair thing for anyone
evaluating the code to know.

## Scope

- **UMD Video images** (`.iso`): the main feature with chapters, the disc's audio and
  subtitle tracks, seek and pause, resume.
- **Single stream files** (`.mps`, one clip taken out of an image): played from start to end
  (no seeking). PSP game movies (`.pmf`) are not supported.
- **Video**: H.264 Main profile at 720x480, progressive, film (3:2) and interlaced
  field-coded alike, presented at its authored cadence (on the 480p output, film coded as
  fields is recognised by its 3:2 rhythm and each film frame shown whole); 480p over HDMI (with a
  Zoom that fills a 16:9 screen with a widescreen film stored letterboxed in 4:3), or native 480i
  to an analog CRT (with Letterbox / Crop of 16:9 titles for a 4:3 CRT, and an optional
  dither that smooths the banding of the standard I/O board's 6-bit DAC).
- **Audio**: ATRAC3plus stereo, decoded in fabric.
- **Disc menus**: the discs' scripted menus (RCO/VSMX) run as on a PSP, by the UMD Main on
  the ARM; with a stock Main the core plays the main title directly.
- **Real discs**: a PSP with custom firmware (ARK-5) shares the disc in its drive over USB; the
  UMD Main finds it and plays it, and a stock Main plays it through an MGL shortcut.

Out of scope for the first version: PSP game cutscenes.

## Getting started

Download `MiSTer_UMD_Video_<version>.zip` from the
[latest release](https://github.com/owenb321/MiSTer_UMD_Video/releases/latest) and follow the
[install page](https://owenb321.github.io/MiSTer_UMD_Video/getting-started/install/): the zip goes to the SD card's root,
and two lines in `MiSTer.ini` turn on the UMD Main (the disc menus and the rest). To build it
yourself, see below and `./tools/package_release.sh`.

## Documentation

- **[User manual](https://owenb321.github.io/MiSTer_UMD_Video/)** — published with each release;
  its source is [`site/content/`](site/content/), built with MkDocs.
- **[`docs/`](docs/)** — engineering design notes: the *why* behind the RTL. **Not a manual.**

## Building from source

Requires **Quartus 17.0.2 exactly**.

```bash
USE_DOCKER=1 ./build_release.sh --compile   # pinned container -> releases/UMD_<slug>_<date>_<time>.rbf
./build_release.sh --compile                # native Quartus 17.0.2
```

The UMD Main (the disc menus, the control panel, a PSP's disc over USB): `USE_DOCKER=1 main/build_main.sh` -> `main/.build/MiSTer_UMD`.

Always use `build_release.sh` rather than `quartus_cpf` directly: MiSTer's loader needs a
*compressed* `.rbf`; an uncompressed one silently fails to configure and the core shows
no video on any output. The script also runs the build gates and names the build after
the `dev-<slug>` in `CORE_VERSION`, so the `.rbf`, the zip and the OSD line agree.

Benches run under Icarus Verilog: `bench/umd/run_scaffold.sh` (`--red` proves each bench
can fail). Host tests: `tools/tests/run_tests.sh`.

## Hosting

Developed in a private repository during bring-up; the public history starts from an import of that
work, so references written `fj#NN` in `docs/` name pre-publication pull requests and issues
(`docs/README.md`). Everything
in the tree is written as if it were already public.

## Licensing

The project as a whole is **GPL-3.0-or-later** — see [LICENSE](LICENSE), with the
component breakdown in [NOTICE](NOTICE).

| Component | Licence |
|---|---|
| `sys/` — MiSTer framework | GPL, mixed "v2 or later" and "v3 or later" |
| `umd/`, `bench/`, `tools/`, `docs/`, `site/` | Original to this project, with modules inherited from MiSTer_DVD — GPL-3.0-or-later |

**Patents are a separate matter and, unlike MPEG-2, not an expired one.** H.264/AVC is
covered by a patent pool whose members' patents are partly still in force, and ATRAC3plus
is a proprietary Sony format documented only by reverse engineering. This is a hobby
implementation written from the published specification and from open-source reference
decoders used as verification oracles; no patent licence is granted or implied, and none
of this affects the copyright position above.

## Acknowledgements

The MiSTer-devel framework; MiSTer_DVD, this core's sibling; ffmpeg and the JM reference
decoder as oracles; the PSP homebrew community, whose reverse engineering of the PSMF,
CLPI and RCO formats is the only documentation of them; and the H.264 FPGA papers cited
in [`docs/references.md`](docs/references.md).
