#!/usr/bin/env bash
# The Stats page's own numbers against a hand-made listening history: periods
# at local day boundaries, top lists, ties and the chart's bars. No network,
# login or window; nothing is read from the real history.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Stats/ListeningStats.swift" \
    "$ROOT/Sources/Floe/Library/ListeningHistory.swift" \
    "$ROOT/Sources/Floe/Core/CoreEvent.swift" \
    "$ROOT/Sources/Floe/API/Models.swift" \
    "$ROOT/Tests/StatsTests.swift" \
    -o "$TEMP/stats-tests"
"$TEMP/stats-tests"
