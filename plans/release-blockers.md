# Plan: last release blockers for app tiles

Status: approved by the user. Implement in order. Do not commit.

## Context (read first)

Hyprmux (Swift, SwiftPM) is a tiling compositor in one macOS window. Apps open as tiles
through an XPC client protocol. Read `docs/APPS.md`, `docs/ADAPTERS.md`,
`docs/ARCHITECTURE.md` ("Client apps"), `docs/DEVELOPMENT.md`, the two previous plans in
`plans/` (their Notes describe the current state), and the `AGENTS.md` files
(`~/.pi/agent/AGENTS.md`, `/Users/gavrix/src/github.com/gavrix/AGENTS.md`): their
writing rules apply to docs, comments, and every user-facing string.

Apps are `.hmapp` entries (generated from adapters, or installed). Electron apps run
through `Sources/hyprmux-electron-bridge` (`Bridge.swift`, `Injector.swift`) with
`Resources/electron-hook.js` injected through the main-process inspector. The launcher
is `picker, apps` (default bind `$mod, D`). The working tree has a lot of uncommitted
work from earlier sessions: keep all of it.

**User decision that matters here:** the UI never explains internals. Users see apps
that can open; why something fails belongs in `hyprmuxctl` output, logs, and developer
docs.

### Test environment

- **Never touch the user's own Hyprmux** (`build/Hyprmux.app`, socket
  `/tmp/hyprmux-501/hyprmux.sock`) or `~/.config/hyprmux`.
- Test instance: `/tmp/HyprmuxTest.app`. Rebundle with
  `HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh`. Restart with
  `HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock /tmp/HyprmuxTest.app/Contents/MacOS/hyprmuxctl dispatch exit`,
  wait ~8 s, then `sh /tmp/hm-launch.sh`. The dev broker is loaded from the test bundle;
  leave it loaded. `HYPRMUX_ADAPTER_BIN` points at the debug build, so a rebuilt bridge
  (`swift build --product hyprmux-electron-bridge`) applies to new launches without
  rebundling; the hook loads from the repo.
- Use `hyprmuxctl launch NAME`, `hyprmuxctl adapters`, `hyprmuxctl snapshot`, and the
  adapter logs in `~/Library/Logs/Hyprmux/adapters/test/`. `screencapture` doesn't work
  here. Electron apps on this machine: Reactotron, Cursor, Logseq, Graphite (generated),
  VS Code at `/tmp/ee/vsc` (installed entry). Slack fails the probe.
- Close tiles you open; leave the test instance running.

## Steps

- [x] 1. Baseline: read the files above; `swift build`; `swift test` (expect 204 passing).

- [x] 2. **Close the inspector window.** Today the bridge starts the app with
      `--inspect-brk=PORT` on 127.0.0.1, attaches over CDP, injects the hook, and the hook
      closes the inspector after a 2 s timer. Until then any local process could discover
      the WebSocket URL from `http://127.0.0.1:PORT/json` and attach. Make it:
      - **Hide the URL:** add `--inspect-publish-uid=stderr` so the HTTP endpoints don't
        publish the WebSocket UUID; read the `Debugger listening on ws://…` line from the
        app's stderr instead (the bridge must pipe and forward the app's stderr to its
        own, keeping today's logging). Verify each Electron app on this machine accepts
        the flag (Reactotron is Electron 27, VS Code 43). If an app rejects it, fall back
        to today's behavior for that app and note which.
      - **Close it at once:** the hook calls `require('inspector').close()` as soon as it
        loads (after it has what it needs), not on a 2 s timer. Confirm the port no longer
        accepts connections right after injection (`curl -s 127.0.0.1:PORT/json` fails).
      - **Detect a race:** if CDP reports another session or the bridge fails to be first,
        stop the app and fail the launch.
      - Document the model in `docs/CLIENT_PROTOCOL.md` (Electron bridge) and
        `docs/ADAPTERS.md` ("Security" subsection): what is exposed, for how long, why.

