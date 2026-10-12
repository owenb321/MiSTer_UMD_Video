# Controls

The buttons follow the PSP's own video player: Start plays and pauses, the bottom button
pauses (and chooses in a disc menu), the right button stops, the shoulder buttons skip chapters and the D-pad fast
forwards and rewinds. The "Pad" column is where each button lands by default on MiSTer's
SNES-style pad layout (A bottom, B right, X top, Y left); remap any of them in the MiSTer
OSD's "Define buttons".

| Button | Pad | Keyboard | Action |
|---|---|---|---|
| Play/Pause | Start | Space | Play, and pause; press again to go on. The picture and the sound stop together and pick up exactly where they left off. From Stop, play from where it stopped. |
| Select | A | Enter | In a disc menu, choose the highlighted item (the PSP's ✕ button; not the pad's own Select button, which is Audio). In playback, the same as Play/Pause: pause, press again to go on; from Stop, play from where it stopped. During fast forward or rewind, go back to normal play. |
| Stop | B | Q, Esc | Stop: the idle screen replaces the picture (with the UMD Main, [the disc screen](disc-menus.md#the-disc-screen)). Play/Pause resumes from exactly where it stopped. With the UMD Main, Stop again on the disc screen forgets the disc's place. |
| Prev Chapter | L | P, Page Up | Go back to the start of the current chapter. Pressed within one second of a chapter's start, go to the chapter before it. At the first chapter, restart it. |
| Next Chapter | R | N, Page Down | Go to the start of the next chapter. At the last chapter the player says "There is no chapter available." and playback carries on. |
| Audio | Select | A, F3 | The first press shows the audio track playing, its number and language, for three seconds. Pressed again while that shows, the next audio track the title offers, in turn. |
| Display | -- | D | Show or hide the Display overlay: the disc's title, the chapter, the time and a progress bar ([On-screen messages](on-screen-messages.md)). Also on the [control panel](#control-panel). |
| UMD Menu | Y | M, F1 | The disc's own menu ([Disc menus](disc-menus.md): needs the UMD Main). |
| Subtitle | -- | S, F4 | The first press shows the subtitles' state: the track's number and language, or Off, for three seconds. Pressed again while that shows: subtitles on, then each subtitle track the title offers in turn, then off again. Subtitles are off when a title loads. |
| Go To | -- | G, F2 | Jump to a chapter or a time ([Go To](#go-to), below). Press again to close it. |
| Control Panel | X | L | Open or close the control panel: every action, chosen with the D-pad ([Control panel](#control-panel), below). Needs the UMD Main. |
| D-pad Right | -- | Right arrow, F, Tab | Fast forward. Each further press goes faster, up to speed 3. |
| D-pad Left | -- | Left arrow, R, Backspace | Rewind. Each further press goes faster, up to speed 3. |
| A-B Repeat | -- | B | Repeat a stretch of the title over and over ([A-B Repeat](#a-b-repeat), below). Also on the [control panel](#control-panel). |

With the disc menus running, the buttons are the PSP's in a menu, and Stop is the PSP's ○
during the film: see [Disc menus](disc-menus.md#buttons-in-a-menu).

Every button shows what it did in the bottom-left corner of the picture
([On-screen messages](on-screen-messages.md)).

Chapter presses less than half a second apart count together: three quick presses of
Next move three chapters in one jump. The picture holds while the core finds the chapter,
then opens on the chapter's first picture. Expect a second or two of held picture on a
jump; the sound starts with the new picture.

## Go To

Go To jumps to a chapter or to a time, as the PSP's Go To does. Press it while a title plays
or is paused; it has no button on the pad by default (give it one in "Define buttons", or
use G / F2).

Two boxes open above the progress bar: **Chapter n** and the time (a title without chapters
has the time alone). The chapter box is highlighted first.

- **Left / Right** move between the two boxes.
- **Select** opens the highlighted box:
    - in the chapter box, **Up / Down** step the chapter number;
    - in the time box, **Left / Right** move between hours, minutes and seconds and
      **Up / Down** change the one highlighted (each wraps round).
- **Select** again jumps there, and Go To closes.
- **Stop**, or **Go To** again, closes it without jumping. UMD Menu closes it and opens the
  disc's menu.

A small blue marker above the bar shows where the jump will land. It is not shown for a
chapter in another part of a title that plays several videos one after another.

The time is that of what is playing: a video chosen on its own from a disc's menu counts
from 0:00:00 to its own length, a "play all" counts across every video. A time past the end
plays the last moment and ends the title, as reaching the end does (with the disc menus,
the disc goes back to its menu).

While Go To is open the D-pad, Select and Stop work Go To, not the player; the other
buttons work as usual.

## A-B Repeat

A-B Repeat plays one stretch of the title again and again, as the PSP's does. It has no pad
button: use the keyboard's B, or A-B Repeat on the [control panel](#control-panel).

1. Press **A-B Repeat** where the stretch should start (point A). The play symbol and `A-B`
   show in the bottom-left corner, the `B` blinking.
2. Press it again where the stretch should end (point B). The `B` stops blinking, and after
   two seconds the symbols go. From then on, each time playback reaches B it jumps back to A.
3. Press it a third time to stop repeating; playback carries on from where it is. Clear, on the
   control panel, stops it too.

Point B must come after point A: a press at or before A does nothing.

While it repeats:

- **Next Chapter** and **Prev Chapter** both jump back to A.
- **Fast forward**, **rewind** and **Go To** do nothing.
- **Pause** pauses, and the repeat goes on after Play/Pause.
- **Stop** ends the repeat; Play/Pause then resumes from where it stopped, without it.

Between setting A and setting B every button works as usual, so you can fast forward to the
point you want as B: go back to normal play first (Select or Play/Pause), as A-B Repeat does nothing
during fast forward or rewind. Each jump back to A takes a moment, as a chapter jump does: the picture
holds and the sound pauses briefly. Loading another disc, the end of the title or a disc menu
ends the repeat too. On a single stream file (`.mps`) A-B Repeat says
`Not available for this file.`

## Control panel

The control panel is the PSP's pop-up panel: every action as an icon, chosen with the D-pad, so
nothing needs remembering. Every action on it also has its own button.

It needs the UMD Main ([Compatibility](../reference/compatibility.md)). On the stock Main, Control
Panel shows `The control panel needs the UMD Main.`; with a UMD Main too old for it,
`Update the UMD Main for the control panel.`

**Control Panel** opens it over the picture, the cursor on Display. Three rows of icons:

| Top row | Middle row | Bottom row |
|---|---|---|
| UMD Menu, Go To, Audio, Subtitles, Display | Previous Chapter, Next Chapter, Fast Reverse, Fast Forward, Play, Pause, Stop | A-B Repeat, Clear |

The selected icon is white; its name shows under the rows.

- **Left / Right** move along a row, going round at its ends; **Up / Down** move to the row above
  or below, going round from the bottom row to the top.
  Icons that do nothing at the moment are dark and skipped: Subtitles on a title without
  subtitles, UMD Menu without the disc's menus.
- **Select** does the selected action, exactly as its own button would, and the panel
  stays open, so you can step through chapters or tracks with it. Audio and Subtitles, like
  their buttons, show the current track at the first press and change it at the next.
  - **Play** plays and **Pause** pauses; neither toggles, so Pause on a paused title leaves it
    paused.
  - **Clear** stops [A-B Repeat](#a-b-repeat), whether only A or both points are set.
  - **Stop** and **UMD Menu** close it.
  - **Go To** hides it while you pick a chapter or a time; it comes back once the jump has
    landed, or at once if you back out.
- **Stop** (the button) or **Control Panel** again closes it.
- The other buttons work as usual while it is open: Play/Pause, the chapter buttons, UMD Menu.

Subtitles keep showing under the open panel. While it is open a new subtitle line may appear
a frame or two late.

Over a disc's own menu, Control Panel opens the panel too. Only UMD Menu, Display and Stop work
there (the bottom row is dark and skipped): Stop leaves the disc, as Stop does at a menu's top page.

Over a stopped title the panel shows on a black background, not over the idle screen (over
[the disc screen](disc-menus.md#the-disc-screen) when the UMD Main shows one).

## Fast forward and rewind

Fast forward and rewind run at three speeds, about 20, 33 and 55 times normal, as on the
PSP. The picture jumps from one key picture to the next (roughly every second or two of
the film), and the sound is off.

- Play/Pause, Select or the opposite arrow goes back to normal play from the picture on
  screen, as the PSP's ✕ does.
- Stop stops there; Play/Pause resumes from it.
- Next / Prev Chapter work from the picture on screen.
- At the end of the title fast forward goes back to normal play, and the last seconds play
  out. At the start of the title rewind goes back to normal play from the beginning.

The D-pad does nothing while the MiSTer OSD is open.

## Remote controls

Every action has a keyboard key (the table above), so anything that presents itself to the
MiSTer as a keyboard can drive the player, with nothing to set up in the core:

- a **FLIRC USB** receiver, which learns whatever IR remote you have: teach each remote
  button the key in the table above;
- a **2.4 GHz media remote** (the small "air mouse" style dongles);
- the receiver built into a **console dock**;
- any **USB keyboard**.

A **TV remote over HDMI-CEC** works too: MiSTer passes its buttons to the core as keys.
Play/Pause, Stop, OK (Select), the arrows, Fast Forward and Rewind, the page / channel keys
(chapters) and the four colour keys (red Go To, green Audio, yellow Subtitle, blue UMD Menu)
reach their actions. The keys follow the MiSTer DVD core's, so a remote set up for one works
for the other.

!!! warning "Media Center (eHome) IR receivers are not supported out of the box"
    A Windows Media Center receiver (the eHome / `mceusb` family) needs a Linux kernel
    driver that MiSTer does not include, so it never appears as an input device. A FLIRC
    learns the same remote and needs nothing.

Keys the player never uses, because MiSTer keeps them: F12 and the Menu key (the OSD),
Pause/Break, Num Lock and Scroll Lock, Alt and the Windows key.
