# Third-party notices

Hypermux builds on the following projects. None of their binaries are checked
into this repository; the fetch scripts download pinned versions.

| Component | Used as | License |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty) / libghostty | Terminal emulation and rendering. Prebuilt `GhosttyKit.xcframework` from the [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty) fork (the build cmux ships), fetched by `scripts/fetch-ghosttykit.sh`. | MIT |
| Ghostty macOS sources | `TerminalView` and `GhosttyInput` port parts of Ghostty's `SurfaceView_AppKit.swift`, `Ghostty.Input.swift`, and `NSEvent+Extension.swift`. | MIT |
| Ghostty resources | terminfo, shell integration, and themes, copied into the bundle from an installed Ghostty.app or cmux.app by `scripts/bundle.sh`. | MIT |
| [Chromium Embedded Framework](https://github.com/chromiumembedded/cef) | Optional Chromium web engine, fetched by `scripts/fetch-cef.sh`. Chromium itself carries many component licenses; see the `CREDITS.html` in CEF distributions. | BSD-3-Clause (CEF), various (Chromium) |
| [idb](https://github.com/facebook/idb) | `Sources/SimulatorBridge/idb/Indigo.h` and `Mach.h` (simulator HID wire format), and the design of the single-touch message builder. | MIT |

Hypermux also uses Apple's private CoreSimulator and SimulatorKit frameworks,
loaded at runtime from the installed Xcode, for iOS Simulator tiles. They are
not redistributed.

Design is inspired by [Hyprland](https://hyprland.org) (config syntax,
dispatcher names, dwindle layout, groups) and
[cmux](https://github.com/manaflow-ai/cmux). No cmux or Hyprland code is
included.
