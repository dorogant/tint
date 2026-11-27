#!/usr/bin/env bash
# The updater: versions, GitHub's answers, the signature, and the whole install
# and reopening on stand-in app bundles in a temporary folder. No network and
# nothing of the real app is touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Updates/UpdateFeed.swift" \
    "$ROOT/Sources/Floe/Updates/UpdateInstaller.swift" \
    "$ROOT/Sources/Floe/Updates/UpdateModel.swift" \
    "$ROOT/Tests/UpdateTests.swift" "$ROOT/Tests/TestDefaults.swift" \
    -o "$TEMP/update-tests"
"$TEMP/update-tests"
