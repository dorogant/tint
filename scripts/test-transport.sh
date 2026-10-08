#!/usr/bin/env bash
# Production playback state with synthetic core events; no login, network or audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Playback/PlayerModel.swift" \
    "$ROOT/Sources/Floe/Core/CoreEvent.swift" \
    "$ROOT/Sources/Floe/API/Models.swift" \
    "$ROOT/Sources/Floe/Settings/AppSettings.swift" \
    "$ROOT/Tests/PlaybackTransportTestSupport.swift" \
    "$ROOT/Tests/PlaybackTransportTests.swift" \
    -o "$TEMP/transport-tests"
"$TEMP/transport-tests"
