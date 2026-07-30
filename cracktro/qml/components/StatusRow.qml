import QtQuick 2.15
import QtQuick.Layouts 1.15

RowLayout {
    id: root
    property string label: ""
    property string value: ""
    property int health: 0
    Layout.fillWidth: true
    spacing: 7

    Rectangle {
        width: 6; height: 6; radius: 3
        color: root.health > 0 ? "#49ff9a" : root.health < 0 ? "#ff4d8d" : "#22e7f2"
        opacity: root.health === 0 ? 0.55 : 1
    }
    Text {
        text: root.label
        textFormat: Text.PlainText
        color: "#91a5b3"
        font.family: "monospace"
        font.pixelSize: 10
        Layout.fillWidth: true
        elide: Text.ElideRight
    }
    Text {
        text: root.value || "--"
        textFormat: Text.PlainText
        color: "#e6fbff"
        font.family: "monospace"
        font.pixelSize: 10
        font.bold: true
        horizontalAlignment: Text.AlignRight
        Layout.maximumWidth: root.width * 0.58
        elide: Text.ElideRight
    }
}
