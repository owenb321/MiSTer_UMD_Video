# Building from source

Requires **Quartus 17.0.2 exactly**. The pinned Docker image `raetro/quartus:mister` is
that version:

```bash
USE_DOCKER=1 ./build_release.sh --compile   # -> releases/UMD_<slug>_<date>_<time>.rbf
```

`build_release.sh` also runs the build gates (implicit nets, undriven signals, the
decoder-clock timing gate at both corners, the netlist canary) and packs a **compressed**
`.rbf`, which MiSTer's loader requires.

Simulation benches run under Icarus Verilog: `bench/umd/run_scaffold.sh` (add `--red` to
prove each bench can fail).

The **UMD Main** (`MiSTer_UMD`: the disc menus, the control panel and a PSP's disc over USB) is the MiSTer's Main program with this
project's `main/` added. Its build fetches Main_MiSTer at a pinned commit and cross-compiles
it with the toolchain in `main/docker/Dockerfile`:

```bash
USE_DOCKER=1 main/build_main.sh   # -> main/.build/MiSTer_UMD + MiSTer_UMD.json (its provenance)
./tools/package_release.sh        # the install zip: the newest .rbf and this Main, from one commit
```

The manual is built with MkDocs: `python3 tools/docs_check.py && mkdocs build --strict`.
