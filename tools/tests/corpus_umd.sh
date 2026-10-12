#!/usr/bin/env bash
# Phase 1 media gate: the census over every local UMD image, then corpus_gate.py turns
# its JSON into verdicts. Needs ${UMD_ISO_DIR:-~/umd-isos}; with no images it prints SKIP
# and exits 2 -- a skip is never scored as a pass.
#   corpus_umd.sh [--full-audio] [--jobs N]     (--full-audio: decode every track end to end)
set -u
cd "$(dirname "$0")/../.."
dir="${UMD_ISO_DIR:-$HOME/umd-isos}"
n=$(find "$dir" -maxdepth 1 -iname '*.iso' 2>/dev/null | wc -l)
if [ "$n" = 0 ]; then
    echo "corpus_umd: SKIP -- no .iso in $dir (set UMD_ISO_DIR)"; exit 2
fi
mkdir -p .sim/census
python3 tools/umd_census.py "$dir" --index-packs 1000000 --json .sim/census/corpus.json "$@" \
    > .sim/census/corpus.txt 2>&1
echo "census exit $? over $n images (report: .sim/census/corpus.txt)"
python3 tools/tests/corpus_gate.py .sim/census/corpus.json
