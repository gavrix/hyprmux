# Third-party notices

Hyprmux builds on the following projects. Fetch scripts download the large,
pinned SDK binaries; small runtime resources are checked into this repository.

| Component | Used as | License |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty) / libghostty | Terminal emulation and rendering. Prebuilt `GhosttyKit.xcframework` from the [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty) fork (the build cmux ships), fetched by `scripts/fetch-ghosttykit.sh`. | MIT |
| Ghostty macOS sources | `TerminalView` and `GhosttyInput` port parts of Ghostty's `SurfaceView_AppKit.swift`, `Ghostty.Input.swift`, and `NSEvent+Extension.swift`. | MIT |
| Ghostty terminfo | Compiled `ghostty` and `xterm-ghostty` entries bundled under `Resources/terminfo`. | MIT |
| Ghostty shell integration | Bash, Zsh, Fish, Elvish, and Nushell integration bundled under `Resources/ghostty/shell-integration`. Individual files retain their license headers; the Bash and Zsh integrations include GPL-3.0 code derived from Kitty. | GPL-3.0 and MIT |
| [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) | Ghostty-compatible themes bundled under `Resources/ghostty/themes`. | MIT |
| [Chromium Embedded Framework](https://github.com/chromiumembedded/cef) | Optional Chromium web engine, fetched by `scripts/fetch-cef.sh`. Chromium itself carries many component licenses; see the `CREDITS.html` in CEF distributions. | BSD-3-Clause (CEF), various (Chromium) |
| [idb](https://github.com/facebook/idb) | `Sources/SimulatorBridge/idb/Indigo.h` and `Mach.h` (simulator HID wire format), and the design of the single-touch message builder. | MIT |
| [grpc-swift](https://github.com/grpc/grpc-swift) | gRPC 1.x client transport for Android Emulator tiles. Resolved by SwiftPM. | Apache-2.0 |
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | Protocol Buffers runtime for the Android Emulator client. Resolved by SwiftPM. | Apache-2.0 |
| [Android Emulator](https://android.googlesource.com/platform/external/qemu/) protocol definitions | The checked-in generated client uses a minimal wire-compatible subset of `emulator_controller.proto`. | Apache-2.0 |

Hyprmux also uses Apple's private CoreSimulator and SimulatorKit frameworks,
loaded at runtime from the installed Xcode, for iOS Simulator tiles. They are
not redistributed.

Design is inspired by [Hyprland](https://hyprland.org) (config syntax,
dispatcher names, dwindle layout, groups) and
[cmux](https://github.com/manaflow-ai/cmux). No cmux or Hyprland code is
included.
