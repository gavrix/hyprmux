#!/usr/bin/env bash
# Build Hypermux and assemble build/Hypermux.app.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
cd "$ROOT"

"$ROOT/scripts/fetch-ghosttykit.sh" >/dev/null
"$ROOT/scripts/gen-default-config.sh" >/dev/null

swift build -c "$CONFIG" --product Hypermux
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Hypermux"

APP="$ROOT/build/Hypermux.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hypermux"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# libghostty resources: terminfo + shell integration + themes. Ghostty finds
# them via Contents/Resources/terminfo/78/xterm-ghostty. Take them from an
# installed Ghostty (or cmux) unless Resources/ already has a copy.
RES_SRC=""
for cand in "$ROOT/Resources" "/Applications/Ghostty.app/Contents/Resources" "/Applications/cmux.app/Contents/Resources"; do
  if [[ -f "$cand/terminfo/78/xterm-ghostty" && -d "$cand/ghostty" ]]; then RES_SRC="$cand"; break; fi
done
if [[ -n "$RES_SRC" ]]; then
  cp -R "$RES_SRC/terminfo" "$APP/Contents/Resources/terminfo"
  mkdir -p "$APP/Contents/Resources/ghostty"
  for d in shell-integration themes; do
    [[ -d "$RES_SRC/ghostty/$d" ]] && cp -R "$RES_SRC/ghostty/$d" "$APP/Contents/Resources/ghostty/$d"
  done
else
  echo "warning: no Ghostty resources found; TERM falls back to xterm-256color" >&2
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
