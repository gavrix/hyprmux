#!/usr/bin/env bash
# Loads or unloads the client-protocol broker with launchctl, for development.
# A shipping app registers it with SMAppService instead (docs/CLIENT_PROTOCOL.md).
# Both use one label, so a loaded dev broker stops Hyprmux from registering its own.
#
# Usage: scripts/dev-broker.sh load [path/to/Hyprmux.app]   (default: build/Hyprmux.app)
#        scripts/dev-broker.sh unload
#        scripts/dev-broker.sh status
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL=dev.gavrix.hyprmux.broker
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/Caches/dev.gavrix.hyprmux/$LABEL.plist"
LOG="$HOME/Library/Logs/hyprmux-broker.log"

case "${1:-}" in
  load)
    APP="$(cd "${2:-$ROOT/build/Hyprmux.app}" && pwd)"
    BROKER="$APP/Contents/MacOS/hyprmux-broker"
    [[ -x "$BROKER" ]] || { echo "error: no broker at $BROKER (run scripts/bundle.sh)" >&2; exit 1; }
    mkdir -p "$(dirname "$PLIST")"
    # The bundled plist uses BundleProgram (relative to the app); launchctl needs an absolute path.
    sed -e "s#<key>BundleProgram</key><string>Contents/MacOS/hyprmux-broker</string>#<key>ProgramArguments</key><array><string>$BROKER</string></array><key>StandardErrorPath</key><string>$LOG</string>#" \
      "$APP/Contents/Library/LaunchAgents/$LABEL.plist" > "$PLIST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "loaded $LABEL from $BROKER (log: $LOG)"
    ;;
  unload)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "unloaded $LABEL" || echo "$LABEL wasn't loaded"
    rm -f "$PLIST"
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state|program|pid" || echo "$LABEL isn't loaded"
    ;;
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
