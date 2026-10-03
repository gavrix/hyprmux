#!/usr/bin/env bash
# Renders Resources/AppIcon/AppIcon.png (1024x1024 master) into Resources/AppIcon.icns.
# The master already includes the transparent margin, rounded mask, and drop shadow.
# Run this after you replace the PNG, and commit the .icns so bundle.sh stays simple.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon/AppIcon.png"
OUT="$ROOT/Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

render() { # pixel size, file name
  sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
cp "$SRC"   "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "wrote $OUT"
