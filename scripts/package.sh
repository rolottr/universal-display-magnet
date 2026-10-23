#!/bin/zsh
# Build and package the app: universal (arm64 and x86_64), zipped with a SHA-256 checksum.
#   scripts/package.sh
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> scripts/package.sh
#     signs, notarizes and staples the app before zipping it. The profile is a
#     notarytool keychain profile (xcrun notarytool store-credentials).
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=release "$ROOT/scripts/build.sh"
APP="Universal Display Magnet.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$ROOT/build/$APP/Contents/Info.plist")
ARCHIVE="Universal-Display-Magnet-$VERSION-macos.zip"
cd "$ROOT/build"
rm -f "$ARCHIVE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY" >&2; exit 2; }
  echo "==> Notarizing"
  ditto -c -k --sequesterRsrc --keepParent "$APP" notarize.zip
  xcrun notarytool submit notarize.zip --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "notarize.json" || true
  rm -f notarize.zip
  ID=$(plutil -extract id raw "notarize.json")
  STATUS=$(plutil -extract status raw "notarize.json")
  xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" "notarize-log.json" || true
  echo "    submission $ID: $STATUS (log: build/notarize-log.json)"
  [[ "$STATUS" == Accepted ]] || exit 1
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "==> Packaged $ROOT/build/$ARCHIVE"
