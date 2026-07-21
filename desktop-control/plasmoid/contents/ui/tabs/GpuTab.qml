import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var snapshot: backend.snapshot
    readonly property var gpu: snapshot.gpu
    property string mode: gpu.mode
    property int minimum: gpu.minimum || 0
    property int maximum: gpu.maximum || gpu.configuredMax || 1500
    property int loadMinimum: Math.round((gpu.loadLower === null ? 0.65 : gpu.loadLower) * 100)
    property int loadMaximum: Math.round((gpu.loadUpper === null ? 0.80 : gpu.loadUpper) * 100)
    property int rampMs: gpu.climbMs || 500
    readonly property bool controllable: gpu.controllable && !backend.busy
    readonly property string disabledReason: backend.busy ? backend.busyLabel
        : !gpu.available ? "Install the GPU governor with bc250-power.sh governor."
        : !snapshot.toolkit.privileged ? "The system service is not privileged."
        : !gpu.dbusReady ? "Start the GPU governor; its D-Bus interface is unavailable."
        : "GPU controls are unavailable."
    spacing: Kirigami.Units.largeSpacing

    function syncFromSnapshot() {
        mode = gpu.mode;
        minimum = gpu.minimum || 0;
        maximum = gpu.maximum || gpu.configuredMax || 1500;
        loadMinimum = Math.round((gpu.loadLower === null ? 0.65 : gpu.loadLower) * 100);
        loadMaximum = Math.round((gpu.loadUpper === null ? 0.80 : gpu.loadUpper) * 100);
        rampMs = gpu.climbMs || 500;
    }

    onGpuChanged: if (!backend.busy) syncFromSnapshot()

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "Live GPU"
        Components.StatusRow { label: "Active clock"; value: gpu.activeMhz === null ? "Unavailable" : gpu.activeMhz + " MHz" }
        Components.StatusRow {
            label: "Governor service"
            value: gpu.governorService.enabled + " / " + gpu.governorService.active
            health: gpu.governorService.enabled === "enabled" && gpu.governorService.active === "active" ? 1 : -1
        }
        Components.StatusRow { label: "Live mode"; value: gpu.mode; health: gpu.dbusReady ? 1 : -1 }
        Components.StatusRow {
            label: "Saved replay"
            value: gpu.requestedMode === "range" ? gpu.requestedMinimum + "-" + gpu.requestedMaximum + " MHz"
                : gpu.requestedMode === "pin" ? gpu.requestedMaximum + " MHz pinned" : gpu.requestedMode
        }
        Components.StatusRow {
            label: "Live range"
            value: gpu.liveMinimum === null || gpu.liveMaximum === null ? "D-Bus unavailable"
                : gpu.liveMinimum + "-" + gpu.liveMaximum + " MHz"
            health: gpu.dbusReady ? 1 : -1
        }
        Components.StatusRow {
            label: "Boot replay"
            value: !gpu.persistent ? "Pending setup" : gpu.replayApplied ? "Applied" : "Enabled, not live"
            health: gpu.persistent && gpu.replayApplied ? 1 : -1
        }
        Components.StatusRow { label: "Adaptive ceiling"; value: gpu.configuredMax ? gpu.configuredMax + " MHz" : "Curve maximum" }
        Components.StatusRow { label: "Loaded ceiling"; value: gpu.initialMaximum ? gpu.initialMaximum + " MHz" : "Unavailable" }
    }

    Components.Section {
        title: "Frequency"
        QQC2.ComboBox {
            id: modeBox
            Layout.fillWidth: true
            model: ["Adaptive", "Custom range / overclock", "Pinned frequency", "Maximum curve point"]
            currentIndex: ["adaptive", "range", "pin", "max"].indexOf(root.mode)
            enabled: root.controllable
            onActivated: root.mode = ["adaptive", "range", "pin", "max"][currentIndex]
        }
        QQC2.Label { text: "Minimum clock"; visible: root.mode === "adaptive" || root.mode === "range" }
        QQC2.SpinBox {
            from: 0; to: Math.min(root.gpu.allowedMaximum || 2150, 2150); stepSize: 50
            value: root.minimum; editable: true; enabled: root.controllable
            visible: root.mode === "adaptive" || root.mode === "range"
            Layout.fillWidth: true
            textFromValue: (value) => value + " MHz"
            valueFromText: (text) => parseInt(text)
            onValueModified: { root.minimum = value; root.mode = "range"; }
        }
        QQC2.Label { text: root.mode === "pin" ? "Pinned clock" : "Maximum clock"; visible: root.mode !== "max" }
        QQC2.SpinBox {
            from: Math.max(root.gpu.allowedMinimum || 100, 100); to: Math.min(root.gpu.allowedMaximum || 2150, 2150); stepSize: 50
            value: root.maximum; editable: true; enabled: root.controllable
            visible: root.mode !== "max"; Layout.fillWidth: true
            textFromValue: (value) => value + " MHz"
            valueFromText: (text) => parseInt(text)
            onValueModified: { root.maximum = value; if (root.mode === "adaptive") root.mode = "range"; }
        }
        Components.ActionButton {
            text: "Apply frequency mode"
            enabled: root.controllable
            disabledReason: root.disabledReason
            onClicked: {
                var apply = function() { root.backend.setGpuFrequency(root.mode, root.minimum, root.maximum); };
                if (root.mode === "pin" || root.mode === "max")
                    confirmation.ask("Apply sustained GPU clocks?",
                        "Pinned or maximum clocks increase heat and power. Thermal throttling remains active.", false, apply);
                else
                    apply();
            }
        }
    }

    Components.Section {
        title: "Load Response"
        Components.StatusRow {
            label: "Current target"
            value: gpu.loadUpper === null || gpu.loadLower === null ? "Unavailable"
                : Math.round(gpu.loadUpper * 100) + " / " + Math.round(gpu.loadLower * 100) + "%"
        }
        RowLayout {
            Layout.fillWidth: true
            Components.ActionButton {
                text: "Eager preset"; description: "40/10%"; enabled: root.controllable
                disabledReason: root.disabledReason; Layout.fillWidth: true
                onClicked: root.backend.setLoadTarget("eager")
            }
            Components.ActionButton {
                text: "Balanced preset"; description: "80/65%"; enabled: root.controllable
                disabledReason: root.disabledReason; Layout.fillWidth: true
                onClicked: root.backend.setLoadTarget("reset")
            }
        }
        QQC2.Label { text: "Clock down below " + root.loadMinimum + "% load" }
        QQC2.Slider {
            from: 1; to: 99; stepSize: 1; value: root.loadMinimum; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.loadMinimum = Math.round(value)
        }
        QQC2.Label { text: "Clock up above " + root.loadMaximum + "% load" }
        QQC2.Slider {
            from: 1; to: 99; stepSize: 1; value: root.loadMaximum; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.loadMaximum = Math.round(value)
        }
        Components.ActionButton {
            text: "Apply custom load target"
            enabled: root.controllable && root.loadMinimum < root.loadMaximum
            disabledReason: root.loadMinimum >= root.loadMaximum
                ? "Minimum load must be lower than maximum load." : root.disabledReason
            onClicked: root.backend.setCustomLoadTarget(root.loadMinimum, root.loadMaximum)
        }
    }

    Components.Section {
        title: "Ramp"
        QQC2.Label { text: "Idle-to-max climb: " + root.rampMs + " ms" }
        QQC2.Slider {
            from: 200; to: 5000; stepSize: 100; value: root.rampMs; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.rampMs = Math.round(value / 100) * 100
        }
        Components.ActionButton {
            text: "Apply ramp time"; enabled: root.controllable; disabledReason: root.disabledReason
            onClicked: root.backend.setRamp(root.rampMs)
        }
    }

    Components.Section {
        title: "Voltage Curve"
        visible: root.gpu.safePoints.length > 0
        Repeater {
            model: root.gpu.safePoints
            Components.StatusRow {
                required property var modelData
                required property int index
                label: modelData.frequency ? modelData.frequency + " MHz" : "Point " + (index + 1)
                value: modelData.voltage ? modelData.voltage + " mV" : "Unavailable"
            }
        }
    }
}
