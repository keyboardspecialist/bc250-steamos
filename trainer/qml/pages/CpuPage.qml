import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    spacing: 8
    readonly property var snap: backend.snapshot || ({})
    readonly property var cpu: snap.cpu || ({})
    readonly property var mitigations: cpu.mitigations || ({})
    readonly property var unlock: backend.cpuUnlockStatus || ({})
    readonly property var guard: unlock.guard || ({})
    readonly property var actions: unlock.actions || ({})
    readonly property var linuxReplay: unlock.linuxReplay || ({})
    readonly property var efi: unlock.efi || ({})
    readonly property var linuxService: linuxReplay.service || unlock.service || ({})
    readonly property string unlockMode: unlock.mode || (linuxService.enabled === "enabled"
        ? "linux-replay" : unlock.topologyState === "unlocked" ? "temporary" : "none")
    readonly property bool recoveryWarningVisible: unlockMode === "conflict" || unlockMode === "partial"
    readonly property bool automaticRebootPending: guard.state === "automatic" && guard.currentBoot === true
    readonly property bool cpuControls: Boolean((snap.toolkit || {}).cpuControlAvailable) && !backend.busy && !automaticRebootPending
    readonly property bool unlockControls: unlock.schemaVersion === 1 && !backend.busy && !automaticRebootPending
    property int frequency: 4000
    property int voltage: 1275
    property int temperature: 90

    function actionStatus(action, readyText) {
        var state = actions[action] || ({})
        var blockers = state.blockers || []
        if (blockers.length > 0)
            return "Blocked: " + blockers.join(", ")
        if (state.available !== true)
            return state.hint || state.message || "Unavailable from the installed service."
        return state.hint || state.message || readyText
    }

    function modeLabel(mode) {
        if (mode === "linux-replay") return "LINUX REPLAY"
        if (mode === "efi") return "EFI PREBOOT"
        if (mode === "temporary") return "ONE-TIME TEST"
        return (mode || "unknown").toUpperCase()
    }

    function serviceLabel(service) {
        var enabled = service.enabled || "unknown"
        var active = service.active || "unknown"
        return enabled + " / " + active
    }

    function firstValue(source, names) {
        for (var index = 0; index < names.length; ++index) {
            if (source[names[index]] !== undefined && source[names[index]] !== null)
                return source[names[index]]
        }
        return undefined
    }

    function stateLabel(value) {
        if (value === undefined) return "Unknown"
        if (typeof value === "boolean") return value ? "Installed" : "Not installed"
        return String(value)
    }

    function efiInstalledLabel() {
        if (efi.partial === true) return "Partial"
        return stateLabel(firstValue(efi, ["installed", "imageInstalled", "espImageInstalled"]))
    }

    function efiBootEntryLabel() {
        var entry = efi.bootEntry
        if (!entry || typeof entry !== "object")
            return "Unavailable"
        if (entry.queryAvailable !== true) return "Unavailable"
        if (efi.unrecordedMatchingEntries === true) return "Unowned entry"
        if (entry.effective === true) return "Effective"
        if (entry.present === false) return "Missing"
        if (entry.active === false) return "Inactive"
        if (entry.matching === false) return "Mismatched"
        if (entry.firstInBootOrder === false) return "Reordered"
        return "Unavailable"
    }

    function efiBootEntryHealth() {
        var entry = efi.bootEntry
        if (!entry || typeof entry !== "object" || entry.queryAvailable !== true
                || entry.effective === undefined || entry.effective === null)
            return 0
        return entry.effective === true ? 1 : -1
    }

    function disableLabel() {
        if (unlockMode === "efi") return "DISABLE EFI PREBOOT"
        if (unlockMode === "linux-replay") return "DISABLE LINUX REPLAY"
        if (unlockMode === "conflict") return "RECOVER CONFLICTING MODES"
        if (unlockMode === "partial") return "ATTEMPT PARTIAL CLEANUP"
        return "DISABLE CORE UNLOCK"
    }

    function disableDetail() {
        if (unlockMode === "efi")
            return "This disables the EFI preboot mode and may remove its firmware boot entry. It does not relock cores during the current boot; fully power off to return to the factory six-core mask."
        if (unlockMode === "conflict" || unlockMode === "partial")
            return "This first disables Linux replay, then removes only EFI state whose toolkit ownership can be verified. Ambiguous or unqueryable firmware entries are retained for manual recovery. It does not relock cores during the current boot."
        return "This disables the active core-unlock mode. It does not relock cores during the current boot. If eight cores remain active, a complete shutdown and full power-off is required to return to the factory six-core mask."
    }

    C.ConfirmDialog { id: confirm; objectName: "cpuConfirmDialog" }
    C.SectionHeader { text: "CPU security mitigations" }
    Switch {
        id: mitigationSwitch
        objectName: "cpuMitigationsSwitch"
        text: "ENABLE KERNEL SECURITY MITIGATIONS"
        checked: root.mitigations.configuredEnabled === true
        enabled: root.cpuControls && root.mitigations.available === true
            && typeof root.mitigations.configuredEnabled === "boolean"
        onClicked: {
            var nextEnabled = checked;
            checked = Qt.binding(function() { return root.mitigations.configuredEnabled === true; });
            if (nextEnabled) {
                root.backend.setCpuMitigations(true);
            } else {
                confirm.ask("Disable CPU security mitigations?",
                    "This may improve performance, but reduces protection against processor security vulnerabilities. A reboot is required.", true,
                    function() { root.backend.setCpuMitigations(false); });
            }
        }
    }
    C.StatusRow {
        objectName: "cpuMitigationsBootStatus"
        label: "Current boot"
        value: root.mitigations.bootEnabled === null || root.mitigations.bootEnabled === undefined
            ? "Unknown" : root.mitigations.bootEnabled ? "Enabled" : "Disabled"
        health: root.mitigations.bootEnabled === false ? -1 : 1
    }
    Text {
        visible: root.mitigations.rebootRequired === true || root.mitigations.state === "foreign"
            || root.mitigations.state === "incomplete"
        text: root.mitigations.state === "foreign"
            ? "A non-toolkit GRUB source controls mitigations; remove it manually before using this toggle."
            : root.mitigations.state === "incomplete"
            ? "The GRUB source and generated boot configuration disagree. Reapply the setting from the terminal."
            : "Reboot required to apply the configured mitigation state."
        color: "#ffb06a"; font.family: "monospace"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true
    }
    C.SectionHeader { text: "CPU topology and core unlock" }
    RowLayout {
        Layout.fillWidth: true
        C.MetricTile { label: "PHYSICAL"; value: (root.unlock.physicalCores ?? "--") + " CORES"; Layout.fillWidth: true }
        C.MetricTile { label: "LOGICAL"; value: (root.unlock.logicalThreads ?? "--") + " THREADS"; accent: "#ef48bb"; Layout.fillWidth: true }
        C.MetricTile { label: "STATE"; value: (root.unlock.topologyState || "UNKNOWN").toUpperCase(); accent: root.unlock.topologyState === "unlocked" ? "#49ff9a" : "#ff9a55"; Layout.fillWidth: true }
        C.MetricTile { objectName: "cpuUnlockModeTile"; label: "MODE"; value: root.modeLabel(root.unlockMode); accent: root.unlockMode === "conflict" || root.unlockMode === "partial" ? "#ff4d8d" : "#22e7f2"; Layout.fillWidth: true }
    }
    C.StatusRow { label: "Unlock helper / unit"; value: root.unlock.helperInstalled ? (root.unlock.unitInstalled ? "Installed / installed" : "Installed / missing") : "Unavailable"; health: root.unlock.helperInstalled && root.unlock.unitInstalled ? 1 : -1 }
    C.StatusRow { label: "Linux replay service (enabled / active)"; value: root.serviceLabel(root.linuxService); health: root.linuxService.enabled === "enabled" ? 1 : 0 }
    C.StatusRow { objectName: "efiInstallStatus"; label: "EFI installation"; value: root.efiInstalledLabel(); health: root.efi.partial ? -1 : root.efi.installed ? 1 : 0 }
    C.StatusRow { objectName: "efiBootEntryStatus"; label: "EFI firmware boot entry"; value: root.efiBootEntryLabel(); health: root.efiBootEntryHealth() }
    C.StatusRow { label: "Reboot guard"; value: root.automaticRebootPending ? "AUTOMATIC REBOOT PENDING" : root.guard.state || "Unknown"; health: root.automaticRebootPending ? -1 : 0 }
    Repeater {
        model: root.unlock.ccxGroups || []
        C.StatusRow {
            required property var modelData
            label: "CCX " + (modelData.ccxId ?? "?")
            value: "cores " + (modelData.cores || []).map(function(core) { return core.coreId }).join(", ")
        }
    }
    Text { visible: Boolean(root.unlock.message); text: root.unlock.message || ""; color: "#ffb06a"; font.family: "monospace"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
    Text {
        objectName: "cpuUnlockModeWarning"
        visible: root.recoveryWarningVisible
        text: root.unlockMode === "conflict"
            ? "CONFLICT: Linux replay and EFI preboot are both configured. Do not enable either mode; use the disable action to recover to one clean state."
            : "PARTIAL INSTALL: a core-unlock mode is incomplete or inconsistent. Do not enable another mode. The cleanup action can remove verified toolkit-owned state; ambiguous entries require manual firmware recovery."
        color: "#ff6aa2"; font.family: "monospace"; font.pixelSize: 10; font.bold: true
        wrapMode: Text.Wrap; Layout.fillWidth: true
    }

    GridLayout {
        Layout.fillWidth: true
        columns: root.width >= 500 ? 2 : 1
        columnSpacing: 8
        rowSpacing: 8

        C.NeonPanel {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            implicitHeight: linuxOption.implicitHeight + 20
            accent: "#49ff9a"
            ColumnLayout {
                id: linuxOption
                anchors.fill: parent; anchors.margins: 10
                spacing: 6
                Text { text: "LINUX REPLAY (RECOMMENDED)"; color: "#49ff9a"; font.family: "monospace"; font.pixelSize: 11; font.bold: true; Layout.fillWidth: true }
                Text {
                    text: "Safest persistent method. After each cold power-on, Linux boots once to apply the mask, then warm-reboots into Linux a second time."
                    color: "#c6d9df"; font.family: "monospace"; font.pixelSize: 9
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                C.NeonButton {
                    objectName: "cpuUnlockTestButton"
                    text: "ONE-TIME TEST"; Layout.fillWidth: true
                    enabled: root.unlockControls && Boolean((root.actions.test || {}).available)
                    hint: "Changes the mask now; Linux sees added cores after a warm reboot."
                    onClicked: confirm.ask("Test disabled CPU cores?",
                        "Disabled cores may be physically defective. The mask changes immediately, but Linux cannot enumerate added cores until a warm reboot. Instability, restart, or data loss is possible.", true,
                        function() { root.backend.cpuUnlockAction("test") })
                }
                Text {
                    text: root.actionStatus("test", "Ready for a one-time warm-reboot test.")
                    color: (root.actions.test || {}).available ? "#76b8bd" : "#ff8ab4"
                    font.family: "monospace"; font.pixelSize: 8; wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                C.NeonButton {
                    objectName: "linuxReplayEnableButton"
                    text: "ENABLE LINUX REPLAY"; Layout.fillWidth: true
                    enabled: root.unlockControls && Boolean((root.actions.enable || {}).available)
                    hint: "Available only when the service reports the tested topology is ready for replay."
                    onClicked: confirm.ask("Enable Linux core-unlock replay?",
                        "Persist only after the eight-core topology has completed stability testing. Disabled cores may be defective. Cold power-on will boot Linux once to apply the mask, then perform a warm reboot into Linux.", true,
                        function() { root.backend.cpuUnlockAction("enable") })
                }
                Text {
                    text: root.actionStatus("enable", "Ready to enable Linux replay.")
                    color: (root.actions.enable || {}).available ? "#76b8bd" : "#ff8ab4"
                    font.family: "monospace"; font.pixelSize: 8; wrapMode: Text.Wrap; Layout.fillWidth: true
                }
            }
        }

        C.NeonPanel {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            implicitHeight: efiOption.implicitHeight + 20
            accent: "#ef48bb"
            ColumnLayout {
                id: efiOption
                anchors.fill: parent; anchors.margins: 10
                spacing: 6
                Text { text: "EFI PREBOOT (EXPERIMENTAL)"; color: "#ef70cc"; font.family: "monospace"; font.pixelSize: 11; font.bold: true; Layout.fillWidth: true }
                Text {
                    text: "Applies before Linux, avoiding one Linux boot, but still performs one quick firmware warm reset after cold power. Upstream support is new and reverse-engineered. The unsigned EFI image does not work with Secure Boot."
                    color: "#c6d9df"; font.family: "monospace"; font.pixelSize: 9
                    wrapMode: Text.Wrap; Layout.fillWidth: true
                }
                C.NeonButton {
                    objectName: "efiEnableButton"
                    text: "ENABLE EFI PREBOOT"; Layout.fillWidth: true; accent: "#ef48bb"
                    enabled: root.unlockControls && Boolean((root.actions["efi-enable"] || {}).available)
                    hint: "Action availability is advisory. Installation performs additional runtime preflight for Secure Boot, the ESP mount, NVRAM access, and required tools."
                    onClicked: confirm.ask("Enable experimental EFI preboot?",
                        "This experimental, new, reverse-engineered mode changes files on the ESP and changes the firmware boot entry/order. Installation first performs additional runtime preflight for Secure Boot, the ESP mount, NVRAM access, and required tools. The unsigned EFI image does not work with Secure Boot. If boot fails, recover in firmware setup by disabling or removing its boot entry.", true,
                        function() { root.backend.cpuUnlockAction("efi-enable") },
                        "I understand the ESP, boot-order, Secure Boot, and recovery risks.")
                }
                Text {
                    objectName: "efiActionHelp"
                    text: root.actionStatus("efi-enable", "Action available; installation still runs runtime preflight for Secure Boot, ESP mount, NVRAM, and tools.")
                    color: (root.actions["efi-enable"] || {}).available ? "#b987aa" : "#ff8ab4"
                    font.family: "monospace"; font.pixelSize: 8; wrapMode: Text.Wrap; Layout.fillWidth: true
                }
            }
        }
    }

    C.NeonButton {
        objectName: "cpuUnlockOffButton"
        text: root.disableLabel(); Layout.fillWidth: true; accent: "#ff6aa2"
        enabled: root.unlockControls && Boolean((root.actions.off || {}).available)
        hint: root.actionStatus("off", "Disable the active core-unlock mode.")
        onClicked: confirm.ask(root.disableLabel() + "?", root.disableDetail(), true,
            function() { root.backend.cpuUnlockAction("off") })
    }
    Text {
        text: root.actionStatus("off", "No active mode needs disabling.")
        color: (root.actions.off || {}).available ? "#76b8bd" : "#ff8ab4"
        font.family: "monospace"; font.pixelSize: 8; wrapMode: Text.Wrap; Layout.fillWidth: true
    }

    C.SectionHeader { text: "CPU overclock profile" }
    C.StatusRow { label: "Detected profile"; value: ((root.cpu.staged || root.cpu.installed || {}).detected) || "None" }
    RowLayout {
        Layout.fillWidth: true
        C.NeonSpinBox { from: 3500; to: 4500; stepSize: 100; value: root.frequency; editable: true; enabled: root.cpuControls; Layout.fillWidth: true; onValueModified: root.frequency = value; textFromValue: function(v) { return v + " MHz" } }
        C.NeonSpinBox { from: 950; to: 1325; stepSize: 25; value: root.voltage; editable: true; enabled: root.cpuControls; Layout.fillWidth: true; onValueModified: root.voltage = value; textFromValue: function(v) { return v + " mV" } }
        C.NeonSpinBox { from: 50; to: 100; stepSize: 5; value: root.temperature; editable: true; enabled: root.cpuControls; Layout.fillWidth: true; onValueModified: root.temperature = value; textFromValue: function(v) { return v + " C" } }
    }
    RowLayout {
        Layout.fillWidth: true
        C.NeonButton {
            text: "DETECT"; enabled: root.cpuControls; Layout.fillWidth: true
            onClicked: confirm.ask("Start CPU overclock detection?",
                "Close applications and save work. Detection stress-steps the CPU and can crash or restart the machine. Do not interrupt it while running.", true,
                function() { root.backend.cpuOcAction("detect", root.frequency, root.voltage, root.temperature) })
        }
        C.NeonButton { text: "APPLY NOW"; enabled: root.cpuControls && Boolean(root.cpu.staged || root.cpu.installed); Layout.fillWidth: true; onClicked: root.backend.cpuOcAction("apply", root.frequency, root.voltage, root.temperature) }
        C.NeonButton {
            text: "ENABLE BOOT"; enabled: root.cpuControls && Boolean(root.cpu.staged || root.cpu.installed); Layout.fillWidth: true
            onClicked: confirm.ask("Enable CPU profile at boot?", "Only persist a profile after stability testing. It will be applied on every boot.", false,
                function() { root.backend.cpuOcAction("enable", root.frequency, root.voltage, root.temperature) })
        }
        C.NeonButton {
            text: "STOCK"; enabled: root.cpuControls; Layout.fillWidth: true; accent: "#ff6aa2"
            onClicked: confirm.ask("Revert CPU tuning to stock?", "Boot replay will be disabled and stock limits applied now. The detected profile remains saved.", false,
                function() { root.backend.cpuOcAction("off", root.frequency, root.voltage, root.temperature) })
        }
    }
}
