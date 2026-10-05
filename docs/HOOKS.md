# Events and hooks

Hyprmux reports what changes as events: a window opens, focus moves, a dispatcher
runs, the config reloads. Two things use them:

- **The event stream.** `hyprmuxctl events` prints each event as it happens. Any
  program can subscribe the same way, through the control socket. It's Hyprmux's
  version of Hyprland's `socket2`.
- **Hooks.** JSON manifests that run a command when an event happens. The
  [tour](TOUR.md) starts this way on the first launch.

Both only react. Neither can stop or change what Hyprmux does.

## The event stream

```sh
hyprmuxctl events
```

```
appactive>>1
submap>>
dispatch>>key,exec,
openwindow>>4,1,terminal,
activewindow>>terminal,~
activewindowv2>>4
```

Each line is `NAME>>DATA`, Hyprland's format. Fields in DATA are separated by
commas, and a last field that is free text (a title) can contain commas itself.
Window ids are surface ids, the same numbers as `hyprmuxctl clients` and
`surface:N` references.

To subscribe from a program, connect to the control socket (`$HYPRMUX_SOCKET`),
send `events` and a newline, and read lines until the connection closes. The first
lines describe the current state of the stateful events (`appactive` and
`submap`), so a subscriber doesn't need to ask. Subscribe before you query the
state you care about (`clients`, `workspaces`), so no change falls in between.

Hyprmux writes to each subscriber from its own queue, so a slow reader never slows
Hyprmux down. A reader that falls 1000 batches behind, or doesn't read for two
seconds, is disconnected.

### Events

Most names and fields follow Hyprland. These come from the window model, after
every change:

| Event | Data | When |
|---|---|---|
| `openwindow` | `ID,WORKSPACE,KIND,TITLE` | A window opened. KIND is `terminal`, `web`, or `app`. |
| `closewindow` | `ID` | A window closed. |
| `movewindow` | `ID,WORKSPACE` | A window moved to another workspace. |
| `activewindow` | `KIND,TITLE` | Focus moved. Both are empty when nothing has focus. |
| `activewindowv2` | `ID` | Focus moved, by id. |
| `changefloatingmode` | `ID,FLOATING` | A window floated (1) or tiled again (0). |
| `fullscreen` | `0` or `1` | A window entered or left fullscreen or maximize. |
| `togglegroup` | `STATE,ID,ID…` | A group was made (1) or dissolved (0), with its members. |
| `moveintogroup` | `ID` | A window joined an existing group. |
| `moveoutofgroup` | `ID` | A window left a group that still exists. |
| `workspace` | `N` | Another regular workspace is on screen. |
| `workspacev2` | `N,NAME` | The same, with the workspace's name (its number when unnamed). |
| `createworkspace` | `N` | A workspace got its first window, or came on screen. |
| `destroyworkspace` | `N` | A workspace emptied and went away. |
| `renameworkspace` | `N,NAME` | A workspace was named or renamed. |
| `activespecial` | `WORKSPACE,MONITOR` | The scratchpad opened (`special:NAME`) or closed (empty). MONITOR is always `hyprmux`. |
| `windowtitle` | `ID` | A window's title changed. |
| `windowtitlev2` | `ID,TITLE` | The same, with the new title. |
| `submap` | `NAME` | A bind submap started. Empty when it ends (`reset`). |
| `configreloaded` | (empty) | The config was reloaded. |

These are Hyprmux's own:

| Event | Data | When |
|---|---|---|
| `dispatch` | `SOURCE,NAME,ARGS` | A dispatcher is about to run. NAME and ARGS are written as in a bind line, so `dispatch>>key,movefocus,l`. |
| `appactive` | `0` or `1` | Hyprmux became the front app, or stopped being it. |
| `launch` | (empty) | Hyprmux started, after the session came back or the startup programs ran. |
| `firstlaunch` | (empty) | Hyprmux started and wrote a new config file. Comes just before `launch`. |

`dispatch` SOURCE says what caused it:

| Source | Meaning |
|---|---|
| `key` | A bind. |
| `mouse` | A mouse bind drag (`dispatch>>mouse,movewindow,` or `resizewindow`, sent when the drag ends), or a workspace pill clicked in the bar. |
| `ipc` | `hyprmuxctl dispatch`, or another socket command that moves windows. |
| `picker` | A choice in a picker (the workspace picker, naming a workspace) or in the menu. A menu row that opens another picker sends `dispatch>>picker,picker,KIND`. |
| `app` | Hyprmux itself: a terminal's own split shortcuts, a layout. |

A click or the pointer focuses a window without a dispatch: only `activewindow`
and `activewindowv2` arrive. That's how the tour tells keyboard focus from mouse
focus.

`launch` and `firstlaunch` happen while Hyprmux starts, before any subscriber can
connect. Only hooks see them.

## Hooks

A hook is a JSON file in a hooks folder:

- **Built in:** `Hyprmux.app/Contents/Resources/hooks/`.
- **Yours:** `hooks/` next to the config file, normally `~/.config/hyprmux/hooks/`.

Hyprmux loads them at launch and on every config reload. A hook of yours with a
built-in's id replaces it.

```json
{
  "id": "log-windows",
  "description": "Logs every window that opens or closes.",
  "on": ["openwindow", "closewindow"],
  "command": "echo \"$HYPRMUX_EVENT $HYPRMUX_EVENT_DATA\" >> ~/hyprmux-windows.log"
}
```

| Key | Value |
|---|---|
| `id` | Required. Starts with a letter; letters, digits, `.`, `_`, and `-`. |
| `on` | Required. An event name, or a list of them. |
| `command` | Required. A shell command line. |
| `run` | `exec` (the default) or `terminal`. |
| `description` | Optional text. |
| `disabled` | `true` turns off the hook with this id. A file with only `id` and `disabled` turns off a built-in. |

**`run: exec`** runs the command with `/bin/sh -c` in the background, from your
home folder. Its output is discarded; a non-zero exit goes to the log. Its
environment has everything a Hyprmux terminal gets (`HYPRMUX_SOCKET`,
`HYPRMUX_PID`, and `hyprmuxctl` on `PATH`), plus:

| Variable | Value |
|---|---|
| `HYPRMUX_EVENT` | The event name. |
| `HYPRMUX_EVENT_DATA` | The event data. |
| `HYPRMUX_HOOK` | The hook's id. |

Each event starts a new process, so keep hooks on frequent events
(`activewindow`, `windowtitle`) cheap. For those, a program that reads
`hyprmuxctl events` is often the better fit. A hook that dispatches can trigger
itself. For example, a hook on `openwindow` that opens a window never stops.

**`run: terminal`** types the command into a new terminal's shell, so the shell
stays when the command ends. It works only on `launch` and `firstlaunch`. Like
`exec-once`, a terminal hook replaces the empty terminal Hyprmux would otherwise
open, unless a session came back. In that case the hook's terminal opens next to
the restored tiles.

Broken manifests stay on screen as one notice until you fix them, with the file
and the problem.

### The built-in hook

`tour.json` offers the [tour](TOUR.md) on the first launch:

```json
{
  "id": "tour",
  "on": "firstlaunch",
  "run": "terminal",
  "command": "hyprmux-tour --welcome"
}
```

To never be offered the tour, add `~/.config/hyprmux/hooks/tour.json` with
`{ "id": "tour", "disabled": true }`. That matters only if you delete your
config, since `firstlaunch` happens only when Hyprmux writes a new one.
