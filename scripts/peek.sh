#!/usr/bin/env bash
# runs build/Peek.app from the terminal. it goes through `open` so macos treats it as the app
# (and shows the photos prompt as "Peek"), with its output streamed back here.
#   scripts/peek.sh index
#   scripts/peek.sh search a yellow boat --sheet /tmp/boat.jpg
set -euo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
open -W -n --stdout "$log" --stderr "$log" build/Peek.app --args "$@" &
app=$!
tail -n +1 -f "$log" &
follow=$!
wait "$app"
sleep 0.2
kill "$follow" 2>/dev/null || true
wait "$follow" 2>/dev/null || true
rm -f "$log"
