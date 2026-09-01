import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var audio: backend.snapshot.audio || ({})
    readonly property bool controlsEnabled: audio.controllable && backend.snapshot.toolkit.privileged && !backend.busy
    spacing: Kirigami.Units.largeSpacing

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "HDMI Audio"
        Components.StatusRow { label: "Surround state"; value: root.audio.state || "Unavailable"; health: root.audio.active ? 1 : root.audio.state === "incomplete" ? -1 : 0 }
        Components.StatusRow { label: "Active profile"; value: root.audio.activeProfile || "Unknown" }
        Components.StatusRow { label: "Udev rule"; value: root.audio.udevState || "Unknown"; health: root.audio.udevState === "foreign" ? -1 : 0 }
        Components.StatusRow { label: "WirePlumber configuration"; value: root.audio.wireplumberState || "Unknown"; health: root.audio.wireplumberState === "foreign" ? -1 : 0 }
        Components.StatusRow { label: "Update persistence"; value: root.audio.persistenceState || "Unknown"; health: root.audio.persistenceState === "foreign" ? -1 : 0 }
        QQC2.Switch {
            text: "Dolby Digital 5.1 over HDMI"
            checked: root.audio.enabled === true
            enabled: root.controlsEnabled
            onClicked: {
                var nextEnabled = checked;
                checked = Qt.binding(function() { return root.audio.enabled === true; });
                confirmation.ask(nextEnabled ? "Enable HDMI surround?" : "Disable HDMI surround?",
                    nextEnabled
                        ? "WirePlumber will restart and select real-time AC-3 5.1 output. An AC-3-capable receiver is required."
                        : "Managed HDMI surround files will be removed and the stereo profile restored.",
                    false, function() { root.backend.setHdmiSurround(nextEnabled); });
            }
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: !root.audio.available || root.audio.state === "incomplete"
            type: Kirigami.MessageType.Warning
            text: !root.audio.available ? "Reinstall the frontend to add the trusted HDMI audio helper."
                : "Managed HDMI audio files are incomplete or foreign. Repair or revert them from the toolkit."
        }
    }
}
