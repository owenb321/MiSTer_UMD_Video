# Video output

UMD Video movies are 720x480 anamorphic 16:9, almost always 23.976 fps film carrying its
own pulldown flags.

- **HDMI**: the core outputs a 720x480 progressive raster at 59.94 Hz (or the 480i one,
  below) and the MiSTer scaler handles the rest. Film cadence (3:2) is presented from the stream's own flags.
- **Interlaced titles** (TV series, trailers, extras) are shown the way the
  [Deinterlace](../playback/settings.md) setting says: Weave, Bob or Blend. Film and
  progressive pictures are never deinterlaced. On the 480i raster, fields are sent as
  fields.

- **Analog**: a native 480i raster for CRTs, chosen by the
  [Video Output](../playback/settings.md) option (Auto follows `MiSTer.ini`); while it is
  selected HDMI shows the same 480i picture. See [Analog and CRT output](analog-crt.md).

A picture taller than 480 lines (none has been found on a UMD Video disc) is shown with
its bottom cut off.

## Letterboxed 4:3 titles (Zoom)

A few discs store a widescreen film letterboxed inside a 4:3 picture, with black bars
recorded above and below it (*Short Circuit*, for example). Auto shows such a title at 4:3,
its true shape, so a 16:9 television adds black bars at the sides too and the film sits in
a small window.

Set [Aspect Ratio](../playback/settings.md) to **Zoom** to fill the screen. The core sends
the scaler the middle 360 of the picture's 480 lines and presents them at 16:9. The film
keeps its true shape and most of the recorded bars are cut. Things to know:

- Zoom acts on every 4:3 title while it is selected. A title that fills its 4:3 picture
  loses its top and bottom eighth, so switch back to Auto for it.
- Widescreen titles, the disc's menus and a stopped disc's screen are shown as in Auto.
- The transport display moves inside the zoomed picture. Subtitles are moved up into it,
  never cut. The control panel's subtitle moves with them under the UMD Main.
- Zoom applies to the progressive (480p) output. On the interlaced (480i) output it acts as
  Auto, because a 4:3 CRT already shows a letterboxed 4:3 title as it should.
- On the analog output at 480p, the cut lines are black: the picture shows the same band,
  letterboxed.
- With `direct_video` in `MiSTer.ini` the HDMI output carries the analog signal, so Zoom
  cannot fill the screen there: forced to the progressive output, it shows the band letterboxed.
