import QtQuick 2.15
import QtTest 1.3
import "../../qml/components" as Components

TestCase {
    name: "CracktroComponents"
    when: windowShown
    width: 640
    height: 480

    Component {
        id: buttonComponent
        Components.NeonButton { text: "TEST"; hint: "A test control" }
    }

    Component {
        id: rowComponent
        Components.StatusRow { label: "Service"; value: "Online"; health: 1; width: 300 }
    }

    Component {
        id: spinBoxComponent
        Components.NeonSpinBox {
            from: 0
            to: 100
            value: 40
            stepSize: 10
            editable: true
            textFromValue: function(value) { return value + " MHz" }
        }
    }

    function test_neonButton() {
        var button = createTemporaryObject(buttonComponent, this)
        verify(button !== null)
        compare(button.text, "TEST")
        verify(button.implicitHeight >= 32)
        var toolTip = findChild(button, "neonToolTip")
        verify(toolTip !== null)
        compare(toolTip.text, "A test control")
        compare(toolTip.delay, 450)
        verify(findChild(toolTip, "neonToolTipFrame") !== null)
    }

    function test_statusRow() {
        var row = createTemporaryObject(rowComponent, this)
        verify(row !== null)
        compare(row.health, 1)
        compare(row.value, "Online")
    }

    function test_neonSpinBox() {
        var spinBox = createTemporaryObject(spinBoxComponent, this)
        verify(spinBox !== null)
        compare(spinBox.displayText, "40 MHz")
        verify(findChild(spinBox, "spinInput") !== null)
        verify(findChild(spinBox, "spinUpIndicator") !== null)
        verify(findChild(spinBox, "spinDownIndicator") !== null)
        spinBox.increase()
        compare(spinBox.value, 50)
    }
}
