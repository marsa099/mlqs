import QtQuick
import "."

// Folder sidebar in the chat clients' visual language: inverted ink-pill
// cursor, faint tint on the open folder, loud/quiet unread hierarchy.
Rectangle {
    id: bar
    color: Theme.bg_alt
    property bool active: false
    property int sel: 0
    opacity: active ? 1.0 : 0.8
    Behavior on opacity { NumberAnimation { duration: 120 } }

    readonly property var roleGlyph: ({
        inbox: "󰚇", starred: "", sent: "󰗍", drafts: "󰙏",
        spam: "󱚝", trash: "󰩺", label: "󰓹"
    })

    function move(d) {
        if (Backend.folders.length === 0) return
        sel = Math.max(0, Math.min(Backend.folders.length - 1, sel + d))
        list.positionViewAtIndex(sel, ListView.Contain)
    }
    function choose() {
        const f = Backend.folders[sel]
        if (f) Backend.selectFolder(f.id, f.name)
    }
    Connections {
        target: Backend
        function onCurrentFolderIdChanged() {
            const i = Backend.folders.findIndex(f => f.id === Backend.currentFolderId)
            if (i >= 0) bar.sel = i
        }
    }

    // account header: same 52px band + hairline as the chat workspace header
    Item {
        id: acctHeader
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: 52
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
        Text {
            renderType: Text.NativeRendering
            anchors.left: parent.left; anchors.leftMargin: 16
            anchors.right: parent.right; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: {
                const w = Backend.workspaces.find(x => x.id === Backend.currentAccount)
                return w ? (w.email || w.name) : "mlqs"
            }
            color: Theme.fg; font.family: Theme.fontFamily
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: 13; font.weight: 600
            elide: Text.ElideRight
        }
    }

    ListView {
        id: list
        anchors { top: acctHeader.bottom; topMargin: 4; left: parent.left; right: parent.right; bottom: parent.bottom }
        model: Backend.folders
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        section.property: "section"
        section.delegate: Item {
            required property string section
            width: list.width
            height: 34
            Text {
                renderType: Text.NativeRendering
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                text: section.toUpperCase()
                color: Theme.fg_muted; font.family: Theme.fontFamily
                font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 11; font.weight: 500; font.letterSpacing: 1.2
            }
        }

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: list.width; height: 36
            readonly property bool cursor: index === bar.sel
            readonly property bool isOpen: modelData.id === Backend.currentFolderId
            readonly property bool primary: bar.active && cursor
            // inbox unread is the "loud" count (filled accent pill, like
            // mentions/DMs in chat); other folders stay quiet muted numbers
            readonly property bool loudUnread: modelData.unread > 0 && modelData.role === "inbox"

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 6; anchors.rightMargin: 6
                radius: height / 2
                color: row.primary ? Theme.fg
                     : (row.isOpen && !bar.active ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.06)
                               : hov.hovered ? Qt.rgba(Theme.fg.r, Theme.fg.g, Theme.fg.b, 0.04) : "transparent")
            }
            HoverHandler { id: hov }

            // relative number gutter (vim hybrid), focused-panel only
            Text {
                renderType: Text.NativeRendering
                visible: bar.active && !row.cursor
                anchors.left: parent.left; anchors.leftMargin: 12
                width: 18; horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
                text: Math.abs(row.index - bar.sel)
                color: Theme.fg; opacity: 0.65
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 12
                font.features: ({ "tnum": 1 })
            }
            Rectangle {
                visible: bar.active && row.cursor
                anchors.left: parent.left; anchors.leftMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                width: 3; height: 16; radius: 2; color: Theme.cursor
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: bar.active ? 36 : 18
                anchors.rightMargin: 8 + (modelData.unread > 0 ? 38 : 0)
                spacing: 7
                Text {
                    renderType: Text.NativeRendering
                    id: glyph
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    text: bar.roleGlyph[modelData.role] || "󰓹"
                    color: row.primary ? Theme.bg
                         : modelData.role === "starred" ? Theme.yellow : Theme.fg_muted
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 13
                }
                Text {
                    renderType: Text.NativeRendering
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - glyph.width - parent.spacing
                    text: modelData.role === "label" ? modelData.name
                        : (modelData.name.charAt(0) + modelData.name.slice(1).toLowerCase())
                    elide: Text.ElideRight
                    color: row.primary ? Theme.bg
                         : (modelData.unread > 0 || row.isOpen || row.cursor) ? Theme.fg : Theme.dimmedFg
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 14
                    font.weight: modelData.unread > 0 ? 500 : Theme.fontWeight
                }
            }

            // loud: filled accent pill, ink text (inbox)
            Rectangle {
                visible: row.loudUnread
                anchors.right: parent.right; anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                height: 18; width: Math.max(18, ub.implicitWidth + 10); radius: 9
                color: Theme.cursor
                Text {
                    id: ub; renderType: Text.NativeRendering; anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    text: modelData.unread > 9999 ? "9999+" : modelData.unread
                    color: Theme.ink
                    font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                    font.pixelSize: 12; font.weight: 500; font.features: ({ "tnum": 1 })
                }
            }
            // quiet: bare muted count
            Text {
                renderType: Text.NativeRendering
                visible: modelData.unread > 0 && !row.loudUnread
                anchors.right: parent.right; anchors.rightMargin: 22
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.unread
                color: row.primary ? Theme.bg : Theme.fg_muted
                font.family: Theme.fontFamily; font.hintingPreference: Font.PreferNoHinting
                font.pixelSize: 12; font.features: ({ "tnum": 1 })
            }

            TapHandler {
                onTapped: { bar.sel = index; bar.choose() }
            }
        }
    }
}
