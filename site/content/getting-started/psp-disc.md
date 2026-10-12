# Playing a real UMD

No UMD drive exists for a PC or a MiSTer, but a PSP is one. A PSP running custom firmware
can share the disc in its drive over USB, and the core plays it like an image.

## What you need

- A PSP with a UMD drive (not a PSP Go) running custom firmware with a "UMD" USB device. This
  page was written with **ARK-5**.
- A USB cable from the PSP to one of the MiSTer's USB ports.
- For the smoothest use, the **UMD Main** ([Install](install.md)). Without it, the disc plays
  through an MGL shortcut you make yourself (below).

## Set up the PSP

1. On the PSP, go to **Settings > Custom Firmware Settings** and set **USB Device** to
   **UMD**. Leave **USB Read-Only** on **Auto**.
2. Put a UMD Video disc in the PSP and wait for its icon to appear in the Video column.
3. Connect the cable and choose **USB Connection** on the PSP.

The MiSTer now sees one file, `UMD9660.ISO`, on a USB drive: the disc in the PSP's drive.

## With the UMD Main

Open **UMD** from the MiSTer menu. The core finds the PSP on any of the MiSTer's USB drives
and plays its disc, with no file to pick. The disc menus, going on where you left off, and
the [disc screen](../playback/disc-menus.md#the-disc-screen) all work as for an image.

- **Connecting the PSP while the core is open**, or entering USB mode, plays its disc. This
  replaces an image you loaded from the file picker.
- **Leaving USB mode** or unplugging the PSP stops playback and brings back the idle
  screen.
- **An image you load from the file picker** while the PSP is connected plays as usual. The
  PSP's disc does not take over again until you swap its disc or re-enter USB mode.
- **Unloading the disc from the OSD** keeps it unloaded until you swap its disc or re-enter
  USB mode.

## With the stock Main

The MiSTer's file picker cannot reach the PSP's file, but an MGL shortcut can
([Launching from an MGL](loading.md#launching-from-an-mgl)). Save these lines as a text file
named, for example, `UMD (PSP disc).mgl` in `_Other` on the SD card, next to the core:

```xml
<mistergamedescription>
  <rbf>_Other/UMD</rbf>
  <file delay="2" type="s" index="0" path="/media/usb0/UMD9660.ISO"/>
</mistergamedescription>
```

It then shows under **Other** in the MiSTer menu, and opening it plays the PSP's disc. The path
is `/media/usb0` when the PSP is the only USB drive. If you also have another USB drive
connected, the PSP may be `/media/usb1` or higher: change the number to match.

The stock Main does not notice the PSP going away. If you leave USB mode or unplug the PSP
while a disc plays, playback carries on for a while from what the MiSTer still has in memory,
then breaks up. Stop first: load something else, or open the MiSTer menu.

## Changing discs

**Leave USB mode on the PSP, swap the disc, then choose USB Connection again.**

The PSP builds the file it shares when USB mode starts, sized for the disc in the drive at
that moment. If you swap discs without leaving USB mode, the file keeps the old disc's size,
and the new disc might not be readable to its end. The UMD Main detects the swap, stops,
and shows `Disc changed on the PSP. Leave USB mode and enter it again to play it.`

## Good to know

- **The PSP's drive reads at its own speed.** Playback is unaffected: the drive reads several
  times faster than any film plays. Jumps take longer than from an image, though: a chapter
  jump or a fast-forward step takes up to two seconds while the drive seeks.
- **A dirty or scratched disc** can stall the PSP's drive. While it is stalled, the MiSTer's
  menu and the subtitles freeze too, until you leave USB mode on the PSP. Clean the disc. If
  the PSP cannot read it from its own Video column, the core cannot either.
- **A game UMD** is not played. The UMD Main shows `The PSP's disc is a game, not a UMD Video.`
- If the PSP comes up as its **Memory Stick** instead (the menu shows a `PSP` and `MUSIC`
  folder), **USB Device** is set to Memory Stick. Some crashes reset it, so check the setting.
