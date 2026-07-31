import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    spacing: 8
    readonly property var snap: backend.snapshot || ({})
    readonly property var cu: snap.cu || ({})
    readonly property bool writable: advanced.checked && Boolean(cu.controllable) && !backend.busy

    C.ConfirmDialog { id: confirm }
    C.SectionHeader { text: "Compute unit routing" }
    RowLayout {
        Layout.fillWidth: true
        C.MetricTile { label: "ACTIVE"; value: (root.cu.total ?? "--") + " CU"; Layout.fillWidth: true }
        C.MetricTile { label: "MAXIMUM"; value: (root.cu.maximum ?? "--") + " CU"; accent: "#ef48bb"; Layout.fillWidth: true }
        C.MetricTile { label: "FACTORY"; value: (root.cu.factoryTotal ?? "--") + " CU"; accent: "#49ff9a"; Layout.fillWidth: true }
    }
    C.StatusRow { label: "Saved mask table"; value: (root.cu.savedMasks || []).length === 4 ? "Available" : "Unavailable"; health: (root.cu.savedMasks || []).length === 4 ? 1 : -1 }
    C.StatusRow { label: "Boot replay service"; value: (root.cu.service || {}).enabled || "Unknown"; health: (root.cu.service || {}).enabled === "enabled" ? 1 : -1 }
    C.StatusRow { label: "Update persistence"; value: root.cu.protected ? "Protected" : "Pending"; health: root.cu.protected ? 1 : -1 }

    C.SectionHeader { text: "Live WGP map" }
    RowLayout {
        Layout.fillWidth: true
        Text { text: "ROUTE"; color: "#91a5b3"; font.family: "monospace"; font.pixelSize: 9; Layout.preferredWidth: 58 }
        Repeater {
            model: 5
            Text { required property int index; text: "CU" + index * 2 + "-" + (index * 2 + 1); color: "#91a5b3"; font.family: "monospace"; font.pixelSize: 8; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
        }
    }
    Repeater {
        model: root.cu.rows || []
        RowLayout {
            id: routeRow
            required property var modelData
            Layout.fillWidth: true
            Text { text: "SE" + routeRow.modelData.se + ".SH" + routeRow.modelData.sh; color: "#d7e7ee"; font.family: "monospace"; font.pixelSize: 9; Layout.preferredWidth: 58 }
            Repeater {
                model: 5
                C.NeonButton {
                    id: routeButton
                    required property int index
                    readonly property bool routed: Boolean(routeRow.modelData.wgps[index])
                    readonly property bool factoryRoute: Boolean(routeRow.modelData.factoryWgps[index])
                    text: factoryRoute ? (routed ? "OEM" : "OEM!") : routed ? "ON" : "OFF"
                    accent: factoryRoute ? "#49ff9a" : routed ? "#22e7f2" : "#ff4d8d"
                    enabled: root.writable && !factoryRoute
                    Layout.fillWidth: true
                    hint: factoryRoute ? "Factory route is locked." : !advanced.checked ? "Enable advanced live editing first." : root.cu.liveReason || "Toggle harvested WGP pair"
                    onClicked: {
                        var selected = index
                        var next = !routed
                        confirm.ask((next ? "Enable " : "Disable ") + "CU" + selected * 2 + "-" + (selected * 2 + 1) + "?",
                            "This immediately writes GPU routing registers. Factory-disabled compute units may be physically defective and can cause corruption, a GPU hang, or a forced reboot. Save all work first.", true,
                            function() { root.backend.setCuWgp(routeRow.modelData.se, routeRow.modelData.sh, selected, next) })
                    }
                }
            }
        }
    }
    Text { visible: !(root.cu.rows || []).length; text: "Live routing is unavailable. " + (root.cu.liveReason || "The service did not return a verified routing map."); color: "#ff6aa2"; font.family: "monospace"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true }

    C.SectionHeader { text: "Safety interlock" }
    Switch {
        id: advanced
        text: "ARM LIVE WGP EDITING"
        enabled: Boolean(root.cu.controllable) && !root.backend.busy
        palette.text: checked ? "#ff6aa2" : "#b7cbd4"
    }
    Text {
        text: "Harvested routes failed or skipped factory validation. Every change requires a separate confirmation; script-level checks remain authoritative."
        color: "#ff9abd"; font.family: "monospace"; font.pixelSize: 9
        wrapMode: Text.Wrap; Layout.fillWidth: true
    }
}
