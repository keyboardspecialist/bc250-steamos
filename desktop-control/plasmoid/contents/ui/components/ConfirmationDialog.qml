import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

QQC2.Dialog {
    id: root
    property bool destructive: false
    property string message: ""
    property var acceptedAction: null

    modal: true
    anchors.centerIn: parent
    width: Math.min(parent ? parent.width - Kirigami.Units.largeSpacing * 2 : 460, 460)
    standardButtons: QQC2.Dialog.Ok | QQC2.Dialog.Cancel
    closePolicy: QQC2.Popup.CloseOnEscape

    contentItem: QQC2.Label {
        text: root.message
        wrapMode: Text.Wrap
        color: root.destructive ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
    }

    onAccepted: {
        if (acceptedAction)
            acceptedAction();
        acceptedAction = null;
    }
    onRejected: acceptedAction = null

    function ask(dialogTitle, description, isDestructive, action) {
        title = dialogTitle;
        message = description;
        destructive = isDestructive;
        acceptedAction = action;
        open();
    }
}
