# Development

How Hypermux is built, tested, and changed. This is the working style it was
developed with: the rules exist because each one prevented a real bug or a
disrupted session.

## Build and run

```sh
scripts/fetch-ghosttykit.sh   # libghostty (pinned, checksummed)
scripts/fetch-cef.sh          # Chromium SDK; needed to build even if you use WebKit
                              # (bundle.sh runs both)
swift build                   # all targets
swift test                    # core tests
scripts/bundle.sh             # build/Hypermux.app (debug); `scripts/bundle.sh release` for release
open build/Hypermux.app
```

`bundle.sh` does four things:

- regenerates the embedded default config;
- builds the app and the Chromium helper;
- assembles the bundle: Info.plist, Ghostty's terminfo and shell integration
  (copied from an installed Ghostty.app or cmux.app), and the CEF framework
  plus helper apps when `vendor/cef` exists;
- signs it ad hoc.

The framework copy is an APFS clone, so bundling takes a few seconds.

## Where code goes

- **Decisions in the core.** Anything that decides layout, focus, or state
  goes in `HypermuxCore`, with a unit test. It has no AppKit, so it's fast to
  test and can't depend on view state.
- **Execution in the app.** `Hypermux` executes: it applies snapshots,
  animates, and bridges to libghostty, CEF, and SimulatorKit. When the app
  needs the model to do something, it dispatches. When the model needs the app
  to do something, it emits an `Effect`.
- **New tile kinds** conform to `Surface`. A new web engine subclasses
  `BrowserSurface`.
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

- **Where to change it:** edit [`config/hypermux.conf`](../config/hypermux.conf),
  then run `scripts/gen-default-config.sh` (bundle.sh does too). A test fails
  if the embedded copy drifts from the file.
- **Parsing:** new options go in `ConfigParser.apply`. Unknown keys become
  errors, never crashes. Hyprland keys with no equivalent are accepted and
  ignored, so Hyprland configs mostly load.
- **Documentation:** add the option to [CONFIGURATION.md](CONFIGURATION.md).

## Testing a running app

Hypermux is often the developer's own daily environment. Test in a separate
instance, never in theirs.

```sh
cp -Rc build/Hypermux.app /tmp/HypermuxTest.app          # separate copy
mkdir -p /tmp/hmcfg && cp ~/.config/hypermux/hypermux.conf /tmp/hmcfg/
sed -i '' 's/follow_mouse = 1/follow_mouse = 0/' /tmp/hmcfg/hypermux.conf
open -g -n \
  --env HYPERMUX_SOCKET=/tmp/hm-test/hypermux.sock \
  --env HYPERMUX_CONFIG=/tmp/hmcfg/hypermux.conf \
  --env HYPERMUX_CHROMIUM_PROFILE=/tmp/hm-chromium \
  /tmp/HypermuxTest.app
export HYPERMUX_SOCKET=/tmp/hm-test/hypermux.sock
hypermuxctl dispatch exec
hypermuxctl clients
hypermuxctl dispatch exit        # quit it (Chromium processes exit cleanly)
```

Why each setting:

- **`-g -n`:** start a new instance in the background. It doesn't steal focus
  from the person using the machine.
- **Separate socket, config, and Chromium profile:** Chromium allows one
  process per profile, and the IPC socket would clash.
- **`follow_mouse = 0`:** the real pointer moving over the test window would
  move focus mid-test.

Rules that came out of real mistakes:

- **Never restart or kill the user's running Hypermux** without asking. It
  closes their shells.
- **Don't activate the test app** unless a test needs it: typing into text
  fields and page buttons does. Activate it briefly, then give focus back to
  whatever was frontmost.
- **Use `sendtext` only for terminals.** It types via Ghostty's text-input
  path. The paste path (`ghostty_surface_text`) is a bracketed paste, which
  zsh highlights instead of running.
- **Use throwaway simulators** for anything that sends input:
  `xcrun simctl create "Hypermux Test" ...`, boot it, delete it after. Only read
  (display) from the user's simulators.
- **Clean up** test instances, temporary configs, profiles, simulators, and
  screenshots.

### Test tools

| Tool | Use |
|---|---|
| `hypermuxctl sendkey MODS, key` | Presses a key through the real path (binds, then the surface). Works in the background for binds and terminals. |
| `hypermuxctl senddrag` / `sendmouse` | Mouse input, paced like a hand. `sendmouse down` … `up` for holds. |
| `hypermuxctl hittest x y` | Which views a click reaches. This found the dim overlay that swallowed every click. |
| `hypermuxctl debug` | App active, key window, first responder, `keyboardClient`, the frames of HUD panels on screen, and the open picker (query, rows, selection). Use it for any "wrong window" bug, and to find where to click a notification. |
| `hypermuxctl clients` | Frames, focus, groups, URLs. |
| `screencapture -x -o -l <windowid>` | Captures one window even when covered. Find the window ID with `CGWindowListCopyWindowInfo` for the test app's pid. |
| Chromium `remote-debugging-port` | Set `web:chromium_flags = remote-debugging-port=9333` in a test config, then query targets and evaluate JavaScript over the DevTools protocol. |

**Coordinate caution:** the test window opens on whichever display it last
used, so its size changes between runs. Compute click positions from
`hypermuxctl clients` (tile frames, the simulator's `pixels`), never hard-code
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
  Hypermux isn't in front. Follow-mouse must check `NSApp.isActive`.
- **Chromium `DoClose`.** Returning false closes the top-level window, which
  is the monitor. Close the browser's own view instead.
- **Chromium popups** need a user gesture, as in any browser. Test them with a
  focused button and Enter, not a timer.
- **Simulator touches.** SimulatorKit has no "moved" builder. Re-mark down
  messages as continuing contacts (0x7), or long press never fires. Keep a held
  finger alive at 60 Hz.
- **Cross-fades over transparency blink.** Swap instantly where Hyprland does
  (group tabs).
- **Config watching.** Watch the file as well as its directory: in-place
  saves don't touch the directory.
- **Hidden windows don't animate.** The `Animator`'s display link stops while
  the app is hidden, so tiles and HUD panels freeze at their start frame, often
  offscreen or at alpha 0. Hide the test app only when no test depends on it.
- **Ghostty filters desktop notifications.** A repeated OSC 9 with the same
  text, or several in quick succession, may never reach Hypermux. Put
  `$RANDOM` in test messages and space them out.
- **Modifier combos in a grab.** An early picker matched Return by key code alone,
  so ⌘↩ (the new-terminal bind) chose a row instead of doing nothing. Keys a
  HUD element takes must check modifiers; ⌘ and ⌥ combos go to the text field.
- **First click in an inactive window.** AppKit uses it to activate the app
  unless the view returns true from `acceptsFirstMouse`. HUD panels do, so a
  click on a notification works while Hypermux is in the background.

## Commits

- One change per commit.
- The message says what changed and why, with the root cause for bug fixes.
- Run `swift test` before committing.
- Build the bundle for anything that touches the app.
- Verify behavior in a test instance for anything visible or interactive, and
  say in the commit or PR what was verified and what wasn't.
