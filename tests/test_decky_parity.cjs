const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const root = path.resolve(__dirname, "..");
let ts;
try { ts = require("typescript"); }
catch { ts = require(path.join(root, "decky-plugin/node_modules/typescript")); }

// Exercise the actual TypeScript without Decky, Steam, DOM, network, or hardware.
function runtime(api = {}) {
  const slots = [];
  let cursor = 0;
  let effects = [];
  const react = {
    useState(initial) {
      const index = cursor++;
      if (!(index in slots)) slots[index] = typeof initial === "function" ? initial() : initial;
      return [slots[index], (next) => { slots[index] = typeof next === "function" ? next(slots[index]) : next; }];
    },
    useRef(initial) {
      const index = cursor++;
      return slots[index] ?? (slots[index] = { current: initial });
    },
    useEffect(callback, dependencies) {
      const index = cursor++;
      const previous = slots[index];
      if (!previous || dependencies.some((value, i) => value !== previous[i])) {
        slots[index] = dependencies;
        effects.push(callback);
      }
    },
  };
  const cache = new Map();
  function load(relative) {
    const filename = path.resolve(root, "decky-plugin/src", relative);
    if (cache.has(filename)) return cache.get(filename);
    const source = fs.readFileSync(filename, "utf8");
    const output = ts.transpileModule(source, { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
      jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true,
    } }).outputText;
    const module = { exports: {} };
    const requireMock = (id) => {
      if (id === "react") return react;
      if (id === "react/jsx-runtime") return {
        jsx: (type, props) => ({ type, props }), jsxs: (type, props) => ({ type, props }), Fragment: "Fragment",
      };
      if (id === "@decky/ui") return new Proxy({}, { get: (_target, key) => key });
      if (id.endsWith("/api")) return api;
      const base = path.resolve(path.dirname(filename), id);
      const target = [base + ".ts", base + ".tsx"].find((file) => fs.existsSync(file));
      if (!target) throw new Error(`Unexpected import: ${id}`);
      return load(path.relative(path.join(root, "decky-plugin/src"), target));
    };
    vm.runInThisContext(`(function(require,module,exports){${output}\n})`, { filename })(requireMock, module, module.exports);
    cache.set(filename, module.exports);
    return module.exports;
  }
  return {
    load,
    render(Component, props) {
      cursor = 0;
      effects = [];
      const tree = Component(props);
      for (const effect of effects) effect();
      return tree;
    },
  };
}

function nodes(tree) {
  if (Array.isArray(tree)) return tree.flatMap(nodes);
  if (!tree || typeof tree !== "object") return [];
  return [tree, ...nodes(tree.props?.children)];
}
function find(tree, type, label) {
  const result = nodes(tree).find((node) => (typeof node.type === "function" ? node.type.name : node.type) === type
    && (label === undefined || node.props.label === label));
  assert.ok(result, `${type}: ${label}`);
  return result.props;
}

const helpers = runtime().load("parity.ts");
const curve = [
  { frequency: 350, voltage: 700 }, { frequency: 1000, voltage: 800 },
  { frequency: 1500, voltage: 900 }, { frequency: 2230, voltage: 1000 },
];

function backendManifest() {
  return { controlApiVersion: 1, controlCapabilities: [
    "gpu-voltage-curve", "gpu-ramp-reset", "cpu-oc-update", "cpu-unlock-metrics",
    "cpu-unlock-uninstall", "cli-handoff", "hwmon-sensors",
  ] };
}

test("API capability checks use only the installed backend manifest", () => {
  assert.equal(helpers.controlApiSupports(backendManifest(), "gpu-voltage-curve"), true);
  for (const toolkit of [
    {}, { controlApiVersion: 1 }, { controlCapabilities: ["gpu-voltage-curve"] },
    { controlApiVersion: 0, controlCapabilities: ["gpu-voltage-curve"] },
    { controlApiVersion: 1.5, controlCapabilities: ["gpu-voltage-curve"] },
    { controlApiVersion: 1, controlCapabilities: "gpu-voltage-curve" },
    { controlApiVersion: 1, controlCapabilities: ["cpu-oc-update"] },
    { toolkitVersion: "v0.35.1", capabilitiesAvailable: true },
  ]) assert.equal(helpers.controlApiSupports(toolkit, "gpu-voltage-curve"), false);
});

