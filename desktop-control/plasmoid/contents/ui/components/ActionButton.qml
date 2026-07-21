import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: root
    property string text: ""
    property string description: ""
    property string disabledReason: ""
    property string iconName: ""
    signal clicked()
    Layout.fillWidth: true
    spacing: 2

    QQC2.Button {
        text: root.text
        icon.name: root.iconName
        enabled: root.enabled
        Layout.fillWidth: true
        onClicked: root.clicked()
        QQC2.ToolTip.visible: hovered && !enabled && root.disabledReason.length > 0
        QQC2.ToolTip.text: root.disabledReason
    }
    QQC2.Label {
        text: root.enabled ? root.description : root.disabledReason
        visible: text.length > 0
        color: root.enabled ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.neutralTextColor
        font: Kirigami.Theme.smallFont
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
}
