import { PanelSection } from "@decky/ui";
import { EmptyState, StatusRow } from "../components/Common";
import type { HardwareSensor, Snapshot } from "../types";
import { historySample, sensorInventory, sensorValue, temperatureForRole, type HistorySample } from "../parity";
import { PowerTab } from "./PowerTab";

export type { HistorySample } from "../parity";

export function snapshotSample(snapshot: Snapshot): HistorySample {
  const temperatures = snapshot.power.temperatures ?? [];
  const gpuTemp = temperatureForRole(temperatures, "gpu");
  const cpuTemp = temperatureForRole(temperatures, "cpu");

  return historySample({
    cpuClock: snapshot.power.cpuCurrentMhz,
    gpuClock: snapshot.gpu.activeMhz,
    cpuTemp,
    gpuTemp,
  });
}

function HistoryChart({
  title,
  values,
  color,
  unit,
  floor = 0,
  compact = false,
}: {
  title: string;
  values: Array<number | null>;
  color: string;
  unit: string;
  floor?: number;
  compact?: boolean;
}) {
  const present = values.filter((value): value is number => typeof value === "number" && Number.isFinite(value));
  const current = values[values.length - 1];
  const maximum = present.length > 0 ? Math.max(...present) : floor + 1;
  const minimum = present.length > 0 ? Math.min(...present) : floor;
  const ceiling = Math.max(maximum, floor + 1);
  const width = 300;
  const height = compact ? 38 : 56;
  const sampleCount = 36;
  const firstIndex = sampleCount - Math.min(values.length, sampleCount);
  const pointY = (value: number) =>
    Math.max(
      3,
      Math.min(
        height - 3,
        height - 3 - ((value - floor) / (ceiling - floor)) * (height - 8),
      ),
    );
  let path = "";
  let segmentStarted = false;
  const visibleValues = values.slice(-sampleCount);
  visibleValues.forEach((value, index) => {
    if (value === null || !Number.isFinite(value)) {
      segmentStarted = false;
      return;
    }
    const x = ((firstIndex + index) / (sampleCount - 1)) * width;
    const y = pointY(value);
    path += `${segmentStarted ? " L" : " M"} ${x.toFixed(1)} ${y.toFixed(1)}`;
    segmentStarted = true;
  });
  const singleIndex = present.length === 1
    ? visibleValues.findIndex((value) => value !== null)
    : -1;
  const singlePoint = singleIndex >= 0
    ? {
        x: ((firstIndex + singleIndex) / (sampleCount - 1)) * width,
        y: pointY(present[0]),
      }
    : null;

  return (
    <div
      style={{
        flex: compact ? "1 1 135px" : "1 1 280px",
        minWidth: 0,
        padding: compact ? "10px 12px 8px" : "14px 16px 12px",
        border: "1px solid rgba(255,255,255,.09)",
        borderRadius: 8,
        background: "rgba(255,255,255,.035)",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          justifyContent: "space-between",
          gap: 12,
          marginBottom: compact ? 5 : 8,
        }}
      >
        <span style={{ color: "#b8bfc6", fontSize: 12 }}>{title}</span>
        <span style={{ color: "#fff", fontSize: compact ? 14 : 18, fontWeight: 700 }}>
          {current === undefined || current === null ? "–" : Math.round(current)} {unit}
        </span>
      </div>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        preserveAspectRatio="none"
        style={{ display: "block", width: "100%", height }}
        aria-label={`${title} history`}
      >
        <line
          x1="0"
          y1={height - 1}
          x2={width}
          y2={height - 1}
          stroke="rgba(255,255,255,.12)"
        />
        {path && (
          <>
            <path
              d={path}
              fill="none"
              stroke={color}
              strokeWidth={compact ? 3 : 2.5}
              strokeLinecap="round"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
            />
            {singlePoint && (
              <circle cx={singlePoint.x} cy={singlePoint.y} r="3" fill={color} />
            )}
          </>
        )}
      </svg>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          marginTop: compact ? 3 : 5,
          color: "#7f8992",
          fontSize: 10,
        }}
      >
        <span>{present.length > 1 ? `${Math.round(minimum)} min` : "Collecting"}</span>
        <span>{present.length > 1 ? `${Math.round(maximum)} max` : "1 s samples"}</span>
      </div>
    </div>
  );
}

