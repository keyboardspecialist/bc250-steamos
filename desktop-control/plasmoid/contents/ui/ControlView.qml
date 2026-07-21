import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "components" as Components
import "tabs" as Tabs

Item {
    id: root
    required property var backend
    required property bool active
    property int currentTab: 0
    readonly property bool wide: width >= 760
    readonly property var tabs: [
        { label: "Overview", icon: "view-statistics" },
        { label: "GPU", icon: "video-display" },
        { label: "CU", icon: "cpu" },
        { label: "CPU", icon: "speedometer" },
        { label: "CEC", icon: "video-television" }
    ]

    implicitWidth: 600
    implicitHeight: 620
    Layout.minimumWidth: 360
    Layout.minimumHeight: 420
    Layout.preferredWidth: 620
    Layout.preferredHeight: 640

    onActiveChanged: {
        backend.uiVisible = active;
        backend.telemetryWanted = active && currentTab === 0;
        if (active)
            backend.refresh();
    }
    onCurrentTabChanged: backend.telemetryWanted = active && currentTab === 0
    Component.onCompleted: {
        backend.uiVisible = active;
        backend.telemetryWanted = active && currentTab === 0;
    }
    Component.onDestruction: {
        backend.uiVisible = false;
        backend.telemetryWanted = false;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            color: Kirigami.Theme.alternateBackgroundColor
            Layout.fillWidth: true
            implicitHeight: headerLayout.implicitHeight + Kirigami.Units.largeSpacing * 2

            RowLayout {
                id: headerLayout
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing

                ColumnLayout {
                    spacing: 0
                    Layout.fillWidth: true
                    QQC2.Label { text: "BC-250 Control"; font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.35; font.weight: Font.Bold }
                    QQC2.Label {
                        text: root.backend.busy ? root.backend.busyLabel : root.backend.healthSummary
                        color: root.backend.busy ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                QQC2.ToolButton {
                    icon.name: "view-refresh"
                    text: "Refresh"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: !root.backend.busy
                    onClicked: root.backend.refresh()
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.text: text
                }
                QQC2.ToolButton {
                    visible: root.backend.busy && root.backend.operationId
                    icon.name: "process-stop"
                    text: "Cancel operation"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: !root.backend.cancelPending
                    onClicked: root.backend.cancelOperation()
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.text: text
                }
                QQC2.Button {
                    visible: root.wide
                    text: "Open Full Controls"
                    icon.name: "window-duplicate"
                    onClicked: root.backend.openFullControls()
                }
            }
        }

        QQC2.ProgressBar {
            Layout.fillWidth: true
            visible: root.backend.busy
            indeterminate: true
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: root.backend.error.length > 0
            text: root.backend.error
            type: Kirigami.MessageType.Error
            showCloseButton: true
            onVisibleChanged: if (!visible) root.backend.error = ""
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: Boolean(root.backend.snapshot) && (!root.backend.snapshot.toolkit.available
                || !root.backend.snapshot.toolkit.privileged)
            text: root.backend.snapshot && !root.backend.snapshot.toolkit.available
                ? "Toolkit components are incomplete at " + root.backend.snapshot.toolkit.path
                : "The system service is not privileged; hardware mutations are disabled."
            type: Kirigami.MessageType.Warning
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: root.backend.notice.length > 0 && root.backend.error.length === 0
            text: root.backend.notice
            type: Kirigami.MessageType.Positive
            showCloseButton: true
            onVisibleChanged: if (!visible) root.backend.notice = ""
        }

        QQC2.ScrollView {
            id: topNavigation
            visible: !root.wide
            Layout.fillWidth: true
            Layout.preferredHeight: navRow.implicitHeight + Kirigami.Units.smallSpacing * 2
            QQC2.ScrollBar.vertical.policy: QQC2.ScrollBar.AlwaysOff
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AsNeeded
            contentWidth: navRow.implicitWidth

            RowLayout {
                id: navRow
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: root.tabs
                    QQC2.ToolButton {
                        required property var modelData
                        required property int index
                        text: modelData.label
                        icon.name: modelData.icon
                        checkable: true
                        checked: root.currentTab === index
                        onClicked: root.currentTab = index
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                visible: root.wide
                color: Kirigami.Theme.alternateBackgroundColor
                Layout.fillHeight: true
                Layout.preferredWidth: 154

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    Repeater {
                        model: root.tabs
                        QQC2.ToolButton {
                            required property var modelData
                            required property int index
                            text: modelData.label
                            icon.name: modelData.icon
                            display: QQC2.AbstractButton.TextBesideIcon
                            checkable: true
                            checked: root.currentTab === index
                            Layout.fillWidth: true
                            onClicked: root.currentTab = index
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }

            QQC2.ScrollView {
                id: contentScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true

                Item {
                    width: contentScroll.availableWidth
                    implicitHeight: contentColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

                    ColumnLayout {
                        id: contentColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Kirigami.Units.largeSpacing

                        QQC2.BusyIndicator {
                            visible: root.backend.loading && !root.backend.snapshot
                            running: visible
                            Layout.alignment: Qt.AlignHCenter
                        }

                        QQC2.Label {
                            visible: !root.backend.loading && !root.backend.snapshot
                            text: root.backend.error || "Unable to load toolkit status."
                            color: Kirigami.Theme.neutralTextColor
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                        }

                        Loader {
                            Layout.fillWidth: true
                            active: Boolean(root.backend.snapshot)
                            sourceComponent: root.currentTab === 0 ? overviewComponent
                                : root.currentTab === 1 ? gpuComponent
                                : root.currentTab === 2 ? cuComponent
                                : root.currentTab === 3 ? cpuComponent : cecComponent
                        }

                        QQC2.Button {
                            visible: !root.wide
                            text: "Open Full Controls"
                            icon.name: "window-duplicate"
                            Layout.fillWidth: true
                            onClicked: root.backend.openFullControls()
                        }
                    }
                }
            }
        }
    }

    Component { id: overviewComponent; Tabs.OverviewTab { backend: root.backend } }
    Component { id: gpuComponent; Tabs.GpuTab { backend: root.backend } }
    Component { id: cuComponent; Tabs.CuTab { backend: root.backend } }
    Component { id: cpuComponent; Tabs.CpuTab { backend: root.backend } }
    Component { id: cecComponent; Tabs.CecTab { backend: root.backend } }
}
