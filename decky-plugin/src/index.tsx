import {
  ButtonItem,
  ConfirmModal,
  PanelSection,
  PanelSectionRow,
  showModal,
  Spinner,
  staticClasses,
} from "@decky/ui";
import { definePlugin, toaster } from "@decky/api";
import { useEffect, useRef, useState } from "react";
import {
  FaBolt,
  FaCog,
  FaMemory,
  FaMicrochip,
  FaSyncAlt,
  FaTv,
} from "react-icons/fa";
import { getSnapshot } from "./api";
import { EmptyState } from "./components/Common";
import { VerticalTabs, type VerticalTab } from "./components/VerticalTabs";
import { CecTab } from "./tabs/CecTab";
import { CpuTab } from "./tabs/CpuTab";
import { CuTab } from "./tabs/CuTab";
import { GpuTab } from "./tabs/GpuTab";
import { PowerTab } from "./tabs/PowerTab";
import type { Confirmation, MutationRunner } from "./tabs/shared";
import type { Snapshot } from "./types";

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "The backend action failed.";
}

function Content() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [activeTab, setActiveTab] = useState("cu");
  const [loading, setLoading] = useState(true);
  const [busyLabel, setBusyLabel] = useState("");
  const [error, setError] = useState("");
  const requestVersion = useRef(0);
  const mutationRunning = useRef(false);
  const refreshRunning = useRef(false);

  const refresh = async (quiet = false) => {
    if (refreshRunning.current || (quiet && mutationRunning.current)) return;
    refreshRunning.current = true;
    const request = ++requestVersion.current;
    if (!quiet) setLoading(true);
    try {
      const next = await getSnapshot();
      if (request === requestVersion.current) {
        setSnapshot(next);
        setError("");
      }
    } catch (caught) {
      if (request === requestVersion.current) setError(errorMessage(caught));
    } finally {
      refreshRunning.current = false;
      if (!quiet && request === requestVersion.current) setLoading(false);
    }
  };

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(true), 10_000);
    return () => window.clearInterval(timer);
  }, []);

  const execute = async (
    label: string,
    operation: () => Promise<void>,
  ) => {
    if (mutationRunning.current) return;
    mutationRunning.current = true;
    const request = ++requestVersion.current;
    setBusyLabel(label);
    try {
      await operation();
      try {
        const next = await getSnapshot();
        if (request === requestVersion.current) {
          setSnapshot(next);
          setError("");
        }
      } catch (caught) {
        if (request === requestVersion.current) {
          setError(`Action completed, but status refresh failed: ${errorMessage(caught)}`);
        }
      }
      toaster.toast({ title: "BC-250 Control", body: label });
    } catch (caught) {
      const message = errorMessage(caught);
      if (request === requestVersion.current) setError(message);
      toaster.toast({ title: "BC-250 action failed", body: message });
    } finally {
      mutationRunning.current = false;
      setBusyLabel("");
    }
  };

  const runMutation: MutationRunner = (
    label,
    operation,
    confirmation?: Confirmation,
  ) => {
    if (!confirmation) {
      void execute(label, operation);
      return;
    }
    showModal(
      <ConfirmModal
        strTitle={confirmation.title}
        strDescription={confirmation.description}
        strOKButtonText="Apply"
        strCancelButtonText="Cancel"
        bDestructiveWarning={confirmation.destructive}
        onOK={() => void execute(label, operation)}
      />,
    );
  };

  if (loading && !snapshot) {
    return (
      <div style={{ display: "flex", justifyContent: "center", padding: 28 }}>
        <Spinner />
      </div>
    );
  }

  if (!snapshot) {
    return (
      <PanelSection title="Backend unavailable">
        <EmptyState>{error || "Unable to load toolkit status."}</EmptyState>
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => void refresh()}>
            Retry
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    );
  }

  const busy = Boolean(busyLabel);
  const tabProps = { snapshot, busy, runMutation };
  const tabs: VerticalTab[] = [
    {
      id: "cu",
      label: "CU",
      icon: <FaMicrochip />,
      healthy: snapshot.cu.available,
      content: <CuTab {...tabProps} />,
    },
    {
      id: "power",
      label: "Power",
      icon: <FaBolt />,
      healthy:
        snapshot.power.acpiActive && snapshot.power.governor.active === "active",
      content: <PowerTab {...tabProps} />,
    },
    {
      id: "gpu",
      label: "GPU",
      icon: <FaMemory />,
      healthy: snapshot.gpu.available,
      content: <GpuTab {...tabProps} />,
    },
    {
      id: "cpu",
      label: "CPU",
      icon: <FaCog />,
      healthy: Boolean(snapshot.cpu.installed || snapshot.cpu.staged),
      content: <CpuTab {...tabProps} />,
    },
    {
      id: "cec",
      label: "CEC",
      icon: <FaTv />,
      healthy:
        snapshot.cec.devicePresent && snapshot.cec.service.active === "active",
      content: <CecTab {...tabProps} />,
    },
  ];

  return (
    <div>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 8,
          padding: "4px 10px 8px",
          borderBottom: "1px solid rgba(255,255,255,.08)",
        }}
      >
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: 12, color: "#aeb3b8" }}>
            {busyLabel || `${snapshot.cu.total}/40 CU · ${snapshot.gpu.activeMhz ?? "–"} MHz GPU`}
          </div>
          {!snapshot.toolkit.available && (
            <div
              style={{
                color: "#e6ad55",
                fontSize: 11,
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}
            >
              Toolkit incomplete: {snapshot.toolkit.path}
            </div>
          )}
          {error && <div style={{ color: "#e77878", fontSize: 11 }}>{error}</div>}
        </div>
        <ButtonItem
          layout="below"
          disabled={Boolean(busyLabel)}
          onClick={() => void refresh()}
        >
          <FaSyncAlt />
        </ButtonItem>
      </div>
      <VerticalTabs tabs={tabs} active={activeTab} onChange={setActiveTab} />
    </div>
  );
}

export default definePlugin(() => ({
  name: "BC-250 Control",
  titleView: <div className={staticClasses.Title}>BC-250 Control</div>,
  content: <Content />,
  icon: <FaMicrochip />,
  onDismount() {},
}));
