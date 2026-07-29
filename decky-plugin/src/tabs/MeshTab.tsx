import {
  ButtonItem,
  ConfirmModal,
  PanelSection,
  PanelSectionRow,
  showModal,
  Spinner,
  TextField,
  ToggleField,
} from "@decky/ui";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { getMeshStatus, setMeshGameEnabled } from "../api";
import { EmptyState, StatusRow } from "../components/Common";
import type { MeshStatus } from "../types";

interface Unregisterable {
  unregister(): void;
}

interface AppDetails {
  strDisplayName?: string;
  strLaunchOptions?: string;
}

interface InstalledApp {
  nAppID: number;
  strAppName: string;
}

interface SteamApi {
  InstallFolder?: {
    GetInstallFolders(): Promise<Array<{ vecApps: InstalledApp[] }>>;
    RegisterForInstallFolderChanges?(callback: () => void): Unregisterable;
  };
  Apps?: {
    RegisterForAppDetails?(
      appId: number,
      callback: (details: AppDetails) => void,
    ): Unregisterable;
    SetAppLaunchOptions?(appId: number, options: string): void | Promise<void>;
    OpenAppSettingsDialog?(appId: number, section: string): void;
  };
}

interface SteamGlobals {
  SteamClient?: SteamApi;
  appStore?: {
    GetAppOverviewByAppID(appId: number): {
      visible_in_game_list: boolean;
    } | null;
  };
  appDetailsStore?: {
    GetAppDetails(appId: number): AppDetails | null;
  };
}

interface GameRow {
  appId: number;
  name: string;
  installed: boolean;
}

const ALIAS_PATTERN = /^bc250-steam-([1-9]\d*)$/;
const DETAILS_TIMEOUT_MS = 4_000;

function globals(): SteamGlobals {
  return globalThis as unknown as SteamGlobals;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "The action failed.";
}

function shellWord(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function canonicalOption(status: MeshStatus, appId: number): string {
  return `MESA_DRICONF_EXECUTABLE_OVERRIDE=${shellWord(`bc250-steam-${appId}`)} VK_ICD_FILENAMES=${shellWord(status.icdPath)} %command%`;
}

function currentDetails(appId: number): AppDetails | null {
  return globals().appDetailsStore?.GetAppDetails(appId) ?? null;
}

function unregister(registration?: Unregisterable) {
  try {
    registration?.unregister();
  } catch {
    // Steam may already have released the registration.
  }
}

function openProperties(appId: number): boolean {
  const apps = globals().SteamClient?.Apps;
  if (!apps?.OpenAppSettingsDialog) return false;
  try {
    apps.OpenAppSettingsDialog(appId, "general");
    return true;
  } catch {
    return false;
  }
}

function waitForLaunchOptions(appId: number, fresh = false): Promise<string> {
  const immediate = fresh ? undefined : currentDetails(appId)?.strLaunchOptions;
  if (typeof immediate === "string") return Promise.resolve(immediate);

  const apps = globals().SteamClient?.Apps;
  const register = apps?.RegisterForAppDetails?.bind(apps);
  if (!register) {
    return Promise.reject(new Error("Steam app details are unavailable."));
  }

  return new Promise((resolve, reject) => {
    let registration: Unregisterable | undefined;
    let settled = false;
    const finish = (options?: string, error?: Error) => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timer);
      unregister(registration);
      if (error) reject(error);
      else resolve(options ?? "");
    };
    const timer = window.setTimeout(
      () => finish(undefined, new Error("Timed out waiting for Steam app details.")),
      DETAILS_TIMEOUT_MS,
    );

    try {
      registration = register(appId, (details) => {
        const options = details.strLaunchOptions ??
          currentDetails(appId)?.strLaunchOptions;
        if (typeof options === "string") finish(options);
      });
      if (settled) unregister(registration);
    } catch (error) {
      finish(undefined, new Error(errorMessage(error)));
    }
  });
}

function Guidance({ children }: { children: ReactNode }) {
  return (
    <PanelSectionRow>
      <div
        style={{
          width: "100%",
          padding: "9px 12px",
          borderRadius: 6,
          background: "rgba(230, 173, 85, 0.12)",
          color: "#e6c48f",
          fontSize: 12,
          lineHeight: 1.4,
          overflowWrap: "anywhere",
        }}
      >
        {children}
      </div>
    </PanelSectionRow>
  );
}

