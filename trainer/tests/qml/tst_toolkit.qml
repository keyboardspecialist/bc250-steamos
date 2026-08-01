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
        property var cpuUnlockStatus: ({"updatePersistence": true})
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
                {"id": "ram", "state": "not-installed"}
            ]
        })
        property var operations: [
            {"id": "storage-install", "title": "Install storage", "verb": "INSTALL", "description": "Install storage.", "destructive": false},
            {"id": "storage-repair", "title": "Repair storage", "verb": "REPAIR", "description": "Repair storage.", "destructive": false},
            {"id": "storage-remove", "title": "Remove storage", "verb": "REMOVE", "description": "Remove storage.", "destructive": true}
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
        compare(page.componentState("persistence"), "installed")

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
    }

    function test_missingToolkitDisablesActions() {
        controller.available = false
        var storage = findChild(page, "toolkitCard-storage")
        tryCompare(storage, "actionEnabled", false)
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
