#!/usr/bin/env bash
# Production Metal rendering with synthetic inputs, no Spotify login or network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Views/ReactiveBackground.swift" \
    "$ROOT/Sources/Floe/Visualization/ReactiveShader.swift" \
    "$ROOT/Sources/Floe/Visualization/SpectrumAnalyzer.swift" \
    "$ROOT/Sources/Floe/Images/CoverPalette.swift" \
    "$ROOT/Tests/BackgroundTestSupport.swift" "$ROOT/Tests/BackgroundTests.swift" \
    -o "$TEMP/background-tests"
"$TEMP/background-tests"
