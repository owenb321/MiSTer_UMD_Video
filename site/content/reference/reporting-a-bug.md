# Reporting a bug

Bugs are recorded as issues on the project's
[GitHub repository](https://github.com/owenb321/MiSTer_UMD_Video/issues), where a form for
each kind of problem asks for what is listed below. Never attach copyrighted media: the
report bundle below is the way to share a disc's structure.

Always include:

- the version line from the OSD About page (`UMD <version> <yymmdd>`);
- which disc image, and how it was made;
- what you saw, what you expected, and when (the time on the Display overlay, if it is
  in the middle of a title);
- a **report bundle** of the image (below), when the problem is with one disc;
- if you can, the [diagnostic log](../playback/on-screen-messages.md#the-diagnostic-log)
  (`/tmp/umd_telem.json`, with the UMD Main installed and `umd_hil` on the SD card), copied
  while or just after the problem shows.

## The report bundle

Most problems with one disc (it plays the wrong title, it cannot be played, its menu does
nothing, a chapter lands in the wrong place, a track is missing) can be reproduced from the
disc's **structure** alone. `umd_report.py` copies that structure out of your image into a
small zip, usually a few hundred KB (up to about 2 MB for a disc with many video clips):

- the disc's filesystem and its navigation tables (titles, playlists, chapters, tracks);
- the disc menus' scripts and layout, with **every picture replaced by a plain grey box and
  every sound silenced**;
- the first few seconds of each video stream with **only its headers** kept (time stamps,
  the picture format, the frame and slice headers): no picture data and no sound data.

The bundle holds **nothing you could watch or listen to**. The tool checks every sector
before it writes the zip, and refuses to write it if anything looks like picture or sound.
The zip records the image's file name, not where it is stored.

`umd_report.py` comes in the release zip, at the root of the SD card. It needs only Python 3,
which every MiSTer has.

**On the MiSTer**, over SSH (the image stays where it is):

```sh
python3 /media/fat/umd_report.py "/media/fat/games/UMD/My Disc.iso"
```

**On a PC** with Python 3, after copying `umd_report.py` off the SD card:

```sh
python3 umd_report.py "My Disc.iso"
```

The tool asks for the OSD's version line and a one-line description (press Enter to skip
either), then writes `umdreport-<title>-<date>.zip` in the current directory and prints
what it holds. Attach that zip to your report. Add `--core-version "UMD ..."` and
`--note "..."` to answer the questions on the command line.

A bare stream file (`.MPS`) works the same way.

!!! note "What a bundle cannot show"
    A problem with the picture or the sound itself, such as a glitch, a wrong colour or a
    crackle at a certain time, needs the real data, which the bundle never carries. For those,
    give the time it happens and the diagnostic log.
