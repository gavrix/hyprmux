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

# 1. One terminal.
pause 1.2
type_line "hello"
pause 1.5

# 2. More tiles: dwindle splits each new window off the focused one.
ctl dispatch exec
pause 1
type_line "ls"
pause 1
ctl dispatch web "file://${HYPRMUX_DEMO_DIR}/page.html"
pause 1.6

# 3. Move around: focus, swap, resize.
ctl dispatch movefocus l
pause 0.6
ctl dispatch swapwindow r
pause 1
ctl dispatch resizeactive 220 0
pause 0.8
ctl dispatch resizeactive -220 0
pause 0.8

# 4. Float a window and put it back.
ctl dispatch togglefloating
pause 1
ctl dispatch moveactive -120 -60
pause 0.8
ctl dispatch togglefloating
pause 1

# 5. Tabs: a group, with a new tab in it.
ctl dispatch togglegroup
pause 0.6
ctl dispatch exec
pause 1
type_line "git log --oneline"
pause 1
ctl dispatch changegroupactive b
pause 1

# 6. A named workspace, through the picker.
ctl dispatch picker workspace
pause 0.8
type_keys "notes"
pause 0.6
key ", Return"
pause 1
ctl dispatch exec
pause 1
type_line "cat todo.md"
pause 1.2

# 7. A notification from a terminal (OSC 9).
type_line "sleep 1; printf '\\e]9;Build finished in 42s\\a'"
pause 2.4

# 8. Back to the first workspace, then the scratchpad.
ctl dispatch workspace 1
pause 1.2
ctl dispatch togglespecialworkspace magic
pause 0.6
ctl dispatch exec
pause 1.2
ctl dispatch togglespecialworkspace magic
pause 1.5
