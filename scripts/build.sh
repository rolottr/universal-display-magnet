#!/bin/zsh
# Builds Universal Display Magnet.app with SwiftPM.
#   scripts/build.sh                 release build into build/Universal Display Magnet.app
#   CONFIG=debug scripts/build.sh
#   ARCH=x86_64 scripts/build.sh     another architecture (default: this Mac's)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                                    Developer ID signature for releases (default: ad-hoc)
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
ARCH=${ARCH:-$(uname -m)}
case "$CONFIG" in
  release|debug) ;;
  *) echo "CONFIG must be release or debug" >&2; exit 2 ;;
esac
BUNDLE_ID=dev.rolottr.UniversalDisplayMagnet
APP="$ROOT/build/Universal Display Magnet.app"
cd "$ROOT"
mkdir -p "$ROOT/build"

# Use the selected toolchain without changing global developer settings.
# Universal Display Magnet avoids SwiftUI's @State (a compiler macro on the macOS 27 SDK
# whose plugin ships only with Xcode), so the Command Line Tools build it
# with any SDK. Override with SDKROOT=... if needed.
export SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
echo "==> swift build ($CONFIG, $ARCH) with SDK $SDKROOT"
swift build -c "$CONFIG" --arch "$ARCH" --product UniversalDisplayMagnet
BIN=$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UniversalDisplayMagnet" "$APP/Contents/MacOS/UniversalDisplayMagnet"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

echo "==> App icon"
rm -rf "$ROOT/build/AppIcon.iconset"
swift "$ROOT/scripts/generate-icon.swift" "$ROOT/build/AppIcon.iconset" >/dev/null
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # The default designated requirement (bundle id + team) is stable across
  # updates, and also satisfies permissions granted to the ad-hoc builds.
  # No entitlements: the app isn't sandboxed and needs no runtime exceptions.
  echo "==> Signing with $SIGN_IDENTITY (Hardened Runtime, secure timestamp)"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    --options runtime --timestamp \
    "$APP"
else
  echo "==> Ad-hoc signing (identifier-based designated requirement keeps permissions across updates)"
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

echo "==> Built $APP"
