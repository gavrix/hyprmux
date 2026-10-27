# hyprmux-qml

> **Experimental.** The `Hyprmux` QML module may change between releases.

The QML host: renders QML into Hyprmux surfaces, tiles, items in the workspace
bar, and popups under them. Hyprmux runs it for each `plugin =` line; see
[Plugins](../../docs/PLUGINS.md). `scripts/bundle.sh` builds it and puts it in the
app.

Qt Quick draws through `QQuickRenderControl` into the client's IOSurface
swapchain. Each IOSurface is wrapped as a Metal texture, so no pixels are copied.
The host speaks the client protocol over raw libxpc.

## Build

Needs CMake. Qt is the pinned copy the app ships, in `vendor/qt`
(`scripts/fetch-qt.sh` downloads it; `scripts/bundle.sh` does too):

```sh
../../scripts/fetch-qt.sh
cmake -S . -B build -DCMAKE_PREFIX_PATH=../../vendor/qt -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build -j 8
ctest --test-dir build --output-on-failure    # unit tests
```

In the app, `scripts/deploy-qt.sh` puts the Qt frameworks, plugins, and QML
modules the host needs into the bundle (about 40 MB) and points the host at them.
Only the Basic Qt Quick Controls style ships, and the host makes it the default.
The bundled Qt needs macOS 14.4.

## Layout

| Folder | What's there |
|---|---|
| `src/protocol` | The client protocol over raw libxpc. |
| `src/render` | The swapchain: IOSurfaces wrapped as Metal textures. |
| `src/scene` | A QML scene as a surface: roles, the render loop, input. |
| `src/qml` | The `Hyprmux` QML module's types, and the logic under them. |
| `tests` | Qt Test unit tests for the logic that needs no window system. |

## Checking QML

The build writes the module's type information to `build/Hyprmux`. Point
`qmllint` at it to check a plugin or app before running it:

```sh
../../vendor/qt/bin/qmllint -I build ../../Resources/plugins/sysload/*.qml
```

The built-in plugins lint clean; keep them that way.

## Run

A QML file whose root is an `Item` becomes a tile:

```sh
hyprmuxctl new-surface --type app --workspace empty -- "$PWD/build/hyprmux-qml" "$PWD/examples/demo.qml"
```

A plugin is a folder with a `plugin.json`. Load it from the config, and
`scripts/bundle.sh` puts this host in the app:

```ini
plugin = sysload          # built in: Resources/plugins/sysload
plugin = ~/src/my-plugin  # or any folder
```

Started by hand instead, the host runs, but Hyprmux refuses its bar item: only
processes it started for a `plugin =` line are plugins. Its settings come from
`config.json` in `HYPRMUX_PLUGIN_CONFIG_DIR` (docs/PLUGINS.md, Settings).

## The `Hyprmux` QML module

| Type | What it is |
|---|---|
| `HyprmuxWindow` | An app window, shown as a tile: `title`, `color`, `active`, `restoreToken`, `closing(close)`, `closed()`, `close()`, `activate()`. See [QML apps](../../docs/QML.md). |
| `HyprmuxApp` | How Hyprmux launched the app: `arguments`, `restoreTokens`, and `launched()`, after which the host answers the launch (`launch.done`). |
| `FileDialog`, `FolderDialog`, `MessageDialog` | QtQuick.Dialogs' API over `dialog.open`: sheets Hyprmux shows over the tile. |
| `NativeMenu`, `NativeMenuItem`, `NativeMenuSeparator` | A menu tree for `menu.popup`; `popup()` opens it at the pointer. |
| `Files` | `readText`, `writeText` (through `QSaveFile`), `exists`, and `lastError`. |
| `BarItem` | Root of a bar item. `implicitWidth` is the width it asks for; `order` sorts items. |
| `BarPopup` | Inside a `BarItem`: a panel under it, in a surface of its own. `open` shows it; Hyprmux sets it false on a click elsewhere or Esc. Its implicit size is the size it asks for. |
| `Tiles` | Hyprmux's tiles with the CPU and memory of their processes (`rows`), and each tile's last `history` seconds of both, for graphs. Samples every `interval` ms while `active`, every `backgroundInterval` ms otherwise; `history: 0` stops background sampling. One sample walks the process table, about 6 ms for 2,700 processes. `focus(id)` shows a tile. |
| `System` | CPU (`cpu`, and `cpuHistory` over `history` seconds), memory (`memoryPressure`, `memoryUsed`, `memoryTotal`), and battery (`onBattery`, `charging`, `batteryPercent`), every `interval` ms. |
| `Plugin` | The manifest's `id`, `name`, `dir`, and the merged `config`. |
| `Theme` | Hyprmux's look, from its `theme_json`, updated on config reloads: `accent`, `foreground`, `secondary`, `background`, `colors` (16 ANSI), `rounding`, `terminalFamily`, `terminalFontSize`; and `monoFamily` (SF Mono, as the bar's pills), `uiFamily`, `barFontSize`, `barText`. It also becomes the palette of every scene's window, so Qt Quick Controls (Basic) look like Hyprmux. |

