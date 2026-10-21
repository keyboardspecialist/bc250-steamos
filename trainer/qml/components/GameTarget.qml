import QtQuick 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    id: root
    required property var backend
    required property var inventory
    required property var target
    required property var game
    property bool orphan: false
    property bool helixOnly: false
    readonly property string installState: target.state || "unavailable"
    readonly property string helixState: helixOnly ? installState : target.helixsrState || "unavailable"
    readonly property bool blocked: ["modified", "invalid"].indexOf(installState) >= 0
    readonly property bool helixBlocked: ["modified", "invalid"].indexOf(helixState) >= 0
    readonly property bool gameReady: orphan || (game.fullyInstalled === true && game.installPresent === true)
    readonly property bool complete: gameReady && (orphan || game.scanState === "complete")
    readonly property bool fsrManaged: !helixOnly && ["ready", "upgrade-required", "missing"].indexOf(installState) >= 0
    readonly property bool helixManaged: helixOnly || target.helixsrManaged === true
    readonly property bool supported: String(target.relativePath || target.targetPath || "").replace(/\\/g, "/").split("/").pop().toLowerCase() === "amd_fidelityfx_upscaler_dx12.dll"
    readonly property bool directoryManaged: target.optiscalerManaged === true || hasManagedOptiscaler()
    readonly property bool fsrInstall: !orphan && supported && inventory.available === true && gameReady && !blocked
        && !helixManaged && target.discovered === true && ["available", "restored", "upgrade-required"].indexOf(installState) >= 0
    readonly property bool fsrRestore: !helixOnly && gameReady && !blocked && (orphan || fsrManaged)
    readonly property bool helixInstall: !orphan && inventory.helixsrAvailable === true && inventory.helixsrPayloadState === "ready"
        && complete && target.discovered === true && installState === "available" && !directoryManaged
        && !helixBlocked && helixState !== "unavailable"
    readonly property bool helixRestore: complete && helixManaged && !helixBlocked && !directoryManaged
        && (helixOnly || installState === "available")
    spacing: 5
    Layout.fillWidth: true

    function directory(path) {
        var normalized = String(path || "").replace(/\\/g, "/").replace(/\/+$/, "")
        var position = normalized.lastIndexOf("/")
        return position < 0 ? "." : normalized.slice(0, position) || "/"
    }
    function hasManagedOptiscaler() {
        return (game.optiscalerCandidates || []).some(function(candidate) {
            return ["not-installed", "unavailable"].indexOf(candidate.state) < 0
                && ((target.targetPath && candidate.installPath === directory(target.targetPath))
                    || (target.relativePath && candidate.relativePath === directory(target.relativePath)))
        })
    }
    function request(kind, install) {
        var id = String(target.targetId)
        confirm.ask((install ? "Install / update " : "Restore pre-") + kind + " game DLL?",
            "Close the game first. Do not use injected DLLs in online or anti-cheat games; bans are possible. "
                + (install ? "The service revalidates the discovered target and preserves exact rollback bytes."
                    : "Only verified managed files are restored from exact rollback copies. Modified or ambiguous files require manual recovery."), true,
            function() {
                if (kind === "FSR4") root.backend.setFsr4Dll(id, install)
                else if (install) root.backend.installHelixsr(id)
                else root.backend.uninstallHelixsr(id)
            })
    }
    ConfirmDialog { id: confirm; objectName: "gameTargetConfirm" }
    Text { text: root.target.relativePath || root.target.targetPath || "Unknown target"; textFormat: Text.PlainText; color: "#9cdbe0"; font.pixelSize: 10; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true }
    StatusRow { visible: !root.helixOnly; label: root.orphan ? "Unassociated FSR4 rollback" : "FSR4"; value: root.installState + (root.target.release ? " / " + root.target.release : "") }
    StatusRow { label: root.helixOnly ? "Unassociated HelixSR rollback" : "HelixSR"; value: root.helixState + (root.target.helixsrRelease ? " / " + root.target.helixsrRelease : root.helixOnly && root.target.release ? " / " + root.target.release : "") }
    RowLayout {
        Layout.fillWidth: true
        NeonButton { objectName: "fsrInstall"; visible: !root.helixOnly && !root.orphan; text: "FSR4 INSTALL / UPDATE"; enabled: !root.backend.busy && root.fsrInstall; onClicked: root.request("FSR4", true) }
        NeonButton { objectName: "fsrRestore"; visible: !root.helixOnly; text: "RESTORE FSR4"; enabled: !root.backend.busy && root.fsrRestore; onClicked: root.request("FSR4", false) }
    }
    RowLayout {
        Layout.fillWidth: true
        NeonButton { objectName: "helixInstall"; visible: !root.orphan; text: "HELIXSR INSTALL / UPDATE"; enabled: !root.backend.busy && root.helixInstall; onClicked: root.request("HelixSR", true) }
        NeonButton { objectName: "helixRestore"; text: "RESTORE HELIXSR"; enabled: !root.backend.busy && root.helixRestore; onClicked: root.request("HelixSR", false) }
    }
    Text {
        text: root.blocked || root.helixBlocked ? "Integrity warning: modified or invalid managed files. Resolve manually; writes are blocked."
            : !root.gameReady ? "Finish the Steam install or update first."
            : root.directoryManaged ? "Restore OptiScaler in this directory before managing HelixSR."
            : !root.complete ? "Complete the game scan before managing HelixSR."
            : "FSR4 and HelixSR are mutually exclusive. Restore the active DLL before switching."
        color: "#ffb06a"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true
    }
}
