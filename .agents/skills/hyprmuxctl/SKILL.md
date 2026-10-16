---
name: hyprmuxctl
description: Discover, open, arrange, close, read, and control Hyprmux surfaces with hyprmuxctl. Use when coordinating work between Hyprmux terminals, opening a terminal or web tile on a workspace, moving or closing surfaces, sending commands or keys to another surface, reading rendered terminal output, or testing Hyprmux without changing focus. Also use it inside a Hyprmux terminal (HYPRMUX_CLIENT set) to run builds, tests, dev servers, watchers, or any long or non-exiting command as a visible background job (hyprmuxctl run, hyprmuxctl jobs) instead of blocking the shell.
compatibility: macOS with Hyprmux running and hyprmuxctl available
---

<!-- managed-by-hyprmux -->

# Hyprmux surface automation

Use `hyprmuxctl` as the compositor-mediated interface to Hyprmux surfaces:
terminals, web tiles, and app tiles, including Mobile's simulator and emulator tiles.
Do not open the Unix socket directly or depend on surface view objects.

## Establish the client

Hyprmux ships the matching `hyprmuxctl` and adds it to terminal `PATH`.
Confirm that it is available:

```sh
command -v hyprmuxctl
```

Use `$HYPRMUXCTL_PATH` when shell configuration replaces `PATH`.
When working from this repository, build the client when necessary:

```sh
swift build --product hyprmuxctl
```

Use `HYPRMUX_SOCKET` from the current terminal.
Do not replace it unless the user identifies another Hyprmux instance.
The bundled skill path is available as `HYPRMUX_SKILL_PATH`.

A running Hyprmux can be older than the client.
If a command replies `error: unknown command`, tell the user that Hyprmux needs a restart.
Do not restart it yourself: that closes their shells.

## Discover before acting

Start every cross-terminal workflow with:

```sh
hyprmuxctl surfaces
```

Inspect each surface's `ref`, `kind`, `workspace`, `title`, `visible`, and `capabilities`.
Use `identify` to inspect the calling or focused surface:

```sh
hyprmuxctl identify
```

Choose targets by returned `surface:N` references.
Do not use list positions or infer workspace membership from surface numbers.
IDs are process-local and can change after Hyprmux restarts.

## Read before sending

Read recent rendered output before changing another terminal:

```sh
hyprmuxctl read-screen --surface surface:N --lines 100
```

Use the visible viewport when history is unnecessary:

```sh
hyprmuxctl read-screen --surface surface:N
```

Use `--scrollback` for all available rendered history.
Use `--json` when structured metadata is needed beside the text.

Read the terminal's most recent mouse selection without the clipboard:

```sh
hyprmuxctl read-selection --surface surface:N
```

Hyprmux preserves the selection after terminal input clears its visible highlight.

## Send explicit input

Prefer an explicit target for every cross-terminal action.
Send a command and Enter separately when quoting would be unclear:

```sh
hyprmuxctl send --surface surface:N 'npm test'
hyprmuxctl send-key --surface surface:N enter
```

Use standard input for arbitrary or multiline text:

```sh
printf '%s' "$text" | hyprmuxctl send --surface surface:N
```

Command arguments decode `\n`, `\t`, and `\\`.
Standard input remains literal.

Send control and special keys directly:

```sh
hyprmuxctl send-key --surface surface:N ctrl+c
hyprmuxctl send-key --surface surface:N escape
hyprmuxctl send-key --surface surface:N shift+tab
```

Targeted reads and input must not focus the target or switch workspaces.
They can reach inactive workspaces and hidden group tabs.

## Open, move, and close surfaces

Open a surface without taking focus.
It prints the new surface's JSON; read its `ref` for later commands:

```sh
ref=$(hyprmuxctl new-surface --workspace 3 --cwd "$PWD" --input 'npm test\n' | jq -r .ref)
hyprmuxctl new-surface --workspace name:agents -- htop
hyprmuxctl new-surface --type web --workspace 2 https://example.com
```

Put options before the command or URL.
`--input` types into a shell that stays open after the program exits.
A command after `--` replaces the shell, and the terminal closes when it exits.
Without `--cwd`, a terminal starts in the focused terminal's directory, not the caller's.
`--workspace` takes `3`, `name:NAME`, `special:NAME`, or `empty`; a new `name:` creates the workspace.

Open a macOS app in a tile with `launch`, by the name or id `apps` lists.
It replies with the tile's JSON, like `new-surface`, and takes focus only with `--focus`:

```sh
hyprmuxctl apps                                      # the apps Hyprmux can open (.hmapp bundles)
hyprmuxctl launch Cursor ~/src/project               # name or id, then the app's arguments
hyprmuxctl apps add "Zed (dev)" ~/src/zed/target/release-fast/zed   # install an app (.app or executable)
hyprmuxctl apps refresh                              # rescan the app folders now
```

An app that can open several windows replies with them instead of opening one.
Pick one with `--window ID`. Mobile shows iOS Simulators and Android Emulators
this way:

```sh
hyprmuxctl launch Mobile                             # {"app": "Mobile", "windows": [{"id": "ios:UDID", ...}]}
hyprmuxctl launch --window ios:UDID Mobile           # opens that device; each call opens another tile
hyprmuxctl launch Mobile "iPhone 17"                 # or name the device directly
```

An app missing from `apps` can't open in a tile. `adapters match` says why:

