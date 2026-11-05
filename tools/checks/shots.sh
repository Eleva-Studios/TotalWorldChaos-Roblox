#!/bin/bash
# shots.sh <checkout> <label> <viewport or ""> scenario... : renders the scenarios with screenshots at one size and
# keeps them in tools/harness/out_<label>/ (for reviewing a GUI change at 844x390, 667x375 and 1366x1024).
cd "$1" || exit 1; label=$2; vp=$3; shift 3
rm -rf tools/harness/out
for s in "$@"; do
  if [ -n "$vp" ]; then r=$(VIEWPORT=$vp lune run tools/harness/play "$s" 2>&1); else r=$(lune run tools/harness/play "$s" 2>&1); fi
  echo "$r" | grep -E "== $s|rror|EXPECT|✗" | head -5 | sed "s/^/$label /"
done
rm -rf "tools/harness/out_$label"; mv tools/harness/out "tools/harness/out_$label"
echo "shots done"
