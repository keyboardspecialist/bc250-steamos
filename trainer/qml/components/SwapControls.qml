import QtQuick 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    id: root
    required property var backend
    readonly property var swap: (backend.snapshot || {}).swap || ({})
    readonly property var capabilities: backend.capabilities || ({})
    readonly property bool controllable: swap.available === true && !backend.busy
        && ((backend.snapshot || {}).toolkit || {}).privileged === true
    readonly property bool configured: ["zram", "zswap", "legacy-zswap"].indexOf(swap.configuredProfile) >= 0
    property string mode: "zram"
    property string compressor: "zstd"
    property int sizeGiB: 16
    property int swappiness: swap.configuredSwappiness ?? swap.swappiness ?? 60
    spacing: 8
    ConfirmDialog { id: confirm; objectName: "swapConfirm" }
    SectionHeader { text: "Compressed swap / disk fallback" }
    StatusRow { label: "Configured / active"; value: (root.swap.configuredProfile || "Unknown") + " / " + (root.swap.runtime || "Unknown") }
    StatusRow { label: "Disk swap / pending"; value: (root.swap.diskSizeGiB ?? "Unknown") + " GiB / " + (root.swap.pending || "Unknown") }
    StatusRow { label: "Swappiness (active / saved)"; value: (root.swap.swappiness ?? "Unknown") + " / " + (root.swap.configuredSwappiness ?? "OS default") }
    Text {
        text: root.swap.error || (root.swap.available !== true ? "Update the installed frontend / shared service to enable native swap controls." : "Zram: half-RAM logical capacity at priority 100 with a 16 GiB disk fallback at priority 10 by default. Zswap: 10% RAM cache and disk swap. Reboot to switch profiles; no live swapoff. Existing files are reused, not resized: remove, reboot, finish removal, then install a different size.")
        textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
        color: "#7898a3"; font.family: "monospace"; font.pixelSize: 9
    }
    NeonComboBox {
        Layout.fillWidth: true; model: ["Zram + disk fallback", "Zswap + disk"]
        enabled: root.controllable && root.capabilities.ConfigureSwap === true
        onActivated: { root.mode = currentIndex === 0 ? "zram" : "zswap"; root.compressor = currentIndex === 0 ? "zstd" : "lz4"; }
    }
    NeonComboBox {
        Layout.fillWidth: true; model: ["Zstandard (higher ratio)", "LZ4 (faster)"]
        enabled: root.controllable && root.capabilities.ConfigureSwap === true
        currentIndex: root.compressor === "zstd" ? 0 : 1
        onActivated: root.compressor = currentIndex === 0 ? "zstd" : "lz4"
    }
    Text { text: "DISK SWAP (GiB): 4-64; 0 disables zram fallback. Default: 16."; color: "#7898a3"; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: 9 }
    NeonSpinBox { from: 0; to: 64; value: root.sizeGiB; editable: true; enabled: root.controllable; onValueModified: root.sizeGiB = value }
    NeonButton {
        objectName: "swapConfigure"
        text: "CONFIGURE SWAP PROFILE"
        enabled: root.controllable && root.capabilities.ConfigureSwap === true && (root.sizeGiB >= 4 && root.sizeGiB <= 64 || root.mode === "zram" && root.sizeGiB === 0)
        onClicked: confirm.ask("Configure " + root.mode + " (" + root.compressor + ") with " + root.sizeGiB + " GiB disk swap?",
            "Save your work and ensure size + 1 GiB free persistent storage. Reboot to apply. Zram + disk disables zswap to avoid double compression. Foreign configurations are refused; active swapfiles are never removed.",
            true, function() { root.backend.configureSwap(root.mode, root.compressor, root.sizeGiB) })
    }
    Text { text: "SWAPPINESS (0-200, global for all swap devices)"; color: "#7898a3"; font.pixelSize: 9 }
    NeonSpinBox { from: 0; to: 200; value: root.swappiness; editable: true; enabled: root.controllable && root.configured; onValueModified: root.swappiness = value }
    NeonButton {
        objectName: "swapSwappiness"
        text: "SET SWAPPINESS"; enabled: root.controllable && root.configured && root.capabilities.SetSwappiness === true && root.swap.pending !== "uninstall"
        onClicked: confirm.ask("Set vm.swappiness=" + root.swappiness + "?",
            "Applies now and at boot. Retained across profile changes; profile removal restores the OS default after reboot. No automatic default override.",
            false, function() { root.backend.setSwappiness(root.swappiness) })
    }
    NeonButton { objectName: "swapVerify"; text: "VERIFY SWAP PROFILE"; enabled: root.controllable && root.configured && root.capabilities.VerifySwap === true; onClicked: root.backend.verifySwap() }
    NeonButton {
        objectName: "swapRemove"
        text: "REMOVE SWAP PROFILE"; enabled: root.controllable && (root.configured || root.swap.configuredProfile === "partial") && root.capabilities.RemoveSwapProfile === true
        onClicked: confirm.ask("Restore OS swap defaults?",
            "Active disk swap is never removed. If removal is pending, reboot and run removal again to reclaim the swapfile. Swappiness returns to the OS default after reboot.",
            true, function() { root.backend.removeSwapProfile() })
    }
    Text { text: root.swap.details || ""; visible: text.length > 0; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: "#7898a3"; font.pixelSize: 9 }
}
