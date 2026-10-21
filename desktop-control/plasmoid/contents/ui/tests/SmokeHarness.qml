import QtQuick
import QtQuick.Controls as QQC2
import ".."

// Offscreen, mock-only construction of every tab. Never instantiates Backend.
QQC2.ApplicationWindow {
    width: 940
    height: 720
    visible: true
    MockBackend { id: mockBackend }
    ControlView { id: controls; anchors.fill: parent; backend: mockBackend; active: true }
    Timer {
        interval: 250
        repeat: true
        running: true
        property int step: 0
        onTriggered: {
            step += 1;
            if (step < 8) controls.currentTab = step;
            else if (step === 8) { width = 420; controls.currentTab = 0; }
            else if (step < 16) controls.currentTab = step - 8;
            else if (step === 16) {
                // The terminal catalog remains accessible without a snapshot.
                mockBackend.snapshot = null;
                mockBackend.cliCatalog = { schemaVersion: 1, available: false,
                    reason: "No supported desktop terminal (mock)", sections: [] };
            } else Qt.quit();
        }
    }
}
