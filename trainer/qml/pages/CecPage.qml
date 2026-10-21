import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    readonly property var snap: backend.snapshot || ({})
    readonly property var cec: snap.cec || ({})
    readonly property bool controls: backend.serviceAvailable && !backend.busy
        && (snap.toolkit || {}).cecAvailable === true && cec.devicePresent === true
    property string broadcastName: cec.osdName || ""
    readonly property bool validName: broadcastName.trim().length > 0
        && encodeURIComponent(broadcastName).replace(/%[0-9A-F]{2}|./g, "x").length <= 14
        && !/["\\\u0000-\u001f\u007f-\u009f]/.test(broadcastName)
    spacing: 8
    onCecChanged: if (!backend.busy) broadcastName = cec.osdName || ""
    C.ConfirmDialog { id: confirm; objectName: "cecConfirmDialog" }
    C.SectionHeader { text: "HDMI CEC / television and receiver" }
    C.StatusRow { label: "CEC adapter"; value: root.cec.devicePresent === true ? "Connected" : "Unavailable" }
    C.StatusRow { label: "Daemon"; value: (root.cec.service || {}).active || "Unavailable" }
    C.StatusRow { label: "Active source"; value: typeof root.cec.active !== "boolean" ? "Unknown" : root.cec.active ? "This console" : "Another source" }
    C.StatusRow { label: "Poweroff / sleep integration"; value: (root.cec.poweroffIntegration ? "Installed" : "Unavailable") + " / " + (root.cec.sleepIntegration ? "Installed" : "Unavailable") }
    Text {
        visible: !root.controls
        text: backend.busy ? "An operation is active." : !root.cec.devicePresent
            ? "Connect a CEC-tunneling DP-to-HDMI adapter exposing /dev/cec0."
            : "CEC controls are unavailable from the installed service or toolkit."
        color: "#ffb06a"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true
    }
    RowLayout {
        Layout.fillWidth: true
        TextField { objectName: "cecName"; Layout.fillWidth: true; text: root.broadcastName; placeholderText: "Broadcast name (1-14 UTF-8 bytes)"; enabled: root.controls && typeof root.cec.osdName === "string"; onTextEdited: root.broadcastName = text }
        C.NeonButton {
            objectName: "cecNameApply"; text: "SET NAME"; enabled: root.controls && root.validName && root.broadcastName !== root.cec.osdName
            onClicked: { var name = root.broadcastName; confirm.ask("Change CEC broadcast name?", "The service validates the 14-byte UTF-8 limit and restarts CEC integration.", false, function() { root.backend.setCecName(name) }) }
        }
    }
    GridLayout {
        columns: 3; Layout.fillWidth: true
        Repeater {
            model: [{id:"tv-on",title:"TV ON"},{id:"tv-off",title:"TV STANDBY"},
                {id:"amp-on",title:"AMP ON"},{id:"amp-off",title:"AMP STANDBY"},
                {id:"switch",title:"TAKE SOURCE"},{id:"release",title:"RELEASE SOURCE"},
                {id:"vol-up",title:"VOLUME +"},{id:"vol-down",title:"VOLUME -"},{id:"mute",title:"MUTE"}]
            C.NeonButton {
                required property var modelData
                objectName: "cec-" + modelData.id
                text: modelData.title; Layout.fillWidth: true; enabled: root.controls
                onClicked: {
                    var action = modelData.id
                    if (action === "tv-off" || action === "amp-off")
                        confirm.ask("Put HDMI device in standby?", "This may turn off the display or receiver and interrupt other users.", false, function() { root.backend.cecAction(action) })
                    else root.backend.cecAction(action)
                }
            }
        }
    }
    Repeater {
        model: [{key:"wake-tv",field:"wakeTv",title:"Wake TV on resume"},
            {key:"suspend-tv",field:"suspendTv",title:"TV standby on suspend"},
            {key:"allow-standby",field:"allowStandby",title:"Suspend console when TV turns off"},
            {key:"uinput",field:"uinput",title:"TV remote input"}]
        Switch {
            required property var modelData
            text: modelData.title; checked: root.cec[modelData.field] === true
            enabled: root.controls && typeof root.cec[modelData.field] === "boolean"
            onClicked: {
                var next = checked; var key = modelData.key
                checked = Qt.binding(function() { return root.cec[modelData.field] === true })
                confirm.ask("Change CEC integration?", "This changes automatic television, suspend, or remote-input behavior and restarts CEC integration.", false, function() { root.backend.setCecToggle(key, next) })
            }
        }
    }
}
