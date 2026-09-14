import QtQuick 2.15
import QtTest 1.3
import "../../qml/pages" as Pages

TestCase {
    id: testCase
    name: "GpuControls"
    when: windowShown
    width: 640
    height: 900

    QtObject {
        id: backend
        property bool busy: false
        property var meshStatus: ({})
        property var snapshot: ({"gpu": {
            "controllable": true,
            "dbusReady": true,
            "mode": "adaptive",
            "minimum": 350,
            "maximum": 1500,
            "loadLower": 0.65,
            "loadUpper": 0.80,
            "temperatureTarget": 85,
            "climbMs": 500
        }})
        property string calledMethod: ""
        property var calledArguments: []
        function record(method, values) { calledMethod = method; calledArguments = values }
        function setGpuFrequency(mode, minimum, maximum) { record("frequency", [mode, minimum, maximum]) }
        function setLoadTarget(preset) { record("loadPreset", [preset]) }
        function setCustomLoadTarget(minimum, maximum) { record("customLoad", [minimum, maximum]) }
        function setTemperatureTarget(target) { record("temperature", [target]) }
        function setRamp(milliseconds) { record("ramp", [milliseconds]) }
    }

    Pages.GpuPage {
        id: page
        width: 580
        backend: backend
    }

    function setSnapshot(gpu) {
        backend.snapshot = {"gpu": gpu}
    }

    function init() {
        backend.busy = false
        backend.calledMethod = ""
        backend.calledArguments = []
        setSnapshot({
            "controllable": true,
            "dbusReady": true,
            "mode": "adaptive",
            "minimum": 350,
            "maximum": 1500,
            "loadLower": 0.65,
            "loadUpper": 0.80,
            "temperatureTarget": 85,
            "climbMs": 500
        })
    }

    function test_snapshotResynchronizesEveryEditor() {
        page.mode = "pin"
        page.minimum = 700
        page.maximum = 700
        page.loadMinimum = 20
        page.loadMaximum = 60
        page.temperatureTarget = 95
        page.ramp = 1800

        setSnapshot({
            "controllable": true,
            "dbusReady": true,
            "mode": "range",
            "minimum": 450,
            "maximum": 1350,
            "loadLower": 0.30,
            "loadUpper": 0.72,
            "temperatureTarget": 88,
            "climbMs": 900
        })

        tryCompare(page, "mode", "range")
        compare(page.minimum, 450)
        compare(page.maximum, 1350)
        compare(page.loadMinimum, 30)
        compare(page.loadMaximum, 72)
        compare(page.temperatureTarget, 88)
        compare(page.ramp, 900)
    }

    function test_frequencyEditLeavesAdaptiveMode() {
        var minimum = findChild(page, "gpuMinimum")
        verify(minimum !== null)
        minimum.value = 500
        minimum.valueModified()
        compare(page.mode, "range")
        compare(page.minimum, 500)

        page.mode = "adaptive"
        var maximum = findChild(page, "gpuMaximum")
        verify(maximum !== null)
        maximum.value = 1400
        maximum.valueModified()
        compare(page.mode, "range")
        compare(page.maximum, 1400)
    }

    function test_allActionsDispatchCurrentValues() {
        page.mode = "range"
        page.minimum = 500
        page.maximum = 1400
        findChild(page, "gpuFrequencyApply").clicked()
        compare(backend.calledMethod, "frequency")
        compare(backend.calledArguments, ["range", 500, 1400])

        findChild(page, "gpuLoadEager").clicked()
        compare(backend.calledMethod, "loadPreset")
        compare(backend.calledArguments, ["eager"])

        page.loadMinimum = 25
        page.loadMaximum = 70
        findChild(page, "gpuLoadSet").clicked()
        compare(backend.calledMethod, "customLoad")
        compare(backend.calledArguments, [25, 70])

        page.temperatureTarget = 90
        findChild(page, "gpuTemperatureSet").clicked()
        compare(backend.calledMethod, "temperature")
        compare(backend.calledArguments, [90])

        page.ramp = 1200
        findChild(page, "gpuRampSet").clicked()
        compare(backend.calledMethod, "ramp")
        compare(backend.calledArguments, [1200])
    }
}
