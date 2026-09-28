#!/usr/bin/env bash
# Records the README demo: builds a separate copy of Hyprmux, launches it with the demo
# config and a clean shell, plays scenario.sh, and records only its window.
#
#   scripts/demo/record.sh            # -> docs/media/demo.mp4 and docs/media/demo.gif
#   scripts/demo/record.sh --rehearse # play the scenario without recording, and leave the
#                                     # instance open (quit it with ⇧⌘M)
#
# Needs Screen Recording permission for the terminal app you run it from. Don't touch the
# keyboard while it plays: pickers need the demo window in front to take keys.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="$ROOT/scripts/demo"
WORK="/tmp/hyprmux-demo"
APP="$WORK/Hyprmux.app"
SOCK="$WORK/hyprmux.sock"
SIZE="${HYPRMUX_DEMO_SIZE:-1440x900}"
CTL="$ROOT/.build/debug/hyprmuxctl"
REHEARSE=0
[[ "${1:-}" == "--rehearse" ]] && REHEARSE=1

frontmost="$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null || true)"
cleanup() {
  [[ -n "${RECORDER_PID:-}" ]] && kill -INT "$RECORDER_PID" 2>/dev/null || true
  [[ $REHEARSE == 1 ]] || HYPRMUX_SOCKET="$SOCK" "$CTL" dispatch exit >/dev/null 2>&1 || true
  # Give the keyboard back to whatever was in front before.
  [[ -n "$frontmost" ]] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $frontmost) to true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "building…"
HYPRMUX_APP="$APP" "$ROOT/scripts/bundle.sh" >/dev/null
swift build --product hyprmuxctl >/dev/null
CTL="$(swift build --show-bin-path)/hyprmuxctl"
mkdir -p "$ROOT/.build/demo"
swiftc -O "$DEMO/recorder.swift" -o "$ROOT/.build/demo/recorder" 2>/dev/null

# A small fake project for the terminals to show.
rm -rf "$WORK/project" "$WORK/session.json"
mkdir -p "$WORK/project/Sources" "$WORK/project/docs"
printf '# Notes\n\n- [x] tile terminals, web pages, and simulators\n- [x] name workspaces\n- [ ] ship it\n' > "$WORK/project/todo.md"
printf 'print("hello")\n' > "$WORK/project/Sources/main.swift"
printf '# Project\n' > "$WORK/project/README.md"
( cd "$WORK/project" && git init -q && git add -A && git -c user.name=demo -c user.email=demo@example.com commit -qm "Start the project" \
  && printf '\n' >> README.md && git -c user.name=demo -c user.email=demo@example.com commit -qam "Add notes" )

rm -f "$SOCK"
open -n \
  --env HYPRMUX_SOCKET="$SOCK" \
  --env HYPRMUX_CONFIG="$DEMO/hyprmux.conf" \
  --env HYPRMUX_SESSION="$WORK/session.json" \
  --env HYPRMUX_CHROMIUM_PROFILE="$WORK/chromium" \
  --env HYPRMUX_WINDOW_SIZE="$SIZE" \
  --env HYPRMUX_DEMO_DIR="$DEMO" \
  --env ZDOTDIR="$DEMO/zsh" \
  "$APP"
for _ in $(seq 50); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
PID="$(pgrep -f "$APP/Contents/MacOS/Hyprmux" | head -1)"
[[ -n "$PID" ]] || { echo "Hyprmux didn't start" >&2; exit 1; }
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
sleep 1.5

if [[ $REHEARSE == 0 ]]; then
  "$ROOT/.build/demo/recorder" --pid "$PID" --out "$WORK/raw.mp4" &
  RECORDER_PID=$!
  sleep 1
fi
CTL="$CTL" HYPRMUX_SOCKET="$SOCK" HYPRMUX_DEMO_DIR="$DEMO" "$DEMO/scenario.sh"
[[ $REHEARSE == 1 ]] && exit 0

kill -INT "$RECORDER_PID"
wait "$RECORDER_PID" || true
unset RECORDER_PID

mkdir -p "$ROOT/docs/media"
echo "encoding…"
# MP4 for the release page; GIF for the README (GitHub doesn't play videos from the repo).
ffmpeg -loglevel error -y -i "$WORK/raw.mp4" -vf "scale=1440:-2" -c:v libx264 -crf 24 -preset slow \
  -pix_fmt yuv420p -movflags +faststart "$ROOT/docs/media/demo.mp4"
ffmpeg -loglevel error -y -i "$WORK/raw.mp4" -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  "$ROOT/docs/media/demo.gif"
ls -lh "$ROOT/docs/media/demo.mp4" "$ROOT/docs/media/demo.gif"
