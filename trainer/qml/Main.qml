import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Dialogs 6.3
import "components" as C
import "pages" as Pages

ApplicationWindow {
    id: root
    title: "BC250 Trainer"
    visible: true
    flags: Qt.Window | Qt.FramelessWindowHint
    color: "black"
    property int fittedWidth: 1200
    property int fittedHeight: 676
    property int currentPage: 0
    readonly property real designRatio: 1200 / 676
    readonly property var pageNames: ["STATUS", "GPU", "CUs", "CPU", "MEMORY", "SETUP"]
    readonly property bool ambientEffectsActive: visibility !== Window.Hidden
        && visibility !== Window.Minimized
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
        var availableWidth = Screen.desktopAvailableWidth > 0 ? Screen.desktopAvailableWidth - 32 : 1200
        var availableHeight = Screen.desktopAvailableHeight > 0 ? Screen.desktopAvailableHeight - 32 : 676
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
    onVisibilityChanged: function(visibility) {
        bridge.visible = visibility !== Window.Hidden && visibility !== Window.Minimized
    }
    onCurrentPageChanged: bridge.statusPageActive = currentPage === 0

    Image {
        id: backgroundImage
        anchors.fill: parent
        source: "qrc:/assets/background.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

    HoverHandler {
        id: backgroundHover
        onHoveredChanged: if (hovered) backgroundDistortion.resetTrail()
    }

    Item {
        id: backgroundDistortion
        anchors.fill: parent
        enabled: false
        visible: opacity > 0
        opacity: backgroundHover.hovered ? 1 : 0
        property real phase: 0
        property var trailPoints: []
        readonly property real effectRadius: Math.max(44, Math.min(72, root.width * 0.06))
        readonly property real diameter: effectRadius * 2
        readonly property int gridSize: 7
        readonly property real cellSize: diameter / gridSize
        readonly property real pointerX: backgroundHover.point.position.x
        readonly property real pointerY: backgroundHover.point.position.y

        function currentPoint() {
            return Qt.point(pointerX, pointerY)
        }

        function resetTrail() {
            var point = currentPoint()
            trailPoints = [point, point]
        }

        function sampleTrail() {
            var point = currentPoint()
            trailPoints = [point,
                           trailPoints.length > 0 ? trailPoints[0] : point]
        }

        function pointForLayer(layer) {
            if (layer === 0)
                return currentPoint()
            return trailPoints.length >= layer ? trailPoints[layer - 1] : currentPoint()
        }

        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        Timer {
            interval: 50
            repeat: true
            running: backgroundDistortion.visible
            onTriggered: backgroundDistortion.phase = (backgroundDistortion.phase
                + Math.PI * 2 / 17) % (Math.PI * 2)
        }

        Timer {
            interval: 45
            repeat: true
            running: backgroundHover.hovered
            triggeredOnStart: true
            onTriggered: backgroundDistortion.sampleTrail()
        }

        Repeater {
            model: 3
            Item {
                id: trailLayer
                required property int index
                anchors.fill: parent
                readonly property point trailPoint: backgroundDistortion.pointForLayer(index)
                readonly property real strength: index === 0 ? 0.68
                    : index === 1 ? 0.22 : 0.12

                Repeater {
                    model: backgroundDistortion.gridSize * backgroundDistortion.gridSize
                    Item {
                        required property int index
                        readonly property int row: Math.floor(index / backgroundDistortion.gridSize)
                        readonly property int column: index % backgroundDistortion.gridSize
                        readonly property real localCenterX: (column + 0.5)
                            * backgroundDistortion.cellSize - backgroundDistortion.effectRadius
                        readonly property real localCenterY: (row + 0.5)
                            * backgroundDistortion.cellSize - backgroundDistortion.effectRadius
                        readonly property real normalizedDistance: Math.sqrt(
                            localCenterX * localCenterX + localCenterY * localCenterY)
                            / backgroundDistortion.effectRadius
                        readonly property real edgeFade: Math.pow(Math.max(0, Math.min(1,
                            (1 - normalizedDistance) / 0.42)), 2)
                        readonly property real glitchX: Math.sin(backgroundDistortion.phase * 2
                            + row * 1.7 + trailLayer.index * 0.8) * (1.5 + row % 3)
                        readonly property real glitchY: Math.cos(backgroundDistortion.phase
                            + column * 1.3 + trailLayer.index) * 1.2

                        x: trailLayer.trailPoint.x - backgroundDistortion.effectRadius
                            + column * backgroundDistortion.cellSize
                        y: trailLayer.trailPoint.y - backgroundDistortion.effectRadius
                            + row * backgroundDistortion.cellSize
                        width: backgroundDistortion.cellSize + 0.5
                        height: backgroundDistortion.cellSize + 0.5
                        visible: normalizedDistance < 1
                        opacity: trailLayer.strength * edgeFade
                        clip: true

                        Image {
                            x: -parent.x + parent.glitchX
                            y: -parent.y + parent.glitchY
                            width: backgroundDistortion.width
                            height: backgroundDistortion.height
                            source: backgroundImage.source
                            sourceSize: Qt.size(Math.max(1, Math.ceil(width / 10)),
                                                Math.max(1, Math.ceil(height / 10)))
                            fillMode: Image.PreserveAspectFit
                            smooth: false
                            cache: true
                        }
                    }
                }
            }
        }
    }

    Item {
        id: vhsTracking
        anchors.fill: parent
        enabled: false
        clip: true
        property int staticTick: 0

        Timer {
            interval: 72
            repeat: true
            running: root.ambientEffectsActive
            onTriggered: vhsTracking.staticTick = (vhsTracking.staticTick + 1) % 10000
        }

        Item {
            id: syncRoll
            x: 0
            y: -height
            width: parent.width
            height: Math.max(92, root.height * 0.19)
            clip: true
            readonly property int cycle: vhsTracking.staticTick

            Image {
                x: syncRoll.cycle % 3 === 0 ? -14 : 10
                y: -syncRoll.y - 18 + ((syncRoll.cycle * 7) % 27)
                width: root.width
                height: root.height
                source: backgroundImage.source
                fillMode: Image.PreserveAspectFit
                smooth: false
                cache: true
                opacity: 0.58
            }

            Repeater {
                model: 11
                Item {
                    required property int index
                    readonly property int cycle: syncRoll.cycle + index * 23
                    readonly property real tear: ((cycle * (13 + index * 4)) % 73) - 36
                    x: 0
                    y: index * syncRoll.height / 11
                    width: syncRoll.width
                    height: syncRoll.height / 11 + 1
                    clip: true

                    Image {
                        x: parent.tear
                        y: -syncRoll.y - parent.y + ((parent.cycle * 5) % 17) - 8
                        width: root.width
                        height: root.height
                        source: backgroundImage.source
                        fillMode: Image.PreserveAspectFit
                        smooth: false
                        cache: true
                        opacity: 0.72
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                opacity: 0.34
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#05050aee" }
                    GradientStop { position: 0.08; color: "#4022e7f2" }
                    GradientStop { position: 0.18; color: "#11030812" }
                    GradientStop { position: 0.72; color: "#24101824" }
                    GradientStop { position: 0.92; color: "#4aef48bb" }
                    GradientStop { position: 1.0; color: "#06050aee" }
                }
            }

            Repeater {
                model: 26
                Rectangle {
                    required property int index
                    readonly property int cycle: syncRoll.cycle + index * 31
                    x: ((cycle * (19 + index * 2)) % Math.max(1, syncRoll.width))
                        - width * 0.5
                    y: (index * 17 + cycle * (7 + index % 5))
                        % Math.max(1, syncRoll.height)
                    width: 30 + ((cycle * (37 + index)) % 210)
                    height: index % 5 === 0 ? 4 : index % 2 === 0 ? 2 : 1
                    color: index % 4 === 0 ? "#f4fdff"
                        : index % 4 === 1 ? "#ef48bb" : "#55edf7"
                    opacity: 0.14 + (index % 4) * 0.035
                    visible: cycle % 7 < 5
                }
            }

            Rectangle {
                x: 0
                y: 2
                width: parent.width
                height: 4
                color: "#b8f7ff"
                opacity: 0.48
            }

            Rectangle {
                x: syncRoll.cycle % 2 === 0 ? -18 : 12
                y: parent.height - 7
                width: parent.width
                height: 6
                color: "#ef48bb"
                opacity: 0.38
            }

            NumberAnimation on y {
                from: -syncRoll.height
                to: root.height + syncRoll.height
                duration: 7500
                loops: Animation.Infinite
                easing.type: Easing.Linear
                running: root.ambientEffectsActive
            }
        }

        Repeater {
            model: 18
            Rectangle {
                required property int index
                readonly property int cycle: vhsTracking.staticTick + index * 17
                readonly property real trackWidth: vhsTracking.width
                    * (0.34 + ((cycle * 17) % 61) / 100)
                x: (cycle * (29 + index * 7))
                    % Math.max(1, vhsTracking.width - trackWidth)
                y: (index * 89 + cycle * (13 + index * 3)) % Math.max(1, vhsTracking.height)
                width: trackWidth
                height: index % 5 === 0 ? 4 : index % 3 === 0 ? 2 : 1
                color: index % 3 === 0 ? "#b8f7ff"
                    : index % 3 === 1 ? "#ef48bb" : "#6ae8f2"
                opacity: 0.055 + (index % 4) * 0.028
                visible: cycle % 9 < 6
            }
        }

        Rectangle {
            readonly property int cycle: vhsTracking.staticTick
            x: cycle % 5 < 2 ? -18 : 12
            y: (cycle * 47) % Math.max(1, vhsTracking.height)
            width: parent.width
            height: cycle % 11 === 0 ? 12 : 4
            color: "#d8fbff"
            opacity: cycle % 7 < 3 ? 0.18 : 0
        }
    }

    MouseArea {
        id: moveArea
        x: 0; y: 0
        width: root.width * 0.47
        height: mediaPane.y
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

        C.NeonPanel { anchors.fill: parent; accent: bridge.error || mediaController.error ? "#ff4d8d" : "#22e7f2" }

        RowLayout {
            id: titleBar
            x: 14; y: 8; width: parent.width - 28; height: 36
            spacing: 6
            ColumnLayout {
                spacing: -2; Layout.fillWidth: true
                Text { text: "BC-250 // UNLOCKED SILICON"; color: "#22e7f2"; font.family: "monospace"; font.pixelSize: 14; font.bold: true; font.letterSpacing: 1 }
                Text { text: bridge.mockMode ? "ISOLATED MOCK LINK" : bridge.serviceAvailable ? "SYSTEM BUS LINKED" : "SYSTEM BUS OFFLINE"; color: bridge.serviceAvailable ? "#49ff9a" : "#ff4d8d"; font.family: "monospace"; font.pixelSize: 8 }
            }
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
                    text: (index < 5 ? "F" + (index + 1) + " " : "") + modelData
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
            color: bridge.error || mediaController.error ? "#481126dd" : bridge.notice ? "#102f32dd" : "#0c131bdd"
            border.color: bridge.error || mediaController.error ? "#ff4d8d" : bridge.busy ? "#ef48bb" : "#244f5a"
            clip: true
            Text {
                anchors.fill: parent; anchors.margins: 6
                text: bridge.busy ? "WORKING: " + bridge.busyLabel : bridge.error ? "ERROR: " + bridge.error : mediaController.error ? "AUDIO: " + mediaController.error : bridge.notice ? bridge.notice : "READY // read-only polling active"
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
                    : root.currentPage === 3 ? cpuComponent
                    : root.currentPage === 4 ? ramComponent : setupComponent
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

    C.MediaPane {
        id: mediaPane
        z: 2
        controller: mediaController
        width: Math.min(root.width * 0.47, 440)
        onDirectorySelectionRequested: folderDialog.open()
    }

    FolderDialog {
        id: folderDialog
        title: "Select a music folder"
        onAccepted: mediaController.setDirectory(selectedFolder)
    }

    Shortcut { sequence: "F1"; onActivated: root.currentPage = 0 }
    Shortcut { sequence: "F2"; onActivated: root.currentPage = 1 }
    Shortcut { sequence: "F3"; onActivated: root.currentPage = 2 }
    Shortcut { sequence: "F4"; onActivated: root.currentPage = 3 }
    Shortcut { sequence: "F5"; onActivated: root.currentPage = 4 }
    Shortcut { sequence: "M"; onActivated: mediaController.muted = !mediaController.muted }
    Shortcut { sequence: "P"; onActivated: mediaController.togglePlayback() }
    Shortcut { sequence: "R"; onActivated: if (!bridge.busy) bridge.refresh() }
    Shortcut { sequence: "Escape"; onActivated: root.close() }

    Component { id: statusComponent; Pages.StatusPage { backend: bridge } }
    Component { id: gpuComponent; Pages.GpuPage { backend: bridge } }
    Component { id: cuComponent; Pages.CuPage { backend: bridge } }
    Component { id: cpuComponent; Pages.CpuPage { backend: bridge } }
    Component { id: ramComponent; Pages.RamPage { backend: bridge } }
    Component { id: setupComponent; Pages.SetupPage { backend: bridge } }
}
