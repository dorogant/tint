#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Images/Artwork.swift" "$ROOT/Sources/Floe/API/Models.swift" \
    "$ROOT/Sources/Floe/Support/ViewState.swift" "$ROOT/Tests/ArtworkTests.swift" \
    "$ROOT/Sources/Floe/Views/Motion.swift" \
    -o "$TEMP/artwork-tests"
"$TEMP/artwork-tests"
