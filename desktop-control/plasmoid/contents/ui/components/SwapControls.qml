import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: root
    required property var backend
    readonly property var swap: backend.snapshot.swap || ({})
    readonly property bool available: swap.available === true
        && backend.snapshot.toolkit.controlApiVersion === 1
        && (backend.snapshot.toolkit.controlCapabilities || []).indexOf("swap-control") >= 0
    readonly property bool controllable: available && backend.snapshot.toolkit.privileged && !backend.busy
    readonly property bool configured: ["zram", "zswap", "legacy-zswap"].indexOf(swap.configuredProfile) >= 0
    property string mode: "zram"
    property string compressor: "zstd"
    property int sizeGiB: 16
    property int swappiness: swap.configuredSwappiness ?? swap.swappiness ?? 60
    readonly property bool validSize: sizeGiB >= 4 && sizeGiB <= 64 || mode === "zram" && sizeGiB === 0
    spacing: Kirigami.Units.smallSpacing
    ConfirmationDialog { id: confirm }
    Section {
        title: "Compressed swap / disk fallback"
        StatusRow { label: "Configured / active"; value: (root.swap.configuredProfile || "Unknown") + " / " + (root.swap.runtime || "Unknown") }
        StatusRow { label: "Disk swap / pending"; value: (root.swap.diskSizeGiB ?? "Unknown") + " GiB / " + (root.swap.pending || "Unknown") }
        StatusRow { label: "Swappiness (active / saved)"; value: (root.swap.swappiness ?? "Unknown") + " / " + (root.swap.configuredSwappiness ?? "OS default") }
        QQC2.Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: root.swap.error || (!root.available ? "Update the installed frontend / shared service to enable native swap controls." : "Zram: half-RAM logical capacity at priority 100 with a 16 GiB disk fallback at priority 10 by default. Zswap: 10% RAM cache and disk swap. Reboot to switch profiles; no live swapoff. Existing files are reused, not resized: remove, reboot, finish removal, then install a different size.")
        }
        QQC2.ComboBox {
            Layout.fillWidth: true; enabled: root.controllable
            model: ["Zram + disk fallback", "Zswap + disk"]
            onActivated: { root.mode = currentIndex === 0 ? "zram" : "zswap"; root.compressor = currentIndex === 0 ? "zstd" : "lz4"; }
        }
        QQC2.ComboBox {
            Layout.fillWidth: true; enabled: root.controllable; model: ["Zstandard (higher ratio)", "LZ4 (faster)"]
            currentIndex: root.compressor === "zstd" ? 0 : 1
            onActivated: root.compressor = currentIndex === 0 ? "zstd" : "lz4"
        }
        QQC2.Label { text: "Disk swap: 4-64 GiB; 0 disables zram disk fallback. Default: 16 GiB."; wrapMode: Text.Wrap; Layout.fillWidth: true }
        QQC2.SpinBox { from: 0; to: 64; value: root.sizeGiB; editable: true; enabled: root.controllable; onValueModified: root.sizeGiB = value }
        ActionButton {
            text: "Configure swap profile"; enabled: root.controllable && root.validSize
            onClicked: confirm.ask("Configure " + root.mode + " (" + root.compressor + ") with " + root.sizeGiB + " GiB disk swap?",
                "Save your work and ensure size + 1 GiB free persistent storage. Reboot to apply. Zram + disk disables zswap to avoid double compression. Foreign configurations are refused and active swapfiles are never removed.",
                true, function() { root.backend.configureSwap(root.mode, root.compressor, root.sizeGiB); })
        }
        QQC2.Label { text: "Swappiness (0-200, global for all swap devices)" }
        QQC2.SpinBox { from: 0; to: 200; value: root.swappiness; editable: true; enabled: root.controllable && root.configured; onValueModified: root.swappiness = value }
        ActionButton {
            text: "Set swappiness"; enabled: root.controllable && root.configured && root.swap.pending !== "uninstall"
            onClicked: confirm.ask("Set vm.swappiness=" + root.swappiness + "?",
                "Applies now and at boot. Retained across profile changes; removing the profile restores the OS default after reboot. No automatic default override.",
                false, function() { root.backend.setSwappiness(root.swappiness); })
        }
        ActionButton { text: "Verify swap profile"; enabled: root.controllable && root.configured; onClicked: root.backend.verifySwap() }
        ActionButton {
            text: "Remove swap profile"; enabled: root.controllable && (root.configured || root.swap.configuredProfile === "partial")
            onClicked: confirm.ask("Restore OS swap defaults?",
                "Active disk swap is never removed. If removal is pending, reboot and run removal again to reclaim the swapfile. Swappiness returns to the OS default after reboot.",
                true, function() { root.backend.removeSwapProfile(); })
        }
        QQC2.Label { text: root.swap.details || ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; visible: text.length > 0 }
    }
}
