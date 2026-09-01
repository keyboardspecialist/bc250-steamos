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
        <EmptyState>{error || "Unable to load Mesa / RADV runtime status."}</EmptyState>
        <PanelSection><PanelSectionRow><ButtonItem layout="below" onClick={() => void refresh()}>Retry</ButtonItem></PanelSectionRow></PanelSection>
      </>
    );
  }

  return (
    <>
      <PanelSection title="Mesa / RADV Async Compute">
        <StatusRow label="Patched AMDGPU" value={status.kernelReady ? "Installed and active" : "Not ready"} good={status.kernelReady} />
        <StatusRow label="Scheduler policy" value={status.schedulerActive ? "Active" : status.schedulerConfigured ? "Reboot required" : "Disabled"} good={status.schedulerActive} />
        <StatusRow label="RADV runtime" value={status.runtimeState} good={status.runtimeState === "ready"} />
        <StatusRow label="Global activation" value={status.globalEnabled ? "Enabled" : "Disabled"} good={status.globalEnabled} />
        <StatusRow label="Mesa" value={status.mesaVersion ?? "Not installed"} />
        <StatusRow label="Alternate ICD" value={status.icdPath || "Unavailable"} good={status.runtimeState === "ready"} />
        <StatusRow label="Private FSR4 profile" value={status.fsr4State} good={status.fsr4State === "ready"} />
        <StatusRow label="FSR4 runner" value={status.fsr4RunnerPath} good={status.fsr4State === "ready"} />
      </PanelSection>

      {error && <EmptyState>{error}</EmptyState>}
      {!status.scriptAvailable && <EmptyState>The Mesa / RADV toolkit script is unavailable.</EmptyState>}
      {!status.kernelReady && <EmptyState>Install the AMDGPU kernel fixes and reboot before installing the Mesa / RADV async-compute patch.</EmptyState>}
      {status.runtimeState === "not-installed" && <EmptyState>The Mesa / RADV patch enables GFX1013 async compute. Install it from Drivers after the patched AMDGPU module is active; the build usually takes 3-5 minutes.</EmptyState>}
      {status.runtimeState === "invalid" && <EmptyState>The alternate runtime failed validation or requires migration. Run setup again from the toolkit menu.</EmptyState>}
      {status.fsr4State === "invalid" && <EmptyState>The private FSR4 runtime failed integrity validation. Reinstall or remove it from the toolkit.</EmptyState>}
      {status.globalEnabled && <EmptyState>The patched RADV ICD is active across this user session.</EmptyState>}
      {status.restartRequired && !status.schedulerActive && <EmptyState>Reboot to activate amdgpu.sched_policy=2 and patched RADV together.</EmptyState>}
      {status.restartRequired && status.schedulerActive && <EmptyState>The global driver is configured but this graphical session has not inherited it. Sign out and back in.</EmptyState>}
      {status.games.length > 0 && <EmptyState>Migration records from the older per-game workflow remain for: {status.games.map((game) => game.name).join(", ")}. Remove MESA_DRICONF_EXECUTABLE_OVERRIDE and VK_ICD_FILENAMES from their Steam launch options, then run bc250-mesh-shader.sh legacy-clear.</EmptyState>}

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
