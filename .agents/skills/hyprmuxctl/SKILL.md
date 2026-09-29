---
name: hyprmuxctl
description: Discover, inspect, read, and control Hyprmux terminal surfaces with hyprmuxctl. Use when coordinating work between Hyprmux terminals, sending commands or keys to another surface, reading rendered terminal output, or testing Hyprmux without changing focus.
compatibility: macOS with Hyprmux running and hyprmuxctl available
---

<!-- managed-by-hyprmux -->

# Hyprmux terminal automation

Use `hyprmuxctl` as the compositor-mediated interface between terminals.
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

## Verify and handle failures

Read the target again after sending input.
Treat any `error:` response or nonzero exit status as failure.
Do not silently choose another surface when a target closes.

Only use operations listed in the target's capabilities.
Terminal surfaces currently expose `read_text`, `send_text`, and `send_key`.
Browser and device surfaces do not yet support these automation commands.

Avoid destructive commands unless the user explicitly requested them.
Do not send input to an ambiguous or unrelated terminal.
Remember that every same-user process with socket access shares this trust boundary.
