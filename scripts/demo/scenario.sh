#!/usr/bin/env bash
# The README demo. record.sh plays it (through run.sh, which sources lib.sh); edit freely:
# every step is a shortcut, text typed into a terminal, or a pause.

play() {
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
}
