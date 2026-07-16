import { DropdownItem, PanelSection, SliderField } from "@decky/ui";
import { useEffect, useState } from "react";
import { setGpuFrequency, setLoadTarget, setRamp } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { GpuMode } from "../types";
import type { TabProps } from "./shared";

const modeOptions = [
  { data: "adaptive", label: "Adaptive" },
  { data: "range", label: "Adaptive range" },
  { data: "pin", label: "Pinned frequency" },
  { data: "max", label: "Maximum curve point" },
];

export function GpuTab({ snapshot, busy, runMutation }: TabProps) {
  const { gpu } = snapshot;
  const initialMax = gpu.maximum || gpu.configuredMax || 1500;
  const [mode, setMode] = useState<GpuMode>(gpu.mode);
  const [minimum, setMinimum] = useState(gpu.minimum || 0);
  const [maximum, setMaximum] = useState(initialMax);
  const [rampMs, setRampMs] = useState(gpu.climbMs || 500);
  const frequencyDisabled = busy || !gpu.controllable;
  const frequencyMaximum = Math.min(gpu.allowedMaximum || 2150, 2150);
  const frequencyMinimum = Math.max(gpu.allowedMinimum || 100, 100);

  useEffect(() => {
    setMode(gpu.mode);
    setMinimum(gpu.minimum || 0);
    setMaximum(gpu.maximum || gpu.configuredMax || 1500);
    setRampMs(gpu.climbMs || 500);
  }, [gpu.mode, gpu.minimum, gpu.maximum, gpu.configuredMax, gpu.climbMs]);

  if (!gpu.available) {
    return <EmptyState>Install the GPU governor through `bc250-power.sh governor`.</EmptyState>;
  }

  const applyFrequency = () =>
    runMutation(
      "GPU frequency updated",
      () => setGpuFrequency(mode, minimum, maximum),
      mode === "pin" || mode === "max"
        ? {
            title: "Apply sustained GPU clocks?",
            description: "Pinned or maximum clocks increase heat and power. Thermal throttling remains active.",
          }
        : undefined,
    );

  return (
    <>
      <PanelSection title="Live GPU">
        <StatusRow
          label="Active clock"
          value={gpu.activeMhz ? `${gpu.activeMhz} MHz` : "Unavailable"}
        />
        <StatusRow label="Requested mode" value={gpu.mode} />
        <StatusRow
          label="Boot replay"
          value={gpu.persistent ? "Enabled" : "Pending setup"}
          good={gpu.persistent}
        />
        <StatusRow
          label="Configured ceiling"
          value={gpu.configuredMax ? `${gpu.configuredMax} MHz` : "Curve maximum"}
        />
      </PanelSection>

      <PanelSection title="Frequency">
        <DropdownItem
          label="Mode"
          rgOptions={modeOptions}
          selectedOption={mode}
          disabled={frequencyDisabled}
          onChange={(option) => setMode(option.data as GpuMode)}
        />
        {mode === "range" && (
          <SliderField
            label="Minimum"
            value={minimum}
            min={0}
            max={frequencyMaximum}
            step={50}
            valueSuffix=" MHz"
            editableValue
            disabled={frequencyDisabled}
            onChange={setMinimum}
          />
        )}
        {(mode === "range" || mode === "pin") && (
          <SliderField
            label={mode === "pin" ? "Pinned clock" : "Maximum"}
            value={maximum}
            min={frequencyMinimum}
            max={frequencyMaximum}
            step={50}
            valueSuffix=" MHz"
            editableValue
            disabled={frequencyDisabled}
            onChange={setMaximum}
          />
        )}
        {!gpu.controllable && (
          <EmptyState>Start the GPU governor before changing live frequency mode.</EmptyState>
        )}
        <ActionButton
          label="Apply frequency mode"
          disabled={frequencyDisabled}
          onClick={applyFrequency}
        />
      </PanelSection>

      <PanelSection title="Load Response">
        <StatusRow
          label="Current target"
          value={
            gpu.loadUpper !== null && gpu.loadLower !== null
              ? `${Math.round(gpu.loadUpper * 100)} / ${Math.round(gpu.loadLower * 100)}%`
              : "Unavailable"
          }
        />
        <ActionButton
          label="Eager preset"
          description="60/45%; helps light or frame-capped games leave idle clocks."
          disabled={busy}
          onClick={() =>
            runMutation("Eager load target applied", () => setLoadTarget("eager"))
          }
        />
        <ActionButton
          label="Balanced preset"
          description="80/65%; restores the toolkit defaults."
          disabled={busy}
          onClick={() =>
            runMutation("Balanced load target applied", () => setLoadTarget("reset"))
          }
        />
      </PanelSection>

      <PanelSection title="Ramp">
        <SliderField
          label="Idle-to-max climb"
          value={rampMs}
          min={200}
          max={5000}
          step={100}
          valueSuffix=" ms"
          editableValue
          disabled={busy}
          onChange={setRampMs}
        />
        <ActionButton
          label="Apply ramp time"
          disabled={busy}
          onClick={() =>
            runMutation("GPU ramp updated", () => setRamp(rampMs))
          }
        />
      </PanelSection>

      <PanelSection title="Voltage Curve">
        {gpu.safePoints.map((point, index) => (
          <StatusRow
            key={`${point.frequency}-${index}`}
            label={point.frequency ? `${point.frequency} MHz` : `Point ${index + 1}`}
            value={point.voltage ? `${point.voltage} mV` : "Unavailable"}
          />
        ))}
      </PanelSection>
    </>
  );
}
