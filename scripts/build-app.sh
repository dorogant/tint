#!/usr/bin/env bash
# Builds build/Tint.app with only the Command Line Tools (no Xcode):
#   1. Rust core      cargo build --release        -> core/target/release/libfloe_core.a
#   2. Swift app      swift build -c release       -> .build/release/Floe
#   3. Bundle         Info.plist, icon, executable -> build/Tint.app
#   4. Sign           Developer ID, a local certificate, or ad-hoc (see docs/REFERENCE.md: Signing)
#
# Usage: scripts/build-app.sh [--debug] [--public] [--zip] [--install] [--open]
#   --debug   Swift debug build (the Rust core is always release)
#   --public  the copy handed to others: no Spotify client ID built in, signed ad-hoc
#             (or with FLOE_DEVELOPER_ID), and it updates itself from GitHub's releases
#   --zip     also pack build/Tint-<version>.zip to share (scripts/package-app.sh)
#   --install update ~/Applications/Tint.app (scripts/install-app.sh)
#   --open    launch the app when done
#
# Per-machine settings, all optional. Each is an environment variable or a
# git-ignored one-line file at the repo root:
#   FLOE_SPOTIFY_CLIENT_ID   .spotify-client-id   Web API client ID built into the app;
#                                                 without one, Tint asks on first launch
#   FLOE_SIGN_IDENTITY       .signing-identity    code-signing certificate (name or SHA-1)
#   FLOE_DEVELOPER_ID        -                    "Developer ID Application: …" identity;
#                                                 signs with the hardened runtime
#   FLOE_NOTARY_PROFILE      -                    notarytool keychain profile (--zip only)
#   FLOE_BUNDLE_ID           -                    bundle ID (default com.antonchurchyn.floe)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The app is Tint; its Swift package product keeps the original name, Floe.
APP_NAME="Tint"
PRODUCT="Floe"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0

CONFIG=release
OPEN=0
INSTALL=0
ZIP=0
PUBLIC=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --open) OPEN=1 ;;
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        --public) PUBLIC=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Reads a setting from the environment, else the first line of a repo-root file.
setting() {
    local value="${!1:-}"
    if [[ -z "$value" && -f "$ROOT/$2" ]]; then value="$(head -n 1 "$ROOT/$2" | tr -d '[:space:]')"; fi
    printf '%s' "$value"
}
# True when version $1 >= $2 (dotted, numeric).
at_least() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" == "$2" ]]; }

step "Toolchain"
[[ "$(uname -m)" == arm64 ]] || fail "Tint builds for Apple Silicon only (this Mac is $(uname -m))."
xcode-select -p >/dev/null 2>&1 \
    || fail "the Command Line Tools are missing. Install them with: xcode-select --install"
SWIFT_VERSION="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
[[ -n "$SWIFT_VERSION" ]] || fail "swift not found. Install the Command Line Tools: xcode-select --install"
at_least "$SWIFT_VERSION" 6.2 \
    || fail "Swift $SWIFT_VERSION is too old; Tint needs Swift 6.2+. Update the Command Line Tools in Software Update."
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
at_least "${SDK_VERSION:-0}" 26.0 \
    || fail "the macOS ${SDK_VERSION:-?} SDK is too old; Tint needs the macOS 26 SDK. Update the Command Line Tools."
command -v cargo >/dev/null \
    || fail "cargo not found. Install Rust with rustup (https://rustup.rs), then open a new terminal."
command -v rustup >/dev/null \
    || echo "note: cargo isn't from rustup, so core/rust-toolchain.toml (the pinned Rust version) is ignored."
HOST_VERSION="$(sw_vers -productVersion)"
at_least "$HOST_VERSION" 26.0 || echo "note: this Mac runs macOS $HOST_VERSION; Tint itself needs macOS 26 to run."
printf 'Swift %s, macOS SDK %s, %s\n' "$SWIFT_VERSION" "$SDK_VERSION" "$(cd "$ROOT/core" && cargo --version)"

