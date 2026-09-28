# Architecture

Hyprmux is one macOS app that acts as a small compositor. Its window is the
"monitor". Inside it, tiles hold terminals, web pages, or iOS Simulator
screens, laid out and driven the way Hyprland lays out and drives windows.
There is no Apple window-management API underneath. Tiles are views that
Hyprmux owns, positions, and animates itself.

```
┌─────────────────────────── Hyprmux.app ────────────────────────────┐
│                                                                     │
│  HyprmuxCore (pure Swift, unit tested)                             │
│    Config parser ─► HyprmuxConfig                                  │
│    Dispatcher ─► WindowManager ─► Snapshot (frames, focus, z, ...)  │
│                    ├ DwindleLayout (BSP tree per workspace)         │
│                    └ groups, floating, workspaces, special          │
│                                                                     │
│  Hyprmux (AppKit)                                                  │
│    Compositor: applies Snapshots to views, animates, routes input   │
│    MonitorWindow ─ CompositorView ─ ClientView (border/shadow/clip) │
│                                        └ Surface                    │
│                                            ├ TerminalView (libghostty)
│                                            ├ WebKitSurface (WKWebView)
│                                            ├ ChromiumSurface (CEF)  │
│                                            └ SimulatorSurface       │
│    HUD: overlay layer, theme, NotificationStack, PickerPresenter    │
│    IPCServer (Unix socket) ◄── hyprmuxctl                          │
│                                                                     │
│  ChromiumBridge (Obj-C++)  ── CEF framework + 4 helper apps          │
│  SimulatorBridge (Obj-C)   ── Xcode's CoreSimulator/SimulatorKit     │
│  GhosttyKit (prebuilt libghostty)                                   │
└─────────────────────────────────────────────────────────────────────┘
```

## Modules

| Target | Language | Role |
|---|---|---|
| `HyprmuxCore` | Swift 6 | Model and logic, no AppKit: layout, workspaces, focus, groups, config, dispatchers, IPC protocol, bezier curves, the rounded-corner shape. All unit tests live here. |
| `Hyprmux` | Swift 5 mode | The app: window, compositor, surfaces, input, animations, IPC server. |
| `ChromiumBridge` | Obj-C++ | CEF lifecycle, the `NSApplication` subclass CEF needs, browsers as child views. |
| `CEFWrapper` | C++ | CEF's `libcef_dll_wrapper`, built by SwiftPM from `vendor/cef` (no cmake). |
| `HyprmuxHelper` | Obj-C | Chromium's helper process (GPU, renderer, ...). |
| `SimulatorBridge` | Obj-C | Simulator display and input through Xcode's private frameworks. |
| `GhosttyKit` | binary | Prebuilt libghostty xcframework (terminal emulation and rendering). |
| `hyprmuxctl` | Swift | The IPC client. |

## The model: `WindowManager`

Everything that decides where things go lives in `HyprmuxCore`. The app never
positions a tile on its own authority.

- **Clients** are `ClientID`s. The model doesn't know whether a client is a
  terminal or a browser.
- **Workspaces** are `.regular(n)` or `.special(name)`, created on demand and
  dropped when empty. Regular ones can have names, kept in the manager rather
  than the workspace, so a name outlives an emptied workspace. One regular workspace is shown, plus optionally one
  special workspace (the scratchpad) on top.
- **Tiling** is a `DwindleLayout` per workspace, a binary tree modeled on
  Hyprland's dwindle layout:
  - A new client splits the target leaf along its longer side.
  - The tree moves windows by removing them and re-inserting at a focal point:
    that's how `movewindow`, drag-and-drop, and re-tiling from floating work.
  - Resizing changes split ratios. Keyboard resizing grows the focused window;
    mouse resizing moves the grabbed edge.
- **Floating** clients have their own rectangle and a stacking order. A
  floated client remembers its tiled slot (sibling subtree, side, orientation,
  ratio), so re-tiling puts it back.
- **Groups** hold several clients in one slot:
  - The layout slot always holds the group's shown member.
  - Switching tabs swaps which client sits there (`replaceClient`), so the tree
    code knows nothing about groups.
  - The other members stay managed, hidden at the slot's frame.
- **Focus** keeps a recency counter per client. It drives focus after a close,
  `focuscurrentorlast`, and stacking: tiles stack by recency, so the window you
  just touched animates above others.
