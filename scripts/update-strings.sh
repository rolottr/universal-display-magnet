#!/bin/zsh
# Syncs Resources/Localizable.xcstrings with the code, like Xcode does on
# build: new strings are added (untranslated), removed ones marked stale.
set -euo pipefail

ROOT=${0:A:h:h}
OUT="$ROOT/build/strings"
cd "$ROOT"
export SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
rm -rf "$OUT"
mkdir -p "$OUT"
swift build --product UniversalDisplayMagnet --scratch-path "$ROOT/build/strings-build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
swift "$ROOT/scripts/strings.swift" extract "$ROOT/Resources/Localizable.xcstrings" "$OUT"/*.stringsdata
