import QtQuick 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    id: root
    property alias text: label.text
    spacing: 3
    Layout.fillWidth: true

    Text {
        id: label
        color: "#ef48bb"
        font.family: "monospace"
        font.pixelSize: 12
        font.bold: true
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1.3
    }
    Rectangle { color: "#ef48bb"; opacity: 0.65; height: 1; Layout.fillWidth: true }
}
