// The system-load popup: what each Hyprmux tile costs, busiest first. Read-only:
// clicking a row shows its tile. Opens sorted by memory while memory is under
// pressure, by CPU otherwise.
pragma ComponentBehavior: Bound

import QtQuick
import Hyprmux
import "Format.js" as Format

BarPopup {
    id: popup
    property bool cpuHot: false

    readonly property var config: Plugin.config
    readonly property real rowCpuWarn: config.row_cpu_warn ?? 50
    readonly property real rowMemoryWarn: (config.row_memory_warn_gb ?? 4) * 1073741824
    readonly property int maxRows: config.max_rows ?? 12

    property string sortBy: "cpu"
    readonly property var sorted: {
        const key = sortBy
        const rows = Tiles.rows.slice()
        rows.sort((a, b) => b[key] - a[key])
        return rows.slice(0, maxRows)
    }

    implicitWidth: 560
    implicitHeight: body.implicitHeight + 28

    onOpenChanged: {
        if (open) sortBy = System.memoryPressure !== "normal" && !cpuHot ? "memory" : "cpu"
        Tiles.active = open
    }

    Column {
        id: body
        x: 14; y: 14
        width: parent.width - 28
        spacing: 10

        // The machine as a whole.
        Row {
            spacing: 14
            Label { text: "CPU"; dim: true }
            Label { text: Format.percent(System.cpu); color: popup.cpuHot ? Format.hot : Theme.barText }
            Label { text: "Memory"; dim: true }
            Label {
                text: Format.memory(System.memoryUsed) + " of " + Math.round(System.memoryTotal / 1073741824) + " GB"
                color: System.memoryPressure === "critical" ? Format.hot
                     : System.memoryPressure === "warning" ? Format.busy : Theme.barText
            }
            Label { visible: System.memoryPressure !== "normal"; text: System.memoryPressure + " pressure"; dim: true }
            Label { visible: System.hasBattery; text: "Battery"; dim: true }
            Label {
                visible: System.hasBattery
                text: System.batteryPercent + "%" + (System.charging ? " ⚡" : System.onBattery ? "" : " AC")
            }
        }

        Rectangle { width: parent.width; height: 1; color: "#22ffffff" }

        // Column heads; CPU and Memory sort.
        Item {
            width: parent.width
            height: 16
            Label { text: "Tile"; dim: true; anchors.verticalCenter: parent.verticalCenter }
            SortHead {
                key: "memory"; text: "Memory"; current: popup.sortBy; onPicked: k => popup.sortBy = k
                anchors.right: parent.right; width: 76
            }
            SortHead {
                key: "cpu"; text: "CPU"; current: popup.sortBy; onPicked: k => popup.sortBy = k
                anchors.right: parent.right; anchors.rightMargin: 84; width: 56
            }
            // Over the graphs: what they show, and over how long.
            Label {
                anchors.right: parent.right
                anchors.rightMargin: 84 + 56 + 8
                anchors.verticalCenter: parent.verticalCenter
                width: 64
                horizontalAlignment: Text.AlignHCenter
                dim: true
                font.pixelSize: 10
                text: (popup.sortBy === "cpu" ? "CPU" : "memory") + ", " + Math.round(Tiles.history / 60) + " min"
            }
        }

        Column {
            width: parent.width
            spacing: 2
            // By count, not by the array: an array model rebuilds every row on each
            // sample, and a rebuilt graph shows blank for a frame before it paints.
            Repeater {
                id: rows
                model: popup.sorted.length
                delegate: TileRow {
                    required property int index
                    tile: popup.sorted[index]
                    width: rows.parent.width
                    sortBy: popup.sortBy
                    cpuWarn: popup.rowCpuWarn
                    memoryWarn: popup.rowMemoryWarn
                    span: Tiles.history
                }
            }
            Label {
                visible: Tiles.rows.length === 0
                text: "Measuring…"
                dim: true
            }
        }
    }

    // A column head that sorts the list.
    component SortHead: Item {
        id: head
        property string key
        property string current
        property alias text: label.text
        signal picked(string key)
        height: 16
        Label {
            id: label
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            dim: head.current !== head.key
        }
        Label {
            anchors.right: label.left
            anchors.rightMargin: 3
            anchors.verticalCenter: parent.verticalCenter
            visible: head.current === head.key
            text: "▾"
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: head.picked(head.key) }
    }
}
