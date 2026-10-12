# Troubleshooting

## The core loads but shows no picture on any output

An **uncompressed** `.rbf` silently fails to configure the FPGA. Release builds are
compressed (about 3 MB); a 7 MB file is the sign. Rebuild with `build_release.sh`.

## This disc cannot be played.

The core stopped on the disc. Turn on the [diagnostic log](../playback/on-screen-messages.md#the-diagnostic-log)
and load the image again to see why:

- **`reader` shows an error** ([codes](../playback/on-screen-messages.md#reader-errors)):
    - **1, 2**: the file is not a disc image. Check that it is the whole `.iso`, not an
      archive or a part of one.
    - **3, 5-9, 11**: the image is damaged or incomplete. Make it again from the disc if you
      can, then [report it](reporting-a-bug.md) if the error stays.
    - **4**: the image is not a UMD Video disc. PSP game and UMD Audio images are not
      supported.
    - **10**: the image uses an ISO 9660 feature no surveyed disc uses. Please
      [report it](reporting-a-bug.md).
    - **12**: a stream file of 4 GB or more (a UMD clip is under 1.8 GB), or a `.pmf` file
      (not supported) whose header is damaged.
- **`refused` climbs** ([codes](../playback/on-screen-messages.md#video-refusals)): the disc
  uses an H.264 feature outside this core's scope. No disc surveyed does; please
  [report it](reporting-a-bug.md) with the code.

## The screen stays black, or the picture breaks up

With the [diagnostic log](../playback/on-screen-messages.md#the-diagnostic-log) on:

- **`fe_err` climbing steadily** ([codes](../playback/on-screen-messages.md#video-errors)):
  the video breaks the H.264 rules or the image is damaged. A few errors, or one at the end of
  a title, are normal; a steady climb is worth [reporting](reporting-a-bug.md) with the code.
- **`recon_err` climbing** ([codes](../playback/on-screen-messages.md#picture-errors)): a burst
  at the very start of a title, then no more, is normal (it opens on pictures that refer to
  earlier ones). Code 6 climbing means the stream keeps more reference pictures than UMD Video
  allows, or the image is damaged. Anything else climbing is worth
  [reporting](reporting-a-bug.md).
- **`refused & 15` above zero**: pictures larger than the standard's limit for UMD Video were
  skipped. No disc surveyed has them; please [report it](reporting-a-bug.md).

## No sound

- **No sound at all**: the title may declare no audio track; press Audio (A or F3) and see
  whether a track tag appears.
- **`aud_err` climbing** in the [diagnostic log](../playback/on-screen-messages.md#the-diagnostic-log)
  ([codes](../playback/on-screen-messages.md#audio-refusals)): sound frames were refused and
  played as silence. A few in a damaged image are expected; on a clean image please
  [report](reporting-a-bug.md) the disc and the code.
- **Sound that keeps dropping out and coming back**: the image is read too slowly (a slow card
  or network share).

## The title shows small empty boxes

The Display overlay draws plain ASCII only: `™`, accented letters and Japanese titles show as
one small empty box per character. The disc still reads normally.

## "There is no chapter available."

Next Chapter was pressed at the title's last chapter. The message goes after three
seconds and playback carries on: nothing is wrong.

## "Not available for this file."

Fast forward, rewind, Go To or A-B Repeat was pressed while playing a single `.mps` stream file. Such a
file has no seek table, so it plays from start to end only; load the whole disc image to
seek. Playback carries on.

## "The control panel needs the UMD Main."

Control Panel was pressed on a MiSTer running its stock Main program. The
[control panel](../playback/controls.md#control-panel) is drawn by the UMD Main that ships with
the core; every action on it also has its own button, so nothing is lost without it.

To have it, check that `MiSTer_UMD` is at the root of the SD card (`/media/fat/MiSTer_UMD`, not
in a folder), and that `/media/fat/MiSTer.ini` has the `[UMD]` section with `main=MiSTer_UMD`
([Install](../getting-started/install.md)). MiSTer switches Main programs when a core loads, so
load the UMD core again after editing the file.

## "Update the UMD Main for the control panel."

Control Panel was pressed with a UMD Main that has no control panel (an older one), or that is
not the version this core talks to. Install the UMD Main from the same release as the core.

## "Disc changed on the PSP. Leave USB mode and enter it again to play it."

The disc in the PSP was swapped while the PSP stayed in USB mode. The PSP sizes the file it
shares for the disc that was in the drive when USB mode started, so the new disc cannot be
trusted to read to its end. Leave USB mode on the PSP and choose USB Connection again: the new
disc then plays ([Playing a real UMD](../getting-started/psp-disc.md#changing-discs)).

## "The PSP's disc is a game, not a UMD Video."

The PSP shared a game disc over USB. Only UMD Video discs play; put a movie disc in the PSP,
then leave and re-enter USB mode.

## A PSP is connected but its disc does not play

- With the stock Main, the disc plays only through an MGL shortcut whose path names the PSP's
  USB drive: `/media/usb0` when it is the only one, higher with another USB drive connected
  ([Playing a real UMD](../getting-started/psp-disc.md#with-the-stock-main)).
- On the PSP, **Settings > Custom Firmware Settings > USB Device** must be **UMD**. If the
  MiSTer sees the PSP's Memory Stick (folders such as `PSP` and `MUSIC`), it is set to Memory
  Stick; some crashes reset it.
- An image you loaded from the file picker, or unloaded from the OSD, keeps its place until
  you swap the PSP's disc or re-enter USB mode.
- The UMD Main writes what it decided to `/tmp/umd_psp.log`: include it in a bug report.

## A PSP's disc keeps playing after the PSP is disconnected

On the stock Main, nothing watches the PSP: the MiSTer keeps the disc's file open and plays on
from what it still has in memory, for as long as that lasts, then the picture breaks up. Load
something else or open the MiSTer menu before leaving USB mode. With the UMD Main, playback
stops within about a second of the PSP leaving USB mode
([Playing a real UMD](../getting-started/psp-disc.md)).

## Playback from a PSP freezes, with the menu

The PSP's drive is not answering, usually because the disc is dirty or scratched. While a read
is outstanding the MiSTer's menu, the subtitles and the control panel wait for it too. Leave
USB mode on the PSP to end it, then clean the disc. If the PSP cannot play the disc from its
own Video column, the core cannot either.

## A disc starts straight into its film, without its menus

The disc menus run in the UMD Main ([Disc menus](../playback/disc-menus.md)). The core plays
the main title at once when:

- the MiSTer runs its stock Main: check `MiSTer_UMD` and the `[UMD]` lines as for the
  control panel above, then load the core again;
- [Disc Menus](../playback/settings.md) is set to **Off** (the option shows only while the UMD
  Main is running), or was changed after the image loaded: load the image again;
- the disc has no menus, or menus the core cannot run.

## Stop closed the disc and opened the file browser

With the disc menus running, Stop is the PSP's ○ button. During the film, when the disc does
not use it, it closes the disc as a PSP returns to its home screen, and the file browser
opens over [the disc screen](../playback/disc-menus.md#the-disc-screen). Close the browser (the
OSD button) and press Play/Pause, or load the image again: the disc goes on from where it
stopped ([Disc menus](../playback/disc-menus.md#during-the-film)). Pause with Select or
Play/Pause instead.

## A disc starts from the beginning instead of where I left it

With the UMD Main a disc remembers its place
([Going on where you left off](../playback/disc-menus.md#going-on-where-you-left-off)). It
starts afresh when:

- the title was played to its end;
- Stop was pressed on the disc screen, which forgets the place on purpose;
- the MiSTer was switched off within a few seconds of the place being saved;
- the MiSTer runs its stock Main, which keeps no places;
- with the disc menus, the disc's own script decides what to do with the place: most discs
  go back into the film, some open their menu first.

## Another core runs the UMD Main

MiSTer switches back to your usual Main when another core loads, but only if the `main=` it
finds for that core names a file that exists. A `main=` line in the `[MiSTer]` section that
points at a missing program leaves whichever Main ran last in charge until the next reboot.
The UMD Main is a full Main and does nothing extra outside the UMD core, so this is
harmless. To stop it, fix or remove that `main=` line.

## No subtitles, or subtitles dropped or late

- **No subtitles at all**: they are off when a title loads. Press Subtitle (S or F4); the
  balloon tag in the bottom-left corner says which track is on. `Off` right away means the
  title has no subtitles.
- **`subs >> 8` above 0** in the [diagnostic log](../playback/on-screen-messages.md#the-diagnostic-log):
  subtitle images were dropped. A damaged image can do this; if it happens on a good one,
  please [report it](reporting-a-bug.md).
- **`subs & 255` above 0**: subtitles were shown late. The first line after a jump may count
  here; a count that keeps climbing while a title plays straight through is worth
  [reporting](reporting-a-bug.md).

## A network share gives a black screen and no error

The share is mounted read-only. The framework opens images read-write regardless, so a
read-only mount fails silently. Mount it read-write or copy the image to the SD card.
