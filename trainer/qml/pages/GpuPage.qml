import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    spacing: 8
    readonly property var snap: backend.snapshot || ({})
    readonly property var gpu: snap.gpu || ({})
    readonly property var mesh: backend.meshStatus || ({})
    readonly property bool enabledControls: Boolean(gpu.controllable) && !backend.busy
    property string mode: gpu.mode || "adaptive"
    property int minimum: gpu.minimum ?? 300
    property int maximum: gpu.maximum ?? 1500
    property int loadMinimum: Math.round((gpu.loadLower ?? 0.65) * 100)
    property int loadMaximum: Math.round((gpu.loadUpper ?? 0.80) * 100)
    property int temperatureTarget: gpu.temperatureTarget ?? 85
    property int ramp: gpu.climbMs ?? 500
    readonly property bool frequencyValid: root.mode !== "range"
        || ((root.minimum === 0 || root.minimum >= 300) && root.minimum <= root.maximum)

    C.ConfirmDialog { id: confirm }
    C.SectionHeader { text: "Mesa / RADV and compute queues" }
    C.StatusRow { label: "Patched AMDGPU"; value: root.mesh.kernelReady ? "Installed and active" : "Not ready"; health: root.mesh.kernelReady ? 1 : -1 }
    C.StatusRow { label: "Scheduler policy"; value: root.mesh.schedulerActive ? "Active" : root.mesh.schedulerConfigured ? "Reboot required" : "Disabled"; health: root.mesh.schedulerActive ? 1 : root.mesh.schedulerConfigured ? 0 : -1 }
    C.StatusRow { label: "RADV runtime"; value: root.mesh.runtimeState || "Unavailable"; health: root.mesh.runtimeState === "ready" ? 1 : -1 }
    C.StatusRow { label: "Global activation"; value: root.mesh.globalEnabled ? "Enabled" : "Disabled"; health: root.mesh.globalEnabled ? 1 : 0 }
    C.StatusRow { label: "Private FSR4 profile"; value: root.mesh.fsr4State || "Unavailable"; health: root.mesh.fsr4State === "ready" ? 1 : root.mesh.fsr4State === "invalid" ? -1 : 0 }
    Text { visible: Boolean(root.mesh.error) || root.mesh.runtimeState === "invalid" || root.mesh.fsr4State === "invalid"; text: root.mesh.error || "A Mesa / RADV runtime failed integrity validation. Repair it from the toolkit."; color: "#ff6aa2"; font.family: "monospace"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
    C.SectionHeader { text: "Frequency control" }
    C.StatusRow { label: "Live / saved mode"; value: (root.gpu.mode || "--") + " / " + (root.gpu.requestedMode || "--"); health: root.gpu.dbusReady ? 1 : -1 }
    C.StatusRow { label: "Live range"; value: (root.gpu.liveMinimum ?? "--") + " - " + (root.gpu.liveMaximum ?? "--") + " MHz" }

    C.NeonComboBox {
        id: modeBox
        Layout.fillWidth: true
        enabled: root.enabledControls
        model: ["Adaptive", "Custom range", "Pinned frequency", "Maximum curve point"]
        currentIndex: Math.max(0, ["adaptive", "range", "pin", "max"].indexOf(root.mode))
        onActivated: root.mode = ["adaptive", "range", "pin", "max"][currentIndex]
    }
    RowLayout {
        Layout.fillWidth: true
        C.NeonSpinBox {
            from: 0; to: 2230; stepSize: 50; value: root.minimum; editable: true
            enabled: root.enabledControls && (root.mode === "adaptive" || root.mode === "range")
            Layout.fillWidth: true; onValueModified: root.minimum = value
            textFromValue: function(value) { return "MIN " + value + " MHz" }
            valueFromText: function(text) { return parseInt(text) || 0 }
        }
        C.NeonSpinBox {
            from: 300; to: 2230; stepSize: 50; value: root.maximum; editable: true
            enabled: root.enabledControls && root.mode !== "max"
            Layout.fillWidth: true; onValueModified: root.maximum = value
            textFromValue: function(value) { return "MAX " + value + " MHz" }
            valueFromText: function(text) { return parseInt(text) || 300 }
        }
        C.NeonButton {
            text: "APPLY"; enabled: root.enabledControls && root.frequencyValid
            onClicked: {
                var run = function() { root.backend.setGpuFrequency(root.mode, root.minimum, root.maximum) }
                if (root.mode === "pin" || root.mode === "max")
                    confirm.ask("Apply sustained GPU clocks?", "Pinned or maximum clocks increase heat and power. Thermal throttling remains active, but instability or data loss is possible.", true, run)
                else run()
            }
        }
    }

    C.SectionHeader { text: "Load response" }
    RowLayout {
        Layout.fillWidth: true
        C.NeonButton { text: "EAGER 40/10"; enabled: root.enabledControls; Layout.fillWidth: true; onClicked: root.backend.setLoadTarget("eager") }
        C.NeonButton { text: "BALANCED 80/65"; enabled: root.enabledControls; Layout.fillWidth: true; onClicked: root.backend.setLoadTarget("reset") }
    }
    Text { text: "CUSTOM: down < " + root.loadMinimum + "%   up > " + root.loadMaximum + "%"; color: "#b7cbd4"; font.family: "monospace"; font.pixelSize: 9 }
    RowLayout {
        Layout.fillWidth: true
        Slider { from: 1; to: 98; stepSize: 1; value: root.loadMinimum; enabled: root.enabledControls; Layout.fillWidth: true; onMoved: root.loadMinimum = Math.round(value) }
        Slider { from: 2; to: 99; stepSize: 1; value: root.loadMaximum; enabled: root.enabledControls; Layout.fillWidth: true; onMoved: root.loadMaximum = Math.round(value) }
        C.NeonButton { text: "SET"; enabled: root.enabledControls && root.loadMinimum < root.loadMaximum; onClicked: root.backend.setCustomLoadTarget(root.loadMinimum, root.loadMaximum) }
    }

    C.SectionHeader { text: "Thermal target" }
    RowLayout {
        Layout.fillWidth: true
        Text { text: root.temperatureTarget + " C / recover " + (root.temperatureTarget - 10) + " C"; color: "#22e7f2"; font.family: "monospace"; font.pixelSize: 10 }
        Slider { from: 50; to: 100; stepSize: 1; value: root.temperatureTarget; enabled: root.enabledControls; Layout.fillWidth: true; onMoved: root.temperatureTarget = Math.round(value) }
        C.NeonButton { text: "SET TEMP"; enabled: root.enabledControls; onClicked: root.backend.setTemperatureTarget(root.temperatureTarget) }
    }

    C.SectionHeader { text: "Ramp and voltage curve" }
    RowLayout {
        Layout.fillWidth: true
        Text { text: root.ramp + " ms"; color: "#22e7f2"; font.family: "monospace"; font.pixelSize: 10 }
        Slider { from: 200; to: 5000; stepSize: 100; value: root.ramp; enabled: root.enabledControls; Layout.fillWidth: true; onMoved: root.ramp = Math.round(value / 100) * 100 }
        C.NeonButton { text: "SET RAMP"; enabled: root.enabledControls; onClicked: root.backend.setRamp(root.ramp) }
    }
    Repeater {
        model: root.gpu.safePoints || []
        C.StatusRow { required property var modelData; label: "Curve point"; value: modelData.frequency + " MHz @ " + modelData.voltage + " mV" }
    }
    Text { text: "Voltage points are read-only. The service does not expose voltage mutation."; color: "#718896"; font.family: "monospace"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
}
