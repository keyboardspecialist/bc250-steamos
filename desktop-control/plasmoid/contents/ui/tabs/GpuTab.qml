import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import "../components" as Components

ColumnLayout {
    id: root
    required property var backend
    readonly property var snapshot: backend.snapshot
    readonly property var gpu: snapshot.gpu
    readonly property var mesh: backend.meshStatus || ({})
    readonly property var fsr4: backend.fsr4Inventory || ({ games: [], orphanedTargets: [], errors: [] })
    property string fsr4Search: ""
    property string mode: gpu.mode
    property int minimum: gpu.minimum || 0
    property int maximum: gpu.maximum || gpu.configuredMax || 1500
    property int loadMinimum: Math.round((gpu.loadLower === null ? 0.65 : gpu.loadLower) * 100)
    property int loadMaximum: Math.round((gpu.loadUpper === null ? 0.80 : gpu.loadUpper) * 100)
    property int temperatureTarget: gpu.temperatureTarget || 85
    property int rampMs: gpu.climbMs || 500
    readonly property int frequencyMinimum: Math.max(root.gpu.allowedMinimum || 300, 300)
    readonly property bool frequencyValid: root.mode !== "range"
        || ((root.minimum === 0 || root.minimum >= root.frequencyMinimum) && root.minimum <= root.maximum)
    readonly property bool controllable: gpu.controllable && !backend.busy
    readonly property string disabledReason: backend.busy ? backend.busyLabel
        : !gpu.available ? "Install the GPU governor with bc250-power.sh governor."
        : !snapshot.toolkit.privileged ? "The system service is not privileged."
        : !gpu.dbusReady ? "Start the GPU governor; its D-Bus interface is unavailable."
        : "GPU controls are unavailable."
    spacing: Kirigami.Units.largeSpacing

    function syncFromSnapshot() {
        mode = gpu.mode;
        minimum = gpu.minimum || 0;
        maximum = gpu.maximum || gpu.configuredMax || 1500;
        loadMinimum = Math.round((gpu.loadLower === null ? 0.65 : gpu.loadLower) * 100);
        loadMaximum = Math.round((gpu.loadUpper === null ? 0.80 : gpu.loadUpper) * 100);
        temperatureTarget = gpu.temperatureTarget || 85;
        rampMs = gpu.climbMs || 500;
    }

    function visibleFsr4Games() {
        var games = root.fsr4.games || [];
        var query = root.fsr4Search.trim().toLowerCase();
        var visible = [];
        for (var index = 0; index < games.length && visible.length < 100; ++index) {
            var game = games[index];
            if (!query || String(game.name).toLowerCase().indexOf(query) >= 0
                    || String(game.appId).indexOf(query) >= 0)
                visible.push(game);
        }
        return visible;
    }

    onGpuChanged: if (!backend.busy) syncFromSnapshot()

    Components.ConfirmationDialog { id: confirmation }

    Components.Section {
        title: "Live GPU"
        Components.StatusRow { label: "Active clock"; value: gpu.activeMhz === null ? "Unavailable" : gpu.activeMhz + " MHz" }
        Components.StatusRow {
            label: "Governor service"
            value: gpu.governorService.enabled + " / " + gpu.governorService.active
            health: gpu.governorService.enabled === "enabled" && gpu.governorService.active === "active" ? 1 : -1
        }
        Components.StatusRow { label: "Live mode"; value: gpu.mode; health: gpu.dbusReady ? 1 : -1 }
        Components.StatusRow {
            label: "Saved replay"
            value: gpu.requestedMode === "range" ? gpu.requestedMinimum + "-" + gpu.requestedMaximum + " MHz"
                : gpu.requestedMode === "pin" ? gpu.requestedMaximum + " MHz pinned" : gpu.requestedMode
        }
        Components.StatusRow {
            label: "Live range"
            value: gpu.liveMinimum === null || gpu.liveMaximum === null ? "D-Bus unavailable"
                : gpu.liveMinimum + "-" + gpu.liveMaximum + " MHz"
            health: gpu.dbusReady ? 1 : -1
        }
        Components.StatusRow {
            label: "Boot replay"
            value: !gpu.persistent ? "Pending setup" : gpu.replayApplied ? "Applied" : "Enabled, not live"
            health: gpu.persistent && gpu.replayApplied ? 1 : -1
        }
        Components.StatusRow { label: "Adaptive ceiling"; value: gpu.configuredMax ? gpu.configuredMax + " MHz" : "Curve maximum" }
        Components.StatusRow { label: "Loaded ceiling"; value: gpu.initialMaximum ? gpu.initialMaximum + " MHz" : "Unavailable" }
    }

    Components.Section {
        title: "Mesa / RADV and Compute Queues"
        Components.StatusRow { label: "Patched AMDGPU"; value: root.mesh.kernelReady ? "Installed and active" : "Not ready"; health: root.mesh.kernelReady ? 1 : -1 }
        Components.StatusRow {
            label: "Scheduler policy"
            value: root.mesh.schedulerActive ? "Active" : root.mesh.schedulerConfigured ? "Reboot required" : "Disabled"
            health: root.mesh.schedulerActive ? 1 : root.mesh.schedulerConfigured ? 0 : -1
        }
        Components.StatusRow { label: "RADV runtime"; value: root.mesh.runtimeState || "Unavailable"; health: root.mesh.runtimeState === "ready" ? 1 : -1 }
        Components.StatusRow { label: "Global activation"; value: root.mesh.globalEnabled ? "Enabled" : "Disabled"; health: root.mesh.globalEnabled ? 1 : 0 }
        Components.StatusRow { label: "FSR4 RC8 game DLLs"; value: (root.mesh.fsr4DllState || "Unavailable") + " (" + (root.mesh.fsr4DllInstallCount || 0) + ")"; health: root.mesh.fsr4DllState === "ready" ? 1 : root.mesh.fsr4DllState === "invalid" ? -1 : 0 }
        Components.StatusRow { label: "Legacy FSR4 V3 profile"; value: root.mesh.fsr4State || "Unavailable"; health: root.mesh.fsr4State === "ready" ? 1 : root.mesh.fsr4State === "invalid" ? -1 : 0 }
        Components.StatusRow { label: "Legacy FSR4 runner"; value: root.mesh.fsr4RunnerPath || "Unavailable" }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: Boolean(root.mesh.error) || root.mesh.runtimeState === "invalid" || root.mesh.fsr4State === "invalid" || root.mesh.fsr4DllState === "invalid"
            type: Kirigami.MessageType.Warning
            text: root.mesh.error || "A Mesa / RADV runtime failed integrity validation. Repair it from the toolkit."
        }
    }

    Components.Section {
        title: "FSR4 RC8 Game Manager"
        QQC2.TextField {
            Layout.fillWidth: true
            placeholderText: "Search installed Steam games or app ID"
            text: root.fsr4Search
            onTextEdited: root.fsr4Search = text
        }
        QQC2.Label {
            Layout.fillWidth: true
            text: !root.backend.fsr4Inventory ? "Loading Steam game inventory"
                : (root.fsr4.games ? root.fsr4.games.length : 0) + " installed games | "
                    + (root.fsr4.currentRelease || "helper unavailable")
            color: Kirigami.Theme.disabledTextColor
        }
        Components.ActionButton {
            text: "Refresh game list"
            enabled: !root.backend.busy
            disabledReason: root.backend.busy ? root.backend.busyLabel : ""
            onClicked: root.backend.refreshFsr4()
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: root.backend.fsr4Inventory && !root.fsr4.available
            type: Kirigami.MessageType.Warning
            text: root.fsr4.currentRelease
                ? "Steam library metadata is unavailable. Start Steam once, then refresh the game list."
                : root.fsr4.errors && root.fsr4.errors.length > 0
                    ? root.fsr4.errors[0] : "The FSR4 helper is unavailable."
        }
        Repeater {
            model: root.visibleFsr4Games()
            ColumnLayout {
                id: gameDelegate
                required property var modelData
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                QQC2.Label {
                    Layout.fillWidth: true
                    text: gameDelegate.modelData.name
                    font.bold: true
                    wrapMode: Text.Wrap
                }
                QQC2.Label {
                    visible: !gameDelegate.modelData.targets || gameDelegate.modelData.targets.length === 0
                    Layout.fillWidth: true
                    text: gameDelegate.modelData.installPresent
                        ? (gameDelegate.modelData.scanState === "truncated" || gameDelegate.modelData.scanState === "partial"
                            ? "Scan incomplete" : "Compatible DLL not detected")
                        : "Install unavailable"
                    color: Kirigami.Theme.disabledTextColor
                    wrapMode: Text.Wrap
                }
                Repeater {
                    model: gameDelegate.modelData.targets || []
                    ColumnLayout {
                        id: targetDelegate
                        required property var modelData
                        Layout.fillWidth: true
                        readonly property bool gameReady: gameDelegate.modelData.fullyInstalled && gameDelegate.modelData.installPresent
                        readonly property bool managed: modelData.state === "ready" || modelData.state === "upgrade-required"
                        readonly property bool integrityBlocked: modelData.state === "modified" || modelData.state === "invalid"
                        readonly property bool undiscoverableInstall: modelData.state === "restored" && !modelData.discovered
                        QQC2.Switch {
                            id: targetSwitch
                            Layout.fillWidth: true
                            text: "FSR4 RC8"
                            checked: targetDelegate.managed
                            enabled: !root.backend.busy && targetDelegate.gameReady
                                && !targetDelegate.integrityBlocked && targetDelegate.modelData.state !== "missing"
                                && !targetDelegate.undiscoverableInstall
                            onClicked: {
                                var nextEnabled = checked;
                                var targetId = String(targetDelegate.modelData.targetId);
                                checked = Qt.binding(function() { return targetDelegate.managed; });
                                confirmation.ask(nextEnabled ? "Install FSR4 RC8 for this game?" : "Restore the original game DLL?",
                                    "Close the game first. The toolkit validates the target again and preserves exact rollback bytes.",
                                    true, function() { root.backend.setFsr4Dll(targetId, nextEnabled); });
                            }
                        }
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: (targetDelegate.modelData.relativePath || targetDelegate.modelData.targetPath || "Unknown target")
                                + " | " + targetDelegate.modelData.state
                                + (targetDelegate.modelData.release ? " | " + targetDelegate.modelData.release : "")
                                + (targetDelegate.gameReady ? "" : " | Steam install/update incomplete")
                                + (targetDelegate.undiscoverableInstall ? " | target not found during scan" : "")
                            color: targetDelegate.integrityBlocked ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
                            wrapMode: Text.WrapAnywhere
                        }
                        Components.ActionButton {
                            visible: targetDelegate.modelData.state === "upgrade-required"
                            text: "Update this target"
                            enabled: !root.backend.busy && targetDelegate.gameReady && targetDelegate.modelData.discovered
                            disabledReason: root.backend.busy ? root.backend.busyLabel
                                : !targetDelegate.gameReady ? "Finish the Steam install or update first."
                                : !targetDelegate.modelData.discovered ? "The target was not found during the latest scan." : ""
                            onClicked: {
                                var targetId = String(targetDelegate.modelData.targetId);
                                confirmation.ask("Update FSR4 RC8 for this game?",
                                    "Close the game first. The previous managed DLL will be restored before the new pinned release is installed.",
                                    true, function() { root.backend.setFsr4Dll(targetId, true); });
                            }
                        }
                        Components.ActionButton {
                            visible: targetDelegate.modelData.state === "missing"
                            text: "Restore missing original DLL"
                            enabled: !root.backend.busy && targetDelegate.gameReady
                            disabledReason: root.backend.busy ? root.backend.busyLabel
                                : !targetDelegate.gameReady ? "Finish the Steam install or update first." : ""
                            onClicked: {
                                var targetId = String(targetDelegate.modelData.targetId);
                                confirmation.ask("Restore the missing original DLL?",
                                    "Close the game first. The toolkit will recreate the target from its exact rollback copy.",
                                    true, function() { root.backend.setFsr4Dll(targetId, false); });
                            }
                        }
                    }
                }
            }
        }
        QQC2.Label {
            visible: root.fsr4.games && root.fsr4.games.length > 100 && !root.fsr4Search.trim()
            Layout.fillWidth: true
            text: "Showing the first 100 games. Search by game name or Steam app ID."
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.Wrap
        }
        QQC2.Label {
            visible: root.fsr4.games && root.fsr4.games.length > 0 && root.visibleFsr4Games().length === 0
            Layout.fillWidth: true
            text: "No installed Steam games match this search."
            color: Kirigami.Theme.disabledTextColor
        }
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: root.fsr4.errors && root.fsr4.errors.length > 0
            type: Kirigami.MessageType.Warning
            text: visible ? root.fsr4.errors.join(" ") : ""
        }
        Repeater {
            model: root.fsr4.orphanedTargets || []
            ColumnLayout {
                id: orphanDelegate
                required property var modelData
                Layout.fillWidth: true
                readonly property bool integrityBlocked: modelData.state === "modified" || modelData.state === "invalid"
                QQC2.Label {
                    Layout.fillWidth: true
                    text: "Unassociated FSR4 rollback | " + (orphanDelegate.modelData.targetPath || "Invalid rollback record")
                        + " | " + orphanDelegate.modelData.state
                    color: orphanDelegate.integrityBlocked ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
                    wrapMode: Text.WrapAnywhere
                }
                Components.ActionButton {
                    text: "Restore original DLL"
                    enabled: !root.backend.busy && !orphanDelegate.integrityBlocked
                    disabledReason: root.backend.busy ? root.backend.busyLabel
                        : orphanDelegate.integrityBlocked ? "Resolve the rollback integrity warning manually." : ""
                    onClicked: {
                        var targetId = String(orphanDelegate.modelData.targetId);
                        confirmation.ask("Restore the original game DLL?",
                            "Close the game first. The toolkit will validate this recorded target and restore its exact original bytes.",
                            true, function() { root.backend.setFsr4Dll(targetId, false); });
                    }
                }
            }
        }
    }

    Components.Section {
        title: "Frequency"
        QQC2.ComboBox {
            id: modeBox
            Layout.fillWidth: true
            model: ["Adaptive", "Custom range / overclock", "Pinned frequency", "Maximum curve point"]
            currentIndex: ["adaptive", "range", "pin", "max"].indexOf(root.mode)
            enabled: root.controllable
            onActivated: root.mode = ["adaptive", "range", "pin", "max"][currentIndex]
        }
        QQC2.Label { text: "Minimum clock"; visible: root.mode === "adaptive" || root.mode === "range" }
        QQC2.SpinBox {
            from: 0; to: Math.min(root.gpu.allowedMaximum || 2230, 2230); stepSize: 50
            value: root.minimum; editable: true; enabled: root.controllable
            visible: root.mode === "adaptive" || root.mode === "range"
            Layout.fillWidth: true
            textFromValue: (value) => value + " MHz"
            valueFromText: (text) => parseInt(text)
            onValueModified: { root.minimum = value; root.mode = "range"; }
        }
        QQC2.Label { text: root.mode === "pin" ? "Pinned clock" : "Maximum clock"; visible: root.mode !== "max" }
        QQC2.SpinBox {
            from: root.frequencyMinimum; to: Math.min(root.gpu.allowedMaximum || 2230, 2230); stepSize: 50
            value: root.maximum; editable: true; enabled: root.controllable
            visible: root.mode !== "max"; Layout.fillWidth: true
            textFromValue: (value) => value + " MHz"
            valueFromText: (text) => parseInt(text)
            onValueModified: { root.maximum = value; if (root.mode === "adaptive") root.mode = "range"; }
        }
        Components.ActionButton {
            text: "Apply frequency mode"
            enabled: root.controllable && root.frequencyValid
            disabledReason: !root.frequencyValid
                ? "Minimum clock must be 0 (no floor) or at least " + root.frequencyMinimum + " MHz, and not exceed maximum."
                : root.disabledReason
            onClicked: {
                var apply = function() { root.backend.setGpuFrequency(root.mode, root.minimum, root.maximum); };
                if (root.mode === "pin" || root.mode === "max")
                    confirmation.ask("Apply sustained GPU clocks?",
                        "Pinned or maximum clocks increase heat and power. Thermal throttling remains active.", false, apply);
                else
                    apply();
            }
        }
    }

    Components.Section {
        title: "Load Response"
        Components.StatusRow {
            label: "Current target"
            value: gpu.loadUpper === null || gpu.loadLower === null ? "Unavailable"
                : Math.round(gpu.loadUpper * 100) + " / " + Math.round(gpu.loadLower * 100) + "%"
        }
        RowLayout {
            Layout.fillWidth: true
            Components.ActionButton {
                text: "Eager preset"; description: "40/10%"; enabled: root.controllable
                disabledReason: root.disabledReason; Layout.fillWidth: true
                onClicked: root.backend.setLoadTarget("eager")
            }
            Components.ActionButton {
                text: "Balanced preset"; description: "80/65%"; enabled: root.controllable
                disabledReason: root.disabledReason; Layout.fillWidth: true
                onClicked: root.backend.setLoadTarget("reset")
            }
        }
        QQC2.Label { text: "Clock down below " + root.loadMinimum + "% load" }
        QQC2.Slider {
            from: 1; to: 99; stepSize: 1; value: root.loadMinimum; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.loadMinimum = Math.round(value)
        }
        QQC2.Label { text: "Clock up above " + root.loadMaximum + "% load" }
        QQC2.Slider {
            from: 1; to: 99; stepSize: 1; value: root.loadMaximum; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.loadMaximum = Math.round(value)
        }
        Components.ActionButton {
            text: "Apply custom load target"
            enabled: root.controllable && root.loadMinimum < root.loadMaximum
            disabledReason: root.loadMinimum >= root.loadMaximum
                ? "Minimum load must be lower than maximum load." : root.disabledReason
            onClicked: root.backend.setCustomLoadTarget(root.loadMinimum, root.loadMaximum)
        }
    }

    Components.Section {
        title: "Thermal Target"
        QQC2.Label { text: "Throttle at " + root.temperatureTarget + " C; recover below " + (root.temperatureTarget - 10) + " C" }
        QQC2.Slider {
            from: 50; to: 100; stepSize: 1; value: root.temperatureTarget; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.temperatureTarget = Math.round(value)
        }
        Components.ActionButton {
            text: "Apply thermal target"; enabled: root.controllable; disabledReason: root.disabledReason
            onClicked: root.backend.setTemperatureTarget(root.temperatureTarget)
        }
    }

    Components.Section {
        title: "Ramp"
        QQC2.Label { text: "Idle-to-max climb: " + root.rampMs + " ms" }
        QQC2.Slider {
            from: 200; to: 5000; stepSize: 100; value: root.rampMs; enabled: root.controllable
            Layout.fillWidth: true; onMoved: root.rampMs = Math.round(value / 100) * 100
        }
        Components.ActionButton {
            text: "Apply ramp time"; enabled: root.controllable; disabledReason: root.disabledReason
            onClicked: root.backend.setRamp(root.rampMs)
        }
    }

    Components.Section {
        title: "Voltage Curve"
        visible: root.gpu.safePoints.length > 0
        Repeater {
            model: root.gpu.safePoints
            Components.StatusRow {
                required property var modelData
                required property int index
                label: modelData.frequency ? modelData.frequency + " MHz" : "Point " + (index + 1)
                value: modelData.voltage ? modelData.voltage + " mV" : "Unavailable"
            }
        }
    }
}
