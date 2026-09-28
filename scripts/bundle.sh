#!/usr/bin/env bash
# Build Hypermux and assemble build/Hypermux.app.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
cd "$ROOT"

"$ROOT/scripts/fetch-ghosttykit.sh" >/dev/null
# SwiftPM needs the CEF SDK present to build (the engine itself is chosen at runtime).
"$ROOT/scripts/fetch-cef.sh" >/dev/null
"$ROOT/scripts/gen-default-config.sh" >/dev/null

# Signing identity, first found: HYPERMUX_SIGN_IDENTITY; the first line of .sign-identity
# (untracked; e.g. your Apple Development certificate's name); "Hypermux Local Signing"
# when it exists (scripts/make-signing-cert.sh); else ad hoc. A stable identity keeps macOS
# privacy permissions (Screen Recording, ...) across rebuilds; an ad-hoc signature loses them.
SIGN="${HYPERMUX_SIGN_IDENTITY:-}"
if [[ -z "$SIGN" && -f "$ROOT/.sign-identity" ]]; then
  SIGN="$(head -n 1 "$ROOT/.sign-identity" | tr -d '\r')"
fi
if [[ -z "$SIGN" ]]; then
  if security find-certificate -c "Hypermux Local Signing" >/dev/null 2>&1; then
    SIGN="Hypermux Local Signing"
  else
    SIGN="-"
  fi
fi
sign() {
  codesign --force --sign "$SIGN" "$1" >/dev/null 2>&1 && return
  echo "warning: signing $(basename "$1") with '$SIGN' failed; signing ad hoc" >&2
  codesign --force --sign - "$1" >/dev/null 2>&1 || true
}

swift build -c "$CONFIG" --product Hypermux
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Hypermux"

APP="$ROOT/build/Hypermux.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hypermux"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# App icon, rendered from Resources/AppIcon/*.svg by scripts/make-icon.sh.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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

# Chromium (CEF): framework + helper apps, when the SDK is present (scripts/fetch-cef.sh).
CEF_FW="$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework"
if [[ -d "$CEF_FW" ]]; then
  swift build -c "$CONFIG" --product HypermuxHelper
  HELPER_BIN="$(swift build -c "$CONFIG" --show-bin-path)/HypermuxHelper"
  mkdir -p "$APP/Contents/Frameworks"
  # clonefile copy: instant on APFS, no extra disk.
  cp -Rc "$CEF_FW" "$APP/Contents/Frameworks/" 2>/dev/null || cp -R "$CEF_FW" "$APP/Contents/Frameworks/"
  sign "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  # Chromium looks for "<App> Helper (<Kind>).app" next to the framework.
  for kind in "" " (GPU)" " (Renderer)" " (Alerts)"; do
    name="Hypermux Helper$kind"
    case "$kind" in
      " (Renderer)") bid="dev.gavrix.hypermux.helper.renderer" ;;
      " (Alerts)") bid="dev.gavrix.hypermux.helper.alerts" ;;
      *) bid="dev.gavrix.hypermux.helper" ;;
    esac
    H="$APP/Contents/Frameworks/$name.app"
    mkdir -p "$H/Contents/MacOS"
    cp "$HELPER_BIN" "$H/Contents/MacOS/$name"
    cat > "$H/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bid</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><string>1</string>
  <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
    sign "$H"
  done
fi

sign "$APP"
if [[ "$SIGN" == "-" ]]; then
  echo "signed ad hoc: permissions reset on every build (see docs/DEVELOPMENT.md, Signing)" >&2
else
  echo "signed with: $SIGN" >&2
fi
echo "$APP"
