// `?` from any non-insert mode: a full keybind reference across every mode.
// Scrim + centered card; Esc or ? closes. Purely presentational — the shell's
// key handler owns show/hide and swallows keys while it's open.
import QtQuick
import "."
import QsLib

Item {
    id: root
    anchors.fill: parent
    visible: shown
    property bool shown: false

    // [title, [ [ [keys…], description ], … ] ]
    readonly property var columns: [
        [
            ["Normal", [
                [["j"], "Down (count: 8j)"],
                [["k"], "Up"],
                [["↵"], "Open conversation"],
                [["l"], "Open / focus index"],
                [["h"], "Focus sidebar"],
                [["g", "g"], "Jump to top"],
                [["⇧g"], "Jump to bottom"],
                [["x"], "Star"],
                [["e"], "Archive"],
                [["d", "d"], "Trash"],
                [["u"], "Undo last remove"],
                [["v"], "Visual select"],
                [["⇧r"], "Toggle read"],
                [["r"], "Refresh"],
                [["n"], "Compose"],
                [["/"], "Search"],
                [["q"], "Hide window"],
            ]],
            ["Go to", [
                [["g", "i"], "Inbox"],
                [["g", "⇧i"], "Starred"],
                [["g", "s"], "Sent"],
                [["g", "⇧s"], "Spam"],
                [["g", "d"], "Drafts"],
                [["g", "t"], "Threads"],
                [["g", "⇧t"], "Trash"],
                [["g", "c"], "Calendar"],
            ]],
        ],
        [
            ["Conversation", [
                [["j"], "Scroll down"],
                [["k"], "Scroll up"],
                [["⇧j"], "Next message"],
                [["⇧k"], "Previous message"],
                [["i"], "Reply"],
                [["a"], "Toggle reply-all"],
                [["r"], "Reply to focused"],
                [["⇧f"], "Forward"],
                [["f"], "Link hints"],
                [["o"], "Open in browser"],
                [["y"], "RSVP accept"],
                [["m"], "RSVP tentative"],
                [["n"], "RSVP decline"],
                [["e"], "Archive"],
                [["d", "d"], "Trash"],
                [["h"], "Close"],
            ]],
            ["Visual", [
                [["j", "k"], "Extend selection"],
                [["e"], "Archive selection"],
                [["d"], "Trash selection"],
                [["r"], "Mark read"],
                [["x"], "Star"],
                [["⌃d", "⌃u"], "Half-page (extends)"],
                [["esc"], "Exit"],
            ]],
        ],
        [
            ["Calendar", [
                [["j", "k"], "Move"],
                [["↵"], "Open event"],
                [["o"], "Open in browser"],
                [["y", "m", "n"], "RSVP"],
                [["⇧n"], "New event"],
                [["s"], "Cycle span"],
                [["r"], "Refresh"],
            ]],
            ["Global", [
                [["⌃d", "⌃u"], "Half-page down / up"],
                [["⌃h", "⌃l"], "Sidebar / index"],
                [["⌃s"], "Next account"],
                [["⌃⇧h", "⌃⇧l"], "Prev / next account"],
                [["?"], "This cheat sheet"],
            ]],
            ["Insert", [
                [["⌃↵"], "Send"],
                [["⌃o"], "Attach clipboard path"],
                [["esc"], "Discard / exit"],
            ]],
        ],
    ]

    Rectangle {
        anchors.fill: parent
        color: Theme.ink
        opacity: 0.5
        MouseArea { anchors.fill: parent; onClicked: root.shown = false }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(960, parent.width - 80)
        height: Math.min(colsRow.implicitHeight + header.height + 56, parent.height - 60)
        color: Theme.bg
        radius: Theme.radiusCard
        border.width: 1
        border.color: Theme.hairline

        Column {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 24 }
            spacing: 2
            Text {
                text: "Keyboard shortcuts"
                color: Theme.fg
                font.family: Theme.fontFamily; font.pixelSize: 18; font.weight: 600
                renderType: Text.NativeRendering
            }
            Text {
                text: "esc or ? to close"
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
                renderType: Text.NativeRendering
            }
        }

        Row {
            id: colsRow
            anchors { top: header.bottom; left: parent.left; right: parent.right
                      bottom: parent.bottom; margins: 24; topMargin: 18 }
            spacing: 28

            Repeater {
                model: root.columns
                Column {
                    required property var modelData
                    width: (colsRow.width - colsRow.spacing * 2) / 3
                    spacing: 18

                    Repeater {
                        model: parent.modelData
                        Column {
                            required property var modelData
                            width: parent.width
                            spacing: 5

                            Text {
                                text: modelData[0]
                                color: Theme.fg_muted
                                font.family: Theme.fontFamily; font.pixelSize: 11
                                font.weight: 600; font.capitalization: Font.AllUppercase
                                font.letterSpacing: 1.2
                                renderType: Text.NativeRendering
                            }
                            Repeater {
                                model: modelData[1]
                                Row {
                                    required property var modelData
                                    width: parent.width
                                    spacing: 8
                                    Row {
                                        id: keysRow
                                        spacing: 3
                                        Repeater {
                                            model: modelData[0]
                                            KeyCap {
                                                required property var modelData
                                                text: modelData
                                                small: true
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                    }
                                    Text {
                                        width: parent.width - keysRow.width - parent.spacing
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData[1]
                                        color: Theme.fg
                                        elide: Text.ElideRight
                                        font.family: Theme.fontFamily; font.pixelSize: 13
                                        renderType: Text.NativeRendering
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
