#!/usr/bin/env bash
# The equalizer's settings, the ring that carries Soloist's tapped sound and the
# real audio graph rendered offline. No Soloist, login, network or audio device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Playback/Equalizer.swift" \
    "$ROOT/Sources/Floe/Playback/EqualizerOutput.swift" \
    "$ROOT/Tests/EqualizerTests.swift" "$ROOT/Tests/TestDefaults.swift" \
    -o "$TEMP/equalizer-tests"
"$TEMP/equalizer-tests"
