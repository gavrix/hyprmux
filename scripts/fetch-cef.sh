#!/usr/bin/env bash
# Download the CEF (Chromium Embedded Framework) minimal SDK for macOS arm64,
# pinned by version and sha1, into vendor/cef:
#   vendor/cef/include                         C/C++ headers
#   vendor/cef/libcef_dll                      C++ wrapper sources (built by SwiftPM)
#   vendor/cef/Release/Chromium Embedded Framework.framework
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF_VERSION="${CEF_VERSION:-154.0.28+g564dd6c+chromium-154.0.8037.58}"
CEF_SHA1="${CEF_SHA1:-f7c50c2719deb8aa0c78de517c1228d0b8c3fced}"
NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
OUT="$ROOT/vendor/cef"
STAMP="$OUT/.cef-version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$CEF_VERSION" ]]; then
  echo "CEF $CEF_VERSION already present"
  exit 0
fi

CACHE="$ROOT/.cache"
mkdir -p "$CACHE"
ARCHIVE="$CACHE/$NAME.tar.bz2"
if [[ ! -f "$ARCHIVE" ]] || ! echo "$CEF_SHA1  $ARCHIVE" | shasum -a 1 -c - >/dev/null 2>&1; then
  URL="https://cef-builds.spotifycdn.com/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME.tar.bz2")"
  echo "Downloading $NAME"
  curl -fL --retry 5 -o "$ARCHIVE" "$URL"
fi
echo "$CEF_SHA1  $ARCHIVE" | shasum -a 1 -c - >/dev/null || { echo "CEF checksum mismatch" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xjf "$ARCHIVE" -C "$TMP"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$TMP/$NAME/include" "$OUT/include"
cp -R "$TMP/$NAME/libcef_dll" "$OUT/libcef_dll"
mkdir -p "$OUT/Release"
cp -R "$TMP/$NAME/Release/Chromium Embedded Framework.framework" "$OUT/Release/"
cp "$TMP/$NAME/LICENSE.txt" "$OUT/LICENSE.txt"
# SwiftPM needs a public-headers dir for the wrapper target. Keep CEF's own
# include/ out of it so Clang never tries to build CEF headers as a module.
mkdir -p "$OUT/swiftpm-public"
echo "// CEF wrapper: include headers as \"include/cef_*.h\"." > "$OUT/swiftpm-public/cefwrapper.h"
echo "$CEF_VERSION" > "$STAMP"
echo "CEF ready at $OUT"
