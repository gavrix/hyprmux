# Adapters

An adapter lifts an app that doesn't speak the [client protocol](CLIENT_PROTOCOL.md)
into Hyprmux tiles. It's a JSON manifest plus an executable. The executable is
itself a protocol client: Hyprmux runs it in place of the app, and it turns the
app's windows into toplevels.

Hyprmux has no app-specific code. When `new-surface --type app` names an
`.app`, Hyprmux asks the adapter registry which adapter matches, and runs that
adapter's command. Apps that speak the protocol themselves (`HyprmuxClient` in
their Info.plist) never get an adapter.

Users don't see adapters. They see [apps](APPS.md): Hyprmux scans the app
folders, and each app an adapter lifts (whose probe passes) gets a generated
`.hmapp` in the launcher. Adapters are the rules that generate those apps.

Today's adapters all use `hyprmux-electron-bridge`:

| Adapter | Matches | Profile |
|---|---|---|
| `electron.vscode` | VS Code, Insiders, VSCodium | Own `--user-data-dir` and `--extensions-dir`, so it runs next to your own VS Code |
| `electron.cursor` | Cursor | Same, for Cursor |
| `electron` | Any app with `Electron Framework.framework` | Own user data folder |

Every lifted app runs with its own profile, apart from your normal copy. See
[Profiles](APPS.md#profiles) for what that means and how to use your real one.

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

## Security

The Electron bridge gets its hook into the app through Node's main-process
inspector. The inspector runs any code in the app's main process, with the
app's permissions: its files, its keychain items, its entitlements. So the
bridge keeps it open as briefly as it can, and lets nobody else in.

- **What is exposed:** the bridge starts the app with
  `--inspect-brk=PORT --inspect-publish-uid=stderr`. The inspector listens
  on `127.0.0.1:PORT`, a free port picked at random. Any local process can
  connect to the port, but attaching needs the WebSocket URL, which ends in
  a random UUID. With `--inspect-publish-uid=stderr`, the inspector prints
  that URL only to the app's stderr. Its HTTP endpoints (`/json/list`,
  `/json/version`) answer 404 instead of listing it.
- **Who sees the URL:** the app's stderr is a pipe that only the bridge
  reads. The bridge forwards every line to its own log, with the UUID
  replaced by `(hidden)`.
- **For how long:** from the launch until the hook loads. `--inspect-brk`
  holds the app at its first line until the bridge attaches. The bridge
  stops at the app's entry script and loads the hook there. The hook's last
  step closes the inspector (`require('inspector').close()`), before the
  app's own code runs. Measured from launch to a closed port: Logseq 281 ms,
  VS Code 304 ms, Reactotron 315 ms, Cursor 743 ms. Most of that is the app
  starting up before the inspector listens.
- **Only one session:** Node prints `Debugger attached.` on stderr for each
  session. The hook writes a marker to stderr right after it closes the
  inspector, so the bridge sees every session report first. A second session,
  before or after the bridge's, stops the app and fails the launch. So do an
  inspector that still accepts connections 2 seconds after injection, and a
  hook that hasn't loaded 45 seconds after launch.
- **Apps that ignore the flag:** the bridge also checks `/json/list`. An app
  whose inspector ignored `--inspect-publish-uid` is found there, as before
  the flag, and the log says so. Every Electron app tested accepts it: Electron
  27 (Reactotron, Graphite), 38 (Logseq), 42 (Cursor), and 43 (VS Code).

The failure reason goes to the adapter log and `hyprmuxctl adapters`. Users
see only that the app couldn't open.

## Writing an adapter

The executable gets the expanded `args`, plus `HYPRMUX_LAUNCH_TOKEN` and
`HYPRMUX_INSTANCE` in its environment. It must:

- Connect to Hyprmux with `HyprmuxClientKit`, or any implementation of the
  protocol. The kit sends the launch token in its `hello`, and the first
  toplevel answers the launch: it gets a tile where the launch started
  ([Launch and restore](CLIENT_PROTOCOL.md#10-launch-and-restore)).
- Create one toplevel per app window, and destroy it when the window closes.
- Exit when the app exits, and stop the app when Hyprmux disconnects or the
  adapter gets SIGTERM.
- Write a one-line reason to stderr before exiting on failure. Hyprmux keeps
  the last stderr line as the instance's note in `hyprmuxctl adapters`, and
  the whole stderr in the adapter log. Users only see that the app couldn't
  open.

## Apps that don't appear

The launcher lists only apps that can open, and never says why one is missing.
That's for developers, here. An app found in the scanned folders (see
[Generated apps](APPS.md#generated-apps)) gets no `.hmapp` when:

- **No adapter matches it,** or every match is disabled or broken. Most native
  macOS apps are in this group.
- **The selected adapter's probe fails.** Slack is one: its Electron build turns
  off the `EnableNodeCliInspectArguments` fuse, so the bridge can't inject its hook.
- **Another app has the same bundle id.** The first one found wins.
- **It isn't in a scanned folder.** Add it with `hyprmuxctl apps add NAME PATH`.

To see which case applies:

```sh
hyprmuxctl adapters match "/Applications/Slack.app"   # the choice, every candidate, and the probe
hyprmuxctl apps refresh                                # regenerate after changing an adapter
```

A probe runs once per app version, and its result is cached in `probes.json` in
the generated apps folder. Delete that file to probe every app again.

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
