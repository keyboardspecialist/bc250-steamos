import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Rectangle {
    id: root
    property string title: ""
    property string value: "Unavailable"
    property color accent: Kirigami.Theme.highlightColor
    property var samples: []
    property real floor: 0

    implicitWidth: 210
    implicitHeight: 118
    radius: Kirigami.Units.cornerRadius
    color: Kirigami.Theme.alternateBackgroundColor
    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.34)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: 2

        RowLayout {
            Layout.fillWidth: true
            QQC2.Label {
                text: root.title
                color: Kirigami.Theme.disabledTextColor
                Layout.fillWidth: true
            }
            QQC2.Label {
                text: root.value
                color: root.accent
                font.weight: Font.Bold
            }
        }

        Canvas {
            id: chart
            Layout.fillWidth: true
            Layout.fillHeight: true
            antialiasing: true

            onPaint: {
                var context = getContext("2d");
                context.reset();
                var values = root.samples || [];
                var present = [];
                for (var i = 0; i < values.length; ++i) {
                    if (values[i] !== null && values[i] !== undefined)
                        present.push(Number(values[i]));
                }
                context.strokeStyle = Qt.rgba(Kirigami.Theme.textColor.r,
                    Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12);
                context.beginPath();
                context.moveTo(0, height - 1);
                context.lineTo(width, height - 1);
                context.stroke();
                if (present.length === 0)
                    return;
                var maximum = Math.max.apply(Math, present.concat([root.floor + 1]));
                context.strokeStyle = root.accent;
                context.lineWidth = 2;
                context.lineJoin = "round";
                context.beginPath();
                var started = false;
                for (i = 0; i < values.length; ++i) {
                    if (values[i] === null || values[i] === undefined) {
                        started = false;
                        continue;
                    }
                    var x = values.length < 2 ? width : i * width / 35;
                    var y = height - 3 - Math.max(0, (Number(values[i]) - root.floor)
                        / (maximum - root.floor)) * (height - 7);
                    if (!started)
                        context.moveTo(x, y);
                    else
                        context.lineTo(x, y);
                    started = true;
                }
                context.stroke();
            }

            Connections {
                target: root
                function onSamplesChanged() { chart.requestPaint(); }
                function onWidthChanged() { chart.requestPaint(); }
                function onHeightChanged() { chart.requestPaint(); }
            }
        }
    }
}
