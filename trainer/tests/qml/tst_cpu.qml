import QtQuick 2.15
import QtTest 1.3
import "../../qml/pages" as Pages

TestCase {
    id: testCase
    name: "CpuUnlockModes"
    when: windowShown
    width: 820
    height: 1000

    function status(actions, mode, efiOverride) {
        var linuxEnabled = mode === "linux-replay" || mode === "conflict"
        var efiState = efiOverride || {
            "installed": mode === "efi" || mode === "conflict",
            "partial": mode === "partial",
            "masterInstalled": mode === "efi" || mode === "conflict" || mode === "partial",
            "imageInstalled": mode === "efi" || mode === "conflict",
            "espImageInstalled": mode === "efi" || mode === "conflict",
            "imagesMatch": mode === "efi" || mode === "conflict",
            "bootnumStateInstalled": mode === "efi" || mode === "conflict",
            "bootEntryConfigured": mode === "efi" || mode === "conflict",
            "bootEntry": {
                "present": mode === "efi" || mode === "conflict",
                "active": mode === "efi" || mode === "conflict",
                "matching": mode === "efi" || mode === "conflict",
                "firstInBootOrder": mode === "efi" || mode === "conflict",
                "effective": mode === "efi" || mode === "conflict",
                "queryAvailable": true
            },
            "imageHashPresent": false,
            "imageHashStateInstalled": false,
            "imageHashValid": null
        }
        return {
            "schemaVersion": 1,
            "mode": mode || "none",
            "physicalCores": mode === "none" ? 6 : 8,
            "logicalThreads": mode === "none" ? 12 : 16,
            "topologyState": mode === "none" ? "locked" : "unlocked",
            "helperInstalled": true,
            "unitInstalled": false,
            "ccxGroups": [],
            "guard": {"state": "clear"},
            "service": {"enabled": linuxEnabled ? "enabled" : "disabled", "active": linuxEnabled ? "active" : "inactive"},
            "linuxReplay": {
                "installed": true,
                "enabled": linuxEnabled,
                "service": {"enabled": linuxEnabled ? "enabled" : "disabled", "active": linuxEnabled ? "active" : "inactive"},
                "updatePersistence": true
            },
            "efi": efiState,
            "actions": actions
        }
    }

    QtObject {
        id: backend
        property bool busy: false
        property var snapshot: ({"toolkit": {"cpuControlAvailable": true}, "cpu": {}})
        property var cpuUnlockStatus: testCase.status({}, "none")
        property string lastUnlockAction: ""
        function cpuUnlockAction(action) { lastUnlockAction = action }
        function cpuOcAction(action, frequency, voltage, temperature) {}
    }

    Pages.CpuPage {
        id: page
        width: 780
        backend: backend
    }

    function init() {
        backend.busy = false
        backend.lastUnlockAction = ""
        backend.cpuUnlockStatus = status({
            "test": {"available": true, "blockers": []},
            "enable": {"available": true, "blockers": []},
            "efi-enable": {"available": true, "blockers": []},
            "off": {"available": false, "blockers": ["persistent-replay-disabled"]}
        }, "temporary")
    }

    function test_actionAvailabilityComesFromService() {
        var testButton = findChild(page, "cpuUnlockTestButton")
        var linuxButton = findChild(page, "linuxReplayEnableButton")
        var efiButton = findChild(page, "efiEnableButton")
        var offButton = findChild(page, "cpuUnlockOffButton")
        verify(testButton !== null)
        verify(linuxButton !== null)
        verify(efiButton !== null)
        verify(offButton !== null)
        compare(testButton.enabled, true)
        compare(linuxButton.enabled, true)
        compare(efiButton.enabled, true)
        compare(offButton.enabled, false)

        backend.cpuUnlockStatus = status({
            "test": {"available": false, "blockers": ["persistent-replay-enabled"]},
            "enable": {"available": false, "blockers": ["persistent-replay-enabled"]},
            "efi-enable": {"available": false, "blockers": ["persistent-replay-enabled"]},
            "off": {"available": true, "blockers": []}
        }, "linux-replay")
        tryCompare(testButton, "enabled", false)
        compare(linuxButton.enabled, false)
        compare(efiButton.enabled, false)
        compare(offButton.enabled, true)
        compare(page.unlockMode, "linux-replay")
    }

    function test_modeLabelsAndRecoveryStates() {
        var modeTile = findChild(page, "cpuUnlockModeTile")
        var warning = findChild(page, "cpuUnlockModeWarning")
        var offButton = findChild(page, "cpuUnlockOffButton")
        verify(modeTile !== null)
        verify(warning !== null)
        verify(offButton !== null)

        var cases = [
            {"mode": "none", "label": "NONE"},
            {"mode": "temporary", "label": "ONE-TIME TEST"},
            {"mode": "linux-replay", "label": "LINUX REPLAY"},
            {"mode": "efi", "label": "EFI PREBOOT"}
        ]
        for (var index = 0; index < cases.length; ++index) {
            backend.cpuUnlockStatus = status({}, cases[index].mode)
            compare(modeTile.value, cases[index].label)
            compare(page.recoveryWarningVisible, false)
        }

        var blockedActions = {
            "test": {"available": false, "blockers": ["efi-installation-partial"]},
            "enable": {"available": false, "blockers": ["efi-installation-partial"]},
            "efi-enable": {"available": false, "blockers": ["efi-installation-partial"]},
            "off": {"available": true, "blockers": []}
        }
        backend.cpuUnlockStatus = status(blockedActions, "partial")
        compare(modeTile.value, "PARTIAL")
        compare(page.recoveryWarningVisible, true)
        verify(warning.text.indexOf("PARTIAL INSTALL") >= 0)
        compare(offButton.text, "ATTEMPT PARTIAL CLEANUP")
        compare(offButton.enabled, true)

        var conflictActions = {
            "test": {"available": false, "blockers": ["persistent-replay-enabled", "efi-unlock-enabled"]},
            "enable": {"available": false, "blockers": ["persistent-replay-enabled", "efi-unlock-enabled"]},
            "efi-enable": {"available": false, "blockers": ["persistent-replay-enabled"]},
            "off": {"available": true, "blockers": []}
        }
        backend.cpuUnlockStatus = status(conflictActions, "conflict")
        compare(modeTile.value, "CONFLICT")
        compare(page.recoveryWarningVisible, true)
        verify(warning.text.indexOf("CONFLICT") >= 0)
        compare(offButton.text, "RECOVER CONFLICTING MODES")
    }

    function test_bootEntryRuntimeSafetyStates() {
        var entryStatus = findChild(page, "efiBootEntryStatus")
        var partialStatus = findChild(page, "efiInstallStatus")
        verify(entryStatus !== null)
        verify(partialStatus !== null)

        var effectiveEfi = {
            "installed": true,
            "partial": false,
            "bootEntryConfigured": true,
            "bootEntry": {"present": true, "active": true, "matching": true, "firstInBootOrder": true, "effective": true, "queryAvailable": true}
        }
        backend.cpuUnlockStatus = status({}, "efi", effectiveEfi)
        compare(entryStatus.value, "Effective")
        compare(entryStatus.health, 1)

        var ownershipOnlyEfi = {
            "installed": true,
            "partial": false,
            "bootEntryConfigured": true
        }
        backend.cpuUnlockStatus = status({}, "efi", ownershipOnlyEfi)
        compare(entryStatus.value, "Unavailable")
        compare(entryStatus.health, 0)

        var states = [
            {"entry": {"present": false, "active": false, "matching": false, "firstInBootOrder": false, "effective": false, "queryAvailable": true}, "label": "Missing", "health": -1},
            {"entry": {"present": true, "active": false, "matching": true, "firstInBootOrder": true, "effective": false, "queryAvailable": true}, "label": "Inactive", "health": -1},
            {"entry": {"present": true, "active": true, "matching": false, "firstInBootOrder": true, "effective": false, "queryAvailable": true}, "label": "Mismatched", "health": -1},
            {"entry": {"present": true, "active": true, "matching": true, "firstInBootOrder": false, "effective": false, "queryAvailable": true}, "label": "Reordered", "health": -1},
            {"entry": {"present": true, "active": true, "matching": true, "firstInBootOrder": true, "effective": false, "queryAvailable": true}, "label": "Unavailable", "health": -1},
            {"entry": {"present": null, "active": null, "matching": null, "firstInBootOrder": null, "effective": null, "queryAvailable": false}, "label": "Unavailable", "health": 0}
        ]
        for (var index = 0; index < states.length; ++index) {
            var degradedEfi = {
                "installed": true,
                "partial": false,
                "bootEntryConfigured": true,
                "bootEntry": states[index].entry
            }
            backend.cpuUnlockStatus = status({}, "efi", degradedEfi)
            compare(entryStatus.value, states[index].label)
            compare(entryStatus.health, states[index].health)
        }

        var partialEfi = {
            "installed": false,
            "partial": true,
            "bootEntryConfigured": false
        }
        backend.cpuUnlockStatus = status({}, "partial", partialEfi)
        compare(partialStatus.value, "Partial")
        compare(partialStatus.health, -1)
    }

    function test_oldSchemaFallbackDoesNotClaimEffectiveEfi() {
        var entryStatus = findChild(page, "efiBootEntryStatus")
        var modeTile = findChild(page, "cpuUnlockModeTile")
        verify(entryStatus !== null)
        verify(modeTile !== null)

        var oldStatus = {
            "schemaVersion": 1,
            "physicalCores": 8,
            "logicalThreads": 16,
            "topologyState": "unlocked",
            "helperInstalled": true,
            "unitInstalled": true,
            "service": {"enabled": "enabled", "active": "active"},
            "guard": {"state": "clear"},
            "actions": {}
        }
        backend.cpuUnlockStatus = oldStatus
        compare(page.unlockMode, "linux-replay")
        compare(modeTile.value, "LINUX REPLAY")
        compare(entryStatus.value, "Unavailable")
        compare(entryStatus.health, 0)
    }

    function test_staleAutomaticGuardStillAllowsRecoveryAction() {
        var offButton = findChild(page, "cpuUnlockOffButton")
        var recoveryStatus = status({
            "test": {"available": false, "blockers": ["automatic-reboot-pending"]},
            "enable": {"available": false, "blockers": ["automatic-reboot-pending"]},
            "efi-enable": {"available": false, "blockers": ["automatic-reboot-pending"]},
            "off": {"available": true, "blockers": []}
        }, "partial")
        recoveryStatus.guard = {"state": "automatic", "currentBoot": false}
        backend.cpuUnlockStatus = recoveryStatus

        compare(page.automaticRebootPending, false)
        compare(offButton.enabled, true)
    }

    function test_efiConfirmationEmitsBackendAction() {
        var efiButton = findChild(page, "efiEnableButton")
        var efiHelp = findChild(page, "efiActionHelp")
        var dialog = findChild(page, "cpuConfirmDialog")
        verify(efiButton !== null)
        verify(efiHelp !== null)
        verify(dialog !== null)
        verify(efiButton.hint.indexOf("runtime preflight") >= 0)
        verify(efiButton.hint.indexOf("NVRAM") >= 0)
        verify(efiHelp.text.indexOf("runtime preflight") >= 0)
        efiButton.clicked()
        verify(dialog.detail.indexOf("ESP") >= 0)
        verify(dialog.detail.indexOf("Secure Boot") >= 0)
        verify(dialog.detail.indexOf("disabling or removing") >= 0)
        dialog.accept()
        compare(backend.lastUnlockAction, "efi-enable")
    }
}
