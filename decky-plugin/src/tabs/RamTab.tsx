import { PanelSection, SliderField } from "@decky/ui";
import { useState } from "react";
import { removeTtmOverride, setTtmPages, setUmaSize } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import type { TabProps } from "./shared";

export function RamTab({ snapshot, busy, runMutation }: TabProps) {
  const { ram } = snapshot;
  const [umaMiB, setUmaMiB] = useState(ram.umaLastRequestedMiB || 512);
  const [ttmPages, setTtmPageCount] = useState(ram.ttmConfiguredPages || 3014656);
  const controlsDisabled = busy || !snapshot.toolkit.privileged || !ram.available;
  const ttmDisabled = controlsDisabled || ram.ttmState === "foreign";
  const umaValid = umaMiB >= 256 && umaMiB <= 12288 && umaMiB % 16 === 0
    && umaMiB !== 2048;
  const gibibytes = (pages: number | null) => pages === null
    ? "Default"
    : `${(pages / 262144).toFixed(2)} GiB`;

  return (
    <>
      <PanelSection title="RAM / VRAM Status">
        <StatusRow
          label="Memory utility"
          value={ram.toolState === "verified"
            ? `Verified ${ram.toolVersion || ""}`
            : ram.toolState === "invalid" ? "Unsafe / partial" : "Not installed"}
          good={ram.toolState === "verified"}
        />
        <StatusRow
          label="CMOS minimum VRAM"
          value={ram.umaLastRequestedMiB ? `${ram.umaLastRequestedMiB} MiB` : "Unknown"}
        />
        <StatusRow
          label="TTM configured"
          value={gibibytes(ram.ttmConfiguredPages)}
          good={ram.ttmState !== "foreign"}
        />
        <StatusRow label="TTM boot" value={gibibytes(ram.ttmBootPages)} />
        <StatusRow label="TTM live" value={gibibytes(ram.ttmLivePages)} />
        <StatusRow
          label="Boot change"
          value={ram.rebootRequired ? "Reboot required" : "Applied"}
          good={!ram.rebootRequired}
        />
      </PanelSection>

      {!ram.available && (
        <EmptyState>Reinstall the plugin to add the trusted RAM / VRAM helper.</EmptyState>
      )}
      {ram.ttmState === "foreign" && (
        <EmptyState>A foreign or unsafe TTM configuration exists. The toolkit will not replace it.</EmptyState>
      )}

      <PanelSection title="CMOS Minimum VRAM">
        <EmptyState>
          This persistent setting applies after reboot and survives uninstall. If the selected split prevents boot, clear CMOS physically. 2048 MiB is blocked.
        </EmptyState>
        <SliderField
          label="Minimum reserved VRAM"
          value={umaMiB}
          min={256}
          max={12288}
          step={16}
          valueSuffix=" MiB"
          editableValue
          disabled={controlsDisabled}
          onChange={setUmaMiB}
        />
        <ActionButton
          label="Write CMOS minimum"
          description={!umaValid ? "Choose an aligned value from 256-12288 MiB other than 2048 MiB." : undefined}
          disabled={controlsDisabled || !umaValid}
          onClick={() => runMutation(
            `CMOS minimum VRAM set to ${umaMiB} MiB; reboot required`,
            () => setUmaSize(umaMiB),
            {
              title: "Write CMOS minimum VRAM?",
              description: "This writes battery-backed CMOS and persists across operating systems and uninstall. If the machine no longer boots, clear CMOS with the board jumper or battery.",
              destructive: true,
            },
          )}
        />
      </PanelSection>

      <PanelSection title="Dynamic TTM Limit">
        <SliderField
          label="Maximum dynamic VRAM"
          description={`${gibibytes(ttmPages)} (${ttmPages} pages)`}
          value={ttmPages}
          min={65536}
          max={3145728}
          step={65536}
          editableValue
          disabled={ttmDisabled}
          onChange={setTtmPageCount}
        />
        <ActionButton
          label="Set TTM limit"
          disabled={ttmDisabled}
          onClick={() => runMutation(
            `TTM limit set to ${gibibytes(ttmPages)}; reboot required`,
            () => setTtmPages(ttmPages),
            {
              title: "Update dynamic VRAM limit?",
              description: "This writes a toolkit-owned GRUB drop-in, regenerates the SteamOS boot configuration, and requires a reboot.",
              destructive: true,
            },
          )}
        />
        <ActionButton
          label="Remove TTM override"
          disabled={ttmDisabled || ram.ttmState !== "configured"}
          onClick={() => runMutation(
            "TTM override removed; reboot required",
            removeTtmOverride,
            {
              title: "Remove dynamic VRAM override?",
              description: "The toolkit-owned TTM GRUB drop-in will be removed and GRUB regenerated. Reboot returns to the kernel default.",
            },
          )}
        />
      </PanelSection>
    </>
  );
}
