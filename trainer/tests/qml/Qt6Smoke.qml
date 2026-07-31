import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../../qml/components" as Components

ApplicationWindow {
    width: 640
    height: 480
    visible: true

    ColumnLayout {
        anchors.centerIn: parent
        Components.NeonButton { text: "QT 6 SMOKE"; hint: "Offscreen component check" }
        Components.StatusRow { label: "Runtime"; value: "Qt 6"; health: 1; Layout.preferredWidth: 300 }
    }

    Timer {
        interval: 100
        running: true
        onTriggered: Qt.quit()
    }
}
