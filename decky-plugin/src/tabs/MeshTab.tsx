import { ButtonItem, PanelSection, PanelSectionRow, Spinner } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import { getMeshStatus } from "../api";
import { EmptyState, StatusRow } from "../components/Common";
import type { MeshStatus } from "../types";

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "The action failed.";
}

export function MeshTab() {
  const [status, setStatus] = useState<MeshStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const mounted = useRef(true);

  const refresh = async () => {
    setLoading(true);
    try {
      const next = await getMeshStatus();
      if (mounted.current) {
        setStatus(next);
        setError("");
      }
    } catch (caught) {
      if (mounted.current) setError(errorMessage(caught));
    } finally {
      if (mounted.current) setLoading(false);
    }
  };

  useEffect(() => {
    mounted.current = true;
    void refresh();
    return () => {
      mounted.current = false;
    };
  }, []);

  if (loading && !status) {
    return <PanelSection><PanelSectionRow><Spinner /></PanelSectionRow></PanelSection>;
  }

  if (!status) {
    return (
      <>
        <EmptyState>{error || "Unable to load GFX1013 runtime status."}</EmptyState>
        <PanelSection><PanelSectionRow><ButtonItem layout="below" onClick={() => void refresh()}>Retry</ButtonItem></PanelSectionRow></PanelSection>
      </>
    );
  }

  return (
    <>
      <PanelSection title="GFX1013 Compute + Mesh">
        <StatusRow label="Kernel repair" value={status.kernelReady ? "Active" : "Not active"} good={status.kernelReady} />
        <StatusRow label="RADV runtime" value={status.runtimeState} good={status.runtimeState === "ready"} />
        <StatusRow label="Global activation" value={status.globalEnabled ? "Enabled" : "Disabled"} good={status.globalEnabled} />
        <StatusRow label="Mesa" value={status.mesaVersion ?? "Not installed"} />
        <StatusRow label="Alternate ICD" value={status.icdPath || "Unavailable"} good={status.runtimeState === "ready"} />
      </PanelSection>

      {error && <EmptyState>{error}</EmptyState>}
      {!status.scriptAvailable && <EmptyState>The GFX1013 toolkit script is unavailable.</EmptyState>}
      {!status.kernelReady && <EmptyState>Patch AMDGPU and reboot before installing the global alternate RADV runtime.</EmptyState>}
      {status.runtimeState === "not-installed" && <EmptyState>Run the GFX1013 setup from the toolkit menu. It enables the alternate ICD for the complete user session.</EmptyState>}
      {status.runtimeState === "invalid" && <EmptyState>The alternate runtime failed validation or requires migration. Run setup again from the toolkit menu.</EmptyState>}
      {status.globalEnabled && <EmptyState>The patched RADV ICD is active across this user session.</EmptyState>}
      {status.restartRequired && <EmptyState>The global driver is configured but this graphical session has not inherited it. Sign out and back in.</EmptyState>}
      {status.games.length > 0 && <EmptyState>Legacy per-game records remain for: {status.games.map((game) => game.name).join(", ")}. Remove their old Steam launch options, then run bc250-mesh-shader.sh legacy-clear.</EmptyState>}

      <PanelSection>
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => void refresh()} disabled={loading}>
            {loading ? "Refreshing..." : "Refresh status"}
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    </>
  );
}
