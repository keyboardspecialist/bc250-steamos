import QtQuick 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root
    property string label: ""
    property string value: "--"
    property color accent: "#22e7f2"
    implicitHeight: 55
    color: "#101722dd"
    border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.65)
    radius: 2

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 7
        spacing: 1
        Text { text: root.label.toUpperCase(); color: "#8297a5"; font.family: "monospace"; font.pixelSize: 8 }
        Text {
            text: root.value
            color: root.accent
            font.family: "monospace"
            font.pixelSize: 17
            font.bold: true
            Layout.fillWidth: true
            elide: Text.ElideRight
        }
    }
}
