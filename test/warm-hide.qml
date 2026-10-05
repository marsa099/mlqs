import QtQuick
import QtTest
import Quickshell
import "."
ShellRoot {
    id: test
    property int phase: 0
    MlqsWindow { id: mlqs; Item { TestEvent { id: input } } }
    Window { id: outside; visible: false; width: 100; height: 100 }
    function check(value, message) { if (!value) throw new Error(message) }
    Timer {
        interval: 250; repeat: true; running: true
        onTriggered: {
            if (test.phase === 0) {
                test.check(mlqs.visible, "cold window hidden")
                mlqs.pane = "sidebar"
                mlqs.contentItem.Window.window.requestActivate()
            } else if (test.phase === 1) {
                test.check(mlqs.contentItem.Window.window.active && mlqs.visible, "MLQS did not activate")
                input.mouseClick(mlqs.contentItem, 3, 3, Qt.LeftButton, Qt.NoModifier, 0)
            } else if (test.phase === 2) {
                test.check(mlqs.visible, "inside click hid MLQS")
                outside.visible = true
                outside.requestActivate()
            } else if (test.phase === 3) {
                test.check(outside.active && !mlqs.visible, "outside focus did not hide MLQS")
                test.check(mlqs.pane === "sidebar", "outside hide reset navigation state")
                Backend.summonRequested()
                mlqs.contentItem.Window.window.requestActivate()
            } else if (test.phase === 4) {
                test.check(mlqs.visible && mlqs.contentItem.Window.window.active, "warm summon did not restore MLQS")
                test.check(mlqs.pane === "sidebar", "warm summon reset navigation state")
                input.keyClick(Qt.Key_Q, Qt.NoModifier, 0)
            } else if (test.phase === 5) {
                test.check(!mlqs.visible, "q did not use warm hide")
                Backend.summonRequested()
            } else if (test.phase === 6) {
                test.check(mlqs.visible && mlqs.pane === "sidebar", "q hide could not warm summon")
                console.log("PASS: cold show, inside click, outside-focus warm hide, preserved navigation, summon, and q hide")
                Qt.quit()
            }
            test.phase++
        }
    }
}
