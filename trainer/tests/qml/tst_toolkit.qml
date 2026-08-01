import QtQuick 2.15
import QtTest 1.3
import "../../qml/components" as Components
import "../../qml/pages" as Pages

TestCase {
    id: testCase
    name: "ToolkitDashboard"
    when: windowShown
    width: 640
    height: 900

    Component {
        id: backendComponent
        QtObject {
            property bool busy: false
            property bool serviceAvailable: true
            property var snapshot: ({"toolkit": {"available": true}})
            property var cpuUnlockStatus: ({"updatePersistence": true})
            property int refreshCalls: 0
            function refresh() { refreshCalls += 1 }
        }
    }

    Component {
        id: controllerComponent
        QtObject {
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
    }

    Component {
        id: pageComponent
        Pages.ToolkitPage { width: 580 }
    }

    Component {
        id: consoleComponent
        Components.ConsolePanel { width: 580; height: implicitHeight }
    }

    function makePage() {
        var backend = createTemporaryObject(backendComponent, testCase)
        var controller = createTemporaryObject(controllerComponent, testCase)
        var page = createTemporaryObject(pageComponent, testCase,
            {"backend": backend, "controller": controller})
        verify(page !== null)
        wait(0)
        return {"page": page, "backend": backend, "controller": controller}
    }

    function test_inventoryStatesAndBusyInterlock() {
        var fixture = makePage()
        compare(fixture.page.componentState("storage"), "installed")
        compare(fixture.page.componentState("power"), "partial")
        compare(fixture.page.componentState("persistence"), "installed")

        var storage = findChild(fixture.page, "toolkitCard-storage")
        verify(storage !== null)
        compare(storage.installState, "installed")
        verify(storage.actionEnabled)
        verify(storage.removeVisible)

        fixture.backend.busy = true
        tryCompare(storage, "actionEnabled", false)
        fixture.backend.busy = false
        fixture.controller.refreshing = true
        tryCompare(storage, "actionEnabled", false)
        fixture.page.destroy()
    }

    function test_missingToolkitDisablesActions() {
        var fixture = makePage()
        fixture.controller.available = false
        var storage = findChild(fixture.page, "toolkitCard-storage")
        tryCompare(storage, "actionEnabled", false)
        fixture.page.destroy()
    }

    function test_consoleReflectsAndClearsOutput() {
        var controller = createTemporaryObject(controllerComponent, testCase)
        controller.outputText = "build line 1\nbuild line 2\n"
        var console = createTemporaryObject(consoleComponent, testCase,
            {"controller": controller})
        verify(console !== null)
        var output = findChild(console, "consoleOutput")
        verify(output !== null)
        compare(output.text, controller.outputText)
        controller.clearOutput()
        compare(output.text, "No command output yet. Select an action to begin.")
    }
}
