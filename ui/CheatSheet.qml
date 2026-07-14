// `?` from any non-insert mode: a full keybind reference across every mode.
// Scrim + centered card. Responsive column count, `/` to fuzzy-filter, esc/?
// to close. Owns its keyboard focus while shown (shell.qml refocuses on close).
import QtQuick
import "."
import QsLib

Item {
    id: root
    anchors.fill: parent
    visible: shown
    property bool shown: false
    property string query: ""
    property bool searching: false

    // explicit searchField ref (not bare `text`) so it works from any caller,
    // incl. arrow-function key handlers where QML doesn't inject object scope
    function resetSearch() { searching = false; query = ""; searchField.text = "" }

    onShownChanged: {
        resetSearch()
        if (shown) keyCatcher.forceActiveFocus()
    }

    // Flat ordered sections: { title, rows: [ [ [keys…], description ] … ] }.
    readonly property var sections: [
        { title: "Normal", rows: [
            [["j"], "Down (count: 8j)"], [["k"], "Up"],
            [["↵"], "Open conversation"], [["l"], "Open / focus index"],
            [["h"], "Focus sidebar"], [["g", "g"], "Jump to top"], [["⇧g"], "Jump to bottom"],
            [["x"], "Star"], [["e"], "Archive"], [["d", "d"], "Trash"], [["u"], "Undo last remove"],
            [["v"], "Visual select"], [["⇧r"], "Toggle read"], [["r"], "Refresh"],
            [["n"], "Compose"], [["/"], "Search"], [["q"], "Hide window"],
        ]},
        { title: "Go to", rows: [
            [["g", "i"], "Inbox"], [["g", "⇧i"], "Starred"], [["g", "s"], "Sent"],
            [["g", "⇧s"], "Spam"], [["g", "d"], "Drafts"], [["g", "t"], "Threads"],
            [["g", "⇧t"], "Trash"], [["g", "c"], "Calendar"],
        ]},
        { title: "Conversation", rows: [
            [["j"], "Scroll down"], [["k"], "Scroll up"],
            [["⇧j"], "Next message"], [["⇧k"], "Previous message"],
            [["i"], "Reply"], [["a"], "Toggle reply-all"], [["r"], "Reply to focused"],
            [["⇧f"], "Forward"], [["f"], "Link hints"], [["o"], "Open in browser"],
            [["y"], "RSVP accept"], [["m"], "RSVP tentative"], [["n"], "RSVP decline"],
            [["e"], "Archive"], [["d", "d"], "Trash"], [["h"], "Close"],
        ]},
        { title: "Visual", rows: [
            [["j", "k"], "Extend selection"], [["e"], "Archive selection"],
            [["d"], "Trash selection"], [["r"], "Mark read"], [["x"], "Star"],
            [["⌃d", "⌃u"], "Half-page (extends)"], [["esc"], "Exit"],
        ]},
        { title: "Calendar", rows: [
            [["j", "k"], "Move"], [["↵"], "Open event"], [["o"], "Open in browser"],
            [["y", "m", "n"], "RSVP"], [["⇧n"], "New event"], [["s"], "Cycle span"], [["r"], "Refresh"],
        ]},
        { title: "Global", rows: [
            [["⌃d", "⌃u"], "Half-page down / up"], [["⌃h", "⌃l"], "Sidebar / index"],
            [["⌃s"], "Next account"], [["⌃⇧h", "⌃⇧l"], "Prev / next account"],
            [["⌃⇧r"], "Check for updates"], [["?"], "This cheat sheet"],
        ]},
        { title: "Insert", rows: [
            [["⌃↵"], "Send"], [["⌃o"], "Attach clipboard path"], [["esc"], "Discard / exit"],
        ]},
    ]

    // Sections with rows filtered by the query (match description or any key);
    // sections with no surviving rows drop out.
    readonly property var filtered: {
        const q = query.trim().toLowerCase()
        if (!q) return sections
        const out = []
        for (const s of sections) {
            const rows = s.rows.filter(r =>
                r[1].toLowerCase().indexOf(q) >= 0
                || r[0].some(k => k.toLowerCase().indexOf(q) >= 0)
                || s.title.toLowerCase().indexOf(q) >= 0)
            if (rows.length) out.push({ title: s.title, rows: rows })
        }
        return out
    }

    // Responsive: 1 / 2 / 3 columns by available width, sections packed into the
    // currently-shortest column (balanced by row count) so it reflows cleanly.
    // keyed on the overlay width (not panel.width — that depends on colCount)
    readonly property int colCount: root.width < 620 ? 1 : root.width < 940 ? 2 : 3
    readonly property var laidOut: {
        const cols = [], load = []
        for (let i = 0; i < colCount; i++) { cols.push([]); load.push(0) }
        for (const s of filtered) {
            let t = 0
            for (let i = 1; i < colCount; i++) if (load[i] < load[t]) t = i
            cols[t].push(s)
            load[t] += s.rows.length + 2   // +2 ≈ title + spacing weight
        }
        return cols
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.ink
        opacity: 0.5
        MouseArea { anchors.fill: parent; onClicked: root.shown = false }
    }

    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: root.shown
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Escape) {
                if (root.searching || root.query) root.resetSearch()
                else root.shown = false
                e.accepted = true
            } else if (e.key === Qt.Key_Slash && !root.searching) {
                root.searching = true; searchField.forceActiveFocus(); e.accepted = true
            } else if (e.key === Qt.Key_Question && !root.searching) {
                root.shown = false; e.accepted = true
            }
        }
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(root.colCount === 1 ? 460 : root.colCount === 2 ? 680 : 960, parent.width - 60)
        height: Math.min(colsRow.implicitHeight + header.height + 54, parent.height - 60)
        color: Theme.bg
        radius: Theme.radiusCard
        border.width: 1
        border.color: Theme.hairline
        clip: true

        Item {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 24 }
            height: 40
            Column {
                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                    text: "Keyboard shortcuts"
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: 18; font.weight: 600
                    renderType: Text.NativeRendering
                }
                Text {
                    text: root.searching ? "type to filter · esc to clear" : "/ to search · esc or ? to close"
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 12
                    renderType: Text.NativeRendering
                }
            }
            // search field: a pill on the right; grows in on `/`
            Rectangle {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: root.searching ? 220 : 0
                height: 30; radius: 8; clip: true
                color: Theme.surface1
                border.width: root.searching ? 1 : 0
                border.color: Theme.hairline
                visible: width > 1
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                TextInput {
                    id: searchField
                    anchors.fill: parent; anchors.margins: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: 13
                    clip: true
                    onTextChanged: root.query = text
                    Text {
                        visible: !searchField.text
                        anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                        text: "filter…"; color: Theme.fg_muted
                        font: searchField.font
                        renderType: Text.NativeRendering
                    }
                    Keys.onPressed: e => {
                        if (e.key === Qt.Key_Escape) {
                            root.resetSearch()
                            keyCatcher.forceActiveFocus(); e.accepted = true
                        }
                    }
                }
            }
        }

        Row {
            id: colsRow
            anchors { top: header.bottom; left: parent.left; right: parent.right
                      bottom: parent.bottom; margins: 24; topMargin: 16 }
            spacing: 28

            Repeater {
                model: root.laidOut
                Column {
                    required property var modelData
                    width: (colsRow.width - colsRow.spacing * (root.colCount - 1)) / root.colCount
                    spacing: 18

                    Repeater {
                        model: parent.modelData
                        Column {
                            required property var modelData
                            width: parent.width
                            spacing: 5

                            Text {
                                text: modelData.title
                                color: Theme.fg_muted
                                font.family: Theme.fontFamily; font.pixelSize: 11
                                font.weight: 600; font.capitalization: Font.AllUppercase
                                font.letterSpacing: 1.2
                                renderType: Text.NativeRendering
                            }
                            Repeater {
                                model: modelData.rows
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

            // empty-state when a filter matches nothing
            Text {
                visible: root.laidOut.length === 0 || root.filtered.length === 0
                text: "no shortcuts match “" + root.query + "”"
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 13
                renderType: Text.NativeRendering
            }
        }
    }
}
