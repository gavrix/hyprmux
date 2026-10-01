# Adapters

An adapter lifts an app that doesn't speak the [client protocol](CLIENT_PROTOCOL.md)
into Hyprmux tiles. It's a JSON manifest plus an executable. The executable is
itself a protocol client: Hyprmux runs it in place of the app, and it turns the
app's windows into toplevels.

Hyprmux has no app-specific code. When `new-surface --type app` names an
`.app`, Hyprmux asks the adapter registry which adapter matches, and runs that
adapter's command. Apps that speak the protocol themselves (`HyprmuxClient` in
their Info.plist) never get an adapter.

Today's adapters all use `hyprmux-electron-bridge`:

| Adapter | Matches | Profile |
|---|---|---|
| `electron.vscode` | VS Code, Insiders, VSCodium | Own `--user-data-dir` and `--extensions-dir`, so it runs next to your own VS Code |
| `electron.cursor` | Cursor | Same, for Cursor |
| `electron` | Any app with `Electron Framework.framework` | None |

## Where manifests live

Hyprmux loads `*.json` from these directories, in order:

1. **Built-in:** `Hyprmux.app/Contents/Resources/adapters/`, from
   `Resources/adapters/` in the repo.
2. **User:** `adapters/` next to the config file, normally
   `~/.config/hyprmux/adapters/`.

A user manifest with a built-in's `id` replaces it. A manifest with only an id
and `"disabled": true` turns a built-in off:

```json
{ "id": "electron.vscode", "disabled": true }
```

Hyprmux rescans on launch, on config reload, and on `hyprmuxctl adapters reload`.

## Manifest

```json
{
  "id": "electron.vscode",
  "name": "VS Code",
  "description": "What it does, for hyprmuxctl adapters.",
  "match": {
    "bundleIds": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
    "bundleFiles": ["Contents/Frameworks/Electron Framework.framework"]
  },
  "exec": "hyprmux-electron-bridge",
  "args": ["--adapter", "vscode", "{app}", "{args}"],
  "probe": ["probe", "{app}", "--adapter", "vscode"],
  "priority": 10
}
```

| Key | Meaning |
|---|---|
| `id` | Required. Starts with a letter. Letters, digits, `.`, `_`, `-`. |
| `name`, `description` | Shown by `hyprmuxctl adapters`. |
| `match.bundleIds` | Any of these bundle ids. A trailing `*` matches a prefix. Case-insensitive. |
| `match.bundleFiles` | Paths inside the bundle that must all exist. |
| `exec` | Required. An absolute path, a path relative to the manifest (contains `/`), or a bare name. Bare names resolve in the adapter bin directories, then the manifest's directory. |
| `args` | Default `["{app}", "{args}"]`. `{app}` is the bundle path. An `{args}` element is replaced by the arguments after the app in `new-surface`. |
| `probe` | Optional. Arguments for a dry run (see below). |
| `priority` | Default 0. When several adapters match, the highest wins. |
| `disabled` | Default false. |

`match` needs at least one of `bundleIds` and `bundleFiles`, and both must hold
when both are given. Unknown keys are errors, so a typo can't silently widen a
match. A manifest with errors is skipped and listed under manifest errors.

The adapter Hyprmux picks is the highest-priority match that is `ready`. A
matching adapter that is disabled or broken (its executable is missing) is
skipped, and the next match gets the app.

## Bin directories

Bare `exec` names resolve in `HYPRMUX_ADAPTER_BIN` (colon-separated, for
development builds), then in `Hyprmux.app/Contents/MacOS`.

## Probe

`hyprmuxctl adapters match APP` runs the selected adapter's `probe`, if it has
one. A probe must not launch the app. It prints one JSON object to stdout and
has 5 seconds:

```json
{"ok": false, "reason": "the app disables the main-process inspector", "electron": "43.1.1"}
```

`ok` is required. `reason` explains a failure. Any other keys show up as
details. The Electron bridge's probe checks the bundle, reads the Electron
version, and checks the `EnableNodeCliInspectArguments` fuse. Without that
fuse, the bridge can't inject its hook. Slack is one such app.

## Writing an adapter

The executable gets the expanded `args`, plus `HYPRMUX_LAUNCH_TOKEN` and
`HYPRMUX_INSTANCE` in its environment. It must:

- Connect to Hyprmux with `HyprmuxClientKit`, or any implementation of the
  protocol. The kit sends the launch token in its `hello`, and the first
  toplevel fills the tile Hyprmux reserved.
- Create one toplevel per app window, and destroy it when the window closes.
- Exit when the app exits, and stop the app when Hyprmux disconnects or the
  adapter gets SIGTERM.
- Write a one-line reason to stderr before exiting on failure. Hyprmux shows
  the last stderr line when a launch fails before connecting.

## Runtime state

`hyprmuxctl adapters` shows:

- **Adapters:** each one with its state, source, priority, match, and resolved
  executable.
  - `ready`: usable.
  - `disabled`: turned off by a manifest.
  - `error`: unusable, with the reason (a missing executable).
  - `user*`: overrides a built-in manifest.
- **Manifest errors:** each file that didn't load, and why.
- **Instances:** each process Hyprmux started through an adapter, with its pid,
  tiles, and uptime.
  - `launching`: started, and its tiles are still waiting.
  - `running`: at least one tile is connected.
  - `idle`: alive, but with no tiles. Every window closed, or it never
    connected in time.
  - `exited`: the process ended. The note shows its last stderr line or its
    exit status.
  - `failed`: the process never started.

  Hyprmux keeps the last 10 ended instances.
- **Directories:** which ones were scanned, and whether they exist.

```sh
hyprmuxctl adapters                      # tables
hyprmuxctl adapters --json               # everything, plus the last probe per app
hyprmuxctl adapters match "/Applications/Visual Studio Code.app"
hyprmuxctl adapters match com.tinyspeck.slackmacgap
hyprmuxctl adapters reload
```

`adapters match` lists every adapter: `→` marks the one Hyprmux would use, `·`
marks other matches, and the WHY column says why each one did or didn't
match. `hyprmuxctl surfaces` shows an `adapter` field on app tiles.
