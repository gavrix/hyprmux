# Terminal automation

`hyprmuxctl` lets tools discover, open, arrange, and close Hyprmux surfaces, and control terminal surfaces.
Operations go through Hyprmux's Unix socket.
They do not change focus or workspace visibility unless a command has `--focus`.

## Install and connect

The distributed application ships `hyprmuxctl` and adds its directory to terminal `PATH`.
Development builds can build the client directly:

```sh
swift build --product hyprmuxctl
```

Shells created by Hyprmux receive these variables:

| Variable | Meaning |
|---|---|
| `HYPRMUX_SOCKET` | Control socket for this Hyprmux instance. |
| `HYPRMUX_SURFACE_ID` | Numeric ID of the current terminal surface. |
| `HYPRMUX_CLIENT` | Compatibility alias for the current surface ID. |
| `HYPRMUX_PID` | PID of the owning Hyprmux process. |
| `HYPRMUXCTL_PATH` | Absolute path to the matching bundled `hyprmuxctl`. |
| `HYPRMUX_SKILL_PATH` | Absolute path to the bundled agent skill. |

Outside Hyprmux, set `HYPRMUX_SOCKET` when the default socket is not correct:

```sh
export HYPRMUX_SOCKET=/tmp/hyprmux-test/hyprmux.sock
```

## Discover and identify surfaces

List every live surface:

```sh
hyprmuxctl surfaces
hyprmuxctl surfaces | jq '.[] | {ref, kind, workspace, visible, focused, capabilities}'
```

Use `identify` to inspect the caller, explicit target, or focused surface:

```sh
hyprmuxctl identify
hyprmuxctl identify --surface surface:7
```

A surface reference accepts either `7` or `surface:7`.
The explicit form is easier to recognize in logs and prompts.

Surface IDs use one counter for all surface kinds.
They start at one for each Hyprmux process and are never reused within that process.
Gaps are valid, and IDs can change after an app restart or session restoration.
Moving a surface between workspaces does not change its ID.

The `workspace` field reports a regular workspace such as `2` or a special workspace.
A false `visible` value can mean an inactive workspace or a hidden group tab.
Do not infer workspace membership or ordering from the numeric surface ID.

Right-click a surface and choose **Copy Surface ID** to copy its `surface:N` reference.

## Target selection

Commands resolve their target in this order:

1. Explicit `--surface` option.
2. `HYPRMUX_SURFACE_ID` from the calling terminal.
3. Legacy `HYPRMUX_CLIENT` value.
4. Currently focused surface.

Use an explicit target for cross-terminal work.
Explicit reads and input do not focus the target, switch workspaces, or activate hidden group tabs.

`dispatch` is the exception.
Without `--surface`, it acts on the focused window, as a key binding does.

## Manage surfaces

Open a surface with `new-surface`.
It prints the new surface's JSON entry, the same shape as `surfaces` returns:

```sh
hyprmuxctl new-surface                                   # a shell next to the focused window
hyprmuxctl new-surface --workspace 3 --cwd ~/src/app     # a shell on workspace 3
hyprmuxctl new-surface --workspace name:agents -- htop   # run a command instead of the shell
hyprmuxctl new-surface --input 'devx pi\n'               # type into the new shell once it starts
hyprmuxctl new-surface --type web github.com
hyprmuxctl new-surface --type web --focus ~/notes/plan.md:42   # markdown, rendered, at line 42
hyprmuxctl new-surface --type app -- ~/bin/my-client   # a client app; see Open apps
ref=$(hyprmuxctl new-surface --workspace 2 | jq -r .ref)
```

| Option | Meaning |
|---|---|
| `--type` | `terminal` (default), `web`, or `app`. |
| `--workspace` | Workspace syntax: `3`, `name:NAME`, `special:NAME`, `empty`, `+1`. Default: the focused window's workspace. A new `name:` creates and names a workspace. |
| `--focus` | Focus the surface, switching to its workspace. |
| `--floating` | Open it floating instead of tiled. |
| `--cwd` | Terminal directory. Relative paths are relative to the caller. Default: the focused terminal's directory. |
| `--input` | Text typed into the new shell. Decodes `\n`, `\t`, and `\\`. The shell stays after the program exits. |

