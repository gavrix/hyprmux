# Client protocol (draft v0)

Status: draft. Milestone 1 is implemented: the broker, the handshake, buffers,
surfaces, toplevels, configure, frame callbacks, pointer, keyboard, cursor names,
and `new-surface --type app`. Milestone 2 is in progress: the Electron bridge
runs Reactotron and VS Code as client tiles, with dialogs, menus, and restore
tokens. Section 14 lists what the implementation does
differently from this text, or doesn't do yet.

Hyprmux is a small compositor inside one macOS window. Today it draws a fixed
set of tile kinds that it builds itself. The client protocol lets other
processes draw into tiles. A client renders its own pixels, hands them to
Hyprmux, and gets input back. Hyprmux lays the tile out, decorates it, and
animates it like any other tile.

This is a *nested* compositor. Hyprmux does not replace WindowServer. It is a
normal app with one window, and clients stay normal macOS processes. They keep
the pasteboard, notifications, the keychain, the file system, and TCC prompts.
The protocol only covers what a window would give them: pixels, input, and
the UI tied to a window, such as popups and dialogs. A client can still open a
real window for anything the protocol doesn't cover yet.

The design borrows from Wayland (object model, configure and ack, frame
callbacks, buffer release, xdg-shell roles, text-input-v3). It does not use
Wayland's wire format. See [Decisions](#12-decisions).

## 1. Who can be a client

- **Good fits:** apps that draw themselves. Examples: GPU-native editors
  (Zed, through a GPUI backend), browsers (Chromium through windowless CEF),
  Flutter apps (its embedder API targets custom surfaces), and wgpu, Metal, or
  SDL apps.
- **Bridges:** clients that translate an app that doesn't know about Hyprmux.
  Examples: the Electron bridge (an injected hook plus a helper), and later
  the iOS Simulator, the Android Emulator, and window capture.
- **Poor fits:** ordinary AppKit and SwiftUI apps. AppKit draws into
  WindowServer windows. No public API renders a view tree into our surface
  without losing fidelity.

## 2. Terms

| Term | Meaning |
|---|---|
| Compositor | Hyprmux. |
| Client | A process connected to the compositor. |
| Connection | One XPC connection. A client usually has one. |
| Object | A protocol object, identified by a 64-bit id that the creator allocates. |
| Surface | A rectangle of pixels the client draws. It has no meaning until it gets a role. |
| Role | What a surface is: `toplevel` (a tile), later `popup`. |
| Buffer | One image the client registered: an IOSurface or a shared-memory region. |
| Commit | Makes the pending surface state current, atomically. |
| Point | A layout unit, like AppKit. Pixels = points × scale. |

## 3. Transport

XPC carries the protocol. Unix sockets can't carry mach ports, and zero-copy
IOSurface sharing needs them (`IOSurfaceCreateXPCObject`).

A process can only listen on a named mach service when launchd started it
from a job that declares the name. Hyprmux is started from Finder, so it
can't own the name directly. A small broker owns it:

```
Hyprmux.app/Contents/Library/LaunchAgents/dev.gavrix.hyprmux.broker.plist
  MachServices: dev.gavrix.hyprmux.compositor   lookup, any client
                dev.gavrix.hyprmux.registrar    register, Hyprmux only
  BundleProgram: Contents/MacOS/hyprmux-broker
```

1. On every launch, Hyprmux registers the agent with
   `SMAppService.agent(plistName:)`. Registering again does nothing.
   - macOS may ask the user to allow Hyprmux in System Settings → General →
     Login Items & Extensions. Hyprmux then shows a notice that opens that
     pane. It checks again each time it becomes the active app, and connects
     once the agent is allowed.
   - Hyprmux skips registration when it doesn't run from an app bundle (a
     SwiftPM build in `.build`), or when `misc:register_broker = false`.
   - It also skips when another job already holds the broker label: the dev
     broker (`scripts/dev-broker.sh load`), or another Hyprmux copy's agent.
     It tells by pinging the lookup service while its own agent isn't
     enabled. The broker that is already running wins, so development keeps
     working.
   - Every copy of Hyprmux uses the same label and service names. One broker
     per login session serves them all. Instances keep their registrations
     apart.
   - `hyprmuxctl broker status` shows the agent's status, which program
     launchd runs, and who loaded it.
