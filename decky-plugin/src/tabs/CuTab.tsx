import { PanelSection } from "@decky/ui";
import { EmptyState, StatusRow } from "../components/Common";
import type { TabProps } from "./shared";

export function CuTab({ snapshot }: TabProps) {
  const { cu } = snapshot;
  const bootEnabled = cu.service.enabled === "enabled";

  return (
    <>
      <PanelSection title="Compute Units">
        <StatusRow
          label="Live routing"
          value={cu.available ? `${cu.total}/${cu.maximum} CU` : "Unavailable"}
          good={cu.available}
        />
        <StatusRow
          label="Boot replay"
          value={bootEnabled ? "Enabled" : "Disabled"}
          good={bootEnabled}
        />
        <StatusRow
          label="Update protection"
          value={cu.protected ? "Protected" : "Pending"}
          good={cu.protected}
        />
      </PanelSection>

      {cu.available ? (
        <PanelSection title="WGP Routing">
          <div style={{ padding: "4px 12px 10px" }}>
            {cu.rows.map((row) => (
              <div
                key={`${row.se}-${row.sh}`}
                style={{
                  display: "grid",
                  gridTemplateColumns: "64px repeat(5, 1fr) 42px",
                  gap: 4,
                  alignItems: "center",
                  marginBottom: 6,
                  fontSize: 11,
                }}
              >
                <span style={{ color: "#aeb3b8" }}>SE{row.se}.SH{row.sh}</span>
                {row.wgps.map((enabled, index) => (
                  <span
                    key={index}
                    style={{
                      padding: "4px 0",
                      borderRadius: 4,
                      textAlign: "center",
                      background: enabled ? "rgba(89,209,133,.24)" : "rgba(255,255,255,.06)",
                      color: enabled ? "#7be5a1" : "#777f86",
                    }}
                  >
                    {index}
                  </span>
                ))}
                <span style={{ textAlign: "right" }}>{row.cus}/10</span>
              </div>
            ))}
          </div>
        </PanelSection>
      ) : (
        <EmptyState>{cu.liveReason || "Live CU routing is unavailable."}</EmptyState>
      )}

      <PanelSection title="Boot Behavior">
        <StatusRow
          label="Saved table"
          value={cu.savedMasks.length === 4 ? "Available" : "Unavailable"}
          good={cu.savedMasks.length === 4}
        />
        <EmptyState>
          Change CU routing and boot replay from the toolkit CLI, where the harvest-map safety checks are available.
        </EmptyState>
      </PanelSection>
    </>
  );
}
