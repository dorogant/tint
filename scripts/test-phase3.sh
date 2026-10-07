#!/usr/bin/env bash
# Synthetic parser, matching and image tests, runnable with Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Core/CoreEvent.swift" \
    "$ROOT/Sources/Floe/Lyrics/LRC.swift" \
    "$ROOT/Sources/Floe/Lyrics/LyricsService.swift" \
    "$ROOT/Sources/Floe/Images/CoverPalette.swift" \
    "$ROOT/Tests/Phase3Tests.swift" -o "$TEMP/phase3-tests"
"$TEMP/phase3-tests"
