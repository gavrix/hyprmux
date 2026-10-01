# Plan: `.hmapp` app bundles and the in-Hyprmux launcher

Status: approved by the user. Implement in order. Do not commit.

## Context (read first)

Hyprmux is a tiling compositor in one macOS window (Swift, SwiftPM). Other processes
draw tiles through an XPC client protocol (`docs/CLIENT_PROTOCOL.md`). Apps that don't
speak it are lifted by **adapters** (`docs/ADAPTERS.md`): JSON manifests matched by
bundle id and bundle files, each with an executable (today `hyprmux-electron-bridge`
for VS Code, Cursor, and other Electron apps) and an optional probe. Read
`docs/ARCHITECTURE.md`, `docs/ADAPTERS.md`, `docs/DEVELOPMENT.md`, and the project
`AGENTS.md` files (`~/.pi/agent/AGENTS.md`, `/Users/gavrix/src/github.com/gavrix/AGENTS.md`):
their writing-style rules apply to docs, comments, and messages.

Today an app opens only through `hyprmuxctl new-surface --type app -- TARGET ARGS`
(`Compositor+Clients.swift`: `makeApp`, `resolveApp`, `launch`). Resolution: an app
with `HyprmuxClient = true` in Info.plist is a native client; otherwise the first ready
adapter that matches (`AdapterRegistry.match`, `Compositor+Adapters.swift`); otherwise
it opens as a plain app whose tile times out.

### Decisions the user made (do not revisit)

1. **Apps open from inside Hyprmux, always.** A launcher in Hyprmux is the way in.
   Apps started outside are not adopted.
2. **The launcher lists only apps that can open.** No "unsupported" entries and no
   reasons in the UI. Why an app is missing belongs in developer docs and
   `hyprmuxctl adapters match`.
3. **Everything launchable is a `.hmapp`:** a folder bundle only Hyprmux understands.
   It is not a macOS app, so Spotlight, Launchpad, and the Dock never list it.
   - **Generated** `.hmapp`s come from adapters (scan → match → probe) and from native
     clients found in the app folders. Hyprmux owns and regenerates them.
   - **Installed** `.hmapp`s are written by the user or third parties. They may point
     at anything (a dev build) or carry their own executable.
   - Adapters become rules that generate `.hmapp`s. Users never see adapters.
4. **Locations:** generated in `~/Library/Application Support/Hyprmux/Apps/`
   (a subfolder per `HYPRMUX_INSTANCE` other than `default`, like the adapter logs);
   installed in `apps/` next to the config file (normally `~/.config/hyprmux/apps/`).
   Same id in both: installed wins.
5. **Scan, don't search:** `/Applications`, `/Applications/Utilities`, `~/Applications`,
   `/System/Applications`, `/System/Applications/Utilities`, one level of subfolders
   deep in `/Applications` and `~/Applications`. No Spotlight (measured: noisy). No
   running apps.
6. **Customizing** a generated app = copy its `.hmapp` into the installed folder and
   edit `Info.json`. Regeneration never touches installed ones.
7. **Config `app = name, path` lines are not added.** `hyprmuxctl apps add` writes an
   installed `.hmapp` instead.
8. **A `.hmapp` carrying its own executable is code:** if it is quarantined (downloaded),
   check its signature or ask once before running it.
9. **Finder:** Hyprmux's Info.plist exports `.hmapp` as a package type and handles it,
   so a `.hmapp` shows as one item, and double-clicking it launches it into a tile.

### State of the working tree (uncommitted, keep it)

The last commit is `cacdf48` (client apps, adapters, Electron bridge). Uncommitted work
from the previous session is in the tree; build on it, do not revert it:

- `clients/rust/hyprmux-client/`: a Rust protocol client (used by a Zed backend in a
  separate checkout at `~/src/github.com/gavrix/zed`; do not touch that checkout).