export function OverviewSummary({
  snapshot,
  history,
  compact = false,
}: {
  snapshot: Snapshot;
  history: HistorySample[];
  compact?: boolean;
}) {
  const latest = snapshotSample(snapshot);
  const gpuGovernorReady = snapshot.gpu.dbusReady;
  const cpuProfileEnabled = snapshot.cpu.service.enabled === "enabled";
  const topology = snapshot.cpuUnlock;

  return (
    <>
      <PanelSection title={compact ? "System summary" : "System Overview"}>
        <StatusRow
          label="Compute units"
          value={
            snapshot.cu.available
              ? `${snapshot.cu.total}/${snapshot.cu.maximum}`
              : "Unavailable"
          }
          good={snapshot.cu.available}
        />
        <StatusRow
          label="CPU OC profile"
          value={
            cpuProfileEnabled
              ? "Enabled at boot"
              : snapshot.cpu.installed || snapshot.cpu.staged
                ? "Available, not enabled"
                : "Not configured"
          }
          good={cpuProfileEnabled}
        />
        <StatusRow
          label="GPU governor"
          value={
            gpuGovernorReady
              ? "Active · D-Bus ready"
              : snapshot.power.governor.active === "active"
                ? "Active · D-Bus unavailable"
                : snapshot.power.governor.active
          }
          good={gpuGovernorReady}
        />
        <StatusRow
          label="CPU core topology"
          value={
            topology.topologyState === "unavailable"
              ? "Unavailable"
              : `${topology.physicalCores} cores / ${topology.logicalThreads} threads (${topology.topologyState})`
          }
          good={topology.topologyState === "unlocked"}
        />
      </PanelSection>

      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          gap: compact ? 8 : 12,
          padding: compact ? "0 4px 10px" : "0 8px 12px",
        }}
      >
        <HistoryChart
          title="Peak CPU clock"
          values={history.map((sample) => sample.cpuClock)}
          color="#60a5fa"
          unit="MHz"
          compact={compact}
        />
        <HistoryChart
          title="GPU clock"
          values={history.map((sample) => sample.gpuClock)}
          color="#a78bfa"
          unit="MHz"
          compact={compact}
        />
        <HistoryChart
          title="CPU temperature"
          values={history.map((sample) => sample.cpuTemp)}
          color="#34d399"
          unit="°C"
          floor={20}
          compact={compact}
        />
        <HistoryChart
          title="GPU temperature"
          values={history.map((sample) => sample.gpuTemp)}
          color="#fb923c"
          unit="°C"
          floor={20}
          compact={compact}
        />
      </div>

      {history.length === 0 && (
        <PanelSection title="Live Values">
          <StatusRow
            label="Peak CPU clock"
            value={latest.cpuClock === null ? "Unavailable" : `${latest.cpuClock} MHz`}
          />
          <StatusRow
            label="GPU clock"
            value={latest.gpuClock === null ? "Unavailable" : `${latest.gpuClock} MHz`}
          />
          <StatusRow label="CPU temperature (snapshot)" value={latest.cpuTemp === null ? "Unavailable" : `${latest.cpuTemp} °C`} />
          <StatusRow label="GPU temperature (snapshot)" value={latest.gpuTemp === null ? "Unavailable" : `${latest.gpuTemp} °C`} />
        </PanelSection>
      )}
    </>
  );
}

export function OverviewTab({
  snapshot,
  history,
  sensors,
}: {
  snapshot: Snapshot;
  history: HistorySample[];
  sensors?: HardwareSensor[];
}) {
  // An explicit live inventory (even []) supersedes older snapshot readings.
  const inventory = sensorInventory(sensors ?? snapshot.power.sensors,
    sensors === undefined ? snapshot.power.temperatures ?? [] : []);
  return (
    <>
      <OverviewSummary snapshot={snapshot} history={history} />
      <PowerTab snapshot={snapshot} />
      <PanelSection title="All Hardware Sensors">
        <StatusRow label="Source" value={sensors !== undefined ? "Latest telemetry" : "Status snapshot (10 s refresh)"} />
        <EmptyState>Driver-reported labels and units are shown as provided. Board, memory, and storage temperatures are not substituted for CPU or GPU temperature. Missing sensors are unavailable, not zero.</EmptyState>
        {inventory.length === 0 && <EmptyState>No readable hwmon sensors were reported. CPU metrics installation and memory-temperature setup are available in CPU and Maintenance / CLI.</EmptyState>}
        {inventory.map((sensor, index) => (
          <StatusRow key={`${sensor.key}-${index}`} label={`${sensor.device} · ${sensor.label || sensor.key}`}
            value={sensorValue(sensor)} />
        ))}
      </PanelSection>
    </>
  );
}
