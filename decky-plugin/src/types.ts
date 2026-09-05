export interface ServiceState {
  enabled: string;
  active: string;
}

export interface CuRow {
  se: number;
  sh: number;
  spi: number | null;
  cc: number | null;
  wgps: boolean[];
  cus: number;
  factoryCuMask: number | null;
  factoryWgps: boolean[];
}

export interface CuStatus {
  available: boolean;
  controllable: boolean;
  liveReason: string | null;
  total: number;
  maximum: number;
  rows: CuRow[];
  savedMasks: number[];
  factoryMapAvailable: boolean;
  factoryTotal: number | null;
  service: ServiceState;
  protected: boolean;
}

export interface Temperature {
  device: string;
  label: string;
  celsius: number;
}

export interface TelemetrySample {
  cpuClock: number | null;
  gpuClock: number | null;
  cpuTemp: number | null;
  gpuTemp: number | null;
}

export interface PowerStatus {
  acpiActive: boolean;
  cStates: number;
  cpuGovernor: string;
  cpuCurrentMhz: number | null;
  governor: ServiceState;
  acpiService: ServiceState;
  cpufreqService: ServiceState;
  frequencyRestore: ServiceState;
  temperatures: Temperature[];
  protected: boolean;
}

export interface SafePoint {
  frequency: number | null;
  voltage: number | null;
}

export type GpuMode = "adaptive" | "max" | "pin" | "range";

export interface GpuStatus {
  available: boolean;
  controllable: boolean;
  dbusReady: boolean;
  mode: GpuMode;
  requestedMode: GpuMode;
  requestedMinimum: number;
  requestedMaximum: number;
  minimum: number;
  maximum: number;
  liveMinimum: number | null;
  liveMaximum: number | null;
  initialMinimum: number | null;
  initialMaximum: number | null;
  activeMhz: number | null;
  levels: string[];
  allowedMinimum: number | null;
  allowedMaximum: number | null;
  climbMs: number | null;
  governorService: ServiceState;
  frequencyRestore: ServiceState;
  persistent: boolean;
  replayApplied: boolean;
  safePoints: SafePoint[];
  configuredMax: number | null;
  loadUpper: number | null;
  loadLower: number | null;
  temperatureTarget: number | null;
  temperatureRecovery: number | null;
  adjustMicros: number | null;
  rampNormal: number | null;
  downEvents: number | null;
}

export interface CpuConfig {
  values: Record<string, string>;
  detected: string;
}

export interface CpuStatus {
  service: ServiceState;
  installed: CpuConfig | null;
  staged: CpuConfig | null;
  toolAvailable: boolean;
  mitigations: {
    schemaVersion: 1;
    available: boolean;
    state: "enabled" | "disabled" | "foreign" | "incomplete" | "unavailable";
    configuredEnabled: boolean | null;
    bootEnabled: boolean | null;
    rebootRequired: boolean;
    protected: boolean;
  };
}

export interface CpuUnlockActionStatus {
  available: boolean;
  blockers: string[];
  hint?: string;
  message?: string;
}

export interface CpuCore {
  packageId: number;
  coreId: number;
  logicalCpus: number[];
  ccxId: number | null;
}

export interface CpuUnlockStatus {
  schemaVersion: 1;
  devicePresent: boolean;
  physicalCores: number;
  logicalThreads: number;
  topologyState: "locked" | "unlocked" | "unexpected" | "unavailable";
  cores: CpuCore[];
  ccxGroups: Array<{
    ccxId: number;
    cores: CpuCore[];
  }>;
  ccxAvailable: boolean;
  helperInstalled: boolean;
  licenseInstalled: boolean;
  unitInstalled: boolean;
  helperBundleAvailable: boolean;
  service: ServiceState;
  updatePersistence: boolean;
  guard: {
    state: "clear" | "manual" | "automatic" | "unavailable";
    active: boolean;
    currentBoot: boolean;
  };
  mode: "none" | "temporary" | "linux-replay" | "efi" | "conflict" | "partial";
  linuxReplay: {
    installed: boolean;
    enabled: boolean;
    service: ServiceState;
    updatePersistence: boolean;
  };
  efi: {
    installed: boolean;
    partial: boolean;
    bootEntry: {
      present: boolean;
      active: boolean;
      matching: boolean;
      firstInBootOrder: boolean;
      effective: boolean;
      queryAvailable: boolean;
    };
  };
  actions: Record<"test" | "enable" | "efi-enable" | "off", CpuUnlockActionStatus>;
  message?: string;
}

export interface RamStatus {
  schemaVersion: 1;
  available: boolean;
  toolState: "verified" | "invalid" | "not-installed";
  toolVersion: string | null;
  umaLastRequestedMiB: number | null;
  ttmState: "configured" | "foreign" | "default";
  ttmConfiguredPages: number | null;
  ttmBootPages: number | null;
  ttmLivePages: number | null;
  rebootRequired: boolean;
  protected: boolean;
}

export interface CecStatus {
  devicePresent: boolean;
  service: ServiceState;
  osdName: string | null;
  wakeTv: boolean | null;
  suspendTv: boolean | null;
  allowStandby: boolean | null;
  uinput: boolean | null;
  active: boolean | null;
  physicalAddress: number | null;
  audioLogicalAddress: number | null;
  poweroffIntegration: boolean;
  sleepIntegration: boolean;
  protected: boolean;
}

export interface HdmiAudioStatus {
  available: boolean;
  controllable: boolean;
  state: "active" | "configured" | "not-installed" | "incomplete" | "unavailable";
  enabled: boolean;
  active: boolean;
  udevState: "installed" | "missing" | "foreign";
  wireplumberState: "installed" | "missing" | "foreign";
  persistenceState: "installed" | "missing" | "foreign";
  activeProfile: string;
}

export interface MeshGame {
  executable: string;
  name: string;
}

export interface MeshStatus {
  scriptAvailable: boolean;
  runtimeState: "ready" | "not-installed" | "invalid";
  mesaVersion: string | null;
  icdPath: string;
  configValid: boolean;
  kernelReady: boolean;
  schedulerConfigured: boolean;
  schedulerActive: boolean;
  globalEnabled: boolean;
  restartRequired: boolean;
  fsr4State: "ready" | "not-installed" | "invalid";
  fsr4IcdPath: string;
  fsr4RunnerPath: string;
  error: string | null;
  games: MeshGame[];
}

export interface Snapshot {
  toolkit: {
    available: boolean;
    privileged: boolean;
    powerAvailable: boolean;
    cpuControlAvailable: boolean;
    cecAvailable: boolean;
    ramControlAvailable: boolean;
    audioAvailable: boolean;
    path: string;
  };
  cu: CuStatus;
  power: PowerStatus;
  gpu: GpuStatus;
  cpu: CpuStatus;
  cpuUnlock: CpuUnlockStatus;
  ram: RamStatus;
  cec: CecStatus;
  audio: HdmiAudioStatus;
}
