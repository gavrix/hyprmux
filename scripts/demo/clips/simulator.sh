# Clip 4, bonus: a live iOS Simulator as a tile (Mobile), with touch and the Home button.
# Uses a throwaway simulator ("Hyprmux Demo"), created here and deleted afterwards.

SIM_NAME="Hyprmux Demo"

setup() {
  local rt dt
  rt="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')"
  dt="$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=[x for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]; print(d[-1]["identifier"])')"
  SIM_UDID="$(xcrun simctl create "$SIM_NAME" "$dt" "$rt")"
  echo "$SIM_UDID" > "${HYPRMUX_DEMO_WORK}/sim-udid"
  xcrun simctl boot "$SIM_UDID"
  xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
  xcrun simctl launch "$SIM_UDID" com.apple.Preferences >/dev/null || true
  sleep 3
  type_line "hello"
  sleep 0.5
}

teardown() {
  local u
  u="$(cat "${HYPRMUX_DEMO_WORK}/sim-udid" 2>/dev/null || true)"
  [[ -n "$u" ]] || return 0
  xcrun simctl shutdown "$u" >/dev/null 2>&1 || true
  xcrun simctl delete "$u" >/dev/null 2>&1 || true
  rm -f "${HYPRMUX_DEMO_WORK}/sim-udid"
}

# A finger drag inside the simulator tile, in fractions of its screen: drag x1 y1 x2 y2.
drag() {
  local x y w h
  read -r x y w h < <(client_frame app)
  local ax ay bx by
  ax=$(python3 -c "print(int($x + $w * $1))"); ay=$(python3 -c "print(int($y + $h * $2))")
  bx=$(python3 -c "print(int($x + $w * $3))"); by=$(python3 -c "print(int($y + $h * $4))")
  ctl senddrag ", 272, $ax $ay, $bx $by"
}

# Clicks the Home button in the bar under the screen: Mobile's iOS bar has Home,
# then Lock, 22 points wide and 42 apart, centered.
home() {
  local x y w h
  read -r x y w h < <(client_frame app)
  local hx hy
  hx=$(python3 -c "print(int($x + $w / 2 - 32))"); hy=$(python3 -c "print(int($y + $h - 14))")
  ctl senddrag ", 272, $hx $hy, $hx $hy"
}

play() {
  caption "Bonus: iOS Simulator, as a tile | touch, keys, and the Home button, no Simulator.app"
  pause 1.4
  # By UDID: ⌘I would offer every booted simulator, including ones that aren't the demo's.
  ctl launch --focus --window "ios:$(cat "${HYPRMUX_DEMO_WORK}/sim-udid")" Mobile >/dev/null
  pause 2
  caption
  drag 0.5 0.7 0.5 0.3                # scroll Settings
  pause 1.2
  drag 0.5 0.3 0.5 0.75
  pause 1.2
  home
  pause 1.5
  drag 0.85 0.5 0.15 0.5              # next home screen page
  pause 1.4
  drag 0.15 0.5 0.85 0.5
  pause 1.2
}
