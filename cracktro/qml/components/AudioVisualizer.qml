import QtQuick 2.15

Item {
    id: root

    property var levels: []
    property real position: 0
    property real duration: 0
    property bool playing: false
    property bool muted: false

    readonly property bool active: levels && levels.length > 0 && duration > 0
    property real liveLevel: 0
    property real beatPulse: 0
    property real phase: 0
    property real syncPosition: position
    property double syncTime: Date.now()

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
        return Math.max(0, Math.min(duration, value))
    }

    function updateFrame() {
        if (!active) {
            liveLevel = 0
            beatPulse = 0
            visualizer.requestPaint()
            return
        }

        var fraction = estimatedPosition() / duration
        var index = Math.min(levels.length - 1, Math.floor(fraction * levels.length))
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
        visualizer.requestPaint()
    }

    onPositionChanged: resync()
    onPlayingChanged: resync()
    onLevelsChanged: resync()
    onActiveChanged: {
        if (!active) {
            liveLevel = 0
            beatPulse = 0
        }
    }
    onDurationChanged: resync()
    onMutedChanged: visualizer.requestPaint()
    onWidthChanged: visualizer.requestPaint()
    onHeightChanged: visualizer.requestPaint()

    Timer {
        interval: 33
        repeat: true
        running: root.playing && root.active
        triggeredOnStart: true
        onTriggered: root.updateFrame()
    }

    Canvas {
        id: visualizer
        anchors.fill: parent

        onPaint: {
            var context = getContext("2d")
            context.reset()
            context.clearRect(0, 0, width, height)

            context.fillStyle = "#050b11b8"
            context.fillRect(0, 0, width, height)
            context.strokeStyle = "#17343d"
            context.lineWidth = 1
            for (var gridX = 0.5; gridX < width; gridX += 22) {
                context.beginPath()
                context.moveTo(gridX, 0)
                context.lineTo(gridX, height)
                context.stroke()
            }
            context.beginPath()
            context.moveTo(0, height / 2 + 0.5)
            context.lineTo(width, height / 2 + 0.5)
            context.stroke()

            if (!root.active)
                return

            var estimated = root.estimatedPosition()
            var currentIndex = Math.min(root.levels.length - 1,
                                        Math.floor(estimated / root.duration * root.levels.length))
            var bars = 34
            var gap = 2
            var barWidth = Math.max(2, (width - (bars - 1) * gap) / bars)
            var centerY = height / 2
            var maximumHeight = height * 0.41
            for (var bar = 0; bar < bars; ++bar) {
                var sourceOffset = bar - Math.floor(bars / 2)
                var level = root.levelAt(currentIndex + sourceOffset)
                var wave = 0.86 + Math.sin(root.phase + bar * 0.68) * 0.14
                var emphasis = 1 + root.beatPulse * Math.max(0, 1 - Math.abs(sourceOffset) / 12)
                var barHeight = Math.max(1, level * wave * emphasis * maximumHeight)
                var x = bar * (barWidth + gap)
                var passed = sourceOffset <= 0
                context.fillStyle = passed
                    ? (root.muted ? "#b34891" : "#ef48bb")
                    : (root.muted ? "#436975" : "#22e7f2")
                context.globalAlpha = 0.48 + level * 0.5
                context.fillRect(x, centerY - barHeight, barWidth, barHeight * 2)
            }
            context.globalAlpha = 1

            var coreRadius = 2.5 + root.liveLevel * 4 + root.beatPulse * 7
            context.strokeStyle = root.muted ? "#ef70cc" : "#dffcff"
            context.lineWidth = 1.5
            context.beginPath()
            context.arc(width / 2, centerY, coreRadius, 0, Math.PI * 2)
            context.stroke()
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
