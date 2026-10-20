#!/bin/zsh
# Build and package the app for one architecture (default: this Mac's).
#   ARCH=x86_64 scripts/package.sh
set -euo pipefail

ROOT=${0:A:h:h}
ARCH=${ARCH:-$(uname -m)}
CONFIG=release ARCH="$ARCH" "$ROOT/scripts/build.sh"
ARCHIVE="Universal-Display-Magnet-macos-$ARCH.zip"
cd "$ROOT/build"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "Universal Display Magnet.app" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "==> Packaged $ROOT/build/$ARCHIVE"
