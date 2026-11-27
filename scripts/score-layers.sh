#!/usr/bin/env bash
# Scores the analyzer's layers against real instruments: families of GarageBand's
# Apple Loops mixed with their parts known (Tests/StemScore.swift). A measurement,
# not a pass/fail suite: run it before and after a change to the analysis.
# FLOE_STEMS_ONLY=<name> scores one family.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O ${FLOE_STEMS_FLAGS:--D LEAD_LAYER} \
    "$ROOT/Sources/Floe/Visualization/SpectrumAnalyzer.swift" \
    "$ROOT/Tests/StemScore.swift" \
    -o "$TEMP/stem-score"
"$TEMP/stem-score"
