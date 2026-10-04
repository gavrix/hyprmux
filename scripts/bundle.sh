#!/usr/bin/env bash
# Build Hyprmux and assemble build/Hyprmux.app.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
cd "$ROOT"

"$ROOT/scripts/fetch-ghosttykit.sh" >/dev/null
# SwiftPM needs the CEF SDK present to build (the engine itself is chosen at runtime).
"$ROOT/scripts/fetch-cef.sh" >/dev/null
"$ROOT/scripts/gen-default-config.sh" >/dev/null

# Signing identity, first found: HYPRMUX_SIGN_IDENTITY; the first line of .sign-identity
# (untracked; e.g. your Apple Development certificate's name); "Hyprmux Local Signing"
# when it exists (scripts/make-signing-cert.sh); else ad hoc. A stable identity keeps macOS
# privacy permissions (Screen Recording, ...) across rebuilds; an ad-hoc signature loses them.
SIGN="${HYPRMUX_SIGN_IDENTITY:-}"
if [[ -z "$SIGN" && -f "$ROOT/.sign-identity" ]]; then
  SIGN="$(head -n 1 "$ROOT/.sign-identity" | tr -d '\r')"
fi
if [[ -z "$SIGN" ]]; then
  if security find-certificate -c "Hyprmux Local Signing" >/dev/null 2>&1; then
    SIGN="Hyprmux Local Signing"
  else
    SIGN="-"
  fi
fi
sign() {
  codesign --force --sign "$SIGN" "$1" >/dev/null 2>&1 && return
  echo "warning: signing $(basename "$1") with '$SIGN' failed; signing ad hoc" >&2
  codesign --force --sign - "$1" >/dev/null 2>&1 || true
}

swift build -c "$CONFIG" --product Hyprmux
swift build -c "$CONFIG" --product hyprmuxctl
swift build -c "$CONFIG" --product hyprmux-tour
swift build -c "$CONFIG" --product hyprmux-broker
swift build -c "$CONFIG" --product hyprmux-electron-bridge
swift build -c "$CONFIG" --product hyprmux-credential-1password
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Hyprmux"
CTL_BIN="$BIN_DIR/hyprmuxctl"
TOUR_BIN="$BIN_DIR/hyprmux-tour"
BROKER_BIN="$BIN_DIR/hyprmux-broker"
EBRIDGE_BIN="$BIN_DIR/hyprmux-electron-bridge"
CREDENTIAL_1PASSWORD_BIN="$BIN_DIR/hyprmux-credential-1password"

# HYPRMUX_APP builds the bundle somewhere else (test copies, demo recordings).
APP="${HYPRMUX_APP:-$ROOT/build/Hyprmux.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hyprmux"
cp "$CTL_BIN" "$APP/Contents/MacOS/hyprmuxctl"
# The interactive tour (docs/TOUR.md); terminals find it on PATH next to hyprmuxctl.
cp "$TOUR_BIN" "$APP/Contents/MacOS/hyprmux-tour"
# Client-protocol broker and its launchd job (docs/CLIENT_PROTOCOL.md, section 3).
cp "$BROKER_BIN" "$APP/Contents/MacOS/hyprmux-broker"
cp "$EBRIDGE_BIN" "$APP/Contents/MacOS/hyprmux-electron-bridge"
cp "$CREDENTIAL_1PASSWORD_BIN" "$APP/Contents/MacOS/hyprmux-credential-1password"
cp "$ROOT/Resources/electron-hook.js" "$APP/Contents/Resources/electron-hook.js"
rm -rf "$APP/Contents/Resources/adapters"
cp -R "$ROOT/Resources/adapters" "$APP/Contents/Resources/adapters"
# Built-in hooks (docs/HOOKS.md): the tour's first-launch offer.
rm -rf "$APP/Contents/Resources/hooks"
cp -R "$ROOT/Resources/hooks" "$APP/Contents/Resources/hooks"
rm -rf "$APP/Contents/Resources/credential-providers"
cp -R "$ROOT/Resources/credential-providers" "$APP/Contents/Resources/credential-providers"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/Resources/LaunchAgents/dev.gavrix.hyprmux.broker.plist" "$APP/Contents/Library/LaunchAgents/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# App icon, rendered from Resources/AppIcon/AppIcon.png by scripts/make-icon.sh.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SKILL="$ROOT/.agents/skills/hyprmuxctl"
if [[ ! -f "$SKILL/SKILL.md" ]]; then
  echo "error: missing bundled agent skill: $SKILL/SKILL.md" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/skills"
cp -R "$SKILL" "$APP/Contents/Resources/skills/hyprmuxctl"

# libghostty resources are checked in so building Hyprmux does not require an
# installed Ghostty or cmux app. Keep these paths aligned with what libghostty
# expects below GHOSTTY_RESOURCES_DIR (set in Sources/Hyprmux/main.swift).
for required in \
  "$ROOT/Resources/terminfo/78/xterm-ghostty" \
  "$ROOT/Resources/ghostty/shell-integration" \
  "$ROOT/Resources/ghostty/themes"; do
  if [[ ! -e "$required" ]]; then
    echo "error: missing bundled Ghostty resource: $required" >&2
    exit 1
  fi
done
cp -R "$ROOT/Resources/terminfo" "$APP/Contents/Resources/terminfo"
cp -R "$ROOT/Resources/ghostty" "$APP/Contents/Resources/ghostty"
cp -R "$ROOT/Resources/ThirdPartyLicenses" "$APP/Contents/Resources/ThirdPartyLicenses"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/ThirdPartyLicenses/"

# Chromium (CEF): framework + helper apps, when the SDK is present (scripts/fetch-cef.sh).
CEF_FW="$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework"
if [[ -d "$CEF_FW" ]]; then
  swift build -c "$CONFIG" --product HyprmuxHelper
  HELPER_BIN="$(swift build -c "$CONFIG" --show-bin-path)/HyprmuxHelper"
  mkdir -p "$APP/Contents/Frameworks"
  # clonefile copy: instant on APFS, no extra disk.
  cp -Rc "$CEF_FW" "$APP/Contents/Frameworks/" 2>/dev/null || cp -R "$CEF_FW" "$APP/Contents/Frameworks/"
  sign "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
  # Chromium looks for "<App> Helper (<Kind>).app" next to the framework.
  for kind in "" " (GPU)" " (Renderer)" " (Alerts)"; do
    name="Hyprmux Helper$kind"
    case "$kind" in
      " (Renderer)") bid="dev.gavrix.hyprmux.helper.renderer" ;;
      " (Alerts)") bid="dev.gavrix.hyprmux.helper.alerts" ;;
      *) bid="dev.gavrix.hyprmux.helper" ;;
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

# A second Mach-O executable inside Contents/MacOS must be signed before the outer bundle.
sign "$APP/Contents/MacOS/hyprmuxctl"
sign "$APP/Contents/MacOS/hyprmux-tour"
sign "$APP/Contents/MacOS/hyprmux-broker"
sign "$APP/Contents/MacOS/hyprmux-electron-bridge"
sign "$APP/Contents/MacOS/hyprmux-credential-1password"
sign "$APP"
if [[ "$SIGN" == "-" ]]; then
  echo "signed ad hoc: permissions reset on every build (see docs/DEVELOPMENT.md, Signing)" >&2
else
  echo "signed with: $SIGN" >&2
fi
echo "$APP"
