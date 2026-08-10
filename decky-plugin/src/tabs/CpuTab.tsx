import { PanelSection, SliderField, ToggleField } from "@decky/ui";
import { useEffect, useState } from "react";
import { cpuOcAction, setCpuMitigations } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { TabProps } from "./shared";

export function CpuTab({ snapshot, busy, runMutation }: TabProps) {
  const { cpu } = snapshot;
  const enabled = cpu.service.enabled === "enabled";
  const detected = cpu.staged?.detected || cpu.installed?.detected || "";
  const detectedValues = detected.match(/(\d+)\s*MHz\s*@\s*(\d+)\s*mV/i);
  const [frequency, setFrequency] = useState(Number(detectedValues?.[1]) || 4000);
  const [voltage, setVoltage] = useState(Number(detectedValues?.[2]) || 1275);
  const [temperature, setTemperature] = useState(90);
  const controlsDisabled =
    busy ||
    !snapshot.toolkit.privileged ||
    !snapshot.toolkit.cpuControlAvailable;
  const profileAvailable = Boolean(cpu.installed || cpu.staged);
  const mitigations = cpu.mitigations || {
    schemaVersion: 1 as const,
    available: false,
    state: "unavailable" as const,
    configuredEnabled: null,
    bootEnabled: null,
    rebootRequired: false,
    protected: false,
  };

  useEffect(() => {
    if (!detectedValues) return;
    setFrequency(Number(detectedValues[1]));
    setVoltage(Number(detectedValues[2]));
  }, [detected]);

  const action = (name: string) =>
    cpuOcAction(name, frequency, voltage, temperature);

  return (
    <>
      <PanelSection title="CPU Overclock">
        <StatusRow
          label="Boot service"
          value={enabled ? "Enabled" : "Disabled"}
          good={enabled}
        />
        <StatusRow label="Live service" value={cpu.service.active} />
        <StatusRow
          label="Detected result"
          value={detected || "Unavailable"}
          good={Boolean(detected)}
        />
      </PanelSection>

      <PanelSection title="CPU Security">
        <ToggleField
          label="CPU security mitigations"
          description={
            mitigations.rebootRequired
              ? `Configured ${mitigations.configuredEnabled ? "enabled" : "disabled"}; reboot required.`
              : `Current boot: ${mitigations.bootEnabled === null ? "unknown" : mitigations.bootEnabled ? "enabled" : "disabled"}.`
          }
          checked={mitigations.configuredEnabled === true}
          disabled={controlsDisabled || !mitigations.available || typeof mitigations.configuredEnabled !== "boolean"}
          onChange={(nextEnabled) =>
            runMutation(
              `CPU mitigations ${nextEnabled ? "enabled" : "disabled"}; reboot required`,
              () => setCpuMitigations(nextEnabled),
              nextEnabled
                ? undefined
                : {
                    title: "Disable CPU security mitigations?",
                    description:
                      "This may improve performance, but reduces protection against processor security vulnerabilities. A reboot is required.",
                    destructive: true,
                  },
            )
          }
        />
        {(mitigations.state === "foreign" || mitigations.state === "incomplete") && (
          <EmptyState>{mitigations.state === "foreign"
            ? "A non-toolkit GRUB source controls mitigations. Remove it manually before using this toggle."
            : "The GRUB source and generated boot configuration disagree. Reapply the setting from the terminal."}</EmptyState>
        )}
      </PanelSection>

      {!snapshot.toolkit.privileged ? (
        <EmptyState>CPU controls require the Decky backend to run as root.</EmptyState>
      ) : !snapshot.toolkit.cpuControlAvailable && (
        <EmptyState>Reinstall the plugin to add the root-owned CPU tuning helper.</EmptyState>
      )}

      <PanelSection title="Detection">
        <SliderField
          label="Target boost clock"
          description="The detector stress-steps toward this clock."
          value={frequency}
          min={3500}
          max={4500}
          step={100}
          valueSuffix=" MHz"
          editableValue
          disabled={controlsDisabled}
          onChange={setFrequency}
        />
        <SliderField
          label="VID safety limit"
          description="Never exceeds the toolkit hard limit of 1325 mV."
          value={voltage}
          min={950}
          max={1325}
          step={25}
          valueSuffix=" mV"
          editableValue
          disabled={controlsDisabled}
          onChange={setVoltage}
        />
        <SliderField
          label="Temperature limit"
          value={temperature}
          min={50}
          max={100}
          step={5}
          valueSuffix=" °C"
          editableValue
          disabled={controlsDisabled}
          onChange={setTemperature}
        />
        <ActionButton
          label="Detect stable profile"
          description="Runs a long CPU stress test and leaves the detected profile active."
          disabled={controlsDisabled}
          onClick={() =>
            runMutation(
              "CPU profile detected",
              () => action("detect"),
              {
                title: "Start CPU overclock detection?",
                description:
                  "Close other applications first. Detection stress-tests each step and can hard-crash an unstable system. Do not power off while it is running.",
                destructive: true,
              },
            )
          }
        />
      </PanelSection>

      <PanelSection title="Profile Actions">
        <ActionButton
          label="Apply profile now"
          disabled={controlsDisabled || !profileAvailable}
          onClick={() => runMutation("CPU profile applied", () => action("apply"))}
        />
        <ActionButton
          label="Enable profile at boot"
          description="Saves the latest detected profile and applies it now."
          disabled={controlsDisabled || !profileAvailable}
          onClick={() =>
            runMutation(
              "CPU profile enabled at boot",
              () => action("enable"),
              {
                title: "Enable CPU profile at boot?",
                description:
                  "Only enable a profile after confirming it is stable. It will be applied on every boot.",
              },
            )
          }
        />
        <ActionButton
          label="Revert to stock"
          description="Disables boot replay and restores the stock 3500 MHz curve."
          disabled={controlsDisabled}
          onClick={() =>
            runMutation(
              "CPU restored to stock",
              () => action("off"),
              {
                title: "Revert CPU tuning to stock?",
                description:
                  "The saved profile is kept, but boot replay is disabled and stock limits are applied now.",
                destructive: true,
              },
            )
          }
        />
      </PanelSection>

      {cpu.installed ? (
        <PanelSection title="Boot Configuration">
          {Object.entries(cpu.installed.values).map(([key, value]) => (
            <StatusRow key={key} label={key.split("_").join(" ")} value={value} />
          ))}
        </PanelSection>
      ) : (
        <EmptyState>Run CPU detection from the toolkit before enabling saved tuning.</EmptyState>
      )}

      {cpu.staged && (
        <PanelSection title="Staged Detection Result">
          <StatusRow label="Result" value={cpu.staged.detected || "Detected profile"} />
          <EmptyState>
            Complete stability testing before enabling this profile at boot.
          </EmptyState>
        </PanelSection>
      )}
    </>
  );
}