## Debugging

- `HM_QML_DEBUG=1`: configure, render, commit, popup, and pointer timings on stderr.
- `HM_QML_DUMP=DIR`: each surface's latest frame as `DIR/toplevel.png`,
  `bar_item.png`, or `popup.png`. `hyprmuxctl snapshot` doesn't reach popups,
  and a window capture is blank while the screen is locked.
- `HM_QML_STATS=FILE`: one JSON line per surface per second: frames, CPU time
  per frame (`render`), submitting it (`submit`, where Qt waits for the GPU),
  commit to frame callback, resize to answer, and starved renders; and the
  process's IOSurface and Metal memory (`surfaces_mb`, `metal_mb`). Those two
  are steady; `footprint`'s graphics figure swings with driver memory macOS
  reclaims later.
  `scripts/qml-bench.py` reads it.
- `QML_DISABLE_DISK_CACHE=1`: Qt's compiled-QML cache once kept serving an old
  `Details.qml` after an edit. Use it while editing plugins.

## How input reaches Qt

Hyprmux's input goes through Qt's window-system queue, synchronously, as a
platform plugin would deliver it: pointer handlers and shortcut matching only work
on that path. Each scene's window gets a native window that's never shown, because
Qt counts a window active only with one, and Qt Quick Controls match shortcuts
only in active windows. Text input runs through Hyprmux's input methods
(`text_input.*`), enabled while the focused item takes text.

## What works

- Configure, ack, resize, and scale, for tiles and bar items.
- A three-buffer swapchain with buffer release. Each buffer keeps its render
  target, and they share one depth-stencil buffer: given bare textures, Qt
  Quick builds a new render target and depth buffer each time the texture
  changes, which was every frame.
- Rendering paced by frame callbacks: when the scene changes, and every frame
  while an animation runs. A hidden tile gets no callbacks, so it stops drawing.
- Animations step on frame callbacks (`FrameDriver`), at the display's rate and
  with the shown frame's time, and pause while no surface of the process shows.
- Pointer enter, leave, motion, buttons, double clicks, and scrolling with
  trackpad phases, through Qt's window-system queue. Pointer handlers
  (`TapHandler`, `HoverHandler`) need that path; `sendEvent` reaches only
  `MouseArea`. Keys, with Qt's macOS modifier convention (Command is
  `ControlModifier`). Every Qt cursor shape but bitmaps, from `HoverHandler`
  and `MouseArea`.
- Trackpad pinch and rotate (`pointer.gesture`) as Qt native gestures, from a
  touchpad device, so `PinchHandler` takes them.
- Dialogs and menus Hyprmux shows (`dialog.open`, `menu.popup`); each request's
  answer comes back by its id (`Host::expectReply`).
- Session restore: a window's restore token goes with `toplevel.create`, which
  waits for the window to be complete so the token is set.
- Core Text glyphs (`NativeTextRendering`). Qt's default distance-field text
  tints glyph edges on a transparent surface.

## Not yet

- A fence. Each frame waits for the GPU in `endFrame` before it commits: about
  1 ms at full screen, measured. Not worth the complexity yet.
