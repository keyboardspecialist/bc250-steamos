import { ButtonItem, DropdownItem, PanelSection, PanelSectionRow, Spinner, TextField, ToggleField } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import {
  getFsr4Inventory,
  getMeshStatus,
  installHelixsr,
  installFsr4Dll,
  installNativeMesh,
  installOptiscaler,
  prepareHelixsr,
  uninstallHelixsr,
  uninstallFsr4Dll,
  uninstallNativeMesh,
  uninstallOptiscaler,
} from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { Fsr4Game, Fsr4GameTarget, Fsr4Inventory, Fsr4Target, MeshStatus, OptiscalerCandidate } from "../types";
import type { MutationRunner } from "./shared";

const optiscalerProxies = [
  "dxgi.dll",
  "winmm.dll",
  "version.dll",
  "dbghelp.dll",
  "d3d12.dll",
  "wininet.dll",
  "winhttp.dll",
] as const;
type OptiscalerProxy = (typeof optiscalerProxies)[number];

const optiscalerProxyOptions = optiscalerProxies.map((proxy) => ({
  data: proxy,
  label: proxy,
}));

function supportedProxy(proxy: string | null): proxy is OptiscalerProxy {
  return proxy !== null && optiscalerProxies.includes(proxy as OptiscalerProxy);
}

function selectedProxy(proxy: string | null | undefined): OptiscalerProxy {
  const value = proxy ?? null;
  return supportedProxy(value) ? value : "winmm.dll";
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "The action failed.";
}

function LaunchOption({ value }: { value: string | null }) {
  if (!value) return null;
  return (
    <PanelSectionRow>
      <div style={{ width: "100%", color: "#b8bcbf", fontSize: 13 }}>
        <div style={{ marginBottom: 4 }}>Steam launch option</div>
        <code style={{ color: "#f2f2f2", overflowWrap: "anywhere", userSelect: "text" }}>
          {value}
        </code>
      </div>
    </PanelSectionRow>
  );
}

function preferredOptiscalerCandidate(candidates: OptiscalerCandidate[]) {
  return candidates.find((candidate) =>
    candidate.state !== "not-installed" && candidate.state !== "unavailable"
  ) ?? candidates.find((candidate) => candidate.discovered) ?? candidates[0];
}

function fsr4Managed(target: Fsr4Target) {
  return target.state === "ready" || target.state === "upgrade-required";
}

function fsr4Compatible(target: Fsr4Target) {
  const path = target.relativePath || target.targetPath || "";
  return path.replace(/\\/g, "/").split("/").pop()?.toLocaleLowerCase()
    === "amd_fidelityfx_upscaler_dx12.dll";
}

function integrityBlocked(state: string) {
  return state === "modified" || state === "invalid";
}

function directoryOf(path: string | null | undefined) {
  if (!path) return null;
  const normalized = path.replace(/\\/g, "/").replace(/\/+$/, "");
  const separator = normalized.lastIndexOf("/");
  return separator < 0 ? "." : normalized.slice(0, separator) || "/";
}

function targetHasManagedOptiscaler(game: Fsr4Game, target: Fsr4GameTarget) {
  const absoluteDirectory = directoryOf(target.targetPath);
  const relativeDirectory = directoryOf(target.relativePath);
  return game.optiscalerCandidates.some((candidate) => {
    if (candidate.state === "not-installed" || candidate.state === "unavailable") return false;
    return (absoluteDirectory !== null && candidate.installPath === absoluteDirectory)
      || (relativeDirectory !== null && candidate.relativePath === relativeDirectory);
  });
}

