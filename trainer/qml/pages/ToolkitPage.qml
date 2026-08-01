import QtQuick 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    required property var controller
    property string category: "SYSTEM"
    spacing: 8
    readonly property bool inventoryReady: controller.inventory.schemaVersion === 1
        && Array.isArray(controller.inventory.components)
    readonly property bool actionsEnabled: controller.available && inventoryReady
        && !controller.refreshing && !controller.running && !backend.busy
    readonly property var toolkitSnapshot: (backend.snapshot || {}).toolkit || ({})

    function componentState(componentId) {
        if (componentId === "persistence")
            return (backend.cpuUnlockStatus || {}).updatePersistence ? "installed" : "not-installed"
        var components = controller.inventory.components || []
        for (var i = 0; i < components.length; ++i) {
            if (components[i].id === componentId)
                return components[i].state || "unknown"
        }
        return controller.available ? "unknown" : "unavailable"
    }

    function operation(operationId) {
        var operations = controller.operations || []
        for (var i = 0; i < operations.length; ++i) {
            if (operations[i].id === operationId)
                return operations[i]
        }
        return null
    }

    function requestOperation(operationId) {
        var metadata = operation(operationId)
        if (!metadata)
            return
        var detail = metadata.description + "\n\nLive output will be shown in the console. "
            + "Do not close the application or power off the system while this operation is active."
        var acknowledgement = metadata.destructive
            ? "I understand this removes toolkit-managed integration and may require a reboot."
            : ""
        confirmation.ask(metadata.title, detail, metadata.destructive,
            function() { controller.start(operationId) }, acknowledgement)
    }

    ListModel {
        id: components
        ListElement { componentId: "storage"; categoryName: "SYSTEM"; title: "PERSISTENT STORAGE"; description: "Home-backed storage and boot recovery."; primary: "storage-install"; repair: "storage-repair"; remove: "storage-remove" }
        ListElement { componentId: "power"; categoryName: "SYSTEM"; title: "POWER MANAGEMENT"; description: "ACPI override, governor, and helpers."; primary: "power-install"; repair: ""; remove: "power-remove" }
        ListElement { componentId: "ram"; categoryName: "SYSTEM"; title: "RAM / VRAM HELPER"; description: "Verified CMOS and TTM configuration helper."; primary: "ram-install"; repair: ""; remove: "ram-remove" }
        ListElement { componentId: "compute"; categoryName: "SYSTEM"; title: "COMPUTE PREREQUISITES"; description: "Build UMR for CU routing controls."; primary: "compute-build"; repair: ""; remove: "compute-remove" }
        ListElement { componentId: "cec"; categoryName: "SYSTEM"; title: "HDMI-CEC"; description: "TV, receiver, boot, and sleep integration."; primary: "cec-setup"; repair: "cec-repair"; remove: "cec-remove" }
        ListElement { componentId: "persistence"; categoryName: "SYSTEM"; title: "UPDATE PERSISTENCE"; description: "Retain toolkit integration across SteamOS updates."; primary: "persistence-install"; repair: ""; remove: "persistence-remove" }
        ListElement { componentId: "aic"; categoryName: "DRIVERS"; title: "AIC8800 WIRELESS"; description: "Build matching WiFi and Bluetooth modules."; primary: "aic-install"; repair: ""; remove: "aic-remove" }
        ListElement { componentId: "audio"; categoryName: "DRIVERS"; title: "PATCHED AMDGPU"; description: "Display-clock audio and metrics fixes."; primary: "audio-build"; repair: ""; remove: "audio-remove" }
        ListElement { componentId: "mesh"; categoryName: "DRIVERS"; title: "MESH-SHADER RADV"; description: "Alternate per-game RADV build."; primary: "mesh-setup"; repair: ""; remove: "mesh-remove" }
        ListElement { componentId: "decky"; categoryName: "INTERFACES"; title: "DECKY PLUGIN"; description: "Gaming-mode BC-250 controls."; primary: "decky-install"; repair: ""; remove: "decky-remove" }
        ListElement { componentId: "desktop"; categoryName: "INTERFACES"; title: "PLASMA CONTROL"; description: "Desktop applet and shared system service."; primary: "desktop-install"; repair: ""; remove: "desktop-remove" }
    }

    C.ConfirmDialog { id: confirmation }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 58
        color: controller.available && !controller.error ? "#091d1fc8" : "#2d101ac8"
        border.color: controller.available && !controller.error ? "#2e7f82" : "#ff4d8d"
        radius: 2

        RowLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 9
            Rectangle {
                implicitWidth: 8; implicitHeight: 8; radius: 4
                color: controller.refreshing ? "#e6ad55"
                    : controller.available && !controller.error ? "#49ff9a" : "#ff4d8d"
            }
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                Text {
                    text: controller.refreshing ? "SCANNING TOOLKIT INVENTORY"
                        : controller.available && root.inventoryReady && !controller.error
                            ? "TOOLKIT READY // NATIVE EXECUTION"
                        : controller.available ? "TOOLKIT INVENTORY UNAVAILABLE"
                        : "TOOLKIT CHECKOUT NOT AVAILABLE"
                    color: controller.refreshing ? "#e6ad55"
                        : controller.available && root.inventoryReady && !controller.error
                            ? "#65f5ad" : "#ff8ab4"
                    font.family: "monospace"; font.pixelSize: 9; font.bold: true
                }
                Text {
                    text: controller.error.length > 0 ? controller.error
                        : controller.toolkitPath.length > 0 ? controller.toolkitPath
                        : "~/.local/share/bc250-fixes/bc250-steamos"
                    color: "#7898a3"
                    font.family: "monospace"; font.pixelSize: 7
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
            }
            Text {
                text: backend.serviceAvailable ? "SERVICE ONLINE" : "SERVICE OFFLINE"
                color: backend.serviceAvailable ? "#49ff9a" : "#e6ad55"
                font.family: "monospace"; font.pixelSize: 7; font.bold: true
            }
            C.NeonButton {
                text: "SCAN"
                enabled: !controller.refreshing && !controller.running
                implicitWidth: 50; implicitHeight: 27
                font.pixelSize: 8
                onClicked: {
                    controller.refreshInventory()
                    backend.refresh()
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 4
        Repeater {
            model: ["SYSTEM", "DRIVERS", "INTERFACES", "ALL"]
            C.NeonButton {
                required property string modelData
                text: modelData
                checked: root.category === modelData
                accent: checked ? "#ef48bb" : "#22e7f2"
                implicitHeight: 27
                font.pixelSize: 8
                Layout.fillWidth: true
                onClicked: root.category = modelData
            }
        }
    }

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: 7
        rowSpacing: 7

        Repeater {
            model: components
            C.ToolkitCard {
                required property string componentId
                required property string categoryName
                required property string primary
                required property string repair
                required property string remove
                visible: root.category === "ALL" || root.category === categoryName
                objectName: "toolkitCard-" + componentId
                Layout.fillWidth: true
                Layout.preferredWidth: (root.width - 7) / 2
                installState: root.componentState(componentId)
                primaryText: (root.operation(primary) || {}).verb || "RUN"
                actionEnabled: root.actionsEnabled
                repairVisible: repair.length > 0
                removeVisible: installState !== "not-installed" && installState !== "unavailable"
                onPrimaryRequested: root.requestOperation(primary)
                onRepairRequested: root.requestOperation(repair)
                onRemoveRequested: root.requestOperation(remove)
            }
        }
    }

    Rectangle {
        visible: !controller.available
        Layout.fillWidth: true
        implicitHeight: missingText.implicitHeight + 18
        color: "#321327b8"
        border.color: "#ef48bb"
        Text {
            id: missingText
            anchors.fill: parent
            anchors.margins: 9
            text: "Install or clone the full BC-250 toolkit at the standard path, then select SCAN. Toolkit execution is intentionally unavailable in the Flatpak build."
            color: "#ffc1df"
            font.family: "monospace"; font.pixelSize: 8
            wrapMode: Text.Wrap
        }
    }

    C.ConsolePanel {
        id: consolePanel
        controller: root.controller
        Layout.fillWidth: true
        Layout.preferredHeight: implicitHeight
    }
}
