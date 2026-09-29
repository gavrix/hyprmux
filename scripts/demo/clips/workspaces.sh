# Clip 3, workspaces: numbered ones that slide, a named one from the picker, moving a
# window there, and the scratchpad.

setup() {
  type_line "hello"
  key "SUPER, B"
  sleep 0.8
  type_url "localhost:${HYPRMUX_DEMO_PORT}"
  key ", Return"
  sleep 0.8
  key "SUPER, 2"
  key "SUPER, Return"
  sleep 1
  type_line "git log --oneline"
  key "SUPER, 3"
  key "SUPER, Return"
  sleep 1
  type_line "ls"
  key "SUPER, Return"
  sleep 1
  type_line "cat todo.md"
  key "SUPER, S"                      # a scratchpad terminal, then hide it
  key "SUPER, Return"
  sleep 1
  type_line "echo scratchpad"
  key "SUPER, S"
  key "SUPER, 1"
  sleep 1
}

play() {
  caption "Workspaces | ⌘1…9, named ones, and a scratchpad"
  pause 1.4
  key "SUPER, 2"
  pause 1
  key "SUPER, 3"
  pause 1
  key "SUPER, 1"
  pause 1.1
  caption

  key "SUPER, P"                      # the workspace picker; a new name makes one
  pause 0.7
  type_keys "notes"
  pause 0.5
  key ", Return"
  pause 1
  key "SUPER, 1"
  pause 0.9
  key "SUPER, L"                      # focus the web tile…
  pause 0.5
  key "SUPER SHIFT, P"                # …and move it to "notes"
  pause 0.7
  type_keys "not"
  pause 0.4
  key ", Return"
  pause 1.3

  key "SUPER, S"                      # scratchpad over everything
  pause 1.3
  key "SUPER, S"
  pause 1.2
}
