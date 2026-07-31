import QtQuick 2.15

Item {
    id: root

    property var amplitudes: []
    property real position: 0
    property real duration: 0
    property bool playing: false
    property bool muted: false

    readonly property bool quiet: !amplitudes || amplitudes.length === 0
    readonly property int barCount: 128
    readonly property real playbackFraction: duration > 0
        ? Math.max(0, Math.min(1, position / duration)) : 0
    readonly property real playheadX: playbackFraction * width

    implicitWidth: 320
    implicitHeight: 48

    function levelAt(index) {
        if (quiet)
            return 0
        var sourceIndex = Math.min(amplitudes.length - 1,
                                   Math.floor(index * amplitudes.length / barCount))
        var sample = Number(amplitudes[sourceIndex])
        return isFinite(sample) ? Math.max(0, Math.min(1, Math.abs(sample))) : 0
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: "#25515a"
        }

        Repeater {
            model: root.barCount
            Rectangle {
                required property int index
                objectName: "waveformBar" + index
                readonly property real level: root.levelAt(index)
                readonly property bool played: index / Math.max(1, root.barCount - 1)
                    <= root.playbackFraction

                x: (index + 0.5) * root.width / root.barCount - width / 2
                y: root.height / 2 - height / 2
                width: Math.max(1, root.width / root.barCount * 0.62)
                height: Math.max(1, level * root.height * 0.84)
                color: played ? "#ef48bb" : "#397985"
                opacity: root.muted ? 0.55 : 0.72 + level * 0.28
            }
        }

        Rectangle {
            visible: !root.quiet && root.duration > 0
            x: Math.round(root.playheadX)
            y: 2
            width: 1
            height: parent.height - 4
            color: root.muted ? "#ef70cc" : root.playing ? "#dffcff" : "#22e7f2"
        }
    }

    Text {
        anchors.centerIn: parent
        visible: root.quiet
        text: "QUIET // WAVEFORM UNAVAILABLE"
        color: "#66838b"
        font.family: "monospace"
        font.pixelSize: 8
        font.letterSpacing: 0.5
    }
}
