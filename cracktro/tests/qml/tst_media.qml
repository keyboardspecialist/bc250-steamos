import QtQuick 2.15
import QtTest 1.3
import "../../qml/components" as Components

TestCase {
    id: testCase
    name: "MediaComponents"
    when: windowShown
    width: 640
    height: 480

    Component {
        id: fakeControllerComponent
        QtObject {
            property var trackTitles: ["Alpha", "Beta", "Gamma"]
            property int currentIndex: 1
            property string currentTitle: "Beta"
            property bool playing: true
            property real position: 65000
            property real duration: 185000
            property bool muted: false
            property real volume: 0.7
            property string selectedDirectory: "/tmp/music"
            property var waveformData: [0.1, 0.5, 1.0, 0.25, 0.65]
            property var visualizerData: [0.1, 0.2, 0.8, 0.25, 1.0, 0.3, 0.7, 0.2, 0.9, 0.15]

            property int previousCalls: 0
            property int toggleCalls: 0
            property int nextCalls: 0
            property int selectedTrack: -1
            property int rescanCalls: 0

            function previous() { previousCalls += 1 }
            function togglePlayback() {
                toggleCalls += 1
                playing = !playing
            }
            function next() { nextCalls += 1 }
            function selectTrack(index) {
                selectedTrack = index
                currentIndex = index
                currentTitle = trackTitles[index]
            }
            function rescan() { rescanCalls += 1 }
        }
    }

    Component {
        id: mediaPaneComponent
        Components.MediaPane {}
    }

    Component {
        id: waveformComponent
        Components.AudioWaveform { width: 300; height: 60 }
    }

    Component {
        id: signalSpyComponent
        SignalSpy {}
    }

    function makePane() {
        var controller = createTemporaryObject(fakeControllerComponent, testCase)
        verify(controller !== null)
        var pane = createTemporaryObject(mediaPaneComponent, testCase,
                                         {"controller": controller})
        verify(pane !== null)
        return {"pane": pane, "controller": controller}
    }

    function test_collapsedAndExpandedGeometry() {
        var fixture = makePane()
        var pane = fixture.pane
        compare(pane.height, pane.collapsedHeight)
        compare(pane.y + pane.height, testCase.height)

        var bottom = pane.y + pane.height
        findChild(pane, "expandButton").clicked()
        verify(pane.expanded)
        compare(pane.height, pane.expandedHeight)
        compare(pane.y + pane.height, bottom)
        verify(pane.y < testCase.height - pane.collapsedHeight)
        verify(findChild(pane, "libraryArea").height > 0)
    }

    function test_transportRoutingAndState() {
        var fixture = makePane()
        var pane = fixture.pane
        var controller = fixture.controller
        var playButton = findChild(pane, "playPauseButton")

        compare(findChild(pane, "currentTrackText").text, "Beta")
        compare(findChild(pane, "mediaTimeText").text, "1:05 / 3:05")
        compare(playButton.text, "PAUSE")

        findChild(pane, "previousButton").clicked()
        playButton.clicked()
        findChild(pane, "nextButton").clicked()

        compare(controller.previousCalls, 1)
        compare(controller.toggleCalls, 1)
        compare(controller.nextCalls, 1)
        compare(controller.playing, false)
        compare(playButton.text, "PLAY")

        var volumeSlider = findChild(pane, "volumeSlider")
        volumeSlider.value = 0.35
        volumeSlider.moved()
        compare(controller.volume, 0.35)

        findChild(pane, "muteButton").clicked()
        compare(controller.muted, true)
        compare(findChild(pane, "muteButton").text, "MUTED")
    }

    function test_trackSelectionAndActions() {
        var fixture = makePane()
        var pane = fixture.pane
        var controller = fixture.controller
        pane.expanded = true
        wait(0)

        var currentRow = findChild(pane, "trackRow1")
        verify(currentRow !== null)
        verify(currentRow.currentTrack)

        var firstRow = findChild(pane, "trackRow0")
        verify(firstRow !== null)
        firstRow.activate()
        compare(controller.selectedTrack, 0)
        compare(findChild(pane, "currentTrackText").text, "Alpha")
        verify(firstRow.currentTrack)

        var folderSpy = createTemporaryObject(signalSpyComponent, testCase,
                                               {"target": pane,
                                                "signalName": "directorySelectionRequested"})
        verify(folderSpy !== null)
        findChild(pane, "selectFolderButton").clicked()
        findChild(pane, "mediaRefreshButton").clicked()
        compare(folderSpy.count, 1)
        compare(controller.rescanCalls, 1)
    }

    function test_emptyState() {
        var fixture = makePane()
        var pane = fixture.pane
        var controller = fixture.controller
        controller.trackTitles = []
        controller.currentIndex = -1
        controller.currentTitle = ""
        pane.expanded = true
        wait(0)

        var emptyState = findChild(pane, "emptyState")
        compare(findChild(pane, "trackList").count, 0)
        compare(emptyState.text, "NO PLAYABLE TRACKS IN FOLDER")
        compare(findChild(pane, "currentTrackText").text, "NO TRACK")
    }

    function test_waveformQuietActivePausedAndMuted() {
        var waveform = createTemporaryObject(waveformComponent, testCase)
        verify(waveform !== null)
        verify(waveform.quiet)
        compare(waveform.playbackFraction, 0)

        waveform.amplitudes = [0, 0.5, 1, 0.25]
        waveform.duration = 1000
        waveform.position = 250
        waveform.playing = true
        verify(!waveform.quiet)
        compare(waveform.playbackFraction, 0.25)
        compare(waveform.playheadX, 75)

        waveform.playing = false
        compare(waveform.playheadX, 75)
        waveform.muted = true
        waveform.position = 500
        compare(waveform.playheadX, 150)
    }

    function test_dedicatedVisualizerRespondsAndFreezes() {
        var fixture = makePane()
        var visualizer = findChild(fixture.pane, "audioVisualizer")
        verify(visualizer !== null)
        verify(visualizer.active)
        var centerBar = findChild(visualizer, "visualizerBar17")
        verify(centerBar !== null)
        tryVerify(function() { return centerBar.height > 2 }, 500)
        tryVerify(function() { return visualizer.liveLevel > 0 }, 500)

        fixture.controller.playing = false
        wait(50)
        var frozenPhase = visualizer.phase
        wait(100)
        compare(visualizer.phase, frozenPhase)

        fixture.controller.visualizerData = []
        verify(!visualizer.active)
        compare(visualizer.liveLevel, 0)

        fixture.controller.visualizerData = [0.2, 0.8, 0.4]
        verify(visualizer.active)
        tryVerify(function() { return centerBar.height > 2 }, 500)
    }

    function test_panelConsumesBackgroundPresses() {
        var fixture = makePane()
        var blocker = findChild(fixture.pane, "mediaInputBlocker")
        verify(blocker !== null)
        verify(blocker.enabled)
        verify((blocker.acceptedButtons & Qt.LeftButton) !== 0)
    }
}
