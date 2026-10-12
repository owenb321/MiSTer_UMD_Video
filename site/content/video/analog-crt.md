# Analog and CRT output

The core can send a native **480i** picture (720x480 interlaced, 59.94 fields a second,
15.7 kHz) to an analog display: a CRT television or monitor through the MiSTer's analog
output (an analog I/O board, or a VGA-to-SCART / component / S-Video adapter), or a
scaler that takes 15 kHz video.

## Turning it on

The [Video Output](../playback/settings.md) option chooses the raster:

| Video Output | What the core sends |
|---|---|
| **Auto** (default) | 480i when `MiSTer.ini` sets up an analog display, 480p otherwise. |
| **Interlaced** | Always 480i. |
| **Progressive** | Always 480p (the HDMI output's native picture). |

**Auto** takes 480i when `MiSTer.ini` has any of `composite_sync=1`, `vga_mode=ypbpr`
(or the older `ypbpr=1`) or `vga_sog=1` without `vga_scaler=1`, or `direct_video=1`.
Auto settles while nothing is playing, so the raster never switches under a playing
title; a forced Interlaced or Progressive applies at once.

!!! note "S-Video and composite"
    `vga_mode=svideo` and `vga_mode=cvbs` are not passed to the core, so Auto cannot see
    them: set **Video Output** to **Interlaced**, or add `composite_sync=1`.

There is one raster: while 480i is selected, HDMI shows the same 480i picture, made
progressive by the MiSTer's scaler.

## What you see

- **Every field is a real field.** Film and progressive titles are split into their
  own fields, interlaced titles (TV series, trailers) are sent field by field as they were
  recorded, so a CRT shows them exactly as a television broadcast would. Nothing is
  deinterlaced on the analog output.
- **Field order is kept.** An interlaced title's first field of each pair is always sent on
  the raster field of the same parity, so motion never steps back and forth. When playback
  starts or after a seek this can hold the first picture for one extra field (1/60 s).
- **Pause shows one field.** A paused interlaced picture would flicker between two
  moments; while paused the core shows one of its fields on both raster fields instead
  (the missing lines rebuilt from the ones above and below), so the still is steady. Film
  and progressive pictures are shown whole.
- **Composite sync** follows the broadcast standard (equalising and serrated pulses), so
  televisions keep the two fields interlaced correctly rather than pairing them.
- **HDMI at 480i:** the [HDMI Deinterlace](../playback/settings.md) option picks Weave or
  Bob for the HDMI picture. The core's own Blend is a progressive-output setting and is
  hidden while 480i is selected.
- **The transport display moves inside the title-safe area** (the part of the picture every
  CRT shows, inside its overscan): the title, the icons, the chapter, the time and the progress
  bar are drawn nearer the middle than on the progressive output, so none of it is cut off.
- Subtitles stay where the disc puts them.

## Widescreen titles on a 4:3 television

Almost every UMD Video title is 16:9 widescreen. A 4:3 CRT shown that picture as it is
stretches it vertically (tall, thin faces), as a DVD player set to 16:9 output would. The
[Analog Aspect](../playback/settings.md) option corrects it:

| Analog Aspect | What you see | When to use it |
|---|---|---|
| **Auto** (default) | Letterbox for 16:9 titles, Fit for 4:3 titles | A 4:3 CRT: right for most people |
| **Fit** | The picture unchanged, filling the screen | A widescreen CRT or television set to its 16:9 mode |
| **Letterbox** | The whole picture at its true shape, three quarters of the screen's height, centred with black bars above and below | A 4:3 CRT, when nothing may be cut off |
| **Crop** | The centre three quarters of the picture's width, stretched to fill the screen: full height, no bars, the sides cut off | A 4:3 CRT, when a full screen matters more than the edges |

- **Auto never selects Crop**: cutting off part of the picture is always your choice.
- **Letterbox scales properly**: each new line is blended from the two nearest source lines,
  at its exact position in each field, not made by dropping lines.
- **Crop blends too**: each new column is blended from the two nearest source columns.
- **Only on the interlaced output.** On the progressive (480p) output the MiSTer's scaler
  shapes the picture, and the [Aspect Ratio](../playback/settings.md) option applies instead.
- **HDMI shows the same picture**: with Letterbox or Crop in effect, the HDMI output shows the
  letterboxed or cropped 480i picture at 4:3.
- **Subtitles are not scaled**: they keep their size and place on the screen, so under
  Letterbox a subtitle at the bottom of the picture appears in the lower black bar.
- The transport display is not scaled either.
- A picture that is not 720x480 (none has been found on a UMD Video disc) is always shown Fit.
- **The disc menus are fitted too**, as 16:9 pictures: Auto and Letterbox letterbox a menu,
  Crop crops it, Fit shows it unchanged ([Disc menus](../playback/disc-menus.md#on-a-43-crt)).

## Banding in dark scenes (Analog Dither)

The DE10-Nano's standard analog I/O board has a 6-bit video DAC: it shows 64 levels for each
colour, where the decoded picture has 256. Bright, detailed scenes hide this. Smooth dark
gradients do not: a night sky, a fade to black or a dim wall can break into visible
**bands** on a CRT, each one four levels wide.

The [Analog Dither](../playback/settings.md) option (Off by default) fixes this. **On** adds
a very fine pattern of tiny offsets just before the picture reaches the DAC. The television
blurs it into the in-between levels the DAC cannot output, so gradients come out smooth. The
two fields of an interlaced picture get opposite patterns. On a progressive picture the
pattern flips every frame.

- **Leave it Off on a board with a full 8-bit analog DAC** (a SuperStation, a 24-bit analog
  board). There are no bands to fix.
- On a 31 kHz VGA monitor (Video Output set to Progressive) the pattern is one pixel fine and
  may be faintly visible up close. Turn it off if you prefer that.
- It applies to RGB, component, S-Video and composite alike. Blanking, sync and the colour
  burst are never touched.
- **HDMI is never affected**, and neither is the analog output when `MiSTer.ini` sets
  `vga_scaler=1` (the scaled picture), which the core does not dither.
