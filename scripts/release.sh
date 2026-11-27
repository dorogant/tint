#!/usr/bin/env bash
# Makes the release that others download and that installed copies update to:
#   build/release/Tint.zip      the public build (scripts/build-app.sh --public)
#   build/release/Tint.zip.sig  the zip's signature, made with the update key
#
# Usage: scripts/release.sh [--publish]
#   --publish  also create the GitHub release v<version> with both files. Needs gh,
#              nothing uncommitted, the commit pushed, and a version no release has:
#              raise CFBundleShortVersionString in Support/Info.plist first.
#
# Installed copies only accept a zip signed with the update key, so both files
# always travel together. The key is the file FLOE_UPDATE_KEY names, else
# ~/.config/tint/update-key (made once by scripts/update-signature.swift generate).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
KEY="${FLOE_UPDATE_KEY:-$HOME/.config/tint/update-key}"

PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
sign_tool() { swift "$ROOT/scripts/update-signature.swift" "$@"; }

[[ -f "$KEY" ]] || fail "no update key at $KEY (FLOE_UPDATE_KEY). Without the key the copies already installed were built for, they can't be updated."
# A zip signed with another key would be refused by every installed copy.
BUILT_IN="$(sed -n 's/.*static let publicKey = "\(.*\)".*/\1/p' "$ROOT/Sources/Floe/Updates/UpdateInstaller.swift")"
[[ -n "$BUILT_IN" && "$(sign_tool public "$KEY")" == "$BUILT_IN" ]] \
    || fail "the key at $KEY isn't the one built into Tint (UpdateInstaller.publicKey)."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")"
if [[ $PUBLISH == 1 ]]; then
    command -v gh >/dev/null || fail "gh not found (https://cli.github.com)."
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || fail "there are uncommitted changes; a release is built from a commit."
    [[ -n "$(git -C "$ROOT" branch -r --contains HEAD 2>/dev/null)" ]] || fail "this commit isn't pushed yet."
    (cd "$ROOT" && ! gh release view "v$VERSION" >/dev/null 2>&1) \
        || fail "release v$VERSION exists already. Installed copies compare version numbers: raise CFBundleShortVersionString in Support/Info.plist."
fi

"$ROOT/scripts/build-app.sh" --public --zip
APP="$ROOT/build/Tint.app"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :FloeSpotifyClientID' "$PLIST" >/dev/null 2>&1 && fail "the build carries a Spotify client ID."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FloeUpdates' "$PLIST" 2>/dev/null)" == true ]] || fail "the build has updates off."

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$ROOT/build/Tint-$VERSION.zip" "$OUT/Tint.zip"
sign_tool sign "$KEY" "$OUT/Tint.zip" > "$OUT/Tint.zip.sig"
sign_tool verify "$BUILT_IN" "$OUT/Tint.zip" "$(cat "$OUT/Tint.zip.sig")"
printf '\nRelease %s: %s (%s) and its signature\n' "$VERSION" "$OUT/Tint.zip" "$(du -h "$OUT/Tint.zip" | cut -f1)"

if [[ $PUBLISH == 1 ]]; then
    # With files named, gh publishes the release only after they are uploaded, so
    # "latest" never points at a release an installed copy can't take.
    (cd "$ROOT" && gh release create "v$VERSION" "$OUT/Tint.zip" "$OUT/Tint.zip.sig" \
        --target "$(git rev-parse HEAD)" --title "Tint $VERSION" --generate-notes)
else
    echo "Not published. scripts/release.sh --publish creates the GitHub release."
fi
