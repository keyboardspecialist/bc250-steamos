import QtQuick 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    property bool blocked: false
    readonly property var catalog: backend.cliCatalog || ({})
    spacing: 6
    C.ConfirmDialog { id: confirm }
    C.SectionHeader { text: "Complete toolkit CLI / native terminal handoff" }
    C.StatusRow { label: "CLI checkout version"; value: root.catalog.toolkitVersion || "Unknown / legacy checkout" }
    Text { text: "Checkout capabilities are separate from Trainer's compiled version and the installed service. Updating source does not update this binary."; color: "#7898a3"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
    Text {
        text: root.catalog.available === true
            ? "Complex maintenance opens a fixed toolkit section in your host-user terminal, never a root shell. The CLI owns further prompts and authorization. No arbitrary commands, paths, or arguments are accepted."
            : root.catalog.reason || "CLI handoff unavailable. Update the host service. Flatpak does not provide host-terminal access."
        color: "#ffb06a"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true
    }
    Repeater {
        model: root.catalog.sections || []
        ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            C.NeonButton {
                text: "OPEN " + modelData.title; enabled: root.catalog.available === true && !root.backend.busy && !root.blocked
                onClicked: {
                    var section = modelData.id; var risk = modelData.risk
                    confirm.ask("Open host-user toolkit terminal?", modelData.description + "\n\nThe terminal may remain open after this handoff completes. Do not run conflicting hardware or maintenance operations concurrently.", risk !== "read-only", function() { root.backend.openCliSection(section) })
                }
            }
            Text { text: modelData.description + " [" + modelData.risk + "]"; color: "#7898a3"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
        }
    }
}
