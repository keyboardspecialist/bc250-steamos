import QtQuick 2.15
import QtQuick.Controls 2.15

SpinBox {
    id: control

    property color accent: "#22e7f2"

    implicitWidth: Math.max(120, contentItem.implicitWidth + 64)
    implicitHeight: 32
    leftPadding: 9
    rightPadding: 53
    font.family: "monospace"
    font.pixelSize: 10
    font.bold: true

    contentItem: TextInput {
        objectName: "spinInput"
        z: 2
        text: control.textFromValue(control.value, control.locale)
        font: control.font
        color: control.enabled ? "#dffcff" : "#71808c"
        selectionColor: control.accent
        selectedTextColor: "#071018"
        horizontalAlignment: Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        readOnly: !control.editable
        validator: control.validator
        inputMethodHints: Qt.ImhFormattedNumbersOnly
        selectByMouse: true
    }

    up.indicator: Rectangle {
        objectName: "spinUpIndicator"
        x: control.width - width
        y: 0
        implicitWidth: 26
        implicitHeight: control.height
        color: control.up.pressed ? "#3d2449" : control.up.hovered ? "#193540" : "#101923"
        border.color: control.enabled ? control.accent : "#48515b"
        border.width: control.activeFocus ? 2 : 1

        Text {
            anchors.centerIn: parent
            text: "+"
            color: control.enabled ? control.accent : "#71808c"
            font.family: "monospace"
            font.pixelSize: 11
            font.bold: true
        }
    }

    down.indicator: Rectangle {
        objectName: "spinDownIndicator"
        x: control.width - width * 2
        y: 0
        implicitWidth: 26
        implicitHeight: control.height
        color: control.down.pressed ? "#3d2449" : control.down.hovered ? "#2d1d38" : "#151420"
        border.color: control.enabled ? "#ef48bb" : "#48515b"
        border.width: control.activeFocus ? 2 : 1

        Text {
            anchors.centerIn: parent
            text: "-"
            color: control.enabled ? "#ef70cc" : "#71808c"
            font.family: "monospace"
            font.pixelSize: 11
            font.bold: true
        }
    }

    background: Rectangle {
        color: control.enabled ? "#09111acc" : "#0b0f15aa"
        border.color: control.activeFocus ? control.accent
                                           : control.enabled ? "#28636d" : "#3c4650"
        border.width: control.activeFocus ? 2 : 1
        radius: 2

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 2
            color: control.enabled ? control.accent : "#48515b"
            opacity: control.activeFocus ? 1 : 0.55
        }
    }
}
