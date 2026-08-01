import QtQuick 2.15
import QtTest 1.3
import "../../qml/components" as Components

TestCase {
    name: "BC250TrainerComponents"
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

    Component {
        id: comboBoxComponent
        Components.NeonComboBox {
            model: ["Adaptive", "Custom range", "Pinned frequency"]
            currentIndex: 1
            width: 240
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
        var frame = findChild(toolTip, "neonToolTipFrame")
        verify(frame !== null)
        verify(findChild(frame, "backdropPanelTint") !== null)
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
        spinBox.forceActiveFocus()
        keyClick(Qt.Key_Up)
        compare(spinBox.value, 50)
    }

    function test_neonComboBox() {
        var comboBox = createTemporaryObject(comboBoxComponent, this)
        verify(comboBox !== null)
        compare(comboBox.displayText, "Custom range")
        verify(comboBox.implicitHeight >= 32)
        verify(findChild(comboBox, "comboDisplay") !== null)
        verify(findChild(comboBox, "comboIndicator") !== null)
        verify(findChild(comboBox.popup, "comboPopupFrame") !== null)
    }
}
