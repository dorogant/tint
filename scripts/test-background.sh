#!/usr/bin/env bash
# Production Metal rendering with synthetic inputs, no Spotify login or network.
# Set FLOE_BACKGROUND_PREVIEWS=<dir> to also write the rendered frames as PNGs, and
# FLOE_BLOOM_RENDERS=<dir> for Bloom's shapes, a scripted song frame by frame and its
# contact sheet. FLOE_BLOOM_ONLY=1 runs just Bloom's checks, renders and cost.
# FLOE_BLOOM_CHECK=fade,stability,oracle,resolution runs just those Bloom checks.
# FLOE_BUILD_ONLY=1 runs just the build and drop checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Views/ReactiveBackground.swift" \
    "$ROOT/Sources/Floe/Visualization/ReactiveShader.swift" \
    "$ROOT/Sources/Floe/Visualization/BackgroundMotion.swift" \
    "$ROOT/Sources/Floe/Visualization/BeatDetector.swift" \
    "$ROOT/Sources/Floe/Visualization/BeamRig.swift" \
    "$ROOT/Sources/Floe/Visualization/BloomRig.swift" \
    "$ROOT/Sources/Floe/Visualization/SpectrumAnalyzer.swift" \
    "$ROOT/Sources/Floe/Visualization/VisualSettings.swift" \
    "$ROOT/Sources/Floe/Images/CoverPalette.swift" \
    "$ROOT/Tests/BackgroundTestSupport.swift" "$ROOT/Tests/BackgroundTests.swift" "$ROOT/Tests/MusicFeatureTests.swift" \
    "$ROOT/Tests/AllocationCounter.swift" "$ROOT/Tests/BloomTests.swift" "$ROOT/Tests/TestDefaults.swift" \
    -o "$TEMP/background-tests"
"$TEMP/background-tests"
