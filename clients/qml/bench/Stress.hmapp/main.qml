// QML Stress: one load scenario per launch, for scripts/qml-bench.sh. The host's
// HM_QML_STATS records how each one renders; the script reads it.
//
//   hyprmuxctl launch "QML Stress" SCENARIO
//
// - idle: a still window of controls. The baseline.
// - full: one animated gradient over the whole tile. Per-frame overhead at full size.
// - scene: 2,000 items, each animated by its own binding. Scene graph and JS cost.
// - gpu: animated content under a large blur and a shadow. GPU cost per frame.
// - list: a 10,000-row list scrolling without pause. Delegate churn and text.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Hyprmux

HyprmuxWindow {
    id: window
    property string scenario: ""
    title: "Stress: " + (scenario || "…")

    // 0 to 1 once a second, for every scenario that moves.
    property real phase: 0
    NumberAnimation on phase {
        running: window.scenario !== "" && window.scenario !== "idle"
        from: 0; to: 1; duration: 1000; loops: Animation.Infinite
    }

    function pick(asked) {
        const known = ["idle", "full", "scene", "gpu", "list"]
        scenario = known.includes(asked) ? asked : "idle"
    }
    Connections {
        target: HyprmuxApp
        function onLaunched() { window.pick(HyprmuxApp.arguments[0] ?? "idle") }
    }
    // Run straight from a terminal: hyprmux-qml main.qml --scenario=gpu
    Component.onCompleted: {
        const arg = Qt.application.arguments.find(a => a.startsWith("--scenario="))
        if (arg) pick(arg.slice(11))
    }

    Loader {
        anchors.fill: parent
        sourceComponent: ({ idle: idle, full: full, scene: scene, gpu: gpu, list: list })[window.scenario] ?? null
    }

    Label {
        anchors { right: parent.right; bottom: parent.bottom; margins: 8 }
        text: window.scenario
        color: Theme.secondary
        font.family: Theme.monoFamily
    }

    Component {
        id: idle
        ColumnLayout {
            anchors.centerIn: parent
            spacing: 12
            Label { text: "Nothing moves here."; font.pixelSize: 20 }
            TextField { placeholderText: "A field"; Layout.preferredWidth: 260 }
            RowLayout { Button { text: "One" } Button { text: "Two" } CheckBox { text: "Three" } }
            Slider { Layout.preferredWidth: 260; value: 0.4 }
        }
    }

    Component {
        id: full
        Rectangle {
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.hsla(window.phase, 0.6, 0.35, 1) }
                GradientStop { position: 1; color: Qt.hsla((window.phase + 0.5) % 1, 0.6, 0.35, 1) }
            }
        }
    }

    Component {
        id: scene
        Item {
            id: field
            readonly property int columns: 50
            Repeater {
                model: 2000
                Rectangle {
                    required property int index
                    readonly property real cell: field.width / field.columns
                    x: (index % field.columns) * cell + cell * 0.1
                    y: Math.floor(index / field.columns) * cell + cell * 0.1
                    width: cell * 0.8
                    height: cell * 0.8
                    radius: 3
                    rotation: (window.phase * 360 + index * 7) % 360
                    color: Theme.colors[1 + index % 6]
                    opacity: 0.5 + 0.5 * Math.sin((window.phase + index / 200) * 2 * Math.PI)
                }
            }
        }
    }

    Component {
        id: gpu
        Item {
            // The content stays visible under an opaque cover, so its changes reach
            // the scene: a hidden effect source doesn't, while animations run, until
            // the host drives rendering from its own animation driver.
            Item {
                id: content
                anchors.fill: parent
                Repeater {
                    model: 24
                    Rectangle {
                        required property int index
                        readonly property real a: (window.phase + index / 24) * 2 * Math.PI
                        width: content.width / 5
                        height: width
                        radius: width / 2
                        x: content.width / 2 + Math.cos(a) * content.width / 3 - width / 2
                        y: content.height / 2 + Math.sin(a * 2) * content.height / 3 - height / 2
                        color: Theme.colors[1 + index % 6]
                    }
                }
            }
            Rectangle { anchors.fill: parent; color: Theme.background }
            MultiEffect {
                anchors.fill: parent
                source: content
                blurEnabled: true
                blurMax: 64
                blur: 1
                shadowEnabled: true
                shadowBlur: 1
                saturation: 0.3
            }
        }
    }

    Component {
        id: list
        ListView {
            model: 10000
            clip: true
            delegate: ItemDelegate {
                id: row
                required property int index
                width: ListView.view.width
                contentItem: Column {
                    Label { text: "Row " + row.index + ": the quick brown fox jumps over the lazy dog" }
                    Label { text: "Some secondary text, number " + (row.index * 7919 % 10007); color: Theme.secondary; font.pixelSize: 11 }
                }
            }
            // Scrolls 2,000 points a second, forever.
            NumberAnimation on contentY {
                from: 0; to: 2000 * 600; duration: 600 * 1000; loops: Animation.Infinite
            }
        }
    }
}
