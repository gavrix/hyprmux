# Terminal automation

`hyprmuxctl` lets tools discover Hyprmux surfaces and control terminal surfaces.
Operations go through Hyprmux's Unix socket and do not change focus or workspace visibility.

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

## Recommended agent workflow

1. Run `surfaces` and inspect `kind`, `workspace`, `title`, and `capabilities`.
2. Select a terminal by its returned `ref`, not its list position.
3. Read recent output before sending input.
4. Send text or one key with an explicit target.
5. Read the target again and verify the result.

Only terminals currently advertise `read_text`, `send_text`, and `send_key`.
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
