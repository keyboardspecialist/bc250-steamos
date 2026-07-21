import QtQuick
import QtQuick.Controls as QQC2
import ".."

QQC2.ApplicationWindow {
    width: 940
    height: 720
    visible: true
    title: "BC-250 Control Mock"

    MockBackend { id: mockBackend }
    ControlView {
        anchors.fill: parent
        backend: mockBackend
        active: true
    }
}
