#!/bin/bash
# Builds the transport spike, loads the broker as a throwaway LaunchAgent,
# runs a compositor and a client, then unloads everything.
set -euo pipefail
cd "$(dirname "$0")"
OUT=/tmp/hyprmux-spike
LABEL=dev.gavrix.hyprmux.spike.broker
mkdir -p "$OUT"

swiftc -O spike.swift -o "$OUT/spike"
codesign --force --sign - "$OUT/spike"   # ad-hoc, like local Hyprmux builds

cat > "$OUT/$LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$OUT/spike</string><string>broker</string></array>
  <key>MachServices</key><dict><key>dev.gavrix.hyprmux.spike.compositor</key><true/></dict>
  <key>StandardErrorPath</key><string>$OUT/broker.log</string>
</dict></plist>
EOF

cleanup() {
  [ -n "${COMP:-}" ] && kill "$COMP" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
}
trap cleanup EXIT

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$OUT/$LABEL.plist"

echo "--- client before the compositor registers (expect not_running)"
"$OUT/spike" client || true

"$OUT/spike" compositor 2>"$OUT/compositor.log" & COMP=$!
sleep 0.5
echo "--- client"
"$OUT/spike" client
echo "--- compositor log"; cat "$OUT/compositor.log"
echo "--- broker log"; cat "$OUT/broker.log"
