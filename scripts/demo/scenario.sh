#!/usr/bin/env bash
# The demo, played through the control socket. record.sh runs it while recording; run it
# alone against any instance to rehearse:  HYPRMUX_SOCKET=... scripts/demo/scenario.sh
# Edit freely: every step is a dispatcher, a key, or text typed into a terminal.
set -euo pipefail
CTL="${CTL:-hyprmuxctl}"

ctl() { "$CTL" "$@" >/dev/null; }
pause() { sleep "${1:-0.8}"; }
# Types into the focused terminal like a person would, then presses Return.
# (The control socket trims each request, so spaces and Return go as keys.)
type_line() {
  local s="$1" i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == " " ]]; then key ", space"; else ctl sendtext "$ch"; fi
    sleep 0.035
  done
  pause 0.25
  key ", Return"
}
key() { ctl sendkey "$@"; }
# Types into a picker's query field (keys, since it isn't a terminal).
type_keys() {
  local s="$1" i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    [[ "$ch" == " " ]] && ch=space
    key ", $ch"
    sleep 0.06
  done
}
# Types an address into a text field, key by key (":" is Shift-semicolon).
type_url() {
  local s="$1" i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      :) key "SHIFT, semicolon" ;;
      /) key ", slash" ;;
      .) key ", period" ;;
      *) key ", $ch" ;;
    esac
    sleep 0.05
  done
}

# Most steps press the real default shortcuts (config/hyprmux.conf), so the keycast
# (hud:keycast, on in the demo config) shows them. Keys reach Hyprmux even when it
# isn't the front app.

# 1. One terminal.
pause 1.2
type_line "hello"
pause 1.5

# 2. More tiles: dwindle splits each new window off the focused one.
key "SUPER, Return"
pause 1
type_line "ls"
pause 1
key "SUPER, B"                      # a web tile, with its address bar focused
pause 1
type_url "localhost:${HYPRMUX_DEMO_PORT:-8765}"
key ", Return"
pause 1.6

# 3. Move around: focus, swap, resize.
key "SUPER, H"
pause 0.7
key "SUPER ALT, L"
pause 1
for _ in 1 2 3 4 5; do key "SUPER CTRL, L"; sleep 0.12; done
pause 0.8
for _ in 1 2 3 4 5; do key "SUPER CTRL, H"; sleep 0.12; done
pause 0.8

# 4. Float a window and put it back.
key "SUPER SHIFT, Space"
pause 1.2
key "SUPER SHIFT, Space"
pause 1

# 5. Tabs: a group, with a new tab in it.
key "SUPER, G"
pause 0.7
key "SUPER, Return"
pause 1
type_line "git log --oneline"
pause 1
key "CTRL SHIFT, Tab"
pause 1

# 6. A named workspace, through the picker.
key "SUPER, P"
pause 0.8
type_keys "notes"
pause 0.6
key ", Return"
pause 1
key "SUPER, Return"
pause 1
type_line "cat todo.md"
pause 1.2

# 7. A notification from a terminal (OSC 9).
type_line "sleep 1; printf '\\e]9;Build finished in 42s\\a'"
pause 2.4

# 8. Back to the first workspace, then the scratchpad.
key "SUPER, 1"
pause 1.2
key "SUPER, S"
pause 0.6
key "SUPER, Return"
pause 1.2
key "SUPER, S"
pause 1.5
