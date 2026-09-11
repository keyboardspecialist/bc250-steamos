import { ButtonItem, PanelSection, PanelSectionRow, Spinner, TextField, ToggleField } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import { getFsr4Inventory, getMeshStatus, installFsr4Dll, uninstallFsr4Dll } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { Fsr4Inventory, Fsr4Target, MeshStatus } from "../types";
import type { MutationRunner } from "./shared";

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "The action failed.";
}

export function MeshTab({ busy, runMutation }: { busy: boolean; runMutation: MutationRunner }) {
  const [status, setStatus] = useState<MeshStatus | null>(null);
  const [inventory, setInventory] = useState<Fsr4Inventory | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [search, setSearch] = useState("");
  const mounted = useRef(true);

  const refresh = async () => {
    setLoading(true);
    try {
      const failures: string[] = [];
      await Promise.all([
        getMeshStatus().then((next) => {
          if (mounted.current) setStatus(next);
        }).catch((caught) => failures.push(errorMessage(caught))),
        getFsr4Inventory().then((next) => {
          if (mounted.current) setInventory(next);
        }).catch((caught) => failures.push(errorMessage(caught))),
      ]);
      if (mounted.current) setError(failures.join(" "));
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

  const toggleTarget = (target: Fsr4Target, enabled: boolean) => {
    const action = enabled ? installFsr4Dll : uninstallFsr4Dll;
    runMutation(
      enabled ? "FSR4 RC8 installed" : "Original game DLL restored",
      async () => {
        try {
          await action(target.targetId);
        } finally {
          await refresh();
        }
      },
      {
        title: enabled ? "Install FSR4 RC8 for this game?" : "Restore the original game DLL?",
        description: enabled
          ? `Close the game first. The toolkit will replace ${target.relativePath || target.targetPath || "the selected DLL"} and retain an exact rollback copy.`
          : `Close the game first. The toolkit will restore the exact original bytes for ${target.relativePath || target.targetPath || "this target"} and remove its rollback record.`,
        destructive: true,
      },
      { refresh: false },
    );
  };

  const query = search.trim().toLocaleLowerCase();
  const visibleGames = (inventory?.games ?? [])
    .filter((game) => !query || game.name.toLocaleLowerCase().includes(query) || game.appId.includes(query))
    .slice(0, 100);
  const targetToggle = (target: Fsr4Target, label: string, gameReady = true) => {
    const managed = target.state === "ready" || target.state === "upgrade-required";
    const integrityBlocked = target.state === "modified" || target.state === "invalid";
    const undiscoverableInstall = target.state === "restored" && !target.discovered;
    const disabled = busy || !gameReady || integrityBlocked || target.state === "missing" || undiscoverableInstall;
    const description = `${target.relativePath || target.targetPath || "Unknown target"} | ${target.state}${target.release ? ` | ${target.release}` : ""}${gameReady ? "" : " | Steam install/update incomplete"}${undiscoverableInstall ? " | target not found during scan" : ""}`;
    return (
      <div key={target.targetId}>
        <ToggleField
          label={label}
          description={description}
          checked={managed}
          disabled={disabled}
          onChange={(enabled) => toggleTarget(target, enabled)}
        />
        {target.state === "upgrade-required" && (
          <ActionButton label="Update this target" disabled={busy || !gameReady || !target.discovered} onClick={() => toggleTarget(target, true)} />
        )}
        {target.state === "missing" && (
          <ActionButton label="Restore missing original DLL" disabled={busy || !gameReady} onClick={() => toggleTarget(target, false)} />
        )}
      </div>
    );
  };

  const gameManager = (
    <>
      <PanelSection title="FSR4 RC8 Game Manager">
        <TextField
          label="Installed Steam games"
          description={inventory ? `${inventory.games.length} installed games | ${inventory.currentRelease ?? "helper unavailable"}` : "Loading Steam inventory"}
          value={search}
          disabled={loading || !inventory}
          onChange={(event) => setSearch(event.target.value)}
        />
        {!inventory && loading && <PanelSectionRow><Spinner /></PanelSectionRow>}
        {!inventory && !loading && (
          <EmptyState>{error || "Unable to load the Steam game inventory."}</EmptyState>
        )}
        {inventory && !inventory.available && (
          <EmptyState>{inventory.currentRelease
            ? "Steam library metadata is unavailable. Start Steam once, then refresh the game list."
            : inventory.errors[0] || "The FSR4 helper is unavailable."}</EmptyState>
        )}
        {inventory && visibleGames.map((game) => (
          <div key={game.appKey}>
            {game.targets.length === 0 ? (
              <StatusRow
                label={game.name}
                value={!game.installPresent
                  ? "Install unavailable"
                  : game.scanState === "truncated" || game.scanState === "partial"
                    ? "Scan incomplete"
                    : "Compatible DLL not detected"}
              />
            ) : game.targets.map((target, index) => targetToggle(
              target,
              game.targets.length === 1 ? game.name : `${game.name} | target ${index + 1}`,
              game.fullyInstalled && game.installPresent,
            ))}
          </div>
        ))}
        {inventory && inventory.games.length > 100 && !query && (
          <EmptyState>Showing the first 100 games. Search by game name or Steam app ID.</EmptyState>
        )}
        {inventory && visibleGames.length === 0 && (
          <EmptyState>No installed Steam games match this search.</EmptyState>
        )}
      </PanelSection>

      {inventory && inventory.orphanedTargets.length > 0 && (
        <PanelSection title="Unassociated FSR4 Targets">
          {inventory.orphanedTargets.map((target) => (
            <div key={target.targetId}>
              <StatusRow label={target.targetPath || "Invalid rollback record"} value={target.state} />
              <ActionButton
                label="Restore original DLL"
                disabled={busy || target.state === "modified" || target.state === "invalid"}
                onClick={() => toggleTarget(target, false)}
              />
            </div>
          ))}
        </PanelSection>
      )}
      {inventory && inventory.errors.length > 0 && (
        <EmptyState>{inventory.errors.join(" ")}</EmptyState>
      )}
    </>
  );

  if (loading && !status && !inventory) {
    return <PanelSection><PanelSectionRow><Spinner /></PanelSectionRow></PanelSection>;
  }

  if (!status) {
    return (
      <>
        <EmptyState>{error || "Unable to load Mesa / RADV runtime status."}</EmptyState>
        {gameManager}
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
        <StatusRow label="FSR4 RC8 game DLLs" value={`${status.fsr4DllState} (${status.fsr4DllInstallCount})`} good={status.fsr4DllState === "ready"} />
        <StatusRow label="Legacy FSR4 V3 profile" value={status.fsr4State} good={status.fsr4State === "ready"} />
        <StatusRow label="Legacy FSR4 runner" value={status.fsr4RunnerPath} good={status.fsr4State === "ready"} />
      </PanelSection>

      {error && <EmptyState>{error}</EmptyState>}
      {!status.scriptAvailable && <EmptyState>The Mesa / RADV toolkit script is unavailable.</EmptyState>}
      {!status.kernelReady && <EmptyState>Install the AMDGPU kernel fixes and reboot before installing the Mesa / RADV async-compute patch.</EmptyState>}
      {status.runtimeState === "not-installed" && <EmptyState>The Mesa / RADV patch enables GFX1013 async compute. Install it from Drivers after the patched AMDGPU module is active; the build usually takes 3-5 minutes.</EmptyState>}
      {status.runtimeState === "invalid" && <EmptyState>The alternate runtime failed validation or requires migration. Run setup again from the toolkit menu.</EmptyState>}
      {status.fsr4DllState === "invalid" && <EmptyState>A game-local FSR4 DLL failed integrity validation. Restore it with the toolkit before making further changes.</EmptyState>}
      {status.fsr4State === "invalid" && <EmptyState>The legacy private FSR4 runtime failed integrity validation. Reinstall or remove it from the toolkit.</EmptyState>}
      {status.globalEnabled && <EmptyState>The patched RADV ICD is active across this user session.</EmptyState>}
      {status.restartRequired && !status.schedulerActive && <EmptyState>Reboot to activate amdgpu.sched_policy=2 and patched RADV together.</EmptyState>}
      {status.restartRequired && status.schedulerActive && <EmptyState>The global driver is configured but this graphical session has not inherited it. Sign out and back in.</EmptyState>}
      {status.games.length > 0 && <EmptyState>Migration records from the older per-game workflow remain for: {status.games.map((game) => game.name).join(", ")}. Remove MESA_DRICONF_EXECUTABLE_OVERRIDE and VK_ICD_FILENAMES from their Steam launch options, then run bc250-mesh-shader.sh legacy-clear.</EmptyState>}

      {gameManager}

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
