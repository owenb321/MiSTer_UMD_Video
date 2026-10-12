#!/usr/bin/env bash
# run_menu.sh -- P9 M1, the menu engine on the PC (main/support/umd/menu/, docs/p9.md S3.3-S3.4).
# Built by bench/umd/menu/Makefile into .sim/menu/.
# ARMS="H14 G9 ...": with --red, run only those mutation arms (the GREEN stages always run)
# --lib: also the M4 library sweep (below)
#
# GREEN:
#   rco    M1a: the RCO loader (rco.c) against tools/rco_census.py on every RCO of every disc
#          image under ${UMD_ISO_DIR:-~/umd-isos} (tools/menu_rco_check.py): entries, depth,
#          fan-out, the object / animation / image / sound histograms, the VSMX header -- EQUAL.
#          SKIP, loudly, without images.
#   attrs  tools/rco_attr_gen.py --check: rco_attrs.h is what RCOMage's tables generate
#   iso    M3: the UMD Main's image reader (umd_iso.c, via menu/iso_dump.c) against tools/umd_iso.py
#          (tools/menu_iso_check.py): every image's whole tree, disc id and the menus' files' CRCs;
#          and tools/menu_iso_synth.py's synthetic images (the ISO9660 cases no disc has: ';1',
#          a trailing '.', lower case, a contiguous multi-extent file, padded UMD_DATA.BIN fields,
#          the depth limit; a gapped multi-extent file and a ninth level refused by both)
#   playlist  M3: the PLAYLIST.UMD parser (umd_playlist.c, via menu/pl_dump.c) against
#          tools/umd_playlist.py, its chapters against umd_nav_ref.py's rule (tools/menu_pl_check.py):
#          every image's file and synthetic ones (65,535 unsorted marks with Endmarks, duplicates and
#          a missing item; four malformed files, refused by both)
#   host   M3: the UMD Main's P9 host-row logic (main/support/umd/umd_menu_logic.c) against a C model
#          of umd_host.sv's P9 side and player_ctl's answers (menu/host_menu_check.c, 200 seeds):
#          once-only records after their echo, adoption, events by count, BAD retried in order,
#          the start chapter at a landing, the old playlist's events dropped
#   scale  M4h: THE CANVAS SCALE (menu.c menu_scale, the menu's 480 x 272 canvas stretched onto the plane) against
#          its definition one pixel and channel at a time, clips against the whole call, 1:1 a copy, a float
#          bilinear within its derived 7 LSB, the edge clamp (menu/scale_check.c)
#   lib    M4 (--lib, opt-in, ~10 min): tools/menu_lib.py -- every image under the ISO dir through the
#          UMD Main's path with the library probe (menu_host_check --walk: Cross on a page that sits
#          unchanged until a content play of a feature-length playlist, then Square), each image's class
#          (menu / autoplay / no-square / stuck / stopped / refused) against tools/menu_lib_classes.txt
#          (a changed class, a new image or a missing one FAILs). Its RED arms are mhost's lib-* (H36-H48)
#   mhost  M3: tools/menu_gate.py --host -- the same scenarios through the UMD Main's whole menu
#          path (menu/menu_host_check.c: the engine, umd_menu_host.c, umd_menu_logic.c, the image
#          read by umd_iso / umd_playlist, a core model with 50-400 ms seeks), 3 seeds each, plus the
#          host's own: the levels, P9-6's quit (the top page, Akira's warning, the film then the
#          image again: resumed), the film's end (Akira: no resume point after it; X-Men: its copyright
#          screens then its menu), a slow mount, the startup RCO of a disc without EN100000
#   vag    M3 C: the menus' sounds -- vag.c (via menu/vag_dump.c) against ffmpeg's adpcm_psx, every
#          channel of every sound of every RCO, sample for sample, and its 48 kHz resample against
#          tools/menu_vag_check.py's own (the definition); and synthetic VAGs the library never
#          exercises (a history past 16 bits, a block flagged 7, every filter and shift)
#   gate   M1b: tools/menu_gate.py -- the VSMX VM and the engine (vsmx.c, menu.c) under the model
#          player (menu/menu_run.c) run each CAPTURED disc's startup chain to its main menu and a
#          key path through it, every checkpoint in order and in time, as the PSP captures show
#          (docs/p9.md S2): Family Guy, Akira, Austin Powers 2. SKIP, loudly, without their images.
# --red: mutations on a COPY of the loader (compiled inside it), each must make [rco] differ:
#   M1  the VSMX script read 4 bytes past its place
#   M2  an image entry's extra 4 bytes longer than its span
#   M3  a mono sound entry's second (zero) channel pair not counted
#   M4  the depth counted from 1
#   M5  the type byte misread (every entry one type on)
#   (a parent ending where its last child ended, ignoring its own next-sibling offset, is
#    EQUIVALENT on every library RCO -- each parent ends exactly there -- and is not an arm)
#   M6  an object's size from the attribute table only, the table a word short for one type
# --red: mutations on a COPY of the engine / the model player, each must make [gate] FAIL:
#   G1  the scripts' playlist numbers taken from 0 (they count from 1: Akira's 6, Family Guy's 15)
#   G2  an empty array true (as JavaScript; the PSP's is false: Austin Powers 2's Chapter_menu2)
#   G3  a play's START chapter not posted to onChapter (Austin Powers 2's language page waits on it)
#   G4  script-set handlers ignored (`btn.onPush = f`: Austin Powers 2's buttons have no other)
#   G5  a page's open() not focusing its first button (Family Guy's Ep01, its Play button)
#   G6  resume() returning nothing (Akira's `resume() == 0` fails, the film restarts)
#   G7  Square not calling controller.onMenu (Akira's menu in playback)
#   G8  END_STMT clearing the frame's stack (JPCSP's; the && / || chains run it mid-expression)
#   (M1c, the picture: [gate]'s "draw" checks -- where the titles land against the captures)
#   G9  the scene's y axis down (the captures: Ep01 at y 170 is the TOP title)
#   G10 every object anchored at its left edge, not its centre (since M4b: the horizontal anchor digit ignored, all left)
#   G11 the scene in the PSP's 480 x 272, not 854 x 480
#   G12 `children` labels only, not array-like (Austin Powers 2's pages draw nothing)
#   G13 Array(...) called without `new` not an array (Austin Powers 2's colours become NaN)
#   G14 a new tween replacing the running one (Family Guy's focused Ep01 ends dim; a MODEL check)
#   G15 animScale ignored (Family Guy's focused Ep01 at 1.0x; the capture's 1.1x)
#   G16 iconOffset 1 ignored (Austin Powers 2's main-menu items centred, half off the screen)
#   G49 iconOffset's vertical anchor ignored (M4b: My Chemical Romance disc 2's highlights 17, top-left,
#       drawn centred -- off its video's lettering; the mcr2 scenario)
#   G50 iconOffset's right anchor ignored (Astro Boy's carousel labels pushed right, clipped; astro-anchor)
#   G53 a script's rotation the long way (Astro Boy's drum spins three quarters back at the wrap; astro-wrap)
#   G52 a script's tween stacked on the running ones, not replacing them (MCR disc 2's highlights stay lit after quick presses; mcr2-quick)
#   G54 an animation played again while it runs keeps its old run (MCR disc 2: the old run's late steps
#       relight a button the page re-open faded -- residual highlights after rapid presses; mcr2-rapid:
#       its Lock also swallows a press, so the last-focus checkpoint fails before the picture)
#   G51 rotation about X ignored (the 2-D scene: Astro Boy's drum never turns, its faces overlap; astro-drum)
#   G55 the focus's onFocusIn not delivered again at a later activation (X2's glow, Aliens' white; fj#68:
#       x2-focus-activate, aliens-focus-activate)
#   G56 ... delivered again at an activation in the open's own instant too (Akira's pageRoot; akira-focus-same-instant)
#   G57 the size mode ignored (fj#73: every image stretched to its object's box -- The Rock's scene titles 893 x 46,
#       overlapping; rock-scenes, against the maintainer's PSP photo)
#   G58 the size mode taken for every object (an image at its own size even where the flag is 0: The Rock's grid
#       427 x 240, not the screen; rock-scenes)
#   G59 another animation's step stacking on the running tweens, not replacing them (fj#68: The Rock's main menu
#       opens with PLAY's row unfocused -- animRootOpen's slide ends after animPlayFocus's; rock-root-focus)
#   G60 the engine not calling the host's change_resource (fj#66: afgm-play-warnings)
#   G61 the model player ignoring pauseMode 1 (fj#65: animatrix-still-held -- the model's rule, as umd_menu_host's)
#   G62 a parent's alpha multiplied into its children when drawn (fj#69, the rule before: Hackers' entries, The
#       Transporter's buttons, The Fifth Element's PLAY MOVIE, X-Men's languages never drawn; hackers-wheel,
#       transporter-pivots, fifth-root-play, xmen-setup-langs)
#   G63 an alpha write not handed down (X-Men's buttons through the 13 s hold, The Incredibles' buttons left
#       lit as the main menu fades out; xmen, incredibles-setup-fade)
#   G64 ... handed down as the descendants' AUTHORED alpha times the value (The Incredibles' buttons lost
#       on the way back to the main menu; incredibles-setup-fade)
#   G65 ... handed down as the value itself (every X-Men glow lit; xmen)
#   G66 a closed page's animation run left going (only its Lock dropped, the rule before: The Animatrix's mainTimer
#       cuts a chosen segment to the first a minute after the main menu opened; animatrix-segment-timer)
#   H49 Function.prototype.call missing (Astro Boy's timer abandoned: its submenu never opens; astro-drum)
#   H50 the damage ignores a colour change (a highlight's fade left stale: CORE INC MISMATCH; M4d)
#   H51 a damaged rectangle not cleared before its redraw (blended over the old composite)
#   H52 the clipped span's first texel step recomputed at the clip (the LSB drift the exact clip avoids; since fj#74 seen
#       through aliens-focus-activate-nocache: the item cache draws unclipped entries, which hid it)
#   G17 MENU_PX_PLANE (the subtitle plane's {A, R, G, B} word, M3's) with red and blue unswapped
#   (M1d, relaunch: [gate]'s akira-relaunch / ap2-relaunch)
#   G18 a relaunch calling onAutoPlay (Austin Powers 2's logo again; Akira's logos)
#   G19 the user data not kept across a relaunch
#   G20 the kept user data's numbers lost in its text form (restored as 0)
#   (X-Men, the maintainer's capture of 2026-10-02)
#   G21 try / catch refused (as before X-Men was measured): its menu never opens
#   G22 two empty arrays unequal (JavaScript's identity): X-Men's focus handler throws, its menu's
#       opening is abandoned in MMAnim's catch
#   G23 activate() not bringing back the page's own focus (Akira's AUDIO pop-up: the closed pop-up's
#       Japanese chosen by the next Cross; the PSP: closed "without making a choice")
#   (the library, 2026-10-02: each rule that let a stopped disc run, a lib-* scenario)
#   G24 a numeric index not truncated (Final Fantasy: children[1.5])
#   G25 no time in a busy-wait (Goldmember: `while (picto.getPos()[0] != 200)`, the heap fills)
#   G26 no `parent` (Kill Bill: this.parent.children[...])
#   G27 a script's TypeError stopping the engine (Dude, Where's My Car: its own onFocusIn's)
#   G28 [] unequal to undefined (Now That's Music: `currentPage != []` with currentPage unset)
#   G29 an object unequal to its string form (Akira's `RootButtonFocus == '[object Button]'`)
#   G30 no getRotate (A Few Good Men and four more)
#   G32 a UButton's string form "[object UButton]" (the PSP's "[object Button]": Akira)
#   (setCrop / animCrop, slice, toLowerCase: no disc's first minute depends on them -- no arm)
#   G34 the renderer's fast path two texels off (the gate's shots compare it with the general path)
#   G38 the ROTATED path (draw_affine, M4) not stepping its texture rows (X-Men's orbs mid-turn at 102.5 s)
#   G37 open() resetting a page that is already up (Austin Powers 2 re-opens pageRootMenu while it is up)
#   G36 a page rebuilt by open() keeping the focus held in it (Akira's PLAY unlit after Square: no onFocusIn)
#   G35 open() keeps a page's attributes from its last time up (Family Guy's episode page reopened at
#       alpha 0 after Main Menu: black on the rig, 2026-10-03)
#   G33 MoveTo an offset from the object's place (JPCSP's), not absolute (The Island's scene selection
#       page off screen; the maintainer's photo)
#   (a rotation's sense or unit: X-Men's group turns by whole turns and back to 0 over the video's
#    own orbs -- its resting places measure neither, so no arm: docs/p9.md M3 "X-Men")
#   (the propagation of a handler's error to an enclosing try, vm_error_caught, is exercised by no
#    captured disc once G22's rule holds: no arm)
# --red: mutations on a COPY of umd_iso.c, each must make [iso] FAIL (the synthetic set, then the library):
#   I1  a ';1' version suffix kept                  I2  a trailing '.' kept
#   I3  UMD_DATA.BIN's fields not trimmed           I4  a file read one byte late
#   I5  a gapped multi-extent file accepted          I6  no depth limit on a listing
#   I7  names not upper-cased
# --red: mutations on a COPY of umd_playlist.c, each must make [playlist] FAIL:
#   L1  chapters in table order, not by (item, PTS)  L2  Endmarks (type 16) taken as chapters
#   L3  a mark on a missing item taken as a chapter  L4  a marks count its length cannot hold accepted
#   L5  a clip name over 8 truncated, not refused    L6  IN read 2 bytes late
#   L7  a mark's PTS as 32 bits                   L8  a mark's name (onMark's mark_name) cut to 23 bytes
# --red: mutations on a COPY of vag.c, each must make [vag] FAIL (the library's sounds vs ffmpeg):
#   V1  the history clipped (ffmpeg keeps it unclipped)   V2  the prediction's / 64 as >> 6 (floor)
#   V3  the nibbles high first                            V4  a block flagged 7 not silenced
#   V5  the resample rounded to the nearest (the definition truncates toward zero)
# --red: mutations on a COPY of umd_menu_logic.c, each must make [host] FAIL:
#   U1  no adoption of the echoed seqs            U2  a flip sent before the last one's echo
#   U3  consumed-but-unpopped events delivered again  U4  the old playlist's CHAPTER not dropped
#   U5  no start chapter at a landing             U6  a BAD PLAYLIST not retried
#   U7  a landing without a seen seek (a replayed playlist lands at once)
#   U8  the PTS's top word shifted by 31          U9  a PLAYLIST not holding the command channel
#   U10 a CHAPTER equal to the last posted passed again
#   U11 a QUEUED PLAYLIST not counted for the drop rule (the old playlist's end read before the send)
#   P6d: U12 a press sent before the last one's echo   U13 the press seq not adopted at the start
#        U14 ui_sub never written                      U15 the flip's plane cut to 1 bit
# --red: mutations on a COPY of umd_menu_host.c, each must make [mhost] FAIL (one seed):
#   H1  play()'s playlist number not made an index      H2  the mount's STOP after the script's start
#   H3  every button grabbed in CONTENT (the transport's Triangle, arrows... lost)
#   H4  Circle not grabbed in CONTENT (the transport's stop, not the PSP's quit)
#   H5  resume() from the playlist's start
#   H6  the resume point not kept across a relaunch      H7  the engine started before the mount lands
#   H8  Circle quitting only with a page open (Akira's warning: the maintainer's test)
#   H9  getPlayerStatus's playlist an index
#   H10 Circle not the script's not quitting
#   (H11, an ended playlist leaving a resume point, is EQUIVALENT since the point is kept only while
#    the core plays or pauses: a title's end leaves it stopped. The clear stays, as defence: no arm)
#   H12 the startup RCO EN100000 or the language's only (Iron Man: ES100000 alone)
#   H13 Start not the script's not play / pause (the PSP's, measured)
#   H15 the Menu Language option's codes out of CONF_STR's order (Transporter 2 in French)
#   (umd_menu_run.c, the glue's state machine)
#   H16 the core idle (the OSD's Reset) not quitting the disc: a black screen holding every button
#   H17 a frame drawn while a flip is in flight (the core flags a write to a plane about to show)
#   H18 the shown buffer not tracked: frames drawn into the plane on screen
#   H20 a 4:3 picture under a menu not pillarboxed (the core presents 16:9 there; Family Guy's episodes)
#   H22 a sound placed again at every play (the cache by the engine's key lost)
#   H23 a stereo sound triggered as mono
#   H24 play()'s audio off ignored (Family Guy's episode page loop heard: the third rig session)
#   H25 the mute level never written to the core (the CTL word without bit 13)
#   (H26, a change of the mute level alone not written, is EQUIVALENT and retired: the mute changes
#    only in a play() / resume(), which queues a PLAYLIST, and every HOST_WR carries the CTL word --
#    the mute rides on the command's write; the comparison stays in umd_menu_logic.c for safety)
#   H27 a fitted menu drawn unfitted (the 480i Letterbox ignored by the render)
#   H28 a change of fit not redrawing a still menu
#   H29 the video window not fitted with the menu
#   H30 Crop's view the whole scene (Crop drawn as a squeezed Fit)
#   H31 every open page presented as a menu (pageDummy over a starting episode: the CRT's squeeze)
#   H32 menu_shows blind to alpha (pageDummy's plane at alpha 0 "seen")
#   H35 Disc Menus Off traced but ignored (the menus start: STOP, levels, plays)
#   (M4, the library probe: each rule a lib-* scenario run with --walk, docs/p9.md M4)
#   H36 the script's stop() keeping a resume point (Die Hard's logo loops: stop(); resume() continues it)
#   H37 named marks not reaching onMark (Now That's Music: no menu page ever opens)
#   H38 a content play replaced by another keeping a resume point (Lost resumes a trailer over its episode)
#   H39 open() firing onInit on a page already open (Die Hard's Square: onInit_pageRoot opens pageRoot: endless)
#   H40 the EMPTY constant's rule for every empty array (Batman & Robin's onMenu: `fArray != []` false, no menu)
#   H41 a stopped player's playStatus 2 (Hellboy's Play: stop(1, false), then a wait that times out)
#   H42 no menuMode in the status (Hellboy's ChangeResource stops and waits again and again)
#   H43 local slot 0 not `arguments` (Hackers' addCardPL(...): no info cards, Play does nothing)
#   H44 open()'s first button taking over the focus onInit set (Godzilla Final Wars: RootMenuLock, dead keys)
#   H45 a Lock outliving its animation run (Ghost in the Shell 2.0's chapter menu: three Locks, no Unlock)
#   H46 a Lock outliving its page (Audioslave's lockScreen closed under a 44-minute Lock: the main menu locked)
#   H47 an animation's FireEvent of another animation ignored (Alien: the focus stays on a ghost button)
#   H48 SET_ATTR leaving no value (The Rock's tryToCloseBlack: an operand stack underflow stops the engine)
#   (RS1, docs/resume.md: the kept text on the SD card)
#   H53 the disc id not read before the Disc Menus Off return (nothing kept without it: any relaunch;
#       fg-host-menus-off's "disc -")
#   H54 a store skipped as a repeat when it differs (only the first store reaches the card): the quit's
#       resume point lost (akira-host-quit-powercut). (A quit storing nothing, the first H54, is
#       EQUIVALENT: every change of the kept text is stored when it happens -- setUserData, the resume
#       point -- so the quit's own store only repeats the last; measured over the library, 2026-10-06.)
#   H55 a continue not told apart from a fresh start (the start's trace)
#   H56 a refused write taken as written (no trace, no count; its repeat then skipped: akira-host-cardfull)
#   H57 a refused write's text kept as the card's (its repeat skipped, never retried: akira-host-cardfull)
#   (RS2, the tracker: Disc Menus Off; akira-off-*)
#   H58 Pause not saved (akira-off-pause-powercut)      H59 Stop not saved (akira-off-stop-powercut)
#   H60 no wait for a seek after the title's end (Play then Pause after it writes the end back: akira-off-end)
#   H61 the audio track not restored                    H62 the subtitles not restored
#   H63 a point past PLAYLIST.UMD kept (akira-off-badpoint)
#   H64 a quit (a mount, a core change) not saving (akira-off-relaunch)
#   (RS4, the disc screen: akira-*discscreen*)
#   H65 the disc screen while an engine runs (its own STOP at the start: fg-host-levels' never)
#   H66 the disc screen not hidden at Play          H67 no STOP at a title's end (R5c)
#   H68 Play after the end not restarting the title  H69 the page shown without `menu` (no 16:9, no fit)
#   H70 Play after a menu disc's quit not relaunching its menus (R5f)
#   H71 the CRT's fit ignored                        H72 the Play line's time wrong
#   (M4e, the maintainer's rig session 2026-10-07: Forgejo fj#70, fj#72)
#   H73 onExit's player commands sent at a quit the core no longer holds the disc for (fj#70: inter-host-exit-detached)
#   H74 the new mount's quit not detached (the runner's half of fj#70)
#   H75 a transport key the script left under a page that draws nothing dropped (fj#72: office-host-transport)
#   H76 ... Cross forwarded too (it would pause The Office's opening clips: office-host-transport's never)
#   H77 a closed page's focus taking the key (The Office's Nav takes Right through the episode: office-host-transport)
#   (fj#76, the M4e rig check 2026-10-08: a CHAPTER read before the latest play() was queued, delivered after it)
#   H78 the host delivering it anyway (Aliens' continue: the stale chapter's playlist-1 handler, no menu: aliens-continue-stale-chapter)
#   H79 the logic's play generation not bumped at a PLAYLIST pushed (the same scenario)
#   (fj#74, the renderer's speed: the item cache, menu.c THE ITEM CACHE)
#   H80 a cached item's entry kept after the item changes (CORE INC: the incremental frame vs the full render,
#       which draws without the caches -- every scenario whose menu animates)
#   (M4h, THE CANVAS: [scale] scale_check on the mutant menu.c)
#   S1  the stretch's horizontal weights swapped in the vector step ([def])
#   S2  ... in the scalar tail (a clip or width not a multiple of 4: [def] on 97 / 133 wide)
#   S3  a clipped call's columns from the clip, not the target's origin (the drift the exact clip avoids: [clip])
#   S4  the sample at the pixel's corner, not its centre (the definition's own check: [float])
#   S5  the last column not clamped (a read past the row: [edge] / [def])
#   S6  a window group's first texels shuffled from the second column (THE WINDOW's masks: [def])
#   (M4h, the runner: [mhost]'s CORE INC -- every incremental frame against the whole canvas stretched whole)
#   H81 a canvas rectangle mapped to the target without the bilinear's reach (the neighbours a changed pixel feeds)
#   H82 a fit change not stretching the view whole (the old fit's pixels left: fg-host-fitchange)
#   (M4h, RENDER PIPELINED + THE TICK: umd_menu_run.c; menu_host_check's CORE STALE PUT / PLANE WRITE, the END's verdict)
#   H83 a frame owed without dropping the drawn one (put stale after a fit change: rock-host-fit-moving)
#   H84 the fit not checked before a put (the drawn frame put at the old fit: rock-host-fit-moving)
#   H85 a put while the flip is out (into the buffer about to be shown: CORE PLANE WRITE)
#   H86 the capped tick giving the engine less than the time owed (its clock falls behind: every timed checkpoint)
#   (fj#65 / fj#66, the maintainer's PSP batch 2026-10-10)
#   H87 pauseMode 1 ignored (no PAUSE after the PLAYLIST: The Animatrix plays through its four stills and reopens
#       its main menu at each chapter; animatrix-still-held)
#   H88 getPlayerStatus answering the core's playlist while the latest play() has not landed (Goldmember's main
#       menu reads 4, keeps the Warning clip under the menu: goldmember-gt-return)
#   H89 the system's stop of a menu's playback at a changeResource dropped (A Few Good Men's warning cards over
#       the menu loop: afgm-play-warnings)
#   (fj#88 / fj#89, the resume point, the maintainer's rig 2026-10-10; R7, the user's)
#   H90 the quit's point kept AFTER the script's onExit (Aliens' / The Animatrix's stop() clears it:
#       aliens-quit-resume, animatrix-relaunch-resume)
#   H91 a resume point used up at the ask (no landing to use it up: aliens-quit-resume; a quit inside its seek
#       keeps none: animatrix-relaunch-before-landing)
#   H92 ... the quit not keeping a used point (the onExit's stop() drops it: the same scenario)
#   H93 the used point never used up at its landing (aliens-quit-resume's "used up")
#   H94 the disc screen's Play line from the core's place after a menu disc's quit (aliens-quit-menu-play)
#   H95 Stop on the disc screen not grabbed (akira-off-discscreen, the -forget scenarios)
#   H96 Stop on the disc screen deleting nothing (akira-*-discscreen-forget's empty store)
#   H97 ... Play after it resuming the stopped place, not the title's start (akira-off-discscreen-forget)
#   H98 the OSD Reset's quit reading the idle read, not the last in play (no point kept: aliens-reset-resume)
#   (a content play / a script's stop() before the resumed play lands dropping the used point: no library
#    scenario asks either; unarmed)
#   (the line cache, the vector step, the bands: exact by construction, their gate is tools/menu_render_ab.py --
#    every library image's frames hashed against a reference build; it is not an arm here: the reference is a build)
#   H33 a landing posting the core's chapter word (0 just after it), not the one the play named
#   H34 getPlayerStatus answering the core's word, not the chapter last posted
#   H19 (menu.c) a tween's end not drawing (the rig: Family Guy's art stuck half faded; the bench's
#       stale-frame check -- a fresh render at rest against the last frame flipped)
#   H14 the video window's width not mapped from the 854-wide scene to the 720-wide raster (The Island)
set -u
cd "$(dirname "$0")/../.."
fail=0
red=0; lib=0
for a in "$@"; do case $a in --red) red=1 ;; --lib) lib=1 ;; esac; done
ISO=${UMD_ISO_DIR:-$HOME/umd-isos}
export UMD_REFS_DIR=${UMD_REFS_DIR:-$(cd .. && cd .. && pwd)/umd_repos}

