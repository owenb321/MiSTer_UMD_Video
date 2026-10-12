# Audio formats

UMD Video discs carry **ATRAC3plus** audio, typically stereo at 48 kHz, in one to three
language tracks.

The core decodes the audio in FPGA fabric and plays it in step with the picture: each
stretch of sound starts at the moment its time stamp names on the display's clock, and
stays there, because sound and picture run off the same clock.

- It starts on the **first audio track** the title declares (the lowest-numbered one). On
  the discs surveyed that is the disc's main language. The Audio button (A or F3 on a
  keyboard) steps through the others ([Controls](../playback/controls.md)); the new track's
  sound starts at its next time stamp, up to about two seconds after the press.
- With the disc menus, a disc's own set-up page can choose the track
  ([Disc menus](../playback/disc-menus.md)). A disc picked up where you left it keeps the
  track you had chosen.
- Stereo at 48 kHz, on HDMI and the analog audio output.
- If the sound falls behind (the core could not read the image fast enough), it goes
  quiet briefly and comes back in step, rather than playing late.
- A stretch the decoder cannot decode (a damaged image, or a track that is not 48 kHz
  stereo) is played as silence, 43 ms at a time, and counted in the
  [diagnostic log](../playback/on-screen-messages.md#audio-refusals).

There is no A/V offset setting: sound and picture run off the same clock, so there is no
drift to correct.
