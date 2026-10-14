#!/usr/bin/env bash
# Renders scripts/site/og.html to site/media/og.png (1200×630) with headless Chrome.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
  --force-device-scale-factor=1 --window-size=1200,630 --virtual-time-budget=2000 \
  --screenshot="$TMP/og.png" "file://$ROOT/scripts/site/og.html" >/dev/null 2>&1
magick "$TMP/og.png" -strip -define png:compression-level=9 "$ROOT/site/media/og.png" 2>/dev/null \
  || cp "$TMP/og.png" "$ROOT/site/media/og.png"
echo "wrote site/media/og.png"