test("history contains only four finite scalars, preserves zero, rejects undefined/NaN", () => {
  assert.deepEqual(helpers.historySample({ cpuClock: 0, gpuClock: NaN, gpuTemp: Infinity, sensors: curve }), {
    cpuClock: 0, gpuClock: null, cpuTemp: null, gpuTemp: null,
  });
  assert.deepEqual(Object.keys(helpers.historySample({})), ["cpuClock", "gpuClock", "cpuTemp", "gpuTemp"]);
});

test("sensor inventory preserves all units, zero, null, and legacy temperatures", () => {
  const sensors = [
    { key: "fan1", device: "board", label: "Fan", value: 0, unit: "RPM" },
    { key: "power1", device: "gpu", label: "Socket", value: 61.5, unit: "W" },
    { key: "in1", device: "board", label: "Core rail", value: 0.9, unit: "V" },
    { key: "temp1", device: "cpu", label: "Tctl", value: 50, unit: "°C" },
    { key: "temp2", device: "ram", label: "Memory", value: null, unit: "°C" },
  ];
  const temperatures = [{ device: "cpu", label: "Tctl", celsius: 50 }, { device: "nvme", label: "Composite", celsius: 34 }];
  const result = helpers.sensorInventory(sensors, temperatures);
  assert.equal(result.length, 6);
  assert.deepEqual(result.slice(0, 3).map(helpers.sensorValue), ["0 RPM", "61.5 W", "0.9 V"]);
  assert.equal(helpers.sensorValue(result[4]), "Unavailable");
  assert.equal(helpers.sensorValue({ value: undefined, unit: "W" }), "Unavailable");
  assert.equal(helpers.sensorInventory(undefined, temperatures).length, 2);
});

test("temperature roles never borrow storage, board, or GPU memory values", () => {
  const temperatures = [
    { device: "nvme", label: "Composite", celsius: 34 },
    { device: "board", label: "temp1", celsius: 30 },
    { device: "amdgpu", label: "Memory", celsius: 70 },
  ];
  assert.equal(helpers.temperatureForRole(temperatures, "cpu"), null);
  assert.equal(helpers.temperatureForRole(temperatures, "gpu"), null);
  temperatures.push({ device: "bc250_smu", label: "CPU temperature", celsius: 52 });
  temperatures.push({ device: "amdgpu", label: "edge", celsius: 0 });
  assert.equal(helpers.temperatureForRole(temperatures, "cpu"), 52);
  assert.equal(helpers.temperatureForRole(temperatures, "gpu"), 0);
});

test("frequency modes validate pinned/range integer limits and the zero-floor sentinel", () => {
  const valid = (mode, min, max) => helpers.frequencyValid(mode, min, max, 350, 2230);
  assert.equal(valid("range", 0, 2230), true);
  assert.equal(valid("pin", 0, 2230), true);
  assert.equal(valid("pin", 0, 2231), false);
  assert.equal(valid("range", 300, 1500), false);
  assert.equal(valid("range", 1600, 1500), false);
  assert.equal(valid("range", 350, 1500.5), false);
});

test("curve set/add/edit/remove/offset/reset mirror CLI invariants", () => {
  const error = (action, f, v, nf = 0, points = curve) => helpers.voltageCurveError(points, action, f, v, nf);
  assert.equal(error("set", 1000, 810), null);
  assert.equal(error("add", 1200, 850), null);
  assert.equal(error("edit", 1000, 850, 1200), null);
  assert.equal(error("remove", 1000, 0), null);
  assert.equal(error("offset", 0, 25), null);
  assert.equal(error("reset", 0, 0, 0, []), null);
  assert.match(error("add", 350, 750), /already exists/);
  assert.match(error("set", 1200, 850), /existing/);
  assert.match(error("edit", 1000, 900, 1500), /unique/);
  assert.match(error("add", 349, 700), /350-2230/);
  assert.match(error("add", 2231, 1000), /350-2230/);
  assert.match(error("set", 350, 699), /700-1050/);
  assert.match(error("set", 2230, 1051), /700-1050/);
  assert.match(error("set", 1000, 950), /must not decrease/);
  assert.match(error("offset", 0, -1), /700-1050/);
  assert.match(error("offset", 0, 51), /700-1050/);
  assert.match(error("offset", 0, 0.5), /whole number/);
  assert.match(error("remove", 350, 0, 0, curve.slice(0, 2)), /at least two/);
  assert.match(error("set", 350, 700, 0, [{ frequency: null, voltage: null }]), /incomplete/);
});

