import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Dialog {
    id: dialog
    required property var controller
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(420, parent ? parent.width - 40 : 420)
    title: "Administrator access"
    modal: true
    closePolicy: Popup.CloseOnEscape

    function requestPassword() {
        password.text = ""
        open()
        password.forceActiveFocus()
    }

    background: BackdropPanel {
        objectName: "passwordDialogBackdrop"
        fillColor: "#d90b0e18"
        borderColor: "#ef48bb"
        borderWidth: 2
    }
    header: Text {
        text: dialog.title
        color: "#ef80ce"
        font.family: "monospace"
        font.pixelSize: 14
        font.bold: true
        padding: 15
    }
    contentItem: ColumnLayout {
        spacing: 10
        Text {
            text: "The selected toolkit action needs sudo. The password is sent directly to the private process terminal and is never added to the console log."
            color: "#d7e7ee"
            font.family: "monospace"
            font.pixelSize: 10
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        TextField {
            id: password
            Layout.fillWidth: true
            echoMode: TextInput.Password
            passwordCharacter: "*"
            placeholderText: "Administrator password"
            color: "#d7e7ee"
            font.family: "monospace"
            onAccepted: dialog.accept()
            background: Rectangle {
                color: "#f2050810"
                border.color: password.activeFocus ? "#22e7f2" : "#35525d"
            }
        }
    }
    footer: DialogButtonBox {
        background: Rectangle { color: "transparent" }
        Button { text: "CANCEL"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        Button {
            text: "AUTHENTICATE"
            enabled: password.text.length > 0
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }
    onAccepted: {
        controller.submitPassword(password.text)
        password.text = ""
    }
    onRejected: {
        password.text = ""
        if (controller.authenticationPending)
            controller.cancel()
    }

    Connections {
        target: dialog.controller
        function onAuthenticationRequested() { dialog.requestPassword() }
        function onOperationFinished() {
            if (dialog.opened)
                dialog.close()
            password.text = ""
        }
    }
}
