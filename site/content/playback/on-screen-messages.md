# On-screen messages

## What the player shows

The player draws its own small display over the picture, in the style of the PSP's video
player: nothing while a title simply plays, and a few seconds of feedback when you press
something.

- **Bottom left: what the player is doing.** A play symbol for three seconds when a title
  starts or play resumes. While paused, stopped, fast forwarding or rewinding, the
  symbol stays up for as long as that lasts; fast forward and rewind show their speed
  (1 to 3) in a small circle beside it.
- **`A-B` beside it** while [A-B Repeat](controls.md#a-b-repeat) is being set: from the first
  press the symbol and `A-B` stay up, the `B` blinking; at the second press the `B` stays lit for
  two seconds, then both go while the stretch repeats (with the Display overlay on, or paused,
  `A-B` shows beside the symbol).
- **Above it, for three seconds, a caption:**
    - `Forward 2` / `Reverse 1` when fast forward or rewind starts or changes speed;
    - `Chapter 12` after Next or Prev Chapter: the chapter it goes to;
    - a note symbol, the track number and its language (`2 Japanese`) after the Audio button:
      the track playing at the first press, the new one when a second press changes it. A
      language the player has no name for shows as its two-letter code.
    - a speech balloon and the subtitle track's number and language (`1 English`), or `Off`,
      after the Subtitle button, the same way (a disc's menus changing the subtitles themselves
      show nothing, as on a PSP).
- **The message strip.** A dark strip with one line of text, just above the chapter and time,
  for three seconds. The messages:

| Message | Meaning |
|---|---|
| `There is no chapter available.` | Next Chapter was pressed at the title's last chapter. Nothing else happens; playback carries on. |
| `The control panel needs the UMD Main.` | Control Panel was pressed on the stock Main: the [control panel](controls.md#control-panel) is drawn by the UMD Main that ships with the core. Every action on it has its own button too. |
| `Update the UMD Main for the control panel.` | Control Panel was pressed with a UMD Main that does not have the control panel, or is a different version from the core's. |
| `Not available for this file.` | Fast forward, rewind, Go To, A-B Repeat or a disc menu's jump was asked of a single stream file (`.mps`), which has no table to seek with ([A single stream file](../getting-started/images.md#a-single-stream-file-mps)). Playback carries on. |
| `This disc cannot be played.` | The core stopped on the disc: the image could not be read (damaged, incomplete, or not a UMD Video disc), or its video uses a coding this core does not decode. The [diagnostic log](#the-diagnostic-log) says which ([troubleshooting](../reference/troubleshooting.md#this-disc-cannot-be-played)). |

- **The Display overlay** (the [Display button](controls.md), or the D key) stays until you press it again: the
  disc's title across the top, and at the bottom `Chapter n`, the time played and the
  title's length (`00:20:14/02:05:15`, the time played in blue), and a progress bar that
  fills in blue. A title with no chapters shows the time alone. A title longer than 100
  hours shows three hour digits; the display stops at `999:59:59+`.
- **Go To** ([Controls](controls.md#go-to)) draws the Display overlay with its bottom line
  turned into two boxes: `Chapter n` and the time to jump to, over the title's length. The
  box you are on is lighter; the number being changed is lighter still, with a small arrow
  above and below it. A blue marker above the progress bar shows where the jump lands.
  While Go To is open the captions above (`Chapter 12`, the track) are not shown: the line
  is Go To's.

The title is shown as the disc stores it. Characters outside plain ASCII (such as `™`
or Japanese text) show as a small empty box, one per character, and a title too long for
the line ends in `...`.

## Messages from the UMD Main

A few messages come from the UMD Main rather than the player. They show in MiSTer's small
message box in the corner of the screen, for five seconds:

| Message | Meaning |
|---|---|
| `Disc changed on the PSP. Leave USB mode and enter it again to play it.` | The disc in a PSP connected over USB was swapped without leaving USB mode. The disc is unloaded; leave USB mode on the PSP and choose USB Connection again ([Playing a real UMD](../getting-started/psp-disc.md#changing-discs)). |
| `The PSP's disc is a game, not a UMD Video.` | The PSP connected over USB holds a game disc. It is not loaded. |

## The diagnostic log

The core counts what it reads and decodes, and the UMD Main can write those counts to a file
for a bug report. To turn it on, put an empty file named `umd_hil` in the root of the SD card
(`/media/fat/umd_hil`). While the UMD core runs, the UMD Main then writes
`/tmp/umd_telem.json` four times a second (it lives in the MiSTer's memory: copy it off over
the network or ssh before switching the MiSTer off). Delete `umd_hil` to turn it off again.

Each value in the file is a 16-bit number. The ones a report most often needs, with how to
read the code out of them (`>>` shifts right, `& 15` keeps the low four bits):

| Field | What it holds |
|---|---|
| `reader` | The reader's error: `(reader >> 6) & 15`, listed [below](#reader-errors). `0` while all is well. |
| `refused` | Video streams refused (`refused >> 8`) and the last reason (`(refused >> 4) & 15`), listed [below](#video-refusals); pictures skipped as too large (`refused & 15`). |
| `fe_err` | Video parsing errors (`fe_err >> 4`) and the last code (`fe_err & 15`), listed [below](#video-errors). |
| `recon_err` | Picture decoding errors (`recon_err >> 4`) and the last code (`recon_err & 15`), listed [below](#picture-errors). |
| `aud_err` | Sound frames refused (`aud_err >> 8`) and the last reason (`aud_err & 255`), listed [below](#audio-refusals). |
| `warn` | The reader's warnings (`warn >> 13`: `4` a playlist implausibly long, `2` the title longer than 128 bytes and cut, `1` the disc has no readable title) and pictures the stream told the decoder to discard unshown at a fresh start (`warn & 255`). |
| `subs` | Subtitle images dropped (`subs >> 8`) and shown late (`subs & 255`). Both should stay `0`. |

## Reader errors

The reader's error in the [diagnostic log](#the-diagnostic-log) (`reader`). The disc stops and
`This disc cannot be played.` shows.

| Code | What it means |
|---|---|
| 1 | The file is too small to be a disc image. |
| 2 | The file is not an ISO 9660 disc image. |
| 3 | A directory in the image is damaged. |
| 4 | The image has no `UMD_VIDEO` folder: it is not a UMD Video disc (a PSP game, for example). |
| 5 | `PLAYLIST.UMD` is missing or is not a UMD Video playlist. |
| 6 | `PLAYLIST.UMD` is damaged, or lists no playlist. |
| 7 | A clip the playlist names has no `CLIPINF` entry. |
| 8 | A clip's `CLIPINF` entry is damaged. |
| 9 | A clip's stream file (`STREAM/*.MPS`) is missing. |
| 10 | A stream file is stored interleaved, which the core does not read. |
| 11 | A file is split into pieces in a way the core does not follow. |
| 12 | A stream file is 4 GB or larger (a UMD clip is under 1.8 GB), or a `.pmf` file (not supported) has a damaged header. |

What to do about each is on the [troubleshooting](../reference/troubleshooting.md#this-disc-cannot-be-played) page.

## Video refusals

The `refused` count and code in the [diagnostic log](#the-diagnostic-log). A refusal is a legal
H.264 feature that no UMD Video disc surveyed uses and this core does not decode; the unit is
skipped rather than decoded as garbage, the count keeps climbing while such units arrive, and
`This disc cannot be played.` shows. The codes are hexadecimal (`A` is 10).

| Code | The stream uses |
|---|---|
| 1 | a chroma format other than 4:2:0 |
| 2 | more than 8 bits per sample |
| 3 | scaling matrices |
| 4 | MBAFF (macroblock-adaptive frame/field coding) |
| 5 | CAVLC entropy coding |
| 6 | slice groups (FMO) |
| 7 | the 8x8 transform (High profile) |
| 8 | redundant pictures |
| 9 | SP or SI slices |
| A | data partitioning |
| B | scalable or multiview coding (SVC / MVC) |
| C | a picture wider or taller than 128 macroblocks (2048 pixels) |

## Video errors

The `fe_err` count and code in the [diagnostic log](#the-diagnostic-log). An error is a stream that breaks the H.264
rules, or a unit cut short; the unit is skipped and parsing continues with the next.

| Code | What it means |
|---|---|
| 1 | a value outside the range the standard allows |
| 2 | a slice names a picture parameter set that was never received |
| 3 | a picture parameter set names a sequence parameter set that was never received |
| 4 | a header ran past the end of its unit |
| 5 | an illegal reference-list modification |
| 6 | the arithmetic decoder lost sync |
| 7 | a slice ran past the end of its picture |
| 8 | an empty unit |
| 9 | a unit with the forbidden bit set |

## Audio refusals

The `aud_err` count and code in the [diagnostic log](#the-diagnostic-log) (the code in hexadecimal below). The decoder refused a sound frame; it plays as
43 ms of silence and the next frame is decoded as usual.

| Code | What it means |
|---|---|
| 01 | a frame that does not begin as ATRAC3plus frames must |
| 02 | a channel layout beyond stereo (multichannel) |
| 03 | a channel layout other than one stereo pair (mono, or an unexpected order) |
| 04 | an out-of-range number of frequency bands |
| 05-0A | an out-of-range coding parameter (word lengths, scale factors, code tables) |
| 0B-0D | out-of-range gain-control data |
| 0E | more tonal components than the format allows |
| 0F | an invalid tonal-component mode |
| 10 | a sample rate other than 48 kHz |
| 11 | a track that is not stereo |
| 12 | a code that is in no code table (damaged data) |

## Picture errors

The `recon_err` count and code in the [diagnostic log](#the-diagnostic-log). The picture decoder met a reference it
cannot resolve; the affected block is left as its prediction and decoding continues.

| Code | What it means |
|---|---|
| 1 | a slice names a picture parameter set that was never received |
| 2 | a picture parameter set names a sequence parameter set that was never received |
| 3 | a stream that switches between more than two sequence parameter sets of one rare kind (picture order type 1) |
| 4 | a slice carries more reference-marking commands than the decoder holds |
| 5 | a gap in the picture numbering |
| 6 | no free picture store: the stream keeps more reference pictures than the standard allows, or the screen held on to its pictures for longer than four frames during playback (a pause, a stop or a chapter jump holds them on purpose and is never counted) |
| 7 | the oldest reference picture must be dropped and every reference is a long-term one |
| 8 | a reference-marking command names a picture that does not exist |
| 9 | a reference-list change names a picture that does not exist |
| A | a macroblock names more reference pictures than it has parts |
| B | a macroblock names a reference picture beyond the end of its list |
| C | a reference list entry has no picture behind it |
