# QML apps and plugins

> **Experimental.** The `Hyprmux` QML module may change between releases.

Hyprmux runs QML: apps in tiles, and [plugins](PLUGINS.md) in its bar. They run
in `hyprmux-qml`, a Qt Quick host that ships inside Hyprmux.app with the Qt it
needs (Qt 6.12, Qt Quick, and Qt Quick Controls). An app is a folder of QML
files; nothing to build, nothing to install but the folder.

QML apps need macOS 14.4 or later.

## A first app

```
Hello.hmapp/
  Info.json
  main.qml
```

```json
{ "format": 1, "id": "dev.example.hello", "name": "Hello", "kind": "qml" }
```

```qml
import QtQuick
import QtQuick.Controls
import Hyprmux

HyprmuxWindow {
    title: "Hello"
    Column {
        anchors.centerIn: parent
        spacing: 12
        Label { text: "Hello from QML" }
        Button { text: "Close"; onClicked: close() }
    }
}
```

Put the folder in `~/.config/hyprmux/apps/`, run `hyprmuxctl apps refresh`, and
open it from the launcher or with `hyprmuxctl launch Hello`. `"main"` in
`Info.json` names another main file; the default is `main.qml`.

Without a bundle, `hyprmuxctl apps add Hello ~/src/hello/main.qml` installs a
QML file (or a folder with `main.qml`) as an app, and
`hyprmuxctl new-surface --type app -- "$(dirname "$(which hyprmuxctl)")/hyprmux-qml" main.qml`
opens one once.

