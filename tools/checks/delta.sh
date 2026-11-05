#!/bin/bash
# delta.sh <checkout> scenario... : quick checks, the given scenarios (NO_SHOTS) and the Earth soak. For a small fix
# on top of a merge that already passed fullrun.sh. Prints "delta done" last.
cd "$1" || exit 1; shift
export NO_SHOTS=1
(stylua --check src tests > /dev/null 2>&1 && echo "stylua ok") || echo "STYLUA FAILED"
RUST_MIN_STACK=67108864 selene src 2>&1 | tail -3 | tr '\n' ' '; echo
lune run tests/run 2>&1 | grep -E "FAIL|spec files" | tail -6
mkdir -p build && rojo build -o build/game.rbxlx 2>&1 | tail -1
for s in "$@"; do lune run tools/harness/play "$s" 2>&1 | grep -E "== $s|EXPECT|rror" | head -3; done
MAP=earth lune run tools/harness/soak 2>&1 | grep -E 'peak GUI|rror' | sed "s/^/earth /"
echo "delta done"
