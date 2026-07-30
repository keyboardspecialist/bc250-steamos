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

    function test_neonButton() {
        var button = createTemporaryObject(buttonComponent, this)
        verify(button !== null)
        compare(button.text, "TEST")
        verify(button.implicitHeight >= 32)
    }

    function test_statusRow() {
        var row = createTemporaryObject(rowComponent, this)
        verify(row !== null)
        compare(row.health, 1)
        compare(row.value, "Online")
    }
}
