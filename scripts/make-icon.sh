#!/usr/bin/env bash
# Renders Resources/AppIcon/*.svg into Resources/AppIcon.icns.
# Needs rsvg-convert (brew install librsvg). Run it after you edit the SVGs,
# and commit the .icns so bundle.sh doesn't need librsvg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon"
OUT="$ROOT/Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

render() { # svg, pixel size, file name
  rsvg-convert -w "$2" -h "$2" "$SRC/$1" -o "$SET/$3"
}

# The 16 and 32 px slots use the simplified artwork; everything larger uses the full one.
render AppIcon-small.svg 16   icon_16x16.png
render AppIcon-small.svg 32   icon_16x16@2x.png
render AppIcon-small.svg 32   icon_32x32.png
render AppIcon.svg       64   icon_32x32@2x.png
render AppIcon.svg       128  icon_128x128.png
render AppIcon.svg       256  icon_128x128@2x.png
render AppIcon.svg       256  icon_256x256.png
render AppIcon.svg       512  icon_256x256@2x.png
render AppIcon.svg       512  icon_512x512.png
render AppIcon.svg       1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "wrote $OUT"
