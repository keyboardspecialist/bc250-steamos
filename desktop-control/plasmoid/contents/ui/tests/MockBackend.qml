import QtQuick

QtObject {
    id: root
    property bool uiVisible: true
    property bool telemetryWanted: true
    property bool loading: false
    property bool busy: false
    property string busyLabel: ""
    property string operationId: ""
    property bool cancelPending: false
    property string error: ""
    property string notice: "Mock mode: no hardware calls are made."
    property string healthState: "healthy"
    property string healthSummary: snapshot.cu.total + "/" + snapshot.cu.maximum + " CU · " + snapshot.gpu.activeMhz + " MHz GPU · 57 °C"
    property var telemetryHistory: [
        { cpuClock: 3090, gpuClock: 720, cpuTemp: 51, gpuTemp: 54 },
        { cpuClock: 3420, gpuClock: 980, cpuTemp: 53, gpuTemp: 56 },
        { cpuClock: 3650, gpuClock: 1120, cpuTemp: 55, gpuTemp: 57 }
    ]
    property var snapshot: ({
        toolkit: { available: true, privileged: true, powerAvailable: true,
            cpuControlAvailable: true, cecAvailable: true, path: "/mock/bc250-steamos" },
        cu: {
            available: true, controllable: true, liveReason: null, total: 24, maximum: 40,
            rows: [
                { se: 0, sh: 0, wgps: [true, true, true, false, false], cus: 6, factoryWgps: [true, true, true, false, false] },
                { se: 0, sh: 1, wgps: [true, true, true, false, false], cus: 6, factoryWgps: [true, true, true, false, false] },
                { se: 1, sh: 0, wgps: [true, true, true, false, false], cus: 6, factoryWgps: [true, true, true, false, false] },
                { se: 1, sh: 1, wgps: [true, true, true, false, false], cus: 6, factoryWgps: [true, true, true, false, false] }
            ],
            savedMasks: [7, 7, 7, 7], factoryMapAvailable: true, factoryTotal: 24,
            service: { enabled: "enabled", active: "active" }, protected: true
        },
        power: {
            acpiActive: true, cStates: 3, cpuGovernor: "schedutil", cpuCurrentMhz: 3650,
            governor: { enabled: "enabled", active: "active" },
            acpiService: { enabled: "enabled", active: "active" },
            cpufreqService: { enabled: "enabled", active: "active" },
            frequencyRestore: { enabled: "enabled", active: "exited" },
            temperatures: [{ device: "amdgpu", label: "edge", celsius: 57 }], protected: true
        },
        gpu: {
            available: true, controllable: true, dbusReady: true, mode: "adaptive",
            requestedMode: "adaptive", requestedMinimum: 100, requestedMaximum: 1500,
            minimum: 100, maximum: 1500, liveMinimum: 100, liveMaximum: 1500,
            initialMinimum: 100, initialMaximum: 1500, activeMhz: 1120,
            levels: ["100", "500", "1000", "1500"], allowedMinimum: 100, allowedMaximum: 2150,
            climbMs: 500, governorService: { enabled: "enabled", active: "active" },
            frequencyRestore: { enabled: "enabled", active: "exited" }, persistent: true,
            replayApplied: true, safePoints: [{ frequency: 1000, voltage: 850 }, { frequency: 1500, voltage: 975 }],
            configuredMax: 1500, loadUpper: 0.80, loadLower: 0.65, adjustMicros: 5000,
            rampNormal: 10, downEvents: 3
        },
        cpu: {
            service: { enabled: "enabled", active: "active" },
            installed: { values: { frequency: "4000", voltage: "1275" }, detected: "4000 MHz @ 1275 mV" },
            staged: null, toolAvailable: true
        },
        cec: {
            devicePresent: true, service: { enabled: "enabled", active: "active" },
            osdName: "BC-250", wakeTv: true, suspendTv: true, allowStandby: false,
            uinput: true, active: true, physicalAddress: 4096, audioLogicalAddress: 5,
            poweroffIntegration: true, sleepIntegration: true, protected: true
        }
    })

    function latestGpuTemperature() { return 57; }
    function refresh() { notice = "Mock snapshot refreshed."; }
    function openFullControls() { notice = "Mock plasmawindowed launch requested."; }
    function finish(label) { busy = false; busyLabel = ""; operationId = ""; notice = label + " completed (mock)."; }
    function start(label) {
        busy = true; busyLabel = label; operationId = "0123456789abcdef0123456789abcdef"; notice = "";
        finishTimer.label = label; finishTimer.restart();
    }
    function cancelOperation() {
        finishTimer.stop(); busy = false; busyLabel = ""; operationId = "";
        notice = "Operation cancelled (mock).";
    }
    function setCuWgp() { start("Updating CU routing"); }
    function setGpuFrequency() { start("Applying GPU frequency mode"); }
    function setLoadTarget() { start("Applying GPU load target"); }
    function setCustomLoadTarget() { start("Applying custom load target"); }
    function setRamp() { start("Applying GPU ramp time"); }
    function cpuOcAction() { start("Running CPU operation"); }
    function cecAction() { start("Sending CEC command"); }
    function setCecToggle() { start("Updating CEC behavior"); }
    function setCecName() { start("Updating CEC name"); }

    property Timer finishTimer: Timer {
        property string label: ""
        interval: 700
        onTriggered: root.finish(label)
    }
}
