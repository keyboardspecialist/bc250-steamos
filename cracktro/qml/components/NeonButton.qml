import QtQuick 2.15
import QtQuick.Controls 2.15

Button {
    id: control
    property color accent: "#22e7f2"
    property string hint: ""
    implicitHeight: 32
    leftPadding: 10
    rightPadding: 10
    font.family: "monospace"
    font.pixelSize: 11
    font.bold: true

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.enabled ? control.accent : "#71808c"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        color: control.down ? "#33213f" : control.hovered ? "#172f3a" : "#10131ccc"
        border.color: control.enabled ? control.accent : "#48515b"
        border.width: control.activeFocus ? 2 : 1
        radius: 2
    }
    ToolTip.visible: hovered && hint.length > 0
    ToolTip.text: hint
    Accessible.description: hint
}
