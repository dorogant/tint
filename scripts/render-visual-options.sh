#!/usr/bin/env bash
# Offscreen renders of the Visuals popover's controls (live-background presets
# included) in English and Ukrainian. No login, network, audio or visible window.
# PNGs go to $FLOE_OPTIONS_DIR (default /tmp/tint-visual-options).
# Needs the Rust core built (core/target/release), since the module links it.
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
    "${SOURCES[@]}" "$ROOT/Tests/LayoutRenderSupport.swift" "$ROOT/Tests/VisualOptionsRender.swift" \
    -o "$TEMP/visual-options"
# Localizations come from the app bundle at runtime; point the harness at the sources.
mkdir -p "$TEMP/home"
cp -R "$ROOT/Support/Localizations/"*.lproj "$TEMP/" 2>/dev/null || true
CFFIXED_USER_HOME="$TEMP/home" "$TEMP/visual-options"