- [x] 3. **Clean failure messages.** `Compositor+Clients.swift` shows
      `"\(label): \(stderr last line)"` when a launch fails; for adapters that leaks
      internals (Slack's fuse message). Change user-facing notices to plain sentences:
      "Couldn't open NAME." or, for a timeout, "NAME didn't open." Keep the detail where
      developers look: `AdapterInstance.lastError`/`failure`, the adapter log, and
      `hyprmuxctl adapters`. Apply to restores too ("Couldn't reopen NAME."). Check every
      `flash(...)` and notice reachable from app launching for leaked internals (paths,
      flags, "adapter", "fuse", "inspector") and fix them. Verify with
      `hyprmuxctl new-surface --type app /Applications/Slack.app` (it bypasses the
      catalog) that the notice is clean and `hyprmuxctl adapters` still has the reason.

- [x] 4. **"Open App…" menu item.** Existing configs lack the launcher bind, so add an
      "Open App…" item to Hyprmux's app menu (`App.swift`, `buildMenu`) that opens the
      apps picker. No key equivalent (binds own the keyboard), but show the bound chord if
      one exists, if the menu code makes that easy. Mention it in `docs/APPS.md`
      ("The launcher").

- [x] 5. **README section "Apps in tiles"** (user-facing, short): open apps with the
      launcher or "Open App…"; which apps work (native clients, VS Code/Cursor/most
      Electron apps); first-launch Login Items approval; separate profiles (link to
      `docs/APPS.md#profiles`); shortcuts (binds win; rebind in the app or use pass
      lists); known limitations: no drag and drop in Electron apps; Electron apps' own
      menu bar isn't reachable (use the command palette); some apps can't open at all
      (they don't appear). Link `docs/APPS.md`. Zed: say it's coming as an optional
      download, nothing more.

- [x] 6. `swift build`, `swift test` (all pass), rebundle, restart the test instance.
      Live checks: launch Reactotron and VS Code (inspector closed right after injection,
      tiles render); the Slack notice is clean; "Open App…" opens the picker
      (`hyprmuxctl debug` shows it). Record results in Notes.

- [x] 7. Final report: steps done/blocked, which apps accept `--inspect-publish-uid`,
      the inspector-open window you measured (ms from launch to close), files changed,
      decisions you made.

## Notes

(Implementer: add observations here.)

- Step 1: `swift build` OK; `swift test` 204 passing, 0 failures. Read APPS, ADAPTERS,
  ARCHITECTURE ("Client apps"), DEVELOPMENT, both earlier plans, and the AGENTS.md files.
  No AGENTS.md inside the repo. Test instance was running (5 surfaces, no app tiles).
- Step 2:
  - Flag check, raw launch with `--inspect-brk=P --inspect-publish-uid=stderr` (app paused at
    its first line, then killed): Reactotron (Electron 27.0.3), VS Code (43.7.3), Cursor
    (42.10.0), Logseq (38.4.0), Graphite (27.0.0) all print `Debugger listening on ws://…` on
    stderr and answer 404 on `/json/list` and `/json/version`. Without the flag Reactotron lists
    the URL (200). No app needed the fallback.
  - Node prints `Debugger attached.` on stderr once per session (checked with two sessions on
    Reactotron), and `Debugger ending on ws://…` when the last one leaves. That is the session
    report the bridge counts; CDP itself has no event for other sessions.
  - `require('inspector').close()` called inside the bridge's `evaluateOnCallFrame` (paused)
    works: the WebSocket closes with no reply, the port closes, the app runs on. So the hook
    closes it synchronously as its last top-level step, then writes the marker
    `hyprmux-hook: inspector closed` to fd 2.
  - New `Sources/hyprmux-electron-bridge/InspectorWatch.swift`: reads the app's stderr pipe on a
    thread, takes the URL (only for our port), counts sessions until the marker, forwards every
    line to the bridge's stderr with the UUID shown as `(hidden)`.
  - `Injector.swift`: takes the URL from stderr, with `/json/list` as the fallback (logs
    "ignored --inspect-publish-uid" if used, or "also lists its inspector over HTTP"); treats
    the connection closing during the hook's `require` as success. Also fixed two lost-wakeup
    races (a reply or pause arriving before its continuation was registered); state is locked.
  - `Bridge.swift`: pipes the app's stderr; refuses (stops the app, exit 1) on a second session,
    on a port that still accepts 2 s after injection, or if the hook isn't in after 45 s.
    Logs `inspector closed N ms after launch`. Fixed: `stopApp(exitCode: 1)` used to end with
    status 0 because the app's termination handler called `exit(0)`.
  - Measured launch → closed port (through the test instance): Logseq 281 ms, VS Code 304 ms,
    Reactotron 315 ms, Cursor 743 ms. Before: inspector open until the hook's 2 s timer, with
    the URL on `/json/list`. All four tiles rendered (snapshots of Reactotron and VS Code).
  - Race test: a copy of the hook (`HYPRMUX_ELECTRON_HOOK=/tmp/hook-race.js`) that prints an
    extra `Debugger attached.` before closing → bridge logged "another debugger attached to
    Reactotron's inspector; stopping Reactotron", app stopped, exit 1.
  - Docs: `docs/ADAPTERS.md` new "Security" section (after "Probe"), and "Writing an adapter"
    now says the stderr reason goes to `hyprmuxctl adapters` and the log, not users;
    `docs/CLIENT_PROTOCOL.md` section 11, Electron bridge, "Injection" bullet.
- Step 3:
  - `Compositor+Clients.swift`: `AppLaunchError` gained `notice` (user text; `message` stays for
    `hyprmuxctl`). New `launchFailureNotice(_:name:restoring:)`. `appLaunchFailed` now takes a
    developer reason (logged as `app NAME didn't open: REASON`, subsystem `dev.gavrix.hyprmux`) and
    a notice: "Couldn't open NAME." (exit before connecting, `NSWorkspace` error), "NAME didn't
    open." (timeout), "Couldn't reopen NAME." (any restore failure; `launch(restoring:)`). Restore
    names the app by its catalog name, else the saved title.
  - Other launch paths now use the same notices: the launcher's Enter, the `launch` dispatcher,
    Finder/`open` of a `.hmapp`. Trust refusals say "Didn't open NAME: you chose not to trust it."
    or "Didn't open NAME." `launch` with an unknown name: "No app named X."
  - Broker notices reachable from a launch: `.disabled` → "Apps can't open in tiles while
    misc:register_broker is off. Turn it on, or start the helper yourself."; `.otherBroker` →
    "Apps can't open in tiles right now. hyprmuxctl broker status says why." Left as they were:
    `.notBundled` (dev builds from `.build`, names `scripts/dev-broker.sh`), `.notFound` (broken
    bundle), `.failed` (shows macOS's error; both decided in the broker plan).
  - IPC replies (`new-surface`, `launch`, `apps add`) keep their detailed `error:` text: that is
    `hyprmuxctl` output.
  - Live: `new-surface --type app /Applications/Slack.app` → notice "Couldn't open Slack." (from
    the notice log line); `hyprmuxctl adapters` instance #1 `exited` with the note "…Slack disables
    the main-process inspector (EnableNodeCliInspectArguments)…" and the log path.
    `/usr/bin/false` → "Couldn't open false.", log "exited with status 1". Timeout path not run
    live (needs a process that runs 2 minutes without a window).
  - Docs: APPS.md new "When an app doesn't open", "Sessions" names the new notice;
    ARCHITECTURE.md "Launching" lists the three notices.
- Step 4:
  - `App.swift`: "Open App…" between About and Open Config…, action `openAppLauncher` →
    `presentAppLauncher()`, no key equivalent. Chord not shown: AppKit draws the shortcut column
    only for a real key equivalent, and faking it (attributed title, tab stops) isn't easy or
    native-looking. Decision noted for the human.
  - To verify it without clicking, added the test command `sendmenu TITLE` (IPC + `hyprmuxctl`
    usage, `Compositor.performMenuItem`, parser test `testSendMenuRequest`; docs in
    CONFIGURATION.md IPC table and DEVELOPMENT.md "Test tools"). Live: `sendmenu "Open App..."` →
    `debug` shows the `apps` picker with 7 rows; Escape closed it, focus back on the terminal.
  - APPS.md: intro and "The launcher" mention Hyprmux → Open App….
- Step 5: README: new "## Apps in tiles" section after "Quick start" (launcher and Open App…,
  which apps, first launch and Login Items, profiles link, shortcuts with a link to the `app`
  pass lists, three limitations, Zed one line, link to docs/APPS.md). The Features bullet now
  points to it; ⌘D added to the Quick start table; Apps added under Documentation. The command
  palette hint says F1, because ⇧⌘P is a default Hyprmux bind (`picker, movetoworkspace`).
- Step 6: `swift build` clean (no new warnings), `swift test` 205 passing (204 + `testSendMenuRequest`).
  Exited the test instance, rebundled `/tmp/HyprmuxTest.app` (Apple Development), relaunched with
  `/tmp/hm-launch.sh`.
  - Reactotron: `/json/list` → 404 while the inspector was open; `curl 127.0.0.1:PORT/json` →
    connection refused right after the bridge logged the close; "inspector closed 367 ms after
    launch"; one `Debugger attached.`; snapshot shows the welcome screen.
  - VS Code: same, 404 then refused; 397 ms; snapshot shows the editor (AUTOMATION.md).
  - Slack via `new-surface --type app /Applications/Slack.app`: notice "Couldn't open Slack.";
    `adapters` instance #3 `exited` with the fuse reason and the log path.
  - `sendmenu "Open App…"` → `debug` shows the `apps` picker (7 rows); Escape closed it.
  - Cleanup: closed tiles 5 and 6; no bridge or app processes left (the Slack process running is
    the user's own, pid 776, started long before). Test instance left running with its 4 original
    surfaces. Dev broker still loaded from `/tmp/HyprmuxTest.app` (pid 42186). Deleted my temp
    files (`/tmp/hook-race.js`, snapshots, `/tmp/cdpx`).
  - Inspector-open window across runs (launch → port refused): Logseq 281 ms, VS Code 304/397 ms,
    Reactotron 315/367 ms, Cursor 743 ms.
- Step 7: final report given in the session.

