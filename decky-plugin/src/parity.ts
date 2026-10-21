import type { GpuMode, HardwareSensor, SafePoint, Snapshot, TelemetrySample, Temperature } from "./types";

export const CONTROL_API_UPDATE_REASON = "The installed backend does not advertise this API. Update/reinstall the Decky plugin or control service, then restart it. Updating the CLI checkout alone is not enough.";

export function controlApiSupports(
  toolkit: Pick<Snapshot["toolkit"], "controlApiVersion" | "controlCapabilities">,
  capability: string,
): boolean {
  const version = toolkit.controlApiVersion;
  return typeof version === "number" && Number.isInteger(version) && version >= 1
    && Array.isArray(toolkit.controlCapabilities) && toolkit.controlCapabilities.includes(capability);
}

// Keep history small: sensor inventories are latest-value data, not chart samples.
export type HistorySample = Pick<TelemetrySample, "cpuClock" | "gpuClock" | "cpuTemp" | "gpuTemp">;
export const finiteReading = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

export function historySample(sample: Partial<TelemetrySample>): HistorySample {
  return {
    cpuClock: finiteReading(sample.cpuClock),
    gpuClock: finiteReading(sample.gpuClock),
    cpuTemp: finiteReading(sample.cpuTemp),
    gpuTemp: finiteReading(sample.gpuTemp),
  };
}

export function temperatureForRole(temperatures: Temperature[], role: "cpu" | "gpu"): number | null {
  // Do not assign anonymous board, memory, or storage temperatures to CPU/GPU.
  const device = role === "cpu" ? /k10temp|cpu/i : /amdgpu|gpu/i;
  const label = role === "cpu" ? /tctl|tdie|cpu|package/i : /gpu|edge|junction/i;
  const matching = temperatures.filter((item) => !/memory|\bmem\b|vram|vrm/i.test(item.label)
    && (device.test(item.device) || label.test(item.label)));
  const preferred = matching.find((item) => label.test(item.label)) ?? matching[0];
  return finiteReading(preferred?.celsius);
}

export function sensorInventory(sensors: HardwareSensor[] | undefined, temperatures: Temperature[]): HardwareSensor[] {
  const result = (sensors ?? []).map((sensor) => ({ ...sensor, value: finiteReading(sensor.value) }));
  for (const [index, temperature] of temperatures.entries()) {
    const present = result.some((sensor) => sensor.device === temperature.device
      && sensor.label === temperature.label && /^(°?C|celsius)$/i.test(sensor.unit));
    if (!present) result.push({
      key: `legacy-temperature-${index}`,
      device: temperature.device,
      label: temperature.label,
      value: finiteReading(temperature.celsius),
      unit: "°C",
    });
  }
  return result;
}

export function sensorValue(sensor: HardwareSensor): string {
  const value = finiteReading(sensor.value);
  return value === null ? "Unavailable" : `${value} ${sensor.unit}`.trim();
}

export function frequencyValid(mode: GpuMode, minimum: number, maximum: number, floor: number, ceiling: number): boolean {
  if (mode === "max" || mode === "adaptive") return true;
  return Number.isInteger(maximum) && maximum >= floor && maximum <= ceiling
    && (mode === "pin" || (Number.isInteger(minimum) && (minimum === 0 || minimum >= floor) && minimum <= maximum));
}

export type VoltageAction = "set" | "add" | "edit" | "remove" | "offset" | "reset";
export const GPU_FREQUENCY_MIN = 350;
export const GPU_FREQUENCY_MAX = 2230;
export const GPU_VOLTAGE_MIN = 700;
export const GPU_VOLTAGE_MAX = 1050;

// Client feedback only. The backend revalidates the entire curve transaction.
export function voltageCurveError(points: SafePoint[], action: VoltageAction, frequency: number, voltage: number, newFrequency: number): string | null {
  if (action === "reset") return null;
  if (points.some((point) => !Number.isInteger(point.frequency) || !Number.isInteger(point.voltage))) {
    return "The current curve is incomplete. Reset it or repair it through the CLI.";
  }
  const current = points.map((point) => ({ frequency: point.frequency as number, voltage: point.voltage as number }));
  const existing = current.find((point) => point.frequency === frequency);
  if ((action === "set" || action === "edit" || action === "remove") && !existing) return "Select an existing curve point.";
  if (action === "add" && existing) return "A point already exists at this frequency; use Set or Edit.";
  let next = current;
  if (action === "offset") {
    if (!Number.isInteger(voltage)) return "Offset must be a whole number of mV.";
    next = current.map((point) => ({ ...point, voltage: point.voltage + voltage }));
  } else if (action === "remove") {
    next = current.filter((point) => point.frequency !== frequency);
  } else {
    const target = action === "edit" ? newFrequency : frequency;
    if (!Number.isInteger(target) || target < GPU_FREQUENCY_MIN || target > GPU_FREQUENCY_MAX) return "Frequency must be 350-2230 MHz (whole numbers).";
    if (!Number.isInteger(voltage)) return "Voltage must be a whole number of mV.";
    next = [...current.filter((point) => action === "add" || point.frequency !== frequency), { frequency: target, voltage }];
  }
  next.sort((left, right) => left.frequency - right.frequency);
  if (next.length < 2) return "Keep at least two curve points.";
  for (const [index, point] of next.entries()) {
    if (point.frequency < GPU_FREQUENCY_MIN || point.frequency > GPU_FREQUENCY_MAX) return "All frequencies must remain within 350-2230 MHz.";
    if (point.voltage < GPU_VOLTAGE_MIN || point.voltage > GPU_VOLTAGE_MAX) return "All voltages must remain within 700-1050 mV.";
    if (index > 0 && next[index - 1].frequency === point.frequency) return "Curve frequencies must be unique.";
    if (index > 0 && next[index - 1].voltage > point.voltage) return "Voltage must not decrease as frequency increases.";
  }
  return null;
}
