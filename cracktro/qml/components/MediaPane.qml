import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root

    required property var controller
    property bool expanded: false
    readonly property int collapsedHeight: 228
    readonly property int expandedHeight: 462

    signal directorySelectionRequested()

    function formatTime(milliseconds) {
        var totalSeconds = Math.max(0, Math.floor(Number(milliseconds) / 1000))
        if (!isFinite(totalSeconds))
            totalSeconds = 0
        var seconds = totalSeconds % 60
        var minutes = Math.floor(totalSeconds / 60) % 60
        var hours = Math.floor(totalSeconds / 3600)
        var paddedSeconds = seconds < 10 ? "0" + seconds : String(seconds)
        if (hours > 0) {
            var paddedMinutes = minutes < 10 ? "0" + minutes : String(minutes)
            return hours + ":" + paddedMinutes + ":" + paddedSeconds
        }
        return minutes + ":" + paddedSeconds
    }

    anchors.left: parent.left
    anchors.bottom: parent.bottom
    width: Math.min(440, parent.width)
    height: expanded ? expandedHeight : collapsedHeight
    color: Qt.rgba(7 / 255, 16 / 255, 24 / 255, 0.91)
    border.color: expanded ? "#ef48bb" : "#22e7f2"
    border.width: 1
    radius: 3
    clip: true

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 3
        color: root.expanded ? "#ef48bb" : "#22e7f2"
        opacity: 0.76
    }

    MouseArea {
        id: inputBlocker
        objectName: "mediaInputBlocker"
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: function(mouse) { mouse.accepted = true }
    }

    Item {
        id: libraryArea
        objectName: "libraryArea"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: transportArea.top
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.bottomMargin: 5
        height: root.expanded ? root.expandedHeight - root.collapsedHeight - 9 : 0
        visible: root.expanded

        RowLayout {
            id: libraryHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 23
            spacing: 8

            Text {
                text: "MEDIA LIBRARY"
                color: "#ef70cc"
                font.family: "monospace"
                font.pixelSize: 10
                font.bold: true
                font.letterSpacing: 1
            }
            Text {
                Layout.fillWidth: true
                text: String(root.controller.selectedDirectory || "NO FOLDER SELECTED")
                textFormat: Text.PlainText
                color: "#718e98"
                font.family: "monospace"
                font.pixelSize: 8
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideMiddle
            }
        }

        Rectangle {
            id: listFrame
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: libraryHeader.bottom
            anchors.bottom: libraryActions.top
            anchors.topMargin: 5
            anchors.bottomMargin: 7
            color: Qt.rgba(5 / 255, 10 / 255, 16 / 255, 0.72)
            border.color: "#244f5a"
            radius: 2
            clip: true

            ListView {
                id: trackList
                objectName: "trackList"
                anchors.fill: parent
                anchors.margins: 2
                clip: true
                model: root.controller.trackTitles || []
                currentIndex: root.controller.currentIndex
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                    id: trackRow
                    required property int index
                    required property string modelData
                    readonly property bool currentTrack: index === root.controller.currentIndex
                    function activate() { root.controller.selectTrack(index) }
                    objectName: "trackRow" + index
                    width: ListView.view.width
                    height: 30
                    color: currentTrack ? Qt.rgba(0.94, 0.28, 0.73, 0.16)
                                        : trackMouse.containsMouse ? Qt.rgba(0.13, 0.91, 0.95, 0.08)
                                                                  : "transparent"

                    Rectangle {
                        visible: trackRow.currentTrack
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2
                        height: parent.height - 8
                        color: "#ef48bb"
                    }
                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 10
                        anchors.rightMargin: 8
                        text: (trackRow.index + 1) + "  " + trackRow.modelData
                        textFormat: Text.PlainText
                        color: trackRow.currentTrack ? "#ffe1f3" : "#9ec2ca"
                        font.family: "monospace"
                        font.pixelSize: 9
                        font.bold: trackRow.currentTrack
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        id: trackMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: trackRow.activate()
                        Accessible.name: "Play " + trackRow.modelData
                    }
                }
            }

            Text {
                id: emptyState
                objectName: "emptyState"
                anchors.centerIn: parent
                visible: trackList.count === 0
                text: "NO PLAYABLE TRACKS IN FOLDER"
                color: "#718e98"
                font.family: "monospace"
                font.pixelSize: 9
            }
        }

        RowLayout {
            id: libraryActions
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 32
            spacing: 6

            NeonButton {
                id: selectFolderButton
                objectName: "selectFolderButton"
                text: "SELECT FOLDER"
                accent: "#ef48bb"
                Layout.fillWidth: true
                onClicked: root.directorySelectionRequested()
                hint: "Request a non-recursive music-folder selection"
            }
            NeonButton {
                id: refreshButton
                objectName: "mediaRefreshButton"
                text: "REFRESH"
                Layout.fillWidth: true
                onClicked: root.controller.rescan()
                hint: "Rescan the selected folder"
            }
        }
    }

    Item {
        id: transportArea
        objectName: "transportArea"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 11
        anchors.rightMargin: 10
        anchors.bottomMargin: 7
        height: root.collapsedHeight - 13

        RowLayout {
            id: titleRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 23
            spacing: 7

            Text {
                id: currentTrackText
                objectName: "currentTrackText"
                Layout.fillWidth: true
                text: String(root.controller.currentTitle || "NO TRACK")
                textFormat: Text.PlainText
                color: "#dffcff"
                font.family: "monospace"
                font.pixelSize: 10
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                id: timeText
                objectName: "mediaTimeText"
                text: root.formatTime(root.controller.position) + " / " + root.formatTime(root.controller.duration)
                color: "#7bc5cc"
                font.family: "monospace"
                font.pixelSize: 9
            }
            NeonButton {
                id: expandButton
                objectName: "expandButton"
                text: root.expanded ? "TRACKS -" : "TRACKS +"
                accent: root.expanded ? "#ef48bb" : "#22e7f2"
                implicitWidth: 72
                implicitHeight: 24
                onClicked: root.expanded = !root.expanded
                hint: root.expanded ? "Collapse media library" : "Expand media library"
            }
        }

        AudioVisualizer {
            id: audioVisualizer
            objectName: "audioVisualizer"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: titleRow.bottom
            anchors.topMargin: 2
            height: 58
            levels: root.controller.visualizerData || []
            position: root.controller.position
            duration: root.controller.duration
            playing: root.controller.playing
            muted: root.controller.muted
        }

        AudioWaveform {
            id: audioWaveform
            objectName: "audioWaveform"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: audioVisualizer.bottom
            anchors.topMargin: 3
            height: 37
            amplitudes: root.controller.waveformData || []
            position: root.controller.position
            duration: root.controller.duration
            playing: root.controller.playing
            muted: root.controller.muted
        }

        RowLayout {
            id: playbackControls
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: audioWaveform.bottom
            anchors.topMargin: 4
            height: 32
            spacing: 5

            NeonButton {
                id: previousButton
                objectName: "previousButton"
                text: "|<"
                implicitWidth: 42
                onClicked: root.controller.previous()
                hint: "Previous track"
            }
            NeonButton {
                id: playPauseButton
                objectName: "playPauseButton"
                text: root.controller.playing ? "PAUSE" : "PLAY"
                accent: "#ef48bb"
                Layout.fillWidth: true
                onClicked: root.controller.togglePlayback()
                hint: root.controller.playing ? "Pause soundtrack" : "Play soundtrack"
            }
            NeonButton {
                id: nextButton
                objectName: "nextButton"
                text: ">|"
                implicitWidth: 42
                onClicked: root.controller.next()
                hint: "Next track"
            }
        }

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 28
            spacing: 8

            NeonButton {
                id: muteButton
                objectName: "muteButton"
                text: root.controller.muted ? "MUTED" : "MUTE"
                accent: root.controller.muted ? "#ef48bb" : "#22e7f2"
                implicitWidth: 66
                implicitHeight: 28
                onClicked: root.controller.muted = !root.controller.muted
                hint: root.controller.muted ? "Unmute soundtrack" : "Mute soundtrack"
            }
            Slider {
                id: volumeSlider
                objectName: "volumeSlider"
                from: 0
                to: 1
                value: root.controller.volume
                Layout.fillWidth: true
                onMoved: root.controller.volume = value
                Accessible.name: "Soundtrack volume"

                background: Rectangle {
                    x: volumeSlider.leftPadding
                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                    width: volumeSlider.availableWidth
                    height: 3
                    color: "#244f5a"
                    radius: 1
                    Rectangle {
                        width: volumeSlider.visualPosition * parent.width
                        height: parent.height
                        color: root.controller.muted ? "#6d3b62" : "#22e7f2"
                        radius: 1
                    }
                }
                handle: Rectangle {
                    x: volumeSlider.leftPadding + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                    y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                    implicitWidth: 10
                    implicitHeight: 16
                    radius: 2
                    color: root.controller.muted ? "#ef70cc" : "#dffcff"
                    border.color: root.controller.muted ? "#ef48bb" : "#22e7f2"
                }
            }
            Text {
                objectName: "volumeText"
                text: Math.round(root.controller.volume * 100) + "%"
                color: root.controller.muted ? "#ef70cc" : "#9cdbe0"
                font.family: "monospace"
                font.pixelSize: 9
                horizontalAlignment: Text.AlignRight
                Layout.preferredWidth: 32
            }
        }
    }
}
