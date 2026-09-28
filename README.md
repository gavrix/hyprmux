# hypermux

A Hyprland-style tiling terminal multiplexer for macOS, built on libghostty.

One macOS window acts as the "monitor". Inside it, terminal surfaces tile with
Hyprland's dwindle layout. You drive them with Hyprland-style binds, dispatchers,
workspaces, a scratchpad, floating windows, and bezier animations. The config
file uses `hyprland.conf` syntax and reloads on save.

## Build and run

Requirements: macOS 14+, Xcode 16+ (Swift 6).

```sh
scripts/fetch-cef.sh         # optional: Chromium (CEF) SDK, ~130 MB download, for web { engine = chromium }
scripts/bundle.sh            # fetches libghostty, builds, assembles build/Hypermux.app
open build/Hypermux.app
swift test                   # core model tests
```

`scripts/fetch-ghosttykit.sh` downloads a prebuilt `GhosttyKit.xcframework`
(libghostty) pinned by commit and sha256. It comes from the
[manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty) fork that cmux ships.
The bundle script copies Ghostty's terminfo and shell integration from an
installed Ghostty.app or cmux.app.

## Default binds

`SUPER` is ⌘. Keys are physical positions, so binds work with any keyboard layout.

| Keys | Action |
|---|---|
| ⌘↩ / ⌘T | new terminal (`exec`) |
| ⌘W | close (`killactive`) |
| ⌘H/J/K/L, ⌘arrows | `movefocus` |
| ⇧⌘H/J/K/L | `movewindow` |
| ⌥⌘H/J/K/L | `swapwindow` |
| ⌃⌘H/J/K/L | `resizeactive` (repeats) |
| ⌘1…9 / ⇧⌘1…9 | `workspace` / `movetoworkspace` |
| ⌘[ / ⌘] | previous / next non-empty workspace |
| ⌘S / ⇧⌘S | toggle / move to the `magic` scratchpad |
| ⇧⌘Space | `togglefloating` |
| ⌘F / ⇧⌘F | maximize / fullscreen |
| ⌘E / ⇧⌘E | `togglesplit` / `swapsplit` |
| ⌘R | resize submap (h/j/k/l, Esc to leave) |
| ⌘ + drag | move window (tiled: drop into place; floating: move) |
| ⌘ + right-drag | resize window |
| ⌘I | show a booted iOS Simulator in a tile (a menu if several are booted) |
| ⌘Esc / ⇧⌘Esc | simulator Home / Lock (`simbutton home|lock`) |
| ⌃⌘F (or the green button) | fill the screen / back to a window |
| ⇧⌘R / ⇧⌘M | reload config / exit |
| ⌘B | new web tile (start page, cursor in the address bar) |
| ⌘O | focus the address bar (Enter goes, Esc returns to the page) |
| ⌥⌘← / ⌥⌘→ / ⌥⌘R / ⌥⌘I | back / forward / reload / Web Inspector |

Keys that no bind claims go to the terminal, so ⌘C, ⌘V, and your Ghostty binds still work.

## Config

`~/.config/hypermux/hypermux.conf` (or `$HYPERMUX_CONFIG`). If the file is
missing, the built-in default ([config/hypermux.conf](config/hypermux.conf)) is
used. Menu → *Open Config…* writes the default there. Saving the file reloads it
live. Errors show in a red bar, like Hyprland.

Supported so far: `$variables`, nested sections, `source`, `general` (gaps,
border size, gradient border colors), `decoration` (rounding, opacity, dim,
shadow), `animations` (`bezier`, `animation` with Hyprland's inheritance tree
and `popin`/`slide`/`slidevert`/`fade` styles), `input:follow_mouse`, `dwindle`
(`preserve_split`, `force_split`, `split_width_multiplier`,
`default_split_ratio`), `binds:workspace_back_and_forth`, `bind[elnmrd]`,
`submap`, `exec-once`, `exec`.

Transparency: `misc:background_color = rgba(00000000)` makes the monitor window
see-through. `decoration:inactive_opacity` / `active_opacity` fade window
content (animated with `fadeSwitch`). `decoration:blur:enabled` adds a macOS
frosted-glass blur behind each window. Shadows are drawn only outside windows,
so they don't show through. Native fullscreen puts the window on its own Space,
with only black behind it. The default `misc:fullscreen_style = fill` avoids
that: full screen makes the window borderless and screen-sized on the normal
desktop, and auto-hides the menu bar and Dock while Hypermux is in front.

