import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: root
    property string title: ""
    default property alias content: body.data
    spacing: Kirigami.Units.smallSpacing
    Layout.fillWidth: true

    QQC2.Label {
        text: root.title
        visible: text.length > 0
        font.weight: Font.DemiBold
        color: Kirigami.Theme.textColor
        Layout.topMargin: Kirigami.Units.smallSpacing
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: body.implicitHeight + Kirigami.Units.largeSpacing * 2
        radius: Kirigami.Units.cornerRadius
        color: Kirigami.Theme.alternateBackgroundColor
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.10)

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing
        }
    }
}
