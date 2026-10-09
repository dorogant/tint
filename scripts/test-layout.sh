#!/usr/bin/env bash
# Offscreen renders of the main window (Home, Search, playlist, artist, album,
# Liked Songs and the toolbar) with a fixture library: no login, network, audio
# or visible window. PNGs go to $FLOE_LAYOUT_DIR (default /tmp/tint-layout);
# FLOE_LAYOUT_ONLY=home,search renders a subset; FLOE_LAYOUT_PERF=1 also measures
# CPU and SwiftUI layouts per second on each surface, paused and playing.
# Needs the Rust core built (core/target/release), since the visualizer links it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
    find "$ROOT/Sources/Floe" -name '*.swift' \
        ! -path '*/App/FloeApp.swift' ! -path '*/App/SelfTest.swift' \
        ! -path '*/Core/FloeCore.swift' ! -path '*/Playback/AudioOutput.swift' \
        ! -path '*/Playback/NowPlaying.swift' | sort)
swiftc -swift-version 6 -O -module-name Floe -parse-as-library \
    -I "$ROOT/Sources/CFloeCore" -L "$ROOT/core/target/release" \
    -framework Security -framework SystemConfiguration -framework CoreFoundation -framework IOKit \
    "${SOURCES[@]}" "$ROOT/Tests/LayoutRenderSupport.swift" "$ROOT/Tests/LayoutRender.swift" \
    -o "$TEMP/layout-render"
# A private home keeps the harness's preferences and caches away from Tint's.
mkdir -p "$TEMP/home"
CFFIXED_USER_HOME="$TEMP/home" "$TEMP/layout-render"
