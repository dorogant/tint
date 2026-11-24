#!/bin/bash
# Measures a running app from outside, for the comparison in the README: CPU as a share
# of one core, and memory footprint (Activity Monitor's "Memory"). Both are summed over
# every process inside the app's bundle, because a Chromium app is several processes
# and its own window only shows one of them.
#
# It starts, stops and plays nothing. Put the app in the state to measure first (the
# same song playing, the window visible), then run this.
#
#   scripts/measure-app.sh Tint          # 60 s
#   scripts/measure-app.sh Spotify 30    # 30 s
set -euo pipefail

APP="${1:-}"
DURATION="${2:-60}"
[ -n "$APP" ] || { echo "usage: $0 <app name> [seconds]" >&2; exit 2; }

# Each process in the bundle, with the CPU seconds it has used so far.
snapshot() {
    ps -axo pid=,time=,comm= | awk -v bundle="/$APP.app/" '
        index($0, bundle) {
            n = split($2, part, ":"); seconds = 0
            for (i = 1; i <= n; i++) seconds = seconds * 60 + part[i]
            print $1, seconds
        }'
}

# footprint counts memory the processes share once, which adding up Activity Monitor's
# rows does not.
footprint_bytes() {
    local file args=() bytes
    file=$(mktemp)
    for pid in $(snapshot | awk '{print $1}'); do args+=(-p "$pid"); done
    footprint "${args[@]}" -j "$file" >/dev/null 2>&1 || true
    bytes=$(plutil -extract 'total footprint' raw -o - "$file" 2>/dev/null || echo 0)
    rm -f "$file"
    echo "$bytes"
}

before=$(snapshot)
[ -n "$before" ] || { echo "$APP isn't running." >&2; exit 1; }

memory_sum=0
memory_samples=0
started=$(date +%s)
while :; do
    bytes=$(footprint_bytes)
    if [ "$bytes" -gt 0 ]; then
        memory_sum=$((memory_sum + bytes))
        memory_samples=$((memory_samples + 1))
    fi
    left=$((DURATION - ($(date +%s) - started)))
    [ "$left" -gt 0 ] || break
    sleep $((left < 10 ? left : 10))
done
after=$(snapshot)
elapsed=$(($(date +%s) - started))
[ "$memory_samples" -gt 0 ] || { echo "$APP quit while it was being measured." >&2; exit 1; }

# A process that started during the measurement counts in full; one that quit is left out.
cpu=$( { echo "$before" | sed 's/^/before /'; echo "$after" | sed 's/^/after /'; } | awk -v elapsed="$elapsed" '
    $1 == "before" { start[$2] = $3 }
    $1 == "after"  { used += $3 - start[$2] }
    END { printf "%.1f", used / elapsed * 100 }')
count=$(echo "$after" | grep -c .)
megabytes=$((memory_sum / memory_samples / 1000000))

echo "$APP: CPU $cpu% of one core, memory $megabytes MB, processes $count, over $elapsed s"