2. At startup, Hyprmux creates an anonymous XPC listener. It sends
   `register { instance, endpoint }` to `dev.gavrix.hyprmux.registrar`.
   - The broker sets a peer code-signing requirement on every registrar
     connection: identifier `dev.gavrix.hyprmux`, signed with the same
     certificate as the broker, and by the same team when the signature has
     one. The broker derives that from its own designated requirement and logs
     it at startup. An ad-hoc broker has no certificate, so it checks only the
     identifier. That is fine for local builds, and nothing a release should
     ship.
   - A registration lives as long as the connection that made it.
3. A client connects to `dev.gavrix.hyprmux.compositor` and sends
   `lookup { instance }`. The broker returns the endpoint, or `not_running`.
4. The client connects to that endpoint. From here on, the broker is not
   involved.

**Instances.** A test copy of Hyprmux runs next to the user's own. Each
registers under its `HYPRMUX_INSTANCE` name, which defaults to `default`.
Hyprmux sets the variable for everything it starts, so clients launched from
its tiles or terminals find the right instance.

When Hyprmux restarts, it registers a new endpoint. Clients see their
connection drop, look up again, and reconnect (section 10).

Messages are XPC dictionaries. Every message has `op` (a string) and, where
it applies, `id` (the object). Each connection has its own XPC queue. Hyprmux
handles messages on the main thread, in order.

## 4. Handshake

```
client → hello { version: 0, app_id, name, capabilities: [..], launch_token? }
server → welcome { version: 0, server_capabilities: [..], scale, monitor }
```

- `version` is the highest major version the client speaks. The compositor
  answers with the one it will use, or closes the connection with
  `error { code: "version" }`.
- `app_id` is the client's bundle identifier, or a reverse-DNS name for tools
  without a bundle.
- The compositor reads the caller's pid, uid, and team ID from the XPC audit
  token. `app_id` is only a hint.
