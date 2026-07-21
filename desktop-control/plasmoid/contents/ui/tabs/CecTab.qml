import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components
import "../Utils.js" as Utils

ColumnLayout {
    id: root
    required property var backend
    readonly property var snapshot: backend.snapshot
    readonly property var cec: snapshot.cec
    readonly property bool controlsEnabled: snapshot.toolkit.cecAvailable && cec.devicePresent && !backend.busy
    readonly property string disabledReason: backend.busy ? backend.busyLabel
        : !cec.devicePresent ? "Connect a CEC-tunneling DP-to-HDMI adapter to expose /dev/cec0."
        : !snapshot.toolkit.cecAvailable ? "The CEC toolkit component is unavailable."
        : "CEC controls are unavailable."
    property string cecName: cec.osdName || ""
    spacing: Kirigami.Units.largeSpacing

    onCecChanged: if (!backend.busy) cecName = cec.osdName || ""

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "CEC Status"
        Components.StatusRow { label: "Daemon"; value: cec.service.active; health: cec.service.active === "active" ? 1 : -1 }
        Components.StatusRow {
            label: "Active source"; value: cec.active === null ? "Unknown" : cec.active ? "This console" : "Another source"
            health: cec.active === true ? 1 : -1
        }
        Components.StatusRow { label: "Poweroff integration"; value: cec.poweroffIntegration ? "Installed" : "Pending"; health: cec.poweroffIntegration ? 1 : -1 }
        Components.StatusRow { label: "Sleep integration"; value: cec.sleepIntegration ? "Installed" : "Pending"; health: cec.sleepIntegration ? 1 : -1 }
        RowLayout {
            Layout.fillWidth: true
            QQC2.TextField {
                id: nameField
                text: root.cecName
                placeholderText: "CEC broadcast name"
                maximumLength: 14
                enabled: root.controlsEnabled && root.cec.osdName !== null
                Layout.fillWidth: true
                onTextEdited: root.cecName = text
                onAccepted: if (saveButton.enabled) saveButton.clicked()
            }
            QQC2.Button {
                id: saveButton
                text: "Save"
                readonly property int byteCount: Utils.utf8Bytes(root.cecName.trim()).length
                readonly property bool safeText: !/["\\\u0000-\u001f\u007f-\u009f]/.test(root.cecName.trim())
                enabled: root.controlsEnabled && byteCount > 0 && byteCount <= 14
                    && safeText && root.cecName.trim() !== (root.cec.osdName || "")
                onClicked: {
                    try {
                        root.backend.setCecName(root.cecName);
                    } catch (caught) {
                        root.backend.error = String(caught);
                    }
                }
                QQC2.ToolTip.visible: hovered && !enabled
                QQC2.ToolTip.text: byteCount > 14 ? "The name exceeds 14 UTF-8 bytes."
                    : !safeText ? "Double quotes, backslashes, and control characters are not allowed."
                    : root.disabledReason
            }
        }
    }

    Components.Section {
        title: "TV and Receiver"
        GridLayout {
            columns: root.width >= 420 ? 2 : 1
            Layout.fillWidth: true
            Components.ActionButton {
                text: "Wake TV and select input"; enabled: root.controlsEnabled; disabledReason: root.disabledReason
                onClicked: root.backend.cecAction("tv-on")
            }
            Components.ActionButton {
                text: "TV standby"; enabled: root.controlsEnabled; disabledReason: root.disabledReason
                onClicked: confirmation.ask("Put the TV in standby?", "The television will enter standby immediately.",
                    false, function() { root.backend.cecAction("tv-off"); })
            }
            Components.ActionButton {
                text: "Receiver on"; enabled: root.controlsEnabled; disabledReason: root.disabledReason
                onClicked: root.backend.cecAction("amp-on")
            }
            Components.ActionButton {
                text: "Receiver standby"; enabled: root.controlsEnabled; disabledReason: root.disabledReason
                onClicked: confirmation.ask("Put the receiver in standby?", "The receiver will enter standby immediately.",
                    false, function() { root.backend.cecAction("amp-off"); })
            }
            Components.ActionButton {
                text: "Claim active source"; enabled: root.controlsEnabled; disabledReason: root.disabledReason
                onClicked: root.backend.cecAction("switch")
            }
            Components.ActionButton {
                text: "Release active source"; enabled: root.controlsEnabled; disabledReason: root.disabledReason
                onClicked: root.backend.cecAction("release")
            }
        }
    }

    Components.Section {
        title: "Volume"
        RowLayout {
            Layout.fillWidth: true
            Components.ActionButton { text: "Volume up"; enabled: root.controlsEnabled; disabledReason: root.disabledReason; onClicked: root.backend.cecAction("vol-up") }
            Components.ActionButton { text: "Volume down"; enabled: root.controlsEnabled; disabledReason: root.disabledReason; onClicked: root.backend.cecAction("vol-down") }
            Components.ActionButton { text: "Mute"; enabled: root.controlsEnabled; disabledReason: root.disabledReason; onClicked: root.backend.cecAction("mute") }
        }
    }

    Components.Section {
        title: "Behavior"
        QQC2.Switch {
            text: "Wake TV on resume"; checked: cec.wakeTv === true
            enabled: root.controlsEnabled && cec.wakeTv !== null
            onToggled: root.backend.setCecToggle("wake-tv", checked)
        }
        QQC2.Switch {
            text: "TV standby on suspend"; checked: cec.suspendTv === true
            enabled: root.controlsEnabled && cec.suspendTv !== null
            onToggled: root.backend.setCecToggle("suspend-tv", checked)
        }
        QQC2.Switch {
            text: "Suspend when TV turns off"; checked: cec.allowStandby === true
            enabled: root.controlsEnabled && cec.allowStandby !== null
            onToggled: root.backend.setCecToggle("allow-standby", checked)
        }
        QQC2.Switch {
            text: "TV remote input"; checked: cec.uinput === true
            enabled: root.controlsEnabled && cec.uinput !== null
            onToggled: root.backend.setCecToggle("uinput", checked)
        }
        QQC2.Label {
            visible: !root.controlsEnabled
            text: root.disabledReason
            color: Kirigami.Theme.neutralTextColor; wrapMode: Text.Wrap; Layout.fillWidth: true
        }
    }
}