```sh
hyprmuxctl adapters match com.tinyspeck.slackmacgap   # which adapter, and can it lift the app?
hyprmuxctl adapters                                  # adapters, launched instances, manifest errors
hyprmuxctl new-surface --type app "/Applications/Visual Studio Code.app"   # by path, without the catalog
```

If every app tile times out, check the broker they connect through:
`hyprmuxctl broker status` says whether macOS runs it, and whether it waits for
approval in Login Items.

Move, focus, or close a surface by its reference:

```sh
hyprmuxctl move-surface --surface surface:N --workspace 4
hyprmuxctl focus-surface --surface surface:N
hyprmuxctl close-surface --surface surface:N
```

These default to the calling terminal, so always pass `--surface` for another one.
`move-surface` moves the surface's whole group and prints its JSON.
`close-surface` closes immediately, without confirmation, and ends the programs in that terminal.

Run any key-binding dispatcher on a surface without focusing it:

```sh
hyprmuxctl dispatch --surface surface:N movewindow l
hyprmuxctl dispatch --surface surface:N swapwindow r
hyprmuxctl dispatch --surface surface:N resizeactive 40 0
hyprmuxctl dispatch --surface surface:N togglefloating
hyprmuxctl dispatch --surface surface:N moveintogroup l
```

Without `--surface`, `dispatch` acts on the focused window, which may belong to the user.
`movefocus`, `cyclenext`, and `movetoworkspace` move focus even with a target.
Use `movetoworkspacesilent` or `move-surface` to move a window without following it.
App and workspace dispatchers such as `exec` and `workspace` reject `--surface`.

### Background jobs

Inside a Hyprmux terminal (`HYPRMUX_CLIENT` is set), run commands that take a while
through `hyprmuxctl run`. Each runs in a real terminal attached to your tile, as a
live preview the user can watch, expand, and type into.

**Builds and tests: wait for them.** Prefix the command. Output streams back as plain
text, and `run` exits with the command's status, as if it ran in place:

```sh
hyprmuxctl run --reveal-after 1.5 -- npm test
```

**Servers, watchers, and anything that doesn't exit: start a job.** Never run them in
the foreground: your shell call would block until its timeout. Use a job instead of
`&`, `nohup`, `disown`, or `setsid` too: the user sees what runs, and you can read its
output and stop it later, from any shell call. `--no-wait` returns at once with the
job's JSON; its `ref` is the job id:

```sh
job=$(hyprmuxctl run --no-wait --title "dev server" -- npm run dev | jq -r .ref)
hyprmuxctl jobs log "$job" --lines 40            # its output so far, as plain text
hyprmuxctl jobs wait "$job" --timeout 120        # block until it ends; exits with its status
hyprmuxctl jobs log "$job" --follow              # stream it until it ends
hyprmuxctl jobs                                  # this tile's jobs: state, exit status, time
hyprmuxctl jobs stop "$job"                      # end it when you're done
```

- Give each job a `--title`: the user sees it on the preview.
- Poll a server's log for "ready" or a port before you use it.
- Stop the jobs you started once you don't need them. A failed job's preview stays
  until someone closes it; a finished one goes after a few seconds.
- `jobs log` and `jobs wait` still answer after the job's terminal closed.
- `jobs wait` exits 124 when the timeout passes first, and 129 for a stopped job.

## Drive web tiles

Drive Chromium web tiles through CDP with agent-browser or Playwright.
`hyprmuxctl cdp-url` prints the endpoint's WebSocket URL:

```sh
agent-browser connect "$(hyprmuxctl cdp-url --surface surface:N)"   # one tile
agent-browser connect "$(hyprmuxctl cdp-url)"                       # every web tile
agent-browser snapshot -i
agent-browser click @e2
```

Prefer `--surface` with the tile the user means. It keeps you out of their other tiles.
Pass the URL, not a port: Hyprmux serves no `/json/version`.
`tab new` opens a background web tile on the focused workspace.
It needs `web:engine = chromium`; otherwise `cdp-url` replies with an error.

The user sees a banner and your cursor in the tile, and can press Stop.
After Stop, your next command fails with a message that says so.
Don't reattach without asking the user.

## Wait for changes

`hyprmuxctl events` streams one `NAME>>DATA` line per change until it is stopped.
Use it to wait instead of polling, for example for a surface to close:

```sh
hyprmuxctl events | grep -m1 '^closewindow>>7$'
```

Window ids in events are the `N` of `surface:N`.
Useful events: `openwindow`, `closewindow`, `activewindowv2`, `windowtitlev2`, and `dispatch`.

## Respect the user's view

The user is often working in the focused window.
Open, move, and dispatch in the background by default.
Use `--focus`, `focus-surface`, or a focus-moving dispatcher only when the user wants to see the result now.

## Verify and handle failures

Read the target again after sending input.
Check the `workspace` field that `new-surface` and `move-surface` print.
After `close-surface`, confirm the `ref` is gone from `surfaces`.
Treat any `error:` response or nonzero exit status as failure.
Do not silently choose another surface when a target closes.

`capabilities` lists the content operations a surface supports.
Terminal surfaces expose `read_text`, `send_text`, and `send_key`.
App tiles with text input (such as VS Code) expose `send_text`: `send` types into the focused field there.
Browser and device surfaces do not support `read-screen`, `send`, or `send-key` yet.
Drive Chromium web tiles through `cdp-url` instead.
Opening, moving, focusing, closing, and dispatching work for every surface kind.

Avoid destructive commands unless the user explicitly requested them.
Do not send input to an ambiguous or unrelated terminal.
Remember that every same-user process with socket access shares this trust boundary.
