import QtQuick 2.15
import QtQuick.Controls 2.15

ComboBox {
    id: control

    property color accent: "#22e7f2"

    implicitWidth: Math.max(160, contentItem.implicitWidth + 52)
    implicitHeight: 32
    leftPadding: 10
    rightPadding: 38
    font.family: "monospace"
    font.pixelSize: 10
    font.bold: true

    delegate: ItemDelegate {
        id: option
        required property int index
        required property var modelData
        width: control.width - control.popup.leftPadding - control.popup.rightPadding
        height: 30
        highlighted: control.highlightedIndex === index

        contentItem: Text {
            text: modelData
            color: option.highlighted ? "#071018" : control.enabled ? "#c9f8fb" : "#71808c"
            font: control.font
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }

        background: Rectangle {
            color: option.highlighted ? control.accent
                                      : option.hovered ? "#17313b" : "transparent"
            radius: 1
        }
    }

    indicator: Rectangle {
        objectName: "comboIndicator"
        x: control.width - width
        y: 0
        width: 32
        height: control.height
        color: control.down || control.popup.visible ? "#33213f"
              : control.hovered ? "#193540" : "#101923"
        border.color: control.enabled ? "#ef48bb" : "#48515b"
        border.width: control.activeFocus ? 2 : 1

        Text {
            anchors.centerIn: parent
            text: control.popup.visible ? "^" : "v"
            color: control.enabled ? "#ef70cc" : "#71808c"
            font.family: "monospace"
            font.pixelSize: 11
            font.bold: true
        }
    }

    contentItem: Text {
        objectName: "comboDisplay"
        text: control.displayText
        color: control.enabled ? "#dffcff" : "#71808c"
        font: control.font
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
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

    popup: Popup {
        y: control.height + 2
        width: control.width
        implicitHeight: Math.min(contentItem.implicitHeight + topPadding + bottomPadding, 220)
        topPadding: 3
        bottomPadding: 3
        leftPadding: 3
        rightPadding: 3

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            highlightMoveDuration: 0
            ScrollIndicator.vertical: ScrollIndicator {}
        }

        background: BackdropPanel {
            objectName: "comboPopupFrame"
            fillColor: "#f2071018"
            borderColor: control.accent
            borderWidth: 1
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
}
