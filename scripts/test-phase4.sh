#!/usr/bin/env bash
# Real PCM tap tests in Rust, deterministic frequency-response tests in Swift/vDSP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --release --manifest-path "$ROOT/core/Cargo.toml" analysis::tests
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O "$ROOT/Sources/Floe/Visualization/SpectrumAnalyzer.swift" \
    "$ROOT/Sources/Floe/Visualization/ReactiveShader.swift" "$ROOT/Tests/Phase4Tests.swift" -o "$TEMP/phase4-tests"
"$TEMP/phase4-tests"
