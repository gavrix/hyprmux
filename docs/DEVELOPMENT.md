# Development

How Hyprmux is built, tested, and changed. This is the working style it was
developed with: the rules exist because each one prevented a real bug or a
disrupted session.

## Build and run

```sh
scripts/fetch-ghosttykit.sh   # libghostty (pinned, checksummed)
scripts/fetch-cef.sh          # Chromium SDK; needed to build even if you use WebKit
                              # (bundle.sh runs both)
swift build                   # all targets; resolves grpc-swift and SwiftProtobuf
swift test                    # core and Android discovery tests
scripts/bundle.sh             # build/Hyprmux.app (debug); `scripts/bundle.sh release` for release
open build/Hyprmux.app
```

`bundle.sh` does four things:

- regenerates the embedded default config;
- builds the app and the Chromium helper;
- assembles the bundle: Info.plist, the checked-in Ghostty runtime resources,
  and the CEF framework plus helper apps when `vendor/cef` exists;
- signs it ad hoc.

The framework copy is an APFS clone, so bundling takes a few seconds.

Android Emulator protobuf and gRPC Swift files are checked in under
`Sources/AndroidEmulatorBridge/Generated`. Normal builds do not run `protoc`.
After editing the wire-compatible subset, run
`scripts/gen-android-emulator-protos.sh`. The script uses generators from PATH
or dependency checkout builds. The subset must retain the field numbers from
the installed SDK's `emulator/lib/emulator_controller.proto`.

## Demo recording

The README's demo is recorded by a script, so it can be redone after a feature or
styling change:

```sh
scripts/demo/record.sh              # -> docs/media/demo.mp4 and demo.gif
scripts/demo/record.sh --rehearse   # play it without recording; the instance stays open
scripts/demo/publish.sh             # put the new video in the README
scripts/demo/record.sh --clip intro # one short clip for posting -> build/clips/intro.mp4
scripts/demo/record.sh --clip all   # every clip in scripts/demo/clips/
```

**Clips** (`scripts/demo/clips/*.sh`) are short, 16:9 (1600x900) videos for
posting, one feature each: `intro`, `config`, `workspaces`, and `simulator`. Each
defines `play()` and optionally `setup()`, which runs before recording starts, and
`teardown()`, which runs after it stops. Helpers such as `key`, `type_line`, and
`caption` come from `lib.sh`. `caption "Title | subtitle"` shows a caption panel
at the top of the window (the `caption` IPC command); `caption` with no text
hides it. The simulator clip creates a throwaway simulator and deletes it
afterwards. It opens the simulator by UDID (`launch --window ios:UDID Mobile`),
because ⌘I would offer every booted
one. For the config clip, record.sh writes the default config and the demo
overrides into one file, `/tmp/hyprmux-demo/hyprmux.conf`, so nvim can edit it
and each save reloads live.

GitHub plays a README video inline only when it's hosted as an attachment, not
as a file in the repo. `publish.sh` posts `demo.mp4` to the repo's "README media"
issue (`gh issue comment --attach`) and points the README at the new attachment.
Commit the README, the MP4, and the GIF afterwards.

- **`scenario.sh`** is the demo: the real default shortcuts, text typed into
  terminals, and pauses. The demo config turns on `hud:keycast`, so each
  shortcut shows on screen as it's pressed. Edit it to show something new.
- **`hyprmux.conf`** is the default config plus a few overrides: no
  follow-mouse, no session restore, WebKit, and a plain `zsh` in a fake project
  under `/tmp/hyprmux-demo`.
- **`zsh/.zshrc`** gives that shell a neutral prompt and no pager.
  `HYPRMUX_WINDOW_SIZE` (default 1440x900) fixes the window size.
- **`recorder.swift`** records only the Hyprmux window with ScreenCaptureKit
  (even when covered, without the cursor), and `ffmpeg` turns the result into an
  MP4 and a GIF. `record.sh` wraps it in a small signed app, "Hyprmux Demo
  Recorder" (`.build/demo/`), started with `open`, so it has its own Screen
  Recording permission. Allow it once in System Settings → Privacy & Security →
  Screen & System Audio Recording.
- **It plays in the background.** Pickers take keys without the app in front,
  so your keyboard and focus stay yours. In demo mode (`HYPRMUX_WINDOW_SIZE`)
  the window floats above others, because macOS stops drawing covered windows,
  and has no title bar, because macOS badges a captured window's title bar.
