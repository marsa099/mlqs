// `?` from any non-insert mode: a full keybind reference across every mode.
// Scrim + centered card. Responsive column count, `/` to fuzzy-filter, esc/?
// to close. Owns its keyboard focus while shown (shell.qml refocuses on close).
import QtQuick
import "."
import QsLib

Item {
    id: root
    anchors.fill: parent
    property bool shown: false
    property string query: ""
    property bool searching: false
    // fade in/out like the slqs/dsqrd cheat sheet (shell drives `shown`)
    opacity: shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 90 } }

    // Presentational only — shell.qml owns key handling (open/close/filter) and
    // sets shown/searching/query; the field below just displays `query`.
    function resetSearch() { searching = false; query = "" }
    onShownChanged: { resetSearch(); if (shown) flick.contentY = 0 }
    // keyboard scroll (shell.qml drives these while shown): j/k step, ⌃d/⌃u page
    function scrollBy(dy) { flick.scrollBy(dy) }
    function scrollPage(dir) { flick.scrollBy(dir * flick.height * 0.85) }

    // Flat ordered sections: { title, rows: [ [ [keys…], description ] … ] }.
    readonly property var sections: [
        { title: "Normal", rows: [
            [["j"], "Down (count: 8j)"], [["k"], "Up"],
            [["↵"], "Open conversation"], [["l"], "Open / focus index"],
            [["h"], "Focus sidebar"], [["g", "g"], "Jump to top"], [["⇧g"], "Jump to bottom"],
            [["x"], "Star"], [["e"], "Archive"], [["d", "d"], "Trash"], [["u"], "Undo last remove"],
            [["v"], "Visual select"], [["r"], "Toggle read"], [["⇧r"], "Refresh"],
            [["n"], "Compose"], [["/"], "Search"], [["q"], "Hide window"],
        ]},
        { title: "Go to", rows: [
            [["⇧i"], "Inbox"], [["⇧t"], "Threads"], [["⇧c"], "Calendar"],
            [["g", "i"], "Inbox"], [["g", "⇧i"], "Starred"], [["g", "s"], "Sent"],
            [["g", "⇧s"], "Spam"], [["g", "d"], "Drafts"], [["g", "t"], "Threads"],
            [["g", "⇧t"], "Trash"], [["g", "c"], "Calendar"],
        ]},
        { title: "Conversation", rows: [
            [["j"], "Scroll down"], [["k"], "Scroll up"],
            [["⇧j"], "Next message"], [["⇧k"], "Previous message"],
            [["↵"], "Cursor in message"], [["v"], "Visual select in message"],
            [["y"], "Yank hints (invites: accept)"], [["⇧y"], "Copy whole message"],
            [["m"], "RSVP tentative"], [["n"], "RSVP decline"],
            [["i"], "Reply"], [["a"], "Toggle reply-all"], [["r"], "Reply to focused"],
            [["⇧f"], "Forward"], [["f"], "Link hints"], [["o"], "Open in browser"],
            [["e"], "Archive"], [["d", "d"], "Trash"],
            [["h"], "Close"], [["q"], "Back to inbox"],
        ]},
        { title: "Visual — index", rows: [
            [["j", "k"], "Extend selection"], [["e"], "Archive selection"],
            [["d"], "Trash selection"], [["r"], "Mark read"], [["x"], "Star"],
            [["⌃d", "⌃u"], "Half-page (extends)"], [["esc"], "Exit"],
        ]},
        { title: "Message cursor", rows: [
            [["↵"], "Enter message (auto if single)"],
            [["h", "l"], "Char left / right"], [["j", "k"], "Line down / up (counts: 12j)"],
            [["w", "b", "e"], "Word forward / back / end"],
            [["⇧w", "⇧b", "⇧e"], "WORD (whitespace-delimited)"],
            [["0", "^", "$"], "Line start / first char / end"], [["g", "⇧g"], "Text start / end"],
            [["v"], "Visual select"], [["⇧v"], "Line select"],
            [["⌃d", "⌃u"], "Half-page cursor move"], [["⌃e", "⌃y"], "Scroll view"],
            [["o"], "Swap anchor / cursor"],
            [["y"], "Yank selection / image / token hints"],
            [["y", "y"], "Copy whole message"], [["⇧y"], "Copy whole message"],
            [["esc"], "Drop selection / back"],
        ]},
        { title: "Yank mode", rows: [
            [["a", "s", "d", "…"], "Pick a label to copy it"],
            [["y"], "Copy whole message"],
            [["esc"], "Cancel"],
        ]},
        { title: "Calendar", rows: [
            [["j", "k"], "Move"], [["↵"], "Open event"], [["o"], "Open in browser"],
            [["y", "m", "n"], "RSVP"], [["⇧n"], "New event"], [["s"], "Cycle span"],
            [["⇥"], "Filter calendar (⇧⇥ back)"], [["x"], "Hide / show filtered calendar"],
            [["r"], "Refresh"],
        ]},
        { title: "Global", rows: [
            [["⌃d", "⌃u"], "Half-page down / up"], [["⌃h", "⌃l"], "Sidebar / index"],
            [["⌃s"], "Next account"], [["⌃⇧h", "⌃⇧l"], "Prev / next account"],
            [["⌃⇧r"], "Check for updates"], [["⇧U"], "Apply update"], [["?"], "This cheat sheet"],
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

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(root.colCount === 1 ? 460 : root.colCount === 2 ? 680 : 960, parent.width - 60)
        height: Math.min(colsRow.implicitHeight + header.height + 54, parent.height - 60)
        // smoothly resize as filtering adds/removes rows
        Behavior on height {
            NumberAnimation { duration: 200; easing.type: Easing.BezierSpline
                              easing.bezierCurve: [0.165, 0.84, 0.44, 1.0, 1.0, 1.0] }
        }
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
                }
                Text {
                    text: root.searching ? "type to filter · esc to clear" : "/ to search · esc or ? to close"
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 12
                }
            }
            // search field: a pill on the right; grows in while filtering, and
            // stays open as long as there's text (never hide a non-empty filter)
            Rectangle {
                readonly property bool showField: root.searching || root.query.length > 0
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                width: showField ? 220 : 0
                height: 30; radius: 8; clip: true
                color: Theme.surface1
                border.width: showField ? 1 : 0
                border.color: Theme.hairline
                visible: width > 1
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Text {   // display-only: shell.qml edits root.query
                    anchors.fill: parent; anchors.margins: 8
                    verticalAlignment: Text.AlignVCenter
                    text: root.query.length ? root.query : "filter…"
                    color: root.query.length ? Theme.fg : Theme.fg_muted
                    font.family: Theme.fontFamily; font.pixelSize: 13
                    elide: Text.ElideLeft
                }
            }
        }

        // Scroll when the columns don't fit a short screen (small laptops) —
        // otherwise the panel clips the bottom rows with no way to reach them.
        // Trackpad/wheel scroll works natively; shell.qml's j/k/⌃d/⌃u call scrollBy.
        Flickable {
            id: flick
            anchors { top: header.bottom; left: parent.left; right: parent.right
                      bottom: parent.bottom; margins: 24; topMargin: 16 }
            clip: true
            contentWidth: width
            contentHeight: colsRow.implicitHeight
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            function scrollBy(dy) {
                contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + dy))
            }

        Row {
            id: colsRow
            width: flick.width
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
            }
        }
        }
    }
}
