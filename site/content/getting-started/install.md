# Install the core

!!! info "Not yet released"
    There is no release yet. These steps describe how installation will work; until a
    release exists, build the core from source (see
    [Building from source](../about/building.md)).

1. Download `MiSTer_UMD_Video_<version>.zip` from the latest release and extract it to the
   **root** of your SD card (`/media/fat`). It places:
    - `_Other/UMD_YYYYMMDD.rbf`: the core;
    - `MiSTer_UMD`: the **UMD Main**, for the disc menus, the control panel, the disc screen, remembered places and a PSP's disc over USB (keep it at the root);
    - `MiSTer_UMD.json` and `UMD_INSTALL.txt`: which build it is, and these steps;
    - `umd_report.py`: makes a report bundle of a disc for a bug report
      ([Reporting a bug](../reference/reporting-a-bug.md#the-report-bundle)).
2. For the UMD Main's features (the disc menus, the control panel and the rest), add these two lines to `/media/fat/MiSTer.ini`. Add them as a new
   section; do not replace the file. If there is no `MiSTer.ini`, create one with just
   these lines:

    ```ini
    [UMD]
    main=MiSTer_UMD
    ```

3. Launch **UMD** from the MiSTer menu under **Other**.

## What the UMD Main is

MiSTer's **Main** is the program on the ARM side that runs the menu, the OSD, the scaler
and the file browser. The UMD Main is that same program with these additions:

- it runs the discs' own menus ([Disc menus](../playback/disc-menus.md));
- it draws the [control panel](../playback/controls.md#control-panel);
- it shows a stopped disc's own art ([The disc screen](../playback/disc-menus.md#the-disc-screen));
- it remembers where each disc stopped, on the SD card
  ([Going on where you left off](../playback/disc-menus.md#going-on-where-you-left-off));
- it finds and plays the disc in a PSP connected over USB ([Playing a real UMD](psp-disc.md)).
 The two lines above tell MiSTer to run it
while the UMD core is loaded, and your usual Main for every other core.

Without it, playback is the same: picture, sound, subtitles, chapters, fast forward and
rewind, Go To, A-B Repeat, the audio and subtitle tracks and the on-screen display. A disc then
starts straight into its main title and from its beginning each time, Stop shows the idle
screen, and a PSP's disc plays only through an MGL shortcut
([Playing a real UMD](psp-disc.md#with-the-stock-main)).

## Updating and removing

- **Updating:** extract the new zip over the old files. The core and the UMD Main must come
  from the same release; with a mismatched pair the Control Panel button says
  `Update the UMD Main for the control panel.`
- **Removing the UMD Main:** delete the two `MiSTer.ini` lines and `MiSTer_UMD`. The core
  keeps working without the UMD Main's features. The places it remembered stay in `config/umd/`; delete that folder to remove them too.

## Version check

The OSD's About page shows the running build as `UMD <version> <yymmdd>`. Quote that line
when reporting a problem.
