import { PanelSection, ToggleField } from "@decky/ui";
import { setHdmiSurround } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { TabProps } from "./shared";

export function AudioTab({ snapshot, busy, runMutation }: TabProps) {
  const { audio } = snapshot;
  const disabled = busy || !audio.controllable;
  const mode = audio.active
    ? "Dolby Digital 5.1"
    : audio.state === "configured"
      ? "Surround configured"
      : audio.state === "not-installed"
        ? "HDMI stereo"
        : audio.state === "incomplete"
          ? "Repair required"
          : "Unavailable";

  if (!audio.available) {
    return (
      <EmptyState>
        Reinstall the latest BC-250 Control plugin to add the trusted HDMI audio helper.
      </EmptyState>
    );
  }

  const toggle = (enabled: boolean) => runMutation(
    enabled ? "HDMI surround enabled" : "HDMI stereo restored",
    () => setHdmiSurround(enabled),
    {
      title: enabled ? "Enable HDMI surround?" : "Restore HDMI stereo?",
      description: enabled
        ? "WirePlumber will restart and switch the AMD HDMI output to real-time Dolby Digital 5.1. This requires an AC-3-capable receiver and the SteamOS audio packages."
        : "WirePlumber will restart, managed AC-3 configuration will be removed, and the default HDMI stereo sink will be selected.",
    },
  );

  return (
    <>
      <PanelSection title="HDMI Audio">
        <StatusRow label="Output mode" value={mode} good={audio.active || audio.state === "not-installed"} />
        <StatusRow
          label="Active profile"
          value={audio.activeProfile}
          good={audio.activeProfile.startsWith("output:hdmi-ac3-surround") || audio.activeProfile === "output:hdmi-stereo"}
        />
        <StatusRow
          label="Update protection"
          value={audio.persistenceState === "installed" ? "Protected" : audio.persistenceState}
          good={audio.persistenceState === "installed" || audio.state === "not-installed"}
        />
      </PanelSection>
      <PanelSection title="Output Selection">
        <ToggleField
          label="HDMI surround"
          description="On: Dolby Digital 5.1 encoding. Off: HDMI stereo."
          checked={audio.enabled}
          disabled={disabled}
          onChange={toggle}
        />
        {audio.state === "configured" && (
          <ActionButton
            label="Retry surround activation"
            disabled={busy}
            onClick={() => toggle(true)}
          />
        )}
        {audio.state === "incomplete" && (
          <EmptyState>
            Managed HDMI audio files are incomplete or foreign. Repair or revert them from the toolkit before using this toggle.
          </EmptyState>
        )}
      </PanelSection>
    </>
  );
}
