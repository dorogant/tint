#!/usr/bin/env bash
# Whether Tint knows it is in front and visible, which gates the audio tap, the
# visualizer and the live background. A stand-in AppKit; no window is shown.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/App/WindowPresence.swift" "$ROOT/Tests/PresenceTests.swift" \
    -o "$TEMP/presence-tests"
"$TEMP/presence-tests"
