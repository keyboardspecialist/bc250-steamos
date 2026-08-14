import QtQuick 2.15
import QtQuick.Layouts 1.15
import "." as C

Item {
    id: root
    objectName: "toolkitCard"
    required property string title
    required property string description
    required property string installState
    required property string primaryText
    property string repairText: "REPAIR"
    property bool actionEnabled: true
    property bool repairVisible: false
    property bool removeVisible: false
    signal primaryRequested()
    signal repairRequested()
    signal removeRequested()

    readonly property color stateColor: installState === "installed" ? "#49ff9a"
        : installState === "partial" || installState === "data-preserved" ? "#e6ad55"
        : installState === "not-installed" ? "#607783" : "#ff6aa2"

    implicitHeight: 118

    C.NeonPanel {
        anchors.fill: parent
        accent: root.stateColor
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 9
        anchors.leftMargin: 12
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text {
                text: root.title
                color: "#d7e7ee"
                font.family: "monospace"
                font.pixelSize: 10
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            Text {
                text: root.installState.toUpperCase().replace("-", " ")
                color: root.stateColor
                font.family: "monospace"
                font.pixelSize: 7
                font.bold: true
            }
        }

        Text {
            text: root.description
            color: "#8eabb6"
            font.family: "monospace"
            font.pixelSize: 8
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.fillHeight: true
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            C.NeonButton {
                objectName: "primaryAction"
                text: root.primaryText
                enabled: root.actionEnabled
                implicitHeight: 25
                font.pixelSize: 8
                Layout.fillWidth: true
                onClicked: root.primaryRequested()
            }
            C.NeonButton {
                objectName: "repairAction"
                text: root.repairText
                visible: root.repairVisible
                enabled: root.actionEnabled
                implicitHeight: 25
                font.pixelSize: 8
                Layout.preferredWidth: 64
                onClicked: root.repairRequested()
            }
            C.NeonButton {
                objectName: "removeAction"
                text: "REMOVE"
                visible: root.removeVisible
                enabled: root.actionEnabled
                accent: "#ff6aa2"
                implicitHeight: 25
                font.pixelSize: 8
                Layout.preferredWidth: 66
                onClicked: root.removeRequested()
            }
        }
    }
}
