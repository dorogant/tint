#!/usr/bin/env bash
# Cover colour checks on synthetic covers, offscreen: no app, no login, no network.
# FLOE_PALETTE_PREVIEWS=<dir> also writes contact sheets (cover, accent, highlight,
# background colours, visualizer); FLOE_PALETTE_COVERS=<dir> adds real covers to them.
# Pass a git revision to draw that revision's extractor beside the current one:
#   FLOE_PALETTE_PREVIEWS=/tmp/palette scripts/test-palette.sh f028295
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
EXTRA=()
if [ $# -gt 0 ]; then
    git -C "$ROOT" show "$1:Sources/Floe/Images/CoverPalette.swift" \
        | perl -pe 's/CoverColorExtractor/LegacyExtractor/g; s/\bRGB\b/LegacyRGB/g; s/\bOKLab\b/LegacyOKLab/g' \
        > "$TEMP/LegacyPalette.swift"
    EXTRA=("$TEMP/LegacyPalette.swift" -D PALETTE_BEFORE)
fi
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Images/CoverPalette.swift" \
    "$ROOT/Sources/Floe/Views/VisualizerView.swift" \
    "$ROOT/Sources/Floe/Visualization/SpectrumAnalyzer.swift" \
    "$ROOT/Tests/LayerTestSupport.swift" "$ROOT/Tests/PaletteTests.swift" \
    ${EXTRA[@]+"${EXTRA[@]}"} -o "$TEMP/palette-tests"
"$TEMP/palette-tests"
