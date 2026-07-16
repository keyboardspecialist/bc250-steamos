import { PanelSection } from "@decky/ui";
import { EmptyState, StatusRow } from "../components/Common";
import type { TabProps } from "./shared";

export function CpuTab({ snapshot }: TabProps) {
  const { cpu } = snapshot;
  const enabled = cpu.service.enabled === "enabled";

  return (
    <>
      <PanelSection title="CPU Tuning">
        <StatusRow
          label="Boot service"
          value={enabled ? "Enabled" : "Disabled"}
          good={enabled}
        />
        <StatusRow label="Live service" value={cpu.service.active} />
        <StatusRow
          label="Detected result"
          value={cpu.installed?.detected || "Unavailable"}
          good={Boolean(cpu.installed?.detected)}
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
            Enable or apply this profile from the toolkit CLI after completing stability testing.
          </EmptyState>
        </PanelSection>
      )}
    </>
  );
}