- `hyprmuxctl snapshot [--surface ID] FILE.png`: writes an app tile's frame to a PNG
  (`ClientSurface.writeSnapshot`). Use it to see app tiles: `screencapture` does not
  work in this environment.
- `surfaces` shows `frames` (frame-pacing diagnostics) on app tiles.
- A launched executable keeps its reserved tile while it runs, up to 2 minutes
  (`appRunningTimeout`).

### Test environment

- **Never touch the user's own Hyprmux** (`build/Hyprmux.app`, socket
  `/tmp/hyprmux-501/hyprmux.sock`) or `~/.config/hyprmux`. Test only in the test
  instance (`docs/DEVELOPMENT.md`, "Testing a running app").
- Rebundle: `HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh`.
- Restart the test instance: `HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock /tmp/HyprmuxTest.app/Contents/MacOS/hyprmuxctl dispatch exit`,
  wait ~8 s, then `sh /tmp/hm-launch.sh` (starts it with `HYPRMUX_INSTANCE=test`,
  config `/tmp/hmcfg/hyprmux.conf`, session `/tmp/hm-test/session.json`,
  `HYPRMUX_ADAPTER_BIN` = the debug build dir, `HYPRMUX_HOOK_DEBUG=1`).
- The test config currently has `app { shortcuts = app }` and `bindp` on `$mod, 1/2`;
  the original is `/tmp/hmcfg/hyprmux.conf.bak`. Leave both files as they are, except
  adding a launcher bind for testing if needed (note it in Notes).
- The broker for the test instance is loaded (`scripts/dev-broker.sh`); don't unload it.
- Apps available: `/Applications/Cursor.app` (Electron, adapter `electron.cursor`),
  `/Applications/Reactotron.app` (generic `electron`), `/Applications/Slack.app`
  (matches `electron` but its probe fails → must NOT appear). VS Code is only at
  `/tmp/ee/vsc/Visual Studio Code.app` (not scanned; add it with `apps add`). An
  optimized Zed client build: `~/src/github.com/gavrix/zed/target/release-fast/zed`
  (native client when Hyprmux launches it; add with `apps add`). Do not build Zed.
- The HUD picker can't be screenshotted; verify it with `hyprmuxctl debug` (it reports
  the open picker: query, rows, selection) and `sendkey`.
- Disk is ~27 GB free. Don't create large files.

## Design

### `.hmapp` format (HyprmuxCore, new file `Sources/HyprmuxCore/HMApp.swift`)

```
Visual Studio Code.hmapp/
  Info.json
  icon.png          optional, 256 px
  …                 optional payload (an executable, say)
```

`Info.json`, format 1. Unknown keys are errors (like `AdapterManifest.parse`).

| Key | Required | Meaning |
|---|---|---|
| `format` | yes | `1` |
| `id` | yes | Unique. Generated ones use the target's bundle id. Letters, digits, `.`, `_`, `-`. |
| `name` | yes | Display name. |
| `kind` | yes | `native` or `adapter` (informational; launch uses `exec`/`app`). |
| `adapter` | when `kind` = `adapter` | Adapter id, for instance tracking (`AdapterRuntime`). |
| `app` | no | Absolute path of the `.app` it opens or lifts. Gives the icon and version. |
| `version` | no | The target's `CFBundleShortVersionString` when generated. |
| `exec` | no | Executable: absolute; relative to the `.hmapp` (contains `/`, e.g. `bin/zed`); or a bare name resolved like adapter executables (`AdapterRuntime.binDirectories`). |
| `args` | no | Default `["{args}"]`. Placeholders: `{app}` = `app`, `{bundle}` = the `.hmapp` path, `{args}` = user arguments (spliced). |
| `generatedBy` | no | `"hyprmux"` on generated ones. Only these may be rewritten or deleted by Hyprmux. |

