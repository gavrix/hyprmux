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

## Wait for changes

`hyprmuxctl events` streams a line per change, so a script can wait for something
instead of polling `surfaces`:

```sh
hyprmuxctl events | grep -m1 '^closewindow>>7$'   # surface:7 closed
```

See [Events and hooks](HOOKS.md) for every event, and for hooks: commands Hyprmux
runs when an event happens.

## Recommended agent workflow

1. Run `surfaces` and inspect `kind`, `workspace`, `title`, and `capabilities`.
   To work in a new terminal, open one with `new-surface` and use the `ref` it prints.
2. Select a terminal by its returned `ref`, not its list position.
3. Read recent output before sending input.
4. Send text or one key with an explicit target.
5. Read the target again and verify the result.

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