echo "== build =="
make -s -C bench/umd/menu || { echo "  FAIL build"; exit 1; }
echo "  built .sim/menu/menu_dump"

echo "== GREEN =="
if python3 tools/rco_attr_gen.py --check > .sim/menu/attrs.log 2>&1; then echo "  PASS attrs: $(tail -1 .sim/menu/attrs.log)"
else echo "  FAIL attrs: $(tail -1 .sim/menu/attrs.log)"; fail=1; fi
python3 tools/menu_rco_check.py --iso-dir "$ISO" > .sim/menu/rco.log 2>&1
if grep -q "^PASS: menu_rco_check" .sim/menu/rco.log; then echo "  PASS rco: $(grep '^menu_rco_check:' .sim/menu/rco.log | sed 's/^menu_rco_check: //')"
elif grep -q "SKIP" .sim/menu/rco.log; then echo "  SKIP rco: $(tail -1 .sim/menu/rco.log)"
else echo "  FAIL rco"; grep "FAIL\|menu_rco_check:" .sim/menu/rco.log | head -4; fail=1; fi
python3 tools/menu_gate.py --iso-dir "$ISO" > .sim/menu/gate.log 2>&1
if grep -q "^PASS: menu_gate" .sim/menu/gate.log; then echo "  PASS gate: $(grep '^PASS:' .sim/menu/gate.log | sed 's/^PASS: //')"
elif grep -q "^SKIP" .sim/menu/gate.log; then echo "  SKIP gate: $(tail -1 .sim/menu/gate.log)"
else echo "  FAIL gate"; grep "FAIL" .sim/menu/gate.log | head -4; fail=1; fi

