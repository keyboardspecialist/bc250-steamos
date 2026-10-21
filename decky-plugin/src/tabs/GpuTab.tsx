import { DropdownItem, PanelSection, SliderField } from "@decky/ui";
import { useEffect, useState } from "react";
import {
  setCustomLoadTarget,
  setGpuFrequency,
  setLoadTarget,
  setRamp,
  resetGpuRamp,
  setTemperatureTarget,
} from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { GpuMode } from "../types";
import { CONTROL_API_UPDATE_REASON, controlApiSupports, frequencyValid as validFrequency } from "../parity";
import { GpuVoltageEditor } from "./GpuVoltageEditor";
import type { TabProps } from "./shared";

const modeOptions = [
  { data: "adaptive", label: "Adaptive" },
  { data: "range", label: "Custom range / overclock" },
  { data: "pin", label: "Pinned frequency" },
  { data: "max", label: "Maximum curve point" },
];

export function GpuTab({ snapshot, busy, runMutation }: TabProps) {
  const { gpu } = snapshot;
  // Zero in saved frequency state is a sentinel, not a valid clock setting.
  const initialMax = gpu.requestedMaximum || gpu.configuredMax || gpu.initialMaximum || gpu.maximum || 1500;
  const savedMode = gpu.requestedMode ?? gpu.mode;
  const savedMinimum = gpu.requestedMinimum ?? gpu.minimum ?? 0;
  const [mode, setMode] = useState<GpuMode>(savedMode);
  const [minimum, setMinimum] = useState(savedMinimum);
  const [maximum, setMaximum] = useState(initialMax);
  const [rampMs, setRampMs] = useState(gpu.climbMs ?? 500);
  const [loadMinimum, setLoadMinimum] = useState(
    Math.round((gpu.loadLower ?? 0.65) * 100),
  );
  const [loadMaximum, setLoadMaximum] = useState(
    Math.round((gpu.loadUpper ?? 0.80) * 100),
  );
  const [temperatureTarget, setTemperatureTargetValue] = useState(
    gpu.temperatureTarget ?? 85,
  );
  const frequencyDisabled = busy || !snapshot.toolkit.privileged || !gpu.controllable;
  const rampResetSupported = controlApiSupports(snapshot.toolkit, "gpu-ramp-reset");
  const rampResetDisabled = frequencyDisabled || !snapshot.toolkit.cpuControlAvailable || !rampResetSupported;
  const frequencyMaximum = Math.min(gpu.allowedMaximum ?? 2230, 2230);
  const frequencyMinimum = Math.max(gpu.allowedMinimum ?? 350, 350);
  const frequencyValid = validFrequency(mode, minimum, maximum, frequencyMinimum, frequencyMaximum);
  const loadValid = Number.isInteger(loadMinimum) && Number.isInteger(loadMaximum)
    && loadMinimum >= 5 && loadMaximum <= 99 && loadMinimum < loadMaximum;

  useEffect(() => {
    setMode(savedMode);
    setMinimum(savedMinimum);
    setMaximum(initialMax);
  }, [savedMode, savedMinimum, initialMax]);
  useEffect(() => { setRampMs(gpu.climbMs ?? 500); }, [gpu.climbMs]);
  useEffect(() => { setLoadMinimum(Math.round((gpu.loadLower ?? 0.65) * 100)); }, [gpu.loadLower]);
  useEffect(() => { setLoadMaximum(Math.round((gpu.loadUpper ?? 0.80) * 100)); }, [gpu.loadUpper]);
  useEffect(() => { setTemperatureTargetValue(gpu.temperatureTarget ?? 85); }, [gpu.temperatureTarget]);

  if (!gpu.available) {
    return <EmptyState>Install the GPU governor through `bc250-power.sh governor`.</EmptyState>;
  }

  const applyFrequency = () =>
    runMutation(
      "GPU frequency updated",
      () => setGpuFrequency(mode, minimum, maximum),
      mode === "pin" || mode === "max" || (mode === "range" && (minimum > 0 || maximum > 1500))
        ? {
            title: "Apply advanced GPU clocks?",
            description: "Pinned, raised-floor, maximum, or overclocked ranges increase heat and power and may be unstable. Thermal throttling remains active. Confirm stability before persisting high clocks.",
          }
        : undefined,
    );

  return (
    <>
      <PanelSection title="Live GPU">
        <StatusRow
          label="Active clock"
          value={gpu.activeMhz === null ? "Unavailable" : `${gpu.activeMhz} MHz`}
        />
        <StatusRow
          label="Governor service"
          value={`${gpu.governorService.enabled} / ${gpu.governorService.active}`}
          good={
            gpu.governorService.enabled === "enabled" &&
            gpu.governorService.active === "active"
          }
        />
        <StatusRow label="Live mode" value={gpu.mode} good={gpu.dbusReady} />
        <StatusRow
          label="Saved replay"
          value={
            gpu.requestedMode === "range"
              ? `${gpu.requestedMinimum}-${gpu.requestedMaximum} MHz`
              : gpu.requestedMode === "pin"
                ? `${gpu.requestedMaximum} MHz pinned`
                : gpu.requestedMode
          }
        />
        <StatusRow
          label="Live range"
          value={
            gpu.liveMinimum !== null && gpu.liveMaximum !== null
              ? `${gpu.liveMinimum}-${gpu.liveMaximum} MHz`
              : "D-Bus unavailable"
          }
          good={gpu.dbusReady}
        />
        <StatusRow
          label="Boot replay"
          value={
            !gpu.persistent
              ? "Pending setup"
              : gpu.replayApplied
                ? "Applied"
                : "Enabled, not live"
          }
          good={gpu.persistent && gpu.replayApplied}
        />
        <StatusRow
          label="Adaptive ceiling"
          value={gpu.configuredMax === null ? "Curve maximum" : `${gpu.configuredMax} MHz`}
        />
        <StatusRow
          label="Loaded ceiling"
          value={gpu.initialMaximum === null ? "Unavailable" : `${gpu.initialMaximum} MHz`}
          good={
            gpu.configuredMax === null ||
            gpu.initialMaximum === gpu.configuredMax
          }
        />
      </PanelSection>

      <PanelSection title="Frequency">
        <EmptyState>Mode inputs show the saved request; live mode and range are reported above. Applying a mode saves it for boot replay. 0 MHz minimum means no requested floor, not a live 0 MHz clock.</EmptyState>
        <DropdownItem
          label="Mode"
          rgOptions={modeOptions}
          selectedOption={mode}
          disabled={frequencyDisabled}
          onChange={(option) => setMode(option.data as GpuMode)}
        />
        {(mode === "adaptive" || mode === "range") && (
          <SliderField
            label="Minimum clock"
            value={minimum}
            min={0}
            max={frequencyMaximum}
            step={50}
            valueSuffix=" MHz"
            editableValue
            disabled={frequencyDisabled}
            onChange={(value) => {
              setMinimum(value);
              setMode("range");
            }}
          />
        )}
        {mode !== "max" && (
          <SliderField
            label={mode === "pin" ? "Pinned clock" : "Maximum clock"}
            value={maximum}
            min={frequencyMinimum}
            max={frequencyMaximum}
            step={50}
            valueSuffix=" MHz"
            editableValue
            disabled={frequencyDisabled}
            onChange={(value) => {
              setMaximum(value);
              if (mode === "adaptive") setMode("range");
            }}
          />
        )}
        {!gpu.controllable && (
          <EmptyState>
            {!snapshot.toolkit.privileged
              ? "GPU controls require the Decky backend to run as root."
              : "Start the GPU governor before changing live frequency mode."}
          </EmptyState>
        )}
        {!frequencyValid && <EmptyState>Use whole MHz within {frequencyMinimum}-{frequencyMaximum}. A range minimum can also be 0 and must not exceed its maximum.</EmptyState>}
        <ActionButton
          label="Apply frequency mode"
          disabled={frequencyDisabled || !frequencyValid}
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
          description="40/10%; ramps aggressively for light or frame-capped games."
          disabled={busy || !gpu.controllable}
          onClick={() =>
            runMutation("Eager load target applied", () => setLoadTarget("eager"))
          }
        />
        <ActionButton
          label="Balanced preset"
          description="80/65%; restores the toolkit defaults."
          disabled={busy || !gpu.controllable}
          onClick={() =>
            runMutation("Balanced load target applied", () => setLoadTarget("reset"))
          }
        />
        <SliderField
          label="Minimum load"
          description="Clock down when GPU load falls below this threshold."
          value={loadMinimum}
          min={5}
          max={99}
          step={1}
          valueSuffix="%"
          editableValue
          disabled={busy || !gpu.controllable}
          onChange={setLoadMinimum}
        />
        <SliderField
          label="Maximum load"
          description="Clock up when GPU load rises above this threshold."
          value={loadMaximum}
          min={5}
          max={99}
          step={1}
          valueSuffix="%"
          editableValue
          disabled={busy || !gpu.controllable}
          onChange={setLoadMaximum}
        />
        {!loadValid && (
          <EmptyState>Choose whole percentages from 5-99%; minimum must be lower than maximum.</EmptyState>
        )}
        <ActionButton
          label="Apply custom load target"
          disabled={
            frequencyDisabled || !loadValid
          }
          onClick={() =>
            runMutation(
              "Custom load target applied",
              () => setCustomLoadTarget(loadMinimum, loadMaximum),
            )
          }
        />
      </PanelSection>

      <PanelSection title="Thermal Target">
        <StatusRow label="Current throttle / recovery" value={gpu.temperatureTarget === null || gpu.temperatureRecovery === null
          ? "Unavailable" : `${gpu.temperatureTarget} / ${gpu.temperatureRecovery} °C`} />
        <SliderField
          label="Throttle temperature"
          description={`Recovery is set to ${temperatureTarget - 10} C to prevent rapid cycling.`}
          value={temperatureTarget}
          min={50}
          max={100}
          step={1}
          valueSuffix=" C"
          editableValue
          disabled={frequencyDisabled}
          onChange={setTemperatureTargetValue}
        />
        <ActionButton
          label="Apply thermal target"
          disabled={frequencyDisabled || !Number.isInteger(temperatureTarget) || temperatureTarget < 50 || temperatureTarget > 100}
          onClick={() =>
            runMutation("GPU thermal target updated", () =>
              setTemperatureTarget(temperatureTarget),
            )
          }
        />
        <ActionButton label="Reset thermal target to 85 °C" disabled={frequencyDisabled}
          onClick={() => runMutation("GPU thermal target reset", () => setTemperatureTarget(85))} />
      </PanelSection>

      <PanelSection title="Ramp">
        <StatusRow label="Current climb time" value={gpu.climbMs === null ? "Unavailable" : `${gpu.climbMs} ms`} />
        <StatusRow label="Adjust interval" value={gpu.adjustMicros === null ? "Unavailable" : `${gpu.adjustMicros} µs`} />
        <StatusRow label="Normal rate / down events" value={`${gpu.rampNormal ?? "Unavailable"} / ${gpu.downEvents ?? "Unavailable"}`} />
        <SliderField
          label="Idle-to-max climb"
          value={rampMs}
          min={200}
          max={5000}
          step={100}
          valueSuffix=" ms"
          editableValue
          disabled={busy || !gpu.controllable}
          onChange={setRampMs}
        />
        <ActionButton
          label="Apply ramp time"
          description="Restarts the governor and reapplies saved frequency mode."
          disabled={frequencyDisabled || !Number.isInteger(rampMs) || rampMs < 200 || rampMs > 5000}
          onClick={() =>
            runMutation("GPU ramp updated", () => setRamp(rampMs))
          }
        />
        <ActionButton label="Reset ramp to toolkit defaults" description="Restores interval, normal/burst rates, and down-event defaults; restarts the governor."
          disabled={rampResetDisabled}
          onClick={() => {
            if (rampResetDisabled) return;
            runMutation("GPU ramp defaults restored", () => resetGpuRamp(), {
              title: "Reset GPU ramp behavior?",
              description: "The governor will restart with the toolkit default ramp timing, then restore the saved frequency mode.",
            });
          }} />
        {!rampResetSupported && <EmptyState>GPU ramp reset: {CONTROL_API_UPDATE_REASON}</EmptyState>}
      </PanelSection>

      <GpuVoltageEditor snapshot={snapshot} busy={busy} runMutation={runMutation} />
    </>
  );
}
