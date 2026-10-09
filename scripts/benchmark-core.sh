#!/usr/bin/env bash
# Offline timings for cover decoding, the per-song cover work, palettes and core
# events (Tests/CoreBenchmarks.swift), plus the Rust audio path. No app, login,
# network or audio device. The harness gets a private home for its caches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --release -q --manifest-path "$ROOT/core/Cargo.toml" -- --ignored --nocapture bench_ | grep BENCH
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Images/Artwork.swift" "$ROOT/Sources/Floe/Images/CoverAppearance.swift" \
    "$ROOT/Sources/Floe/Images/CoverPalette.swift" "$ROOT/Sources/Floe/Core/CoreEvent.swift" \
    "$ROOT/Sources/Floe/API/Models.swift" "$ROOT/Sources/Floe/Support/ViewState.swift" \
    "$ROOT/Sources/Floe/Views/Motion.swift" "$ROOT/Tests/CoreBenchmarks.swift" \
    -o "$TEMP/core-benchmarks"
mkdir -p "$TEMP/home"
CFFIXED_USER_HOME="$TEMP/home" "$TEMP/core-benchmarks"
