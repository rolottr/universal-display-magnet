#!/bin/zsh
# Install Universal Display Magnet.app into /Applications and open it.
#   scripts/install.sh           uses the existing build, or builds if missing
#   scripts/install.sh --build   rebuilds before installing
set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/build/Universal Display Magnet.app"
DEST="/Applications/Universal Display Magnet.app"
if [[ "${1:-}" == "--build" || ! -d "$APP" ]]; then
  "$ROOT/scripts/build.sh"
fi
pkill -f "Universal Display Magnet.app/Contents/MacOS/UniversalDisplayMagnet" 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "==> Installed $DEST"
