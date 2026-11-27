#!/usr/bin/env bash
# Offscreen renders of the Mix and Stats pages in their states, in
# English (wide) and Ukrainian (narrow). No network, login, player or visible
# window. PNGs go to $FLOE_PAGES_DIR (default /tmp/tint-pages);
# FLOE_PAGES_ONLY=mix,stats picks pages.
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
    "${SOURCES[@]}" "$ROOT/Tests/LayoutRenderSupport.swift" "$ROOT/Tests/TestDefaults.swift" \
    "$ROOT/Tests/MixTestSupport.swift" "$ROOT/Tests/MixFixtures.swift" \
    "$ROOT/Tests/PagesRender.swift" \
    -o "$TEMP/pages-render"
# Localizations come from the app bundle at runtime; point the harness at the sources.
mkdir -p "$TEMP/home"
cp -R "$ROOT/Support/Localizations/"*.lproj "$TEMP/" 2>/dev/null || true
CFFIXED_USER_HOME="$TEMP/home" "$TEMP/pages-render"
