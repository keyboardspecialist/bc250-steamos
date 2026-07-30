import QtQuick 2.15

Item {
    id: root

    property var amplitudes: []
    property real position: 0
    property real duration: 0
    property bool playing: false
    property bool muted: false

    readonly property bool quiet: !amplitudes || amplitudes.length === 0
    readonly property real playbackFraction: duration > 0
        ? Math.max(0, Math.min(1, position / duration)) : 0
    readonly property real playheadX: playbackFraction * width

    implicitWidth: 320
    implicitHeight: 48

    onAmplitudesChanged: waveform.requestPaint()
    onPositionChanged: waveform.requestPaint()
    onDurationChanged: waveform.requestPaint()
    onPlayingChanged: waveform.requestPaint()
    onMutedChanged: waveform.requestPaint()

    Canvas {
        id: waveform
        anchors.fill: parent

        function drawEnvelope(context, samples, color, endX) {
            var inset = 2
            var drawableWidth = Math.max(0, width - inset * 2)
            var center = height / 2
            var peakHeight = Math.max(1, height * 0.42)
            var count = samples.length
            var step = count > 1 ? drawableWidth / (count - 1) : 0

            context.save()
            context.beginPath()
            context.rect(0, 0, Math.max(0, endX), height)
            context.clip()
            context.strokeStyle = color
            context.lineWidth = count > drawableWidth / 2 ? 1 : 1.5
            context.beginPath()
            for (var i = 0; i < count; ++i) {
                var sample = Number(samples[i])
                if (!isFinite(sample))
                    sample = 0
                var amplitude = Math.max(0, Math.min(1, Math.abs(sample)))
                var x = count > 1 ? inset + i * step : width / 2
                var halfHeight = Math.max(0.75, amplitude * peakHeight)
                context.moveTo(x, center - halfHeight)
                context.lineTo(x, center + halfHeight)
            }
            context.stroke()
            context.restore()
        }

        onPaint: {
            var context = getContext("2d")
            context.reset()
            context.clearRect(0, 0, width, height)

            var center = height / 2
            context.strokeStyle = "#25515a"
            context.lineWidth = 1
            context.beginPath()
            context.moveTo(0, center + 0.5)
            context.lineTo(width, center + 0.5)
            context.stroke()

            if (root.quiet) {
                context.strokeStyle = "#326670"
                context.beginPath()
                for (var x = 3; x < width; x += 8) {
                    context.moveTo(x, center - 1)
                    context.lineTo(Math.min(width, x + 3), center + 1)
                }
                context.stroke()
                return
            }

            drawEnvelope(context, root.amplitudes, "#397985", width)
            drawEnvelope(context, root.amplitudes, "#ef48bb", root.playheadX)

            context.strokeStyle = root.muted ? "#ef70cc"
                                               : root.playing ? "#dffcff" : "#22e7f2"
            context.lineWidth = 1
            context.beginPath()
            context.moveTo(Math.round(root.playheadX) + 0.5, 2)
            context.lineTo(Math.round(root.playheadX) + 0.5, height - 2)
            context.stroke()
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