Launch semantics: with `exec`, run it (a `Process`, as `launch()` does for
executables, with `HYPRMUX_LAUNCH_TOKEN`/`HYPRMUX_INSTANCE`). Without `exec` but with
`app`, open the `.app` bundle (native client path, `NSWorkspace`, as today). Neither:
invalid.

### The catalog

- `AppCatalog` (HyprmuxCore, pure, unit-testable): loads `.hmapp`s from the generated
  and installed folders, validates, merges by id (installed wins), reports errors per
  file (like `AdapterRegistry.errors`).
- Generation (`AppScanner`/`AppGenerator`, core where possible; probing needs
  `Compositor.runProbe`, which already runs off main and returns a result):
  1. Scan the folders in decision 5. Collect bundle id, name (`CFBundleDisplayName`,
     `CFBundleName`, file name), version, `HyprmuxClient`.
  2. Native client → generated `.hmapp` with `kind: native`, `app`, no `exec`.
  3. Else `AdapterRegistry.match` → selected adapter → if it has a probe, run it.
     Probe results are cached in the generated folder (`probes.json`, keyed by app path
     + version), so a probe runs once per app version. Pass → generated `.hmapp` with
     `kind: adapter`, `adapter`, `app`, `exec` = adapter executable, `args` = adapter
     args with `{app}` left as a placeholder. Fail → no `.hmapp`.
  4. Write only changed `.hmapp`s (compare `Info.json`). Write `icon.png` from
     `NSWorkspace.shared.icon(forFile:)` (256 px PNG). Delete generated `.hmapp`s
     (`generatedBy: hyprmux`) whose target vanished or no longer qualifies. Never touch
     anything else.
- **When:** in the background at startup (after adapters load), on config reload,
  on `hyprmuxctl apps refresh`, and when the launcher opens (cheap: rescan, only
  changed apps re-probe). Publish catalog updates on the main thread. The launcher
  shows the current catalog immediately.
- Recent launches: `recent.json` in the generated folder, id → last launch time.

### Launching entries

- `Compositor.launchEntry(id: String, args: [String]) throws -> ClientSurface`
  building an `AppCommand` from the entry and reusing `launch(_:argument:into:timeout:)`.
  Adapter-kind entries register an `AdapterInstance` (adapter id from the entry) so
  `hyprmuxctl adapters` keeps showing them. Record the launch in `recent.json`.
- `ClientSurface` / session: remember the entry id. Add `appEntry: String?` to
  `SessionTile` (keep `app` for old sessions); restore launches by entry id, falling
  back to the old launch string. Unknown entry on restore → the existing "couldn't
  restore" notice.
- `new-surface --type app PATH.hmapp` launches that bundle.

### Interfaces

