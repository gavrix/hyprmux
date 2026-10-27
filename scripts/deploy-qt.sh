#!/usr/bin/env bash
# Copies the Qt the QML host needs into Hyprmux.app, so plugins and QML apps run on
# Macs without Qt (docs/PLUGINS.md). Called by scripts/bundle.sh after it copies
# hyprmux-qml into the app:
#
#   scripts/deploy-qt.sh APP QT_PREFIX
#
# Layout, as Qt documents for macOS bundles:
#   Contents/Frameworks/Qt*.framework     what the host and plugins link, arm64, no headers
#   Contents/PlugIns/platforms, tls, ...  Qt's plugins
#   Contents/PlugIns/quick/*.dylib        QML modules' plugins (code stays out of Resources)
#   Contents/Resources/qml/<module>/      their qmldir and type info, pointing at PlugIns/quick
#   Contents/Resources/qt.conf            where the host's Qt finds all that
# Frameworks are the closure of what these link, found with otool, not a fixed list.
set -euo pipefail

APP="$1"
QT="$2"
HOST="$APP/Contents/MacOS/hyprmux-qml"
FW="$APP/Contents/Frameworks"
PI="$APP/Contents/PlugIns"
QML_OUT="$APP/Contents/Resources/qml"

# QML modules a plugin or app may import. Only the Basic controls style: the default
# style is chosen in the host, and other styles would add tens of MB.
QML_MODULES=(
  QtQml QtQml/Models QtQml/WorkerScript QtCore
  QtQuick QtQuick/Window QtQuick/Shapes QtQuick/Layouts QtQuick/Effects QtQuick/Templates
  QtQuick/Controls QtQuick/Controls/impl QtQuick/Controls/Basic QtQuick/Controls/Basic/impl
)
# Qt plugins: the platform, TLS for HTTPS from QML, and image formats beyond PNG.
QT_PLUGINS=(
  platforms/libqcocoa.dylib
  tls/libqsecuretransportbackend.dylib
  imageformats/libqsvg.dylib imageformats/libqjpeg.dylib imageformats/libqgif.dylib
  iconengines/libqsvgicon.dylib
)

[[ -x "$HOST" ]] || { echo "deploy-qt: no host at $HOST" >&2; exit 1; }
rm -rf "$QML_OUT" "$PI/quick" "$APP/Contents/Resources/qt.conf"
for p in "${QT_PLUGINS[@]}"; do rm -rf "$PI/$(dirname "$p")"; done
find "$FW" -maxdepth 1 -name 'Qt*.framework' -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$FW" "$PI/quick" "$QML_OUT"

thin() { # arm64 only: the archives are universal
  if lipo -info "$1" 2>/dev/null | grep -q x86_64; then lipo "$1" -thin arm64 -output "$1.arm64" && mv "$1.arm64" "$1"; fi
}

# Copied binaries look for Qt next to themselves in the bundle.
add_rpath() { install_name_tool -add_rpath "$2" "$1" 2>/dev/null || true; }

machos=("$HOST")

for p in "${QT_PLUGINS[@]}"; do
  [[ -f "$QT/plugins/$p" ]] || continue
  mkdir -p "$PI/$(dirname "$p")"
  cp "$QT/plugins/$p" "$PI/$p"
  thin "$PI/$p"
  add_rpath "$PI/$p" "@loader_path/../../Frameworks"
  machos+=("$PI/$p")
done

for m in "${QML_MODULES[@]}"; do
  src="$QT/qml/$m"
  [[ -f "$src/qmldir" ]] || { echo "deploy-qt: no QML module $m" >&2; exit 1; }
  mkdir -p "$QML_OUT/$m"
  # Files at this level only: subfolders are other modules, copied if listed.
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    if [[ "$name" == *.dylib ]]; then
      cp "$f" "$PI/quick/$name"
      thin "$PI/quick/$name"
      add_rpath "$PI/quick/$name" "@loader_path/../../Frameworks"
      machos+=("$PI/quick/$name")
    elif [[ "$name" != *.prl && "$name" != *.a ]]; then
      cp "$f" "$QML_OUT/$m/$name"
    fi
  done < <(find "$src" -maxdepth 1 -type f -print0)
  # `plugin NAME` resolves next to the qmldir; give it the path to PlugIns/quick.
  depth="$(awk -F/ '{print NF}' <<<"$m")"
  up="$(printf '../%.0s' $(seq 1 $((depth + 2))))"
  sed -E -i '' "s#^((optional )?plugin [A-Za-z0-9_]+)\$#\\1 ${up}PlugIns/quick#" "$QML_OUT/$m/qmldir"
done

# Frameworks: everything @rpath/Qt*.framework these link, and what those link.
copied=" "
i=0
while [[ $i -lt ${#machos[@]} ]]; do
  bin="${machos[$i]}"
  i=$((i + 1))
  while read -r fwname; do
    [[ "$copied" == *" $fwname "* ]] && continue
    copied+="$fwname "
    [[ -d "$QT/lib/$fwname.framework" ]] || { echo "deploy-qt: $bin links $fwname, not in $QT/lib" >&2; exit 1; }
    rsync -a --exclude 'Headers' --exclude '*.prl' "$QT/lib/$fwname.framework" "$FW/"
    thin "$FW/$fwname.framework/Versions/A/$fwname"
    machos+=("$FW/$fwname.framework/Versions/A/$fwname")
  done < <(otool -L "$bin" | awk '{print $1}' | sed -nE 's#^@rpath/(Qt[A-Za-z0-9]+)\.framework/.*#\1#p' | sort -u)
done

# The host: built against vendor/qt, it finds the bundle's Qt instead.
while read -r rp; do
  install_name_tool -delete_rpath "$rp" "$HOST"
done < <(otool -l "$HOST" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -v '^@')
add_rpath "$HOST" "@executable_path/../Frameworks"

cat > "$APP/Contents/Resources/qt.conf" <<'CONF'
[Paths]
Plugins = PlugIns
QmlImports = Resources/qml
CONF

size="$(du -sck "$FW"/Qt*.framework "$PI" "$QML_OUT" | tail -1 | awk '{printf "%.0f MB", $1 / 1024}')"
echo "deploy-qt: $(wc -w <<<"$copied" | tr -d ' ') frameworks, $(find "$PI" -name '*.dylib' | wc -l | tr -d ' ') plugins, $size" >&2
