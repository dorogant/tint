#!/usr/bin/env bash
# Install the signed app for this user and put its launch icon on the Desktop.
# The shortcut keeps pointing at the same location after future updates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/Floe.app"
APP_DIRECTORY="$HOME/Applications"
INSTALLED="$APP_DIRECTORY/Floe.app"
DESKTOP_LINK="$HOME/Desktop/Floe.app"

[[ -d "$SOURCE" ]] || { echo 'Build Floe first: scripts/build-app.sh'; exit 1; }
codesign --verify --strict "$SOURCE"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
[[ "$BUNDLE_ID" == 'com.antonchurchyn.floe' ]] || { echo 'Source is not the Floe app'; exit 1; }

if [[ -e "$INSTALLED" || -L "$INSTALLED" ]]; then
    [[ ! -L "$INSTALLED" && -d "$INSTALLED" ]] || { echo "Cannot replace $INSTALLED"; exit 1; }
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$EXISTING_ID" == "$BUNDLE_ID" ]] || { echo "Another item already occupies $INSTALLED"; exit 1; }
fi
if [[ -e "$DESKTOP_LINK" || -L "$DESKTOP_LINK" ]]; then
    [[ -L "$DESKTOP_LINK" && "$(readlink "$DESKTOP_LINK")" == "$INSTALLED" ]] \
        || { echo "Another item already occupies $DESKTOP_LINK"; exit 1; }
fi

mkdir -p "$APP_DIRECTORY"
STAGING="$(mktemp -d "$APP_DIRECTORY/.floe-install.XXXXXX")"
cleanup() {
    # Restore the previous installed build if moving the new bundle failed.
    if [[ ! -e "$INSTALLED" && -d "$STAGING/Previous.app" ]]; then
        mv "$STAGING/Previous.app" "$INSTALLED"
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
ditto "$SOURCE" "$STAGING/Floe.app"
codesign --verify --strict "$STAGING/Floe.app"
if [[ -d "$INSTALLED" ]]; then mv "$INSTALLED" "$STAGING/Previous.app"; fi
mv "$STAGING/Floe.app" "$INSTALLED"
if [[ ! -L "$DESKTOP_LINK" ]]; then ln -s "$INSTALLED" "$DESKTOP_LINK"; fi
printf 'Installed: %s\nDesktop icon: %s\n' "$INSTALLED" "$DESKTOP_LINK"
