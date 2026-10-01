#!/bin/bash
# Usage: run.sh <App.app> <entry-url-regex> [extra app args...]
APP="$1"; ENTRY="$2"; shift 2
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
INSPECT=$((9300 + RANDOM % 500))
rm -f /tmp/ee/hook.log
"$BIN" --inspect-brk=$INSPECT "$@" >/tmp/ee/app.out 2>&1 &
echo "pid $!"
node --experimental-websocket /tmp/ee/inject.mjs $INSPECT /tmp/ee/hook.cjs "$ENTRY" 2>&1 | grep -E "inject|paused"
