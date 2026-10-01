# Plan: register the broker with SMAppService

Status: approved by the user. Implement in order. Do not commit.

## Context (read first)

Hyprmux is a tiling compositor in one macOS window (Swift, SwiftPM). App tiles
(VS Code, Zed, …) connect through an XPC client protocol (`docs/CLIENT_PROTOCOL.md`,
sections 3 and 13). Only a launchd job may own a mach service name, and Hyprmux starts
from Finder, so a tiny **broker** (`Sources/hyprmux-broker`) owns two names:
`dev.gavrix.hyprmux.compositor` (lookup, any client) and `dev.gavrix.hyprmux.registrar`
(Hyprmux only; the broker sets a peer code-signing requirement derived from its own
designated requirement). Hyprmux registers an anonymous endpoint per `HYPRMUX_INSTANCE`.

Today the broker loads only through `scripts/dev-broker.sh` (`launchctl bootstrap` of a
copy of `Resources/LaunchAgents/dev.gavrix.hyprmux.broker.plist` with an absolute
path). The bundle already ships `Contents/Library/LaunchAgents/dev.gavrix.hyprmux.broker.plist`
(`BundleProgram`, `MachServices`, `AssociatedBundleIdentifiers`) and
`Contents/MacOS/hyprmux-broker`. When the broker is missing, `ClientServer.warnIfUnavailable`
shows "Client apps need hyprmux-broker. Run scripts/dev-broker.sh load." and
`ClientServer` retries registering every 5 s.

**Goal:** a release build works with no developer steps. On launch Hyprmux registers
the bundled agent with `SMAppService.agent(plistName:)`, guides the user through the
Login Items approval when macOS asks for it, and keeps working with the dev broker.

Read `docs/DEVELOPMENT.md` (signing, test instances, "Client apps"),
`docs/ARCHITECTURE.md` ("Client apps"), `Sources/Hyprmux/Clients/ClientServer.swift`,
`Sources/hyprmux-broker/main.swift`, `scripts/bundle.sh`, `scripts/dev-broker.sh`, and
the `AGENTS.md` files (`~/.pi/agent/AGENTS.md`, `/Users/gavrix/src/github.com/gavrix/AGENTS.md`)
whose writing rules apply to docs, comments, and user-facing text.

### Decisions

1. **Register on launch, every launch** (`register()` is idempotent). Statuses:
   - `.enabled`: nothing to do.
   - `.requiresApproval`: show a Hyprmux notice once per launch: "Allow Hyprmux in
     Login Items to open apps in tiles." with an action that calls
     `SMAppService.openSystemSettingsLoginItems()`. Re-check status when Hyprmux becomes
     active again, and clear the notice once enabled.
   - `.notRegistered` after a failed `register()`: notice with the error, in plain words.
   - `.notFound`: a bundle problem (missing plist); log it, notice for developers.
2. **The dev broker keeps working and wins.** If the lookup service already answers
   (the dev broker is loaded, or a registered agent is running), don't fight it: skip
   `register()` when a broker loaded by `dev-broker.sh` holds the label
   (`launchctl print gui/UID/dev.gavrix.hyprmux.broker` shows `path` under
   `~/Library/Caches/dev.gavrix.hyprmux/`). Detect this without shelling out if possible
   (e.g. `SMAppService.status` plus a lookup ping); if shelling out to `launchctl print`
   is the only reliable way, do it off the main thread. Document the rule.
3. **Only real app bundles register.** A SwiftPM build run from `.build` (no
   `Contents/Library/LaunchAgents`) skips registration silently.
4. **Settings to opt out:** `misc:register_broker = true` (default). `false` skips
   registration (for people who manage the broker themselves). Document it.
5. **`hyprmuxctl broker [status|register|unregister] [--json]`:** status shows the
   `SMAppService` status, whether the lookup service answers, which broker program
   launchd runs (if readable), and this instance's registration with the broker.
   `register`/`unregister` call `SMAppService` (for testing and support).
