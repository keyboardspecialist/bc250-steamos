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
    readonly property var unlock: backend.cpuUnlockStatus || ({})
    readonly property var guard: unlock.guard || ({})
    readonly property var actions: unlock.actions || ({})
    readonly property bool automaticRebootPending: guard.state === "automatic"
    readonly property bool cpuControls: Boolean((snap.toolkit || {}).cpuControlAvailable) && !backend.busy && !automaticRebootPending
    readonly property bool unlockControls: unlock.schemaVersion === 1 && !backend.busy && !automaticRebootPending
    readonly property var actionBlockers: {
        var values = []
        var names = ["test", "enable", "off"]
        for (var index = 0; index < names.length; ++index) {
            var blockers = (actions[names[index]] || {}).blockers || []
            for (var blocker = 0; blocker < blockers.length; ++blocker) {
                if (values.indexOf(blockers[blocker]) < 0)
                    values.push(blockers[blocker])
            }
        }
        return values
    }
    property int frequency: 4000
    property int voltage: 1275
    property int temperature: 90

    C.ConfirmDialog { id: confirm }
    C.SectionHeader { text: "CPU topology and core unlock" }
    RowLayout {
        Layout.fillWidth: true
        C.MetricTile { label: "PHYSICAL"; value: (root.unlock.physicalCores ?? "--") + " CORES"; Layout.fillWidth: true }
        C.MetricTile { label: "LOGICAL"; value: (root.unlock.logicalThreads ?? "--") + " THREADS"; accent: "#ef48bb"; Layout.fillWidth: true }
        C.MetricTile { label: "STATE"; value: (root.unlock.topologyState || "UNKNOWN").toUpperCase(); accent: root.unlock.topologyState === "unlocked" ? "#49ff9a" : "#ff9a55"; Layout.fillWidth: true }
    }
    C.StatusRow { label: "Unlock helper / unit"; value: root.unlock.helperInstalled ? (root.unlock.unitInstalled ? "Installed / installed" : "Installed / missing") : "Unavailable"; health: root.unlock.helperInstalled && root.unlock.unitInstalled ? 1 : -1 }
    C.StatusRow { label: "Replay service"; value: (root.unlock.service || {}).enabled || "Unknown"; health: (root.unlock.service || {}).enabled === "enabled" ? 1 : 0 }
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
    Text { visible: root.actionBlockers.length > 0; text: "BLOCKERS: " + root.actionBlockers.join(", "); color: "#ff6aa2"; font.family: "monospace"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
    RowLayout {
        Layout.fillWidth: true
        C.NeonButton {
            text: "ONE-TIME TEST"; Layout.fillWidth: true
            enabled: root.unlockControls && Boolean((root.actions.test || {}).available)
            hint: "Changes the mask now; Linux sees added cores after a warm reboot."
            onClicked: confirm.ask("Test disabled CPU cores?",
                "Disabled cores may be physically defective. The mask changes immediately, but Linux cannot enumerate added cores until a warm reboot. Instability, restart, or data loss is possible.", true,
                function() { root.backend.cpuUnlockAction("test") })
        }
        C.NeonButton {
            text: "ENABLE REPLAY"; Layout.fillWidth: true
            enabled: root.unlockControls && Boolean((root.actions.enable || {}).available)
            hint: root.unlock.physicalCores === 8 ? "Persist the tested eight-core mask." : "Available only after Linux reports exactly eight physical cores."
            onClicked: confirm.ask("Enable core-unlock replay?",
                "Persist only after the eight-core topology has completed stability testing. Disabled cores may be defective and the mask will be replayed during boot.", true,
                function() { root.backend.cpuUnlockAction("enable") })
        }
        C.NeonButton {
            text: "DISABLE REPLAY"; Layout.fillWidth: true
            enabled: root.unlockControls && Boolean((root.actions.off || {}).available)
            onClicked: confirm.ask("Disable core-unlock replay?",
                "This does not relock cores during the current boot. If eight cores remain active, a complete shutdown and full power-off is required to return to the factory six-core mask.", true,
                function() { root.backend.cpuUnlockAction("off") })
        }
    }

    C.SectionHeader { text: "CPU overclock profile" }
    C.StatusRow { label: "Detected profile"; value: ((root.cpu.staged || root.cpu.installed || {}).detected) || "None" }
    RowLayout {
        Layout.fillWidth: true
        SpinBox { from: 3500; to: 4500; stepSize: 100; value: root.frequency; editable: true; enabled: root.cpuControls; Layout.fillWidth: true; onValueModified: root.frequency = value; textFromValue: function(v) { return v + " MHz" } }
        SpinBox { from: 950; to: 1325; stepSize: 25; value: root.voltage; editable: true; enabled: root.cpuControls; Layout.fillWidth: true; onValueModified: root.voltage = value; textFromValue: function(v) { return v + " mV" } }
        SpinBox { from: 50; to: 100; stepSize: 5; value: root.temperature; editable: true; enabled: root.cpuControls; Layout.fillWidth: true; onValueModified: root.temperature = value; textFromValue: function(v) { return v + " C" } }
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
