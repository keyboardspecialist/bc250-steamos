import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    spacing: 9
    readonly property var snap: backend.snapshot || ({})
    readonly property var toolkit: snap.toolkit || ({})
    readonly property var unlock: backend.cpuUnlockStatus || ({})

    C.SectionHeader { text: "Soundtrack" }
    RowLayout {
        Layout.fillWidth: true
        C.NeonButton { text: backend.muted ? "UNMUTE" : "MUTE"; accent: backend.muted ? "#ff6aa2" : "#22e7f2"; onClicked: backend.muted = !backend.muted }
        Slider { from: 0; to: 1; value: backend.volume; enabled: !backend.muted; Layout.fillWidth: true; onMoved: backend.volume = value }
        Text { text: Math.round(backend.volume * 100) + "%"; color: "#d7e7ee"; font.family: "monospace"; font.pixelSize: 10; Layout.preferredWidth: 36 }
    }
    Text { text: "Volume and mute are stored in per-user QSettings."; color: "#718896"; font.family: "monospace"; font.pixelSize: 9 }

    C.SectionHeader { text: "Service diagnostics" }
    C.StatusRow { label: "Connection"; value: backend.serviceAvailable ? "Available" : "Unavailable"; health: backend.serviceAvailable ? 1 : -1 }
    C.StatusRow { label: "Application mode"; value: backend.mockMode ? "Mock / no writes" : "System D-Bus client"; health: backend.mockMode ? 0 : 1 }
    C.StatusRow { label: "Service schema/version"; value: root.snap.schemaVersion || root.toolkit.version || "Not reported" }
    C.StatusRow { label: "Toolkit path"; value: root.toolkit.path || "Unavailable"; health: root.toolkit.available ? 1 : -1 }
    C.StatusRow { label: "Privileged boundary"; value: root.toolkit.privileged ? "Ready" : "Unavailable"; health: root.toolkit.privileged ? 1 : -1 }
    C.StatusRow { label: "CPU controls"; value: root.toolkit.cpuControlAvailable ? "Ready" : "Unavailable"; health: root.toolkit.cpuControlAvailable ? 1 : -1 }
    C.StatusRow { label: "CPU-unlock API"; value: root.unlock.schemaVersion === 1 ? "Ready" : "Unavailable"; health: root.unlock.schemaVersion === 1 ? 1 : -1 }
    C.StatusRow { label: "Update persistence"; value: root.unlock.updatePersistence ? "Protected" : "Unknown / pending"; health: root.unlock.updatePersistence ? 1 : 0 }

    RowLayout {
        Layout.fillWidth: true
        C.NeonButton { text: "REFRESH ALL [R]"; enabled: !backend.busy; Layout.fillWidth: true; onClicked: backend.refresh() }
        C.NeonButton { text: "CLEAR MESSAGE"; Layout.fillWidth: true; onClicked: backend.clearMessage() }
    }

    C.SectionHeader { text: "Advanced-control warning" }
    Rectangle {
        color: "#321327b8"; border.color: "#ef48bb"; radius: 2
        Layout.fillWidth: true; implicitHeight: warning.implicitHeight + 18
        Text {
            id: warning
            anchors.fill: parent; anchors.margins: 9
            text: "These controls alter live silicon routing and clock policy. Harvested units may be defective; overclock detection may crash the system. The application is unprivileged and never invokes scripts, sudo, busctl, or subprocesses. The root service and toolkit checks remain authoritative."
            color: "#ffc1df"; font.family: "monospace"; font.pixelSize: 9
            wrapMode: Text.Wrap
        }
    }
}
