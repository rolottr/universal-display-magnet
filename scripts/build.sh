#!/bin/zsh
# Builds Universal Display Magnet.app with SwiftPM.
#   scripts/build.sh                 release build into build/Universal Display Magnet.app
#   CONFIG=debug scripts/build.sh
#   ARCHS=arm64 scripts/build.sh     one architecture (default: universal, arm64 and x86_64)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                                    Developer ID signature for releases (default: ad-hoc)
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-release}
ARCHS=(${=ARCHS:-arm64 x86_64})
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
# One build per architecture, joined with lipo: SwiftPM's multi-arch build
# needs Xcode's build system on older toolchains. Each binary is copied out
# right away, since newer toolchains reuse one output folder for every arch.
SLICES="$ROOT/build/slices"
rm -rf "$SLICES"
mkdir -p "$SLICES"
for arch in $ARCHS; do
  echo "==> swift build ($CONFIG, $arch) with SDK $SDKROOT"
  swift build -c "$CONFIG" --arch "$arch" --product UniversalDisplayMagnet
  cp "$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/UniversalDisplayMagnet" "$SLICES/$arch"
done

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$SLICES"/* -output "$APP/Contents/MacOS/UniversalDisplayMagnet"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

echo "==> Translations"
for catalog in "$ROOT"/Resources/*.xcstrings; do
  swift "$ROOT/scripts/strings.swift" compile "$catalog" "$APP/Contents/Resources"
done

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
