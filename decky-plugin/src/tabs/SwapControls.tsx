import { DropdownItem, PanelSection, SliderField } from "@decky/ui";
import { useEffect, useState } from "react";
import { configureSwap, removeSwapProfile, setSwappiness, verifySwap } from "../api";
import { ActionButton, EmptyState, StatusRow } from "../components/Common";
import { controlApiSupports } from "../parity";
import type { TabProps } from "./shared";

export function SwapControls({ snapshot, busy, runMutation }: TabProps) {
  const swap = snapshot.swap;
  const [mode, setMode] = useState("zram");
  const [compressor, setCompressor] = useState("zstd");
  const [size, setSize] = useState(16);
  const [swappiness, setValue] = useState(swap?.configuredSwappiness ?? swap?.swappiness ?? 60);
  useEffect(() => { setValue(swap?.configuredSwappiness ?? swap?.swappiness ?? 60); }, [swap?.configuredSwappiness, swap?.swappiness]);
  const disabled = busy || !snapshot.toolkit.privileged || !swap?.available
    || !controlApiSupports(snapshot.toolkit, "swap-control");
  const valid = Number.isInteger(size) && (size >= 4 && size <= 64 || mode === "zram" && size === 0);
  const configured = swap?.configuredProfile === "zram" || swap?.configuredProfile === "zswap" || swap?.configuredProfile === "legacy-zswap";
  return <PanelSection title="Compressed swap / disk fallback">
    <StatusRow label="Configured / active" value={`${swap?.configuredProfile ?? "Unknown"} / ${swap?.runtime ?? "Unknown"}`} />
    <StatusRow label="Disk swap / pending" value={`${swap?.diskSizeGiB ?? 0} GiB / ${swap?.pending ?? "Unknown"}`} />
    <StatusRow label="Swappiness (active / saved)" value={`${swap?.swappiness ?? "Unknown"} / ${swap?.configuredSwappiness ?? "OS default"}`} />
    <EmptyState>{swap?.error || (!swap?.available ? "Update the installed plugin / backend to enable native swap controls." : "Zram uses half-RAM logical capacity at priority 100 and a 16 GiB disk fallback at priority 10 by default. Zswap uses a 10% RAM cache and disk swap. Profile changes require reboot; no live swapoff. Existing files are reused, not resized: remove, reboot, finish removal, then install a different size.")}</EmptyState>
    <DropdownItem label="Swap profile" selectedOption={mode} disabled={disabled}
      rgOptions={[{ data: "zram", label: "Zram + disk fallback" }, { data: "zswap", label: "Zswap + disk" }]}
      onChange={(option) => { setMode(String(option.data)); setCompressor(option.data === "zram" ? "zstd" : "lz4"); }} />
    <DropdownItem label="Compression" selectedOption={compressor} disabled={disabled}
      rgOptions={[{ data: "zstd", label: "Zstandard (higher ratio)" }, { data: "lz4", label: "LZ4 (faster)" }]}
      onChange={(option) => setCompressor(String(option.data))} />
    <SliderField label="Disk swap size" value={size} min={0} max={64} step={1} valueSuffix=" GiB" editableValue
      description="4-64 GiB; 0 is allowed only for zram without a disk fallback. Default: 16 GiB."
      disabled={disabled} onChange={setSize} />
    <ActionButton label="Configure swap profile" disabled={disabled || !valid}
      onClick={() => runMutation("Swap profile configured; reboot to apply", () => configureSwap(mode, compressor, size), {
        title: `Configure ${mode} (${compressor}) with ${size} GiB disk swap?`, destructive: true,
        description: "Save your work and ensure enough free persistent storage (size + 1 GiB). Changes are reboot-gated. Zram + disk disables zswap to avoid double compression. The helper refuses foreign configurations and never removes an active swapfile.",
      })} />
    <SliderField label="Swappiness" value={swappiness} min={0} max={200} step={1} editableValue disabled={disabled || !configured} onChange={setValue}
      description="Global vm.swappiness for either profile; retained across profile changes. No automatic default override." />
    <ActionButton label="Set swappiness" disabled={disabled || !configured || !Number.isInteger(swappiness) || swappiness < 0 || swappiness > 200 || swap?.pending === "uninstall"}
      onClick={() => runMutation("Swappiness applied and saved", () => setSwappiness(swappiness), {
        title: `Set vm.swappiness=${swappiness}?`, description: "Applies now and at boot for all swap devices. Profile removal restores the OS default after reboot.",
      })} />
    <ActionButton label="Verify swap profile" disabled={disabled || !configured} onClick={() => runMutation("Swap verification completed", verifySwap)} />
    <ActionButton label="Remove swap profile" disabled={disabled || (!configured && swap?.configuredProfile !== "partial")}
      onClick={() => runMutation("Swap removal requested; review reboot status", removeSwapProfile, {
        title: "Restore OS swap defaults?", destructive: true,
        description: "Active disk swap is never removed. If removal is pending, reboot and run removal again to reclaim the swapfile. Swappiness returns to the OS default after reboot.",
      })} />
    {swap?.details && <EmptyState>{swap.details}</EmptyState>}
  </PanelSection>;
}
