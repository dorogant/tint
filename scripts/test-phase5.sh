#!/usr/bin/env bash
# Offline playback/API recovery checks: all tokens, devices and metadata are synthetic.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --release --manifest-path "$ROOT/core/Cargo.toml"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Core/CoreEvent.swift" "$ROOT/Sources/Floe/API/PlaybackAPI.swift" "$ROOT/Sources/Floe/API/Models.swift" "$ROOT/Sources/Floe/API/WebAPI.swift" \
    "$ROOT/Sources/Floe/Auth/TokenProviders.swift" "$ROOT/Sources/Floe/Auth/SpotifyOAuth.swift" \
    "$ROOT/Sources/Floe/Auth/CredentialStore.swift" "$ROOT/Sources/Floe/Auth/LoopbackRedirectServer.swift" \
    "$ROOT/Sources/Floe/Support/Localization.swift" "$ROOT/Sources/Floe/Playback/ConnectModel.swift" \
    "$ROOT/Tests/Phase5Tests.swift" -o "$TEMP/phase5-tests"
"$TEMP/phase5-tests" "$ROOT"
plutil -lint "$ROOT/Support/Localizations/en.lproj/Localizable.strings" "$ROOT/Support/Localizations/uk.lproj/Localizable.strings" \
    "$ROOT/Support/Localizations/en.lproj/Localizable.stringsdict" "$ROOT/Support/Localizations/uk.lproj/Localizable.stringsdict"
