#!/usr/bin/env python3
"""menu_gate.py -- P9 M1b's gate: the menu engine (main/support/umd/menu/) on the PC runs each
captured disc's startup chain to its main menu and a key path through it, as the PSP did
(docs/p9.md S2: the maintainer's captures, 2026-10-01).

    menu_gate.py [--iso-dir DIR] [--run MENU_RUN] [--fx DIR]

Each disc's fixture (its RCOs and playlist timing) comes from its image through
tools/menu_fixture.py (the P1 parsers, never the engine's code). bench/umd/menu/menu_run.c plays
the disc with a model player and a key script; the trace must hold every checkpoint IN ORDER,
each inside its time window, and end without the engine stopping. The checkpoints are what the
captures show (startup RCO, which clip plays when, which button is lit, what a key does), not
what the engine happened to print. One is the model player's, not a capture's (marked MODEL).
Prints "PASS: menu_gate" or "FAIL"; "SKIP" (exit 0) with no image of any captured disc.

    menu_gate.py --host [--seeds N] [--run-host MENU_HOST_CHECK]

M3: the SAME scenarios through the UMD Main's whole menu path (bench/umd/menu/menu_host_check.c:
the engine, umd_menu_host, umd_menu_logic, the image read by umd_iso, a core model with seeks of
50-400 ms), N seeds each, plus the host's own scenarios ("host": True). Read for the host: a window
(0, 0) is (0, 1000) (the mount lands first); a window of one instant (a scheduled relaunch) stays;
the others go (each clip starts a seek later: ORDER and "never" carry the check); a "resume" is a
PLAYLIST at a place ("PLAYER play playlist N at T ms", T within 1.5 s before the model's: the
place is the last HOST_RD's); the pictures stay menu_run's.
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (time, regex) in order: time None (any), (lo, hi) ms inclusive, or "never" (no line from the
# previous checkpoint to the end may match); ("within", MS): within MS ms of the previous checkpoint's line
DISCS = [
    {
        # P9 M4b, one tween a property (the maintainer on the rig, 2026-10-04: MCR disc 2's highlights
        # "sometimes don't clear when another selection is made"): six Downs 300 ms apart (the focus
        # animation still running at each). The checkpoint: one highlight lit at the end -- the focused one
        # (the last FOCUS line names it) -- every other button's highlight clear (alpha 0: not drawn).
        "key": "mcr2-quick",
        "iso": "My Chemical Romance - Life on the Murder Scene Disc-02",
        "args": ["--ms", "39000"] + sum((["--key", "%d:DOWN" % (34000 + 300 * k)] for k in range(6)), []),
        "expect": [
            ((29000, 31000), r"FOCUS btnMMPlay_playAll$"),
            ((35200, 35800), r"FOCUS btnMMPlay_playAll$"),       # the press at 35.2 s comes round to it
        ],
        "draw": [
            {"t": 38500, "size": "720x480", "tol": 15.0, "alpha": {},
             "centres": {"btnMMPlay_playAll": (603.0, 93.0)},
             "absent": ["btnMMPlay_livePerformances", "btnMMPlay_tvAppearances", "btnMMPlay_onlinePerformances",
                        "btnMMPlay_videos"]},
        ],
    },
    {
        # P9, one playback an animation (the maintainer on the rig, 2026-10-04, a screenshot: MCR disc 2
        # left three highlights lit after "pressing back and forth between the bottom two options"). Two
        # Downs to TV Appearances, then Left / Right 550 ms apart -- each press just after the focus
        # animation's Unlock (+500), its 750-800 ms Recolours still running -- across the menu video's
        # Loop_HL_ON mark (~40.1 s), whose page re-open focuses another button while TV's animOpenMenu_01
        # still runs. The checkpoint (the maintainer's expectation, as on every other menu: one highlight,
        # the focused one): at the end every button but TV Appearances, the last focused, is clear.
        "key": "mcr2-rapid",
        "iso": "My Chemical Romance - Life on the Murder Scene Disc-02",
        "args": ["--ms", "46200", "--key", "34000:DOWN", "--key", "35000:DOWN"]
                + sum((["--key", "%d:%s" % (37000 + 550 * k, "LEFT" if k % 2 == 0 else "RIGHT")] for k in range(12)), []),
        "expect": [
            # (windows of 100 ms: through the UMD Main's path, --host, a key lands on its 10 ms tick early;
            #  the mark is "PLAYER mark" on the PC, "HOST mark" there, at 40.1-40.7 s)
            ((34900, 35100), r"FOCUS btnMMPlay_tvAppearances$"),
            ((39000, 41500), r"mark Loop_HL_ON"),                  # the scenario crosses the loop's re-open
            ((42950, 43150), r"FOCUS btnMMPlay_tvAppearances$"),   # the twelfth press, a Right, lands on TV
        ],
        "draw": [
            {"t": 46000, "size": "720x480", "tol": 15.0, "alpha": {}, "centres": {},
             "absent": ["btnMMPlay_playAll", "btnMMPlay_livePerformances", "btnMMPlay_onlinePerformances",
                        "btnMMPlay_videos"]},
        ],
    },
    {
        # P9 M4b, the 3-D scene and Function.prototype.call (the maintainer on the rig, 2026-10-04: Astro
        # Boy's options overlapped after a press, and its submenu took no key). The carousel is a DRUM: the
        # script puts the four labels at y / z on a circle of radius 90 and turns their Group about X on
        # Up / Down, each label counter-turned. The checkpoints: the drum's own places at rest (its front at
        # y 244.25, its top 155.0, its bottom 335.0 of 480, the three labels' centres before the press, from
        # the script's setPos -- not the turned render): after Down the focused label (root_audio) at the
        # front, the last one (root_play) on top, the next (root_subs) below. Then Cross: its timer opens the
        # page by `f.call(...)` -- AudioMenu opens, no script error.
        "key": "astro-drum",
        "iso": "Astro Boy Volume 1",
        "args": ["--ms", "26000", "--key", "20000:DOWN", "--key", "22000:CROSS"],
        "expect": [
            ((14000, 16000), r"FOCUS RootMenuButton$"),
            (None, r"KEY DOWN \(focus RootMenuButton, page RootMenu\)"),
            (None, r"KEY CROSS \(focus RootMenuButton, page RootMenu\)"),
            (None, r"AudioMenu\.open\(\)$"),
            (None, r"FOCUS AudioMenuButton$"),
            ("never", r"SCRIPT ERROR"),
        ],
        "draw": [
            {"t": 21000, "size": "720x480", "tol": 3.0, "alpha": {},
             "centres": {"root_audio": (360.0, 244.25), "root_play": (360.0, 155.0), "root_subs": (360.0, 335.0)}},
        ],
    },
    {
        # P9 M4b, a script's rotation takes the short way (the maintainer on the rig, 2026-10-04: at the
        # last option the drum "should rotate the same direction ... instead of ... rotating backwards a
        # lot"). Three Downs; the third wraps (the script's target goes from -pi to +pi/2). Checkpoint, from
        # the drum's geometry (radius 90, front y 244.25; 120 ms into a 250 ms quarter turn = 43.2 deg): the
        # label coming up from the bottom (root_trailer) at 244.25 + 90 cos 43.2 = 309.9, the one going up to
        # the top (root_subs) at 244.25 - 90 sin 43.2 = 182.6 -- the same roll as every other Down.
        "key": "astro-wrap",
        "iso": "Astro Boy Volume 1",
        "args": ["--ms", "24300", "--key", "20000:DOWN", "--key", "22000:DOWN", "--key", "24000:DOWN"],
        "expect": [
            ((14000, 16000), r"FOCUS RootMenuButton$"),
            (None, r"RootMenuNav\.animRotate\(1\.570796, 0, 0, 250\)$"),   # the wrapped target
        ],
        "draw": [
            {"t": 24120, "size": "720x480", "tol": 3.0, "alpha": {},
             "centres": {"root_trailer": (360.0, 309.9), "root_subs": (360.0, 182.6)}},
        ],
    },
    {
        # P9 M4b, the RIGHT anchor (iconOffset 2): Astro Boy's main menu -- the carousel template it shares
        # with Men in Black, Spider-Man and A Few Good Men -- draws its labels (texRootPlay / Audio /
        # Trailer) right-anchored at x 0 of a parent the script centres. The checkpoint: the screen's centre
        # across (x 360 of 720), the labels' authored layout -- the old centre rule pushed them ~180 px
        # right, "Play All Episodes" clipped at the screen's edge; on the rig (2026-10-04) centred as here.
        "key": "astro-anchor",
        "iso": "Astro Boy Volume 1",
        "args": ["--ms", "20100"],
        "expect": [
            ((0, 0), r"RESOURCE EN100000 "),
            ((14000, 16000), r"FOCUS RootMenuButton$"),
        ],
        "draw": [
            {"t": 20000, "size": "720x480", "tol": 8.0, "alpha": {},
             "centres_x": {"root_play": 360.0, "root_audio": 360.0, "root_trailer": 360.0}},
        ],
    },
    {
        # P9 M4b (the maintainer on the rig, 2026-10-04: "the highlights do not line up with the options"):
        # My Chemical Romance disc 2's main menu -- every button iconOffset 17, the TOP-LEFT anchor. The
        # options are lettered in the menu VIDEO (playlist 1 = clip 00002); the checkpoints are where that
        # video's ink is (each option's box and lettering, dark pixels in its frame at 34 s / 37 s,
        # extracted with ffmpeg: "Play all" x 530-676 y 75-111, "Live Performances" x 488-683 y 330-382 --
        # rough, the hand's shadow bleeds in: tol 15). Centre anchoring drew them 62 / 30 and 85 / 20 px off.
        "key": "mcr2",
        "iso": "My Chemical Romance - Life on the Murder Scene Disc-02",
        "args": ["--ms", "38000", "--key", "36000:DOWN"],
        "expect": [
            ((0, 0), r"RESOURCE EN100000 "),
            ((0, 0), r"PLAYER play playlist 1 chapter 1 "),        # the motion menu, its options in the video
            ((29000, 31000), r"FOCUS btnMMPlay_playAll$"),          # at its HL_On mark (29.86 s)
            (None, r"KEY DOWN \(focus btnMMPlay_playAll, page pageMM_01\)"),
            (None, r"FOCUS btnMMPlay_livePerformances$"),
        ],
        "draw": [
            {"t": 34000, "size": "720x480", "tol": 15.0,
             "centres": {"btnMMPlay_playAll": (603.0, 93.0)}, "alpha": {}},
            {"t": 37000, "size": "720x480", "tol": 15.0,
             "centres": {"btnMMPlay_livePerformances": (585.5, 356.0)}, "alpha": {}},
        ],
    },
    {
        "key": "fg",
        "iso": "Family Guy - Freakin' Sweet Collection",
        "args": ["--ms", "70000", "--key", "15000:DOWN", "--key", "17000:CROSS", "--key", "25000:CIRCLE",
                 "--key", "30000:DOWN", "--key", "32000:CROSS", "--key", "38000:CROSS"],
        "expect": [
            ((0, 0), r"RESOURCE EN100000 "),                       # <lang>100000.RCO starts
            ((0, 0), r"PLAYER play playlist 9 chapter 1 "),        # its motion menu
            ((0, 10000), r"FOCUS btnMainEp01$"),                   # opens on its menu, Ep01 lit
            (None, r"KEY DOWN \(focus btnMainEp01, page pageRoot\)"),
            (None, r"FOCUS btnMainEp02$"),
            (None, r"KEY CROSS \(focus btnMainEp02, page pageRoot\)"),
            (None, r"FOCUS btnPlay$"),                             # the episode page (1:22)
            (None, r"KEY CIRCLE \(focus btnPlay, page pageEpisode\)"),  # Circle in a sub-page
            (None, r"KEY DOWN \(focus btnMainEp0\d, page pageRoot\)"),  # ... returns (1:28)
            (None, r"KEY CROSS \(focus btnMainEp0\d, page pageRoot\)"),
            (None, r"KEY CROSS \(focus btnPlay, page pageEpisode\)"),   # Play Episode (1:42)
            (None, r"PLAYER play playlist 15 chapter 1 "),         # Fox's ATTENTION clip
            (None, r"RESOURCE EN000001 "),                         # its own FBI page
            (None, r"RESOURCE EN100000 "),
            (None, r"PLAYER play playlist [1-5] chapter 1 "),      # the episode (2:12)
        ],
        # M1c, the picture: where menu_render draws the main menu's six titles at 10 s on the PSP's
        # 480 x 272, against their centres MEASURED in the capture at 12 s (the PSP's screen
        # perspective-warped out of the phone frame, each title's edges aligned to the render's:
        # every offset within 6 px at 1920 x 1088, the warp's own precision; docs/p9.md S3.3 M1c)
        "draw": [{
            "t": 10000, "size": "480x272", "tol": 3.0,
            "centres": {"btnMainEp01": (297.6, 40.3), "btnMainEp02": (297.4, 86.0), "btnMainEp03": (296.9, 131.0),
                        "btnMainEp04": (296.4, 175.8), "btnMainEp05": (296.1, 220.6), "btnMainPreviews": (296.6, 257.5)},
            # the focused Ep01 at 1.1x (the capture's lettering fits the render best at 1.1x: edge
            # correlation 0.557 vs 0.423 at 1.0x)
            "width_ratio": ("btnMainEp01", "btnMainEp02", 1.10, 0.02),
            # MODEL: Ep01 lit, the others at their 0.7 (the camera saturates; the script's intent)
            "alpha": {"btnMainEp01": 1.0, "btnMainEp02": 0.7},
        }],
    },
    {
        "key": "akira",
        "iso": "Akira",
        "args": ["--ms", "100000", "--key", "50000:CROSS", "--key", "70000:SQUARE", "--key", "82000:CROSS"],
        "expect": [
            ((0, 0), r"RESOURCE EN100000 "),
            ((0, 0), r"PLAYER play playlist 5 chapter 1 "),        # the warning / logo clips (0:00)
            ((39000, 41000), r"PLAYER play playlist 6 chapter 1 "),  # then the motion menu (0:44)
            ((39000, 45000), r"FOCUS btnPlay$"),
            (None, r"KEY CROSS \(focus btnPlay, page pageRoot\)"),
            (None, r"PLAYER play playlist 1 chapter 1 "),          # the first Cross plays the film
            (None, r"KEY SQUARE "),
            (None, r"CALLBACK controller\.onMenu$"),               # Square in playback: the menu
            (None, r"PLAYER play playlist 6 chapter 1 "),          # (1:32-1:34)
            (None, r"KEY CROSS \(focus btnPlay, page pageRoot\)"),
            (None, r"PLAYER resume playlist 1 at 20000 ms"),       # MODEL: the player's resume point
            ("never", r"PLAYER play playlist 1 chapter 1 "),       # ... continued, not restarted
        ],
        # the menu bar (RootBackground) with PLAY lit (btnPlay's overlay, the same box) at 45 s, against
        # the capture at 50 s: offset (+4, -5) px at 1920 x 1088 (the LCD's pixel grid shows as moire
        # in this capture, so its edge correlation is weak, 0.14; the crops agree by eye)
        "draw": [{
            "t": 45000, "size": "480x272", "tol": 3.0,
            "centres": {"RootBackground": (330.9, 253.6), "btnPlay": (330.9, 253.6)},
            "alpha": {"btnPlay": 1.0},
        }],
    },
    {
        "key": "ap2",
        "iso": "Austin Powers - The Spy Who Shagged Me",
        "args": ["--ms", "90000", "--key", "20000:DOWN", "--key", "22000:CROSS"],
        "expect": [
            ((0, 0), r"RESOURCE EN100000 "),
            ((0, 0), r"PLAYER play playlist 2 chapter 1 "),        # the SF logo
            ((13000, 13100), r"PLAYER play playlist 8 chapter 1 "),  # then the language page
            ((13000, 13100), r"Nav\.setFocus\(\)$"),               # ... up, its selector focused
            (None, r"KEY DOWN \(focus Nav, page pageRootMenu\)"),
            (None, r"HANDLER Nav\.onFocusDown$"),
            (None, r"KEY CROSS \(focus Nav, page pageRootMenu\)"),
            (None, r"HANDLER Nav\.onPush$"),
            (None, r"PLAYER play playlist 5 chapter 1 "),          # Norsk's warning (video_warning_no = 5; the
                                                                   # capture: Down to Norsk, Cross, "Advarsel", 1:14)
            (None, r"PLAYER play playlist 7 chapter 1 "),          # the main menu
        ],
        # the language page's four names, drawn from script (Chapter_menu2: setPos / animScale 1.45 /
        # animColor), against the capture at 40 s (hand-placed corners refined to the screen's edge;
        # every offset within 7 px at 1920 x 1088): Svenska lit, the others dim as the capture shows
        "draw": [{
            "t": 16000, "size": "480x272", "tol": 3.0,
            "centres": {"CMLS_1_1": (340.5, 87.6), "CMLS_1_2": (340.5, 121.4), "CMLS_1_3": (340.5, 154.9),
                        "CMLS_1_4": (340.5, 188.6)},
            "alpha": {"CMLS_1_1": 1.0, "CMLS_1_2": 0.5},
        }, {
        # the main menu after Norsk's warning: its four items are iconOffset-1 planes, positioned by
        # their LEFT edge and scaled about it (Play Movie lit at 1.4x, the rest 1.0x at 0.6), against
        # the capture at 85 s. The phone's lens bends the warp near the frame's edges: the video's own
        # static art there (the logo, beside the items) reads -17 px at 1920, the items -21, so the
        # centres below are the render's corrected by the art's local offset (1 px at 480 x 272)
            "t": 35000, "size": "480x272", "tol": 3.0,
            "centres": {"CMMM_1_1": (129.1, 175.6), "CMMM_1_2": (99.5, 198.3), "CMMM_1_3": (99.5, 220.9),
                        "CMMM_1_4": (99.5, 243.6)},
            "alpha": {"CMMM_1_1": 1.0, "CMMM_1_2": 0.6},
        }],
    },
]

# X-Men (2000): its startup to the main menu (the maintainer's capture 2026-10-02, 20261002_085643:
# the PSP's clip starts take ~1 s, its gaps between clips ~8 s of disc seeking, neither modelled), the
# first disc measured with try / catch, `[] == []` and a group Rotate (docs/p9.md M3)
DISCS += [
    {
        "key": "xmen", "iso": "X-Men (2000)",
        "args": ["--ms", "110000"],
        "expect": [
            ((0, 0), r"RESOURCE EN100000 "),
            ((0, 0), r"PLAYER play playlist 13 chapter 1 "),       # the piracy advert (0:04)
            (None, r"PLAYER play playlist 17 chapter 1 "),         # the copy warnings (0:52)
            (None, r"PLAYER play playlist 3 chapter 1 "),          # 20th Century Fox (1:12)
            (None, r"PLAYER play playlist 2 chapter 1 "),          # the menu's video (1:36)
            (None, r"pgMM\.open\(\)"),                           # the main menu's page, in MMAnim's try
        ],
        # the four orbs: none 9.6 s after the menu's play() (the capture: none until ~13 s), then their
        # places after the group's fade and rotations, measured at 20 s (the capture's 1:52.5: every
        # orb within 11 px at 1920 x 1088)
        "draw": [{
            "t": 98000, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
            "absent": ["mmBtnPlay", "mmBtnSf", "mmBtnSetup", "mmBtnPrev"],
        }, {
            # (M4) mid-turn: the orb group rotates 2.2 s from 101.38 s -- the renderer's ROTATED path
            # (draw_affine) against its general path at a live rotation (whole turns land axis-aligned)
            "t": 102500, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
        }, {
            "t": 108400, "size": "480x272", "tol": 3.0,
            "centres": {"mmBtnPlay": (153.8, 57.1), "mmBtnSf": (332.4, 46.9), "mmBtnSetup": (150.3, 225.0),
                        "mmBtnPrev": (330.5, 222.8)},
            "alpha": {},
            # (fj#69, the maintainer's PSP 2026-10-10: settled, only the focused button has its glow)
            "present": ["mmBtnPlayBlur"], "absent": ["mmBtnSfBlur", "mmBtnSetupBlur", "mmBtnPrevBlur"],
        }],
    },
]

# X-Men's relaunches (the maintainer, 2026-10-02, on the PSP): quit during the logo -> the logo again
# from its start, as a fresh boot; quit from the menu after a playback -> back at the menu
DISCS += [
    {
        "key": "xmen-relaunch-logo", "fx": "xmen", "iso": "X-Men (2000)",
        "args": ["--ms", "40000", "--relaunch", "20000"],
        "expect": [
            ((0, 0), r"PLAYER play playlist 13 chapter 1 "),       # the advert
            ((20000, 20000), r"RELAUNCH: quit"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER play playlist 13 chapter 1 "),         # the advert from its start ...
            ("never", r"PLAYER resume "),                          # ... not resumed mid-way
        ],
    },
    {
        "key": "xmen-relaunch-menu", "fx": "xmen", "iso": "X-Men (2000)",
        "args": ["--ms", "175000", "--key", "107000:CROSS", "--key", "125000:SQUARE", "--relaunch", "150000"],
        "expect": [
            (None, r"KEY CROSS \(focus mmBtnPlay, page pgMM\)"),  # Play Movie
            (None, r"PLAYER play playlist 1 chapter 1 "),          # the film
            (None, r"CALLBACK controller\.onMenu$"),               # Square: the menu
            (None, r"PLAYER play playlist 2 chapter 2 "),
            ((150000, 150000), r"RELAUNCH: quit"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER play playlist 2 chapter 2 "),          # back at the menu
            ("never", r"PLAYER play playlist 13 "),                # no advert
        ],
    },
]

# M1d, RELAUNCH (menu.h): quitting calls onExit and keeps the user data and the player's resume
# point; launching again calls onContinuePlay. The captures (docs/p9.md S2): Akira relaunched goes
# back into its film (1:28), Austin Powers 2 back to its main menu without logo or language (1:42).
DISCS += [
    {
        "key": "akira-relaunch", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "80000", "--key", "50000:CROSS", "--relaunch", "60000"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),          # the film
            ((60000, 60000), r"RELAUNCH: quit"),
            (None, r"CALLBACK controller\.onExit$"),
            (None, r"RELAUNCH: \d+ bytes of user data kept, resume point kept"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER resume playlist 1 at 10000 ms"),       # back into the film
            ("never", r"PLAYER play playlist [56] "),              # not the logos, not the menu
        ],
    },
    {
        "key": "ap2-relaunch", "fx": "ap2", "iso": "Austin Powers - The Spy Who Shagged Me",
        "args": ["--ms", "60000", "--key", "20000:DOWN", "--key", "22000:CROSS", "--relaunch", "40000"],
        "expect": [
            (None, r"PLAYER play playlist 7 chapter 1 "),          # the main menu
            ((40000, 40000), r"RELAUNCH: quit"),
            (None, r"CALLBACK controller\.onExit$"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER play playlist 7 chapter 1 "),          # back to the main menu ...
            ("never", r"PLAYER play playlist [28] "),              # ... without the logo or the language page
        ],
    },
]

# M3, the UMD Main's own rules (umd_menu_host.h), through menu_host_check only. A checkpoint's time
# may be ("first", FILTER): the first line after the previous checkpoint that matches FILTER must
# match the checkpoint's regex.
DISCS += [
    {
        # the mount, the levels: STOP before the script's first play (the stop screen behind `menu`,
        # not the feature); MENU grabs every button with `menu` up, `ui` once a page is open;
        # CONTENT (an episode) grabs Square and Circle with `menu` down; Square reaches the script
        # (onMenu) and the levels come back
        "key": "fg-host-levels", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "75000", "--key", "15000:DOWN", "--key", "17000:CROSS", "--key", "25000:CIRCLE",
                 "--key", "30000:DOWN", "--key", "32000:CROSS", "--key", "38000:CROSS", "--key", "70000:SQUARE"],
        "expect": [
            ("never", r"HOST disc screen up"),            # RS4: the engine runs (its own STOP at the start)
            (None, r"HOST start EN100000: the engine runs"),
            (None, r"CORE levels grab 0xfff ui 0 menu 1$"),
            (("first", r"PLAYER (stop|play|busy)"), r"PLAYER stop$"),
            (None, r"PLAYER play playlist 9 chapter 1 "),
            (None, r"CORE levels grab 0xfff ui 1 menu 1$"),
            (None, r"KEY CIRCLE \(focus btnPlay, page pageEpisode\)"),  # a sub-page's Circle: the script's
            (None, r"CORE levels grab 0x840 ui 0 menu 0$"),
            (None, r"PLAYER play playlist [1-5] chapter 1 "),       # the episode
            ((70000, 70000), r"CORE key SQUARE -> host"),
            (None, r"CALLBACK controller\.onMenu$"),
            (None, r"CORE levels grab 0xfff ui [01] menu 1$"),
            ("never", r"QUIT"),
        ],
    },
    {
        # Circle the script does not take is the PSP's system stop (P9-6; docs/p9.md S2: the three
        # captures, "at the top page and during playback"): at Family Guy's top page ...
        "key": "fg-host-quit", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "16000", "--key", "12000:CIRCLE"],
        "expect": [
            (None, r"FOCUS btnMainEp01$"),
            ((11900, 12000), r"KEY CIRCLE \(focus btnMainEp01, page pageRoot\)"),
            (None, r"HOST Circle not the script's: quit the disc"),
            (None, r"CALLBACK controller\.onExit$"),
            ((12000, 12000), r"QUIT \(P9-6\)"),
            (None, r"PLAYER stop$"),
            ("never", r"PLAYER play"),
        ],
    },
    {
        # ... during Akira's warning (the maintainer's test, 2026-10-02: back to the XMB) ...
        "key": "akira-host-warning-quit", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "8000", "--key", "5000:CIRCLE"],
        "expect": [
            (None, r"PLAYER play playlist 5 chapter 1 "),
            ((5000, 5000), r"CORE key CIRCLE -> host"),
            (None, r"HOST Circle not the script's: quit the disc"),
            ((5000, 5000), r"QUIT \(P9-6\)"),
            (None, r"PLAYER stop$"),
            ("never", r"PLAYER play"),
        ],
    },
    {
        # ... and in the film, which the image selected again resumes (Akira's capture, 1:28: the
        # relaunch went back into the film)
        "key": "akira-host-film-quit", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "80000", "--key", "50000:CROSS", "--key", "65000:CIRCLE", "--relaunch", "70000"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            ((65000, 65000), r"CORE key CIRCLE -> host"),
            (None, r"CALLBACK controller\.onExit$"),
            ((65000, 65000), r"QUIT \(P9-6\): \d+ bytes kept, resume point kept"),
            ((70000, 70000), r"RELAUNCH: the image selected again"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (13500, 15000)),
            ("never", r"PLAYER play playlist 1 chapter 1 "),
        ],
    },
    {
        # RS1 (docs/resume.md): the kept text on the SD card. A power cut runs nothing (no onExit, no
        # store), so a cut in the film with no exit since keeps no point: the next launch is the PSP's
        # after a reboot -- the disc's own chain from its start
        "key": "akira-host-powercut", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "95000", "--key", "50000:CROSS", "--powercut", "80000"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            ((80000, 80000), r"POWERCUT: 0 bytes on the card, resume point none"),
            (None, r"CALLBACK controller\.onAutoPlay$"),
            (None, r"HOST start EN100000: the engine runs"),
            (None, r"PLAYER play playlist 5 chapter 1 "),          # the logo: a fresh start
            ("never", r"onContinuePlay|PLAYER play playlist 1 "),
        ],
    },
    {
        # ... and a cut after a quit keeps what the quit stored: the next launch is the relaunch
        # (akira-host-film-quit's: onContinuePlay, the film at its point)
        "key": "akira-host-quit-powercut", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "95000", "--key", "50000:CROSS", "--key", "65000:CIRCLE", "--powercut", "70000"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            ((65000, 65000), r"QUIT \(P9-6\): \d+ bytes kept, resume point kept"),
            ((70000, 70000), r"POWERCUT: \d+ bytes on the card, resume point kept playlist 1 at (\d+) ms", (13500, 15000)),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"HOST start EN100000 \(continue\): the engine runs"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (13500, 15000)),
            ("never", r"PLAYER play playlist [15] chapter 1 "),
        ],
    },
    {
        # ... and a card that refuses the writes (full, read-only): each refusal traced and counted, a
        # repeat retried (nothing is known to be on the card), the disc plays on; the cut keeps nothing
        "key": "akira-host-cardfull", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "75000", "--key", "50000:CROSS", "--key", "65000:CIRCLE", "--powercut", "70000", "--card-full"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            # (fj#89: the quit keeps the point BEFORE onExit -- the R line alone, then onExit's setUserData)
            (None, r"HOST the kept text for Akira_8A020D2D8C48A972 NOT written to the card \(38 bytes; 1 refused\)"),
            (None, r"HOST the kept text for Akira_8A020D2D8C48A972 NOT written to the card \(80 bytes; 3 refused\)"),
            ((65000, 65000), r"QUIT \(P9-6\): 0 bytes kept, resume point none"),
            ((70000, 70000), r"POWERCUT: 0 bytes on the card, resume point none"),
            (None, r"HOST start EN100000: the engine runs"),
        ],
    },
    # RS2 (docs/resume.md §3): with no engine (Disc Menus Off) the runner keeps the point itself --
    # saved at Stop, Pause, a quit and the OSD's Reset; resumed at the next mount once the core's own
    # start landed, its audio track and subtitles with it; forgotten at the title's end
    {
        "key": "akira-off-stop-powercut", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "80000", "--menus-off", "--key", "30000:SELECT", "--sub", "31000", "--key", "60000:CIRCLE",
                 "--powercut", "65000"],
        "expect": [
            (None, r"HOST mount: disc Akira_8A020D2D8C48A972, Disc Menus Off"),
            ((30000, 30000), r"CORE key SELECT -> transport audio 1"),
            ((60000, 60000), r"CORE key CIRCLE -> transport stop"),
            (None, r"HOST resume point saved \(stop\): playlist 1 item 0 pts \d+, audio 1, subtitles on 0$"),
            ((65000, 65000), r"POWERCUT: \d+ bytes on the card, resume point kept playlist 1 at (\d+) ms", (58500, 60000)),
            (None, r"HOST resume: playlist 1 "),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (58500, 60000)),
            (None, r"HOST resume landed: playlist 1$"),
            (None, r"PLAYER audio 1$"),
            (None, r"PLAYER subtitles on track 0$"),
            ("never", r"HOST start|CORE levels"),
        ],
    },
    {
        # Pause, then the power off: "pause, then switch off" keeps the place
        "key": "akira-off-pause-powercut", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "60000", "--menus-off", "--key", "40000:CROSS", "--powercut", "50000"],
        "expect": [
            ((40000, 40000), r"CORE key CROSS -> transport pause"),
            (None, r"HOST resume point saved \(pause\): playlist 1 "),
            ((50000, 50000), r"POWERCUT: \d+ bytes on the card, resume point kept playlist 1 at (\d+) ms", (38500, 40000)),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (38500, 40000)),
            (None, r"HOST resume landed: playlist 1$"),
            ("never", r"PLAYER (audio|subtitles)"),             # (track 0, subtitles off: nothing to restore)
        ],
    },
    {
        # the title's end forgets the point (R4) and STOPs to the disc screen (R5c) without writing the
        # end back; Play there restarts the title (R5c), and the Pause after it saves the new place
        "key": "akira-off-end", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "45000", "--menus-off", "--key", "10000:CROSS", "--key", "12000:START", "--skip", "20000:7510000",
                 "--key", "28000:START", "--key", "29000:CROSS", "--powercut", "35000"],
        "expect": [
            (None, r"HOST resume point saved \(pause\): playlist 1 "),
            (None, r"PLAYER end of playlist 1$"),
            (None, r"HOST resume point forgotten: the title ended"),
            ("never", r"HOST resume point saved \(stop\)"),     # (from here on: R5c's STOP writes nothing back)
            (None, r"PLAYER stop$"),
            ((28000, 28000), r"CORE key START -> transport play"),
            (None, r"HOST disc screen: Play after the title's end"),
            ((29000, 29000), r"CORE key CROSS -> transport pause"),
            (None, r"HOST resume point saved \(pause\): playlist 1 "),
            ((35000, 35000), r"POWERCUT: \d+ bytes on the card, resume point kept playlist 1 at (\d+) ms", (0, 1500)),
        ],
    },
    {
        # a point the disc cannot have (a playlist past PLAYLIST.UMD's): forgotten, the disc plays
        "key": "akira-off-badpoint", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "5000", "--menus-off", "--kept", "R 1 99 0 0 57344 48384 1 48512 0"],
        "expect": [
            (None, r"HOST resume point forgotten: its playlist / item is not on the disc"),
            ("never", r"HOST resume:"),
        ],
    },
    {
        # another mount (the image again) saves the point and resumes it
        "key": "akira-off-relaunch", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "50000", "--menus-off", "--relaunch", "40000"],
        "expect": [
            ((40000, 40000), r"HOST resume point saved \(a new mount\): playlist 1 "),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (38500, 40000)),
            (None, r"HOST resume landed: playlist 1$"),
        ],
    },
    {
        # the OSD's Reset (the core idle, no hook) saves it too
        "key": "akira-off-reset", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "50000", "--menus-off", "--idle", "40000", "--relaunch", "45000"],
        "expect": [
            ((40000, 40000), r"CORE Reset"),
            (None, r"HOST resume point saved \(the core went idle\): playlist 1 "),
            ((45000, 45000), r"RELAUNCH: the image selected again \(\d+ bytes kept\)"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (38500, 40000)),
        ],
    },
    # RS4 (docs/resume.md §6, R5): the disc screen -- the disc's art while the core is stopped and no
    # engine runs, under ui + menu, hidden at Play; R5c a title's end STOPs to it and Play restarts the
    # title; R5f after a menu disc's quit, Play relaunches its menus (onContinuePlay)
    {
        "key": "akira-off-discscreen", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "40000", "--menus-off", "--key", "30000:CIRCLE", "--key", "35000:START"],
        "expect": [
            ((30000, 30000), r"CORE key CIRCLE -> transport stop"),
            (None, r'HOST disc screen art: PIC1 480 x 272, ICON0 144 x 80, title "Akira"'),
            (None, r"HOST disc screen up"),
            (None, r"CORE levels grab 0x040 ui 1 menu 1$"),      # (R7: its Stop is the runner's)
            (None, r'HOST disc screen drawn: fit 0, "> Resume 0:00:(\d+)"', (27, 30)),
            ((35000, 35000), r"CORE key START -> transport play"),
            (None, r"HOST disc screen down"),
            (None, r"CORE levels grab 0x000 ui 0 menu 0$"),
        ],
    },
    {
        "key": "akira-off-end-discscreen", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "40000", "--menus-off", "--skip", "10000:7510000", "--key", "25000:START"],
        "expect": [
            (None, r"PLAYER end of playlist 1$"),
            (None, r"PLAYER stop$"),                                # R5c
            (None, r"HOST disc screen up"),
            (None, r'HOST disc screen drawn: fit 0, "> Play"'),
            ((25000, 25000), r"CORE key START -> transport play"),
            (None, r"HOST disc screen: Play after the title's end -- playlist 1 from its start"),
            (None, r"PLAYER play playlist 1 chapter 1 "),
        ],
    },
    {
        "key": "akira-quit-discscreen", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "80000", "--key", "50000:CROSS", "--key", "65000:CIRCLE", "--key", "70000:START"],
        "expect": [
            ((65000, 65000), r"QUIT \(P9-6\)"),
            (None, r"HOST disc screen up"),
            (None, r'HOST disc screen drawn: fit 0, "> Resume 0:00:(\d+)"', (13, 15)),
            ((70000, 70000), r"CORE key START -> transport play"),
            (None, r"HOST disc screen: Play -- the disc's menus again"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (13500, 15000)),
        ],
    },
    {
        # ... and the disc screen goes down with the relaunch (the engine runs again). Its own scenario: the
        # resumed play (above) lands when the core's seek does, a few ms either side of this line -- the order of
        # the two depends on the seeded latencies (M4h's pipeline changed how many flips draw the RNG), not on a rule
        "key": "akira-quit-discscreen-down", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "80000", "--key", "50000:CROSS", "--key", "65000:CIRCLE", "--key", "70000:START"],
        "expect": [
            (None, r"HOST disc screen up"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (("within", 50), r"HOST disc screen down"),
        ],
    },
    {
        # the 4:3 CRT's Letterbox: the page fitted as the menus (analog.md S7)
        "key": "akira-off-discscreen-crt", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "32000", "--menus-off", "--menu-aa", "1000:1", "--key", "30000:CIRCLE"],
        "expect": [
            (None, r"HOST disc screen up"),
            (None, r'HOST disc screen drawn: fit 1, "> Resume'),
        ],
    },
    {
        # X-Men's film end (the maintainer, 2026-10-02: "a bunch of copyright screens in different
        # languages before returning to the menu"): its script plays playlist 21 (70 s, eight 10 s
        # chapters) from PlayDubbingCredit, then its menu loop -- no controller.end()
        "key": "xmen-host-filmend", "fx": "xmen", "iso": "X-Men (2000)", "host": True,
        "args": ["--ms", "200000", "--key", "107000:CROSS", "--skip", "115000:6254000"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            ((115000, 115000), r"CORE skip: playlist 1 at 6254000 ms"),
            (None, r"PLAYER end of playlist 1$"),
            (None, r"PLAYER play playlist 21 chapter 1 "),         # the copyright screens
            (None, r"PLAYER end of playlist 21$"),
            (None, r"PLAYER play playlist 2 chapter 2 "),          # back at the menu
            ("never", r"controller\.end\(\)|QUIT"),
        ],
    },
    {
        # the film's END (reached by a skip): an ended playlist leaves NO resume point (the host's
        # rule), so the menu's next play keeps none and Play starts the film again. controller.end()
        # answering true -- the menu: the PSP's (the maintainer, 2026-10-02: Akira's end "goes to the menu")
        "key": "akira-host-filmend", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "90000", "--key", "50000:CROSS", "--skip", "55000:7510000", "--key", "75000:CROSS"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            ((55000, 55000), r"CORE skip: playlist 1 at 7510000 ms"),
            (None, r"PLAYER end of playlist 1$"),
            ("never", r"HOST resume point: playlist 1 "),          # (traced at the next play(), before its take)
            (None, r"controller\.end\(\)"),
            (None, r"PLAYER play playlist 6 chapter 1 "),          # the PSP: the menu
            ((75000, 75000), r"CORE key CROSS -> host"),
            (None, r"PLAYER play playlist 1 chapter 1 "),          # the film from its start
        ],
    },
    {
        # the startup RCO (umd_mh_pick_start: the rule, not a capture): 4 of 84 discs have no
        # EN100000 -- Iron Man starts from ES100000, Ghost in the Shell 2.0 from JA100000
        "key": "ironman-host-start", "iso": "Iron Man (2008)", "host": True,
        "args": ["--ms", "3000"],
        "expect": [(None, r"RESOURCE ES100000 "), (None, r"HOST start ES100000: the engine runs")],
    },
    {
        # the OSD's Menu Language (O[14:11]) picks the startup menu, as the PSP's UMD Menu Language
        # (the maintainer, 2026-10-02: French opens Transporter 2's FR100000); option 1 is French
        "key": "t2-host-french", "iso": "Transporter 2", "host": True,
        "args": ["--ms", "3000", "--lang-opt", "1"],
        "expect": [(None, r"RESOURCE FR100000 "), (None, r"HOST start FR100000: the engine runs")],
    },
    {
        "key": "gits-host-start", "iso": "Ghost in the Shell 2.0", "host": True,
        "args": ["--ms", "3000"],
        "expect": [(None, r"RESOURCE JA100000 "), (None, r"HOST start JA100000: the engine runs")],
    },
    {
        # the OSD's Reset (the core idle, its image unloaded -- no Main hook fires): the disc is gone,
        # quit (its kept text), every level down -- not a black screen that answers nothing (the
        # review); the image selected again starts it anew
        "key": "akira-host-reset", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "52000", "--idle", "45000", "--relaunch", "48000"],
        "expect": [
            (None, r"FOCUS btnPlay$"),
            ((45000, 45000), r"CORE Reset"),
            (None, r"HOST quit \(the core went idle \(Reset\)\)"),
            (None, r"CORE levels grab 0x000 ui 0 menu 0$"),
            ((48000, 48000), r"RELAUNCH: the image selected again"),
            (None, r"HOST start EN100000"),
        ],
    },
    {
        # THE ASPECT (the maintainer, the first rig session): a menu is always 16:9 (the core presents
        # 16:9 under one), so a 4:3 picture under a menu is pillarboxed by the host's video window --
        # Family Guy's episodes are 4:3 (SAR 10:11), its menu clips 16:9 (40:33): Square in an episode
        # shows the menu over the episode's last picture, pillarboxed, until its 16:9 clip lands
        "key": "fg-host-aspect", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "75000", "--narrow", "1,2,3,4,5", "--key", "15000:DOWN", "--key", "17000:CROSS",
                 "--key", "25000:CROSS", "--key", "70000:SQUARE"],
        "expect": [
            (None, r"PLAYER play playlist [1-5] chapter 1 "),       # the episode: no window (the core's
            (("first", r"CORE window"), r"CORE window 90 0 540x480$"),  # own 4:3), then Square: pillarboxed
            (None, r"PLAYER play playlist 8 chapter 1 "),
            (None, r"CORE window off$"),                           # the 16:9 menu clip landed
        ],
    },
    {
        # ... and a 4:3 clip under the menu for good (the rule, on Family Guy's menu clip marked 4:3:
        # no captured disc has one): pillarboxed while it plays
        "key": "fg-host-narrow-menu", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "20000", "--narrow", "9"],
        "expect": [
            (None, r"PLAYER play playlist 9 chapter 1 "),
            (None, r"CORE window 90 0 540x480$"),
            ("never", r"CORE window off"),
        ],
    },
    {
        # SOUNDS (M3 C): Family Guy's sndMain (its focus sound) placed once in the PCM region and
        # triggered at each play -- 11,536 frames, stereo: ffmpeg's decode of its VAG, 11,536 samples
        # at 48 kHz (tools/menu_vag_check.py's oracle), not this engine's count
        "key": "fg-host-sound", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "18000", "--key", "15000:DOWN", "--key", "17000:DOWN"],
        "expect": [
            (None, r"sndMain\.play\(\)"),
            (None, r"HOST sound [0-9a-f]+ placed at word 0: 11536 frames, stereo"),
            (None, r"CORE pcm start 0 len 11536 stereo"),
            ("never", r"HOST sound [0-9a-f]+ placed"),                # placed once ...
            (None, r"KEY DOWN"),
            (None, r"CORE pcm start 0 len 11536 stereo"),          # ... played again
        ],
    },
    {
        # a slow mount (an image on a share): the engine waits for it to land, its first play is
        # not refused (umd_menu_host.h "THE MOUNT")
        "key": "akira-host-slowmount", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "6000", "--mount-lat", "3000"],
        "expect": [
            ((3000, 3100), r"HOST start EN100000: the engine runs"),
            (None, r"PLAYER play playlist 5 chapter 1 "),
            ("never", r"PLAYER busy"),
        ],
    },
]

# The maintainer's PSP tests of 2026-10-02 (docs/p9.md S2), on Akira: each checkpoint marked with
# what the PSP did. Through menu_run and the UMD Main's path alike.
DISCS += [
    {
        # quit during the logo, relaunch: "resumes the logo" (its script calls resume() there; X-Men's
        # restarts its advert)
        "key": "akira-relaunch-logo", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "30000", "--relaunch", "20000"],
        "expect": [
            ((0, 0), r"PLAYER play playlist 5 chapter 1 "),
            ((20000, 20000), r"RELAUNCH: quit"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER resume playlist 5 at 20000 ms"),       # the PSP: the logo resumed
            ("never", r"PLAYER play playlist 5 chapter 1 "),
        ],
    },
    {
        # the film, Square to the menu, quit there, relaunch, Play: "this resumes the film"
        "key": "akira-menu-relaunch", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "110000", "--key", "50000:CROSS", "--key", "70000:SQUARE", "--relaunch", "80000",
                 "--key", "100000:CROSS"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),
            (None, r"CALLBACK controller\.onMenu$"),
            ((80000, 80000), r"RELAUNCH: quit"),
            (None, r"RELAUNCH: \d+ bytes of user data kept, resume point kept"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"PLAYER play playlist 6 chapter 1 "),          # its menu
            (None, r"KEY CROSS \(focus btnPlay, page pageRoot\)"),
            (None, r"PLAYER resume playlist 1 at 20000 ms"),       # the PSP: the film resumed
            ("never", r"PLAYER play playlist 1 chapter 1 "),
        ],
    },
    {
        # Circle in the AUDIO pop-up "just closes the pop-up without making a choice": the script's
        # onCancel, not a quit; `pageRoot.activate()` gives the keys back to AUDIO, the root page's own
        # focus (a Cross then opens the pop-up again)
        "key": "akira-audio-popup", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "54000", "--key", "46000:RIGHT", "--key", "47000:CROSS", "--key", "49000:DOWN",
                 "--key", "50000:CIRCLE", "--key", "52000:CROSS"],
        "expect": [
            (None, r"AudioSelection\.open\(\)"),
            (None, r"KEY CIRCLE \(focus btnAudio_Japanese, page AudioSelection\)"),
            ("never", r"changeResumeInfo\(-1, 48385|QUIT"),        # no choice made, no quit
            (None, r"FOCUS btnAudio$"),
            (None, r"AudioSelection\.close\(\)"),
            (None, r"KEY CROSS \(focus btnAudio, page pageRoot\)"),
            (None, r"AudioSelection\.open\(\)"),
        ],
    },
    {
        # Left in the pop-up closes it towards PLAY: Akira's own script (RootButtonFocus = btnPlay,
        # then onActivate_pageRoot's `if (RootButtonFocus == '[object Button]') .setFocus()` -- a
        # UButton reads "[object Button]" and an object compares with a string by its string form)
        "key": "akira-audio-popup-left", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "53000", "--key", "46000:RIGHT", "--key", "47000:CROSS", "--key", "50000:LEFT",
                 "--key", "52000:CROSS"],
        "expect": [
            (None, r"KEY LEFT \(focus btnAudio_English, page AudioSelection\)"),
            (None, r"btnPlay\.setFocus\(\)"),
            (None, r"KEY CROSS \(focus btnPlay, page pageRoot\)"),
            (None, r"PLAYER play playlist 1 chapter 1 "),          # the film
        ],
    },
    {
        # Japanese chosen, the film, Square, Resume: "resuming stays japanese" (the menu's clip
        # plays track 0; the resume point keeps the film's track 1)
        "key": "akira-host-japanese", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "95000", "--key", "46000:RIGHT", "--key", "47000:CROSS", "--key", "49000:DOWN",
                 "--key", "50000:CROSS", "--key", "51000:CIRCLE", "--key", "53000:LEFT", "--key", "54000:CROSS",
                 "--key", "75000:SQUARE", "--key", "85000:CROSS"],
        "expect": [
            (None, r"movieplayer\.changeResumeInfo\(-1, 48385, "),
            (None, r"PLAYER play playlist 1 chapter 1 "),
            (None, r"PLAYER audio 1$"),
            (None, r"PLAYER play playlist 6 chapter 1 "),
            (None, r"PLAYER audio 0$"),
            (None, r"movieplayer\.resume\(\) -> 0"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (19500, 21000)),
            (None, r"PLAYER audio 1$"),                             # the PSP: still Japanese
        ],
    },
    {
        # Start not the script's is play / pause, a menu's clip too (the PSP: "Start: play/pause")
        "key": "akira-host-start", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "49000", "--key", "45000:START", "--key", "47000:START"],
        "expect": [
            (None, r"KEY START \(focus btnPlay, page pageRoot\)"),
            (None, r"PLAYER pause$"),
            (None, r"KEY START \(focus btnPlay, page pageRoot\)"),
            (None, r"PLAYER play \(transport\)$"),
        ],
    },
]

# The library (2026-10-02): every image started for 90 s with no key, through the UMD Main's path.
# 13 of 84 stopped the engine; each rule that fixed them is a scenario here: the disc runs its first
# minute without the engine stopping and without a handler abandoned (but where the disc's own script
# is at fault -- "script_errors": the count expected). Rules from the discs' own scripts (named),
# not from captures.
DISCS += [
    {   # numeric indices truncated: `children[getNumButtons(g) / 2]` (1.5 for three buttons)
        "key": "lib-ff", "iso": "Final Fantasy - The Spirits Within", "args": ["--ms", "40000"],
        "expect": [(None, r"RESOURCE EN100000 "), (None, r"pageRoot\.open\(\)")],
    },
    {   # a busy-wait on a moving object advances time: `while (picto.getPos()[0] != 200) {}`
        "key": "lib-goldmember", "iso": "Austin Powers in Goldmember", "args": ["--ms", "40000"],
        "expect": [(None, r"BUSY-WAIT on picto"), (None, r"pageRootMenu\.open\(\)")],
    },
    {   # objects carry `parent`: `this.parent.children["plnMM" + this.name.substring(5)]`
        "key": "lib-killbill", "iso": "Kill Bill - Vol. 1", "args": ["--ms", "45000"],
        "expect": [(None, r"RESOURCE EN100000 "), (None, r"plnMM\S*\.animColor\(")],
    },
    {   # [] equals undefined: `if (localData.currentPage != []) localData.currentPage.close()`
        "key": "lib-nowthats", "iso": "Now Thats What I Call Music 2006", "args": ["--ms", "20000"],
        "expect": [(None, r"CALLBACK movieplayer\.onPlayListEnd$"),
                   (None, r"movieplayer\.play\(0, 1, 37, ")],        # its menu, after the guard
    },
    {   # getRotate (5 discs: the root menu's group turned from where it is)
        "key": "lib-fewgoodmen", "iso": "A Few Good Men", "args": ["--ms", "20000"],
        "expect": [(None, r"\.getRotate\(\)")],
    },
    {   # a script's TypeError abandons its handler, the disc goes on (its onFocusIn reads
        # animtable["animMMBreath_0_o"] before its caller sets the focus number: none)
        "key": "lib-dude", "iso": "Dude Wheres My Car", "args": ["--ms", "20000"], "script_errors": 1,
        "expect": [(None, r"SCRIPT ERROR onFocusIn_pageRoot: method \.play of undefined"),
                   (None, r"animMMBreath_1_o\.play\(")],
    },
]

# P9-5, the video window: The Island's scene selection (the maintainer, 2026-10-02: "a tiny little
# movie in the middle of the screen"). Its size and place are the script's (setSize 342 x 192, setPos
# 83, 25 in the 854 x 480 scene); the PSP's placement is not measured yet -- a capture would pin it.
DISCS += [
    {
        # ... and its page, from the maintainer's photo (2026-10-02, .sim/p9_captures/island_scenes.jpg,
        # warped to 854 x 480; each object's edges aligned to the render's): the panels slide in by
        # MoveTo to ABSOLUTE places (plnScenesHole from posX -900 to 0); the hole in its art (x 362-655,
        # y 150-280) shows the video window behind it (339-681 x 119-311), as the photo does.
        # btnScenes / btnSSMain (left edge: -9 / -10 px, the lens) are not checked
        "key": "island-scenes", "fx": "island", "iso": "The Island (2005)",
        "args": ["--ms", "36000", "--key", "30000:DOWN", "--key", "31000:CROSS"],
        "expect": [
            (None, r"KEY CROSS \(focus btnScenes, page pageRoot\)"),
            (None, r"movieplayer\.setSize\(342, 192\)"),
        ],
        "draw": [{
            "t": 35000, "size": "854x480", "tol": 6.0,
            "centres": {"plnScenesHole": (427.0, 240.0), "plnUp": (285.5, 256.5), "plnDown": (290.5, 317.5),
                        "plnNumber": (522.0, 254.0)},
            "alpha": {},
        }],
    },
    {
        "key": "island-host-scenes", "iso": "The Island (2005)", "host": True,
        "args": ["--ms", "36000", "--key", "30000:DOWN", "--key", "31000:CROSS"],
        "expect": [
            (None, r"KEY CROSS \(focus btnScenes, page pageRoot\)"),
            (None, r"movieplayer\.setSize\(342, 192\)"),
            (None, r"CORE window 286 119 288x192$"),               # 342 x 192 of 854 x 480 on the 720 x 480 raster
            (None, r"PLAYER play playlist 11 chapter 1 "),         # the scene clips, in the window
        ],
    },
]

# fj#73, THE SIZE MODE: The Rock's Scene Selections (the maintainer's rig session, 2026-10-07: the titles "far
# too big", overlapping). The checkpoints' source: the maintainer's PSP photo of the same page (2026-10-08,
# Forgejo fj#73), measured in scene units (854 / 480 = 1.78 a PSP pixel): "01. LOGOS" ~128 wide, "32. FORT
# WALTON KANSAS / END CREDITS" ~463, each title about one row high (~17-20); the grid behind fills the
# screen. The tolerances are the photo's (+-25 across, +-5 down); the box-stretched titles were 893 x 46.
DISCS += [
    {
        "key": "rock-scenes", "iso": "The Rock (1996)",
        "args": ["--ms", "20000", "--key", "6000:SQUARE", "--key", "10000:DOWN", "--key", "11000:DOWN",
                 "--key", "12000:CROSS"],
        "expect": [
            (None, r"KEY CROSS \(focus btnScenes, page pageRoot\)"),
            (None, r"pageSS\.open\(\)"),
        ],
        "draw": [{
            "t": 19000, "size": "854x480", "tol": 2.0, "centres": {}, "alpha": {},
            "sizes": {"plnSSChapter1": (128.0, 18.5, 25.0, 5.0), "plnSSChapter32": (463.0, 18.5, 25.0, 5.0),
                      "plnBGGrid": (854.0, 480.0, 2.0, 2.0)},
        }],
    },
]

# fj#69, ALPHA IS WRITTEN DOWN, NOT INHERITED (menu.c; the maintainer's PSP checks, 2026-10-10, and the rig's
# reports of 2026-10-07). Each checkpoint is what the PSP shows, by name: the objects drawn or not at all
# (their places and alphas are the RCO's and the scripts', unchanged by the rule). X-Men's main menu (the
# glows) is in its own scenario above; its 13 s hold is the xmen scenario's 98 s checkpoint.
DISCS += [
    {
        # Hackers: the main menu's entries are Wheel's children, Wheel authored alpha 0 and never written --
        # the PSP shows them ("a rotating drum"); the rule before drew nothing
        "key": "hackers-wheel", "iso": "Hackers (1995)",
        "args": ["--ms", "4100"],
        "expect": [((0, 0), r"pageRoot\.open\(\)")],
        "draw": [{"t": 4000, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "present": ["plnMM_play_movie", "plnMM_audio_set_up", "plnMM_subtitles"]}],
    },
    {
        # The Transporter: its buttons hang from imageless alpha-0 pivots (mm_parent_*) that
        # anim_mm_activate turns -- the maintainer's rig report (2026-10-07: "rotating, but no visible
        # options"), a retail menu
        "key": "transporter-pivots", "iso": "The Transporter (2002)",
        "args": ["--ms", "95100"],
        "expect": [(None, r"pg_mm\.open\(\)")],
        "draw": [{"t": 95000, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "present": ["mm_btn_play", "mm_btn_sf", "mm_btn_setup"]}],
    },
    {
        # The Fifth Element: btnRootPlay under gpRootPage, authored alpha 0 (the fj#69 census) -- a retail
        # main menu's PLAY MOVIE
        "key": "fifth-root-play", "iso": "The Fifth Element (1997)",
        "args": ["--ms", "25100"],
        "expect": [(None, r"pageRoot\.open\(\)")],
        "draw": [{"t": 25000, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "present": ["btnRootPlay", "btnRootAudio", "btnRootSubs"]}],
    },
    {
        # X-Men's Set Up: animMM_To_Setup fades grpSetupLang to 0, anim_aud_expand then fades each language
        # button in -- the PSP shows them, the red orb at the current one (the maintainer, 2026-10-10)
        "key": "xmen-setup-langs", "fx": "xmen", "iso": "X-Men (2000)",
        "args": ["--ms", "116100", "--key", "107000:UP", "--key", "108000:CROSS"],
        "expect": [
            (None, r"KEY CROSS \(focus mmBtnSetup, page pgMM\)"),
            (None, r"animMM_To_Setup\.play"),
            (None, r"anim_aud_expand\.play"),
        ],
        "draw": [{"t": 116000, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "present": ["laBtnEN_aud", "laBtnFR_aud", "laBtnIT_aud", "laSetupMarker_pln"]}],
    },
    {
        # The Incredibles: Set Up from the main menu -- animTransToSetUp fades grpMM to 0 over 500 ms and its
        # buttons go with it (the maintainer's PSP, 2026-10-10); Circle back: the main menu again, its
        # buttons drawn as at its first open (the picture at 169.9 s here, which the PSP shows)
        "key": "incredibles-setup-fade", "iso": "The Incredibles",
        "args": ["--ms", "179100", "--key", "163000:CROSS", "--key", "170000:LEFT", "--key", "171000:CROSS",
                 "--key", "175000:CIRCLE"],
        "expect": [
            (None, r"FOCUS btnMMSetUp$"),
            (None, r"animTransToSetUp\.play"),
            (None, r"animBackToMM1\.play"),
        ],
        "draw": [{"t": 169900, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "present": ["btnMMPlayMovie", "btnMMBonusMat", "btnMMSetUp", "btnMMSceneSel"]},
                 {"t": 171500, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "absent": ["btnMMPlayMovie", "btnMMBonusMat", "btnMMSetUp", "btnMMSceneSel",
                             "plnMMPlayMovie", "plnMMBonusMat", "plnMMSetUp", "plnMMSceneSel"]},
                 {"t": 179000, "size": "480x272", "tol": 3.0, "centres": {}, "alpha": {},
                  "present": ["btnMMPlayMovie", "btnMMBonusMat", "btnMMSetUp", "btnMMSceneSel",
                              "plnMMPlayMovie", "plnMMBonusMat", "plnMMSetUp", "plnMMSceneSel"]}],
    },
]

# fj#68, ANOTHER ANIMATION'S STEP REPLACES: The Rock's main menu opens with PLAY focused (the maintainer's PSP
# photo, 2026-10-08: PLAY's row in its focused layout -- the thumbnail at the left, PLAY further right --, the
# other three rows unfocused). animRootOpen fires activateMainPage (animPlayFocus again) and starts its 600 ms
# MoveTos of every row to the unfocused places; animPlayFocus's 400 ms MoveTos start 100 ms later. The numbers
# are the RCO's targets drawn at 854 x 480: animPlayFocus's btnPlay x -220 and plnPlayMap x -275 (centres 271.5
# / 152), animRootOpen's plnSubsMap x 350 (centre 777); the photo says which layout each row is in.
DISCS += [
    {
        "key": "rock-root-focus", "iso": "The Rock (1996)",
        "args": ["--ms", "9000", "--key", "6000:SQUARE"],
        "expect": [
            (None, r"pageRoot\.activate\(\)"),
            (None, r"FOCUS btnPlay: onFocusIn again at its page's activation"),
        ],
        "draw": [{
            "t": 8900, "size": "854x480", "tol": 4.0, "alpha": {},
            "centres": {"btnPlay": (271.5, 130.0), "plnPlayMap": (152.0, 130.0), "plnSubsMap": (777.0, 203.0)},
        }],
    },
]

DISCS += [
    {
        # OPEN BUILDS A PAGE AFRESH (the third rig session, 2026-10-03): Family Guy leaves an episode
        # page by Main Menu through `animEpisodeToRoot.play(pageEpisode.root)`, a Recolour of the whole
        # page to alpha 0; its next open must draw as its first did. The checkpoint's source: the first
        # open's picture (t 22000 here), which the maintainer saw match the PSP on the rig ("the
        # transition to the submenus for each episode work well") -- the reopen, black on the rig, is
        # held to it; on the PSP every reopen shows the page
        "key": "fg-page-reopen", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection",
        "args": ["--ms", "36000", "--key", "15000:DOWN", "--key", "17000:CROSS", "--key", "23000:DOWN",
                 "--key", "24000:DOWN", "--key", "25000:CROSS", "--key", "27000:DOWN", "--key", "28000:CROSS"],
        "expect": [
            (None, r"pageEpisode\.open\(\)"),
            (None, r"animEpisodeToRoot\.play"),
            (None, r"pageEpisode\.close\(\)"),
            (None, r"pageEpisode\.open\(\)"),
            (None, r"RESET pageEpisode: "),
        ],
        "draw": [{
            "t": 35000, "size": "854x480", "tol": 2.0,
            "centres": {"plnEP02": (427.0, 240.0), "btnPlay": (337.0, 240.0), "btnMainMenu": (337.0, 390.0)},
            # (btnPlay, focused: 1.0 since M4b, 2026-10-04 -- the script dims every button with animColor(0.7,
            # 500) and its focus handler lights Play with animColor(1, 250) in the same instant; the 0.7 this
            # checkpoint first held was the engine's own first open under the old stacking of tweens, the
            # subject checking itself. The main menu's focused episode is lit at 1.0 in the PSP capture.)
            "alpha": {"plnEP02": 1.0, "btnPlay": 1.0, "btnSetup": 0.7, "btnMainMenu": 0.7},
        }],
    },
    {
        # AUDIO OFF (play()'s argument 6; p9.md S1): the episode page loops playlist 8 with it 0 -- the
        # film's sound muted under it (the "engine idling" on the rig, never heard on the PSP: the
        # maintainer, 2026-10-03), heard again with the main menu's playlist 9 (argument 6 = 1). The
        # source: the script's own constants (EN100000's play() calls)
        "key": "fg-host-mute", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "40000", "--key", "15000:DOWN", "--key", "17000:CROSS", "--key", "30000:DOWN",
                 "--key", "31000:DOWN", "--key", "32000:CROSS"],
        "expect": [
            # (nothing muted before playlist 8's play; muted at it; heard again at playlist 9's)
            (("first", r"CORE audio|movieplayer\.play\(0, 1, 8,"), r"movieplayer\.play\(0, 1, 8, 1, 57344, 48384, 0, -1, 0\)"),
            (("within", 50), r"CORE audio muted$"),            # (at once: not at the next write for another cause)
            (("first", r"CORE audio|movieplayer\.play\(0, 1, 9,"), r"movieplayer\.play\(0, 1, 9, 2, 57344, 48385, 1, -1, 0\)"),
            (("first", r"CORE audio"), r"CORE audio heard$"),
        ],
    },
]

DISCS += [
    {
        # A MENU ON A 4:3 CRT (docs/analog.md S7; the maintainer, 2026-10-03): the core's fit 1 (480i,
        # Analog Aspect Auto / Letterbox) letterboxes the scene -- 854 x 480 into 720 x 360 at line 60.
        # The checkpoints from that definition: the video window the band; the main menu's drawn rows
        # 35-469 at Fit (fg-host-crop's run at fit 0) -> 60 + 0.75 y = 86-412, its columns unchanged;
        # the episode page's full-screen art exactly the band. M4h (THE CANVAS, docs/p9.md): the scene drawn at
        # 480 x 272 and stretched -- a canvas pixel is 1.5 x 1.76 target pixels and the bilinear reaches into
        # the next, so a soft edge lands up to 2 px further out than drawn at 720 x 480 (measured: 1-2);
        # the boxes below take +-2 around the definition's numbers (a mapping error is tens of pixels)
        "key": "fg-host-letterbox", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "30000", "--menu-aa", "0:1", "--key", "15000:DOWN", "--key", "17000:CROSS"],
        "expect": [
            (None, r"CORE window 0 60 720x360$"),
            (None, r"CORE frame rows 8[4-9]-41[0-4] cols 25[6-9]-6(4[5-9]|50)$"),
            (None, r"pageEpisode\.open\(\)"),
            (None, r"CORE frame rows 60-419 cols 0-719$"),
        ],
    },
    {
        # ... fit 2 (Analog Aspect Crop, chosen: Auto never crops) shows the scene's centre 640 x 480 on
        # the whole raster: the window full, the main menu's columns from Fit's 258 to (258 x 854 / 720
        # - 427 + 320) x 720 / 640 = 224, its right edge past the raster (cut at 719), rows unchanged
        "key": "fg-host-crop", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "12000", "--menu-aa", "0:2"],
        "expect": [
            (None, r"CORE window 0 0 720x480$"),
            (None, r"CORE frame rows 3[3-8]-4(69|7[01]) cols 22[2-6]-719$"),      # (+-2: M4h's canvas)
        ],
    },
    {
        # ... and a fit that CHANGES under a still menu (the Video Output or Analog Aspect set in the
        # OSD) redraws it at once: Family Guy's main menu at rest by 10 s
        "key": "fg-host-fitchange", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "11000", "--menu-aa", "10000:1"],
        "expect": [
            (None, r"CORE frame rows 3[3-7]-4(69|7[01]) cols 25[6-9]-6(4[5-9]|50)$"),     # (+-2: M4h's canvas)
            (None, r"CORE menu fit 1$"),
            ((10000, 10100), r"CORE frame rows 8[4-9]-41[0-4] cols 25[6-9]-6(4[5-9]|50)$"),
            ((10000, 10100), r"CORE window 0 60 720x360$"),
        ],
    },
    {
        # THE PRESENTATION FOLLOWS WHAT IS SEEN (the third rig session: a 4:3 episode squeezed on the
        # CRT for its first seconds): Family Guy's Play resumes the episode under pageDummy -- one plane
        # at alpha 0 (its RCO), open 3 s to hold the keys. The keys stay the page's (grab 0xfff, ui), the
        # picture the content's (menu 0: its own aspect, no pillarbox window), then the episode's levels
        "key": "fg-host-dummy", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "72000", "--narrow", "1,2,3,4,5", "--key", "15000:DOWN", "--key", "17000:CROSS",
                 "--key", "26000:CROSS", "--key", "60000:SQUARE", "--key", "66000:CROSS"],
        "expect": [
            (None, r"KEY SQUARE"),
            (None, r"movieplayer\.resume\(\) -> 0"),
            (("first", r"CORE (levels|window)"), r"CORE levels grab 0xfff ui 1 menu 0$"),
            (("first", r"CORE (levels|window)"), r"CORE levels grab 0x840 ui 0 menu 0$"),
        ],
    },
]

DISCS += [
    {
        # M4h, RENDER PIPELINED (umd_menu_run.h): a frame is drawn while the previous flip is out and put when it
        # is back -- a CRT fit that changes in between must drop the drawn frame, never put it (menu_host_check's
        # CORE STALE PUT, the END's verdict). The Rock's main menu (pageRoot at 484.3 s, the bench's own trace)
        # moves every frame, so a drawn frame is always waiting when the fit changes: three changes mid-motion
        "key": "rock-host-fit-moving", "iso": "The Rock (1996)", "host": True,
        "args": ["--ms", "500000", "--menu-aa", "490000:1", "--menu-aa", "493000:2", "--menu-aa", "496000:0"],
        "expect": [
            (None, r"pageRoot\.open\(\)"),
            (None, r"CORE menu fit 1$"),
            (None, r"CORE menu fit 2$"),
            (None, r"CORE menu fit 0$"),
        ],
    },
]

DISCS += [
    {
        # THE LANDING'S CHAPTER (the rig, 2026-10-03: the main menu not reopened after Main Menu): the
        # core ranks a landing a moment after it (the model: 1-40 ms), its word 0 till then; Family
        # Guy's onChapterRoot opens the root only at chapter 2, the chapter its play() names
        # (`play(0, 1, 9, 2, ...)`, the script's constant: the checkpoint's source)
        "key": "fg-host-mainmenu", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "34000", "--key", "15000:DOWN", "--key", "17000:CROSS", "--key", "25000:DOWN",
                 "--key", "26000:DOWN", "--key", "27000:CROSS"],
        "expect": [
            (None, r"animEpisodeToRoot\.play"),
            (None, r"movieplayer\.play\(0, 1, 9, 2, "),
            (("first", r"getPlayerStatus\(\)"), r"getPlayerStatus\(\) -> playing 1 playlist 9 chapter 2$"),
            (None, r"In onChapterRoot opening Root"),
            (None, r"pageRoot\.open\(\)"),
        ],
    },
]

DISCS += [
    {
        # SQUARE IN THE FILM, PLAY LIT (the rig, 2026-10-03, against the capture at 1:35: the menu back with
        # PLAY lit): pageRoot reopened -- built afresh -- with btnPlay's focus left from before the film;
        # the focus is re-established (its onFocusIn lights the overlay), not kept silently. The bar's
        # place as "akira"'s (its capture at 50 s)
        "key": "akira-square-lit", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "78000", "--key", "50000:CROSS", "--key", "70000:SQUARE"],
        "expect": [
            (None, r"KEY SQUARE "),
            (None, r"pageRoot\.open\(\)"),
            (None, r"FOCUS btnPlay$"),
        ],
        "draw": [{
            "t": 76000, "size": "480x272", "tol": 3.0,
            "centres": {"RootBackground": (330.9, 253.6), "btnPlay": (330.9, 253.6)},
            "alpha": {"btnPlay": 1.0},
        }],
    },
]

DISCS += [
    {
        # OPEN AGAIN WHILE UP (the rig, 2026-10-03): Austin Powers 2's startup calls pageRootMenu.open()
        # repeatedly while it is up, setting its objects between the calls; only a CLOSED page is built
        # afresh, so nothing of an open one is reset (the rig's trace showed "RESET pageRootMenu: 3
        # objects" on the second call before the rule was narrowed). Its first 14 s: the logo, the pages
        # opened (each from closed, at their authored attributes: no RESET line), the language page
        "key": "ap2-open-again", "fx": "ap2", "iso": "Austin Powers - The Spy Who Shagged Me",
        "args": ["--ms", "14000"],
        "expect": [
            ("never", r"^RESET "),
            ((13000, 13100), r"PLAYER play playlist 8 chapter 1 "),
        ],
    },
]

DISCS += [
    {
        # DISC MENUS OFF (M3b, the maintainer 2026-10-03: "will behave as it does with the bare .rbf and
        # play the main playlist"): the mount's own choice plays -- the core's longest playlist, the
        # reader's rule -- and the host never starts, never writes a level, never stops it; the keys
        # stay the transport's (Cross pauses). A relaunch (the image again) too
        "key": "fg-host-menus-off", "fx": "fg", "iso": "Family Guy - Freakin' Sweet Collection", "host": True,
        "args": ["--ms", "30000", "--menus-off", "--key", "15000:CROSS", "--relaunch", "20000"],
        "expect": [
            (None, r"CORE mount: the feature, playlist 1$"),
            (None, r"HOST mount: disc _11DDC9B0F726EBBA, Disc Menus Off"),   # RS1: the id read (resume.md)
            ("never", r"HOST start|CORE levels|PLAYER stop"),
            (None, r"CORE key CROSS -> transport pause"),
            (None, r"CORE mount: the feature, playlist 1$"),
            (None, r"HOST mount: disc _11DDC9B0F726EBBA, Disc Menus Off"),
            # RS2: the relaunch resumes the place the pause saved (the tracker's PLAYLIST: no engine)
            (None, r"PLAYER play playlist 1 at (\d+) ms", (13500, 15000)),
        ],
    },
]

# M4, THE LIBRARY (docs/p9.md M4): each engine rule the library probe found, on the disc that needed it,
# through the UMD Main's whole path with the probe itself (menu_host_check --walk: Cross on a page that
# sits unchanged, until a content play of a feature-length playlist -- half the longest's duration in
# PLAYLIST.UMD -- then Square in it, then Cross). The probe reacts to the state, so it holds across the
# seeds' seek latencies. The checkpoints' source: the rule's (the feature by PLAYLIST.UMD's durations,
# a mark by its name in PLAYLIST.UMD), and the disc's own script for the line that shows the rule ran;
# no capture covers these discs.
def lib(key, iso, ms, feature_pl, *extra, **kw):
    d = {"key": key, "iso": iso, "host": True, "args": ["--walk", "--ms", str(ms)],
         "expect": list(extra) + [(None, r"WALK FEATURE playlist %d " % feature_pl), (None, r"WALK MENU AGAIN")]}
    d.update(kw)
    return d


DISCS += [
    # named marks: its menus open at its clips' "initMenu" (PLAYLIST.UMD, every menu playlist)
    lib("lib-nowthats-mark", "Now Thats What I Call Music 2006", 40000, 36,
        (None, r"HOST mark initMenu \(playlist 37 "), (("within", 0), r"CALLBACK movieplayer\.onMark$"),
        (("within", 0), r"page_mainMenu\.open\(\)")),
    # the script's stop() keeps no resume point: PlayMovieContinue's stop(); resume() fails on a fresh
    # disc and the film plays from its start (with the point, its logo looped); and open() fires onInit
    # once (Square's onMenu: onInit_pageRoot opens pageRoot itself)
    # (the maintainer's PSP, 2026-10-03: "goes straight to the movie after the logo")
    dict(lib("lib-diehard", "Die Hard (1998)", 40000, 1),
         expect=[(None, r"movieplayer\.resume\(\) -> -1"), (None, r"WALK FEATURE playlist 1 .* after 0 presses"),
                 (None, r"WALK MENU AGAIN"), ("never", r"PLAYER play playlist 2 at ")]),
    # the EMPTY constant vs an array literal: onMenu acts `if (fArray != [])`, its pending-action array empty
    dict(lib("lib-batman", "Batman & Robin", 40000, 1),
         expect=[(None, r"WALK FEATURE playlist 1 "), (None, r"WALK SQUARE"),
                 (("within", 20), r"CALLBACK controller\.onMenu$"), (("within", 0), r"controller\.setUserData"),
                 (None, r"WALK MENU AGAIN")]),
    # playStatus 0 when stopped, menuMode 1 unless content plays: Play's ChangeResource stops, then waits
    lib("lib-hellboy", "Hellboy (2004)", 60000, 1, (None, r"In onPush_btnRootMenu"),
        ("never", r"ERROR: Timeout waiting for movieplayer")),
    # an assignment is an expression: tryToCloseBlack's `s.playListNumber != 4 && (s.playStatus = 1)`, run
    # after Cross on the menu Square brought back (the probe's last step)
    dict(lib("lib-rock", "The Rock (1996)", 560000, 1),
         expect=[(None, r"WALK FEATURE playlist 1 "), (None, r"WALK MENU AGAIN"), (None, r"WALK BACK "),
                 (None, r"EVENT FireEvent -> tryToCloseBlack$")]),
    # `arguments` (local slot 0): addCardPL(...) variadic -- its info cards, then the film
    lib("lib-hackers", "Hackers (1995)", 80000, 1, (None, r"RESOURCE EN000001 ")),
    # open()'s default focus yields to its onInit's (onActivate focuses RootMenuButton)
    lib("lib-godzillafw", "Godzilla Final Wars", 80000, 1, (None, r"RootMenuButton\.setFocus\(\)"),
        ("never", r"FOCUS RootMenuLock$")),
    # Lock / Unlock a flag: two Locks, one Unlock as its root page opens
    lib("lib-nirvana", "Nirvana - Nevermind", 60000, 2, ("never", r"KEY \S+ \(locked\)$")),
    # a Lock lasts while its animation runs: the chapter menu Square brings opens under three Locks that
    # end without an Unlock (onMenu stops the film first: a menu over a stopped player); Cross plays
    dict(lib("lib-gits", "Ghost in the Shell 2.0", 80000, 3),
         expect=[(None, r"WALK FEATURE playlist 3 "), (None, r"WALK MENU AGAIN"), (None, r"main1_menu\.open\(\)"),
                 ("never", r"KEY \S+ \(locked\)$"), (None, r"WALK CROSS \(focus main1_1\)"),
                 # (the maintainer's PSP, 2026-10-03: "DIVE-1 plays immediately after selecting it")
                 (("within", 1500), r"WALK BACK restarted"), (("within", 0), r"PLAYER play playlist 3 chapter 1 ")]),
    # a Lock goes with its page: lockScreen closed for the main menu, no Unlock
    lib("lib-audioslave", "Audioslave", 80000, 3, (None, r"lockScreen\.close\(\)"),
        (("within", 0), r"ANIM \S+ stopped \(its page closed\): unlock$")),
    # an animation's FireEvent of another animation: animFadeInRootBtns' last action plays
    # animBlipRootBtns, whose run focuses Play Movie
    lib("lib-alien", "Alien (1979)", 140000, 1, (None, r"EVENT FireEvent -> play animBlipRootBtns$")),
    # a content play replaced by another content play leaves no resume point: its trailers end at their
    # Endmarks with the next one's play; PlayEpisodeContinue's stop(); resume() must not resume a trailer
    # (the maintainer's PSP, 2026-10-03: "play after the trailers goes to an antipiracy message, then
    # the fbi logo, then the first episode, no additional trailers")
    lib("lib-lost", "Lost - The Series Pilot", 460000, 17, (None, r"HOST mark Endmark4 "),
        (None, r"KEY CROSS \(focus btnPlay, page pageMM\)"), (None, r"pageFBIInterpol\.open\(\)"),
        (None, r"pageFBI1Interpol\.open\(\)"), ("never", r"PLAYER play playlist (1[0-6]|1[89]) "),
        (None, r"movieplayer\.resume\(\) -> -1"), ("never", r"PLAYER play playlist 1[2-6] at ")),
]

# M4e, the maintainer's rig session of 2026-10-07 (Forgejo fj#68, fj#70, fj#72). The checkpoints' sources: each
# disc's own script and RCO (named beside them) and what the maintainer saw on the rig; no PSP capture.
DISCS += [
    # fj#68 FOCUS AT ACTIVATION: X2's OnFocusInBtn lights a button only once g_AppState names the page (its
    # switch, EN100000's script), set as the page is activated 2.8 s after pgMM.open(); the rig showed no
    # highlight until the D-pad moved. The focus's onFocusIn again at activate(): the red glow at 0.7
    {
        "key": "x2-focus-activate", "iso": "X-Men 2 - X-Men United", "args": ["--ms", "75000"],
        "expect": [
            (None, r"pgMM\.open\(\)$"), (("within", 0), r"FOCUS mm_btn_play$"),
            (None, r"pgMM\.activate\(\)$"),
            (("within", 0), r"FOCUS mm_btn_play: onFocusIn again at its page's activation$"),
            (("within", 0), r"mm_btn_play_red\.animColor\(1, 1, 1, 0\.7, 300\)$"),
        ],
    },
    # ... and Aliens' two pages (the rig: PLAY MOVIE enlarged but not white; Set Up opened with nothing
    # lit): anim_mm_return's 0-ms Recolour and anim_trans_mm_to_la2's Recolours (the RCO) leave the focused
    # button blue after open(); each page ends its opening in activate(), where the focus anim / setColor
    # runs again: anim_mm_focus_play (Recolour to white), la_on_focus_in's setColor(1, 1, 1, 1)
    {
        "key": "aliens-focus-activate", "iso": "Aliens (1986)",
        "args": ["--ms", "117000", "--key", "108000:DOWN", "--key", "109000:CROSS"],
        "expect": [
            (None, r"pg_mm\.activate\(\)$"),
            (("within", 0), r"FOCUS mm_btn_play: onFocusIn again at its page's activation$"),
            (("within", 0), r"anim_mm_focus_play\.play\("),
            (None, r"pg_la\.activate\(\)$"),
            (("within", 0), r"FOCUS la_btn_mm: onFocusIn again at its page's activation$"),
            (("within", 0), r"la_btn_mm\.setColor\(1, 1, 1, 1\)$"),
        ],
    },
    # ... and ONLY when the activation comes later than the open: Akira opens pageRoot and activates it in
    # the same instant (at the menu and again at Square, its script); a second onFocusIn there would replay
    # its focus sound and animation for nothing
    {
        "key": "akira-focus-same-instant", "fx": "akira", "iso": "Akira",
        "args": ["--ms", "100000", "--key", "50000:CROSS", "--key", "70000:SQUARE", "--key", "82000:CROSS"],
        "expect": [
            ("never", r"onFocusIn again at its page's activation$"),
            (None, r"pageRoot\.activate\(\)$"), (None, r"KEY SQUARE "), (None, r"pageRoot\.activate\(\)$"),
        ],
    },
    # fj#70 A QUIT AFTER WHICH THE CORE NO LONGER HOLDS THE DISC: Interstella 5555's onExit calls
    # movieplayer.stop() (its script); at a new image that STOP reached the next disc on the rig (The
    # Matrix loaded stopped, its menus never started: 3 of 3, Akira's onExit as the control 0 of 2). The
    # quit for a new mount drops it (command 4, UMD_PC_STOP), traced; the relaunched disc starts. (The PC
    # bench is single-threaded: it cannot reproduce the rig's send race itself, only that nothing is pushed)
    {
        "key": "inter-host-exit-detached", "iso": "Interstella 5555", "host": True,
        "args": ["--ms", "40000", "--relaunch", "30000"],
        "expect": [
            (None, r"HOST start EN100000"),
            ((30000, 30000), r"RELAUNCH: quit$"),
            (("within", 0), r"CALLBACK controller\.onExit$"),
            (("within", 0), r"movieplayer\.stop\("),
            (("within", 0), r"HOST command 4 dropped: the core no longer holds this disc \(its onExit\)$"),
            (("within", 0), r"HOST quit \(a new mount\)"),
            (None, r"HOST start EN100000 \(continue\): the engine runs$"),
        ],
    },
    # fj#72 THE TRANSPORT UNDER A PAGE THAT DRAWS NOTHING: The Office's Play opens pageWaitDummy (its script)
    # and leaves it open, at alpha 0, through the episode (grab 0xfff, ui 1, menu 0); the rig: chapter skip
    # and seeking dead. R (bit 8) and Right (bit 0) the script leaves are the transport's presses; Cross
    # (bit 5), pressed by the walk on that page through the opening clips, is never forwarded
    {
        "key": "office-host-transport", "iso": "The Office - The Complete First Series - Disc 01", "host": True,
        "args": ["--walk", "--ms", "70000", "--key", "61000:R", "--key", "61500:RIGHT", "--key", "62000:CROSS"],
        "expect": [
            ("never", r"HOST button 5 "),
            (None, r"WALK FEATURE playlist 9 "), (None, r"CORE levels grab 0xfff ui 1 menu 0$"),
            (None, r"KEY R \(focus"), (("within", 0), r"HOST button 8 not the script's under a page that draws nothing"),
            (None, r"CORE press 0x0100$"),
            (None, r"KEY RIGHT \(focus"), (("within", 0), r"KEY RIGHT: its focus Nav is on a closed page$"),
            (("within", 0), r"HOST button 0 not the script's under a page that draws nothing"),
            (None, r"CORE press 0x0001$"),
            (None, r"KEY CROSS: its focus Nav is on a closed page$"),   # (unhandled, and not forwarded: the never)
        ],
    },
    # fj#76 A CHAPTER READ BEFORE THE LATEST play() WAS QUEUED (the M4e rig check, 2026-10-08: Aliens resumed
    # from a kept place showed its background loop and no menu). The checkpoints are EN100000's script:
    # onContinuePlay sets g_app_state = MAINMENU_TRANS_IN and plays the menu loop (playlist 2, chapter 3 =
    # g_menu_loop_chapter); onChapter dispatches on getPlayerStatus().playListNumber, and on_chapter_menu at
    # chapter 3 under MAINMENU_TRANS_IN runs mm_re_activate (open_bg, pg_mm.open()). The stale chapter (the
    # mount's feature play, playlist 1: on_chapter_movie sets MOVIE_PLAY) is read while the start loads
    # (--start-lat 60: the rig's start is tens of ms; player_ctl ranks the mount's landing 0-40 ms after it)
    # and must not reach the script
    # fj#74 THE ITEM CACHE HIDES A CLIPPED DRAW: an item unchanged for a frame blends from an entry drawn
    # UNCLIPPED, so CORE INC (each incremental frame against the full render) no longer sees a defect in how a
    # draw clipped to a damage rectangle finds its pixels (RED H52: caught by 17 scenarios on main, by none with
    # the cache on). aliens-focus-activate again (its checkpoints: the disc's script and RCO, above), the cache
    # off: H52 differs on 634 of its 766 frames (mcr2-quick, tried first, never saw H52 even on main)
    {
        "key": "aliens-focus-activate-nocache", "iso": "Aliens (1986)", "host": True,
        "args": ["--ms", "117000", "--key", "108000:DOWN", "--key", "109000:CROSS", "--no-item-cache"],
        "expect": [
            (None, r"pg_mm\.activate\(\)$"),
            (("within", 0), r"FOCUS mm_btn_play: onFocusIn again at its page's activation$"),
            (None, r"pg_la\.activate\(\)$"),
            (("within", 0), r"FOCUS la_btn_mm: onFocusIn again at its page's activation$"),
        ],
    },
    {
        "key": "aliens-continue-stale-chapter", "iso": "Aliens (1986)", "host": True,
        "args": ["--ms", "75000", "--relaunch", "60000", "--start-lat", "60"],
        "expect": [
            ("never", r"movieplayer\.getPlayerStatus\(\) -> playing 1 playlist 1 chapter 1$"),
            ((60000, 60000), r"RELAUNCH: quit$"),
            (None, r"CORE start at \d+: 60 ms of the poll's steps held in the mailbox"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (("within", 0), r"movieplayer\.play\(0, 1, 2, 3, "),
            (None, r"HOST start EN100000 \(continue\): the engine runs$"),
            (("within", 0), r"HOST chapter 1 dropped: read before the latest play\(\) was asked$"),
            (None, r"CALLBACK movieplayer\.onChapter$"),
            (("within", 0), r"movieplayer\.getPlayerStatus\(\) -> playing 1 playlist 2 chapter 3$"),
            (None, r"pg_mm\.open\(\)$"),
        ],
    },
]

# fj#88 / fj#89, THE RESUME POINT (the maintainer's rig session, 2026-10-10; docs/resume.md §3, §6 R7). Sources: the
# rig's /tmp/umd_menu.log in each issue, the discs' scripts (disassembled: The Animatrix's onExit calls stop() and
# its onContinuePlay calls resume() unchecked; Aliens' onExit calls stop(-1, false)), the user's R7 decision.
DISCS += [
    {
        # fj#89 (1): a P9-6 quit keeps the film's point although Aliens' onExit stops it; the disc screen says so,
        # and its Play (the relaunch) resumes the film there (the rig: "getResumeInfo() -> none", the film over)
        "key": "aliens-quit-resume", "iso": "Aliens (1986)", "host": True,
        "args": ["--ms", "150000", "--key", "107000:CROSS", "--key", "130000:CIRCLE", "--key", "135000:START"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),                    # PLAY MOVIE (the script)
            ((130000, 130000), r"QUIT \(P9-6\): \d+ bytes kept, resume point kept"),
            (None, r'HOST disc screen drawn: fit 0, "> Resume 0:00:(\d+)"', (20, 22)),   # 108.5 s -> 130 s
            ((135000, 135000), r"movieplayer\.getResumeInfo\(\) -> playlist 1 "),
            (("within", 0), r"movieplayer\.resume\(\) -> 0$"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (20500, 22000)),
            (None, r"HOST resume point used up: the resumed play landed$"),
        ],
    },
    {
        # fj#89 (2): a quit from the menu keeps no point -- the Play line says "> Play", never "> Resume" (the rig:
        # "> Resume 0:00:10", the core's place in the menu loop)
        "key": "aliens-quit-menu-play", "iso": "Aliens (1986)", "host": True,
        "args": ["--ms", "135000", "--key", "130000:CIRCLE"],
        "expect": [
            ((130000, 130000), r"QUIT \(P9-6\): \d+ bytes kept, resume point none"),
            (None, r'HOST disc screen drawn: fit 0, "> Play"$'),
            ("never", r'HOST disc screen drawn: .*Resume'),
        ],
    },
    {
        # fj#88: The Animatrix, a segment from its menu, the image loaded again (a mount's quit): its onExit stops
        # the film and saves "in the film"; the point must be kept with it, or onContinuePlay's unchecked
        # resume() leaves the disc black (the rig's file: "R 0 2 0 38357229 ...")
        "key": "animatrix-relaunch-resume", "fx": "animatrix-still-held", "iso": "The Animatrix (2003)", "host": True,
        "args": ["--ms", "80000", "--start", "JA100000", "--key", "44000:CROSS", "--key", "46000:RIGHT",
                 "--key", "47000:CROSS", "--relaunch", "70000"],
        "expect": [
            (None, r"PLAYER play playlist 5 chapter 1 "),                     # the segment (animatrix-segment-timer)
            ((70000, 70000), r"RELAUNCH: \d+ bytes of user data kept, resume point kept$"),
            (None, r"CALLBACK controller\.onContinuePlay$"),
            (None, r"movieplayer\.resume\(\) -> 0$"),
            (None, r"PLAYER play playlist 5 at (\d+) ms", (21500, 23000)),   # 47.3 s -> 70 s
        ],
    },
    {
        # fj#88: a quit INSIDE the resume's seek (before its first picture) keeps the point: the next relaunch
        # resumes the same place (resume() once used it up at the ask). Every seek 600 ms, so the second relaunch
        # (70.9 s) falls between the resume's ask (70.6 s: the mount's own start landed) and its landing (71.2 s)
        "key": "animatrix-relaunch-before-landing", "fx": "animatrix-still-held", "iso": "The Animatrix (2003)",
        "host": True,
        "args": ["--ms", "80000", "--lat", "600:600", "--start", "JA100000", "--key", "47000:CROSS",
                 "--key", "49000:RIGHT", "--key", "50000:CROSS", "--relaunch", "70000", "--relaunch", "70900"],
        "expect": [
            (None, r"PLAYER play playlist 5 chapter 1 "),
            ((70000, 70000), r"RELAUNCH: \d+ bytes of user data kept, resume point kept$"),
            (None, r"movieplayer\.resume\(\) -> 0$"),
            ((70900, 70900), r"HOST resume point kept: quit before its landing$"),
            ((70900, 70900), r"RELAUNCH: \d+ bytes of user data kept, resume point kept$"),
            (None, r"movieplayer\.resume\(\) -> 0$"),
            (None, r"PLAYER play playlist 5 at (\d+) ms", (18500, 20000)),   # 50.3 s -> 70 s, the same place
            (None, r"HOST resume point used up: the resumed play landed$"),
        ],
    },
    {
        # fj#88's likely origin (the issue: the 2026-10-08 OSD Resets): the Reset's quit runs after the first idle
        # read, so the film's place must come from the last read in play -- before, "R 0 0 0 0 ..." beside the
        # onExit's "in the film" (the rig's own Aliens file read so on 2026-10-10)
        "key": "aliens-reset-resume", "iso": "Aliens (1986)", "host": True,
        "args": ["--ms", "150000", "--key", "107000:CROSS", "--idle", "130000", "--relaunch", "135000"],
        "expect": [
            (None, r"PLAYER play playlist 1 chapter 1 "),                    # PLAY MOVIE (the script)
            ((130000, 130000), r"CORE Reset: the image unloaded"),
            (None, r"HOST resume point: playlist 1 item 0 pts"),
            (None, r"HOST quit \(the core went idle \(Reset\)\)"),
            (None, r"movieplayer\.resume\(\) -> 0$"),
            (None, r"PLAYER play playlist 1 at (\d+) ms", (20500, 22000)),   # 108.5 s -> 130 s
        ],
    },
    {
        # R7 (the user, 2026-10-10): Stop on the disc screen forgets the disc's place -- Disc Menus Off: the file
        # deleted, "> Play", and Play starts the title from its start
        "key": "akira-off-discscreen-forget", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "40000", "--menus-off", "--key", "30000:CIRCLE", "--key", "33000:CIRCLE", "--key", "36000:START"],
        "expect": [
            ((30000, 30000), r"CORE key CIRCLE -> transport stop"),
            (None, r'HOST disc screen drawn: fit 0, "> Resume 0:00:(\d+)"', (27, 30)),
            ((33000, 33000), r"CORE key CIRCLE -> host$"),
            (("within", 10), r"CARD store Akira_8A020D2D8C48A972: 0 bytes"),
            (None, r'HOST disc screen drawn: fit 0, "> Play"$'),
            ((36000, 36000), r"CORE key START -> transport play"),
            (None, r"HOST disc screen: Play after its place was forgotten -- playlist 1 from its start"),
            (None, r"PLAYER play playlist 1 chapter 1 "),
        ],
    },
    {
        # R7 with the menus: after a P9-6 quit, Stop on the disc screen deletes the kept text whole (the script's
        # data too: they cannot disagree) and the relaunch is a fresh start -- onAutoPlay, never onContinuePlay
        "key": "akira-quit-discscreen-forget", "fx": "akira", "iso": "Akira", "host": True,
        "args": ["--ms", "75000", "--key", "50000:CROSS", "--key", "65000:CIRCLE", "--key", "68000:CIRCLE",
                 "--key", "70000:START"],
        "expect": [
            ((65000, 65000), r"QUIT \(P9-6\): \d+ bytes kept, resume point kept"),
            (None, r'HOST disc screen drawn: fit 0, "> Resume 0:00:(\d+)"', (13, 15)),
            ((68000, 68000), r"CORE key CIRCLE -> host$"),
            (("within", 10), r"CARD store Akira_8A020D2D8C48A972: 0 bytes"),
            (None, r'HOST disc screen drawn: fit 0, "> Play"$'),
            (None, r"HOST disc screen: Play -- the disc's menus again \(nothing kept: a fresh start\)"),
            (("within", 20), r"CALLBACK controller\.onAutoPlay$"),
            ("never", r"CALLBACK controller\.onContinuePlay$"),
        ],
    },
]

# fj#65 and fj#66, THE MAINTAINER'S PSP BATCH (2026-10-10). Each checkpoint's source beside it: what the PSP showed,
# or the disc's own script (EN100000 / JA100000, disassembled) for the calls that lead there.
DISCS += [
    {
        # fj#65 pauseMode 1: The Animatrix's main menu asks play(1, 1, 23, 1) -- playlist 23 is four one-second
        # stills, one per chapter, the main menu's the first (the script's own choice). The PSP holds it: no
        # flashing through the other three, no onPlayListEnd (whose handler the script never defines: the
        # engine's SCRIPT ERROR before). So after the open, no later chapter of 23, no second open, no end
        "key": "animatrix-still-held", "iso": "The Animatrix (2003)",
        "args": ["--ms", "52000", "--start", "JA100000"],                     # (its only startup RCO)
        "expect": [
            (None, r"movieplayer\.play\(1, 1, 23, 1\)$"),                    # the script (JA100000)
            (None, r"main_menu\.open\(\)$"),                                  # its start chapter's onChapter
            ("never", r"main_menu\.open\(\)$|CALLBACK movieplayer\.onPlayListEnd$|PLAYER chapter [2-4]$"),  # the PSP
        ],
    },
    {
        # A PAGE'S ANIMATIONS END WITH IT (the maintainer on the rig, 2026-10-10: "selecting The Second Renaissance
        # Part I plays about a minute in then jumps to the first segment, The Final Flight of the Osiris", twice).
        # main_menu plays mainTimer on its root (Delay 60000, a fade, FireEvent TimeOut: the first segment,
        # playlist 3); Cross on its first item opens the segment page and closes main_menu; Right, Cross plays
        # The Second Renaissance Part I (playlist 5). It must play on past the main menu's 60 s (41.8 + 60 s):
        # no TimeOut, no playlist 3
        "key": "animatrix-segment-timer", "fx": "animatrix-still-held", "iso": "The Animatrix (2003)",
        "args": ["--ms", "115000", "--start", "JA100000", "--key", "44000:CROSS", "--key", "46000:RIGHT",
                 "--key", "47000:CROSS"],
        "expect": [
            (None, r"mainTimer\.play\("),
            (None, r"main_menu\.close\(\)$"),
            (None, r"PLAYER play playlist 5 chapter 1 "),                     # the segment chosen
            ("never", r"TimeOut|PLAYER play playlist 3 "),                    # the maintainer's report
        ],
    },
    {
        # fj#66: A Few Good Men's Play Movie changes to EN000001 (the warning cards over a page with no backdrop)
        # with the menu loop (menuMode 1, playlist 3) running and no stop() in the script; the PSP shows BLACK
        # between the cards: the system stopped the loop. Nothing of 3 again before the film (the script)
        "key": "afgm-play-warnings", "iso": "A Few Good Men (1992)",
        "args": ["--ms", "62000", "--key", "20000:CROSS"],
        "expect": [
            (None, r"movieplayer\.play\(0, 1, 3, 1, "),                       # the menu loop (EN100000)
            (None, r"controller\.changeResource\(EN000001\)$"),               # Play Movie (EN100000)
            (("within", 20), r"HOST changeResource\(EN000001\): the menu's playlist 3 stopped$|"
                            r"PLAYER stop \(changeResource EN000001: the system's\)$"),   # the PSP: black
            ("never", r"PLAYER play playlist 3 "),                             # no picture of the loop again
        ],
    },
    {
        # fj#65, Goldmember's return from Great Titles (the host's own: the status read in the instant after a
        # play() not yet landed). Great Titles asks play(1, 1, 4, 1): the PSP shows the Background loop as a
        # STILL. Square: onMenu stops, changes to EN100000, whose onChangeResource asks play(1, 1, 3, 1) and
        # then init_mm(), which reads getPlayerStatus().playListNumber and plays the loop (4) when it is not 4
        # (the script). The PSP shows the blue loop MOVING under the main menu, no Warning clip, still after
        # 25 s: its status named 3 at once. The engine read the core's 4 and the Warning played, then the
        # startup chain (Logo, playlist 2) at its end
        "key": "goldmember-gt-return", "iso": "Austin Powers in Goldmember", "host": True,
        "args": ["--ms", "75000", "--key", "30500:RIGHT", "--key", "32000:RIGHT", "--key", "33500:CROSS",
                 "--key", "45000:SQUARE"],
        "expect": [
            (None, r"controller\.changeResource\(EN003001\)$"),               # Great Titles Available
            (None, r"movieplayer\.play\(1, 1, 4, 1, "),                       # EN003001's onChangeResource
            (None, r"PLAYER pause \(held\)$"),                                 # the PSP: a blue still
            (None, r"KEY SQUARE "),
            (None, r"movieplayer\.play\(1, 1, 3, 1, "),                       # EN100000's onChangeResource
            (("within", 0), r"movieplayer\.getPlayerStatus\(\) -> playing \d playlist 3 "),
            (("within", 0), r"movieplayer\.play\(0, 1, 4, 1, "),               # init_mm: the loop
            (None, r"PLAYER play playlist 4 chapter 1 "),
            ("never", r"CALLBACK movieplayer\.onPlayListEnd$|PLAYER play playlist 2 |PLAYER pause"),  # the PSP: moving, 25 s
        ],
    },
]

RESUME = re.compile(r"^PLAYER resume playlist (\d+) at (\d+) ms$")


def for_host(expect):
    out = []
    for cp in expect:
        win, rx = cp[0], cp[1]
        rng = cp[2] if len(cp) > 2 else None
        m = RESUME.match(rx)
        if m:
            t = int(m.group(2))
            rx, rng = r"PLAYER play playlist %s at (\d+) ms" % m.group(1), (t - 1500, t)
        elif rx == r"PLAYER resume ":
            rx = r"PLAYER play playlist \d+ at "
        if isinstance(win, tuple) and win[0] not in ("first", "within"):    # ("within": kept, M4 -- it was dropped)
            win = (0, 1000) if win == (0, 0) else (win if win[0] == win[1] else None)
        out.append((win, rx, rng))
    return out


LINE = re.compile(r"^\s*(\d+) (.*)$")
DRAW = re.compile(r"^DRAW (\S+) (\S+) (\S+) (\S+) (\S+) a(\S+) ")


def check_draw(spec, lines):
    shots = [text for t, text in lines if t == spec["t"] and text.startswith("SHOT ")]
    if not shots or "plane layout ok" not in shots[0]:
        return "picture: no shot at %d ms, or the plane layout (MENU_PX_PLANE) differs" % spec["t"]
    if "fast path ok" not in shots[0]:
        return "picture: the renderer's fast path differs from its general path at %d ms (%s)" % (spec["t"], shots[0])
    boxes = {}
    for t, text in lines:
        m = DRAW.match(text)
        if m and t == spec["t"]:
            boxes[m.group(1)] = tuple(float(m.group(k)) for k in range(2, 7))
    for lab in spec.get("absent", []):
        if lab in boxes and boxes[lab][4] > 0.02:
            return "picture: %s drawn at %d ms (alpha %.2f), the capture shows none" % (lab, spec["t"], boxes[lab][4])
    # (present: drawn, wherever -- a checkpoint that says only that the PSP shows the object)
    for lab in spec.get("present", []):
        if lab not in boxes or boxes[lab][4] <= 0.02:
            return "picture: %s not drawn at %d ms, the PSP shows it" % (lab, spec["t"])
    # (centres_x: a checkpoint known only across -- the screen's centre for a centred layout)
    for lab, cx in spec.get("centres_x", {}).items():
        if lab not in boxes:
            return "picture: %s not drawn at %d ms" % (lab, spec["t"])
        if abs((boxes[lab][0] + boxes[lab][2]) / 2 - cx) > spec["tol"]:
            return "picture: %s centred across at %.1f, the checkpoint's %.1f" % (lab, (boxes[lab][0] + boxes[lab][2]) / 2, cx)
    for lab, (cx, cy) in spec.get("centres", {}).items():
        if lab not in boxes:
            return "picture: %s not drawn at %d ms" % (lab, spec["t"])
        x0, y0, x1, y1, _ = boxes[lab]
        if abs((x0 + x1) / 2 - cx) > spec["tol"] or abs((y0 + y1) / 2 - cy) > spec["tol"]:
            return "picture: %s centred at (%.1f, %.1f), the capture's (%.1f, %.1f)" % (lab, (x0 + x1) / 2, (y0 + y1) / 2, cx, cy)
    # (sizes: label -> (w, h, w tol, h tol), the drawn box in the shot's units -- a measured size)
    for lab, (sw, sh, wt, ht) in spec.get("sizes", {}).items():
        if lab not in boxes:
            return "picture: %s not drawn at %d ms" % (lab, spec["t"])
        x0, y0, x1, y1, _ = boxes[lab]
        if abs((x1 - x0) - sw) > wt or abs((y1 - y0) - sh) > ht:
            return "picture: %s drawn %.1f x %.1f, the checkpoint's %.1f x %.1f" % (lab, x1 - x0, y1 - y0, sw, sh)
    if "width_ratio" in spec:
        a, b, ratio, tol = spec["width_ratio"]
        r = (boxes[a][2] - boxes[a][0]) / (boxes[b][2] - boxes[b][0])
        if abs(r - ratio) > tol:
            return "picture: %s is %.3fx %s's width, the capture's %.2fx" % (a, r, b, ratio)
    for lab, al in spec["alpha"].items():
        if abs(boxes[lab][4] - al) > 0.02:
            return "picture: %s alpha %.2f, expected %.2f (a model)" % (lab, boxes[lab][4], al)
    return None


def find_iso(iso_dir, prefix):
    for p in sorted(glob.glob(os.path.join(iso_dir, "**", "*"), recursive=True)):   # (multi-disc sets: subfolders)
        b = os.path.basename(p)
        if b.lower().startswith(prefix.lower()) and b.lower().endswith(".iso"):
            return p
    return None


def check(disc, out, host=False):
    expect = for_host(disc["expect"]) if host else disc["expect"]
    lines = []
    for l in out.splitlines():
        m = LINE.match(l)
        if m:
            lines.append((int(m.group(1)), m.group(2)))
    i = 0
    prev_t = 0                                  # the time of the last checkpoint's line ("within")
    for k, cp in enumerate(expect):
        win, rx = cp[0], cp[1]
        rng = cp[2] if len(cp) > 2 else None
        r = re.compile(rx)
        if win == "never":
            hit = [t for _, t in lines[i:] if r.search(t)]
            if hit:
                return "checkpoint %d: '%s' after checkpoint %d" % (k + 1, hit[0], k)
            continue
        if isinstance(win, tuple) and win[0] == "first":
            f = re.compile(win[1])
            while i < len(lines) and not f.search(lines[i][1]):
                i += 1
            if i == len(lines) or not r.search(lines[i][1]):
                return "checkpoint %d: the first '%s' is '%s', not %s" % (k + 1, win[1], lines[i][1] if i < len(lines) else "-", rx)
            prev_t = lines[i][0]
            i += 1
            continue
        if isinstance(win, tuple) and win[0] == "within":
            while i < len(lines) and lines[i][0] <= prev_t + win[1] and not r.search(lines[i][1]):
                i += 1
            if i == len(lines) or lines[i][0] > prev_t + win[1]:
                return "checkpoint %d: %s not within %d ms of checkpoint %d (at %d ms)" % (k + 1, rx, win[1], k, prev_t)
            prev_t = lines[i][0]
            i += 1
            continue

        def ok(line):
            m = r.search(line[1])
            if not m or (win is not None and not win[0] <= line[0] <= win[1]):
                return False
            return rng is None or rng[0] <= int(m.group(1)) <= rng[1]
        while i < len(lines) and not ok(lines[i]):
            i += 1
        if i == len(lines):
            return "checkpoint %d not reached: %s%s%s" % (k + 1, rx, "" if win is None else " in %d..%d ms" % win,
                                                         "" if rng is None else " (%d..%d)" % rng)
        prev_t = lines[i][0]
        i += 1
    for spec in ([] if host else disc.get("draw", [])):
        why = check_draw(spec, lines)
        if why:
            return why
    # a handler a script error abandoned: the disc goes on (as the PSP), but none of the gate's
    # scenarios ran into one when they were measured -- one now is a regression
    serr = [t for _, t in lines if t.startswith("SCRIPT ERROR")]
    if len(serr) != disc.get("script_errors", 0):
        return "%d handler(s) abandoned, %d expected: %s" % (len(serr), disc.get("script_errors", 0), serr[0] if serr else "-")
    end = [t for _, t in lines if t.startswith("END ")]
    if not end or end[-1] != "END ok":
        return "the engine stopped: %s" % (end[-1] if end else "no END line")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--run", default=os.path.join(ROOT, ".sim/menu/menu_run"))
    ap.add_argument("--fx", default=os.path.join(ROOT, "bench/umd/fixtures/gen/menu"))
    ap.add_argument("--host", action="store_true", help="M3: through menu_host_check")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--run-host", default=os.path.join(ROOT, ".sim/menu/menu_host_check"))
    ap.add_argument("--only", help="run only the scenarios whose key matches this regex (iterating; never the gate)")
    a = ap.parse_args()
    if a.only:
        DISCS[:] = [d for d in DISCS if re.search(a.only, d["key"])]
    if a.host:
        return main_host(a)
    fails = run = 0
    for d in DISCS:
        if d.get("host"):
            continue
        iso = find_iso(a.iso_dir, d["iso"])
        if not iso:
            print("  SKIP %s: no image '%s*' under the ISO dir" % (d["key"], d["iso"]))
            continue
        fx = os.path.join(a.fx, d.get("fx", d["key"]))
        if not os.path.exists(os.path.join(fx, "marks.txt")):
            subprocess.run([sys.executable, os.path.join(HERE, "menu_fixture.py"), iso, fx], check=True,
                           stdout=subprocess.DEVNULL)
        extra = []
        if "draw" in d:
            tmp = tempfile.mkdtemp()
            extra = ["--size", d["draw"][0]["size"]]           # (one size a disc)
            for k, spec in enumerate(d["draw"]):
                extra += ["--shot", "%d:%s" % (spec["t"], os.path.join(tmp, "shot%d.png" % k))]
        p = subprocess.run([a.run, fx] + d["args"] + extra, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True)
        if extra:
            shutil.rmtree(tmp, ignore_errors=True)
        run += 1
        why = check(d, p.stdout)
        if why:
            fails += 1
            print("  FAIL %s: %s" % (d["key"], why))
        else:
            print("  ok   %s: %d checkpoints, %d picture(s)" % (d["key"], len(d["expect"]), len(d.get("draw", []))))
    if run == 0:
        print("SKIP: menu_gate: no captured disc's image")
        return 0
    if fails:
        print("FAIL: menu_gate: %d of %d scenarios" % (fails, run))
        return 1
    print("PASS: menu_gate (%d scenarios)" % run)
    return 0


def main_host(a):
    fails = run = 0
    for d in DISCS:
        iso = find_iso(a.iso_dir, d["iso"])
        if not iso:
            print("  SKIP %s: no image '%s*' under the ISO dir" % (d["key"], d["iso"]))
            continue
        bad = []
        for seed in range(1, a.seeds + 1):
            p = subprocess.run([a.run_host, iso, "--seed", str(seed)] + d["args"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, universal_newlines=True)
            why = check(d, p.stdout, host=True)
            if why:
                bad.append("seed %d: %s" % (seed, why))
        run += 1
        if bad:
            fails += 1
            print("  FAIL %s: %s%s" % (d["key"], bad[0], "" if len(bad) == 1 else " (%d of %d seeds)" % (len(bad), a.seeds)))
        else:
            print("  ok   %s: %d checkpoints x %d seeds" % (d["key"], len(d["expect"]), a.seeds))
    if run == 0:
        print("SKIP: menu_gate --host: no captured disc's image")
        return 0
    if fails:
        print("FAIL: menu_gate --host: %d of %d scenarios" % (fails, run))
        return 1
    print("PASS: menu_gate --host (%d scenarios x %d seeds)" % (run, a.seeds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
