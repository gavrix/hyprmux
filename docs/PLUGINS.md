# Plugins

> **Experimental.** Plugins, their manifest, the QML module, and the protocol
> parts they use may still change between releases.

A plugin adds to Hyprmux's own UI: an item in the workspace bar, and a popup
under it. For apps in tiles, see [QML apps](QML.md). Plugins are written in QML and run in `hyprmux-qml`, a Qt Quick host
that Hyprmux starts, one process per plugin. Hyprmux ships one: the system-load
readout, `plugin = sysload` (its source is `Resources/plugins/sysload`).

## Loading plugins

The config loads plugins, one `plugin =` line each:

```ini
plugin = sysload                  # ~/.config/hyprmux/plugins/sysload/
plugin = ~/src/my-plugin          # any folder with a plugin.json
```

- A bare name is a folder in `plugins/` next to the config, else a plugin built
  into Hyprmux. A path is taken as written, with `~` expanded; a relative one
  starts at the config's folder.
- **Listed means enabled.** Remove or comment out the line to disable the
  plugin. A folder no line names never runs: a plugin is code.
- A config reload starts newly listed plugins and stops removed ones.
- Hyprmux restarts a plugin that exits: after 1 s, then 2 s, 4 s, up to a
  minute. A plugin that ran a minute or more starts again after 1 s.
- `hyprmuxctl plugins` lists them: state, pid, restarts, the last exit and
  error line, the log, and the settings folder.
- A plugin's output goes to `~/Library/Logs/Hyprmux/plugins/<id>.log`, started
  fresh each run.

The host and the Qt it needs ship in the app; plugins need macOS 14.4 or later.
`HYPRMUX_QML_HOST` names another host binary, for development.

## Settings

A plugin keeps its own settings. Hyprmux never reads them. They live in
`~/.config/hyprmux/plugin-config/<plugin id>/config.json`, a JSON object:

```json
{ "cpu_warn": 70, "history_s": 600 }
```

- Values here win over the manifest's `config` defaults. Keys the file leaves
  out keep their defaults.
- Edits apply live, without a restart. A file that doesn't parse is ignored
  (the log says why), and the defaults stand.
- Hyprmux passes the folder in `HYPRMUX_PLUGIN_CONFIG_DIR`, as it gives apps
  `HYPRMUX_APP_CONFIG_DIR`. It may not exist yet; create it.

## Writing a plugin

A plugin is a folder:

```
my-plugin/
  plugin.json
  Bar.qml
```

```json
{
  "id": "dev.example.my-plugin",
  "name": "My plugin",
  "contributes": { "bar": { "slot": "right", "item": "Bar.qml" } },
  "permissions": ["system-stats"],
  "config": { "warn": 85 }
}
```

`Bar.qml`'s root is a `BarItem`. Its `implicitWidth` is the width it asks for;
the bar sets the height:

```qml
import QtQuick
import Hyprmux

BarItem {
    implicitWidth: label.implicitWidth + 16
    Text {
        id: label
        anchors.centerIn: parent
        text: "CPU " + Math.round(System.cpu) + "%"
        color: System.cpu > Plugin.config.warn ? "#ff6b63" : Theme.barText
        font.family: Theme.monoFamily
        font.pixelSize: Theme.barFontSize
    }
}
```

A `BarPopup` inside the `BarItem` is a panel under it, with its own surface.
Set `open` to show it. Hyprmux closes it on a click elsewhere or Esc, and sets
`open` back to false.

### Permissions

A plugin imports what its manifest's `permissions` list:

| Permission | Gives |
|---|---|
| (none) | `BarItem`, `BarPopup`, `Plugin`, `Theme` |
| `system-stats` | `System`: CPU, memory pressure and use, battery |
| `tiles` | `Tiles`: Hyprmux's tiles with their processes' CPU and memory, and focusing one |

Using a type it didn't ask for is a QML error, such as `Tiles is not defined`,
in the plugin's log. Hyprmux checks too: only a process it started for a
`plugin =` line may create bar items, and only one with `tiles` gets tiles.

### The `Hyprmux` module

See the host's README (`clients/qml/README.md`) for every property.

### Developing

- Check a plugin before running it:
  `vendor/qt/bin/qmllint -I clients/qml/build your-plugin/*.qml`, after building
  the host (`clients/qml/README.md`). The build writes the
  `Hyprmux` module's types there, so the linter knows `BarItem`, `System.cpu`,
  and the rest.
- `QML_DISABLE_DISK_CACHE=1` in Hyprmux's environment stops Qt serving an old
  compiled copy of a file you just edited.
- `HM_QML_DUMP=DIR` writes each surface's latest frame to a PNG there, and
  `HM_QML_DEBUG=1` logs timings. Plugins inherit Hyprmux's environment.
- After editing QML, restart the plugin: kill its pid from
  `hyprmuxctl plugins`, and Hyprmux starts it again a second later.
