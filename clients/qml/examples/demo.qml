// A test tile: animation, hover, clicks, scrolling, and typing.
import QtQuick
import QtQuick.Controls

Rectangle {
    id: root
    property string title: "QML demo · " + clicks + " clicks"
    property int clicks: 0
    color: "#1e1f24"

    Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16

        Text {
            text: "Qt Quick in a Hyprmux tile"
            color: "white"
            font.pixelSize: 28
            font.weight: Font.DemiBold
        }

        Row {
            spacing: 16
            Rectangle {
                id: spinner
                width: 56; height: 56; radius: 12
                color: hover.hovered ? "#ff9f43" : "#54a0ff"
                RotationAnimation on rotation { from: 0; to: 360; duration: 2000; loops: Animation.Infinite }
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.clicks++ }
            }
            Button {
                text: "Clicked " + root.clicks + " times"
                onClicked: root.clicks++
            }
        }

        TextField {
            id: field
            width: 320
            placeholderText: "Type here"
            focus: true
        }
        Text { text: "You typed: " + field.text; color: "#c8d6e5"; font.pixelSize: 15 }

        ListView {
            width: parent.width
            height: parent.height - y
            clip: true
            model: 200
            delegate: Rectangle {
                required property int index
                width: ListView.view.width
                height: 32
                color: index % 2 ? "#2a2c33" : "#24262c"
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 12
                    text: "Row " + index
                    color: "#dfe4ea"
                }
            }
        }
    }
}