test("voltage editor requires acknowledgment and confirmation; RPC placeholders are zero", async () => {
  const calls = [];
  const mutations = [];
  const ui = runtime({ gpuVoltageAction: async (...args) => calls.push(args) });
  const Editor = ui.load("tabs/GpuVoltageEditor.tsx").GpuVoltageEditor;
  const props = { snapshot: { toolkit: { privileged: true, cpuControlAvailable: true, ...backendManifest() }, gpu: { available: true, safePoints: curve } },
    busy: false, runMutation: (...args) => mutations.push(args) };
  let tree = ui.render(Editor, props);
  assert.equal(find(tree, "ActionButton", "Apply voltage curve change").disabled, true);
  find(tree, "ToggleField", "I understand experimental voltage tuning").onChange(true);
  tree = ui.render(Editor, props);
  assert.equal(find(tree, "ActionButton", "Apply voltage curve change").disabled, false);
  find(tree, "DropdownItem", "Curve action").onChange({ data: "offset" });
  tree = ui.render(Editor, props);
  assert.equal(find(tree, "ActionButton", "Apply voltage curve change").disabled, true); // -25 underflows 700
  find(tree, "SliderField", "Whole-curve offset").onChange(25);
  tree = ui.render(Editor, props);
  find(tree, "ActionButton", "Apply voltage curve change").onClick();
  assert.equal(calls.length, 0); // confirmation has not been accepted
  assert.equal(mutations[0][2].destructive, true);
  await mutations[0][1]();
  assert.deepEqual(calls[0], ["offset", 0, 25, 0]);
  find(tree, "DropdownItem", "Curve action").onChange({ data: "reset" });
  tree = ui.render(Editor, props);
  find(tree, "ActionButton", "Apply voltage curve change").onClick();
  await mutations[1][1]();
  assert.deepEqual(calls[1], ["reset", 0, 0, 0]);
  props.snapshot.toolkit.privileged = false;
  assert.equal(find(ui.render(Editor, props), "ActionButton", "Apply voltage curve change").disabled, true);
});

test("point voltage controls use the siii RPC argument order for every edit action", async () => {
  for (const [action, expected] of [
    ["set", ["set", 350, 700, 0]],
    ["add", ["add", 1200, 850, 0]],
    ["edit", ["edit", 1000, 850, 1200]],
    ["remove", ["remove", 1000, 0, 0]],
  ]) {
    const calls = [];
    const mutations = [];
    const ui = runtime({ gpuVoltageAction: async (...args) => calls.push(args) });
    const Editor = ui.load("tabs/GpuVoltageEditor.tsx").GpuVoltageEditor;
    const props = { snapshot: { toolkit: { privileged: true, cpuControlAvailable: true, ...backendManifest() }, gpu: { available: true, safePoints: curve } },
      busy: false, runMutation: (...args) => mutations.push(args) };
    let tree = ui.render(Editor, props);
    find(tree, "ToggleField", "I understand experimental voltage tuning").onChange(true);
    tree = ui.render(Editor, props);
    find(tree, "DropdownItem", "Curve action").onChange({ data: action });
    tree = ui.render(Editor, props);
    if (action === "edit" || action === "remove") {
      find(tree, "DropdownItem", "Existing point").onChange({ data: 1000 });
      tree = ui.render(Editor, props);
    }
    if (action === "edit") {
      find(tree, "SliderField", "New frequency").onChange(1200);
      find(tree, "SliderField", "Voltage").onChange(850);
      tree = ui.render(Editor, props);
    }
    assert.equal(find(tree, "ActionButton", "Apply voltage curve change").disabled, false);
    find(tree, "ActionButton", "Apply voltage curve change").onClick();
    await mutations[0][1]();
    assert.deepEqual(calls[0], expected);
  }
});

