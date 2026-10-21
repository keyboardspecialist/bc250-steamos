import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ColumnLayout {
    id: root
    required property var backend
    required property var inventory
    required property var candidate
    required property var game
    property bool orphan: false
    readonly property string installState: candidate.state || "unavailable"
    readonly property bool blocked: ["modified", "invalid"].indexOf(installState) >= 0
    readonly property bool managed: ["ready", "upgrade-required", "repair-required", "restorable", "missing"].indexOf(installState) >= 0
    readonly property bool conflict: candidate.fsr4Managed === true || candidate.helixsrManaged === true
    readonly property bool gameReady: orphan || (game.fullyInstalled === true && game.installPresent === true)
    readonly property bool installAllowed: !orphan && inventory.optiscalerAvailable === true && gameReady
        && candidate.discovered === true && !blocked && !conflict
        && (["not-installed", "upgrade-required", "repair-required"].indexOf(installState) >= 0
            || (installState === "restorable" && candidate.currentRelease === true))
    readonly property var proxies: ["winmm.dll", "dxgi.dll", "d3d12.dll", "dbghelp.dll", "version.dll", "wininet.dll", "winhttp.dll"]
    property string proxy: candidate.proxy || "winmm.dll"
    Layout.fillWidth: true
    spacing: 5
    function request(install) {
        var id = String(candidate.candidateId); var selectedProxy = root.proxy
        confirm.ask(install ? "Install / update / repair OptiScaler?" : "Restore pre-OptiScaler files?",
            "Close the game first. Do not use injected DLLs in online or anti-cheat games; bans are possible. "
                + "The service revalidates ownership and rollback copies; modified or ambiguous files are not overwritten. Steam launch options must be applied manually.", true,
            function() { if (install) root.backend.installOptiscaler(id, selectedProxy); else root.backend.uninstallOptiscaler(id) })
    }
    ConfirmDialog { id: confirm; objectName: "optiscalerConfirm" }
    Text { text: "OptiScaler: " + (root.candidate.relativePath || root.candidate.installPath || "Unknown directory"); textFormat: Text.PlainText; color: "#9cdbe0"; font.pixelSize: 10; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true }
    StatusRow { label: root.orphan ? "Unassociated OptiScaler" : "OptiScaler state / release"; value: root.installState + (root.candidate.release ? " / " + root.candidate.release : "") + (root.candidate.proxy ? " / " + root.candidate.proxy : "") }
    Text { text: "Executables: " + (root.candidate.executables || []).join(", "); color: "#9cdbe0"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true }
    NeonComboBox { model: root.proxies; currentIndex: Math.max(0, root.proxies.indexOf(root.proxy)); enabled: !root.backend.busy && !root.managed && !root.orphan; onActivated: root.proxy = currentText; Layout.fillWidth: true }
    TextArea { visible: Boolean(root.candidate.launchOption); text: root.candidate.launchOption || ""; readOnly: true; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere; Layout.fillWidth: true }
    RowLayout {
        NeonButton { objectName: "optiInstall"; visible: !root.orphan; text: "INSTALL / UPDATE / REPAIR"; enabled: !root.backend.busy && root.installAllowed; onClicked: root.request(true) }
        NeonButton { objectName: "optiRestore"; text: "RESTORE ORIGINALS"; enabled: !root.backend.busy && root.gameReady && root.managed && !root.blocked && !root.conflict; onClicked: root.request(false) }
    }
    Text {
        text: root.blocked ? "Integrity warning: modified or invalid files; resolve manually."
            : root.conflict ? "Restore FSR4 / HelixSR in this directory before changing OptiScaler."
            : !root.gameReady ? "Finish the Steam install or update first."
            : !root.candidate.discovered && !root.orphan ? "Directory not discovered; refresh the inventory."
            : "Choose only the directory containing the game executable; the service never accepts arbitrary paths."
        color: "#ffb06a"; font.pixelSize: 9; wrapMode: Text.Wrap; Layout.fillWidth: true
    }
}
