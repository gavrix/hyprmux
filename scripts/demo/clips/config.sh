# Clip 2, the config: hyprland.conf syntax, edited in nvim; every save reloads live.

setup() {
  type_line "hello"
  key "SUPER, Return"
  sleep 1
  type_line "ls"
  key "SUPER, B"
  sleep 0.8
  type_url "localhost:${HYPRMUX_DEMO_PORT}"
  key ", Return"
  sleep 1
  key "SUPER, H"                      # back to the first terminal
  sleep 0.4
  type_line "cd .. && clear"            # so nvim shows just "hyprmux.conf"
  sleep 0.3
  type_line "nvim -u NONE -c 'syntax on' -c 'set nu title titlestring=hyprmux.conf' +/^general hyprmux.conf"
  sleep 1.2
}

# Runs an nvim command, e.g. ":%s/a/b/", then Return.
ex() { type_line "$1"; }

play() {
  caption "Configured like Hyprland | hyprland.conf syntax, reloaded on every save"
  pause 2.4
  caption
  pause 0.4
  ex ":%s/gaps_in = 5/gaps_in = 12/"
  pause 0.4
  ex ":%s/gaps_out = 14/gaps_out = 44/"
  pause 0.4
  ex ":w"
  pause 1.6
  ex ":%s/rounding = 10/rounding = 30/"
  pause 0.4
  ex ":%s/rounding_power = 2.0/rounding_power = 4.0/"
  pause 0.4
  ex ":w"
  pause 1.6
  ex ":%s/rgba(33ccffee) rgba(00ff99ee) 45deg/rgba(ff6ac1ee) rgba(ffb86cee) 45deg/"
  pause 0.4
  ex ":w"
  pause 2
}
