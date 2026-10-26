#!/bin/sh
# Plays both scenes with the game runtime given, and says what each referee
# said: meadow.json (a Flux runner and referee, a graph score) and
# swapped.json (a graph runner and referee, a Flux score).
#   tools/run.sh <fluxion-runtime> [<scratch folder>]
set -u
RUNTIME=$1
WORK=${2:-$(mktemp -d)}
mkdir -p "$WORK"
HERE=$(cd "$(dirname "$0")/.." && pwd)
python3 "$HERE/tools/make_graphs.py" > /dev/null || exit 1
status=0
for scene in meadow swapped; do
    copy="$WORK/$scene"
    rm -rf "$copy"
    cp -r "$HERE" "$copy"
    sed -i "s#res://levels/meadow.json#res://levels/$scene.json#" "$copy/project.fluxion"
    timeout 60 "$RUNTIME" --root "$copy" --frames 600 > "$WORK/$scene.log" 2>&1
    echo "== $scene"
    grep -E "REFEREE|warning|error" "$WORK/$scene.log" || echo "(the referee said nothing)"
    grep -q "REFEREE PASS" "$WORK/$scene.log" || status=1
done
exit $status
