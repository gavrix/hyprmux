// System load in the workspace bar: CPU, memory, and battery (on battery only).
// A reading turns amber or red when the machine is in trouble:
//   CPU      red above cpu_warn % for cpu_sustain_s seconds
//   Memory   amber at the kernel's "warning" pressure, red at "critical"
//   Battery  red below battery_warn %
// Clicking it opens Details.qml: Hyprmux's tiles by CPU or memory.
import QtQuick
import Hyprmux
import "Format.js" as Format

BarItem {
 id: root
    implicitWidth: row.implicitWidth + 8

    readonly property var config: Plugin.config
    readonly property real cpuWarn: config.cpu_warn ?? 85
    readonly property real cpuSustain: config.cpu_sustain_s ?? 10
    readonly property real batteryWarn: config.battery_warn ?? 20

    // When CPU went over the threshold and has stayed there; 0 when it's under.
    property double cpuHotSince: 0
    property bool cpuHot: false

    readonly property int historyS: config.history_s ?? 300

    // Settings apply live: Plugin.config changes when the settings file does.
    function applyConfig() {
        System.interval = config.interval_ms ?? 2000
        System.history = config.bar_graph_s ?? 60
        Tiles.history = historyS
        Tiles.backgroundInterval = (config.sample_s ?? 5) * 1000
    }
    Component.onCompleted: applyConfig()
    Connections { target: Plugin; function onConfigChanged() { root.applyConfig() } }

    Connections {
        target: System
        function onUpdated() {
            if (System.cpu >= root.cpuWarn) {
                if (root.cpuHotSince === 0) root.cpuHotSince = Date.now()
                root.cpuHot = Date.now() - root.cpuHotSince >= root.cpuSustain * 1000
            } else {
                root.cpuHotSince = 0
                root.cpuHot = false
            }
        }
    }

    function gib(bytes) { return (bytes / 1073741824).toFixed(1) }

    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: details.open = !details.open }

    Details {
        id: details
        cpuHot: root.cpuHot
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 2

        Reading {
            label: "CPU"
            value: Math.round(System.cpu) + "%"
            level: root.cpuHot ? "critical" : "normal"
            // The last minute, so a trend shows without opening the details.
            graph: System.cpuHistory
            warn: root.cpuWarn
        }
        Reading {
            label: "MEM"
            value: root.gib(System.memoryUsed) + "/" + Math.round(System.memoryTotal / 1073741824) + "G"
            level: System.memoryPressure
        }
        Reading {
            visible: System.onBattery
            label: System.charging ? "BAT⚡" : "BAT"
            value: System.batteryPercent + "%"
            level: System.batteryPercent >= 0 && System.batteryPercent < root.batteryWarn ? "critical" : "normal"
        }
    }

    component Reading: Rectangle {
        id: reading
        property string label
        property string value
        property string level: "normal"   // normal, warning, critical
        /// Samples for a small graph after the value, one per System.interval. Null: none.
        property var graph: null
        /// The graph's warning threshold, for its colors.
        property real warn: 100

        implicitWidth: parts.implicitWidth + 14
        implicitHeight: 18
        radius: height / 2
        color: level === "critical" ? "#ff5f57" : level === "warning" ? "#ffbd2e" : "transparent"
        Behavior on color { ColorAnimation { duration: 200 } }

        readonly property color ink: level === "normal" ? Theme.barText : "#1a1a1a"

        Row {
            id: parts
            anchors.centerIn: parent
            spacing: 5
            Text {
                text: reading.label
                color: Qt.rgba(reading.ink.r, reading.ink.g, reading.ink.b, 0.6)
                font: valueText.font
            }
            Text {
                id: valueText
                text: reading.value
                color: reading.ink
                font.family: Theme.monoFamily
                font.pixelSize: Theme.barFontSize
                font.weight: Font.DemiBold
            }
            Sparkline {
                visible: reading.graph !== null && reading.graph.length > 1
                anchors.verticalCenter: parent.verticalCenter
                width: 26
                height: 11
                values: reading.graph ?? []
                step: System.interval / 1000
                span: System.history
                maximum: 100
                // In a calm capsule, colored like the details' graphs; in an alert
                // capsule, the text's color, since the capsule says it already.
                levels: reading.level === "normal" ? Format.levels(reading.warn) : []
                color: reading.ink
            }
        }
    }
  }


