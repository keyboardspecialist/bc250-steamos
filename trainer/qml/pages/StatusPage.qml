import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    spacing: 9
    readonly property var snap: backend.snapshot || ({})
    readonly property var gpu: snap.gpu || ({})
    readonly property var power: snap.power || ({})
    readonly property var cu: snap.cu || ({})
    readonly property var unlock: backend.cpuUnlockStatus || ({})
    readonly property var unlockGuard: unlock.guard || ({})
    readonly property bool automaticRebootPending: unlockGuard.state === "automatic" && unlockGuard.currentBoot === true
    readonly property var telemetry: backend.telemetry || ({})
    readonly property var audio: snap.audio || ({})
    readonly property var metrics: unlock.metrics || ({})
    readonly property var sensors: Array.isArray(telemetry.sensors) ? telemetry.sensors
        : Array.isArray(power.sensors) ? power.sensors : []

    C.ConfirmDialog { id: confirm }
    function clockValue(key, fallback) {
        var value = Object.prototype.hasOwnProperty.call(telemetry, key) ? telemetry[key] : fallback
        return typeof value === "number" && isFinite(value) ? value + " MHz" : "Unavailable"
    }
    Text { visible: Boolean(root.telemetry.error); text: "Live telemetry unavailable: " + (root.telemetry.error || ""); color: "#ffb06a"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }

    GridLayout {
        columns: 4
        columnSpacing: 6; rowSpacing: 6
        Layout.fillWidth: true
        C.MetricTile { label: "GPU CLK"; value: root.clockValue("gpuClock", root.gpu.activeMhz); Layout.fillWidth: true }
        C.MetricTile { label: "CPU CLK"; value: root.clockValue("cpuClock", root.power.cpuCurrentMhz); accent: "#ef48bb"; Layout.fillWidth: true }
        C.MetricTile { label: "GPU TEMP"; value: (root.telemetry.gpuTemp ?? "--") + " C"; accent: "#ff9a55"; Layout.fillWidth: true }
        C.MetricTile { label: "CPU TEMP"; value: (root.telemetry.cpuTemp ?? "--") + " C"; accent: "#49ff9a"; Layout.fillWidth: true }
    }

    C.SectionHeader { text: "Silicon status" }
    C.StatusRow { label: "Compute units"; value: root.cu.available ? root.cu.total + "/" + root.cu.maximum + " CU" : "Unavailable"; health: root.cu.available ? 1 : -1 }
    C.StatusRow { label: "CPU topology"; value: root.unlock.physicalCores ? root.unlock.physicalCores + " cores / " + root.unlock.logicalThreads + " threads" : "Unavailable"; health: root.unlock.topologyState === "unlocked" ? 1 : 0 }
    C.StatusRow { label: "GPU governor"; value: root.gpu.dbusReady ? "D-Bus ready" : "Unavailable"; health: root.gpu.dbusReady ? 1 : -1 }
    C.StatusRow { label: "CPU governor"; value: root.power.cpuGovernor || "Unavailable"; health: root.power.cpuGovernor === "schedutil" ? 1 : 0 }
    C.StatusRow { label: "Frequency replay"; value: (root.power.frequencyRestore || {}).enabled || "Unknown" }

    C.SectionHeader { text: "Eight-core metrics compatibility" }
    C.StatusRow { objectName: "metricsCompatibility"; label: "Compatibility helper"; value: root.metrics.state || "Unavailable from installed service" }
    C.StatusRow { label: "Metrics service / revision"; value: ((root.metrics.service || {}).enabled || "Unknown") + " / " + ((root.metrics.service || {}).active || "Unknown") + " / " + (root.metrics.revision || "Unknown") }
    Text { visible: root.unlock.physicalCores === 8 || Boolean(root.metrics.message); text: root.metrics.message || "Eight-core mode can make six-core-only SMU consumers unavailable. Missing measurements are not estimated. Sampling never installs or injects a compatibility payload."; color: "#ffb06a"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
    C.SectionHeader { text: "All available hwmon sensors" }
    Repeater {
        model: root.sensors
        C.StatusRow {
            required property var modelData
            objectName: "hwmonSensor"
            label: (modelData.device || "hwmon") + " / " + (modelData.label || modelData.key || "sensor")
            value: typeof modelData.value === "number" && isFinite(modelData.value) ? modelData.value + " " + (modelData.unit || "") : "Unavailable"
        }
    }
    Text { visible: root.sensors.length === 0; text: "Additional hwmon metrics unavailable from the installed service or hardware."; color: "#7898a3"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }

    C.SectionHeader { text: "Control link" }
    C.StatusRow { label: "System service"; value: backend.mockMode ? "Mock / isolated" : backend.serviceAvailable ? "Online" : "Offline"; health: backend.serviceAvailable ? 1 : -1 }
    C.StatusRow { label: "Current operation"; value: backend.busy ? backend.busyLabel : "Idle"; health: backend.busy ? 0 : 1 }
    C.StatusRow { label: "Core unlock guard"; value: root.automaticRebootPending ? "AUTO REBOOT PENDING" : root.unlockGuard.state || "Unknown"; health: root.automaticRebootPending ? -1 : 0 }
    Text {
        visible: root.automaticRebootPending
        text: "Conflicting controls are blocked while the guarded reboot is pending."
        color: "#ff6aa2"; font.family: "monospace"; font.pixelSize: 10
        wrapMode: Text.Wrap; Layout.fillWidth: true
    }

    C.SectionHeader { text: "HDMI audio" }
    C.StatusRow { label: "Surround state"; value: root.audio.state || "Unavailable"; health: root.audio.active ? 1 : root.audio.state === "incomplete" ? -1 : 0 }
    C.StatusRow { label: "Active profile"; value: root.audio.activeProfile || "Unknown" }
    Switch {
        text: "DOLBY DIGITAL 5.1 OVER HDMI"
        checked: root.audio.enabled === true
        enabled: root.audio.controllable === true && !backend.busy
        onClicked: {
            var nextEnabled = checked
            checked = Qt.binding(function() { return root.audio.enabled === true })
            confirm.ask(nextEnabled ? "Enable HDMI surround?" : "Disable HDMI surround?",
                nextEnabled
                    ? "WirePlumber will restart and select real-time AC-3 5.1 output. An AC-3-capable receiver is required."
                    : "Managed HDMI surround files will be removed and the stereo profile restored.",
                false, function() { root.backend.setHdmiSurround(nextEnabled) })
        }
    }
    Text {
        visible: !root.audio.available || root.audio.state === "incomplete"
        text: !root.audio.available ? "Reinstall the frontend to add the trusted HDMI audio helper."
            : "Managed HDMI audio files are incomplete or foreign. Repair or revert them from the toolkit."
        color: "#ff6aa2"; font.family: "monospace"; font.pixelSize: 9
        wrapMode: Text.Wrap; Layout.fillWidth: true
    }
}