The argument after the options is the terminal command, the URL, or the app.
Options end at `--` or at the first plain word, so put them first.
A terminal command replaces the shell, and the terminal closes when it exits.
Without an argument, a web surface opens the start page.
An app replies once it opens its window.

Without `--focus`, focus and the visible workspace stay as they are.
The one exception is an empty screen: a surface that lands in view takes focus when nothing has it.
Without `--workspace`, a background surface opened while a group is focused joins it as a hidden tab.
It does not end a fullscreen window.

## Open apps

`launch` opens an app from the catalog ([APPS.md](APPS.md)), by name or id, and
replies with its tile once the window opens. Mobile shows iOS Simulators and
Android Emulators:

```sh
hyprmuxctl launch Mobile                    # several devices: lists them, opens none
hyprmuxctl launch --window ios:8A3F… Mobile # open one from the list
hyprmuxctl launch Mobile "iPhone 17"        # or name it: a name, UDID, or AVD id
hyprmuxctl launch --focus Reactotron
```

An app that offers several windows replies with `{"app": NAME, "windows":
[{id, title, detail}]}`. Pass an `id` back with `--window`. Each pick opens a
new tile, even for a device that is already open.

Close, focus, or move a surface:

```sh
hyprmuxctl close-surface --surface surface:7
hyprmuxctl focus-surface --surface surface:7             # switches workspace, shows a hidden tab
hyprmuxctl move-surface --surface surface:7 --workspace 4
hyprmuxctl move-surface --surface surface:7 --workspace name:review --focus
```

`close-surface` closes immediately, like `killactive`, even when a program is running.
`move-surface` moves the surface's whole group, and prints the surface's JSON entry.
Without `--focus`, focus stays where it is.
These commands follow the usual target order, so without `--surface` they act on the calling terminal.

## Run any dispatcher on a surface

Every key binding runs a dispatcher, and `dispatch` runs the same ones.
Window dispatchers act on the focused window.
Name another window with `--surface` before the dispatcher:

```sh
hyprmuxctl dispatch --surface surface:7 movewindow l
hyprmuxctl dispatch --surface surface:7 swapwindow r
hyprmuxctl dispatch --surface surface:7 resizeactive 40 0
hyprmuxctl dispatch --surface surface:7 togglefloating
hyprmuxctl dispatch --surface surface:7 fullscreen 1
hyprmuxctl dispatch --surface surface:7 moveintogroup l
hyprmuxctl dispatch --surface surface:9 webnav reload
hyprmuxctl dispatch --surface surface:9 fillcredential
hyprmuxctl dispatch --surface surface:9 fillcredential 1password
```

In a terminal, `fillcredential` needs the terminal to be focused and showing a password prompt.
A targeted dispatch to a background terminal is refused.

A targeted dispatcher does not focus the window.
Dispatchers about focus still move it: `movefocus` and `cyclenext` start from the target.
`movetoworkspace` follows the window, and `movetoworkspacesilent` doesn't.
On a hidden group tab, layout dispatchers act on the group's slot.
`moveintogroup` on an unfocused window adds it behind the group's shown tab.
`changegroupactive` shows another tab without focusing it.

