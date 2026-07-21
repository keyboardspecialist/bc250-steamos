import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "../components" as Components
import "../Utils.js" as Utils

ColumnLayout {
    id: root
    required property var backend
    readonly property var snapshot: backend.snapshot
    spacing: Kirigami.Units.largeSpacing

    function samples(key) {
        var result = [];
        for (var index = 0; index < backend.telemetryHistory.length; ++index)
            result.push(backend.telemetryHistory[index][key]);
        return result;
    }

    GridLayout {
        columns: root.width >= 660 ? 4 : root.width >= 440 ? 2 : 1
        columnSpacing: Kirigami.Units.smallSpacing
        rowSpacing: Kirigami.Units.smallSpacing
        Layout.fillWidth: true

        Components.MetricCard {
            title: "CPU clock"
            value: Utils.valueOrDash(root.snapshot.power.cpuCurrentMhz, " MHz")
            samples: root.samples("cpuClock")
            accent: "#4f9de8"
            Layout.fillWidth: true
        }
        Components.MetricCard {
            title: "GPU clock"
            value: Utils.valueOrDash(root.snapshot.gpu.activeMhz, " MHz")
            samples: root.samples("gpuClock")
            accent: "#9b7de5"
            Layout.fillWidth: true
        }
        Components.MetricCard {
            title: "CPU temperature"
            value: root.samples("cpuTemp").length ? Utils.valueOrDash(root.samples("cpuTemp").slice(-1)[0], " °C") : "Collecting"
            samples: root.samples("cpuTemp")
            floor: 20
            accent: "#3fbd86"
            Layout.fillWidth: true
        }
        Components.MetricCard {
            title: "GPU temperature"
            value: backend.latestGpuTemperature() === null ? "Collecting" : Math.round(backend.latestGpuTemperature()) + " °C"
            samples: root.samples("gpuTemp")
            floor: 20
            accent: "#e99145"
            Layout.fillWidth: true
        }
    }

    Components.Section {
        title: "System Overview"
        Components.StatusRow {
            label: "Compute units"
            value: root.snapshot.cu.available ? root.snapshot.cu.total + "/" + root.snapshot.cu.maximum : "Unavailable"
            health: root.snapshot.cu.available ? 1 : -1
        }
        Components.StatusRow {
            label: "CPU OC profile"
            value: root.snapshot.cpu.service.enabled === "enabled" ? "Enabled at boot"
                : (root.snapshot.cpu.installed || root.snapshot.cpu.staged) ? "Available, not enabled" : "Not configured"
            health: root.snapshot.cpu.service.enabled === "enabled" ? 1 : -1
        }
        Components.StatusRow {
            label: "GPU governor"
            value: root.snapshot.gpu.dbusReady ? "Active · D-Bus ready"
                : root.snapshot.power.governor.active === "active" ? "Active · D-Bus unavailable"
                : root.snapshot.power.governor.active
            health: root.snapshot.gpu.dbusReady ? 1 : -1
        }
        Components.StatusRow {
            label: "CEC"
            value: root.snapshot.cec.devicePresent ? root.snapshot.cec.service.active : "Not connected"
            health: root.snapshot.cec.devicePresent && root.snapshot.cec.service.active === "active" ? 1 : -1
        }
    }

    Components.Section {
        title: "Power Health"
        Components.StatusRow {
            label: "ACPI C/P-states"
            value: root.snapshot.power.acpiActive ? "Active" : "Reboot or setup needed"
            health: root.snapshot.power.acpiActive ? 1 : -1
        }
        Components.StatusRow {
            label: "CPU governor"
            value: root.snapshot.power.cpuGovernor || "Unavailable"
            health: root.snapshot.power.cpuGovernor === "schedutil" ? 1 : -1
        }
        Components.StatusRow {
            label: "Idle states"
            value: root.snapshot.power.cStates + " states"
            health: root.snapshot.power.cStates >= 3 ? 1 : -1
        }
        Components.StatusRow {
            label: "Adaptive GPU governor"
            value: root.snapshot.power.governor.enabled
            health: root.snapshot.power.governor.enabled === "enabled" ? 1 : -1
        }
        Components.StatusRow {
            label: "Frequency replay"
            value: root.snapshot.power.frequencyRestore.enabled
            health: root.snapshot.power.frequencyRestore.enabled === "enabled" ? 1 : -1
        }
    }

    Components.Section {
        title: "Services"
        Components.StatusRow { label: "ACPI"; value: root.snapshot.power.acpiService.enabled + " / " + root.snapshot.power.acpiService.active }
        Components.StatusRow { label: "CPU frequency"; value: root.snapshot.power.cpufreqService.enabled + " / " + root.snapshot.power.cpufreqService.active }
        Components.StatusRow { label: "CU replay"; value: root.snapshot.cu.service.enabled + " / " + root.snapshot.cu.service.active }
        Components.StatusRow { label: "CPU tuning"; value: root.snapshot.cpu.service.enabled + " / " + root.snapshot.cpu.service.active }
    }
}
