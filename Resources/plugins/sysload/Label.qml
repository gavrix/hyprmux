// Text in the details' style: the system font, dimmed for captions.
import QtQuick
import Hyprmux

Text {
    property bool dim: false
    color: dim ? Qt.rgba(Theme.barText.r, Theme.barText.g, Theme.barText.b, 0.55) : Theme.barText
    font.family: Theme.uiFamily
    font.pixelSize: 12
    font.weight: dim ? Font.Normal : Font.Medium
    elide: Text.ElideRight
}