- **Directional focus** (`DirectionalSearch`) picks the neighbor on that side,
  preferring overlap on the other axis, then distance, then recency.

The model never touches AppKit. Actions the app must take (spawn a terminal,
close a surface, open a web tile, press a simulator button, quit) leave the
model as `Effect` values through `perform`.

`snapshot()` returns a `Snapshot`. For every client it holds the final frame
(border included, top-left origin), visibility, focus, floating and fullscreen
state, stacking order, and group info.

## The app: `Compositor`

The `Compositor` owns the `WindowManager`, the monitor window, and one
`ClientView` per client. Every change follows the same loop:

```
input or IPC ─► wm.dispatch(...) ─► compositor.apply(animated:)
                                      ├ diff old vs new Snapshot
                                      ├ per client: move/fade with the configured animation
                                      ├ restack views by z
                                      ├ bar, hint
                                      └ keyboard focus to the focused surface
```

`apply` picks each animation from what changed:

- **Appearing:** a new client pops in (`windowsIn`).
- **Workspace switch:** clients slide by the width of the screen.
- **Scratchpad:** it slides in vertically.
- **Frame change:** `windowsMove`.
- **Group tab switch:** swaps instantly, like Hyprland. Everything else
  fades.

`Animator` runs every animation from one display link, with the bezier curves
from the config.

### `ClientView`

A client's frame, border, shadow, and clip. The decoration part lives in its base
class, `DecoratedView`, which HUD panels share:

- **Border:** a `CAGradientLayer`, masked to a ring.
- **Shadow:** a separate layer, masked so it's drawn only outside the window
  and never shows through translucent content.
- **Clip:** a view holding the surface.
  - At `rounding_power` 2 it uses Core Animation's `cornerRadius`. Otherwise it
    uses a shape mask from `RoundedShape`, a superellipse path; the same path
    also drives the border, shadow, and blur, so they line up.
  - Active and inactive opacity apply to the clip with group opacity, so
    borders keep their own alpha.
- **Blur:** an `NSVisualEffectView` behind the clip, in a host view masked to
  the same shape.
- **Group tab strip:** a `GroupBarView` at the top of the clip.

During a geometry animation the content jumps to its final size once and the
clip animates around it. Shells therefore get one resize, not one per frame.

### Surfaces

`Surface` is the protocol for what a tile shows. Each surface supplies its
view, a focus target, a title, a kind, a backdrop color, and IPC info, and
handles occlusion, close, and destroy.

- **`TerminalView`:** a libghostty surface in an `NSView`. libghostty installs
  its own Metal layer and renders on its own thread. Keyboard, IME, mouse, and
  clipboard handling are ported from Ghostty's macOS sources.
  - `GhosttyRuntime` holds the app and config and routes runtime callbacks
    back to their views (title, pwd, close, clipboard, open URL).
  - Ghostty's own new-split and goto-split actions map onto Hyprmux
    dispatchers.
