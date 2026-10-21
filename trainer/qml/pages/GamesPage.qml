import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../components" as C

ColumnLayout {
    id: root
    required property var backend
    readonly property var inventory: backend.fsr4Inventory || ({})
    property string search: ""
    spacing: 8
    Component.onCompleted: backend.refreshFsr4()
    function visibleGames() {
        var query = search.trim().toLowerCase()
        return (inventory.games || []).filter(function(game) {
            return !query || String(game.name).toLowerCase().indexOf(query) >= 0 || String(game.appId).indexOf(query) >= 0
        }).slice(0, 100)
    }
    C.ConfirmDialog { id: confirm }
    C.SectionHeader { text: "FSR4 / experimental HelixSR / OptiScaler" }
    Text { text: "Do not use injected DLLs in online or anti-cheat games; bans are possible. Close games before changes. Exact rollback copies are preserved; modified files block writes."; color: "#ffb06a"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true }
    C.StatusRow { label: "FSR4 / OptiScaler release"; value: (root.inventory.currentRelease || "Unavailable") + " / " + (root.inventory.currentOptiscalerRelease || "Unavailable") }
    C.StatusRow { label: "HelixSR payload"; value: root.inventory.helixsrPayloadState || "Unavailable" }
    C.NeonButton {
        text: "PREPARE HELIXSR PAYLOAD"; enabled: !root.backend.busy && root.inventory.helixsrAvailable === true && root.inventory.helixsrPayloadState !== "ready"
        onClicked: confirm.ask("Prepare experimental HelixSR?", "Download official HelixSR and NVIDIA DLSS inputs, then generate the payload locally. This may take time. Do not use in anti-cheat or online games.", true, function() { root.backend.prepareHelixsr() })
    }
    TextField { objectName: "gameSearch"; placeholderText: "Search Steam game or app ID (first 100 matches)"; text: root.search; onTextEdited: root.search = text; Layout.fillWidth: true }
    C.NeonButton { text: "REFRESH GAME INVENTORY"; enabled: !root.backend.busy; onClicked: root.backend.refreshFsr4() }
    Text { text: (root.inventory.errors || []).join(" ") || (root.inventory.available === true ? root.visibleGames().length + " matching games" : "Steam inventory / helper unavailable. Start Steam once, or update the host service, then refresh."); color: root.inventory.available ? "#9cdbe0" : "#ffb06a"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true }
    Repeater {
        model: root.visibleGames()
        ColumnLayout {
            id: gameItem
            required property var modelData
            Layout.fillWidth: true
            C.SectionHeader { text: gameItem.modelData.name + " [" + gameItem.modelData.appId + "]" }
            Text { visible: !(gameItem.modelData.targets || []).length; text: "No compatible DLL discovered (scan: " + (gameItem.modelData.scanState || "unavailable") + ")."; color: "#7898a3"; font.pixelSize: 9 }
            Repeater {
                model: gameItem.modelData.optiscalerCandidates || []
                C.OptiscalerTarget { required property var modelData; backend: root.backend; inventory: root.inventory; candidate: modelData; game: gameItem.modelData }
            }
            Repeater {
                model: gameItem.modelData.targets || []
                C.GameTarget { required property var modelData; backend: root.backend; inventory: root.inventory; target: modelData; game: gameItem.modelData }
            }
        }
    }
    Repeater { model: root.inventory.orphanedTargets || []; C.GameTarget { required property var modelData; backend: root.backend; inventory: root.inventory; target: modelData; game: ({}); orphan: true } }
    Repeater { model: root.inventory.orphanedHelixsr || []; C.GameTarget { required property var modelData; backend: root.backend; inventory: root.inventory; target: modelData; game: ({}); orphan: true; helixOnly: true } }
    Repeater { model: root.inventory.orphanedOptiscaler || []; C.OptiscalerTarget { required property var modelData; backend: root.backend; inventory: root.inventory; candidate: modelData; game: ({}); orphan: true } }
}
