const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ui = path.resolve(__dirname, "..");
const utils = {};
vm.createContext(utils);
vm.runInContext(fs.readFileSync(path.join(ui, "Utils.js"), "utf8")
    .replace(/^\.pragma library\s*/, ""), utils);
const plain = value => JSON.parse(JSON.stringify(value));
const points = [{frequency:350,voltage:700}, {frequency:1000,voltage:800}, {frequency:1500,voltage:900}];
const change = (action, f = 0, v = 0, n = 0, gpu = {}) => utils.voltageChange(points, action, f, v, n, gpu);

assert.deepEqual(plain(change("set", 1000, 825).args), ["set", "1000", "825", "0"]);
assert.deepEqual(plain(change("edit", 1000, 825, 1100).args), ["edit", "1000", "825", "1100"]);
assert.deepEqual(plain(change("add", 1200, 850).points).map(p => p.frequency), [350, 1000, 1200, 1500]);
assert.deepEqual(plain(change("remove", 1000).args), ["remove", "1000", "0", "0"]);
assert.deepEqual(plain(change("offset", 0, 25).args), ["offset", "0", "25", "0"]);
assert.deepEqual(plain(change("reset", 999, 999, 999).args), ["reset", "0", "0", "0"]);
assert.equal(change("reset").points.length, 5);
assert.throws(() => change("set", 1000, 699), /700.*1050/);
assert.throws(() => change("set", 1000, 1051), /700.*1050/);
assert.throws(() => change("set", 1000.5, 800), /whole number/);
assert.throws(() => change("set", 1000, "800; touch /tmp/no"), /whole number/);
assert.throws(() => change("add", 349, 800), /350.*2230/);
assert.throws(() => change("add", 2231, 1000), /350.*2230/);
assert.throws(() => change("add", 1000, 800), /already exists/);
assert.throws(() => change("edit", 1000, 800, 1500), /unique/);
assert.throws(() => change("set", 1000, 950), /must not decrease/);
assert.throws(() => change("offset", 0, -1), /700.*1050/);
assert.throws(() => change("offset", 0, 151), /700.*1050/);
assert.throws(() => change("remove", 1200), /existing/);
assert.throws(() => utils.voltageChange(points.slice(0, 2), "remove", 1000, 0, 0), /at least two/);
assert.throws(() => change("remove", 1500, 0, 0, {requestedMode:"pin", requestedMaximum:1500}), /saved frequency/);
assert.throws(() => change("remove", 350, 0, 0,
    {requestedMode:"range", requestedMinimum:350, requestedMaximum:1000}), /saved frequency/);
assert.doesNotThrow(() => change("remove", 350, 0, 0,
    {requestedMode:"range", requestedMinimum:0, requestedMaximum:1500}));
assert.throws(() => change("$(id)"), /allowlist/);
assert.equal(utils.sensorValue({value:0,unit:"RPM"}), "0 RPM");
assert.equal(utils.sensorValue({value:null,unit:"V"}), "Unavailable");
assert.equal(utils.sensorValue({value:0.975,unit:"V"}), "0.975 V");
assert.throws(() => utils.cliSection("power; id"), /allowlist/);
for (const section of ["menu", "status", "power", "ram", "swap", "compute", "cpu-unlock", "cec",
    "storage", "persistence", "wifi-backend", "memory-temperature", "radv", "video-codec", "proton", "manage"])
    assert.equal(utils.cliSection(section), section);

// Execute the production QML function bodies without instantiating a real
// executable DataSource or connecting to the system service.
const backendSource = fs.readFileSync(path.join(ui, "Backend.qml"), "utf8");
const calls = [];
const backend = {
    Utils: utils, service:"service", objectPath:"/object", serviceInterface:"interface",
    busy:false, error:"", snapshotError:"", telemetryError:"", telemetryWanted:true,
    uiVisible:true, _now:100000, _snapshotAt:99000, _telemetryAt:99900,
    snapshot:{power:{cpuCurrentMhz:1111, sensors:[{value:8}], temperatures:[]}, gpu:{activeMhz:2222, safePoints:points}},
    telemetrySample:{cpuClock:3333, gpuClock:4444, cpuTemp:0, gpuTemp:null, sensors:[{value:0, unit:"RPM"}]},
    telemetryHistory:[], _enqueue:(...args) => calls.push(args),
};
vm.createContext(backend);
for (const name of ["latestTelemetry", "latestSensors", "_command", "_startMutation", "_readFailed",
    "gpuVoltageAction", "resetGpuRamp", "cpuUnlockAction", "cpuOcAction", "openCliSection",
    "setTemperatureTarget", "setCustomLoadTarget", "setGpuFrequency", "_completed"]) {
    const match = backendSource.match(new RegExp("^    function " + name + "\\([^\\n]*\\) \\{[\\s\\S]*?^    \\}", "m"));
    assert.ok(match, name + " production function exists");
    vm.runInContext(match[0], backend);
}
assert.equal(backend.latestTelemetry("cpuClock"), 3333);
assert.equal(backend.latestTelemetry("gpuClock"), 4444);
assert.equal(backend.latestTelemetry("cpuTemp"), 0);
assert.equal(backend.latestTelemetry("gpuTemp"), null); // no stale snapshot fallback
assert.equal(backend.latestSensors()[0].value, 0);
backend._readFailed("telemetry", "transport failed");
assert.equal(backend.latestTelemetry("gpuClock"), null);
assert.equal(backend.latestSensors().length, 0);
assert.equal(backend.telemetryHistory.at(-1).gpuClock, null);
assert.equal(backend.telemetryError, "transport failed");
backend.telemetryError = "";
backend.telemetrySample = {gpuClock:0, sensors:[]};
assert.equal(backend.latestTelemetry("gpuClock"), 0);
backend.telemetrySample = {gpuClock:0, cpuTemp:null, gpuTemp:0};
assert.equal(backend.latestSensors()[0].value, null);
assert.equal(backend.latestSensors()[1].value, 0);
backend._now += 6000;
assert.equal(backend.latestTelemetry("gpuClock"), null);
backend.telemetryWanted = false;
backend._snapshotAt = backend._now;
assert.equal(backend.latestTelemetry("gpuClock"), 2222);
backend.snapshotError = "offline";
assert.equal(backend.latestTelemetry("gpuClock"), null);

