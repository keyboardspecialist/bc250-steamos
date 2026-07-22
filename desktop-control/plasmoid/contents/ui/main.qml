import QtQuick
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import "components" as Components

PlasmoidItem {
    id: root

    switchWidth: 720
    switchHeight: 520
    Plasmoid.icon: Qt.resolvedUrl("../icons/bc250-control.svg")
    Plasmoid.status: backendController.healthState === "error" || backendController.healthState === "warning"
        ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    toolTipMainText: "BC-250 Control"
    toolTipSubText: backendController.healthSummary

    Backend { id: backendController }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Open Full Controls"
            icon.name: "window-duplicate"
            onTriggered: backendController.openFullControls()
        },
        PlasmaCore.Action {
            text: "Refresh Hardware Status"
            icon.name: "view-refresh"
            enabled: !backendController.busy
            onTriggered: backendController.refresh()
        }
    ]

    compactRepresentation: Components.HealthIcon {
        backend: backendController
        onActivated: root.expanded = !root.expanded
    }

    fullRepresentation: ControlView {
        backend: backendController
        active: root.expanded
    }
}
