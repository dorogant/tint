#!/usr/bin/env bash
# Installs the built app as ~/Applications/Tint.app for this user.
# Usage: scripts/install-app.sh [--desktop-icon]
#   --desktop-icon  also put a Tint icon on the Desktop (a link to the installed
#                   app, so it keeps working after future updates)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/Tint.app"
APP_DIRECTORY="$HOME/Applications"
INSTALLED="$APP_DIRECTORY/Tint.app"
DESKTOP_LINK="$HOME/Desktop/Tint.app"
# The app used to be called Floe. Its old copy shares the bundle ID, so it goes.
LEGACY="$APP_DIRECTORY/Floe.app"
LEGACY_LINK="$HOME/Desktop/Floe.app"

DESKTOP_ICON=0
for arg in "$@"; do
    case "$arg" in
        --desktop-icon) DESKTOP_ICON=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

[[ -d "$SOURCE" ]] || { echo 'Build Tint first: scripts/build-app.sh'; exit 1; }
codesign --verify --strict "$SOURCE"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE/Contents/Info.plist")" == 'Tint' ]] \
    || { echo 'Source is not the Tint app'; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"

if [[ -e "$INSTALLED" || -L "$INSTALLED" ]]; then
    [[ ! -L "$INSTALLED" && -d "$INSTALLED" ]] || { echo "Cannot replace $INSTALLED"; exit 1; }
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$EXISTING_ID" == "$BUNDLE_ID" ]] || { echo "Another item already occupies $INSTALLED"; exit 1; }
fi
# An existing link to the installed app is kept either way.
if [[ -e "$DESKTOP_LINK" || -L "$DESKTOP_LINK" ]]; then
    if [[ -L "$DESKTOP_LINK" && "$(readlink "$DESKTOP_LINK")" == "$INSTALLED" ]]; then
        DESKTOP_ICON=1
    elif [[ $DESKTOP_ICON == 1 ]]; then
        echo "Another item already occupies $DESKTOP_LINK"; exit 1
    fi
fi

mkdir -p "$APP_DIRECTORY"
STAGING="$(mktemp -d "$APP_DIRECTORY/.tint-install.XXXXXX")"
cleanup() {
    # Restore the previous installed build if moving the new bundle failed.
    if [[ ! -e "$INSTALLED" && -d "$STAGING/Previous.app" ]]; then
        mv "$STAGING/Previous.app" "$INSTALLED"
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
ditto "$SOURCE" "$STAGING/Tint.app"
codesign --verify --strict "$STAGING/Tint.app"
if [[ -d "$INSTALLED" ]]; then mv "$INSTALLED" "$STAGING/Previous.app"; fi
mv "$STAGING/Tint.app" "$INSTALLED"
if [[ $DESKTOP_ICON == 1 && ! -L "$DESKTOP_LINK" ]]; then ln -s "$INSTALLED" "$DESKTOP_LINK"; fi
if [[ -d "$LEGACY" && ! -L "$LEGACY" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$LEGACY/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]; then
    mv "$LEGACY" "$STAGING/Legacy.app"
fi
if [[ -L "$LEGACY_LINK" && "$(readlink "$LEGACY_LINK")" == "$LEGACY" ]]; then rm "$LEGACY_LINK"; fi
printf 'Installed: %s\n' "$INSTALLED"
if [[ $DESKTOP_ICON == 1 ]]; then printf 'Desktop icon: %s\n' "$DESKTOP_LINK"; fi