function gpuFixture() {
  const service = { enabled: "enabled", active: "active" };
  return { toolkit: { privileged: true, cpuControlAvailable: true, ...backendManifest() }, gpu: {
    available: true, controllable: true, dbusReady: true,
    mode: "range", requestedMode: "range", minimum: 350, maximum: 1200,
    requestedMinimum: 0, requestedMaximum: 2000, allowedMinimum: 350, allowedMaximum: 2230,
    activeMhz: 0, liveMinimum: 350, liveMaximum: 1200, initialMinimum: 350, initialMaximum: 1500,
    governorService: service, configuredMax: 1500, climbMs: 0,
    safePoints: curve, loadLower: 0.10, loadUpper: 0.40, temperatureTarget: 85, temperatureRecovery: 75,
    adjustMicros: 200000, rampNormal: 1, downEvents: 5,
  } };
}

test("GPU controls reflect saved requests, expose resets, and use CLI load bounds", async () => {
  const calls = [];
  const mutations = [];
  const ui = runtime({ resetGpuRamp: async () => calls.push("ramp-reset"), setTemperatureTarget: async (value) => calls.push(value) });
  const Gpu = ui.load("tabs/GpuTab.tsx").GpuTab;
  const props = { snapshot: gpuFixture(), busy: false, runMutation: (...args) => mutations.push(args) };
  let tree = ui.render(Gpu, props);
  assert.equal(find(tree, "SliderField", "Maximum clock").value, 2000);
  assert.equal(find(tree, "StatusRow", "Active clock").value, "0 MHz");
  assert.equal(find(tree, "SliderField", "Minimum load").min, 5);
  find(tree, "SliderField", "Minimum load").onChange(1);
  tree = ui.render(Gpu, props);
  assert.equal(find(tree, "ActionButton", "Apply custom load target").disabled, true);
  find(tree, "ActionButton", "Reset ramp to toolkit defaults").onClick();
  assert.ok(mutations[0][2]);
  await mutations[0][1]();
  find(tree, "ActionButton", "Reset thermal target to 85 °C").onClick();
  await mutations[1][1]();
  assert.deepEqual(calls, ["ramp-reset", 85]);
  props.snapshot.toolkit.privileged = false;
  tree = ui.render(Gpu, props);
  assert.equal(find(tree, "ActionButton", "Reset ramp to toolkit defaults").disabled, true);
});

function cpuFixture() {
  const service = { enabled: "enabled", active: "active" };
  return {
    toolkit: { privileged: true, cpuControlAvailable: true, ...backendManifest() },
    cpu: { service, staged: { detected: "4000 MHz @ 1275 mV", values: { frequency: "4000", max_temperature: "80" } }, installed: null },
    cpuUnlock: { physicalCores: 8, logicalThreads: 8, topologyState: "unlocked", ccxGroups: [], mode: "linux-replay",
      linuxReplay: { service }, guard: { state: "clear", currentBoot: false },
      actions: Object.fromEntries(["test", "enable", "efi-enable", "off", "metrics-enable", "uninstall"].map((key) => [key, { available: true, blockers: [] }])),
      metrics: { state: "compatible", message: "Eight-core capable", service, revision: "test-revision" } },
  };
}

