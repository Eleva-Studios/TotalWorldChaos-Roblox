#!/bin/bash
# runset.sh <worktree> <logprefix> scenario... : runs each harness scenario on its own (NO_SHOTS from the caller),
# one line per result; a failure keeps its error lines. Used by fullrun.sh.
dir=$1; prefix=$2; shift 2
cd "$dir" || exit 1
for s in "$@"; do
  log="${prefix}_$s.log"
  lune run tools/harness/play "$s" > "$log" 2>&1
  code=$?
  if grep -q "== $s passed" "$log"; then
    echo "$s: passed"
  else
    echo "$s: FAILED (exit $code)"
    grep -E "✗|no visible|EXPECT|rror|play:[0-9]+" "$log" | head -6 | sed 's/^/    /'
  fi
done
