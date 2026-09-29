# Helpers for demo scenarios (sourced by run.sh). They drive a Hyprmux instance through
# its control socket: $CTL and $HYPRMUX_SOCKET are set by record.sh.
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

# A caption at the top of the window: "Title | subtitle". No argument hides it.
caption() { ctl caption "${1:-}"; }
# Frame of the first client of a kind, as "x y w h" (for aiming mouse input).
client_frame() {
  "$CTL" clients | python3 -c '
import json, sys
kind = sys.argv[1]
for c in json.load(sys.stdin):
    if c["kind"] == kind and c["visible"]:
        print(*[int(v) for v in c["at"] + c["size"]]); break
' "$1"
}