- `launch_token` binds this connection to a tile Hyprmux is waiting to fill.
  See [Launch and restore](#10-launch-and-restore).
- Capabilities are strings like `text-input`, `cursor-image`, and `popups`. Each side uses only what both sides listed.

Errors are fatal. The compositor sends `error { code, message, id? }` and
closes the connection, like `wl_display.error`. Clients handle a lost
connection by reconnecting.

## 5. Objects

v0 has these objects. Clients create all of them, so all ids come from the
client.

```
connection
 ├ buffer        (iosurface)
 └ surface
    └ toplevel   (role)
```

### 5.1 `buffer`

```
client → buffer.create_iosurface { id, surface: <IOSurface XPC object> }
client → buffer.destroy { id }
server → buffer.release { id }
```

- **Format:** v0 accepts only `BGRA8` (IOSurface `'BGRA'`), with sRGB assumed
  unless the IOSurface carries a color space. `Display P3` and 10-bit formats
  come later.
- **Registration:** a client registers each swapchain image once, then refers
  to it by id. Sending a mach port every frame would be wasteful.
- **IOSurface only:** bridges create IOSurfaces in their own process, even
  when the app they translate can't. The Electron bridge copies the app's
  pixels into its own swapchain (section 11). That makes a shared-memory
  buffer type unnecessary, so v0 has none.
- **Release:** `release` means the compositor no longer reads the buffer, so
  the client may draw into it again. A buffer is busy from the commit that
  attaches it until its `release`. Drawing into a busy buffer causes tearing.

### 5.2 `surface`

```
client → surface.create { id }
client → surface.attach { id, buffer }              pending
client → surface.damage { id, rects: [[x,y,w,h]] }  pending, buffer pixels
client → surface.set_scale { id, scale }            pending
client → surface.set_opaque { id, opaque }          pending
client → surface.frame { id, callback }             pending
client → surface.commit { id }
client → surface.destroy { id }
server → surface.frame_done { callback, time, target_time }
```

- **Commit:** pending state becomes current atomically. The new buffer,
  damage, and scale show together.
- **Size:** the buffer size divided by scale gives the surface size in points.
- **Damage** is a hint. The compositor may redraw more.
- **Frame callbacks:** `frame` asks for one `frame_done` when it's a good time
  to draw the next frame. The compositor drives these from the display link
  of the monitor's screen:
  - `time` is when the compositor sent the callback.
  - `target_time` is the next display refresh the frame should aim for.
  - An occluded or hidden surface gets no callbacks. That throttles it to zero
    without extra protocol.
- **Opaque:** `set_opaque(true)` lets the compositor skip blending. Tiles with
  inactive opacity still apply their opacity.

### 5.3 `toplevel`

A toplevel is a tile. The compositor decides where it goes. The client
suggests, the compositor decides.

```
client → toplevel.create { id, surface }
client → toplevel.set_title { id, title }
client → toplevel.set_restore_token { id, token }     ≤ 4 KiB, opaque
client → toplevel.set_min_size { id, w, h }           points
client → toplevel.request_fullscreen { id, on }
client → toplevel.request_activate { id, activation_token }
client → toplevel.ack_configure { id, serial }
client → toplevel.destroy { id }

server → toplevel.configure { id, serial, w, h, scale, states: [..] }
server → toplevel.close_requested { id }
```

- **Configure:** the compositor sends a size in points, the backing scale, and
  a state set. Clients ack the serial, then commit a buffer of
  `w×scale` by `h×scale`.
  - Until then, the compositor shows the last buffer scaled to fit, on the
    tile's backdrop color. This keeps tiling animations smooth: Hyprmux
    already resizes content once per animation, not once per frame.
  - A configure with `w = 0` or `h = 0` means "choose your size", as for a
    floating tile with no stored rect.
- **States:** `activated` (keyboard focus), `occluded` (not visible),
  `fullscreen`, `floating`, `resizing` (a live mouse resize), and
  `tiled_left/right/top/bottom` (edges that touch neighbours or the monitor).
- **Title** feeds the bar and `hyprmuxctl clients`.
- **Close:** `close_requested` is a request. The client may ask its user
  first, then destroys the toplevel. The compositor never kills the process.
- **Activation:** `request_activate` needs a token the compositor issued. It
  comes from `launch_token`, or from an input event the client received. A
  client can't steal focus without one.
- **Placement:** there's no request for a workspace or position. Placement is
  policy, driven by `windowrule` config later, not by the protocol.

## 6. Input

The compositor translates `NSEvent`s and sends them to the surface under the
pointer or with keyboard focus. Coordinates are surface points, top-left
origin. Hyprmux's own binds (the local key monitor, ⌘-drag) take events
first, and those never reach clients.

### 6.1 Pointer

```
server → pointer.enter { surface, serial, x, y }
server → pointer.leave { surface, serial }
server → pointer.motion { surface, time, x, y, buttons, modifiers }
server → pointer.button { surface, serial, time, x, y, button, state, click_count, modifiers }
server → pointer.scroll { surface, time, x, y, dx, dy, precise, phase, momentum_phase, ticks_x, ticks_y, modifiers }
server → pointer.gesture { surface, time, kind, value, phase }        v0.1: magnify, rotate
client → pointer.set_cursor { name }                                  "arrow", "ibeam", "pointing_hand", ...
client → pointer.set_cursor_image { buffer, hot_x, hot_y }            cap: cursor-image
```

- **Scroll** carries AppKit's own values: `scrollingDeltaX/Y`,
  `hasPreciseScrollingDeltas`, `phase`, and `momentumPhase`. The prototype
  showed the cost of losing them: Chromium-based clients then derive
  `wheelDeltaY` from ticks, and VS Code ignored every scroll.
- **Units:** with `precise`, `dx`/`dy` are points (trackpads). Without it, they
  are lines (notched wheels, accelerated), and `ticks_x`/`ticks_y` carry the
  raw notch count from the CGEvent. Chromium scrolls 40 pixels per line and
  uses raw notches as wheel ticks. A client that treated lines as pixels
  scrolled 1 pixel per notch.
- **Buttons:** `button` is 0 left, 1 right, 2 middle, 3+ others. `state` is
  `down` or `up`.
- **Implicit grab:** while a button is held, events keep going to the surface
  where the press started, even outside it.

### 6.2 Keyboard

```
server → keyboard.enter { surface, serial, pressed_keys, modifiers }
server → keyboard.leave { surface, serial }
server → keyboard.key { surface, serial, time, key_code, state, repeat,
                        characters, characters_ignoring_modifiers, modifiers }
server → keyboard.modifiers { surface, modifiers }
server → keyboard.layout { id, name }       the current input source
```

- `key_code` is the macOS virtual key code, the same as in `NSEvent.keyCode`.
  Clients that need layout tables use `UCKeyTranslate` with the layout's id.
- `characters` fields match `NSEvent`. Clients without IME handling may use
  them directly.

### 6.3 Text input (IME)

Hyprmux owns the `NSTextInputClient` in its key window. That way, IME,
dictation, the emoji picker, press-and-hold accents, and AutoFill all work.
Those features need the key window, which a client process never has.

```
client → text_input.enable { surface, content_type, hints }
client → text_input.disable { surface }
client → text_input.set_cursor_rect { surface, x, y, w, h }     for the candidate window
client → text_input.set_surrounding { surface, text, cursor, anchor }
client → text_input.commit_state { surface, serial }

server → text_input.preedit { surface, text, cursor_begin, cursor_end }
server → text_input.commit { surface, text }
server → text_input.delete_surrounding { surface, before, after }
server → text_input.done { surface, serial }
```

This mirrors Wayland's text-input-v3. The client applies events between two
`done`s atomically. While text input is enabled, key events that the input
method consumes don't also arrive as `keyboard.key`.

## 7. Window UI through the compositor (v0.1)

Native UI tied to a window breaks for a client. The client has no visible
window, and it isn't the active app. The prototype hit this with VS Code's
Open Folder: the sheet sat on a hidden window, behind Hyprmux, and blocked
the app. Clients ask the compositor to show the UI instead.

```
client → dialog.open { id, surface, kind: open|save|alert, options }
server → dialog.result { id, cancelled, urls?, bookmarks?, button? }

client → menu.popup { id, surface, x, y, items: [..] }
server → menu.selected { id, item_id? }

client → popup.create { id, surface, parent, positioner }     cap: popups
server → popup.configure { id, serial, x, y, w, h }
server → popup.dismissed { id }
```

- **Dialogs** show as sheets over the tile, using `NSOpenPanel`,
  `NSSavePanel`, and `NSAlert`. For sandboxed clients, `bookmarks` carries
  security-scoped bookmark data.
- **Menus** are item trees: `id`, `title`, `enabled`, `checked`, `key`, and
  `children`. The compositor builds an `NSMenu`.
- **Popups** are client-drawn child surfaces, such as Chromium's `<select>`
  lists and tooltips. A positioner anchors them to a parent rectangle, like
  `xdg_positioner`. The compositor keeps them on the monitor and closes them
  on an outside click.

## 8. Accessibility (v0.2)

VoiceOver sees Hyprmux's views, not a client's UI. A client can send an
[AccessKit](https://github.com/AccessKit/accesskit) tree update per commit.
Hyprmux exposes it through an AccessKit macOS adapter placed on the tile's
view, and returns actions (focus, press, set value). GPUI already builds
AccessKit trees, and Chromium has its own accessibility tree to translate.

## 9. Other features, later

- **Drag and drop** in both directions (v0.2).
- **Presentation feedback**, meaning actual present times for latency
  tuning (v0.2).
- **Layer tree hosting:** a client may send a `CAContext` id instead of
  buffers, and the compositor shows it with `CALayerHost`. It's private API,
  so it's optional. It would let clients use Core Animation directly.
- **Menu bar:** a client may publish its app menu. Hyprmux shows it while
  the tile has focus, and routes ⌘ key equivalents to it. That fixes menu
  accelerators for bridged apps.

## 10. Launch and restore

- **Launching a client:** the launcher and `hyprmuxctl launch` (an app's
  `.hmapp`, see [APPS.md](APPS.md)), the `launch` dispatcher, or
  `hyprmuxctl new-surface --type app -- <bundle id or path> [args]`.
  1. Hyprmux reserves a tile slot and makes a one-time `launch_token`.
  2. It starts the client with `HYPRMUX_LAUNCH_TOKEN` in the environment.
  3. The first toplevel that arrives with that token fills the slot.
  4. A slot with no toplevel after a timeout shows an error notice and
     closes.
- **Unsolicited clients:** a client that connects without a token gets a new
  tile, the same way a new terminal does.
- **Session restore:** Hyprmux stores the tile as a `SessionTile` with
  `client: { app_id, launch, restore_token }`.
  - On restore, it relaunches with `HYPRMUX_LAUNCH_TOKEN` and
    `HYPRMUX_RESTORE_TOKEN`.
  - The client uses the token to reopen the same document, folder, or URL.
  - A client that's already running gets the restore token over its
    connection instead (`restore { token, launch_token }`).
- **Reconnecting:** when Hyprmux restarts, a client can reconnect and resend
  its toplevels with their restore tokens. Hyprmux matches them to saved
  tiles.
- **Activation policy:** a client with no real windows should switch to
  `NSApplication.ActivationPolicy.accessory`, which hides its Dock icon and
  ⌘Tab entry. The SDK does this by default.

## 11. SDK and bridges

- **`libhyprmux-client`:** a C ABI that handles the connection, handshake,
  reconnects, swapchains, and callbacks. Chromium is C++ and Zed is Rust, so a
  Swift-only SDK would shut out both of the first real clients. Swift and Rust
  wrappers sit on top.
  - **Swapchain helper:** allocates three IOSurfaces at the configured
    pixel size, registers them, and gives the client a free one that's been
    released.
  - **Metal helper:** wraps an IOSurface as an `MTLTexture`.
- **Rust client:** `clients/rust/hyprmux-client`, at the same level as the
  Swift kit: broker lookup and hello, requests, typed events on the main
  queue, and IOSurface allocation. It calls libxpc directly, so its only
  dependency is `block2`.
- **GPUI (Zed):** a `hyprmux` module in `gpui_macos` (on a Zed branch) turns
  GPUI windows into tiles when Hyprmux launched the process. It keeps
  `MacPlatform` for everything else.
  - GPUI's Metal renderer draws into a three-buffer IOSurface swapchain,
    through `MetalRenderer::new_offscreen` and `draw_to_texture`.
  - Frames are demand-driven. GPUI's `schedule_frame` asks for one frame
    callback, so idle and hidden tiles draw nothing.
  - Keys become NSEvents parsed by `gpui_macos`'s own keystroke code, and
    text input goes to GPUI's input handler. GPUI draws its own compositions,
    so it enables text input with `preedit = client`.
  - Prompts and file panels go through `dialog.open`. GPUI draws its own
    menus and popovers, so it needs no `menu.popup` or popup role.
- **Electron bridge:** the injected hook from `prototypes/electron-embed`
  plus a signed helper.
  - Node in an Electron app can't speak XPC. Hardened Electron apps also
    refuse our native addons (checked: Cursor, VS Code, Logseq, Reactotron,
    and Slack).
  - **Injection:** the helper starts the app with
    `--inspect-brk=PORT --inspect-publish-uid=stderr`, reads the inspector's
    WebSocket URL from the app's stderr, stops at the app's entry script, and
    loads the hook there. The hook closes the inspector as its last step,
    before the app's code runs: about 300 ms after launch (740 ms for
    Cursor). The inspector's HTTP endpoints never list the URL, and a second
    debugger session stops the app. See
    [ADAPTERS.md, Security](ADAPTERS.md#security) for the model.
  - So the hook writes each window's `paint` dirty rects into a per-window
    pixel file with `writeSync`, which takes about 2 ms for a full 13 MB frame.
    The helper maps the file and copies from it into its own IOSurface
    swapchain. The Unix socket carries only small messages: "this rect
    changed", input, dialogs, and menus.
  - Pixels never go through the socket. macOS Unix sockets move 8 KB per
    write, and Node can't raise the send buffer, so a 13 MB frame needed
    about 1,600 event-loop turns of the app's main process. In VS Code, that
    meant 100–550 ms per frame.
  - The pixel file only grows, so the helper's mapping never points past
    its end. The helper may copy while the hook writes the next frame. That
    can tear one frame but can't crash either side.
  - It also proxies dialogs (`dialog.*` to `dialog.open`), menus
    (`Menu.popup` to `menu.popup`), and cursors. A menu without a position
    opens at the last pointer position in its window, as Electron's native
    menus open at the cursor. VS Code's right-click menus rely on that.
  - `<select>` popups: on macOS, Chromium shows them as a native menu on the
    hidden window, which offscreen rendering never displays (electron#34047).
    Before each left mouse-down, the hook asks the page what's under the
    pointer. On a `<select>`, it drops the click and shows the options through
    `menu.popup`, then applies the pick with `input` and `change` events.
  - **Drag and drop doesn't work.** Electron's offscreen view cancels every
    drag as it starts and accepts no drops (`StartDragging` ends it at once,
    `GetDropData` is null). Dragging tabs or files inside the app, and dropping
    files from Finder, need an emulation in the page; there is none yet.
- **Built-in sources:** the iOS Simulator and Android Emulator surfaces can
  later become in-process implementations of the same interface. That leaves
  one `ClientSurface` in the app instead of one surface class per source.

## 12. Decisions

- **XPC plus a broker, not a Unix socket:** only mach ports carry IOSurfaces
  without copies. The broker exists because Hyprmux can't own a launchd mach
  service name.
- **No shared-memory buffers:** an earlier draft had `buffer.create_shmem` for
  bridges. The Electron bridge copies into its own IOSurfaces instead. A
  `shmem` buffer would save that one copy, but only by moving it into
  Hyprmux, which would then upload to a texture. It isn't worth a second
  buffer path in the compositor.
- **Our own wire format, not Wayland's:**
  - Toolkits enable their Wayland backends only on Linux, so speaking real
    Wayland wouldn't bring existing Mac clients.
  - Wayland buffers are file descriptors. IOSurfaces aren't.
  - XPC gives us audit tokens and typed messages for free.
  - We keep Wayland's semantics, so porting a Wayland-shaped client backend
    stays mechanical.
- **Clients allocate ids:** v0 has no server-created objects. When
  compositor-created objects arrive (for example, drag offers), they take ids
  with the top bit set.
- **The compositor owns placement and text input:** the client never picks a
  workspace or position. The compositor owns the `NSTextInputClient`, because
  the client never has the key window.
- **IOSurface is the baseline, and `CALayerHost` is optional:** the baseline
  must be public API.

## 13. Plan (as drafted)

**Spikes, which decide whether the design above holds:**

1. **Transport: done, it holds.** `prototypes/client-protocol/spike-transport`
   (`run.sh`) loads an ad-hoc signed broker with `launchctl`, registers an
   anonymous endpoint, looks it up from a client, and sends IOSurfaces. On
   Apple silicon:
   - Lookup before registration returns `not_running`, as designed.
   - Lookup, connect, and first ping take 0.27 ms.
   - A bare message round trip takes 15 µs p50 and 79 µs p99.
   - Registering a 2216×1308 IOSurface costs 4 ms the first time, which
     includes allocating it, and 35 µs after that. Both sides see the same
     global IOSurface id, so nothing is copied.
   - A commit by buffer id, with the compositor reading the client's pixel
     back, takes 12 µs p50 and 55 µs p99. The pixel matched 300 out of 300
     times.

   `SMAppService`, checked later with an Apple Development build on macOS 26:
   - `register()` enabled the agent at once, with no approval step. macOS
     posted its own notification: "“HyprmuxTest” can run in the
     background. You can manage this in Login Items & Extensions settings."
     It names the app after the bundle's file name.
   - Before the first registration, `status` reports `.notFound`, not
     `.notRegistered`. After `unregister()`, it reports `.notRegistered`.
   - launchd lists the job as `type = Submitted`,
     `managed_by = com.apple.xpc.ServiceManagement`, with a program path
     relative to the app.
   - An app tile connected through the registered broker.
   - Still unchecked: an ad-hoc build, and the approval path. macOS asks for
     approval only when the user has turned Hyprmux off in Login Items.
   The peer code-signing requirement on `register` works for ad-hoc and
   signed brokers (section 3).
2. **Chromium passkeys in windowless CEF:** Chrome's WebAuthn dialog and the
   macOS passkey UI want a window in the requesting process. If passkeys
   break, the Chromium client keeps an in-process fallback for sign-in.

**Milestones:**

1. **v0 core:**
   - The broker and a `ClientSurface: Surface` in the app.
   - The handshake, buffers, surfaces, toplevels, configure, and frame
     callbacks.
   - Pointer, keyboard, cursor names, and `hyprmuxctl new-surface --type app`.
   - The first client: a small Swift Metal demo that draws a gradient, shows
     the pointer, and echoes keys.
2. **Electron bridge on v0:** `dialog.*`, `menu.popup`, and restore tokens
   (the VS Code folder).
3. **Text input** (IME) and popups.
4. **Chromium client** (windowless CEF) behind `web:engine = chromium-client`,
   next to the in-process engine.
5. **Zed:** a GPUI backend, the first client written like a third party
   would write it.
6. **Accessibility,** drag and drop, and the menu bar.

## 14. Implementation status

Milestone 1 is in place. Code:

- `Sources/HyprmuxClientProtocol`: service names and ops.
- `Sources/hyprmux-broker`: the broker.
- `Sources/Hyprmux/Clients`: `ClientServer`, `ClientConnection`, and
  `ClientSurface`.
- `Sources/HyprmuxClientKit`: the Swift kit.
- `Sources/hyprmux-demo-client`: the demo client.

Measured on a 60 Hz display, with the demo at 2518×2760 px: about 58 fps while
the demo spends 7 ms drawing each frame on the CPU.

Differences from the text above:

- **Swift kit first.** The C ABI comes with the first C++ or Rust client. The
  Swift kit is its reference.
- **Buffer release:** a replaced buffer is released once `IOSurfaceIsInUse`
  turns false. The compositor polls every 2 ms after a commit. Checking only
  on display-link ticks held each buffer for an extra frame, which starved a
  three-buffer swapchain.
- **Ignored for now:** `surface.damage` and `surface.set_opaque`. Core
  Animation redraws the whole layer.
- **Cursor:** `pointer.set_cursor` applies to every toplevel of the
  connection, and `hidden` shows the arrow.
- **Not yet:** `request_fullscreen`, `request_activate`, `set_min_size`, and
  popups.
- **Session restore** of app tiles works: tiles relaunch their app and match
  windows by restore token.
- **Text input:** `enable`, `disable`, `set_cursor_rect`, and the four server
  events are implemented. `set_surrounding` and `commit_state` aren't; ranges
  count characters committed since `enable`, which is enough for
  press-and-hold to replace the last character.
  - `text_input.enable` takes `preedit`: `client` (the default) or
    `compositor`. With `compositor`, Hyprmux draws the composition itself, at
    the cursor rect. The Electron bridge uses that, since Electron has no API
    to show one.
  - A key the input method uses (a dead key, a composition, an accent pick)
    arrives only as text-input events. Its `keyboard.key` press and release
    are dropped. Other keys arrive as `keyboard.key`, unchanged.
  - Dead keys and IME compositions need Hyprmux to be the active app. Commits
    from outside a key press (the emoji picker, dictation) and
    `hyprmuxctl send --surface ID TEXT` don't.
- **Shortcuts:** Hyprmux's binds win over app tiles, except chords an app's
  `pass` list claims (`app:<id> { pass = … }`, see
  [CONFIGURATION.md](CONFIGURATION.md)). Those reach the app even when they're
  Hyprmux menu shortcuts.
- **Launching:** `new-surface --type app -- TARGET ARGS...` takes argv.
  `hyprmuxctl` quotes each argument, and Hyprmux splits them with shell
  quoting rules, so paths with spaces work. An `.app` that doesn't speak the
  protocol goes through the adapter that matches it. See
  [ADAPTERS.md](ADAPTERS.md).
- **Broker loading:** Hyprmux registers the bundled agent with
  `SMAppService` on launch (section 3). While no broker answers, it retries
  every 5 seconds, so a broker loaded later is picked up.

