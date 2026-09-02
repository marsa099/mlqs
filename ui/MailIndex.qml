import QtQuick
import QtQuick.Controls
import "."
import QsLib

Rectangle {
    id: idx
    signal searchDone()
    function focusSearch() {
        // scroll home so the field connects with the top of the results
        list.positionViewAtBeginning()
        list.currentIndex = 0
        sInput.forceActiveFocus()
    }
    readonly property bool searchFocus: sInput.activeFocus
    // header sits on the window canvas; the list floats below as a card
    color: "transparent"
    property bool active: true

    // visual mode: v anchors, j/k extend the range, actions apply to it
    property bool visualMode: false
    property int visualAnchor: 0
    function visualStart() {
        if (list.count === 0) return
        visualAnchor = list.currentIndex
        visualMode = true
    }
    function visualEnd() { visualMode = false }
    function inSel(i) {
        return visualMode && i >= Math.min(visualAnchor, list.currentIndex)
                          && i <= Math.max(visualAnchor, list.currentIndex)
    }
    function selRows() {
        if (!visualMode) { const c = current(); return c ? [c] : [] }
        const lo = Math.min(visualAnchor, list.currentIndex)
        const hi = Math.max(visualAnchor, list.currentIndex)
        const out = []
        for (let i = lo; i <= hi; i++) out.push(Backend.convs.get(i))
        return out
    }
    function selIds() { return selRows().map(r => r.tid) }

    function move(d) {
        if (list.count === 0) return
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + d))
        if (list.currentIndex >= list.count - 8) Backend.loadMore()
    }
    function page(d) { move(d * Math.max(3, Math.floor(list.height / 64 / 2))) }
    function toTop() { list.currentIndex = 0 }
    function toEnd() { list.currentIndex = list.count - 1 }
    function current() {
        return list.currentIndex >= 0 && list.currentIndex < list.count
            ? Backend.convs.get(list.currentIndex) : null
    }
    function open() { Backend.openConv(current()) }
    Connections {
        target: Backend
        function onCurrentFolderIdChanged() { list.currentIndex = 0; idx.visualEnd() }
    }

    // header: folder name + count, on the canvas (52px matches the sidebar's
    // account-tab band)
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52; color: "transparent"
        Text {
            anchors.left: parent.left; anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: (Backend.currentFolderName.charAt(0) + Backend.currentFolderName.slice(1).toLowerCase())
                  + (Backend.loadingConvs ? "  · loading…" : "")
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 14; font.weight: 600
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: 320; height: 36; radius: 18
            color: Theme.mode === "light" ? Theme.bg : Theme.surface2
            border.width: 1
            border.color: sInput.activeFocus ? Theme.fg_muted : Theme.hairlineSoft
            Icon {
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 14; height: 14
                name: "magnifier"
                fill: "outline"
                color: sInput.activeFocus ? Theme.fg : Theme.fg_muted
            }
            TextField {
                id: sInput
                anchors.fill: parent; anchors.leftMargin: 34
                verticalAlignment: TextInput.AlignVCenter
                topPadding: 0; bottomPadding: 0
                color: Theme.fg; background: null
                rightPadding: 30
                placeholderText: "search…"
                placeholderTextColor: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
                // Esc LEAVES the search — empties the box and puts back the view the
                // search interrupted. Blanking the field alone used to leave the
                // results and the "search: …" title on screen with no way back.
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) {
                        text = ""; Backend.exitSearch(); idx.searchDone(); e.accepted = true
                    } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (text.trim() !== "") Backend.runSearch(text.trim())
                        else Backend.exitSearch()          // ↵ on an emptied box also exits
                        idx.searchDone(); e.accepted = true
                    }
                }
            }
            // Right side of the pill: the `/` keycap when idle, and while a search is
            // active an esc cap that says how to get out (and clears on click) —
            // otherwise leaving is invisible until you already know the bind.
            Rectangle {
                readonly property bool clearable: Backend.searchView
                visible: clearable || !sInput.activeFocus
                anchors.right: parent.right; anchors.rightMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                width: clearable ? 30 : 20; height: 20; radius: 6
                color: Theme.mode === "light" ? Theme.bg : Theme.surface2
                border.width: 1
                border.color: clearable ? Theme.fg_muted : Theme.hairline
                Text {
                    anchors.centerIn: parent
                    text: parent.clearable ? "esc" : "/"
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                }
                TapHandler {
                    enabled: parent.clearable
                    onTapped: { sInput.text = ""; Backend.exitSearch(); idx.searchDone() }
                }
            }
        }
        // leaving a search any other way (⇧I, a folder jump) must not strand the
        // query in the box — the pill would claim a search that isn't running
        Connections {
            target: Backend
            function onSearchViewChanged() { if (!Backend.searchView) sInput.text = "" }
        }
    }

    Card {
        id: card
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom
                  topMargin: 6; leftMargin: 8; rightMargin: 14; bottomMargin: 14 }
        // concentric with the row pills: pill radius (58/2 = 29) + 14px inset
        radius: 43
        color: Theme.surface0
        border.width: 1
        border.color: Theme.hairlineSoft
    }

    ListView {
        id: list
        // 11 + the pill's own 3px margin = 14, matching the side inset so the
        // card corner stays concentric with the pills on both axes
        anchors { fill: card; topMargin: 11; bottomMargin: 11 }
        model: Backend.convs
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 60
        preferredHighlightBegin: 80
        preferredHighlightEnd: height - 80
        highlightRangeMode: ListView.ApplyRange

        // pagination watches contentY so touchpad (native) scrolling loads too
        onContentYChanged: if (contentY + height > contentHeight - 800) Backend.loadMore()

        ScrollFeel { flick: list }

        delegate: Item {
            id: row
            required property int index
            required property string tid
            required property string subject
            required property string snippet
            required property string who
            required property string dateStr
            required property bool unread
            required property bool starred
            // declaring ANY required property turns off implicit model-role
            // injection, so every role the delegate reads must be listed here —
            // an undeclared one is silently undefined, which is how the merged
            // list's account chip rendered as an empty (invisible) string
            required property string account
            width: list.width; height: 64
            readonly property bool cursor: index === list.currentIndex
            readonly property bool sel: idx.inSel(index)

            // reference-style pill rows in our tokens: unread pops as a raised
            // card, read rests on the surface, and selection carries the accent
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: idx.active ? 42 : 14
                anchors.rightMargin: 14
                anchors.topMargin: 3; anchors.bottomMargin: 3
                radius: height / 2
                color: row.sel ? Theme.surface3
                     : row.cursor && idx.active ? Theme.selection
                     : row.unread ? Theme.surface : Theme.surface0
                border.width: (row.sel || (row.cursor && idx.active) || row.unread) ? 1 : 0
                border.color: (row.sel || (row.cursor && idx.active)) ? Theme.hairline : Theme.hairlineSoft
                Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.InOutQuad } }
                Behavior on border.color { ColorAnimation { duration: 120; easing.type: Easing.InOutQuad } }
            }

            // gutter: rel numbers stay put in visual mode — the range is readable as counts
            Item {
                id: gutter
                width: 22; height: parent.height
                anchors.left: parent.left; anchors.leftMargin: 4
                visible: idx.active
                Text {
                    visible: !cursor
                    anchors.right: parent.right; anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: Math.abs(index - list.currentIndex)
                    color: Theme.fg; opacity: 0.5
                    font.family: Theme.fontFamily; font.pixelSize: 12
                    font.features: ({ "tnum": 1 })
                }
                Rectangle {
                    visible: cursor
                    anchors.right: parent.right; anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3; height: 16; radius: 2; color: Theme.fg_muted
                }
            }

            // always-on checkbox (reference-style); fills on visual-mode selection
            Rectangle {
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 56 : 28
                anchors.verticalCenter: parent.verticalCenter
                width: 18; height: 18; radius: 6
                // solid card-white fill so the box reads on tinted pills too
                color: row.sel ? Theme.surface3 : Theme.bg
                border.width: 1
                border.color: row.sel ? Theme.hairline : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.25)
                Icon {
                    visible: row.sel
                    anchors.centerIn: parent
                    width: 11; height: 11
                    name: "check"
                    color: Theme.fg
                }
            }
            // flag only when it says something — starred, cursor, or in the visual range
            Icon {
                id: star
                visible: row.starred || row.sel || (row.cursor && idx.active)
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 86 : 58
                anchors.verticalCenter: parent.verticalCenter
                width: 14; height: 14
                name: "flag-7"
                fill: row.starred ? "glyph" : "outline"
                color: row.starred ? Theme.yellow : Theme.fg_muted
            }

            Text {
                id: whoText
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 112 : 84
                anchors.verticalCenter: parent.verticalCenter
                width: 210
                text: row.who
                color: row.unread ? Theme.fg : Theme.fg_secondary
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.weight: row.unread ? 600 : 400
                elide: Text.ElideRight
            }

            Column {
                anchors.left: whoText.right; anchors.leftMargin: 14
                anchors.right: when.left; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Text {
                    width: parent.width
                    text: row.subject || "(no subject)"
                    color: row.unread ? Theme.fg : Theme.fg_secondary
                    font.family: Theme.fontFamily
                    font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 13
                    font.weight: row.unread ? 600 : 400
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    visible: text !== ""
                    // single line no matter what the provider sends — embedded
                    // newlines (Graph bodyPreview) otherwise overflow the row
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    // gmail snippets arrive HTML-entity-encoded
                    text: (row.snippet || "").replace(/[\n\r]+/g, " ").replace(/&#39;/g, "'").replace(/&quot;/g, '"')
                        .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
                    color: Theme.fg_muted
                    font.family: Theme.fontFamily
                    font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12
                }
            }

            // any merged list (inbox, Filtered, Threads): name the mailbox each row
            // came from. Muted text on the right, the same treatment CalendarView
            // already uses for its merged rows — hidden when an account filter is
            // set, since then every row is from the same mailbox.
            Text {
                id: acctText
                anchors.right: parent.right; anchors.rightMargin: 30
                anchors.verticalCenter: parent.verticalCenter
                visible: Backend.merged && text !== ""
                text: row.account || ""
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 11
            }

            Text {
                id: when
                anchors.right: acctText.visible ? acctText.left : parent.right
                anchors.rightMargin: acctText.visible ? 12 : 30
                anchors.verticalCenter: parent.verticalCenter
                text: row.dateStr
                color: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
                font.features: ({ "tnum": 1 })
            }

            TapHandler {
                onTapped: { list.currentIndex = index; idx.open() }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: list.count === 0 && !Backend.loadingConvs
        text: "empty"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13
    }
}
