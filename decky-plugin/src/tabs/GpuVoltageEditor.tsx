import { DropdownItem, PanelSection, SliderField, ToggleField } from "@decky/ui";
import { useEffect, useState } from "react";
import { gpuVoltageAction } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import {
  GPU_FREQUENCY_MAX, GPU_FREQUENCY_MIN, GPU_VOLTAGE_MAX, GPU_VOLTAGE_MIN,
  CONTROL_API_UPDATE_REASON, controlApiSupports,
  voltageCurveError, type VoltageAction,
} from "../parity";
import type { TabProps } from "./shared";

const actions: Array<{ data: VoltageAction; label: string }> = [
  { data: "set", label: "Set point voltage" },
  { data: "add", label: "Add point" },
  { data: "edit", label: "Move / edit point" },
  { data: "remove", label: "Remove point" },
  { data: "offset", label: "Offset entire curve" },
  { data: "reset", label: "Reset toolkit curve" },
];

export function GpuVoltageEditor({ snapshot, busy, runMutation }: TabProps) {
  const points = snapshot.gpu.safePoints;
  const [acknowledged, setAcknowledged] = useState(false);
  const [action, setAction] = useState<VoltageAction>("set");
  const [frequency, setFrequency] = useState(points[0]?.frequency ?? 350);
  const [newFrequency, setNewFrequency] = useState(frequency);
  const [voltage, setVoltage] = useState(points[0]?.voltage ?? 700);
  const [offset, setOffset] = useState(-25);
  const signature = JSON.stringify(points);
  const unavailable = !snapshot.toolkit.privileged || !snapshot.toolkit.cpuControlAvailable || !snapshot.gpu.available;
  const voltageApiSupported = controlApiSupports(snapshot.toolkit, "gpu-voltage-curve");
  const disabled = busy || unavailable || !voltageApiSupported || !acknowledged;
  const existingAction = action === "set" || action === "edit" || action === "remove";
  const pointOptions = points.filter((point) => point.frequency !== null).map((point) => ({
    data: point.frequency as number,
    label: `${point.frequency} MHz · ${point.voltage ?? "?"} mV`,
  }));

  const selectPoint = (value: number) => {
    setFrequency(value);
    setNewFrequency(value);
    setVoltage(points.find((point) => point.frequency === value)?.voltage ?? 700);
  };

  useEffect(() => {
    if (existingAction) selectPoint(points.find((point) => point.frequency === frequency)?.frequency ?? points[0]?.frequency ?? 350);
  }, [signature]);

  const changeAction = (next: VoltageAction) => {
    setAction(next);
    if (next === "add") {
      setFrequency(1200);
      setVoltage(850);
    } else if (next === "set" || next === "edit" || next === "remove") {
      selectPoint(points[0]?.frequency ?? 350);
    }
  };
  const error = voltageCurveError(points, action, frequency, action === "offset" ? offset : voltage, newFrequency);
  // Unused RPC positions must be zero, not stale editor values.
  const args: [VoltageAction, number, number, number] = action === "reset"
    ? [action, 0, 0, 0]
    : action === "offset" ? [action, 0, offset, 0]
      : action === "remove" ? [action, frequency, 0, 0]
        : [action, frequency, voltage, action === "edit" ? newFrequency : 0];
  const summary = action === "reset"
    ? "Restore 350/700, 1000/800, 1500/900, 2000/1000, 2230/1000 (MHz/mV)."
    : action === "offset" ? `Shift every point by ${offset > 0 ? "+" : ""}${offset} mV.`
      : action === "remove" ? `Remove the ${frequency} MHz point.`
        : `${action === "edit" ? `${frequency} → ${newFrequency}` : frequency} MHz at ${voltage} mV (${action}).`;

  return (
    <PanelSection title="Voltage Curve · Experimental">
      {points.map((point, index) => (
        <StatusRow key={`${point.frequency}-${index}`}
          label={point.frequency === null ? `Point ${index + 1}` : `${point.frequency} MHz`}
          value={point.voltage === null ? "Unavailable" : `${point.voltage} mV`} />
      ))}
      {points.length === 0 && <EmptyState>No voltage curve is available. Reset requires a working governor configuration.</EmptyState>}
      <ToggleField
        label="I understand experimental voltage tuning"
        description="Changes persist and may restart the governor. Undervolting or overclocking can cause artifacts, hangs, data loss, or hardware damage. Test stability before gaming."
        checked={acknowledged}
        disabled={busy || unavailable || !voltageApiSupported}
        onChange={setAcknowledged}
      />
      {!voltageApiSupported && <EmptyState>GPU voltage editing: {CONTROL_API_UPDATE_REASON}</EmptyState>}
      {unavailable && <EmptyState>Voltage editing requires the privileged backend, trusted power/CPU helper, and a governor configuration. Reinstall the plugin to repair its helper, or see Maintenance / CLI for governor setup.</EmptyState>}
      <DropdownItem label="Curve action" rgOptions={actions} selectedOption={action}
        disabled={disabled} onChange={(option) => changeAction(option.data as VoltageAction)} />
      {existingAction && pointOptions.length > 0 && (
        <DropdownItem label="Existing point" rgOptions={pointOptions} selectedOption={frequency}
          disabled={disabled} onChange={(option) => selectPoint(Number(option.data))} />
      )}
      {(action === "add" || action === "edit") && (
        <SliderField label={action === "edit" ? "New frequency" : "Frequency"}
          value={action === "edit" ? newFrequency : frequency}
          min={GPU_FREQUENCY_MIN} max={GPU_FREQUENCY_MAX} step={1} valueSuffix=" MHz" editableValue
          disabled={disabled} onChange={action === "edit" ? setNewFrequency : setFrequency} />
      )}
      {(action === "set" || action === "add" || action === "edit") && (
        <SliderField label="Voltage" value={voltage} min={GPU_VOLTAGE_MIN} max={GPU_VOLTAGE_MAX}
          step={1} valueSuffix=" mV" editableValue disabled={disabled} onChange={setVoltage} />
      )}
      {action === "offset" && (
        <SliderField label="Whole-curve offset" description="Every resulting point must stay within 700-1050 mV."
          value={offset} min={-350} max={350} step={1} valueSuffix=" mV" editableValue
          disabled={disabled} onChange={setOffset} />
      )}
      {error && <EmptyState>{error}</EmptyState>}
      <ActionButton label="Apply voltage curve change" description={summary} disabled={disabled || Boolean(error)}
        onClick={() => {
          if (disabled || error) return;
          runMutation("GPU voltage curve updated", () => gpuVoltageAction(...args), {
            title: "Apply experimental GPU voltage change?",
            description: `${summary} This persists the curve and may restart the governor. I accept the risk of instability, data loss, and hardware damage. The backend validates bounds and curve ordering again.`,
            destructive: true,
          });
        }} />
    </PanelSection>
  );
}
