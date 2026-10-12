# UMD images

The core plays a **`.iso` image of a UMD Video disc**. A UMD Video image is an ordinary
ISO9660 filesystem holding a `UMD_VIDEO/` directory: the playlist, the clip information
tables, and the `STREAM/*.MPS` files that carry the movie.

The core reads the filesystem itself: it finds `UMD_VIDEO/`, reads the disc's title,
and plays the **longest playlist**, which is the feature on every disc surveyed (on some
discs the first playlist is a short intro and the film comes later). A playlist can play
only part of a clip, and the core keeps to the start and end points it sets. On a few
discs the feature ends well before its file does (*Hackers* stops about seven minutes
early). The core reads from the seek point at or before each part's start and skips the
pictures before it, so the feature -- and every later part of a title made of several --
opens on its first picture and ends on its last.

## What is on the disc

- `UMD_VIDEO/PLAYLIST.UMD` lists the disc's titles (the feature, trailers, warnings) and
  their chapter marks.
- `UMD_VIDEO/CLIPINF/*.CLP` describes each clip: its audio and subtitle streams and a
  time-to-sector table used for seeking.
- `UMD_VIDEO/STREAM/*.MPS` is the movie itself: an MPEG program stream with H.264 video,
  ATRAC3plus audio and PNG subtitles.
- `UMD_VIDEO/RESOURCE/*.RCO` are the disc menus, written in a scripting language. The UMD
  Main runs them ([Disc menus](../playback/disc-menus.md)); without it the core plays the
  feature directly.

## A single stream file (`.MPS`)

The core also plays a bare `.MPS` file: one clip's `UMD_VIDEO/STREAM/*.MPS` copied out of an
image (a trailer, an episode, the feature on its own). With no playlist or clip table around
it, the file plays from its first picture to its last, and:

- pause, stop, the audio track and subtitles work; the tracks offered are
  the ones the stream has shown so far, with no language names;
- fast forward, rewind, Go To and the disc's menus are not available
  (`Not available for this file.`), and Next Chapter finds no chapter;
- the time played is shown, but not the length (the progress bar stays empty).

`.PMF` files (the movies inside PSP games) are not supported: their sound is 44.1 kHz, which
the core does not decode, and the picker does not offer them.

## Where to put images

Anywhere the file picker can reach. `games/UMD/` on the SD card is the convention; a
network share works too, as long as it is mounted read-write (see
[troubleshooting](../reference/troubleshooting.md#a-network-share-gives-a-black-screen-and-no-error)).
