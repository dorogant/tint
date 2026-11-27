#!/usr/bin/env bash
# The listening history: what counts as a play and how plays are kept on disk.
# No login, network or audio; the file lives in a temporary folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Library/ListeningHistory.swift" \
    "$ROOT/Sources/Floe/Core/CoreEvent.swift" \
    "$ROOT/Sources/Floe/API/Models.swift" \
    "$ROOT/Tests/HistoryTests.swift" \
    -o "$TEMP/history-tests"
"$TEMP/history-tests"
