import { PanelSection } from "@decky/ui";
import { StatusRow } from "../components/Common";
import type { Snapshot } from "../types";

export function PowerTab({ snapshot }: { snapshot: Snapshot }) {
  const { power } = snapshot;
  const governorEnabled = power.governor.enabled === "enabled";
  const relevantTemps = power.temperatures
    .filter((temp) => /edge|junction|tctl|cpu|gpu/i.test(`${temp.device} ${temp.label}`))
    .slice(0, 4);

  return (
    <>
      <PanelSection title="Power Health">
        <StatusRow
          label="ACPI C/P-states"
          value={power.acpiActive ? "Active" : "Reboot or setup needed"}
          good={power.acpiActive}
        />
        <StatusRow
          label="CPU governor"
          value={power.cpuGovernor || "Unavailable"}
          good={power.cpuGovernor === "schedutil"}
        />
        <StatusRow
          label="CPU clock"
          value={power.cpuCurrentMhz ? `${power.cpuCurrentMhz} MHz` : "Unavailable"}
        />
        <StatusRow label="Idle states" value={`${power.cStates} states`} good={power.cStates >= 3} />
        <StatusRow
          label="GPU governor"
          value={
            power.governor.active !== "active"
              ? power.governor.active
              : snapshot.gpu.dbusReady
                ? "Active · D-Bus ready"
                : "Active · D-Bus unavailable"
          }
          good={power.governor.active === "active" && snapshot.gpu.dbusReady}
        />
      </PanelSection>

      {relevantTemps.length > 0 && (
        <PanelSection title="Temperatures">
          {relevantTemps.map((temperature) => (
            <StatusRow
              key={`${temperature.device}-${temperature.label}`}
              label={temperature.label}
              value={`${temperature.celsius.toFixed(1)} °C`}
              good={temperature.celsius < 85}
            />
          ))}
        </PanelSection>
      )}

      <PanelSection title="Boot Behavior">
        <StatusRow
          label="Adaptive GPU governor"
          value={governorEnabled ? "Enabled" : "Disabled"}
          good={governorEnabled}
        />
        <StatusRow
          label="Frequency replay"
          value={power.frequencyRestore.enabled}
          good={power.frequencyRestore.enabled === "enabled"}
        />
      </PanelSection>
    </>
  );
}
