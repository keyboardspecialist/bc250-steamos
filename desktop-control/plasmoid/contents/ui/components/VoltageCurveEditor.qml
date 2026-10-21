import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../Utils.js" as Utils

ColumnLayout {
    id: root
    required property var backend
    readonly property var gpu: backend.snapshot.gpu
    readonly property var points: gpu.safePoints || []
    readonly property bool apiAvailable: (backend.snapshot.toolkit.controlCapabilities || []).indexOf("gpu-voltage-curve") >= 0
    readonly property bool controllable: apiAvailable && gpu.controllable && backend.snapshot.toolkit.privileged && !backend.busy
    readonly property string action: ["set", "add", "edit", "remove", "offset", "reset"][actionBox.currentIndex]
    readonly property var selected: points[pointBox.currentIndex] || ({ frequency: 0, voltage: 700 })
    property int frequency: 1000
    property int voltage: selected.voltage
    property int offset: 0
    readonly property int sourceFrequency: action === "add" ? frequency : selected.frequency
    readonly property var preview: {
        try {
            return Utils.voltageChange(points, action, sourceFrequency,
                action === "offset" ? offset : voltage, action === "edit" ? frequency : 0, gpu);
        } catch (error) {
            return { error: String(error.message || error), points: [] };
        }
    }
    spacing: Kirigami.Units.smallSpacing

    onSelectedChanged: { voltage = selected.voltage; frequency = selected.frequency || 1000; }

    ConfirmationDialog { id: confirmation }
    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: !root.apiAvailable
        type: Kirigami.MessageType.Warning
        text: "The installed service does not advertise voltage-curve control. Update the frontend/service installation; existing read-only curve values remain available."
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: true
        type: Kirigami.MessageType.Warning
        text: "Voltage changes can cause artifacts, crashes, or data loss. Keep voltages nondecreasing and within 700–1050 mV; frequencies must be unique within 350–2230 MHz. Changes are persistent. Close games first. The service validates and applies one atomic CLI transaction with rollback."
    }
    Repeater {
        model: root.points
        StatusRow {
            required property var modelData
            label: modelData.frequency + " MHz"
            value: Utils.valueOrDash(modelData.voltage, " mV")
        }
    }
    QQC2.Label { text: "Curve action" }
    QQC2.ComboBox {
        id: actionBox
        Layout.fillWidth: true
        model: ["Set point voltage", "Add point", "Edit point frequency and voltage", "Remove point", "Offset whole curve", "Reset community curve"]
        enabled: root.controllable
    }
    QQC2.Label { text: "Existing frequency"; visible: ["set", "edit", "remove"].indexOf(root.action) >= 0 }
    QQC2.ComboBox {
        id: pointBox
        Layout.fillWidth: true
        visible: ["set", "edit", "remove"].indexOf(root.action) >= 0
        model: root.points
        textRole: "frequency"
        enabled: root.controllable && count > 0
    }
    QQC2.Label { text: "New frequency (MHz)"; visible: root.action === "add" || root.action === "edit" }
    QQC2.SpinBox {
        Layout.fillWidth: true
        visible: root.action === "add" || root.action === "edit"
        from: 350; to: 2230; stepSize: 10; editable: true; value: root.frequency
        enabled: root.controllable
        onValueModified: root.frequency = value
    }
    QQC2.Label { text: "Voltage (mV)"; visible: ["set", "add", "edit"].indexOf(root.action) >= 0 }
    QQC2.SpinBox {
        Layout.fillWidth: true
        visible: ["set", "add", "edit"].indexOf(root.action) >= 0
        from: 700; to: 1050; stepSize: 5; editable: true; value: root.voltage
        enabled: root.controllable
        onValueModified: root.voltage = value
    }
    QQC2.Label { text: "Signed voltage offset (mV)"; visible: root.action === "offset" }
    QQC2.SpinBox {
        Layout.fillWidth: true
        visible: root.action === "offset"
        from: -350; to: 350; stepSize: 5; editable: true; value: root.offset
        enabled: root.controllable
        onValueModified: root.offset = value
    }
    QQC2.Label {
        Layout.fillWidth: true
        text: root.preview.error || "Preview: " + root.preview.points.map(function(point) {
            return point.frequency + " MHz @ " + point.voltage + " mV";
        }).join(" · ")
        wrapMode: Text.Wrap
        color: root.preview.error ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.disabledTextColor
    }
    ActionButton {
        text: "Apply curve change"
        enabled: root.controllable && !root.preview.error
        disabledReason: root.preview.error || (root.backend.busy ? root.backend.busyLabel : "A privileged service and GPU governor are required.")
        onClicked: {
            // Capture the confirmed arguments, not mutable editor state.
            var args = root.preview.args.slice(0);
            confirmation.ask("Apply persistent GPU voltage change?",
                "An unstable curve may crash the system or corrupt unsaved work. The governor may restart. Test stability before relying on these settings.",
                true, function() { root.backend.gpuVoltageAction(args[0], args[1], args[2], args[3]); });
        }
    }
}