- IPC + `hyprmuxctl`:
  - `apps [list] [--json]`: table ID, NAME, KIND, SOURCE (generated | installed),
    ADAPTER, APP/EXEC; plus load errors and the two folders. JSON has everything.
  - `apps refresh`: regenerate now; reply when done (run the work off main like
    `adapters match` does, via `IPCReply.background`).
  - `apps add NAME PATH [ARGS…]`: write an installed `.hmapp` to the installed folder.
    PATH an `.app` → classify it like generation (native or adapter, probe included;
    refuse with a plain message if it can't open). PATH anything else → `exec` = PATH.
    Id: the bundle id for apps, else `user.<slug-of-name>`. Reply with the entry.
  - `launch NAME|ID [ARGS…]`: launch an entry into a new tile, reply like
    `new-surface` (the surface JSON). Match id first, then name (case-insensitive).
- Dispatchers (HyprmuxCore `Dispatcher`, config parsing): `launch, NAME|ID` and a new
  picker kind `picker, apps`.
- Default config (`config/hyprmux.conf`, then `sh scripts/gen-default-config.sh`):
  `bind = $mod, D, picker, apps` (D is free in the user's config; don't edit the user's
  config). Keep the generated `DefaultConfig.swift` in sync (a test checks it).
- **Launcher picker:** follow the existing HUD pickers (`PickerKind`, `HUD`,
  `PickerView`; read how the workspace and layout pickers are built and keyboard-driven).
  Rows: icon + name. Fuzzy filter on name. Sort: recent launches first, then name.
  Enter launches into a new tile on the current workspace and closes the picker.
  Escape closes. Empty catalog: one disabled row "No apps".
- **Finder:** `Resources/Info.plist`: `UTExportedTypeDeclarations` for
  `dev.gavrix.hyprmux.hmapp` (extension `hmapp`, conforms to `com.apple.package`), and
  `CFBundleDocumentTypes` (role Viewer, `LSHandlerRank` Owner, `LSTypeIsPackage`).
  `AppDelegate` handles opened URLs (`application(_:open:)`): load the `.hmapp`
  from its path and launch it.
- **Trust (decision 8):** before running an `exec` that resolves inside a `.hmapp`
  carrying `com.apple.quarantine`: valid code signature (`SecStaticCodeCheckValidity`)
  → run; else ask once with an `NSAlert` naming the app; remember the answer in
  `trust.json` (generated folder) keyed by path + file modification date. Generated
  `.hmapp`s and ones whose `exec` is outside the bundle skip this.

### Docs

- New `docs/APPS.md`: what a `.hmapp` is, the format table, the two folders and
  precedence, generation (what gets generated and when), customizing by copying,
  `hyprmuxctl apps`, `launch`, the launcher, Finder, trust. Users see apps, not adapters.
- `docs/ADAPTERS.md`: adapters generate `.hmapp`s; add "Apps that don't appear"
  (point to `hyprmuxctl adapters match`). Probe failures are explained here, not in the UI.
- `docs/CONFIGURATION.md`: `picker, apps`, `launch` dispatcher, IPC rows for `apps`
  and `launch`.
- `docs/ARCHITECTURE.md`: the catalog and where it lives.
- `docs/DEVELOPMENT.md`: generated apps are per `HYPRMUX_INSTANCE`; testing the launcher.
- `.agents/skills/hyprmuxctl/SKILL.md`: `apps`, `launch`.
- `README.md`: one short mention if there is a natural place.

## Steps

- [x] 1. Read the context docs, `AGENTS.md` files, and the code named above
      (`Compositor+Clients.swift`, `Compositor+Adapters.swift`, `Adapters.swift`,
      `Session.swift`, `Compositor+Session.swift`, `IPC.swift`, `Dispatcher.swift`,
      `Config.swift`, the HUD picker code, `hyprmuxctl/main.swift`). Run `swift build`
      and `swift test` to confirm the baseline (expect 174 tests passing).
- [x] 2. `HMApp.swift` in HyprmuxCore: the manifest type, `parse` with validation,
      `write`, placeholder expansion, exec resolution. Unit tests: valid/invalid
      manifests, unknown keys, exec resolution (absolute, relative, bare), args
      expansion with `{app}`, `{bundle}`, `{args}`.
- [x] 3. `AppCatalog` in HyprmuxCore: load both folders, merge (installed wins),
      errors per file. Unit tests with temp folders.
- [x] 4. Scanner + generator: scan (testable with fake `.app` bundles in temp dirs:
      `Contents/Info.plist` with bundle id, name, version, `HyprmuxClient`), classify
      (native / adapter via `AdapterRegistry` / none), probe cache, write/diff/delete
      generated bundles, icons. Inject the probe as a closure so tests don't spawn
      processes. Unit tests: generation creates, updates on version change, deletes
      vanished apps, never touches non-generated bundles, probe failure → nothing.
- [x] 5. App runtime in Hyprmux (new `Compositor+Apps.swift`): folders (per instance),
      background generation at startup/reload, catalog on main, recent launches,
      `launchEntry`, session `appEntry`, `new-surface --type app X.hmapp`.
- [x] 6. IPC + `hyprmuxctl`: `apps [list|refresh|add]`, `launch`, with tables and
      `--json` like `adapters`. Parser unit tests.
- [x] 7. Dispatchers `launch` and `picker, apps`; config parsing tests; default config
      bind + regenerated `DefaultConfig.swift`.
- [x] 8. The launcher picker in the HUD.
- [x] 9. Finder integration (Info.plist types, `application(_:open:)`) and the trust check.
- [x] 10. Docs (list above) and the skill.
- [x] 11. `swift build`, `swift test` (all pass), rebundle the test app.
- [x] 12. Live verification in the test instance (restart it first):
      - `hyprmuxctl apps`: Cursor and Reactotron generated (adapter), Slack absent.
        Generated folder is the test instance's own.
      - `hyprmuxctl apps add "Visual Studio Code" "/tmp/ee/vsc/Visual Studio Code.app"`
        → installed adapter entry; `apps add "Zed (dev)" ~/src/github.com/gavrix/zed/target/release-fast/zed`
        → installed exec entry.
      - `hyprmuxctl launch "Zed (dev)" /tmp/zedtest`: a tile connects (allow ~20 s);
        `hyprmuxctl snapshot` shows Zed. `hyprmuxctl launch Reactotron`: connects.
      - Launcher: add `bind = $mod, D, picker, apps` to the test config if missing (it
        reloads live), `sendkey SUPER, D`, check `hyprmuxctl debug` shows the apps
        picker with rows, type a filter with `sendkey`, Enter launches, a new tile
        appears. Escape closes it.
      - Restart the test instance: the launched app tiles restore by entry id.
      - Copy a generated `.hmapp` into `/tmp/hmcfg/apps/`, rename it in `Info.json`,
        `apps refresh`: the installed one wins.
      - `open -a /tmp/HyprmuxTest.app some.hmapp` is optional (LaunchServices may
        route to the user's own Hyprmux, which must not happen; skip if unsure and
        note it).
      Close the tiles you opened at the end (`close-surface`), leave the test instance
      running.
- [x] 13. Final report (see your agent instructions). List any decision you had to make.

## Notes

(Implementer: add observations here as you go.)

- Step 1: baseline `swift build` OK, `swift test`: 174 XCTest tests pass, 0 failures. No project-level
  `AGENTS.md` in the repo; the global ones apply. Test instance is running (pid 37159).
- Step 2: `Sources/HyprmuxCore/HMApp.swift` (`HMAppManifest`, `HMApp`, `HMAppSource`). Exec resolution
  reuses `AdapterRegistry.resolveExecutable` (bare names: bin dirs, then the bundle). `encoded()` writes
  sorted keys without escaped slashes and leaves out default `args`, so unchanged manifests compare equal.
  9 tests in `HMAppTests.swift`.
- Step 3: `Sources/HyprmuxCore/AppCatalog.swift`. Duplicate ids in one folder are errors; `find` matches
  id, then name (case-insensitive), then id (case-insensitive). `launcherOrder` = recent first, then name.
  4 tests in `AppCatalogTests.swift`.
- Step 4: `Sources/HyprmuxCore/AppGenerator.swift` (`AppScanner`, `AppClassification`, `AppGenerator`).
  Probe and icon are injected closures; the app passes `Compositor.runProbe` and an `NSWorkspace` icon
  (step 5). Probe cache `probes.json` is keyed by app path + version + adapter id. Generated folder names
  are `NAME.hmapp`; if that name is taken by a bundle Hyprmux doesn't own, `NAME (ID).hmapp`. An adapter
  with a bare `exec` keeps the bare name in the generated `.hmapp`, so it resolves through the bin
  directories at launch. 7 tests in `AppGeneratorTests.swift`.
- Step 5: `Sources/Hyprmux/Compositor/Compositor+Apps.swift` (`AppRuntime` + Compositor extension).
  Generated folder: `~/Library/Application Support/Hyprmux/Apps[/INSTANCE]`; `recent.json`, `trust.json`,
  `probes.json` live there. `start()` loads the catalog from disk before session restore, then refreshes
  in the background; config reload does the same. Refreshes coalesce: one running, one queued.
  Launch tracking: `ClientServer` now keeps a `Launch` (argument, or entry id + args) per token, and stamps
  every toplevel of that launch, so extra windows of an entry launch also restore by id.
  `AppCommand.adapter: AdapterEntry?` became `adapterID: String?` (an installed `.hmapp` may name an adapter
  the registry doesn't have; instance tracking only needs the id). `SessionTile` gained `appEntry` and
  `appArgs`; entry tiles save no `app` string. `new-surface --type app X.hmapp` (and Finder) launch by path
  and restore by path, through `resolveApp`.
- Step 6: IPC `apps [list|refresh]`, `apps add --base64 <shell words>`, `launch [--focus] (--base64 B64 | NAME…)`.
  `apps refresh` and `apps add` (probe) reply via `IPCReply.background`. `hyprmuxctl apps` renders a table
  (ID, NAME, KIND, SOURCE, ADAPTER, APP/EXEC), load errors, and both folders; `apps add` prints one line.
  `apps --json` adds a `generation` summary (counts only; probe reasons stay in `adapters match`).
- Step 7: `Dispatcher.launch(String)` → `Effect.launch`; `PickerKind.apps`; keycast labels "Open X" and
  "Apps". A bind's text names an app whole, or its first shell word does and the rest are arguments; an
  empty `launch` opens the launcher. Default config: `bind = $mod, D, picker, apps`, DefaultConfig.swift
  regenerated. Tests in `AppRequestTests.swift` (6). `swift test`: 200 tests, 0 failures.
- Step 8: `presentAppLauncher` (Compositor+Apps). `Picker.emptyText` (core) draws the disabled "No apps"
  row; Enter on it beeps. `PickerPresenter.present(_:icons:)` and `PickerListView.icons` draw an icon
  per row (the bundle's `icon.png`, else the target's Finder icon). Opening the launcher starts a background
  refresh; an open launcher doesn't update live when that refresh lands (it shows the catalog as it was).
- Step 9: `Resources/Info.plist` exports `dev.gavrix.hyprmux.hmapp` (conforms to `com.apple.package`) and
  claims it (Viewer, Owner, `LSTypeIsPackage`). `AppDelegate.application(_:open:)` launches each `.hmapp`
  via `openHMApp` (queued until the compositor starts). Trust: only installed bundles whose `exec`
  resolves inside the bundle and that carry `com.apple.quarantine` (bundle or executable) are checked.
  Signature requirement: `anchor apple generic` (a certificate Apple issued); ad-hoc signatures don't
  count. Otherwise one `NSAlert`; the answer is kept in `trust.json` by executable path + mtime.
- Step 10: new `docs/APPS.md`; `docs/ADAPTERS.md` (adapters generate apps; "Apps that don't appear");
  `docs/CONFIGURATION.md` (`launch`, `picker, apps`, IPC rows, `apps/` folder, `app` section intro);
  `docs/ARCHITECTURE.md` ("The app catalog" under Client apps; `.hmapp` as a TARGET);
  `docs/DEVELOPMENT.md` (per-instance generated apps, testing the launcher); skill `launch`/`apps`;
  README "Apps in tiles" bullet.
- Step 11: `swift build` clean (no warnings in new code), `swift test`: 200 tests, 0 failures (174 before).
  Rebundled `/tmp/HyprmuxTest.app` (signed with the Apple Development identity). `build/Hyprmux.app` untouched.
- Step 12 (test instance only; restarted with `dispatch exit` + `/tmp/hm-launch.sh`):
  - `apps`: 5 generated, all `adapter`: Appium Inspector, Cursor (`electron.cursor`), Graphite, Logseq,
    Reactotron (`electron`). Slack and Descript absent (probe: `EnableNodeCliInspectArguments` fuse off).
    First generation: 113 apps scanned, 7 probed, 108 skipped, 256 KB written. Folder:
    `~/Library/Application Support/Hyprmux/Apps/test/` (the `default` instance's folder has nothing else).
  - `apps add "Visual Studio Code" "/tmp/ee/vsc/Visual Studio Code.app"` → installed, adapter
    `electron.vscode`, id `com.microsoft.VSCode` (0.29 s, probe included). `apps add "Zed (dev)" …/zed` →
    installed native exec entry `user.zed-dev`. `apps add Slack /Applications/Slack.app` refuses with the
    probe reason, exit 1. Both written to `/tmp/hmcfg/apps/` (created by `apps add`).
  - The old session's Zed tile (saved before this change, `app` launch string) restored through the old
    path and connected. I closed it and sent SIGTERM to its Zed (a child of the test instance; Zed keeps
    running with no windows), so the next launch wouldn't hand off to it.
  - `launch "Zed (dev)" /tmp/zedtest`: tile connected within 5 s; `snapshot` showed Zed with notes.txt.
    `launch Reactotron`: connected; `adapters` shows the instance (`electron`, running).
  - Launcher: added `bind = $mod, D, picker, apps` to `/tmp/hmcfg/hyprmux.conf` (left in place). `sendkey
    SUPER, D` → `debug` shows `apps` picker, rows recent-first (Reactotron, Zed (dev), then by name). Typing
    `c`,`u` → rows `[Cursor]`. Return → Cursor tile connected, focused, workspace 1. Reopened, Escape →
    picker closed, keyboard back on the terminal.
  - Restart: session saved `appEntry` (+ `appArgs` for Zed); after relaunch all three tiles (Cursor,
    Reactotron, Zed) reconnected by entry id.
  - Copied `Reactotron.hmapp` to `/tmp/hmcfg/apps/`, renamed to "Reactotron (mine)", `apps refresh` →
    listed as `installed*`, generated copy untouched. Removed the copy afterwards.
  - `new-surface --type app /tmp/hm-demo.hmapp` (exec inside the bundle, the debug demo client) connected;
    restores by path. Removed `/tmp/hm-demo.hmapp` afterwards.
  - Trust: not exercised live (the `NSAlert` would appear on the user's screen). The signature check
    itself, run standalone: ad-hoc demo binary → false; Cursor (Developer ID) → true; the test bundle's
    `hyprmuxctl` (Apple Development) → true.
  - `open -a /tmp/HyprmuxTest.app some.hmapp`: skipped. Both bundles share `dev.gavrix.hyprmux`, so
    LaunchServices could route the open to the user's own Hyprmux.
  - Cleanup: closed tiles 2–5; Reactotron's bridge exited by itself, Cursor's bridge and Zed kept running
    without windows, so I sent them SIGTERM (children of the test instance). Test instance left running
    with its one terminal.
- Decisions made while implementing (not in the plan):
  - Display name follows the plan's order (CFBundleDisplayName, CFBundleName, file name), so a VS Code in
    /Applications would be generated as "Code". Its file name, which Finder shows, may be preferable.
  - Signature rule for trust is `anchor apple generic`; ad-hoc signatures don't pass.
  - "Remember the answer" stores both yes and no; a no is final until `trust.json` is edited or the
    executable changes.
  - `apps add` replaces an installed app with the same id in place (keeps its folder name).
  - IPC `launch` doesn't take focus unless `--focus` (like `new-surface`); the launcher and the `launch`
    dispatcher focus the new tile.
  - An open launcher doesn't update when its background refresh finishes.
  - `docs/CLIENT_PROTOCOL.md` section 10 claimed an `app` dispatcher that doesn't exist; it now names the
    launcher, `hyprmuxctl launch`, and the `launch` dispatcher.