A downloaded `.hmapp` is code: Hyprmux asks before it runs one that came from
the internet, as for any app that carries its own program ([Trust](APPS.md#trust)).

[clients/qml/examples/Notes.hmapp](../clients/qml/examples/Notes.hmapp) is a
fuller example: a list and an editor, settings, shortcuts, a second window,
import and export through file dialogs, a right-click menu, pinch to zoom, a
"Save changes?" prompt on close, and windows that come back after a restart.

## Windows

Every `HyprmuxWindow` is a tile. Hyprmux places and sizes it; the content follows.

| Member | What it does |
|---|---|
| `title` | The tile's title. |
| `color` | What shows behind the content: by default `Theme.background`, Hyprmux's terminal background. `"transparent"` to draw everything yourself. |
| `active` | The tile has the keyboard. |
| `closing(close)` | The user asked to close the tile. Set `close.accepted = false` to keep it, for example to ask about unsaved changes first. |
| `closed()` | The tile is gone. |
| `close()` | Closes the tile, without `closing`. |
| `activate()` | Asks Hyprmux to focus the tile. It does only right after the user pressed something in the app, so a window can't steal focus. |
| `restoreToken` | Names the window across restarts ([Session restore](#session-restore)). |

The file's root is the first window. More windows are more `HyprmuxWindow`s:
declared inside the first, or made later with `Component.createObject(null, ...)`.
A window made at run time is deleted when it closes. The app quits when its last
window closes.

A plain `Item` root still works as a single tile titled by its `title` property.

## Looks

Apps look like Hyprmux by default. Hyprmux sends the host its look, and sends it
again when its config reloads, so running apps follow:

- **`Theme`** has it: `accent` (the active border's color), `foreground`,
  `secondary`, `background` (the terminal's, with its opacity), `colors` (the
  terminal's 16 ANSI colors), `rounding` (the tiles'), `terminalFamily` and
  `terminalFontSize`, plus `uiFamily` and `monoFamily` (SF Pro and SF Mono).
- **Qt Quick Controls** use the Basic style, the one style that ships, and draw
  from a palette made of those colors: buttons, fields, lists, menus, and dialogs
  match Hyprmux without any styling. `palette` on any item overrides it.

Full custom drawing works as anywhere in Qt Quick.

Animations run at the display's rate, 120 Hz on ProMotion. They pause while
none of the app's windows show, such as on a workspace out of view, and catch up
when one shows again. A `Timer` keeps running; use it for work that must go on
while hidden.

## Keyboard

- Keys, shortcuts (`Shortcut`, `Action.shortcut`, `Keys`), and key repeat work.
  On macOS Qt names Command `Ctrl` and Control `Meta`: `"Ctrl+S"` is ⌘S.
- **Hyprmux's binds win.** A chord Hyprmux binds never reaches the app. The
  default config binds ⌘N, ⌘S, ⌘W, and more. An app's pass list hands chords to
  it while its tile has the keyboard
  ([Configuration: app](CONFIGURATION.md#app)):

  ```ini
  app:dev.gavrix.hyprmux.notes {
      pass = SUPER N, SUPER S
  }
  ```

- **Text input goes through macOS's input methods**: dead keys, press-and-hold
  accents, the emoji picker, dictation, and CJK input work in `TextField`,
  `TextArea`, `TextInput`, and `TextEdit`.

## Dialogs and menus

A tile isn't a real window, so Qt's own dialogs and native menus would open out
of sight. `QtQuick.Dialogs` doesn't ship for that reason. The `Hyprmux` module has
dialogs with the same API, which Hyprmux shows as sheets over the tile:

```qml
FileDialog {
    id: exportDialog
    fileMode: FileDialog.SaveFile
    nameFilters: ["Text (*.txt)"]
    selectedFile: "note.txt"          // the suggested name
    onAccepted: Files.writeText(selectedFile, editor.text)
}
MessageDialog {
    id: confirm
    text: "Delete the note?"
    informativeText: "You can't undo this."
    buttons: MessageDialog.Ok | MessageDialog.Cancel
    onAccepted: remove()
}
```

- **`FileDialog`**: `fileMode` (`OpenFile`, `OpenFiles`, `SaveFile`), `title`,
  `nameFilters`, `currentFolder`, `acceptLabel`. The answer is in `selectedFile`
  and `selectedFiles`, then `accepted()`, or `rejected()` on cancel.
- **`FolderDialog`**: picks a folder, into `selectedFolder`.
- **`MessageDialog`**: `text`, `informativeText`, and `buttons` (Ok, Save,
  Cancel, Discard, Yes, No, and the rest). `buttonClicked(button)` names the
  answer; `accepted()` and `rejected()` follow for accepting and rejecting
  buttons.
- `open()` shows a dialog; one sheet shows at a time, and later ones wait.

**`NativeMenu`** is a macOS menu over the tile, as other apps' context menus.
`popup()` opens it where the pointer is; `popup(item, x, y)` at a point in an item.

```qml
NativeMenu {
    id: menu
    NativeMenuItem { text: "Open in Window"; shortcut: "Ctrl+Shift+N"; onTriggered: openWindow() }
    NativeMenuItem { text: "Pinned"; checkable: true; checked: note.pinned; onTriggered: pin(checked) }
    NativeMenuSeparator {}
    NativeMenu { title: "Move to"; NativeMenuItem { text: "Archive" } }
}
TapHandler { acceptedButtons: Qt.RightButton; onTapped: menu.popup() }
```

`shortcut` only labels the item; the chord itself belongs to a `Shortcut`. Qt
Quick Controls' `Menu` still works too, drawn inside the tile in Hyprmux's colors.

## Pointer and trackpad

Clicks, drags, hover, the scroll wheel, and trackpad scrolling work, and items'
`HoverHandler.cursorShape` sets the cursor. A trackpad pinch and rotation reach
`PinchHandler` and `onNativeGesture`.

## Data

QtCore's `Settings` keeps an app's settings (in
`~/Library/Preferences/dev.gavrix.hyprmux.qml.<app name>.plist`):

```qml
import QtCore
Settings { category: "notes"; property string notes: "" }
```

Hyprmux also hands every app a folder of its own in `HYPRMUX_APP_CONFIG_DIR`.

**`Files`** reads and writes text files, which QML can't on its own:
`Files.readText(url)`, `Files.writeText(url, text)` (written aside, then moved in
place), and `Files.exists(url)`. On failure, `Files.lastError` says why.

## Session restore

Hyprmux restores app tiles when it restarts. It relaunches the app and puts each
window back in its tile by its `restoreToken`:

```qml
HyprmuxWindow {
    restoreToken: "main"
    Connections {
        target: HyprmuxApp
        // The tokens of every window the app had: open the others again.
        function onLaunched() {
            for (const t of HyprmuxApp.restoreTokens)
                if (t.startsWith("note:")) noteWindow.createObject(null, { noteId: t.slice(5) })
        }
    }
}
```

- The token is the app's to pick, up to 4 KiB: enough to name a document.
  Changing it later updates what Hyprmux saves.
- `HyprmuxApp.launched()` fires once Hyprmux says why it started the app.
  Windows made there take their tiles; restored tiles that no window claims close.
- `HyprmuxApp.arguments` has the launch's arguments (`hyprmuxctl launch Notes ARGS`).

## Developing

- **Live reload:** `HM_QML_RELOAD=1` in Hyprmux's environment (or the host's)
  reloads an app when one of its files changes, in the same tiles.
- **Lint before you run:** the app bundles the module's type information, so
  `qmllint` knows `HyprmuxWindow`, `Theme`, and the rest:

  ```sh
  qmllint -I /Applications/Hyprmux.app/Contents/Resources/qml main.qml
  ```

  `qmllint` comes with Qt (`brew install qt`); from a Hyprmux checkout,
  `vendor/qt/bin/qmllint -I .build/qml-host`. Start files that use delegates with
  `pragma ComponentBehavior: Bound`, and give items ids rather than reaching for
  `parent.parent`: the linter then catches mistakes a run would only show later.
- **Debugging:** `HM_QML_DEBUG=1` logs input, text input, and frames on stderr;
  `HM_QML_DUMP=DIR` writes each surface's latest frame to `DIR`. An app started
  from the launcher has no terminal: start it with `hyprmuxctl new-surface` from
  one to see its output.

## The `Hyprmux` module

| Type | Kind | For |
|---|---|---|
| `HyprmuxWindow` | item | An app window (above). |
| `Theme` | singleton | Hyprmux's look (above). |
| `BarItem`, `BarPopup` | item | A plugin's bar item and its popup ([Plugins](PLUGINS.md)). |
| `Plugin` | singleton | A plugin's manifest and settings. |
| `System` | singleton | CPU, memory, and battery. Plugins need `system-stats`. |
| `Tiles` | singleton | Hyprmux's tiles with their processes' CPU and memory, and focusing one. Plugins need `tiles`. |
| `HyprmuxApp` | singleton | Launch arguments and restore tokens (above). |
| `FileDialog`, `FolderDialog`, `MessageDialog` | object | Sheets over the tile (above). |
| `NativeMenu`, `NativeMenuItem`, `NativeMenuSeparator` | object | Native menus (above). |
| `Files` | singleton | Reading and writing text files. |

[clients/qml/README.md](../clients/qml/README.md) lists every property.

## Not yet

- Accessibility.
- Drag and drop between apps.
- Popup surfaces outside the tile: Qt Quick Controls' menus, tooltips, and
  combo-box lists stay inside it.
