# The tour

`hyprmux-tour` teaches Hyprmux step by step, inside Hyprmux. It runs in a normal
terminal tile, the tour tile. Each step asks you to do something with the real keys
or the mouse, watches Hyprmux until you have done it, and then asks you to come
back to the tour tile. Nothing happens for you: the tour never presses a key or
moves a tile.

## Starting it

- **First launch:** when Hyprmux writes a new config, it emits `firstlaunch`, and
  the built-in `tour` [hook](HOOKS.md#hooks) runs `hyprmux-tour --welcome` in the
  first terminal. The tour asks once: press Return to start or `q` for not now.
  The shell stays when the tour ends.
- **Any time:** run `hyprmux-tour` in a Hyprmux terminal. It's on `PATH` there,
  next to `hyprmuxctl`.

| Command | Does |
|---|---|
| `hyprmux-tour` | Picks up at the step where you stopped. A finished tour starts over. |
| `hyprmux-tour --restart` | Starts from the beginning. |
| `hyprmux-tour --step N` | Starts at step N (0 is the welcome). |
| `hyprmux-tour --welcome` | Offers the tour unless it was offered before. |

In the tour tile: Return goes on once a step is done, `s` skips a step, `b` goes
back, `r` redoes the current step, and `q` pauses the tour.

## The steps

Every lesson ends by coming back to the tour tile, and every way back uses
something an earlier step taught. The ways back arrive in this order:

1. **The mouse:** focus follows the pointer, or you click.
2. **⌘H/J/K/L:** directional focus.
3. **⌘\`:** the tile you were on before. It works across workspaces.
4. **⌃Tab:** for when the tour is a hidden tab in a group.
5. **⌘1…9:** for when the tour is on another workspace.
6. **⌘S:** hiding the scratchpad puts you back under it.
7. **⌘Tab:** back from your editor after changing the config.

| # | Step | You do | Way back |
|---|---|---|---|
| 1 | Open a terminal | ⌘↩ | the mouse |
| 2 | Move focus | ⌘L, by key only | ⌘H, by key only |
| 3 | More tiles | ⌘↩ from the other terminal, so the tour keeps its size | ⌘H/J/K/L, then ⌘\` |
| 4 | Move the tour tile | ⇧⌘H/J/K/L, ⌥⌘H/J/K/L, and ⌘-drag onto another tile | (focus stays) |
| 5 | Resize | ⌃⌘H/L; resize mode with ⌘R, H/J/K/L, and Esc; ⌘-right-drag | (focus stays) |
| 6 | Float and maximize | ⇧⌘Space, ⌘-drag the floating tile, ⇧⌘Space, ⌘F twice | (focus stays) |
| 7 | A web tile | ⌘B, then an address | ⌘\` or ⌘H/J/K/L |
| 8 | Tabs | ⌘G, ⌘↩, close the extra tab, ⌘G | ⌃Tab |
| 9 | Workspaces | ⌘2 and a terminal there | ⌘1 |
| 10 | Send a tile to another workspace | ⇧⌘2 from a practice tile | ⌘1 |
| 11 | The scratchpad | ⌘S, a terminal, ⌘S | ⌘S |
| 12 | Clean up | ⌘W on every practice tile, wherever it is | everything above |
| 13 | Make it yours | edit `gaps_in` in your config and save | ⌘Tab |

Steps that teach a way to do something check that you used it. Step 2 wants the
keyboard both ways; if focus moved with the pointer, the tour says so. Step 4's
move and swap are told apart, and its drag must be a drag. Step 5 follows resize
mode in and out. Step 3's last return must be ⌘\`.

The keys shown are the ones in your config. The tour reads it with the same parser
as Hyprmux, so a rebound action shows its new key, and an unbound one says so. The
workspace numbers adapt too: step 9 picks the first empty workspace.

## Getting lost

When a step waits for you to come back, the tour works out the quickest way from
where you are. After a few seconds it shows that way in the tour tile, if the tile
is on screen. After 20 seconds it sends a notification (OSC 9), such as "Hyprmux
tour: Press ⌘1 to go back to workspace 1." Clicking the notification focuses the
tour tile. Directional focus and ⌘\` are suggested only after the steps that teach
them, and ⌘\` only when the tour really was the previous tile.

## How it works

The tour is a separate executable that only watches Hyprmux. Hyprmux has no
tour-specific code: the tour uses the [event stream](HOOKS.md#the-event-stream)
to watch and a built-in [hook](HOOKS.md#hooks) to start.

- **`HyprmuxTour`** (library, unit tested): the steps and their checks
  (`Curriculum`), the progress state machine (`TourEngine`), key lookup from the
  config (`TourKeys`), the way-back hint (`TourWayBack`), and styled text with word
  wrapping (`TourMarkup`, `TourWrap`).
- **`hyprmux-tour`** (executable): the terminal UI, the socket client, and the
  saved progress.

The tour subscribes to events, then waits for a key or an event. After each event
batch it fetches `clients` and `workspaces` once. A step is a list of tasks. Each
task is a check over what Hyprmux reported (now, at the previous look, when the
step began, and when the previous task finished) and the events since the previous
task. `dispatch` events say how something happened: by key, by mouse, or neither.
`appactive` says whether Hyprmux is in front, and `configreloaded` that a save
took. Tasks finish in order and stay finished.

The tour's own tile comes from `HYPRMUX_SURFACE_ID`. Practice tiles are every
surface that didn't exist when the tour began.

Progress lives in `~/Library/Application Support/Hyprmux/Tour/<instance>.json`,
where the instance is `HYPRMUX_INSTANCE` or `default`. `HYPRMUX_TOUR_STATE` points
it somewhere else, which test instances use. Surface ids only mean something inside
one Hyprmux run, so the file also records `HYPRMUX_PID`.

## Testing

Run the tour in a test instance (see [DEVELOPMENT.md](DEVELOPMENT.md#testing-a-running-app))
with a config path that doesn't exist yet, so it's a first launch:

```sh
HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh
mkdir -p /tmp/hm-test
open -g -n \
  --env HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock \
  --env HYPRMUX_CONFIG=/tmp/hm-test/config/hyprmux.conf \
  --env HYPRMUX_CHROMIUM_PROFILE=/tmp/hm-test/chromium \
  --env HYPRMUX_SESSION=/tmp/hm-test/session.json \
  --env HYPRMUX_TOUR_STATE=/tmp/hm-test/tour.json \
  /tmp/HyprmuxTest.app
export HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock
hyprmuxctl read-screen --surface surface:1 --lines 200   # the welcome
hyprmuxctl sendkey ", Return"                            # start
hyprmuxctl sendkey "SUPER, Return"                       # step 1
hyprmuxctl senddrag "SUPER, 272, 600 900, 1900 900"      # a ⌘-drag, for the mouse tasks
```

`sendkey` and `senddrag` play the user's part, and `read-screen` shows what the
tour says. `hyprmuxctl events` in another shell shows what the tour sees. The
config step waits for Hyprmux to be the front app, which a background test
instance isn't: press `s` there.
