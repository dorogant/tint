#!/usr/bin/env bash
# The auto preset offline: genre mapping, the sound classifier on synthetic
# songs, hysteresis, manual override, persistence and the per-artist genre
# cache. No login, network, audio or window. Needs the Rust core built
# (core/target/release), since the module links it.
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
    "${SOURCES[@]}" "$ROOT/Tests/LayoutRenderSupport.swift" \
    "$ROOT/Tests/AutoPresetSongs.swift" "$ROOT/Tests/AutoPresetTests.swift" \
    -o "$TEMP/autopreset-tests"
mkdir -p "$TEMP/home"
CFFIXED_USER_HOME="$TEMP/home" "$TEMP/autopreset-tests"
