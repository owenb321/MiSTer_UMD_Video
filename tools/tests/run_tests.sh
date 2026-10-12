#!/usr/bin/env bash
# Host-side python tests (docs_check parser, harness helpers, the Phase 1 format tools).
# No hardware, no Docker, no disc images (tools/tests/corpus_umd.sh is the media gate).
#   --red   also prove each Phase 1 test can fail (tools/tests/red_umd.py)
set -u
cd "$(dirname "$0")/../.."
fail=0
for t in tools/tests/test_*.py; do
    if python3 "$t" 2>&1 | tee /tmp/hiltest.log | grep -q "ALL GREEN"; then
        echo "PASS $(basename "$t")"
    else
        echo "FAIL $(basename "$t")"; tail -20 /tmp/hiltest.log; fail=1
    fi
done
if [ "${1:-}" = "--red" ]; then
    python3 tools/tests/red_umd.py | tee /tmp/hiltest.log
    grep -q "red_umd: ALL GREEN" /tmp/hiltest.log || fail=1
fi
[ $fail = 0 ] && echo "tools/tests: ALL GREEN" || echo "tools/tests: FAILURES"
exit $fail
