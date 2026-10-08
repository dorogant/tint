#!/usr/bin/env bash
# Production SwiftUI lyric view, synthetic data, no login or network needed.
# Optional argument selects an older LyricsView.swift for the same benchmark.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
VIEW="${1:-$ROOT/Sources/Floe/Views/LyricsView.swift}"
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Support/ViewState.swift" \
    "$ROOT/Sources/Floe/Views/Motion.swift" \
    "$ROOT/Sources/Floe/Lyrics/LRC.swift" "$VIEW" \
    "$ROOT/Tests/LyricsRenderingSupport.swift" \
    "$ROOT/Tests/LyricsRenderingBenchmark.swift" \
    -o "$TEMP/lyrics-rendering-benchmark"
"$TEMP/lyrics-rendering-benchmark"
