import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import "Utils.js" as Utils

QtObject {
    id: root

    readonly property string service: "io.github.keyboardspecialist.BC250Control1"
    readonly property string objectPath: "/io/github/keyboardspecialist/BC250Control1"
    readonly property string serviceInterface: "io.github.keyboardspecialist.BC250Control1"

    property var snapshot: null
    property var telemetryHistory: []
    property string error: ""
    property string notice: ""
    property bool loading: true
    property bool busy: false
    property string busyLabel: ""
    property string operationId: ""
    property bool cancelPending: false
    property bool uiVisible: false
    property bool telemetryWanted: false

    readonly property string healthState: {
        if (error)
            return "error";
        if (!snapshot)
            return "unknown";
        if (!snapshot.toolkit || !snapshot.toolkit.available)
            return "error";
        if (!snapshot.cu.available || !snapshot.gpu.dbusReady
                || snapshot.power.governor.active !== "active")
            return "warning";
        return "healthy";
    }
    readonly property string healthSummary: {
        if (error)
            return error;
        if (!snapshot)
            return "Waiting for the BC-250 service";
        var cu = snapshot.cu.available ? snapshot.cu.total + "/" + snapshot.cu.maximum + " CU" : "CU unavailable";
        var gpu = snapshot.gpu.activeMhz === null ? "GPU unavailable" : Math.round(snapshot.gpu.activeMhz) + " MHz GPU";
        var temperature = latestGpuTemperature();
        return cu + " · " + gpu + (temperature === null ? "" : " · " + Math.round(temperature) + " °C");
    }

    signal operationFinished(bool success, string message)

    property var _queue: []
    property var _current: null
    property bool _snapshotQueued: false
    property bool _telemetryQueued: false
    property bool _operationQueued: false
    property int _operationPollFailures: 0

    function latestGpuTemperature() {
        if (telemetryHistory.length > 0) {
            var latest = telemetryHistory[telemetryHistory.length - 1];
            if (latest.gpuTemp !== null && latest.gpuTemp !== undefined)
                return latest.gpuTemp;
        }
        if (!snapshot || !snapshot.power || !snapshot.power.temperatures)
            return null;
        for (var index = 0; index < snapshot.power.temperatures.length; ++index) {
            var temperature = snapshot.power.temperatures[index];
            var name = String(temperature.device) + " " + String(temperature.label);
            if (/amdgpu|gpu|edge|junction/i.test(name))
                return temperature.celsius;
        }
        return null;
    }

    function _command(method, signature, argumentsList) {
        method = Utils.allowed(method, ["GetSnapshot", "GetTelemetry", "GetOperation",
            "SetCuWgp", "SetGpuFrequency", "SetLoadTarget", "SetCustomLoadTarget",
            "SetRamp", "CpuOcAction", "CecAction", "SetCecToggle", "SetCecName",
            "CancelOperation"]);
        signature = Utils.allowed(signature, ["", "s", "u", "yy", "suu", "yyyb", "suuu", "sb"]);
        var interactive = ["SetCuWgp", "SetGpuFrequency", "SetLoadTarget",
            "SetCustomLoadTarget", "SetRamp", "CpuOcAction"].indexOf(method) >= 0;
        var command = "/usr/bin/busctl --system --json=short --timeout="
            + (interactive ? "130" : "15") + " call " + service + " "
            + objectPath + " " + serviceInterface + " " + method;
        if (signature)
            command += " " + signature;
        for (var index = 0; index < argumentsList.length; ++index)
            command += " " + argumentsList[index];
        return command;
    }

    function _enqueue(type, command, context) {
        _queue.push({ type: type, command: command, context: context || {} });
        _pump();
    }

    function _pump() {
        if (_current || _queue.length === 0)
            return;
        _current = _queue.shift();
        executable.connectSource(_current.command);
    }

    function refresh() {
        if (_snapshotQueued || (_current && _current.type === "snapshot") || busy)
            return;
        _snapshotQueued = true;
        _enqueue("snapshot", _command("GetSnapshot", "", []), {});
    }

    function sampleTelemetry() {
        if (_telemetryQueued || (_current && _current.type === "telemetry") || busy)
            return;
        _telemetryQueued = true;
        _enqueue("telemetry", _command("GetTelemetry", "", []), {});
    }

    function _startMutation(method, signature, args, label) {
        if (busy)
            return;
        busy = true;
        busyLabel = label;
        notice = "";
        error = "";
        _operationPollFailures = 0;
        _enqueue("mutation", _command(method, signature, args), { label: label });
    }

    function setCuWgp(se, sh, wgp, enabled) {
        _startMutation("SetCuWgp", "yyyb", [
            Utils.integer(se, 0, 1), Utils.integer(sh, 0, 1), Utils.integer(wgp, 0, 4),
            Utils.booleanToken(enabled)
        ], (enabled ? "Enabling" : "Disabling") + " CU" + (wgp * 2) + "-" + (wgp * 2 + 1));
    }

    function setGpuFrequency(mode, minimum, maximum) {
        var safeMode = Utils.allowed(mode, ["adaptive", "range", "pin", "max"]);
        _startMutation("SetGpuFrequency", "suu", [safeMode,
            Utils.integer(minimum, 0, 2150), Utils.integer(maximum, 100, 2150)],
            "Applying GPU frequency mode");
    }

    function setLoadTarget(preset) {
        var safePreset = Utils.allowed(preset, ["eager", "reset"]);
        _startMutation("SetLoadTarget", "s", [safePreset], "Applying GPU load target");
    }

    function setCustomLoadTarget(minimum, maximum) {
        _startMutation("SetCustomLoadTarget", "yy", [Utils.integer(minimum, 1, 99),
            Utils.integer(maximum, 1, 99)], "Applying custom GPU load target");
    }

    function setRamp(milliseconds) {
        _startMutation("SetRamp", "u", [Utils.integer(milliseconds, 200, 5000)],
            "Applying GPU ramp time");
    }

    function cpuOcAction(action, frequency, voltage, temperature) {
        var safeAction = Utils.allowed(action, ["detect", "apply", "enable", "off"]);
        _startMutation("CpuOcAction", "suuu", [safeAction,
            Utils.integer(frequency, 3500, 4500), Utils.integer(voltage, 950, 1325),
            Utils.integer(temperature, 50, 100)], "Running CPU " + safeAction);
    }

    function cecAction(action) {
        var safeAction = Utils.allowed(action,
            ["tv-on", "tv-off", "amp-on", "amp-off", "switch", "release", "vol-up", "vol-down", "mute"]);
        _startMutation("CecAction", "s", [safeAction], "Sending CEC " + safeAction);
    }

    function setCecToggle(key, enabled) {
        var safeKey = Utils.allowed(key, ["wake-tv", "suspend-tv", "allow-standby", "uinput"]);
        _startMutation("SetCecToggle", "sb", [safeKey, Utils.booleanToken(enabled)],
            "Updating CEC behavior");
    }

    function setCecName(name) {
        var text = String(name).trim();
        var bytes = Utils.utf8Bytes(text);
        if (bytes.length < 1 || bytes.length > 14)
            throw new Error("CEC names must contain 1 to 14 UTF-8 bytes.");
        if (/[\u0000-\u001f\u007f-\u009f]/.test(text)
                || /["\\]/.test(text))
            throw new Error("CEC names cannot contain controls, double quotes, or backslashes.");
        _startMutation("SetCecName", "s", [Utils.shellString(text)], "Updating the CEC name");
    }

    function openFullControls() {
        var command = "/usr/bin/plasmawindowed io.github.keyboardspecialist.bc250control";
        launcher.disconnectSource(command);
        launcher.connectSource(command);
    }

    function _pollOperation() {
        if (!operationId || _operationQueued || (_current && _current.type === "operation"))
            return;
        _operationQueued = true;
        _enqueue("operation", _command("GetOperation", "s", [Utils.safeOperationId(operationId)]), {});
    }

    function cancelOperation() {
        if (!operationId || cancelPending)
            return;
        cancelPending = true;
        _enqueue("cancel", _command("CancelOperation", "s",
            [Utils.safeOperationId(operationId)]), {});
    }

    function _fail(message) {
        error = message;
        busy = false;
        busyLabel = "";
        operationId = "";
        cancelPending = false;
        operationPoll.stop();
        operationFinished(false, message);
    }

    function _operationPollFailed(message) {
        _operationPollFailures += 1;
        if (/UnknownObject|Operation not found/i.test(message) || _operationPollFailures >= 8) {
            _fail("Operation status is no longer available. Refresh hardware state before retrying.");
            refresh();
            return;
        }
        error = message + " Retrying operation status.";
    }

    function _completed(sourceName, data) {
        if (!_current || sourceName !== _current.command)
            return;
        var request = _current;
        _current = null;
        executable.disconnectSource(sourceName);
        if (request.type === "snapshot")
            _snapshotQueued = false;
        else if (request.type === "telemetry")
            _telemetryQueued = false;
        else if (request.type === "operation")
            _operationQueued = false;
        else if (request.type === "cancel")
            cancelPending = false;

        var exitCode = Number(data["exit code"] === undefined ? data.exitCode : data["exit code"]);
        if (exitCode !== 0) {
            if (request.type === "mutation")
                _fail(Utils.readableError(data));
            else if (request.type === "operation")
                _operationPollFailed(Utils.readableError(data));
            else if (request.type === "cancel")
                error = Utils.readableError(data);
            else if (request.type !== "telemetry" && request.type !== "launch")
                error = Utils.readableError(data);
            loading = false;
            Qt.callLater(_pump);
            return;
        }

        try {
            if (request.type === "snapshot") {
                snapshot = Utils.busValue(data.stdout);
                error = "";
                loading = false;
            } else if (request.type === "telemetry") {
                var sample = Utils.busValue(data.stdout);
                var history = telemetryHistory.slice(0);
                history.push(sample);
                telemetryHistory = history.slice(-36);
            } else if (request.type === "mutation") {
                operationId = Utils.safeOperationId(Utils.busValue(data.stdout));
                operationPoll.start();
                _pollOperation();
            } else if (request.type === "operation") {
                var operation = Utils.busValue(data.stdout);
                var status = operation ? String(operation.status || "") : "";
                if (!status)
                    throw new Error("The service returned an invalid operation status.");
                _operationPollFailures = 0;
                error = "";
                if (status === "failed") {
                    _fail(String(operation.error || "The hardware operation failed."));
                } else if (status === "cancelled") {
                    busy = false;
                    busyLabel = "";
                    operationId = "";
                    cancelPending = false;
                    operationPoll.stop();
                    notice = "Operation cancelled.";
                    operationFinished(false, notice);
                    refresh();
                } else if (status === "succeeded") {
                    var message = String(operation.message || (operation.method ? operation.method + " completed." : "Operation completed."));
                    busy = false;
                    busyLabel = "";
                    operationId = "";
                    cancelPending = false;
                    operationPoll.stop();
                    notice = message;
                    operationFinished(true, message);
                    refresh();
                } else if (status !== "queued" && status !== "running") {
                    throw new Error("The service returned an unknown operation state.");
                } else if (operation.label) {
                    busyLabel = String(operation.label);
                }
            } else if (request.type === "cancel") {
                if (Utils.busValue(data.stdout) !== true)
                    notice = "The operation could not be cancelled because it has already finished.";
            }
        } catch (caught) {
            if (request.type === "mutation")
                _fail(String(caught));
            else if (request.type === "operation")
                _operationPollFailed(String(caught));
            else if (request.type === "cancel")
                error = String(caught);
            else if (request.type !== "telemetry")
                error = String(caught);
            loading = false;
        }
        Qt.callLater(_pump);
    }

    Component.onCompleted: refresh()

    property Timer snapshotPoll: Timer {
        interval: root.uiVisible ? 10000 : 60000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    property Timer telemetryPoll: Timer {
        interval: 1000
        repeat: true
        running: root.uiVisible && root.telemetryWanted
        triggeredOnStart: true
        onTriggered: root.sampleTelemetry()
    }

    property Timer operationPoll: Timer {
        interval: 750
        repeat: true
        onTriggered: root._pollOperation()
    }

    property Plasma5Support.DataSource executable: Plasma5Support.DataSource {
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => root._completed(sourceName, data)
    }

    // Keep a long-lived plasmawindowed process from blocking serialized bus calls.
    property Plasma5Support.DataSource launcher: Plasma5Support.DataSource {
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => disconnectSource(sourceName)
    }
}
