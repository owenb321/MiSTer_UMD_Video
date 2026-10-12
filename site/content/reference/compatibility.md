# Compatibility

Current as of **the unreleased development build**.

## Formats

| | Status |
|---|---|
| UMD Video `.iso` | Finds the main title (the longest playlist) and plays it: the H.264 pictures decoded faster than real time on every disc tested and shown each at its time, with the first audio track's sound in step. Each part of the playlist plays between the start and end points the playlist sets ([UMD images](../getting-started/images.md)). Pause, stop, the chapter buttons, fast forward / rewind, Go To and A-B Repeat work ([Controls](../playback/controls.md)), on titles of several parts too. The audio track can be changed, and the player shows what it is doing over the picture ([On-screen messages](../playback/on-screen-messages.md)). |
| Bare `.MPS` files | A clip's stream file on its own plays from start to end with its sound; pause, stop, the audio track and subtitles work. Fast forward / rewind, Go To, A-B Repeat and chapters are not available, and the length is not shown ([A single stream file](../getting-started/images.md#a-single-stream-file-mps)). |
| `.PMF` files (PSP game movies) | Not supported, and not offered by the picker: their sound is 44.1 kHz, which the core does not decode. |
| Disc menus (RCO) | Run as on a PSP, with the UMD Main: the startup warnings and logos, the main menu, scene selection, set-up pages, the menu during the film, going on where you left off ([Disc menus](../playback/disc-menus.md)). Checked against a PSP on three discs; on every other disc tested (88 images) the menus lead to the film and come back with UMD Menu. |
| Control panel (the PSP's pop-up panel) | With the UMD Main: every action as an icon, over the film or a disc menu, subtitles kept under it ([Controls](../playback/controls.md#control-panel)). Every action also has its own button. |
| Physical UMD discs | Through a PSP with custom firmware (ARK-5 tested), shared over USB as its "UMD" USB device: with the UMD Main the disc is found and played without a file to pick, and a disc changed on the PSP is noticed; with the stock Main, through an MGL shortcut the manual shows how to make. Jumps wait for the PSP's drive to seek, up to about two seconds ([Playing a real UMD](../getting-started/psp-disc.md)). |

## Video

Pictures are decoded faster than real time and shown in their presentation order, each
at its own time: the core follows the disc's time stamps and each picture's display
structure, so film shows its 3:2 cadence and progressive film its 2-3 refresh rhythm on
the 60 Hz output.

UMD Video discs use H.264 Main profile, Level 3.0, at 720x480. Pictures are coded in one
of three ways, and a single disc often mixes them:

- **progressive film** (23.976 frames per second);
- **film with 3:2 pulldown** (most feature films);
- **interlaced fields** (most trailers and extras, and the main title of every TV-series
  disc and every European import surveyed, for example *The Dark Knight*, *The Simpsons
  Movie*, *South Park* and *Family Guy*).

Interlaced fields hold one of two things. Some are true video (*The Office*, the concert
discs). Many are **film stored as fields**, with the 3:2 pulldown already applied: about 15
main titles, including *The Dark Knight*, *The Simpsons Movie*, *GoldenEye*, *South Park* and
*Family Guy*. Nothing in the stream says which.

All of them are decoded and shown. On the progressive output, the core recognises film
stored as fields by its 3:2 rhythm. It then shows each film frame whole, whatever the
[Deinterlace](../playback/settings.md) setting, with no combing.

- Recognition takes a second or two of motion.
- At a cut it can show one combed picture. It then shows the Deinterlace setting until it
  recognises the rhythm again.
- A few animated titles move too little for it to recognise, and are shown as the setting
  says.

Some discs store a widescreen film letterboxed inside a 4:3 picture (*Short Circuit*).
It is shown at 4:3, as authored; **Zoom** in [Aspect Ratio](../playback/settings.md) fills
a 16:9 screen with it ([Video output](../video/output.md#letterboxed-43-titles-zoom)).

True interlaced video is shown the way the setting says (Weave, Bob or Blend). Film and
progressive pictures coded as frames are never deinterlaced. A lone field without its
partner is always shown bobbed. The stream itself says which pictures are fields, so the choice is never a
guess; the one case it cannot help with is a picture coded as a whole frame but marked as
interlaced (none has been found on a UMD Video disc), which is shown woven in every mode.
Streams that use features no
UMD Video disc has been seen to use (CAVLC entropy coding, MBAFF, the 8x8 transform and
the rest of the list on the [on-screen messages](../playback/on-screen-messages.md#video-refusals)
page) are reported on screen as a `REF` code rather than decoded.

On the 480i output fields are sent as fields, each pair's first field on the raster field
of its own parity. A stream whose fields stop alternating mid-title (a lone field between
pairs, as at an edit) is then shown one field (1/60 s) behind its timing until the next
seek or the next such break; the order of the fields stays right.

A stream made only of single interlaced fields with no partners (none has been found on
a UMD Video disc) plays at the output's maximum rate, so after a stall it can take up
to three seconds to get back in step.

Many discs carry an occasional time stamp that disagrees with the pictures around it
(usually a few hundredths of a second late, rarely early). The core recognises a lone
time stamp like this and keeps the picture's normal timing, so playback runs smoothly
through it.

Colour is stored at half the picture's resolution, as in all H.264 video. The core blends
it smoothly between the stored samples at the standard position (every UMD Video disc uses
it). A stream that declares another position (none has been found) shows its colour half a
pixel off. Interlaced pictures are blended within each field, at the field's own colour
positions, when shown with **Weave** (and when film stored as fields is shown whole); with
**Bob** or **Blend**, and on the 480i output, the colour is blended only along each line.
Under **Crop** in [Analog Aspect](../playback/settings.md) and inside a disc menu's video
window it is shown as stored.

## Audio

ATRAC3plus, stereo, 48 kHz, as on every surveyed disc (four bitrates are in
use, from about 64 to 192 kbit/s), decoded in fabric and played in step with the
picture. Discs carry up to five audio languages; the core plays the first one the
title declares, and the Audio button (or the A key) steps through the others
([Controls](../playback/controls.md)). The sound of the new track starts at its next
time stamp, up to about two seconds after the press.

Mono and multichannel ATRAC3plus, and sample rates other than 48 kHz, are not found on
UMD Video discs; the core plays such a stretch as silence and counts it.

## Subtitles

Discs carry subtitles as small images, up to 29 languages per film. The core shows them
over the picture at their times, as the disc places them. They are off when a title
loads; the Subtitle button (S or F4 on a keyboard) turns them on at the first track the
title offers, steps through the others, and turns them off again
([Controls](../playback/controls.md)).

- After a jump (a chapter, fast forward or rewind), a subtitle that was already on screen at
  the landing point may not show: the disc sends each line ahead of its time, and the core
  starts from the jump. The next line shows as usual.
- The Display overlay draws over the bottom of the picture, and over a subtitle there.

Subtitles are decoded by the core itself, so they work on the stock Main as well as with the
UMD Main ([Install](../getting-started/install.md)). With the UMD Main, an open control panel
keeps the subtitle under it, as the PSP does.