Web tiles: `web { home, search, open_terminal_links, address_bar }`. The
address bar takes URLs, hosts (`github.com/x`, `localhost:3000`), paths, or
search terms. Pages that open windows get their own tile. ⌘-click in a
terminal opens http(s) links in a web tile (set `open_terminal_links = false`
to use your default browser).

Two engines, picked with `web { engine = webkit | chromium }` (restart needed):

- **webkit**: WKWebView. Light, but no passkeys or security keys. Apple only
  allows WebAuthn in web views of apps it approved as browsers.
- **chromium**: bundled Chromium via CEF (+~370 MB). Chromium does WebAuthn
  itself, so passkeys from a phone (QR code) or a USB security key work. That
  covers Okta and GitHub. Passkeys stored on this Mac (Touch ID, iCloud
  Keychain) still need Apple's browser entitlement, so they don't. The profile
  lives in `~/Library/Application Support/Hypermux/Chromium`.

Chromium extras: `web:chromium_flags` passes switches (e.g.
`remote-debugging-port=9333`), and `web:chromium_extensions` loads unpacked
extensions. Extensions that only use content scripts or network rules can work.
Extensions that need tabs or windows (like 1Password) don't: embedded CEF
browsers aren't part of Chrome's tab model, so `chrome.tabs.query` finds nothing.

A `ghostty { ... }` block passes settings to libghostty. Your normal
`~/.config/ghostty/config` loads first.

## IPC

Like `hyprctl`. Shells inside hypermux get `HYPERMUX_SOCKET` and `HYPERMUX_CLIENT`.

```sh
swift build --product hypermuxctl
hypermuxctl dispatch workspace 2
hypermuxctl dispatch exec htop
hypermuxctl clients            # JSON
hypermuxctl workspaces
hypermuxctl dispatch web github.com
hypermuxctl sendkey SUPER, Return
hypermuxctl sendtext 'ls\n'
```

## Layout of the code

- `Sources/HypermuxCore` — pure Swift, no AppKit, unit tested.
  - `DwindleLayout` — the BSP tree: insert at a focal point, remove, resize, toggle/swap split.
  - `WindowManager` — workspaces, special workspaces, floating, fullscreen, focus
    history, dispatchers. Produces a `Snapshot` of frames. Side effects (spawn,
    close) go out as `Effect`s.
  - `Config` — hyprlang-style parser. `Dispatcher`, `Keys`, `Bezier`, `IPC`.
- `Sources/Hypermux` — the AppKit shell.
  - `Surfaces/` — the `Surface` protocol; `BrowserSurface` (address bar, start
    page, navigation) with `WebKitSurface` and `ChromiumSurface` engines.
  - `Ghostty/` — libghostty runtime callbacks and `TerminalView` (keyboard, IME,
    mouse, clipboard). Ported from Ghostty's macOS app.
  - `Compositor/` — applies snapshots to views, runs animations on a display link,
    routes binds and mouse drags, draws the bar and error banner.
- `Sources/ChromiumBridge` — Objective-C++ bridge to CEF: an NSApplication
  subclass, lifecycle, and browsers as child NSViews. CEF runs in "Alloy" style
  (required for embedding), which still shows Chrome's passkey dialog.
- `Sources/SimulatorBridge` — iOS Simulator displays through Xcode's private
  CoreSimulator/SimulatorKit (the route idb and Radon IDE use): the device's
  framebuffer IOSurface goes straight into a tile's layer. Clicks and drags
  become touches (with edge flags, so the home swipe works), keys go to the
  device as USB HID usages, and Home/Lock are hardware buttons. Touch messages
  follow idb's wire format (`Sources/SimulatorBridge/idb`, MIT).
  Touches stream live, one message per phase, as the mouse does it: press,
  hold, and release are separate, so long press and hand-timed drags work.
  Moves are "changed" contacts (digitizer mask Range|Touch|Position), not new
  touches, and a held finger is re-reported at 60 Hz like a real digitizer.
- `Sources/HypermuxHelper` — Chromium's helper process; the bundle script
  copies it into the four `Hypermux Helper*.app` bundles.
- `vendor/cef` (fetched) — CEF headers, C++ wrapper sources (built by SwiftPM),
  and the framework.
- `Sources/hypermuxctl` — the IPC client.

When a window animates, its terminal jumps to its final size once and the
rounded clip animates around it. That keeps shells from getting a resize signal
every frame.

## Credits

Terminal emulation, rendering, and input encoding: [Ghostty](https://github.com/ghostty-org/ghostty) (MIT).
`TerminalView` and `GhosttyInput` port parts of Ghostty's macOS sources.
Design inspired by [Hyprland](https://hyprland.org) and [cmux](https://github.com/manaflow-ai/cmux).
