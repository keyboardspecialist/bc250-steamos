import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import "Utils.js" as Utils

QtObject {
    id: root

    readonly property string service: "io.github.keyboardspecialist.BC250Control1"
    readonly property string objectPath: "/io/github/keyboardspecialist/BC250Control1"
    readonly property string serviceInterface: "io.github.keyboardspecialist.BC250Control1"

    property var snapshot: null
    property var cpuUnlockStatus: null
    property var meshStatus: null
    property var fsr4Inventory: null
    property var cliCatalog: null
    property var telemetryHistory: []
    property var telemetrySample: null
    property string telemetryError: ""
    property string snapshotError: ""
    property double _snapshotAt: 0
    property double _telemetryAt: 0
    property double _now: Date.now()
    property string error: ""
    property string notice: ""
    property bool loading: true
    property bool busy: false
    property string busyLabel: ""
    property string operationId: ""
    property bool operationCancellable: false
    property bool cancelPending: false
    property bool uiVisible: false
    property bool telemetryWanted: false

    onNoticeChanged: {
        if (notice)
            noticeTimer.restart();
        else
            noticeTimer.stop();
    }

    readonly property string healthState: {
        if (error || snapshotError)
            return "error";
        if (!snapshot)
            return "unknown";
        if (!snapshot.toolkit || !snapshot.toolkit.available)
            return "error";
        if (telemetryError || _now - _snapshotAt > (uiVisible ? 30000 : 90000)
                || (telemetryWanted && (_now - _telemetryAt > 5000
                    || latestTelemetry("cpuClock") === null || latestTelemetry("gpuClock") === null)))
            return "warning";
        if (!snapshot.cu.available || !snapshot.gpu.dbusReady
                || snapshot.power.governor.active !== "active")
            return "warning";
        return "healthy";
    }
    readonly property string healthSummary: {
        if (error)
            return error;
        if (snapshotError)
            return "Snapshot unavailable: " + snapshotError;
        if (telemetryError)
            return "Live telemetry unavailable: " + telemetryError;
        if (!snapshot)
            return "Waiting for the BC-250 service";
        if (_now - _snapshotAt > (uiVisible ? 30000 : 90000))
            return "Status is stale; refresh the service connection";
        if (telemetryWanted && _now - _telemetryAt > 5000)
            return "Waiting for fresh live telemetry";
        var cu = snapshot.cu.available ? snapshot.cu.total + "/" + snapshot.cu.maximum + " CU" : "CU unavailable";
        var clock = latestTelemetry("gpuClock");
        var gpu = clock === null ? "GPU unavailable" : Math.round(clock) + " MHz GPU";
        var temperature = latestGpuTemperature();
        return cu + " · " + gpu + (temperature === null ? "" : " · " + Math.round(temperature) + " °C");
    }

    signal operationFinished(bool success, string message)

    property var _queue: []
    property var _current: null
    property bool _snapshotQueued: false
    property bool _cpuUnlockQueued: false
    property bool _meshQueued: false
    property bool _fsr4Queued: false
    property bool _cliQueued: false
    property bool _telemetryQueued: false
    property bool _operationQueued: false
    property int _operationPollFailures: 0
    property bool _refreshFsr4AfterOperation: false

    function latestTelemetry(key) {
        // Do not backfill a failed/explicitly unknown live reading with an old
        // snapshot or history point. Zero, unlike null, is a real reading.
        if (telemetryWanted || _telemetryAt >= _snapshotAt) {
            if (telemetryError || !telemetrySample || _now - _telemetryAt > 5000)
                return null;
            var value = telemetrySample[key];
            return typeof value === "number" && isFinite(value) ? value : null;
        }
        if (snapshotError || !snapshot || _now - _snapshotAt > (uiVisible ? 30000 : 90000))
            return null;
        if (key === "cpuClock") return snapshot.power.cpuCurrentMhz === undefined ? null : snapshot.power.cpuCurrentMhz;
        if (key === "gpuClock") return snapshot.gpu.activeMhz === undefined ? null : snapshot.gpu.activeMhz;
        var temperatures = snapshot.power.temperatures || [];
        for (var index = 0; index < temperatures.length; ++index) {
            var temperature = temperatures[index];
            var name = String(temperature.device) + " " + String(temperature.label);
            if ((key === "gpuTemp" && /amdgpu|gpu|edge|junction/i.test(name))
                    || (key === "cpuTemp" && /k10temp|cpu|tctl|tdie/i.test(name)))
                return temperature.celsius === undefined ? null : temperature.celsius;
        }
        return null;
    }

    function latestGpuTemperature() { return latestTelemetry("gpuTemp"); }

    function latestSensors() {
        if (telemetryWanted || _telemetryAt >= _snapshotAt) {
            if (telemetryError || !telemetrySample || _now - _telemetryAt > 5000)
                return [];
            if (Array.isArray(telemetrySample.sensors)) return telemetrySample.sensors;
            // Older services expose only the four scalars. Keep their current
            // nulls, rather than substituting snapshot temperatures.
            return [{ key: "cpuTemp", device: "CPU", label: "Temperature", value: telemetrySample.cpuTemp, unit: "°C" },
                { key: "gpuTemp", device: "GPU", label: "Temperature", value: telemetrySample.gpuTemp, unit: "°C" }];
        }
        if (snapshotError || !snapshot || _now - _snapshotAt > (uiVisible ? 30000 : 90000)) return [];
        if (Array.isArray(snapshot.power.sensors)) return snapshot.power.sensors;
        return (snapshot.power.temperatures || []).map(function(sensor) {
            return { key: sensor.device + ":" + sensor.label, device: sensor.device,
                label: sensor.label, value: sensor.celsius, unit: "°C" };
        });
    }

    function _command(method, signature, argumentsList) {
        method = Utils.allowed(method, ["GetSnapshot", "GetTelemetry", "GetCpuUnlockStatus", "GetMeshStatus", "GetFsr4Inventory", "GetCliCatalog", "GetOperation",
            "SetCuWgp", "SetGpuFrequency", "SetLoadTarget", "SetCustomLoadTarget",
            "SetTemperatureTarget", "SetRamp", "ResetGpuRamp", "GpuVoltageAction", "OpenCliSection",
            "CpuOcAction", "CpuUnlockAction", "SetCpuMitigations", "SetCpuSmtDisabled", "CecAction", "SetCecToggle", "SetCecName",
            "SetUmaSize", "SetTtmPages", "RemoveTtmOverride", "SetHdmiSurround", "InstallFsr4Dll", "UninstallFsr4Dll",
            "PrepareHelixsr", "InstallHelixsr", "UninstallHelixsr", "InstallOptiscaler", "UninstallOptiscaler",
            "InstallDirectMesh", "InstallNativeMesh", "UninstallNativeMesh", "CancelOperation"]);
        signature = Utils.allowed(signature, ["", "b", "s", "u", "y", "yy", "suu", "siii", "yyyb", "suuu", "sb", "ss"]);
        var interactive = ["SetCuWgp", "SetGpuFrequency", "SetLoadTarget",
            "SetCustomLoadTarget", "SetTemperatureTarget", "SetRamp", "ResetGpuRamp", "GpuVoltageAction", "OpenCliSection",
            "CpuOcAction", "CpuUnlockAction", "SetCpuMitigations", "SetCpuSmtDisabled",
            "InstallOptiscaler", "UninstallOptiscaler"].indexOf(method) >= 0;
        var command = "/usr/bin/busctl --system --json=short --timeout="
            + (interactive ? "130" : method === "GetFsr4Inventory" ? "120" : method === "GetMeshStatus" || method === "GetCpuUnlockStatus" ? "35" : "15") + " call " + service + " "
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
        if (!_cpuUnlockQueued && !(_current && _current.type === "cpu-unlock")) {
            _cpuUnlockQueued = true;
            _enqueue("cpu-unlock", _command("GetCpuUnlockStatus", "", []), {});
        }
        if (!_meshQueued && !(_current && _current.type === "mesh")) {
            _meshQueued = true;
            _enqueue("mesh", _command("GetMeshStatus", "", []), {});
        }
        if (!fsr4Inventory)
            refreshFsr4();
        refreshCliCatalog();
    }

    function refreshCliCatalog() {
        if (_cliQueued || busy) return;
        _cliQueued = true;
        _enqueue("cli", _command("GetCliCatalog", "", []), {});
    }

    function openCliSection(sectionId) {
        var id = Utils.cliSection(sectionId);
        if (!cliCatalog || cliCatalog.schemaVersion !== 1 || !cliCatalog.available
                || !(cliCatalog.sections || []).some(function(section) { return section.id === id; }))
            throw new Error("The requested terminal workflow is unavailable. Refresh the catalog.");
        _startMutation("OpenCliSection", "s", [id], "Opening terminal workflow");
    }

    function refreshFsr4() {
        if (_fsr4Queued || (_current && _current.type === "fsr4") || busy)
            return;
        _fsr4Queued = true;
        _enqueue("fsr4", _command("GetFsr4Inventory", "", []), {});
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
        var command = _command(method, signature, args);
        busy = true;
        busyLabel = label;
        notice = "";
        error = "";
        _operationPollFailures = 0;
        var cancellable = ["OpenCliSection", "GpuVoltageAction", "ResetGpuRamp", "CpuUnlockAction", "SetCpuMitigations", "SetCpuSmtDisabled", "SetUmaSize", "SetTtmPages",
            "RemoveTtmOverride", "SetHdmiSurround", "InstallFsr4Dll", "UninstallFsr4Dll",
            "PrepareHelixsr", "InstallHelixsr", "UninstallHelixsr", "InstallOptiscaler", "UninstallOptiscaler",
            "InstallDirectMesh", "InstallNativeMesh", "UninstallNativeMesh"].indexOf(method) < 0
            && !(method === "CpuOcAction" && args[0] === "update");
        _enqueue("mutation", command, {
            label: label,
            refreshFsr4: method === "InstallFsr4Dll" || method === "UninstallFsr4Dll"
                || method === "PrepareHelixsr" || method === "InstallHelixsr" || method === "UninstallHelixsr"
                || method === "InstallOptiscaler" || method === "UninstallOptiscaler",
            cancellable: cancellable
        });
    }

    function setCuWgp(se, sh, wgp, enabled) {
        _startMutation("SetCuWgp", "yyyb", [
            Utils.integer(se, 0, 1), Utils.integer(sh, 0, 1), Utils.integer(wgp, 0, 4),
            Utils.booleanToken(enabled)
        ], (enabled ? "Enabling" : "Disabling") + " CU" + (wgp * 2) + "-" + (wgp * 2 + 1));
    }

    function setGpuFrequency(mode, minimum, maximum) {
        var safeMode = Utils.allowed(mode, ["adaptive", "range", "pin", "max"]);
        if (safeMode === "range" && ((Number(minimum) !== 0 && Number(minimum) < 350)
                || Number(minimum) > Number(maximum)))
            throw new Error("The frequency range needs a 0 or 350+ MHz floor not exceeding its ceiling.");
        _startMutation("SetGpuFrequency", "suu", [safeMode,
            Utils.integer(minimum, 0, 2230), Utils.integer(maximum, 350, 2230)],
            "Applying GPU frequency mode");
    }

    function setLoadTarget(preset) {
        var safePreset = Utils.allowed(preset, ["eager", "reset"]);
        _startMutation("SetLoadTarget", "s", [safePreset], "Applying GPU load target");
    }

    function setCustomLoadTarget(minimum, maximum) {
        if (Number(minimum) >= Number(maximum))
            throw new Error("Clock-down load must be below clock-up load.");
        _startMutation("SetCustomLoadTarget", "yy", [Utils.integer(minimum, 5, 99),
            Utils.integer(maximum, 5, 99)], "Applying custom GPU load target");
    }

    function setTemperatureTarget(target) {
        _startMutation("SetTemperatureTarget", "y", [Utils.integer(target, 50, 100)],
            "Applying GPU thermal target");
    }

    function setRamp(milliseconds) {
        _startMutation("SetRamp", "u", [Utils.integer(milliseconds, 200, 5000)],
            "Applying GPU ramp time");
    }

    function resetGpuRamp() {
        _startMutation("ResetGpuRamp", "", [], "Restoring default GPU ramp timing");
    }

    function gpuVoltageAction(action, frequency, voltage, newFrequency) {
        var change = Utils.voltageChange(snapshot.gpu.safePoints, action, frequency, voltage, newFrequency, snapshot.gpu);
        _startMutation("GpuVoltageAction", "siii", change.args, "Updating GPU voltage curve");
    }

    function setFsr4Dll(targetId, enabled) {
        var safeId = Utils.safeTargetId(targetId);
        _startMutation(enabled ? "InstallFsr4Dll" : "UninstallFsr4Dll", "s", [safeId],
            (enabled ? "Installing" : "Restoring") + " FSR4 game DLL");
    }

    function prepareHelixsr() {
        _startMutation("PrepareHelixsr", "", [], "Preparing experimental HelixSR payload");
    }

    function installHelixsr(targetId) {
        _startMutation("InstallHelixsr", "s", [Utils.safeTargetId(targetId)],
            "Installing experimental HelixSR game DLL");
    }

    function uninstallHelixsr(targetId) {
        _startMutation("UninstallHelixsr", "s", [Utils.safeTargetId(targetId)],
            "Restoring pre-HelixSR game DLL");
    }

    function setNativeMeshEnabled(enabled) {
        _startMutation(enabled ? "InstallDirectMesh" : "UninstallNativeMesh", "", [],
            enabled ? "Installing global DirectMesh" : "Removing retired BC250 R2");
    }

    function installOptiscaler(candidateId, proxy) {
        var safeId = Utils.safeCandidateId(candidateId);
        var safeProxy = Utils.allowed(proxy, ["winmm.dll", "dxgi.dll", "d3d12.dll",
            "dbghelp.dll", "version.dll", "wininet.dll", "winhttp.dll"]);
        _startMutation("InstallOptiscaler", "ss", [safeId, safeProxy],
            "Installing OptiScaler");
    }

    function uninstallOptiscaler(candidateId) {
        _startMutation("UninstallOptiscaler", "s", [Utils.safeCandidateId(candidateId)],
            "Restoring pre-OptiScaler game files");
    }

    function cpuOcAction(action, frequency, voltage, temperature) {
        var safeAction = Utils.allowed(action, ["detect", "apply", "enable", "update", "off"]);
        _startMutation("CpuOcAction", "suuu", [safeAction,
            Utils.integer(frequency, 3500, 4500), Utils.integer(voltage, 950, 1325),
            Utils.integer(temperature, 50, 100)], "Running CPU " + safeAction);
    }

    function cpuUnlockAction(action) {
        var safeAction = Utils.allowed(action, ["test", "enable", "efi-enable", "off", "metrics-enable", "uninstall"]);
        if (!cpuUnlockStatus || !cpuUnlockStatus.actions || !cpuUnlockStatus.actions[safeAction]
                || cpuUnlockStatus.actions[safeAction].available !== true)
            throw new Error("This core-unlock action is blocked by the service. Refresh its status.");
        _startMutation("CpuUnlockAction", "s", [safeAction], "Running CPU core-unlock " + safeAction);
    }

    function setCpuMitigations(enabled) {
        _startMutation("SetCpuMitigations", "b", [Utils.booleanToken(enabled)],
            (enabled ? "Enabling" : "Disabling") + " CPU mitigations");
    }

    function setCpuSmtDisabled(disabled) {
        _startMutation("SetCpuSmtDisabled", "b", [Utils.booleanToken(disabled)],
            (disabled ? "Disabling" : "Enabling") + " CPU SMT");
    }

    function setUmaSize(umaMiB) {
        _startMutation("SetUmaSize", "u", [Utils.integer(umaMiB, 256, 12288)],
            "Writing CMOS minimum VRAM");
    }

    function setTtmPages(pages) {
        _startMutation("SetTtmPages", "u", [Utils.integer(pages, 65536, 3145728)],
            "Updating TTM boot limit");
    }

    function removeTtmOverride() {
        _startMutation("RemoveTtmOverride", "", [], "Removing TTM boot limit");
    }

    function setHdmiSurround(enabled) {
        _startMutation("SetHdmiSurround", "b", [Utils.booleanToken(enabled)],
            (enabled ? "Enabling" : "Disabling") + " HDMI surround");
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
        var refreshGames = _refreshFsr4AfterOperation;
        error = message;
        busy = false;
        busyLabel = "";
        operationId = "";
        operationCancellable = false;
        _refreshFsr4AfterOperation = false;
        cancelPending = false;
        operationPoll.stop();
        operationFinished(false, message);
        if (refreshGames)
            refreshFsr4();
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

    function _readFailed(type, message) {
        if (type === "telemetry") {
            telemetryError = message;
            telemetrySample = null;
            telemetryHistory = telemetryHistory.concat([
                { cpuClock: null, gpuClock: null, cpuTemp: null, gpuTemp: null, sensors: [] }
            ]).slice(-36);
        } else if (type === "cli") {
            cliCatalog = { schemaVersion: 1, available: false, reason: message, sections: [] };
        } else {
            if (type === "snapshot") snapshotError = message;
            if (type === "cpu-unlock") cpuUnlockStatus = null;
            if (type === "mesh") meshStatus = null;
            if (type === "fsr4") fsr4Inventory = null;
            error = message;
        }
    }

    function _completed(sourceName, data) {
        if (!_current || sourceName !== _current.command)
            return;
        var request = _current;
        _current = null;
        executable.disconnectSource(sourceName);
        if (request.type === "snapshot")
            _snapshotQueued = false;
        else if (request.type === "cpu-unlock")
            _cpuUnlockQueued = false;
        else if (request.type === "mesh")
            _meshQueued = false;
        else if (request.type === "fsr4")
            _fsr4Queued = false;
        else if (request.type === "cli")
            _cliQueued = false;
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
            else
                _readFailed(request.type, Utils.readableError(data));
            loading = false;
            Qt.callLater(_pump);
            return;
        }

        try {
            if (request.type === "snapshot") {
                var nextSnapshot = Utils.busValue(data.stdout);
                if (!nextSnapshot || !nextSnapshot.power || !nextSnapshot.gpu || !nextSnapshot.toolkit || !nextSnapshot.cu || !nextSnapshot.cpu)
                    throw new Error("The service returned an invalid snapshot.");
                snapshot = nextSnapshot;
                _now = Date.now();
                _snapshotAt = _now;
                snapshotError = "";
                error = "";
                loading = false;
            } else if (request.type === "cpu-unlock") {
                cpuUnlockStatus = Utils.busValue(data.stdout);
            } else if (request.type === "mesh") {
                meshStatus = Utils.busValue(data.stdout);
            } else if (request.type === "fsr4") {
                fsr4Inventory = Utils.busValue(data.stdout);
            } else if (request.type === "cli") {
                var catalog = Utils.busValue(data.stdout);
                if (!catalog || catalog.schemaVersion !== 1 || !Array.isArray(catalog.sections))
                    throw new Error("The service returned an unsupported terminal-workflow catalog.");
                cliCatalog = catalog;
            } else if (request.type === "telemetry") {
                var sample = Utils.busValue(data.stdout);
                if (!sample || typeof sample !== "object" || Array.isArray(sample)
                        || !["cpuClock", "gpuClock", "cpuTemp", "gpuTemp"].every(function(key) {
                            return sample[key] === null || (typeof sample[key] === "number" && isFinite(sample[key]));
                        }))
                    throw new Error("The service returned invalid telemetry.");
                telemetrySample = sample;
                telemetryError = "";
                _now = Date.now();
                _telemetryAt = _now;
                var history = telemetryHistory.slice(0);
                history.push(sample);
                telemetryHistory = history.slice(-36);
            } else if (request.type === "mutation") {
                operationId = Utils.safeOperationId(Utils.busValue(data.stdout));
                operationCancellable = request.context.cancellable !== false;
                _refreshFsr4AfterOperation = Boolean(request.context.refreshFsr4);
                operationPoll.start();
                _pollOperation();
            } else if (request.type === "operation") {
                var operation = Utils.busValue(data.stdout);
                var status = operation ? String(operation.status || "") : "";
                if (!status)
                    throw new Error("The service returned an invalid operation status.");
                _operationPollFailures = 0;
                error = "";
                operationCancellable = operationCancellable && operation.cancellable !== false;
                if (status === "failed") {
                    _fail(String(operation.error || "The hardware operation failed."));
                } else if (status === "cancelled") {
                    busy = false;
                    busyLabel = "";
                    operationId = "";
                    operationCancellable = false;
                    _refreshFsr4AfterOperation = false;
                    cancelPending = false;
                    operationPoll.stop();
                    notice = "Operation cancelled.";
                    operationFinished(false, notice);
                    refresh();
                } else if (status === "succeeded") {
                    var message = String(operation.message || (operation.method ? operation.method + " completed." : "Operation completed."));
                    var refreshGames = _refreshFsr4AfterOperation;
                    busy = false;
                    busyLabel = "";
                    operationId = "";
                    operationCancellable = false;
                    _refreshFsr4AfterOperation = false;
                    cancelPending = false;
                    operationPoll.stop();
                    notice = message;
                    operationFinished(true, message);
                    refresh();
                    if (refreshGames)
                        refreshFsr4();
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
            else
                _readFailed(request.type, String(caught));
            loading = false;
        }
        Qt.callLater(_pump);
    }

    Component.onCompleted: refresh()

    property Timer freshnessClock: Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: root._now = Date.now()
    }

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

    property Timer noticeTimer: Timer {
        interval: 5000
        onTriggered: root.notice = ""
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
