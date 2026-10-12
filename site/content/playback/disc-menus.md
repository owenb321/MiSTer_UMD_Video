# Disc menus

A UMD Video disc carries its own menus: the warnings and logos that open it, a main menu
with scene selection, set-up pages for the audio and subtitles, and the menu that comes up
when you press the menu button during the film. The core runs them the way a PSP does.

The disc menus run on the MiSTer's ARM, in the **UMD Main** that ships with the core
([Install](../getting-started/install.md)). On a stock Main, or with
[Disc Menus](settings.md) set to **Off**, the core skips the menus and plays the disc's main
title as soon as it loads.

## Starting a disc

Loading an image starts the disc as a PSP would: its warnings and logos, then its main
menu. Some discs play trailers first, several minutes of them on a few (*The Rock*,
*Lost*), exactly as the disc is authored; a few discs start the film by themselves and
show their menu when you press UMD Menu.

The [Menu Language](settings.md) setting picks the language of discs that carry their menus in several (as the PSP's **UMD Menu Language** setting does); a disc without
that language opens its English menu.

## Buttons in a menu

The PSP's buttons are on the core's buttons as follows (the "Pad" column of
[Controls](controls.md) says where each lands on your controller):

| PSP button | Core button | In a menu |
|---|---|---|
| D-pad | D-pad | Move between the menu's items |
| ✕ | Select | Choose the highlighted item |
| ○ | Stop | Back, where the disc offers it |
| □ | UMD Menu | The disc's menu (during the film too) |
| △ | Display | Whatever the disc does with it |
| Start | Play/Pause | Whatever the disc does with it, else play / pause |
| Select | Audio | Whatever the disc does with it |
| L / R | Prev Chapter / Next Chapter | Whatever the disc does with them |

The menus' own sound effects play as the disc sets them.

## During the film

- **UMD Menu** brings the disc's menu up over the film, as on the PSP. Choosing play from
  the menu goes on from where the film was (most discs; a disc's scene list plays the
  scene you pick).
- **Stop** is the PSP's ○: the disc may use it, and if it does not, the disc is closed and
  the file browser opens (the PSP's way back to its home screen). Load the image again to
  go on from where you stopped.
- Every other button works as in [Controls](controls.md): pause, chapters, fast forward and
  rewind, Go To, the audio track, subtitles. While Go To is open, Stop closes it rather than
  reaching the disc.
- A few discs keep an invisible page of their menu open through an episode they start (The
  Office). Chapters, fast forward, rewind and the audio track still work there, but Select
  does not pause: use Play/Pause.

## The disc screen

With the UMD Main installed, a stopped disc shows its own art instead of the idle screen, as
a PSP's home screen shows an inserted UMD: the disc's background picture over the whole
screen and, on a card across the lower part, its thumbnail, its title and what Play does
next: **Resume** and the time it goes on from, or **Play** when there is no place to go on
from. It appears when you press Stop on a disc played with **Disc Menus** set to **Off** (or a
disc without menus), when a title plays to its end, and after Stop closes a disc's menus.

- Play/Pause starts playing again from where it stopped. After the title's end it starts the
  title from the beginning. After Stop has closed a disc's menus the file browser opens over
  the disc screen: close it (the OSD button) and Play/Pause opens the disc again, its menus
  going on from where you left them, as choosing the disc on a PSP does.
- After Stop has closed a disc's menus, **Resume** shows the place the disc keeps for the film
  you were watching, and **Play** shows when you left from a menu. What Play then does is the
  disc's own choice: most discs go back into the film, some open their menu first.
- **Stop on the disc screen forgets the disc's place.** The card turns to **Play**, and Play/Pause
  starts the disc from the beginning: its main title, or with its menus its warnings and logos
  again, as a disc never played.
- A title the screen's lettering cannot show (a few discs have Japanese titles) is shown by
  the image's file name.
- On a 4:3 CRT at 480i the art is fitted as the disc menus are ([Analog Aspect](settings.md)).
- A subtitle on screen when you stop is not shown again when play resumes; the next one is.

## Going on where you left off

Each disc remembers where it was when you load another image or another core, or close
it with Stop: loaded again, it goes on from there, the way the disc's own script does it
(into the film, or back to its menu). The memory is kept on the SD card (`config/umd/`),
so it lasts when the MiSTer is switched off, which a PSP's does not. Switching off in the
middle of a film keeps the place from the last time you left the disc, not the moment the
power went: stop first to keep it.

With **Disc Menus** set to **Off** ([Settings](settings.md)) the UMD Main remembers the place
itself: a disc loaded again starts its main title where you paused it, stopped it, loaded
another image or core, or pressed the menu's Reset, with the audio track and the subtitles you
had chosen. You see the title's first moment before it jumps there. Give it a few seconds after
pausing or stopping before you switch the MiSTer off: a place saved just before the power goes
can be lost, and the disc then goes on from the place saved before it. Playing a title to its end
forgets the place, so the next load starts from the beginning.

To forget a disc's place yourself, press Stop on [the disc screen](#the-disc-screen) (Stop once to
reach it, again to forget).

## On a 4:3 CRT

A disc's menus are drawn for the PSP's 16:9 screen. On the interlaced (480i) output the
[Analog Aspect](settings.md) setting fits them to a 4:3 CRT: **Auto** and **Letterbox**
show the whole menu letterboxed, **Crop** shows its centre filling the screen (its edges cut
off), **Fit** shows it unchanged ([Analog and CRT output](../video/analog-crt.md)).

## What is not supported

- The PSP's own system panels other than its control panel (the Select overlay, the "this
  operation is not available here" message) are part of the PSP, not the disc, and are not
  reproduced. The control panel is: [Controls](controls.md#control-panel).
- Menus have been checked against a PSP on three discs (*Family Guy: Freakin' Sweet
  Collection*, *Akira*, *Austin Powers: The Spy Who Shagged Me*). On every other disc tested
  (88 images) the menus lead to the film and the UMD Menu button brings them back, but a disc
  may still show a menu differently from a PSP. A disc whose menus the core cannot run is
  played without them. [Reporting a bug](../reference/reporting-a-bug.md) helps.
- Menus are drawn at the PSP's own screen size and scaled up to the picture, as the PSP shows them;
  the film playing behind a menu stays at its full resolution.
- Only the parts of a menu that move are redrawn, so most menus animate smoothly. A menu where
  most of the screen moves at once (a full-screen fade, a large animated scene) can animate less
  smoothly than on a PSP; it still runs at the disc's own pace.
