#!/usr/bin/env bash
# Credential files and the one-time Keychain migration, in a temporary folder with a
# fake keychain: never touches Application Support or the real Keychain items.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Auth/CredentialStore.swift" \
    "$ROOT/Tests/CredentialStoreTests.swift" \
    -o "$TEMP/credential-tests"
mkdir "$TEMP/data"
"$TEMP/credential-tests" "$TEMP/data"
