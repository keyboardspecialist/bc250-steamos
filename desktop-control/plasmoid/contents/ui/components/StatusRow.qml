import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

RowLayout {
    id: root
    property string label: ""
    property string value: ""
    property int health: 0 // 0 neutral, 1 healthy, -1 warning
    spacing: Kirigami.Units.largeSpacing
    Layout.fillWidth: true

    QQC2.Label {
        text: root.label
        color: Kirigami.Theme.disabledTextColor
        elide: Text.ElideRight
        Layout.fillWidth: true
    }
    QQC2.Label {
        text: root.value
        color: root.health > 0 ? Kirigami.Theme.positiveTextColor
            : root.health < 0 ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignRight
        wrapMode: Text.Wrap
        Layout.maximumWidth: parent.width * 0.62
    }
}
