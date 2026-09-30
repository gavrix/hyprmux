#!/usr/bin/env bash
# Build, Developer ID-sign, package, notarize, and staple a public Hyprmux DMG.
# Usage: scripts/release.sh [version]
# Environment:
#   HYPRMUX_SIGN_IDENTITY     Developer ID Application identity or SHA-1 hash.
#   HYPRMUX_NOTARY_PROFILE    notarytool Keychain profile (default: hyprmux-notary).
#   HYPRMUX_NOTARY_KEYCHAIN   Keychain containing that profile (useful in CI).
#   HYPRMUX_SKIP_NOTARIZATION Set to 1 for a signed local packaging test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Hyprmux.app"
ENTITLEMENTS="$ROOT/Resources/Release.entitlements"
PROFILE="${HYPRMUX_NOTARY_PROFILE:-hyprmux-notary}"
NOTARY_KEYCHAIN="${HYPRMUX_NOTARY_KEYCHAIN:-}"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/Resources/Info.plist"
}

VERSION="${1:-$(plist_value CFBundleShortVersionString)}"
if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "error: version must contain two or three numeric components, for example 0.1.0" >&2
  exit 1
fi

IDENTITY="${HYPRMUX_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')"
  COUNT="$(printf '%s\n' "$IDENTITIES" | awk 'NF { count++ } END { print count + 0 }')"
  if [[ "$COUNT" -ne 1 ]]; then
    echo "error: expected one Developer ID Application identity, found $COUNT" >&2
    echo "set HYPRMUX_SIGN_IDENTITY to select one" >&2
    exit 1
  fi
  IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk 'NF { print; exit }')"
fi
if ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$IDENTITY" | grep -q "Developer ID Application:"; then
  echo "error: '$IDENTITY' is not a valid Developer ID Application identity" >&2
  exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: missing release entitlements: $ENTITLEMENTS" >&2
  exit 1
fi

echo "Building Hyprmux $VERSION"
echo "Signing with: $IDENTITY"
HYPRMUX_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/bundle.sh" release

# The source plist carries the normal development version. A release argument may
# override only the assembled bundle, before its final signature is created.
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

sign_runtime() {
  codesign --force --sign "$IDENTITY" --timestamp --options runtime "$@"
}

CEF="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
if [[ -d "$CEF" ]]; then
  # Nested libraries must be signed before their containing framework.
  while IFS= read -r -d '' library; do
    sign_runtime "$library"
  done < <(find "$CEF" -type f -name '*.dylib' -print0)
  sign_runtime "$CEF"
fi

# All helper variants use one executable. Any variant can host Chromium's V8 JIT.
for helper in "$APP"/Contents/Frameworks/Hyprmux\ Helper*.app; do
  [[ -d "$helper" ]] || continue
  sign_runtime --entitlements "$ENTITLEMENTS" "$helper"
done

sign_runtime "$APP/Contents/MacOS/hyprmuxctl"
sign_runtime --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
if ! codesign -d --verbose=4 "$APP" 2>&1 | grep 'flags=.*runtime' >/dev/null; then
  echo "error: the app signature does not enable the hardened runtime" >&2
  exit 1
fi

ARCHES="$(lipo -archs "$APP/Contents/MacOS/Hyprmux")"
case "$ARCHES" in
  arm64) ARCH_LABEL="arm64" ;;
  "x86_64 arm64"|"arm64 x86_64") ARCH_LABEL="universal" ;;
  *) ARCH_LABEL="${ARCHES// /-}" ;;
esac
DMG="$ROOT/build/Hyprmux-$VERSION-$ARCH_LABEL.dmg"
CHECKSUM="$DMG.sha256"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hyprmux-release.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ditto "$APP" "$STAGE/Hyprmux.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG" "$CHECKSUM"
hdiutil create -quiet -volname "Hyprmux $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if [[ "${HYPRMUX_SKIP_NOTARIZATION:-0}" == "1" ]]; then
  echo "warning: skipping notarization; Gatekeeper will reject this DMG on other Macs" >&2
else
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

(
  cd "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUM")"
)

echo "DMG: $DMG"
echo "SHA-256: $CHECKSUM"
