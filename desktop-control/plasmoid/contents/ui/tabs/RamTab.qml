import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var ram: backend.snapshot.ram || ({})
    readonly property bool controlsEnabled: ram.available && backend.snapshot.toolkit.privileged && !backend.busy
    readonly property bool ttmEnabled: controlsEnabled && ram.ttmState !== "foreign"
    readonly property bool umaValid: umaMiB >= 256 && umaMiB <= 12288
        && umaMiB % 16 === 0 && umaMiB !== 2048
    property int umaMiB: ram.umaLastRequestedMiB || 512
    property int ttmPages: ram.ttmConfiguredPages || 3014656
    spacing: Kirigami.Units.largeSpacing

    function gibibytes(pages) {
        return pages === null || pages === undefined ? "Default"
            : (Number(pages) / 262144).toFixed(2) + " GiB";
    }

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "RAM / VRAM Status"
        Components.StatusRow {
            label: "Memory utility"
            value: root.ram.toolState === "verified" ? "Verified " + (root.ram.toolVersion || "")
                : root.ram.toolState === "invalid" ? "Unsafe / partial" : "Not installed"
            health: root.ram.toolState === "verified" ? 1 : root.ram.toolState === "invalid" ? -1 : 0
        }
        Components.StatusRow { label: "CMOS minimum VRAM"; value: root.ram.umaLastRequestedMiB ? root.ram.umaLastRequestedMiB + " MiB" : "Unknown" }
        Components.StatusRow { label: "TTM configured"; value: root.gibibytes(root.ram.ttmConfiguredPages); health: root.ram.ttmState === "foreign" ? -1 : 1 }
        Components.StatusRow { label: "TTM boot"; value: root.gibibytes(root.ram.ttmBootPages) }
        Components.StatusRow { label: "TTM live"; value: root.gibibytes(root.ram.ttmLivePages) }
        Components.StatusRow { label: "Boot change"; value: root.ram.rebootRequired ? "Reboot required" : "Applied"; health: root.ram.rebootRequired ? 0 : 1 }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: !root.ram.available || root.ram.ttmState === "foreign"
            type: Kirigami.MessageType.Warning
            text: !root.ram.available ? "Reinstall the frontend to add the trusted RAM / VRAM helper."
                : "A foreign or unsafe TTM configuration exists. The toolkit will not replace it."
        }
    }

    Components.Section {
        title: "CMOS Minimum VRAM"
        QQC2.Label {
            text: "Persistent across operating systems and uninstall. If the selected split prevents boot, clear CMOS physically. 2048 MiB is blocked."
            wrapMode: Text.Wrap; color: Kirigami.Theme.neutralTextColor; Layout.fillWidth: true
        }
        QQC2.SpinBox {
            from: 256; to: 12288; stepSize: 16; value: root.umaMiB; editable: true
            enabled: root.controlsEnabled; Layout.fillWidth: true
            textFromValue: (value) => value + " MiB"; valueFromText: (text) => parseInt(text)
            onValueModified: root.umaMiB = value
        }
        Components.ActionButton {
            text: "Write CMOS minimum"; enabled: root.controlsEnabled && root.umaValid
            disabledReason: root.umaValid ? "RAM controls are unavailable." : "Choose an aligned value other than 2048 MiB."
            onClicked: confirmation.ask("Write CMOS minimum VRAM?",
                "This writes battery-backed CMOS and survives uninstall. If the machine no longer boots, clear CMOS with the board jumper or battery.",
                true, function() { root.backend.setUmaSize(root.umaMiB); })
        }
    }

    Components.Section {
        title: "Dynamic TTM Limit"
        QQC2.SpinBox {
            from: 65536; to: 3145728; stepSize: 65536; value: root.ttmPages; editable: true
            enabled: root.ttmEnabled; Layout.fillWidth: true
            textFromValue: (value) => value + " pages (" + root.gibibytes(value) + ")"
            valueFromText: (text) => parseInt(text)
            onValueModified: root.ttmPages = value
        }
        Components.ActionButton {
            text: "Set TTM limit"; enabled: root.ttmEnabled
            disabledReason: root.ram.ttmState === "foreign" ? "A foreign TTM configuration is present." : "RAM controls are unavailable."
            onClicked: confirmation.ask("Update dynamic VRAM limit?",
                "This writes a toolkit-owned GRUB drop-in, regenerates the SteamOS boot configuration, and requires a reboot.",
                true, function() { root.backend.setTtmPages(root.ttmPages); })
        }
        Components.ActionButton {
            text: "Remove TTM override"; enabled: root.ttmEnabled && root.ram.ttmState === "configured"
            disabledReason: "No toolkit-owned TTM override is active."
            onClicked: confirmation.ask("Remove dynamic VRAM override?",
                "The toolkit-owned TTM GRUB drop-in will be removed and GRUB regenerated. Reboot returns to the kernel default.",
                false, function() { root.backend.removeTtmOverride(); })
        }
    }
}
