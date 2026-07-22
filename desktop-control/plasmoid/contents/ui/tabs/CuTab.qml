import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var snapshot: backend.snapshot
    readonly property var cu: snapshot.cu
    property bool advanced: false
    readonly property bool editable: advanced && cu.controllable && !backend.busy
    readonly property string disabledReason: backend.busy ? backend.busyLabel
        : !snapshot.toolkit.privileged ? "The system service is not privileged."
        : cu.liveReason ? String(cu.liveReason)
        : "Live editing requires readable GPU registers, the verified factory map, and the root-owned CU manager."
    spacing: Kirigami.Units.largeSpacing

    function savedRows() {
        var result = [];
        for (var index = 0; index < Math.min(4, cu.savedMasks.length); ++index) {
            var mask = Number(cu.savedMasks[index]) & 31;
            var factory = null;
            for (var rowIndex = 0; rowIndex < cu.rows.length; ++rowIndex) {
                if (cu.rows[rowIndex].se === Math.floor(index / 2) && cu.rows[rowIndex].sh === index % 2)
                    factory = cu.rows[rowIndex];
            }
            var wgps = [];
            for (var wgp = 0; wgp < 5; ++wgp)
                wgps.push(Boolean(mask & (1 << wgp)));
            result.push({
                se: Math.floor(index / 2), sh: index % 2, wgps: wgps,
                factoryWgps: factory ? factory.factoryWgps : [false, false, false, false, false],
                cus: wgps.filter(function(value) { return value; }).length * 2
            });
        }
        return result;
    }

    readonly property var displayRows: cu.available ? cu.rows : savedRows()

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "Compute Units"
        Components.StatusRow {
            label: "Live routing"; value: cu.available ? cu.total + "/" + cu.maximum + " CU" : "Unavailable"
            health: cu.available ? 1 : -1
        }
        Components.StatusRow {
            label: "Boot replay"; value: cu.service.enabled === "enabled" ? "Enabled" : "Disabled"
            health: cu.service.enabled === "enabled" ? 1 : -1
        }
        Components.StatusRow {
            label: "Factory lock"; value: cu.factoryMapAvailable ? cu.factoryTotal + "/40 CU locked" : "Map unavailable"
            health: cu.factoryMapAvailable ? 1 : -1
        }
        Components.StatusRow { label: "Update protection"; value: cu.protected ? "Protected" : "Pending"; health: cu.protected ? 1 : -1 }
    }

    Components.Section {
        title: cu.available ? "Active CU Routing" : "Saved CU Routing"
        visible: root.displayRows.length === 4

        Flickable {
            id: cuScroll
            Layout.fillWidth: true
            Layout.preferredHeight: cuGrid.implicitHeight + Kirigami.Units.gridUnit
            contentWidth: Math.max(width, 520)
            contentHeight: cuGrid.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            QQC2.ScrollBar.horizontal: QQC2.ScrollBar {}

            ColumnLayout {
                id: cuGrid
                width: cuScroll.contentWidth
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        text: ""
                        Layout.minimumWidth: 72
                        Layout.preferredWidth: 72
                        Layout.maximumWidth: 72
                    }
                    Repeater {
                        model: 5
                        QQC2.Label {
                            required property int index
                            text: "CU" + (index * 2) + "-" + (index * 2 + 1)
                            font: Kirigami.Theme.smallFont
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                            Layout.minimumWidth: 64
                            Layout.preferredWidth: 80
                        }
                    }
                    QQC2.Label {
                        text: "Total"
                        font: Kirigami.Theme.smallFont
                        horizontalAlignment: Text.AlignRight
                        Layout.minimumWidth: 52
                        Layout.preferredWidth: 52
                        Layout.maximumWidth: 52
                    }
                }

                Repeater {
                    model: root.displayRows
                    delegate: RowLayout {
                        id: rowDelegate
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.Label {
                            text: "SE" + rowDelegate.modelData.se + ".SH" + rowDelegate.modelData.sh
                            font: Kirigami.Theme.smallFont
                            Layout.minimumWidth: 72
                            Layout.preferredWidth: 72
                            Layout.maximumWidth: 72
                        }
                        Repeater {
                            model: 5
                            QQC2.Button {
                                id: routeButton
                                required property int index
                                readonly property bool routed: Boolean(rowDelegate.modelData.wgps[index])
                                readonly property bool factory: Boolean(rowDelegate.modelData.factoryWgps[index])
                                readonly property color stateColor: factory
                                    ? (routed ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.negativeTextColor)
                                    : routed ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                                text: factory ? (routed ? "OEM" : "OEM!") : routed ? "ON" : "OFF"
                                enabled: root.editable && !factory
                                Layout.fillWidth: true
                                Layout.minimumWidth: 64
                                Layout.preferredWidth: 80
                                background: Rectangle {
                                    radius: 4
                                    color: Qt.rgba(routeButton.stateColor.r, routeButton.stateColor.g,
                                        routeButton.stateColor.b, 0.16)
                                    border.color: routeButton.stateColor
                                    border.width: 1
                                }
                                contentItem: QQC2.Label {
                                    text: routeButton.text
                                    font: routeButton.font
                                    color: routeButton.stateColor
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                QQC2.ToolTip.visible: hovered && !enabled
                                QQC2.ToolTip.text: factory ? "Factory routing is locked." : root.disabledReason
                                onClicked: {
                                    var selectedWgp = index;
                                    var next = !routed;
                                    var pair = "CU" + (selectedWgp * 2) + "-" + (selectedWgp * 2 + 1);
                                    confirmation.ask((next ? "Enable " : "Disable ") + pair + "?",
                                        "This writes live GPU routing registers. Factory-disabled WGPs may be defective and can cause corruption, a GPU hang, or a forced reboot. Save your work and monitor temperatures.",
                                        true, function() {
                                            root.backend.setCuWgp(rowDelegate.modelData.se, rowDelegate.modelData.sh, selectedWgp, next);
                                        });
                                }
                            }
                        }
                        QQC2.Label {
                            text: rowDelegate.modelData.cus + "/10"
                            horizontalAlignment: Text.AlignRight
                            Layout.minimumWidth: 52
                            Layout.preferredWidth: 52
                            Layout.maximumWidth: 52
                        }
                    }
                }
            }
        }

        QQC2.Label {
            visible: !root.cu.available
            text: "Live registers are unavailable. The grid shows the saved boot table."
            color: Kirigami.Theme.neutralTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }

    Components.Section {
        title: "Advanced"
        QQC2.Switch {
            text: "Enable live WGP editing"
            checked: root.advanced && root.cu.controllable
            enabled: root.cu.controllable && !root.backend.busy
            onToggled: root.advanced = checked
        }
        QQC2.Label {
            text: root.cu.controllable
                ? "Each switch controls one two-CU WGP pair and writes routing registers immediately."
                : root.disabledReason
            color: root.cu.controllable ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.neutralTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        QQC2.Label {
            text: "Factory-disabled WGPs may have failed validation. Test correctness and stability before saving changes for boot."
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }

    Components.Section {
        title: "Boot Behavior"
        Components.StatusRow { label: "Saved table"; value: cu.savedMasks.length === 4 ? "Available" : "Unavailable"; health: cu.savedMasks.length === 4 ? 1 : -1 }
        QQC2.Label {
            text: "Save live routing and change boot replay from the toolkit CLI, where full harvest-map checks are available."
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
    }
}
