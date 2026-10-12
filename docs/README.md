# Engineering design notes

**These are not user documentation.** They are the development record of the core: the
reasoning behind non-trivial design decisions, the measurements behind each choice, the
hardware bring-up histories, and the theories that turned out to be wrong.

📖 **The user manual's source is in `site/content/`** (published on release). If you are
trying to *use* the core, read that. Nothing in this directory is written for that
purpose, and following a design note as though it were instructions will mislead you.

## What this is for

These notes exist so that work can resume cold. They record *why*, not *what*: the code
says what it does; these say what else was tried, what the hardware measured, and which
assumptions turned out false. Entry points:

| File | Covers |
|---|---|
| `roadmap.md` | The phased plan and current status — the canonical "what's next" |
| `umd_video_format.md` | What is actually on a UMD Video disc, measured from real images |
| `architecture.md` | Target data flow, clock domains, memory ports |
| `harvest.md` | Which MiSTer_DVD modules transfer, with what surgery, in which phase |
| `hw_budget_and_lessons.md` | The fabric budget, and the verification rules a failed feature earned |
| `hil_harness.md` | Driving the real MiSTer from a session |
| `mgl_launch.md` | How an MGL launch works and how a core's own additions can break it |
| `bug_reports.md` | The sparse-sector repro bundle (planned) |
| `spec_hardening.md` | Design to the format's maximum, not the test shelf |
| `conformance.md` | Feature-by-feature coverage matrix and the reference oracles |
| `idle_screen.md` | The XMB-style wave: design and bench |
| `umd_reader.md` | The P2 image reader: the walk, its bounds and refusals, the bench |
| `p2_chain.md` | The rest of P2: demux surgery, `es_probe`, the diagnostic HUD, the chain bench, the HW gate |
| `h264_frontend.md` | P3: the syntax-element golden (JM + the H.264.1 traces), the Python front end, the engine, the macroblock layer and the chain in fabric, the `emu` integration (CDC, flush, readout) |
| `transport_hud.md` | P6b's look: the PSP video player's design language, measured from captures (a reference, not a spec) |
| `transport.md` | P6b's plan: seek (the decoder's recovery-point start, the discontinuity), pause, chapters, the audio track, the reader's navigation, `player_ctl`, the HUD; stages, gates, open decisions |
| `area_plan.md` | The device after P6: the levers, the stock-Main rule (A5-A10), what may run on the HPS |
| `hps_host.md` | Host B, the UMD Main: install beside stock Main, the host port (EXT_BUS 0x7B / 0x7C), the subtitle decode on the HPS (A7), P6c's door, what stock Main shows |
| `menus.md` | Phase 9, disc menus (RCO / VSMX): what the discs contain, the oracles, one C engine for a fabric or an HPS host, the fabric contract, what P6 / P7 must leave room for |
| `references.md` | Specs, papers, oracles and repositories |
| `experiments.md` | Parking lot for undecided ideas |
| `history.md` | Condensed record of solved problems |

Most of the process and several of the notes are inherited from **MiSTer_DVD**, the
sibling project this core was scaffolded from. Where a note cites a measurement made
there, it says so; those numbers are about that core's netlist, not this one's.

## References to earlier history

This core was developed in a private repository before being published, and the public
history begins with an import of the accumulated work rather than the full commit-by-commit
trail. So:

- References written **`fj#NN`** (`PR fj#22`, `issue fj#71`) are **pre-publication** pull
  requests and issues, of this repository or of MiSTer_h264_decoder's. They have no
  equivalent on GitHub; they carry that prefix precisely so they can never be confused with
  the public repository's own `#NN`, which start from 1. MiSTer_DVD's are its public numbers,
  always named with it (`MiSTer_DVD PR #164`).
- **Commit SHAs quoted in these notes** refer to that earlier history and will not resolve
  in the public repository.

Neither affects the design rationale these notes exist to record.