test("CPU metrics honor server availability, reboot guard, and missing additive fields", () => {
  const ui = runtime();
  const Cpu = ui.load("tabs/CpuTab.tsx").CpuTab;
  const props = { snapshot: cpuFixture(), busy: false, runMutation() {} };
  let tree = ui.render(Cpu, props);
  assert.equal(find(tree, "ActionButton", "Enable eight-core metrics boot service").disabled, false);
  assert.equal(find(tree, "SliderField", "Temperature limit").value, 80);
  assert.equal(find(tree, "StatusRow", "Logical threads").good, true); // 8 cores, SMT intentionally off
  props.snapshot.cpuUnlock.actions["metrics-enable"].available = false;
  tree = ui.render(Cpu, props);
  assert.equal(find(tree, "ActionButton", "Enable eight-core metrics boot service").disabled, true);
  assert.equal(find(tree, "ActionButton", "Uninstall core unlock and metrics").disabled, false);
  props.snapshot.cpuUnlock.guard = { state: "automatic", currentBoot: true };
  assert.equal(find(ui.render(Cpu, props), "ActionButton", "Uninstall core unlock and metrics").disabled, true);
  delete props.snapshot.cpuUnlock.metrics;
  delete props.snapshot.cpuUnlock.actions["metrics-enable"];
  delete props.snapshot.cpuUnlock.actions.uninstall;
  tree = ui.render(Cpu, props);
  assert.equal(find(tree, "ActionButton", "Uninstall core unlock and metrics").disabled, true);
  assert.equal(find(tree, "StatusRow", "AMDGPU metrics decoder").value, "Unavailable on this backend");
});

test("CPU source updates are confirmed and do not run detection", async () => {
  const calls = [];
  const mutations = [];
  const ui = runtime({ cpuOcAction: async (...args) => calls.push(args) });
  const Cpu = ui.load("tabs/CpuTab.tsx").CpuTab;
  const tree = ui.render(Cpu, { snapshot: cpuFixture(), busy: false, runMutation: (...args) => mutations.push(args) });
  find(tree, "ActionButton", "Update CPU tuning tools").onClick();
  assert.ok(mutations[0][2]);
  assert.equal(calls.length, 0);
  await mutations[0][1]();
  assert.deepEqual(calls[0], ["update", 4000, 1275, 80]);
});

test("old service disables unsupported APIs without blocking older native controls", async () => {
  const oldService = (snapshot) => {
    delete snapshot.toolkit.controlApiVersion;
    delete snapshot.toolkit.controlCapabilities;
    return snapshot;
  };
  const calls = [];
  const mutations = [];
  const runMutation = (...args) => mutations.push(args);
  const gpu = oldService(gpuFixture());
  gpu.gpu.climbMs = 500;
  const editorUi = runtime({ gpuVoltageAction: async () => calls.push("unsupported-curve") });
  const Editor = editorUi.load("tabs/GpuVoltageEditor.tsx").GpuVoltageEditor;
  const props = { snapshot: gpu, busy: false, runMutation };
  let tree = editorUi.render(Editor, props);
  assert.equal(find(tree, "ToggleField", "I understand experimental voltage tuning").disabled, true);
  assert.equal(find(tree, "StatusRow", "350 MHz").value, "700 mV"); // read-only curve survives
  find(tree, "ToggleField", "I understand experimental voltage tuning").onChange(true);
  tree = editorUi.render(Editor, props);
  const curveButton = find(tree, "ActionButton", "Apply voltage curve change");
  assert.equal(curveButton.disabled, true);
  curveButton.onClick();
  assert.match(JSON.stringify(tree), /Update\/reinstall the Decky plugin or control service/);

  const gpuUi = runtime({ resetGpuRamp: async () => calls.push("unsupported-ramp"), setRamp: async (value) => calls.push(["ramp", value]) });
  const Gpu = gpuUi.load("tabs/GpuTab.tsx").GpuTab;
  tree = gpuUi.render(Gpu, props);
  const resetButton = find(tree, "ActionButton", "Reset ramp to toolkit defaults");
  assert.equal(resetButton.disabled, true);
  resetButton.onClick();
  assert.equal(find(tree, "ActionButton", "Apply frequency mode").disabled, false);
  assert.equal(find(tree, "ActionButton", "Apply ramp time").disabled, false);
  assert.equal(find(tree, "ActionButton", "Reset thermal target to 85 °C").disabled, false);
  assert.match(JSON.stringify(tree), /Updating the CLI checkout alone is not enough/);

  const cpu = oldService(cpuFixture());
  delete cpu.cpuUnlock.actions["metrics-enable"];
  delete cpu.cpuUnlock.actions.uninstall;
  const cpuUi = runtime({ cpuOcAction: async (action) => calls.push(["cpu", action]) });
  const Cpu = cpuUi.load("tabs/CpuTab.tsx").CpuTab;
  tree = cpuUi.render(Cpu, { snapshot: cpu, busy: false, runMutation });
  const updateButton = find(tree, "ActionButton", "Update CPU tuning tools");
  assert.equal(updateButton.disabled, true);
  updateButton.onClick();
  assert.equal(find(tree, "ActionButton", "Enable eight-core metrics boot service").disabled, true);
  assert.equal(find(tree, "ActionButton", "Uninstall core unlock and metrics").disabled, true);
  assert.equal(find(tree, "ActionButton", "Apply profile now").disabled, false);
  assert.equal(find(tree, "ActionButton", "Detect stable profile").disabled, false);
  assert.equal(find(tree, "ActionButton", "Run one-time unlock test").disabled, false);
  assert.match(JSON.stringify(tree), /Update\/reinstall the Decky plugin or control service/);
  assert.deepEqual(mutations, []); // even a direct disabled callback cannot schedule unsupported RPCs
  assert.deepEqual(calls, []);
  find(tree, "ActionButton", "Apply profile now").onClick();
  await mutations[0][1]();
  const gpuTree = gpuUi.render(Gpu, props);
  find(gpuTree, "ActionButton", "Apply ramp time").onClick();
  await mutations[1][1]();
  assert.deepEqual(calls, [["cpu", "apply"], ["ramp", 500]]);
});

