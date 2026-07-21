import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import "components" as Components

PlasmoidItem {
    id: root

    switchWidth: 720
    switchHeight: 520
    Plasmoid.icon: Qt.resolvedUrl("../icons/bc250-control.svg")
    Plasmoid.status: backend.healthState === "error" || backend.healthState === "warning"
        ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    toolTipMainText: "BC-250 Control"
    toolTipSubText: backend.healthSummary

    Backend { id: backend }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Open Full Controls"
            icon.name: "window-duplicate"
            onTriggered: backend.openFullControls()
        },
        PlasmaCore.Action {
            text: "Refresh Hardware Status"
            icon.name: "view-refresh"
            enabled: !backend.busy
            onTriggered: backend.refresh()
        }
    ]

    compactRepresentation: Components.HealthIcon {
        backend: backend
        onActivated: root.expanded = !root.expanded
    }

    fullRepresentation: ControlView {
        backend: backend
        active: root.expanded
    }
}
