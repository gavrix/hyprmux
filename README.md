# Hypermux

A Hyprland-style tiling environment for macOS, inside one window. Tiles hold
terminals ([libghostty](https://github.com/ghostty-org/ghostty)), web pages
(WebKit or Chromium), and live iOS Simulator screens. You drive them with
Hyprland's keybinds, dispatchers, workspaces, groups, and bezier animations,
configured in `hyprland.conf` syntax that reloads when you save it.

## Features

- **Tiling:** the dwindle layout, with directional focus, move and swap, keyboard
  and mouse resizing, floating windows (the first float centers, re-tiling returns
  to the old spot), and fullscreen or maximize.
- **Workspaces:** numbered workspaces that slide like Hyprland's, plus a scratchpad
  (special workspace).
- **Groups:** several windows as tabs in one tile, with a tab strip. Groups float,
  move, and fullscreen as a whole.
- **Terminals:** a full Ghostty terminal in each tile, with your Ghostty config,
  IME, mouse, clipboard, and shell integration.
- **Web tiles:** an address bar that takes URLs, hosts, or search terms. Popups
  open as new tiles, and ⌘-click on a terminal link opens it in a tile.
  - **WebKit engine:** light, but no passkeys.
  - **Chromium engine (CEF):** passkeys from your phone or a USB security key,
    enough for Okta and GitHub sign-in.
- **iOS Simulator tiles:** a booted simulator's screen at native resolution, with
  touch (tap, drag, long press, edge swipes), keyboard, and Home/Lock buttons.
  Simulator.app isn't needed.
- **Looks:** gradient borders, shadows, rounded or squircle corners
  (`rounding_power`), inactive-window opacity and blur, and a see-through
  background with a full-screen mode that keeps the wallpaper visible.
- **Notifications:** Hypermux's own notices, styled like your terminal and
  your window borders. Config errors, warnings, and terminal notifications
  (OSC 9 and OSC 777) show up there.
- **Pickers:** fzf-style lists in the same style, for choosing among several
  things (booted simulators for now). Type to filter, Return to choose.
- **Scripting:** `hypermuxctl`, a `hyprctl`-like CLI over a Unix socket.

## Requirements

- macOS 14 or later on Apple silicon.
- Xcode 16 or later (Swift 6 toolchain). Simulator tiles use the private
  frameworks of the selected Xcode (`xcode-select -p`).
- An installed [Ghostty](https://ghostty.org) or cmux app. The bundle script
  copies Ghostty's terminfo and shell integration from it; without one,
  terminals fall back to `TERM=xterm-256color`.
- About 1.5 GB of disk: the libghostty and Chromium SDK downloads, the build,
  and the app bundle (Chromium is always bundled; the engine is chosen at runtime).

## Build

```sh
git clone <this repo> hypermux && cd hypermux
scripts/bundle.sh           # downloads libghostty + the Chromium SDK (pinned, checksummed),
                            # builds, and assembles build/Hypermux.app
open build/Hypermux.app
```

The first run downloads about 260 MB and compiles everything, which takes a few
minutes. Later runs take seconds. Run `scripts/bundle.sh` (or both
`scripts/fetch-*.sh` scripts) before a plain `swift build`: SwiftPM needs the
downloaded SDKs in `vendor/`.

- **Release build:** `scripts/bundle.sh release`.
- **Tests:** `swift test`.
- **CLI:** `swift build --product hypermuxctl` builds it into
  `.build/debug/hypermuxctl`.

The app is signed ad hoc. That's enough to run it locally. Distributing it to
other Macs needs a Developer ID signature and notarization.

## Quick start

`SUPER` is ⌘. Keys are physical positions, so they work with any keyboard layout.

| Keys | Action |
|---|---|
| ⌘↩ | new terminal |
| ⌘B | new web tile (⌘O focuses the address bar) |
| ⌘I | show a booted iOS Simulator (a picker if several are booted) |
| ⌘W | close |
| ⌘H/J/K/L, ⌘ arrows | move focus |
| ⇧⌘H/J/K/L | move the window |
| ⌃⌘H/J/K/L, or ⌘R then H/J/K/L | resize |
| ⌘1…9 / ⇧⌘1…9 | switch workspace / move the window there |
| ⌘S | scratchpad |
| ⇧⌘Space | float / re-tile |
| ⌘F / ⇧⌘F | maximize / fullscreen the window |
| ⌃⌘F | full-screen Hypermux itself |
| ⌘G, ⌃Tab | make a group, switch tabs |
| ⌘ + drag / ⌘ + right-drag | move / resize with the mouse |
| ⇧⌘R | reload config |

The full default set is in [`config/hypermux.conf`](config/hypermux.conf).
Keys no bind claims go to the focused tile, so ⌘C and ⌘V still work in
terminals.

## Configuration

Hypermux reads `~/.config/hypermux/hypermux.conf`. Without it, the built-in
default applies; **Hypermux → Open Config…** (⌘,) writes that default out for you
to edit. Saving reloads it live. Your normal Ghostty config still applies to
terminals, and a `ghostty { }` block can override it.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for every option, bind
syntax, all dispatchers, and the IPC commands.

## Scripting

```sh
hypermuxctl dispatch workspace 2
hypermuxctl dispatch web github.com
hypermuxctl dispatch sim booted
hypermuxctl clients            # JSON for every window
```

Shells inside Hypermux get `HYPERMUX_SOCKET` and `HYPERMUX_CLIENT`, so
`hypermuxctl` run there talks to the right instance.

## Documentation

- [Architecture](docs/ARCHITECTURE.md): the model, the compositor, surfaces, and
  the Chromium and Simulator bridges.
- [Configuration](docs/CONFIGURATION.md): options, binds, dispatchers, IPC.
- [Development](docs/DEVELOPMENT.md): building, testing in a separate instance,
  the test tools, and pitfalls.

## Limitations

- **One monitor:** one Hypermux window acts as the monitor; there's no
  multi-display support yet.
- **Native macOS Spaces:** Hypermux can't move windows between them. macOS
  offers no API for it with SIP on.
- **Passkeys:** the WebKit engine has none. The Chromium engine supports phone
  (QR) and security-key passkeys. Mac passkeys (Touch ID, iCloud Keychain)
  need Apple's browser entitlement.
- **Chromium extensions:** those that need tabs (1Password, for example) don't
  work in tiles.
- **Private frameworks:** simulator tiles and the libghostty fork depend on
  private or fast-moving APIs, so an Xcode or libghostty update can break them.

## License

MIT, see [LICENSE](LICENSE). Third-party components keep their own licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Built on Ghostty, the Chromium Embedded Framework, and pieces of idb. Inspired by
[Hyprland](https://hyprland.org) and [cmux](https://github.com/manaflow-ai/cmux).