assert.throws(() => backend._command("Shell", "s", ["id"]), /allowlist/);
assert.throws(() => backend._command("GetSnapshot", "ssss", []), /allowlist/);
assert.throws(() => backend._startMutation("Shell", "s", [], "bad"), /allowlist/);
assert.equal(backend.busy, false); // validation must happen before busy latch
for (const [run, pattern, cancellable] of [
    [() => backend.setTemperatureTarget(85), /SetTemperatureTarget y 85$/, true],
    [() => backend.gpuVoltageAction("offset", 0, 25, 0), /GpuVoltageAction siii offset 0 25 0$/, false],
    [() => backend.resetGpuRamp(), /ResetGpuRamp$/, false],
    [() => backend.cpuOcAction("update", 4000, 1275, 90), /CpuOcAction suuu update 4000 1275 90$/, false],
]) {
    backend.busy = false;
    run();
    assert.match(calls.at(-1)[1], pattern);
    assert.equal(calls.at(-1)[2].cancellable, cancellable);
}
backend.busy = false;
backend.cpuUnlockStatus = {actions:{"metrics-enable":{available:false}}};
assert.throws(() => backend.cpuUnlockAction("metrics-enable"), /blocked/);
backend.cpuUnlockStatus.actions["metrics-enable"].available = true;
backend.cpuUnlockAction("metrics-enable");
assert.match(calls.at(-1)[1], /CpuUnlockAction s metrics-enable$/);
assert.equal(calls.at(-1)[2].cancellable, false);
backend.busy = false;
backend.cpuUnlockStatus.actions.uninstall = {available:true};
backend.cpuUnlockAction("uninstall");
assert.match(calls.at(-1)[1], /CpuUnlockAction s uninstall$/);
backend._readFailed("cpu-unlock", "offline");
assert.equal(backend.cpuUnlockStatus, null);
backend.busy = false;
assert.throws(() => backend.cpuUnlockAction("uninstall"), /blocked/);
backend.cliCatalog = {schemaVersion:1, available:false, sections:[{id:"power"}]};
assert.throws(() => backend.openCliSection("power"), /unavailable/);
backend.cliCatalog.available = true;
assert.throws(() => backend.openCliSection("manage"), /unavailable/);
backend.openCliSection("power");
assert.match(calls.at(-1)[1], /OpenCliSection s power$/);
assert.equal(calls.at(-1)[2].cancellable, false);
backend.busy = false;
assert.throws(() => backend.setCustomLoadTarget(4, 80), /range/);
assert.throws(() => backend.setCustomLoadTarget(80, 65), /below/);
assert.throws(() => backend.setGpuFrequency("range", 1000, 500), /frequency range/);

backend.Qt = {callLater:() => {}};
backend.executable = {disconnectSource:() => {}};
backend._pump = () => {};
const complete = (type, data) => {
    backend._current = {type, command:"mock-request", context:{}};
    backend._completed("mock-request", data);
};
const reply = value => ({"exit code":0, stdout:JSON.stringify({data:[JSON.stringify(value)]})});
complete("telemetry", {"exit code":1, stderr:"read unavailable"});
assert.equal(backend.telemetryError, "read unavailable");
assert.equal(backend.telemetrySample, null);
complete("telemetry", {"exit code":0, stdout:"malformed JSON"});
assert.ok(backend.telemetryError);
complete("telemetry", reply({cpuClock:null, gpuClock:123, cpuTemp:0, gpuTemp:null, sensors:[]}));
assert.equal(backend.telemetryError, "");
assert.equal(backend._telemetryAt, backend._now);
backend.telemetryWanted = true;
assert.equal(backend.latestTelemetry("gpuClock"), 123);
assert.equal(backend.latestTelemetry("cpuClock"), null);
complete("telemetry", reply({gpuClock:123})); // missing required nullable scalars is malformed
assert.ok(backend.telemetryError);
const transportFailure = backend.telemetryError;
complete("fsr4", reply({games:[]}));
assert.equal(backend.telemetryError, transportFailure); // unrelated reads cannot hide failure
assert.equal(backend.snapshotError, "offline");
backend.operationCancellable = false;
complete("operation", reply({status:"running", cancellable:true}));
assert.equal(backend.operationCancellable, false); // server cannot re-enable an unsafe cancel button
complete("cli", {"exit code":1, stderr:"No terminal"});
assert.equal(backend.cliCatalog.available, false);
assert.equal(backend.cliCatalog.reason, "No terminal");
console.log("Plasma parity JavaScript checks passed");
