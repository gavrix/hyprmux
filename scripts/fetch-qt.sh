#!/usr/bin/env bash
# Download Qt for the QML host (docs/PLUGINS.md), pinned by version and sha1, from
# Qt's official package archives into vendor/qt:
#   vendor/qt/lib, bin, libexec, plugins, qml, metatypes, mkspecs, ...
# Only qtbase, qtdeclarative, and qtsvg: what the host builds against and ships.
# The archives are universal (x86_64 + arm64); scripts/deploy-qt.sh thins what
# goes into the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QT_VERSION="${QT_VERSION:-6.12.0}"
QT_BUILD="${QT_BUILD:-0-202609280346}"
# name sha1, per archive: <name>-MacOS-MacOS_26-Clang-MacOS-MacOS_26-X86_64-ARM64.7z
PACKAGES=(
  "qtbase ee000bfb994032853910263fd214b595f8066ee7"
  "qtdeclarative 11dcc3f84c6e8605d9838a8443f9577e581f906c"
  "qtsvg a3dbab2f385c3e5a5dd4767cc3af38d9dff72bf1"
)
DIGITS="${QT_VERSION//./}"
BASE="https://download.qt.io/online/qtsdkrepository/mac_x64/desktop/qt6_$DIGITS/qt6_$DIGITS/qt.qt6.$DIGITS.clang_64"
OUT="$ROOT/vendor/qt"
STAMP="$OUT/.qt-version"
WANT="$QT_VERSION $QT_BUILD"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WANT" ]]; then
  echo "Qt $QT_VERSION already present"
  exit 0
fi

CACHE="$ROOT/.cache/qt"
mkdir -p "$CACHE"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/qt"
for entry in "${PACKAGES[@]}"; do
  read -r name sha <<<"$entry"
  file="$QT_VERSION-$QT_BUILD$name-MacOS-MacOS_26-Clang-MacOS-MacOS_26-X86_64-ARM64.7z"
  archive="$CACHE/$file"
  if [[ ! -f "$archive" ]] || ! echo "$sha  $archive" | shasum -a 1 -c - >/dev/null 2>&1; then
    echo "Downloading Qt $QT_VERSION $name"
    curl -fL --retry 5 -o "$archive" "$BASE/$file"
  fi
  echo "$sha  $archive" | shasum -a 1 -c - >/dev/null || { echo "Qt $name checksum mismatch" >&2; exit 1; }
  # macOS's bsdtar reads 7z archives.
  # Each archive is the install prefix itself; they merge.
  tar -xf "$archive" -C "$TMP/qt"
done

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$TMP/qt" "$OUT"
# The archives come from Qt's online installer, which writes these next: tell the
# tools (qmllint, qmltyperegistrar, ...) where their Qt is, relative to themselves.
for dir in bin libexec; do
  [[ -d "$OUT/$dir" ]] && printf '[Paths]\nPrefix=..\n' > "$OUT/$dir/qt.conf"
done
echo "$WANT" > "$STAMP"
echo "Qt ready at $OUT"