6. **Messages** say what the user does, never internals ("Allow Hyprmux in Login Items…",
   not "SMAppService status 2").
7. The **Zed** decision (out of scope here): the user will publish a "Zed for Hyprmux"
   `.hmapp` from a fork as an optional download. Don't implement anything for it.

### Testing safely (read carefully)

- **Never touch the user's own Hyprmux** (`build/Hyprmux.app`, socket
  `/tmp/hyprmux-501/hyprmux.sock`) or `~/.config/hyprmux`.
- The test instance runs from `/tmp/HyprmuxTest.app` (rebundle:
  `HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh`; restart:
  `HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock /tmp/HyprmuxTest.app/Contents/MacOS/hyprmuxctl dispatch exit`,
  wait ~8 s, `sh /tmp/hm-launch.sh`). Its dev broker is loaded from
  `/tmp/HyprmuxTest.app` (`scripts/dev-broker.sh status`).
- Both Hyprmux copies share the broker label and service names. Registering the test
  bundle's agent while the dev broker holds the label can fail or collide. Test the
  `SMAppService` path like this, and nothing riskier:
  1. Record `scripts/dev-broker.sh status` and `hyprmuxctl broker status`.
  2. `scripts/dev-broker.sh unload`.
  3. Restart the test instance: it registers the test bundle's agent. Check status
     (`.enabled` or `.requiresApproval`). If approval is required, record that and do
     not try to click System Settings; the user will approve by hand later.
  4. If enabled: launch an app tile (`hyprmuxctl launch Reactotron`) to prove clients
     connect through the registered broker; close it.
  5. `hyprmuxctl broker unregister`, then `scripts/dev-broker.sh load /tmp/HyprmuxTest.app`,
     restart the test instance, and confirm tiles work as before. **Leave the system as
     you found it**: dev broker loaded from `/tmp/HyprmuxTest.app`, no registered agent
     for the test bundle.
- If step 3 can't complete non-interactively, mark it blocked with what you saw.

## Steps

- [x] 1. Read the context files. `swift build`, `swift test` baseline (expect 200 passing).
- [x] 2. `BrokerRegistration` (new file in `Sources/Hyprmux/Clients/`): status, register,
      unregister, dev-broker detection, bundle check, setting check. Called at startup
      before `startClientServer`, and on app activation while approval is pending.
- [x] 3. Notices (decision 1) through the existing HUD notice path, with the Login Items
      action. Replace the "Run scripts/dev-broker.sh load." notice: in a real bundle the
      registration flow handles it; from `.build`, keep a developer notice.
- [x] 4. `misc:register_broker` in `Config.swift` (+ default config comment, regenerate
      `DefaultConfig.swift` with `sh scripts/gen-default-config.sh`), with a test.
- [x] 5. IPC + `hyprmuxctl broker …` (parser tests; output table and `--json` like `adapters`).
- [x] 6. Broker signing check: confirm in `Sources/hyprmux-broker/main.swift` that the
      registrar requirement derived from a Developer ID or Apple Development signature
      pins the team (not just "any Apple-signed"), and that an ad-hoc broker still works
      for local builds. Fix if needed; note what the requirement string is.
- [x] 7. Docs: `docs/CLIENT_PROTOCOL.md` (sections 3 and 13: SMAppService is done),
      `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md` (dev broker vs registered agent, the
      label collision, how to test), `docs/CONFIGURATION.md` (`misc:register_broker`,
      `broker` IPC row), `docs/APPS.md` (first-launch approval, user-facing),
      `README.md` (one line on the Login Items approval if there is a natural place).
- [x] 8. `swift build`, `swift test`, rebundle the test app.
- [x] 9. Live test (section "Testing safely"). Restore the dev broker afterwards.
- [x] 10. Final report: steps done/blocked, what macOS showed (status, any approval
      notification), files changed, decisions you made.

## Notes

(Implementer: add observations here.)

