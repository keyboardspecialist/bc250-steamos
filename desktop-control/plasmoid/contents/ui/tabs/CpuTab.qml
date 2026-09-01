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
    readonly property var mitigations: cpu.mitigations || ({})
    readonly property var unlock: backend.cpuUnlockStatus || ({})
    readonly property var unlockActions: unlock.actions || ({})
    readonly property var unlockGuard: unlock.guard || ({})
    readonly property string unlockMode: unlock.mode || "unknown"
    readonly property bool unlockControlsEnabled: unlock.schemaVersion === 1 && !backend.busy
        && !(unlockGuard.state === "automatic" && unlockGuard.currentBoot === true)
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

    function unlockActionState(action) {
        return unlockActions[action] || ({});
    }

    function unlockActionReason(action, fallback) {
        var state = unlockActionState(action);
        var blockers = state.blockers || [];
        if (blockers.length > 0)
            return "Blocked: " + blockers.join(", ").replace(/-/g, " ");
        return state.hint || state.message || fallback;
    }

    function unlockActionEnabled(action) {
        return unlockControlsEnabled && unlockActionState(action).available === true;
    }

    function unlockModeLabel() {
        if (unlockMode === "linux-replay") return "Standard Linux";
        if (unlockMode === "efi") return "EFI preboot";
        if (unlockMode === "temporary") return "One-time test";
        if (unlockMode === "none") return "Disabled";
        return unlockMode.replace(/-/g, " ");
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
        title: "CPU Topology and Core Unlock"
        Components.StatusRow {
            label: "Physical cores"
            value: root.unlock.physicalCores === undefined ? "Unavailable" : String(root.unlock.physicalCores)
            health: root.unlock.physicalCores >= 8 ? 1 : root.unlock.physicalCores > 0 ? 0 : -1
        }
        Components.StatusRow {
            label: "Logical threads"
            value: root.unlock.logicalThreads === undefined ? "Unavailable" : String(root.unlock.logicalThreads)
            health: root.unlock.logicalThreads >= 16 ? 1 : root.unlock.logicalThreads > 0 ? 0 : -1
        }
        Components.StatusRow {
            label: "Topology"
            value: root.unlock.topologyState ? String(root.unlock.topologyState).replace(/-/g, " ") : "Unavailable"
            health: root.unlock.topologyState === "unlocked" ? 1 : root.unlock.topologyState === "locked" ? 0 : -1
        }
        Components.StatusRow {
            label: "Persistent method"
            value: root.unlockModeLabel()
            health: root.unlockMode === "conflict" || root.unlockMode === "partial" ? -1
                : root.unlockMode === "linux-replay" || root.unlockMode === "efi" ? 1 : 0
        }
        Components.StatusRow {
            label: "Linux replay service"
            value: (root.unlock.linuxReplay || root.unlock).service
                ? (root.unlock.linuxReplay || root.unlock).service.enabled + " / "
                    + (root.unlock.linuxReplay || root.unlock).service.active : "Unavailable"
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: root.unlockMode === "conflict" || root.unlockMode === "partial"
                || (root.unlockGuard.state === "automatic" && root.unlockGuard.currentBoot === true)
            type: Kirigami.MessageType.Warning
            text: root.unlockGuard.state === "automatic" && root.unlockGuard.currentBoot === true
                ? "An automatic core-unlock reboot is pending; controls are temporarily disabled."
                : root.unlock.message || "Core-unlock installation is conflicting or incomplete. Disable it to recover verified toolkit-owned state."
        }
        Components.ActionButton {
            text: "Run one-time unlock test"
            description: root.unlockActionReason("test", "Tests disabled cores before enabling persistence.")
            enabled: root.unlockActionEnabled("test")
            disabledReason: description
            onClicked: confirmation.ask("Test disabled CPU cores?",
                "Disabled cores may be physically defective. The mask changes immediately, but Linux discovers added cores only after a warm reboot. Instability or data loss is possible.",
                true, function() { root.backend.cpuUnlockAction("test"); })
        }
        Components.ActionButton {
            text: "Enable standard Linux method"
            description: root.unlockActionReason("enable", "Replays the tested mask during Linux boot.")
            enabled: root.unlockActionEnabled("enable")
            disabledReason: description
            onClicked: confirmation.ask("Enable standard Linux core unlock?",
                "Only persist cores after stability testing. Each cold power-on boots Linux once to apply the mask, then warm-reboots into Linux.",
                true, function() { root.backend.cpuUnlockAction("enable"); })
        }
        Components.ActionButton {
            text: "Enable EFI preboot method"
            description: root.unlockActionReason("efi-enable", "Experimental alternative to Linux replay; Secure Boot is unsupported.")
            enabled: root.unlockActionEnabled("efi-enable")
            disabledReason: description
            onClicked: confirmation.ask("Enable experimental EFI core unlock?",
                "This installs an unsigned EFI image and changes firmware boot order. Secure Boot is unsupported. Firmware recovery may be required if boot fails.",
                true, function() { root.backend.cpuUnlockAction("efi-enable"); })
        }
        Components.ActionButton {
            text: "Disable core unlock"
            description: root.unlockActionReason("off", "Disables persistent unlock state; a full power-off restores the factory mask.")
            enabled: root.unlockActionEnabled("off")
            disabledReason: description
            onClicked: confirmation.ask("Disable CPU core unlock?",
                "Persistent unlock state will be removed. Cores remain visible during this boot; fully power off to restore the factory core mask.",
                true, function() { root.backend.cpuUnlockAction("off"); })
        }
    }

    Components.Section {
        title: "CPU Security"
        QQC2.Switch {
            id: mitigationSwitch
            text: "CPU security mitigations"
            checked: root.mitigations.configuredEnabled === true
            enabled: root.controlsEnabled && root.mitigations.available === true
                && typeof root.mitigations.configuredEnabled === "boolean"
            onClicked: {
                var nextEnabled = checked;
                checked = Qt.binding(function() { return root.mitigations.configuredEnabled === true; });
                if (nextEnabled) {
                    root.backend.setCpuMitigations(true);
                } else {
                    confirmation.ask("Disable CPU security mitigations?",
                        "This may improve performance, but reduces protection against processor security vulnerabilities. A reboot is required.",
                        true, function() { root.backend.setCpuMitigations(false); });
                }
            }
        }
        Components.StatusRow {
            label: "Current boot"
            value: root.mitigations.bootEnabled === null || root.mitigations.bootEnabled === undefined
                ? "Unknown" : root.mitigations.bootEnabled ? "Enabled" : "Disabled"
            health: root.mitigations.bootEnabled === false ? -1 : 1
        }
        Components.StatusRow {
            label: "Boot change"
            value: root.mitigations.state === "foreign" ? "Foreign GRUB configuration"
                : root.mitigations.state === "incomplete" ? "GRUB repair required"
                : root.mitigations.rebootRequired ? "Reboot required" : "Applied"
            health: root.mitigations.state === "foreign" || root.mitigations.state === "incomplete"
                ? -1 : root.mitigations.rebootRequired ? 0 : 1
        }
    }

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
