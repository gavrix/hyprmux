#!/usr/bin/env bash
# Smoke test for the QML host (docs/QML.md, docs/PLUGINS.md): starts a throwaway
# Hyprmux instance with the built-in sysload plugin, the demo QML file, and the Notes
# example .hmapp, checks they come up, that a killed plugin restarts, and cleans up.
#
#   HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh   # once, a test copy with the host
#   scripts/qml-smoke.sh [APP]                           # default: $HYPRMUX_APP or /tmp/HyprmuxTest.app
#
# Needs the broker loaded (it is when your own Hyprmux runs). Leaves your instance
# alone: its own instance name, socket, config, and session.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-${HYPRMUX_APP:-/tmp/HyprmuxTest.app}}"
CTL="$APP/Contents/MacOS/hyprmuxctl"
HOST="$APP/Contents/MacOS/hyprmux-qml"
[[ -x "$CTL" ]] || { echo "no Hyprmux at $APP (build one with HYPRMUX_APP=$APP scripts/bundle.sh)" >&2; exit 2; }
[[ -x "$HOST" ]] || { echo "$APP has no QML host: was Qt installed when it was built?" >&2; exit 2; }

WORK="$(mktemp -d /tmp/hm-qml-smoke.XXXXXX)"
export HYPRMUX_SOCKET="$WORK/hyprmux.sock"
printf 'plugin = sysload\ninput:follow_mouse = 0\n' > "$WORK/hyprmux.conf"
HYPRMUX_PID=""
cleanup() {
  [[ -n "$HYPRMUX_PID" ]] && kill "$HYPRMUX_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
check() {   # check NAME COMMAND...: retries for up to 10 s
  local name="$1"; shift
  for _ in $(seq 1 40); do
    if "$@" >/dev/null 2>&1; then echo "ok    $name"; return 0; fi
    sleep 0.25
  done
  echo "FAIL  $name"; failures=$((failures + 1)); return 1
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }

open -g -n \
  --env HYPRMUX_INSTANCE=qml-smoke \
  --env HYPRMUX_SOCKET="$HYPRMUX_SOCKET" \
  --env HYPRMUX_CONFIG="$WORK/hyprmux.conf" \
  --env HYPRMUX_CHROMIUM_PROFILE="$WORK/chromium" \
  --env HYPRMUX_SESSION="$WORK/session.json" \
  "$APP"

check "Hyprmux answers" "$CTL" surfaces
plugin_running() { "$CTL" plugins | json "any(p['state'] == 'running' and p.get('id') == 'dev.gavrix.sysload' for p in d['plugins'])"; }
check "sysload runs" plugin_running
PLUGIN_PID="$("$CTL" plugins | python3 -c "import json,sys; print(json.load(sys.stdin)['plugins'][0].get('pid', ''))")"
HYPRMUX_PID="$(ps -o ppid= -p "$PLUGIN_PID" | tr -d ' ')"
bar_item() { "$CTL" debug | json "len(d['bar'].get('items', [])) >= 1"; }
check "its bar item shows" bar_item

"$CTL" new-surface --type app --workspace empty -- "$HOST" "$ROOT/clients/qml/examples/demo.qml" >/dev/null \
  || echo "      (new-surface: the app's tile didn't open; its frame check fails next)"
app_drew() { "$CTL" surfaces | json "any(s.get('app') == 'dev.gavrix.hyprmux.qml.demo' and s.get('framesShown', 0) >= 1 for s in d)"; }
check "the demo app draws a frame" app_drew

# A QML .hmapp (kind qml) from the launcher: the Notes example.
mkdir -p "$WORK/apps"
cp -R "$ROOT/clients/qml/examples/Notes.hmapp" "$WORK/apps/"
"$CTL" apps refresh >/dev/null
"$CTL" launch Notes >/dev/null || echo "      (launch: Notes didn't open; its check fails next)"
notes_drew() { "$CTL" surfaces | json "any(s.get('title') == 'Notes' and s.get('framesShown', 0) >= 1 for s in d)"; }
check "a QML .hmapp launches and draws" notes_drew

kill -9 "$PLUGIN_PID"
restarted() { "$CTL" plugins | json "d['plugins'][0]['state'] == 'running' and d['plugins'][0]['restarts'] >= 1 and d['plugins'][0]['pid'] != $PLUGIN_PID"; }
check "a killed plugin restarts" restarted
check "its bar item comes back" bar_item

if [[ "$failures" -gt 0 ]]; then
  echo "$failures failed. Plugin log: ~/Library/Logs/Hyprmux/plugins/qml-smoke/dev.gavrix.sysload.log" >&2
  exit 1
fi
echo "all passed"
