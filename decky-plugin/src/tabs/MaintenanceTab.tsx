import { PanelSection, Spinner } from "@decky/ui";
import { useEffect, useRef, useState } from "react";
import { getCliCatalog, openCliSection } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { CliCatalog, CliSection } from "../types";
import type { MutationRunner } from "./shared";

export function MaintenanceTab({ busy, runMutation }: { busy: boolean; runMutation: MutationRunner }) {
  const [catalog, setCatalog] = useState<CliCatalog | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const mounted = useRef(false);
  const discoveryRunning = useRef(false);

  const discover = async () => {
    if (discoveryRunning.current) return;
    discoveryRunning.current = true;
    setLoading(true);
    try {
      const next = await getCliCatalog();
      if (next.schemaVersion !== 1 || !Array.isArray(next.sections)) throw new Error("Unsupported CLI catalog. Update the backend / plugin together.");
      if (mounted.current) {
        setCatalog(next);
        setError("");
      }
    } catch (caught) {
      if (mounted.current) {
        setCatalog(null);
        setError(caught instanceof Error ? caught.message : String(caught));
      }
    } finally {
      discoveryRunning.current = false;
      if (mounted.current) setLoading(false);
    }
  };

  useEffect(() => {
    mounted.current = true;
    void discover();
    return () => { mounted.current = false; };
  }, []);

  const open = (section: CliSection) => runMutation(
    `${section.title} terminal requested`,
    async () => {
      setNotice("");
      setError("");
      try {
        await openCliSection(section.id);
        if (mounted.current) setNotice(`Terminal requested for ${section.title}. Continue in Desktop Mode; opening a terminal does not mean its commands have completed.`);
      } catch (caught) {
        if (mounted.current) setError(caught instanceof Error ? caught.message : String(caught));
        throw caught;
      }
    },
    section.risk === "read-only" ? undefined : {
      title: `Open ${section.title} ${section.risk === "maintenance" ? "maintenance" : "advanced"} menu?`,
      description: "This hands off to the interactive toolkit CLI, not inline Decky controls. The menu can change system configuration, install components, or require reboot / recovery. Switch to Desktop Mode, save your work, and review the CLI's own prompts before applying changes. Sudo authentication happens in the terminal.",
      destructive: true,
    },
    { refresh: false },
  );

  return (
    <>
      <PanelSection title="Maintenance / CLI">
        <EmptyState>
          Expert and maintenance features use an explicit interactive CLI handoff, not native inline controls.
          Switch to Desktop Mode first: terminals may be invisible or inaccessible in Gaming Mode.
          The terminal runs as the logged-in user; privileged CLI actions may ask for sudo there.
          No password is collected by this UI. Only backend-allowlisted sections can be opened.
        </EmptyState>
        {loading && <Spinner />}
        <StatusRow label="CLI handoff" value={catalog?.available ? "Available" : loading ? "Discovering" : "Unavailable"}
          good={catalog?.available ?? false} />
        {catalog?.reason && <EmptyState>{catalog.reason}</EmptyState>}
        <StatusRow label="CLI checkout version" value={catalog?.toolkitVersion ?? "Unknown / legacy checkout"} />
        <EmptyState>Checkout capabilities are separate from the plugin and installed backend. Refresh the frontend installation after updating shared service code.</EmptyState>
        {error && <EmptyState>{error}</EmptyState>}
        {notice && <EmptyState>{notice}</EmptyState>}
        {!loading && catalog?.sections.length === 0 && <EmptyState>No CLI sections were advertised by this backend.</EmptyState>}
        <ActionButton label="Refresh CLI availability" disabled={busy || loading} onClick={() => void discover()} />
      </PanelSection>
      {catalog?.sections.map((section) => (
        <PanelSection key={section.id} title={section.title}>
          <StatusRow label="Interface / risk" value={`CLI handoff · ${section.risk}`} />
          <ActionButton label={`Open ${section.title} in terminal`} description={section.description}
            disabled={busy || loading || !catalog.available} onClick={() => open(section)} />
        </PanelSection>
      ))}
    </>
  );
}
