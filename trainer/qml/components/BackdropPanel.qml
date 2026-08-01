import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

Item {
    id: panel

    property color fillColor: "#d90b0e18"
    property color borderColor: "#22e7f2"
    property int borderWidth: 1
    property real radius: 2
    property real blurRadius: 64

    readonly property Item backdropSource: {
        var overlay = Overlay.overlay
        if (!overlay || !overlay.parent)
            return null
        var siblings = overlay.parent.children
        for (var i = 0; i < siblings.length; ++i) {
            if (siblings[i].objectName === "trainerBackdrop")
                return siblings[i]
        }
        return null
    }

    clip: true

    ShaderEffectSource {
        id: backdropCapture
        anchors.fill: parent
        visible: false
        sourceItem: panel.backdropSource
        sourceRect: {
            if (!sourceItem)
                return Qt.rect(0, 0, 1, 1)
            var position = panel.mapToItem(sourceItem, 0, 0)
            return Qt.rect(position.x, position.y,
                           Math.max(1, panel.width), Math.max(1, panel.height))
        }
        textureSize: Qt.size(Math.max(1, Math.ceil(panel.width / 2)),
                             Math.max(1, Math.ceil(panel.height / 2)))
        live: panel.visible
        smooth: true
    }

    FastBlur {
        anchors.fill: parent
        visible: panel.backdropSource !== null
        source: backdropCapture
        radius: panel.blurRadius
    }

    Rectangle {
        id: tint
        objectName: "backdropPanelTint"
        anchors.fill: parent
        color: panel.fillColor
        border.color: panel.borderColor
        border.width: panel.borderWidth
        radius: panel.radius
    }
}
