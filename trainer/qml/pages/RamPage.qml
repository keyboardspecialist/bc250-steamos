import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    spacing: 8
    readonly property var ram: (backend.snapshot || {}).ram || ({})
    readonly property bool controlsEnabled: Boolean(ram.available) && !backend.busy
    readonly property bool ttmWritable: controlsEnabled && ram.ttmState !== "foreign"
    readonly property bool umaValid: umaMiB >= 256 && umaMiB <= 12288
        && umaMiB % 16 === 0 && umaMiB !== 2048
    property int umaMiB: ram.umaLastRequestedMiB || 512
    property int ttmPages: ram.ttmConfiguredPages || 3014656

    function gibibytes(pages) {
        return (Number(pages) / 262144).toFixed(2)
    }

    C.ConfirmDialog { id: confirm }

    C.SectionHeader { text: "RAM / VRAM split" }
    RowLayout {
        Layout.fillWidth: true
        C.MetricTile {
            label: "CMOS MINIMUM"
            value: root.ram.umaLastRequestedMiB ? root.ram.umaLastRequestedMiB + " MiB" : "UNKNOWN"
            Layout.fillWidth: true
        }
        C.MetricTile {
            label: "TTM DYNAMIC"
            value: root.ram.ttmConfiguredPages ? root.gibibytes(root.ram.ttmConfiguredPages) + " GiB" : "DEFAULT"
            accent: "#ef48bb"
            Layout.fillWidth: true
        }
        C.MetricTile {
            label: "BOOT STATE"
            value: root.ram.rebootRequired ? "REBOOT" : "ACTIVE"
            accent: root.ram.rebootRequired ? "#ff9a55" : "#49ff9a"
            Layout.fillWidth: true
        }
    }
    C.StatusRow {
        label: "Memory utility"
        value: root.ram.toolState === "verified" ? "Verified " + (root.ram.toolVersion || "")
            : root.ram.toolState === "invalid" ? "Unsafe / partial" : "Installed on first CMOS write"
        health: root.ram.toolState === "verified" ? 1 : root.ram.toolState === "invalid" ? -1 : 0
    }
    C.StatusRow {
        label: "TTM configured / boot / live"
        value: (root.ram.ttmConfiguredPages || "default") + " / "
            + (root.ram.ttmBootPages || "default") + " / "
            + (root.ram.ttmLivePages || "default") + " pages"
        health: root.ram.ttmState === "foreign" ? -1 : root.ram.rebootRequired ? 0 : 1
    }
    Text {
        visible: !root.ram.available || root.ram.ttmState === "foreign"
        text: !root.ram.available
            ? "RAM control requires reinstalling the frontend to update the shared service payload."
            : "A foreign or unsafe TTM configuration exists. The toolkit will not replace it."
        color: "#ff6aa2"
        font.family: "monospace"; font.pixelSize: 9
        wrapMode: Text.Wrap; Layout.fillWidth: true
    }

    C.SectionHeader { text: "CMOS minimum VRAM" }
    Text {
        text: "Persistent minimum reserved VRAM. Reboot applies the write; clear CMOS physically if the selected split prevents boot. 2048 MiB is blocked."
        color: "#ff9abd"; font.family: "monospace"; font.pixelSize: 9
        wrapMode: Text.Wrap; Layout.fillWidth: true
    }
    RowLayout {
        Layout.fillWidth: true
        Repeater {
            model: [256, 512, 4096, 8192]
            C.NeonButton {
                required property int modelData
                text: modelData < 1024 ? modelData + "M" : modelData / 1024 + "G"
                checked: root.umaMiB === modelData
                accent: checked ? "#ef48bb" : "#22e7f2"
                Layout.fillWidth: true
                onClicked: root.umaMiB = modelData
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        C.NeonSpinBox {
            objectName: "umaInput"
            from: 256; to: 12288; stepSize: 16; value: root.umaMiB; editable: true
            Layout.fillWidth: true; enabled: root.controlsEnabled
            onValueModified: root.umaMiB = value
            textFromValue: function(value) { return value + " MiB UMA" }
            valueFromText: function(text) { return parseInt(text) || 256 }
        }
        C.NeonButton {
            objectName: "writeUmaButton"
            text: "WRITE CMOS"; accent: "#ff6aa2"
            enabled: root.controlsEnabled && root.umaValid
            onClicked: confirm.ask("Write CMOS minimum VRAM?",
                "This writes battery-backed CMOS and applies after reboot. The setting persists across operating systems and uninstall. If the machine no longer boots, clear CMOS with the board jumper or battery.", true,
                function() { root.backend.setUmaSize(root.umaMiB) })
        }
    }

    C.SectionHeader { text: "Dynamic TTM limit" }
    RowLayout {
        Layout.fillWidth: true
        Repeater {
            model: [{label: "8G", pages: 2097152}, {label: "10G", pages: 2621440},
                    {label: "GUIDE 11.5G", pages: 3014656}, {label: "12G", pages: 3145728}]
            C.NeonButton {
                required property var modelData
                text: modelData.label
                checked: root.ttmPages === modelData.pages
                accent: checked ? "#ef48bb" : "#22e7f2"
                Layout.fillWidth: true
                onClicked: root.ttmPages = modelData.pages
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        C.NeonSpinBox {
            objectName: "ttmInput"
            from: 65536; to: 3145728; stepSize: 65536; value: root.ttmPages; editable: true
            Layout.fillWidth: true; enabled: root.ttmWritable
            onValueModified: root.ttmPages = value
            textFromValue: function(value) { return value + " pages // " + root.gibibytes(value) + " GiB" }
            valueFromText: function(text) { return parseInt(text) || 65536 }
        }
        C.NeonButton {
            objectName: "setTtmButton"
            text: "SET TTM"; enabled: root.ttmWritable
            onClicked: confirm.ask("Update dynamic VRAM limit?",
                "This writes a toolkit-owned GRUB drop-in, regenerates the SteamOS boot configuration, and requires a reboot. The prior configuration is restored if regeneration fails.", true,
                function() { root.backend.setTtmPages(root.ttmPages) })
        }
        C.NeonButton {
            objectName: "removeTtmButton"
            text: "REMOVE"; accent: "#ff6aa2"
            enabled: root.ttmWritable && root.ram.ttmState === "configured"
            onClicked: confirm.ask("Remove dynamic VRAM override?",
                "The toolkit-owned TTM GRUB drop-in will be removed and GRUB regenerated. Reboot is required to return to the kernel default.", false,
                function() { root.backend.removeTtmOverride() })
        }
    }
}
