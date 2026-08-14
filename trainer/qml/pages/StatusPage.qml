import QtQuick 2.15
import QtQuick.Layouts 1.15
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

    GridLayout {
        columns: 4
        columnSpacing: 6; rowSpacing: 6
        Layout.fillWidth: true
        C.MetricTile { label: "GPU CLK"; value: (root.telemetry.gpuClock ?? root.gpu.activeMhz ?? "--") + " MHz"; Layout.fillWidth: true }
        C.MetricTile { label: "CPU CLK"; value: (root.telemetry.cpuClock ?? root.power.cpuCurrentMhz ?? "--") + " MHz"; accent: "#ef48bb"; Layout.fillWidth: true }
        C.MetricTile { label: "GPU TEMP"; value: (root.telemetry.gpuTemp ?? "--") + " C"; accent: "#ff9a55"; Layout.fillWidth: true }
        C.MetricTile { label: "CPU TEMP"; value: (root.telemetry.cpuTemp ?? "--") + " C"; accent: "#49ff9a"; Layout.fillWidth: true }
    }

    C.SectionHeader { text: "Silicon status" }
    C.StatusRow { label: "Compute units"; value: root.cu.available ? root.cu.total + "/" + root.cu.maximum + " CU" : "Unavailable"; health: root.cu.available ? 1 : -1 }
    C.StatusRow { label: "CPU topology"; value: root.unlock.physicalCores ? root.unlock.physicalCores + " cores / " + root.unlock.logicalThreads + " threads" : "Unavailable"; health: root.unlock.topologyState === "unlocked" ? 1 : 0 }
    C.StatusRow { label: "GPU governor"; value: root.gpu.dbusReady ? "D-Bus ready" : "Unavailable"; health: root.gpu.dbusReady ? 1 : -1 }
    C.StatusRow { label: "CPU governor"; value: root.power.cpuGovernor || "Unavailable"; health: root.power.cpuGovernor === "schedutil" ? 1 : 0 }
    C.StatusRow { label: "Frequency replay"; value: (root.power.frequencyRestore || {}).enabled || "Unknown" }

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
}