test("each new mutation requires its own capability, not just an API version", () => {
  const gpu = gpuFixture();
  gpu.toolkit.controlCapabilities = ["gpu-voltage-curve"];
  const ui = runtime();
  const Gpu = ui.load("tabs/GpuTab.tsx").GpuTab;
  const tree = ui.render(Gpu, { snapshot: gpu, busy: false, runMutation() {} });
  assert.equal(find(tree, "ActionButton", "Reset ramp to toolkit defaults").disabled, true);
  const cpu = cpuFixture();
  cpu.toolkit.controlCapabilities = ["gpu-voltage-curve"];
  const cpuUi = runtime();
  const Cpu = cpuUi.load("tabs/CpuTab.tsx").CpuTab;
  assert.equal(find(cpuUi.render(Cpu, { snapshot: cpu, busy: false, runMutation() {} }), "ActionButton", "Update CPU tuning tools").disabled, true);
});

test("CPU uninstall names its full integration scope and calls the agreed uninstall action", async () => {
  const calls = [];
  const mutations = [];
  const ui = runtime({ cpuUnlockAction: async (action) => calls.push(action) });
  const Cpu = ui.load("tabs/CpuTab.tsx").CpuTab;
  const tree = ui.render(Cpu, { snapshot: cpuFixture(), busy: false, runMutation: (...args) => mutations.push(args) });
  find(tree, "ActionButton", "Uninstall core unlock and metrics").onClick();
  assert.equal(mutations[0][2].destructive, true);
  assert.match(mutations[0][2].description, /not a metrics-only uninstall/);
  assert.match(mutations[0][2].description, /full power-off/);
  await mutations[0][1]();
  assert.deepEqual(calls, ["uninstall"]);
});

test("Overview exposes full sensor inventory without substituting stale live temperatures", () => {
  const ui = runtime();
  const Overview = ui.load("tabs/OverviewTab.tsx").OverviewTab;
  const snapshot = { power: { temperatures: [{ device: "cpu", label: "Tctl", celsius: 52 }] } };
  const legacyTree = ui.render(Overview, { snapshot, history: [] });
  assert.equal(find(legacyTree, "StatusRow", "cpu · Tctl").value, "52 °C");
  const liveTree = ui.render(Overview, { snapshot, history: [], sensors: [] });
  assert.equal(nodes(liveTree).some((node) => node.props?.label === "cpu · Tctl"), false);
});

