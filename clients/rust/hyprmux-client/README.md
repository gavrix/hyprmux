# hyprmux-client

A Rust client for the Hyprmux client protocol ([CLIENT_PROTOCOL.md](../../../docs/CLIENT_PROTOCOL.md)).
It is the Rust counterpart of the Swift `HyprmuxClientKit`, at the same level:

- `Client::connect` looks Hyprmux up through the broker, says hello, and
  presents `HYPRMUX_LAUNCH_TOKEN`, so the first toplevel fills the tile Hyprmux
  reserved for this process.
- Requests: toplevels, IOSurface buffers, attach and commit, frame callbacks,
  cursors, text input, dialogs, and menus.
- Events arrive as a typed `Event` on the main dispatch queue.
- `surface::Surface` allocates BGRA8 IOSurfaces, for clients without their own.

It talks to libxpc and IOSurface directly, so its only dependency is `block2`.
Swapchains, frame pacing, and input mapping belong to the toolkit using it.

```sh
# Next to a test instance (docs/DEVELOPMENT.md): one tile, solid color, input on stderr.
HYPRMUX_INSTANCE=test cargo run --example demo
```

Users:

- **GPUI (Zed):** a backend in `gpui_macos` that turns GPUI windows into tiles.
  It renders with GPUI's Metal renderer into registered IOSurfaces.
