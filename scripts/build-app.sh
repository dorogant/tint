#!/usr/bin/env bash
# Builds build/Floe.app with only the Command Line Tools (no Xcode):
#   1. Rust core      cargo build --release        -> core/target/release/libfloe_core.a
#   2. Swift app      swift build -c release       -> .build/release/Floe
#   3. Bundle         Info.plist, icon, executable -> build/Floe.app
#   4. Sign           with the local "Floe Local Signing" certificate if present,
#                     otherwise ad-hoc (see README: Signing)
#
# Usage: scripts/build-app.sh [--debug] [--install] [--open]
#   --debug  Swift debug build (the Rust core is always release)
#   --open   launch the app when done
#   --install update ~/Applications/Floe.app and its Desktop shortcut
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Floe"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
# Signing certificate: $FLOE_SIGN_IDENTITY, else the git-ignored per-machine file
# .signing-identity (a certificate name or SHA-1), else "Floe Local Signing".
if [[ -z "${FLOE_SIGN_IDENTITY:-}" && -f "$ROOT/.signing-identity" ]]; then
    FLOE_SIGN_IDENTITY="$(head -n 1 "$ROOT/.signing-identity")"
fi
SIGN_IDENTITY="${FLOE_SIGN_IDENTITY:-Floe Local Signing}"
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0

CONFIG=release
OPEN=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --open) OPEN=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }

command -v cargo >/dev/null || { echo "cargo not found: install Rust with rustup first" >&2; exit 1; }

step "Rust core (cargo build --release)"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml"

step "Swift app (swift build -c $CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

step "Icon"
ICON="$OUT/AppIcon.icns"
if [[ ! -f "$ICON" || "$ROOT/scripts/make-icon.swift" -nt "$ICON" ]]; then
    ICONSET="$OUT/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift "$ROOT/scripts/make-icon.swift" "$OUT/AppIcon-1024.png"
    for px in 16 32 128 256 512; do
        sips -z $px $px "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
        sips -z $((px * 2)) $((px * 2)) "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICON"
    rm -rf "$ICONSET" "$OUT/AppIcon-1024.png"
fi

step "Assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Support/Localizations/"*.lproj "$APP/Contents/Resources/"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# A stable certificate keeps the Keychain's access rule valid across rebuilds;
# ad-hoc signatures change every build and trigger a Keychain prompt.
if security find-identity -p codesigning 2>/dev/null | grep -qF -e "\"$SIGN_IDENTITY\"" -e " $SIGN_IDENTITY "; then
    step "Sign ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
else
    step "Sign (ad-hoc: no \"$SIGN_IDENTITY\" certificate found)"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

printf '\nBuilt %s (%s, %s)\n' "$APP" "$CONFIG" "$(du -sh "$APP" | cut -f1)"
if [[ $INSTALL == 1 ]]; then
    "$ROOT/scripts/install-app.sh"
    APP="$HOME/Applications/$APP_NAME.app"
fi
if [[ $OPEN == 1 ]]; then open "$APP"; fi
