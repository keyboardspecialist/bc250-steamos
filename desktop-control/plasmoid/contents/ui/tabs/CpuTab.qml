import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var snapshot: backend.snapshot
    readonly property var cpu: snapshot.cpu
    readonly property string detected: cpu.staged && cpu.staged.detected ? cpu.staged.detected
        : cpu.installed && cpu.installed.detected ? cpu.installed.detected : ""
    readonly property bool controlsEnabled: snapshot.toolkit.privileged
        && snapshot.toolkit.cpuControlAvailable && !backend.busy
    readonly property bool profileAvailable: Boolean(cpu.installed || cpu.staged)
    readonly property string disabledReason: backend.busy ? backend.busyLabel
        : !snapshot.toolkit.privileged ? "The system service is not privileged."
        : !snapshot.toolkit.cpuControlAvailable ? "Install the root-owned CPU tuning helper."
        : "CPU controls are unavailable."
    property int frequency: 4000
    property int voltage: 1275
    property int temperature: 90
    spacing: Kirigami.Units.largeSpacing

    function run(action) {
        backend.cpuOcAction(action, frequency, voltage, temperature);
    }

    function syncDetected() {
        var match = detected.match(/(\d+)\s*MHz\s*@\s*(\d+)\s*mV/i);
        if (match) {
            frequency = Number(match[1]);
            voltage = Number(match[2]);
        }
    }

    Component.onCompleted: syncDetected()
    onDetectedChanged: if (!backend.busy) syncDetected()

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "CPU Overclock"
        Components.StatusRow {
            label: "Boot service"; value: cpu.service.enabled === "enabled" ? "Enabled" : "Disabled"
            health: cpu.service.enabled === "enabled" ? 1 : -1
        }
        Components.StatusRow { label: "Live service"; value: cpu.service.active }
        Components.StatusRow { label: "Detected result"; value: root.detected || "Unavailable"; health: root.detected ? 1 : -1 }
    }

    Components.Section {
        title: "Detection"
        QQC2.Label { text: "Target boost clock" }
        QQC2.SpinBox {
            from: 3500; to: 4500; stepSize: 100; value: root.frequency; editable: true
            enabled: root.controlsEnabled; Layout.fillWidth: true
            textFromValue: (value) => value + " MHz"; valueFromText: (text) => parseInt(text)
            onValueModified: root.frequency = value
        }
        QQC2.Label { text: "VID safety limit" }
        QQC2.SpinBox {
            from: 950; to: 1325; stepSize: 25; value: root.voltage; editable: true
            enabled: root.controlsEnabled; Layout.fillWidth: true
            textFromValue: (value) => value + " mV"; valueFromText: (text) => parseInt(text)
            onValueModified: root.voltage = value
        }
        QQC2.Label { text: "Temperature limit" }
        QQC2.SpinBox {
            from: 50; to: 100; stepSize: 5; value: root.temperature; editable: true
            enabled: root.controlsEnabled; Layout.fillWidth: true
            textFromValue: (value) => value + " °C"; valueFromText: (text) => parseInt(text)
            onValueModified: root.temperature = value
        }
        Components.ActionButton {
            text: "Detect stable profile"
            description: "Stress-steps toward the target and leaves the detected profile active."
            enabled: root.controlsEnabled; disabledReason: root.disabledReason
            onClicked: confirmation.ask("Start CPU overclock detection?",
                "Close other applications first. Detection performs a long stress test and can hard-crash an unstable system. Do not power off while it is running.",
                true, function() { root.run("detect"); })
        }
    }

    Components.Section {
        title: "Profile Actions"
        Components.ActionButton {
            text: "Apply profile now"; enabled: root.controlsEnabled && root.profileAvailable
            disabledReason: !root.profileAvailable ? "No detected profile is available." : root.disabledReason
            onClicked: root.run("apply")
        }
        Components.ActionButton {
            text: "Enable profile at boot"
            description: "Saves the latest detected profile and applies it now."
            enabled: root.controlsEnabled && root.profileAvailable
            disabledReason: !root.profileAvailable ? "No detected profile is available." : root.disabledReason
            onClicked: confirmation.ask("Enable CPU profile at boot?",
                "Only enable a profile after confirming it is stable. It will be applied on every boot.",
                false, function() { root.run("enable"); })
        }
        Components.ActionButton {
            text: "Revert to stock"
            description: "Disables boot replay and restores the stock 3500 MHz curve."
            enabled: root.controlsEnabled; disabledReason: root.disabledReason
            onClicked: confirmation.ask("Revert CPU tuning to stock?",
                "The saved profile is kept, but boot replay is disabled and stock limits are applied now.",
                true, function() { root.run("off"); })
        }
    }

    Components.Section {
        title: "Boot Configuration"
        visible: Boolean(root.cpu.installed)
        Repeater {
            model: root.cpu.installed ? Object.keys(root.cpu.installed.values) : []
            Components.StatusRow {
                required property string modelData
                label: modelData.replace(/_/g, " ")
                value: root.cpu.installed.values[modelData]
            }
        }
    }

    Components.Section {
        title: "Staged Detection Result"
        visible: Boolean(root.cpu.staged)
        Components.StatusRow { label: "Result"; value: root.cpu.staged ? root.cpu.staged.detected || "Detected profile" : "" }
        QQC2.Label {
            text: "Complete stability testing before enabling this profile at boot."
            color: Kirigami.Theme.neutralTextColor; wrapMode: Text.Wrap; Layout.fillWidth: true
        }
    }
}
