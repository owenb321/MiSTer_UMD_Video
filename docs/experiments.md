# Experiments / speculative ideas

A parking lot for ideas that are **not** committed roadmap items. Committed work lives in
`roadmap.md`; this file is for the maybes. Move an item over once it is decided, or delete
it if ruled out. Keep the technical reasoning so a later session does not re-derive it.

---

## RCO/VSMX disc menus: moved to the roadmap

Decided 2026-09-25: roadmap Phase 9, designed in `menus.md`. One C engine for two hosts
(a soft CPU in fabric, or a `support/umd` module in the project's Main fork, `main/`; host B chosen 2026-09-30), sharing one fabric
contract.

## PSP game cutscenes (`.PMF`): ruled out (2026-10-05)

Surveyed 2026-10-05 (`tools/pmf_census.py`, `docs/bare_streams.md` §2): the video is inside the
disc limits (Main, CABAC, frames, Level 2.1), the audio is not (every track 44.1 kHz). Dropped
from the scope by the maintainer the same day; the reader's PSMF path stays, unoffered
(`bare_streams.md` B4, with the audio stage it would need).

## Index packs (`0xBF`) as a seek aid

If the private-stream-2 packs carry a per-GOP entry table, a seek could snap to them
without walking the CLPI EP map. Measure in P1 first.

## 2352-byte / raw images

Not seen in the wild for UMD; rejected unless a dump format needs it.

## `SND0.AT3` / `ICON1.PMF`

The XMB browser's background music and icon animation. ATRAC3 (non-plus) for the former;
pure polish, and outside the player's job.