- **The web tile** loads the demo page from a local server on a free port, so
  no file path shows in its address bar.

## Signing

macOS ties privacy permissions (Screen Recording, Accessibility, folder access)
to an app's signature. An ad-hoc signature changes with every build, so each
rebuild silently loses them. Anything that runs inside Hyprmux loses them too,
because its shells inherit Hyprmux's identity: `screencapture` stopped working
this way. Sign with a stable identity and a permission granted once stays
granted.

`scripts/bundle.sh` signs the app, bundled `hyprmuxctl`, Chromium framework,
and helper apps with the first of:

1. `HYPRMUX_SIGN_IDENTITY`;
2. the first line of `.sign-identity` in the repo (untracked), for example
   `Apple Development: Your Name (XXXXXXXXXX)`;
3. "Hyprmux Local Signing", if it exists;
4. ad hoc, with a warning.

**With an Apple developer account** (a free personal team works): in Xcode, open
Settings → Accounts → your team → Manage Certificates, and add an Apple
Development certificate. Put its name in `.sign-identity`
(`security find-identity -v -p codesigning` lists it). Renewing it keeps the
name, so permissions survive renewals.

**Without one:** `scripts/make-signing-cert.sh` creates a self-signed
"Hyprmux Local Signing" identity in the login keychain (10 years, local only).
The first build that uses it asks for your login password; choose Always Allow.

The build prints which identity it used. After switching identities, grant the
permissions once more. The bundle also copies the agent skill from
`.agents/skills/hyprmuxctl` into `Contents/Resources/skills`.

## Public release

Public releases require a paid Apple Developer account, a `Developer ID
Application` certificate, and a validated `notarytool` Keychain profile. Create
the default profile once:

```sh
xcrun notarytool store-credentials hyprmux-notary \
  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Build, sign with the hardened runtime, create the drag-to-Applications DMG,
notarize it, staple Apple's ticket, and write its SHA-256 checksum:

```sh
scripts/release.sh                 # version from Resources/Info.plist
scripts/release.sh 0.2.0           # override the assembled app's version
```

The output is `build/Hyprmux-VERSION-arm64.dmg`. Set
`HYPRMUX_SIGN_IDENTITY` when the Keychain contains several Developer ID
identities, or `HYPRMUX_NOTARY_PROFILE` for a differently named profile.
`HYPRMUX_SKIP_NOTARIZATION=1` creates a signed test image that Gatekeeper will
reject on other Macs.

### GitHub Actions

The **Release DMG** workflow runs manually on GitHub's Apple-silicon macOS
runner. It always uploads the notarized DMG as a workflow artifact. Its
`publish` input can also create the matching `vVERSION` GitHub Release.

Create a `release` GitHub environment and add these environment secrets:

| Secret | Value |
|---|---|
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 of the exported Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password used when exporting that `.p12` |
| `APPLE_NOTARY_APPLE_ID` | Apple Account email used for notarization |
| `APPLE_NOTARY_PASSWORD` | Apple app-specific password |
| `APPLE_TEAM_ID` | Developer team identifier |
| `APPLE_KEYCHAIN_PASSWORD` | A new random password used only for the temporary runner Keychain |

Export the certificate and private key from Keychain Access as a password-protected
`.p12`, then copy its Base64 form:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Optionally add `APPLE_DEVELOPER_ID_SHA1` when the `.p12` contains more than one
Developer ID identity. Obtain it with `security find-identity -v -p codesigning`.
Never commit the `.p12`, its password, or notarization credentials.

Run **Actions → Release DMG → Run workflow**, enter `0.2.0`, and choose whether
to publish it. The `release` environment can require manual approval before
GitHub exposes its secrets to the job.

## Where code goes

- **Decisions in the core.** Anything that decides layout, focus, or state
  goes in `HyprmuxCore`, with a unit test. It has no AppKit, so it's fast to
  test and can't depend on view state.
- **Execution in the app.** `Hyprmux` executes: it applies snapshots,
  animates, and bridges to libghostty and CEF. When the app
  needs the model to do something, it dispatches. When the model needs the app
  to do something, it emits an `Effect`.
- **New tile kinds** conform to `Surface`. A new web engine subclasses
  `BrowserSurface`. Content that another program can draw is a client app
  instead, like Mobile: Hyprmux stays free of app-specific code.
- **First-party apps** are `.hmapp`s in `Resources/apps`, with their program as
  an executable target that `bundle.sh` copies into `Contents/MacOS`.
- **Android Emulator protocol code** stays in `AndroidEmulatorBridge`.
  Mobile sees endpoint, frame, and client types, not generated messages.
- **Private or C APIs** sit behind a small Objective-C bridge
  (`ChromiumBridge`, `SimulatorBridge`) with a plain Objective-C header for
  Swift. Look up private classes and functions at runtime
  (`NSClassFromString`, `dlsym`, `respondsToSelector:`), catch Objective-C
  exceptions, and report "unavailable" instead of crashing.
- **Follow Hyprland.** Hyprland is the reference: dispatcher names, config
  keys, and behavior follow it unless there's a macOS reason not to.
  Deviations are deliberate and commented: the centered first float,
  `moveintogroup` creating a group, fill full screen.

## Config changes

- **Where to change it:** edit [`config/hyprmux.conf`](../config/hyprmux.conf),
  then run `scripts/gen-default-config.sh` (bundle.sh does too). A test fails
  if the embedded copy drifts from the file.
- **Parsing:** new options go in `ConfigParser.apply`. Unknown keys become
  errors, never crashes. Hyprland keys with no equivalent are accepted and
  ignored, so Hyprland configs mostly load.
- **Documentation:** add the option to [CONFIGURATION.md](CONFIGURATION.md).

## Testing a running app

Hyprmux is often the developer's own daily environment. Test in a separate
instance, never in theirs.

```sh
HYPRMUX_APP=/tmp/HyprmuxTest.app scripts/bundle.sh    # a separate copy; build/ stays untouched
mkdir -p /tmp/hmcfg && cp ~/.config/hyprmux/hyprmux.conf /tmp/hmcfg/
sed -i '' 's/follow_mouse = 1/follow_mouse = 0/' /tmp/hmcfg/hyprmux.conf
open -g -n \
  --env HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock \
  --env HYPRMUX_CONFIG=/tmp/hmcfg/hyprmux.conf \
  --env HYPRMUX_CHROMIUM_PROFILE=/tmp/hm-chromium \
  --env HYPRMUX_SESSION=/tmp/hm-test/session.json \
  /tmp/HyprmuxTest.app
