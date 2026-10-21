import QtQuick 2.15
import QtTest 1.3
import "../../qml/components" as C
import "../../qml/pages" as Pages

TestCase {
    id: testCase
    name: "TrainerParity"
    when: windowShown
    // TestCase is invisible by default. Mount dynamic visual pages on a visible
    // surface, as the production Loader does: Qt 6.4 can crash while tearing
    // down nested GridLayouts beneath an invisible TestCase parent.
    visible: true
    width: 700
    height: 1000

    QtObject {
        id: backend
        property bool busy: false
        property bool serviceAvailable: true
        property bool mockMode: true
        property string busyLabel: ""
        property var snapshot: ({toolkit:{cecAvailable:true}, cec:{devicePresent:true,osdName:"BC250"}, power:{sensors:[{key:"fan",device:"nct6687",label:"fan",value:0,unit:"RPM"}]}})
        property var telemetry: ({})
        property var cpuUnlockStatus: ({physicalCores:8,metrics:{state:"unavailable",message:"Legacy SMU consumer incompatible"}})
        property var cliCatalog: ({schemaVersion:1,available:false,reason:"CLI handoff is unavailable in Flatpak.",sections:[]})
        property var fsr4Inventory: ({available:true,helixsrAvailable:true,helixsrPayloadState:"ready",optiscalerAvailable:true})
        property string called: ""
        property var calledArguments: []
        function setFsr4Dll(id, enabled) { called = "fsr"; calledArguments = [id, enabled] }
        function installHelixsr(id) { called = "helix"; calledArguments = [id] }
        function uninstallHelixsr(id) { called = "helixRestore"; calledArguments = [id] }
        function installOptiscaler(id, proxy) { called = "opti"; calledArguments = [id, proxy] }
        function uninstallOptiscaler(id) { called = "optiRestore"; calledArguments = [id] }
        function cecAction(action) { called = "cec"; calledArguments = [action] }
        function setCecName(name) { called = "cecName"; calledArguments = [name] }
        function setCecToggle(key, value) { called = "cecToggle"; calledArguments = [key, value] }
    }

    readonly property var readyGame: ({fullyInstalled:true,installPresent:true,scanState:"complete",optiscalerCandidates:[]})
    function target(overrides) {
        var value = {targetId:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",relativePath:"amd_fidelityfx_upscaler_dx12.dll",state:"available",discovered:true,helixsrState:"not-installed",helixsrManaged:false,optiscalerManaged:false}
        Object.keys(overrides || {}).forEach(function(key) { value[key] = overrides[key] })
        return value
    }
    function candidate(overrides) {
        var value = {candidateId:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",relativePath:"bin",state:"not-installed",discovered:true,fsr4Managed:false,helixsrManaged:false}
        Object.keys(overrides || {}).forEach(function(key) { value[key] = overrides[key] })
        return value
    }
    Component { id: targetComponent; C.GameTarget { width: 650 } }
    Component { id: optiComponent; C.OptiscalerTarget { width: 650 } }
    Component { id: statusComponent; Pages.StatusPage { width: 650 } }
    Component { id: cecComponent; Pages.CecPage { width: 650 } }
    Component { id: cliComponent; Pages.CliPage { width: 650 } }

    function init() {
        backend.busy = false
        backend.called = ""
        backend.calledArguments = []
        backend.telemetry = ({})
    }

    function test_gameBlockersAndRollback() {
        var item = createTemporaryObject(targetComponent, testCase, {backend:backend,inventory:backend.fsr4Inventory,target:target(),game:readyGame})
        verify(item !== null)
        verify(item.fsrInstall)
        verify(item.helixInstall)
        item.target = target({state:"ready"})
        verify(!item.helixInstall)
        verify(item.fsrRestore)
        item.target = target({state:"missing"})
        verify(item.fsrRestore)
        verify(!item.fsrInstall)
        item.target = target({state:"modified"})
        verify(!item.fsrInstall)
        verify(!item.fsrRestore)
        item.target = target({helixsrManaged:true,helixsrState:"ready"})
        verify(!item.fsrInstall)
        verify(item.helixRestore)
        item.target = target({helixsrManaged:true,helixsrState:"invalid"})
        verify(!item.helixRestore)
        item.target = target({optiscalerManaged:true})
        verify(!item.helixInstall)
        item.target = target()
        item.game = {fullyInstalled:true,installPresent:true,scanState:"partial"}
        verify(!item.helixInstall)
        item.game = readyGame
        item.target = target({relativePath:"amd_fidelityfx_dx12.dll"})
        verify(!item.fsrInstall)
    }

    function test_gameWritesRequireWarningAndUseOpaqueId() {
        var item = createTemporaryObject(targetComponent, testCase, {backend:backend,inventory:backend.fsr4Inventory,target:target(),game:readyGame})
        findChild(item, "fsrInstall").clicked()
        compare(backend.called, "")
        var dialog = findChild(item, "gameTargetConfirm")
        verify(dialog.highRisk)
        verify(dialog.detail.indexOf("anti-cheat") >= 0)
        verify(dialog.detail.indexOf("rollback") >= 0)
        dialog.acceptedAction()
        dialog.close()
        compare(backend.called, "fsr")
        compare(backend.calledArguments, [target().targetId, true])
    }

    function test_optiscalerRepairConflictAndOrphanRollback() {
        var item = createTemporaryObject(optiComponent, testCase, {backend:backend,inventory:backend.fsr4Inventory,candidate:candidate(),game:readyGame})
        verify(item.installAllowed)
        item.candidate = candidate({state:"repair-required"})
        verify(item.installAllowed)
        verify(item.managed)
        item.candidate = candidate({state:"restorable",currentRelease:false})
        verify(!item.installAllowed)
        verify(findChild(item, "optiRestore").enabled)
        item.candidate = candidate({state:"ready",fsr4Managed:true})
        verify(!findChild(item, "optiRestore").enabled)
        item.candidate = candidate({state:"invalid"})
        verify(!item.installAllowed)
        verify(!findChild(item, "optiRestore").enabled)
        item.orphan = true
        item.game = ({})
        item.candidate = candidate({state:"ready",discovered:false})
        verify(!item.installAllowed)
        verify(findChild(item, "optiRestore").enabled)
    }

    function test_sensorFallbackPreservesZeroAndUnavailable() {
        var item = createTemporaryObject(statusComponent, testCase, {backend:backend})
        compare(item.sensors.length, 1)
        compare(item.sensors[0].value, 0)
        backend.telemetry = {sensors:[{key:"missing",device:"hwmon",label:"temperature",value:null,unit:"C"}]}
        compare(item.sensors[0].value, null)
        wait(0)
        var sensor = findChild(item, "hwmonSensor")
        verify(sensor !== null)
        tryCompare(sensor, "value", "Unavailable")
        backend.telemetry = {sensors:[]}
        compare(item.sensors.length, 0) // empty live list is authoritative
        compare(item.clockValue("cpuClock", 3650), "3650 MHz")
        backend.telemetry = {cpuClock:null, sensors:[], error:"Polling failed"}
        compare(item.clockValue("cpuClock", 3650), "Unavailable")
        backend.telemetry = {cpuClock:0, sensors:[]}
        compare(item.clockValue("cpuClock", 3650), "0 MHz")
    }

    function test_cecNameBytesAndStandbyConfirmation() {
        var item = createTemporaryObject(cecComponent, testCase, {backend:backend})
        verify(item.controls)
        item.broadcastName = "123456789012345"
        verify(!item.validName)
        item.broadcastName = "éééééééé"
        verify(!item.validName)
        item.broadcastName = "ééééééé"
        verify(item.validName)
        findChild(item, "cec-tv-off").clicked()
        compare(backend.called, "")
        var dialog = findChild(item, "cecConfirmDialog")
        verify(dialog.visible)
        dialog.accept()
        tryCompare(dialog, "visible", false)
        compare(backend.calledArguments, ["tv-off"])
    }

    function test_cecPageCanBeReloaded() {
        // Exercise production-style page unload independently of popup state.
        for (var cycle = 0; cycle < 5; ++cycle) {
            var item = createTemporaryObject(cecComponent, testCase, {backend:backend})
            verify(item !== null)
            verify(item.visible)
            verify(waitForRendering(item))
            compare(findChild(item, "cec-tv-off").text, "TV STANDBY")
            item.destroy()
            wait(0)
        }
    }

    function test_cliUnavailableIsExplicit() {
        var item = createTemporaryObject(cliComponent, testCase, {backend:backend})
        verify(!item.catalog.available)
        verify(item.catalog.reason.indexOf("Flatpak") >= 0)
    }
}
