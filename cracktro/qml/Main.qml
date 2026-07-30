import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtMultimedia 6.4
import "components" as C
import "pages" as Pages

ApplicationWindow {
    id: root
    title: "BC-250 Cracktro"
    visible: true
    flags: Qt.Window | Qt.FramelessWindowHint
    color: "black"
    property int fittedWidth: 1200
    property int fittedHeight: 676
    property int currentPage: 0
    readonly property real designRatio: 1200 / 676
    readonly property var pageNames: ["STATUS", "GPU", "COMPUTE UNITS", "CPU", "SETUP"]
    width: fittedWidth
    height: fittedHeight
    minimumWidth: fittedWidth
    maximumWidth: fittedWidth
    minimumHeight: fittedHeight
    maximumHeight: fittedHeight
    palette.window: "#090c13"
    palette.windowText: "#d7e7ee"
    palette.text: "#d7e7ee"
    palette.button: "#131925"
    palette.buttonText: "#d7e7ee"
    palette.highlight: "#22e7f2"

    function fitToScreen() {
        var availableWidth = Screen.availableWidth > 0 ? Screen.availableWidth - 32 : 1200
        var availableHeight = Screen.availableHeight > 0 ? Screen.availableHeight - 32 : 676
        var nextWidth = Math.min(1200, availableWidth)
        var nextHeight = Math.round(nextWidth / designRatio)
        if (nextHeight > availableHeight) {
            nextHeight = availableHeight
            nextWidth = Math.round(nextHeight * designRatio)
        }
        fittedWidth = Math.max(1, nextWidth)
        fittedHeight = Math.round(fittedWidth / designRatio)
    }

    Component.onCompleted: fitToScreen()
    onVisibilityChanged: bridge.visible = visibility !== Window.Hidden && visibility !== Window.Minimized
    onCurrentPageChanged: bridge.statusPageActive = currentPage === 0

    Image {
        anchors.fill: parent
        source: "qrc:/assets/background.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

    MouseArea {
        id: moveArea
        x: 0; y: 0
        width: root.width * 0.47
        height: root.height
        acceptedButtons: Qt.LeftButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: root.startSystemMove()
        Accessible.name: "Drag window"
    }

    Repeater {
        model: Math.ceil(root.height / 5)
        Rectangle {
            required property int index
            x: 0; y: index * 5; width: root.width; height: 1
            color: "#061018"; opacity: 0.16
        }
    }

    Item {
        id: controlDeck
        x: root.width * 0.475
        y: 14
        width: root.width * 0.51
        height: root.height - 42

        C.NeonPanel { anchors.fill: parent; accent: bridge.error ? "#ff4d8d" : "#22e7f2" }

        RowLayout {
            id: titleBar
            x: 14; y: 8; width: parent.width - 28; height: 36
            spacing: 6
            ColumnLayout {
                spacing: -2; Layout.fillWidth: true
                Text { text: "BC-250 // UNLOCKED SILICON"; color: "#22e7f2"; font.family: "monospace"; font.pixelSize: 14; font.bold: true; font.letterSpacing: 1 }
                Text { text: bridge.mockMode ? "ISOLATED MOCK LINK" : bridge.serviceAvailable ? "SYSTEM BUS LINKED" : "SYSTEM BUS OFFLINE"; color: bridge.serviceAvailable ? "#49ff9a" : "#ff4d8d"; font.family: "monospace"; font.pixelSize: 8 }
            }
            C.NeonButton { text: bridge.muted ? "SND OFF" : "SND ON"; implicitWidth: 66; onClicked: bridge.muted = !bridge.muted; hint: "Mute soundtrack [M]" }
            C.NeonButton { text: "_"; implicitWidth: 32; onClicked: root.showMinimized(); hint: "Minimize" }
            C.NeonButton { text: "X"; implicitWidth: 32; accent: "#ef48bb"; onClicked: root.close(); hint: "Close [Esc]" }
        }

        RowLayout {
            id: navigation
            x: 14; y: 50; width: parent.width - 28; height: 31
            spacing: 4
            Repeater {
                model: root.pageNames
                C.NeonButton {
                    required property string modelData
                    required property int index
                    text: (index < 4 ? "F" + (index + 1) + " " : "") + modelData
                    accent: root.currentPage === index ? "#ef48bb" : "#22e7f2"
                    checked: root.currentPage === index
                    Layout.fillWidth: true
                    onClicked: root.currentPage = index
                }
            }
        }

        Rectangle {
            id: messageBar
            x: 14; y: 87; width: parent.width - 28; height: 27
            color: bridge.error ? "#481126dd" : bridge.notice ? "#102f32dd" : "#0c131bdd"
            border.color: bridge.error ? "#ff4d8d" : bridge.busy ? "#ef48bb" : "#244f5a"
            clip: true
            Text {
                anchors.fill: parent; anchors.margins: 6
                text: bridge.busy ? "WORKING: " + bridge.busyLabel : bridge.error ? "ERROR: " + bridge.error : bridge.notice ? bridge.notice : "READY // read-only polling active"
                textFormat: Text.PlainText
                color: bridge.error ? "#ff8ab4" : bridge.busy ? "#ef80ce" : "#9cdbe0"
                font.family: "monospace"; font.pixelSize: 9
                elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter
            }
        }

        BusyIndicator { anchors.centerIn: pageArea; running: bridge.loading && !Object.keys(bridge.snapshot).length; visible: running }
        ScrollView {
            id: pageArea
            x: 14; y: 120; width: parent.width - 28; height: parent.height - 184
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            Loader {
                width: pageArea.availableWidth
                sourceComponent: root.currentPage === 0 ? statusComponent
                    : root.currentPage === 1 ? gpuComponent
                    : root.currentPage === 2 ? cuComponent
                    : root.currentPage === 3 ? cpuComponent : setupComponent
            }
        }

        Rectangle {
            x: 14; y: parent.height - 58; width: parent.width - 28; height: 17
            color: "#05080cc0"; border.color: "#ef48bb"; clip: true
            Text {
                id: ticker
                y: 2
                text: "  WARNING // HARVESTED SILICON MAY BE DEFECTIVE // SAVE WORK BEFORE LIVE CHANGES // PRIVILEGED CHECKS REMAIN AUTHORITATIVE  "
                color: "#ef70cc"; font.family: "monospace"; font.pixelSize: 8; font.bold: true
                NumberAnimation on x { from: controlDeck.width; to: -ticker.implicitWidth; duration: 15000; loops: Animation.Infinite }
            }
        }

        RowLayout {
            x: 14; y: parent.height - 35; width: parent.width - 28; height: 28
            Text { text: "v" + applicationVersion; color: "#607783"; font.family: "monospace"; font.pixelSize: 8 }
            Item { Layout.fillWidth: true }
            C.NeonButton { visible: bridge.busy && bridge.operationId.length > 0; enabled: bridge.operationCancellable; text: bridge.operationCancellable ? "CANCEL OP" : "NON-CANCELLABLE"; accent: "#ff6aa2"; onClicked: bridge.cancelOperation() }
            C.NeonButton { text: "REFRESH [R]"; enabled: !bridge.busy; onClicked: bridge.refresh() }
        }
    }

    MediaPlayer {
        id: soundtrack
        source: "qrc:/assets/soundtrack.oga"
        loops: MediaPlayer.Infinite
        audioOutput: AudioOutput { volume: bridge.muted ? 0 : bridge.volume }
        onErrorOccurred: function(error, errorString) { bridge.reportAudioError(errorString) }
        Component.onCompleted: play()
    }

    Shortcut { sequence: "F1"; onActivated: root.currentPage = 0 }
    Shortcut { sequence: "F2"; onActivated: root.currentPage = 1 }
    Shortcut { sequence: "F3"; onActivated: root.currentPage = 2 }
    Shortcut { sequence: "F4"; onActivated: root.currentPage = 3 }
    Shortcut { sequence: "M"; onActivated: bridge.muted = !bridge.muted }
    Shortcut { sequence: "R"; onActivated: if (!bridge.busy) bridge.refresh() }
    Shortcut { sequence: "Escape"; onActivated: root.close() }

    Component { id: statusComponent; Pages.StatusPage { backend: bridge } }
    Component { id: gpuComponent; Pages.GpuPage { backend: bridge } }
    Component { id: cuComponent; Pages.CuPage { backend: bridge } }
    Component { id: cpuComponent; Pages.CpuPage { backend: bridge } }
    Component { id: setupComponent; Pages.SetupPage { backend: bridge } }
}