python3 tools/menu_iso_synth.py .sim/menu/syn_iso > /dev/null
python3 tools/menu_iso_check.py --iso-dir .sim/menu/syn_iso > .sim/menu/iso_syn.log 2>&1
python3 tools/menu_iso_check.py --iso-dir "$ISO" > .sim/menu/iso.log 2>&1
if grep -q "^PASS:" .sim/menu/iso_syn.log && { grep -q "^PASS:" .sim/menu/iso.log || grep -q "^SKIP" .sim/menu/iso.log; }; then
  echo "  PASS iso: $(grep '^menu_iso_check:' .sim/menu/iso_syn.log | sed 's/^menu_iso_check: //') (synthetic); $(grep '^menu_iso_check:\|^SKIP' .sim/menu/iso.log | sed 's/^menu_iso_check: //')"
else echo "  FAIL iso"; grep "FAIL" .sim/menu/iso_syn.log .sim/menu/iso.log | head -4; fail=1; fi
python3 tools/menu_pl_check.py --iso-dir "$ISO" > .sim/menu/pl.log 2>&1
if grep -q "^PASS:" .sim/menu/pl.log; then echo "  PASS playlist: $(grep '^menu_pl_check:' .sim/menu/pl.log | sed 's/^menu_pl_check: //')"
else echo "  FAIL playlist"; grep "FAIL" .sim/menu/pl.log | head -4; fail=1; fi
python3 tools/menu_vag_check.py --iso-dir "$ISO" > .sim/menu/vag.log 2>&1
if grep -q "^PASS:" .sim/menu/vag.log; then echo "  PASS vag: $(grep '^menu_vag_check:' .sim/menu/vag.log | sed 's/^menu_vag_check: //')"
elif grep -q "^SKIP" .sim/menu/vag.log; then echo "  SKIP vag: $(tail -1 .sim/menu/vag.log)"
else echo "  FAIL vag"; grep "FAIL" .sim/menu/vag.log | head -4; fail=1; fi
python3 tools/menu_gate.py --iso-dir "$ISO" --host > .sim/menu/gate_host.log 2>&1
if grep -q "^PASS: menu_gate" .sim/menu/gate_host.log; then echo "  PASS mhost: $(grep '^PASS:' .sim/menu/gate_host.log | sed 's/^PASS: //')"
elif grep -q "^SKIP" .sim/menu/gate_host.log; then echo "  SKIP mhost: $(tail -1 .sim/menu/gate_host.log)"
else echo "  FAIL mhost"; grep "FAIL" .sim/menu/gate_host.log | head -4; fail=1; fi
.sim/menu/scale_check > .sim/menu/scale.log 2>&1
if grep -q "^scale_check: .* PASS$" .sim/menu/scale.log; then echo "  PASS scale: $(grep '^scale_check:' .sim/menu/scale.log | sed 's/^scale_check: //')"
else echo "  FAIL scale"; grep "FAIL" .sim/menu/scale.log | head -4; fail=1; fi
.sim/menu/host_menu_check > .sim/menu/host.log 2>&1
if grep -q "^PASS:" .sim/menu/host.log; then echo "  PASS host: $(grep '^host_menu_check:' .sim/menu/host.log | sed 's/^host_menu_check: //')"
else echo "  FAIL host"; grep "FAIL" .sim/menu/host.log | head -4; fail=1; fi
if [ $lib = 1 ]; then
  # (opt-in: ~10 min at 8 jobs) every image's class under the M4 probe against the recorded ones
  python3 tools/menu_lib.py --iso-dir "$ISO" --jobs "${JOBS:-8}" --out .sim/menu/lib --check tools/menu_lib_classes.txt > .sim/menu/lib.log 2>&1
  if grep -q "^PASS: menu_lib" .sim/menu/lib.log; then echo "  PASS lib: $(grep '^menu_lib: [0-9]' .sim/menu/lib.log | sed 's/^menu_lib: //')"
  elif grep -q "^SKIP" .sim/menu/lib.log; then echo "  SKIP lib: $(tail -1 .sim/menu/lib.log)"
  else echo "  FAIL lib"; grep "FAIL" .sim/menu/lib.log | head -6; fail=1; fi
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught) =="
  mut() {   # name old new
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    if ! python3 - "$d/src/rco.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/src" OUT="$d/out" "$d/out/menu_dump" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 tools/menu_rco_check.py --iso-dir "$ISO" --dump "$d/out/menu_dump" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the check cannot see this defect"; fail=1
    else echo "  $name: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  mut M1 "r->vsmx = idx; r->vsmx_data = b + 0x30 + vo;" "r->vsmx = idx; r->vsmx_data = b + 0x34 + vo;"
  mut M2 "x = nxt ? nxt - 0x28 : 12 + (le16(b + 0x2A) ? 4u : 0u);" "x = nxt ? nxt - 0x24 : 12 + (le16(b + 0x2A) ? 4u : 0u);"
  mut M3 "x = 12 + 8 * (ch < 2 ? 2u : ch);" "x = 12 + 8 * ch;"
  mut M4 "e->depth = (uint32_t)sp;" "e->depth = (uint32_t)sp + 1u; if ((uint32_t)sp + 1u > r->max_depth) r->max_depth = (uint32_t)sp + 1u;"
  mut M5 "e->table = (uint8_t)(tid >> 8); e->type = (uint8_t)tid;" "e->table = (uint8_t)(tid >> 8); e->type = (uint8_t)(tid + 1);"
  mut6() {   # M6 mutates the generated table: Plane one word short
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" M6 "* ]] && return     # (ARMS: those arms only)
    local d; d=$(mktemp -d); mkdir -p "$d/src" "$d/out"; cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    sed -i 's/{ "Plane", rco_obj_plane, 17, 19 }/{ "Plane", rco_obj_plane, 17, 18 }/' "$d/src/rco_attrs.h"
    if cmp -s "$d/src/rco_attrs.h" main/support/umd/menu/rco_attrs.h; then echo "  M6: harness failure (anchor)"; fail=1
    else (cd bench/umd/menu && make -s SRC="$d/src" OUT="$d/out" "$d/out/menu_dump" > "$d/build.log" 2>&1)
      python3 tools/menu_rco_check.py --iso-dir "$ISO" --dump "$d/out/menu_dump" > "$d/log" 2>&1
      if grep -q "^PASS:" "$d/log"; then echo "  M6: SURVIVED -- the check cannot see this defect"; fail=1
      else echo "  M6: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi; fi
    rm -rf "$d"
  }
  mut6
  smut() {   # name old new: menu.c mutated, [scale] must FAIL (M4h)
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    if ! python3 - "$d/src/menu.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/src" OUT="$d/out" "$d/out/scale_check" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    "$d/out/scale_check" > "$d/log" 2>&1
    if grep -q "^scale_check: .* PASS$" "$d/log"; then echo "  $name: SURVIVED -- the check cannot see this defect"; fail=1
    else echo "  $name: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  smut S1 "                    u16x8 w = ld16(cfw + i), iw = c256 - w;
                    st32(hrb" "                    u16x8 iw = ld16(cfw + i), w = c256 - iw;
                    st32(hrb"
  smut S6 "                m0[4 * k + b] = (uint8_t)(4 * ((int)cu0[i + k] - base) + b);" \
          "                m0[4 * k + b] = (uint8_t)(4 * ((int)cu1[i + k] - base) + b);"
  smut S2 "        for (; i < nx; i++) o[i] = lerp2(a_rb[i], b_rb[i], fv) | lerp2(a_ga[i], b_ga[i], fv) << 8;" \
          "        for (; i < nx; i++) o[i] = lerp2(b_rb[i], a_rb[i], fv) | lerp2(b_ga[i], a_ga[i], fv) << 8;"
  smut S3 "        int32_t U = u_first + (int32_t)(cx0 + i) * du;" "        int32_t U = u_first + (int32_t)i * du;"
  smut S4 "    int32_t u_first = (int32_t)lroundf((rx + 0.5f * rw / (float)dw - 0.5f) * 65536.0f);" \
          "    int32_t u_first = (int32_t)lroundf(rx * 65536.0f);"
  smut S5 "        if (u1 > sw - 1) u1 = sw - 1;
        cu0[i] = (uint32_t)u0;" "        cu0[i] = (uint32_t)u0;"
  gmut() {   # name file(src/... or bench/...) old new: the gate must FAIL on the mutant
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 file=$2 old=$3 new=$4 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/bench" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    cp bench/umd/menu/*.c bench/umd/menu/*.h bench/umd/menu/Makefile "$d/bench/"
    if ! python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd "$d/bench" && make -s SRC="$d/src" OUT="$d/out" "$d/out/menu_run" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 tools/menu_gate.py --iso-dir "$ISO" --run "$d/out/menu_run" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the gate cannot see this defect"; fail=1
    elif grep -q "^SKIP" "$d/log"; then echo "  $name: SKIP (no images)"
    else echo "  $name: caught: $(grep -m1 'FAIL ' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  imut() {   # name old new: umd_iso.c mutated, [iso] must FAIL
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    if ! python3 - "$d/src/umd_iso.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/src" OUT="$d/out" "$d/out/iso_dump" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 tools/menu_iso_check.py --iso-dir .sim/menu/syn_iso --dump "$d/out/iso_dump" > "$d/log" 2>&1
    grep -q "^PASS:" "$d/log" && python3 tools/menu_iso_check.py --iso-dir "$ISO" --dump "$d/out/iso_dump" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the check cannot see this defect"; fail=1
    else echo "  $name: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  imut I1 "if (c == ';') break;" "(void)0;"
  imut I2 "if (k && name[k - 1] == '.') name[--k] = 0;" "(void)0;"
  imut I3 "while (a < z && b[a] == ' ') a++;" "(void)0;"
  imut I4 "if (e.size && iso->read(iso->ud, (uint64_t)e.lba * SEC, b, e.size) != e.size)" \
          "if (e.size && iso->read(iso->ud, (uint64_t)e.lba * SEC + 1, b, e.size) != e.size)"
  imut I5 "if (lba != p_next) return fail(iso, \"a multi-extent file is not contiguous (LBA %u, %u)\", lba, p_next);" "(void)p_next;"
  imut I6 "if (depth > DEPTH_MAX) return fail(iso, \"directory depth %d > %d\", depth, DEPTH_MAX);" "(void)depth;"
  imut I7 "name[k++] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;" "name[k++] = c;"
  pmut() {   # name old new: umd_playlist.c mutated, [playlist] must FAIL (synthetic first)
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    if ! python3 - "$d/src/umd_playlist.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/src" OUT="$d/out" "$d/out/pl_dump" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 tools/menu_pl_check.py --synthetic-only --dump "$d/out/pl_dump" > "$d/log" 2>&1
    grep -q "^PASS:" "$d/log" && python3 tools/menu_pl_check.py --iso-dir "$ISO" --dump "$d/out/pl_dump" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the check cannot see this defect"; fail=1
    else echo "  $name: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  pmut L1 "    qsort(ent->chapters, ent->nchapters, sizeof(uint32_t), chap_cmp);" "    (void)chap_cmp;"
  pmut L2 "if (b[0] == MARK_CHAPTER && ent->marks[k].item < ent->nitems)" "if ((b[0] == MARK_CHAPTER || b[0] == 16) && ent->marks[k].item < ent->nitems)"
  pmut L3 "if (b[0] == MARK_CHAPTER && ent->marks[k].item < ent->nitems)" "if (b[0] == MARK_CHAPTER)"
  pmut L4 "if (2u + MARK_LEN * nm != ln) return fail" "if (2u + MARK_LEN * nm > ln + 40u) return fail"
  pmut L5 "if (cl > 8) return fail(pl, \"playlist %u item %u: clip name length %u > 8\", idx, k, cl);" "if (cl > 8) cl = 8;"
  pmut L6 "ent->items[k].in = be48(body + 10);" "ent->items[k].in = be48(body + 12);"
  pmut L7 "ent->marks[k].item = be16(b + 2); ent->marks[k].pts = be48(b + 4);" "ent->marks[k].item = be16(b + 2); ent->marks[k].pts = be32(b + 6);"
  pmut L8 "memcpy(ent->marks[k].name, b + 16, 24);" "memcpy(ent->marks[k].name, b + 16, 23);"
  hmut() {   # name old new: umd_menu_logic.c mutated, [host] must FAIL
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/hsrc" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    cp main/support/umd/umd_menu_logic.c main/support/umd/umd_menu_logic.h main/support/umd/umd_host_proto.h "$d/hsrc/"
    if ! python3 - "$d/hsrc/umd_menu_logic.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/src" HSRC="$d/hsrc" OUT="$d/out" "$d/out/host_menu_check" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    "$d/out/host_menu_check" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the check cannot see this defect"; fail=1
    else echo "  $name: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  vmut() {   # name old new: vag.c mutated, [vag] must FAIL
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 d
    d=$(mktemp -d); mkdir -p "$d/src" "$d/out"
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/src/"
    if ! python3 - "$d/src/vag.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/src" OUT="$d/out" "$d/out/vag_dump" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 tools/menu_vag_check.py --iso-dir "$ISO" --dump "$d/out/vag_dump" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the check cannot see this defect"; fail=1
    else echo "  $name: caught: $(grep -m1 'FAIL' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  vmut V1 "            s1 = sample;" "            s1 = sample > 32767 ? 32767 : sample < -32768 ? -32768 : sample;"
  vmut V2 "(s1 * vag_f[filter][0] + s2 * vag_f[filter][1]) / 64;" "((s1 * vag_f[filter][0] + s2 * vag_f[filter][1]) >> 6);"
  vmut V3 "            int nib = (i & 1) ? (byte >> 4) : (byte & 15);" "            int nib = (i & 1) ? (byte & 15) : (byte >> 4);"
  vmut V4 "            if (flag < 7)" "            if (flag < 8)"
  vmut V5 "(int)(((int64_t)(b2 - a) * (int64_t)fr) / 48000));" "(int)((((int64_t)(b2 - a) * (int64_t)fr) + 24000) / 48000));"
  hmut U1 "s->cmd_seq = rd->cmd_ack; s->flip_seq = rd->flip_ack; s->pcm_seq = rd->pcm_ack;" "(void)0;"
  hmut U2 "if (!s->flip_busy && s->n_flip) {" "if (s->n_flip) {"
  hmut U3 "for (uint8_t k = off; k < avail && k < 4; k++) {" "for (uint8_t k = 0; k < avail && k < 4; k++) {"
  hmut U4 "if (pl_ahead(s)) { s->n_dropped++; break; }       // the old playlist's" "(void)0;"
  hmut U11 "for (int i = 0; i < s->n_cmd; i++) if (s->q_cmd[i].code == UMD_PC_PLAYL) return 1;" "(void)0;"
  hmut U5 "			post(s, ev, nev, UMD_ME_CHAPTER, ch);" "			(void)ch;"
  hmut U6 "if (s->retries < UMD_MENU_RETRY_MAX) {" "if (0) {"
  hmut U7 "if (s->land_wait && s->seen_seek && rd->playlist == s->land_pl" "if (s->land_wait && rd->playlist == s->land_pl"
  hmut U8 "wr[UMD_HOST_WR_PCMD_PTS2]  = (uint16_t)(c->pts >> 32);" "wr[UMD_HOST_WR_PCMD_PTS2]  = (uint16_t)(c->pts >> 31);"
  hmut U9 "if (!s->cmd_busy && !s->inflight && s->n_cmd) {" "if (!s->cmd_busy && s->n_cmd) {"
  # P6d (docs/panel.md F1 / F5): the press channel, ui_sub, the flip's 2-bit plane -> S6
  hmut U12 "if (!s->press_busy && s->n_press) {" "if (s->n_press) {"
  hmut U13 "			s->press_seq = rd->press_ack;" "			(void)0;"
  hmut U14 "(s->lv.ui_sub ? 0x1000 : 0)" "0"
  hmut U15 "(f->buf & 3) << 1" "(f->buf & 1) << 1"
  hmut U10 "if (data != s->last_chapter) { post(s, ev, nev, UMD_ME_CHAPTER, data); s->last_chapter = data; }" "{ post(s, ev, nev, UMD_ME_CHAPTER, data); s->last_chapter = data; }"
  mhmut() {   # name old new [file]: umd_menu_host.c (or umd_menu_run.c) mutated, [mhost] must FAIL
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return     # (ARMS="H14 G9 ...": those arms only)
    local name=$1 old=$2 new=$3 file=${4:-umd_menu_host.c} d
    d=$(mktemp -d); mkdir -p "$d/hsrc/menu" "$d/out"      # (the host includes "menu/menu.h")
    cp main/support/umd/menu/*.c main/support/umd/menu/*.h "$d/hsrc/menu/"
    cp main/support/umd/umd_menu_*.c main/support/umd/umd_menu_*.h main/support/umd/umd_panel*.c main/support/umd/umd_panel*.h main/support/umd/umd_disc_screen.[ch] main/support/umd/umd_host_proto.h "$d/hsrc/"   # (P6d: the runner links the panel)
    if ! python3 - "$d/hsrc/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    if ! (cd bench/umd/menu && make -s SRC="$d/hsrc/menu" HSRC="$d/hsrc" OUT="$d/out" "$d/out/menu_host_check" > "$d/build.log" 2>&1); then
      echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 tools/menu_gate.py --iso-dir "$ISO" --host --seeds 1 --run-host "$d/out/menu_host_check" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then echo "  $name: SURVIVED -- the gate cannot see this defect"; fail=1
    elif grep -q "^SKIP" "$d/log"; then echo "  $name: SKIP (no images)"
    else echo "  $name: caught: $(grep -m1 'FAIL ' "$d/log" | cut -c1-110)"; fi
    rm -rf "$d"
  }
  mhmut H1 "uint16_t idx = (uint16_t)(num - 1);" "uint16_t idx = (uint16_t)num;"
  # M4d, the damage rectangles (menu_host_check's CORE INC check: every incremental frame against the whole render)
  mhmut H50 "if (a && b && !memcmp(a, b, DR_KEY_BYTES)) continue;" "if (a && b && !memcmp(a, b, offsetof(dritem, col))) continue;" menu/menu.c
  mhmut H51 "        for (int y = c[1]; y < c[3]; y++) memset(px + (size_t)y * (size_t)stride + 4 * (size_t)c[0], 0, 4 * (size_t)(c[2] - c[0]));" "" menu/menu.c
  mhmut H52 "    u_first += (int32_t)(cxs - xs) * du;" "    if (im) u_first = (int32_t)lroundf(((fx0 + (float)(cxs - ix0) * dfx) * (float)im->w - 0.5f) * 65536.0f);" menu/menu.c
  # M4h, THE CANVAS (umd_menu_run.c): the damage's stretch and the fit's
  mhmut H81 "	int lo = (int)floorf(((float)a0 - 1.0f - s + 0.5f) * k - 0.5f) - 1;
	int hi = (int)ceilf(((float)a1 - s + 0.5f) * k - 0.5f) + 2;" "	int lo = (int)floorf(((float)a0 - s) * k);
	int hi = (int)ceilf(((float)a1 - s) * k);" umd_menu_run.c
  mhmut H82 "	if (fit != r->inc_fit) {
		mr_bands(px, &v);" "	if (0) {
		mr_bands(px, &v);" umd_menu_run.c
  mhmut H83 "static void owe_frame(umd_menu_run *r) { r->need_frame = 1; r->staged = 0; }" "static void owe_frame(umd_menu_run *r) { r->need_frame = 1; }" umd_menu_run.c
  mhmut H84 "	fit_check(r);
	if (!umd_menu_flip_idle(r->L)) return -1;" "	if (!umd_menu_flip_idle(r->L)) return -1;" umd_menu_run.c
  mhmut H85 "	if (!umd_menu_flip_idle(r->L)) return -1;                 // a flip in flight: its buffer not yet ours" "" umd_menu_run.c
  mhmut H86 "	if (r->tick_acc >= UMD_MR_TICK_MS) { umd_mh_tick(&r->H, r->tick_acc); r->tick_acc = 0; }" "	if (r->tick_acc >= UMD_MR_TICK_MS) { umd_mh_tick(&r->H, r->tick_acc / 2); r->tick_acc = 0; }" umd_menu_run.c
  mhmut H87 "	if (arg_i(p, 0, 0) == 1) {" "	if (0) {"
  mhmut H88 "	if (h->pl_pending && h->playing_pl >= 0) {" "	if (0) {"
  mhmut H89 "	h->n_res_stop++;" "	return;"
  mhmut H90 $'\tkeep_resume(h);\n\t// (fj#88: a resume asked' $'\tif (0) keep_resume(h);\n\t// (fj#88: a resume asked'
  mhmut H91 "	h->resume_used = 1;                     // (fj#88: dropped at the landing, umd_mh_events)" "	h->resume.have = 0;"
  mhmut H92 "	if (h->resume_used) { h->resume_used = 0; tr(h, \"HOST resume point kept: quit before its landing\"); }" ""
  mhmut H93 "				if (h->resume_used) drop_used(h, \"the resumed play landed\");" ""
  mhmut H94 "		if (r->ds_relaunch) umd_ds_hint(" "		if (0) umd_ds_hint(" umd_menu_run.c
  mhmut H95 "		lv->grab |= 1u << UMD_JB_STOP;          // R7" "		(void)0;          // R7" umd_menu_run.c
  mhmut H96 "	kept_put(r, \"\", 0);                     // (the whole text" "	(void)0;                     // (the whole text" umd_menu_run.c
  mhmut H97 "	if (!r->ds_relaunch) r->ds_ended = 2;" "	(void)0;" umd_menu_run.c
  mhmut H98 "(h->have_rd && h->rd.state == 0 && h->have_play) ? &h->rd_play : &h->rd;" "&h->rd;"
  mhmut H2 $'\tpush_cmd(h, UMD_PC_STOP, 0, 0, 0, 0);\n\th->mode = UMD_MH_MENU;\n\th->content = 0;\n\tint rc = cont ? menu_continue(h->m, name) : menu_start(h->m, name);' \
           $'\th->mode = UMD_MH_MENU;\n\th->content = 0;\n\tint rc = cont ? menu_continue(h->m, name) : menu_start(h->m, name);\n\tpush_cmd(h, UMD_PC_STOP, 0, 0, 0, 0);'
  mhmut H3 "else lv->grab = UMD_MH_GRAB_CONTENT;" "else lv->grab = UMD_MH_GRAB_MENU;"
  mhmut H4 "else lv->grab = UMD_MH_GRAB_CONTENT;" "else lv->grab = UMD_MH_GRAB_CONTENT & ~(1u << UMD_JB_STOP);"
  mhmut H5 "push_cmd_ch(h, UMD_PC_PLAYL, 0, r.pl, r.item, r.pts, rank_at(h, r.pl, r.item, r.pts));" "push_cmd_ch(h, UMD_PC_PLAYL, 0, r.pl, 0, h->pl->e[r.pl].items[0].in, rank_at(h, r.pl, r.item, r.pts));"
  mhmut H6 "if (have && pl < h->pl->n) {" "if (0) {"
  mhmut H7 "return rd->nwords_ok && (rd->state == 1 || rd->state == 2) && rd->shown && !rd->seeking;" "return rd->nwords_ok && rd->state != 0;"
  mhmut H8 "if (!took && order[k].key == MENU_KEY_CIRCLE && !h->quit_req) {" "if (!took && order[k].key == MENU_KEY_CIRCLE && !h->quit_req && menu_page_open(h->m)) {"
  mhmut H9 "s->playlist = h->rd.playlist + 1;" "s->playlist = h->rd.playlist;"
  mhmut H10 "if (h->sv.quit) h->sv.quit(h->sv.ud);" "(void)0;"
  mhmut H12 "for (int pass = 0; pass < 3 && !best; pass++)" "for (int pass = 0; pass < 2 && !best; pass++)"
  mhmut H14 "	float W = ww * tw / vw, H = hh * th / vh;" "	float W = ww, H = hh * th / vh;"
  mhmut H15 'static const char *const codes[] = { "EN", "FR", "ES",' 'static const char *const codes[] = { "EN", "ES", "FR",'
  mhmut H16 "if (r->have_rd && r->rd.state == 0) { quit(r, \"the core went idle (Reset)\"); return; }" "(void)0;" umd_menu_run.c
  mhmut H17 "	if (!umd_menu_flip_idle(r->L)) return -1;" "" umd_menu_run.c
  mhmut H18 "	if (r->flipping >= 0) { r->front = r->flipping; r->flipping = -1; }" "" umd_menu_run.c
  mhmut H19 "        else m->dirty = 1;                       // (its last step: drawn even if no tween is left)" "" menu/menu.c
  mhmut H20 "if (h->pres && h->have_rd && h->rd.pic_known && !h->rd.pic_wide) {" "if (0) {"
  mhmut H22 "	while (k < r->n_snd && r->snd[k].key != key) k++;" "	k = r->n_snd;" umd_menu_run.c
  mhmut H23 "	p.start = r->snd[k].word; p.len = r->snd[k].frames; p.stereo = r->snd[k].stereo;" "	p.start = r->snd[k].word; p.len = r->snd[k].frames; p.stereo = 0;" umd_menu_run.c
  mhmut H24 "	h->mute = arg_i(p, 6, 1) == 0;" "	h->mute = 0;"
  mhmut H25 " | (s->lv.mute ? 0x2000 : 0));" ");" umd_menu_logic.c
  mhmut H27 "	if (!fit) menu_render(r->H.m," "	if (1) menu_render(r->H.m," umd_menu_run.c
  mhmut H28 "	if (fit != r->fit_was) { r->fit_was = fit; r->need_frame = 1; }" "	(void)fit;" umd_menu_run.c
  mhmut H29 "	float l = tx + (cx - ww / 2 - vx) * tw / vw, t = ty + (vy - (cy + hh / 2)) * th / vh;" "	(void)fit; tx = 0; ty = 0; tw = 720; th = 480; vx = -427; vy = 240; vw = 854; vh = 480; float l = tx + (cx - ww / 2 - vx) * tw / vw, t = ty + (vy - (cy + hh / 2)) * th / vh;"
  mhmut H30 "	*vx = fit == 2 ? -320.0f : -427.0f; *vy = 240; *vw = fit == 2 ? 640.0f : 854.0f; *vh = 480;" "	*vx = -427.0f; *vy = 240; *vw = 854.0f; *vh = 480;"
  mhmut H31 "	h->pres = !h->content || (page && menu_shows(h->m));" "	h->pres = !h->content || page;"
  mhmut H35 "	if (r->menus_off) { rtr(r, \"HOST mount: disc %s, Disc Menus Off -- the core plays the disc on its own\", r->disc_id[0] ? r->disc_id : \"-\"); return -1; }" "	if (r->menus_off) rtr(r, \"HOST mount: disc %s, Disc Menus Off -- the core plays the disc on its own\", r->disc_id[0] ? r->disc_id : \"-\");" umd_menu_run.c
  # RS1 (docs/resume.md): the disc id before the Disc Menus Off return; a quit's store; the continue traced
  mhmut H53 "	if (umd_iso_disc_id(&r->iso, r->disc_id, sizeof(r->disc_id))) r->disc_id[0] = 0;" "	r->disc_id[0] = 0;" umd_menu_run.c
  mhmut H54 "	if (r->kept_last && r->kept_last_n == n && !memcmp(r->kept_last, t, n)) { r->n_kept_same++; return; }" "	if (r->kept_last) { r->n_kept_same++; return; }" umd_menu_run.c
  mhmut H55 "	h->continued = cont;" "	h->continued = 0;"
  mhmut H56 "	if (r->sv.kept_store(r->sv.ud, r->disc_id, t, n)) {" "	if (r->sv.kept_store(r->sv.ud, r->disc_id, t, n) && 0) {" umd_menu_run.c
  mhmut H57 "		r->n_kept_fail++;" "		r->n_kept_fail++; r->kept_last = (char *)malloc(n + 1); if (r->kept_last) { memcpy(r->kept_last, t, n); r->kept_last_n = n; }" umd_menu_run.c
  # RS2 (docs/resume.md §3): the tracker
  mhmut H58 "	if (r->tr_state_was == 1 && rd->state == 2) tr_save(r, \"pause\");" "	if (0) tr_save(r, \"pause\");" umd_menu_run.c
  mhmut H59 "	else if ((r->tr_state_was == 1 || r->tr_state_was == 2) && rd->state == 3) tr_save(r, \"stop\");" "	else if (0) tr_save(r, \"stop\");" umd_menu_run.c
  mhmut H60 "			r->tr_wait_seek = 1; r->tr_go = 0; r->tr_landing = 0;" "			r->tr_wait_seek = 0; r->tr_go = 0; r->tr_landing = 0;" umd_menu_run.c
  mhmut H61 "	if (r->tr_go_audio >= 0 && r->tr_go_audio != (int)r->rd.audio_track) {" "	if (0) {" umd_menu_run.c
  mhmut H62 "	if (r->tr_go_sub >= 0) {" "	if (0) {" umd_menu_run.c
  mhmut H63 "	if (pl >= r->pl.n || item >= r->pl.e[pl].nitems) {" "	if (pl >= r->pl.n + 1000) {" umd_menu_run.c
  mhmut H64 "	tr_save(r, why);                        // RS2: the tracker's point (no engine)" "	(void)why;" umd_menu_run.c
  # RS4 (docs/resume.md §6): the disc screen
  mhmut H65 "	int want = r->have_disc && r->have_rd && r->rd.state == 3 && !r->rd.seeking && !engine_runs(r) && !r->armed;" "	int want = r->have_disc && r->have_rd && r->rd.state == 3 && !r->rd.seeking;" umd_menu_run.c
  mhmut H66 "	int want = r->have_disc && r->have_rd && r->rd.state == 3 && !r->rd.seeking && !engine_runs(r) && !r->armed;" "	int want = r->have_disc && r->have_rd && (r->rd.state == 3 || r->ds_up) && !engine_runs(r) && !r->armed;" umd_menu_run.c
  mhmut H67 $'\t\t\tc.code = UMD_PC_STOP;\n\t\t\tumd_menu_push_cmd(r->L, &c);\n\t\t\tr->ds_ended = 1;' $'\t\t\tr->ds_ended = 1;' umd_menu_run.c
  mhmut H68 "	if (r->ds_ended && r->ds_state_was == 3 && (rd->state == 1 || rd->state == 2) && r->have_pl && rd->playlist < r->pl.n) {" "	if (0) {" umd_menu_run.c
  mhmut H69 "	if (r->ds_up) { lv->ui = 1; lv->menu = 1; }" "	if (r->ds_up) { lv->ui = 1; }" umd_menu_run.c
  mhmut H70 "		r->armed = 1;                           // (the start fires at the next ready read: a continue)" "		(void)0;" umd_menu_run.c
  mhmut H71 "%d|%s\", r->rd.menu_aa > 2 ? 0 : r->rd.menu_aa, hint);" "%d|%s\", 0, hint);" umd_menu_run.c
  mhmut H72 "	return (uint32_t)(acc / 90);" "	return (uint32_t)(acc / 45);" umd_menu_run.c
  mhmut H73 "	if (h->detached) { tr(h, \"HOST command %u dropped: the core no longer holds this disc (its onExit)\", code); return; }" ""
  mhmut H74 "	quit(r, \"a new mount\", 1);" "	quit(r, \"a new mount\", 0);" umd_menu_run.c
  mhmut H75 "				if (!took && h->content && !h->pres && h->have_rd" "				if (0 && !took && h->content && !h->pres && h->have_rd"
  mhmut H76 "				    (order[k].key == MENU_KEY_LEFT ||" "				    (order[k].key == MENU_KEY_CROSS || order[k].key == MENU_KEY_LEFT ||"
  mhmut H77 "    if (fo >= 0 && m->nodes[fo].page >= 0 && !m->nodes[m->nodes[fo].page].visible) {" "    if (0) {" menu/menu.c
  mhmut H78 "			if (ev[i].gen != h->L->play_gen) {" "			if (0) {"
  mhmut H79 "		if (c->code == UMD_PC_PLAYL) s->play_gen++;   // (fj#76: what was read before it is stale)" "" umd_menu_logic.c
  mhmut H80 $'        else {\n            ic_drop(m, c);' $'        else {\n            (void)0;' menu/menu.c
  mhmut H33 "			uint16_t ch = s->last_pl.chapter ? s->last_pl.chapter : rd->chapter ? rd->chapter : 1;" "			uint16_t ch = rd->chapter ? rd->chapter : 1;" umd_menu_logic.c
  mhmut H34 "	s->chapter = h->chapter ? h->chapter : h->rd.chapter;" "	s->chapter = h->rd.chapter;"
  mhmut H32 "    if (a <= 0.0f) return 0;                    // (as draw_node: its children inherit the zero)" "" menu/menu.c
  mhmut H36 $'\th->playing.have = 0;\n\th->mk_on = 0;\n\th->stopped = 1;' $'\tkeep_resume(h);\n\th->mk_on = 0;\n\th->stopped = 1;'
  mhmut H37 $'\t\tmenu_mark(h->m, mk->name);' $'\t\t(void)0;'
  mhmut H38 $'\tif (menu_mode) keep_resume(h);\n\telse h->playing.have = 0;' $'\tkeep_resume(h);'
  mhmut H39 "    if (!was_open || nd->table != RCO_T_OBJECT || nd->type != 1) fire(" "    if (was_open || 1) fire(" menu/menu.c
  mhmut H40 "        && (a.u.o->nothing || b.u.o->nothing)) return 1;" ") return 1;" menu/vsmx.c
  mhmut H41 "vm_num(s->playing ? (s->paused ? 2.0f : 1.0f) : 0.0f)" "vm_num(s->playing ? 1.0f : 2.0f)" menu/menu.c
  mhmut H42 "    vm_set(v, o, \"menuMode\", vm_num((float)(s->menu_mode != 0)));" "" menu/menu.c
  mhmut H43 "if (x.k.local == 0 && !f->args_built && f->nlocals) {" "if (0) {" menu/vsmx.c
  mhmut H44 "&& M->n_focus_set == fset) set_focus(M, b);" "&& (fset || 1)) set_focus(M, b);" menu/menu.c
  mhmut H45 "if (m->runs[i].cursor >= 0) m->runs[j++] = m->runs[i];   // (its Lock ends with it)" "if (m->runs[i].cursor >= 0 || m->runs[i].locks) m->runs[j++] = m->runs[i];" menu/menu.c
  mhmut H46 "if (r->cursor >= 0 && t >= 0 && (t == pi || M->nodes[t].page == pi)) {" "if (0 && r->cursor >= 0 && t >= 0 && (t == pi || M->nodes[t].page == pi)) {" menu/menu.c
  mhmut H47 "if (t == REF_ANIM && tn >= 0) {" "if (0) {" menu/menu.c
  mhmut H48 "            push(v, a);             // (an assignment is an expression: vsmx.h)" "" menu/vsmx.c
  mhmut H13 "if (!took && order[k].key == MENU_KEY_START) push_cmd(h, UMD_PC_PLAYPAUSE, 0, 0, 0, 0);" "(void)0;"
  gmut G1 bench/menu_run.c "if (pls[i].idx == num - 1) return &pls[i];" "if (pls[i].idx == num) return &pls[i];"
  gmut G2 src/vsmx.c "case V_OBJ:  return x.u.o->kind != O_ARRAY || x.u.o->nel != 0;" "case V_OBJ:  return 1;"
  gmut G3 bench/menu_run.c "P.next_ch = P.chapter - 1;" "P.next_ch = P.chapter;"
  gmut G4 src/menu.c "if (f.t != V_UNDEF) {" "if (0) {"
  gmut G5 src/menu.c "    if (b >= 0 && !M->err[0] && M->n_focus_set == fset) set_focus(M, b);" "    (void)b; (void)fset;"
  gmut G6 src/menu.c "return vm_num((float)r);" "(void)r; return vm_undef();"
  gmut G7 src/menu.c "case MENU_KEY_SQUARE: done = callback(m, m->controller, \"onMenu\", 0, NULL); break;" "case MENU_KEY_SQUARE: break;"
  gmut G8 src/vsmx.c "if (v->sp > (f ? f->base : 0)) v->sp--;" "v->sp = f ? f->base : 0;"
  gmut G9 src/menu.c "affine root = { (float)w / sw, 0, -sx * (float)w / sw, 0, -(float)h / sh, sy * (float)h / sh };" \
                     "affine root = { (float)w / sw, 0, -sx * (float)w / sw, 0, (float)h / sh, sy * (float)h / sh };"
  gmut G10 src/menu.c "        float dx = ah == 1 ? qw * 0.5f : ah == 2 ? -qw * 0.5f : 0.0f;" "        float dx = qw * 0.5f; (void)ah;"
  gmut G11 src/menu.c "    return menu_render_view(m, px, w, h, stride, layout, -427.0f, 240.0f, 854.0f, 480.0f);" \
                      "    return menu_render_view(m, px, w, h, stride, layout, -240.0f, 136.0f, 480.0f, 272.0f);"
  gmut G12 src/menu.c "            vm_obj *kids = vm_new_array(m->v, 0);" "            vm_obj *kids = vm_new_object(m->v, \"children\");"
  gmut G13 src/vsmx.c "vm_objv(vm_new_native(v, \"Array\", nat_array, NULL))" "vm_objv(vm_new_native(v, \"Array\", nat_tostring, NULL))"
  gmut G14 src/menu.c "    if (m->ntw == m->tw_cap) {" "    tween_cancel(m, ni, prop); if (m->ntw == m->tw_cap) {"
  gmut G17 src/menu.c "layout == MENU_PX_PLANE ? 2 : 0, layout == MENU_PX_PLANE ? 0 : 2, 0 };" "layout == MENU_PX_PLANE ? 0 : 0, layout == MENU_PX_PLANE ? 2 : 2, 0 };"
  gmut G18 src/menu.c "    callback(m, m->controller, \"onContinuePlay\", 0, NULL);" "    callback(m, m->controller, \"onAutoPlay\", 0, NULL);"
  gmut G19 src/menu.c "    return m->has_userdata ? kept_out(&m->userdata, buf, cap, 0) : 0;" "    return (m->has_userdata && 0) ? kept_out(&m->userdata, buf, cap, 0) : 0;"
  gmut G20 src/menu.c "        k->t = V_NUM; k->n = strtof(num, &e);" "        k->t = V_NUM; k->n = 0.0f * strtof(num, &e);"
  gmut G21 src/vsmx.c "        case OP_TRY_IN:" "        case 0x141:"
  gmut G22 src/vsmx.c "&& (a.u.o->nothing || b.u.o->nothing)) return 1;" "&& a.u.o == b.u.o) return 1;"
  gmut G23 src/menu.c "if (nd->last_focus >= 0 && (M->focus < 0 || M->nodes[M->focus].page != M->active_page)) set_focus(M, nd->last_focus);" "(void)0;"
  gmut G24 src/vsmx.c "if (k.t == V_NUM && isfinite(k.u.n) && fabsf(k.u.n) < 2147483648.0f)" "if (0)"
  gmut G25 src/menu.c "if (!moving || m->debt >= BUSY_MAX_MS) return 0;" "return 0;"
  gmut G26 src/menu.c "if (parent) vm_set(m->v, o, \"parent\", vm_objv(parent));" "(void)parent;"
  gmut G27 src/menu.c "    if (vm_error_catchable(m->v)) {" "    if (0) {"
  gmut G28 src/vsmx.c "    if (((a.t == V_UNDEF || a.t == V_NULL) && is_nothing(b)) || ((b.t == V_UNDEF || b.t == V_NULL) && is_nothing(a))) return 1;" "    (void)is_nothing;"
  gmut G29 src/vsmx.c "if ((a.t == V_OBJ && b.t == V_STR) || (a.t == V_STR && b.t == V_OBJ)) {" "if (0) {"
  gmut G30 src/menu.c "    natf(m, m->proto_obj, \"getRotate\", n_getRotate);" "    (void)n_getRotate;"
  gmut G32 src/menu.c "const char *cls = (e->table == RCO_T_OBJECT && e->type == 26) ? \"Button\" :" "const char *cls = (e->table == RCO_T_OBJECT && e->type == 26) ? \"UButton\" :"
  gmut G33 src/menu.c "            tween_start(m, tn_i, P_POS, to, 7, ms); break;" "            for (int k = 0; k < 3; k++) { to[k] += m->nodes[tn_i].pos[k]; } tween_start(m, tn_i, P_POS, to, 7, ms); break;"
  gmut G37 src/menu.c "    if (nd->table == RCO_T_OBJECT && nd->type == 1 && !nd->visible) {" "    if (nd->table == RCO_T_OBJECT && nd->type == 1) {"
  gmut G36 src/menu.c "        if (M->focus >= 0 && (M->focus == pi || M->nodes[M->focus].page == pi)) {" "        if (0) {"
  gmut G35 src/menu.c "            n += node_reset(M, c) | hid;" "            n += hid;"
  gmut G38 src/menu.c "for (int X = xs; X < xe; X++, U += du, V += dv) {" "for (int X = xs; X < xe; X++, U += du, V += dv >> 8) {"
  gmut G34 src/menu.c "        u_first = (int32_t)lroundf(((fx0 + (float)(xs - ix0) * dfx) * (float)im->w - 0.5f) * 65536.0f);" "        u_first = (int32_t)lroundf(((fx0 + (float)(xs - ix0) * dfx) * (float)im->w + 1.5f) * 65536.0f);"
  gmut G16 src/menu.c "        float dx = ah == 1 ? qw * 0.5f : ah == 2 ? -qw * 0.5f : 0.0f;" "        float dx = ah == 2 ? -qw * 0.5f : 0.0f;"
  gmut G49 src/menu.c "        float dy = av == 1 ? -qh * 0.5f : av == 2 ? qh * 0.5f : 0.0f;" "        float dy = 0.0f;"
  gmut G53 src/menu.c "    if (anim && prop == P_ROT) {" "    if (0 && prop == P_ROT) {"
  gmut G52 src/menu.c "    tween_cancel(m, (int)(nd - m->nodes), prop);
    tween_start(m, (int)(nd - m->nodes), prop, to, mask, ms);" "    tween_start(m, (int)(nd - m->nodes), prop, to, mask, ms);"
  gmut G54 src/menu.c "        if (m->runs[i].node == ni && m->runs[i].cursor >= 0) {" "        if (0) {"
  gmut G55 src/menu.c "    if (nd->fi_pending >= 0 && M->focus == nd->fi_pending && M->now != nd->fi_t && !M->err[0]) {" "    if (0) {"
  gmut G56 src/menu.c "    if (nd->fi_pending >= 0 && M->focus == nd->fi_pending && M->now != nd->fi_t && !M->err[0]) {" "    if (nd->fi_pending >= 0 && M->focus == nd->fi_pending && !M->err[0]) {"
  gmut G51 src/menu.c "    float cx = cosf(nd->rot[0]), sx = sinf(nd->rot[0]), cy = cosf(nd->rot[1]), sy = sinf(nd->rot[1]);" "    float cx = 1.0f, sx = 0.0f, cy = cosf(nd->rot[1]), sy = sinf(nd->rot[1]);"
  gmut G57 src/menu.c "            if (qw == 0 || fw != 0) qw = (float)im->w;" "            if (qw == 0) qw = (float)im->w;"
  gmut G58 src/menu.c "            if (qh == 0 || fw != 0) qh = (float)im->h;" "            qh = (float)im->h; qw = (float)im->w;"
  gmut G59 src/menu.c "    if (m->tw_src >= 0) {" "    if (0) {"
  gmut G60 src/menu.c "        if (m->h.change_resource) m->h.change_resource(m->h.ud, name);" ""
  gmut G61 bench/menu_run.c "    P.held = p->n > 0 && p->a[0] == 1;" "    P.held = 0;"
  gmut G62 src/menu.c "pcol[2] * nd->col[2], nd->col[3] };" "pcol[2] * nd->col[2], pcol[3] * nd->col[3] };"
  gmut G63 src/menu.c "        alpha_down(m, m->nodes[ni].ent, to[3], dur);" "        (void)alpha_down;"
  gmut G64 src/menu.c "        const float to[4] = { 0, 0, 0, m->nodes[di].base_a * a };" "        const float to[4] = { 0, 0, 0, attr_f(&m->r.e[c], \"alphaScale\", 1.0f) * a };"
  gmut G65 src/menu.c "        const float to[4] = { 0, 0, 0, m->nodes[di].base_a * a };" "        const float to[4] = { 0, 0, 0, a };"
  gmut G66 src/menu.c "            r->cursor = -1;" "            (void)0;"
  gmut H49 src/vsmx.c "                    if (!vm_is_func(a) && vm_is_func(self) &&" "                    if (0 && vm_is_func(self) &&"
  gmut G50 src/menu.c "        float dx = ah == 1 ? qw * 0.5f : ah == 2 ? -qw * 0.5f : 0.0f;" "        float dx = ah == 1 ? qw * 0.5f : 0.0f;"
  gmut G15 src/menu.c "    tween_start(m, (int)(nd - m->nodes), prop, to, mask, ms);" \
                      "    if (prop != P_SCALE) tween_start(m, (int)(nd - m->nodes), prop, to, mask, ms);"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