CLIENT_ID="$(setting FLOE_SPOTIFY_CLIENT_ID .spotify-client-id)"
if [[ -n "$CLIENT_ID" && ! "$CLIENT_ID" =~ ^[0-9a-f]{32}$ ]]; then
    fail "the Spotify client ID \"$CLIENT_ID\" isn't 32 lowercase hex characters (FLOE_SPOTIFY_CLIENT_ID or .spotify-client-id)."
fi

SIGN_IDENTITY="$(setting FLOE_SIGN_IDENTITY .signing-identity)"
if [[ $PUBLIC == 1 ]]; then
    # This Mac's own client ID and certificate stay out of a copy made for others.
    CLIENT_ID=""
    SIGN_IDENTITY=""
fi
# Self-signed certificates count too, though macOS calls them untrusted (no -v).
has_identity() { security find-identity -p codesigning 2>/dev/null | grep -qF -e "\"$1\"" -e " $1 "; }
if [[ -n "${FLOE_DEVELOPER_ID:-}" ]] && ! has_identity "$FLOE_DEVELOPER_ID"; then
    fail "no \"$FLOE_DEVELOPER_ID\" certificate in the keychain (FLOE_DEVELOPER_ID)."
fi

step "Rust core (cargo build --release)"
# Run from core/ so rustup picks up core/rust-toolchain.toml.
(cd "$ROOT/core" && cargo build --release)

step "Swift app (swift build -c $CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product "$PRODUCT"
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
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Support/Localizations/"*.lproj "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
if [[ -n "${FLOE_BUNDLE_ID:-}" ]]; then
    # Another bundle ID starts with fresh settings; saved logins are shared (see docs/REFERENCE.md).
    plutil -replace CFBundleIdentifier -string "$FLOE_BUNDLE_ID" "$PLIST"
fi
if [[ $PUBLIC == 1 ]]; then
    # Only these copies update themselves: one built for this Mac would be replaced
    # by the public build, without its client ID and with another signature.
    plutil -replace FloeUpdates -bool YES "$PLIST"
    echo "Updates: on (from GitHub's releases)"
fi
if [[ -n "$CLIENT_ID" ]]; then
    plutil -replace FloeSpotifyClientID -string "$CLIENT_ID" "$PLIST"
    echo "Spotify client ID: ${CLIENT_ID:0:6}… (built in)"
else
    echo "Spotify client ID: none built in; Tint asks for one on first launch"
fi

# Ad-hoc signatures change on every build. Tint keeps its logins in files, not the
# Keychain, so that only matters for macOS privacy prompts; a stable certificate
# keeps those answered across rebuilds.
if [[ -n "${FLOE_DEVELOPER_ID:-}" ]]; then
    step "Sign (Developer ID: $FLOE_DEVELOPER_ID, hardened runtime)"
    codesign --force --sign "$FLOE_DEVELOPER_ID" --options runtime --timestamp "$APP"
elif [[ -n "$SIGN_IDENTITY" ]] && has_identity "$SIGN_IDENTITY"; then
    step "Sign ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
else
    if [[ -n "$SIGN_IDENTITY" ]]; then
        step "Sign (ad-hoc: no \"$SIGN_IDENTITY\" certificate in the keychain)"
    else
        step "Sign (ad-hoc: no certificate configured, see docs/REFERENCE.md: Signing)"
    fi
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

printf '\nBuilt %s (%s, %s)\n' "$APP" "$CONFIG" "$(du -sh "$APP" | cut -f1)"
if [[ $ZIP == 1 ]]; then
    "$ROOT/scripts/package-app.sh"
fi
if [[ $INSTALL == 1 ]]; then
    "$ROOT/scripts/install-app.sh"
    APP="$HOME/Applications/$APP_NAME.app"
fi
if [[ $OPEN == 1 ]]; then open "$APP"; fi