test("the navigation rail has its own scroll viewport for the maintenance tab", () => {
  const ui = runtime();
  const Tabs = ui.load("components/VerticalTabs.tsx").VerticalTabs;
  const tree = ui.render(Tabs, { tabs: [{ id: "maintenance", label: "CLI / Tools", content: "Controls" }], active: "maintenance", onChange() {} });
  assert.equal(nodes(tree).filter((node) => node.type?.name === "ScrollViewport").length, 2);
});

test("CLI catalog exposes every advertised section and confirms risky handoffs", async () => {
  const ids = ["menu", "status", "power", "ram", "swap", "compute", "cpu-unlock", "cec", "storage", "persistence", "wifi-backend", "memory-temperature", "radv", "video-codec", "proton", "manage"];
  const sections = ids.map((id) => ({ id, title: id, description: `${id} toolkit menu`, risk: id === "status" ? "read-only" : id === "manage" ? "maintenance" : "advanced" }));
  const mutations = [];
  const opened = [];
  const ui = runtime({ getCliCatalog: async () => ({ schemaVersion: 1, available: true, reason: null, sections }),
    openCliSection: async (id) => opened.push(id) });
  const Maintenance = ui.load("tabs/MaintenanceTab.tsx").MaintenanceTab;
  const props = { busy: false, runMutation: (...args) => mutations.push(args) };
  ui.render(Maintenance, props);
  await Promise.resolve();
  let tree = ui.render(Maintenance, props);
  for (const id of ids) assert.equal(find(tree, "ActionButton", `Open ${id} in terminal`).disabled, false);
  find(tree, "ActionButton", "Open manage in terminal").onClick();
  assert.equal(mutations[0][2].destructive, true);
  assert.equal(mutations[0][3].refresh, false);
  assert.equal(opened.length, 0);
  await mutations[0][1]();
  assert.deepEqual(opened, ["manage"]);
  tree = ui.render(Maintenance, props);
  assert.ok(JSON.stringify(tree).includes("does not mean its commands have completed"));
  find(tree, "ActionButton", "Open status in terminal").onClick();
  assert.equal(mutations[1][2], undefined);
});

test("CLI discovery unavailability and launch failures are visible and retryable", async () => {
  let available = false;
  const ui = runtime({ getCliCatalog: async () => ({ schemaVersion: 1, available,
    reason: available ? null : "No supported terminal in the graphical user session", sections: [{ id: "power", title: "Power", description: "Setup", risk: "advanced" }] }),
    openCliSection: async () => { throw new Error("Session authorization denied"); } });
  const mutations = [];
  const Maintenance = ui.load("tabs/MaintenanceTab.tsx").MaintenanceTab;
  const props = { busy: false, runMutation: (...args) => mutations.push(args) };
  ui.render(Maintenance, props);
  await Promise.resolve();
  let tree = ui.render(Maintenance, props);
  assert.equal(find(tree, "ActionButton", "Open Power in terminal").disabled, true);
  assert.ok(JSON.stringify(tree).includes("No supported terminal"));
  available = true;
  find(tree, "ActionButton", "Refresh CLI availability").onClick();
  await Promise.resolve();
  tree = ui.render(Maintenance, props);
  find(tree, "ActionButton", "Open Power in terminal").onClick();
  await assert.rejects(mutations[0][1], /authorization denied/);
  assert.ok(JSON.stringify(ui.render(Maintenance, props)).includes("Session authorization denied"));
});

test("new frontend callables retain the agreed typed RPC names", () => {
  const api = fs.readFileSync(path.join(root, "decky-plugin/src/api.ts"), "utf8");
  for (const name of ["gpu_voltage_action", "reset_gpu_ramp", "get_cli_catalog", "open_cli_section"]) assert.ok(api.includes(`>("${name}")`));
  const index = fs.readFileSync(path.join(root, "decky-plugin/src/index.tsx"), "utf8");
  assert.ok(index.includes("historySample(sample)"));
  assert.ok(index.includes("content: <MaintenanceTab"));
});
