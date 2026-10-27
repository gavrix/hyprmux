---
name: hyprmux-qml
description: Write, check, and run QML apps and plugins for Hyprmux. Use when asked to make a small app that runs in a Hyprmux tile, a plugin for Hyprmux's bar (a bar item with a popup), or to change one, in QML with the Hyprmux module (HyprmuxWindow, Theme, BarItem, BarPopup, System, Tiles, Plugin).
compatibility: macOS 14.4 or later with Hyprmux installed; qmllint from Qt 6 to check files
---

<!-- managed-by-hyprmux -->

# Hyprmux QML apps and plugins

Hyprmux runs QML in its own host, `hyprmux-qml`, shipped in Hyprmux.app with
Qt 6.12, Qt Quick, and Qt Quick Controls (Basic style only). Nothing to build.
The full guide is `docs/QML.md` (apps) and `docs/PLUGINS.md` (plugins).

## An app

A folder named `Name.hmapp` with `Info.json` and `main.qml`:

```json
{ "format": 1, "id": "dev.example.name", "name": "Name", "kind": "qml" }
```

```qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Hyprmux

HyprmuxWindow {
    id: window
    title: "Name"
    // content: Qt Quick items and Controls; they take Hyprmux's colors already
}
```

Install and open it:

```sh
cp -R Name.hmapp ~/.config/hyprmux/apps/ && hyprmuxctl apps refresh
hyprmuxctl launch Name
```

Rules that matter:

- Every `HyprmuxWindow` is a tile. More windows: `Component.createObject(null, {...})`
  on a `Component { HyprmuxWindow { ... } }`. The app quits when its last window closes.
- `onClosing: close => { close.accepted = false; ... }` keeps a window open (unsaved
  changes); call `window.close()` when done.
- Use `Theme` for colors (`Theme.accent`, `Theme.foreground`, `Theme.background`,
  `Theme.colors[1]` red, `[2]` green, `[3]` yellow) and `palette` roles in Controls.
  Don't hardcode a light theme: Hyprmux is usually dark.
- Shortcuts: `"Ctrl+S"` is ⌘S on macOS. Hyprmux's binds win (⌘N, ⌘S, ⌘W, and
  more by default); tell the user to add a pass list for the chords the app needs:
  `app:<id> { pass = SUPER N, SUPER S }` in `~/.config/hyprmux/hyprmux.conf`.
- Store settings with `import QtCore` and `Settings { category: "..." }`.
- Files: `FileDialog`, `FolderDialog`, and `MessageDialog` come from `import Hyprmux`,
  with QtQuick.Dialogs' API (`fileMode`, `nameFilters`, `selectedFile`, `buttons`,
  `onAccepted`). Hyprmux shows them as sheets. Read and write text with
  `Files.readText(url)` and `Files.writeText(url, text)`.
- Context menus: `NativeMenu { NativeMenuItem { text; onTriggered } NativeMenuSeparator {} }`
  and `menu.popup()` from a `TapHandler { acceptedButtons: Qt.RightButton }`.
- Session restore: give each window a `restoreToken` naming what it shows, and
  reopen the extra windows in `Connections { target: HyprmuxApp; function onLaunched() {...} }`
  from `HyprmuxApp.restoreTokens`.
- Not available: QtQuick.Dialogs (use the Hyprmux ones), other Controls styles
  (Material, Fusion, ...), Qt modules beyond QtQuick, Controls, Layouts, Shapes,
  Effects, and QtCore.

## A plugin

A folder with `plugin.json` and a bar item (see `docs/PLUGINS.md`):

```json
{
  "id": "dev.example.clock", "name": "Clock",
  "contributes": { "bar": { "slot": "right", "item": "Bar.qml" } },
  "permissions": [],
  "config": { "seconds": false }
}
```

The bar item's root is a `BarItem` (its `implicitWidth` is the width it asks
for). A `BarPopup` inside it is a panel under it; set `open`. Load it with
`plugin = ~/path/to/folder` in the config, then `hyprmuxctl reload`;
`hyprmuxctl plugins` shows its state and log. Settings the user changes go in
`~/.config/hyprmux/plugin-config/<id>/config.json` and apply live
(`Plugin.config`).

## Check before running

Lint every file; fix all warnings:

```sh
qmllint -I /Applications/Hyprmux.app/Contents/Resources/qml *.qml
```

(`qmllint` comes with `brew install qt`. In a Hyprmux checkout:
`vendor/qt/bin/qmllint -I .build/qml-host`.) Give items ids and reach other
items by id, not `parent.parent`; declare `required property` in delegates with
`pragma ComponentBehavior: Bound` at the top of the file.

## Run and debug

- Open it once without installing:
  `hyprmuxctl new-surface --type app -- "$(dirname "$(command -v hyprmuxctl)")/hyprmux-qml" "$PWD/main.qml"`
- See its output: wrap that command in a script that appends stdout and stderr to
  a log, and read the log. QML errors and `console.log` land there.
- `HM_QML_RELOAD=1` reloads the app on save, in the same tiles.
- `hyprmuxctl snapshot --surface surface:N out.png` shows an app tile's frame.
