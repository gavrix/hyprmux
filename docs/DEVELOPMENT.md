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
afterwards. It opens the simulator by UDID, because ⌘I would list every booted
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

`scripts/bundle.sh` signs the app, the Chromium framework, and the helper apps
with the first of:

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
permissions once more.

## Where code goes

- **Decisions in the core.** Anything that decides layout, focus, or state
  goes in `HyprmuxCore`, with a unit test. It has no AppKit, so it's fast to
  test and can't depend on view state.
- **Execution in the app.** `Hyprmux` executes: it applies snapshots,
  animates, and bridges to libghostty, CEF, and SimulatorKit. When the app
  needs the model to do something, it dispatches. When the model needs the app
  to do something, it emits an `Effect`.
- **New tile kinds** conform to `Surface`. A new web engine subclasses
  `BrowserSurface`.
- **Android Emulator protocol code** stays in `AndroidEmulatorBridge`.
  The app target sees endpoint, frame, and client types, not generated messages.
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
hyprmuxctl clients
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

### Test tools

| Tool | Use |
|---|---|
| `hyprmuxctl sendkey MODS, key` | Presses a key through the real path (binds, then the surface). Works in the background for binds and terminals. |
| `hyprmuxctl senddrag` / `sendmouse` | Mouse input, paced like a hand. `sendmouse down` … `up` for holds. |
| `hyprmuxctl hittest x y` | Which views a click reaches. This found the dim overlay that swallowed every click. |
| `hyprmuxctl debug` | App active, key window, first responder, `keyboardClient`, the frames of HUD panels on screen, and the open picker (query, rows, selection). Use it for any "wrong window" bug, and to find where to click a notification. |
| `hyprmuxctl clients` | Frames, focus, groups, URLs. |
| `screencapture -x -o -l <windowid>` | Captures one window even when covered. Find the window ID with `CGWindowListCopyWindowInfo` for the test app's pid. |
| Chromium `remote-debugging-port` | Set `web:chromium_flags = remote-debugging-port=9333` in a test config, then query targets and evaluate JavaScript over the DevTools protocol. |

**Coordinate caution:** the test window opens on whichever display it last
used, so its size changes between runs. Compute click positions from
`hyprmuxctl clients` (tile frames, the simulator's `pixels`), never hard-code
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
