import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "." as C

Item {
    id: root
    objectName: "consolePanel"
    required property var controller
    property bool expanded: false
    property bool followOutput: true
    implicitHeight: expanded ? 330 : 176

    C.NeonPanel {
        anchors.fill: parent
        accent: controller.resultStatus === "failed" || controller.resultStatus === "error"
            || controller.resultStatus === "signaled"
            ? "#ff4d8d" : controller.running ? "#ef48bb" : "#22e7f2"
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 7
        anchors.leftMargin: 11
        spacing: 5

        RowLayout {
            Layout.fillWidth: true
            spacing: 5
            Text {
                text: controller.running ? "CONSOLE // " + controller.activeOperationTitle.toUpperCase()
                    : "CONSOLE // " + controller.resultStatus.toUpperCase()
                color: controller.running ? "#ef80ce" : "#77dbe2"
                font.family: "monospace"
                font.pixelSize: 8
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
            C.NeonButton {
                text: root.followOutput ? "FOLLOW" : "PAUSED"
                checked: root.followOutput
                implicitHeight: 23
                implicitWidth: 58
                font.pixelSize: 7
                onClicked: root.followOutput = !root.followOutput
            }
            C.NeonButton {
                text: "COPY"
                enabled: output.text.length > 0
                implicitHeight: 23
                implicitWidth: 45
                font.pixelSize: 7
                onClicked: {
                    output.selectAll()
                    output.copy()
                    output.deselect()
                }
            }
            C.NeonButton {
                text: "CLEAR"
                enabled: output.text.length > 0
                implicitHeight: 23
                implicitWidth: 48
                font.pixelSize: 7
                onClicked: controller.clearOutput()
            }
            C.NeonButton {
                text: root.expanded ? "SHRINK" : "EXPAND"
                implicitHeight: 23
                implicitWidth: 53
                font.pixelSize: 7
                onClicked: root.expanded = !root.expanded
            }
        }

        ScrollView {
            id: consoleScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AsNeeded
            ScrollBar.vertical.policy: ScrollBar.AsNeeded

            TextArea {
                id: output
                objectName: "consoleOutput"
                text: controller.outputText.length > 0 ? controller.outputText
                    : "No command output yet. Select an action to begin."
                textFormat: Text.PlainText
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.NoWrap
                color: controller.outputText.length > 0 ? "#bcebf0" : "#607783"
                selectionColor: "#285a68"
                selectedTextColor: "#ffffff"
                font.family: "monospace"
                font.pixelSize: 9
                padding: 7
                background: Rectangle {
                    color: "#03070be8"
                    border.color: "#183a43"
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: controller.running || controller.exitCode >= 0
            Text {
                text: controller.running ? "PROCESS ACTIVE"
                    : "EXIT " + controller.exitCode + " // " + controller.resultStatus.toUpperCase()
                color: controller.resultStatus === "failed" || controller.resultStatus === "error"
                    || controller.resultStatus === "signaled"
                    ? "#ff8ab4" : "#7898a3"
                font.family: "monospace"
                font.pixelSize: 7
                Layout.fillWidth: true
            }
            C.NeonButton {
                visible: controller.running && controller.cancellable
                enabled: !controller.cancelPending
                text: controller.cancelPending ? "STOPPING" : "CANCEL"
                accent: "#ff6aa2"
                implicitHeight: 23
                font.pixelSize: 7
                onClicked: controller.cancel()
            }
        }
    }

    Connections {
        target: controller
        function onOutputTextChanged() {
            if (root.followOutput)
                output.cursorPosition = output.length
        }
    }
}
