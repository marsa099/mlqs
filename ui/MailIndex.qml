import QtQuick
import QtQuick.Controls
import "."
import QsLib

Rectangle {
    id: idx
    signal searchDone()
    function focusSearch() { sInput.forceActiveFocus() }
    readonly property bool searchFocus: sInput.activeFocus
    color: Theme.bg
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
    function page(d) { move(d * Math.max(3, Math.floor(list.height / 40 / 2))) }
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

    // header: folder name + count
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        // 52px to match the sidebar's account-tab band — the hairline must
        // run continuously across both panels
        height: 52; color: Theme.bg
        Text {
            renderType: Text.NativeRendering
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
            width: 230; height: 30; radius: 15
            color: Theme.surface
            border.width: 1
            border.color: sInput.activeFocus ? Theme.fg_muted : Theme.hairline
            TextField {
                id: sInput
                anchors.fill: parent; anchors.leftMargin: 12
                verticalAlignment: TextInput.AlignVCenter
                topPadding: 0; bottomPadding: 0
                color: Theme.fg; background: null
                rightPadding: 30
                placeholderText: "search…"
                placeholderTextColor: Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) { text = ""; idx.searchDone(); e.accepted = true }
                    else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (text.trim() !== "") Backend.runSearch(text.trim())
                        idx.searchDone(); e.accepted = true
                    }
                }
            }
            // the family keycap for the / bind, right-aligned in the pill
            Rectangle {
                visible: !sInput.activeFocus
                anchors.right: parent.right; anchors.rightMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                width: 20; height: 20; radius: 6
                color: Theme.mode === "light" ? Theme.bg : Theme.surface2
                border.width: 1; border.color: Theme.hairline
                Text {
                    renderType: Text.NativeRendering
                    anchors.centerIn: parent
                    text: "/"
                    color: Theme.fg
                    font.family: Theme.fontFamily; font.pixelSize: 11; font.weight: 500
                }
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
    }

    ListView {
        id: list
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        model: Backend.convs
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 60
        preferredHighlightBegin: 80
        preferredHighlightEnd: height - 80
        highlightRangeMode: ListView.ApplyRange

        // chat-client scroll feel: 5x wheel gain (Qt's default is treacle)
        property real scrollGain: 5.0
        WheelHandler {
            acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
            onWheel: e => {
                const px = (e.pixelDelta.y !== 0) ? e.pixelDelta.y : e.angleDelta.y / 8
                list.contentY -= px * list.scrollGain
                list.returnToBounds()
                if (list.contentY + list.height > list.contentHeight - 800) Backend.loadMore()
                e.accepted = true
            }
        }

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
            width: list.width; height: 40
            readonly property bool cursor: index === list.currentIndex
            readonly property bool sel: idx.inSel(index)
            // ink text on the inverted selection pill
            readonly property color rowFg: sel ? Theme.bg : Theme.fg
            readonly property color rowFgDim: sel ? Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.7) : Theme.fg_muted

            // reference-style pill rows in our tokens: unread pops as a raised
            // card, read sits as a faint tint, visual selection inverts to ink
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: idx.active ? 28 : 8
                anchors.rightMargin: 8
                anchors.topMargin: 2; anchors.bottomMargin: 2
                radius: height / 2
                color: row.sel ? Theme.fg
                     : row.cursor && idx.active ? Theme.selection
                     : row.unread ? (Theme.mode === "light" ? Theme.bg : Theme.surface2)
                     : Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.03)
                border.width: 1
                border.color: (row.cursor && idx.active) || row.unread ? Theme.hairline : "transparent"
            }

            // gutter: rel numbers normally; check circles in visual mode
            Item {
                id: gutter
                width: 22; height: parent.height
                anchors.left: parent.left; anchors.leftMargin: 4
                visible: idx.active
                Text {
                    renderType: Text.NativeRendering
                    visible: !idx.visualMode && !cursor
                    anchors.right: parent.right; anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: Math.abs(index - list.currentIndex)
                    color: Theme.fg; opacity: 0.5
                    font.family: Theme.fontFamily; font.pixelSize: 12
                    font.features: ({ "tnum": 1 })
                }
                Rectangle {
                    visible: !idx.visualMode && cursor
                    anchors.right: parent.right; anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3; height: 16; radius: 2; color: Theme.cursor
                }
                Rectangle {
                    visible: idx.visualMode
                    anchors.right: parent.right; anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16; height: 16; radius: 5
                    color: row.sel ? Theme.cursor : "transparent"
                    border.width: 1
                    border.color: row.sel ? Theme.cursor : Theme.hairline
                    Icon {
                        visible: row.sel
                        anchors.centerIn: parent
                        width: 10; height: 10
                        name: "check"
                        color: Theme.ink
                    }
                }
            }

            // unread dot
            Rectangle {
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 38 : 18
                anchors.verticalCenter: parent.verticalCenter
                width: 7; height: 7; radius: 4
                color: Theme.cursor
                visible: row.unread && !row.sel
            }

            Icon {
                id: star
                anchors.left: parent.left; anchors.leftMargin: idx.active ? 50 : 30
                anchors.verticalCenter: parent.verticalCenter
                width: 13; height: 13
                name: "flag-7"
                fill: row.starred ? "glyph" : "outline"
                color: row.sel ? Theme.bg : row.starred ? Theme.cursor : Theme.fg_muted
            }

            Text {
                id: whoText
                renderType: Text.NativeRendering
                anchors.left: star.right; anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 210
                text: row.who
                color: row.sel ? Theme.bg : row.unread ? Theme.fg : Theme.fg_secondary
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.weight: row.unread ? 600 : 400
                elide: Text.ElideRight
            }

            Text {
                renderType: Text.NativeRendering
                anchors.left: whoText.right; anchors.leftMargin: 14
                anchors.right: when.left; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.StyledText
                text: {
                    const subj = (row.subject || "(no subject)")
                        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    const snip = (row.snippet || "")
                        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    return subj + (snip ? "  <font color='" + Theme.fg_muted + "'>— " + snip + "</font>" : "")
                }
                color: row.sel ? Theme.bg : row.unread ? Theme.fg : Theme.fg_secondary
                font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 13
                font.weight: row.unread ? 600 : 400
                elide: Text.ElideRight
            }

            Text {
                id: when
                renderType: Text.NativeRendering
                anchors.right: parent.right; anchors.rightMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                text: row.dateStr
                color: row.sel ? Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.75) : row.unread ? Theme.fg : Theme.fg_muted
                font.family: Theme.fontFamily; font.pixelSize: 12
                font.features: ({ "tnum": 1 })
            }

            TapHandler {
                onTapped: { list.currentIndex = index; idx.open() }
            }
        }
    }

    Text {
        renderType: Text.NativeRendering
        anchors.centerIn: parent
        visible: list.count === 0 && !Backend.loadingConvs
        text: "empty"
        color: Theme.fg_muted; font.family: Theme.fontFamily; font.pixelSize: 13
    }
}
