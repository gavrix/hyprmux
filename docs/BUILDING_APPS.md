# Building for Hyprmux

> **Experimental.** The client protocol is a draft. Messages, the Swift kit,
> the Rust crate, and the `.hmapp` format may still change between releases.

Other programs can draw into Hyprmux tiles. This page describes what exists
today and how to try it. The reference is the
[client protocol](CLIENT_PROTOCOL.md) spec.

## How it works

Hyprmux is a small compositor inside one macOS window. A client is a separate
process that draws its own pixels into IOSurfaces (shared GPU memory buffers)
and hands them to Hyprmux over XPC. Hyprmux places the tile, decorates it,
animates it, and sends input back. The design borrows from Wayland: configure
and acknowledge, frame callbacks, and buffer release.

Clients stay normal macOS processes. They keep the pasteboard, notifications,
the keychain, the file system, and permission prompts. The protocol covers
only what a window gives them: pixels, input, dialogs, menus, and cursors.

Clients find Hyprmux through `hyprmux-broker`, a helper that macOS runs in the
background. Hyprmux registers it on launch.

## Who uses it today

- **Mobile:** Hyprmux's built-in app for iOS Simulators and Android Emulators.
  It's a Swift client: `Sources/hyprmux-mobile`.
- **The Electron bridge:** lifts VS Code, Cursor, and other Electron apps into
  tiles. It's a Swift client too: `Sources/hyprmux-electron-bridge`.
- **Zed:** a GPUI backend in a [fork](https://github.com/gavrix/zed/tree/hyprmux)
  of Zed, written against the Rust crate.
- **The demo client:** `Sources/hyprmux-demo-client`, an animated test tile.

## What works, and what doesn't

Working:

- The broker and the handshake.
- Toplevels (tiles), IOSurface buffers, subsurfaces, configure, and frame
  callbacks. Hidden tiles get no frame callbacks, so they cost nothing.
- Pointer, keyboard, cursors, and text input (IME), including dead keys and
  press-and-hold accents.
- Open panels, save panels, and alerts, shown by Hyprmux as sheets over the
  tile. Context menus, built by Hyprmux from an item tree.
- Launches from the launcher, a bind, or `hyprmuxctl`, including apps that
  offer several windows to pick from.
- Session restore through restore tokens.

Not yet:

- Popups, fullscreen and activate requests, and minimum sizes.
- Reconnecting after Hyprmux restarts. The client's tiles are gone, so the
  demos exit when the connection drops.
- Damage regions. Hyprmux redraws the whole tile on each commit.
- Accessibility.
- A C library. Clients use the Swift kit, the Rust crate, or raw XPC.
- Launch offers and subsurfaces in the Rust crate.
- A published package. Both the kit and the crate build from this repo only.

[Section 14 of the spec](CLIENT_PROTOCOL.md#14-implementation-status) has the
full list.

## Try it

Install Hyprmux and launch it first. Allow it to run in the background when
macOS asks: clients can't find Hyprmux without the broker.
`hyprmuxctl broker status` says whether it runs.

### Rust

```sh
git clone https://github.com/gavrix/hyprmux.git
cd hyprmux/clients/rust/hyprmux-client
cargo run --example demo        # one tile; click to change its color
cargo run --example latency     # measures frame-callback latency
```

The crate calls libxpc and IOSurface directly. Its only dependency is
`block2`. See [its README](../clients/rust/hyprmux-client/README.md).

### Swift

The Swift package needs the downloaded SDKs in `vendor/`, even for the demo:

```sh
git clone https://github.com/gavrix/hyprmux.git && cd hyprmux
scripts/fetch-ghosttykit.sh && scripts/fetch-cef.sh
swift build --product hyprmux-demo-client
hyprmuxctl new-surface --type app -- "$(swift build --show-bin-path)/hyprmux-demo-client"
```

Run `hyprmuxctl` from a Hyprmux terminal, or use the copy in
`Hyprmux.app/Contents/MacOS/`. The demo shows the pointer, buttons, scrolling,
focus, and typed keys. `HM_DEMO_STATS=1` prints its frame rate to stderr.

A minimal client fills its tile with one color:

```swift
import Foundation
import HyprmuxClientKit
import IOSurface

let client = HMClient(appID: "com.example.hello", name: "Hello")
try client.connect()
client.onDisconnect = { _ in exit(0) }

let top = client.makeToplevel(title: "Hello")
top.onCloseRequested = { top.destroy(); exit(0) }
top.onConfigure = { _ in draw() }

func draw() {
    guard let buffer = top.acquireBuffer() else { return }
    IOSurfaceLock(buffer.surface, [], nil)
    let pixels = IOSurfaceGetBaseAddress(buffer.surface)
    memset(pixels, 0x40, buffer.bytesPerRow * buffer.height)   // BGRA: translucent gray
    IOSurfaceUnlock(buffer.surface, [], nil)
    top.present(buffer)
}

dispatchMain()
```

`acquireBuffer()` gives a free IOSurface at the tile's pixel size, from a
three-buffer swapchain the kit manages. `present` attaches it, acknowledges
the latest configure, and commits. Pass a closure to `present` to draw again
on the next frame callback.

## Put it in the launcher

The launcher lists `.hmapp` bundles: a folder with an `Info.json`. Mobile's
looks like this:

```json
{
  "format": 1,
  "id": "dev.gavrix.hyprmux.mobile",
  "name": "Mobile",
  "kind": "native",
  "exec": "hyprmux-mobile",
  "instances": "single"
}
```

For your own client, set `exec` to an absolute path, or to a path inside the
bundle such as `bin/hello`. Put the bundle in `~/.config/hyprmux/apps/`, then
run `hyprmuxctl apps refresh`. A downloaded bundle that carries code needs a
valid Apple signature, or Hyprmux asks before it runs it. See
[Apps](APPS.md#what-a-hmapp-is) for every key, and [Trust](APPS.md#trust).

## Lift an app you don't control

An adapter is a JSON manifest plus a program. Hyprmux runs the program in
place of the app, and the program turns the app's windows into tiles. The
Electron bridge is the only adapter so far. See [Adapters](ADAPTERS.md) for
the manifest, the probe that decides which apps it matches, and its security
model.

## Feedback

Open an issue for questions and protocol feedback. The design is still open,
so reports about what's missing for your toolkit help the most.
