#!/usr/bin/env bash
# The mix: ReccoBeats answers captured from the real service, the choosing
# rules, and a whole session driven by a fake player and stub sources.
# No login, network, audio or player.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Mix/ReccoBeats.swift" \
    "$ROOT/Sources/Floe/Mix/MixChooser.swift" \
    "$ROOT/Sources/Floe/Mix/MixModel.swift" \
    "$ROOT/Sources/Floe/API/Models.swift" \
    "$ROOT/Tests/TestDefaults.swift" \
    "$ROOT/Tests/MixFixtures.swift" \
    "$ROOT/Tests/MixTestSupport.swift" \
    "$ROOT/Tests/MixTests.swift" \
    -o "$TEMP/mix-tests"
"$TEMP/mix-tests"
