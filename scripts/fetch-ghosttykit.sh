#!/usr/bin/env bash
# Download a prebuilt GhosttyKit.xcframework (libghostty) and keep only the
# macOS slice. The binary comes from the manaflow-ai/ghostty fork, which is
# what cmux ships. Pinned by ghostty commit + sha256.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_SHA="${GHOSTTY_SHA:-e168fd31c0fc5893cdac933dc665307b3a760554}"
EXPECTED_SHA256="${GHOSTTYKIT_SHA256:-66d0089dcb7ea8873d86553e684e9b746d39c33318fa5c663a84e7fec68b098f}"
FLAVOR="crashsubdir-cmux-crash-sentry-off-noi18n-v2"
URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-${GHOSTTY_SHA}-${FLAVOR}/GhosttyKit.xcframework.tar.gz"
OUT="$ROOT/vendor/GhosttyKit.xcframework"
STAMP="$OUT/.ghostty-sha"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$GHOSTTY_SHA" ]]; then
  echo "GhosttyKit $GHOSTTY_SHA already present"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="${GHOSTTYKIT_ARCHIVE:-$TMP/gk.tar.gz}"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading GhosttyKit for ghostty $GHOSTTY_SHA"
  curl -fL --retry 5 -o "$ARCHIVE" "$URL"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED_SHA256" ]]; then
  echo "checksum mismatch: expected $EXPECTED_SHA256 got $ACTUAL" >&2
  exit 1
fi

tar --no-same-owner -xzf "$ARCHIVE" -C "$TMP"
SRC="$TMP/GhosttyKit.xcframework"
rm -rf "$OUT"
mkdir -p "$OUT/macos-arm64_x86_64"
cp -R "$SRC/macos-arm64_x86_64/Headers" "$OUT/macos-arm64_x86_64/Headers"
# SwiftPM wants the conventional lib*.a name.
cp "$SRC/macos-arm64_x86_64/ghostty-internal.a" "$OUT/macos-arm64_x86_64/libghostty.a"
cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>BinaryPath</key><string>libghostty.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>macos-arm64_x86_64</string>
      <key>LibraryPath</key><string>libghostty.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
      <key>SupportedPlatform</key><string>macos</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST
echo "$GHOSTTY_SHA" > "$STAMP"
echo "GhosttyKit ready at $OUT"
