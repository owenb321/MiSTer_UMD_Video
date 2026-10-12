# MiSTer UMD Video Player

A player for **PSP UMD Video** discs on the MiSTer FPGA platform (DE10-Nano). Put a UMD
Video `.iso` on the SD card and the core decodes its H.264 video and ATRAC3plus audio in
FPGA fabric.

!!! info "Status: in development, no release yet"
    The development build plays UMD Video discs from start to end. Picture, sound and
    subtitles work; so do the transport (pause, stop, chapters, fast forward and rewind,
    Go To, A-B Repeat), the audio and subtitle tracks, 480p over HDMI and native 480i to a
    CRT. With the **UMD Main** that ships with the core, the discs' own menus run as on a
    PSP, along with the control panel, the disc screen and remembering where each disc
    stopped. There is no release to download yet: see [Install](getting-started/install.md).
    What is not supported is listed in [Compatibility](reference/compatibility.md).

## Start here

1. [Install the core](getting-started/install.md)
2. [What you need](getting-started/what-you-need.md)
3. [Loading a movie](getting-started/loading.md)

## What the core does

- Plays UMD Video movies from a `.iso` image of the disc: the main feature, its chapters,
  and the disc's audio and subtitle tracks.
- Runs the disc's own menus as a PSP does (with the UMD Main).
- Outputs 480p over HDMI, or native 480i to an analog CRT.
- Presents the film at its authored 23.976 fps cadence, with the sound in step.
- Plays a real UMD from a PSP shared over USB ([Playing a real UMD](getting-started/psp-disc.md)).

<!-- SCREENSHOT hero.png: the idle screen (the XMB-style wave) on a 16:9 display.
     Capture: tools/mister.py shot with no image loaded. -->
