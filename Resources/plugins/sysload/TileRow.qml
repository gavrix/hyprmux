// One row of the details: a tile (or a plugin, or Hyprmux itself), what it runs,
// a graph of the last few minutes, and its CPU and memory. Clicking a tile's row
// shows the tile.
import QtQuick
import Hyprmux
import "Format.js" as Format

Rectangle {
    id: row
    /// A `Tiles.rows` entry.
    required property var tile
    /// What the graph shows: "cpu" or "memory".
    property string sortBy: "cpu"
    property real cpuWarn: 50
    property real memoryWarn: 4 * 1073741824
    /// Seconds the graph covers.
    property real span: 300

    // Hyprmux and plugins have no tile to show.
    readonly property bool own: tile.kind === "hyprmux" || tile.kind === "plugin"
    readonly property bool measured: tile.processes > 0
    readonly property bool cpuHigh: tile.cpu >= cpuWarn
    readonly property bool memoryHigh: tile.memory >= memoryWarn

    height: 38
    radius: 7
    color: hover.hovered && !own ? "#1affffff" : "transparent"

    HoverHandler { id: hover; cursorShape: row.own ? Qt.ArrowCursor : Qt.PointingHandCursor }
    TapHandler { enabled: !row.own; onTapped: Tiles.focus(row.tile.id) }

    Item {
        id: ref
        x: 8
        width: 34
        height: parent.height
        IdPill {
            visible: !row.own
            anchors.verticalCenter: parent.verticalCenter
            number: row.tile.id
            fill: row.tile.pillFill ?? "#888888"
            ink: row.tile.pillInk ?? "#ffffff"
            fontSize: row.tile.pillFontSize ?? 11
        }
    }
    Column {
        anchors.left: ref.right
        anchors.right: trend.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        Label {
            width: parent.width
            text: row.tile.title || row.tile.kind
        }
        Label {
            width: parent.width
            dim: true
            font.pixelSize: 11
            text: {
                const t = row.tile
                const where = t.parent ? "job of surface:" + t.parent
                            : t.kind === "hyprmux" ? "web tiles and helpers"
                            : t.kind === "plugin" ? "plugin"
                            : "workspace " + t.workspace
                if (!row.measured) return where + (t.kind === "web" ? " · renders in Hyprmux" : " · no processes")
                const names = t.top.map(p => p.name).join(", ")
                return where + " · " + t.processes + (t.processes === 1 ? " process" : " processes") + (names ? ": " + names : "")
            }
        }
    }
    // The last few minutes of whatever the list sorts by. CPU on a fixed 0–100%
    // scale so rows compare; memory against the tile's own peak, for its trend.
    Sparkline {
        id: trend
        readonly property bool byCpu: row.sortBy === "cpu"
        anchors.right: cpu.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        width: 64
        height: 18
        values: (byCpu ? row.tile.historyCpu : row.tile.historyMemory) ?? []
        times: row.tile.historyT ?? []
        span: row.span
        maximum: byCpu ? 100 : 0
        filled: byCpu
        levels: Format.levels(byCpu ? row.cpuWarn : row.memoryWarn)
    }
    Text {
        id: cpu
        anchors.right: mem.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 56
        horizontalAlignment: Text.AlignRight
        text: !row.measured ? "—" : row.tile.cpu < 0 ? "…" : Format.percent(row.tile.cpu)
        color: row.cpuHigh ? Format.hot : Theme.barText
        font.family: Theme.monoFamily
        font.pixelSize: 11
        font.weight: row.cpuHigh ? Font.Bold : Font.Normal
    }
    Text {
        id: mem
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 68
        horizontalAlignment: Text.AlignRight
        text: row.measured ? Format.memory(row.tile.memory) : "—"
        color: row.memoryHigh ? Format.busy : Theme.barText
        font.family: Theme.monoFamily
        font.pixelSize: 11
        font.weight: row.memoryHigh ? Font.Bold : Font.Normal
    }
}