export HYPRMUX_SOCKET=/tmp/hm-test/hyprmux.sock
hyprmuxctl dispatch exec
hyprmuxctl surfaces
hyprmuxctl dispatch exit        # quit it (Chromium processes exit cleanly)
```

Why each setting:

- **`-g -n`:** start a new instance in the background. It doesn't steal focus
  from the person using the machine.
- **Separate socket, config, and Chromium profile:** Chromium allows one
  process per profile, and the IPC socket would clash.
- **Separate session file:** without it, the test instance restores the
  user's session on launch and overwrites it on quit.
- **`follow_mouse = 0`:** the real pointer moving over the test window would
  move focus mid-test.

Rules that came out of real mistakes:

- **Never restart or kill the user's running Hyprmux** without asking. It
  closes their shells.
- **Don't activate the test app** unless a test needs it: typing into text
  fields and page buttons does. Activate it briefly, then give focus back to
  whatever was frontmost.
- **Use `sendtext` only for terminals.** It types via Ghostty's text-input
  path. The paste path (`ghostty_surface_text`) is a bracketed paste, which
  zsh highlights instead of running.
- **Use throwaway simulators** for anything that sends input:
  `xcrun simctl create "Hyprmux Test" ...`, boot it, delete it after. Only read
  (display) from the user's simulators.
- **Never send input to or restart a user's Android emulator.** Discovery tests
  use fixture files and fake process checks. Interactive testing needs a throwaway AVD.
- **Clean up** test instances, temporary configs, profiles, simulators, and
  screenshots.

### Client apps

Client apps find Hyprmux through `hyprmux-broker`, a launchd job. For
development, load it from the bundle you're testing, and give the test
instance its own `HYPRMUX_INSTANCE`, so it can't take over your own
Hyprmux's registration:

```sh
scripts/dev-broker.sh load /tmp/HyprmuxTest.app   # log: ~/Library/Logs/hyprmux-broker.log
open -g -n --env HYPRMUX_INSTANCE=test ... /tmp/HyprmuxTest.app   # plus the settings above
swift build --product hyprmux-demo-client
hyprmuxctl new-surface --type app -- "$(swift build --show-bin-path)/hyprmux-demo-client"
HYPRMUX_INSTANCE=test HM_DEMO_STATS=1 "$(swift build --show-bin-path)/hyprmux-demo-client"   # its own tile, stats on stderr
scripts/dev-broker.sh unload                      # when done
```

The demo echoes typed text into its title, so `hyprmuxctl surfaces` shows
whether keys made the round trip. Build it with `-c release` to measure
frame rates. A debug build spends most of each frame drawing.

#### Dev broker or registered agent

There are two ways the broker gets loaded:

- **Dev broker:** `scripts/dev-broker.sh load APP` boots a copy of the
  bundled plist with an absolute path, from
  `~/Library/Caches/dev.gavrix.hyprmux/`.
- **Registered agent:** a Hyprmux app bundle registers its own agent with
  `SMAppService` on launch. This is what users get. macOS lists it under
  System Settings → General → Login Items & Extensions, and may ask the user to allow it.

Both use one label, `dev.gavrix.hyprmux.broker`, and the same mach service
names. Only one job can hold them. So Hyprmux registers its agent only when
nobody holds the label: if the lookup service answers and its own agent isn't
enabled, it leaves the running broker alone. The dev broker wins, and a test
copy never takes over the broker your own Hyprmux uses. A SwiftPM build run
from `.build` never registers. `misc:register_broker = false` turns
registration off.

`hyprmuxctl broker status` shows which case you're in:

```sh
hyprmuxctl broker status      # the agent's status, the launchd job, who loaded it
hyprmuxctl broker unregister  # remove this bundle's agent
hyprmuxctl broker register    # register it now, skipping the checks above
```

To test the registered agent with a test copy, unload the dev broker first,
so nothing holds the label:

1. Record `scripts/dev-broker.sh status` and `hyprmuxctl broker status`.
2. `scripts/dev-broker.sh unload`.
3. Restart the test instance. It registers its agent. `broker status`
   shows `enabled`, or `waiting for approval` with a notice in the test
   window.
4. Open an app tile (`hyprmuxctl launch Reactotron`) to prove clients
   connect through the registered broker, then close it.
5. `hyprmuxctl broker unregister`, then
   `scripts/dev-broker.sh load /tmp/HyprmuxTest.app`, and restart the test
   instance.

What macOS does along the way:

- `register()` enables the agent at once, and macOS posts a notification:
  "“HyprmuxTest” can run in the background…". It names the app after the
  bundle's file name.
- Before the first registration, `broker status` says `not registered`
  (`SMAppService` reports `.notFound` then). The test bundle never needed
  approval. Approval comes up only after the user turns Hyprmux off in Login
  Items.
- `unregister()` removes the launchd job, but macOS keeps a disabled record
  of the item. `sfltool dumpbtm` lists it. That's harmless. Don't run
  `sfltool resetbtm`: it resets every app's background items.

Your own Hyprmux loses the broker between steps 2 and 5. Tiles that are
already open keep working, since they talk to Hyprmux directly. New app tiles
connect once a broker is back: Hyprmux retries every 5 seconds.

Electron apps go through `hyprmux-electron-bridge`, picked by the adapter
manifests in `Resources/adapters/` ([ADAPTERS.md](ADAPTERS.md)). Start the test
instance with `--env HYPRMUX_ADAPTER_BIN="$(swift build --show-bin-path)"`, so
adapters resolve to debug builds without rebundling. A debug bridge finds
`Resources/electron-hook.js` in the repo by itself. `hyprmuxctl adapters` shows
which executable each adapter resolved to. `hyprmuxctl adapters match APP`
shows the choice for one app.

Generated apps are per instance too: a test instance with
`HYPRMUX_INSTANCE=test` writes them to
`~/Library/Application Support/Hyprmux/Apps/test/`, and its installed apps come
from `apps/` next to its config file. Your own Hyprmux's apps stay untouched.
To test the launcher in the background, press its bind with `sendkey` and read
the open picker from `hyprmuxctl debug` (query, rows, selection):

```sh
hyprmuxctl apps                        # what the test instance generated
hyprmuxctl sendkey SUPER, D            # open the launcher (bind = $mod, D, picker, apps)
hyprmuxctl sendkey , R                 # type a filter
hyprmuxctl debug                       # "picker": {"title": "apps", "rows": [...], ...}
hyprmuxctl sendkey , Return            # open the selected app; Escape closes instead
hyprmuxctl snapshot --surface N /tmp/app.png   # see the tile
```

Each adapter process logs its stderr to
`~/Library/Logs/Hyprmux/adapters/` (a subdirectory per `HYPRMUX_INSTANCE`), and
`hyprmuxctl adapters` prints the latest log's path. Start the test instance
with `--env HYPRMUX_HOOK_DEBUG=1` too, and the bridge and hook log their work
there:

- Keys, buttons, and text-input updates the bridge forwards, with timings.
- Frames: dirty rect, hook cost, transit, and present time.
- Input events the app's webContents receives, dialog and menu calls with
  their results, and `<select>` popups.

The bridge can also run from a shell, where it opens its own tile:

```sh
HYPRMUX_INSTANCE=test HYPRMUX_HOOK_DEBUG=1 "$(swift build --show-bin-path)/hyprmux-electron-bridge" /Applications/Reactotron.app
kill -USR1 <bridge pid>   # with HYPRMUX_HOOK_DEBUG: writes each window's frame to /tmp/hyprmux-bridge-win<N>.png
```

The PNG dump shows what a tile displays when screen capture isn't
available. Read coordinates off it carefully: the dump is in pixels, and
`sendmouse` takes window points, so divide by the tile's scale and add the
tile's `at` from `hyprmuxctl surfaces`.

Testing app tiles from a background instance has limits:

- **Menus:** context menus and `<select>` popups do open, but synthetic clicks
  can't pick an item. AppKit's menu tracking ignores them.
- **Dead keys and IME:** compositions need Hyprmux to be the active app. With
  the instance in the background, ⌥E types nothing. `sendkey` with ALT
  computes characters from the keyboard layout (⌥S gives ß), like a real key.
- **Text:** `hyprmuxctl send --surface ID TEXT` types into an app tile through
  text input. Its `surfaces` entry shows `textInput`, with the last key's
  input-method result.

### Mobile

Mobile runs from the bundle you test, as a built-in app. Without rebundling,
start the test instance with `HYPRMUX_ADAPTER_BIN="$(swift build --show-bin-path)"`
and `swift build --product hyprmux-mobile`: the bare `exec` name then resolves to
the debug build.

```sh
"$(swift build --show-bin-path)/hyprmux-mobile" list         # the devices it would offer
"$(swift build --show-bin-path)/hyprmux-mobile" info UDID    # a simulator's framebuffer size and format
hyprmuxctl launch Mobile                                     # the offer, as JSON
hyprmuxctl launch --window ios:UDID Mobile                   # one tile; read-only on your own simulators
hyprmuxctl surfaces                                          # "subsurfaces": each device screen's rect
hyprmuxctl snapshot --surface N /tmp/mobile.png              # the bar and the screen, composited
```

`snapshot` composites subsurfaces over the toplevel's buffer, so it shows what
the tile shows. Hyprmux keeps only the last line of Mobile's stderr, for a launch
that fails. Mobile started from a shell gets no launch and quits after 10
seconds: launch it from Hyprmux.

### Test tools

| Tool | Use |
|---|---|
| `hyprmuxctl read-screen --surface ID` | Reads a terminal's rendered viewport; add `--scrollback` or `--lines N` for history. |
| `hyprmuxctl send --surface ID` / `send-key --surface ID` | Sends terminal input directly without focusing the target or running Hyprmux binds. |
| `hyprmuxctl sendkey MODS, key` | Presses a key through the focused real path (binds, then the surface). Works in the background. |
| `hyprmuxctl senddrag` / `sendmouse` | Mouse input, paced like a hand. `sendmouse down` … `up` for holds. |
| `hyprmuxctl snapshot [--surface ID] FILE.png` | Writes an app tile's current frame to a PNG, straight from the client's IOSurface. Needs no screen-recording permission, so it works where `screencapture` doesn't. |
| `hyprmuxctl sendscroll MODS, LINES, x y` | A notched mouse-wheel scroll, built as a real line-unit event (positive scrolls up). App tiles get it with its raw notch count, like hardware. |
| `hyprmuxctl sendmenu TITLE` | Performs a menu bar item, as a click would (`sendmenu "Open App..."`). Works in the background. |
| `hyprmuxctl hittest x y` | Which views a click reaches. This found the dim overlay that swallowed every click. |
| `hyprmuxctl debug` | App active, key window, first responder, `keyboardClient`, the frames of HUD panels on screen, and the open picker (query, rows, selection). Use it for any "wrong window" bug, and to find where to click a notification. |
| `hyprmuxctl surfaces` | References, capabilities, workspaces, frames, focus, groups, URLs, and terminal directories. |
| `screencapture -x -o -l <windowid>` | Captures one window even when covered. Find the window ID with `CGWindowListCopyWindowInfo` for the test app's pid. |
| Chromium `remote-debugging-port` | Set `web:chromium_flags = remote-debugging-port=9333` in a test config, then query targets and evaluate JavaScript over the DevTools protocol. |

**Coordinate caution:** the test window opens on whichever display it last
used, so its size changes between runs. Compute click positions from
`hyprmuxctl surfaces` (tile frames, an app tile's `subsurfaces`), never hard-code
them. Several "bugs" during development were clicks landing outside the
window.

## Pitfalls we hit

Each one cost a debugging session.

- **Event monitor return values.** `self?.handleKey(e) ?? e` turns "consumed"
  (`nil`) back into `e`, so every bind also reached the terminal. Use
  `guard let self else { return e }; return self.handleKey(e)`.
- **Invisible overlays eat clicks.** A plain `NSView` at alpha 0 still wins
  hit testing. Visual-only overlays must be `PassthroughView`, with `hitTest`
  returning nil.
- **`hitTest` coordinates.** `hitTest` takes the point in the superview's
  coordinates. The window frame view isn't flipped, so y was mirrored in the
  first probe.
- **Background key injection.** A window that isn't key drops queued key
  events, and text fields need an active input context. `sendkey` handles binds
  itself and hands other keys to the first responder when the app is inactive.
  Text-field typing still needs a brief activation.
- **Follow-mouse while inactive.** Terminals track the mouse even when
  Hyprmux isn't in front. Follow-mouse must check `NSApp.isActive`.
- **Chromium `DoClose`.** Returning false closes the top-level window, which
  is the monitor. Close the browser's own view instead.
- **Chromium popups** need a user gesture, as in any browser. Test them with a
  focused button and Enter, not a timer.
- **Simulator touches.** SimulatorKit has no "moved" builder. Re-mark down
  messages as continuing contacts (0x7), or long press never fires. Keep a held
  finger alive at 60 Hz.
- **Android discovery credentials.** Never log an endpoint dictionary or bearer
  token. Endpoint descriptions must redact credentials, including error paths.
- **Android frame format.** `streamScreenshot` uses RGBA8888 within a 720×1280
  bound. Keep native dimensions separately because touch coordinates use them.
  Emulator 37.2.3+ uses a client-owned file mapping. Copy each notified frame
  before rendering because the emulator can overwrite MMAP data concurrently.
  Keep gRPC fallback enabled for older versions and rejected MMAP requests.
- **Cross-fades over transparency blink.** Swap instantly where Hyprland does
  (group tabs).
- **Config watching.** Watch the file as well as its directory: in-place
  saves don't touch the directory.
- **Hidden windows don't animate.** The `Animator`'s display link stops while
  the app is hidden, so tiles and HUD panels freeze at their start frame, often
  offscreen or at alpha 0. Hide the test app only when no test depends on it.
- **Ghostty filters desktop notifications.** A repeated OSC 9 with the same
  text, or several in quick succession, may never reach Hyprmux. Put
  `$RANDOM` in test messages and space them out.
- **Modifier combos in a grab.** An early picker matched Return by key code alone,
  so ⌘↩ (the new-terminal bind) chose a row instead of doing nothing. Keys a
  HUD element takes must check modifiers; ⌘ and ⌥ combos go to the text field.
- **First click in an inactive window.** AppKit uses it to activate the app
  unless the view returns true from `acceptsFirstMouse`. HUD panels do, so a
  click on a notification works while Hyprmux is in the background.

## Commits

- One change per commit.
- The message says what changed and why, with the root cause for bug fixes.
- Run `swift test` before committing.
- Build the bundle for anything that touches the app.
- Verify behavior in a test instance for anything visible or interactive, and
  say in the commit or PR what was verified and what wasn't.