- **`BrowserSurface`:** the shared part of a web tile: address bar, start
  page, navigation. Two engines subclass it:
  - **`WebKitSurface`:** a `WKWebView`. Light, but no passkeys: Apple gates
    WebAuthn in web views behind a browser entitlement.
  - **`ChromiumSurface`:** CEF through `ChromiumBridge`. Chromium implements
    WebAuthn itself, so phone passkeys (QR code) and USB security keys work.
    See [Chromium](#chromium-cef).
- **`SimulatorSurface`:** a booted iOS Simulator's screen, with touch and
  keys. See [Simulator](#ios-simulator).

### Input

- **Keys:** a local event monitor sees every key event before any view. It
  matches binds by physical key code and exact modifiers in the current
  submap. A matching key is consumed (its key-up too); anything else goes to
  the focused surface.
- **Mouse binds:** ⌘-drag moves (floating) or drags and drops (tiled);
  ⌘-right-drag resizes from the grabbed edge or corner.
- **Clicks:** a click on any tile focuses it first.
- **Follow-mouse:** focus follows the pointer, only while Hyprmux is the
  active app.
- **Keyboard focus:** after every apply, the focused surface's focus target
  becomes first responder. Focus already somewhere inside the surface (an
  address bar, for example) is left alone.

### HUD: Hyprmux's own UI

Notifications and pickers live in the HUD. It works like a
Hyprland overlay layer: elements sit above every tile and never tile.

- **Model in the core:**
  - `HUDAnchor` places an element against the monitor, the work area, or a
    tile, and `HUDLayout` places one element or a stack.
  - `NoticeQueue` holds the notifications: order, expiry, duplicates, keyed
    updates, the visible limit, and hover holds.
  - `LayerAnimationStyle` parses Hyprland's layer styles.
- **`HUDLayerView`:** the overlay view, above the bar. Its own hit test
  returns nil, so the gaps between panels pass clicks through to tiles. The
  compositor also skips click-to-focus and follow-mouse over a panel.
- **`HUD`:** owns the layer, the theme, and the anchor geometry, and runs the
  `layersIn`, `layersOut`, `fadeLayers*`, and `layers` animations. Elements
  are components on top of it.
- **`HUDTheme`:** the font, foreground, and palette come from Ghostty, the
  frame from the decoration settings. Level colors are the terminal's own
  bright red, yellow, and green.
- **Panels are `DecoratedView`s,** the same base class as `ClientView`, so
  borders, squircle corners, shadow, and blur match tiles exactly. Their blur
  uses `.withinWindow` to blur the tiles below; tiles use `.behindWindow`.
- **`NotificationStack`:** diffs the queue against its views: new ones animate
  in, gone ones out, the rest reflow.
- **`PickerPresenter`:** one picker at a time, with a keyboard grab like a
  Hyprland layer's exclusive focus:
  - The model is `Picker` in the core: the query, rows ranked by `FuzzyMatch`
    (fzf-style, scored by dynamic programming), the selection, and scrolling.
  - While a picker is open, `handleKey` skips binds. The picker takes its own
    keys (Return, Escape, arrows, fzf's ⌃ keys) and every other key goes to the
    query field. `updateFocus` keeps the field as first responder, and focus
    goes back to the tile on close.
  - A `PickerScrim` under the panel catches clicks outside it and cancels.
  - `PickerView` keeps its content at full size, centered in the clip, so a
    popin reveals it from the middle.
- **Font family:** `ghostty_config_get` can't return repeatable strings, so
  `GhosttyConfigScan` reads `font-family` from Ghostty's config files.

### The monitor window and chrome

- **`MonitorWindow`:** a normal titled window with a transparent title bar.
  - **Fill full screen:** it becomes borderless and screen-sized on the normal
    desktop, auto-hiding the menu bar and Dock while Hyprmux is in front. That
    keeps the wallpaper behind a transparent background; native full screen
    would put black there.
  - **Transparency:** with a background alpha below 1 the window is
    non-opaque. It keeps 1% alpha so clicks in the gaps still land in
    Hyprmux.
- **Chrome:** `BarView` shows workspaces, the focused title, the scratchpad,
  and the submap. Config errors and short messages are HUD notifications.

### Session restore

- **Schema and model in the core:** `SessionState` (JSON) holds workspaces,
  split trees, floating rects as fractions of the work area, groups, focus, and
  names. `WindowManager.exportSession` and `restoreSession` take closures: the
  app describes each client as a `SessionTile`, and creates a client from one.
  A tile the app skips collapses its split. `RestorePolicy` decides which
  foreground programs re-run and turns agent reports into resume commands.
- **Describing a terminal** (`Compositor+Session.swift`): the directory comes
  from OSC 7, else the foreground process. libghostty reports the foreground
  process group (`ghostty_surface_foreground_pid`); `ProcessInspector` reads its
  argv (`KERN_PROCARGS2`) and directory (`proc_pidinfo`). An agent's
  `ResumeReport` wins while its PID is in that group.
- **Restoring:** surfaces are created and adopted (views only), then the model
  places them. A restored command is the shell's `initial_input`, so the shell
  survives the program.
- **Layouts** reuse the schema for one workspace: `exportWorkspace` saves it
  with a `name` instead of an `id`, and `loadLayout` finds the named workspace or
  builds it on a free number (`Layouts.swift` has the picker and the files).
  Agents are saved by kind only and start with `session:start:KIND`.
- **When it saves:** 2 s after `apply`, every 30 s, and on quit, before the
  shells close. CEF's quit path skips `applicationShouldTerminate`, so
  `main.swift`'s terminate handler saves too.

### Config

- **Parsing:** `ConfigParser` turns hyprlang-style text into `HyprmuxConfig`
  and collects errors instead of failing.
- **Reloading:** `ConfigWatcher` watches both the directory (rename-style
  saves) and the file (in-place writes), re-arms when the file is replaced, and
  reloads on a modification-date change.
- **Applying:** a reload updates the model settings, decorations, animations,
  binds, and Ghostty config live.
- **Default:** the built-in default is `config/hyprmux.conf`, embedded by
  `scripts/gen-default-config.sh`.

### IPC

`IPCServer` serves a Unix socket: one line in, one reply out, handled on the
main thread. `IPCRequest` parsing lives in the core. Beyond Hyprland-style
`dispatch`, `clients`, and `workspaces`, there are test commands that inject
input through the real event path (`sendkey`, `sendmouse`, `senddrag`,
`sendtext`) and ones that report what's under a point or holds the keyboard
(`hittest`, `debug`). See [DEVELOPMENT.md](DEVELOPMENT.md).

## Chromium (CEF)

- **Download:** `scripts/fetch-cef.sh` fetches the CEF minimal SDK (pinned
  version and sha1). SwiftPM builds the C++ wrapper from it.
- **Bundle:** `scripts/bundle.sh` copies the framework into
  `Contents/Frameworks`, and the helper binary into four
  `Hyprmux Helper*.app` bundles (plain, GPU, Renderer, Alerts).
- **Startup:** when `web:engine = chromium`, `main.swift` creates
  `HMApplication` (the `NSApplication` subclass CEF requires), starts CEF, and
  runs CEF's message loop instead of `NSApp.run()`.
- **Quitting:** closes every browser first, then ends the loop and shuts CEF
  down.
- **Embedding:** each browser is a child view of its tile. On macOS that forces
  CEF's Alloy style, which still shows Chrome's own passkey dialog in a
  separate window.
- **Closing a browser:** `DoClose` removes the browser's view and returns true.
  Returning false would send `performClose:` to the top-level window, which is
  the whole Hyprmux monitor.
- **Popups:** handled in `OnBeforePopup` by creating a new tile and attaching
  the popup there, so `window.opener` keeps working.
- **Profile:** `~/Library/Application Support/Hyprmux/Chromium`, with
  `use-mock-keychain`, since ad-hoc builds would otherwise hit a keychain
  prompt on every build.
- **Limits:**
  - Tiles aren't Chrome tabs, so extensions that need `chrome.tabs` or
    `chrome.windows` (1Password, for one) don't work in them.
  - Mac and iCloud passkeys (Touch ID) need Apple's browser entitlement.

## iOS Simulator

`SimulatorBridge` loads `CoreSimulator` and `SimulatorKit` from the selected
Xcode. All private calls are dynamic, so a changed Xcode fails with an error,
not a crash.

- **Display:** the device's IO ports expose the main display's
  `framebufferSurface`, an `IOSurface`. A callback fires when the surface
  changes and another when pixels change. `SimulatorSurface` hands the surface
  to a layer: no copies, no screen recording, no Simulator.app. The screen is
  letterboxed in the tile.
- **Touch:** goes through `SimDeviceLegacyHIDClient`, one message per phase, as
  the mouse moves.
  - The message layout comes from idb (`Sources/SimulatorBridge/idb`, MIT),
    checked with static asserts.
  - SimulatorKit only builds touch-down and touch-up messages, so moves are
    down messages re-marked with digitizer mask Range|Touch|Position (0x7).
    On iOS 27, 0x3 restarts the touch (no long press) and 0x4 doesn't scroll.
  - A held finger is re-reported at 60 Hz.
  - Touches that start at a screen edge carry the edge flag, which is how iOS
    recognizes the home swipe and other system gestures.
- **Keys:** macOS key codes map to USB HID usages
  (`IndigoHIDMessageForKeyboardArbitrary`).
- **Buttons:** Home and Lock use `IndigoHIDMessageForButton`.

## Rendering pipeline notes

- **Terminals:** libghostty draws terminals on its own Metal layer.
- **Chromium:** composites into its child view through its own layer tree.
- **Simulator:** its `IOSurface` is a layer's contents.
- **Everything else** is Core Animation: borders, masks, shadow, the blur
  view, and the tab strip.
- **Opacity:** the clip's group opacity applies to all of them, which is how
  inactive translucency works for every tile kind.