export function MeshTab() {
  const [status, setStatus] = useState<MeshStatus | null>(null);
  const [installed, setInstalled] = useState<InstalledApp[]>([]);
  const [search, setSearch] = useState("");
  const [loadingStatus, setLoadingStatus] = useState(true);
  const [loadingApps, setLoadingApps] = useState(true);
  const [statusError, setStatusError] = useState("");
  const [appsError, setAppsError] = useState("");
  const [busyApp, setBusyApp] = useState<number | null>(null);
  const [notes, setNotes] = useState<Record<number, string>>({});
  const mounted = useRef(true);

  const refreshStatus = async () => {
    try {
      const next = await getMeshStatus();
      if (mounted.current) {
        setStatus(next);
        setStatusError("");
      }
    } catch (error) {
      if (mounted.current) setStatusError(errorMessage(error));
    } finally {
      if (mounted.current) setLoadingStatus(false);
    }
  };

  const refreshApps = async () => {
    const installFolder = globals().SteamClient?.InstallFolder;
    if (!installFolder) {
      setAppsError("Steam install-folder APIs are unavailable.");
      setLoadingApps(false);
      return;
    }
    try {
      const folders = await installFolder.GetInstallFolders();
      const deduped = new Map<number, InstalledApp>();
      for (const app of folders.flatMap((folder) => folder.vecApps)) {
        const overview = globals().appStore?.GetAppOverviewByAppID(app.nAppID);
        if (overview && !overview.visible_in_game_list) continue;
        if (!deduped.has(app.nAppID)) deduped.set(app.nAppID, app);
      }
      if (mounted.current) {
        setInstalled([...deduped.values()]);
        setAppsError("");
      }
    } catch (error) {
      if (mounted.current) setAppsError(errorMessage(error));
    } finally {
      if (mounted.current) setLoadingApps(false);
    }
  };

  useEffect(() => {
    mounted.current = true;
    void refreshStatus();
    void refreshApps();

    let registration: Unregisterable | undefined;
    try {
      registration = globals().SteamClient?.InstallFolder
        ?.RegisterForInstallFolderChanges?.(() => void refreshApps());
    } catch (error) {
      setAppsError(`Install-folder updates unavailable: ${errorMessage(error)}`);
    }
    return () => {
      mounted.current = false;
      unregister(registration);
    };
  }, []);

  const setNote = (appId: number, note: string) => {
    if (mounted.current) setNotes((current) => ({ ...current, [appId]: note }));
  };

  const finishBackendAction = async () => {
    await refreshStatus();
    if (mounted.current) setBusyApp(null);
  };

  const enableBackend = async (row: GameRow, option: string | null) => {
    if (!status || busyApp !== null) return;
    const apps = globals().SteamClient?.Apps;
    setBusyApp(row.appId);
    setNote(row.appId, "");
    try {
      await setMeshGameEnabled(row.appId, row.name, true);
    } catch (error) {
      setNote(row.appId, `Enable failed: ${errorMessage(error)}`);
      setBusyApp(null);
      return;
    }

    const canonical = canonicalOption(status, row.appId);
    if (option === null) {
      setNote(row.appId, `Backend enabled. Steam launch options could not be inspected; manually merge: ${canonical}`);
      openProperties(row.appId);
      await finishBackendAction();
      return;
    }
    if (!option.trim()) {
      try {
        option = await waitForLaunchOptions(row.appId, true);
      } catch (error) {
        setNote(row.appId, `Backend enabled. Launch options could not be rechecked: ${errorMessage(error)} Manually set: ${canonical}`);
        openProperties(row.appId);
        await finishBackendAction();
        return;
      }
    }
    if (!option.trim()) {
      if (apps?.SetAppLaunchOptions) {
        try {
          await apps.SetAppLaunchOptions(row.appId, canonical);
          setNote(row.appId, "Enabled; the Steam launch-option update was requested.");
        } catch (error) {
          setNote(
            row.appId,
            `Backend enabled, but Steam launch options failed: ${errorMessage(error)} Manually set: ${canonical}`,
          );
          openProperties(row.appId);
        }
      } else {
        setNote(row.appId, `Backend enabled. Steam cannot be updated here; manually set: ${canonical}`);
        openProperties(row.appId);
      }
    } else if (option.trim() === canonical) {
      setNote(row.appId, "Enabled; the toolkit-owned launch option was preserved.");
    } else {
      setNote(row.appId, `Backend enabled. Merge this into the existing launch options without replacing them: ${canonical}`);
      if (!openProperties(row.appId)) {
        setNote(row.appId, `Backend enabled. Steam Properties cannot be opened here; manually merge: ${canonical}`);
      }
    }
    await finishBackendAction();
  };

  const requestEnable = async (row: GameRow) => {
    if (!status || busyApp !== null) return;
    setBusyApp(row.appId);
    setNote(row.appId, "Reading Steam launch options...");
    let option: string;
    try {
      option = await waitForLaunchOptions(row.appId, true);
    } catch (error) {
      const canonical = canonicalOption(status, row.appId);
      setBusyApp(null);
      setNote(row.appId, "Steam launch options are unavailable; awaiting confirmation.");
      showModal(
        <ConfirmModal
          strTitle={`Enable mesh shaders for ${row.name}?`}
          strDescription={
            <div>
              <div style={{ marginBottom: 10 }}>
                Steam launch options could not be inspected and will not be
                changed. Configure this option manually after enabling:
              </div>
              <code style={{ overflowWrap: "anywhere" }}>{canonical}</code>
              <div style={{ marginTop: 10 }}>{errorMessage(error)}</div>
            </div>
          }
          strOKButtonText="Enable backend entry"
          strCancelButtonText="Cancel"
          onOK={() => void enableBackend(row, null)}
          onCancel={() => setNote(row.appId, "Enable canceled; no changes were made.")}
        />,
      );
      return;
    }
    setBusyApp(null);

    const canonical = canonicalOption(status, row.appId);
    if (option.trim() && option.trim() !== canonical) {
      setNote(row.appId, "Custom launch options detected; awaiting confirmation.");
      showModal(
        <ConfirmModal
          strTitle={`Enable mesh shaders for ${row.name}?`}
          strDescription={
            <div>
              <div style={{ marginBottom: 10 }}>
                Existing launch options will not be changed. After enabling the
                backend entry, merge this option in Steam Properties:
              </div>
              <code style={{ overflowWrap: "anywhere" }}>{canonical}</code>
            </div>
          }
          strOKButtonText={globals().SteamClient?.Apps?.OpenAppSettingsDialog
            ? "Enable and open Properties"
            : "Enable"}
          strCancelButtonText="Cancel"
          onOK={() => void enableBackend(row, option)}
          onCancel={() => setNote(row.appId, "Enable canceled; no changes were made.")}
        />,
      );
      return;
    }
    await enableBackend(row, option);
  };

  const disable = async (row: GameRow) => {
    if (!status || busyApp !== null) return;
    const apps = globals().SteamClient?.Apps;
    const canonical = canonicalOption(status, row.appId);
    setBusyApp(row.appId);
    setNote(row.appId, "Disabling backend entry...");
    try {
      await setMeshGameEnabled(row.appId, row.name, false);
    } catch (error) {
      setNote(row.appId, `Disable failed; launch options were not changed: ${errorMessage(error)}`);
      setBusyApp(null);
      return;
    }

    let option: string;
    try {
      option = await waitForLaunchOptions(row.appId, true);
    } catch (error) {
      setNote(row.appId, `Backend disabled. Launch options could not be checked: ${errorMessage(error)}`);
      await finishBackendAction();
      return;
    }

    if (option.trim() === canonical) {
      if (apps?.SetAppLaunchOptions) {
        try {
          await apps.SetAppLaunchOptions(row.appId, "");
          setNote(row.appId, "Disabled; clearing the exact toolkit launch option was requested.");
        } catch (error) {
          setNote(row.appId, `Backend disabled, but the launch option could not be cleared: ${errorMessage(error)} Remove: ${canonical}`);
          openProperties(row.appId);
        }
      } else {
        setNote(row.appId, `Backend disabled. Steam cannot be updated here; remove: ${canonical}`);
        openProperties(row.appId);
      }
    } else if (option.trim()) {
      setNote(row.appId, "Backend disabled. Custom launch options were preserved unchanged.");
    } else {
      setNote(row.appId, "Backend disabled; launch options were already empty.");
    }
    await finishBackendAction();
  };

  if (loadingStatus && !status) {
    return <div style={{ display: "flex", justifyContent: "center", padding: 28 }}><Spinner /></div>;
  }

  if (!status) {
    return (
      <>
        <EmptyState>{statusError || "Unable to load Mesh Shaders status."}</EmptyState>
        <PanelSection><PanelSectionRow><ButtonItem layout="below" onClick={() => void refreshStatus()}>Retry</ButtonItem></PanelSectionRow></PanelSection>
      </>
    );
  }

  const enabled = new Map<number, string>();
  const manual = [];
  for (const game of status.games) {
    const match = ALIAS_PATTERN.exec(game.executable);
    const appId = match ? Number(match[1]) : 0;
    if (appId >= 1 && appId <= 0xffffffff) enabled.set(appId, game.name);
    else manual.push(game);
  }

  const rows = new Map<number, GameRow>();
  for (const app of installed) {
    rows.set(app.nAppID, {
      appId: app.nAppID,
      name: app.strAppName || currentDetails(app.nAppID)?.strDisplayName || `App ${app.nAppID}`,
      installed: true,
    });
  }
  for (const [appId, name] of enabled) {
    if (!rows.has(appId)) rows.set(appId, { appId, name: name || `App ${appId}`, installed: false });
  }
  const query = search.trim().toLocaleLowerCase();
  const visibleRows = [...rows.values()]
    .filter((row) => !query || row.name.toLocaleLowerCase().includes(query) || String(row.appId).includes(query))
    .sort((left, right) =>
      Number(enabled.has(right.appId)) - Number(enabled.has(left.appId)) ||
      left.name.localeCompare(right.name),
    );
  const canEnable = status.scriptAvailable && status.runtimeState === "ready" && status.configValid;
  const canDisable = status.scriptAvailable && status.configValid;
  const steamApps = globals().SteamClient?.Apps;

  return (
    <>
      <PanelSection title="Mesh Shaders Runtime">
        <StatusRow label="Runtime" value={status.runtimeState} good={status.runtimeState === "ready"} />
        <StatusRow label="Mesa" value={status.mesaVersion ?? "Not installed"} />
        <StatusRow label="Configuration" value={status.configValid ? "Valid" : "Invalid"} good={status.configValid} />
        <StatusRow label="Alternate ICD" value={status.icdPath || "Unavailable"} good={status.runtimeState === "ready"} />
      </PanelSection>

      {status.error && <EmptyState>{status.error}</EmptyState>}
      {!status.scriptAvailable && <EmptyState>The Mesh Shaders toolkit script is unavailable.</EmptyState>}
      {status.runtimeState === "not-installed" && <EmptyState>Install the alternate Mesa/RADV runtime from the toolkit CLI before enabling games.</EmptyState>}
      {status.runtimeState === "invalid" && <EmptyState>The alternate runtime failed validation. Repair it from the toolkit CLI before enabling games.</EmptyState>}
      {!steamApps?.SetAppLaunchOptions && <EmptyState>Steam launch-option editing is unavailable in this client. Backend changes still work, but launch options must be updated manually.</EmptyState>}
      {!steamApps?.OpenAppSettingsDialog && <EmptyState>Steam Properties cannot be opened by this client. Manual-merge instructions remain visible below each affected game.</EmptyState>}

      <PanelSection title="Installed Games">
        <TextField
          label="Search"
          description={`${visibleRows.length} of ${rows.size} games`}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
        {loadingApps && <PanelSectionRow><Spinner /></PanelSectionRow>}
        {appsError && <Guidance>{appsError}</Guidance>}
        {!loadingApps && !appsError && visibleRows.length === 0 && (
          <Guidance>{query ? "No installed games match this search." : "No installed games were reported by Steam."}</Guidance>
        )}
        {visibleRows.map((row) => {
          const isEnabled = enabled.has(row.appId);
          const canonical = canonicalOption(status, row.appId);
          const launchOptions = currentDetails(row.appId)?.strLaunchOptions;
          const trimmed = launchOptions?.trim();
          let launchState = "Launch options not loaded";
          if (trimmed === canonical) launchState = isEnabled ? "Ready" : "Backend disabled; toolkit option remains";
          else if (!trimmed && launchOptions !== undefined) launchState = isEnabled ? "Backend enabled; launch option missing" : "Disabled";
          else if (trimmed) launchState = isEnabled ? "Backend enabled; manual merge required" : "Custom launch options preserved";
          return (
            <div key={row.appId}>
              <ToggleField
                label={row.name}
                description={`App ${row.appId} | ${row.installed ? launchState : "Not currently installed"}`}
                checked={isEnabled}
                disabled={busyApp !== null || (isEnabled ? !canDisable : !canEnable) || (!row.installed && !isEnabled)}
                onChange={(next) => next ? void requestEnable(row) : void disable(row)}
              />
              {busyApp === row.appId && <Guidance>Working...</Guidance>}
              {notes[row.appId] && <Guidance>{notes[row.appId]}</Guidance>}
              {isEnabled && trimmed !== canonical && (
                <Guidance>
                  Required launch option: <code>{canonical}</code>
                </Guidance>
              )}
            </div>
          );
        })}
      </PanelSection>

      {manual.length > 0 && (
        <PanelSection title="Manual Executable Entries">
          <Guidance>
            These entries do not use a Steam AppID alias and are read-only here.
            Disable one with <code>./bc250-mesh-shader.sh game disable EXECUTABLE</code>.
          </Guidance>
          {manual.map((game) => (
            <StatusRow key={game.executable} label={game.name} value={game.executable} />
          ))}
        </PanelSection>
      )}

      <PanelSection>
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            disabled={loadingStatus || busyApp !== null}
            onClick={() => void refreshStatus()}
          >
            Refresh Mesh status
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
      {statusError && <EmptyState>{statusError}</EmptyState>}
    </>
  );
}
