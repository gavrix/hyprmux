# Clip 1, the intro: basic operations, one shortcut at a time (keycast shows each).

play() {
  caption "Hyprland-style tiling, for macOS | terminals and web pages, in one window"
  pause 1.4
  type_line "hello"
  pause 1.2

  key "SUPER, Return"                 # new terminal: dwindle splits the focused tile
  pause 0.9
  type_line "ls"
  pause 0.6
  key "SUPER, B"                      # web tile, address bar focused
  pause 0.9
  type_url "localhost:${HYPRMUX_DEMO_PORT}"
  key ", Return"
  pause 1.4
  caption

  key "SUPER, H"                      # focus left
  pause 0.6
  key "SUPER ALT, L"                  # swap right
  pause 0.9
  for _ in 1 2 3 4 5; do key "SUPER CTRL, L"; sleep 0.1; done
  pause 0.7
  for _ in 1 2 3 4 5; do key "SUPER CTRL, H"; sleep 0.1; done
  pause 0.8

  key "SUPER SHIFT, Space"            # float
  pause 1.1
  key "SUPER SHIFT, Space"            # and back
  pause 0.9

  key "SUPER, G"                      # a group: tabs in one tile
  pause 0.6
  key "SUPER, Return"
  pause 0.9
  type_line "git log --oneline"
  pause 0.8
  key "CTRL SHIFT, Tab"
  pause 0.9

  key "SUPER, W"                      # close
  pause 1.2
}
