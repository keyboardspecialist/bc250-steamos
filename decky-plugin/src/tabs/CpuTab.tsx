import { PanelSection, SliderField, ToggleField } from "@decky/ui";
import { useEffect, useState } from "react";
import { cpuOcAction, cpuUnlockAction, setCpuMitigations, setCpuSmtDisabled } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import { CONTROL_API_UPDATE_REASON, controlApiSupports } from "../parity";
import type { CpuUnlockAction } from "../types";
import type { TabProps } from "./shared";

export function CpuTab({ snapshot, busy, runMutation }: TabProps) {
  const { cpu } = snapshot;
  const enabled = cpu.service.enabled === "enabled";
  const detected = cpu.staged?.detected || cpu.installed?.detected || "";
  const detectedValues = detected.match(/(\d+)\s*MHz\s*@\s*(\d+)\s*mV/i);
  const profile = cpu.staged ?? cpu.installed;
  const profileFrequency = Number(detectedValues?.[1] ?? profile?.values.frequency) || 4000;
  const profileTemperature = Number(profile?.values.max_temperature) || 90;
  const [frequency, setFrequency] = useState(profileFrequency);
  const [voltage, setVoltage] = useState(Number(detectedValues?.[2]) || 1275);
  const [temperature, setTemperature] = useState(profileTemperature);
  const controlsDisabled =
    busy ||
    !snapshot.toolkit.privileged ||
    !snapshot.toolkit.cpuControlAvailable;
  const updateApiSupported = controlApiSupports(snapshot.toolkit, "cpu-oc-update");
  const updateDisabled = controlsDisabled || !updateApiSupported;
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
  const smt = cpu.smt || {
    available: false,
    state: "unavailable" as const,
    configuredDisabled: null,
    liveDisabled: null,
    liveState: "unavailable" as const,
    protected: false,
  };
  const unlock = snapshot.cpuUnlock;
  const automaticRebootPending =
    unlock.guard.state === "automatic" && unlock.guard.currentBoot;
  const unlockControlsDisabled = busy || !snapshot.toolkit.privileged || automaticRebootPending;
  const detectionValid = Number.isInteger(frequency) && frequency >= 3500 && frequency <= 4500
    && Number.isInteger(voltage) && voltage >= 950 && voltage <= 1325
    && Number.isInteger(temperature) && temperature >= 50 && temperature <= 100;

  const unlockReason = (name: CpuUnlockAction) => {
    const actionState = unlock.actions[name];
    if (!actionState) return "This backend does not provide this action. Update/reinstall the Decky plugin or control service.";
    if (actionState.blockers.length > 0) {
      return `Blocked: ${actionState.blockers
        .map((blocker) => blocker.split("-").join(" "))
        .join(", ")}.`;
    }
    return actionState.hint || actionState.message;
  };

  const runUnlock = (
    name: CpuUnlockAction,
    label: string,
    title: string,
    description: string,
  ) => runMutation(label, () => cpuUnlockAction(name), {
    title,
    description,
    destructive: true,
  });

  useEffect(() => {
    setFrequency(profileFrequency);
    setVoltage(Number(detectedValues?.[2]) || 1275);
    setTemperature(profileTemperature);
  }, [detected, profileFrequency, profileTemperature]);

  const action = (name: string) =>
    cpuOcAction(name, frequency, voltage, temperature);

  return (
    <>
      <PanelSection title="CPU Topology and Core Unlock">
        <StatusRow
          label="Physical cores"
          value={unlock.physicalCores}
          good={unlock.physicalCores >= 8}
        />
        <StatusRow
          label="Logical threads"
          value={unlock.logicalThreads}
          good={unlock.logicalThreads >= unlock.physicalCores && unlock.physicalCores > 0}
        />
        <StatusRow
          label="Topology"
          value={unlock.topologyState.split("-").join(" ")}
          good={unlock.topologyState === "unlocked"}
        />
        {unlock.ccxGroups.map((group) => (
          <StatusRow
            key={group.ccxId}
            label={`CCX ${group.ccxId}`}
            value={`Cores ${group.cores.map((core) => core.coreId).join(", ")}`}
          />
        ))}
        <StatusRow
          label="Persistent method"
          value={unlock.mode.split("-").join(" ")}
          good={unlock.mode === "linux-replay" || unlock.mode === "efi"}
        />
        <StatusRow
          label="Linux replay service"
          value={`${unlock.linuxReplay.service.enabled} / ${unlock.linuxReplay.service.active}`}
        />
        {(unlock.mode === "conflict" || unlock.mode === "partial" || automaticRebootPending) && (
          <EmptyState>
            {automaticRebootPending
              ? "An automatic core-unlock reboot is pending; controls are temporarily disabled."
              : unlock.message || "Core-unlock installation is conflicting or incomplete. Disable it to recover verified toolkit-owned state."}
          </EmptyState>
        )}
        <ActionButton
          label="Run one-time unlock test"
          description={unlockReason("test")}
          disabled={unlockControlsDisabled || !unlock.actions.test.available}
          onClick={() => runUnlock(
            "test",
            "CPU core-unlock test started",
            "Test disabled CPU cores?",
            "Disabled cores may be defective. Linux discovers added cores only after a warm reboot. Instability or data loss is possible.",
          )}
        />
        <ActionButton
          label="Enable standard Linux method"
          description={unlockReason("enable")}
          disabled={unlockControlsDisabled || !unlock.actions.enable.available}
          onClick={() => runUnlock(
            "enable",
            "Standard CPU core unlock enabled",
            "Enable standard Linux core unlock?",
            "Only persist cores after stability testing. Each cold power-on boots Linux once to apply the mask, then warm-reboots into Linux.",
          )}
        />
        <ActionButton
          label="Enable EFI preboot method"
          description={unlockReason("efi-enable")}
          disabled={unlockControlsDisabled || !unlock.actions["efi-enable"].available}
          onClick={() => runUnlock(
            "efi-enable",
            "EFI CPU core unlock enabled",
            "Enable experimental EFI core unlock?",
            "This installs an unsigned EFI image and changes firmware boot order. Secure Boot is unsupported and firmware recovery may be required.",
          )}
        />
        <ActionButton
          label="Disable core unlock"
          description={unlockReason("off")}
          disabled={unlockControlsDisabled || !unlock.actions.off.available}
          onClick={() => runUnlock(
            "off",
            "CPU core unlock disabled",
            "Disable CPU core unlock?",
            "Persistent unlock state will be removed. Fully power off to restore the factory core mask for the next boot.",
          )}
        />
      </PanelSection>

      <PanelSection title="CPU Metrics Compatibility">
        <StatusRow label="AMDGPU metrics decoder" value={unlock.metrics?.state ?? "Unavailable on this backend"} />
        <StatusRow label="Metrics service" value={unlock.metrics
          ? `${unlock.metrics.service.enabled} / ${unlock.metrics.service.active}` : "Unavailable"} />
        <StatusRow label="Metrics revision" value={unlock.metrics?.revision ?? "Unknown / not installed"} />
        <EmptyState>{unlock.metrics?.message
          || "Eight-core SMU metrics need a matching AMDGPU decoder. Update the backend to inspect compatibility; do not assume missing readings are zero."}</EmptyState>
        <ActionButton label="Enable eight-core metrics boot service" description={unlockReason("metrics-enable")}
          disabled={unlockControlsDisabled || !unlock.actions["metrics-enable"]?.available}
          onClick={() => runUnlock("metrics-enable", "Eight-core metrics service enabled; reboot required", "Enable eight-core SMU metrics at boot?",
            "Requires eight active physical cores. Installs the toolkit metrics payload and enables its boot service. A matching AMDGPU metrics decoder is a separate requirement: use the toolkit AMDGPU fixes if compatibility is not confirmed. Reboot before relying on corrected telemetry. The backend rechecks action availability and the core-unlock reboot guard.")}
        />
        <ActionButton label="Uninstall core unlock and metrics" description={unlockReason("uninstall")}
          disabled={unlockControlsDisabled || !unlock.actions.uninstall?.available}
          onClick={() => runUnlock("uninstall", "Core unlock and metrics integration removed; full power-off required", "Uninstall core unlock and metrics integration?",
            "This removes toolkit-owned Linux/EFI core-unlock integration, helper files, pending state, and the metrics boot service/payload. It does not remove AMDGPU fixes or CPU overclock profiles. Active extra cores remain until a full power-off restores the factory mask. This is not a metrics-only uninstall.")}
        />
      </PanelSection>

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

      <PanelSection title="CPU Threading">
        <ToggleField
          label="Disable SMT at boot"
          description="Applies immediately and persists at boot; cache-sensitive games may perform better with one thread per core."
          checked={smt.configuredDisabled === true}
          disabled={controlsDisabled || !smt.available || typeof smt.configuredDisabled !== "boolean"}
          onChange={(disabled) =>
            runMutation(
              `SMT ${disabled ? "disabled" : "enabled"}`,
              () => setCpuSmtDisabled(disabled),
            )
          }
        />
        <StatusRow
          label="Current state"
          value={smt.liveState}
          good={typeof smt.liveDisabled === "boolean" && smt.liveDisabled === smt.configuredDisabled}
        />
        {(smt.state === "foreign" || smt.state === "incomplete") && (
          <EmptyState>{smt.state === "foreign"
            ? "A non-toolkit systemd unit controls SMT. Remove it manually before using this toggle."
            : "The SMT boot unit is installed but not enabled. Reapply the setting."}</EmptyState>
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
          disabled={controlsDisabled || !detectionValid}
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
        <ActionButton label="Update CPU tuning tools" description="Refreshes pinned CPU tuning sources and safety patches; does not run detection."
          disabled={updateDisabled}
          onClick={() => {
            if (updateDisabled) return;
            runMutation("CPU tuning tools updated", () => action("update"), {
              title: "Update CPU tuning tools?",
              description: "Downloads the toolkit-pinned CPU overclock sources and reapplies its safety patches. Existing tuning configuration is retained.",
            });
          }} />
        {!updateApiSupported && <EmptyState>CPU tuning tool update: {CONTROL_API_UPDATE_REASON}</EmptyState>}
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
          {Object.entries(cpu.staged.values).map(([key, value]) => (
            <StatusRow key={key} label={key.split("_").join(" ")} value={value} />
          ))}
          <EmptyState>
            Complete stability testing before enabling this profile at boot.
          </EmptyState>
        </PanelSection>
      )}
    </>
  );
}
