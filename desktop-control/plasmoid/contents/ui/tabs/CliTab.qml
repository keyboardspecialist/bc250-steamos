import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var catalog: backend.cliCatalog || ({ sections: [] })
    readonly property bool available: catalog.schemaVersion === 1 && catalog.available === true
    spacing: Kirigami.Units.largeSpacing

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "Expert and Maintenance CLI Workflows"
        Components.StatusRow {
            label: "CLI checkout version"
            value: root.catalog.toolkitVersion || "Unknown / legacy checkout"
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "Checkout capabilities are separate from this applet's version and the installed service. Refresh the frontend installation after updating shared service code."
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "These workflows open the real toolkit in a desktop terminal as your logged-in user, not inside Plasma. Interactive prompts and any sudo authorization stay in that terminal. A successful launch does not mean the workflow has finished."
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: !root.available
            type: Kirigami.MessageType.Warning
            text: root.catalog.reason || "Loading terminal and toolkit availability. Refresh if the service is unavailable."
        }
        Components.ActionButton {
            text: "Refresh terminal workflows"
            enabled: !root.backend.busy
            disabledReason: root.backend.busyLabel
            onClicked: root.backend.refreshCliCatalog()
        }
    }

    Repeater {
        model: root.catalog.sections || []
        Components.Section {
            id: section
            required property var modelData
            title: String(modelData.title)
            QQC2.Label {
                Layout.fillWidth: true
                text: String(section.modelData.description || "")
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
            }
            QQC2.Label {
                text: "Risk: " + String(section.modelData.risk || "unknown")
                textFormat: Text.PlainText
                color: section.modelData.risk === "read-only"
                    ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.neutralTextColor
            }
            Components.ActionButton {
                text: "Open in terminal"
                enabled: root.available && !root.backend.busy
                disabledReason: root.backend.busy ? root.backend.busyLabel
                    : root.catalog.reason || "A desktop terminal and a trusted toolkit are required."
                onClicked: {
                    var sectionId = String(section.modelData.id);
                    if (section.modelData.risk === "read-only") {
                        root.backend.openCliSection(sectionId);
                    } else {
                        confirmation.ask("Open " + String(section.modelData.title) + "?",
                            "This terminal menu may change hardware, boot configuration, storage, installed software, or remove toolkit components. Read each prompt carefully. Changes happen outside Plasma and are not cancelled by closing this window.",
                            true, function() { root.backend.openCliSection(sectionId); });
                    }
                }
            }
        }
    }
}
