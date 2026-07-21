import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: root
    required property var backend
    signal activated()

    implicitWidth: Kirigami.Units.iconSizes.smallMedium
    implicitHeight: implicitWidth
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: "BC-250 Control: " + root.backend.healthSummary
    Keys.onSpacePressed: root.activated()
    Keys.onReturnPressed: root.activated()

    Kirigami.Icon {
        anchors.fill: parent
        source: Qt.resolvedUrl("../../icons/bc250-control.svg")
        isMask: true
        color: Kirigami.Theme.textColor
    }

    Rectangle {
        width: Math.max(5, parent.width * 0.26)
        height: width
        radius: width / 2
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: root.backend.healthState === "healthy" ? Kirigami.Theme.positiveTextColor
            : root.backend.healthState === "warning" ? Kirigami.Theme.neutralTextColor
            : root.backend.healthState === "error" ? Kirigami.Theme.negativeTextColor
            : Kirigami.Theme.disabledTextColor
        border.width: 1
        border.color: Kirigami.Theme.backgroundColor
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.activated()
    }
}