- Step 1: `swift build` OK, `swift test` 200 passing. The working tree already had many
  uncommitted changes (apps catalog, adapters, …); edits below sit on top of them.
  Starting state: dev broker loaded from `/tmp/HyprmuxTest.app` (pid 56703, plist
  `~/Library/Caches/dev.gavrix.hyprmux/dev.gavrix.hyprmux.broker.plist`). The user's
  own Hyprmux (pid 47284, `build/Hyprmux.app`) and the test instance (pid 53110) run.
  Test bundle signed "Apple Development: NAME (CERT)", team TEAMID.
  macOS 26.5.2.
- Step 2: `Sources/Hyprmux/Clients/BrokerRegistration.swift`. Rule: skip outside an `.app`;
  skip when the setting is off; `.enabled` / `.requiresApproval` need nothing; otherwise, if
  the lookup service already exists (XPC ping: only `XPC_ERROR_CONNECTION_INVALID` means
  "nobody holds the name"), another broker holds the label and we skip; else `register()`.
  No shelling out at startup; `launchctl print` runs only for `hyprmuxctl broker status`.
  Runs on a background queue; `startBrokerRegistration()` is called just before
  `startClientServer()`, and `recheck()` on `didBecomeActive` while approval is pending.
  `register()` is called only when the status is neither enabled nor waiting for approval
  (decision: avoids re-registering a pending item every launch). A plist missing from an
  `.app` maps to `.notFound`, checked by file, because `SMAppService.status` also reports
  `.notFound` for agents never registered.
- Step 3: `Compositor+Broker.swift`. Notices use key `broker`, sticky. Approval: "Allow
  Hyprmux in Login Items to open apps in tiles. Click to open Login Items." (click calls
  `SMAppService.openSystemSettingsLoginItems()`), once per launch on its own, again when an
  app tile can't connect. Enabled after approval: notice dismissed, `ClientServer.retryNow()`,
  "App tiles are ready." `NotificationStack.post` gained an `action:` closure.
  `ClientServer.warnIfUnavailable` now asks the host (`clientServerUnavailable`); the old
  "Run scripts/dev-broker.sh load." text stays only for non-bundle runs.
- Step 4: `HyprmuxConfig.registerBroker`, parsed from `misc:register_broker`; comment in
  `config/hyprmux.conf`; `DefaultConfig.swift` regenerated; `testRegisterBroker`. A config
  reload that flips it re-runs the check (turning it off never unregisters).
- Step 5: `IPCRequest.broker(BrokerAction)` (`status|register|unregister`), replied off the
  main thread. `hyprmuxctl broker [status|register|unregister] [--json]` renders a
  summary. `LaunchdJob` (HyprmuxCore) parses `launchctl print`; tests in `BrokerTests.swift`
  and `IPCTests.testBrokerRequest`. Added a short broker hint to the hyprmuxctl skill.
  `swift test`: 204 passing.
