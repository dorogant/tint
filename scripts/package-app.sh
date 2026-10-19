#!/usr/bin/env bash
# Packs build/Tint.app into build/Tint-<version>.zip to hand to someone else.
# Run scripts/build-app.sh first (or use its --zip).
#
# Notarization is optional: with the app signed by a Developer ID certificate
# (FLOE_DEVELOPER_ID at build time) and FLOE_NOTARY_PROFILE naming a keychain
# profile saved with `xcrun notarytool store-credentials`, the zip is sent to
# Apple, the ticket is stapled to the app and the zip is packed again. Without
# them the zip is un-notarized: see README, Sharing a build, for how to open it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tint.app"

[[ -d "$APP" ]] || { echo 'Build Tint first: scripts/build-app.sh' >&2; exit 1; }
codesign --verify --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Tint-$VERSION.zip"

pack() {
    rm -f "$ZIP"
    # ditto keeps the bundle's symlinks, permissions and signature intact; zip(1) doesn't.
    ditto -c -k --keepParent "$APP" "$ZIP"
}
pack

if [[ -n "${FLOE_NOTARY_PROFILE:-}" ]]; then
    codesign -dv "$APP" 2>&1 | grep -q '^Authority=Developer ID Application' || {
        echo 'FLOE_NOTARY_PROFILE is set, but the app is not signed with a Developer ID certificate.' >&2
        echo 'Rebuild with FLOE_DEVELOPER_ID set, or unset FLOE_NOTARY_PROFILE.' >&2
        exit 1
    }
    printf '\n==> Notarize (profile %s)\n' "$FLOE_NOTARY_PROFILE"
    RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$FLOE_NOTARY_PROFILE" --wait 2>&1)"
    echo "$RESULT"
    grep -q 'status: Accepted' <<<"$RESULT" || {
        echo 'Notarization was not accepted; `xcrun notarytool log <id>` explains why.' >&2
        exit 1
    }
    xcrun stapler staple "$APP"
    pack
    spctl --assess --type execute --verbose "$APP"
fi

if [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :FloeSpotifyClientID' "$APP/Contents/Info.plist" 2>/dev/null)" ]]; then
    CLIENT_NOTE="It uses your Spotify developer app; add the recipient's Spotify email under User Management, or they paste their own Client ID."
else
    CLIENT_NOTE="No Spotify client ID is built in; the recipient pastes their own on first launch."
fi
printf '\nPacked %s (%s)\n%s\n' "$ZIP" "$(du -h "$ZIP" | cut -f1)" "$CLIENT_NOTE"
