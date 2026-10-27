// A tile's number, like the id pill on its border: a circle for one digit, a
// capsule for more, in the colors Hyprmux sends with the tile.
import QtQuick
import Hyprmux

Rectangle {
    id: pill
    property int number
    property color fill: "#888888"
    property color ink: "#ffffff"
    property real fontSize: 11

    height: Math.ceil(fontSize + 7)
    width: Math.max(height, digits.implicitWidth + 12)
    radius: height / 2
    color: fill

    Text {
        id: digits
        anchors.centerIn: parent
        text: pill.number
        color: pill.ink
        font.family: Theme.uiFamily
        font.pixelSize: pill.fontSize
        font.weight: Font.Bold
        font.features: { "tnum": 1 }
    }
}
