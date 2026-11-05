#!/bin/bash
# fullrun.sh <checkout> <prefix> [scenarios for 667x375...]: the coordinator's full check of a merge before main moves.
# Quick checks (stylua, selene, Lune tests, rojo build), every harness scenario in two streams (NO_SHOTS), the soak on
# all three maps, the no-EditableImage smoke and menu, then the given scenarios at VIEWPORT=667x375. Prints
# "fullrun done" last. Logs go to $CHECK_LOGS (default: a check-logs folder next to the checkout).
# Runs take 40-70 minutes; start it detached (setsid nohup ... &) with an until-loop waiter on "fullrun done".
T=$(cd "$1" && pwd) || exit 1; P=$2; shift 2
L=${CHECK_LOGS:-$(dirname "$T")/check-logs}; mkdir -p "$L"
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$T" || exit 1
export NO_SHOTS=1
(stylua --check src tests > /dev/null 2>&1 && echo "stylua ok") || echo "STYLUA FAILED"
RUST_MIN_STACK=67108864 selene src 2>&1 | tail -3 | tr '\n' ' '; echo
lune run tests/run 2>&1 | grep -E "FAIL|spec files" | tail -6
mkdir -p build && rojo build -o build/game.rbxlx 2>&1 | tail -1
a=""; b=""; i=0
for s in $(ls tools/harness/scenarios/ | sed 's/\.luau$//'); do if [ $((i % 2)) -eq 0 ]; then a="$a $s"; else b="$b $s"; fi; i=$((i+1)); done
("$HERE/runset.sh" "$T" "$L/${P}a" $a > "$L/${P}a.out" 2>&1) &
("$HERE/runset.sh" "$T" "$L/${P}b" $b > "$L/${P}b.out" 2>&1) &
wait
cat "$L/${P}a.out" "$L/${P}b.out"
echo "scenarios passed: $(cat "$L/${P}a.out" "$L/${P}b.out" | grep -c ': passed')"
for m in earth eldmoor skyshards; do MAP=$m lune run tools/harness/soak 2>&1 | grep -E 'peak GUI|rror|busiest|fleets' | sed "s/^/$m /"; done
NO_EDITABLE_IMAGE=1 lune run tools/harness/play smoke 2>&1 | grep -E '== smoke|rror|EXPECT' | sed 's/^/no-image /'
NO_EDITABLE_IMAGE=1 lune run tools/harness/play menu 2>&1 | grep -E '== menu|rror|EXPECT' | sed 's/^/no-image /'
for s in "$@"; do VIEWPORT=667x375 lune run tools/harness/play "$s" 2>&1 | grep -E "== $s|rror|EXPECT" | sed 's/^/667x375 /'; done
echo "fullrun done"