function OptiscalerGameControls({
  game,
  available,
  busy,
  runMutation,
  refresh,
}: {
  game: Fsr4Game;
  available: boolean;
  busy: boolean;
  runMutation: MutationRunner;
  refresh: () => Promise<void>;
}) {
  const preferred = preferredOptiscalerCandidate(game.optiscalerCandidates);
  const [candidateId, setCandidateId] = useState(preferred?.candidateId ?? "");
  const [proxy, setProxy] = useState<OptiscalerProxy>(selectedProxy(preferred?.proxy));
  const candidate = game.optiscalerCandidates.find((item) => item.candidateId === candidateId)
    ?? preferred;

  useEffect(() => {
    if (!candidate) return;
    if (candidate.candidateId !== candidateId) setCandidateId(candidate.candidateId);
    if (candidate.state !== "not-installed" && supportedProxy(candidate.proxy)) {
      setProxy(candidate.proxy);
    }
  }, [candidate?.candidateId, candidate?.proxy, candidate?.state, candidateId]);

  if (!candidate) return null;

  const gameReady = game.fullyInstalled
    && game.installPresent
    && game.scanState === "complete";
  const integrityBlocked = candidate.state === "modified" || candidate.state === "invalid";
  const unavailable = candidate.state === "unavailable";
  const managerBlocked = candidate.fsr4Managed || candidate.helixsrManaged;
  const installDisabled = busy
    || !available
    || !gameReady
    || !candidate.discovered
    || unavailable
    || integrityBlocked
    || managerBlocked;
  const managedMutationDisabled = installDisabled;
  const proxyDisabled = candidate.state !== "not-installed" || installDisabled;
  const removeDisabled = busy
    || !available
    || !gameReady
    || unavailable
    || integrityBlocked
    || managerBlocked;
  const path = candidate.relativePath || candidate.installPath;
  const executableSummary = candidate.executables.join(", ") || "No safe executable detected";
  const stateSummary = `${candidate.state}${candidate.release ? ` | ${candidate.release}` : ""}${candidate.proxy ? ` | ${candidate.proxy}` : ""}`;
  const warning = "Close the game first. Avoid OptiScaler in anti-cheat or online games; injected DLLs can trigger anti-cheat action or bans.";

  const selectCandidate = (nextId: string) => {
    const next = game.optiscalerCandidates.find((item) => item.candidateId === nextId);
    setCandidateId(nextId);
    setProxy(selectedProxy(next?.proxy));
  };

  const install = (update: boolean) => runMutation(
    update ? "OptiScaler updated" : "OptiScaler installed",
    async () => {
      try {
        await installOptiscaler(candidate.candidateId, proxy);
      } finally {
        await refresh();
      }
    },
    {
      title: update ? "Update OptiScaler for this game?" : "Install OptiScaler for this game?",
      description: `${warning} ${update ? "Update" : "Install"} ${path} using ${proxy}.`,
      destructive: true,
    },
    { refresh: false },
  );

  const remove = () => runMutation(
    "OptiScaler removed and original files restored",
    async () => {
      try {
        await uninstallOptiscaler(candidate.candidateId);
      } finally {
        await refresh();
      }
    },
    {
      title: "Uninstall OptiScaler and restore original files?",
      description: `${warning} The toolkit will restore the original files in ${path} and remove its rollback record.`,
      destructive: true,
    },
    { refresh: false },
  );

  return (
    <div>
      <DropdownItem
        label={`${game.name} | OptiScaler directory`}
        description={executableSummary}
        rgOptions={game.optiscalerCandidates.map((item) => ({
          data: item.candidateId,
          label: item.relativePath || item.installPath || "Recorded directory unavailable",
        }))}
        selectedOption={candidate.candidateId}
        disabled={busy}
        onChange={(option) => selectCandidate(option.data as string)}
      />
      <StatusRow label="OptiScaler" value={stateSummary} good={candidate.state === "ready"} />
      <DropdownItem
        label="Proxy DLL"
        rgOptions={optiscalerProxyOptions}
        selectedOption={proxy}
        disabled={proxyDisabled}
        onChange={(option) => setProxy(option.data as OptiscalerProxy)}
      />
      {candidate.state === "not-installed" && (
        <ActionButton
          label="Install OptiScaler"
          disabled={installDisabled}
          onClick={() => install(false)}
        />
      )}
      {candidate.state === "upgrade-required" && (
        <ActionButton
          label="Update OptiScaler"
          disabled={managedMutationDisabled}
          onClick={() => install(true)}
        />
      )}
      {candidate.state === "restorable" && candidate.currentRelease && (
        <ActionButton
          label="Finish OptiScaler install"
          disabled={managedMutationDisabled}
          onClick={() => install(true)}
        />
      )}
      {candidate.state === "repair-required" && (
        <ActionButton
          label="Repair OptiScaler files"
          disabled={managedMutationDisabled}
          onClick={() => install(true)}
        />
      )}
      {candidate.state !== "not-installed" && candidate.state !== "unavailable" && (
        <ActionButton
          label={candidate.state === "missing" ? "Restore original files" : "Uninstall OptiScaler"}
          disabled={removeDisabled}
          onClick={remove}
        />
      )}
      {candidate.state === "unavailable" && (
        <ActionButton label="Install OptiScaler" disabled onClick={() => install(false)} />
      )}
      {candidate.fsr4Managed && (
        <EmptyState>Restore BC-250 FSR4 for this directory before changing OptiScaler.</EmptyState>
      )}
      {candidate.helixsrManaged && (
        <EmptyState>Restore HelixSR for this directory before changing OptiScaler.</EmptyState>
      )}
      {candidate.state === "restorable" && !candidate.currentRelease && (
        <EmptyState>An interrupted older installation must be uninstalled before upgrading.</EmptyState>
      )}
      {!gameReady && (
        <EmptyState>Finish the Steam install/update and a complete executable scan before changing OptiScaler.</EmptyState>
      )}
      <LaunchOption value={candidate.launchOption} />
    </div>
  );
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
      enabled ? "FSR4 RC9 installed" : "Original game DLL restored",
      async () => {
        try {
          await action(target.targetId);
        } finally {
          await refresh();
        }
      },
      {
        title: enabled ? "Install FSR4 RC9 for this game?" : "Restore the original game DLL?",
        description: enabled
          ? `Close the game first. The toolkit will replace ${target.relativePath || target.targetPath || "the selected DLL"} and retain an exact rollback copy.`
          : `Close the game first. The toolkit will restore the exact original bytes for ${target.relativePath || target.targetPath || "this target"} and remove its rollback record.`,
        destructive: true,
      },
      { refresh: false },
    );
  };

  const toggleHelixsr = (
    target: Pick<Fsr4Target, "targetId" | "targetPath" | "relativePath">,
    enabled: boolean,
  ) => {
    const action = enabled ? installHelixsr : uninstallHelixsr;
    runMutation(
      enabled ? "HelixSR installed" : "Original game DLL restored",
      async () => {
        try {
          await action(target.targetId);
        } finally {
          await refresh();
        }
      },
      {
        title: enabled ? "Install experimental HelixSR for this game?" : "Restore the pre-HelixSR game DLL?",
        description: enabled
          ? `Close the game first. Do not use HelixSR in anti-cheat or online games. The toolkit will install the locally generated payload at ${target.relativePath || target.targetPath || "the selected DLL"} and retain an exact rollback copy.`
          : `Close the game first. The toolkit will restore the exact pre-HelixSR bytes for ${target.relativePath || target.targetPath || "this target"} and remove its rollback record.`,
        destructive: true,
      },
      { refresh: false },
    );
  };

  const prepareHelixsrPayload = () => runMutation(
    "HelixSR payload prepared",
    async () => {
      try {
        await prepareHelixsr();
      } finally {
        await refresh();
      }
    },
    {
      title: "Prepare the experimental HelixSR payload?",
      description: "This downloads the official HelixSR release and NVIDIA DLSS input, generates files locally, and may take time. HelixSR should not be used in anti-cheat or online games.",
      destructive: true,
    },
    { refresh: false },
  );

  const toggleNativeMesh = (enabled: boolean) => runMutation(
    enabled ? "Private native-mesh profile installed" : "Private native-mesh profile removed",
    async () => {
      try {
        await (enabled ? installNativeMesh() : uninstallNativeMesh());
      } finally {
        await refresh();
      }
    },
    {
      title: enabled ? "Install the private native-mesh profile?" : "Remove the private native-mesh profile?",
      description: enabled
        ? "Build the experimental combined async-compute, FSR4, and physical-GFX10 native-mesh ICD. It stays private: Steam launch options and global activation are not changed."
        : "Remove only the private native-mesh profile. The global RADV runtime and Steam configuration are unchanged.",
      destructive: !enabled,
    },
    { refresh: false },
  );

  const restoreOrphanedOptiscaler = (candidate: OptiscalerCandidate) => {
    runMutation(
      "OptiScaler removed and original files restored",
      async () => {
        try {
          await uninstallOptiscaler(candidate.candidateId);
        } finally {
          await refresh();
        }
      },
      {
        title: "Restore files from this OptiScaler record?",
        description: `Close the game first. Avoid OptiScaler in anti-cheat or online games; injected DLLs can trigger anti-cheat action or bans. The toolkit will restore the original files in ${candidate.relativePath || candidate.installPath || "the recorded directory"} and remove its rollback record.`,
        destructive: true,
      },
      { refresh: false },
    );
  };

  const query = search.trim().toLocaleLowerCase();
  const visibleGames = (inventory?.games ?? [])
    .filter((game) => !query || game.name.toLocaleLowerCase().includes(query) || game.appId.includes(query))
    .slice(0, 100);
  const targetToggle = (target: Fsr4GameTarget, label: string, game: Fsr4Game) => {
    const managed = fsr4Managed(target);
    const supportsFsr4 = fsr4Compatible(target);
    const targetIntegrityBlocked = integrityBlocked(target.state);
    const undiscoverableInstall = target.state === "restored" && !target.discovered;
    const gameReady = game.fullyInstalled && game.installPresent;
    const scanComplete = gameReady && game.scanState === "complete";
    const helixsrState = target.helixsrState || "unavailable";
    const helixsrIntegrityBlocked = integrityBlocked(helixsrState);
    const optiscalerManaged = target.optiscalerManaged || targetHasManagedOptiscaler(game, target);
    const fsr4ManagementBlocked = target.state !== "available";
    const fsr4Disabled = busy || !supportsFsr4 || !gameReady || targetIntegrityBlocked || target.state === "missing"
      || undiscoverableInstall || (!managed && target.helixsrManaged);
    const helixsrInstallDisabled = busy
      || !inventory?.helixsrAvailable
      || inventory.helixsrPayloadState !== "ready"
      || !scanComplete
      || !target.discovered
      || helixsrState === "unavailable"
      || fsr4ManagementBlocked
      || optiscalerManaged
      || targetIntegrityBlocked
      || helixsrIntegrityBlocked;
    const helixsrRestoreDisabled = busy || !scanComplete || fsr4ManagementBlocked
      || optiscalerManaged || helixsrIntegrityBlocked;
    const description = `${target.relativePath || target.targetPath || "Unknown target"} | ${target.state}${target.release ? ` | ${target.release}` : ""}${supportsFsr4 ? "" : " | FSR4 unsupported target name"}${gameReady ? "" : " | Steam install/update incomplete"}${undiscoverableInstall ? " | target not found during scan" : ""}${target.helixsrManaged ? " | HelixSR managed" : ""}`;
    const helixsrDescription = `${target.relativePath || target.targetPath || "Unknown target"} | ${helixsrState}${target.helixsrRelease ? ` | ${target.helixsrRelease}` : ""}${scanComplete ? "" : " | complete game scan required"}${fsr4ManagementBlocked ? " | restore FSR4 first" : ""}${optiscalerManaged ? " | OptiScaler directory managed" : ""}`;
    return (
      <div key={target.targetId}>
        <ToggleField
          label={label}
          description={description}
          checked={managed}
          disabled={fsr4Disabled}
          onChange={(enabled) => toggleTarget(target, enabled)}
        />
        {target.state === "upgrade-required" && (
          <ActionButton label="Update this target" disabled={busy || !gameReady || !target.discovered || target.helixsrManaged} onClick={() => toggleTarget(target, true)} />
        )}
        {target.state === "missing" && (
          <ActionButton label="Restore missing original DLL" disabled={busy || !gameReady} onClick={() => toggleTarget(target, false)} />
        )}
        <ToggleField
          label="HelixSR (experimental)"
          description={helixsrDescription}
          checked={Boolean(target.helixsrManaged)}
          disabled={target.helixsrManaged ? helixsrRestoreDisabled : helixsrInstallDisabled}
          onChange={(enabled) => toggleHelixsr(target, enabled)}
        />
        {helixsrState === "upgrade-required" && target.helixsrManaged && (
          <ActionButton label="Update HelixSR" disabled={helixsrInstallDisabled} onClick={() => toggleHelixsr(target, true)} />
        )}
        {helixsrState === "restorable" && target.helixsrManaged && (
          <ActionButton label="Restore pre-HelixSR DLL" disabled={helixsrRestoreDisabled} onClick={() => toggleHelixsr(target, false)} />
        )}
      </div>
    );
  };

  const gameManager = (
    <>
      <PanelSection title="HelixSR (Experimental)">
        <StatusRow
          label="Availability"
          value={inventory?.helixsrAvailable ? "Available" : "Unavailable"}
          good={inventory?.helixsrAvailable}
        />
        <StatusRow
          label="Payload"
          value={inventory
            ? `${inventory.helixsrPayloadState}${inventory.currentHelixsrRelease ? ` | ${inventory.currentHelixsrRelease}` : ""}`
            : "Loading"}
          good={inventory?.helixsrPayloadState === "ready"}
        />
        {inventory && inventory.helixsrPayloadState !== "ready" && (
          <ActionButton
            label="Prepare HelixSR payload"
            disabled={busy || !inventory.helixsrAvailable}
            onClick={prepareHelixsrPayload}
          />
        )}
        <EmptyState>Experimental. Do not use HelixSR in anti-cheat or online games.</EmptyState>
      </PanelSection>
      <PanelSection title="FSR4 RC9 Game Manager">
        <TextField
          label="Installed Steam games"
          description={inventory ? `${inventory.games.length} installed games | FSR4 ${inventory.currentRelease ?? "helper unavailable"} | OptiScaler ${inventory.currentOptiscalerRelease ?? "helper unavailable"}` : "Loading Steam inventory"}
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
        {inventory && !inventory.optiscalerAvailable && (
          <EmptyState>The OptiScaler helper is unavailable. Reinstall or update the toolkit before managing OptiScaler.</EmptyState>
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
              game,
            ))}
            {game.optiscalerCandidates.length > 0 && (
              <OptiscalerGameControls
                game={game}
                available={inventory.optiscalerAvailable}
                busy={busy}
                runMutation={runMutation}
                refresh={refresh}
              />
            )}
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
      {inventory && inventory.orphanedHelixsr.length > 0 && (
        <PanelSection title="Unassociated HelixSR Targets">
          {inventory.orphanedHelixsr.map((target) => {
            const state = target.state;
            return (
              <div key={target.targetId}>
                <StatusRow label={target.targetPath || "Invalid rollback record"} value={`${state}${target.release ? ` | ${target.release}` : ""}`} />
                <ActionButton
                  label="Restore pre-HelixSR DLL"
                  disabled={busy || integrityBlocked(state)}
                  onClick={() => toggleHelixsr(target, false)}
                />
              </div>
            );
          })}
        </PanelSection>
      )}
      {inventory && inventory.orphanedOptiscaler.length > 0 && (
        <PanelSection title="Unassociated OptiScaler Records">
          {inventory.orphanedOptiscaler.map((candidate) => {
            const blocked = busy
              || !inventory.optiscalerAvailable
              || candidate.state === "modified"
              || candidate.state === "invalid"
              || candidate.state === "unavailable"
              || candidate.fsr4Managed
              || candidate.helixsrManaged;
            return (
              <div key={candidate.candidateId}>
                <StatusRow
                  label={candidate.relativePath || candidate.installPath || "Invalid OptiScaler record"}
                  value={`${candidate.state}${candidate.release ? ` | ${candidate.release}` : ""}${candidate.proxy ? ` | ${candidate.proxy}` : ""}`}
                />
                <ActionButton
                  label="Restore original files"
                  disabled={blocked}
                  onClick={() => restoreOrphanedOptiscaler(candidate)}
                />
                {candidate.fsr4Managed && (
                  <EmptyState>Restore BC-250 FSR4 for this directory before removing OptiScaler.</EmptyState>
                )}
                {candidate.helixsrManaged && (
                  <EmptyState>Restore HelixSR for this directory before removing OptiScaler.</EmptyState>
                )}
                <LaunchOption value={candidate.launchOption} />
              </div>
            );
          })}
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
        <StatusRow label="FSR4 RC9 game DLLs" value={`${status.fsr4DllState} (${status.fsr4DllInstallCount})`} good={status.fsr4DllState === "ready"} />
        <StatusRow label="Legacy FSR4 V3 profile" value={status.fsr4State} good={status.fsr4State === "ready"} />
        <StatusRow label="Legacy FSR4 runner" value={status.fsr4RunnerPath} good={status.fsr4State === "ready"} />
      </PanelSection>

      <PanelSection title="Private Native Mesh">
        <StatusRow label="Native-mesh profile" value={status.nativeMeshState} good={status.nativeMeshState === "ready"} />
        <StatusRow label="Private ICD" value={status.nativeMeshIcdPath} good={status.nativeMeshState === "ready"} />
        <StatusRow label="Private runner" value={status.nativeMeshRunnerPath} good={status.nativeMeshState === "ready"} />
        {status.nativeMeshState === "not-installed" && (
          <ActionButton label="Install private native mesh" disabled={busy || !status.kernelReady || !status.schedulerActive} onClick={() => toggleNativeMesh(true)} />
        )}
        {status.nativeMeshState !== "not-installed" && (
          <ActionButton label="Remove private native mesh" disabled={busy || status.nativeMeshState === "invalid"} onClick={() => toggleNativeMesh(false)} />
        )}
        <EmptyState>This experimental profile is never enabled globally. Add the displayed runner to a game's Steam launch options manually when required.</EmptyState>
      </PanelSection>

      {error && <EmptyState>{error}</EmptyState>}
      {!status.scriptAvailable && <EmptyState>The Mesa / RADV toolkit script is unavailable.</EmptyState>}
      {!status.kernelReady && <EmptyState>Install the AMDGPU kernel fixes and reboot before installing the Mesa / RADV async-compute patch.</EmptyState>}
      {status.runtimeState === "not-installed" && <EmptyState>The Mesa / RADV patch enables GFX1013 async compute. Install it from Drivers after the patched AMDGPU module is active; the build usually takes 3-5 minutes.</EmptyState>}
      {status.runtimeState === "invalid" && <EmptyState>The alternate runtime failed validation or requires migration. Run setup again from the toolkit menu.</EmptyState>}
      {status.fsr4DllState === "invalid" && <EmptyState>A game-local FSR4 DLL failed integrity validation. Restore it with the toolkit before making further changes.</EmptyState>}
      {status.fsr4State === "invalid" && <EmptyState>The legacy private FSR4 runtime failed integrity validation. Reinstall or remove it from the toolkit.</EmptyState>}
      {status.nativeMeshState === "invalid" && <EmptyState>The private native-mesh profile failed integrity validation. Repair or remove it from the toolkit CLI.</EmptyState>}
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
