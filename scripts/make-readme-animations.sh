#!/bin/zsh
# Render the README animations (.github/assets/*.webp) from the app itself,
# with scripted demo data: no personal data, nothing on this Mac is touched.
# Needs img2webp (brew install webp).
set -euo pipefail

ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"

swift build --product UniversalDisplayMagnet
BIN=$(swift build --show-bin-path)/UniversalDisplayMagnet
mkdir -p "$WORK/data" "$ROOT/.github/assets"
echo "==> Rendering frames"
UDM_DATA_DIR="$WORK/data" UDM_DEVICE_NAME="Mac Studio" "$BIN" --demo-frames "$WORK/frames"

for name in showcase menubar; do
  frames=("$WORK/frames/$name"/frame-*.png)
  echo "==> $name.webp (${#frames} frames at 15 fps)"
  args=()
  for i in {1..${#frames}}; do
    # 15 fps: alternate 67/66 ms so the total stays exact.
    args+=(-d $(( (i * 1000 + 7) / 15 - ((i - 1) * 1000 + 7) / 15 )) "${frames[$i]}")
  done
  img2webp -loop 0 -lossy -q 82 -m 4 "${args[@]}" -o "$ROOT/.github/assets/$name.webp" >/dev/null
  ls -lh "$ROOT/.github/assets/$name.webp" | awk '{print "    " $5}'
done
