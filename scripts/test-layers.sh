#!/usr/bin/env bash
# Offscreen pixel checks for the Core Animation views (cover, visualizer, progress track).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Views/CrawlingCover.swift" "$ROOT/Sources/Floe/Views/BlobShape.swift" \
    "$ROOT/Sources/Floe/Views/LayerClock.swift" \
    "$ROOT/Sources/Floe/Views/VisualizerView.swift" "$ROOT/Sources/Floe/Views/ProgressTrack.swift" \
    "$ROOT/Sources/Floe/Visualization/SpectrumAnalyzer.swift" \
    "$ROOT/Tests/LayerTestSupport.swift" "$ROOT/Tests/LayerTests.swift" "$ROOT/Tests/AllocationCounter.swift" \
    -o "$TEMP/layer-tests"
"$TEMP/layer-tests"
