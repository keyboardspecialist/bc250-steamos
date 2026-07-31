import QtQuick 2.15

Item {
    id: root

    property var levels: []
    property real position: 0
    property real duration: 0
    property bool playing: false
    property bool muted: false

    readonly property bool active: levels && levels.length > 0
    property real liveLevel: 0
    property real beatPulse: 0
    property real phase: 0
    property real syncPosition: position
    property double syncTime: Date.now()
    property int frameIndex: 0
    readonly property int barCount: 34
    readonly property real barGap: 2

    function resync() {
        syncPosition = position
        syncTime = Date.now()
        updateFrame()
    }

    function levelAt(index) {
        if (!levels || levels.length === 0)
            return 0
        var bounded = Math.max(0, Math.min(levels.length - 1, index))
        var value = Number(levels[bounded])
        return isFinite(value) ? Math.max(0, Math.min(1, value)) : 0
    }

    function estimatedPosition() {
        var value = syncPosition
        if (playing)
            value += Date.now() - syncTime
        return duration > 0 ? Math.max(0, Math.min(duration, value)) : Math.max(0, value)
    }

    function updateFrame() {
        if (!active) {
            liveLevel = 0
            beatPulse = 0
            frameIndex = 0
            return
        }

        var fraction = duration > 0 ? estimatedPosition() / duration : 0
        var index = Math.min(levels.length - 1, Math.floor(fraction * levels.length))
        frameIndex = index
        var current = levelAt(index)
        var average = 0
        var count = 0
        for (var offset = 1; offset <= 8; ++offset) {
            if (index - offset >= 0) {
                average += levelAt(index - offset)
                count += 1
            }
        }
        if (count > 0)
            average /= count

        var onset = Math.max(0, current - average)
        liveLevel += (current - liveLevel) * 0.34
        beatPulse = Math.max(beatPulse * 0.78, Math.min(1, onset * 4.2))
        phase += playing ? 0.075 + liveLevel * 0.08 : 0
    }

    onPositionChanged: resync()
    onPlayingChanged: resync()
    onLevelsChanged: resync()
    onActiveChanged: {
        if (!active) {
            liveLevel = 0
            beatPulse = 0
        }
        resync()
    }
    onDurationChanged: resync()

    Timer {
        interval: 33
        repeat: true
        running: root.playing && root.active
        triggeredOnStart: true
        onTriggered: root.updateFrame()
    }

    Rectangle {
        anchors.fill: parent
        color: "#050b11b8"

        Repeater {
            model: Math.ceil(root.width / 22)
            Rectangle {
                required property int index
                x: index * 22
                width: 1
                height: root.height
                color: "#17343d"
            }
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: "#17343d"
        }

        Repeater {
            model: root.barCount
            Rectangle {
                required property int index
                objectName: "visualizerBar" + index
                readonly property int sourceOffset: index - Math.floor(root.barCount / 2)
                readonly property real level: root.levelAt(root.frameIndex + sourceOffset)
                readonly property real wave: 0.86 + Math.sin(root.phase + index * 0.68) * 0.14
                readonly property real emphasis: 1 + root.beatPulse
                    * Math.max(0, 1 - Math.abs(sourceOffset) / 12)
                readonly property real barHeight: Math.max(1, level * wave * emphasis
                                                            * root.height * 0.41)
                readonly property bool passed: sourceOffset <= 0

                visible: root.active
                x: index * (width + root.barGap)
                y: root.height / 2 - barHeight
                width: Math.max(2, (root.width - (root.barCount - 1) * root.barGap)
                                / root.barCount)
                height: barHeight * 2
                color: passed ? (root.muted ? "#b34891" : "#ef48bb")
                              : (root.muted ? "#436975" : "#22e7f2")
                opacity: 0.48 + level * 0.5
            }
        }

        Rectangle {
            readonly property real coreRadius: 2.5 + root.liveLevel * 4 + root.beatPulse * 7
            anchors.centerIn: parent
            visible: root.active
            width: coreRadius * 2
            height: width
            radius: width / 2
            color: "transparent"
            border.color: root.muted ? "#ef70cc" : "#dffcff"
            border.width: 1.5
        }
    }

    Text {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 4
        text: root.active ? "LIVE // BEAT ENERGY" : "LIVE // ANALYZING"
        color: root.active ? "#71cbd3" : "#58717a"
        font.family: "monospace"
        font.pixelSize: 7
        font.bold: true
        font.letterSpacing: 0.6
    }
}
