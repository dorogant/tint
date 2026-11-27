#!/usr/bin/env bash
# The Friends page without the app: ListenBrainz's answers (captured ones, in
# Tests/FriendsFixtures.swift), the paced line of requests on a fake clock, the
# list of friends and its refreshing. No network, login or window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
swiftc -swift-version 6 -O \
    "$ROOT/Sources/Floe/Friends/ListenBrainz.swift" \
    "$ROOT/Sources/Floe/Friends/FriendsModel.swift" \
    "$ROOT/Tests/FriendsFixtures.swift" \
    "$ROOT/Tests/TestDefaults.swift" \
    "$ROOT/Tests/FriendsTests.swift" \
    -o "$TEMP/friends-tests"
"$TEMP/friends-tests"
