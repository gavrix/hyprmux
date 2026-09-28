#!/usr/bin/env bash
# Records the README demo: builds a separate copy of Hyprmux, launches it with the demo
# config and a clean shell, plays scenario.sh, and records only its window.
#
#   scripts/demo/record.sh            # -> docs/media/demo.mp4 and docs/media/demo.gif
#   scripts/demo/record.sh --rehearse # play the scenario without recording, and leave the
#                                     # instance open (quit it with ⇧⌘M)
#
# The recorder is a small signed app, "Hyprmux Demo Recorder", with its own Screen
# Recording permission: macOS asks for it on the first run (allow it, then run again).
# The demo instance plays in the background: your own windows and keyboard stay yours.
# Pass --front to bring it forward while it plays.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="$ROOT/scripts/demo"
WORK="/tmp/hyprmux-demo"
APP="$WORK/Hyprmux.app"
SOCK="$WORK/hyprmux.sock"
SIZE="${HYPRMUX_DEMO_SIZE:-1440x900}"
CTL="$ROOT/.build/debug/hyprmuxctl"
REHEARSE=0
FRONT=0
for a in "$@"; do
  case "$a" in
    --rehearse) REHEARSE=1 ;;
    --front) FRONT=1 ;;
  esac
done
RECAPP="$ROOT/.build/demo/Hyprmux Demo Recorder.app"
RECBIN="$RECAPP/Contents/MacOS/recorder"

frontmost="$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null || true)"
cleanup() {
  pkill -INT -f "$RECBIN" 2>/dev/null || true
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ $REHEARSE == 1 ]] || HYPRMUX_SOCKET="$SOCK" "$CTL" dispatch exit >/dev/null 2>&1 || true
  # Give the keyboard back to whatever was in front before.
  [[ -n "$frontmost" ]] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $frontmost) to true" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "building…"
HYPRMUX_APP="$APP" "$ROOT/scripts/bundle.sh" >/dev/null
swift build --product hyprmuxctl >/dev/null
CTL="$(swift build --show-bin-path)/hyprmuxctl"
# The recorder, as an app of its own so macOS gives it its own Screen Recording permission.
mkdir -p "$RECAPP/Contents/MacOS"
swiftc -O "$DEMO/recorder.swift" -o "$RECBIN" 2>/dev/null
cat > "$RECAPP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>recorder</string>
  <key>CFBundleIdentifier</key><string>dev.gavrix.hyprmux.demo-recorder</string>
  <key>CFBundleName</key><string>Hyprmux Demo Recorder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
SIGN="${HYPRMUX_SIGN_IDENTITY:-$(head -n 1 "$ROOT/.sign-identity" 2>/dev/null || true)}"
codesign --force --sign "${SIGN:--}" "$RECAPP" >/dev/null 2>&1 || codesign --force --sign - "$RECAPP" >/dev/null

# A small fake project for the terminals to show.
rm -rf "$WORK/project" "$WORK/session.json"
mkdir -p "$WORK/project/Sources" "$WORK/project/docs"
printf '# Notes\n\n- [x] tile terminals, web pages, and simulators\n- [x] name workspaces\n- [ ] ship it\n' > "$WORK/project/todo.md"
printf 'print("hello")\n' > "$WORK/project/Sources/main.swift"
printf '# Project\n' > "$WORK/project/README.md"
( cd "$WORK/project" && git init -q && git add -A && git -c user.name=demo -c user.email=demo@example.com commit -qm "Start the project" \
  && printf '\n' >> README.md && git -c user.name=demo -c user.email=demo@example.com commit -qam "Add notes" )

# The web tile's page, from a local server (a file:// URL would show a local path).
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
cp "$DEMO/page.html" "$WORK/index.html"
( cd "$WORK" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!

rm -f "$SOCK"
open -g -n \
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
[[ $FRONT == 1 ]] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true"
sleep 1.5

if [[ $REHEARSE == 0 ]]; then
  rm -f "$WORK/raw.mp4" "$WORK/recorder.log"
  open -g -n "$RECAPP" --args --pid "$PID" --out "$WORK/raw.mp4" --log "$WORK/recorder.log"
  for _ in $(seq 50); do grep -q "recording\|recorder:" "$WORK/recorder.log" 2>/dev/null && break; sleep 0.1; done
  if ! grep -q "^recording" "$WORK/recorder.log" 2>/dev/null; then
    cat "$WORK/recorder.log" >&2 2>/dev/null || true
    echo "The recorder couldn't start. If macOS asked, allow \"Hyprmux Demo Recorder\" in System Settings →" >&2
    echo "Privacy & Security → Screen & System Audio Recording, then run this again." >&2
    exit 1
  fi
fi
CTL="$CTL" HYPRMUX_SOCKET="$SOCK" HYPRMUX_DEMO_DIR="$DEMO" HYPRMUX_DEMO_PORT="$PORT" "$DEMO/scenario.sh"
[[ $REHEARSE == 1 ]] && exit 0

pkill -INT -f "$RECBIN"
for _ in $(seq 100); do pgrep -f "$RECBIN" >/dev/null || break; sleep 0.1; done

mkdir -p "$ROOT/docs/media"
echo "encoding…"
# MP4 for the release page; GIF for the README (GitHub doesn't play videos from the repo).
ffmpeg -loglevel error -y -i "$WORK/raw.mp4" -vf "scale=1440:-2" -c:v libx264 -crf 24 -preset slow \
  -pix_fmt yuv420p -movflags +faststart "$ROOT/docs/media/demo.mp4"
ffmpeg -loglevel error -y -i "$WORK/raw.mp4" -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  "$ROOT/docs/media/demo.gif"
ls -lh "$ROOT/docs/media/demo.mp4" "$ROOT/docs/media/demo.gif"
