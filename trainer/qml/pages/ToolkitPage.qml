import QtQuick 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    required property var controller
    property string category: "FOUNDATION"
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

    function showsCategory(categoryName) {
        return category === "ALL" || category === categoryName
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
        ListElement { componentId: "storage"; categoryName: "FOUNDATION"; title: "PERSISTENT STORAGE"; description: "Automatic infrastructure; manual status, install, and boot recovery."; primary: "storage-install"; repair: "storage-repair"; secondaryText: "REPAIR"; remove: "storage-remove" }
        ListElement { componentId: "audio"; categoryName: "FOUNDATION"; title: "AMDGPU KERNEL FIXES"; description: "Install early, then reboot: clocks, telemetry, and compute queues."; primary: "audio-build"; repair: ""; secondaryText: "REPAIR"; remove: "audio-remove" }
        ListElement { componentId: "power"; categoryName: "FOUNDATION"; title: "POWER FOUNDATION"; description: "Installs ACPI and test-starts the GPU governor; enable at boot after load testing."; primary: "power-install"; repair: ""; secondaryText: "REPAIR"; remove: "power-remove" }
        ListElement { componentId: "persistence"; categoryName: "FOUNDATION"; title: "UPDATE PROTECTION"; description: "Retain supported toolkit integration across SteamOS updates."; primary: "persistence-install"; repair: ""; secondaryText: "REPAIR"; remove: "persistence-remove" }
        ListElement { componentId: "ram"; categoryName: "PERFORMANCE"; title: "MEMORY BALANCE HELPER"; description: "Install the verified helper before choosing CMOS and TTM limits on MEMORY."; primary: "ram-install"; repair: ""; secondaryText: "REPAIR"; remove: "ram-remove" }
        ListElement { componentId: "swap"; categoryName: "PERFORMANCE"; title: "COMPRESSED SWAP"; description: "Choose half-RAM zstd zram, or lz4 zswap with a 16 GiB persistent disk swapfile."; primary: "swap-zram-install"; repair: "swap-zswap-install"; secondaryText: "ZSWAP"; remove: "swap-remove" }
        ListElement { componentId: "compute"; categoryName: "PERFORMANCE"; title: "GPU CU PREREQUISITES"; description: "Build UMR only; routing, stability testing, and boot replay are separate steps."; primary: "compute-build"; repair: ""; secondaryText: "REPAIR"; remove: "compute-remove" }
        ListElement { componentId: "mesh"; categoryName: "PERFORMANCE"; title: "MESA / RADV ASYNC COMPUTE"; description: "Builds the GFX1013 async-compute driver in about 3-5 minutes; requires the patched AMDGPU module."; primary: "mesh-setup"; repair: ""; secondaryText: "REPAIR"; remove: "mesh-remove" }
        ListElement { componentId: "cec"; categoryName: "DEVICES"; title: "HDMI-CEC"; description: "TV, receiver, boot, and sleep integration."; primary: "cec-setup"; repair: "cec-repair"; secondaryText: "REPAIR"; remove: "cec-remove" }
        ListElement { componentId: "aic"; categoryName: "DEVICES"; title: "AIC8800 WIRELESS"; description: "Hardware-specific WiFi and Bluetooth modules."; primary: "aic-install"; repair: ""; secondaryText: "REPAIR"; remove: "aic-remove" }
        ListElement { componentId: "decky"; categoryName: "INTERFACES"; title: "DECKY PLUGIN"; description: "Gaming-mode BC-250 controls."; primary: "decky-install"; repair: ""; secondaryText: "REPAIR"; remove: "decky-remove" }
        ListElement { componentId: "desktop"; categoryName: "INTERFACES"; title: "PLASMA CONTROL"; description: "Desktop applet and shared system service."; primary: "desktop-install"; repair: ""; secondaryText: "REPAIR"; remove: "desktop-remove" }
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
            model: ["FOUNDATION", "PERFORMANCE", "DEVICES", "INTERFACES", "ALL"]
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
                required property string secondaryText
                required property string remove
                visible: root.showsCategory(categoryName)
                objectName: "toolkitCard-" + componentId
                Layout.fillWidth: true
                Layout.preferredWidth: (root.width - 7) / 2
                installState: root.componentState(componentId)
                primaryText: (root.operation(primary) || {}).verb || "RUN"
                repairText: secondaryText
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