- Step 6: the old code already pinned more than "any Apple-signed" for the two common cases,
  but it fell back to *identifier only* for any requirement that didn't start with
  `identifier "`, e.g. a single-word signing id, which `codesign` writes unquoted
  (`identifier dev and ...`). That fallback would let any process calling itself
  `dev.gavrix.hyprmux` register. Fixed in `Sources/hyprmux-broker/main.swift`: ad hoc is
  detected from the signing flags (identifier only, as before); otherwise the broker's
  identifier clause is swapped, quoted or not; with no swappable clause it falls back to
  `identifier "dev.gavrix.hyprmux" and (<broker DR>)` (fails closed); a team id is appended as
  `certificate leaf[subject.OU]` when the requirement lacks one. Requirement strings seen by
  running signed copies of the broker in `/tmp` (deleted afterwards):
  - Apple Development: `(identifier "dev.gavrix.hyprmux" and anchor apple generic and
    certificate leaf[subject.CN] = "Apple Development: NAME (CERT)"
    and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */) and certificate
    leaf[subject.OU] = "TEAMID"`. `/tmp/HyprmuxTest.app` satisfies it (`codesign -v -R`);
    an ad-hoc binary doesn't.
  - Developer ID: `identifier "dev.gavrix.hyprmux" and anchor apple generic and certificate
    1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate
    leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ZTL88N7JGG`
    (team pinned by Apple's own DR).
  - Ad hoc: `identifier "dev.gavrix.hyprmux"`, so local ad-hoc builds still work.
- Step 8: `swift build` clean, `swift test` 204 passing (200 + 4 new). Exited the test
  instance first, then rebundled `/tmp/HyprmuxTest.app` (signed Apple Development);
  `Contents/Library/LaunchAgents/dev.gavrix.hyprmux.broker.plist` present, `codesign -v --deep` OK.
- Step 7: `docs/CLIENT_PROTOCOL.md` (section 3: registration rule, Login Items notice,
  shared label, team in the signing requirement; section 13: SMAppService results; section 14:
  "Broker loading" replaces "isn't wired up"), `docs/ARCHITECTURE.md` ("Loading the broker"),
  `docs/DEVELOPMENT.md` ("Dev broker or registered agent": the two ways, the label rule,
  `broker` commands, the test recipe, what macOS does), `docs/CONFIGURATION.md`
  (`misc:register_broker`, `broker` IPC row), `docs/APPS.md` ("The first launch"),
  `README.md` (one sentence in "Apps in tiles"). Also `scripts/dev-broker.sh` header (one
  line on the shared label; its usage printout now stops before `set -euo pipefail`, which it
  printed before).
- Step 9 (live test):
  - First launch of the new build crashed the test instance on `hyprmuxctl broker status`:
    an Optional stored in `[String: Any]` made `JSONSerialization` throw. Fixed (only present
    values are stored) and rebundled before the real run.
  - 9.1, dev broker loaded: `broker status` showed agent `not registered` (SMAppService
    reports `.notFound` before any registration), on launch `skipped: another broker holds the
    label`, launchd job pid 56703 loaded by dev-broker.sh, instance `test` registered. So the
    dev broker wins as designed.
  - 9.2 `dev-broker.sh unload`; 9.3 restart: `register()` returned with status **enabled**
    straight away; no approval needed. launchd job: `path = (submitted by smd.7578)`,
    `type = Submitted`, `managed_by = com.apple.xpc.ServiceManagement`,
    `program identifier = Contents/MacOS/hyprmux-broker (mode: 2)`,
    `parent bundle identifier = dev.gavrix.hyprmux`. BTM posted its own notification:
    "“HyprmuxTest” can run in the background. You can manage this in Login Items &
    Extensions settings." (from the BackgroundTaskManagementAgent log; not seen on screen).
  - 9.4 `hyprmuxctl launch Reactotron`: tile connected, 4 frames, snapshot showed
    Reactotron's welcome screen. Closed; no Reactotron process left.
  - 9.5 `broker unregister`: launchd job gone, status `not-registered`, lookup no longer
    answers. `sfltool dumpbtm` still lists a BTM record for the agent, now
    `[disabled, allowed, notified]` (macOS keeps it; not removed, `sfltool resetbtm` would reset
    every app). Then rebundled (parser now recognizes SMAppService jobs and shows the broker's
    absolute path via `proc_pidpath`), `dev-broker.sh load /tmp/HyprmuxTest.app`, restarted.
    Reactotron tile connected again (4 frames) and was closed.
  - Final state: dev broker loaded from `/tmp/HyprmuxTest.app` (pid 42186, new registrar
    requirement with team), no registered agent for the test bundle, test instance running
    and registered as `test`. The user's own Hyprmux (pid 47284) was not touched; it had no
    broker between steps 9.2 and 9.5 (the broker log never showed a `default` registration).
  - Not exercised: the `.requiresApproval` notice and its Login Items click, because macOS
    never asked. It would need the user to turn the item off in System Settings.