Dispatchers that act on the app or a workspace reject `--surface`.
Examples are `exec`, `web`, `workspace`, `togglespecialworkspace`, `renameworkspace`, and `picker`.
[CONFIGURATION.md](CONFIGURATION.md#dispatchers) lists every dispatcher.

## Read terminal output

Read the visible viewport:

```sh
hyprmuxctl read-screen --surface surface:7
```

Read rendered scrollback:

```sh
hyprmuxctl read-screen --surface surface:7 --scrollback
```

Read the last 100 rendered lines:

```sh
hyprmuxctl read-screen --surface surface:7 --lines 100
```

`--lines` implies `--scrollback`.
Use `--json` when another program needs the target ID and options beside the text.
The command reads Ghostty's rendered text, not raw PTY bytes.
Control sequences and output overwritten by terminal rendering are therefore absent.

Read the terminal's most recent mouse selection without changing the clipboard:

```sh
hyprmuxctl read-selection --surface surface:7
```

Hyprmux caches it when the mouse selection completes, before keyboard input clears the live selection.

## Send text and keys

Send text and decode `\n`, `\t`, and `\\` in command arguments:

```sh
hyprmuxctl send --surface surface:7 'npm test\n'
```

Use standard input for arbitrary or multiline text.
Standard input is not escape-decoded:

```sh
printf '%s' 'literal \n text' | hyprmuxctl send --surface surface:7
```

Text input bypasses Hyprmux key bindings.
Send one terminal key separately when that better expresses the action:

```sh
hyprmuxctl send --surface surface:7 'npm test'
hyprmuxctl send-key --surface surface:7 enter
hyprmuxctl send-key --surface surface:7 ctrl+c
```

Other examples include `tab`, `shift+tab`, and `escape`.
Targeted input works for terminals on inactive workspaces and hidden group tabs.

## Drive web tiles

Agents can drive Chromium web tiles with any Chrome DevTools Protocol (CDP) client,
such as [agent-browser](https://github.com/vercel-labs/agent-browser),
Playwright's `connectOverCDP`, or Puppeteer's `connect`. It needs
`web:engine = chromium`.

```sh
agent-browser connect "$(hyprmuxctl cdp-url)"           # every web tile
agent-browser connect "$(hyprmuxctl cdp-url --surface surface:7)"   # one tile
agent-browser snapshot -i
agent-browser click @e2
```

`cdp-url` prints a WebSocket URL like
`ws://127.0.0.1:PORT/devtools/browser/TOKEN`. The first call starts the endpoint.
The URL stays the same until Hyprmux quits.

- **Targets:** each web tile is one page target. The focused tile is listed first.
- **`--surface`:** the URL reaches that tile only, plus the tiles its agent opens.
- **New pages:** `Target.createTarget` (`tab new`, `newPage()`) opens a web tile in
  the background on the focused workspace. Popups an agent's page opens stay in
  the background too. Chromium's focus requests from these tiles don't move
  Hyprmux's focus. The user's own click does.
- **Focus:** `Target.activateTarget` and `Page.bringToFront` succeed without
  moving focus. Use `focus-surface` to show a tile.
- **No quitting:** `Browser.close` only disconnects. Browser contexts aren't
  supported, because all tiles share one profile.

While an agent is attached, the tile shows a banner, "Agent is controlling this
tile", with a Stop button. The agent's mouse commands also move a cursor over
the page. A click waits until the cursor reaches its point, so what the user
sees matches what happens. Typing moves the cursor to the focused field, so a
`fill` without a click still shows where the text goes. The cursor stays put
when it's already over that field. Hyprmux draws the banner and the cursor in its own
views, so the page can't see them.

**Stop** detaches every agent from the tile. Their pending calls fail, and
their next message says the user stopped them. Auto-attach won't bring them
back; an explicit `Target.attachToTarget` does, and shows the banner again.

Credential fill is off in a tile while an agent controls it, because the agent
could read the filled value from the page.

How it works:

- Hyprmux serves the endpoint itself, on the loopback address only. Chromium
  opens no remote-debugging port, so credential fill keeps working in other tiles.
- Hyprmux answers the browser-level `Target` and `Browser` methods itself. It
  passes each tile's messages to that tile's in-process DevTools session.
- All agents share one DevTools session per tile. When the last agent leaves,
  Hyprmux undoes what agents changed: it removes their scripts and bindings,
  clears emulation, and turns their domains off.
- Requests with an `Origin` header (web pages) are refused, and so is any `Host`
  that isn't the loopback address.
- The URL's token is the secret. Only processes that can use Hyprmux's socket
  learn it.
- No `/json/version`: pass the WebSocket URL, not a port.

Limits:

- A tile on a workspace that isn't shown draws no frames. CDP still works there,
  but a client that waits for an animation frame waits for its timeout:
  agent-browser's `click` takes about 5 seconds. Drive tiles that are on screen.
- Emulated viewports (`Emulation.setDeviceMetricsOverride`) scale the page, so
  the cursor can land off the point the agent clicked. The click itself is right.

`HYPRMUX_CDP_LOG=FILE` in Hyprmux's environment logs every message in both
directions, shortened, for debugging a client.

## Wait for changes

`hyprmuxctl events` streams a line per change, so a script can wait for something
instead of polling `surfaces`:

```sh
hyprmuxctl events | grep -m1 '^closewindow>>7$'   # surface:7 closed
```

See [Events and hooks](HOOKS.md) for every event, and for hooks: commands Hyprmux
runs when an event happens.

## Agent state

A coding agent in a Hyprmux terminal, or a hook it runs, says what it's doing:

```sh
hyprmuxctl agent-state working --kind claude
hyprmuxctl agent-state blocked --kind claude --message "Allow rm -rf build?"
hyprmuxctl agent-state idle --kind claude
```

- **States:** `working`, `blocked` (it waits for you: a question, an approval),
  and `idle` (ready for input).
- **Shown on the tile:** the title pill on its top border takes the state's
  color: orange for working, red for needs you, green for done. So does the
  border while the tile isn't focused; a focused tile keeps its focus border.
  Both pulse: needs you fast, working steadily, done slowly. With titles off
  (`decoration:title`), the pill says the state instead ("working"). A tile in a
  group shows a dot on its tab. Idle shows nothing. The colors and the pulse are
  in [`activity`](CONFIGURATION.md#activity).
- **Shown on the workspace:** the workspace's pill in the bar counts its tiles in
  each state, one bubble per state: red for needs you, green for done, orange for
  working. Working bubbles wobble and ripple, needs-you bubbles faster, and done
  bubbles glow. When a tile finishes, a drop hops from its bubble to the done
  bubble and lands with a splash, and the done count goes up. Hover the pill for
  the counts in words. The workspace picker (`picker, workspace`) shows the same
  bubbles on each row, special workspaces included, and they update while it's
  open. With Reduce Motion (System Settings, Accessibility) the bubbles only fade
  in and out.
- **Done:** a turn that ends while you're not looking at the terminal shows as
  "done" until you focus it. Looking means its tile has focus while Hyprmux is in
  front.
- **Notices:** "needs you" (with the message) and "done" post a notice, unless
  you're looking at the terminal. Clicking it goes to the tile.
- **Which terminal:** `HYPRMUX_CLIENT`, set in every Hyprmux terminal. Outside one,
  `agent-state` does nothing, so a hook can call it anywhere. It prints nothing.
- **Which process:** the report counts while the agent runs in the terminal's
  foreground, as `resume` reports do. `--pid` defaults to the caller's process
  group, which is the agent's when a hook runs it. When the agent exits, the tile
  is a plain terminal again within a couple of seconds.
- **More fields:** `--title` (what it works on), `--session` (its session, for
  restore; see [Agent sessions](CONFIGURATION.md)).

**pi:** `Resources/agents/pi/hyprmux.ts` (inside the app: `Hyprmux.app/Contents/Resources/agents/pi/`)
is a pi extension that reports working while pi runs a turn and idle when it
settles, with its session for restore. It replaces `hyprmux-session.ts`. Copy it
to `~/.pi/agent/extensions/`. Another extension can mark pi blocked with
`pi.events.emit("hyprmux:blocked", { active: true, label: "Allow rm?" })` and
`{ active: false }` when answered.

`hyprmuxctl surfaces` shows a terminal's agent as
`"agent": {"kind", "state", "title", "message"}` and the tile's pill as `status`.
`hyprmuxctl events` sends `agent>>ID,KIND,STATE` when the shown state changes, with
an empty STATE when the agent goes away. On the socket, the report is one line:

```json
agent {"client": 12, "pid": 4711, "kind": "claude", "state": "blocked", "message": "Allow rm?"}
```

## Background jobs

`hyprmuxctl run` runs a command in a terminal attached to the caller's tile. The
job shows as a chip in the tile's job bar, along its bottom edge. The output also
streams back to the caller, and `run` exits with the command's status, so it works
as a drop-in prefix:

```sh
hyprmuxctl run -- npm test                       # streams here; a chip shows on this tile
hyprmuxctl run --reveal-after 1.5 -- make        # no chip if it ends within 1.5 seconds
hyprmuxctl run --no-wait --title dev -- npm run dev   # a background job; prints its JSON
```

A job started with `--no-wait` keeps running after `run` returns. Manage it by its
id, the `ref` (or `id`) in that JSON:

```sh
hyprmuxctl jobs                         # this tile's jobs (--all: every tile's; --json)
hyprmuxctl jobs log surface:14 --lines 40   # its output as plain text
hyprmuxctl jobs log surface:14 --new    # only what's new since this reader's last --new
hyprmuxctl jobs wait surface:14 --timeout 60   # exits with its status; 124 on timeout
```

A job is a terminal surface, so the usual commands type into it and stop it:
`send --surface surface:14 'y\n'`, `send-key --surface surface:14 ctrl+c`, and
`close-surface --surface surface:14`.

Hyprmux keeps a job's record (title, state, exit status, log path) after its terminal
closes, for the last 100 closed jobs, so `wait` and `log` still answer. States:
`running`, `done` (exit 0), `failed`, and `stopped` (closed while it ran; `wait` exits
129). Only `--no-wait` jobs have a log: a job `run` waits for streams to its caller.

`--new` remembers each reader's position, in a file next to the log. The reader is the
calling tile, or `--reader NAME`. It returns everything up to the end of the log, then
the job's state on stderr: `[surface:14 running]`. When a running job's output ends
in the middle of a line, as at a prompt, the state says so:
`[surface:14 running, its last line has no newline: it may wait for input]`.
The log is a file under `$TMPDIR`, left for macOS to clean up.

- **The job bar:** a strip along the bottom of the tile, one chip per job: a status
  dot, the title, and the run time. The tile's content shrinks to make room, so jobs
  never cover it. The bar goes away with the tile's last job. Jobs that need you come
  first, then running ones, then finished ones. When chips don't fit, titles
  truncate, then chips shrink to their dot, then the last ones go behind a `+N` chip
  that lists them. The bar moves, hides, and slides with its tile.
- **Peek:** hover a chip to see its job: the real terminal, scaled down, just above
  the chip. The command sees the full size (the expanded frame), so nothing reflows
  when it expands. The peek stays while the pointer is on it. Peeks and expanded
  jobs grow out of their chip and shrink back into it.
- **Expand:** click a chip or a peek, or press `$mod SHIFT B` (`focusattached`). It
  covers its tile above the job bar, minus a margin, and takes the keyboard: answer a
  prompt, press ctrl-c. Click its chip again, move focus away, or press
  `focusattached` again to collapse it.
- **Status:** the chip's dot (and the job's border) is orange while it runs. It turns
  green when the command succeeds, and the job goes after `--linger` seconds (default
  5; 0 keeps it). It turns red ("needs you") when the command fails, and stays until
  closed (`killactive`).
- **Lifetime:** closing the tile closes its jobs. When the `run` process dies first
  (an agent aborting a tool call, even with SIGKILL), Hyprmux closes the job's terminal,
  which hangs up on it. `close-surface` on the job ends it.
- **Output:** to a terminal, `run` passes the bytes as they are. To a pipe, it drops
  escape sequences and keeps the last state of lines redrawn with a carriage return,
  so a progress bar leaves one line.
- **Environment:** the command gets the caller's environment and directory, a real
  terminal (`TERM` and size from the attached terminal), and `PAGER=cat` and
  `GIT_PAGER=cat`, so nothing waits in a pager (`--keep-pager` to keep yours).
  stdout and stderr arrive merged, as in any terminal.
- **Outside Hyprmux** (no `HYPRMUX_CLIENT`), `run` runs the command in place.

An agent running in a job reports its state like any agent (see Agent state): its
chip takes the color, red with a notice when it needs you. A job started through
`run` sits behind `script(1)`, outside the terminal's foreground process group, so its
reports don't count. An agent harness sends `attach {…}` itself, without `status_file`
or `log`, so the agent is the terminal's foreground program.

Layout dispatchers sent to a job act on its tile: a job has no place in the layout of
its own. `surfaces` lists a job with `"attached": {"parent", "expanded", "revealed",
"running", "exitStatus"}`, and its `status`. A tile with a job bar lists its jobs'
ids in bar order as `"jobs"`.

**pi:** `Resources/agents/pi/hyprmux-run.ts` routes pi's bash tool through
`hyprmuxctl run --reveal-after 1.5`. Copy it to `~/.pi/agent/extensions/`. It rewrites
the command in a `tool_call` handler, so it works with extensions that re-register
bash. `PI_HYPRMUX_RUN=0` turns it off; `HYPRMUX_RUN_REVEAL_AFTER` sets the delay.

On the socket, `run` sends one line and gets the job's `surfaces` entry back. `jobs`
lists the records, all or one tile's:

```json
attach {"parent": 12, "command": "...", "cwd": "...", "env": {...}, "title": "npm test",
        "owner": 4711, "reveal_after": 1.5, "linger": 5, "status_file": "...", "log": "..."}
jobs --parent 12
```

## Recommended agent workflow

1. Run `surfaces` and inspect `kind`, `workspace`, `title`, and `capabilities`.
   To work in a new terminal, open one with `new-surface` and use the `ref` it prints.
2. Select a terminal by its returned `ref`, not its list position.
3. Read recent output before sending input.
4. Send text or one key with an explicit target.
5. Read the target again and verify the result.

For a web tile, connect a CDP client to `hyprmuxctl cdp-url` (see Drive web tiles).

Terminals advertise `read_text`, `send_text`, and `send_key`. App tiles whose
client has text input on (such as VS Code through its adapter) advertise
`send_text`: `send` types into the app's focused field, through the same path
as dictation.
Treat missing capabilities as unsupported operations.
A closed surface returns an error instead of retargeting another surface.

## Limits and trust

The server accepts requests up to 1 MiB.
`hyprmuxctl send` limits input to 750 KiB.
Terminal reads are limited to 16 MiB; use `--lines` for large histories.

The socket is created with mode `0600`.
Any process running as the same macOS user can still read terminals and send input.
Do not expose the socket to untrusted programs.

## Agent skill

Hyprmux ships an Agent Skills compatible `hyprmuxctl` skill inside the application.
Install or update it explicitly:

```sh
hyprmuxctl skill install
```

The command writes `~/.agents/skills/hyprmuxctl/SKILL.md` atomically.
It refuses to replace an unmanaged file unless `--force` is present.
The installed copy follows the portable Agent Skills layout and works from any directory.

Inspect or remove the installation:

```sh
hyprmuxctl skill status
hyprmuxctl skill path
hyprmuxctl skill source
hyprmuxctl skill uninstall
```

Pi discovers the installed skill when a new session starts.
At startup, Pi advertises the skill's name and description without loading all instructions.
It reads the full skill when a request matches that description.
Run `/reload` to discover a new installation in an existing Pi session.
Use `/skill:hyprmuxctl` to force loading.

Installation is optional.
Launch Pi with the bundled skill for one session without writing a global file:

```sh
pi --skill "$HYPRMUX_SKILL_PATH"
```

The local `skill` commands do not connect to the Hyprmux socket.
Skills teach an agent the workflow but do not grant additional socket permissions.
