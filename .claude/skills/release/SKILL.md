---
name: release
description: Cut and publish a release of the MiSTer UMD Video core — gather notes from every PR merged since the previous release, land the one release commit that sets CORE_VERSION and reconciles the manual, build the timing-clean .rbf, and publish it as a GitHub release draft packaged by CI. Use when the user asks to cut, make, or publish a release.
---

# Cutting a release

Two artefacts ship (A7, `docs/hps_host.md` §1): the compressed `.rbf` and the **UMD Main**
(`MiSTer_UMD`, `main/build_main.sh`: the MiSTer's Main with the disc menus, the control panel, the disc
screen, the remembered places and a PSP's disc), each with its
manifest (`.rbf.json`, `MiSTer_UMD.json`), packed with the install steps into ONE zip by
`tools/package_release.sh`. The two must come from the same commit (the host-port PROTO);
the packager refuses a pair that does not. No scripts.

## The one-commit invariant

> A bare semver lives in **exactly one commit per release** — the release commit. Any
> build whose OSD shows `v0.1.0` came from that commit and no other.

- `CORE_VERSION` in `umd/emu.sv` carries `dev-<slug>` on branches and whatever the last
  merge left on `main`. The release commit sets `v<semver>`; nothing resets it after.
  `build_release.sh` refuses a `dev-` string on `--release` and a semver on a dev build.
- Tag = `v<semver>`; zip = `MiSTer_UMD_Video_v<semver>.zip`.
- **The `.rbf` stays `UMD_YYYYMMDD.rbf` — date only, never a version**: MiSTer's core
  browser and update scripts parse the date out of the filename.
- `CORE_VERSION` and `BUILD_DATE` are inside CONF_STR = inside the netlist, so the version
  edit rides in ONE commit with the docs sweep and the release needs exactly one compile.

## Preconditions

On `main`, clean tree, every intended branch merged (`/merge`). The manual matches what
ships: `.venv/bin/python3 tools/docs_check.py && .venv/bin/mkdocs build --strict`. Decide
the number against the WHOLE unreleased delta (patch / minor / major per `CLAUDE.md`).

## Steps

1. **Gather the notes.** Every PR merged since the last release, grouped into human
   sentences; run `docs-sweep` over `<prev_tag>..HEAD` and fix stale pages.
   - `gh pr list --state merged --base main --json number,title,mergedAt` and
     `git log <prev_tag>..HEAD --merges --format='%h %s'`. For the first release, the Forgejo
     era's work is summarised from `docs/roadmap.md` (its PRs are `fj#NN`: no GitHub links).
2. **Land ONE release commit** on `main`: `CORE_VERSION` → `"v<semver>"`,
   `extra.released_version` in `mkdocs.yml` → `<semver>`, the "Current as of" line in
   `site/content/reference/compatibility.md`, the docs-sweep edits. Verify the two docs
   checks. Do NOT push until the build is tested (memory: no release-signalling pushes).
3. **Build the core (timing-clean) and the UMD Main, from the release commit:**
   ```bash
   USE_DOCKER=1 ./build_release.sh --release --compile   # -> releases/UMD_YYYYMMDD.rbf + .json
   USE_DOCKER=1 main/build_main.sh                       # -> main/.build/MiSTer_UMD + .json
   ```
   `--release` refuses a marginal netlist; re-roll with `tools/seed_sweep.sh` if needed.
   Never ship a `_MARGINAL_` build. Both on a clean tree at the release commit: the packager
   compares the two manifests' commits.
4. **Record the fit** in `UMD.qsf`'s SEED LEDGER (`jq . releases/UMD_YYYYMMDD.rbf.json`
   has every number) and `docs/history.md`.
5. **Smoke-test on hardware** (`hil-testing`): flash, boot, load an image, confirm the OSD
   About line reads `UMD v<semver> <yymmdd>`. On the stock Main: Akira plays with sound,
   Subtitle turns its subtitles on (decoded in fabric since A12), and Control Panel says
   `The control panel needs the UMD Main.` Then under the UMD Main
   (`mister.py deploy --main main/.build/MiSTer_UMD`): the disc menus start Akira, the
   control panel opens, and Stop shows the disc screen.
6. **Publish.**
   - Push `main`, then `tools/publish_draft.sh v<semver> --notes /tmp/relnotes.md` creates
     the draft with the `.rbf` pair and the UMD Main pair (it refuses a Main built from another
     commit) and dispatches `.github/workflows/package.yml`, which makes the zip; smoke-test
     the draft's zip, then
     `gh release edit v<semver> --draft=false`. Publishing deploys the manual
     (`docs.yml`). A later doc fix deploys from a `docs-v<semver>` branch cut off the tag,
     never from `main`.

⛔ No version-reset step after publishing. The next feature branch sets its own
`dev-<slug>` in its first commit.
