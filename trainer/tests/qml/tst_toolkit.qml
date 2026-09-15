import QtQuick 2.15
import QtTest 1.3
import "../../qml/pages" as Pages

TestCase {
    id: testCase
    name: "ToolkitDashboard"
    when: windowShown
    width: 640
    height: 900

    QtObject {
        id: backend
        property bool busy: false
        property bool serviceAvailable: true
        property var snapshot: ({"toolkit": {"available": true}})
        property int refreshCalls: 0
        function refresh() { refreshCalls += 1 }
    }

    QtObject {
        id: controller
        property bool available: true
        property string toolkitPath: "/tmp/bc250-steamos"
        property var inventory: ({
            "schemaVersion": 1,
            "components": [
                {"id": "storage", "state": "installed"},
                {"id": "power", "state": "partial"},
                {"id": "ram", "state": "not-installed"},
                {"id": "swap", "state": "installed"},
                {"id": "ac3", "state": "installed"},
                {"id": "proton", "state": "not-installed"},
                {"id": "mesh", "state": "partial"}
                ,{"id": "native-mesh", "state": "not-installed"}
            ]
        })
        property var operations: [
            {"id": "auto-base-installation", "title": "Auto Base Toolkit Installation", "verb": "INSTALL / RESUME", "description": "Install AMDGPU/RADV, the power foundation, and the RAM helper with automatic dependencies. Rerunning after mandatory reboots resumes the setup.", "cancellable": false, "destructive": false},
            {"id": "storage-install", "title": "Install storage", "verb": "INSTALL", "description": "Install storage.", "destructive": false},
            {"id": "storage-repair", "title": "Repair storage", "verb": "REPAIR", "description": "Repair storage.", "destructive": false},
            {"id": "storage-remove", "title": "Remove storage", "verb": "REMOVE", "description": "Remove storage.", "destructive": true},
            {"id": "swap-zram-install", "title": "Use zram", "verb": "USE ZRAM", "description": "Use zram.", "destructive": false},
            {"id": "swap-zswap-install", "title": "Use zswap", "verb": "USE ZSWAP", "description": "Use zswap.", "destructive": false},
            {"id": "swap-remove", "title": "Remove swap", "verb": "REMOVE", "description": "Remove swap.", "destructive": true},
            {"id": "ac3-install", "title": "Enable AC-3", "verb": "ENABLE", "description": "Enable surround.", "destructive": false},
            {"id": "ac3-remove", "title": "Restore stereo", "verb": "REMOVE", "description": "Restore stereo.", "destructive": true},
            {"id": "proton-install", "title": "Install Proton", "verb": "INSTALL", "description": "Install Proton.", "destructive": false},
            {"id": "proton-update", "title": "Update Proton", "verb": "UPDATE", "description": "Update Proton.", "destructive": false},
            {"id": "proton-remove", "title": "Remove Proton", "verb": "REMOVE", "description": "Remove Proton.", "destructive": true},
            {"id": "graphics-setup", "title": "Install graphics stack", "verb": "INSTALL / RESUME", "description": "Install graphics.", "destructive": false},
            {"id": "mesh-remove", "title": "Remove RADV", "verb": "REMOVE", "description": "Remove RADV.", "destructive": true}
            ,{"id": "native-mesh-install", "title": "Install private native mesh", "verb": "BUILD + INSTALL", "description": "Never globally enabled and Steam is not edited.", "destructive": false}
            ,{"id": "native-mesh-remove", "title": "Remove private native mesh", "verb": "REMOVE", "description": "Leave global RADV unchanged.", "destructive": true}
        ]
        property bool refreshing: false
        property bool running: false
        property string error: ""
        property string activeOperationTitle: ""
        property bool cancellable: false
        property bool cancelPending: false
        property bool authenticationPending: false
        property string outputText: ""
        property int exitCode: -1
        property string resultStatus: "idle"
        property int refreshCalls: 0
        property string startedOperation: ""
        signal authenticationRequested()
        signal operationFinished(string operationId, string status, int exitCode)
        function refreshInventory() { refreshCalls += 1 }
        function start(operationId) { startedOperation = operationId; return true }
        function cancel() { return false }
        function clearOutput() { outputText = "" }
    }

    Pages.ToolkitPage {
        id: page
        width: 580
        backend: backend
        controller: controller
    }

    function init() {
        page.category = "FOUNDATION"
        backend.busy = false
        backend.refreshCalls = 0
        controller.available = true
        controller.refreshing = false
        controller.running = false
        controller.error = ""
        controller.outputText = ""
        controller.exitCode = -1
        controller.resultStatus = "idle"
        controller.refreshCalls = 0
        controller.startedOperation = ""
    }

    function test_inventoryStatesAndBusyInterlock() {
        compare(page.componentState("storage"), "installed")
        compare(page.componentState("power"), "partial")
        compare(page.componentState("swap"), "installed")

        var storage = findChild(page, "toolkitCard-storage")
        verify(storage !== null)
        compare(storage.installState, "installed")
        verify(storage.actionEnabled)
        verify(storage.removeVisible)

        backend.busy = true
        tryCompare(storage, "actionEnabled", false)
        backend.busy = false
        controller.refreshing = true
        tryCompare(storage, "actionEnabled", false)
        controller.refreshing = false
        controller.error = "inventory failed"
        tryCompare(storage, "actionEnabled", false)
    }

    function test_autoBaseInstallationIsIndependentAndDispatches() {
        var card = findChild(page, "autoBaseInstallationCard")
        var title = findChild(page, "autoBaseInstallationTitle")
        var description = findChild(page, "autoBaseInstallationDescription")
        var action = findChild(page, "autoBaseInstallationAction")
        verify(card !== null)
        verify(title !== null)
        verify(description !== null)
        verify(action !== null)
        compare(page.category, "FOUNDATION")
        compare(page.showsCategory("FOUNDATION"), true)
        verify(card.categoryVisible)
        compare(title.text, "AUTO BASE TOOLKIT INSTALLATION")
        compare(action.text, "INSTALL / RESUME")
        verify(description.text.indexOf("AMDGPU/RADV") >= 0)
        verify(description.text.indexOf("automatic dependencies") >= 0)
        verify(description.text.indexOf("mandatory reboots") >= 0)
        verify(action.enabled)

        action.clicked()
        var dialog = findChild(page, "toolkitConfirmDialog")
        verify(dialog !== null)
        compare(dialog.title, "Auto Base Toolkit Installation")
        dialog.accept()
        compare(controller.startedOperation, "auto-base-installation")

        page.category = "PERFORMANCE"
        tryCompare(card, "categoryVisible", false)
        page.category = "ALL"
        tryCompare(card, "categoryVisible", true)
        page.category = "FOUNDATION"
    }

    function test_missingToolkitDisablesActions() {
        controller.available = false
        var storage = findChild(page, "toolkitCard-storage")
        var status = findChild(page, "toolkitAvailabilityStatus")
        verify(status !== null)
        tryCompare(storage, "actionEnabled", false)
        compare(status.text, "CONTROL SERVICE READY // NATIVE MAINTENANCE UNAVAILABLE")
    }

    function test_semanticCategoryVisibility() {
        var storage = findChild(page, "toolkitCard-storage")
        var ram = findChild(page, "toolkitCard-ram")
        var swap = findChild(page, "toolkitCard-swap")
        var ac3 = findChild(page, "toolkitCard-ac3")
        var proton = findChild(page, "toolkitCard-proton")
        var nativeMesh = findChild(page, "toolkitCard-native-mesh")
        var coolercontrol = findChild(page, "toolkitCard-coolercontrol")
        verify(storage !== null)
        verify(ram !== null)
        verify(swap !== null)
        verify(ac3 !== null)
        verify(proton !== null)
        verify(nativeMesh !== null)
        verify(findChild(page, "toolkitCard-cec") === null)
        verify(findChild(page, "toolkitCard-persistence") === null)
        verify(coolercontrol !== null)
        compare(storage.categoryName, "FOUNDATION")
        compare(ram.categoryName, "PERFORMANCE")
        compare(swap.categoryName, "PERFORMANCE")
        compare(ac3.categoryName, "DEVICES")
        compare(proton.categoryName, "PERFORMANCE")
        compare(nativeMesh.categoryName, "PERFORMANCE")
        compare(coolercontrol.categoryName, "INTERFACES")
        compare(page.showsCategory(storage.categoryName), true)
        compare(page.showsCategory(ram.categoryName), false)
        compare(page.showsCategory(ac3.categoryName), false)

        page.category = "PERFORMANCE"
        compare(page.showsCategory(storage.categoryName), false)
        compare(page.showsCategory(ram.categoryName), true)
        compare(page.showsCategory(ac3.categoryName), false)

        page.category = "DEVICES"
        compare(page.showsCategory(ram.categoryName), false)
        compare(page.showsCategory(ac3.categoryName), true)

        page.category = "ALL"
        compare(page.showsCategory(storage.categoryName), true)
        compare(page.showsCategory(ram.categoryName), true)
        compare(page.showsCategory(ac3.categoryName), true)
        page.category = "FOUNDATION"
    }

    function test_consoleReflectsAndClearsOutput() {
        controller.outputText = "build line 1\nbuild line 2\n"
        var output = findChild(page, "consoleOutput")
        verify(output !== null)
        compare(output.text, controller.outputText)
        controller.clearOutput()
        compare(output.text, "No command output yet. Select an action to begin.")
    }
}
