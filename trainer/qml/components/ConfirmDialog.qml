import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Dialog {
    id: dialog
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(500, parent ? parent.width - 40 : 500)
    modal: true
    closePolicy: Popup.CloseOnEscape
    property var acceptedAction: null
    property bool highRisk: false
    property string detail: ""
    property string acknowledgementText: "I understand the hardware and stability risk."

    function ask(titleText, detailText, dangerous, action, acknowledgement) {
        title = titleText
        detail = detailText
        highRisk = dangerous
        acknowledgementText = acknowledgement || "I understand the hardware and stability risk."
        acceptedAction = action
        acknowledgement.checked = false
        open()
    }

    background: Rectangle { color: "#0b0e18f5"; border.color: dialog.highRisk ? "#ff4d8d" : "#22e7f2"; border.width: 2 }
    header: Text {
        text: dialog.title
        color: dialog.highRisk ? "#ff6aa2" : "#22e7f2"
        font.family: "monospace"; font.pixelSize: 15; font.bold: true
        padding: 16
        wrapMode: Text.Wrap
    }
    contentItem: ColumnLayout {
        spacing: 12
        Text {
            text: dialog.detail
            color: "#d7e7ee"
            font.family: "monospace"; font.pixelSize: 11
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        CheckBox {
            id: acknowledgement
            visible: dialog.highRisk
            text: dialog.acknowledgementText
            palette.text: "#ffb0cd"
        }
    }
    footer: DialogButtonBox {
        background: Rectangle { color: "transparent" }
        Button { text: "CANCEL"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        Button {
            text: "CONFIRM"
            enabled: !dialog.highRisk || acknowledgement.checked
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }
    onAccepted: {
        var action = acceptedAction
        acceptedAction = null
        if (action) action()
    }
    onRejected: acceptedAction = null
}
