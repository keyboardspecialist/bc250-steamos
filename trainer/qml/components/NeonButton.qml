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
    ToolTip {
        id: hintPopup
        objectName: "neonToolTip"
        visible: control.hovered && control.hint.length > 0
        text: control.hint
        delay: 450
        timeout: 6000
        margins: 8
        leftPadding: 10
        rightPadding: 10
        topPadding: 8
        bottomPadding: 8
        font.family: "monospace"
        font.pixelSize: 9
        implicitWidth: Math.min(340, Math.max(110,
            hintText.implicitWidth + leftPadding + rightPadding))
        implicitHeight: hintText.implicitHeight + topPadding + bottomPadding

        contentItem: Text {
            id: hintText
            width: hintPopup.availableWidth
            text: hintPopup.text
            textFormat: Text.PlainText
            color: "#bcebf0"
            font: hintPopup.font
            wrapMode: Text.Wrap
        }

        background: Rectangle {
            objectName: "neonToolTipFrame"
            color: "#071018f2"
            border.color: control.accent
            border.width: 1
            radius: 2

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 3
                anchors.rightMargin: 3
                height: 2
                color: "#ef48bb"
                opacity: 0.8
            }
        }
    }
    Accessible.description: hint
}
