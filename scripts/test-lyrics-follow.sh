#!/usr/bin/env bash
# Synced lyrics' Follow, frame by frame: the real LyricsView in offscreen windows
# with a synthetic clock; no login, network or visible window. LYRICS_FOLLOW_TESTING
# compiles in transparent markers on each row and the pill. Optional argument
# checks another LyricsView.swift; FLOE_FOLLOW_ONLY=A|B|C|D|E|F|G runs one group,
# FLOE_FOLLOW_TRACE=1 prints every sampled frame.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
VIEW="${1:-$ROOT/Sources/Floe/Views/LyricsView.swift}"
swiftc -swift-version 6 -O -D LYRICS_FOLLOW_TESTING \
    "$ROOT/Sources/Floe/Support/ViewState.swift" "$ROOT/Sources/Floe/Support/InterfaceScale.swift" \
    "$ROOT/Sources/Floe/Support/ListMotion.swift" \
    "$ROOT/Sources/Floe/Views/Motion.swift" "$ROOT/Sources/Floe/Views/LoopingSymbol.swift" \
    "$ROOT/Sources/Floe/Lyrics/LRC.swift" "$VIEW" \
    "$ROOT/Tests/LyricsRenderingSupport.swift" "$ROOT/Tests/LyricsFollowTests.swift" "$ROOT/Tests/AllocationCounter.swift" \
    -o "$TEMP/lyrics-follow-tests"
"$TEMP/lyrics-follow-tests"
