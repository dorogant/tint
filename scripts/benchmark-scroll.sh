#!/usr/bin/env bash
# Scrolls the real playlist page through 600 synthetic tracks (paged, with
# generated covers) in an offscreen window and reports main-thread time per
# frame, CPU, window layouts and row rebuilds. No login, network, audio or
# visible window. FLOE_SCROLL_ONLY=cold,warm,hover,flick,cold-liked picks
# runs; FLOE_SCROLL_SECONDS and FLOE_SCROLL_SPEED (pt/s) set their length and pace;
# FLOE_SCROLL_VIEWS=1 counts AppKit views after each run, FLOE_SCROLL_REDRAWS=1 the
# layers drawn again during it.
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
swiftc -swift-version 6 -O -module-name Floe -parse-as-library -D SCROLL_BENCHMARK \
    -I "$ROOT/Sources/CFloeCore" -L "$ROOT/core/target/release" \
    -framework Security -framework SystemConfiguration -framework CoreFoundation -framework IOKit \
    "${SOURCES[@]}" "$ROOT/Tests/LayoutRenderSupport.swift" \
    "$ROOT/Tests/ScrollBenchmarkFixture.swift" "$ROOT/Tests/ScrollBenchmark.swift" \
    -o "$TEMP/scroll-benchmark"
# A private home keeps the harness's preferences and caches away from Tint's.
mkdir -p "$TEMP/home"
CFFIXED_USER_HOME="$TEMP/home" "$TEMP/scroll-benchmark"
