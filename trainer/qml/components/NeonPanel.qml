import QtQuick 2.15

Rectangle {
    id: panel
    property color accent: "#22e7f2"
    color: "#090c13e8"
    border.color: accent
    border.width: 1
    radius: 3

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 3
        color: panel.accent
        opacity: 0.72
    }
}
